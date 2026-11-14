#!/bin/bash
# Runs one learner session inside the learner container (olivium-bench-learner:v1).
#   in : /work/in/prompt.txt, /work/in/settings.json, /work/in/learn-input.json, /work/in/views/*
#        /work/repo (the repository at the base, read only for this user)
#   out: /work/out/learned.raw.json (written by the model), transcript.jsonl, stderr.log,
#        exit_code, wall_seconds
# Env: LEARN_MODEL, LEARN_MAX_TURNS, LEARN_TIMEOUT_S, ANTHROPIC_BASE_URL (the meter) and a
#      dummy ANTHROPIC_API_KEY; the real key, if any, lives only in the meter container.
set -u
out=/work/out
mkdir -p "$out"
if [ ! -s /work/in/prompt.txt ] || [ ! -s /work/in/settings.json ]; then
    echo "missing /work/in/prompt.txt or settings.json" >"$out/stderr.log"
    echo 2 >"$out/exit_code"
    exit 2
fi
started=$(date +%s)
cd /work || exit 2
timeout --signal=TERM --kill-after=30 "${LEARN_TIMEOUT_S:-900}" \
    claude -p --output-format stream-json --verbose \
        --model "${LEARN_MODEL:-claude-haiku-5-5}" \
        --max-turns "${LEARN_MAX_TURNS:-15}" \
        --permission-mode bypassPermissions \
        --settings /work/in/settings.json \
        --disallowedTools "WebSearch,WebFetch" \
        </work/in/prompt.txt >"$out/transcript.jsonl" 2>"$out/stderr.log"
code=$?
echo "$code" >"$out/exit_code"
echo "$(( $(date +%s) - started ))" >"$out/wall_seconds"
exit "$code"
