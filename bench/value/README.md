# Value benchmark

Does a harness from Olivium Harness make Claude Code cheaper, better informed or
more accurate on real bugs, compared with no harness and with a free `/init`
`CLAUDE.md`?

`PROTOCOL.md` is the design, written before any paid run. This file is how to run
it and how to read the result.

## Two protocols

`--protocol 1` (the default) is the 2026-11-09 pilot, described in `PROTOCOL.md`.
`--protocol 2` is the second measurement, described in `PROTOCOL-v2.md`: the
new model-free generator (`bin/harnessforge generate`) as the `olivium` arm, the 5
pilot tasks plus held-out tasks from repositories the analyzer was not tuned on
(`corpus/manifest-v2.json`, selected by `corpus/select_heldout.py`; the rule aimed
for 5 and found 3, all from `pallets/werkzeug`), and the harness
run exactly as exported, with its own settings passed with `--settings` and default
permissions. Every agent session in every arm, `/init` included, runs with Claude
Code's `WebSearch` and `WebFetch` removed (`--disallowedTools`), and the meter refuses
any request that offers a web search or fetch server tool: a search runs on the API
side, past the container's isolation, and could find the upstream fix. A run that is
offered a web tool anyway is scored `infra_error`. The pilot code path and its data
are unchanged.

```
OUT=/path/to/new-empty-dir
python3 bench/value/corpus/materialize.py --manifest bench/value/corpus/manifest-v2.json --out $OUT/material
python3 bench/value/run.py prepare --protocol 2 --out $OUT
python3 bench/value/run.py run --protocol 2 --out $OUT
python3 bench/value/analyze.py --in $OUT --out $OUT/report --manifest bench/value/corpus/manifest-v2.json \
  --pilot-results docs/benchmarks/value-2026-11-09/results.json
```

Those commands use the mock model by default. A paid run adds
`--paid --cap-usd 30 --run-cap-usd 3 --key-file /path/to/key-dir/anthropic.key`
to `prepare` and `run`, wrapped in `caffeinate -ims`. Agent images are rebuilt
automatically when their launch script changed.

Protocol 2 also has an information arm, `none-lean`, run only when named with
`--arms` (never in the default selection). It is the `none` arm (same prompt, flags,
permission mode and benchmark settings, no `CLAUDE.md`, no hooks, no file in the
repository) plus only the lean trim of that task's `olivium` export in the same OUT:
`includeGitInstructions` and the bare tool names in `permissions.deny` that
`.olivium/spec.json` lists as `spec.context.deny_tools`. `prepare` derives it from the
export at $0 (`arms/none_lean.py`) and refuses an export that is not lean; `run` checks
it again before the meter starts. A selection that includes `none-lean` keeps its own
schedule file (`schedule.none-lean.json`), so it can run into the same OUT after the
other arms, for example `run --arms none,olivium --repeats 2` and then
`run --arms none-lean --repeats 1`; the meter replays OUT's request log, so `--cap-usd`
counts what earlier invocations into that OUT spent. For a cap of a few dollars, pass
`--total-reserve-usd` (for example 0.10): the meter otherwise holds $1.00 per in-flight
request against the cap, so with two runs at a time it refuses requests from about
cap minus $2.00.

Protocol 3 (`PROTOCOL-v3.md`, benchmark v3) runs the protocol 2 code path with the
v3 manifest, Claude Code pinned, and setups interleaved in seeded blocks. Its scored
run names `none,generic,olivium,none-lean`: `none-lean` is an unscored control that
runs once per task, in the blocks of repeat 1 only. Protocol 3 grades the test command
with a 600 s limit (twice the selection limit), and a paid protocol 3 run refuses to
start while a selection container (`olivium-bench-v3val-*` and similar) is running.
The analysis needs the frozen manifest and the checksum the protocol's change log
records; an OUT that is not a scored protocol 3 run of that manifest on the live meter
is stamped REHEARSAL and gets no verdict:

```
python3 bench/value/analyze.py --protocol 3 --in $OUT --out $OUT/report \
  --manifest bench/value/corpus/manifest-v3.json --manifest-checksum <frozen checksum>
```

v4 development rehearsal (`PROTOCOL-v4dev.md`) adds two protocol-2-only setups, run only
when named with `--arms`: `olivium-ai`, the `lean-ai` export of `bin/harnessforge generate
--context lean-ai --learned DIR`, built from a bundle that `bin/harnessforge learn` makes once
per task base from that commit and its ancestors only; and `olivium-det`, the same export from
a bundle made without cloud learning (deterministic commands and rewrites only). `prepare`
runs the learner in Docker against the runner's meter (`--learn-model`, default
`claude-haiku-5-5`; `--learn-cap-usd`), so learning is metered and counts against `--cap-usd`.
A dry run gives the learner a scripted plan and the bundle says `mock`; a paid run refuses a
mock bundle. `none-lean` reads the same trim from a `lean-ai` export as from a `lean` one, and
refuses when the two exports disagree. Protocol 3 refuses both setups. The harder development
tasks come from `corpus/devtasks_v4.py` (repositories in `corpus/dev-repos-v3.txt` only), and
`analyze_v4.py` compares `olivium-ai` with `none-lean` (stamped MOCK, with no decision, for a
dry run). For dry runs only, `OLIVIUM_BENCH_V4_APP=DIR` runs a frozen application directory
instead of a snapshot of the tree, and `OLIVIUM_BENCH_V4_LEARNER_IMAGE=TAG` names another learner
image; both are recorded in every setup, and `--paid` refuses them:

