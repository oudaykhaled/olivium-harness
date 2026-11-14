# Coordination Plan: Iteration 10 company evidence review

**Classification**: planning
**Pattern**: composed: map-reduce + sequential handoff + review-loop
**Total agents involved**: 19

This document covers the authorized planning handoff: root, this conductor, one NEW Astra decision maker and sixteen NEW original Sol planners. All seventeen child sessions were explicitly dispatched fork-none with the requested models and no reasoning override. Dispatch arguments establish requested models; effective backend model telemetry is not claimed. Future implementation/adviser/QA/retrospective roles are requirements for the next handoff, not already-dispatched actors.

## Agents involved (in order of first involvement)

Capability citations refer to `/Users/<user>/.agents/skills/fleet-capability-map/SKILL.md`: capability index lines33–71 and the named agent's “When to invoke” entry. The root row describes coordination responsibility, not an assertion about root's dispatched profile/model.

| # | Agent | Role in this plan | Why this agent (cite the capability map) |
|---|---|---|---|
| 1 | `staff-agent-orchestrator` | Designated root `/root`: scope acceptance, sole execution/board/state/results owner | Map458: fleet capability matching and multi-agent coordination; root remains the designated session authority. |
| 2 | `staff-agent-orchestrator` | `/root/i10_conductor`: intake, bounded dispatch, actual barrier, handoff | Map458: coordination-plan design and explicit handoffs. |
| 3 | `staff-tech-lead` | NEW `i10_astra`, requested `gpt-6-astra`: independent ADR/dispositions | Map415: architecture decisions, ADR/RFC, capacity and technical risk. |
| 4 | `staff-product-owner` | NEW Sol01 `p01_analysis_entry`: connected entry | Map64: product story/prioritization and owner outcomes. |
| 5 | `staff-documentation-writer` | NEW Sol02 `p02_guide_discovery`: wayfinding | Map365: documentation information architecture. |
| 6 | `principal-elixir-engineer` | NEW Sol03 `p03_pinned_identity`: retained revision metadata | Map50: Elixir/Phoenix/OTP specialty. |
| 7 | `principal-security-auditor` | NEW Sol04 `p04_safe_metadata`: unsafe/missing links | Map62 and auditor entry: security boundaries and input safety. |
| 8 | `staff-tech-lead` | NEW Sol05 `p05_conflict_review`: original/current distinction | Map415: ADR tradeoffs and technical risk. |
| 9 | `principal-qa-web-playwright` | NEW Sol06 `p06_keyboard_focus`: keyboard/focus evidence plan | Map720: browser, visual and web-e2e quality. Read-only planning; root executes browsers. |
| 10 | `principal-frontend-perf-engineer` | NEW Sol07 `p07_width_zoom`: long metadata/reflow | Map750: web performance and rendering specialty. |
| 11 | `principal-elixir-engineer` | NEW Sol08 `p08_stale_recovery`: exact refusal/recovery reasons | Map50: Phoenix state/event and backend contracts. |
| 12 | `principal-security-auditor` | NEW Sol09 `p09_privacy_refresh`: active data authority | Map62: security, scopes and revocation boundaries. |
| 13 | `staff-product-owner` | NEW Sol10 `p10_plan_continuation`: exact claim/goal continuation | Map64: user journey and acceptance criteria. |
| 14 | `staff-documentation-writer` | NEW Sol11 `p11_novice_readability`: qualified language | Map365: clear user guidance/information architecture. |
| 15 | `principal-qa-api-curl` | NEW Sol12 `p12_mcp_presentation`: portal/MCP disclosure consistency | Map59: API contract testing; no HTTP/SDK operations delegated. |
| 16 | `staff-qa-lead` | NEW Sol13 `p13_regression_evidence`: independent oracles/accounting | Map736: quality gates and test strategy. |
| 17 | `principal-code-reviewer` | NEW Sol14 `p14_minimal_ownership`: reuse/blast radius | Map331: correctness, security, performance, tests and review. This is planning, not final implementation review. |
| 18 | `staff-tech-lead` | NEW Sol15 `p15_company_outcome`: company value tradeoff | Map415: architectural tradeoffs and risk. |
| 19 | `principal-elixir-engineer` | NEW Sol16 `p16_missing_model`: inference versus approved-data authority | Map50: Elixir/Phoenix contracts; no fallback or runtime changes. |

