# Changelog

This candidate is unpublished; the application version is 0.1.0.

## Unreleased

### Benchmark (2026-11-14, re-run of the 8 v2 tasks)

- Published `docs/benchmarks/value-v2r-2026-11-13/` (`results.json`, `provenance.json`):
  96 paid runs under `bench/value/PROTOCOL-v2r.md`, 4 setups × 8 development tasks × 3
  repeats, $5.507054 metered. Default export minus no harness: −53,197 tokens per run
  (95% interval −72,241 to −16,825), cost −$0.0039 (−$0.0093 to +$0.0162), solved 18 vs
  15 of 24 with a per-task median difference of 0. Against `--native none`, no
  difference could be told from zero; generated skills were called in 6 of 24 runs and
  subagents in none. The tasks are not held out. README, `website/value.html` and a
  dated note on `website/benchmark.html` updated; program spend is $33.00 of $60 (including a $0.07 real `learn` check).

### Fixed (2026-11-14, review repair)

- Test runner guard: a test file the runner adds must be a relative path in the
  project. An absolute path (such as a file put in `/tmp`), a `~` path or a `..` part
  is refused, so `npm test -- /tmp/x.test.js` no longer runs a file from outside the
  project. The replay oracle already labelled such calls `runner_scope`.
- `npm test` with a direct `mocha`, `jest` or `vitest` script: the `npx <tool>` form is
  now given only when the script has no `pre`/`post` script, shell operator, quote,
  variable, `--` or watch flag, as for the file form. `jest && node scripts/cleanup.js`
  and `vitest run` with a `pretest` script now give `runner_command_unsuitable` instead
  of `npx jest` and `npx vitest run`. `bench/e2e-cli.sh` C33 checks both and a plain
  `jest` script.
- Learned skills: a symbol `Owner.member` is placed only inside the class row named
  `Owner`; a plain name only at a definition no class encloses. Adjacent definitions
  (`@overload` stubs and then the implementation) give the implementation. A name with
  separate definitions, in one file or several, is left without a location instead of
  pointing at the first match. On the real click bundle, `Option.get_default` now
  points at `core.py:3223-3255` and `Parameter.get_default` at `2473-2506` (was the
  stub at 2464-2468 for both).
- Learning: the learner, meter, network and verification containers get a random
  per-run suffix, so two `learn` runs on the same repository and commit no longer
  remove each other's containers. The meter's `run_id` is unchanged.
- `CLAUDE.md`: a line that repeats a kept line (code spans that are a subset of the
  kept line's or the other way round, and a shared word, with "modify" and "alter"
  counted as "edit") is withheld as `duplicate`, and a code example with at most one word outside its code
  spans as `no_subject`. Both codes appear in `withheld_counts` only when used. mocha's
  default `CLAUDE.md` drops from 5 lines to 2 (the repeated generated-file and
  `AGENTS.md` lines, and the `require(...)` example whose context line was scoped).
- Replay gate: entries naming `{runner}` are replayed once per allowed runner command,
  so the one-file form (`npm test --`) is checked as well as the suite form. The gate
  also fails when the oracle labels a synthetic normal call (`normal_labelled`). It
  checks that every unsafe entry is refused and carries its expected oracle labels; it
  does not check that the refusing layer is the one a label implies (`unsafe_rows`
  lists both). Synthetic call list version 5 adds ru11 to ru15 (a `/tmp` test file, a
  `..` path, `--require=`, `--import` and another package script).
- Benchmark docs: `bench/value/README.md` uses placeholder paths
  (`/path/to/new-empty-dir`, `/path/to/key-dir/anthropic.key`). The README links the
  site copy of `PROTOCOL-v2.md`, which differs from the pre-registered original only in
  two output directories. The site copy of the value-v2 `evidence/index.json` is again
  byte-identical to the repository file.

### Fixed (2026-11-14, skills and subagents from git history)

