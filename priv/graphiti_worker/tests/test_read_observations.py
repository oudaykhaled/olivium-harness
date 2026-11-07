"""Native read/append mechanics with public synthetic ACKs; no root proof claim."""
import asyncio
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from uuid import uuid4

import pytest
from pydantic import ValidationError
from graphiti_core.nodes import EntityNode, EpisodicNode, EpisodeType
from graphiti_core.edges import EntityEdge
from graphiti_core.driver.neo4j_driver import Neo4jDriver
from graphiti_core.errors import NodeNotFoundError

from fixtures.helpers import context_reply, job, pin
from lineage import operation
from observations import (SAVE_ACTIVE, Call, Observation, Proof, SeamFrame,
                          intermediate_operation, native_value)
from protocol import BoundaryError, ContextEntry, canonical, digest
from read_observations import (BOOTSTRAP_SCHEMA_DIGEST, BOOTSTRAP_SEAM, BOOTSTRAP_TRANSFORM,
                               LOADER_PROJECTION, bootstrap_schema, native_read_policy,
                               without_vector, wrap_read)


def ingest_job(**updates):
    body = "Synthetic next episode"
    return job("ingest", args={"binding_id": "binding:synthetic", "episode_uuid": str(uuid4()),
        "revision_id": "revision:synthetic", "body": body, "body_hash": digest(body.encode()),
        "window_start": 0, "window_end": len(body.encode()), "reference_time": "2026-01-01T00:00:00Z",
        "time_basis": "event", "prior_episode_ids": []}, **updates)


def stages():
    return {stage: pin(stage, "http://127.0.0.1:11434/v1/chat/completions")
            for stage in ("extraction", "summary")}


def driver():
    # No driver constructor, sockets or backend. The actual pinned class is
    # required by the registered native wrapper profile.
    return object.__new__(Neo4jDriver)


class ScriptedAuthority:
    """Entry binding and wait mechanics only, never production inventory authority."""
    def __init__(self):
        self.pages = []
        self.refs = {}

    async def __call__(self, page):
        self.pages.append(page)
        ack = await context_reply(page)
        refs = []
        for entry in page.entries:
            identity = (entry.kind, entry.object_id)
            existing = self.refs.get(identity)
            ref = entry.version_ref or (existing[1] if existing and existing[0] == entry.value_hash else str(uuid4()))
            self.refs[identity] = entry.value_hash, ref
            refs.append({"entry_id": entry.entry_id, "version_ref": ref})
        return ack.model_copy(update={"version_refs": [type(ack.version_refs[0]).model_validate(value) for value in refs]})


@asynccontextmanager
async def scope(authority=None, **job_updates):
    authority = authority or ScriptedAuthority()
    with operation(ingest_job(**job_updates)):
        async with intermediate_operation(stages(), authority) as state:
            yield state, authority


def frame(state, authority, stage="summary", seam="graphiti.summary_batch.v1"):
    selected = state.pins[stage]
    observation = Observation(selected, seam, Call(selected.id, seam), authority,
                              digest(canonical({"seam": seam, "v": 1})))
    return SeamFrame(state, observation, seam, "graphiti_fact_append_v1", {}, None)


async def read_nodes(state, values, *, returned=None):
    async def native(driver, names, group_ids):
        assert state.write_gate.locked() and state.read_owner is asyncio.current_task()
        assert not SAVE_ACTIVE.get() and state.write_owner is None
        return values if returned is None else returned
    read = wrap_read(native, "EntityNode.get_by_names", "EntityNode")
    return await read(driver(), [node.name for node in values], ["synthetic_group"])


