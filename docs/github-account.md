# Live GitHub account access

The selected-repository source connector imports evidence for one repository.
`HarnessForge.Connectors.GitHubAccount` separately answers explicit live account
requests without importing repository content or calling a model.

Configuration contains exactly `{"credential_ref":"GH_TOKEN"}` (or another
uppercase environment reference). The app resolves the token during dispatch;
raw credentials, endpoints, scopes, and request options are not configuration.
Browser GitHub sign-in does not establish this API connection.

`verify/2` calls `GET https://api.github.com/user` and returns only the verified
account login and numeric ID. `repositories/3` verifies that identity again,
then calls `GET /user/repos` with `affiliation=owner`, `visibility=all`,
`sort=updated`, `direction=desc`, `page=1`, and a requested limit of 1–20
(default 10). The client pins GitHub REST API version `2026-03-10`.

"Top" means most recently updated here. Results preserve GitHub's order,
including ties; this is not a star ranking. Returned metadata is limited to
repository ID, name, full name, GitHub URL, privacy flag, star count, and update
time. `has_more` uses the provider's validated pagination link. `complete`
means the token-visible owned repository list has no next page; it does not
prove access to every private repository. Fine-grained tokens can expose only
their selected repositories. No collaborator or organization-member expansion
is performed.

The response validates owner login and numeric ID against `/user`, canonical
GitHub URLs, unique repository IDs, timestamps, and descending update order.
Foreign-owner or malformed results fail the entire page. No continuation URL
is followed. The existing Req 0.7.5 transport rejects redirects, disables
retries, bounds response bodies at 4 MiB, and uses a 5 second connect timeout
and 15 second receive timeout. Provider bodies and credentials never enter
error details. API denial and rate limiting remain visible, safe errors.

## Decision

Context: local evidence search cannot discover repositories outside imported
sources. Decision: add one compiled, read-only account metadata operation,
reusing `Connectors.Common` for authentication resolution, safe transport,
and pagination checks. Consequence: two API reads per repository request and
no cached authority; each request reflects current token access. Alternatives
were public username lookup (cannot verify "my" account or private access) and
model-generated arbitrary API requests (unnecessary URL and scope exposure).

## Verification

`mix test test/harness_forge/github_account_test.exs` covers fixed requests,
identity verification, ordering, result bounds, absent credentials with zero
transport, foreign owners, unsafe URLs, malformed responses, pagination,
denial, rate limits, response size, and secret-safe errors. Tests use synthetic
Req fixtures and assert that no evidence source or revision is imported.
Fixture tests alone do not establish live token compatibility.

On 2026-10-31 the client also completed a real read-only request using the
existing `GH_TOKEN`: `/user` verified the account, and `/user/repos` returned
10 owned repositories with `ordering=updated_desc`, `has_more=true`, and
`complete=false`. Verification output contained identity and counts only;
private repository names, provider bodies, and the credential were not logged.
This establishes compatibility for those two operations with that token at
that time, not access to every private repository or other connectors.

The API contracts and permission notes were checked against GitHub's current
[authenticated-user endpoint](https://docs.github.com/en/rest/users/users#get-the-authenticated-user)
and [authenticated repository-list endpoint](https://docs.github.com/en/rest/repos/repos#list-repositories-for-the-authenticated-user)
on 2026-10-31. The repository endpoint requires read access to repository
metadata; available results depend on the existing token's permissions.
