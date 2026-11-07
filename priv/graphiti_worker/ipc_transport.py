"""httpx transport for official clients. No socket/model credential operations."""
from __future__ import annotations

import asyncio
from typing import Awaitable, Callable
from uuid import uuid4

import httpx

from lineage import CURRENT_CALL, CURRENT_LINEAGE
from observations import current_observation
from protocol import Attempt, AttemptResult, BoundaryError, Grant, MAX_BODY, StagePin, digest

Relay = Callable[[Attempt], Awaitable[tuple[Grant | None, AttemptResult]]]


class IPCTransport(httpx.AsyncBaseTransport):
    def __init__(self, pin: StagePin, relay: Relay, semaphore: asyncio.Semaphore):
        self.pin = pin
        self.relay = relay
        self.semaphore = semaphore

    async def handle_async_request(self, request: httpx.Request) -> httpx.Response:
        if request.method != "POST" or str(request.url) != self.pin.endpoint:
            raise BoundaryError("scope_denied")
        raw = await request.aread()
        if len(raw) > MAX_BODY:
            raise BoundaryError("response_limit")
        try:
            body = raw.decode("utf-8", errors="strict")
            lineage, context = CURRENT_LINEAGE.get(), CURRENT_CALL.get()
        except (LookupError, UnicodeError) as error:
            raise BoundaryError("closure_incomplete") from error
        if context.stage_id != self.pin.id:
            raise BoundaryError("scope_denied")
        observation = current_observation(self.pin, context.prompt_name)
        context.ordinal += 1
        if context.ordinal > 3:
            raise BoundaryError("budget_exhausted")
        body_hash = digest(raw)
        proof = await observation.bind(raw)
        manifest_ref, manifest_digest = proof.manifest_ref, proof.manifest_digest
        if proof.body_hash != body_hash:
            raise BoundaryError("reconcile_required")
        attempt = Attempt(
            job_id=lineage.job.job_id, logical_call_id=context.logical_call_id,
            attempt_id=str(uuid4()), stage_id=self.pin.id, stage_digest=self.pin.config_digest,
            prompt_name=context.prompt_name, closure_ref=lineage.job.closure_ref,
            closure_digest=lineage.job.closure_digest,
            context_manifest_ref=manifest_ref, context_manifest_digest=manifest_digest,
            cancel_epoch=lineage.job.cancel_epoch, payload_sha256=body_hash, method="POST",
            route_id=self.pin.route_id, body=body,
            timeout_ms=min(self.pin.timeout_ms, 60000), max_output_tokens=self.pin.max_output_tokens,
            context_changed=context.previous_payload is not None and context.previous_payload != body_hash,
            ordinal=context.ordinal, predecessor_attempt_id=context.predecessor,
        )
        context.predecessor, context.previous_payload = attempt.attempt_id, body_hash
        # The global lock is in addition to Graphiti's per-gather cap.
        async with self.semaphore:
            async with asyncio.timeout(attempt.timeout_ms / 1000):
                grant, result = await self.relay(attempt)
        if result.attempt_id != attempt.attempt_id:
            raise BoundaryError("reconcile_required")
        lineage.receipt(result.receipt_id)
        if result.state != "completed":
            raise BoundaryError(result.error_code or "provider_error")
        if grant is None or grant.attempt_id != attempt.attempt_id or grant.payload_sha256 != body_hash or grant.cancel_epoch != attempt.cancel_epoch:
            raise BoundaryError("reconcile_required")
        # Root owns the actual grant expiry check before HTTP. Do not reject a
        # valid late receipt merely because its grant expired during the POST.
        if result.http_status is None or result.body is None:
            raise BoundaryError("provider_error")
        await observation.response(result, proof)
        return httpx.Response(result.http_status, content=result.body.encode(),
                              headers={"content-type": "application/json"}, request=request)
