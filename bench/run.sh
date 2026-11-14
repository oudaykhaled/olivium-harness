#!/usr/bin/env bash
# bench/run.sh - reproduce the Olivium Harness benchmark and end-to-end evidence in one command.
#
# Stages, in this order (each stage runs even if an earlier one failed; the exit status is 1 if any failed):
#   1. e2e-browser  start `mix phx.server` on a free port with a fresh workspace under tmp/, wait until it answers,
#                   run `node bench/e2e.cjs`, stop the server
#   2. e2e-cli      run `bash bench/e2e-cli.sh` with its own fresh workspace (no server)
#   3. pipeline     run `BENCH_OUT=... HARNESSFORGE_WORKSPACE=... mix run bench/pipeline.exs` on a fresh workspace
#   4. portal       start `mix phx.server` on a free port with another fresh workspace, run `node bench/portal.cjs`,
#                   probe `/` and `/login` with curl, stop the server
#   5. e2e-learn    opt-in (name it in BENCH_STAGES): run `bash bench/e2e-learn.sh` ($0, mock meter) with its own fresh
#                   workspace; it needs Docker, LEARN_REPO (a pallets/click repository at the base of
#                   test/fixtures/learning/plan-click.json) and VERIFY_IMAGE (that repository's deps image); METER_IMAGE,
#                   DOCKER_SLOT and CHECK_LEARNED are passed through. Asked for without LEARN_REPO or VERIFY_IMAGE, the
#                   stage fails (exit 2); it is never skipped quietly.
#   6. e2e-native   opt-in: writes the synthetic repository of bench/native/fixture.sh under the scratch root, generates
#                   it twice with bin/harnessforge (skills and subagents all, and --native none), writes and generates
#                   its three-area variant (fixture.sh AREAS=3, three area skills), then runs
#                   `python3 -I bench/native/probe.py`: real Claude Code in NATIVE_PROBE_IMAGE (default
#                   olivium-bench-agent-pallets-click-3858:v1) against bench/value/meter/meter.py in mock mode on an
#                   internal Docker network ($0, no key), checks E-N1..E-N8 and writes native/native-probe.json.
#                   DOCKER_SLOT is passed through; NATIVE_PROBE_METER_IMAGE (default olivium-bench-meter:v1). Without
#                   Docker or an image the probe writes status unavailable and the stage fails; it is never skipped.
#
# Usage:  bash bench/run.sh            (from any directory; the script changes to the repository root)
#
# Environment (all optional):
#   BENCH_OUT_ROOT         evidence root; default docs/benchmarks/$(date +%F) under the repository. If that default
#                          already holds a README.md (a published evidence set), the run writes to
#                          docs/benchmarks/<date>-rerun-<UTC time> instead of overwriting it.
#   BENCH_TMP_ROOT         scratch root for workspaces, exports and corpus copies; default tmp/bench-<UTC timestamp>
#                          under the repository. Must be an absolute path without symlinked ancestors. The default
#                          is removed after a fully successful run; a caller-supplied root is always kept.
#   BENCH_STAGES           comma-separated subset of e2e-browser,e2e-cli,pipeline,portal,e2e-learn,e2e-native (default:
#                          the first four; e2e-learn and e2e-native run only when named).
#   BENCH_KEEP_TMP=1       keep the default scratch root even after a successful run.
#   BENCH_READY_TIMEOUT_S  seconds to wait for a portal instance to answer (default 120).
#   BENCH_CORPUS_SRC, BENCH_MAX_FILES, BENCH_MAX_TOTAL_BYTES, BENCH_SKIP_SHELL, BENCH_NAV_SAMPLES, BENCH_PACKAGE_NAME,
#   E2E_STEP_TIMEOUT_MS, E2E_EVAL_TIMEOUT_MS, PLAYWRIGHT_CHROMIUM_EXECUTABLE are passed through to the scripts.
#
# Guarantees: the default workspace (~/.local/share/harnessforge) is never used (HARNESSFORGE_WORKSPACE is set
# explicitly for every command and cleared otherwise); `mix test` is never run; git is never run except a read-only
# `git rev-parse HEAD` / `git status --porcelain` for machine.txt when git is available; only bash, mix, node, curl,
# lsof and python3 plus the standard utilities date, mkdir, rm, kill, ps, sleep, tee, tr, head, tail and wc are used
# (the opt-in e2e-learn stage also uses docker, for the learner, meter and verification containers; the opt-in
# e2e-native stage uses git to write its synthetic repository under the scratch root, and docker for the meter and
# the Claude Code containers, all named olivium-bench-native-*).
# Workspace access tokens are read only inside bench/e2e.cjs and bench/portal.cjs and never printed.
#
# Output layout under BENCH_OUT_ROOT:
#   run.log, run-summary.json, machine.txt
#   e2e/      results.json (browser suite), e2e.log, screenshots/, server.log, server-start-timing.txt, stdout.log,
#             cli-results.json, cli.log
#   pipeline/ results.json, pipeline.log, console.log
#   portal/   browser-results.json, browser.log, screenshots/, server.log, server-start-timing.txt,
#             rss-after-ready.txt, rss-after-flow.txt, curl.log, stdout.log
#   learn/    stdout.log (e2e-learn only; its per-check files stay under the scratch root, e2e-learn-out/)
#   native/   native-probe.json, stdout.log, generate-all.json, generate-none.json, generate-three.json (e2e-native
#             only; captures and
#             transcripts stay under the scratch root, native-probe/runs/)
#
# Written for bash 3.2 (the macOS default) and later.

