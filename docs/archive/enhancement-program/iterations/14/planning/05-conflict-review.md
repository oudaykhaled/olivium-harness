# 05 — Put the decision beside its evidence

**User/job/measure.** A company operator must decide whether guidance survives a later exception or contrary incident and record why. Success is an uncoached operator identifying supporting/opposing excerpts, historical status, unknowns and separate claim/plan decisions in a public fixture. The hypothesis fails if they approve while missing a visible contradiction or mistake resolution for proof.

**Direct frozen-source observations.** The corpus report puts uncertainty, goal rationale, conflict counts and resolution above findings; each excerpt mainly shows source/revision IDs and offsets (`components/company/corpus_review.ex:425–479`). Guidance is in closed details (`:481–497`). Legacy analysis already puts a checked current source name and capture date beside citations (`components/company/analysis.ex:478–525`). The scoped corpus service provides source summaries including title, capture date, document status and effective/event dates (`company/corpus_review.ex:236–269,663–690`). The backend requires resolution for conflicted reports, preserves original citations on revision and gates approval (`company/analysis.ex:50–74,166–170,362–365`). `AnalysisV2` calls retrieval relations provisional and omitted evidence unknown (`company/analysis_v2.ex:44–54`).

**Root evidence and inference.** Root's handoff records scripted conflict resolution, separate claim/plan approvals and eight exports; static integrity passed while task evaluation was `BLOCKED: model_not_selected`. I did not run it. **Inference:** separated metadata risks a missed temporal conflict. A current title must not masquerade as a historical title.

**Smallest UI slice.** Group each finding with its excerpt, pinned identity, available title/status/dates; present support and conflict together beside goal rationale, uncertainty, guidance edit and resolution. Disclose hashes/offsets. Show metadata only for matching pins; otherwise label it unavailable. Preserve server eligibility and separate approvals. This is bounded presentation, not relevance classification.

**Acceptance examples.**

1. Given policy and a later exception, when reviewing, then both excerpts and available status/dates appear beside resolution; the operator explains applicability.
2. Given missing metadata or a changed revision, when reviewing, then the pinned excerpt remains identifiable and the UI labels metadata unavailable; no newer title or approval is implied.
3. Given conflict without resolution, when approving, then the existing gate blocks approval and focus returns to conflict/resolution; an edited successor requires exact claim and separate plan decisions.
4. Given static PASS and task BLOCKED, when viewing outcome, then the states remain distinct without claiming task success.

**Ownership/risk.** Web component owner handles presentation; a read-model owner supplies authorized pinned metadata if needed. Root owns wiring. Verify keyboard focus and stale-source recovery in a packaged browser journey. Defer entailment, contrary recall, real-model benefit and scale to 15. A new dashboard or source-wide chronology is unnecessary for this local decision.
