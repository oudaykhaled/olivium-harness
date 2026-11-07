# A02-02 bounded implementation contract proposal

Decision: extend the existing pure Guide projection; assemble checked metadata server-side. Preserve ADR16’s Company authority boundary. No workflow engine, schema migration or global completion score. This proposal does not claim remote A10-01 Done, candidate16 installation, browser verification or novice success.

## Exact DTO

`Guide.readiness/1` accepts server-assembled observations and returns:

```text
{version: "company-readiness.v1", scope, observed_at,
 facts: {capture: Fact, understanding: Fact, review: Fact,
         candidate: Fact, evaluation: Fact, release: Fact},
 capabilities, omissions, blockers, next_action}
Fact = {status, reason_code, pins, references, evidence_kind}
pins = {workspace_id, project_id, project_hash, goal_id, goal_hash,
        corpus_id, semantic_generation, authorization_generation,
        run_id, run_digest, claim_id, claim_revision_hash,
        plan_id, plan_revision_hash, artifact_digest, evaluation_id}
reference = {kind, id, digest, destination_code}
next_action = null | {code, destination_code, bound_ids}
```

Unavailable pins are null, never synthesized. Fixed string keys/codes; no dynamic atoms. References contain metadata, no source bodies, arbitrary URLs or credentials. Scope uses saved identities, not drafts. `evidence_kind` distinguishes current-content, historical, diagnostic, static, protected and prospective evidence; missing classification is `unknown`.

Statuses: `not_started`, `running`, `needs_input`, `complete_for_selected_scope`, `blocked`, `cancelled`, `stale`, `unknown`. Checked absence permits not_started; unread/unavailable records require unknown. Invalidated pins override old completion. Reason codes are explicit: `not_observed`, `backing_record_unavailable`, `scope_selection_required`, `stale_generation`, `capture_verified`, `analysis_abstained`, `analysis_failed`, `exact_review_required`, `artifact_verified`, `qualification_missing`, plus allowlisted upstream reasons.

| Fact | Completion evidence / conservative fallback |
|---|---|
| capture | Current pinned scan_verified/scan_complete, no incomplete enumeration; never infer from source counts. |
| understanding | Exact observed bounded analysis outcome, without semantic-quality claims; retrieval ready/context_complete is not understanding. Missing outcome unknown; abstention needs_input; failure blocked. |
| review | Exact current selected claim/plan decisions, each separately referenced; approved count is insufficient. |
| candidate | Verified artifact and exact selected-plan binding; built never means exported. |
| evaluation | Exact selected evaluation’s kind/outcome/identity; static pass remains explicitly static. |
| release | Qualification and exact authority must be evidenced; admission observation never proves published release. Missing receipt/qualification stays unknown/blocked. |

## Assembly and ownership

`CompanyPanel.reload/1` currently loads setup/plans, source summaries and preflight, **not corpus runs or optional-source outcomes** (989–1167). Add bounded assembly after preflight and clear it on existing resets/scope changes. Reuse `Company.build_inputs/1`, `Harnesses.assessment_inputs/3`, current approved claims and `Readiness.for_artifact/2` for an exact selected artifact/evaluation; absent evaluation stays unknown. Preserve Readiness’s OpenCode live-identity abstention.

Root adds only `Retrieval.read_summary(id,digest,caller)`: existing `Corpora.guard` → `checked_run` → body-free `result` plus `pins(scope_from_run)`. Existing read_run hydrates snippets; summary must not. checked_run accepts ready/abstained retrieval only, so it cannot manufacture failed/running analysis. `CorpusReview.summary_refs/2` concerns source metadata, not capture completeness. Reject returned pins mismatching selected project/goal. Never choose latest workspace run implicitly. Without an explicit validated run reference, capture/understanding remain unknown.

Root must supply authorized selected-run/analysis-outcome and optional-source metadata at this assembly seam; their producer/handoff is absent from the inspected panel. Until real producers exist, associated AC integration remains open. No fabricated adapter or regex parsing of analysis notices. FTS remains usable when graph capability is unavailable; omitted optional scope is displayed only from explicit required/optional coverage records.

Three disjoint authors: WEB owns `lib/harness_forge_web/components/company/guide.ex`; Root owns `lib/harness_forge_web/components/company_panel.ex` and `lib/harness_forge/company/retrieval.ex`; QA owns new `test/harness_forge_web/company_readiness_test.exs` and `test/harness_forge/company/readiness_summary_test.exs`. Paths are under existing lib roots; confirm new test paths before dispatch. Each cut targets≤300 netLoC. Plan/release authority modules stay unchanged.

## Acceptance

1. Verified scoped capture plus failed/abstained analysis preserves capture and its exact pins; understanding blocks/needs input.
2. Verified built artifact without qualification/exact approvals cannot project ready/released.
3. Explicit optional failure names omitted scope while sufficient required evidence permits its existing safe action; missing classification remains unknown.
4. Generation change or unavailable record invalidates affected facts/references; old approvals cannot restore readiness.

Test pure matrices plus server read/reset/scope integration and visible labels/reference pins. Allow only existing navigation actions; absent safe bindings yield null. Root runs checks; actual WEB verification remains pending browser availability. Fixture passes do not close missing assembly or WEB evidence.

## Root integration amendment — 3 November

The producer-seam study confirmed that synthesis stores a result digest without a durable outcome and retrieval coverage cannot identify its selected capture. The implemented bounded slice therefore uses `Company.ReadinessProjection.project/1` as the shared pure contract and `Company.Readiness` as the metadata assembler. Guide receives that projection; CorpusReviewLive renders the same six facts from explicitly selected records. Its synthesis observations are labelled current-session metadata, cleared on remount/scope/reset/invalidation, and callbacks additionally bind the original operation and retrieval IDs. No durable history is inferred.

Root also owns additive `Capture.read_summary/2` and completion-scope metadata in the existing counts map. New verified scans store exact final corpus semantic/access generations plus workspace/connection IDs. Old scans without those pins remain historical/unknown. The existing corpus semantic generation also advances on indexing: the first scoped scan can become stale after indexing, and a separate explicit physical re-verification is currently required to establish a current scan. This conservative limitation is recorded and tested; it is not hidden by rebinding the old scan. No migration or source-body loading is added to summary reads.

The exact selected plan's existing preflight and assessment binding support review/candidate observations. No selected evaluation or actual release receipt producer is added, so those facts remain unknown/blocked. No optional connector declaration producer exists: AC3 remains open, and no configured/failed connector is invented as optional. `next_action` remains null; existing separately checked WEB controls remain usable. No layout redesign or release authority change is included.

Actual authorship: Root owns checked summaries, metadata assembly and LiveView/CompanyPanel integration; `a02_readiness_projection` owns the new pure module/component plus Guide render hook; `a02_readiness_qa` owns three new test files. Both workers released their files before Root's final integration/regression amendments. Initial source freeze01 and failing checks are retained; a later freeze qualifies the corrected source. Ticket stays In Progress until remaining producers, review, WEB evidence and acceptance criteria are satisfied.
