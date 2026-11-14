# Value benchmark protocol

Written 2026-11-08, before any paid run. This file is the pre-registration. Any
change after the first paid run must be added to the change log at the bottom,
with the reason.

## Question

Does a harness produced by Olivium Harness make a coding agent cheaper, better
informed or more accurate on real tasks in a real repository, compared with no
harness and with a free generic instruction file?

The earlier benchmark in `docs/benchmarks/2026-11-08/` measures whether the tool
works. It says nothing about this question.

## Arms

| Arm | What the agent gets |
| --- | --- |
| `none` | The repository at the commit before the fix. No instruction files. |
| `generic` | Same, plus a `CLAUDE.md` written by Claude Code's own `/init` at that commit. This is the free alternative a harness has to beat. |
| `olivium` | Same, plus the files produced by this repository's real pipeline at that commit. |

The `olivium` arm uses the pipeline as it exists: import the repository's
Markdown files as they were at the commit before the fix, propose claims through
the Anthropic provider, approve every proposal that has valid citations, build
for `claude_code`, export. Nothing in this arm is written by hand. Its input
must not contain anything from the fix commit or later.

Every arm starts from the same snapshot. Any `CLAUDE.md`, `AGENTS.md`, `.claude/`,
`.cursor/` or `.github/copilot-instructions.md` already in the repository is
removed from all arms first.

The exported `.claude/settings.json` asks for permission on every tool and
disables bypass mode, so it cannot run headless. All arms use one identical
benchmark settings file instead. `CLAUDE.md`, agents and skills stay exactly as
generated. One extra run with the settings as exported records what happens; it
is reported separately and is not part of the analysis.

## Task selection

The rule picks the tasks. Nobody picks them by hand, and every rejected candidate
is recorded with its reason.

- Public repositories with an MIT, BSD or Apache-2.0 licence, in Python or
  JavaScript/TypeScript, whose tests run offline in under 5 minutes.
- Start from `pallets/click`, `pallets/flask`, `pallets/jinja`, `encode/httpx`,
  `python-attrs/attrs`, `expressjs/express`. If these give too few tasks, add
  repositories with over 1,000 stars and record the addition.
- Merged pull requests, newest first, merged after 2026-06-30 so the fix is
  unlikely to be in the model's training data. If that yields too few, widen the
  date and record it.
- The pull request closes a linked issue that describes the problem in prose.
- At most 3 non-test files and 100 non-test lines changed; at least one test
  added or changed; no dependency changes.
- Validation inside Docker with no network: the target tests fail at the parent
  commit with the test patch applied and pass with the real fix, 3 times out of 3.
- Take the first 5 eligible tasks in round-robin order, at most 2 per repository.

The task list is frozen, with a checksum, before any paid run. The repository
stores references only (repository URL, commit SHAs, issue URL, checksum of the
issue text), not third-party source.

## Environment

- Claude Code pinned to 2.1.311, the version the `claude_code` adapter targets. If
  that version cannot be installed or cannot use the model, use the nearest working
  version and record it.
- Model `claude-sonnet-5-5` for every run and every arm.
- Repository code and model-generated code run only inside Docker, never on the
  host. The agent container runs as non-root with all capabilities dropped, no
  privilege escalation, limits on memory, CPU and processes, and no host mounts.
- The agent container has no route to the internet. Its only peer is the meter.
- The meter is a reverse proxy to the Anthropic API. It alone holds the API key.
  The key never enters a container that runs model-generated code.
- The agent's repository has only history up to the parent commit, with no remotes.
- Grading runs in a separate fresh container with `--network none`.

## Run procedure

- 5 tasks × 3 arms × 3 repeats = 45 scored runs. Setup calls (`/init`, claim
  proposal) are metered and reported separately as setup cost.
- The prompt is the same in all arms: the issue title and body, then
  `Fix this issue in the repository in the current directory.`
- Limits per run: 60 turns, 20 minutes, and a per-run dollar limit set at launch.
- Run order is shuffled with seed `20261108`, so that time of day and prompt-cache
  warmth are spread evenly across arms.
- At most 2 runs at a time.

## Metrics

Token counts come from the meter, which reads them from the API responses. Claude
Code's own totals are recorded as a cross-check.

| Question | Metric |
| --- | --- |
| Fewer tokens? | Input, output, cache-write and cache-read tokens per run; cost per run in USD; **cost per solved task** (total arm cost divided by runs solved) |
| Better context? | Distinct files read that are not in the real fix (`wasted_reads`); turns and tool calls before the first edit to a file in the real fix |
| More accurate? | **Solved**: every fail-to-pass test passes and no pass-to-pass test regresses; regressions; repository's configured linter passes, where one exists |

