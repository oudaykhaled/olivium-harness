# Value benchmark protocol, version 2

Written 2026-11-09, after the pilot of the same day and before any task selection,
rehearsal or scored run for this version. This file is the pre-registration for the
second measurement. `PROTOCOL.md` remains the record of the pilot and is not changed
by this version. Any change to this file after its first SHA-256 was recorded goes in
the change log at the end, with the reason, and the new SHA-256 is added to
`PROTOCOL-v2.sha256`. Nothing here is chosen from outcome data of this version; the
pilot's outcome is the reason this version exists and is stated as such.

## Why a second measurement

The pilot (`docs/benchmarks/value-2026-11-09/report.md`) found no accuracy gain and
no clear saving for the old harness against no file: its rules were project
descriptions, its pipeline read only Markdown, and its exported permissions could not
run unattended. A new, model-free generator now writes the harness from a repository's
own code and history. This version measures whether that new harness helps, on real
repositories, and reports the result whatever it is.

## Question

Does a harness produced by the new generator make a coding agent cheaper, better
informed or more accurate on real tasks in real repositories, compared with no
harness and with a free generic instruction file? Same three questions and same
metrics as the pilot: fewer tokens, better context, more accurate.

## Arms

| Arm | What the agent gets |
| --- | --- |
| `none` | The repository at the commit before the fix. No instruction files. |
| `generic` | Same, plus a fresh `CLAUDE.md` written by Claude Code's own `/init` at that commit, as in the pilot. |
| `olivium` | Same, plus the output of `bin/harnessforge generate PATH --runtime claude_code --export DIR --json`, unmodified: `CLAUDE.md`, `.claude/settings.json`, `.claude/hooks/olivium-before-stop.sh`, `.claude/hooks/olivium-format.sh` when generated, and `.olivium/*`. |

Every arm starts from the same snapshot. Any `CLAUDE.md`, `AGENTS.md`, `.claude/`,
`.cursor/` or `.github/copilot-instructions.md` already in the repository is removed
from every arm first, at any depth, exactly as in the pilot (`arms/entry.sh`).

**How each arm runs.** `none` and `generic` keep the pilot's identical benchmark
settings file, `arms/benchmark-settings.json`, with `--permission-mode
bypassPermissions`. `olivium` runs the harness exactly as exported: its own
`CLAUDE.md`, its own hooks, and its own `.claude/settings.json` passed to Claude Code
with `--settings`, with `--permission-mode default` and no bypass. The bytes passed
with `--settings` must equal the exported bytes; the runner records both hashes and
refuses the trial otherwise. This is the real product, so a too-narrow allow list or
a hook that fails counts against the `olivium` arm. A tool denied by the harness's
rules ends as whatever the model does next; nothing is adapted to help it.

`UV_NO_SYNC=1` is set for every agent session in every arm, `/init` included, because
plain `uv run` otherwise needs the network in the offline containers.

## Generator input

The generator runs on the repository at `base_sha` only:

- A fresh local git repository is built for each task from the existing bare clone by
  fetching only `base_sha` (no tags, no remote). It holds `base_sha` and its ancestors
  and nothing else. Reflogs are expired and unreachable objects pruned.
- Instruction files are removed from the working tree and the index with the same
  name rule as `arms/entry.sh`, without a commit, so `HEAD` stays `base_sha`.
- The generator runs on the host through `bin/harnessforge` from a snapshot of this
  repository's application, with a new `HARNESSFORGE_WORKSPACE` for each task. It only
  parses repository files and git history; it runs nothing from the repository.
- The workspace access token is deleted immediately after the generator exits. It is
  never logged or printed.
- A check verifies, before the arm is accepted: `HEAD` equals `base_sha`; the fix
  commit and every commit of the pull request are absent from the truncated
  repository; the repository has only `refs/heads/main`, no tags, no remote; no
  exported file contains the fix commit SHA, any pull request commit SHA (full or
  12-character prefix) or the pull request number in a `#NNNN` form. A failure stops
  the benchmark; it is not worked around.

Setup cost for `olivium` is $0, because no model is called, and is reported as $0.
If the generator fails on any task, that is a product problem: it is reported and the
benchmark stops before any paid run; it is not patched and the arm is not substituted.

## Tasks

