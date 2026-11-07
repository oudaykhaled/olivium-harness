"""Closed preparation control mechanics; no Port/backend/process execution."""
import asyncio
import io

import pytest
from pydantic import ValidationError

from fixtures.helpers import context_reply, job, pin
from lineage import operation
from protocol import (Boot, BoundaryError, Frame, PrepareRuntime, PrepareRuntimeAck,
                      decode, encode, stage_set_digest)
from runtime import Runtime
from worker import Server


def configured():
    pins = [pin(stage, "http://127.0.0.1:11434/v1/" +
        ("embeddings" if stage == "embedder" else "chat/completions")) if "dedupe" not in stage else pin(stage)
        for stage in ("extraction", "summary", "node_dedupe", "edge_dedupe", "embedder")]
    return Boot(source_lock_digest="1" * 64, backend_pin_digest="2" * 64,
        backend_uri="bolt://127.0.0.1:7687", backend_user="synthetic", backend_password="synthetic",
        database="neo4j", stage_pins=pins, stage_set_digest=stage_set_digest(pins))


def request(boot, **updates):
    values = dict(operation_id="operation:search", partition_id="partition:synthetic",
        lease_id="lease:synthetic", scope_ref="synthetic_group", stage_set_digest=boot.stage_set_digest)
    values.update(updates)
    return PrepareRuntime.model_validate(values)


def selected(boot):
    return job(job_id="operation:search", stage_set_digest=boot.stage_set_digest)


async def denied_relay(attempt):
    raise AssertionError("Preparation has no provider authority")


def test_preparation_wire_is_exact_five_and_nine_fields_and_strict():
    boot = configured()
    req = request(boot)
    ack = PrepareRuntimeAck(**req.model_dump(), initialized=True, source_lock_digest=boot.source_lock_digest,
        backend_pin_digest=boot.backend_pin_digest, error_code=None)
    assert set(req.model_dump()) == {"operation_id", "partition_id", "lease_id", "scope_ref", "stage_set_digest"}
    assert set(ack.model_dump()) == set(req.model_dump()) | {
        "initialized", "source_lock_digest", "backend_pin_digest", "error_code"}
    for kind, payload in (("prepare_runtime", req.model_dump()), ("prepare_runtime_ack", ack.model_dump())):
        packet = encode(dict(v=1, kind=kind, session_id="session:synthetic", seq=1,
            request_id="request:prepare", payload=payload))
        assert decode(packet[4:]).payload == payload
    for changes in ({"initialized": False}, {"initialized": 1}, {"error_code": "raw provider details"},
                    {"query": "not control metadata"}, {"operation_token": "never"}):
        with pytest.raises(ValidationError):
            PrepareRuntimeAck.model_validate({**ack.model_dump(), **changes})
    for changes in ({"lease_id": None}, {"stage_set_digest": "bad"}, {"query": "never"}):
        with pytest.raises(ValidationError):
            PrepareRuntime.model_validate({**req.model_dump(), **changes})


async def test_runtime_preparation_waits_initialization_once_before_search_baseline(monkeypatch):
    boot = configured()
    runtime = Runtime(boot, denied_relay, context_reply, session_id="session:synthetic")
    started, release, calls = asyncio.Event(), asyncio.Event(), []
    async def open_graph():
        calls.append("open")
        started.set()
        await release.wait()
        runtime.graph = object()
    monkeypatch.setattr(runtime, "open", open_graph)
    task = asyncio.create_task(runtime.prepare(request(boot)))
    await started.wait()
    assert runtime.prepared is None
    with pytest.raises(BoundaryError, match="scope_denied"):
        runtime.check_prepared(selected(boot))
    release.set()
    await task
    runtime.check_prepared(selected(boot))
    with pytest.raises(BoundaryError, match="reconcile_required"):
        await runtime.prepare(request(boot))
    assert calls == ["open"]


@pytest.mark.parametrize("field,value", [("job_id", "foreign"), ("partition_id", "foreign"),
    ("lease_id", "foreign"), ("scope_ref", "foreign"), ("stage_set_digest", "0" * 64),
    ("worker_session_id", "foreign"), ("op", "ingest")])
