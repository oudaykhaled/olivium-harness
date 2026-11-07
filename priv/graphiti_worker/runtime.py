"""Compose the pinned Graphiti engine and official SDKs, with IPC-only models."""
from __future__ import annotations

import asyncio
import copy
import importlib.metadata
import json
import os
from datetime import datetime
from pathlib import Path
from typing import Any

# Must precede all upstream imports, including modules which call load_dotenv.
os.environ["GRAPHITI_TELEMETRY_ENABLED"] = "false"
os.environ["PYTHON_DOTENV_DISABLED"] = "1"

import httpx
from openai import AsyncOpenAI
from graphiti_core import Graphiti
from graphiti_core.cross_encoder.client import CrossEncoderClient
from graphiti_core.driver.neo4j_driver import Neo4jDriver
from graphiti_core.embedder.openai import OpenAIEmbedder, OpenAIEmbedderConfig
from graphiti_core.errors import NodeNotFoundError
from graphiti_core.llm_client import JevClient, LLMRuntime, LLMTransport, PromptRoutes, jev_prompt_overrides
from graphiti_core.llm_client.config import LLMConfig
from graphiti_core.llm_client.openai_generic_client import OpenAIGenericClient
from graphiti_core.nodes import EpisodeType, EpisodicNode
from graphiti_core.prompts.lib import resolve_response_model

from ipc_transport import IPCTransport, Relay
from lineage import CURRENT_LINEAGE
from observations import (ObserverRelay, current_observation, observed_call,
                          install_intermediate_hooks, intermediate_operation, native_value)
from protocol import Boot, BoundaryError, Ingest, Job, PrepareRuntime, StagePin, canonical, digest
from search_observations import native_search, search_input

STAGE_CEILING_POLICY = "graphiti-stage-ceiling-v1"


class DeniedReranker(CrossEncoderClient):
    async def rank(self, query: str, passages: list[str]) -> list[tuple[str, float]]:
        raise BoundaryError("stage_unavailable")


class ObservedRuntime(LLMRuntime):
    """Observe the exact context, then execute upstream's builder/routing once."""
    def __init__(self, *args: Any, observer_relay: ObserverRelay | None = None, **kwargs: Any):
        super().__init__(*args, **kwargs)
        self.observer_relay = observer_relay

    async def complete(self, prompt_name: str, context: dict[str, Any], **kwargs: Any) -> dict:
        model = self.resolve_model(prompt_name)
        pin = getattr(model.transport.client, "pin", None)
        if not isinstance(pin, StagePin):
            raise BoundaryError("closure_incomplete")
        requested = kwargs.get("max_tokens")
        if requested is not None and (type(requested) is not int or requested <= 0):
            raise BoundaryError("invalid_dto")
        kwargs["max_tokens"] = pin.max_output_tokens if requested is None else min(requested, pin.max_output_tokens)
        copied = copy.deepcopy(context)
        schema = resolve_response_model(prompt_name, kwargs.get("response_model"))
        schema_hash = digest(canonical(schema.model_json_schema() if schema is not None else {}))
        async with observed_call(pin, prompt_name, native_value(copied), self.observer_relay, schema_digest=schema_hash) as observation:
            result = await super().complete(prompt_name, copied, **kwargs)
            await observation.logical_response(result)
            return result


class MeteredGeneric(OpenAIGenericClient):
    def __init__(self, pin: StagePin, client: AsyncOpenAI):
        super().__init__(LLMConfig(api_key="ipc-placeholder", model=pin.model,
                                 base_url=str(client.base_url), max_tokens=pin.max_output_tokens),
                         client=client, max_tokens=pin.max_output_tokens)
        self.pin = pin

    async def generate_response(self, messages: list, *args: Any, **kwargs: Any) -> dict:
        name = kwargs.get("prompt_name")
        if not name:
            raise BoundaryError("invalid_dto")
        await current_observation(self.pin, name).rendered([m.model_dump() for m in messages])
        return await super().generate_response(messages, *args, **kwargs)