The agent's patch is applied to a clean checkout, then the real test patch
overwrites any test files it touches.

A run that hits a limit is scored unsolved and its cost counts.

### Trial record (`trials.jsonl`)

`run_id, task_id, arm, repeat, status (completed|timeout|turn_limit|budget_exhausted|infra_error), solved, f2p_passed, f2p_total, p2p_regressions, lint_ok, tokens {input, output, cache_creation, cache_read}, cost_usd, requests, turns, tool_calls {name: count}, files_read, wasted_reads, turns_before_first_gold_edit, tool_calls_before_first_gold_edit, patch_lines, wall_seconds, model, claude_code_version, harness_bytes`

## Analysis

- For each task, average the 3 repeats per arm, then take differences
  `olivium − none` and `olivium − generic`.
- Report per-task values, the median difference, and a percentile bootstrap 95%
  interval across tasks (10,000 resamples, seed `20261108`).
- With 5 tasks this is a pilot. It can show a direction and it can show a problem.
  It cannot prove a general effect, and the report must say so next to the numbers.

## Spending and restarts

- A paid run needs an explicit `--paid` flag, a key file and a `--cap-usd` value.
- The meter stops forwarding requests once the cap is reached. Runs cut off this
  way are `budget_exhausted`, and the report states how many.
- `infra_error` runs (API outage, Docker failure) may be repeated. Each repeat is
  logged. Runs that fail because of the model are never repeated.
- If a bug in the benchmark is found after paid runs start, all runs are discarded
  and the benchmark restarts, with an entry below. Runs are never re-done
  selectively.

## Publication

The result is published whatever it is, including no effect or a negative one.
Numbers reach the project README only from the final `results.json`. Rehearsal
data from the mock model never leaves the scratch directory.

## What this cannot show

Five tasks, one model, one agent, two languages, bug fixes only. Repositories
need Markdown documentation for the `olivium` arm to have input, which narrows
the sample. Today's pipeline reads documentation only, not git history or code;
that is the hands-free generator on the roadmap, which is not built yet.

## Change log

### 2026-11-09, before any paid run

