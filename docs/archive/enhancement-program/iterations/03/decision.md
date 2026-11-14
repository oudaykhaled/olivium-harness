# Coordination Plan: Exact-package readiness inspection

**Classification**: implementation
**Pattern**: composed: sequential + parallel-fan-out + review-loop
**Total agents involved**: 8 execution roles (after the 16 planning agents and this decision maker are released; two implementation authors maximum)

## Decision and evidence

Select ONE functionality unit: **an operator inspects one immutable package and an explicitly selected persisted evaluation, sees independent admission stages and one corrective next action before attempting release approval**. Deliver a read-only domain API and one Packages inspector. No migration, approval format, compiler change, execution backend or new release authority is needed.

Decision made only after conductor `ALL16_READY`. Read all sixteen originals below, all five [iteration02 retrospectives](../02/retro/), [handoff](../02/handoff-to-03.md), [PROGRAM](../../PROGRAM.md), repository AGENTS and [guardrail brief](review/guardrail-brief.md). [Actual concurrency snapshot](../../../../../tmp/enhancement-program/03/planning-concurrency.json) records all sixteen `i03_sol_01`–`i03_sol_16` tasks running at 2026-11-01 13:35:39 UTC without reactivation; decision task is `/root/i03_conductor/i03_astra_decision`, explicitly dispatched `gpt-6-astra`; planners were `gpt-6-sol`. The snapshot reports successful dispatch model arguments, not independently inspected opaque model IDs. All proposals were read before this selection. This is source inspection and planning, not a new test or live compatibility result.

**Context / ADR.** `Artifacts.read/2` verifies persisted metadata and payload; `Harnesses.eligible/1` rechecks claim and plan authority; `Evaluations.get/1` is workspace-scoped; `Evaluations.applicability/2` compares current exact identities; `Releases.Validation.check/3` checks qualified task outcome, cleanup, controls, scope and applicability. The portal currently offers separate package/run choices without this consolidated preapproval answer. Conversely, `Harnesses.specification/3` emits `goal_id: nil`, and `Evidence.create_claim/1` requires citations: policy completeness is a real unresolved gap.

**Decision rationale.** Compare each option on (1) immediate operator value, (2) preserving admission/security, (3) implementation and meaningful test scope, (4) simplicity, (5) external prerequisites. Readiness provides new diagnostic functionality by composing existing authoritative gates with no new persisted authority or live-model prerequisite. Goal-origin policy plus declared conflicts has greater policy-expression value but changes claim hashing, decisions, plan admission, compiler compatibility and privacy lifecycle. Conflict-only is smaller but still alters existing plans' authority after declaration. Portable approval serves a different recipient and first needs signer trust, expiry/revocation and restored-key semantics. None is rejected as unimportant. Choosing readiness is a bounded delivery judgment, not a count of recommendations.

**Consequences and dissent.** Product and architecture retros favor goal-origin policy and declared conflicts; UX, trust and quality favor exact-artifact readiness. Keep that disagreement in the next handoff. This unit does not make intended policy expressible, detect contradictions, authenticate exports or prove company fitness. No green overall “company qualified” status is permitted. Real representative outcomes require a separately authorized pilot.

## Every proposal disposition

