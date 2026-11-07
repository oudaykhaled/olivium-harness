"""Actual-value context exchange. Root seals versions; this module grants nothing."""
from __future__ import annotations

import copy
import asyncio
import json
import inspect
import math
import struct
from functools import wraps
from contextlib import asynccontextmanager
from contextvars import ContextVar
from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum
from typing import Any, AsyncIterator, Awaitable, Callable
from uuid import uuid4

from lineage import CURRENT_CALL, CURRENT_LINEAGE, Call, call
from protocol import (BoundaryError, ContextAck, ContextEntry, ContextPage,
                      AttemptResult, ParentContext, StagePin, canonical, digest)
from schema_export import EMBEDDING_SCHEMA_DIGEST, native_save_completion_policy
from read_observations import (BOOTSTRAP_SCHEMA_DIGEST, BOOTSTRAP_SEAM, BOOTSTRAP_TRANSFORM,
                               LOADER_PROJECTION, registered_route, without_vector)

ObserverRelay = Callable[[ContextPage], Awaitable[ContextAck]]


@dataclass(frozen=True)
class Proof:
    manifest_ref: str
    manifest_digest: str
    body_hash: str | None
    versions: tuple[tuple[str, str], ...] = ()


@dataclass(frozen=True)
class FullReference:
    # None means root alone measured the full hash: a vector-omitting loader
    # never grants the worker knowledge of an omitted vector commitment.
    value_hash: str | None
    version_ref: str
    proof: Proof
    projected_hash: str
    readable: bool


@dataclass(frozen=True)
class LoaderReference:
    full_ref: str
    value_hash: str
    proof: Proof
    mutated: bool = False


def snapshot(value: object) -> object:
    """Reject unsupported Python objects rather than silently stringify ancestry."""
    try:
        return json.loads(canonical(value))
    except (TypeError, ValueError, UnicodeError, RecursionError) as error:
        raise BoundaryError("closure_incomplete") from error


