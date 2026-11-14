# Shared privacy fence: scoped review

**Blocking:** None in the frozen repair. Scoped static approval of freeze05 (`948c48f0f2169ed81f5987164ae11b7ef1593a8e30a40c8526f64aa5ebce48d6`); this does not establish repaired browser delivery.

**Non-blocking / limits:** Candidate03 packaging and repeated browser replay remain outstanding evidence. Check22 records one successful independent CLI run; check23 records the next run failing to display the artifact. The debugger attributes that failure to a DB/privacy-lock wait, supported by its cited private log; this reviewer did not access that log. Preserve both outcomes. No repeated-browser-green claim is justified yet.

**Nit:** None.

**Praise / correctness:** `purge.ex:814–832` keys ownership by workspace in the calling process. It sets the marker only inside the acquired global-lock callback. Nested calls execute directly without another acquire/release, so an inner return or caught failure cannot release the outer fence. Only the outer callback deletes its marker in `after`; normal return, raise, throw and exit propagation retain Elixir’s cleanup semantics. Untrappable process death destroys process-local state; lock-owner death handling remains the existing global-lock mechanism. A different workspace uses a separate marker and resource. This is trusted process bookkeeping, not a new externally supplied authorization signal.

The complete production delta is the wrapper replacement plus its separating blank/comment. Reconstructing the original wrapper yields check24’s exact original file hash. `harness_delivery.ex:79–96` still encloses the transaction, readiness checks, verified artifact lookup, eligibility and bounded delivery inside the fence, with refusal on uncertainty. Its file hash matches the prior approved source.

`purge_synchronization_test.exs:15–106` probes the actual lock from another PID with zero retries. It covers nested return values, caught nested raise/throw/exit, outer raised-exception cleanup and re-entry, and independent workspace ownership. It does not mistake missing callbacks or elapsed sleeps for exclusion. Check24 retained four tests/two expected failures; check25 records 73 tests/zero failures across lock, delivery, outcome, requirements, retrieval and privacy tests. Both receipts have equal before/after source maps; current lock/test hashes match freeze05 copies.

The corrected regression matches `repeatable-source02`: lines48–62 no longer read an attempt-relative path as a host file, and timestamped exclusive receipts remove the fixed-name sequential rerun failure. It asserts the download event/path/name and explicitly delegates exact ZIP bytes to Root’s post-run comparison. UI/history and 320px geometry assertions remain; this is an existing synthetic artifact regression, not a new model/company qualification.

Only the assigned report/audit were written. No tests, runtime, browser, screenshots, private files, or generated exports were executed or inspected. Root retains implementation, canonical checks, packaging, exact-byte comparison and replay ownership.
