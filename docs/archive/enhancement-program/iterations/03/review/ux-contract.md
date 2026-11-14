# Exact-package readiness — UX contract

Status: ready for Author B. This is a bounded addition to Packages under the [selected decision](../decision.md), not a redesign or new release authority.

Basis: read repository AGENTS, PROGRAM, the decision and all five original iteration02 retrospectives. Inspected the actual Packages/Evaluations/Releases markup, portal selection/reset/reload/session handlers, existing focus hook and CSS in [PortalLive](../../../../../../lib/harness_forge_web/live/portal_live.ex), `assets/js/app.js` and `assets/css/app.css`. Existing Packages shows full saved digests and separate export forms; Evaluations and Releases already explain that static/smoke results do not qualify a release. This review is source inspection; no browser, service or Mix operation was performed. The UI Accessibility Audit skill informed the keyboard checklist. Native acceptance remains pending root evidence.

## Interaction and copy

- Add one **Package readiness** inspector to Packages. Keep existing build/export behavior. Explain once: “Inspect a saved package and optional evaluation. Inspection does not run an evaluation or approve a release.”
- Use visible labels **Saved package** and **Persisted evaluation (optional)**. Package options distinguish name, version and digest; show the full selected digest beside the controls/report. Never select the newest/best run automatically. The blank run option reads **No evaluation selected**; list only that digest's current-workspace runs, distinguished by kind, outcome and ID.
- **Inspect readiness** submits the exact selected pair synchronously. **Refresh readiness** repeats the same read after a report exists. Disable while submitting and use a truthful busy label. Selection alone does not inspect, start work, approve, export or probe availability.
- Changing package clears the run and report immediately; changing run clears the report immediately. Show “Selection changed. Inspect readiness to view current results.” The previous pair's badges, identity details and next action must disappear together. An empty package list says “No saved packages to inspect”; do not present an actionable empty form.
- Order the result as: exact digest/run and observed time → concise current blocker → **one primary navigation action** → seven independent stages → expandable identities and limitations. Keep the action before long provenance. Use allowlisted domain `next_action`; its click only opens the named existing panel and cannot dispatch an evaluation or approval.
- Positive release wording is exactly **Ready for release review**. Explain that actual approval rechecks admission. Never use “approved”, “company qualified”, “production ready” or an overall green qualification badge for this observation.

## Seven distinct gates

Render every stage in the frozen order; text conveys status independently of color. A passed gate cannot visually imply the remaining gates passed.

| API stage | User label | Meaning to preserve |
|---|---|---|
| `integrity` | Package integrity | Saved bytes and metadata were verified. |
| `eligibility` | Current build eligibility | Current local evidence/plan admission was rechecked. |
| `managed_runtime` | Managed runtime availability | Configuration/backend facts only; live availability was not checked. Historical success does not turn this into a live health pass. |
| `evaluation` | Selected evaluation | Exact persisted kind and outcome; distinguish pending/running, blocked, failed, cancelled and interrupted from passed. |
| `applicability` | Evaluation applicability | Selected evidence matches current exact identities. |
| `cleanup` | Evaluation cleanup | Recorded cleanup state remains distinct from task outcome. |
| `release_admission` | Release admission | Only the existing final validation gate can produce Ready for release review. |

Translate statuses consistently: **Passed**, **Blocked**, **Unavailable**, **Not assessed**. Show a short safe reason beside each non-pass. “Unavailable” is not “failed”; “Not assessed” is not “passed”. Avoid raw atom dumps as the only explanation.

## Required safe states

| Situation | Required operator understanding |
|---|---|
| No run selected | Integrity/eligibility may pass; “No evaluation selected” remains explicit. Offer evaluation selection/navigation; release is not ready. |
| Static or smoke pass | Show its actual kind and passed outcome; explain that qualified task evidence is required for release review. |
| Unsupported managed backend / missing model | Name the allowlisted fact and relevant next step. OpenCode live health remains not assessed; do not probe on render/inspection. |
| Failed/cancelled/interrupted task or incomplete cleanup | Keep outcome and cleanup separate; no readiness action that implies approval. |
| Stale identities or revoked/changed plan/evidence | Identify the safe mismatch/blocker, retain the selected exact reference, and require correction/reinspection. Old success cannot remain displayed. |
| Missing/foreign run | Same safe unavailable wording; no ownership/existence clues. |
| Different-artifact run submitted outside the filtered UI | “The selected evaluation does not match this package.” No unrelated run identities or payload. |
| Missing/tampered package, privacy refusal or unknown data | Safe blocked/unavailable result; downstream not assessed where required. No raw payload, error inspection text or optimistic fallback. |

## Identity and lifetime

Keep full artifact digest and selected evaluation ID accessible as selectable, wrapping text. Expandable **Identities** contains all retained plan bindings, current/evaluation identity metadata from the fixed allowlist and observation time; do not silently choose one binding. Explain “No retained local plan binding” without implying portable approval. **Limitations** states live availability was not checked, inspection is a local observation, and company fitness/portable authenticated approval remain unproven. Exclude source/rule/goal/task text, credentials, actor identity, configuration maps and arbitrary run fields.

Relevant reload/evaluation changes, privacy reset/purge/restore and session revocation invalidate the entire report and action. Authenticate every inspector event; a queued stale event cannot restore a cleared report. Session revocation must clear before redirect. Reinspection repeats current admission; navigation never preserves authority against later changes.

## Keyboard and presentation

Use native labeled selects, buttons and `details`/`summary`; no custom dropdown or positive tabindex. Tab order follows package → evaluation → Inspect/Refresh → next action → disclosures. Enter/Space works with native controls. Keep a visible focus indicator; after inspection retain logical control focus and announce one concise result through a polite status region. Associate validation/refusal text with the relevant form; do not announce the complete gate/identity tree repeatedly. Next-action navigation focuses the existing destination panel using its established focus behavior. Avoid focusing removed report content on selection/reset.

Reuse the portal's tokens/classes and readable Company typography/target pattern within the inspector. Prefer controls at least 44px high, wrapping action labels and digest/ID text, with no horizontal page overflow at a calibrated narrow viewport. Status text must remain legible and meet contrast requirements; color alone is insufficient. Do not claim screen-reader, zoom or WCAG conformance from source or screenshots alone.

## Root-owned native evidence checklist

- Record candidate/source hashes, local process/URL identity, synthetic record provenance, actual viewport dimensions, screenshots and DOM/event evidence; tie each report to its exact digest/run. No fabricated native qualified success.
- Inspect an eligible saved package with no run; explicitly choose a real persisted static run and inspect again. Capture all seven gates, exact IDs, truthful static pass/release block and the primary safe action.
- Switch package and run separately: capture immediate clearing, blank run on package change, then refreshed identity/status. Navigate the actual next action and record destination/focus without mutation.
- Change current plan/evidence authority and refresh; show new eligibility refusal despite historical evidence. Exercise the root's real reset signal and session revocation; capture report/action clearing. Server tests cover adversarial forged/foreign/mismatched references and queued stale events; do not substitute screenshots for those tests.
- Record keyboard traversal, select/disclosure activation, focus visibility and result announcement markup. Capture calibrated desktop and narrow action/result frames plus measured overflow; full-page downsampling alone cannot prove legibility. True 200% zoom, screen-reader output and any unexercised checks remain explicitly unverified.

Prior missing-export-parent advice and stale export alert are recorded iteration02 issues and explicitly deferred by this scope. They do not justify unrelated recovery changes here.
