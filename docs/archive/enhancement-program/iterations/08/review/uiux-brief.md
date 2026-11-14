# Iteration 08 UI/UX pre-edit contract

Advisory only, by `/root/i08_conductor/advice08_uiux`. Root accepted [ADR08](../decision.md) through `root-scope-acceptance.json`; its older pending-acceptance header is historical. One benefit remains selected: truthful package-name refusal, retained submitted draft and explicit corrected retry. Progress remains **7/50**. I read current source, not a Figma design; this standalone repair introduces no private design-system dependency, permission gate or human-study prerequisite. No application, test, browser or native action was executed.

## Author and test handshake

A owns Portal and the optional new `HarnessForgeWeb.PackageBuild` presenter; B owns the new focused test file; root owns bounded JS and all execution. Prefer the presenter, following the existing [PackageExport pattern](../../../../../../lib/harness_forge_web/package_export.ex#L1). Agree these names before either author starts:

| Proposed exported API, owned by A | Parameters and exact result |
|---|---|
| `PackageBuild.defaults/0` | `%{"name" => "my-harness", "version" => "0.1.0", "runtime" => "opencode", "runtime_version" => "unqualified"}` |
| `PackageBuild.input/2` | `(params :: term(), current_generation :: String.t())` → `{:ok, draft}` or `{:error, :stale_form | :invalid_draft}`. Wrapper contains `"package_build_generation"` and `"package"`; draft has exactly the four string keys above. Ignore unrelated Phoenix wrapper metadata; reject extra draft keys. |
| `PackageBuild.classify_error/1` | `(reason :: term())` → `:name`, `:package`, `{:existing, reason_atom}` or `{:runtime, code_string}`. These tags are presentation only. |
| `PackageBuild.copy/1` | Fixed strings for `:name_help`, `:name`, `:package` and the four whitelisted `{:runtime, code}` tags below; no input interpolation. |
| Portal private seams | `reset_build/1 :: socket → socket`; `build_message/1 :: reason → String.t()`. Assigns are `build_draft`, `build_generation` and `build_name_error` (boolean). Existing `finish/3`, `reload/1`, authentication and domain build stay authoritative. |
| Root JS seams | Extend local `resetCompanyControls(form, freshForm, generationAttribute = "data-company-reset-token")`; add local `resetBuildFormBeforePatch(fromEl, toEl)`. Existing `onBeforeElUpdated` calls both reset wrappers. External focus event is `phx:package-build-focus`, exact payload `{kind: "name", generation: UUID}`. No new browser-global function. |

### Classification and copy

Only `%HarnessForge.Contracts.Error{code: "invalid_harness", details: details}` can classify `:name`. Require a proper nonempty list of at most 100 entries, every entry equal to one of:

```text
$.metadata.name: invalid format
$.metadata.name: outside permitted bounds
$.metadata.name: invalid string
$.metadata.name: required
```

These come from [check/type and required errors](../../../../../../lib/harness_forge/contracts.ex#L198), [string/bounds errors](../../../../../../lib/harness_forge/contracts.ex#L269) and [bounded error construction](../../../../../../lib/harness_forge/contracts.ex#L323). Mixed details, empty/malformed lists, lookalikes, plain maps and unknown reasons become `:package`. Never inspect arbitrary text for substrings or display `message/details`.

`:name_help` is exactly **“Use 1–64 characters. Start with a lowercase letter; then use lowercase letters, numbers, underscores or hyphens.”** `:name` is **“Check Package name.”** `:package` is **“Check the package values and approved inputs, then try building again.”**

Preserve existing atom remedies through `{:existing, reason}` only for `:no_approved_claims`, `:goal_claim_requires_plan`, `:privacy_operation_incomplete`, `:cleanup_failed`, `:jobs_still_executing`, `:evaluations_still_running`, `:runtime_unqualified`, `:source_unavailable`, `:stale_or_revoked_evidence`, `:service_unavailable`; Portal reuses `error_message/1`. Other atoms default to `:package`. Typed runtime errors receive fixed copy, because [the current mapper echoes their messages](../../../../../../lib/harness_forge_web/live/portal_live.ex#L1258):

| Typed runtime code | Fixed build-only remedy |
|---|---|
| `unsupported_runtime` | Use a supported coding agent target and runtime version listed below. |
| `invalid_runtime_intent` | Review approved inputs for the selected coding agent target, then build again. |
| `unsupported_required_control` | The selected coding agent cannot represent a required control. Review approved inputs or choose a compatible target. |
| `runtime_unqualified` | Use a supported runtime profile. Managed execution requires a separately qualified runtime and backend. |

Connector operations keep their current mapper and remedies. No global error-map rewrite is required.

## Draft, reset and focus lifecycle

After validating generation first, require a plain draft map, all four values binary and valid UTF-8; three text fields allow 0–4096 bytes each, while runtime must equal `opencode`, `codex` or `claude_code`. Reject NUL-containing text to avoid DOM value substitution. Empty text reaches the unchanged domain validator through direct server submission; native `required` interception remains separate. Preserve accepted bounded strings exactly through ordinary HEEx `value`/`selected` attributes, including whitespace and escaped markup; no trim, normalization, truncation or replacement compilation. A current malformed/oversized submission invokes no build, clears the entire draft to defaults and gives fixed generic guidance. A stale/missing/malformed generation is a no-op: it cannot erase a newer result or retain any payload.

Use one fresh UUID generation at mount, **every accepted current submission**, current invalid-draft clearing, and `reset_build/1`. Keep generation unchanged on ordinary `reload/1` and polling. Each real submission stores its bounded draft, rotates generation, clears prior name error and runs the existing build once. Failure then sets only the new outcome; success removes the field error and uses the existing immutable-package success flash. Typing alone keeps the last response until explicit retry. Retaining the submitted valid draft after success is acceptable. No `phx-change` or automatic retry is needed.

Call `reset_build/1` from mount and `reset_company_cache/1`, covering successful purge/restore, reset broadcasts and revocation before redirect. Also clear on leaving Packages, matching export's existing tab lifecycle; returning presents fresh defaults. Set `phx-auto-recover="ignore"` on `#build-form`. Its hidden `package_build_generation` and `data-build-generation` agree. The build reset wrapper compares valid UUIDs for **inequality**, so a remount cannot fail the existing numeric-increase test. Reuse control clearing on both `fromEl` and the connected form/locked clone. Do not change Company/export/readiness generation semantics.

## Visible controls and keyboard behavior

Keep the existing layout, labels and button. Always show `#package-name-help` immediately beside `#package-name`. Only a name-only refusal adds `#package-name-error` with “Check Package name.” and existing `form-error` styling. Set `aria-invalid="true"` and `aria-describedby="package-name-help package-name-error"`; otherwise omit invalid and describe only help. Keep both text nodes outside Tab order. The existing `#error` alert contains the short `Package build: Check Package name.` summary; inline text has no second alert/live role. Other build refusals use the fixed or preserved remedy in that same alert, without marking Package name invalid. This preserves existing known-remedy selectors and avoids another notice system.

Emit focus only for a new name-only refusal. Inside `requestAnimationFrame`, require exact payload keys/types, current generation, `build_name_error` reflected by `data-build-name-error="true"`, visible connected Package panel/form, and a contained enabled text input with exact ID/name `package-name` / `package[name]`. Reject hidden/inert/aria-hidden ancestors as export already does. Consume each generation once. Focus the input without selecting/replacing text. Next Tab reaches Package version, then Coding agent target, Runtime version and Build. Harmless rerenders emit no focus. Success/reset/new failure invalidates queued old focus; reset does not introduce a focus jump. The rule stays visible; runtime qualifications remain in their existing explanatory paragraph.

## Verification handoff and bounded amendments

B's tests must exercise actual eligible approved synthetic evidence through refusal/retry: `Bad Name` preserves all four nondefault values; artifact rows/files and `harness.built` events remain identical; correcting only the name yields one explicit successful build/full digest and no evaluation. Bind classifier tests to actual validator errors. Cover one-/64-character positives; uppercase, leading digit, spaces, empty and 65-character negatives; valid-name/non-name failure; mixed/unknown/hostile details; known runtime/connector remedies; 4096/4097-byte and multibyte bounds; map/list/non-string/non-UTF-8/NUL input; repeated failure, harmless reload, reset broadcasts, revocation, remount and stale replay. Assert stale events cannot clear newer error/draft. Preserve prior valid-fixture digest identity.

Necessary ownership amendment: [PackageExportTest:54](../../../../../../test/harness_forge_web/package_export_test.exs#L54) directly submits a partial build envelope without generation. Root should assign B that one test setup change: use the current form with all fields and a supported runtime plus unsupported runtime version, retaining its build-flash/export-preservation oracle. Do not weaken generation checks to accommodate it. Existing form-based Coding/Goal tests naturally include hidden generation.

Root alone records four native cases: CSS **320/100%, 390/100%, 320/200%, 390/200%**, using actual browser zoom. For each retain complete ordinary screenshots, zoom reading, `innerWidth`, document/client/scroll widths, control/error bounds and DOM/AX associations. Record keyboard refusal → focused correction → next Tab → valid explicit retry, plus focused reset/stale-focus delivery. Require visible focus, complete wrapping, reachable controls and no document horizontal scroll. Failures return to the same owners; CSS scope needs an explicit amendment only if actual evidence requires it. Existing focus CSS is unmeasured here. These observations establish bounded keyboard/fit behavior; speech, full WCAG, novice comprehension and company qualification remain unmeasured. No implementation or verification is claimed by this brief.
