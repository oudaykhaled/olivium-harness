# Independent final code review — frozen03 source and QA

**Verdict: SOURCE / QA ACCEPTED for frozen03. Blocking: 0. Non-blocking defects: 0. Nits: 0. Main preservation and installation remain pending; the programme remains 6/50.** This is an independent code-lens decision, not a vote or whole-iteration completion. No additional source fix or QA execution is requested within this scope.

The original candidate02 report and revocation addendum remain unchanged at `review/candidate-02/code-review.md` (SHA256 `09e100f98573217bb96008a899c354c06a2b01c2e044e1ac76193dacfdddc77a`). The limited candidate03 report remains at `review/candidate-03/code-review.md` (SHA256 `600c80ec7cfb5529b83177e21f54877d35ca99682cebb39b9ba15eab0204aee4`). This final phase consumes root's explicit final QA release. I read no peer07 review, spawned no agent, changed no product/test, and performed no runtime, browser, Docker, Mix, database or process operation. Read-only file/hash/BEAM-chunk inspection and ordinary local image viewing support this report.

## Evidence identity and actual gates

I fully read `verification.md` and the 156-entry `final-qa-packet-01.json`, SHA256 `ad50804b139c899db5d427510453a8a415b8b93ba3cd101aa17f4a2764b149c7`. My independent audit `tmp/enhancement-program/07/review-code07-final-audit.json` verifies all 156 evidence files by length and SHA256, and all 636 physical frozen03 files, with zero mismatches. Frozen03 manifest SHA256 is `8651fdc74e283fe737defdf67abe92390752058d5d5a7e9fbcb2993725b3128f`. Source references below are under `tmp/enhancement-program/07/source-candidate-03/`, not mutable live source. Earlier full source/delta reviews remain the basis for unchanged code.

Canonical03 has 554 registered identities: 539 passed, 15 default Docker skips, zero failures/exclusions/invalid/unknown, exit0 in60.506348s. Fresh guarded03 has 28 registered, 15 passed and13 explicit exclusions, zero failures/skips, exit0 in350.041974s. I independently compared module/test-name identity sets: those15 passes exactly equal the canonical15 skips. Thus554 canonical identities actually passed across the two runs; repeats do not inflate this count. The separate supplemental script contributes one new passing identity, exit0 in55.718352s, for555 distinct observed passing identities. Coverage remains unmeasured.

All192 recorded source inputs in each final canonical/guarded/supplemental and reviewed static command agree with the corresponding frozen03 hashes. The supplemental script is separately bound by `completion-configuration-input-v3.json` and the packet; its preparatory `executed:false` field is not an execution claim. The later command, suite and stdout establish its actual execution. Forced warning-gated compilation, CI strict Credo warning scope and both format checks exit0. Unsuppressed Dialyzer03 exits2 with exactly `releases.ex:47` and`:121` call_without_opaque findings, zero skipped/new findings and no ignore option. It is baseline-only, not a clean type gate.

Native build inventory/compile/assets/release exit0. I independently parsed the physical application BEAMs and confirmed all130 release BEAMs match the production BEAM in every retained chunk, with raw SHA differences retained. All43 release assets match recorded bytes/hashes;116 lib/config input hashes match frozen03. Four generated overlay documentation changes are explicitly recorded. This establishes the stated build correspondence without claiming raw BEAM equality or bit-for-bit identity of the entire release tree.

## Blocking findings — closed

**B1: cancellation leaves owned local inference capability alive when daemon verification fails — closed.** Frozen03 `coding.ex:854` validates persisted UUID/workspace ownership and revokes the exact local session under the per-run lock. Direct cleanup at`:876` stops locally before decoding context or verifying the original daemon; `evaluations.ex:709` does so before backend classification, including null/corrupt-context rejection. Missing/foreign rows cannot revoke. Local-stop failure short-circuits; successful local revocation alone cannot declare Docker cleanup complete. Original context/profile/daemon/label checks remain mandatory for Docker; current selection never retargets original resources.

