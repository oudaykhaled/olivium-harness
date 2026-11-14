# Proposal 01 — explain static-only cleanup

**User/job:** An operator inspecting a static pass needs to know what ran and what remains before release review. **Hypothesis:** contextual wording prevents “cleanup incomplete” being read as failed teardown or a qualified task. **Success:** four of five blinded operators distinguish static evidence, task cleanup failure and required model-backed qualification within 60 seconds. Any false qualification inference or fewer than four correct answers falsifies the hypothesis. This study is proposed, not measured.

**Evidence:** `Readiness.cleanup_stage/1` maps non-`complete` status to blocked/incomplete ([readiness.ex:255](/Users/<user>/Desktop/AI%20Steup/harnessforge/lib/harness_forge/readiness.ex:255)); the summary prioritizes cleanup ([package_readiness.ex:210](/Users/<user>/Desktop/AI%20Steup/harnessforge/lib/harness_forge_web/components/package_readiness.ex:210)). The view knows evaluation kind/outcome and prints cleanup ([package_readiness.ex:138](/Users/<user>/Desktop/AI%20Steup/harnessforge/lib/harness_forge_web/components/package_readiness.ex:138)). Iteration03 verified static and blocked task views, but no novice study ([verification](../../03/verification.md)).

**Decision (UI only):** For an explicitly selected, valid `static_integrity` + `passed` + `not_started` report, explain beside summary and cleanup: “Static package checks passed. No model-backed task ran, so task cleanup was not attempted. A qualified task evaluation is still required for release review.” Retain `Blocked`/`Not started`, gate reasons, seven stages and action destination. Never infer this state from absent, malformed or foreign runs.

**Acceptance:**

1. Given a genuine selected static pass with `not_started`, when inspected or refreshed, then the explanation appears before the stage list; recorded statuses and refusal are unchanged.
2. Given a task with `cleanup_failed`, when inspected, then its failure warning remains prominent and no static-only explanation appears.
3. Given no selected evaluation or unknown cleanup metadata, when inspected, then the static-only explanation is absent and no reassuring cleanup claim appears.
4. Given the static state at 320 CSS px and 200% zoom, when navigated by keyboard, then the explanation precedes the stages in reading order without overflow; reset/switching clears it.

**Tradeoff:** Export recovery addresses a real failed retry, including stale alerts ([portal_live.ex:393](/Users/<user>/Desktop/AI%20Steup/harnessforge/lib/harness_forge_web/live/portal_live.ex:393)), but spans form state, flash lifecycle and filesystem-error copy. This proposal is smaller, about half a day in `package_readiness.ex` and its LiveView tests plus browser verification. It improves interpretation, not release qualification; OpenCode task applicability/admission remain **Not assessed**. Preserve auth, privacy, reset, no-overwrite and all domain gates.
