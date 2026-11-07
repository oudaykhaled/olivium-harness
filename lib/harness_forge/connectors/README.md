# Selected-source connectors

Five compiled-in adapters implement `Contracts.Connector` using Req 0.7.5:
GitHub repositories, Jira Cloud, GitHub Projects v2, Slack channels and Confluence
Cloud. All requests are read-only. Four adapters use fixed GET endpoints;
Projects uses only compiled-in GraphQL **query** POST operations at
`https://api.github.com/graphql`. Mutation operations are rejected.

See [configuration and coverage for all five](../../../docs/integrations.md),
[GitHub Projects details](../../../docs/github-projects-connector.md) and
[Confluence details](../../../docs/confluence-connector.md) and
[GitHub cursor compatibility](../../../docs/github-repository-pagination.md).

```elixir
{:ok, connection} = HarnessForge.Evidence.connect(%{
  "provider" => "github", "name" => "Selected public repository",
  "config" => %{"endpoint" => "https://api.github.com", "repository" => "owner/repository"}
})
{:ok, page} = HarnessForge.Evidence.sync(connection["id"])
# Call again explicitly while page["complete"] == false.
```

GitHub credentials are optional for public reads. To use a token, configure
`"credential_ref" => "HARNESSFORGE_GITHUB_TOKEN"` and set that environment
variable outside the application. Jira requires both `credential_ref` and
`username_ref`; both contain **environment variable names**, never values:

```elixir
%{"endpoint" => "https://your-tenant.atlassian.net", "project" => "DEMO",
  "credential_ref" => "HARNESSFORGE_JIRA_TOKEN",
  "username_ref" => "HARNESSFORGE_JIRA_EMAIL"}
```

Configuration rejects unknown keys, credentials embedded in URLs, arbitrary
origins and wildcard selections. GitHub.com and Jira Cloud are supported;
GitHub Enterprise and Jira Data Center are not implemented. Redirects are
rejected. Provider URLs are validated against selection; supplied pagination
URLs are never followed directly. A credential with broader permissions does
not change the configured selection.

Each call fetches one bounded page outside the write transaction, then commits
normalized revisions, their provenance, FTS changes, audit event and next cursor
atomically. Cursors resume after a restart. Replayed content and provenance are
deduplicated. Credentials are resolved at fetch time and never persisted in
config, cursor, revisions, audit, error values or job arguments. Only trusted
callers can inject the `plug:` test transport; connection config cannot do so.

GitHub stages repository metadata, issue/PR body pages and each listed PR's
paginated reviews. Subsequent scans overlap the issue update watermark by
60 seconds. Review coverage follows PRs returned by the issue update endpoint;
there is no independent review event stream or complete comment import.
Jira stages selected-project enhanced JQL search pages and each returned issue's
paginated changelogs. Jira descriptions are normalized from ADF text nodes;
unsupported rich-media attributes are omitted and marked as `adf_text_only`.
Changelog records contain actual transitions only. Jira currently rescans the
project on a new completed scan; its persisted page cursor supports resumable
imports, not a cross-scan change feed.

`sync_state`, `sync_complete` and `last_synced_at` distinguish an unfinished
scan from the last completed one. A failed/inconsistent changelog page does not
advance the cursor. `complete` means traversal completed for the selected
supported endpoint kinds; it does not prove live access, deleted-item detection,
or full project history. Missing items are never inferred to be deleted.
401/403/404 (except explicit rate limiting) revoke the connection and block body
retrieval, search, citations and dependent approval eligibility. Reconnect with
a new explicit connection after correcting access. This implementation does not
claim continuous ACL refresh. Locally captured provenance includes exact source
URL and timestamp, observed time, scope/kind and normalizer version.

Rate limits return safe `rate_limited` errors and bounded Retry-After seconds
when the provider supplies a numeric value. HTTP-date Retry-After values do not
currently produce a delay. There are no automatic provider retries or sleeps;
a caller chooses when to make another explicit sync. Remote Oban errors cancel
that job with the safe code. Response bytes, item count, nesting of ADF, cursor
size, individual source body size, connect time and receive time are bounded.

The offline Req.Test suites exercise real request construction, response
normalization and Evidence transactions for all five providers. They do not
establish authenticated live provider compatibility.
Live Jira verification requires a separately authorized selected project and
credentials. No private-source reads are part of fixture tests.

Primary API references checked 2026-10-31:

- [GitHub repository issues](https://docs.github.com/en/rest/issues/issues#list-repository-issues)
- [GitHub pull request reviews](https://docs.github.com/en/rest/pulls/reviews#list-reviews-for-a-pull-request)
- [Jira enhanced JQL search](https://developer.atlassian.com/cloud/jira/platform/rest/v3/api-group-issue-search/#api-rest-api-3-search-jql-get)
- [Jira paginated changelogs](https://developer.atlassian.com/cloud/jira/platform/rest/v3/api-group-issues/#api-rest-api-3-issue-issueidorkey-changelog-get)
