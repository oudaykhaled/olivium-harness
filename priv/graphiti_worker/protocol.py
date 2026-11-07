"""Strict packet-4 ABI. No Graphiti imports, I/O, or authority discovery."""
from __future__ import annotations

import asyncio
import hashlib
import json
import math
import re
import struct
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, JsonValue, ValidationError, field_validator, model_validator

MAX_FRAME = 131_072
MAX_BODY = 98_304
ID = Annotated[str, Field(pattern=r"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,199}$")]
SHA = Annotated[str, Field(pattern=r"^[a-f0-9]{64}$")]
Counter = Annotated[int, Field(ge=0)]
ERRORS = frozenset("invalid_frame invalid_dto scope_denied stale_generation closure_incomplete stage_unavailable consent_required budget_exhausted cancelled deadline_exceeded provider_error response_limit worker_lost reconcile_required purge_denied".split())


class BoundaryError(Exception):
    def __init__(self, code: str):
        self.code = code if code in ERRORS else "invalid_dto"
        super().__init__(self.code)


class Strict(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True, frozen=True, hide_input_in_errors=True)


class StagePin(Strict):
    id: ID
    stage: Literal["extraction", "summary", "node_dedupe", "edge_dedupe", "embedder", "reranker", "synthesis"]
    provider: Literal["ollama", "openai", "openai_responses", "anthropic", "jev"]
    model: Annotated[str, Field(pattern=r"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$")]
    endpoint: str
    route_id: ID
    credential_ref: str | None
    config_digest: SHA
    prompt_digest: SHA
    schema_digest: SHA
    consent_revision: Counter
    input_rate: Counter
    output_rate: Counter
    max_output_tokens: Annotated[int, Field(ge=1, le=4096)]
    timeout_ms: Annotated[int, Field(ge=1, le=60000)]

    @field_validator("model")
    @classmethod
    def no_alias(cls, value: str) -> str:
        if "latest" in value.lower():
            raise ValueError("unpinned model")
        return value

    @field_validator("endpoint", "provider", "credential_ref")
    @classmethod
    def bounded_strings(cls, value: str | None) -> str | None:
        if value is not None and (not value or len(value.encode()) > 2048 or any(c in value for c in "\r\n\0")):
            raise ValueError("invalid string")
        return value

    @model_validator(mode="after")
    def identity(self) -> StagePin:
        if digest(canonical(self.model_dump(exclude={"config_digest"}))) != self.config_digest:
            raise ValueError("stage identity")
        if self.credential_ref is not None and re.fullmatch(r"HARNESSFORGE_[A-Z0-9_]{1,100}", self.credential_ref) is None:
            raise ValueError("credential reference")
        return self


class Boot(Strict):
    source_lock_digest: SHA
    backend_pin_digest: SHA
    backend_uri: str
    backend_user: str
    backend_password: str = Field(repr=False)
    database: ID
    stage_pins: Annotated[list[StagePin], Field(max_length=7)]
    stage_set_digest: SHA

    @field_validator("backend_uri")
    @classmethod
    def backend_local(cls, value: str) -> str:
        from urllib.parse import urlsplit
        uri = urlsplit(value)
        if uri.scheme != "bolt" or uri.hostname not in {"127.0.0.1", "::1", "neo4j"} or uri.username or uri.password or uri.query or uri.fragment or uri.path not in {"", "/"}:
            raise ValueError("backend denied")
        if uri.port is None or not 1 <= uri.port <= 65535:
            raise ValueError("backend port required")
        return value

    @field_validator("backend_user", "backend_password")
    @classmethod
    def secret_bound(cls, value: str) -> str:
        if len(value.encode()) > 16384 or any(c in value for c in "\r\n\0"):
            raise ValueError("invalid secret")
        return value

    @model_validator(mode="after")
    def stage_identity(self) -> Boot:
        if stage_set_digest(self.stage_pins) != self.stage_set_digest:
            raise ValueError("stage set identity")
        return self


