# Proposal 04 — resolve declared policy conflicts before admission

**Operator/job/hypothesis.** A company operator must decide which of two declared, incompatible approved claim revisions governs a plan before sharing it. Success: every declared conflict in accepted plans has an exact, reviewable resolution; zero unresolved pairs pass build/export. One admitted unresolved pair falsifies the hypothesis. Automatic conflict discovery and company fitness remain unmeasured.

**Evidence and choice.** [Company](../../../../../lib/harness_forge/company.ex) pins claims and rechecks approval at decision/build; [Harnesses](../../../../../lib/harness_forge/harnesses.ex) rechecks binding at export. Neither represents conflict resolution. The [04 handoff](../../04/handoff-to-05.md) preserves three candidates. Goal-origin basis explains *why* a rule exists but leaves incompatible rules unresolved. Task-route identity improves applicability, but spans execution and must preserve [03 abstention](../../03/decision-amendment.md) until proven. Conflict admission offers direct operator value through a narrower gate, conditional on declaration. Select by value, reliability and simplicity, not votes.

**Bounded contract.** Add immutable workspace-scoped declarations for two exact approved claim revisions and a plan revision. An actor explicitly resolves precedence; compilation excludes the losing rule for that plan. Resolution is distinct from claim/plan approval. Recheck at plan approval, build, export and release eligibility; never reuse it across revisions. Preserve existing artifact bytes and admission for plans without declarations. Do not infer conflicts from text.

**Acceptance.**

- Given a declared pair and exact resolution, when the operator approves and builds that plan, then the losing rule is absent from its package and the decision remains reviewable.
- Given an unresolved pair, when approval, build or export is attempted, then admission refuses with a conflict-specific reason and publishes no new package/export bytes.
- Given a changed/withdrawn claim, superseded plan, foreign workspace reference or restored quarantine, when admission is retried, then the old resolution has no authority; an unrelated plan remains eligible.

**Ownership/risk.** Company/Evidence own declarations and decisions; Harnesses/release own rechecks; privacy owns purge and restore withdrawal; web/CLI expose explicit choice. Undeclared contradictions remain the main risk. Evaluate disclosure with representative tasks; model/runtime qualification stays separate.