| Proposal | Disposition and rubric reasoning |
|---|---|
| [01 Product intent](planning/01-product-intent.md) | Defer. High authoring value and no external service dependency, but new basis/conflict authority has broad migration, compatibility and privacy tests; exceeds this unit. |
| [02 Readiness UX](planning/02-readiness-ux.md) | Accept domain benefit and distinct states; narrow to one Packages surface and explicit run choice. Three surfaces and automatic capability probes add latency/staleness risk without necessary acceptance value. |
| [03 Policy architecture](planning/03-policy-architecture.md) | Defer as substantive competing priority. Exact goal hashes and legacy decoding are credible; claim/decision/compiler/purge/restore breadth raises admission risk versus additive read-only delivery. |
| [04 Declared conflicts](planning/04-declared-conflicts.md) | Defer separately. Preventing known contradictions is valuable; declarations invalidate existing plans and require new persistence, resolution semantics and repeated admission. No semantic detector is implied. |
| [05 Artifact identity](planning/05-artifact-identity.md) | Accept exact stored identities and gate reuse. Reject automatic latest-applicable-run fallback: it can conceal later failure and expands selection policy. Require explicit evaluation ID. |
| [06 Portable authority](planning/06-portable-authority.md) | Defer as distinct recipient trust capability. Ed25519 alone does not resolve issuer enrollment/revocation/expiry; governance ADR and clean-import tests precede implementation. No unsigned substitute receipt in this unit. |
| [07 Privacy lifetime](planning/07-privacy-lifetime.md) | Accept privacy fence, reset invalidation, metadata allowlist and restore/purge negatives as mandatory boundaries. Reject persisted readiness records. No external prerequisite. |
| [08 Acceptance](planning/08-acceptance.md) | Accept adversarial matrix, exact-gate comparison and honest historical baseline. Narrow runtime availability claims to recorded evidence/configuration; no probe or live outcome needed. |
| [09 Machine discovery](planning/09-machine-discovery.md) | Defer MCP extension. Useful machine consumer of the same API later, but adds transport/auth/privacy surface and separate contract tests beyond one operator workflow. |
| [10 Evaluation lifecycle](planning/10-evaluation-lifecycle.md) | Accept explicit failed/cancelled/interrupted/cleanup states and no mutations. Use standalone Readiness context rather than expand Evaluations with orchestration responsibilities. |
| [11 Runtime truth](planning/11-runtime-truth.md) | Accept no render probes, registry/backend truth and short-socket guidance when an actual reason warrants it. Defer live refresh/probe machinery: current readiness says live availability not checked. |
| [12 Reuse scope](planning/12-reuse-scope.md) | Accept gate reuse and explicit run ID. Derive all plan bindings from owned DB records rather than accept caller plan authority; preserve multiple bindings rather than choose arbitrarily. |
| [13 CLI workflow](planning/13-cli-workflow.md) | Defer CLI surface. Valuable automation but adds parsing/contract scope; exact plan/hash user input is unnecessary for the bounded Packages path. Domain API enables later reuse. |
| [14 Next actions](planning/14-next-actions.md) | Accept one action beside exact saved digest and domain revalidation. Navigation only; no automatic evaluation, approval, export or prefilled mutation dispatch. |
| [15 Adversarial admission](planning/15-adversarial-admission.md) | Accept persisted-run loading and final gate as sole positive release predicate. A one-code admission wrapper alone obscures other stages; compose it in the inspector without altering release command semantics. |
| [16 Bounded architecture](planning/16-bounded-architecture.md) | Accept additive Readiness context plus one Packages inspector. Narrow capabilities probing and forbid implicit run selection, keeping scope/test cost low and external prerequisites absent. |

## Frozen interfaces and authority contract

`HarnessForge.Readiness.for_artifact(digest, evaluation_id \\ nil) :: {:ok, map()} | {:error, atom()}` in `lib/harness_forge/readiness.ex`.