async def test_registered_native_classmethod_waits_for_ack_and_preserves_exact_result_and_order():
    nodes = [EntityNode(name=name, group_id="synthetic_group", summary="Prior") for name in ("B", "A")]
    entered, release, consumed = asyncio.Event(), asyncio.Event(), []
    authority = ScriptedAuthority()
    async def waiting(page):
        assert page.seam_id == BOOTSTRAP_SEAM
        entered.set()
        await release.wait()
        return await authority(page)
    async with scope(waiting) as (state, _):
        async def consume():
            result = await read_nodes(state, nodes)
            consumed.append(result)
            return result
        task = asyncio.create_task(consume())
        try:
            await asyncio.wait_for(entered.wait(), 1)
            assert consumed == [] and state.write_gate.locked()
            release.set()
            assert await task is nodes
        finally:
            release.set()
            if not task.done():
                task.cancel()
            await asyncio.gather(task, return_exceptions=True)
        assert state.current(nodes[0]) is not None and not state.write_gate.locked()
    page, = authority.pages
    assert [entry.object_id for entry in page.entries if entry.kind == "deterministic_output"] == [
        "EntityNode:" + node.uuid for node in nodes]
    assert len(page.entries) == 6 and page.schema_digest == BOOTSTRAP_SCHEMA_DIGEST
    assert page.transform_id == BOOTSTRAP_TRANSFORM and page.phase == "inputs"
    assert page.base_context_ref is None and page.parent_contexts == [] and page.raw_body_sha256 is None
    assert all(entry.version_ref is None and entry.predecessor_version_ref is None for entry in page.entries)
    assert all(entry.projection_id == LOADER_PROJECTION for entry in page.entries if entry.kind == "deterministic_output")


async def test_partial_read_reuse_mutation_then_actual_embedding_keeps_full_and_view_predecessors_distinct():
    node = EntityNode(name="Synthetic", group_id="synthetic_group", summary="Prior")
    async with scope() as (state, authority):
        assert await read_nodes(state, [node]) == [node]
        key = "deterministic_output", node.uuid
        full = state.full_refs[key]
        assert full.value_hash is None and key not in state.versions
        current = frame(state, authority)
        await state.certify(current, [node], {"arguments": native_value([node])}, phase="inputs")
        read_entry = next(entry for entry in authority.pages[-1].entries if entry.object_id == node.uuid and entry.kind == key[0])
        assert read_entry.projection_id == LOADER_PROJECTION and read_entry.version_ref == full.version_ref
        assert state.full_refs[key] == full
        node.summary = "Prior\nSynthetic new fact"
        await state.certify(current, [node], {"before": "Prior", "after": node.summary}, phase="derived")
        first_view = next(entry for entry in authority.pages[-1].entries if entry.object_id.startswith("loader_view:"))
        first_proof = state.loader_views[key].proof
        first_version = state.versions[state.view_key(node)][1]
        assert first_view.predecessor_version_ref is None and first_view.version_ref is None
        assert first_view.value == native_value(node) and first_view.projection_id == "identity_v1"
        assert state.full_refs[key].version_ref == full.version_ref and state.full_refs[key].value_hash is None
        assert full.proof.manifest_ref in {p.manifest_ref for p in authority.pages[-1].parent_contexts}
        assert state.current(node)[1] == first_version
        node.summary += "\nAnother synthetic fact"
        await state.certify(current, [node], {"after": node.summary}, phase="derived")
        second_view = next(entry for entry in authority.pages[-1].entries if entry.object_id.startswith("loader_view:"))
        assert second_view.predecessor_version_ref == first_version
        assert first_proof.manifest_ref in {p.manifest_ref for p in authority.pages[-1].parent_contexts}
        second_proof = state.loader_views[key].proof
        # This represents an actual native embedding assignment. Root tests
        # separately bind real model response receipts and persistence.
        node.name_embedding = [0.0] * 1024
        await state.certify(current, [node], {"after": native_value(node)}, phase="derived")
        materialized = next(entry for entry in authority.pages[-1].entries if entry.object_id == node.uuid and entry.kind == key[0])
        assert materialized.predecessor_version_ref == full.version_ref
        assert materialized.projection_id == "identity_v1" and materialized.value["vector_commitments"]
        assert second_proof.manifest_ref in {p.manifest_ref for p in authority.pages[-1].parent_contexts}
        assert state.full_refs[key].value_hash == materialized.value_hash
        assert not state.full_refs[key].readable  # intermediate full != certified native SAVE


