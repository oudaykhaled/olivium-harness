# Iteration 07 — final independent web QA, frozen03

**BOUNDED PASS: frozen03 source and supplied root-executed QA evidence, including A8 and the changed A9 refusal journey. No unresolved web QA blocker found.** Main installation/preservation and iteration closure remain pending; official progress remains **6/50**. This verdict does not authorize or claim an installation.

Reviewer `/root/i07_conductor/review_web07` is the same independent validator. The original candidate02 report/addendum remains unchanged, SHA256 `e4b4d67a6a82641bb7a873600773373e25b0b4aebcf00ecf475b915b3feef7aa`. No peer07 report was read. I performed only local source/evidence/hash/diff reads, ordinary artifact-image viewing and owned report/audit writes. All tests, builds, Docker, native/browser actions, database observations and process operations below were performed by root; none was run by this reviewer.

## Identity and prior finding closure

I fully read `verification.md` and parsed the complete final packet. Packet SHA256 **`ad50804b139c899db5d427510453a8a415b8b93ba3cd101aa17f4a2764b149c7`** independently matches **156/156 actual file lengths/hashes**. Frozen03 SHA256 **`8651fdc74e283fe737defdf67abe92390752058d5d5a7e9fbcb2993725b3128f`** matches **636/636 actual copied files**. Actual02→03 comparison is628 identical/eight changed/no additions/deletions. I read every changed hunk: three production files and five test files. Presentation, CSS/JS, authentication and reset/stale-form code retain their reviewed bytes.

1. **Opacity finding closed.** Typed route/endpoint/identity-digest accessors keep raw field reads inside CodingTransport and preserve `@opaque`, the exact v2 digest input and route behavior. Dialyzer03 actually exits2 with exactly the two retained `releases.ex:47/121` diagnostics, zero new/ignored/skipped findings. This satisfies the zero-new gate; it is not a clean Dialyzer run.
2. **Owned relay cancellation finding closed.** Frozen `Coding.stop_session/1` verifies actual current-workspace persisted run ownership, independently of transport context. Both direct cleanup and Evaluations cleanup revoke that local capability before validating context/daemon authority. Docker commands still require the original context/profile/identity/labels. Canonical03 passes the actual active-relay regression for unavailable and replaced original daemons: session/relay stop, future authorized HTTP request fails, upstream inference counter/ledger stay empty, no Docker mutation occurs, cancellation/unqualified state and private context remain, and original-daemon retry completes cleanup without converting cancellation to pass. Expanded tests cover missing/corrupt context and refusal to revoke a missing/foreign-owned session.

Retain RED01 as a fixture-premise failure: missing workspace_id prevented reaching the daemon. RED02 actually reaches unavailable-daemon verification and fails on the still-live session; its replaced-ID loop branch was not reached. GREEN01 passes both cases but lacks a complete physical source snapshot, so I do not claim an exact GREEN-byte reread. The later37-case focused run selects the corrected coding/context/privacy files; unrelated trace-test hashes changed afterward. Fresh canonical03 matches frozen source inputs and executes the final expanded cases, closing that correspondence limit.

Native build binding independently matches116 lib/config input hashes, all43 released static asset hashes, and all130 application modules' complete retained BEAM chunk dictionaries. Release stripping differences are preserved; raw BEAM equality is not claimed. Four generated/overlay inputs differ from the original freeze as recorded by root. Build commands exit0. These checks bind the reviewed native candidate without claiming every live/generated file equals all636 frozen inputs.

## A8: command-free inspection remains bounded and honest

Frozen03 Readiness/LiveView trace inventories add `Coding.stop_session/1` and `cleanup/1` to the existing pinned/unpinned Docker, context/invoke, Port, System.cmd, admission/profile/run and transport observe/verify boundaries. Actual compiled private `coding_command` arities are **[2,4]**. No nonexistent3 or removed profile/0 instrumentation is counted. Canonical03 logs show60 positive Readiness match lines/30 unique MFA pairs, none zero. Actual caller/child marker calibration, delivery barriers and exact expected inspection/tool-call counts remain; unexpected LiveView workers fail the test.

Canonical03 passes actual synchronous Readiness, real Inspect/Refresh events and all three MCP read tools, including both company-plan list/detail calls. OpenCode current identities/applicability/release admission remain **Not assessed**; MCP remains `not_assessed_by_this_tool`. Private endpoint/daemon sentinel cases and unknown-reason tests pass. Native Package Inspect/Refresh retains the exact refusal as a historical observation and adds no further observe call. General mount/model availability checks are outside the synchronous abstention claim; this is not universal application I/O purity.

## A9: actual refusal and native visual evidence

Root's two separately queued UI task IDs are **`31ce6c99-7887-425a-a212-41307e82442a`** and **`b0759206-ed3c-438c-92f0-87a8ba25d2a6`**. I inspected their actual persisted-result evidence, both launch traces, probe source, tags-only fixture setup and before/final observations. Both launches assert the absent `/private/tmp/hf07-a9-missing.sock`, unset DOCKER_CONTEXT and configure a selected healthy local synthetic model before UI queuing. Source admission order and actual traces reach the **new** observe after model availability; both return `coding_transport_unavailable`. These are neither seeded rows nor prerequisite/old-probe refusals.

Both results are v2 blocked/unqualified with null environment digest/private context, not_started/not_dispatched and empty checks. The traces have all targets positively matched and exactly two observe refusals, with zero Coding.run, relay/session start, runtime preparation or pinned Docker calls. Tags counters record8+6 GETs and zero POSTs; final recorded SQLite counts are zero model requests/budgets, with no coding directories. Distinct missing-model and unsupported-runtime controls retain separate copy. An accidental static-integrity queue is preserved and excluded from the two transport refusals.

