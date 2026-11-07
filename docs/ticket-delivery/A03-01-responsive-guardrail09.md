## GUARDRAIL BRIEF — Company Home first-screen action

**Classification:** Company-only presentation · reversible.

**Verdict:** PROCEED-WITH-CONDITIONS. No binding blocker.

**Guardrails that apply:**
1. Collapse only the Company tab’s global introduction/demo block into a closed native “About this workspace and demo” disclosure. Keep its existing demo button ID and guarded handler; expanding the disclosure must never load data or dispatch work. Preserve authentication, dirty-draft and consent guards.
2. Reuse one heading-render helper without duplicate DOM IDs. Preserve headings, structure and behavior of the other nine tabs. keep active errors, unavailable-state explanations and required decisions outside optional introductory content.
3. Leave `Guide.next_action` and existing scope/declaration/approval rules unchanged. Do not achieve visibility by hiding blockers, shrinking essential controls, clipping text . Native disclosure must work by keyboard and expose expanded/collapsed state.
4. Root verifies actual geometry at 320px, 390px and desktop widths using recorded viewport heights. Record the primary button’s top/bottom and visibility at initial scroll position; document Y alone does not prove first-screen usability. The entire primary control must be usable without initial scrolling; never hide important error/draft content to meet this.

**Definition of done:**
- [ ] Default Company view exposes one usable primary action; disclosure/demo remain discoverable and keyboard-operable.
- [ ] Other tabs retain their headings; no duplicate IDs or accidental dispatch.
- [ ] Root records focused verification and actual browser measurements against the new candidate.

**Knowledge base:** Unchanged. Assessment uses Root’s stated measurements/proposal; no fresh source, tests, browser or images inspected.
