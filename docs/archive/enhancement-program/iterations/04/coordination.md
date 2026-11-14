# Coordination Plan: HarnessForge iteration 04 UI/UX

**Classification**: implementation
**Pattern**: composed: map-reduce + sequential + review-loop
**Total agents involved**: 34 including root and conductor; at most 19 in planning

## Agents involved (in order of first involvement)

Capability citations refer to `/Users/<user>/.agents/skills/fleet-capability-map/SKILL.md`; supported role labels resolve dispatch.

| # | Agent | Role in this plan | Why this agent (cite the capability map) |
|---|---|---|---|
| 1 | `staff-agent-orchestrator` | Root and fresh conductor | Meta-orchestration: bounded phases and explicit handoffs |
| 2 | `staff-tech-lead` | One fresh Astra decision maker; later impediment advisor | Architecture/ADR/RFC capability and technical risk management |
| 3 | `staff-product-owner` | Fresh Sol planning lenses | Product stories, prioritization and acceptance criteria |
| 4 | `principal-elixir-engineer` | Sol lenses and principal author | Elixir/Phoenix capability; LiveView and Ecto specialty |
| 5 | `principal-qa-web-playwright` | Sol lenses and independent web validation | Browser behavior, stable accessibility locators and visual evidence |
| 6 | `staff-documentation-writer` | Sol lenses | Information architecture and concise operator guidance |
| 7 | `principal-security-auditor` | Sol lens and independent trust review | Security, broken access control and data integrity |
| 8 | `principal-ml-engineer` | Sol qualification lens | ML evaluation and calibrated evidence |
| 9 | `staff-qa-lead` | Sol testability lens and independent QA | Test pyramid, meaningful gates and environment policy |
| 10 | `principal-qa-api-curl` | Sol contract lens and backend validation | API contract, negative and smoke testing |
| 11 | `principal-code-reviewer` | Independent review loop | Correctness, security, tests, docs and observability |

Two exact supported specialist roles supplement the older map: **Principal UI/UX Engineer** (expert design input and independent UX validation) and **Guardrail Agent** (request-scoped brief before changes). **Senior Software Architect** supplies the planner's service-internal boundary lens. No capability-map omission blocks the supported roles. The final actual session inventory is recorded with dispatch evidence; 34 is an initial bounded estimate.

## Phases

### Phase 1: Prior evidence and concurrent proposals
- **Agent**: `staff-agent-orchestrator`, sixteen independent Sol planning sessions
- **Input**: Root iteration-start signal, all five original03 retrospectives, handoff, accepted amendment, verification and current source.
- **Activity**: Preserve disagreement. Sixteen fresh `gpt-6-sol`, `fork_turns:none` sessions write distinct proposals of at most350 words and hold ACTIVE at the final-review barrier. Capture actual concurrency before any release.
- **Deliverable**: `planning/01..16-*.md`; SSD `planning-concurrency.json` and report fingerprints.
- **Done when**: All sixteen reports exist and an actual snapshot records all sixteen original sessions running.
- **Handoff to**: Phase2, `staff-tech-lead`
- **Estimated effort**: 2.0 person-hours aggregate

### Phase 2: Evidence-based bounded choice
- **Agent**: `staff-tech-lead` (fresh `gpt-6-astra`)
- **Input**: Every proposal, every prior original retrospective and source evidence.
- **Activity**: Disposition each proposal and choose one user benefit by value, acceptance, reliability and simplicity. Do not count votes. Release planners and decision maker after review.
- **Deliverable**: `decision.md` with exact scope, ownership and acceptance.
- **Done when**: Root accepts the concrete integration boundary before author dispatch.
- **Handoff to**: Phase3, `staff-agent-orchestrator`
- **Estimated effort**: 0.5 person-hours

### Phase 3: Guardrails and bounded implementation
- **Agent**: `principal-elixir-engineer`, **Principal UI/UX Engineer**, **Guardrail Agent**, `staff-tech-lead`
- **Input**: Root-accepted decision and disjoint file ownership.
- **Activity**: Obtain guardrail brief before edits; implement the smallest bounded change using existing LiveView components. At most three authors. Root alone owns shared integration, ledger, native build and CUA. Reserve one serialized Mix window explicitly.
- **Deliverable**: Product change, meaningful regression checks, implementation note and SSD command/exit evidence.
- **Done when**: Acceptance behavior works and authored files are frozen for independent review.
- **Handoff to**: Phase4, `principal-code-reviewer`
- **Estimated effort**: 1.5–3.0 person-hours

### Phase 4: Review, checks and native acceptance
- **Agent**: `principal-code-reviewer`, `principal-security-auditor`, `principal-qa-api-curl`, `principal-qa-web-playwright`, **Principal UI/UX Engineer**
- **Input**: Frozen changed files, decision and before bytes.
- **Activity**: Independent code, security, backend, web and UX validation; one serial Mix window. Correct findings, capped at three review rounds before Staff escalation. Root builds fresh04 native release and conducts actual Chrome acceptance after freeze.
- **Deliverable**: `review/*.md`, SSD command/exit/machine results and root browser provenance.
- **Done when**: Material findings are resolved and root accepts bounded behavior; failures remain preserved.
- **Handoff to**: Phase5, five independent retrospective sessions
- **Estimated effort**: 1.5–3.0 person-hours

### Phase 5: Independent retrospectives and handoff
- **Agent**: Five new product, UX, architecture, trust and quality instances
- **Input**: Root-frozen identical accepted evidence manifests and hashes; sole report paths.
- **Activity**: Each independently answers the user's exact helpfulness/reliability question in at most650 words before reading peers. Conductor reads all five only after all finish, preserves dissent and writes next handoff.
- **Deliverable**: `retro/01..05-*.md`, `handoff-to-05.md`
- **Done when**: Root records accepted04 result; no conductor ledger writes or future dispatch.
- **Handoff to**: Root closure and root-authorized05 start
- **Estimated effort**: 1.0 person-hours aggregate

## Effort summary

| Phase | Agent | Effort |
|---|---|---|
| 1 | Sixteen Sol planners + conductor | 2.0h |
| 2 | Astra `staff-tech-lead` | 0.5h |
| 3 | Principal author + advisors | 1.5–3.0h |
| 4 | Independent reviewers + root | 1.5–3.0h |
| 5 | Five fresh reviewers + conductor | 1.0h |
| **Total** | | **6.5–9.5h aggregate effort** |

## Risks + mitigations

- **Risk**: Parallel sessions exit before actual concurrency → **Mitigation**: Explicit ACTIVE barrier; retain actual list_agents result and disclose any reactivation.
- **Risk**: Copy implies authority or hides an incident → **Mitigation**: Preserve all domain gates and recorded states; test contrasting scenarios.
- **Risk**: Competing edits or Mix builds corrupt provenance → **Mitigation**: Disjoint ownership, sole root shared-file/native owner and one explicit Mix reservation.
- **Risk**: Evidence is overstated → **Mitigation**: Keep synthetic/native observations separate from model/company qualification and human-study claims.

## Escalation path

- If a boundary is ambiguous, a check repeatedly fails or three review rounds fail → escalate to root and `staff-tech-lead` with exact source, command/exit, preserved failure and smallest alternatives.

## How to execute

Use the actual collaboration tools, supported exact role labels and the task paths preserved in SSD evidence. No CLI dispatch is invented. Root controls shared integration, Mix reservations, native startup/CUA, immutable accepted inputs and final completion state. Routine authorized local work continues without a new user permission gate.
