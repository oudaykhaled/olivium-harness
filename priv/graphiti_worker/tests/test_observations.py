"""Strict observer/IPC controls with synthetic ACKs; no inventory/backend claim."""
import asyncio
import io
from datetime import datetime, timezone

import httpx
import pytest
from openai import AsyncOpenAI
from pydantic import ValidationError
from graphiti_core.llm_client import LLMRuntime, LLMTransport
from graphiti_core.nodes import EntityNode, EpisodicNode, EpisodeType
from graphiti_core.edges import EntityEdge, EpisodicEdge
from graphiti_core.driver.neo4j_driver import Neo4jDriver
from neo4j import EagerResult, Record
from graphiti_core.utils.maintenance import node_operations, edge_operations

from fixtures.helpers import context_reply, job, pin, reply
from ipc_transport import IPCTransport
from lineage import call, operation
from observations import (CURRENT_OBSERVATION, CURRENT_SEAM, SAVE_INVOCATION, Call, Observation, Proof, SeamFrame,
                          _guard_bulk_transaction, _save_completion, _wrap_async, _wrap_temporal, intermediate_operation,
                          native_value, observed_call)
from protocol import (Boot, BoundaryError, ContextAck, ContextEntry, ContextPage,
                      Frame, Job, canonical, digest, stage_set_digest)
from runtime import MeteredGeneric, ObservedRuntime, Runtime
from worker import Server


def boot(pins=None):
    pins = pins or []
    return Boot(source_lock_digest="1" * 64, backend_pin_digest="2" * 64,
                backend_uri="bolt://127.0.0.1:7687", backend_user="synthetic",
                backend_password="synthetic", database="neo4j", stage_pins=pins,
                stage_set_digest=stage_set_digest(pins))


def test_stage_set_digest_is_order_independent_and_rejects_duplicate_identity_or_stage():
    a = pin("extraction", "http://127.0.0.1:11434/v1/chat/completions")
    b = pin("summary", "http://127.0.0.1:11434/v1/chat/completions")
    assert stage_set_digest([a, b]) == stage_set_digest([b, a])
    assert boot([]).stage_set_digest == stage_set_digest([])
    with pytest.raises(ValueError, match="duplicate"):
        stage_set_digest([a, a])
    changed = a.model_dump()
    changed["id"] = "different:id"
    changed["config_digest"] = digest(canonical({k: v for k, v in changed.items() if k != "config_digest"}))
    with pytest.raises(ValueError, match="duplicate"):
        stage_set_digest([a, changed])
    with pytest.raises(ValidationError):
        Boot.model_validate({**boot().model_dump(), "stage_set_digest": "0" * 64})


def test_job_controls_are_required_and_private_control_tokens_never_cross_wire():
    selected = job()
    for change in [{"partition_id": None}, {"lease_id": None}, {"operation_token": "forbidden"},
                   {"control_token": "forbidden"}]:
        with pytest.raises(ValidationError):
            Job.model_validate({**selected.model_dump(), **change})
    diagnostic = job("health", partition_id=None, lease_id=None, scope_ref="worker:health",
                     closure_ref="source-lock", semantic_generation=0, authorization_generation=0,
                     cancel_epoch=0, deadline_ms=1000, args={})
    assert diagnostic.partition_id is None
    with pytest.raises(ValidationError):
        Job.model_validate({**diagnostic.model_dump(), "scope_ref": "foreign"})


async def test_unobserved_or_unsealed_requests_emit_zero_attempts():
    emitted = []
    async def relay(attempt):
        emitted.append(attempt)
        return reply(attempt, {})
    stage = pin("embedder", "http://127.0.0.1:11434/v1/embeddings")
    async def deny(page):
        return ContextAck(job_id=page.job_id, context_id=page.context_id, page_index=0,
            page_digest=digest(canonical(page.model_dump())), state="denied", version_refs=[],
            context_manifest_ref=None, context_manifest_digest=None, allowed_body_sha256=None,
            error_code="closure_incomplete")
    async with httpx.AsyncClient(transport=IPCTransport(stage, relay, asyncio.Semaphore(1))) as client:
        with operation(job()), call(stage.id, "embedder.create"), pytest.raises(BoundaryError, match="closure_incomplete"):
            await client.post(stage.endpoint, json={"model": stage.model, "input": ["synthetic"]})
        with operation(job()), pytest.raises(BoundaryError, match="closure_incomplete"):
            async with observed_call(stage, "embedder.create", ["synthetic"], deny, embed=True):
                await client.post(stage.endpoint, json={"model": stage.model, "input": ["synthetic"]})
    assert emitted == []


