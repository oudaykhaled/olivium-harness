# Quickstart

This guide runs the local source checkout. It does not publish a server, import
private accounts, install a model or make a paid inference call.

## Chat with connected evidence

Open **Chat** in the portal after importing a source. Choose **Local evidence
search** and ask a question such as “What tests are required?” to inspect exact
supporting excerpts without a model call. The connector sidebar shows all source
types, their captured scope and explicit Sync next page actions.

For AI answers, configure a supported provider/model in Connections. Cloud models
also require selected-source consent and the separate chat-context checkbox.
Then choose **Configured AI model** when sending a message. The conversation is
kept only in the current LiveView session, and source changes invalidate its
answers. CLI equivalents are `bin/harnessforge chat-connectors` and
`bin/harnessforge chat 'What tests are required?' [evidence|model]`.
See [the chat guide](chat.md) for limits and consent details.

## Requirements

- Elixir 1.19.5 and Erlang/OTP 28.3.1, pinned in `.tool-versions`. The observed
  development target is macOS arm64. Linux CI is configured separately; that is
  not evidence of a completed Linux run.
- Git, Hex and Rebar for the locked dependencies. A C compiler/build tools may
  be needed if Exqlite cannot use its compatible precompiled NIF.
- A modern browser. Node.js is unnecessary for the esbuild/Tailwind wrappers or
  assembled release. It is only used by optional browser QA.
- Optional: a running local Ollama service with an already installed local
  model. Runtime checks also require Docker with Linux containers and the
  explicitly installed pinned OpenCode image.

Install `.tool-versions` with your existing asdf/mise, or matching Elixir/Erlang
through your package manager. From this repository:

```sh
mix local.hex --force
mix local.rebar --force
mix deps.get
mix assets.setup
mix assets.build
```

## Start a private local workspace

The default directory is `~/.local/share/harnessforge/default`. To keep the demo
separate, choose an absolute path before all commands:

```sh
export HARNESSFORGE_WORKSPACE="$PWD/tmp/my-demo-workspace"
bin/harnessforge init
bin/harnessforge demo
bin/harnessforge serve
```