async def test_actual_pinned_get_by_names_retains_native_vector_omission_and_classmethod_binding():
    node = EntityNode(name="Synthetic", group_id="synthetic_group", summary="Prior", name_embedding=[0.0] * 1024)
    selected = driver()
    calls = []
    async def execute_query(query, **kwargs):
        calls.append(kwargs)
        return ([{"uuid": node.uuid, "name": node.name, "group_id": node.group_id,
            "created_at": node.created_at, "summary": node.summary, "labels": ["Entity"],
            "attributes": {"uuid": node.uuid, "name_embedding": node.name_embedding}}], None, None)
    selected.execute_query = execute_query
    original = EntityNode.__dict__["get_by_names"].__func__
    observed = wrap_read(original, "EntityNode.get_by_names", "EntityNode")
    async with scope() as (state, authority):
        result = await observed(EntityNode, selected, ["Synthetic"], ["synthetic_group"])
        assert len(calls) == 1 and len(result) == 1
        assert type(result[0]) is EntityNode and result[0].name_embedding is None
        entry = next(entry for entry in authority.pages[0].entries if entry.kind == "deterministic_output")
        assert entry.value["vector_commitments"] == {} and entry.projection_id == LOADER_PROJECTION
        assert state.full_refs[("deterministic_output", node.uuid)].value_hash is None


async def test_pinned_edge_similarity_reader_observes_before_native_rrf_can_consume_edge():
    from graphiti_core.search.search_utils import edge_similarity_search
    from graphiti_core.search.search_filters import SearchFilters
    edge = EntityEdge(name="RELATES", fact="Synthetic relationship", group_id="synthetic_group",
        source_node_uuid=str(uuid4()), target_node_uuid=str(uuid4()), episodes=[str(uuid4())],
        created_at=datetime(2026, 1, 1, tzinfo=timezone.utc), fact_embedding=[0.0] * 1024)
    selected, calls = driver(), []
    async def execute_query(query, **kwargs):
        calls.append(kwargs)
        record = edge.model_dump(mode="python", exclude={"fact_embedding"})
        record["attributes"] = {"fact_embedding": edge.fact_embedding}
        return [record], None, None
    selected.execute_query = execute_query
    observed = wrap_read(edge_similarity_search, "search_utils.edge_similarity_search", "EntityEdge")
    async with scope() as (state, authority):
        result = await observed(selected, [0.0] * 1024, None, None, SearchFilters(), ["synthetic_group"], 10)
        assert len(calls) == 1 and len(result) == 1 and type(result[0]) is EntityEdge
        assert result[0].fact_embedding is None and result[0].episodes == edge.episodes
        entry, = authority.pages[0].entries
        assert entry.kind == "edge" and entry.object_id == "EntityEdge:" + edge.uuid
        assert entry.projection_id == LOADER_PROJECTION and state.current(result[0]) is not None


async def test_prior_episode_bootstrap_is_full_identity_and_current_save_reload_skips_historical_bootstrap():
    episode = EpisodicNode(name="Prior", group_id="synthetic_group", content="Synthetic prior",
        source=EpisodeType.text, source_description="Synthetic", valid_at=datetime(2026, 1, 1, tzinfo=timezone.utc))
    async def native(cls, driver, uuids):
        return [episode]
    observed = wrap_read(native, "EpisodicNode.get_by_uuids", "EpisodicNode")
    async with scope() as (state, authority):
        assert await observed(EpisodicNode, driver(), [episode.uuid]) == [episode]
        entry, = authority.pages[0].entries
        assert entry.kind == "episode" and entry.projection_id == "identity_v1"
        assert entry.object_id == "EpisodicNode:" + episode.uuid
        assert state.current(episode) is not None
        count = len(authority.pages)
        await observed(EpisodicNode, driver(), [episode.uuid])
        assert len(authority.pages) == count
    async with scope() as (state, authority):
        current = frame(state, authority, "extraction", "graphiti.save.v1")
        current.save_method = "EpisodicNode.save"
        await state.certify(current, [episode], {"result": "component only"}, phase="derived")
        count = len(authority.pages)
        assert await observed(EpisodicNode, driver(), [episode.uuid]) == [episode]
        assert len(authority.pages) == count and state.full_refs[("episode", episode.uuid)].readable


