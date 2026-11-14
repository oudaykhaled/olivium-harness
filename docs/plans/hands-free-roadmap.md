# Hands-free harness roadmap

Date: 2026-11-07 · Baseline: commit `628676e` · Source: five independent assessment agents
(engine, inputs, wizard, portal, developer experience). Their full findings, with file
references, are in [hands-free-assessment-details.md](hands-free-assessment-details.md).
This document merges the five plans into one, resolves where they overlapped or
disagreed, and lists the decisions only the owner can make.

## Goal

Point the tool at a repository and get a mature harness for Claude Code, Codex CLI and
OpenCode with **no questions and no approvals**. Manual instructions are optional and
layer on top. The same tool serves a solo developer (default) and a team (review and
governance switched on). The portal shows state with diagrams, statuses and numbers,
not paragraphs.

## Where the repository is today

Verified by the agents with file references; the numbers were spot-checked.

| Area | Finding | Evidence |
|---|---|---|
| Engine | Deterministic compiler and adapters work, but only rule sentences vary per project. Agents, skills, policies and the review checklist are literal constants. | `lib/harness_forge/harnesses.ex:302-376` |
| Engine | A build needs at least one human-approved claim; there is no hands-free path. | `harnesses.ex:203` returns `:no_approved_claims` |
| Engine | Generated `CLAUDE.md`/`AGENTS.md` is a title, two disclaimers and a flat rule list. No project map, commands, conventions or architecture. | `adapters/claude_code.ex:314-326`, `codex.ex:292-304` |
| Engine | Permissions default to `ask` for every tool; no hooks, no MCP config. | `adapters/claude_code.ex:101-126` |
| Engine | Export only to a fresh directory; no install, merge, diff or update. | `artifacts.ex:327` `export_conflict` |
| Inputs | Nothing reads a local git repository, manifest, CI workflow, CODEOWNERS or existing `CLAUDE.md`. Local import accepts `.md`/`.txt` only. | no `System.cmd`/git usage in `lib/`; `evidence/local_import.ex:6` |
| Wizard | None. `init` prints the workspace id. About eight separate steps lead to a package. CLI and portal cannot run at the same time (one workspace owner). Login is a token pasted from a file; sessions die on restart. | `cli.ex:16-19`, `workspaces.ex` |
| Portal | One 4,125-line LiveView with 10 tabs, ~7,000 words of static copy, 516 `<p>` elements, no SVG, chart, progress bar or icon in use. 123 hard-coded hex colors; Tailwind barely used; daisyUI declared but never loaded; dark mode off; status refreshed by a 2-second poll. | `live/portal_live.ex`, `assets/css/app.css`, `mix.exs` |
| DX | Requires the Erlang/Elixir toolchain. Release archives are built but never published. Everything is on by default (company builder, chat, Graphiti/Docker/Python, evaluation, release gates, MCP). 783 doc files / 6.8 MB plus a 142 KB `PROGRESS.md` ship inside the release. Two product names. | `packaging/`, `.github/workflows/`, `docs/` |

What is worth keeping as the foundation: the pure, byte-deterministic compiler with
verify-by-recompile (`compiler.ex`), content-addressed artifacts with staged atomic
writes (`artifacts.ex`), canonical JSON and schema validation (`contracts.ex`),
byte-exact citations (`models/proposal.ex`), the connectors, the PubSub topic
`workspace:<id>`, and the whole governance layer as an optional mode.

## Target design

```
            ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐
  repo ───▶ │ Detect   │───▶│ Analyze  │───▶│ Generate │───▶│ Install  │
            │ git root │    │ history  │    │ profile  │    │ managed  │
            │ targets  │    │ stack    │    │ blueprint│    │ blocks   │
            │ existing │    │ docs     │    │ overlay  │    │ backups  │
            │ harness  │    │ privacy  │    │ compile  │    │ lock     │
            └──────────┘    └──────────┘    └──────────┘    └──────────┘
                 │               │               │               │
   portal Home shows these four nodes live: status, count, progress ring
```

One pipeline, two front doors, one switch.

