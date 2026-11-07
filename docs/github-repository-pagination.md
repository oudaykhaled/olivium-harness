# GitHub repository pagination

Repository synchronization verifies the selected repository metadata and stores its positive 64-bit GitHub database ID in the scan cursor. GitHub issue `Link` headers can use either `/repos/{owner}/{repository}/issues` or `/repositories/{verified-id}/issues`. Both shapes must retain the selected origin, filters and page size, and increment the page by exactly one.

An optional opaque `after` value is limited to 2,048 printable ASCII bytes. It is preserved across pull-request review stages and sent as an encoded query parameter on the original selected `/repos/{owner}/{repository}/issues` URL. Remote URLs are validated and are never used as request destinations. Duplicate query keys, unexpected parameters, changed IDs, fragments, credentials in URLs, immediately repeated or dropped continuation tokens, malformed next links and multiple next links fail the page without importing its sources or advancing its cursor.

Older issue cursors without a repository ID re-fetch the selected metadata and preserve their page, `since` filter and scan start. An invalid existing ID or continuation does not trigger an automatic scan restart.

Pull-request review pagination retains the existing selected repository path and integer page validation. Numeric review-path aliases are not accepted without a verified implementation and regression coverage.

This follows GitHub's [REST pagination guide](https://docs.github.com/en/rest/using-the-rest-api/using-pagination-in-the-rest-api), which documents numeric repository issue links and pagination through `page`, `before`/`after` or `since` query parameters. Automated regression data is synthetic; authenticated live connector status is recorded separately.
