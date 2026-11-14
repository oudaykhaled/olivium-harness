# Connector chatbot verification — 31 October 2026

This records the earlier captured-evidence chatbot checks. It did **not** establish
live account access. The subsequent user-reported routing and connection gaps are
addressed separately in [live chat correction evidence](live-chat-verification.md).

The authenticated portal now has a Chat screen and CLI equivalents. Read access
covers current captured evidence from local files, GitHub repositories, GitHub
Projects, Jira, Slack and Confluence. Optional AI answers use Ollama, OpenAI Chat,
OpenAI Responses or Anthropic Messages through the existing model gateway.

## Observed checks

| Check | Result | Practical limit |
| --- | --- | --- |
| Canonical `mix test` | 285 tests, zero failures, 15 existing Docker-only skips | Controlled fixtures establish application behavior |
| New model checks | 14 tests | All four provider profiles, consent, accounting and retry fences |
| New backend checks | 18 tests | All six imports, exact UTF-8 citations, stale/withdrawn scope, malicious text, bounded retrieval and shared budget |
| New UI checks | 8 tests | Authentication, local search, escaped content, explicit consent/sync, AI fixture response, pending-response cancellation and log filtering |
| Format/compiler/Credo warning gate | passed | No full strict-refactoring cleanup claimed |
| Dialyzer | two existing release opacity diagnostics; no new chat diagnostics | Exit 2 remains explicit |
| Independent review | approved, no open findings | Two concerns fixed: log redaction and repeated validation reads |
| Native browser | login, local submission/citations, clear, missing-model state and connector inventory passed | No live model inference attempted |

The batched validation regression measures **six SQL queries for ten replies
sharing one source**, and nine for two sources. It preserves all reply-digest,
workspace, privacy, active-connection, revision, full-context, configuration and
exact-snippet checks. The existing native test exporter is explicitly excluded
from ordinary ExUnit discovery; its separate Docker probe remains available.

## Authority and privacy checks

Local evidence lookup makes no model request. Cloud chat requires exact source
consent plus the separate `chat_context` category for the current question, up to
four recent user questions and source labels. Existing proposal consent remains
unchanged until the operator explicitly selects the new checkbox. No provider
can supply a schema, system prompt or executable tool through chat.

Answers contain only validated references to retrieved excerpts. Invalid JSON,
duplicate keys/IDs, fabricated references and extra authority fields fail.
Citation validity does not prove factual entailment. Imported and model text is
escaped in the UI and never creates claims, decisions, releases or remote writes.

The transcript is bounded to ten turns in the LiveView process. It is absent from
database tables, backups, Oban arguments and audit bodies. Phoenix parameter logs
redact both `chat` and `question`. Refresh/session expiration clears the session;
source/configuration withdrawal invalidates affected replies, and cancelled or
stale async completion cannot repopulate a cleared conversation. The model ledger
retains only existing safe identifiers, fingerprints and accounting state.

## Native and packaging evidence

The native app runs on loopback at `http://localhost:8865`. Actual Chrome showed
all six source connector types, source counts, incomplete/revoked connection
states, all four supported model providers, and coding-target status. Local
questions retrieved real previously imported public GitHub and synthetic handbook
snapshots. Source excerpts were not sent to a model. The demonstration workspace
still has no model selected and no cloud chat consent; AI mode correctly refuses
inference. No connector was automatically synchronized or mutated.

Packaged smoke covers `chat-connectors` and local `chat` along with previous
source/model/target commands, in a disposable synthetic workspace. Model fixture
tests exercise real metered dispatch through synthetic HTTP responses, including
a cited UI answer and a cancelled follow-up. They do not establish live API access.

Ignored local logs:

- `tmp/chat-final-test.log`, `tmp/chat-final-lint.log`, `tmp/chat-dialyzer.log`
- `tmp/chat-ui-tests.log`, `tmp/chat-package-build.log`, `tmp/chat-package-smoke.log`
- `tmp/chat-native-server.log`
- `tmp/chat-browser-2026-10-31.jpg`

The latest archive checksum, size, module inventory and native server owner are
in the companion verification record next to the archive under `tmp/packages/`.
No paid API request, private-source import, remote mutation, publication or
Codex/Claude managed execution was performed. Live model/account qualification
requires separately configured operator credentials, model and consent.