set -u
set -o pipefail

PROJECT=$(cd "$(dirname "$0")/.." && pwd -P)
cd "$PROJECT" || exit 2

unset HARNESSFORGE_WORKSPACE
unset PHX_SERVER

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
TODAY=$(date +%F)
READY_TIMEOUT=${BENCH_READY_TIMEOUT_S:-120}
STAGES=${BENCH_STAGES:-e2e-browser,e2e-cli,pipeline,portal}
KEEP_TMP=${BENCH_KEEP_TMP:-0}
FAILED=0
SERVER_PID=""
SERVER_PORT=""
READY_MS=""
READY_CODE=""
STAGE_LINES=()

# ---------------------------------------------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------------------------------------------

iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

now_ms() { python3 -I -c 'import time; print(int(time.time() * 1000))'; }

log() {
  local line
  line="$(iso_now) $*"
  printf '%s\n' "$line"
  if [ -n "${RUN_LOG:-}" ]; then printf '%s\n' "$line" >> "$RUN_LOG"; fi
}

die() { log "error: $*"; exit 2; }

has_stage() {
  case ",$STAGES," in
    *",$1,"*) return 0 ;;
    *) return 1 ;;
  esac
}

# Run a command, append its combined output to a file and echo it; return the command's own exit status.
run_logged() {
  local file=$1
  shift
  log "run: $*"
  "$@" 2>&1 | tee -a "$file"
  return "${PIPESTATUS[0]}"
}

# True while the process exists and is not a zombie (our own children stay zombies until waited for).
proc_alive() {
  local st
  st=$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ')
  [ -n "$st" ] && [ "${st#Z}" = "$st" ]
}

