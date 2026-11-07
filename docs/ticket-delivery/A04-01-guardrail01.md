## GUARDRAIL BRIEF — A04-01 durable WEB setup

**Classification:** Additive session persistence + navigation · Root-owned schema/routes · maximum three implementation lanes.

**Verdict:** PROCEED-WITH-CONDITIONS. No blocking questions.

**Guardrails that apply (ranked):**
1. [AGENTS.md; A04-01 scope/AC3] Persist workspace/principal-owned, versioned sessions containing bounded drafts and exact references only: goal/outcome, selected scope, operations and decisions. Resolve workspace and authenticated owner from server context on every read/write; URL/session IDs grant no access. Use a stable owner identity across reauthentication, not a transient connection token. No credentials, source bodies or client-supplied approval/completion fields; reject unknown commands and keys without creating atoms.
2. [A04-01 AC1–3] Save/back/continue/change require session ID and expected version. Atomically compare-and-update; stale tabs receive conflict plus the current authorized revision, never overwrite newer state. Acknowledge saved state only after commit. Restore acknowledged selections/references after refresh/logout/restart without dispatch; preserve unsaved input visibly on validation/conflict. Replayed stale requests cannot silently advance navigation twice.
3. [A04-01 scope; A04-02 scope/AC1–5] Navigation and saved defaults grant no acquisition, consent, claim/plan approval or job admission. Continue opens the existing next control. A04-02 separately owns exact-manifest stage consent, destination/usage checks and shared run limits; never duplicate that authority in sessions or infer permission from a saved grant reference.
4. [A04-01 dependencies/AC4; AGENTS.md] Consume exact A02-01 goal and A02-02 readiness contracts. On restoration and dependent actions, revalidate scope, revisions/generations, current access and revocation; historical references remain historical, stale/unavailable facts cannot project complete. Preserve independent collection, understanding, evaluation and release states and existing guarded navigation/focus behavior.
5. [A04-01 AC5] **First two persisted steps plus an honest unavailable later-step shell are permitted as partial delivery:** “Early implemented steps can ship with later test/release steps explicitly unavailable.” This does not satisfy AC1’s restoration of all seven steps or complete A04-01. Expose missing producer/capability reasons and safe recovery; do not mark inaccessible steps saved or done.

**Definition of done for this slice:**
- [ ] Real save/refresh/reauthentication, conflict, forged ownership/reference and revocation checks pass with zero navigation-triggered dispatch.
- [ ] Loading/early-click behavior is addressed or explicitly retained as open: waiting for connected DOM in CLI is not a human-interaction fix.
- [ ] Root records slice-specific verification, preserves source10/385-pin baseline and keeps full A03/A04 completion unclaimed.

**Knowledge base:** Unchanged. No product/tests/runtime/network/board changes; exact document hashes/selectors and read limits are audited.
