# Iteration 02 proposal: task language for Company

## Observed evidence

The saved [Company DOM](../../../../../../tmp/enhancement-program/01/browser/company-dom.txt) shows “AWAITING A DECISION 0” alongside a proposed 0.2.0 plan. In [PortalLive](../../../../../../lib/harness_forge_web/live/portal_live.ex#L977), that count calls `proposed(@claims)` only, while the banner always marks “Connect sources” complete (line 987). [Company Plan](../../../../../../lib/harness_forge_web/components/company/plan.ex#L47) presents seven numbered sections, including distinct claim and plan decisions. Its goal selector says “future intent, not approved policy” (line 136); target help says building does not run an agent (line 164). These are code and recorded DOM observations, not a user study.

## Bounded proposal

Add a concise, state-derived **“What to do next”** guide at the top of Company. Each state names one action and its destination, using the existing controls: “Save a company profile”; “Add a repository to your project”; “Review proposed claims in Evidence”; “Review proposed plan 0.2.0”; or “Build approved plan 0.1.0.” A stale plan says: “This plan uses changed context. Review current evidence and project membership, then propose a new plan.” The action text must reflect the selected exact revision and never call a proposed or rejected plan buildable.

Use consistent task labels in this view: **“Claims to review”** and **“Plans to review”** as separate counts; **“Captured sources”** for stored snapshots, without implying a live connection; **“Built packages”** for artifacts, without implying evaluation. Replace the universal four-stage completion banner on Company with this guide. Keep optional goals and milestones under “Optional future intent”; add the sentence “Goals and milestones do not approve claims or plans.” Link to the existing Goals section only when relevant. Do not create hosted help or new authority.

## Acceptance and risk

For empty, partial, proposed, rejected, approved and stale synthetic states, the displayed next action reaches the named control; both decision counts match their own saved records. Keyboard focus reaches the destination, and narrow screens retain readable action text. Browser checks should capture the rendered wording and destination, not claim a novice study. Risk: choosing a single next action can hide alternatives; retain direct access to every existing section and exact-revision review. Keep build, integrity, runtime availability, evaluation and release qualification as separate statements.
