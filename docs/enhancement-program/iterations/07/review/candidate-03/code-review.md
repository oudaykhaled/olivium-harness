# Independent code review — frozen03 limited delta phase

**Verdict: SOURCE_DELTA_ACCEPTED; PENDING_GATES / PENDING_RUNTIME / PENDING_NATIVE.** B1 cancellation ordering and N1 stale test premise are closed for the reviewed source and focused evidence. B2's opaque-type repair is source-correct, but its required fresh Dialyzer gate is still pending in this phase. No new blocking defect or nit was found. This is not whole-candidate approval, installation authorization or iteration completion.

The [original02 report and revocation addendum](../candidate-02/code-review.md) remain unchanged, SHA256 `09e100f98573217bb96008a899c354c06a2b01c2e044e1ac76193dacfdddc77a`. This phase follows root's explicit release to review only frozen03 delta plus retained RED/GREEN/focused evidence. No peer07 review report was read; no product/test edit, test execution, Mix, Docker, process, database, browser or HTTP operation was performed.

## Evidence identity

The independent [03 audit](../../../../../../tmp/enhancement-program/07/review-code07-candidate03-delta-audit.json), SHA256 `e519eae54321dcc2acbd20245f4a9f25784907d4c22ac2392cd5601b1b08def5`, verifies **636/636 physical frozen03 copies, zero mismatches**, against manifest SHA `8651fdc74e283fe737defdf67abe92390752058d5d5a7e9fbcb2993725b3128f`. Compared with02, exactly eight paths change, with no addition/deletion: three implementation modules and five test files. All source references below refer to `tmp/enhancement-program/07/source-candidate-03/`, not live source.

Both retained RED source directories contain **192/192 matching command-recorded input hashes**. Command/suite files were parsed and all recorded stdout/stderr lengths/hashes checked. The GREEN01 exact source directory was not found at its expected prefix; GREEN's recorded hashes differ from03 in seven files, so its log alone is not claimed to execute every final03 byte. The stronger later focused run's 192 input hashes match03 except the two readiness test files, subsequently changed only to add trace targets. All three changed production modules and all three tested focused files match03 exactly.

## Blocking finding dispositions

**B1 — Closed for source and focused regression.** `coding.ex:854` exposes an internal `stop_session/1` using the existing workspace/run global lock. `stop_owned_session/1` checks a valid UUID and an actual persisted row matching current workspace/run before calling the existing local session stop. Direct cleanup at line876 revokes locally before `owned_observation` and daemon verification. Shared `evaluations.ex:709` revokes before `cleanup_backend`, covering malformed-context rejection rather than leaving that branch ahead of revocation. Missing/foreign persisted rows cannot revoke a session.

Local-stop failure short-circuits before Docker cleanup and is returned as cleanup failure. Revocation itself reads no endpoint metadata. Remote context/profile/daemon/label checks and final identity verification remain intact; successful local revocation alone never marks remote cleanup complete. Creation and revocation reuse the same per-run lock. The dispatcher releases its first lock before guarded Coding cleanup reacquires it, but cancellation has already persisted terminal intent, direct cleanup revokes again under its lock, and scoped purge refuses active evaluations; this introduces no identified new creation bypass.

Root's retained RED01 failed on the empty-command assertion because its fixture lacked public workspace_id: this is an earlier setup failure, not the intended RED. **RED02 actually fails `refute Process.alive?(session)`** after the original-ID command assertions, demonstrating B1 in the first unavailable-daemon loop case. It does not demonstrate reaching the second replaced-ID case after that failure. GREEN01 passes the one selected test containing both scenarios. Counts for each selected run are nine registered, one executed, eight explicit exclusions, zero skips; RED02 exits2 and GREEN01 exits0. These are repetitions of one test, not nine executed cases.

The later **37/37 focused run**, exit0 in19.047252 seconds with zero exclusions/skips/failures, executes the final03 active relay/cancellation assertions. It covers unavailable/replaced daemon, no subsequent listener access/inference, preserved context and cancelled retry; both cancel and direct cleanup with null/corrupt context; and missing/foreign-row refusal while the local session remains alive. The listener and session are real local processes; the Docker CLI/daemon state and model health service are synthetic. This closes the local-capability regression without claiming actual container interruption qualification.

