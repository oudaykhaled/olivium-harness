# Company builder contract

Status: **frozen implementation contract**, 31 October 2026, root coordinator decision.
This specifies required behavior, not completed implementation or test evidence.
Root owns amendments and communicates them before dependent implementation changes.

## Boundary

One workspace represents one company. `Workspaces` owns identity, files and sessions.
`Company` owns profile, repository catalogue, projects, immutable plans and roadmap
milestones. `Evidence`, `Goals` and `Decisions` retain source, goal and exact human
claim authority. `Harnesses` admits approved plans; existing compiler/adapters render
v1alpha1. Evaluations, releases and privacy retain their existing gates.

A connector account, Jira project or GitHub board does not create company membership.
Company metadata and roadmap text do not become approved policy. Other companies use
separate workspaces. No new tenancy, private infrastructure or remote hosting.

## Frozen API

```elixir
Company.get_profile()
Company.save_profile(attrs)
Company.list_repositories()
Company.create_repository(attrs)
Company.update_repository(id, attrs)
Company.list_projects()
Company.create_project(attrs)
Company.update_project(id, attrs)
Company.search_capabilities(query)
Company.consumers(repository_id)
Company.create_plan(attrs)
Company.get_plan(id)
Company.list_plans()
Company.decide_plan(id, attrs)
Company.build_inputs(id)
Harnesses.build_plan(id, expected_hash)
```

Results are `{:ok, dto}`, `{:ok, list}`, `{:ok, nil}` for an absent profile, or
`{:error, atom}`. Existing approved evidence and goals retain their existing DTOs.
All public maps use string keys; IDs are opaque UUIDs. Reject unknown keys, duplicate
IDs, foreign-workspace references and excessive input. Every mutation checks
workspace readiness and uses the existing privacy mutation fence.

Commands accept flat attributes, not a `payload` envelope. Catalogue input attributes are the payload fields below. Updates include an
`expected_content_hash` outside the persisted payload; stale updates fail. Profile
creation needs no expected hash; replacing an existing profile requires its hash.

`create_plan` accepts payload fields plus optional `supersedes_id` outside payload.
No caller-supplied snapshot, revision hash, approval or workspace ID is accepted.
`decide_plan` takes exactly `actor`, `decision` (`approve` or `reject`) and
`expected_revision_hash`. The authenticated UI supplies the current local operator.

Catalogue DTOs contain `id`, `workspace_id`, `payload`, `content_hash`, `inserted_at`,
`updated_at`. Plan DTOs contain `id`, `workspace_id`, `family_id`, `supersedes_id`,
`payload`, `snapshot`, `revision_hash`, `inserted_at`, `status` and `superseded`.
Status is `proposed`, `approved` or `rejected`; superseded is a separate boolean.
Search and consumers return repository DTO lists, with deterministic ordering.

## Payloads and bounds

| Record | Required fields | Optional fields |
| --- | --- | --- |
| Profile | `name` | `description`, `source_ids`, `goal_ids` |
| Repository | `identity`, `name`, `purpose`, `owner` | `capabilities`, `interfaces`, `version_strategy`, `dependency_ids`, `examples` |
| Project | `name`, `repository_ids` | `description`, `source_ids`, `goal_ids` |
| Plan | `name`, `package_version`, `project_id`, `repository_ids`, `claim_refs`, `goal_ids`, `template_ids`, `runtime`, `runtime_version`, `execution` | `milestones` |

`capabilities`, `interfaces` and `examples` are arrays of bounded strings;
`version_strategy` is a string and dependency IDs are UUID references.
Optional arrays default to `[]`, optional strings to `""`. Plan selections must be
explicit, including an empty `goal_ids` when no future goal is selected. A plan
requires at least one approved claim, one selected repository and one template.
Repository identities are unique within the workspace and follow existing opaque
scope grammar (`example/identity`); paths and credential URLs are forbidden.

`claim_refs` contains exact `{id, revision_hash}` maps. `execution` has exactly
`max_turns` and `timeout_seconds`, bounded by existing v1alpha1 constraints
(1–1000 turns and 1–86400 seconds). These remain requested/advisory runtime intent
according to the existing capability report; they do not override managed limits.

