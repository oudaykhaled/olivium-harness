# Iteration08 accepted-scope implementation interface

Root accepted the single benefit in ADR08: package-name build refusal, bounded retained draft and an explicit corrected retry. This consolidates three frozen advisers after conductor full-read; the same fresh08 Guardrail Astra resolved their API/envelope/token differences. It does not rewrite the original advice, ADR, planning reports or completion records. Root must full-read this concrete handoff before author dispatch. Progress remains7/50; nothing is implemented or executed by this phase.

## Owners and initial handshake

| Owner | Exclusive implementation ownership |
|---|---|
| A — Principal Elixir / OTP Engineer | `lib/harness_forge_web/live/portal_live.ex`; new `lib/harness_forge_web/package_build.ex` with the API below. |
| B — separate Principal Elixir / OTP Engineer | New `test/harness_forge_web/package_build_test.exs`; **bounded amendment:** only the prior-build-refusal setup at `test/harness_forge_web/package_export_test.exs:54`. |
| Root | Bounded `assets/js/app.js` reset/focus integration; all commands, native/browser/DB/process evidence and shared integration. |

There are at most three distinct product authors across implementation and corrections. A confirms these exact public symbols, assigns, DOM attributes and payloads to B/root before parallel edits. B writes against this interface and reports proposed commands; root alone runs them. No CSS/schema/compiler/domain/router/config/migration/dependency change is planned. No fourth author or new user flow is authorized.

## Frozen pure presenter API

Module: `HarnessForgeWeb.PackageBuild`, owned by A. Do not export the differing advisory aliases (`default_draft`, `name_only?`, `failure`, `classify_error`, `copy`).

| API | Exact contract |
|---|---|
| `defaults/0` | `%{"name" => "my-harness", "version" => "0.1.0", "runtime" => "opencode", "runtime_version" => "unqualified"}` |
| `input/2` | `(event :: term(), current_generation :: String.t())` → `{:ok, four_field_map}` or `:stale` or `:invalid` |
| `classify/1` | `(unwrapped_reason :: term())` → `:name`, `:generic`, `{:runtime, code_string}` or `{:known, atom}` |
| `message/1` | Fixed strings for `:name_help`, `:name`, `:generic` and the four allowed `{:runtime, code}` tags. Never takes raw diagnostics. Portal handles `{:known, atom}` through its existing fixed `error_message/1`. |

**Envelope:** use nested `package[generation]` exclusively, not either proposed top-level alias. Ignore unrelated top-level Phoenix metadata without retaining/forwarding it. The nested plain map has exactly `generation`, `name`, `version`, `runtime`, `runtime_version`. Missing/malformed/mismatched generation is `:stale`; check it before retaining other fields. Current generation with extra keys or malformed fields is `:invalid`. Successful input returns only the four original field values; generation never reaches `Harnesses.build/1`.

