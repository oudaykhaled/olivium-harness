# Read-only integrations

All five services have compiled Elixir adapters, selected-scope configuration in
the portal and CLI, durable resumable cursors, exact citations, evidence revisions
and synthetic HTTP integration tests. Imported content creates no approvals.
Browser sign-in and application API authentication are separate.

| Provider / config name | Selection | Captured content | Limitations |
|---|---|---|---|
| GitHub / `github` | `owner/repository` | Repository metadata, issues and PR descriptions, PR reviews | No repository files, issue comments or independent review change feed |
| GitHub Projects / `github_projects` | Canonical organization/user project URL | Project metadata, fields/options, views, items and field values | No classic Projects; inaccessible linked content stays redacted; no linked-repository crawl |
| Jira Cloud / `jira` | Tenant origin + project key | Issues, ADF description text, actual changelog transitions | No Data Center, attachments or full rich-media rendering |
| Slack / `slack` | Workspace ID + joined channel ID | Channel messages and threaded replies, edited timestamps | No DMs, files, reactions, auto-joining or retention recovery |
| Confluence Cloud / `confluence` | Tenant origin + numeric space ID | Current page text, version/author provenance | No macros, attachments, comments, blogs, historical versions or gateway-scoped tokens |

No adapter infers deletion from an absent item or provides continuous ACL
attestation. An explicit access-denied response revokes the connection and makes
its existing sources/citations unavailable. A successful traversal covers only
the supported endpoint kinds. Partial/error responses never advance a cursor.

## API credentials

Open Connections and select a provider; the form shows its relevant fields.
Credential inputs take environment variable **names**, never token values.
Set values privately in the server's launch environment before startup, then
enter the corresponding names. Do not paste secrets into chat or source files.
Only references are stored in the workspace. Tokens are resolved for each fetch
and excluded from source records, jobs, audits, provider errors and backups.

| Provider | Reference example | Required API access |
|---|---|---|
| GitHub | `HARNESSFORGE_GITHUB_TOKEN` (optional public reads) | Selected repository read access; classic `repo` for private content, or appropriate fine-grained permissions |
| Projects | `HARNESSFORGE_PROJECTS_TOKEN` | Projects read permission; classic `read:project`; linked repository permissions affect item visibility |
| Jira | `HARNESSFORGE_JIRA_EMAIL`, `HARNESSFORGE_JIRA_TOKEN` | Tenant email/API token that can browse the selected project and issue changelogs |
| Slack | `HARNESSFORGE_SLACK_TOKEN` | User token: `team:read`, `channels:read` + `channels:history` for public channels, `groups:read` + `groups:history` for private channels; membership/access to selected channel |
| Confluence | `HARNESSFORGE_CONFLUENCE_EMAIL`, `HARNESSFORGE_CONFLUENCE_TOKEN` | Direct-tenant email/API token able to read the selected space/pages; scoped tokens requiring `api.atlassian.com` gateway unsupported |

Slack bot tokens cannot read public/private threaded replies with the supported
`conversations.replies` endpoint; use an authorized user token for this coverage.
Slack methods have independent quotas. This adapter requests at most 15 messages
per content page and makes no automatic retries. Every content page also checks
`team.info` and `conversations.info`, so a replaced token cannot cross workspace
or channel boundaries. Full rescans capture edits and new replies on old parents;
limited/partial history returns an explicit failure rather than complete.

IDs are available in canonical provider URLs. A Slack channel URL contains
`/client/TWORKSPACE/CCHANNEL`. A Confluence space ID is numeric, distinct from
the space name/key. Atlassian endpoints must be bare origins such as
`https://your-site.atlassian.net`, without `/wiki`, trailing slash or query.

## CLI examples

Stop the portal before offline commands; the workspace permits a single owner.
Examples contain only reference names and synthetic selections:

```sh
bin/harnessforge connect github 'Repository' owner/repository HARNESSFORGE_GITHUB_TOKEN
bin/harnessforge connect github_projects 'Board' https://github.com/orgs/owner/projects/1 HARNESSFORGE_PROJECTS_TOKEN
bin/harnessforge connect jira 'Issues' https://your-site.atlassian.net DEMO HARNESSFORGE_JIRA_EMAIL HARNESSFORGE_JIRA_TOKEN
bin/harnessforge connect slack 'Channel' T0123456789 C0123456789 HARNESSFORGE_SLACK_TOKEN
bin/harnessforge connect confluence 'Pages' https://your-site.atlassian.net 12345 HARNESSFORGE_CONFLUENCE_EMAIL HARNESSFORGE_CONFLUENCE_TOKEN
bin/harnessforge sync CONNECTION_ID
```

Each explicit sync commits one bounded top-level page. Click Sync next page or
repeat the command while `complete` is false. Projects additionally drains nested
connections within a bounded 32-request budget before committing that page;
exhausting the budget is an error, never silent truncation. Slack threads resume
separately from history. Confluence begins with a space verification page that
imports zero documents. Failed pages preserve the last committed cursor.

Rate limits preserve the cursor and return `rate_limited`; numeric Retry-After
is bounded to one day. Retry explicitly after the provider delay. Missing env
values return `credential_unavailable` before a network request. Correct access
and create a new connection after `source_access_denied` revokes an old one.
Provider response bodies and exception text are never shown as error messages.

## Verification status

Automated tests exercise all five adapters through the actual configuration,
transport and ingestion transactions, with synthetic provider responses. Portal
and CLI tests cover all five setup paths and credential-free background jobs.
These checks establish implemented behavior, not private-service compatibility.

The rebuilt native app imported `elixir-lang/elixir` repository metadata and
30 real public issue/PR snapshots, then resumed one PR-review page. The durable
cursor preserves the verified repository ID and opaque continuation; the scan
correctly remains incomplete. Authenticated GitHub, Projects,
Slack, Jira and Confluence imports have not been qualified: API credentials and
individual live resource selections were not supplied. Browser sessions work
for GitHub/Projects/Slack; the selected Jira/Confluence tenant currently displays
“Page unavailable”. No private live content was imported. The exact final test
counts and package/browser observations are recorded in [verification.md](archive/verification.md).

Official API references checked 31 October 2026:

- [GitHub Projects GraphQL API](https://docs.github.com/en/issues/planning-and-tracking-with-projects/automating-your-project/using-the-api-to-manage-projects)
- [Slack team.info](https://docs.slack.dev/reference/methods/team.info/)
- [Slack conversations.info](https://docs.slack.dev/reference/methods/conversations.info/)
- [Slack channel history](https://docs.slack.dev/reference/methods/conversations.history/)
- [Slack threaded replies and user-token requirements](https://docs.slack.dev/reference/methods/conversations.replies/)
- [Confluence Cloud REST v2 pages](https://developer.atlassian.com/cloud/confluence/rest/v2/api-group-page/)
- [Existing GitHub/Jira endpoint references](../lib/harness_forge/connectors/README.md)
