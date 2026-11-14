# Value benchmark v2: after the refusal fix (2026-11-10)

**What this is.** The scored run of 2026-11-10 ([report](../value-v2-2026-11-09/report.md)) found that the `olivium` harness cost more than no instruction file on all 8 tasks. Its own permission settings refused 35 ordinary calls in 14 of 24 runs. The generator was fixed (solo mode allows the shell as a whole; scratch files in `/tmp` are allowed), and the `olivium` arm was run again: 24 paid runs, the same 8 tasks, 3 repeats, same model (`claude-sonnet-5-5`), same Claude Code 2.1.311, prompt, limits and Docker images. The `none` and `generic` runs are the scored run's, not re-run. Design and stop rules were written into [`PROTOCOL-v2.md`](../../../bench/value/PROTOCOL-v2.md) (change log, "after the scored run") before any paid call.

**Read this with care.** These are the same tasks the fix was found on, so this is not a held-out result. Arms come from two runs a few hours apart.

## Before and after the fix

| Per arm, 24 runs | No instruction file | Claude Code `/init` | Olivium, before fix | **Olivium, after fix** |
| --- | ---: | ---: | ---: | ---: |
| Solved | 15 | 15 | 15 | **15** |
| Total cost | $1.2403 | $1.3750 | $1.7183 | **$1.4019** |
| Cost per solved task | $0.0827 | $0.0917 | $0.1146 | **$0.0935** |
| Median cost per run | $0.0490 | $0.0559 | $0.0662 | **$0.0528** |
| Median tokens per run | 110,307 | 135,362 | 143,260 | **134,610** |
| Mean tokens per run | 114,857 | 125,050 | 175,592 | **136,294** |
| Mean turns | 5.75 | 5.79 | 7.88 | **6.33** |
| Refused calls (runs) | 0 | 0 | 35 (14) | **4 (4)** |

Paired per-task cost difference (olivium minus baseline, median, 95% bootstrap interval across 8 tasks):

| | Before fix | After fix |
| --- | --- | --- |
| vs no instruction file | +$0.0105 (+$0.0029 to +$0.0404), olivium costlier | +$0.0016 (−$0.0031 to +$0.0158), no clear difference |
| vs `/init` | +$0.0040 (+$0.0012 to +$0.0386), olivium costlier | −$0.0032 (−$0.0098 to +$0.0094), no clear difference |

