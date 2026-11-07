---
status: proposed-for-root-acceptance
date: 2026-11-02
decision-maker: original iteration09 Astra arbiter
---

# ADR 09: Turn cross-source analysis into one reviewed harness recommendation

## Context

[PRODUCT_OUTCOME](../../PRODUCT_OUTCOME.md), received before selection, supersedes the initial isolated coverage candidates. The benefit is one connected journey: selected company history and a future goal → an explained recommendation → human correction and exact approval → company-specific target files.

Current `Models.propose/2` reads one revision (`models.ex:150–190`); `Models.Proposal` validates only that revision. `Models.infer/2` already meters multiple authorized source IDs. Evidence supports multiple citations and immutable successors, but its goal origin forbids citations (`evidence.ex:272–452`). Company and Harnesses already recheck exact decisions, snapshots and export eligibility. Reuse these boundaries. Do not introduce an analysis dashboard, autonomous planner or another package format.

Root's [availability observation](../../../../tmp/enhancement-program/09/local-model-availability.json) found zero configured model rows and a refused default Ollama connection. It did not inventory every installed program. Production must use the real configured-provider path; a controlled synthetic provider demonstrates mechanics only. No model installation, paid inference or hidden heuristic fallback is authorized.

## Decision

Deliver **one structured, goal-linked synthesis recommendation per explicit analysis request**, over **2–4 deliberately selected current captured sources and one saved goal in one project**. The portal exposes included revisions, safe source links, capture dates, exclusions/unknown coverage, interpreted findings, supporting/conflicting excerpts and uncertainty. Analysis proposes; humans edit, reject and approve; an explicitly composed and approved Company plan builds/exports it.

Use a separate finite `company_analysis` inference purpose, retaining the existing single-source proposal and chat contracts. Source documents may contain historical decisions, discussions and exceptions; capture time alone never establishes policy chronology. The prompt asks for recurring practices/failures, decision versus discussion, changes/exceptions/conflicts, and their relation to future intent. The validator proves structure and exact provenance, **not semantic truth or exhaustive analysis**. Unknowns and abstention are valid outcomes.

### Concrete domain contract

New `HarnessForge.Company.Analysis.analyze(attrs, opts \\ [])` accepts only string-keyed `project_id`, `source_refs`, `goal_id`, `goal_content_hash`. Each of 2–4 distinct refs contains exactly `source_id`, `revision_id`, `body_hash`. IDs/hashes use existing UUID/SHA-256 validators. Inputs must be current, workspace-scoped, active, and assigned through the profile/project; the goal must be assigned too. Server captures profile/project hashes, every input revision (including subsequently uncited inputs), goal hash and current model configuration fingerprint. Sort refs by source ID. Reject rather than silently truncate bodies: aggregate source bodies ≤32,768 bytes; assembled prompt ≤49,152 bytes. No caller-supplied prompt, provider, schema or workspace override.

Use `Models.start_run/infer` with one request, max output 4,096 tokens and existing timeout/budget limits. `opts` permits existing run/request IDs and timeout only; default IDs are fresh UUIDs. Require both `source_body` and new `company_context` consent categories for cloud inference because goal/project context leaves the workspace. Expose that category in existing configuration controls; do not broaden existing consent implicitly. Source/model/consent fingerprint is rechecked around dispatch and admission. No inference while holding the privacy lock or a DB transaction.

Canonical output has exactly `findings`, `recommendation`, `uncertainty`. At most six findings each have `kind`, `statement`, `citations`; kinds are the fixed strings `practice`, `failure`, `decision`, `discussion`, `exception`, `change`, `conflict`, `unknown`. Statement ≤1,000 characters. Each non-unknown finding has 1–4 exact source/revision/start/end/snippet citations; unknown findings have none and explain the missing evidence. At most 16 distinct citations overall. Validate selected membership, UTF-8 boundaries, exact snippet bytes and duplicate JSON keys; reject unknown fields, excessive nesting or output >32,768 bytes. A recommendation requires support from at least two distinct selected sources; two quotes from one source do not satisfy this.

`recommendation` is null (abstention), or exactly `{rule, workflow, check, evaluation_criterion, goal_rationale, status}`: each text is nonblank and ≤1,000 characters; status is `supported`, `uncertain` or `conflicted`. `uncertainty` is nonblank, ≤1,000 characters, and is displayed even for supported output. Findings/conflict/uncertainty are review metadata. Deterministically render only the four recommendation guidance fields into claim text, with fixed labels. Workflow/check/evaluation wording is advisory guidance; it does not create executable skills, graders or new runtime powers.

