"""Offline schema/descriptor mechanics; catalogue qualification stays root-owned."""
import io
import json
from types import SimpleNamespace

import pytest
from graphiti_core.prompts.lib import BUILTIN_PROMPT_SPECS, resolve_response_model
from graphiti_core.llm_client.openai_generic_client import OpenAIGenericClient

import schema_export
from fixtures.helpers import context_reply, job, pin
from lineage import operation
from observations import observed_call
from protocol import BoundaryError, canonical, digest
from schema_export import (EMBEDDING_SCHEMA_DIGEST, MAX_EXPORT_BYTES, PROMPT_STAGES,
                           build_catalogue, embedding_output_descriptor, export_catalogue)
from read_observations import BOOTSTRAP_SEAM, native_read_policy
from search_observations import SEARCH_SEAM, native_search_policy

SOURCE = "1" * 64
DEPENDENCIES = "2" * 64


def test_catalogue_is_closed_sorted_deterministic_and_binds_actual_versions_without_self_reference():
    raw = export_catalogue(SOURCE, DEPENDENCIES)
    assert raw == export_catalogue(SOURCE, DEPENDENCIES)
    value = json.loads(raw)
    assert raw == canonical(value) and len(raw) <= MAX_EXPORT_BYTES
    assert set(value) == {"format", "adapter_export_version", "source_lock_digest", "dependency_lock_digest",
                          "versions", "route_policy", "entries"}
    assert value["format"] == "graphiti-schema-catalogue-v1"
    assert value["source_lock_digest"] == SOURCE and value["dependency_lock_digest"] == DEPENDENCIES
    assert value["versions"]["graphiti-core"] == "0.31.2"
    assert value["versions"]["openai"] and value["versions"]["pydantic"]
    keys = [(entry["stage"], entry["prompt_name"]) for entry in value["entries"]]
    assert keys == sorted(set(keys)) and len(keys) == 19
    prompt_entries = [entry for entry in value["entries"] if entry["schema_kind"] in {"json_schema", "static_none"}]
    assert {entry["prompt_name"] for entry in prompt_entries} == set(PROMPT_STAGES)
    assert len(prompt_entries) == 7
    assert value["route_policy"]["catalogue_membership_releases_routes"] is False
    assert value["route_policy"]["native_reads"] == native_read_policy()
    assert value["route_policy"]["native_search"] == native_search_policy()
    assert BOOTSTRAP_SEAM not in {entry["prompt_name"] for entry in value["entries"]}
    assert SEARCH_SEAM not in {entry["prompt_name"] for entry in value["entries"]}
    for denied in ["extract_nodes.extract_message", "extract_nodes.extract_json", "extract_nodes.extract_attributes",
                   "extract_edges.extract_attributes", "extract_edges.extract_timestamps_batch",
                   "extract_nodes.extract_entity_summaries_from_episodes", "extract_nodes_and_edges.extract_message",
                   "eval.qa_prompt", "summarize_sagas.summarize_saga"]:
        assert denied not in {entry["prompt_name"] for entry in value["entries"]}


def test_static_models_and_physical_response_formats_come_from_actual_native_apis():
    value = build_catalogue(SOURCE, DEPENDENCIES)
    holder = SimpleNamespace(structured_output_mode="json_schema")
    for entry in value["entries"]:
        if entry["schema_kind"] not in {"json_schema", "static_none"}:
            continue
        spec = BUILTIN_PROMPT_SPECS[entry["prompt_name"]]
        model = resolve_response_model(entry["prompt_name"])
        assert not spec.dynamic_schema and model is spec.response_model
        assert entry["schema"] == (model.model_json_schema() if model is not None else {})
        assert entry["schema_digest"] == digest(canonical(entry["schema"]))
        assert entry["model_selector"] == "stage_pin.model"
        if entry["stage"] in {"node_dedupe", "edge_dedupe"}:
            assert entry["physical_profile"]["response_format"] is None
            assert entry["physical_profile"]["required_keys"] == ["model", "questions", "state"]
            assert entry["physical_profile"]["max_tokens"] == "absent"
        else:
            expected = OpenAIGenericClient._build_response_format(holder, model)
            assert entry["physical_profile"]["response_format"] == expected
            if model is not None:
                assert "strict" not in expected["json_schema"]
    none = next(entry for entry in value["entries"] if entry["prompt_name"] == "extract_nodes.extract_summary")
    assert none["schema_kind"] == "static_none" and none["response_model"] is None
    assert none["schema"] == {} and none["schema_digest"] == digest(canonical({}))
    assert none["physical_profile"]["response_format"] == {"type": "json_object"}


def test_export_never_initializes_sdk_model_or_database_clients(monkeypatch):
    import openai
    import httpx
    import runtime
    def unavailable(*args, **kwargs):
        raise AssertionError("Offline export must not initialize clients or call a model/backend")
    for cls in (openai.AsyncOpenAI, httpx.AsyncClient, runtime.MeteredGeneric, runtime.MeteredJev,
                runtime.Neo4jDriver, runtime.Graphiti):
        monkeypatch.setattr(cls, "__init__", unavailable)
    assert build_catalogue(SOURCE, DEPENDENCIES)["format"] == "graphiti-schema-catalogue-v1"


def test_actual_resolver_or_route_drift_denies_instead_of_exporting_a_fallback(monkeypatch):
    import graphiti_core.prompts.lib as library
    registry = dict(library.BUILTIN_PROMPT_SPECS)
    registry.pop("extract_nodes.extract_text")
    monkeypatch.setattr(library, "BUILTIN_PROMPT_SPECS", registry)
    with pytest.raises(BoundaryError, match="stage_unavailable"):
        build_catalogue(SOURCE, DEPENDENCIES)


