# Coordination Plan: Iteration 13 corpus-to-reviewed-harness slice

**Classification**: multi-stack feature
**Pattern**: composed: sequential + parallel-fan-out + review-loop
**Total agents involved**: 7 execution roles, excluding completed 16-planner/Astra phase and mandated later five NEW retrospective reviewers

DRAFT for root acceptance. Contract: `adr-corpus-retrieval.md`; dispositions: `selection-decision.md`. Do not begin authors until root accepts interfaces and captures final original16 READY+RUNNING barrier, then parent releases planners. No dispatch by this document alone.

## Agents involved (in order of first involvement)

| # | Agent | Role in this plan | Why this agent (cite the capability map) |
|---|---|---|---|
| 1 | `staff-tech-lead` | Root integration/acceptance; conductor coordinates and removes impediments | Fleet Capability Map: architecture decisions, cross-repo planning and technical risk; root retains all commands/runtime/board/count |
| 2 | `principal-elixir-engineer` | Author A, corpus/capture/passages | Map: Phoenix contexts, OTP supervision, Ecto and background work |
| 3 | `principal-python-backend-engineer` | Author B, Graphiti worker/control adapter | Map: Python async structured concurrency, Pydantic v2 and packaging |
| 4 | `principal-code-reviewer` | Independent review loop | Map: correctness, security, performance, tests and observability |
| 5 | `principal-security-auditor` | Independent authority/privacy review; existing guardrail input retained | Map: OWASP, secrets and threat modeling |
| 6 | `staff-qa-lead` | Independent oracle/verification assessment | Map: test pyramid, quality gates and environment policy |
| 7 | `principal-qa-web-playwright` | Independent UI/UX and web flow evidence assessment | Map: visual regression, locators and web E2E quality; root alone runs native/runtime checks |

Capability reference: `/Users/<user>/.agents/skills/fleet-capability-map/SKILL.md`; pattern reference: `/Users/<user>/.agents/skills/multi-agent-coordination-patterns/SKILL.md`. These role names do not replace root ownership. Existing guardrail reviewer and conductor are advisers, no extra product/test writers.

## Phases

### Phase 1: Accept frozen interfaces and oracle
- **Agent**: `staff-tech-lead`
- **Input**: All16 dispositions, ADR, root oracle-freeze SHA `ed34669f018c88cd35114b6e30041275b6770985a3276271962e682ac66bef32`, guardrail timing amendment.
- **Activity**: Root accepts bounded contracts/ownership, records backend server qualification resolution tasks and protected oracle; conductor resolves impediments without changing scope.
- **Deliverable**: Root-owned `tmp/enhancement-program/13/root-selection-acceptance.json` and ownership entries on existing board.
- **Done when**: Final original16 READY+RUNNING evidence captured, planners released, root accepts ADR and frozen thresholds before source authors.
- **Handoff to**: Phase 2, `principal-elixir-engineer` and `principal-python-backend-engineer` with same accepted contract.
- **Estimated effort**: 8 person-hours.

### Phase 2: Implement one connected slice in three owned lanes
- **Agent**: `principal-elixir-engineer`, `principal-python-backend-engineer`, root `staff-tech-lead`.
- **Input**: Accepted ADR and source-before; existing approval/export/inspector code, pinned Graphiti source; independent oracle remains protected.
- **Activity**: A owns `evidence/corpora*`, `evidence/capture*`, `evidence/passages*`, `company/retrieval*`, local-import/job extensions and their tests. B owns `priv/graphiti_worker/`, dependency/license lock, `graphiti/` Elixir IPC facade, `models/stages*`, `models/attempt_gateway*` and their tests. Root owns existing `company.ex`, analysis/output/origin/harness eligibility, existing model configuration/ledger seams, privacy/restore, UI/MCP integration, all shared config/router/application/migrations and integration tests. Agree exact file list before edits; preserve others' changes.
- **Deliverable**: Candidate source plus per-lane contract evidence; worker lock records actual server version/digest/license, not a guessed pin.
- **Done when**: CorpusRun/status/passages/origin/attempt/worker DTOs match ADR; actual capture→review→export path is ready for root checks. Exactly ≤3 product/test authors including root; no fourth author for QA fixes.
- **Handoff to**: Phase 3, `principal-code-reviewer`, `principal-security-auditor`, `staff-qa-lead`, `principal-qa-web-playwright` receive frozen diff/source/evidence.
- **Estimated effort**: 128 person-hours (root32 + A48 + B48); bounds are planning estimates, overlapping proposal day estimates are not additive.

