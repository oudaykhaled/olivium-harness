# Codex coding-agent connector

HarnessForge exports a deterministic Codex native preview. It writes project
instructions, standalone custom agents and instruction-only skills. It does not
launch a coding session, copy your Codex login, call a model or modify your
personal Codex configuration.

The target is `codex`, version `unqualified` or exactly `0.156.0`. Other version
strings are rejected rather than assumed compatible. The installed macOS CLI
reported `codex-cli 0.156.0` during implementation; a version response alone does
not qualify task execution, instruction discovery or sandbox enforcement.

| Export | Purpose |
| --- | --- |
| `AGENTS.md` | Approved rules, revision identities and an explicit preview notice |
| `.codex/config.toml` | Documented project defaults |
| `.codex/agents/<name>.toml` | One standalone agent with name, description and developer instructions |
| `.agents/skills/<name>/SKILL.md` | Repository skill with quoted metadata and instruction body |

Export names use lowercase letters and digits with single hyphen separators.
Paths cannot traverse the export directory. TOML strings escape quotes,
backslashes, line breaks, C0 and C1 controls; YAML frontmatter quotes descriptions
so embedded delimiters remain data. No hooks, MCP commands, scripts, provider
endpoints or credentials are generated. Existing HarnessForge immutable artifact
hashes and export containment still apply.

The project defaults request `workspace-write`, `on-request` approval, disabled
web search and disabled sandbox network access. Optional
`tool_permissions.bash = "deny"` additionally renders `features.shell_tool = false`.
Optional `network.denied = true` reports its mapping to the network and web-search
defaults. Other control intents remain visibly unsupported; the export never
loosens these defaults in response to an unsupported policy.

Every mapped control is **advisory**. Codex project trust, higher-priority
configuration, parent-session settings, connectors and the host environment can
affect effective permissions. Required controls fail compilation because this
adapter has no qualified enforcement profile. Global turn, timeout and spending
limits are not fabricated. Native preview does not enable managed execution or
release promotion.

Run the adapter checks with:

```sh
mix test test/harness_forge/codex_adapter_test.exs
```

These synthetic tests verify rendering, escaping, scope, determinism and honest
capability reporting. They do not call OpenAI. Any isolated CLI qualification
results belong in the project verification record and must distinguish a config
parse or instruction-discovery check from a real coding task.

The implementation follows official OpenAI documentation for
[project configuration](https://learn.chatgpt.com/docs/config-file/config-basic),
[configuration keys](https://learn.chatgpt.com/docs/config-file/config-reference),
[standalone subagent TOML](https://learn.chatgpt.com/docs/agent-configuration/subagents)
and [repository skills](https://learn.chatgpt.com/docs/build-skills). Documentation
was checked on 2026-10-31. Native-format compatibility remains version-specific.
