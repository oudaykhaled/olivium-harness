# Iteration 10 candidate — enter company analysis deliberately

**Owner and job.** A company owner with captured history and a future goal needs to find analysis and understand the next human decision. The Guide jumps from project membership to Evidence (`lib/harness_forge_web/components/company/guide.ex:5-12,168-179`), while analysis already supports selection, original findings and Evidence navigation (`lib/harness_forge_web/components/company/analysis.ex:185-204,321-415`). The connected route is easy to miss.

**Proposal.** Add “Analyse selected history and a future goal” after Guide membership. With 2–4 current assigned captures, an assigned saved goal and no eligible approved claim, its next action opens and focuses existing analysis selection. Explain the route: proposed recommendation → human edit/reject/exact Evidence approval → separate exact Company plan approval → build to target files. Preserve the manual Evidence route. Reuse Guide’s saved-state projection and controls (`guide.ex:15-86,323-377`) and existing analysis UI.

**Success/falsifier.** Measure whether an owner enters analysis and identifies the next explicit review step without help. False readiness, silent selection changes or implied approval before both decisions falsifies the proposal. Synthetic navigation cannot prove novice comprehension or real-model/company quality.

- **Positive:** Given a scoped project, two current assigned captures, an assigned goal and no eligible approved claim, when the owner opens Guide’s next action, then analysis selection opens, explains Evidence→plan→build, and starts no inference.
- **Negative:** Given no assigned goal or fewer than two current captures, when viewing Guide, then analysis shows the missing prerequisite, manual Evidence remains reachable, and no request/decision is created.
- **Recovery/edge:** Given a changed capture, when Guide refreshes at 320/390px and actual 200% zoom, then it shows current recovery with keyboard-reachable focus; old pins, drafts and approvals remain unchanged.

Source recognition aids inspection; stale-build guidance aids later recovery. Neither fixes entry. Outcome-first, coherence-first, portable authority/MCP revocation and approval-time versus creation-time coverage dissent remains. Privacy, immutable pins and explicit authority remain binding.

## Read fingerprint (complete originals)

SHA-256 of bytes read:

| Path | SHA-256 |
|---|---|
| `docs/enhancement-program/iterations/09/retro/01-product.md` | `435f398fdfe78f9c943e3b78076b3292475e011ec82b1107f0e6284aca49614b` |
| `docs/enhancement-program/iterations/09/retro/02-architecture.md` | `986b36d87c125695e116a77f03d499cae4375b02c308120ad6d20bf6cfdd7fc4` |
| `docs/enhancement-program/iterations/09/retro/03-security.md` | `dbf11b3a0ac2bab3ddc5570322f40b190ab5f06f64299084a6153f3a5967ce05` |
| `docs/enhancement-program/iterations/09/retro/04-quality.md` | `e10deededbb2711013fbdde354a762d79a04a72c6719a79d75c281f3759e7a8d` |
| `docs/enhancement-program/iterations/09/retro/05-uiux.md` | `677a80a0c319ef6772e26afe18e165a6dae813ed6db17d0287bbb1266bfef0d8` |
| `docs/enhancement-program/iterations/09/handoff-to-10.md` | `f665a9a20fee1fc194464af963713520c47fde0d44fdba0ef00de15ae0fe60e0` |
| `AGENTS.md` | `6e68397cfbbc31f5d0b4bb87827f329b3c2752de3513744b4694d76e70c557c7` |
| `docs/enhancement-program/PRODUCT_OUTCOME.md` | `561a77e4fdf562960a65730336c5a07a364c52ff613d8c7c6954a735c37a722f` |
