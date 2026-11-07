# Iteration 12 UI implementation advice

Report-only advice for root and Principal B, 2 November 2026. This is not another approval gate. No product/test edits or runtime checks were performed. The accepted count remains root-owned. No Figma asset was supplied for this standalone OSS surface.

## Recommended composition

Use one page, titled **Corpus evidence review**, with the existing Company tokens and native labelled controls. The standalone wrapper must receive the token/44px-target rules currently scoped to `.company-builder` and `.company-analysis-report` in `assets/css/app.css:166–187`; otherwise global controls fall back to smaller typography and targets.

1. **Inspection scope.** Paged captured-connection, saved-project and assigned-saved-goal controls; an explicit **Open inspection** action. Show selected goal title, owner and acceptance before a disclosure containing hashes. Changing a selection clears passage/report content. Use the separate line: “Inspecting this captured corpus does not assign its sources to this project.” Show saved project assignment counts independently.
2. **Local capture facts.** A compact definition list, not a progress bar: captured records, current captured revisions, unavailable captured records, actual connection sync state and last-sync time. Explain “Current” as the available captured revision, not current policy. Say “Import/discovery coverage: unknown” and “Analysis coverage: unknown.” A completed connector page or sync flag establishes neither complete company capture nor semantic coverage.
3. **Additional inspected corpus evidence — not part of this recommendation's model input.** Explicit literal search, up to 25 metadata rows, previous/next controls, and one opened passage of at most 4,096 UTF-8 bytes including context. Each row needs a readable source title, capture date or unknown, availability and **Open passage** button. Keep long IDs out of the row's primary text. Use “Candidate evidence · needs review”; no support/conflict colouring or inferred historical status.
4. **Original analyzed evidence.** A bounded matching-recommendation picker, original report, current eligibility, and **Continue to exact review**. Show uncertainty, original stored finding kinds and human-resolution requirement before collapsed provenance. Preserve the existing `Analysis.report/1` immutable excerpt/link semantics. A report using sources outside this inspection connection needs a nearby explicit notice. Do not infer that its report covers the selected corpus.

On wide screens, the last two regions may sit beside each other using `minmax(0,1fr)` columns. Keep their DOM order identical to their narrow layout. At narrow widths/200% zoom stack them; avoid fixed sidebars, horizontal carousels, sticky action bars and nested scrolling passages. This keeps comparison usable without adding an independent search workspace.

## Copy and progressive details

Keep the ADR sentence visible near the scope: “Browse captured evidence across this corpus. Model analysis still uses 2–4 explicitly selected sources; this preview has not analyzed the whole corpus.”

| Situation | Concrete copy/interaction |
|---|---|
| Search | “Literal keyword matches within this captured corpus. Results need review.” Submit explicitly; a goal-title seed remains editable and does not run automatically. |
| Zero results | “No captured records match these keywords. This does not establish that supporting or conflicting evidence is absent.” Offer the existing clear-query or first-page action. |
| Passage | Show source title and capture date first; exact UTF-8 bytes `[start,end)` and revision/hash in **Capture details**. Show “Earlier context omitted” / “Later context omitted” from actual truncation flags. **Next context window** replaces the current text; it does not append windows. |
| Historical metadata | “Document status: unknown”, “Effective date: unknown”, etc. unless a whitelisted captured field has known semantics. Capture/source-updated dates remain separately named. |
| No matching recommendation | “No current recommendation is available for this project and goal.” Keep evidence inspection useful and link to the existing selected-source analysis, with its 2–4-source limit. |
| Review continuation | “Review and edit this exact recommendation. Inspected passages are not added to its original model input.” Pass only the exact revalidated claim identity; preserve destination dirty-edit handling. |

The report's existing structural citation count is the number of distinct **cited** sources (`analysis.ex:433–439`), not necessarily the model's full original input count. Derive analyzed-input scope from the report's validated context refs. Keep both meanings distinct; do not rename the citation count “sources analyzed.”

## Keyboard, status and recovery

Reuse the fixed allowlisted focus-after-DOM-patch pattern in `assets/js/app.js:140–165` through root. Use fixed `tabindex="-1"` headings/status targets with a visible focus style. After an explicit search/page, announce row count and live-page status and focus the results heading; after open/next, focus the passage heading. Close returns focus to the exact still-mounted source trigger; if unavailable, use the results heading. Do not move focus merely because a selector changes or a status rerenders. Native labels, fieldsets, buttons and disclosures suffice; avoid custom comboboxes or dialog focus traps.

Use a small polite status region for outcomes, an associated alert/error summary for refusals, and ordinary text in addition to colour. Do not put whole excerpts or the full result list in a live region. Apply visible focus to links, summaries and programmatic targets as well as controls. Existing Company spacing, typography, wrapping and target tokens should serve this scope; no new visual system is needed.

For expired paging: “This live page expired. Refresh captured records to start again.” Preserve safe query/goal choices. For changed source/hash: clear the old passage and say “This captured revision changed. Refresh and explicitly reopen the current passage.” For reset/revocation/privacy failure: remove passage/report text immediately and show a safe bounded explanation; do not retain old text as a draft or silently repin. An explicit refresh creates fresh handles, not approval or corpus completeness. Do not offer resume/retry-analysis/Graphiti controls without an existing implemented operation.

## Root's focused browser proof

Record the actual authenticated selector→nonfirst page→search→open→next→close→matching report→continue journey and one stale/reset recovery. At 320/390 CSS widths and 100/200% zoom, verify wrapped titles/URLs/hashes, readable goal acceptance, stacked columns, reachable controls, no document horizontal overflow, visible focus and no hidden revoked text. Check keyboard order and outcome announcements. These observations establish only the tested behaviour; no full WCAG, novice independence, semantic recall, complete coverage or million-file readiness claim follows.

Static reference scope and file fingerprints are recorded in `tmp/enhancement-program/12/ux-read-audit.json`. Root remains sole runtime/board owner; A/B/root retain their assigned source/test ownership.
