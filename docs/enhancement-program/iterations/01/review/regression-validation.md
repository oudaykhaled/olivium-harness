# Iteration 01 independent regression validation

Owner: `/root/i01_regression_qa`. Final regression verdict: **approved with follow-up** for the two unchanged baseline Dialyzer findings. The independent final run registered **403 tests: 388 passed, zero failed and 15 skipped**, seed 0. The final source snapshot remained unchanged throughout execution. No product, test or board file was edited by this reviewer. Root received the exclusive Mix window release before native build began; this reviewer has no remaining Mix task.

## Final verified results

The final attempt ran on 2026-11-01, after the sole source owners removed four new Dialyzer diagnostics. `HARNESSFORGE_WORKSPACE` was unset to use the canonical isolated per-process test workspace. The exact commands, environments, start times, exit codes and wall durations are in `tmp/enhancement-program/01/regression/final/checks.json`; test-level results are in the adjacent `canonical.json`, and every command has its own unfiltered log.

| Check | Final observed result |
| --- | --- |
| `MIX_ENV=test mix format --check-formatted` | Exit 0 |
| `MIX_ENV=test mix format --check-formatted packaging/inventory.exs` | Exit 0 |
| `MIX_ENV=test mix compile --warnings-as-errors` | Exit 0 |
| Canonical `mix test --seed 0`, CLI plus JSON formatter | Exit 0; 403 registered, 388 passed, 0 failed, 15 skipped, 0 excluded |
| ExUnit duration / command wall duration | 44.910121 / 45.956226 seconds |
| `MIX_ENV=test mix credo --strict --only warning` | Exit 0; 151 files, 2,095 modules/functions, no issues in this warning gate |
| `MIX_ENV=dev mix dialyzer` | Exit 2; exactly the two existing `releases.ex:47,121` `call_without_opaque` findings; zero new diagnostics |

Coverage remains **unmeasured** (`null`). The machine comparison with the previous 370-test baseline confirms **33 added tests, zero removed tests, and the identical 15 skipped test identities**, with no new skips. See `final/baseline-comparison.json`. CLI and machine counts agree. The two existing Dialyzer diagnostics remain open and have not been suppressed or relabeled as a passing type check.

This verdict covers source regression and the listed check commands. Real SDK/native interoperability, connector authentication, model quality and complete company-harness qualification require their separately owned evidence; these 403 tests do not establish those claims.

## Preserved first attempt and repair evidence

The first attempt ran on 2026-11-01 in the exclusive Mix window granted by root. Commands, exit codes and source hashes are recorded in `tmp/enhancement-program/01/regression/checks.json`; test-level machine evidence is `canonical.json` in that directory. Source content was unchanged during the run.

| Check | First observed result |
| --- | --- |
| Formatter checks, warnings-as-errors compile, CI Credo warning gate | Exit 0 |
| Canonical suite, CLI plus JSON formatter, seed 0 | Exit 2; 403 registered, 387 passed, 1 failed, 15 skipped; 41.434684 seconds ExUnit run time |
| `MIX_ENV=dev mix dialyzer` | Exit 2; six diagnostics, four new and two existing |

The failed test was the existing `HarnessForge.RuntimeRelayTest` Unix socket check at `test/harness_forge/runtime_relay_test.exs:265`. This attempt explicitly placed the workspace in the deeply nested evidence directory; its generated socket path was 117 bytes and exceeded the existing `< 104` byte guard at `execution/relay.ex:221`. The environment proof is `attempt-1-environment.json`. The final run unset that QA override and passed the existing Unix-socket test. No product change was made for this harness configuration error. The first attempt's logs and JSON remain intact.

The first attempt's new Dialyzer `pattern_match_cov` diagnostics were at `mcp/auth.ex:46`, `mcp/protocol.ex:129`, and `mcp/tools.ex:221,242`. Root routed these to the existing sole authors; the implementation coordinator received the exact log path. They were resolved before the independent final run, which reports no MCP diagnostic. No diagnostic suppression was added.

The standalone JSON formatter was required before dependencies were loaded, so its direct Jason reference emitted an infrastructure compile warning in the first test log. The independent product warnings-as-errors compile passed. The final formatter resolves that runtime dependency dynamically, and the final test log contains no such warning. The first formatter and runner are retained as `attempt-1-reporter.exs` and `attempt-1-run_checks.py`.

The author's earlier unfiltered `mix credo --strict` exit 14 is a separate style scan; this reviewer did not execute or validate that scan. It must not be confused with the independently executed CI warning gate above.
