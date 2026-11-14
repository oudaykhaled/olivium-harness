# Value benchmark protocol, version 3

Written 2026-11-11, before any v3 candidate was looked at, before the candidate walk,
the pilot, any Olivium export of a candidate, or any paid v3 run. This file is the
pre-registration for the third measurement. `PROTOCOL.md` (the pilot) and
`PROTOCOL-v2.md` (the second measurement) are not changed by it. The design comes from
the program's final plan (`docs/plans/harness-enhancement-plan.md`, sections 7 and 8)
and the master plan's benchmark section, which it does not change except where this
file says so. Any change after the first SHA-256 is recorded goes in the change log at
the end, with the reason, and the new SHA-256 is recorded next to the old ones.

## Why a third measurement

v2 (8 tasks x 3 setups x 3 repeats, plus a re-run of the `olivium` setup) found no
gain and could not have shown an accuracy gain:

- No task was of middle difficulty. Every task gave the same result in all 12 of its
  runs: 5 tasks were always solved, 3 never.
- The tasks were tiny. The no-harness setup needed a median of 6 turns (4 to 8), and
  6 of 8 fixes touched one code file. Tokens were almost only turns x fixed context.
- Cache warmth moved dollars by 18% to 30% of a run, so dollars are not a fair primary.
- The solve-rate statistic was a median across tasks, which cannot move unless more
  than half the tasks change.
- The 8 v2 tasks and their repositories were then used to develop the new harness, so
  they are development data now.

v3 asks the same question on harder, unknown tasks, chosen by rule, with difficulty set
from no-harness runs only, and with decision rules fixed here before any data.

## Question

On bug-fix tasks the plain agent finds non-trivial but possible, in repositories it is
unlikely to know, does the harness the generator exports (unmodified, its own settings)
cut tokens per run or raise the solve rate, against no instruction file and against a
free `/init` file?

## Setups

| Setup | What the agent gets | Permission mode |
| --- | --- | --- |
| `none` | The repository at the base commit, instruction files removed | `bypassPermissions` with `arms/benchmark-settings.json`, as v2 |
| `generic` | The same, plus one `CLAUDE.md` written by Claude Code's own `/init` at the base commit | as `none` |
| `olivium` | The same, plus the output of `bin/harnessforge generate PATH --runtime claude_code --export DIR --json`, unmodified, with its own `.claude/settings.json` passed with `--settings` | `default`, as v2 |

- Every setup starts from the same snapshot. Any `CLAUDE.md`, `AGENTS.md`, `.claude/`,
  `.cursor/` or `.github/copilot-instructions.md` in the repository is removed first, at
  any depth (`arms/entry.sh`), exactly as in v2.
- The `olivium` export is whatever the frozen generator writes by default for a solo
  export. Today that is the `lean` context profile (owner decision 3 of the final plan).
  The coordinator adopted three open decisions under the owner's general go-ahead,
  before any v3 data: O1, automatic memory stays on in `lean`; O2, the solve-rate
  tolerance is T = 10 points; O3, `lean` keeps denying the subagent tools (`Task`,
  `Agent`), while `standard` keeps them. The prompt-time locator card (item 6 of the
  plan) is not in the export this round; Gate 0 row 9 allows that.
- Generator input rules are v2's, unchanged: a fresh repository holding only the base
  commit and its ancestors, no tags, no remote; instruction files removed from the tree
  and index; the generator runs on the host and only parses files and history; the
  arm is refused if the fix commit, a pull request commit or `#<pull request number>`
  appears in any exported file. A generator failure on any task stops the benchmark
  before a paid run; nothing is patched or substituted.
- `UV_NO_SYNC=1` is set for every session in every setup, `/init` included.
- No other setup is scored. `none-lean` (the `none` setup plus only the export's settings
  trim, v2's information setup) runs once per scored task as an unscored control, in the
  scored run's blocks of repeat 1 (change log of 2026-11-11, integration 2 repair round,
  attribution). It decides only how a gain may be worded, never the verdict.

## Development set and exclusions

- `corpus/dev-repos-v3.txt` lists every repository any enhancement lane used to develop
  or test the generator: the repositories of all 8 v2 tasks and every repository lane
  G named as a development repository. It is written before the walk starts, its
  SHA-256 is written into the walk log and into `manifest-v3.json`, and the
  coordinator commits it at the freeze. It may not change after the walk starts.
- Owners `pallets`, `pallets-eco`, `python-attrs` and `expressjs` are excluded
  entirely, whatever the list says.

## Model cutoff

The `claude-sonnet-5-5` model page (platform.claude.com, "Models overview" and the
Claude Sonnet 5.5 page, read 2026-11-11) gives "Training data cutoff: Jun 2026" and
"Reliable knowledge cutoff: Jun 2026", to the month only. The cutoff is therefore taken
as the last day of that month, **2026-06-30**, the same value v2 used. Rule T1 below
uses it.

## Repository pool

| # | Rule |
| --- | --- |
| R1 | Primary language on GitHub is Python, JavaScript or TypeScript |
| R2 | 100 to 3,000 stars; not archived; not a fork; licence MIT, Apache-2.0, BSD-2-Clause, BSD-3-Clause or ISC |
| R3 | Ordered by SHA-256 of the seed plus the full name; walked in that order until the target is met |
| R4 | Not an excluded owner (above); not listed in `corpus/dev-repos-v3.txt` |
| R5 | At least 150 tracked non-test source files at the task's base commit |
| R6 | An install recipe from the fixed list below applies at the base commit; `toolchain_nondefault` is recorded |

**Population.** One snapshot of GitHub repository search, taken once before the walk and
never refreshed: for each language in R1 and each licence in R2 (SPDX names in search
form `mit`, `apache-2.0`, `bsd-2-clause`, `bsd-3-clause`, `isc`), the query
`language:<L> license:<l> stars:<a>..<b> archived:false fork:false is:public
pushed:>=2026-07-31`. The star range starts as 100..3000 and is split in halves while a
query reports more than 1,000 results (the search limit); a single star value with more
than 1,000 results is split further by `created:` date ranges. Every page of every leaf
query is read. The `pushed` filter only drops repositories that cannot hold a task:
rule T1 needs a merge into the default branch on or after 2026-07-31, and such a merge
is a push. The snapshot (queries, counts, items) and its SHA-256 are stored with the
walk record outside the repository.

**Order (R3).** Seed `olivium-bench-v3-20261111`. Key of a repository:
SHA-256 of the UTF-8 bytes of `seed + "\n" + full_name.lower()`, as hex. Ascending key
order. Nobody reorders, skips or picks.

**Source files (R5).** Tracked files at the base commit whose extension is one of
`.py .pyi .pyx .js .jsx .mjs .cjs .ts .tsx .mts .cts .vue .svelte`, that are not test
paths (below), not `*.min.js`, and not under a directory segment named
`node_modules`, `vendor`, `third_party`, `dist`, `build` or `site-packages`.

