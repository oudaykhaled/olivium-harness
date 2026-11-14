# Company-outcome lens: iteration 10 UI/UX

**Recommend recognizable pinned evidence in reopened analysis. Scope remains unselected.** The owner judges whether guidance reflects authorised history and future intent before deciding. Selection shows title, capture date and guarded link; reopened excerpts show only source/revision IDs and byte spans (`lib/harness_forge_web/components/company/analysis.ex:262–275, 480–497`). Recognition at the decision point eases checking a recommendation's basis without claiming measured comprehension or semantic support.

Reuse the analysis report and selection's safe-link treatment. Pass already-loaded sources into `report/1`; retain exact source ID, revision ID and span. `Source.title` is **current** metadata and must be labelled as such, never represented as historical title. Show capture date and source URL only when metadata is demonstrably bound to the cited revision; the normal source DTO exposes only `latest_revision` (`lib/harness_forge/evidence.ex:681–689`). For an older, changed, unavailable or unsafe capture, explicitly say pinned metadata unavailable and render no link. Do not silently substitute the latest capture. Preserve immutable original report, exact Evidence approval, separate plan approval, privacy/scope checks and zero inference on reopening.

**Trade-off.** Stale-build recovery also helps when evidence changes: `PackageBuild` maps some refusals to generic copy (`lib/harness_forge_web/package_build.ex:31–57`), and build focuses only a name error (`lib/harness_forge_web/live/portal_live.ex:1046–1063`). It has wider error-classification and navigation blast radius. Source recognition touches report presentation and data pass-through, reaches earlier human judgment, and is easier to falsify. Guide discovery remains open.

**Acceptance/falsifier.** Positive: reopen a report whose cited revision is still the exposed capture; each excerpt shows current title clearly qualified, exact pin/span, capture date and safe link. Negative: after a newer capture or unsafe URL, the old pin remains and metadata/link show unavailable; no decision, selection, report byte or inference count changes. Recovery: at 320/390px and actual 200% zoom, long labels wrap, links and controls remain keyboard reachable, and returning from a source does not change the selected report. A mismatched capture label/link or implicit authority change falsifies delivery. Owner-reviewed representative tasks must later establish usefulness, obligation coverage, coherence and interruption recovery; synthetic construction cannot qualify complete-company reliability.

Full reads (bytes; SHA-256):

| Path | Bytes | SHA-256 |
|---|---:|---|
| `09/retro/01-product.md` | 6125 | `435f398fdfe78f9c943e3b78076b3292475e011ec82b1107f0e6284aca49614b` |
| `09/retro/02-architecture.md` | 6348 | `986b36d87c125695e116a77f03d499cae4375b02c308120ad6d20bf6cfdd7fc4` |
| `09/retro/03-security.md` | 6111 | `dbf11b3a0ac2bab3ddc5570322f40b190ab5f06f64299084a6153f3a5967ce05` |
| `09/retro/04-quality.md` | 6182 | `e10deededbb2711013fbdde354a762d79a04a72c6719a79d75c281f3759e7a8d` |
| `09/retro/05-uiux.md` | 6147 | `677a80a0c319ef6772e26afe18e165a6dae813ed6db17d0287bbb1266bfef0d8` |
| `09/handoff-to-10.md` | 11945 | `f665a9a20fee1fc194464af963713520c47fde0d44fdba0ef00de15ae0fe60e0` |
| `AGENTS.md` | 1694 | `6e68397cfbbc31f5d0b4bb87827f329b3c2752de3513744b4694d76e70c557c7` |
| `PRODUCT_OUTCOME.md` | 4256 | `561a77e4fdf562960a65730336c5a07a364c52ff613d8c7c6954a735c37a722f` |

Prior 08 dissent stays live: outcomes, coherence, portable authority/MCP revocation, and creation versus approval coverage are distinct questions. Repetition is not selection.
