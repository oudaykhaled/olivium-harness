# Coordination Plan: Iteration 13 corpus-to-reviewed-harness planning

**Classification**: multi-stack feature
**Pattern**: composed: parallel-fan-out + map-reduce + handoff + review-loop
**Total agents involved**: 20 in this planning stage (root, conductor, fresh guardrail, 16 fresh Sol planners, one fresh Astra); later implementation/QA/retro identities require root phase release.

## Agents involved (in order of first involvement)

The independent planner instances use `default` roles with explicit `gpt-6-sol` models; capability-map matches below explain lens allocation, not a claim that specialist personas were loaded. Exact task identities/models/hashes are in `tmp/enhancement-program/13/planning-dispatch-manifest-01.json`.

| # | Agent | Role in this plan | Why this agent (cite the capability map) |
|---|---|---|---|
| 1 | `/root` | Final acceptance, board/count/runtime owner | `staff-agent-orchestrator`: coordination and specialty boundaries; root authority is repository AGENTS/PROGRAM. |
| 2 | `/root/i13_conductor` | Intake, custody, dispatch and handoff | `staff-agent-orchestrator`: capability matching, handoff signals and explicit escalation. |
| 3 | `/root/i13_conductor/guardrail` | Fresh request-scoped guardrail and same-owner wording amendment | Actual available `Guardrail Agent`, explicitly required by root; current capability-map snapshot omits this newer role, so no map excerpt is invented. |
| 4 | `/root/i13_conductor/p01` | Product falsifiers | Map `staff-product-owner`: product stories/prioritization. |
| 5 | `/root/i13_conductor/p02` | Resumable capture | Map `principal-elixir-engineer`: Ecto transactions and background work. |
| 6 | `/root/i13_conductor/p03` | Membership/generations | Map `principal-data-engineer`: schema, modeling, tombstones. |
| 7 | `/root/i13_conductor/p04` | Exact passage/FTS baseline | Map `principal-data-engineer`: query plans and indexing. |
| 8 | `/root/i13_conductor/p05` | Real Graphiti episodes/temporal source | Map `principal-python-backend-engineer`: Python backend integration. |
| 9 | `/root/i13_conductor/p06` | Real Jev/runtime/routes source | Map `principal-ml-engineer`: model routing and evaluation. |
| 10 | `/root/i13_conductor/p07` | Backend/worker boundary | Map `principal-devops-sre`: Docker, dependency and operational lifecycle. |
| 11 | `/root/i13_conductor/p08` | Origin dependency closure | Map `principal-data-engineer`: modeling and durable ownership. |
| 12 | `/root/i13_conductor/p09` | Contrary evidence/chronology | Map `principal-ml-engineer`: retrieval/evaluation specialty. |
| 13 | `/root/i13_conductor/p10` | Attempt consent/budgets/cancellation | Map `principal-security-auditor`: security and boundary controls. |
| 14 | `/root/i13_conductor/p11` | Tombstone/removal/rebuild | Map `principal-security-auditor`: security review and failure boundaries. |
| 15 | `/root/i13_conductor/p12` | Exact review/plan/export | Map `principal-code-reviewer`: correctness, security, tests. |
| 16 | `/root/i13_conductor/p13` | Critical oracle/task evaluation | Map `principal-backend-qa-lead`: contract strategy and performance budgets. |
| 17 | `/root/i13_conductor/p14` | Usability/own MCP consistency | Map `principal-qa-web-playwright`: user-path and visual quality. |
| 18 | `/root/i13_conductor/p15` | Bounds/backpressure/query cost | Map `principal-elixir-engineer`: OTP/background work/BEAM observability. |
| 19 | `/root/i13_conductor/p16` | Adversarial minimality/interfaces | Map `staff-tech-lead`: architecture/ADR and risk management. |
| 20 | `/root/i13_conductor/astra` | Fresh `gpt-6-astra` arbiter | Map `staff-tech-lead`: ADR/architecture arbitration; explicit rubric, never voting. |

## Phases

### Phase 1: Binding intake and fresh guardrail
- **Agent**: `/root/i13_conductor`, `/root/i13_conductor/guardrail`
- **Input**: AGENTS/PROGRAM/outcome/reuse steering, all five original12 retros, complete12 handoff, root13 intent, frozen public source, REUSE-DECISION first.
- **Activity**: Fully read binding originals; separate hard authority from unresolved schema/backend decisions. No product/runtime work.
- **Deliverable**: `tmp/enhancement-program/13/conductor-intake-read-01.json`, `planning-guardrails.md`, `guardrail-read-audit.json`, `guardrail-amendment-01.json`.
- **Done when**: Root accepts request-scoped brief; fingerprints match. Original7302B wording remains byteexact archived; corrected7406B wording freezes oracle before code and measures candidate afterward.
- **Handoff to**: Phase2 (`/root/i13_conductor/p01`–`p16`).
- **Estimated effort**: 1 person-hour.