`milestones` is an authorable proposed roadmap DAG. Each item contains exactly
`id`, `title`, `goal_ids`, `depends_on`, `acceptance`, `evaluation_method`,
`target_version`. `acceptance` and `evaluation_method` are strings; `goal_ids` and `depends_on`
are ID arrays. Item IDs are bounded slug strings local to the plan. Goal IDs
must be selected by the plan; dependency IDs must exist in that plan. Reject
self-edges and cycles. `target_version` is a proposed package version label, not a
delivery promise. A milestone has no approval, scheduling or release authority.
Creating a revised roadmap creates a new immutable plan revision.

Finite template IDs are `reviewed-change-v1` and `reuse-before-build-v1`. The first
provides the bounded review workflow; the second adds a fixed reuse-before-build
workflow. Templates are compiled-in server constants and grant no permissions.
No freeform agent, skill, instruction, policy, template, command or module input is
allowed. Unknown IDs fail. Company-specific normative instructions still require
approved claim revisions. Goals and catalogue descriptions remain labeled data.

Bounds: at most 100 repository/project/source/goal/milestone references per array,
500 claim refs and two distinct template IDs. Labels are at most 256 characters,
prose 4096; package name/version and runtime fields use existing schema bounds.
Set-valued arrays are duplicate-free and sorted for hashing. Template rendering
order is server-defined. Repository cycles may represent real systems and must
not cause unbounded traversal; roadmap cycles are invalid.

Capability search is bounded lexical catalogue search, independent of model
availability. Consumers are derived from declared dependency edges. Registration
and dependency metadata do not establish live interfaces or compatibility.

## Persistence owned by root migration

All IDs below are UUID primary keys; workspace IDs are strings.

| Table | Additional columns | Behavior |
| --- | --- | --- |
| `company_profiles` | `payload` map, `content_hash` string, timestamps | One per workspace; mutable |
| `company_repositories` | `payload` map, `content_hash` string, timestamps | Mutable; unique payload identity within workspace |
| `company_projects` | `payload` map, `content_hash` string, timestamps | Mutable |
| `company_plans` | `family_id` UUID, `supersedes_id` UUID nullable, `payload` map, `snapshot` map, `revision_hash` string, `inserted_at` | Immutable; unique non-null successor link |
| `company_plan_decisions` | `plan_id` UUID, `actor` string, `decision` string, `revision_hash` string, `inserted_at` | Immutable; one explicit decision per plan |
| `company_artifact_bindings` | `plan_id` UUID, `plan_revision_hash` string, `artifact_digest` string, `inserted_at` | Immutable; unique workspace/plan/artifact |

Lane A owns catalogue/plan/decision records. Lane B owns only the binding Ecto
record within `company/`. Root owns migrations and privacy integration.
Use `utc_datetime_usec` timestamps. No separate roadmap table is needed.

## Snapshot and scope authority

The server captures this exact snapshot shape at plan creation:

```text
profile: {id, content_hash}
project: {id, content_hash}
repositories: [{id, identity, content_hash}]
sources: [{id, revision_id, body_hash}]
claims: [{id, revision_hash}]
goals: [{id, content_hash}]
```

Sources are the unique source revisions underlying selected claim citations.
Goal content hash covers canonical `id`, `title`, `owner`, `acceptance`.
Plan revision hash covers canonical payload plus snapshot; timestamps, workspace
paths and secret material are excluded. Source text is not copied into the plan.

Selected repositories must be a nonempty subset of the project's repository IDs.
Allowed sources/goals are the union of profile and selected project assignments.
Every selected goal must belong to that union. Every citation of every selected
claim must refer to an allowed active source and its current eligible revision.
Mixed-scope claims fail if even one citation is outside the allowed set. There is
no fallback to all workspace claims, sources or goals.

Each selected claim must be approved, current, unsuperseded and match its pinned
hash. Selected goal content must match its snapshot. Profile/project/repository
content hashes must still match their snapshots. This deliberately conservative
first version treats any selected catalogue record edit as stale scope metadata,
even a descriptive edit; create and review a new plan. Do not silently broaden
scope or recompute snapshots during build/export.