- Test runner for package scripts: when an `npm`, `pnpm` or `yarn` test script is one
  direct call of a test tool that takes files (`mocha`, `vitest`, `vitest run`, `jest`,
  `ava`, `tap`, `node --test`) with only plain flags, reached directly or through at
  most two `npm run` hops, the runner runs it on one file as `npm test -- <file>`
  (`npm run <script> -- <file>`; `pnpm`/`yarn` without `--`). Scripts with shell
  operators, wrappers, `pre`/`post` scripts or that name a slice of the suite
  (`test:browser`, `test-coverage` and similar) still give `runner_command_unsuitable`.
  CI commands run in a `working-directory` other than the root are no longer test
  command candidates. The guard's flag list is unchanged. axios now gets
  `npm run test:vitest:unit -- <file>`; mocha still gets no runner (its scripts go
  through `cross-env`, `nyc` and `run-s`).
- Built-in subagents: a lean export that keeps `Task` now denies `Agent(Explore)`,
  `Agent(general-purpose)` and `Agent(statusline-setup)`, which takes 971 bytes
  (about 395 tokens) off every request; `standard` keeps them. `context.disable_builtin_agents`
  is `true` in that case, and `native.cost.builtin_agents_denied_tokens`,
  `native.builtin_agents_denied` and `native.builtin_agents_denied_tokens` report it.
  The CLI's subagent line and the portal say which built-in subagents are denied and
  what that saves, or that they stay listed. Estimates on the end-to-end fixture:
  3,229 tokens per request (was 3,624), lean saving 8,873 (was 8,478). Measured
  first-request difference against `--native none`: 8,777 bytes, about 3,231 tokens.
- Area skills: tests with no joint change in history are listed under "Tests linked
  by name (no joint change in history)", never under "Tests that history pairs with
  them". After the body is cut to fit, the description and closing line are chosen
  from what is left, so a description no longer promises tests or past fixes the body
  lacks. Section headings are never cut on their own.
- `CLAUDE.md`'s `Test:` and `Test one:` lines and the test runner name the same
  commands.
- Replay gate: the policy oracle labels test-runner calls outside the runner's
  commands (`runner_scope`) and files in secret directories (`.ssh`, `.aws` and
  similar, `~` paths included), so ru01, ru02, ru03 and ru07 carry their expected
  labels. The gate also fails when an unsafe entry lacks its
  expected oracle labels (`unsafe_expected_not_labelled`) and reports each unsafe
  entry's layer and labels (`unsafe_rows`). Synthetic call list version 4 (ru04's
  label renamed `secret`).
- `bench/native/probe.py` checks E-N1 (built-in subagents listed exactly when not
  denied; an `Explore` call refused by `Agent(Explore)`), E-N7 (the test runner stops
  at its `maxTurns`, 8 requests for a 20-step plan) and E-N8 (an export with three area
  skills has three `Skill(<name>)` rules and each skill launches with no permission
  denial). `bench/native/fixture.sh` takes an optional AREAS=3 argument for E-N8.
  `bench/e2e-cli.sh` C27 to C30 expect the deny rules and the new figures; C32
  checks the runner on a synthetic Node repository with decoy scripts and a CI job in
  a subdirectory.
- python-jsonschema still gets nothing (`gate_failed`): within the 3-year window no two
  source files changed together more than 2 times (4 needed), it has 14 source files
  (40 needed for the locator) and no detected test command. The gates were not
  loosened.

### Added (2026-11-13, skills and subagents from git history)

- `generate --native all|skills|agents|none` (default `all`; `none` for `lean-x`)
  and the portal's "Skills and subagents" select. The CLI prints one line per skill
  (bytes listed on every request, bytes loaded on use) and per subagent (its tools),
  and the estimated tokens they add to every request, measured on Claude Code
  2.1.311; with none it prints the reasons. `--json` gives `result.native` and the
  context's `kept_tools`, `disable_bundled_skills` and `disable_builtin_agents`. A
  bad `--native` value is a usage error (exit 2). The lean saving shown is the
  measured figure for the tools kept, less the listing, not 11,700.
