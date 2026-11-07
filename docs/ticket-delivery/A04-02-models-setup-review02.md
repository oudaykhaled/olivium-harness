# A04-02 Models / Setup compatibility review 02

**Blocking:** None. **Verdict:** Approve the scoped legacy-budget compatibility delta; retain review01’s bounded Models/Setup approval.

`Ledger.reopen_run/2` (`ledger.ex:24–33`) checks live setup ownership and retirement denial before lookup, preserves all three stored caps, and routes reopening through strict `start_run`. Creation limits apply only to `budget_not_found`; other failures do not create a default budget. The second admission check and strict equality comparison preserve denial if state changes between lookup and creation. Existing usage is not reset.

Chat and legacy Company Analysis use this helper for their implicit opening behavior. `Models.propose` (`models.ex:178–183`) distinguishes an absent budget from an explicit option; explicit options still use strict `start_run`, including invalid or increased caps. Setup authorization/shared-budget paths remain unchanged.

Tests strengthen the explicit-increase expectation and assert unchanged stored caps. The retirement regression now checks `reopen_run` for both retired operation and budget IDs. Existing Chat two-request and Company Analysis one-token regressions are byte-identical to freeze01 and retain their exhaustion assertions.

**Non-blocking / Nit:** None added. **Praise:** The repair separates implicit legacy reopening from explicit limit changes without introducing another budget authority.

**Verification and limits:** Check167 and format168 receipts show exit 0; Root reports 71 focused tests passed. Check169 had no completion result at inspection. Historical canonical165’s three failures are retained, not relabeled. Six relevant changed files and three unchanged adjacent source/test files were pinned; Capture changes are outside this review. No tests, runtime, provider or board operations were performed. This approves source compatibility only, not installation, real-provider behavior or full A04-02 completion. Ownership released.