**Pilot tasks, fixed:** `pallets-click-3858`, `pallets-flask-6096`,
`python-attrs-attrs-1593`, `expressjs-express-7366`, `pallets-click-3769`, from
`corpus/manifest.json` (checksum `aa9b6795b6fa1e6cd6e4367d723f3051d8f647cb12fde12e89a93db419c50e43`),
copied unchanged into `corpus/manifest-v2.json`.

**Held-out tasks.** The analyzer and rule filters were tuned while looking at
`pallets/click`, `pallets/flask`, `python-attrs/attrs` and `expressjs/express`, at the
same base commits the pilot used. Five more tasks are selected by the existing rule
in `corpus/corpus_lib.py` (static rule, 3 of 3 base-fail and 3 of 3 fix-pass in
Docker, frozen manifest, recorded rejections) from repositories other than those
four. These five are the held-out tasks. At least 3 are required; with fewer than 3
the benchmark does not proceed. The rule parameters for the additional tasks only:
`max_tasks` 10 in total (5 new), `max_per_repository` 3.

Candidate repositories, in order, with the existing round-robin:

1. `pallets/jinja`, `encode/httpx`.
2. Then repositories chosen by rule, not by hand: GitHub repository search, query
   `language:<L> stars:>=1000 archived:false fork:false pushed:>=2026-06-30
   license:<SPDX lower-case>` for each language `L` in Python, JavaScript, TypeScript
   and each licence in `mit`, `apache-2.0`, `bsd-3-clause`, `bsd-2-clause`, first page
   of 100 sorted by stars descending (cached). Merge, drop duplicates, drop the four
   tuned repositories and the two named above, order by stars descending then full
   name. Walk that list and keep a repository only if the install recipe rule below
   applies at its default branch head, until 15 repositories are kept. Every dropped
   repository is recorded in `rejected-v2.jsonl` with its reason.

Install recipe rule for extra repositories: the only generic recipe available is the
`uv` recipe the pilot used, because grading requires JUnit output and offline
installs. A repository qualifies if its language is Python, it has a root `uv.lock`
and its `pyproject.toml` declares a `[dependency-groups]` table with a `tests` group,
and a name for the project (the dist name; import name from it with `-` as `_`).
Other repositories are rejected with `no_generic_install_recipe` (this includes every
JavaScript and TypeScript repository outside the fixed start list, because no generic
JUnit test command exists for them). This narrowing is a limit of the benchmark's
install machinery, not of the rule, and the report states it.

The first pass uses `merged_after` 2026-06-30. Only if fewer than 5 tasks are accepted
after every candidate repository has been walked does a second pass widen
`merged_after` to 2026-01-01 over the same repositories and the same rules; if that
happens, it is recorded in the manifest under `selection.relaxations` and in the
report. Nobody picks a task by hand. Rejected candidates are recorded with their
reason.

`corpus/manifest-v2.json` carries `held_out: true` on the additional tasks and
`held_out: false` on the pilot tasks. It is frozen, with a checksum, before any paid
run.

## Environment and run procedure

- Claude Code 2.1.311, model `claude-sonnet-5-5`, every arm. Same agent image,
  same isolation, same meter and same limits as the pilot: 60 turns, 20 minutes, a
  per-run dollar cap of $3, two runs at a time, `--cap-usd 30` total.
- 10 tasks × 3 arms × 3 repeats = 90 scored runs, or the corresponding fewer when
  fewer held-out tasks qualify. Run order is shuffled with seed `20261108`.
- The prompt is the same in every arm: the issue title and body, then
  `Fix this issue in the repository in the current directory.`
- Grading is unchanged: the agent's patch is applied to a clean checkout in a fresh
  `--network none` container, then test files and test configuration are restored and
  the real test patch applied. Patch extraction additionally excludes the top-level
  `.olivium/` directory, so the harness's own files are not counted as the agent's
  work, in the same way that `CLAUDE.md` and `.claude/` are excluded.
- `infra_error` runs may be repeated (up to 3 attempts), as in the pilot. A run that
  fails because of the model or of the harness is never repeated.

## Metrics and analysis

Same metrics and trial record as the pilot (`PROTOCOL.md`). Token and dollar figures
come from the meter. For each task, average the 3 repeats per arm; report
`olivium − none` and `olivium − generic` per task, the median difference across
tasks, and a percentile bootstrap 95% interval across tasks (10,000 resamples, seed
`20261108`). A difference whose interval includes zero is reported as one the data
cannot tell from no effect, and no benefit is described that the data does not show.