- End-to-end checks on a synthetic Python repository with fixed history:
  `bench/e2e-cli.sh` C25-C30 (file contents and limits, evidence commits, repeat
  byte-identical, each `--native` mode, allow and deny differences, the replay gate
  with test-runner calls, text lines), `bench/e2e.cjs` B23 (portal list equals the
  CLI JSON and digest), and `bench/e2e-learn.sh` L-N1 to L-N4 (learned items).
- `bench/native/probe.py`, the opt-in `BENCH_STAGES=e2e-native` stage: real Claude
  Code in Docker, on an internal network whose only other member is the mock meter,
  checks the listing, the cost
  estimate (within 20%), skill loading on use, each subagent's tool limit, the guard
  on the test runner and a session with no permission denial. It costs $0.
- `bench/value/meter/meter.py --plan-any-tools` (mock mode only) lets a scripted
  plan drive a subagent. The replay gate's synthetic call list is version 3, with
  test-runner calls (6 normal, 6 to refuse) when the export has a test runner.
- `learn`: learner prompt v2 proposes area skills and locator or test-runner
  subagents as data only (paths, tests, symbols, command ids, evidence commits). Each
  is checked against the paths and evidence at the base commit; a test runner keeps
  only commands that ran in Docker with network none (`not_verified` otherwise).
  Bundles always carry sorted `skills` and `agents`; bundles written by prompt v1
  still validate. The learn summary reports skills and agents kept and dropped.
- `lean-ai`: learned skills and agents go to the generator as candidates with
  origin `learned`, with located symbols, paired-test support and linked pitfall
  notes. A learned area that overlaps a history group is merged into it. Items whose
  paths are missing at HEAD are dropped and counted, never repaired; a candidate the
  generator rejects is reported as `learned_native_invalid`.

### Changed (2026-11-13, repair after review)