class Observation:
    def __init__(self, pin: StagePin, prompt_name: str, context: Call,
                 relay: ObserverRelay | None, schema_digest: str):
        self.pin, self.prompt_name, self.context = pin, prompt_name, context
        self.relay, self.schema_digest = relay, schema_digest
        self.base: Proof | None = None
        self.parents: list[Proof] = []
        self.responses: list[Proof] = []

    def entry(self, kind: str, value: object, projection_id: str, *, object_id: str | None = None,
              version_ref: str | None = None, predecessor: str | None = None,
              receipt_ref: str | None = None) -> ContextEntry:
        lineage = CURRENT_LINEAGE.get()
        full = snapshot(value)
        value_hash = digest(canonical(full))
        return ContextEntry(entry_id=str(uuid4()), kind=kind, object_id=object_id or self.context.logical_call_id,
            version_ref=version_ref, predecessor_version_ref=predecessor,
            value_hash=value_hash, value=full, projection_id=projection_id,
            projection_hash=value_hash, parent_manifest_ref=lineage.job.closure_ref,
            parent_manifest_digest=lineage.job.closure_digest, receipt_ref=receipt_ref)

    async def attest(self, entries: list[ContextEntry], *, seam: str, phase: str,
                     transform: str, body_hash: str | None = None) -> Proof:
        if self.relay is None:
            raise BoundaryError("closure_incomplete")
        job = CURRENT_LINEAGE.get().job
        if job.op not in {"search", "ingest", "remove"} or job.partition_id is None or job.lease_id is None:
            raise BoundaryError("closure_incomplete")
        parents: dict[str, Proof] = {}
        for parent in self.parents:
            prior = parents.get(parent.manifest_ref)
            if prior is not None and prior.manifest_digest != parent.manifest_digest:
                raise BoundaryError("reconcile_required")
            parents[parent.manifest_ref] = parent
        if len(parents) > 100:
            raise BoundaryError("response_limit")
        payload = ContextPage(job_id=job.job_id, partition_id=job.partition_id,
            lease_id=job.lease_id, cancel_epoch=job.cancel_epoch,
            semantic_generation=job.semantic_generation, authorization_generation=job.authorization_generation,
            operation_manifest_ref=job.closure_ref, operation_manifest_digest=job.closure_digest,
            context_id=str(uuid4()), logical_call_id=self.context.logical_call_id,
            phase=phase, seam_id=seam, stage_id=self.pin.id, prompt_name=self.prompt_name,
            config_digest=self.pin.config_digest, schema_digest=self.schema_digest,
            page_index=0, previous_page_digest=None, final=True, entries=entries,
            base_context_ref=self.base.manifest_ref if self.base else None,
            base_context_digest=self.base.manifest_digest if self.base else None,
            parent_contexts=[ParentContext(manifest_ref=p.manifest_ref, manifest_digest=p.manifest_digest)
                             for p in parents.values()],
            raw_body_sha256=body_hash,
            rendered_projection_digest=digest(canonical([e.model_dump() for e in entries])),
            transform_id=transform)
        ack = ContextAck.model_validate(await self.relay(payload))
        if (ack.job_id != job.job_id or ack.context_id != payload.context_id
                or ack.page_index != payload.page_index or ack.page_digest != digest(canonical(payload.model_dump()))):
            raise BoundaryError("reconcile_required")
        if ack.state == "denied":
            raise BoundaryError(ack.error_code or "closure_incomplete")
        if (ack.state != "sealed" or ack.context_manifest_ref is None or ack.context_manifest_digest is None
                or ack.context_manifest_ref == job.closure_ref or ack.allowed_body_sha256 != body_hash):
            raise BoundaryError("closure_incomplete")
        refs = {r.entry_id for r in ack.version_refs}
        if refs != {entry.entry_id for entry in entries}:
            raise BoundaryError("closure_incomplete")
        return Proof(ack.context_manifest_ref, ack.context_manifest_digest, body_hash,
                     tuple((ref.entry_id, ref.version_ref) for ref in ack.version_refs))

    async def response(self, result: AttemptResult, request_proof: Proof) -> None:
        """Seal the exact root receipt before the SDK can consume any response."""
        if result.body is None or result.http_status is None or result.body_sha256 is None:
            raise BoundaryError("provider_error")
        if len(self.responses) >= 3:
            raise BoundaryError("budget_exhausted")
        self.parents = [request_proof, *self.responses]
        entry = self.entry("deterministic_output", {"attempt_id": result.attempt_id,
            "http_status": result.http_status, "body_bytes": len(result.body.encode()), "body_sha256": result.body_sha256},
            "identity_v1", object_id=result.attempt_id, receipt_ref=result.receipt_id)
        proof = await self.attest([entry], seam="llm.response.v1", phase="derived", transform="model_response_v1")
        self.responses.append(proof)
        self.base = proof
        frame = CURRENT_SEAM.get(None)
        if frame is not None:
            frame.child(proof)

    async def logical_response(self, value: object) -> None:
        if not self.responses:
            raise BoundaryError("closure_incomplete")
        self.parents = list(self.responses)
        entry = self.entry("deterministic_output", value, "identity_v1")
        self.base = await self.attest([entry], seam="llm.response.v1", phase="derived", transform="model_response_v1")
        frame = CURRENT_SEAM.get(None)
        if frame is not None:
            frame.child(self.base)

    async def embedding_response(self, vectors: list[list[float]]) -> None:
        if not vectors or len(vectors) > 100:
            raise BoundaryError("response_limit")
        await self.logical_response({"embedding_vectors": [vector_commitment(vector) for vector in vectors]})

    async def inputs(self, value: object, *, embed: bool = False) -> None:
        entry = self.entry("embed_input" if embed else "deterministic_output", value,
                           "embed_text_v1" if embed else "graphiti_context_v1")
        self.base = await self.attest([entry], seam="embedder.input.v1" if embed else "llm.context.v1",
                                     phase="inputs", transform="identity_v1" if embed else "graphiti_builder_v1")

    async def rendered(self, messages: list[dict]) -> None:
        if self.base is None or not messages or len(messages) > 100:
            raise BoundaryError("closure_incomplete")
        entries = [self.entry("rendered_message", message, "messages_v1") for message in snapshot(messages)]
        self.base = await self.attest(entries, seam="llm.messages.v1", phase="inputs", transform="graphiti_builder_v1")

    async def bind(self, raw: bytes) -> Proof:
        if self.base is None:
            raise BoundaryError("closure_incomplete")
        try:
            from protocol import _pairs, _tree
            body = json.loads(raw.decode("utf-8"), object_pairs_hook=_pairs,
                              parse_constant=lambda _: (_ for _ in ()).throw(ValueError("nonfinite")))
            _tree(body)
        except (ValueError, UnicodeError, RecursionError) as error:
            raise BoundaryError("invalid_dto") from error
        if not isinstance(body, dict) or body.get("model") != self.pin.model:
            raise BoundaryError("scope_denied")
        if self.pin.stage == "embedder":
            if set(body) - {"input", "model", "encoding_format", "dimensions"} or "input" not in body:
                raise BoundaryError("closure_incomplete")
            entries = [self.entry("embed_input", body["input"], "embed_text_v1")]
            transform = "official_openai_embed_v1"
        elif self.pin.provider == "jev":
            if set(body) != {"model", "state", "questions"}:
                raise BoundaryError("closure_incomplete")
            entries = [self.entry("rendered_message", {"state": body["state"], "questions": body["questions"]}, "native_jev_fit_v1")]
            transform = "native_jev_fit_v1"
        else:
            if set(body) - {"model", "messages", "temperature", "max_tokens", "response_format", "stream"} or body.get("stream", False) is not False:
                raise BoundaryError("closure_incomplete")
            messages = body.get("messages")
            if not isinstance(messages, list) or not messages or len(messages) > 100:
                raise BoundaryError("closure_incomplete")
            entries = [self.entry("rendered_message", message, "messages_v1") for message in messages]
            transform = "official_openai_chat_v1"
        return await self.attest(entries, seam="http.serialized.v1", phase="attempt_bind",
                                 transform=transform, body_hash=digest(raw))


CURRENT_OBSERVATION: ContextVar[Observation] = ContextVar("graphiti_actual_context")


def current_observation(pin: StagePin, prompt_name: str | None = None) -> Observation:
    try:
        observation, context = CURRENT_OBSERVATION.get(), CURRENT_CALL.get()
    except LookupError as error:
        raise BoundaryError("closure_incomplete") from error
    if (observation.pin != pin or observation.context is not context
            or (prompt_name is not None and observation.prompt_name != prompt_name)):
        raise BoundaryError("scope_denied")
    return observation


@asynccontextmanager
async def observed_call(pin: StagePin, prompt_name: str, inputs: object,
                        relay: ObserverRelay | None, *, schema_digest: str | None = None,
                        embed: bool = False) -> AsyncIterator[Observation]:
    with call(pin.id, prompt_name) as context:
        frame = CURRENT_SEAM.get(None)
        state = CURRENT_INTERMEDIATE.get(None)
        if state is not None and state.read_only:
            state.check_write_current()
            if (not embed or pin != state.pins.get("embedder") or prompt_name != "embedder.create"
                    or inputs != state.search_embed_input or state.search_embed_calls != 0):
                state.failure = "closure_incomplete"
                raise BoundaryError("closure_incomplete")
            state.search_embed_calls += 1
        if frame is not None:
            await frame.state.flush()
        embedding_schema = embed or pin.stage == "embedder"
        selected_schema = EMBEDDING_SCHEMA_DIGEST if embedding_schema else (schema_digest or pin.schema_digest)
        if embedding_schema and schema_digest is not None and schema_digest != EMBEDDING_SCHEMA_DIGEST:
            raise BoundaryError("scope_denied")
        observation = Observation(pin, prompt_name, context, relay, selected_schema)
        if frame is not None and frame.observation.base is not None:
            observation.parents = [frame.observation.base, *frame.children]
        token = None
        try:
            await observation.inputs(copy.deepcopy(inputs), embed=embed)
            token = CURRENT_OBSERVATION.set(observation)
            yield observation
            if state is not None and state.read_only:
                if not observation.responses or observation.base is None:
                    raise BoundaryError("closure_incomplete")
                state.search_embedding_proof = observation.base
        except BaseException:
            state = CURRENT_INTERMEDIATE.get(None)
            if state is not None:
                state.failure = state.failure or "closure_incomplete"
            raise
        finally:
            if token is not None:
                CURRENT_OBSERVATION.reset(token)


