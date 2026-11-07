"""Closed native read observations; root alone certifies inventory membership.

No loader, query, ranking or hydration algorithm is implemented here. Each
registered async boundary delegates once while holding the operation's write
gate, then withholds the original native result until its root proof is known.
"""
from __future__ import annotations

import importlib
import inspect
import json
from functools import wraps
from typing import Any, Callable

from protocol import BoundaryError, canonical, digest

BOOTSTRAP_SEAM = "graphiti.bootstrap.v1"
BOOTSTRAP_TRANSFORM = "root_inventory_bootstrap_v1"
LOADER_PROJECTION = "native_loader_no_vector_v1"
_BOOTSTRAP_SCHEMA = {
    "$id": "hf.graph.bootstrap.v1", "type": "array", "minItems": 1, "maxItems": 100,
    "items": {"type": "object", "additionalProperties": False,
        "properties": {
            "entry_id": {"format": "uuid", "type": "string"},
            "kind": {"enum": ["episode", "deterministic_output", "edge", "summary", "attribute"]},
            "object_id": {"type": "string"},
            "parent_manifest_digest": {"pattern": "^[0-9a-f]{64}$", "type": "string"},
            "parent_manifest_ref": {"format": "uuid", "type": "string"},
            "predecessor_version_ref": {"type": "null"},
            "projection_hash": {"pattern": "^[0-9a-f]{64}$", "type": "string"},
            "projection_id": {"enum": ["identity_v1", LOADER_PROJECTION]},
            "receipt_ref": {"type": "null"}, "value": {},
            "value_hash": {"pattern": "^[0-9a-f]{64}$", "type": "string"},
            "version_ref": {"type": "null"}},
        "required": ["entry_id", "kind", "object_id", "parent_manifest_digest", "parent_manifest_ref",
            "predecessor_version_ref", "projection_hash", "projection_id", "receipt_ref", "value",
            "value_hash", "version_ref"]}}
BOOTSTRAP_SCHEMA_DIGEST = digest(canonical(_BOOTSTRAP_SCHEMA))

# Names are provenance of pinned wrapper sites, never caller-selected authority.
CLASS_READS = {
    "EpisodicNode": ("get_by_uuid", "get_by_uuids"),
    "EntityNode": ("get_by_names", "get_by_uuids"),
}
FUNCTION_READS = {
    "node_similarity_search": "EntityNode",
    "edge_fulltext_search": "EntityEdge",
    "edge_similarity_search": "EntityEdge",
}


def bootstrap_schema() -> dict:
    return json.loads(canonical(_BOOTSTRAP_SCHEMA))


def bootstrap_prompt_policy() -> dict:
    return {"format": "root-bootstrap-prompt-policy-v1", "prompt_name": BOOTSTRAP_SEAM,
            "provider_attempt": False, "stage": "extraction", "transform_id": BOOTSTRAP_TRANSFORM}


def registered_route(route: str, object_type: str) -> bool:
    if route.startswith("search_utils."):
        return FUNCTION_READS.get(route.removeprefix("search_utils.")) == object_type
    return route in {object_type + "." + method for method in CLASS_READS.get(object_type, ())}


def native_read_policy() -> dict:
    return {"format": "graphiti-native-read-policy-v1", "v": 1,
        "projection_id": LOADER_PROJECTION, "driver": "graphiti_core.driver.neo4j_driver.Neo4jDriver",
        "provider": "neo4j", "legacy_search_interface": "absent",
        "legacy_graph_operations_interface": "absent", "custom_attributes": "empty_only",
        "class_routes": [name + "." + method for name, methods in CLASS_READS.items() for method in methods],
        "function_routes": ["search_utils." + name for name in FUNCTION_READS],
        "bootstrap_seam": BOOTSTRAP_SEAM, "bootstrap_schema_digest": BOOTSTRAP_SCHEMA_DIGEST,
        "gate": "before_native_read_through_root_ack_and_cache",
        "objects_per_measurement": 10, "operation_cache_entries": 100,
        "unknown_routes": "denied", "hydration": "denied", "native_order": "unchanged"}


def without_vector(value: dict) -> dict:
    """The one closed read projection; all other bytes retain their meaning."""
    if (set(value) != {"object_type", "fields", "vector_commitments"}
            or value["object_type"] not in {"EntityNode", "EntityEdge"}
            or not isinstance(value["fields"], dict) or value["fields"].get("attributes") != {}
            or not isinstance(value["vector_commitments"], dict)):
        raise BoundaryError("closure_incomplete")
    return {"object_type": value["object_type"], "fields": value["fields"], "vector_commitments": {}}