async def test_actual_raw_body_requires_its_own_separate_sealed_context():
    pages, emitted = [], []
    async def observe(page):
        pages.append(page)
        return await context_reply(page)
    async def relay(attempt):
        emitted.append(attempt)
        return reply(attempt, {})
    stage = pin("embedder", "http://127.0.0.1:11434/v1/embeddings")
    async with httpx.AsyncClient(transport=IPCTransport(stage, relay, asyncio.Semaphore(1))) as client:
        selected = job()
        with operation(selected):
            async with observed_call(stage, "embedder.create", ["synthetic"], observe, embed=True):
                await client.post(stage.endpoint, content=b'{"model":"synthetic-fixture-v1","input":["synthetic"]}')
    assert [p.phase for p in pages] == ["inputs", "attempt_bind", "derived"]
    assert pages[-1].seam_id == "llm.response.v1"
    assert pages[-1].entries[0].receipt_ref is not None
    assert pages[-1].entries[0].value["body_sha256"] == digest(b"{}")
    assert pages[1].raw_body_sha256 == emitted[0].payload_sha256
    assert emitted[0].closure_ref == selected.closure_ref
    assert emitted[0].context_manifest_ref != selected.closure_ref
    assert pages[1].base_context_ref is not None
    assert pages[1].entries[0].value == ["synthetic"]


async def test_mismatched_ack_or_raw_binding_cannot_emit_an_attempt():
    emitted = []
    async def observe(page):
        ack = await context_reply(page)
        if page.phase == "attempt_bind":
            return ack.model_copy(update={"allowed_body_sha256": "0" * 64})
        return ack
    async def relay(attempt):
        emitted.append(attempt)
        return reply(attempt, {})
    stage = pin("embedder", "http://127.0.0.1:11434/v1/embeddings")
    async with httpx.AsyncClient(transport=IPCTransport(stage, relay, asyncio.Semaphore(1))) as client:
        with operation(job()), pytest.raises(BoundaryError, match="closure_incomplete"):
            async with observed_call(stage, "embedder.create", ["synthetic"], observe, embed=True):
                await client.post(stage.endpoint, json={"model": stage.model, "input": ["synthetic"]})
    assert emitted == []


async def test_observed_runtime_delegates_once_and_denies_unreceipted_logical_output(monkeypatch):
    delegated, pages = [], []
    async def observe(page):
        pages.append(page)
        return await context_reply(page)
    async def relay(attempt):
        raise AssertionError("This delegate test must not dispatch")
    stage = pin("extraction", "http://127.0.0.1:11434/v1/chat/completions")
    async with httpx.AsyncClient(transport=IPCTransport(stage, relay, asyncio.Semaphore(1))) as http:
        client = MeteredGeneric(stage, AsyncOpenAI(api_key="ipc-placeholder", base_url="http://127.0.0.1:11434/v1/", http_client=http, max_retries=0))
        async def native_once(self, prompt_name, context, **kwargs):
            assert pages and CURRENT_OBSERVATION.get().base is not None
            delegated.append((prompt_name, context.copy()))
            context["episode_content"] = "changed only in private copy"
            return {"extracted_entities": []}
        monkeypatch.setattr(LLMRuntime, "complete", native_once)
        runtime = ObservedRuntime(LLMTransport(client, models=[stage.model]).model(stage.model), observer_relay=observe)
        context = {"episode_content": "Synthetic input"}
        with operation(job()), pytest.raises(BoundaryError, match="closure_incomplete"):
            await runtime.complete("extract_nodes.extract_text", context)
        assert context == {"episode_content": "Synthetic input"}
    assert len(delegated) == 1


async def test_context_schema_bounds_hashes_and_unknown_fields():
    captured = []
    async def observe(page):
        captured.append(page)
        return await context_reply(page)
    with operation(job()):
        async with observed_call(pin(), "dedupe_nodes.nodes", {"synthetic": True}, observe):
            pass
    value = captured[0].model_dump()
    for change in [{"operation_token": "forbidden"}, {"entries": value["entries"] * 101},
                   {"transform_id": "arbitrary-code"}, {"previous_page_digest": "0" * 64}]:
        with pytest.raises(ValidationError):
            ContextPage.model_validate({**value, **change})
    entry = value["entries"][0]
    with pytest.raises(ValidationError):
        ContextEntry.model_validate({**entry, "value": "changed"})
    huge = "x" * 16385
    with pytest.raises(ValidationError):
        ContextEntry.model_validate({**entry, "value": huge, "value_hash": digest(canonical(huge)),
                                     "projection_hash": digest(canonical(huge))})


async def test_session_mismatch_is_denied_without_dispatch():
    server = Server(asyncio.StreamReader(), io.BytesIO())
    server.session = "session:synthetic"
    selected = job(worker_session_id="session:foreign")
    async with asyncio.TaskGroup() as tasks:
        with pytest.raises(BoundaryError, match="scope_denied"):
            await server._receive(Frame(v=1, kind="job", session_id=server.session, seq=1,
                request_id="request:synthetic", payload=selected.model_dump()), tasks)
    assert server.jobs == {}


