## GUARDRAIL BRIEF — native relay argument and approval boundary

**Classification:** Standalone HarnessForge execution boundary · additive private protocol/security change · no shared fleet service (AGENTS.md:3).

**Verdict:** PROCEED-WITH-CONDITIONS for the disabled seam; repair F1 before native-controller qualification. No blocking user question.

**Guardrails that apply to THIS request (ranked):**
1. **F1 — stale approval remains deliverable after continuation.** In relay.ex:309–339, matching call/result history can advance the pending call without checking a recorded approval's disposition. In :424–434, polling checks driver nonce and request digest but ignores the binding's stored call_id. Consequently, within one open driver, record/accept A, submit A's continuation producing B (or no call), then poll A: relay currentness still permits consumption of A. This is a source-proven missing lifecycle fence, not an observed native execution. Require the polled binding's call_id to equal native_pending_call before consumption, and reject continuation while that call has an unresolved recorded approval. Reuse existing approval state; do not invent another authority engine. Native errors or safe commands without callbacks must remain distinguishable from unresolved recorded approvals.
2. **Preserve exact publication and authority fences.** codex_command_policy.ex and runtime.ex:145–195 constrain original argument bytes before SSE publication, while valid provider usage settles first. relay.ex:463–481 rechecks revocation, configuration, sources and running model/tools identity; relay_plug.ex denies Origin and requires the capability. Keep these checks on every relevant transition. Advisory commandActions/proposed amendments grant nothing; acceptForSession is never a deliverable grant. The inspected supplied contract's decision example is accepted without enabling amendments.
3. **Retain execution prohibition until qualification.** AGENTS.md:10–13 and CODEX-native-bridge-contract03.md require native parent/proc/fd/network isolation evidence and real callback correlation. Root reports task_argv remains codex_command_bridge_unqualified and the native controller absent. The reviewed native_commands flag defaults false. Source configuration and synthetic fixtures establish neither confinement nor editing success.

**Hard STOPs:** No host generated execution, permission broadening, paid fallback, candidate exposure to private control credentials, or company/task qualification from these tests.

**Definition of done for this request:**
- [ ] Root adds a regression for accept-A → continuation-before-poll → stale-A polling, alongside the legitimate consumed-A continuation path; rejection must not deliver an acceptance.
- [ ] Cancellation/configuration drift still withhold delivery, and rejected argument publication still settles usage.
- [ ] Controller remains unavailable pending its separate native qualification.

**Knowledge base:** Unchanged. Scope excludes Domain/SQL/WEB, independently reviewed by Astra. No commands/tests/runtime actions performed. Root's 101 focused passes and earlier 1282 baseline are reported evidence, not this review's execution. Exact pins, read ranges and truncation limits accompany the audit.
