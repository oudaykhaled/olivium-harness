# Value benchmark results

> Measurement: 8 tasks, one model, one agent. This can show a direction or a problem. It cannot prove a general effect.

Each run is one attempt by Claude Code to fix one real bug. `none` has no instruction file, `generic` has a CLAUDE.md from Claude Code's own `/init`, and `olivium` has the files this project generates. Differences are olivium minus the other arm, so a negative cost difference means olivium was cheaper.

## The three questions

> Measurement: 8 tasks, one model, one agent. This can show a direction or a problem. It cannot prove a general effect.

**Did the agent use fewer tokens and cost less?**

- `none` cost per solved task: $0.0827 (15 of 24 runs solved, total $1.24).
- `generic` cost per solved task: $0.0917 (15 of 24 runs solved, total $1.38).
- `olivium` cost per solved task: $0.1146 (15 of 24 runs solved, total $1.72).
- Against none, on these 8 tasks, the olivium arm cost more per run (a direction, not proof): median difference +$0.0105 (95% interval +$0.0029 to +$0.0404 across 8 tasks).
- Against generic, on these 8 tasks, the olivium arm cost more per run (a direction, not proof): median difference +$0.0040 (95% interval +$0.0012 to +$0.0386 across 8 tasks).

**Did the agent have better context?**

- Against none, no clear difference: median difference 0 (95% interval 0 to +0.67 across 8 tasks); the interval includes zero.
- Against generic, no clear difference: median difference 0 (95% interval 0 to +1.17 across 8 tasks); the interval includes zero.

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
| olivium | 24 | 0 | 0 | 0 | 0 | 15 of 24 | $0.1146 |

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
| olivium | 24 | 35 | 14 | 0 | 0 |

**Web tools.** Under this protocol every arm, and `/init`, runs with Claude Code's `WebSearch` and `WebFetch` removed (`--disallowedTools`), and the meter refuses any request offering a web server tool. From each run's own init event: runs offered a web tool, none 0, generic 0, olivium 0 (of runs with the tool list recorded: none 24, generic 24, olivium 24). Web tool calls attempted: none 0, generic 0, olivium 0. Attempts stopped by the web guard and repeated as infrastructure errors: none 0, generic 0, olivium 0. `/init` sessions offered a web tool: 0 of 8 recorded.

## What the generator produced, by task

Setup cost of the `olivium` arm is $0: no model call is made.

| Task | Held out | Rules | Hooks | Allowed commands | Denied commands | Harness bytes | Diagnostics |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| pallets-click-3858 | no | 2 | 3 | 41 | 61 | 68376 | allowed_programs_unrestricted, approval_still_required, guard_missing_fails_open, registry_access, runtime_unqualified, secret_deny_is_partial, unsupported_control, workspace_trust_required |
| pallets-flask-6096 | no | 1 | 3 | 41 | 61 | 67442 | allowed_programs_unrestricted, approval_still_required, guard_missing_fails_open, registry_access, runtime_unqualified, secret_deny_is_partial, unsupported_control, workspace_trust_required |
| python-attrs-attrs-1593 | no | 8 | 3 | 41 | 61 | 73592 | ai_policy_detected, allowed_programs_unrestricted, approval_still_required, guard_missing_fails_open, registry_access, runtime_unqualified, secret_deny_is_partial, unsupported_control, workspace_trust_required |
| expressjs-express-7366 | no | 0 | 2 | 40 | 61 | 65159 | allowed_programs_unrestricted, approval_still_required, guard_missing_fails_open, registry_access, runtime_unqualified, secret_deny_is_partial, unsupported_control, workspace_trust_required |
| pallets-click-3769 | no | 2 | 3 | 41 | 61 | 68310 | allowed_programs_unrestricted, approval_still_required, guard_missing_fails_open, registry_access, runtime_unqualified, secret_deny_is_partial, unsupported_control, workspace_trust_required |
| pallets-werkzeug-3298 | yes | 2 | 3 | 41 | 61 | 68464 | allowed_programs_unrestricted, approval_still_required, guard_missing_fails_open, registry_access, runtime_unqualified, secret_deny_is_partial, unsupported_control, workspace_trust_required |
| pallets-werkzeug-3273 | yes | 1 | 3 | 41 | 61 | 67680 | allowed_programs_unrestricted, approval_still_required, guard_missing_fails_open, registry_access, runtime_unqualified, secret_deny_is_partial, unsupported_control, workspace_trust_required |
| pallets-werkzeug-3266 | yes | 1 | 3 | 41 | 61 | 67680 | allowed_programs_unrestricted, approval_still_required, guard_missing_fails_open, registry_access, runtime_unqualified, secret_deny_is_partial, unsupported_control, workspace_trust_required |

