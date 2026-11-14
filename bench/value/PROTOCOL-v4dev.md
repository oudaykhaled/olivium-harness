# v4 development rehearsal: protocol

Written on 2026-11-11 by lane D of the v4 build, before any v4 paid run. Nothing below may change once the first
paid request of the rehearsal is sent. The sha256 of this file is recorded outside the repository next to the run
plan, and the plan checks it before spending.

**What this is.** A paid rehearsal on development data. It checks whether the `olivium-ai` setup (the `lean-ai`
export plus a bundle learned from the repository's history) uses fewer tokens or solves more than the trim-only
control `none-lean`, on harder tasks, before any held-out benchmark. Its numbers are **not evidence of value** and
are never quoted as such. Only the held-out benchmark, run once under its own protocol, can be.

## Tasks

- The tasks of `manifest-v4dev.json`, written by `corpus/devtasks_v4.py select` under the frozen rules file
  `dev-rules-v4.json` (schema `olivium.v4dev-rules/1`). The manifest checksum and the rules sha256 are recorded in
  the run plan before any paid request.
- Repositories: `corpus/dev-repos-v3.txt` only, which the benchmark v3 protocol excludes from its pool. No v3 file,
  candidate or task is read.
- Rule summary: merged on or after 2026-01-01; a closing reference to an issue of the same repository, at most 365
  days old, at least 20 words of prose; 1 to 6 non-test code files, and harder means 2 or more code files or 60 or
  more code lines; 400 non-test lines or fewer; at least 1 test file; no dependency change; Docker fail-to-pass 3 of
  3 per side with network none; the real fix graded solved by `grade/` with protected paths on; at most 2 tasks per
  repository; at least 2 JavaScript or TypeScript tasks.
- The 8 easy v2 tasks are not part of this rehearsal.
- **Difficulty screen (P2; amendment of 2026-11-12).** Before the rehearsal, one paid `none-lean` run per task,
  into an OUT of its own. `screen_v4.py` keeps a task if that run used 7 or more requests or did not solve it
  (design.md section 7) and writes `manifest-v4dev-screened.json` with its own checksum. The rehearsal runs on the
  screened manifest only. The screen runs are never reused or scored by the rehearsal, and no later filter is
  applied to rehearsal runs. If fewer than 4 tasks pass the screen, the rehearsal does not run: report it.

## Setups

| Setup | The agent gets | Settings and permission mode |
|---|---|---|
| `none-lean` | The repository at the base commit, plus only the lean trim (`includeGitInstructions` and the bare tool names the export denies), read from the task's `olivium-ai` export and checked equal to the `olivium` export's trim | `arms/benchmark-settings.json` plus the trim; `bypassPermissions` |
| `olivium` | The current static generator's `lean` export, installed unmodified (reference) | Its exported settings; `default` |
| `olivium-ai` | The `lean-ai` export built with `--learned` from a bundle that `bin/harnessforge learn` made once for the task's base commit, installed unmodified | Its exported settings; `default` |
| `olivium-det` | The same `lean-ai` export built from a bundle made without `--allow-cloud` (no model; only verified deterministic commands and rewrites), installed unmodified: what the AI part adds over the deterministic index, card and verified commands | Its exported settings; `default` |

- **Learning input.** The truncated repository (the base commit and its ancestors only, no tags, no remote),
  checked by `assert_no_post_base` before the learner runs and again on the export and the bundle. No GitHub
  issue, pull request or review data. The learner never sees the task prompt.
- **Learning engine.** Claude Code 2.1.311 in the learner image, on the runner's internal network, whose only
  peer is the meter (run id `learn-<repository>-<base12>`). Model: `claude-haiku-5-5` unless the learner-model step
  (P1) chose otherwise before this file's hash was recorded. Meter per-run cap for one learning run: $0.10 Haiku,
  $0.50 Sonnet. 15 turns. Commands and rewrites verified in the task's dependency image with network none.
- **Bundles (amendment of 2026-11-12).** `prepare` reuses the bundles inspected in the v4 repair round, copied
  byte for byte into `OUT/learned/<task>-ai` before `prepare` runs, so the rehearsal scores the bundles that
  were checked. Their learning cost is the bundle's own learner record (paid in the repair round) and is reported
  with every token ratio.
- **Refusals.** A paid run refuses a `mock` bundle, a bundle whose sha256 does not match, an export changed after
  `prepare`, a pinned application directory (`OLIVIUM_BENCH_V4_APP`) and a learner image override
  (`OLIVIUM_BENCH_V4_LEARNER_IMAGE`); both of those are for dry runs only.
- Agent constants are the protocol-2 ones: `claude-sonnet-5-5`, 60 turns, 1,200 s, `WebSearch` and `WebFetch`
  removed, `UV_NO_SYNC=1`, hook events recorded. Amendment of 2026-11-12: **1 session at a time**
  (`run.py run --sessions 1`), so a run and its meter stay at 2 containers on a Docker host shared with other work.

## Runs, order and money

- **Invocation 1:** `none-lean` and `olivium-ai`, 2 repeats each, one seeded shuffle (seed 20261108).
- **Invocation 2:** `olivium-det` (ablation), then `olivium` (reference), 1 repeat each, after invocation 1, into
  the same OUT. If the money left after invocation 1 does not cover both, the ablation runs and the reference is
  skipped and reported.
- **Learning:** once per task base, in `prepare --paid`, before invocation 1. It counts against the same total cap.
- **Total cap $6.00** across learning and both invocations (the meter replays OUT's request log). Per-run cap
  $1.00. Reserve $0.10 per in-flight request.
- If the cap stops invocation 1, the rehearsal is incomplete (no decision). Invocation 2 only loses the reference
  and the ablation.
- A run interrupted by something other than the model is `infra_error` and repeated, up to 3 attempts. Its cost
  counts.

## Measures

- **Tokens per run** = input + output + cache_creation + cache_read of the run's meter `messages` rows
  (`trials.jsonl` `tokens`), unweighted. Dollars are reported but secondary.
- **Solved** = every fail-to-pass test passes, no pass-to-pass regression, as graded by `grade/`.
- **Task-balanced mean:** per task the mean over its scored repeats, then the mean over the tasks scored in both
  compared setups.
- **Secondaries:** requests per run; first-request tokens; tokens before the first edit of a gold file; locator
  cards shown and whether a gold file is in the card; rewrites fired; failed calls; test output bytes; the token
  difference split into configuration (first-request difference times requests) and behaviour (the rest).
- **Learning cost:** per task base, tokens and dollars from the meter; the mean per base; the break-even number of
  runs (learning tokens divided by tokens saved per run).

## Decision rule (harder tasks, `olivium-ai` against `none-lean`)

- **Continue** to a new freeze and the held-out benchmark if the task-balanced token ratio
  `olivium-ai / none-lean` is at most **0.80**, or the solve rate is at least **15 points** higher with the ratio
  at most **1.0**.
- **Otherwise:** report, and stop or redesign.
- **Incomplete** (a scheduled run missing, or a run stopped by a budget): no decision.
- The program target (ratio at most 0.75 with solve rate within 10 points, or solve rate +20 points with tokens
  within 10%) is reported for information.
- Every token ratio is reported with the learning tokens and dollars per task base and the break-even number of
  sessions on the same base, in the same line.

## What this run can show (amendment of 2026-11-12)

This is a screening run, not a test of the target, and its most likely result is `stop_or_redesign`:

- **Lever reach.** On the 7 development tasks the locator card was right (gold file printed) on 3 in the
  integration's $0 check. If those 3 got the design's best case for all levers (-39%) and the other 4 cost nothing,
  the task-balanced ratio would be about 0.83: above the 0.80 continue bar.
- **Noise.** With about 7 tasks and 2 repeats (Gate 1 spread), a true ratio of 0.75 passes the continue bar only
  about 54 to 68% of the time, and a true 0.90 about 6 to 11%; the solve route fires about 10% of the time with no
  real effect.
- So a `continue` is a reason to run the held-out benchmark, never evidence of value, and a `stop_or_redesign` on
  this set says little about a better lever.

## Analysis

- Script: `analyze_v4.py` (standard library only; reads data, executes nothing), checked by
  `test_analyze_v4.py`. Command: `python3 -I bench/value/analyze_v4.py --out OUT --manifest MANIFEST --report
  REPORT.json --md REPORT.md`.
- An OUT with any mock meter row, rehearsal setup or mock bundle is stamped MOCK and gets no decision.
- The sha256 of `analyze_v4.py` is recorded with this file's sha256 before any paid request.
- The difficulty screen is `screen_v4.py` (standard library only; reads data, executes nothing), checked by
  `test_screen_v4.py`; its sha256 is recorded in the same file. The analysis takes the screened manifest.

## What this rehearsal does not change

Protocols 1, 2 and 3, their manifests, grading, outcomes, verdict bars and isolation rules. The `olivium-ai` and
`olivium-det` setups exist for protocol 2 only; protocol 3 refuses them.

## Amendments

- **2026-11-12, review repair round, before any paid rehearsal request.** Added the P2 difficulty screen and the
  screened manifest, the `olivium-det` ablation in invocation 2, reuse of the inspected bundles, 1 session at a
  time, the learning cost next to every ratio, and the section on what this run can show (review issues B2, M5,
  M6, m4 and m5). The sha256 of this file and of `analyze_v4.py` are recorded again next to the run plan.