- **CLI:** `olivium init` (in a repo, no flags) runs the whole pipeline and installs the
  harness in place. `olivium update`, `status`, `open`, `uninstall` cover the rest.
- **Portal:** Home is the pipeline diagram above. With no project yet, Home is the
  wizard's first screen (pick a folder, targets pre-selected, one button). The
  Analysis, Harness and Installed nodes are the wizard's other screens. Governance
  lives behind **Advanced**, visible only in team mode.
- **Mode:** one key, `mode = "solo" | "team"`, in `.olivium/harness.toml`. Solo derives
  hands-free generation, direct install, format/lint/test hooks and a two-screen portal.
  Team derives review-required approval, candidate-only install, a pull-request CI
  step and the Review/Checks/Audit screens. Everything else is `[advanced]`.
- **Inputs that need no model and no credentials:** git history (commit conventions, hot files,
  ownership, release cadence, co-change), stack and tooling (manifests, build/test/lint/
  format commands, CI, Docker, monorepo layout, formatters), existing instruction files
  (`CLAUDE.md`, `AGENTS.md`, `.cursorrules`, `CONTRIBUTING.md`, ADRs, CODEOWNERS).
  A configured model is used automatically when one is available (Ollama first, then cloud
  providers with stored consent and budgets) and adds cited, suggested rules; without one the
  package is still produced. Remote connectors are optional enrichers.
