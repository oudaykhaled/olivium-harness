"""Offline, closed schema export. Root alone qualifies and installs its bytes.

Digest arguments come from root's verified immutable files. This module reads no
lock/config/input paths, constructs no SDK clients and performs no model/DB I/O.
Only main writes canonical JSON to stdout; failure writes nothing and exits1.
"""
from __future__ import annotations

import importlib.metadata
import json
import logging
import os
import platform
import re
import sys
from pathlib import Path
from types import MappingProxyType, SimpleNamespace
from typing import BinaryIO

os.environ["GRAPHITI_TELEMETRY_ENABLED"] = "false"
os.environ["PYTHON_DOTENV_DISABLED"] = "1"
if __name__ == "__main__":
    for _key in tuple(os.environ):
        if (_key.endswith(("_API_KEY", "_TOKEN")) or _key.lower().endswith("_proxy")
                or _key.startswith(("OTEL_", "HARNESSFORGE_"))):
            os.environ.pop(_key, None)
    sys.path.insert(0, str(Path(__file__).resolve().parent))
logging.disable(logging.CRITICAL)

from protocol import BoundaryError, canonical, digest
from read_observations import native_read_policy
from search_observations import native_search_policy

FORMAT = "graphiti-schema-catalogue-v1"
ADAPTER_EXPORT_VERSION = 1
MAX_EXPORT_BYTES = 524288
_EMBEDDING_BYTES = canonical({
    "format": "graphiti-embedding-output-descriptor-v1", "v": 1,
    "result_key": "embedding_vectors", "vectors_per_call": 1, "dimensions": 1024,
    "vector_fields": ["format", "length", "sha256"], "vector_format": "ieee754-be-f64-v1",
    "hash_algorithm": "sha256", "number_encoding": "big-endian-ieee754-binary64",
    "finite_values_only": True, "native_slice": {"start": 0, "stop": 1024},
    "sdk_base64_number_encoding": "native-float32-to-python-float",
})
EMBEDDING_SCHEMA_DIGEST = digest(_EMBEDDING_BYTES)
_SAVE_COMPLETION_BYTES = canonical({
    "format": "native-save-completion-policy-v1", "v": 1,
    "descriptor_format": "native-save-completion-v1",
    "descriptor_fields": ["format", "method", "return_kind", "returned_uuid"],
    "projection_id": "identity_v1", "value_position": "deterministic_output.result",
    "variants": [
        {"method": name + ".save", "return_kind": "neo4j-eager-uuid",
         "object_type": name, "returned_uuid": "saved_object.uuid"}
        for name in ("EntityNode", "EpisodicNode", "EntityEdge", "EpisodicEdge")
    ] + [{"method": "add_nodes_and_edges_bulk", "return_kind": "none",
          "object_type": None, "returned_uuid": None}],
    "driver": "graphiti_core.driver.neo4j_driver.Neo4jDriver",
    "provider": "neo4j", "legacy_graph_operations_interface": "absent",
    "result_type": "neo4j.EagerResult", "record_type": "neo4j.Record",
    "result_keys": ["uuid"], "record_keys": ["uuid"], "record_count": 1,
    "claim": "observed-native-return-only",
    "persistence_authority": "independent-root-inventory-and-ack",
    "structured_domain_returns": "unchanged-native-projection",
})

# No registry discovery expands this allowlist. Catalogue membership is not a
# route release; root independently releases and validates each operation.
PROMPT_STAGES = MappingProxyType({
    "extract_nodes.extract_text": "extraction",
    "extract_edges.edge": "extraction",
    "extract_edges.extract_timestamps": "extraction",
    "dedupe_nodes.nodes": "node_dedupe",
    "dedupe_edges.resolve_edge": "edge_dedupe",
    "extract_nodes.extract_summaries_batch": "summary",
    "extract_nodes.extract_summary": "summary",
})
SEAM_STAGES = MappingProxyType({
    "graphiti.extract_nodes.v1": ("extraction",),
    "graphiti.resolve_nodes.v1": ("node_dedupe",),
    "graphiti.extract_edges.v1": ("extraction", "edge_dedupe"),
    "graphiti.attributes.v1": ("extraction",),
    "graphiti.summary_flight.v1": ("summary",),
    "graphiti.summary_batch.v1": ("summary",),
    "graphiti.temporal.v1": ("extraction", "edge_dedupe"),
    "graphiti.save.v1": ("extraction",),
})
SEAM_TRANSFORMS = MappingProxyType({
    "graphiti.extract_nodes.v1": "graphiti_extract_nodes_v1",
    "graphiti.resolve_nodes.v1": "graphiti_resolve_nodes_v1",
    "graphiti.extract_edges.v1": "graphiti_extract_edges_v1",
    "graphiti.attributes.v1": "graphiti_attribute_overlay_v1",
    "graphiti.summary_flight.v1": "graphiti_summary_flight_v1",
    "graphiti.summary_batch.v1": "graphiti_fact_append_v1",
    "graphiti.temporal.v1": "graphiti_temporal_v1",
    "graphiti.save.v1": "graphiti_save_v1",
})