Reporting:

- Results for all tasks and, **separately, for the held-out tasks only**. The report
  must state that the analyzer and rule filters were tuned on the same repositories,
  at the same base commits, as the 5 pilot tasks, so only the held-out table is free
  of that overlap.
- A before and after comparison with the pilot's old harness on the same 5 pilot
  tasks, from `docs/benchmarks/value-2026-11-09/results.json`, labelled as different
  runs with different harnesses, different times and separate samples of the model. It
  says what changed; it does not show that the harness caused any change.
- `olivium` setup cost $0; `generic` setup cost as metered; generator diagnostics and
  the count of permission denials per run from Claude Code's own `result` event.

## Spending and restarts

- A paid run needs `--paid`, `--key-file`, `--cap-usd 30`, `--run-cap-usd 3`. With
  $3.48 already spent, this keeps the whole program under the $60 the owner was told
  about. Requests are refused once the cap is reached and the affected runs are
  reported as `budget_exhausted`.
- Every other phase, including rehearsal and selection, uses mock mode or no model
  calls at all.
- **If a benchmark bug is found after the scored run begins, all scored runs are
  discarded and repeated, within the cap, with an entry in the change log.** Runs are
  never re-done selectively. A bug found before the scored run begins is fixed and
  logged here.

## Publication

The result is published whatever it is, including no effect or a negative one.
Numbers reach any other document only from the final `results.json`. Only
references, statistics, traces, charts and screenshots go under `docs/benchmarks`;
no third-party source, patches, issue text or full transcripts. Mock output is
stamped REHEARSAL and stays in the scratch directory.

## What this cannot show

Up to ten tasks, one model, one agent, two languages, bug fixes only. The pilot
tasks overlap with the repositories the analyzer was tuned on. Held-out tasks are
few, are Python only unless a named repository provides otherwise, and may be rejected
for install reasons that are unrelated to harness quality. An interval across up to
ten tasks can show a direction and can show a problem; it cannot prove a general
effect, and the report says so next to the numbers.

## Change log

### 2026-11-09, implementation, before any scored run

These came out of implementing and rehearsing this protocol in mock mode. None is
chosen from outcome data of this version, none changes what is measured.

- **Generator input directory name.** The working copy the generator analyzes is named after the repository (for example `click`, `express`), not `repo`, because the generator derives the project name from it and a real clone would be named after the project. The name is the only effect; the content rules above stand.
- **Hook lifecycle events are recorded.** The agent launch script passes `--include-hook-events` to Claude Code when `BENCH_INCLUDE_HOOK_EVENTS=1`, which `run.py` sets for every agent session under this protocol, in every arm. It adds `system`/`hook_started`/`hook_response` events to the transcript and changes nothing the agent or the model sees. Agent images are rebuilt when their launch script changes (`run.py`, `build_agent_images`); the flag is off, and the script otherwise identical, for the pilot.
- **The harness check runs before the agent starts.** `arms/entry.sh` records the SHA-256 of every harness file and of the `--settings` file in `/work/out`. The runner compares them with the arm's files and the exported settings, and scores the trial `infra_error` on any mismatch. For `none` the expected set is empty; for `generic` it is `CLAUDE.md`. This is the check required under "Generator input" and "Arms".
- **Selection is lazy per repository.** `select_heldout.py` evaluates a repository's merged pull requests as the round-robin reaches them, newest first, in the same order as the pilot's up-front walk; candidates never reached are not rejected and are listed in `validation-v2.json`.
- **Selection restart with early cancel.** The first selection run was stopped and resumed once, before any manifest was written, because each `pallets-eco/flask-admin` candidate spends about 16 minutes timing out across 6 test runs. `corpus_lib.validate_candidate` now cancels the not-yet-started runs of a candidate as soon as one run has rejected it. A rejected candidate is rejected either way, so the result of validation does not change; `--resume` reused the recorded validations, so the candidates and order are unchanged.
- **Mock scenarios added** (`permcheck`, `hookfail`, dry-run only): they let a rehearsal prove that the exported allow and deny rules are applied in default mode and that the Stop and PostToolUse hooks fire. They are never used with `--paid`.
- **Observed, not changed.** Claude Code prints `Ignoring 18 permissions.allow entries from .claude/settings.json: this workspace has not been trusted` for the copy of the settings inside the repository. The same rules are applied from the `--settings` file, which is why this protocol passes them that way (rehearsal: an allowed `mkdir` ran and a denied `rm` was refused in default mode). Generated harness files are uncommitted in the agent's repository, so the Stop hook's `git status` is never clean and it runs the project's checks at the first stop even when the agent changed nothing; that is how the harness behaves as exported, and it counts against it in time, not tokens, because hook output only reaches the model when a check fails.