class MeteredJev(JevClient):
    def __init__(self, pin: StagePin, client: httpx.AsyncClient):
        super().__init__(LLMConfig(api_key="ipc-placeholder", model=pin.model,
                                 max_tokens=pin.max_output_tokens), base_url=pin.endpoint,
                         max_retries=1, timeout_seconds=pin.timeout_ms / 1000, http_client=client)
        self.pin = pin

    async def generate_response(self, messages: list, *args: Any, **kwargs: Any) -> dict:
        name = kwargs.get("prompt_name")
        if name not in {"dedupe_nodes.nodes", "dedupe_edges.resolve_edge"}:
            raise ValueError("unsupported Jev prompt")
        await current_observation(self.pin, name).rendered([m.model_dump() for m in messages])
        return await super().generate_response(messages, *args, **kwargs)


class MeteredEmbedder(OpenAIEmbedder):
    def __init__(self, pin: StagePin, client: AsyncOpenAI, observer_relay: ObserverRelay | None = None):
        super().__init__(OpenAIEmbedderConfig(embedding_model=pin.model, embedding_dim=1024,
                                           api_key="ipc-placeholder"), client=client)
        self.pin = pin
        self.observer_relay = observer_relay

    async def create(self, input_data: Any) -> list[float]:
        async with observed_call(self.pin, "embedder.create", input_data, self.observer_relay, embed=True) as observation:
            vector = await super().create(input_data)
            await observation.embedding_response([vector])
            return vector

    async def create_batch(self, input_data_list: list[str]) -> list[list[float]]:
        # Bound responses and meter every physical SDK request separately.
        if len(input_data_list) > 100:
            raise BoundaryError("response_limit")
        results: list[list[float]] = []
        for value in input_data_list:
            async with observed_call(self.pin, "embedder.create_batch", [value], self.observer_relay, embed=True) as observation:
                batch = await super().create_batch([value])
                if len(batch) != 1:
                    raise BoundaryError("provider_error")
                await observation.embedding_response(batch)
                results.extend(batch)
        return results


def compose_runtime(generation: Any, summary: Any, nodes: Any, edges: Any,
                    observer_relay: ObserverRelay | None = None) -> LLMRuntime:
    """No source port: these are upstream transports/routes/prompt builders."""
    gen = LLMTransport(generation, models=[generation.pin.model]).model(generation.pin.model, max_tokens=generation.pin.max_output_tokens)
    sums = LLMTransport(summary, models=[summary.pin.model]).model(summary.pin.model, max_tokens=summary.pin.max_output_tokens)
    node = LLMTransport(nodes, models=[nodes.pin.model]).model(nodes.pin.model, prompt_overrides=jev_prompt_overrides(), max_tokens=nodes.pin.max_output_tokens)
    edge = LLMTransport(edges, models=[edges.pin.model]).model(edges.pin.model, prompt_overrides=jev_prompt_overrides(), max_tokens=edges.pin.max_output_tokens)
    return ObservedRuntime(model=gen, observer_relay=observer_relay, routes=PromptRoutes(
        extract_nodes=PromptRoutes.ExtractNodes(extract_summary=sums, extract_summaries_batch=sums,
                                               extract_entity_summaries_from_episodes=sums),
        dedupe_nodes=PromptRoutes.DedupeNodes(nodes=node),
        dedupe_edges=PromptRoutes.DedupeEdges(resolve_edge=edge), summarize_nodes=sums,
    ))


