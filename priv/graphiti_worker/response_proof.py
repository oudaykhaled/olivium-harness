"""Isolated native-client receipt replay; never execution or send authority.

Root launches this fixed entrypoint with network=none and immutable image files.
Inputs are privately retained settled evidence, never worker-created authority.
Replay options are a qualified profile, not attestation of unobserved kwargs.
"""
from __future__ import annotations

import asyncio
import importlib.metadata
import json
import logging
import os
import platform
import struct
import sys
from pathlib import Path, PurePosixPath
from types import SimpleNamespace
from typing import Annotated, BinaryIO, Literal

os.environ["GRAPHITI_TELEMETRY_ENABLED"] = "false"
os.environ["PYTHON_DOTENV_DISABLED"] = "1"
if __name__ == "__main__":
    for _key in tuple(os.environ):
        if (_key.endswith(("_API_KEY", "_TOKEN")) or _key.lower().endswith("_proxy")
                or _key.startswith(("OPENAI_", "ANTHROPIC_", "JEV_", "OTEL_", "HARNESSFORGE_"))):
            os.environ.pop(_key, None)
    sys.path.insert(0, str(Path(__file__).resolve().parent))
logging.disable(logging.CRITICAL)

import httpx
from openai import AsyncOpenAI
from openai.types.chat import ChatCompletion, ChatCompletionMessage
from openai.types.chat.chat_completion import Choice
from pydantic import Field, field_validator, model_validator
from graphiti_core.embedder.openai import OpenAIEmbedder, OpenAIEmbedderConfig
from graphiti_core.llm_client.config import LLMConfig, ModelSize, DEFAULT_TEMPERATURE
from graphiti_core.llm_client.jev_client import JevClient
from graphiti_core.llm_client.openai_generic_client import OpenAIGenericClient
from graphiti_core.prompts.lib import BUILTIN_PROMPT_SPECS, resolve_response_model
from graphiti_core.prompts.models import Message

from observations import vector_commitment
from protocol import BoundaryError, ID, SHA, StagePin, Strict, canonical, digest, _pairs
from schema_export import (FORMAT, PROMPT_STAGES, EMBEDDING_SCHEMA_DIGEST,
                           embedding_output_descriptor, _embedding_profile)

BASE = Path(__file__).resolve().parent
SOURCE_PATH = BASE / "source.lock.json"
CATALOGUE_PATH = BASE / "schema-catalogue.json"
DEPENDENCIES_PATH = BASE / "dependencies.lock.json"
MAX_REQUEST, MAX_RESPONSE, MAX_BODY, MAX_MESSAGES = 524288, 98304, 98304, 49152
MAX_REPLAY_SECONDS = 30


def bounded(value: object, depth: int = 0) -> None:
    if depth > 12 or isinstance(value, float):
        raise BoundaryError("invalid_dto")
    if isinstance(value, dict):
        if len(value) > 100 or any(type(key) is not str for key in value):
            raise BoundaryError("response_limit")
        for item in value.values():
            bounded(item, depth + 1)
    elif isinstance(value, list):
        if len(value) > 100:
            raise BoundaryError("response_limit")
        for item in value:
            bounded(item, depth + 1)
    elif value is not None and type(value) not in (str, int, bool):
        raise BoundaryError("invalid_dto")


class RenderedMessage(Strict):
    role: Literal["system", "user"]
    content: str


class Options(Strict):
    max_tokens: Annotated[int, Field(ge=1, le=4096)]
    model_size: Literal["medium"]
    attribute_extraction: Literal[False]

    @field_validator("attribute_extraction", mode="before")
    @classmethod
    def exact_false(cls, value):
        if value is not False:
            raise ValueError("unsupported replay option")
        return value


class Receipt(Strict):
    attempt_id: ID
    receipt_id: ID
    ordinal: Annotated[int, Field(ge=1, le=3)]
    predecessor_attempt_id: ID | None
    method: Literal["POST"]
    endpoint: str
    request_body_sha256: SHA
    http_status: Annotated[int, Field(ge=100, le=599)]
    body: str
    body_sha256: SHA

    @model_validator(mode="after")
    def exact_body(self):
        raw = self.body.encode("utf-8", errors="strict")
        if len(raw) > MAX_BODY or digest(raw) != self.body_sha256:
            raise ValueError("receipt body binding")
        return self


