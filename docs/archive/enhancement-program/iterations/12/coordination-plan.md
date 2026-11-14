# Coordination Plan: Iteration 12 corpus and goal evidence inspection

**Classification**: planning
**Pattern**: composed: parallel-fan-out + map-reduce + handoff + review-loop
**Total agents involved**: 35 intended sessions across the full iteration: 20 observed through planning (root, conductor, guardrail, 16 Sol planners, new Astra); 15 implementation/advisory/validation/retrospective sessions remain root-dispatched after contract acceptance. This document does not dispatch them or count the iteration.

## Agents involved (in order of first involvement)

The capability-map reference is `/Users/<user>/.agents/skills/fleet-capability-map/SKILL.md`; its literal specialty excerpts justify the choices below. Two explicitly requested roles are newer than that map: `guardrail-agent` and `principal-ui-ux-engineer` are verified existing definitions in `/Users/<user>/.codex/agents/`, and the live roster supplies their descriptions. They are not invented agents. This standalone project uses their relevant review/accessibility expertise without importing private Olivium infrastructure.

| # | Agent | Role in this plan | Why this agent (cite the capability map) |
|---|---|---|---|
| 1 | `staff-agent-orchestrator` (existing root) | Sole board/count writer, integration author and executor | Map: capability matching, explicit artifact handoffs and coordination; root task additionally reserves all execution. |
| 2 | `staff-agent-orchestrator` (this conductor) | Fresh planning, evidence bindings and contract | Map: parallel fan-out and map-reduce with a single synthesis handoff. |
| 3 | `guardrail-agent` | Already loaded scoped guardrail brief | Map's security/technical-risk capabilities are supplemented by the existing role's “request-scoped GUARDRAIL BRIEF”; root preloaded it before product work. |
| 4 | `staff-product-owner` / Sol 01 | Operator journey/outcome original | Map: “jobs-to-be-done framing” and testable acceptance criteria. |
| 5 | `staff-documentation-writer` / Sol 02 | Novice information architecture original | Map: information architecture and separating tutorial, reference and explanation. |
| 6 | `principal-elixir-engineer` / Sol 03 | Server corpus/LiveView state original | Map: Phoenix contexts and “LiveView for stateful UIs.” |
| 7 | `principal-data-engineer` / Sol 04 | Metadata/membership/pagination original | Map: schema/query/index design and read-model trade-offs. |
| 8 | `principal-elixir-engineer` / Sol 05 | Saved-goal and stale-state original | Map: Elixir/Phoenix bounded contexts and stateful UI. |
| 9 | `principal-ml-engineer` / Sol 06 | Conflict, coverage and abstention original | Map: retrieval critique and evaluation-harness design. |
| 10 | `principal-code-reviewer` / Sol 07 | Exact provenance/approval original | Map: correctness, security, tests and performance review. |
| 11 | `principal-security-auditor` / Sol 08 | Scope/privacy/recovery original | Map: broken access control and data integrity. |
| 12 | `principal-security-auditor` / Sol 09 | Consent/budget/readiness original | Map: unrestricted resource consumption and API authorization. |
| 13 | `principal-qa-web-playwright` / Sol 10 | Accessible interaction original | Map: role/label locators, visual regression and axe integration. |
| 14 | `principal-devops-sre` / Sol 11 | Truthful progress/recovery original | Map: observability, SLOs and operational failure handling. |
| 15 | `principal-ml-engineer` / Sol 12 | Existing retrieval/Graphiti reuse original | Map: NLP/LLM retrieval and evaluation, with framework trade-offs. |
| 16 | `staff-product-owner` / Sol 13 | Corrected export/task-value original | Map: outcome metrics and acceptance criteria. |
| 17 | `principal-qa-web-playwright` / Sol 14 | Independent meaningful proof original | Map: end-to-end and regression quality bar. |
| 18 | `principal-frontend-perf-engineer` / Sol 15 | Payload/hydration original | Map: loading performance and lab-versus-field measurement. |
| 19 | `staff-tech-lead` / Sol 16 | Minimal coherent architecture original | Map: ADR/RFC, capacity and technical-risk decisions. |
| 20 | `staff-tech-lead` / NEW Astra | Select one scope with explicit rubric | Map: architecture decisions/ADRs and risk; user specifically requires a new Astra arbiter, not vote counting. |
| 21 | `staff-agent-orchestrator` / implementation | Coordinate two principals plus root | Map: ownership, handoff design and review-loop orchestration. |
| 22 | `staff-tech-lead` / impediments | Resolve scoped dependencies without taking source ownership | Map: capacity, technical-risk management and escalation decisions. |
| 23 | `principal-elixir-engineer` / A | Bounded domain APIs and owned tests | Map: Elixir, Phoenix contexts and data boundaries. |
| 24 | `principal-elixir-engineer` / B | Stateless HEEx presentation and owned tests | Map: Phoenix/LiveView; root retains event/state ownership. |
| 25 | `principal-ui-ux-engineer` / adviser | Expert UI/accessibility advice, report only | Existing role: “accessibility auditing” and Web UI implementation; map's frontend/Playwright skills complement it. |
| 26 | `principal-code-reviewer` / independent QA 1 | Required code-review loop | Map: correctness/security/performance/tests quality bar. |
| 27 | `principal-security-auditor` / independent QA 2 | Scope/privacy/authority validation | Map: access control and API/data integrity. |
| 28 | `principal-qa-web-playwright` / independent QA 3 | Authenticated UI and regression review | Map: fixtures, stable locators, reflow/focus and visual evidence. |
| 29 | `principal-qa-api-curl` / independent QA 4 | Bounded API/refusal evidence review | Map: curl/jq smoke and HTTP/API contract tests; root executes all requests. |
| 30 | `principal-ui-ux-engineer` / independent QA 5 | Separate interaction/visual assessment | Existing role: UI fidelity/accessibility; separate from adviser and authors. |
| 31 | `staff-product-owner` / NEW retro | Independent company-value retrospective | Map: outcome metrics and prioritization. |
| 32 | `staff-tech-lead` / NEW retro | Independent architecture retrospective | Map: ADRs, risks and cross-cutting trade-offs. |
| 33 | `principal-security-auditor` / NEW retro | Independent security retrospective | Map: access control/data integrity. |
| 34 | `staff-qa-lead` / NEW retro | Independent quality retrospective | Map: quality gates, test pyramid and incident test gaps. |
| 35 | `principal-ui-ux-engineer` / NEW retro | Independent UI/UX retrospective | Existing role: accessibility and Web usability; a further new session. |

