# Planner 03 · recognizable pinned source identity · UNSELECTED

**Owner benefit.** On reopening a finding, the owner can recognize its captured revision before judging guidance. Keep exact source ID, revision ID and byte span visible. This improves the analysis→decision→package journey without proving semantic correctness or completeness (`PRODUCT_OUTCOME.md:9–21`).

**Evidence and constraint.** The report stores citation IDs, revision IDs, snippets and spans, and its context pins every examined revision/hash (`lib/harness_forge/models/company_analysis.ex:136–154`; `lib/harness_forge/company/analysis.ex:300–325`). The current excerpt renders only IDs/span (`lib/harness_forge_web/components/company/analysis.ex:473–485`). `Evidence.Revision` retains `captured_at` and `source_url`; **title is only on mutable `Evidence.Source`**, and import can replace it (`lib/harness_forge/evidence/records.ex:19–48`; `lib/harness_forge/evidence.ex:535–545`). Neither report nor revision retains a capture-time title. The selection UI already displays title, capture time and URL with an HTTP(S), host and no-userinfo check (`components/company/analysis.ex:262–275,537–549`).

**Bounded design.** Enrich the reopened report from workspace-scoped historical metadata keyed by *pinned* revision ID. Show “Captured [timestamp]” and a safely validated “Open captured source link.” If accessible, label `Evidence.Source.title` **“Current source name (may have changed)”**; otherwise “Captured title unavailable.” Never infer historical title from current data, search or URL. For missing/revoked/purged metadata show “Capture details unavailable” while preserving immutable citation IDs, excerpt and report bytes. Extend the report read model and reuse its URL policy. Opening a link causes no selection or decision. No re-pinning, inference, approval change or cross-workspace disclosure.

**Acceptance/falsifier.** Positive: an old pin shows its own timestamp/URL beside exact IDs/span after newer capture. Negative: changed title is labelled current; unsafe URL becomes unavailable text. Recovery: missing metadata leaves excerpt readable and explains the gap. At 320/390 px and actual 200% zoom, labels wrap and links remain keyboard reachable. Newer metadata on an old pin, unlabelled current title, unsafe link, authority mutation or view-triggered inference falsifies delivery. This candidate selects nothing. Stale-build recovery and Guide discovery remain distinct 10 alternatives; 11 outcome receipts, purge refresh and milestone coverage, plus prior08 outcome/coherence/portable-authority and approval-versus-insert dissent, remain open (`09/handoff-to-10.md`). Synthetic09 mechanics do not prove real-model/company semantics, novice comprehension or full WCAG.

## Full-read fingerprints

All paths under `docs/enhancement-program/iterations/09/`; bytes and SHA-256 are of complete local originals read before this proposal.

| Path | Bytes | SHA-256 |
|---|---:|---|
| `retro/01-product.md` | 6125 | `435f398fdfe78f9c943e3b78076b3292475e011ec82b1107f0e6284aca49614b` |
| `retro/02-architecture.md` | 6348 | `986b36d87c125695e116a77f03d499cae4375b02c308120ad6d20bf6cfdd7fc4` |
| `retro/03-security.md` | 6111 | `dbf11b3a0ac2bab3ddc5570322f40b190ab5f06f64299084a6153f3a5967ce05` |
| `retro/04-quality.md` | 6182 | `e10deededbb2711013fbdde354a762d79a04a72c6719a79d75c281f3759e7a8d` |
| `retro/05-uiux.md` | 6147 | `677a80a0c319ef6772e26afe18e165a6dae813ed6db17d0287bbb1266bfef0d8` |
| `handoff-to-10.md` | 11945 | `f665a9a20fee1fc194464af963713520c47fde0d44fdba0ef00de15ae0fe60e0` |