async def test_prepared_runtime_rejects_any_binding_change_before_native_search(monkeypatch, field, value):
    boot = configured()
    runtime = Runtime(boot, denied_relay, context_reply, session_id="session:synthetic")
    async def open_graph():
        runtime.graph = object()
    monkeypatch.setattr(runtime, "open", open_graph)
    await runtime.prepare(request(boot))
    with pytest.raises(BoundaryError, match="scope_denied"):
        runtime.check_prepared(selected(boot).model_copy(update={field: value}))


async def test_search_never_lazily_reopens_and_failed_preparation_never_retries(monkeypatch):
    boot = configured()
    runtime = Runtime(boot, denied_relay, context_reply, session_id="session:synthetic")
    calls = []
    async def open_graph():
        calls.append("open")
        raise BoundaryError("stage_unavailable")
    monkeypatch.setattr(runtime, "open", open_graph)
    with operation(selected(boot)), pytest.raises(BoundaryError, match="stage_unavailable"):
        await runtime.execute(selected(boot))
    assert calls == []
    with pytest.raises(BoundaryError, match="stage_unavailable"):
        await runtime.prepare(request(boot))
    with pytest.raises(BoundaryError, match="reconcile_required"):
        await runtime.prepare(request(boot))
    assert calls == ["open"]


async def test_cancelled_preparation_cannot_become_ready_or_retry(monkeypatch):
    boot = configured()
    runtime = Runtime(boot, denied_relay, context_reply, session_id="session:synthetic")
    started = asyncio.Event()
    async def open_graph():
        started.set()
        await asyncio.Event().wait()
    monkeypatch.setattr(runtime, "open", open_graph)
    task = asyncio.create_task(runtime.prepare(request(boot)))
    await started.wait()
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task
    assert runtime.prepared is None and runtime.graph is None
    with pytest.raises(BoundaryError, match="reconcile_required"):
        await runtime.prepare(request(boot))


async def test_server_preparation_has_separate_pending_slot_boot_identity_and_no_job_authority():
    boot = configured()
    server = Server(asyncio.StreamReader(), io.BytesIO())
    server.session, server.boot = "session:synthetic", boot
    started, release, calls = asyncio.Event(), asyncio.Event(), []
    class Preparation:
        async def prepare(self, req):
            calls.append(req)
            started.set()
            await release.wait()
    server.runtime = Preparation()
    async with asyncio.TaskGroup() as tasks:
        await server._receive(Frame(v=1, kind="prepare_runtime", session_id=server.session, seq=1,
            request_id="request:prepare", payload=request(boot).model_dump()), tasks)
        await started.wait()
        assert server.prepared_request is None
        assert server.jobs == server.job_specs == server.contexts == server.pending == {}
        assert server.output.getvalue() == b""
        release.set()
        await server.preparation_task
        assert server.prepared_request == request(boot)
        with pytest.raises(BoundaryError, match="reconcile_required"):
            await server._receive(Frame(v=1, kind="prepare_runtime", session_id=server.session, seq=2,
                request_id="request:repeat", payload=request(boot).model_dump()), tasks)
    response = decode(server.output.getvalue()[4:])
    assert response.kind == "prepare_runtime_ack" and response.request_id == "request:prepare"
    ack = PrepareRuntimeAck.model_validate(response.payload)
    assert ack.initialized and ack.error_code is None
    assert ack.source_lock_digest == boot.source_lock_digest and ack.backend_pin_digest == boot.backend_pin_digest
    assert ack.stage_set_digest == boot.stage_set_digest and len(calls) == 1
    assert server.jobs == server.job_specs == server.contexts == server.pending == {}


@pytest.mark.parametrize("initialized", [True, False])
async def test_preparation_binding_is_installed_before_success_ack_can_be_exposed(monkeypatch, initialized):
    boot = configured()
    server = Server(asyncio.StreamReader(), io.BytesIO())
    server.session, server.boot = "session:synthetic", boot
    req = request(boot)
    entered, release = asyncio.Event(), asyncio.Event()
    observed = []
    class Preparation:
        async def prepare(self, active_request):
            assert active_request is req
            if not initialized:
                raise BoundaryError("closure_incomplete")
    server.runtime = Preparation()
    async def send(kind, request_id, payload):
        # This is the external-visibility boundary, before send returns to
        # run_preparation. A separate receiver can already be scheduled here.
        try:
            assert kind == "prepare_runtime_ack" and request_id == "request:prepare"
            assert payload["initialized"] is initialized
            observed.append(server.prepared_request)
            assert server.prepared_request is (req if initialized else None)
            assert server.jobs == server.job_specs == server.pending == server.contexts == {}
        finally:
            entered.set()
        await release.wait()
    monkeypatch.setattr(server, "send", send)
    task = asyncio.create_task(server.run_preparation("request:prepare", req))
    await entered.wait()
    release.set()
    await task
    assert observed == [req if initialized else None]


