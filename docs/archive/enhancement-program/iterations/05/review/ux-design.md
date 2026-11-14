# Iteration05 UX direction — explicit goal-origin claims

**Pre-author direction under [ADR05](../decision.md):** saved goal → proposed goal-origin claim → exact claim approval → selected and separately approved plan → build/export. Goal selection grants no authority. Reuse the existing LiveView with a small goal-rule proposal form beside the sourced proposal. This establishes a reviewable origin journey, not company fitness. ADR05 has been read, including its presentation and ownership contract.

Basis: [04 handoff](../../04/handoff-to-05.md), [goal contract proposal](../planning/02-goal-contract.md), [accessibility proposal](../planning/13-accessibility-value.md), current [Evidence](../../../../../../lib/harness_forge/evidence.ex), [Decisions](../../../../../../lib/harness_forge/decisions.ex), [Portal](../../../../../../lib/harness_forge_web/live/portal_live.ex), [Company Plan](../../../../../../lib/harness_forge_web/components/company/plan.ex), [Guide](../../../../../../lib/harness_forge_web/components/company/guide.ex), [Catalog](../../../../../../lib/harness_forge_web/components/company/catalog.ex) and [CompanyPanel](../../../../../../lib/harness_forge_web/components/company_panel.ex). Source review uses the UI Accessibility Audit skill for labels, reading order, focus and associated errors. No product edit, Mix command, runtime/browser operation or usability study was performed.

## Smallest coherent interface

Reuse the Evidence tab, existing sourced proposal, claim cards, exact decision controls, Company choices/disclosures, error region and navigation. Keep internal section/event identities stable. The sourced form remains gated on available sources as today; the separate goal form must be reachable without sources. Existing claim review, Plan and Guide copy/filtering assume citations, so the goal-origin path must be addressed consistently in those places.

Keep **Propose a sourced claim** and its source/citation submission semantics. Add the small goal-rule form alongside it. The two headings make origin an explicit choice without an origin-switch control or shared dynamic form. Both use manually authored text; never copy a goal into rule text or select a goal automatically. The saved-goal option binds its ID and expected content hash, following the existing source-snapshot selection pattern; the server constructs and validates the typed basis. Submission only proposes. Full title/owner/acceptance/hash review appears on the resulting proposed card before the separate approval action. No wizard or modal is required.

| Place | Copy / behavior |
|---|---|
| Goal proposal heading | **Propose a goal-based rule** |
| Goal proposal helper | “Choose a saved goal and write the rule separately. Saving or selecting a goal does not approve a rule.” |
| Existing source form | Retain **Source snapshot**, captured document choice, rule text and existing citation construction. |
| Saved goal choice | **Saved goal**; placeholder **Choose a saved goal**. Options show goal title and owner, with a short ID when needed to distinguish duplicates. |
| Goal rule textarea | **Rule to review**; manually authored and separate from goal text. |
| Goal-origin review | Display **Goal**, **Owner**, **Acceptance criteria** and pinned hash before approval, as described below. |
| No sources | The goal proposal stays available. General empty-state copy may say “Capture a source or save a goal to propose a claim for review.” |
| No goals | “No saved goals are available. Save a goal in Goals, then return here.” Reuse the existing tab action, labeled **Save a goal**. |
| Goal submit | **Propose goal-based rule for review**. Success: “Goal-based rule proposed. Review its saved goal and exact revision before deciding.” |

Do not present a zero-source workspace as unable to propose any claim. A failure to load goals is **Saved goals are unavailable. Reload before proposing a goal-based rule**, not “No goals.” Preserve existing source proposal behavior.

## Review the exact origin before deciding

Keep the card order: claim status and revision → claim text → origin review → existing Reject/Approve controls. Show **Sourced claim** or ADR05's **Goal-based rule** in normal readable text, rather than relying on badge color. Source-origin cards retain exact source snippets and byte offsets. Goal-origin cards show the matching saved goal title, owner and acceptance criteria, and say **“This rule is based on saved intent and has no source citation.”** Never label the goal a supporting source or fabricate evidence.

