# HarnessForge private Graphiti worker

This adapter uses the real pinned Graphiti 0.31.2 engine and native Jev routing.
It provides no public HTTP service and no authority or semantic-quality claim.
Elixir alone resolves immutable stages, exact-revision consent, scope, complete
transitive manifests, budgets, grants, current eligibility and publication.

The root launches an isolated nonroot/read-only image with private stdin/stdout,
no host mounts, bounded memory/CPU and network restricted to the qualified
Neo4j channel. Python model clients have only IPC httpx transports and placeholder
keys. Root's HTTP.request_raw/5 supplies actual provider credentials. All stdout
bytes are packet-4 frames, capped before body allocation. Logging/telemetry,
dotenv, ambient API keys/proxies and tracer exports are disabled before imports.

Root supplies actual uv.lock/dependencies.lock.json and a digest-qualified
PYTHON_DEPENDENCY_IMAGE containing Python 3.12, the unmodified pinned Graphiti
wheel and fully resolved dependencies. They are deliberately not invented by
an author. Root owns installation, image resolution/build, tests and launch.
Dockerfile does no networked install. The official Python base pin is recorded
in root backend-qualification/python-base-pin-01.json.

Boot carries the source-lock/backend receipt digests, ephemeral backend auth and
immutable stage pins. Root must verify all stage/config/set digests. Stage routes
are exact full endpoints, including /chat/completions or /embeddings; there is no
implicit model, endpoint, embedder, reranker or fallback. In this worker the
supplied generative/embedder stages must be OpenAI-compatible; other providers
remain available to root's generic raw synthesis gateway, not silently converted.
Jev serves only node and edge deduplication. All SDK/native retries/split/shrink
posts use fresh attempts, predecessor/ordinal and a root grant/receipt.

Graphiti uses previous episode context, candidate facts and mutable attributes/
summaries. Root must resolve context_manifest_ref/digest against immutable actual
value versions plus the conservative full-partition source ancestry before each
grant. Python observations are ephemeral and cannot approve that inventory.
Unknown ancestry must be denied; no model-generated closure is trusted. Context
exchange and search/query embedding require independent root verification.
The intermediate slice wraps native single-episode extraction/resolution,
attributes before assignment, summary flights, deterministic fact append,
temporal mutation and save entry points. It does not qualify these paths.
Ingestion and removal still reject before opening the backend. Retained native
ingestion composition is explicitly unreleased, not an alternate product entry.

A future native remove return can give cleanup_status=verification_required only. Existing
attributes may still contain removed content; root must deny rebuild dispatch
unless every surviving input version is clean. Default repair is a fresh fenced
partition from surviving originals. Root's fences/epochs survive worker restart.

The backend test requires a root-supplied isolated backend boot configuration and
scripted provider replies, and must be reported separately from model semantics.
Normal unit tests use synthetic protocol fixtures only. Missing qualified backend
or real model cannot become a PASS. No protected oracle is used by worker tests.

The default dependency image is the root-built content identity
`sha256:cb57c3221207787c737561c9d764776a3e81c641a5c63ee1bf82c8b8a9f28c05`,
from the verified official Python 3.12.16 arm64 base manifest
`sha256:b224e2fe306f9d303251ada22961635e5b52a69c0414a0050611be31c59f5f5b`.
Root's exported dependency lock binds 36 actual wheel artifacts, including the
wheel built from the verified 171-file pinned Graphiti tree; this is not an
unchecked substitute from PyPI. Startup verifies the installed Graphiti version
and thirty critical upstream module hashes against source.lock.json. The complete
wheel hash remains bound by dependencies.lock.json/image identity; that startup
check does not represent a complete independent dependency audit.

The uv source override explicitly selects
`vendor/graphiti_core-0.31.2-py3-none-any.whl`, the wheel built by root from the
verified pinned upstream source. It does not resolve Graphiti from PyPI.
Root copies that actual artifact and generates `uv.lock` using the recorded
resolved versions and wheel hashes in `dependencies.lock.json`; the adapter
author neither invents wheel hashes nor substitutes an unverified release wheel.

