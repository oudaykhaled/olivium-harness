# Value benchmark v2r: re-run of the 8 v2 tasks with the current generator

> **These are development tasks.** The generator was changed while looking at results on these same 8 tasks, including the three `pallets/werkzeug` tasks that the v2 protocol called held-out. No task here is held out. The result can show a direction or a problem on tasks the generator was tuned on. It cannot show a gain on unseen repositories.

- Protocol: `bench/value/PROTOCOL-v2r.md`, SHA-256 `f5b92f61bd59c1da6bcba4a2af75cf97d9307087f4fff8c712279652b2aa89f6` at the paid run (recorded before the first paid request).
- Runs: 2026-11-14 UTC. `/init` setup 02:56:48Z to 02:59:30Z; scored runs 03:00:06Z to 03:54:26Z, including one resumed attempt. The directory name `value-v2r-2026-11-13` is the one the protocol fixed in advance.
- Claude Code 2.1.311, model `claude-sonnet-5-5`, one headless session per run in its own Docker container whose only network peer is a metering proxy. Limits per run: 60 turns, 20 minutes, $3.
- 8 tasks x 4 arms x 3 repeats = 96 scored runs, in one order shuffled with seed `20261108`, two at a time.
- Graded by the real pull request's hidden tests in a fresh container with no network. Solved means every fail-to-pass test passes, no pass-to-pass test regresses, and the session ended `completed`.
- Analysis: `bench/value/analyze_v2r.py` (fixed before the paid run). Numbers below come from `results.json` in this directory unless a line says otherwise.

## Arms

| Arm | What the agent gets | Settings, permission mode |
| --- | --- | --- |
| `none` | The repository at the commit before the fix, instruction files removed. | benchmark settings, `bypassPermissions` |
| `generic` | Same, plus a `CLAUDE.md` written by Claude Code's own `/init` at that commit (run again for this version, metered as setup). | benchmark settings, `bypassPermissions` |
| `olivium` | Same, plus the unmodified output of `bin/harnessforge generate PATH --runtime claude_code --export DIR --json` with the generator's defaults: `lean` context, generated skills and subagents. | the exported `.claude/settings.json`, byte for byte; `default` |
| `olivium-nn` | Same as `olivium`, same application snapshot and input, with `--native none`: no generated skills or subagents. Its settings deny the `Skill` and `Task` tools. | its exported settings, byte for byte; `default` |

`olivium - olivium-nn` therefore compares the whole native configuration (generated skill and subagent files, the Skill and Agent tool definitions, and the built-in-agent rules), not the skill and agent files alone.

## Per arm (24 scored runs each)

| Arm | Solved | Total cost | Cost per solved run | Median cost per run | Median tokens per run | Mean turns | Runs with a pass-to-pass regression | Permission denials | Stop-hook blocks |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `none` | 15 | $1.2104 | $0.0807 | $0.0517 | 108,861 | 5.54 | 3 | 0 | 0 |
| `generic` | 13 | $1.4723 | $0.1133 | $0.0559 | 121,602 | 5.92 | 3 | 0 | 0 |
| `olivium` | 18 | $1.2075 | $0.0671 | $0.0487 | 65,976.5 | 5.50 | 0 | 0 | 0 |
| `olivium-nn` | 15 | $1.0653 | $0.0710 | $0.0460 | 43,249 | 5.71 | 1 | 0 | 0 |

- Setup cost: `generic` $0.4991 for the 8 `/init` sessions ($0.0447 to $0.0900 per task). `none`, `olivium` and `olivium-nn` $0 (the generator calls no model). With setup included, `generic` costs $0.1516 per solved run.
- Tokens are API-reported input, output, cache-write and cache-read tokens, unweighted. Most are cache reads, which cost far less than input, so token and dollar differences do not move together.
- Mean turns, regressions, denials and hook blocks come from the independent recomputation (see below), which agrees with the trial rows.
- The only tool errors outside the Bash tool were 7 calls to a tool named `bash` in lower case, which does not exist (`olivium` 4, `none` 2, `olivium-nn` 1). These are naming errors by the model, not refusals.

## Primary comparisons

Median of the per-task differences (first arm minus second), with a percentile bootstrap 95% interval over the 8 tasks (10,000 resamples, seed `20261108`).