## Differences, by question

Median across tasks of the per-task difference, then the 95% bootstrap interval in brackets.

### Did the agent use fewer tokens and cost less?

> Measurement: 8 tasks, one model, one agent. This can show a direction or a problem. It cannot prove a general effect.

| Metric | Better when | olivium - none | Tasks | olivium - generic | Tasks |
| --- | --- | ---: | ---: | ---: | ---: |
| Cost per run | lower | +$0.0105 [+$0.0029, +$0.0404] | 8 | +$0.0040 [+$0.0012, +$0.0386] | 8 |
| Input tokens | lower | +2 [-1, +11] | 8 | +1 [-1, +13] | 8 |
| Output tokens | lower | +533 [+112, +1,576] | 8 | +229 [-15, +1,613] | 8 |
| Cache-write tokens | lower | +2,221 [+29, +4,029] | 8 | +955 [-7, +2,655] | 8 |
| Cache-read tokens | lower | +24,757 [-4,843, +145,877] | 8 | +7,509 [-9,020, +157,941] | 8 |

### Did the agent have better context?

> Measurement: 8 tasks, one model, one agent. This can show a direction or a problem. It cannot prove a general effect.

| Metric | Better when | olivium - none | Tasks | olivium - generic | Tasks |
| --- | --- | ---: | ---: | ---: | ---: |
| Files read outside the real fix | lower | 0 [0, +0.67] | 8 | 0 [0, +1.17] | 8 |
| Turns before the first edit to a fixed file | lower | +0.67 [0, +1.33] | 7 | +0.50 [0, +1.33] | 8 |
| Tool calls before that edit | lower | +0.67 [0, +1.67] | 7 | +0.50 [0, +2.17] | 8 |

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
| pallets-click-3858 | $0.0668 | $0.0717 | $0.1359 | +$0.0690 | +$0.0642 |
| pallets-flask-6096 | $0.0437 | $0.0490 | $0.0636 | +$0.0199 | +$0.0146 |
| python-attrs-attrs-1593 | $0.0397 | $0.0416 | $0.0801 | +$0.0404 | +$0.0386 |
| expressjs-express-7366 | $0.0354 | $0.0515 | $0.0361 | +$0.0007 | -$0.0154 |
| pallets-click-3769 | $0.0306 | $0.0372 | $0.0407 | +$0.0100 | +$0.0035 |
| pallets-werkzeug-3298 | $0.0570 | $0.0592 | $0.0623 | +$0.0053 | +$0.0032 |
| pallets-werkzeug-3273 | $0.0707 | $0.0771 | $0.0817 | +$0.0110 | +$0.0045 |
| pallets-werkzeug-3266 | $0.0695 | $0.0712 | $0.0724 | +$0.0029 | +$0.0012 |

### Input tokens

> Measurement: 8 tasks, one model, one agent. This can show a direction or a problem. It cannot prove a general effect.

| Task | none | generic | olivium | olivium - none | olivium - generic |
| --- | ---: | ---: | ---: | ---: | ---: |
| pallets-click-3858 | 12 | 13 | 28 | +16 | +15 |
| pallets-flask-6096 | 13 | 13 | 17 | +5 | +5 |
| python-attrs-attrs-1593 | 12 | 10 | 23 | +11 | +13 |
| expressjs-express-7366 | 13 | 13 | 12 | -1 | -1 |
| pallets-click-3769 | 8 | 11 | 11 | +3 | +1 |
| pallets-werkzeug-3298 | 12 | 9 | 11 | -1 | +1 |
| pallets-werkzeug-3273 | 11 | 12 | 11 | +1 | -1 |
| pallets-werkzeug-3266 | 12 | 13 | 13 | +1 | 0 |

### Output tokens

> Measurement: 8 tasks, one model, one agent. This can show a direction or a problem. It cannot prove a general effect.

| Task | none | generic | olivium | olivium - none | olivium - generic |
| --- | ---: | ---: | ---: | ---: | ---: |
| pallets-click-3858 | 2,972 | 2,900 | 6,073 | +3,101 | +3,174 |
| pallets-flask-6096 | 1,656 | 1,845 | 2,491 | +835 | +646 |
| python-attrs-attrs-1593 | 1,303 | 1,266 | 2,879 | +1,576 | +1,613 |
| expressjs-express-7366 | 1,076 | 1,202 | 1,187 | +112 | -15 |
| pallets-click-3769 | 816 | 1,070 | 1,395 | +579 | +325 |
| pallets-werkzeug-3298 | 2,448 | 1,989 | 2,122 | -325 | +133 |
| pallets-werkzeug-3273 | 3,208 | 3,729 | 3,695 | +487 | -33 |
| pallets-werkzeug-3266 | 2,838 | 2,941 | 3,026 | +188 | +86 |

