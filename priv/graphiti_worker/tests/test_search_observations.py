"""Public scripted native search/IPC mechanics; not root inventory authority."""
import asyncio
import copy
import importlib
import struct
from datetime import datetime, timezone
from types import SimpleNamespace
from uuid import uuid4

import httpx
import pytest
from openai import AsyncOpenAI
from graphiti_core.driver.neo4j_driver import Neo4jDriver
from graphiti_core.edges import EntityEdge
from graphiti_core.search.search_config import SearchResults
from graphiti_core.search.search_config_recipes import EDGE_HYBRID_SEARCH_RRF
from graphiti_core.search.search_filters import SearchFilters

from fixtures.helpers import context_reply, job, pin, reply
from ipc_transport import IPCTransport
from lineage import operation
from observations import (CURRENT_INTERMEDIATE, _guard_bulk_transaction,
                          _wrap_async, _wrap_temporal, intermediate_operation)
from protocol import BoundaryError, canonical, digest
from read_observations import BOOTSTRAP_SEAM, wrap_read
from runtime import DeniedReranker, MeteredEmbedder
from search_observations import (SEARCH_SCHEMA_DIGEST, SEARCH_SEAM, native_search,
    native_search_policy, project_results, search_input, search_prompt_policy, search_schema)


def stages():
    return {stage: pin(stage, "http://127.0.0.1:11434/v1/" +
        ("embeddings" if stage == "embedder" else "chat/completions"))
        for stage in ("extraction", "embedder")}


def edge(**updates):
    values = dict(uuid=str(uuid4()), group_id="synthetic_group", name="SYNTHETIC",
        fact="Synthetic A assists Synthetic B.", source_node_uuid=str(uuid4()),
        target_node_uuid=str(uuid4()), episodes=[str(uuid4())],
        created_at=datetime(2026, 1, 1, tzinfo=timezone.utc))
    values.update(updates)
    return EntityEdge(**values)


def test_closed_search_schema_and_prompt_are_defensive_and_not_native_catalogue_schemas():
    schema = search_schema()
    assert schema["$id"] == "hf.graph.search.v1"
    assert digest(canonical(schema)) == SEARCH_SCHEMA_DIGEST
    assert schema["oneOf"][0]["required"] == ["query", "limit", "recipe_id", "group_id"]
    assert schema["oneOf"][1]["properties"]["candidates"]["maxItems"] == 10
    assert search_prompt_policy() == {"format": "root-search-prompt-policy-v1",
        "input_transform_id": "root_search_intent_v1", "prompt_name": SEARCH_SEAM,
        "provider_attempt": False, "result_transform_id": "native_search_rrf_v1", "stage": "embedder"}
    schema["oneOf"].clear()
    assert len(search_schema()["oneOf"]) == 2
    assert native_search_policy()["mutation"] == "denied"


@pytest.mark.parametrize("updates", [
    {"args": {"query": "x" * 257, "limit": 1, "recipe_id": "edge_hybrid_rrf_v1"}},
    {"args": {"query": "x", "limit": 11, "recipe_id": "edge_hybrid_rrf_v1"}},
    {"deadline_ms": 60001}, {"scope_ref": ""}, {"op": "ingest"},
])
def test_search_profile_rejects_before_native_call(updates):
    with pytest.raises(BoundaryError):
        search_input(job().model_copy(update=updates))


@pytest.mark.parametrize("change", ["duplicate", "support_zero", "support_duplicate", "support_25",
    "foreign", "non_uuid", "nan", "other_scope", "opaque", "score_bool"])
def test_native_result_measurement_denies_unknown_or_oversize_without_truncation(change):
    item = edge()
    results = SearchResults(edges=[item], edge_reranker_scores=[0.5])
    if change == "duplicate":
        results.edges.append(item)
        results.edge_reranker_scores.append(0.5)
    elif change.startswith("support_"):
        item.episodes = ([] if change == "support_zero" else [str(uuid4()) for _ in range(25)]
            if change == "support_25" else item.episodes * 2)
    elif change == "foreign":
        item.group_id = "foreign"
    elif change == "non_uuid":
        item.uuid = "edge:synthetic"
    elif change == "nan":
        results.edge_reranker_scores[0] = float("nan")
    elif change == "other_scope":
        results.node_reranker_scores.append(0.1)
    elif change == "opaque":
        results.edges[0] = object()
    else:
        results.edge_reranker_scores[0] = True
    with pytest.raises(BoundaryError, match="closure_incomplete"):
        project_results(results, group_id="synthetic_group", limit=10)


