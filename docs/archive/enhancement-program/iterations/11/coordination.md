# Coordination Plan: Iteration 11 connected company functionality

**Classification**: planning
**Pattern**: composed: map-reduce + sequential + review-loop
**Total agents involved**: 19

This document counts the actual planning cohort: designated root, conductor, sixteen NEW original Sol planner sessions and one NEW Astra decision session. At most19 were needed concurrently. Later adviser, implementation, review, QA and retrospective sessions are required handoffs, not already-dispatched actors. Explicit spawn arguments record requested models and `fork_turns=none`; effective backend-model telemetry is not claimed. Five self-written audit model labels were corrected by those same original authors to this distinction; actual earlier bytes are retained.

## Agents involved (in order of first involvement)

Capability citations refer to `/Users/<user>/.agents/skills/fleet-capability-map/SKILL.md`, capability index and named roster entries. Independent candidate matching considered product, architecture, Elixir/Phoenix, data, ML, operations, web QA, API QA, security and QA strategy; the bounded lenses below use the matching specialties. The existing application remains standalone OSS, without private Olivium prerequisites.

| # | Agent | Role in this plan | Why this agent (cite the capability map) |
|---|---|---|---|
| 1 | `staff-agent-orchestrator` | Designated root `/root`: acceptance, sole board/state/result and execution owner | Map meta-orchestration: explicit handoffs and fleet coordination; root role is designated authority, not model telemetry. |
| 2 | `staff-agent-orchestrator` | `/root/i11_conductor`: intake, dispatch, barrier, fullread and handoff | Map meta-orchestration: coordination-plan design and bounded ownership. |
| 3 | `staff-tech-lead` | Fresh `/root/i11_conductor/i11_astra`, requested `gpt-6-astra`: decision | Map415: ADR/RFC decisions, technical risk, capacity and contract tradeoffs. |
| 4 | `staff-product-owner` | Fresh `i11_p01_outcome`, requested `gpt-6-sol`: Company owner outcome | Map382: jobs to be done, testable requirements, KPI and outcome acceptance. |
| 5 | `staff-tech-lead` | Fresh `i11_p02_completeness`, requested `gpt-6-sol`: Coherence and completeness | Map415: ADR/RFC decisions, technical risk, capacity and contract tradeoffs. |
| 6 | `staff-product-owner` | Fresh `i11_p03_rubric`, requested `gpt-6-sol`: Representative owner task/rubric | Map382: jobs to be done, testable requirements, KPI and outcome acceptance. |
| 7 | `principal-elixir-engineer` | Fresh `i11_p04_domain`, requested `gpt-6-sol`: Domain and persistence contract | Map178: Elixir/Phoenix/LiveView, Ecto contexts and PubSub/OTP boundaries. |
| 8 | `principal-data-engineer` | Fresh `i11_p05_history`, requested `gpt-6-sol`: Immutable history/successors | Map430: schema modeling, immutable history and migration safety. |
| 9 | `principal-ml-engineer` | Fresh `i11_p06_evaluation`, requested `gpt-6-sol`: Evaluation truth and semantic limits | Map443: evaluation harnesses and model quality evidence. |
| 10 | `principal-devops-sre` | Fresh `i11_p07_runtime`, requested `gpt-6-sol`: Runtime qualification boundary | Map337: operational isolation, Docker and observability boundaries; planning only here. |
| 11 | `principal-elixir-engineer` | Fresh `i11_p08_portal`, requested `gpt-6-sol`: Real portal flow | Map178: Elixir/Phoenix/LiveView, Ecto contexts and PubSub/OTP boundaries. |
| 12 | `principal-qa-web-playwright` | Fresh `i11_p09_ux`, requested `gpt-6-sol`: Usable owner journey | Map720: real browser/visual/accessible journey oracles; root executes browsers. |
| 13 | `principal-qa-api-curl` | Fresh `i11_p10_mcp`, requested `gpt-6-sol`: Focused own-MCP context | Map562: API contracts, negative cases and compatibility oracles; root executes HTTP/SDK. |
| 14 | `principal-security-auditor` | Fresh `i11_p11_security`, requested `gpt-6-sol`: Authority/security | Map350: broken access control, data integrity, revocation and privacy boundaries. |
| 15 | `principal-elixir-engineer` | Fresh `i11_p12_purge`, requested `gpt-6-sol`: Mounted supported-source purge | Map178: Elixir/Phoenix/LiveView, Ecto contexts and PubSub/OTP boundaries. |
| 16 | `principal-qa-api-curl` | Fresh `i11_p13_contract`, requested `gpt-6-sol`: Public compatibility | Map562: API contracts, negative cases and compatibility oracles; root executes HTTP/SDK. |
| 17 | `principal-security-auditor` | Fresh `i11_p14_privacy`, requested `gpt-6-sol`: Privacy lifecycle/restore | Map350: broken access control, data integrity, revocation and privacy boundaries. |
| 18 | `staff-qa-lead` | Fresh `i11_p15_oracle`, requested `gpt-6-sol`: Independent test oracle | Map734: meaningful cross-stack test gates and independent evidence. |
| 19 | `staff-tech-lead` | Fresh `i11_p16_ownership`, requested `gpt-6-sol`: Minimal substantial ownership | Map415: ADR/RFC decisions, technical risk, capacity and contract tradeoffs. |

