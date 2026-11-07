# Coordination Plan: Iteration08 independent source and test-oracle review

**Classification**: review
**Pattern**: composed: parallel-fan-out + review-loop + handoff
**Total agents involved**: 7 in this review phase, including root and conductor; the same three product authors remain on hold for any corrections

## Agents involved (in order of first involvement)

Capability citations refer to `/Users/<user>/.agents/skills/fleet-capability-map/SKILL.md`. Exact fresh task IDs, default-model requests, fork-none settings and initial messages are in `tmp/enhancement-program/08/independent-qa/conductor-dispatch-01.json`.

| # | Agent | Role in this plan | Why this agent (cite the capability map) |
|---|---|---|---|
| 1 | `staff-agent-orchestrator` | Root and conductor | Explicit specialty boundaries, coordination and handoffs |
| 2 | `principal-code-reviewer` | Independent code/test-oracle review | Correctness, security, performance and meaningful tests |
| 3 | `principal-security-auditor` | Independent privacy/input/focus review | Input trust, access control, injection and integrity controls |
| 4 | `principal-qa-api-curl` | Source/contract/identity QA without HTTP execution | API contracts, negative and smoke-test oracles |
| 5 | `principal-qa-web-playwright` | JS/browser-plan QA without execution | Browser behavior, accessibility locators and visual evidence |
| 6 | **Principal UI/UX Engineer** (exact supported runtime role) | Independent UI/UX review | Existing conductor contract resolves older capability-map omission; copy, accessibility and design-to-production review |

## Phases

### Phase 1: Bind frozen inputs — complete

- **Agent**: `staff-agent-orchestrator`
- **Input**: Accepted ADR/interface, root source-freeze01, root logs/helper and source-binding records.
- **Activity**: Verify 1004 actual copies and five current product files. Bind finished focused/canonical/static evidence; preserve failed focused01 and wrong-environment Dialyzer01. Native binding is source evidence, while actual journey remains pending.
- **Deliverable**: `independent-qa/input-manifest-01.json`, `input-supplement-01.json`, `conductor-intake-01.json`.
- **Done when**: Frozen copies match; source/test case identities and pending-native limits are explicit.
- **Handoff to**: Phase 2 (five independent reviewers).
- **Estimated effort**: 0.2 person-hours.

### Phase 2: Five original independent reports — active

- **Agent**: Five fresh supported validator roles above; no delegation.
- **Input**: Identical source/evidence packet plus distinct lens and exclusive report/audit path.
- **Activity**: Read/hash/source review only. Parse actual case identities and root command outcomes; assess classifier, input/draft/reset/focus/privacy and real-domain oracles. No peer/author report reading or runtime execution. Each freezes its first source/test-oracle report with NATIVE PENDING.
- **Deliverable**: `review/qa-{code,security,api,web,uiux}-01.md` and scoped `independent-qa/*-01-audit.json`.
- **Done when**: Five original frozen reports, input/source accounting and explicit findings/limits exist; individual actual completions verified.
- **Handoff to**: Root full-read and Phase 3; no vote or aggregate acceptance.
- **Estimated effort**: 1.0–2.0 aggregate person-hours.

### Phase 3: Evidence-led corrections and native followup — root-controlled

- **Agent**: Root plus the same A/B/root product authors and same independent reviewers.
- **Input**: Exact source findings and root's subsequent native packet.
- **Activity**: Return material findings to original owners only; at most three review rounds. Root alone executes Mix/tests/format/build/Docker/native/browser/HTTP/DB/process operations. Revisions and native reviews use new announced paths, preserving first originals. Qualified07 Docker reuse stays labeled historical reuse with exact dependency hashes.
- **Deliverable**: Corrected source if necessary, root source-bound native evidence, separate independent followup verdicts.
- **Done when**: Root accepts selected behavior and material corrections against final source; original first reports remain intact.
- **Handoff to**: Root's later acceptance/install/retrospective decision, outside this dispatch.
- **Estimated effort**: 0.5–2.0 aggregate person-hours, dependent on actual findings.

## Effort summary

| Phase | Agent | Effort |
|---|---|---|
|1|Conductor|0.2h|
|2|Five independent validators|1.0–2.0h|
|3|Same authors/reviewers under root|0.5–2.0h|
|**Total**||**1.7–4.2 aggregate hours**|

## Risks + mitigations

- **Risk**: Source or synthetic DOM results are called native verification → **Mitigation**: First originals explicitly retain native-pending status; later actual images/DOM/zoom receive separate review.
- **Risk**: A passing count hides weak or confounded oracles → **Mitigation**: Independently parse exact identities, inspect real-domain premises and preserve failed focused01/test-environment Dialyzer evidence.
- **Risk**: Review consensus replaces evidence → **Mitigation**: Each original is independent and frozen; root full-reads them and selects corrective work by findings, not votes.
- **Risk**: Review expands authors or runtime authority → **Mitigation**: Same three distinct authors, disjoint ownership, root-only execution and three-round escalation.

## Escalation path

- Material finding or third failed correction round → root and `staff-tech-lead`, with exact trigger, source line, failing evidence and smallest proposed repair; no fresh author, permission/study gate or silent scope expansion.

## How to execute

Only supported collaboration tools dispatch agents. This plan creates five independent review tasks; it does not authorize main installation, goal-count changes, retrospectives or publication. Root is sole board/state/runtime writer and final acceptance authority. Current progress remains 7/50.
