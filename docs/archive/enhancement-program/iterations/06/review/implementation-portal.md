# Iteration06 Portal author handoff

Implemented the root-accepted ADR06 export recovery unit. **Author verification passes; independent review, canonical checks and native acceptance are pending.** The exclusive author Mix window was released at 2026-11-01 18:25:11 UTC. No Mix process remains from this task.

## Changed surface

- [Portal](../../../../../../lib/harness_forge_web/live/portal_live.ex): replaces `export_path` with one ephemeral `export_outcome`, one UUID `export_generation` and a fixed neutral `export_message`. Exact loaded lowercase full digest, current generation, Packages context and a bounded valid UTF-8 target are checked before the real `Harnesses.export/2`. Relative/traversal strings pass only the string envelope check and reach the unchanged domain path refusal; no filesystem preflight was added. Every accepted submission replaces the generation-keyed forms, supersedes the previous outcome and restores only the attempted failed target. Success clears every target. Invalid envelopes neither invoke export nor retain/echo their submitted private values.
- [PackageExport](../../../../../../lib/harness_forge_web/package_export.ex): one 76-line pure presentation helper validates returned identity and maps structured destination/integrity errors and current-evidence/plan/privacy refusals to fixed copy. Success requires shape-valid returned digest/path and exact equality with submitted values; no normalization or substituted path. I/O, audit, unknown and identity anomalies use completion-unconfirmed/inspect-destination copy. This helper grants no admission and performs no I/O.
- Local escaped result includes trusted current package name/version, exact destination and full digest. Error/help associations, destination-only `aria-invalid`, focusable success status and exact root JS IDs/data markers/event payload match the accepted UX contract. Export never writes or clears flashes; only direct Packages build production gains `Package build:`.
- Reset, sibling privacy broadcast, revocation, remount, artifact removal/loading failure and all four Packages exit paths clear/rotate. Ordinary reload/reorder retains the bound outcome if its exact artifact remains. Readiness selection remains independent. Clearing UI state does not delete exports.
- [Dedicated tests](../../../../../../test/harness_forge_web/package_export_test.exs): 16 tests use actual LiveView events, real approved synthetic records and real temporary filesystem exports/refusals. The existing [goal journey](../../../../../../test/harness_forge_web/goal_claims_test.exs) changes only four export-selector lines. Portal changes are +186/-30 lines (net +156), plus the helper; no framework/dependency/domain change.

The initial API checkpoint was sent to root/conductor before edits. Root alone owns assets; no author asset edit occurred. All 243 pre-existing unowned files under lib/config/priv/test plus mix.exs/mix.lock match the before snapshot byte-for-byte. Exact changed file hashes and check metadata are in the [author check index](../../../../../../tmp/enhancement-program/06/author-portal/checks.json).

## Actual checks and preserved failures

Every numbered JSON records actual argv, explicit `MIX_ENV=test`, UTC start/end, exit and corresponding full log under [author evidence](../../../../../../tmp/enhancement-program/06/author-portal/). No timeout increase, test exclusion or hidden retry was used.

| Attempt | Actual result | Correction / meaning |
|---|---|---|
|01 targeted format|exit0|Four owned Elixir/test files only.|
|02 compile --warnings-as-errors|exit0; two files compiled|Application code compiled without warnings.|
|03 focused export/goal/portal seed0|exit1 at test compilation|First test's `assert_push_event` map pattern illegally called `artifact["digest"]` (`Access.get/2` in a match). Replaced it with pre-bound pinned digest/generation variables. Product code was not changed.|
|04 same focused command|36 tests, two failures, exit2|`malformed unavailable foreign and stale envelopes never invoke export or echo targets`: fixture name `FOREIGN_PACKAGE_CANARY` violated the compiler's package-name format (`invalid_harness`, `$.metadata.name`). `a stale approved Company plan gives Company review rather than directory advice`: fixture supplied empty template IDs, rejected by `Company.Validation.plan/1`'s required nonempty known-template list. Corrected valid synthetic slug/template and complete update payload.|
|05 same focused command|36 tests, two failures, exit2|Foreign fixture used another workspace ID but the same physical artifact root; `Artifacts.list/1` lists that root's verified directories (`artifacts.ex:38–47`), so its name was already legitimately loaded before the forged submission. Gave the foreign fixture its own actual workspace directory. Company fixture then reached `:profile_required`; added the required synthetic profile and used repository `payload` plus `expected_content_hash`, following actual Company replacement API. No gate was weakened or mocked.|
|06 same focused command|36 tests, zero failures, exit0|Corrected full three-file pass.|
|07 targeted format|exit0|After adding the real cached-row/corrupted-metadata integrity refusal.|
|08 final focused export/goal/portal/readiness seed0|**52 tests, zero failures, exit0; 5.7s**|Final pass basis, including all 16 new export tests and existing calibrated command-free readiness event checks.|
|09 targeted format --check-formatted|exit0|All four owned files formatted.|
|10 compile --warnings-as-errors|exit0|Final warning gate.|

The shell evidence recorder itself exits normally after recording subprocess exits; the JSON `exit` and each log's actual Mix outcome are authoritative. Earlier failed attempts remain retained and are not counted as passes.

## Bounded behavior established

Real occupied→fresh retry preserves existing sentinel hashes and compares every exported payload file against the immutable artifact. Escaped destination, full package identity, one current result, blank replacement targets and unchanged build/unrelated flashes are asserted. Real relative/traversal/missing-parent/symlink-parent/symlink-destination/existing-file refusals preserve outside/existing bytes.

Same-named A/B follow success A→failure B→success B→failure A, with only the active failed draft retained; readiness selection, ordinary reload and a deliberate reorder of actual loaded records preserve exact ownership. The reorder changes presentation ordering only and does not replace domain admission.

Process-scoped export entry tracing matches the real `Harnesses.export/2` MFA and is calibrated by accepted occupied/fresh submissions producing one call. Malformed/stale/foreign/unavailable envelopes then produce zero calls, unchanged audit lists and no new destination. Sibling source purge uses an unrelated source; the selected package remains currently eligible, proving UI invalidation independently of a domain refusal. All exit paths, remount, revoked authentication, lock broadcasts and active artifact removal/unavailability clear state and rotate DOM IDs. Revoked authentication captures the actual revoked socket before redirect.

Cached-row metadata corruption, superseded/rejected evidence, changed approved Company plan, pending privacy operation and **actual backup→restore quarantine** refuse through the unchanged domain. The restore test opens the real restored database and points its test LiveView process at that database; no approved database was copied into an active fixture. Restored approvals are absent. The pending-operation row is an explicit synthetic database fixture, not a claim of a complete failed purge/retry journey.

Hostile result/error shapes, broad I/O, `:audit_failed` and mismatched returned digest/path are **pure presentation fixtures only**. They prove sanitized copy/identity rejection; they do not induce or prove an actual filesystem or post-publication audit failure. Generic failure may follow publication, so the UI never universally promises no output.

## Remaining acceptance

Root/independent reviewers own canonical tests, CI Credo, full warning-gated compilation, the two unsuppressed baseline Dialyzer findings, frozen source verification and native browser/build evidence. Author did not execute canonical/Docker/Dialyzer/native/CLI seed/runtime/browser operations, paid calls, external mutations or generated-harness host execution.

LiveView tests establish new generation-keyed blank markup and event semantics. They do **not** prove removal of an actually focused unsent browser value, delayed animation-frame cancellation, real active-element/next-Tab behavior, 320/390px/actual200% reflow, screen-reader speech, novice comprehension or company qualification. Those native/independent checks remain pending against root's candidate and JS.
