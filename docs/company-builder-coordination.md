# Company builder coordination

Status: frozen delivery contract; implemented and verified locally, 1 November
2026. Results are tracked in `PROGRESS.md` and
[the verification record](company-builder-verification.md). No publication is claimed.

## Sessions and ownership

The root owns the local board, integration, shared configuration, migrations,
router/application changes and final verification. Maximum three implementation
lanes are active at once. All agents preserve concurrent changes. Planning and
review sessions may inspect work but do not silently expand their file ownership.

| Session | Responsibility | Files / handoff |
| --- | --- | --- |
| Planning/domain | Freeze scope, language, record authority and compatibility | `docs/company-builder-contract.md`, this document, `GLOSSARY.md` |
| Company implementation | Catalogue, applicability, immutable plans, roadmap milestones within plans | `lib/harness_forge/company.ex`, `lib/harness_forge/company/` excluding the binding record, focused context tests; hand root a migration proposal |
| Composition implementation | Approved-plan admission, fixed presets and local artifact bindings | `harnesses.ex`, finite template registry, binding record and focused tests; preserve compiler/schema and v1alpha1 bytes |
| Portal implementation | Authenticated company/project/plan forms and browser-facing selection | Assigned portal/component files and focused UI tests |
| Root integration | CLI, persistence/privacy integration and final verification | CLI, migrations, privacy, shared config/router/application, board |
| QA/review | Independent contract checks and acceptance evidence | Read-only review first; test-only ownership assigned explicitly before writes |

The root has frozen the contract in [company-builder-contract.md](company-builder-contract.md).
Changes require a coordinated amendment before dependent implementation proceeds.
Authors report changed files, exact checks, limitations and open integration needs.
No implementation lane delegates further without an explicit root assignment.

## Bounded waves

1. **Catalogue and scope.** Create the company profile, repositories and project
   memberships; associate existing sources and goals; search capabilities and
   derive consumers. Verify workspace boundaries and explicit applicability.
2. **Plans and compilation.** Persist immutable plan revisions, select eligible
   approved claims and goals, select finite presets, build existing v1alpha1 for
   three native targets, verify deterministic outputs and safe export. Revalidate scope and
   authority at publication/export/release. Complete privacy integration before
   treating these records as delivered.
3. **Roadmap and connected UX.** Author proposed capability items, dependencies,
   acceptance/evaluation methods and version links. Reject cycles and missing refs.
   Exercise the complete company-to-export path through authenticated controls.
4. **Follow-up authority work (separate scope).** Goal-origin claims, portable
   composition provenance and explicit conflict-resolution records require their
   own contracts and tests. They are not
   hidden prerequisites or silently implemented via plan instructions.

Each wave ends in a working local slice, not only tables or unused domain APIs.
Roadmap order is a dependency view; no invented scheduling, effort estimates or
automatic policy adoption is promised.

## Acceptance scenario

Use only public synthetic fixtures in a fresh workspace. No private imports,
paid model calls or publication are needed.

1. Create company **Example Works**, projects **Commerce** and **Support**, and
   repositories `example/identity`, `example/orders`, `example/helpdesk`.
2. Register identity's authentication capability. Orders declares an identity
   dependency. Capability search returns identity; consumers lists orders.
3. Import company, commerce and support guidance, including a rejected injection.
   Assign source applicability deliberately. Approve exact company/commerce claim
   revisions individually; leave another proposed and reject the injection.
4. Create a Commerce goal with owner and acceptance conditions. Select it as future
   intent. No goal-derived organizational rule becomes approved by this action.
5. Create Commerce plan `0.1.0`, selecting identity/orders, exact eligible claims,
   the goal and finite reviewed-change/reuse presets. Explicitly approve its exact
   revision through a separate plan decision. Support content is excluded.
6. Create and approve one target-specific plan for each native runtime (runtime
   is pinned in the plan). Build each twice. Compare bytes and per-target digests. Export each into a fresh contained destination and verify integrity.
7. Create and explicitly approve `0.2.0` with one deliberate reviewed selection/
   component change. Build it and diff against `0.1.0`. The older plan still works while its authority remains valid.
8. Create a new plan revision containing proposed roadmap milestones with goal
   rationale, dependencies and acceptance. Show dependency order and reject a cycle.
   Neither result establishes release qualification or automatic scheduling.
9. Withdraw a selected source/project membership: affected old plans cannot
   build/export/promote. Any edit to a pinned catalogue record conservatively
   requires a new plan; unrelated approvals and unreferenced Support edits do not.
10. Create **OtherCo** in a separate workspace and prove foreign IDs are rejected.
11. Purge one selected source and verify dependent payload removal. Backup/restore
   preserves useful metadata but quarantines authority. Workspace purge includes
   all company records.
12. Repeat the principal journey through the rebuilt authenticated local app and
   actual browser controls. Tie browser evidence to the new build, not a stale
   running process.

## Verification and completion

Required automated evidence includes cross-workspace references, mixed-source
claims, stale hashes, missing applicability, immutable plan tampering, unknown
presets/keys, deterministic order, legacy artifact compatibility, roadmap cycles,
privacy cleanup/quarantine and release rejection for unqualified evaluations.
Run focused author checks, then root's formatter, compiler warnings gate, canonical
`mix test`, warning-level Credo and actual browser acceptance. Record exact totals,
skips and build identity; do not claim tests that were not run.

The reported pre-change baseline is 326 tests, zero failures and 15 existing Docker
skips. This is a supplied baseline, not a verification run performed by this plan.

Local completion means an operator can define the company and project, review
evidence, select goals and finite components, create immutable scoped versions,
inspect a proposed roadmap, compile native previews and export them safely.
Static diagnostics cannot qualify release promotion. Existing task/runtime/model
identity and cleanup gates remain binding.

Authenticated connector checks require suitable credentials and selected scope;
representative coding evaluations require an available selected model/backend.
Codex/Claude managed execution is currently unavailable, separately from native
export. A qualified pilot, measured productivity benefit and public release are
separate outcomes. External blockers do not prevent completing local authoring.
