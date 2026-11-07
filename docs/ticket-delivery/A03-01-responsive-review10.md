# Home responsive source review10

**Blocking:** None. Scoped static approval of source-freeze09 (`9e4bd8aa4532915e10419031e7fbb72bad51b8141303c8899094f054e58dd6fd`). Actual geometry acceptance remains pending.

**Evidence:** Portal’s hero is extracted into one private render helper; its markup matches the original after whitespace normalization. Mutually exclusive Company/non-Company branches render it once: on Home inside closed native `company-home-about` after the Company component, elsewhere in its original position. The `load-demo` ID, handler and loading state remain intact. Chat’s existing no-demo condition is retained. No event handler or domain operation changed.

The main landmark now has a Company-home label on Home, and Guide retains its visible heading. Notices, alerts, unavailable-state messaging and Company controls remain outside the optional disclosure. Native summary/details supplies keyboard disclosure semantics without application dispatch. Browser focus/discoverability still needs confirmation.

Guide’s delta folds only the generic introductory sentence and repository count into saved-step Details. Saved company, project, assigned goals, explicit absence of an analysis-goal selection, next-action explanation and recovery remain exposed. Selector precedence, approval policy and event-generation guards are unchanged; no essential control is shrunk or clipped by this source change.

The extended existing test asserts one demo control inside closed Home details, the main label, exclusion of Guide/recovery from that disclosure, and Sources’ original heading/demo placement. It retains explicit navigation and zero-dispatch checks. Its empty fixture cannot alone prove runtime error visibility, but the unchanged alert markup remains structurally outside the fold.

Root’s check43 receipt/log records **60 tests, zero failures**, exit0 and stable source. All three changed current files match frozen copies and pins; worker product receipt hashes match. Full-source diffs against source08 contain only the reviewed extraction/folding and test additions.

**Non-blocking / limits:** This addresses decision09 without claiming that320px now fits. Candidate05 replay must measure the full primary rectangle at fresh scroll0 for320/390/desktop and verify keyboard disclosure/demo access without activating demo. Preserve the earlier counterexample and guardrails; do not hide errors to satisfy geometry. This is not full A03 or A04 completion.

**Nit:** None. **Praise:** Shared rendering preserves other-tab markup while removing redundant Home content from initial priority.

No reviewer test, build, runtime, browser, image, board or product-edit operations occurred. Root retains acceptance ownership.
