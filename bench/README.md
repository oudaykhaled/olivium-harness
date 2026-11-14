# bench/ - reproducible benchmark and end-to-end evidence

The scripts in this directory measure a checkout of Olivium Harness through its real entry points: the Phoenix LiveView portal driven by headless Chromium, the `bin/harnessforge` launcher, and the programmatic pipeline API inside one `mix run` BEAM. They never use the default workspace under `~/.local/share/harnessforge`, never run `mix test`, and never run git write commands. Each dated result set lives under `docs/benchmarks/<YYYY-MM-DD>/`; the current one, with every table and screenshot, is [docs/benchmarks/2026-11-08/README.md](../docs/benchmarks/2026-11-08/README.md).

## One command

```sh
bash bench/run.sh
```

`run.sh` runs four stages in this order and keeps going when one fails (exit status 1 at the end if any did):

1. **e2e-browser**: starts `mix phx.server` on a free loopback port with a fresh workspace under `tmp/`, waits until `curl http://127.0.0.1:<port>/` answers, runs `node bench/e2e.cjs`, stops the server and verifies the port is free.
2. **e2e-cli**: runs `bash bench/e2e-cli.sh` with its own fresh workspace (no server; every launcher call boots the BEAM).
3. **pipeline**: runs `BENCH_OUT=... HARNESSFORGE_WORKSPACE=... mix run bench/pipeline.exs` on a third fresh workspace.
4. **portal**: starts `mix phx.server` again with a fourth fresh workspace, runs `node bench/portal.cjs`, records the server RSS and ten `curl` time-to-first-byte probes, stops the server.

Defaults: evidence goes to `docs/benchmarks/$(date +%F)/` (if that directory already holds a published `README.md`, the run writes to `docs/benchmarks/<date>-rerun-<UTC time>/` instead of overwriting it); workspaces, exports and the import corpus copy go to `tmp/bench-<UTC timestamp>/` under the repository, which is removed after a fully successful run and kept when something failed or `BENCH_KEEP_TMP=1` is set.

| Variable | Meaning | Default |
| --- | --- | --- |
| `BENCH_OUT_ROOT` | evidence root | `docs/benchmarks/$(date +%F)` |
| `BENCH_TMP_ROOT` | scratch root (absolute path, no symlinked ancestors; always kept when caller-supplied) | `tmp/bench-<timestamp>` |
| `BENCH_STAGES` | comma-separated subset of `e2e-browser,e2e-cli,pipeline,portal` | all four |
| `BENCH_KEEP_TMP` | `1` keeps the default scratch root | unset |
| `BENCH_READY_TIMEOUT_S` | seconds to wait for a portal instance to answer | `120` |

The script also passes `BENCH_CORPUS_SRC`, `BENCH_MAX_FILES`, `BENCH_MAX_TOTAL_BYTES`, `BENCH_SKIP_SHELL`, `BENCH_NAV_SAMPLES`, `BENCH_PACKAGE_NAME`, `E2E_STEP_TIMEOUT_MS`, `E2E_EVAL_TIMEOUT_MS` and `PLAYWRIGHT_CHROMIUM_EXECUTABLE` through to the individual scripts. The verification run of `run.sh` on the benchmark laptop took 2 min 9 s end to end (stage wall times 14334, 62767, 38509 and 12691 ms; see `docs/benchmarks/2026-11-08/supplementary/run-sh-verification/run-summary.json`); the CLI suite alone makes 20 launcher calls, each booting the BEAM.

## Prerequisites

- The toolchain in `.tool-versions` (Elixir 1.19.5 / Erlang 28.3.1) with `mix deps.get`, `mix assets.setup` and `mix assets.build` done. The dev environment should already be compiled; otherwise the first `mix phx.server` or `mix run` compiles it.
- Node.js and Playwright 1.64.1 with its Chromium build under `test/browser/node_modules`: `cd test/browser && npm install && npx playwright install chromium`. The browser scripts `require` Playwright from that directory.
- `curl`, `lsof` and `python3` (macOS ships them; most Linux distributions do too). `run.sh` is written for bash 3.2, the macOS default.
- A writable `tmp/` directory under the repository (it is gitignored). Workspace paths must be absolute and must not pass through a symlink; `run.sh` resolves its scratch root with `pwd -P`.
- Nothing else may own the workspaces: each workspace admits exactly one owning OS process, which is why every stage gets its own fresh directory.

## Scripts and their contracts

### `bench/e2e.cjs` - browser end-to-end suite