free_port() {
  local port tries=0
  while [ "$tries" -lt 20 ]; do
    port=$(python3 -I -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()') || return 1
    if [ -z "$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null)" ]; then
      printf '%s\n' "$port"
      return 0
    fi
    tries=$((tries + 1))
  done
  return 1
}

# start_server PORT WORKSPACE LOGFILE  -> sets SERVER_PID / SERVER_PORT
start_server() {
  local port=$1 ws=$2 logfile=$3
  mkdir -p "$ws"
  log "start: PORT=$port HARNESSFORGE_WORKSPACE=$ws PHX_SERVER=true mix phx.server > $logfile"
  PORT=$port HARNESSFORGE_WORKSPACE=$ws PHX_SERVER=true mix phx.server > "$logfile" 2>&1 < /dev/null &
  SERVER_PID=$!
  SERVER_PORT=$port
}

# wait_ready PORT PID TIMEOUT_S  -> READY_MS, READY_CODE; 0 when the portal answered
wait_ready() {
  local port=$1 pid=$2 timeout=$3 t0 code polls=0 max_polls
  max_polls=$((timeout * 10))
  t0=$(now_ms)
  READY_MS=""
  READY_CODE=""
  while :; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 1 "http://127.0.0.1:$port/" 2>/dev/null)
    if [ -n "$code" ] && [ "$code" != "000" ]; then
      READY_MS=$(( $(now_ms) - t0 ))
      READY_CODE=$code
      return 0
    fi
    if ! proc_alive "$pid"; then
      READY_MS=$(( $(now_ms) - t0 ))
      READY_CODE=exited
      return 1
    fi
    polls=$((polls + 1))
    if [ "$polls" -ge "$max_polls" ]; then
      READY_MS=$(( $(now_ms) - t0 ))
      READY_CODE=timeout
      return 1
    fi
    sleep 0.1
  done
}