```
python3 -I bench/value/corpus/devtasks_v4.py select --rules RULES.json --work W --clones C --out D --jobs 1
python3 -I bench/value/corpus/devtasks_v4.py materialize --manifest D/manifest-v4dev.json --out $OUT/material --clones C
python3 bench/value/run.py prepare --protocol 2 --manifest D/manifest-v4dev.json --clones C --material $OUT/material \
  --arms none-lean,olivium,olivium-ai --out $OUT
python3 bench/value/run.py run --protocol 2 --manifest D/manifest-v4dev.json --clones C --material $OUT/material \
  --arms none-lean,olivium-ai --repeats 2 --out $OUT
python3 -I bench/value/analyze_v4.py --out $OUT --manifest D/manifest-v4dev.json --report $OUT/analysis-v4.json
```

## What it measures

Five real bugs from public repositories, taken by rule from recent pull requests.
Each bug is attempted by Claude Code three times in three setups, so 45 scored runs:

| Arm | The agent gets |
| --- | --- |
| `none` | the repository at the commit before the fix, nothing else |
| `generic` | the same, plus a `CLAUDE.md` written by Claude Code's own `/init` |
| `olivium` | the same, plus the files this project generates from the repository's Markdown |

Every run is scored on three questions:

- **Fewer tokens?** Tokens and dollars per run, read from the API responses, and
  cost per solved task.
- **Better context?** How many files it read that the real fix did not touch, and
  how many turns and tool calls passed before it first edited a file the real fix
  changed.
- **More accurate?** Whether the failing tests now pass and nothing else broke, and
  whether the repository's linter still passes.

The agent's patch is applied to a clean checkout, then test files and test
configuration are put back so an agent cannot pass by weakening the tests.

All repository code and all model-written code runs in Docker, never on your
machine. The agent has no route to the internet: its only peer is a small proxy,
the meter, which alone holds the API key and counts every token and dollar.

## Try it for free first

The default mode, `--dry-run`, uses a mock model and contacts no model API.

```
OUT=/some/scratch/dir
python3 bench/value/corpus/materialize.py --out $OUT/material
python3 bench/value/run.py prepare --out $OUT
python3 bench/value/run.py run --out $OUT --repeats 1
python3 bench/value/analyze.py --in $OUT --out $OUT/report
```

`prepare` needs one dependency image per task (`olivium-bench-deps-<task>:v1`), built
by `corpus/select.py` during task selection. It stops with an error if one is missing.

Dry-run output is stamped REHEARSAL everywhere. The mock's costs are scripted, so
a rehearsal shows the machinery works and nothing else.

## Launching the paid pilot

Paid runs need an Anthropic API key and spend real money.

1. Put the key in a file nobody else can read. It holds only the key:

   ```
   mkdir -p /path/to/key-dir && chmod 700 /path/to/key-dir
   # save your API key to /path/to/key-dir/anthropic.key, then:
   chmod 600 /path/to/key-dir/anthropic.key
   ```

2. Keep the laptop awake for the whole run. Sleep can wedge containers and stalls
   the timers. `caffeinate` below does this on macOS.

3. Run a canary first: one task, three arms, one repeat. The paid path has never
   run end to end, so find out cheaply whether it works:

   ```
   CANARY=/path/to/new-canary-dir
   python3 bench/value/corpus/materialize.py --out $CANARY/material --tasks pallets-flask-6133
   caffeinate -dims python3 bench/value/run.py prepare --paid --cap-usd 8 --run-cap-usd 2 \
     --key-file /path/to/key-dir/anthropic.key --tasks pallets-flask-6133 --out $CANARY
   python3 bench/value/run.py status --tasks pallets-flask-6133 --repeats 1 --out $CANARY
   ```

   Check `claims_approved` in the status output. If it is 0, the arm has no content
   and the benchmark must not proceed. The real proposal call may reject a whole
   proposal when one citation is wrong, so read this before spending more. Then:

   ```
   caffeinate -dims python3 bench/value/run.py run --paid --cap-usd 8 --run-cap-usd 2 \
     --key-file /path/to/key-dir/anthropic.key --tasks pallets-flask-6133 --repeats 1 --out $CANARY
   python3 bench/value/analyze.py --in $CANARY --out $CANARY/report
   ```

