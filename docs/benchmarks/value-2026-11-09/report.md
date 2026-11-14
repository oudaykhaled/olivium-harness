# Value benchmark results

> Pilot: 5 tasks, one model, one agent. This can show a direction or a problem. It cannot prove a general effect.

Each run is one attempt by Claude Code to fix one real bug. `none` has no instruction file, `generic` has a CLAUDE.md from Claude Code's own `/init`, and `olivium` has the files this project generates. Differences are olivium minus the other arm, so a negative cost difference means olivium was cheaper.

## The three questions

> Pilot: 5 tasks, one model, one agent. This can show a direction or a problem. It cannot prove a general effect.

**Did the agent use fewer tokens and cost less?**

- `none` cost per solved task: $0.0541 (12 of 15 runs solved, total $0.6486).
- `generic` cost per solved task: $0.0687 (12 of 15 runs solved, total $0.8244).
- `olivium` cost per solved task: $0.0478 (12 of 15 runs solved, total $0.5739).
- Against none, no clear difference: median difference -$0.0032 (95% interval -$0.0160 to +$0.0040 across 5 tasks); the interval includes zero.
- Against generic, on these 5 tasks, the olivium arm cost less per run (a direction, not proof): median difference -$0.0153 (95% interval -$0.0373 to -$0.0007 across 5 tasks).

**Did the agent have better context?**

- Against none, no clear difference: median difference 0 (95% interval -0.33 to +0.33 across 5 tasks); the interval includes zero.
- Against generic, no clear difference: median difference -1 (95% interval -1.67 to 0 across 5 tasks); the interval includes zero.

**Was the agent more accurate?**

- Against none, no clear difference: median difference 0.00 (95% interval 0.00 to 0.00 across 5 tasks); the interval includes zero.
- Against generic, no clear difference: median difference 0.00 (95% interval 0.00 to 0.00 across 5 tasks); the interval includes zero.

## How the runs ended

> Pilot: 5 tasks, one model, one agent. This can show a direction or a problem. It cannot prove a general effect.

0 runs were cut off by a spending limit (`budget_exhausted`). Those runs count as unsolved and their cost counts.

| Arm | Completed | Timeout | Turn limit | Budget exhausted | Infrastructure errors (not scored) | Solved | Cost per solved task |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| none | 15 | 0 | 0 | 0 | 0 | 12 of 15 | $0.0541 |
| generic | 15 | 0 | 0 | 0 | 0 | 12 of 15 | $0.0687 |
| olivium | 15 | 0 | 0 | 0 | 0 | 12 of 15 | $0.0478 |

![Cost per solved task by arm](chart_cost_per_solved.svg)

![Average cost per run by task and arm](chart_cost_by_task.svg)

![Did the agent use fewer tokens and cost less?](chart_fewer_tokens.svg)

![Did the agent have better context?](chart_better_context.svg)

![Was the agent more accurate?](chart_more_accurate.svg)

## Differences, by question

Median across tasks of the per-task difference, then the 95% bootstrap interval in brackets.

### Did the agent use fewer tokens and cost less?

> Pilot: 5 tasks, one model, one agent. This can show a direction or a problem. It cannot prove a general effect.

| Metric | Better when | olivium - none | Tasks | olivium - generic | Tasks |
| --- | --- | ---: | ---: | ---: | ---: |
| Cost per run | lower | -$0.0032 [-$0.0160, +$0.0040] | 5 | -$0.0153 [-$0.0373, -$0.0007] | 5 |
| Input tokens | lower | -1 [-7, +1] | 5 | -2 [-7, 0] | 5 |
| Output tokens | lower | -189 [-663, +142] | 5 | -465 [-790, -4] | 5 |
| Cache-write tokens | lower | +376 [-3,670, +1,418] | 5 | -3,203 [-8,889, +1,679] | 5 |
| Cache-read tokens | lower | -1,571 [-69,297, +14,380] | 5 | -32,603 [-72,390, -2,704] | 5 |

