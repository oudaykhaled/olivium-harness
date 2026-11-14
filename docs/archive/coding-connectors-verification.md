# Codex and Claude verification — 31 October 2026

Both coding-agent exports and model APIs are implemented. This record separates
automated application checks, real native discovery, packaging, and authenticated
inference. No paid API request or model-backed coding task was performed.

| Integration | Implemented behavior | Observed evidence | Qualification limit |
| --- | --- | --- | --- |
| Codex CLI 0.156.0 | Native guidance, config, standalone agents and skills | 16 renderer tests; isolated unmodified native CLI/app-server inspection | Discovery/config checks, no inference or managed execution backend |
| Claude Code 2.1.311 | Native guidance, settings, agents and static skills | 16 renderer tests; isolated unmodified native startup | Discovery/config checks, no inference or managed execution backend |
| OpenAI Responses | Fixed endpoint, strict proposal JSON, consent, credentials by reference, metered dispatch | Synthetic HTTP requests through real Models contexts and durable ledger | Authenticated API/model availability unverified |
| Anthropic Messages | Fixed endpoint, structured proposals, consent, cache-aware usage accounting | Synthetic HTTP requests through real Models contexts and durable ledger | Authenticated API/model availability unverified |

## Application and review

Canonical `mix test`: **245 tests, zero failures, 15 existing Docker-only skips**.
The previous five source integrations remain included. The new cloud module has
16 tests; the two shared integration modules have six. Formatter, compilation
with warnings as errors, and Credo's warning gate pass. Current Dialyzer reports
exactly the two existing Ecto/MapSet opacity diagnostics in `releases.ex` lines
47 and 121; no new connector diagnostic. Its exit status remains 2.

Independent review closed in two rounds with zero open findings. Root fixed
Claude file-import handling, fenced skill context expansion, and YAML control
escaping, with regressions. The reviewer reran 28 focused tests and independently
checked quoted frontmatter against Ruby Psych. Required enforcement controls
still reject compilation; advisory native settings never qualify task execution.

Root's integration checks cover all target identities, byte-compatible OpenCode
output, tamper rejection, static integrity, unavailable managed backends, CLI
target builds, real LiveView target selection, API consent and decimal prices.
Unsupported Codex/Claude task or runtime-smoke evaluations persist blocked under
their own target identities. They cannot authorize release promotion.

## Native consumption

`test/native_agents/check.sh` builds a test-only image with pinned unmodified
Codex and Claude Code versions, exports only a synthetic fixture, and runs with
network disabled, no host mounts or credentials, a read-only root filesystem,
unprivileged user, bounded resources and fresh temporary home. The fixture
denies Bash. This is a discovery check, not an inference or enforcement claim.

Codex's native config inspection reads the project settings. Its own instruction
inspection reads the rule sentinel; skills inspection identifies the exported
skill. Native app-server thread startup detects custom agent definitions; a
malformed-agent negative control establishes that the exact exported path is
being read. No model turn is started.

Claude's stream-json startup with project settings identifies the exported agent
and skill, omits Bash and has no MCP servers. It then refuses authentication
without an API call, tokens or cost. `plugin validate` returning empty `contents`
is deliberately excluded as evidence of project agent/skill validation.

The final probe exited 0. Its test image is
`sha256:ae0c32e54968f97eba367b6f0f3c204b38d45c6866a7105772d95dd2ec40d267`.
JSON evidence is `tmp/coding-connectors-native-probe.log`; build details are
`tmp/native-agent-probe/check-build.log`. Agent/skill invocation remains unverified.

## Native app and package

The rebuilt macOS arm64 release runs on `http://localhost:8865`, loopback only.
Actual Chrome login, target selection, immutable compilation and fresh-directory
export succeeded for both Codex and Claude using two previously approved
synthetic claim revisions. All seven manifest file hashes in each export match.

| Browser artifact | Digest | Static integrity | Managed task |
| --- | --- | --- | --- |
| browser-codex | `8014c925f1f0dd4152d718f3bd7e1faf7fff2cc3a0b9ced926a48c03d4337d8d` | passed, integrity_only | blocked, runtime_backend_unavailable |
| browser-claude | `f03d7f40b30bd8de0fc423a72c88afc720dd4daae90c4bce9665407d571251ca` | passed, integrity_only | blocked, runtime_backend_unavailable |

Both records remain runtime-unqualified. Native task requests did not dispatch a
model or execute repository code. The portal's OpenAI Responses and Anthropic
forms show model ID, environment reference, price estimates and source consent.
No consent was selected or model configuration changed in this demonstration
workspace; it retains its disabled Ollama default. No horizontal overflow or
browser warning/error was observed. Screenshot:
`tmp/coding-connectors-browser-2026-10-31.jpg`.

Packaged CLI smoke passed `help/init/demo/status/runtimes`, all five existing
source connection save commands, both new target builds and both API provider
configuration/status commands. Only an isolated disposable built-in fixture
received explicit test decisions; the malicious third demo claim was excluded.
API configuration had no consent and no inference was attempted.

Archive inventory confirms both native adapters, Registry and both API adapters,
safe paths, documentation and absence of operator databases/login secrets. Its
latest checksum and byte count are in the companion verification record beside
the archive, avoiding a self-referential hash inside the packaged documentation.
The running native server owner observed after restart is PID 43484.

## Reproduce and inspect

```sh
mix test
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --only warning
test/native_agents/check.sh
packaging/build.sh
packaging/smoke.sh _build/prod/rel/harness_forge
```

Local logs are ignored rather than distributed as synthetic proof of future
runs: `tmp/coding-connectors-final-test.log`,
`tmp/coding-connectors-final-lint.log`,
`tmp/coding-connectors-dialyzer.log`, and the native probe/build/smoke records.
The native package contains the documentation and compiled adapters; it does
not include the operator workspace, API secrets or login code.

The remaining live checks require operator-selected API model IDs, dedicated
credential environment variables, exact-source consent and authorized inference.
Coding-agent subscriptions and browser sessions do not provision API credentials.
API fixture tests do not prove provider account access, price accuracy or model
quality. Existing authenticated source-connector limits are unchanged.