async def test_ingest_and_removal_stay_denied_before_backend_open():
    configured = boot()
    async def relay(attempt):
        raise AssertionError("No attempt may emit")
    runtime = Runtime(configured, relay, session_id="session:synthetic")
    body = "Synthetic input"
    ingest = job("ingest", stage_set_digest=configured.stage_set_digest, args={
        "binding_id": "binding:synthetic", "episode_uuid": "episode:synthetic", "revision_id": "revision:synthetic",
        "body_hash": digest(body.encode()), "window_start": 0, "window_end": len(body), "body": body,
        "reference_time": "2026-01-01T00:00:00Z", "time_basis": "event", "prior_episode_ids": []})
    removal = job("remove", stage_set_digest=configured.stage_set_digest, args={
        "episode_uuid": "episode:synthetic", "purge_fence_id": "purge:synthetic", "rebuild_closure_ref": "manifest:fixture"})
    with pytest.raises(BoundaryError, match="closure_incomplete"):
        await runtime.execute(ingest)
    with pytest.raises(BoundaryError, match="purge_denied"):
        await runtime.execute(removal)
    assert runtime.graph is None


async def test_parent_handles_and_predecessors_are_explicit_strict_and_bounded():
    pages = []
    async def observe(page):
        pages.append(page)
        return await context_reply(page)
    with operation(job()):
        async with observed_call(pin(), "dedupe_nodes.nodes", {"synthetic": True}, observe):
            pass
    page = pages[0].model_dump()
    assert page["parent_contexts"] == []
    assert page["entries"][0]["predecessor_version_ref"] is None
    parent = {"manifest_ref": "manifest:parent", "manifest_digest": "8" * 64}
    assert ContextPage.model_validate({**page, "parent_contexts": [parent]})
    for parents in [[parent, parent], [parent] * 101, [{**parent, "authority": True}]]:
        with pytest.raises(ValidationError):
            ContextPage.model_validate({**page, "parent_contexts": parents})
    missing = page["entries"][0].copy()
    del missing["predecessor_version_ref"]
    with pytest.raises(ValidationError):
        ContextEntry.model_validate(missing)
    count = len(pages)
    with operation(job()), pytest.raises(BoundaryError, match="reconcile_required"):
        stage = pin()
        observation = Observation(stage, "dedupe_nodes.nodes", Call(stage.id, "dedupe_nodes.nodes"), observe, "2" * 64)
        observation.parents = [Proof("manifest:parent", "7" * 64, None), Proof("manifest:parent", "8" * 64, None)]
        await observation.attest([observation.entry("deterministic_output", {"synthetic": True}, "identity_v1")],
                                 seam="llm.context.v1", phase="inputs", transform="identity_v1")
    assert len(pages) == count


async def test_real_native_attribute_return_is_acknowledged_before_caller_assignment():
    pages = []
    node = EntityNode(name="Synthetic owner", group_id="synthetic_group", attributes={"owner": "Prior"})
    async def observe(page):
        pages.append(page)
        assert node.attributes == {"owner": "Prior"}
        return await context_reply(page)
    wrapped = _wrap_async(node_operations._extract_entity_attributes, "graphiti.attributes.v1",
                          "graphiti_attribute_overlay_v1", "extraction")
    with operation(job("ingest", args={"binding_id": "binding:synthetic", "episode_uuid": "episode:synthetic",
        "revision_id": "revision:synthetic", "body": "Synthetic", "body_hash": digest(b"Synthetic"),
        "window_start": 0, "window_end": 9, "reference_time": "2026-01-01T00:00:00Z",
        "time_basis": "event", "prior_episode_ids": []})):
        async with intermediate_operation({"extraction": pin("extraction", "http://127.0.0.1:11434/v1/chat/completions")}, observe):
            attributes = await wrapped(None, node, None, None, None)
            node.attributes = attributes
    assert [page.phase for page in pages] == ["inputs", "derived"]
    assert any(entry.kind == "attribute" for entry in pages[-1].entries)
    assert pages[-1].base_context_ref is not None


async def test_real_native_no_llm_fact_append_is_sealed_before_next_consumer():
    pages, consumed = [], []
    node = EntityNode(name="Synthetic owner", group_id="synthetic_group", summary="Prior")
    edge = EntityEdge(name="RELATES", group_id="synthetic_group", source_node_uuid=node.uuid,
                      target_node_uuid="node:synthetic", fact="New synthetic fact", episodes=["episode:synthetic"],
                      created_at=datetime(2026, 1, 1, tzinfo=timezone.utc))
    async def deny_derived(page):
        pages.append(page)
        ack = await context_reply(page)
        if page.phase == "derived":
            return ack.model_copy(update={"state": "denied", "version_refs": [], "context_manifest_ref": None,
                "context_manifest_digest": None, "allowed_body_sha256": None, "error_code": "closure_incomplete"})
        return ack
    wrapped = _wrap_async(node_operations._extract_entity_summaries_batch, "graphiti.summary_batch.v1",
                          "graphiti_fact_append_v1", "summary")
    with operation(job()), pytest.raises(BoundaryError, match="closure_incomplete"):
        async with intermediate_operation({"summary": pin("summary", "http://127.0.0.1:11434/v1/chat/completions")}, deny_derived):
            await wrapped(None, [node], None, None, None, {node.uuid: [edge]})
            consumed.append(node.summary)
    assert node.summary == "Prior\nNew synthetic fact"  # native mutation occurred in memory
    assert consumed == []
    assert pages[-1].transform_id == "graphiti_fact_append_v1"
    summary = next(entry for entry in pages[-1].entries if entry.kind == "summary")
    assert summary.predecessor_version_ref is not None