stop_server() {
  local p i=0 t0 t1 leftover
  [ -n "$SERVER_PID" ] || return 0
  t0=$(now_ms)
  kill "$SERVER_PID" 2>/dev/null
  for p in $(lsof -ti :"$SERVER_PORT" 2>/dev/null); do kill "$p" 2>/dev/null; done
  while proc_alive "$SERVER_PID" || [ -n "$(lsof -ti :"$SERVER_PORT" 2>/dev/null)" ]; do
    i=$((i + 1))
    if [ "$i" -ge 300 ]; then
      log "portal pid $SERVER_PID did not exit within 30 s after SIGTERM; sending SIGKILL"
      kill -9 "$SERVER_PID" 2>/dev/null
      for p in $(lsof -ti :"$SERVER_PORT" 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
      break
    fi
    sleep 0.1
  done
  wait "$SERVER_PID" 2>/dev/null
  t1=$(now_ms)
  leftover=$(lsof -ti :"$SERVER_PORT" 2>/dev/null | tr '\n' ' ')
  log "stopped portal pid $SERVER_PID on port $SERVER_PORT after $((t1 - t0)) ms; lsof -ti :$SERVER_PORT -> '${leftover}'"
  SERVER_PID=""
  SERVER_PORT=""
}

record_stage() { # NAME EXIT_STATUS WALL_MS COMMAND
  local line
  printf -v line '%s\t%s\t%s\t%s' "$1" "$2" "$3" "$4"
  STAGE_LINES+=("$line")
  [ "$2" -eq 0 ] || FAILED=1
}

run_stage() { # NAME FUNCTION COMMAND_DESCRIPTION
  local name=$1 fn=$2 desc=$3 t0 t1 rc
  log "=== stage $name: start"
  t0=$(now_ms)
  "$fn"
  rc=$?
  t1=$(now_ms)
  log "=== stage $name: exit=$rc wall_ms=$((t1 - t0))"
  record_stage "$name" "$rc" "$((t1 - t0))" "$desc"
}

skip_stage() { log "=== stage $1: skipped (BENCH_STAGES=$STAGES)"; }

cleanup() {
  stop_server
  if [ "$TMP_IS_DEFAULT" = "1" ]; then
    if [ "$KEEP_TMP" = "1" ] || [ "$FAILED" -ne 0 ]; then
      log "scratch root kept for inspection: $TMP_ROOT"
    else
      rm -rf "$TMP_ROOT"
      log "scratch root removed: $TMP_ROOT"
    fi
  else
    log "caller-supplied scratch root kept: $TMP_ROOT"
  fi
}

# ---------------------------------------------------------------------------------------------------------------
# preflight
# ---------------------------------------------------------------------------------------------------------------

for tool in bash mix node curl lsof python3; do
  command -v "$tool" > /dev/null 2>&1 || die "required tool not found: $tool"
done

if has_stage e2e-browser || has_stage portal; then
  [ -f "$PROJECT/test/browser/node_modules/playwright/package.json" ] ||
    die "Playwright is not installed under test/browser/node_modules; run: (cd test/browser && npm install && npx playwright install chromium)"
fi

OUT_ROOT=${BENCH_OUT_ROOT:-}
if [ -z "$OUT_ROOT" ]; then
  OUT_ROOT=$PROJECT/docs/benchmarks/$TODAY
  if [ -f "$OUT_ROOT/README.md" ]; then
    OUT_ROOT=$PROJECT/docs/benchmarks/$TODAY-rerun-$(date -u +%H%M%S)
  fi
fi
case $OUT_ROOT in
  /*) ;;
  *) OUT_ROOT=$PROJECT/$OUT_ROOT ;;
esac
mkdir -p "$OUT_ROOT" || die "cannot create $OUT_ROOT"
RUN_LOG=$OUT_ROOT/run.log
: > "$RUN_LOG"

TMP_IS_DEFAULT=0
if [ -n "${BENCH_TMP_ROOT:-}" ]; then
  TMP_ROOT=$BENCH_TMP_ROOT
else
  TMP_ROOT=$PROJECT/tmp/bench-$STAMP
  TMP_IS_DEFAULT=1
fi
case $TMP_ROOT in
  /*) ;;
  *) die "BENCH_TMP_ROOT must be an absolute path: $TMP_ROOT" ;;
esac
case $TMP_ROOT in
  "${HOME:-/nonexistent}/.local/share/harnessforge"*) die "BENCH_TMP_ROOT must not point at the default workspace tree: $TMP_ROOT" ;;
esac
mkdir -p "$TMP_ROOT" || die "cannot create $TMP_ROOT"
TMP_PHYS=$(cd "$TMP_ROOT" && pwd -P)
if [ "$TMP_PHYS" != "$TMP_ROOT" ]; then
  log "note: scratch root resolves through a symlink; using the physical path $TMP_PHYS (workspaces reject symlinked ancestors)"
  TMP_ROOT=$TMP_PHYS
fi

trap cleanup EXIT
trap 'log "interrupted"; exit 130' INT TERM

STARTED=$(iso_now)
log "olivium harness benchmark run"
log "project=$PROJECT"
log "evidence_root=$OUT_ROOT"
log "scratch_root=$TMP_ROOT"
log "stages=$STAGES"

{
  printf 'recorded_at=%s\n' "$(iso_now)"
  printf 'project=%s\n' "$PROJECT"
  if command -v git > /dev/null 2>&1; then
    printf 'git_head=%s\n' "$(git rev-parse HEAD 2>/dev/null || printf 'unavailable')"
    printf 'git_dirty_entries=%s\n' "$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  fi
  if command -v sysctl > /dev/null 2>&1; then
    printf 'cpu=%s\n' "$(sysctl -n machdep.cpu.brand_string 2>/dev/null)"
    printf 'logical_cores=%s\n' "$(sysctl -n hw.logicalcpu 2>/dev/null)"
    printf 'memory_bytes=%s\n' "$(sysctl -n hw.memsize 2>/dev/null)"
    printf 'load_average=%s\n' "$(sysctl -n vm.loadavg 2>/dev/null)"
  fi
  if command -v sw_vers > /dev/null 2>&1; then printf 'os=%s\n' "$(sw_vers 2>/dev/null | tr '\n' ' ')"; fi
  printf 'kernel=%s\n' "$(uname -sr 2>/dev/null)"
  printf 'node=%s\n' "$(node --version 2>/dev/null)"
  printf 'elixir=%s\n' "$(elixir --version 2>/dev/null | tail -1)"
  printf 'playwright=%s\n' "$(node -e 'try{process.stdout.write(require(process.argv[1]).version)}catch(e){process.stdout.write("not installed")}' "$PROJECT/test/browser/node_modules/playwright/package.json" 2>/dev/null)"
} > "$OUT_ROOT/machine.txt" 2>&1

# ---------------------------------------------------------------------------------------------------------------
# stages
# ---------------------------------------------------------------------------------------------------------------

stage_e2e_browser() {
  local ws=$TMP_ROOT/e2e-ws exports=$TMP_ROOT/e2e-exports-browser out=$OUT_ROOT/e2e port rc
  mkdir -p "$out"
  port=$(free_port) || { log "no free loopback port found"; return 1; }
  start_server "$port" "$ws" "$out/server.log"
  if ! wait_ready "$port" "$SERVER_PID" "$READY_TIMEOUT"; then
    log "portal on 127.0.0.1:$port did not answer ($READY_CODE after $READY_MS ms); see $out/server.log"
    stop_server
    return 1
  fi
  printf 'port=%s start_to_ready_ms=%s first_http_code=%s poll_interval_s=0.1 workspace=%s\n' \
    "$port" "$READY_MS" "$READY_CODE" "$ws" > "$out/server-start-timing.txt"
  log "portal ready on 127.0.0.1:$port after $READY_MS ms (HTTP $READY_CODE)"
  run_logged "$out/stdout.log" env HARNESSFORGE_URL="http://127.0.0.1:$port" HARNESSFORGE_WORKSPACE="$ws" \
    BENCH_OUT="$out" E2E_EXPORT_ROOT="$exports" node bench/e2e.cjs
  rc=$?
  stop_server
  return "$rc"
}

stage_e2e_cli() {
  local ws=$TMP_ROOT/e2e-cli-ws exports=$TMP_ROOT/e2e-exports-cli out=$OUT_ROOT/e2e
  mkdir -p "$out" "$ws"
  run_logged "$out/cli-stdout.log" env HARNESSFORGE_WORKSPACE="$ws" BENCH_OUT="$out" E2E_EXPORT_ROOT="$exports" \
    bash bench/e2e-cli.sh
}

stage_pipeline() {
  local ws=$TMP_ROOT/pipeline-ws out=$OUT_ROOT/pipeline
  mkdir -p "$out" "$ws"
  # bench/pipeline.exs places its corpus copy and export targets next to the workspace (here: under the scratch root)
  # and times nested `mix run` / `bin/harnessforge status` calls against the sibling workspace pipeline-ws-cli.
  run_logged "$out/console.log" env BENCH_OUT="$out" HARNESSFORGE_WORKSPACE="$ws" mix run bench/pipeline.exs
}

stage_portal() {
  local ws=$TMP_ROOT/portal-ws out=$OUT_ROOT/portal port rc pid i path
  mkdir -p "$out"
  port=$(free_port) || { log "no free loopback port found"; return 1; }
  start_server "$port" "$ws" "$out/server.log"
  if ! wait_ready "$port" "$SERVER_PID" "$READY_TIMEOUT"; then
    log "portal on 127.0.0.1:$port did not answer ($READY_CODE after $READY_MS ms); see $out/server.log"
    stop_server
    return 1
  fi
  printf 'port=%s start_to_ready_ms=%s first_http_code=%s poll_interval_s=0.1 workspace=%s\n' \
    "$port" "$READY_MS" "$READY_CODE" "$ws" > "$out/server-start-timing.txt"
  log "portal ready on 127.0.0.1:$port after $READY_MS ms (HTTP $READY_CODE)"
  pid=$(lsof -ti :"$port" 2>/dev/null | head -1)
  { printf 'measured_at=%s pid=%s comm=%s rss_kib=%s\n' "$(iso_now)" "$pid" "$(ps -o comm= -p "$pid" 2>/dev/null)" \
      "$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')"; } > "$out/rss-after-ready.txt"
  run_logged "$out/stdout.log" env HARNESSFORGE_URL="http://127.0.0.1:$port" HARNESSFORGE_WORKSPACE="$ws" \
    BENCH_OUT="$out" BENCH_SCRATCH="$TMP_ROOT" node bench/portal.cjs
  rc=$?
  { printf 'measured_at=%s pid=%s rss_kib=%s\n' "$(iso_now)" "$pid" "$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')"; } > "$out/rss-after-flow.txt"
  {
    printf '# %s curl -s -o /dev/null -w "%%{http_code} %%{size_download} %%{time_starttransfer}" (5 samples each, unauthenticated)\n' "$(iso_now)"
    for path in / /login; do
      i=0
      while [ "$i" -lt 5 ]; do
        printf '%s ' "$path"
        curl -s -o /dev/null -w '%{http_code} %{size_download} %{time_starttransfer}\n' --max-time 5 "http://127.0.0.1:$port$path" || printf 'curl_failed\n'
        i=$((i + 1))
      done
    done
  } > "$out/curl.log" 2>&1
  stop_server
  return "$rc"
}

stage_e2e_learn() {
  local ws=$TMP_ROOT/e2e-learn-ws out=$OUT_ROOT/learn
  if [ -z "${LEARN_REPO:-}" ] || [ -z "${VERIFY_IMAGE:-}" ]; then
    log "e2e-learn needs LEARN_REPO (a pallets/click repository at the mock plan's base) and VERIFY_IMAGE (its deps image);"
    log "set both, or leave e2e-learn out of BENCH_STAGES"
    return 2
  fi
  mkdir -p "$out" "$ws"
  run_logged "$out/stdout.log" env HARNESSFORGE_WORKSPACE="$ws" LEARN_OUT="$TMP_ROOT/e2e-learn-out" bash bench/e2e-learn.sh
}

# The synthetic repository is generated twice, the export with every generated skill and subagent and the export with
# --native none, and both are handed to the probe. Nothing from the repository runs on the host.
stage_e2e_native() {
  local work=$TMP_ROOT/native-probe out=$OUT_ROOT/native ws=$TMP_ROOT/native-probe/ws mode rc
  mkdir -p "$out" "$ws"
  log "run: bash bench/native/fixture.sh $work/fixture-repo"
  bash bench/native/fixture.sh "$work/fixture-repo" >> "$out/stdout.log" 2>&1 || { log "the native fixture could not be written"; return 1; }
  log "run: bash bench/native/fixture.sh $work/fixture-repo-three '' 3"
  bash bench/native/fixture.sh "$work/fixture-repo-three" "" 3 >> "$out/stdout.log" 2>&1 || { log "the three-area native fixture could not be written"; return 1; }
  log "run: HARNESSFORGE_WORKSPACE=$ws bin/harnessforge generate $work/fixture-repo-three --runtime claude_code --export $work/export-three --json"
  HARNESSFORGE_WORKSPACE=$ws bin/harnessforge generate "$work/fixture-repo-three" --runtime claude_code --export "$work/export-three" \
    --json > "$out/generate-three.json" 2>> "$out/stdout.log" || { log "generate (three areas) failed; see $out/generate-three.json"; return 1; }
  for mode in all none; do
    log "run: HARNESSFORGE_WORKSPACE=$ws bin/harnessforge generate $work/fixture-repo --runtime claude_code --export $work/export-$mode --native $mode --json"
    HARNESSFORGE_WORKSPACE=$ws bin/harnessforge generate "$work/fixture-repo" --runtime claude_code --export "$work/export-$mode" \
      --native "$mode" --json > "$out/generate-$mode.json" 2>> "$out/stdout.log"
    rc=$?
    [ "$rc" -eq 0 ] || { log "generate --native $mode exited $rc; see $out/generate-$mode.json"; return 1; }
  done
  run_logged "$out/stdout.log" ${DOCKER_SLOT:-} python3 -I bench/native/probe.py --export-all "$work/export-all" \
    --export-none "$work/export-none" --export-three "$work/export-three" --out "$out" --work "$work/runs"
}

if has_stage e2e-browser; then run_stage e2e-browser stage_e2e_browser "mix phx.server (fresh workspace, free port) + node bench/e2e.cjs"; else skip_stage e2e-browser; fi
if has_stage e2e-cli; then run_stage e2e-cli stage_e2e_cli "bash bench/e2e-cli.sh (fresh workspace)"; else skip_stage e2e-cli; fi
if has_stage pipeline; then run_stage pipeline stage_pipeline "mix run bench/pipeline.exs (fresh workspace)"; else skip_stage pipeline; fi
if has_stage portal; then run_stage portal stage_portal "mix phx.server (fresh workspace, free port) + node bench/portal.cjs + curl probes"; else skip_stage portal; fi
if has_stage e2e-learn; then run_stage e2e-learn stage_e2e_learn "bash bench/e2e-learn.sh (fresh workspace, Docker, mock meter)"; else skip_stage e2e-learn; fi
if has_stage e2e-native; then run_stage e2e-native stage_e2e_native "bench/native/fixture.sh + bin/harnessforge generate (all, none) + python3 -I bench/native/probe.py (Docker, real Claude Code, mock meter)"; else skip_stage e2e-native; fi

# ---------------------------------------------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------------------------------------------

ENDED=$(iso_now)
python3 -I - "$OUT_ROOT/run-summary.json" "$STARTED" "$ENDED" "$PROJECT" "$OUT_ROOT" "$TMP_ROOT" "$STAGES" \
  ${STAGE_LINES[@]+"${STAGE_LINES[@]}"} <<'PY'
import json
import sys

path, started, ended, project, out_root, tmp_root, stages, *lines = sys.argv[1:]
rows = []
for line in lines:
    name, status, ms, command = line.split("\t", 3)
    rows.append({"stage": name, "exit_status": int(status), "wall_ms": int(ms), "command": command})
summary = {
    "schema": "harnessforge-bench-run/1",
    "started_at": started,
    "ended_at": ended,
    "project": project,
    "evidence_root": out_root,
    "scratch_root": tmp_root,
    "stages_requested": stages.split(","),
    "stages": rows,
    "all_passed": all(r["exit_status"] == 0 for r in rows),
    "files": {
        "e2e": ["results.json", "e2e.log", "screenshots/", "server.log", "server-start-timing.txt", "stdout.log",
                "cli-results.json", "cli.log", "cli-stdout.log"],
        "pipeline": ["results.json", "pipeline.log", "console.log"],
        "portal": ["browser-results.json", "browser.log", "screenshots/", "server.log", "server-start-timing.txt",
                   "rss-after-ready.txt", "rss-after-flow.txt", "curl.log", "stdout.log"],
        "learn": ["stdout.log"],
        "native": ["native-probe.json", "stdout.log", "generate-all.json", "generate-none.json", "generate-three.json"],
    },
}
with open(path, "w") as handle:
    json.dump(summary, handle, indent=2)
    handle.write("\n")
PY

log "summary:"
for line in ${STAGE_LINES[@]+"${STAGE_LINES[@]}"}; do
  log "  $(printf '%s' "$line" | tr '\t' ' ')"
done
log "evidence written under $OUT_ROOT (run.log, run-summary.json, machine.txt, and e2e/, pipeline/, portal/, learn/ for the stages that ran)"
if [ "$FAILED" -ne 0 ]; then
  log "one or more stages failed; see the stage logs above"
  exit 1
fi
exit 0