def test_seams_are_exact_descriptors_with_current_hook_stages_and_no_physical_request():
    entries = build_catalogue(SOURCE, DEPENDENCIES)["entries"]
    for entry in entries:
        if entry["schema_kind"] != "seam_descriptor":
            continue
        assert entry["schema"] == {"seam": entry["prompt_name"], "v": 1}
        assert entry["schema_digest"] == digest(canonical(entry["schema"]))
        assert entry["physical_profile"] is None and entry["response_model"] is None
        assert entry["stage"] in schema_export.SEAM_STAGES[entry["prompt_name"]]
        assert entry["allowed_seams"] == [entry["prompt_name"]]
        assert entry["transforms"] == [schema_export.SEAM_TRANSFORMS[entry["prompt_name"]]]


def test_embedding_descriptor_hash_has_no_pin_catalogue_self_reference_and_sdk_profile_is_concrete():
    descriptor = embedding_output_descriptor()
    assert descriptor["dimensions"] == 1024 and descriptor["vector_format"] == "ieee754-be-f64-v1"
    assert EMBEDDING_SCHEMA_DIGEST == digest(canonical(descriptor))
    descriptor["dimensions"] = 1
    assert embedding_output_descriptor()["dimensions"] == 1024
    first, other = build_catalogue(SOURCE, DEPENDENCIES), build_catalogue("3" * 64, "4" * 64)
    for value in (first, other):
        entries = [entry for entry in value["entries"] if entry["schema_kind"] == "embedding_descriptor"]
        assert len(entries) == 2
        for entry in entries:
            assert entry["schema_digest"] == EMBEDDING_SCHEMA_DIGEST
            assert entry["schema"] == embedding_output_descriptor()
            profile = entry["physical_profile"]
            assert profile["required_keys"] == ["encoding_format", "input", "model"]
            assert profile["encoding_format"] == "base64"
            assert profile["dimensions"] == "absent" and profile["user"] == "absent"


def test_native_save_completion_policy_is_closed_and_binds_only_known_return_positions():
    value = build_catalogue(SOURCE, DEPENDENCIES)
    policy = value["route_policy"]["save_completion"]
    assert policy == schema_export.native_save_completion_policy()
    assert policy["format"] == "native-save-completion-policy-v1" and policy["v"] == 1
    assert policy["descriptor_format"] == "native-save-completion-v1"
    assert policy["descriptor_fields"] == ["format", "method", "return_kind", "returned_uuid"]
    assert policy["projection_id"] == "identity_v1"
    assert policy["value_position"] == "deterministic_output.result"
    assert policy["driver"] == "graphiti_core.driver.neo4j_driver.Neo4jDriver"
    assert policy["legacy_graph_operations_interface"] == "absent"
    assert policy["result_type"] == "neo4j.EagerResult" and policy["record_type"] == "neo4j.Record"
    assert policy["result_keys"] == policy["record_keys"] == ["uuid"] and policy["record_count"] == 1
    assert policy["claim"] == "observed-native-return-only"
    assert policy["persistence_authority"] == "independent-root-inventory-and-ack"
    assert policy["variants"] == [
        {"method": kind + ".save", "return_kind": "neo4j-eager-uuid",
         "object_type": kind, "returned_uuid": "saved_object.uuid"}
        for kind in ("EntityNode", "EpisodicNode", "EntityEdge", "EpisodicEdge")
    ] + [{"method": "add_nodes_and_edges_bulk", "return_kind": "none", "object_type": None, "returned_uuid": None}]
    policy["variants"].clear()
    assert len(schema_export.native_save_completion_policy()["variants"]) == 5


async def test_embedding_observations_use_the_concrete_descriptor_and_reject_arbitrary_schema_hashes():
    pages = []
    async def observe(page):
        pages.append(page)
        return await context_reply(page)
    stage = pin("embedder", "http://127.0.0.1:11434/v1/embeddings")
    assert stage.schema_digest != EMBEDDING_SCHEMA_DIGEST
    with operation(job()):
        async with observed_call(stage, "embedder.create", ["Synthetic"], observe, embed=True):
            pass
        assert pages[0].schema_digest == EMBEDDING_SCHEMA_DIGEST
        with pytest.raises(BoundaryError, match="scope_denied"):
            async with observed_call(stage, "embedder.create", ["Synthetic"], observe,
                                     embed=True, schema_digest=stage.schema_digest):
                pass
    assert len(pages) == 1


def test_cli_emits_only_complete_canonical_bounded_json_or_no_bytes(monkeypatch):
    output = io.BytesIO()
    args = ["--source-lock-digest", SOURCE, "--dependency-lock-digest", DEPENDENCIES]
    assert schema_export.main(args, output) == 0
    raw = output.getvalue()
    assert raw == canonical(json.loads(raw)) and raw[-1:] == b"}"
    for invalid in [[], args + ["--file", "/arbitrary"], ["--source-lock-digest", SOURCE] * 2,
                    ["--source-lock-digest", "invalid", "--dependency-lock-digest", DEPENDENCIES]]:
        target = io.BytesIO()
        assert schema_export.main(invalid, target) == 1 and target.getvalue() == b""
    monkeypatch.setattr(schema_export, "MAX_EXPORT_BYTES", 32)
    target = io.BytesIO()
    assert schema_export.main(args, target) == 1 and target.getvalue() == b""