All four values are binaries, valid UTF-8 and at most4096 bytes. Runtime is exactly `opencode`, `codex` or `claude_code`. Retained text rejects U+0000, U+000A and U+000D before invocation; this also excludes those characters from any runtime string. Root verified the [WHATWG text-input standard](<https://html.spec.whatwg.org/multipage/input.html#text-(type=text)-state-and-search-state-(type=search)>), whose newline stripping would otherwise change a rejected value on retry. The same Guardrail Astra explicitly acknowledged this narrow refinement. Preserve every other admitted string exactly: no trimming, coercion, normalization, truncation or replacement compilation. Empty text is structurally admissible for direct server submission and reaches existing domain validation; browser `required` interception is a distinct observation.

## Classifier and fixed copy

`:name` requires typed `%HarnessForge.Contracts.Error{code: "invalid_harness", details: details}` with a nonempty proper list of at most100 entries, each exactly one of:

```text
$.metadata.name: invalid format
$.metadata.name: outside permitted bounds
$.metadata.name: invalid string
$.metadata.name: required
```

Bound recursive list consumption; reject improper tails/overlong lists without full unbounded traversal. Duplicates are harmless. Empty/mixed/unknown/lookalike detail strings, malformed shapes, plain maps and unknown reasons are `:generic`. Do not inspect/interpolate arbitrary `message`, details or other error fields. Name matching is never substring-based.

- `message(:name_help)`: **Use 1–64 characters. Start with a lowercase letter; then use lowercase letters, numbers, underscores or hyphens.**
- `message(:name)`: **Check Package name.**
- `message(:generic)`: **Check the package values and approved inputs, then try building again.**

| Typed runtime code | Exact build-only fixed remedy |
|---|---|
| `unsupported_runtime` | Use a supported coding agent target and runtime version listed below. |
| `invalid_runtime_intent` | Review approved inputs for the selected coding agent target, then build again. |
| `unsupported_required_control` | The selected coding agent cannot represent a required control. Review approved inputs or choose a compatible target. |
| `runtime_unqualified` | Use a supported runtime profile. Managed execution requires a separately qualified runtime and backend. |

The exact known-atom allowlist is `no_approved_claims`, `goal_claim_requires_plan`, `privacy_operation_incomplete`, `cleanup_failed`, `jobs_still_executing`, `evaluations_still_running`, `runtime_unqualified`, `source_unavailable`, `stale_or_revoked_evidence`, `service_unavailable`. Classify these as `{:known, atom}` and reuse their current fixed Portal clause. Other atoms are generic. Typed runtime `.message` is never delegated. Connector operations and their mapper remain unchanged.

## Portal lifecycle and DOM

A adds private `reset_build/1`, assigning `build_draft=defaults`, fresh UUID `build_generation`, nil `build_outcome`. `build_outcome` holds only the safe classification tag when a current refusal exists. No separate attempt token, controls token or boolean assign is needed.

Require the current Packages tab before build-state mutation/domain invocation. Stale/missing generation or off-tab submission is a total no-op: preserve newer draft, notice, generation and focus. A current valid submission retains its exact four values, rotates the UUID, clears previous build outcome and invokes the existing builder once. Classify failure, replace the prior build flash and retain the bounded draft; success clears correction/outcome through existing success/flash behavior and retains the submitted valid draft. No automatic retry, evaluation or inference starts. A current `:invalid` clears the entire draft to render-only defaults, rotates UUID, shows generic build guidance and invokes the domain zero times. Defaults are never compiled as replacements.

Call `reset_build/1` at mount, from `reset_company_cache/1`, and when leaving Packages via `change_tab/2`. These seams cover successful purge/restore, sibling reset broadcasts, revocation before redirect and remount. Harmless reload/polling preserves draft/outcome/generation and emits no focus. Reset clears the build-owned outcome/field correction; preserve unrelated existing flash ownership.

`#build-form` has `phx-auto-recover="ignore"`, hidden `package[generation]`, `data-build-generation`, existing `data-company-reset-token`, and `data-build-outcome="name"` only for a current name failure. Keep the existing four input IDs/names, labels and button. Always render full `#package-name-help`. Only a name failure renders non-live `#package-name-error` with **Check Package name.**, sets `#package-name[aria-invalid="true"]`, and uses `aria-describedby="package-name-help package-name-error"`; otherwise describe help only and omit invalid. The existing single `#error` alert contains **Package build: Check Package name.** on name refusal. Other failures use `Package build: ` plus their fixed remedy. Inline correction adds no second live/alert role. Help/error are outside Tab order; next Tab from Package name reaches Package version, Coding agent target, Runtime version, Build.

## Root JS seam

Extend existing control-reset logic only for `#build-form`: compare valid build UUIDs for **inequality**, independently of Company's numeric reset counter. On change reset the connected form and possible LiveView locked clone from fresh server controls. This handles per-attempt preservation, unsafe-input clearing and remount where the Company counter can decrease. Keep Company/export/readiness behavior unchanged.

A emits `push_event("package-build-focus", %{kind: "name", generation: uuid})` only after a new name-only refusal. Root's listener requires exactly those payload keys/types. Inside `requestAnimationFrame`, recheck current generation/outcome, visible connected Package panel/form, exact contained enabled `#package-name[name="package[name]"]` text input, and no hidden/inert/aria-hidden ancestor. Consume each generation once; focus without replacing/selecting text. No arbitrary destination/payload text or new browser-global function. Success/reset/new refusal/tab exit invalidates delayed old focus. Ordinary rerender never steals focus.

## Test and native handoff

B amends only the legacy export-test setup to submit the actual current `#build-form`, all four otherwise-valid values and `Bad Name`. Retain every prior build-flash and export-preservation assertion. Do not bypass generation checks or change the tested export contract.

New focused tests bind classification to real validator output and eligible approved synthetic evidence. Actual `Bad Name` refusal retains four nondefault fields, produces fixed correction and changes neither artifact file inventory nor `harness.built` count; correcting only the name yields one explicit immutable build/full digest and no evaluation. Artifacts are files: do not invent an artifact-row table. Cover1/64 valid and empty/65/uppercase/digit/space invalid names, valid-name/non-name/mixed faults, hostile detail/message sentinels, proper/improper list bounds, known runtime/connector remedies,4096/4097 UTF-8 byte limits, non-string/map/list/invalid UTF-8/NUL/CR/LF input including `0.1.\r\n0`, stale replay preserving newer errors, off-tab/tab-exit/reset/broadcast/revocation/remount, sequential failures/success and harmless reload. Unsafe current input must make zero domain calls and clear defaults; stale input changes nothing. Calibrate any invocation oracle with a real admitted call. Preserve valid-fixture digest and existing export/readiness generation semantics.

Root alone runs focused/affected/canonical checks under the accepted ADR and records source-bound results. Native cases are320/100%,390/100%,320/200%,390/200% with actual browser zoom, complete ordinary screenshots, measured widths/control/error bounds and DOM/AX associations. Exercise keyboard refusal→correction→next Tab→explicit retry, focused reset and delayed stale focus. Require complete readable controls/copy, visible focus and no document horizontal scroll. No human study, speech/full-WCAG or company qualification claim follows. Historical07 Docker evidence remains labeled reuse with explicit unchanged dependency hashes.

## Frozen provenance and root interface

Original advice: [guardrail-brief.md](guardrail-brief.md), SHA `b4a6afb0ee206cca4277e6e463dad3a1f8b2d836e1b0a69f597b4762143e2ef1`; [impediments.md](impediments.md), SHA `8b94e77c16a52663189fdb5acbfce9efa43fe6a62c124b90bbc525418a017839`; [uiux-brief.md](uiux-brief.md), SHA `5d6f487b004cc4e05dab504080fcb961865c143f300af1ff956278da1a9759f6`. Their differing proposed names/tokens are retained as history and resolved above; none was silently revised. Same-adviser arbitration and CR/LF ACK are recorded separately under `tmp/enhancement-program/08/conductor08-preedit-{arbitration,text-edge-ack}.json`. The [citation appendix](planning-citation-resolution-appendix.md) remains append-only and changes no source facts or scope.

Root full-read/acceptance of this interface is the next step. No author has been dispatched, no product/test/style/config changes made, no runtime action performed, and no goal count/status mutated by this conductor. Later review must include independent `principal-code-reviewer` and actual UI/UX/browser evidence review; failures return to the same three owners, with three-round escalation to root/`staff-tech-lead`.