4. If the canary looks right, launch the pilot in a new directory:

   ```
   OUT=/path/to/new-pilot-dir
   python3 bench/value/corpus/materialize.py --out $OUT/material
   caffeinate -dims python3 bench/value/run.py prepare --paid --cap-usd 150 --run-cap-usd 3 \
     --key-file /path/to/key-dir/anthropic.key --out $OUT
   python3 bench/value/run.py status --out $OUT
   caffeinate -dims python3 bench/value/run.py run --paid --cap-usd 150 --run-cap-usd 3 \
     --key-file /path/to/key-dir/anthropic.key --repeats 3 --out $OUT
   python3 bench/value/analyze.py --in $OUT --out $OUT/report
   ```

If a run is interrupted, re-run the same command. Finished trials are kept, and a
trial cut off half way is recorded as an infrastructure error and repeated.

## What it costs

No real run has been measured yet, so these are estimates from the published
prices (Sonnet: $2 per million input tokens, $10 output, $2.50 cache write, $0.10
cache read).

| Item | Estimate |
| --- | ---: |
| One scored run (20 to 60 turns) | $0.30 to $1.50 |
| 45 scored runs | $15 to $70 |
| Setup, `/init` on 5 tasks | $1 to $4 |
| Setup, claim proposals (limit $1 per task) | up to $5 |
| **Expected total** | **$20 to $80** |
| One-task canary | $2 to $6 |

The caps in the commands above limit what it can spend: $3 per run and $150 in
total. In-flight requests can pass a cap by what they cost above the $1 reserve per
request. If every run hit its cap the ceiling would be about $158 (45 runs, the
as-exported run, `/init` and proposals), so $150 could stop the run early. To
tighten the limit, lower `--cap-usd`; when the total cap is reached the run stops
and the remaining trials stay unscored.

Setup is reported separately from the scored runs. An interrupted paid trial still
counts what it spent, and its replacement counts again.

## How long it takes

Also an estimate. Runs go two at a time, and each run is the agent's session plus
about a minute of grading.

| | Time |
| --- | ---: |
| `prepare` | 15 to 30 minutes |
| 45 runs, typical session of 5 to 10 minutes | about 2 to 4 hours |
| 45 runs, every session hitting the 20-minute limit | about 8 hours |

## Reading the output

`analyze.py` writes three kinds of file to its `--out` directory.

- `report.md` answers the three questions in plain language, then shows the tables.
- `results.json` holds every number the report uses. Only numbers from this file
  reach the project README.
- `chart_*.svg` show cost per solved task, cost by task and arm, and one chart per
  question.

How to read a difference:

- Differences are **olivium minus the other arm**. A negative cost difference means
  olivium was cheaper. A positive `solved` difference means olivium solved more.
- Each task's repeats are averaged first, then the median across tasks is taken.
- The range in brackets is a 95% bootstrap interval across tasks. If it includes
  zero, this pilot cannot tell the arms apart on that measure.
- **Five tasks is a pilot.** It can show a direction and it can show a problem. It
  cannot prove a general effect, and the report says so next to the numbers.
- `n/a` means no run produced that number, for example no run ever edited a file
  the real fix changed.

Other things to check:

- `budget_exhausted` runs were cut off by a spending limit. They count as unsolved
  and their cost counts. A run stopped by the total cap ends the whole benchmark.
- `infra_error` runs were interrupted by something other than the model. They are
  left out of the scores and repeated, up to 3 attempts. Their cost is shown
  separately.
- Anything marked **REHEARSAL** is mock output and must not be published.

## What this cannot show

Five bugs, one model, one agent, two languages, bug fixes only. Today's pipeline
reads a repository's documentation, not its code or history. See `PROTOCOL.md`.

## Files

| Path | What it is |
| --- | --- |
| `PROTOCOL.md` | The pre-registered design of the pilot and its change log |
| `PROTOCOL-v2.md` | The pre-registered design of the second measurement (generator, held-out tasks) |
| `PROTOCOL-v2.sha256` | The protocol's checksum at each state. Since 2026-11-14 the published `PROTOCOL.md` and `PROTOCOL-v2.md` have the output folder replaced by `<bench-out>`, so these are digests of the unredacted original; see `docs/benchmarks/PLACEHOLDERS.txt` |
| `run.py` | The runner: `prepare`, `run`, `status` |
| `analyze.py` | The statistics and report |
| `PROTOCOL-v4dev.md`, `analyze_v4.py`, `test_analyze_v4.py` | The v4 development rehearsal: its protocol, analysis and hand-computed checks |
| `corpus/devtasks_v4.py`, `arms/olivium_ai.py` | v4 harder development tasks; the `olivium-ai` and `olivium-det` setups |
| `corpus/` | The frozen task lists (`manifest.json` for the pilot, `manifest-v2.json` with held-out flags), by reference only, and the rejected candidates |
| `meter/` | The proxy that holds the key and counts usage |
| `docker/` | The agent image and network setup |
| `arms/`, `grade/`, `lib/` | Building the arms, grading a patch, and shared code |
| `test_analyze.py` | Hand-computed checks of the statistics |

The repository stores references only. Third-party source, issue text and test
patches are fetched into your scratch directory by `materialize.py`.
