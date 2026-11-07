# ADR 10 — Recognize the evidence behind an exact recommendation

Status: Astra selection, pending root scope acceptance and conductor's original-running planning barrier. Date: 2026-11-02. This record authorizes no implementation by itself. Iteration 09 is complete, 9/50; iteration 10 is UI/UX.

## Context

The owner must judge whether a recommendation reflects selected company history and a saved future goal before editing, rejecting or approving it. `PRODUCT_OUTCOME.md` connects that judgment to separately approved Company plans, coherent target files and ultimately owner-reviewed representative tasks. Iteration 09 demonstrated the synthetic analysis→human review→export mechanics. It did not demonstrate real-model reasoning, complete obligations or successful company work.

The five complete 09 retrospectives and entire handoff were read before selection, followed by AGENTS, the product outcome, verification/install records, accepted evidence, final result/root acceptance and all five final QA originals. All sixteen original final proposals were subsequently read in full. The accompanying receipt binds exact bytes and individual dispositions; proposal counts play no part in this decision.

Reopened findings expose excerpts, source/revision IDs and UTF-8 spans, while the selection view also exposes names, dates and links (`lib/harness_forge_web/components/company/analysis.ex:249,473`). The shared report appears in Company and at the actual Evidence decision (`lib/harness_forge_web/live/portal_live.ex:1661`). Improving only Company would leave the decision surface inconsistent.

The data boundary is decisive. `Evidence.Source.title` is mutable CURRENT metadata, even when a revision still matches. `Evidence.Revision` retains capture date and URL; there is no guaranteed historical title (`lib/harness_forge/evidence/records.ex:19,35`). `Evidence.list_sources/0` supplies already-loaded latest-only DTOs; `source_dto/1` hides the revision when source/connection is unavailable (`lib/harness_forge/evidence.ex:51,681`). An old pin cannot borrow the latest date or URL. Historical retrieval would introduce a different query/privacy contract.

## Decision

Select ONE connected benefit: **recognizable, accurately qualified evidence beside original finding excerpts at exact recommendation review, in both Company and Evidence**. Use existing loaded source DTOs with a pure exact-match display projection. No domain lookup, historical-read API, schema or authority change is needed.

### Frozen presentation contract

1. For each original citation, locate its exact source/revision reference in `basis.context.sources`. Display metadata only if the loaded active source's ID, exposed latest revision ID, revision's source ID and body hash match that reference and the citation's IDs. Missing, malformed, ambiguous or mismatched data fails closed to display fallback. Do not interpret a matching snippet or title as a revision match.
2. An available nonblank source name is labelled **“Current source name (may have changed)”**, including when all pins match. It is never called a captured title. An unavailable name gets explicit name-unavailable text. Never infer a historic name from URL, current title, model output or search.
3. On an exact match, show the revision's capture date, explicitly unavailable when absent. A capture timestamp is neither policy chronology nor proof that external content is current. Use a brief accompanying explanation that the link was stored with the capture and its destination may have changed.
4. Show a source link only from that matched revision, validated as bounded, valid text with an absolute HTTP(S) host, no userinfo, control characters, whitespace, backslash or malformed URI. Render through escaped HEEx, with an explicit accessible label and `target="_blank" rel="noopener noreferrer"`. Missing/unsafe URL yields “Source link unavailable” with no anchor; raw unsafe URL is not echoed. Reuse/factor the existing pure `source_url/1` policy within this component so picker and report do not disagree. No network lookup, preview, prefetch or automatic link opening.
5. On changed/latest-only, missing, revoked or unavailable metadata, show **“Pinned capture details unavailable or changed”**, keep the original excerpt and exact source/revision/span, and omit the added name/date/link. State that the original pin is retained. This intentionally provides less detail for older captures; it never substitutes new metadata. A normal supported refresh/reload determines the available DTO, not an inferred guarantee of immediate external-writer freshness.
6. Preserve full exact source ID, revision ID and UTF-8 byte span with exclusive-end meaning. Retain existing context body hashes and exact claim/goal revision details in their disclosure. Long text wraps and remains selectable; no ellipsis replaces authority text. Excerpts remain primary, metadata secondary; no general layout redesign.
7. Opening/reopening reports, expanding details, following a link and returning are view operations. They do not select/repin inputs, infer, retry, resolve, create a successor, approve, reject, build or export. Original report bytes, all influencing pins (including uncited context), exact Evidence decisions and separate exact Company-plan decisions remain unchanged. Imported labels/URLs are data, never instructions.

