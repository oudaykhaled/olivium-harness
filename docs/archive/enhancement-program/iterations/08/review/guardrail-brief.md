## GUARDRAIL BRIEF — bounded package-name refusal, draft correction and explicit retry

**Classification:** standalone Phoenix UI · input/presentation/privacy lifecycle · additive · no shared Olivium surface; repository AGENTS.md explicitly establishes standalone ownership. Reversible UI change; schema/compiler/publication remain authoritative.

**Verdict:** PROCEED-WITH-CONDITIONS — root freezes the following author/test handshake and the small existing-test ownership amendment before author edits. No additional user permission gate.

**Guardrails that apply to THIS request (ranked, most binding first):**

1. **[AGENTS.md; accepted decision.md, Decision/Confirmation] Reject unsafe submission before invocation.** A owns PortalLive and optional `HarnessForgeWeb.PackageBuild`; recommend that pure module so B can test hostile terms directly. Export these APIs:

| API | Parameter / return contract |
|---|---|
| `defaults/0` | Four string keys: `name=my-harness`, `version=0.1.0`, `runtime=opencode`, `runtime_version=unqualified`. |
| `input/2` | Whole event payload, current UUID generation → `{:ok, four_field_map}`, `:stale`, or `:invalid`. |
| `classify/1` | Error reason → `:name`, `:generic`, `{:runtime, fixed_code}`, or `{:known, fixed_atom}`. |
| `message/1` | Classification → fixed string; never accepts/interpolates diagnostic text. |

`input/2` first requires a plain package map and matching string `generation`; missing/mismatched generation returns `:stale`, without modifying current draft, notice or focus. For matching generation require exactly `generation,name,version,runtime,runtime_version`. All four values must be binaries, valid UTF-8, at most4096 bytes; runtime must equal `opencode`, `codex` or `claude_code`. Empty text is structurally safe and reaches domain validation. Any malformed/oversized field rejects the entire submission, clears the entire retained draft to defaults, displays fixed generic guidance, and invokes no compiler. Defaults are render-only after rejection; never compile defaults or a truncated/sanitized replacement. Successful input returns exactly the four original values, stripping generation only. No trimming, coercion, dynamic atoms, raw HTML, persistence, audit payload or browser storage. Test4096/4097-byte boundaries and multibyte byte counts.

2. **[decision.md, Decision; contracts.ex:199–259,323] Classify exact typed errors only inside build.** `:name` requires `%HarnessForge.Contracts.Error{code: "invalid_harness", details: details}` with a nonempty proper list, at most100 entries (validator ceiling), every entry exactly one of:

- `$.metadata.name: invalid format`
- `$.metadata.name: outside permitted bounds`
- `$.metadata.name: invalid string`
- `$.metadata.name: required`

Duplicates are harmless. Use bounded recursive matching so improper lists cannot crash or unbounded lists force a full traversal. Ignore message/correlation/retryability. Mixed, empty, unknown, non-list, lookalike and forged plain-map errors become `:generic`. Name copy: “Use 1–64 characters. Start with a lowercase letter; then use lowercase letters, numbers, underscores or hyphens.” Generic copy: “Check the package values and approved inputs, then try building again.” Never use substring matching or expose raw error fields.

Preserve known atom remedies through an explicit build-only allowlist referencing existing `error_message/1`: `no_approved_claims`, `goal_claim_requires_plan`, `stale_or_revoked_evidence`, `runtime_unqualified`, `privacy_operation_incomplete`, `service_unavailable`. Unknown atoms remain generic. Typed runtime codes retain differentiated fixed remedies: `unsupported_runtime` → “Choose a supported runtime target and version.”; `invalid_runtime_intent` → “Review approved runtime instructions and permissions, then build again.”; `unsupported_required_control` → “Review required controls against the selected runtime’s supported controls.”; `runtime_unqualified` → “Use a supported runtime version or unqualified for a native preview.” Amend wording only with UI adviser agreement. Existing build branch echoes runtime `message`; bypass that branch for build. Connector operations keep their existing mapping unchanged.