### Cache-write tokens

> Measurement: 8 tasks, one model, one agent. This can show a direction or a problem. It cannot prove a general effect.

| Task | none | generic | olivium | olivium - none | olivium - generic |
| --- | ---: | ---: | ---: | ---: | ---: |
| pallets-click-3858 | 10,019 | 11,654 | 16,555 | +6,536 | +4,901 |
| pallets-flask-6096 | 6,555 | 7,439 | 8,994 | +2,439 | +1,556 |
| python-attrs-attrs-1593 | 6,553 | 7,927 | 10,582 | +4,029 | +2,655 |
| expressjs-express-7366 | 5,393 | 11,177 | 5,422 | +29 | -5,755 |
| pallets-click-3769 | 6,369 | 6,598 | 6,591 | +222 | -7 |
| pallets-werkzeug-3298 | 8,447 | 12,125 | 12,359 | +3,912 | +234 |
| pallets-werkzeug-3273 | 11,492 | 11,091 | 13,494 | +2,002 | +2,403 |
| pallets-werkzeug-3266 | 11,768 | 11,330 | 11,684 | -84 | +355 |

### Cache-read tokens

> Measurement: 8 tasks, one model, one agent. This can show a direction or a problem. It cannot prove a general effect.

| Task | none | generic | olivium | olivium - none | olivium - generic |
| --- | ---: | ---: | ---: | ---: | ---: |
| pallets-click-3858 | 120,196 | 134,957 | 336,798 | +216,603 | +201,841 |
| pallets-flask-6096 | 107,182 | 118,905 | 161,515 | +54,333 | +42,610 |
| python-attrs-attrs-1593 | 102,643 | 90,580 | 248,521 | +145,877 | +157,941 |
| expressjs-express-7366 | 111,360 | 115,537 | 106,517 | -4,843 | -9,020 |
| pallets-click-3769 | 65,345 | 99,614 | 102,327 | +36,982 | +2,713 |
| pallets-werkzeug-3298 | 114,050 | 89,663 | 101,968 | -12,082 | +12,305 |
| pallets-werkzeug-3273 | 98,651 | 120,710 | 109,459 | +10,808 | -11,251 |
| pallets-werkzeug-3266 | 116,421 | 134,055 | 128,953 | +12,531 | -5,102 |

### Files read outside the real fix

> Measurement: 8 tasks, one model, one agent. This can show a direction or a problem. It cannot prove a general effect.

| Task | none | generic | olivium | olivium - none | olivium - generic |
| --- | ---: | ---: | ---: | ---: | ---: |
| pallets-click-3858 | 0 | 0 | 0 | 0 | 0 |
| pallets-flask-6096 | 1.67 | 1.67 | 1.67 | 0 | 0 |
| python-attrs-attrs-1593 | 0.67 | 0.33 | 2.67 | +2 | +2.33 |
| expressjs-express-7366 | 1.33 | 1 | 1 | -0.33 | 0 |
| pallets-click-3769 | 0 | 0 | 0 | 0 | 0 |
| pallets-werkzeug-3298 | 1 | 1 | 1 | 0 | 0 |
| pallets-werkzeug-3273 | 1.33 | 0.67 | 2 | +0.67 | +1.33 |
| pallets-werkzeug-3266 | 5 | 5 | 5 | 0 | 0 |

### Turns before the first edit to a fixed file

> Measurement: 8 tasks, one model, one agent. This can show a direction or a problem. It cannot prove a general effect.

| Task | none | generic | olivium | olivium - none | olivium - generic |
| --- | ---: | ---: | ---: | ---: | ---: |
| pallets-click-3858 | 2.50 | 3 | 6.67 | +4.17 | +3.67 |
| pallets-flask-6096 | 3 | 4 | 4 | +1 | 0 |
| python-attrs-attrs-1593 | n/a | 2.50 | 3.33 | n/a | +0.83 |
| expressjs-express-7366 | 1 | 1 | 1.67 | +0.67 | +0.67 |
| pallets-click-3769 | 2 | 2 | 3.33 | +1.33 | +1.33 |
| pallets-werkzeug-3298 | 3 | 2 | 2 | -1 | 0 |
| pallets-werkzeug-3273 | 2.67 | 3.33 | 3.33 | +0.67 | 0 |
| pallets-werkzeug-3266 | 3 | 2.67 | 3 | 0 | +0.33 |