### Phase 2: Sixteen independent source-backed proposals
- **Agent**: `/root/i13_conductor/p01`–`p16`
- **Input**: Same mandatory full originals, guardrail and reuse decision, then distinct small public/pinned-source focus.
- **Activity**: Independently seal 300–500-word proposals and honest FULL/PARTIAL read audits; remain READY and RUNNING without replacements/reactivation.
- **Deliverable**: `planning/01-connected-product.md` through `planning/16-minimal-contracts.md`; exact paths/hashes in `tmp/enhancement-program/13/planning-originals-manifest-01.json`.
- **Done when**: All16 READY receipts; original bodies/audits sealed; initial genuine all16 RUNNING captured independently by root.
- **Handoff to**: Phase3 (`/root/i13_conductor/astra`).
- **Estimated effort**: 4 person-hours aggregate.

### Phase 3: Evidence-based scope and contracts
- **Agent**: `/root/i13_conductor/astra`
- **Input**: Full16 originals/audits, pinned Graphiti source, root independent public oracle and all shared intake.
- **Activity**: Full-read every original; apply mandatory connected-outcome/authority/reuse gates and explicit value/correctness/testability/minimality rubric; preserve dissent in all16 dispositions and ADR alternatives.
- **Deliverable**: `selection-decision.md`, draft `adr-corpus-retrieval.md`, draft `engineering-handoff.md`, `tmp/enhancement-program/13/astra-read-audit.json`.
- **Done when**: All16 dispositions and source-backed interfaces sealed; no schema/backend/server contract is accepted merely by drafting.
- **Handoff to**: Phase4 (`/root`).
- **Estimated effort**: 1 person-hour.

### Phase 4: Root acceptance and final live barrier
- **Agent**: `/root`, `/root/i13_conductor`
- **Input**: Entire selected ADR/handoff plus all16 original bodies, exact audits, frozen oracle.
- **Activity**: Root independently reads and accepts or returns concrete interface changes; captures genuine all16 READY+RUNNING AFTER Astra full-read/dispositions, then authorizes planner release.
- **Deliverable**: Root-owned acceptance/barrier record; conductor-owned release receipt and final planning handoff.
- **Done when**: Original planners are explicitly released and observed completed; root alone releases implementation phase.
- **Handoff to**: Root-appointed implementation/advisory team, with `principal-code-reviewer` review loop and independent QA required by PROGRAM. At most root+two other product/test authors; root owns shared integration/runtime/checks.
- **Estimated effort**: 1 person-hour.

## Effort summary

| Phase | Agent | Effort |
|---|---|---|
| 1 | conductor + guardrail | 1h |
| 2 | 16 original Sol planners | 4h aggregate |
| 3 | fresh Astra | 1h |
| 4 | root + conductor | 1h |
| **Total** | | **7h planning estimate; elapsed agent time is not measured person-hours** |

## Risks + mitigations

- **Risk**: Graphiti research is mistaken for product/backend/model qualification → **Mitigation**: actual upstream integration and backend cells, frozen critical oracle, explicit unavailable semantics;51offline passes remain research.
- **Risk**: New contrary members preserve stale approved guidance → **Mitigation**: server-owned versioned origin and explicit corpus-generation invalidation acceptance before review/build/export.
- **Risk**: Scope expands past one useful journey → **Mitigation**: Astra gates connected larger-corpus-to-corrected-export/evaluation value; root accepts exact interfaces before authors, no isolated infrastructure count.
- **Risk**: Coordination records substitute for live concurrence → **Mitigation**: root captures direct agent states after Astra dispositions; no final barrier from task receipts or reactivation.

## Escalation path

- If candidate contracts cannot meet a core gate → escalate to root acting as `staff-tech-lead` with original proposal, source lines, failing contract, alternatives and impact; do not silently weaken the outcome.
- If review later exceeds three correction cycles → root assigns `staff-tech-lead`; keep all failing evidence and unverified cells.

## How to execute

This stage is already running through native collaboration tools with explicit original model identities. No CLI agents are authorized in this workspace. For future separately authorized CLI use, the fleet's conventional form is:

```bash
./bin/Codex -p --append-system-prompt-file ~/.Codex/agents/<slug>.md \
  "<the input for this phase>"
```

Do not run that command in this task. Root releases later phases; this document authorizes no runtime, private import, inference spending, publication or generated-harness host execution.
