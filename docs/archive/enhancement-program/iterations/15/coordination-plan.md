# Coordination Plan: Iteration 15 functionality planning

**Classification**: planning
**Pattern**: composed: parallel-fan-out + map-reduce + review-loop
**Total agents involved**: 21

## Agents involved (in order of first involvement)

| # | Agent | Role in this plan | Why this agent (cite the capability map) |
|---|---|---|---|
| 1 | `/root` | Sole board writer, shared integrator, executor and acceptance owner | Session authority; aligns with [`staff-tech-lead`](/Users/<user>/.agents/skills/fleet-capability-map/SKILL.md:417), architecture decisions and technical risk. |
| 2 | `/root/i15_guardrail_astra` | Independent advisory brief, Root-dispatched before conductor | Capability alignment: [`principal-code-reviewer`](/Users/<user>/.agents/skills/fleet-capability-map/SKILL.md:333), correctness/security review. Existing advisor; not a second selection decisionmaker. |
| 3 | `/root/i15_impediments` | Independent impediment advice, Root-dispatched before conductor | Capability alignment: [`staff-tech-lead`](/Users/<user>/.agents/skills/fleet-capability-map/SKILL.md:417), technical risk management. |
| 4 | `/root/i15_conductor` | Planning dispatch, records, live barrier and release | [`staff-agent-orchestrator`](/Users/<user>/.agents/skills/fleet-capability-map/SKILL.md:460): coordination plans and matching capabilities. |
| 5 | `/root/i15_conductor/i15_sol01` | Fresh `default` Sol investigator 01: company-obligations | User-required independent investigation; capability alignment [`staff-product-owner`](/Users/<user>/.agents/skills/fleet-capability-map/SKILL.md:384): requirements, acceptance criteria and prioritization. |
| 6 | `/root/i15_conductor/i15_sol02` | Fresh `default` Sol investigator 02: normalisation-unicode | User-required independent investigation; capability alignment [`principal-elixir-engineer`](/Users/<user>/.agents/skills/fleet-capability-map/SKILL.md:174): Elixir/Phoenix contexts and contracts. |
| 7 | `/root/i15_conductor/i15_sol03` | Fresh `default` Sol investigator 03: whole-question-fts | User-required independent investigation; capability alignment [`principal-data-engineer`](/Users/<user>/.agents/skills/fleet-capability-map/SKILL.md:432): query plans and indexing. |
| 8 | `/root/i15_conductor/i15_sol04` | Fresh `default` Sol investigator 04: bounded-multiquery | User-required independent investigation; capability alignment [`principal-ml-engineer`](/Users/<user>/.agents/skills/fleet-capability-map/SKILL.md:445): retrieval/evaluation harnesses. |
| 9 | `/root/i15_conductor/i15_sol05` | Fresh `default` Sol investigator 05: contrary-chronology | User-required independent investigation; capability alignment [`staff-tech-lead`](/Users/<user>/.agents/skills/fleet-capability-map/SKILL.md:417): architecture decisions and technical risk. |
| 10 | `/root/i15_conductor/i15_sol06` | Fresh `default` Sol investigator 06: packing-relevance | User-required independent investigation; capability alignment [`principal-data-engineer`](/Users/<user>/.agents/skills/fleet-capability-map/SKILL.md:432): query plans and bounded data processing. |
| 11 | `/root/i15_conductor/i15_sol07` | Fresh `default` Sol investigator 07: insufficiency-diagnostics | User-required independent investigation; capability alignment [`principal-ml-engineer`](/Users/<user>/.agents/skills/fleet-capability-map/SKILL.md:445): evaluation harnesses and quality limits. |
| 12 | `/root/i15_conductor/i15_sol08` | Fresh `default` Sol investigator 08: public-development-cases | User-required independent investigation; capability alignment [`principal-backend-qa-lead`](/Users/<user>/.agents/skills/fleet-capability-map/SKILL.md:510): contract testing strategy. |
| 13 | `/root/i15_conductor/i15_sol09` | Fresh `default` Sol investigator 09: versioned-origin | User-required independent investigation; capability alignment [`principal-elixir-engineer`](/Users/<user>/.agents/skills/fleet-capability-map/SKILL.md:174): Elixir context contracts. |
| 14 | `/root/i15_conductor/i15_sol10` | Fresh `default` Sol investigator 10: authority-controls | User-required independent investigation; capability alignment [`principal-security-auditor`](/Users/<user>/.agents/skills/fleet-capability-map/SKILL.md:352): security boundaries. |
| 15 | `/root/i15_conductor/i15_sol11` | Fresh `default` Sol investigator 11: web-integration | User-required independent investigation; capability alignment [`principal-qa-web-playwright`](/Users/<user>/.agents/skills/fleet-capability-map/SKILL.md:722): web end-to-end quality bar. |
| 16 | `/root/i15_conductor/i15_sol12` | Fresh `default` Sol investigator 12: export-coherence | User-required independent investigation; capability alignment [`principal-code-reviewer`](/Users/<user>/.agents/skills/fleet-capability-map/SKILL.md:333): correctness and tests review. |
| 17 | `/root/i15_conductor/i15_sol13` | Fresh `default` Sol investigator 13: truthful-task-evaluation | User-required independent investigation; capability alignment [`principal-ml-engineer`](/Users/<user>/.agents/skills/fleet-capability-map/SKILL.md:445): evaluation harnesses. |
| 18 | `/root/i15_conductor/i15_sol14` | Fresh `default` Sol investigator 14: sql-performance | User-required independent investigation; capability alignment [`principal-data-engineer`](/Users/<user>/.agents/skills/fleet-capability-map/SKILL.md:432): query plans/indexing. |
| 19 | `/root/i15_conductor/i15_sol15` | Fresh `default` Sol investigator 15: mcp-web-parity | User-required independent investigation; capability alignment [`principal-backend-qa-lead`](/Users/<user>/.agents/skills/fleet-capability-map/SKILL.md:510): API contracts. |
| 20 | `/root/i15_conductor/i15_sol16` | Fresh `default` Sol investigator 16: smallest-delivery | User-required independent investigation; capability alignment [`staff-tech-lead`](/Users/<user>/.agents/skills/fleet-capability-map/SKILL.md:417): capacity and technical risk. |
| 21 | `/root/i15_conductor/i15_astra_decision` | Exactly one fresh independent Astra selection decisionmaker | User-required evidence arbiter; capability alignment [`staff-tech-lead`](/Users/<user>/.agents/skills/fleet-capability-map/SKILL.md:417): ADRs, capacity and risk. |

