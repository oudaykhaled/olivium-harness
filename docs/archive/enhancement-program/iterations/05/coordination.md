# Coordination Plan: HarnessForge iteration 05 functionality

**Classification**: implementation
**Pattern**: composed: map-reduce + sequential + review-loop
**Total agents involved**: approximately34 including root/conductor; at most21 active, planning19. Actual dispatch identities/evidence are authoritative.

## Agents involved (in order of first involvement)

Capability citations refer to `/Users/<user>/.agents/skills/fleet-capability-map/SKILL.md`. Exact supported runtime labels are used for dispatch.

| # | Agent | Role in this plan | Why this agent (cite the capability map) |
|---|---|---|---|
|1|`staff-agent-orchestrator`|Root and fresh conductor|Meta-orchestration, bounded handoffs and sole root ledger ownership|
|2|`staff-product-owner`|Fresh Sol product lenses|Operator jobs and falsifiable acceptance|
|3|`principal-elixir-engineer`|Fresh Sol source lenses; two disjoint principal authors|Ecto, Phoenix/LiveView and Elixir context ownership|
|4|`principal-security-auditor`|Planning and independent security review|Authority, secrets, data integrity and lifecycle review|
|5|`principal-devops-sre`|Sol route-failure planning lens|Capability index: Docker and operational failure boundaries|
|6|`staff-qa-lead`|Sol evidence lenses and quality retrospective|Meaningful gates and evidence limits|
|7|`principal-data-engineer`|Sol migration and compatibility lens|Capability index: database schema, migrations and immutable data|
|8|`principal-qa-api-curl`|Sol company-admission planning lens|Contract and negative-path testing|
|9|`principal-qa-web-playwright`|Planning and independent web validation|Actual browser behavior and accessibility locators|
|10|`staff-tech-lead`|Sol architecture lens, fresh Astra decision and impediment advice|Architecture/ADR, blast radius and technical risk|
|11|`principal-backend-qa-lead`|Independent serialized regression and fresh Docker execution|Capability index: backend/API quality strategy and test gates|
|12|`principal-code-reviewer`|Independent code review|Correctness, security, tests and maintainability|

**Principal UI/UX Engineer** is an actually supported runtime role despite the older map's omission; its first involvement was Sol planner06, followed by pre-edit direction/docs-only work and a fresh independent UX reviewer. **Guardrail Agent** supplied the pre-edit brief and later reviewed private QA instrumentation. Advisors and docs-only work do not become extra product implementation authors. The table reflects selected runtime roles; no documentation-writer session was dispatched. No agent was dispatched by Astra; root/conductor own scheduling.

## Phases

### Phase 1: Prior gate and sixteen concurrent proposals
- **Agent**: Root/conductor and sixteen new `gpt-6-sol` planners, fork_turns none.
- **Input**: PROGRAM, conductor, all five original04 retrospectives, handoff/verification,03 accepted amendment and05 input manifest/current source.
- **Activity**: Distinct <=350-word reports; all remain active until conductor release. Preserve prior goal-origin/conflict/current-route disagreement.
- **Deliverable**: `planning/01..16-*.md`; actual task/model concurrency and final fingerprints on SSD.
- **Done when**: All sixteen final reports exist and actual all-originals-running snapshot precedes release. Recorded16:20:22 UTC, zero reactivations.
- **Handoff to**: Fresh Astra.
- **Estimated effort**: 2.0 person-hours aggregate.

### Phase 2: One bounded decision
- **Agent**: `staff-tech-lead`, fresh `gpt-6-astra`.
- **Input**: Every final proposal, all original prior retrospectives and inspected admission/privacy source.
- **Activity**: Select by operator value, reliability, acceptance and simplicity; disposition all16. No vote count. Specify nullable basis v1, exact approval/hash/scope, legacy compatibility, direct-build/binding refusal and lifecycle contract.
- **Deliverable**: `decision.md`, this coordination plan.
- **Done when**: Root accepts concrete integration/ownership; conductor releases planners and Astra after final review. No implementation dispatch before this handoff.
- **Handoff to**: Root/conductor scheduling interface.
- **Estimated effort**: 0.75 person-hours.

### Phase 3: Guardrails, design and implementation
- **Agent**: Guardrail Agent, Principal UI/UX Engineer, staff-tech-lead impediment advisor; two Principal Elixir / OTP Engineers plus root as third author.
- **Input**: Root-accepted ADR05 and exact sole ownership table.
- **Activity**: Guardrail/UX briefs precede product edits. A owns Evidence/Decisions/Goals/Company/Harnesses and domain/lifecycle tests; B owns bounded existing LiveView/company origin presentation, Guide source-only prerequisite projections and dedicated web tests; root owns additive migration/migration tests and necessary shared/privacy integration. No new tables, dependency/schema/compiler/runtime changes. Preserve peer edits. Stage basis, admission, then presentation as focused review units, ideally <=400 net production lines each.
- **Deliverable**: One working goal-origin rule approval→plan→build/export journey, owned implementation notes, test evidence.
- **Done when**: Explicit authority, bypass/race, legacy and lifecycle acceptance passes; frozen candidate ready for independent review.
- **Handoff to**: Independent review and QA.
- **Estimated effort**: 4–7 person-hours aggregate; scope reconsidered if a new authority system or broad privacy rewrite is required.

