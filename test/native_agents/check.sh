#!/bin/sh
# Dependency installation happens at image build time. The probe runs offline.
set -eu
probe_project_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$probe_project_root"
MIX_ENV=test mix run --no-start test/native_agents/export.ex >&2
docker build --quiet --tag harnessforge/native-agent-probe:codex-0.156.0-claude-2.1.311 tmp/native-agent-probe >&2
docker image inspect --format '{{.Id}}' harnessforge/native-agent-probe:codex-0.156.0-claude-2.1.311 >&2
docker run --rm \
  --label dev.harnessforge.native_probe=2026-10-31 \
  --network none --read-only --cap-drop ALL \
  --security-opt no-new-privileges --user 1000:1000 \
  --memory 1g --cpus 1 --pids-limit 128 \
  --tmpfs /tmp:rw,noexec,nosuid,size=128m,uid=1000,gid=1000 \
  --tmpfs /home/node:rw,noexec,nosuid,size=128m,uid=1000,gid=1000 \
  harnessforge/native-agent-probe:codex-0.156.0-claude-2.1.311