class Ingest(Strict):
    binding_id: ID
    episode_uuid: ID
    revision_id: ID
    body_hash: SHA
    window_start: Counter
    window_end: Counter
    body: str
    reference_time: str
    time_basis: Literal["event", "effective", "capture_fallback"]
    prior_episode_ids: Annotated[list[ID], Field(max_length=24)]

    @model_validator(mode="after")
    def exact_window(self) -> Ingest:
        body = self.body.encode("utf-8")
        if not 0 < len(body) <= 4096 or self.window_end - self.window_start != len(body):
            raise ValueError("window bounds")
        if digest(body) != self.body_hash or len(set(self.prior_episode_ids)) != len(self.prior_episode_ids):
            raise ValueError("window binding")
        return self


class Search(Strict):
    query: str
    limit: Annotated[int, Field(ge=1, le=100)]
    recipe_id: Literal["edge_hybrid_rrf_v1"]

    @field_validator("query")
    @classmethod
    def bounded_query(cls, value: str) -> str:
        if not value.strip() or len(value.encode()) > 4096:
            raise ValueError("query bounds")
        return value


class PrepareRuntime(Strict):
    operation_id: ID
    partition_id: ID
    lease_id: ID
    scope_ref: ID
    stage_set_digest: SHA


class PrepareRuntimeAck(PrepareRuntime):
    initialized: bool
    source_lock_digest: SHA
    backend_pin_digest: SHA
    error_code: str | None

    @model_validator(mode="after")
    def outcome(self) -> PrepareRuntimeAck:
        if self.initialized != (self.error_code is None):
            raise ValueError("preparation outcome")
        if self.error_code is not None and self.error_code not in ERRORS:
            raise ValueError("unsafe error")
        return self


class Remove(Strict):
    episode_uuid: ID
    purge_fence_id: ID
    rebuild_closure_ref: ID


class Cancel(Strict):
    target_job_id: ID
    new_cancel_epoch: Counter


class Empty(Strict):
    pass


class Job(Strict):
    op: Literal["health", "ingest", "search", "remove", "cancel"]
    job_id: ID
    idempotency_key: ID
    scope_ref: ID
    semantic_generation: Counter
    authorization_generation: Counter
    cancel_epoch: Counter
    closure_ref: ID
    closure_digest: SHA
    stage_set_digest: SHA
    partition_id: ID | None
    lease_id: ID | None
    worker_session_id: ID
    deadline_ms: Annotated[int, Field(ge=1, le=3_600_000)]
    args: dict

    @model_validator(mode="after")
    def arguments(self) -> Job:
        {"health": Empty, "ingest": Ingest, "search": Search, "remove": Remove, "cancel": Cancel}[self.op].model_validate(self.args)
        if self.op == "health":
            if (self.partition_id is not None or self.lease_id is not None or self.scope_ref != "worker:health"
                    or self.closure_ref != "source-lock" or self.semantic_generation != 0
                    or self.authorization_generation != 0 or self.cancel_epoch != 0 or self.deadline_ms > 1000):
                raise ValueError("diagnostic health controls")
        elif self.partition_id is None or self.lease_id is None:
            raise ValueError("graph controls required")
        return self


class ContextEntry(Strict):
    entry_id: ID
    kind: Literal["episode", "summary", "attribute", "edge", "rendered_message", "embed_input", "deterministic_output"]
    object_id: ID
    version_ref: ID | None
    predecessor_version_ref: ID | None
    value_hash: SHA
    value: JsonValue
    projection_id: Literal["identity_v1", "graphiti_context_v1", "messages_v1", "embed_text_v1", "native_jev_fit_v1", "native_loader_no_vector_v1"]
    projection_hash: SHA
    parent_manifest_ref: ID
    parent_manifest_digest: SHA
    receipt_ref: ID | None

    @model_validator(mode="after")
    def value_binding(self) -> ContextEntry:
        def no_floats(value: JsonValue) -> None:
            if isinstance(value, float):
                raise ValueError("context canonical values require integers")
            if isinstance(value, list):
                for item in value:
                    no_floats(item)
            elif isinstance(value, dict):
                for item in value.values():
                    no_floats(item)
        no_floats(self.value)
        raw = canonical(self.value)
        cap = 49152 if self.kind == "rendered_message" else (4096 if self.kind in {"episode", "embed_input"} else 16384)
        if len(raw) > cap or digest(raw) != self.value_hash:
            raise ValueError("context value binding")
        if self.projection_hash != self.value_hash:
            raise ValueError("projection binding")
        _tree(self.value)
        return self


