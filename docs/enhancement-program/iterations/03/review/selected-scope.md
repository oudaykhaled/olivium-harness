# Selected-scope guardrail review — iteration03

**Verdict: PROCEED.** The [frozen decision](../decision.md) selects one additive, read-only exact-package readiness inspector. Its API and disjoint ownership preserve the [guardrail brief](guardrail-brief.md), repository [AGENTS](../../../../../AGENTS.md) and [PROGRAM](../../../PROGRAM.md). No blocking contract correction or additional approval gate is required before the two authors start.

This is pre-implementation source/contract review, not a test or security acceptance verdict. No Mix, service, browser/native operation or product edit was performed; root's source snapshot remains untouched.

## Frozen interface accepted

`HarnessForge.Readiness.for_artifact(digest, evaluation_id \\ nil)` accepts only a lowercase 64-hex digest and nil/bounded UUID. Reject caller maps, overrides and extra authority inputs. Inspect synchronously under `Privacy.Purge.synchronize/1` and `Workspaces.ensure_writable/0`; return the existing privacy refusal without cached report data. No persistence, audit, export, execution, scheduler or live probes.

The following are implementation constraints already present in the decision, not new scope:

1. **Existing admission is the authority.** `Harnesses.get/1` verifies stored artifact bytes; `Harnesses.eligible/1` retains exact claim/plan admission and any-valid-binding semantics. Load only the explicitly selected current-workspace record through `Evaluations.get/1`; nil never selects a convenient prior pass. Missing/foreign IDs are indistinguishable; another artifact's run reveals no detailed metadata. Derive scope and plan bindings from owned verified records, never caller input.
2. **One positive predicate.** Invoke unchanged `Releases.Validation.check(artifact, run, derived_scope)`. `release_admission` passes if and only if that call returns `:ok`; the inspector cannot substitute a weaker predicate or change release behavior. Separate stages may remain `not_assessed` for live availability even when historical evidence satisfies this existing gate. Label the result “Ready for release review”; actual mutation commands repeat admission. No approval or company-fitness claim follows from inspection.
3. **Pure identity projection, no health probe.** Current identities come from `Evaluations.applicability/1`, applicability from `/2`; inspection of these source paths shows configuration/file-derived identity computation rather than runtime availability checks. Do not call `Evaluations.capabilities/0`, `Execution.probe/0` or `Coding.availability/0`. Codex/Claude managed backends stay unavailable; configured OpenCode/model does not establish live availability. Historical errors are labeled selected-run observations.
4. **Allowlisted metadata only.** Project the decision's fixed keys, bounded identifiers/digests and known enum/reason/action values. Never return raw artifacts, run maps, configuration, actor identity, source/rule/goal/task text or exception inspection. Unknown/malformed data cannot pass. Missing/tampered artifacts yield safe blocked integrity and unassessed downstream stages. Plan bindings are sorted provenance pairs, not individually approved-plan assertions. Fixed next-action destinations navigate only.
5. **Invalidate cached observations.** Package changes clear run selection and report; run changes clear the report until explicit refresh. Clear readiness state on privacy reset, revocation and relevant reloads. Authenticate every event; any cached component follows existing mount/reset freshness rules, including stale-event tests. Do not compute/probe from render or introduce asynchronous result lifetime. Restore/quarantine, source purge and later authority changes remain binding.

Source basis: [Artifacts](../../../../../lib/harness_forge/artifacts.ex), [Harnesses](../../../../../lib/harness_forge/harnesses.ex), [Evaluations](../../../../../lib/harness_forge/evaluations.ex), [Coding identity/probe separation](../../../../../lib/harness_forge/execution/coding.ex), [Validation](../../../../../lib/harness_forge/releases/validation.ex), [Portal reset/revocation](../../../../../lib/harness_forge_web/live/portal_live.ex).

## Ownership accepted

| Author | Exclusive source/test ownership |
| --- | --- |
| A | `lib/harness_forge/readiness.ex`, optional `lib/harness_forge/readiness/*.ex`, `test/harness_forge/readiness_test.exs` |
| B | `lib/harness_forge_web/live/portal_live.ex`, `lib/harness_forge_web/components/package_readiness.ex`, `test/harness_forge_web/package_readiness_test.exs` |

Two disjoint authors; preserve others' changes. Root alone owns board/state, shared mix/config/router/application/migrations, source baselines, Mix scheduling and native/browser operations. No gate/compiler/persistence change is authorized by this scope. If one becomes necessary, stop that dependent edit and give root the concrete failure and smallest amendment; independent owned work can continue. No commits, remotes/publication, private imports, credentials, paid inference, permission expansion or host execution of generated code.

## Acceptance remains pending

Use the decision's eight acceptance items without enlarging scope: exact gate parity including privileged synthetic positives; before/after no-write evidence; invalid/foreign/cross-artifact/tampered inputs and private sentinels; each material identity mismatch; failed/cancelled/interrupted/incomplete cleanup states; stale authority and multiple bindings; reset/revocation/cache lifetime; root-operated native flow and scheduled regression checks. Historical artifact samples must retain exact bytes/digests. Synthetic positives prove projection only. Prior tests, Docker evidence, Dialyzer diagnostics and unverified zoom/company outcomes retain their stated limits.

**Status: SELECTED_SCOPE_READY.** Independent implementation/security review follows the frozen candidate and evidence; this document grants no implementation pass.
