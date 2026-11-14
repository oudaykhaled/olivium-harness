# 09 proposal — selected-goal accounting at approval

**User and job.** At approval, a company plan owner needs a declared acceptance/evaluation path for each selected goal. [CompanyTest](../../../../../../test/harness_forge/company_test.exs#L400) creates and approves a plan without milestones despite selecting a goal. The result is buildable without declared goal accounting. Real owner abandonment or failed company outcomes are unmeasured.

**Recommendation.** At [approval](../../../../../../lib/harness_forge/company.ex#L340), require every selected goal ID in a valid milestone of the exact revision. [Validation](../../../../../../lib/harness_forge/company/validation.ex#L79) checks references and nonblank acceptance/evaluation text but allows zero milestones. Preserve partial drafts and rejection. Return bounded, sorted uncovered IDs. Selected goals do not imply complete company obligations.

**Acceptance.** Metric: zero new approvals with uncovered selected goals; one counterexample falsifies delivery. Owner-reviewed real-company tasks remain necessary to test usefulness.

- Given two selected goals with valid covering milestones, when approving the current revision, then one approval is recorded and build inputs become available.
- Given one selected goal uncovered, when approving, then the response identifies its ID, records no decision/audit event, and build inputs remain unavailable.
- Given duplicate references to A while B is selected, when approving, then B remains uncovered. Zero-goal plans follow existing eligibility; approved ancestors remain immutable and successors require their own coverage.

**Tradeoff and ownership.** Approval-time correction adds friction; creation-time refusal would prevent useful partial drafts. A more direct outcome alternative is owner acceptance attached to an observed run: [Evaluations](../../../../../../lib/harness_forge/evaluations.ex#L20) tracks runs, but coding-task readiness is blocked or unqualified locally; this adds review/identity workflow without reliable execution evidence. One Company engineer owns gate, response and focused tests; estimate 1–2 days, pending transport error-shape inspection. Declared coverage does not prove milestone quality, policy completeness, model performance or owner acceptance.
