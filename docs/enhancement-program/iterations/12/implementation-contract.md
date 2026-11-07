# Iteration 12 implementation and verification contract

Status: **ready for root acceptance; implementation unstarted by this conductor**. This is normal coordination within existing local authorization, not a user permission request. ADR12 is authoritative: `decision.md`, SHA256 `60e82bdfe70323f25cd06a24386764645540d72c28e84b577f980b5640716656`. Root must full-read/accept the ADR and this concrete ownership/interface before dispatching source authors. Root alone owns execution, board/state/count and runtime identity. The accepted count remains 11/50.

## Selected benefit and limits

An authenticated operator can select an existing captured connection, a saved project and assigned saved goal; inspect ≤25 metadata rows/page and one exact ≤4,096-byte UTF-8 passage/context; compare exploratory evidence with a matching existing recommendation's original support/conflict/unknown findings; and continue deliberate correction/rejection, exact claim approval, separate plan approval, corrected actual export and representative assessment.

Connection inspection is existing **workspace read scope**, distinct from project assignment and analysis/plan eligibility. No search hit becomes semantic support/conflict. No candidate passage is inserted into a citation, v1 analysis origin, claim or plan by browsing/continuing. Show the original report's 2–4 analyzed sources separately from additional inspected evidence. Say plainly that whole-corpus model analysis has not occurred and the 2–4-source model-analysis limit remains. No unbacked corpus-analysis/resume/Graphiti control, invented capture/index percentage or silent model substitution.

Normal Portal mount, Company entry/navigation/refresh and return from review must be bounded too. A dedicated inspector with an eager 5,000-body parent load fails this benefit. Counts come from actual captured records; unknown discovery/semantic coverage stays unknown. Historical dates/status have explicit known metadata semantics or display unknown.

## Exactly three source owners

| Owner | Exclusive product/test files | Deliverable and handoff |
|---|---|---|
| Root | `lib/harness_forge_web/router.ex`; new `live/corpus_review_live.ex`; shared `live/portal_live.ex`; `components/company_panel.ex`; root-owned flow tests/fixtures and necessary existing Portal/Company flow tests; additive measured index migration only if needed; shared JS only if required | Authenticated route/state/events, normal-entry metadata migration, compatibility integration, all runtime/checks/build/install/browser/DB/process/Git and board/count. Accept A's DTO contract before B consumes it. |
| Principal A, `principal-elixir-engineer` | New `lib/harness_forge/company/corpus_review.ex`; new `test/harness_forge/company/corpus_review_test.exs`; bounded facade additions in `lib/harness_forge/evidence.ex` and directly corresponding domain tests; minimal pure retrieval helper extraction only if explicitly needed | Strict authorized metadata/choices/passage/report reads, cursor/token validation and domain tests. Preserve non-UI legacy APIs/authority. A fixes A's findings. |
| Principal B, `principal-elixir-engineer` | New `lib/harness_forge_web/components/company/corpus_review.ex`; component tests; necessary summary-compatible presentation changes in `components/company/{analysis,catalog}.ex` and corresponding component/metadata tests; scoped `assets/css/app.css` | Stateless HEEx, visible scope/status/unknowns, pagination/passage/report view, accessible controls/focus targets and summary-aware legacy presentation. B fixes B's findings. |

