# Iteration 12 implementation coordination report

This is the implementation orchestrator's report, not the canonical board or state/count ledger. Root accepted the entire22,548-byte contract (`69c76f7d845c514901cacdd1a3bb4db09d6206d907a92f913251ffec34524c71`) after full reading, and owns its separate immutable acceptance record. Original ADR/contract stay unchanged. This same conductor continues as the implementation orchestrator; no extra planning or orchestration agent was added.

| Owner | Status and responsibility | Evidence / blocker / next step |
|---|---|---|
| Existing root | Integrating; sole execution/board/state/count owner | Owns router, CorpusReviewLive, PortalLive/CompanyPanel/state, integration fixtures/flow tests and all runtime/tests/build/browser/DB/process/Git actions. No author handoff changes this ownership. |
| A `/root/i12_domain` — `principal-elixir-engineer` | First domain candidate implemented; root verification pending | New `company/corpus_review.ex`, owned domain test and additive Evidence delegates reported. No A runtime/compile/format/tests. Next: root-run `mix test test/harness_forge/company/corpus_review_test.exs`; A fixes A findings. |
| B `/root/i12_ui` — `principal-elixir-engineer` | First presentation candidate implemented; root verification pending | New stateless component/component tests/Guide metadata tests; owned Analysis/Guide/Catalog/metadata-test/CSS changes reported. No B runtime checks. Root explicitly extended B to minimal Guide metadata compatibility; no fourth author. Next: root format/compile and focused component/Guide/metadata checks. |
| `/root/i12_impediments` — separate root-dispatched adviser | Sealed six-item report; conductor full-read | `implementation-impediments.md` plus32-file read audit. No external blocker/dependency/permission; existing root/A/B own every remedy. These are pre-implementation prerequisites, not verified candidate failures or fixes. |
| `/root/i12_ux_adviser` — `principal-ui-ux-engineer` | Expert UX advice complete, report-only | `ux-implementation-advice.md`,7,369B, SHA256 `1a3230c1a446b572eccb2de58bf5dbc3cfded5ab5f53ee7d508d1f0b6d13fcd6`; conductor full-read. Root/B already received actionable points; actual changed-UI verification pending. |
| This conductor/orchestrator | Reports/coordination only | No product/test/config edits or runtime/test/browser/DB/process/Git execution. Track ownership/interfaces and ask root for actual checks when ready; root alone updates canonical progress. |

## Agreed A interface before edits

A sent root and conductor: `choices/2`, `open_scope/2`, `page/3`, `passage/3`, `recommendation/3`, `source_page/2`, `summary_refs/2`; results `{:ok, string-keyed map}` or `{:error, bounded static atom}`. Server-only options are exactly authorize closure/session fingerprint/view generation/reset token from the accepted assessment-style pattern. Client string maps never establish auth or workspace.

`open_scope`: connection/project/goal/goal hash. `page`: query and optional cursor. `passage`: exact source/revision/body hash/start byte integer. `recommendation`: claim ID/hash. `source_page`: optional connection/query/cursor. `choices`: kind and applicable project/goal/cursor. `summary_refs`: separate saved selection groups as in contract; unavailable/off-page IDs are preserved until explicit removal.

Metadata queries fetch26/return≤25, source-ID keyset, scope before FTS and≤8 literal tokens. Optional `match_start_byte` is a SQL byte-prefix projection or nil where no literal position exists; no invented offset. Known historical whitelist is `document_status`, `effective_at`, `event_at`; absent fields remain unknown. Body-free source/latest-revision, page/count, exact≤4KiB passage and report DTOs retain accepted required keys. A reported no runtime actions.

Root accepted B's stateless component call `review(state: map, generation: string)`: internal state has fixed atom keys; DTOs and selection use string keys. Internal choices are four plural-atom kind maps; root maps those fixed kinds to A's singular string-kind attrs. Root added `corpus_choices_next` for bounded choice pagination and `corpus_generation` as the event envelope; scope/search inputs are nested params and button pins are scalar. This is an integration clarification, not new user authority. Root/A/B were all sent the same interface; no additional preparation gate was added.

