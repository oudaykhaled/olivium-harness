import asyncio

import httpx
import pytest

from fixtures.helpers import pin, reply
from ipc_transport import IPCTransport
from protocol import BoundaryError
from runtime import DeniedReranker, MeteredGeneric, MeteredJev, compose_runtime
from openai import AsyncOpenAI


async def test_composition_uses_real_runtime_two_native_jev_routes_and_separate_generation():
    async def relay(attempt):
        return reply(attempt, {})
    semaphore = asyncio.Semaphore(1)
    stages = [pin("extraction", "http://127.0.0.1:11434/v1/chat/completions"),
              pin("summary", "http://127.0.0.1:11434/v1/chat/completions"), pin(), pin("edge_dedupe")]
    clients = [httpx.AsyncClient(transport=IPCTransport(stage, relay, semaphore), trust_env=False) for stage in stages]
    try:
        generation = MeteredGeneric(stages[0], AsyncOpenAI(api_key="ipc-placeholder", base_url="http://127.0.0.1:11434/v1/", http_client=clients[0], max_retries=0))
        summary = MeteredGeneric(stages[1], AsyncOpenAI(api_key="ipc-placeholder", base_url="http://127.0.0.1:11434/v1/", http_client=clients[1], max_retries=0))
        nodes, edges = MeteredJev(stages[2], clients[2]), MeteredJev(stages[3], clients[3])
        runtime = compose_runtime(generation, summary, nodes, edges)
        assert runtime.resolve_model("extract_nodes.extract_text").transport.client is generation
        assert runtime.resolve_model("extract_nodes.extract_summaries_batch").transport.client is summary
        assert runtime.resolve_model("dedupe_nodes.nodes").transport.client is nodes
        assert runtime.resolve_model("dedupe_edges.resolve_edge").transport.client is edges
        assert runtime.resolve_model("eval.qa_prompt").transport.client is generation
        assert runtime.resolve_model("dedupe_nodes.nodes").flat_overrides
    finally:
        for client in clients:
            await client.aclose()


async def test_unselected_reranker_cannot_use_ambient_provider():
    with pytest.raises(BoundaryError, match="stage_unavailable"):
        await DeniedReranker().rank("synthetic", ["synthetic"])


async def test_duplex_reader_services_attempt_while_job_waits_without_deadlock():
    """Dispatcher mechanics only; the real backend test exercises Graphiti."""
    import io
    from fixtures.helpers import job
    from protocol import Attempt, Frame, Grant, PrepareRuntime, digest
    from worker import Server

    selected = job()
    server = Server(asyncio.StreamReader(), io.BytesIO())
    server.session = "session:synthetic"
    server.preparation_seen = True
    server.prepared_request = PrepareRuntime(operation_id=selected.job_id,
        partition_id=selected.partition_id, lease_id=selected.lease_id,
        scope_ref=selected.scope_ref, stage_set_digest=selected.stage_set_digest)
    dispatched = asyncio.Event()

    class RelayOperation:
        async def execute(self, active_job):
            body = "{}"
            attempt = Attempt(job_id=active_job.job_id, logical_call_id="call:synthetic",
                attempt_id="attempt:synthetic", stage_id="stage:synthetic", stage_digest="1" * 64,
                prompt_name="synthetic.dispatch", closure_ref=active_job.closure_ref,
                closure_digest=active_job.closure_digest, context_manifest_ref=active_job.closure_ref,
                context_manifest_digest=active_job.closure_digest, cancel_epoch=0,
                payload_sha256=digest(body.encode()), method="POST", route_id="route:synthetic",
                body=body, timeout_ms=1000, max_output_tokens=1, context_changed=False,
                ordinal=1, predecessor_attempt_id=None)
            dispatched.set()
            # Explicit synthetic context receipt; observation exchange itself is
            # exercised by test_observations. This test covers duplex attempts.
            server.context_proofs[attempt.context_manifest_ref] = (active_job.job_id, attempt.context_manifest_digest, attempt.payload_sha256)
            grant, receipt = await server.relay(attempt)
            assert grant is not None and receipt.state == "completed"
            return {"candidates": []}

    server.runtime = RelayOperation()
    async with asyncio.TaskGroup() as tasks:
        await server._receive(Frame(v=1, kind="job", session_id=server.session, seq=1,
            request_id="request:synthetic", payload=selected.model_dump()), tasks)
        await asyncio.wait_for(dispatched.wait(), 1)
        assert "attempt:synthetic" in server.pending
        from protocol import AttemptResult
        grant = Grant(attempt_id="attempt:synthetic", grant_id="grant:synthetic", payload_sha256=digest(b"{}"),
                      expires_at="2099-01-01T00:00:00Z", cancel_epoch=0)
        await server._receive(Frame(v=1, kind="attempt_grant", session_id=server.session, seq=2,
            request_id="attempt:synthetic", payload=grant.model_dump()), tasks)
        receipt = AttemptResult(attempt_id="attempt:synthetic", receipt_id="receipt:synthetic",
            state="completed", http_status=200, body="{}", body_sha256=digest(b"{}"),
            usage_status="unknown", billing_status="unknown", input_tokens=None, output_tokens=None, error_code=None)
        await server._receive(Frame(v=1, kind="attempt_result", session_id=server.session, seq=3,
            request_id="attempt:synthetic", payload=receipt.model_dump()), tasks)
    assert server.pending == {}
    assert server.jobs == {}