- **Which files are proposed.** `propose` takes one source per call and every call costs money, so the set is fixed by rule, not by hand. All Markdown files at the base commit are imported. Proposals are made for at most 5 of them, chosen without any reference to the task: exclude empty files, files over 32 KiB, changelogs and release notes (basename starting `change`, `history`, `news`, `release`, or a `changelog.d/` directory), code of conduct, security, licence, support and funding files, and issue or pull-request templates; rank the root README first, then contributing or development guides, then files under `docs/` or `doc/`, then everything else, and within a rank shallowest path first, then alphabetical; take files in that order while the running total stays at or under 40,000 bytes, skipping any file that would exceed it. Reason: this keeps setup cost small and bounded (at most 5 requests per task with `max_output_tokens` 4096; the application ledger enforces a $1.00 limit per task) and it is the same rule for every task. See `arms/olivium.py`.
- **Proposal calls are metered by the application, not by the meter, and the application holds the key for that step.** The Anthropic provider accepts only the exact endpoint `https://api.anthropic.com/v1` (`lib/harness_forge/models/configuration.ex`), so it cannot be pointed at the meter without changing `lib/` or using a test-only hook. In a paid run, the host process running `mix run` receives the key through `HARNESSFORGE_BENCH_ANTHROPIC_API_KEY` for the proposal step only; no container that runs model-generated code ever sees it. Token counts for this step come from the application's usage ledger as reported by the API, are priced from `meter/prices.json`, and are reported as setup cost. Requests with unknown usage are counted at their full reservation. The meter's total cap is reduced by this spending.
- **Proposal step in rehearsal.** Because the provider cannot reach the mock, `--dry-run` replaces the one call to `Models.propose/2` with a fixture whose claims are marked `REHEARSAL FIXTURE (not model output)`. They still pass the real `Proposal.validate/2` and `Proposal.persist/2`, and connect, sync, approval, build and export are the real pipeline. The real proposal request path is not exercised by any rehearsal.
- **Grading also restores test configuration.** After the agent's patch is applied and before the real test patch, every path the patch touched that is a test file, test configuration or harness, or CI file is restored to the base commit, or removed if the agent added it: anything under a `test`, `tests`, `testing`, `__tests__`, `spec` or `specs` directory, `conftest.py`, pytest and tox configuration, `pyproject.toml`, `setup.cfg`, `package.json` and lockfiles, mocha, jest and vitest configuration, lint configuration (eslint, ruff, flake8, mypy), `.github/` and other CI files, and every file in the task's `test_files`. Reason: an agent must not be able to pass by weakening the tests. See `grade/grade.sh`.
- **Trace definitions.** `files_read` and `wasted_reads` count distinct files under the repository read with `Read` or with simple `cat`, `head`, `tail`, `less`, `more`, `nl`, `sed` or `awk` commands that name a file existing at the base commit. Failed tool calls never count as reads or edits. No path is special-cased by arm, so a read of an arm's `CLAUDE.md` or skill counts as a wasted read. `turns` counts main-session assistant messages; `tool_calls` includes subagent calls.
- **Retries and the as-exported run.** A trial that ends as `infra_error`, including one interrupted part-way, is recorded and repeated on the next `run` under a new `run_id` (`<task>.<arm>.r<repeat>.a<attempt>`), at most 3 attempts; every attempt is logged in `attempts.jsonl`. Trials that hit a limit are scored unsolved and are not repeated. The one run with settings as exported uses the first task in manifest order, `permission-mode default` and the exported `.claude/settings.json`; it is stored under `as_exported/`, never in `trials.jsonl`.
- **Total cap ends the run.** Once the meter refuses a request because the total cap is reached, trials already running finish as `budget_exhausted` and no further trial starts. Trials that never started stay unrecorded and `run` reports them as pending. Reason: starting them would only record empty refusals as unsolved runs, which would be misread as model results.
- **Adversarial review, before any paid run.** Changes from the review, each a bug or a closed loophole:
  - **Trial status.** A session that ended abnormally without reaching a limit (non-zero exit or `is_error`, for example because the meter or API went away) is `infra_error`; previously it could be scored as `completed` and unsolved. A session that finished normally is `completed` even if an upstream error was retried past on the way (a 429 or 529 no longer discards a good run). An abnormal end caused by the agent's own oversized request (`upstream_400`, `upstream_413`) stays `completed` and unsolved, because runs that fail because of the model are never repeated. See `lib/transcript.py`.
  - **A dead meter stops the queue.** No further trial starts once the meter container has stopped, so trials do not use up their attempts against a meter that is gone. Re-running resumes with spending intact.
  - **Failed setup still counts its spending.** A failed or retried proposal step keeps its tokens and cost in the setup record and reduces the meter's total cap; unknown usage counts at its reservation, and a pipeline that dies before reporting counts at the full $1.00 task limit. Failed `/init` attempts report their meter usage. The report shows both the setup cost and the upper bound.
  - **Grading also removes test-runner shadows.** `python -m pytest` puts the repository root first on `sys.path`, so a root-level `pytest.py` or a root-level `*.dist-info` directory can forge results while touching no test file. Root-level `.py` and `.pth` files, `*.dist-info` and `*.egg-info` paths, and top-level `pytest`, `_pytest`, `pluggy`, `iniconfig`, `packaging`, `exceptiongroup`, `tomli` or `py` directories changed by the agent are restored or removed before the test patch. Forgery through ordinary source files in the package under test is still possible and is not detected.
  - **Turns before the first edit.** `turns_before_first_gold_edit` counts assistant messages from the main session and subagents, so delegating work to a subagent does not look like fewer turns. `tool_calls_before_first_gold_edit` already did. The first edit is the first edit to a real-fix file other than a changelog (`CHANGES*`, `History*`, `NEWS*`, `RELEASE*`, `changelog.d/`): an edit to a changelog says nothing about having found the bug. `wasted_reads` still uses all real-fix files, as defined above.
  - **Trace limitation, stated plainly.** Reads through simple Bash commands are counted, following a leading `cd` in the same command. Reads through `grep`, `rg`, `find`, interpreters or a command in a Bash script are not; `wasted_reads` is therefore a lower bound on files actually inspected.
  - **The meter is built from the checked-out source** every time it starts, and its image id is recorded in `meter/image.json`. Before, an existing image was reused silently, so a meter or price change could be left out of a run.
  - **Dated model ids.** A response naming a dated snapshot of the requested model (`claude-haiku-5-5-20261001` for `claude-haiku-5-5`) is priced at the requested model. Any other unknown model still gets the most expensive rate.
  - **The 60-turn limit** counts main-session turns; turns inside a subagent do not use it up. An arm that delegates can therefore run longer under this limit. The 20-minute and per-run dollar limits apply to subagents too, and every subagent token is counted in cost.
  - **Instruction files are removed at any depth**, not only the repository root, in every arm (`arms/entry.sh`), and such files are not imported into the `olivium` arm. None of the five frozen tasks ships any, at any depth.

