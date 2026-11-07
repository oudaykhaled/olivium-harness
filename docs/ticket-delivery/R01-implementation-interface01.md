# R01 implementation interface and ownership

Root accepts decision01, addendum01 and correction01 in that precedence; independent review02 resolves the removed-membership P2. These are implementation obligations, not verified behavior. Root is the sole executor/runtime/board writer. No checks or services run by authors. Preserve other authors; maximum three concurrent product/test authors including Root.

## Store schema and service seam

Root creates migration `20261103000300_revision_use_holds.exs` with:

- `revision_use_holds`: `id` UUID primary key (public event_id), `workspace_id`, `connection_id`, `provider`, `external_id`, `source_id`, `revision_id`, `body_hash`, `command_id`, `request_digest`, `schema_version=1`, `policy_generation=1`, `denied_purposes` JSON array in fixed order `[inspection,retrieval,analysis,compile]`, `reason_code=operator_restriction`, `actor`, `inserted_at`. Workspace/revision and workspace/command unique; source lookup index; immutable updates/deletes. FK parents and an insert identity trigger enforce resolved workspace/source/revision/hash/connection/provider/external identity without a wide redundant parent index.
- `revision_use_cleanup`: `event_id` UUID primary key/FK to hold.id, `workspace_id`, `state=pending|completed`, `cursor` TEXT initially empty, `lock_version` integer initially0, `updated_at`. Workspace/event identity immutable in normal operation, checkpoint content mutable. Scope trigger validates parent workspace. Down refuses any restriction/checkpoint rows.

Service owner writes only `lib/harness_forge/evidence/revision_use_holds.ex` and `test/harness_forge/revision_use_holds_test.exs` plus its named receipt. Module `HarnessForge.Evidence.RevisionUseHolds` exports `restrict(attrs,caller)`, `status(event_id,caller)`, `resume(event_id,expected_version,caller)`; Root delegates the three approved Evidence APIs. Attributes use strict string keys/typed values from decision01; server owns identity/actor. Receipt version1 includes cleanup_version. Status/replay may privately read exact reference metadata after a hold; never hydrate body or use a public content getter to bypass denial.

Shared read-only helpers, usable inside an owning transaction/fence: `assert_use(source_id,revision_id,body_hash,purpose)`, `assert_source_unheld(source_id)`, `assert_corpus_unheld(corpus_id)`, returning `:ok | {:error,code}`. Malformed/unknown/read errors deny; absence only means no additional restriction and cannot grant underlying access. `not_held_sql(revision_alias)` supplies one centrally owned parameter-free NOT EXISTS predicate against fixed internal revision aliases; validate alias syntax, never accept client SQL. All four purposes are denied by this version. Source helper checks any hold for the existing source identity, blocking all recapture/new-body/metadata-change bypasses.

Mutators reject caller-owned transactions and use the existing privacy-before-SQL/caller-guard pattern; read helpers must not introduce nested transactions/rollback poisoning. Hold/checkpoint commit atomically. Resume effects+CAS checkpoint commit together; exact page, stale replay, future version and completed replay follow addendum01. No worker waits under locks. Correction01 preserves removed membership and requires generation fencing once per committed page.

## Disjoint integration

Root owns migration, `evidence.ex`, `evidence/corpora.ex`, Privacy inventory/Purge/Snapshot and privacy/migration tests. Core admission refuses held-source capture or membership inclusion; current corpus predicates fence cached graph scope before cleanup. Root integrates hold-aware invalidation preserving removed status and original revision.

Consumer owner owns CorpusReview/Retrieval, Passages/OriginV2/GraphManifests, Models final dispatch/publication hooks, Harnesses eligibility and MCP projection only where central guards do not already suffice; its cross-consumer integration tests are separate. Prefer existing shared currentness checks to redundant adapter policy. Exact owned files are listed in the dispatch. Root later dispatches WEB work only after an author lane is released; no fourth concurrent author.

No new positive grant/restore, storage erasure, historical eligibility or complete R01 claim. Candidate08/8889 and its sealed A04 evidence remain unchanged until a reviewed, tested immutable candidate is installed through an owned upgrade.