### Tool calls before that edit

> Measurement: 8 tasks, one model, one agent. This can show a direction or a problem. It cannot prove a general effect.

| Task | none | generic | olivium | olivium - none | olivium - generic |
| --- | ---: | ---: | ---: | ---: | ---: |
| pallets-click-3858 | 2.50 | 3 | 8.33 | +5.83 | +5.33 |
| pallets-flask-6096 | 3 | 4.33 | 4.33 | +1.33 | 0 |
| python-attrs-attrs-1593 | n/a | 2.50 | 4.67 | n/a | +2.17 |
| expressjs-express-7366 | 1 | 1 | 1.67 | +0.67 | +0.67 |
| pallets-click-3769 | 2 | 2 | 3.67 | +1.67 | +1.67 |
| pallets-werkzeug-3298 | 3 | 2 | 2 | -1 | 0 |
| pallets-werkzeug-3273 | 3 | 3.33 | 3.67 | +0.67 | +0.33 |
| pallets-werkzeug-3266 | 3 | 2.67 | 3 | 0 | +0.33 |

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
| pallets-click-3858 | $0.0668 | $0.0717 | $0.1359 |
| pallets-flask-6096 | $0.0437 | $0.0490 | $0.0636 |
| python-attrs-attrs-1593 | $0.0397 | $0.0416 | $0.0801 |
| expressjs-express-7366 | $0.0354 | $0.0515 | $0.0361 |
| pallets-click-3769 | n/a | n/a | n/a |
| pallets-werkzeug-3298 | $0.0570 | $0.0592 | $0.0623 |
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
| olivium | 3 | 9 | $0.2164 | $0.6492 |

**Did the agent use fewer tokens and cost less? (held-out only)**

- Against none, on these 3 tasks, the olivium arm cost more per run (a direction, not proof): median difference +$0.0053 (95% interval +$0.0029 to +$0.0110 across 3 tasks).
- Against generic, on these 3 tasks, the olivium arm cost more per run (a direction, not proof): median difference +$0.0032 (95% interval +$0.0012 to +$0.0045 across 3 tasks).

**Did the agent have better context? (held-out only)**

- Against none, no clear difference: median difference 0 (95% interval 0 to +0.67 across 3 tasks); the interval includes zero.
- Against generic, no clear difference: median difference 0 (95% interval 0 to +1.33 across 3 tasks); the interval includes zero.

**Was the agent more accurate? (held-out only)**

- Against none, no clear difference: median difference 0.00 (95% interval 0.00 to 0.00 across 3 tasks); the interval includes zero.
- Against generic, no clear difference: median difference 0.00 (95% interval 0.00 to 0.00 across 3 tasks); the interval includes zero.

| Metric | Better when | olivium - none | Tasks | olivium - generic | Tasks |
| --- | --- | ---: | ---: | ---: | ---: |
| Cost per run | lower | +$0.0053 [+$0.0029, +$0.0110] | 3 | +$0.0032 [+$0.0012, +$0.0045] | 3 |
| Input tokens | lower | +1 [-1, +1] | 3 | 0 [-1, +1] | 3 |
| Output tokens | lower | +188 [-325, +487] | 3 | +86 [-33, +133] | 3 |
| Cache-write tokens | lower | +2,002 [-84, +3,912] | 3 | +355 [+234, +2,403] | 3 |
| Cache-read tokens | lower | +10,808 [-12,082, +12,531] | 3 | -5,102 [-11,251, +12,305] | 3 |
| Files read outside the real fix | lower | 0 [0, +0.67] | 3 | 0 [0, +1.33] | 3 |
| Turns before the first edit to a fixed file | lower | 0 [-1, +0.67] | 3 | 0 [0, +0.33] | 3 |
| Tool calls before that edit | lower | 0 [-1, +0.67] | 3 | +0.33 [0, +0.33] | 3 |
| Solved | higher | 0.00 [0.00, 0.00] | 3 | 0.00 [0.00, 0.00] | 3 |
| Regressions per run | lower | 0 [0, 0] | 3 | 0 [0, 0] | 3 |
| Linter passes | higher | 0.00 [0.00, 0.00] | 3 | 0.00 [0.00, 0.00] | 3 |

| Task | Cost: none | generic | olivium | Solved: none | generic | olivium |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| pallets-werkzeug-3298 | $0.0570 | $0.0592 | $0.0623 | 1.00 | 1.00 | 1.00 |
| pallets-werkzeug-3273 | $0.0707 | $0.0771 | $0.0817 | 0.00 | 0.00 | 0.00 |
| pallets-werkzeug-3266 | $0.0695 | $0.0712 | $0.0724 | 0.00 | 0.00 | 0.00 |

