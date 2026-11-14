# Iteration 07 — evaluation integration handoff

Author B owns only `lib/harness_forge/evaluations.ex`, the two existing evaluation test files and new `test/harness_forge/coding_context_test.exs`. Root released edits after both author ACKs. This reuses and extends the existing Evaluations, Run, TaskSuite and execution boundaries; it adds no dependency or public tool. Author A owns the shared `CodingDockerFixture` and transport implementation. Root owns schema/privacy/UI integration and every execution check.

The task path calls `Coding.admit/1` once, derives its public v2 identity and private six-key context from that observation, and inserts them together before `Coding.run/3`. Refusals persist the original prerequisite reason, fixed v2 marker, null environment/context and undispatched/unstarted state. Public DTOs still return result only. Persistence failures return a fixed error.

The model configuration is captured before admission. Identity construction and insertion recheck it; a change commits a `model_configuration_changed` refusal with no private context, within the same transaction before dispatch. A paused-health regression covers selection changes. Root's first focused invocation compiled product modules without warnings but stopped on a test helper name colliding with `Ecto.Query.update/2`; correction round one renamed that helper. The second focused run reached tests and exposed the shared B fixture's symlinked macOS temporary ancestor; correction round two uses canonical `/private/tmp` on Darwin and explicitly builds the pinned runtime artifact so transport tests can reach admission. The third run reached all test bodies; one B test revealed stale test structs making intended workspace/context restoration ineffective. Correction round three reloads the actual row for each fixture mutation and asserts each injected stored value. It also keeps model mutations on the controlled endpoint and advertises both original/replacement models, so model drift fails identity while health remains available. Directory and qualification guards remain intact. The corrected test run remains pending root.

Live applicability loads the actual current-workspace row and requires supplied-result equality, artifact ownership, stored-context decode and recomputed profile equality before current admission/model/config comparison. Completion validates the terminal candidate against its owned pending identity and current authority separately, so a successful terminal candidate need not equal its still-running stored result. Lost authority makes a proposed qualified success inconclusive.

Cancellation, restart and purge use persisted backend dispatch. Static/managed, explicit predispatch and exact restored quarantine rows require no daemon. Offline smoke uses only Execution; v2 coding uses only Coding's original context. Unknown unfinished legacy origins remain unresolved. Restart enumerates stored unresolved records without a current-daemon probe or global sweep. Scoped `cleanup_runs/1` rechecks retained completed contexts, preserves authority and terminal outcomes on failure/retry, and works without artifacts, models or writability admission while purge is fenced.

Authored coverage includes owned-result authority, missing/corrupt/foreign/legacy contexts, endpoint/daemon/model drift, precise healthy-model transport refusal, private DTOs, completed-context rechecks, scoped decoys, original-daemon retries, cancelled restart, and no-contact backend/quarantine cases. The guarded stable task test exercises new-terminal completion; an additional guarded current-selection drift test checks completion invalidation. The old provider-health cancellation fixture now verifies that no attempt exists before admission finishes, consistent with atomic pre-effect insertion. Resource-stage cancellation coverage remains.

Author B ran no Mix, Docker, database, build or browser operations. All verification is pending root execution; fixtures establish controlled behavior only, never native transport or model quality.

Suggested root checks:

```sh
mix format lib/harness_forge/evaluations.ex test/harness_forge/evaluations_test.exs test/harness_forge/coding_evaluation_test.exs test/harness_forge/coding_context_test.exs
mix test test/harness_forge/evaluations_test.exs test/harness_forge/coding_evaluation_test.exs test/harness_forge/coding_context_test.exs
```

Root separately schedules guarded Docker checks, canonical tests and A1–A9 evidence. No installation, iteration completion, merge or publication is claimed.