- Inputs: lowercase 64-hex digest and nil or bounded UUID evaluation ID; all other shapes return `{:error, :invalid_readiness_reference}`. Caller maps, status/outcome overrides, scope, plan hash and arbitrary destinations are not inputs. Never atomize input.
- Read under existing `Privacy.Purge.synchronize/1`; `Workspaces.ensure_writable/0` supplies the existing privacy-ready fence despite this query being read-only. On privacy refusal return the existing reason atom without retained result data. No writes, execution, model/network/Docker probes, audit append, export, receipt or scheduler.
- Load artifact with `Harnesses.get/1`. Missing/tampered artifact returns a safe report with integrity blocked and downstream stages `not_assessed`; do not return artifact payload/error inspection text. Preserve a fixed safe reason code. Derive scope from the verified artifact only.
- Return string keys: `artifact_digest`, `evaluation_id`, `observed_at`, `plan_bindings`, `current_identities`, `evaluation_identities`, `stages`, `blockers`, `next_action`, `limitations`. `plan_bindings` is a sorted list of owned `{plan_id, plan_revision_hash}` pairs from `ArtifactBinding`, not an assertion each binding is currently approved. Empty means no retained local binding; never infer portable authority. Existing `Harnesses.eligible/1` remains authoritative, including its any-valid-binding semantics.
- `stages` is an ordered list of `{name, status, reason_code}` for `integrity`, `eligibility`, `managed_runtime`, `evaluation`, `applicability`, `cleanup`, `release_admission`. Status vocabulary: `passed`, `blocked`, `unavailable`, `not_assessed`. Evaluation additionally exposes safe persisted `kind` and `outcome` fields; cleanup exposes its safe persisted status. Unknown/malformed values cannot pass.
- Eligibility delegates to `Harnesses.eligible/1`; this already uses Company build inputs and exact recompilation. Avoid reimplementing plan admission. Current identities delegate to `Evaluations.applicability/1`; expose only a fixed allowlist of runtime/model/suite/grader/fixture/environment/config/capability/policy/scope digest metadata. No source/rule/goal/task text, configuration maps, credentials, actor identity, or arbitrary persisted run map. Scope itself need not be displayed; derive scope digest.
- Managed runtime: registry says Codex/Claude backend unavailable; missing selected model can be identified from current trusted model identity. OpenCode with selected model remains `not_assessed` for **live availability**, even with historical evidence. Do not call `Evaluations.capabilities/0`, `Execution.probe/0` or `Coding.availability/0`. They perform external checks. Recorded missing-image/model/socket errors may be displayed through a fixed reason allowlist, labeled as the selected run's observation rather than current live health.
- Nil evaluation ID means `no_evaluation_selected`; never pick newest/best pass. Otherwise `Evaluations.get/1` loads the exact current-workspace record. Nonexistent and foreign IDs have the same safe unavailable result. A different artifact's run blocks with `evaluation_artifact_mismatch`; do not disclose its detailed metadata. Use `Evaluations.applicability/2` and `Releases.Validation.check(artifact, run, derived_scope)` unchanged. `release_admission` passes **if and only if that final gate returns :ok**; label it “Ready for release review”, never “approved” or “company qualified”. Live availability not assessed is independent of historical release admissibility and does not rewrite the existing gate.
- `blockers` is ordered safe `{stage, code, action}` metadata. `next_action` has fixed `code` and allowlisted `destination` (`company`, `connections`, `evaluations`, `releases`, `package`), selected by integrity → eligibility → selected evidence/applicability/cleanup → release gate. A missing run directs evaluation selection; unsupported runtime directs reviewing/rebuilding a supported target. Inspection itself never triggers mutations. Unknown failure uses a safe blocked fallback, never an optimistic pass.
- UI: one Packages inspector, exact digest and optional run dropdown filtered to that digest's current-workspace runs, explicit Inspect/Refresh button, independent stage labels, one primary navigation action, expandable identities and limitations. Changing package clears the evaluation selection and prior report. Changing run clears prior report until refreshed. No expensive read in render. Clear readiness state on privacy reset, session revocation and relevant data/evaluation reload; do not keep a stale green report. Authenticate every event. Any new cached component must obey existing per-mount/reset freshness rules; use synchronous inspection to avoid async-result lifetime machinery. Navigation cannot bypass actual admission.

No shared source edits are presumed necessary. If implementation discovers a required change to gate semantics, persistence, compiler or shared infrastructure, stop that dependent change and send root the smallest contract amendment before proceeding.

## Agents involved (in order of first involvement)

Capability references are to [Fleet Capability Map](/Users/<user>/.agents/skills/fleet-capability-map/SKILL.md); the generic map's example versions/model tags are not this project's runtime constraints.

| # | Agent | Role in this plan | Why this agent (cite the capability map) |
|---|---|---|---|
| 1 | `staff-tech-lead` | Implementation conductor, impediment removal and integration | Capability index: architecture/ADR; decomposition into PR-sized units and capacity estimates. |
| 2 | `principal-security-auditor` | Selected-contract guardrail and privacy review | Specialty: broken access control, integrity and sensitive-data exposure. |
| 3 | `staff-product-owner` | Bounded UX wording/interaction review, no source ownership | Capability index: product stories; ensures observable operator benefit without qualification overclaim. |
| 4 | `principal-elixir-engineer` | Author A: domain API and domain tests | Specialty: Phoenix contexts, Ecto and typed Elixir boundaries. |
| 5 | `principal-elixir-engineer` | Author B: Packages inspector and LiveView tests | Specialty: Phoenix LiveView stateful UI. Separate instance with disjoint files. |
| 6 | `principal-code-reviewer` | Independent review loop | Map: correctness, security, performance, tests, observability review. |
| 7 | `principal-qa-elixir` | Independent domain/regression verification | Capability index: Elixir/Phoenix QA. |
| 8 | `principal-qa-web-playwright` | Independent UX/native evidence assessment | Map: web E2E, visual regression, locator/accessibility discipline; root performs browser operations. |