## Before and after: the pilot's old harness and this run's new harness

Different runs: the pilot's old harness and this run's new harness were measured on different days with separate samples of the model. This table says what changed between the two runs; it does not show that the harness caused any difference. One more difference between them: in the pilot every arm was offered Claude Code's WebSearch and WebFetch (none of its 51 sessions used them); in this run no arm is.

Aggregate over the 5 pilot tasks (solved of runs; cost per solved task):

| Arm | Pilot | This run |
| --- | --- | --- |
| none | 12 of 15, $0.0541 | 12 of 15, $0.0541 |
| generic | 12 of 15, $0.0687 | 12 of 15, $0.0627 |
| olivium | 12 of 15, $0.0478 | 12 of 15, $0.0891 |

| Task | Solved share: old harness (pilot) | new harness (this run) | none (pilot) | none (this run) | Cost per run: old harness | new harness |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| pallets-click-3858 | 1.00 | 1.00 | 1.00 | 1.00 | $0.0560 | $0.1359 |
| pallets-flask-6096 | 1.00 | 1.00 | 1.00 | 1.00 | $0.0378 | $0.0636 |
| python-attrs-attrs-1593 | 1.00 | 1.00 | 1.00 | 1.00 | $0.0344 | $0.0801 |
| expressjs-express-7366 | 1.00 | 1.00 | 1.00 | 1.00 | $0.0314 | $0.0361 |
| pallets-click-3769 | 0.00 | 0.00 | 0.00 | 0.00 | $0.0317 | $0.0407 |

## Method

For each task, the repeats of each arm are averaged, leaving out runs recorded as `infra_error`. The difference is olivium minus the other arm for that task. The headline is the median of those differences across tasks. The interval is a percentile bootstrap: tasks are resampled with replacement 10000 times with seed 20261108, the median is taken each time, and the 2.5th and 97.5th percentiles are reported. Cost per solved task is the total cost of the arm's runs divided by the number of runs that solved the task; it has no interval because the protocol defines none.

Measurement: 8 tasks, one model, one agent. This can show a direction or a problem. It cannot prove a general effect.

## Supplement: refusals, hook activity, canaries and spend

This section is written by `supplement.py` from the same run directory and from the two canary directories. Its numbers are in `supplement.json`; the sections above come from `analyze.py` and `results.json`. Command text is cut to its leading program words and paths; refusal reasons are reduced to a class.

### Refusals and hook activity per arm (scored runs)

`none` and `generic` run with the benchmark's bypass settings and no hooks. `olivium` runs its exported settings in `default` mode; an unattended run refuses what Claude Code asks. "Guard" is the export's PreToolUse guard hook; "deny rule" is a deny rule in the exported settings; "ask" is Claude Code asking (outside the allow list, or a shell form it cannot check statically).

| Arm | Scored runs | Refused calls | Runs with a refusal | by guard | by deny rule | Claude Code asked | PreToolUse hook runs | Hook approvals | PreToolUse non-zero exits | PostToolUse (format) hook runs | Stop hook runs | Stop blocks (exit 2) | Runs with a Stop block |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| none | 24 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| generic | 24 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| olivium | 24 | 35 | 14 | 9 | 0 | 26 | 198 | 0 | 0 | 19 | 24 | 0 | 0 |

Guard warnings ("missing, changed or cannot be checked" / "failed") in the `olivium` arm: 0 / 0. Refused file-tool calls (Read, Edit, Write, Grep, Glob): 0.

Refusal classes in the `olivium` arm:

| Class | Where the docs (`docs/claude-code-connector.md`, "Generator settings (v1alpha2)") list it | Count |
| --- | --- | ---: |
| guard: this call names a path outside the project | The guard hook | 8 |
| ask: backslash-escaped whitespace | What still asks (backslash-escaped whitespace) | 6 |
| ask: cd followed by a write | What still asks (a cd followed by a write) | 4 |
| ask: cd before a git command | not listed | 3 |
| ask: compound, '..' after a cd | What still asks (a .. path after a cd) | 3 |
| ask: '..' path after a cd (resolved outside the working directory) | What still asks (a .. path after a cd) | 2 |
| ask: shell Claude Code could not parse | What still asks (shell Claude Code cannot check statically; this form not named) | 2 |
| ask: read-only git with -C | not listed (docs: read-only git runs by itself) | 1 |
| guard: this call runs a denied command | The guard hook | 1 |
| ask: compound, part outside the allow list (rmdir scratch_tmp) | What still asks (a command outside the allow list) | 1 |
| ask: compound, part outside the allow list (uv python) | What still asks (a command outside the allow list) | 1 |
| ask: outside the allow list (uv python) | What still asks (a command outside the allow list) | 1 |
| ask: $( ... ) nested command | What still asks ($( ... )) | 1 |
| ask: compound, a cd followed by a write | What still asks (a cd followed by a write) | 1 |

