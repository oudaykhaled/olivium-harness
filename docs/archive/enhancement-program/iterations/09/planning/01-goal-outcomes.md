# 09 proposal — cross-source analysis into reviewed goals and harness

**User/job/outcome.** A company plan owner facing scattered history needs to decide which practices and failures shape the next harness. Success: a portal journey from two current revisions through editable analysis, human claim decisions, a future goal and approved plan, to company-specific export. Missing provenance or human decision falsifies delivery; real-company usefulness remains unmeasured.

**Current gap.** `lib/harness_forge/models.ex:150` proposes from one revision; `lib/harness_forge/models/proposal.ex:1` validates citations only to it. `lib/harness_forge/evidence.ex:289` persists cited claims; `lib/harness_forge/decisions.ex:7` requires approval. `lib/harness_forge_web/components/company_panel.ex:320` saves plans and later decides/builds; `lib/harness_forge/harnesses.ex:122` exports. Cross-source interpretation is absent.

**Recommendation.** Add a reviewable *company analysis draft* for 2–5 operator-selected current revisions. Reuse `Models.infer` consent/budgets and byte citations. Structured rows identify recurring practice, failure/exception, change/conflict, decision versus discussion, source anchors, uncertainty, proposed rule/check/evaluation criterion and future goal. Operator edits/rejects rows, proposes cited claims, saves a goal with acceptance text, approves claims and exact plan, then builds/exports through existing authority. Drafts remain advisory; unavailable models have no fallback. Two authors own model/domain draft and portal review; root integrates shared surfaces. Estimate 3–5 days.

**Acceptance examples.**

- Given two current sources showing recurring review and a later changed decision, when analysis runs with a consented model, then the portal shows anchors, change and editable future-goal/check recommendation; the approved rule reaches target files after plan/build/export.
- Given unresolved conflict, when reviewing, then uncertainty is shown; a rejected proposal is excluded from the exported rules, while an edit requires its own exact human approval.
- Given a source becomes stale or revoked after drafting, when approving/exporting, then existing fences refuse use; no analysis silently refreshes authority.

**Tradeoff.** Keyword extraction is cheaper/offline but cannot reliably distinguish discussion and decisions. Model drafts add provider/budget dependence and unknown quality. Synthetic fixtures verify journey/fences, not real-company semantics, managed runtime, connector scopes or portable authority.
