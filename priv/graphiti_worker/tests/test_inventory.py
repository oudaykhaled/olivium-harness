"""Mocked official-driver boundary tests; actual Cypher/read-only checks are root-owned."""
import io
import json
import re
import struct
from datetime import datetime, timezone

import pytest
from pydantic import ValidationError
from neo4j import READ_ACCESS
from graphiti_core.nodes import EntityNode

from inventory import (Backend, QUERIES, Request, Response, decode_request, encode_response,
                       measure, read_request)
from observations import native_value, vector_commitment
from protocol import BoundaryError, MAX_BODY, MAX_FRAME, canonical

DATE = datetime(2026, 1, 1, tzinfo=timezone.utc)
A = "00000000-0000-0000-0000-000000000001"
B = "00000000-0000-0000-0000-000000000002"
C = "00000000-0000-0000-0000-000000000003"


def request(action="page", kind="entity", **updates):
    value = {"v": 1, "session_id": "inventory:synthetic", "backend": {
        "uri": "bolt://neo4j:7687", "user": "synthetic-user", "password": "synthetic-secret", "database": "neo4j"},
        "group_id": "synthetic_group", "action": action, "kind": kind, "cursor": None, "limit": 2, "object_ids": []}
    if action == "identity":
        value.update(kind=None, limit=1)
    if action == "objects":
        value.update(object_ids=[A])
    value.update(updates)
    return value


def entity(identity=A, *, group="synthetic_group", **updates):
    record = {"uuid": identity, "group_id": group, "name": "Synthetic owner", "summary": "Synthetic relationship",
              "created_at": DATE.isoformat(), "name_embedding": None, "labels": ["Entity"], "attributes": {}}
    record.update(updates)
    return {"safe": True, "record": record}


class Result:
    def __init__(self, rows):
        self.rows = iter(rows)

    def __aiter__(self):
        return self

    async def __anext__(self):
        try:
            return next(self.rows)
        except StopIteration:
            raise StopAsyncIteration


class Session:
    def __init__(self, script):
        self.script, self.calls = script, []

    async def __aenter__(self):
        return self

    async def __aexit__(self, *args):
        return False

    async def run(self, query, parameters):
        key = next(key for key, text in QUERIES.items() if query.text == text)
        self.calls.append((key, parameters))
        rows = self.script[key]
        if isinstance(rows, Exception):
            raise rows
        return Result(rows)


class Driver:
    def __init__(self, session):
        self.active_session, self.options, self.closed = session, None, False

    async def __aenter__(self):
        return self

    async def __aexit__(self, *args):
        self.closed = True
        return False

    def session(self, **options):
        self.options = options
        return self.active_session


class Factory:
    def __init__(self, script):
        self.session = Session(script)
        self.driver, self.calls = Driver(self.session), []

    def __call__(self, uri, **options):
        self.calls.append((uri, options))
        return self.driver


def script(rows, *, more=False, count=None):
    count = len(rows) if count is None else count
    return {"entity:page": rows, "entity:objects": rows,
            "entity:count": [{"count": count, "unique_count": count}], "entity:more": [{"more": more}]}


async def test_unknown_mutation_query_keys_and_invalid_shapes_deny_before_driver_open():
    factory = Factory({})
    changes = [{"action": "write"}, {"query": "MATCH (n) DETACH DELETE n"}, {"limit": True},
               {"limit": 11}, {"v": True}, {"kind": "Cypher"}, {"cursor": "unbounded"},
               {"object_ids": [A, A]}, {"backend": {**request()["backend"], "cypher": "RETURN 1"}}]
    for change in changes:
        response = await measure({**request(), **change}, driver_factory=factory)
        assert response.state == "denied" and response.records == []
    assert factory.calls == []


def test_backend_has_exact_local_routes_and_credentials_never_appear_in_repr():
    selected = Backend.model_validate(request()["backend"])
    assert "synthetic-secret" not in repr(selected)
    for uri in ["bolt://foreign.example:7687", "bolt://neo4j:9999", "bolt://neo4j:7687/",
                "bolt://user:secret@neo4j:7687", "bolt://127.0.0.1:7687?query=anything"]:
        with pytest.raises(ValidationError):
            Backend.model_validate({**selected.model_dump(), "uri": uri})


