"""Closed read-only search composition; ranking and loaders remain upstream.

The schema/policy are the decoded root-native-search-abi-v1 constants. Score
bits measure native output; this module does not implement the root completion
hash or independently assert relevance, membership, or publication authority.
"""
from __future__ import annotations

import copy
import json
import math
import struct
from typing import TYPE_CHECKING
from uuid import UUID

from protocol import BoundaryError, Job, Search, StagePin, canonical, digest

if TYPE_CHECKING:
    from graphiti_core import Graphiti
    from observations import ObserverRelay

SEARCH_SEAM = "graphiti.search.v1"
SEARCH_INPUT_TRANSFORM = "root_search_intent_v1"
SEARCH_RESULT_TRANSFORM = "native_search_rrf_v1"
_SEARCH_SCHEMA = {
    "$id": "hf.graph.search.v1", "oneOf": [
        {"additionalProperties": False, "properties": {
            "group_id": {"maxLength": 200, "minLength": 1, "type": "string"},
            "limit": {"maximum": 10, "minimum": 1, "type": "integer"},
            "query": {"maxLength": 256, "minLength": 1, "type": "string"},
            "recipe_id": {"enum": ["edge_hybrid_rrf_v1"]}},
         "required": ["query", "limit", "recipe_id", "group_id"], "type": "object"},
        {"additionalProperties": False, "properties": {"candidates": {
            "items": {"additionalProperties": False, "properties": {
                "edge_id": {"format": "uuid", "type": "string"},
                "episode_ids": {"items": {"format": "uuid", "type": "string"},
                    "maxItems": 24, "minItems": 1, "type": "array", "uniqueItems": True},
                "score": {"additionalProperties": False, "properties": {
                    "bits": {"pattern": "^[0-9a-f]{16}$", "type": "string"},
                    "format": {"enum": ["ieee754-be-f64-v1"]}},
                    "required": ["format", "bits"], "type": "object"}},
                "required": ["edge_id", "episode_ids", "score"], "type": "object"},
            "maxItems": 10, "minItems": 0, "type": "array"}},
         "required": ["candidates"], "type": "object"}]}
SEARCH_SCHEMA_DIGEST = digest(canonical(_SEARCH_SCHEMA))


def search_schema() -> dict:
    return json.loads(canonical(_SEARCH_SCHEMA))


def search_prompt_policy() -> dict:
    return {"format": "root-search-prompt-policy-v1", "input_transform_id": SEARCH_INPUT_TRANSFORM,
        "prompt_name": SEARCH_SEAM, "provider_attempt": False,
        "result_transform_id": SEARCH_RESULT_TRANSFORM, "stage": "embedder"}


def native_search_policy() -> dict:
    return {"format": "graphiti-native-search-policy-v1", "v": 1,
        "seam": SEARCH_SEAM, "schema_digest": SEARCH_SCHEMA_DIGEST,
        "prompt_policy": search_prompt_policy(), "recipe_id": "edge_hybrid_rrf_v1",
        "native_call": "Graphiti.search_", "recipe": "deepcopy:EDGE_HYBRID_SEARCH_RRF:limit_only",
        "read_routes": ["search_utils.edge_fulltext_search", "search_utils.edge_similarity_search"],
        "query_max_bytes": 1024, "query_max_characters": 256, "limit_min": 1, "limit_max": 10,
        "support_max": 24, "embedding_calls": 1, "embedding_input": "singleton:query.replace(newline,space)",
        "lazy_open": "denied", "mutation": "denied", "other_result_scopes": "empty",
        "score_projection": "ieee754-be-f64-v1", "native_order": "unchanged"}


def search_input(job: Job) -> dict:
    args = Search.model_validate(job.args)
    if (job.op != "search" or not job.scope_ref or len(args.query) > 256
            or len(args.query.encode("utf-8")) > 1024 or args.limit > 10 or job.deadline_ms > 60000):
        raise BoundaryError("scope_denied")
    return {"query": args.query, "limit": args.limit, "recipe_id": args.recipe_id, "group_id": job.scope_ref}


