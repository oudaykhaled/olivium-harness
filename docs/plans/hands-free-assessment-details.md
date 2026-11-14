# Hands-free harness: assessment details

Generated 2026-11-07 from five independent assessment agents run over commit `628676e`. Each section is one agent's read of the repository for its lens, with file references. The consolidated plan is in [hands-free-roadmap.md](hands-free-roadmap.md).

Change ids: E = engine, H = history/signals, W = wizard, P = portal, D = developer experience.

## Contents

- [1. Hands-free generation engine and the mature package](#1-hands-free-generation-engine-and-the-mature-package)
- [2. Repository history and tooling signals (inputs)](#2-repository-history-and-tooling-signals-inputs)
- [3. Wizard: one-command CLI and guided portal flow](#3-wizard-one-command-cli-and-guided-portal-flow)
- [4. Visual-first portal](#4-visual-first-portal)
- [5. Developer experience, distribution and simplification](#5-developer-experience-distribution-and-simplification)

## 1. Hands-free generation engine and the mature package

### Current state

The pipeline is a pure deterministic compiler (Compiler.compile -> Adapters.Registry -> ClaudeCode/Codex/OpenCode) fed by Harnesses.specification/3, which hard-codes everything except rule sentences (approved claims) and goals. Each adapter emits one guidance file, one settings file, one agent file per agent and one SKILL.md per skill, plus four harnessforge.*.json provenance files; the guidance file is a flat list of rule sentences behind two disclaimers, and permissions default to 'ask' for every tool. Building requires at least one human-approved claim (or an approved company plan); claims come from model proposals or the synthetic demo, and only Markdown/text and GitHub issue/PR prose enter the system, so no stack, command or tooling signal reaches the compiler. Export writes only to a fresh directory, static_integrity is a digest check, and the v1alpha1 schema rejects unknown fields, so there is no hands-free path, no overlay, no in-place regeneration and no quality score today. Determinism and tamper verification are already solid and should be kept as the foundation.

| Finding | Evidence |
|---|---|
| Only rules and goals vary per project; policies (shell-review=ask, no-network-advice), the single 'implementer' agent, the single 'reviewed-change' skill, execution (20 turns/300 s) and evaluation suite are literal constants. Runtime defaults to opencode and scope to 'local-workspace'. | lib/harness_forge/harnesses.ex:302-376 (policies 342-355, agents 356-363, skills 364-371, execution 372, evaluation 373, runtime default 303, scope 318) |
| The company-plan path replaces skills with at most two fixed advisory templates; no other template or agent catalogue exists. | lib/harness_forge/harnesses.ex:171-180; lib/harness_forge/harnesses/templates.ex:4-17; lib/harness_forge/company/validation.ex:4,49-50 |
| Claude Code adapter emits exactly CLAUDE.md, .claude/settings.json, .claude/agents/<name>.md and .claude/skills/<name>/SKILL.md. settings.json contains only permissions (allow/ask/deny of 11 fixed tools, defaultMode=default, disableBypassPermissionsMode=disable) and disableSkillShellExecution=true; every tool not named by a policy lands in 'ask'. No hooks, MCP, env or command rules. | lib/harness_forge/adapters/claude_code.ex:16-28,101-126,281-292; test/harness_forge/claude_code_adapter_test.exs:22-27,100-110,154-167; docs/claude-code-connector.md:29-30,45-47 |
| Guidance files (CLAUDE.md/AGENTS.md) are title + two disclaimer paragraphs + rule statements each prefixed with an HTML comment carrying rule id/revision. No project map, commands, conventions, checklist or sections. | lib/harness_forge/adapters/claude_code.ex:314-326; lib/harness_forge/adapters/codex.ex:292-304; lib/harness_forge/adapters/opencode.ex:261-272 |
| Codex .codex/config.toml is constant (approval_policy=on-request, sandbox_mode=workspace-write, web_search=disabled, network_access=false) except project_doc_max_bytes and an optional features.shell_tool=false; OpenCode opencode.json sets permission '*'=ask, external_directory=deny and agent.<name>.steps only. | lib/harness_forge/adapters/codex.ex:233-247; lib/harness_forge/adapters/opencode.ex:85-90,242-249; test/harness_forge/codex_adapter_test.exs:42-54 |
| Compiler is pure and deterministic; verify/1 recompiles the embedded spec and compares every byte; assemble adds harnessforge.spec/provenance/capabilities/manifest.json at the package root; identity is compiler_version 0.1.0 / template_version v1alpha1.1. Any rendering change therefore invalidates every stored artifact on read. | lib/harness_forge/compiler.ex:15-19,23-31,35-43,94-99,130-131; lib/harness_forge/artifacts.ex:140-161; test/harness_forge/compiler_test.exs:13-36 |
| The frozen schema sets additionalProperties=false at every level, requires at least one agent, and semantic checks demand evidence citations or a goal_id for every rule, so derived (non-claim) facts cannot be expressed. | priv/schemas/harness-v1alpha1.json:6,39,112,219-263; lib/harness_forge/contracts.ex:287-321 (314-317) |
| No approval bypass exists: Harnesses.build/1 returns :no_approved_claims without approved claims; approved_claims joins per-claim Decision rows; Decisions.decide requires actor + expected_revision_hash per claim. Claims are created by Models.propose (model required) or by Demo.load, which proves claims can be minted deterministically via Evidence.citation + Evidence.create_claim without inference. | lib/harness_forge/harnesses.ex:182-206; lib/harness_forge/evidence.ex:378-400; lib/harness_forge/decisions.ex:7-50; lib/harness_forge/models.ex:164; lib/harness_forge/demo.ex:55-75 |
| Inputs are prose only: local import accepts .md/.markdown/.txt; the GitHub connector returns repository/issue/pull_request/review items. No file trees, manifests (mix.exs, package.json), CI files or commits reach the engine, so stack-derived allow lists are impossible today. | lib/harness_forge/evidence/local_import.ex:6; lib/harness_forge/connectors/github.ex:2,19-28 |
| Export requires a fresh absolute directory (export_conflict otherwise); no in-place sync, overlay merge or working-tree diff exists. Releases.diff/2 compares files and rules of two stored artifacts only. | lib/harness_forge/artifacts.ex:5-7,324-328; test/harness_forge/harnesses_test.exs:46-48; lib/harness_forge/releases.ex:104-115 |
| No quality rubric: static_integrity always passes with the single check artifact_digest_and_manifest; Readiness is a 7-stage lifecycle report (integrity, eligibility, runtime, evaluation...) with blockers/next_action; HarnessLive shows files, hashes and verification flags but no score. | lib/harness_forge/evaluations.ex:581-586; lib/harness_forge/readiness.ex:18,280-302; lib/harness_forge_web/live/harness_live.ex:350-410,445-478; lib/harness_forge_web/harness_delivery.ex:15-51 |
| Accepted runtime versions are pinned (Claude 'unqualified'\|2.1.311, Codex 'unqualified'\|0.156.0, OpenCode 1.x); the native container probe verified discovery of AGENTS.md/CLAUDE.md, one agent and one skill only. Hooks, MCP and permission-rule syntax were never exercised. UNVERIFIED offline: exact current native syntax for Claude hooks/command rules, Codex mcp_servers/hooks, OpenCode per-command bash permission objects. | lib/harness_forge/adapters/claude_code.ex:129-131; lib/harness_forge/adapters/codex.ex:99-101; lib/harness_forge/adapters/opencode.ex:114-124; docs/coding-connectors-verification.md:1-12; test/native_agents/verify.cjs |

### Gaps

- **No hands-free entry point: every build path requires at least one approved claim or an approved plan (harnesses.ex:184-203).** A solo developer with zero configuration cannot get any package; the owner's default mode does not exist.
- **Package content is not derived from the repository: no project map, commands, stack, conventions or architecture notes; only rule sentences vary.** A harness without build/test/lint commands and a project map is not mature by any definition and offers little over an empty CLAUDE.md.
- **Permission posture is 'ask everything' (Claude) / '*': ask (OpenCode); nothing is derived from the detected stack.** Hands-free use is impossible when every Edit/Read/test command prompts; the owner named this explicitly.
- **No hooks, no MCP config, no purpose-specific agents or skills (one generic agent, one generic skill or two fixed templates).** Format/lint/test-on-edit hooks and reviewer/test-writer agents are the parts of a harness that change agent behaviour most.
- **Guidance files are flat and unsectioned, have no size budget, and the Claude adapter rejects any '@' (claude_code.ex:168-172), which blocks emails and Elixir module attributes like @moduledoc.** Generated project maps and Elixir/TypeScript conventions will contain '@' and file paths; the current check would refuse to compile them.
- **No overlay for manual instructions; the only human text that enters a package is an approved claim or a goal.** Optional manual notes must layer on top of the generated package without forcing the review workflow.
- **Derived facts cannot be represented: schema is closed and every rule needs citations or a goal (contracts.ex:314-317).** Hands-free rules need a provenance form (origin + fingerprint) that is neither a claim nor a goal.
- **No idempotent in-place regeneration or working-tree diff; export only to fresh directories (artifacts.ex:324-328).** Re-running must be safe and report 'unchanged' or a precise diff, otherwise continuous regeneration (lens 5) has no primitive to build on.
- **No maturity/quality rubric; static_integrity is a digest check.** The portal cannot show a status or score, and hands-free output has no self-check for missing commands, oversized guidance or all-ask permissions.
- **Adapter output is unversioned: Compiler.verify recompiles stored artifacts, so any rendering change invalidates all existing artifacts.** Every change in this plan touches rendering; without a versioned renderer the upgrade breaks existing workspaces.

### Target design

A new HarnessForge.Generation context assembles a v1alpha2 Harness spec from three layered inputs and hands it to the existing pure Compiler: (1) a RepoProfile (string-keyed facts produced by lens 2: languages, frameworks, package managers, commands, layout, conventions, tooling, CI, history), (2) a versioned data-driven Blueprint catalogue in priv/blueprints (base -> per-stack -> optional team layer) that supplies sectioned guidance, purpose-specific agents, skills, hooks and permission policies with {{commands.test}}-style placeholders resolved only from the profile, and (3) an optional Overlay parsed from HARNESS_NOTES.md plus harnessforge.overlay.json. Precedence per key is overlay > approved claims (reviewed mode only) > derived profile facts > blueprint defaults; lists merge with de-duplication and overlay may remove items by id, scalars are replaced, and overlay can widen or tighten permissions within the portable vocabulary but can never set required=true. In hands_free mode (default) no claim, decision or plan is consulted: rules carry origin=derived with a sha256 fingerprint and source pointer, the artifact is published content-addressed and audited as harness.generated, and Harnesses.eligible/1 only re-checks rules whose origin is approved_claim, so the entire claims/decisions/plan/evaluation/release machinery stays available as the optional reviewed mode without being on the default path. The spec gains project, guidance (ordered sections), hooks, mcp, generation (mode, profile_digest, overlay_digest, blueprint_version) sections plus agent tools/mode and command_permissions policies, and each adapter renders those sections natively: Claude Code gets a sectioned CLAUDE.md, settings.json allow/ask/deny with Bash(<cmd>:*) and Read(./.env) rules, PostToolUse/Stop hooks and .mcp.json; Codex gets sectioned AGENTS.md, config.toml with mcp_servers and policy-driven sandbox/approval, with hooks rendered as a checklist plus unsupported diagnostics; OpenCode gets sectioned AGENTS.md, opencode.json permission patterns, agent tool maps and mcp. Compilation stays byte-deterministic: identical profile+overlay+blueprint yield the identical digest, provenance files move under .harnessforge/, and a pure Maturity rubric is computed at compile time into .harnessforge/maturity.json so any UI can show a score, level and per-dimension fixes. Generation.plan/1 compiles without publishing and diffs the package against the target working tree (added/changed/unchanged/user_modified/removed, line diffs), and Artifacts.export gains a sync mode that writes only owned paths and never overwrites a user-edited generated file unless forced, which makes re-runs idempotent. v1alpha1 rendering is frozen behind an apiVersion branch so existing artifacts keep verifying. The CLI exposes generate/plan as one command; the wizard (lens 3), portal visuals (lens 4) and scheduling (lens 5) sit on top of these two functions and the maturity/plan data.

### Day one after the plan ships

1. `bin/harnessforge generate --root . --target claude_code` with no config: the engine takes the lens-2 profile, resolves the elixir_phoenix blueprint, prints maturity 'solid 74/100' with the three missing dimensions, and writes CLAUDE.md, .claude/settings.json (allow: Edit/Read/Grep/Glob, Bash(mix test:*), Bash(mix format:*); deny: Bash(rm -rf:*), Read(./.env)), hooks (PostToolUse Edit|Write -> mix format), three agents, two skills and .harnessforge/*.json into the repo.
2. Run the same command again: output is `changes: 0 (all unchanged)`, same digest, no new artifact.
3. Add HARNESS_NOTES.md with '## Don't' and '## Commands' overriding the test command; `--plan` shows the CLAUDE.md line diff and the settings.json change; `generate` applies it and the Notes/Do-Don't sections appear with origin=overlay in provenance.
4. `--target all` produces Codex (AGENTS.md, .codex/config.toml, .codex/agents, .agents/skills) and OpenCode (AGENTS.md, opencode.json, .opencode/agents, .opencode/skills) packages from the same spec; Codex/OpenCode report hooks as a checklist with unsupported_control diagnostics.
5. Portal 'Your harness' page reads .harnessforge/maturity.json and the plan from HarnessDelivery and shows score, dimension statuses and per-file change badges (rendered by lens 4).
6. A team runs `generate --mode reviewed`: approved claims become Rules with ids/revisions, the team blueprint adds the reviewer agent, review checklist and disableBypassPermissionsMode, and export still passes Harnesses.eligible/1 and the existing evaluation/release gates.

### Proposed changes

#### E1 · Spec v1alpha2 schema and contract validation

**Priority** P0 · **Effort** M · **Type** add · **Depends on** none

**What.** Add priv/schemas/harness-v1alpha2.json (copy of v1alpha1 plus: spec.project {name, languages[], frameworks[], package_managers[], commands{install,build,test,test_single,lint,format,typecheck,run}, layout[{path,purpose}], conventions[], ci[]}; spec.guidance[] ordered sections {id in project-map|commands|conventions|do-dont|architecture|review-checklist|rules|notes, title, lines[]}; spec.hooks[] {id, event in after_edit|before_stop|session_start, matcher, command, timeout_seconds, required=false}; spec.mcp[] {name, transport in stdio|http, command, args[], url, env_refs[]}; spec.generation {mode in hands_free|reviewed, profile_digest, overlay_digest, blueprint_version}; rule.origin in approved_claim|derived|overlay with source and fingerprint; agent.tools[] (portable names) and agent.mode; policy capability command_permissions.<id> with value {pattern, action}). Contracts.validate_harness/1 dispatches on apiVersion; semantic_errors requires evidence-or-goal only when origin=approved_claim and fingerprint when derived/overlay; deterministic rule ids = sha256-derived UUID-shaped hex (Generation.Ids).

**Where.** priv/schemas/harness-v1alpha2.json (new); lib/harness_forge/contracts.ex (validate_harness/1, semantic_errors/1, schema/1 by version); lib/harness_forge/generation/ids.ex (new); docs/contracts.md

**Why.** The closed v1alpha1 schema and evidence-or-goal rule requirement make every other change impossible; a sibling schema keeps old artifacts valid.

#### E2 · RepoProfile input contract for the engine

**Priority** P0 · **Effort** M · **Type** add · **Depends on** none

**What.** Define HarnessForge.Generation.Profile: validate/1 (string keys, bounded strings, commands are plain argv strings without shell metacharacters, paths relative), digest/1 (Contracts.digest), empty/1 fallback, and from_existing_harness/1 (reads any CLAUDE.md/AGENTS.md/.claude/settings.json already in the repo as 'existing_harness' facts). Ship fixtures examples/profiles/{elixir_phoenix,node_typescript,python,go,minimal}.json. This is the shape lens 2's extractor must return (HarnessForge.Signals.profile/1 expected); the engine never reads repositories itself.

**Where.** lib/harness_forge/generation/profile.ex (new); examples/profiles/*.json (new); docs/mature-package.md (profile section)

**Why.** Decouples generation from extraction so both lenses can be built in parallel against fixtures, and keeps repository bytes out of the compiler (no execution, no host paths).

#### E3 · Data-driven blueprints replace hard-coded agents, skills, policies and templates

**Priority** P0 · **Effort** L · **Type** change · **Depends on** E1, E2

**What.** Add priv/blueprints/base.json, priv/blueprints/stack/{elixir_phoenix,node_typescript,python,go,rust,jvm}.json and priv/blueprints/team/reviewed.json, each with agents (e.g. code-reviewer with read-only tools, test-author, debugger, <stack>-implementer), skills (run-checks, <stack>-conventions, reviewed-change-v1, reuse-before-build-v1 kept with their ids), hooks (after_edit -> {{commands.format}}, before_stop -> {{commands.lint}}), policies (tool_permissions + command_permissions allow for {{commands.*}} and safe git reads, deny for rm -rf, git push --force, secret reads) and guidance sections with placeholders. HarnessForge.Generation.Blueprint.resolve(profile, opts) merges base -> detected stacks (sorted) -> team layer, substitutes only {{commands.*}}/{{project.*}} tokens from the validated profile, drops entries whose placeholders are unresolved, and returns blueprint_version. Harnesses.specification/3 literals (harnesses.ex:342-373) are replaced by a call to Blueprint.resolve; Harnesses.Templates becomes a shim over the blueprint skill ids.

**Where.** priv/blueprints/**/*.json (new); lib/harness_forge/generation/blueprint.ex (new); lib/harness_forge/harnesses.ex (specification/3); lib/harness_forge/harnesses/templates.ex (shim); lib/harness_forge/company/validation.ex (@templates from Blueprint.skill_ids/0)

**Why.** Agent, skill and permission policy must vary with the detected stack; JSON blueprints are reviewable data, versioned for determinism, and need no template engine.

#### E4 · Overlay: optional manual notes with precedence rules

**Priority** P0 · **Effort** M · **Type** add · **Depends on** E1

**What.** HarnessForge.Generation.Overlay.load(%{"notes_path"|"notes_text", "json_path"}) parses HARNESS_NOTES.md: '## Commands' key: value lines, '## Conventions', '## Do', '## Don't', '## Architecture', '## Review checklist', '## Permissions' (allow/ask/deny: pattern), '## Hooks' (event: command), '## Notes' free text; and harnessforge.overlay.json {commands, permissions, hooks, agents, remove:[ids]}. apply/2 merges into the resolved spec with precedence overlay > approved_claim rules > derived > blueprint: scalars replaced, lists appended+deduplicated by id, 'remove' deletes blueprint/derived items, required=true never settable, commands must pass Profile command validation, text passes the adapters' static checks (no !` expansion, '@' only inside code spans). Records overlay_digest in spec.generation and origin=overlay on rules/sections.

**Where.** lib/harness_forge/generation/overlay.ex (new); docs/mature-package.md (overlay section with the recognised headings)

**Why.** Manual instructions must be optional, plain Markdown, and deterministic in how they override generated content, without entering the claim/decision workflow.

#### E5 · Hands-free engine entry points and optional reviewed mode

**Priority** P0 · **Effort** L · **Type** add · **Depends on** E1, E2, E3, E4

**What.** lib/harness_forge/generation.ex with generate/1 and plan/1 taking %{"profile" (or "root" delegated to lens 2), "target" (one or "all"), "mode" (hands_free default | reviewed), "team" boolean, "notes_path", "name", "version"}. Steps: Profile.validate -> Blueprint.resolve -> (reviewed only) Evidence.approved_claims as origin=approved_claim rules -> Overlay.apply -> Generation.Spec.assemble (v1alpha2, metadata.name slug from profile.name) -> Compiler.compile -> (generate only) Artifacts.publish + Audit.append("harness.generated", %{digest, mode, target, profile_digest, overlay_digest, maturity_score}). Harnesses.eligible/1 filters rules to origin=approved_claim before the revision check and treats an empty approved set as eligible when spec.generation.mode=hands_free; Harnesses.build/1 and build_plan/2 remain the reviewed entry points. Config keys: config :harness_forge, :generation, [default_mode: :hands_free, default_target: "claude_code", default_hooks: [:format]] with env overrides HARNESSFORGE_GENERATION_MODE and HARNESSFORGE_DEFAULT_TARGET in config/runtime.exs. No DB migration: state lives in the artifact store and audit log.

**Where.** lib/harness_forge/generation.ex (new); lib/harness_forge/generation/spec.ex (new); lib/harness_forge/harnesses.ex (eligible/1, eligible_binding/2); config/config.exs; config/runtime.exs

**Why.** Delivers the zero-approval default path while keeping approvals, plans and release gates as a selectable layer rather than deleting them.

#### E6 · Claude Code adapter v2: sectioned CLAUDE.md, derived permissions, hooks, MCP, agent tools

**Priority** P0 · **Effort** L · **Type** change · **Depends on** E1

**What.** Branch on apiVersion: v1alpha1 rendering frozen byte-for-byte; v1alpha2 renders CLAUDE.md from spec.guidance sections (H2 per section, code spans for paths/commands, rules section keeps '<!-- rule: id; revision -->' lines, footer comment with spec digest prefix and blueprint_version; warn diagnostic above 16 KB). settings.json: permissions.allow/ask/deny from tool_permissions plus command_permissions rendered as Bash(<prefix>:*) and Read(<glob>) rules, defaultMode=default, disableBypassPermissionsMode only when team/reviewed, disableSkillShellExecution=true kept; hooks map {PostToolUse: [{matcher: "Edit|Write", hooks: [{type: "command", command, timeout}]}], Stop: [...]} from spec.hooks; .mcp.json {mcpServers: ...} only when spec.mcp != []. Agents gain 'tools:' (portable -> native via @tools) and 'model: inherit'. static_rules/static_skills ignore '@' inside backtick code spans and reject it elsewhere. Capability report marks command_permissions and hooks as advisory with boundary claude_code.settings.

**Where.** lib/harness_forge/adapters/claude_code.ex (compile/2, guidance/1, permissions/1, new hooks/1, mcp_json/1, agent_markdown/2, static_rules/1); docs/claude-code-connector.md

**Why.** This is the concrete 'mature package' for the primary target; freezing v1alpha1 output protects stored artifacts from Compiler.verify failures.

#### E7 · Codex adapter v2: sectioned AGENTS.md, mcp_servers, policy-driven config, hooks as checklist

**Priority** P0 · **Effort** M · **Type** change · **Depends on** E1

**What.** v1alpha2 branch: AGENTS.md from spec.guidance sections (same renderer helper as E6, shared in lib/harness_forge/adapters/guidance.ex); .codex/config.toml adds [mcp_servers.<name>] command/args/url blocks from spec.mcp, approval_policy=on-request (hands_free) or untrusted (team), sandbox network_access from network.denied policy, project_doc_max_bytes covering AGENTS.md; agents TOML unchanged plus optional model omitted; hooks rendered as a 'Before you finish' checklist section in AGENTS.md and reported unsupported_control (Codex hooks feature is gated per lib/harness_forge/execution/codex.ex:24); command_permissions reported unsupported with the mapped AGENTS.md checklist line.

**Where.** lib/harness_forge/adapters/codex.ex (compile/2, config_toml/2, guidance/1); lib/harness_forge/adapters/guidance.ex (new shared Markdown section renderer); docs/codex-connector.md

**Why.** Codex has no portable hook or per-command permission surface, so honesty requires checklist rendering plus visible unsupported diagnostics, consistent with the existing capability report.

#### E8 · OpenCode adapter v2: permission patterns, agent tool maps, mcp, sectioned AGENTS.md

**Priority** P0 · **Effort** M · **Type** change · **Depends on** E1

**What.** v1alpha2 branch: AGENTS.md via shared renderer; opencode.json permission becomes {edit: allow (hands_free) | ask (team), bash: {"<pattern>": action..., "*": ask}, webfetch: ask, external_directory: deny} from tool_permissions + command_permissions; agent map gains mode and tools {portable: boolean} per agent; mcp map from spec.mcp ({type: local|remote, command/url, enabled: true}); agent markdown frontmatter adds tools; hooks rendered as checklist + unsupported_control. Add docs/opencode-connector.md mirroring the other two connector docs.

**Where.** lib/harness_forge/adapters/opencode.ex (compile/2, permissions/1, agent_markdown/1); docs/opencode-connector.md (new); lib/harness_forge/adapters/registry.ex (config_paths adds .mcp.json/.harnessforge paths)

**Why.** Brings the default target to parity so 'all targets' emits equivalent maturity from one spec.

#### E9 · Compiler v2 layout, versioned identity and compile-time maturity score

**Priority** P0 · **Effort** M · **Type** change · **Depends on** E1

**What.** For v1alpha2 specs Compiler.assemble writes provenance under .harnessforge/{spec,provenance,capabilities,manifest,maturity}.json (v1alpha1 keeps root-level names), bumps @identity to compiler_version 0.2.0 / template_version v1alpha2.1 for v2 only, and records spec.generation in provenance. New pure HarnessForge.Generation.Maturity.score(spec, files) returns {score 0-100, level seed|basic|solid|mature, dimensions[]} with weighted dimensions: project_map, commands (install/build/test/lint present), conventions (>=3), do_dont, architecture, review_checklist, rules_provenance, permissions_tuned (allow non-empty, deny has destructive patterns, not all-ask), hooks (format on edit; lint/test before stop), agents_purposeful (>=2 with tool restrictions), skills (>=2 stack-specific), mcp_declared_or_none, size_budget (guidance <= 12 KB), target_parity (unsupported required-free). Each dimension carries status pass|partial|missing, why and fix text. HarnessDelivery.preview/1 adds "maturity" read from .harnessforge/maturity.json (data only; rendering is lens 4).

**Where.** lib/harness_forge/compiler.ex (assemble/3, @identity by version); lib/harness_forge/generation/maturity.ex (new); lib/harness_forge_web/harness_delivery.ex (preview/1); lib/harness_forge/adapters/registry.ex

**Why.** A rubric computed from spec+files only is deterministic, ships inside the artifact, and gives the portal and CLI one source of truth for status without a new evaluation kind.

#### E10 · Idempotent in-place sync export and working-tree plan diff

**Priority** P1 · **Effort** M · **Type** add · **Depends on** E5, E9

**What.** Artifacts.export/3 gains mode: :sync (default stays :fresh): target may exist; writes only paths in the artifact manifest; before writing, compares each existing file's sha256 with the previously generated hash recorded in <target>/.harnessforge/manifest.json; unchanged -> skip, absent -> write, matches previous generated hash -> overwrite, differs from previous hash -> report user_modified and skip unless force: true; owned files no longer generated are removed only if unmodified. Writes go through the existing private stage + rename per file. HarnessForge.Generation.Diff.against_directory(artifact, dir) returns per-file status (added|changed|unchanged|user_modified|removed) and line diffs via List.myers_difference/2 bounded to 64 KB per file; Generation.plan/1 returns {digest, maturity, changes}. Releases.diff/2 is reused unchanged for artifact-vs-artifact comparison.

**Where.** lib/harness_forge/artifacts.ex (export/3, new sync_at/3, valid_target/2); lib/harness_forge/generation/diff.ex (new); lib/harness_forge/generation.ex (plan/1); lib/harness_forge/harnesses.ex (export/3 passes mode)

**Why.** Re-running must produce no churn and a precise preview; protecting user-edited generated files is what makes hands-free regeneration safe to automate (lens 5).

#### E11 · CLI generate/plan command; legacy build moved behind advanced help

**Priority** P1 · **Effort** S · **Type** add · **Depends on** E5, E10

**What.** Add CLI.run(["generate" | flags]) parsing --root DIR, --target claude_code|codex|opencode|all (default from config), --mode hands_free|reviewed, --team, --notes FILE, --out DIR (fresh) | --in-place (sync into root, default when --root given), --plan (no publish, no write), --force. JSON result {ok, digest(s), maturity, changes, files_written, skipped_user_modified, diagnostics}. Keep build NAME VERSION [runtime [version]] and company build but list them under an 'advanced (reviewed mode)' group in help. bin/harnessforge unchanged.

**Where.** lib/harness_forge/cli.ex (run/1 clauses, help/0 grouping); docs/quickstart.md (generate first, demo second)

**Why.** One command gives the solo developer the whole engine; the wizard (lens 3) can call the same Generation functions.

#### E12 · Golden-file tests, determinism/idempotence tests and documentation of the mature package

**Priority** P1 · **Effort** M · **Type** add · **Depends on** E6, E7, E8, E9, E10

**What.** test/harness_forge/generation_test.exs: same profile+overlay -> identical digest across runs and targets; plan after sync reports all unchanged; user-modified file skipped without --force; overlay precedence (scalar replace, list merge, remove, required never set); reviewed mode includes approved claims and refuses stale ones. test/harness_forge/generation/{maturity,overlay,blueprint,diff}_test.exs. Golden snapshots per profile and target under test/fixtures/generation/<profile>/<target>/ compared byte-for-byte (regeneration script in test/support). Update exact file-list assertions in claude_code_adapter_test.exs:22-27 and codex_adapter_test.exs:22-27 for v2 fixtures while keeping v1alpha1 fixture tests untouched. Docs: docs/mature-package.md (definition per target, section list, permission defaults, hook defaults, maturity rubric, overlay headings), docs/contracts.md (v1alpha2), connector docs updated, docs/status.md row for hands-free generation.

**Where.** test/harness_forge/generation_test.exs (new); test/harness_forge/generation/*_test.exs (new); test/fixtures/generation/** (new); test/harness_forge/{claude_code,codex}_adapter_test.exs; docs/mature-package.md (new); docs/contracts.md; docs/status.md

**Why.** Golden bytes lock determinism and make native-format drift visible in review; the document is the shared definition the other lenses and future agents implement against.

### Reuse as-is or lightly adapted

- HarnessForge.Compiler (pure compile, verify-by-recompile, manifest/digest assembly) at lib/harness_forge/compiler.ex — keep as the only path to bytes; add the v2 branch rather than a second compiler.
- HarnessForge.Contracts canonical JSON, digest and the small schema validator at lib/harness_forge/contracts.ex — reuse for the v1alpha2 schema, profile and overlay digests.
- HarnessForge.Artifacts content-addressed publish (returns existing artifact for identical digest, artifacts.ex:90-97) and staged exclusive writes — the idempotence primitive; extend with sync mode only.
- Adapter escaping and safety helpers (ClaudeCode.quoted/1, Codex.toml_string/1, safe_name?/1, static_skills/1) at lib/harness_forge/adapters/*.ex — reuse for all new frontmatter, TOML and JSON rendering.
- HarnessForge.Releases.diff/2 at lib/harness_forge/releases.ex:104-115 — artifact-vs-artifact file and rule differences for 'what changed since last generation'.
- HarnessForge.Readiness report shape (stages, blockers, next_action) at lib/harness_forge/readiness.ex:280-302 — mirror its status vocabulary in the maturity dimensions so the portal can render both the same way.
- HarnessForgeWeb.HarnessDelivery.preview/1 and download/1 at lib/harness_forge_web/harness_delivery.ex — the bounded data seam for maturity and plan output to the portal and ZIP download.
- HarnessForge.Demo deterministic citation + create_claim pattern (lib/harness_forge/demo.ex:55-75) and Jobs.Operation Oban dispatch (lib/harness_forge/jobs/operation.ex) — for the optional 'promote derived facts to reviewable claims' step in reviewed mode and for background generation.

### Risks

- Stored-artifact invalidation: Artifacts.read_at calls Compiler.verify, which recompiles; any change to v1alpha1 rendering breaks every existing workspace artifact. Mitigation: branch on apiVersion and lock v1alpha1 output with the existing fixture tests.
- Native format drift (UNVERIFIED offline): Claude hooks/permission-rule syntax, Codex mcp_servers and gated hooks, OpenCode per-command bash permission objects must be re-checked against the pinned versions (2.1.311 / 0.156.0 / 1.x) before golden files are frozen; the adapters currently refuse other versions, so a version bump is a separate decision.
- Hooks execute on the developer's machine via the target CLI; a slow or wrong command (e.g. full test suite on Stop) degrades the experience. Mitigation: commands come only from the validated profile, format-on-edit is the sole default, lint/test hooks are opt-in with timeouts.
- Permission widening: hands-free allow lists (Edit/Write/Bash(<cmd>:*)) remove prompts by design; a mis-detected command prefix (e.g. a wrapper script) could allow more than intended. Mitigation: deny list for destructive patterns always emitted, profile command validation rejects shell metacharacters, team layer restores stricter defaults.
- Guidance size and the '@' rule: generated sections can grow past Codex project_doc_max_bytes or Claude's practical limits, and relaxing the '@' rejection to 'outside code spans' depends on Claude's import semantics. Mitigation: size_budget dimension, truncation diagnostics, code-span rendering of all identifiers, explicit test.
- Cross-lens contract drift: the RepoProfile shape (lens 2), maturity/plan payloads (lens 4) and regeneration triggers (lens 5) are interfaces defined here; disagreement late in implementation costs rework. Mitigation: fixtures in examples/profiles and golden outputs are the contract.

### Open questions for the owner

- Solo hands-free permission posture: allow Edit/Write/Read and every detected project command outright (proposed), or keep Bash on 'ask' except detected test/format/lint commands?
- Hook defaults: format-on-edit only (proposed), or also lint and the test suite on Stop/before-commit even though they may be slow in large repositories?
- In-place sync into the repository as the default for `generate --root` (proposed) versus the current fresh-directory export; and may a user-edited generated file ever be overwritten without --force (proposed: never)?
- May model-proposed claims enter a hands-free package unreviewed, clearly labelled as 'suggested' (default off), or must hands-free stay fully deterministic and offline (proposed)?
- Keep v1alpha1 rendering frozen indefinitely for stored previews (proposed), or accept a one-time invalidation with a migration note since all current artifacts are unqualified previews?

## 2. Repository history and tooling signals (inputs)

### Current state

Nothing in lib/ reads a local git repository, a manifest, a CI workflow, CODEOWNERS or an existing agent-instruction file: a grep over lib/**/*.ex for git/System.cmd finds no invocation, and manifest-name hits occur only in evaluation fixtures, the Codex execution inputs, Graphiti worker pins and the adapters' own CLAUDE.md/AGENTS.md outputs. The only local input is HarnessForge.Evidence.LocalImport, which walks an approved directory for .md/.markdown/.txt bodies (500 files, 1 MiB each, 16 MiB total, symlinks rejected) with no .gitignore or secret handling. Remote connectors (github, jira, github_projects, slack, confluence) are credential/scope-bound page importers; the GitHub adapter captures repository metadata, issue/PR bodies and PR reviews but no commits, files or CODEOWNERS. Rules can only come from a human-authored claim, the one-source Models.propose pass (body <= 65,536 bytes, <= 30 claims, byte-exact citations) or the 2-4-source company analysis; every non-rule section of the spec (scope, policies, agents, skills, execution, evaluation) is hard-coded in Harnesses.specification/3. The codebase does already provide the building blocks a Repository Analyzer needs: bounded file reads, immutable citable revisions, a frozen-JSON-schema validator with canonical digests, a cleared-environment subprocess precedent (the Python capture scanner), a finite model-purpose registry, and explicit privacy inventory/purge allowlists.

| Finding | Evidence |
|---|---|
| No module shells out to git or reads .git; no git library is a dependency, so history mining must call the system git binary (already a documented prerequisite). | grep -rn -i -E '\bgit\b\|git log\|git rev\|\.git/\|System\.cmd' lib/ --include='*.ex' -> no matches; mix.exs:42-77 deps list (phoenix, ecto_sqlite3, oban, req, jason...; no git lib); docs/quickstart.md:26 lists Git as a requirement. |
| No manifest/tooling detection exists; manifest filenames appear only in fixtures, the Codex execution inputs, Graphiti worker pins and adapter outputs. | grep for mix.exs\|package.json\|Cargo.toml\|pyproject\|Makefile\|CODEOWNERS\|.github/workflows\|.editorconfig\|CLAUDE.md\|AGENTS.md\|.cursorrules\|CONTRIBUTING\|.gitignore\|Dockerfile: hits only in lib/harness_forge/evaluation/task_suite.ex:40,178,184; evaluation/holdout_suite.ex:7-8; execution/codex.ex:19,177,313; evidence/graph_sources.ex:9; adapters/claude_code.ex:121; adapters/codex.ex:91; adapters/opencode.ex:106; harnesses.ex:304. |
| Local import reads only Markdown/text, bounded, symlink-safe, with no .gitignore honoring and no redaction. | lib/harness_forge/evidence/local_import.ex:3-6 (@max_bytes 1_048_576, @max_files 500, @max_total_bytes 16_777_216, @extensions ~w(.md .markdown .txt)); :8-19 approved_directory; :215-231 no_symlink_components; docs/status.md:22 'content captured as written, not automatically redacted'; portal warning lib/harness_forge_web/live/portal_live.ex:3153. |
| The GitHub connector captures repository metadata, issue/PR bodies and PR reviews only; commits, files, CODEOWNERS and workflows are out of scope even with a token. | lib/harness_forge/connectors/github.ex:2 moduledoc, :19-28 capabilities kinds ~w(repository issue pull_request review), comments false; docs/integrations.md:10 'No repository files, issue comments or independent review change feed'. |
| Providers are a compiled-in allowlist plus the special-cased 'local' provider; Evidence.sync branches on provider == 'local' to a full directory walk. | lib/harness_forge/connectors/registry.ex:5-11 adapter/1, :19 document_scope(%{provider: "local"}); lib/harness_forge/evidence.ex:137-144 sync/2, :84-118 import_directory/1, :769-782 connection_attrs. |
| Revisions are immutable, deduplicated by body hash, carry a free-form metadata map and a source_url; citations are byte-exact against a revision. This is the natural persistence path for mined instruction files and a generated signals report. | lib/harness_forge/evidence.ex:539-608 persist_document (hash compare at :553-567, metadata at :581), :306-326 citation/3, :740-755 snippet/3; lib/harness_forge/evidence/records.ex:34-48 Revision schema (metadata :map). |
| The only hands-free rule generators are model passes: Models.propose handles one source <= 65,536 bytes and <= 30 claims with 1-10 byte-exact citations; company analysis needs 2-4 selected sources and a goal. There is no deterministic, model-free rule candidate path besides the demo fixture. | lib/harness_forge/models.ex:164-167 propose/2 size bound, :246-250 finite purposes (proposal\|chat\|company_analysis); lib/harness_forge/models/proposal.ex:7-43 schema, :120-133 valid_citation?; lib/harness_forge/evidence/origin.ex:93 sources length 2..4; lib/harness_forge/demo.ex propose/1 computes offsets with :binary.match. |
| Only rule statements vary per project: scope, policies, agents, skills, execution and evaluation are literals, and Claude settings default every tool to 'ask'. | lib/harness_forge/harnesses.ex:318 scope ['local-workspace'], :342-355 policies, :356-363 agents, :364-371 skills, :372-373 execution/evaluation; lib/harness_forge/adapters/claude_code.ex:281-292 permissions (Map.get(requested, portable, "ask")); harnesses/templates.ex:4-17 two fixed skills. |
| Rule text containing '@' is rejected by the Claude adapter and repository scope must be an opaque identity, so mined CODEOWNERS handles, scoped npm names and local paths need sanitizing before they reach the spec. | lib/harness_forge/adapters/claude_code.ex:166-172 static_rules rejects '@'; lib/harness_forge/compiler.ex:61-76 repository_scope regex forbids paths/URLs. |
| A cleared-environment subprocess boundary already exists (Python directory enumerator run with -I -S, env wiped, framed bounded I/O), giving a template for a safe git wrapper. | lib/harness_forge/evidence/capture/scanner.ex:39-61 open_port (System.get_env cleared, args ['-I','-S','-X','utf8', script], {:packet,4}); priv/corpus_capture/scan.py MAX_FRAME/MAX_BATCH bounds; lib/harness_forge/application.ex:17 Scanner in the supervision tree. |
| Privacy inventory, purge, audit payload keys and the Operation job are explicit allowlists that any new table, event or UI action must be added to; Oban runs one serialized queue with no cron plugin. | lib/harness_forge/privacy.ex:46-47 inventory tables; lib/harness_forge/privacy/purge.ex:7-8 @immutable/@content_tables; lib/harness_forge/audit.ex:6 @allowed keys; lib/harness_forge/jobs/operation.ex:36-43 dispatch (sync\|propose\|evaluate); config/config.exs:20-24 Oban queues [default: 1], plugins []. |
| This repository's own history and tooling show what a zero-config analysis yields: 5 commits, all Conventional-Commit prefixed (feat:/docs:/ci:), one author, no tags, branches main and local-development, CI running mix format/compile --warnings-as-errors, pinned .tool-versions, AGENTS.md and CONTRIBUTING.md present, no CLAUDE.md/.cursorrules/CODEOWNERS/.editorconfig. No doc or PROGRESS.md entry mentions git-history mining (grep count 0; unverified beyond the grep terms used). | git log --format='%h %ad %an %s' (5 commits 2026-11-07); git tag (empty); git branch -a; .github/workflows/ci.yml steps; .tool-versions (erlang 28.3.1, elixir 1.19.5-otp-28); ls CLAUDE.md .cursorrules CODEOWNERS .editorconfig -> missing; grep -c -i -E 'git history\|git log\|repository analy\|conventional commit\|commit message\|CODEOWNERS\|co-change\|churn' PROGRESS.md README.md docs/*.md docs/enhancement-program/*.md -> all 0. |

### Gaps

- **No reader of local git history (commits, refs, tags, numstat), so commit conventions, hot files, ownership, release cadence and co-change clusters cannot be derived.** These are the only credential-free, model-free inputs that differ between projects; without them the hands-free harness is the same template everywhere.
- **Local import is limited to .md/.markdown/.txt, so manifests (mix.exs, package.json, Cargo.toml, pyproject, go.mod), CI workflows, Dockerfiles, lockfiles and formatter/linter configs are invisible.** Stack, build/test/lint commands and test frameworks drive the skills, permission allow-lists and evaluation checks of a mature package.
- **Existing agent-instruction files (CLAUDE.md, AGENTS.md, .cursorrules, .cursor/rules, copilot-instructions.md, .claude/settings.json, .codex/config.toml) and CONTRIBUTING/ADR/CODEOWNERS are neither detected nor lifted into rule candidates.** They are the highest-confidence statement of a team's conventions and must seed the harness instead of being overwritten.
- **There is no deterministic rule-candidate generator; every rule needs a human-typed claim or a model call.** A solo developer with no model and no credentials currently gets zero project-specific rules.
- **No .gitignore honoring, secret scanning, env-file policy or author pseudonymization for local reads.** Reading a real repository without these limits would copy .env values, keys in fixtures and personal emails into the SQLite evidence store and backups.
- **The GitHub connector cannot substitute for local mining (no commits, files, CODEOWNERS) and requires network/credentials for private repos.** Hands-free by default must work offline on the checkout the developer already has.
- **No repository identity flows into the spec: scope.repositories is the literal 'local-workspace'.** Multi-repo teams and monorepos need per-repository scope and provenance in the package.
- **No incremental or continuous re-analysis: local sync is a full walk and remote sync is page-based; nothing tracks the analyzed HEAD.** Continuous regeneration on new commits (lens 5) needs delta mining and a stable aggregate store.
- **The model layer has a finite purpose registry (proposal, chat, company_analysis) and a one-source 64 KiB limit; no purpose summarizes mined signals into rules.** The optional local-Ollama summary pass must reuse consent, ledger and byte-citation validation rather than a new path.
- **Tests have no synthetic git repositories; fixtures are Markdown-only directories.** History miners need deterministic repos (fixed authors/dates, tags, merges, secrets traps) to be verifiable offline.

### Target design

A new `HarnessForge.Analyzers` context turns an already-checked-out repository into a string-keyed Signals document with no model and no credentials. `bin/harnessforge analyze PATH` (or the wizard's directory pick) creates a connection with provider "repository", and `Evidence.sync` routes that provider to `Analyzers.Repository.analyze/2`, which runs four detectors in fixed order: `Analyzers.Git.History` (commit conventions, hot/volatile files, path ownership, merge/PR and branch workflow, release tags and cadence, revert/fix hot spots, co-change clusters) over a bounded `git log --numstat` read; `Analyzers.Stack` (languages, package managers, build/test/lint/format commands, CI workflows, Docker, monorepo layout, test frameworks, env/config file names and tool versions) over `git ls-files --exclude-standard` so .gitignore is honored; `Analyzers.Instructions` (CLAUDE.md, AGENTS.md, .cursorrules, .cursor/rules, copilot-instructions, .claude/settings.json, .codex/config.toml, CONTRIBUTING, README, ADRs, CODEOWNERS) which imports those files as ordinary evidence revisions and lifts imperative sentences into rule candidates with byte-exact citations; and `Analyzers.Enrichers`, which only reads sources already synced by the existing GitHub/Jira/Slack/Confluence connectors. Every signal is `{"key","value","confidence","evidence":[...],"detector","version"}`; the whole document is validated against `priv/schemas/repository-signals-v1.json`, canonically digested, stored in a `repository_analyses` row, and rendered as `signals.json` + `signals.md` evidence revisions so rules derived from it carry the same citations as human claims. `Analyzers.Confidence` scores declared files at 90, statistical history signals by ratio x min(1, n/50) x 100 with a recency weight and a -20 truncation penalty, +10 for cross-detector agreement, and buckets them auto (>=70), suggested (40-69) or observed-only (<40). `Analyzers.Mapping.harness_inputs/1` hands the generation engine string-keyed inputs per harness section (rules, commands for skills, permission hints, ownership notes, evaluation checks, repository identity), so the solo path consumes auto signals directly while the team path turns the same candidates into proposed claims for the existing Decisions flow. Re-analysis stores the analyzed HEAD and manifest fingerprints: a fast-forward delta mines only `previous..HEAD` and merges persisted per-file and pair aggregates; a rewritten history (previous not an ancestor) triggers a full recompute. Privacy limits are enforced in `Analyzers.Git.Command` and `Analyzers.Secrets`: allow-listed git subcommands run with a cleared environment, GIT_CONFIG_NOSYSTEM/GIT_CONFIG_GLOBAL=/dev/null, --no-ext-diff and timeouts; only allow-listed filenames are opened (<=256 KiB each); .env* contents are never read (only key names of .env.example); stored text is secret-scanned and redacted; authors are pseudonymous hashes unless the team option enables names. Manual instructions layer on top optionally: an existing CLAUDE.md/AGENTS.md is lifted first and wins conflicts, and a repo-local `.harnessforge/analyzer.json` (exclude paths, author names, max commits, extra instruction files, command overrides) adjusts detection; the optional `Analyzers.Summary` pass sends only the signals report to local Ollama first (cloud with existing consent) under a new finite purpose with byte-citation validation.

### Day one after the plan ships

1. `cd my-repo && bin/harnessforge analyze .` runs offline in seconds and prints JSON: stack (elixir 1.19 / phoenix), commands (test `mix test`, lint `mix credo --strict`, format `mix format`), conventions (conventional commits 100%, n=5), workflow (1 author, branch main, no tags), instruction files found (AGENTS.md, CONTRIBUTING.md), 14 rule candidates (9 auto, 5 suggested), privacy (0 secrets stored, .env ignored, authors pseudonymous).
2. `bin/harnessforge analyze signals . --section history` lists hot files, revert/fix hot spots and co-change clusters, each with the commit hashes and paths that produced it.
3. The wizard/portal shows one Repository card: stack badges, confidence meters per section and a Re-analyze button; no form fields are required.
4. After pushing three commits, `bin/harnessforge analyze .` reports `mode: incremental, commits_processed: 3` and only changed signals move; a rebase triggers `mode: full` automatically.
5. Optional: `bin/harnessforge analyze summarize .` with a local Ollama model turns signals.md into <= 20 cited rules stored as proposed claims; cloud providers require the existing consent step.
6. Team layer (optional): `bin/harnessforge analyze . --authors` adds CODEOWNERS-based ownership with names; candidates become proposed claims that reviewers approve in the existing Decisions flow before the generation engine builds the package from `Analyzers.Mapping.harness_inputs/1`.

### Proposed changes

#### H1 · Safe git command boundary

**Priority** P0 · **Effort** M · **Type** add · **Depends on** none

**What.** Add a wrapper that runs only allow-listed git subcommands (`rev-parse`, `log --format=<fixed> --numstat --date=iso-strict -n MAX`, `for-each-ref`, `tag --list`, `shortlog -sne`, `ls-files --cached --others --exclude-standard`, `check-ignore --stdin`, `config --get remote.origin.url`, `merge-base --is-ancestor`, `diff --name-only A B -- <patterns>`) through System.cmd with a cleared environment plus GIT_TERMINAL_PROMPT=0, GIT_CONFIG_NOSYSTEM=1, GIT_CONFIG_GLOBAL=/dev/null, `-c core.pager=cat -c core.fsmonitor=false`, `--no-ext-diff`, 60 s per call, 16 MiB output cap, 5,000-commit default cap (config key `:analyzer_max_commits`). Probe `git --version` once (on darwin check `xcode-select -p` first to avoid the CLT dialog) and return `{:error, :git_unavailable}` so analysis degrades to stack-only. Strip userinfo from remote URLs and reject token-looking fragments.

**Where.** new lib/harness_forge/analyzers/git/command.ex (HarnessForge.Analyzers.Git.Command); config key `:harness_forge, :analyzer_max_commits` in config/config.exs; pattern copied from lib/harness_forge/evidence/capture/scanner.ex:39-61

**Why.** Every history signal depends on git; the project's trust model (no repository code on the host, bounded subprocesses, no credential leakage) must hold for the git binary too.

#### H2 · Signals data model, schema, storage and privacy registration

**Priority** P0 · **Effort** M · **Type** add · **Depends on** none

**What.** Define the string-keyed Signals document: `{"version":"repository-signals-v1","repository":{"identity","head","remote","analyzed_at"},"detectors":{name:{"version","complete","truncated"}},"signals":[{"key","value","confidence","bucket","detector","evidence":[{"kind":"file|commit|ref|source","path","line","commits":[<=10],"source_id","revision_id","start_byte","end_byte"}]}],"aggregates":{...}}` with a frozen JSON Schema validated by the existing Contracts validator pattern, canonical digest via Contracts.digest. Add migration `repository_analyses` (id, workspace_id, connection_id, repository_identity, head_commit, parent_analysis_id, analyzer_version, mode full|incremental, signals json, aggregates json, digest, counts, state, started_at, completed_at). Register the table in Privacy inventory and purge lists and add audit actions `repository.analyzed`, `repository.analysis_failed` with allowed keys (`connection_id`, `count`, `status`).

**Where.** new lib/harness_forge/analyzers/signals.ex, lib/harness_forge/analyzers/records.ex (HarnessForge.Analyzers.Analysis schema), priv/schemas/repository-signals-v1.json, priv/repo/migrations/2026MMDD000100_repository_analyses.exs; edits lib/harness_forge/privacy.ex:46-47, lib/harness_forge/privacy/purge.ex:7-8, lib/harness_forge/audit.ex:6

**Why.** A stable intermediate contract lets detectors, mapping, portal and the model pass evolve independently and keeps analysis data inside the existing inventory/purge guarantees.

#### H3 · Git history miner

**Priority** P0 · **Effort** L · **Type** add · **Depends on** H1, H2

**What.** Parse the bounded log into commit records (hash, pseudonymous author_id, iso date, subject <= 200 chars, merge?, files with add/del) and emit signals: `conventions.commits` (conventional-commit ratio, type set, scope set, ticket-id pattern such as ABC-123/#123, sign-off ratio, average subject length), `workflow.merges` (merge-commit ratio, 'Merge pull request #' and squash '(#123)' patterns), `workflow.branches` (local/remote ref naming families: main|master|develop, feature/, release/, hotfix/), `releases.tags` (semver tags, median interval days, latest tag, days since), `hotspots.files` (top 25 by commits in last 365 days and all-time, churn lines), `hotspots.fixes` (files most often touched by fix/revert/hotfix commits; revert count), `ownership.paths` (top-level and second-level directories -> top 3 author_ids by commit and line share, bus factor), `cochange.clusters` (file pairs with support >= 3 and Jaccard >= 0.5, skipping commits touching > 100 files; capped at 50 pairs). Persist per-file and per-pair counters in `aggregates` for incremental merging.

**Where.** new lib/harness_forge/analyzers/git/history.ex (HarnessForge.Analyzers.Git.History) with pure functions `parse_log/1`, `signals/2`, `merge_aggregates/2`

**Why.** These are the project-specific facts that make a harness mature without any manual input.

#### H4 · Stack and tooling detector

**Priority** P0 · **Effort** L · **Type** add · **Depends on** H1, H2

**What.** From the `git ls-files` listing (or a bounded, .gitignore-free fallback walk reusing LocalImport.approved_directory when no git repo exists) detect: `stack.languages` (extension histogram, top 5), `stack.manifests` (mix.exs, package.json + lockfile kind, pyproject.toml/requirements.txt/poetry.lock/uv.lock, Cargo.toml, go.mod/go.work, Gemfile, pom.xml, build.gradle(.kts), composer.json, *.csproj/*.sln, Package.swift, pubspec.yaml, CMakeLists.txt, Makefile/Justfile/Taskfile.yml), `commands.{build,test,lint,format,typecheck}` extracted without evaluating code (Jason for package.json scripts; line regex for mix.exs aliases, Makefile targets, pyproject [tool.*] sections, YAML `run:` lines bounded to 20 per job), `ci.workflows` (.github/workflows/*.yml job names and run lines, .gitlab-ci.yml, .circleci/config.yml, Jenkinsfile, azure-pipelines.yml), `containers` (Dockerfile*, docker-compose*.yml, .devcontainer/), `layout.monorepo` (pnpm-workspace.yaml, workspaces field, nx.json, turbo.json, lerna.json, Cargo workspace, apps/ umbrella, go.work; per-package manifests capped at 50), `testing.frameworks` (ExUnit, jest/vitest/mocha config, pytest.ini/conftest.py, go test, cargo test, rspec), `tooling.formatters_linters` (.formatter.exs, .credo.exs, eslint/biome/prettier configs, ruff/black, rustfmt/clippy, golangci, .editorconfig), `config.env_files` (names only, plus key names from .env.example/.env.sample), `tooling.versions` (.tool-versions, .nvmrc, .python-version, rust-toolchain.toml, .ruby-version, engines). Only allow-listed filenames are opened, each <= 256 KiB, via LocalImport.read_file-style bounded reads.

**Where.** new lib/harness_forge/analyzers/stack.ex (HarnessForge.Analyzers.Stack), lib/harness_forge/analyzers/stack/manifests.ex (per-manifest extractors), lib/harness_forge/analyzers/ignore.ex (git check-ignore wrapper + fallback); reuse lib/harness_forge/evidence/local_import.ex read/approval helpers

**Why.** Commands and frameworks are what the skills, permission allow-lists and evaluation checks of the package must reflect; the current template cannot name a single real command.

#### H5 · Existing instruction and docs lifter

**Priority** P0 · **Effort** M · **Type** add · **Depends on** H2, H4

**What.** Detect and import as evidence revisions (provider 'repository', external_id = relative path, metadata normalizer_version 'repo-instructions-v1', kind instruction|contributing|readme|adr|codeowners|settings): CLAUDE.md, .claude/CLAUDE.md, AGENTS.md, .cursorrules, .cursor/rules/*.mdc, .github/copilot-instructions.md, .windsurfrules, .clinerules, GEMINI.md, .claude/settings.json, .codex/config.toml, opencode.json, CONTRIBUTING.md, README.md, SECURITY.md, docs/adr/**/*.md, docs/decisions/**/*.md, doc/architecture/decisions/**/*.md, .github/PULL_REQUEST_TEMPLATE.md, CODEOWNERS (.github/, root, docs/). Emit `instructions.existing` (which agent files exist, byte sizes), `ownership.codeowners` (pattern -> handles with '@' stripped), `instructions.rule_candidates`: imperative sentences (must|never|always|do not|required|before) from instruction/contributing files as rule candidates whose citations are byte offsets computed with :binary.match against the stored revision (as lib/harness_forge/demo.ex does), confidence 90 for agent files, 80 for CONTRIBUTING, 60 for README. Flag conflicts between lifted commands and detected manifests (e.g., CONTRIBUTING says `npm test` but package.json has no test script).

**Where.** new lib/harness_forge/analyzers/instructions.ex (HarnessForge.Analyzers.Instructions); uses HarnessForge.Evidence.import_markdown/2 (lib/harness_forge/evidence.ex:123-134) and Evidence.citation/3; adds `document_scope(%{provider: "repository"}, _)` in lib/harness_forge/connectors/registry.ex:19

**Why.** Teams that already wrote CLAUDE.md/AGENTS.md expect the harness to start from it; lifting with citations keeps the existing provenance guarantees and never overwrites the file.

#### H6 · Privacy guard: secrets, env policy, pseudonymous authors, ignore rules

**Priority** P0 · **Effort** M · **Type** add · **Depends on** H1, H2

**What.** Add `Analyzers.Secrets.scan/1` (regexes for AKIA..., ghp_/gho_/github_pat_, sk-..., xox[baprs]-, -----BEGIN ... PRIVATE KEY-----, JWT-like, generic `(api[_-]?key|secret|token|password)\s*[:=]\s*\S{16,}`) applied to every string before it is stored in signals or evidence; redact to [REDACTED] and record `privacy.redactions` count. Never open any `.env*` except key names of `.env.example`/`.env.sample`; never open files > 1 MiB, binary files or symlinks; honor .gitignore through `git ls-files --exclude-standard`/`check-ignore`; author identity = first 12 hex of sha256(lowercased email + workspace id) by default, display names only when the connection config `author_names` is true; store commit subjects only (no bodies); strip userinfo from remote URLs. Honor optional `.harnessforge/analyzer.json` (`exclude_paths`, `author_names`, `max_commits`, `extra_instruction_files`, `commands`) validated as string-keyed JSON with Contracts.decode_json.

**Where.** new lib/harness_forge/analyzers/secrets.ex, lib/harness_forge/analyzers/policy.ex (HarnessForge.Analyzers.Policy for .harnessforge/analyzer.json and env rules); applied inside H3/H4/H5 before persistence; docs section in docs/privacy.md

**Why.** docs/status.md:22 states evidence is captured as written and not redacted; reading real repositories hands-free is only acceptable with these limits built in.

#### H7 · Repository provider, orchestrator, report revisions and incremental re-analysis

**Priority** P0 · **Effort** L · **Type** change · **Depends on** H1, H2, H3, H4, H5, H6

**What.** Add provider 'repository' (directory + config `{"author_names":false,"max_commits":5000}`) handled like 'local': `Evidence.connect` accepts it via LocalImport.approved_directory; `Evidence.sync` routes it to `HarnessForge.Analyzers.Repository.analyze(connection)`, which runs H3-H5 (and H10 when connections exist), builds the Signals document, validates it (H2), writes `signals.json` and `signals.md` as evidence revisions of that connection (dedupe by body hash so unchanged analyses create no revision), inserts the `repository_analyses` row and audits. Incremental mode: load the latest analysis for the connection; if `git merge-base --is-ancestor previous HEAD` then mine only `previous..HEAD`, merge aggregates, re-run Stack/Instructions only when `git diff --name-only previous HEAD -- <allow-listed manifest/instruction patterns>` is non-empty; otherwise run full. Expose `Analyzers.latest/1`, `Analyzers.signals/2` (section filter), `Analyzers.diff/2` (previous vs current signal values) and `Analyzers.analyze_path/2` (create-or-reuse connection for an absolute path, then sync). Repository identity for scope = remote slug (owner/repo) when available else directory basename, sanitized to the compiler's opaque-identity regex.

**Where.** new lib/harness_forge/analyzers.ex (HarnessForge.Analyzers context), lib/harness_forge/analyzers/repository.ex; edits lib/harness_forge/evidence.ex:137-144 (sync branch), :769-782 (connection_attrs for provider 'repository'), lib/harness_forge/connectors/registry.ex:19 (document_scope), lib/harness_forge/jobs/sync.ex (terminal errors :git_unavailable, :unreadable_directory)

**Why.** Reusing connection/revision/sync semantics gives the analyzer purge, backup, audit, citations and portal sync status for free, and the HEAD/aggregate record makes continuous regeneration cheap.

#### H8 · Confidence scoring and signals-to-harness mapping

**Priority** P0 · **Effort** M · **Type** add · **Depends on** H2, H3, H4, H5

**What.** `Analyzers.Confidence.score/2`: declared-file signals start at 90; statistical signals = round(ratio * min(1, n/50) * 100) with recency weighting (commits in last 365 days count 1.0, older 0.5); +10 when two detectors agree (e.g., CI run line equals manifest test script); -20 when the detector reports truncation; buckets auto >= 70, suggested 40-69, observed < 40. `Analyzers.Mapping.harness_inputs/1` returns string-keyed inputs for the generation engine (lens 1): `rules` (candidate statements with citations into signals.md or lifted files, sanitized: no '@', <= 4096 chars), `commands` (build/test/lint/format for skills and permission allow hints such as `mix test`, `npm run lint`), `conventions` (commit format, branch naming), `ownership` (path -> owner ids, team layer only), `hotspots` (files to treat carefully), `evaluation_checks` (CI commands), `privacy` (env files to deny-read), `repository_identity` for scope.repositories, plus `bucket` per item so hands-free generation uses auto items and the team path turns auto+suggested into proposed claims via Evidence.create_claim.

**Where.** new lib/harness_forge/analyzers/confidence.ex, lib/harness_forge/analyzers/mapping.ex; consumer hook documented for lib/harness_forge/harnesses.ex:302-376 (lens 1 replaces literals at :318, :342-373)

**Why.** Hands-free generation needs a defensible rule for what to trust; the mapping is the contract between inputs (this lens) and the package builder (lens 1).

#### H9 · CLI verbs and job action

**Priority** P0 · **Effort** S · **Type** change · **Depends on** H7

**What.** Add `analyze PATH [--authors] [--max-commits N]` (create-or-reuse repository connection, sync, print summary JSON), `analyze status CONNECTION_ID`, `analyze signals CONNECTION_ID [SECTION]` (stack|history|instructions|ownership|ci|privacy), `analyze diff CONNECTION_ID`, `analyze explain CONNECTION_ID SIGNAL_KEY` (prints evidence paths/commits/byte ranges), `connect repository NAME DIRECTORY`, and `analyze summarize CONNECTION_ID` (H11). Register them in `help`. Add Operation job action `analyze` (dispatch to Analyzers.Repository.analyze) so the portal/wizard can enqueue it with PubSub completion like sync.

**Where.** lib/harness_forge/cli.ex (new run/1 clauses near :69-70 and help list :221-274); lib/harness_forge/jobs/operation.ex:36-43 (`dispatch(%{"action" => "analyze", "id" => id})`); docs/quickstart.md CLI block

**Why.** One command with zero flags is the solo-developer entry point; the job action is what the wizard (lens 3) and portal (lens 4) call.

#### H10 · Optional enrichers from already-synced connectors

**Priority** P2 · **Effort** M · **Type** add · **Depends on** H2, H7

**What.** When active connections exist, read only stored revisions (no network): GitHub reviews -> `review.culture` (share of PRs with >= 1 review, approval states, median reviews per PR), issues/PRs -> `work.labels` and title conventions; Jira changelog records -> `workflow.states` (observed transitions) and issue-key pattern (feeds `conventions.commits` ticket pattern agreement bonus); Confluence/Slack -> `docs.presence` and channel references only. Each enrichment cites source_id/revision_id/byte ranges of the connector revisions. Surface in the portal only under an advanced/team toggle.

**Where.** new lib/harness_forge/analyzers/enrichers.ex (HarnessForge.Analyzers.Enrichers) reading via HarnessForge.Evidence.list_sources/0 filtered by provider and metadata kind (lib/harness_forge/connectors/github.ex:248-256 metadata shape, jira.ex changelog records)

**Why.** Teams that already connected GitHub/Jira get review and workflow signals without new credentials or scope, keeping the default path offline.

#### H11 · Optional model summary pass over the signals report

**Priority** P1 · **Effort** M · **Type** add · **Depends on** H7, H8

**What.** Add finite purpose `repository_summary` to Models.Profile (system prompt: summarize supplied repository signals into <= 20 concise engineering rules, untrusted data, cite exact byte ranges of the supplied report; schema `{"rules":[{"text"<=600,"section":enum(stack|workflow|testing|review|release|ownership|safety),"confidence":0-100,"citations":[1..6]}],"uncertainty"}`), validate with Proposal-style byte citations against the `signals.md` revision (report <= 64 KiB; split by section when larger), run through Models.infer so Ollama is used first and cloud needs existing `cloud_consent` + `source_body` consent, persist as proposed claims with basis `{"kind":"repository_summary","version":1,"analysis_id","analysis_digest","provider","model","config_fingerprint","run_id","request_id"}` by extending Evidence.validate_origin and Origin.references; never required for hands-free output.

**Where.** new lib/harness_forge/analyzers/summary.ex (HarnessForge.Analyzers.Summary), lib/harness_forge/models/repository_summary.ex (schema/system/validate); edits lib/harness_forge/models/profile.ex:37-50, lib/harness_forge/models.ex:246-250 (valid_purpose?), lib/harness_forge/evidence.ex:430-455 (validate_origin), lib/harness_forge/evidence/origin.ex:9-53 (references)

**Why.** Reuses consent, ledger and citation validation for the one place a model adds value (phrasing), while keeping the deterministic path authoritative.

#### H12 · Synthetic fixture repositories, test suite and docs

**Priority** P0 · **Effort** M · **Type** add · **Depends on** H1, H2, H3, H4, H5, H6, H7, H8, H9

**What.** Add `HarnessForge.RepositoryFixture.build/2` that creates deterministic repos in System.tmp_dir!() from JSON recipes (commits with fixed GIT_AUTHOR_DATE/GIT_COMMITTER_DATE, `-c user.name/email`, `-c commit.gpgsign=false`, tags, merge commits, remote URL) and a `git fast-import` stream generator for the large-history case. Recipes: conventional_elixir (mix.exs aliases, .formatter.exs, ci.yml, CODEOWNERS, AGENTS.md, tags v0.1.0/v0.2.0), node_monorepo (pnpm-workspace.yaml, packages/*, eslint, vitest, 'Merge pull request #N' merges, non-conventional subjects), python_poetry_solo (pyproject, pytest, one author, no CI), rust_cargo_workspace (release cadence), secrets_trap (.env with fake value, AKIA key in a fixture file, symlink, gitignored build/ containing a manifest), plain_directory (no .git), large_history (6,000 commits -> truncation flags). Tests: analyzers/git_command_test (env cleared, allowlist, timeout, git missing), git_history_test, stack_test, instructions_test (citations resolve byte-exactly), secrets_test (no trap value appears in DB or signals), repository_test (full then incremental equals full recompute; rebase -> full), confidence_mapping_test (digest determinism, buckets, '@' sanitization, opaque identity), enrichers_test (seeded via existing Req.Test GitHub fixtures), summary_test (model_test_plug, invalid citation rejected), cli_test, privacy_test (purge-source removes analyses). Docs: docs/repository-analyzer.md (signals keys, confidence, privacy limits, .harnessforge/analyzer.json), updates to docs/privacy.md, docs/contracts.md, README 'What it does'.

**Where.** new test/support/repository_fixture.ex, test/fixtures/repositories/*.json, test/harness_forge/analyzers/*_test.exs, test/harness_forge/privacy/analyzer_purge_test.exs; docs/repository-analyzer.md; edits docs/privacy.md, docs/contracts.md, README.md, CHANGELOG.md; add `/.analyzer-test-*/` to .gitignore if fixtures are built under cwd

**Why.** CONTRIBUTING.md requires synthetic shareable fixtures and a success plus refusal case per behavior; deterministic repos are the only way to verify miners offline.

### Reuse as-is or lightly adapted

- lib/harness_forge/evidence/local_import.ex: approved_directory/1, read_file/2, validate_body/1 and symlink rejection for bounded reads of allow-listed manifest and instruction files.
- lib/harness_forge/evidence.ex:123-134 import_markdown/2 and :539-608 persist_document (hash dedupe, metadata map, FTS insert) to store lifted instruction files and the signals.json/signals.md report as citable revisions; :306-326 citation/3 and :328-366 create_claim/1 for rule candidates.
- lib/harness_forge/models/proposal.ex:120-133 byte-exact citation validation and lib/harness_forge/models/profile.ex:37-50 finite purpose registry, plus Models.infer consent/ledger (lib/harness_forge/models.ex), for the optional repository_summary pass.
- lib/harness_forge/contracts.ex: canonical_json/digest and the frozen-schema validator pattern (priv/schemas/harness-v1alpha1.json) for priv/schemas/repository-signals-v1.json and analysis digests.
- lib/harness_forge/evidence/capture/scanner.ex:39-61 cleared-environment, bounded, timed subprocess pattern as the template for Analyzers.Git.Command.
- lib/harness_forge/jobs/operation.ex and lib/harness_forge/jobs/sync.ex with Phoenix.PubSub 'workspace:<id>' broadcasts for portal-triggered analysis and durable sync of the repository provider.
- lib/harness_forge/demo.ex propose/1 (:binary.match offsets -> Evidence.citation -> create_claim) as the deterministic no-model path for lifted sentences.
- lib/harness_forge/privacy.ex:46-47, lib/harness_forge/privacy/purge.ex:7-8 and lib/harness_forge/audit.ex:6 allowlists for registering the new table and events; test/harness_forge/connectors_test.exs Req.Test GitHub fixtures to seed enricher tests.

### Risks

- Git binary variance: missing git, very old versions, or the macOS Xcode CLT shim (which opens a GUI dialog) can stall or fail analysis; mitigate with a one-time `git --version` probe, darwin `xcode-select -p` check, timeouts and stack-only degradation.
- Privacy leakage through commit subjects, author emails, committed fixtures or remote URLs; mitigations (pseudonymous authors, subject-only storage, secret scan, allow-listed reads, .gitignore honoring) are heuristic and must be visibly reported, not assumed complete.
- Scale: monorepos and long histories exceed caps (5,000 commits, 50 packages, 100 files per commit for co-change); truncation must lower confidence and be shown, and co-change pair counting must stay bounded in memory.
- Heuristic parsing (regex over mix.exs, Makefile, YAML run lines) can produce wrong commands; commands are never executed to verify, so confidence must stay below auto when only one detector supports them.
- Over-trusting signals in hands-free mode could encode accidental habits (e.g., chaotic commit style) as rules; thresholds, the observed-only bucket, lifted human instructions winning conflicts and the optional .harnessforge/analyzer.json override limit this.
- Touching Evidence.sync, connection_attrs, Registry.document_scope and purge semantics for a new provider risks regressions in connector scope checks and purge/restore; history rewrites (rebase/force-push) break incremental aggregates unless the ancestor check forces a full recompute.

### Open questions for the owner

- May new parsing dependencies (e.g., a TOML and a YAML library) be added for manifest/CI extraction, or must extraction stay regex/Jason-only as proposed (CONTRIBUTING.md requires a reason, lockfile update and license review for new deps)?
- Default author identity: pseudonymous hashes everywhere (proposed), or real names automatically when the team/governance layer is enabled?
- Should the generated signals.json/signals.md be stored as citable evidence revisions of the repository connection (proposed, reuses purge/backup/citations), or only in the repository_analyses table with a new citation path?
- What default bounds are acceptable for a first release: 5,000 commits and 365-day recency window (proposed), and should over-cap repositories sample old history or truncate it?
- In solo hands-free mode, should auto-bucket candidates bypass claims entirely (generation engine consumes Mapping.harness_inputs directly) or be recorded as claims auto-approved by actor 'repository-analyzer' so one pipeline serves both solo and team modes?

## 3. Wizard: one-command CLI and guided portal flow

### Current state

There is no wizard today. `harnessforge init` only prints the workspace id/root, and the real path to a package is a chain of separate CLI commands or portal tabs: connect a local directory of .md/.txt files, sync, configure a model, propose per source, approve each claim revision, fill a 4-field build form, then export to a fresh absolute directory (or download a ZIP and copy it by hand). Every CLI call boots the whole OTP app and takes the exclusive workspace lock, so CLI and portal cannot run at the same time. Login requires opening the access-token file and pasting it, and sessions die on every restart. Hands-free generation is blocked by `Harnesses.build/1` refusing to compile without approved claims, and by export refusing to write into an existing project directory. The company/setup flow (7 steps, 7-section guide, 7-action run state machine) is the de facto home screen rather than an optional team layer.

| Finding | Evidence |
|---|---|
| `init` is not a wizard: it returns workspace id/root only; `help` lists 47 commands with no grouping and a warning to stop the portal first. | lib/harness_forge/cli.ex:16-17, 221-274 (ownership note 271-272) |
| Every CLI invocation starts the full application (mix run / release eval) and acquires the exclusive SQLite ownership lock; while the portal runs, the CLI fails with workspace_in_use. | bin/harnessforge:19-22; lib/harness_forge/workspaces.ex:41-55 (acquire), 60-85 (init -> {:stop, reason}) |
| Login = open `<workspace>/access-token`, paste into a form; the session epoch is random per boot so restarting the server logs everyone out; max age 12h. | lib/harness_forge/workspaces.ex:67, 76-81, 128-145; lib/harness_forge_web/controllers/session_controller.ex:14-27; session_html.ex ("Restarting HarnessForge ends active sessions"); plugs/operator_session.ex @max_age 43_200; README.md:36-39 |
| Demo path to a package today: 3 mix commands + `demo` + `serve` + token paste + 3 per-claim decisions + 4 build fields + build + typed export directory (or ZIP download) = 8 commands/screens and ~12 inputs/clicks. A real repo adds `connect local`, `sync`, model config, `propose` per source (<=64 KiB each) and `decide` per claim. | README.md:28-43; docs/quickstart.md:50-92; lib/harness_forge_web/live/portal_live.ex:3573-3625 (build form), 3676-3700 (export form), 896-915 (decide); lib/harness_forge/models.ex:164-167 (65_536 byte bound); lib/harness_forge/demo.ex:11-37 |
| Hands-free build is impossible: `Harnesses.build/1` returns :no_approved_claims when there are none, although the schema allows 0 rules (agents minItems 1) and each rule needs evidence or a goal_id. | lib/harness_forge/harnesses.ex:182-206; priv/schemas/harness-v1alpha1.json (rules minItems 0, agents minItems 1); lib/harness_forge/contracts.ex:313-317 |
| Export only writes to a fresh absolute directory under an existing parent; there is no install/merge into an existing project root, so the user copies files manually. | lib/harness_forge/artifacts.ex:62-70, 111-126 (absent(target)), 248-252 (valid_target); lib/harness_forge_web/package_export.ex ("Existing destinations are never replaced") |
| Local import is limited to .md/.markdown/.txt, <=500 files, <=16 MiB, no symlinks; repository code, git history and toolchain are never read. | lib/harness_forge/evidence/local_import.ex:3-6, 8-17, 58-96 |
| Target choice is a manual select plus a free-text runtime version; the registry knows 3 targets and their config paths but has no detection of installed CLIs or repo markers. | lib/harness_forge_web/live/portal_live.ex:3603-3625; lib/harness_forge_web/package_build.ex defaults (opencode/unqualified); lib/harness_forge/adapters/registry.ex:16-41 |
| The team/company flow is heavy: SetupLive has 7 steps, the company guide 7 sections, setup runs 7 explicit actions (prepare/acquire/retrieve/authorize/analyze/retry/new_run), and Home entry goes to /setup. | lib/harness_forge_web/live/setup_live.ex:11-20, 592-599; lib/harness_forge_web/components/company/guide.ex:5-13; lib/harness_forge/company/setup_runs.ex @actions; test/harness_forge_web/setup_entry_test.exs:23-29 |
| Portal lands on the `company` tab among 10 tabs; `/` has no first-run detection; a 'Load synthetic demo' button is shown on most tabs. | lib/harness_forge_web/live/portal_live.ex:9, 37, 163-164, 4086-4095; lib/harness_forge_web/router.ex live routes |
| Background work exists as Oban `Jobs.Operation` with a single finish broadcast on `workspace:<id>`; there is no progress stream, and the Oban queue is default: 1. | lib/harness_forge/jobs/operation.ex:7-31; lib/harness_forge_web/live/portal_live.ex:1437-1449 (enqueue); config/config.exs (queues: [default: 1]) |
| Packaging smoke and tests call `init`, `demo`, `runtimes`, `build`, `export` in a temp workspace; changing `init` semantics must keep them green. | packaging/smoke.sh:14-20, 45-47; test/harness_forge/runtime_targets_test.exs:101-111; test/harness_forge/company_cli_test.exs:13-27 |

### Gaps

- **No single-command entry: there is no `init PATH` that detects, analyzes, generates and installs.** A solo developer needs one command; today the minimum is ~8 commands/screens with per-source and per-claim repetition.
- **No install-into-project operation (export demands a fresh directory).** The harness must land in the repo where Claude Code/Codex/OpenCode read it; manual copying defeats hands-free and breaks re-runs.
- **Generation requires approved claims; zero-rule or goal-only packages cannot be built through `Harnesses.build/1`.** A hands-free baseline (agents/skills/permissions + whatever the engine extracts) must compile with 0 approved claims.
- **No target auto-detection.** Asking 'which agent and which runtime version' is avoidable; the machine knows which CLIs are installed and which marker files exist.
- **CLI and portal are mutually exclusive (one lock, whole-app boot per CLI call).** `init` must work while the portal is open, otherwise the wizard and the visual review cannot coexist.
- **Token paste login and restart-invalidated sessions.** This is the first thing every user hits; for localhost single-user it is pure friction.
- **No remembered projects / no 'update harness' / no drift detection.** A mature harness is regenerated as the repo evolves; re-running must not re-ask questions or clobber local edits.
- **No progress stream for long analysis.** The LiveView wizard's 'auto-analysis with live progress' screen needs stage/percent events, not a single finish flash.
- **Review/approval and the company builder are the default path, not an optional layer.** Governance must be a toggle (team mode) that routes through the existing claims/approval flow without changing the solo path.
- **No non-interactive contract (flags, exit codes, JSON) for CI.** Teams want `harnessforge init --yes --check` in CI; today output is JSON for everything and exit codes are 0/1 only.

### Target design

A new `HarnessForge.Wizard` context owns one pipeline, `detect -> analyze -> generate -> preview -> install`, exposed identically to the CLI (`harnessforge init [PATH]`) and to a 4-screen `WizardLive`. With no flags and no input, `init` resolves PATH to the current git root, detects installed agent CLIs and repo markers to choose targets, runs the analysis entry point (lens 2) and the generation engine (lens 1) behind a `Wizard.Pipeline` behaviour, compiles one artifact per target through the existing `Compiler`/adapters, and installs the files into the project with a per-file conflict policy and a `.harnessforge/installed.json` manifest. A built-in baseline implementation of the pipeline (markers + hard-coded agents/skills/policies, zero or goal-based rules) guarantees a valid package even before the richer engine lands, and the UI always states how many project-specific rules were found. The wizard asks at most three things, all pre-answered: project path (skipped when given or remembered), targets (chips pre-selected by detection; one question only if nothing is detected), and a 'Team mode' toggle defaulting to off. Optional manual instructions are a free-text notes box or `--notes`, stored in `.harnessforge/notes.md` and fed to the generator on every run; the baseline turns notes into goal-based rules so the contract's evidence-or-goal rule holds. Team mode routes the same run through the existing governance: extracted statements become proposed claims with citations, the package is built with `Harnesses.build/1` from approved claims only, and the Review screen shows pending-approval counts with deep links to the existing Review tab, Company builder and release gates. Progress is streamed over PubSub `wizard:<run_id>` from an Oban `Jobs.Wizard` worker so the LiveView survives reconnects and the CLI can follow a run started elsewhere. The CLI starts the application lazily; when the portal already owns the workspace it delegates the run to a loopback control API authenticated with the workspace access token, so CLI and portal coexist. Login for localhost becomes a one-time ticket URL opened by `serve --open`/`init --open` (token file never shown or pasted), the paste form stays as fallback, `HARNESSFORGE_AUTH=token` forces strict mode, and the session epoch persists across restarts. Re-runs are first-class: the wizard home lists remembered projects with Installed / Update available / Drifted status, `harnessforge update` regenerates and shows a diff before writing, and `harnessforge status --check` returns a CI-friendly exit code. The existing portal tabs, SetupLive, CorpusReviewLive and the 40+ CLI commands remain intact under an 'Advanced' grouping.

### Day one after the plan ships

1. `cd my-repo && harnessforge init` -> prints: detected Claude Code + Codex CLI, analyzing (git, toolchain, docs) with a progress line, '11 files generated, 0 conflicts, installed: CLAUDE.md, .claude/settings.json, .claude/agents/*, AGENTS.md, .codex/config.toml', and 'review visually: harnessforge serve --open'.
2. `harnessforge serve --open` -> the browser opens already logged in on /wizard; the home shows one project card 'my-repo · Installed · Claude Code, Codex' with a green status pill.
3. Click 'Review' -> file tree with inline previews, a permissions allow/ask/deny bar, rule and skill counts, 'Project-specific rules: N'; an 'Add notes' box is collapsed; 'Regenerate' re-runs with the notes.
4. Click 'Install update' -> a conflict list (keep/overwrite per file, JSON merge for settings.json) -> done screen with the exact command to start each agent.
5. Weeks later: `harnessforge update` (or the 'Update available' pill) -> diff vs installed files -> install; `harnessforge status --check` in CI exits 3 on drift.
6. A team lead flips 'Team mode' on the project card -> the next run writes proposals instead of installing; teammates approve in the existing Review tab; install unlocks when approvals exist, with Company builder and release gates one click away under Advanced.

### Proposed changes

#### W1 · Wizard pipeline context with progress stream and run/project tables

**Priority** P0 · **Effort** L · **Type** add · **Depends on** none

**What.** Add `HarnessForge.Wizard` (public API: `start_run/2`, `get_run/1`, `list_projects/0`, `remember_project/2`) and `HarnessForge.Wizard.Run` executing stages detect -> analyze -> generate -> preview -> install, broadcasting `{:wizard_progress, run_id, stage, percent, detail}` and `{:wizard_finished, run_id, result}` on PubSub topic `wizard:<run_id>` (plus the existing `workspace:<id>`). Define behaviour `HarnessForge.Wizard.Pipeline` with callbacks `detect(path)`, `analyze(detection, opts, progress_fun)`, `generate(analysis, targets, notes, opts)` so lens 1/2 implementations plug in via config key `config :harness_forge, :wizard_pipeline`. Ship `HarnessForge.Wizard.Baseline` (default): detect = git root, languages/toolchain markers, existing CLAUDE.md/AGENTS.md; generate = the current hard-coded agents/skills/policies from `Harnesses.specification/3` with zero rules, compiled via `Compiler.compile/1` and published via `Artifacts.publish/1` with `spec.metadata.name` = repo basename, provenance tagged origin 'wizard'. Add `Harnesses.build_spec/2` (compile+publish a wizard spec without requiring approved claims; audits `harness.built` with origin). Run work in `HarnessForge.Jobs.Wizard` (Oban worker, new queue `wizard: 1`). Migrations: `wizard_runs` (id, workspace_id, project_id, status, stage, percent, options_json, result_json, error_code, timestamps) and `wizard_projects` (id, workspace_id, path, targets_json, team_mode, notes_ref, last_run_id, last_digest_json, last_installed_at, analysis_fingerprint).

**Where.** new lib/harness_forge/wizard.ex, lib/harness_forge/wizard/{run.ex,pipeline.ex,baseline.ex,records.ex}, lib/harness_forge/jobs/wizard.ex; lib/harness_forge/harnesses.ex (add build_spec/2); config/config.exs (Oban queues add wizard: 1; :wizard_pipeline); new priv/repo/migrations/*_create_wizard_tables.exs; lib/harness_forge/privacy.ex counts list (add both tables)

**Why.** Both the CLI verb and the LiveView need one orchestrator with resumable, observable runs; today the only reusable pattern is a fire-and-forget Oban job with a single finish flash (jobs/operation.ex:18-22), and `Harnesses.build/1` refuses to compile without approved claims (harnesses.ex:182-206).

#### W2 · `harnessforge init [PATH]` one-command flow, plus `update`, `status`, `workspace`

**Priority** P0 · **Effort** M · **Type** change · **Depends on** W1, W4, W5

**What.** Repurpose `init` as the wizard: `init [PATH] [--targets auto|claude_code,codex,opencode] [--yes] [--dry-run] [--out DIR] [--notes TEXT|--notes-file FILE] [--team] [--on-conflict keep|overwrite|diff] [--model none|auto|NAME] [--open] [--demo] [--json]`. Defaults: PATH = git toplevel of cwd (else cwd), targets auto (W5), install into PATH (W4), on-conflict keep, model none (never calls a provider unless configured with consent and `--model auto`), human-readable output with a final file list; `--json` emits the current JSON envelope. Add `update [PATH]` (re-run with remembered options, show diff summary, install), `status [PATH] [--check]` (installed digest, targets, drift; `--check` exits 3 on drift/update available), and move the old `init` output to `workspace` (also `workspace path`). Exit codes: 0 ok, 1 error, 2 pending approvals (team mode), 3 drift/conflicts unresolved in `--yes`. Interactive prompts only when a tty and not `--yes`: at most the targets question. Parse options with `OptionParser` in a new `HarnessForge.CLI.Init`; `CLI.main/1` starts the app lazily (`Application.ensure_all_started/1`) or delegates per W7; `bin/harnessforge` switches to `mix run --no-start`. Update packaging/smoke.sh to call `workspace` where it used `init`, and add `init --demo --dry-run --json` to the smoke.

**Where.** lib/harness_forge/cli.ex (run clauses init/update/status/workspace, help grouping), new lib/harness_forge/cli/init.ex, bin/harnessforge, rel/overlays/bin/harnessforge, packaging/smoke.sh, test/harness_forge/cli_init_test.exs (new)

**Why.** The one-command promise is the core of the lens; `init` currently prints two fields (cli.ex:16-17) and the documented path is 8+ commands (docs/quickstart.md:50-92).

#### W3 · `WizardLive`: four screens with smart defaults, skip everywhere, team toggle

**Priority** P0 · **Effort** L · **Type** add · **Depends on** W1, W4, W5

**What.** Add `HarnessForgeWeb.WizardLive` at `/wizard` (and `/wizard/:project_id`, `/wizard/runs/:run_id`) inside the existing `live_session :operator`. Screen 1 `project`: path input with validation (absolute, directory, git root suggestion), remembered-project cards, 'Use demo project' link, detected target chips (toggle), 'Team mode' toggle (off), one primary button 'Analyze'. Screen 2 `progress`: stage rail detect/import/signals/generate with percent and detail lines from `wizard:<run_id>` PubSub; auto-advances; Cancel. Screen 3 `review`: summary tiles (files, rules found, agents, skills), permission allow/ask/deny bar per target, file tree with `<details>` previews (reuse HarnessLive markup via `HarnessDelivery.preview/1`), diff vs installed when updating, collapsed 'Add notes' textarea (maxlength 16384) + 'Regenerate', 'Skip to install'. Screen 4 `install`: destination (project path default, 'Download ZIP', 'Export to new folder' secondary), conflict list with per-file keep/overwrite and JSON-merge option, 'Install', done state with agent start commands and 'Open project' card. Components: `HarnessForgeWeb.Wizard.{ProjectPicker, ProgressRail, PackageSummary, ConflictList}`. Route `/` -> redirect to `/wizard` when `wizard_projects` is empty or `?view=` is absent and no company records exist; otherwise unchanged PortalLive. Every screen keeps the existing operator auth hooks (`OperatorSession.on_mount/4`).

**Where.** new lib/harness_forge_web/live/wizard_live.ex, lib/harness_forge_web/components/wizard/{project_picker.ex,progress_rail.ex,package_summary.ex,conflict_list.ex}; lib/harness_forge_web/router.ex (live "/wizard", redirect for "/"); assets/css/app.css (wizard rail reusing .harness-journey/.pill tokens); test/harness_forge_web/wizard_live_test.exs (new)

**Why.** The portal currently lands on a 10-tab company home (portal_live.ex:9,37) and the setup flow has 7 steps (setup_live.ex:11-20); the owner asked for a simple guided flow with minimal text and visual status.

#### W4 · `Artifacts.install/3` into an existing project root with conflict policy, manifest and drift

**Priority** P0 · **Effort** M · **Type** add · **Depends on** none

**What.** Add `HarnessForge.Artifacts.install(artifact_or_digest, project_root, opts)` writing artifact files relative to an existing directory: validate root with the same symlink/traversal rules as `valid_target`/`walk_directories`, stage under `<root>/.harnessforge/.stage-*`, per-file policy `on_conflict: :keep | :overwrite | :merge_json` (merge_json allowed only for `.claude/settings.json` and `opencode.json`, deep-merging `permissions` lists), exclusive create for new files, atomic rename per file, and write `<root>/.harnessforge/installed.json` (digests per target, file sha256s, run_id, targets, installed_at, tool_versions). Return `%{installed: [...], kept: [...], overwritten: [...], conflicts: [...]}`. Add `Artifacts.plan_install/3` (dry run: same result without writes) and `Artifacts.drift(project_root)` comparing current file hashes to the manifest (modified/missing/foreign). Keep `export/3` unchanged. Audit `harness.installed` with artifact digests. Exclude `harnessforge.*.json` metadata files from the project install by default (`include_metadata: false`), keeping them in the manifest only.

**Where.** lib/harness_forge/artifacts.ex (install/3, plan_install/3, drift/1), new lib/harness_forge/artifacts/install.ex and lib/harness_forge/artifacts/json_merge.ex; docs/contracts.md (manifest format); test/harness_forge/artifacts_install_test.exs (new)

**Why.** Export refuses existing destinations by design (artifacts.ex:111-126, 248-252); agents read files from the repo root, so a safe merge-install is required for hands-free use and for re-runs.

#### W5 · Target auto-detection and the single targets question

**Priority** P0 · **Effort** S · **Type** add · **Depends on** none

**What.** Add `HarnessForge.Wizard.Targets.detect(project_root)` returning per target `%{installed_cli: bool, cli_version: string|nil, repo_markers: [paths], recommended: bool}` using `System.find_executable/1` for `claude`, `codex`, `opencode` (version read from `--version` with a 2s timeout, no network) and `Adapters.Registry.config_paths/1` plus CLAUDE.md/AGENTS.md markers. Default rule: targets = union of installed CLIs and repo markers; if empty, ask one question (CLI prompt / Screen 1 chips) with default `claude_code,codex,opencode`; `--targets` or saved project settings override. Runtime version: `unqualified` unless the detected CLI version equals the adapter's observed version (2.1.311 / 0.156.0), then that exact version. For multi-target runs, build one artifact per target and reconcile shared paths (`AGENTS.md` for codex and opencode): identical bytes install once; differing bytes are reported as a conflict with 'keep first' default and surfaced in Screen 4. Extend `Registry.list/0` entries with `detected` fields for the portal.

**Where.** new lib/harness_forge/wizard/targets.ex; lib/harness_forge/adapters/registry.ex (detect/1 helper, list/0 fields); used by lib/harness_forge/cli/init.ex and WizardLive screen 1; test/harness_forge/wizard_targets_test.exs (new, executables stubbed via :wizard_which config)

**Why.** The only target UI today is a manual select plus a free-text version field (portal_live.ex:3603-3625); detection removes the question for most users and keeps the build honest about qualified versions.

#### W6 · Localhost auto-login via one-time tickets; sessions survive restarts; strict mode opt-in

**Priority** P1 · **Effort** M · **Type** change · **Depends on** none

**What.** Add `Workspaces.issue_login_ticket/0` (32-byte url-safe nonce, 60s TTL, single use, kept in GenServer state) and `Workspaces.consume_login_ticket/1`; add `GET /login/ticket/:nonce` in `SessionController.ticket/2` that consumes the nonce, creates the operator session exactly like `create/2`, and redirects to `/wizard` (or `redirect_to` within the app). `bin/harnessforge serve --open` and `harnessforge init --open` request a ticket (in-process, or via W7 when delegating) and open `http://127.0.0.1:PORT/login/ticket/<nonce>` with `open`/`xdg-open`; the URL is printed once to the terminal, never logged (add `nonce` to `filter_parameters`). Persist the session epoch to `<workspace>/session-epoch` (0600) so sessions last up to the existing 12h across restarts; `rotate_session_epoch/0` (logout, `harnessforge auth reset`) rewrites it. Config key `HARNESSFORGE_AUTH=token` disables tickets and `--open`; the login page keeps the paste form but demotes it under 'Use the access code instead'. Update README/quickstart wording ('the access code is never placed in a URL; tickets are single-use and expire in 60s').

**Where.** lib/harness_forge/workspaces.ex, lib/harness_forge_web/controllers/session_controller.ex, session_html.ex, lib/harness_forge_web/router.ex, config/runtime.exs (auth_mode, filter_parameters), bin/harnessforge (serve --open), lib/harness_forge/cli/init.ex (--open), README.md:36-39, docs/quickstart.md:57-60, test/harness_forge_web/session_ticket_test.exs (new)

**Why.** Token paste is the first friction every user meets and restart invalidates sessions (workspaces.ex:76-81; session_controller.ex:14-27); tickets keep the same proof-of-file-ownership model for the single-user loopback profile while the token path remains for strict/multi-user setups.

#### W7 · CLI and portal coexistence: portal marker + loopback control API delegation

**Priority** P1 · **Effort** M · **Type** add · **Depends on** W1, W2

**What.** When the Endpoint serves, `Workspaces` writes `<workspace>/portal.json` {port, pid, started_at} (0600) and removes it on terminate. New `HarnessForgeWeb.ControlController` under `/api/control/*` (JSON, loopback only via existing `LocalOrigin`, Bearer auth comparing against `Workspaces.access_token/0` with `Plug.Crypto.secure_compare/2`): `POST /api/control/wizard/runs` (start run with the same options as `init`), `GET /api/control/wizard/runs/:id` (status/progress/result), `POST /api/control/login-ticket` (W6), `GET /api/control/health`. `CLI.main/1` checks `portal.json` + health before starting the app; if the portal owns the workspace it delegates `init/update/status/serve --open` through the API (using `Req`, already a dependency) and streams progress by polling; otherwise it starts the app in-process as today. Document that mutation commands other than these still require stopping the portal.

**Where.** lib/harness_forge/workspaces.ex (portal marker), new lib/harness_forge_web/controllers/control_controller.ex, new lib/harness_forge_web/plugs/control_token.ex, lib/harness_forge_web/router.ex (scope "/api/control"), lib/harness_forge/cli.ex (main/1 delegation), new lib/harness_forge/cli/remote.ex; docs/quickstart.md ownership section

**Why.** The single-owner lock makes `init` fail whenever the portal is running (workspaces.ex:41-55; cli.ex:271-272), which breaks the 'run the command, then review in the browser' story.

#### W8 · Team mode: route the same run through claims, approvals and `Harnesses.build/1`

**Priority** P1 · **Effort** S · **Type** add · **Depends on** W1, W3

**What.** Add `team_mode` to `wizard_projects` and `--team` to the CLI. When on, `Wizard.Run` (a) ensures a local connection + import of the project's docs via `Evidence.connect/1` and `Evidence.import_directory/1`, (b) writes generated rule statements as proposed claims with `Evidence.create_claim/1` using exact citations when the analysis provides byte ranges, else whole-revision citations via `Evidence.citation(rev, 0, byte_size(body))` (same as the portal propose handler), and notes as goal-based claims (`Goals.add_goal/1` + basis goal_id), (c) stops before install with status `awaiting_approval`, and (d) on the next run builds with `Harnesses.build/1` (approved claims only) and installs. Review screen shows 'N proposals awaiting approval' with deep links to `/?view=evidence` and `/setup`; CLI prints the same and exits 2. Solo mode is untouched. Company plans, evaluations and releases stay reachable from the Review screen under 'Governance (advanced)'.

**Where.** lib/harness_forge/wizard/run.ex (team branch), lib/harness_forge/wizard/records.ex, lib/harness_forge/cli/init.ex (--team), lib/harness_forge_web/live/wizard_live.ex (review screen state), reuse lib/harness_forge/evidence.ex, decisions.ex, harnesses.ex; test/harness_forge/wizard_team_mode_test.exs (new)

**Why.** Governance must remain available as an optional layer; the existing approval flow (decisions.ex, portal decide handler 896-915) already enforces exact-revision approval and should be reused, not duplicated.

#### W9 · Optional manual instructions: notes box and `--notes`, persisted in the project

**Priority** P1 · **Effort** S · **Type** add · **Depends on** W1

**What.** Accept notes from `--notes TEXT`, `--notes-file FILE`, or the Review screen textarea (UTF-8, <=16 KiB, no NUL). Store at `<project>/.harnessforge/notes.md` (committable) and mirror the path/hash in `wizard_projects.notes_ref`; every run re-reads the file so edits in the repo flow into regeneration. Pass notes to `Pipeline.generate/4`; the Baseline splits paragraphs into rule statements attached to an auto-created goal 'Operator notes for <repo>' (`Goals.add_goal/1`, owner `Workspaces.operator/0`), satisfying the evidence-or-goal rule; statements containing '@' are rewritten with '(at)' to pass the Claude adapter's static_rules check and a notice is shown. Notes never alter permission policies.

**Where.** lib/harness_forge/wizard/notes.ex (new), lib/harness_forge/wizard/baseline.ex, lib/harness_forge/cli/init.ex, lib/harness_forge_web/live/wizard_live.ex (review screen), docs/wizard.md

**Why.** The owner wants manual instructions to be optional but first-class; the contract requires evidence or a goal per rule (contracts.ex:313-317) and Claude rejects '@' in rules (adapters/claude_code.ex static_rules).

#### W10 · Remembered projects, 'Update harness' and drift status

**Priority** P1 · **Effort** S · **Type** add · **Depends on** W1, W4

**What.** Wizard home (`/wizard`) lists `wizard_projects` as cards with a status pill computed by `Wizard.project_status/1`: Installed (manifest digests match), Update available (new `analysis_fingerprint` or new engine/adapter mapping_version), Drifted (`Artifacts.drift/1` finds modified/missing files), Not installed. One-click 'Update harness' starts a run with saved options and lands on Screen 3 with a diff (per-file added/changed/removed computed from manifest hashes). `harnessforge update` and `status --check` use the same functions. Remove a project card (forget) without touching repo files.

**Where.** lib/harness_forge/wizard.ex (project_status/1, forget_project/1), lib/harness_forge_web/live/wizard_live.ex (home + diff view), lib/harness_forge_web/components/wizard/package_summary.ex (diff), lib/harness_forge/cli.ex (update/status)

**Why.** Sensible re-run behaviour is required by the lens; nothing today remembers a project or compares installed files to a build.

#### W11 · Demote current screens and commands to 'Advanced'; rewrite the entry docs around `init`

**Priority** P2 · **Effort** S · **Type** hide-behind-advanced · **Depends on** W2, W3

**What.** Portal: keep all PortalLive tabs but group the sidebar into Start (Wizard, Projects), Workspace (Sources, Review, Goals, Package, Checks, Releases, Audit, Privacy, Chat) and Team (Company builder `/setup`, Corpus review `/company/corpus`), with Workspace/Team collapsed by default and remembered per browser; remove the 'Load synthetic demo' button from tabs other than Sources and add 'Try the demo project' on the wizard home (uses `Demo.load/0` into a temp project dir). CLI: `help` returns `{"start_here": [init, update, status, serve], "advanced": {...existing groups...}}` and the human `help` prints the same grouping; existing command names/outputs unchanged. Docs: README 'Try it' becomes `harnessforge init` then `serve --open`; add docs/wizard.md (screens, flags, exit codes, manifest, team mode); quickstart keeps the old path under 'Advanced CLI'.

**Where.** lib/harness_forge_web/live/portal_live.ex (nav grouping, demo button condition ~4086-4095), lib/harness_forge/cli.ex (help), README.md:23-49, docs/quickstart.md, new docs/wizard.md, docs/architecture.md (wizard section)

**Why.** The owner asked for the least text and a simple default path; existing flows must remain available but not be the landing experience (portal_live.ex:9,37).

#### W12 · Non-interactive/CI contract and wizard progress telemetry

**Priority** P2 · **Effort** S · **Type** add · **Depends on** W2

**What.** Freeze the machine contract: `init --yes --json` never prompts and emits `{ok, result: {run_id, targets, files, conflicts, installed, pending_approvals}}`; `--dry-run --json` emits the plan only; exit codes 0/1/2/3 as in W2; `status --check` for CI drift gates. Emit `:telemetry` events `[:harness_forge, :wizard, :stage, :stop]` per stage for the existing Telemetry supervisor. Add a documented GitHub Actions snippet (no network, no model) in docs/wizard.md and a smoke step in packaging/smoke.sh running `init --demo --yes --dry-run --json` on the release.

**Where.** lib/harness_forge/cli/init.ex, lib/harness_forge/wizard/run.ex (telemetry), lib/harness_forge_web/telemetry.ex (metrics), docs/wizard.md, packaging/smoke.sh

**Why.** Teams and CI need a stable non-interactive surface; today every command prints JSON with only 0/1 exit codes (cli.ex:5-14).

### Reuse as-is or lightly adapted

- lib/harness_forge/compiler.ex `Compiler.compile/1` + adapters (lib/harness_forge/adapters/{claude_code,codex,opencode}.ex) and `Artifacts.publish/1` (lib/harness_forge/artifacts.ex) as the unchanged deterministic generator behind the wizard.
- lib/harness_forge_web/live/harness_live.ex file-tree/preview markup and `HarnessDelivery.preview/1` (lib/harness_forge_web/harness_delivery.ex:16-50, bounded previews) for the Review screen.
- lib/harness_forge/jobs/operation.ex worker pattern and PubSub topic `workspace:<id>` (jobs/operation.ex:18-22; portal_live.ex:1437-1449 enqueue) as the template for `Jobs.Wizard` and progress broadcasts.
- lib/harness_forge/evidence/local_import.ex (symlink-safe bounded directory read), `Evidence.connect/1`, `Evidence.import_directory/1`, `Evidence.citation/3`, `Evidence.create_claim/1` (evidence.ex:39-56, 84-118, 307-330) and the portal propose handler (portal_live.ex:816-840) for team-mode proposals.
- lib/harness_forge/workspaces.ex secret-file handling and `OperatorSession.new_auth/0` (plugs/operator_session.ex) for ticket login; `Plugs.LocalOrigin` for the loopback-only control API.
- lib/harness_forge_web/package_build.ex (`defaults/0`, `classify/1`, `message/1`) and package_export.ex (`present/3`) for build/export error copy in the wizard.
- lib/harness_forge/harnesses.ex `build/1`, lib/harness_forge/decisions.ex `decide/2`, `/?view=evidence` and lib/harness_forge_web/live/setup_live.ex as the optional team/governance layer.
- assets/css/app.css status visuals: `.pill.*` (44-49), `.panel`/`.context-note` (109-113), `.harness-journey`/`.harness-stage-symbol` (340-383) for the progress rail and status pills.

### Risks

- Multi-target installs collide on shared paths (codex and opencode both emit AGENTS.md; whether their bytes are identical is unverified) and `.claude/settings.json` may already exist with user permissions; the conflict policy and JSON merge must be explicit or the wizard will clobber local config.
- Installing into an existing repo intentionally relaxes the fresh-directory export invariant; W4 must keep symlink/traversal checks, exclusive creates and staging, and never write outside the project root.
- The one-owner workspace lock plus CLI delegation adds a second control path (loopback API with the access token); a race between portal boot and CLI start, or a stale portal.json, must degrade to a clear 'portal starting, retry' error rather than a hang.
- Oban Lite runs `default: 1`; without a separate `wizard` queue a run can sit behind a long sync/propose job and the progress screen will look frozen.
- Until the lens-1 engine and lens-2 extractor land, baseline packages contain the same hard-coded agents/skills/policies with 0 project rules; the UI must say so plainly, otherwise 'hands-free' looks like it did more than it did.
- Changing `init` semantics affects packaging/smoke.sh and release docs; login tickets must stay single-use/short-lived and the README promise about access codes in URLs must be reworded, not silently broken.

### Open questions for the owner

- Should `harnessforge init` write into the repository by default (hands-free) or default to a preview with `--install` required? The plan assumes install-by-default with a printed file list and keep-on-conflict.
- When no agent CLI or marker is detected, should the default be all three targets, Claude Code only, or always ask the one question? The plan assumes ask-once in a tty, all three under `--yes`.
- Is per-project state in `<repo>/.harnessforge/` (installed.json, notes.md; committable and team-shareable) acceptable, or must state stay only in the workspace database?
- Is ticket-based auto-login (single-use, 60s, loopback) acceptable given the README's 'the portal never puts the code in a URL' statement, and should sessions persist across restarts by default?
- May `init` use an already-configured model with existing consent automatically (`--model auto` as default), or must inference stay strictly opt-in per run as the plan assumes?

## 4. Visual-first portal

### Current state

The portal is one 4,125-line LiveView (PortalLive) that renders its own sidebar shell with 10 tabs (5 primary, 5 under a 'More workspace tools' disclosure), plus SetupLive (wizard), HarnessLive (generated files), CorpusReviewLive and three controller pages (/login, /verification, /mcp/access). Status is conveyed almost entirely as sentences and 9px text pills: templates hold roughly 7,000 words of static copy, 516 <p> elements and about 160 <button> elements, with zero <svg>, <progress>, chart or heroicon usage in any LiveView or component. The only quasi-visuals are a 4-tile numeric strip, a 3-step CSS-arrow 'harness journey' list, a flat grid of file links labelled a 'file tree', and text-only diff lists. Styling is a bespoke 432-line CSS file with 123 hard-coded hex colors; Tailwind 4 is imported but utilities appear in 18 of 747 class attributes, daisyUI is a mix dependency that is never loaded, and dark mode is hard-coded off. Live updates exist through PubSub on 'workspace:<id>' (start/finish-grained events) plus a 2-second polling loop that reloads every collection; there are no LiveView streams and no JS hooks.

| Finding | Evidence |
|---|---|
| Information architecture: a single LiveView owns 10 tabs selected by assigns.tab (default 'company'); governance tabs (goals, releases, audit, privacy, chat) sit under a <details> at the same level as the core flow. Labels are inconsistent: tab 'package' is labelled 'Your harness', its heading says 'Build a harness package', the panel says 'Built packages'. | lib/harness_forge_web/live/portal_live.ex:9 (@tabs), :37 (default tab), :2728-2767 (sidebar nav), :2550-2575 (title/1, label/1); lib/harness_forge_web/router.ex:43-49 (5 live routes), :36-41 (controller pages) |
| Text density (static copy only, computed with a tag-stripping script over ~H blocks): portal_live 1,465 words; setup_live 707; harness_live 208; company/corpus_review.ex 1,242; company/assessment.ex 791; company/plan.ex 579; total 7,045 words across web templates. Element counts: 26 <h2>, 64 <h3>, 516 <p>, 165 <button> (portal_live alone: 1 h1, 10 h2, 19 h3, 79 p, 39 button). The Home tab composes CompanyPanel -> Guide + Catalog + Analysis + Plan + Assessment, about 2,850 static words reachable on one screen, mostly inside <details> (corpus_review 11, portal 10, harness_live 8 disclosures). | grep -c over lib/harness_forge_web/live/*.ex and components/**/*.ex; scratchpad script <scratch>/copycount.py (approximate; dynamic strings excluded) |
| No diagram, chart or progress visualization exists in any LiveView or component: 0 <svg>, 0 <progress>, 0 radial/gauge/sparkline/canvas, 0 charting library. The only SVGs in the web layer are in the stock Phoenix welcome page, which is not routed (router maps '/' to PortalLive). | grep -rn '<svg\|<progress\|radial\|chart\|mermaid\|canvas' lib/harness_forge_web assets -> hits only in lib/harness_forge_web/controllers/page_html/home.html.heex; lib/harness_forge_web/router.ex:44 |
| Status is conveyed as prose plus text pills in at least four unrelated vocabularies: ReadinessFacts (unknown/not_started/running/needs_input/complete_for_selected_scope/blocked/cancelled/stale) rendered as a <dl>; PackageReadiness 7 stages (passed/blocked/unavailable/not_assessed) rendered as an <ol> of pills plus reason sentences; Guide task cards with data-saved and strings 'Saved'/'To review'; evaluation outcomes as strings '✓ PASS'/'✕ FAIL'/'⊘ BLOCKED'. Pills and labels are 9px type. | lib/harness_forge_web/components/company/readiness_facts.ex:14-23, :75-90; lib/harness_forge_web/components/package_readiness.ex:5-13, :133-157; lib/harness_forge_web/components/company/guide.ex:735-747, :753-758; lib/harness_forge_web/live/portal_live.ex:2576-2579 (evaluation_status/1); assets/css/app.css:43-44 (.eyebrow 10px, .pill 9px), :60 (.nav-heading 9px), :85 (.metric-label 9px) |
| The closest things to a dashboard are the 4-tile .metrics strip (sources, awaiting decision, approved claims, packages) hidden on the Home and Chat tabs, and the Guide 'next action' button computed from a 7-step completion map. Colored status exists only as 6px .metric-dot circles (amber/green). | lib/harness_forge_web/live/portal_live.ex:2810-2824; lib/harness_forge_web/components/company/guide.ex:51-61 (complete map), :413-474 (next button), :721-747 (counts and task cards); assets/css/app.css:82-89 |
| Pipeline visualization: HarnessLive renders a 3-item 'harness-journey' <ol> whose arrows are CSS ::after content; the sidebar uses Unicode glyphs instead of icons; a .workflow strip is styled in CSS but no template uses it (dead CSS). | lib/harness_forge_web/live/harness_live.ex:350-410; assets/css/app.css:340-392 (.harness-journey), :90-93 (.workflow, no hits for 'workflow' in lib/harness_forge_web templates); lib/harness_forge_web/live/portal_live.ex:4115-4124 (nav_symbol/1) |
| File tree and diff: #harness-file-tree is a flat <ul> grid of anchors (no nesting, no target folder structure); files render as <details><pre> with SHA-256 lines. Package comparison uses Releases.diff/2 (files and rules added/removed/changed by name) rendered as text lines; no side-by-side or per-file diff. | lib/harness_forge_web/live/harness_live.ex:420-444; assets/css/app.css:394-412; lib/harness_forge/releases.ex:104-116; lib/harness_forge_web/components/company/plan.ex:468-500 |
| CSS/Tailwind setup: app.css imports Tailwind 4 with source(none) and only the heroicons plugin; daisyUI v5.5.20 is pinned in mix.exs but never loaded with @plugin, so the daisyUI classes used by core_components.ex (btn, toast, alert, fieldset, table-zebra) have no definitions in app.css (0 matches). Tailwind utility tokens appear in 18 of 747 class attributes; 123 hard-coded hex colors; only 9 :root custom properties. Runtime rendering unverified because priv/static/assets is not built in this checkout. | assets/css/app.css:3-10; mix.exs:61-67; lib/harness_forge_web/components/core_components.ex:65-72, :103, :369; grep -cE '\.btn\b\|\.toast\b\|\.alert\b' assets/css/app.css -> 0 |
| Dark mode is hard-coded off: root layout sets <body data-theme="light"> and <meta name="color-scheme" content="light">; :root has color-scheme: light. Layouts.theme_toggle/1 exists but is referenced only from the unrouted welcome page and from Layouts.app, which no LiveView uses (the :live_view macro sets no layout; live_session sets none). No 'phx:set-theme' listener exists in app.js. | lib/harness_forge_web/components/layouts/root.html.heex:7, :13; assets/css/app.css:10; lib/harness_forge_web/components/layouts.ex:129-158; lib/harness_forge_web.ex:49-55; lib/harness_forge_web/router.ex:43; assets/js/app.js (no set-theme handler) |
| Icons: the heroicons Tailwind plugin is compiled, yet <.icon> / hero-* classes are used 0 times outside core_components.ex and layouts.ex; buttons are text-only with occasional Unicode arrows. | assets/vendor/heroicons.js; lib/harness_forge_web/components/core_components.ex:445-452; grep -rn '<.icon\|hero-' lib/harness_forge_web/live lib/harness_forge_web/components (excluding core/layouts) -> 0 |
| Live updates: PortalLive and HarnessLive subscribe to 'workspace:<id>'. Domain broadcasts are coarse: {:operation_finished, summary} after an Oban job, {:command_approval_requested, run_id}, :operator_session_revoked; the portal also broadcast_from's {:company_changed,_}, :company_cache_reset, :corpus_cache_reset. Every event triggers reload/1, which re-reads 9 collections; evaluations are additionally polled every 2 seconds. No stream/3 usage; 5 start_async call sites; 0 phx-hook. | lib/harness_forge_web/live/portal_live.ex:28-29, :1013-1208, :1464-1500, :1565-1640, :1175-1207; lib/harness_forge_web/live/harness_live.ex:12, :79-103; lib/harness_forge/jobs/operation.ex:18-22; lib/harness_forge/execution/relay.ex:412-416; lib/harness_forge/workspaces.ex:95-99 |
| JS and tests: app.js is 286 lines of form-reset and focus-event listeners with no hooks; there is no package.json or node_modules, so any browser library must be vendored under assets/vendor. The web test suite (35 files, 16,770 lines) contains 542 text-match assertions (=~) and references 419 distinct #id selectors, so copy and id changes are high-blast-radius. | assets/js/app.js:28-241; assets/tsconfig.json comment; test/harness_forge_web/ (wc -l, grep -c '=~', grep -oE '"#[a-z][a-z0-9-]+' \| sort -u \| wc -l); heaviest: corpus_review_component_test.exs (76), company_assessment_presentation_test.exs (42), package_readiness_test.exs (36) |

### Gaps

- **No single 'where am I' view: nothing shows the end-to-end state Sources -> Analysis -> Harness -> Installed; Home is the Company builder with seven task cards and text status behind disclosures.** A hands-free solo developer needs one glance to know whether a harness exists, is fresh, and what happens next; today that requires reading several panels.
- **Four unrelated status vocabularies, all rendered as sentences or 9px pills, with no shared color/shape mapping.** Status badges (fresh/stale/needs-attention) only work if every surface maps onto the same few tokens; otherwise the visual language is inconsistent and untestable.
- **No progress visualization for long operations (capture/sync, analysis, build, evaluation); only start/finish events and a 2s poll exist.** Hands-free generation runs for seconds to minutes; without rings/bars the portal looks frozen and the user cannot tell running from stuck.
- **No maturity or coverage signal for a generated harness: HarnessLive lists files and byte counts, but nothing shows which sections (rules/agents/skills/policies/permissions) are populated versus template defaults.** The known weakness (only rule sentences vary; agents/skills/policies are hard-coded) is invisible in the UI, so users cannot judge quality or see what would improve it.
- **No source-to-rule traceability view: rules carry byte-exact evidence citations, but the UI shows citations one claim at a time and never maps which source fed which rule.** Traceability is the product's core trust story; a source map makes it visible without reading.
- **File tree is a flat link grid; no nesting by target folder (.claude/, .codex/, .opencode/), no per-file change state, and the diff is a text list of names.** Continuous regeneration produces updates; users need to see what changed in the package before installing.
- **No design tokens or dark mode; 123 hard-coded hex colors in page-scoped CSS (.company-*, .corpus-*, .harness-*), daisyUI dependency unused.** Consistent status colors, theming and a maintainable component library are impossible without tokens; dark mode is expected for a developer tool.
- **Navigation mixes the core flow with governance (goals, evaluations, releases, audit, privacy, chat, MCP access, verification) in one 10-tab list plus separate pages.** Governance must be an optional layer; it should live behind an Advanced switch, not compete with Home/Harness/Sources.
- **Icon-first interaction is absent: 165 text buttons, Unicode glyph nav, zero heroicons despite the plugin being compiled.** The owner asked for least text and more visuals; icon buttons with tooltips halve on-screen words while keeping accessibility.
- **Copy has no budget or placement policy; explanatory paragraphs sit inline and tests assert on their wording.** Without a policy and an automated budget check, text density will regrow; without decoupling tests from copy, redesign is blocked.

### Target design

Five screens replace the 10-tab portal: Home (/), Project (/project), Harness (/harnesses/:digest), Sources (/sources) and Advanced (/advanced, the existing PortalLive tabs unchanged) plus Settings (/settings). Home is diagram-first: an inline-SVG pipeline 'Sources -> Analysis -> Harness -> Installed' whose four nodes are live status nodes colored by one shared token set (fresh, stale, running, attention, idle), each showing a count or a progress ring, with one 'Next' icon button computed from the existing Guide next-action logic and a 'completeness' gauge for the current harness. With zero manual input the hands-free engine populates every node automatically; Home shows green nodes, counts and the install state, and no paragraph of text, only labels, tooltips and 'Learn more' links to docs. Governance appears only as optional badges on nodes ('3 awaiting review') and in Advanced when the Settings toggle is on; solo developers never see claims, plans, evaluations or releases unless they opt in. The Harness screen shows a nested file tree grouped by target folder, per-section coverage meters (rules, agents, skills, policies, permissions, hooks: custom versus template), a source map (sources on the left, rules on the right, lines drawn from evidence citations), a diff view against the previous version and icon buttons for Download/Install; integrity and recorded-check details collapse under an Advanced accordion. Sources shows one tile per connector with an icon, a sync progress bar and a status badge, and a single '+' button that opens the existing connect forms in a dialog. All visuals are server-rendered function components with inline SVG (rings, bars, gauge, bipartite map) driven by Tailwind 4 @theme tokens; no JS charting library is added because there is no npm pipeline and the shapes are deterministic. Dark mode follows prefers-color-scheme with a persisted toggle, implemented with tokens redefined under [data-theme=dark]. Live status uses the existing 'workspace:<id>' PubSub topic extended with {:pipeline_progress, stage, payload} events emitted by the engine and jobs, updating node assigns directly and streaming the activity feed, with the 2-second poll kept only as a configurable fallback. A copy policy caps Home at 60 words, Harness at 120, Sources at 80 and Project at 100 and is enforced by a rendering test. Existing components are kept intact inside Advanced (CompanyPanel, PackageReadiness.inspector, CommandApproval.panel, ChatPanel, AccountPanel, SetupLive, CorpusReviewLive).

### Day one after the plan ships

1. Run the one-command start (lens 3) and the browser opens '/': Home shows the pipeline SVG with Sources (1 repo, fresh), Analysis (ring at 40%, running), Harness (idle) and Installed (idle), one 'Generate' icon button and nothing else to read.
2. Within a minute the Analysis node turns green via PubSub, the Harness node fills with 'Claude Code · Codex · OpenCode' badges and the completeness gauge shows 62 with six section meters underneath.
3. Click the Harness node: a nested file tree (CLAUDE.md, .claude/settings.json, .claude/agents/, .claude/skills/) with a preview pane, coverage meters per section, and a source map; hovering a rule highlights the commits and docs that fed it. Press the Install icon button.
4. Click Sources: connector tiles show the local repository synced 100% and GitHub as an idle tile; pressing '+' opens the existing connection form in a dialog.
5. Next week new commits land; Home shows the Harness node with a 'stale' badge and the Installed node 'behind 1 version'; the Harness screen's diff view lists 3 changed files with a per-file diff and an 'Update' button.
6. A team lead opens Settings and switches on 'Review and governance': Home gains a review-queue badge on the Analysis node and the Advanced screen exposes claims review, plans, evaluations, releases and audit, exactly as they exist today.

### Proposed changes

#### P1 · Design tokens, dark mode and CSS cleanup

**Priority** P0 · **Effort** M · **Type** change · **Depends on** none

**What.** Replace the 123 hard-coded hex colors with Tailwind 4 @theme tokens (--color-surface, --color-ink, --color-line, --color-accent, --color-status-fresh/stale/running/attention/idle, spacing and radius scales) and redefine them under [data-theme=dark] and @media (prefers-color-scheme: dark). Remove data-theme="light" and the color-scheme=light meta from root.html.heex; add a 20-line inline theme-boot script and a 'phx:set-theme' listener in app.js that persists to localStorage. Decide daisyUI: either add @plugin "../vendor/daisyui" (vendoring deps/daisyui/packages/bundle) to make core_components.ex classes real, or delete the daisy classes from core_components.ex. Delete dead .workflow CSS and the unrouted page_html/home.html.heex + PageController.

**Where.** assets/css/app.css; lib/harness_forge_web/components/layouts/root.html.heex; assets/js/app.js; lib/harness_forge_web/components/layouts.ex (theme_toggle/1 reused); lib/harness_forge_web/components/core_components.ex; lib/harness_forge_web/controllers/page_controller.ex, page_html.ex, page_html/home.html.heex (remove); mix.exs:61-67 (daisyui dep decision)

**Why.** Every visual component needs shared status colors and theming; the current CSS cannot express them consistently and the daisyUI state is contradictory.

#### P2 · Unified status projection module

**Priority** P0 · **Effort** M · **Type** add · **Depends on** none

**What.** Add HarnessForgeWeb.Status with status/2 mapping every existing vocabulary onto five tokens (:fresh, :stale, :running, :attention, :idle): ReadinessFacts statuses, PackageReadiness stage statuses, Guide task completion, evaluation outcomes (pending/running/passed/failed/blocked/cancelled/interrupted), connection sync_state (active/credential_unavailable/source_access_denied/rate_limited/...), harness verification (eligible/verified/generated), and install state. Add pipeline/1 that takes the already-loaded assigns (connections, sources, claims, approved, artifacts, runs, setup runs) and returns four node structs %{id, label, status, count, progress, detail, href, badges}. Add completeness/1 that scores a harness spec 0-100 from section population (rules count, custom agents/skills vs template defaults, policies, permissions, hooks present) with the breakdown per section.

**Where.** new lib/harness_forge_web/status.ex; reads lib/harness_forge_web/components/company/readiness_facts.ex:14-23, lib/harness_forge_web/components/package_readiness.ex:5-13, lib/harness_forge_web/components/company/guide.ex:51-61, lib/harness_forge/harnesses.ex:302-376 (spec sections); new test test/harness_forge_web/status_test.exs

**Why.** Badges, nodes, rings and the gauge must agree; a single pure projection is testable and lets lens 1/2 data plug in without touching components.

#### P3 · Viz primitive components (inline SVG, no JS)

**Priority** P0 · **Effort** M · **Type** add · **Depends on** P1, P2

**What.** Add HarnessForgeWeb.Viz function components: status_badge/1 (status, label, count, size), progress_ring/1 (value 0-100, size, status, label; SVG circle with stroke-dasharray, animated only when motion is allowed), progress_bar/1 (value, status, label), gauge/1 (0-100 arc with three bands and center number), meter/1 (coverage label, value, max, status), stat_tile/1 (icon, value, label, status), icon_button/1 (heroicon name, sr-only label, tooltip text, optional count, variants primary/secondary/ghost), tooltip/1 (CSS-only via data-tip and :focus-visible), and learn_more/1 (icon link to a docs anchor). All accept a status token from P2 and expose stable ids for tests.

**Where.** new lib/harness_forge_web/components/viz.ex; styles appended to assets/css/app.css using P1 tokens; icons via assets/vendor/heroicons.js and CoreComponents.icon/1; new test test/harness_forge_web/viz_test.exs

**Why.** Server-rendered SVG needs no vendored library, works with LiveView diffs, and covers every shape the design calls for.

#### P4 · Pipeline diagram component with live nodes

**Priority** P0 · **Effort** M · **Type** add · **Depends on** P3

**What.** Add Viz.pipeline/1 rendering an inline SVG with four nodes (Sources, Analysis, Harness, Installed) joined by connectors; each node shows a status-colored ring (progress when running), a count, optional sub-badges (e.g., review queue when governance is enabled), and is a phx-click target navigating to its screen. Assigns: nodes (list from Status.pipeline/1), compact (boolean for the topbar variant), selected (node id). Provide a non-SVG fallback list using the existing .harness-journey styles for screen readers and print.

**Where.** new lib/harness_forge_web/components/pipeline.ex (or inside viz.ex); CSS in assets/css/app.css reusing .harness-journey (app.css:340-392) for the fallback; test test/harness_forge_web/pipeline_component_test.exs

**Why.** The pipeline is the owner's central visual; it replaces the hero paragraph 'Scope -> Sources -> Review -> Your harness -> Checks' with a live diagram.

#### P5 · Home LiveView at '/'

**Priority** P0 · **Effort** L · **Type** add · **Depends on** P2, P3, P4

**What.** Add HarnessForgeWeb.HomeLive mounted at '/', rendering: Viz.pipeline (full size), gauge (completeness of the latest harness), one Next icon button (label and action from Guide.project/1 next), three stat tiles (sources, rules, targets) and an activity feed streamed from Audit.list_events/0 (5 rows, icon per action prefix). Subscribes to 'workspace:<id>' and handles {:pipeline_progress, ...}, {:operation_finished, _}, {:company_changed, _} by recomputing Status.pipeline/1 only. Copy budget 60 words; all explanations as tooltips or learn_more links to docs/quickstart.md and docs/architecture.md anchors. Query params currently handled by PortalLive at '/' (view, setup, company_review, create, return_*) redirect to /advanced with the same query so existing deep links keep working.

**Where.** new lib/harness_forge_web/live/home_live.ex; lib/harness_forge_web/router.ex (live "/" -> HomeLive; live "/advanced" -> PortalLive); reuses lib/harness_forge_web/components/company/guide.ex:17-107 (project/1) and lib/harness_forge_web/live/portal_live.ex:1600-1612 loader list; new test test/harness_forge_web/home_live_test.exs

**Why.** A dedicated small LiveView gives the hands-free user a glanceable dashboard without touching the 4,125-line PortalLive.

#### P6 · Harness screen: file tree, coverage meters, source map, diff view

**Priority** P0 · **Effort** L · **Type** change · **Depends on** P3

**What.** Refactor HarnessLive to a two-column layout with new HarnessForgeWeb.HarnessComponents: file_tree/1 (nested tree built from file paths, grouped by target folder, heroicon per file kind, selected file shown in a preview pane instead of N <details><pre> blocks), coverage_meters/1 (Status.completeness/1 breakdown per section as Viz.meter), source_map/1 (bipartite inline SVG: sources from Evidence.list_sources/0 on the left, rules from spec.rules on the right, lines from rule.evidence[].revision_id to source.latest_revision.id; hover/focus highlights; aggregated 'N more' beyond 40 rules), diff_view/1 (Releases.diff/2 output as added/removed/changed chips plus a per-file unified diff computed with String.myers_difference/2 on HarnessDelivery previews, selectable baseline from Harnesses.list_artifacts/0), and an action bar of icon buttons (Download ZIP, Install/Export, Update). Move 'Integrity and qualification details' and 'recorded checks' into an Advanced accordion; keep existing ids (harness-download, harness-file-tree, harness-proof, harness-recorded-checks) for tests.

**Where.** lib/harness_forge_web/live/harness_live.ex:288-566 (render); new lib/harness_forge_web/components/harness_components.ex; data from lib/harness_forge_web/harness_delivery.ex:15-50, lib/harness_forge/releases.ex:104-116, lib/harness_forge/harnesses.ex:208-209; CSS replacing app.css:338-425; tests test/harness_forge_web/harness_outcome_live_test.exs updated

**Why.** The harness page is where quality, traceability and updates must be visible; today it is a list of <pre> blocks and sentences.

#### P7 · Sources screen with connector tiles and sync progress

**Priority** P1 · **Effort** M · **Type** change · **Depends on** P2, P3

**What.** Extract the connections tab (portal_live.ex:3132-3475) into HarnessForgeWeb.SourcesLive at '/sources': one tile per connection (provider heroicon, name, Viz.progress_bar from sync_complete/sync_state, Viz.status_badge via Status.status/2, 'Sync' icon button), an 'Add source' '+' icon button opening the existing local-directory and remote-provider forms in a <dialog>, and a hidden-by-default error line mapped from connector_error/1. Account/chat connectors stay in Advanced.

**Where.** new lib/harness_forge_web/live/sources_live.ex; move markup from lib/harness_forge_web/live/portal_live.ex:3132-3475 and handlers connect/import/connect_remote/remote_changed; router.ex; CSS replacing .connection-row (app.css:114); tests test/harness_forge_web/coding_connections_test.exs adjusted or duplicated for /sources

**Why.** Sources is the first node of the pipeline; progress and status must be visual, and the forms should not dominate the screen.

#### P8 · Project screen for extracted signals

**Priority** P1 · **Effort** M · **Type** add · **Depends on** P3, P6

**What.** Add HarnessForgeWeb.ProjectLive at '/project' showing detected repository signals as visuals: language/test-runner/CI/convention chips, history stats as horizontal bars (commits, contributors, active paths), goals as cards, and a 'what fed which rule' summary (count of rules per source kind) reusing source_map/1 in compact mode. Reads a signals summary provided by lens 2 (assumed API HarnessForge.Signals.summary/0 returning %{languages, tooling, history, conventions}; unverified, to be aligned with lens 2's contract). Copy budget 100 words.

**Where.** new lib/harness_forge_web/live/project_live.ex; router.ex; reuses lib/harness_forge_web/components/harness_components.ex (source_map/1) and viz.ex; lib/harness_forge/goals.ex:13 (list_goals/0)

**Why.** Users should see what the engine learned about their repository without reading rule text; this screen depends on the lens 2 data contract.

#### P9 · Advanced and Settings: governance behind a switch

**Priority** P0 · **Effort** M · **Type** hide-behind-advanced · **Depends on** P5

**What.** Move PortalLive to '/advanced' unchanged (all 10 tabs, CompanyPanel, PackageReadiness.inspector, CommandApproval.panel, ChatPanel, AccountPanel, verification and MCP access links) and add HarnessForgeWeb.SettingsLive at '/settings' with: Governance layer toggle (persisted via a new workspace setting key :portal_governance, read by Status.pipeline/1 to add review badges and by the shell to show the Advanced item), theme choice, default target runtimes (claude_code, codex, opencode), workspace storage facts (from the privacy tab) and a link to /mcp/access. SetupLive and CorpusReviewLive stay routed and are linked from Advanced only.

**Where.** lib/harness_forge_web/router.ex:43-49; lib/harness_forge_web/live/portal_live.ex (no render changes; route only); new lib/harness_forge_web/live/settings_live.ex; new config key :harness_forge, :portal_governance default false plus a workspace-level setting stored via HarnessForge.Workspaces (new get_setting/put_setting); tests test/harness_forge_web/portal_test.exs updated to live(conn, "/advanced")

**Why.** Keeps every existing governance surface available while making the hands-free path the default.

#### P10 · Pipeline progress events and streams instead of polling

**Priority** P1 · **Effort** M · **Type** add · **Depends on** P4, P5

**What.** Add HarnessForge.Progress with broadcast(stage, %{state, pct, detail}) publishing {:pipeline_progress, stage, payload} on 'workspace:<id>' (stages: :sources, :analysis, :harness, :installed). Emit from Jobs.Operation.perform/1 (start and finish), Evidence.sync/2 (per page), Models.propose/1, Harnesses.build/1 and the hands-free engine's phases (lens 1). HomeLive, HarnessLive and SourcesLive update node assigns directly; the activity feed and sources list use stream/3. Keep the 2-second evaluation poll only when config :harness_forge, :portal_poll_ms is set (default nil).

**Where.** new lib/harness_forge/progress.ex; lib/harness_forge/jobs/operation.ex:7-30; lib/harness_forge/evidence.ex:137; lib/harness_forge/harnesses.ex:182; lib/harness_forge_web/live/home_live.ex, sources_live.ex, harness_live.ex handle_info; lib/harness_forge_web/live/portal_live.ex:29, :1175-1207 (poll behind config); config/config.exs

**Why.** Animated status nodes and rings need stage-level progress; the current operation_finished-plus-reload model cannot show running work.

#### P11 · Copy policy, Copy module and copy-budget test

**Priority** P1 · **Effort** S · **Type** add · **Depends on** P5, P6, P7

**What.** Write docs/portal-copy-policy.md: per-screen word budgets (Home 60, Sources 80, Project 100, Harness 120, Advanced exempt), one sentence per <p>, explanations only in tooltips or learn_more links to docs anchors, labels <= 3 words, no eyebrow/hero paragraphs. Add HarnessForgeWeb.Copy with label/1, tip/1 and learn_more/1 keyed by atom so tests assert keys rather than prose. Add test/harness_forge_web/copy_budget_test.exs rendering Home, Sources, Project and Harness with fixtures and asserting visible word counts via LazyHTML text extraction.

**Where.** new docs/portal-copy-policy.md; new lib/harness_forge_web/copy.ex; new test/harness_forge_web/copy_budget_test.exs; applied in home_live.ex, sources_live.ex, project_live.ex, harness_live.ex

**Why.** Without a budget and an automated check, text density returns; keyed copy also decouples tests from wording.

#### P12 · Icon-first shared shell and navigation

**Priority** P0 · **Effort** M · **Type** change · **Depends on** P1, P4

**What.** Add HarnessForgeWeb.Shell layout component (sidebar + topbar) used by every LiveView via the :live_view macro layout option: five heroicon nav items (Home, Project, Harness, Sources, Advanced shown only when governance is on) with sr-only labels and tooltips, Settings and theme toggle at the bottom, compact pipeline (Viz.pipeline compact) in the topbar on non-Home screens, icon rail below 900px. Replace nav_symbol/1 glyphs and the per-LiveView shells (PortalLive .workspace-shell, HarnessLive/SetupLive bare <main class="content company-builder">).

**Where.** new lib/harness_forge_web/components/shell.ex; lib/harness_forge_web.ex:49-55 (layout: {Shell, :app}); lib/harness_forge_web/live/portal_live.ex:2719-2785 (remove inline shell), :4115-4124 (remove nav_symbol/1); lib/harness_forge_web/live/harness_live.ex:302, lib/harness_forge_web/live/setup_live.ex:1398; CSS .sidebar/.topbar (app.css:52-78) rewritten with tokens

**Why.** One shell gives consistent navigation and status across screens and removes the duplicated, text-heavy sidebars.

### Reuse as-is or lightly adapted

- HarnessForgeWeb.Company.Guide.project/1 and next_action/5 (lib/harness_forge_web/components/company/guide.ex:17-107, :166) supply the Home 'Next' action and the 7-step completion map that becomes node badges.
- HarnessForge.Company.Readiness.for_plan/6 and the ReadinessFacts status/reason vocabularies (lib/harness_forge/company/readiness.ex; lib/harness_forge_web/components/company/readiness_facts.ex:14-60) map directly onto the five status tokens.
- HarnessForgeWeb.PackageReadiness @stages and announcement/1 (lib/harness_forge_web/components/package_readiness.ex:5-13, :212-240) become the release-admission badge inside the Harness Advanced accordion; the inspector itself stays unchanged in /advanced.
- HarnessForgeWeb.HarnessDelivery.preview/1 (lib/harness_forge_web/harness_delivery.ex:15-50) already returns files with path/bytes/sha256/truncated plus a verification map; it feeds the file tree, preview pane and verification badges with no backend change.
- HarnessForge.Releases.diff/2 (lib/harness_forge/releases.ex:104-116) and HarnessForge.Harnesses.list_artifacts/0, get/1 (lib/harness_forge/harnesses.ex:208-209) power the diff view and baseline selector.
- The PubSub topic "workspace:" <> Workspaces.current_id() and existing handlers (lib/harness_forge_web/live/portal_live.ex:28, :1013-1208; lib/harness_forge_web/live/harness_live.ex:12, :79-103) are extended with progress events rather than replaced.
- Layouts.theme_toggle/1 with JS.dispatch("phx:set-theme") (lib/harness_forge_web/components/layouts.ex:129-158) and the heroicons plugin plus CoreComponents.icon/1 (assets/vendor/heroicons.js; lib/harness_forge_web/components/core_components.ex:445-452) are already compiled and only need wiring.
- Existing CSS primitives worth keeping after tokenization: .panel, .pill, .metrics (as stat tiles), .empty-state, .notice, .audit-list and .harness-journey fallback (assets/css/app.css:82-129, :340-392); HarnessForge.Audit.list_events/0 (lib/harness_forge/audit.ex:27-32) feeds the activity stream.

### Risks

- Test blast radius: 35 web test files (16,770 lines) with 542 text assertions and 419 distinct #id selectors; moving PortalLive off '/' or rewording copy breaks many tests. Mitigation: route PortalLive at /advanced with a query-param redirect shim from '/', keep existing ids on refactored components, and introduce keyed copy (P11) before rewording.
- daisyUI ambiguity: the dependency is pinned but never loaded and core_components.ex relies on its classes; loading it changes global element styling (buttons, tables), while removing it means rewriting core_components. Runtime rendering is unverified in this checkout because priv/static/assets is not built. Decide in P1 before any component work.
- No npm pipeline: any charting or diagram library must be vendored under assets/vendor; inline SVG avoids this but caps complexity (bipartite source maps beyond ~40 rules need aggregation, and long file trees need virtualization-free collapsing).
- Live progress depends on producers: until the engine (lens 1) and jobs emit {:pipeline_progress, ...} events, nodes can only show start/finish states from operation_finished and the 2-second poll; rings would be static.
- Score semantics: the codebase explicitly avoids an overall completion or release score (readiness_facts.ex moduledoc; docs/status.md disclaimers). A 'maturity' gauge could be read as qualification; label it 'completeness', derive it only from section population, and keep evaluation/release status in separate badges.
- Accessibility regressions: icon-first buttons and SVG status risk losing meaning for screen readers and color-blind users; every icon needs an sr-only label, every status token needs a shape or text glyph in addition to color, rings must respect the existing prefers-reduced-motion rule (app.css:136), and type must rise from the current 9-10px labels.

### Open questions for the owner

- Is a numeric 'completeness' gauge acceptable given the project's stated position against overall completion or release scores (readiness_facts.ex moduledoc, docs/status.md), or should Home show only per-section meters without a single number?
- daisyUI: load it (gains radial-progress, steps, badge, progress components with no npm) or remove it and the daisy classes in core_components.ex? Both fit the no-Node constraint; the choice shapes P1 and P3.
- Should HomeLive take over '/' immediately (breaking live(conn, "/") assertions in portal tests until updated) or ship first at '/home' with PortalLive still at '/' until the test migration lands?
- Brand alignment: the marketing site (website/styles.css) is dark with neon green #bbff62 and IBM Plex Mono, the portal is light forest green #275e4e with Inter. Should the portal tokens adopt the website palette (dark default) or keep the current light palette with a dark variant?
- For solo developers with governance off, should Home show any review-queue badge at all (e.g., 'N proposed rules awaiting approval'), or must the hands-free path hide claims entirely until the toggle is on?

## 5. Developer experience, distribution and simplification

### Current state

Running the app today means installing the pinned Erlang 28.3.1 / Elixir 1.19.5 toolchain, five mix/bin commands, then pasting an access token copied from a file into the browser; native release archives are built by packaging/build.sh and the CI package job but never published (no release workflow, no tags, 7-day artifact retention). The workspace is owned by exactly one OS process, so the offline CLI cannot run while the portal is open, which rules out hooks or CI driving the generator. The only output path is an immutable export into a fresh, non-existing directory (plus a ZIP download); nothing installs, merges, diffs or updates CLAUDE.md/AGENTS.md/.claude/.codex/opencode.json inside a real project, and nothing records whether an installed harness is stale. The app is 72K LOC with Graphiti (10.7K LOC, Docker+Python), company builder, chat, execution/evaluation, releases, privacy and MCP all started or exposed by default across 10 portal tabs, a 7-step setup flow and ~45 CLI command forms. Documentation is 778 files / 6.8 MB (mostly agent-orchestration evidence) plus a 142 KB PROGRESS.md board, all copied into the release archive, with contradictory status pages, and the product carries two names (Olivium Harness in README/website vs HarnessForge in every module, env var, CLI, login page and package file).

| Finding | Evidence |
|---|---|
| Install path requires the pinned Erlang/Elixir toolchain and five commands; release archives exist only locally or as a 7-day CI artifact, never published. | README.md 'Try the synthetic demo' (mix deps.get, mix assets.setup, mix assets.build, bin/harnessforge demo, bin/harnessforge serve); .tool-versions; packaging/build.sh writes tmp/packages/*.tar.gz; .github/workflows/ci.yml package job `retention-days: 7`; `git tag` returns nothing; no .github/workflows/release.yml; mix.exs has no `releases:` key; no Dockerfile/Homebrew formula in repo. |
| Portal login requires copying a 32-byte access token from a file and pasting it; sessions expire after 12 h. | lib/harness_forge_web/controllers/session_controller.ex:14-26 (secure_compare against Workspaces.access_token()); lib/harness_forge_web/controllers/session_html.ex:40 renders the token file path; lib/harness_forge_web/plugs/operator_session.ex:8 `@max_age 43_200`; README.md 'Open ~/.local/share/harnessforge/default/access-token ... paste the code'. |
| bin/harnessforge is a 25-line sh launcher: `serve` sets PHX_SERVER and execs the release `start` (or `mix phx.server`); every other command boots a fresh BEAM running HarnessForge.CLI.main; there is no open/stop/daemon, no URL printed, no browser launch. | bin/harnessforge (whole file); rel/overlays/bin/harnessforge is a copy made by packaging/build.sh. |
| One owning OS process per workspace: the CLI fails with :workspace_in_use while the portal runs, so hooks/watch/CI cannot drive the generator while the UI is open. | lib/harness_forge/workspaces.ex:42-56 (`PRAGMA busy_timeout=0; BEGIN EXCLUSIVE` on .ownership.sqlite3 -> {:error, :workspace_in_use}); lib/harness_forge/cli.ex:2 moduledoc and :271-272 help text 'Stop the portal before offline mutation commands; a second owner is rejected'. |
| Export is fresh-directory only: an existing destination yields export_conflict; files are staged then renamed; the LiveView tells the user to 'Choose a new directory'. | lib/harness_forge/artifacts.ex:6-7 (moduledoc), :104-117 (export_at stage+rename), :245-256 (valid_target), :324-329 (absent/1 -> export_conflict); lib/harness_forge_web/package_export.ex:28-33; lib/harness_forge_web/live/portal_live.ex:947-952 handle_event "export"; ZIP download at lib/harness_forge_web/router.ex:54. |
| Generated package layout per target plus four metadata JSON files written to the project root (harnessforge.spec/provenance/capabilities/manifest.json). | lib/harness_forge/adapters/claude_code.ex:101-123 (CLAUDE.md, .claude/settings.json, .claude/agents/*.md, .claude/skills/*/SKILL.md); codex.ex:83-92 (AGENTS.md, .codex/config.toml, .codex/agents/*.toml); opencode.ex:94-107 (AGENTS.md, opencode.json, .opencode/agents\|skills); lib/harness_forge/compiler.ex:94-131; lib/harness_forge/adapters/registry.ex:37-39 config_paths/1. |
| The spec hard-codes policies, the single 'implementer' agent and 'reviewed-change' skill; Claude settings default every portable tool to 'ask' and disable bypass mode. | lib/harness_forge/harnesses.ex:302-376 specification/3; lib/harness_forge/adapters/claude_code.ex:287-291 (`Map.get(requested, portable, "ask")`, `disableBypassPermissionsMode`); lib/harness_forge/harnesses/templates.ex (two fixed templates). |
| A build refuses to run without human-approved claims; hands-free generation therefore has no path through the current build entry points. | lib/harness_forge/harnesses.ex:181-205 (`true <- claims != []` else {:error, :no_approved_claims}); AGENTS.md 'Claims are proposed until an explicit decision approves an immutable revision'. |
| No regeneration or staleness machinery exists: no git hooks, no file watcher, no scheduled jobs, no input fingerprint on exported packages. | grep -rn 'post-commit\|post_commit\|post-merge\|watch' lib matches only the Graphiti port watcher (lib/harness_forge/graphiti/runtime.ex:211-901); config/config.exs Oban `plugins: []` (no Cron); `file_system` appears in mix.lock only via phoenix_live_reload (dev); 'stale' in lib refers to evidence/plan revocation (harnesses.ex:231-234), not input drift. |
| Default surface is maximal: 72,014 LOC under lib (graphiti 10,744; web components 9,120; web live 8,270 incl. portal_live.ex 4,125; company 7,613; execution 4,815); 10 tabs, 7 setup steps, ~45 CLI forms; the Python capture scanner and Graphiti runtime start at boot and the code probes for python3/docker. | line counts via find/wc over lib/; lib/harness_forge/application.ex:10-22 (Scanner, Graphiti.Runtime children); lib/harness_forge/evidence/capture/scanner.ex:40 (find_executable python3); lib/harness_forge/graphiti/pipe.ex:18 and lib/harness_forge/execution/command.ex:16,56 (find_executable docker); portal_live.ex:9 (@tabs) and :2728-2765 (nav + 'More workspace tools'); setup_live.ex:11 (@steps); cli.ex:221-273 (help list). |
| Dead/default scaffolding and build-time showcase data remain in the web layer. | lib/harness_forge_web/controllers/page_controller.ex exists but lib/harness_forge_web/router.ex has no PageController route; lib/harness_forge_web/components/layouts.ex:36-60 Layouts.app with phoenixframework.org links, referenced only by its own doc; lib/harness_forge_web/controllers/verification_controller.ex:5-30 compiles priv/showcase/recordings.json into a /verification page. |
| Docs volume, contradictions and dual naming: 778 doc files / 6.8 MB (docs/enhancement-program 625 files / 5.2 MB; docs/ticket-delivery 125 files) plus PROGRESS.md 142,660 bytes, all copied into the release; status pages disagree; the HarnessForge name persists everywhere below the README. | find/du over docs/; packaging/build.sh `cp ... PROGRESS.md ...` and `cp -R docs`; docs/status.md 'Official enhancement progress is 5/50' vs PROGRESS.md 'Historical 50-iteration program — superseded 3 November 2026'; docs/compatibility.md claims a SECRET_KEY_BASE requirement while lib/harness_forge/workspaces.ex generates session-secret; 209 lib files contain 'HarnessForge', 20 distinct HARNESSFORGE_* env names, session_html.ex:20 'Unlock HarnessForge', docs/branding.md 'retain their current names for compatibility'; website/ (728 KB) + .github/workflows/pages.yml in the app repo, deploy blocked per website/README.md; CHANGELOG.md 'This candidate is unpublished'. |

### Gaps

- **No install path without the Erlang/Elixir toolchain; built archives are never published (no release workflow, no tags, no install script, no tap, no image).** A solo developer will not install asdf/mise and compile a Phoenix app to get a CLAUDE.md; day-one adoption is zero until a binary exists.
- **Opening the portal requires copying a token out of a file; `serve` prints nothing and does not open a browser.** On localhost the process and filesystem are already trusted; the copy step is pure friction and the first thing a new user hits.
- **CLI and portal are mutually exclusive (single workspace owner), so no hook, watcher or CI job can regenerate while the UI is open.** Continuous regeneration and a live staleness badge are impossible without a client/server split.
- **Output is a fresh-directory export or ZIP; no install/merge/update/diff into a real repository, and metadata files would land at the project root.** Users must hand-copy files and lose their own CLAUDE.md edits on the next export; the generated harness never becomes part of the project.
- **Nothing records which inputs produced an installed harness or whether they changed since.** Without a fingerprint there is no 'stale' state, no safe auto-update and nothing for the portal to visualise.
- **No regeneration triggers: no git hooks, watch mode or CI template; Oban runs no scheduled jobs.** The owner's goal is a harness that stays mature over the repository's history; a one-shot export decays immediately.
- **No solo/team switch; defaults are maximal governance (human decision per claim, `ask` for every tool, evaluations/releases visible).** Zero-configuration for a solo developer and optional governance for a team need one key with mode-derived defaults, not 40 commands.
- **Everything is on by default: Graphiti/Docker/Python lanes, company builder, chat, execution, privacy, MCP, 10 tabs, 7 setup steps, dead Phoenix scaffolding.** Boot cost, external-tool probes and cognitive load fall on the solo path that needs none of it; the advanced layer must be opt-in.
- **Documentation is 6.8 MB of orchestration evidence shipped in the release, with contradictory status files and a README that is a status report rather than a 1-minute path.** Readers cannot find the three commands that matter; release archives carry agent handoff logs; trust drops when status pages disagree.
- **Two product names across CLI, env vars, modules, login page and package files; marketing site and its workflow live in the app repo; CHANGELOG has no released version.** Install scripts, docs and support all need one stable user-facing name and a versioned release history.

### Target design

Distribution is one `olivium` executable per OS/arch published to GitHub Releases from a tag-triggered workflow built on the existing `mix release` + packaging/build.sh, installed by `curl ... | sh` or `brew install oudaykhaled/tap/olivium`, with a ghcr.io image as the CI/fallback runtime; no Erlang, Node, Python or Docker is needed for the default path. `olivium init` inside a project asks nothing: it detects the git root and existing CLAUDE.md/.claude, AGENTS.md/.codex and opencode.json, writes `.olivium/harness.toml` with the single key `mode = "solo"`, generates the harness (lens 1 engine over lens 2 signals) and installs it in place. Installation is a new `HarnessForge.Installer` that owns only managed regions (`<!-- olivium:begin -->…<!-- olivium:end -->` blocks in CLAUDE.md/AGENTS.md, union-only key merges in settings.json/opencode.json, a managed region in .codex/config.toml, namespaced `olivium-*` agent/skill files) and keeps metadata under `.olivium/`; every touched file is backed up to `.olivium/backup/<ts>/`, writes are temp+rename, and a `.olivium/lock.json` records artifact digest, managed-region hashes and the input fingerprint so user edits are detected and never clobbered. `olivium open` starts the server if needed and opens the browser already unlocked through a single-use, 60-second loopback nonce, so the persistent access code still never appears in a URL. A loopback control socket lets the CLI act as a thin client of the running server, which removes the "stop the portal first" rule and makes hooks, watch mode and CI possible. Freshness is a first-class state (`fresh | stale | conflict | not_installed`) computed from the lock fingerprint, shown as one badge in the portal and returned by `olivium status`. Regeneration runs from `post-commit`/`post-merge` hooks (detached, debounced), `olivium watch`, or a generated GitHub workflow that runs `olivium update --check` and, in team mode, opens a pull request. `mode` is the only required configuration: `solo` derives auto-approval by an audited machine actor, direct install, hooks on and a two-section portal; `team` derives review-required approval, candidate-only install, PR-based CI and the Review/Checks/Audit sections; anything else lives under an optional `[advanced]` table that re-enables company builder, chat, Graphiti, evaluations, releases, privacy UI and MCP exactly as they exist today. Manual instructions layer on top as ordinary text outside managed blocks or as `.olivium/instructions.md`, which the engine includes verbatim. The app shrinks by gating rather than deleting: feature flags decide which supervision children start, which routes answer and which tabs render; dead scaffolding is removed; docs collapse to six pages plus an archive directory excluded from releases; the user-facing name becomes `olivium` while Elixir modules keep their namespace.

### Day one after the plan ships

1. `curl -fsSL https://github.com/oudaykhaled/olivium-harness/releases/latest/download/install.sh | sh` (or `brew install oudaykhaled/tap/olivium`) puts `olivium` on PATH in under a minute; `olivium doctor` prints version, platform and that no toolchain is required.
2. `cd my-project && olivium init` detects the git repo and existing CLAUDE.md/AGENTS.md/opencode.json, writes `.olivium/harness.toml` with `mode = "solo"`, generates the harness, installs managed blocks into CLAUDE.md + .claude/, AGENTS.md + .codex/, opencode.json + .opencode/, installs post-commit/post-merge hooks, and prints a 6-line summary: targets, files touched (+ backup path), status `fresh`.
3. `olivium open` starts the local server if needed and opens the browser already unlocked (single-use nonce); the home screen is one card: Fresh badge, three target icons, 'last regenerated 2 min ago', one 'Regenerate' button.
4. Normal work: each commit or merge regenerates in the background; a user edit inside a managed block flips the badge to `conflict` with the two versions side by side; `olivium update --diff` shows exactly what would change and `olivium update` applies it, backing up first.
5. Team opt-in: `olivium mode team` switches approvals to review-required, writes `.github/workflows/olivium-harness.yml` (`olivium update --check` on push; opens a 'Refresh harness' PR when stale) and reveals Review, Checks and Audit in the portal; company builder, chat, Graphiti and MCP stay behind `[advanced]`.
6. `olivium uninstall` removes managed blocks, owned files and hooks, restoring originals byte-exact from the last backup; `olivium status --json` is what editors and CI read.

### Proposed changes

#### D1 · Publish a per-OS `olivium` binary: release workflow, install script, Homebrew tap, Docker fallback

**Priority** P0 · **Effort** L · **Type** add · **Depends on** none

**What.** Add a tag-triggered release workflow (matrix: macos-14 arm64, macos-13 x86_64, ubuntu-24.04 x86_64, ubuntu-24.04-arm arm64) that runs packaging/build.sh and uploads `olivium-<ver>-<os>-<arch>.tar.gz` + .sha256 to GitHub Releases; add `packaging/install.sh` (detect OS/arch, download, verify sha256, extract to `~/.olivium/versions/<ver>`, symlink `~/.local/bin/olivium`, strip macOS quarantine if unsigned); add `packaging/homebrew/olivium.rb` formula template for a `oudaykhaled/homebrew-tap` repo; add `packaging/Dockerfile` (multi-stage hexpm/elixir -> debian-slim, ENTRYPOINT bin/olivium) pushed to ghcr.io; declare `releases: [olivium: [include_executables_for: [:unix], steps: [:assemble, :tar]]]` in mix.exs; rename the launcher to `bin/olivium` (keep `bin/harnessforge` as a shim for one release); make build.sh bundle only LICENSE/NOTICE/THIRD_PARTY_NOTICES/packaging/licenses, not docs/ or PROGRESS.md. Burrito single-file wrapping is a follow-up once the tar path works (needs Zig at build time; exqlite NIF compatibility unverified).

**Where.** .github/workflows/release.yml (new); packaging/install.sh (new); packaging/Dockerfile (new); packaging/homebrew/olivium.rb (new); mix.exs (`releases:`); bin/olivium (renamed from bin/harnessforge); packaging/build.sh; packaging/README.md; .github/workflows/ci.yml (reuse package job steps)

**Why.** Nothing else matters if a solo developer must compile Elixir; the release machinery already exists locally (mix release, build.sh, smoke.sh) and only needs publishing.

#### D2 · `olivium open`: start server, open browser, no token copy on localhost

**Priority** P0 · **Effort** M · **Type** add · **Depends on** D1

**What.** Add CLI commands `open` and `serve --open`: ensure the server is running (spawn the release as a detached `daemon` if the workspace lock is free, else reuse), mint a single-use login nonce via new `Workspaces.issue_login_nonce/0` (32 random bytes, 60 s TTL, consumed once, distinct from the persistent access token) and launch the browser at `http://127.0.0.1:<port>/login/once/<nonce>` using open/xdg-open. Add route `get "/login/once/:nonce"` -> `SessionController.once/2` which consumes the nonce (secure_compare + expiry) and sets the same session as `create/2`; keep the access-code form as fallback. `serve` prints `Portal: http://localhost:8865` and `olivium stop` stops the daemon. Endpoint remains loopback-only.

**Where.** lib/harness_forge/cli.ex (`open`, `stop`); lib/harness_forge/workspaces.ex (nonce state in the GenServer); lib/harness_forge_web/router.ex; lib/harness_forge_web/controllers/session_controller.ex (`once/2`); bin/olivium (`open`, `daemon`, `stop` via release `daemon`/`stop`); docs/quickstart.md; README.md

**Why.** The token-paste step is the first friction every user hits; a one-shot nonce keeps the 'persistent code never in a URL' invariant while making the portal one command away.

#### D3 · Loopback control socket so the CLI works while the portal runs

**Priority** P0 · **Effort** M · **Type** add · **Depends on** D1

**What.** Add `HarnessForge.Control.Server` (second Bandit/ThousandIsland listener on a Unix domain socket `control.sock`, mode 0600, under the 0700 workspace root; verify ThousandIsland `ip: {:local, path}` support during implementation) that accepts newline-delimited JSON `{"argv": [...]}` and dispatches to the existing pure `HarnessForge.CLI.run/1` inside the owning process (same purge fence and audit). Add `HarnessForge.Control.Client`: when `bin/olivium` runs a command and the socket exists, it starts a BEAM without starting :harness_forge, connects with :gen_tcp `{:local, path}`, forwards argv and prints the reply; when absent, it runs embedded exactly as today. Remove the 'stop the portal first' rule from help/docs.

**Where.** lib/harness_forge/control/server.ex, client.ex, protocol.ex (new); lib/harness_forge/application.ex (child after Endpoint, gated by Features); lib/harness_forge/cli.ex (`main/1` tries Client first); bin/olivium; config/runtime.exs (`control_socket` path); lib/harness_forge/cli.ex:271-272 help text; docs

**Why.** Hooks, watch mode, CI and a live badge all need the CLI to act while the portal owns the workspace; a client/server split preserves the single-owner lock instead of weakening it.

#### D4 · Install into the real project with managed sections, backups and `update --diff`

**Priority** P0 · **Effort** L · **Type** add · **Depends on** D1

**What.** New `HarnessForge.Installer` taking an artifact and a project root (git work tree, or `--project DIR --force-dir`): (1) CLAUDE.md/AGENTS.md: insert or replace one managed block `<!-- olivium:begin managed digest=<spec_digest> -->…<!-- olivium:end -->`, preserving all text outside; create the file with only the block when absent; if the block's hash differs from `.olivium/lock.json`, keep the user's text, write `.olivium/conflicts/<file>` and report `conflict`. (2) `.claude/settings.json`/`opencode.json`: deep-merge only keys recorded as owned in the lock; union permission arrays; never move a user `allow` entry to `ask`; never delete unknown keys. (3) `.codex/config.toml`: managed `# olivium:begin`/`# olivium:end` text region (no TOML dep needed; codex.ex already hand-writes TOML). (4) Agents/skills written under owned namespaced paths `.claude/agents/olivium-*.md`, `.claude/skills/olivium-*/SKILL.md`, `.codex/agents/olivium-*.toml`, `.opencode/...`; owned files absent from the new artifact are removed. (5) Map `harnessforge.spec|provenance|capabilities|manifest.json` to `.olivium/` (artifact bytes unchanged; Installer owns the path mapping via `Registry.install_layout/1`). (6) Back up every touched file to `.olivium/backup/<utc-ts>/` (keep 10), write temp+rename, append `.olivium/backup/` and `.olivium/conflicts/` to the project .gitignore. (7) Write `.olivium/lock.json` {artifact_digest, files: {path: {region_sha256, owned}}, owned_keys, source_fingerprint, installed_at, mode, app_version}. CLI: `olivium install [--target claude|codex|opencode]... [--dry-run]`, `olivium update [--diff|--check]` (unified diff of managed regions; `--check` exits 2 stale / 3 conflict), `olivium uninstall`. Portal: replace the free-text 'fresh directory' export form with 'Install into project' + diff preview; keep `export` under Advanced. `Artifacts.export` stays unchanged.

**Where.** lib/harness_forge/installer.ex + lib/harness_forge/installer/{managed_markdown,json_merge,toml_region,lock,backup,diff}.ex (new); lib/harness_forge/adapters/registry.ex (`install_layout/1`); lib/harness_forge/cli.ex; lib/harness_forge_web/live/portal_live.ex (package tab, handle_event "export" at :947); lib/harness_forge_web/package_export.ex (install/update/conflict copy); test/harness_forge/installer_test.exs (new); docs/install.md

**Why.** A harness that lives only in a fresh export directory never reaches the project; managed regions plus a lock file are the minimum that lets regeneration run repeatedly without destroying user edits.

#### D5 · Freshness model and `olivium status`

**Priority** P0 · **Effort** M · **Type** add · **Depends on** D4

**What.** Add `HarnessForge.Freshness` computing `source_fingerprint = sha256(canonical_json(%{git_head, input_revision_hashes, config_sha256(.olivium/harness.toml), compiler_version, template_version, app_version}))` and comparing it with `.olivium/lock.json` to yield `fresh | stale | conflict | not_installed | error` with reasons (`inputs_changed`, `config_changed`, `generator_upgraded`, `managed_block_edited`, `owned_file_missing`). `olivium status` returns `{state, reasons, installed_at, targets, last_regenerated}` (JSON; `--human` one-liner) replacing today's `elixir/otp/runtime_qualified` payload. Portal: `FreshnessBadge` component (color chip + relative time + Regenerate button) on Home and Your harness, refreshed via PubSub `workspace:<id>` `{:freshness, state}` after every install/refresh; authenticated `/status.json` for editors/status bars.

**Where.** lib/harness_forge/freshness.ex (new); lib/harness_forge/cli.ex (`status` at :19-27); lib/harness_forge_web/components/freshness_badge.ex (new); lib/harness_forge_web/live/portal_live.ex; lib/harness_forge_web/router.ex (`/status.json`); test/harness_forge/freshness_test.exs (new)

**Why.** Staleness is the one status the owner's visual portal must show and the signal every automation (hooks, CI) keys on.

#### D6 · Continuous regeneration: git hooks, watch mode, CI template

**Priority** P1 · **Effort** M · **Type** add · **Depends on** D3, D4, D5

**What.** `olivium hooks install|uninstall` writes `post-commit` and `post-merge` into the effective hooks dir (honour `core.hooksPath`; if a hook exists, append a managed `# olivium:begin/end` block instead of overwriting) that run `olivium refresh --quiet` detached with a 2 s debounce lock (`.olivium/refresh.lock`) and skip under `OLIVIUM_SKIP_HOOK=1`. `olivium refresh` = re-read inputs (lens 2 API) -> regenerate (lens 1) -> solo: `install`; team: write candidate under `.olivium/candidate/` and mark `stale` for review. `olivium watch` runs in the foreground with `file_system` (promote from transitive dev dep to a direct runtime dep in mix.exs; already in mix.lock), ignoring .git, node_modules, _build, deps, .olivium. `olivium ci init` writes `.github/workflows/olivium-harness.yml` from a template: on push to the default branch run `olivium update --check` in the ghcr.io image; solo: commit the refresh with `[skip ci]`; team: open a 'Refresh harness' PR. Ship a `.pre-commit-hooks.yaml` for pre-commit users.

**Where.** lib/harness_forge/hooks.ex (new); lib/harness_forge/watch.ex (new); lib/harness_forge/cli.ex (`hooks`, `refresh`, `watch`, `ci init`); mix.exs (`{:file_system, "~> 1.0"}`); priv/templates/ci/github-olivium-harness.yml (new); .pre-commit-hooks.yaml (new); docs/continuous.md

**Why.** The product goal is a harness that tracks repository history; hooks cover the laptop, CI covers the team, and the badge from D5 covers every case where neither ran.

#### D7 · One configuration key: `mode = "solo" | "team"`

**Priority** P0 · **Effort** S · **Type** add · **Depends on** none

**What.** Add `HarnessForge.Settings` resolving `OLIVIUM_MODE` env > project `.olivium/harness.toml` > user `~/.config/olivium/config.toml` > default `solo` (parse with the small pure-Elixir `toml` hex package; justify per CONTRIBUTING dependency rule). Derived defaults: solo -> `approval: auto` (Decisions recorded with actor `olivium-auto`), `install: auto`, `hooks: true`, `ci: off`, `portal.sections: [home, harness]`; team -> `approval: review`, `install: candidate`, `hooks: true`, `ci: pr`, `portal.sections: [home, sources, review, harness, checks, audit]`, `reviewers: []`. Every derived value can be overridden under `[advanced]` (also toggles `company`, `chat`, `graphiti`, `evaluations`, `releases`, `privacy_ui`, `mcp`). `olivium init` writes the file; `olivium mode team|solo` flips it and reinstalls hooks/CI. Optional manual instructions are plain text outside managed blocks or `.olivium/instructions.md`, surfaced to the engine via `Settings.instructions/0`.

**Where.** lib/harness_forge/settings.ex (new); mix.exs (`:toml`); lib/harness_forge/cli.ex (`init`, `mode`); config/runtime.exs (OLIVIUM_MODE); lib/harness_forge_web/live/portal_live.ex (@tabs at :9 becomes Settings-driven); docs/configuration.md

**Why.** Solo-by-default and team-as-a-layer must be one decision with sane derivations, consumed by the installer, hooks, CI template and portal alike.

#### D8 · Gate advanced/team features at supervision, router, portal and CLI level; remove dead scaffolding

**Priority** P1 · **Effort** M · **Type** hide-behind-advanced · **Depends on** D7

**What.** Add `HarnessForge.Features.enabled?/1` (from Settings/mode) and apply it: application.ex starts `Evidence.Capture.Scanner` (python3) and `Graphiti.Runtime` (docker) only when `graphiti`/`capture_scanner` are enabled; router mounts `/verification`, `/mcp/access`, `/company/corpus`, `/setup/*` behind a plug that 404s when disabled; portal renders only `Settings.portal_sections` (drop the hard-coded 'More workspace tools' details at portal_live.ex:2746-2765); CLI help shows eight core commands (`init open status update diff refresh mode doctor`) and moves the existing ~40 forms under `olivium advanced <company|connect|model|chat|evaluate|releases|backup|restore|purge|mcp> ...` unchanged. Delete unrouted `PageController`/`page_html`, the Phoenix default `Layouts.app` nav, and (once gated) `VerificationController` + priv/showcase.

**Where.** lib/harness_forge/features.ex (new); lib/harness_forge/application.ex:10-22; lib/harness_forge_web/router.ex; lib/harness_forge_web/live/portal_live.ex; lib/harness_forge/cli.ex:221-273; delete lib/harness_forge_web/controllers/page_controller.ex, page_html.ex, page_html/; trim lib/harness_forge_web/components/layouts.ex:36-60; lib/harness_forge_web/controllers/verification_controller.ex

**Why.** The 72K LOC stays available for teams, but the solo path must not boot Docker/Python probes, show ten tabs or forty commands; gating is reversible where deletion is not.

#### D9 · Collapse documentation to a 1-minute README plus six pages; archive orchestration evidence

**Priority** P1 · **Effort** M · **Type** change · **Depends on** D2, D4

**What.** Rewrite README.md to ~60 lines: one paragraph, three commands (install / `olivium init` / `olivium open`), one SVG diagram (repo -> olivium -> CLAUDE.md+.claude / AGENTS.md+.codex / opencode.json), a four-row Solo vs Team table, six links. Docs become install.md, quickstart.md (rewritten), configuration.md (mode + [advanced]), targets.md (merge claude-code-connector.md, codex-connector.md, OpenCode notes), team-mode.md (summaries + links for company builder, chat, execution, privacy, MCP), architecture.md (trimmed). Move to docs/archive/ (kept in git, excluded from releases and nav): PROGRESS.md, docs/enhancement-program/, docs/ticket-delivery/, docs/handoffs/, all *-verification.md and *-coordination.md, github-checkpoint.md, verification.md, compatibility.md, company-builder-contract.md, service-accounts.md, github-account.md, github-repository-pagination.md; fold status.md limits into CHANGELOG 'Known limits'. Replace AGENTS.md orchestration text (references ../harnessforge-plan/) with a 15-line contributor guide for coding agents. Add a markdown link check to ci.yml.

**Where.** README.md; docs/{install,quickstart,configuration,targets,team-mode,architecture}.md; docs/archive/ (new); AGENTS.md; CHANGELOG.md; packaging/build.sh; .github/workflows/ci.yml (link check step)

**Why.** 6.8 MB of agent handoff logs and contradictory status pages hide the product; the README must be the wizard's text twin.

#### D10 · User-facing rename to `olivium` and repo hygiene (modules keep their namespace)

**Priority** P2 · **Effort** M · **Type** change · **Depends on** D1

**What.** Rename only user-facing surfaces: `bin/olivium` launcher and `olivium` release name; `OLIVIUM_*` env vars read first with `HARNESSFORGE_*` fallback and a one-time deprecation warning; default workspace `~/.local/share/olivium/default` with automatic one-time move of the old `harnessforge` directory; login title 'Unlock Olivium Harness'; docs/mcp.md, GLOSSARY.md, CONTRIBUTING.md titles; add `"product" => "olivium-harness"` to the compiler identity while keeping `harnessforge` contract strings and `apiVersion`. Move website/, .github/workflows/pages.yml and .github/scripts/validate-website.py to a separate site repository. Adopt Keep-a-Changelog with a `0.2.0` section for this plan and tag `v0.2.0` to trigger D1. Add a naming table (CLI/env = olivium; Elixir modules = HarnessForge; package contract = harnessforge.*) to CONTRIBUTING.md.

**Where.** bin/olivium; mix.exs; config/runtime.exs; lib/harness_forge/workspaces.ex (root/0 migration); lib/harness_forge_web/controllers/session_html.ex:20; lib/harness_forge/compiler.ex:15-19; docs/mcp.md; GLOSSARY.md; CONTRIBUTING.md; CHANGELOG.md; website/ and .github/workflows/pages.yml (moved out)

**Why.** Install scripts, docs and support need one stable name; a 209-file module rename adds churn without user value and can wait.

#### D11 · `olivium doctor` first-run diagnostics

**Priority** P2 · **Effort** S · **Type** add · **Depends on** D5

**What.** Add `HarnessForge.Doctor` printing version, platform, workspace path and lock owner pid, server/control-socket state, project detection (git root, targets found, managed blocks present), hook and CI template state, freshness, and optional tools labelled 'advanced only' (git, docker, python3, Ollama reachability) with no network calls beyond loopback. JSON and human output; exit 1 on a broken install.

**Where.** lib/harness_forge/doctor.ex (new); lib/harness_forge/cli.ex; docs/install.md (troubleshooting section)

**Why.** Replaces a meaningless `status` payload and gives users and issue reporters one command to paste.

#### D12 · Release smoke and unit tests for the day-one path on every release OS

**Priority** P1 · **Effort** S · **Type** change · **Depends on** D1, D4, D5, D6

**What.** Extend packaging/smoke.sh: create a temp git repo, `olivium init --project <dir> --no-open`, assert `status` = fresh and managed blocks present, edit a Markdown input and `git commit` (hook fires) or run `olivium refresh`, assert `update --check` exit codes, run `olivium uninstall` and compare the restored files byte-exact with the backup. Run it in release.yml on all matrix OSes plus `docker run ghcr.io/.../olivium doctor`. Add unit tests for Installer (managed block insert/replace/conflict, union-only JSON merge, TOML region), Freshness and Hooks using synthetic repos under tmp/, matching the existing synthetic-fixture policy.

**Where.** packaging/smoke.sh; .github/workflows/release.yml; test/harness_forge/installer_test.exs, freshness_test.exs, hooks_test.exs (new); test/support/ (temp git repo helper)

**Why.** Writing into user repositories is the riskiest new behaviour; the existing smoke only proves export to an empty directory.

### Reuse as-is or lightly adapted

- lib/harness_forge/artifacts.ex staged write + atomic rename + path/symlink checks (export_at :104-117, valid_target :245-256, walk_directories :260-290) — reuse for the Installer's temp+rename and backup directory creation; keep Artifacts.export unchanged for 'export a copy'.
- lib/harness_forge/compiler.ex deterministic `files` map and manifest with per-file sha256 (:94-131) — the Installer consumes artifact["files"] and seeds .olivium/lock.json from manifest entries.
- lib/harness_forge/adapters/registry.ex config_paths/1 (:37-39) — extend to install_layout/1 (managed vs owned paths, metadata relocation) rather than adding a new per-target table.
- mix release + packaging/build.sh + packaging/smoke.sh + the ci.yml package job (pinned erlef/setup-beam, ubuntu-24.04) — the release workflow and Docker image build on these as-is.
- lib/harness_forge/workspaces.ex GenServer (secret_file!, access_token, session_epoch, rotate_session_epoch) and lib/harness_forge_web/plugs/operator_session.ex new_auth/0 — extend with the one-time login nonce; no new auth model.
- lib/harness_forge/cli.ex run/1 as a pure argv -> {:ok, map} | {:error, reason} dispatcher — reuse unchanged behind the control socket so every command works in client mode.
- lib/harness_forge_web/package_export.ex present/3 fixed-copy error mapping and Phoenix.PubSub `workspace:<id>` broadcasts (lib/harness_forge/jobs/operation.ex, workspaces.ex) plus HarnessForge.Audit.append/2 — reuse for install/update/conflict messages, freshness pushes and `harness.installed`/`harness.refreshed` audit events.
- lib/harness_forge/demo.ex synthetic fixture loader — reuse as `olivium init --demo` for a zero-source first run and as the smoke fixture.

### Risks

- Native per-OS releases: ERTS + exqlite NIF must be built on each target (Linux glibc vs musl, macOS x86_64 vs arm64); unsigned macOS binaries are quarantined by Gatekeeper, so install.sh must strip quarantine or the owner must sign/notarize; Burrito adds a Zig toolchain and is unverified with this NIF set.
- Writing into user repositories is inherently destructive: a bug in JSON/TOML merging of .claude/settings.json or .codex/config.toml can change tool permissions silently. Mitigations are union-only merges, mandatory backups, `--diff`/`--dry-run`, candidate-only install in team mode and fixture tests (D12).
- Git hooks are per-clone, absent in CI checkouts and some GUI clients, and can slow commits; they must run detached and debounced, and the freshness badge plus the CI check remain the real safety net.
- The control socket is a second local IPC surface: it must be a Unix socket with 0600 under the 0700 workspace root, keep the purge fence and audit semantics of the owning process, and is unavailable on Windows (already unsupported per docs/status.md). ThousandIsland `{:local, path}` support must be confirmed before committing to this design.
- Solo mode's auto-approval by a machine actor changes the project's core trust invariant ('claims are proposed until a human approves'); it must be visibly audited (actor `olivium-auto`), reversible by `mode team`, and depends on the lens-1 engine delivering an approval policy — without it `olivium init` cannot build a package for a repo with no approved claims (harnesses.ex:181-205).
- Archiving docs and renaming user-facing surfaces breaks cross-links in ~156 doc files and the enhancement-program evidence the owner may still value; move instead of delete, add a CI link check, and keep a naming table so the mixed `olivium`/`HarnessForge`/`harnessforge.*` identifiers do not confuse contributors.

### Open questions for the owner

- Distribution channel and signing: GitHub Releases + install.sh + a `oudaykhaled/homebrew-tap` formula (recommended first), Burrito single binaries later? Will macOS builds be signed/notarized with an Apple Developer ID; if not, is stripping quarantine in install.sh acceptable?
- Will the repository become public? Public GitHub Releases, a Homebrew tap, ghcr.io pulls and the Pages site (PROGRESS.md: blocked by plan/private repo) all depend on it.
- Naming depth: rename only user-facing surfaces to `olivium` (CLI, env vars, workspace dir, login page) as proposed, or also rename the Elixir namespace `HarnessForge.*` (209 files) and the frozen contract strings `harnessforge.*.json` / `apiVersion harnessforge.dev/v1alpha1` (which would require a v1alpha2 contract)?
- May website/, docs/enhancement-program/, docs/ticket-delivery/ and PROGRESS.md leave this repository (separate site/history repos), or must they stay in-tree under docs/archive/?
- In solo mode, do you accept packages produced with zero human decisions (auto-approval recorded under actor `olivium-auto`), and should the Graphiti/Docker/Python lanes be excluded from the default build as a separate 'team' release flavour, or merely disabled at runtime?