### 2026-11-09, held-out selection outcome (before any scored run)

- **Result.** `corpus/manifest-v2.json`, frozen 2026-11-09T21:31:48Z, checksum `c8bde114ef966b873cc0a13cb15e153474e5e96c3643f3ec9f3034e6104061d3`: the 5 pilot tasks unchanged plus 3 held-out tasks, `pallets-werkzeug-3298`, `pallets-werkzeug-3273` and `pallets-werkzeug-3266`, each validated 3 of 3 base-fail and 3 of 3 fix-pass in Docker. This meets the minimum of 3, not the target of 5.
- **How.** Candidate repositories by rule: `pallets/jinja`, `encode/httpx`, then the repository search kept only 4 of 871 distinct repositories under the generic recipe rule (`fastapi/fastapi`, `pallets/werkzeug`, `pallets-eco/flask-admin`, `bennylope/django-organizations`); 863 were rejected at that stage (275 no root `uv.lock`, 82 no `tests` group, 506 JavaScript or TypeScript with no generic JUnit command). The first pass (merged after 2026-06-30) accepted the 3 werkzeug tasks and reached the per-repository cap of 3. `pallets/jinja` had no pull request merged after 2026-01-01 and `encode/httpx` had none with a closing issue reference. Every `pallets-eco/flask-admin` candidate that reached validation (5) was rejected as `test_timeout` (its suite exceeds 300 s). As pre-registered, the second pass widened `merged_after` to 2026-01-01 for the held-out tasks; it added no task. The widening is recorded in the manifest under `selection.relaxations` though it changed nothing. 1,877 rejections are in `corpus/rejected-v2.jsonl`.
- **Run size that follows.** 8 tasks × 3 arms × 3 repeats = 72 scored runs.
- **Limit this creates, stated now.** All held-out tasks come from one repository, `pallets/werkzeug`, which the analyzer was not tuned on but which shares the organisation, layout and tooling conventions (`CHANGES.rst`, `uv`, `ruff`, `pytest`) of `pallets/click` and `pallets/flask`, which it was tuned on. The held-out table is therefore free of the base-commit overlap but not of a same-family overlap, and the report must say so.

### 2026-11-09, mock rehearsal (no model contacted, $0)

- **What ran.** `run.py --dry-run --protocol 2` against the mock meter, 1 repeat, output in the scratch directory only: `gold` on 4 tasks (`pallets-click-3858`, `expressjs-express-7366`, `pallets-werkzeug-3298`, `pallets-werkzeug-3273`, 12 trials), `permcheck` and `hookfail` on 3 tasks (9 trials each), then `gold` on all 8 tasks (24 trials). 54 of 54 trials `completed`; every `gold` trial solved and graded in a fresh `--network none` container; patch lines equal across arms on every task, so the harness's own files never entered a patch.
- **Proofs for the `olivium` arm.** Every `olivium` trial reported `permissionMode` `default` in Claude Code's own init event; the bytes passed with `--settings` had the same SHA-256 as the exported `.claude/settings.json` on the host and inside the container; the harness check found every exported file in the container and nothing else (none and generic: nothing, and `CLAUDE.md`). Under `permcheck`, an allow-listed `mkdir` ran without a prompt, a deny-listed `rm` was refused by rule and an unlisted `curl` was refused as needing approval, and both refusals appear in Claude Code's `permission_denials`. Hook events show `PostToolUse` after edits and `Stop` at the end; under `hookfail` the Stop hook exited 2 once and the retry was allowed. The post-base check passed on all 8 tasks, and the generator's output was byte-identical across 4 separate builds of each task.
- **Seen in rehearsal, kept as product behaviour.** On the two werkzeug tasks in `gold`, the Stop hook ran `uv run pytest` after the mock applied the real fix without the real test change, found the old test that the fix contradicts, and blocked once. A real agent can see and act on that; the mock cannot. It is how the harness behaves and is not changed.