| Comparison | Total tokens per run | Cost per run | Solved share |
| --- | --- | --- | --- |
| `olivium` - `none` | -53,197 [-72,241, -16,825] | -$0.0039 [-$0.0093, +$0.0162] | 0.00 [0.00, 0.00] |
| `olivium` - `olivium-nn` | +14,957 [-7,723, +31,014] | +$0.0066 [-$0.0105, +$0.0191] | 0.00 [0.00, +0.33] |
| `olivium` - `generic` | -57,708 [-97,268, -29,319] | -$0.0107 [-$0.0199, -$0.0003] | 0.00 [0.00, +0.67] |

An interval that includes zero is a difference these data cannot tell from no effect.

- **`olivium` against `none`.** Fewer tokens per run; the interval excludes zero, and 7 of 8 tasks were lower (`pallets-click-3769` was higher by 24,173). Cost per run cannot be told from zero. Solved 18 of 24 against 15 of 24, but all 3 extra solves come from one task, `pallets-werkzeug-3266` (3/3 against 0/3), so the median per-task difference is 0.
- **`olivium` against `olivium-nn`.** No difference in tokens, cost or solved share can be told from zero. The export without skills and subagents had the lowest median tokens per run of all arms (43,249). The generated skills and subagents were not used in any solved run, so this run cannot attribute an effect to them.
- **`olivium` against `generic`.** Fewer tokens per run; the interval excludes zero. Cost per run is lower and its interval excludes zero, but the upper end (-$0.0003) is close to zero, and `generic`'s $0.4991 setup cost is not included. Solved share cannot be told from zero.
- Secondary metrics (turns, files read outside the real fix, turns before the first edit to a fixed file, pass-to-pass regressions) show no difference whose interval excludes zero in any comparison.

## Per task

Solved out of 3, mean cost per run, mean total tokens per run.

| Task | `none` | `generic` | `olivium` | `olivium-nn` |
| --- | ---: | ---: | ---: | ---: |
| pallets-click-3858 | 3/3, $0.0661, 126,363 | 3/3, $0.0845, 200,053 | 3/3, $0.0666, 77,790 | 3/3, $0.0483, 46,776 |
| pallets-flask-6096 | 3/3, $0.0456, 136,099 | 3/3, $0.0492, 133,840 | 3/3, $0.0388, 63,858 | 3/3, $0.0395, 58,899 |
| python-attrs-attrs-1593 | 3/3, $0.0362, 96,905 | 3/3, $0.0469, 136,351 | 3/3, $0.0269, 39,083 | 3/3, $0.0222, 27,621 |
| expressjs-express-7366 | 3/3, $0.0255, 78,216 | 3/3, $0.0346, 90,711 | 3/3, $0.0436, 61,392 | 3/3, $0.0236, 39,376 |
| pallets-click-3769 | 0/3, $0.0331, 73,405 | 0/3, $0.0496, 123,202 | 0/3, $0.0492, 97,578 | 0/3, $0.0301, 45,091 |
| pallets-werkzeug-3298 | 3/3, $0.0585, 118,910 | 1/3, $0.0627, 98,116 | 3/3, $0.0518, 52,682 | 1/3, $0.0637, 82,839 |
| pallets-werkzeug-3273 | 0/3, $0.0719, 114,782 | 0/3, $0.0736, 111,652 | 0/3, $0.0709, 70,878 | 0/3, $0.0624, 52,426 |
| pallets-werkzeug-3266 | 0/3, $0.0665, 146,319 | 0/3, $0.0897, 151,417 | 3/3, $0.0547, 67,497 | 2/3, $0.0652, 75,220 |

Two tasks were solved by no arm and four were solved 3/3 by every arm, so the solved-share intervals are close to degenerate.

## Use of generated skills and subagents

Counted from the session transcripts (Skill and Agent/Task tool calls).
- `olivium` called a generated skill in 6 of 24 runs, once per run: `olivium-area-click-2` in all 3 runs of `pallets-click-3769`, and `olivium-area-werkzeug` in all 3 runs of `pallets-werkzeug-3273`. No arm solved either task.
- No run in any arm started a subagent, generated or built-in.
- None of the 18 solved `olivium` runs used a skill or a subagent.

## What the sessions were offered

From each session's init event.
- `olivium` on the 7 tasks with generated skills: the generated skills plus two bundled skills, `doctor` and `plugin-authoring`, although these exports set `disableBundledSkills`. The protocol's change log, written after the mock rehearsal, mentions only `plugin-authoring`.
- `olivium` on `expressjs-express-7366` (no generated skill) and `olivium-nn` on every task: these exports do not set `disableBundledSkills`, and all 16 bundled skills were listed. In `olivium-nn` the `Skill` and `Task` tools are denied, so none of them could be called.
- `none` and `generic`: the 16 bundled skills.
- Every arm's init event listed the built-in agents (`Explore`, `general-purpose`, `Plan`, `statusline-setup`). `olivium` also listed `olivium-test-runner`, and `olivium-locator` on the werkzeug tasks. `olivium`'s settings deny three of the built-in agents by name.

