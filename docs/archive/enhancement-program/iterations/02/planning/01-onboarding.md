# Company onboarding: one saved-state next action

**Observed evidence.** The saved Chrome screenshot places the first Company form below metrics and a four-stage banner; `company-dom.txt` lists seven Company sections and a proposed 0.2.0 plan while “AWAITING A DECISION” reads 0. `portal_live.ex:980` counts proposed claims only; line 988 always styles “Connect sources” complete. `company_panel.ex:357` reloads saved records; line 543 renders all forms together. `company/catalog.ex:48` gives the profile a stable name input. No newcomer study was performed.

**User/job/hypothesis.** A first-time local operator wants to save a company identity and know the next prerequisite. An accurate next-action card should reduce guessing. Proposed five-person synthetic trial: at least four save a profile and identify the next required prerequisite unaided; fewer than four falsifies the hypothesis.

**One bounded change.** On Company, show a “Next action” card from persisted records, initially “Name your company,” linked to `#company-profile-name`. Advance through missing repository, project membership, captured source/eligible claim, proposed plan, exact plan decision, then approved-plan build using existing controls. Separate required prerequisites from optional goals/milestones and proposed claim from plan counts. Replace the misleading Company workflow banner; retain form access. Rejected/superseded plans prompt a new proposal; stale eligibility prompts current-context review.

**Acceptance.**

- Given an empty workspace, when Company opens, then the card names “Name your company,” targets the labeled name input, and shows no source as complete.
- Given a saved profile but no repository, when Company reloads, then the action targets the repository form; unsaved fields do not count as progress.
- Given a current proposed plan, when Company opens, then its decision is next and its count is distinct from proposed claims.
- Given a rejected, superseded or stale plan, when Company opens, then the card offers review or a new proposal, never build.
- Given keyboard use at narrow width, when activating the card, then focus reaches the target and entered values remain available.

**Risk/non-goals.** Saved counts alone cannot establish current eligibility: use existing admission checks before suggesting build. No new approval authority, source import, runtime qualification, or claim of accessibility conformance.