### Phase 4: Independent review and native evidence
- **Agent**: Principal Code Reviewer, Principal Security Auditor, Principal Backend QA Lead/API QA, Principal Web QA (Playwright), Principal UI/UX Engineer; root owns native operations.
- **Input**: Frozen candidate, ADR05, before bytes and author's bounded checks.
- **Activity**: Independent code/security reviews; root-scheduled serialized Mix focused/canonical/static gates and lifecycle/compatibility matrix. Retain exact two baseline Dialyzer findings, zero new. Root builds a fresh native candidate and performs goal-only saved-record journey, source-only contrast, exact approval, missing-goal refusal/recovery, privacy invalidation and keyboard/narrow/zoom observations. Match source/build/process/assets/export bytes. Existing inspector no-probe traces remain required. Fix findings with same owners; three review-round cap before Staff escalation.
- **Deliverable**: `review/guardrail-brief.md`, `review/ux-design.md`, `review/code-review.md`, `review/security-review.md`, `review/regression-validation.md`, `review/web-validation.md`, `review/ux-validation.md`; SSD logs/exit codes, accounting and native evidence; accepted manifest.
- **Done when**: Selected behavior and regressions verified; material findings corrected; all failures and limitations retained. No mocked qualification or transferable approval claim.
- **Handoff to**: Five fresh independent retrospectives.
- **Estimated effort**: 2–4 person-hours plus root native scheduling.

### Phase 5: Five independent retrospectives and handoff
- **Agent**: Five fresh product, UX, architecture, trust/privacy and quality instances.
- **Input**: Identical root-frozen accepted evidence manifest/hashes and sole report paths.
- **Activity**: Independently answer “Was this tool really helpful and reliable to build a complete harness for a company? What is missing to make it reliable?” before seeing peers. Rank gaps, cite evidence and distinguish synthetic construction from qualified company outcomes. Conductor reads all five only after completion and preserves disagreement.
- **Deliverable**: `retro/01..05-*.md`, conductor handoff-to-06; root verification/ledger acceptance.
- **Done when**: Five reports complete and root accepts05 as a working verified benefit. No premarking, next-iteration dispatch or conductor board writes.
- **Handoff to**: Root closure;06 starts only on root signal.
- **Estimated effort**: 1 person-hour aggregate.

## Effort summary

| Phase | Agent | Effort |
|---|---|---|
|1|Sixteen Sol planners/conductor|2h|
|2|Astra Staff Tech Lead|0.75h|
|3|Two domain/web authors plus root/advisors|4–7h|
|4|Independent review/QA plus root|2–4h|
|5|Five retrospective instances|1h|
|**Total**|All phases|9.75–14.75h|

Estimated **9.75–14.75 aggregate person-hours**, not elapsed-time or completion promise.

## Risks + mitigations

- **Risk**: Goal selection becomes authority → **Mitigation**: exact immutable typed basis, separately approved claim and plan, repeated current admission.
- **Risk**: Empty plan binding or direct build bypasses the new requirement → **Mitigation**: goal-specific fail-closed binding and direct-build refusal with negative/race tests.
- **Risk**: Legacy nullable DTO/hash drift or source ancestry laundering → **Mitigation**: omit null basis from old DTO/hash; forbid cross-origin successors; golden bytes and typed purge/restore tests.
- **Risk**: Database migration loses history → **Mitigation**: additive nullable column, trigger/old-backup fixtures, down refusal when goal data exists; root owns backup/recovery.
- **Risk**: Concurrent edits/Mix create invalid evidence → **Mitigation**: sole file owners, <=3 authors, single explicit Mix reservation, frozen source and native identity binding.
- **Risk**: Review confidence substitutes for outcomes → **Mitigation**: independent acceptance before retrospectives; company fitness remains unproven, runtime/connector limits explicit.

## Escalation path

Any new contract/table/compiler/runtime requirement or material privacy ambiguity goes to root and Staff Tech Lead with exact file, failure, minimum fix and alternatives. Preserve failed evidence; after three review rounds stop broadening and obtain one bounded retry/replan decision. Routine local authorized fixes do not require repeated user approval.

## How to execute

Use supported collaboration calls and actual role labels. Root alone owns board/state, shared config/router/application/migrations, runtime/native build/CUA and final acceptance. Conductor hands off concrete ownership before dispatch and manages active-slot barriers. No remote writes, publication, paid inference, private source imports, host execution of generated code or credential extraction. Retain03/04 command-free inspection and historical bytes; no qualification or connector claims are inferred.
