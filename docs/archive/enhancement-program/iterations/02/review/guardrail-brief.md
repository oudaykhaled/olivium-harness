# Iteration 02 guardrail brief

Owner: `/root/enhancement_conductor/i02_guardrail`, principal-security-auditor capability: access control and data integrity. Product source read only. Root acceptance of the frozen [decision](../decision.md), and root's explicit cache-reset/fixed-focus-hook clarifications, were supplied by the conductor. The decision's older “awaiting acceptance” text does not introduce another approval gate.

**Ready for the three bounded authors once the impediment remover freezes the matching interface.** No missing credential, domain decision or permission blocks this UI work. This brief is a pre-edit constraint review, not a passing implementation verdict. No Mix command, browser, private import, remote write or generated-code execution was performed.

## Evidence and narrow threat model

Read `AGENTS.md`, [PROGRAM](../../../PROGRAM.md), the frozen decision, [prior handoff](../../01/handoff-to-02.md), prior implementation handoff, Company/Portal/catalogue/plan code, and privacy/session/admission code. Applied the local Security Review Checklist to authorization and information disclosure; no Olivium infrastructure is required.

The flow is authenticated operator → bounded component events → existing Company/Harnesses APIs → workspace-scoped records and immutable package. Form text, catalogue descriptions, milestones and guide state are untrusted data. An exact stored decision and fresh domain admission remain the authority boundary.

| Threat | Existing control and required UI treatment |
| --- | --- |
| Forged/stale decision or build request | `Company.decide_plan/2` checks exact revision, one immutable decision and current approval eligibility; `Harnesses.build_plan/2` checks exact hash and repeats current inputs under the purge fence. Retain both entry points unchanged. |
| Misleading current eligibility | `Company.build_inputs/1` resolves exact approved claims, latest active sources/connections, explicit membership and pinned catalogue snapshot. Cached status is guidance only. |
| Retained private data after erasure/revocation | Company is already mounted with `hidden`, while `update/2` preserves private child assigns. Portal's current `privacy_result/2` resets chat only. Workspace purge retains workspace ID/session. Explicit Company invalidation is therefore required. |
| Untrusted focus target or draft transport | Retain strict string-keyed event shapes and browser `_unused_*` normalization; focus only compiled fixed destination IDs. Never interpret input as selector, HTML, script, atom or module. |

## Binding author constraints

1. **Exact authority.** A guide action opens/focuses existing review/build controls; it never submits approval, chooses a decision or creates a plan automatically. Preserve displayed plan ID/hash and server-derived actor. Rejected decisions remain immutable; recovery proposes a new version. A proposed successor does not revoke an otherwise eligible approved predecessor (`Company.build_inputs/1` does not reject that ancestor).

2. **One selected preflight, outside render.** On exact plan selection and saved-data reload, call existing `Company.build_inputs/1` only for the selected approved plan. Store a bounded state/reason keyed to that ID and revision, not the returned claims/snapshot payload. Reset the previous result before checking. No selection, non-approved status, changed/reset context or loader/preflight failure is buildable. Render/guide projection must remain pure; do not probe all plans. Recheck through existing domain approval/build/export APIs on the actual action, including forged targeted events. A success may race a later edit and cannot authorize future use.

3. **Saved, scoped prerequisites.** Use saved selected project, or the sole saved project; ambiguous project/plan choice requires selection. Setup edits must not silently substitute a different selected plan. Eligible evidence requires nonempty captured current revision, active source/connection, explicit company/project assignment, and exact approved non-superseded claims whose every citation belongs to those assigned current revisions. Reuse parent `approved` admission data and source DTOs (`latest_revision` is absent for unavailable sources); account configuration or source IDs alone establish no eligibility. Preserve domain refusals for stale proposed-plan approval. Goals/milestones are optional future intent.

4. **Truthful counts and failures.** Parent supplies actionable proposed, non-superseded claim count and loader status; Company reuses its own plans for the separate plan count. Label both workspace-wide. Relevant unavailable loaders show unavailable and suppress completion/build invitation, never zero or a retained successful preflight. No duplicate parent plan query. Built bytes, digest, integrity, current eligibility, runtime availability, evaluation and release remain distinct facts.

5. **Draft privacy and lifetime.** Keep Company/forms mounted during ordinary tab/disclosure trips. Normal parent refresh preserves dirty profile/repository/project/plan inputs, checkbox and milestone choices, edited record identity and its original expected hash. A failed submit preserves the attempted draft; success resets only that form. Explicit New/discard may clear; changing edited records cannot silently discard dirty data. No browser storage or cross-session draft promise.

   A server-owned reset generation must change after successful `purge_source`, `purge_workspace` and restore; backup and harmless validation failures must preserve drafts. Reset before reassignment/reload. Clear **all** child-private cache: loaded profile/repositories/projects/plans, every draft/edit/original hash, selection/preflight, built artifact/package diff, capability/consumer query/results and notices/errors. A fresh authorized reload may repopulate saved current records; it must not restore cached drafts or authority. Source purge may conservatively reset all Company cache. Notify other mounted Portal instances through the existing workspace PubSub path, so sibling tabs cannot retain the same stale cache. A privacy failure must still invalidate successful preflight when current admission becomes unavailable.

   On invalid operator authentication, clear/revoke cached child state and redirect; preserve component-targeted event authentication because LiveComponents do not inherit the parent event hook. Existing logout epoch rotation/broadcast and redirect revoke open tabs; never renew auth to preserve a draft. Restore creates a fresh quarantined directory, does not switch the running workspace, and restores no approvals; no UI path may import prior authority from it. Workspace identity alone is not a reset signal.

6. **Bounded implementation.** No domain/schema/API/MCP/config/router/dependency changes. Three disjoint authors only; root alone writes board/state/shared infrastructure and serializes Mix. Minimal focus hook may use only compiled fixed destinations, preserve other hooks, and must never steal focus on routine typing. Keep all seven sections reachable and hidden controls out of the active focus path. Error focus opens the affected section and uses bounded known reasons, without reflecting raw exceptions or inventing field diagnoses.

## Review gate and evidence

Acceptance needs isolated synthetic LiveView tests for normal-refresh/tab draft retention versus successful purge/restore full cache clearing, sibling-tab reset, revoked component events, loader failure after prior preflight success, malformed/`_unused_*`/stale-hash forms, out-of-scope evidence, stale approved plan and approved predecessor plus proposed successor. No privacy purge/restore is authorized against main, demo or native browser workspaces. Existing domain/privacy tests establish underlying quarantine semantics; new UI tests must prove its cache boundary.

Conductor owns focused/canonical tests and normal format/compiler/Credo gates. Independent native Chrome validation covers the frozen state/focus/responsive matrix without destructive privacy operations. Preserve 15 existing Docker skips, two existing release Dialyzer diagnostics and unavailable integrations in reporting. Synthetic journeys do not establish newcomer usability, accessibility certification, real-model fitness or runtime qualification. Post-build review remains pending.