- **Accuracy:** unchanged, 15 of 24 in every arm; each task was solved by all its runs or by none.
- **Context** (files read outside the fix, turns before the first edit to a fixed file): no clear difference against either baseline.
- **Held-out tasks** (3, `pallets/werkzeug`): olivium still slightly costlier, intervals include zero (vs none +$0.0078, −$0.0011 to +$0.0158; vs `/init` +$0.0061, −$0.0033 to +$0.0094).
- **The 4 refusals left** were all the guard, on purpose: a listing of `~/.local/share/uv/python` (the home directory stays outside) and three attempts to fetch `mypy` from the package registry (`uvx mypy`, `uv run --with mypy`).
- **Spend:** this re-run $1.4019 (152 meter rows, all live, equal to the trials' total). Programme total $10.49 of $60.

## Proof of the fix at $0

[`replay.json`](replay.json): every main-session tool call of the 14 olivium runs that had a refusal (150 calls) was replayed in its original order through real Claude Code 2.1.311 in each task's image, with the mock model.

| Export | Refused calls |
| --- | ---: |
| In the paid run | 35 |
| Replay, old export | 35 |
| Replay, old export plus a plain `Bash` allow | 9 (the guard's) |
| Replay, fixed export | 2 (both on purpose) |

With the guard file deleted from the fixed export, Claude Code's own deny rules still refused `rm -rf`, `rm -r`, `curl`, `wget`, `git push`, `git commit`, `git reset --hard`, `sudo` and `cat .env`; with the guard present it refused them first.

## Files

- `results.json`, the charts and the analysis below: `bench/value/analyze.py` run on a merged directory (the scored run's `none` and `generic` trials, meter rows and setups, plus this re-run's `olivium` trials, meter rows and setups).
- `runs/`: this re-run's trial summaries, meter log, setups and schedule. No transcripts, patches, issue text or third-party source.
- `replay.json`: the $0 proofs, counts and refusal reasons only.
- `provenance.json`: commands, digests, spend and checksums.

---

## Analysis: Value benchmark results

> Measurement: 8 tasks, one model, one agent. This can show a direction or a problem. It cannot prove a general effect.

Each run is one attempt by Claude Code to fix one real bug. `none` has no instruction file, `generic` has a CLAUDE.md from Claude Code's own `/init`, and `olivium` has the files this project generates. Differences are olivium minus the other arm, so a negative cost difference means olivium was cheaper.

## The three questions

> Measurement: 8 tasks, one model, one agent. This can show a direction or a problem. It cannot prove a general effect.

**Did the agent use fewer tokens and cost less?**

- `none` cost per solved task: $0.0827 (15 of 24 runs solved, total $1.24).
- `generic` cost per solved task: $0.0917 (15 of 24 runs solved, total $1.38).
- `olivium` cost per solved task: $0.0935 (15 of 24 runs solved, total $1.40).
- Against none, no clear difference: median difference +$0.0016 (95% interval -$0.0031 to +$0.0158 across 8 tasks); the interval includes zero.
- Against generic, no clear difference: median difference -$0.0032 (95% interval -$0.0098 to +$0.0094 across 8 tasks); the interval includes zero.

**Did the agent have better context?**

- Against none, no clear difference: median difference 0 (95% interval -0.33 to +0.33 across 8 tasks); the interval includes zero.
- Against generic, no clear difference: median difference 0 (95% interval 0 to +0.33 across 8 tasks); the interval includes zero.

**Was the agent more accurate?**

- Against none, no clear difference: median difference 0.00 (95% interval 0.00 to 0.00 across 8 tasks); the interval includes zero.
- Against generic, no clear difference: median difference 0.00 (95% interval 0.00 to 0.00 across 8 tasks); the interval includes zero.

## How the runs ended

> Measurement: 8 tasks, one model, one agent. This can show a direction or a problem. It cannot prove a general effect.

0 runs were cut off by a spending limit (`budget_exhausted`). Those runs count as unsolved and their cost counts.

| Arm | Completed | Timeout | Turn limit | Budget exhausted | Infrastructure errors (not scored) | Solved | Cost per solved task |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| none | 24 | 0 | 0 | 0 | 0 | 15 of 24 | $0.0827 |
| generic | 24 | 0 | 0 | 0 | 0 | 15 of 24 | $0.0917 |
| olivium | 24 | 0 | 0 | 0 | 0 | 15 of 24 | $0.0935 |

![Cost per solved task by arm](chart_cost_per_solved.svg)

![Average cost per run by task and arm](chart_cost_by_task.svg)

![Did the agent use fewer tokens and cost less?](chart_fewer_tokens.svg)

![Did the agent have better context?](chart_better_context.svg)

![Was the agent more accurate?](chart_more_accurate.svg)

## Read this first: overlap with the tuning repositories

The analyzer and rule filters were tuned while looking at pallets/click, pallets/flask, python-attrs/attrs and expressjs/express, at the same base commits the pilot used, and the 5 pilot tasks come from those repositories. Only the held-out table is free of that overlap. The held-out tasks come from pallets/werkzeug, which shares an owner with a tuned repository and likely its layout and tooling conventions, so the held-out table is free of the base-commit overlap but not of that family resemblance.

Held-out tasks in this run: 3 (pallets-werkzeug-3298, pallets-werkzeug-3273, pallets-werkzeug-3266). See the separate held-out sections below.

## Permissions and hooks

> Measurement: 8 tasks, one model, one agent. This can show a direction or a problem. It cannot prove a general effect.

The `olivium` arm runs as exported, with default permissions and its own allow list, so a denied tool counts against it. `none` and `generic` use the benchmark's bypass settings, so these columns are zero for them.

| Arm | Runs | Permission denials | Runs with a denial | Stop hook blocks | Runs with a Stop block |
| --- | ---: | ---: | ---: | ---: | ---: |
| none | 24 | 0 | 0 | 0 | 0 |
| generic | 24 | 0 | 0 | 0 | 0 |
| olivium | 24 | 4 | 4 | 0 | 0 |

**Web tools.** Under this protocol every arm, and `/init`, runs with Claude Code's `WebSearch` and `WebFetch` removed (`--disallowedTools`), and the meter refuses any request offering a web server tool. From each run's own init event: runs offered a web tool, none 0, generic 0, olivium 0 (of runs with the tool list recorded: none 24, generic 24, olivium 24). Web tool calls attempted: none 0, generic 0, olivium 0. Attempts stopped by the web guard and repeated as infrastructure errors: none 0, generic 0, olivium 0. `/init` sessions offered a web tool: 0 of 8 recorded.

## What the generator produced, by task

Setup cost of the `olivium` arm is $0: no model call is made.

| Task | Held out | Rules | Hooks | Allowed commands | Denied commands | Harness bytes | Diagnostics |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| pallets-click-3858 | no | 2 | 3 | 41 | 61 | 69532 | allowed_programs_unrestricted, approval_still_required, guard_missing_fails_open, registry_access, runtime_unqualified, secret_deny_is_partial, unsupported_control, workspace_trust_required |
| pallets-flask-6096 | no | 1 | 3 | 41 | 61 | 68598 | allowed_programs_unrestricted, approval_still_required, guard_missing_fails_open, registry_access, runtime_unqualified, secret_deny_is_partial, unsupported_control, workspace_trust_required |
| python-attrs-attrs-1593 | no | 8 | 3 | 41 | 61 | 74748 | ai_policy_detected, allowed_programs_unrestricted, approval_still_required, guard_missing_fails_open, registry_access, runtime_unqualified, secret_deny_is_partial, unsupported_control, workspace_trust_required |
| expressjs-express-7366 | no | 0 | 2 | 40 | 61 | 66315 | allowed_programs_unrestricted, approval_still_required, guard_missing_fails_open, registry_access, runtime_unqualified, secret_deny_is_partial, unsupported_control, workspace_trust_required |
| pallets-click-3769 | no | 2 | 3 | 41 | 61 | 69466 | allowed_programs_unrestricted, approval_still_required, guard_missing_fails_open, registry_access, runtime_unqualified, secret_deny_is_partial, unsupported_control, workspace_trust_required |
| pallets-werkzeug-3298 | yes | 2 | 3 | 41 | 61 | 69620 | allowed_programs_unrestricted, approval_still_required, guard_missing_fails_open, registry_access, runtime_unqualified, secret_deny_is_partial, unsupported_control, workspace_trust_required |
| pallets-werkzeug-3273 | yes | 1 | 3 | 41 | 61 | 68836 | allowed_programs_unrestricted, approval_still_required, guard_missing_fails_open, registry_access, runtime_unqualified, secret_deny_is_partial, unsupported_control, workspace_trust_required |
| pallets-werkzeug-3266 | yes | 1 | 3 | 41 | 61 | 68836 | allowed_programs_unrestricted, approval_still_required, guard_missing_fails_open, registry_access, runtime_unqualified, secret_deny_is_partial, unsupported_control, workspace_trust_required |

## Differences, by question

Median across tasks of the per-task difference, then the 95% bootstrap interval in brackets.

### Did the agent use fewer tokens and cost less?

> Measurement: 8 tasks, one model, one agent. This can show a direction or a problem. It cannot prove a general effect.

| Metric | Better when | olivium - none | Tasks | olivium - generic | Tasks |
| --- | --- | ---: | ---: | ---: | ---: |
| Cost per run | lower | +$0.0016 [-$0.0031, +$0.0158] | 8 | -$0.0032 [-$0.0098, +$0.0094] | 8 |
| Input tokens | lower | +2 [-1, +3] | 8 | +1 [-3, +2] | 8 |
| Output tokens | lower | +213 [-130, +568] | 8 | +76 [-202, +466] | 8 |
| Cache-write tokens | lower | -281 [-1,456, +4,061] | 8 | -2,302 [-2,725, +3,056] | 8 |
| Cache-read tokens | lower | +26,726 [-10,506, +37,158] | 8 | +15,046 [-21,157, +22,396] | 8 |

### Did the agent have better context?

> Measurement: 8 tasks, one model, one agent. This can show a direction or a problem. It cannot prove a general effect.

| Metric | Better when | olivium - none | Tasks | olivium - generic | Tasks |
| --- | --- | ---: | ---: | ---: | ---: |
| Files read outside the real fix | lower | 0 [-0.33, +0.33] | 8 | 0 [0, +0.33] | 8 |
| Turns before the first edit to a fixed file | lower | 0 [-0.50, +0.33] | 7 | 0 [-0.33, 0] | 8 |
| Tool calls before that edit | lower | 0 [-0.50, +0.17] | 7 | -0.08 [-0.33, 0] | 8 |

### Was the agent more accurate?

> Measurement: 8 tasks, one model, one agent. This can show a direction or a problem. It cannot prove a general effect.

| Metric | Better when | olivium - none | Tasks | olivium - generic | Tasks |
| --- | --- | ---: | ---: | ---: | ---: |
| Solved | higher | 0.00 [0.00, 0.00] | 8 | 0.00 [0.00, 0.00] | 8 |
| Regressions per run | lower | 0 [0, 0] | 8 | 0 [0, 0] | 8 |
| Linter passes | higher | 0.00 [0.00, 0.00] | 8 | 0.00 [0.00, 0.00] | 8 |

## Per-task values

Average of the repeats for each task and arm, then the difference. `n/a` means no run of that task and arm produced the value, for example no edit reached a fixed file.

### Cost per run

> Measurement: 8 tasks, one model, one agent. This can show a direction or a problem. It cannot prove a general effect.

| Task | none | generic | olivium | olivium - none | olivium - generic |
| --- | ---: | ---: | ---: | ---: | ---: |
| pallets-click-3858 | $0.0668 | $0.0717 | $0.0677 | +$0.0009 | -$0.0039 |
| pallets-flask-6096 | $0.0437 | $0.0490 | $0.0459 | +$0.0022 | -$0.0030 |
| python-attrs-attrs-1593 | $0.0397 | $0.0416 | $0.0743 | +$0.0347 | +$0.0328 |
| expressjs-express-7366 | $0.0354 | $0.0515 | $0.0323 | -$0.0031 | -$0.0192 |
| pallets-click-3769 | $0.0306 | $0.0372 | $0.0274 | -$0.0033 | -$0.0098 |
| pallets-werkzeug-3298 | $0.0570 | $0.0592 | $0.0559 | -$0.0011 | -$0.0033 |
| pallets-werkzeug-3273 | $0.0707 | $0.0771 | $0.0865 | +$0.0158 | +$0.0094 |
| pallets-werkzeug-3266 | $0.0695 | $0.0712 | $0.0772 | +$0.0078 | +$0.0061 |

### Input tokens

> Measurement: 8 tasks, one model, one agent. This can show a direction or a problem. It cannot prove a general effect.

| Task | none | generic | olivium | olivium - none | olivium - generic |
| --- | ---: | ---: | ---: | ---: | ---: |
| pallets-click-3858 | 12 | 13 | 15 | +3 | +2 |
| pallets-flask-6096 | 13 | 13 | 15 | +2 | +2 |
| python-attrs-attrs-1593 | 12 | 10 | 16 | +4 | +6 |
| expressjs-express-7366 | 13 | 13 | 11 | -2 | -3 |
| pallets-click-3769 | 8 | 11 | 8 | 0 | -3 |
| pallets-werkzeug-3298 | 12 | 9 | 11 | -1 | +1 |
| pallets-werkzeug-3273 | 11 | 12 | 13 | +2 | +1 |
| pallets-werkzeug-3266 | 12 | 13 | 14 | +2 | +1 |

### Output tokens

> Measurement: 8 tasks, one model, one agent. This can show a direction or a problem. It cannot prove a general effect.

| Task | none | generic | olivium | olivium - none | olivium - generic |
| --- | ---: | ---: | ---: | ---: | ---: |
| pallets-click-3858 | 2,972 | 2,900 | 2,942 | -30 | +42 |
| pallets-flask-6096 | 1,656 | 1,845 | 1,954 | +298 | +109 |
| python-attrs-attrs-1593 | 1,303 | 1,266 | 2,277 | +974 | +1,011 |
| expressjs-express-7366 | 1,076 | 1,202 | 946 | -130 | -256 |
| pallets-click-3769 | 816 | 1,070 | 943 | +128 | -126 |
| pallets-werkzeug-3298 | 2,448 | 1,989 | 2,203 | -244 | +214 |
| pallets-werkzeug-3273 | 3,208 | 3,729 | 3,527 | +318 | -202 |
| pallets-werkzeug-3266 | 2,838 | 2,941 | 3,407 | +568 | +466 |

### Cache-write tokens

> Measurement: 8 tasks, one model, one agent. This can show a direction or a problem. It cannot prove a general effect.

| Task | none | generic | olivium | olivium - none | olivium - generic |
| --- | ---: | ---: | ---: | ---: | ---: |
| pallets-click-3858 | 10,019 | 11,654 | 9,022 | -997 | -2,632 |
| pallets-flask-6096 | 6,555 | 7,439 | 5,100 | -1,456 | -2,339 |
| python-attrs-attrs-1593 | 6,553 | 7,927 | 14,122 | +7,569 | +6,195 |
| expressjs-express-7366 | 5,393 | 11,177 | 5,354 | -39 | -5,823 |
| pallets-click-3769 | 6,369 | 6,598 | 4,334 | -2,035 | -2,264 |
| pallets-werkzeug-3298 | 8,447 | 12,125 | 9,400 | +954 | -2,725 |
| pallets-werkzeug-3273 | 11,492 | 11,091 | 15,553 | +4,061 | +4,462 |
| pallets-werkzeug-3266 | 11,768 | 11,330 | 11,245 | -523 | -84 |

### Cache-read tokens

> Measurement: 8 tasks, one model, one agent. This can show a direction or a problem. It cannot prove a general effect.

| Task | none | generic | olivium | olivium - none | olivium - generic |
| --- | ---: | ---: | ---: | ---: | ---: |
| pallets-click-3858 | 120,196 | 134,957 | 157,353 | +37,158 | +22,396 |
| pallets-flask-6096 | 107,182 | 118,905 | 136,121 | +28,939 | +17,216 |
| python-attrs-attrs-1593 | 102,643 | 90,580 | 162,426 | +59,783 | +71,846 |
| expressjs-express-7366 | 111,360 | 115,537 | 94,380 | -16,979 | -21,157 |
| pallets-click-3769 | 65,345 | 99,614 | 70,665 | +5,320 | -28,949 |
| pallets-werkzeug-3298 | 114,050 | 89,663 | 103,544 | -10,506 | +13,881 |
| pallets-werkzeug-3273 | 98,651 | 120,710 | 123,164 | +24,514 | +2,454 |
| pallets-werkzeug-3266 | 116,421 | 134,055 | 150,266 | +33,845 | +16,211 |

### Files read outside the real fix

> Measurement: 8 tasks, one model, one agent. This can show a direction or a problem. It cannot prove a general effect.

| Task | none | generic | olivium | olivium - none | olivium - generic |
| --- | ---: | ---: | ---: | ---: | ---: |
| pallets-click-3858 | 0 | 0 | 0 | 0 | 0 |
| pallets-flask-6096 | 1.67 | 1.67 | 2 | +0.33 | +0.33 |
| python-attrs-attrs-1593 | 0.67 | 0.33 | 3 | +2.33 | +2.67 |
| expressjs-express-7366 | 1.33 | 1 | 1 | -0.33 | 0 |
| pallets-click-3769 | 0 | 0 | 0 | 0 | 0 |
| pallets-werkzeug-3298 | 1 | 1 | 1 | 0 | 0 |
| pallets-werkzeug-3273 | 1.33 | 0.67 | 1 | -0.33 | +0.33 |
| pallets-werkzeug-3266 | 5 | 5 | 5 | 0 | 0 |

### Turns before the first edit to a fixed file

> Measurement: 8 tasks, one model, one agent. This can show a direction or a problem. It cannot prove a general effect.

| Task | none | generic | olivium | olivium - none | olivium - generic |
| --- | ---: | ---: | ---: | ---: | ---: |
| pallets-click-3858 | 2.50 | 3 | 2.67 | +0.17 | -0.33 |
| pallets-flask-6096 | 3 | 4 | 4 | +1 | 0 |
| python-attrs-attrs-1593 | n/a | 2.50 | 2.50 | n/a | 0 |
| expressjs-express-7366 | 1 | 1 | 1 | 0 | 0 |
| pallets-click-3769 | 2 | 2 | 2 | 0 | 0 |
| pallets-werkzeug-3298 | 3 | 2 | 2 | -1 | 0 |
| pallets-werkzeug-3273 | 2.67 | 3.33 | 3 | +0.33 | -0.33 |
| pallets-werkzeug-3266 | 3 | 2.67 | 2.50 | -0.50 | -0.17 |

### Tool calls before that edit

> Measurement: 8 tasks, one model, one agent. This can show a direction or a problem. It cannot prove a general effect.

| Task | none | generic | olivium | olivium - none | olivium - generic |
| --- | ---: | ---: | ---: | ---: | ---: |
| pallets-click-3858 | 2.50 | 3 | 2.67 | +0.17 | -0.33 |
| pallets-flask-6096 | 3 | 4.33 | 4 | +1 | -0.33 |
| python-attrs-attrs-1593 | n/a | 2.50 | 4 | n/a | +1.50 |
| expressjs-express-7366 | 1 | 1 | 1 | 0 | 0 |
| pallets-click-3769 | 2 | 2 | 2 | 0 | 0 |
| pallets-werkzeug-3298 | 3 | 2 | 2 | -1 | 0 |
| pallets-werkzeug-3273 | 3 | 3.33 | 3 | 0 | -0.33 |
| pallets-werkzeug-3266 | 3 | 2.67 | 2.50 | -0.50 | -0.17 |

### Solved

> Measurement: 8 tasks, one model, one agent. This can show a direction or a problem. It cannot prove a general effect.

| Task | none | generic | olivium | olivium - none | olivium - generic |
| --- | ---: | ---: | ---: | ---: | ---: |
| pallets-click-3858 | 1.00 | 1.00 | 1.00 | 0.00 | 0.00 |
| pallets-flask-6096 | 1.00 | 1.00 | 1.00 | 0.00 | 0.00 |
| python-attrs-attrs-1593 | 1.00 | 1.00 | 1.00 | 0.00 | 0.00 |
| expressjs-express-7366 | 1.00 | 1.00 | 1.00 | 0.00 | 0.00 |
| pallets-click-3769 | 0.00 | 0.00 | 0.00 | 0.00 | 0.00 |
| pallets-werkzeug-3298 | 1.00 | 1.00 | 1.00 | 0.00 | 0.00 |
| pallets-werkzeug-3273 | 0.00 | 0.00 | 0.00 | 0.00 | 0.00 |
| pallets-werkzeug-3266 | 0.00 | 0.00 | 0.00 | 0.00 | 0.00 |

### Regressions per run

> Measurement: 8 tasks, one model, one agent. This can show a direction or a problem. It cannot prove a general effect.

| Task | none | generic | olivium | olivium - none | olivium - generic |
| --- | ---: | ---: | ---: | ---: | ---: |
| pallets-click-3858 | 0 | 0 | 0 | 0 | 0 |
| pallets-flask-6096 | 0 | 0 | 0 | 0 | 0 |
| python-attrs-attrs-1593 | 0 | 0 | 0 | 0 | 0 |
| expressjs-express-7366 | 0 | 0 | 0 | 0 | 0 |
| pallets-click-3769 | 0 | 0 | 0 | 0 | 0 |
| pallets-werkzeug-3298 | 0 | 0 | 0 | 0 | 0 |
| pallets-werkzeug-3273 | 0 | 0 | 0 | 0 | 0 |
| pallets-werkzeug-3266 | 2 | 2 | 2 | 0 | 0 |

### Linter passes

> Measurement: 8 tasks, one model, one agent. This can show a direction or a problem. It cannot prove a general effect.

| Task | none | generic | olivium | olivium - none | olivium - generic |
| --- | ---: | ---: | ---: | ---: | ---: |
| pallets-click-3858 | 0.67 | 1.00 | 1.00 | +0.33 | 0.00 |
| pallets-flask-6096 | 1.00 | 1.00 | 1.00 | 0.00 | 0.00 |
| python-attrs-attrs-1593 | 1.00 | 1.00 | 1.00 | 0.00 | 0.00 |
| expressjs-express-7366 | 1.00 | 1.00 | 1.00 | 0.00 | 0.00 |
| pallets-click-3769 | 1.00 | 1.00 | 1.00 | 0.00 | 0.00 |
| pallets-werkzeug-3298 | 1.00 | 1.00 | 1.00 | 0.00 | 0.00 |
| pallets-werkzeug-3273 | 1.00 | 1.00 | 1.00 | 0.00 | 0.00 |
| pallets-werkzeug-3266 | 1.00 | 1.00 | 1.00 | 0.00 | 0.00 |

## Cost per solved task, by task

> Measurement: 8 tasks, one model, one agent. This can show a direction or a problem. It cannot prove a general effect.

Total cost of the arm's runs on that task divided by how many of them solved it. `n/a` means none did.

| Task | none | generic | olivium |
| --- | ---: | ---: | ---: |
| pallets-click-3858 | $0.0668 | $0.0717 | $0.0677 |
| pallets-flask-6096 | $0.0437 | $0.0490 | $0.0459 |
| python-attrs-attrs-1593 | $0.0397 | $0.0416 | $0.0743 |
| expressjs-express-7366 | $0.0354 | $0.0515 | $0.0323 |
| pallets-click-3769 | n/a | n/a | n/a |
| pallets-werkzeug-3298 | $0.0570 | $0.0592 | $0.0559 |
| pallets-werkzeug-3273 | n/a | n/a | n/a |
| pallets-werkzeug-3266 | n/a | n/a | n/a |

## Setup cost (reported separately)

> Measurement: 8 tasks, one model, one agent. This can show a direction or a problem. It cannot prove a general effect.

Includes what failed attempts spent. The upper bound also counts requests whose usage is unknown at their full reservation.

| Arm | Setup cost | Upper bound | Tasks with failed setup |
| --- | ---: | ---: | --- |
| none | $0.0000 | $0.0000 | none |
| generic | $0.4557 | $0.4557 | none |
| olivium | $0.0000 | $0.0000 | none |

## Held-out tasks only

Same analysis restricted to the held-out tasks, which come from repositories the analyzer was not tuned on. The analyzer and rule filters were tuned while looking at pallets/click, pallets/flask, python-attrs/attrs and expressjs/express, at the same base commits the pilot used, and the 5 pilot tasks come from those repositories. Only the held-out table is free of that overlap. The held-out tasks come from pallets/werkzeug, which shares an owner with a tuned repository and likely its layout and tooling conventions, so the held-out table is free of the base-commit overlap but not of that family resemblance.

> Held-out measurement: 3 tasks, one model, one agent. This can show a direction or a problem. It cannot prove a general effect.

| Arm | Solved | Runs | Cost per solved task | Total cost |
| --- | ---: | ---: | ---: | ---: |
| none | 3 | 9 | $0.1972 | $0.5916 |
| generic | 3 | 9 | $0.2075 | $0.6224 |
| olivium | 3 | 9 | $0.2196 | $0.6589 |

**Did the agent use fewer tokens and cost less? (held-out only)**

- Against none, no clear difference: median difference +$0.0078 (95% interval -$0.0011 to +$0.0158 across 3 tasks); the interval includes zero.
- Against generic, no clear difference: median difference +$0.0061 (95% interval -$0.0033 to +$0.0094 across 3 tasks); the interval includes zero.

**Did the agent have better context? (held-out only)**

- Against none, no clear difference: median difference 0 (95% interval -0.33 to 0 across 3 tasks); the interval includes zero.
- Against generic, no clear difference: median difference 0 (95% interval 0 to +0.33 across 3 tasks); the interval includes zero.

**Was the agent more accurate? (held-out only)**

- Against none, no clear difference: median difference 0.00 (95% interval 0.00 to 0.00 across 3 tasks); the interval includes zero.
- Against generic, no clear difference: median difference 0.00 (95% interval 0.00 to 0.00 across 3 tasks); the interval includes zero.

| Metric | Better when | olivium - none | Tasks | olivium - generic | Tasks |
| --- | --- | ---: | ---: | ---: | ---: |
| Cost per run | lower | +$0.0078 [-$0.0011, +$0.0158] | 3 | +$0.0061 [-$0.0033, +$0.0094] | 3 |
| Input tokens | lower | +2 [-1, +2] | 3 | +1 [+1, +1] | 3 |
| Output tokens | lower | +318 [-244, +568] | 3 | +214 [-202, +466] | 3 |
| Cache-write tokens | lower | +954 [-523, +4,061] | 3 | -84 [-2,725, +4,462] | 3 |
| Cache-read tokens | lower | +24,514 [-10,506, +33,845] | 3 | +13,881 [+2,454, +16,211] | 3 |
| Files read outside the real fix | lower | 0 [-0.33, 0] | 3 | 0 [0, +0.33] | 3 |
| Turns before the first edit to a fixed file | lower | -0.50 [-1, +0.33] | 3 | -0.17 [-0.33, 0] | 3 |
| Tool calls before that edit | lower | -0.50 [-1, 0] | 3 | -0.17 [-0.33, 0] | 3 |
| Solved | higher | 0.00 [0.00, 0.00] | 3 | 0.00 [0.00, 0.00] | 3 |
| Regressions per run | lower | 0 [0, 0] | 3 | 0 [0, 0] | 3 |
| Linter passes | higher | 0.00 [0.00, 0.00] | 3 | 0.00 [0.00, 0.00] | 3 |

| Task | Cost: none | generic | olivium | Solved: none | generic | olivium |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| pallets-werkzeug-3298 | $0.0570 | $0.0592 | $0.0559 | 1.00 | 1.00 | 1.00 |
| pallets-werkzeug-3273 | $0.0707 | $0.0771 | $0.0865 | 0.00 | 0.00 | 0.00 |
| pallets-werkzeug-3266 | $0.0695 | $0.0712 | $0.0772 | 0.00 | 0.00 | 0.00 |

## Method

For each task, the repeats of each arm are averaged, leaving out runs recorded as `infra_error`. The difference is olivium minus the other arm for that task. The headline is the median of those differences across tasks. The interval is a percentile bootstrap: tasks are resampled with replacement 10000 times with seed 20261108, the median is taken each time, and the 2.5th and 97.5th percentiles are reported. Cost per solved task is the total cost of the arm's runs divided by the number of runs that solved the task; it has no interval because the protocol defines none.

Measurement: 8 tasks, one model, one agent. This can show a direction or a problem. It cannot prove a general effect.