class ParentContext(Strict):
    manifest_ref: ID
    manifest_digest: SHA


class ContextPage(Strict):
    job_id: ID
    partition_id: ID
    lease_id: ID
    cancel_epoch: Counter
    semantic_generation: Counter
    authorization_generation: Counter
    operation_manifest_ref: ID
    operation_manifest_digest: SHA
    context_id: ID
    logical_call_id: ID
    phase: Literal["inputs", "derived", "attempt_bind"]
    seam_id: Literal["llm.context.v1", "llm.messages.v1", "embedder.input.v1", "http.serialized.v1",
        "graphiti.extract_nodes.v1", "graphiti.resolve_nodes.v1", "graphiti.extract_edges.v1",
        "graphiti.attributes.v1", "graphiti.summary_flight.v1", "graphiti.summary_batch.v1",
        "graphiti.temporal.v1", "graphiti.save.v1", "llm.response.v1", "graphiti.bootstrap.v1", "graphiti.search.v1"]
    stage_id: ID
    prompt_name: str
    config_digest: SHA
    schema_digest: SHA
    page_index: Counter
    previous_page_digest: SHA | None
    final: bool
    entries: Annotated[list[ContextEntry], Field(min_length=1, max_length=100)]
    base_context_ref: ID | None
    base_context_digest: SHA | None
    parent_contexts: Annotated[list[ParentContext], Field(max_length=100)]
    raw_body_sha256: SHA | None
    rendered_projection_digest: SHA | None
    transform_id: Literal["identity_v1", "graphiti_builder_v1", "official_openai_chat_v1", "official_openai_embed_v1", "native_jev_fit_v1",
        "graphiti_extract_nodes_v1", "graphiti_resolve_nodes_v1", "graphiti_extract_edges_v1",
        "graphiti_attribute_overlay_v1", "graphiti_summary_flight_v1", "graphiti_fact_append_v1",
        "graphiti_temporal_v1", "graphiti_save_v1", "model_response_v1", "root_inventory_bootstrap_v1",
        "root_search_intent_v1", "native_search_rrf_v1"]

    @model_validator(mode="after")
    def bounded_page(self) -> ContextPage:
        if not self.prompt_name or len(self.prompt_name.encode()) > 200:
            raise ValueError("prompt bounds")
        if (self.page_index == 0) != (self.previous_page_digest is None):
            raise ValueError("page chain")
        if (self.base_context_ref is None) != (self.base_context_digest is None):
            raise ValueError("base context")
        if len({entry.entry_id for entry in self.entries}) != len(self.entries):
            raise ValueError("duplicate entry")
        if len({parent.manifest_ref for parent in self.parent_contexts}) != len(self.parent_contexts):
            raise ValueError("duplicate parent context")
        if self.phase == "attempt_bind":
            if self.raw_body_sha256 is None or self.rendered_projection_digest is None or self.base_context_ref is None:
                raise ValueError("raw body binding required")
        elif self.raw_body_sha256 is not None:
            raise ValueError("unexpected raw body")
        if sum(len(canonical(e.value)) for e in self.entries if e.kind == "rendered_message") > 49152:
            raise ValueError("aggregate prompt bounds")
        if len(canonical(self.model_dump())) > MAX_BODY:
            raise ValueError("context page bounds")
        return self


class VersionRef(Strict):
    entry_id: ID
    version_ref: ID


