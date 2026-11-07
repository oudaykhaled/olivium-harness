# A04-01 independent P2 recheck

**Verdict: approve the scoped P2 correction. Blocking: none (P1:0, P2:0).** The revoked-selector finding from review01 is resolved in source03. Review01 remains immutable; this is not whole-ticket or release approval.

**Evidence.** `setup_live.ex:250–280` keeps catalogue loading and reference observations under one reentrant Purge fence, but finishes the catalogue SQL transaction before calling `CorpusReview.summary_refs/2`. Lines320–344 construct visible catalogue choices only after a successful authoritative source-access observation. Unavailable references are withheld; observation errors stop collection and produce the fatal choices error. Lines283–301 separate nonfatal withheld-choice warnings from fatal read failures, allowing independent valid choices to remain usable. Initialization, cache clearing, scope-error clearing and rendered warning state are included. No command, consent, dispatch or authorization semantics were changed.

The new test (`setup_live_test.exs:206–254`) asserts both fresh reopen and explicit Reload, checks absence of revoked profile/project tokens and names, checks DTO redaction, then acknowledges an unrelated source-free project and confirms Continue remains disabled and dispatch counts unchanged. Root RED68 fails at the original revoked profile option assertion, demonstrating that this regression detects the pre-fix defect. Root70 passes76 tests in6.8s; root71 format check exits0. Both check records have stable before/after source maps matching all394 source03 pins exactly. Root67 separately establishes1164 passes,15 skips,0 failures on source02; it does not verify source03. Current full-suite outcome was not supplied at this review boundary.

**Non-blocking:** The optional postcommit-observation-failure regression from review01 remains open outside this correction. This recheck does not expand that scope.

**Nit:** None.

**Praise:** Reusing the existing source validator closes the display leak without introducing a second authorization policy, and the regression verifies that withholding one revoked choice does not disable unrelated valid choices.

**Pins and coverage.** Source-freeze03 SHA256: `446b87d4195dcb684209c2b1dfeb88fe265add4bd3879e62be6fac3f2cc5dec8`. All394 frozen-copy hashes were checked with zero mismatches; independent manifest comparison confirms exactly two changed files. Semantic recheck covers every source02→source03 hunk in SetupLive and SetupLiveTest, plus the relevant unchanged CorpusReview read/summary, Corpora guard and Purge fence primitives. Hash coverage is not semantic review of394 files. Check-record hashes68–71 match the manifest. No product edits, tests, formatter, browser/runtime, network, provider or target execution were performed by this reviewer. First two steps remain the bounded partial delivery; deployment, early-click browser behavior, whole-ticket completion and usefulness are unclaimed. No security-scan/CI-green assertion is made.
