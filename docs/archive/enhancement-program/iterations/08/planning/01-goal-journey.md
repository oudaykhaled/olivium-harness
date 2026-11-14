# 08 proposal — saved goal to deliberate rule proposal

**Problem and job.** An operator who saved a goal needs a separately reviewable rule without mistaking the goal for approved policy. The saved card ends at owner/title/acceptance ([PortalLive:1980](../../../../../lib/harness_forge_web/live/portal_live.ex#L1980)); the rule form is on Evidence ([1542](../../../../../lib/harness_forge_web/live/portal_live.ex#L1542)) with a blank goal choice ([1579](../../../../../lib/harness_forge_web/live/portal_live.ex#L1579)). The browser test manually navigates back ([goal_claims_test:47](../../../../../test/harness_forge_web/goal_claims_test.exs#L47)). This is a source-evidenced discontinuity, not measured abandonment.

**Decision / benefit.** Add “Propose a rule for review” to each saved goal card. Reuse tab change and focus event, with a visible, focusable rule-form heading; keep Saved goal blank. Explain that approval is separate. This makes the next step discoverable while preserving deliberate selection and exact revision review. It changes no claim, plan, package, export or approval authority.

**Acceptance.**

- Given a saved goal, when its action is keyboard activated, then Evidence opens, focus reaches “Propose a goal-based rule,” and the next Tab reaches the blank Saved goal selector.
- Given the same action, when navigation completes, then no goal is selected, no rule or decision is created, and existing exact-revision approval remains required.
- Given goals are unavailable, purged, or the operator session is locked between display and activation, when the action is attempted, then stale draft/selection cannot reappear; current unavailable or login feedback applies.

**Success / falsification.** Proposed human target: at least four of five first-time operators continue within two minutes and accurately distinguish saving from approval; fewer falsifies the comprehension hypothesis. This study has **not** run. Technical acceptance requires keyboard focus and complete controls at 320/390 CSS widths and actual 200% zoom; browser visuals cannot substitute for the human target.

**Delivery / tradeoff.** Expected owner: UI author for `lib/harness_forge_web/live/portal_live.ex`, `assets/js/app.js` focus allowlist, and focused `test/harness_forge_web/goal_claims_test.exs`; root alone schedules Mix/native browser verification and records evidence. Strongest alternative is the smaller confirmed invalid-package-name repair: `invalid_harness` currently reaches generic provider-import advice ([PortalLive:1262](../../../../../lib/harness_forge_web/live/portal_live.ex#L1262)). That removes real misdirection faster, but leaves the saved-goal journey disconnected. Neither alternative establishes company/model fitness, novice usability, full WCAG, portable authority or publication completion.