class Runtime:
    def __init__(self, boot: Boot, relay: Relay, observer_relay: ObserverRelay | None = None,
                 *, session_id: str | None = None):
        self.boot, self.relay = boot, relay
        self.observer_relay, self.session_id = observer_relay, session_id
        self.graph: Graphiti | None = None
        self.clients: list[httpx.AsyncClient] = []
        self.semaphore = asyncio.Semaphore(1)
        self.preparation_started = False
        self.prepared: PrepareRuntime | None = None
        self.pins = {pin.stage: pin for pin in boot.stage_pins}
        if len(self.pins) != len(boot.stage_pins):
            raise BoundaryError("invalid_dto")

    def _pin(self, stage: str) -> StagePin:
        if stage not in self.pins:
            raise BoundaryError("stage_unavailable")
        return self.pins[stage]

    def _http(self, pin: StagePin) -> httpx.AsyncClient:
        client = httpx.AsyncClient(transport=IPCTransport(pin, self.relay, self.semaphore),
                                   trust_env=False, follow_redirects=False, timeout=pin.timeout_ms / 1000)
        self.clients.append(client)
        return client

    def _sdk(self, pin: StagePin, suffix: str) -> AsyncOpenAI:
        if not pin.endpoint.endswith(suffix):
            raise BoundaryError("stage_unavailable")
        return AsyncOpenAI(api_key="ipc-placeholder", base_url=pin.endpoint[:-len(suffix)] + "/",
                           http_client=self._http(pin), max_retries=0)

    async def open(self) -> None:
        self.verify_source()
        install_intermediate_hooks()
        genpin, sumpin = self._pin("extraction"), self._pin("summary")
        npin, epin, embedpin = self._pin("node_dedupe"), self._pin("edge_dedupe"), self._pin("embedder")
        generation = MeteredGeneric(genpin, self._sdk(genpin, "/chat/completions"))
        summary = MeteredGeneric(sumpin, self._sdk(sumpin, "/chat/completions"))
        nodes, edges = MeteredJev(npin, self._http(npin)), MeteredJev(epin, self._http(epin))
        embedder = MeteredEmbedder(embedpin, self._sdk(embedpin, "/embeddings"), self.observer_relay)
        driver = Neo4jDriver(self.boot.backend_uri, self.boot.backend_user,
                             self.boot.backend_password, database=self.boot.database)
        # Neo4jDriver schedules its own initialization; root owns startup and
        # only a qualified isolated backend may be supplied here.
        self.graph = Graphiti(graph_driver=driver, llm_runtime=compose_runtime(generation, summary, nodes, edges, self.observer_relay),
                              embedder=embedder, cross_encoder=DeniedReranker(), max_coroutines=1)
        if driver._init_task is not None:
            await driver._init_task

    async def prepare(self, request: PrepareRuntime) -> None:
        """One initialization attempt before root captures the search baseline."""
        if self.preparation_started or self.graph is not None:
            raise BoundaryError("reconcile_required")
        self.preparation_started = True
        if self.session_id is None or request.stage_set_digest != self.boot.stage_set_digest:
            raise BoundaryError("scope_denied")
        if self.observer_relay is None:
            raise BoundaryError("closure_incomplete")
        for stage in ("extraction", "summary", "node_dedupe", "edge_dedupe", "embedder"):
            self._pin(stage)
        await self.open()
        if self.graph is None:
            raise BoundaryError("stage_unavailable")
        self.prepared = request

    def check_prepared(self, job: Job) -> None:
        if self.preparation_started:
            expected = self.prepared
            if (expected is None or job.op != "search" or self.graph is None
                    or any(getattr(job, field) != getattr(expected, field)
                        for field in ("partition_id", "lease_id", "scope_ref", "stage_set_digest"))
                    or job.job_id != expected.operation_id or job.worker_session_id != self.session_id):
                raise BoundaryError("scope_denied")
        elif job.op == "search":
            raise BoundaryError("stage_unavailable")

    def verify_source(self) -> None:
        lock_path = Path(__file__).with_name("source.lock.json")
        lock_bytes = lock_path.read_bytes()
        if digest(lock_bytes) != self.boot.source_lock_digest:
            raise BoundaryError("stage_unavailable")
        lock = json.loads(lock_bytes)
        if importlib.metadata.version("graphiti-core") != lock["version"]:
            raise BoundaryError("stage_unavailable")
        import graphiti_core
        base = Path(graphiti_core.__file__).parent
        for relative, expected in lock["files"].items():
            if digest((base / relative).read_bytes()) != expected:
                raise BoundaryError("stage_unavailable")

    async def execute(self, job: Job) -> dict:
        if self.session_id is None or job.worker_session_id != self.session_id:
            raise BoundaryError("scope_denied")
        if job.stage_set_digest != self.boot.stage_set_digest:
            raise BoundaryError("stale_generation")
        if job.op == "health":
            if job.closure_digest != self.boot.source_lock_digest:
                raise BoundaryError("scope_denied")
            return {"version": "0.31.2", "source_lock_digest": self.boot.source_lock_digest,
                    "backend_pin_digest": self.boot.backend_pin_digest,
                    "readiness": "configured" if self.graph else "stage_unavailable"}
        if job.op == "ingest":
            self.check_prepared(job)
            return await self.ingest(job)
        if job.op == "remove":
            raise BoundaryError("purge_denied")
        if job.op != "search":
            raise BoundaryError("invalid_dto")
        self.check_prepared(job)
        search_input(job)
        for stage in ("extraction", "summary", "node_dedupe", "edge_dedupe", "embedder"):
            self._pin(stage)
        if self.graph is None:
            raise BoundaryError("stage_unavailable")
        return await native_search(self.graph, job, self.pins, self.observer_relay)

    async def ingest(self, job: Job) -> dict:
        if job.op != "ingest":
            raise BoundaryError("invalid_dto")
        self.check_prepared(job)
        if self.session_id is None or job.worker_session_id != self.session_id or not job.scope_ref:
            raise BoundaryError("scope_denied")
        if job.stage_set_digest != self.boot.stage_set_digest:
            raise BoundaryError("stale_generation")
        lineage = CURRENT_LINEAGE.get(None)
        if self.observer_relay is None or lineage is None or lineage.job != job:
            raise BoundaryError("closure_incomplete")
        for stage in ("extraction", "summary", "node_dedupe", "edge_dedupe", "embedder"):
            self._pin(stage)
        Ingest.model_validate(job.args)
        if self.graph is None:
            await self.open()
        if self.graph is None:
            raise BoundaryError("stage_unavailable")
        async with intermediate_operation(self.pins, self.observer_relay):
            return await self._native_ingest(job)

    async def _native_ingest(self, job: Job) -> dict:
        assert self.graph is not None
        args = Ingest.model_validate(job.args)
        try:
            reference = datetime.fromisoformat(args.reference_time.replace("Z", "+00:00"))
        except ValueError as error:
            raise BoundaryError("invalid_dto") from error
        if reference.tzinfo is None:
            raise BoundaryError("invalid_dto")
        previous_episodes = await EpisodicNode.get_by_uuids(self.graph.driver, args.prior_episode_ids)
        if {previous.uuid for previous in previous_episodes} != set(args.prior_episode_ids):
            raise BoundaryError("closure_incomplete")
        for previous in previous_episodes:
            if previous.group_id != job.scope_ref:
                raise BoundaryError("scope_denied")
            CURRENT_LINEAGE.get().observe("episode", previous.uuid, previous.content)
        try:
            episode = await EpisodicNode.get_by_uuid(self.graph.driver, args.episode_uuid)
            if episode.group_id != job.scope_ref or episode.content != args.body or episode.valid_at != reference:
                raise BoundaryError("reconcile_required")
        except NodeNotFoundError:
            episode = EpisodicNode(uuid=args.episode_uuid, name=args.binding_id, group_id=job.scope_ref,
                                   source=EpisodeType.text, source_description=args.revision_id,
                                   content=args.body, valid_at=reference)
            await episode.save(self.graph.driver)
        result = await self.graph.add_episode(name=args.binding_id, episode_body=args.body,
            source_description=args.revision_id, reference_time=reference, source=EpisodeType.text,
            group_id=job.scope_ref, uuid=args.episode_uuid,
            previous_episode_uuids=args.prior_episode_ids, update_communities=False)
        lineage = CURRENT_LINEAGE.get()
        for node in result.nodes:
            lineage.observe("summary", node.uuid, node.summary)
            lineage.observe("attribute", node.uuid, node.attributes)
        for edge in result.edges:
            lineage.observe("edge", edge.uuid, {"fact": edge.fact, "episodes": edge.episodes})
        return {"binding_id": args.binding_id, "episode_uuid": result.episode.uuid}

    async def close(self) -> None:
        if self.graph:
            await self.graph.close()
        for client in self.clients:
            await client.aclose()