## Phases

### Phase 1: Freeze admission and ownership
- **Agent**: `staff-tech-lead` with `principal-security-auditor` and `staff-product-owner`
- **Input**: This decision, guardrail brief, source and planner/retrospective dissent.
- **Activity**: Conductor gets a bounded selected-scope guardrail verdict and UX input, then releases planning barrier before implementation. Root records board/ledger.
- **Deliverable**: `docs/enhancement-program/iterations/03/review/selected-scope.md`.
- **Done when**: Root accepts exact API and disjoint ownership; no author starts with an unresolved authority contract.
- **Handoff to**: Phase 2, two `principal-elixir-engineer` instances.
- **Estimated effort**: 1 person-hour.

### Phase 2: Implement domain and one operator surface
- **Agent**: `principal-elixir-engineer` instances A and B.
- **Input**: Frozen contract and existing synthetic fixtures.
- **Activity**: A owns only `lib/harness_forge/readiness.ex`, optional `lib/harness_forge/readiness/*.ex`, `test/harness_forge/readiness_test.exs`. B owns only `lib/harness_forge_web/live/portal_live.ex`, new `lib/harness_forge_web/components/package_readiness.ex`, `test/harness_forge_web/package_readiness_test.exs`. B can build against frozen API while A implements; integration follows A's ready signal. Each preserves others' changes. No third implementation author needed.
- **Deliverable**: Those source/tests plus author evidence notes under iteration03 review.
- **Done when**: Focused behavior and adversarial tests pass in root-scheduled serialized Mix window; no probe/mutation from read path.
- **Handoff to**: Phase 3, `principal-code-reviewer` and `principal-security-auditor`.
- **Estimated effort**: 6 person-hours (A 3.5, B 2.5).

### Phase 3: Review and correct
- **Agent**: `principal-code-reviewer`, `principal-security-auditor`; authors correct only owned files.
- **Input**: Source comparison against root’s `tmp/enhancement-program/03/source-before/` and matching inventory, focused evidence, contract, frozen historical artifact sample. The application is untracked; git diff is not the historical baseline. Root’s historical02 copies preserve the actual frozen prior bytes.
- **Activity**: Review admission parity, safe projection, privacy lifetime, unknown states, UI input handling and historical bytes. Maximum three bounded review rounds; no scope expansion.
- **Deliverable**: `review/code-review.md`, `review/security-review.md` with explicit verdicts.
- **Done when**: Blocking findings corrected and independently accepted.
- **Handoff to**: Phase 4, `principal-qa-elixir` and `principal-qa-web-playwright`.
- **Estimated effort**: 2 person-hours.

### Phase 4: Independent verification and native proof
- **Agent**: `principal-qa-elixir`, `principal-qa-web-playwright`, root operator.
- **Input**: Reviewed candidate, actual commands and native artifacts.
- **Activity**: Root owns Mix/build/browser scheduling and native operation; validators assess independent checks and real UI evidence. Keep runtime roots short for 104-byte socket limit.
- **Deliverable**: `review/regression-validation.md`, `review/ux-validation.md`; logs/screenshots/hashes under `tmp/enhancement-program/03/`.
- **Done when**: Acceptance below passes with exact provenance; unavailable outcomes stay explicit. Root then commissions PROGRAM's five independent retrospectives before completion.
- **Handoff to**: Root/conductor for retrospective cycle and ledger completion.
- **Estimated effort**: 2 person-hours, excluding later five-reviewer retrospective cycle.

## Acceptance and falsifiers