@pytest.mark.parametrize("failure", ["closed", "opaque"])
async def test_failed_preparation_ack_has_only_closed_error_and_no_ready_binding(failure):
    boot = configured()
    server = Server(asyncio.StreamReader(), io.BytesIO())
    server.session, server.boot = "session:synthetic", boot
    class Preparation:
        async def prepare(self, req):
            if failure == "closed":
                raise BoundaryError("closure_incomplete")
            raise RuntimeError("Private backend/password details must not cross IPC")
    server.runtime = Preparation()
    async with asyncio.TaskGroup() as tasks:
        await server._receive(Frame(v=1, kind="prepare_runtime", session_id=server.session, seq=1,
            request_id="request:prepare", payload=request(boot).model_dump()), tasks)
    response = decode(server.output.getvalue()[4:])
    assert response.payload["initialized"] is False
    assert response.payload["error_code"] == ("closure_incomplete" if failure == "closed" else "stage_unavailable")
    assert server.prepared_request is None and b"Private" not in server.output.getvalue()


async def test_preparation_inflight_job_and_foreign_job_are_denied_without_job_registration():
    boot = configured()
    server = Server(asyncio.StreamReader(), io.BytesIO())
    server.session, server.boot = "session:synthetic", boot
    server.preparation_seen = True
    async with asyncio.TaskGroup() as tasks:
        with pytest.raises(BoundaryError, match="scope_denied"):
            await server._receive(Frame(v=1, kind="job", session_id=server.session, seq=1,
                request_id="request:early", payload=selected(boot).model_dump()), tasks)
        server.prepared_request = request(boot)
        foreign = selected(boot).model_copy(update={"lease_id": "foreign"})
        with pytest.raises(BoundaryError, match="scope_denied"):
            await server._receive(Frame(v=1, kind="job", session_id=server.session, seq=2,
                request_id="request:foreign", payload=foreign.model_dump()), tasks)
    assert server.jobs == server.job_specs == {} and server.output.getvalue() == b""


async def test_prepared_session_runs_only_one_matching_search_and_preserves_diagnostic_health():
    boot = configured()
    server = Server(asyncio.StreamReader(), io.BytesIO())
    server.session, server.boot = "session:synthetic", boot
    server.preparation_seen, server.prepared_request = True, request(boot)
    calls = []
    class RuntimeStub:
        async def execute(self, selected_job):
            calls.append(selected_job.op)
            if selected_job.op == "health":
                return {"version": "0.31.2", "source_lock_digest": boot.source_lock_digest,
                    "backend_pin_digest": boot.backend_pin_digest, "readiness": "configured"}
            return {"candidates": []}
    server.runtime = RuntimeStub()
    async with asyncio.TaskGroup() as tasks:
        await server._receive(Frame(v=1, kind="job", session_id=server.session, seq=1,
            request_id="request:first", payload=selected(boot).model_dump()), tasks)
        await server.jobs["operation:search"]
        with pytest.raises(BoundaryError, match="scope_denied"):
            await server._receive(Frame(v=1, kind="job", session_id=server.session, seq=2,
                request_id="request:second", payload=selected(boot).model_dump()), tasks)
        health = job("health", args={}, stage_set_digest=boot.stage_set_digest,
            scope_ref="worker:health", closure_ref="source-lock", closure_digest=boot.source_lock_digest,
            semantic_generation=0, authorization_generation=0, cancel_epoch=0,
            partition_id=None, lease_id=None, deadline_ms=1000)
        await server._receive(Frame(v=1, kind="job", session_id=server.session, seq=3,
            request_id="request:health", payload=health.model_dump()), tasks)
    assert calls == ["search", "health"]