Elixir Worker receives a **raw binary stream Port**, without Erlang `packet: 4`:
it parses packet prefixes itself before accumulating bodies. Root passes the
already launched Port, session nonce and strict Boot DTO to Worker.start_link/1.
Do not merge runtime stderr into the framed stdout stream. Provider attempts and
publication run separately from the sole reader; every attempt crosses root's
StageAuthority and raw HTTP seam. Root persists cancel epoch/fences before
Graphiti.cancel/2; cancellation itself is a denial-only local control message.
Root must mark interrupted dispatched attempts uncertain on restart and retain
reservations. No exactly-once provider billing or successful purge is implied.

Jobs carry root-issued partition_id/lease_id and worker_session_id; they never
carry a private control token. Job and frame session must match the boot session.
Diagnostic health has null partition/lease, the worker:health/source-lock
namespace, zero corpus generations and no backend/model access. Cancel identifies
only an existing matching target after root has durably fenced it. Synthesis
continues directly through Elixir and does not create a Python job.

Stages.set_digest and Python stage_set_digest use canonical UTF-8 JSON
`{"v":1,"pins":full_pins_sorted_by_id}` with explicit nulls, no floats or Unicode
normalization. Duplicate stage IDs/names reject. Empty sets are diagnostic-only;
changed pins require a new root-bound worker session.

context_page/context_ack use the existing duplex reader and fixed internal
StageAuthority.observe_context(ctx,page). Each actual upstream context and
rendered/embed input is observed before delegation. ObservedRuntime calls the
native complete method once; final IPC observes actual serialized bytes after
native client transformations. A distinct sealed attempt context must match the
raw-body hash before either peer can emit an attempt. It references the operation
manifest and cannot substitute that manifest as proof. Denied/missing/mismatched
ACKs, unknown paths and retries without fresh attestation produce zero attempts.
Arrays remain at most 100; original windows 4096 bytes, derived values 16384,
aggregate rendered projections 49152, page 98304 and full frame 131072 bytes.
Ephemeral values are not persisted as prompts or approval authority.

The stable operation manifest is a source certificate. Its source_lock_digest is
the graph-source-set-v1 source triple-chain digest, whereas Boot.source_lock_digest
hashes Graphiti source.lock.json bytes. They are different identities. Per-call
contexts inherit source authority through the certificate and sealed direct
parent handles; the worker never walks or copies inherited ancestors.

Each context entry explicitly carries predecessor_version_ref (nullable). Each
page carries parent_contexts, at most100 unique {manifest_ref,manifest_digest}
pairs. The ordered base_context handle is separate. ACKs retain exact entry→version
refs. Root must resolve parents, verify actual values/named transforms and CAS
predecessors before sealing. These fields are claims, not capabilities.

Every physical response is sealed before SDK consumption using receipt_ref and
{attempt_id,http_status,body_bytes,body_sha256}. Root verifies durable response
commitments and computes logical projection hashes while holding actual response
bytes; raw bodies need not be persisted. Logical OpenAI output is native parsed
JSON after code-fence stripping. Jev output is native assembled entity_resolutions
or duplicate_facts/contradicted_facts; all split responses are explicit parents.
Missing receipts, including unsupported zero-question Jev outputs, deny.
Embedding output carries {embedding_vectors:[{format:"ieee754-be-f64-v1",
length:1024,sha256:...}]}, hashing the native first1024 double values in big-endian
IEEE754 representation. Graph snapshots include the same vector commitments;
root must verify them against exact receipt-backed embedding projections or a
previous immutable version. Unknown/reused vectors cannot self-certify.

Native hooks delegate once. extract_nodes/resolve_extracted_nodes are replaced
in both maintenance definitions and actual graphiti.py imported bindings.
Candidate collection is observed before deterministic or LLM resolution.
_extract_and_resolve_edges, extract_edges and _dedupe_extracted_edge preserve
full support lists and attest outputs before return. _extract_entity_attributes
attests merged output before caller assignment. _process_summary_flight attests
before/after; _extract_entity_summaries_batch checkpoints fact appends before a
flight and seals the no-LLM return before embeddings.

