# Goal-origin rules and explicit conflicts

**Priority: high, after the current claim-only company flow.** A company can state a measurable goal, yet its harness only receives that goal as future intent. Users cannot turn it into a bounded instruction or record why two proposed instructions disagree. This leaves the exported guidance incomplete for a real company.

## Code evidence

- `Goals.add_goal/1` stores title, owner and acceptance, with no rule text or revision workflow (`lib/harness_forge/goals.ex:11-25`).
- Company plans select goal IDs and approved claim revisions, but the plan payload has no goal-rule or conflict field (`lib/harness_forge/company/validation.ex:5,37-67`). `Company.resolve/1` pins goal content hashes and exact claim references (`lib/harness_forge/company.ex:234-260`).
- `Harnesses.specification/3` makes every rule from a claim and sets `goal_id` to `nil` (`lib/harness_forge/harnesses.ex:184-205`). The contract already accepts a rule with an explicit goal ID and empty evidence (`lib/harness_forge/contracts.ex:307-317`). The acceptance test currently asserts all rule goal IDs are nil (`test/harness_forge/company_acceptance_test.exs:115-119`).
- The plan has a separate exact-revision approval and rechecks eligibility at build (`lib/harness_forge/company.ex:110-133,138-151,318-334`); this is the natural review boundary. The delivery handoff identifies goal-origin rule basis and explicit conflict records as remaining extensions (`docs/handoffs/company-builder.md:80-83`).

## Bounded proposal

Add optional `goal_rules` to a company plan. Each entry carries a stable local ID, statement, selected `goal_id`, and a short basis explaining how the rule advances that goal's acceptance condition. It may reference only a goal selected in the same plan. Compile it as a rule with `goal_id`, empty evidence and a stable ID derived from the plan entry; show its goal title, owner, acceptance and basis during plan review. Treat goal text and basis as proposed user intent, never as sourced organizational fact or runtime permission.

Add optional `conflicts` to the same immutable plan revision. Each record names two selected rule IDs (claim or goal origin), a reason, a disposition (`block`, `prefer_first`, `prefer_second`, or `rewrite`), and rationale. `block` prevents approval/build. A resolved disposition must identify the surviving rule or a replacement goal rule in this revision; compilation includes only the surviving approved selection. Show a visible conflict register in plan review and package provenance. Conflict records are human declarations: do not claim automated semantic conflict detection. Changing a rule or resolution creates a successor plan and requires its own approval.

Keep claim decisions separate and binding. A goal rule cannot cite a rejected or unapproved claim as its basis, impersonate a citation, or expand repository scope. No new model call, connector, migration, or runtime privilege is needed for a first slice; store the entries in the existing plan payload/snapshot and render them through the current compiler path.

## Acceptance and negative cases

1. A selected goal with an approved plan produces a goal-origin rule with the exact goal ID, empty evidence, stable output bytes, and visible basis; claim-origin rules retain exact approved revisions.
2. A conflict between two selected rules appears in plan review and the package. `block` refuses approval and build; a resolved disposition compiles only the surviving instruction. Changing the resolution changes the plan hash and requires a new decision.
3. Reject foreign or unselected goals, dangling or duplicate rule IDs, self-conflicts, invalid dispositions, and a replacement that is not selected. Stale goals, revoked sources, superseded claims, and rejected claim revisions still fail eligibility.
4. A goal statement alone never silently becomes an instruction. An undeclared contradiction is not asserted to be detected; UI copy describes the register as explicit reviewer input.

**Scope limit:** This iteration improves deterministic plan review and export. Semantic conflict discovery and organization-wide policy precedence need separate design and evaluation.
