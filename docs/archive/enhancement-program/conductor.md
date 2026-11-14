# Coordination Plan: HarnessForge bounded enhancement iterations

**Classification**: implementation
**Pattern**: composed: map-reduce + sequential + review-loop
**Total agents involved**: 28–32 per iteration; at most 21 active, including root

## Agents involved (in order of first involvement)

Capability citations refer to `/Users/<user>/.agents/skills/fleet-capability-map/SKILL.md`.

| # | Agent | Role in this plan | Why this agent (cite the capability map) |
|---|---|---|---|
| 1 | `staff-agent-orchestrator` | Root and phase conductor | Meta-orchestration: bounded coordination and explicit handoffs |
| 2 | `staff-product-owner` | Sol planning lenses | Product priorities, jobs to be done and testable acceptance criteria |
| 3 | `principal-elixir-engineer` | Sol planning lenses; principal implementation | Elixir/Phoenix/LiveView, Ecto and OTP specialization |
| 4 | `staff-documentation-writer` | Sol planning lenses | Information architecture and concise operator guidance |
| 5 | `principal-qa-web-playwright` | Sol planning lenses; independent browser verification | Accessibility locators, real browser behavior and visual evidence |
| 6 | `principal-security-auditor` | Planning lens and guardrail review | Access control, secrets, data integrity and resource limits |
| 7 | `principal-frontend-perf-engineer` | Sol planning lens | Web interaction and layout performance |
| 8 | `principal-qa-api-curl` | Sol planning lens; independent API verification | API contract, negative and smoke testing |
| 9 | `staff-tech-lead` | One Astra decision maker; impediment removal | ADRs, capacity, blast radius and technical risk |
| 10 | `principal-typescript-frontend-engineer` | Optional bounded design-system advice | Frontend design-system architecture; no stack rewrite |
| 11 | `principal-code-reviewer` | Independent code review | Correctness, security, tests, docs and observability |
| 12 | `staff-qa-lead` | Verification coordination and independent retrospective | Test strategy, meaningful evidence and quality gates |

The runtime tool registry exposes **Principal UI/UX Engineer**. Root resolved the older capability-map omission by using that exact supported role in iteration 02; no invented slug or extra approval is required. Expert UI/UX participation remains required.

## Phases

### Phase 1: Prior retrospective gate
- **Agent**: `staff-agent-orchestrator`
- **Input**: Root’s explicit iteration-start signal, prior accepted evidence, all five independent retrospectives and their handoff.
- **Activity**: Check the previous iteration is accepted and its agents released. Odd iterations select functionality; even iterations select UI/UX.
- **Deliverable**: Iteration input manifest; root alone updates state and board.
- **Done when**: Required prior reports exist, root gives the start signal, and planning slots are available.
- **Handoff to**: Phase 2 (`staff-tech-lead` with 16 Sol planners)
- **Estimated effort**: 0.1 person-hours

### Phase 2: Sixteen concurrent proposals and one Astra decision
- **Agent**: `staff-product-owner`, `principal-elixir-engineer`, `staff-documentation-writer`, `principal-qa-web-playwright`, `principal-security-auditor`, `principal-frontend-perf-engineer`, `principal-qa-api-curl`; `staff-tech-lead` adjudicates.
- **Input**: Prior handoff, five retrospectives, current code and one distinct lens per planner.
- **Activity**: Spawn exactly 16 `gpt-6-sol` planning agents with `fork_turns=none`; one `gpt-6-astra` decision maker. Each planner writes at most 350 words to its sole owned report, reports ready to Astra, and remains active at the final-review barrier. Capture an actual live snapshot with all 16 running before release. Astra reads every proposal and prior retrospective, records every disposition, then selects one small, substantive benefit with exact acceptance criteria.
- **Deliverable**: `iterations/NN/planning/01..16-*.md`, `decision.md`, and local concurrency JSON with task/model identities.
- **Done when**: Sixteen distinct reports, observed concurrency and one evidence-based bounded decision exist; all planners have been released.
- **Handoff to**: Root interface; **stop before dispatching implementation authors**.
- **Estimated effort**: 3.0 aggregate person-hours

### Phase 3: Bounded implementation
- **Agent**: `staff-agent-orchestrator`, `principal-elixir-engineer`, UI/UX specialist resolved by root, `principal-security-auditor`, `staff-tech-lead`
- **Input**: Root-accepted decision, file ownership, acceptance checks and root’s single Mix window.
- **Activity**: At most three distinct implementation authors; advisory guardrail and impediment roles do not edit product files. Reuse current Phoenix/LiveView components and contracts. Root integrates shared configuration, application, router and migrations.
- **Deliverable**: Working improvement, focused regression checks, concise implementation note.
- **Done when**: Selected acceptance criteria pass; no hidden fallback, scope expansion or ownership conflict remains.
- **Handoff to**: Phase 4 (`principal-code-reviewer` and independent QA)
- **Estimated effort**: 2.0–6.0 person-hours, revised by Astra scope