Canonical runtime session identifiers, requested models and assigned paths are in `tmp/enhancement-program/11/planning-roster.json`. The runtime exposes task paths rather than a separate UUID. No replacement or reactivation is used to claim concurrency.

## Phases

### Phase 1: Frozen prior-outcome intake
- **Agent**: `staff-agent-orchestrator`
- **Input**: AGENTS, PROGRAM, PRODUCT_OUTCOME, conductor, all five ENTIRE iteration10 original retrospectives, ENTIRE13515B handoff, forward accepted evidence/result/root acceptance,25-anchor manifest and1320-file public source snapshot.
- **Activity**: Fullread the named prose/acceptance anchors and verify all25 physical anchor fingerprints plus all1320 source-copy fingerprints. Preserve09dissent and both task-rubric and mounted supported-purge alternatives; no scope preselection.
- **Deliverable**: `tmp/enhancement-program/11/conductor-intake-receipt.json`.
- **Done when**: Exact input manifest e98562b2…895 and source manifest a1378c95…726 match, with fullread versus hash/parse modes recorded honestly.
- **Handoff to**: Phase2, the sixteen named Principal/Staff originals and `staff-tech-lead`.
- **Estimated effort**: 0.35 person-hours.

### Phase 2: Independent bounded parallel proposals
- **Agent**: The sixteen named `gpt-6-sol` Principal/Staff planner sessions.
- **Input**: Identical frozen common anchors/full five originals/full handoff and distinct bounded actual-source lenses.
- **Activity**: Each original writes <=350word proposal and small fingerprint/read-mode audit, reports READY to conductor/Astra and stays RUNNING on <=45second waits. No peer11note reads before the initial proposal; no product/runtime/test execution. Retain actual initial READY bytes before any requested correction.
- **Deliverable**: Sixteen `docs/enhancement-program/iterations/11/planning/*.md`; `planning-final-originals.json`, assigned audits and actual initial READY copies under `tmp/enhancement-program/11/`.
- **Done when**: All16distinct final original proposals exist, each required fullread is declared and source fingerprints match. All16proposals total45623B, all<=350whitespacewords and unchanged from initialREADY; five metadata-only audit corrections retain exact original bytes.
- **Handoff to**: Phase3, `staff-tech-lead` (`i11_astra`).
- **Estimated effort**: 1.60 aggregate person-hours (16×0.10).

### Phase 3: One actual readiness barrier and independent decision
- **Agent**: `staff-agent-orchestrator` observes; `staff-tech-lead` adjudicates.
- **Input**: All16READY messages, all16final originals, original prior evidence and relevant frozen actual source.
- **Activity**: Capture one actual `collaboration.list_agents` with SAME16 original Sol sessions and Astra RUNNING after all16READY. Astra FULLREADS every final proposal, binds actual bytes/hashes, disposes every proposal against explicit outcome/coherence/evidence/reliability/boundedness rubric and selects ONE substantial connected slice, never a vote. Any necessary correction uses the same original after retaining real earlier bytes.
- **Deliverable**: `tmp/enhancement-program/11/planning-live-ready-barrier.json`, `docs/enhancement-program/iterations/11/decision.md`, `tmp/enhancement-program/11/astra-read-receipt.json`.
- **Done when**: Actual running barrier and16individual dispositions exist; ADR has exact public compatibility plus positive/negative/native/mutation/authority checks. Representative success must mean every frozen mandatory obligation SATISFIED and zero critical violations; observed/unmet/unknown/interrupted cannot be success. Owner assertion never becomes trusted Evaluation.Run/runtime/release qualification.
- **Handoff to**: Phase4, `staff-agent-orchestrator`.
- **Estimated effort**: 0.50 person-hours.

### Phase 4: Fullread, binding verification and release
- **Agent**: `staff-agent-orchestrator`
- **Input**: Sixteen final notes, Astra final ADR/read receipt and actual running-barrier evidence.
- **Activity**: FULLREAD all16final notes and the complete decision; parse/inspect receipt and independently verify every final binding. After actual barrier and final decision verification, RELEASE all16same originals plus Astra; observe their completions. Preserve earlier bytes and failed/unverified claims honestly.
- **Deliverable**: `tmp/enhancement-program/11/conductor-planning-completion.json` and final release/completion observation receipt.
- **Done when**: All original17child sessions actually complete following release, exact final artifacts remain bound, and no product/runtime/check execution occurred.
- **Handoff to**: Phase5, designated root `/root`.
- **Estimated effort**: 0.30 person-hours.

