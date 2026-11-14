# A02-02 source01 review

**Verdict: changes requested for the bounded partial source. Blocking: 1 (P2). Nits: 0.** This is not a ticket-completion, merge, release, browser or installed-upgrade verdict.

Reviewed freeze02: all six new implementation/test files in full; all five existing-file diffs against `before`, with bounded adjacent/helper definitions. All 11 snapshot and current source SHA-256 hashes match the freeze02 manifest. Exact hashes and semantic ranges are in `tmp/ticket-delivery/reviews/A02-02-source01-read-audit.json`; hashing an entire file does not imply full semantic review.

## Blocking

**P2 — `lib/harness_forge/company/readiness.ex:79`: superseded plans can remain review-complete.** Trigger: approve plan A, create a new revision that supersedes A without changing its pinned catalog/claims, then select or reload A. `CompanyPanel.preflight/1` checks its approved status (`company_panel.ex:1130`) and calls `Company.build_inputs/1`. That helper checks the decision and resolved snapshot (`company.ex:222–232,445–454`), but not supersession. `plan_dto/1` separately retains `status: approved` and `superseded: true` (`company.ex:479–487`). Consequently `for_plan/6` converts `:eligible` into `exact_review_verified` for a noncurrent plan. The adjacent candidate path correctly refuses it through `Harnesses.assessment_plan/2` (`harnesses.ex:78–82`), leaving contradictory readiness facts.

Minimal fix: explicitly reject a superseded selected plan before projecting review completion, returning stale/unknown and withholding its completion references. Apply the same condition to preflight if desired; avoid changing command authority as part of this read-model fix. Add a real WEB regression that approves A, creates its superseding revision, selects A, and asserts review is not complete and release remains unavailable. This is a new incorrect readiness claim even though the reused build-input helper predates this change.

## Non-blocking

No additional independent defects established. The absence of a required/optional connector producer leaves AC3 open as documented. Current-session synthesis outcomes, explicit physical recapture after indexing changes the generation, and unselected evaluation/release receipts are accepted boundaries of this amendment, not blanket defects.

## Nit

None.

## Praise

The pure projection bounds references/pins, uses fixed reason/status codes, and always withholds `next_action`. Capture completion stores its actual generation; legacy records remain historical/unknown. Synthesis callbacks revalidate the selected run and original operation before recording outcomes, and proposed claims additionally match operation/request IDs. Scope/reset/remount paths clear observations. Claim approval and plan approval remain separate; artifact existence cannot grant release.

## Review axes and verification limits

Correctness: inspected stale/current bindings, missing records, exact approvals, callback handling and reset paths; blocker above. Security: scoped store reads and authorization/privacy guards remain; metadata summary DTOs avoid passage hydration, and the rendered projection excludes bodies/URLs. No authority command or provider invocation is added by the projection. Performance: bounded DTO/reference counts; reused summary aggregates and repeated checked reads have no measured latency claim. Tests: read all three new test files, including physical scan, generation invalidation, failure/reset and exact plan/artifact cases; the superseded-plan case is absent. Observability: fixed display reasons and observation timestamps avoid raw exception output; no telemetry verification performed. Operability: additive completion metadata, conservative legacy handling, no migration/dependency changes in the frozen set.

No tests, app runtime, browser, CI, security scan, protected data, paid providers or target code were executed. Root check08 was reported running at dispatch; its result was not inspected here. Earlier passing checks do not qualify this freeze. Root must record applicable current-candidate checks after remediation. Actual WEB/browser evidence, durable synthesis history and AC3 remain outside this source verdict.
