# olivium-bench-learner:v1 — the AI learner's container (Claude Code 2.1.311, git, python3).
# Build: docker build -t olivium-bench-learner:v1 -f priv/learner/Dockerfile priv/learner
#
# The container runs on an internal Docker network whose only peer is the meter; it never
# holds an API key. Nothing from the analyzed repository is installed or run at build time.
FROM node:22-slim AS node_src

FROM python:3.12-slim
LABEL olivium-bench="1" \
      olivium.claude-code-version="2.1.311"

COPY --from=node_src /usr/local/bin/node /usr/local/bin/node
COPY --from=node_src /usr/local/lib/node_modules /usr/local/lib/node_modules

# Scripts stay enabled for this one pinned package: its postinstall selects the native binary.
RUN set -eux; \
    ln -sfn ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates git ripgrep; \
    rm -rf /var/lib/apt/lists/*; \
    npm install -g --no-audit --no-fund --no-update-notifier @anthropic-ai/claude-code@2.1.311; \
    npm cache clean --force >/dev/null 2>&1 || true; \
    test "$(claude --version | cut -d' ' -f1)" = "2.1.311"; \
    git --version >/dev/null; python3 --version >/dev/null; \
    useradd --uid 1001 --create-home --home-dir /home/learner --shell /bin/bash learner; \
    mkdir -p /work/repo /work/in /work/out; \
    chown learner:learner /work/out /home/learner; \
    git config --system --add safe.directory '*'

COPY --chmod=0555 learn-run.sh /usr/local/bin/olivium-learn-run

ENV HOME=/home/learner \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    DISABLE_TELEMETRY=1 \
    DISABLE_ERROR_REPORTING=1 \
    DISABLE_BUG_COMMAND=1 \
    DISABLE_AUTOUPDATER=1 \
    CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY=1 \
    CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL=1 \
    NPM_CONFIG_UPDATE_NOTIFIER=false \
    NO_UPDATE_NOTIFIER=1 \
    PYTHONDONTWRITEBYTECODE=1

USER learner
WORKDIR /work
CMD ["/usr/local/bin/olivium-learn-run"]
