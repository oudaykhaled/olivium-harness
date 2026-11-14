# 05 privacy matrix: explicit goal-origin rule basis

**One bounded functionality proposal.** Let an operator approve a local goal-origin basis for an exact claim revision and goal content hash, then build/export a plan containing that rule. The operator authors the rule; selecting a goal grants no rule authority. This explains why a required practice appears without inventing an evidence citation. It does not certify policy completeness or runtime fitness.

**Current facts.** `Company.resolve/1` pins goal hashes and approved claims; `Company.approved_claim/1` requires citations ([company.ex](../../../../../../lib/harness_forge/company.ex)). `Harnesses` emits rules with `goal_id: nil` ([harnesses.ex](../../../../../../lib/harness_forge/harnesses.ex)). Source purge traces cited claims into plans/artifacts and withdraws cloud consent ([purge.ex](../../../../../../lib/harness_forge/privacy/purge.ex), [privacy/company.ex](../../../../../../lib/harness_forge/privacy/company.ex)). Restore clears decisions and revokes connections while preserving quarantined bytes ([snapshot.ex](../../../../../../lib/harness_forge/privacy/snapshot.ex)). The [04 handoff](../handoff-to-05.md) retains competing priorities; five retrospectives report no representative company/model qualification.

| Choice | Value | Privacy/lifecycle cost |
|---|---|---|
| Goal selection implicitly authorizes rules | Fastest authoring | Unreviewed normative authority; reject. |
| Explicit exact goal-origin basis **(recommend)** | Traceable practice with existing local approval model | New typed lineage, purge and restore enforcement. |
| Declared-conflict admission | Stops known contradictory revisions | Valuable separate decision; does not establish rule origin. |
| Current task identity | Improves qualification applicability | Needs trusted route/profile provenance; does not establish policy authority. |

**Acceptance and ownership.** Evidence/Company own a versioned basis `{goal_id, goal_content_hash, claim_revision_hash, actor, decision}` and approval; Harnesses emits typed goal provenance without changing legacy artifact bytes. Build/export recheck workspace, goal hash, approved claim/basis/plan revisions. Missing, stale, foreign or withdrawn bindings refuse admission. Privacy owns dependent deletion on source purge, consent withdrawal and restore quarantine: old basis decisions cannot revive authority; unrelated plans remain eligible. Test approved build/export, refusals, purge, restore and legacy verification. Exports contain neither source bodies nor transferable approval receipts.

**Risk.** A basis must not launder a purged source-derived claim. Type origin at claim creation and retain source lineage; purge invalidates dependent basis, plan, artifact and evaluation. Keep release checks authoritative and current OpenCode task applicability **Not assessed** under the [03 amendment](../../03/decision-amendment.md).