async def test_native_batch_acknowledges_fact_append_before_a_later_flight(monkeypatch):
    pages, flight_calls = [], []
    short = EntityNode(name="Synthetic short", group_id="synthetic_group", summary="Prior")
    long = EntityNode(name="Synthetic long", group_id="synthetic_group", summary="L" * 2001)
    edge = EntityEdge(name="RELATES", group_id="synthetic_group", source_node_uuid=short.uuid,
                      target_node_uuid=long.uuid, fact="Synthetic appended fact", episodes=["episode:synthetic"],
                      created_at=datetime(2026, 1, 1, tzinfo=timezone.utc))
    async def observe(page):
        pages.append(page)
        return await context_reply(page)
    async def flight(llm_client, nodes, episode, previous_episodes, *, use_episode_prompt=False,
                     entity_types=None, clients=None):
        flight_calls.append(nodes)
        assert short.summary == "Prior\nSynthetic appended fact"
        assert any(page.phase == "derived" and page.transform_id == "graphiti_fact_append_v1"
                   and any(entry.kind == "summary" and entry.object_id == short.uuid
                           and entry.value == short.summary for entry in page.entries) for page in pages)
    monkeypatch.setattr(node_operations, "_process_summary_flight", _wrap_async(flight,
        "graphiti.summary_flight.v1", "graphiti_summary_flight_v1", "summary"))
    batch = _wrap_async(node_operations._extract_entity_summaries_batch, "graphiti.summary_batch.v1",
                         "graphiti_fact_append_v1", "summary")
    with operation(job()):
        async with intermediate_operation({"summary": pin("summary", "http://127.0.0.1:11434/v1/chat/completions")}, observe):
            await batch(None, [short, long], None, None, None, {short.uuid: [edge]})
    assert flight_calls == [[long]]


async def test_temporal_transition_requires_certified_inputs_and_drains_before_consumption():
    pages = []
    stage = pin("edge_dedupe")
    async def observe(page):
        pages.append(page)
        return await context_reply(page)
    older = EntityEdge(name="RELATES", source_node_uuid="node:a", target_node_uuid="node:b",
        group_id="synthetic_group", fact="Older", episodes=["episode:older"],
        created_at=datetime(2026, 1, 1, tzinfo=timezone.utc),
        valid_at=datetime(2025, 1, 1, tzinfo=timezone.utc))
    newer = EntityEdge(name="RELATES", source_node_uuid="node:a", target_node_uuid="node:b",
        group_id="synthetic_group", fact="Newer", episodes=["episode:newer"],
        created_at=datetime(2026, 1, 1, tzinfo=timezone.utc),
        valid_at=datetime(2026, 1, 1, tzinfo=timezone.utc))
    temporal = _wrap_temporal(edge_operations._apply_temporal_invalidation)
    with operation(job()):
        async with intermediate_operation({"edge_dedupe": stage}, observe) as state:
            observation = Observation(stage, "graphiti.extract_edges.v1", Call(stage.id, "graphiti.extract_edges.v1"),
                                      observe, "2" * 64)
            frame = SeamFrame(state, observation, "graphiti.extract_edges.v1", "graphiti_extract_edges_v1",
                              {"edges": [newer, older]}, None)
            token = CURRENT_SEAM.set(frame)
            try:
                with pytest.raises(BoundaryError, match="closure_incomplete"):
                    temporal(newer, [older])
                await state.certify(frame, frame.arguments, {"synthetic": True}, phase="inputs")
                temporal(newer, [older])
                assert older.invalid_at == newer.valid_at
                assert state.pending
                await state.flush()
                assert not state.pending
                assert state.current(older) is not None
                assert frame.children
            finally:
                CURRENT_SEAM.reset(token)
    assert any(page.seam_id == "graphiti.temporal.v1" for page in pages)


def test_complete_edge_support_is_never_silently_shortened_and_vectors_are_committed():
    edge = EntityEdge(name="RELATES", source_node_uuid="node:a", target_node_uuid="node:b",
                      group_id="synthetic_group", fact="Synthetic", episodes=[f"episode:{i}" for i in range(101)],
                      created_at=datetime(2026, 1, 1, tzinfo=timezone.utc))
    with pytest.raises(BoundaryError, match="response_limit"):
        native_value(edge)
    node = EntityNode(name="Synthetic", group_id="synthetic_group", name_embedding=[0.0] * 1024)
    projection = native_value(node)
    commitment = projection["vector_commitments"]["name_embedding"]
    assert commitment == {"format": "ieee754-be-f64-v1", "length": 1024, "sha256": digest(b"\0" * 8192)}
    assert "name_embedding" not in projection["fields"]