Synchronous _apply_temporal_invalidation requires certified exact inputs and
captures immutable before/after snapshots. ACKs drain before any later model,
embedding, save or enclosing async return. Overlapping mutations without an
acknowledged current input deny. _process_episode_data, bulk-save aliases,
guarded bulk transactions and individual Entity/Episodic node/edge saves require
an active observer operation. Root must verify native timestamp clocks, episode
supports, UUID mappings, capped attribute overlays, sentence truncation and
actual save projections. A save exception/unsupported backend return means the
mutation may already have occurred: root must retain its durable uncertainty
fence and reconcile rather than publish.

Only the known return positions of EntityNode.save, EpisodicNode.save,
EntityEdge.save and EpisodicEdge.save use native-save-completion-v1. The exact
Neo4jDriver/no-legacy-interface profile requires a real EagerResult, keys [uuid],
one real Record with exactly [uuid], and its string UUID equal to the validated
saved object's UUID. The four-field descriptor is {format,method,return_kind,
returned_uuid}, with return_kind neo4j-eager-uuid. Native add_nodes_and_edges_bulk
requires actual None and uses return_kind none/returned_uuid null. This projects
only observed completion, not persistence. _process_episode_data retains its
structured native domain projection. Unknown opaque returns still fail closed.
The descriptor occupies deterministic_output.value.result beside full before/
after values; identity_v1 identifies that named projection. The wrapper delegates
once, waits for the existing root ACK, then returns the SAME original native
object. Post-write shape/ACK failure poisons the operation and requires root
reconciliation without retry. Root's independent quiescent inventory and atomic
provenance/version/context acknowledgement remain mandatory. Schema export's
route_policy.save_completion registers the closed methods and exact profile.

One asyncio.Lock per IntermediateState excludes all qualified save=True wrappers
from before native argument capture/input certification through the final sealed
ACK and wrapper return. Sibling/nested-gather writers wait before capture; each
rechecks shared failure and task cancellation after acquisition, before native
delegation and before successful unlock. Failure or cancellation poisons the
shared operation before releasing exclusion, so queued saves cannot delegate.
_process_episode_data stays outside this non-reentrant gate. The pinned bulk
transaction invokes tx.run rather than individual .save wrappers. SAVE_ACTIVE
is only authorization: bulk transaction entry additionally requires the actual
current task to own the locked gate and its exact active bulk invocation. A
child's inherited ContextVars cannot authorize a transaction. Embedding/context
callbacks within bulk remain serviceable while the save gate is held. Root's
exclusive durable writer lease, independently measured inventory, atomic ACK
and reconciliation fencing remain separate requirements; this lock grants no
production authority. These source/tests await root image qualification.

Native search requires equal edge/score array lengths before constructing any
candidate. It preserves native order and finite floating wire scores unchanged;
no score padding, truncation or synthetic0.0 applies. Root owns the separate
domain-separated completion hash projection. This source slice changes no
dispatch release and requires a new immutable image/catalogue qualification.

Bulk/combined ingestion, triplets, communities, saga writes, direct contradiction
calls and removal/rebuild remain denied. No dispatcher releases them. Root's
independent transform/save verifier and real qualification remain required.
Observer errors poison the ephemeral operation even when native code catches
them. All existing byte/array caps still apply; unsupported large snapshots fail
instead of silently shortening edge ancestry or increasing a context limit.

The separate root-launched inventory reader is `python -I /app/inventory.py`.
It consumes one bounded packet-4 request, measures once, emits one bounded response
and exits0 without waiting for stdin EOF. Trailing request bytes remain unconsumed
and are never interpreted; they are not claimed to be rejected. Root sends exactly
one frame and accepts only one complete response followed by stdout EOF and exit0;
extra stdout, truncation, bad exit or timeout confers no authority.
Its exact ABI is independent of the worker protocol. Only `identity`, `page`
and `objects` are accepted. The immutable code selects fixed parameterized READ
queries, uses the official Neo4j driver with a READ session, and delegates actual
record deserialization to pinned Graphiti helpers before `native_value`.
Application-enforced read-only requires the accepted root/reader/Docker TCB;
database credentials are not claimed to enforce read-only privileges. Root owns
the dedicated network, write lease/quiescence, inventory revision and pinned
launch/image verification. This is direct backend measurement, not protection
against a malicious trusted reader.