**Install recipes (R6).** Checked at the base commit, first match wins. A repository
with no matching recipe is rejected under R6. Python images start from the official
`python:3.12` image, or `python:3.13`, `python:3.11`, `python:3.14` or `python:3.10`
(first in that order that the project's `requires-python` allows). JavaScript and
TypeScript images start from `node:22`, the Node major the agent image ships.

| Kind | Applies when | Install |
| --- | --- | --- |
| `uv` | root `uv.lock`, and `pyproject.toml` has a `[dependency-groups]` group named `test`, `tests` or `testing` (else `dev`) | `uv sync --frozen --no-default-groups` with those groups |
| `uv-extra` | root `uv.lock`, and an optional-dependencies extra named `test`, `tests`, `testing` (else `dev`) | `uv sync --frozen --extra <name>` |
| `poetry` | root `poetry.lock` | Poetry 2.5.1 in its own environment; `poetry install` into the project environment with the groups named `test`, `tests`, `testing` or `dev` that exist |
| `pip-group` | `pyproject.toml` has such a dependency group, no lock file | `pip install -e . --group <name>` (pip 25.3) |
| `pip-extra` | `pyproject.toml` `[project.optional-dependencies]` or `setup.cfg` `[options.extras_require]` has such an extra | `pip install -e .[<name>]` |
| `pip-requirements` | a test requirements file exists (`requirements-test.txt`, `requirements_test.txt`, `test-requirements.txt`, `test_requirements.txt`, `requirements-tests.txt`, `requirements-dev.txt`, `requirements_dev.txt`, `dev-requirements.txt`, `requirements/test.txt`, `requirements/tests.txt`, `requirements/testing.txt`, `requirements/dev.txt`, `tests/requirements.txt`, first found) | `pip install -r requirements.txt` when present, then the test file, then `pip install -e .` when the project is installable |
| `npm` | `package-lock.json` or `npm-shrinkwrap.json` | `npm ci` |
| `pnpm` | `pnpm-lock.yaml` | pnpm from `packageManager`, else by lock version (9: 10.34.9, 6: 8.15.9, 5.4: 7.33.7); `pnpm install --frozen-lockfile` |
| `yarn` | `yarn.lock`, classic format | Yarn 1.22.22; `yarn install --frozen-lockfile` |
| `yarn-berry` | `yarn.lock`, Berry format, `.yarnrc.yml` with `nodeLinker: node-modules` | Yarn from `packageManager` through Corepack; `yarn install --immutable` |
| `npm-nolock` | `package.json` and no lock file | `npm install --no-package-lock` |

- Python tests always run as `python -m pytest -p no:cacheprovider -q --tb=short
  --junitxml=<results>`, with the project's own pytest configuration. If the recipe does
  not install pytest, pytest 8.4.2 is added to the image and `toolchain_nondefault` is
  set.
- JavaScript and TypeScript tests use the runner the root `package.json` declares in
  its dependencies, in this order: `vitest` (`vitest run --reporter=junit`), `jest`
  (with the `jest-junit` 16.0.0 reporter installed outside the repository), `mocha`
  (`--reporter xunit`), or `node --test` in `scripts.test` (`--test-reporter=junit`).
  When `scripts.test` is a single command made of optional environment assignments
  (optionally behind `cross-env`) and that runner, its arguments are kept and the
  reporter arguments added; otherwise the runner is called with no arguments.
  Watch flags are dropped. `CI=true` is set. Other runners (ava, tap, karma, browser
  runners) have no recipe.
- `bun.lock` or `bun.lockb` alone, Yarn Plug'n'Play, and a Python project with none of
  the files above have no recipe.
- `toolchain_nondefault` is true when the repository's own test entry point is not
  plain `pytest` or a plain `npm test`: any of `tox.ini`, `noxfile.py`, `[tool.tox]`,
  `[tool.nox]`, `[tool.hatch.envs`, `[tool.poe` or a root `Makefile` (Python); a
  `workspaces` field or `pnpm-workspace.yaml`, a package manager other than npm, or a
  `scripts.test` that is not the single-command form above (JavaScript and
  TypeScript); or pytest was added. There is no quota on it; the subgroup is reported.

## Task rules

| # | Rule |
| --- | --- |
| T1 | A pull request merged into the default branch on or after 2026-07-31 (cutoff 2026-06-30 plus 30 days), whose linked issue was opened on or after 2026-07-01 |
| T2 | A linked issue in the same repository, by a closing keyword in the pull request body or GitHub's linked-issue field (`closingIssuesReferences`), with at least 20 prose words in its body; the issue is not itself a pull request and no earlier accepted task used it |
| T3 | The fix, from the base commit to the merge commit: at least 2 non-test code files or at least 25 changed lines in non-test code files; at most 8 non-test code files and at most 400 changed lines in them; at least 1 changed test file with a code extension; no dependency change; no binary change to a non-test code file |
| T4 | The issue's title and body do not contain the path or the file name of any non-test code file the fix changes (case-insensitive; a file name counts only as a whole token, not inside a longer name) |
| T5 | Docker validation: 3 of 3 runs fail before the fix and 3 of 3 pass after it, 300 s limit per run, no network; then the real fix is graded solved by the scoring grader (change log of 2026-11-11, integration 2 repair round); recorded at the same step for free: whether every other test passes at the base commit |
| T6 | At most 2 tasks per repository; at least 8 repositories in the pool |

Definitions:

- **Code extension**: the R5 list. Docs, changelogs, configuration and data files are
  not code; they go into the gold patch but do not count for T3.
- **Test path**: a directory segment `tests`, `test`, `__tests__`, `__test__`,
  `testing`, `spec` or `specs`; or a file name `test_*.py`, `*_test.py`, `conftest.py`,
  or `*.test.<ext>` / `*.spec.<ext>` for a JavaScript or TypeScript extension.
- **Dependency change**: any changed non-test path named `pyproject.toml`, `setup.py`,
  `setup.cfg`, `Pipfile`, `Pipfile.lock`, `poetry.lock`, `uv.lock`, `pdm.lock`,
  `package.json`, `package-lock.json`, `npm-shrinkwrap.json`, `yarn.lock`,
  `pnpm-lock.yaml`, `bun.lock`, `bun.lockb`, or a `requirements*.txt`/`.in`,
  `constraints*.txt` or `requirements/*` file (v2's definition plus the bun lock files).
- **Base commit**: v2's derivation, unchanged (first parent of a merge commit; the
  parent of a squash; walking back over a rebase).
- **Prose words**: v2's count (comments, code blocks, inline code and links removed).
- **Task id**: `<owner>-<name>-<pull request number>`, lower case, every character
  outside `a-z 0-9 -` replaced by `-`.

**T4 is a limit of the result.** It keeps tasks where the agent must find the code. The
share of candidates that reach T4 and fail it is reported next to every result, so
readers see how much real work the rule leaves out.

## Walk

Repositories in R3 order. For each repository: R4, then its pull requests merged into
the default branch on or after 2026-07-31, newest merge first. Each pull request is
checked in this fixed order, and the first rule it fails is recorded:
T1 (merge date, default branch), T2 (link), T1 (issue date), T2 (prose, reuse), T3 (from
the pull request's file list), T4, then the repository is cloned (read-only `git`, no
checkout) and the base commit derived, T3 again from `git diff --numstat` between base
and merge commit, R5, R6, T5. A repository stops after its second accepted task (T6),
or after 3 of its candidates in a row are rejected at T5 with no acceptance between them
(recorded once for the repository, under T5; change log of 2026-11-11, walk cost).
A repository with no pull request in the window is recorded once, under T1.

Every candidate considered, accepted or rejected, is one line of the walk log with the
rule id. Rejections at T5 carry the step (image build, isolation probe, patch apply,
timeout, no results, no fail-to-pass test, no pass-to-pass test, gold patch not
gradeable). Every restart of the walk is a record of the walk log with the SHA-256 of
this file and of the code that applies it. An image build that
fails is retried once (network at build time can fail); a second failure rejects.

**Target.** The walk stops when 48 tasks are accepted (the pilot stage 1 ceiling) or the
population is exhausted. If it has to stop for time after at least 24 tasks are
accepted, it stops at a repository boundary and the pool is the accepted list so far;
time is the only allowed reason, never what a task looks like. The pool order is the
order of acceptance.

**Yield fallbacks, fixed now.** Only if the whole population has been walked and fewer
than 24 tasks are accepted, apply in this order, recording each step and the yield after
it, and stop as soon as 24 are reached:

1. F1, stars 50 to 5,000: repositories of the same queries with 50 to 99 or 3,001 to
   5,000 stars are added, ordered by the same key, and walked after the first
   population.
2. F2, 3 tasks per repository: repositories holding 2 accepted tasks, in pool order,
   continue their pull request list for one more task.
3. F3, R5 down to 100 source files: candidates rejected only at R5 with 100 to 149
   source files are re-checked from R6 on, in walk order, under the cap then in force.

Floor 12 tasks: below 12 after F3, stop and ask the owner. Nothing else may be relaxed.

**Docker validation (T5).** Following v2's `corpus/select.py`:

- One dependency image per candidate, `olivium-bench-deps-<task id>:v1`, labelled
  `olivium-bench=1`, built with network: the repository fetched at the base commit only
  (no remote, no tags, no later refs, reflog expired), dependencies installed by the
  recipe. Installing may not change the tracked tree.
- An isolation probe in the image, as v2: head is the base commit, only `main`, no
  remote, no tag, no reflog, no fix or pull request commit reachable, no released copy of
  the project installed in place of the working tree (Python; the npm copy scan as v2).
- 3 runs with the test patch at the base commit and 3 runs with the test patch and the
  fix, each in a fresh container with `--network none`, 1,800 MB memory, 2 CPUs, 300 s.
  Fail-to-pass tests: failing or absent in all 3 base runs and passing in all 3 fix runs;
  at least 1 is required. Pass-to-pass tests: passing in all 6; at least 1 is required.
  A test whose result differs between runs of one side is flaky and is neither.
- Gold grading: the real fix goes once through the scoring grader (`grade/grader.py`,
  `grade/grade.sh`) in place of an agent's patch, in a fresh `--network none` container
  from the dependency image, with protection on and the scored run's test limit. The
  candidate is rejected (`gold_not_gradeable`) unless every fail-to-pass test passes and
  no pass-to-pass test regresses or goes missing. A task the real fix cannot solve under
  grading measures nothing.
- Recorded for each accepted task: the full-suite census (whether any test other than
  the fail-to-pass ones fails or is flaky at the base commit), the lint command when the
  repository configures one and the tool is installed (v2's rule), wall times, image id,
  `toolchain_nondefault`, the recipe kind and the source file count.
- Candidate code, its tests and its install scripts run only in these containers. On
  the host only `git` and read-only GitHub API calls touch candidate data.

**Outputs.** Outside the repository: the population snapshot, the walk log (every
candidate, rule id, reason), the candidate list and the validation evidence. In the
repository: `corpus/manifest-v3.json` in v2's manifest schema, references only (URLs,
commits, test ids, dates, checksums), no third-party code, issue text or patches; with
`selection.status` `pool_before_pilot` and the pool order. Generator lanes never read
any of these.

## Difficulty filter, from no-harness runs only

- Stage 1: one `none` run per pool task, in pool order. Drop a task solved in 8 turns or
  fewer (trivial; 8 was the largest `none` turn count in v2).
- Stage 2: two more `none` runs for every task left. Keep a task solved 1, 2 or 3 times
  of 3, except 3 of 3 with a median under 10 turns. Drop a task solved 0 of 3 times.
- Take the first 16 kept tasks in pool order (or the size the cost rule below sets),
  write the frozen manifest with its checksum, and record the checksum in this file's
  change log before any scored run.
- Pilot runs are discarded. Every setup, `none` included, is run fresh for scoring.

What the filter does, stated now: dropping never-solved tasks removes tasks where a
harness could only gain accuracy, which works against `olivium`; dropping trivial tasks
removes tasks where an instruction file can only add tokens, which works for both
instruction-file setups. The result applies to "tasks the plain agent finds non-trivial
but possible", and the report says so next to the numbers.

**Size rule, fixed now.** Design: 16 tasks x 3 setups x 3 repeats = 144 scored runs. If
pilot stage 1 shows more than $0.18 per run, cut tasks, not repeats, down to 12 (108
runs). If under $0.12, raise to 24 tasks (216 runs) when the pool holds enough kept
tasks. Floor 12; below 12 kept tasks, stop and ask the owner.

## Freeze order

1. `corpus/dev-repos-v3.txt` written (and later committed by the coordinator) before the
   walk starts.
2. Candidate lists stay outside the repository except `manifest-v3.json`; no generator
   lane reads them, `PROTOCOL-v3.md` or `corpus/*v3*`.
3. The generator is frozen before the pilot and before any `olivium` export is built for
   any candidate: its commit and the digests of `lib`, `priv/blueprints`, `config`,
   `bin/harnessforge` and `mix.lock` go into this file's change log.
4. After the freeze and before the pilot, the free request capture records each task's
   per-request trim (the `none` first request minus the `olivium` first request, mock
   meter, real Claude Code) into the run directory. It does not change the export.
5. Pilot data may not change the export, the rules or the analysis.

## Environment and run procedure

- Claude Code 2.1.311 in every image, model `claude-sonnet-5-5` in every setup and in
  `/init`. 60 turns, 20 minutes, $3 per run, two runs at a time.
- `WebSearch` and `WebFetch` removed from every session (`--disallowedTools`), and the
  meter refuses any request that offers a web or server tool; a run offered one is
  `infra_error` and a stop condition, as in v2.
- The prompt is v2's in every setup: the issue title and body, then
  `Fix this issue in the repository in the current directory.`
- Setups are always interleaved, in seeded blocks (seed `20261108`, the runner's
  default): the (task, repeat) blocks are shuffled, and each block runs every setup
  once, in a shuffled order, so no setup runs more than twice in a row. The runner
  refuses a scored run of a single setup. Warm-start counts (a first request read from
  a cache another run left) are reported per setup.
- Grading is v2's: the agent's patch on a clean checkout in a fresh `--network none`
  container from the dependency image, test files and test configuration restored, the
  real test patch applied, then lint and the task's test command. `.olivium/`,
  `CLAUDE.md` and `.claude/` are not counted as the agent's work. The test command's
  limit is 600 s, twice T5's 300 s (change log of 2026-11-11, integration 2 repair round).
- No paid phase (pilot, `/init`, canary, scored run) starts while the selection uses
  Docker: the walk has ended or was stopped (`STOP`) first, and the runner refuses a paid
  protocol 3 run while a selection container is running.
- `infra_error` runs are retried up to 3 attempts. A run that fails because of the model
  or the harness is never repeated.
- Canary: one task (the first of the frozen manifest), three setups, one repeat, not
  scored, in its own output directory, with v2's amended canary stop rule
  (`PROTOCOL-v2.md`, change log of 2026-11-10) and the connector documentation as it
  stands at the freeze. Its `olivium` transcript is read for the frozen export's new
  texts, which have no paid evidence yet: whether the agent reacts to the environment
  line (for example "Python 3.14 is not available here ... Skip it.") by no longer running
  Python at all, and whether the deprecation and warnings sentences change what it does.
  The finding is reported; it is not a stop rule.

## Outcomes

**Primary outcomes, `olivium` against `none`:**

1. **Total tokens per run.** For each task, the ratio of the mean total tokens of its
   `olivium` runs to the mean of its `none` runs (input, output, cache write and cache
   read, from the meter). The statistic is the median of these ratios across tasks.
2. **Solve rate.** For each task, the share of `olivium` runs solved minus the share of
   `none` runs solved (solved: every fail-to-pass test passes, no pass-to-pass test
   regresses, as v2). The statistic is the mean of these differences across tasks.

Per-task means use the scored runs that are not `infra_error`. A task without such a
run in both setups is left out of that comparison; a primary with no task left gives
the verdict **insufficient data**, checked before the table below.

**A primary passes** when both hold: the 95% percentile bootstrap interval of its
statistic (tasks resampled with replacement, 10,000 resamples, seed `20261108`) excludes
no effect (a ratio of 1, a difference of 0); and a two-sided exact sign-flip test across
tasks gives p < 0.05. The sign-flip test enumerates every assignment of signs to the
per-task values (the log of the ratio for tokens, the difference for solve rate) and
uses their sum as its statistic (the same for both primaries); p is the share of
assignments whose sum is at least as far from zero as the observed one. Both
tests are required because the bootstrap alone is loose at this size: 6% to 9.5% false
positives in the master plan's simulation. A null simulation of the two tests exactly as
`analyze.py --protocol 3` runs them (16 tasks, no real effect, 2,000 simulated
benchmarks per scenario; change log of 2026-11-11, analysis) gave 5.1% to 6.6% for the
bootstrap alone and 1.8% to 3.2% with both.

**"Significantly higher" or "significantly lower"** means that primary passes in that
direction.

**Verdict, fixed now (T = 10 points, O2):**

| Verdict | Rule | What follows |
| --- | --- | --- |
| **Failure** (checked first) | Tokens significantly higher, or solve rate significantly lower, or more than 1 refusal per 10 `olivium` runs (every permission denial in an `olivium` run counts, an upper bound on refusals of normal work) | Publish; revert the defaults that caused it |
| **Dramatic gain** | Tokens at least 25% lower (median ratio at most 0.75) and passing, or solve rate at least 20 points higher and passing; and the other primary within tolerance: tokens at most +5% (median ratio at most 1.05), solve rate at least -10 points and not significantly lower | Publish; the claim is limited to one model, one agent, these task rules; the headline carries the behaviour-only ratio and the configuration share |
| **Gain with an accuracy warning** | A primary passes; the other is outside its tolerance but not significantly worse | Publish with the warning in the headline; no "dramatic" wording |
| **Measurable gain** | A primary passes below the dramatic bar; the other within tolerance | Publish |
| **No demonstrated gain** | Neither primary passes | Publish; stop spending benchmark money on generated context text; next effort: human-reviewed claims and the free safety suite |

The report states that 16 x 3 cannot rule out a solve-rate drop under about 25 points:
a harness with no effect shows a drop beyond -10 points in about 16% of simulated
benchmarks.

**Main secondary comparison:** `olivium` against `generic` on both primaries, same
statistics and tests.

**Named context-use outcomes (secondary, in the headline table):** tokens in the first
request; tokens spent before the first edit of a file the real fix changed (shell edits
count); the largest context reached in a run. Definitions as built are in the change log
of 2026-11-11, integration 2 repair round.

**Attribution (secondary, in the headline):** `olivium` against `none-lean` on both
primaries, same statistics and tests, one `none-lean` run per task. A primary that passes
against `none` is credited to the harness's text and hooks only when `olivium` also passes
against `none-lean` on that primary in the same direction. Otherwise the headline words it
as a configuration (settings) gain, and no wording may credit `CLAUDE.md` or the hooks.

**Other secondaries, reported, never used for the verdict:**

- **Behaviour-only ratio.** Per task, (mean `olivium` tokens + trim x mean `olivium`
  turns) / mean `none` tokens, where trim is the task's per-request trim from freeze
  step 4 (`OUT/trim.json`) and turns are Claude Code's turns for the run. The same with
  the meter's request rows in place of turns is reported next to it as a sensitivity
  figure. Missing trim means "not available", never zero. Median across tasks, same two
  tests. It is an optimistic bound for what the harness's text and hooks did: it credits
  them with every change in behaviour that the trim itself causes (on Gate 1 it gave 0.858
  while `olivium` against `none-lean` gave 1.175). The configuration share is the rest.
- **Subagent use** per setup: `Agent`/`Task` calls and the tokens of their requests.
- **Dollars per run** per setup, with the warm-start count, and the note that tokens are
  mostly cache reads at 1/20 of the input price, so dollars and tokens can disagree.
- Grading wall time of the test command per setup, and the runs killed at its limit.
- Turns, wall time per setup (the Stop hook adds time, not tokens), files read outside
  the fix, turns and tool calls before the first fix-file edit (with the count of runs
  that never edited one), wrong commands ("command not found", "No module named",
  unknown option, a test call collecting 0 tests), "tool not installed" results, first
  test command correct, regressions, new lint findings.
- Harness-caused refusals and Stop blocks per run; hook fire counts; refusals of normal
  work (counted against `olivium`).
- Conventions: changelog touched when the real fix touched one; a test added or changed;
  deprecation compliance where the practice rule fired.
- The T4 rejection share and the full-suite census of the pool.
- Subgroups by language and by `toolchain_nondefault`.
- The safety value is measured separately and for free: the scripted unsafe list and
  normal list replayed through real Claude Code in every setup (mock meter), reporting
  blocked-unsafe and wrongly-blocked-normal. Every setup's tool calls in the paid run are
  also classified offline with the same rule list ("would have been refused").

## Power, quoted so readers know what this size can show

16 tasks x 3 repeats, both tests, simulated (master plan section 3.2): a 25% token
saving is detected with 99% power at v2's noise and 83% at a pessimistic guess; 15% with
77% or 34%. Solve rate: +30 points with 0.91; +20 points with 0.61; +10 points with
0.20. This design shows a dramatic gain if there is one. It cannot prove a modest one.

## Spending and restarts

Spent before v3: $10.49 of the $60 the owner approved. Left: $49.51.

| Item | Size | Cap |
| --- | --- | --- |
| Paid rehearsal (v2 tasks, development data; Gate 1) | 32 runs plus 8 `none-lean` runs | $2.60 |
| Pilot stage 1 (`none`, 1 run) | up to 48 pool tasks at about $0.10 | $5.00 |
| Pilot stage 2 (`none`, 2 more runs) | up to 22 tasks x 2 at about $0.18 | $8.00 |
| `/init` files | 16 tasks at about $0.10 | $2.00 |
| Canary | 1 task x 3 setups, not scored | $0.60 |
| Scored run | 144 runs at about $0.18 | $25.91 |
| `none-lean` control, in the scored run's blocks (change log of 2026-11-11, integration 2 repair round) | 16 runs at about $0.18, 1 per task, not scored | $3.00 |
| Reserve, untouched | | $2.40 |
| **Total** | | **$49.51** |

- Each phase runs with `--paid`, `--key-file`, its own `--cap-usd` equal to its cap
  above, and `--run-cap-usd 3`. A phase that reaches its cap stops; its unfinished runs
  are `budget_exhausted` and the next phase does not start without the coordinator's
  decision recorded here. The scored run and its `none-lean` control are one invocation
  with `--cap-usd` equal to the sum of their two lines.
- Every other step (selection, validation, request capture, rehearsals of the tooling)
  uses the mock meter or no model at all.
- **A benchmark bug found after the scored run starts voids all scored runs.** Runs are
  never re-done selectively. A redo needs new money from the owner; the reserve does not
  cover it.

## Run time, worst case first

| Phase | Worst case | Likely |
| --- | --- | --- |
| Candidate walk and Docker validation | 27 hours (every candidate up to 6 runs of 300 s plus a 30-minute image build) | 4 to 8 hours |
| Pilot, up to 92 runs | 16 hours (every run hits 20 minutes) | 2.5 hours |
| `/init` files and `olivium` exports | 3 hours | 30 minutes |
| Canary and scored run, 147 runs | 24 hours | 3.5 hours |
| Analysis and report | 3 hours | 1 hour |

Retries of `infra_error` runs (up to 3 attempts) can triple a phase in the worst case.

## Publication

The result is published whatever it is. Numbers reach any other document only from the
final `results.json`. Only references, statistics, traces, charts and screenshots go
under `docs/benchmarks`; no third-party source, patches, issue text or full transcripts.
Mock output is stamped REHEARSAL and stays outside the repository.

## What this cannot show

One model, one agent, Python, JavaScript and TypeScript bug fixes only, with issues that
do not name the file and that the plain agent finds non-trivial but possible. A token
saving under about 15% if noise is high; a solve-rate gain under about 25 to 30 points;
anything about team mode, other models, other agents or other Claude Code versions. The
`/init` setup is one file per task, one sample. The harness's permission mode differs
from the other setups because that is the product as shipped; its refusals are reported
and counted against it.

Known limits of the frozen export, listed next to the result: the Stop hook runs at most
3 changed test files and says nothing about the others (after v3 it should print
`Olivium: N changed test files were not run (limit 3).`); a regression in a test the agent
did not change is not caught at stop; `.olivium/test-pairs.tsv` is written but no hook
reads it.

## Change log

### 2026-11-11, selection tooling, before the walk and before any candidate was looked at

Found while writing `corpus/select_v3.py` and `corpus/v3lib.py`, before the population
snapshot was read or any candidate was evaluated. Neither change uses candidate data.

- **Python test command.** It is `python -m pytest -p no:cacheprovider -q --tb=short
  --continue-on-collection-errors --junitxml=<results>`. Without the flag, a test patch
  that adds tests importing a name the fix introduces stops the whole base run at
  collection (pytest exit 2, no other test run), so no pass-to-pass test can be measured
  and the task is lost for a reason unrelated to its difficulty. With it, the modules that
  fail to collect are reported as errors and every other test runs; at grading time an
  agent's patch that breaks one module's import still lets the rest of the suite report
  regressions. Exit codes other than 0 and 1 still reject the candidate.
- **Untracked install output.** After the recipe installs, a change to a tracked file
  still rejects the candidate. Untracked, not ignored output of the install (for example
  `*.egg-info/`) is added to the image's `.git/info/exclude`, so it can never enter an
  agent's patch, and the image's tree is then clean (`git status --porcelain` empty), as
  v2 required.

### 2026-11-11, recipe versions, before the walk and before any candidate was looked at

A smoke test of every recipe kind ran at $0 on repositories that can never be candidates
(more than 5,000 stars, so outside the population and the F1 range; several are also lane
G development repositories): the default branch head was installed by the recipe in Docker
and the test command run once. `uv`, `pip-group`, `npm` with vitest and with jest,
`npm-nolock` with mocha, and `pnpm` with jest produced JUnit results; two v2 tasks re-validated
with the v3 recipes gave the same fail-to-pass tests as v2. Two pins were wrong for projects
active in late 2026 and are changed:

- **pnpm for a version 9 lock file without `packageManager`: 10.34.9, not 9.15.9.** pnpm 10,
  11 and 12 all write `lockfileVersion: '9.0'`; pnpm 9.15.9 refused two such projects (a
  lock file with a second YAML document, and a `pnpm-workspace.yaml` that holds settings but
  no `packages`), and pnpm 10.34.9 installed both.
- **Poetry 2.5.1, not 2.2.1.** Poetry 2.2.1 refused a current lock file ("pyproject.toml
  changed significantly since poetry.lock was last generated"); 2.5.1, the current release,
  installed it.

pip 25.3, pytest 8.4.2, Yarn 1.22.22 and jest-junit 16.0.0 are unchanged.

`corpus/dev-repos-v3.txt`: lane G's notes for stage 2 did not exist when the walk started
(waited 30 minutes). Its development repositories were read from lane G's development clone
directory instead (10 repositories), and are listed with the 5 repositories of the v2 tasks.

### 2026-11-11, analysis, run order and outcome details aligned with the built tools, before any pilot or outcome data

Found after the walk started (2 tasks in the pool, no v3 run of any agent), while checking
`run.py --protocol 3` and `analyze.py --protocol 3` against this file. The stage 1 contract
(its section E, binding on the runner and the analysis) had fixed these points before this
file was written; this file stated them differently. The analysis that will run is the
one below. No pilot or scored run exists and no outcome has been seen; nothing here
touches selection, the rules T1 to T6 or the verdict bars.

- **Sign-flip statistic: the sum of the per-task values** (log ratios for tokens,
  differences for solve rate), equivalently their mean, for both primaries. It was the
  median of the log ratios for tokens. The estimates and bootstrap intervals are unchanged:
  the median of per-task ratios for tokens, the mean of per-task differences for solve
  rate.
- **Seed `20261108`** for the bootstrap and the run order, the runner's and the analysis's
  default, not `20261111`. The selection seed `olivium-bench-v3-20261111` is unchanged.
- **Run order: seeded blocks.** The (task, repeat) blocks are shuffled and each block
  runs every setup once in a shuffled order, as the runner schedules them; it was "one
  shuffled order of all scored runs". Still interleaved, and a single-setup scored run is
  still refused.
- **`infra_error` runs are left out of the per-task means**, and a primary with no task
  that has valid runs in both setups gives the verdict "insufficient data", checked before
  Failure.
- **Refusal limit.** Every permission denial in an `olivium` run counts towards the
  "more than 1 per 10 `olivium` runs" Failure rule, because refusals of normal work are
  not separated from policy refusals automatically. This is an upper bound and works
  against `olivium`.
- **Behaviour-only ratio** uses Claude Code's turns as the request count, with the
  meter's request rows as a sensitivity figure, as `analyze.py` reports them.
- **False positives, recomputed for the tests as built.** The figure "with both, 1.0% to
  2.1%" came from the master plan's simulation, whose script is not available. A null
  simulation calling `analyze.paired_test` (16 tasks, 2,000 simulated benchmarks per
  scenario, its own seed 4242) gave, for the bootstrap alone / the sign-flip test alone /
  both: per-task log ratios normal with s.d. 0.15, 6.6% / 4.9% / 3.2%; log ratios from a
  t distribution with 3 degrees of freedom scaled by 0.12, 5.1% / 4.2% / 2.2%; solve
  differences from 3 against 3 runs at the same per-task solve chance (uniform), 5.8% /
  1.8% / 1.8%. The Outcomes section now quotes 1.8% to 3.2%.

Lane G's stage 2 notes appeared after the walk started; the development repositories they
list are exactly the 10 in `corpus/dev-repos-v3.txt`, which is unchanged.


### 2026-11-11, walk cost: a repository stops after 3 T5 rejections in a row

Made during the walk, at 5 accepted tasks, after one repository had 9 candidates in a
row rejected at T5, each by a test run over 300 s, with 325 more merged pull requests in
its window. Without a limit the walk would have spent about 6 minutes of Docker time on
every one of them that passed the static rules, for hours, with nothing a rule could
accept. The protocol has no other per-repository limit on Docker time.

- **Rule.** A repository stops after 3 of its candidates in a row are rejected at T5
  (any step: image build, isolation, no results, timeout, no fail-to-pass, no
  pass-to-pass), with no acceptance between them. It is recorded once for the
  repository, under T5 (`repository_t5_streak`), with the count of pull requests not
  considered. It uses only the outcome of the Docker validation, never what a task looks
  like, and applies to every repository from the restart on, fallbacks included.
- **Effect on what was walked before it.** Of the 8 repositories that had reached T5,
  only the one above would have stopped earlier, and it had no accepted task. The pool
  (5 tasks) is unchanged. The repository's records were dropped from `walk.jsonl` when
  the walk resumed (it was unfinished) and are replayed from the cached validation
  results; the walk log as it stood before this entry is kept outside the repository as
  `walk-before-amendment-4.jsonl`.
- `corpus/select_v3.py` and `corpus/v3lib.py` implement it (`T5_STREAK_LIMIT = 3`), and
  `manifest-v3.json` records it under `selection.parameters.t5_streak_limit`.

### 2026-11-11, walk safety on the shared Docker machine; no rule change

At 5 accepted tasks, one candidate's dependency install made the Docker daemon on this
machine stop answering for about 24 minutes (Docker VM load about 60 on 16 CPUs), and
other, unrelated containers on the machine were restarted when it recovered. The walk was
stopped by hand. Three changes in `corpus/v3lib.py` and `corpus/select_v3.py`, none of
which changes what a rule accepts or rejects:

- **Build watchdog.** While an image builds, the daemon is asked for its version every 60
  s. If it does not answer 3 times in a row, the build is stopped and the candidate is
  recorded as `infra` (`DockerUnresponsive`), like a network or `gh` failure: no rule id,
  not accepted, counted in the report. The 1,800 s build limit and the single retry are
  unchanged.
- **Daemon gate.** Before each candidate's Docker work, the walk waits until the daemon
  answers.
- **Optional look-ahead helper** (`select_v3.py ahead`). It runs the walk's own steps on
  repositories further down the order with one test container at a time, so that their
  Docker results are in the shared validation cache when the walk reaches them. It writes
  only its own log and that cache. The walk still processes every repository itself, in
  order, re-applies every rule and alone decides what is accepted and in which order; it
  waits while the helper holds the same repository (a claim file per repository). It ran
  for 35 minutes before the incident above and was then stopped; none of its results
  reached the pool.

### 2026-11-11, generator freeze (coordinator, integration point 2); no rule change

Freeze order step 3, written by the coordinator before any paid pilot run and before any
`olivium` export was built for a candidate. Nothing in selection, the setups, the
outcomes, the verdict bars or the spending changes.

- **Commit.** None: worker tasks may not commit. HEAD is `628676e`, and the generator
  files carry uncommitted changes (40 status entries under `lib/`, `priv/`, `bin/` and
  `mix.lock`), so the generator is frozen by content digest. Any later commit must hold
  exactly these bytes.
- **Digest rule.** For each path: the SHA-256 of the lines `<sha256>  <path>` (one per
  regular file that git tracks or would track, `git ls-files --cached --others
  --exclude-standard`, sorted bytewise, each line ending in a newline).
- **Digests.** `lib` (234 files)
  `a91d88c538a379981af526ac5ba77652558b06e6d5ea620c477b147d42eb9c90`; `priv/blueprints`
  (4 files) `84810f842c257dcf9bf69fa59f06f59d78a92ca8a44c2e96ab22905baa58f10d`; `config`
  (5 files) `c87c3a27ee236ce43557abbbb87422ba49faf8355788833ba7869efb465d671a`;
  `bin/harnessforge` `3d1975ac8b286aea6e69dca86b66e140db9e58055548b99793353157d7aa8b6c`;
  `mix.lock` `de55062033598c01d2d38ad5df085e7cd731fad6547b1e89a3f3ea025d40de93`. All of
  `lib`, `priv`, `bin` and `mix.lock` together (394 files):
  `bca293410b53231ed1a904292d47475fadca9bbb02563636df28c9bca6a3c4d3`.
- **Versions.** Template `v1alpha2.3`, compiler `0.2.0`, Claude Code mapping
  `claude-code-docs-v3`, blueprints base 3, elixir 3, node 4, python 4; Claude Code
  2.1.311.
- **What the frozen generator exports by default for a solo export:** the `lean` context
  profile; a SessionStart environment check; a Stop hook that formats and lints the
  changed files and runs only the changed test files (at most 3, 60 s), not their history
  pairs; no locator card.
- The full record (`freeze.json`, `freeze-files.sha256`) is kept in the program's work
  directory outside the repository. Lane B's $0 mock pilot on 2 pool tasks ran in pilot
  mode, no-harness only, and built no `olivium` export.

### 2026-11-11, integration 2 repair round (review 2); before any pilot, `/init` or scored data

Written by the coordinator's repair round after the second independent review, before any
pilot run, `/init` file, `olivium` export of a candidate or paid v3 run, and with no v3
outcome of any agent seen. The generator is unchanged: the freeze above holds. The
decisions in this entry were adopted by the coordinator under the owner's general
go-ahead; they are not owner signatures.

- **T5, gold patch graded (review M1).** The real fix of
  `coder-vscode-coder-1160` changes `vitest.config.mts`, which the grader restores as test
  configuration, so under grading the real fix failed 4 of 4 fail-to-pass tests and broke
  37 pass-to-pass tests: no setup could solve it. T5 now ends with one gold grading run
  (Docker validation, above). `select_v3.py gold-check` graded the real fix of every task
  accepted so far; the walk applies the step itself to every candidate from now on,
  and to any cached validation that predates it. Results on the 12 tasks accepted before
  this entry: 11 graded solved, every fail-to-pass test passing and no pass-to-pass test
  regressing, nothing restored, test command 35 to 289 s; `coder-vscode-coder-1160` not
  solved (fail-to-pass 0 of 4, 37 pass-to-pass regressions, `vitest.config.mts`
  restored), as the review found.
  `coder-vscode-coder-1160` is rejected at T5 (`gold_not_gradeable`). Because a T5
  rejection lets the walk go on to that repository's next pull request, the walk log was
  cut at the first record of `coder/vscode-coder` (`select_v3.py rewind`, record
  `phase: rewind`; the full log is kept outside the repository as
  `walk-before-amendment-6.jsonl`: 23,326 records, of which the last 5,333 were dropped,
  covering 184 repositories, 183 of them finished, and 8 accepted tasks) and the walk
  replays that repository and every later one from the API and validation caches, in the
  same order. Nothing before that repository changes. The pool order stays the walk order.
  The walk process still running the code from before this entry was ended at 15:05:58Z
  inside an unfinished repository (its candidate was in its image build); it had accepted
  `voxelum-x-minecraft-launcher-1835` at 15:04Z without gold grading. The replay grades
  that task's real fix from its cached validation, as for any cached validation.
- **Grading time limit (review M5).** The real fix of
  `dynamics365ninja-d365fo-mcp-server-1180` ran its suite in 220 to 240 s at T5, 198 to
  309.5 s in the review's re-run under load, and 289 s in the gold grading above, with
  the walk running beside it. At grade.sh's 300 s a run would then be scored unsolved by
  host load alone. Protocol 3 now grades the test command with a 600 s limit, twice T5's
  limit, in every setup (`GRADE_TEST_TIMEOUT_V3_S`; protocols 1 and 2 keep 300 s). The
  review proposed scoring a kill at the limit as `infra_error` instead. That was not
  adopted: the runner repeats an `infra_error` run as a new paid session, so an agent whose
  patch makes the suite hang would get further attempts and then drop out of the means,
  instead of being scored. With twice the limit a kill is the patch's doing and is scored
  as not solved, as in v2. Grading wall times and kills are reported per setup. A paid
  phase never starts beside selection containers (Environment and run procedure).
- **Analysis input checks (review M2).** `analyze.py --protocol 3` gave the verdict
  "dramatic", unstamped, on Gate 1's paid protocol 2 data. It now needs `--manifest` (the
  frozen manifest) and `--manifest-checksum` (the checksum recorded here at the manifest
  freeze), and gives a verdict only when `OUT/protocol.json` is this protocol's scored
  record (`mode scored`, `pilot false`), every row has `protocol 3` and `pilot false`, the
  manifest's checksum equals both the given one and the one in `OUT/protocol.json`, and
  every task of the OUT is in the manifest. Otherwise the output is stamped REHEARSAL and
  carries no verdict (the rule table it would meet is kept, labelled, for checks of the
  machinery).
- **Attribution (review M3).** On Gate 1, `olivium` against `none` was 0.363 and `none-lean`
  against `none` 0.317, while the behaviour-only ratio gave 0.858: the arithmetic credits
  the trim's own effect on behaviour to the text and hooks. `none-lean` therefore runs as an
  unscored control: one run per scored task, in the scored run's blocks of repeat 1, in the
  seeded position the block shuffle gives it (`lib/protocol3.py`, `SECONDARY_REPEATS`), and
  the attribution rule above decides the wording. If the scored run has no `none-lean`
  runs, nothing is credited to the text and hooks and the Gate 1 figures are printed next
  to the headline. Spending: $3.00 moves from the reserve to a `none-lean` line; the total
  stays $49.51 of the $60 the owner approved. If the owner refuses that line before the
  scored run, the wording rule alone stays.
- **Pre-registered secondaries built now (review M4)**, so that pilot data cannot shape
  them. Definitions as built:
  - tokens in the first request: prompt tokens (input, cache write, cache read) of the
    run's first request on its main model;
  - tokens before the first edit of a fix file: the total tokens of every request up to
    and including the one whose answer first edited a file the real fix changed (shell
    edits count, as the trace finds them). The edit's assistant message (k-th, subagents
    included) is mapped to the k-th request, so the value is "not available" for a run
    whose request rows (all, or those on the main model) and transcript messages are not
    equally many. Runs that never edited one are counted, not averaged. On Gate 1, 40 of 40
    runs mapped;
  - largest context: the largest prompt of any main-model request of the run;
  - warm starts: runs whose first main-model request read from the prompt cache;
  - per setup, olivium against none per task for the three context outcomes (ratio of
    means, both tests, never used for the verdict);
  - subgroups by language and by `toolchain_nondefault`: both primaries within each group;
  - the T4 rejection share and the full-suite census, from `manifest-v3.json`
    (`selection.t4_share`, `selection.census`, the tasks' `full_suite_green_at_base`);
  - wrong commands (Bash results with "command not found", "No module named", an unknown
    option or unrecognised arguments, or a test run that collected 0 tests), the first test
    command's result, regressions, new lint findings, Stop blocks, hook events, changed
    test files, and the changelog touched where the real fix touched one, per setup.
  `analyze.py` sha256 `ce31d1564c0aa31d736c2d85109f6b0a7a683bce9ddbad6c7c5ba89dc1ecdcd8`,
  `lib/protocol3.py` `346e11af6e8cddbe1b5714bf2ac371f781a62c326e02e620f1b98c17ecf7b21b`,
  `grade/grade.sh` `ee0fb1bce0afce27bff298196c5cfb31716405a9909ad738dab46a4e56d88ef6`,
  `grade/grader.py` `5f02bd701e87911429317de18fdbb1742c6330e047108769fda8d13c1e43a613`.
  Pilot data may not change them (Freeze order, step 5).
- **Walk restarts in the walk log (review m3).** Every restart writes a `phase: resume`
  record with the SHA-256 of this file, `select_v3.py`, `v3lib.py`, `grade.sh` and
  `grader.py`. Earlier restarts are only in `select.log`.
- **An entry missing since 06:34Z (review m3): exact early T5 rejection.** Since the walk
  restart at 06:34Z, T5 runs one base and one fix run first and rejects at once when that
  pair leaves no possible fail-to-pass test (none fails or is absent at base and passes
  with the fix) or no possible pass-to-pass test (none passes in both). A fail-to-pass test
  must fail or be absent in every base run and pass in every fix run, and a pass-to-pass
  test must pass in all six, so four more runs cannot create one: the accept or reject
  decision is identical. Only the recorded step can differ (a later run might have timed
  out first), and both count the same towards the 3-in-a-row repository stop. It skips
  wasted runs only.
- **Manifest wall times (review m1).** Each task records `t5_max_test_seconds` (the
  longest of its 6 T5 runs) and `gold_grade_test_seconds`. No rule uses them.
- **Known limits and the canary check (review m4, m5):** listed under "What this cannot
  show" and in the canary rule above. The generator stays frozen.

### 2026-11-11, owner redirect: the integration-2 generator freeze is withdrawn; before any pilot, `/init` or candidate export

Written by the coordinator at v4 integration, before any pilot run, `/init` file, `olivium`
export of a candidate or paid v3 run, and with no v3 outcome of any agent seen. The v4 work
used no v3 material: it used the development repositories of `corpus/dev-repos-v3.txt`,
the 8 v2 development tasks and its own development tasks only. This entry is a
coordinator decision under the owner's go-ahead of 2026-11-11; it is not an owner
signature.

- **What happened.** On 2026-11-11 the owner redirected the program: the generator is to
  use AI to learn from each repository's history (tools, guardrails, a local index,
  pitfalls from past fixes) to cut tokens and raise accuracy. It is to be built first and
  then benchmarked once on held-out tasks.