`olivium` was measured with these bundled skills listed. This is product behaviour, measured as exported.

## Native files in the exports

| Task | `olivium` files / bytes | Generated skills | Generated subagents | `olivium-nn` files / bytes |
| --- | ---: | ---: | --- | ---: |
| expressjs-express-7366 | 14 / 94,971 | 0 | test-runner | 12 / 86,606 |
| pallets-click-3769 | 17 / 118,475 | 3 | test-runner | 12 / 96,477 |
| pallets-click-3858 | 16 / 111,382 | 2 | test-runner | 12 / 94,202 |
| pallets-flask-6096 | 15 / 101,468 | 1 | test-runner | 12 / 89,638 |
| pallets-werkzeug-3266 | 18 / 124,958 | 3 | locator, test-runner | 12 / 99,584 |
| pallets-werkzeug-3273 | 17 / 123,985 | 2 | locator, test-runner | 12 / 101,106 |
| pallets-werkzeug-3298 | 18 / 143,419 | 3 | locator, test-runner | 12 / 114,088 |
| python-attrs-attrs-1593 | 16 / 118,565 | 2 | test-runner | 12 / 100,362 |

Bytes are the whole export, `.olivium/` metadata included; the agent reads only what it opens. Skill names per task are in `results.json` under `native_in_olivium_export`.

## Spend (metered)

| Item | Requests | USD |
| --- | ---: | ---: |
| `/init` setup for `generic`, 8 sessions | 35 | $0.499052 |
| 96 scored runs | | $4.955478 |
| 1 `infra_error` attempt (not in any per-run figure) | | $0.052524 |
| **Total** (cap $15) | **587** | **$5.507054** |

Program spend before this run was $27.42 of $60 approved. A real `learn` check earlier the same day cost $0.07, and this run $5.51, so the total after it is $33.00. The four mock rehearsals before the paid run used the mock meter only (364 rows, $0).

## Protocol checks and execution

- Protocol hash: `e7871636...` recorded at 02:16:44Z before preparation; `f5b92f61...` after the change-log entry at 02:48:44Z and again at 02:56:22Z. The first paid request is at 02:56:48Z. Both copies of the protocol (the repository file and the frozen runner copy) hash to `f5b92f61...`.
- The paid commands ran from a frozen copy of `bench/value` (79 files, all digests unchanged before and after the run). The generator source was unchanged since preparation. The 8 agent images had the recorded ids, equal to the v2 scored run's.
- Stop rules:
  - total cap not reached (largest cumulative total $5.507, largest run $0.1003, largest request $0.0436);
  - 1 `infra_error` (limit: more than 9);
  - 0 web tool uses;
  - 0 harness-check failures in 97 attempts;
  - all 97 trial rows on Claude Code 2.1.311 and `claude-sonnet-5-5`;
  - highest turn count 10 (limit 60), longest run 103 s (limit 20 minutes).
- The schedule (96 unique entries, the full grid) was written at 03:00:04Z, before the first run at 03:00:06Z. The run log follows its order exactly, plus one retry at the end. At most 2 sessions ran at once.
- Rows: 97 trial rows = 96 scored runs + 1 `infra_error` row. The analysis printed `LIVE: 97 rows`.

### The one repeated run

`python-attrs-attrs-1593.generic.r2` ended with exit code 137 after 67 s, with no result event and empty stderr, while the agent's own command `uv run ruff check ...; pytest -n auto` was running. The container has a 1,500 MB memory and swap limit and 2 CPUs. The runner scores any nonzero exit without a result as `infra_error`, and the protocol allows an `infra_error` run to be repeated, so the run was resumed with the same command; the second attempt completed and solved.

**The cause of the kill is not established.** It may have been the agent's own `pytest -n auto` exceeding the container's memory, which would be a failure caused by the model, not an infrastructure error. No other of the 97 transcripts used `-n auto`. Scored as a failure instead, `generic` would be 12 of 24 solved and its `python-attrs-attrs-1593` cell 2/3; no primary median would change. Later runner versions should record the container's OOM-killed state.

## Independent check and corrections

