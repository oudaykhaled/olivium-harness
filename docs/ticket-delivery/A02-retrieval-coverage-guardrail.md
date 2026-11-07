## GUARDRAIL BRIEF — Bind retrieval capture coverage to the explicit declaration

**Classification:** Additive retrieval metadata/validation correction; affects readiness gating, not consent or source admission.

**Verdict:** PROCEED-WITH-CONDITIONS. No blocking question or binding objection to the selected declaration approach.

**Guardrails that apply (ranked):**
1. [retrieval.ex:697–722; requirements.ex:50–65,526–550] Replace only the declaration-bearing run’s corpus-latest capture decision with the checked declaration’s `required_status == "complete"`. The current latest-run query proves the ordering defect. Preserve nonempty selected passages, index completeness, packing/parent-context, question coverage, graph certificates, source eligibility and every existing dispatch/consent gate. An optional omission changes declared coverage, never grants inference permission or semantic sufficiency.
2. [requirements.ex:95–140,239–247,324–355] Accept only an optional strict `{id,digest}` reference, never caller-supplied completion/omissions. Check full workspace/corpus/project/profile/goal hashes and generations against the captured retrieval scope. Reject explicit malformed, mismatched, superseded or unavailable declarations; only genuinely absent references use historical legacy semantics. Do not silently strip an invalid reference or select a newer declaration.
3. [retrieval.ex:623–652,969–983; requirements.ex:436–475,554–569] Bind the exact declaration reference in the immutable envelope and a deterministic compact checked coverage basis in the run digest: declaration revision, required status, exact capture IDs/revisions and omission reason/provenance. Recheck at initial capture, publication and every checked-run/resolve path. Compare the freshly derived basis with the stored basis; never rewrite old runs. Supersession, receipt revision/config/root changes or omission changes invalidate even without a corpus generation change. Exclude timestamps/display names from identity unless deliberately part of the contract.
4. [assessment_attempts.ex:8–24; requirements.ex:50–67] Keep real caller authorization for user-facing retrieval, publish, read and analysis resolution. For callerless `validate_current`, a private backend-only adapter may reuse the same summary with fixed server-owned authorization context solely to return validity; it must still execute workspace/privacy fences and all declaration/access checks. Do not weaken options validation, expose this adapter as an endpoint, accept its context from input, mint an operator session/consent, or use it for dispatch. Prefer threading the actual caller through guarded paths; reserve internal context for the existing trusted currentness path only.

**Hard STOPs:** No invalid-reference fallback, latest-run replacement, skipped required controls, changed retrieval membership, forged consent or historical digest migration.

**Definition of done:**
- [ ] Required complete plus optional failed works in either capture order; required failure/unknown and undeclared members remain non-ready.
- [ ] Same-generation declaration supersession and receipt-revision change invalidate saved runs; cross-scope/tampered refs and coverage fail.
- [ ] Revoked real callers remain denied; reference-free historical runs keep legacy behavior; Root reruns the failing regression and relevant browser path.

**Knowledge base:** Unchanged. Exact ranges/hashes recorded in the companion audit. No product changes, tests, runtime or boards accessed by this task.