class Request(Strict):
    v: Literal[1]
    nonce: ID
    source_lock_digest: SHA
    catalogue_digest: SHA
    pin: StagePin
    prompt_name: str
    group_id: ID
    messages: Annotated[list[RenderedMessage], Field(min_length=1, max_length=100)] | None
    embed_input: str | Annotated[list[str], Field(min_length=1, max_length=1)] | None
    options: Options | None
    transcript: Annotated[list[Receipt], Field(min_length=1, max_length=3)]

    @field_validator("v", mode="before")
    @classmethod
    def exact_version(cls, value):
        if type(value) is not int:
            raise ValueError("invalid version")
        return value

    @model_validator(mode="after")
    def exact_profile(self):
        if self.pin.stage == "embedder":
            if (self.prompt_name not in {"embedder.create", "embedder.create_batch"}
                    or self.messages is not None or self.options is not None or self.embed_input is None
                    or (self.prompt_name == "embedder.create_batch" and type(self.embed_input) is not list)):
                raise ValueError("embedding profile")
            original = self.embed_input
        else:
            if (PROMPT_STAGES.get(self.prompt_name) != self.pin.stage or self.messages is None
                    or self.options is None or self.embed_input is not None
                    or self.options.max_tokens > self.pin.max_output_tokens or self.messages[0].role != "system"
                    or not any(message.role == "user" for message in self.messages)):
                raise ValueError("static LLM profile")
            if self.pin.provider == "jev" and self.options.max_tokens != self.pin.max_output_tokens:
                raise ValueError("Jev replay token profile")
            original = [message.model_dump() for message in self.messages]
        if len(canonical(original)) > MAX_MESSAGES:
            raise ValueError("original input bound")
        if len({item.attempt_id for item in self.transcript}) != len(self.transcript):
            raise ValueError("duplicate attempt")
        if len({item.receipt_id for item in self.transcript}) != len(self.transcript):
            raise ValueError("duplicate receipt")
        previous = None
        for index, item in enumerate(self.transcript, 1):
            if (item.ordinal != index or item.predecessor_attempt_id != previous
                    or item.endpoint != self.pin.endpoint):
                raise ValueError("ordered transcript binding")
            previous = item.attempt_id
        if sum(len(item.body.encode()) for item in self.transcript) > 3 * MAX_BODY:
            raise ValueError("aggregate receipt bound")
        bounded(self.model_dump())
        if len(canonical(self.model_dump())) > MAX_REQUEST:
            raise ValueError("request bound")
        return self


def _fixed_file(path: Path, cap: int) -> bytes:
    with path.open("rb") as reader:
        raw = reader.read(cap + 1)
    if not 1 <= len(raw) <= cap:
        raise BoundaryError("stage_unavailable")
    return raw


def verify_files(request: Request):
    source_bytes = _fixed_file(SOURCE_PATH, MAX_REQUEST)
    catalogue_bytes = _fixed_file(CATALOGUE_PATH, MAX_REQUEST)
    dependency_bytes = _fixed_file(DEPENDENCIES_PATH, MAX_REQUEST)
    if (digest(source_bytes) != request.source_lock_digest or digest(catalogue_bytes) != request.catalogue_digest
            or request.pin.schema_digest != request.catalogue_digest):
        raise BoundaryError("stage_unavailable")
    source = json.loads(source_bytes, object_pairs_hook=_pairs)
    catalogue = json.loads(catalogue_bytes, object_pairs_hook=_pairs)
    if (catalogue.get("format") != FORMAT or catalogue.get("source_lock_digest") != request.source_lock_digest
            or catalogue.get("dependency_lock_digest") != digest(dependency_bytes)
            or source.get("version") != "0.31.2" or importlib.metadata.version("graphiti-core") != "0.31.2"):
        raise BoundaryError("stage_unavailable")
    import graphiti_core
    source_base = Path(graphiti_core.__file__).parent
    for relative, expected in source["files"].items():
        path = PurePosixPath(relative)
        if path.is_absolute() or ".." in path.parts or digest(_fixed_file(source_base / relative, MAX_REQUEST)) != expected:
            raise BoundaryError("stage_unavailable")
    for package, expected in catalogue["versions"].items():
        actual = platform.python_version() if package == "python" else importlib.metadata.version(package)
        if actual != expected:
            raise BoundaryError("stage_unavailable")
    entries = [entry for entry in catalogue["entries"]
               if entry["stage"] == request.pin.stage and entry["prompt_name"] == request.prompt_name]
    if len(entries) != 1:
        raise BoundaryError("stage_unavailable")
    entry = entries[0]
    physical = entry["physical_profile"]
    if (not isinstance(physical, dict) or request.pin.provider not in physical["providers"]
            or not request.pin.endpoint.endswith(physical["endpoint_suffix"]) or physical["method"] != "POST"):
        raise BoundaryError("stage_unavailable")
    # Endpoint equality still binds each POST. Reject query/fragment/credentials
    # rather than allowing SDK URL normalization to select another route.
    url = httpx.URL(request.pin.endpoint)
    if url.scheme not in {"http", "https"} or url.userinfo or url.query or url.fragment:
        raise BoundaryError("stage_unavailable")
    if request.pin.stage == "embedder":
        if (entry["schema_kind"] != "embedding_descriptor" or entry["schema"] != embedding_output_descriptor()
                or entry["schema_digest"] != EMBEDDING_SCHEMA_DIGEST or physical != _embedding_profile()):
            raise BoundaryError("stage_unavailable")
        return None
    spec = BUILTIN_PROMPT_SPECS.get(request.prompt_name)
    if spec is None or spec.dynamic_schema:
        raise BoundaryError("stage_unavailable")
    model = resolve_response_model(request.prompt_name)
    schema = model.model_json_schema() if model is not None else {}
    name = model.__module__ + "." + model.__qualname__ if model is not None else None
    if (model is not spec.response_model or entry["schema"] != schema or entry["schema_digest"] != digest(canonical(schema))
            or entry["response_model"] != name or entry["schema_kind"] != ("json_schema" if model else "static_none")):
        raise BoundaryError("stage_unavailable")
    is_jev = request.pin.stage in {"node_dedupe", "edge_dedupe"}
    if is_jev:
        if request.pin.provider != "jev" or physical["id"] != "native_jev_systemone_v1":
            raise BoundaryError("stage_unavailable")
    elif (physical["id"] != "openai_chat_completions_v1" or physical["temperature"] != DEFAULT_TEMPERATURE
            or physical["response_format"] != OpenAIGenericClient._build_response_format(
                SimpleNamespace(structured_output_mode="json_schema"), model)):
        raise BoundaryError("stage_unavailable")
    return model