class ContextAck(Strict):
    job_id: ID
    context_id: ID
    page_index: Counter
    page_digest: SHA
    state: Literal["page_accepted", "sealed", "denied"]
    version_refs: Annotated[list[VersionRef], Field(max_length=100)]
    context_manifest_ref: ID | None
    context_manifest_digest: SHA | None
    allowed_body_sha256: SHA | None
    error_code: str | None

    @model_validator(mode="after")
    def binding(self) -> ContextAck:
        if len({ref.entry_id for ref in self.version_refs}) != len(self.version_refs):
            raise ValueError("duplicate version ref")
        if self.state == "sealed":
            if self.context_manifest_ref is None or self.context_manifest_digest is None or self.error_code is not None:
                raise ValueError("sealed context handle")
        elif self.context_manifest_ref is not None or self.context_manifest_digest is not None or self.allowed_body_sha256 is not None:
            raise ValueError("unsealed handle")
        if self.state == "denied":
            if self.error_code not in ERRORS or self.version_refs:
                raise ValueError("unsafe denial")
        elif self.error_code is not None:
            raise ValueError("unexpected error")
        return self


class Attempt(Strict):
    job_id: ID
    logical_call_id: ID
    attempt_id: ID
    stage_id: ID
    stage_digest: SHA
    prompt_name: str
    closure_ref: ID
    closure_digest: SHA
    context_manifest_ref: ID
    context_manifest_digest: SHA
    cancel_epoch: Counter
    payload_sha256: SHA
    method: Literal["POST"]
    route_id: ID
    body: str
    timeout_ms: Annotated[int, Field(ge=1, le=60000)]
    max_output_tokens: Annotated[int, Field(ge=1, le=4096)]
    context_changed: bool
    ordinal: Annotated[int, Field(ge=1, le=3)]
    predecessor_attempt_id: ID | None

    @model_validator(mode="after")
    def binding(self) -> Attempt:
        if len(self.body.encode()) > MAX_BODY or digest(self.body.encode()) != self.payload_sha256:
            raise ValueError("payload binding")
        if (self.ordinal == 1) != (self.predecessor_attempt_id is None):
            raise ValueError("attempt predecessor")
        if not self.prompt_name or len(self.prompt_name.encode()) > 200:
            raise ValueError("prompt name")
        return self


class Grant(Strict):
    attempt_id: ID
    grant_id: ID
    payload_sha256: SHA
    expires_at: str
    cancel_epoch: Counter


class AttemptResult(Strict):
    attempt_id: ID
    receipt_id: ID
    state: Literal["completed", "denied", "cancelled", "uncertain", "stale", "invalid"]
    http_status: Annotated[int, Field(ge=100, le=599)] | None
    body: str | None
    body_sha256: SHA | None
    usage_status: Literal["reported", "unknown"]
    billing_status: Literal["estimated", "local_unpriced", "unknown"]
    input_tokens: Counter | None
    output_tokens: Counter | None
    error_code: str | None

    @model_validator(mode="after")
    def binding(self) -> AttemptResult:
        if self.error_code is not None and self.error_code not in ERRORS:
            raise ValueError("unsafe error")
        if self.body is not None and (len(self.body.encode()) > MAX_BODY or digest(self.body.encode()) != self.body_sha256):
            raise ValueError("response binding")
        if self.usage_status == "reported" and (self.input_tokens is None or self.output_tokens is None):
            raise ValueError("missing usage")
        return self


class Result(Strict):
    job_id: ID
    state: Literal["completed", "cancelled", "failed", "unavailable", "stale", "reconcile_required"]
    generation: Counter
    closure_digest: SHA
    receipt_count: Counter
    receipt_digest: SHA
    result: dict

    @model_validator(mode="after")
    def shape(self) -> Result:
        keys = set(self.result)
        variants = [
            {"error_code"}, {"version", "source_lock_digest", "backend_pin_digest", "readiness"},
            {"binding_id", "episode_uuid"}, {"candidates"}, {"cleanup_status", "version_manifest_digest"},
            {"cancelled_job_id"},
        ]
        if keys not in variants:
            raise ValueError("result shape")
        if "error_code" in keys and self.result["error_code"] not in ERRORS:
            raise ValueError("unsafe error")
        if "candidates" in keys:
            candidates = self.result["candidates"]
            if not isinstance(candidates, list) or len(candidates) > 100:
                raise ValueError("candidates bounds")
            for c in candidates:
                if not isinstance(c, dict) or set(c) != {"edge_id", "episode_ids", "score"}:
                    raise ValueError("candidate shape")
                check_id(c["edge_id"])
                if not isinstance(c["episode_ids"], list) or len(c["episode_ids"]) > 100:
                    raise ValueError("ancestry bounds")
                for episode in c["episode_ids"]:
                    check_id(episode)
                if type(c["score"]) not in (int, float) or not math.isfinite(c["score"]):
                    raise ValueError("score")
        return self