async def test_bootstrap_pages_ten_objects_without_truncating_or_returning_partial_results():
    nodes = [EntityNode(name=f"Synthetic {index}", group_id="synthetic_group") for index in range(11)]
    async with scope() as (state, authority):
        assert await read_nodes(state, nodes) is nodes
        assert [len(page.entries) for page in authority.pages] == [30, 3]
        assert len({page.logical_call_id for page in authority.pages}) == 2
        assert all(page.final and page.page_index == 0 and page.previous_page_digest is None for page in authority.pages)
        before = len(authority.pages)
        assert await read_nodes(state, nodes) is nodes
        assert len(authority.pages) == before  # exact same-operation proof reuse


@pytest.mark.parametrize("failure", ["foreign", "custom", "conflict", "opaque", "overflow"])
async def test_bad_read_values_deny_before_transport_and_poison_operation(failure):
    node = EntityNode(name="Synthetic", group_id="synthetic_group")
    nodes = [node]
    returned = None
    if failure == "foreign":
        node.group_id = "foreign_group"
    elif failure == "custom":
        node.attributes = {"unqualified": "value"}
    elif failure == "conflict":
        nodes.append(node.model_copy(update={"summary": "Different"}))
    elif failure == "opaque":
        returned = [object()]
    elif failure == "overflow":
        nodes = [EntityNode(name=f"Synthetic {index}", group_id="synthetic_group") for index in range(101)]
    with pytest.raises(BoundaryError):
        async with scope() as (state, authority):
            try:
                await read_nodes(state, nodes, returned=returned)
            finally:
                assert state.failure is not None and not state.write_gate.locked()
                assert authority.pages == []


async def test_cache_cap_counts_full_read_and_scalar_entries_without_eviction():
    node = EntityNode(name="Synthetic", group_id="synthetic_group")
    with pytest.raises(BoundaryError, match="response_limit"):
        async with scope() as (state, authority):
            for index in range(98):
                state.versions[("deterministic_output", f"call:{index}")] = "1" * 64, str(uuid4()), Proof(str(uuid4()), "2" * 64, None)
            await read_nodes(state, [node])
    assert len(state.versions) == 98 and authority.pages == [] and state.loader_views == {}


@pytest.mark.parametrize("action", ["deny", "cancel"])
async def test_ack_failure_or_cancel_prevents_queued_read_and_save_delegates(action):
    held, release = asyncio.Event(), asyncio.Event()
    authority, calls = ScriptedAuthority(), []
    async def observe(page):
        held.set()
        await release.wait()
        ack = await authority(page)
        if action == "deny":
            return ack.model_copy(update={"state": "denied", "version_refs": [],
                "context_manifest_ref": None, "context_manifest_digest": None, "error_code": "closure_incomplete"})
        return ack
    async def native(driver, names, group_ids):
        calls.append("read")
        return [EntityNode(name="Synthetic", group_id="synthetic_group")]
    read = wrap_read(native, "EntityNode.get_by_names", "EntityNode")
    async def queued_save(state):
        async with state.save_scope("EntityNode.save"):
            calls.append("save")
    with pytest.raises(BoundaryError, match="closure_incomplete"):
        async with scope(observe) as (state, _):
            owner = asyncio.create_task(read(driver(), ["Synthetic"], ["synthetic_group"]))
            await asyncio.wait_for(held.wait(), 1)
            queued = [asyncio.create_task(read(driver(), [], [])), asyncio.create_task(queued_save(state))]
            try:
                if action == "cancel":
                    owner.cancel()
                release.set()
                outcomes = await asyncio.gather(owner, *queued, return_exceptions=True)
                assert all(isinstance(value, (BoundaryError, asyncio.CancelledError)) for value in outcomes)
                assert calls == ["read"] and state.failure == "closure_incomplete"
            finally:
                release.set()
                for task in [owner, *queued]:
                    if not task.done():
                        task.cancel()
                await asyncio.gather(owner, *queued, return_exceptions=True)


