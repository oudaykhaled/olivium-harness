# First-time operator: continue from a saved goal

**Problem and evidence.** A company operator who saves an observable goal needs to turn it into a reviewable rule. The saved card ends with owner/title/acceptance and no next action ([Portal:1952–1985](../../../../../../lib/harness_forge_web/live/portal_live.ex#L1952)); the separate Evidence form requires choosing a saved goal and explains that saving/selecting does not approve a rule ([Portal:1542–1602](../../../../../../lib/harness_forge_web/live/portal_live.ex#L1542)). The gap is visible; its human impact is unmeasured.

**One benefit / ADR.** Context: the user must discover a separate form. Decision: add one “Propose a rule from a saved goal” action on each saved-goal card, using existing tab navigation and focus, landing on the form heading with the saved-goal select blank. Consequence: one extra control per card. Navigation creates no selection, claim, approval or authority; preserve generation/reset boundaries.

**Success and falsification.** Technical success is a keyboard-usable continuation with zero state mutation. An **unperformed** five-person first-time study targets four reaching the form unassisted within two minutes and distinguishing saved goal, proposed rule and approval. Fewer falsifies the comprehension hypothesis.

- Given a saved goal, when its action is keyboard-activated, then Evidence opens, focus lands on “Propose a goal-based rule”, and the next Tab reaches a blank “Saved goal” selector.
- Given the action is activated, when the operator inspects records, then no goal is selected and no rule, decision or approval is created.
- Given goals become unavailable, or privacy reset/lock occurs between display and activation, when the action is used, then stale drafts cannot return and the current unavailable/reset state is shown; controls and focus remain usable at 320/390 CSS pixels and actual 200% zoom.

**Delivery.** UI author owns `portal_live.ex` and, only if required for existing focus handling, `assets/js/app.js`; web QA owns focused LiveView/browser checks. Root alone schedules native verification and board updates. The strongest alternative is correcting the confirmed invalid-package-name refusal routed to connector advice ([Portal:1258–1281](../../../../../../lib/harness_forge_web/live/portal_live.ex#L1258)): smaller and certain error recovery, but narrower reach than the stalled goal journey. Neither option establishes company/model fitness, full WCAG or novice comprehension without observation.
