# Codex WEB command approval reuse facts

No durable native-command pending/accept-once/deny domain was found by targeted public `lib` searches. Existing domains supply reusable constraints, not command policy. Native Codex 0.156 app-server ownership is the supplied requirement; this inspection did not qualify its protocol. Full SHA256 pins and actual read ranges are in `codex-runtime/approval-reuse-audit01.json`.

| Existing seam | Reuse and limits |
|---|---|
| `Decisions.decide/2`, `decisions.ex:7–49` | Exact claim revision, current evidence, unique decision, append-only audit inside privacy fence/transaction. Claim-specific approve/reject; actor is supplied input. It is neither command approval nor sufficient caller authentication. |
| `SetupSessions.command/2`, `company/setup_sessions.ex:102–200,280–309` | Server workspace/local-operator ownership, caller validation before/after mutation, exact SQL version CAS, atomic audit, authorized current record on conflict. Private helpers are a pattern, not a reusable public command-approval API. |
| `Models.Ledger.reserve/3`, `models/ledger.ex:44–125` | Durable workspace/run/request uniqueness and payload fingerprint; uncertain duplicate work stays fenced. Existing public API meters model inference, not operator decisions. |
| `Coding.authorize_run/2`, `execution/coding.ex:1104–1120` | Best public current-run guard: exact workspace/run/artifact, running outcome, current `Harnesses.eligible/1`, privacy fence. Preserve this authority at decision and native response handoff. |
| `Models.Runtime`, `models/runtime.ex:258–296` | Current deadline/configuration/source checks include revision-use holds plus active source/connection; supplied run authorization closure is rechecked. These are private inference guards, not standalone command APIs. |
| `Relay`, `execution/relay.ex:29–65,201–215,259–288`; `relay_plug.ex:9–38` | Private capability token, owner/deadline/revocation checks, bounded requests, exact POST route and browser-Origin rejection. Keep capability out of WEB forms. Current turn range is1..100; Ledger default request budget is10 (`ledger.ex:8–11`). Requested32 approvals/run needs explicit enforcement. |

WEB touchpoint is **PortalLive itself**, `live/portal_live.ex:3110–3178`: evaluation form and run cards expose outcome/artifact/run plus cancellation; no command/cwd/hash or approval control exists. `OperatorSession` validates workspace/process-bound session per event (`plugs/operator_session.ex:20–58`); it supplies no durable named user. `Evaluations.get/1` scopes saved runs; cancellation remains distinct from verified cleanup (`evaluations.ex:127–138,316–351`).

Current `Execution.Codex.task_argv/1` invokes `exec`; fixed policy is `never`; command events fail closed (`execution/codex.ex:156–179,236–252,436–456`). The missing connected slice is durable exact request identity/payload plus one terminal decision and native response consumption, with command/cwd/hash presentation and existing current-run/session checks. Do not repurpose claim decisions or inference reservations as execution permission. Restart/expiry/cancellation and duplicate response semantics remain unimplemented for native approvals.

Inspected tests cover CAS concurrency/authorization rollback (`company_setup_sessions_test.exs:126–143,448–473`), relay budget/revocation (`runtime_relay_test.exs:221–233,300–319`), and rejection of approval/command events (`codex_runtime_test.exs:230–244`). No tests were run.