async def scripted_native_search(monkeypatch, *, empty=False, query="Synthetic\nrelationship", limit=1,
                                deny_final=False):
    """Use the real pinned search/RRF and official SDK; script only I/O edges."""
    native = importlib.import_module("graphiti_core.search.search")
    selected, configured = job(args={"query": query, "limit": limit, "recipe_id": "edge_hybrid_rrf_v1"}), stages()
    pages, attempts, calls, reads, sealed = [], [], [], [], {}
    # A candidate present in only one list is discarded at limit1 but its read
    # context must still parent the final outer proof.
    winner, discarded = edge(), edge()
    all_edges = [] if empty else [winner, discarded]
    async def observe(page):
        pages.append(page)
        ack = await context_reply(page)
        sealed[page.context_id] = ack.context_manifest_ref
        if deny_final and page.seam_id == SEARCH_SEAM and page.phase == "derived":
            return ack.model_copy(update={"state": "denied", "error_code": "closure_incomplete",
                "context_manifest_ref": None, "context_manifest_digest": None, "version_refs": []})
        return ack
    async def relay(attempt):
        attempts.append(attempt)
        return reply(attempt, {"object": "list", "model": configured["embedder"].model,
            "data": [{"object": "embedding", "index": 0, "embedding": [1.0] + [0.0] * 1023}],
            "usage": {"prompt_tokens": 1, "total_tokens": 1}})
    async def fulltext(driver, query, search_filter, group_ids=None, limit=10):
        state = CURRENT_INTERMEDIATE.get()
        assert state.read_only and state.read_owner is asyncio.current_task() and state.write_gate.locked()
        reads.append(("fulltext", query, group_ids, limit))
        return all_edges
    async def similarity(driver, search_vector, source_node_uuid, target_node_uuid, search_filter,
                         group_ids=None, limit=10, min_score=0.0):
        state = CURRENT_INTERMEDIATE.get()
        assert state.read_only and state.read_owner is asyncio.current_task() and state.write_gate.locked()
        assert len(search_vector) == 1024 and source_node_uuid is target_node_uuid is None
        reads.append(("similarity", group_ids, limit))
        return [] if empty else [winner]
    monkeypatch.setattr(native, "edge_fulltext_search", wrap_read(fulltext, "search_utils.edge_fulltext_search", "EntityEdge"))
    monkeypatch.setattr(native, "edge_similarity_search", wrap_read(similarity, "search_utils.edge_similarity_search", "EntityEdge"))
    recipe_before = copy.deepcopy(EDGE_HYBRID_SEARCH_RRF)
    async with httpx.AsyncClient(transport=IPCTransport(configured["embedder"], relay, asyncio.Semaphore(1)), trust_env=False) as client:
        embedder = MeteredEmbedder(configured["embedder"], AsyncOpenAI(api_key="ipc-placeholder",
            base_url="http://127.0.0.1:11434/v1/", http_client=client, max_retries=0), observe)
        clients = SimpleNamespace(driver=object.__new__(Neo4jDriver), embedder=embedder,
            cross_encoder=DeniedReranker(), max_coroutines=1)
        class Graph:
            async def search_(self, original, *, config, group_ids):
                calls.append((original, config, group_ids))
                assert config is not EDGE_HYBRID_SEARCH_RRF
                unchanged = config.model_copy(update={"limit": recipe_before.limit})
                assert unchanged == recipe_before
                return await native.search(clients, original, group_ids, config, SearchFilters())
        with operation(selected):
            if deny_final:
                with pytest.raises(BoundaryError, match="closure_incomplete"):
                    await native_search(Graph(), selected, configured, observe)
                return None, pages, attempts, reads, calls, sealed
            result = await native_search(Graph(), selected, configured, observe)
    assert EDGE_HYBRID_SEARCH_RRF == recipe_before
    return result, pages, attempts, reads, calls, sealed