- **What is withdrawn.** The freeze recorded in "2026-11-11, generator freeze
  (coordinator, integration point 2)", digest
  `bca293410b53231ed1a904292d47475fadca9bbb02563636df28c9bca6a3c4d3` over 394 files. No
  scored, pilot or `/init` run used it, and no `olivium` export of a candidate was built
  from it. The tree no longer holds those bytes: the template is now `v1alpha2.4` and the
  generator has the `lean-ai` profile and the `learn` command.
- **What is not changed.**
  - The pool, the walk, the task rules, grading (600 s test limit), the outcomes, the
    verdict bars and the isolation rules.
  - Freeze order steps 2 and 5: no development lane reads candidate lists, `corpus/*v3*`
    (except `dev-repos-v3.txt`) or this file, and pilot data may not change the export,
    the rules or the analysis.
- **What must happen before the pilot.** A new freeze entry (freeze order step 3) with:
  - the digests of `lib`, `priv/blueprints`, `priv/schemas`, `priv/learner`, `config`,
    `bin/harnessforge` and `mix.lock`;
  - the template version;
  - the learner: prompt sha256, model, cost and turn caps, Claude Code version, and the
    image ids of the learner, meter and verification images.

  In the same entry, before any pilot data, the setup table is amended:
  - **The scored harness setup becomes `olivium-ai`.** It is the `lean-ai` export plus a
    learned bundle made once per task base commit, from that commit and its ancestors only
    (the v2 generator input rules), never from the task's issue or pull request.
  - **The role of `none-lean` is decided:** scored comparator or unscored control.
  - **The spending table gains a learning line.** It is the cost per task base, recorded
    per repository and reported with the results.