Retained RED01 is an early fixture setup failure. RED02 demonstrates the intended live-session assertion failure in the first unavailable-daemon scenario only; the replaced-ID RED iteration was not reached. GREEN01 passes the single loop test covering both scenarios, but has logs and192 hashes without a complete physical source snapshot. I do not claim an exact GREEN-byte reread. Final source-matching focused37 and canonical03 execute expanded active-session, null/corrupt context, foreign/missing ownership, retry and fresh-premise assertions. Fresh actual Docker tests additionally pass in-flight model-request cancellation and restart cleanup preserving cancellation. Together these close the source defect and its bounded runtime consequence.

**B2: new opaque_match diagnostics — closed.** Typed route/endpoint/digest getters keep raw observation access inside `CodingTransport`, preserve `@opaque` and the exact profile identity input. Fresh Dialyzer03 removes both candidate02 Coding diagnostics without suppression; only the two pre-existing Releases diagnostics remain.

## Non-blocking findings — closed

**N1: stale Ecto restoration allowed a forged-digest test to refuse on the wrong context — closed.** Frozen03 `coding_pinning_test.exs:333` and the final restoration use fresh rows and actual stored context/digest assertions. Focused37 and canonical03 pass the corrected oracle. No remaining non-blocking defect was identified. Failure-path confidentiality is verified under actual `Repo log:false`; enabling SQL parameter logging is outside that result.

## Nit

None.

## Praise

The fix separates persisted-row authority to revoke an in-memory capability from the stronger authority needed to mutate original Docker resources. Tests exercise the difference using real local sessions/listeners and preserve foreign rows/files. The evidence retains initial failures, exclusions, physical-source limitations and partial captures instead of converting them into passing claims.

## A1–A9 disposition

| Item | Accepted evidence and boundary |
|---|---|
| A1 — observation/profile/route | Source retains one admission observation, pure deterministic profile and pinned route threading. Canonical classifier fixtures plus fresh pinned Desktop execution exercise the implemented positive route. Finite native-Linux policy fixtures do not qualify a live Linux topology. |
| A2 — refusal/admission atomicity | Canonical executes exact decoder/refusal and atomic-insert tests after three pinned image inspections with no runtime effects. Native healthy tags lead to actual observe refusal twice, durable v2 blocked rows, null context/digest, empty checks and no dispatch. |
| A3 — pinned commands and identity | Source pins endpoint and original daemon throughout runtime/cleanup, with bounded output/time and label checks. Command safe_args rejects all -H prefixes. Canonical decoy/replacement fixtures and fresh guarded successful execution/completion drift pass; original-endpoint postflight records no labelled HarnessForge containers/networks. This is not a foreign/unlabelled-orphan guarantee. |
| A4 — cancellation/recovery | B1 closure above, final active owned-session negative cases and actual in-flight Docker cancellation/restart tests pass. Failed cleanup retains context and cancellation for original-resource retry. |
| A5 — applicability/completion | Actual owned persisted result/context guards remain. Canonical both-healthy same-endpoint model/configuration cases pass. Guarded protected tasks succeed and connection drift cannot qualify; separate actual pinned supplemental run completes both task checks with healthy unchanged endpoint/model but changed accounting configuration, then records inconclusive/unqualified with original digest. Controlled protocol success does not measure real-model quality. |
| A6 — privacy/compatibility | Six-key private context remains outside result DTO/audit/export, redacted on inspection; rollback/restore cases pass. Actual packaged CLI11 steps, eight exports and audit projection omit privileged synthetic sentinels while private DB retains them. This fixture is a static unqualified row, not fabricated coding qualification. Backup context is intentionally private and unencrypted. Main additive-schema preservation/install is a later gate. |
| A7 — lifecycle/purge | Canonical source/file-failure and workspace failure/retry tests retain authority until deletion completes and preserve foreign data. Supplemental actual Docker-backed purge removes the completed owned context while preserving a foreign workspace row. Fences/backend dispatch remain explicit; no physical-erasure claim. |
| A8 — bounded discovery | Canonical03 executes updated calibrated traces for actual Inspect/Refresh and three MCP tools, including stop_session/cleanup. Compiled private coding_command arities are2/4, not3. Native Inspect/Refresh retains historical refusal with current authority Not assessed and no new observe. This is evidence for those paths, not universal absence of I/O. |
| A9 — native outcome | All four primary ordinary native JPEGs actually viewed and compared with measured DOM/actual Chrome zoom evidence; target outcome and keyboard focus fit. Actual queued IDs persist through restart and leave/return. Twelve traced refresh callbacks preserve Queue focus. Terminal refusal has no Cancel; native focus behavior when an active Cancel disappears remains unexercised. |

