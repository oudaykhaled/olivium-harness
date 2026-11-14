# Live connector correction — 31 October 2026

The user's exact GitHub inventory question previously returned a captured-text
lookup. A regression reproduced the wrong behavior before implementation:
`mix test test/harness_forge/chat_test.exs --only line:98` failed once. Earlier
adapter and captured-chat checks did not establish usable live accounts.

The default assistant now routes supported inventory questions to fixed account
metadata operations. Connections verifies API access before saving an account;
the safe catalog reports last verification and credential availability. Captured
source status is labeled separately. Inventory replies never import source bodies,
invoke models or approve claims. Explicit local/model modes preserve their scope
and direct recognized inventory questions to Assistant.

## Automated evidence

- GitHub account client: 13 synthetic HTTP tests.
- Five-service account context: 20 tests, including identity, provider permission
  errors, limits, source-import rejection, withdrawal, purge and concurrent privacy
  admission fencing.
- Intent parser: three tests covering the exact question, all five operations,
  ordering/limits and ordinary evidence fallback.
- Native LiveView flow: four tests covering default routing, verified GitHub setup
  and ten results, explicit local-mode correction, and failed Projects verification.
- Independent reviewer: approved with zero open findings; 81 focused tests,
  formatter, warnings-as-errors compilation and Credo warning gate passed.

Canonical `mix test`: **326 tests, zero failures, 15 existing Docker-only skips**.
The original exact-question regression is now green: one test, zero failures,
18 excluded. Formatter, warnings-as-errors compilation and Credo warning gate
passed. Dialyzer still exits 2 with the same two Ecto/MapSet opacity diagnostics
in `releases.ex:47` and `releases.ex:121`; no new diagnostics were reported.

## Actual native browser evidence

The rebuilt native release runs on `127.0.0.1:8865`, observed PID 22815.
After a fresh workspace unlock, Chrome's Connections → Live accounts successfully
verified `GITHUB_PERSONAL_ACCESS_TOKEN` as `oudaykhaled` through the running app.
Only the environment reference was entered; its value was never copied into the
form. The verification timestamp was `2026-10-31T22:47:00.506791Z`.

Chat defaulted to **Live connector assistant**. Submitting the exact question
“List for me the top 10 repositories on my github” produced **LIVE CONNECTOR
RESULT**, ten repository links, descending update timestamps, account identity,
fetch time `2026-10-31T22:47:12.514579Z`, and “No model call”. The reply explicitly
states token-visible owned scope and one-page partial coverage. This establishes
the native UI → Chat → Accounts → actual GitHub API path at that time.

Actual Projects verification using that existing reference returned safe API
access denial. The page retained one configured GitHub account and four setup
required states. Read-only database counts afterward were 32 source snapshots,
32 revisions and three claims, unchanged from before these checks. Exactly one
active `service_account` row exists, for GitHub. No Projects account was saved.

Native package build and packaged CLI smoke passed. The smoke uses its own
disposable synthetic workspace and makes no provider/model call. Final archive
identity and module inventory are in the companion verification report under
`tmp/packages/`.

Ignored local evidence (screenshots include user-visible repository metadata):

- `tmp/live-chat-red.log`, `tmp/live-chat-green.log`
- `tmp/live-chat-full-tests.log`, `tmp/live-chat-final-lint.log`, `tmp/live-chat-dialyzer.log`
- `tmp/live-chat-package-build.log`, `tmp/live-chat-package-smoke.log`
- `tmp/live-chat-native-server.log`
- `tmp/live-chat-browser-2026-10-31.png`, `tmp/live-accounts-browser-2026-10-31.png`

## Current access limits

Existing environment references authenticate GitHub as `oudaykhaled`. Real read-only
`/user` and `/user/repos` returned ten owned repositories in updated-descending order,
with another page available. Both available references failed GitHub Projects
GraphQL queries with `INSUFFICIENT_SCOPES`; ordinary repository scopes lack
`read:project`. No scopes were expanded. Slack has no app API credential configured.
The available Atlassian Rovo connection reports `UNAUTHORIZED`, and browser sign-in
does not provision Jira/Confluence API-token credentials for this standalone app.

The operator must provide a Projects read credential, a Slack read credential, and
a reachable Atlassian tenant with API-token/email environment references to verify
the remaining four accounts. No paid inference, private-source body import,
remote content mutation, public release or managed coding-agent execution occurred.
