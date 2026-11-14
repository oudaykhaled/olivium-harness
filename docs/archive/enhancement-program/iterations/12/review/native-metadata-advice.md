# Native review metadata advice — UI12-02

Principal B, report only, 2 November 2026. No product/test edit or runtime check was performed for this advice. Root reports candidate02's canonical result as 831 registered: 816 passed / 0 failed / 15 existing Docker skips; that result was not rerun by this reviewer.

## Finding and cause

The saved native observations show five current-source metadata blocks in Company (`tmp/enhancement-program/12/browser02/24-5000-continued-exact-review.txt`, lines 260, 276, 292, 308, 321), followed by five generic metadata fallbacks in Evidence (`25-5000-evidence-rejection-review.txt`, lines 111, 118, 125, 132, 136). Those saved text artifacts have SHA256 `ce331c18ed66fd918108c843e4fe0f6842a0728ab6953c2df5ad95a912c65001` and `9526913de31f3292df2d98b78be32ef1257321642ce91eff86de8aa80377af81`, respectively. Reading them is not another native-browser execution.

This is a missing presentation projection, not evidence that these captures changed. The current fallback says “unavailable or changed”; it does not assert a change, but it obscures the loaded-page limitation at the exact decision point.

| Exact code location | Explanation |
|---|---|
| `lib/harness_forge_web/live/portal_live.ex:1263`–1285 | `load_source_page/2` assigns only the bounded source page to `:sources`; its separate metadata lookup covers consent IDs only. |
| `lib/harness_forge_web/live/portal_live.ex:2179`–2184 | Every Evidence analysis report receives that same `@sources` browse page. Off-page original input refs are absent. |
| `lib/harness_forge_web/components/company/analysis.ex:607`–628 | The metadata projection correctly requires a unique source, exact source/revision/hash correspondence, current eligibility and matching workspace. A missing off-page source fails at line 616, just as other unavailable/mismatched metadata does. |
| `lib/harness_forge_web/components/company/analysis.ex:521`–523 | All failures share the existing fallback. It cannot distinguish an unrequested metadata row from a stale/revoked capture. |
| `lib/harness_forge_web/components/company_panel.ex:1049`–1067 | Company already reads metadata for the **selected** recommendation's original refs through `summary_refs/2`, explaining the different visible result. |

Do not weaken the correspondence checks or infer current eligibility from the original excerpt. Preserve the excerpt and its original immutable pin under existing privacy rules.

## Recommended smallest useful correction

Reuse bounded active-recommendation metadata hydration in root-owned `PortalLive`; keep the browse page unchanged. Maintain one separate active report binding containing exact claim ID/hash and at most four source summaries. Derive its refs from the current server-loaded claim after the existing `current_review/2` check (`portal_live.ex:1352`), then call:

```elixir
CorpusReview.summary_refs(%{"recommendation_refs" => current_claim["basis"]["context"]["sources"]}, source_caller(socket))
```

`company/corpus_review.ex:277`–303 already returns body-free metadata and explicit `unavailable_ids`; its ref-group bound at lines 901–902 is four. A successful API return alone does not mean every pin is current: respect nonempty `unavailable_ids`, and retain the component's exact matching checks.

Carry the current selected claim's ID/hash when Company requests Evidence navigation. The existing Company guard at `company_panel.ex:276` must still run before forwarding any selected identity. Its current message at lines 297–300 drops that context, and `PortalLive.handle_info/2` at line 733 receives only the destination. Root can extend this internal message with the server-selected exact claim identity, revalidate it in the parent, and populate the separate metadata binding before showing Evidence. The inspector's validated continuation already establishes an exact requested ID/hash (`corpus_review_live.ex:216`–230), but do not rely only on an older `requested_company_review`: saving a successor or selecting another recommendation can change the actual current selection.

At `portal_live.ex:2179`, provide the separate active metadata only when its claim ID **and revision hash** match the rendered claim. Other cards keep their bounded-page presentation until deliberately selected. Do not collect refs from all `@claims`, widen the source browse list, hydrate bodies into socket assigns, or reuse component caches as authorization. Clear/revalidate this new binding on mutation/reload, privacy/reset/revocation, failed current-origin validation and identity changes, alongside the existing sensitive assigns. Existing claim decision admission remains unchanged.

This is root-owned integration using the existing domain API; no new A API or B metadata guard change is necessary. It restores useful dates/links at the decision point while adding at most four summaries for one selected report.

## Alternative and trade-off

A copy-only B correction is smaller: “Current capture details could not be shown from the loaded metadata. The original excerpt and pin are retained; this display alone does not establish whether the capture changed.” This is truthful for both missing and mismatched metadata and preserves all checks. It leaves the operator without available capture dates/links during exact review, so bounded active-report hydration is recommended for this connected journey. No copy or source change was made in this report-only task.

Root's focused regression should place all four original refs outside the first 25 rows, continue from the inspector, enter Evidence and verify exact metadata/links for the selected matching claim while the browse list remains at most 25 and no source bodies are assigned. Changed/foreign/revoked pins and privacy reset must still refuse/clear that projection; another card must not borrow the active report's metadata. Root owns execution and the resulting evidence.

## Additional observed UX cost, unchanged

`corpus_review_live.ex:146`–152 explicitly clears `:recommendation` whenever search is submitted. Comparing another query therefore requires reopening original findings before Continue is available, even within the same selected scope. The strict continuation at lines 216–238 correctly refuses an absent/mismatched selected report and revalidates before navigation. Record the extra reopen action as a comparison cost; retaining a report across a query would need its own freshness/state decision. This report recommends no change to that behavior in the current correction scope.
