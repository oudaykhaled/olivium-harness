# Proposal 09 — explain the first step after a company build

**User/job.** After building an approved plan, a company operator needs to identify the exact package and the next action. The guide's post-build primary action says **“Open packages and export”**, although export is optional and evaluation/release are separate. The build panel offers three peer buttons; Packages combines inspection and export. This is a comprehension hypothesis, not observed novice behavior. [Guide](../../../../../lib/harness_forge_web/components/company/guide.ex), [Plan](../../../../../lib/harness_forge_web/components/company/plan.ex), [Portal](../../../../../lib/harness_forge_web/live/portal_live.ex).

**Benefit.** Make the guide's post-build primary action **“Inspect built package”**, show its full digest, and open Packages with that digest selected. Copy explains: “Inspection checks this saved package. Export saves a copy; evaluation tests it; release approval requires a qualified task.” Keep optional compare/export controls. Selection creates no approval, evaluation, export or readiness receipt. Preserve explicit run selection, seven separate inspector stages and OpenCode task **Not assessed**. [Handoff](../handoff-to-04.md), [amendment](../decision-amendment.md).

**Acceptance.** 

1. Given a newly built artifact, when the guide action is activated, then Packages opens with that digest selected, no evaluation inferred, and inspection still explicit.
2. Given no artifact or revoked/stale context, when the guide renders, then no package-specific action or releasability claim appears; corrective guidance remains.
3. Given two artifacts, when the action is activated, then it selects the current build's displayed digest; changing packages clears prior inspection.

**Success/falsification.** A browser journey passes all criteria, keyboard focus and 320 CSS-pixel/200% zoom checks. A future novice study must test whether operators distinguish inspection, optional export and qualified evaluation; continued confusion falsifies the hypothesis. No study has run.

**Alternative/risk/effort.** Static-cleanup explanation and export-error recovery are observed wording defects and smaller alternatives. This selection crosses Guide/Portal state: estimate 0.5–1.5 engineering days plus native verification. Files: `company/guide.ex`, `company_panel.ex`, `portal_live.ex`, focused web tests. Clear selection on reset/revocation through existing generations; preserve privacy, no-overwrite export and admission.
