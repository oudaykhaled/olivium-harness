# A03-01 Home: parser-fix addendum07

**Blocking:** None. Review06’s P2 is resolved in source07. Scoped source approval; no overall A03 acceptance or release claim.

**Evidence:** The only source06→07 delta is `company_home_next_action_test.exs:303–309`: `query/2` now parses a fragment with the installed LazyHTML parser, queries the unchanged selector, and materializes the matches as a list. `text/2` joins the selected nodes’ text and trims it. Empty-result, match-count, descendant, attribute, visibility-marker, text and ordering assertions are retained. All fixtures, test cases and other helpers are unchanged; no dependency or product code changed.

Root’s actual check35 receipt records exit0 with stable before/after source maps; its log records **44 tests, zero failures**. This closes the unavailable-Floki verification gap rather than weakening the tests. The debugger receipt correctly describes the two-helper-only change; its earlier “pending” test status is superseded by check35.

All seven current files match source07 snapshots and pins. The six unchanged files, including all three production files, retain their source06 hashes. Freeze07 SHA-256: `4486c082372d09ce26790a9fd5b457c7b635008f5adaba9df4b6b292e28793f8`.

**Non-blocking / limits:** Review06 remains the historical changes-requested record. Its product-source findings and scope limits continue to apply. Formatting/canonical checks, candidate04 build and actual desktop/narrow Home keyboard/geometry evidence remain Root-owned qualification steps. Artifact proof from an earlier candidate does not qualify the new Home presentation. A04 durable resume and full A03 completion remain unclaimed.

**Nit:** None. **Praise:** The repair reuses the installed parser and preserves all structural assertions.

No tests, runtime, browser, screenshots, board or product edits were performed by this reviewer. Ownership released to Root.
