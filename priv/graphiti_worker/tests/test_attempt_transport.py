import asyncio
import json

import httpx
import pytest
from graphiti_core.prompts.models import Message

from fixtures.helpers import context_reply, job, pin, reply
from ipc_transport import IPCTransport
from lineage import call, operation
from observations import observed_call
from protocol import BoundaryError
from runtime import MeteredJev


async def test_real_jev_split_is_three_individually_admitted_posts():
    attempts = []
    async def relay(attempt):
        attempts.append(attempt)
        data = json.loads(attempt.body)
        if len(data["questions"]) > 1:
            return reply(attempt, "max_tokens_exceeded", 400)
        return reply(attempt, {"answers": {k: {"choice": "none"} for k in data["questions"]},
                               "usage": {"input_tokens": 2, "output_tokens": 1}})
    stage = pin()
    async with httpx.AsyncClient(transport=IPCTransport(stage, relay, asyncio.Semaphore(1)), trust_env=False) as http:
        client = MeteredJev(stage, http)
        payload = {"state": "<ENTITIES>[]</ENTITIES>", "questions": {
            "e0": {"type": "choice", "instructions": "Synthetic A", "criteria": {"none": "none"}},
            "e1": {"type": "choice", "instructions": "Synthetic B", "criteria": {"none": "none"}}}}
        with operation(job()) as lineage:
            async with observed_call(stage, "dedupe_nodes.nodes", payload, context_reply):
                result = await client.generate_response([Message(role="user", content=json.dumps(payload))],
                                                        prompt_name="dedupe_nodes.nodes")
            assert result == {"entity_resolutions": []}
            assert len(lineage.receipts) == 3
    assert [a.ordinal for a in attempts] == [1, 2, 3]
    assert attempts[1].predecessor_attempt_id == attempts[0].attempt_id
    assert len({a.logical_call_id for a in attempts}) == 1
    assert len({a.attempt_id for a in attempts}) == 3
    assert attempts[1].context_changed and attempts[2].context_changed


async def test_split_cannot_spend_a_fourth_attempt_even_with_native_recursion():
    attempts = []
    async def relay(attempt):
        attempts.append(attempt)
        data = json.loads(attempt.body)
        if len(data["questions"]) > 1:
            return reply(attempt, "max_tokens_exceeded", 400)
        return reply(attempt, {"answers": {k: {"choice": "none"} for k in data["questions"]}})
    stage = pin()
    async with httpx.AsyncClient(transport=IPCTransport(stage, relay, asyncio.Semaphore(1))) as http:
        client = MeteredJev(stage, http)
        payload = {"state": "<ENTITIES>[]</ENTITIES>", "questions": {
            f"e{i}": {"type": "choice", "instructions": "Synthetic", "criteria": {"none": "none"}}
            for i in range(4)}}
        with operation(job()), pytest.raises(BoundaryError, match="budget_exhausted"):
            async with observed_call(stage, "dedupe_nodes.nodes", payload, context_reply):
                await client.generate_response([Message(role="user", content=json.dumps(payload))],
                                               prompt_name="dedupe_nodes.nodes")
    assert len(attempts) == 3


async def test_transport_denies_wrong_route_missing_closure_and_mismatched_grant():
    calls = []
    async def relay(attempt):
        calls.append(attempt)
        grant, receipt = reply(attempt, {"ok": True})
        return grant.model_copy(update={"payload_sha256": "0" * 64}), receipt
    stage = pin()
    async with httpx.AsyncClient(transport=IPCTransport(stage, relay, asyncio.Semaphore(1))) as client:
        with pytest.raises(BoundaryError, match="scope_denied"):
            await client.post("https://foreign.invalid/", json={})
        with pytest.raises(BoundaryError, match="closure_incomplete"):
            await client.post(stage.endpoint, json={})
        assert calls == []
        with operation(job()), call(stage.id, "dedupe_nodes.nodes"), pytest.raises(BoundaryError, match="closure_incomplete"):
            await client.post(stage.endpoint, json={})
        assert calls == []
        with operation(job()):
            async with observed_call(stage, "dedupe_nodes.nodes", {"synthetic": True}, context_reply):
                with pytest.raises(BoundaryError, match="reconcile_required"):
                    await client.post(stage.endpoint, json={"model": stage.model, "state": "synthetic", "questions": {}})
        assert len(calls) == 1


async def test_native_unsupported_jev_prompt_fails_before_relay():
    calls = []
    async def relay(attempt):
        calls.append(attempt)
        return reply(attempt, {})
    stage = pin()
    async with httpx.AsyncClient(transport=IPCTransport(stage, relay, asyncio.Semaphore(1))) as http:
        with pytest.raises(ValueError, match="unsupported"):
            await MeteredJev(stage, http).generate_response([], prompt_name="extract_nodes.extract_text")
    assert calls == []
