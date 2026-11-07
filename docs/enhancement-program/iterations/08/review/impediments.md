# Iteration08 pre-edit implementation contract

Recommend the bounded presenter below under accepted [ADR08](../decision.md). Root acceptance supersedes the ADR/coordination's historical pending wording; progress remains **7/50**. This is advice, without product edits, execution, delegation or private imports. The audit records full reads and source fingerprints.

## API and ownership handshake

| Owner / API | Exact contract |
|---|---|
| A: new `HarnessForgeWeb.PackageBuild.default_draft/0` | Returns `%{"name" => "my-harness", "version" => "0.1.0", "runtime" => "opencode", "runtime_version" => "unqualified"}`. |
| A: `PackageBuild.input/2` | `(event :: term(), current_generation :: String.t()) :: {:ok, draft} \| {:error, :invalid_draft} \| :stale`; envelope `%{"build_generation" => generation, "package" => draft}`. `draft` has exactly those four string keys. Output contains no generation or extra input. |
| A: `PackageBuild.name_only?/1` | `(reason :: term()) :: boolean()`; typed, exact classifier described below. |
| A: `PackageBuild.failure/1` | Takes the unwrapped error reason; returns `%{kind: :name \| :generic \| :runtime, message: String.t(), invalid_name: boolean()}` or `:delegate` only for explicitly listed existing safe atom reasons. No raw reason/message/details in output. |
| A: Portal private `reset_build/1` | Socket → socket; assigns fresh UUID `build_generation`, default `build_draft`, nil `build_outcome`. Mount invokes it; accepted failure stores only draft plus fixed outcome and fresh UUID `attempt`. |
| A → root: `package-build-focus` | `push_event("package-build-focus", %{generation: uuid, attempt: uuid})`; fixed destination `package-name`. No arbitrary ID/selector/payload text. |
| Root: existing native reset helper | Add only `build-form` to its allowlist and UUID-change branch; retain Company numeric-token behavior and export handler. No new library or global notice abstraction. |
| B: focused test ownership | Only `test/harness_forge_web/package_build_test.exs`; consume these exact APIs and real form. Root alone runs commands/native checks. |

A owns Portal and the new presenter; root owns JS. Before dispatch, conductor binds these signatures, DOM attributes and invalid/stale distinctions in both author prompts. A reports implemented signatures/source hashes to B and root; B reports authored oracles and proposed command to root. Corrections return to these same three authors.

## Classification and safe remedies

`name_only?/1` accepts only `%HarnessForge.Contracts.Error{code: "invalid_harness", details: details}` whose nonempty **proper** list contains at most100 entries, all exactly one of:

- `$.metadata.name: invalid format`
- `$.metadata.name: outside permitted bounds`
- `$.metadata.name: invalid string`
- `$.metadata.name: required`