The initial reader profile is `empty_custom_attributes_only`. Unknown flattened
properties or ontology labels deny before property transport through Cypher
CASE guards. Known labels are Episodic and Entity (plus the exact native derived
Entity_<group-with-hyphens-removed> label). Full lists of at most100 UUID supports
are retained, never sliced to claim completeness. A vector must be absent or
contain exactly1024 doubles, which become the existing bit-preserving commitment.
The upstream individual EntityEdge.save source_uuid/target_uuid property shape
is denied: its pinned deserializer exposes those properties as nonempty attrs.
Default add_episode bulk saves use source_node_uuid/target_node_uuid instead;
these are checked against actual relationship endpoints and are supported.

Queries return at most the requested1..10 records; UUID order is DESC with a
strict less-than cursor. A separate EXISTS query determines exhaustion even for
short pages, and count/distinct metadata detects duplicate selected IDs beyond
the row limit. Objects require the complete requested ID set. Identity reports
actual dbms.components/db.info values and foreign/unknown counts; root checks
the dedicated store before accepting an inventory and keeps it quiescent across
measurements. No database identity is supplied from echoed configuration.

Driver decoding cannot enforce the final98304-byte JSON cap before every Bolt
allocation. The fixed server guards instead bound each selected string, property
schema, label set, full support list and vector before CASE emits an explicit
map. No wildcard/raw properties map is returned. Server-side keys/labels checks
still inspect stored metadata, and a corrupt type may make the fixed query deny.
The typed projection then has a16384-byte bound and the whole response a98304-byte
bound; no partial records are published when either fails. Request frames are
capped at131072 before body allocation. The mocked tests establish control
mechanics only; actual query, persistence, oversized/foreign-store and launch
qualification are root-owned and remain separate evidence.

Root exports the closed schema catalogue offline using
`python -I /app/schema_export.py --source-lock-digest <verified-SHA256> --dependency-lock-digest <verified-SHA256>`.
The exporter reads no supplied files/configuration and emits only complete canonical
JSON, at most524288 bytes; failures emit no bytes and exit1. Installed distribution
metadata identifies actual Graphiti/Pydantic/SDK versions. Root independently
verifies digest inputs, code/image/lock tuple and exported bytes before installing
its own schema-catalogue.json; the worker cannot supply or approve that catalogue.

The graphiti-schema-catalogue-v1 first profile contains exactly7 static prompts:
text node extraction, edge extraction/timestamps, native node/edge dedupe, summary
batch and explicit static-None extract_summary. The actual pinned registry/resolver
and native OpenAIGenericClient response-format builder supply schemas unchanged;
no strict:true field is invented. The real compose_runtime model selector is
checked using inert uninitialized client shells; no SDK clients or model calls.
Dynamic attributes, message/JSON extraction, combined/batch/removal/community/saga/
eval routes remain absent. Catalogue membership itself enables no route.
extract_entity_summaries_from_episodes belongs to denied removal/rebuild or the
explicit skip_fact_appending=True path; current default text ingestion selects
extract_summaries_batch, so the former is absent from this first profile.

Each intermediate seam exports {seam,v:1} as a descriptor with actual hook stages,
not JSON Schema. Embedding calls now emit EMBEDDING_SCHEMA_DIGEST, the hash of an
explicit independent1024/ieee754-be-f64-v1 output descriptor, instead of echoing a
stage catalogue hash. No arbitrary pin-schema fallback applies to embedding.
The exact qualified SDK helper supplies model/input/encoding_format=base64 with
dimensions/user absent. Raw physical POST checks still require model/pin/token/
temperature/response_format/message equality and unchanged raw-byte binding.
These source changes require new image/export/test qualification; prior image06
results remain evidence for the earlier immutable slice only. Dispatch is unchanged.