B's ready handoff confirms required internal state keys `:choices`, `:selected_choices`, `:selection`, `:scope`, `:page`, `:query`, `:passage`, `:recommendation`, `:previous?`, `:error`, `:notice`; string-keyed DTOs remain unchanged. Every event carries `corpus_generation`; selected pins are scalar. Fixed focus IDs: `corpus-results`, `corpus-passage`, `corpus-error`, `corpus-notice`. Requested root-run focused check after root format/compile: `mix test test/harness_forge_web/corpus_review_component_test.exs test/harness_forge_web/company_guide_metadata_test.exs test/harness_forge_web/company_analysis_metadata_test.exs`. This is a requested command, not an execution result. Reuse root's existing check if already running.

A's first candidate reports no API/DTO change except a root-approved per-row `passage_token` on normal `source_page` rows for Portal lazy open. This is recorded as A's reported root approval; root owns the immutable acceptance and actual security checks. Scoped inspector passage calls remain unchanged. A's smallest requested check is `mix test test/harness_forge/company/corpus_review_test.exs`. Both lane requests are with root; neither author nor conductor executed them. First-candidate source readiness does not imply format/compiler/test/review/browser/install acceptance.

## Root check checkpoint 01–03

Root reported check01 formatting PASS and check02 test-environment warnings-as-errors compilation PASS. Check03 focused batch then failed test compilation after two dots: B's `defp render/1` in `corpus_review_component_test.exs:385` conflicts with imported `Phoenix.LiveViewTest.render/1`. Root requested the smallest helper rename from the **same B**. No focused-suite/domain PASS or full execution is inferred. Root continues its shared integration/flow-test authoring; no fourth writer or additional planning/debug branch was introduced. Raw command/log identity remains root-owned and will be bound in the candidate packet.

### Held domain handoff and root checkpoint07

Conductor full-read A's `tmp/enhancement-program/12/author-domain/handoff.md`. A reports its product/test files held on root's instruction, with complete APIs/DTO/output hashes in the companion read audit. The per-row Portal token is a distinct `kind=source_preview`, bound to source/revision/hash/connection and unable to authorize company paging/report reads; root retains it server-side. Source metadata and optional match byte position are projected after LIMIT26; a nil match offset is explicitly a first-window preview. A's report describes bounded BLOB slicing, original registry scope validation and domain-origin validation, but these implementation claims are not independently accepted by this orchestrator. No A runtime actions occurred.

A's historical account of run05 (157 tests, one B assertion failure, no observed A failure) is retained as its reported root observation; final A SQL type/host guards may postdate05, so it is not evidence for held current hashes.

Root directly reports run07: **163 tests, four failures**; A/B tests had no observed failures, with B's prior test issues corrected. Three failures are root-authored flow-test transport (hidden hash forging through the wrong DOM transport, missing fetched session on recycled unauthenticated conn). One is a **real remaining indirect full-body list** in `Chat.Snapshot.catalog` via Portal's `chat_catalog`. Root exclusively extends its own lane to `lib/harness_forge/chat/snapshot.ex` aggregate captured-metadata counts; legacy Chat exact-source validation stays intact. Root also corrects its own test transport. This is the accepted indirect-helper boundedness seam, not a fourth writer or scope expansion. Both A/B were told to hold stable unless root returns specific corrections. Full focused/candidate PASS remains unclaimed; root will freeze the corrected source before independent QA.

### Root checkpoints09/11 and correction rerun13

Root reports run09:190 tests/one failure, confined to root's unauthenticated fixture transport; root changed it to a fresh `build_conn`. Broader run11:63 tests/four failures. One old Company test expected stale historical report rendering, which now deliberately refuses as a **current** Company review under ADR12; the changed test retains immutable Evidence history as read-only baseline. This is not a claim that all historical data is removed or that private revoked snippets may remain in current review.

