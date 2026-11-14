# Iteration 10 implementation interface — qualified evidence at review

Root accepted ADR10 in `tmp/enhancement-program/10/root-scope-acceptance.json` (SHA256 `c7a50fc82c335f3488e343f96fff656b3d36ff3faa9499b4ab2e6c4d561532b5`). This interface resolves the three fresh read-only briefs within that scope. Root has not released authors. Programme count remains9/50; no implementation or runtime result is asserted.

All three complete briefs and audits were read by conductor. Exact final fingerprints and adviser identities are bound by `tmp/enhancement-program/10/conductor-adviser-completion.json`.

| Actual adviser | Final brief SHA256 |
|---|---|
| Guardrail Agent | `1a783a6ff112c7e3afe04f4808f1fbea8e1eafe6055a1e4f6a038a011428bbe5` |
| Staff Tech Lead, impediment removal | `bdc102f85102cd580599e9508ee93c78cc5eaa8acda38085f781bb47c3d24ea2` |
| Principal UI/UX Engineer | `1a54524634d9006de9a6a34cec9c80485c7577153658be5eced7f80c3e4ade92` |

## Ownership and public ABI

Preferred TWO distinct product authors total; maximum THREE including root and corrections. Advisers/conductor are not product authors.

- **Principal Elixir author:** `lib/harness_forge_web/components/company/analysis.ex` and new focused `test/harness_forge_web/company_analysis_metadata_test.exs`. Own presentation, private pure matching/URL helpers, default attribute and Company builder pass-through. Preserve other authors' edits. No runtime commands.
- **Root:** one Evidence report attribute in `lib/harness_forge_web/live/portal_live.ex`; narrow existing caller/integration assertions in `test/harness_forge_web/company_analysis_test.exs`, docs, and optional report-scoped `assets/css/app.css` only when layout/focus evidence warrants it. Root executes ALL format/Mix/tests/build/Docker/native/browser/HTTP/process/DB and writes board/state/results/snapshots.

`Analysis.report/1` ALREADY requires full `claim: map` and `id: string`, with `goals: list = []` (`analysis.ex:422–447`). Add ONLY `attr :sources, :list, default: []`. The full claim already carries real `workspace_id`; no expected-workspace argument is needed.

Company's builder report (`analysis.ex:341`) adds `sources={@sources}` beside existing `claim={@selected}`, id and goals. CompanyPanel already supplies builder sources (`company_panel.ex:1190–1208`). Evidence's existing `AnalysisUI.report` (`portal_live.ex:1661–1666`) adds `sources={@sources}`, keeping its existing full claim/id/goals/condition. Both use ONE renderer and helper. Older callers default to explicit no-metadata fallback.

## Actual input shapes and access provenance

Original displayed citations are `claim["basis"]["report"]["findings"][i]["citations"][j]` with string keys `source_id, revision_id, start_byte, end_byte, snippet`. They have NO citation-record ID, body hash or workspace ID. Do not substitute separately persisted `claim["citations"]`, whose shape differs.

Pin/hash refs are `claim["basis"]["context"]["sources"]`: maps with `source_id, revision_id, body_hash`. Keep existing goal/project/profile pins, uncited context, original findings, current guidance/resolution and all immutable report bytes untouched.

Actual Source DTO contains `id, workspace_id, status, title, latest_revision_id, latest_revision`. The revision map contains `id, workspace_id, source_id, body_hash, captured_at, source_url` (and other existing fields). `Store.dto/1` retains schema workspace fields; there is no `active` boolean. Capture time is stored ISO8601 DTO text; title is mutable CURRENT Source metadata, never a captured title.

Authentication/scoping is upstream: Router/OperatorSession → Portal `reload/1` → `Evidence.list_sources/0` / scoped Store → existing CompanyPanel or Evidence assigns. Unavailable sources/connections hide the exposed revision. Pass this already-loaded list, without new filtering by the currently selected project and without reads in the component. Matching arbitrary DTOs does not authenticate them; a coherent foreign bundle is not authorized merely because its fields agree. Prove foreign exclusion through real scoped loading/caller assertions.