Canonical child identifiers and exact dispatch arguments are retained in `tmp/enhancement-program/10/conductor-planning-dispatch.json`. Capability candidates also included `principal-qa-elixir`, `principal-typescript-frontend-engineer` and `principal-devops-sre`; they were not added to this planning phase because it has no runtime, dependency, deployment or TypeScript implementation work.

## Phases

### Phase 1: Original intake and preserved dissent
- **Agent**: `staff-agent-orchestrator`
- **Input**: All five09 original retrospectives, entire09 handoff, AGENTS, PRODUCT_OUTCOME, verification/install records, accepted evidence, iteration result/root closure and10 root facts/anchors.
- **Activity**: Full-read originals before dispatch; verify exact anchor fingerprints and retain source-recognition versus stale-recovery/Guide and all11/08 disagreements.
- **Deliverable**: `tmp/enhancement-program/10/conductor-intake.json`.
- **Done when**: Five originals30,913B and full handoff11,945B actually read; root acknowledged intake; no10 product/runtime changes.
- **Handoff to**: Phase2, the16 named Sol planners and `staff-tech-lead`.
- **Estimated effort**: 0.35 person-hours.

### Phase 2: Sixteen independent concurrent proposals
- **Agent**: The sixteen named Principal/Staff planner instances above, each requested `gpt-6-sol`.
- **Input**: Same five complete originals/full handoff, PRODUCT_OUTCOME/AGENTS and one distinct connected UI/UX lens; only relevant source reads.
- **Activity**: Write ≤350word independent proposals, code references, company benefit, positive/negative/recovery oracles and unchanged boundaries; send READY to Astra/conductor and stay actually RUNNING on bounded waits until RELEASE.
- **Deliverable**: Sixteen distinct `docs/enhancement-program/iterations/10/planning/*.md`; dispatch and final-read receipts.
- **Done when**: SAME16 original authors finalREADY; each final hash independently matches retained bytes; no peer proposal reads, replacements/reactivations or specialist execution.
- **Handoff to**: Phase3, `staff-tech-lead` (`i10_astra`).
- **Estimated effort**: 1.60 person-hours total, sixteen ×0.10. Wall time benefits from parallel independent lenses.

### Phase 3: Evidence-based scope selection
- **Agent**: `staff-tech-lead`, requested `gpt-6-astra`.
- **Input**: All16 final proposals52,431B, full prior originals/handoff, relevant real data model/report code.
- **Activity**: Full-read/dispose each proposal; compare review-at-decision benefit versus stale-build recovery, Guide/model entry and continuation by outcome/blast radius. No vote, majority or repetition selection.
- **Deliverable**: `docs/enhancement-program/iterations/10/decision.md` and `tmp/enhancement-program/10/astra-read-receipt.json`.
- **Done when**: ADR selects ONE connected benefit;16 individual dispositions/full hashes; corrected files reread; Astra FINAL_READY and remains actually running.
- **Handoff to**: Phase4, `staff-agent-orchestrator`.
- **Estimated effort**: 0.45 person-hours.

### Phase 4: Actual barrier and same-original completion
- **Agent**: `staff-agent-orchestrator`.
- **Input**: All16 finalREADY, Astra's exact final ADR/receipt, actual collaboration roster.
- **Activity**: Full-read16 finals/ADR/receipt; observe SAME16 original Sols plus Astra RUNNING after final disposition; hash-bind snapshot; only then RELEASE same originals and require actual completions.
- **Deliverable**: `conductor-proposals-fullread.json`, `conductor-readiness-messages.json`, `conductor-final-running-barrier.json` and `conductor-planning-completion.json`, all under `tmp/enhancement-program/10/`.
- **Done when**: Actual tool evidence shows all16 original planners completed after RELEASE, final files unchanged, and Astra completed. No author role released.
- **Handoff to**: Phase5, designated root `/root`.
- **Estimated effort**: 0.30 person-hours.

### Phase 5: Root scope acceptance and implementation handoff
- **Agent**: `staff-agent-orchestrator`, designated root.
- **Input**: Full final ADR/receipt, this coordination plan, exact original-running/completion evidence and untouched10 baseline.
- **Activity**: Accept/revise the bounded scope, then request fresh actual Guardrail, impediment, Principal engineer and expert UI/UX advice/implementation. Root controls author release and all execution.
- **Deliverable**: Root-owned acceptance/next-phase dispatch; no acceptance is asserted by this document.
- **Done when**: Root explicitly accepts scoped ADR after original16 completion evidence. Future implementation ownership is concrete and max3 distinct product authors includes root/corrections.
- **Handoff to**: Root-directed implementation and `principal-code-reviewer` review-loop, then independent evidence QA and exactly five NEW independent retrospectives/full handoff.
- **Estimated effort**: 0.20 person-hours for scope/dispatch; implementation/QA/retrospectives are estimated by root after advice.