@pytest.mark.parametrize("edge_count,score_count", [(1, 0), (1, 2), (0, 1)])
async def test_search_score_misalignment_denies_without_padding_or_truncation(edge_count, score_count):
    from graphiti_core.search.search_config import SearchResults
    from search_observations import project_results
    results = SearchResults().model_copy(update={
        "edges": [object()] * edge_count, "edge_reranker_scores": [0.5] * score_count})
    with pytest.raises(BoundaryError, match="closure_incomplete"):
        project_results(results, group_id="synthetic_group", limit=10)


async def test_search_preserves_native_candidate_order_and_exact_floating_scores():
    import struct
    from datetime import datetime, timezone
    from uuid import uuid4
    from graphiti_core.edges import EntityEdge
    from graphiti_core.search.search_config import SearchResults
    from search_observations import project_results
    scores = [-0.0, 0.12345678901234566]
    edges = [EntityEdge(uuid=str(uuid4()), group_id="synthetic_group", name="SYNTHETIC", fact="Synthetic",
        source_node_uuid=str(uuid4()), target_node_uuid=str(uuid4()), episodes=[str(uuid4())],
        created_at=datetime(2026, 1, 1, tzinfo=timezone.utc)) for _ in scores]
    result, measured = project_results(SearchResults(edges=edges, edge_reranker_scores=scores),
                                       group_id="synthetic_group", limit=10)
    assert [candidate["edge_id"] for candidate in result["candidates"]] == [edge.uuid for edge in edges]
    assert [struct.pack(">d", candidate["score"]) for candidate in result["candidates"]] == [
        struct.pack(">d", score) for score in scores]
    assert [candidate["score"]["bits"] for candidate in measured["candidates"]] == [
        struct.pack(">d", score).hex() for score in scores]


def _ingest_runtime_and_job(*, observer=True, omit_stage=None):
    from fixtures.helpers import context_reply, job
    from protocol import Boot, digest, stage_set_digest
    from runtime import Runtime
    stages = [pin(stage, "http://127.0.0.1:11434/v1/" + (
        "embeddings" if stage == "embedder" else "chat/completions"))
        if "dedupe" not in stage else pin(stage)
        for stage in ("extraction", "summary", "node_dedupe", "edge_dedupe", "embedder")
        if stage != omit_stage]
    configured = Boot(source_lock_digest="1" * 64, backend_pin_digest="2" * 64,
        backend_uri="bolt://127.0.0.1:7687", backend_user="synthetic", backend_password="synthetic",
        database="neo4j", stage_pins=stages, stage_set_digest=stage_set_digest(stages))
    async def relay(attempt):
        raise AssertionError("Control-only test must emit no model attempt")
    runtime = Runtime(configured, relay, context_reply if observer else None, session_id="session:synthetic")
    body = "Synthetic input"
    selected = job("ingest", stage_set_digest=configured.stage_set_digest, args={
        "binding_id": "binding:synthetic", "episode_uuid": "episode:synthetic", "revision_id": "revision:synthetic",
        "body_hash": digest(body.encode()), "window_start": 0, "window_end": len(body.encode()), "body": body,
        "reference_time": "2026-01-01T00:00:00Z", "time_basis": "event", "prior_episode_ids": ["episode:prior"]})
    return runtime, selected


