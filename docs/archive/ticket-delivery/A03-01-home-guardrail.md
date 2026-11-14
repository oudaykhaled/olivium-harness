## GUARDRAIL BRIEF — One scope-aware Company Home action

**Classification:** Bounded WEB presentation/navigation · reversible · no domain, router or CSS change.

**Verdict:** PROCEED-WITH-CONDITIONS. No blocking questions.

**Guardrails that apply (ranked):**
1. [guide.ex:147–234; A03-01-next-slice.md] Keep `Guide.next_action/5` the sole Home continuation selector. Remove the competing unconditional primary; render status and the selected action before task forms. Preserve unavailable/preflight recovery precedence. Navigation opens existing controls only: no automatic retrieval, synthesis, approval, build, export or evaluation.
2. [company_panel.ex:236–335; portal_live.ex:737–775] Preserve authentication, event-generation checks, draft guards, exact claim revision handoff and focus targets. Do not replace guarded events with bare redirects. Keep dirty drafts, pending work and active errors visible when folding static introductory/help content; refresh must not reset or hide unsaved work. Preserve existing independent explicit claim and plan decisions.
3. [guide.ex:90–98,319–325; portal_live.ex:737–746] Show the actual guide project or an explicit scope-selection need. Assigned goals are saved goals, not a selected analysis goal; do not infer one from multiple assignments. Corpus navigation carries no project/goal pins, so label it “Select corpus and goal,” never “Resume analysis.” No refresh, authentication or two-tab durable-resume claim: A04-01 remains undelivered.
4. [A03-01-next-slice.md; AGENTS.md] Keep exactly one primary continuation in the Home summary while retaining necessary task-form actions. Use existing accessible disclosures and stable IDs; keyboard activation must open/focus the intended control. Root owns CompanyPanel and label-only Portal; WEB owns Guide; QA owns the new focused test—maximum three authors including Root. Preserve current frozen candidate and separate this slice’s source/evidence.

**Hard STOPs:** No second success-ranking function, global completion claim, hidden recovery, implicit goal/approval choice, or broader navigation redesign.

**Definition of done:**
- [ ] Empty, saved, ambiguous-scope, blocked/stale and unavailable states show one honest Home action before forms.
- [ ] Dirty/stale events preserve work and dispatch no domain operation; desktop/narrow keyboard checks confirm focus and discoverability.
- [ ] Root records relevant checks and actual WEB verification. This bounded slice does not complete A03-01 or its A04-01 dependency.

**Knowledge base:** Unchanged; exact read ranges/hashes and initial search truncation are recorded in the companion audit. No product/tests/runtime/boards/screenshots/private Main accessed or changed beyond source reads.
