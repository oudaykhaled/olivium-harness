# Connector chat

Chat reads verified live account metadata for GitHub, GitHub Projects, Jira, Slack
and Confluence, plus captured evidence from those providers and local files.
It reports the registered
OpenCode, Codex CLI and Claude Code export targets separately from the configured
Ollama, OpenAI Chat, OpenAI Responses or Anthropic Messages model connection.
These capabilities do not imply managed coding-agent execution or live remote ACL
verification.

The Chat page and `harnessforge chat QUESTION [assistant|evidence|model]` use the
same `HarnessForge.Chat` context. **Live connector assistant is the default.**
`harnessforge chat-connectors` returns a safe inventory without network requests.
Connections → Live accounts verifies an environment-referenced credential
before saving an account. Browser sign-in alone does not provision API access.
Captured text still requires an explicit selected-source import/sync.

## Modes and limits

- **Assistant:** routes supported inventory questions to fixed, read-only account
  operations. For example, “List for me the top 10 repositories on my github”
  fetches ten token-visible owned repositories ordered by most recently updated;
  “top” does not mean most stars. Other supported inventories are GitHub Projects
  boards, Slack channels, Jira projects and Confluence spaces. Limits are 1–20,
  one API page, with partial coverage and order displayed. Ordinary evidence
  questions use local lookup. No model is called in this mode. Missing credentials
  or permissions return an actionable error and never a fabricated result.
- **Evidence:** literal, case-insensitive keyword lookup with bounded OR alternatives
  for simple plurals and English `-ing`/`-ed` endings. It returns matching captured
  excerpts and explicitly labels the result as a local lookup. It performs no
  inference and does not invent a synthesized answer.
- **Model:** sends the question, up to four previous user questions, and matching
  excerpts through the existing metered `Models.infer/2` boundary. All four model
  providers use the same server-owned chat profile. A model must be explicitly
  configured; there is no provider fallback or model installation.

A recognized live inventory request in Evidence or Model mode asks you to switch
to Assistant, preserving the question. Live account metadata is ephemeral: it is
not imported, stored as source evidence, or supplied to the model. Disconnecting
an account, credential removal, purge or session/configuration changes invalidate
its displayed replies. Each new query rechecks the authenticated identity and
current API access. Setup details: [live service accounts](service-accounts.md).

Questions are valid UTF-8, nonempty and at most 4,000 bytes. Previous context contains
only user-question strings, each subject to the same bound. Assistant messages,
credentials, connector settings, directories and opaque sync cursors are excluded.
The complete serialized model context is at most 24 KiB. Questions/history that
leave insufficient room for evidence return `chat_context_too_large`. At most 12
excerpts of 1,536 UTF-8 bytes each are selected, from current revisions on active
connections. Search uses at most 16 literal token alternatives, with the existing
FTS API returning at most 50 candidates per alternative. Broad overview questions
use the captured source list. This is lexical retrieval, with no vector index or
semantic completeness guarantee.

Every ephemeral citation carries its `E#` identifier, source and connection IDs,
provider, title (bounded to 512 UTF-8 bytes), immutable revision ID, body hash,
exclusive byte offsets, exact snippet and capture time. Links are restricted to
HTTPS without user information or query strings, except Confluence's canonical
numeric `pageId` query. Exact source bodies remain in the evidence store; chat
does not create persisted citation, claim or approval records.

No matching evidence produces a deterministic local explanation and no model
request. Incomplete syncs remain visible in the connector inventory. Search does
not automatically sync providers, check their present permissions, or establish
that captured text is factually correct.

## Cloud consent and cost

Cloud mode requires explicit provider/endpoint consent for both `source_body` and
`chat_context`, covering the selected source IDs. `chat_context` includes the user's
question, recent user questions and source labels. Retrieval reads only explicitly
consented IDs when using a cloud provider; bodies outside that selection are never
included in the prompt. Missing chat consent fails before any dispatch. Clearing
or changing model settings invalidates prior model replies in the UI.

The UI retains one run ID across turns, with a fresh request ID for each call.
The existing immutable default budget is 10 requests, 100,000 reserved tokens and
USD 1 in operator-declared estimated cost for the run. Unknown outcomes retain
their reservation. Reusing a dispatched request ID cannot dispatch another call.
Chat uses a 2,048-token output limit and the existing bounded, timeout-protected,
nonredirecting HTTP adapters. Saving a connection or entering the Chat page does
not run paid inference.

Model responses must contain exactly `answer` and `citation_ids`. Answers are
nonblank UTF-8 strings of at most 8,000 characters; citations contain 1–12 distinct
supplied IDs. Duplicate JSON keys, invented IDs (including explicit `E#` references
in the answer), extra fields and other malformed output are rejected after metering.
Schema compliance and valid citations establish provenance, not factual entailment;
review the displayed source excerpt before relying on a generated assertion.

## ADR: ephemeral chat over existing evidence and inference boundaries

**Context.** The project already has workspace-scoped captured revisions, explicit
source revocation/privacy workflows, finite runtime adapters and metered model
providers. A separate autonomous connector agent would duplicate those controls
and introduce new tool authority.

**Decision.** Extend those existing contexts with a read-only Chat context. Keep
conversation state in the connected LiveView, with no new chat database tables,
Oban jobs or public HTTP inference endpoint. Preserve imported instructions as
untrusted text. The model profile cannot call tools, execute code, synchronize a
source, approve claims or change permissions. An exact context snapshot is checked
before dispatch and after completion; it includes every selected source, even if
the final answer cites only a subset. `Chat.valid?/1` rechecks workspace identity,
privacy readiness, active connections, current revisions, exact citation bytes and
the model configuration fingerprint before redisplay.

**Consequences.** No persisted transcript needs an additional purge policy. UI
refresh/session revocation clears conversation state; source updates, revocation,
purge or model configuration changes invalidate affected replies. Existing model
request ledgers persist only safe accounting/fingerprints, with no prompt or answer
body. Local lookup remains usable without a model service. The trade-offs are
lexical retrieval, no transcript continuity after refresh and no remote mutation.

**Live metadata extension.** A finite deterministic intent parser now selects
compiled account operations. It accepts no model-generated URL, request body or
tool name. Metadata authority remains separate from captured evidence and model
consent. No autonomous remote write or source synchronization is introduced.

**Alternatives considered.** A model with arbitrary connector tools requires a
separate authorization, tool and audit design. A vector/RAG service would improve semantic matching but adds an
index lifecycle, deletion synchronization and another privacy boundary. Both are
outside this bounded implementation.

## Verification

`mix test test/harness_forge/chat_test.exs` exercises all six synthetic source
providers through the real import APIs; natural testing-rule lookup against the
built-in demo; exact Unicode spans; bounded contexts; credential-free inventory;
malicious imported text; revision/revocation/purge/workspace invalidation; model
consent filtering; metered HTTP fixture inference and shared run budgets; malformed
responses and late stale completions. Provider fixtures establish deterministic
protocol behavior, not live account access or production model compatibility.
No paid inference or private connector import is required for these checks.
