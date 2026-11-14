# Coordination Plan: Iteration 02 Company workflow guide

**Classification**: implementation
**Pattern**: composed: map-reduce + parallel-fan-out + review-loop + handoff
**Total agents involved**: 32 planned instances, at most 21 active

## Agents involved (in order of first involvement)

Capability citations refer to the local `fleet-capability-map` skill. Runtime task names and explicit model requests for the completed planning phase are recorded in `tmp/enhancement-program/02/planning-concurrency.json`.

| # | Agent | Role in this plan | Why this agent (cite the capability map) |
|---|---|---|---|
| 1 | `staff-agent-orchestrator` | Root/program owner and phase conductor | Meta-orchestration, ownership and concrete handoff design |
| 2 | `staff-product-owner` | Sol onboarding/package planning lenses | Jobs to be done and testable acceptance |
| 3 | `principal-elixir-engineer` | Sol state/draft/lifecycle lenses; principal implementation | Phoenix LiveView and Ecto contexts |
| 4 | `staff-documentation-writer` | Sol hierarchy/language/help lenses | Information architecture and operator guidance |
| 5 | `principal-qa-web-playwright` | Sol focus/error lenses; independent browser validation | Browser behavior, semantic locators and visual evidence |
| 6 | `principal-frontend-perf-engineer` | Sol responsive lens | Layout and interaction performance |
| 7 | `principal-security-auditor` | Sol authority lenses; independent guardrail | Access control and data integrity |
| 8 | `principal-qa-api-curl` | Sol acceptance lens | Contract and negative testing |
| 9 | `staff-tech-lead` | Astra decision; separate impediment-removal instance | ADRs, blast radius and technical risk |
| 10 | `principal-typescript-frontend-engineer` | Design-system capability reference | Frontend design-system architecture; no stack change |
| 11 | `principal-code-reviewer` | Independent code review | Correctness, security, tests and observability |
| 12 | `staff-qa-lead` | Independent suite and retrospective quality | Test strategy and meaningful acceptance gates |

The runtime exposes an actual **Principal UI/UX Engineer** role absent from the generated capability map; root explicitly assigned that existing role to presentation author B. This is a catalogue discrepancy, not an invented agent slug. Planning used 16 actual Sol instances, not simulated roles.

## Phases

### Phase 1: Concurrent investigation and Astra decision — completed
- **Agent**: Sixteen Sol planners across the specialties above; one Astra `staff-tech-lead`.
- **Input**: Iteration 01 handoff, all five original retrospectives, code and recorded native baseline.
- **Activity**: Distinct investigations, maximum 350 words each; all stayed active until the actual 16-agent snapshot. Astra read all reports and recorded each disposition.
- **Deliverable**: `planning/01..16-*.md`, `decision.md`, local concurrency JSON.
- **Done when**: Achieved: all 16 READY and completed after release; decision 1,046 words; no reactivation.
- **Handoff to**: Root acceptance before Phase 2.
- **Estimated effort**: 3 aggregate person-hours.

### Phase 2: Freeze implementation interface
- **Agent**: `staff-agent-orchestrator`, `principal-security-auditor`, `staff-tech-lead`, root-resolved expert UI/UX specialist.
- **Input**: Root-accepted `decision.md`.
- **Activity**: Confirm bounded guide, assigns/events, three author boundaries and browser evidence; guardrail reviews authority/drafts and impediment remover resolves concrete ownership/tooling blockers.
- **Deliverable**: `review/interface-contract.md`, `review/guardrail-brief.md`, `review/impediments.md`.
- **Done when**: Achieved: root accepted scope and author dispatch; interfaces have one owner each.
- **Handoff to**: Phase 3 (`principal-elixir-engineer` and design/portal authors).
- **Estimated effort**: 0.5 h.