## Phases

### Phase 1: Frozen intake and independent planning
- **Agent**: `staff-agent-orchestrator`, `guardrail-agent`, the 16 named Sol instances above.
- **Input**: Entire iteration 11 handoff and all five original retrospectives; AGENTS/PROGRAM/outcome/scale/reuse decision; physical source-before snapshot.
- **Activity**: Verify source identity, full-read mandatory inputs and focused source, hold all 16 READY/RUNNING before GO, then write independent originals without peers.
- **Deliverable**: `tmp/enhancement-program/12/{conductor-intake,planning-barrier-pre-go,planning-originals-manifest-01,planning-release-01}.json` and `plans/01-journey.md` through `plans/16-architecture.md`.
- **Done when**: Observed all-16 live barrier; 16 final originals/physical copies sealed, conductor/root full-read, read fingerprints match, all planners released. Completed planning evidence does not imply product correctness.
- **Handoff to**: Phase 2 + `staff-tech-lead` / NEW Astra.
- **Estimated effort**: 5 person-hours combined.

### Phase 2: Evidence-based scope selection
- **Agent**: `staff-tech-lead` / NEW Astra.
- **Input**: All 16 entire originals, all five entire retrospectives/handoff, guardrail brief and meaningful source.
- **Activity**: Apply explicit weighted core-journey/UX/correctness/source-constraint/testability/minimal-change rubric; retain every proposal's disposition and dissent. Select a backed UI benefit and honest following-functionality proof boundary.
- **Deliverable**: `decision.md`, `tmp/enhancement-program/12/astra-read-audit.json`.
- **Done when**: New Astra signs the exact selected scope/API/ownership/acceptance and root/conductor full-read it; no majority vote or product-authoring shortcut.
- **Handoff to**: Phase 3 + `staff-agent-orchestrator` (root and implementation).
- **Estimated effort**: 1 person-hour.