Refused calls of a class the docs do not list: 4 of 35.

<details><summary>Every refused call in the olivium arm</summary>

| Run | Solved | Tool | Refused by | Class | Docs | Command lead | Part Claude Code named |
| --- | --- | --- | --- | --- | --- | --- | --- |
| pallets-click-3769.olivium.r2 | no | Bash | asks | ask: '..' path after a cd (resolved outside the working directory) | What still asks (a .. path after a cd) | `cd /work/repo/src/click && grep -n ...` |  |
| pallets-click-3769.olivium.r2 | no | Bash | refused_guard | guard: this call names a path outside the project | The guard hook | `cd /work/repo && python - ...` |  |
| pallets-click-3769.olivium.r2 | no | Bash | asks | ask: cd before a git command | not listed | `cd /work/repo && python - ...` |  |
| expressjs-express-7366.olivium.r1 | yes | Bash | asks | ask: backslash-escaped whitespace | What still asks (backslash-escaped whitespace) | `sed -i ...` |  |
| pallets-click-3858.olivium.r2 | yes | Bash | asks | ask: compound, '..' after a cd | What still asks (a .. path after a cd) | `cd /work/repo/src/click; grep -n ...` | `head -40; head -20 ../../CHANGES.md` |
| pallets-click-3858.olivium.r2 | yes | Bash | asks | ask: compound, '..' after a cd | What still asks (a .. path after a cd) | `cd /work/repo/src/click; grep -n ...` | `grep ...` |
| pallets-click-3858.olivium.r2 | yes | Bash | refused_guard | guard: this call names a path outside the project | The guard hook | `cd /work/repo/src/click; python - ...` |  |
| pallets-click-3858.olivium.r2 | yes | Bash | asks | ask: cd followed by a write | What still asks (a cd followed by a write) | `cd /work/repo/src/click; python - ...` |  |
| pallets-click-3858.olivium.r2 | yes | Bash | asks | ask: read-only git with -C | not listed (docs: read-only git runs by itself) | `git -C /work/repo status --short` |  |
| pallets-werkzeug-3266.olivium.r3 | no | Bash | asks | ask: cd followed by a write | What still asks (a cd followed by a write) | `cd /work/repo; sed -i ...` |  |
| pallets-flask-6096.olivium.r1 | yes | Bash | asks | ask: backslash-escaped whitespace | What still asks (backslash-escaped whitespace) | `sed -i ...` |  |
| pallets-flask-6096.olivium.r1 | yes | Bash | asks | ask: backslash-escaped whitespace | What still asks (backslash-escaped whitespace) | `sed -i ...` |  |
| pallets-click-3858.olivium.r3 | yes | Bash | asks | ask: compound, '..' after a cd | What still asks (a .. path after a cd) | `cd /work/repo/src/click && grep -n ...` | `sed -n 1,200p; grep -n ...` |
| pallets-click-3858.olivium.r3 | yes | Bash | refused_guard | guard: this call names a path outside the project | The guard hook | `python - ...` |  |
| pallets-click-3858.olivium.r3 | yes | Bash | asks | ask: cd before a git command | not listed | `cd /work/repo && git diff --stat; grep -n ...` |  |
| python-attrs-attrs-1593.olivium.r3 | yes | Bash | refused_guard | guard: this call names a path outside the project | The guard hook | `python - ...` |  |
| python-attrs-attrs-1593.olivium.r3 | yes | Bash | asks | ask: shell Claude Code could not parse | What still asks (shell Claude Code cannot check statically; this form not named) | `mkdir -p scratch_tmp && cat > scratch_tmp/t.py ...` |  |
| python-attrs-attrs-1593.olivium.r3 | yes | Bash | refused_guard | guard: this call runs a denied command | The guard hook | `mkdir -p scratch_tmp && uv run python -c ...` |  |
| python-attrs-attrs-1593.olivium.r3 | yes | Bash | asks | ask: compound, part outside the allow list (rmdir scratch_tmp) | What still asks (a command outside the allow list) | `uv run python -c ...` | `rmdir scratch_tmp` |
| python-attrs-attrs-1593.olivium.r1 | yes | Bash | refused_guard | guard: this call names a path outside the project | The guard hook | `ls changelog.d \| head; git log -3 --format=%s \| head -3; cat > /tmp/t.py ...` |  |
| python-attrs-attrs-1593.olivium.r1 | yes | Bash | asks | ask: compound, part outside the allow list (uv python) | What still asks (a command outside the allow list) | `uv run --python 3.14 python -V 2>&1; uv python list --only-installed 2>&1 \| head` | `uv run --python 3.14 python -V 2>&1; uv python list --only-installed 2>&1` |
| python-attrs-attrs-1593.olivium.r1 | yes | Bash | asks | ask: outside the allow list (uv python) | What still asks (a command outside the allow list) | `uv python list --only-installed` |  |
| pallets-flask-6096.olivium.r3 | yes | Bash | asks | ask: backslash-escaped whitespace | What still asks (backslash-escaped whitespace) | `sed -i ...` |  |
| pallets-flask-6096.olivium.r3 | yes | Bash | asks | ask: backslash-escaped whitespace | What still asks (backslash-escaped whitespace) | `sed -i ...` |  |
| expressjs-express-7366.olivium.r3 | yes | Bash | asks | ask: backslash-escaped whitespace | What still asks (backslash-escaped whitespace) | `sed -i ...` |  |
| pallets-flask-6096.olivium.r2 | yes | Bash | asks | ask: $( ... ) nested command | What still asks ($( ... )) | `python - ...` |  |
| pallets-click-3769.olivium.r1 | no | Bash | asks | ask: '..' path after a cd (resolved outside the working directory) | What still asks (a .. path after a cd) | `cd /work/repo/src/click && grep -n ...` |  |
| python-attrs-attrs-1593.olivium.r2 | yes | Bash | refused_guard | guard: this call names a path outside the project | The guard hook | `cd /work/repo; (uv run --python 3.14 python -c ...` |  |
| python-attrs-attrs-1593.olivium.r2 | yes | Bash | refused_guard | guard: this call names a path outside the project | The guard hook | `cd /work/repo; ls changelog.d \| head; cat > /tmp/fr.py ...` |  |
| python-attrs-attrs-1593.olivium.r2 | yes | Bash | asks | ask: cd followed by a write | What still asks (a cd followed by a write) | `cd /work/repo; echo ...` |  |
| pallets-click-3858.olivium.r1 | yes | Bash | refused_guard | guard: this call names a path outside the project | The guard hook | `python - ...` |  |
| pallets-click-3858.olivium.r1 | yes | Bash | asks | ask: cd before a git command | not listed | `cd /work/repo && git status --short && python - ...` |  |
| pallets-click-3858.olivium.r1 | yes | Bash | asks | ask: shell Claude Code could not parse | What still asks (shell Claude Code cannot check statically; this form not named) | `cd /work/repo && sed -i ...` |  |
| pallets-click-3858.olivium.r1 | yes | Bash | asks | ask: compound, a cd followed by a write | What still asks (a cd followed by a write) | `sed -i ...` | `sed -i ...` |
| pallets-click-3858.olivium.r1 | yes | Bash | asks | ask: cd followed by a write | What still asks (a cd followed by a write) | `cd /work/repo && uv run mypy 2>&1 \| tail -15; uv run mypy mre_tmp.py \| tail -5; ...` |  |

