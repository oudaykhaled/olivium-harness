# Coordination Plan: Iteration07 attempt-owned coding transport

**Classification**: implementation
**Pattern**: composed: map-reduce + sequential + parallel-fan-out + review-loop
**Total agents involved**: 34 planned instances across the complete cycle, including root and conductor; 19 actually dispatched for planning, no implementation author dispatched

## Agents involved (in order of first involvement)

Capability citations refer to [Fleet Capability Map](/Users/<user>/.agents/skills/fleet-capability-map/SKILL.md). Exact planning task IDs, distinct lenses, supported role labels, accepted requested models and fork-none provenance are in [planning-roster.json](../../../../tmp/enhancement-program/07/planning-roster.json). Counts are instances, not different specialties. At the planning barrier there were 16 original Sol planners plus Astra and conductor in the observed subtree; root was outside the scoped status response. The 21-active-agent limit is never a target.

| # | Agent | Role in this plan | Why this agent (cite the capability map) |
|---|---|---|---|
| 1 | `staff-agent-orchestrator` | Root and fresh07 conductor, two instances | Map meta-orchestration: capability matching, bounded ownership, explicit handoffs. Root alone writes the board/state/results and runs native/Mix operations. |
| 2 | `staff-tech-lead` | Astra adjudicator; Sol04/16; later fresh impediment advisor and architecture retrospective | Map architecture/ADR capability and technical-risk ownership; compares source, value and minimality rather than votes. |
| 3 | `staff-product-owner` | Sol01; later independent product retrospective | Map product/story/prioritization capability; company-operator value and falsifiable acceptance. |
| 4 | `principal-elixir-engineer` | Sol02/03/12; two proposed bounded authors | Map Elixir/Phoenix specialty: OTP lifecycle, Ecto contracts and contexts. Existing stack is retained. |
| 5 | `principal-security-auditor` | Sol05/08/14; later security review and trust retrospective | Map security/access-control specialty; private context, authority, purge and restore boundaries. |
| 6 | `principal-ml-engineer` | Sol06 | Map ML evaluation-harness specialty; distinguishes selected-goal accounting from representative company outcomes. |
| 7 | `principal-qa-api-curl` | Sol07 | Map API-contract and negative-testing capability; command-free inspection/MCP authority limits. |
| 8 | `principal-data-engineer` | Sol09 | Map database/schema/migration specialty; immutable historical identities and nullable private context trade-offs. |
| 9 | `staff-qa-lead` | Sol10; later independent regression QA and quality retrospective | Map org-wide QA strategy and quality gates; exact accounting, meaningful failure cases and reuse limits. |
| 10 | `principal-devops-sre` | Sol11 operational failure lens | Map observability/operability capability; original-resource recovery and daemon loss. Root remains the native operator. |
| 11 | `principal-qa-web-playwright` | Sol13; later independent web review | Map web E2E specialty; real operator behavior and native evidence, with no autonomous browser execution here. |
| 12 | `principal-code-reviewer` | Sol15; later fresh independent code review | Map code-review capability: correctness, security, tests, observability and minimal change. |
| 13 | `guardrail-agent` | Later fresh pre-edit boundary advisor | Root requires this supported runtime role; map security/architecture capabilities explain the boundary review. The older map omits this role; its exact installed slug exists at `/Users/<user>/.codex/agents/guardrail-agent.toml` and runtime exposes **Guardrail Agent**. |
| 14 | `principal-ui-ux-engineer` | Later fresh pre-edit advisor, independent UX review and UX retrospective | Programme requires the actual supported **Principal UI/UX Engineer**. The older map's omission is already documented in conductor.md; exact installed slug exists at `/Users/<user>/.codex/agents/principal-ui-ux-engineer.toml`. Existing run-card wording and approachable recovery are its bounded responsibility. |

The two installed-role exceptions above are observed registry/filesystem facts, not invented agents or edits to the shared fleet map. No Olivium-private infrastructure is needed. Future fresh instances total three pre-edit advisors, two product authors, five independent reviewers and five independent retrospectives. Together with the 19 planning instances this is 34. None of those future 15 instances is dispatched by this document.

## Phases