The report still shows saved goal intent, original uncertainty/conflict, current guidance and saved human resolution using the existing flow. This is a substantive review improvement inside the connected company journey, not packaging-only cleanup. It makes no new claim about semantic support or completeness.

### Reuse, ownership and blast radius

Reuse `Company.Analysis.report/1`, its citation loop and selection link treatment (`analysis.ex:426–550`), passing the builder's existing `@sources` at its report call (`:341`) and PortalLive's existing `@sources` at the Evidence call (`portal_live.ex:1661`). Keep `sources` defaulting to an empty list for safe older callers. Prefer a small pure helper in the existing component; no new read service or repository query.

Root dispatches implementation only after scope/barrier acceptance, preserving the maximum three distinct product authors including corrections/root. Suggested PR-sized units, ideally ≤400 net lines each:

| Unit / owner | Owned surface | Blast radius and confirmation |
|---|---|---|
| A, Elixir/Phoenix component author | `components/company/analysis.ex`; focused component/unit assertions | Pure pin projection, qualified labels and safe URL rendering; both reports share one rendering contract. No database/provider/approval code. |
| Root integration | One `portal_live.ex` report attribute; narrow existing LiveView tests; `assets/css/app.css` only if actual wrap checks require it | Pass already-loaded data to Evidence; existing auth/reset/dirty fences stay intact. CSS restricted to report metadata. Root owns all runtime checks. |

Use the existing `test/harness_forge_web/company_analysis_test.exs` and relevant portal/component tests; tests must assert attribution and absent side effects, not merely copy strings. No dependency/version upgrades, new JS hook, new route or new model setting. Actual Guardrail, impediment and Principal UI/UX advice remains conductor-owned and must be consumed within this scope before authors; it does not create a new approval chain. If advice discovers an authority defect, report concrete evidence rather than silently broadening this ADR.

## Confirmation and acceptance handoffs

Root is the sole runtime/Mix/test/format/build/Docker/native/browser/HTTP/process/database executor. Delegates may read/hash/local-view and write their assigned artifacts. The following are scoped acceptance requirements, not claims already passed:

| Case | Required observable result |
|---|---|
| Positive connected review | Reopen an analysis from at least two selected synthetic history sources and a saved goal in Company AND Evidence. Each eligible excerpt shows qualified CURRENT name, exact capture date/safe link and unchanged IDs/span, alongside existing goal/uncertainty/current-guidance distinction. Record exact report/pin/decision/request projections before and after viewing. |
| Current-name truth | Change only the mutable name while keeping the exposed revision; the UI still says CURRENT and never claims historical title. Malicious HTML in a title/snippet stays escaped data. |
| Changed pin | Advance one cited source to a newer revision with different title/date/URL; reopen after supported refresh. Its old excerpt/pin remains, with fallback and no new metadata/link. Also test same revision ID with mismatched body hash, wrong source ID, missing context reference and absent metadata. No implicit refresh of authority. |
| Safe/missing metadata | Valid HTTP(S) stored link renders; absent date/name has its specific fallback. Missing URL, `javascript:`, `data:`, credentials, relative/protocol-relative URL, controls/whitespace/backslash and malformed text produce no anchor or raw unsafe URL. No live remote call is required for negative cases. |
| Privacy/auth | Loaded unavailable/revoked source or connection and missing source render no added metadata/link after supported refresh; purged claims remain removed by existing semantics. Another workspace's DTO cannot satisfy the current workspace's supplied data path. Auth loss and privacy reset clear existing assigns; no new endpoint or historical fetch bypasses them. Do not claim immediate external-writer cache invalidation. |
| Unavailable model | Reopening both reports still works with no usable configured model, makes zero inference requests and offers no fallback/download. Already-approved current-data build/export remains independent of model availability; stale-data build/export still refuses. Preserve the distinction between native changed/unavailable model proof and integration-only unset-model proof unless newly measured. |
| Dirty/reset/late-event recovery | Follow the source link and return without losing dirty guidance or changing selected report. Existing save/discard fence still blocks leaving review. Reset/auth-loss/remount and queued old events cannot revive draft, selected report, added metadata or an inference action. Deliberate refresh/reopen shows current fallback without rewriting the old pin. |
| Responsive keyboard matrix | Root records actual 320 AND390 CSS-pixel widths at actual100 AND200% browser zoom in both review locations, using long names/IDs and available/unavailable links. No unintended horizontal overflow or clipped authority text; logical Tab order, visible focus, keyboard link activation and return retain context. Capture native evidence and dimensions; CSS scaling alone is not browser zoom. Restore existing browser state afterward. |
| Downstream noninterference | Use synthetic approved guidance in the existing connected plan/build/export flow: exact Evidence and separate plan approvals remain required, edited guidance reaches target files, rejected/pre-edit guidance does not, and metadata presentation causes no extra request/decision/build/export. Compare relevant immutable payloads/digests; no generated instructions execute. Preserve unrelated records and external exports. |

