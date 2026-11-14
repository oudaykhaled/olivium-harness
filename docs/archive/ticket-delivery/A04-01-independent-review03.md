# A04-01 independent CSS addendum

**Approve this scoped CSS change. Blocking: none (P1:0, P2:0).**

`assets/css/app.css:198` applies the existing `--company-target: 2.75rem` minimum height to disclosure summaries only within `#setup-workbench`. SetupLive carries the `company-builder` class that defines the token. The rule preserves native disclosure behavior and adds no fixed height, width, clipping or authority change. Reusing the existing target token is appropriate for the reported undersized summaries.

**Non-blocking / Nit:** None added. The earlier optional postcommit-observation test remains outside scope.

**Praise:** One scoped rule addresses both summaries without changing shared disclosure styling.

Verified source04 manifest SHA256 `4bcbb381ca884b00332a2816c4fc3f27109fb9bef7bdaaa9b671346d10ba62dc`, all394 copy hashes, and the sole source03→04 delta: `assets/css/app.css`. Semantic review covers that rule, its token and relevant markup only.

Root reports full72 on source03:1165 passes,15 existing skips,0 failures; Elixir/tests are unchanged. Repaired browser geometry remains pending. This reviewer performed no browser/runtime checks and makes no release, whole-ticket or browser-verification claim. Reviews01/02 remain unchanged.