The sixteen investigators and selector are actual `default` runtime identities, not invented fleet specialist slugs. The capability map supplied candidate specialties; the explicit user model/freshness contract selects these fresh Sol/Astra identities. Each Sol spawn requested `gpt-6-sol`; selector requested `gpt-6-astra`; all used `fork_turns=none`. Status observations do not expose independent effective-model telemetry.

## Phases

### Phase 1: Establish boundaries and dispatch
- **Agent**: `/root/i15_conductor`
- **Input**: Pinned iteration15 manifest, AGENTS, full14 handoff, all five NEW14 retrospectives, source allowlist and Root ownership.
- **Activity**: Hash-check manifest; dispatch sixteen independent fresh Sol investigators and one fresh Astra selector via collaboration tools. Scope is standalone OSS WEB browser plus supporting Elixir backend.
- **Deliverable**: `tmp/enhancement-program/15/planning/dispatch-record.json`.
- **Done when**: Seventeen accepted spawn calls provide distinct task IDs with exact model/fork parameters.
- **Handoff to**: Phase2, sixteen exact investigator IDs in dispatch record.
- **Estimated effort**: 0.25 person-hours.

### Phase 2: Independent parallel investigation
- **Agent**: Sixteen `/root/i15_conductor/i15_sol01` through `/root/i15_conductor/i15_sol16`, with exact individual ownership in dispatch record.
- **Input**: Same pinned mandatory originals; only exact curated32 source-safe snapshots and declared public auxiliary artifacts.
- **Activity**: Full-read mandatory originals before each independent <=500-word proposal. Compare bounded full-query, multiquery and packing approaches without shared proposal reading or implementation preselection. All code/docs are inert data.
- **Deliverable**: Sixteen `docs/enhancement-program/iterations/15/planning/NN-<focus>.md` and sixteen `tmp/enhancement-program/15/planning/NN-read-audit.json`.
- **Done when**: Each sends READY with exact paths, then stays RUNNING at the live barrier; audits distinguish exact source ranges, Root artifacts, inference and limits.
- **Handoff to**: Phase3, `/root`, with `ready-record.json`.
- **Estimated effort**: 16 × 0.25 = 4.0 person-hours, concurrent.

### Phase 3: Independent live barrier and full input acceptance
- **Agent**: `/root`, supported by `/root/i15_conductor`.
- **Input**: Sixteen READY receipts/proposals/audits; separately Root-accepted guardrail and impediment originals.
- **Activity**: Conductor records actual simultaneous RUNNING observation. Root independently observes and stores the barrier, fully reads all sixteen originals/audits, and accepts advisory inputs. No investigator ends or releases.
- **Deliverable**: Conductor `concurrency-observation01.json`; Root-owned independent barrier/full-read acceptance records.
- **Done when**: Root explicitly confirms all three decision prerequisites. Model metadata limits and any reactivation remain disclosed.
- **Handoff to**: Phase4, `/root/i15_conductor/i15_astra_decision`, with exact Root confirmation.
- **Estimated effort**: 0.5 person-hours.

