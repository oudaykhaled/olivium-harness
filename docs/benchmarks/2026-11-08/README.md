# Olivium Harness benchmark and end-to-end evidence, 2026-11-08

**Date of run:** 2026-11-08 (UTC). Pipeline benchmark 10:18:41Z to 10:19:18Z; portal evidence 10:23:22Z to 10:27:47Z (its first launch on 2026-11-07T23:36:01Z was aborted, see methodology); end-to-end scenario suite 13:20:47Z to 13:35:01Z.

**Commit:** `628676e` (`628676e7c48d7f3e02cca7785e5c476393cfca91`) plus the uncommitted documentation reorganisation (`docs/archive`, `docs/plans`) from 2026-11-07. `git status --porcelain` listed 775 entries at measurement time: that reorganisation plus the benchmark files themselves.

**Machine:** Intel Core i9-9980HK @ 2.40GHz, 16 logical cores, 32 GiB RAM (34359738368 bytes), macOS 26.6 build 25G72 (kernel 25.6.0), Elixir 1.19.5 compiled with Erlang/OTP 28, Erlang 28.3.1 (ERTS 16.2), Node v24.10.0, Playwright 1.64.1 with Chromium 156.0.8078.4, Docker 28.5.1 installed and unused.

**Mode:** `MIX_ENV=dev` throughout. The portal ran as `PHX_SERVER=true mix phx.server` (code reloader, debug logging, esbuild/tailwind watchers); the CLI launcher `bin/harnessforge` runs `mix run -e HarnessForge.CLI.main` and boots the BEAM on every call; the pipeline benchmark ran inside one `mix run` BEAM. None of this is a release build.

Every number on this page is copied from a file in this directory; the file and key are named next to each table. Nothing was estimated. Workspace access tokens were read only inside the scripts that log in and were never printed, logged, screenshotted or stored.

## Methodology

What each script does:

- `bench/e2e.cjs` (browser end-to-end suite): 15 scenarios against the real portal in headless Chromium through Playwright from `test/browser/node_modules`. Each scenario asserts with `node:assert/strict` and records `result`, `duration_ms`, console errors seen while it ran and one PNG screenshot (1280x800; B13 at 390x844). The access code is read from `<workspace>/access-token` inside the process. Outputs `results.json` (kept here as `e2e/browser-results.json`), `e2e.log`, `screenshots/index.json`; exit 1 if any scenario fails; nothing is skipped silently. The moment at which the script takes the B02 screenshot was corrected after this run (see the screenshot gallery notes); no assertion changed.
- `bench/e2e-cli.sh` (CLI end-to-end suite): 11 scenarios through the real `bin/harnessforge` launcher against a second fresh workspace. Every launcher call boots the BEAM and that time is included in each scenario's `duration_ms`. Raw stdout/stderr of every command goes to `cli.log`; scenario records to `cli-results.json`; exit 1 if any scenario fails.
- `bench/pipeline.exs` (pipeline benchmark, `mix run`): 11 steps on a fresh workspace: (1) BEAM boot baseline from the shell with nested `/usr/bin/time -p` against a sibling workspace, (2) `Demo.load/0`, (3) two approvals through `Decisions.decide`, (4) first `Harnesses.build` per runtime, (5) five rebuilds per runtime for determinism, (6) `Compiler.compile/1` at 10/100/500 rules plus `Compiler.verify/1`, (7) three fresh `Harnesses.export`s, (8) local import of 400 Markdown files and one sync, (9) `Evidence.search/1` over 50 FTS5 queries, (10) memory and database footprint, (11) inventory. In-process timings use `:timer.tc`; every step records its error string and the run continues. Outputs `results.json` and `pipeline.log`; the console output and the exact shell commands are in `console.log` and `commands.sh`.
- `bench/portal.cjs` (portal evidence): one portal flow in headless Chromium (login, unlock, load demo, reject the hostile claim and approve the two ordinary ones, build `bench-portal`, export to a fresh directory, queue a `static_integrity` evaluation) plus five navigations each to `/login`, `/` and `/?view=evidence` sampled with the browser's navigation timing and a MutationObserver for `.phx-connected`, six in-page action latencies (capture-phase click timestamp to the first matching DOM mutation, `performance.now()`), and 10 screenshots at 1440x900 (one at 390x844). Outputs `browser-results.json`, `browser.log`, `screenshots/index.json`. Server start-to-ready, SIGTERM-to-gone, RSS and `curl` time-to-first-byte were taken from the shell around it (`server-restart-timing.txt`, `server-start-timing.txt`, `rss-*.txt`, `curl.log`).

Concurrency caveats, exactly as reported by the measuring runs:

- Pipeline (`pipeline/results.json` `caveats`): "Other processes on the machine (for this run: a second HarnessForge portal from a concurrent agent on PORT 8866 with its own workspace) add light background load; no isolation or CPU pinning was applied." Step 1 CLI timings "include BEAM boot, Mix project loading and HarnessForge application start (workspace lock, SQLite open/migrations, Oban, endpoint without HTTP listener)" and use a sibling workspace "because the benchmark process owns [the workspace] and a workspace admits one owning OS process."
- Portal (`portal/results.json` `environment.concurrent_load`, `caveats`): "another agent ran the CLI pipeline benchmark in its own workspace at the same time; 1 other beam.smp process was present; load average 10.51/8.85/9.29 on 16 logical cores when recorded", so "timings are from a shared, moderately loaded laptop." Also: "The host slept for about 10.6 h between the first server launch (2026-11-07T23:36:01Z) and the next command; the first attempt was discarded anyway [...] and every reported number comes from the fresh run on 2026-11-08 between 10:23Z and 10:26Z."
- End-to-end suite (`e2e/results.json` `environment.concurrency`): "The CLI suite ran in the background while the first (partial) browser run executed; the final browser run (results below) and the two repeats ran after the CLI suite had finished. The repeats used port 8868 and fresh workspaces e2e-ws-rep2 / e2e-ws-rep3 while the main server on 8867 stayed up." Load average at 13:33Z: 3.48 3.33 5.83.

Discarded first attempts (kept as raw output, contributing no numbers): `portal/run1-aborted/` (two selector bugs in `bench/portal.cjs`: an unscoped `.artifact-row` locator and `#nav-privacy` hidden inside a collapsed `<details>`; fixed, whole flow rerun on a new workspace) and `e2e/run1-partial/` (B10 failed with a Playwright strict-mode violation on a nested `<details>` summary in `bench/e2e.cjs`; fixed, whole suite rerun on a fresh workspace and a fresh server instance). Neither was a product defect.

## End-to-end scenarios

### Browser scenarios

Source: `e2e/browser-results.json` (`scenarios[]`, `passed`, `failed`, `total_duration_ms`, `console_errors_total`, `pageerrors_total`) and `e2e/results.json` (`browser.repeats`). Server `PORT=8867`, fresh workspace, headless Chromium 156.0.8078.4, viewport 1280x800, step timeout 30000 ms, evaluation timeout 90000 ms. Final run 13:32:19.294Z to 13:32:26.115Z.