Use bounded recursive consumption, rejecting unknown/improper tails without enumeration exceptions. `expected string`, fake maps, empty lists, path prefixes/suffixes and mixed name/version errors are false. These strings come from [Contracts](../../../../../lib/harness_forge/contracts.ex#L188), not an invented parser. Never inspect `message` to classify.

Name copy is exactly: “Use 1–64 characters. Start with a lowercase letter; then use lowercase letters, numbers, underscores or hyphens.” Generic copy is exactly: “Check the package values and approved inputs, then try building again.” Typed runtime codes `unsupported_runtime`, `invalid_runtime_intent`, `unsupported_required_control`, `runtime_unqualified` receive fixed runtime-specific remedies: choose a documented target/version; review approved runtime inputs; remove an unsupported required control; obtain qualified runtime/task evidence, respectively. Never delegate typed runtime `.message`, currently echoed by [Portal](../../../../../lib/harness_forge_web/live/portal_live.ex#L1258).

`:delegate` is limited to existing atom reasons `:no_approved_claims`, `:goal_claim_requires_plan`, `:privacy_operation_incomplete`, `:service_unavailable`, `:path_escape`, `:unsafe_directory`, `:invalid_input`, `:stale_or_revoked_evidence`, `:runtime_unqualified`; Portal reuses their existing fixed `error_message/1`. Other reasons use generic build guidance. Connector handlers/mappings remain intact and receive a genuine connector regression oracle.

## Draft, reset and focus lifecycle

Check generation before inspecting/storing draft. Missing, malformed or unequal generation returns `:stale`; Portal does nothing, preserving newer error/draft. With current generation, require a plain four-key map; each value must be binary, valid UTF-8 and at most4096 bytes; runtime must be `opencode`, `codex` or `claude_code`. Empty text reaches unchanged domain validation. Reject nonstrings, invalid bytes, extras and oversize atomically; call `reset_build/1`, show generic guidance and make **zero** domain calls. Never truncate, trim, normalize, stringify or compile defaults as a replacement. [Harnesses](../../../../../lib/harness_forge/harnesses.ex#L93) defaults missing values, so partial maps must not reach it. Ordinary rejected strings remain complete, including escaped quotes/angle brackets.

Render hidden top-level `build_generation`, four retained values and selected runtime. Set `build-form` attributes `data-build-generation`, `data-build-attempt` (current name outcome only), and `data-company-reset-token={@company_reset_token}`. Always render `package-name-help`; name failure additionally renders `package-name-error`, sets `aria-invalid="true"`, and associates both IDs through `aria-describedby`. Other outcomes remove name-invalid association. Preserve labelled `#error` build flash with its `Package build:` prefix; repeated builds replace it, and success clears it through existing `finish/3`.

Call `reset_build/1` from [reset_company_cache/1](../../../../../lib/harness_forge_web/live/portal_live.ex#L810): successful purge/restore, sibling reset broadcasts and revocation already converge there. Mount starts fresh. Also clear on Packages exit through `change_tab/2`, preventing hidden-form submission; require current Packages tab before domain invocation. Ordinary reload/polling retains state and emits no focus. Each new failure replaces outcome/attempt; success clears outcome/attempt and retains submitted valid draft. Reset clears both.

[JS](../../../../../assets/js/app.js#L73) must reset the connected form **and** LiveView's possible locked clone when build UUID changes, even when the Company counter decreases after remount. Otherwise a focused rejected value can survive server clearing. Reuse `resetCompanyControls`; numeric Company behavior stays unchanged. Focus handler accepts exactly two UUID fields; inside `requestAnimationFrame` rechecks current form generation/attempt, visible connected Packages/form/input, containment, no hidden/inert ancestor, and enabled text input `package[name]`. Only then focus. Old reset/failure/success focus deliveries fail; harmless rerenders do not steal focus. No `phx-change`, browser storage or asynchronous retry is needed.

## Oracles and bounded integration amendment

B uses real imported synthetic source, exact eligible claim approval and current form generation. `Bad Name` refusal retains all fields with nondefault Codex0.156.0; only correcting name succeeds once and exposes full digest. Snapshot artifact listings/directories/files and `harness.built` count before refusal; all stay unchanged. This build stores artifacts as files, so do not invent an artifact-row table. Assert no evaluation starts. Valid-name/bad-version and mixed failures are real domain negatives; classifier tests bind actual validator errors, all four name vocabularies, hostile sentinels and malformed tails. Cover a/64 valid, uppercase/digit/space/empty/65 invalid; UTF-8 byte boundaries4096/4097, malformed current input, stale/remount/reset/sibling/revocation, two failures, success, harmless reload and unchanged export/readiness generations. Malformed/stale input must call build zero times; calibrate tracing with a real admitted call.

Root needs one explicit ownership amendment: [export test line54](../../../../../test/harness_forge_web/package_export_test.exs#L54) submits a sparse generationless build and expects a flash. Replace only that setup with actual `#build-form` submission using `Bad Name`; preserve its export/prior-refusal oracle. Do not weaken stale rejection for compatibility.

Root records keyboard submit→correction→explicit retry, active element/next Tab, associations, visible focus and stale-focus reset. Native matrix: CSS320/390 × actual browser100/200% zoom; read zoom, capture full form/dimensions/screenshots and assert no document horizontal scroll/clipping. Root runs focused/affected/canonical checks prescribed by ADR08. Unchanged07 runtime reuse needs final hash justification; two baseline Dialyzer findings remain nonclean. Company qualification, comprehension, speech/full-WCAG and fresh MCP SDK compatibility remain unmeasured. Rollback is the bounded Portal/presenter/JS/test change; no domain/schema/data migration.
