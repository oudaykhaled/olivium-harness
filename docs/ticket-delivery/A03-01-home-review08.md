# A03-01 Home: selector addendum08

**Blocking:** None. Approve the bounded test-only correction; retain review07’s scoped source approval.

`corpus_review_flow_test.exs:678` now searches `#company-guide-details` instead of `#company-guide-scope`, retaining the exact assertion “1 eligible approved claims.” Reversing this single replacement reproduces the entire source07 file hash (`9a4c342ce23e7f819f0ae9af77703ce6b962bac0bce5573b3a401bb576dbe969`), establishing that every other byte is unchanged.

The correction matches the current render: `Guide:304–314` contains the project name/unavailable state; `Guide:443–461` contains the approved-claim count under saved-step Details. The test continues checking an approved manifest-backed claim, empty manual assignments, and exact revision availability in a separate plan. This relocates the metadata assertion without relaxing its count or authority contract. It does not assert that closed disclosure content is visible without expansion.

Check37’s retained canonical log identifies this obsolete selector as its single failure: 1,143 tests, one failure, 15 skips. Check39’s actual receipt/log records **16 tests, zero failures**, exit0 and stable source. No current full-suite success is claimed here; Root’s check40 and upgrade decision remain separate.

All eight source08 changed-since05 files match current source and frozen copies. The three production files and previously approved new Home test retain their source07 hashes. Freeze08 SHA-256: `3461067999513af75e85d8bde1baa404d7f99dc9eeea24a3da340c1f48436393`. This test-only delta supplies no product-code reason to rebuild candidate04, but this review does not independently attest to its build.

**Non-blocking / limits:** Actual Home browser acceptance, durable A04 setup and overall A03 completion remain unclaimed. **Nit:** None. **Praise:** The correction preserves the exact approved-claim count and all surrounding integration assertions.

No tests, build, runtime, browser, board or product edits were performed. Root retains canonical verification and upgrade ownership.
