## GUARDRAIL BRIEF — CSS-corrected native helpers

**Classification:** Root-only local build/QA restart · CSS-only product correction · same disposable workspace/schema.

**Verdict:** **PROCEED-WITH-CONDITIONS / STATIC GO.** No material helper-code blocker. This authorizes the reviewed local sequence under existing root ownership; it is not corrected native acceptance, a new execution result or permission expansion.

**Actual reviewed SHA256 values** — paths below are under `tmp/enhancement-program/06/`:

| Helper | SHA256 |
|---|---|
| `build_native_corrected.py` | `2be98cd57d6eb54d1978e99d56e5b9e95a92946d572cbb99cf717b79397ca73e` |
| `verify_corrected_release.py` | `98795b62b0d82890952332b85824259e4b4fbb3f41e3f4c1a8935ece04429e04` |
| `start_native_corrected_qa.py` | `52416b4020cec318a373ca359ee83204191dd8211afcc39fefe81734c2a9e9c9` |
| `verify_corrected_binding.py` | `878681cf8fbf192a761d3c46504ae5c9393fd38642c2da146e43812e8ca82526` |

**Guardrails/checks, ranked:**

1. **Fresh outputs; preserve running releases and failures.** Direct full diffs of build/release-verifier/launcher against originals show only corrected release/output/verifier-path substitutions. Build refuses existing `native-corrected` (`tmp/enhancement-program/06/build_native_corrected.py:4`), but logs/manifests use overwriting writes (`:23`, `:25`, `:30`): root must preflight all corrected outputs before first use and preserve partial attempts before retry. Reserve the sole Mix window; generated overlay refresh cannot authorize running-release overwrite. Retain original02 failed images and parser attempts.

2. **Restart the same QA workspace without reseeding.** Root identifies existing02 PID/release/open database, gracefully stops it and verifies port8872 release before launcher use. Launcher preserves `tmp/u06`, MCPoff and fixed probe (`tmp/enhancement-program/06/start_native_corrected_qa.py:15`, `:26`), checks release/open database (`:69`) and exposes only fixed stdin commands (`:78`). Preflight server-log/events paths before spawning; exclusive observer files are opened afterward (`:30`, `:41`). Root separately corroborates listener identity and before/after workspace preservation. Never rerun fixture seeding.

3. **Require both verifier stages before attributing corrected evidence.** Build automatically invokes only release verification (`tmp/enhancement-program/06/build_native_corrected.py:34`); root must additionally run binding. Binding retains the corrected per-line parser, compares nonempty application declarations against complete BEAM filenames on both sides, requires identical 126-module sets and dynamic asset count ≥41 (`tmp/enhancement-program/06/verify_corrected_binding.py:25`, `:32`, `:39`). Retained-chunk verification remains exact for copied chunks, not raw BEAM equality. Source binding refuses non-generated drift/deletions and records generated changes/additions (`:9`, `:20`). It records actual asset count, preserving non-vacuity without freezing generated count at 41. It no longer rewrites historical parser-attempt evidence.

4. **Preserve fixed containment and honest claims.** Probe SHA remains `7309c451376fd96d9eaf44ac5ef11b170e8149bcc65da0928e3900f9b79f4c77`: only tmp/u06:8872, one connected Portal, one suspension/launch, watchdog-before-suspend, queue-zero refusal. No public endpoint, authority seed, automatic approval, credentials or generated-harness execution. Freeze03/QA03/reuse-contract hashes match root's supplied anchors. Snapshot CSS diff adds only `overflow-wrap:anywhere` to existing `.artifact-row`; no corrected E3 pass follows from source. Root's unsafe-path JSON records remain attributed to root, not this reviewer's execution.

**Definition of done:** Root records successful fresh build/binding, identified preserved-workspace restart and actual corrected native evidence; failed/inconclusive02 evidence remains retained.

**Knowledge base:** unchanged. Only this new report written; earlier briefs untouched. No helper/runtime/DB/Mix/browser execution or product edits.