## Fail-closed display projection

A private pure helper may receive full claim, original citation and loaded sources. It returns eligible display metadata or unavailable; it performs no I/O, body hashing, authority-validator call or event. Validate relevant maps/lists/nonblank IDs/hash before comparing; no nil==nil success.

Require ALL:

1. Exactly one valid context ref for the cited source; its revision equals the citation revision. Duplicate context source IDs, including identical duplicate refs, are ambiguous and refuse enrichment.
2. Exactly one loaded source with that full source ID; duplicate matching DTOs refuse enrichment. Source `status == "active"`; exposed latest revision is a map.
3. `citation.source_id == ref.source_id == source.id == revision.source_id`.
4. `citation.revision_id == ref.revision_id == source.latest_revision_id == revision.id`.
5. Valid exact `ref.body_hash == revision.body_hash`.
6. Nonblank actual `claim.workspace_id == source.workspace_id == revision.workspace_id`, as defensive consistency ONLY; authenticated scoped callers remain authority.

Malformed relevant values or any mismatch produce whole-pin fallback. Identical hashes on different source/revision identities cannot select a match. Repeated original citations remain separate. The new projection must tolerate malformed enrichment inputs; it does not claim to repair every pre-existing malformed report envelope.

## One shared safe URL policy

Freeze Guardrail's conservative policy for BOTH picker and report, factored within the existing component:

- Binary, valid UTF8, **1–2048 BYTES**, not character count. Reject raw Unicode whitespace/separators, control/format characters, backslash and malformed percent escapes. No trimming, repair or truncation.
- Explicit absolute HTTP(S) authority, successful exception-safe parse, no userinfo. Normalize scheme only for comparison; preserve accepted URL bytes.
- Nonempty syntactically valid ASCII DNS host (localhost/punycode included), valid IPv4 or bracketed valid IPv6. Reject encoded/Unicode/empty host, broken brackets/delimiters and invalid numeric addresses. No DNS/network lookup.
- Optional explicit port is digits in1–65535; absent port allowed. Empty/signed/text/out-of-range ports refuse.
- Reject percent-encoded C0/DEL or backslash; otherwise well-formed path/query/fragment escapes may remain encoded.
- Refusal yields no anchor and no unsafe raw URL in HTML/attributes/errors. This is navigation hygiene, not destination trust/freshness.

Use escaped HEEx; no `raw`, preview, prefetch or automatic opening. Ordinary anchor: `target="_blank" rel="noopener noreferrer"`, with no Phoenix click/navigation event or new hook. Visible/accessibility name includes **“Open stored source link (opens in a new tab)”**. Distinguish citations with report-id/finding/excerpt index association or accessible name; do not add Tab stops to static metadata.

## Shared hierarchy and fallback copy

Keep current report/uncertainty/goal/resolution order. Within each citation: unchanged excerpt → existing full source/revision/UTF8 span → secondary metadata OUTSIDE the quoted source words. Retain exclusive-end byte meaning, full selectable IDs/hashes and existing disclosures; no ellipsis, line clamp or tooltip-only authority.

| State | Added UI |
|---|---|
| Match, nonblank usable title | **Current source name (may have changed):** escaped current title |
| Match, unavailable title | **Current source name unavailable.** Date/link remain independent |
| Match, valid capture timestamp | **Captured at:** exact stored timestamp or equivalent display preserving timezone; valid `time` element is suitable |
| Match, invalid/absent date | **Capture date unavailable.** Never substitute update/current time |
| Match, safe stored URL | New-tab link plus **This link was stored with the capture. Its destination may have changed.** Explanation may appear once when clearly applying to all report links |
| Match, unsafe/absent URL | **Source link unavailable.** No anchor/raw rejected value |
| Any whole-pin mismatch/unavailable state | **Pinned capture details unavailable or changed. The original excerpt and pin are retained.** Omit ALL added name/date/link |