Expose the full claim revision and pinned goal ID/content hash in ordinary text or a native **Exact origin details** disclosure. Human-readable goal details may be shown as the reviewed version only when they match the pinned hash; changed/unavailable goals must not be substituted under the old identity. Show **“The saved goal is unavailable or has changed. This rule cannot be approved; review the current goal and propose a new rule revision.”** Approval eligibility remains the domain’s decision. Keep historical claim/decision identifiers visible only within the existing workspace privacy boundary.

For goal-origin cards, replace “Review the citation” with **“Review the claim and saved goal version before approving this exact revision.”** Retain **Approve revision** and **Reject**, with accessible names identifying the claim text and action. Submit the exact displayed revision as today; never grant approval on origin selection, goal save, proposal, Company assignment, plan selection or plan approval.

## Company selection and handoff

Use **4. Claim review**, **Review claims in Evidence**, and **“Only an eligible, explicitly approved exact claim revision can be selected. Company setup and plan approval cannot approve a claim.”** The guide must allow a valid approved goal-origin claim without requiring captured sources. It must still abstain when required saved records are unavailable; client-side completion is guidance, not admission.

In approved claim choices and exact plan review, include the origin beside the claim and exact revision. A goal-origin choice names its saved goal. The operator must explicitly select that same in-scope goal in the existing plan goals control; do not silently add it when selecting the claim. Label it **Selected goals · required for claims based on them; selection grants no approval**. Preserve the separate plan decision and selected-plan build controls.

For a missing plan goal, say **“Select the goal used by this approved claim before saving the plan.”** For changed/unavailable goal authority, say **“A goal used by this claim is unavailable or has changed. Review the claim and propose a new plan version.”** Use these only for known domain reasons; an unknown failure must not invent a goal diagnosis. Existing build preflight/error placement and review navigation suffice. Build/export repeat authoritative checks; a previously approved card or saved package is not current eligibility.

Map ADR05's direct-build refusal `:goal_claim_requires_plan` in Packages to **“Goal-based rules require an approved Company plan. Select the rule and its goal, then approve the exact plan before building.”** Do not send this known refusal to generic model/provider advice. This is narrow origin guidance, not export-recovery work.

## Acceptance and root native cases

1. **Goals-only success:** save a real goal, choose it in the goal-rule form, write a distinct rule, propose, inspect its title/owner/acceptance/hash, approve that exact revision, assign/select the same goal and claim, then separately approve the saved plan. Build/export to a fresh contained target carries the pinned goal and empty evidence without invented citations. Proposed/rejected claims and proposed plans cannot build.
2. **Existing source path:** Captured source still creates/reviews the captured citation and exact decision. Source-only legacy hashes, specs, provenance, manifests, digests and historical artifact bytes remain unchanged. Domain/root regression establishes byte identity; native inspection alone cannot.
3. **Wrong or stale authority:** missing/foreign/hash-mismatched goal, mixed origins, superseded claim, wrong expected revision, omitted plan goal and changed plan refuse at the relevant authoritative boundary. Web assertions check specific known messages and absence of inappropriate approval/build affordances. No foreign title/body leaks. Goal editing is not exposed today; do not report a native stale-goal edit unless a real supported action supplies it.
4. **Keyboard and layout:** root reaches each separately named proposal form, then saved goal → rule text → proposal → origin disclosure → exact decision; Company navigation still focuses its existing destination. Errors identify the relevant choice; existing Company errors receive focus with the corrective control next in logical order. Observe full affected scrolling content at 320/390 CSS widths and actual 200% zoom; long titles, claim text and hashes wrap without obscuring controls.
5. **Privacy and stale events:** root verifies lock/fresh remount and the established reset/queued-submit cases under the applicable unchanged-contract evidence rules. New saved-goal selections, rule drafts and previews join existing reset clearing. Source purge must not remove unrelated goal-origin authority, while affected plans still revalidate; workspace purge and quarantined restore must never restore claim/plan approval. Historical packages retain their original bytes and cannot supply present authority.

Domain and web authors own their assigned checks; root owns shared migration/privacy integration, board updates, serialized verification and all native operations. A minimal ownership reconciliation was sent to the conductor before product edits: `components/company/guide.ex` also needs its source-required eligibility/completion/copy projection changed for the approved goals-only journey. This is a presentation projection, not a new authority predicate; the shared Evidence validator and Company admission remain authoritative. No new dependencies, export-recovery design, conflict resolution, task-route qualification, certification, screen-reader-speech result or human-comprehension claim is part of this direction.