Root's fixed receipt replay entrypoint is `python -I /app/response_proof.py`,
launched fresh in the qualified immutable image, nonroot/read-only, with no
mounts and network=none. It accepts one packet-4 request of at most524288 bytes,
emits exactly one canonical JSON reply of at most98304 bytes, and exits0. It
leaves trailing input unconsumed, never another operation. Root requires the
complete reply plus stdout EOF/exit0 and enforces the matching purpose-specific
Pipe input cap; the inventory Pipe default remains131072. Internal replay has
a30-second deadline; root owns the shorter live-operation deadline and process
cleanup. This helper exports neither execution nor provider-send authority.

The exact request keys are v=1,nonce,source_lock_digest,catalogue_digest,pin,
prompt_name,group_id,messages,embed_input,options,transcript. Pin is the complete
validated StagePin. Hashes bind the fixed sibling source.lock.json and
schema-catalogue.json files; the latter's dependency hash must match the fixed
dependencies.lock.json, and installed source/module/package versions must match.
There are no supplied file/module/callback/backend/configuration paths. The
static catalogue entry and actual registry/model/response-format must agree.
Unknown/dynamic prompts and unsupported physical profiles deny before replay.

LLM messages are the retained ORIGINAL pre-generate_response/pre-language-
mutation role/content values, roles system/user, at most100 messages and49152
canonical bytes. embed_input is null. options is exactly {max_tokens,
model_size:medium,attribute_extraction:false}; max_tokens is positive and no
greater than the pin cap. These are qualified REPLAY options, not evidence that
original unobserved kwargs had these values. Root derives generic max_tokens
from the independently admitted physical body and uses pin.max_output_tokens
for Jev, whose body has no token parameter. Fixed medium affects tracing here;
both clients receive explicit model=pin.model. Attribute extraction/custom
schemas are unsupported. Unknown behavior-affecting options cannot pass the
exact original physical request-body hash check. group_id is root's scope.

Embedding messages/options are null. embed_input is a string or singleton string
list for embedder.create; embedder.create_batch requires the exact singleton
list from the adapter's per-item loop. Original input has the same49152-byte
cap. Native OpenAIEmbedder/SDK perform base64 decoding and the1024-value slice;
the output is {embedding_vectors:[existing vector_commitment]}, never another
decoder or vector conversion algorithm.

Transcript contains1..3 ordered objects with exactly attempt_id,receipt_id,
ordinal,predecessor_attempt_id,method,endpoint,request_body_sha256,http_status,
body,body_sha256. Each UTF-8 body is at most98304 bytes, aggregate at most294912;
the whole request cap also applies after JSON escaping. Attempt/receipt IDs are
unique, ordinal starts1, and predecessors form the exact direct chain. Each
POST must match the next admitted method, full endpoint and exact serialized
body hash before the transport returns that receipt's raw status/body with
IPCTransport's content-type:application/json header. No sockets, redirects or
fallback transport exist. All receipts must be consumed exactly once; missing,
extra, reordered, mismatched or cancelled replay denies. Native retry and Jev
split/shrink/assembly remain unchanged, bounded by transcript size/deadline.

OpenAIGenericClient.generate_response and JevClient.generate_response execute
unchanged, without the whole Graphiti engine or prompt builders. The fixed SDK
completion proxy delegates to the actual AsyncOpenAI parser once, then requires
one choice, finish_reason stop, empty/absent refusal and no tool calls before
returning the SAME SDK object. This is HarnessForge proof policy stricter than
upstream, whose generic client can otherwise ignore a simultaneous refusal.

The exact reply keys are v,nonce,state,transcript_sha256,consumed_receipts,value,
value_sha256,error_code. transcript_sha256 commits to the canonical complete
ordered transcript including raw bodies; consumed_receipts contains only
{attempt_id,receipt_id}. Success returns the full bounded canonical native value
and its hash. Denial returns null value/hash and a safe error code. No receipts,
messages, provider errors, credentials or SDK summaries appear in output.
Malformed framing has null nonce/transcript hash. Root alone retains settled
SQL-bound receipt/input slots in private RAM, invokes replay, compares the full
claimed projection and rechecks current authority/call CAS during atomic sealing.
Scripted tests establish native-client correspondence mechanics only; this
source slice needs a new image and isolated qualification. The current native
single-episode dispatcher enters guarded composition for controlled qualification.
Root final publication and removal remain denied; this functionality remains
uninstalled and unqualified until the actual native job checks pass.

