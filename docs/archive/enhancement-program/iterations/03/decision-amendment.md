# Iteration03 ADR amendment: conservative runtime-identity abstention

**Status: ROOT_ACCEPTED — 2026-11-01 14:14:21 UTC.** Root read and accepted the full amended contract before dispatching Author A/B corrections. This is a correction within the selected iteration03 unit, not a new feature selection or user permission gate. Original decision and candidate01 failures remain historical records; this accepted amendment supersedes the original unconditional task-identity delegation and full positive-parity promise.

## Context and evidence

Read [A's frozen facts](review/admission-correction-facts.md), current [code](review/code-review.md), [security](review/security-review.md), [UX](review/ux-validation.md) and [QA](review/regression-validation.md) reviews, [machine checks](../../../../../tmp/enhancement-program/03/independent-qa/checks.json), and actual Readiness/Evaluations/Validation/Command/component source. No source edit, Mix, runtime probe or test was performed for this decision.

Canonical01 is **449 registered / 433 passed / 1 timeout failure / 15 skips**, exit 2. The identity matrix exceeded 60 seconds through `Evaluations.applicability_identity/2 → Coding.profile_digest/0 → profile/0 → transport/0 → Command.docker/3`. An OpenCode task identity performs three Docker info calls, potentially each preceded by context lookup. Current inspection computes that profile one to three times: three to nine info calls, up to three to nine context subprocesses. The fixture timeout exposes a real inspector transitive-call violation, not merely a slow test. All prior assertions that this identity path is pure are withdrawn. Focused passes and the narrow health-function trace did not prove no probes.

Dialyzer has the two baseline releases.ex opacity findings **plus two new unreachable branches** at candidate01 Readiness 247 and Portal 470. They require correction without suppression. Root reports the accepted two-line destination-focus fix applied; B reports the owned `load_records/2` fix applied. Those reports do not substitute for corrected-candidate verification. Preserve all failed logs, candidate01 bytes and earlier verdict corrections.

## Decision and alternatives

Choose **context-only conservative abstention**. Retain the existing integrity, current company eligibility, historical evaluation outcome, cleanup, privacy and exact-selection functionality. Refuse to establish current OpenCode task applicability or positive release admission in a read-only inspector when obtaining the trusted current identity requires live commands. Preserve pure selected static/smoke comparison and their exact release refusal. Shared Evaluations, Validation, Coding, Docker and Command remain byte-identical.

This loses the inspector's ability to establish a favorable OpenCode task release preflight. That capability was promised but never delivered without probes. Actual release commands remain unchanged and perform their normal authoritative validation. The smaller truthful inspector still answers useful questions about exact bytes, withdrawn approval, selected evidence and cleanup; it does not answer every release-readiness question.

Alternatives assessed by operator value, admission reliability, scope, simplicity and prerequisites—not votes:

- **Trusted pure route/profile boundary:** could retain full positive parity, but no such current-route source exists. Implementing one entails a new provenance/lifetime/invalidation contract and shared execution/validation integration. Defer.
- **Deterministic configured transport for all callers:** could make profile hashing pure globally, but changes Docker Desktop routing and historical environment identities; requires execution-contract work and Docker isolation verification. Defer as broader than this correction.
- **Inject saved run environment/profile identity, caller identity or a fabricated non-task record:** reject. Historical evidence cannot supply its own current comparison baseline. It can conceal transport drift and either bypass the unchanged gate or change the question evaluated. No synthetic identity may flow into production admission.
- **Allow probes, mock them away or increase timeout:** reject. These abandon the selected bounded read contract or conceal the failed requirement. No timeout increase.

Product/architecture's policy-completeness preference and UX/trust/quality's readiness preference remain unresolved priorities, as does portable authenticated authority. This narrower readiness result must be preserved honestly in the handoff.

## Exact amended domain contract

Public signature stays `Readiness.for_artifact(digest, evaluation_id \\ nil)`, with the original strict inputs, privacy fence, no writes, fixed allowlists and explicit owned run selection. No caller identity/options and no new persistence or shared public API.

1. **Current task identities.** Never call `Evaluations.applicability/1` for verified runtime `opencode`, including no-run/static/smoke/missing-model cases. Set `current_identities` to `%{}` and add:
   ```json
   "current_identity_assessment": {
     "kind": "task",
     "status": "not_assessed",
     "reason_code": "runtime_identity_check_required"
   }
   ```
   This field explicitly describes the full **current task** identity; it does not deny that a selected non-task comparison can be established. Do not fill gaps with selected run values. For verified non-OpenCode targets, the existing pure `/1` may populate current identities and assessment `{kind: task, status: passed, reason_code: current_task_identities_observed}`. Here “passed” means the identity observation succeeded, never runtime support. If artifact integrity fails, assessment is `not_assessed/artifact_integrity_required`. Existing identity allowlists still apply.
2. **Managed runtime metadata.** Preserve registry unavailable-backend behavior. OpenCode missing-model detection may call the independently pure `Coding.model_identity/0`; no task profile digest is needed. A selected model still leaves live availability not assessed. No model configuration bodies are returned.
3. **Matched OpenCode task.** Preserve historical `evaluation` and `cleanup` stage observations/identities exactly as allowlisted. Set both `applicability` and `release_admission` to `not_assessed`, reason `runtime_identity_check_required`. Do not invoke task applicability `/2` or `Validation.check/3` for this branch—even failed task records may safely abstain at release stage while their separate outcome/cleanup stages state the actual blockers. This deliberately avoids maintaining a duplicated classifier of Validation's early-return predicates. A potential-positive stored run never yields `passed`, `blocked` or `ready_for_release_review` merely because current identity is unavailable.
4. **Matched OpenCode static_integrity/runtime_smoke.** Invoke unchanged `Evaluations.applicability/2` on the actual stored record. Its non-task branch uses pure Docker profile constants and verified config bytes. Invoke unchanged Validation on that same record: its kind check returns qualified-task-required before task applicability. Preserve exact applicability match/mismatch and exact release error parity. Do not construct a fake non-task record to assess task evidence.
5. **Matched non-OpenCode known-kind run.** Preserve unchanged pure applicability and Validation calls, including positive gate parity where the existing gate returns :ok. Managed backend remains independently unavailable; a synthetic gate-positive fixture is not evidence of actual managed execution.
6. **Unknown/malformed kinds.** Keep evaluation blocked as invalid. Do not treat an unknown kind as proof of a valid pure static/smoke comparison merely because existing private code would take its non-task branch. Applicability stays not assessed with invalid-record reason; release remains blocked invalid-record. Wrong artifact/workspace/missing-run behavior retains original safe refusal without unrelated run identities. No-run still has no implicit selection.
7. **Actions and missing assessment.** Add fixed action `{code: review_runtime_identity, destination: releases}` for `runtime_identity_check_required`; navigation only. Preserve earlier actual blockers' priority: integrity, eligibility, unsupported backend, failed/incomplete evaluation, incomplete cleanup. If those do not require correction and current applicability/admission abstains, use the new action. Do not bury known cleanup failure behind applicability abstention. `blockers` continues to mean actual blocked/unavailable stages; not-assessed is not a gate rejection and must remain visible in stages/assessment/UI. A separate generic blocked fallback must not convert abstention into a claimed Validation refusal.

**Lost capability, explicitly:** equality between inspector release result and direct Validation is no longer claimed for OpenCode task records. The inspector abstains even if a separately invoked real command would pass or fail. The full material-identity drift matrix remains exact only on trusted pure branches. For OpenCode task inputs, drift tests establish invariant abstention and lack of side effects, not detection of each changed current runtime identity.

## Exact presentation changes

Keep seven stage rows and add safe labels for the fixed assessment metadata. Change the identity disclosure label to **Current task identities**. When empty due to abstention show: **“Current OpenCode task identities were not checked because resolving the runtime transport requires a live check.”** Selected run identities retain their historical label.

For `runtime_identity_check_required`, use: **“Not assessed: the current runtime identity requires a live check. This inspector did not run that check.”** Primary action label: **“Open release review — runtime check required”**. Explain alongside: **“Opening release review does not approve or run anything. An explicit release approval attempt repeats the full existing validation and may check the runtime.”** Do not call it ready, approved, denied by the gate, or a new availability probe button.

Summary/announcement must distinguish three cases: actual earlier blocker → existing precise refusal; abstention without an earlier blocker → **“Release admission was not assessed. A current runtime identity check is required.”**; pure gate :ok → existing bounded ready-for-review language. The runtime-required condition must not fall through to the old generic “Release review is blocked” summary. Keep fixed allowlists for action/reason/assessment keys and values; unknown metadata must fail safely.

## Ownership and sequence

- **Root/conductor first:** accept or reject this proposal internally, then dispatch correction. Root remains sole board/state/shared-file/native/build/browser owner. Existing root focus changes are only `assets/js/app.js` allowlist addition and `company_panel.ex` section tabindex; no further shared change authorized here.
- **Author A:** only `lib/harness_forge/readiness.ex` and `test/harness_forge/readiness_test.exs` (and previously owned readiness submodules if actually needed). Implement abstention/pure-branch policy, safe metadata, action precedence and remove the unreachable fallback without suppression. Tests must not call live-bearing identity helpers to construct inert task fixtures. An inert fixture may contain arbitrary historical digest values for abstention tests, clearly labeled; these values never become current identity.
- **Author B:** existing owned `portal_live.ex`, `package_readiness.ex`, dedicated web test. Preserve existing loader correction; add assessment/copy/action/announcement handling and expanded event trace. No duplicated domain admission. Preserve mount/reset/revocation invalidation.
- **Reviewers/QA:** independent code/security/UX re-review and root-scheduled serial Mix checks after both owners ready. No new sixteen-planner barrier; same iteration correction. Estimated correction/review work 3–5 person-hours, not a wall-clock promise.

## Required no-probe evidence

Add low-level, process-scoped trace assertions around actual synchronous `Readiness.for_artifact/2` and real LiveView Inspect/Refresh events after setup. Include these exact MFAs:

- `HarnessForge.Execution.Command.docker/1`, `/2`, `/3` (default wrappers plus actual implementation).
- `HarnessForge.Execution.Command.local_endpoint/1` and `invoke/4` using local/private call tracing; these cover both Docker context endpoint discovery and command launch. `collect/4` is diagnostic coverage if traced, not a substitute for entry boundaries.
- `Elixir.Port.open/2` **and** `:erlang.open_port/2`, because wrapper inlining can bypass a wrapper-only trace; `Elixir.System.cmd/2` and `/3`. Confirm which trace patterns match in the actual compiled runtime and fail/report unsupported instrumentation rather than silently asserting an empty mailbox.
- Retain `Models.status/0`, `Evaluations.capabilities/0`, `Execution.probe/0`, `Coding.availability/0`; additionally trace `Coding.profile/0`, `profile_digest/0`, private `transport/0` to expose the discovered route.
- `Command.run/*` does **not exist** in the inspected Command module. Record this explicit source/export finding; do not invent a matched MFA. Recheck the corrected source/export inventory. If any run arity appears, include that exact arity and audit its transitive launch boundary before claiming coverage.

Trace the process executing the context and the actual LiveView process, propagating to spawned descendants (`set_on_spawn` or equivalent) if needed. Use a separate collector, enable before event, wait for the synchronous response plus trace-delivery barrier, then assert zero prohibited calls and restore tracing in `after`. Instrumentation must not inspect source bodies or command arguments unnecessarily. Run these cases non-concurrently where global trace patterns require it; fixture setup/LiveView mount may use existing unrelated health machinery outside the measured event and must be excluded explicitly, never silently counted as inspector evidence.

Explain why coverage is complete for this **synchronous call path**: source audit shows task live discovery enters Command.docker, resolves endpoints through local_endpoint/invoke, and launches via Port/open_port; there is no generic Command.run. System.cmd coverage guards an alternative launch route. Readiness and its event introduce no worker/delegation; if one appears, extend trace provenance to that worker or reject the claim. This is bounded observed-path evidence, not proof no subprocess anywhere in the application can run.

## Acceptance before any renewed pass

- Exercise no-run, missing/foreign/cross-artifact run, static, smoke, failed/cancelled/incomplete-cleanup task, and inert potential-positive OpenCode task through the low-level domain/event traces. Every measured path makes zero prohibited calls. The potential-positive task remains explicitly not assessed; no fake native positive.
- Exact static/smoke applicability match and every relevant identity mismatch retain unchanged gate refusal. Non-OpenCode trusted pure fixture preserves final-gate parity. OpenCode task mutation cases all abstain without obtaining or injecting current runtime identity. No increased test timeout, mock hiding command calls, or shared gate change.
- Known evaluation/cleanup failures remain visible and drive sensible actions; no-run and metadata semantics are intelligible. Test announcements distinguish refusal from abstention. Existing strict references, private sentinels, no-write hashes, reset/purge/restore/remount/revocation tests remain meaningful.
- Root repeats focused suites then canonical checks on a new frozen candidate. Dialyzer must return exactly the two unsuppressed baseline diagnostics, with neither new unreachable branch. Format/compile/Credo/JS gates remain required; preserve all candidate01 failures and source snapshots.
- Root rebuilds native candidate and proves actual static/no-run inspection, switching/clearing, task-abstention wording if a suitable inert test record is used, and keyboard corrective navigation focusing `company-panel` with logical next Tab. Retain observed BODY-focus failure. Match native source/process/assets evidence to corrected freeze. Native synthetic evidence remains distinct from live model outcomes and genuine task qualification.
- Reviewers withdraw no evidence retroactively: new verdict applies only to corrected bytes and newly executed checks. Company fitness, portable authority, policy completeness, true zoom and screen-reader certification remain unproven.

If trace completeness or pure branch parity cannot be demonstrated without shared execution changes, escalate to root/`staff-tech-lead` with the exact MFA, observed call, smallest alternatives and lost capability. Do not broaden or weaken admission to rescue a green test.
