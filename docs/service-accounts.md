# Live service accounts

HarnessForge distinguishes live account metadata from captured source evidence.
Signing into a provider in a browser does not authenticate HarnessForge's API client.
The local operator selects an environment variable reference and verifies the account
in Connections. Stored configuration contains references, the selected provider/site,
the verified identity, and the last verification time. Tokens and email credentials
are resolved at request time and are never stored in account rows or audit events.

| Service | Verification | Live operation | Scope and order |
| --- | --- | --- | --- |
| GitHub | `GET /user` | `github.repositories` | Token-visible repositories owned by the authenticated user, updated descending |
| GitHub Projects | GraphQL `viewer.projectsV2(first: 1)` | `github_projects.boards` | Viewer-owned Projects v2 metadata, updated descending |
| Slack | `auth.test` and one channel page | `slack.channels` | Token-visible public/private channel metadata, provider order; no DMs |
| Jira Cloud | `GET /rest/api/3/myself` and one project page | `jira.projects` | Token-visible project metadata, project key ascending |
| Confluence Cloud | `GET /wiki/rest/api/user/current` and one space page | `confluence.spaces` | Token-visible space metadata, ID ascending |

`Accounts.connect/2` accepts a string-keyed map with `service` and `credential_ref`.
Jira and Confluence additionally require an operator-selected `https://<site>.atlassian.net`
origin and `username_ref` containing the API-token account email. GitHub.com and Slack
origins are fixed. Extra configuration fields, raw token values, arbitrary URLs and
client-supplied transports are rejected. Only successful verification creates an account.
GitHub Projects needs Projects read permission independently of ordinary GitHub access.
Slack channel listing needs `channels:read` and `groups:read` for both channel types;
the credential can see fewer channels than the browser user.

```elixir
HarnessForge.Accounts.connect(%{
  "service" => "github",
  "credential_ref" => "GITHUB_PERSONAL_ACCESS_TOKEN"
})

HarnessForge.Accounts.query("github.repositories", %{"limit" => 10})
```

All operations are compiled and read-only. Queries accept only an integer `limit`
between 1 and 20, request one page, and expose returned count, continuation availability,
token visibility, and ordering. “Top 10 repositories” means the ten most recently updated
owned repositories; it does not claim a star ranking. Metadata responses omit descriptions,
issue/page/message bodies, clone credentials, private profile fields, and arbitrary URLs.
Queries do not import evidence, create claims, invoke models, or execute coding agents.

The safe catalog makes no network request. `configured` means that an active account was
previously verified and referenced credentials are currently present, with a displayed
`last_verified_at`; it does not claim current remote authorization. API requests have fixed
destinations, no redirects or retries, a 5-second connect timeout, a 15-second response
timeout, and the existing 4 MiB response bound. HTTP and HTTP-200 provider permission errors
are mapped to safe error codes without response bodies. Rate limits require a later explicit
retry; no background poller is started.

In-memory live replies bind their payload to the workspace, operator session epoch, account
connection ID, and exact account configuration. `Accounts.valid?/1` rechecks privacy state,
active authority, configuration, and credential availability without another API call.
Disconnect, purge, restore quarantine, workspace/session changes, or modified responses
invalidate prior replies. Each query re-verifies the account identity, preventing an
environment token change from silently switching the connected owner.

Account verification and admission hold the existing workspace privacy lock. A concurrent
purge runs afterward and removes newly admitted authority. The optional trusted `:authorize`
callback and the captured operator-session epoch are checked before requests and again before
persistence/return; browser events cannot supply callbacks or transports.

The `service_account` connector wrapper cannot synchronize or import source documents.
Selected source connectors remain the explicit path for importing a repository, channel,
project, or space. Existing generic workspace purge and restore quarantine include these
account records without a schema change.

Decision: extend `Evidence.Connection` for account lifecycle and reuse `Connectors.Common`
for fixed metadata requests. This preserves the existing audit/privacy behavior while
separating live metadata authority from selected content imports. A separate account table
would require duplicating lifecycle/migration logic; reusing source imports would incorrectly
treat browser login or repository selection as account-wide authorization.

Official API references checked 2026-10-31:
[GitHub users and Projects v2](https://docs.github.com/en/graphql/reference/users),
[GitHub Projects](https://docs.github.com/en/graphql/reference/projects),
[Slack auth.test](https://docs.slack.dev/reference/methods/auth.test/),
[Slack conversations.list](https://docs.slack.dev/reference/methods/conversations.list/),
[Jira current user](https://developer.atlassian.com/cloud/jira/platform/rest/v3/api-group-myself/),
[Jira projects](https://developer.atlassian.com/cloud/jira/platform/rest/v3/api-group-projects/),
[Confluence current user](https://developer.atlassian.com/cloud/confluence/rest/v1/api-group-users/),
[Confluence spaces](https://developer.atlassian.com/cloud/confluence/rest/v2/api-group-space/).

Verification: `mix test test/harness_forge/accounts_test.exs` exercises synthetic HTTP
fixtures for all five providers, safe errors, bounds, owner/team restrictions, revocation,
quarantine semantics, workspace purge, concurrent privacy serialization, and session
authorization withdrawal. Fixture coverage does not establish live Slack/Atlassian access.