def embedding_output_descriptor() -> dict:
    """A fresh concrete descriptor; it contains neither catalogue nor pin hash."""
    return json.loads(_EMBEDDING_BYTES)


def native_save_completion_policy() -> dict:
    """Closed return-position policy; a completion descriptor grants no write proof."""
    return json.loads(_SAVE_COMPLETION_BYTES)


def _qualified(value: type) -> str:
    return value.__module__ + "." + value.__qualname__


def _check_json(value: object, depth: int = 0) -> None:
    if depth > 32 or isinstance(value, float):
        raise BoundaryError("invalid_dto")
    if isinstance(value, dict):
        if len(value) > 100 or any(not isinstance(key, str) for key in value):
            raise BoundaryError("response_limit")
        for item in value.values():
            _check_json(item, depth + 1)
    elif isinstance(value, list):
        if len(value) > 100:
            raise BoundaryError("response_limit")
        for item in value:
            _check_json(item, depth + 1)
    elif value is not None and type(value) not in (str, int, bool):
        raise BoundaryError("invalid_dto")


def _actual_routes():
    # No constructors, SDKs, prompt generation or model calls. Use the real
    # adapter composition and upstream model selector with inert client shells.
    from runtime import MeteredGeneric, MeteredJev, compose_runtime
    clients = []
    for stage in ("extraction", "summary", "node_dedupe", "edge_dedupe"):
        client = object.__new__(MeteredJev if stage.endswith("dedupe") else MeteredGeneric)
        client.pin = SimpleNamespace(stage=stage, model="schema-export:" + stage, max_output_tokens=4096)
        clients.append(client)
    return compose_runtime(*clients)


def _embedding_profile() -> dict:
    from openai._types import omit
    from openai._utils import is_given
    from openai.lib._parsing._embeddings import prepare_embedding_request
    prepared = prepare_embedding_request(None, {"model": "stage_pin.model", "input": "measured_input",
        "dimensions": omit, "encoding_format": omit, "user": omit}, encoding_format=omit)
    body = {key: value for key, value in prepared.body.items() if is_given(value)}
    if body != {"model": "stage_pin.model", "input": "measured_input", "encoding_format": "base64"}:
        raise BoundaryError("stage_unavailable")
    return {"id": "openai_embeddings_sdk_v1", "method": "POST", "endpoint_suffix": "/embeddings",
        "providers": ["ollama", "openai"], "required_keys": sorted(body), "optional_keys": [],
        "encoding_format": body["encoding_format"], "dimensions": "absent", "user": "absent",
        "model_selector": "stage_pin.model", "input_selector": "measured_input",
        "native_return_dimensions": 1024}


def _entry(stage: str, prompt: str, kind: str, schema: dict, response_model: type | None,
           client: str | None, seams: list[str], transforms: list[str], physical: dict | None) -> dict:
    _check_json(schema)
    return {"stage": stage, "prompt_name": prompt, "schema_kind": kind, "schema": schema,
        "schema_digest": digest(canonical(schema)),
        "response_model": _qualified(response_model) if response_model is not None else None,
        "model_selector": "stage_pin.model", "client": client,
        "allowed_seams": seams, "transforms": transforms, "physical_profile": physical}