async def test_native_read_does_not_start_while_another_task_holds_save_gate():
    held, release = asyncio.Event(), asyncio.Event()
    calls = []
    async with scope() as (state, authority):
        async def saving():
            async with state.save_scope("EpisodicNode.save"):
                calls.append("save")
                held.set()
                await release.wait()
        async def native(driver, names, group_ids):
            calls.append("read")
            return []
        observed = wrap_read(native, "EntityNode.get_by_names", "EntityNode")
        writer = asyncio.create_task(saving())
        await asyncio.wait_for(held.wait(), 1)
        reader = asyncio.create_task(observed(driver(), [], []))
        try:
            await asyncio.sleep(0)
            assert calls == ["save"] and not reader.done()
            release.set()
            assert await reader == []
            await writer
        finally:
            release.set()
            for task in (writer, reader):
                if not task.done():
                    task.cancel()
            await asyncio.gather(writer, reader, return_exceptions=True)
        assert calls == ["save", "read"] and authority.pages == []


async def test_new_exact_episode_absence_is_not_a_failed_observation():
    async def absent(cls, driver, uuid):
        raise NodeNotFoundError(uuid)
    observed = wrap_read(absent, "EpisodicNode.get_by_uuid", "EpisodicNode")
    selected = ingest_job()
    with operation(selected):
        async with intermediate_operation(stages(), ScriptedAuthority()) as state:
            with pytest.raises(NodeNotFoundError):
                await observed(EpisodicNode, driver(), selected.args["episode_uuid"])
            assert state.failure is None and not state.write_gate.locked()


@pytest.mark.parametrize("profile", ["foreign_driver", "search_interface", "graph_interface", "wrong_class"])
async def test_unknown_native_reader_profile_denies_before_delegate_or_frame(profile):
    calls = []
    async def native(cls, driver, names, group_ids):
        calls.append("delegate")
        return []
    observed = wrap_read(native, "EntityNode.get_by_names", "EntityNode")
    selected = object() if profile == "foreign_driver" else driver()
    if profile == "search_interface":
        selected.search_interface = object()
    elif profile == "graph_interface":
        selected.graph_operations_interface = object()
    with pytest.raises(BoundaryError, match="closure_incomplete"):
        async with scope() as (state, authority):
            await observed(EpisodicNode if profile == "wrong_class" else EntityNode,
                           selected, ["Synthetic"], ["synthetic_group"])
    assert calls == [] and authority.pages == [] and state.failure == "closure_incomplete"


async def test_uncertified_staging_full_value_cannot_authorize_a_database_reload():
    node = EntityNode(name="Synthetic", group_id="synthetic_group", name_embedding=[0.0] * 1024)
    with pytest.raises(BoundaryError, match="reconcile_required"):
        async with scope() as (state, authority):
            current = frame(state, authority)
            await state.certify(current, [node], {"arguments": native_value(node)}, phase="inputs")
            assert not state.full_refs[("deterministic_output", node.uuid)].readable
            await read_nodes(state, [node])


