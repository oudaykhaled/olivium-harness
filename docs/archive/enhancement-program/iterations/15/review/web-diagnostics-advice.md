# Iteration 15 web diagnostics advice

Read-only advisory; Root owns implementation and browser verification.

**Direct source facts.** The curated component separates draft (`state.question`) from submitted question, provides focusable `company-corpus-results`, shows selected totals and structural readiness, and retains exact UTF-8 context controls (lines 621–751, 799–808). Its help describes scope/privacy resets; this snapshot cannot prove lifecycle behavior.

**Minimal recommendation.** After the submitted question, add one compact block, `company-corpus-question-coverage`, using only Root’s accepted `run.coverage.search.question` DTO:

- For `status: lexical`, show “Question-derived candidates: N · selected for synthesis: M.” Keep “Total selected passages: T” separate; add “Goal and follow-up searches may supply background evidence.” Counts describe query provenance, not verified relevance. No page-length counts, lane summation, background subtraction or client recomputation.
- Only a known `candidates: 0` shows exactly “No question-matched evidence found; background evidence only”. If total selection is also zero, retain the existing no-passages explanation. If candidates are positive but selected is zero, show “Question-matched candidates were found; none were selected for synthesis.”
- Follow with “Matches do not establish that this question can be answered.” Preserve the structural ready state and existing synthesis eligibility. Suggested ready wording: “Capture, index and context checks passed. Whether this evidence answers the question remains unknown.”
- Use a collapsed `company-corpus-question-search-details` with summary “Question search details”: “Searched question terms”, `searched_terms`, and “Query plan version”, `query_plan_version`. Render complete server values with wrapping. Bind them to that run’s digest; never derive them from the editable draft.
- For historical/graph `status: unknown` or absent fields, show “Question search details: unknown for this run.” Missing values are unknown, never zero or reconstructed terms. Empty-term goal fallback with known lexical zero receives the zero-hit warning.

**Action and focus.** Add `company-corpus-retry-question`, “Edit question and search again”, focusing `company-corpus-question-text` without replacing its current draft or submitting. Reuse the existing form and submit action. Keep results as the completion focus destination, errors at the existing alert, and one polite status announcement. Typing must not steal focus. No modal or extra approval/resolution step.

**Acceptance for Root.** Check zero-hit/background-ready, positive-hit, candidate-positive/selected-zero, historical unknown, graph unknown and goal fallback. Edit the draft after submission: prior diagnostics stay tied to the submitted run. Scope/privacy/currentness invalidation must clear stale results and synthesis consent together. Confirm retry/error keyboard focus, busy disabling, long/Unicode term wrapping, exact-context return, byte labels and existing approvals.

**Limits.** These are source-based recommendations; no LiveView lifecycle, visual, accessibility or semantic-answerability validation was performed.