def vector_commitment(vector: list[float]) -> dict:
    if (len(vector) != 1024 or any(isinstance(item, bool) or not isinstance(item, (int, float))
        or not math.isfinite(item) for item in vector)):
        raise BoundaryError("closure_incomplete")
    return {"format": "ieee754-be-f64-v1", "length": len(vector),
            "sha256": digest(b"".join(struct.pack(">d", item) for item in vector))}


def native_value(value: object) -> object:
    """Lossless supported graph projection; vectors are separately receipt-bound.

    Full support lists are retained. Unknown objects, floats, callbacks and large
    arrays fail closed; this function never shortens provenance to meet a cap.
    """
    from pydantic import BaseModel
    if isinstance(value, Enum):
        return native_value(value.value)
    if isinstance(value, datetime):
        return value.isoformat()
    if isinstance(value, type) and issubclass(value, BaseModel):
        return {"schema": snapshot(value.model_json_schema())}
    if isinstance(value, BaseModel):
        if not type(value).__module__.startswith("graphiti_core."):
            raise BoundaryError("closure_incomplete")
        fields = value.model_dump(mode="python", exclude={"name_embedding", "fact_embedding"})
        vectors = {}
        for name in ("name_embedding", "fact_embedding"):
            vector = getattr(value, name, None)
            if vector is not None:
                vectors[name] = vector_commitment(vector)
        return {"object_type": type(value).__name__, "fields": native_value(fields), "vector_commitments": vectors}
    if isinstance(value, (list, tuple)):
        if len(value) > 100:
            raise BoundaryError("response_limit")
        return [native_value(item) for item in value]
    if isinstance(value, dict):
        if len(value) > 100:
            raise BoundaryError("response_limit")
        if all(isinstance(key, str) for key in value):
            return {key: native_value(item) for key, item in value.items()}
        # edge_type_map has tuple endpoint keys. Preserve the actual item order.
        return {"ordered_pairs": [[native_value(key), native_value(item)] for key, item in value.items()]}
    return snapshot(value)


def graph_objects(value: object) -> list[object]:
    from pydantic import BaseModel
    if isinstance(value, BaseModel) and hasattr(value, "uuid"):
        return [value]
    result: list[object] = []
    children = value.values() if isinstance(value, dict) else value if isinstance(value, (tuple, list)) else ()
    if len(children) > 100:
        raise BoundaryError("response_limit")
    for child in children:
        result.extend(graph_objects(child))
        if len(result) > 100:
            raise BoundaryError("response_limit")
    return result


@dataclass
class SeamFrame:
    state: IntermediateState
    observation: Observation
    seam: str
    transform: str
    arguments: dict[str, object]
    before: object
    children: list[Proof] = field(default_factory=list)
    last: object = None
    parent: SeamFrame | None = None
    save_method: str | None = None

    def child(self, proof: Proof) -> None:
        prior = next((p for p in self.children if p.manifest_ref == proof.manifest_ref), None)
        if prior is not None and prior.manifest_digest != proof.manifest_digest:
            raise BoundaryError("reconcile_required")
        if prior is None:
            if len(self.children) >= 100:
                raise BoundaryError("response_limit")
            self.children.append(proof)

    async def checkpoint(self) -> None:
        """Catch deterministic fact appends before a flight consumes any node."""
        current = native_value(self.arguments)
        if current != self.last:
            await self.state.certify(self, self.arguments, {"before": self.last, "after": current},
                                     phase="derived", transform="graphiti_fact_append_v1")
            self.last = current


CURRENT_SEAM: ContextVar[SeamFrame] = ContextVar("graphiti_intermediate_seam")
CURRENT_INTERMEDIATE: ContextVar[IntermediateState] = ContextVar("graphiti_intermediate_operation")
TEMPORAL_ACTIVE: ContextVar[bool] = ContextVar("graphiti_temporal_active", default=False)
SAVE_ACTIVE: ContextVar[bool] = ContextVar("graphiti_save_active", default=False)
SAVE_INVOCATION: ContextVar[object | None] = ContextVar("graphiti_save_invocation", default=None)