graphiti-stage-ceiling-v1 applies in ObservedRuntime.complete after resolving the
actual routed StagePin: omitted/None max_tokens uses that stage's configured cap;
an explicit positive integer uses min(requested,pin.max_output_tokens). Booleans,
zero, negative and other types deny. Pinned upstream edge calls can explicitly
request16384 tokens; this adapter intentionally reduces their generation budget
to the configured ceiling (at most4096), which can affect extraction quality or
truncation. No cap is raised, and no repair/fallback/retry is added. Native prompt
builders, extraction/resolution/assembly algorithms and one native delegation
remain unchanged. The exact admitted SDK body and independent replay bind the
effective value. Root's new immutable image must qualify this policy change.

Bootstrap and append source slice (qualification pending)
-------------------------------------------------------

read_observations.py wraps only the pinned legacy Neo4j read boundaries used by
native single-episode append: EpisodicNode.get_by_uuid/get_by_uuids,
EntityNode.get_by_names/get_by_uuids, and search_utils.node_similarity_search,
edge_fulltext_search/edge_similarity_search. It replaces definitions and the
actual imported aliases, preserving classmethod binding, one native delegation,
the SAME returned objects and their order. The same operation lock excludes
saves from before the actual read through root ACK and cache seed. Failure or
cancellation poisons queued readers/writers before release. An exact new intent
episode's expected NodeNotFoundError is raised without poisoning the operation.
Unregistered loaders, alternate interfaces/drivers, hydration, MMR/BFS and
community/saga paths deny. This does not release search/removal publication.

The root-only bootstrap seam is graphiti.bootstrap.v1, phase inputs, transform
root_inventory_bootstrap_v1, extraction pin/config. Its schema and prompt policy
are exported by bootstrap_schema()/bootstrap_prompt_policy(); root independently
defines and compares those exact bytes. There is no upstream response-model or
native catalogue entry for this seam. Every batch is a new one-shot logical call
with nil base/previous/raw-body, empty parents and immediate finished ACK flow.
It contains at most ten native identities plus EntityNode summary/attribute
entries, each typed Type:UUID. Root independently checks full values against the
absolute latest published versions and captured base P_N under unchanged S.
ACK entry-to-version UUID shape stays unchanged and transfers no old authority.

Pinned native node/edge loaders deliberately omit their embedding. The closed
native_loader_no_vector_v1 projection replaces only vector_commitments with {},
preserving all fields/lists exactly under the empty-custom-attributes profile.
Wire value_hash/projection_hash commit to the actual consumed view; root alone
resolves the full version hash for dependency content_hash. Separate full_refs
and loader_views retain the full V reference, actual view hash and current proof.
An unchanged view reuses that V. A changed partial view instead has deterministic
identity loader_view:Type:UUID, its OWN view predecessor (nil first), and both full
anchor and latest-view proof parents. It cannot overwrite the full reference or
mint a partial native V. Root adds the private operation ID to stored view
identity. Actual native embedding plus complete snapshot creates the next full V
with previous FULL predecessor and intermediate-view context parent. Summary and
attribute versions remain exact. No assumed vectors are carried or hydrated.
Only a certified current save permits a changed full-value database re-read;
arbitrary staging versions do not. All caches together retain at most100 entries
without eviction; existing value/frame/deadline/budget caps remain unchanged.

schema_export.route_policy.native_reads has the exact metadata returned by
native_read_policy(): format graphiti-native-read-policy-v1/v1; the closed
projection, driver/provider, absent legacy interfaces, empty-only attributes,
class_routes/function_routes lists above, bootstrap seam/schema digest, gate
before_native_read_through_root_ack_and_cache, objects_per_measurement10,
operation_cache_entries100, unknown_routes=denied, hydration=denied and
native_order=unchanged. Source lock additionally pins search/search.py,
search/search_utils.py and search/search_config_recipes.py from the verified
Graphiti0.31.2 checkout. Generated catalogue/image installation belongs to root.

