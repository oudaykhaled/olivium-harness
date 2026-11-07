# Native Responses review01

**Verdict:** One P2 requiring correction; no P1 identified in the reviewed protocol boundary. Source-only review of all nine implementation/test files in `implementation-ready01.json`; current full-file hashes and authored-pin differences are in `protocol/review-audit01.json`. Coding/Evaluations lifecycle integration is excluded.

## P2 — Bound the whole attempt, including identity metadata

`local_model_identity.ex:59` supplies only a 2,000ms `receive_timeout` to `HTTP.request` (`provider.ex:167–179`). That is an inactivity timeout, unlike the explicitly supervised absolute deadline in `request_responses` (`provider.ex:73–86`). A metadata response that continually supplies bytes can therefore keep identity observation running beyond the request/run limit.

The initial and final `current_identity` calls run outside that absolute timeout (`runtime.ex:158,170,190–193`). Even without a slow-drip peer, three sequential metadata requests before a permitted 60-second Responses call, followed by three more metadata requests, can exceed `Relay.responses`' fixed 65-second call timeout (`relay.ex:95`) and the proxy's 65-second read timeout (`proxy-responses.conf:23`). The caller receives an error/disconnect while the relay continues settlement/metadata work. Cancellation revokes publication through the atomics latch, but `Relay.stop` can itself exhaust its fixed 65-second wait while the blocked identity check continues (`relay.ex:77`). This contradicts the bounded attempt/cleanup contract.

**Smallest correction:** establish one monotonic absolute attempt deadline, capped by remaining relay lifetime and leaving bounded settlement/teardown headroom below the enclosing call/proxy deadline. Pass remaining time into every metadata and inference operation; give metadata an absolute transport deadline as well. Recheck the immediate authorization latch around metadata transitions. Preserve ledger settlement for already-dispatched attempts and uncertainty for interrupted transport; do not extend waits indefinitely or hold SQL/privacy locks across I/O.

**Focused regression:** deterministic slow-drip metadata must terminate within the configured total deadline; delayed metadata plus near-limit inference must not outlive the outer call; revoke during metadata and during inference, then verify no later publication, bounded stop and correct reservation settlement. Existing fast fixtures do not cover these timings.

## Other reviewed behavior and limits

The implementation forwards original SSE bytes after bounded collection and validation, strips upstream authorization, rejects unknown request fields/server-tool types and nonlocal models, checks offered function/namespace identities and correlated input results, and rejects malformed/failed/truncated/ambiguous-limit streams. Reported usage settles before final source/configuration/model/authority checks; invalid usage retains uncertain reservations.

The immediate latch does not depend on servicing a queued GenServer message: `stop` verifies the protected ETS table's owner and token digest before setting atomics; dispatch/publication authorization reads that latch. No actionable latch defect was established within the trusted-host-process boundary. Do not claim ETS protects against arbitrary trusted BEAM code.

Tests were fully read, not executed. Root reported 39 tests with two fixture failures before the shared-Sandbox correction; the currently read test file includes that correction. This review does not certify the subsequent test result. Actual Codex request/tool-catalog compatibility, model inference, isolated tasks and benefit remain unverified.
