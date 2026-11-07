# 05 — Owner-declared mandatory goals at plan approval

**Problem/job.** A company owner reviewing a plan needs every explicitly mandatory obligation included before harness approval. Goals carry owner and acceptance text (`lib/harness_forge/goals.ex:18-31`); rules can become goal-backed claims (`lib/harness_forge/evidence.ex:380-399`). Company plans pin selected goals and approved claim revisions (`lib/harness_forge/company.ex:234-261`). Yet profile/project goal IDs define an allowed pool; `resolve/1` checks selected IDs only, and approval tests no omissions (`lib/harness_forge/company.ex:245-250,340-344`). The source proves an accounting gap, not a missed real-company policy.

**One benefit.** Let the owner mark a bounded subset of existing profile goals as `required_goal_ids`; default to `[]` for legacy profiles. At `Company.decide_plan/2` approval, require each declared ID in the exact plan `goal_ids`; return sorted, bounded missing IDs. Reuse profile content hash, plan snapshot and transactional decision/audit path. The owner decides mandatory status; goal titles, source prose and the allowed pool confer no duty. Draft plans and rejection remain possible. This differs from milestones for already selected goals.

**Acceptance:**

- Given a profile with two owner-marked required goals and a current plan selecting both, when its exact revision is approved, then one decision and audit record bind that revision.
- Given one required goal absent from a plan, when approval is attempted, then bounded missing IDs are returned and no decision, audit, or build artifact is created.
- Given a legacy profile with no required goals, when a current plan is approved, then existing approval behavior holds; given a changed profile after proposal, the existing stale-snapshot refusal still applies, and historical decisions remain immutable.

**Trade-off/effort.** One focused domain/validation and caller-contract change plus regression tests; profile edits can force reproposal. Unlike selected-goal milestone coverage, this catches an owner-declared obligation omitted *before selection*, but cannot judge claim/milestone quality or unknown policy. A reviewed obligation register offers greater precision at greater schema/UI cost. **Metric:** zero approvals omitting declared IDs. One such approval falsifies delivery; an owner-reviewed omitted real obligation despite this gate falsifies company-readiness claims.
