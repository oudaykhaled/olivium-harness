"""Actual native clients with public scripted transcripts; no settled-authority claim.

CaptureTransport is a no-network fixture recorder, not a provider or Root receipt.
Production prove() accepts only a closed transcript and fixed immutable files.
"""
import asyncio
import base64
import copy
import io
import json
import struct

import httpx
import pytest
from openai.types.chat import ChatCompletion
from graphiti_core.prompts.lib import resolve_response_model

import response_proof as proof
from fixtures.helpers import pin
from observations import vector_commitment
from protocol import BoundaryError, StagePin, canonical, digest


def _pin(stage):
    endpoint = ("https://api.typesafe.ai/v1/systemone" if "dedupe" in stage else
                "http://127.0.0.1:11434/v1/" + ("embeddings" if stage == "embedder" else "chat/completions"))
    value = pin(stage, endpoint).model_dump()
    value["schema_digest"] = digest(proof.CATALOGUE_PATH.read_bytes())
    value["config_digest"] = digest(canonical({key: item for key, item in value.items() if key != "config_digest"}))
    return StagePin.model_validate(value)


def _request(stage="extraction", prompt="extract_nodes.extract_text", messages=None, embed_input=None):
    selected = _pin(stage)
    return proof.Request(v=1, nonce="nonce:public-replay", source_lock_digest=digest(proof.SOURCE_PATH.read_bytes()),
        catalogue_digest=digest(proof.CATALOGUE_PATH.read_bytes()), pin=selected, prompt_name=prompt,
        group_id="synthetic_group", messages=None if stage == "embedder" else messages or [
            {"role": "system", "content": "Public synthetic system"},
            {"role": "user", "content": "Private original marker not echoed"}],
        embed_input=embed_input if stage == "embedder" else None,
        options=None if stage == "embedder" else {"max_tokens": selected.max_output_tokens,
            "model_size": "medium", "attribute_extraction": False},
        transcript=[{"attempt_id": "attempt:1", "receipt_id": "receipt:1", "ordinal": 1,
            "predecessor_attempt_id": None, "method": "POST", "endpoint": selected.endpoint,
            "request_body_sha256": "0" * 64, "http_status": 200, "body": "{}", "body_sha256": digest(b"{}")}])


