## GUARDRAIL BRIEF — Explain successful static inspection without implying attempted cleanup

**Classification:** standalone Phoenix component · presentation/regression only · additive, reversible · SHARED: no fleet service change; repository [AGENTS](../../../../../AGENTS.md) identifies a standalone application. No contract, domain, persistence or execution change.

**Verdict:** PROCEED-WITH-CONDITIONS

**Guardrails that apply to THIS request (ranked, most binding first):**

1. **Preserve admission and abstention.** [ADR04](../decision.md), [accepted03 amendment](../../03/decision-amendment.md): change explanation only. Preserve the complete report maps, seven stage names/statuses/reasons, blockers, cleanup **Blocked** / recorded **Not started**, exact identities, next-action code/destination and release refusal. OpenCode current task identity, applicability and admission remain **Not assessed**; historical identities confer no current authority. **Check:** compare actual Inspect/Refresh results with the unchanged domain report; static integrity never becomes qualified task execution or approval.

2. **Require the complete narrow predicate.** [ADR04](../decision.md): evaluation must contain `kind=static_integrity`, `outcome=passed`, `status=passed`; cleanup must contain `status=blocked`, `reason_code=evaluation_cleanup_incomplete`, `cleanup_status=not_started`; release admission must contain `status=blocked`, `reason_code=qualified_task_evaluation_required`. Only then use the accepted integrity-only/no-attempt/qualified-task explanation in the cleanup row. Replace summary wording only when existing priority selects cleanup; visible summary and polite announcement share that summary function. **Check:** earlier integrity, eligibility, unsupported-runtime and evaluation warnings retain precedence. Contradictory, missing or unknown predicate values must not qualify.

3. **Keep inspection command-free and private.** [03 amendment](../../03/decision-amendment.md), [AGENTS](../../../../../AGENTS.md): introduce no I/O, domain call, worker, profile resolution or dynamic metadata rendering. Preserve reason/action/identity allowlists, authentication nonce/generations, exact-pair selection, privacy fence and reset invalidation. **Check:** retain calibrated actual-event/domain no-probe traces, including Command/docker/endpoint/invoke, Port/open_port, System.cmd and live-bearing profile helpers; exclude setup/mount explicitly. Keep stale-submit, switching, remount, reload, revocation, purge/restore and private-sentinel regressions meaningful. Contextual copy disappears whenever its report clears.

4. **Honor disjoint ownership.** [ADR04](../decision.md), [conductor](../../../conductor.md): A owns only `lib/harness_forge_web/components/package_readiness.ex`; B owns only `test/harness_forge_web/package_readiness_test.exs`. No Readiness, Portal, shared, dependency, configuration or domain edits. Preserve other authors’ changes. Root owns board/state, candidate freeze, serialized Mix, native/CUA/browser/build/service operations and existing main03/MCP processes. This reviewer writes only this brief; no execution or service changes.

5. **Make evidence specific and bounded.** [PROGRAM](../../../PROGRAM.md), [ADR04](../decision.md): positive evidence uses a genuine persisted static evaluation through Inspect/Refresh. Contrast task cleanup failure, failed/blocked task, smoke, incomplete/unknown static metadata, no run and missing/foreign/cross-artifact selection. Clearly label inert task fixtures as rendering evidence. Report fresh commands, exits and provenance; historical passes/skips are not04 results. No novice-study, screen-reader-certification, live-model qualification or company-fitness claim is required or established.

**Hard STOPs (do NOT do):**
- Hide a real cleanup failure, override an earlier blocker, weaken a gate, or borrow historical task identity.
- Add probes, private imports, paid calls, credential extraction, remote writes, host execution of generated code or competing runtime operations.

**Definition of done for this request:**
- [ ] Focused positive/negative rendering and real-event checks pass; report semantics, clearing and navigation remain unchanged.
- [ ] Root records focused/canonical tests, format, warning-gated compile, Credo, packaging/inventory, JS and zero new Dialyzer findings beyond the two documented baselines.
- [ ] Root verifies native static/blocked-task/no-run/reset, keyboard Evaluations destination/next Tab, measured320/390 CSS widths and actual200% zoom; saves screenshots/AX, frozen-source/process provenance and bounded before/after hashes.

**Knowledge base:** unchanged. Configured external Codex-ui AGENTS/guardrails files are absent; available repository authorities cover this request. Source/document review only; no tests, Mix, browser or services ran.
