# Root supplies digest-qualified base/dependency image arguments and builds.
# Dependency installation/lock generation is root-owned; no networked build RUN.
ARG PYTHON_DEPENDENCY_IMAGE=harnessforge-i13-python-dependencies@sha256:cb57c3221207787c737561c9d764776a3e81c641a5c63ee1bf82c8b8a9f28c05
ARG PYTHON_BASE=python@sha256:b224e2fe306f9d303251ada22961635e5b52a69c0414a0050611be31c59f5f5b
FROM ${PYTHON_DEPENDENCY_IMAGE}
WORKDIR /app
COPY priv/graphiti_worker/ /app/
ENV GRAPHITI_TELEMETRY_ENABLED=false PYTHON_DOTENV_DISABLED=1 \
    PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
USER 65532:65532
ENTRYPOINT ["python", "-I", "/app/__main__.py"]
