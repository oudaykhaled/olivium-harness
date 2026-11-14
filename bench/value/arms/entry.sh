#!/bin/bash
# Runs first inside every agent container, as the agent user, in every arm.
# Removes any agent instruction files that shipped with the repository, then
# installs this arm's files, so all arms start from the same snapshot.
# Records what this container actually has, before the agent starts (PROTOCOL-v2.md).
set -u
cd /work/repo || exit 2
find . -path ./.git -prune -o -path ./node_modules -prune -o \
    \( -name CLAUDE.md -o -name AGENTS.md -o -name copilot-instructions.md \
       -o -name .claude -o -name .cursor \) -print0 | xargs -0 -r rm -rf --
if [ -d /work/in/arm ]; then
    cp -a /work/in/arm/. /work/repo/ || exit 2
    rm -rf /work/in/arm
fi
mkdir -p /work/out
find CLAUDE.md .claude .olivium AGENTS.md -type f -print0 2>/dev/null \
    | sort -z | xargs -0 -r sha256sum >/work/out/harness-files.sha256
if [ -f /work/in/settings.json ]; then
    sha256sum /work/in/settings.json >/work/out/settings-in.sha256
fi
exec /usr/local/bin/olivium-agent-run