### Phase 3: Three bounded author lanes
- **Agent**: Principal engineering authors with expert UI/UX participation.
- **Input**: Frozen events/assigns and acceptance cases from `decision.md`.
- **Activity**: A owns `company_panel.ex` and new `company/guide.ex`; B owns `company/catalog.ex`, `company/plan.ex`, `assets/css/app.css` and the approved minimal focus listener in `assets/js/app.js`; C owns `portal_live.ex` and focused Company regression tests. Preserve other edits; root owns board/state/shared infrastructure. One Mix window coordinated by root.
- **Deliverable**: Working guide, mounted disclosure, accurate counts/preflight and draft/focus behavior.
- **Done when**: Selected state matrix and focused checks pass; no domain/schema/API/MCP changes.
- **Handoff to**: Phase 4 (`principal-code-reviewer`, independent QA).
- **Estimated effort**: 3–6 aggregate h.

### Phase 4: Independent review and evidence
- **Agent**: `principal-code-reviewer`, `staff-qa-lead`, `principal-qa-web-playwright`, guardrail reviewer.
- **Input**: Changed files, acceptance contract, existing failures/limitations.
- **Activity**: Independent regression and authority review; canonical suite/gates in root window; actual native Chrome state/focus/draft/recovery checks, desktop/390px screenshots, 320px overflow and 200% zoom.
- **Deliverable**: Command/exit logs, screenshots, review verdict and accepted manifest on SSD under `tmp/enhancement-program/02/`.
- **Done when**: Meaningful checks pass and material findings are fixed; no fabricated study, conformance or model-quality claim.
- **Handoff to**: Phase 5 (five independent retrospective instances).
- **Estimated effort**: 2–3 aggregate h.

### Phase 5: Five retrospectives and next handoff
- **Agent**: Five independent product, UX, architecture, trust and quality reviewers.
- **Input**: Same accepted manifest, separate output paths; no peer reports before verdict.
- **Activity**: Answer usefulness/reliability for a complete company harness and rank missing capabilities. Preserve disagreement about next functionality: goal policy/conflicts, qualification/readiness and portable approval.
- **Deliverable**: Five `retro/` reports, root handoff to iteration 03 and ledger update.
- **Done when**: Root accepts evidence and reports; iteration 02 is not pre-counted.
- **Handoff to**: Root-authorized iteration 03 functionality planning.
- **Estimated effort**: 1 aggregate h.

## Effort summary

| Phase | Agent | Effort |
|---|---|---|
| 1 | Sixteen Sol planners + Astra decision | 3 h |
| 2 | Conductor + advisors | 0.5 h |
| 3 | Three principal/design authors | 3–6 h |
| 4 | Independent review + QA | 2–3 h |
| 5 | Five retrospective instances | 1 h |
| **Total** | | **9.5–13.5 aggregate h** |

## Risks + mitigations

- **Risk**: Guide implies authority or qualification → **Mitigation**: Selected-plan preflight is advisory; approval/build/export recheck admission; lifecycle and runtime labels remain separate.
- **Risk**: Disclosure loses input/focus → **Mitigation**: Mounted forms, bounded session drafts and browser keyboard/error evidence.
- **Risk**: Parallel authors conflict → **Mitigation**: Freeze interfaces, disjoint files, max three authors and serialized Mix.
- **Risk**: Baseline skips hide execution assurance → **Mitigation**: Retain 15 existing Docker skips, two old Dialyzer diagnostics and unavailable managed runtime explicitly.

## Escalation path

- If contract ambiguity, ownership conflict or three failed review rounds persist → root and `staff-tech-lead`, with exact finding/log, changed files and smallest retry/re-scope. Continue independent authorized work.

## How to execute

For each phase, the user can invoke the agent via the running agents-ui (open the Chat tab and select the agent), or via CLI:

```bash
./bin/Codex -p --append-system-prompt-file ~/.Codex/agents/<slug>.md \
  "<the input for this phase>"
```

The already-authorized collaboration tools execute this program. Phases 1–2 completed, and three exclusive authors are implementing Phase 3. No Mix process or browser validation has been started by the conductor/authors.