1. Exact approved package + no selected run: verified integrity/current eligibility; no qualification; explicit next action. Explicit static and smoke passes remain release-blocked. Task pending/running/blocked/failed/cancelled/interrupted outcomes and incomplete cleanup remain distinguishable.
2. Positive release-admission fixture is privileged synthetic test setup using existing trusted-run fixture practice; report exactly matches `Validation.check/3`. It proves gate projection only. Test no new run, approval, channel, audit or artifact writes; hash/count relevant tables and immutable files before/after queries.
3. Cross-workspace run, cross-artifact run, caller-supplied map/outcome, malformed digest/UUID, missing and tampered package fail closed with safe codes. Place private sentinels in unrelated/raw fields and assert none enter report, DOM or error output.
4. Change every material applicability identity independently: suite/grader/fixture, runtime image/version, model/context, environment, effective config, capability/policy/scope. Existing gate fails and report cannot remain positive. Required-control failure and missing completion/checks fail. Unknown run data cannot be coerced into pass. Do not claim resistance to arbitrary privileged database rewrite beyond the existing trust model.
5. Revoke claim/plan, alter company snapshot or goal acceptance, then refresh: eligibility blocks despite old successful evidence. Merely proposed successor preserves eligible approved predecessor. Multiple stored plan bindings are represented deterministically with current gate semantics unchanged.
6. Incomplete purge refuses query; source purge clears affected displayed report; restore remains quarantined. Unrelated scope remains unaffected. Session revocation clears report. Package/run switch cannot retain the previous identity/status. Actual approval after a previously positive observation must still refuse newly stale authority/applicability.
7. Native browser proof on the locally built candidate: select saved package, inspect no-run, explicitly select real persisted static run, observe blocked release and exact IDs, switch packages/run and refresh, navigate safe next action, demonstrate stale-plan refresh and reset/revocation clearing. Screenshots plus DOM/event evidence at desktop and calibrated narrow viewport, keyboard labels/focus, no overflow or overclaim. Use synthetic records; do not seed a fake native qualified success. True 200% zoom remains unverified unless actually exercised.
8. Root schedules focused tests then canonical `mix test`, format, warning-gated compile, Credo and baseline Dialyzer comparison. Record commands/exits and preserve failures. Prior 417 passes and two Dialyzer diagnostics are baseline only. Reuse previous Docker isolation evidence only as historical evidence; rerun Docker fixtures if execution/isolation/cleanup behavior changes. Such source changes are outside this unit and require root scope review.

## Effort summary

| Phase | Agent | Effort |
|---|---|---|
| 1 | `staff-tech-lead` + guardrail/UX input | 1 h |
| 2 | Two `principal-elixir-engineer` instances | 6 h |
| 3 | `principal-code-reviewer` + security | 2 h |
| 4 | `principal-qa-elixir` + web QA/root | 2 h |
| **Total** | | **11 h** |

Estimates are engineering person-hours, not agent wall-clock promises. Parallel UI/domain work shortens elapsed time; serialized integration/testing avoids shared Mix and state collisions.

## Risks + mitigations

- **Risk**: Readiness is mistaken for new authority → **Mitigation**: final predicate reuses Validation unchanged, explicit provisional wording, actual commands repeat admission and stale-after-inspection test.
- **Risk**: Privacy reset leaves cached identities/status or reveals raw errors → **Mitigation**: allowlisted metadata/reasons, synchronous request, authenticate handlers, invalidate report on reset/revocation and sentinel/race checks.
- **Risk**: Live availability overclaim or probe stalls → **Mitigation**: no probes in this unit; missing current configuration and unsupported backend are explicit, live availability remains not assessed.
- **Risk**: Existing gate behavior is misrepresented as complete-company assurance → **Mitigation**: preserve synthetic suite labeling, unresolved policy and portable-authority limitations, no native fake positive.

## Escalation path

- If API parity, privacy lifetime or historical-byte compatibility requires changing authority → escalate to `staff-tech-lead` and root with failing test, exact gate/source, smallest alternatives and scope impact. Independent work continues only within owned safe files.
- If three review rounds fail → `staff-tech-lead` selects a smaller corrected implementation or records a genuine blocker; do not relabel failure as completion.
- Root alone owns PROGRESS/state, shared mix/config/router/application/migrations, native/build/browser operations and scheduling. No publishing, commits, private imports, credentials, paid inference or host execution of generated code.

## How to execute

The conductor dispatches the mapped roles through the actual `collaboration.spawn_agent` tool after planning release and root's internal scope acceptance, with the frozen decision, exact file ownership and authorized model in each task. Follow-up work uses `collaboration.followup_task`; handoffs and Mix scheduling use `collaboration.send_message`. These are the supported mechanisms in this session. Capability-map command examples are not executable workspace commands.

Deferred explicitly: goal-origin/conflict admission, signed or unsigned authority receipts, MCP/CLI inspection, new release-status/channel projection, new managed backends, live model probes, company pilot, unrelated export-recovery polish, broad accessibility certification, dependency upgrades and production deployment.