async def test_intermediate_input_denial_prevents_the_native_delegate():
    calls = []
    async def native(episode=None):
        calls.append(episode)
        return []
    async def deny(page):
        ack = await context_reply(page)
        return ack.model_copy(update={"state": "denied", "version_refs": [], "context_manifest_ref": None,
            "context_manifest_digest": None, "error_code": "closure_incomplete"})
    wrapped = _wrap_async(native, "graphiti.extract_nodes.v1", "graphiti_extract_nodes_v1", "extraction")
    with operation(job()), pytest.raises(BoundaryError, match="closure_incomplete"):
        async with intermediate_operation({"extraction": pin("extraction", "http://127.0.0.1:11434/v1/chat/completions")}, deny):
            await wrapped()
    assert calls == []


def _save_object(kind):
    common = {"group_id": "synthetic_group"}
    if kind == "EntityNode":
        return EntityNode(name="Synthetic", **common)
    if kind == "EpisodicNode":
        return EpisodicNode(name="Synthetic", source=EpisodeType.text, source_description="Synthetic",
            content="Synthetic", valid_at=datetime(2026, 1, 1, tzinfo=timezone.utc), **common)
    edge = dict(source_node_uuid="node:source", target_node_uuid="node:target",
                created_at=datetime(2026, 1, 1, tzinfo=timezone.utc), **common)
    if kind == "EntityEdge":
        return EntityEdge(name="RELATES", fact="Synthetic", episodes=["episode:synthetic"], **edge)
    return EpisodicEdge(**edge)


def _eager_uuid(uuid):
    # Real pinned driver classes; the deliberately opaque summary must never be
    # inspected, dumped, stringified or serialized by the descriptor projector.
    return EagerResult(records=[Record([("uuid", uuid)])], summary=object(), keys=["uuid"])


def _save_driver(result, calls):
    driver = object.__new__(Neo4jDriver)
    async def execute_query(*args, **kwargs):
        calls.append("delegated")
        return result
    driver.execute_query = execute_query
    return driver


@pytest.mark.parametrize("kind", ["EntityNode", "EpisodicNode", "EntityEdge", "EpisodicEdge"])
async def test_actual_individual_save_returns_same_eager_result_only_after_descriptor_ack(kind):
    obj, pages, calls = _save_object(kind), [], []
    result = _eager_uuid(obj.uuid)
    driver = _save_driver(result, calls)
    derived, release = asyncio.Event(), asyncio.Event()
    async def observe(page):
        pages.append(page)
        if page.phase == "derived":
            derived.set()
            await release.wait()
        return await context_reply(page)
    wrapped = _wrap_async(type(obj).save, "graphiti.save.v1", "graphiti_save_v1", "extraction",
                          save=True, save_method=kind + ".save")
    with operation(job()):
        async with intermediate_operation({"extraction": pin("extraction",
                "http://127.0.0.1:11434/v1/chat/completions")}, observe):
            task = asyncio.create_task(wrapped(obj, driver))
            try:
                await asyncio.wait_for(derived.wait(), 1)
                assert not task.done() and calls == ["delegated"]
                details = [entry for entry in pages[-1].entries if entry.kind == "deterministic_output"
                           and isinstance(entry.value, dict) and set(entry.value) == {"before", "after", "result"}]
                assert len(details) == 1
                detail = details[0]
                assert detail.projection_id == "identity_v1"
                assert detail.value["result"] == {"format": "native-save-completion-v1",
                    "method": kind + ".save", "return_kind": "neo4j-eager-uuid", "returned_uuid": obj.uuid}
                assert detail.value["before"] == detail.value["after"] == {"object": native_value(obj)}
            finally:
                release.set()
                returned = await task
            assert returned is result
    assert [page.phase for page in pages] == ["inputs", "derived"]


@pytest.mark.parametrize("invalid", ["wrong_keys", "missing", "multiple", "record_keys", "extra_record_key",
    "duplicate_record_key", "mismatched_uuid", "uuid_type", "mapping_record", "tuple_result", "unknown"])
async def test_invalid_native_save_return_denies_after_one_delegate_and_poisoning(invalid):
    obj, calls, pages = _save_object("EpisodicNode"), [], []
    result = _eager_uuid(obj.uuid)
    changes = {
        "wrong_keys": {"keys": ["other"]}, "missing": {"records": []},
        "multiple": {"records": result.records * 2},
        "record_keys": {"records": [Record([("other", obj.uuid)])]},
        "extra_record_key": {"records": [Record([("uuid", obj.uuid), ("other", "private")])]},
        "duplicate_record_key": {"records": [Record([("uuid", obj.uuid), ("uuid", obj.uuid)])]},
        "mismatched_uuid": {"records": [Record([("uuid", "foreign:uuid")])]},
        "uuid_type": {"records": [Record([("uuid", 7)])]},
        "mapping_record": {"records": [{"uuid": obj.uuid}]},
    }
    if invalid in changes:
        result = result._replace(**changes[invalid])
    elif invalid == "tuple_result":
        result = tuple(result)
    else:
        result = object()
    async def observe(page):
        pages.append(page)
        return await context_reply(page)
    wrapped = _wrap_async(EpisodicNode.save, "graphiti.save.v1", "graphiti_save_v1", "extraction",
                          save=True, save_method="EpisodicNode.save")
    with operation(job()), pytest.raises(BoundaryError, match="closure_incomplete"):
        async with intermediate_operation({"extraction": pin("extraction",
                "http://127.0.0.1:11434/v1/chat/completions")}, observe) as state:
            await wrapped(obj, _save_driver(result, calls))
    assert calls == ["delegated"] and state.failure == "closure_incomplete"
    assert [page.phase for page in pages] == ["inputs"]