| ID | Title | Result | Duration, final run (ms) | Median of 3 fresh runs (ms) |
| --- | --- | --- | ---: | ---: |
| B01 | Unlock the workspace with the access code and reach the home screen | pass | 1077 | 878 |
| B02 | A wrong access code is rejected and the workspace stays locked (fresh context), then unlock correctly | pass | 760 | 760 |
| B03 | Load the synthetic demo and assert the expected sources and claim cards appear (incl. the hostile claim) | pass | 178 | 189 |
| B04 | Reject the hostile claim and approve the two ordinary claims; assert the card states change | pass | 289 | 326 |
| B05 | Build a package named e2e-claude for the Claude Code runtime and assert an artifact row with a digest appears | pass | 334 | 231 |
| B06 | Build again with identical inputs and assert the digest shown in the DOM is identical (determinism) | pass | 175 | 169 |
| B07 | Open the artifact detail page: file list has the guidance file, settings, an agents entry, a skills entry; verification flags shown | pass | 190 | 190 |
| B08 | Export the package to a fresh directory and verify guidance content and the manifest on disk | pass | 361 | 362 |
| B09 | Run a static_integrity evaluation; assert it reaches passed and the UI states runtime qualification false | pass | 287 | 293 |
| B10 | Run a task evaluation and assert it is reported blocked (no isolated runtime), not faked | pass | 254 | 344 |
| B11 | Attempt a release approval with the static_integrity evaluation and assert it is refused (#error) | pass | 233 | 233 |
| B12 | Create a workspace backup into a fresh directory via the Privacy tab and verify the directory on disk | pass | 296 | 301 |
| B13 | Mobile viewport 390x844 on the Evidence tab: the shell renders without horizontal overflow | pass | 250 | 260 |
| B14 | Lock the workspace (logout) and assert a protected page redirects to the login form | pass | 469 | 469 |
| B15 | Chat tab: ask one question in evidence mode; an answer with citations or an explicit unavailable message renders, no page errors | pass | 534 | 534 |
| **Total** | 15 scenarios | **15/15 passed, 0 failed** | **6821** (suite `started_at` to `ended_at`) | **7307** (min 6821, max 7331, n = 3) |

- Page errors (`pageerror` events): 0. Console errors: 1, the expected `Failed to load resource: the server responded with a status of 401 (Unauthorized)` from the deliberate wrong-code POST in B02 (`e2e/results.json` `headline.browser_console_error_detail`).
- Three complete fresh runs (new workspace and new server instance each): 15/15, 15/15, 15/15; suite totals 6821, 7331, 7307 ms (`e2e/repeat2/results.json`, `e2e/repeat3/results.json`).
- Server start-to-ready of the repeat instances on port 8868: 3.545 s (repeat 2), 4.199 s (repeat 3), 0.1 s poll (`browser.repeats.server_start_to_ready_s`). Start-to-ready of the two instances on port 8867 was not captured exactly: the readiness poll began in a separate step after launch, so it is only bounded above, by about 25 s (`server.second_instance_ready`).
- Server RSS of the final instance after all browser runs: 112708 KiB (`server.second_instance_rss_kib_at_13_33Z`). Server stopped at 13:35:01Z, port 8867 verified free (`e2e/server-stop.txt`).

What the scenarios established (`e2e/browser-results.json` `scenarios[].details`):

| Check | Observed |
| --- | --- |
| Determinism (B05, B06) | first digest `2e6979ea0663c1d3c0d5f5065c1763356732c81d5f3bbdc6190706ea2b077de2` (claude_code 2.1.311); rebuild digest identical: `true` |
| Artifact detail (B07) | 8 files: `.claude/agents/implementer.md`, `.claude/settings.json`, `.claude/skills/reviewed-change/SKILL.md`, `CLAUDE.md`, `harnessforge.capabilities.json`, `harnessforge.manifest.json`, `harnessforge.provenance.json`, `harnessforge.spec.json` |
| Export on disk (B08) | 8 exported files, 7 manifest entries (manifest excluded from itself), 0 sha256 mismatches |
| static_integrity evaluation (B09) | outcome `passed`; UI text "Recorded runtime qualification: false" |
| Task evaluation (B10) | outcome `blocked` ("This target has no managed execution backend.") |
| Release approval with a static_integrity run (B11) | refused: "Release approval requires passed model-backed tasks. A diagnostic or blocked run cannot qualify."; releases before = after = 0 |
| Backup on disk (B12) | reported 11 files, 12 files on disk incl. manifest, 11 manifest entries, 0 sha256 mismatches |
| Mobile 390x844 (B13) | `scrollWidth` 390, `innerWidth` 390, `clientWidth` 390, one workspace shell |
| Lock (B14) | protected page redirects to `/login` (final path `/login`, status 200) |
| Chat, evidence mode (B15) | `answer_with_citations`, 1 citation, mode pill "LOCAL EVIDENCE SEARCH", no model call |

### CLI scenarios

Source: `e2e/cli-results.json` (`scenarios[]`, `passed`, `failed`, `total`, `total_duration_ms`, `cli_calls`; the launcher-call column is the length of each scenario's `commands` list, which matches the `$` command lines in `e2e/cli.log`). Launcher `bin/harnessforge` (`mix run -e HarnessForge.CLI.main`), fresh workspace `e2e-cli-ws`, 13:30:38Z to 13:31:41Z. Each launcher call boots the BEAM and that time is included in every duration: the single-call scenarios took 2789 ms (C06) to 4261 ms (C01) including the command's own work, and the pipeline benchmark's `bin/harnessforge status` baseline (step 1 below) was 2.84 s median, 2.51 s min, 2.99 s max over 3 runs.

| ID | Title | Result | Duration (ms) | Launcher calls |
| --- | --- | --- | ---: | ---: |
| C01 | init prints a workspace id | pass | 4261 | 1 |
| C02 | status reports elixir 1.19.5 and runtime_qualified false | pass | 3632 | 1 |
| C03 | demo loads and claims lists exactly 3 claims | pass | 6185 | 2 |
| C04 | decide: approve the two ordinary claims by id and exact revision_hash, reject the hostile one | pass | 11866 | 4 |
| C05 | build e2e-cli 0.1.0 for claude_code 2.1.311, codex 0.156.0 and opencode 1.0.0; each returns a digest and manifest | pass | 9292 | 3 |
| C06 | rebuilding claude_code with identical inputs returns the same digest | pass | 2789 | 1 |
| C07 | export the claude_code digest to a fresh directory; CLAUDE.md, .claude/settings.json and manifest sha256 verified on disk | pass | 3241 | 1 |
| C08 | evaluate DIGEST static_integrity passes and runs lists it | pass | 5790 | 2 |
| C09 | diff between the claude_code and codex digests reports differences | pass | 2879 | 1 |
| C10 | backup to a fresh directory, restore into a fresh workspace directory, status against the restored workspace | pass | 8992 | 3 |
| C11 | inventory returns counts | pass | 3134 | 1 |
| **Total** | 11 scenarios | **11/11 passed, 0 failed** | **63122** (suite wall time) | **20** |

What the scenarios established (`e2e/cli-results.json` `scenarios[].details`):

| Check | Observed |
| --- | --- |
| Digests (C05) | claude_code 2.1.311 `1f8e06e5e3de0cbfe476dd7c60ae65d4ea71b339af3ef5e9c748b4c56b495a0b`; codex 0.156.0 `4aada16bdbf4e14d6d01303a348fb3cd0f674162c88c965c848964734ed91ba2`; opencode 1.0.0 `3b26cdf311d4d4db3faf6474a6f67cdd0d1775ec20ddc69a5981c345a78e9d81`; 7 manifest files each |
| Determinism (C06) | rebuild digest identical to the first claude_code digest: `true` |
| Export on disk (C07) | `CLAUDE.md` contains the approved rule and the UTF-8 rule, does not contain the hostile text; `.claude/settings.json` parses; 8 files on disk, 7 manifest entries, manifest lists every file, 0 sha256 mismatches |
| static_integrity (C08) | outcome `passed`, `runtime_qualified` false, listed by `runs`, 0 extra polls |
| diff claude_code vs codex (C09) | 11 file differences (4 added, 4 removed, 3 changed), 0 rule differences |
| Backup and restore (C10) | backup 29 files, not encrypted; restore state `quarantined`, `approvals_restored` false, `source_revalidation_required` true; `status` on the restored workspace returns the new workspace id |
| Inventory (C11) | 44 record tables; evidence_sources 1, evidence_revisions 1, evidence_claims 3, claim_decisions 3, evaluation_runs 1, audit_events 14; 27 artifact files |

Browser and CLI digests differ from each other by design (package name and claim ids are compiler inputs); determinism is asserted within each workspace and held in both.

## Pipeline performance

Source: `pipeline/results.json` (`steps.*`), `pipeline/console.log`. Run 10:18:41Z to 10:19:18Z on fresh workspace `bench-ws`; script duration 36.574 s (`duration_s`), outer wall time including BEAM boot 40.61 s (`/usr/bin/time -p` real in `console.log`); zero step errors.

**Step 1, BEAM boot baseline** (`steps.1_beam_boot`; shell, `/usr/bin/time -p` real seconds, nested OS processes against sibling workspace `bench-ws-cli`; 3 timed runs after one warm-up that creates and migrates that workspace):

| Command | Median (s) | Min (s) | Max (s) | Warm-up (s) |
| --- | ---: | ---: | ---: | ---: |
| `mix run -e :ok` (BEAM + Mix + application start) | 2.61 | 2.55 | 2.62 | 3.59 |
| `bin/harnessforge status` | 2.84 | 2.51 | 2.99 | 3.19 |
| `mix run --no-start -e :ok` (BEAM + Mix only) | 0.72 | 0.67 | 0.73 | 0.69 |

**Steps 2 and 3, demo load and decisions** (`steps.2_demo_load`, `steps.3_decisions`; in-process, single measurements because they cannot be repeated on one workspace):

| Operation | Time (ms) | Notes |
| --- | ---: | --- |
| `Demo.load/0`, first load | 52.985 | 1 source, 1 revision, 3 claims created (`synthetic_fixture`) |
| `Demo.load/0`, idempotent re-runs | 8.812 / 7.558 | nothing created |
| `Decisions.decide` approve, claim 1 / claim 2 | 6.368 / 4.259 | 2 approved after; the hostile third claim stays `proposed` |

**Step 4, first build per runtime** (`steps.4_build.builds[]`; `Harnesses.build`, includes publishing the content-addressed artifact to disk):

| Runtime | First build (ms) | Files | Bytes | Digest |
| --- | ---: | ---: | ---: | --- |
| opencode (`unqualified`) | 48.155 | 8 | 7709 | `74f58057e09250d115e3bcc9fd258b31233d47a4ec4587ba9119377b88f2793b` |
| codex 0.156.0 | 38.86 | 8 | 8380 | `fe0404fb0d77bf6e9c2597f1a0298c187ea617ffc5cfeedd5eb5de55d2949551` |
| claude_code 2.1.311 | 42.766 | 8 | 8090 | `5b7f55b8917f3c0a16cc24fe2fe37cb302c97283c6cbf68e9efa768c50d38fbd` |

**Step 5, determinism** (`steps.5_determinism.runtimes[]`; 5 rebuilds each, which re-verify the existing digest instead of writing):

| Runtime | Identical digests / builds | Rebuild median (ms) | Min (ms) | Max (ms) |
| --- | ---: | ---: | ---: | ---: |
| opencode | 6/6 | 27.321 | 22.73 | 31.877 |
| codex | 6/6 | 27.931 | 24.422 | 29.407 |
| claude_code | 6/6 | 26.85 | 24.345 | 28.337 |

`all_deterministic`: true.

**Step 6, compiler micro-benchmark** (`steps.6_compiler`; `Compiler.compile/1`, median of 5, opencode runtime; rules replicate the first real rule with unique synthetic ids and statements). 1000 rules was requested but is not representable: the v1alpha1 schema caps `spec.rules` at 500, so 500 is the largest size.

| Spec size | Median (ms) | Min (ms) | Max (ms) | Throughput (rules/s) | Output |
| --- | ---: | ---: | ---: | ---: | --- |
| 10 rules | 1.785 | 1.56 | 1.985 | 5602.241 | 8 files, 15919 bytes |
| 100 rules | 12.363 | 10.228 | 12.965 | 8088.652 | 8 files, 107814 bytes |
| 500 rules | 65.551 | 54.624 | 67.007 | 7627.649 | 8 files, 517017 bytes |
| `Compiler.verify/1`, real 2-rule artifact | 0.808 | 0.759 | 1.082 | n/a | 5 ok runs |

**Step 7, export** (`steps.7_export`; `Harnesses.export` of the opencode artifact to 3 fresh directories):

| Measure | Value |
| --- | --- |
| Export time, median / min / max of 3 | 30.044 / 28.594 / 30.403 ms |
| Files and bytes on disk per export | 8 files, 7709 bytes |
| Exported files byte-identical to the stored artifact | 8/8 |
| Post-export `Compiler.verify/1`, median / min / max | 1.317 / 0.842 / 1.625 ms |

**Step 8, local import** (`steps.8_import`; corpus = first 400 of 759 sorted Markdown files under `docs/archive`, copied to a scratch directory; MB are decimal, 1e6 bytes):

| Measure | Value |
| --- | --- |
| Corpus | 400 files, 2976139 bytes (2.838 MiB), largest file 142660 bytes, 0 skipped for size |
| `connect local` | 1.275 ms |
| First `sync` (bodies + FTS5 rows in one transaction) | 1.336 s, 400 sources and 400 revisions created |
| Throughput | 299.338 files/s, 2.227 MB/s |
| Re-sync of the unchanged corpus | 971.173 ms, 986.028 ms (0 imported, 400 unchanged each) |

**Step 9, search** (`steps.9_search`; `Evidence.search/1`, 50 queries = 10 fixed words x 5, FTS5 MATCH with LIMIT 50; latency includes materialising every hit with its revision body):

| Statistic | Value (ms) |
| --- | ---: |
| p50 | 87.724 |
| p95 | 169.96 |
| max | 272.326 |
| min | 3.333 |
| mean | 95.758 |

Mean hits per query 44.1; 0 failed queries. Per-word probe (one sample each): verification 50 hits 82.461 ms; coordination 39 hits 74.974 ms; ticket 2 hits 4.632 ms; connector 50 hits 107.518 ms; evidence 50 hits 111.649 ms; workspace 50 hits 108.961 ms; release 50 hits 110.111 ms; harness 50 hits 111.957 ms; claim 50 hits 109.277 ms; operator 50 hits 151.57 ms.

**Step 10, footprint after step 9** (`steps.10_footprint`; MB decimal):

| Measure | Value |
| --- | --- |
| `:erlang.memory(:total)` | 99.283 MB (99283408 bytes) |
| OS RSS of the benchmark BEAM (`ps -o rss=`) | 120496 KiB = 123.388 MB |
| `data.sqlite3` | 10.596 MB (10596352 bytes) |
| `data.sqlite3-wal` / `-shm` (not checkpointed) | 11482472 / 32768 bytes; all database files 22.112 MB |
| Schedulers online / Erlang processes | 16 / 293 |

**Step 11, inventory** (`steps.11_inventory`; 11.865 ms): evidence_sources 401, evidence_revisions 401, evidence_claims 3, claim_decisions 2, evidence_citations 3, source_connections 2, workspace_goals 1, audit_events 430, evaluation_runs 0; files: artifacts 27, runs 0, tmp 1; retention `until_explicit_purge`.

## Portal timings

Source: `portal/results.json` (`server.*`, `browser.*`), `portal/browser-results.json`, `portal/server-restart-timing.txt`, `portal/curl.log`. Server `PORT=8866`, fresh workspace `portal-ws`, headless Chromium 156.0.8078.4, viewport 1440x900; measured run 10:23:22Z to 10:27:47Z.

**Server start-to-ready** (`server.start_to_ready`; seconds from immediately before `mix phx.server` is launched until the first HTTP answer on `/`, a 302 to `/login`; 0.1 s poll, so each value carries up to +0.1 s):

| Case | Median (s) | Min (s) | Max (s) | n | Values (s) | RSS at ready (KiB) |
| --- | ---: | ---: | ---: | ---: | --- | --- |
| Existing workspace (warm1-3) | 3.067 | 2.899 | 3.302 | 3 | 3.302, 2.899, 3.067 | 104148, 105992, 100616 |
| New empty workspace (fresh1-3) | 3.433 | 3.399 | 3.682 | 3 | 3.399, 3.682, 3.433 | 112504, 109604, 116052 |
| All six timed starts | 3.351 | 2.899 | 3.682 | 6 | | |
| Fresh boot used for the browser flow | not captured exactly: upper bound 6.964 s, because the poll started after the server already answered | | | 1 | | |

**Server shutdown** (`server.shutdown_sigterm_to_process_gone_s`): SIGTERM to process gone, 7 stops: median 1.325 s, min 1.313 s, max 1.451 s.

**Server memory** (`server.memory`; `ps -o rss=` on the beam.smp pid): 113188 KiB (110.5 MiB, 115.9 MB) 0.2 s after ready on the fresh workspace; 112668 KiB (110.0 MiB, 115.4 MB) after the whole browser flow; delta -520 KiB.

**HTTP time-to-first-byte with curl** (`server.curl.by_path`; `%{time_starttransfer}`, unauthenticated, 10 samples per path across two server instances):

| Path | Status | Body (bytes) | TTFB median (ms) | Min (ms) | Max (ms) |
| --- | ---: | ---: | ---: | ---: | ---: |
| `/` | 302 | 72 | 34.4 | 27.0 | 47.2 |
| `/login` | 200 | 4060 | 27.6 | 26.0 | 69.2 |

**Browser navigation timing** (`browser.navigation_timing_ms`; `page.goto` with `waitUntil: "load"`, 5 samples per page; p50 with min to max in parentheses; "LiveView connected" is the first appearance of `.phx-connected`):

| Page | TTFB (ms) | DOMContentLoaded (ms) | load (ms) | LiveView connected (ms) |
| --- | --- | --- | --- | --- |
| `/login` | 76.5 (42.3 to 91.6) | 85.0 (60.2 to 160.6) | 85.8 (60.3 to 160.6) | no LiveView |
| `/` (home) | 38.0 (36.8 to 117.5) | 52.1 (50.1 to 135) | 53.7 (51.6 to 137.2) | 117.2 (111.6 to 281.2) |
| `/?view=evidence` | 46.5 (39.5 to 53.4) | 62.2 (55.3 to 66.9) | 63.6 (56.7 to 68.3) | 134.7 (117.7 to 170.7) |

**In-page action latencies** (`browser.action_latency_ms`; click event to first matching DOM mutation, measured inside the page; the Node-side wall time of the same step, which includes Playwright round trips, is shown for comparison):

| Action | In-page (ms) | Node side (ms) | Signal |
| --- | ---: | ---: | --- |
| Tab switch Home to Evidence | 31.3 | 70 | `#evidence-panel` |
| Load demo to first claim card | 67.1 | 89 | `.claim-card` |
| Approve click to card pill `.approved` | 43.8 | 66 | `.pill.approved` on the claim card |
| Build package click to artifact row | 97.0 | 140 | `#package-panel .artifact-row[data-export-digest]` |
| Export package click to status | 95.8 | 136 | `[id^="package-export-result-"][role="status"]` |
| static_integrity queue click to run card `passed` | 318.1 | 352 | `[id^="run-"][data-outcome="passed"]` |

Other recorded checks (`browser.checks`): login submit to live shell 728 ms (Node side); harness detail page load 131 ms; package form defaults version 0.1.0, runtime opencode, runtime version `unqualified`; built digest `23843af726572adc91c1f550686c82ee4cad42f263be18e01db937b72362470d`; export: `AGENTS.md` exists, includes the approved rule, excludes the rejected claim; evaluation text includes `passed` and "Recorded runtime qualification: false"; `/setup` answers 200; mobile view has no horizontal overflow. Console over the whole flow (`browser.console`): 0 page errors, 0 console errors, 0 warnings, 0 failed requests. Whole browser flow 6898 ms (`browser.run.total_ms`); 10 screenshots, 1073566 bytes, not downscaled.

## Screenshot gallery

Captions are copied from `e2e/screenshots/index.json` and `portal/screenshots/index.json`, except for B02, whose caption in the index file does not describe the image (see the notes below the end-to-end table). End-to-end screenshots are 1280x800 unless noted; portal screenshots are 1440x900 unless noted. Every login screenshot shows an empty access-code field; the real access code appears in no screenshot.

Screenshots and video that showed local paths are not published.

### End-to-end suite (final run)

| Screenshot | Caption |
| --- | --- |
| `e2e/screenshots/B01.png` (not published) | Login page before anything is typed: empty "Workspace access code" field and Unlock workspace button (redirected from /). |
| `e2e/screenshots/B02.png` (not published) | Fresh browser context after the wrong-code attempt: the login page as re-rendered when the still-locked context requested a protected page and was redirected to /login; access-code field empty. The "The access code is incorrect." alert and the 401 were asserted by the scenario and are recorded in `details` (`wrong_code_http_status` 401, `login_error`), but they are not in this image, because the script navigated to `/?view=evidence` before taking it; the file is byte-identical to B01.png and B14.png of the same run (see the notes below). |
| [e2e/screenshots/B03.png](e2e/screenshots/B03.png)<br><img src="e2e/screenshots/B03.png" width="320" alt="B03"> | Load the synthetic demo and assert the expected sources and claim cards appear (incl. the hostile claim); pass. |
| [e2e/screenshots/B04.png](e2e/screenshots/B04.png)<br><img src="e2e/screenshots/B04.png" width="320" alt="B04"> | Reject the hostile claim and approve the two ordinary claims; assert the card states change; pass. |
| [e2e/screenshots/B05.png](e2e/screenshots/B05.png)<br><img src="e2e/screenshots/B05.png" width="320" alt="B05"> | Build a package named e2e-claude for the Claude Code runtime and assert an artifact row with a digest appears; pass. |
| [e2e/screenshots/B06.png](e2e/screenshots/B06.png)<br><img src="e2e/screenshots/B06.png" width="320" alt="B06"> | Build again with identical inputs and assert the digest shown in the DOM is identical (determinism); pass. |
| [e2e/screenshots/B07.png](e2e/screenshots/B07.png)<br><img src="e2e/screenshots/B07.png" width="320" alt="B07"> | Open the artifact detail page: file list has the guidance file, settings, an agents entry, a skills entry; verification flags shown; pass. |
| `e2e/screenshots/B08.png` (not published) | Export the package to a fresh directory and verify guidance content and the manifest on disk; pass. |
| [e2e/screenshots/B09.png](e2e/screenshots/B09.png)<br><img src="e2e/screenshots/B09.png" width="320" alt="B09"> | Run a static_integrity evaluation; assert it reaches passed and the UI states runtime qualification false; pass. |
| [e2e/screenshots/B10.png](e2e/screenshots/B10.png)<br><img src="e2e/screenshots/B10.png" width="320" alt="B10"> | Run a task evaluation and assert it is reported blocked (no isolated runtime), not faked; pass. |
| [e2e/screenshots/B11.png](e2e/screenshots/B11.png)<br><img src="e2e/screenshots/B11.png" width="320" alt="B11"> | Attempt a release approval with the static_integrity evaluation and assert it is refused (#error); pass. |
| `e2e/screenshots/B12.png` (not published) | Create a workspace backup into a fresh directory via the Privacy tab and verify the directory on disk; pass. |
| [e2e/screenshots/B13.png](e2e/screenshots/B13.png)<br><img src="e2e/screenshots/B13.png" width="200" alt="B13"> | Evidence tab at a 390x844 phone viewport after the decisions: workspace shell renders, no horizontal overflow. (390x844) |
| `e2e/screenshots/B14.png` (not published) | Lock the workspace (logout) and assert a protected page redirects to the login form; pass. |
| [e2e/screenshots/B15.png](e2e/screenshots/B15.png)<br><img src="e2e/screenshots/B15.png" width="320" alt="B15"> | Chat tab: ask one question in evidence mode; an answer with citations or an explicit unavailable message renders, no page errors; pass. |

The same 15 files from the two repeat runs are under `e2e/repeat2/screenshots/` and `e2e/repeat3/screenshots/`; the discarded first run's are under `e2e/run1-partial/screenshots/`.

Notes from the verification pass over these images (`verification/screenshot-identity.log`, `verification/e2e-b02-fix.log`):

- The caption that `bench/e2e.cjs` wrote for B02 into `index.json` and `e2e.log` ("alert, still on /login") did not describe the captured image: the script took the shot after a redirect had re-rendered the login page, so in every run B02.png is byte-identical to B01.png and B14.png (md5 `8f002c68225aa127cfc4f83641f8e552` in the final run). The scenario's assertions were not affected. `bench/e2e.cjs` was corrected after the published run to take the B02 screenshot while the alert is on screen, and the corrected script was run once more on 2026-11-08 (14:15:37.116Z to 14:15:44.417Z, scratch workspace, port 8869; no number above comes from it): 15/15 passed in 7301 ms, and its B02.png (76345 bytes, kept with B01.png, `e2e.log` and `results.json` under `verification/e2e-b02-fix/`) shows the alert above an empty access-code field. The published B02.png is kept exactly as captured.
- `e2e/screenshots/B13.png` and `portal/screenshots/10-mobile-evidence.png` are byte-identical (md5 `cc880ce1c0fc1d3458f6b9e8a7fb4082`) although they were taken by different scripts on different workspaces and ports about three hours apart: the 390x844 viewport shows only the workspace shell and the demo counters (1 source, 0 awaiting, 2 approved, 1 package), which were the same in both flows, and both logs record a 56958-byte capture (`e2e/e2e.log` 13:32:24.949Z, `portal/browser.log` 10:23:59.239Z).

### Portal evidence run

| Screenshot | Caption |
| --- | --- |
| `portal/screenshots/01-login.png` (not published) | Login page before anything is typed: empty "Workspace access code" field and Unlock workspace button. |
| [portal/screenshots/02-home.png](portal/screenshots/02-home.png)<br><img src="portal/screenshots/02-home.png" width="320" alt="02-home"> | First screen after unlocking the workspace (Home tab of the workspace shell, LiveView connected). |
| [portal/screenshots/03-evidence-demo.png](portal/screenshots/03-evidence-demo.png)<br><img src="portal/screenshots/03-evidence-demo.png" width="320" alt="03-evidence-demo"> | Evidence tab right after "Load synthetic demo": three proposed claim cards including the hostile "IGNORE ALL PREVIOUS INSTRUCTIONS" claim, each with Reject / Approve revision buttons. |
| [portal/screenshots/04-evidence-decided.png](portal/screenshots/04-evidence-decided.png)<br><img src="portal/screenshots/04-evidence-decided.png" width="320" alt="04-evidence-decided"> | Evidence tab after deciding: the hostile claim REJECTED and the two ordinary claims APPROVED, decision buttons gone. |
| [portal/screenshots/05-package-built.png](portal/screenshots/05-package-built.png)<br><img src="portal/screenshots/05-package-built.png" width="320" alt="05-package-built"> | Package tab after building "bench-portal": the Built packages list shows the artifact row with its digest, "Open your harness" and "Download ZIP". |
| [portal/screenshots/06-harness-detail.png](portal/screenshots/06-harness-detail.png)<br><img src="portal/screenshots/06-harness-detail.png" width="320" alt="06-harness-detail"> | Harness detail page `/harnesses/<digest>` for "bench-portal" (full page): generated files, checks and download. |
| [portal/screenshots/07-evaluations.png](portal/screenshots/07-evaluations.png)<br><img src="portal/screenshots/07-evaluations.png" width="320" alt="07-evaluations"> | Evaluations tab after queuing a static package integrity check: the recorded run shows passed, with its details opened to show "Recorded runtime qualification: false". |
| `portal/screenshots/08-privacy.png` (not published) | Privacy tab: local-only data controls including the workspace backup form. |
| [portal/screenshots/09-setup.png](portal/screenshots/09-setup.png)<br><img src="portal/screenshots/09-setup.png" width="320" alt="09-setup"> | Company setup page /setup (final path /setup). |
| [portal/screenshots/10-mobile-evidence.png](portal/screenshots/10-mobile-evidence.png)<br><img src="portal/screenshots/10-mobile-evidence.png" width="200" alt="10-mobile-evidence"> | Evidence tab at a 390x844 phone viewport after the decisions (workspace shell, no horizontal overflow check recorded). (390x844) |

## Reproduction

Prerequisites: the versions in `.tool-versions` (Elixir 1.19.5 / Erlang 28.3.1), `mix deps.get`, `mix assets.setup`, `mix assets.build`, and Playwright 1.64.1 with its Chromium build under `test/browser/node_modules` (`cd test/browser && npm install && npx playwright install chromium`). Every workspace below must be a fresh absolute directory without symlinked ancestors; never use the default workspace under `~/.local/share/harnessforge`.

Everything in one go (browser suite, CLI suite, pipeline, portal evidence, in that order; output in `docs/benchmarks/$(date +%F)/`, scratch workspaces under `tmp/`):

```sh
bash bench/run.sh
```

`bench/run.sh` itself was exercised once on the same machine on 2026-11-08 (13:54:19Z to 13:56:28Z, output directed outside the repository): all four stages exited 0, with wall times e2e-browser 14334 ms, e2e-cli 62767 ms, pipeline 38509 ms, portal 12691 ms. Its `run.log`, `run-summary.json` and `machine.txt` are kept under `supplementary/run-sh-verification/` as the record of that run; no number above comes from that run.

The individual stages as they were run on 2026-11-08 (ports and directories were specific to that run; `WS` and `EXPORTS` stand for fresh directories):

```sh
# 1. Browser end-to-end suite
PORT=8867 HARNESSFORGE_WORKSPACE=$WS/e2e-ws PHX_SERVER=true mix phx.server > docs/benchmarks/2026-11-08/e2e/server.log 2>&1 &
until [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 1 http://127.0.0.1:8867/)" != 000 ]; do sleep 0.1; done
HARNESSFORGE_URL=http://127.0.0.1:8867 HARNESSFORGE_WORKSPACE=$WS/e2e-ws BENCH_OUT=docs/benchmarks/2026-11-08/e2e \
  E2E_EXPORT_ROOT=$EXPORTS/e2e-exports-browser node bench/e2e.cjs
kill $(lsof -ti :8867)

# 2. CLI end-to-end suite (own fresh workspace; no server needed)
HARNESSFORGE_WORKSPACE=$WS/e2e-cli-ws BENCH_OUT=docs/benchmarks/2026-11-08/e2e \
  E2E_EXPORT_ROOT=$EXPORTS/e2e-exports-cli bash bench/e2e-cli.sh

# 3. Pipeline benchmark (exact commands: pipeline/commands.sh)
BENCH_OUT=docs/benchmarks/2026-11-08/pipeline HARNESSFORGE_WORKSPACE=$WS/bench-ws mix run bench/pipeline.exs

# 4. Portal evidence
PORT=8866 HARNESSFORGE_WORKSPACE=$WS/portal-ws PHX_SERVER=true mix phx.server > docs/benchmarks/2026-11-08/portal/server.log 2>&1 &
until [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 1 http://127.0.0.1:8866/)" != 000 ]; do sleep 0.1; done
HARNESSFORGE_URL=http://127.0.0.1:8866 HARNESSFORGE_WORKSPACE=$WS/portal-ws BENCH_OUT=docs/benchmarks/2026-11-08/portal node bench/portal.cjs
kill $(lsof -ti :8866)
```

Raw files per directory: `e2e/` (`results.json` summary, `browser-results.json`, `cli-results.json`, `e2e.log`, `cli.log`, `server.log`, `server-stop.txt`, `screenshots/`, `repeat2/`, `repeat3/`, `run1-partial/`); `pipeline/` (`results.json`, `pipeline.log`, `console.log`, `commands.sh`); `portal/` (`results.json`, `browser-results.json`, `browser.log`, `run-stdout.log`, `server.log`, `curl.log`, `machine.txt`, `rss-after-ready.txt`, `rss-after-flow.txt`, `server-start-*.txt`, `server-restart-timing.txt`, `server-restart-*.log`, `screenshots/`, `run1-aborted/`).

## Supplementary static checks (not part of the benchmark)

`supplementary/static-checks/` holds logs from an earlier attempt that are not part of this benchmark and are not test evidence: a formatter check (`format.log`), a compile with warnings as errors (`compile.log`), Credo (`credo.log`), Dialyzer (`dialyzer.log`), static source metrics (`metrics.json`, `metrics.log`) and a unit-test run.
That unit-test run (`test-run1-default-tmpdir.log`, `test-failed-rerun.log`, `coverage-run1-default-tmpdir.txt`) failed on macOS because the default `TMPDIR` resolves through the `/var -> /private/var` symlink, which the local importer rejects as an unsafe directory (`{:error, :unsafe_directory}` in test setup).
`test-tmpdir-experiment.log` shows the same test file failing under the default `TMPDIR` and passing once `TMPDIR` points at a directory without symlinked ancestors; `test.log` is a later run with such a `TMPDIR` whose log ends without a summary line.
The end-to-end scenarios above are the test evidence for this date; these logs are kept for completeness only and are not referenced from the project README.