No fourth source/test author, including corrections or fixture writers. Implementation orchestrator, guardrail, impediment remover and expert UI/UX adviser own reports only. Five independent validators own reports, not product/tests. Root assigns actual A/B sessions and publishes file ownership before edits. Existing planners are completed and never become accidental source authors. Preserve everyone else's work. The ADR's suggested patch line count is advisory; it is not a release condition or an excuse to omit correctness/tests. Estimate 32–56 source-owner person-hours (ADR's rough 4–7 engineer-days), then independent verification; actual duration is unmeasured.

## Caller and domain interface

The ADR's operation names and semantics are frozen. The following explicit server-context parameter clarifies its shorthand signatures; root/A agree exact arity before source edits, then B consumes only DTOs. Every operation returns `{:ok, dto}` or a bounded existing/static error tuple. User maps stay string-keyed and strict; never convert user values to atoms/modules.

`caller` is the existing assessment-attempt-style **server-only keyword options** pattern, created by root after actual `OperatorSession.valid?/1`, never accepted from params: `[authorize: zero_arity_boolean_function, session_fingerprint: Contracts.digest(operator_auth), view_generation: 32_lowercase_hex_string, reset_token: nonnegative_integer]`. It is not serialized to the browser. Reuse the pattern in `Company.AssessmentAttempts.options/1,authorize/1` and root's existing assessment caller, without reusing assessment token salts or authority. The closure rechecks the actual current operator auth on every domain read; domain also derives `Evidence.Store.workspace()` server-side, compares all token bindings and checks the existing privacy fence. User DTO/attrs remain strict string-keyed maps; fixed internal option atoms are never derived from user input. No client workspace/group ID, boolean `authorized` field or `:all` escape hatch. Scope/cursor tokens use separate versioned Phoenix.Token salts and600-second maximum age, existing application signing secret, with no secret logged or new credential input.

| Operation | Input / result contract |
|---|---|
| `choices(attrs, caller)` | Strict `%{"kind" => "connection" / "project" / "goal" / "recommendation", "project_id" => UUID-or-empty, "goal_id" => UUID-or-empty, "cursor" => token-or-nil}`;≤25 safe ID/title summaries plus next cursor. Goal requires current profile/project assignment; recommendation requires matching project/goal. No directories, connection config, credentials or source bodies. |
| `open_scope(attrs, caller)` | Exactly connection ID, project ID, goal ID/content hash; validate active workspace connection, current profile/project and assigned goal. Return server-minted scope token plus safe DTO. Bind workspace/session/view/reset, profile/project hashes, goal hash and connection identity/config digest/status. Project context does not widen membership. |
| `page(token, attrs, caller)` | Query ≤256 Unicode characters/1,024 bytes and ≤8 literal tokens; signed query/scope-bound cursor with short expiry. Scope predicates precede FTS/LIMIT; stable source-ID keyset query fetches at most26 metadata rows, returns at most25 plus continuation. Counts/rows share a read transaction. Cursor describes a live page, not an immutable full-corpus snapshot. |
| `passage(token, attrs, caller)` | Exact source/revision/hash/start byte; revalidate selected connection, current source and privacy/document scope. Return one ≤4,096-byte valid UTF-8 window including quote/context, exact exclusive byte bounds, body length, truncation and bounded next-window position. Use bounded SQLite slicing with only small boundary-validation extra bytes; never load a whole corpus body into a socket. Invalid boundary/stale pin refuses; no silent repair. |
| `recommendation(token, attrs, caller)` | Exact claim ID/hash; matching project/goal and existing `Analysis.validate_origin/2`; return only the eligible original report plus bounded metadata for its existing refs. Original kinds supply classifications. Refuse stale/foreign/revoked reports; no historical revoked snippets. Existing bounded v1 validation remains authoritative. |
| `source_page(attrs, caller)` | Reuse the same SQL/projection for bounded legacy Portal source browsing/search under existing workspace-operator authority. It is not a company analysis scope token. Do not call hydrated `Evidence.list_sources/0` or `Evidence.search/1` then page/filter. |
| `summary_refs(server_refs, caller)` | Metadata only for currently edited profile/project's existing≤100 assignments each, current legacy≤4 analysis pins and opened report's bounded refs; preserve separate set bounds. These IDs come from saved/server state, not an unbounded client array. Do not enumerate every project's source assignments. |

Metadata DTO: source/connection ID, safe title, current revision ID/hash, captured/source-updated dates, active eligibility and actual body byte length; no `body` or hidden full source. Safe original URLs are validated/escaped as in current metadata rendering. Effective/event dates/documentary status are shown only when explicitly captured with known meaning. Unknown never defaults to approved/current policy.

### Shared DTO shapes (A produces; root/B consume)

All maps below use string keys. Root/A can omit inapplicable optional fields, but must not rename required keys independently. `nil` means unavailable/unknown, not empty evidence or approval.

```elixir
# source summary: compatible with existing UI reference pinning, never a body DTO
%{"id" => source_uuid, "workspace_id" => server_workspace,
  "connection_id" => connection_uuid, "provider" => provider,
  "external_id" => captured_external_id, "title" => title,
  "status" => stored_source_status, "eligible" => boolean,
  "latest_revision" => nil_or_revision_summary}
# revision_summary (no "body" key)
%{"id" => revision_uuid, "workspace_id" => server_workspace,
  "source_id" => source_uuid, "revision" => integer,
  "body_hash" => sha256, "body_bytes" => nonnegative_integer,
  "captured_at" => iso8601, "source_updated_at" => string_or_nil,
  "source_url" => safe_url_or_nil,
  "metadata" => explicitly_whitelisted_historical_metadata}

# choices return; choice rows have id/title and the necessary project/goal hash
%{"rows" => choice_summaries, "next_cursor" => token_or_nil}
# scope-open return: token is opaque; DTO exposes no signing/session/config secret
%{"token" => scope_token, "scope" => scope_summary}
# scope_summary includes the selected connection's id/name/provider and actual
# sync_state/sync_complete/last_synced_at; selected project id/name/content_hash;
# selected goal id/title/owner/acceptance/content_hash; assignment counts separately.

# page: rows are source summaries, never full sources; counts describe local facts
%{"scope" => scope_summary,
  "counts" => %{"captured" => integer, "current" => integer,
    "unavailable" => integer, "matches" => integer_or_nil,
    "discovery_total" => nil, "semantic_coverage" => "unknown"},
  "rows" => source_summaries, "next_cursor" => token_or_nil}

# passage: text is exact bytes [start_byte,end_byte), total <=4096 bytes
%{"source" => source_summary, "revision_id" => revision_uuid,
  "body_hash" => sha256, "start_byte" => integer, "end_byte" => integer,
  "text" => exact_utf8_window, "body_bytes" => integer,
  "truncated_before" => boolean, "truncated_after" => boolean,
  "next_start_byte" => integer_or_nil}

# matching recommendation: report/guidance retain existing field meanings
%{"claim_id" => claim_uuid, "revision_hash" => sha256,
  "status" => existing_current_status, "superseded" => false, "eligible" => true,
  "project_id" => project_uuid, "goal_id" => goal_uuid,
  "goal_content_hash" => sha256, "report" => original_validated_report,
  "guidance" => current_guidance, "review_resolution" => string_or_nil,
  "analyzed_sources" => existing_bounded_source_ref_summaries,
  "outside_inspection_connection" => boolean}
```

`summary_refs(server_refs, caller)` accepts `%{"profile_ids" => saved_ids_max100, "project_ids" => saved_ids_max100, "analysis_refs" => exact_refs_max4, "recommendation_refs" => exact_refs_max4, "consent_ids" => saved_ids_max100}` with absent groups treated as empty; return `%{"sources" => metadata_summaries, "unavailable_ids" => saved_ids_without_current_metadata}`. Deduplicate reads, preserve original saved sets separately, validate each group's bound and never enumerate all projects. Reference groups contain source/revision/body-hash pins; ID groups are saved IDs. Unavailable selected IDs remain visible as unavailable selections until explicitly removed; they cannot silently disappear on unrelated Save. Normal source pages accept only validated optional connection ID, query and cursor; no browser-supplied workspace ID.

Historical metadata is a documented whitelist for explicitly stored documentary/effective/event fields. Arbitrary revision metadata, connection configuration and local connection directory are not passed through. B renders unknown when no whitelisted semantic field exists. A/root agree this projection before B implementation. Existing current-source readiness uses `eligible` plus exact revision metadata and `body_bytes`, and never fabricates a `body` field to appease old presentation code.

Return safe refusals for empty/foreign/expired scope, wrong session/generation, stale/foreign cursor, invalid UTF-8 offset, source/connection revocation, changed connector scope and incomplete privacy operation. Do not leak forbidden snippets in errors. No lookup/search/page/open action writes provider ledgers, citations, claims, decisions, memberships, plans or assessments. No inference call is introduced.

## Root event/state and compatibility seams

`CorpusReviewLive` owns scope/query/page/cursor stack/open passage/selected claim/generation/error/notice. Use the ADR's `corpus_scope_change/open`, `corpus_search`, page previous/next, passage open/next/close, recommendation open, continue-review and refresh events. Reuse the actual authenticated router/session pipeline. Every event validates session and view generation before reads; async replies also bind request/scope/query. No raw query parameter establishes authority.

Clear passage/report state on reset, revocation, scope change and failed freshness validation. Subscribe to the actual existing privacy-reset mechanism; root verifies direct-route behavior as well as Portal. Preserve safe query/goal choices after harmless paging refusal, but remove forbidden text. Explicit refresh mints fresh handles; it never repins/approves existing claims. Destination review keeps its existing dirty-draft/departure guards. An inspector has no unsaved guidance editor to bypass those guards.

Replace the normal Portal source-list loader with bounded metadata and remove preloaded bodies from closed source disclosures. Source-open and search use the same authorized bounded read facade. Legacy model-propose actions pass exact identities and load needed full data inside the existing domain operation. Existing ≤4-source analysis still reloads/revalidates its bodies at dispatch; v1 input/origin/consent/approval/export contracts do not change. Audit indirect helper paths as well as direct loader names; a list/guide/readiness helper must not reintroduce corpus-sized source hydration. Existing necessary exact bounded domain authority checks do not permit corpus-wide UI body loads.

Preserve saved source/consent selection sets across metadata pages. Opening a page or saving unrelated fields cannot deselect off-page assignments/consent. An explicit removal affects only the intended saved selection; newly visible unchecked rows are not automatically added. Preserve the existing100-ID cap and legacy public CLI/MCP/list semantics. Correct tests in their existing source-owner lanes rather than weakening assertions. Remaining general claim/goal scalability is unqualified; this scope specifically removes eager corpus-source body hydration from the required entry paths.

## Root-run verification matrix

Before implementation, root freezes a public synthetic corpus/oracle with500 and5,000 captured sources under a local fixture connection, saved assigned goal, expected policy/contrary/irrelevant passages and exact spans. Include dated policy, incident, exception, later decision, unapproved discussion, long multibyte content, off-page selections and revoked/foreign canaries. Use bounded supported fixture/domain capture; this is not proof that the500-file/16MiB directory importer has become resumable. Keep one existing valid four-source report for connected regression; scripted responses prove mechanics only.

| Proof | Required observable result / evidence |
|---|---|
| Normal entry and boundedness | Authenticate normally; Portal mount, Company navigation/reload, inspector direct entry and review return use ≤25 metadata rows and lazy bounded bodies. Instrument real query/call paths, rows, payload/HTML/diff bytes and memory at500/5,000; no corpus-sized full source DTO load hidden in a parent/helper/disclosure. Record actual p50/p95;≤1,000ms page latency is a design target, not an inherited pass. |
| User success | Select captured connection/project/assigned goal, page beyond the first page, explicitly query expected policy and contrary incident, open exact ≤4KiB UTF-8 context, recognize unknown capture coverage and candidate-versus-original-finding distinction. Existing matching report shows its own support/conflict/unknown and exact analyzed scope. |
| Read-only/authority negative | Freeze DB/artifact projections after authentication. Search/page/open create no provider attempt or citation/claim/decision/membership/plan mutation. Empty/foreign scope, wrong session/generation, expired/cross-query cursor, unassigned goal and tampered IDs refuse. Browsing an unassigned same-workspace connection never makes its sources eligible for project analysis/build/export. |
| Passage/report negative | Wrong revision/hash/offset, multibyte boundary, changed connector document scope, revoked source/connection, stale report and pending failed purge serve no forbidden text. Zero matches is not “no conflict”; no inferred status/date or support/conflict label appears on raw FTS hits. |
| Selection compatibility | Place saved project/profile assignments and model consent IDs outside the visible page; paginate and save unrelated fields, then assert exact sets preserved. Explicit removals/additions work only as selected; no cap increase or hidden consent broadening. Existing small analysis/model-propose/Chat/catalogue flows still work. |
| Recovery | Recapture while a passage is open: old pin refuses/clears; explicit refresh/new open succeeds. Supported privacy reset and failed cleanup clear mounted bodies/reports and keep later reads fenced; successful cleanup cannot revive old approvals. Expired cursor starts a fresh live page with notice. Late events cannot restore removed text. Harmless failure preserves safe query/goal choice. |
| Connected outcome | Continue to existing exact review, reject unsafe guidance, save correction/resolution, separately approve exact claim and plan, build and verify corrected bytes/rejected-text absence in actual target export files. Reopen representative assessment with operator-report/unverified-truth qualification. Additional preview was not silently added to machine-tracked origin. Recapture recovery creates explicitly fresh eligible records as required; old history stays immutable. No generated harness runs on host. |
| Changed UI | Root records actual authenticated keyboard selector/page/open/close/continue/recovery, visible focus and status/error announcements, escaped malicious corpus text,320/390 CSS widths at100/200% zoom. Screenshots identify actual browser surface; domain/protocol tests are not relabelled native browser proof. No full WCAG/novice claim. |
| Regression/gates | Root runs owned domain/component/flow tests plus relevant analysis/output/metadata, builder, privacy/snapshot, consent/budget, claim/plan/export and assessment checks; then canonical `mix test`, formatting/compiler and existing quality gates. Preserve exact failures/exit codes and baseline diagnostics. Reviewers request checks; root executes. |

Record evidence beneath `tmp/enhancement-program/12/`; freeze the candidate and raw evidence for five independent validators. Review-loop corrections return to root/A/B and the same reviewer. No broadened/repeated checks after clean gates without new changes or unresolved concern. Preserve CODE-11-02/WEB-11-01/WEB-11-02 and existing warnings unless actually fixed and verified.

## Following functionality and closure

Iteration13's user outcome/minimum proof is binding, while exact scope/schema/modules/backend remain unselected until iteration12 is verified, all five NEW retrospectives/full handoff are consumed and fresh16Sol/NEW Astra select. It must connect bounded resumable corpus capture/membership/pagination and original passages through versioned cited/uncited/transitive origins, supporting/contrary evidence, deliberate correction/rejection/exact approvals, actual corrected exports and representative evaluation. Compare matched FTS5/candidate evidence and critical misses, exact citations, task correctness, actual latency/cost where measured. Do not substitute another isolated polish round.

Reuse pinned Graphiti0.31.2@d72407dcedac911e1be9fc15b55e8c05a3efcc36, its actual Jev/runtime/extraction/temporal/hybrid components via bounded Python; keep Elixir/revisioned SQLite/FTS5 authority. Preserve nonempty server scope before retrieval/dispatch, independently consented/metered stages/retries/cancel/ambiguous usage, transitive dependencies/new contradictions, tombstone-before-removal and deny serving through failed summary rebuild. Native Jev's two dedupe routes do not replace generative extraction. Do not port the engine, stack frameworks, default deprecated Kuzu, raise unbounded caps or treat51 offline mock passes as installed/backend/semantic/million-file qualification. No paid pilot/private imports/new model installation/publication/access expansion/host generated-code execution.

Root proceeds after accepting this concrete contract; implementation/advisory roles are not yet dispatched by this conductor. Five independent validation originals, actual accepted local install/verification, exactly five **further NEW** independent retrospectives, and root/conductor entire reads/full handoff precede counting12/50. Board/state/count remain root-only. If bounded normal entry, scope isolation, removed-text protection or truthful provenance cannot be met, return the failing evidence to root/`staff-tech-lead`; do not silently expand scope or release placeholders.
