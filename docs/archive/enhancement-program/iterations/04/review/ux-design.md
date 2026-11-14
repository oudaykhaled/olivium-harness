# Iteration04 UX direction — static-only explanation

**Proceed within the accepted copy-only scope.** The bounded operator benefit is understanding why a successful integrity check still needs task qualification, without mistaking unattempted cleanup for a teardown incident. Basis: [accepted decision](../decision.md), [iteration03 UX](../../03/review/ux-validation.md), current [component](../../../../../../lib/harness_forge_web/components/package_readiness.ex), Readiness, Evaluations, Portal handlers and CSS. This is source review, informed by the UI Accessibility Audit skill; no native operation or product edit occurred.

## Exact copy and placement

Use the accepted explanation verbatim:

> This static evaluation checked package integrity only. No model-backed task or runtime cleanup was attempted. Release review still requires a qualified model-backed task evaluation.

Replace only the cleanup row’s generic reason. Keep its **Blocked** badge and **Recorded cleanup: Not started** immediately below. This separates conservative gate status from recorded execution history. Keep all seven rows, their order, statuses, recorded observations and release refusal unchanged.

When cleanup is the blocker selected by the existing announcement priority, prefix the same explanation with **“Release review is blocked. ”** Use the same summary function for `readiness-summary` and the existing polite status region. Do not add an optimistic headline. Earlier integrity, eligibility, unsupported-backend and evaluation warnings retain precedence; a qualifying cleanup row may explain its own state while an earlier warning remains the summary.

## Guard the meaning

The explanation requires the complete accepted conjunction: evaluation `kind=static_integrity`, `outcome=passed`, `status=passed`; cleanup `status=blocked`, `reason_code=evaluation_cleanup_incomplete`, `cleanup_status=not_started`; release admission `status=blocked`, `reason_code=qualified_task_evaluation_required`. Match exact known fields, without inferring from a run label or treating missing metadata as success.

Retain generic/incident wording for actual task `cleanup_failed`, blocked/failed/incomplete tasks, runtime smoke, unsuccessful/incomplete static evaluations, unknown kinds/outcomes/cleanup states, and deliberately inconsistent reports. No-run, missing, foreign and cross-artifact references must retain their existing safe refusals without unrelated identity disclosure. Successful static evidence must never imply qualified task execution, current runtime health or release approval. OpenCode current task identity/applicability/admission remain **Not assessed**; historical identities cannot supply current authority.

## Reading, contrast and bounded validation

Preserve DOM and keyboard order: existing selection controls → polite result → exact pair/time → visible summary → unchanged **Review evaluations** action → seven stages → disclosures. The explanation remains before the action; the row supplies local context when reading stage details. Existing repeated summary reading is a deferred burden, not a reason to add panels, buttons, disclosures or focus behavior.

Source color calculation gives existing paragraph text `--muted` on white **4.65:1**; retain that treatment without smaller/dimmer styling. Existing 9px neutral badges calculate **3.85:1** against their fill, below the normal-text AA threshold. That predates this unit and remains a separate accessibility follow-up; source review does not certify rendered contrast or WCAG conformance.

Root should freshly verify genuine persisted static Inspect/Refresh, blocked-task/no-run contrast, earlier-blocker priority, selection/switch/lock clearing, existing keyboard destination/next Tab, 320/390 CSS widths and actual 200% zoom. Reuse iteration03 fixed-reset/queued native evidence only when exact event/JS/domain hashes remain unchanged and iteration04 server regressions pass; no new reset probe. Contextual text must disappear with the report after invalidation, privacy reset or revocation; auth, stale-event refusal and command-free/no-probe inspection remain unchanged. An inert cleanup-failure fixture proves rendering only. No novice study or screen-reader-speech claim is an acceptance prerequisite or result.
