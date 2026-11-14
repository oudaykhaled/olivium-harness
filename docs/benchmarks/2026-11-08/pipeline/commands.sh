#!/bin/sh
# Exact shell commands used for the 2026-11-08 pipeline benchmark run (in order).
# Project root: <repo> (commit 628676e plus uncommitted docs reorganisation)
set -eu
cd <repo>
WS=<scratch>/bench-ws
OUT=<repo>/docs/benchmarks/2026-11-08/pipeline

# 1. Fresh workspace, corpus/export scratch directories and evidence directory.
rm -rf "$WS" "$WS-cli" "$(dirname "$WS")/bench-corpus" "$(dirname "$WS")/bench-export"
mkdir -p "$WS" "$OUT"

# 2. Formatter check only (never `mix format` without --check-formatted).
mix format --check-formatted bench/pipeline.exs

# 3. The benchmark itself (step 1 inside the script spawns nested
#    `/usr/bin/time -p mix run -e :ok`, `/usr/bin/time -p bin/harnessforge status`
#    and `/usr/bin/time -p mix run --no-start -e :ok` against "$WS-cli").
export HARNESSFORGE_WORKSPACE="$WS" BENCH_OUT="$OUT"
unset PHX_SERVER
/usr/bin/time -p mix run bench/pipeline.exs > "$OUT/console.log" 2>&1