### Phase 3: Concrete implementation handoff
- **Agent**: `staff-agent-orchestrator`, `staff-tech-lead`, `principal-ui-ux-engineer`.
- **Input**: Final ADR, `implementation-contract.md`, guardrail and impediments reports.
- **Activity**: Root accepts the reviewable contract within existing authorization, then dispatches the implementation orchestrator, impediment adviser and UI/UX adviser. Advisers own reports only. Exactly root + A + B own product/test source, including corrections.
- **Deliverable**: Root acceptance receipt; explicit A/B file ownership and adviser reports under `review/`.
- **Done when**: No overlapping source ownership, no hidden fourth author, exact API and verification matrix frozen before code.
- **Handoff to**: Phase 4 + `principal-elixir-engineer` A/B and root.
- **Estimated effort**: 1 person-hour.

### Phase 4: Implement the selected benefit
- **Agent**: `principal-elixir-engineer` A/B; existing root.
- **Input**: Accepted ADR/interface, source-before bindings and root's frozen public synthetic expectations.
- **Activity**: A builds only domain/read APIs and owned tests; B builds only stateless presentation and owned tests; root integrates shared state/Portal, compatibility and test fixtures. Root alone runs every runtime/test/build/HTTP/browser/DB/process/Git action. Same owners fix findings.
- **Deliverable**: Working selected UI/API, root command logs with exit codes, bounded normal-entry/query evidence, positive/refusal/recovery and corrected-export continuity evidence.
- **Done when**: Contract checks pass without broadening analysis/approval/consent authority or hiding failures. No Graphiti/model/million-file claim follows from inspection.
- **Handoff to**: Phase 5 + five independent validators, including `principal-code-reviewer`.
- **Estimated effort**: 32–56 person-hours across the three source owners (ADR's rough4–7 engineer-days); not observed time.

### Phase 5: Independent validation and review loop
- **Agent**: `principal-code-reviewer`, `principal-security-auditor`, `principal-qa-web-playwright`, `principal-qa-api-curl`, `principal-ui-ux-engineer` in five separate sessions.
- **Input**: Same frozen candidate/evidence packet and individual output paths; each independently reads source and actual evidence.
- **Activity**: Challenge boundedness, authority, refusals, recovery, usability and downstream continuity. Root executes requested checks; validators do not author product/tests. Findings return to the original owner. Repeat only when a failure/change justifies it.
- **Deliverable**: Five independent `qa/` originals, root verification report and any same-reviewer correction verdicts.
- **Done when**: Blocking findings are corrected and independently disposed; exact checks/limits/failures remain visible. Maximum three unresolved review loops before named Staff escalation.
- **Handoff to**: Phase 6 + existing root.
- **Estimated effort**: 6 person-hours combined.

### Phase 6: Local installation and verification
- **Agent**: `staff-agent-orchestrator` (existing root executor).
- **Input**: Accepted candidate, verified command logs, pre-upgrade backup and observed local runtime identity.
- **Activity**: Root preserves unrelated work, upgrades only the authorised local app, verifies data/artifact preservation and normal-entry UI/resource identity, records actual browser origin and process lifecycle. This is local work, not production/publication.
- **Deliverable**: Root local install/smoke/rollback evidence and frozen retrospective packet.
- **Done when**: Candidate actually installed and verified or failure explicitly corrected; no process/DB claim by advisers. Rollback preserves the pre-upgrade data/artifacts if installation fails.
- **Handoff to**: Phase 7 + five further NEW independent retrospective sessions.
- **Estimated effort**: 2 person-hours.

### Phase 7: Exactly five further new retrospectives
- **Agent**: NEW `staff-product-owner`, `staff-tech-lead`, `principal-security-auditor`, `staff-qa-lead`, `principal-ui-ux-engineer` instances.
- **Input**: Same accepted evidence packet, outcome/reuse direction and five separate output paths; none previously planned/authored/validated this round.
- **Activity**: Each answers company-harness helpfulness/reliability and ranks missing capabilities before seeing peers; cites code/evidence and preserves dissent.
- **Deliverable**: Exactly five original `retro/{product,architecture,security,quality,uiux}.md` reports and read audits.
- **Done when**: Reports independently written, physical bindings verified and all five entirely read by conductor and root. Opinions do not replace validation.
- **Handoff to**: Phase 8 + `staff-agent-orchestrator` (root/conductor).
- **Estimated effort**: 2.5 person-hours combined.

### Phase 8: Full handoff and root count
- **Agent**: `staff-agent-orchestrator` (conductor prepares, root accepts).
- **Input**: All five entire originals, actual verification/install record, open findings and user outcome/reuse constraints.
- **Activity**: Preserve disagreement and limits; bind exact evidence and following-functionality minimum proof without preselecting iteration 13's schema/backend. Root full-reads the handoff and records accepted status/count only after every required gate.
- **Deliverable**: `handoff-to-13.md`, root closure receipt and root-only board/ledger updates.
- **Done when**: Full accepted handoff precedes any count change. Iteration 13 still needs its fresh 16 Sol/new Astra selection after this retrospective.
- **Handoff to**: Fresh iteration 13 planning led by a new `staff-tech-lead` / Astra.
- **Estimated effort**: 1 person-hour.

## Effort summary

| Phase | Agent | Effort |
|---|---|---|
| 1 | Conductor, guardrail, 16 Sol | 5 h |
| 2 | NEW Astra | 1 h |
| 3 | Root and implementation advisers | 1 h |
| 4 | Root + two principals | 32–56 h |
| 5 | Five independent validators | 6 h |
| 6 | Root | 2 h |
| 7 | Five further NEW retrospectives | 2.5 h |
| 8 | Root/conductor | 1 h |
| **Total** | | **50.5–74.5 h** |

## Risks + mitigations

- **Risk**: A paged component hides unbounded parent body hydration → **Mitigation**: inspect/query-check normal mount, Company navigation and reload with a larger public corpus; no full-body source-list DTOs.
- **Risk**: Connection inspection looks like project analysis/plan membership or semantic support → **Mitigation**: explicit distinct scopes, no inference/approval bridge, labels only from existing bound findings, exact refusal/recovery checks.
- **Risk**: Off-page saved assignments/consent IDs disappear on Save → **Mitigation**: explicit untouched/off-page preservation and regression checks before global metadata integration.
- **Risk**: A broad framework build replaces this UI benefit or future functionality is deferred repeatedly → **Mitigation**: ADR-bounded APIs now, concrete iteration 13 outcome/minimum proof, fresh next-round selection; no unreviewed backend/schema prescription.
- **Risk**: Reviewers become extra authors or testing evidence is overstated → **Mitigation**: exactly three source owners including tests/corrections, root-only execution and five independent reports with actual evidence provenance.

## Escalation path

- If implementation cannot satisfy normal-entry boundedness or exact scope/authority within the selected slice → root escalates to `staff-tech-lead` with ADR/hash, failing source/query/behavior evidence, affected user action, smallest corrective option and at least one alternative.
- If three review loops leave a blocking finding unresolved → `staff-tech-lead` selects one explicit replan/retry/human handoff; never relabel failure or add an unapproved fourth writer.
- Missing real-model/private-source credentials, spending permission or unsupported controllers are recorded once; continue independent authorised work and do not repeat an unchanged request.

## How to execute

This run uses the existing collaboration sessions. Root dispatches only the needed phase and owns all execution. No CLI-agent launch, publication or new permission flow is authorised. The canonical invocation below is retained as format reference only, not an instruction to run it.

For each phase, the user can invoke the agent via the running agents-ui (open the Chat tab and select the agent), or via CLI:

```bash
./bin/Codex -p --append-system-prompt-file ~/.Codex/agents/<slug>.md \
  "<the input for this phase>"
```
