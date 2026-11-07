# Implementation and qualification status

Status date: 1 November 2026. Version 0.1.0 is a local development candidate.
This checkout does not represent a published public release, hosted service or
completed private pilot.

Official enhancement progress is **5/50**. The
[accepted iteration05](enhancement-program/iterations/05/verification.md) adds
explicit goal-origin claims through separate exact claim and company-plan decisions.
Independent review, native Chrome acceptance, local installation and five independent
retrospectives are complete. Candidate01 has493 distinct executed passing tests;
the CSS-only candidate02 reuses scoped backend evidence and has fresh native checks.
Two unsuppressed baseline Dialyzer findings remain. Complete-company reliability,
real-model qualification and independent operator comprehension remain unproven.
The [iteration06 UI/UX candidate](enhancement-program/iterations/06/decision.md) adds package-owned export feedback, safe destination remedies and reset-bound form controls. Author checks pass; independent review and native acceptance remain pending. The official count remains five.
Existing observations below retain their historical scope.

| Area | Implemented | Evidence / practical limit |
| --- | --- | --- |
| Workspace/portal | Loopback login, one owner, SQLite, LiveView | Local checks; no public/multiuser hosting profile |
| Company builder | Company profile, repository/service catalogue, project scope, immutable reviewed plans and proposed milestone DAG; accepted iteration05 goal-based rules | Exact selected claim/source/goal snapshots; native target exports; local plan bindings; 05 independent/native checks passed within their recorded scope; portable authenticated authority remains unproven |
| Evidence | Text import, revisions, citations, search, claims; accepted iteration05 versioned goal-origin basis | Synthetic fixtures; content captured as written, not automatically redacted; goal selection alone grants no authority |
| Decisions/compiler | Exact revision approval, lineage, deterministic OpenCode/Codex/Claude previews and export | Byte/tamper/path checks; previews do not qualify a coding runtime |
| GitHub/Jira/Projects/Slack/Confluence | Selected read-only, resumable bounded adapters with portal/CLI | All five fixture-tested; authenticated live checks still need API credentials and selected scopes |
| Models | Ollama, OpenAI Chat/Responses and Anthropic Messages with source-scoped consent and ledger | API fixtures; no live paid/model availability assumed |
| Chat | Live metadata for five verified account types; all six captured source types; local cited search and optional model answers | Session-only, finite read-only operations; live credentials required; explicit model consent; no coding-agent launch |
| Runtime | Pinned OpenCode 1.19.5 confinement/lifecycle | Real local offline version/config/containment checks; no blanket portability claim |
| Coding tasks | Isolated execution/model relay and protected grading integration | Real qualification needs an available selected model; blocked runs cannot pass |
| Releases | Evaluation/approval/channel/history guards | Diagnostics cannot authorize promotion; no qualified release asserted |
| Privacy | Logical purge, recovery, consistent backup/restore | Synthetic lifecycle checks; backups are unencrypted |
| Packaging | Native release, inventory, Linux CI candidate | macOS arm64 build and CLI package smoke passed; Linux hosted CI has not run |

Fixture tests do not prove live support, model quality or productivity benefit.
A container smoke does not prove consumption of every generated native file or
successful model-backed coding. Neither two tasks nor human approval establishes
prompt-injection immunity.

The iteration05 journey is saved goal → user-authored **Goal-based rule** → exact
claim approval → explicit selection of the same goal and claim in an in-scope
Company plan → separate exact plan approval → build/export. Zero source documents
is valid for that goal-only path. The existing v1alpha1 rule carries `goal_id` and
empty `evidence`. Generic workspace-wide build refuses approved goal-origin claims;
it cannot silently omit them or grant plan approval. Typed lineage preserves origin
across successors, while the versioned hash binds rule text and the pinned goal.
Source purge retains independent goal families; affected dependencies still
invalidate. Workspace purge includes them, and restore clears decisions under
quarantine. Historical artifact bytes remain historical records, not current or
portable approval authority. Runtime/task qualification and company fitness remain
separate from this representability change.

## Remaining qualification work

1. Install/select a local model under its license and run protected
   baseline/candidate task evaluations. Preserve failed/blocked/interrupted
   outcomes, usage and cleanup records.
2. Run authorized authenticated live checks for all five services using selected
   scopes and environment API credential references. Restore Atlassian tenant
   availability first. Enterprise/Data Center variants and complete
   deletion/ACL synchronization are outside the implemented connector scope.
3. Run packaging on a clean Linux target and verify each advertised platform
   archive. Windows/cross-platform archive reuse are unsupported.
4. Before publication, assign repository/maintainer/private disclosure ownership,
   review distribution terms, and choose signing/provenance/retention policies.
   This local build performs no publishing or announcements.

Whole-root removal is offline after shutdown. Logical purge retains minimal
operation tombstones, identity/login files. Physical erasure of SQLite free
pages, SSD blocks, snapshots, backups, exports and provider copies is unproven.

See [compatibility](compatibility.md), [execution](execution.md) and
[packaging](../packaging/README.md) for commands and exact evidence limits.
The initial [packaging check record](../packaging/VERIFICATION.md) records the
native archive checks separately from application/task qualification.

## Five service adapters

GitHub repositories, GitHub Projects v2, Jira Cloud, Slack channels and Confluence
Cloud have real read-only adapters and portal/CLI configuration. Their ingestion,
provenance and failure behavior are tested with synthetic HTTP fixtures. See
[integrations.md](integrations.md) for coverage and authenticated live blockers.

## Codex and Claude integration

Native exports now support Codex CLI 0.156.0 and Claude Code 2.1.311 alongside
OpenCode. Provider setup supports OpenAI Responses (including compatible Codex
model IDs) and Anthropic Messages (Claude models). API adapters reuse exact-source
consent, credential references and durable budgets; generated claims stay proposed.

Native preview is distinct from managed coding. Codex/Claude artifacts pass
static integrity but task and managed runtime-smoke evaluations persist blocked
with their own unavailable target identities. They cannot inherit the OpenCode
backend's result or qualify release promotion. See the per-target and API docs
for native parser observations and authenticated-live limits.

The [connector chatbot](chat.md) defaults to a live connector assistant. Finite
inventory questions use separately verified [service accounts](service-accounts.md);
ordinary evidence questions use current captured snapshots. Optional model answers
use the existing shared ledger and explicit chat consent. No mode silently imports
content or refreshes an incomplete evidence scan. Live GitHub metadata has passed
the actual native browser flow; the other four accounts remain unverified due to credentials or
permissions. See the [current correction evidence](live-chat-verification.md).