Under the existing privacy fence and transaction, revalidate the **entire** captured context, then atomically insert citations and one proposed claim plus existing bounded proposal audit. Return `{:ok, %{"status" => "proposed", "claim" => dto, "run_id" => id, "request_id" => id}}`. Abstention returns `{:ok, %{"status" => "abstained", "uncertainty" => text}}`, with no evidence writes. Malformed output, stale context and invalid selection return respectively `:invalid_company_analysis_output`, `:stale_company_analysis_context`, `:invalid_company_analysis_input`; unassigned context returns `:company_analysis_out_of_scope`; oversize input returns `:company_analysis_input_too_large`. Existing model/consent/budget errors propagate. No raw provider text or exception inspection in errors. Model ledger/reservation/audit writes may exist after dispatched failures; “zero writes” below means no citation/claim/decision/plan/package writes, not erased billing history.

### Durable authority and edits

Extend the existing JSON `Claim.basis` with a distinct `{"kind":"company_analysis","version":1,...}` variant; no table/migration is needed. It contains project ID, goal ID/hash, sorted complete context manifest and digest, bounded validated report, actual provider/model/config fingerprint and run/request IDs, plus `review_resolution` (initially null). Store no prompts, full source bodies, credentials or endpoint secrets. The new claim hash binds text, canonical citations and the **entire** basis; retain existing source-only and goal-v1 hash algorithms byte-for-byte.

`Analysis.revise(claim_id, expected_revision_hash, attrs)` accepts only the four editable guidance fields and optional `review_resolution` (≤1,000 characters). Reuse `Evidence.create_claim` supersession; preserve context, citations and original model findings, and create an unapproved successor. Enforce that origin continuity in the domain, including generic claim callers: no conversion to another origin, editing citation identities or concealed clearing of disagreement. For uncertain/conflicted output, approval requires a nonblank human resolution saved in the successor; otherwise return `:analysis_resolution_required`. Rejection remains available under existing eligibility rules. A resolution is a recorded human judgment, not automated proof of correctness.

Extend `Evidence.validate_claim` for this origin, including all influencing revisions and goal/context hashes. Company must verify the same project, selected goal, and **all context sources** against its scope; union context revisions with citation revisions when pinning source snapshots. Harnesses must recognize the mixed cited/goal origin in `matching_origin?`, require a Company binding, and continue its before-publication/export rechecks. Source purge dependency discovery must include uncited manifest revisions and remove affected claim families/plan artifacts through existing purge machinery. Reuse a single origin-reference helper across these consumers to avoid inconsistent dependency rules.

The existing harness schema already carries both `goal_id` and evidence. Export approved guidance through that schema and existing target adapters; the claim revision hash binds the full analysis origin. Local provenance does not authenticate portable recipient authority. Do not add raw analysis reports or source bodies to target files. Previously approved legacy plans/packages keep their hashes and existing eligibility; no universal goal-coverage or retroactive approval policy is introduced.

## Portal and acceptance

Place the action in the existing Company journey, with explicit project/source/goal selection and a focused analysis review component. Preserve current event-generation/reset protections, bounded forms and safe escaping. Reopen persisted proposals with their original metadata; edits create successors. Show current availability/refusal, busy/completed state and actionable fixed errors. A repeated submit with the same request identity must not redispatch inference; no automatic retry. Reset/tab departure clears unsaved draft state and ignores late results, while committed records remain discoverable through normal reload. Review decisions and plan selection remain explicit; no automatic claim/goal/plan approval or selection.

1. **Positive:** a labelled synthetic corpus has policy, an incident history with two recurring failures, and a later decision containing an exception and abandoned discussion; a saved goal specifies future acceptance. The controlled provider yields cited findings, visible uncertainty and one recommendation. Through the actual authenticated portal, edit its guidance, save a successor, approve that exact revision, compose/approve a plan, build and export to a fresh directory. Verify edited guidance, goal ID and evidence in manifest/spec and `AGENTS.md` (or selected target equivalent); pre-edit wording is absent. Reopen preserves reviewed metadata. Repeat a build from identical approved inputs: identical digest/files, without claiming deterministic model output.
2. **Negative:** reject a separate synthetic proposal; it never enters exported rules. Forged UTF-8 span, unselected/foreign source, missing consent, invalid goal, malformed output, model unavailability or budget refusal creates no exportable proposal. Injected source instructions grant no action/approval. Discussion/decision and conflict classifications in the fixture must match the explicit corpus oracle; this is not a general semantic guarantee.
3. **Edges/recovery:** change/revoke an examined but uncited source during inference: no proposal admission. Change it after approval: new build/export refuses. Purge it: affected provenance/artifacts are removed, unrelated material remains. A goal/context change, stale edit hash, duplicate request, superseded claim and unresolved conflict have controlled refusals. Recover with fresh explicit analysis/review; never silently refresh old authority. Current missing-model state remains visibly unavailable on the normal application.

Root joins native portal observations to actual decision/claim counts, exact hashes, exported file bytes and negative-side-effect oracles. Synthetic provider routing must be explicitly labelled and confined to the disposable QA environment, with no shipped fallback or fake production availability. Root alone executes tests/browser/runtime. Full canonical tests plus focused Models/Profile, Evidence/Decisions, Company/Harnesses, privacy/purge, compiler/export and portal suites; preserve existing MCP and package-recovery regressions. Independent code and QA review assess the connected result, not screenshots alone.

