# Iteration05 impediment review

**Advisory: proceed within the selected goal-origin unit.** No essential user input or additional approval gate is needed. This is a source review before author work, not an implementation or verification pass. The conductor's live contract selects an immutable nullable `evidence_claims.basis` column, version 1 goal kind with exact goal ID/content hash, existing claim decisions and a selected approved company plan. Source↔goal supersession is forbidden. The final decision record remains the authority for exact field names.

Read the [04 handoff](../../04/handoff-to-05.md), full [03 amendment](../../03/decision-amendment.md), current Evidence/Decisions/Company/Harnesses/Contracts, startup migration, and privacy purge/snapshot code. This review ran no Mix, runtime, browser, model or product mutation. The read-only OpenCode task abstention, seven readiness stages, static explanation and actual release checks remain binding.

## Smallest execution path and versioned contract

Reuse `Evidence.create_claim/1` → `Decisions.decide/2` → `Company.resolve/1`/`build_inputs/1` → `Harnesses.build_plan/2` and existing eligibility checks. Centralize basis validation/hash calculation in Evidence or one small owned helper; Company should add selected-goal membership/snapshot enforcement rather than a second approval registry. Goal selection alone cannot authorize a rule. Existing `Contracts.semantic_errors/1` and compiler provenance already support `goal_id` with empty evidence; no package schema, compiler version or alternate authority is needed.

Keep source claims on their exact historical canonical hash input. `basis = nil` means citation origin only; an empty/malformed/unknown-version map is an error, never a fallback. Goal kind requires empty citations, an exact workspace-owned goal/hash and basis-bound claim hash; mixed bases fail. A source↔goal supersession attempt must fail in both directions before insertion. Goal↔goal revisions may supersede only under the final selected contract. Rejection must remain distinguishable from approval; no optimistic approval is created by proposal, preview or plan selection.

The nullable schema field will appear in generic `Store.dto/1`. Omit its nil value where preserving legacy public claim shape matters, and verify source-only package spec, provenance, manifest and digest bytes. Do not backfill or rewrite immutable claims or previously saved artifacts. A deliberate new goal claim emits its existing rule shape with the selected goal ID and empty evidence.

## Races and admission

Current `create_claim/1` validates citations and the predecessor before its transaction; do not place new goal eligibility solely in this preflight. Validate the goal, predecessor kind and pinned hash again within the transaction that inserts the claim. Apply the existing privacy fence to new proposal/decision mutations where required; audit and claim/decision commits remain atomic. Immutable goals eliminate an ordinary goal-update race, but purge and restore remain lifecycle boundaries. Treat SQL uniqueness/foreign-key failure as safe refusal, never a reason to repeat an effect blindly.

Preserve existing `Harnesses` prebind and publish rechecks through `Company.build_inputs/1`. Each recheck must validate the approved exact claim revision, goal basis and plan's selected goal snapshot. Export and release already share `Harnesses.eligible/1`; reuse that route. `eligible_binding/1` currently accepts zero bindings for legacy packages. Goal-origin artifacts must require a valid exact company binding, including when a binding is missing or invalidated. Generic `Harnesses.build/1` must either keep goal claims out of its legacy source-only path or refuse a goal-containing unplanned build. It must never create a goal package with plan-free eligibility.

## Root migration and privacy integration

Root owns the additive nullable-column migration and shared integration. Existing evidence-claim UPDATE/DELETE triggers cover the added column; no new table, immutable list or purge ordering is required. Keep null defaults and no data rewrite. `StartupGate` runs migrations synchronously before reconciliation, Oban and the endpoint; use that existing boundary. Preserve the previous release and root's backup for rollback. Once goal rows exist, do not downgrade or drop their basis column against that workspace; restore the coherent pre-upgrade backup if rollback is necessary.

`Privacy.inventory`, workspace purge and snapshot already operate on `evidence_claims`. `Snapshot` remaps its workspace ID, clears claim/plan decisions and retains artifact bindings. A basis stores a goal ID/hash, so no extra workspace identifier should need rewriting. Its copied goal remains historical data after restore, while cleared decisions prevent authority recovery. Prove both current backup/restore and a pre-05 database/backup without the column; quarantine uses direct SQL before later startup migration and should not require a new backup format.

Source purge traces citation claim families and plan bindings. With cross-kind supersession forbidden, unrelated goal-only families should survive. A mixed plan depending on a purged source must lose its plan/binding/artifact even when a separate goal claim survives. Preserve binding invalidation and artifact removal ordering, since losing the only binding must not grant legacy eligibility. Workspace purge removes goal claims, goals, decisions and artifacts. Audit identifiers/hashes only; existing parameter filtering and UI escaping must cover goal-rule text without logging private content.

## Precise ownership and acceptance evidence

Conductor-confirmed disjoint ownership uses two delegated authors and root as the third author:

| Owner | Test files | Required evidence |
|---|---|---|
| Author A: all domain models, Evidence/Decisions/Company/Harnesses | `test/harness_forge/evidence_test.exs`, `test/harness_forge/company_test.exs`, `test/harness_forge/company_harnesses_test.exs` | v1 shape/hash, exact decisions, malformed/mixed/foreign bases, bidirectional cross-kind supersession refusal, selected approved goal plan → build/export, unselected goal, missing/invalid binding, generic-build bypass, supersession and deterministic source hash/package bytes |
| Author B: web components and events | `test/harness_forge_web/company_builder_test.exs` | explicit proposed→approved claim→selected plan journey, safe errors, reset/selection/privacy clearing |
| Root only | `test/harness_forge/company_privacy_test.exs`; new `test/harness_forge/goal_basis_migration_test.exs` if needed | mixed/unrelated source purge, workspace purge, committed current restore with approvals cleared/bindings retained, pre-05 column migration and old-backup compatibility |

Keep exactly those three implementation ownership lanes; root adds the narrowly owned migration/privacy assertions during integration. Independent QA runs the conductor's serialized checks after integration; this report grants no pass. No need to broaden shared runtime, current-route identity, declared-conflict handling, portable authority or representative outcome qualification to deliver this benefit. If a concrete incompatibility appears, report the failing call/bytes and choose between a bounded compatibility fix and withholding only goal-origin admission; do not weaken legacy checks or invent approval authority.
