# Iteration11: retained family-wide obligation-ID disposition

This retains the SAME ORIGINAL Astra decision-maker's interpretation already delivered to the conductor. It is not a new planning decision, approval gate, product change or amendment to the accepted ADR/interface.

**Disposition: family-wide invariant; P2 correctness/contract nonconformance; bounded correction required within iteration11.** An obligation ID retains its meaning across the rubric family's ancestor chain. Dropping it in an intermediate revision does not permit assigning it different meaning later.

The accepted frozen ADR requires stable obligation IDs and no reference remapping (`docs/enhancement-program/iterations/11/decision.md:35,43`). Accepted interface §2 states: “a successor reusing an ID must preserve that obligation's kind/text/mandatory/claim_refs exactly. Changed meaning gets a new ID.” (`docs/enhancement-program/iterations/11/review/implementation-interface.md:42`). Read “successor” in the linked family lineage, not merely the immediately adjacent pair. This interpretation preserves the existing accepted identity contract; it does not require global IDs across independent families.

Frozen `lib/harness_forge/company/assessment_validation.ex:79–85` compares obligations only with the supplied previous list. `lib/harness_forge/company/assessments.ex:283–287` supplies the immediate predecessor; stored-lineage validation at306–314 recursively checks adjacent pairs. Consequently v1 defines owner-authored X, v2 drops X, and v3 reintroduces X with changed text can pass both local comparisons. Recursive adjacent-pair validity does not establish family-wide ID stability.

**Impact is bounded.** The same family ID/obligation ID can denote different meanings after a gap, violating the advertised stable identity and making lineage interpretation unreliable. Per-rubric hashes and rubric-linked assessments still bind exact historical meanings (`assessments.ex:321–329`; `company/assessment_records.ex:1–27`); immutable UPDATE/DELETE triggers remain in the frozen migration. This is not demonstrated old-byte corruption, inherited accepted success, cross-workspace disclosure, or a trusted evaluation/release-authority bypass. Do not inflate it into those claims.

**Correction:** root may direct the SAME original author A to validate reused IDs against the complete scoped ancestor chain during both successor creation and stored-lineage validation. Preserve workspace/family checks, cycle/depth bounds, immutable predecessors and existing API error semantics. No schema change or additional author is needed. A cumulative ancestor definition map or equivalent bounded traversal can enforce the same invariant; conflicting historical definitions must fail closed rather than selecting the newest one.

Required checks:

- Negative: freeze v1 with owner-authored X; freeze v2 omitting X; attempt v3 with changed-meaning X. Refuse without a new rubric or audit. Exercise stored-lineage refusal for an otherwise hash-valid conflicting chain as well as creation refusal.
- Positive: unchanged X may return after omission; changed meaning with a fresh ID succeeds. Independent families may use their own IDs. Existing immediate-predecessor refusal and workspace/cycle bounds remain intact.
- Preservation: predecessor rubric/assessment payloads and hashes remain unchanged; no result reassignment or inherited acceptance. Root executes the meaningful red test and focused regressions; this report records no execution result of its own.

Root subsequently reported serial `family-id-red01` reproduced the intended failure at line427: expected refusal, received `{:ok, new_rubric}`; one test, one failure, exit2. This is **root-reported**, not independently executed or inspected by Astra. No unfinished patch or changing product file was read.

Evidence boundary: packet01 SHA256 `05068a34bad3daf4c2661132539570bf09e7a10c6e00e26dd4eb10fc4cc09564`; source-freeze02 manifest SHA256 `9320c0077f1f4d948daee4421f29b1326c6f470b0846f3d279b021f447a04f77`. The compact audit binds the six actual frozen files and distinguishes semantic ranges from whole-file hashes. No fresh peer QA reports, tests, runtime/browser/HTTP/DB/git operations, external calls, subagents or product/helper edits informed this disposition. Main11 installation and completion are not claimed.