class TranscriptTransport(httpx.AsyncBaseTransport):
    def __init__(self, request: Request):
        self.request, self.consumed, self.failure = request, [], None

    async def handle_async_request(self, request: httpx.Request) -> httpx.Response:
        try:
            if self.failure is not None or asyncio.current_task().cancelling():
                raise BoundaryError("cancelled" if asyncio.current_task().cancelling() else self.failure)
            index = len(self.consumed)
            if index >= len(self.request.transcript):
                raise BoundaryError("closure_incomplete")
            receipt = self.request.transcript[index]
            raw = await request.aread()
            if (len(raw) > MAX_BODY or request.method != receipt.method
                    or str(request.url) != receipt.endpoint or digest(raw) != receipt.request_body_sha256):
                raise BoundaryError("reconcile_required")
            self.consumed.append({"attempt_id": receipt.attempt_id, "receipt_id": receipt.receipt_id})
            return httpx.Response(receipt.http_status, content=receipt.body.encode("utf-8"),
                headers={"content-type": "application/json"}, request=request)
        except BaseException:
            self.failure = self.failure or "closure_incomplete"
            raise


class _CompletionGate:
    """HarnessForge proof policy on SDK-parsed fields, stricter than upstream."""
    def __init__(self, create):
        self.create_native = create

    async def create(self, **kwargs):
        result = await self.create_native(**kwargs)
        if (type(result) is not ChatCompletion or type(result.choices) is not list or len(result.choices) != 1
                or type(result.choices[0]) is not Choice or type(result.choices[0].message) is not ChatCompletionMessage
                or result.choices[0].finish_reason != "stop"
                or result.choices[0].message.refusal not in (None, "")
                or (result.choices[0].message.tool_calls is not None
                    and (type(result.choices[0].message.tool_calls) is not list or result.choices[0].message.tool_calls))):
            raise BoundaryError("provider_error")
        return result