async def test_save_ack_denial_poisoning_keeps_original_write_uncertain_without_retry():
    obj, calls = _save_object("EntityNode"), []
    async def deny(page):
        ack = await context_reply(page)
        if page.phase == "derived":
            return ack.model_copy(update={"state": "denied", "version_refs": [], "context_manifest_ref": None,
                "context_manifest_digest": None, "error_code": "closure_incomplete"})
        return ack
    wrapped = _wrap_async(EntityNode.save, "graphiti.save.v1", "graphiti_save_v1", "extraction",
                          save=True, save_method="EntityNode.save")
    with operation(job()), pytest.raises(BoundaryError, match="closure_incomplete"):
        async with intermediate_operation({"extraction": pin("extraction",
                "http://127.0.0.1:11434/v1/chat/completions")}, deny) as state:
            await wrapped(obj, _save_driver(_eager_uuid(obj.uuid), calls))
    assert calls == ["delegated"] and state.failure == "closure_incomplete"


async def test_unqualified_save_profile_or_method_denies_before_native_delegation():
    obj, calls, pages = _save_object("EntityNode"), [], []
    driver = _save_driver(_eager_uuid(obj.uuid), calls)
    driver.graph_operations_interface = object()
    async def observe(page):
        pages.append(page)
        return await context_reply(page)
    for method in ("EntityNode.save", "CommunityNode.save", None):
        wrapped = _wrap_async(EntityNode.save, "graphiti.save.v1", "graphiti_save_v1", "extraction",
                              save=True, save_method=method)
        with operation(job()), pytest.raises(BoundaryError, match="closure_incomplete"):
            async with intermediate_operation({"extraction": pin("extraction",
                    "http://127.0.0.1:11434/v1/chat/completions")}, observe):
                await wrapped(obj, driver)
    assert calls == pages == []


async def test_native_bulk_none_is_named_but_structured_save_domain_return_stays_native():
    from graphiti_core.utils import bulk_utils
    calls, pages = [], []
    driver = object.__new__(Neo4jDriver)
    class Session:
        async def execute_write(self, *args, **kwargs):
            calls.append("write")
        async def close(self):
            calls.append("close")
    driver.session = Session
    async def observe(page):
        pages.append(page)
        return await context_reply(page)
    bulk = _wrap_async(bulk_utils.add_nodes_and_edges_bulk, "graphiti.save.v1", "graphiti_save_v1", "extraction",
                       save=True, save_method="add_nodes_and_edges_bulk")
    domain_return = ([], _save_object("EpisodicNode"))
    async def structured():
        return domain_return
    domain = _wrap_async(structured, "graphiti.save.v1", "graphiti_save_v1", "extraction")
    with operation(job()):
        async with intermediate_operation({"extraction": pin("extraction",
                "http://127.0.0.1:11434/v1/chat/completions")}, observe):
            assert await bulk(driver, [], [], [], [], None) is None
            assert await domain() is domain_return
    details = [entry.value for page in pages if page.phase == "derived" for entry in page.entries
               if entry.kind == "deterministic_output"]
    assert calls == ["write", "close"]
    assert details[0]["result"] == {"format": "native-save-completion-v1", "method": "add_nodes_and_edges_bulk",
                                    "return_kind": "none", "returned_uuid": None}
    assert details[1]["result"] == native_value(domain_return)
    for unknown in [object(), (), _eager_uuid("foreign:uuid")]:
        with pytest.raises(BoundaryError, match="closure_incomplete"):
            _save_completion("add_nodes_and_edges_bulk", unknown, None)
    with pytest.raises(BoundaryError, match="closure_incomplete"):
        native_value(_eager_uuid(domain_return[1].uuid))


