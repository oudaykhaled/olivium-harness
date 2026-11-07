# WEB delivery privacy-fence debugging

Single sequential debugger; Root owns verification, runtime changes and boards. Generated harness files and imported documents remain data. No generated code, model call, browser, runtime or database mutation is part of this investigation.

## Frozen observations

- The second independent deterministic Chrome run returned the authenticated unavailable view for the unchanged artifact: `tmp/ticket-delivery/A02-browser/checks/23-repeatable-artifact-cli.log` and `repeatable-output04/results/generated-artifact-existing-reviewed-harness-da6b993ba21e23f2/attempt-1/screen-at-failure.txt`. Screenshots were not inspected.
- `tmp/ticket-delivery/A02-browser/private/web05.log:85` records an Oban database checkout queue failure after 1616 ms. At line 108, an existing HarnessLive client held its database connection for more than 15000 ms while waiting in `global.set_lock` through `Retrieval.declaration_current/2`.
- `HarnessDelivery.checked/2` holds `Purge.synchronize/1` around a `Store.transaction/1` and the complete artifact/currentness check. `Harnesses.eligible/1` reaches approved claim validation and `OriginV2` → `Retrieval.validate_current/2` → `Requirements.current_summary/2` → `Capture.current_summary/1`. Both current-summary functions acquire `Purge.synchronize/1` again inside that database transaction.
- `lib/harness_forge/privacy/purge.ex:813` uses `:global.trans({{__MODULE__, Workspaces.current_id()}, self()}, fun)` without nesting bookkeeping.
- Installed OTP 28.3.1, kernel 10.5 source is directly available at `/opt/homebrew/Cellar/erlang/28.3.1/lib/erlang/lib/kernel-10.5/src/global.erl`. Lines 698–706 always release the lock after each `trans/4`; lines 2086–2095 accept an already-locking PID without incrementing a count; lines 2133–2145 delete its sole lock entry. Therefore nested `trans` is not a recursive mutex.

## Competing hypotheses

1. **Nested global lock release causes the DB/privacy inversion (high confidence).** An inner current-summary return drops the outer fence while its database transaction remains open. A second read acquires that fence and waits for the first database transaction; the first later reacquires the fence and waits for the second read. Prediction: another PID can obtain the supposedly held fence immediately after a nested checked delivery. A regression can demonstrate this without timeouts, model calls or unsafe execution. The logged blocked call is exactly a later nested fence acquisition.
2. **A slow query alone exhausts the pool (lower confidence).** This predicts active query execution at the stalled client, whereas the retained stack shows `global.random_sleep` while holding the checked-out connection. Query cost can aggravate timing but does not explain the lock ownership hole.
3. **Artifact revocation, corruption or approval drift (lower confidence).** This predicts changed artifact bytes or currentness records. Root reports unchanged artifact bytes and two terminal model requests, and the production log independently demonstrates a lock wait. Existing refusal, tamper, revocation and plan tests must remain intact.

## Proposed smallest correction

Make the existing workspace-specific `Purge.synchronize/1` fence recursive for the same trusted BEAM process. Only its outermost call acquires/releases the existing global lock; nested calls run under that already-held fence. Use a workspace-specific private process marker with `try/after` cleanup. Do not remove the outer delivery transaction, change eligibility, change privacy checks, raise timeouts or add a different WEB-only lock.

Root extended ownership to `lib/harness_forge/privacy/purge.ex` and the new isolated `test/harness_forge/privacy/purge_synchronization_test.exs`. Root retained check 24 with four tests, exactly two expected failures, and stable source hashes before authorizing the helper correction. The nested-ownership and caught-nested-exception probes both demonstrated early release; outer cleanup and distinct-workspace probes passed.

Implementation attempt 1 replaces only the nonrecursive wrapper with workspace-specific process ownership. The marker is set inside the successful `:global.trans` callback; a nested call runs under its existing outer fence; `try/after` deletes the marker before that outer callback exits and global releases its lock. The resource and requester identity remain unchanged. `HarnessDelivery.checked/2`, its outer database transaction, currentness checks, privacy readiness, approval eligibility and all delivery bytes are unchanged.

## Verification plan

The deterministic regressions in `test/harness_forge/privacy/purge_synchronization_test.exs` obtain the real privacy fence and prove a different PID cannot acquire it with zero retries until the outer operation exits. They also cover caught nested raise/throw/exit, outer exception cleanup and successful re-entry, exact return values, and independent workspace ownership. Every probe observes an actual independent-process lock result and releases any acquired probe lock; no sleeps or missing callbacks are treated as success.

Root then runs the focused delivery and outcome tests, currentness/privacy regressions, compilation/formatting, and the same repeated independent Chrome artifact test. No resolution claim is made before that evidence exists. Maximum five implementation attempts; current implementation attempts: one. The debugger ran only the formatter on its two owned Elixir files; Root remains the sole test runner and runtime operator.

## Root-observed focused result

Root check 25 on exact freeze 05 passed all 73 focused tests with zero failures in 7.9 seconds and stable source hashes. This includes the four lock regressions, artifact preview/ZIP and LiveView outcome checks, declaration/privacy/currentness retrieval checks, and the privacy suite. Retained evidence: `tmp/ticket-delivery/A02-browser/checks/25-purge-and-web-focused.log` and `.json`. The RED result remains separately retained as check 24; no failed receipt was overwritten.

The focused result confirms the corrected ownership behavior and existing checked-delivery/privacy regressions. Root's full canonical suite, scoped Astra review, candidate build and repeated independent Chrome run remain pending at this checkpoint. It is not yet a deployed or real-company effectiveness qualification. The debugger releases product source ownership after this one correction and remains available only for a new reported failure.