- **The request-shape capture (freeze order step 4) is re-run** on the new exports after
  the new freeze.
- **The new SHA-256 of this file** goes into the hash chain kept in the v3 work
  directory; the coordinator step that may write there appends it.

### 2026-11-12, the v5 freeze replaces the withdrawn one; `olivium` is the lean-x export; money rule; before any pilot, `/init`, candidate export or paid v3 run

Written by the v3 pilot step for the coordinator, before any pilot run, `/init` file, `olivium` export of a
candidate or paid v3 run, and with no v3 outcome of any agent seen. On 2026-11-12 the owner chose "Fair benchmark
now" with the v5 export, within the $60 already approved. The decisions below were adopted by the coordinator
under the owner's general go-ahead; they are not owner signatures.

- **Freeze (freeze order step 3), replacing the freeze withdrawn in the entry above.** The record is the
  program's v5 freeze file, kept outside the repository (`freeze-v5.json`, sha256
  `26431eca0befb8958764db1fd60425e69fe8ddc1c451d6fa00af35e47e885009`, written 2026-11-12T09:06:37Z after its
  integration gates passed).
  - Commit: none. HEAD is `628676e` and the generator files carry 45 uncommitted status entries under `lib/`,
    `priv/`, `config/`, `bin/` and `mix.lock`, so the generator is frozen by content digest. Any later commit must
    hold exactly these bytes.
  - Digest rule: the integration-2 rule (sha256 over sorted `<sha256>  <path>` lines of every regular file git
    tracks or would track), over `lib`, `priv/blueprints`, `priv/schemas`, `priv/learner`, `config`,
    `bin/harnessforge` and `mix.lock`.
  - All together (268 files): `ef94811fdc465b582beaaa43811c9272398d6657fe7d9d7a132a71c0b945c42f`. Parts: `lib`
    (247 files) `2e4b6ee8a404509720b8e823d3b3a189588acfeb3243423a79d7d12dbb97e6ed`; `priv/blueprints` (4)
    `e71a312db8accfb4ac4b04db8876305b3981fa5db99fcb3fb3b5439af2fd129c`; `priv/schemas` (6)
    `056bbc0f8003117a7fdc0d4dfc8e5f63b6f7b6ae3e487a1980a8337f431c830a`; `priv/learner` (4)
    `96d143565efafa03e09e2b7568ca190144593a64f2b3724c8419014c634155ac`; `config` (5)
    `c87c3a27ee236ce43557abbbb87422ba49faf8355788833ba7869efb465d671a`; `bin/harnessforge`
    `3d1975ac8b286aea6e69dca86b66e140db9e58055548b99793353157d7aa8b6c`; `mix.lock`
    `de55062033598c01d2d38ad5df085e7cd731fad6547b1e89a3f3ea025d40de93`. Recomputed by this step before this entry:
    identical.
  - Template `v1alpha2.4`; Claude Code 2.1.311; model `claude-sonnet-5-5`. The learner image and prompt are
    recorded in the freeze file but not used: the lean-x export has no learned part.
  - Bench files at this entry, as the v5 freeze and the integration 2 repair round recorded them: `run.py`
    `4233af12dc98421ceb9d4a984ba9998bf2268f9065aae8a1312e695cd930db5a`, `lib/protocol3.py`
    `346e11af6e8cddbe1b5714bf2ac371f781a62c326e02e620f1b98c17ecf7b21b`, `lib/common.py`
    `665673c9c862be6e7b8782b0a89e6b63280616284726171193d245fed3ed0524`, `arms/olivium_x.py`
    `4bb416ee6aadd1278ffefaf2ef4e863839bd31758602e6cbc1e5fde3ed219f13`, `arms/none_lean.py`
    `12fb529db831bd0b82bc0a41ebed5125ae70358652cecf736a8edc1ac01eac28`, `analyze.py`
    `ce31d1564c0aa31d736c2d85109f6b0a7a683bce9ddbad6c7c5ba89dc1ecdcd8`, `grade/grade.sh`
    `ee0fb1bce0afce27bff298196c5cfb31716405a9909ad738dab46a4e56d88ef6`, `grade/grader.py`
    `5f02bd701e87911429317de18fdbb1742c6330e047108769fda8d13c1e43a613`; meter sources `meter/Dockerfile`
    `761e67761890623fc05d2023c957fcb7ac8a5689bfdc0c43fd714a960b770f80`, `meter/meter.py`
    `132128e497d8864c589f625cd4f15ec17f322a4d877641ffc31255d0c4449314`, `meter/prices.json`
    `822e4a75d811e0abe1c1d68ab7e101ab763a6d126b5b574ccc9121eb9577dab2`.