### 2026-11-09, web tools removed from every arm (before any scored run)

- **Problem, found in review with the mock model ($0).** Under `bypassPermissions`, Claude Code 2.1.311 offers `WebSearch` and `WebFetch` and runs `WebSearch` without asking. The search is a separate Messages request that offers the `web_search_20250305` server tool. It passes through the meter, which forwards request bodies unchanged, to the API, where the search runs on the open internet, past the container's network isolation. In a mock probe the `none` arm's scripted search returned search-result text and added one request to the meter (4 requests against 3). The `olivium` arm runs in default mode and its exported allow list names neither tool, so both were refused there. The `none` and `generic` arms could therefore have looked up the upstream pull request or fix and the `olivium` arm could not. That is a difference between arms outside the pre-registered one (harness files and settings). The search fee ($10 per 1,000 searches) is also missing from the meter's price table. In the pilot, all 51 sessions were offered both tools and none used them.
- **Change.** Every agent session under this protocol, in every arm and in `/init`, runs with `--disallowedTools "WebSearch,WebFetch"`. The launch script adds the flag when `BENCH_DISALLOW_WEB=1`, which `lib/session.py` sets for protocol 2 only. The bytes passed with `--settings` are unchanged, so the `olivium` arm still runs its exported settings byte for byte; the flag is a command-line rule applied the same way to all arms. Second layer: under this protocol the meter starts with `--refuse-web-tools`. It refuses any Messages request that offers a web search or web fetch server tool (403, `x-should-retry: false`, logged as `refused_web_tool`, $0, never forwarded), so a search cannot run even if the flag were lost. The meter also logs the type of any server tool a request offers. Agent images are rebuilt because the launch script changed, and the meter image because the meter changed. The pilot path is unchanged: re-analysing the pilot's data gives a `results.json` byte-identical to the published one.
- **Guard.** Each trial records Claude Code's own init tool list, the web tools it offered and the web tool calls made. A trial that was offered a web tool, or whose meter rows hold a refused or forwarded web request, is scored `infra_error`, and the runner starts no further trial, because such a failure would be systematic and every further run would still cost money. A `/init` setup with the same evidence fails, so `run` refuses to start. The report gives these counts per arm.
- **Effect on the comparison with the pilot.** In the pilot every arm was offered both tools; in this version no arm is. The before-and-after table is already labelled as different runs, and its note now names this difference too.
- **Proof, mock model, $0.** Probe through the real run config of each arm on `pallets-click-3858`. With the fix, all three arms were offered the same 20 tools, without `WebSearch` and `WebFetch`. Scripted `WebSearch` and `WebFetch` calls, including one from a subagent, failed with "No such tool available … disabled for this session, in subagents as well as here". `ToolSearch` found no deferred web tools. Each arm made 8 meter requests and none offered a server tool. With the command-line flag deliberately stripped from the container, the meter refused both of Claude Code's real `web_search_20250305` requests (main session and subagent), and the trial was classified `infra_error`. Run end to end through `run.py` with the flag stripped, the first two trials were scored `infra_error` with "Claude Code offered WebFetch,WebSearch", and no further trial started. The mock rehearsal was then repeated in full: `gold` on 4 tasks, `permcheck` and `hookfail` on 3, and `gold` on all 8. All 54 of 54 trials completed. No trial was offered a web tool, the init tool sets were identical across arms on every task, none of the 519 meter rows offered a web or server tool, and every `/init` recorded no web tool. Every scored field of every trial (status, solved, patch lines, cost, requests, turns, permission denials, Stop blocks, tests, lint, files read) is identical to the rehearsal before this change. The generated `olivium` arms are byte-identical, and the `permcheck` and `hookfail` proofs hold as before.

### 2026-11-10, first paid canary: a product defect, the generator fixed, the canary stop rule (before any scored run)