Falsifiers are any current-to-pinned substitution, unqualified captured-title claim, unsafe link, cross-scope disclosure, hidden/truncated authority, inaccessible link at the measured matrix, revived reset state or view-induced authority/inference/artifact mutation. A failure is not reclassified as success through a screenshot or aggregate test count. Root should run focused semantic regressions plus the required canonical checks once against final frozen source, retaining failed attempts and distinguishing repeated tests from new identities. Native walkthrough proves reachability, not novice comprehension. No new user study is an implementation gate.

## Consequences

The owner receives readable context at the point of judgment with a falsifiable provenance rule. Reusing loaded data avoids new I/O, schema, consent or revocation paths and keeps rollback to a small presentation/pass-through reversal with no data migration. Exact decisions continue to govern compilation.

The cost is more vertical space and deliberately sparse older-source displays. Even an exact-match date/URL is not a captured historical title or guaranteed current external page. Mounted metadata may remain cached after an external writer until supported refresh, just as 09 recorded; this iteration neither solves nor hides that limitation. Links are explicit user navigation and may leave the application; noreferrer prevents sending the workspace page as referrer.

No improvement in review time, comprehension or company task quality is claimed without measurement. Root's prior 587 canonical passes plus Docker15 covered602 identities; focused92 and syntheticJS22 were separate. Dialyzer retained two existing unsuppressed diagnostics. These are inherited facts, not iteration10 results.

## Alternatives and preserved dissent

**Actionable stale-build recovery (09 Architecture/Security; planners06/08/13):** directly repairs the observed image39 refusal after uncited drift and helps the owner regain a valid package. It can be a small change, but a correct action needs reason classification, disclosure navigation/focus and dirty/reset checks. Some failures require access or storage repair rather than fresh inference. Recognition is selected because it improves judging every opened recommendation before authority is granted, using one shared renderer and no event transitions. Stale-build recovery remains a concrete open next UI/UX candidate, not rejected on votes or severity assumptions.

**Guide discovery and missing-model guidance (01/02/16):** improves finding the analysis journey and distinguishing new inference from continuing approved work. It adds saved-state branching and prerequisite semantics, while not explaining an excerpt at the decision. Retain it separately; model availability must never become build authority.

**Recommendation-to-plan continuation (10):** reduces wrong turns through the whole journey but requires matching selected claim AND goal to a plan, eligibility and several state transitions. It is a larger state-machine change than this presentation benefit. Automatic plan selection remains unacceptable.

**Historical metadata retrieval (03/04):** can show old revision dates/URLs after recapture, improving historical recognition. It adds scoped query, revocation and missing/deletion contracts, and still cannot reconstruct a historical title. Defer the API/domain expansion; explicit fallback is acceptable and honest now. Doing nothing avoids added text but leaves the demonstrated recognition gap.

Iteration11 remains UNSELECTED among owner-reviewed task-rubric receipts (Product), mounted-domain-purge freshness (Architecture/Security), and selected-goal milestone coverage at exact approval (Quality/UIUX). The first begins measuring owner outcomes but is not trusted runtime qualification; the second fixes observable cache consistency but not semantics; the third proves declared accounting, not complete/coherent obligations. Prior08 real-outcomes-first, coherence/completeness, portable signer/scope/freshness/revocation, per-client MCP revocation and creation-time versus approval-time coverage dissent remains substantive. Approval-time coverage preserves partial drafts; insertion-time checks strengthen creation invariants at authoring cost. No agreement resolves these contracts.

