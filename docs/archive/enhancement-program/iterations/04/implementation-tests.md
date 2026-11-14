# Iteration04 regression implementation

Implemented the [accepted decision](decision.md) in `test/harness_forge_web/package_readiness_test.exs` only: 179 net lines, two new test cases, 15 web cases total. Reuse classification: **extend** the standalone PackageReadiness inspector regressions, existing genuine static fixture, inert persisted records, exact-pair events, calibrated trace collector and reset/auth tests. The repository is standalone; no fleet service dependency or atlas import applies.

The genuine persisted static case exercises actual Inspect and Refresh, verifies the accepted explanation verbatim in the visible summary, polite status and cleanup row, and retains Blocked / Recorded cleanup: Not started / Review evaluations. Each resulting complete report equals the unchanged `Readiness.for_artifact/2` report apart from its observation timestamp. The authoritative release validator still returns `qualified_task_evaluation_required`.

The new rendering matrix rejects 42 single-field mutations across all eight required predicate fields, including missing, nil, unknown and contradictory known values. Four earlier-blocker contrasts preserve integrity, eligibility, unsupported-runtime and evaluation warning priority in both summary locations. A qualifying cleanup row retains its local explanation when an earlier unrelated warning wins; an evaluation blocker fails the predicate.

Existing actual-event coverage now contrasts smoke, passed/failed/blocked/pending/cancelled task observations, task cleanup failure, unknown kind, and failed/incomplete/unknown-outcome/unknown-cleanup static records. Inert task/smoke records establish presentation only. Cleanup-failure incident wording remains visible; OpenCode task applicability/admission remain Not assessed. No-run and forged missing/foreign/cross-artifact submissions receive no static-success explanation. Package switching, reload/evaluation invalidation and both inspectors after source purge clear the contextual copy; existing remount, restore, privacy and auth refusal checks remain.

The calibrated actual-event trace now asserts 28 domain inspections in its expanded matrix, plus six in the existing missing-model contrast. Its existing prohibited command/port/profile probes remain zero, with actual caller/child calibration and no new inspector worker. Setup and mount remain outside this measured synchronous path; this does not claim universal application purity.

## Fresh author verification

Conductor granted one exclusive Mix window after author A released it. Both commands ran sequentially on 2026-11-01 with `MIX_ENV=test`, an isolated `/private/tmp/hf04-author-b` workspace, MCP disabled, Phoenix server disabled and Docker-tagged execution unset:

| Actual command | Exit | Result |
|---|---:|---|
| `mix format test/harness_forge_web/package_readiness_test.exs` | 0 | Only the owned test formatted |
| `mix test test/harness_forge/readiness_test.exs test/harness_forge_web/package_readiness_test.exs` | 0 | First attempt: 38 tests, 0 failures; seed 360096; 5.0 seconds |

Exact arguments, environment, UTC start/end timestamps and exits: [focused-checks.json](../../../../../tmp/enhancement-program/04/author-b/focused-checks.json). Logs are `tmp/enhancement-program/04/author-b/01-format.log` and `02-focused-attempt1.log`; before bytes and the authored diff are retained alongside them. Test-file SHA-256 after checks: `4baf3be83093ecb353a4fc8b4b24dd5ee7a6bdf9ae0253b0068317663713eb5d`.

Mix ownership was explicitly released to conductor immediately after checks. No author browser/native/service/build operation ran. Root owns candidate freeze, independent/canonical/static gates and native acceptance; these focused checks establish no real-model qualification, current runtime health, novice comprehension or company fitness.