- **The `olivium` setup is the frozen lean-x export, run as the v5 `olivium-x` arm.** The export is
  `bin/harnessforge generate PATH --runtime claude_code --context lean-x --export DIR --json` under the generator
  input rules above. The setup is the task's `none-lean` settings byte for byte plus the export's `hooks`
  (PreToolUse only: the guard, then the Bash output shaper with its test timeouts) and its `outputStyle` (a
  four-line style), passed with `--settings`. Exactly three exported files are installed:
  `.claude/hooks/olivium-guard.sh`, `.claude/hooks/olivium-shape.sh` and `.claude/output-styles/olivium.md`. The
  permission mode is `none-lean`'s (`bypassPermissions`). There is no `CLAUDE.md`, no SessionStart or Stop hook and
  no learned bundle.
  - This replaces the setup table's `olivium` row (the `lean` export, its own settings, `default` mode). It also
    replaces the `olivium-ai` setup and the learning line that the entry above planned.
  - Refusals: in this mode only the guard hook refuses. Its denials are in the trial row's
    `permission_denials` (v5 development test: the 2 guard denials are the only non-zero rows). So they count
    towards the Failure rule's refusal limit, as every permission denial does.
  - `none-lean` stays the unscored control of the integration 2 repair round. Against it, `olivium` now differs
    only by the two hooks and the style.
  - Runner: `run.py --protocol 3` builds the `lean` export for `olivium` today; `olivium-x` is a protocol 2 arm
    only. Making protocol 3's `olivium` this arm is a runner change for the step after the pilot and before any
    `olivium` export of a candidate. That change may do nothing else, does not depend on pilot data, and its file
    hashes go into a change-log entry before the canary. The request-shape capture (freeze order step 4) runs on
    these exports.