def _profile(driver: object) -> None:
    from graphiti_core.driver.driver import GraphProvider
    from graphiti_core.driver.neo4j_driver import Neo4jDriver
    if (type(driver) is not Neo4jDriver or driver.provider is not GraphProvider.NEO4J
            or driver.search_interface is not None or driver.graph_operations_interface is not None):
        raise BoundaryError("closure_incomplete")


def wrap_read(original: Callable, route: str, object_type: str) -> Callable:
    """Wrap an actual registered unbound classmethod or imported async function."""
    if not registered_route(route, object_type):
        raise BoundaryError("closure_incomplete")

    @wraps(original)
    async def wrapped(*args: Any, **kwargs: Any) -> Any:
        from graphiti_core.errors import NodeNotFoundError
        from lineage import CURRENT_LINEAGE
        from observations import CURRENT_INTERMEDIATE
        state, lineage = CURRENT_INTERMEDIATE.get(None), CURRENT_LINEAGE.get(None)
        if state is None or lineage is None or lineage.job.op not in {"ingest", "search"}:
            raise BoundaryError("closure_incomplete")
        if (lineage.job.op == "search") != state.read_only:
            state.failure = "closure_incomplete"
            raise BoundaryError("closure_incomplete")
        if state.read_only and route not in {
                "search_utils.edge_fulltext_search", "search_utils.edge_similarity_search"}:
            state.failure = "closure_incomplete"
            raise BoundaryError("closure_incomplete")
        missing = None
        try:
            bound = inspect.signature(original).bind(*args, **kwargs)
            bound.apply_defaults()
            _profile(bound.arguments.get("driver"))
            if state.read_only and bound.arguments.get("group_ids") != [lineage.job.scope_ref]:
                raise BoundaryError("scope_denied")
            if "cls" in bound.arguments:
                from graphiti_core import nodes, edges
                expected = getattr(nodes, object_type, None) or getattr(edges, object_type, None)
                if bound.arguments["cls"] is not expected:
                    raise BoundaryError("closure_incomplete")
            async with state.read_scope():
                try:
                    result = await original(*args, **kwargs)  # exactly one native delegation
                except NodeNotFoundError as error:
                    # A new exact intent UUID is expected to be absent before
                    # EpisodicNode.save. Raise outside the gate without poison.
                    if (route != "EpisodicNode.get_by_uuid"
                            or bound.arguments.get("uuid") != lineage.job.args.get("episode_uuid")):
                        raise
                    missing = error
                if missing is None:
                    await state.observe_read(result, route, object_type)
                state.check_write_current()
            if missing is not None:
                raise missing
            return result
        except BaseException as error:
            if error is not missing:
                state.failure = state.failure or "closure_incomplete"
            raise
    return wrapped


async def _denied_read(*args: Any, **kwargs: Any) -> Any:
    from observations import CURRENT_INTERMEDIATE
    state = CURRENT_INTERMEDIATE.get(None)
    if state is not None:
        state.failure = state.failure or "closure_incomplete"
    raise BoundaryError("closure_incomplete")


def install_read_hooks() -> None:
    from graphiti_core import nodes, edges
    from graphiti_core.utils.maintenance import node_operations, edge_operations
    graph = importlib.import_module("graphiti_core.graphiti")
    search_utils = importlib.import_module("graphiti_core.search.search_utils")
    search = importlib.import_module("graphiti_core.search.search")
    for cls in (nodes.EpisodicNode, nodes.EntityNode, edges.EntityEdge, edges.EpisodicEdge):
        for name, descriptor in tuple(vars(cls).items()):
            if isinstance(descriptor, classmethod) and name.startswith("get_"):
                original = descriptor.__func__
                if not inspect.iscoroutinefunction(original):
                    raise BoundaryError("stage_unavailable")
                replacement = (wrap_read(original, cls.__name__ + "." + name, cls.__name__)
                    if name in CLASS_READS.get(cls.__name__, ()) else _denied_read)
                setattr(cls, name, classmethod(replacement))
            elif name.startswith("load_") and inspect.iscoroutinefunction(descriptor):
                setattr(cls, name, _denied_read)
    # Both definitions and actual aliases are changed. Synchronous deserializers
    # remain upstream-owned; an async ACK cannot safely wrap their return.
    for name in tuple(vars(search_utils)):
        original = getattr(search_utils, name)
        if not inspect.iscoroutinefunction(original):
            continue
        if name in FUNCTION_READS:
            replacement = wrap_read(original, "search_utils." + name, FUNCTION_READS[name])
        elif name.startswith(("get_", "community_", "episode_", "node_", "edge_")):
            replacement = _denied_read
        else:
            continue
        setattr(search_utils, name, replacement)
        for module in (search, node_operations, edge_operations, graph):
            if getattr(module, name, None) is original:
                setattr(module, name, replacement)
