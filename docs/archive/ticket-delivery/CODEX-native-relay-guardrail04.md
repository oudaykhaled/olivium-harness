## GUARDRAIL BRIEF — native relay lifecycle repair re-review04

**Classification:** Standalone HarnessForge · bounded private approval lifecycle repair · additive.

**Verdict:** PROCEED for this repair. Review03 F1 is closed in the inspected source and recorded regression evidence. No new P1/P2 finding in this scope; no user decision required.

**Guardrails that apply to THIS request:**
1. **Current-call delivery is enforced.** relay.ex:425–437 compares the recorded binding's call_id to native_pending_call before invoking CommandApprovals.poll. A stale approval cannot reach consumption through this route after continuation.
2. **Recorded approvals settle before continuation.** relay.ex:309–317 and :458–483 collect bindings for the pending call/current driver nonce, then require every recorded ID to exist with consumed/declined state. Pending, accepted, missing IDs and list failures deny before Runtime.responses. The GenServer serializes relay transitions; this change adds no human wait or parallel approval engine. No-record tool-error continuation grants no approval.
3. **Existing fences remain.** The inspected route retains driver/thread/turn binding, call uniqueness, pre/post currentness and deadline checks. Root124's Runtime and command-policy hashes match review03, preserving argument admission and usage settlement. Keep the existing unconditional unqualified execution boundary; native controller, isolation and actual editing remain separately unqualified.

**Definition of done for this re-review:**
- [x] Regression asserts pending and accepted-before-poll continuations return 503, retain one model request and leave approval state unchanged; consumed continuation succeeds; stale polling before finish returns 503.
- [x] Separate no-record error continuation succeeds while approval records remain empty. Configuration drift still rejects consumption.
- [x] Root124 log records 102 tests, 0 failures, 31.8 seconds; evidence exit is 0. Both reviewed files match Root124 before/after pins; the saved test copy also matches.

**Hard STOPs:** This result does not authorize host execution, relax confinement, enable the absent native controller, or establish company/task/release qualification.

**Knowledge base:** Unchanged. Read-only inspection; no tests, commands or runtime actions executed by this reviewer. Domain/SQL/WEB internals were not re-reviewed. Exact hashes, inspected ranges and evidence-read limitations are in the accompanying audit. Review03 remains frozen.