class IntermediateState:
    """Only ephemeral caches of root ACKs. Root independently owns every version."""
    def __init__(self, pins: dict[str, StagePin], relay: ObserverRelay | None, *, read_only: bool = False):
        self.pins, self.relay = pins, relay
        self.read_only = read_only
        self.search_embed_input: list[str] | None = None
        self.search_embed_calls = 0
        self.search_embedding_proof: Proof | None = None
        if read_only:
            from search_observations import search_input
            lineage = CURRENT_LINEAGE.get(None)
            if lineage is None:
                raise BoundaryError("closure_incomplete")
            inputs = search_input(lineage.job)
            self.search_embed_input = [inputs["query"].replace("\n", " ")]
        self.versions: dict[tuple[str, str], tuple[str, str, Proof]] = {}
        self.full_refs: dict[tuple[str, str], FullReference] = {}
        self.loader_views: dict[tuple[str, str], LoaderReference] = {}
        self.pending: list[tuple[SeamFrame, object, object]] = []
        self.flushing = False
        self.failure: str | None = None
        self.write_gate = asyncio.Lock()
        self.write_owner: asyncio.Task | None = None
        self.write_invocation: object | None = None
        self.write_method: str | None = None
        self.read_owner: asyncio.Task | None = None

    def check_write_current(self) -> None:
        if self.failure is not None:
            raise BoundaryError(self.failure)
        task = asyncio.current_task()
        if task is None or task.cancelling():
            raise asyncio.CancelledError()

    def require_mutation(self) -> None:
        if self.read_only:
            self.failure = self.failure or "closure_incomplete"
            raise BoundaryError("closure_incomplete")
        self.check_write_current()

    def require_write_owner(self, method: str | None) -> None:
        self.require_mutation()
        self.check_write_current()
        if (not self.write_gate.locked() or self.write_owner is not asyncio.current_task()
                or self.write_invocation is None or SAVE_INVOCATION.get() is not self.write_invocation
                or self.write_method != method):
            raise BoundaryError("closure_incomplete")

    @asynccontextmanager
    async def save_scope(self, method: str | None) -> AsyncIterator[None]:
        """Exclude sibling writes before input capture through committed ACK."""
        acquired, token = False, None
        try:
            self.require_mutation()
            self.check_write_current()
            if self.write_owner is asyncio.current_task() or self.read_owner is asyncio.current_task():
                # The qualified bulk path uses tx.run, never reentrant saves.
                raise BoundaryError("closure_incomplete")
            await self.write_gate.acquire()
            acquired = True
            self.check_write_current()
            self.write_owner = asyncio.current_task()
            self.write_invocation = object()
            self.write_method = method
            token = SAVE_INVOCATION.set(self.write_invocation)
            yield
            self.require_write_owner(method)
        except BaseException:
            # Includes a cancelled waiter. Poison before any owned gate opens.
            self.failure = self.failure or "closure_incomplete"
            raise
        finally:
            if acquired:
                if token is not None:
                    SAVE_INVOCATION.reset(token)
                self.write_owner = self.write_invocation = self.write_method = None
                self.write_gate.release()

    @asynccontextmanager
    async def read_scope(self) -> AsyncIterator[None]:
        """Hold the SAME gate before the actual read through ACK/cache seed."""
        acquired = False
        try:
            self.check_write_current()
            if asyncio.current_task() in (self.read_owner, self.write_owner):
                raise BoundaryError("closure_incomplete")
            await self.write_gate.acquire()
            acquired = True
            self.read_owner = asyncio.current_task()
            self.check_write_current()
            yield
            self.check_write_current()
        except BaseException:
            self.failure = self.failure or "closure_incomplete"
            raise
        finally:
            if acquired:
                self.read_owner = None
                self.write_gate.release()

    def reserve_cache(self, keys: set[tuple[str, str]], read_keys: set[tuple[str, str]] | None = None) -> None:
        # Metadata for the same full V is one entry; an additional consumed
        # read-view identity and each changed-view V count independently.
        current = set(self.versions) | set(self.full_refs)
        current |= {("read_view", kind + ":" + identity) for kind, identity in self.loader_views}
        current |= keys
        current |= {("read_view", kind + ":" + identity) for kind, identity in read_keys or set()}
        if len(current) > 100:
            self.failure = "response_limit"
            raise BoundaryError("response_limit")

    @staticmethod
    def view_key(obj: Any) -> tuple[str, str]:
        return "deterministic_output", "loader_view:" + type(obj).__name__ + ":" + obj.uuid

    async def observe_read(self, result: object, route: str, object_type: str) -> None:
        from graphiti_core import nodes, edges
        classes = {"EpisodicNode": nodes.EpisodicNode, "EntityNode": nodes.EntityNode,
                   "EntityEdge": edges.EntityEdge}
        if (self.read_owner is not asyncio.current_task() or not self.write_gate.locked()
                or object_type not in classes or not registered_route(route, object_type)):
            raise BoundaryError("closure_incomplete")
        objects = graph_objects(result)
        if not isinstance(result, (list, tuple, classes[object_type])):
            raise BoundaryError("closure_incomplete")
        if isinstance(result, (list, tuple)) and len(objects) != len(result):
            raise BoundaryError("closure_incomplete")
        unique, hashes = [], {}
        lineage = CURRENT_LINEAGE.get()
        parent = CURRENT_SEAM.get(None)
        for obj in objects:
            if type(obj) is not classes[object_type] or obj.group_id != lineage.job.scope_ref:
                raise BoundaryError("scope_denied")
            value = native_value(obj)
            identity = type(obj).__name__, obj.uuid
            value_hash = digest(canonical(value))
            if identity in hashes:
                if hashes[identity] != value_hash:
                    raise BoundaryError("reconcile_required")
                continue
            hashes[identity] = value_hash
            key = _object_kind(obj), obj.uuid
            projected = object_type in {"EntityNode", "EntityEdge"} and not value["vector_commitments"]
            if object_type in {"EntityNode", "EntityEdge"}:
                without_vector(value)  # exact empty-attributes profile
            full = self.full_refs.get(key)
            if full is not None:
                expected = full.projected_hash if projected else full.value_hash
                view = self.loader_views.get(key)
                if (not full.readable or expected != value_hash
                        or (view is not None and view.mutated and view.full_ref == full.version_ref)):
                    raise BoundaryError("reconcile_required")
                if projected:
                    self.reserve_cache(set(), {key})
                    self.loader_views[key] = LoaderReference(full.version_ref, value_hash, full.proof)
                if parent is not None:
                    parent.child(full.proof)
                continue
            if key in self.versions:
                raise BoundaryError("closure_incomplete")
            unique.append((obj, key, value, LOADER_PROJECTION if projected else "identity_v1"))
        for offset in range(0, len(unique), 10):
            batch = unique[offset:offset + 10]
            pin = self.pins.get("extraction")
            if pin is None:
                raise BoundaryError("stage_unavailable")
            observation = Observation(pin, BOOTSTRAP_SEAM, Call(pin.id, BOOTSTRAP_SEAM),
                                      self.relay, BOOTSTRAP_SCHEMA_DIGEST)
            entries, bindings, keys, read_keys = [], [], set(), set()
            for obj, key, value, policy in batch:
                entry = observation.entry(key[0], value, policy,
                    object_id=type(obj).__name__ + ":" + obj.uuid)
                entries.append(entry)
                bindings.append((entry, key, value, policy))
                keys.add(key)
                if policy == LOADER_PROJECTION:
                    read_keys.add(key)
                if type(obj).__name__ == "EntityNode":
                    for kind, scalar in (("summary", obj.summary), ("attribute", obj.attributes)):
                        scalar_entry = observation.entry(kind, native_value(scalar), "identity_v1",
                            object_id="EntityNode:" + obj.uuid)
                        entries.append(scalar_entry)
                        bindings.append((scalar_entry, (kind, obj.uuid), None, "identity_v1"))
                        keys.add((kind, obj.uuid))
            self.reserve_cache(keys, read_keys)
            proof = await observation.attest(entries, seam=BOOTSTRAP_SEAM, phase="inputs",
                                             transform=BOOTSTRAP_TRANSFORM)
            self.check_write_current()
            refs = dict(proof.versions)
            for entry, key, value, policy in bindings:
                if value is None:
                    self.versions[key] = entry.value_hash, refs[entry.entry_id], proof
                    continue
                projected_hash = digest(canonical(without_vector(value))) if value["object_type"] in {"EntityNode", "EntityEdge"} else entry.value_hash
                self.full_refs[key] = FullReference(entry.value_hash if policy == "identity_v1" else None,
                    refs[entry.entry_id], proof, projected_hash, True)
                if policy == LOADER_PROJECTION:
                    self.loader_views[key] = LoaderReference(refs[entry.entry_id], entry.value_hash, proof)
                else:
                    self.versions[key] = entry.value_hash, refs[entry.entry_id], proof
            if parent is not None:
                parent.child(proof)

    def current(self, obj: Any) -> tuple[str, str, Proof] | None:
        key = _object_kind(obj), obj.uuid
        view, full = self.loader_views.get(key), self.full_refs.get(key)
        value_hash = digest(canonical(native_value(obj)))
        if view is not None and not native_value(obj)["vector_commitments"]:
            if full is None or view.full_ref != full.version_ref or view.value_hash != value_hash:
                return None
            if view.mutated:
                return self.versions.get(self.view_key(obj))
            return value_hash, full.version_ref, view.proof
        known = self.versions.get(key)
        return known if known is not None and known[0] == value_hash else None

    async def certify(self, frame: SeamFrame, values: object, detail: object, *, phase: str,
                      transform: str | None = None, extra: list[ContextEntry] | None = None) -> Proof:
        self.require_mutation()
        if self.failure is not None:
            raise BoundaryError(self.failure)
        observation = frame.observation
        entries: list[ContextEntry] = []
        native_updates: dict[str, tuple[str, tuple[str, str], object]] = {}
        overrides = {(entry.kind, entry.object_id) for entry in extra or []}
        identities: dict[tuple[str, str], str] = {}
        for obj in graph_objects(values):
            native = native_value(obj)
            identity = type(obj).__name__, obj.uuid
            native_hash = digest(canonical(native))
            if identity in identities:
                if identities[identity] != native_hash:
                    raise BoundaryError("reconcile_required")
                continue
            identities[identity] = native_hash
            key = _object_kind(obj), obj.uuid
            full, view = self.full_refs.get(key), self.loader_views.get(key)
            previous_view = self.versions.get(self.view_key(obj))
            if view is not None:
                if full is None:
                    raise BoundaryError("closure_incomplete")
                frame.child(full.proof)
                if previous_view is not None:
                    frame.child(previous_view[2])
            if view is not None and not native["vector_commitments"]:
                without_vector(native)
                unchanged_read = (not view.mutated and view.full_ref == full.version_ref
                                  and view.value_hash == native_hash)
                if unchanged_read:
                    frame.child(view.proof)
                    entry = observation.entry(key[0], native, LOADER_PROJECTION, object_id=obj.uuid,
                                              version_ref=full.version_ref)
                    native_updates[entry.entry_id] = "read", key, obj
                else:
                    # A changed partial view has its OWN identity/predecessor.
                    # It cannot turn absent vectors into a new full native V.
                    same_view = previous_view is not None and previous_view[0] == native_hash
                    entry = observation.entry("deterministic_output", native, "identity_v1",
                        object_id=self.view_key(obj)[1],
                        version_ref=previous_view[1] if same_view else None,
                        predecessor=previous_view[1] if previous_view is not None and not same_view else None)
                    native_updates[entry.entry_id] = "view", key, obj
                entries.append(entry)
            else:
                known = self.versions.get(key)
                predecessor = full.version_ref if full is not None else known[1] if known else None
                unchanged = ((full is not None and full.value_hash == native_hash)
                             or (full is None and known is not None and known[0] == native_hash))
                if full is not None:
                    frame.child(full.proof)
                elif known is not None:
                    frame.child(known[2])
                entry = observation.entry(key[0], native, "identity_v1", object_id=obj.uuid,
                    version_ref=predecessor if unchanged else None,
                    predecessor=predecessor if predecessor is not None and not unchanged else None)
                entries.append(entry)
                native_updates[entry.entry_id] = "full", key, obj
            projected = []
            if type(obj).__name__ == "EntityNode":
                projected.extend([("summary", native_value(obj.summary)), ("attribute", native_value(obj.attributes))])
            for kind, value in projected:
                if (kind, obj.uuid) in overrides:
                    continue
                known = self.versions.get((kind, obj.uuid))
                unchanged = known is not None and known[0] == digest(canonical(value))
                if known is not None:
                    frame.child(known[2])
                entries.append(observation.entry(kind, value, "identity_v1", object_id=obj.uuid,
                    version_ref=known[1] if unchanged else None,
                    predecessor=known[1] if known is not None and not unchanged else None))
        entries.extend(extra or [])
        entries.append(observation.entry("deterministic_output", detail, "identity_v1"))
        if len(entries) > 100:
            raise BoundaryError("response_limit")
        keys = {(entry.kind, entry.object_id) for entry in entries
                if native_updates.get(entry.entry_id, (None,))[0] != "read"}
        keys |= {key for mode, key, _ in native_updates.values() if mode in {"read", "full"}}
        self.reserve_cache(keys)
        observation.parents = list(frame.children)
        try:
            proof = await observation.attest(entries, seam=frame.seam, phase=phase,
                                             transform=transform or frame.transform)
        except BaseException:
            self.failure = "closure_incomplete"
            raise
        refs = dict(proof.versions)
        for entry in entries:
            key = (entry.kind, entry.object_id)
            update = native_updates.get(entry.entry_id)
            if update is not None:
                mode, native_key, obj = update
                if mode == "read":
                    full = self.full_refs[native_key]
                    if refs[entry.entry_id] != full.version_ref:
                        self.failure = "reconcile_required"
                        raise BoundaryError("reconcile_required")
                    self.loader_views[native_key] = LoaderReference(full.version_ref, entry.value_hash, proof)
                    continue
                if mode == "view":
                    self.loader_views[native_key] = LoaderReference(self.full_refs[native_key].version_ref,
                                                                  entry.value_hash, proof, True)
                else:
                    previous = self.full_refs.get(native_key)
                    value = entry.value
                    # Only the closed empty-attributes read profile can use
                    # this secondary hash. Other native values retain their
                    # existing observation semantics but cannot enter a loader.
                    projected_hash = (digest(canonical(without_vector(value)))
                        if type(obj).__name__ in {"EntityNode", "EntityEdge"}
                        and value["fields"].get("attributes") == {} else entry.value_hash)
                    readable = ((previous is not None and previous.readable
                                 and previous.version_ref == refs[entry.entry_id])
                                or (frame.save_method is not None and phase == "derived"))
                    self.full_refs[native_key] = FullReference(entry.value_hash, refs[entry.entry_id],
                                                              proof, projected_hash, readable)
            self.versions[key] = (entry.value_hash, refs[entry.entry_id], proof)
        observation.base = proof
        frame.children.clear()
        return proof

    async def flush(self) -> None:
        if self.failure is not None:
            raise BoundaryError(self.failure)
        if self.flushing:
            return
        self.flushing = True
        try:
            while self.pending:
                frame, before, after = self.pending.pop(0)
                proof = await self.certify(frame, {}, {"before": before, "after": after},
                    phase="derived", transform="graphiti_temporal_v1")
                # Register exact immutable after-values, not mutable edge references.
                for obj in graph_objects(frame.arguments):
                    if native_value(obj) not in after:
                        self.failure = "closure_incomplete"
                        raise BoundaryError("closure_incomplete")
                frame.child(proof)
                registered = await self.certify(frame, frame.arguments, {"temporal_context": proof.manifest_ref}, phase="derived")
                if frame.parent is not None:
                    frame.parent.child(registered)
        finally:
            self.flushing = False


