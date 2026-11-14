# Root integration choices for contract02 / corrected appendix03

These fix concrete storage names without changing the approved authority flow.

- Schema-v2 session payload adds `refs: {run_ref: Ref|null}`. Existing selection/draft/scope_pin/operation_refs/decision_refs keys stay; the two legacy ref arrays remain empty. V1 payload stays unchanged. Only SetupRuns owned CAS writes v2 refs; generic session mutations cannot accept caller-provided run refs.
- Every `command_id` or `last_command_id` in new dependent records means the caller command UUID, matched to `SetupRunCommand.command_id` using workspace/owner/session. `SetupRunCommand.id` is the stored row UUID. A command Ref uses that row ID and its immutable `request_digest`.
- `operation_binding/2` and `publish_operation/4` must compose inside an existing Purge→SQL transaction. Publication joins the caller transaction so claim/stage completion and Setup CAS commit together. They perform no network or filesystem work.
- Internal Models read helpers are `RunAuthorization.descriptor/0`, `prepared_view/2`, and `usage/2`. No helper grants authority or performs HTTP. Existing authoritative signatures and exact refs remain unchanged.
- Fresh command intent/registration/CAS commits before model execution. Execute acquisition/retrieval/analysis outside the command SQL/privacy fence; no provider wait while either is held. Use existing LiveView asynchronous handling for responsiveness. A replay returns the stored receipt and never executes again; interrupted/ambiguous work cannot silently resend.
- Root owns compatibility in Runtime.prepare when Ledger exact-cap reopening becomes strict: absent explicit budget may reuse observed existing exact caps; an explicit mismatch fails. This does not grant setup operations an alternate budget.

Root owns shared records/migrations, Capture/LocalImport, Privacy and runtime integration. Models and Setup own disjoint behavior and tests. Root alone formats/compiles/tests/builds/drives browsers/models/runtimes and writes canonical boards. All source remains uninstalled until integrated verification.

- Additional internal read `RunAuthorization.ready_for_run(run_ref,caller)` validates the same owned current preparation/disclosure/consent/origin/descriptor/limits/expiry without requiring an analysis operation before it exists. It creates nothing and performs no network I/O; Scope→Understanding uses this validation instead of a ready flag.

- Operation registration uses the same server UUID for `SetupRunOperation.id` and `.operation_id`; OperationRef.id also names the StageControl/CaptureRun. The DDL checks this identity. Capture helpers are `preflight_for_setup(session_id,connection_id,caller)` (FS outside SQL), `start_for_setup(config_ref,command_ref,caller)` (joins existing transaction) and `setup_status(capture_ref,caller)` (guarded metadata/index readiness).

- An identical active `prepare` validates both current versions and persists a new command receipt with those current versions. It does not increment either CAS, replace refs or alter phase/last command; an in-flight operation therefore keeps its publication version. State-changing commands still increment once. Setup cancellation/selection invalidation joins `SetupCapture.cancel_bound_run/1` inside the accepted transaction, withdraws queued/running/paused capture leases and marks unresolved reserved body charges uncertain without refunding allowances.
