# Claude Code native connector

HarnessForge renders a deterministic Claude Code **native preview**. Select runtime
`claude_code` and version `unqualified` or the locally observed exact CLI version
`2.1.311`. Selecting a version does not qualify execution. Managed execution and
promotion remain unavailable until a separate execution backend is qualified.

The adapter extends the existing `RuntimeAdapter` compilation contract. It writes
only `CLAUDE.md`, `.claude/settings.json`, `.claude/agents/<name>.md`, and
`.claude/skills/<name>/SKILL.md`; it does not change an installed CLI or global
configuration. The surrounding compiler owns immutable manifests and provenance.

Portable `tool_permissions.<name>` policies accept `allow`, `ask`, and `deny`.

| Portable name | Claude Code rule |
| --- | --- |
| bash | Bash |
| edit | Edit |
| write | Write |
| read | Read |
| glob | Glob |
| grep | Grep |
| task | Agent |
| skill | Skill |
| webfetch | WebFetch |
| websearch | WebSearch |
| question | AskUserQuestion |

Unspecified listed tools use `ask`. The preview sets the initial mode to `default`
and disables bypass mode. Other tools, inherited settings, workspace trust and
managed settings still affect the CLI. Native approval rules are advisory in
HarnessForge's capability report: they do not establish adversarial filesystem or
network isolation. Every required control is rejected; optional unsupported
controls remain visible in diagnostics. Unknown tool names, duplicate policies
and invalid permission values fail compilation.

Agent `maxTurns` maps the portable turn count to each subagent. Resuming agents,
the main session, tokens and spend are outside that setting. Wall-clock timeout
requires an external backend and is reported unsupported.

Names are limited to 64 lowercase letters/digits separated by single hyphens.
Frontmatter strings use JSON quoting with escaped YAML line separators. Skills
support static instructions only: executable `!`-backtick context expansion is
rejected. Rule statements containing `@` are conservatively rejected because
`CLAUDE.md` can interpret that marker as a host-file import; this includes email
addresses. No hooks, MCP servers, dynamic commands, credential helpers, model
selection or API credentials are generated.

## Verification and limits

Run the focused suite with:

```sh
mix test test/harness_forge/claude_code_adapter_test.exs
```

Tests verify deterministic files, policy categories, required-control rejection,
exact version selection, path/frontmatter injection boundaries and executable
skill/file-import rejection. They do not call an authenticated model or run a
coding task.

The credential-free native probe uses an isolated Docker container, the unmodified
CLI and only project settings. Its startup event identifies the exported agent
and skill, then authentication fails before inference. See
[the verification record](coding-connectors-verification.md) and
`test/native_agents/check.sh` for exact assertions and commands. This checks
discovery, not model-backed behavior or enforcement.

In version 2.1.311, `plugin validate` can return success with empty `contents`
when pointed at project agent/skill directories; that result does not validate
these exports. `claude --version` and `--help` establish version and flags only.
`claude agents --json` lists background sessions, not project definitions.

Model APIs are a separate connector. This renderer never borrows an existing
Claude account session, authenticates, sends content, starts the CLI or spends
tokens. Live inference requires the operator's own configured API credentials
and the application's explicit cloud consent.

The format and boundaries follow the official [memory](https://code.claude.com/docs/en/memory),
[settings](https://code.claude.com/docs/en/settings),
[settings reference](https://code.claude.com/docs/en/settings-reference),
[permissions](https://code.claude.com/docs/en/permissions),
[subagent](https://code.claude.com/docs/en/sub-agents), and
[skill](https://code.claude.com/docs/en/skills) documentation, checked 2026-10-31.

Static skill text and metadata reject both inline `!`-backtick and fenced
shell-context expansion forms, plus all `@` file-reference markers. The
conservative `@` restriction also rejects email addresses; review/phrase guidance
accordingly. Native settings additionally set `disableSkillShellExecution: true`
as a documented runtime defense; the capability report remains advisory and
unqualified. No dynamic snippet, referenced file, hook or MCP server is emitted.
