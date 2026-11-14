#!/bin/bash
# Runs one Claude Code session inside the agent container.
#   in : /work/in/prompt.txt (required), /work/in/settings.json (optional)
#   out: /work/out/transcript.jsonl, stderr.log, exit_code, wall_seconds
# Env: BENCH_MODEL, BENCH_MAX_TURNS, BENCH_TIMEOUT_S, BENCH_PERMISSION_MODE,
#      BENCH_INCLUDE_HOOK_EVENTS, BENCH_DISALLOW_WEB (protocol 2),
#      ANTHROPIC_BASE_URL and a dummy ANTHROPIC_API_KEY (set at docker create).
set -u
out=/work/out
mkdir -p "$out"
if [ ! -s /work/in/prompt.txt ]; then
    echo "missing /work/in/prompt.txt" >"$out/stderr.log"
    echo 2 >"$out/exit_code"
    exit 2
fi
args=(-p --output-format stream-json --verbose
      --model "${BENCH_MODEL:-claude-sonnet-5-5}"
      --max-turns "${BENCH_MAX_TURNS:-60}"
      --permission-mode "${BENCH_PERMISSION_MODE:-bypassPermissions}")
if [ -f /work/in/settings.json ]; then
    args+=(--settings /work/in/settings.json)
fi
# Protocol v2 records hook lifecycle events in the transcript. Empty in the pilot.
if [ "${BENCH_INCLUDE_HOOK_EVENTS:-}" = "1" ]; then
    args+=(--include-hook-events)
fi
# Protocol v2 removes the web tools from every arm alike: WebSearch runs on the
# API side, past the container's network isolation. One comma-separated argument,
# so the variadic option cannot take anything else. Empty in the pilot.
if [ "${BENCH_DISALLOW_WEB:-}" = "1" ]; then
    args+=(--disallowedTools "WebSearch,WebFetch")
fi
started=$(date +%s)
cd /work/repo || exit 2
timeout --signal=TERM --kill-after=30 "${BENCH_TIMEOUT_S:-1200}" \
    claude "${args[@]}" </work/in/prompt.txt >"$out/transcript.jsonl" 2>"$out/stderr.log"
code=$?
echo "$code" >"$out/exit_code"
echo "$(( $(date +%s) - started ))" >"$out/wall_seconds"
exit "$code"
