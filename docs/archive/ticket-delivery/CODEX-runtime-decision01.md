# Codex runtime: extend the existing isolated coding lifecycle

**Status:** Proposed for Root implementation; execution compatibility unverified. **Date:** 2026-11-03. **Scope:** WEB-triggered Codex task, then matched baseline. Guardrails: [CODEX-runtime-guardrail01](CODEX-runtime-guardrail01.md). This decision grants no release authority.

## Context and evidence

The blocker is implementation: `adapters/registry.ex:27` advertises no Codex backend; `evaluations.ex:405` refuses non-OpenCode execution. `Coding` hardcodes OpenCode image/config/commands and identity; cleanup and applicability also specialize OpenCode. Removing one guard is insufficient.

Reuse `Coding`, `CodingTransport`, `Command`, `CodingSession`, `Relay`, `Models.Runtime`/Ledger, and protected `TaskSuite`. `test/native_agents/verify.cjs` already exercises Codex 0.156.0 config origins, instruction/skill discovery and malformed-agent rejection, but explicitly starts zero turns. Its Dockerfile is a parser fixture, not a qualified runtime image.

## Decision and ownership

Extend the lifecycle with a compiled-in target descriptor/driver; no caller-supplied images, commands, mounts or endpoints. Preserve OpenCode defaults and historical profile identities. Introduce a distinct versioned Codex profile. Three product authors maximum, including Root:

1. **Root:** `execution/coding.ex`, `evaluations.ex`, `adapters/registry.ex`, release/snapshot integration and WEB evidence presentation. Own admission, persisted context, target dispatch, lifecycle and applicability; sole executor/board writer.
2. **Runtime author:** new `execution/codex.ex`, fixed container driver/image recipe, focused adapter tests. Descriptor supplies immutable image/CLI/protocol versions, canonical overlay, fixed smoke/task argv, and strict output/config validators. Reuse native probe code; keep `adapters/codex.ex` export bytes/preview semantics intact.
3. **Protocol author:** `models/runtime.ex`, new `models/codex_protocol.ex`, `execution/relay{,_plug}.ex`, Codex-specific proxy template and protocol tests. Preserve existing Chat route behavior.

Mount exact exported artifact read-only at `/approved`, with read-only discovery mounts at the task project's `AGENTS.md`, `.codex` and `.agents`; task files alone remain writable. Use fresh container HOME/session storage, never host login/config. Keep nonroot/read-only-root/cap-drop/resource limits/internal network; only the fixed authenticated relay path is reachable. Protected tests remain in the separate offline grader. Verify mounts and artifact hashes before/after; sanitize and bound stored runtime events, candidate diff and grader output for inspection, not merely hashes.

## Protocol and pinning contract

Before inference, Root must inspect the exact isolated binary's schema/help and effective configuration. Reuse its app-server `config/read`, `skills/list`, `thread/start` discovery; explicitly verify applicable exported instructions, provider/model, denied connectors, approval behavior and config origins. Reject warnings, unsupported keys or unverified effective overrides. Use fixed noninteractive `exec --json` only after its exact flags/event schema are verified. Unexpected approval requests fail; never silently weaken policy.

Current Relay accepts only `/v1/chat/completions`; Runtime converts this to Ollama `/api/chat`. `OpenAIResponses` is cloud authoring with tools disabled, not a runtime bridge. Prefer verified Codex Chat support if the pinned binary actually supports it. Otherwise implement a bounded Responses codec through the same Runtime reservation/dispatch/reconciliation path: text, function calls/results and correlated SSE completion/error events only. Reject unknown tools/content, remote state, unsupported continuation and protocol/version drift. Never fabricate model output or forward directly around Ledger. If native Codex tools require unsupported semantics, report that incompatibility before dispatch.

Persist artifact/manifest, runtime-overlay/effective-config, image ID/digest, CLI, protocol, suite/fixture/grader, model-settings, actual model-content/service-version, environment/transport and limit pins. Current `Ollama.available` checks tags/name/remote markers only; it does not establish immutable model identity or tool capability. Add bounded observation/revalidation before send and completion; unavailable stable identity blocks comparable qualification. Relay capability remains ephemeral/redacted.

## Failure and recovery

Reserve every actual attempt; disable hidden retries or meter each retry separately. Unknown tokens remain unknown, never zero-cost success. Nonzero exit, incomplete events, failed protected tests, changed pins, revoked/held sources or uncertain cleanup cannot pass. Persist original daemon/run ownership before resources. Extend `stored_observation`, `owned_observation`, cleanup dispatch and reconciliation together; revoke relay, stop owned containers, verify removal, retain cleanup failures for restart retry. Cancellation must beat late success. Restore removes authority and requires reevaluation. Preserve separate claim approval, plan approval and current eligibility checks.

## Qualification and consequences

Root first verifies versions/config/discovery and negative containment, then runs one real local-model Codex task with inspectable edit/events and protected test results. Next run fresh harness/no-harness pairs: identical task, model, runtime, limits, grader and infrastructure overlay; remove only harness guidance, record that delta. Compare outcomes, failures, elapsed time and reported usage; one pair establishes only finite observations, not general benefit.

Represent baseline as an explicit evaluation treatment, never a fabricated approved artifact or release candidate. Pair identity includes limits/protocol/model-content/overlay pins; store each arm's distinct guidance digest. Preserve unsuccessful attempts in the comparison. WEB results must retrieve evidence under current workspace/artifact eligibility and retain sanitized bounded text separately from immutable hashes.

Test matrix: OpenCode regression; malformed protocol/tool correlation; budget/unknown usage; configuration/model/daemon drift; source revocation; time/output limits; cancellation/restart/restore; failed grader; mount/network escape; baseline contamination. Static, runtime, task, benefit and release remain independent.

Alternatives rejected: second sandbox engine, host execution, paid fallback, relabeling export success. Cost: a version-specific protocol codec and qualification maintenance. Blockers currently unknown: selected local service/model, tools/protocol compatibility, immutable model pin and usable Codex image. The historical default Ollama refusal is not current availability evidence.