- **Money rule, a hard stop for the program.** Spent before this entry: $18.37 of the $60 the owner approved
  (v1 and v2 $10.49, Gate 1 $1.76, v4 learning $0.80, v4 development rehearsal $3.14, v5 development test $2.18).
  Left: $41.63. The spending table's remaining lines sum to $44.51 (pilot $5.00 and $8.00, `/init` $2.00, canary
  $0.60, scored $25.91, `none-lean` $3.00). The $2.40 reserve no longer exists.
  - Total spend may never pass $60.00.
  - Before each paid phase: money left is $60.00 minus all spend so far. The phase's `--cap-usd` is the smaller of
    its line and the money left.
  - If the phase's expected cost (measured dollars per run times its runs) is more than the money left, the phase
    does not start and the owner is asked.
- **Background only, never a bar.** The v5 development test (7 development tasks, not v3 tasks, 3 repeats per
  arm): `olivium-x` used 0.801 times the tokens of `none-lean`, and each arm solved 3 of 21 runs. Its own decision
  against its 0.75 bar was `fail`. These are development data: they set no bar and no expectation for v3.
- **Pool manifest before the pilot.** `corpus/manifest-v3.json` is as the walk wrote it at its end
  (2026-11-11T20:15:35Z), and it is not rewritten:
  - `selection.status` `pool_before_pilot_stopped_for_time`. This is the walk tooling's form of
    `pool_before_pilot` when the walk stops for time, as the Target rule allows;
  - 24 tasks from 14 repositories, in pool order;
  - checksum (the manifest's own, `lib/common.py` rule)
    `6eaae9d34fa7079681647faf28058a92e25234c1a9bfb969614f8dc210f11bff`; file sha256
    `6558c4bfe2d0cc53f666d53a4fc5cd3321524127a8cdf24ea9bd9d1a6ef32b71`.
  - A byte copy is kept with the pilot output outside the repository, and both pilot stages read that copy.
- **How the difficulty filter is applied, fixed before any pilot data.**
  - Turns are the trial row's `turns` (Claude Code's turn count; the field whose v2 `none` maximum was 8). Solved is
    as in grading.
  - Stage 1 keeps pool order. It runs one runner invocation per consecutive pair of pool tasks, all into one OUT.
    Within an invocation the runner orders the runs in its seeded blocks; the pairs keep pool order while two runs
    go at a time. The $5.00 cap counts everything in that OUT.
  - Stage 2 runs into its own fresh OUT with the $8.00 cap: one invocation per remaining task, in pool order, with
    `--repeats 2`. Its runs r1 and r2 are the task's runs 2 and 3.
  - A task's three runs are its stage 1 run and its two stage 2 runs. "Median under 10 turns" is the median of
    those three.
  - `infra_error`: the same invocation is run again, up to 3 attempts (the runner's rule). A task left with no
    valid run at either stage is dropped as not measured, and the report says so.
  - A run stopped at the $3 run cap counts as not solved, as in scoring. If a phase cap stops a stage, the next stage
    does not start without a coordinator decision recorded here.
  - Dollars per run for the size rule: the meter cost of the stage 1 runs that are not `infra_error`, divided by
    their number. Spend on `infra_error` attempts is reported separately.
  - The frozen manifest is the first N kept tasks in pool order. It is written to `corpus/manifest-v3.json` in the
    same schema, with `selection.status` `frozen`, the pool manifest's checksum, and the per-task pilot counts. Its
    checksum goes into a change-log entry before any scored run.
- **Nothing else changes:** the `none` and `generic` setups, the pool, the task rules, grading (600 s limit), the
  outcomes, the verdict table, the bars, the tests, the spending lines (under the money rule above), and freeze
  order steps 2 and 5.

### 2026-11-12, size rule edge cases, fixed before any pilot data

Written by the v3 pilot step, before any pilot run (no paid v3 call yet), as a coordinator decision under the owner's
general go-ahead (not an owner signature). It only states how the size rule reads at its edges.

- Dollars per run is compared unrounded: more than $0.18 gives 12 tasks; under $0.12 gives 24 tasks when at least
  24 are kept, and otherwise 16; anything from $0.12 to $0.18 gives 16.
- N is then the smaller of that size and the number of kept tasks, taken in pool order. With 12 to 15 kept tasks
  and a size of 16 or 24, all kept tasks are scored. Below 12 kept tasks nothing is frozen and the owner is asked.
- The scored run's runs and its cap follow N (N x 3 setups x 3 repeats, plus N `none-lean` runs), under the money
  rule of the entry above.

### 2026-11-12, pilot result: 2 tasks kept, below the floor of 12; nothing frozen; the owner is asked

Written by the v3 pilot step after both pilot stages, before any `/init`, candidate export or scored run. It records
an outcome and the stop the protocol requires. It changes no rule, setup or analysis.

- **Stage 1:** 24 `none` runs, one per pool task, all `completed`, 0 `infra_error`; 3 solved. Meter spend $2.887188
  (234 live requests), so dollars per run are $0.1203. That gives the size rule 16 tasks.
  - Dropped as trivial (solved in 8 turns or fewer): 1 task. Sent to stage 2: 23 tasks.
- **Stage 2:** 46 `none` runs (2 per task), all `completed`, 0 `infra_error`; 2 solved. Meter spend $6.162877 (503
  live requests).
  - Kept: 2 tasks, each solved 2 of 3 (`smithy-lang-smithy-typescript-2271`, median 11 turns;
    `certinia-debug-log-analyzer-1245`, median 18 turns).
  - Dropped as never solved (0 of 3): 21 tasks. Dropped as 3 of 3 under 10 turns: none.
- **Floor.** 2 kept tasks is below the floor of 12. As the protocol requires, the filter stops here: no manifest
  is frozen, `corpus/manifest-v3.json` stays the pool manifest (checksum
  `6eaae9d34fa7079681647faf28058a92e25234c1a9bfb969614f8dc210f11bff`), and no `/init`, canary or scored run starts.
  The owner decides what follows.
- **Pilot data.** The pilot data may not change the export, the rules or the analysis. Any change of rules that
  the owner makes now is made after seeing pilot data, and the report must say so.
- **Spend.** The pilot spent $9.050065 in all. Program spend is now $27.420065 of $60.00, and $32.579935 is left.
  This step's report and evidence are kept in the program's work directory, outside the repository.
