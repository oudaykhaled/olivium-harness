# Coordination Plan: Iteration 09 initial source QA

**Classification**: review
**Pattern**: composed: parallel-fan-out + handoff
**Total agents involved**: 7 (root, conductor, five new independent original reviewers)

Initial source phase is complete. All five originals were actually observed completed; conductor fully read all five original reports, including the corrected security report, and parsed their receipts. No demonstrated product-source blocker was reported. This conclusion covers the frozen source and recorded root checks; native acceptance and iteration completion remain pending. Count stays **8/50**. No reviewer or conductor ran application/tests/browser/HTTP/DB operations or edited product/tests.

## Agents involved (in order of first involvement)

Capability citations refer to the [Fleet Capability Map](/Users/<user>/.agents/skills/fleet-capability-map/SKILL.md). Task/model/fork provenance and exact output fingerprints are in `tmp/enhancement-program/09/qa-initial-coordination.json`.

| # | Agent | Role in this plan | Why this agent (cite the capability map) |
|---|---|---|---|
| 1 | `staff-agent-orchestrator` | Root and conductor | Meta-orchestration: explicit ownership, evidence and bounded handoffs |
| 2 | `principal-code-reviewer` | `qa09_code_initial` | Map: correctness, security, tests and observability review |
| 3 | `principal-security-auditor` | `qa09_security_initial`, explicit `gpt-6-astra` | Map: access control, authentication, data integrity and secret boundaries |
| 4 | `principal-qa-api-curl` | `qa09_api_initial` | Map: positive/negative API contract and side-effect oracles |
| 5 | `principal-qa-web-playwright` | `qa09_web_initial` | Map: real web behavior, stable locators and browser evidence limits |
| 6 | `Principal UI/UX Engineer` (supported runtime role) | `qa09_uiux_initial` | Actual runtime design/accessibility specialty; older map omission is already resolved in PROGRAM's conductor plan, not an invented agent |

Every reviewer was new, `fork_turns=none`; four used default models without an override. Security alone received the authorized Astra override. Exact effective model telemetry was not independently exposed by the spawn tool. Initial reports were independent of peer reports. Same five identities are retained for root's later native-packet followup.

## Phases

### Phase 1: Frozen source intake
- **Agent**: `staff-agent-orchestrator`
- **Input**: Product outcome, accepted ADR/interface, clarification01, both author handoffs, root release, source-freeze01/check binding, actual diffs and six command/log packets.
- **Activity**: Bind the packet; distinguish 205 check inputs, 1,102 physical copies and 33 changed product/doc/test files. Clarification01 adds the originating reset token to queued starts before inference.
- **Deliverable**: Compact `qa-initial-coordination.json` input/roster receipt.
- **Done when**: Actual paths/counts are recorded; native proof is explicitly pending.
- **Handoff to**: Phase 2, the five original reviewers.
- **Estimated effort**: 0.1 person-hours.

### Phase 2: Independent source reviews
- **Agent**: The five specialists above.
- **Input**: Same frozen packet, distinct review lenses and disjoint report/receipt paths.
- **Activity**: Inspect code/diffs/tests and root-recorded results; report blockers immediately. No fixes or runtime execution.
- **Deliverable**: `qa-{code,security,api,web,uiux}-initial.md` and matching JSON receipts.
- **Done when**: Actual five completions exist. Security's same-original metadata correction is completed and recorded below.
- **Handoff to**: Phase 3, conductor/root.
- **Estimated effort**: 1.5 aggregate person-hours.

### Phase 3: Source findings and native handoff
- **Agent**: `staff-agent-orchestrator`
- **Input**: Five completed originals and receipts.
- **Activity**: Fully read all reports; retain findings and limits without voting acceptance into existence. Freeze fingerprints and stop this phase.
- **Deliverable**: This bounded report and completed coordination receipt.
- **Done when**: Root has the source findings, exact same-five identities and remaining native oracles. No retrospectives are dispatched.
- **Handoff to**: Root's normal-provider/native workflow; later followup to these same five originals.
- **Estimated effort**: 0.2 person-hours.

Source review supports the coherent implementation of immutable original report versus edited guidance, exact human resolution/approval, all influencing source/goal/profile/project pins, before-egress configuration guards, data-only offline approved export, purge/restore, and independent queued-start/callback reset guards. Root's final five check records bind 205 frozen/current inputs: focused02 92/92; canonical01 602 registered, 587 passed, zero failed, 15 optional Docker skips; format-check, warning-gated compile and warning-filtered strict Credo exit zero. Focus repeats add no tests. Focused01's eight failures and four corrected input differences remain retained. Fresh guarded Docker/native results belong to a later packet, not this accounting.

| Retained finding | Disposition and owner |
|---|---|
| CR09-N1 / API09-G1: direct goal/profile/project drift and source/prompt boundary/out-of-scope matrix | No demonstrated bypass; checks exist in source, but direct analysis-specific oracle coverage is incomplete. A/root can strengthen the relevant tests within existing ownership; do not claim the missing matrix passed. |
| UX09-01: Guide discovery | P2 source-predicted friction: `lib/harness_forge_web/components/company/guide.ex:5,168` omits analysis from its task list and routes projects without approvals toward manual Evidence. Analysis is mounted and usable by source. B/root native observation should assess the entry point. |
| UX09-02: reopened source recognition | P2 source-predicted friction: `lib/harness_forge_web/components/company/analysis.ex:480,494` shows UUID/hash provenance, while human-readable titles/dates/links live in selection. No lost authority or observed usability failure is claimed. |
| QAHELPER-01/02 | Root corrected pre-start isolation and exact provider-input comparison before first execution; security reread corrected source. Only corrected helper bytes are hash-bound. Earlier weaker versions have narrative/tool-transcript history, without retained distinct original hashes. |

The security reviewer was reactivated once solely to correct that historical-hash attribution in its own report/receipt; no new reviewer or product author was created. Its final verdict is unchanged. Root subsequently reported one bootstrap seed exit zero; that report is not native acceptance. Provider/server/inference/portal/export behavior is still outside the initial source reviews.

## Effort summary

| Phase | Agent | Effort |
|---|---|---|
| 1 | Conductor | 0.1 h |
| 2 | Five specialists | 1.5 h |
| 3 | Conductor | 0.2 h |
| **Total** | | **1.8 aggregate h estimated** |

## Risks + mitigations

- **Risk**: Source passes are mistaken for a completed user outcome → **Mitigation**: Root must join actual authenticated portal edit/save/resolve/exact approval, separate rejection, deliberate plan approval/build/fresh export to counts/hashes/bytes; exclude rejected/pre-edit guidance and verify deterministic approved-input rebuild.
- **Risk**: Context/UX gaps remain hidden → **Mitigation**: Preserve the findings; exercise examined-uncited-source mutation during inference and after approval, purge/unrelated preservation, normal missing-model honesty, actual keyboard/focus and CSS 320/390 at real 100/200% zoom. Controlled synthetic mechanics never establish real-company/model semantic fitness or full accessibility.

## Escalation path

- A source or native blocker goes to root and `staff-tech-lead` with exact failing evidence and owning A/B/root files. Corrections stay within the existing three distinct product authors; reviewers never become fix authors.

## How to execute

This source phase used the authorized collaboration tools and is now stopped. Root owns every runtime action and final acceptance. Once the final native packet exists, follow up the same five canonical tasks under `/root/i09_conductor/`; their exact identities are in the receipt. Create no replacements or retrospective agents at this boundary.