Runs 15 scenarios (B01 to B15) against an already running portal in headless Chromium: unlock, wrong access code, load the synthetic demo, reject the hostile claim and approve the two ordinary ones, build a package for Claude Code, rebuild and compare the digest, open the artifact detail page, export and verify the files on disk, run a `static_integrity` evaluation, run a task evaluation (expected `blocked` without an isolated runtime), attempt a release approval (expected refusal), create a backup, check the 390x844 mobile view, lock the workspace, ask one question in the chat tab. Each scenario asserts with `node:assert/strict` and records `result`, `duration_ms`, console errors and one PNG.

```sh
HARNESSFORGE_URL=http://127.0.0.1:8867 HARNESSFORGE_WORKSPACE=/abs/workspace BENCH_OUT=/abs/out node bench/e2e.cjs
```

| Variable | Meaning | Default |
| --- | --- | --- |
| `HARNESSFORGE_URL` | origin of the running portal | `http://127.0.0.1:8865` |
| `HARNESSFORGE_WORKSPACE` | workspace directory of that portal; the access code is read from `<workspace>/access-token` inside the script and never printed, logged or stored | required |
| `BENCH_OUT` | evidence directory | `docs/benchmarks/<today>/e2e` |
| `E2E_EXPORT_ROOT` | fresh (absent or empty) directory per run for exports and backups | `<BENCH_OUT>/../tmp-exports` |
| `E2E_STEP_TIMEOUT_MS`, `E2E_EVAL_TIMEOUT_MS` | locator and evaluation timeouts | `30000`, `90000` |
| `PLAYWRIGHT_CHROMIUM_EXECUTABLE` | use a specific Chromium build | Playwright's own |

Outputs `BENCH_OUT/results.json`, `BENCH_OUT/e2e.log`, `BENCH_OUT/screenshots/*.png` and `screenshots/index.json`; prints a table; exits 1 if any scenario failed and 2 on a fatal error. A scenario that cannot be implemented is recorded as a failure with the reason; nothing is skipped silently.

### `bench/e2e-cli.sh` - CLI end-to-end suite

Runs 11 scenarios (C01 to C11) through the real launcher: `init`, `status`, `demo` + `claims`, `decide` (approve two by exact revision hash, reject the hostile one), `build` for claude_code 2.1.311 / codex 0.156.0 / opencode 1.0.0, a rebuild with identical inputs, `export` with on-disk verification (guidance file content, settings JSON, manifest sha256 of every file), `evaluate DIGEST static_integrity` + `runs`, `diff`, `backup` + `restore` + `status` on the restored workspace, `inventory`.

```sh
HARNESSFORGE_WORKSPACE=/abs/fresh-workspace BENCH_OUT=/abs/out E2E_EXPORT_ROOT=/abs/fresh-exports bash bench/e2e-cli.sh
```

| Variable | Meaning | Default |
| --- | --- | --- |
| `HARNESSFORGE_WORKSPACE` | fresh workspace owned by the CLI calls of this run | required |
| `BENCH_OUT` | evidence directory | `docs/benchmarks/<today>/e2e` |
| `E2E_EXPORT_ROOT` | fresh directory for exports and backups | `<BENCH_OUT>/../tmp-exports` |
| `E2E_RESTORE_TARGET` | fresh directory for the restored workspace of C10 | `<E2E_EXPORT_ROOT>/cli-restored-workspace` |

Every launcher call boots the BEAM; that time is included in each scenario's `duration_ms`. Raw stdout/stderr of every command is appended to `BENCH_OUT/cli.log`; scenario records go to `BENCH_OUT/cli-results.json`; exit status 1 if any scenario failed.

### `bench/pipeline.exs` - pipeline benchmark

Eleven steps inside one `mix run` BEAM on a fresh workspace: BEAM boot baseline from the shell (nested `/usr/bin/time -p mix run -e :ok`, `bin/harnessforge status` and `mix run --no-start -e :ok` against a sibling workspace), `Demo.load/0`, two approvals, first `Harnesses.build` per runtime, five rebuilds per runtime (determinism), `Compiler.compile/1` at 10 / 100 / 500 rules plus `Compiler.verify/1`, three fresh exports, local import of a Markdown corpus with one sync and two re-syncs, `Evidence.search/1` over 50 FTS5 queries, memory and database footprint, inventory. Every step records its error string and the run continues.

```sh
BENCH_OUT=DIR HARNESSFORGE_WORKSPACE=/absolute/fresh/workspace mix run bench/pipeline.exs
```

