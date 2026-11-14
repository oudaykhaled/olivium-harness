# ADR — Iteration 02: guide the existing Company workflow

**Status:** frozen Astra recommendation accepted by root; guardrail brief and interface contract precede author edits.
**Decision maker:** `gpt-6-astra`, `i02_astra_decision`. Runtime: Elixir 1.19.5 / OTP 28, Phoenix 1.8.16, LiveView 1.2.13; no dependency changes.

## Context and evidence

Read [PROGRAM](../../PROGRAM.md), [handoff](../01/handoff-to-02.md), all five original [product](../01/retro/01-product.md), [UX](../01/retro/02-ux.md), [architecture](../01/retro/03-architecture.md), [trust](../01/retro/04-trust.md), and [quality](../01/retro/05-quality.md) retrospectives, and all 16 proposals below. All 16 READY messages received; conductor recorded actual concurrent Sol participation without reactivation in `tmp/enhancement-program/02/planning-concurrency.json`.

`portal_live.ex:980–991` counts claims under a broad decision label and unconditionally completes source connection. `company_panel.ex:543–571` renders seven sections together. `company.ex:139` checks exact approval/current context; `plan_dto/1` supplies decision status, not eligibility. `company_panel.ex:143` preserves plan drafts, but catalogue forms lack equivalent change-state handling. These concrete defects outweigh proposal popularity. Recorded browser evidence is synthetic; no newcomer study exists.

## Decision and bounded scope

Deliver **one Company workflow guide** above progressively disclosed existing sections. Suppress the global metrics/banner on Company; replace them there with saved-prerequisite summaries, separate “Claims to review” and “Plans to review” counts, and one primary navigation action. Keep direct access to all seven sections.

The guide follows saved profile → repository → project/repository membership → captured, assigned source/current approved claim → proposed plan review → approved-plan build → existing Packages handoff. Goals/milestones remain optional future intent. Draft text, configured accounts and expanded sections never count as saved completion. Scope evidence to the selected saved project (or sole project); multiple projects/plans without a selection require choosing one, not guessing. Retain selected exact plan identity and its independent lifecycle when revisiting setup.

Count actionable proposed, non-superseded claims and plans separately from already loaded records; label counts workspace-wide. A loader failure shows unavailable, never zero/completed. Pass parent claim count/loading status into Company; reuse Company’s plan list, avoiding a duplicate parent plan query.

For the selected approved plan only, invoke existing `Company.build_inputs/1` on selection/saved-data reload, outside rendering. Success permits a build invitation; failure shows a bounded reason and current-context review/re-proposal action. Unknown status never means buildable. Proposed-plan staleness remains checked by existing approval admission; surface its refusal without changing the stored decision. Recheck authority on actual approval/build/export. An eligible approved predecessor remains buildable despite a proposed successor.

Keep forms mounted during disclosure. Preserve session drafts for profile, repository, project and plan across section changes, tab trips, parent refresh and failed submission. Capture catalogue changes using existing bounded string-key validation; retain revision hashes and browser `_unused_*` handling. Successful save resets only its form. Explicit New/discard may reset; changing edited records must not silently lose dirty input. No browser storage or cross-session persistence guarantee.

Use semantic disclosure controls, visible expanded state, stable destinations and focus after destination rendering. A next-action click opens/focuses the named control; closing a focused section returns focus to its toggle. Rejected submissions open the affected section and focus a form-level error summary. Map existing reliable reasons; do not invent field diagnoses from generic invalid input. Never steal focus on routine typing.

## Alternatives and consequences

Counts-only repair is cheaper but leaves navigation burden. A hard sequential wizard reduces visible content but complicates revisits, drafts and parallel plan versions. The selected guide reuses the mounted component and admission APIs, trading modest presentation/draft state for direct task navigation. One selected-plan preflight adds bounded read work and can race later edits; server admission remains mandatory.