@asynccontextmanager
async def intermediate_operation(pins: dict[str, StagePin], relay: ObserverRelay | None,
                                 *, read_only: bool = False) -> AsyncIterator[IntermediateState]:
    if CURRENT_INTERMEDIATE.get(None) is not None:
        raise BoundaryError("scope_denied")
    state = IntermediateState(pins, relay, read_only=read_only)
    token = CURRENT_INTERMEDIATE.set(state)
    try:
        yield state
        await state.flush()
    finally:
        CURRENT_INTERMEDIATE.reset(token)


_PRIVATE_ARGS = frozenset({"clients", "llm_client", "driver", "embedder", "tx"})


def _arguments(original: Callable, args: tuple, kwargs: dict) -> dict[str, object]:
    bound = inspect.signature(original).bind(*args, **kwargs)
    bound.apply_defaults()
    values = {key: value for key, value in bound.arguments.items() if key not in _PRIVATE_ARGS and key != "self"}
    # Node/edge save methods carry their value in self, unlike Graphiti methods.
    owner = bound.arguments.get("self")
    if hasattr(owner, "uuid"):
        values["object"] = owner
    if values.get("saga") is not None or values.get("saga_previous_episode_uuid") is not None:
        raise BoundaryError("closure_incomplete")
    native_value(values)  # reject unsupported callbacks before upstream delegation
    return values