- **Mature package per target:** sectioned guidance (project map, commands, conventions,
  do/don't, architecture, review checklist, rules, notes), permissions derived from the
  detected stack (`allow` edits and `Bash(mix test:*)`-style project commands, `deny`
  destructive commands and secret reads), format-on-edit and lint-and-test-before-stop hooks
  (each with a timeout), purpose-specific agents
  and skills from a per-stack blueprint, MCP config when declared, provenance and a
  maturity score under `.olivium/`.
- **Manual instructions, optional:** `.olivium/notes.md` with recognised headings
  (`## Commands`, `## Do`, `## Don't`, `## Permissions`, `## Hooks`, `## Notes`) is an
  overlay with precedence over derived facts. Any text a user writes in `CLAUDE.md`
  outside the managed block is preserved as-is.
- **Idempotent and safe:** the same inputs produce the same bytes. The installer owns
  only managed regions and namespaced files, backs up every touched file, never
  overwrites user edits without `--force`, never runs `git commit` or `git push`, and records a lock with the input
  fingerprint so freshness (`fresh | stale | conflict | not_installed`) is a first-class
  state shown on Home and returned by `olivium status`.

## Where the five plans overlapped, and the resolution

The agents worked independently, so several proposed the same thing under different
names. One implementation each:

| Topic | Proposals | Resolution |
|---|---|---|
| Install into a real project | E10 `Artifacts.export` sync mode · W4 `Artifacts.install` with conflict policy and `installed.json` · D4 `HarnessForge.Installer` with managed blocks, union-only JSON merge, backups, `lock.json` | **One `HarnessForge.Installer`** built on D4's managed-region design (safest for existing `CLAUDE.md` content), plus W4's `plan_install` dry run and conflict list and E10's per-file line diff. `Artifacts.export` stays unchanged for "export a copy". |
| Mode and configuration | E5 `generation.mode` config · W8 per-project `team_mode` · D7 `.olivium/harness.toml` `mode` · P9 portal governance toggle | **D7 `HarnessForge.Settings`** is the single source: env > project file > user config > `solo`. The engine, wizard, portal sections and feature gates all read it. |
| Local login without pasting a token | W6 tickets · D2 nonce | Identical; implement once: `GET /login/once/:nonce`, single use, 60 s, loopback only. The access code still never appears in a URL. |
| CLI while the portal runs | W7 loopback HTTP control API with bearer token · D3 Unix domain socket forwarding `argv` to `CLI.run/1` | **D3.** No token handling, every command works in client mode, 0600 socket under the 0700 workspace root. Use `:gen_tcp` with `{:local, path}` directly rather than a second Bandit listener, which avoids the unverified ThousandIsland dependency. |
| Progress events | W1 `wizard:<run_id>` topic · P10 `{:pipeline_progress, stage, payload}` on `workspace:<id>` · D5 `{:freshness, state}` | **One `HarnessForge.Progress`** broadcasting `{:pipeline_progress, stage, payload}` on `workspace:<id>` with `run_id` in the payload; freshness is the payload of the `:installed` stage. The 2-second poll becomes an opt-in fallback. |
| Scores | E9 compile-time maturity rubric · P2 UI-side completeness · D5 freshness | **E9 computes, P2 renders.** One pure rubric written to `.olivium/maturity.json` at compile time; the portal shows per-section completeness meters as a spectrum strip and no headline number, which keeps it apart from evaluation or release qualification. The numeric score stays in the JSON for the CLI and CI. Freshness is a separate state. |
| Analyzer to engine contract | E2 expects a `RepoProfile` · H8 produces `Mapping.harness_inputs/1` · P8 assumes `Signals.summary/0` | `Analyzers.Mapping.profile/1` returns exactly E2's `RepoProfile` shape plus rule candidates; `Analyzers.summary/1` feeds the Project screen. The JSON fixtures in `examples/profiles/` are the contract and are frozen first. |
| Notes file | E4 `HARNESS_NOTES.md` + `harnessforge.overlay.json` · W9 `.harnessforge/notes.md` · D7 `.olivium/instructions.md` | **`.olivium/notes.md`** with E4's recognised headings and precedence rules. |
| Project-side state directory | E9 `.harnessforge/` · D4 `.olivium/` | **`.olivium/`** (provenance, maturity, lock, notes, backups, conflicts), tied to the naming decision below. |
| Home vs wizard | P5 `HomeLive` at `/` · W3 four-screen `WizardLive` at `/wizard` · D2 "one card" home | **Merge.** Home is the pipeline diagram; its empty state is the wizard's project screen, and the nodes are the wizard's progress, review and install screens. No separate wizard app. |
| Hands-free approvals | E5 rules carry `origin = derived` and bypass claims · D7 auto-approve claims under a machine actor `olivium-auto` | **E5.** Solo mode never creates claims or decisions; derived rules carry a fingerprint and source pointer and are audited as `harness.generated`. Team mode turns the same candidates into proposed claims for the existing Decisions flow. The invariant becomes: a rule marked `approved_claim` was approved by a human. |
| Interim baseline | W1 ships a `Wizard.Baseline` so the wizard works before the engine lands | Keep only as a development stepping stone; it must display "0 project-specific rules". Do not ship the wizard publicly on the baseline. |

## Roadmap

Phases are dependency-ordered. Ids point to the full change descriptions in the details
file. Effort is the agents' S/M/L. Phases 1 and 3 can run in parallel once Phase 0 has
frozen the contracts; Phase 4's distribution item (D1) depends on nothing and can start
any time.

### Phase 0 · Decisions and contracts (2 S, 6 M)

Freeze the interfaces the other phases build on. The `olivium` name applies to everything
new from here on (`.olivium/`, `olivium:` markers, `OLIVIUM_*`); renaming the existing
launcher and environment variables is D10 in Phase 4.

| Id | Change | Effort |
|---|---|---|
| D7 | `HarnessForge.Settings`: `mode = solo \| team`, derived defaults, `[advanced]` table | S |
| E1 | Spec `v1alpha2`: project, guidance sections, hooks, mcp, generation, rule origin, agent tools, command permissions. v1alpha1 rendering frozen behind an `apiVersion` branch so stored artifacts keep verifying | M |
| E2 | `Generation.Profile` (the RepoProfile contract) with fixtures in `examples/profiles/` | M |
| H1 | Safe git command boundary: allow-listed subcommands, cleared environment, timeouts, output caps, `git_unavailable` degradation | M |
| H2 | Signals data model, JSON schema, `repository_analyses` table, privacy inventory and audit registration | M |
| P1 | Tailwind 4 `@theme` tokens replacing 123 hex colors, dark mode, daisyUI decision, remove dead Phoenix scaffolding | M |
| P2 | `HarnessForgeWeb.Status`: five status tokens (`fresh stale running attention idle`) mapped from every existing vocabulary; `pipeline/1` node structs | M |
| P10a | `HarnessForge.Progress` broadcast module (consumers come in Phase 3) | S |

### Phase 1 · Hands-free engine (2 S, 10 M, 6 L)

The core value: a mature package from a repository with no input.

| Id | Change | Effort |
|---|---|---|
| H3 | Git history miner: commit conventions, hot files, fix/revert hot spots, ownership, branches, release cadence, co-change clusters, incremental aggregates | L |
| H4 | Stack and tooling detector over `git ls-files`: languages, manifests, build/test/lint/format commands, CI, containers, monorepo layout, test frameworks, formatters, env file names, tool versions | L |
| H5 | Existing instruction and docs lifter: `CLAUDE.md`, `AGENTS.md`, `.cursorrules`, `CONTRIBUTING.md`, ADRs, CODEOWNERS → evidence revisions and cited rule candidates | M |
| H6 | Privacy guard: secret scanning and redaction, `.env` policy, pseudonymous authors, `.gitignore` honoured, `.olivium/analyzer.json` overrides | M |
| H7 | `repository` provider, `Analyzers.Repository.analyze/2` orchestrator, `signals.json`/`signals.md` revisions, incremental re-analysis with full recompute on history rewrite | L |
| H8 | Confidence scoring (auto ≥ 70, suggested 40–69, observed < 40) and `Mapping.profile/1` to the engine | M |
| H9 | CLI `analyze PATH`, `analyze signals\|diff\|explain`, job action `analyze` | S |
| H11 | Model summary pass (`repository_summary` purpose), on by default whenever a configured model is available: Ollama first, then cloud providers with stored consent and the budget ledger; byte-cited rules with origin `model`; the derived package is still produced when no model is available | M |
| E3 | Data-driven blueprints in `priv/blueprints/` (base → per-stack → team layer): agents, skills, hooks, policies, guidance sections with `{{commands.*}}` placeholders; replaces the literals in `harnesses.ex:342-373`. Default hooks: format on edit, lint and tests before stop, each with a timeout and skipped when the profile has no such command | L |
| E4 | Overlay: `.olivium/notes.md` and `overlay.json` with precedence overlay > approved claims > derived > blueprint | M |
| E5 | `HarnessForge.Generation.generate/1` and `plan/1`: profile → blueprint → (reviewed only) claims → overlay → spec → compile → publish + audit. `Harnesses.eligible/1` only re-checks `approved_claim` rules | L |
| E6 | Claude Code adapter v2: sectioned `CLAUDE.md`, `settings.json` allow/ask/deny with `Bash(<cmd>:*)` and `Read(./.env)` rules, `PostToolUse`/`Stop` hooks, `.mcp.json`, agent `tools:` | L |
| E7 | Codex adapter v2: sectioned `AGENTS.md`, `config.toml` with `mcp_servers`, policy-driven approval and sandbox, hooks as a checklist with `unsupported_control` diagnostics | M |
| E8 | OpenCode adapter v2: permission patterns, agent tool maps, mcp, sectioned `AGENTS.md`, new `docs/opencode-connector.md` | M |
| E9 | Compiler v2 layout under `.olivium/`, versioned identity, compile-time `Maturity.score/2` with per-dimension pass/partial/missing and fix text | M |
| E11 | CLI `generate`/`--plan` (folded into `init` in Phase 2) | S |
| E12 | Golden-file, determinism and idempotence tests; `docs/mature-package.md` | M |
| H12 | Synthetic fixture repositories (conventional Elixir, Node monorepo, Python solo, Rust workspace, secrets trap, plain directory, 6,000-commit history) and the analyzer test suite | M |

### Phase 2 · Install and one-command init (4 S, 4 M, 2 L)

| Id | Change | Effort |
|---|---|---|
| D4 + W4 + E10 | `HarnessForge.Installer`: managed `<!-- olivium:begin/end -->` blocks in `CLAUDE.md`/`AGENTS.md`, union-only merge of `.claude/settings.json` and `opencode.json`, managed region in `.codex/config.toml`, namespaced `olivium-*` agent and skill files, backups under `.olivium/backup/`, `.olivium/lock.json`, dry run, conflict list, per-file line diff | L |
| W1 | `HarnessForge.Wizard` run context: detect → analyze → generate → preview → install as an Oban job on its own queue, `wizard_runs`/`wizard_projects` tables, progress via `Progress` | L |
| D5 | `HarnessForge.Freshness`: input fingerprint vs lock → `fresh \| stale \| conflict \| not_installed`, `olivium status [--json]`, `/status.json` | M |
| W2 | `init [PATH]` with `--targets --yes --dry-run --notes --team --on-conflict --open --json`; `update`, `status --check`, `uninstall`; exit codes 0/1/2/3; `workspace` takes over the old `init` output | M |
| W5 | Target auto-detection from installed CLIs (`claude`, `codex`, `opencode`) and repo markers; one question only when nothing is detected | S |
| W6 / D2 | Login nonce `GET /login/once/:nonce`; `serve --open` and `init --open`; session epoch persisted across restarts; `HARNESSFORGE_AUTH=token` strict mode | M |
| D3 | Control socket so the CLI acts as a thin client of a running portal; removes the "stop the portal first" rule | M |
| W9 | Notes: `--notes`, `--notes-file`, portal textarea → `.olivium/notes.md`, read on every run | S |
| W10 | Remembered projects with status pills (Installed, Update available, Drifted, Not installed), one-click update with diff | S |
| W12 | Non-interactive contract for CI (`init --yes --json`, `status --check`), telemetry events, smoke step | S |

### Phase 3 · Visual portal (1 S, 7 M, 2 L)

| Id | Change | Effort |
|---|---|---|
| P3 | `HarnessForgeWeb.Viz` primitives, inline SVG, no JS library: `status_badge`, `progress_ring`, `progress_bar`, `meter` (spectrum strip), `stat_tile`, `icon_button`, `tooltip`, `learn_more` | M |
| P4 | `Viz.pipeline/1`: four live nodes with rings, counts, badges; compact topbar variant; screen-reader fallback list | M |
| P5 + W3 | `HomeLive` at `/`: pipeline diagram, per-section completeness meters as a spectrum strip (no single score), one Next button, three stat tiles, activity stream. Empty state = project picker with detected target chips and the Team toggle; Analysis node = progress rail; Harness node = review; Installed node = install with conflict list. Copy budget 60 words | L |
| P6 | Harness screen: nested file tree by target folder with preview pane, coverage meters per section, source map (sources → rules drawn from citations), diff view against the previous version, icon action bar; integrity details under an Advanced accordion | L |
| P7 | Sources screen: one tile per connector with icon, sync progress bar, status badge, `+` opens the existing connect forms in a dialog | M |
| P8 | Project screen: stack chips, history bars, conventions, goals, "what fed which rule" summary from `Analyzers.summary/1` | M |
| P12 | Icon-first `Shell` layout used by every LiveView: five nav items, settings and theme toggle, compact pipeline in the topbar, icon rail below 900 px | M |
| P9 | `PortalLive` moves unchanged to `/advanced` (deep links from `/` redirect with their query); `SettingsLive` with the governance switch, theme, default targets | M |
| P10b | Home, Harness and Sources consume `pipeline_progress` events and LiveView streams; the poll stays behind a config key | M |
| P11 | Copy policy with per-screen word budgets enforced by a rendering test; keyed copy so tests assert keys, not prose | S |

### Phase 4 · Distribution, continuity, team mode, cleanup (4 S, 5 M, 1 L)

| Id | Change | Effort |
|---|---|---|
| D1 | Tag-triggered release workflow for macOS arm64/x86_64 and Linux x86_64/arm64, `packaging/install.sh`, Homebrew formula template, `ghcr.io` image; release bundles exclude `docs/` and `PROGRESS.md` | L |
| D6 | Continuous regeneration: `post-commit`/`post-merge` hooks (debounced, detached, managed block if a hook exists; they regenerate files and never commit), `olivium watch`, `olivium ci init` writing a check-only GitHub workflow (`update --check` fails the run when stale; opening a pull request is an explicit opt-in, nothing is pushed by default); `.pre-commit-hooks.yaml` | M |
| D8 | `HarnessForge.Features`: gate supervision children (capture scanner, Graphiti), routes, portal sections and CLI help by mode; `olivium advanced <group> ...` keeps every existing command unchanged | M |
| W8 | Team mode wiring: candidates → proposed claims with citations, run stops at `awaiting_approval` (exit 2), next run builds from approved claims via `Harnesses.build/1` | S |
| W11 | Demote current screens and commands to Advanced; README "Try it" becomes `init` then `open`; `docs/wizard.md` | S |
| D9 | Documentation collapses to a 60-line README and six pages (`install`, `quickstart`, `configuration`, `targets`, `team-mode`, `architecture`); markdown link check in CI. The evidence material already moved to `docs/archive/` on 2026-11-07 and release bundles exclude it | M |
| D10 | User-facing rename to `olivium` (launcher, env vars with `HARNESSFORGE_*` fallback, workspace directory with one-time move, login title); Elixir namespace and `harnessforge.*` contract strings unchanged; website moves to its own repository | M |
| D11 | `olivium doctor` | S |
| D12 | Release smoke on every OS: temp repo → `init` → `status` fresh → commit triggers refresh → `update --check` codes → `uninstall` restores bytes | S |
| H10 | Optional enrichers from already-synced GitHub/Jira/Slack/Confluence revisions, shown only in team mode | M |

## Contracts between workstreams

Freeze these in Phase 0; disagreement found late is the main rework risk the agents named.

1. **RepoProfile** (`Generation.Profile`, E2): `name, languages[], frameworks[], package_managers[], commands{install, build, test, test_single, lint, format, typecheck, run}, layout[{path, purpose}], conventions[], ci[], existing_harness, rule_candidates[{text, confidence, bucket, citations}]`. Produced by `Analyzers.Mapping.profile/1`. Fixtures: `examples/profiles/*.json`. Commands are plain argv strings, no shell metacharacters; they are never executed to verify.
2. **Signals document** (H2): `priv/schemas/repository-signals-v1.json`; every signal carries `key, value, confidence, bucket, detector, evidence[]`.
3. **Spec v1alpha2** (E1): `priv/schemas/harness-v1alpha2.json`; rule `origin ∈ approved_claim | derived | overlay`.
4. **Progress events**: `{:pipeline_progress, stage ∈ :sources | :analysis | :harness | :installed, %{run_id, state, pct, detail}}` on `workspace:<id>`.
5. **Status tokens**: `fresh | stale | running | attention | idle` (P2) for every badge, ring and node; freshness states map onto them.
6. **Project-side layout**: `.olivium/{harness.toml, notes.md, lock.json, spec.json, provenance.json, capabilities.json, manifest.json, maturity.json, backup/, conflicts/}`; `backup/` and `conflicts/` are added to the project `.gitignore`.
7. **Maturity payload** (E9): `{score 0-100, level seed | basic | solid | mature, dimensions[{id, status pass | partial | missing, why, fix}]}`.

## Decisions taken by the owner (2026-11-07)

1. **Name.** The product is **Olivium Harness**. Everything user-facing is `olivium`: the CLI, `OLIVIUM_*` environment variables (with `HARNESSFORGE_*` fallback for one release), the `.olivium/` project directory, `olivium:` managed-block markers and the login page. The Elixir namespace `HarnessForge` and the frozen `harnessforge.*` contract strings stay.
2. **Files, never git.** `olivium init` writes the harness into the local project (managed blocks, backups, printed file list), because hands-free is impossible otherwise. Nothing in the tool ever runs `git commit` or `git push`: hooks only regenerate files, the CI template is check-only, and opening a pull request is an explicit opt-in. The same rule applies to anyone implementing this plan in this repository: changes stay in the working tree until the owner commits them.
3. **Solo permissions.** Allow `Edit`, `Write`, `Read`, `Grep`, `Glob` and every detected project command (`Bash(mix test:*)` and similar); deny destructive commands and secret reads. Team mode restores stricter defaults and `disableBypassPermissionsMode`.
4. **Hooks.** Both: format on edit, and lint plus tests before stop, each with a timeout and skipped when the profile has no such command.
5. **Completeness.** Per-section meters rendered as a spectrum strip; no single headline number on Home. The numeric score stays in `.olivium/maturity.json` for the CLI and CI.
6. **UI.** The owner does not like the current UI/UX, so Phase 3 is a replacement, not a restyle: new shell, new screens, design tokens, dark mode, inline-SVG visuals. daisyUI is loaded from the vendored bundle (the Phoenix 1.8 default, no npm) for base components; `PortalLive` survives only under `/advanced`.
7. **Model use.** Auto-use. When a configured model is available the engine uses it without asking: Ollama first, then cloud providers with stored consent and the existing budget ledger. Model output enters the package as cited rules with origin `model`; the derived package is still produced when no model is available. H11 therefore sits in Phase 1.
8. **Public repository.** Yes. GitHub Releases, a Homebrew tap, `ghcr.io` and the Pages site can proceed (D1). macOS signing is still open; until then `install.sh` strips quarantine.
9. **Archive.** Done on 2026-11-07: `PROGRESS.md`, `docs/enhancement-program/`, `docs/ticket-delivery/`, `docs/handoffs/`, the `*-coordination.md` and `*-verification.md` pages, `verification.md` and `github-checkpoint.md` moved to `docs/archive/` with relative links rewritten; `packaging/build.sh` excludes the archive from release bundles. Reference pages (`compatibility`, `service-accounts`, `github-account`, `github-repository-pagination`, `company-builder-contract`) stay until the README rewrite in D9.
10. **Dependencies.** `toml` and `file_system` approved; a YAML parser may be added if regex extraction of CI files proves insufficient. Each still gets the reason, lockfile update and license review that `CONTRIBUTING.md` requires.

## Unverified items to check before freezing golden files

The agents worked offline and could not confirm these; each is a small check, not a design risk.

- Current native syntax for Claude Code hooks (`PostToolUse`, `Stop`), permission rules (`Bash(cmd:*)`, `Read(path)`) and `.mcp.json`; Codex `mcp_servers` and gated hooks; OpenCode per-command bash permission objects. Check against the pinned versions the adapters accept (Claude 2.1.311, Codex 0.156.0, OpenCode 1.x) or decide to bump them.
- Whether the Codex and OpenCode `AGENTS.md` outputs are byte-identical when both targets are installed in one repo (the installer's shared-path reconciliation depends on it).
- `:gen_tcp` `{:local, path}` on the supported platforms for the control socket.
- daisyUI rendering at runtime (`priv/static/assets` is not built in this checkout).
- `exqlite` NIF compatibility with a single-file Burrito build (the tar release path does not need it).

## Risks the agents agreed on

- **Writing into user repositories.** A merge bug in `settings.json` or `config.toml` could change permissions silently. Mitigations: union-only merges, mandatory backups, `--dry-run` and `--diff`, candidate-only install in team mode, byte-exact fixture tests.
- **Stored artifact invalidation.** `Artifacts.read_at` verifies by recompiling; any change to v1alpha1 rendering breaks every existing artifact. Mitigation: branch on `apiVersion`, lock v1alpha1 output with the existing fixture tests.
- **Heuristic signals as rules.** Regex-parsed commands can be wrong and habits can be mis-read as conventions. Mitigations: confidence buckets, only `auto` signals enter hands-free output, lifted human instructions win conflicts, commands are never executed, `.olivium/analyzer.json` overrides.
- **Test blast radius in the portal.** 35 web test files with 542 text assertions and 419 id selectors. Mitigations: `PortalLive` keeps rendering unchanged at `/advanced`, refactored components keep their ids, keyed copy lands before rewording.
- **Hooks on the developer's machine.** A slow or wrong command degrades every edit. Mitigations: commands only from the validated profile, format-on-edit as the sole default, timeouts.
- **Privacy of mined history.** Commit subjects, emails and committed fixtures can leak. Mitigations are heuristic (pseudonymous authors, subject-only storage, secret scan, allow-listed reads) and must be reported visibly, never assumed complete.