async def test_shared_save_gate_excludes_nested_gather_writers_before_capture_until_ack():
    nodes = [_save_object("EntityNode") for _ in range(3)]
    results = {node.uuid: _eager_uuid(node.uuid) for node in nodes}
    calls, pages, entered = [], [], []
    held, release, queued = asyncio.Event(), asyncio.Event(), asyncio.Event()
    driver = object.__new__(Neo4jDriver)
    async def execute_query(*args, **kwargs):
        uuid = kwargs["entity_data"]["uuid"]
        calls.append(uuid)
        return results[uuid]
    driver.execute_query = execute_query
    async def observe(page):
        pages.append(page)
        if page.phase == "derived" and not held.is_set():
            held.set()
            await release.wait()
        return await context_reply(page)
    save = _wrap_async(EntityNode.save, "graphiti.save.v1", "graphiti_save_v1", "extraction",
                      save=True, save_method="EntityNode.save")
    async def write(node):
        entered.append(node.uuid)
        if len(entered) == 3:
            queued.set()
        result = await save(node, driver)
        assert result is results[node.uuid]
    async def nested():
        await asyncio.gather(write(nodes[1]), write(nodes[2]))
    async def process():
        # Like _process_episode_data, this domain-returning coordinator must not
        # acquire the non-reentrant write gate around its nested save calls.
        await asyncio.gather(write(nodes[0]), nested())
        return nodes
    coordinator = _wrap_async(process, "graphiti.save.v1", "graphiti_save_v1", "extraction")
    with operation(job()):
        async with intermediate_operation({"extraction": pin("extraction",
                "http://127.0.0.1:11434/v1/chat/completions")}, observe) as state:
            task = asyncio.create_task(coordinator())
            try:
                await asyncio.wait_for(held.wait(), 1)
                await asyncio.wait_for(queued.wait(), 1)
                assert calls == [nodes[0].uuid] and state.write_gate.locked()
                object_inputs = [page for page in pages if page.phase == "inputs"
                    and any(isinstance(entry.value, dict) and set(entry.value) == {"arguments"}
                            and "object" in entry.value["arguments"] for entry in page.entries)]
                assert len(object_inputs) == 1
                nodes[1].summary = "Changed while queued, before capture"
            finally:
                release.set()
                returned = await task
            assert returned is nodes
            assert len(calls) == 3 and len(set(calls)) == 3
            assert not state.write_gate.locked() and state.write_owner is state.write_invocation is None
    queued_input = next(entry.value["arguments"]["object"] for page in pages if page.phase == "inputs"
        for entry in page.entries if isinstance(entry.value, dict) and set(entry.value) == {"arguments"}
        and entry.value["arguments"].get("object", {}).get("fields", {}).get("uuid") == nodes[1].uuid)
    assert queued_input["fields"]["summary"] == "Changed while queued, before capture"


@pytest.mark.parametrize("failure", ["denied_ack", "relay_error", "cancel_owner", "cancel_waiter"])
async def test_failed_save_gate_poisoning_prevents_all_queued_native_delegation(failure):
    nodes = [_save_object("EntityNode") for _ in range(3)]
    held, release, queued = asyncio.Event(), asyncio.Event(), asyncio.Event()
    calls = []
    driver = object.__new__(Neo4jDriver)
    async def execute_query(*args, **kwargs):
        uuid = kwargs["entity_data"]["uuid"]
        calls.append(uuid)
        return _eager_uuid(uuid)
    driver.execute_query = execute_query
    async def observe(page):
        ack = await context_reply(page)
        if page.phase == "derived":
            held.set()
            await release.wait()
            if failure == "relay_error":
                raise BoundaryError("reconcile_required")
            if failure == "denied_ack":
                return ack.model_copy(update={"state": "denied", "version_refs": [],
                    "context_manifest_ref": None, "context_manifest_digest": None, "error_code": "closure_incomplete"})
        return ack
    save = _wrap_async(EntityNode.save, "graphiti.save.v1", "graphiti_save_v1", "extraction",
                      save=True, save_method="EntityNode.save")
    async def wait_then_write(node):
        queued.set()
        return await save(node, driver)
    with operation(job()), pytest.raises(BoundaryError, match="closure_incomplete"):
        async with intermediate_operation({"extraction": pin("extraction",
                "http://127.0.0.1:11434/v1/chat/completions")}, observe) as state:
            owner = asyncio.create_task(save(nodes[0], driver))
            tasks = [owner]
            try:
                await asyncio.wait_for(held.wait(), 1)
                waiter = asyncio.create_task(wait_then_write(nodes[1]))
                tasks.append(waiter)
                await asyncio.wait_for(queued.wait(), 1)
                if failure == "cancel_owner":
                    owner.cancel()
                elif failure == "cancel_waiter":
                    waiter.cancel()
                    await asyncio.gather(waiter, return_exceptions=True)
                    assert state.failure == "closure_incomplete"
                tasks.append(asyncio.create_task(save(nodes[2], driver)))
                release.set()
                outcomes = await asyncio.gather(*tasks, return_exceptions=True)
                assert all(isinstance(outcome, (BoundaryError, asyncio.CancelledError)) for outcome in outcomes)
                assert calls == [nodes[0].uuid]
                assert state.failure == "closure_incomplete" and not state.write_gate.locked()
            finally:
                release.set()
                for task in tasks:
                    if not task.done():
                        task.cancel()
                await asyncio.gather(*tasks, return_exceptions=True)
            # The enclosing operation's final flush must also report the poison.