Explicit non-goals: Guide routing, generic stale-build remedy, historical metadata/API/schema changes, mounted external-purge invalidation, new task evaluators, goal-coverage enforcement, MCP tools/auth changes, model installation/fallback/paid calls, portable approval and host execution. Preserve all direct goal/profile/project mutation and complete boundary/scope test gaps, earlier helper historical-hash limits, external exports beyond purge control, and unproven real-company/model/coherent obligations/all-live-connectors/managed Codex-Claude/Linux/portable authority/full WCAG/speech/novice/log confidentiality/longitudinal reliability. Main09 PID68553/8865 remains the recorded standard MCP-off/no-probe installation; historical01 MCP36093/8867 stays observation-only. No publication, git mutation, private import or access expansion.

## Sixteen final-proposal dispositions

Each row refers to the final full-read file under `planning/`; exact final sizes and SHA-256 values are in `tmp/enhancement-program/10/astra-read-receipt.json`. “Incorporate” means a bounded constraint of the selected benefit, never a vote or authority to add a second feature.

Same-original factual corrections amended04/05/07/09/10/11/12/14 before final freeze; all eight final files were reread in full. Earlier READY hashes are message provenance only: no separate pre-correction physical copies or independent historical hash verification were retained. The receipt binds final retained bytes only; it does not reconstruct or claim historical-byte proof.

| Original | Final proposal | Disposition and reason |
|---|---|---|
| 01 | `01-analysis-entry.md` | Defer entry/next action. Strong discovery outcome, different saved-state/navigation surface; preserve manual Evidence route and no automatic selection. |
| 02 | `02-guide-discovery.md` | Defer Guide row/readiness branching. Report existence is not approval; selected scope does not claim to fix discovery. |
| 03 | `03-pinned-identity.md` | Incorporate exact revision and CURRENT-title truth; defer historical read model. Loaded exact-match fallback avoids new domain/privacy contracts. |
| 04 | `04-safe-metadata.md` | Incorporate safe escaped links, explicit missing states and qualified current name; defer `evidence.ex` lookup/projection expansion. |
| 05 | `05-conflict-review.md` | Incorporate evidence recognition at decision, preserve original conflict/current-guidance distinction. Do not add a new “Why” flow or imply a captured historical title. |
| 06 | `06-keyboard-focus.md` | Defer stale-recovery action. Carry keyboard/focus, actual zoom and no navigation side effects into report acceptance. |
| 07 | `07-width-zoom.md` | Incorporate full selectable authority text, wrapping and the complete320/390×100/200 matrix. Current-title qualification is mandatory. |
| 08 | `08-stale-recovery.md` | Defer reason-specific build recovery. Preserve distinction among changed pins, access, storage and model failures; no silent renewal. |
| 09 | `09-privacy-refresh.md` | Incorporate active loaded DTO exact source/revision/hash gate, reset fences and explicit mounted-cache limit; current name always qualified. No new invalidation work. |
| 10 | `10-plan-continuation.md` | Defer multi-step continuation. Exact claim AND goal plus separate plan approval remain downstream noninterference oracles. |
| 11 | `11-novice-readability.md` | Incorporate clear metadata/fallback language; label title CURRENT even when revision matches. Do not assert novice comprehension or redesign uncertainty flow. |
| 12 | `12-mcp-presentation.md` | Incorporate portal-only disclosure boundary and zero extra bodies; own-MCP remains unchanged, readiness is not portable authority. |
| 13 | `13-regression-evidence.md` | Defer stale-build feature; incorporate independent absent-side-effect, reset and truthful test-accounting approach for chosen scope. |
| 14 | `14-minimal-ownership.md` | Incorporate shared report/both call sites and no data-access expansion; qualify mutable name. Historical detail remains explicit fallback. |
| 15 | `15-company-outcome.md` | Incorporate decision-point rationale, current-title truth and latest-only gate. Representative owner tasks remain the ultimate unmeasured outcome. |
| 16 | `16-missing-model.md` | Defer Guide branch; incorporate unavailable-model viewing and approved-data authority distinction. No model prerequisite for reopening/approved builds. |

Conductor must capture all SAME sixteen original planners actually RUNNING after this full-read/disposition, then release and require their completions; no replacement/reactivation or self-release. Root fully reads this decision/receipt and accepts scope before implementation authors. Astra remains running on bounded waits after FINAL_READY until conductor RELEASE.