- **What ran.** The first paid canary of this protocol: `pallets-click-3858`, three arms, one repeat, output `<bench-out>/value-v2-2026-11-09-canary`, 2026-11-09. Meter total $0.3979005 (`/init` $0.0974153; trials `none` $0.0625892, `generic` $0.0926459, `olivium` $0.1452501), equal to Claude Code's own `total_cost_usd` on every trial. All three trials `completed` and solved it (1 of 1 fail-to-pass, 0 regressions, lint passed). No web tool was offered and every harness check passed.
- **Why it stopped: a defect in the product, not in the benchmark.** The `olivium` trial had 5 permission denials in Claude Code's `result` event. All 5 came from the generator's own exported settings, on ordinary reads and the project's own toolchain inside the project, which the product means to run without a prompt in an unattended session:
  1. `cd /work/repo/src/click && grep -n "class Path" ... types.py ...`: Claude Code 2.1.311 asked because the export had 43 `Read(...)` deny rules; while any `Read` deny rule exists, it asks before a relative-path read after a `cd` in a compound command.
  2. `python3 - <<'E' ...` (an edit script, followed by `uv run mypy`, `uv run ruff` and `uv run pytest`): bare `python3` was not on the allow list.
  3. `python3 -I /tmp/edit_path.py`: the same.
  4. `uv run --no-sync pytest -q 2>&1 | tail -3; which mypy pyright ruff` and 5. `uv run --no-sync pytest -q tests/test_types.py`: `uv run --no-sync pytest` does not match `Bash(uv run pytest:*)`.
  An unattended run refuses what Claude Code asks, so these refusals counted against the arm because of a generator defect.
- **The fix, made in the product outside the benchmark and reviewed there.** `lib/harness_forge/generation/spec.ex` and `priv/blueprints/base.json`, `python.json`, `node.json`, `elixir.json`: the allow list now holds the shell utilities every project uses and the detected toolchain (the interpreter, the runner of each detected package manager with any arguments, so `uv run --no-sync pytest` matches `Bash(uv run:*)`, and each tool a detected command names, bare). `lib/harness_forge/adapters/claude_code.ex`: no `Read(...)` deny rule is written; secret reads are refused by the guard instead. New `lib/harness_forge/adapters/claude_code/guard.ex`: the export gains `.claude/hooks/olivium-guard.sh`, run by a `PreToolUse` hook in `.claude/settings.json`. The guard only refuses, best effort, what it can parse: secret reads, paths outside the project, denied commands also behind wrappers and runners, recursive deletes, branch deletion, package downloads, and changes to the project's `.claude` files. The hook command runs it only while its SHA-256 equals the generated value and passes on only its exact deny line, so it never approves a call. The settings are described in `docs/claude-code-connector.md`, section "Generator settings (v1alpha2)". The final review ran 1,212 calls through real Claude Code 2.1.311 and the mock meter ($0), with the full export and with the settings alone: 0 hook approvals, and no call ran with the full export that did not also run with the settings alone, apart from one deliberate case (2 calls, one per task) in which the two runs had reached different file states. In that review `mix test` gave 1738 tests, 0 failures, 28 skipped.
- **What this changes in the `olivium` arm.** The arm is still the generator's output, unmodified (see Arms); it now also contains `.claude/hooks/olivium-guard.sh`, and the harness check hashes and compares that file like every other harness file. The arm still runs with its exported `.claude/settings.json` passed with `--settings`, in `default` mode.
- **The first canary is not scored.** Its directory stays on disk, unchanged, as the record of the defect. None of its trials and not its `/init` enter any analysis. Its $0.3979005 counts toward spending: $3.88 of the $60 was spent before any scored run ($3.48 on the pilot, $0.40 on this canary), and `--cap-usd 30` keeps the program under $60.
- **The `olivium` arms are rebuilt from the fixed application.** `prepare` re-takes the application snapshot whenever `lib/`, `config/`, `priv/blueprints/`, `bin/harnessforge` or `mix.lock` changed. The fixed application's digests are `lib` `ccc8a19c4753cff2e932ce23f141c136b22c1def8bcbf465d3dcf784f7d47f07` and `priv/blueprints` `82e96fc7b4f3f6d50dd066ff91660272867a9290a882659c936f28ab39d244ed` (the canary ran `lib` `669ad231860e571fe89cd8327b29e91a9eb23a2d0b64512326db4cf0ea7990e4`; `config`, `bin/harnessforge` and `mix.lock` are unchanged). A finished `olivium` setup is never rebuilt inside an existing output directory, so the next canary and the scored run each use a new output directory, and their arms are built from the fixed application. The arms of all 8 tasks are rebuilt.
- **Nothing else in this protocol changes.** Not the tasks or the manifest (checksum `c8bde114ef966b873cc0a13cb15e153474e5e96c3643f3ec9f3034e6104061d3`), the `none` and `generic` arms, how each arm runs, the prompt, the limits, the caps, the seed, grading, the metrics or the analysis.
- **Canary stop rule, amended.** Before the scored run, a paid canary runs one task (`pallets-click-3858`), three arms, one repeat, in its own new output directory. Its trials are never scored. It stops the benchmark only for one of these:
  1. a refusal, in the `olivium` arm, of a call that `docs/claude-code-connector.md` (SHA-256 `b4849bf58e9ba3b5556024fca06ec2f8880b9cdc14b2b3780d8c30d82c418651` at this entry), section "Generator settings (v1alpha2)", says is allowed: a call of a kind listed under "What is allowed" that falls under none of "What is denied", the refusals listed under "The guard hook", or "What still asks". That is a product defect;
  2. a harness file missing from the container: any harness-check failure (a harness file missing, extra or changed, or the `--settings` bytes not equal to the exported settings);
  3. the meter's cost and Claude Code's own `total_cost_usd` disagreeing on a trial by more than one millionth (relative);
  4. a web tool offered to any session, or a web request in the meter log;
  5. a grading failure: grading did not return status `ok` for a trial that is not `infra_error`.

  Every other refusal (a deny rule, a guard refusal, or an ask the docs list) is part of what this protocol measures. It is reported with the canary's result, with its tool, the start of its command and the documented class it falls under, and it is neither a reason to stop nor a reason to change the harness. If a stop condition holds, no scored run starts and the cause is logged here.