@pytest.mark.parametrize("empty", [False, True])
async def test_one_native_rrf_search_one_observed_singleton_even_empty_and_all_reader_parents(monkeypatch, empty):
    result, pages, attempts, reads, calls, sealed = await scripted_native_search(monkeypatch, empty=empty)
    assert len(calls) == len(attempts) == 1 and len(reads) == 2
    assert calls[0][0] == "Synthetic\nrelationship" and calls[0][2] == ["synthetic_group"]
    embed_inputs = [p for p in pages if p.seam_id == "embedder.input.v1"]
    assert len(embed_inputs) == 1 and embed_inputs[0].entries[0].value == ["Synthetic relationship"]
    outer = [p for p in pages if p.seam_id == SEARCH_SEAM]
    assert [p.phase for p in outer] == ["inputs", "derived"]
    assert all(len(p.entries) == 1 and p.entries[0].object_id == p.logical_call_id for p in outer)
    assert outer[0].logical_call_id == outer[1].logical_call_id
    assert outer[0].stage_id == outer[1].stage_id == "stage:embedder"
    assert outer[1].base_context_ref is not None
    # Synthetic ACK IDs are not root proof. Assert every measured Bootstrap
    # ACK remains a direct parent, including discarded native candidates.
    bootstrap = [p for p in pages if p.seam_id == BOOTSTRAP_SEAM]
    assert bool(bootstrap) == (not empty)
    assert len(result["candidates"]) == (0 if empty else 1)
    measured = outer[1].entries[0].value["candidates"]
    if not empty:
        assert sum(len(p.entries) for p in bootstrap) == 2  # includes discarded native candidate
        assert measured[0]["edge_id"] == result["candidates"][0]["edge_id"]
        assert measured[0]["score"]["bits"] == struct.pack(">d", result["candidates"][0]["score"]).hex()
    assert len(outer[1].parent_contexts) >= len(bootstrap) + 2  # outer input + native embedding receipts
    parents = {parent.manifest_ref for parent in outer[1].parent_contexts}
    assert {sealed[page.context_id] for page in bootstrap} <= parents
    assert sealed[outer[0].context_id] in parents
    logical = [p for p in pages if p.seam_id == "llm.response.v1"
        and "embedding_vectors" in p.entries[0].value]
    assert len(logical) == 1 and sealed[logical[0].context_id] in parents


async def test_denied_outer_result_ack_withholds_native_search_result(monkeypatch):
    result, pages, attempts, _, calls, _ = await scripted_native_search(monkeypatch, deny_final=True)
    assert result is None and len(attempts) == len(calls) == 1
    assert pages[-1].seam_id == SEARCH_SEAM and pages[-1].phase == "derived"


@pytest.mark.parametrize("path", ["save", "intermediate", "temporal", "transaction"])
async def test_readonly_native_mutations_deny_before_argument_capture_or_delegate(path):
    calls = []
    async def mutation(*args, **kwargs):
        calls.append("mutated")
    def temporal(*args, **kwargs):
        calls.append("mutated")
    selected = job()
    with operation(selected), pytest.raises(BoundaryError, match="closure_incomplete"):
        async with intermediate_operation(stages(), context_reply, read_only=True):
            if path == "temporal":
                _wrap_temporal(temporal)(object(), [])
            elif path == "transaction":
                await _guard_bulk_transaction(mutation)(object())
            else:
                await _wrap_async(mutation, "graphiti.save.v1", "graphiti_save_v1", "extraction",
                    save=path == "save", save_method="EntityNode.save" if path == "save" else None)(object())
    assert calls == []


@pytest.mark.parametrize("path", ["wrong_input", "second", "generation", "batch"])
async def test_search_embedding_boundary_rejects_unknown_extra_and_generative_calls_before_post(path):
    from observations import observed_call
    configured, pages = stages(), []
    async def observe(page):
        pages.append(page)
        return await context_reply(page)
    with operation(job()), pytest.raises(BoundaryError, match="closure_incomplete"):
        async with intermediate_operation(configured, observe, read_only=True) as state:
            if path == "second":
                state.search_embed_calls = 1
            selected = configured["extraction"] if path == "generation" else configured["embedder"]
            prompt = "embedder.create_batch" if path == "batch" else "embedder.create"
            values = ["changed"] if path == "wrong_input" else state.search_embed_input
            async with observed_call(selected, prompt, values, observe, embed=path != "generation"):
                raise AssertionError("Denied call reached native client")
    assert pages == []


@pytest.mark.parametrize("route,object_type", [("EntityNode.get_by_uuids", "EntityNode"),
    ("EpisodicNode.get_by_uuid", "EpisodicNode"), ("search_utils.node_similarity_search", "EntityNode")])
async def test_readonly_search_denies_ingest_loader_routes_before_delegation(route, object_type):
    calls = []
    async def native(driver, group_ids=None):
        calls.append(True)
        return []
    with operation(job()), pytest.raises(BoundaryError, match="closure_incomplete"):
        async with intermediate_operation(stages(), context_reply, read_only=True):
            await wrap_read(native, route, object_type)(object.__new__(Neo4jDriver), ["synthetic_group"])
    assert calls == []