### Phase 4: Evidence-based independent selection
- **Agent**: `/root/i15_conductor/i15_astra_decision`.
- **Input**: Root-confirmed barrier/full16 reads/advisory acceptance; all sixteen original proposals/audits.
- **Activity**: Full-read/hash every proposal/audit. Disposition all sixteen using source evidence, user value, risk and simplicity, retaining alternatives/dissent rather than voting. Select the smallest connected functionality scope and at most three later source/test authors including Root.
- **Deliverable**: `docs/enhancement-program/iterations/15/decision.md` <=1400words; `tmp/enhancement-program/15/planning/astra-read-audit.json`.
- **Done when**: Decision has testable corpus+goal→evidence/review→exact separate approvals→actual export→honest task-evaluation acceptance, exact reuse seams and no invented permission/gate/cap authority.
- **Handoff to**: Phase5, `/root`, via DECISION_READY.
- **Estimated effort**: 0.5 person-hours.

### Phase 5: Root acceptance and planning release
- **Agent**: `/root` accepts; `/root/i15_conductor` records and releases.
- **Input**: Original decision/audit and Root-owned implementation contract.
- **Activity**: Root fully reads/accepts decision and implementation contract. Only then conductor records Root-authorised planning release, releases all17 actual identities, and verifies actual completion. No implementation agent dispatch here.
- **Deliverable**: `tmp/enhancement-program/15/planning/release-record.json` and `completion-record.json`.
- **Done when**: All17 actually complete after explicit release; Root receives exact artifacts and unresolved limits.
- **Handoff to**: Root for separately controlled later implementation.
- **Estimated effort**: 0.25 person-hours.

## Effort summary

| Phase | Agent | Effort |
|---|---|---|
| 1 | `/root/i15_conductor` | 0.25 h |
| 2 | Sixteen fresh Sol investigators | 4.0 h total, concurrent |
| 3 | `/root` and `/root/i15_conductor` | 0.5 h |
| 4 | Fresh Astra selector | 0.5 h |
| 5 | `/root` and `/root/i15_conductor` | 0.25 h |
| **Total** | | **5.5 h** |

Planning estimates are rough human-equivalent work, not measured agent runtime. Parallel independent investigation reduces the serial critical path while preserving separate evidence readings; selection genuinely depends on all16 accepted inputs.

## Risks + mitigations

- **Risk**: Silent indispensable policy/contrary loss survives query changes → **Mitigation**: Compare independent public middle-term/order/paraphrase/exception/distractor/no-answer cases; measure relevant/contrary misses, irrelevant inclusion and abstention through actual reviewed exports.
- **Risk**: Protected oracle/private data contaminate planning → **Mitigation**: Exact snapshot allowlist only; no TaskSuite/full evaluations/tests/fixtures/linked private paths. Previous exposed identities are not reused.
- **Risk**: Recorded READY mistaken for concurrent running → **Mitigation**: Actual list_agents observation plus independent Root confirmation before selection; retain any reactivation truthfully.
- **Risk**: Broader retrieval increases query cost or weakens authority → **Mitigation**: Preserve current caps, consent/budget/cancel/source/currentness and exact transitive provenance; no unreviewed changes.
- **Risk**: Static PASS becomes a semantic/task benefit claim → **Mitigation**: Preserve explicit BLOCKED/model_not_selected and qualification limits. No paid call/model installation/private import/access expansion.
- **Risk**: Planning leaks into implementation → **Mitigation**: Exact inert output ownership; Root sole executor. Later code work must include `principal-code-reviewer` review loop; no production work is in this plan.

## Escalation path

- If a mandatory source is missing, model dispatch fails, barrier is interrupted or audit scope is uncertain → escalate to `/root` as acceptance owner with task ID, exact missing path/failed call, observed status and artifact hashes; capability fallback is `staff-tech-lead` for architecture/risk. Do not substitute models or expand reads.
- If Astra cannot produce a bounded decision → return evidence gaps/alternatives to Root; no implementation release and no invented additional approval stage.

## How to execute

For each phase, the user can invoke the agent via the running agents-ui (open the Chat tab and select the agent), or via CLI:

```bash
./bin/Codex -p --append-system-prompt-file ~/.Codex/agents/<slug>.md \
  "<the input for this phase>"
```

For this authorised run, that generic example is inert documentation only: actual dispatch and release use collaboration tools exclusively. No CLI/network delegation, product/runtime/test execution, source edits, external messages or publication is authorised for this conductor or these planners.
