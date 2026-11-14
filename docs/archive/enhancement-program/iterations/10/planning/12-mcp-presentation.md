# Planner 12 — MCP presentation consistency (unselected)

**Recommendation:** Show recognizable *pinned* sources in the portal’s reopened analysis report so owners can verify historical support before Evidence approval. Keep own-MCP unchanged: its three read-only tools expose catalogue, plan readiness and package metadata, not excerpts (`lib/harness_forge/mcp/tools.ex:28–72,135–268`). An MCP analysis reader would widen disclosure. Portal selection displays title, capture date and URL (`lib/harness_forge_web/components/company/analysis.ex:249–275`); reopened citations show IDs, revision and span (`:475–497`). Reuse revision-aware presentation without changing report bytes or approval logic.

**Contract:** Identify exact pinned source/revision. `Source.title` is mutable current metadata, so label it “Current source name (may have changed)” or unavailable; never claim it was the capture-time name. Capture date and safe HTTP(S) URL must come from the exact revision. Otherwise show “Pinned capture metadata unavailable”; preserve IDs/span. Label current freshness separately. Opening a report/link causes no selection, inference, approval, build or export. Reveal no body beyond the existing excerpt. Titles/links are data, not instructions. Scoped MCP `buildable`/`eligible` remain momentary observations, never portable authority (`lib/harness_forge/mcp/tools.ex:176–268`; `lib/harness_forge/mcp/auth.ex`).

**Acceptance/falsifier:** Unchanged capture shows exact IDs, revision date/link and qualified current name, wrapping and keyboard focus at 320/390px, actual 200%. New latest capture leaves old revision metadata or explicit unavailable text; missing/unsafe URL yields no link. Historical-name claim, wrong pin, leaked body, view side effect or implicit decision fails. Guide discovery, stale-build recovery, full WCAG, novice use, real-model quality and complete obligations remain unresolved. Preserve 08 outcome/coherence/portable-authority and creation-versus-approval dissent.

Read-only fingerprints (bytes, SHA-256; full reads except portal excerpt):

| Input | Bytes | SHA-256 |
|---|---:|---|
| `09/retro/01-product.md` | 6125 | `435f398fdfe78f9c943e3b78076b3292475e011ec82b1107f0e6284aca49614b` |
| `09/retro/02-architecture.md` | 6348 | `986b36d87c125695e116a77f03d499cae4375b02c308120ad6d20bf6cfdd7fc4` |
| `09/retro/03-security.md` | 6111 | `dbf11b3a0ac2bab3ddc5570322f40b190ab5f06f64299084a6153f3a5967ce05` |
| `09/retro/04-quality.md` | 6182 | `e10deededbb2711013fbdde354a762d79a04a72c6719a79d75c281f3759e7a8d` |
| `09/retro/05-uiux.md` | 6147 | `677a80a0c319ef6772e26afe18e165a6dae813ed6db17d0287bbb1266bfef0d8` |
| `09/handoff-to-10.md` | 11945 | `f665a9a20fee1fc194464af963713520c47fde0d44fdba0ef00de15ae0fe60e0` |
| `AGENTS.md` | 1694 | `6e68397cfbbc31f5d0b4bb87827f329b3c2752de3513744b4694d76e70c557c7` |
| `PRODUCT_OUTCOME.md` | 4256 | `561a77e4fdf562960a65730336c5a07a364c52ff613d8c7c6954a735c37a722f` |
| `mcp/tools.ex` | 10863 | `9a435420a81c4be5385fb7b725081963c1c8e6ac817e257181f49b364aa81e95` |
| `mcp/auth.ex` | 2383 | `533a10e8d6646ee1b9771372c55a7d43e13ac74a00ef4f73b12fa58cbce3f5ac` |
| `mcp/protocol.ex` | 5311 | `08e90d8a2fb2ba43e75c2d7728b70d3db66268844c26947a20ecad3d5086d212` |
| `web/components/company/analysis.ex` (excerpt) | 22909 | `1ecf42581e721220b28678f82a0bd4606086df55d63b41e9f00ab7ec507c30e2` |