## Actual image inspection

I viewed each primary JPEG through the read-only local image tool at original detail. All four show the target blocked header, complete fixed Docker explanation, Runtime qualified:false, Cleanup:not_started, complete UUID `b0759206-ed3c-438c-92f0-87a8ba25d2a6`, and visible Compare focus. DOM rectangles fit the viewport/document without required horizontal scrolling. At200%, adjacent lower cards are partial; acceptance concerns the complete target card. Browser AX records establish actual100/200% zoom; devicePixelRatio alone is not substituted for that evidence.

All paths in this table are relative to `tmp/enhancement-program/07/browser/`:

| CSS width / actual zoom | Primary native JPEG and SHA256 | Paired DOM |
|---|---|---|
| 320 / 100% | `native-320-100-fit.jpg` — `0ae6339dae798b5747439e711a161a492263cdfb537fe2cc37e402c64290d815` | `320-100-native-fit.json` — `79508ed33ce33377ce01a7182c4cb37d6c174a125b906fdc5528c49f834f8392` |
| 390 / 100% | `native-390-100-fit.jpg` — `4b7e8aaab0e02318653e38092a8d815cee5123bbc5b1cbec04a5825b623c9152` | `390-100-native-fit.json` — `e460842b6c95fe758b441a7b43fddcc754f0b68e27000535f022f63edce164fc` |
| 320 / 200% | `native-320-200-fit.jpg` — `9143862f2f15ca0b5c92b27e0d6165925c5260789da491e61ef63778c6bccc01` | `320-200-fit-stable.json` — `88ae9ad55a7544f5daaab7fc222547d9e4f1bfcdd7696bcf38e7eadff1a386d6` |
| 390 / 200% | `native-390-200-final.jpg` — `61cdf5a33ed2dc4a88c217d5d18b34ea26ae2ffe0194095925e75e88e5cd4bf9` | `390-200-corrected-native-fit.json` — `a9997196d264b1bb3f25ceb426842def70548048fe09b4b12fbfe5c618115e0a` |

The earlier `native-390-200-fit.jpg` is header-clipped and the earlier320/200 focused captures omit lower UUID content; they remain partial evidence, not the accepted replacement captures. CSS-size images are supplementary only.

I independently parsed both native trace event logs: every registered pattern matched; two observe calls returned coding_transport_unavailable; no Coding.run, relay/session start, Runtime.prepare or pinned Docker command call appeared. Exactly12 evaluation_poll events fall between the before/after focus timestamps, whose active element remains Queue evaluation. The final recorded DB state contains the two actual refusal IDs, no model requests/budgets/coding directories, and healthy tags counters with zero POSTs. The extra static selector attempt is retained and not counted as refusal. These are bounded instrumented native observations; they do not establish speech, novice usability or general WCAG conformity.

## Remaining boundary

No new evidence is missing for this code-lens SOURCE/QA verdict. Root's main preservation/install obligations remain outside it, including repeated identity/quiescence verification and post-install comparisons; the read-only preflight and an unexecuted helper cannot close them. No native-Linux, authenticated connector, managed Codex/Claude, portable recipient authority, real-model/company fitness, speech/novice/WCAG or longitudinal reliability claim follows. The original architecture/quality dissent remains relevant to those unproven scopes and is not resolved by test-count accumulation.