### Did the agent have better context?

> Pilot: 5 tasks, one model, one agent. This can show a direction or a problem. It cannot prove a general effect.

| Metric | Better when | olivium - none | Tasks | olivium - generic | Tasks |
| --- | --- | ---: | ---: | ---: | ---: |
| Files read outside the real fix | lower | 0 [-0.33, +0.33] | 5 | -1 [-1.67, 0] | 5 |
| Turns before the first edit to a fixed file | lower | +0.50 [-1, +1.17] | 4 | 0 [-1, +1] | 5 |
| Tool calls before that edit | lower | +0.50 [-1, +1.50] | 4 | 0 [-0.67, +1.33] | 5 |

### Was the agent more accurate?

> Pilot: 5 tasks, one model, one agent. This can show a direction or a problem. It cannot prove a general effect.

| Metric | Better when | olivium - none | Tasks | olivium - generic | Tasks |
| --- | --- | ---: | ---: | ---: | ---: |
| Solved | higher | 0.00 [0.00, 0.00] | 5 | 0.00 [0.00, 0.00] | 5 |
| Regressions per run | lower | 0 [0, 0] | 5 | 0 [0, 0] | 5 |
| Linter passes | higher | 0.00 [0.00, 0.00] | 5 | 0.00 [0.00, 0.00] | 5 |

## Per-task values

Average of the repeats for each task and arm, then the difference. `n/a` means no run of that task and arm produced the value, for example no edit reached a fixed file.

### Cost per run

> Pilot: 5 tasks, one model, one agent. This can show a direction or a problem. It cannot prove a general effect.

| Task | none | generic | olivium | olivium - none | olivium - generic |
| --- | ---: | ---: | ---: | ---: | ---: |
| pallets-click-3858 | $0.0720 | $0.0753 | $0.0560 | -$0.0160 | -$0.0193 |
| pallets-flask-6096 | $0.0410 | $0.0531 | $0.0378 | -$0.0032 | -$0.0153 |
| python-attrs-attrs-1593 | $0.0435 | $0.0453 | $0.0344 | -$0.0091 | -$0.0109 |
| expressjs-express-7366 | $0.0321 | $0.0321 | $0.0314 | -$0.0006 | -$0.0007 |
| pallets-click-3769 | $0.0277 | $0.0690 | $0.0317 | +$0.0040 | -$0.0373 |

### Input tokens

> Pilot: 5 tasks, one model, one agent. This can show a direction or a problem. It cannot prove a general effect.

| Task | none | generic | olivium | olivium - none | olivium - generic |
| --- | ---: | ---: | ---: | ---: | ---: |
| pallets-click-3858 | 11 | 12 | 10 | -1 | -2 |
| pallets-flask-6096 | 13 | 15 | 13 | 0 | -2 |
| python-attrs-attrs-1593 | 15 | 14 | 8 | -7 | -6 |
| expressjs-express-7366 | 11 | 11 | 11 | -1 | 0 |
| pallets-click-3769 | 8 | 16 | 9 | +1 | -7 |

### Output tokens

> Pilot: 5 tasks, one model, one agent. This can show a direction or a problem. It cannot prove a general effect.

| Task | none | generic | olivium | olivium - none | olivium - generic |
| --- | ---: | ---: | ---: | ---: | ---: |
| pallets-click-3858 | 3,108 | 2,891 | 2,444 | -663 | -447 |
| pallets-flask-6096 | 1,795 | 2,072 | 1,606 | -189 | -465 |
| python-attrs-attrs-1593 | 1,631 | 1,853 | 1,063 | -568 | -790 |
| expressjs-express-7366 | 994 | 876 | 872 | -122 | -4 |
| pallets-click-3769 | 848 | 1,776 | 989 | +142 | -787 |

### Cache-write tokens

> Pilot: 5 tasks, one model, one agent. This can show a direction or a problem. It cannot prove a general effect.

