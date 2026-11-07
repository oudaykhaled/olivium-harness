# Source-owned runtime only. Build with the checked package lock; no target files.
FROM node@sha256:4b150b48b4116e2a22f2c39cc27025fbf4f153e2078fd3b14d159fdb5c7279da
# Reuse Debian's signed static utilities from the base image's fixed archive date.
# APT still verifies Debian's archive signatures and package hashes.
# These are required for the existing positive containment probes, not agent tools.
RUN printf '%s\n' \
      'deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/20261027T000000Z bookworm main' \
      'deb [check-valid-until=no] http://snapshot.debian.org/archive/debian-security/20261027T000000Z bookworm-security main' \
      > /etc/apt/sources.list && \
    rm -f /etc/apt/sources.list.d/debian.sources && \
    apt-get update && apt-get install --no-install-recommends -y busybox-static bubblewrap && \
    for utility in ip wget nslookup; do ln -s /bin/busybox /usr/local/bin/$utility; done && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /opt/harnessforge-codex
COPY package.json package-lock.json ./
RUN npm ci --ignore-scripts --omit=dev && \
    test -x node_modules/.bin/codex && \
    test "$(node_modules/.bin/codex --version)" = "codex-cli 0.156.0" && \
    npm cache clean --force
COPY preflight.cjs ./preflight.cjs
COPY requirements.toml /etc/codex/requirements.toml
# Loaded native policy roots are empty and immutable. Runtime must supply an
# equally immutable server-owned rules directory when fresh HOME is mounted over
# the image directory, and when the exact exported .codex directory is mounted.
RUN mkdir -p /etc/codex/rules /home/harnessforge/.codex/rules /candidate/.codex/rules && \
    chmod 0444 /etc/codex/requirements.toml && \
    chmod 0555 /etc/codex /etc/codex/rules \
      /home/harnessforge/.codex/rules /candidate/.codex/rules
ENV PATH="/opt/harnessforge-codex/node_modules/.bin:${PATH}" \
    HOME="/home/harnessforge" CODEX_HOME="/home/harnessforge/.codex"
USER 65534:65534
WORKDIR /candidate
# The lifecycle supplies fixed argv and fresh private tmpfs HOME. No shell entrypoint.
ENTRYPOINT []