## Effort summary

These are rough person-hour estimates, not elapsed-time or model telemetry.

| Phase | Agent | Effort |
|---|---|---|
| 1 | `staff-agent-orchestrator` | 0.35h |
| 2 | Sixteen original Principal/Staff planners | 1.60h |
| 3 | `staff-tech-lead` | 0.45h |
| 4 | `staff-agent-orchestrator` | 0.30h |
| 5 | Designated root coordinator | 0.20h |
| **Total** | | **2.90h** |

## Risks + mitigations

- **Risk**: Mutable title or latest capture is misrepresented as history → **Mitigation**: mandatory CURRENT-name label; source/revision/bodyhash exact-match display gate; old/missing/unsafe metadata gets explicit fallback without new lookup.
- **Risk**: Nominal READY is mistaken for concurrency → **Mitigation**: original16 actually held RUNNING; final real tool roster after Astra dispositions; same-original RELEASE and actual completed observation.
- **Risk**: A useful report change misses Evidence's actual approval surface → **Mitigation**: shared component contract in BOTH Company and Evidence with already-loaded gated data.
- **Risk**: In-place factual amendments overstate historical hash proof → **Mitigation**: final retained bytes only are independently bound; initial READY hashes are reported message provenance, pre-correction copies were not separately retained. Eight renewed READY payloads are preserved. No reconstruction.
- **Risk**: View operation renews authority, leaks context or loses dirty guidance → **Mitigation**: pure projection/no I/O or events; exact no-side-effect, privacy/reset/late-event and dirty/link-return oracles before claiming completion.
- **Risk**: Scope grows into stale recovery, Guide, historical retrieval or11 functionality → **Mitigation**: ADR explicit alternatives/non-goals; preserve each dissent without adding it to10.
- **Risk**: Synthetic reachability is promoted to full company reliability → **Mitigation**: retain real-company/model, coherent obligations, owner tasks, live connectors, managed agents, Linux, portable authority, WCAG/novice/log/longitudinal limits.
- **Risk**: More than three product authors or competing runtime execution → **Mitigation**: root alone releases ≤3 total authors and executes all runtime/checks. This planning phase performs none.

## Escalation path

- If any original planner prematurely completes or a final hash changes before the barrier → escalate to `staff-tech-lead` and root with actual roster, READY messages, affected retained bytes and dispatch identity. Report the failed condition honestly; no replacement/reactivation fiction.
- If scoped advice finds a real privacy/authority or retained-metadata defect → escalate to `staff-tech-lead` with exact source path, counterexample and two bounded alternatives; root decides scope. No automatic historical API or access expansion.
- If implementation review requests changes beyond three focused review rounds → root escalates to `staff-tech-lead` with frozen source/evidence, remaining defect and author-count ledger.

## How to execute

For each phase, the user can invoke the agent via the running agents-ui (open the Chat tab and select the agent), or via CLI:

```bash
./bin/Codex -p --append-system-prompt-file ~/.Codex/agents/<slug>.md \
  "<the input for this phase>"
```

The authorized planning dispatch already used native collaboration tools; no agent CLI/process was executed. Do not redispatch the frozen planners. Root's acceptance triggers the next authorized work within existing permissions; it is not a new user approval gate. This standalone OSS repository requires no private Olivium atlas or build-orchestrator-v2 protocol.

The selected product contract is in the ADR: accurately qualified evidence at exact recommendation review, shared Company/Evidence rendering, already-loaded exact active source/revision/bodyhash gate, CURRENT name, capture date/safe stored link or explicit unavailable fallback, full pins/spans, zero view side effects. Historical query/schema, Guide, stale-build remedy, mounted-purge freshness, MCP and model/runtime settings remain outside10. Root should retain actual320/390 ×100/200 keyboard/reflow observations, downstream exact approvals/export noninterference and independent code/security/UX evidence before local installation; the eventual five NEW retrospectives must answer the exact mandated company-usefulness/reliability question and preserve dissent.