## Disposition of every original final proposal

All sixteen final originals were fully read after canonical product steering; hashes are in the read receipt. No votes were counted.

| Proposal | Disposition and evidence-based reason |
|---|---|
| 01 outcomes | Adopt connected user outcome; narrow multiple rows/new goals to one recommendation and one existing explicit goal. |
| 02 atomicity | Adopt final whole-context recheck and atomic admission; no new receipt table/migration. Ledger failures are not “zero DB writes.” |
| 03 creation contract | Adopt pre-insert provenance validation and successor edits; reject creation-time milestone coverage as unrelated. |
| 04 legacy | Adopt separate purpose/schema and legacy eligibility preservation; extend mixed origin deliberately rather than pretend existing goal-only basis suffices. |
| 05 obligations | Select one goal-linked recommendation as the smallest substantive unit; no inferred mandatory-obligation completeness. |
| 06 coherence | Adopt explicit discussion/conflict/unknown findings; restrict three cards to one synthesis and explicit resolution. No semantic contradiction engine. |
| 07 trust | Adopt all-source authorization, visible uncertainty and no fallback. Independent MCP client revocation remains deferred, substantive dissent. |
| 08 contracts | Adopt bounded citations and actual export oracle; defer six recommendations and four executable output kinds. All guidance uses existing reviewed rule representation. |
| 09 connectors | Adopt selected captured corpus with visible scope/freshness; defer connector expansion/live authentication qualification. |
| 10 composition | Adopt deterministic approved-input export and separate metadata; model response itself remains nondeterministic. |
| 11 reproducibility | Adopt persisted exact review and model identity; use existing immutable claim rather than new analysis table. Entire influencing context invalidates the recommendation. |
| 12 privacy | Adopt transactional recheck and withdrawal through export; explicitly add uncited-context purge dependencies. |
| 13 discovery | Adopt Company entry point and explicit review-to-plan continuation; no automatic corpus selection or detached brief. |
| 14 browser | Adopt settled native journey plus domain/file oracle; use root's existing supported browser tooling, no prescribed dependency upgrade. |
| 15 minimality | Adopt durable all-input manifest, including uncited context, as essential correctness; embed in versioned claim origin. |
| 16 adversarial | Adopt model-assisted proposal with human authority; manual synthesis stays available but cannot be presented as automated analysis. |

## Consequences, alternatives and ownership

Citation-only multi-source extraction is cheaper, but loses uncited influencing-source freshness and exact goal linkage. A separate analysis aggregate offers richer multi-recommendation lifecycle, but adds persistence/purge/schema work unnecessary for one recommendation. Keyword/manual synthesis avoids model dependence but does not meet the requested assisted analysis benefit. Selected-goal admission before approval preserves drafts; admission before INSERT gives a stronger draft invariant at authoring cost. Both remain deferred alongside mandatory-obligation/coherence work, independently revocable MCP clients and portable authority. Outcome evidence remains more important than additional validation counts.

Three distinct product authors **total across all corrections, including root**: (A) Principal Elixir owns new Analysis/schema/origin helpers, Models/Profile and their tests; (B) portal specialist owns analysis component, Company/Portal presentation and tests; (C) root owns Evidence/Decisions/Company/Harnesses/purge integration, shared config/router/application/migrations if unexpectedly necessary, and integration fixtures/tests. No other reviewer edits product files. Sequence reviewable units: profile/schema; immutable origin/eligibility; portal review; composition/purge integration; end-to-end verification, aiming ≤400 net lines per unit rather than concealing aggregate scope. Estimate 4–6 person-days, medium/high uncertainty around origin propagation and UI recovery. No new dependency by default.

Blast radius includes inference purpose, claim origin/eligibility, purge dependency discovery and Company UI, not just an analysis button. Keep new-origin handling explicit; unknown kinds fail closed. Rollback must retain ability to read/withdraw newly stored origins: revert the entry point first, not the validators, or stop safely with the preserved workspace backup. No destructive downgrade or rewriting immutable history.

Unproven claims remain real-company/model outcomes, complete/coherent obligations, authenticated connectors, managed Codex/Claude, portable authority, fresh08 MCP SDK/Linux, novice/longitudinal use, full WCAG/speech and operating-log confidentiality. Prior08 accounting remains 569 canonical =554 fresh passes+15 Docker skips; historical Docker15,49 focus repeats,22 synthetic JS are separate; dev Dialyzer has two baseline findings, wrong-testenv nine is a failed attempt. These are inherited facts, not09 results.

**Falsifier:** any approved/exported recommendation loses an influencing revision/goal, bypasses explicit review, retains rejected/pre-edit instruction text, or cannot complete the actual portal-to-export fixture journey. The iteration is not implemented, verified or counted by this ADR; root acceptance and subsequent work remain required.
