# Harness enhancement plan and benchmark v3

Date: 2026-11-11. Status: final plan after red team. Planning only; this file is the only repository change.

Status update, 2026-11-11: stage 1 and 2 built, Gate 1 passed, generator frozen at integration point 2. See section 13.

Inputs: master plan `S-master-plan.md` and evidence reports U1, U2, U3, U4, D1, D2, D3 in `WORK_ROOT/v3-program/plan/`. Machine-readable copy: `WORK_ROOT/v3-program/final-plan.json`. Lane G / lane A contract: `WORK_ROOT/v3-program/contract.md`.

`WORK_ROOT` in this document is the program's work directory, outside the repository. Its location is machine-local and is not recorded here.

Words: "none" = no harness. "/init" = Claude Code's own CLAUDE.md. "fix run" = the Olivium run of 2026-11-10. "turn" = one model request. "prefix" = the system prompt, tool definitions and session context sent with every request. "lean" = the new context profile (item 2).

---

## 0. Summary

**What the red team changed.** The master plan's largest open number was the size of the prefix a project settings file can remove. It guessed 1,500 to 4,000 tokens per request. I measured it at $0: real Claude Code 2.1.311 in the benchmark's Docker image, talking to a local capture server that records each request and answers with a scripted reply (no API, no key).

