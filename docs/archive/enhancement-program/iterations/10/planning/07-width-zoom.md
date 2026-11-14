# Width and zoom lens — unselected iteration 10 candidate

**Owner benefit.** Make reopened excerpts recognizable while retaining exact authority. Review prints source/revision IDs and byte spans (`lib/harness_forge_web/components/company/analysis.ex:473–497`); selection displays title, capture date and guarded HTTP(S) link (`:249–275`, `:537–550`). Show any title as **“Current source name (may have changed)”**: `source.title` is mutable, even when the latest revision matches the pin. Resolve capture date and safe URL from the exact cited revision only; otherwise say unavailable and provide no link. Keep full IDs and spans. Never label an older citation from newer capture metadata.

**Bounded implementation.** Reuse selector identity and link guard in `lib/harness_forge_web/components/company/analysis.ex`; adjust `assets/css/app.css:251–260` only if needed. Keep full, selectable title, ID, URL label, revision, hashes and byte ranges. Wrap long tokens within cards; never truncate or hide authority text. Links need keyboard access and visible focus. Extra vertical space is acceptable; retain the excerpt as primary content.

**Baseline and acceptance for root.** First record `scrollWidth`/`clientWidth`, clipping and focus on a reopened synthetic report with long title, ID, URL and span. Check **320/390 CSS-pixel** viewports at actual **100%/200% browser zoom**. Positive: pins and citations remain readable, links work by keyboard, and unintended horizontal overflow is **0 px**. Negative: changed capture, missing metadata and unsafe URL get explicit fallback without current-data substitution. Recovery: reopen after reset or discarded edit; pins and focus path persist, with no selection, inference or decision. Mislabeling, hidden text, inaccessible link, overflow or authority side effect falsifies delivery.

This improves review mechanics, not semantic quality. Iteration 09’s synthetic provider proves no real-company completeness or novice comprehension. Preserve outcome-first, coherence-first, portable-authority/MCP-revocation and approval-versus-creation dissent. Scope remains unselected.

## Full-read fingerprint appendix

All paths relative to repository root; each entry was read in full. `path | bytes | SHA-256`:

```text
docs/enhancement-program/iterations/09/retro/01-product.md | 6125 | 435f398fdfe78f9c943e3b78076b3292475e011ec82b1107f0e6284aca49614b
docs/enhancement-program/iterations/09/retro/02-architecture.md | 6348 | 986b36d87c125695e116a77f03d499cae4375b02c308120ad6d20bf6cfdd7fc4
docs/enhancement-program/iterations/09/retro/03-security.md | 6111 | dbf11b3a0ac2bab3ddc5570322f40b190ab5f06f64299084a6153f3a5967ce05
docs/enhancement-program/iterations/09/retro/04-quality.md | 6182 | e10deededbb2711013fbdde354a762d79a04a72c6719a79d75c281f3759e7a8d
docs/enhancement-program/iterations/09/retro/05-uiux.md | 6147 | 677a80a0c319ef6772e26afe18e165a6dae813ed6db17d0287bbb1266bfef0d8
docs/enhancement-program/iterations/09/handoff-to-10.md | 11945 | f665a9a20fee1fc194464af963713520c47fde0d44fdba0ef00de15ae0fe60e0
AGENTS.md | 1694 | 6e68397cfbbc31f5d0b4bb87827f329b3c2752de3513744b4694d76e70c557c7
docs/enhancement-program/PRODUCT_OUTCOME.md | 4256 | 561a77e4fdf562960a65730336c5a07a364c52ff613d8c7c6954a735c37a722f
```
