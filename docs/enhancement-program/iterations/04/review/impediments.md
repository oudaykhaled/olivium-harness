# Iteration04 impediments and check order

Read [ADR04](../decision.md), [PROGRAM](../../../PROGRAM.md), [conductor](../../../conductor.md), [03 handoff](../../03/handoff-to-04.md) and [accepted amendment](../../03/decision-amendment.md), plus the current component and existing web tests. This is an advisory source review; no Mix, browser, service or product mutation was performed.

## Actual blockers

**None identified for implementation.** The existing component already uses `announcement/1` for both visible summary and polite announcement, and its blocker ordering is explicit. The existing web test file provides genuine persisted static evaluation, actual Inspect/Refresh, inert contrasts, invalid-reference checks, trace instrumentation and reset/privacy coverage. No new dependency, endpoint, domain API, approval or study is needed.

Verification remains pending; historical03 passes do not establish04 results. The concrete scheduling prerequisite is completion of both owned edits before checks. Conductor holds the single granted serialized Mix window: author-focused checks first, independent QA next; root runs no Mix until that window is released. Only root handles frozen candidate/native build, processes, browser and board/state.

## Simplest implementation order

1. Component owner changes only `lib/harness_forge_web/components/package_readiness.ex`. Recognize exactly: evaluation `kind=static_integrity`, `outcome=passed`, `status=passed`; cleanup `status=blocked`, `reason_code=evaluation_cleanup_incomplete`, `cleanup_status=not_started`; release admission `status=blocked`, `reason_code=qualified_task_evaluation_required`.
2. Reuse one contextual explanation for the cleanup row and the summary only when the existing priority actually selects cleanup. Preserve earlier warnings, seven rows, Blocked/Not started labels, action/destination and OpenCode **Not assessed** semantics. Do not change the report.
3. Regression owner changes only `test/harness_forge_web/package_readiness_test.exs`. Extend existing fixtures/helpers; test real static Inspect/Refresh against unchanged domain output, conservative inconsistent-report negatives, smoke/task/failure/invalid/no-run contrasts, earlier-blocker priority and contextual-copy clearing.

## Check contract and escalation

Run proportionate author-focused checks, then independent focused readiness and canonical/tool checks required by ADR04, with actual commands, exits and frozen-byte provenance. Reuse calibrated synchronous event/domain no-probe checks; setup/mount remain excluded. Add no new probe. Preserve historical Docker labeling and the two unsuppressed baseline Dialyzer findings. Root's new native checks cover changed copy, contrasts, switching/lock, focus and layout, including Evaluations destination/next Tab, 320/390 CSS widths and actual 200% zoom. Prior native reset/queued-event evidence may be reused when relevant hashes are unchanged and iteration04 server checks pass.

If a regression arises, first correct the predicate, contextual selection or test setup within the two files. If correctness instead requires domain/shared execution changes, stop that expansion and report the exact failing evidence to conductor/root. Alternatives are retaining the existing conservative presentation while revising scope, or separately approving the smallest evidenced domain change; neither permits weakened admission or fabricated runtime identity. Existing missing managed execution/model/company qualification is a retained limitation, not a prerequisite for this presentation change.