@pytest.mark.parametrize("phase,native_calls", [("inputs", 0), ("derived", 1)])
async def test_cancellation_caught_by_callback_is_rechecked_before_delegate_and_success(phase, native_calls):
    obj, calls = _save_object("EntityNode"), []
    paused = asyncio.Event()
    async def observe(page):
        if page.phase == phase:
            paused.set()
            try:
                await asyncio.Event().wait()
            except asyncio.CancelledError:
                pass  # A callback must not make a cancelling writer current.
        return await context_reply(page)
    save = _wrap_async(EntityNode.save, "graphiti.save.v1", "graphiti_save_v1", "extraction",
                      save=True, save_method="EntityNode.save")
    with operation(job()), pytest.raises(BoundaryError, match="closure_incomplete"):
        async with intermediate_operation({"extraction": pin("extraction",
                "http://127.0.0.1:11434/v1/chat/completions")}, observe) as state:
            task = asyncio.create_task(save(obj, _save_driver(_eager_uuid(obj.uuid), calls)))
            await asyncio.wait_for(paused.wait(), 1)
            task.cancel()
            outcome, = await asyncio.gather(task, return_exceptions=True)
            assert isinstance(outcome, asyncio.CancelledError)
            assert len(calls) == native_calls and state.failure == "closure_incomplete"


@pytest.mark.parametrize("misuse", ["child_task", "foreign_invocation"])
async def test_bulk_transaction_rejects_inherited_boolean_without_actual_owner_and_invocation(misuse):
    calls = []
    driver = object.__new__(Neo4jDriver)
    async def transaction():
        calls.append("unobserved transaction")
    guarded = _guard_bulk_transaction(transaction)
    async def native_bulk(driver):
        # SAVE_ACTIVE and the invocation ContextVar are inherited by this child;
        # neither confers the parent's actual task ownership of the lock.
        if misuse == "child_task":
            await asyncio.create_task(guarded())
        else:
            token = SAVE_INVOCATION.set(object())
            try:
                await guarded()
            finally:
                SAVE_INVOCATION.reset(token)
    bulk = _wrap_async(native_bulk, "graphiti.save.v1", "graphiti_save_v1", "extraction",
                       save=True, save_method="add_nodes_and_edges_bulk")
    with operation(job()), pytest.raises(BoundaryError, match="closure_incomplete"):
        async with intermediate_operation({"extraction": pin("extraction",
                "http://127.0.0.1:11434/v1/chat/completions")}, context_reply) as state:
            await bulk(driver)
    assert calls == [] and state.failure == "closure_incomplete" and not state.write_gate.locked()


async def test_individual_save_owner_cannot_enter_bulk_transaction():
    calls = []
    async def transaction():
        calls.append("unobserved transaction")
    guarded = _guard_bulk_transaction(transaction)
    obj = _save_object("EntityNode")
    driver = object.__new__(Neo4jDriver)
    async def execute_query(*args, **kwargs):
        await guarded()
        return _eager_uuid(obj.uuid)
    driver.execute_query = execute_query
    save = _wrap_async(EntityNode.save, "graphiti.save.v1", "graphiti_save_v1", "extraction",
                      save=True, save_method="EntityNode.save")
    with operation(job()), pytest.raises(BoundaryError, match="closure_incomplete"):
        async with intermediate_operation({"extraction": pin("extraction",
                "http://127.0.0.1:11434/v1/chat/completions")}, context_reply):
            await save(obj, driver)
    assert calls == []


async def test_actual_bulk_transaction_allows_embedding_callback_without_reentrant_save_deadlock(monkeypatch):
    from graphiti_core.utils import bulk_utils
    calls, pages = [], []
    node = _save_object("EntityNode")
    driver = object.__new__(Neo4jDriver)
    class Transaction:
        async def run(self, *args, **kwargs):
            calls.append("tx.run")
    class Session:
        async def execute_write(self, callback, *args, **kwargs):
            return await callback(Transaction(), *args, **kwargs)
        async def close(self):
            calls.append("close")
    driver.session = Session
    async def observe(page):
        pages.append(page)
        return await context_reply(page)
    embedding = pin("embedder", "http://127.0.0.1:11434/v1/embeddings")
    class Embedder:
        async def create(self, input_data):
            async with observed_call(embedding, "embedder.create", input_data, observe, embed=True):
                calls.append("component embedding callback")
                await asyncio.sleep(0)
                return [0.0] * 1024
    monkeypatch.setattr(bulk_utils, "add_nodes_and_edges_bulk_tx",
                        _guard_bulk_transaction(bulk_utils.add_nodes_and_edges_bulk_tx))
    bulk = _wrap_async(bulk_utils.add_nodes_and_edges_bulk, "graphiti.save.v1", "graphiti_save_v1", "extraction",
                       save=True, save_method="add_nodes_and_edges_bulk")
    with operation(job()):
        async with intermediate_operation({"extraction": pin("extraction",
                "http://127.0.0.1:11434/v1/chat/completions"), "embedder": embedding}, observe) as state:
            assert await asyncio.wait_for(bulk(driver, [], [], [node], [], Embedder()), 1) is None
            assert state.failure is None and not state.write_gate.locked()
    assert calls == ["component embedding callback", "tx.run", "tx.run", "tx.run", "tx.run", "close"]
    assert any(page.seam_id == "embedder.input.v1" for page in pages)