- Shallow clones: a shallow clone that holds at least 200 commits is now graded like
  a history cut off at the commit limit, so it gets skills and subagents. With fewer
  commits it gets none, and the `native_none_generated` notice says to run
  `git fetch --unshallow`. The analyzer still never fetches. The source-test pairs
  (the test-runner gate and the stop hook's `.olivium/test-pairs.tsv`) are graded the
  same way; the other history signals (and so `CLAUDE.md`) are unchanged for shallow
  clones.
- History evidence: only focused changes (2 to 25 files) count toward a group, and
  formatting, linting, version-support drops, migrations, version bumps and
  `style`/`chore`/`ci`/`build`/`docs` commits do not count. File names follow renames
  to their current names, so a renamed test keeps its pairing. Past fixes exclude
  merge commits and documentation or CI fixes.
- A commit subject or file name that holds git log record separators can no longer
  forge a record: every parsed record must match a hash from a second, hash-only
  `git log`, occur once and come in history order; others are dropped.
- Area skills: each past fix lists the files it changed (cluster files, then tests).
  A repository rule from its own instruction files (`auto` bucket, the same rules
  `CLAUDE.md` takes) that names one of the area's files is added as `Project rule:`
  (at most 2, each at most 240 bytes). The fragile-file line gives the file's fix
  count, and a follow-up fix counts only when it changes one of the same tests.
  Names skip `src`, `lib` and similar directories and drop every extension
  (`index.d.ts` gives `index`). Tests a learner linked (no joint changes) are listed
  as "Tests linked to them:", and a skill without past fixes no longer promises them
  in its description.
- Test runner: written only when a command can run one test file (the test tool
  itself, such as `pytest` or `npx vitest run`, never a package script such as
  `npm run test-browser`); otherwise dropped with the new reason
  `runner_command_unsuitable`. The guard now refuses any flag the runner adds
  except a fixed list of output and selection flags, and any word with `=` or a
  leading `@` (`pytest -p plugin`, `--config`, `@argsfile`).
- Locator: written only with a co-change group strong enough for an area skill;
  layout rows alone no longer keep `Task` (and the built-in subagents it lists).
- Permissions: the export allows `Skill(<name>)` for each generated skill instead
  of the bare `Skill` tool, so a skill the repository, a plugin or a session adds
  still asks. With generated items, the guard also protects
  `.claude/skills/olivium-*` and `.claude/agents/olivium-*` (and moving the
  `.claude/skills` or `.claude/agents` directory) like the settings and hooks.
- The CLI (`subagents` line) and the portal now say that each subagent call costs
  about 3,472 to 4,582 tokens per turn of its own (measured 8,540 to 11,271 bytes per
  subagent request), outside the per-request figure, and that this figure includes
  Claude Code's built-in subagents. `result.native.subagent_turn_tokens` carries it.
- Tests: `bench/native/fixture.sh` adds a hostile commit (forged record separators,
  `---`, backticks and `$(...)` in its subject; file names with a quote, a newline
  and an `@`); C25 checks none of it reaches the export and that every listed fix
  changed the files it names. C28 expects one `Skill(<name>)` rule per skill. C31
  generates from two shallow clones (10 commits, and 228 of 229 after 200 filler
  commits); the long one must get the area skill, the locator and the test runner. The replay gate's
  synthetic list adds ru07 to ru10.

### Changed (2026-11-13, integration)

- The generator no longer writes `env.CLAUDE_AGENT_SDK_DISABLE_BUILTIN_AGENTS` into
  `.claude/settings.json`, and `disable_builtin_agents` is always `false`: on Claude
  Code 2.1.311 that key in the project settings did not remove the built-in
  subagents (general-purpose, Explore, statusline-setup) from the listing; it did
  only when passed with `--settings`. The cost table now assumes the built-in
  subagents stay listed: fixed cost with subagents 2,477 tokens per request (with
  skills too: 3,326), plus the listing; before it was 1,911 and 2,761. The lean
  saving shown with subagents is lower by the same amount. `bench/native/probe.py`
  E-N1 now checks that the built-in subagents are listed exactly when the export does
  not set the switch.
- A learned and a history item dropped for the same reason are one row in
  `native.dropped`, not two.

### Known issues (2026-11-13)

- Skills and subagents need at least 200 commits of history; a shallower clone
  generates none (the summary says `history_unavailable` and to run
  `git fetch --unshallow`).
- Claude Code ignores the exported allow rules in a workspace that is not trusted,
  so the test runner's command then needs approval.
- Whether the generated skills and subagents improve accuracy or reduce tokens on
  real tasks is not measured; no paid A/B run exists.

### Changed (2026-11-13, product fixes after the development tests)

- The `lean` profiles keep `Task` when the repository has its own subagents
  (`.claude/agents/`), and `Skill` with `Workflow` when it has its own skills or
  commands (`.claude/skills/`, `.claude/commands/`). The saving is then reported as
  not measured, because only the full deny list was measured. The CLI and portal say
  that the lean profile is a settings change a user could also make by hand.
- `git commit` is no longer denied: a local commit is reversible. `git push`, `gh`
  and the other network and publishing commands stay denied. The replay gate's
  synthetic call list (`bench/value/replay/synthetic-calls.json`) is now version 2,
  with `git commit` removed from the calls that must be refused; it now has 38 normal and 47 unsafe calls.
- `learn` with `lean-ai`, and `lean-x`, are marked experimental in the CLI with their
  measured development results: `lean-ai` used 0.96x the tokens of the lean settings
  alone (within noise); `lean-x` used 0.80x on 7 development tasks with the same
  solve rate, below its own pre-set bar of 0.75x, and was never run on held-out tasks.

### Added

- Reproducible end-to-end benchmark suite (`bench/`) and dated evidence under
  `docs/benchmarks/`.
- Read-only session chat across local files, GitHub, Projects, Jira, Slack and
  Confluence snapshots, with current-revision citations, explicit selected sync,
  local search, optional model answers and separate cloud chat-context consent.
- Codex/Claude native exports and OpenAI Responses/Anthropic Messages model APIs.
- Local Elixir/OTP workspace, SQLite/FTS5, loopback LiveView portal and CLI.
- Source revisions/citations, immutable claims, explicit decisions and goals.
- Deterministic OpenCode native previews, integrity checks and safe export.
- Bounded read-only GitHub repository, GitHub Projects v2, Jira Cloud, Slack channel
  and Confluence Cloud adapters with selected-scope portal/CLI setup, and optional
  local Ollama/consented OpenAI through a usage/budget ledger.
- Durable isolated evaluation, pinned OpenCode Docker diagnostics and guarded
  local release approval/channel history.
- Logical content purge, resumable cleanup, consistent backup and quarantined
  restore with approvals, active connections and cloud consent withdrawn.
- Synthetic fixtures, contributor/security docs, native release packaging and
  a Linux CI workflow candidate.
- `harnessforge learn ABSOLUTE_PATH --out FRESH_DIR --verify-image IMAGE`: learns from
  the repository's history at HEAD. An AI learner (Claude Code in Docker, behind a
  metering proxy; cloud inference only with `--allow-cloud --key-file`) proposes
  concepts, pitfalls, commands and command rewrites; each is kept only with evidence
  from commits at or before HEAD, and commands and rewrites only after they ran in the
  given image with network none. The result is one content-addressed bundle
  (`learned.json` + `learned.sha256`) written once into a fresh directory. A learner
  that did not run is shown as `unavailable` or `failed`, never replaced.
