# Company-scale evidence and source reuse — incorporation

User steering received 2 November 2026 through the companion review handoff. The user requires handling corpora with hundreds of thousands or millions of files, removing manual 2–4-document selection as the primary journey, studying Jev/frontier graph retrieval and reusing existing source rather than building a new graph/RAG framework. This updates the canonical direction without changing the frozen iteration11 candidate or completing an iteration.

Root read REUSE-DECISION.md first, then the comparison, study, frontier-model research, source lock, spike summary/composition and actual offline command/stdout. Root also inspected the pinned Jev supported prompt contract, empty-group search normalization and failed removal-summary rebuild branch. All 18 source files listed in sources.lock.json matched their recorded lengths and hashes. This is scoped source/evidence review, not a new execution or a full dependency security audit.

## Adopt the existing implementation

Use Graphiti v0.31.2, commit d72407dcedac911e1be9fc15b55e8c05a3efcc36 (Apache-2.0), as the selected graph dependency for integration. Reuse its real JevClient, LLMRuntime, LLMTransport, PromptRoutes, jev_prompt_overrides, extraction, temporal episode/fact lineage and hybrid retrieval. Keep Elixir/Phoenix and the existing SQLite store authoritative for evidence, identity, review, consent/budgets, build/export and privacy. A bounded Python worker may host the dependency; do not port its graph algorithms or create another Jev HTTP engine. Retain licenses/notices and pin resolved dependencies. Select/test the graph backend separately; deprecated Kuzu is not the default. Do not stack the other surveyed frameworks beside it without measured missing capability.

Native Jev routes serve dedupe_nodes.nodes and dedupe_edges.resolve_edge only. Extraction and summaries need an explicitly supplied generative model. Static routing does not provide an evaluated confidence-based frontier escalation policy. Upstream thresholds, 120-second timeout, five retries and moving aliases are defaults, not our measured policy or budget. The study's proposed $100 model pilot is not spending authorisation.

## Concrete next planning and delivery boundary

Iteration11 finishes its current bounded correction, same-reviewer verdicts, local install, five NEW retrospectives and full handoff. Immediately feed this study and all five retrospectives into the fresh16Sol/Astra planning round for iteration12. The next UI round must make corpus/goal selection, bounded evidence and conflict inspection, progress/coverage and deliberate review usable without a whole-corpus checklist or full-source payload. It must address the company-scale journey rather than another isolated export/copy polish round. The fresh Astra selects the smallest reviewable UI slice and necessary integration seams; this steering does not bypass planning or prescribe an unreviewed schema.

The following functionality planning must deliver a corpus-to-harness vertical slice: bounded resumable capture beyond the current500-file/16MiB batch, relational membership beyond100 source arrays, metadata pagination/lazy hydration, exact-byte passages and a server-owned versioned retrieval origin. Select corpus plus future goal, retrieve supporting/conflicting evidence without manual four-document selection, review/edit/reject/approve exact recommendations, separately approve a plan, and verify corrected bytes in actual target exports plus representative assessment. Keep FTS5 as the measured baseline. Integrate the pinned Graphiti source at its bounded adapter/control seam; do not defer the scale correction behind unrelated infrastructure work. Validate on a larger public synthetic corpus first, then the authorised pilot when inputs/access exist.

## Application contracts the dependency does not supply

- Server-derived nonempty group scope; access filtering before retrieval and each provider dispatch; no model decides permissions.
- Source/revision/hash/exact UTF-8 spans, parent context, document status, effective/capture dates, supporting/conflicting/unknown evidence and coverage. Episode IDs alone are insufficient.
- Versioned origin and transitive prompt-influencing dependency manifests, including uncited inputs, summaries and newly added contrary evidence. Preserve exact claim and plan approval and deterministic exports.
- Stage-pinned provider configurations, independently consented endpoints, per-attempt budget/cancellation/usage and ambiguity records. Reconcile existing singleton settings,100-source consent caps and generic131072-byte/4096-token/60-second admission instead of merely raising limits.
- Immediate tombstone/deny-serving before dependency removal; keep derivatives blocked through a failed rebuild. Graphiti remove_episode restores the old summary on failure, so its successful return does not establish our purge promise. Extend indexes/caches/analysis/jobs/restore quarantine and test partial failure.
- Bounded jobs/checkpoints, per-file results, incomplete-scan handling, backpressure, revision/idempotency rules and observable stale/index coverage. No million-ID form or one transaction covering the corpus.

## What the study actually establishes

The separate restricted offline source-reuse spike reports51 passing upstream/composition tests, one Pydantic deprecation warning, and a retained initial missing-httpx failure corrected by explicit httpx0.28.1. It used no network, nonroot/read-only execution and no host mounts. Root reviewed its recorded command/stdout and hashes; root has not rerun that spike or installed it in HarnessForge. No real backend ingestion/search/removal or HarnessForge E2E is qualified by those51 tests.

The million logical synthetic-document probe used three million short repetitive passages and supplied edges. Its warm p95 specific38.477ms/graph78.987ms/broad977.629ms are mechanical observations with explicit limits, not million-file production or semantic-model evidence. Model bakeoffs, actual quotas, semantic edge quality, realistic concurrent ingestion and company task improvement remain unmeasured. Do not copy study prices/model claims into implementation defaults without current primary-source verification at the point of use.

Study root: /Users/<user>/Desktop/AI Steup/research/harnessforge-graph-rag-study-2026-11-02/. The immutable received document copies, hashes, direct-source inspection boundaries and incorporation receipt are under tmp/enhancement-program/11/scale-reuse-steering-01/. The canonical board and next handoff must cite this direction and distinguish research, implemented, reviewed, installed and verified work.
