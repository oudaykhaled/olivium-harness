"""Public synthetic protocol data, unrelated to the protected product oracle."""
import json
from datetime import datetime, timedelta, timezone
from uuid import uuid4

from protocol import AttemptResult, ContextAck, Grant, Job, StagePin, canonical, digest


def pin(stage="node_dedupe", endpoint="https://api.typesafe.ai/v1/systemone"):
    value = dict(id=f"stage:{stage}", stage=stage, provider="jev" if "dedupe" in stage else "ollama",
        model="jev-1.14.0" if "dedupe" in stage else "synthetic-fixture-v1",
        endpoint=endpoint, route_id=f"route:{stage}", credential_ref=None,
        prompt_digest="1" * 64, schema_digest="2" * 64, consent_revision=1,
        input_rate=0, output_rate=0, max_output_tokens=4096, timeout_ms=1000)
    value["config_digest"] = digest(canonical(value))
    return StagePin.model_validate(value)


def job(op="search", **updates):
    value = dict(op=op, job_id=str(uuid4()), idempotency_key=str(uuid4()), scope_ref="synthetic_group",
        semantic_generation=1, authorization_generation=1, cancel_epoch=0,
        closure_ref="manifest:fixture", closure_digest="3" * 64, stage_set_digest="4" * 64,
        partition_id="partition:synthetic", lease_id="lease:synthetic", worker_session_id="session:synthetic",
        deadline_ms=60000, args={"query": "Synthetic review relationship", "limit": 10,
                                 "recipe_id": "edge_hybrid_rrf_v1"})
    value.update(updates)
    return Job.model_validate(value)


def reply(attempt, body, status=200, *, state="completed", error_code=None):
    text = json.dumps(body, separators=(",", ":")) if not isinstance(body, str) else body
    grant = Grant(attempt_id=attempt.attempt_id, grant_id=str(uuid4()),
        payload_sha256=attempt.payload_sha256,
        expires_at=(datetime.now(timezone.utc) + timedelta(seconds=60)).isoformat(),
        cancel_epoch=attempt.cancel_epoch)
    result = AttemptResult(attempt_id=attempt.attempt_id, receipt_id=str(uuid4()), state=state,
        http_status=status, body=text, body_sha256=digest(text.encode()), usage_status="unknown",
        billing_status="unknown", input_tokens=None, output_tokens=None, error_code=error_code)
    return grant, result


async def context_reply(page):
    """Scripted ACK for control mechanics only; not an independent inventory verifier."""
    return ContextAck(job_id=page.job_id, context_id=page.context_id, page_index=page.page_index,
        page_digest=digest(canonical(page.model_dump())), state="sealed",
        version_refs=[{"entry_id": e.entry_id, "version_ref": str(uuid4())} for e in page.entries],
        context_manifest_ref=str(uuid4()), context_manifest_digest="5" * 64,
        allowed_body_sha256=page.raw_body_sha256, error_code=None)