| Variable | Meaning | Default |
| --- | --- | --- |
| `HARNESSFORGE_WORKSPACE` | fresh, disposable workspace (absolute, no symlinked ancestors); `mix run` locks and migrates it before the script starts | required |
| `BENCH_OUT` | evidence directory, receives `results.json` and `pipeline.log` | `docs/benchmarks/<today>/pipeline` |
| `BENCH_CORPUS_SRC` | directory whose `.md` / `.markdown` / `.txt` files form the import corpus | `docs/archive` |
| `BENCH_CORPUS` | where the bounded corpus copy is assembled (recreated) | `<workspace parent>/bench-corpus` |
| `BENCH_EXPORT_DIR` | parent directory for fresh export targets (recreated) | `<workspace parent>/bench-export` |
| `BENCH_MAX_FILES` | corpus file cap (importer hard limit 500) | `400` |
| `BENCH_MAX_TOTAL_BYTES` | corpus byte cap (importer hard limit 16 MiB) | 15 MiB |
| `BENCH_SKIP_SHELL` | `1` skips the shell boot baseline | unset |

Run it from the project root with `PHX_SERVER` unset so the application starts without an HTTP listener. The 2026-11-08 run wrapped it in `/usr/bin/time -p` and kept the console output; see `docs/benchmarks/2026-11-08/pipeline/commands.sh`.

### `bench/portal.cjs` - portal evidence

One portal flow in headless Chromium against an already running server: login screenshot before the code is typed, unlock, home, five timed navigations each to `/login`, `/` and `/?view=evidence` (navigation timing plus the first `.phx-connected` element), tab switch, load demo, decide the three claims, build `bench-portal`, export to a fresh directory, queue a `static_integrity` evaluation, then screenshots of the evaluations tab, privacy tab, harness detail page (full page), `/setup` and the 390x844 evidence view. Six action latencies are measured inside the page from the click event to the first matching DOM mutation.

```sh
HARNESSFORGE_URL=http://127.0.0.1:8866 HARNESSFORGE_WORKSPACE=/abs/workspace BENCH_OUT=/abs/out node bench/portal.cjs
```

| Variable | Meaning | Default |
| --- | --- | --- |
| `HARNESSFORGE_URL` | origin of the running portal | `http://127.0.0.1:8865` |
| `HARNESSFORGE_WORKSPACE` | workspace of that portal; the access code is read from `<workspace>/access-token` and never printed, logged, screenshotted or written to a result file | `tmp/demo-workspace` |
| `BENCH_OUT` | evidence directory | `docs/benchmarks/<today>/portal` |
| `BENCH_SCRATCH` | parent for the fresh export directory | parent of the workspace |
| `BENCH_PACKAGE_NAME`, `BENCH_NAV_SAMPLES` | package name, navigations per page | `bench-portal`, `5` |
| `BENCH_STEP_TIMEOUT_MS`, `BENCH_EVAL_TIMEOUT_MS` | timeouts | `30000`, `90000` |
| `PLAYWRIGHT_CHROMIUM_EXECUTABLE` | use a specific Chromium build | Playwright's own |

Outputs `BENCH_OUT/browser.log`, `BENCH_OUT/browser-results.json`, `BENCH_OUT/screenshots/*.png` and `screenshots/index.json`; exits 1 if any step failed. Every step runs in its own try/catch, so a failing step is recorded and the run continues. Server start-to-ready, shutdown time, RSS and `curl` probes are taken from the shell around it; `run.sh` records a start-to-ready time, RSS before and after the flow and ten `curl` samples next to the browser results.

## Output layout of `run.sh`

```
docs/benchmarks/<date>/
  run.log                  timestamped log of every command run.sh issued and every stage's exit status
  run-summary.json         stages, exit statuses and wall times
  machine.txt              CPU, memory, OS, toolchain versions, git HEAD
  e2e/                     results.json + e2e.log + screenshots/ (browser suite), server.log, server-start-timing.txt,
                           stdout.log, cli-results.json + cli.log + cli-stdout.log (CLI suite)
  pipeline/                results.json, pipeline.log, console.log
  portal/                  browser-results.json, browser.log, screenshots/, server.log, server-start-timing.txt,
                           rss-after-ready.txt, rss-after-flow.txt, curl.log, stdout.log
```

When publishing a result set, add a `README.md` next to these directories that names the file and key behind every number, states the concurrency and dev-mode caveats, and reports failed measurements as failed. The 2026-11-08 set is the template.

## Rules

- Never point any of these scripts at a workspace you care about; they load the demo, approve claims, build, export and import into it.
- Never run them with the default workspace; always set `HARNESSFORGE_WORKSPACE` (run.sh does this for every command).
- Stop any portal that owns a workspace before running CLI commands against the same workspace; run.sh gives every stage its own.
- `bench/` is outside the project's `.formatter.exs` inputs; `mix format --check-formatted bench/pipeline.exs` passes and is the only formatter command to use here.
- These scripts produce measurements and screenshots. They do not qualify a runtime, approve a release or stand in for the project's own evaluation gates.
