# A03-01 Home: bounded implementation decision

**Blocking:** None for the proposed presentation cut. Approve implementation within the stated three-author ownership; this is a design decision, not acceptance or release approval.

**Concrete direction:** Keep `Guide.next_action/5` as the sole server selector. Present saved company, guide project and explicitly labeled assigned goals, then exactly one Home primary continuation before task forms. Move CompanyPanel’s unconditional introduction and steps into “How this works”; retain “Select corpus and goal” as a secondary task link. Keep event names, generation envelopes, dirty-draft guards and domain commands unchanged. Portal’s change is the visible Company→Home label only.

**Implementation constraints:**
- `Guide:28–30,90–98` supplies assigned goals and a project fallback, not durable selected-goal state. Label assigned goals as such; when selection is absent or ambiguous, say so. Do not call the corpus action “Resume”: `Portal:737–746` redirects without project/goal pins. Do not manufacture a selected goal from the first list element.
- `Guide:147–242` already prioritizes unavailable reads and consumes exact-plan preflight. Keep unavailable/stale explanations and the relevant recovery action outside disclosures. Make any needed navigation precedence adjustment there; do not rank readiness facts in a second selector or treat display state as approval. Preserve the approved-ancestor rebuild contract rather than rewriting eligibility for this layout task.
- `CompanyPanel:40–81,278–335` contains reset/generation and draft-sensitive navigation behavior. Open the selected task only on clean entry or explicit navigation; a normal record refresh must not collapse dirty work, pending operations or active errors. Keep task submit controls distinct from the one Home continuation—“one primary” is not a prohibition on the active form’s explicit save/review operation.
- Keep named access to setup, goals, evidence, packages, evaluations, release, Audit, Privacy and optional Chat; retain existing handlers and keyboard reachability.

**Verification boundary:** Add fixtures for empty, saved, blocked, stale, unavailable and ambiguous project/goal state; assert exactly one Home continuation, its DOM order, visible recovery and zero dispatch. Retain existing stale-generation, dirty-draft and exact-approval regressions. Actual narrow/desktop keyboard checks remain required before acceptance. A complete built fixture must not claim fresh approval or require another build merely because navigation changed.

**Non-blocking / scope limits:** A04-01 durable cross-reload setup remains an unmet predecessor. Same-mount navigation does not establish refresh/authentication/two-tab resume. Full Home/Review/Evidence consolidation and complete-scope maintenance remain outside this cut; AC1–AC5 are only partially addressed. The shared-lock repair and artifact delivery are not replanned here.

**Nit:** None. **Praise:** The cut reuses the existing selector and disclosures without adding dispatch or authority.
