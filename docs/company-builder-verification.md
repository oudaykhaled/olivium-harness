# Company builder verification — 1 November 2026

The local company authoring workflow is implemented and verified through the
native app in Chrome. Automated application checks, native package execution and
the interactive journey are recorded separately. This does not qualify a
model-backed company pilot.

## Orchestrated delivery

Four Astra decision sessions covered guardrails, domain design, orchestration and
independent QA. Three bounded build orchestrators each used one short-lived author:
company catalogue/plans, trusted build/provenance, and guided portal. Root integrated
migrations, privacy, audit, CLI and packaging and kept the sole progress board.

Critical decisions are frozen in [the contract](company-builder-contract.md): one
company per local workspace, explicit project applicability and exact reviewed plan
inputs, finite workflow presets, compatible v1alpha1 artifacts, durable local plan
bindings, and proposed roadmap intent separate from release authority.

## Observed results

| Check | Actual result | Limit |
| --- | --- | --- |
| Canonical suite | **370 tests: 355 passed, zero failed, 15 existing Docker skips**, seed 0, 37.1 seconds | Coverage not measured |
| Independent combined focus | 91 tests, zero failures/skips | Synthetic fixtures |
| Independent acceptance + privacy | Eight tests, zero failures/skips | Includes all three native exports to real fresh directories |
| Domain additions | 15 tests | Workspace, scope, DAG, hashes and decisions |
| Trusted build additions | 13 tests | Determinism, ancestor versions, prebinding and failed publication retries |
| Company portal additions | Six tests; final 28-test UI/regression focus passed | Includes real browser transport regression |
| Root privacy/CLI additions | Five tests passed | Purge/restore authority and bounded strict JSON |
| Format, test compile warnings-as-errors, Credo warning gate | Passed | Full strict style cleanup not claimed |
| Dialyzer | Exit 2, same two pre-existing release opacity diagnostics at lines 47/121 | No clean type-analysis claim |
| Native build and packaged CLI smoke | Passed | Synthetic disposable workspace |
| Packaged company journey | Proposed plan refused; exact fixture plan approved; scoped Codex package built, verified and exported | No generated code executed |
| Main native app | Final release at localhost:8865, observed PID 32400; login HTTP 200 | Company data remains operator-authored |
| Disposable browser-test app | Final release at localhost:8866, observed PID 30296; complete Chrome journey passed | Public synthetic company and claims only |

The main workspace retained 32 sources, three claims, three immutable packages and
its active GitHub account. It has zero company plans: no company policy or plan was
silently created or approved. A private consistent pre-upgrade database copy is in
ignored `tmp/pre-company-upgrade-2026-11-01.sqlite3`.

## Negative checks and review

Tests verify cross-project exclusion, current connector scope, exact claim/plan
revision authority, unknown fields/templates, deterministic ordering, predecessor
rebuild, changed catalogue invalidation, source withdrawal, roadmap cycles, static
release rejection and restore quarantine. All three target exports are verified
through the actual compiler and filesystem.

Independent QA found source-purge overreach and committed test-fixture leakage.
Purge now scrubs source applicability assignments while preserving unrelated
catalogue data, follows typed provenance instead of free text, and removes dependent
plan families/artifacts. Committed tests clean their disposable records; binding
assertions use workspace scope. Regression checks passed in the canonical run.

Astra security review found malformed milestone input could crash the page. The UI
now validates complete string ID/prose fields and bounds execution values before
rendering. The reviewer rechecked both fixes and approved with no open actionable
findings. Component events explicitly revalidate sessions; decisions use the server
operator and displayed exact revision hash.

## Actual Chrome sign-off

After the user unlocked the Mac, the allowed localhost tab was controlled through
Chrome's supported DOM interface. Native desktop control had separately reported
a URL restriction; no bypass was used. The test ran only in the disposable
`tmp/company-browser-workspace` on port8866.

The actual browser serializer exposed a bug missed by the original LiveView
fixtures: project selection submitted blank `_unused_` array/nested markers that
the form shape guard rejected. A browser-shaped regression failed before the fix.
The minimal fix removes only blank metadata beside its actual sibling field;
malformed execution and milestone values still fail strict validation. Astra
independently approved the fix. The final canonical suite and native rebuild passed.

Observed browser steps:

1. Loaded the built-in synthetic handbook, rejected its instruction-injection
   claim, and approved the two ordinary exact fixture revisions.
2. Saved Example Works, Identity (`example/identity`) and Orders (`example/orders`)
   with Orders declaring Identity as a dependency. Capability search found Identity;
   its direct-consumer lookup returned Orders. Saved explicit Commerce membership.
3. Proposed `commerce-harness` 0.1.0 with both repositories, one exact approved rule,
   the synthetic goal, both finite presets, one proposed milestone and Codex0.156.0.
   Build was disabled until the separate exact plan decision was recorded.
4. Approved and built 0.1.0, then proposed 0.2.0 adding the second exact approved rule.
   Its build also remained disabled until its separate approval. The package diff
   identified the added rule and four changed native/spec/provenance files.
5. Exported both versions through the real portal to distinct fresh directories.
   The predecessor remained export-eligible after the successor. Trusted filesystem
   inspection verified all eight manifest entries per export, the exact two-repository
   scope, one goal and one/two selected rules; the rejected instruction was absent.
6. Queued static integrity: **passed**, `integrity_only`, runtime qualified false.
   Queued managed Codex tasks: **blocked**, `runtime_backend_unavailable`.
   Attempted release approval using the passed static record: refused with
   “Release approval requires passed model-backed tasks.” No release was approved.

| Version | Exact plan revision | Package digest |
| --- | --- | --- |
| 0.1.0 | `70bb606ccf286087595058823a6e2aae0c56b115ba0871ef167ad6a93038686e` | `e9ac8fe7f662219d4f8fa28011bdfb94bc11339ee3fd26a3da0e3e5aaaf22335` |
| 0.2.0 | `8b867b8fc1c6070e0e49ff338b14d840eeb64be2442e72beefdf25ed2b13bc6b` | `9d26244706e6dd7ca42a0e3a671cae3b1ce8dfc5d44d8d4b86f7ae864272dac7` |

The disposable database corroborated one profile, two repositories, one project,
two plans, two plan decisions, two bindings and zero release approvals. The final
company result remains open in Chrome. [The handoff](handoffs/company-builder.md)
records the delivered state and unchanged external limits.

## Evidence and qualification limits

Ignored local logs/artifacts:

- `tmp/company-qa/{acceptance,focused-fixed,canonical,canonical-browser-fix}.json`
- `tmp/company-qa/browser/{company-final,company-build-diff,company-export,company-evaluation-gates,company-release-rejected}.png`
- `tmp/company-qa/browser/export-audit.json`
- `tmp/company-root-focused.log`, `tmp/company-root-privacy.log`
- `tmp/company-package-build.log`, `tmp/company-package-smoke.log`
- `tmp/company-browser-fix-build.log`, `tmp/company-browser-fix-smoke.log`
- `tmp/company-browser-fixed-native.log`, `tmp/company-fixed-native-main.log`
- `tmp/company-dialyzer.log`, `tmp/company-native-server.log`, `tmp/company-native-main.log`
- Native archive, SHA-256 and companion verification report under `tmp/packages/`

Live GitHub metadata was verified in the prior task. Projects, Slack, Jira and
Confluence still need suitable credentials/permissions or a reachable tenant.
No new private body import, paid model call, remote mutation, publication, model
quality claim or managed Codex/Claude execution occurred. Goal-origin claim basis,
explicit conflict records and portable complete company-plan provenance remain
documented extensions, outside this verified local composition contract.
