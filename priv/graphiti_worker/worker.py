"""Single reader, bounded job tasks, duplex attempt grants and receipts."""
from __future__ import annotations

import asyncio
import sys
from dataclasses import dataclass
from typing import Any
from uuid import uuid4

from lineage import operation
from protocol import (Attempt, AttemptResult, Boot, BoundaryError, ContextAck, ContextPage, Frame, Grant,
                      Job, PrepareRuntime, PrepareRuntimeAck, Result, canonical, digest, encode, read_frame)


@dataclass
class Pending:
    future: asyncio.Future
    grant: Grant | None = None


class Server:
    def __init__(self, reader: asyncio.StreamReader, output: Any):
        self.reader, self.output = reader, output
        self.session: str | None = None
        self.input_seq = 0
        self.output_seq = 0
        self.runtime: Any = None
        self.boot: Boot | None = None
        self.pending: dict[str, Pending] = {}
        self.abandoned: set[str] = set()
        self.jobs: dict[str, asyncio.Task] = {}
        self.job_specs: dict[str, Job] = {}
        self.contexts: dict[str, tuple[ContextPage, asyncio.Future]] = {}
        self.context_proofs: dict[str, tuple[str, str, str]] = {}
        self.seen: set[str] = set()
        self.epochs: dict[str, int] = {}
        self.send_lock = asyncio.Lock()
        self.job_lock = asyncio.Semaphore(1)
        self.closed = False
        self.preparation_seen = False
        self.preparation_task: asyncio.Task | None = None
        self.prepared_request: PrepareRuntime | None = None
        self.data_started = False

    async def send(self, kind: str, request_id: str, payload: dict) -> None:
        async with self.send_lock:
            if self.closed or self.session is None:
                raise BoundaryError("worker_lost")
            self.output_seq += 1
            raw = encode({"v": 1, "kind": kind, "session_id": self.session,
                          "seq": self.output_seq, "request_id": request_id, "payload": payload})
            await asyncio.to_thread(self._write, raw)

    def _write(self, raw: bytes) -> None:
        self.output.write(raw)
        self.output.flush()

    async def relay(self, attempt: Attempt) -> tuple[Grant | None, AttemptResult]:
        proof = self.context_proofs.pop(attempt.context_manifest_ref, None)
        if proof != (attempt.job_id, attempt.context_manifest_digest, attempt.payload_sha256):
            raise BoundaryError("closure_incomplete")
        if attempt.attempt_id in self.pending:
            raise BoundaryError("reconcile_required")
        pending = Pending(asyncio.get_running_loop().create_future())
        self.pending[attempt.attempt_id] = pending
        try:
            await self.send("attempt", attempt.attempt_id, attempt.model_dump())
            result = await pending.future
            return pending.grant, result
        finally:
            if pending.future.cancelled():
                self.abandoned.add(attempt.attempt_id)
            self.pending.pop(attempt.attempt_id, None)

    async def observe(self, page: ContextPage) -> ContextAck:
        job = self.job_specs.get(page.job_id)
        if (job is None or page.partition_id != job.partition_id or page.lease_id != job.lease_id
                or page.cancel_epoch != self.epochs.get(job.job_id) or job.worker_session_id != self.session):
            raise BoundaryError("scope_denied")
        if len(self.contexts) >= 1:
            raise BoundaryError("budget_exhausted")
        request_id = str(uuid4())
        future = asyncio.get_running_loop().create_future()
        self.contexts[request_id] = (page, future)
        try:
            await self.send("context_page", request_id, page.model_dump())
            ack = await future
            if (page.phase == "attempt_bind" and ack.state == "sealed"
                    and ack.allowed_body_sha256 == page.raw_body_sha256):
                self.context_proofs[ack.context_manifest_ref] = (page.job_id, ack.context_manifest_digest, ack.allowed_body_sha256)
            return ack
        finally:
            if future.cancelled():
                self.abandoned.add(request_id)
            self.contexts.pop(request_id, None)

    async def _receive(self, frame: Frame, tasks: asyncio.TaskGroup) -> None:
        if self.session != frame.session_id or frame.seq != self.input_seq + 1:
            raise BoundaryError("invalid_frame")
        self.input_seq = frame.seq
        if frame.kind == "prepare_runtime":
            if (self.boot is None or self.preparation_seen or self.data_started or self.jobs
                    or self.pending or self.contexts or self.context_proofs
                    or frame.request_id in self.seen or len(self.seen) >= 10000):
                raise BoundaryError("reconcile_required")
            request = PrepareRuntime.model_validate(frame.payload)
            if request.stage_set_digest != self.boot.stage_set_digest:
                raise BoundaryError("scope_denied")
            self.preparation_seen = True
            self.seen.add(frame.request_id)
            self.preparation_task = tasks.create_task(self.run_preparation(frame.request_id, request))
        elif frame.kind == "context_ack":
            if frame.request_id in self.abandoned:
                self.abandoned.remove(frame.request_id)
                return
            pending_context = self.contexts.get(frame.request_id)
            if pending_context is None or pending_context[1].done():
                raise BoundaryError("reconcile_required")
            page, future = pending_context
            ack = ContextAck.model_validate(frame.payload)
            if (ack.job_id != page.job_id or ack.context_id != page.context_id or ack.page_index != page.page_index
                    or ack.page_digest != digest(canonical(page.model_dump()))):
                raise BoundaryError("reconcile_required")
            future.set_result(ack)
        elif frame.kind == "attempt_grant":
            grant = Grant.model_validate(frame.payload)
            pending = self.pending.get(grant.attempt_id)
            if pending is None and grant.attempt_id in self.abandoned:
                return
            if pending is None or pending.grant is not None or frame.request_id != grant.attempt_id:
                raise BoundaryError("reconcile_required")
            pending.grant = grant
        elif frame.kind == "attempt_result":
            result = AttemptResult.model_validate(frame.payload)
            pending = self.pending.get(result.attempt_id)
            if pending is None and result.attempt_id in self.abandoned:
                self.abandoned.remove(result.attempt_id)
                return
            if pending is None or pending.future.done() or frame.request_id != result.attempt_id:
                raise BoundaryError("reconcile_required")
            pending.future.set_result(result)
        elif frame.kind == "job":
            job = Job.model_validate(frame.payload)
            if job.worker_session_id != self.session or (self.boot is not None and job.stage_set_digest != self.boot.stage_set_digest):
                raise BoundaryError("scope_denied")
            if frame.request_id in self.seen or len(self.seen) >= 10000:
                raise BoundaryError("reconcile_required")
            self.seen.add(frame.request_id)
            if job.op == "cancel":
                target = job.args["target_job_id"]
                epoch = job.args["new_cancel_epoch"]
                target_job = self.job_specs.get(target)
                if (target_job is None or any(getattr(job, field) != getattr(target_job, field)
                    for field in ("partition_id", "lease_id", "worker_session_id", "scope_ref"))):
                    raise BoundaryError("scope_denied")
                if epoch <= self.epochs.get(target, -1) or epoch != job.cancel_epoch:
                    raise BoundaryError("stale_generation")
                self.epochs[target] = epoch
                if target in self.jobs:
                    self.jobs[target].cancel()
                await self.job_result(frame.request_id, job, "completed", {"cancelled_job_id": target})
            elif self.preparation_seen and job.op != "health" and (
                    self.prepared_request is None or self.data_started or job.op != "search"
                    or job.job_id != self.prepared_request.operation_id
                    or any(getattr(job, field) != getattr(self.prepared_request, field)
                        for field in ("partition_id", "lease_id", "scope_ref", "stage_set_digest"))):
                raise BoundaryError("scope_denied")
            elif job.op == "search" and not self.preparation_seen:
                raise BoundaryError("stage_unavailable")
            elif len(self.jobs) >= 3 or job.job_id in self.jobs:
                await self.job_result(frame.request_id, job, "failed", {"error_code": "budget_exhausted"})
            else:
                if job.op != "health":
                    self.data_started = True
                self.epochs[job.job_id] = job.cancel_epoch
                self.job_specs[job.job_id] = job
                self.jobs[job.job_id] = tasks.create_task(self.run_job(frame.request_id, job))
        else:
            raise BoundaryError("invalid_frame")

    async def run_preparation(self, request_id: str, request: PrepareRuntime) -> None:
        error_code = None
        try:
            async with asyncio.timeout(60):
                async with self.job_lock:
                    await self.runtime.prepare(request)
        except asyncio.CancelledError:
            raise
        except TimeoutError:
            error_code = "deadline_exceeded"
        except BoundaryError as error:
            error_code = error.code
        except Exception:
            error_code = "stage_unavailable"
        if self.boot is None:
            raise BoundaryError("stage_unavailable")
        ack = PrepareRuntimeAck(**request.model_dump(), initialized=error_code is None,
            source_lock_digest=self.boot.source_lock_digest, backend_pin_digest=self.boot.backend_pin_digest,
            error_code=error_code)
        if error_code is None:
            self.prepared_request = request
        await self.send("prepare_runtime_ack", request_id, ack.model_dump())

    async def job_result(self, request_id: str, job: Job, state: str, result: dict,
                         receipts: list[str] | None = None) -> None:
        receipts = receipts or []
        await self.send("result", request_id, Result(job_id=job.job_id, state=state,
            generation=job.semantic_generation, closure_digest=job.closure_digest,
            receipt_count=len(receipts), receipt_digest=digest(canonical(receipts)), result=result).model_dump())

    async def run_job(self, request_id: str, job: Job) -> None:
        with operation(job) as lineage:
            try:
                async with asyncio.timeout(job.deadline_ms / 1000):
                    async with self.job_lock:
                        if self.epochs[job.job_id] != job.cancel_epoch:
                            raise BoundaryError("cancelled")
                        result = await self.runtime.execute(job)
                        if self.epochs[job.job_id] != job.cancel_epoch:
                            raise BoundaryError("cancelled")
                await self.job_result(request_id, job, "completed", result, lineage.receipts)
            except asyncio.CancelledError:
                if not self.closed:
                    await self.job_result(request_id, job, "cancelled", {"error_code": "cancelled"}, lineage.receipts)
            except TimeoutError:
                await self.job_result(request_id, job, "reconcile_required", {"error_code": "deadline_exceeded"}, lineage.receipts)
            except BoundaryError as error:
                state = "unavailable" if error.code == "stage_unavailable" else "failed"
                await self.job_result(request_id, job, state, {"error_code": error.code}, lineage.receipts)
            except Exception:
                # Upstream exceptions may contain source bodies/headers.
                await self.job_result(request_id, job, "reconcile_required", {"error_code": "provider_error"}, lineage.receipts)
            finally:
                self.jobs.pop(job.job_id, None)
                self.job_specs.pop(job.job_id, None)
                self.context_proofs = {key: proof for key, proof in self.context_proofs.items() if proof[0] != job.job_id}

    async def run(self) -> None:
        first = await read_frame(self.reader)
        if first.kind != "boot" or first.seq != 1:
            raise BoundaryError("invalid_frame")
        self.session, self.input_seq = first.session_id, first.seq
        boot = Boot.model_validate(first.payload)
        self.boot = boot
        # Imported only after the entrypoint has disabled telemetry/dotenv and
        # dropped ambient secrets. Runtime has no model socket transport.
        from runtime import Runtime
        self.runtime = Runtime(boot, self.relay, self.observe, session_id=self.session)
        self.runtime.verify_source()
        await self.send("result", first.request_id, {
            "job_id": first.request_id, "state": "completed", "generation": 0,
            "closure_digest": boot.stage_set_digest, "receipt_count": 0,
            "receipt_digest": digest(canonical([])),
            "result": {"version": "0.31.2", "source_lock_digest": boot.source_lock_digest,
                       "backend_pin_digest": boot.backend_pin_digest, "readiness": "configured"}})
        try:
            async with asyncio.TaskGroup() as tasks:
                try:
                    while True:
                        await self._receive(await read_frame(self.reader), tasks)
                finally:
                    self.closed = True
                    if self.preparation_task is not None:
                        self.preparation_task.cancel()
                    for task in self.jobs.values():
                        task.cancel()
                    for pending in self.pending.values():
                        if not pending.future.done():
                            pending.future.cancel()
                    for _, future in self.contexts.values():
                        if not future.done():
                            future.cancel()
        finally:
            await self.runtime.close()


async def serve() -> None:
    reader = asyncio.StreamReader(limit=131076)
    protocol = asyncio.StreamReaderProtocol(reader)
    await asyncio.get_running_loop().connect_read_pipe(lambda: protocol, sys.stdin.buffer)
    server = Server(reader, sys.stdout.buffer)
    try:
        await server.run()
    except (BoundaryError, asyncio.IncompleteReadError, BrokenPipeError, TimeoutError):
        # Fixed exit status, no sensitive traceback on stderr/stdout.
        raise SystemExit(2) from None
    except Exception:
        raise SystemExit(2) from None
