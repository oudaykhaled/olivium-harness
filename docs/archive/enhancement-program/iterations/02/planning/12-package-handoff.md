# Package handoff after Company build

**User and job.** After building an approved company plan, a local operator needs to export *that exact package* among earlier versions. Company shows its digest, then three equal navigation buttons. Packages lists every artifact with an export form; comparison lives elsewhere. Wrong-version export is plausible but unmeasured. Evidence: [`plan.ex`](../../../../../../lib/harness_forge_web/components/company/plan.ex), [`portal_live.ex`](../../../../../../lib/harness_forge_web/live/portal_live.ex), [Company DOM](../../../../../../tmp/enhancement-program/01/browser/company-dom.txt).

**Recommendation.** After Company build, show one primary “Review and export this package” action beside the full digest. Carry that digest to Packages, identify its row, and focus its heading or export control. Offer comparison secondarily when two packages exist: preselect the new digest as candidate and require an explicit baseline. Explain comparison as file/rule differences and export as immutable bytes in a fresh directory. Label verified bytes, *current* export eligibility, and evaluation/qualification separately. Reuse `Harnesses.get/1`, `eligible/1`, `export/2`, and `Releases.diff/2`; export still rechecks current evidence and plan bindings ([`harnesses.ex`](../../../../../../lib/harness_forge/harnesses.ex)).

**Success and falsification.** In five observed synthetic operator journeys, at least four export the intended digest without coaching or wrong-version attempts. Fewer than four falsifies the navigation hypothesis. Browser automation alone cannot establish this metric.

**Acceptance.**

- **Given** a newly built eligible digest and older packages, **when** the operator follows the primary action, **then** Packages identifies and focuses that exact digest and its export form; a successful export names that digest and destination.
- **Given** a package whose source or plan becomes stale after build, **when** the operator attempts export, **then** the request is refused with a corrective action and no destination is created; integrity, eligibility and qualification remain distinct.
- **Given** two packages with the same display name/version, **when** the operator compares from Company, **then** the candidate is the just-built full digest and the baseline must be chosen explicitly; the result labels both exact digests.

**Risks.** Refresh eligibility on navigation; rely on export admission. Keep focus predictable on narrow screens and preserve drafts.