Creating a successor plan does not revoke an already approved predecessor. The
older approved plan remains rebuildable/exportable while all pinned authority
remains valid. A superseded proposed plan cannot subsequently be approved.
Unrelated approvals and plans do not affect this plan's eligibility.

## Build bridge and exact DTO

`Company.build_inputs(id)` is read-only admission for both new builds and binding
eligibility. It requires an exact approved plan and all snapshot/scope checks above.
An approved ancestor is admitted regardless of successor existence. It returns:

```text
plan_id
plan_revision_hash
name                         # payload.name
version                      # payload.package_version
runtime
runtime_version
repositories                 # sorted opaque repository identity strings
claims                       # existing eligible Evidence claim DTOs
                              # id, revision_hash, text, citations, etc.
goals                        # existing immutable Goals DTOs
                              # id, title, owner, acceptance, etc.
template_ids
execution                    # max_turns, timeout_seconds
snapshot                     # exact persisted snapshot above
```

`Harnesses.build_plan(id, expected_hash)` calls this API, compares
`plan_revision_hash` with `expected_hash`, deterministically builds the existing
v1alpha1 spec, rechecks the admitted inputs before publication and persists the
immutable binding. Only selected claims/goals/repository identities and server
presets feed compilation. Fixed preset text cannot be replaced by catalogue or
milestone prose. Existing `Harnesses.build/1` remains the legacy path.

## Binding tradeoff and legacy compatibility

**No v1alpha2, compiler identity change or schema extension in this wave.** Preserve
legacy v1alpha1 rendering and verification byte-for-byte. `Compiler.verify/1`
recompiles historical specs, so globally changing template/compiler identity would
invalidate existing immutable artifacts.

The separate local plan-to-artifact binding supplies company provenance and
eligibility without changing exported schema. The tradeoff is explicit: the
exported v1alpha1 package does not carry complete company-plan provenance and a
portable importer cannot independently reconstruct local plan approval. This wave
must not advertise that stronger portability guarantee. A later versioned schema
can address it with a dedicated compatibility decision.

`Harnesses.eligible/1` preserves existing exact claim checks and additionally
validates any local bindings for the artifact. At least one currently valid,
exact approved binding is sufficient when several plans generate identical bytes.
Call `Company.build_inputs(binding.plan_id)` and compare its exact plan revision
hash with the binding. A bound artifact must not fall back to legacy eligibility
when all its bindings are invalid. An artifact that has never been bound uses the
existing legacy eligibility path. Privacy must not erase invalid bindings while
retaining artifact bytes in a way that accidentally grants legacy eligibility.

Export, release approval, promotion and rollback reuse this eligibility gate.
Static compilation/evaluation still cannot qualify a release; runtime, model,
suite, environment and cleanup identity checks remain unchanged.

## Privacy, audit and follow-up

Root adds all six tables to inventory, workspace purge and restore workspace-ID
rewriting; immutable tables join the existing trigger handling. Source purge
traverses plan snapshot sources, decisions, bindings and dependent artifacts,
removes sensitive dependent plan payloads, and preserves unrelated projects.
Mutable source assignments are scrubbed. Family/supersedes references must remain
consistent after removal. No extra lane-owned privacy traversal API is required;
root owns SQL integration. Purge recovery must keep workflows fenced until complete.

Restore preserves and remaps useful catalogue data, plans and artifact bindings
as provenance, while withdrawing plan/claim decisions, source and model authority.
Retained artifact handling must not turn former bound packages
into eligible legacy packages. Existing restored-artifact quarantine remains binding.

Audit only local IDs, statuses and counts, using the existing safe audit boundary;
no description, roadmap text, source body or credential material. No remote events.

Remaining explicit follow-up: exact goal-origin claim basis/hash/decision support,
explicit conflict-resolution records and portable composition provenance. Selecting
a goal or approving a plan does not implement any of those features. This local
wave also does not establish authenticated connector availability, managed
Codex/Claude execution, a qualified pilot or measured productivity gains.