Three privacy counter failures exposed an actual double reset. Root corrected production behavior with `:corpus_cache_reset` to clear body/report and sensitive Company generation at privacy start without a full DB reload/double completion counter; existing `:company_cache_reset` completion remains, including failed-privacy fence broadcasts. This is root's existing-channel/state lane, not a new bus/service or another author. Correction rerun13 was running in root's single exec session78319 at its report. This orchestrator does not attach a second waiter, execute tests or infer its result. No QA/native/full-suite PASS yet.

Root subsequently reports run13 **PASS:63 tests/zero failures,14.7 seconds**, log SHA256 `58c118435da53c126d137cee7348731722a7f04c793169f4ea92fb27af2ce18f`. This is exact scoped historical execution evidence, not current full-suite/native/scale acceptance. Root is adding missing actual project off-page Save/explicit-remove assertions and inspector→current-review redirect regression within its existing flow-test lane, then rerunning relevant checks/canonical gates. A/B remain stable. Root plans actual500/5,000 metadata/normal-entry measurement and native UI evidence before the frozen QA packet.

Root explicitly authorizes this orchestrator to coordinate exactly five **NEW** independent validators only after receiving that frozen source/evidence packet. None is spawned now. The validators remain code/security/web/API/UIUX report-only roles; root alone executes any requested follow-up, and root/A/B alone correct source/tests. Full independent QA, local install, five further NEW retrospectives and root's full handoff/count remain outstanding.

## Current controls and next handoff

Exactly root + A + B are product/test authors, including all corrections. Expert UI/UX, impediments and independent validators remain report-only. Do not create a fourth author for helpers, fixtures, guide compatibility or tests. Preserve other authors' edits.

Root's pre-edit oracle is `tmp/enhancement-program/12/oracle/inspection-oracle.json`, SHA256 `105dc696b6a920fbb25f096b1d6bb851511be1a7edf10323277017c49665c506`: eight corpus fixtures,500/5,000 stages, normal-entry/passage/off-page/privacy/export expectations. This report binds root's oracle; it does not claim independent execution or rederivation.

Remaining integration checks: normal Portal entry must avoid corpus-sized source-body hydration, including indirect consumers; off-page saved assignments/consent must survive Save; existing v1 analysis authority stays separate from connection inspection; arbitrary FTS hits have no semantic support/conflict label; source/report revocation and failed purge clear bodies and refuse stale events. Root runs positive/refusal/recovery, source-owner tests, actual connected export/assessment and required gates. Independent review/validation and five further NEW retrospectives/full handoff still precede count.

UX advice retains two concrete compatibility checks: the standalone wrapper must inherit existing Company typography/44px-target tokens, and distinct cited-source count must remain separate from the full analyzed-input count derived from validated context refs. Fixed focus targets, close-return focus, unknown capture coverage and candidate/original labeling are implementation advice, not independently verified results. The adviser audit is `tmp/enhancement-program/12/ux-read-audit.json`, SHA256 `2bac4d3debfa0a1fb0e9a618f7c9fc74945df4efa5acbec88108198f1bfe9e96`.

## Impediment routing (all unverified until root checks)