async def _native_call(request: Request, client: httpx.AsyncClient, response_model):
    pin = request.pin
    config = LLMConfig(api_key="receipt-replay-placeholder", model=pin.model,
                       max_tokens=pin.max_output_tokens)
    if pin.provider == "jev":
        native = JevClient(config, base_url=pin.endpoint, max_retries=1,
                           timeout_seconds=pin.timeout_ms / 1000, http_client=client)
        return await native.generate_response([Message(**message.model_dump()) for message in request.messages],
            response_model=response_model, max_tokens=request.options.max_tokens, model_size=ModelSize.medium,
            group_id=request.group_id, prompt_name=request.prompt_name, attribute_extraction=False, model=pin.model)
    suffix = "/embeddings" if pin.stage == "embedder" else "/chat/completions"
    sdk = AsyncOpenAI(api_key="receipt-replay-placeholder", base_url=pin.endpoint[:-len(suffix)] + "/",
                      http_client=client, max_retries=0)
    if pin.stage == "embedder":
        native = OpenAIEmbedder(OpenAIEmbedderConfig(embedding_model=pin.model, embedding_dim=1024,
                               api_key="receipt-replay-placeholder"), client=sdk)
        if request.prompt_name == "embedder.create":
            vectors = [await native.create(request.embed_input)]
        else:
            vectors = await native.create_batch(request.embed_input)
        if len(vectors) != 1:
            raise BoundaryError("closure_incomplete")
        return {"embedding_vectors": [vector_commitment(vector) for vector in vectors]}
    proxy = SimpleNamespace(chat=SimpleNamespace(completions=_CompletionGate(sdk.chat.completions.create)))
    native = OpenAIGenericClient(config, client=proxy, max_tokens=pin.max_output_tokens,
                                 structured_output_mode="json_schema")
    return await native.generate_response([Message(**message.model_dump()) for message in request.messages],
        response_model=response_model, max_tokens=request.options.max_tokens, model_size=ModelSize.medium,
        group_id=request.group_id, prompt_name=request.prompt_name, attribute_extraction=False, model=pin.model)


def _result(request: Request | None, state: str, transcript_hash: str | None, consumed: list,
            value=None, error_code=None) -> dict:
    return {"v": 1, "nonce": request.nonce if request is not None else None, "state": state,
        "transcript_sha256": transcript_hash, "consumed_receipts": consumed,
        "value": value, "value_sha256": digest(canonical(value)) if state == "ok" else None,
        "error_code": error_code}


async def prove(request: Request) -> dict:
    transcript_hash = digest(canonical([item.model_dump() for item in request.transcript]))
    transport = TranscriptTransport(request)
    try:
        response_model = verify_files(request)
        async with asyncio.timeout(MAX_REPLAY_SECONDS):
            async with httpx.AsyncClient(transport=transport, trust_env=False, follow_redirects=False,
                                         timeout=request.pin.timeout_ms / 1000) as client:
                value = await _native_call(request, client, response_model)
        if (transport.failure is not None or len(transport.consumed) != len(request.transcript)
                or asyncio.current_task().cancelling() or not isinstance(value, dict)):
            raise BoundaryError("closure_incomplete")
        bounded(value)
        result = _result(request, "ok", transcript_hash, transport.consumed, value)
        if len(canonical(result)) > MAX_RESPONSE:
            raise BoundaryError("response_limit")
        return result
    except asyncio.CancelledError:
        return _result(request, "denied", transcript_hash, transport.consumed, error_code="cancelled")
    except TimeoutError:
        return _result(request, "denied", transcript_hash, transport.consumed, error_code="deadline_exceeded")
    except Exception as error:
        return _result(request, "denied", transcript_hash, transport.consumed,
                       error_code=error.code if isinstance(error, BoundaryError) else "provider_error")


def _read_exact(reader: BinaryIO, size: int) -> bytes:
    value = bytearray()
    while len(value) < size:
        chunk = reader.read(size - len(value))
        if not chunk:
            raise BoundaryError("invalid_frame")
        value.extend(chunk)
    return bytes(value)


def read_request(reader: BinaryIO) -> Request:
    length = struct.unpack(">I", _read_exact(reader, 4))[0]
    if not 1 <= length <= MAX_REQUEST:
        raise BoundaryError("invalid_frame")
    value = json.loads(_read_exact(reader, length).decode("utf-8", errors="strict"), object_pairs_hook=_pairs,
        parse_constant=lambda _: (_ for _ in ()).throw(BoundaryError("invalid_frame")))
    bounded(value)
    return Request.model_validate(value)


def main(reader: BinaryIO | None = None, writer: BinaryIO | None = None) -> int:
    try:
        # Consume one bounded frame, leave trailing input uninterpreted; raw Port
        # cannot half-close. Root requires one reply plus stdout EOF and exit0.
        request = read_request(reader if reader is not None else sys.stdin.buffer)
        result = asyncio.run(prove(request))
    except Exception:
        result = _result(None, "denied", None, [], error_code="invalid_frame")
    raw = canonical(result)
    if not 1 <= len(raw) <= MAX_RESPONSE:
        return 1
    output = writer if writer is not None else sys.stdout.buffer
    output.write(struct.pack(">I", len(raw)) + raw)
    output.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