def test_strict_packet_rejects_malformed_input_and_leaves_trailing_bytes_unconsumed(monkeypatch):
    valid = canonical(request())
    assert decode_request(valid).group_id == "synthetic_group"
    for raw in [b'{"v":1,"v":1}', b"\xff", valid.replace(b'"limit":2', b'"limit":NaN')]:
        with pytest.raises(BoundaryError):
            decode_request(raw)
    packet = struct.pack(">I", len(valid)) + valid
    assert read_request(io.BytesIO(packet)).session_id == "inventory:synthetic"
    stream = io.BytesIO(packet + packet + b"extra")
    assert read_request(stream).session_id == "inventory:synthetic"
    assert stream.tell() == len(packet)
    assert stream.read() == packet + b"extra"
    import inventory
    calls = []
    async def once(selected):
        calls.append(selected)
        return Response(v=1, session_id=selected.session_id, action=selected.action, state="ok", records=[],
                        next_cursor=None, exhausted=True, error_code=None)
    monkeypatch.setattr(inventory, "measure", once)
    stream, output = io.BytesIO(packet + packet + b"extra"), io.BytesIO()
    inventory.main(stream, output)
    assert len(calls) == 1 and stream.tell() == len(packet)
    raw = output.getvalue()
    assert struct.unpack(">I", raw[:4])[0] == len(raw[4:])
    with pytest.raises(BoundaryError):
        read_request(io.BytesIO(packet[:-1]))


def test_oversized_prefix_is_denied_before_any_body_read():
    class PrefixOnly:
        def __init__(self):
            self.calls = []
        def read(self, count):
            self.calls.append(count)
            assert len(self.calls) == 1
            return struct.pack(">I", MAX_FRAME + 1)
    reader = PrefixOnly()
    with pytest.raises(BoundaryError, match="invalid_frame"):
        read_request(reader)
    assert reader.calls == [4]


async def test_parameterized_page_and_independent_exhaustion_keep_short_page_cursor():
    factory = Factory(script([entity(B)], more=True))
    response = await measure(request(limit=10), driver_factory=factory)
    assert response.state == "ok" and response.next_cursor == B and response.exhausted is False
    assert [name for name, _ in factory.session.calls] == ["entity:page", "entity:count", "entity:more"]
    assert factory.session.calls[-1][1] == {"group_id": "synthetic_group", "cursor": B}
    assert factory.driver.options == {"database": "neo4j", "default_access_mode": READ_ACCESS, "fetch_size": 10}
    assert factory.driver.closed
    assert factory.calls[0][1]["max_transaction_retry_time"] == 0
    assert "synthetic_group" not in QUERIES["entity:page"]


async def test_full_desc_page_can_be_exhausted_and_invalid_order_denies():
    factory = Factory(script([entity(B), entity(A)]))
    response = await measure(request(), driver_factory=factory)
    assert response.state == "ok" and response.exhausted is True and response.next_cursor is None
    for rows in [[entity(A), entity(B)], [entity(A), entity(A)]]:
        assert (await measure(request(), driver_factory=Factory(script(rows)))).state == "denied"
    assert (await measure(request(cursor=A), driver_factory=Factory(script([entity(B)])))).state == "denied"


async def test_exact_objects_reject_foreign_missing_and_duplicate_rows_beyond_limit():
    foreign = await measure(request("objects"), driver_factory=Factory(script([entity(group="foreign")])))
    missing = await measure(request("objects"), driver_factory=Factory(script([])))
    duplicate = await measure(request("objects", limit=1), driver_factory=Factory(script([entity()], count=2)))
    assert all(result.state == "denied" and result.records == [] for result in [foreign, missing, duplicate])
    valid = await measure(request("objects", limit=1), driver_factory=Factory(script([entity()])))
    assert valid.state == "ok" and valid.exhausted and valid.next_cursor is None


async def test_unsafe_server_marker_custom_attributes_and_wide_supports_deny_whole_result():
    for row in [{"safe": False, "record": None}, entity(attributes={"custom_owner": "Must not be omitted"}),
                entity(unknown_property="Must not be omitted")]:
        result = await measure(request(), driver_factory=Factory(script([row])))
        assert result.state == "denied" and result.records == []
    edge = {"uuid": A, "group_id": "synthetic_group", "name": "RELATES", "fact": "Synthetic fact",
        "fact_embedding": None, "episodes": [B] * 101, "created_at": DATE.isoformat(), "valid_at": None,
        "invalid_at": None, "expired_at": None, "reference_time": None, "source_node_uuid": B,
        "target_node_uuid": C, "attributes": {}}
    result = await measure(request(kind="edge"), driver_factory=Factory({"edge:page": [{"safe": True, "record": edge}]}))
    assert result.state == "denied" and result.records == []


