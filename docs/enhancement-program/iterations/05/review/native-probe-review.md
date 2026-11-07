# Iteration05 native probe — independent static review

**Current verdict: STATIC PASS for the corrected bounded QA instrumentation.** No launcher, probe, application, Mix, browser or native operation was executed by this reviewer. This is permission-boundary and source review, not evidence that a native stale submission, reset or cleanup actually passed.

## First review — findings preserved

Original probe SHA-256: `ae44f6bd588e55d4c4c034bbc1acc227c9617f41123d7e715750f49f3e9749b9`. The supplied hash matched the original bytes read. The source is root's [fixed local QA probe](../../../../../tmp/enhancement-program/05/browser/native_probe.exs), adapted from the actual [03 probe](../../../../../tmp/enhancement-program/03/browser/native_probe.exs); historical 03 success did not establish 05 behavior.

**Initial verdict: CHANGES REQUESTED before execution.** Two bounded findings were sent to root and conductor:

1. The independent 45-second watchdog was spawned only after `:sys.suspend(pid, 5_000)` succeeded. A timeout/exception could leave a late-processed suspension without a watchdog. Arm target-specific cleanup before attempting suspension and handle failure explicitly.
2. The original code recorded `queued_before_reset` but proceeded for a nonzero queue. Such an episode cannot establish that reset preceded the old browser event. Require zero or resume and mark the episode inconclusive without a reset-first claim.

No product change, authentication bypass, destructive purge, generic eval command or new endpoint was found in the original instrumentation.

## Supplemental review — root's corrected bytes

Corrected probe SHA-256: `14b9c64d29a4ff1e6c8212e999d32b56033c8c8d5ad089480b76380c1d95f57c`; independently rehashed and reread. Launcher [start_native_qa.py](../../../../../tmp/enhancement-program/05/start_native_qa.py) SHA-256: `ba3e7eadbf28c9597e4c0506f0a5246b8a11cb67e0433173906575c612bb3595`; read and Python AST-parsed successfully without executing it.

- **Cleanup findings resolved:** an unlinked target-specific watchdog is created before suspension, invokes safe resume after 45 seconds, and survives an ordinary caller failure. Suspension/queue-inspection errors invoke safe resume and emit a fixed failure marker. A nonzero queue invokes resume and an inconclusive marker, with no reset sent. The one-attempt-per-launch flag is set before the attempt. Explicit resume and stdin EOF also attempt cleanup. These are bounded best-effort mechanisms with five-second system-call timeouts, not a hard guarantee for an unresponsive VM.
- **Workspace/port scope:** probe refuses unless configured root equals `Path.expand("tmp/g05")` and environment port is 8871. The wrapper, run from the explicitly assigned repository cwd, selects only 05 `native-final`, requires a fresh absent `tmp/g05`, refuses an occupied loopback port 8871 and existing startup record, disables distribution/MCP, and preserves PID/startup logs. It checks login readiness, expected release process command and that process's open `tmp/g05/data.sqlite3`. Current [runtime configuration](../../../../../config/runtime.exs) binds the server to 127.0.0.1. These static guards do not substitute for root recording actual process/workspace provenance at execution.
- **Privacy/authentication scope:** fixed stdin commands are only `status`, `reset-company-cache`, `queue-reset-and-suspend`, `resume`; unknown values cannot become code. Telemetry retains connected Portal PIDs, not sockets or assign dumps; output contains fixed markers/counts only. The probe does not read cookies, access codes, epochs, hidden form generations or evidence bodies and exposes no HTTP command surface. Existing [operator session](../../../../../lib/harness_forge_web/plugs/operator_session.ex) and [Portal](../../../../../lib/harness_forge_web/live/portal_live.ex) event/reset authentication remain in force. Auth state must be observed through ordinary login/lock/remount behavior; a reset signal alone proves no authentication-revocation result.
- **Reset scope:** the message uses the current workspace's existing cache-reset path. It clears the goal draft/review and readiness generations, then reloads; it neither invokes purge nor restores authority. The suspension command requires exactly one live registered Portal. Root must treat `refused_suspend`, `suspend_failed` or `inconclusive_queue_not_empty` as unavailable evidence, not a successful stale-event episode.

## What the native observation must establish

Use the genuine current form with a selected saved goal and synthetic rule text; let its ordinary change event settle. Capture the visible populated selection/text and focused control before reset, then the fresh empty form/control replacement afterward. Do not inspect hidden generation/auth values, manually repair the DOM or substitute a direct event injection for the browser submission.

For the one queued episode, record exactly one connected Portal and `queued_before_reset: 0`, submit the genuine old form while suspended, capture its pending/locked submit state, then explicitly resume before the watchdog deadline. Verify the old proposal refuses, the fresh form remains cleared and no new claim/decision/artifact/export appears. Preserve before/after record and artifact hashes and exact probe event chronology. This demonstrates that specific observed episode; it does not exhaust races. A fresh successful form submission, ordinary lock/fresh remount and consent/purge/restore regressions remain separate evidence.

Root retains sole execution, process cleanup and final acceptance ownership. Preserve startup failures/logs; inspect an existing PID before repeating startup. The original findings above remain historical; the supplemental STATIC PASS applies only to the corrected hashes named here. The original feature guardrail brief is unchanged.
