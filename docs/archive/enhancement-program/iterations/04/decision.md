# ADR04 — Explain static-only readiness without implying cleanup failure

**Status:** ROOT_ACCEPTED, 2026-11-01 (acceptance communicated by conductor). Implementation and verification pending.

## Context and evidence

I read PROGRAM/conductor, all five original03 retrospectives, handoff, accepted amendment, verification, every01–16 proposal, and current component, Readiness, Evaluations, Portal export and Artifacts source. All sixteen planners reported READY and remain at the final-review barrier; the coordinator captured their actual concurrent running state. Selection uses demonstrated behavior, acceptance value, reliability and scope—not proposal counts.

The [03 UX evidence](../03/review/ux-validation.md) observed a genuine static pass whose headline said cleanup was incomplete. Current `Evaluations.execute_supported/2` performs integrity checks only for `static_integrity`, retaining `not_started`; `Readiness.cleanup_stage/1` maps it to blocked/incomplete. `PackageReadiness.announcement/1` consequently prioritizes that cleanup reason over qualified-task refusal. The operator cannot readily distinguish work never attempted from failed teardown.

Export recovery is also a real defect: `PortalLive` sends filesystem contract errors through connector advice, retains `export_path` on failure and omits flash clearing on success. It offers a concrete retry outcome, but complete recovery spans per-package input/result state, alert lifecycle and native focus. It is deferred as a separate unit, not dismissed.

Prior evidence records 438 current passes, 15 Docker skips and two baseline Dialyzer findings; these are historical inputs, not04 passes. The03 transitive Docker-probe failure and subsequent OpenCode abstention remain binding lessons.

## Decision and consequences

Deliver **one presentation-only benefit: distinguish a successful static check from a cleanup incident and identify the missing task qualification**. Reuse the stateless existing Phoenix/LiveView inspector and its validated report; add no dependency, persistence, endpoint, domain result or execution path.

Use one narrow predicate: evaluation stage has `kind=static_integrity`, `outcome=passed`, `status=passed`; cleanup has `status=blocked`, `reason_code=evaluation_cleanup_incomplete`, `cleanup_status=not_started`; release admission has `status=blocked`, `reason_code=qualified_task_evaluation_required`. No smoke, task, unknown/missing/foreign record qualifies.

For that predicate, replace the generic cleanup explanation in the cleanup row with:

> This static evaluation checked package integrity only. No model-backed task or runtime cleanup was attempted. Release review still requires a qualified model-backed task evaluation.

When cleanup is the blocker chosen by the **existing announcement priority**, use that same explanation after “Release review is blocked.” Keep earlier integrity, eligibility, unsupported-runtime and evaluation warnings in their current priority. Do not prepend an optimistic headline that overrides another blocker. Apply the same summary function to visible summary and polite announcement. Retain the cleanup **Blocked** badge, recorded **Not started**, all seven stages, release refusal, exact selected identities and unchanged next action/destination. Existing “Review evaluations” remains sufficient; no button or focus redesign.

Positive consequence: the first explanation and its underlying row tell the same truthful story without adding another panel or disclosure. Cost: blocked cleanup remains a deliberately conservative domain status; the explanation must make that distinction clear. This establishes rendered semantics and observed navigation, not measured novice comprehension or company fitness.

OpenCode current task identity/applicability/admission remain **Not assessed**. Inspection must remain command-free and must never borrow historical task identity as current authority. Actual release/export checks remain authoritative.

## All sixteen dispositions