async def test_native_typed_projection_and_exact_double_vector_commitment():
    vector = [0.0] * 1024
    vector[1] = -0.0
    vector[2] = 0.25
    factory = Factory(script([entity(name_embedding=vector)]))
    response = await measure(request(), driver_factory=factory)
    expected = EntityNode(uuid=A, group_id="synthetic_group", name="Synthetic owner", summary="Synthetic relationship",
                          labels=["Entity"], created_at=DATE, name_embedding=vector, attributes={})
    assert response.state == "ok" and response.records == [native_value(expected)]
    assert response.records[0]["vector_commitments"]["name_embedding"] == vector_commitment(vector)
    assert "name_embedding" not in response.records[0]["fields"]
    assert len(encode_response(response)) <= MAX_BODY + 4


async def test_episode_and_mention_use_real_pinned_deserializers():
    episode = {"uuid": A, "group_id": "synthetic_group", "name": "Synthetic episode", "source": "text",
        "source_description": "Synthetic revision", "content": "Synthetic original", "created_at": DATE.isoformat(),
        "valid_at": DATE.isoformat(), "entity_edges": [B]}
    mention = {"uuid": B, "group_id": "synthetic_group", "created_at": DATE.isoformat(),
               "source_node_uuid": A, "target_node_uuid": C}
    for kind, raw, object_type in [("episode", episode, "EpisodicNode"), ("mention", mention, "EpisodicEdge")]:
        data = {kind + ":objects": [{"safe": True, "record": raw}], kind + ":count": [{"count": 1, "unique_count": 1}]}
        result = await measure(request("objects", kind=kind, object_ids=[raw["uuid"]]), driver_factory=Factory(data))
        assert result.state == "ok" and result.records[0]["object_type"] == object_type
        assert result.records[0]["fields"]["uuid"] == raw["uuid"]


async def test_identity_comes_from_server_metadata_and_reports_foreign_unknown_counts():
    data = {"identity:component": [{"component": {"edition": "community", "version": "5.26.32"}}],
        "identity:database": [{"database": "actual_server_database"}],
        "identity:counts": [{"foreign_nodes": 2, "foreign_edges": 0, "unknown_nodes": 1, "unknown_edges": 0}]}
    factory = Factory(data)
    result = await measure(request("identity"), driver_factory=factory)
    assert result.state == "ok" and result.records[0]["database"] == "actual_server_database"
    assert result.records[0]["foreign_nodes"] == 2 and result.records[0]["unknown_nodes"] == 1
    assert result.records[0]["database"] != request()["backend"]["database"]
    data["identity:component"] = [{"component": None}]
    result = await measure(request("identity"), driver_factory=Factory(data))
    assert result.state == "denied" and result.error_code == "stage_unavailable"


async def test_backend_errors_never_echo_query_rows_or_credentials(capsys):
    sensitive = "synthetic-secret MATCH (n) DETACH DELETE n private-row"
    factory = Factory({"entity:page": RuntimeError(sensitive)})
    result = await measure(request(), driver_factory=factory)
    raw = encode_response(result)
    assert result.state == "denied" and result.error_code == "provider_error"
    assert sensitive.encode() not in raw and b"synthetic-secret" not in raw
    assert capsys.readouterr() == ("", "")


def test_only_fixed_read_queries_have_case_property_guards_and_no_extra_page_fetch():
    assert len(QUERIES) == 19
    for name, query in QUERIES.items():
        assert not any(re.search(r"\b" + mutation + r"\b", query, re.IGNORECASE)
                       for mutation in ["CREATE", "MERGE", "DELETE", "SET", "REMOVE", "LOAD", "OFFSET"])
        assert "properties(" not in query and ".*}" not in query
        if name.endswith((":page", ":objects")):
            assert "LIMIT $limit" in query and "CASE WHEN safe THEN" in query
            assert "all(k IN keys(o) WHERE k IN" in query
        if name.endswith(":more"):
            assert "RETURN EXISTS" in query
        assert "101" not in query and "$query" not in query


def test_response_exact_shape_nonfinite_and_frame_bounds():
    value = {"v": 1, "session_id": "inventory:synthetic", "action": "page", "state": "ok", "records": [],
             "next_cursor": None, "exhausted": True, "error_code": None}
    response = Response.model_validate(value)
    packet = encode_response(response)
    assert struct.unpack(">I", packet[:4])[0] == len(packet[4:])
    assert json.loads(packet[4:]) == value
    for change in [{"authority": True}, {"records": [{"score": 0.5}]}, {"records": [{}] * 11},
                   {"records": [{"body": "x" * MAX_BODY}]}]:
        with pytest.raises((BoundaryError, ValidationError)):
            Response.model_validate({**value, **change})
