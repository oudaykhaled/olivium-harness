# Iteration 08 proposal — deliberate Goals-to-Evidence continuation

**Problem and job.** After saving a goal, an operator wants to turn it into a reviewable rule. Today `PortalLive.handle_event("goal")` saves and reloads on Goals (`lib/harness_forge_web/live/portal_live.ex:421`), while Evidence holds the rule form (`:1542–1603`); the operator must discover that tab. The form starts with a blank goal (`:935–961`, `:1572–1591`), and tests protect that separation (`test/harness_forge_web/goal_claims_test.exs:27–54`). This is a navigation gap, not measured user confusion.

**One benefit.** After a successful goal save, show “Continue to propose a rule” beside the result. Activating it switches to Evidence and focuses the rule introduction; the next Tab reaches the blank Saved goal select. It carries no selection or draft text. Saving, navigating and selecting create no claim or approval. Preserve exact goal snapshot/hash validation, fresh form generation, reset/lock/purge clearing, and unavailable-goals refusal. Success metric for a later unassisted study: at least 4/5 first-time operators reach the form within two minutes and distinguish save, proposal and approval. Falsified if fewer than 4/5 do so; this study is unperformed.

**Acceptance**

- Given a successfully saved goal, when the operator activates “Continue to propose a rule”, then Evidence opens, focus lands at the rule introduction, and the next Tab reaches an unselected Saved goal control.
- Given an invalid goal save or unavailable saved-goals load, when the operator attempts continuation, then no rule form is activated or claim/approval created, and the existing error/unavailable guidance remains visible.
- Given a prior draft followed by purge, lock or remount, when the operator returns through continuation, then the goal select and rule text are blank, the stale generation is refused, and no historical goal is silently selected.

**Delivery and tradeoff.** Expected owner: UI author in `portal_live.ex` and focused `goal_claims_test.exs`; root owns any shared integration. Root alone runs Mix and native keyboard/browser verification at 320/390 and actual 200% zoom, including reset and unavailable states. Strongest alternative is correcting the demonstrated invalid-package-name error mapped to generic connector advice (`portal_live.ex:1262–1280`): smaller, directly fixes misleading recovery, but does not reconnect this interrupted goal workflow. Neither benefit establishes novice comprehension, full WCAG coverage, company/model fitness or portable authority.
