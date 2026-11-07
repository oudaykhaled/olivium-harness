# Build a company harness

Use **Company** in the local portal to connect your company's catalogue, project
scope, reviewed guidance and future plans. One workspace holds one company.
Use a separate workspace for another company.

The workflow supports source-based guidance, manually written goal-based rules,
and a bounded company-context analysis. See the [enhancement ledger](enhancement-program/state.json)
for the current verification status.

## Guided workflow

1. **Describe your company.** Save a name and description. Assign captured sources
   and goals that deliberately apply across its projects.
2. **Build a service catalogue.** Register repository identities such as
   `example/identity`, their purpose, owner, capabilities, interfaces and declared
   dependencies. Capability search and consumer lists help find existing services.
   These are operator-entered descriptions; they do not establish live compatibility.
3. **Define a project.** Select its repositories, captured sources and goals.
   A service account provides API access; evidence becomes available only after
   you explicitly capture selected content in Connections. A provider's board or
   Jira project is an external source scope, separate from this project grouping.
4. **Review claims and goal-based rules.** In Evidence, inspect source citations
   before approving a sourced claim. For intended practice without a source, first
   save a goal in Goals, then choose it under **Propose a goal-based rule** and write
   the rule yourself. Review the goal title, owner, acceptance criteria and pinned
   hash before explicitly approving that exact claim revision. A workspace with
   goals and zero source documents can use this path. Saving or selecting a goal
   never approves a rule. Unreviewed, rejected, superseded or ineligible revisions
   cannot enter a company plan. Local/manual review works without a model;
   optional inference follows the configured consent and budget.
   To combine history with future intent, open **Analyse selected history and a
   future goal** in Company. Explicitly select a project, 2–4 current captured
   sources and one assigned saved goal. Configure an available model in Connections;
   cloud providers additionally require explicit permission for selected company
   context. The result separates the original findings, discussion, decisions,
   conflicts and uncertainty from four editable guidance fields. Save edits as a
   new proposed revision. A declared conflict or uncertain/conflicted recommendation
   requires a saved human resolution before exact approval in Evidence. Rejection
   remains a separate action. Citation coverage establishes provenance, not truth
   or complete company coverage; no fallback model or automatic approval is used.
   Both review screens qualify source names as current and potentially changed.
   Capture dates and stored links appear only when the loaded capture matches the
   citation; otherwise the original excerpt and pin remain with an unavailable
   notice. Capture dates do not establish policy chronology. Source links open a
   new tab, and their destination may have changed. Viewing these details or
   opening a link does not edit guidance, approve a claim or request analysis.
5. **Propose a package plan.** Choose the project, a repository subset, exact approved
   claims, applicable goals, workflow presets, coding-agent target and limits.
   For each goal-based rule, explicitly select the same goal in the plan and assign
   it to the company or project scope. Selecting the rule does not add its goal.
   Add optional milestones with acceptance conditions and evaluation methods.
   Dependencies must refer to milestones in this plan and form an acyclic graph.
6. **Review the exact plan.** Approve or reject its displayed immutable revision.
   Claim decisions and plan decisions are separate. A saved proposal cannot build
   until it has its own approval.
7. **Build, inspect and compare.** Build the approved plan. Use Package for fresh
   directory export and Evaluations for actual checks. Create a successor plan
   for a new version, review it separately, and compare the resulting artifacts.
   Older approved plans remain reproducible while their scope and evidence remain
   eligible. An unrelated project's new claims do not enter this package.

Company plans support native OpenCode, Codex CLI and Claude Code previews through
the existing adapters. The built-in presets are a bounded reviewed-change workflow
and a reuse-before-build workflow. Arbitrary commands or model-generated templates
cannot be installed through this form. The capability report describes which
requested controls the target supports.

## Version and authority rules

The selected company, project and repository catalogue hashes, source revisions,
claim revisions and goal contents are pinned in the plan. Editing selected catalogue
metadata conservatively requires a new plan review, including descriptive changes.
Changing source content or withdrawing access blocks dependent builds and exports.
Company analysis retains every examined revision, including uncited inputs. Changes
to any of those inputs invalidate affected guidance. Original reports and attribution
remain immutable when current guidance is edited. Later approved build/export makes
no model call and works without a currently selected model; current evidence and
company/project/goal authority still apply. The four guidance fields are reviewed
instructions, not newly executable workflows or graders.
Creating a successor alone does not revoke an older approved version.

Goals and milestones express future intent. They do not approve policy, schedule
agent execution, qualify a release or change permissions. A goal becomes the origin
of a rule only through a separate user-authored claim and exact-revision approval,
followed by selection of both claim and goal in a separately approved scoped plan.
Build and export recheck current authority. Goal-based rules use the existing
v1alpha1 `goal_id` with empty `evidence`; they do not acquire fabricated citations.

Goal-origin basis v1 pins the saved goal ID and content hash into a versioned claim
hash. Source-origin hashes and historical artifact bytes retain their existing
form. Successors keep their origin type: a sourced claim cannot become a goal-based
rule through supersession, or vice versa. Each successor needs its own approval.
Source purge retains independent goal-origin families while invalidating affected
plan dependencies; workspace purge includes goal-based claims. Backup restore
clears claim and plan decisions and quarantines the workspace for fresh review.

Static integrity results cannot authorize promotion; unavailable models or managed
runtimes remain visibly blocked. Managed Codex/Claude execution is currently
unavailable. Complete-company reliability and representative model-backed outcomes
remain unproven.

Plan-to-artifact approval provenance is held in this workspace. Existing exported
v1alpha1 packages retain their compatible format; complete portable company-plan
provenance is a future contract extension. Backups preserve useful planning data
but restore withdraws plan/claim approval and source/model authority. Retained
bindings remain provenance so a restored company package cannot bypass plan review.

## CLI

Stop the portal before using offline commands. Configuration files contain the
same flat string-keyed attributes described in the [frozen contract](company-builder-contract.md).
No API key belongs in these files.

```text
bin/harnessforge company profile
bin/harnessforge company profile /absolute/path/to/profile.json
bin/harnessforge company repository /absolute/path/to/repository.json
bin/harnessforge company project /absolute/path/to/project.json
bin/harnessforge company search authentication
bin/harnessforge company consumers REPOSITORY_ID
bin/harnessforge goal /absolute/path/to/goal.json
bin/harnessforge company plan /absolute/path/to/plan.json
bin/harnessforge company plans
bin/harnessforge company decide PLAN_ID approve REVISION_HASH
bin/harnessforge company build PLAN_ID REVISION_HASH
bin/harnessforge export DIGEST FRESH_DIRECTORY
```

Plans are separate from the legacy `build NAME VERSION` command. That command
retains its workspace-wide source-only behavior and refuses when the current
approved claim set includes a goal-based rule; it neither silently drops that rule
nor approves a plan. Use Company to select the exact rule and goal and separately
approve their scoped plan. See [coordination and acceptance](company-builder-coordination.md)
for the session handoffs and [current status](status.md) for qualification limits.
