# Olivium Harness

<p align="center">
  <img src="docs/assets/olivium-harness-logo.png" width="144" alt="Olivium Harness logo">
</p>

**Context in. Capability out.**

[Website deployment](https://github.com/oudaykhaled/olivium-harness-website#current-hosting-status) · [Website source (private)](https://github.com/oudaykhaled/olivium-harness-website)

Build an inspectable coding-agent harness from evidence your team has reviewed.
Olivium Harness is a local Elixir/OTP application with a Phoenix LiveView portal. It
imports selected sources, keeps citations and immutable claim revisions, records
human decisions, and compiles approved context into a deterministic native
package for OpenCode, Codex CLI or Claude Code.

**Status: local development candidate, version 0.1.0; no public release has been
published.** Package export works independently of runtime qualification. A
static check or container smoke cannot promote a release. Real coding-task
qualification needs an available, explicitly selected model and a successful
isolated evaluation. See [current status and limits](docs/status.md).

## Try the synthetic demo

Install the versions in `.tool-versions` (Elixir 1.19.5 / Erlang 28.3.1), then run
these commands from this repository:

```sh
mix deps.get
mix assets.setup
mix assets.build
bin/harnessforge demo
bin/harnessforge serve
```

Open [http://localhost:8865](http://localhost:8865). Open
`~/.local/share/harnessforge/default/access-token` in a local text editor and
paste the code into the login form. Keep that code private; it grants access to
the workspace. The portal never puts it in a URL.

Inspect the synthetic handbook, approve the two ordinary engineering claims,
reject the malicious instruction, then build and export a package to a fresh
directory. The demo creates deterministic proposals without inference. Its
hostile sentence is review data, not an instruction to the app or its operator.

For a separate workspace, set `HARNESSFORGE_WORKSPACE` to an absolute directory
before running any command. Stop the portal before using offline mutation
commands; each workspace permits one owning process. See the full
[quickstart](docs/quickstart.md) for source connections, local models and CLI use.

## What it does

- Guides company setup, a reusable repository/service catalogue, project scope,
  exact reviewed package plans and dependency-aware proposed milestones. Selected
  approved inputs generate reproducible native packages, with separate plan review
  and existing evaluation/release gates. See [company builder](docs/company-builder.md).
- Imports bounded local Markdown/text, GitHub repositories, GitHub Projects
  boards, Jira Cloud projects, Slack channels and Confluence Cloud spaces, with
  source revisions, provenance and SQLite FTS5 search. See [connector coverage
  and API setup](docs/integrations.md).
- Proposes claims through local Ollama or optional OpenAI Chat/Responses and
  Anthropic Messages APIs, with credential references, source-scoped consent
  and durable token/request/cost budgets.
- Combines 2–4 deliberately selected company sources with a saved future goal
  into one explained recommendation. Review original findings and uncertainty,
  edit guidance, resolve declared conflicts, then explicitly approve the exact
  revision and company plan before exporting. All examined revisions remain pinned.
- Provides a session-only chatbot with verified live account metadata for all five
  services, captured evidence search and optional cited AI answers. Live reads
  list repositories, boards, channels, projects or spaces without a model or
  content import. Cloud answers need explicit consent. See [chat setup](docs/chat.md).
- Requires an explicit decision for the exact immutable claim revision. Editing
  a claim makes its new revision require approval.
- Produces content-addressed native preview packages, provenance, a capability
  report and checksums. Unsupported enforcement is visible.
- Persists evaluation, release approval and channel history, with promotion
  guards tied to the exact qualified evaluation identity.
- Provides selective content purge, resumable cleanup, consistent local backup
  and restoration with old approvals and model consent removed.

Imported text and model output are untrusted. Olivium Harness does not run generated
or repository code on the host. Optional execution uses a pinned Docker runtime
with resource, filesystem and network restrictions; missing isolation or a model
produces an unavailable/blocked result. It never substitutes a paid provider.

## Documentation

- [Quickstart and configuration](docs/quickstart.md)
- [Company catalogue, plans and harness building](docs/company-builder.md)
- [Company builder verification and browser evidence](docs/company-builder-verification.md)
- [Use Olivium Harness's read-only MCP server](docs/mcp.md)
- [50-iteration enhancement program and evidence](docs/enhancement-program/PROGRAM.md)
- [Architecture and trust boundaries](docs/architecture.md)
- [Implemented behavior and qualification limits](docs/status.md)
- [Contracts and package format](docs/contracts.md)
- [Connector scope and credential references](lib/harness_forge/connectors/README.md)
- [Codex CLI integration](docs/codex-connector.md)
- [Claude Code integration](docs/claude-code-connector.md)
- [OpenAI and Anthropic API setup](docs/cloud-model-connectors.md)
- [Chat across connectors](docs/chat.md)
- [Chat verification evidence](docs/chat-verification.md)
- [Execution and evaluation](docs/execution.md)
- [Privacy, backup, restore and content purge](docs/privacy.md)
- [Build and release packaging](packaging/README.md)
- [Contributing and extension rules](CONTRIBUTING.md)

## Development

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix credo --strict --only warning
mix dialyzer
```

The ordinary suite uses synthetic fixtures and no paid credentials. Docker and
live-service checks are separate opt-in checks. Node.js is only required for the
optional browser QA tooling under `test/browser`; Elixir's asset wrappers build
the application assets, and compiled releases include those assets.

The current OTP 28 tuple reports two Ecto/MapSet opacity diagnostics in
Dialyzer. See the [verification record](docs/verification.md) for actual results
and limitations; a clean Dialyzer run is not claimed.

## License

Project code is offered under [Apache-2.0](LICENSE). Dependency licenses,
OpenCode, Docker, provider terms and model weights have separate terms; see
[third-party notices](THIRD_PARTY_NOTICES.md). This candidate does not bundle a
model, model weights or an OpenCode image.