async def test_execute_ingest_opens_before_native_composition_inside_matching_observer_scope(monkeypatch):
    from lineage import CURRENT_LINEAGE, operation
    from observations import CURRENT_INTERMEDIATE
    runtime, selected = _ingest_runtime_and_job()
    calls = []
    async def open_graph():
        assert CURRENT_INTERMEDIATE.get(None) is None
        calls.append("open")
        runtime.graph = object()
    async def native(job):
        state = CURRENT_INTERMEDIATE.get(None)
        assert state is not None and state.relay is runtime.observer_relay and state.pins == runtime.pins
        assert CURRENT_LINEAGE.get().job is selected and job is selected and runtime.graph is not None
        assert job.args["prior_episode_ids"] == ["episode:prior"]
        calls.append("native")
        return {"binding_id": job.args["binding_id"], "episode_uuid": job.args["episode_uuid"]}
    monkeypatch.setattr(runtime, "open", open_graph)
    monkeypatch.setattr(runtime, "_native_ingest", native)
    with operation(selected):
        assert await runtime.execute(selected) == {"binding_id": "binding:synthetic", "episode_uuid": "episode:synthetic"}
        assert CURRENT_INTERMEDIATE.get(None) is None
        await runtime.ingest(selected)
    assert calls == ["open", "native", "native"]


@pytest.mark.parametrize("invalid,code", [("session", "scope_denied"), ("scope", "scope_denied"),
    ("stage_set", "stale_generation"), ("observer", "closure_incomplete"),
    ("missing_stage", "stage_unavailable"), ("lineage", "closure_incomplete"),
    ("foreign_lineage", "closure_incomplete"), ("operation", "invalid_dto")])
async def test_ingest_preflight_denies_before_open_or_native_mutation(monkeypatch, invalid, code):
    from contextlib import nullcontext
    from lineage import operation
    runtime, selected = _ingest_runtime_and_job(observer=invalid != "observer",
                                               omit_stage="summary" if invalid == "missing_stage" else None)
    changes = {"session": {"worker_session_id": "foreign:session"}, "scope": {"scope_ref": ""},
               "stage_set": {"stage_set_digest": "0" * 64}, "operation": {"op": "search"}}
    selected = selected.model_copy(update=changes.get(invalid, {}))
    async def unavailable(*args):
        raise AssertionError("Invalid control must deny before open/native mutation")
    monkeypatch.setattr(runtime, "open", unavailable)
    monkeypatch.setattr(runtime, "_native_ingest", unavailable)
    context = nullcontext() if invalid == "lineage" else operation(
        selected.model_copy(update={"job_id": "foreign:job"}) if invalid == "foreign_lineage" else selected)
    with context, pytest.raises(BoundaryError, match=code):
        await runtime.ingest(selected)
    assert runtime.graph is None


async def test_ingest_open_or_observer_failure_never_returns_native_success(monkeypatch):
    from lineage import operation
    from observations import observed_call
    from fixtures.helpers import context_reply
    runtime, selected = _ingest_runtime_and_job()
    calls = []
    async def failed_open():
        raise BoundaryError("stage_unavailable")
    monkeypatch.setattr(runtime, "open", failed_open)
    with operation(selected), pytest.raises(BoundaryError, match="stage_unavailable"):
        await runtime.execute(selected)
    assert runtime.graph is None
    async def deny(page):
        ack = await context_reply(page)
        return ack.model_copy(update={"state": "denied", "version_refs": [], "context_manifest_ref": None,
            "context_manifest_digest": None, "error_code": "closure_incomplete"})
    runtime.observer_relay = deny
    runtime.graph = object()
    async def native(job):
        async with observed_call(runtime.pins["extraction"], "extract_nodes.extract_text",
                                  {"synthetic": True}, runtime.observer_relay):
            calls.append("unobserved mutation")
        return {}
    monkeypatch.setattr(runtime, "_native_ingest", native)
    with operation(selected), pytest.raises(BoundaryError, match="closure_incomplete"):
        await runtime.execute(selected)
    assert calls == []


