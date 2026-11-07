"""One-shot trusted, application-read-only measurement of a dedicated Neo4j store.

Root owns the immutable executable, launch, network, write lease and inventory
revision. Database credentials are NOT a database-enforced read-only boundary.
No writer assertion, extraction algorithm, model client or Cypher input is used.
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import struct
import sys
from pathlib import Path
from types import MappingProxyType
from typing import Annotated, Any, BinaryIO, Callable, Literal

# Must precede Graphiti imports, including its package initializer.
os.environ["GRAPHITI_TELEMETRY_ENABLED"] = "false"
os.environ["PYTHON_DOTENV_DISABLED"] = "1"
if __name__ == "__main__":
    for _key in tuple(os.environ):
        if (_key.endswith(("_API_KEY", "_TOKEN")) or _key.lower().endswith("_proxy")
                or _key.startswith(("OTEL_", "HARNESSFORGE_"))):
            os.environ.pop(_key, None)
    # -I excludes the script directory. Add only the immutable reader directory.
    sys.path.insert(0, str(Path(__file__).resolve().parent))
logging.disable(logging.CRITICAL)

from neo4j import AsyncGraphDatabase, Query, READ_ACCESS
from pydantic import Field, JsonValue, ValidationError, field_validator, model_validator
from graphiti_core.driver.driver import GraphProvider
from graphiti_core.nodes import get_entity_node_from_record, get_episodic_node_from_record
from graphiti_core.edges import get_entity_edge_from_record, get_episodic_edge_from_record

from observations import native_value
from protocol import Boot, BoundaryError, ERRORS, ID, MAX_BODY, MAX_FRAME, Strict, canonical

UUID_PATTERN = r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
UUIDString = Annotated[str, Field(pattern="^" + UUID_PATTERN + "$", max_length=36)]
Kind = Literal["episode", "entity", "edge", "mention"]
Action = Literal["identity", "page", "objects"]


class Backend(Strict):
    uri: str
    user: str = Field(repr=False)
    password: str = Field(repr=False)
    database: ID

    @field_validator("uri")
    @classmethod
    def local_backend(cls, value: str) -> str:
        Boot.backend_local(value)
        if re.fullmatch(r"bolt://(?:neo4j:7687|127\.0\.0\.1:[0-9]{1,5}|\[::1\]:[0-9]{1,5})", value) is None:
            raise ValueError("invalid backend route")
        return value

    @field_validator("user", "password")
    @classmethod
    def bounded_secret(cls, value: str) -> str:
        if not value or len(value.encode()) > 4096 or any(c in value for c in "\0\r\n"):
            raise ValueError("invalid backend credential")
        return value


class Request(Strict):
    v: Literal[1]
    session_id: ID
    backend: Backend
    group_id: ID
    action: Action
    kind: Kind | None
    cursor: UUIDString | None
    limit: Annotated[int, Field(ge=1, le=10)]
    object_ids: Annotated[list[UUIDString], Field(max_length=10)]

    @field_validator("v", mode="before")
    @classmethod
    def integer_version(cls, value: object) -> object:
        if type(value) is not int:
            raise ValueError("invalid version")
        return value

    @model_validator(mode="after")
    def action_shape(self) -> Request:
        if len(set(self.object_ids)) != len(self.object_ids):
            raise ValueError("duplicate object")
        if self.action == "identity":
            if self.kind is not None or self.cursor is not None or self.object_ids or self.limit != 1:
                raise ValueError("identity shape")
        elif self.action == "page":
            if self.kind is None or self.object_ids:
                raise ValueError("page shape")
        elif self.kind is None or self.cursor is not None or not self.object_ids or self.limit < len(self.object_ids):
            raise ValueError("objects shape")
        return self


class Response(Strict):
    v: Literal[1]
    session_id: ID
    action: Action
    state: Literal["ok", "denied"]
    records: Annotated[list[dict[str, JsonValue]], Field(max_length=10)]
    next_cursor: UUIDString | None
    exhausted: bool
    error_code: str | None

    @field_validator("v", mode="before")
    @classmethod
    def integer_version(cls, value: object) -> object:
        if type(value) is not int:
            raise ValueError("invalid version")
        return value

    @model_validator(mode="after")
    def exact_shape(self) -> Response:
        bounded_tree(self.model_dump())
        if self.state == "denied":
            if self.records or self.next_cursor is not None or self.exhausted or self.error_code not in ERRORS:
                raise ValueError("denial shape")
        else:
            if self.error_code is not None or (self.exhausted == (self.next_cursor is not None)):
                raise ValueError("response cursor")
            if self.action == "identity" and (len(self.records) != 1 or not self.exhausted):
                raise ValueError("identity response")
            if self.action == "objects" and not self.exhausted:
                raise ValueError("objects response")
        if len(canonical(self.model_dump())) > MAX_BODY:
            raise BoundaryError("response_limit")
        return self


def bounded_tree(value: object, depth: int = 0) -> None:
    if depth > 12 or isinstance(value, float):
        raise BoundaryError("invalid_dto")
    if isinstance(value, dict):
        if len(value) > 100 or any(not isinstance(key, str) for key in value):
            raise BoundaryError("response_limit")
        for item in value.values():
            bounded_tree(item, depth + 1)
    elif isinstance(value, list):
        if len(value) > 100:
            raise BoundaryError("response_limit")
        for item in value:
            bounded_tree(item, depth + 1)
    elif value is not None and type(value) not in (str, int, bool):
        raise BoundaryError("invalid_dto")


def _pairs(pairs: list[tuple[str, object]]) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            raise BoundaryError("invalid_frame")
        result[key] = value
    return result


def decode_request(raw: bytes) -> Request:
    if not 1 <= len(raw) <= MAX_FRAME:
        raise BoundaryError("invalid_frame")
    try:
        value = json.loads(raw.decode("utf-8", errors="strict"), object_pairs_hook=_pairs,
                           parse_constant=lambda _: (_ for _ in ()).throw(BoundaryError("invalid_frame")))
        bounded_tree(value)
        return Request.model_validate(value)
    except (ValueError, UnicodeError, ValidationError, RecursionError) as error:
        raise BoundaryError("invalid_dto") from error


def _read_exact(reader: BinaryIO, size: int) -> bytes:
    chunks = bytearray()
    while len(chunks) < size:
        chunk = reader.read(size - len(chunks))
        if not chunk:
            raise BoundaryError("invalid_frame")
        chunks.extend(chunk)
    return bytes(chunks)


def read_request(reader: BinaryIO) -> Request:
    length = struct.unpack(">I", _read_exact(reader, 4))[0]
    if not 1 <= length <= MAX_FRAME:
        raise BoundaryError("invalid_frame")
    # Raw Elixir Ports cannot half-close stdin. Consume exactly one frame and
    # leave any trailing bytes uninterpreted; main measures once and exits.
    return decode_request(_read_exact(reader, length))


def encode_response(value: Response | dict) -> bytes:
    response = Response.model_validate(value.model_dump() if isinstance(value, Response) else value)
    raw = canonical(response.model_dump())
    return struct.pack(">I", len(raw)) + raw


# Only code-owned constants form query text. No request text becomes Cypher.
_NODE_KEYS = {
    "episode": ["uuid", "group_id", "name", "source", "source_description", "content", "created_at", "valid_at", "entity_edges"],
    "entity": ["uuid", "group_id", "name", "summary", "created_at", "name_embedding", "labels"],
}
_EDGE_KEYS = {
    "mention": ["uuid", "group_id", "created_at"],
    "edge": ["uuid", "group_id", "name", "fact", "fact_embedding", "episodes", "created_at", "valid_at",
             "invalid_at", "expired_at", "reference_time", "source_node_uuid", "target_node_uuid"],
}
_MATCH = {
    "episode": "(o:Episodic)", "entity": "(o:Entity)",
    "edge": "(s)-[o:RELATES_TO]->(t)", "mention": "(s)-[o:MENTIONS]->(t)",
}


def _string(field: str, size: int) -> str:
    return f"({field} IS :: STRING AND size({field}) <= {size})"


def _uuid(field: str) -> str:
    return f"({_string(field, 36)} AND {field} =~ '{UUID_PATTERN}')"


def _date(field: str, optional: bool = False) -> str:
    predicate = f"({field} IS :: ZONED DATETIME OR {_string(field, 64)})"
    return f"({field} IS NULL OR {predicate})" if optional else predicate


def _uuid_list(field: str) -> str:
    return f"({field} IS :: LIST<STRING> AND size({field}) <= 100 AND all(x IN {field} WHERE {_uuid('x')}))"


def _vector(field: str) -> str:
    return f"({field} IS NULL OR ({field} IS :: LIST<FLOAT> AND size({field}) = 1024))"


def _labels(alias: str, kind: str) -> str:
    allowed = "['Episodic']" if kind == "episode" else f"['Entity', 'Entity_' + replace({alias}.group_id, '-', '')]"
    required = "Episodic" if kind == "episode" else "Entity"
    return f"('{required}' IN labels({alias}) AND size(labels({alias})) <= 2 AND all(x IN labels({alias}) WHERE x IN {allowed}))"


def _guard(kind: str, alias: str = "o", *, scope: bool = True) -> str:
    keys = (_NODE_KEYS if kind in _NODE_KEYS else _EDGE_KEYS)[kind]
    key_literal = "[" + ",".join("'" + key + "'" for key in keys) + "]"
    terms = [f"size(keys({alias})) <= {len(keys)}", f"all(k IN keys({alias}) WHERE k IN {key_literal})",
             _uuid(alias + ".uuid"), _string(alias + ".group_id", 200),
             f"{alias}.group_id =~ '[A-Za-z0-9][A-Za-z0-9_.:-]{{0,199}}'", _date(alias + ".created_at")]
    if scope:
        terms.append(f"{alias}.group_id = $group_id")
    if kind in _NODE_KEYS:
        terms.extend([_labels(alias, kind), _string(alias + ".name", 200)])
        if kind == "episode":
            terms.extend([f"{alias}.source IN ['message','text','json']", _string(alias + ".source_description", 2048),
                          _string(alias + ".content", 4096), _date(alias + ".valid_at"), _uuid_list(alias + ".entity_edges")])
        else:
            terms.extend([_string(alias + ".summary", 4096), _vector(alias + ".name_embedding"),
                f"({alias}.labels IS NULL OR ({alias}.labels IS :: LIST<STRING> AND size({alias}.labels) <= 2 "
                f"AND all(x IN {alias}.labels WHERE x IN ['Entity', 'Entity_' + replace({alias}.group_id, '-', '')])))"])
    else:
        terms.extend([_labels("s", "episode" if kind == "mention" else "entity"), _labels("t", "entity"),
                      _uuid("s.uuid"), _uuid("t.uuid"), f"s.group_id = {alias}.group_id", f"t.group_id = {alias}.group_id"])
        if kind == "edge":
            terms.extend([_string(alias + ".name", 200), _string(alias + ".fact", 4096),
                _uuid_list(alias + ".episodes"), _vector(alias + ".fact_embedding"),
                f"({alias}.source_node_uuid IS NULL OR {alias}.source_node_uuid = s.uuid)",
                f"({alias}.target_node_uuid IS NULL OR {alias}.target_node_uuid = t.uuid)"])
            terms.extend(_date(alias + "." + name, True) for name in ("valid_at", "invalid_at", "expired_at", "reference_time"))
    return "(" + " AND ".join(terms) + ")"


def _projection(kind: str) -> str:
    if kind == "episode":
        names = ("uuid", "group_id", "name", "source", "source_description", "content", "created_at", "valid_at", "entity_edges")
    elif kind == "entity":
        names = ("uuid", "group_id", "name", "summary", "created_at", "name_embedding")
    elif kind == "edge":
        names = ("uuid", "group_id", "name", "fact", "fact_embedding", "episodes", "created_at", "valid_at", "invalid_at", "expired_at", "reference_time")
    else:
        names = ("uuid", "group_id", "created_at")
    fields = [f"{name}: o.{name}" for name in names]
    if kind == "entity":
        fields.extend(["labels: labels(o)", "attributes: {}"])
    if kind in {"edge", "mention"}:
        fields.extend(["source_node_uuid: s.uuid", "target_node_uuid: t.uuid"])
    if kind == "edge":
        fields.append("attributes: {}")
    return "{" + ", ".join(fields) + "}"


def _queries() -> dict[str, str]:
    queries = {}
    for kind, pattern in _MATCH.items():
        # Invalid UUIDs remain eligible, so they cannot disappear behind a cursor
        # and produce a false exhausted=true result.
        cursor = f"(NOT coalesce({_uuid('o.uuid')}, false) OR $cursor IS NULL OR o.uuid < $cursor)"
        projection = f"WITH o" + (", s, t" if kind in _EDGE_KEYS else "")
        projection += f", coalesce({_guard(kind)}, false) AS safe RETURN safe, CASE WHEN safe THEN {_projection(kind)} ELSE null END AS record"
        queries[kind + ":page"] = (f"MATCH {pattern} WHERE o.group_id = $group_id AND {cursor} "
            f"WITH o" + (", s, t" if kind in _EDGE_KEYS else "") + f" ORDER BY o.uuid DESC LIMIT $limit {projection}")
        queries[kind + ":objects"] = (f"MATCH {pattern} WHERE o.uuid IN $object_ids WITH o"
            + (", s, t" if kind in _EDGE_KEYS else "") + f" ORDER BY o.uuid DESC LIMIT $limit {projection}")
        queries[kind + ":more"] = f"RETURN EXISTS {{ MATCH {pattern} WHERE o.group_id = $group_id AND {cursor} }} AS more"
        queries[kind + ":count"] = (f"MATCH {pattern} WHERE o.uuid IN $object_ids "
            "RETURN count(o) AS count, count(DISTINCT o.uuid) AS unique_count")
    queries["identity:component"] = """CALL dbms.components() YIELD name, versions, edition
        WHERE name = 'Neo4j Kernel'
        RETURN CASE WHEN size(versions) = 1 AND versions[0] IS :: STRING AND size(versions[0]) <= 200
          AND edition IS :: STRING AND size(edition) <= 200
          THEN {edition:edition,version:versions[0]} ELSE null END AS component LIMIT 1"""
    queries["identity:database"] = """CALL db.info() YIELD name
        RETURN CASE WHEN name IS :: STRING AND size(name) <= 200 THEN name ELSE null END AS database LIMIT 1"""
    node_shape = f"({_guard('episode', 'n', scope=False)} OR {_guard('entity', 'n', scope=False)})"
    edge_shape = f"((type(o) = 'MENTIONS' AND {_guard('mention', scope=False)}) OR (type(o) = 'RELATES_TO' AND {_guard('edge', scope=False)}))"
    queries["identity:counts"] = f"""CALL {{ MATCH (n) WHERE NOT coalesce(n.group_id = $group_id, false) RETURN count(n) AS foreign_nodes }}
        CALL {{ MATCH ()-[o]->() WHERE NOT coalesce(o.group_id = $group_id, false) RETURN count(o) AS foreign_edges }}
        CALL {{ MATCH (n) WHERE NOT coalesce({node_shape}, false) RETURN count(n) AS unknown_nodes }}
        CALL {{ MATCH (s)-[o]->(t) WHERE NOT coalesce({edge_shape}, false) RETURN count(o) AS unknown_edges }}
        RETURN foreign_nodes,foreign_edges,unknown_nodes,unknown_edges"""
    return queries


QUERIES = MappingProxyType(_queries())


async def _rows(session: Any, key: str, parameters: dict, cap: int) -> list[dict]:
    result = await session.run(Query(QUERIES[key], timeout=10.0), parameters)
    rows = []
    async for record in result:
        if len(rows) >= cap:
            raise BoundaryError("response_limit")
        rows.append(dict(record))
    return rows


def _typed_record(kind: str, row: dict, group_id: str) -> dict:
    if set(row) != {"safe", "record"} or row["safe"] is not True or not isinstance(row["record"], dict):
        raise BoundaryError("closure_incomplete")
    record = row["record"]
    if record.get("group_id") != group_id or re.fullmatch(UUID_PATTERN, str(record.get("uuid", ""))) is None:
        raise BoundaryError("scope_denied")
    # These maps came through an explicit CASE-guarded, fixed projection. Check
    # again before an upstream helper can mutate its attributes/labels in place.
    expected = {"episode": set(_NODE_KEYS["episode"]),
        "entity": {"uuid", "group_id", "name", "summary", "created_at", "name_embedding", "labels", "attributes"},
        "edge": {"uuid", "group_id", "name", "fact", "fact_embedding", "episodes", "created_at", "valid_at", "invalid_at",
                 "expired_at", "reference_time", "source_node_uuid", "target_node_uuid", "attributes"},
        "mention": {"uuid", "group_id", "created_at", "source_node_uuid", "target_node_uuid"}}[kind]
    if set(record) != expected or record.get("attributes", {}) != {}:
        raise BoundaryError("closure_incomplete")
    if kind == "episode":
        obj = get_episodic_node_from_record(record)
    elif kind == "entity":
        obj = get_entity_node_from_record(record, GraphProvider.NEO4J)
    elif kind == "edge":
        obj = get_entity_edge_from_record(record, GraphProvider.NEO4J)
    else:
        obj = get_episodic_edge_from_record(record)
    projection = native_value(obj)
    bounded_tree(projection)
    if len(canonical(projection)) > 16384:
        raise BoundaryError("response_limit")
    return projection


def denied(request: Request | None, code: str) -> Response:
    return Response(v=1, session_id=request.session_id if request else "inventory:invalid",
        action=request.action if request else "identity", state="denied", records=[], next_cursor=None,
        exhausted=False, error_code=code if code in ERRORS else "provider_error")


async def measure(value: Request | dict, *, driver_factory: Callable | None = None) -> Response:
    request = None
    try:
        request = Request.model_validate(value.model_dump() if isinstance(value, Request) else value)
        factory = driver_factory or AsyncGraphDatabase.driver
        backend = request.backend
        async with factory(backend.uri, auth=(backend.user, backend.password), connection_timeout=10.0,
                           max_connection_pool_size=1, max_transaction_retry_time=0.0) as driver:
            async with driver.session(database=backend.database, default_access_mode=READ_ACCESS, fetch_size=10) as session:
                async with asyncio.timeout(30):
                    return await _measure(request, session)
    except BoundaryError as error:
        return denied(request, error.code)
    except (ValidationError, ValueError, TypeError, UnicodeError, RecursionError):
        return denied(request, "invalid_dto")
    except Exception:
        # Never include backend exceptions, queries, raw rows or credentials.
        return denied(request, "provider_error")


async def _measure(request: Request, session: Any) -> Response:
    if request.action == "identity":
        component = await _rows(session, "identity:component", {}, 1)
        database = await _rows(session, "identity:database", {}, 1)
        counts = await _rows(session, "identity:counts", {"group_id": request.group_id}, 1)
        if (len(component) != 1 or len(database) != 1 or len(counts) != 1
                or set(component[0]) != {"component"} or set(database[0]) != {"database"}
                or not isinstance(component[0]["component"], dict)
                or set(component[0]["component"]) != {"edition", "version"}
                or not isinstance(database[0]["database"], str)):
            raise BoundaryError("stage_unavailable")
        identity = {**component[0]["component"], **database[0], **counts[0]}
        if (set(identity) != {"edition", "version", "database", "foreign_nodes", "foreign_edges", "unknown_nodes", "unknown_edges"}
                or any(not isinstance(identity[key], str) or not identity[key] or len(identity[key].encode()) > 800
                       for key in ("edition", "version", "database"))
                or any(type(identity[key]) is not int or identity[key] < 0
                       for key in ("foreign_nodes", "foreign_edges", "unknown_nodes", "unknown_edges"))):
            raise BoundaryError("stage_unavailable")
        return Response(v=1, session_id=request.session_id, action=request.action, state="ok", records=[identity],
                        next_cursor=None, exhausted=True, error_code=None)
    assert request.kind is not None
    parameters = {"group_id": request.group_id, "cursor": request.cursor,
                  "limit": request.limit, "object_ids": request.object_ids}
    rows = await _rows(session, request.kind + ":" + request.action, parameters, request.limit)
    records = [_typed_record(request.kind, row, request.group_id) for row in rows]
    ids = [record["fields"]["uuid"] for record in records]
    if ids != sorted(set(ids), reverse=True) or (request.cursor is not None and any(identity >= request.cursor for identity in ids)):
        raise BoundaryError("reconcile_required")
    if request.action == "objects" and set(ids) != set(request.object_ids):
        raise BoundaryError("closure_incomplete")
    counts = await _rows(session, request.kind + ":count", {"object_ids": ids}, 1)
    if (len(counts) != 1 or set(counts[0]) != {"count", "unique_count"}
            or any(type(counts[0][key]) is not int or counts[0][key] != len(ids) for key in ("count", "unique_count"))):
        raise BoundaryError("reconcile_required")
    more = False
    if request.action == "page":
        metadata = await _rows(session, request.kind + ":more",
                               {"group_id": request.group_id, "cursor": ids[-1] if ids else request.cursor}, 1)
        if len(metadata) != 1 or set(metadata[0]) != {"more"} or type(metadata[0]["more"]) is not bool:
            raise BoundaryError("reconcile_required")
        more = metadata[0]["more"]
        if more and not ids:
            raise BoundaryError("reconcile_required")
    return Response(v=1, session_id=request.session_id, action=request.action, state="ok", records=records,
                    next_cursor=ids[-1] if more else None, exhausted=not more, error_code=None)


def main(reader: BinaryIO | None = None, writer: BinaryIO | None = None) -> None:
    reader, writer = reader or sys.stdin.buffer, writer or sys.stdout.buffer
    request = None
    try:
        request = read_request(reader)
        response = asyncio.run(measure(request))
    except BoundaryError as error:
        response = denied(request, error.code)
    except Exception:
        response = denied(request, "invalid_frame")
    writer.write(encode_response(response))
    writer.flush()


if __name__ == "__main__":
    main()