def _save_profile(original: Callable, args: tuple, kwargs: dict, method: str | None,
                  arguments: dict[str, object]) -> str | None:
    """Select only the qualified Neo4j native path before a possible mutation."""
    from graphiti_core import nodes, edges
    from graphiti_core.driver.driver import GraphProvider
    from graphiti_core.driver.neo4j_driver import Neo4jDriver
    from pydantic import TypeAdapter, ValidationError
    from protocol import ID

    variants = {variant["method"]: variant for variant in native_save_completion_policy()["variants"]}
    if method not in variants:
        raise BoundaryError("closure_incomplete")
    bound = inspect.signature(original).bind(*args, **kwargs)
    driver = bound.arguments.get("driver")
    if (type(driver) is not Neo4jDriver or driver.provider is not GraphProvider.NEO4J
            or driver.graph_operations_interface is not None):
        raise BoundaryError("closure_incomplete")
    if method == "add_nodes_and_edges_bulk":
        return None
    classes = {"EntityNode.save": nodes.EntityNode, "EpisodicNode.save": nodes.EpisodicNode,
               "EntityEdge.save": edges.EntityEdge, "EpisodicEdge.save": edges.EpisodicEdge}
    obj = arguments.get("object")
    if type(obj) is not classes[method]:
        raise BoundaryError("closure_incomplete")
    try:
        return TypeAdapter(ID).validate_python(obj.uuid, strict=True)
    except ValidationError as error:
        raise BoundaryError("closure_incomplete") from error