async def test_changed_view_cannot_be_represented_as_an_unchanged_database_reload():
    node = EntityNode(name="Synthetic", group_id="synthetic_group", summary="Prior")
    original = node.model_copy(deep=True)
    with pytest.raises(BoundaryError, match="reconcile_required"):
        async with scope() as (state, authority):
            await read_nodes(state, [node])
            current = frame(state, authority)
            node.summary = "Changed before native embedding"
            await state.certify(current, [node], {"after": node.summary}, phase="derived")
            assert state.loader_views[("deterministic_output", node.uuid)].mutated
            await read_nodes(state, [original])


def test_projection_and_schema_are_closed_and_codecs_keep_view_hash_meaning():
    node = EntityNode(name="Synthetic", group_id="synthetic_group", name_embedding=[0.0] * 1024)
    full = native_value(node)
    projected = without_vector(full)
    assert projected["fields"] == full["fields"] and projected["object_type"] == full["object_type"]
    assert projected["vector_commitments"] == {} and full["vector_commitments"]
    assert digest(canonical(bootstrap_schema())) == BOOTSTRAP_SCHEMA_DIGEST
    assert native_read_policy()["operation_cache_entries"] == 100
    for route, kind in [("EntityNode.get_by_group_ids", "EntityNode"),
                        ("search_utils.edge_similarity_search", "EntityNode")]:
        with pytest.raises(BoundaryError):
            wrap_read(lambda: None, route, kind)
    for changed in [{**full, "object_type": "Unknown"}, {**full, "extra": 1},
                    {**full, "fields": {**full["fields"], "attributes": {"custom": 1}}}]:
        with pytest.raises(BoundaryError):
            without_vector(changed)
    value = {"entry_id": str(uuid4()), "kind": "deterministic_output", "object_id": "EntityNode:" + node.uuid,
        "version_ref": None, "predecessor_version_ref": None, "value": projected,
        "value_hash": digest(canonical(projected)), "projection_hash": digest(canonical(projected)),
        "projection_id": LOADER_PROJECTION, "parent_manifest_ref": str(uuid4()),
        "parent_manifest_digest": "1" * 64, "receipt_ref": None}
    assert ContextEntry.model_validate(value)
    with pytest.raises(ValidationError):
        ContextEntry.model_validate({**value, "projection_hash": "0" * 64})


def test_install_replaces_actual_imported_bindings_and_preserves_classmethod_descriptor(monkeypatch):
    import importlib
    from graphiti_core import nodes, edges
    from graphiti_core.utils.maintenance import node_operations, edge_operations
    from read_observations import install_read_hooks
    search_utils = importlib.import_module("graphiti_core.search.search_utils")
    search = importlib.import_module("graphiti_core.search.search")
    graph = importlib.import_module("graphiti_core.graphiti")
    # Register restoration BEFORE installer mutations, so this test cannot
    # change the native source bindings used by other component tests.
    for cls in (nodes.EpisodicNode, nodes.EntityNode, edges.EntityEdge, edges.EpisodicEdge):
        for name, value in tuple(vars(cls).items()):
            if (isinstance(value, classmethod) and name.startswith("get_")) or name.startswith("load_"):
                monkeypatch.setattr(cls, name, value)
    for module in (search_utils, search, node_operations, edge_operations, graph):
        for name, value in tuple(vars(module).items()):
            if callable(value) and getattr(search_utils, name, None) is value:
                monkeypatch.setattr(module, name, value)
    original = nodes.EntityNode.__dict__["get_by_names"].__func__
    similarity = search_utils.node_similarity_search
    edge_similarity = search_utils.edge_similarity_search
    install_read_hooks()
    descriptor = nodes.EntityNode.__dict__["get_by_names"]
    assert isinstance(descriptor, classmethod) and descriptor.__func__.__wrapped__ is original
    assert search_utils.node_similarity_search.__wrapped__ is similarity
    assert node_operations.node_similarity_search is search_utils.node_similarity_search
    assert search.edge_similarity_search is search_utils.edge_similarity_search
    assert search.edge_similarity_search.__wrapped__ is edge_similarity