No domain/schema/API/MCP changes, full six-state qualification dashboard, automatic imports/decisions, goal-policy/conflict work, new package comparison flow or targeted export routing. Existing package digest and export/evaluation/release destinations remain; built bytes never imply integrity checked, current eligibility, runtime availability or task qualification. Missing models/connectors remain unavailable. No hosted documentation, credential display, private imports, paid calls, remote writes or host generated-code execution. Preserve privacy, quarantine and immutable package identity.

## Proposal dispositions

| Proposal | Evidence-based disposition |
| --- | --- |
| [01 onboarding](planning/01-onboarding.md) | Adopt guide; correct blanket successor/ineligibility inference. |
| [02 progress](planning/02-progress.md) | Adopt persisted/scoped progress; defer full package-state dashboard; preserve eligible ancestors. |
| [03 counts](planning/03-decision-counts.md) | Adopt separate actionable counts/unavailable; reject duplicate parent plan load. |
| [04 disclosure](planning/04-disclosure.md) | Adopt seven reachable sections and visible saved summaries. |
| [05 keyboard](planning/05-keyboard.md) | Adopt focus/recovery evidence; axe alone proves no conformance. |
| [06 responsive](planning/06-responsive.md) | Adopt narrow/zoom checks; defer unmeasured field performance targets. |
| [07 drafts](planning/07-drafts.md) | Adopt mounted forms and bounded catalogue drafts; no persistent draft storage. |
| [08 errors](planning/08-errors.md) | Adopt form recovery/known reasons; defer broad field-validation redesign. |
| [09 trust](planning/09-trust.md) | Adopt truthful labels; defer six-fact dashboard expansion. |
| [10 lifecycle](planning/10-lifecycle.md) | Adopt selected preflight, immutable decisions and eligible ancestor case. |
| [11 authority](planning/11-authority.md) | Adopt scoped prerequisites and separate exact review; no summary approval. |
| [12 handoff](planning/12-package-handoff.md) | Retain digest/existing handoff; defer targeted export/comparison redesign. |
| [13 MCP](planning/13-mcp-discovery.md) | Accept deferral; enabled does not establish credential usability. |
| [14 acceptance](planning/14-acceptance.md) | Adopt state matrix and native evidence; no invented SLO. |
| [15 language](planning/15-language.md) | Adopt concrete action labels and optional-intent wording. |
| [16 architecture](planning/16-architecture.md) | Adopt pure projection/no per-plan probes; selected preflight resolves stale guidance. |

## Confirmation and ownership

Acceptance: empty shows no completion and focuses profile; partial counts saved/scoped prerequisites only; proposed shows separate queues/exact review; rejected offers new proposal without retrying immutable decision; approved/current invites build; stale approved shows reason/recovery and cannot build. Also cover approved predecessor plus proposed successor, out-of-scope claims, loader failure, malformed/stale-hash submissions and revoked operator sessions.

LiveView tests must prove draft/checkbox/milestone retention and negative admission. Native Chrome must record empty/partial/proposed/rejected/approved/stale journeys, keyboard focus/Tab/Enter/Space, failed-submit recovery, comparable desktop and 390px screenshots, 320px overflow and 200% zoom checks. Report browser/version/viewport/actions/failures; no novice-study or accessibility-certification claim.

Maximum three authors: A owns `company_panel.ex` and new `company/guide.ex`; B owns `company/catalog.ex`, `company/plan.ex`, `assets/css/app.css`; C owns `portal_live.ex` and focused `company_builder_test.exs` additions. Freeze assigns/events before parallel edits; each owns its tests, with C integrating regression assertions. Root alone owns board/state/shared infrastructure. Split reviewable units near 400 net lines where practical; blast radius is Company presentation plus its portal wiring. Rollback reverts these UI changes without data migration.

Conductor serializes Mix. Require canonical tests, format/compiler/Credo gates and independent UI/behavior review; baseline is 403 registered, 388 passed, zero failed, 15 existing Docker skips and two existing Dialyzer diagnostics. No implementation or acceptance claimed here. Preserve functional-priority disagreement for iteration 03: goal policy/conflicts versus isolated qualification/readiness versus portable approval.