### Phase 1: Freeze and validate intake — complete
- **Agent**: `staff-agent-orchestrator`
- **Input**: Root's07 start, original06 closure/handoff/five retrospectives, prior05 dissent,17 initial references and626 physical source copies.
- **Activity**: Validate all17 initial byte/hash pairs and all626 actual copied source files; retain readonly owned intake copies. Read all five original06 and original05 retrospectives plus both full handoffs.
- **Deliverable**: [planning-intake-validation.json](../../../../tmp/enhancement-program/07/planning-intake-validation.json), [planning-prior05-originals.json](../../../../tmp/enhancement-program/07/planning-prior05-originals.json).
- **Done when**:17/17 and626/626 match; supplemental05 originals match their actual packaged source-before copies. This establishes intake only. Root's later live state changes are intentional and are not asserted unchanged.
- **Handoff to**: Phase2, `staff-tech-lead` and16 fresh Sol planners.
- **Estimated effort**:0.2 person-hours.

### Phase 2: Fresh concurrent proposals and Astra decision — complete
- **Agent**: `staff-tech-lead` plus16 mapped planner instances.
- **Input**: Frozen intake, distinct lenses and one sole-owned report path per planner; explicit active final-review barrier.
- **Activity**: Exactly16 original `gpt-6-sol` fork-none sessions write288–346-word original reports; one original `gpt-6-astra` fork-none decisionmaker reads all16 plus all original05/06 reports/full handoffs. Select one benefit by source, value and minimality; disposition every proposal and preserve route-only dissent.
- **Deliverable**: [ADR07](decision.md),16 [original reports](planning/01-company-value.md), [actual barrier](../../../../tmp/enhancement-program/07/planning-concurrency.json), [fingerprints](../../../../tmp/enhancement-program/07/planning-report-fingerprints.json), [release verification](../../../../tmp/enhancement-program/07/planning-release-verification.json), [citation resolution](review/planning-citation-resolution.md).
- **Done when**: Actual tool response observes all16 READY originals RUNNING simultaneously after Astra full-read readiness; all16 then explicitly released and actually observed complete. Zero replacements/reactivations. Status API gives statuses; accepted spawn records give requested model provenance. Fifteen broken original Markdown targets remain frozen and are corrected in the appendix.
- **Handoff to**: Phase3, root `staff-agent-orchestrator`.
- **Estimated effort**:3.0 aggregate person-hours.

### Phase 3: Root scheduling interface — current stopping point
- **Agent**: `staff-agent-orchestrator`
- **Input**: Full final ADR07, this coordination plan, Astra readiness, original reports and barrier/release/citation evidence.
- **Activity**: Root reads the full decision and resolves its exact technical contract. The selected benefit binds one validated coding attempt to its original local endpoint/daemon through execution, recorded profile and cleanup; a route-only patch is an explicitly rejected smaller alternative for that guarantee.
- **Deliverable**: Root's explicit ADR acceptance and scheduling instruction, including owners and Mix/native ownership; root alone records it.
- **Done when**: Root accepts one bounded contract; exact positive native-Unix route predicate and legacy unfinished-origin compatibility are resolved before edits. These are technical design obligations, not user permission gates. No unknown observation can mean Unix; an unproven old daemon cannot be declared clean through today's default.
- **Handoff to**: Phase4, fresh `guardrail-agent`, `staff-tech-lead`, `principal-ui-ux-engineer` only after root dispatch. **This conductor stops here before any advisor/author dispatch or product edit.**
- **Estimated effort**:0.3 person-hours.

### Phase 4: Fresh pre-edit advice and explicit API handshake — not dispatched
- **Agent**: `guardrail-agent`, `staff-tech-lead`, `principal-ui-ux-engineer` in parallel.
- **Input**: Root-accepted ADR, A1–A9 acceptance contract, current bytes, root's exact native-route/legacy decisions, proposed disjoint file ownership.
- **Activity**: Guardrail reviews pinned endpoint/daemon, credential-free private context, fail-closed authority and privacy; impediment advisor checks seams, migration/recovery and capacity without deleting evidence; UI/UX advisor supplies plain fixed existing-card refusal copy. Agree typed observation and public/private DTO boundary before parallel author edits. Guardrail knowledge updates only for durable learning within its owned brief.
- **Deliverable**: Fresh root-scheduled `review/guardrail-brief.md`, `review/impediments.md`, `review/ux-design.md`, plus exact author API contract.
- **Done when**: No unresolved contract conflict; finite Unix signature and legacy origin behavior are explicit; root assigns at most three DISTINCT product authors TOTAL including root. SSD11GiB is an assessment input, not a present blocker or deletion authority.
- **Handoff to**: Phase5, two `principal-elixir-engineer` authors and root.
- **Estimated effort**:0.75 aggregate person-hours.