def _save_completion(method: str, result: object, expected_uuid: str | None) -> dict:
    """Project a known return position, never serialize an opaque driver result."""
    from neo4j import EagerResult, Record

    if method == "add_nodes_and_edges_bulk":
        if result is not None or expected_uuid is not None:
            raise BoundaryError("closure_incomplete")
        kind, returned = "none", None
    else:
        individual = {variant["method"] for variant in native_save_completion_policy()["variants"]
                      if variant["return_kind"] == "neo4j-eager-uuid"}
        if (method not in individual or expected_uuid is None or type(result) is not EagerResult
                or type(result.keys) is not list or result.keys != ["uuid"]
                or type(result.records) is not list or len(result.records) != 1):
            raise BoundaryError("closure_incomplete")
        record = result.records[0]
        if type(record) is not Record or record.keys() != ["uuid"]:
            raise BoundaryError("closure_incomplete")
        returned = record["uuid"]
        if type(returned) is not str or returned != expected_uuid:
            raise BoundaryError("closure_incomplete")
        kind = "neo4j-eager-uuid"
    return {"format": "native-save-completion-v1", "method": method,
            "return_kind": kind, "returned_uuid": returned}


def _wrap_async(original: Callable, seam: str, transform: str, stage: str, *, save: bool = False,
                save_method: str | None = None) -> Callable:
    async def observe(state: IntermediateState, args: tuple, kwargs: dict) -> Any:
        await state.flush()
        parent = CURRENT_SEAM.get(None)
        if parent is not None and parent.seam == "graphiti.summary_batch.v1":
            await parent.checkpoint()
        arguments = _arguments(original, args, kwargs)
        saved_uuid = _save_profile(original, args, kwargs, save_method, arguments) if save else None
        pin = state.pins[stage]
        context = Call(pin.id, seam)
        observation = Observation(pin, seam, context, state.relay, digest(canonical({"seam": seam, "v": 1})))
        frame = SeamFrame(state, observation, seam, transform, arguments, native_value(arguments))
        frame.parent = parent
        frame.save_method = save_method if save else None
        if parent is not None and parent.observation.base is not None:
            frame.child(parent.observation.base)
            for proof in parent.children:
                frame.child(proof)
        token = CURRENT_SEAM.set(frame)
        save_token = None
        try:
            await state.certify(frame, arguments, {"arguments": frame.before}, phase="inputs")
            frame.last = native_value(arguments)
            if save:
                state.require_write_owner(save_method)
                save_token = SAVE_ACTIVE.set(True)
            result = await original(*args, **kwargs)  # exactly one native delegation
            await state.flush()
            projected_result = _save_completion(save_method, result, saved_uuid) if save else native_value(result)
            if save and saved_uuid is not None and arguments["object"].uuid != saved_uuid:
                raise BoundaryError("closure_incomplete")
            extra = []
            if seam == "graphiti.attributes.v1":
                node = arguments["node"]
                previous = state.versions.get(("attribute", node.uuid))
                extra = [observation.entry("attribute", native_value(result), "identity_v1", object_id=node.uuid,
                    predecessor=previous[1] if previous else None)]
            proof = await state.certify(frame, arguments if save else [arguments, result],
                {"before": frame.before, "after": native_value(arguments), "result": projected_result},
                phase="derived", extra=extra)
            if parent is not None:
                parent.child(proof)
                if parent.seam == "graphiti.summary_batch.v1" and seam == "graphiti.summary_flight.v1":
                    parent.last = native_value(parent.arguments)
            return result
        except BaseException:
            # Upstream catches some timestamp/rebuild exceptions. Poisoning the
            # operation prevents later consumption/save from hiding a denied ACK.
            state.failure = state.failure or "closure_incomplete"
            raise
        finally:
            if save_token is not None:
                SAVE_ACTIVE.reset(save_token)
            CURRENT_SEAM.reset(token)

    @wraps(original)
    async def wrapped(*args: Any, **kwargs: Any) -> Any:
        state = CURRENT_INTERMEDIATE.get(None)
        if state is None or stage not in state.pins:
            raise BoundaryError("closure_incomplete")
        state.require_mutation()  # before arguments, native values, or delegation
        if save:
            async with state.save_scope(save_method):
                return await observe(state, args, kwargs)
        return await observe(state, args, kwargs)
    return wrapped


def _guard_bulk_transaction(original: Callable) -> Callable:
    @wraps(original)
    async def guarded(*args: Any, **kwargs: Any) -> Any:
        state = CURRENT_INTERMEDIATE.get(None)
        if state is None:
            raise BoundaryError("closure_incomplete")
        try:
            state.require_mutation()
            if not SAVE_ACTIVE.get():
                raise BoundaryError("closure_incomplete")
            state.require_write_owner("add_nodes_and_edges_bulk")
            result = await original(*args, **kwargs)
            state.require_write_owner("add_nodes_and_edges_bulk")
            return result
        except BaseException:
            state.failure = state.failure or "closure_incomplete"
            raise
    return guarded


def _wrap_temporal(original: Callable) -> Callable:
    @wraps(original)
    def wrapped(resolved_edge: Any, invalidation_candidates: list) -> Any:
        state, parent = CURRENT_INTERMEDIATE.get(None), CURRENT_SEAM.get(None)
        if state is not None:
            state.require_mutation()
        objects = [resolved_edge, *invalidation_candidates]
        if (state is None or parent is None or len(state.pending) >= 100 or state.failure is not None
                or len(objects) > 100 or any(state.current(obj) is None for obj in objects)):
            raise BoundaryError("closure_incomplete")
        before = native_value(objects)
        token = TEMPORAL_ACTIVE.set(True)
        try:
            result = original(resolved_edge, invalidation_candidates)
        finally:
            TEMPORAL_ACTIVE.reset(token)
        pin = parent.observation.pin
        temporal_observation = Observation(pin, "graphiti.temporal.v1", Call(pin.id, "graphiti.temporal.v1"),
                                           state.relay, digest(canonical({"seam": "graphiti.temporal.v1", "v": 1})))
        frame = SeamFrame(state, temporal_observation, "graphiti.temporal.v1", "graphiti_temporal_v1",
                          {"edges": objects}, before)
        frame.parent = parent
        # Retain pre-mutation certified handles even though objects now changed.
        for obj in objects:
            known = state.current(obj)
            if known is None:
                # Objects have already mutated; use the certified before-value
                # captured by the current full/read/view cache, never guess.
                view = state.loader_views.get((_object_kind(obj), obj.uuid))
                known = (state.versions.get(state.view_key(obj)) if view is not None and view.mutated
                         else (view.value_hash, view.full_ref, view.proof) if view is not None
                         else state.versions.get((_object_kind(obj), obj.uuid)))
            if known is None:
                raise BoundaryError("closure_incomplete")
            frame.child(known[2])
            full = state.full_refs.get((_object_kind(obj), obj.uuid))
            if full is not None:
                frame.child(full.proof)
        state.pending.append((frame, before, native_value(objects)))
        return result
    return wrapped