**B2 — Source repair accepted, fresh gate pending.** `coding_transport.ex:16` adds typed route/endpoint/digest accessors while retaining `@opaque`. Coding no longer destructures raw observation fields. `identity_digest/1` uses the same four-key version/route/endpoint/daemon digest input as02, so the repair does not change profile identity semantics or expose context through result DTOs. No suppression was added. The two original new opaque_match diagnostics remain historical failures; only a fresh root Dialyzer result showing exactly the two unsuppressed baseline Releases findings can close this gate. No such result was included in this limited release.

## Non-blocking finding dispositions

**N1 — Closed.** `coding_pinning_test.exs:333` now fetches each actual row before context mutation and asserts the stored context. The final forged-digest test reloads before restoring the original context, then explicitly checks valid original context plus forged stored digest before invoking cleanup. Thus a passing refusal now exercises the intended inconsistent profile premise. The focused37 record includes this passing test.

No new non-blocking defect was found. One evidence limitation remains: the failed-insert log test explicitly asserts actual repository `log: false` and captures debug logs without endpoint/daemon/context. This verifies the deployed logging configuration's error path, not confidentiality under arbitrarily re-enabled SQL parameter logging. Frozen `config/runtime.exs:29` already sets `log: false`; no privacy expansion is inferred.

## Nit

None.

## Praise

The correction keeps revocation authority smaller than Docker cleanup authority and tests the distinction with actual local processes. Added workspace-purge tests preserve an entire foreign-workspace row and unrelated file across failure/retry. The atomic-insert test proves three pinned image checks were reached before an injected insertion failure, then checks fixed error, unchanged row/file counts, no ledger/budget and no resource-effect commands. These tests address the failure premises directly.

## Acceptance mapping for this phase

| Item | Frozen03 disposition and observed evidence | Still pending |
|---|---|---|
| A1 | Typed accessors preserve one observation and existing pure profile/route threading; source inspected. | Fresh actual pinned runtime/proxy/network correspondence. Native Linux remains unqualified. |
| A2 | Focused37 executes failed atomic insert after three image checks, fixed refusal/private logs, zero runtime effects; previous decoder/refusal source unchanged. | Full canonical/static checks and native discovery-refusal journey. |
| A3 | Pinned context/ID/labels retained; focused37 reexecutes original/decoy and replacement guard tests. | Actual Docker drift/decoy and guarded execution evidence. |
| A4 | B1 source/actual local-session RED/GREEN and final focused corruption/ownership/retry cases close the identified regression. | Full container/in-flight request cancellation and restart checks; fixture absence is not live daemon absence. |
| A5 | Focused37 reexecutes owned-context applicability and both-healthy-model drift cases; completion logic unchanged. | Actual successful protected task execution and fresh completion transport/model/configuration drift evidence. |
| A6 | Focused37 reexecutes DTO/new-backup/restored no-contact tests and adds failed-insert confidentiality under log:false. | Fresh whole-candidate gates, final native projection and install compatibility inventory. |
| A7 | Focused37 adds workspace original-daemon failure/retry with foreign-row/file preservation, alongside source/file-failure retries. | Actual Docker-backed lifecycle evidence; no physical-erasure claim. |
| A8 | Frozen trace inventories add real `Coding.stop_session/1` and `cleanup/1`; retain actual coding_command arities2/4 and calibrated collectors. Getters are pure; they are not invented traced command boundaries. | New calibration execution for the two updated trace-test files; focused37 did not run them. |
| A9 | Presentation bytes unchanged from02. | Root's native healthy-prerequisite→observe-refusal journey, ordinary changed-outcome images/DOM, measured320/390 CSS×actual100/200% and keyboard checks. No images supplied/viewed in this phase. |

Root reported canonical03 running at dispatch. I did not infer completion or consume later canonical/static/Dialyzer/Docker/build/native results outside this release. The next root handoff should bind those finished results and ordinary images to the frozen candidate; I will read/view them before final scope acceptance. Original02 source findings, initial failed reproducer, actual RED02 and all default skips remain preserved. This phase establishes neither company/model/connector qualification nor managed Codex/Claude, portable authority, speech/novice/WCAG, Linux topology or longitudinal reliability.