A separate check recomputed every figure from the raw rows (meter requests, trial and attempt rows, the schedule, and each trial's grade, details, state, meter rows and transcript) with scripts that import no benchmark code. Every headline number matched: meter rows and total, setup cost, per-arm figures, all nine primary-comparison values (in manifest task order), per-task solved counts, native coverage and skill use.

It found these slips in the run's written summary. This report uses the recomputed values:

| Item | Run summary | Corrected |
| --- | --- | --- |
| Spend of the 96 scored runs | $4.955318 | $4.955478 (= $5.507054 - $0.499052 - $0.052524, and the sum of the per-arm totals) |
| Mean cost per run, `pallets-click-3858` `generic` | $0.085 | $0.0845 ($0.084 at 3 decimals; it had been rounded twice) |
| Mean cost per run, `expressjs-express-7366` `none` | $0.026 | $0.0255 ($0.025 at 3 decimals) |
| Mean cost per run, `pallets-werkzeug-3266` `none` | $0.067 | $0.0665 ($0.066 at 3 decimals) |
| Paid run window | 03:00Z to 03:53Z | 03:00Z to 03:54Z, including the resumed attempt |
| `olivium` median tokens per run | 65,976 | 65,976.5 |
| Repeated run | "an infrastructure kill" | cause not established (see above) |
| Bundled skills on the Express task and in `olivium-nn` | listed although the export disables bundled skills | these exports do not set `disableBundledSkills`; only the 7 exports with generated skills set it |

The bootstrap intervals are computed over tasks in manifest order. With 8 tasks their ends are coarse: under other task orders with the same seed, some ends move by one discrete step (for example the `olivium` - `none` cost upper end from +$0.0093 to +$0.0162, and the `olivium` - `generic` solved upper end from 0.50 to 0.67). No conclusion about zero changes in any of the 42 orders tried.

## Comparison with earlier runs

The v2 run (2026-11-10, `docs/benchmarks/value-v2-2026-11-09` and `value-v2-2026-11-10-fix`) used the same 8 tasks, model and Claude Code version, with an older generator and a different `/init` file. Those are different runs on different days, not a paired comparison. In v2, every setup solved 15 of 24, and after the fix the harness showed no clear cost difference.

## Limits

- 8 development tasks from 5 repositories, which the generator was tuned on. Not held out.
- One model, one agent, bug fixes only (7 Python, 1 JavaScript), 3 repeats per arm.
- Sessions were short (median 5 turns, mostly Bash). Skills were rarely used and subagents never, so this run cannot show what they add when used.
- `olivium - olivium-nn` compares whole native configurations, not the skill and agent files alone.
- Bundled skills were listed in `olivium` sessions although its export disables them, and `olivium` was measured with them.
- `generic` used a newly generated `/init` file, not the stored v2 one.
- The baselines run with permission checks bypassed and the exported arms with their own permissions, as registered.

## Commands

Run from a frozen copy of `bench/value`. `<bench-out>` is the benchmark output folder in the home directory and `<key-file>` the API key file. The paid commands ran under a local lock that serializes Docker-heavy jobs and under `caffeinate -ims` (macOS sleep prevention); neither changes the command.

```sh
python3 -B run.py prepare --protocol 2 --paid --cap-usd 15 --run-cap-usd 3 --total-reserve-usd 0.25 \
  --key-file <key-file> --arms none,generic,olivium,olivium-nn --out <bench-out>/value-v2r-2026-11-13
#   exit 0; generic ok on 8 tasks; meter $0.499052, 35 requests
python3 -B run.py run --protocol 2 --paid --cap-usd 15 --run-cap-usd 3 --total-reserve-usd 0.25 \
  --max-infra-errors 9 --key-file <key-file> --arms none,generic,olivium,olivium-nn --repeats 3 \
  --out <bench-out>/value-v2r-2026-11-13
#   first invocation: exit 1, 1 pending (python-attrs-attrs-1593.generic.r2, infra_error)
#   same command again (the runner's resume): exit 0, 0 pending
python3 -B run.py status --protocol 2 --out <bench-out>/value-v2r-2026-11-13 \
  --arms none,generic,olivium,olivium-nn --repeats 3
#   completed 96, infra_error 1, pending 0, recorded_rows 97, solved 61; meter $5.507054, 587 requests
python3 -B analyze_v2r.py --in <bench-out>/value-v2r-2026-11-13 --out DIR
#   LIVE: 97 rows; exit 0
```

## Files

- `results.json`: the analysis output, byte for byte (no local paths in it).
- `provenance.json`: protocol hashes, snapshot digests, image ids, caps, spend, checks and the SHA-256 of `results.json` and this file.

Not published here: third-party source, issue text, patches, transcripts, test logs and the generated arm files.