| Setting in the generated `.claude/settings.json` | Tokens per request against none (17,179) |
|---|---|
| Bare-name deny of 15 tools no recorded run used, plus `includeGitInstructions: false` | **-11,700 (-68%)** |
| of which: `Task` (subagents tool and agent list) | -2,503 |
| of which: `Workflow` | -1,947 |
| of which: `ScheduleWakeup` | -1,773 |
| `includeGitInstructions: false` alone | -559 |
| `autoMemoryEnabled: false` (not in the default; owner decision O1) | -744 |
| `disableBundledSkills: true` alone (the master plan's candidate) | **+4,007** |
| deny `Skill` alone | **+3,169** |

- Across all 96 recorded runs the agent called only Bash, Read, Edit and Write (570 tool calls over 618 model requests). The other 16 tools were sent on every request and never used.
- The saving does not depend on the repository: -11,700 on express, -11,652 on attrs. The estimate is calibrated on the metered first request of the same task (17,179 tokens); the same method predicts the recorded Olivium request within 24 tokens (0.1%) and the attrs request within 64 (0.4%).
- Two candidate keys raise cost instead. `disableBundledSkills` and a `Skill`-only deny make the `Workflow` tool description inline skill text. The plan now forbids both and removes `Skill` only together with `Workflow`.

**Forecast (a model, not a measurement).**

| | Tokens against none | Solved |
|---|---|---|
| v2-type tasks (development data; recorded fix-run behaviour plus the measured trim) | median per-task ratio 0.54 (-46%), range 0.32 to 0.76; with 1 extra turn per run 0.62 | 15 of 24, unchanged; up to 19 if the practice rule is obeyed (development data, not evidence) |
| v3-type tasks (guess: 15 turns, 1,500 to 2,500 tokens of context growth per turn) | about -35% central, -15% to -55% range | no basis for a change; expect none |

- The token bar for "dramatic" (-25%) is now likely to be met. Most of that saving is configuration that any user could write by hand. Olivium's contribution there is choosing it per project, measuring it and showing what it removes. The report must say so (section 7.4).
- The behaviour part (fewer lint turns, no refusals, environment facts, locator) is forecast at about -3% to +5% on its own. It is reported separately.
- My guess of the v3 verdict: dramatic gain about 55% (65% if the owner adopts O2); gain with an accuracy warning about 20%; measurable gain about 10%; no demonstrated gain about 10%; failure about 5%. The main threat to "dramatic" is not tokens: it is noise in the solve rate (section 7.5).

---

## 1. Red-team findings and how they were resolved

All measurements: `WORK_ROOT/v3-program/probe/` (scripts, 27 captured sessions, `shape-report.json`) and `WORK_ROOT/v3-program/logs/`. Docker resources used: `olivium-bench-v3probe-*` only, removed afterwards.

| # | Question | Finding | Change to the master plan |
|---|---|---|---|
| R1 | How much prefix can a project setting remove? (item 2) | 11,700 tokens per request, 68% of the first request; 16 of 20 tools were never called | Item 2 becomes the first-ranked item; forecast and gates rewritten |
| R2 | Can a trim key raise cost? | Yes: `disableBundledSkills` +4,007; `Skill` deny alone +3,169 (Workflow inlines skill text) | Both forbidden; `Skill` and `Workflow` always removed together; Gate 0 row 4 tests it |
| R3 | Deny `ToolSearch`? | Denying it leaves a placeholder tool; not denying it, it drops out when nothing is deferred | Never deny `ToolSearch` (also keeps MCP working for users who add servers) |
| R4 | Does SessionStart output reach the first request in `-p` mode? (item 3) | Yes, as `SessionStart:startup hook success: <text>` | UserPromptSubmit fallback removed; stage 0 probe (b) closed |
| R5 | Does UserPromptSubmit output reach it? (item 6) | Yes, as `UserPromptSubmit hook success: <text>` | Probe (c) closed |
| R6 | What does carrying a CLAUDE.md cost? (item 1) | Comment-only file: +1 token. One 85-byte line: +146 tokens, of which about 110 is the wrapper. The wrapper text tells the model the file "OVERRIDE[s] any default behavior and you MUST follow [it] exactly", which explains why listed lint commands were obeyed. The "350-token fixed cost" in U2/D3 included about 150 tokens of a git-attribution reminder that Olivium's settings caused and the none arm's settings removed, plus untracked-file lines in the git status | Price formula in the contract: 0 for comment-only, else 110 + bytes/2.8. v2 fairness note recorded (Olivium carried about 150 extra tokens per turn the none arm did not); lean removes it |
| R7 | Does PostToolUse on Bash carry the exit status? | No exit field (`stdout`, `stderr`, `interrupted` only), and it did not fire for a command that exited 3 | The "skip tests already run" part of item 4 stays deferred; a future design can treat "PostToolUse fired" as success |
| R8 | Do `sed -n` reads trigger path-scoped rules? (reason item 9 was dropped) | Yes: a `paths: lib/**/*.js` rule loaded right after `sed -n 1,5p lib/request.js`, and after Read. D1/D3 inferred the opposite from the documentation | Item 9 stays deferred because its value is small (about -0.4% of v2 tokens), but the stated reason is withdrawn; reopen rule changed (section 3) |
| R9 | Is the 15 s end-of-run gap the Stop hook? | Yes: the Stop hook took 9.3 s in a probe session on express | Item 4 evidence confirmed |
| R10 | Do U2's key numbers hold? | Re-ran `u2_forensics.py`: none 5.75 turns, 114,857 tokens, prefix 84.3% of tokens, first request 16,755 median, 15 of 24 solved; fix run 6.33 turns, 136,294 tokens | No change |
| R11 | Is the trim overfit to the 8 v2 tasks? | It comes from Claude Code's tool list and tool-usage counts, not from any task; same size on two repositories in two languages. No v3 task was read | No change; the deny list is a closed enum in the blueprint, tied to Claude Code 2.1.311 and labelled so |
| R12 | Does it break a rule? | Static settings data, deterministic, no repository code, no atoms. It removes capabilities (subagents, skills, workflows, scheduling, worktrees, notebook editing, background monitor) | Visible in CLI and portal with the list of names and the saving; `standard` one switch away; refused (not silently changed) when the spec has agents or skills; owner decision O3 on subagents |
| R13 | Can the reader tell configuration from behaviour? | The master plan's arithmetic split assumed the trim does not change behaviour; removing tools might | Named secondary "behaviour-only ratio" pre-registered; Gate 1 rehearsal gains a `none-lean` arm (none plus only the lean settings) for $0.60 of development data |
| R14 | Is the verdict table complete? | No: tokens significantly lower with the solve rate outside the -5 point tolerance but not significantly lower fits no row | New verdict "gain with an accuracy warning" (section 7.6) |
| R15 | Is the -5 point solve-rate tolerance achievable? | With 16 tasks x 3 repeats of mid-difficulty tasks, a harness with no effect at all shows a drop beyond -5 points 29% of the time and beyond -10 points 16% of the time (simulation, `logs/forecast.txt`). A true -10 point harm still passes a -10 tolerance 47% of the time | Owner decision O2: keep -5 or move to -10; the design cannot police accuracy to 10 points either way, and the report says so. Until signed, -5 stands |
| R16 | Is v3 still powered? | For tokens the effect is now large; power is no longer the binding limit. For solve rate nothing changes (+30 points detectable, +10 not) | No size change |
| R17 | Is the budget realistic? | Unchanged guesses ($0.18 per run); lean Olivium runs will cost less, because cache reads and cold cache writes shrink | $0.60 moved from reserve to the rehearsal; total still $49.51 |
| R18 | Could the locator merge read turns on larger repositories? | Plausible; the gate stays on development repositories with 150+ source files. Each turn is now about 12k tokens cheaper, so a saved turn is worth less in tokens, but the card is still far below its break-even | No change |
| R19 | Stage 0 platform probes | Probes (a), (b), (c), (d), (e), (f) answered at $0 by this red team | Stage 0 shrinks to the contract (already written) and schema start: 0.5 day |
| R20 | Auto memory | `autoMemoryEnabled: false` saves 744 tokens per request but turns off the user's own cross-session memory in that project | Not in the default lean profile; owner decision O1 |
| R21 | Dollars | Tokens fall far more than dollars: 91% of tokens are cache reads priced at 1/20 of input. Expected dollar saving about -10% to -27% per run | Dollars stay secondary and are explained in the report |

---

## 2. Owner decisions adopted

From master plan section 6.2, as the owner approved:

| # | Decision | How this plan applies it |
|---|---|---|
| 1 | "Dramatic" = tokens at least 25% lower or solve rate at least 20 points higher, fixed before data | Section 7.6; written into `PROTOCOL-v3.md` before the pilot |
| 2 | Spend up to the remaining $49.51 of the $60 cap, later | Not in this workflow. Section 8 |
| 3 | `lean` context profile is the default for solo exports, visible in CLI and portal | Item 2; only measured keys; `standard` one switch away |
| 4 | Remove "read the AI policy first" from CLAUDE.md; show the policy to the human | Item 1, reason code `process_only` |
| 5 | Keep the changelog rule | Item 1; compliance scored as a secondary |
| 6 | Narrow Stop hook | Item 4 |
| 7 | All 8 v2 tasks are development data | Rehearsal only; never quoted as evidence |
| 8 | Keep `/init` as a scored setup | Section 7.2 |
| 9 | Publish whatever the verdict | Section 7.6 |
| 10 | Regenerate `v1alpha2` previews | Diagnostic `preview_regenerate`; `v1alpha1` untouched |

New decisions only the owner can make (section 11): O1 auto memory, O2 solve-rate tolerance, O3 subagents in lean.

---

## 3. The items, ranked by expected effect

Numbers: one recorded turn = 20,616 tokens and $0.0086 (U2). Each item keeps the master plan's id. Acceptance has a $0 step (replay, mock session or request capture) and a paid step. Unit-test counts are not acceptance.

| Rank | Item | Expected effect on tokens | On solved | Risk |
|---|---|---|---|---|
| 1 | 2. Lean context profile | -11,700 per request; -46% (v2 model), about -35% (v3 guess) | none expected | capability removed for that project (visible) |
| 2 | 1. Lean root file with inclusion test | -5% to -13% against the fix run; about 0 against none | none | a useful line withheld (reported) |
| 3 | 3. Environment facts at session start | -1% to -3% | none | none when silent |
| 4 | 5. Refusal text and replay gate | -1% to -2%; insurance against the 35-refusal first run | none | none (text only) |
| 5 | 4. Quiet, narrow Stop hook | 0 tokens; -10 to -25 s per run; protects against blocks on suites that fail in a fresh container | 0 to +1 point | a regression outside changed and paired tests is not caught at stop |
| 6 | 6. Prompt-time locator card (gated) | v3 guess 0 to -3 turns of about 15 | 0, small chance of help on multi-file fixes | a wrong pointer distracts; gate controls it |
| 7 | 7. Practice rules | +0.5% where it fires | only lever: up to +6 of 24 on v2 (development data) | designed from data that is now development data |

### Item 2. Lean context profile (rank 1)

- **Mechanism.** `spec.context` (contract section 5) selects `lean` or `standard`. `lean` renders `"includeGitInstructions": false` and bare-name deny rules for `CronCreate`, `CronDelete`, `CronList`, `EnterWorktree`, `ExitWorktree`, `ListAgents`, `Monitor`, `NotebookEdit` (kept when `*.ipynb` is tracked), `ReportFindings`, `ScheduleWakeup`, `SendMessage`, `Skill`, `Task`, `TaskStop`, `Workflow`. Never `disableBundledSkills`, `skillOverrides` or a `ToolSearch` deny.
- **Evidence.** Section 0 table. Request capture files: `probe/captured/{none,rec,oliviumfix,oliviumrec,...}/req-*.json`.
- **What the user loses.** Subagents, skills, workflow scripts, scheduled wake-ups, worktrees, notebook editing, background monitoring, git commit and pull-request guidance (git commit and push are already denied in solo mode). Bundled skills stay reachable to a human through `standard`.
- **Version dependence.** Tool names and sizes are those of Claude Code 2.1.311. A newer version may add tools the table does not name; they are then simply not removed. The CLI prints "measured on Claude Code 2.1.311".
- **Acceptance, $0.** Request capture on the generated export of every development repository and, after the freeze, of every v3 export: first request at most none minus 10,000 tokens; `standard` at most none plus the CLAUDE.md price plus 100. A test that adds each deny name alone and in the shipped set shows no shipped combination raises the request. `permcheck` and the unsafe list still blocked 100% with the merged deny list.
- **Acceptance, paid.** Rehearsal: Olivium mean tokens at most 0.80 x none on v2 tasks; `none-lean` against none shows whether removing tools alone changes turns. v3: behaviour-only ratio reported (section 7.4).

### Item 1. Lean root file with an inclusion test (rank 2)

As the master plan, with these corrections:
- Price shown to the user: 0 tokens when only HTML comments remain (measured +1), else 110 + bytes / 2.8 per request.
- Reason codes: `default_guessable`, `process_only`, `tool_unverified`, `scoped`, `over_budget`, `import_marker` (contract section 6). The old `dropped` key is replaced.
- Fixed line kept: "Lint and format run automatically when you finish. Do not install or download tools." (+146 tokens per request, measured as a one-line file).
- Acceptance, $0: unchanged (at most 600 bytes; no process-command line; every withheld line reported; C13 and C14).

### Item 3. Environment facts at session start (rank 3)

As the master plan. Delivery confirmed in `-p` mode, so the UserPromptSubmit fallback is dropped. The script uses only `command -v` and `test -x`; probe names come from `spec.project.tools` (contract section 3). Silent when everything resolves.

### Item 5. Refusal text and replay gate (rank 4)

Unchanged. The replay gate must also run the merged lean deny list: a bare tool deny must not refuse any recorded Bash, Read, Edit or Write call.

### Item 4. Quiet, narrow Stop hook (rank 5)

Unchanged in design; the 9.3 s probe measurement confirms the target. File arguments and selectors are fixed in the contract (section 2).

### Item 6. Prompt-time locator card, gated (rank 6)

Unchanged gate (development repositories only, 150 or more source files, 30 issues, top-3 hit at least 70%, wrong card at most 15%, at most 600 bytes, under 2 s). UserPromptSubmit delivery confirmed. If the gate fails, the hook is not built and the rest proceeds.

### Item 7. Practice rules (rank 7)

Unchanged. The only accuracy lever; labelled as designed on development data.

### Deferred and rejected (changes only)

| Idea | Status | Reopen when |
|---|---|---|
| Path-scoped rules with companion hook (item 9) | Deferred; the "sed reads do not trigger" reason is withdrawn (R8) | After v3, if a mock session shows compound reads (`grep ... \| sed`, `cd dir && cat file`) also trigger, and withheld `scoped` lines are common in development repositories |
| `disableBundledSkills`, `skillOverrides`, `Skill`-only deny | Rejected | Never while `Workflow` inlines skill text |
| `autoMemoryEnabled: false` | Not in the default | Owner decision O1 |
| Everything else in master plan section 1.5 | Unchanged | Unchanged |

---

## 4. Lanes and file ownership

Copied from master plan section 2.1. Changes: lane G also owns the `context_profiles` blueprint block and the deny-name enum; lane A renders them; lane B ports the probe's request-shape capture into the mock meter.

| Lane | Owns, stages 0 to 2 | Owns, stage 3 |
|---|---|---|
| **G: generator content** | `lib/harness_forge/analyzers/{commands,mapping,history,instructions,repository,inventory,stack}.ex`; new `analyzers/practices.ex`; `lib/harness_forge/generation/{spec,guidance,profile,blueprint}.ex`; new `generation/economy.ex`; `priv/schemas/{repository-signals-v1,repo-profile-v1,harness-v1alpha2}.json`; `priv/blueprints/*.json` (including new `context_profiles`); `examples/profiles/*.json`; tests under `test/harness_forge/analyzers/`, `test/harness_forge/analyzers_git_boundary_test.exs`, `test/harness_forge/generation/{guidance,generation,blueprint}_test.exs`, `test/harness_forge/foundation_contracts_test.exs` | `bench/value/analyze.py`, `bench/value/test_analyze.py`, `bench/value/lib/{transcript,trials}.py`, `bench/value/grade/*` |
| **A: adapter runtime** | `lib/harness_forge/adapters/claude_code.ex`; new `adapters/claude_code/hooks.ex`; `adapters/claude_code/guard.ex`; `test/harness_forge/adapters/claude_code_v2_test.exs` and a new hooks test file | `bench/value/run.py`, `bench/value/arms/*`, `bench/value/lib/{common,session,dockerops}.py` (handed over from lane B) |
| **B: evidence and benchmark** | `bench/value/meter/*` (request-shape record, ported from `WORK_ROOT/v3-program/probe/{capture,shape}.py`); `bench/value/lib/{mockplans,meterctl}.py`; `bench/value/run.py` (mock scenarios only, until handover); new `bench/value/replay/*.py`; `bench/e2e-cli.sh`; `bench/e2e.cjs` | `bench/value/corpus/**`, `bench/value/docker/**`; new `bench/value/PROTOCOL-v3.md`, `PROTOCOL-v3.sha256`, `corpus/dev-repos-v3.txt`; `bench/value/README.md` |
| **Root coordinator** | `lib/harness_forge/compiler.ex` (version only); `lib/harness_forge/cli.ex` and `lib/harness_forge_web/live/generate_live.ex` (CLAUDE.md price, context profile with removed names, `--context` switch); all goldens under `test/harness_forge/generation/golden/` (`UPDATE_GOLDEN=1` only); `bench/run.sh`; `mix.exs`, config, router, application, migrations; `CHANGELOG.md`, `docs/claude-code-connector.md`; `WORK_ROOT/v3-program/contract.md` | Gate runs, generator freeze, benchmark runs, report |

Every lane: `TMPDIR=WORK_ROOT/v3-program/tmp` and its own `MIX_BUILD_PATH=WORK_ROOT/v3-program/build/<lane>` for every mix command. No git commit, add, push, stash, reset or checkout.

---

## 5. Stages and integration points

| Stage | Lane G | Lane A | Lane B | Ends with |
|---|---|---|---|---|
| **0. Contract** (0.5 day) | Schema additions from the contract; start item 1 | Start item 4 and item 5 text against the contract fixture | Port request-shape capture into the meter (`shape` mock scenario) | Coordinator confirms the contract; the six platform probes are already answered |
| **1. Remove the harm, ship the trim** | Item 1; `spec.project.tools`, `test_pairs`, `cochange`; `spec.context` and blueprint `context_profiles` | Item 2 rendering; item 4; item 3 on SessionStart; item 5 | Replay gate (including the lean deny list); counterfactual model; context-cost check; e2e changes; development issue set and locator replay | **Integration point 1**: versions bumped, goldens regenerated, `mix test`, `bench/run.sh`; request shape re-measured on real exports |
| **2. Add the gain** | Item 7 | Item 6, only if the locator gate passed | v3 selection tooling; yield rehearsal | **Integration point 2**: same checks; full Gate 0 |
| **3. Benchmark tooling** | Metrics: behaviour-only ratio, subagent use, new verdict row | Runner: `--protocol 3`, pilot mode, refusal of single-setup scored runs | Candidate walk and Docker validation; `PROTOCOL-v3.md` | **Integration point 3**: generator freeze, then paid steps (separate owner action) |

Version identifiers bumped once per integration point: compiler `template_version` (`compiler.ex:29`), adapter `@v2_mapping_version` (`claude_code.ex:39`), each blueprint `version`.

---

## 6. Gates

### Gate 0 ($0), all rows must pass

| # | Must be true | Shown by |
|---|---|---|
| 1 | Canonical and end-to-end suites pass | `mix test`; `bench/e2e-cli.sh` C10 to C22; `bench/e2e.cjs`; `bench/run.sh` four stages |
| 2 | Exports deterministic | C14; 8 v2 arms and 5 development repositories generated twice, byte-identical |
| 3 | Root file lean | Context-cost check: at most 600 bytes, no process-command line, every withheld line reported with a reason code |
| 4 | **Changed.** Lean first request at most none minus 10,000 tokens; `standard` at most none plus CLAUDE.md price plus 100; no shipped key combination raises the request | `shape` mock scenario, real Claude Code headless, per setup and per development repository |
| 5 | Each hook delivers in headless mode and is silent with nothing to say | `envcheck`, `locate`, `gold`, `hookfail` scenarios |
| 6 | Stop hook adds under 5 s on a passing run and still blocks a failing changed test | `gold`, `hookfail` wall times |
| 7 | Zero refusals of normal work, including by the lean deny list | Replay of about 570 recorded calls; 0 Stop blocks on the 96 final patches |
| 8 | Safety intact | `permcheck` and the unsafe list 100% blocked; normal list 0 blocked |
| 9 | Locator gate passed, or the hook is left out | Locator replay report (may fail without stopping the plan) |
| 10 | Practice thresholds fixed on development repositories | Detector report; patch classifier 12 of 12 |
| 11 | **Changed.** Counterfactual on the 24 recorded fix runs: behaviour part at most +3% against none; with the measured trim, median per-task ratio at most 0.65 | `probe/forecast.py` successor in `bench/value/replay/`, labelled a model |
| 12 | v3 tooling works end to end | Yield rehearsal; protocol-3 dry run on 2 tasks x 3 setups with the mock meter |
| 13 | Protocol frozen; owner signed the bar, the spend, O2 | `PROTOCOL-v3.sha256`; generator commit and digest |
| 14 | **New.** The removed tool names and the saving are visible | `bench/e2e-cli.sh` C17 (settings) and `bench/e2e.cjs` (generate page shows profile, names, saving, `standard` switch) |

Any failed row (except 9) means a repair loop, not a paid run.

### Gate 1 (paid rehearsal, at most $2.60, development tasks only)

40 runs, interleaved: the 8 v2 tasks x `none`, `olivium` x 2 repeats (32 runs), plus `none-lean` x 1 repeat (8 runs). Go on only if:
- refusals of normal work: 0;
- "tool not installed" results with Olivium not more than with none;
- Olivium mean tokens at most 0.80 x none, and mean turns at most none + 0.3;
- every hook fired as designed; no unrelated file in any patch;
- for information: `none-lean` turns against none; deprecation compliance on werkzeug-3266 and -3273.

One repair and one repeat from the reserve; a second failure goes to the owner.

---

## 7. Benchmark v3 rules

### 7.1 Selection

Master plan section 3.1 unchanged: R1 to R6, T1 to T6, difficulty filter from no-harness runs only, yield fallbacks (floor 12 tasks), freeze order. Nothing in the generator reads a candidate task.

### 7.2 Setups and size

16 tasks x 3 setups (`none`, `generic` = `/init`, `olivium` = unmodified export with its own settings) x 3 repeats = 144 scored runs. Claude Code 2.1.311 pinned in every image. Same model, prompt, limits; shuffled, interleaved order. Size rule: above $0.18 per run cut tasks to 12; under $0.12 raise to 24.

### 7.3 Protocol changes against v2

Master plan section 3.5 items 1 to 10, plus:
11. After the freeze, the free request capture records each task's per-request trim (none first request minus Olivium first request) into the run directory before the pilot. It does not change the export.
12. Subagent use (Agent tool calls and their tokens) is reported per setup.

### 7.4 Named secondaries added

- **Behaviour-only ratio**: per task, (Olivium tokens + trim x Olivium turns) / none tokens, median across tasks, same two tests. This is what Olivium's text and hooks did, apart from the configuration.
- **Dollars per run**, with the note that tokens are 91% cache reads at 1/20 of the input price.

### 7.5 What noise allows

- Tokens: a 25% saving is detected with 99% power (v2 noise) or 83% (pessimistic); the forecast is larger.
- Solve rate: 16 x 3 detects +30 points (0.91); not +10 (0.20). A harness with no effect shows a drop beyond -5 points 29% of the time, beyond -10 points 16% of the time.

### 7.6 Success table (fixed before data)

Primary: tokens per run (median of per-task ratios of means) and solve rate (mean of per-task differences), Olivium against none. A primary "passes" when the 95% bootstrap interval (10,000 resamples, fixed seed) excludes zero and the two-sided exact sign-flip test gives p < 0.05. Tolerance T = 5 points (or 10 if the owner signs O2).

| Verdict | Rule | What follows |
|---|---|---|
| **Dramatic gain** | Tokens at least 25% lower and passing, or solve rate at least 20 points higher and passing; the other primary within tolerance (tokens at most +5%; solve rate at least -T points and not significantly lower) | Publish; claim limited to one model, one agent, these task rules; headline carries the behaviour-only ratio and the configuration share |
| **Gain with an accuracy warning** (new) | A primary passes; the other is outside its tolerance but not significantly worse | Publish with the warning in the headline; no "dramatic" wording |
| **Measurable gain** | One primary passes below the dramatic bar; the other within tolerance | Publish |
| **No demonstrated gain** | Neither primary passes | Publish; stop spending on generated context text; next effort: human-reviewed claims and the free safety suite |
| **Failure** | Tokens significantly higher, or solve rate significantly lower, or more than 1 refusal of normal work per 10 Olivium runs | Publish; revert the defaults that caused it |

Secondary comparison: Olivium against `/init` on both primaries, same tests. Context-use outcomes: tokens in the first request, tokens before the first edit of a really-fixed file, largest context reached.

---

## 8. Budget (remaining $49.51 of the $60 cap; spent later, not in this workflow)

| Item | Size | Cap |
|---|---|---|
| Paid rehearsal (development data) | 32 runs at about $0.058 plus 8 `none-lean` runs at about $0.04 | $2.60 |
| Pilot stage 1 (`none`) | up to 48 candidates at about $0.10 | $5.00 |
| Pilot stage 2 (`none`, 2 more runs) | up to 22 candidates x 2 at $0.18 | $8.00 |
| `/init` files | 16 tasks at about $0.10 | $2.00 |
| Canary | 1 task x 3 setups, not scored | $0.60 |
| Scored run | 144 runs at $0.18 (Olivium runs likely cheaper) | $25.91 |
| Reserve, untouched | | $5.40 |
| **Total** | | **$49.51** |

A benchmark bug found after the scored run starts voids all scored runs; a redo needs new money.

---

## 9. Success table for the program

| Outcome | Target | Measured how |
|---|---|---|
| Gate 0 | all rows pass | section 6 |
| Lean first request | at most none minus 10,000 tokens on every development repository and every v3 export | `shape` scenario |
| Rehearsal | 0 refusals; tokens at most 0.80 x none; turns at most none + 0.3 | Gate 1 |
| v3 tokens | at least 25% lower (owner bar) | section 7.6 |
| v3 solve rate | within tolerance and not significantly lower | section 7.6 |
| Behaviour-only ratio | reported, with its own interval; no target | section 7.4 |
| Refusals of normal work | at most 1 per 10 Olivium runs (target 0) | runner counts |
| Safety | unsafe list 100% blocked in every setup | free suite |

---

## 10. Timeline

Effort: about 165 engineer-hours likely (lane G 50, lane A 60, lane B 55), about 290 worst case. Calendar in working days with three lanes; agents running around the clock may compress the build stages, not gates, Docker validation or benchmark runs.

| Step | Expected | Worst case | What makes the worst case |
|---|---|---|---|
| Stage 0: contract and schema start | 0.5 day | 1 day | Contract dispute between lanes G and A |
| Stage 1: items 1 to 5 | 2.5 days | 5 days | Schema and golden churn; the 1,296-line adapter test |
| Stage 2: items 6, 7, selection tooling | 2.5 days | 5 days | Bounded source reader review; install recipes |
| Stage 3 and Gate 0, with repair | 1.5 days | 4 days | Two repair rounds |
| Candidate walk and validation (overlaps stage 3) | 0.5 day | 2.5 days | Low yield; fallbacks |
| Gate 1 rehearsal and review | 0.5 day | 1.5 days | One repair and repeat |
| Pilot and manifest freeze | 0.5 day | 1.5 days | Runs hit the 20-minute limit |
| Exports, canary, scored run | 0.5 day | 1.5 days | Infrastructure retries |
| Analysis and report | 0.5 day | 1.5 days | |
| **Total** | **about 10 working days** | **about 24 working days** | A voided scored run adds about 2 days and needs new money |

---

## 11. Open decisions for the owner

| # | Decision | Recommendation | Effect |
|---|---|---|---|
| O1 | Add `autoMemoryEnabled: false` to `lean` | No: it turns off the user's own cross-session memory in that project | -744 tokens per request (about -4%) if yes |
| O2 | Solve-rate tolerance for "dramatic": -5 points (master plan) or -10 points | -10, signed before any v3 data, with the report stating that the design cannot rule out a drop under about 25 points | Under no true effect, "dramatic" is blocked by noise 29% of the time at -5, 16% at -10 |
| O3 | Keep `Task` (subagents) in the lean deny list | Yes: 0 uses in 570 recorded tool calls; `standard` keeps it | -2,503 tokens per request; on large repositories the agent searches itself instead of delegating |

Lanes implement the recommendations; each is a one-line data change before the freeze.

---

## 12. Evidence appendix

All local; no third-party code was copied.

| Source | What it supports |
|---|---|
| `WORK_ROOT/v3-program/probe/capture.py`, `run_probe.py` | $0 request capture: real Claude Code 2.1.311 in `olivium-bench-agent-expressjs-express-7366:v1` and `olivium-bench-agent-python-attrs-attrs-1593:v1`, internal network, scripted replies, dummy key |
| `WORK_ROOT/v3-program/probe/variants/*/settings.json` | The 27 settings and arm variants tested |
| `WORK_ROOT/v3-program/probe/captured/*/req-*.json` | The captured request bodies |
| `WORK_ROOT/v3-program/probe/shape.py`, `shape-report.json`, `logs/probe-shape.txt` | Per-variant sizes; calibration 2.775 characters per token on the metered 17,179-token request |
| `WORK_ROOT/v3-program/probe/out/{hooks,pt_exit,rules_sed,rules_read,oliviumfix}/` | Hook delivery, PostToolUse payload, scoped-rule loading, Stop hook duration (transcripts) |
| `WORK_ROOT/v3-program/probe/forecast.py`, `logs/forecast.txt` | Counterfactual ratios, v3 extrapolation, solve-rate noise simulation |
| `WORK_ROOT/v3-program/logs/u2-recheck.json` | Re-run of `plan/u2_forensics.py` over the 96 recorded runs |
| `WORK_ROOT/value-v2-2026-11-09/trials/*/meter_rows.jsonl`, `transcript.jsonl` and the same under `value-v2-2026-11-10-fix/` | Recorded tokens, turns (618 requests), tool calls (570), the 20-tool init list |
| `plan/S-master-plan.md`, `U1` to `U4`, `D1` to `D3` | Original design, generator map, forensics, external studies, benchmark design |
| Claude Code 2.1.311 binary strings in the agent image | The settings keys `includeGitInstructions`, `disableBundledSkills`, `skillOverrides`, `autoMemoryEnabled` exist in this version |

Commands used (all $0):

```
python3 -I WORK_ROOT/v3-program/plan/u2_forensics.py WORK_ROOT/v3-program/logs/u2-recheck.json
python3 WORK_ROOT/v3-program/probe/run_probe.py none none2 git skills memory deny16 denynots plugins lean commentonly oneline hooks oliviumfix
python3 WORK_ROOT/v3-program/probe/run_probe.py rec agentname taskname skillonly workflowonly schedonly rec_keepagent oliviumrec oliviumrec_lean
python3 WORK_ROOT/v3-program/probe/run_probe.py pt_exit rules_sed rules_read
PROBE_IMAGE=olivium-bench-agent-python-attrs-attrs-1593:v1 PROBE_PROMPT=.../python-attrs-attrs-1593.none.r1/prompt.txt python3 .../probe/run_probe.py none_attrs rec_attrs
python3 WORK_ROOT/v3-program/probe/shape.py <variants>
python3 -I WORK_ROOT/v3-program/probe/forecast.py
```

Every probe session exited 0. The probe container and network (`olivium-bench-v3probe-capture`, `olivium-bench-v3probe-net`) were removed afterwards; no other Docker resource was touched.

What this plan does not establish: that the agent behaves the same without the removed tools on large repositories (the rehearsal's `none-lean` arm and the v3 behaviour-only ratio address it); any effect on accuracy; anything about other models, agents, team mode or other Claude Code versions.

---

## 13. Status, 2026-11-11 (integration point 2, root coordinator)

Decisions below were adopted by the coordinator under the owner's general go-ahead. They are not owner signatures.

- **Gate 1 (paid rehearsal): GO.** 40 runs, $1.761818. Program spend $12.251818 of $60. Olivium mean tokens 0.390 x none (median per task 0.363); turns 5.06 against 5.69; 0 refusals; 0 Stop blocks. The R5b ruling (a comment edit in werkzeug-3266 is part of the fix) was accepted. These are development tasks and are not evidence of value.
- **Changes at this point:** template `v1alpha2.3`. The Stop hook runs only the changed test files (at most 3); history pairs are no longer run, because the strongest pair added 2 to 30 s to a passing stop. Cost: a regression in an unchanged test is not caught at stop, and the two true-positive gold blocks on werkzeug-3266 and -3273 are gone. Lines about tox, nox, flake8, pylint, pycodestyle or virtual environments, and every line of a pull request or issue template, are now withheld as process lines.
- **Gate 0:** rows 1 to 8 and 10 to 14 pass; row 9 is omitted (no locator card this round). Two readings were adopted by the coordinator:
  - Row 4, `standard` part: fails as written on 8 of 8 tasks, by the attribution reminder (about 210 tokens) that Claude Code adds when `includeCoAuthoredBy` is unset. The no-harness arm sets it to false. With that one key equalised, it passes on 8 of 8. The scored `lean` profile is not affected.
  - Row 6: 20 of 22 paired mock repeats added under 5 s. The two above 5 s (+6.7 s and +5.8 s) were measured under a load average of 24 to 37. On reruns of those two tasks, 6 of 6 repeats added +0.8 to +1.6 s.
  - Row 1: `mix test` on the frozen bytes passed in full (1825 tests, 0 failures) at a load average of 4 to 8. Earlier full runs under higher load failed 1 to 7 tests, all on short fixed timeouts in web and Codex-runtime tests that do not call the generator.
- **Generator frozen by content digest** (nothing is committed): `lib`, `priv`, `bin` and `mix.lock`, 394 files, `bca293410b53231ed1a904292d47475fadca9bbb02563636df28c9bca6a3c4d3`. The per-path digests are in the change log of `bench/value/PROTOCOL-v3.md`. No generator change is allowed before the scored v3 run.
- **Still unproven:** any value on v3 tasks. On the rehearsal, olivium against `none-lean` (trim only) has a median ratio of 1.175 on one repeat. The token saving so far comes from the settings trim, not from the harness text. The v3 pool holds 11 of the 24 tasks needed, and the walk is still running.
