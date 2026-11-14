# Portal correction02: restore successful export visibility in Audit

Independent web review correctly identified a candidate01 P2 regression: the new export handler bound a local outcome without refreshing loaded records. `Harnesses.export/2` appended `harness.exported`, but the Audit tab used stale `@audit`; tab navigation and the evaluations timer did not refresh it. Initial candidate01 evidence and the [original author note](implementation-portal.md) remain unchanged historical records.

Root authorized this correction and the same author's necessary selector compatibility updates. **Author correction checks pass; independent candidate02 verification remains pending. MIX RELEASE: 2026-11-01 18:36:35 UTC**, with no owned command process remaining.

## Exact correction

[Portal](../../../../../../lib/harness_forge_web/live/portal_live.ex) now binds the outcome, refreshes records **only for confirmed success**, then pushes the existing bounded focus event. Existing `retain_export/1` preserves the matching full digest, generation and success across this ordinary reload. No helper, domain, gate or asset change was made.

Root explicitly selected success-only refresh: the domain appends `harness.exported` on success; unconditional error reload would remove a corrupt artifact row and clear the newly established integrity remedy/focus via `retain_export/1`. Failed export targets, integrity/eligibility/privacy remedies and unconfirmed completion therefore retain their prior accepted behavior. No unavailable-row fallback or extra notice system was introduced.

The [new LiveView regression](../../../../../../test/harness_forge_web/package_export_test.exs) exports real files, compares the immutable payload, obtains the actual persisted event, navigates to Audit and asserts that exact event ID/action/full artifact digest is visible immediately. It reproduced the missing-row defect before the production fix.

One all-test/lib legacy-selector search found the old Company Builder form assertion and browser smoke result wait. The [Company Builder assertion](../../../../../../test/harness_forge_web/company_builder_test.exs) now requires the generation-keyed form inside the exact artifact row. The [smoke wait](../../../../../../test/browser/smoke.cjs) now requires the current keyed status result inside its selected artifact row. The export test's deliberate assertion that the old global `#export-result` is absent was retained. No assertion was dropped, excluded or weakened.

## Evidence and limits

[Correction evidence index](../../../../../../tmp/enhancement-program/06/author-portal/correction-02/checks.json) records actual argv, explicit `MIX_ENV=test`, cwd, UTC start/end, exits and logs. `before/`, `before.json` and per-file diffs preserve exact initial bytes; original01 logs/manifests were not overwritten.

| Check | Actual outcome |
|---|---|
|01 new Audit test against unchanged production Portal, isolated by line106|**exit2: one test, one failure** at `assert has_element?(view, "#audit-#{event["id"]}", "harness.exported")`; actual export/payload/persisted-event checks had passed. Sixteen explicit location exclusions are recorded for this isolated red proof only.|
|02 targeted format|exit0|
|03 complete affected export + Company Builder + goal + Portal + readiness files, seed0|**exit0: 73 tests, zero failures, 8.8s**, no filters/exclusions/skips; includes all 17 export tests and existing calibrated command-free readiness checks.|
|04 targeted `mix format --check-formatted`|exit0|
|05 `mix compile --warnings-as-errors`|exit0|
|06 `node --check test/browser/smoke.cjs`|exit0; syntax only, browser script was not executed.|

Exactly four product/test paths changed from candidate01: Portal +3/-1 lines; export test +15 lines; one Company Builder assertion formatted across +6/-1 lines; smoke selector +1/-1 line. The helper, existing goal/Portal tests and root JS match the preserved before bytes. The full affected pass confirms retained occupied→fresh, same-name A/B, failed target/focus, corrupted integrity, stale/foreign envelopes, privacy/reset, remount/lock, real restored-quarantine and readiness regressions alongside immediate Audit visibility.

No canonical suite, Docker, Dialyzer, native build, runtime/browser operation, CLI seed, remote write or generated-code host execution occurred in this author window. Native focus, queued reset and reflow remain root/independent acceptance work. This correction is not independent verification or iteration acceptance.
