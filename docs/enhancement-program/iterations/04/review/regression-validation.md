# Iteration04 independent regression validation

**Regression/static verdict: PASS for source-freeze-01. MIX RELEASED to conductor immediately after checks.** Canonical: **455 registered / 440 executed and passed / 0 failed / 15 opt-in Docker skips**. Independent focused readiness: **38/38 passed**, zero skips. Both used seed 0 and the retained ExUnit JSON reporter. [Machine checks](../../../../../tmp/enhancement-program/04/independent-qa/candidate-01/checks.json) contain exact argv, environment, UTC timestamps, individual exits and accounting. Native acceptance remains root-owned.

Read repository AGENTS, ADR04, guardrail, accepted03 amendment, prior regression evidence, actual two-file diff and trace collectors. Applied the Tests Review Checklist. This reviewer edited only this report and owned QA evidence; no product/test/shared source, browser/native/service, release build, delegation, remote operation, private import, credentials or paid call.

## Executed checks

Ran serially **2026-11-01 15:44:00–15:45:25 UTC** in the repository. Existing Elixir **1.19.5 / OTP28** toolchain (repository pin OTP28.3.1); Node **26.3.1**. Environment: `MIX_ENV=test` except Dialyzer `dev`; `HARNESSFORGE_MCP_ENABLED=false`, `PHX_SERVER=false`, Docker opt-in unset. Short isolated runtime roots were `/private/tmp/hf04q/candidate-01-<check>`; logs and JSON remain on the full SSD path. The [owned runner](../../../../../tmp/enhancement-program/04/independent-qa/run_check.py) preserves each command's stdout/stderr and refuses evidence overwrites.

| Check | Actual command | Exit/result |
|---|---|---|
| Focused | `elixir -r <existing reporter.exs> -S mix test test/harness_forge/readiness_test.exs test/harness_forge_web/package_readiness_test.exs --seed 0 --formatter ExUnit.CLIFormatter --formatter HarnessForgeIteration01RegressionFormatter` | 0; 38 passed; 5.003s suite |
| Canonical | Same reporter/formatters; `mix test --seed 0` without file filters | 0; 440 passed, 15 skipped; 46.873s suite, 47.894s command |
| Format | `mix format --check-formatted` | 0 |
| Packaging format | `mix format --check-formatted packaging/inventory.exs` | 0 |
| Warning gate | `mix compile --force --warnings-as-errors` | 0; 107 files, no warnings |
| CI Credo | `mix credo --strict --only warning` | 0; 156 files, 23 checks, no issues |
| Inventory | `elixir packaging/inventory.exs <candidate-01/dependency-inventory>` | 0; 44 locked source dependencies, matching lock digest |
| JavaScript | `node --check assets/js/app.js` | 0 |
| Dialyzer | `mix dialyzer` | **2; exactly two baseline findings, zero new** |

Angle-bracket paths abbreviate only this table; exact absolute argv are in `*-command.json`. [Canonical JSON](../../../../../tmp/enhancement-program/04/independent-qa/candidate-01/canonical.json), [stdout](../../../../../tmp/enhancement-program/04/independent-qa/candidate-01/canonical.log) and [accounting](../../../../../tmp/enhancement-program/04/independent-qa/candidate-01/test-accounting.json) preserve every result. All 438 prior canonical passes remain; two new tests pass, no removed tests or duplicates. No failure/retry or timeout increase occurred.

## Behavioral evidence and bounds

The genuine persisted static evaluation passes actual Inspect/Refresh assertions: accepted explanation in visible/polite summaries and cleanup row; complete domain report unchanged except observation time; Blocked/Not started, seven stages, action and authoritative qualified-task refusal retained. Forty-two single-field mutations across eight predicate fields reject contextual copy. Four earlier-blocker contrasts preserve warning priority. Smoke, failed/blocked/incomplete/unknown records, cleanup-failure wording, invalid/foreign selections, switching/reload/remount/auth/privacy/purge/restore clearing and OpenCode task abstention pass. Inert task/smoke fixtures establish rendering, not runtime execution.

[Trace validation](../../../../../tmp/enhancement-program/04/independent-qa/candidate-01/trace-validation.json) binds passing calibrated tests to 24 domain and 28+6 actual-event inspections: all 16 prohibited command/port/profile patterns match, caller/child delivery and barriers pass, zero prohibited calls, no new LiveView workers. Setup/mount are excluded; this is bounded synchronous-path evidence.

[Dialyzer comparison](../../../../../tmp/enhancement-program/04/independent-qa/candidate-01/dialyzer-comparison.json) retains unsuppressed `call_without_opaque` at `releases.ex:47:15` and `121:15`; zero skipped diagnostics. [End freeze verification](../../../../../tmp/enhancement-program/04/independent-qa/candidate-01/freeze-validation-end.json), captured before root's build, matches all **502 current and copied hashes**, manifest SHA-256 `9824176c42ace3c8ea5b6e6386029a9df3cd1148e2fe1114de05e07f6a14ebee`. Exactly two product files differ from baseline. Thirteen freeze-only packaging/tool paths lack baseline coverage; they are not new product edits. No generated overlay drift occurred during QA; later root-build output is separate.

The 15 current Docker skips remain separate from iteration02 execution; [157 relevant historical hashes](../../../../../tmp/enhancement-program/04/independent-qa/candidate-01/historical-comparison.json) match. No fresh Docker run, coverage, flake rate, novice comprehension, screen-reader certification, real-model qualification or company-fitness claim is made. Source inventory is not a complete native/transitive SBOM. Root owns native build/browser verification.