### 2026-11-10, mock rehearsal after the generator fix (no model contacted, $0, before any scored run)

- **What ran.** `run.py --dry-run --protocol 2` against the mock meter, 1 repeat, output in the scratch directory only, with a new application snapshot (digests as in the entry above): `gold` on all 8 tasks (24 trials), `permcheck` and `hookfail` on `pallets-click-3858` and `expressjs-express-7366` (6 trials each). 36 of 36 trials `completed`; every `gold` and `permcheck` trial solved and every `hookfail` trial unsolved, as scripted; patch lines equal across arms on every task. Every scored field of all 36 trials (status, solved, patch lines, cost, requests, turns, permission denials, Stop blocks, tests, lint, files read, tool calls) is identical to the rehearsal before the fix.
- **The rebuilt `olivium` arms.** All 8 built from the fixed application with the post-base check passing (no forbidden commit, ref, remote, tag, SHA or `#NNNN` in any exported file). 9 files (Express) or 10, 65,159 to 73,592 bytes; `CLAUDE.md` 197 to 1,413 bytes; `.claude/hooks/olivium-guard.sh` 34,257 to 34,270 bytes; 46 or 47 allow rules, 104 deny rules, no `Read(...)` deny rule. The arms of `pallets-click-3858` and `expressjs-express-7366`, built three times each (for `gold`, `permcheck` and `hookfail`), were byte-identical each time and equal the final review's independent builds of the same tasks.
- **Proofs for the `olivium` arm (12 trials).** `permissionMode` `default` in Claude Code's init event; the bytes passed with `--settings` had the same SHA-256 as the exported settings on the host and in the container; the harness check found every exported file in the container and nothing else, with matching SHA-256 for each hook file (`olivium-guard.sh`, `olivium-before-stop.sh`, and `olivium-format.sh` where generated). The guard's checksum in the hook command matched the guard file, and the guard ran on all 74 tool calls: 74 `PreToolUse` responses, all exit 0, no "missing, changed or cannot be checked" or "failed" warning, no hook approval. Under `permcheck` the allow-listed `mkdir` ran without a prompt in `default` mode, and `rm -rf` and `curl` were refused by the guard before Claude Code's own deny rules were reached (`curl` is now on the deny list too), both listed in Claude Code's `permission_denials`; this run therefore shows the allow list applied and the guard refusing, not a deny rule firing. Under `hookfail` the Stop hook exited 2 once and the retry was allowed; under `gold` it blocked once on each of the three werkzeug tasks, as before.
- **Web guard.** No trial was offered a web tool, the init tool sets (20 tools) were identical across arms on every task, none of the 329 meter rows offered a web or server tool, none was refused, and every mock `/init` recorded no web tool.
- **The canary's refused calls, replayed.** Each of the 5 calls the first canary refused in the `olivium` arm of `pallets-click-3858` ran in its own fresh container through real Claude Code 2.1.311 with the trial's run configuration and the mock meter (the `/tmp/edit_path.py` call preceded by the canary's own `Write` of that file). With the canary's export, all 5 asked again with the same messages and were refused, which shows the replay reproduces the canary. With the rebuilt export, 3 ran (the `cd ... && grep` read, `uv run --no-sync pytest -q ...; which ...` and `uv run --no-sync pytest -q tests/test_types.py`) and 2 were refused by the guard as naming a path outside the project (the edit script, whose here-document also writes `/tmp/mre.py`, and `python3 -I /tmp/edit_path.py`); the guard also refused the preceding `Write` to `/tmp/edit_path.py`, which the canary's export had allowed. Both refusals are a class the docs list under "The guard hook" (`/tmp` is outside the project), so under the amended rule they would be reported, not a reason to stop. Calls 2 and 3 of the first entry above therefore still fail, now for a documented reason (scratch files under `/tmp`) instead of the missing `python3` rule, and the guard's message tells the agent to keep scratch files inside the project.

### 2026-11-10, after the scored run: the harness's own refusals fixed, and a re-run of the `olivium` arm on the same tasks

- **Why.** In the scored run the `olivium` arm cost more than `none` on all 8 tasks and its runs with a refusal took more turns. Its exported settings refused 35 calls in 14 of 24 runs, all ordinary work inside the task's repository: 26 were Claude Code asking about a command no allow rule matched (`cd dir && git ...`, a here-document fed to `python -`, `sed -i` with escapes, a `cd` followed by a write), which an unattended session refuses; 9 were the guard (7 scratch files under `/tmp`, 1 `ls ~/.local/share/uv/python`, 1 `rm -rf scratch_tmp`). The `none` and `generic` arms run in `bypassPermissions` and had none.
- **The fix, in the product.** `lib/harness_forge/generation/spec.ex`: in solo mode (the hands-free default, used by this benchmark) the spec allows the shell tool as a whole, so the export's allow list gains a bare `Bash`. Deny rules and the guard hook still apply first. Team mode is unchanged. `lib/harness_forge/adapters/claude_code/guard.ex`: the system's scratch directories (`/tmp`, `/var/tmp`, `/dev/shm`, and on macOS their real paths under `/private` and the per-user temporary directory) no longer count as outside the project. A secret name there, and a link from there to a path outside both, are still refused. The guard's message now says to put scratch files in `/tmp` instead of in the project. Fixed application digests: `lib` `ec84759cd181f771cd65e11acd36a4b8e485c4ebbdaff25f91f647ffb2ffc7fb`, `priv/blueprints` `82e96fc7b4f3f6d50dd066ff91660272867a9290a882659c936f28ab39d244ed` (unchanged).
- **Proof at $0, before any paid call.** Every main-session tool call of the 14 `olivium` runs that had a refusal (150 calls) was replayed in its original order through real Claude Code 2.1.311 in the task's agent image with the mock meter, one session per run, with the trial's run configuration. With the scored run's exported arms the replay reproduced all 35 refusals. With the same arms plus a bare `Bash` allow rule, 9 remained (the guard's 9). With arms rebuilt from the fixed application, 2 remained: `ls ~/.local/share/uv/python` (the home directory stays outside) and `rm -rf scratch_tmp` (recursive deletes stay refused). The guard ran on all 142 `PreToolUse` events of that replay, all exit 0, no warning, no approval.
- **The re-run, decided before it ran.** New output directory `<bench-out>/value-v2-2026-11-10-fix`. The same 8 tasks and manifest, the same prompt, limits, model, Claude Code version and agent images, 3 repeats, the default seed, `--arms olivium` (the `none` and `generic` arms are not re-run). The `olivium` arms are rebuilt from the fixed application. `--cap-usd 10`. No separate canary: the replay and a mock rehearsal stand in, and the runner still stops at the first `infra_error`.
- **How it is reported.** Its 24 `olivium` trials are compared with the scored run's `none` and `generic` trials of the same tasks, with the same metrics and the same paired per-task bootstrap. The report labels it plainly: different runs of the arms, and the same tasks the fix was found on, so it is not a held-out result. The scored run's results stay published unchanged. All its trials count toward spending.