3. **[decision.md, draft/privacy edges; portal_live.ex:784–825; app.js:29–88] Fence lifecycle changes.** A adds private `reset_build/1`, assigning defaults, nil outcome and fresh UUID `build_generation`; call at mount and from `reset_company_cache/1`, which already covers successful purge/restore, broadcasts and operator revocation. Add `phx-auto-recover="ignore"`, hidden `package[generation]`, `data-build-generation`, and existing `data-company-reset-token` to `build-form`. A rotates generation on each current-generation attempt, including success and malformed rejection; a refused valid draft remains exact. Accepted success removes local correction and uses existing success flash. Harmless reload/poll retains state and generation. Remount creates a new UUID. Delayed old submissions are no-ops, including after newer errors.

Root reuses `resetCompanyControls` and extends the prepatch callback specifically for `build-form`: reset its connected DOM and locked clone when numeric reset token increases OR UUID changes. Server-provided retained values make attempt rotations safe; private reset uses defaults. Do not change company/export/readiness behavior. UUID change covers remount where numeric token returns to0. No change event is needed: retention begins on explicit submission.

4. **[decision.md, native keyboard acceptance; app.js:149–184] Bind focus to the current outcome.** A pushes `package-build-focus` with exactly `%{generation: uuid, kind: "name"}` only after a fresh name-only refusal. Form attributes expose current generation and `data-build-outcome="name"`; `package-name` has `aria-invalid="true"` only then and `aria-describedby="package-name-help package-name-error"`. Fixed help is always present; one conditional fixed error owns `package-name-error`. Root’s handler validates exact payload keys, UUID and kind, then inside requestAnimationFrame rechecks connected visible package panel/form, matching generation/current name outcome, contained enabled text input named `package[name]`, and no hidden/inert/aria-hidden ancestor before focusing. Consume each generation once; never focus on ordinary rerender, success, generic failure or stale delivery. New failure gets a new generation. Existing visible-target/export guard logic is the pattern, not an invitation to generalize notices.

**Hard STOPs (do NOT do):**

- Do not modify compiler/schema/domain authority, automatically retry, start evaluation, echo rejected unsafe values or publish on refusal.
- Do not accept missing generation to preserve a legacy test. Do not clear newer outcomes on stale events.
- No adviser runtime/browser/Mix execution, private imports, external KB edits or fourth product author.

**Definition of done for this request:**

- [ ] A sends B/root final API symbols, assign names, DOM attributes and event shape before parallel edits. B owns new focused tests. Root explicitly amends B’s ownership for the single existing `package_export_test.exs:54` submission: use current form plus all fields and invalid name, preserving its `#error` and export-preservation assertions. Keep a labeled build flash alongside inline correction for compatibility; do not change unrelated flash ownership.
- [ ] Root tests actual approved synthetic evidence: invalid name leaves artifact rows/files and `harness.built` unchanged; explicit corrected retry creates the immutable digest, clears correction, starts no evaluation. Bind classifier tests to real Contracts output; test1/64 valid and empty/65/uppercase/digit/space invalid, valid-name/non-name and mixed faults, hostile messages/details, supported nondefault runtime, sequential failures and all reset/stale cases. Browser required interception differs from direct submission.
- [ ] Root verifies native keyboard correction/next Tab, DOM/AX association, visible focus, and complete form fit at CSS320/390 × actual100/200% browser zoom; record measured zoom, dimensions, no horizontal overflow, reset while focused and stale focus rejection. Screenshots do not establish speech/full WCAG or comprehension.
- [ ] Root runs focused/affected regressions, canonical suite and accepted compile/format/Credo checks, records source-bound actual results and independent reviews. Retain07 evidence limits and exactly two baseline Dialyzer findings if that gate runs. Progress remains7/50 until root closure.

**Knowledge base:** unchanged. Canonical external Codex-ui paths were unavailable; no rules were invented from them. Local AGENTS.md and root-accepted ADR govern this standalone request. Advice only; no runtime verification claimed.