### Phase 5: One transport contract with disjoint ownership — not dispatched
- **Agent**: Two `principal-elixir-engineer` authors; root as third/final possible author.
- **Input**: Accepted contract and pre-edit advice; agreed API handshake; explicit root Mix instructions.
- **Activity**: AuthorA owns `execution/command.ex`, `execution/coding.ex`, optional small `execution/coding_transport.ex` and focused transport/coding tests. AuthorB owns `evaluations.ex` and focused evaluation/applicability/cancellation tests. Root owns `evaluation/run.ex`, one nullable migration, privacy snapshot/purge integration and related tests, optional release integration/fixed-reason mapping and docs. AuthorB does not edit root schema/privacy files. Implement storage/restore slice, pinned transport/profile slice, then evaluation/recovery integration; parallelize only independent agreed slices.
- **Deliverable**: One reviewable implementation with v2 profile, private nullable execution_context, pinned commands/cleanup, unqualified bounded refusal and honest legacy compatibility; implementation note and focused test cases.
- **Done when**: ADR A1–A9 implementation is reviewable; no sidecar/public endpoint/extra MCP tool/policy-conflict/receipt/goal-only/cleanup-sweep feature is added. No raw discovery/provider secrets leave private authority. Populated rollback refuses lost cleanup context.
- **Handoff to**: Phase6, fresh `principal-code-reviewer`, `principal-security-auditor`, `staff-qa-lead`, `principal-qa-web-playwright`, `principal-ui-ux-engineer`.
- **Estimated effort**:4.0–6.0 aggregate person-hours, revised after contract review.

### Phase 6: Independent review loop and root-owned actual verification — not dispatched
- **Agent**: Five fresh independent reviewers named above; root alone executes all Mix/Docker/build/native/browser work.
- **Input**: Frozen candidate, full changed-file inventory, A1–A9 and exact command/exit/native evidence. Authors' reports are context, not independent proof.
- **Activity**: Review code/security/regression/web/UX in parallel against one candidate. Root schedules focused ExUnit and canonical machine accounting; format/compile/Credo/packaging/inventory/Dialyzer checks; guarded actual Docker cases on available supported routes; isolated native run-card refusal with keyboard/reflow evidence only where copy changed. Preserve all failures. Maximum three correction rounds; changes invalidate affected evidence and return to existing owners.
- **Deliverable**: A1–A9 evidence mapping, independent verdicts, exact logs/counts/source identity under root-owned iteration07 paths and review reports.
- **Done when**: All required criteria pass with no new unsuppressed diagnostic; two baseline Dialyzer findings at releases47/121 remain plainly reported.15 default Docker skips stay skips. Execution changes invalidate blanket historical Docker reuse. Fixtures, actual routes, repeats and unavailable routes are distinguished; command-free traces cover new boundaries. No model/company/connector qualification is claimed.
- **Handoff to**: Phase7, root `staff-agent-orchestrator`.
- **Estimated effort**:2.0–3.0 aggregate person-hours.

### Phase 7: Root-only accepted local installation and preservation — not dispatched
- **Agent**: Root `staff-agent-orchestrator`; existing independent reviewers assess its evidence without becoming product authors.
- **Input**: Accepted candidate and migration/legacy/rollback contract, real preservation inventory and root reverified runtime identity.
- **Activity**: Root decides and performs authorized local build/isolated QA/main transition only after explicit scheduling. Reverify release/PID/workspace/database/listener first; back up and compare intended schema versus legacy columns/artifacts. Never overwrite a running release or operate from stale runtime JSON. Preserve protected main until this accepted sequence.
- **Deliverable**: Root's bounded accepted evidence and main preservation/smoke records; no publication or production authorization is inferred.
- **Done when**: Verified changed behavior and preservation meet root acceptance; distinct implemented/reviewed/installed/verified states are recorded honestly. Current planning has no Mix owner and claims no fresh runtime state.
- **Handoff to**: Phase8, five fresh independent retrospective instances.
- **Estimated effort**:0.75 person-hours.