| Proposal | Disposition and reason |
|---|---|
|01 static mental model|Accept core explanation/negative contrasts; proposed human study is not an acceptance prerequisite without participants.|
|02 export recovery|Defer: useful concrete remedy, but larger form-state and retry surface than selected observed defect.|
|03 keyboard recovery|Defer export focus work; retain native keyboard checks for selected inspector. Source concern is not an observed focus failure.|
|04 narrow layout|Defer collapsing Passed rows: adds interaction cost and changes information visibility without measured scanning benefit.|
|05 progressive disclosure|Defer hierarchy redesign: hiding evidence risks secondary-warning discoverability.|
|06 trust copy|Accept conditional historical wording and unchanged gates; avoid additional summary panels.|
|07 boundary simplicity|Accept component-only boundary, qualified-task guard and earlier-blocker precedence; no invented study gate.|
|08 alert lifecycle|Defer as part of coherent export recovery, not an isolated global flash change.|
|09 novice next action|Defer cross-Guide/Portal selection behavior; benefit remains a hypothesis and needs broader state checks.|
|10 runtime calibration|Accept corrected static-only scope and blocked-task contrast. Focused final-review clarification established smoke executes runtime checks and successful execution records complete cleanup; planner corrected its original extension.|
|11 empty states|Defer extra guidance; existing no-run/invalid refusal remains and supplies negative tests.|
|12 testable value|Accept focused LiveView contrasting cases, reset behavior and bounded native evidence.|
|13 corrective navigation|Defer button relabeling: unchanged action already reaches Evaluations; explanatory text supplies the missing purpose.|
|14 history contract|Defer identity repetition/action-reason metadata: wider domain/presentation change and duplicated precedence risk.|
|15 company job value|Accept missing-qualification framing; future novice metric stays explicitly unmeasured.|
|16 adversarial priority|Defer export despite its delivery value: source evidence is strong, but selected native-observed interpretation defect has smaller reliable acceptance surface.|

The original disagreement is preserved: product/architecture/trust favored goal-origin authority; UX favored declared-conflict admission; quality favored trusted current-runtime identity. Representative outcomes and portable authenticated approval remain independent gaps. This UI decision selects none of those next-functionality contracts and does not convert retrospective agreement into evidence.

## Exact ownership and bounded work

Two disjoint authors maximum for this unit:

- **Author A, UI implementer:** only `lib/harness_forge_web/components/package_readiness.ex`; predicate and shared contextual explanation, ideally under100 net lines.
- **Author B, regression author:** only `test/harness_forge_web/package_readiness_test.exs`; behavioral assertions and focused rendering cases, ideally under200 net lines.

No other product files are authorized by this decision. Root owns board/state/shared configuration/router/application/migrations, serialized Mix checks, native builds and browser operations. UI/UX and guardrail reviewers advise without product writes. No services or process changes by these authors; preserve existing main/MCP processes. Root freezes the final candidate before independent validation. Estimated implementation/check work: 3–5 aggregate person-hours, plus 1–2 for independent/native review; confidence moderate, not a wall-clock guarantee.

## Testable acceptance and meaningful checks

1. Use a **genuine persisted static evaluation** through actual Inspect/Refresh. Summary and cleanup row convey integrity-only, no attempted runtime cleanup and required qualified task. The seven stage maps, blockers, next action, recorded state and release refusal remain unchanged. Compare with the unchanged domain report, not an invented expected gate result.
2. Contrast task `cleanup_failed`, failed/blocked task, smoke, unknown kind/outcome/cleanup, incomplete static, no run, missing/foreign/cross-artifact references. None receives static-success explanation. Actual cleanup warning and OpenCode task abstention remain; earlier integrity/eligibility/unsupported-runtime warning priority is preserved. Test deliberately inconsistent static-looking reports conservatively.
3. Existing switch/reset/remount/revocation/stale-submit tests clear contextual copy with the report. Retain exact identity/privacy behavior and immutable package bytes. Reuse calibrated actual-event/domain command/port/profile traces; zero calls applies to measured synchronous inspector paths, excluding setup/mount, not universal application purity.
4. Root runs focused readiness suites, then canonical tests, format, warning-gated compile, CI Credo, packaging/inventory and JS checks. Dialyzer must add zero diagnostics beyond the two documented baseline findings. Record actual counts/exits and preserve failures; historical Docker evidence stays separately labeled unless freshly run.
5. **Root native cases:** genuine static Inspect/Refresh; genuine model-not-selected blocked task; no-run and switching/reset clearing; keyboard action to Evaluations with destination/next-Tab observations; measured320/390 CSS widths and actual200% zoom without overflow. Record screenshots/AX, process/source provenance and bounded before/after data hashes. Task cleanup-failure contrast may use a clearly identified inert fixture for rendering only; never label it actual cleanup execution or qualified outcome. Native reset signaling is distinct from destructive purge tests.

Reject misleading reassurance, hidden real warnings, changed gate values, new I/O or stale contextual text. Fix within the two owned files or escalate a concrete scope change. Rollback is restoring those files and rebuilding through root; no data migration. No novice study, screen-reader speech, accessibility certification, real-model qualification or complete-company reliability is claimed.