### 2026-11-09, canary (first paid run; the pilot did not start)

- **What ran.** `prepare --paid` for `pallets-flask-6133` only, `--cap-usd 8 --run-cap-usd 3`, output under `<bench-out>/canary`. The `generic` arm succeeded through the live meter: 7 requests to `claude-sonnet-5-5`, 2,455 output tokens, $0.097851 by the meter, equal to Claude Code 2.1.311's own `total_cost_usd`. No scored trial ran, so the canary produced no trial data.
- **The `olivium` arm failed: `no_approved_claims`.** Three proposal requests were made (root `README.md`, `examples/celery/README.md`, `src/flask/sansio/README.md`; Flask's documentation is reStructuredText, so these are the only eligible Markdown files). Two ended `uncertain` after 15 s and 18 s, one `completed` (784 input, 347 output tokens) but persisted no claims. Setup cost recorded: $0.005038 reported, $0.100848 upper bound.
- **Cause, established by replaying the identical request body outside the pipeline** (3 calls, $0.072, scratch only): `claude-sonnet-5-5` runs adaptive thinking when the request omits `thinking`, and every replay returned `content` = `[thinking, text]`. `HarnessForge.Models.Anthropic.output_text/1` requires every content block to be `text`, so the adapter returns `:invalid_provider_response` and the ledger records the request as `uncertain`. The replays themselves returned 3, 3 and 3 claims, of which 3, 3 and 2 had byte-exact citations; `Proposal.validate/2` rejects a whole proposal when any citation is wrong, which is the second way a request yields nothing.
- **Why the pilot did not start.** Both causes are in `lib/` (`models/anthropic.ex`: accept non-text blocks or send `thinking: {"type": "between_tools"}`; `models/proposal.ex`: all-or-nothing validation). The benchmark must use the pipeline as it exists and may not change `lib/`, and an `olivium` arm with no content cannot be measured. No design change was made. The pilot waits for a `lib/` fix and a repeated canary.
- **Debuggability.** `arms/pipeline.exs` now includes the per-file proposal outcomes (`status`, `claims`, `error`) in a failed report as well, so the error code is visible without a replay. Not a design change.

### 2026-11-09, after the canary: adapter fix, canary repeated

- **Fix in `lib/harness_forge/models/anthropic.ex`** (made by the coordinator, outside the benchmark): `output_text/1` now ignores `thinking` and `redacted_thinking` content blocks; any other non-text block is still `invalid_provider_response`. The request body is unchanged, so the model still thinks adaptively and the thinking is billed. The `olivium` arm of the repeated canary and of the pilot uses the pipeline with this fix; the canary's `app-snapshot.json` records the `lib/` digest it ran with. This is a compatibility fix to what the app accepts from the API, not a change to proposal validation, citation checking, approval or the compiler.
- **Known limit, measured rather than changed.** Adaptive thinking spends from the same `max_tokens` (4096 per proposal request). A response stopped by `max_tokens` has `stop_reason` `max_tokens` and is still rejected as `invalid_provider_response`; and `Proposal.validate/2` still rejects a whole proposal when one citation is wrong. Both are how the pipeline works today. The setup records (`olivium.setup.json`, `proposals[]`) show per file whether a proposal request failed and with what code; the report states how many proposal requests failed, how many tasks ended with `claims_approved` 0, and the pilot stops only if the `olivium` arm is empty for most tasks.
- **Snapshot staleness, fixed in `arms/olivium.py`.** The pipeline snapshot under OUT was reused as long as it existed, so `--retry-failed` after a `lib/` fix would have run the old code. The snapshot is now re-taken when the digest of `lib/`, `config/` or `mix.lock` differs from the one recorded in `app-snapshot.json`.
- **Canary result after the fix.** `prepare --retry-failed` re-took the pipeline snapshot and the `olivium` arm built: 3 of 3 proposal requests completed (1,402/1,081/795 input and 1,807/1,523/1,666 output tokens, none stopped by `max_tokens`), 6 claims proposed, 6 approved, harness 1,989 bytes (`CLAUDE.md`, one agent, one skill); setup cost $0.061554 reported, $0.157364 upper bound including the failed first attempt. `run` then completed 3 of 3 scored trials (`none`, `generic`, `olivium`, 1 repeat): every trial `completed`, meter cost equal to Claude Code's `total_cost_usd` on all three ($0.0869, $0.0522, $0.0808), 7 turns each, graded in Docker (494 tests seen, 0 regressions), 0 solved. The canary's analysis output is real (not stamped REHEARSAL) and is not part of the pilot.
- **Task selection defect found by the canary: `pallets-flask-6133` is withdrawn by rule.** Its pull request body says `closes #3193`, and the selector accepted that link. Issue #3193 (opened 2019-05-10, "Flask Session variable not available in threads") describes a different problem from the fix (an `app.query` route decorator for the HTTP QUERY method, 2026-08-11), so no agent could solve the task from its prompt, and all three canary agents patched documentation about proxies in threads instead. The other four tasks' issues were opened 0 to 68 days before their pull requests and match their fixes. **New static rule, fixed before any pilot run and before looking at which candidate it admits:** the linked issue must have been opened at most 365 days before the pull request was merged (`RULES["max_issue_age_days"]`, rejection `linked_issue_not_usable` with `issue_too_old:<days>_days`). Reasons: a years-old issue is more likely a stale cross-reference than the problem the fix addresses, and its text, the prompt of this benchmark, is in the model's training data, which the post-2026-06-30 rule exists to avoid for the fix. Selection was re-run from the same cached API data with `--resume`, so the four kept tasks are unchanged and the replacement is the next eligible candidate in the pre-registered round-robin order, validated 3 of 3 in Docker like the others. The superseded manifest (checksum `789ca06df7a37b659df5fa92cb7edbd67dd399d59433ba38f3127acb6f08d52f`) is kept in the selection scratch directory. **Outcome:** the re-run (from cache, `--resume`, 2026-11-09T15:22:45Z) rejected `pallets/flask#6133` as `linked_issue_not_usable` (`issue_too_old:2650_days`) and admitted the next flask candidate in round-robin order, `pallets-flask-6096` (fix for `.partition(":")` on IPv6 addresses; its issue was opened 29 days before the merge; validated 3 of 3 base-fail and 3 of 3 fix-pass, f2p 2, p2p 491, flaky 0). The other four tasks are unchanged. New frozen manifest checksum: `aa9b6795b6fa1e6cd6e4367d723f3051d8f647cb12fde12e89a93db419c50e43`, with 133 rejections recorded in `corpus/rejected.jsonl`.
- **Pilot run, 2026-11-09 15:33 to 15:56 UTC, output `<bench-out>/pilot-2026-11-09`, evidence in `docs/benchmarks/value-2026-11-09/`.** 45 of 45 scored trials `completed`; 0 `infra_error`, 0 `timeout`, 0 `turn_limit`, 0 `budget_exhausted`; no trial was repeated and no trial was discarded. Meter cost equalled Claude Code's `total_cost_usd` on all 45; one prompt hash per task across arms; `claude-sonnet-5-5` and Claude Code 2.1.311 throughout. Setup: `/init` $0.3198 (5 tasks); proposals 21 requests, 15 ok, 4 `invalid_model_output` (the whole proposal rejected by `Proposal.validate/2`, which stays as it is), 2 `invalid_provider_response` with unknown usage (counted at reservation; consistent with a `max_tokens` stop but the stop reason is not recorded by the pipeline); every task got approved claims (9, 3, 11, 2, 4). Spend: scored trials $2.0470, as-exported run $0.0265, proposals $0.4338 reported / $0.5416 upper bound; pilot total $2.93 upper bound; with the canary and diagnostics, $3.48 of the $60 ceiling. Runs were short (median 20 to 35 s, 5 to 6 turns), so the per-run cap never mattered.
- **Metric gap, stated rather than changed.** `turns_before_first_gold_edit` is `n/a` for a run that edited the real-fix file through an interpreter in a Bash heredoc (for example `python - <<EOF`), which `BASH_EDIT_RE` does not match; all three `none` runs on `python-attrs-attrs-1593` are such runs, so that task is excluded from the olivium − none comparison on that metric (4 tasks used). Like `wasted_reads`, this metric is a lower bound on what the trace can see.
- **Stop-condition change for this run (coordinator's instruction).** A further compatibility or transport defect under `lib/harness_forge/models/` (the app failing to parse or send what the API really does) is fixed minimally by the benchmark operator, compiled with `--warnings-as-errors`, formatted, and recorded here. Nothing that decides the content of the `olivium` arm (validation, citation checks, approval, compiler output) is changed.