</details>

**Descriptive only.** `olivium` runs with at least one refused call: 14 (tasks: expressjs-express-7366, pallets-click-3769, pallets-click-3858, pallets-flask-6096, pallets-werkzeug-3266, python-attrs-attrs-1593), mean cost $0.0778, mean turns 9.5, 11 solved. Runs without: 10, mean cost $0.0630, mean turns 5.6, 4 solved. Refusals are not assigned at random (they depend on the task and on what the model tried), so this split does not show that refusals caused the cost difference.

**Run integrity (same checks as the canary stop rule, conditions 2 to 5, over every scored run).** Meter cost differing from Claude Code's own `total_cost_usd` by more than one millionth: 0. Harness-check failures: 0. `olivium` settings bytes not the export: 0. Runs with a web tool offered or used, or a server tool in the meter: 0. Grading not `ok`: 0. Meter rows offering a web or server tool: 0; meter modes: live.

### The two paid canaries (not scored)

Each canary ran `pallets-click-3858`, three arms, one repeat, in its own output directory, before any scored run. Neither enters any number above.

**First canary, 2026-11-09 (generator before the fix).** Application `lib` 669ad231860e, `priv/blueprints` 226c267838af; `olivium` arm de56af958dd7 (24736 bytes). `/init` $0.0974; meter total $0.3979 (36 requests, modes live).