### Phase 8: Independent retrospective and next-iteration gate — not dispatched
- **Agent**: Fresh `staff-product-owner`, `principal-ui-ux-engineer`, `staff-tech-lead`, `principal-security-auditor`, `staff-qa-lead`.
- **Input**: Identical root-accepted immutable evidence and one sole-owned report path each; original dissent and exact evidence limits.
- **Activity**: Each independently answers whether HarnessForge was helpful/reliable for a complete company harness and ranks what remains missing before seeing peers. Conductor/root reads all five originals fully; root alone closes/counts07 and prepares08 UI/UX handoff.
- **Deliverable**: Five original `retro/01..05-*.md` reports and root's next handoff, accepted ledger/result/board update.
- **Done when**: All five are complete and independently evidenced; root accepts the result. Qualification, coherence, portable authority, MCP scope, novice/speech/WCAG and longitudinal gaps remain explicit where unproven. The persistent50-goal is neither completed nor paused by planning.
- **Handoff to**: Root's explicit08 start and new conductor; no automatic08 dispatch here.
- **Estimated effort**:1.0 aggregate person-hours.

## Effort summary

| Phase | Agent | Effort |
|---|---|---|
| 1 | `staff-agent-orchestrator` |0.2 h |
| 2 |16 Sols + Astra `staff-tech-lead` |3.0 h |
| 3 | Root `staff-agent-orchestrator` |0.3 h |
| 4 | Fresh guardrail/impediment/UIUX advisors |0.75 h |
| 5 | Two `principal-elixir-engineer` authors + root |4.0–6.0 h |
| 6 | Five independent reviewers + root execution |2.0–3.0 h |
| 7 | Root, reviewer evidence assessment |0.75 h |
| 8 | Five independent retrospective instances |1.0 h |
| **Total** | | **12.0–15.0 aggregate person-hours** |

Estimates describe effort, not elapsed time. Original-daemon recovery and legacy compatibility carry uncertainty; author scope must stay inside the one accepted benefit.

## Risks + mitigations

- **Risk**: Route-label consistency is mistaken for original daemon ownership → **Mitigation**: A3/A4 require pinned endpoint/daemon checks, wrong-daemon decoys, retained durable context and verified original cleanup; planner15's narrower dissent remains explicit.
- **Risk**: Native Unix inference repeats the existing negative fallback → **Mitigation**: Root resolves one finite positively recognized contract; unknown/unsupported topologies refuse, and fixture Unix evidence never counts as native qualification.
- **Risk**: Migration/restore/purge loses cleanup authority or exposes endpoint paths → **Mitigation**: Private nullable column outside DTOs, no backfill, populated-rollback refusal, context retention through failed cleanup, restore clearing and A6/A7 lifecycle cases.
- **Risk**: Old incomplete attempts are silently cleaned against today's daemon → **Mitigation**: Unproven historical origin remains unresolved, surfaced before installation; no guessed default fallback.
- **Risk**: Parallel edits or independent runtime commands corrupt evidence → **Mitigation**: Exact A/B/root files, three distinct authors total, root-only serialized Mix/native ownership, actual release identities and evidence invalidation after changes.
- **Risk**: Planning convergence overstates product fitness or hides alternatives → **Mitigation**: Every16 and prior05/06 judgment is dispositioned in ADR; no votes/autobundle; qualification remains unproven and five original retrospectives follow actual verification.

## Escalation path

- If root contract review rejects endpoint durability, native-route recognition or legacy handling → escalate to root and `staff-tech-lead` with ADR, planner03/15 dissent, relevant source and smallest honest alternative. Revise the claimed benefit explicitly before edits; do not silently implement route-only while retaining daemon guarantees.
- If a pre-edit boundary conflict, actual acceptance failure or third correction round stalls → escalate to root and `staff-tech-lead` with exact candidate hashes, failing criterion/log, owner and minimal retry/re-plan. Continue independent authorized work; do not repeat unchanged permission questions.
- Runtime, migration, protected-main and storage decisions belong to root. Advisors do not acquire execution permission from this plan; preserved evidence is never deletion collateral.

## How to execute

Current execution stops at Phase3. Root must first read/accept the full ADR and explicitly schedule fresh advice, owners and Mix/native windows. No product author or future advisor is dispatched by this artifact. Prefer collaboration tools using exact supported runtime roles; the CLI template below is the canonical manual alternative only after root schedules a phase, with the actual installed prompt-file path supplied by the running environment:

```bash
./bin/Codex -p --append-system-prompt-file ~/.Codex/agents/<slug>.md \
  "<the input for this phase>"
```

Do not infer that this generic template exists inside HarnessForge: this session uses the supported collaboration runtime and installed TOML role inventory. Programme execution remains local and within authorization: no commits/push/PR, paid inference/private import/credential extraction, remote writes/publication or generated-harness host execution.
