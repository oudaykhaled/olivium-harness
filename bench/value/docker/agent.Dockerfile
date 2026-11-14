# olivium-bench-agent-<task_id>:v1
# Build: docker build -f bench/value/docker/agent.Dockerfile \
#          --build-arg DEPS_IMAGE=olivium-bench-deps-<task_id>:v1 \
#          --label olivium-bench=1 -t olivium-bench-agent-<task_id>:v1 bench/value/docker
#
# Node comes from node:22-slim (Claude Code 2.1.311 needs node >= 22) so the same
# file works on both python:3.12 and node:22 task images.
ARG DEPS_IMAGE=DEPS_IMAGE-build-arg-is-required
FROM node:22-slim AS node_src

FROM ${DEPS_IMAGE}
LABEL olivium-bench="1"

COPY --from=node_src /usr/local/bin/node /usr/local/bin/node
COPY --from=node_src /usr/local/lib/node_modules /usr/local/lib/node_modules

# Scripts stay enabled for this one package: its postinstall selects the native
# binary. The version is pinned; nothing from the task repository runs here.
RUN set -eux; \
    ln -sfn ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm; \
    ln -sfn ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates git ripgrep; \
    rm -rf /var/lib/apt/lists/*; \
    npm install -g --no-audit --no-fund --no-update-notifier @anthropic-ai/claude-code@2.1.311; \
    npm cache clean --force >/dev/null 2>&1 || true; \
    test "$(claude --version | cut -d' ' -f1)" = "2.1.311"; \
    rg --version >/dev/null; git --version >/dev/null; \
    useradd --uid 1001 --create-home --home-dir /home/agent --shell /bin/bash agent; \
    mkdir -p /work/repo /work/in /work/out; \
    chown -R agent:agent /work /home/agent

COPY --chmod=0555 agent-run.sh /usr/local/bin/olivium-agent-run
COPY --chmod=0555 probe.sh /usr/local/bin/olivium-probe

# No update checks, telemetry or error reports. Docker also gives this container
# no route anywhere except the meter, so these are a second layer.
ENV HOME=/home/agent \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    DISABLE_TELEMETRY=1 \
    DISABLE_ERROR_REPORTING=1 \
    DISABLE_BUG_COMMAND=1 \
    DISABLE_AUTOUPDATER=1 \
    CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY=1 \
    CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL=1 \
    NPM_CONFIG_UPDATE_NOTIFIER=false \
    NO_UPDATE_NOTIFIER=1

USER agent
WORKDIR /work/repo
CMD ["/usr/local/bin/olivium-agent-run"]