def _object_kind(obj: object) -> str:
    return {"EntityEdge": "edge", "EpisodicNode": "episode"}.get(type(obj).__name__, "deterministic_output")


def install_intermediate_hooks() -> None:
    """Dedicated worker process only; run after pinned source verification.

    Replace actual imported aliases as well as definitions. All originals are
    delegated once, and every patched mutation entry requires an active scope.
    """
    import graphiti_core.graphiti as graph
    from graphiti_core import nodes, edges
    from graphiti_core.utils import bulk_utils
    from graphiti_core.utils.maintenance import node_operations as node, edge_operations as edge
    if getattr(graph, "_harnessforge_observers_v1", False):
        return
    plans = [
        (node, "extract_nodes", "graphiti.extract_nodes.v1", "graphiti_extract_nodes_v1", "extraction"),
        (node, "resolve_extracted_nodes", "graphiti.resolve_nodes.v1", "graphiti_resolve_nodes_v1", "node_dedupe"),
        (node, "_collect_candidate_nodes", "graphiti.resolve_nodes.v1", "graphiti_resolve_nodes_v1", "node_dedupe"),
        (node, "_extract_entity_attributes", "graphiti.attributes.v1", "graphiti_attribute_overlay_v1", "extraction"),
        (node, "_process_summary_flight", "graphiti.summary_flight.v1", "graphiti_summary_flight_v1", "summary"),
        (node, "_extract_entity_summaries_batch", "graphiti.summary_batch.v1", "graphiti_fact_append_v1", "summary"),
        (edge, "extract_edges", "graphiti.extract_edges.v1", "graphiti_extract_edges_v1", "extraction"),
        (edge, "_dedupe_extracted_edge", "graphiti.extract_edges.v1", "graphiti_extract_edges_v1", "edge_dedupe"),
        (edge, "_extract_edge_timestamps", "graphiti.temporal.v1", "graphiti_temporal_v1", "extraction"),
        (graph.Graphiti, "_extract_and_resolve_edges", "graphiti.extract_edges.v1", "graphiti_extract_edges_v1", "edge_dedupe"),
        (graph.Graphiti, "_process_episode_data", "graphiti.save.v1", "graphiti_save_v1", "extraction"),
        (bulk_utils, "add_nodes_and_edges_bulk", "graphiti.save.v1", "graphiti_save_v1", "extraction"),
    ]
    # These are the imported binding sites on the released single-episode path.
    modules = (graph, node, edge, bulk_utils)
    for owner, name, seam, transform, stage in plans:
        original = getattr(owner, name)
        bulk_save = name == "add_nodes_and_edges_bulk"
        replacement = _wrap_async(original, seam, transform, stage, save=bulk_save,
                                  save_method=name if bulk_save else None)
        setattr(owner, name, replacement)
        for module in modules:
            if getattr(module, name, None) is original:
                setattr(module, name, replacement)
    edge._apply_temporal_invalidation = _wrap_temporal(edge._apply_temporal_invalidation)
    contradictions = edge.resolve_edge_contradictions
    @wraps(contradictions)
    def guarded_contradictions(*args: Any, **kwargs: Any) -> Any:
        state = CURRENT_INTERMEDIATE.get(None)
        if state is not None:
            state.require_mutation()
        if not TEMPORAL_ACTIVE.get():
            raise BoundaryError("closure_incomplete")
        return contradictions(*args, **kwargs)
    edge.resolve_edge_contradictions = guarded_contradictions
    bulk_utils.add_nodes_and_edges_bulk_tx = _guard_bulk_transaction(bulk_utils.add_nodes_and_edges_bulk_tx)
    for cls in (nodes.EntityNode, nodes.EpisodicNode, edges.EntityEdge, edges.EpisodicEdge):
        cls.save = _wrap_async(cls.save, "graphiti.save.v1", "graphiti_save_v1", "extraction",
                               save=True, save_method=cls.__name__ + ".save")
    add_episode = graph.Graphiti.add_episode
    @wraps(add_episode)
    async def guarded_episode(*args: Any, **kwargs: Any) -> Any:
        state = CURRENT_INTERMEDIATE.get(None)
        if state is not None:
            state.require_mutation()
        bound = inspect.signature(add_episode).bind(*args, **kwargs)
        bound.apply_defaults()
        values = bound.arguments
        if (CURRENT_INTERMEDIATE.get(None) is None or values["previous_episode_uuids"] is None
                or values["uuid"] is None or values["update_communities"]
                or values["saga"] is not None or values["saga_previous_episode_uuid"] is not None):
            raise BoundaryError("closure_incomplete")
        return await add_episode(*args, **kwargs)
    graph.Graphiti.add_episode = guarded_episode
    # Bulk/combined extraction, triplet, removal, community and saga paths have
    # additional mutation/catch/rebuild semantics and are intentionally denied.
    for name in ("add_episode_bulk", "add_triplet", "remove_episode", "build_communities"):
        if hasattr(graph.Graphiti, name):
            async def unavailable(*args: Any, **kwargs: Any) -> Any:
                raise BoundaryError("closure_incomplete")
            setattr(graph.Graphiti, name, unavailable)
    from read_observations import install_read_hooks
    install_read_hooks()
    graph._harnessforge_observers_v1 = True