### Phase 5: Root acceptance and bounded implementation handoff
- **Agent**: `staff-agent-orchestrator`, designated root.
- **Input**: Full final ADR, all16final originals, this coordination plan and exact completion/binding evidence.
- **Activity**: Root accepts or revises scope. Only after acceptance/release, conductor obtains actual Guardrail, impediment-removal and Principal UI/UX adviser briefs and freezes a concrete interface/file ownership. At most3distinct product authors TOTAL includes root and every correction. Root alone executes all tests/format/Mix/build/Docker/runtime/browser/HTTP/SDK/process/DB checks and owns shared integration.
- **Deliverable**: Root-owned acceptance, adviser briefs and implementation interface; the current planning documents do not assert root acceptance or an implemented iteration.
- **Done when**: Root explicitly accepts the exact bounded scope, then releases named authors with disjoint files and independently testable handoffs.
- **Handoff to**: Implementation, mandatory `principal-code-reviewer` review-loop (max3focused rounds before Staff escalation), five NEW independent QA reports, then exactly five NEW independent retrospectives/full next handoff. Capability map331 supports code-review correctness/security/tests/docs; `staff-tech-lead` owns unresolved design risk. Runtime Principal UI/UX role is supported by the registry and prior conductor resolution. No production deployment is in scope; `principal-devops-sre` operational planning participates here and root owns local runtime.
- **Estimated effort**: 0.20 person-hours for root scope/dispatch; later implementation/QA effort follows scoped adviser/interface review.

## Effort summary

Estimates are rough aggregate person-hours, not elapsed-time promises or model telemetry.

| Phase | Agent | Effort |
|---|---|---|
| 1 | `staff-agent-orchestrator` | 0.35h |
| 2 | Sixteen original Principal/Staff planners | 1.60h |
| 3 | `staff-tech-lead` + conductor | 0.50h |
| 4 | `staff-agent-orchestrator` | 0.30h |
| 5 | Designated root coordinator | 0.20h |
| **Total** | | **2.95h** |

## Risks + mitigations

- **Risk**: Owner observations are relabelled successful or trusted → **Mitigation**: Freeze explicit rubric before results, require every mandatory result satisfied and no critical violation for owner success; never update trusted runs, release eligibility or runtime qualification.
- **Risk**: Outcome receipt becomes an isolated administrative form → **Mitigation**: Exact existing analysis-origin approved guidance, selected goal, approved plan and built package anchors; native end-to-end reviewed synthetic company journey.
- **Risk**: Task history adds sensitive retained bytes or resurrects authority on restore → **Mitigation**: Exact scoped lifecycle and dependency design in ADR/interface; source/workspace purge, backup/restore quarantine, foreign-workspace and predecessor checks before acceptance.
- **Risk**: Repeated proposals silently outweigh security/coherence/MCP → **Mitigation**: Explicit individual ADR dispositions; mounted completed-domain purge, approval-time coverage and focused own-MCP remain independent alternatives with reasons and limits.
- **Risk**: Hashing is misreported as semantic fullread or model requests as effective telemetry → **Mitigation**: Exact read-mode distinction, all16original-note fullreads, stored dispatch arguments and retained metadata-only correction history.
- **Risk**: Nominal READY replaces actual concurrency → **Mitigation**: Same16originals and Astra actually observed RUNNING after16READY, no replacements/reactivations; release only after the real barrier and final decision.
- **Risk**: More than three product authors or parallel native executors → **Mitigation**: Root author ledger/sole execution and board ownership; no delegate product/runtime work until explicit root release.
- **Risk**: Synthetic mechanics are treated as complete company reliability → **Mitigation**: Keep real company/model semantics, live connectors, managed agents, portable signer/revocation/per-client MCP, full accessibility, novice/time/cost and longitudinal outcomes unqualified.

## Escalation path

- If a planner exits before the real barrier, a final artifact changes or an actual binding fails → escalate to `staff-tech-lead` and root with actual roster, READY message, retained bytes and exact mismatch. Never replace/reactivate and present it as original concurrency.
- If privacy/authority/semantic boundary cannot fit the selected slice → escalate to `staff-tech-lead` and root with source counterexample and two bounded alternatives; do not silently expand scope or add authority.
- If implementation review still fails after3focused correction rounds → root escalates to `staff-tech-lead` with frozen source/evidence, remaining defect and distinct-author ledger.

## How to execute

For each phase, the user can invoke the agent via the running agents-ui (open the Chat tab and select the agent), or via CLI:

```bash
./bin/Codex -p --append-system-prompt-file ~/.Codex/agents/<slug>.md \
  "<the input for this phase>"
```

The authorized planning dispatch used collaboration tools, not agent CLI processes. Do not redispatch or reactivate the original cohort to claim concurrency. Root acceptance continues existing authorization; it is not a request for another user confirmation. Keep main85067/8865 and historical MCP untouched until root-controlled verification. The official iteration count remains10until implemented behavior, appropriate checks, five independent retrospectives and root acceptance complete.
