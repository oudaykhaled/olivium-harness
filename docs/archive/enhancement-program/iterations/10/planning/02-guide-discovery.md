# Iteration 10 proposal 02 — Guide discovery

**UNSELECTED UI/UX candidate.** Route the owner from saved company context to selected-history analysis, then exact recommendation review. The Guide mentions analysis but its seven tasks omit it; `next_action/5` sends owners without eligible claims straight to Evidence (`lib/harness_forge_web/components/company/guide.ex:5–13,138–147,273–275`). The Company panel already supports guarded analysis navigation and focus (`lib/harness_forge_web/components/company_panel.ex:10–25,257–265`). Its form requires deliberate selection of 2–4 captures and one assigned goal (`lib/harness_forge_web/components/company/analysis.ex:187–199,241–296`).

**Recommendation.** Add “Analyse selected history and a future goal” between project and Evidence. For a chosen project with two current assigned captures and an assigned saved goal, offer “Open analysis,” expanding the section and focusing its project selector. Show coverage and scope; preselect nothing. A saved recommendation awaiting decision leads to exact Evidence review; an eligible approved claim proceeds to plan. Distinguish availability, awaiting review, and approved evidence. Legacy manually approved claims still proceed. Reuse `Guide.project/1`, `company_guide_open`, and existing analysis/review controls. Limit ownership to Guide projection/rendering and narrow navigation.

**Acceptance.** Positive: at 320/390px and actual 200%, keyboard users reach analysis, choose inputs, reopen its report, and find exact Evidence review. Negative: insufficient/unavailable prerequisites show a specific capture/assignment remedy; report existence grants no approval. Recovery: after revision change or reload, guidance reflects saved state and requires explicit reselection/review; late events restore no draft or authority. Implicit selection, inference, decision, or wrong-project routing falsifies delivery. Reachability does not prove novice comprehension, semantic quality, or full WCAG.

One Guide row adds state complexity. Iteration 09 proved synthetic mechanics, not complete obligations or owner outcomes. Source recognition and stale-build recovery remain separate. Prior 08 outcome-first, coherence-first, portable-authority/MCP-revocation, and creation-versus-approval dissent remains unresolved; repetition selects nothing. Immutable report/pins, separate exact Evidence/plan approval, privacy, consent, and no automatic fallback or execution remain controlling.

## Full-read fingerprints

All paths relative to repository root; bytes / SHA-256. Entire files read, not excerpts.

| Path | Bytes | SHA-256 |
|---|---:|---|
| `docs/enhancement-program/iterations/09/retro/01-product.md` | 6125 | `435f398fdfe78f9c943e3b78076b3292475e011ec82b1107f0e6284aca49614b` |
| `docs/enhancement-program/iterations/09/retro/02-architecture.md` | 6348 | `986b36d87c125695e116a77f03d499cae4375b02c308120ad6d20bf6cfdd7fc4` |
| `docs/enhancement-program/iterations/09/retro/03-security.md` | 6111 | `dbf11b3a0ac2bab3ddc5570322f40b190ab5f06f64299084a6153f3a5967ce05` |
| `docs/enhancement-program/iterations/09/retro/04-quality.md` | 6182 | `e10deededbb2711013fbdde354a762d79a04a72c6719a79d75c281f3759e7a8d` |
| `docs/enhancement-program/iterations/09/retro/05-uiux.md` | 6147 | `677a80a0c319ef6772e26afe18e165a6dae813ed6db17d0287bbb1266bfef0d8` |
| `docs/enhancement-program/iterations/09/handoff-to-10.md` | 11945 | `f665a9a20fee1fc194464af963713520c47fde0d44fdba0ef00de15ae0fe60e0` |
| `AGENTS.md` | 1694 | `6e68397cfbbc31f5d0b4bb87827f329b3c2752de3513744b4694d76e70c557c7` |
| `docs/enhancement-program/PRODUCT_OUTCOME.md` | 4256 | `561a77e4fdf562960a65730336c5a07a364c52ff613d8c7c6954a735c37a722f` |
| `lib/harness_forge_web/components/company/guide.ex` | 14902 | `3aba8b0350b7944b4d6a2bcf0ce418640d276904333eb824782fc785de110f68` |

Inspected relevant portions of `analysis.ex`, `company_panel.ex`, and `portal_live.ex`; these were not full-file reads.