The prior paragraphs describe earlier source boundaries; root has since reported
qualified first-episode publication on its prior immutable image. This changed
bootstrap source requires a NEW immutable image/catalogue/pins and a freshly
qualified base under those same pins. Prior check150 inventory is not adoptable.
No second-episode or search qualification is claimed here. Root alone executes
the Python suite and real private two-episode job, including candidate reuse,
changed summaries/vectors, preserved old bindings and final inventory/CAS.

Native read-only search source slice (qualification pending)
----------------------------------------------------------

The preceding bootstrap status is historical. Root subsequently reported its
two-episode append checks on image17; this changed search slice requires a NEW
immutable image, catalogue and matching pins. No search or company-readiness
qualification is claimed here. Removal remains denied. Root alone runs all
checks, installs generated catalogue bytes and releases publication authority.

The existing private Port now accepts prepare_runtime with exactly operation_id,
partition_id, lease_id, scope_ref and stage_set_digest. Its prepare_runtime_ack
echoes those five fields plus initialized, source_lock_digest, backend_pin_digest
and error_code; the digests come from verified Boot. initialized is true exactly
when error_code is null. A separate one-shot task awaits Runtime.open and native
Neo4jDriver._init_task under a60-second ceiling, before root captures the query's
inventory baseline. Native index creation retains delete_existing=false. No
query, options, credentials, Job registration, model grant or context authority
is created by preparation. Failure is terminal for that session. Boot still
means configured; a matching prepared session permits one search data job only,
alongside existing diagnostic health and authenticated existing-target cancel.
Search never reopens a missing graph after preparation/baseline.

Runtime's search composition delegates Graphiti.search_ once with a deep copy of
EDGE_HYBRID_SEARCH_RRF, changing only limit1..10, and group_ids=[job.scope_ref].
Original nonblank query bytes are retained (at most256 characters/1024 UTF-8
bytes). No caller vector, filter, driver, reranker, hydration, new retrieval
algorithm, score adjustment, padding or truncation is introduced. Every other
native result scope must be empty. Candidate UUIDs are unique, scores finite,
arrays exactly aligned, and each native ordered support list has1..24 unique
episode UUIDs. Ordinary Result floats/order, including negative zero, remain
unchanged. Only the observation DTO measures scores as16 lowercase hexadecimal
big-endian IEEE754 binary64 bits. Root retains sole graph-completion-v1 hashing.

search_observations.search_schema()/SEARCH_SCHEMA_DIGEST and
search_prompt_policy() reproduce root-native-search-abi-v1's decoded JSON.
The root-only graphiti.search.v1 seam uses the embedder stage/pin and that schema,
with one identity_v1 deterministic_output entry keyed by the outer logical-call
ID per phase: root_search_intent_v1 inputs are exactly query/limit/recipe_id/
group_id; native_search_rrf_v1 derived value is exactly candidates with
edge_id/episode_ids/score{format,bits}. schema_export.route_policy.native_search
records native_search_policy(); the root seam is not an upstream response-model
or native catalogue entry. Source lock additionally pins the actual reused
search/search_config.py from the same verified Graphiti checkout.

The outer read-only IntermediateState uses the existing shared lock before each
native read through root ACK/cache. Its only read routes are legacy Neo4j
edge_fulltext_search and edge_similarity_search; ingest loader routes deny in
this mode. Every save/intermediate mutation/temporal/bulk-write path denies
before argument projection or native delegation. The observed native embedder
must receive exactly [original_query.replace("\n", " ")] once; generation,
batch embedding, a second embedding or changed singleton denies before frames
or POSTs. Even empty results require the settled embedding response and finished
outer ACK. Final parents retain embedding receipts and ALL native reader proofs,
including candidates discarded by native RRF. Selected edges must match their
certified current actual native snapshots. Full-V/loader-view separation and the
100-entry/no-eviction cache,10-object measurement, frame/value/request/deadline
caps remain unchanged. Oversize/unknown/mismatch/cancellation/denied ACK returns
no successful search result. Scripted ACK unit tests prove control mechanics;
independent current-N inventory, source membership and publication remain root.