async def _stage_ceiling_call(requested, *, summary=False):
    import json
    from fixtures.helpers import context_reply, job
    from graphiti_core.llm_client import LLMTransport, PromptRoutes
    from lineage import operation
    from protocol import StagePin, canonical, digest
    from runtime import ObservedRuntime
    generation = pin("extraction", "http://127.0.0.1:11434/v1/chat/completions")
    data = pin("summary", "http://127.0.0.1:11434/v1/chat/completions").model_dump()
    data["max_output_tokens"] = 256
    data["config_digest"] = digest(canonical({key: value for key, value in data.items() if key != "config_digest"}))
    summarized = StagePin.model_validate(data)
    calls, clients, models = [], [], []
    async def relay(attempt):
        calls.append((attempt.stage_id, json.loads(attempt.body)))
        value = {"summary": "Synthetic"} if summary else {"extracted_entities": []}
        return reply(attempt, {"id": "synthetic", "object": "chat.completion", "created": 0,
            "model": "synthetic-fixture-v1", "choices": [{"index": 0, "finish_reason": "stop",
                "message": {"role": "assistant", "content": json.dumps(value)}}]})
    try:
        for selected in (generation, summarized):
            client = httpx.AsyncClient(transport=IPCTransport(selected, relay, asyncio.Semaphore(1)), trust_env=False)
            clients.append(client)
            native = MeteredGeneric(selected, AsyncOpenAI(api_key="ipc-placeholder",
                base_url="http://127.0.0.1:11434/v1/", http_client=client, max_retries=0))
            models.append(LLMTransport(native, models=[selected.model]).model(selected.model,
                max_tokens=selected.max_output_tokens))
        runtime = ObservedRuntime(models[0], routes=PromptRoutes(
            extract_nodes=PromptRoutes.ExtractNodes(extract_summary=models[1])), observer_relay=context_reply)
        kwargs = {} if requested == "omitted" else {"max_tokens": requested}
        context = ({"node": {"name": "Synthetic", "summary": ""}, "episode_content": "Synthetic",
                    "previous_episodes": []} if summary else
                   {"episode_content": "Synthetic", "entity_types": "0: Entity", "custom_extraction_instructions": ""})
        prompt = "extract_nodes.extract_summary" if summary else "extract_nodes.extract_text"
        with operation(job()):
            try:
                result = await runtime.complete(prompt, context, **kwargs)
            except BoundaryError:
                assert calls == []
                raise
        return calls, result
    finally:
        for client in clients:
            await client.aclose()


@pytest.mark.parametrize("requested,effective", [(16384, 4096), (128, 128), ("omitted", 4096), (None, 4096)])
async def test_stage_ceiling_policy_keeps_one_native_sdk_request_with_bounded_tokens(requested, effective):
    from runtime import STAGE_CEILING_POLICY
    calls, value = await _stage_ceiling_call(requested)
    assert STAGE_CEILING_POLICY == "graphiti-stage-ceiling-v1"
    assert len(calls) == 1 and calls[0][0] == "stage:extraction"
    assert calls[0][1]["max_tokens"] == effective and value == {"extracted_entities": []}


@pytest.mark.parametrize("requested", [True, False, 0, -1, "16384"])
async def test_stage_ceiling_policy_rejects_invalid_token_requests_before_any_attempt(requested):
    with pytest.raises(BoundaryError, match="invalid_dto"):
        await _stage_ceiling_call(requested)


async def test_stage_ceiling_uses_actual_summary_route_pin_instead_of_generation_cap():
    calls, value = await _stage_ceiling_call(16384, summary=True)
    assert len(calls) == 1 and calls[0][0] == "stage:summary" and calls[0][1]["max_tokens"] == 256
    assert value == {"summary": "Synthetic"}