Current-name-only change with unchanged revision still displays the CURRENT qualifier. Capture date is not policy chronology. Metadata does not certify support, completeness or eligibility.

## Existing state contract — no new navigation behavior

Dirty **Review exact revision in Evidence** continuation stays disabled and forged `company_navigate` refuses Save/discard feedback. Existing dirty selection/start/clear/open fences remain. Ordinary portal-tab departure STILL clears analysis and rotates/reset generations. No global navigation block/modal and no draft preservation across departure/auth loss/privacy reset/remount.

A plain source anchor opens another browser tab without an app event. Returning to the still-mounted originating tab should retain its report/disclosure/draft; root must observe actual focus/return. No restoration hook. New metadata derives from current assigns; no new persistent cache. External fixture edits require supported reload; immediate cross-writer purge invalidation remains out of scope.

## Root evidence and handoff

Minimum meaningful checks, all UNEXECUTED here:

1. Focused semantic render matrix: exact full match; mutable name; independent missing name/date/URL; old revision; wrong source/latest pointer/revision-source/hash/workspace; absent/duplicate/malformed refs or matching DTOs; same hash/different identities; empty default sources; escaped hostile title/snippet. Mismatches retain original excerpt/pins and omit added metadata.
2. Same URL policy in picker/report: valid HTTP/HTTPS/localhost/valid port;2048/2049 UTF8-byte boundary with multibyte distinction; invalidUTF8, prohibited characters/encoded controls, userinfo, unsafe/relative schemes, malformed host/percent/brackets and invalid ports. No raw unsafe echo.
3. BOTH actual review locations use same admitted synthetic history+goal report. Compare exact immutable projections before/after view/disclosure/link/return; zero selection/inference/decision/artifact mutation. Cross-workspace exclusion uses authenticated scoped caller tests. Deliberate disposable fixture rename/recapture/revoke phases are measured separately, followed by supported reload.
4. Preserve dirty continuation refusal, ordinary-departure reset and auth/privacy/remount/queued-event fences. New-tab return preserves only a still-mounted draft. Measure unavailable-model status rather than infer it; viewing needs no inference, while approved current-data build/export remains model-independent and stale data refuses.
5. BOTH locations:320 AND390 CSS px × actual100 AND200% browser zoom; long authority values, link/fallback, full selectable text, no unintended overflow/clipping, visible focus, logical Tab order, keyboard synthetic-local GET new-tab and return. Restore prior browser state. Existing report wrapping first; root may extend picker-only link target/underline styling with ONE report-scoped selector if evidence warrants it.
6. Connected edited/rejected/exact Evidence approval → separate exact plan approval → deterministic build/export noninterference remains. Root runs focused/canonical checks against final frozen source, preserves failures and separate identity/repetition/Docker accounting. No generated instructions execute.

Guardrail source-read seven prepared helpers and reused fixture without execution; audit binds exact versions and qualifications. Root retains fresh disposable workspace/phase-file checks, actual release/workspace/listener identity, quiescent sequential (not atomic) projection comparisons, completed-operation observations beyond command acknowledgment, and measured model availability. Helper source review is not runtime success.

No demonstrated adviser source blocker. Root's remaining action is full-read this interface/completion and release the TWO concrete author lanes within existing authorization. No additional user permission gate.

Preserve main09 PID68553/8865 standard MCPoff/no probe, all09 frozen evidence and historical01 observation-only. Domain/schema/auth/MCP/model/Guide/stale-recovery/historical-query changes excluded. Prior external cache/export/history-hash limits, direct mutation/boundary gaps, existing Dialyzer diagnostics and unproven real-company/model/coherent obligations/owner tasks/live connectors/managed agents/Linux/portable authority/WCAG/speech/novice/log/longitudinal outcomes remain. Earlier missing drafts add no new gate; Guardrail's own amended bytes were actually preserved in its audit. All10/11/08 dissent remains recorded in ADR/handoff.
