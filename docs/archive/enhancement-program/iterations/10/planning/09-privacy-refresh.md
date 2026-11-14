# Iteration 10 UI/UX candidate — pinned source recognition

**Unselected.** Give the company owner recognizable source context beside each original finding excerpt. Keep exact source/revision IDs and UTF-8 spans visible. Review effort remains unmeasured.

Reuse `Company.Analysis.report/1` (`lib/harness_forge_web/components/company/analysis.ex:440–503`) and the source picker’s safe-link treatment (`:249–275`, `:537–549`). Pass existing privacy-projected scoped source DTOs from `CompanyPanel` (`lib/harness_forge_web/components/company_panel.ex`) to the report. Display the captured date and link **only when** an active/current source’s latest revision ID **and body hash** equal the pinned context reference. Label its mutable title “Current source name (may have changed)”; it is never proof of historical title. Otherwise show “Pinned source metadata unavailable or changed” with exact IDs/span and no title/link. Do not retrieve historical bodies or use latest-capture metadata as an old capture’s identity. Rendering must not select, infer, resolve, approve or repin. Existing authority validation stays in `Company.Analysis.validate_context/1` and `current_source/1` (`lib/harness_forge/company/analysis.ex:80–112,237–255`).

Acceptance: reopen an eligible report; each excerpt has qualified current name, pinned date/link and exact IDs. Change a capture, withdraw access or remove metadata; after supported refresh, no stale identity or link appears. At 320/390px and actual 200% zoom, wrapped labels and keyboard-reachable links remain usable. A link visit changes no report, decision or inference count. Any wrong-revision label, unsafe URL, view-triggered decision, or revived late output falsifies delivery. Preserve dirty-draft and reset fences (`portal_live.ex:575–641,866–903`). External-writer mounted-cache freshness remains separate: image41 persisted until reload42/43; persisted actions refused. No immediate cross-tab purge or external-export deletion is claimed.

09’s synthetic provider proves the connected mechanics, not real-company/model quality, complete obligations, log confidentiality, full WCAG or novice comprehension. Prior outcome-first, coherence-first, portable-authority/MCP-revocation and creation-versus-approval dissent remains open. No vote selects scope.

Full reads, bytes/SHA256 (paths relative to repo):

| Path | Bytes | SHA256 |
|---|---:|---|
| `docs/enhancement-program/iterations/09/retro/01-product.md` | 6125 | `435f398fdfe78f9c943e3b78076b3292475e011ec82b1107f0e6284aca49614b` |
| `docs/enhancement-program/iterations/09/retro/02-architecture.md` | 6348 | `986b36d87c125695e116a77f03d499cae4375b02c308120ad6d20bf6cfdd7fc4` |
| `docs/enhancement-program/iterations/09/retro/03-security.md` | 6111 | `dbf11b3a0ac2bab3ddc5570322f40b190ab5f06f64299084a6153f3a5967ce05` |
| `docs/enhancement-program/iterations/09/retro/04-quality.md` | 6182 | `e10deededbb2711013fbdde354a762d79a04a72c6719a79d75c281f3759e7a8d` |
| `docs/enhancement-program/iterations/09/retro/05-uiux.md` | 6147 | `677a80a0c319ef6772e26afe18e165a6dae813ed6db17d0287bbb1266bfef0d8` |
| `docs/enhancement-program/iterations/09/handoff-to-10.md` | 11945 | `f665a9a20fee1fc194464af963713520c47fde0d44fdba0ef00de15ae0fe60e0` |
| `AGENTS.md` | 1694 | `6e68397cfbbc31f5d0b4bb87827f329b3c2752de3513744b4694d76e70c557c7` |
| `docs/enhancement-program/PRODUCT_OUTCOME.md` | 4256 | `561a77e4fdf562960a65730336c5a07a364c52ff613d8c7c6954a735c37a722f` |