def _chat(value=None, *, content=None, finish="stop", refusal=None):
    if content is None:
        content = json.dumps(value if value is not None else {"extracted_entities": []})
    return {"id": "chat-raw-receipt-marker", "object": "chat.completion", "created": 0,
        "model": "synthetic-fixture-v1", "choices": [{"index": 0, "finish_reason": finish,
            "message": {"role": "assistant", "content": content, "refusal": refusal}}],
        "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}}


class CaptureTransport(httpx.AsyncBaseTransport):
    def __init__(self, respond):
        self.respond, self.items, self.raw_requests = respond, [], []

    async def handle_async_request(self, request):
        raw = await request.aread()
        self.raw_requests.append(raw)
        status, value = self.respond(json.loads(raw), len(self.items))
        body = value if isinstance(value, str) else canonical(value).decode()
        ordinal = len(self.items) + 1
        self.items.append({"attempt_id": f"attempt:{ordinal}", "receipt_id": f"receipt:{ordinal}",
            "ordinal": ordinal, "predecessor_attempt_id": f"attempt:{ordinal - 1}" if ordinal > 1 else None,
            "method": request.method, "endpoint": str(request.url), "request_body_sha256": digest(raw),
            "http_status": status, "body": body, "body_sha256": digest(body.encode())})
        return httpx.Response(status, content=body.encode(), headers={"content-type": "application/json"}, request=request)


async def _capture(request, respond):
    transport = CaptureTransport(respond)
    model = None if request.pin.stage == "embedder" else resolve_response_model(request.prompt_name)
    async with httpx.AsyncClient(transport=transport, trust_env=False, follow_redirects=False) as client:
        value = await proof._native_call(request, client, model)
    return proof.Request.model_validate({**request.model_dump(), "transcript": transport.items}), value, transport


async def test_native_generic_code_fences_exact_value_and_closed_output_without_inputs_or_receipts():
    expected = {"extracted_entities": [{"name": "Synthetic", "entity_type_id": 0, "episode_indices": [0]}]}
    request, captured, _ = await _capture(_request(), lambda body, index:
        (200, _chat(content="```json\n" + json.dumps(expected) + "\n```")))
    result = await proof.prove(request)
    assert captured == expected and result["state"] == "ok" and result["value"] == expected
    assert result["nonce"] == request.nonce and result["value_sha256"] == digest(canonical(expected))
    assert result["transcript_sha256"] == digest(canonical([item.model_dump() for item in request.transcript]))
    assert result["consumed_receipts"] == [{"attempt_id": "attempt:1", "receipt_id": "receipt:1"}]
    assert set(result) == {"v", "nonce", "state", "transcript_sha256", "consumed_receipts", "value", "value_sha256", "error_code"}
    assert b"Private original marker" not in canonical(result) and b"chat-raw-receipt-marker" not in canonical(result)


async def test_native_generic_retry_consumes_two_identical_requests_with_distinct_settled_identities():
    # The pinned native tenacity backoff is deliberately unchanged (>=5s).
    request, expected, transport = await _capture(_request(), lambda body, index:
        (200, _chat(content="malformed public JSON")) if index == 0 else (200, _chat()))
    assert len(transport.items) == 2 and transport.raw_requests[0] == transport.raw_requests[1]
    result = await proof.prove(request)
    assert result["state"] == "ok" and result["value"] == expected and len(result["consumed_receipts"]) == 2


def _jev_request(stage="node_dedupe"):
    if stage == "node_dedupe":
        payload = {"state": '<ENTITIES>[{"id":0,"name":"Synthetic"}]</ENTITIES>', "questions": {
            "e0": {"type": "choice", "instructions": "Synthetic A", "criteria": {"none": "none"}},
            "e1": {"type": "choice", "instructions": "Synthetic B", "criteria": {"none": "none"}}}}
        prompt = "dedupe_nodes.nodes"
    else:
        payload = {"state": "Synthetic edge state", "questions": {
            "dup0": {"type": "noul", "instructions": "Synthetic duplicate"},
            "con1": {"type": "noul", "instructions": "Synthetic contradiction"}}}
        prompt = "dedupe_edges.resolve_edge"
    return _request(stage, prompt, messages=[{"role": "system", "content": "Public synthetic system"},
                                            {"role": "user", "content": json.dumps(payload)}])


async def test_native_jev_split_and_assembly_replay_all_three_actual_posts_in_order():
    def respond(body, index):
        if len(body["questions"]) > 1:
            return 400, "max_tokens_exceeded"
        return 200, {"answers": {key: {"choice": "none"} for key in body["questions"]},
                     "usage": {"input_tokens": 2, "output_tokens": 1}}
    request, expected, transport = await _capture(_jev_request(), respond)
    assert len(transport.items) == 3 and transport.raw_requests[0] != transport.raw_requests[1]
    assert expected == {"entity_resolutions": [{"id": 0, "name": "Synthetic", "duplicate_candidate_id": -1}]}
    result = await proof.prove(request)
    assert result["state"] == "ok" and result["value"] == expected and len(result["consumed_receipts"]) == 3
    missing = proof.Request.model_validate({**request.model_dump(), "transcript": [request.transcript[0].model_dump()]})
    assert (await proof.prove(missing))["state"] == "denied"


async def test_native_jev_edge_thresholds_use_actual_assembler_without_float_logical_output():
    request, expected, _ = await _capture(_jev_request("edge_dedupe"), lambda body, index:
        (200, {"answers": {"dup0": {"noul": 0.71}, "con1": {"noul": 0.79}}}))
    result = await proof.prove(request)
    assert expected == {"duplicate_facts": [0], "contradicted_facts": []}
    assert result["state"] == "ok" and result["value"] == expected


@pytest.mark.parametrize("prompt,input_value", [("embedder.create", "Synthetic"),
    ("embedder.create", ["Synthetic"]), ("embedder.create_batch", ["Synthetic"])])
async def test_sdk_base64_native_slice_and_binary64_commitment_are_preserved(prompt, input_value):
    vector = [0.0, -0.0, 0.25] + [0.0] * 1022  # native must slice from1025 to1024
    encoded = base64.b64encode(struct.pack("<" + "f" * len(vector), *vector)).decode()
    def respond(body, index):
        assert body == {"model": "synthetic-fixture-v1", "input": input_value, "encoding_format": "base64"}
        return 200, {"object": "list", "model": "synthetic-fixture-v1", "data": [
            {"object": "embedding", "index": 0, "embedding": encoded}],
            "usage": {"prompt_tokens": 1, "total_tokens": 1}}
    request, expected, _ = await _capture(_request("embedder", prompt, embed_input=input_value), respond)
    result = await proof.prove(request)
    assert result["state"] == "ok" and result["value"] == expected == {
        "embedding_vectors": [vector_commitment(vector[:1024])]}


async def test_extra_receipt_or_exact_raw_request_hash_mismatch_cannot_produce_proof():
    request, _, _ = await _capture(_request(), lambda body, index: (200, _chat()))
    data = request.model_dump()
    extra = {**data["transcript"][0], "attempt_id": "attempt:2", "receipt_id": "receipt:2",
             "ordinal": 2, "predecessor_attempt_id": "attempt:1"}
    extended = proof.Request.model_validate({**data, "transcript": [data["transcript"][0], extra]})
    assert (await proof.prove(extended))["state"] == "denied"
    data["transcript"][0]["request_body_sha256"] = "0" * 64
    result = await proof.prove(proof.Request.model_validate(data))
    assert result["state"] == "denied" and result["value"] is result["value_sha256"] is None
    assert result["consumed_receipts"] == []


async def test_duplicate_reordered_changed_receipts_and_zero_receipt_inputs_are_rejected():
    def respond(body, index):
        return (400, "max_tokens_exceeded") if index == 0 else (200, {"answers": {}})
    request, _, _ = await _capture(_jev_request(), respond)
    original = request.model_dump()
    for mutation in ("duplicate_attempt", "duplicate_receipt", "reordered", "body", "hash", "predecessor", "endpoint", "zero"):
        data = copy.deepcopy(original)
        if mutation == "duplicate_attempt":
            data["transcript"][1]["attempt_id"] = data["transcript"][0]["attempt_id"]
        elif mutation == "duplicate_receipt":
            data["transcript"][1]["receipt_id"] = data["transcript"][0]["receipt_id"]
        elif mutation == "reordered":
            data["transcript"].reverse()
        elif mutation == "body":
            data["transcript"][0]["body"] += "changed"
        elif mutation == "hash":
            data["transcript"][0]["body_sha256"] = "0" * 64
        elif mutation == "predecessor":
            data["transcript"][1]["predecessor_attempt_id"] = "foreign:attempt"
        elif mutation == "endpoint":
            data["transcript"][0]["endpoint"] = "https://foreign.invalid/v1/systemone"
        else:
            data["transcript"] = []
        with pytest.raises((ValueError, BoundaryError)):
            proof.Request.model_validate(data)


@pytest.mark.parametrize("finish,refusal", [("length", None), ("tool_calls", None), ("unknown", None),
    ("content_filter", None), ("stop", "Public synthetic refusal")])
async def test_harnessforge_sdk_policy_denies_non_stop_and_refusal_even_with_json_content(finish, refusal):
    request, _, _ = await _capture(_request(), lambda body, index: (200, _chat()))
    data = request.model_dump()
    body = canonical(_chat(finish=finish, refusal=refusal)).decode()
    data["transcript"][0].update(body=body, body_sha256=digest(body.encode()))
    result = await proof.prove(proof.Request.model_validate(data))
    assert result["state"] == "denied" and result["value"] is None


async def test_completion_policy_returns_same_native_sdk_object_after_one_delegate_and_rejects_multiple_choices():
    native = ChatCompletion.model_validate(_chat())
    calls = []
    async def create(**kwargs):
        calls.append(kwargs)
        return native
    assert await proof._CompletionGate(create).create(model="synthetic") is native
    assert calls == [{"model": "synthetic"}]
    request, _, _ = await _capture(_request(), lambda body, index: (200, _chat()))
    data = request.model_dump()
    response = _chat()
    response["choices"].append(copy.deepcopy(response["choices"][0]))
    body = canonical(response).decode()
    data["transcript"][0].update(body=body, body_sha256=digest(body.encode()))
    assert (await proof.prove(proof.Request.model_validate(data)))["state"] == "denied"


async def test_missing_choices_malformed_json_and_output_bounds_fail_closed(monkeypatch):
    request, _, _ = await _capture(_request(), lambda body, index: (200, _chat()))
    monkeypatch.setattr(proof, "MAX_REPLAY_SECONDS", 0.05)
    for response in [{"choices": []}, _chat(content="not JSON"), _chat(content="")]:
        data = request.model_dump()
        body = canonical(response).decode()
        data["transcript"][0].update(body=body, body_sha256=digest(body.encode()))
        result = await proof.prove(proof.Request.model_validate(data))
        assert result["state"] == "denied" and result["value"] is None
    data = request.model_dump()
    body = canonical(_chat({"summary": "x" * 2048})).decode()
    data["transcript"][0].update(body=body, body_sha256=digest(body.encode()))
    monkeypatch.setattr(proof, "MAX_RESPONSE", 1024)
    assert (await proof.prove(proof.Request.model_validate(data)))["error_code"] == "response_limit"


async def test_immutable_source_catalogue_dependency_and_actual_static_schema_are_required(tmp_path, monkeypatch):
    request, _, _ = await _capture(_request(), lambda body, index: (200, _chat()))
    changed = {**request.model_dump(), "source_lock_digest": "0" * 64}
    assert (await proof.prove(proof.Request.model_validate(changed)))["state"] == "denied"
    bad_dependencies = tmp_path / "dependencies.json"
    bad_dependencies.write_bytes(b"{}")
    with monkeypatch.context() as local:
        local.setattr(proof, "DEPENDENCIES_PATH", bad_dependencies)
        result = await proof.prove(request)
        assert result["state"] == "denied" and result["consumed_receipts"] == []
    catalogue = json.loads(proof.CATALOGUE_PATH.read_bytes())
    entry = next(entry for entry in catalogue["entries"] if entry["prompt_name"] == request.prompt_name)
    entry["schema"] = {"unsupported": True}
    entry["schema_digest"] = digest(canonical(entry["schema"]))
    bad_catalogue = tmp_path / "catalogue.json"
    bad_catalogue.write_bytes(canonical(catalogue))
    data = request.model_dump()
    data["catalogue_digest"] = data["pin"]["schema_digest"] = digest(bad_catalogue.read_bytes())
    data["pin"]["config_digest"] = digest(canonical({key: value for key, value in data["pin"].items() if key != "config_digest"}))
    monkeypatch.setattr(proof, "CATALOGUE_PATH", bad_catalogue)
    result = await proof.prove(proof.Request.model_validate(data))
    assert result["state"] == "denied" and result["consumed_receipts"] == []


def test_unknown_dynamic_prompts_options_callbacks_and_input_body_bounds_are_rejected():
    request = _request().model_dump()
    for change in [{"prompt_name": "extract_nodes.extract_attributes"}, {"prompt_name": "unknown.prompt"},
                   {"backend": {}}, {"callback": "arbitrary"}, {"module": "arbitrary"}, {"v": True},
                   {"options": {"max_tokens": 1, "model_size": "medium", "attribute_extraction": True}}]:
        with pytest.raises((ValueError, BoundaryError)):
            proof.Request.model_validate({**request, **change})
    body = "x" * (proof.MAX_BODY + 1)
    data = copy.deepcopy(request)
    data["transcript"][0].update(body=body, body_sha256=digest(body.encode()))
    with pytest.raises((ValueError, BoundaryError)):
        proof.Request.model_validate(data)
    with pytest.raises((ValueError, BoundaryError)):
        proof.Request.model_validate({**request, "messages": [{"role": "system", "content": "x" * 49153},
                                                             {"role": "user", "content": "Synthetic"}]})
    with pytest.raises((ValueError, BoundaryError)):
        _request("embedder", "embedder.create_batch", embed_input=["one", "two"])


async def test_cancellation_returns_no_value_or_execution_authority(monkeypatch):
    request = _request()
    entered = asyncio.Event()
    async def pending(*args):
        entered.set()
        await asyncio.Event().wait()
    monkeypatch.setattr(proof, "_native_call", pending)
    task = asyncio.create_task(proof.prove(request))
    await asyncio.wait_for(entered.wait(), 1)
    task.cancel()
    result = await task
    assert result["state"] == "denied" and result["error_code"] == "cancelled" and result["value"] is None


def test_one_frame_main_leaves_trailing_input_unconsumed_and_emits_only_one_bounded_reply(monkeypatch):
    data = canonical(_request().model_dump())
    async def mechanics(request):
        return proof._result(request, "ok", "1" * 64, [], {"component_mechanics_only": True})
    monkeypatch.setattr(proof, "prove", mechanics)
    reader = io.BytesIO(struct.pack(">I", len(data)) + data + b"TRAILING_UNINTERPRETED")
    writer = io.BytesIO()
    assert proof.main(reader, writer) == 0 and reader.read() == b"TRAILING_UNINTERPRETED"
    frame = writer.getvalue()
    length = struct.unpack(">I", frame[:4])[0]
    assert len(frame) == length + 4 and length <= proof.MAX_RESPONSE
    assert json.loads(frame[4:])["value"] == {"component_mechanics_only": True}
    for invalid in [b"", b"\0\0", struct.pack(">I", proof.MAX_REQUEST + 1),
                    b'\0\0\0\x02{', b'\0\0\0\x01\xff',
                    struct.pack(">I", 13) + b'{"v":1,"v":1}']:
        output = io.BytesIO()
        assert proof.main(io.BytesIO(invalid), output) == 0
        result = json.loads(output.getvalue()[4:])
        assert result["state"] == "denied" and result["value"] is None
