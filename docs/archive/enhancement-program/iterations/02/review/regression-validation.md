# Iteration 02 independent regression validation

Owner: `/root/enhancement_conductor/i02_independent_qa`. Final regression verdict: **approved with follow-up for the two unchanged baseline Dialyzer findings**. No product, test, asset or board file was edited by QA. The serialized Mix/Docker window is released; no check remains running. Native acceptance is reported separately by root.

Final evidence is under `tmp/enhancement-program/02/independent-qa/final/`: `checks.json` contains exact commands, environments, exits, wall durations and log paths; `canonical.json` and `docker.json` contain per-test machine results. The existing iteration 01 ExUnit JSON formatter was reused without dependencies or product instrumentation. Dedicated short `/private/tmp/hf02q/final-<check>` runtime roots kept tests away from native/main data and below the Unix-socket path bound.

| Independent check | Actual result |
| --- | --- |
| Canonical `MIX_ENV=test mix test --seed 0` with CLI + JSON formatters | Exit **0**; **417 registered / 402 passed / 0 failed / 15 skipped**; wall **68.626s** |
| `HARNESSFORGE_DOCKER_TESTS=1` targeted three guarded files, `--only docker --seed 0`, same formatters | Exit **0**; **27 registered / 15 passed / 0 failed / 0 skipped / 12 untagged excluded**; wall **268.131s** |
| `MIX_ENV=test mix format --check-formatted` | Exit **0** |
| `MIX_ENV=test mix format --check-formatted packaging/inventory.exs` | Exit **0** |
| `MIX_ENV=test mix compile --warnings-as-errors` | Exit **0** |
| CI `MIX_ENV=test mix credo --strict --only warning` | Exit **0** |
| `node --check assets/js/app.js` | Exit **0** |
| Cached `MIX_ENV=dev mix dialyzer` | Exit **2**; exactly `call_without_opaque` at `releases.ex:47:15` and `121:15`; **zero new diagnostics** |

The exact test invocations use `elixir -r tmp/enhancement-program/01/regression/reporter.exs -S mix test` and append `--formatter ExUnit.CLIFormatter --formatter HarnessForgeIteration01RegressionFormatter`. Docker targets `test/harness_forge/execution_test.exs`, `test/harness_forge/evaluations_test.exs` and `test/harness_forge/coding_evaluation_test.exs`. Full successful and warning output is retained, including the unsuppressed Dialyzer diagnostics; its exit 2 is not relabeled as a passing type check.

`baseline-comparison.json` confirms **14 added tests**, **0 removed**, **0 duplicate identities**, and the identical **15** default-suite opt-in skip identities compared with iteration 01's 403 registered tests. `combined-tests.json` confirms the Docker pass identities exactly equal those 15 skips: **417 unique tests executed and passed across the two final runs**, with **zero duplicate executions**. The 12 excluded untagged Docker-file tests had already passed canonically. Coverage and flake rate remain **unmeasured (`null`)**.

All eight assigned source/test/asset hashes match `tmp/enhancement-program/02/source-freeze-final.json` at QA start and end, and the broader source inventory is unchanged. Exact first/pre-v2, pre-UX-fix, final-freeze, QA-start and QA-end hashes are retained in `final/frozen-source-start.json` and `final/frozen-source-end.json`; see also `final/source-before.json` and `final/source-after.json`. The original [security-review fingerprint table](security-review.md) is untouched: it was captured after the second author window **before v2 admission**, and is not a pristine iteration baseline.

Independent `final/producer-inventory.json` counts **nine forms / nine root hidden generation inputs**, and **22 click definitions / 22 generation attributes**: Guide **5**, Catalog **8**, Plan **9**. These are source-definition counts, supplemented by the canonical rendered-producer regression.

| Finding / surface | Disposition and evidence limit |
| --- | --- |
| S02-02 stale serialized events | Final server regressions pass for unchanged old form/button envelopes after reset, malformed/missing metadata, source/workspace purge, quarantined restore, sibling delivery, remount and valid current controls. No payload-refreshing replay helper is used. Installed browser/channel behavior remains separate root evidence. |
| Capability-search/package-diff error routing | Corrected source routes lookup failures to repository and diff failures to build. The final representative regression passes for malformed/domain-refused queries, missing comparison artifact, open section, fixed error-focus event and retained drafts. |
| S02-01 focused DOM/private lock acknowledgement | This QA run does not inspect browser live values or lock clones. Root owns installed-client reset/ack proof and final native acceptance; server-rendered assertions alone do not close this finding. |
| Existing release type warnings | Exactly the two known opacity findings remain open; no suppression or product scope expansion. |

Docker preflight inspected all 15 guarded tests and the fixed transport/confinement/relay/grader paths before opt-in execution. Fresh final metadata confirmed local Docker client/server **29.7.2**, Linux/arm64 and all three exact OpenCode/nginx/Go digest pins (`final/docker-preflight.json`). Tests exercised actual offline confinement, ownership-aware cancellation/cleanup, metered synthetic local-protocol editing, protected offline grading, forgery rejection and budgets. Candidate execution/grading used fresh synthetic directories and fixed read-only protected fixtures. No image pull, daemon change, external inference or host execution of generated candidate code occurred.

Earlier evidence is preserved in the parent `independent-qa/` directory: the first canonical run passed **416 / 401 / 0 / 15** before the separate UX error-routing correction, and its eight-file end snapshot remained unchanged. The initial metadata probe's eight-second timeout remains in `docker-preflight-attempt-1.json`; the one bounded metadata retry and the fresh final preflight passed. No fixture test failure occurred. These observations do not establish a flake rate, live inference/model quality, managed Codex/Claude support or qualification of a real company harness. CI asset/package work and native Chrome were root-owned, not rerun or claimed by this QA agent.