- `generate ... --context lean-ai --learned BUNDLE_DIR` (template `v1alpha2.4`): the
  `lean` export plus a local index, a locator card hook (only when the repository's own
  replay gate passes), a command rewrite hook for verified rewrites and learned
  `CLAUDE.md` lines. Same bytes from the same repository and bundle.
  - A learned line enters `CLAUDE.md` only in place of the static line on the same
    topic (deprecation, warnings as errors, changelog), so the file never grows;
    `spec.learning.claude_md_lines` counts lines replaced and left out.
  - Learned concept terms are not written to the index until a time-split test shows
    they help the locator.
  - The session-start check leaves out a tool that a verified rewrite already answers,
    and a test command the bundle could not verify is withheld from `CLAUDE.md`.
  - The fixed sentence "Lint and format run automatically when you finish. Do not
    install or download tools." and its lint-only and format-only forms are left out of
    the `lean-ai` `CLAUDE.md` (reported as `process_only`); the stop hook still runs
    lint and format. The bytes they would have taken are not given to other lines: the
    `lean-ai` budget shrinks by them, and the provenance file's `budget_bytes` shows
    it. `lean` and `standard` keep the sentence and the 600-byte budget.
- `learn` checks (from the v4 review):
  - a quiet-flags rewrite may only add output flags (`-q`, `-qq`, `--quiet`,
    `--no-header`, `--tb=short|line`, `--silent`, `--reporter dot|min`, and `-s` after
    npm, pnpm or yarn); a flag that changes what runs, such as `-p no:cacheprovider`,
    is thrown away;
  - a test command that exits 0 but runs no test ("0 passing", "no tests ran") is not
    verified;
  - a pitfall pattern found in more than a quarter of all fix commits
    (`pattern_too_common`, changelog rules excepted), a copy of the prompt's example
    (`example_copy`), or a pitfall naming a tool that verification proved missing
    (`tool_missing`) is dropped;
  - the learner container gets only the repository's tracked files and `.git`, not
    untracked or ignored files; its transcript is kept beside the bundle
    (`learner-transcript.jsonl`).
- `generate ... --context lean-x` (command line only): the `lean` settings plus two
  PreToolUse hooks and a four-line output style (`.claude/output-styles/olivium.md`,
  `"outputStyle": "olivium"`), and no `CLAUDE.md`, card, index or other hook.
  - The guard, as in the other profiles.
  - A Bash output shaper (`.claude/hooks/olivium-shape.sh`, POSIX `sh` and `awk`): the
    command runs unchanged in the same shell; a line over 400 bytes keeps its first
    400 bytes, and a test command's output over 4,000 bytes keeps a 1,200-byte head
    and a 2,800-byte tail. Each cut is marked `[olivium: cut ...]` and the full output
    stays in a private temporary file named in the marker. Test commands get a 600 s
    timeout and run in the foreground. Background jobs, traps, `exec`, a trailing
    backslash and commands over 64 KiB run as written; when the shaper cannot run it
    says so in one line and the command runs unshaped.
  - Measured on Claude Code 2.1.311 (capture server, no model): the first request
    against the `lean` settings has the same tools, 38 more system bytes and about
    410 more message bytes. Whether it saves tokens overall is not yet measured.