### Phase 3: Independent review loop and targeted correction
- **Agent**: `principal-code-reviewer`, `principal-security-auditor`, `staff-qa-lead`, `principal-qa-web-playwright`.
- **Input**: Frozen candidate, accepted ADR, protected oracle and root-executed checks with exact commands/exit codes/hashes.
- **Activity**: Independently assess real upstream/backend reuse, per-attempt/closure/privacy controls, all-input/new-member invalidation, capture resume, actual target bytes, UI recovery and honest evaluation limits. Reviewers write reports only; original three authors fix, root runs checks.
- **Deliverable**: `docs/enhancement-program/iterations/13/qa/{code,security,quality,web-uiux}.md` and explicit findings/verdicts.
- **Done when**: Blocking findings corrected and same reviewers recheck; maximum three loops before root escalation. Unavailable semantic/runtime cells remain distinct from failed mechanics.
- **Handoff to**: Phase 4, root `staff-tech-lead` with approved source and unresolved qualification inventory.
- **Estimated effort**: 20 person-hours.

### Phase 4: Root verification, installation decision and later retrospective gate
- **Agent**: `staff-tech-lead` with `staff-qa-lead` evidence assessment.
- **Input**: Accepted reviews and fresh actual capture/retrieval/export results; frozen seven questions/eight obligations.
- **Activity**: Root executes matched FTS/candidate and representative comparisons, records actual bytes and no-pass cells; handles authorized local installation only after evidence acceptance. Conductor then arranges five further NEW independent retrospectives and full handoff under PROGRAM.
- **Deliverable**: `docs/enhancement-program/iterations/13/verification.md`, SSD logs/manifests and root-owned acceptance/count decision.
- **Done when**: Entire connected path and mandatory mechanics are evidenced, failed checks corrected, unavailable limits candidly retained, five new retrospectives/full handoff consumed; no planning-only count.
- **Handoff to**: Next fresh alternating iteration only after root closure.
- **Estimated effort**: 20 person-hours, excluding later retrospective team.

## Effort summary

| Phase | Agent | Effort |
|---|---|---|
| 1 | `staff-tech-lead` | 8 h |
| 2 | `staff-tech-lead` + `principal-elixir-engineer` + `principal-python-backend-engineer` | 128 h |
| 3 | `principal-code-reviewer` + independent security/QA roles above | 20 h |
| 4 | `staff-tech-lead` + `staff-qa-lead` | 20 h |
| **Total** | | **176 h** |

## Risks + mitigations

- **Risk**: Hidden upstream provider attempts or summary ancestry escape authority → **Mitigation**: transport-level attempt admission, closure tests and deny graph operations until proven.
- **Risk**: Backend/model unavailable becomes fictional PASS → **Mitigation**: actual backend mechanics qualification and explicit UNAVAILABLE semantic/task cells; retain all12 P2/P3/496-query/Dialyzer/Docker/MCP/runtime limits.

## Escalation path

- If a phase stalls or three review loops fail → escalate to `staff-tech-lead` (root) with accepted contract, exact failing command/output, source hashes, smallest reproducer, retained dissent and two bounded alternatives; no silent scope reduction or repeated permission request.

## How to execute

For each phase, the user can invoke the agent via the running agents-ui (open the Chat tab and select the agent), or via CLI. Here root/conductor already owns dispatch; the example is documentation, not permission for worker CLI agents:

```bash
./bin/Codex -p --append-system-prompt-file ~/.Codex/agents/<slug>.md \
  "Read accepted iteration13 ADR and engineering-handoff; perform assigned phase/file ownership; preserve others' edits; root alone runs commands/runtime and writes board/count."
```