| Task | none | generic | olivium | olivium - none | olivium - generic |
| --- | ---: | ---: | ---: | ---: | ---: |
| pallets-click-3858 | 12,213 | 13,179 | 8,542 | -3,670 | -4,637 |
| pallets-flask-6096 | 4,739 | 7,371 | 4,168 | -571 | -3,203 |
| python-attrs-attrs-1593 | 5,422 | 5,161 | 6,840 | +1,418 | +1,679 |
| expressjs-express-7366 | 4,919 | 5,435 | 5,295 | +376 | -140 |
| pallets-click-3769 | 5,031 | 14,363 | 5,474 | +443 | -8,889 |

### Cache-read tokens

> Pilot: 5 tasks, one model, one agent. This can show a direction or a problem. It cannot prove a general effect.

| Task | none | generic | olivium | olivium - none | olivium - generic |
| --- | ---: | ---: | ---: | ---: | ---: |
| pallets-click-3858 | 103,358 | 134,390 | 101,787 | -1,571 | -32,603 |
| pallets-flask-6096 | 111,335 | 139,246 | 112,711 | +1,376 | -26,535 |
| python-attrs-attrs-1593 | 136,287 | 138,339 | 66,990 | -69,297 | -71,350 |
| expressjs-express-7366 | 97,870 | 97,026 | 94,321 | -3,548 | -2,704 |
| pallets-click-3769 | 66,412 | 153,182 | 80,793 | +14,380 | -72,390 |

### Files read outside the real fix

> Pilot: 5 tasks, one model, one agent. This can show a direction or a problem. It cannot prove a general effect.

| Task | none | generic | olivium | olivium - none | olivium - generic |
| --- | ---: | ---: | ---: | ---: | ---: |
| pallets-click-3858 | 0 | 1 | 0 | 0 | -1 |
| pallets-flask-6096 | 1.67 | 2.33 | 2 | +0.33 | -0.33 |
| python-attrs-attrs-1593 | 0 | 1.67 | 0 | 0 | -1.67 |
| expressjs-express-7366 | 1.33 | 1 | 1 | -0.33 | 0 |
| pallets-click-3769 | 0 | 1 | 0 | 0 | -1 |

### Turns before the first edit to a fixed file

> Pilot: 5 tasks, one model, one agent. This can show a direction or a problem. It cannot prove a general effect.

| Task | none | generic | olivium | olivium - none | olivium - generic |
| --- | ---: | ---: | ---: | ---: | ---: |
| pallets-click-3858 | 3 | 2.67 | 2 | -1 | -0.67 |
| pallets-flask-6096 | 2.50 | 2.67 | 3.67 | +1.17 | +1 |
| python-attrs-attrs-1593 | n/a | 3 | 2 | n/a | -1 |
| expressjs-express-7366 | 1 | 1 | 1 | 0 | 0 |
| pallets-click-3769 | 2 | 2 | 3 | +1 | +1 |

### Tool calls before that edit

> Pilot: 5 tasks, one model, one agent. This can show a direction or a problem. It cannot prove a general effect.

| Task | none | generic | olivium | olivium - none | olivium - generic |
| --- | ---: | ---: | ---: | ---: | ---: |
| pallets-click-3858 | 3 | 2.67 | 2 | -1 | -0.67 |
| pallets-flask-6096 | 2.50 | 2.67 | 4 | +1.50 | +1.33 |
| python-attrs-attrs-1593 | n/a | 3 | 3 | n/a | 0 |
| expressjs-express-7366 | 1 | 1 | 1 | 0 | 0 |
| pallets-click-3769 | 2 | 2 | 3 | +1 | +1 |

### Solved

> Pilot: 5 tasks, one model, one agent. This can show a direction or a problem. It cannot prove a general effect.

