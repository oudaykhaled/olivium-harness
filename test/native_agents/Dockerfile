# Test-only native parser image; no model, credentials or coding task is included.
FROM node@sha256:4b150b48b4116e2a22f2c39cc27025fbf4f153e2078fd3b14d159fdb5c7279da
RUN npm install --global --ignore-scripts @openai/codex@0.156.0 @anthropic-ai/claude-code@2.1.311 && node /usr/local/lib/node_modules/@anthropic-ai/claude-code/install.cjs && npm cache clean --force
WORKDIR /workspace
COPY --chown=node:node exports /workspace/exports
COPY --chown=node:node verify.cjs /workspace/verify.cjs
USER node
ENTRYPOINT ["node", "/workspace/verify.cjs"]
