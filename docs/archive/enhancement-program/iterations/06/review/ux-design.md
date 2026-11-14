# Iteration06 pre-edit UX contract

Advisory only against root-accepted [ADR06](../decision.md), SHA256 `572fdd18c5979e4f29af3511f77650ada3df85cdcfeeb1b0592ba2a5f40c37ce`. Read AGENTS, PROGRAM/conductor,06 coordination,05 handoff/original UX/design and03 amendment. Reviewed actual [Portal](../../../../../../lib/harness_forge_web/live/portal_live.ex), [JS](../../../../../../assets/js/app.js), [CSS](../../../../../../assets/css/app.css), Harnesses/Artifacts and focused goal/readiness/artifact tests. Applied UI Accessibility Audit guidance. No product edits, commands executing application code, tests, browser/runtime operations or study occurred. Preserve peer edits; root alone owns board/shared assets/native evidence.

## Presentation and semantics

Reuse each digest-owned package card and export form. DOM order: package name/version/runtime → full digest → label **New export directory** → helper → input → associated failure → **Export package** button → successful result. Helper: **“Choose a new absolute directory under an existing parent. Existing destinations are never replaced.”** Keep destination, remedy and outcome expanded; full digest may use native details if its complete value remains available. Use escaped HEEx text throughout.

One active outcome/draft belongs to full digest and current export generation. Submission B supersedes A; readiness selection changes neither ownership nor generation. Success shows **“Export complete”**, package name/version, exact returned destination/full digest, and **“Files exported. Evaluation and release remain separate decisions.”** Accept success only when returned digest/path have validated shapes and exactly equal submitted digest/target; never display mismatched returned metadata.

Use an explicit label/for pair. Input `aria-describedby` references helper plus existing failure ID. Set `aria-invalid="true"` only for established destination refusals, not uncertain completion or eligibility failure. Error is visible text, not color alone. Successful result is `tabindex="-1" role="status" aria-live="polite" aria-atomic="true"`; preserve its visible focus indicator. No positive tabindex or focusable controls between failed input and export button.

Fixed export copy, never arbitrary server message/details:

| Category | Copy |
|---|---|
| `export_conflict` | “Export destination already exists. Choose a new directory. This refused attempt did not replace the existing destination.” |
| `unsafe_artifact_path` | “Use a new absolute directory under an existing real parent, without symbolic links or traversal.” |
| I/O, unknown/error shape, unexpected returned identity | “Export completion could not be confirmed. Inspect the destination before retrying with a new directory.” I/O may add “Check filesystem access and available storage.” |
| `invalid_artifact` | “Package integrity could not be verified. Review the package and rebuild from current approved inputs.” |
| `:stale_or_revoked_evidence` | “This package uses withdrawn or changed evidence. Review current claims in Evidence and rebuild.” |
| `:stale_or_revoked_plan` | “This package's Company plan is no longer eligible. Review and approve the current exact plan, then rebuild.” |
| `:privacy_operation_incomplete` | “Workspace content removal is incomplete. Resolve the pending privacy operation before exporting.” |

Restored quarantine grants no approval; direct any resulting evidence/plan refusal to its actual review remedy, never just another directory. For invalid/stale envelopes use “This export form is no longer current. Use the refreshed Packages controls.” without submitted metadata, retained draft or digest-targeted focus.

Audit follows publication; broad failures cannot promise absent output. Add **“Package build:”** at production of existing direct-build outcomes only. Export does not write/clear generic flashes or resolve prior build failure.

## Exact focus and generation interface for root/author

Propose server event **`package-export-focus`**, window event **`phx:package-export-focus`**, exactly `{kind, digest, generation}`. Allow `kind` only `target` or `result`; digest `/^[0-9a-f]{64}$/` and length64; generation `/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/` and length36. Reject nonstrings/malformed/extra fields; accept no selector, HTML, path or arbitrary ID. Existing fixed **company-focus allowlist stays unchanged**.

Let `g` be generation and `d` full digest. IDs are exactly `package-export-{form|target|action|help|error|result}-${g}-${d}`. Retain row `artifact-${d}`, adding `data-export-digest=d`; only active row has `data-export-active="true"` and `data-export-focus-kind=kind`. Visible `#package-panel` exposes `data-export-generation=g`. Forms submit `export[generation]`, `export[digest]`, `export[target]`.

Use **one generation for envelope and DOM/control keys**. Validate current generation, visible Packages state, available full digest and bounded valid target shape **before** domain invocation. Reject invalid/stale envelopes without echoing submitted private values or invoking export. For each accepted submission, rotate generation, clear prior outcome/all drafts, then bind the new outcome to the new generation: restore only matching failed target; success leaves every target blank. Replacing generation-keyed forms/inputs clears a focused browser value despite LiveView value preservation. Ordinary record reload/reorder retains generation/outcome if its artifact remains available.

Rotate and clear on mount, leaving Packages, privacy reset including sibling broadcast, revocation/lock and active-artifact removal/unavailability. Returning starts clean. This clears UI state, not exported files.

Push focus with the newly assigned outcome's patch. JS schedules one `requestAnimationFrame`; **inside it**, obtain current panel/row/target anew, recheck generation, connected/visible Packages, matching active digest/kind and connected visible enabled destination. Require panel contains row and row contains destination; visibility checks reject hidden/inert ancestors and hidden computed visibility. Construct ID internally with `getElementById`; no dynamic selector interpretation. Reset, newer submission, hidden tab or removed row makes old work a no-op; no timer/retry may restore focus. Failure focuses new target input; next Tab reaches matching Export. Success focuses new local result.

## Required evidence plan

- Positive: occupied A → preserved target/focused input → next Tab Export → corrected fresh export; exact A bytes/digest/path, blank replacement input and focused local status. Prior build refusal remains labeled.
- Negative: unsafe target, withdrawn evidence/plan/quarantine, hostile errors, mismatched returned path/digest and stale/foreign envelopes; no false success, raw metadata or inappropriate directory-only advice. Stale input never invokes export.
- Edge: same-named A/B success→failure→success→failure, reorder, independent readiness choice, focused unsent input, sibling reset with still-eligible unrelated package, leave/return, remount and revocation. Check actual blank replacement IDs/values and delayed focus cancellation.
- Root captures ordinary viewports at320/390 CSS pixels and actual200% zoom: long name/digest/path wraps, complete controls/focus visible, `scrollWidth ≤ innerWidth`. Bound CSS to changed Packages surface. Preserve exact approvals, deterministic fresh no-overwrite export, privacy/quarantine and03 command-free abstention; no probe, dependency, persistence/domain change or extra handoff. DOM/focus evidence establishes no speech, comprehension, WCAG or company-fitness claim.