Visit [http://localhost:8865](http://localhost:8865). Open the workspace's
`access-token` file in a local text editor and paste the code into the form. The
directory is private to the local account; a filesystem lock prevents two
processes from owning it. Logs and URLs should never contain the access code.

`PORT=8866 bin/harnessforge serve` selects another loopback port. The endpoint
binds `127.0.0.1`; public sharing is outside the supported local profile. Stop
with Ctrl-C, then quit the Erlang break menu if one appears.

## Review, build and export

1. Inspect Evidence and its citations. The demo has two engineering practices and
   one malicious instruction. Approve/reject each claim explicitly.
2. Add or inspect a goal with an owner and acceptance criteria.
3. Build a named package/version. Inspect the preview, provenance and capability
   report. Runtime qualification remains unverified.
4. Export to a fresh absolute directory. Existing paths and unsafe paths fail
   instead of overwriting files.

Export does not certify coding quality or approve a release. Human approval of
a claim does not make its text an enforced sandbox control.

The offline CLI emits JSON; stop the portal before running it. Use IDs/hashes
from your workspace, not example identifiers:

```text
bin/harnessforge help
bin/harnessforge status
bin/harnessforge sources
bin/harnessforge claims
bin/harnessforge goals
bin/harnessforge sync CONNECTION_ID
bin/harnessforge decide CLAIM_ID approve REVISION_HASH
bin/harnessforge build my-harness 0.1.0
bin/harnessforge export DIGEST /absolute/path/to/a-fresh-directory
```

`help` lists exact connection, model, privacy, evaluation and release syntax.
Failures exit nonzero with a safe code. The global status field
`runtime_qualified: false` is not a per-evaluation result or blanket certification.

## Connect selected sources

For the complete company workflow, open **Company** after capturing sources.
Register repositories/services, group them into projects, choose reviewed claim
revisions and goals, then save and explicitly review a versioned package plan.
The [company builder guide](company-builder.md) follows the full local journey.

Enter an absolute directory path in Connections, then import explicitly. Review
files for secrets first: supported text is captured as written, including text
you may reject. Originals remain under your control. The importer bounds files
and content, and rejects unsafe symlinks.

GitHub.com selects one `owner/repository`; public reads can work without a token.
Jira Cloud selects one tenant/project. These adapters read supported source kinds
only. Fixture coverage is not live support evidence. See
[connector limits](../lib/harness_forge/connectors/README.md).

Set credentials in the process environment before starting the portal. In forms
and CLI config, enter only their **environment variable names**:

| Reference example | Purpose |
| --- | --- |
| `HARNESSFORGE_GITHUB_TOKEN` | Optional GitHub read token |
| `HARNESSFORGE_JIRA_TOKEN` | Jira token |
| `HARNESSFORGE_JIRA_EMAIL` | Jira account identity |

Never paste credential values into source documents, URLs, issue reports or
command arguments. Observed access revocation blocks retrieval and dependent
eligibility; it is not continuous remote ACL monitoring.

## Configure a local model

Install/run Ollama and obtain a model separately under its own license. In
Connections, save `http://127.0.0.1:11434` and the exact already installed local
model name. Saving config does not pull a model or start inference. Choose
"Propose with configured model" on a selected source when ready.

Unavailable local inference stays unavailable. Remote/cloud Ollama models are
denied by the adapter. The loopback model service is trusted; HarnessForge cannot
attest its implementation or model provenance.

The optional OpenAI adapter is configured through the Elixir Models context. It
requires a selected model/provider, a `HARNESSFORGE_*` credential reference,
rates/budgets and consent listing the selected source IDs and data categories.
The standard portal form configures local Ollama. No automatic cloud fallback or
paid verification occurs. Consent/accounting do not guarantee an external
provider's retention behavior.

## Workspace files and recovery

| File/directory | Contents |
| --- | --- |
| `data.sqlite3` and journals | Evidence, FTS, decisions, jobs and ledgers |
| `.ownership.sqlite3` | Cross-process ownership lock |
| `workspace.json` | Workspace identity |
| `access-token`, `session-secret` | Local login/session secrets |
| `artifacts/` | Immutable compiled packages |
| `runs/`, `tmp/` | Bounded runtime/operation working data |

Do not commit workspaces or copy live SQLite files as a backup. Use
[consistent backup/restore](privacy.md); backups contain private evidence and
are unencrypted. Content purge retains identity/login files. Complete root
removal is offline after shutdown. Neither operation promises physical erasure.

Startup acquires ownership and completes database/recovery preparation before
jobs and the endpoint. Unresolved cleanup blocks readiness; restore required
Docker/filesystem access and retry. Do not remove recovery records to bypass it.

## Additional service connections

The Connections form and CLI support GitHub Projects boards, Slack channels and
Confluence spaces alongside GitHub repositories and Jira projects. See
[integrations.md](integrations.md) for exact configuration, environment references,
permissions, supported content and live-verification limits.

For live account inventories, use Connections → Live accounts instead.
Select the service and environment variable reference, then verify the account.
Jira/Confluence also require a reachable Atlassian site and email reference.
Chat defaults to Live connector assistant: try “List for me the top 10
repositories on my github”. It lists most recently updated owned repositories,
up to one bounded page, without importing their content or calling a model.
Projects needs its own read permission; GitHub repository access alone is not
enough. See [live account setup](service-accounts.md) and [chat modes](chat.md).

## Codex, Claude Code and model APIs

In Package, choose OpenCode, Codex CLI or Claude Code before building. Export into
a new directory. CLI equivalents:

```sh
bin/harnessforge runtimes
bin/harnessforge build my-harness 0.1.0 codex 0.156.0
bin/harnessforge build my-harness 0.1.0 claude_code 2.1.311
bin/harnessforge export DIGEST FRESH_DIRECTORY
bin/harnessforge model status
bin/harnessforge model configure /absolute/path/to/model-settings.json
```

Connections → Model API connections configures OpenAI Responses/Codex models,
Anthropic/Claude models, legacy OpenAI Chat or local Ollama. Cloud setup requires
an environment-variable reference (not a key value), conservative price estimates
and explicit consent for checked sources. Saving settings sends no inference.
Choose Propose on a permitted source to request a bounded proposed extraction.
See [cloud-model-connectors.md](cloud-model-connectors.md) for exact JSON config,
source categories and accounting. No cloud provider is enabled by default.

Codex/Claude native exports are available independently of managed coding
execution. Their managed evaluations remain visibly unavailable until a qualified
backend/model path exists. Static integrity never authorizes release promotion.
