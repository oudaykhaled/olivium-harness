"""Actual upstream/Neo4j mechanics, with explicitly scripted model replies.

Root supplies an isolated backend-only Boot JSON file. No provider HTTP is made.
Absence is a visible SKIP/unavailable cell, never backend/model qualification.
"""
import json
import os
from pathlib import Path
from uuid import uuid4

import pytest

from fixtures.helpers import context_reply, job, pin, reply
from lineage import operation
from protocol import Boot, BoundaryError, digest, stage_set_digest
from runtime import Runtime


def scripted_response(attempt):
    body = json.loads(attempt.body)
    if attempt.prompt_name.startswith("embedder."):
        inputs = body["input"]
        if isinstance(inputs, str):
            inputs = [inputs]
        return {"object": "list", "data": [
            {"object": "embedding", "index": i, "embedding": [1.0] + [0.0] * 1023}
            for i, _ in enumerate(inputs)], "model": body["model"],
            "usage": {"prompt_tokens": 1, "total_tokens": 1}}
    if attempt.prompt_name == "dedupe_nodes.nodes":
        answers = {}
        for key, question in body["questions"].items():
            match = next((candidate for candidate, label in question.get("criteria", {}).items()
                          if candidate != "none" and any(name in label and name in question["instructions"]
                                                         for name in ["Synthetic Reviewer", "Synthetic Release"])), "none")
            answers[key] = {"choice": match}
        return {"answers": answers, "usage": {"input_tokens": 1, "output_tokens": 1}}
    if attempt.prompt_name == "dedupe_edges.resolve_edge":
        return {"answers": {key: {"noul": 1.0 if key.startswith("dup") else 0.0}
                            for key in body["questions"]}, "usage": {"input_tokens": 1, "output_tokens": 1}}
    if attempt.prompt_name.startswith("extract_nodes.extract_") and "summar" not in attempt.prompt_name:
        content = {"extracted_entities": [
            {"name": "Synthetic Reviewer", "entity_type_id": 0, "episode_indices": [0]},
            {"name": "Synthetic Release", "entity_type_id": 0, "episode_indices": [0]}]}
    elif "summar" in attempt.prompt_name:
        content = {"summaries": [{"name": name, "summary": "Synthetic reviewer checks a synthetic release."}
                                 for name in ["Synthetic Reviewer", "Synthetic Release"]]}
    elif "timestamps_batch" in attempt.prompt_name:
        content = {"timestamps": [{"valid_at": "2026-01-01T00:00:00Z", "invalid_at": None}]}
    elif "timestamp" in attempt.prompt_name:
        content = {"valid_at": "2026-01-01T00:00:00Z", "invalid_at": None}
    elif attempt.prompt_name == "extract_edges.edge":
        content = {"edges": [{"source_entity_name": "Synthetic Reviewer", "target_entity_name": "Synthetic Release",
            "relation_type": "REVIEWS", "fact": "Synthetic Reviewer reviews Synthetic Release.",
            "valid_at": "2026-01-01T00:00:00Z", "invalid_at": None, "episode_indices": [0]}]}
    else:
        raise AssertionError(f"Unscripted upstream prompt: {attempt.prompt_name}")
    return {"id": "synthetic-completion", "object": "chat.completion", "created": 1, "model": body["model"],
            "choices": [{"index": 0, "message": {"role": "assistant", "content": json.dumps(content)}, "finish_reason": "stop"}],
            "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}}


@pytest.mark.backend
async def test_actual_ingest_temporal_hybrid_restart_shared_source_removal_and_failed_rebuild():
    path = os.environ.get("HARNESSFORGE_GRAPHITI_BACKEND_BOOT")
    if not path:
        pytest.skip("UNAVAILABLE: root has not supplied an isolated real Neo4j Boot file")
    boot_data = json.loads(Path(path).read_text())
    boot_data["source_lock_digest"] = digest(Path(__file__).parents[1].joinpath("source.lock.json").read_bytes())
    boot_data["stage_pins"] = [
        pin("extraction", "http://127.0.0.1:11434/v1/chat/completions").model_dump(),
        pin("summary", "http://127.0.0.1:11434/v1/chat/completions").model_dump(),
        pin().model_dump(), pin("edge_dedupe").model_dump(),
        pin("embedder", "http://127.0.0.1:11434/v1/embeddings").model_dump(),
    ]
    boot_data["stage_set_digest"] = stage_set_digest(boot_data["stage_pins"])
    boot = Boot.model_validate(boot_data)
    observed = []
    fail_summary = False
    async def relay(attempt):
        observed.append(attempt)
        if fail_summary and "summar" in attempt.prompt_name:
            raise BoundaryError("stage_unavailable")
        return reply(attempt, scripted_response(attempt))
    runtime = Runtime(boot, relay, context_reply, session_id="session:synthetic")
    group = "qualification_" + uuid4().hex
    body = "Synthetic Reviewer reviews Synthetic Release."
    episodes = []
    try:
        for index in range(2):
            episode = str(uuid4())
            episodes.append(episode)
            ingest = job("ingest", scope_ref=group, stage_set_digest=boot.stage_set_digest, args={
                "binding_id": f"binding:{index}", "episode_uuid": episode, "revision_id": f"revision:{index}",
                "body_hash": digest(body.encode()), "window_start": 0, "window_end": len(body.encode()),
                "body": body, "reference_time": "2026-01-01T00:00:00Z", "time_basis": "event",
                "prior_episode_ids": []})
            with operation(ingest):
                result = await runtime.execute(ingest)
            assert result["episode_uuid"] == episode
        search = job(scope_ref=group, stage_set_digest=boot.stage_set_digest)
        with operation(search):
            result = await runtime.execute(search)
        assert result["candidates"]
        assert any(set(episodes).issubset(c["episode_ids"]) for c in result["candidates"])
        assert runtime.graph is not None
        with operation(search):
            persisted = await runtime.graph.search("Synthetic Reviewer", group_ids=[group])
        assert any(edge.valid_at is not None for edge in persisted)
        await runtime.close()
        runtime = Runtime(boot, relay, context_reply, session_id="session:synthetic")
        with operation(search):
            after_restart = await runtime.execute(search)
        assert after_restart["candidates"]
        fail_summary = True
        removal = job("remove", scope_ref=group, stage_set_digest=boot.stage_set_digest, args={
            "episode_uuid": episodes[0], "purge_fence_id": "purge:synthetic", "rebuild_closure_ref": "manifest:fixture"})
        with operation(removal):
            cleanup = await runtime.execute(removal)
        assert cleanup["cleanup_status"] == "verification_required"
        fail_summary = False
        with operation(search):
            surviving = await runtime.execute(search)
        assert surviving["candidates"]
        assert all(episodes[0] not in c["episode_ids"] for c in surviving["candidates"])
        assert any(episodes[1] in c["episode_ids"] for c in surviving["candidates"])
        assert any("summar" in attempt.prompt_name for attempt in observed)
    finally:
        # Root owns destructive datastore cleanup; unique groups avoid overlap.
        await runtime.close()
