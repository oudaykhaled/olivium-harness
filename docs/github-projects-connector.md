# GitHub Projects v2 connector

The `github_projects` provider reads one selected organization or personal project
from GitHub.com. It uses fixed GraphQL queries over `POST
https://api.github.com/graphql`; it cannot run a user-supplied query or mutation.
This is separate from the `github` repository connector.

## Configure the selected project

Use a canonical project URL without a view suffix, query, fragment, port or
embedded credential:

- `https://github.com/orgs/OWNER/projects/NUMBER`
- `https://github.com/users/OWNER/projects/NUMBER`

Provide the credential through an environment variable in the application
process. Store its **name**, not the token, in the connection:

```elixir
{:ok, connection} = HarnessForge.Evidence.connect(%{
  "provider" => "github_projects",
  "name" => "Selected delivery board",
  "config" => %{
    "endpoint" => "https://api.github.com",
    "project_url" => "https://github.com/orgs/OWNER/projects/7",
    "credential_ref" => "HARNESSFORGE_GITHUB_PROJECTS_TOKEN"
  }
})

HarnessForge.Evidence.sync(connection["id"])
```

A classic personal access token requires `read:project`; `project` also grants
query access but includes unnecessary write permission. Fine-grained or GitHub
App credentials need **Projects: read** for the selected owner/project where
GitHub supports that credential type. The account must have project access, and
repository permissions determine which linked issue/PR content is visible.
Organization approval or SSO authorization may also be required. Browser login
cookies are not API credentials.

When GitHub reports non-empty classic OAuth scopes, the adapter verifies the
project scope. Missing or empty scope headers do not establish fine-grained
permissions; GitHub must authorize the actual project query. A forbidden or missing
project revokes the local connection. Credentials and raw provider errors are
excluded from connector result/error metadata.

## Imported data and completeness

Sync progresses through durable stages: project metadata → fields → views →
items. Each call imports one top-level page and reports `complete: false` until
the item scan finishes. Invoke sync again to resume. After completion, the next
call starts a fresh scan; unchanged snapshots deduplicate.

The connector imports:

- Project title, description, readme and closed state.
- Field definitions, status/select options, multi-select options and iteration
  configuration.
- View name, layout, filter, visible fields, grouping fields, vertical grouping
  and sort fields. Nullable view configurations remain explicit nulls.
- Active and archived item membership; draft, issue and pull-request bodies;
  visible field values; explicit placeholders for redacted items.
- Text, date, number, select, multi-select, iteration, repository, milestone,
  label, user, requested-reviewer, linked-PR and organization issue-field values.

Every normalized source URL is exactly the configured project URL. Metadata
records `project_url`, `project_id`, `owner_kind`, `owner`, `number`, `kind` and
`normalizer_version: github-projects-v1`. Items also record their stable item ID,
item type, redaction state, and visible content ID/URL. Source identities are
`github_projects:<connection UUID>:<stable GraphQL node ID>`.

An issue or PR can belong to a repository outside the repository connector's
selection while being a legitimate member of the selected project. Its content
is read only through project membership. The connector never follows content
URLs, enumerates linked repositories or fetches hidden content separately.

Top-level pages contain at most 20 records. Nested connections use 50-record
pages and are exhausted before a page commits, with a shared budget of 32 HTTP
requests. Repeated/oscillating cursors, duplicate nested records, malformed data,
unsupported future value types or exhausted bounds reject the entire page.
Top-level cursor state is bound to the connection and project URL and permits at
most 100 continuation pages per stage. The conservative connection-node bound
for the item query is approximately 201,000, below GitHub's separate 500,000-node
limit. Transport limits remain 4 MiB per response, no redirects/retries, a
15-second receive timeout and a 5-second connection timeout. Source documents
must also satisfy the application's 1 MiB document bound.

HTTP 200 responses containing GraphQL errors, including partial data, never
commit. Rate limits return a safe retryable error; sync does not sleep or retry
automatically. HTTP `Retry-After` handling is shared with the other connectors.

`complete` describes the current credential's visible scan, not a transactionally
consistent remote snapshot or proof of current ACLs. Remote edits during a scan
can require another scan. Removals, deletions and lost access to individual
previously imported items are **not detected** automatically. Revoke or purge a
connection/source to withdraw stored evidence. Project automation rules,
collaborators, comments, item-change history and rendered board geometry are not
imported.

## Design decision

**Context:** Projects v2 has project-level fields, views and polymorphic items,
with independent pagination for item values and collection-valued fields.

**Decision:** Use fixed GraphQL queries and staged application cursors. Revalidate
project identity on every top-level response and project membership on every
nested response. Commit complete normalized pages atomically through Evidence.

**Consequences:** A sync may need multiple explicit operations. Nested work has a
bounded cost and fails visibly if it cannot be completed within that cost. API
errors cannot silently convert partial data into a successful snapshot.

**Alternatives considered:** GitHub's REST Projects v2 endpoints provide another
read surface, but the GraphQL schema supplies the view/field/value shapes used
here in a unified project membership query. Browser scraping depends on session
cookies and changing rendered HTML, so it was not selected for source ingestion.

## Verification and official references

`mix test test/harness_forge/github_projects_connector_test.exs` exercises the real
Evidence connection/sync/import transaction path with synthetic `Req.Test` HTTP
responses. Tests cover org/personal selection, resumable pages, all nested query
routes, deduplication, scope boundaries, redaction, rate limits, missing
credentials, malformed responses and atomic rollback. These tests do not prove
live access to a private project.

On 2026-10-31, all 14 generated query shapes captured from HTTP request bodies
were validated with `graphql-core` 3.2.7 against the official GitHub schema below.
The schema SHA-256 was
`ee690896ae7d9126765c6a660174b40c9d1974b70db36af8559117b9c4a7b7a6`.
Set `HARNESSFORGE_GRAPHQL_VALIDATION_DIR` to a temporary directory while running
the connector test to capture the fixed query text for independent validation;
the capture excludes query variables and credentials.

- [GitHub Projects API usage and authentication](https://docs.github.com/en/issues/planning-and-tracking-with-projects/automating-your-project/using-the-api-to-manage-projects)
- [GitHub GraphQL Projects reference](https://docs.github.com/en/graphql/reference/projects)
- [Official GitHub GraphQL schema](https://docs.github.com/public/fpt/schema.docs.graphql)
- [GraphQL rate, node and resource limits](https://docs.github.com/en/graphql/overview/rate-limits-and-query-limits-for-the-graphql-api)
- [Fine-grained token Projects permissions](https://docs.github.com/en/rest/authentication/permissions-required-for-fine-grained-personal-access-tokens#organization-permissions-for-projects)