async def test_native_edge_datetime_context_is_projected_only_for_observation(monkeypatch):
    import copy
    import json
    from datetime import datetime, timezone
    from fixtures.helpers import context_reply, job
    from graphiti_core.llm_client import LLMTransport
    from lineage import operation
    from runtime import ObservedRuntime
    reference = datetime(2026, 1, 2, 3, 4, 5, tzinfo=timezone.utc)
    context = {"episode_content": "Synthetic A relates to Synthetic B.",
        "nodes": [{"name": "Synthetic A", "entity_types": ["Entity"]},
                  {"name": "Synthetic B", "entity_types": ["Entity"]}],
        "previous_episodes": [], "reference_time": reference, "edge_types": [],
        "strict_edge_types": False, "custom_extraction_instructions": ""}
    original = copy.deepcopy(context)
    pages, attempts, built = [], [], []
    async def observe(page):
        pages.append(page)
        return await context_reply(page)
    async def relay(attempt):
        attempts.append(attempt)
        return reply(attempt, {"id": "synthetic-edge", "object": "chat.completion", "created": 0,
            "model": "synthetic-fixture-v1", "choices": [{"index": 0, "finish_reason": "stop",
                "message": {"role": "assistant", "content": '{"edges":[]}'}}]})
    stage = pin("extraction", "http://127.0.0.1:11434/v1/chat/completions")
    async with httpx.AsyncClient(transport=IPCTransport(stage, relay, asyncio.Semaphore(1)), trust_env=False) as client:
        native = MeteredGeneric(stage, AsyncOpenAI(api_key="ipc-placeholder",
            base_url="http://127.0.0.1:11434/v1/", http_client=client, max_retries=0))
        runtime = ObservedRuntime(LLMTransport(native, models=[stage.model]).model(stage.model), observer_relay=observe)
        resolve_builder = runtime.resolve_builder
        def observe_builder(prompt_name, model):
            builder = resolve_builder(prompt_name, model)
            def delegate(typed_context):
                assert isinstance(typed_context["reference_time"], datetime)
                assert typed_context == original and typed_context is not context
                built.append(typed_context)
                return builder(typed_context)  # unchanged actual pinned edge prompt
            return delegate
        monkeypatch.setattr(runtime, "resolve_builder", observe_builder)
        with operation(job()):
            assert await runtime.complete("extract_edges.edge", context, max_tokens=16384) == {"edges": []}
    observed = [page for page in pages if page.seam_id == "llm.context.v1"]
    assert len(observed) == 1 and observed[0].entries[0].value["reference_time"] == reference.isoformat()
    assert len(built) == len(attempts) == 1
    body = json.loads(attempts[0].body)
    user = next(message["content"] for message in body["messages"] if message["role"] == "user")
    assert "<REFERENCE_TIME>\n2026-01-02 03:04:05+00:00  #" in user
    assert "<REFERENCE_TIME>\n" + reference.isoformat() not in user
    assert body["max_tokens"] == stage.max_output_tokens
    assert context == original and context["reference_time"] is reference


@pytest.mark.parametrize("invalid", ["opaque", "float"])
async def test_native_context_projection_keeps_unknown_objects_and_floats_denied_before_frame_or_post(invalid):
    from fixtures.helpers import context_reply, job
    from graphiti_core.llm_client import LLMTransport
    from lineage import operation
    from pydantic import ValidationError
    from runtime import ObservedRuntime
    pages, attempts = [], []
    async def observe(page):
        pages.append(page)
        return await context_reply(page)
    async def relay(attempt):
        attempts.append(attempt)
        raise AssertionError("Unsupported context must never emit an attempt")
    stage = pin("extraction", "http://127.0.0.1:11434/v1/chat/completions")
    async with httpx.AsyncClient(transport=IPCTransport(stage, relay, asyncio.Semaphore(1)), trust_env=False) as client:
        native = MeteredGeneric(stage, AsyncOpenAI(api_key="ipc-placeholder",
            base_url="http://127.0.0.1:11434/v1/", http_client=client, max_retries=0))
        runtime = ObservedRuntime(LLMTransport(native, models=[stage.model]).model(stage.model), observer_relay=observe)
        value = object() if invalid == "opaque" else 1.25
        context = {"episode_content": "Synthetic", "unsupported": value}
        with operation(job()), pytest.raises((BoundaryError, ValidationError)):
            await runtime.complete("extract_edges.edge", context)
        assert context["unsupported"] is value
    assert pages == attempts == []