| Task | none | generic | olivium | olivium - none | olivium - generic |
| --- | ---: | ---: | ---: | ---: | ---: |
| pallets-click-3858 | 1.00 | 1.00 | 1.00 | 0.00 | 0.00 |
| pallets-flask-6096 | 1.00 | 1.00 | 1.00 | 0.00 | 0.00 |
| python-attrs-attrs-1593 | 1.00 | 1.00 | 1.00 | 0.00 | 0.00 |
| expressjs-express-7366 | 1.00 | 1.00 | 1.00 | 0.00 | 0.00 |
| pallets-click-3769 | 0.00 | 0.00 | 0.00 | 0.00 | 0.00 |

### Regressions per run

> Pilot: 5 tasks, one model, one agent. This can show a direction or a problem. It cannot prove a general effect.

| Task | none | generic | olivium | olivium - none | olivium - generic |
| --- | ---: | ---: | ---: | ---: | ---: |
| pallets-click-3858 | 0 | 0 | 0 | 0 | 0 |
| pallets-flask-6096 | 0 | 0 | 0 | 0 | 0 |
| python-attrs-attrs-1593 | 0 | 0 | 0 | 0 | 0 |
| expressjs-express-7366 | 0 | 0 | 0 | 0 | 0 |
| pallets-click-3769 | 0 | 0 | 0 | 0 | 0 |

### Linter passes

> Pilot: 5 tasks, one model, one agent. This can show a direction or a problem. It cannot prove a general effect.

| Task | none | generic | olivium | olivium - none | olivium - generic |
| --- | ---: | ---: | ---: | ---: | ---: |
| pallets-click-3858 | 1.00 | 1.00 | 1.00 | 0.00 | 0.00 |
| pallets-flask-6096 | 1.00 | 1.00 | 1.00 | 0.00 | 0.00 |
| python-attrs-attrs-1593 | 1.00 | 1.00 | 1.00 | 0.00 | 0.00 |
| expressjs-express-7366 | 1.00 | 1.00 | 1.00 | 0.00 | 0.00 |
| pallets-click-3769 | 1.00 | 1.00 | 1.00 | 0.00 | 0.00 |

## Cost per solved task, by task

> Pilot: 5 tasks, one model, one agent. This can show a direction or a problem. It cannot prove a general effect.

Total cost of the arm's runs on that task divided by how many of them solved it. `n/a` means none did.

| Task | none | generic | olivium |
| --- | ---: | ---: | ---: |
| pallets-click-3858 | $0.0720 | $0.0753 | $0.0560 |
| pallets-flask-6096 | $0.0410 | $0.0531 | $0.0378 |
| python-attrs-attrs-1593 | $0.0435 | $0.0453 | $0.0344 |
| expressjs-express-7366 | $0.0321 | $0.0321 | $0.0314 |
| pallets-click-3769 | n/a | n/a | n/a |

## Setup cost (reported separately)

> Pilot: 5 tasks, one model, one agent. This can show a direction or a problem. It cannot prove a general effect.

Includes what failed attempts spent. The upper bound also counts requests whose usage is unknown at their full reservation.

| Arm | Setup cost | Upper bound | Tasks with failed setup |
| --- | ---: | ---: | --- |
| none | $0.0000 | $0.0000 | none |
| generic | $0.3198 | $0.3198 | none |
| olivium | $0.4338 | $0.5416 | none |

## One run with the exported settings (not part of the analysis)

> Pilot: 5 tasks, one model, one agent. This can show a direction or a problem. It cannot prove a general effect.

- `pallets-click-3858`: status `completed`, solved False, cost $0.0265, tool calls {"Bash": 1, "Grep": 1, "Read": 1}.

## Method

For each task, the repeats of each arm are averaged, leaving out runs recorded as `infra_error`. The difference is olivium minus the other arm for that task. The headline is the median of those differences across tasks. The interval is a percentile bootstrap: tasks are resampled with replacement 10000 times with seed 20261108, the median is taken each time, and the 2.5th and 97.5th percentiles are reported. Cost per solved task is the total cost of the arm's runs divided by the number of runs that solved the task; it has no interval because the protocol defines none.

Pilot: 5 tasks, one model, one agent. This can show a direction or a problem. It cannot prove a general effect.
