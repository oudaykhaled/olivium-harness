# A03-01 Home: frozen source06 review

**Blocking — P2 (test helper):** `test/harness_forge_web/company_home_next_action_test.exs:303–304` calls unavailable `Floki.parse_document!/1` and `Floki.text/1`. Check34 finished with **44 tests, five failures**, all five failing new cases stopping at this helper. Replace it with the project’s existing DOM parser or supported LiveView assertions while preserving selector, text and ordering checks; rerun the focused suite. Do not add a dependency solely for these assertions. Source06 cannot receive acceptance approval with this verification gap.

**Non-blocking:** No product-source blocker identified in the bounded delta. Native disclosure behavior and desktop/narrow focus/geometry still require actual browser verification. The helper correction must not convert structural assertions into weaker string-presence checks.

**Nit:** None.

**Praise / evidence:**
- `Guide:70–75,304–337` distinguishes assigned saved goals from an analysis selection, explicitly handles absent project and unavailable goal details, and makes no durable-resume promise. Names/titles remain escaped HEEx values. Its existing server selector precedence is unchanged; only corpus-action wording changes to “Select corpus and goal.”
- `Guide:339–406` puts the sole conditional Home continuation before scope/task forms, preserving event generation, targets and focus-section mapping. Unavailable and blocked explanations stay outside disclosures. Exact plan identifiers move into native details; current preflight text remains visible.
- `CompanyPanel:1362–1430` preserves alerts, moves Guide ahead of the closed “How this works” disclosure, and retains a visible secondary corpus action through the same guarded event. The delta changes no reset, draft, pending-operation or domain handlers. Portal’s complete delta is `label("company")`: “Scope”→“Home.”
- Six new tests meaningfully cover empty/saved/ambiguous state, recovery, built-plan navigation, and dirty/stale zero-dispatch behavior. Five need the helper repair above; the existing copy assertions are aligned without removing raw project-identity coverage under Details.

All seven source06 current files and frozen copies matched manifest pins at inspection. Baseline snapshots match accepted05 hashes; reconstructing Portal’s previous label reproduces its accepted hash. Guide author receipt matches; Root/QA preformat receipts are historical, with source06 authoritative.

**Verdict:** Changes requested for the test helper; product presentation is statically acceptable within this cut. No tests, builds, runtime, browser, image, private workspace or domain operations were performed by this reviewer. Prior candidate03 artifact proof does not qualify this new Home source. A04 durable setup, full navigation consolidation and overall A03 completion remain outside this review. Root retains fixes and acceptance ownership.
