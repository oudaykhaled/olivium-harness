# Company builder delivery handoff

Updated 1 November 2026. Root coordinator is sole `PROGRESS.md` writer.

## Delivered state

The local Elixir company/project harness builder completed implementation,
independent Astra decision/security reviews, automated QA, native packaging and
the actual Chrome company journey. All bounded authors and orchestrators handed
ownership back to root. No pending Mac unlock or browser test remains.

Full evidence: [company builder verification](../company-builder-verification.md).
Planning contract: [frozen contract](../../company-builder-contract.md).

## Accepted decisions

- One company per local workspace; explicit catalogue/project applicability.
- Exact approved claim revisions plus a separate explicit plan revision decision.
- Finite compiled presets; goals and milestones remain future intent.
- Legacy v1alpha1 schema/compiler identity preserved; local durable plan bindings
  commit before filesystem publication. Failed publication is retryable.
- Earlier approved versions remain reproducible while current authority is valid.
- Source purge follows typed provenance and scrubs applicability. Restore retains
  bindings while withdrawing decisions; a company artifact cannot become legacy.
- No private imports, paid inference, publishing, remote mutations, permission
  expansion or generated-code host execution occurred.

## Implementation and checks

Main additions: `company.ex`, `company/{records,validation}.ex`,
`harnesses/{artifact_binding,templates}.ex`, company LiveComponent catalogue/plan
screens, migration00700, privacy integration, CLI and acceptance tests.

- Final canonical suite: **370 registered, 355 passed, zero failed, 15 existing
  Docker skips**, seed 0. Report `tmp/company-qa/canonical-browser-fix.json`.
- Independent combined focus 91/0; acceptance and privacy 8/0; final portal focus 28/0.
- Format, warnings-as-errors compilation and Credo warning gate passed.
- Dialyzer exit 2: only existing `releases.ex:47/121` opacity diagnostics.
- Final native rebuild and packaged company review/build/verify/export smoke passed.
- Independent Astra reviews approved with no remaining actionable findings.

Actual Chrome exposed blank LiveView `_unused_` transport metadata rejected by the
original form guard. A red regression reproduced it; the minimal fix strips only
blank markers alongside their real fields. Strict malformed values still fail.
The rebuilt app then completed the entire persisted company flow in Chrome.

## Running apps and browser result

- Main: `http://localhost:8865`, observed PID 32400, `tmp/demo-workspace`.
  Existing source/claim/package/account data preserved; zero company plans.
- Disposable company QA: `http://localhost:8866`, observed PID 30296,
  `tmp/company-browser-workspace`. Example Works, Identity and Orders, Commerce,
  two reviewed package versions, one static pass, one unavailable task and zero
  release approvals. These approvals concern public synthetic fixtures only.
- Both use the final native release with `RELEASE_DISTRIBUTION=none`.
- Chrome browser 3, `companyCheck`, company build result marked deliverable.
  CUA only for UI; use the same browser binding. Never print access codes.

The browser verified capability/consumer lookup, exact plan decisions, disabled
proposed builds, v0.1 to v0.2 builds, added-rule/file diff, both fresh exports, passed
static integrity, blocked managed Codex tasks and refused static-only release.
The final company build screenshot is `tmp/company-qa/browser/company-final.png`.

Export directories: `tmp/company-browser-export-v1` and
`tmp/company-browser-export-v2`. All eight manifest entries per export were
hash/size-verified; scope is exactly `example/identity` and `example/orders`, one
synthetic goal, and one/two approved rules. Rejected injection absent. Audit:
`tmp/company-qa/browser/export-audit.json`.

Archive, checksum and companion verification report are under `tmp/packages/`.
No commit, merge, hosted deployment or public release was performed.

## Remaining external limits

GitHub live metadata was previously verified. Projects needs `read:project`;
Slack needs an API credential; Atlassian needs a reachable tenant and API credential
references. Browser sign-in does not provision application API access. No new
request is needed for unchanged missing inputs.

A selected real model and protected runtime qualification are needed for a live
company pilot. Codex and Claude native exports exist; their managed execution
backends remain unavailable. Goal-origin rule basis, explicit conflict records and
portable complete company-plan provenance remain documented extensions.