def _uuid(value: object) -> None:
    try:
        if type(value) is not str or str(UUID(value)) != value:
            raise ValueError("uuid")
    except (ValueError, AttributeError) as error:
        raise BoundaryError("closure_incomplete") from error


def project_results(results: object, *, group_id: str, limit: int) -> tuple[dict, dict]:
    """Return the unchanged wire scores and a closed measurement of their bits."""
    from graphiti_core.edges import EntityEdge
    from graphiti_core.search.search_config import SearchResults
    if (type(results) is not SearchResults or type(limit) is not int or not 1 <= limit <= 10
            or any(getattr(results, name) for name in ("nodes", "node_reranker_scores", "episodes",
                "episode_reranker_scores", "communities", "community_reranker_scores"))
            or len(results.edges) > limit or len(results.edge_reranker_scores) != len(results.edges)):
        raise BoundaryError("closure_incomplete")
    candidates, projections, seen = [], [], set()
    for edge, score in zip(results.edges, results.edge_reranker_scores, strict=True):
        if (type(edge) is not EntityEdge or edge.group_id != group_id or edge.uuid in seen
                or not 1 <= len(edge.episodes) <= 24 or len(set(edge.episodes)) != len(edge.episodes)
                or type(score) is not float or not math.isfinite(score)):
            raise BoundaryError("closure_incomplete")
        _uuid(edge.uuid)
        for identity in edge.episodes:
            _uuid(identity)
        seen.add(edge.uuid)
        support = list(edge.episodes)
        candidates.append({"edge_id": edge.uuid, "episode_ids": support, "score": score})
        projections.append({"edge_id": edge.uuid, "episode_ids": support,
            "score": {"format": "ieee754-be-f64-v1", "bits": struct.pack(">d", score).hex()}})
    return {"candidates": candidates}, {"candidates": projections}


async def native_search(graph: Graphiti, job: Job, pins: dict[str, StagePin], relay: ObserverRelay | None) -> dict:
    from graphiti_core.search.search_config_recipes import EDGE_HYBRID_SEARCH_RRF
    from lineage import CURRENT_LINEAGE, call
    from observations import CURRENT_SEAM, Observation, SeamFrame, intermediate_operation
    inputs = search_input(job)
    lineage = CURRENT_LINEAGE.get(None)
    if relay is None or lineage is None or lineage.job != job or "embedder" not in pins:
        raise BoundaryError("closure_incomplete")
    pin = pins["embedder"]
    async with intermediate_operation(pins, relay, read_only=True) as state:
        with call(pin.id, SEARCH_SEAM) as context:
            observation = Observation(pin, SEARCH_SEAM, context, relay, SEARCH_SCHEMA_DIGEST)
            observation.base = await observation.attest(
                [observation.entry("deterministic_output", inputs, "identity_v1")],
                seam=SEARCH_SEAM, phase="inputs", transform=SEARCH_INPUT_TRANSFORM)
            frame = SeamFrame(state, observation, SEARCH_SEAM, SEARCH_RESULT_TRANSFORM, inputs, inputs)
            token = CURRENT_SEAM.set(frame)
            try:
                recipe = copy.deepcopy(EDGE_HYBRID_SEARCH_RRF)
                recipe.limit = inputs["limit"]
                results = await graph.search_(inputs["query"], config=recipe, group_ids=[job.scope_ref])
                state.check_write_current()
                if state.search_embed_calls != 1 or state.search_embedding_proof is None:
                    raise BoundaryError("closure_incomplete")
                wire, measured = project_results(results, group_id=job.scope_ref, limit=inputs["limit"])
                for edge in results.edges:
                    known = state.current(edge)
                    if known is None:
                        raise BoundaryError("closure_incomplete")
                    frame.child(known[2])
                observation.parents = [observation.base, *frame.children]
                await observation.attest([observation.entry("deterministic_output", measured, "identity_v1")],
                    seam=SEARCH_SEAM, phase="derived", transform=SEARCH_RESULT_TRANSFORM)
                state.check_write_current()
                return wire
            except BaseException:
                state.failure = state.failure or "closure_incomplete"
                raise
            finally:
                CURRENT_SEAM.reset(token)