### Changed

- The guard counts a package that `npx`, `bunx` or `npm exec` would run as installed
  when the project's own `package.json` declares it as a bin (a `bin` object key, or a
  `bin` string with that `name`). It reads that `package.json` (a regular file of at
  most 1 MiB, not a link) as data, and only for this check.

- Portal restyled to the Olivium Harness brand: dark theme and palette from
  harness.olivium.space, self-hosted Space Grotesk and IBM Plex Mono, new logo
  and icons.
- Generated Claude Code harnesses (`harnessforge.dev/v1alpha2`, template
  `v1alpha2.3`, adapter mapping `claude-code-docs-v3`, blueprints version 3, `python`
  and `node` version 4):
  - CLAUDE.md is lean: at most 600 bytes, only lines the agent cannot guess and that
    change the patch. Lint, format, type-check, build, install and run lines, the
    layout section and "read the AI policy first" are withheld; every withheld line
    is listed with a reason in `.olivium/guidance-provenance.json`. The AI policy is
    shown to the person generating the package instead. Lines about test session
    runners and lint tools (tox, nox, flake8, pylint, pycodestyle), virtual
    environments, issue labels, and every line of a pull request or issue template are
    withheld as process lines.
  - Practice rules: a Python or JavaScript project whose own source emits at least 3
    deprecation warnings, or whose maintainer documents state a deprecation policy,
    gets one fixed sentence ("When removing or changing public API, keep the old
    behaviour working: ..."); a Python project whose pytest configuration turns
    warnings into errors gets "Tests treat warnings as errors: expect new warnings
    with `pytest.warns`." Counts only; no repository text is copied.
  - `lean` context profile, the default for solo exports: `includeGitInstructions:
    false` and bare denies for 15 Claude Code tools no recorded benchmark run used,
    about 11,700 fewer tokens on every model request (measured on Claude Code
    2.1.311). This removes subagents (`Task`) and skills (`Skill`, `Workflow`) in
    that project, the user's own included; `generate` and the portal say so.
    `--context standard` (CLI) or the profile switch (portal) keeps them. `lean` is
    refused, never swapped, for a package with agents or skills.
  - A session-start environment check names a listed tool that is not installed;
    it prints nothing when every tool resolves, or when the runner (`uv run`,
    `npm`, `npx`, ...) has not set up the project's environment yet. A Python
    version pinned in `.python-version` (or `.python-version-default`) is checked
    the same way ("Python 3.14 is not available here: ...").
  - The stop hook formats and lints changed files and runs only the changed test
    files, at most 3, within 60 s (Python: only files pytest collects by name;
    JavaScript: no fixtures or helpers, and no test step when mocha's own
    configuration names spec files); it prints only on failure. Tests that history
    pairs with a changed source file are no longer run: on the benchmark's gold
    patches the single strongest pair added 2 to 30 s to a passing stop.
    `.olivium/test-pairs.tsv` is still written, as data no hook reads. The time bound stops every process the test
    command started. Untracked links, FIFOs and files of 1 MiB or more are never
    read. With a `uv.lock`, checks run with `UV_FROZEN=1` unless the session sets its
    own uv lock or sync option. The edit-time formatter is gone.
  - Guard refusals for missing tools now end with "X is not installed here;
    continue without it."
  - `generate` prints what CLAUDE.md costs (bytes and estimated tokens per request),
    how many lines it withheld and the context profile; the portal shows the same.
- A stored `v1alpha2` preview made by an earlier template no longer verifies and is
  refused with `preview_regenerate`; generate it again. `v1alpha1` is unchanged.

### Known limits

- Model-backed qualification, authorized live scopes and clean-platform packaging
  evidence remain separate from fixture checks.
- Static/runtime-smoke passes cannot approve releases.
- Content purge does not erase external copies, backups or physical media.
