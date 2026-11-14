# Coordination Plan: HarnessForge iteration 14 UI/UX

**Classification**: planning
**Pattern**: composed: parallel-fan-out + map-reduce + review-loop
**Total agents involved**: 18 planning agents; Root separately owns acceptance/execution. Planning is accepted and released; actual completion is recorded in `tmp/enhancement-program/14/planning/completion-status.json`.

## Agents involved (in order of first involvement)

Capability citations refer to [Fleet Capability Map](/Users/<user>/.agents/skills/fleet-capability-map/SKILL.md).

| # | Agent | Role in this plan | Why this agent (cite the capability map) |
|---|---|---|---|
|1|`staff-agent-orchestrator`|Conductor/records|Map: coordination design and handoffs.|
|2|`staff-product-owner`|Sol01/02/05/10|Map: requirements, acceptance, prioritization.|
|3|`principal-elixir-engineer`|Sol03/06/08|Map: Phoenix LiveView and OTP depth.|
|4|`staff-documentation-writer`|Sol04/07|Map: information architecture.|
|5|`principal-code-reviewer`|Sol09/13|Map: correctness/security review.|
|6|`principal-qa-web-playwright`|Sol11/15|Map: web behavior/accessibility evidence.|
|7|`principal-typescript-frontend-engineer`|Sol12|Map: design-system architecture; inspect current HEEx/CSS only.|
|8|`principal-security-auditor`|Sol14|Map: authority/security boundaries.|
|9|`staff-tech-lead`|Sol16 and independent Astra|Map: architecture decisions, capacity, technical risk.|

All 16 investigators use fresh `gpt-6-sol`; the independent decision maker uses fresh `gpt-6-astra`, high. Exact task IDs/models are in the dispatch/barrier records. Distinct investigations own only `planning/NN-*.md` and corresponding `NN-read-audit.json`; no shared source ownership.

## Phases

### Phase 1: Independent investigations
- **Agent**: the 16 Sol assignments above.
- **Input**: full input manifest/mandatory originals, five iteration 13 retrospectives, entire handoff; bounded frozen source.
- **Activity**: investigate 16 distinct UX/source questions without selecting scope or executing code.
- **Deliverable**: 16 proposals (each ≤500 words) and 16 honest read/hash audits.
- **Done when**: each sends READY and remains running.
- **Handoff to**: Phase 2 `staff-agent-orchestrator`.
- **Estimated effort**: 4 person-hours aggregate; planning estimate, not measured labor.

### Phase 2: Live review barrier
- **Agent**: `staff-agent-orchestrator`; Root independently confirms.
- **Input**: all 16 READY messages and live `list_agents`.
- **Activity**: capture actual simultaneous running status, task IDs/model assignments/time; disclose reactivation if any.
- **Deliverable**: `tmp/enhancement-program/14/planning/concurrency-barrier.json`.
- **Done when**: Root acknowledges its own snapshot; no earlier scope finalization.
- **Handoff to**: Phase 3 `staff-tech-lead` (Astra).
- **Estimated effort**: 0.1 person-hours.

### Phase 3: Evidence-weighted decision
- **Agent**: `staff-tech-lead` (Astra).
- **Input**: all 16 original proposals/audits; mandatory originals; Root-accepted guardrail/impediment advice.
- **Activity**: disposition every proposal by code evidence, value, reliability and simplicity; preserve dissent, no voting.
- **Deliverable**: `decision.md` and `planning/astra-read-audit.json`.
- **Done when**: bounded UI scope, acceptance/recovery checks, alternatives and ≤3 implementation ownership lanes are explicit.
- **Handoff to**: Phase 4 Root.
- **Estimated effort**: 0.75 person-hours.

### Phase 4: Root acceptance and release
- **Agent**: Root; `staff-agent-orchestrator` records release.
- **Input**: complete decision/proposals/audits.
- **Activity**: full-read acceptance, release 16 planners, route later implementation through selected ownership. Root's accepted contract sets exactly three total authors: Root lane C/shared/executor, lane A projection, lane B corpus UX. Root retains board/shared files/runtime. Any code changes require separate `principal-code-reviewer` review and proportionate Root validation; cap review at 3 rounds.
- **Deliverable**: planning release record and Root implementation handoff.
- **Done when**: release acknowledged; implementation authority/owners recorded separately.
- **Handoff to**: Root-selected implementation team.
- **Estimated effort**: 0.5 person-hours, excluding implementation.

## Effort summary

|Phase|Agent|Effort|
|---|---|---|
|1|16 Sol investigators|4h|
|2|Conductor/Root|0.1h|
|3|Astra|0.75h|
|4|Root/Conductor|0.5h|
|**Total**||**5.35h estimate**|

## Risks + mitigations

- **Risk**: UI labels imply semantic/scale/task qualification → **Mitigation**: preserve unknown coverage, blocked evaluation and measured limits; functional debt stays in iteration 15.
- **Risk**: scope/authority drift or conflicting edits → **Mitigation**: inert planning, explicit file ownership, ≤3 later authors, Root shared-file integration.
- **Risk**: fabricated concurrency → **Mitigation**: actual snapshot plus Root acknowledgement; honestly record reactivation.

## Escalation path

- Missing evidence, barrier failure or 3 failed review loops → `staff-tech-lead` via Root with originals, audit and precise unresolved decision; no new authorization gates.

## How to execute

Root has already dispatched this plan through live agents. For later equivalent dispatch, use agents-ui or CLI:

```bash
./bin/Codex -p --append-system-prompt-file ~/.Codex/agents/<slug>.md \
  "Read the iteration14 packet and assigned ownership; honor the review barrier."
```