I **actually viewed all four primary ordinary native JPEGs at their original2560×1320 resolution** with the matching full DOM records. All show the complete changed card, fixed explanation, full UUID, `Runtime qualified: false`, `Cleanup: not_started` and visible Compare focus ring without overlap or required horizontal scrolling. Native Chrome zoom records establish actual100%/200%; devicePixelRatio alone is not the zoom proof.

| Measured width / actual zoom | Viewed primary file under `tmp/enhancement-program/07/browser/` | SHA256 | Matching DOM and fit |
|---|---|---|---|
|320 /100%|`native-320-100-fit.jpg`|`0ae6339dae798b5747439e711a161a492263cdfb537fe2cc37e402c64290d815`|`320-100-native-fit.json`; document305≤320, height800; target card fully within viewport.|
|390 /100%|`native-390-100-fit.jpg`|`4b7e8aaab0e02318653e38092a8d815cee5123bbc5b1cbec04a5825b623c9152`|`390-100-native-fit.json`;375≤390, height800; target card fully within viewport.|
|320 /200%|`native-320-200-fit.jpg`|`9143862f2f15ca0b5c92b27e0d6165925c5260789da491e61ef63778c6bccc01`|`320-200-fit-stable.json`;312≤320, height400; target card fully within viewport.|
|390 /200%|`native-390-200-final.jpg`|`61cdf5a33ed2dc4a88c217d5d18b34ea26ae2ffe0194095925e75e88e5cd4bf9`|`390-200-corrected-native-fit.json`;382≤390, height400; target card fully within viewport.|

DOM active control is Compare runs in all four. I also viewed retained earlier390/200 and320/200 focused captures: earlier controls/viewport limitations remain classified, and the earlier320/200 focused-full-card image visibly clips the lower UUID. They are not substituted for primary final images. CSS-size screenshots are supplementary. Other offscreen run cards in a DOM record are not claimed visually covered merely because text exists in that record.

I independently recount **12 actual traced refresh callbacks** between `poll-focus-before.json` and `poll-focus-after.json`; both retain the same Queue button focus and unchanged result text. Keyboard traversal reaches Compare; leave/return preserves both IDs. Restart requires fresh authentication and original history survives. Neither repeated refresh nor historical Readiness upgrades qualification. Terminal refusal rows render no Cancel. **Native removal of a previously active Cancel control was not exercised**; focused/guarded active cancellation tests establish cancellation behavior, not that separate native focus episode. That limit remains explicit rather than becoming a new claim or extra gate for unchanged controls.

## Acceptance and execution accounting

| Criterion | Final evidence and boundary |
|---|---|
|A1|Positive finite route/profile correspondence fixtures plus fresh actual Desktop pinned-image execution. Native Linux remains policy-fixture-only/unqualified.|
|A2|Bounded malformed/unsafe/discovery and failed-atomic-commit tests; actual native healthy-model/new-observe refusals with no runtime effects.|
|A3|Original-endpoint/decoy/same-path replacement tests pass; actual completion drift refuses qualification. No hostile-host atomicity/ABA guarantee.|
|A4|Active relay cancellation regression and expanded ownership/context cases pass; guarded real in-flight cancellation, timeout and restart cleanup pass.|
|A5|Owned context/current identity fixtures and actual protected tasks/metering/cleanup pass. Separate healthy same-endpoint accounting-config drift yields inconclusive/unqualified.|
|A6|DTO/UI/MCP/context migration/old-new restore tests pass; actual packaged CLI/list/compare/export/Audit sentinel checks remain correctly labeled privileged static fixtures, not coding qualification.|
|A7|Scoped failure/retry/foreign workspace tests pass; supplemental actual Docker-backed workspace purge removes owned terminal context and preserves foreign row.|
|A8|Expanded calibrated canonical traces and native historical inspection abstain as above.|
|A9|Two real new-observe refusals plus four actually viewed native width/zoom combinations, keyboard/polling/history observations pass within the stated cancellation-focus limit.|

I parsed actual machine entries and source correspondence: **canonical03 registers554, runs/passes539, fails0, skips15, excludes/invalid/unknown0; exit0,60.506348s**. Fresh guarded03 registers28, runs/passes15, fails/skips0, excludes13; exit0,350.041974s. Its15 passing module/name identities are **exactly** canonical03's15 skipped identities, so all554 canonical identities actually pass across those two runs; default skips remain skips in the canonical record. Supplemental03 passes one distinct noncanonical identity,55.718352s: **555 distinct observed passing test identities** total. Focused repetitions add none. Coverage/flake rates remain unmeasured.

Forced warning-gated compile, CI Credo warning scope and format checks exit0; Dialyzer is baseline-only as above. Original failed focused/canonical candidates, both REDs, earlier new opacity findings, static-selector mistake, workspace-lock refusal, browser timeout/state-check attempts and partial images remain preserved. No retry/exclusion/timeout relabeling supplies acceptance.

Owned audit: `tmp/enhancement-program/07/review-web07-final-audit-03.json`, SHA256 `bb60a53d96b7ac89210033edffb9b142d708cd1f957b9b59e9c90c106f424c48`. It records complete packet/freeze checks, delta, source inputs, distinct-test accounting, raw trace recount, actual viewed-image hashes, DOM fits and native asset/retained-BEAM comparison. No remaining concrete web evidence request blocks this bounded verdict. Root still owns final QA acceptance, installation/preservation and five new retrospectives before counting07.

No native Linux, real-model quality, managed Codex/Claude, authenticated connector, portable recipient authority, company fitness, speech, novice comprehension, WCAG certification or longitudinal reliability claim follows. Backups remain unencrypted/private and may contain identifying cleanup context. Earlier Goals-to-Evidence/comprehension dissent remains unresolved; transport success does not select or bundle that work.