| Finding | Existing owner / concrete verification obligation |
|---|---|
| 1 normal-entry list/search body hydration | A supplies shared bounded projection; root replaces Portal loader/search and lazy source-open. Verify actual mount/navigation/reload at500/5,000, not visible-row count alone. |
| 2 metadata readiness and off-page scope | B owns Analysis+Guide predicates; root supplies current-edit saved refs; A owns DTO. B's focused candidate includes Guide/metadata checks, pending root execution. |
| 3 off-page assignments and consent | Root owns selected-set merging/revalidation, B controls/selection summaries. Verify explicit toggle/remove/save and untouched off-page IDs for profile/project/consent. |
| 4 report destination authority | A validates current original report; root revalidates destination and preserves dirty guard; B preserves original finding labels and candidate distinction. Hash/kind-only navigation is insufficient. |
| 5 failed-purge mounted text | A gates sensitive reads; root clears/notifies at privacy start/failure/success, rejects stale events and clears before auth halt. Verify failed cleanup and explicit fresh recovery. |
| 6 cursor/passage contract | A owns scope-before-LIMIT keyset/literal/bounded UTF-8 slice; root binds actual auth/session/view; B only renders DTO. Legacy hydrated APIs remain for non-UI compatibility. |

Full report: `review/implementation-impediments.md`; audit: `tmp/enhancement-program/12/impediment-read-audit.json`. No source/test/runtime action was performed by that adviser or this orchestrator.

## Independent QA originals sealed and released

Root released exactly five NEW report-only validators against immutable `qa-packet-01.json` (SHA256 `2e505cc4d841b4b6be027cf749435ab3907d7799da86099398bde8a23c91314c`). Actual roles were Principal Code Reviewer, Principal Security Auditor, Principal Web QA (Playwright), Principal API QA (curl / HTTPie), and Principal UI/UX Engineer; each used a fresh `fork_turns=none` session with inherited default model. No sixth validator, peer-original reading before sealing, source edits or reviewer runtime occurred.

All five originals (28,546 bytes) were fully read by conductor and root, with byte-identical report/audit copies in `qa-original-copies-01`. The conductor manifest `qa-originals-manifest-01.json` has SHA256 `21e0019f30286125d69c2e9504e1662f93be7063361e328558ba827ddafbcf3f`: 70/70 mandatory input bindings and 286 resolvable fingerprint claims match, with no mismatches. Hash verification and declared read scopes do not claim semantic full reading of all 1,513 frozen source files. Export-relative file names were explicitly resolved within `actual-export-native02`; an initial naive namespace resolution error was corrected without modifying any original. Root independently retained its own original full-read receipt.

| Original | Disposition / existing owner next action |
|---|---|
| Code | No blocker; CODE-12-QA-01 finds whitespace goal seeding can exceed domain literal-token limits. Root selected the smallest correction: blank first-page browse with deliberate search, plus a meaningful punctuated-goal flow regression. Root may edit only after the original-review hold releases. |
| Security | No demonstrated exploit; SEC-12-QA-01 requires combined mounted passage/report privacy-start + failed-cleanup refusal and authentication-clearing proof. Root executes temporary focused probes; A may supply protocol-only fixtures outside held product/test sources. |
| Web | WEB-12-QA-01 requires current native03 delta/resources/responsive/export/history proof. WEB-12-QA-02 requests stale/wrong-hash continuation and incoming exact-review request into a dirty destination proof. Root supplies runtime evidence. |
| API | No substantiated API code defect; API-12-QA-01 requires current candidate03 metadata/identity/refusal/reset/bounded-entry/export proof under the explicit candidate02-to03 reuse contract. |
| UI/UX | Source semantics supported; UX-12-QA-01 requires current candidate03 delta proof, UX-12-QA-02 retains narrow/zoom/native selector qualification, UX-12-QA-03 retains the extra reopen action after search resets a comparison. No blanket WCAG or novice qualification. |

All five received release and direct fleet inventory subsequently showed all five completed; `qa-originals-release-01.json` records that observation. Source correction returns to root/A/B only. Original findings remain immutable; any proof closure or corrected-source review goes to these same five sessions as a scoped, separately sealed addendum. Root reports current native03 responsive/fresh-export/resource work completed, but its final supplemental packet is not yet reviewed here. A measured 320/390 CSS viewport is not a browser zoom proof. Official count remains 11/current12; five further NEW retrospectives and full root handoff remain required before count.