| Arm | Status | Solved | Cost | Turns | Fail-to-pass | Regressions | Lint | Refused calls | Hook approvals | Stop blocks |
| --- | --- | --- | ---: | ---: | --- | ---: | --- | ---: | ---: | ---: |
| none | completed | yes | $0.0626 | 5 | 1/1 | 0 | ok | 0 | 0 | 0 |
| generic | completed | yes | $0.0926 | 11 | 1/1 | 0 | ok | 0 | 0 | 0 |
| olivium | completed | yes | $0.1453 | 13 | 1/1 | 0 | ok | 5 | 0 | 0 |

Refused calls in the `olivium` arm:

1. Bash, asks (ask: relative-path read after a cd (asked while Read deny rules exist); docs: old generator; cause in PROTOCOL-v2.md change log, 2026-11-10): `cd /work/repo/src/click && grep -n ...`
2. Bash, asks (ask: compound, part outside the allow list (python3); docs: old generator; cause in PROTOCOL-v2.md change log, 2026-11-10): `python3 - ...`
3. Bash, asks (ask: outside the allow list (python3); docs: old generator; cause in PROTOCOL-v2.md change log, 2026-11-10): `python3 -I /tmp/edit_path.py`
4. Bash, asks (ask: compound, part outside the allow list (uv run); docs: old generator; cause in PROTOCOL-v2.md change log, 2026-11-10): `uv run --no-sync pytest -q 2>&1 | tail -3; which mypy pyright ruff`
5. Bash, asks (ask: outside the allow list (uv run); docs: old generator; cause in PROTOCOL-v2.md change log, 2026-11-10): `uv run --no-sync pytest -q tests/test_types.py`

Decision: stopped before any scored run. All 5 refusals came from the generator's own exported settings on ordinary reads and the project's toolchain (43 Read deny rules; bare python3 not allowed; uv run --no-sync not matching Bash(uv run pytest:*)). That was a product defect. The generator was fixed (refuse-only guard hook, no Read deny rules, allow list widened by detected toolchain) and every olivium arm was rebuilt; see PROTOCOL-v2.md, change log, 2026-11-10. This canary is the reason for that fix and is not scored.

**Second canary, 2026-11-10 (fixed generator, the arms this run used).** Application `lib` ccc8a19c4753, `priv/blueprints` 82e96fc7b4f3; `olivium` arm 3dc9aa9f09b7 (68376 bytes). `/init` $0.1008; meter total $0.4173 (36 requests, modes live).

| Arm | Status | Solved | Cost | Turns | Fail-to-pass | Regressions | Lint | Refused calls | Hook approvals | Stop blocks |
| --- | --- | --- | ---: | ---: | --- | ---: | --- | ---: | ---: | ---: |
| none | completed | yes | $0.0621 | 5 | 1/1 | 0 | ok | 0 | 0 | 0 |
| generic | completed | yes | $0.0828 | 8 | 1/1 | 0 | ok | 0 | 0 | 0 |
| olivium | completed | yes | $0.1716 | 14 | 1/1 | 0 | ok | 3 | 0 | 0 |

Refused calls in the `olivium` arm:

1. Bash, refused_guard (guard: this call names a path outside the project; docs: The guard hook): `cd /work/repo/src/click; python - ...`
2. Bash, asks (ask: cd followed by a write; docs: What still asks (a cd followed by a write)): `cd /work/repo/src/click; python - ...`
3. Bash, asks (ask: cd followed by a write; docs: What still asks (a cd followed by a write)): `cd /work/repo && uv run mypy mre_tmp.py 2>&1 | tail -8; rm mre_tmp.py; uv run my ...`

Decision: no stop condition of the amended rule (PROTOCOL-v2.md, change log, 2026-11-10) held. Mechanical conditions 2 to 5: none. Condition 1: each olivium refusal is of a class the docs list (docs/claude-code-connector.md at SHA-256 b4849bf5...: a /tmp path refused by the guard; twice a cd followed by a write, under What still asks). The scored run started after this canary.

### Spend

| Item | USD |
| --- | ---: |
| Before v2 (pilot programme, from its provenance) | 3.4818000 |
| First v2 canary (meter total, `/init` included) | 0.3979005 |
| Second v2 canary (meter total, `/init` included) | 0.4172819 |
| This run: `/init` for the `generic` arm, 8 tasks | 0.4557194 |
| This run: scored trials, infrastructure errors included | 4.3335840 |
| This run: meter total | 4.7893034 |
| Programme total | 9.0862858 |

The `olivium` arm's setup is $0: the generator calls no model. The owner approved $60 for the programme.