def build_catalogue(source_lock_digest: str, dependency_lock_digest: str) -> dict:
    for value in (source_lock_digest, dependency_lock_digest):
        if not isinstance(value, str) or re.fullmatch(r"[a-f0-9]{64}", value) is None:
            raise BoundaryError("invalid_dto")
    from graphiti_core.prompts.lib import BUILTIN_PROMPT_SPECS, resolve_response_model
    from graphiti_core.llm_client.openai_generic_client import OpenAIGenericClient
    from graphiti_core.llm_client.config import DEFAULT_TEMPERATURE
    routes = _actual_routes()
    entries = []
    for prompt, stage in sorted(PROMPT_STAGES.items()):
        spec = BUILTIN_PROMPT_SPECS.get(prompt)
        if spec is None or spec.name != prompt or spec.dynamic_schema:
            raise BoundaryError("stage_unavailable")
        model = resolve_response_model(prompt)
        if model is not spec.response_model:
            raise BoundaryError("stage_unavailable")
        routed = routes.resolve_model(prompt)
        if routed.transport.client.pin.stage != stage or routed.id != "schema-export:" + stage:
            raise BoundaryError("stage_unavailable")
        schema = model.model_json_schema() if model is not None else {}
        is_jev = stage in {"node_dedupe", "edge_dedupe"}
        if is_jev:
            physical = {"id": "native_jev_systemone_v1", "method": "POST",
                "endpoint_suffix": "/v1/systemone", "providers": ["jev"],
                "required_keys": ["model", "questions", "state"], "optional_keys": [],
                "model_selector": "stage_pin.model", "response_format": None,
                "max_tokens": "absent", "temperature": "absent", "stream": "absent"}
            transforms = ["graphiti_builder_v1", "native_jev_fit_v1", "model_response_v1"]
        else:
            # Invoke the pinned builder unchanged; no SDK/client initialization.
            response_format = OpenAIGenericClient._build_response_format(
                SimpleNamespace(structured_output_mode="json_schema"), model)
            physical = {"id": "openai_chat_completions_v1", "method": "POST",
                "endpoint_suffix": "/chat/completions", "providers": ["ollama", "openai"],
                "required_keys": ["max_tokens", "messages", "model", "response_format", "temperature"],
                "optional_keys": [], "model_selector": "stage_pin.model", "temperature": DEFAULT_TEMPERATURE,
                "max_tokens": {"minimum": 1, "maximum_selector": "stage_pin.max_output_tokens"},
                "stream": "absent", "response_format": response_format}
            transforms = ["graphiti_builder_v1", "official_openai_chat_v1", "model_response_v1"]
        entries.append(_entry(stage, prompt, "json_schema" if model is not None else "static_none", schema,
            model, _qualified(type(routed.transport.client)),
            ["llm.context.v1", "llm.messages.v1", "http.serialized.v1", "llm.response.v1"], transforms, physical))
    for seam, stages in sorted(SEAM_STAGES.items()):
        for stage in stages:
            entries.append(_entry(stage, seam, "seam_descriptor", {"seam": seam, "v": 1}, None,
                None, [seam], [SEAM_TRANSFORMS[seam]], None))
    physical = _embedding_profile()
    for prompt in ("embedder.create", "embedder.create_batch"):
        entries.append(_entry("embedder", prompt, "embedding_descriptor", embedding_output_descriptor(),
            None, "runtime.MeteredEmbedder", ["embedder.input.v1", "http.serialized.v1", "llm.response.v1"],
            ["identity_v1", "official_openai_embed_v1", "model_response_v1"], physical))
    entries.sort(key=lambda item: (item["stage"], item["prompt_name"]))
    if len({(entry["stage"], entry["prompt_name"]) for entry in entries}) != len(entries):
        raise BoundaryError("invalid_dto")
    versions = {name: importlib.metadata.version(name)
        for name in ("graphiti-core", "pydantic", "pydantic_core", "openai", "httpx", "httpx2", "numpy", "neo4j")}
    versions["python"] = platform.python_version()
    if versions["graphiti-core"] != "0.31.2":
        raise BoundaryError("stage_unavailable")
    value = {"format": FORMAT, "adapter_export_version": ADAPTER_EXPORT_VERSION,
        "source_lock_digest": source_lock_digest, "dependency_lock_digest": dependency_lock_digest,
        "versions": versions, "route_policy": {"id": "empty_custom_attributes_only_v1",
            "candidate_only": True, "dynamic_schemas": "denied", "unknown_prompts": "denied",
            "catalogue_membership_releases_routes": False,
            "save_completion": native_save_completion_policy(),
            "native_reads": native_read_policy(),
            "native_search": native_search_policy(),
            "prompt_allowlist": [{"stage": stage, "prompt_name": prompt}
                for prompt, stage in sorted(PROMPT_STAGES.items(), key=lambda item: (item[1], item[0]))]},
        "entries": entries}
    _check_json(value)
    if len(canonical(value)) > MAX_EXPORT_BYTES:
        raise BoundaryError("response_limit")
    return value


def export_catalogue(source_lock_digest: str, dependency_lock_digest: str) -> bytes:
    return canonical(build_catalogue(source_lock_digest, dependency_lock_digest))


def main(argv: list[str] | None = None, writer: BinaryIO | None = None) -> int:
    try:
        args = sys.argv[1:] if argv is None else argv
        if len(args) != 4:
            return 1
        options = dict(zip(args[::2], args[1::2]))
        if set(options) != {"--source-lock-digest", "--dependency-lock-digest"}:
            return 1
        raw = export_catalogue(options["--source-lock-digest"], options["--dependency-lock-digest"])
        output = writer if writer is not None else sys.stdout.buffer
        output.write(raw)
        output.flush()
        return 0
    except Exception:
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