### Phase 4: Review and evidence
- **Agent**: `principal-code-reviewer`, `principal-qa-web-playwright`, `principal-qa-api-curl`, `staff-qa-lead`
- **Input**: Changed files, decision and acceptance contract; authors’ checks are context, not independent proof.
- **Activity**: Review code and independently exercise behavior. Root schedules one canonical Mix window. UI iterations require browser/visual evidence appropriate to the change. Correct failures before acceptance; at most three review rounds before escalation.
- **Deliverable**: Review verdict, command/exit logs, machine results and screenshots under `tmp/enhancement-program/NN/`; accepted evidence manifest.
- **Done when**: Selected behavior and regressions are verified, material findings resolved, and limitations explicitly retained.
- **Handoff to**: Phase 5 (five independent retrospective agents)
- **Estimated effort**: 1.0–3.0 person-hours

### Phase 5: Five independent retrospectives and next handoff
- **Agent**: Five independent instances selected from `staff-product-owner`, `staff-tech-lead`, `principal-security-auditor`, `principal-qa-web-playwright`, `staff-qa-lead`
- **Input**: Identical accepted evidence manifest; each receives its own report path and must not read peer retrospectives before writing.
- **Activity**: Answer whether the tool was helpful and reliable for a complete company harness, what remains missing, and rank the next gaps. Preserve disagreement and unavailable behavior.
- **Deliverable**: Five reports under `iterations/NN/retro/`; root’s accepted handoff and state update.
- **Done when**: All five reports exist; root accepts the iteration and records evidence. Planning/doc-only activity never counts as an enhancement.
- **Handoff to**: Phase 1 of the next iteration, following root’s start signal.
- **Estimated effort**: 1.0 aggregate person-hours

## Effort summary

| Phase | Agent | Effort |
|---|---|---|
| 1 | `staff-agent-orchestrator` | 0.1 h |
| 2 | Sixteen Sol planners + Astra `staff-tech-lead` | 3 h |
| 3 | Orchestrator + bounded principal authors/advisors | 2–6 h |
| 4 | `principal-code-reviewer` + independent QA | 1–3 h |
| 5 | Five independent retrospective instances | 1 h |
| **Total** | | **7.1–13.1 aggregate person-hours per iteration** |

Estimates describe task effort, not guaranteed elapsed runtime. Planning has 19 active slots including root and conductor, leaving two slots for necessary advisory roles.

## Risks + mitigations

- **Risk**: Broad proposals overwhelm the product → **Mitigation**: One bounded user benefit per iteration; favor progressive disclosure, clear next actions and reuse.
- **Risk**: Sixteen agents serialize accidentally or exit early → **Mitigation**: Explicit active barrier and actual snapshot; disclose any reactivation.
- **Risk**: Conflicting edits or competing Mix processes → **Mitigation**: At most three authors with disjoint files; root owns shared integration and one Mix window.
- **Risk**: Opinions substitute for reliability → **Mitigation**: Independent behavioral checks and SSD evidence precede five retrospectives.
- **Risk**: Private imports, paid calls or generated-code execution expand scope → **Mitigation**: Preserve existing access, consent, approval, export, purge and runtime boundaries; visibly report unavailable capabilities.

## Escalation path

- If a phase stalls, a contract conflicts, or three review rounds fail → escalate to root and `staff-tech-lead` with exact finding, changed files, failing evidence and the smallest retry or revised scope. Continue independent authorized work; do not repeat unchanged missing-input questions.

## How to execute

Use the authorized collaboration tools and exact supported runtime role labels. Read `state.json` and the prior original five retrospectives; root records acceptance before the next implementation begins. A fresh short-lived conductor owns each new iteration. The planning and retrospective agents are new independent instances for that iteration. Parent root owns native operations and the board.

Iterations01–05 are complete; root has read all five original05 independent retrospectives and the full handoff, preserving disagreements. Iteration06 UI/UX begins with a fresh conductor,16 new concurrent Sol planners and one new Astra decision maker. `tmp/enhancement-program/runtime-state.json` records observed local releases and workspaces. It is an observation, not permission to stop a process or infer Mix ownership: verify identity and coordinate with the active conductor before operations. Never overwrite a running release. Root owns native operations; use a distinct release and short disposable QA workspace, with evidence on the SSD.
