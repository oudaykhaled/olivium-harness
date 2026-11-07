# Confluence Cloud connector

This read-only connector imports current page text from one explicitly selected
Confluence Cloud space. It uses REST API v2 with `Req 0.7.5`. It makes fixed GET
requests; it never uses browser cookies, creates pages, executes macros, follows
page links or downloads attachments.

## Configuration and permissions

The configuration contains references, never credential values:

```json
{
  "endpoint": "https://your-tenant.atlassian.net",
  "space_id": "123456",
  "username_ref": "HARNESSFORGE_CONFLUENCE_EMAIL",
  "credential_ref": "HARNESSFORGE_CONFLUENCE_TOKEN"
}
```

Set those environment variables before starting HarnessForge. The username is
the API user's email and the credential is an Atlassian API token suitable for
direct authentication to that tenant. The API user must be able to view the
selected space and pages. A browser login does not configure API authentication.
Scoped tokens requiring the `api.atlassian.com/ex/confluence/{cloudId}` gateway
and OAuth are not supported by this direct-tenant connector.

The endpoint must be exactly one HTTPS `*.atlassian.net` origin with no path,
query, credentials or trailing slash. `space_id` is a positive decimal string,
not the display name or space key. Both credential references are required.
The API token's broader permissions never expand the configured space.

## Import behavior

1. A sync verifies `GET /wiki/api/v2/spaces/{space_id}` and stores its verified
   space key in the resumable cursor. This metadata request imports no document.
2. Each following sync reads at most 20 current pages from
   `GET /wiki/api/v2/spaces/{space_id}/pages`, requesting
   `body-format=atlas_doc_format`. The space ID is checked on every page.
3. A page's opaque next cursor is extracted from `_links.next` and/or the `Link`
   header. The link's tenant, path and query are validated. Only the cursor is
   reused; the next request is reconstructed with the fixed space and filters.
4. A completed scan resets to space verification for the next full scan. The
   connection's completion flag distinguishes a partial scan from completion.

Each source preserves stable page ID, selected space ID/key, original author,
creation time, current version number, version author/time and text-normalizer
version. The source identity is `confluence:<connection UUID>:<page ID>`. Its
provenance URL is the stable Confluence route
`https://tenant.atlassian.net/wiki/pages/viewpage.action?pageId=<page ID>`.

ADF text is extracted into inert UTF-8 text. Supported text containers include
paragraphs, headings, lists, code blocks and tables. Formatting marks and links
are discarded. Macros, media, smart cards and other unsupported nodes become
`[unsupported Confluence content]`; the metadata reports their omitted-node
count. Their attributes and nested content are not expanded. This is deliberately
lossy extraction, not full-fidelity rendering or macro execution. Raw source
instructions remain untrusted evidence and never approve claims.

Responses are bounded to 4 MiB, ADF input to 1 MiB per page, nesting to 16 and
visited nodes to 10,000. Invalid pages reject the entire fetched page before its
cursor can advance. Responses containing duplicate page IDs also reject. Every
network call rejects redirects, retries no request automatically, and has a
15-second receive timeout with a 5-second connection timeout.

HTTP 401/403/404 revoke the connection and withdraw its sources from retrieval
and approval eligibility. HTTP 429 retains the cursor and exposes a bounded
retry delay. Errors and audit records exclude credentials and raw provider error
bodies. Other temporary failures leave committed evidence and cursors intact.

## Coverage and limitations

The automated connector suite uses synthetic HTTP responses through `Req.Test`
and the actual `Evidence.connect/1` and `Evidence.sync/2` transaction paths. It
covers pagination/resume, idempotency, exact citation creation, proposed claims,
version changes, scope violations, failed-page atomicity, rate limits,
revocation, redirects, redaction and hostile ADF/cursor inputs.

These tests do not establish live compatibility for a private tenant. Live
verification needs an available tenant, an explicitly selected space and API
credentials supplied by the operator. No private live request was made during
this implementation because the selected Atlassian site was unavailable and no
API credentials were configured.

The connector does not import historical page versions, comments, attachments,
blogs, whiteboards, content databases or restricted content unavailable to the
API user. It does not detect deletion or page-level permission withdrawal from
absence in a later scan. Previously captured evidence can remain available
until its source/connection is revoked or purged; a successful scan is not a
continuous ACL guarantee.

## Decision record

Context: HarnessForge needs bounded, attributable evidence without executing
remote content or importing every space a token can access.

Decision: Use the Confluence Cloud REST v2 selected-space page endpoint, explicit
space checks, stable page IDs, inert bounded ADF text extraction and atomic
resumable page commits. Credentials remain environment references.

Consequences: Imports preserve reviewable provenance and recover after a failed
page. Full scans cost one metadata request plus one request per 20 pages.
Unsupported ADF content is visible as omitted content; complete rendering and
deletion/permission reconciliation need separate future implementations.

Alternatives considered: Storage-format HTML preserves more markup but needs a
separate sanitizer/normalizer and does not make macros safe to run. Crawling the
browser would depend on session cookies and changing UI behavior, and would
obscure the configured API scope.

## Official references

- [Confluence REST v2 pages and selected-space pages](https://developer.atlassian.com/cloud/confluence/rest/v2/api-group-page/)
- [Space identity endpoint](https://developer.atlassian.com/cloud/confluence/rest/v2/api-group-space/)
- [Authentication and cursor pagination](https://developer.atlassian.com/cloud/confluence/rest/v2/intro/)
- [Atlassian Confluence URL formats](https://support.atlassian.com/confluence/kb/confluence-url-list/)