PAYLOADS = {"boot": Boot, "job": Job, "attempt": Attempt, "attempt_grant": Grant, "attempt_result": AttemptResult, "result": Result,
            "context_page": ContextPage, "context_ack": ContextAck,
            "prepare_runtime": PrepareRuntime, "prepare_runtime_ack": PrepareRuntimeAck}


class Frame(Strict):
    v: Literal[1]
    kind: Literal["boot", "job", "attempt", "attempt_grant", "attempt_result", "result", "context_page", "context_ack",
                  "prepare_runtime", "prepare_runtime_ack"]
    session_id: ID
    seq: Annotated[int, Field(ge=1)]
    request_id: ID
    payload: dict

    @model_validator(mode="after")
    def payload_shape(self) -> Frame:
        PAYLOADS[self.kind].model_validate(self.payload)
        return self


def check_id(value: object) -> None:
    if not isinstance(value, str) or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.:-]{0,199}", value) is None:
        raise ValueError("identifier")


def digest(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def canonical(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")


def stage_set_digest(pins: list[StagePin] | list[dict]) -> str:
    if len(pins) > 7:
        raise ValueError("stage set bounds")
    validated = [StagePin.model_validate(p.model_dump() if isinstance(p, StagePin) else p) for p in pins]
    if len({p.id for p in validated}) != len(validated) or len({p.stage for p in validated}) != len(validated):
        raise ValueError("duplicate stage")
    return digest(canonical({"v": 1, "pins": [p.model_dump() for p in sorted(validated, key=lambda p: p.id)]}))


def _pairs(pairs: list[tuple[str, object]]) -> dict:
    result: dict = {}
    for key, value in pairs:
        if key in result:
            raise BoundaryError("invalid_frame")
        result[key] = value
    return result


def _tree(value: object, depth: int = 0) -> None:
    if depth > 12:
        raise BoundaryError("invalid_frame")
    if isinstance(value, list):
        if len(value) > 100:
            raise BoundaryError("invalid_frame")
        for child in value:
            _tree(child, depth + 1)
    elif isinstance(value, dict):
        for child in value.values():
            _tree(child, depth + 1)
    elif isinstance(value, float) and not math.isfinite(value):
        raise BoundaryError("invalid_frame")


def decode(data: bytes) -> Frame:
    if not 1 <= len(data) <= MAX_FRAME:
        raise BoundaryError("invalid_frame")
    try:
        value = json.loads(data.decode("utf-8", errors="strict"), object_pairs_hook=_pairs,
                           parse_constant=lambda _: (_ for _ in ()).throw(BoundaryError("invalid_frame")))
        _tree(value)
        if not isinstance(value, dict) or type(value.get("v")) is not int:
            raise BoundaryError("invalid_frame")
        return Frame.model_validate(value)
    except (ValueError, UnicodeError, ValidationError, RecursionError) as error:
        raise BoundaryError("invalid_frame") from error


def encode(frame: Frame | dict) -> bytes:
    try:
        raw = canonical(frame.model_dump() if isinstance(frame, Frame) else frame)
        decode(raw)
    except (ValueError, ValidationError) as error:
        raise BoundaryError("invalid_frame") from error
    return struct.pack(">I", len(raw)) + raw


async def read_frame(reader: asyncio.StreamReader, timeout: float = 60) -> Frame:
    async with asyncio.timeout(timeout):
        prefix = await reader.readexactly(4)
        length = struct.unpack(">I", prefix)[0]
        if not 1 <= length <= MAX_FRAME:
            raise BoundaryError("invalid_frame")
        return decode(await reader.readexactly(length))
