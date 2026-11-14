defmodule HarnessForge.Adapters.ClaudeCode do
  @moduledoc """
  Deterministic Claude Code native preview renderer. This adapter does not start
  the CLI, authenticate, execute tools or establish an isolation boundary.

  The format follows current official documentation and the observed 2.1.311
  CLI. An exact version or `unqualified` requests a preview, not qualification.
  """
  @behaviour HarnessForge.Contracts.RuntimeAdapter

  alias HarnessForge.Adapters.ClaudeCode.{Guard, Hooks, Locator, OutputStyle, Rewrite}
  alias HarnessForge.Contracts
  alias HarnessForge.Contracts.Error
  alias HarnessForge.Generation.{Guidance, Native}

  @mapping_version "claude-code-2.1.311-docs-v1"
  @observed_version "2.1.311"
  @tools %{
    "bash" => "Bash",
    "edit" => "Edit",
    "glob" => "Glob",
    "grep" => "Grep",
    "question" => "AskUserQuestion",
    "read" => "Read",
    "skill" => "Skill",
    "task" => "Agent",
    "webfetch" => "WebFetch",
    "websearch" => "WebSearch",
    "write" => "Write"
  }
  @sources [
    "https://code.claude.com/docs/en/memory",
    "https://code.claude.com/docs/en/settings",
    "https://code.claude.com/docs/en/settings-reference",
    "https://code.claude.com/docs/en/permissions",
    "https://code.claude.com/docs/en/sub-agents",
    "https://code.claude.com/docs/en/skills"
  ]
  @v2_mapping_version "claude-code-docs-v3"
  @v2_documented_version "2.1.319"
  @v2_sources @sources ++
                [
                  "https://code.claude.com/docs/en/hooks",
                  "https://code.claude.com/docs/en/tools-reference"
                ]
  @settings_schema "https://json.schemastore.org/claude-code-settings.json"
  @guidance_report ".olivium/guidance-provenance.json"
  @guarded_tools "Bash|Read|Edit|Write|MultiEdit|NotebookEdit|Grep|Glob"
  @guard_timeout 10
  # Claude Code 2.1.311 tools that none of the 570 recorded tool calls in 96 benchmark
  # runs used. A bare deny rule removes a tool from every request (contract section 5).
  # `ToolSearch` is never denied: it leaves a placeholder tool behind and keeps MCP
  # servers a user adds reachable. `Skill` and `Workflow` go together, because denying
  # `Skill` alone makes the `Workflow` description inline the skill text (+3,169
  # tokens per request, measured).
  @deny_tools ~w(CronCreate CronDelete CronList EnterWorktree ExitWorktree ListAgents Monitor NotebookEdit ReportFindings ScheduleWakeup SendMessage Skill Task TaskStop Workflow)
  # Claude Code 2.1.311's built-in subagents, listed under the Agent tool while it is kept.
  @builtin_agents ~w(Explore general-purpose statusline-setup)
  @context_profiles ~w(lean standard lean-ai lean-x)
  @learned_file ".olivium/learned.json"
  # The two lean-x hook files (contract: lane H renders both through `Hooks.lean_x/1`).
  @shaper_path ".claude/hooks/olivium-shape.sh"
  @lean_x_learned_keys ~w(learned learning locator rewrites)
  @native_report ".olivium/native-provenance.json"
  # The adapter's hard caps for generated items: the generator stays within 200 B and
  # 2,048 B (blueprint `native.limits`).
  @native_description_bytes 200
  @native_body_bytes 4096

  @spec identity() :: map()
  def identity do
    %{
      "name" => "claude_code",
      "mapping_version" => @mapping_version,
      "qualification" => "unverified",
      "observed_cli_version" => @observed_version,
      "documentation" => @sources
    }
  end

  @impl true
  def probe(_config) do
    {:ok, Map.merge(identity(), %{"available" => false, "reason" => "runtime_unqualified"})}
  end

  @impl true
  def capabilities(harness, _config) do
    spec = harness["spec"]

    {:ok,
     Enum.map(spec["policies"], &policy_capability/1) ++
       [
         capability(
           "execution.max_turns",
           false,
           spec["execution"]["max_turns"],
           "advisory",
           "claude_code.agent.maxTurns",
           "Subagent turns only; resumption, the main session, tokens and cost are not bounded."
         ),
         capability(
           "execution.timeout_seconds",
           false,
           spec["execution"]["timeout_seconds"],
           "unsupported",
           "none",
           "A wall-clock timeout requires a qualified external execution backend."
         )
       ]}
  end

  @impl true
  def validate_intent(harness, config) do
    spec = harness["spec"]

    with :ok <- runtime_format(spec["runtime"]),
         :ok <- mode(config),
         :ok <- native_names(spec),
         :ok <- static_rules(spec["rules"]),
         :ok <- static_skills(spec["skills"]),
         :ok <- permission_values(spec["policies"]),
         {:ok, report} <- capabilities(harness, config),
         :ok <- required_controls(report) do
      {:ok, %{"capabilities" => report, "diagnostics" => diagnostics(report)}}
    end
  end

  @impl true
  def compile(harness, config) do
    with {:ok, intent} <- validate_intent(harness, config) do
      spec = harness["spec"]

      agents =
        Map.new(spec["agents"], fn agent ->
          {".claude/agents/#{agent["name"]}.md",
           agent_markdown(agent, spec["execution"]["max_turns"])}
        end)

      skills =
        Map.new(spec["skills"], fn skill ->
          {".claude/skills/#{skill["name"]}/SKILL.md", skill_markdown(skill)}
        end)

      settings = %{
        "permissions" => permissions(spec["policies"]),
        "disableSkillShellExecution" => true
      }

      files =
        agents
        |> Map.merge(skills)
        |> Map.merge(%{
          "CLAUDE.md" => guidance(harness),
          ".claude/settings.json" => Contracts.canonical_json(settings) <> "\n"
        })

      {:ok, Map.put(intent, "files", files)}
    end
  end

  @impl true
  def identity_v2 do
    %{
      "name" => "claude_code",
      "mapping_version" => @v2_mapping_version,
      "qualification" => "unverified",
      "documented_cli_version" => @v2_documented_version,
      "documentation" => @v2_sources
    }
  end

  @doc """
  Render a validated v1alpha2 spec. `CLAUDE.md` stays inside the guidance budget and
  what it withheld is reported in `#{@guidance_report}`. Hook scripts run only commands
  the spec declares, which the schema restricts to words without shell metacharacters;
  see `Hooks`. The `spec.context` profile adds only settings keys measured to shrink
  every request on Claude Code 2.1.311.
  The PreToolUse guard only refuses: it runs `awk` over its JSON input and `realpath`
  on the paths it names, reads no file except the project's own `package.json` (as data,
  to see whether a package `npx` would run is a bin the project provides) and never
  approves a call; its hook command runs it only while its SHA-256 is the generated
  one; see `Guard` and `guard_command/1`.

  The `lean-x` profile writes the `lean` settings plus two PreToolUse hooks (the guard,
  then the Bash output shaper, both from `Hooks.lean_x/1`) and the fixed output style
  `OutputStyle`; it writes no `CLAUDE.md` and no other hook.
  """
  @impl true
  def compile_v2(harness, config) do
    with {:ok, intent} <- validate_intent_v2(harness, config) do
      if lean_x?(harness["spec"]),
        do: compile_lean_x(harness["spec"], intent),
        else: compile_with_guidance(harness, intent)
    end
  end

  defp compile_with_guidance(harness, intent) do
    spec = harness["spec"]
    {claude_md, report} = Guidance.render(harness)

    data = Hooks.data_files(spec)

    files =
      native_entries_v2(spec)
      |> Map.merge(Hooks.scripts(spec))
      |> Map.merge(data)
      |> Map.merge(guard_script(spec))
      |> Map.merge(learned_files(spec, data))
      |> Map.merge(%{
        "CLAUDE.md" => claude_md,
        ".claude/settings.json" => Contracts.canonical_json(settings_v2(spec)) <> "\n",
        @guidance_report => Contracts.canonical_json(report) <> "\n"
      })

    {:ok,
     intent
     |> Map.put("files", files)
     |> Map.update!(
       "diagnostics",
       &(&1 ++ guidance_diagnostics(report) ++ settings_diagnostics())
     )}
  end

  # lean-x: the lean settings, the guard and the Bash output shaper (both PreToolUse,
  # from `Hooks.lean_x/1`) and the output style. No CLAUDE.md, no SessionStart,
  # UserPromptSubmit or Stop hook, and no hook data file: nothing else reaches a request.
  defp compile_lean_x(spec, intent) do
    with {:ok, hooks, hook_files} <- lean_x_hooks(spec) do
      settings =
        spec
        |> base_settings_v2()
        |> Map.put("hooks", hooks)
        |> Map.put("outputStyle", OutputStyle.name())

      files =
        native_entries_v2(spec)
        |> Map.merge(hook_files)
        |> Map.merge(%{
          OutputStyle.path() => OutputStyle.content(),
          ".claude/settings.json" => Contracts.canonical_json(settings) <> "\n"
        })

      {:ok,
       intent
       |> Map.put("files", files)
       |> Map.update!("diagnostics", &(&1 ++ lean_x_diagnostics(spec) ++ settings_diagnostics()))}
    end
  end

  defp lean_x?(spec), do: get_in(spec, ["context", "profile"]) == "lean-x"

  # Lane H's interface, checked here: only PreToolUse entries, and only the guard and the
  # shaper as files. Anything else is refused, never dropped or repaired.
  defp lean_x_hooks(spec) do
    case Hooks.lean_x(spec) do
      {:ok, %{"settings_hooks" => hooks, "files" => files}}
      when is_map(hooks) and is_list(files) ->
        with :ok <- lean_x_events(hooks),
             {:ok, by_path} <- lean_x_files(files) do
          {:ok, hooks, by_path}
        end

      {:error, %{"code" => code, "message" => message}}
      when is_binary(code) and is_binary(message) ->
        error(code, message)

      _ ->
        error("invalid_runtime_output", "The lean-x hooks have an unexpected shape")
    end
  end

  defp lean_x_events(hooks) do
    if Map.keys(hooks) == ["PreToolUse"] and is_list(hooks["PreToolUse"]) and
         hooks["PreToolUse"] != [],
       do: :ok,
       else:
         error(
           "invalid_runtime_output",
           "The lean-x profile renders only PreToolUse hooks",
           Enum.sort(Map.keys(hooks))
         )
  end

  defp lean_x_files(files) do
    allowed = [Guard.path(), @shaper_path]

    by_path =
      for %{"path" => path, "content" => content} <- files,
          path in allowed and is_binary(content),
          into: %{},
          do: {path, content}

    if map_size(by_path) == length(files) and Map.has_key?(by_path, @shaper_path),
      do: {:ok, by_path},
      else:
        error(
          "invalid_runtime_output",
          "The lean-x hook files must be the shaper and at most the guard, once each",
          Enum.map(files, &if(is_map(&1), do: &1["path"], else: nil))
        )
  end

  defp lean_x_diagnostics(spec) do
    rules = length(spec["rules"] || [])

    [
      %{
        "code" => "claude_md_not_rendered",
        "severity" => "info",
        "message" =>
          "The lean-x profile writes no CLAUDE.md. The project rules found in the repository (#{rules}) stay in .olivium/spec.json and are not sent to the model."
      },
      %{
        "code" => "bash_output_shaped",
        "severity" => "info",
        "message" =>
          "#{@shaper_path} shortens what the model reads from a Bash call: a line over 400 bytes keeps its first 400, and a test command's output over 4,000 bytes keeps its first 1,200 and last 2,800 bytes. Each cut is marked [olivium: cut ...] and the full output stays in a temporary file named in the marker. Test commands run in the foreground with a 600 s timeout."
      }
    ]
  end

  # These limits come from Claude Code itself and no generated file can remove them,
  # so they are reported wherever the package is shown.
  defp settings_diagnostics do
    [
      %{
        "code" => "workspace_trust_required",
        "severity" => "warning",
        "message" =>
          "Claude Code ignores permissions.allow in .claude/settings.json until the folder is trusted. Accept the trust prompt once by running claude in the folder, or pass --settings .claude/settings.json to an unattended claude -p run."
      },
      %{
        "code" => "allowed_programs_unrestricted",
        "severity" => "warning",
        "message" =>
          "The allow list lets the detected toolchain (for example python3, uv run, node, npx) and sed, awk, find and xargs start without a prompt. The interpreters and runners execute arbitrary code, which can read, write or delete any file the OS user can and run any command, including one a deny rule names; sed, awk and find can write files and start commands too. Such a program can also write .claude/settings.local.json, which Claude Code reloads during the session: from then on it allows what that file lists, unless a deny rule names it. Claude Code checks only the command line, and the guard only pattern-matches it. Run unattended sessions in a container or sandbox."
      },
      %{
        "code" => "secret_deny_is_partial",
        "severity" => "info",
        "message" =>
          "Secret files are covered by Edit deny rules and by the PreToolUse guard #{Guard.path()}, which pattern-matches each tool call's text, follows links with realpath and expands unquoted wildcards such as dir/* in the project. It does not stop grep -r over a directory holding a secret, a file list piped to another command (find . | xargs cat), a link or copy made in the same command, or a program the agent runs. It is a guard against accidents, not a sandbox. Without realpath in /usr/bin or /bin the guard does not follow links."
      },
      %{
        "code" => "registry_access",
        "severity" => "info",
        "message" =>
          "The project's own toolchain still reaches its package registry: the install command, uv run syncing the environment, a script that downloads. The guard refuses only commands that download a package the project does not declare: npx, bunx or npm exec of a package missing from node_modules or with --yes, pnpm/yarn dlx, uvx, uv tool, pipx, uv run --with, and pip, uv or npm installs or downloads that name a package."
      },
      %{
        "code" => "approval_still_required",
        "severity" => "info",
        "message" =>
          "Claude Code 2.1.311 asks before shell it cannot check statically, whatever the allow rules say, for example a cd followed by a write, .. after cd, a ( ) group, $( ), escaped spaces and environment prefixes such as PYTHONPATH=. The guard never approves anything, so these still ask, and an unattended claude -p run refuses them; the agent sees the refusal and can retry without the cd or prefix."
      },
      %{
        "code" => "guard_missing_fails_open",
        "severity" => "info",
        "message" =>
          "The hook runs #{Guard.path()} only while its SHA-256 matches the one in .claude/settings.json. If the file is missing or changed, or cannot be checked (no sha256sum or shasum in /usr/bin or /bin), the hook does not run it; if it fails (no awk, say), the hook reports that. Either way the hook prints a one-line warning and exits 0, so the session keeps working under Claude Code's own rules alone and the guard's refusals are gone. The guard refuses git stash -u and the usual ways of removing or overwriting .claude (rm, mv, cp, ln, sed -i, sed w, sort -o, uniq, awk print >, redirects, Edit, Write) so an agent does not remove it by accident; a program such as python3 can still change or delete it. To change what the guard refuses, change the spec and generate again."
      }
    ]
  end

  defp validate_intent_v2(harness, config) do
    spec = harness["spec"]

    with :ok <- runtime_format(spec["runtime"]),
         :ok <- mode(config),
         :ok <- native_names(spec),
         :ok <- static_skills_v2(spec["skills"]),
         :ok <- permission_values(spec["policies"]),
         :ok <- context(spec),
         :ok <- native_items(spec),
         :ok <- lean_x_spec(spec),
         :ok <- Hooks.validate(spec),
         :ok <- Locator.validate(spec),
         :ok <- Rewrite.validate(spec),
         :ok <- locator_hook(spec),
         {:ok, base} <- capabilities(harness, config),
         report =
           base ++
             Enum.map(spec["hooks"], &hook_capability/1) ++
             guard_capability(spec) ++ rewrite_capability(spec) ++ shaper_capability(spec),
         :ok <- required_controls(report) do
      {:ok, %{"capabilities" => report, "diagnostics" => diagnostics(report)}}
    end
  end

  defp hook_capability(hook) do
    capability(
      "hooks." <> hook["id"],
      false,
      Hooks.requested(hook),
      "advisory",
      "claude_code.hooks",
      "Runs in the local Claude Code process with the user's permissions; not an isolation boundary."
    )
  end

  # The locator hook needs the index it reads, and a rendered locator needs its hook.
  defp locator_hook(spec) do
    hook? = Enum.any?(spec["hooks"] || [], &(&1["event"] == "prompt_submit"))
    rendered? = get_in(spec, ["locator", "rendered"]) == true

    if hook? == rendered?,
      do: :ok,
      else:
        error(
          "invalid_runtime_intent",
          "The locator hook is rendered exactly when spec.locator.rendered is true"
        )
  end

  # lean-x renders exactly its own hooks: a spec that also asks for others, or carries
  # learned parts, is refused rather than partly rendered.
  defp lean_x_spec(spec) do
    cond do
      not lean_x?(spec) ->
        :ok

      (spec["hooks"] || []) != [] ->
        error(
          "invalid_runtime_intent",
          "The lean-x profile renders only the guard and the Bash output shaper; spec.hooks must be empty"
        )

      Enum.any?(@lean_x_learned_keys, &(not is_nil(spec[&1]))) ->
        error(
          "invalid_runtime_intent",
          "The lean-x profile has no learned parts (learned, learning, locator, rewrites)"
        )

      true ->
        :ok
    end
  end

  defp shaper_capability(spec) do
    if lean_x?(spec) do
      [
        capability(
          "hooks.olivium-shape",
          false,
          @shaper_path,
          "advisory",
          "claude_code.hooks",
          "A PreToolUse Bash hook that runs the command unchanged in the same shell and then shortens what the model reads: a line over 400 bytes keeps its first 400 bytes, and a test command's output over 4,000 bytes keeps its first 1,200 and last 2,800 bytes. Each cut is marked [olivium: cut ...] and the full output stays in a private temporary file named in the marker. Test commands get a 600 s timeout and run in the foreground. Commands that start background jobs (&, nohup, disown, setsid), set a trap, replace the shell with exec or end in a backslash, calls already sent to the background that are not tests, and commands over 64 KiB run as written. It never approves or refuses a call; Claude Code's rules and the guard still decide. When it cannot run, it says so in one line and the command runs unshaped."
        )
      ]
    else
      []
    end
  end

  defp rewrite_capability(spec) do
    if Rewrite.render(spec) do
      [
        capability(
          "hooks.olivium-rewrite",
          false,
          Rewrite.path(),
          "advisory",
          "claude_code.hooks",
          "A PreToolUse Bash hook that replaces the start of a command with a form verified in Docker when the bundle was learned (a missing tool, a wrong runner, quiet flags) and keeps the rest byte for byte. It never approves or refuses a call; Claude Code's rules and the guard still decide. The hook command runs it only while its SHA-256 matches the generated one."
        )
      ]
    else
      []
    end
  end

  defp guard_capability(spec) do
    if Guard.render(spec) do
      [
        capability(
          "hooks.olivium-guard",
          false,
          Guard.path(),
          "advisory",
          "claude_code.hooks",
          "A PreToolUse hook that only refuses: calls that name a secret file (directly, through a link or by a wildcard), a path outside the project (scratch files in /tmp are allowed), a recursive or bulk delete, a branch deletion, a package download, a denied command behind a wrapper, or a change that removes, overwrites or stashes .claude. It never approves a call. The hook command sets PATH to /usr/bin:/bin, runs the guard file only while its SHA-256 matches the generated one, and passes on only the guard's exact refusal line, so the hook cannot make Claude Code allow a call it would not allow without it, as long as /bin/sh and the programs in /usr/bin and /bin are the system's own and no other process can write to the hook's output. It pattern-matches the call's text and looks up links and wildcards on disk: a guard against accidents, not a sandbox. A program the agent runs can still open, write or delete any file the user can, Claude Code's settings files included."
        )
      ]
    else
      []
    end
  end

  # Commands may legitimately contain `@` (`pnpm --filter @acme/web test`) and are
  # always rendered inside code spans, where Claude Code does not expand imports.
  defp static_skills_v2(skills) do
    unsafe? =
      Enum.any?(skills, fn skill ->
        Enum.any?(Map.take(skill, ~w(name description instructions)), fn {_key, value} ->
          String.contains?(value, "!`") or
            Regex.match?(~r/(?:`{3,}|~{3,})[ \t]*!/, value) or
            not Guidance.import_safe?(value)
        end)
      end)

    if unsafe?,
      do:
        error(
          "invalid_runtime_intent",
          "Dynamic shell and file-import expansion in skills is unsupported"
        ),
      else: :ok
  end

  defp native_entries_v2(spec) do
    turns = native_turns(spec)

    agents =
      Map.new(spec["agents"], fn agent ->
        {".claude/agents/#{agent["name"]}.md",
         agent_markdown_v2(agent, Map.get(turns, agent["name"], spec["execution"]["max_turns"]))}
      end)

    skills =
      Map.new(spec["skills"], fn skill ->
        {".claude/skills/#{skill["name"]}/SKILL.md", skill_markdown(skill)}
      end)

    agents
    |> Map.merge(skills)
    |> Map.merge(native_report(spec, Map.merge(agents, skills)))
  end

  defp native_turns(spec) do
    for %{"kind" => "agent", "name" => name, "max_turns" => turns} <-
          get_in(spec, ["native", "items"]) || [],
        into: %{},
        do: {name, turns}
  end

  # A generated subagent lists its closed tool set; Claude Code gives it exactly these.
  defp agent_markdown_v2(agent, max_turns) do
    tools =
      case agent["tools"] do
        [_ | _] = tools -> "tools: " <> Enum.join(tools, ", ") <> "\n"
        _ -> ""
      end

    "---\nname: #{quoted(agent["name"])}\ndescription: #{quoted(agent["description"])}\n" <>
      tools <> "maxTurns: #{max_turns}\n---\n\n" <> agent["instructions"] <> "\n"
  end

  # What each generated skill and subagent is made of, with the SHA-256 of its file.
  defp native_report(%{"native" => %{"items" => [_ | _]} = native}, files) do
    items =
      Enum.map(native["items"], fn item ->
        Map.put(item, "sha256", Contracts.sha256(Map.fetch!(files, item["path"])))
      end)

    report =
      native
      |> Map.take(
        ~w(select measured_on dropped test_runner_commands listing_bytes cost history_head)
      )
      |> Map.merge(%{"schema" => "olivium.native-provenance/v1", "items" => items})

    %{@native_report => Contracts.canonical_json(report) <> "\n"}
  end

  defp native_report(_spec, _files), do: %{}

  # The lean-ai files: the bundle byte for byte (it is canonical JSON, checked when it
  # was read), the index, the rewrite table, and the two hooks when they have work.
  defp learned_files(spec, data) do
    learned =
      if is_map(spec["learned"]),
        do: %{@learned_file => Contracts.canonical_json(spec["learned"]) <> "\n"},
        else: %{}

    scripts =
      [
        {Locator.path(), Locator.render(spec, data[Hooks.cochange_path()] || "")},
        {Rewrite.path(), Rewrite.render(spec)}
      ]
      |> Enum.reject(fn {_path, script} -> is_nil(script) end)
      |> Map.new()

    learned
    |> Map.merge(Locator.data_files(spec))
    |> Map.merge(Rewrite.data_files(spec))
    |> Map.merge(scripts)
  end

  defp settings_v2(spec) do
    data = Hooks.data_files(spec)

    hooks =
      spec
      |> Hooks.events()
      |> put_guard(Guard.render(spec))
      |> put_rewrite(Rewrite.render(spec), get_in(spec, ["rewrites", "timeout_seconds"]))
      |> put_locator(Locator.render(spec, data[Hooks.cochange_path()] || ""), spec["hooks"] || [])

    spec
    |> base_settings_v2()
    |> then(&if(hooks == %{}, do: &1, else: Map.put(&1, "hooks", hooks)))
  end

  # Everything but the hooks (and, for lean-x, the output style): the same keys and
  # values for lean, lean-ai and lean-x.
  defp base_settings_v2(spec) do
    context = spec["context"] || %{}

    %{
      "$schema" => @settings_schema,
      "permissions" => permissions_v2(spec),
      "disableSkillShellExecution" => true
    }
    |> put_false("includeGitInstructions", context["include_git_instructions"])
    |> put_false("autoMemoryEnabled", context["auto_memory"])
    |> put_true("disableBundledSkills", context["disable_bundled_skills"])
  end

  # Measured on 2.1.311 with Workflow denied (checked in `context/1`): the bundled skill
  # listing goes (-5,950 B); the repository's and the user's own skills stay listed.
  # `disable_builtin_agents` is written as deny rules (`permissions_v2/1`), not as the
  # env switch CLAUDE_AGENT_SDK_DISABLE_BUILTIN_AGENTS: from the project or local
  # settings that switch has no effect on 2.1.311 (it works only with --settings).
  defp put_true(settings, key, true), do: Map.put(settings, key, true)
  defp put_true(settings, _key, _value), do: settings

  # Each key is rendered only to switch a measured part of the prompt off; true is
  # Claude Code's default and is never written. `skillOverrides` is never rendered, and
  # `disableBundledSkills` only while `Workflow` is denied: with `Workflow` kept, on
  # 2.1.311 both make the `Workflow` tool description inline the skill text and raise
  # every request (by up to 4,007 tokens; +11,178 B measured for disableBundledSkills).
  defp put_false(settings, key, false), do: Map.put(settings, key, false)
  defp put_false(settings, _key, _value), do: settings

  # The context profile is checked against fixed lists; nothing in it becomes code.
  # A profile that would remove the subagents or skills the spec ships is refused, not
  # changed: the generator decides, the adapter never switches profiles on its own.
  defp context(%{"context" => nil}), do: :ok

  defp context(%{"context" => context} = spec) when is_map(context) do
    deny = context["deny_tools"] || []

    cond do
      Map.has_key?(context, "profile") and context["profile"] not in @context_profiles ->
        error(
          "invalid_runtime_intent",
          "The context profile must be lean, standard, lean-ai or lean-x"
        )

      not is_list(deny) or Enum.any?(deny, &(&1 not in @deny_tools)) or
          length(Enum.uniq(deny)) != length(deny) ->
        error(
          "invalid_runtime_intent",
          "context.deny_tools may only name these Claude Code 2.1.311 tools, once each: " <>
            Enum.join(@deny_tools, ", ")
        )

      "Skill" in deny and "Workflow" not in deny ->
        error(
          "invalid_runtime_intent",
          "Skill cannot be denied while Workflow is kept: denying Skill alone adds about 3,170 tokens to every request"
        )

      Enum.any?(~w(disable_bundled_skills disable_builtin_agents), fn key ->
        Map.has_key?(context, key) and not is_boolean(context[key])
      end) ->
        error("invalid_runtime_intent", "Context switches must be true or false")

      not valid_kept_tools?(context["kept_tools"]) ->
        error(
          "invalid_runtime_intent",
          "context.kept_tools may only name Skill and Task, once each"
        )

      context["disable_bundled_skills"] == true and "Workflow" not in deny ->
        error(
          "invalid_runtime_intent",
          "disable_bundled_skills needs Workflow denied: measured +11,178 B with Workflow kept (sa-h vs sa-c), because the Workflow description inlines the skill text"
        )

      context["disable_bundled_skills"] == true and "Skill" in deny ->
        error(
          "invalid_runtime_intent",
          "disable_bundled_skills needs the Skill tool: with Skill denied there is no skill to keep"
        )

      context["disable_builtin_agents"] == true and "Task" in deny ->
        error(
          "invalid_runtime_intent",
          "disable_builtin_agents needs the Task tool: with Task denied there is no subagent to keep"
        )

      ("Task" in deny and (spec["agents"] || []) != []) or
          ("Skill" in deny and (spec["skills"] || []) != []) ->
        error(
          "lean_profile_unavailable",
          "The lean context profile removes the Task and Skill tools, so it cannot ship agents or skills; use the standard profile"
        )

      Enum.any?(~w(include_git_instructions auto_memory), fn key ->
        Map.has_key?(context, key) and not is_boolean(context[key])
      end) ->
        error("invalid_runtime_intent", "Context switches must be true or false")

      true ->
        :ok
    end
  end

  defp context(%{"context" => _}),
    do: error("invalid_runtime_intent", "The context profile must be an object")

  defp context(_spec), do: :ok

  defp valid_kept_tools?(nil), do: true

  defp valid_kept_tools?(kept) when is_list(kept),
    do: Enum.all?(kept, &(&1 in ["Skill", "Task"])) and Enum.uniq(kept) == kept

  defp valid_kept_tools?(_), do: false

  # The skills and subagents generated from history (`spec.native`): checked against
  # fixed limits, never repaired. Only they may list tools; only the test runner may
  # list Bash, and only with its allowed commands and the guard that enforces them.
  defp native_items(spec) do
    native = spec["native"]
    items = if is_map(native), do: native["items"] || [], else: []
    runner_commands = if is_map(native), do: native["test_runner_commands"] || [], else: []
    named = MapSet.new(items, & &1["name"])
    agents = Map.new(spec["agents"] || [], &{&1["name"], &1})
    skills = Map.new(spec["skills"] || [], &{&1["name"], &1})
    tooled = Enum.filter(Map.values(agents), &Map.has_key?(&1, "tools"))

    entry = fn item ->
      case item["kind"] do
        "skill" -> skills[item["name"]]
        "agent" -> agents[item["name"]]
        _ -> nil
      end
    end

    cond do
      Enum.any?(tooled, &(not MapSet.member?(named, &1["name"]))) ->
        error("invalid_runtime_intent", "Only generated subagents (spec.native) may list tools")

      Enum.any?(tooled, fn agent ->
        tools = agent["tools"]

        not is_list(tools) or tools == [] or Enum.uniq(tools) != tools or
            Enum.any?(tools, &(&1 not in Native.agent_tools()))
      end) ->
        error(
          "invalid_runtime_intent",
          "A subagent's tools may only be " <>
            Enum.join(Native.agent_tools(), ", ") <> ", once each"
        )

      Enum.any?(tooled, &("Bash" in &1["tools"] and &1["name"] != Native.runner_name())) ->
        error("invalid_runtime_intent", "Only #{Native.runner_name()} may use Bash")

      Enum.any?(tooled, &("Bash" in &1["tools"])) and
          (runner_commands == [] or is_nil(Guard.render(spec))) ->
        error(
          "invalid_runtime_intent",
          "#{Native.runner_name()} needs spec.native.test_runner_commands and the guard that limits its Bash to them"
        )

      Enum.any?(items, &(not Native.name?(&1["name"]))) ->
        error("invalid_runtime_intent", "Generated skill and subagent names start with olivium-")

      Enum.any?(items, &is_nil(entry.(&1))) ->
        error(
          "invalid_runtime_intent",
          "Every spec.native item must be a spec skill or agent of its kind"
        )

      Enum.any?(items, &(byte_size(entry.(&1)["description"]) > @native_description_bytes)) ->
        error(
          "invalid_runtime_intent",
          "A generated skill or subagent description is over #{@native_description_bytes} bytes"
        )

      Enum.any?(items, &(byte_size(entry.(&1)["instructions"]) > @native_body_bytes)) ->
        error(
          "invalid_runtime_intent",
          "A generated skill or subagent body is over #{@native_body_bytes} bytes"
        )

      Enum.any?(
        items,
        &(&1["kind"] == "agent" and
              not (is_integer(&1["max_turns"]) and &1["max_turns"] in 1..100))
      ) ->
        error("invalid_runtime_intent", "A generated subagent needs max_turns from 1 to 100")

      Enum.any?(
        Map.values(agents),
        &(Map.has_key?(&1, "tools") and
              not Native.safe_text?(&1["instructions"] <> "\n" <> &1["description"]))
      ) ->
        error(
          "invalid_runtime_intent",
          "Dynamic shell and file-import expansion in subagents is unsupported"
        )

      true ->
        :ok
    end
  end

  # Only rules the spec states are rendered. An unlisted tool must stay out of `ask`:
  # deny, ask and allow are checked in that order, so a bare `Bash` in ask would
  # override every `Bash(mix test:*)` allow rule.
  #
  # Read deny rules are not rendered: while any exists, Claude Code 2.1.311 asks before
  # every `cd dir && cmd` compound, which an unattended run refuses. The guard hook
  # refuses those reads instead. Edit deny rules stay; they do not trigger that check.
  defp permissions_v2(spec) do
    tools =
      for %{"capability" => "tool_permissions." <> tool, "value" => value} <- spec["policies"],
          rule <- tool_rules(tool, value, spec),
          do: {value, rule}

    commands =
      for rule <- spec["permissions"]["commands"],
          do: {rule["action"], command_rule(rule)}

    # Write rules are accepted but never match; Edit rules cover both tools.
    paths =
      for rule <- spec["permissions"]["paths"],
          not (rule["access"] == "read" and rule["action"] == "deny"),
          do:
            {rule["action"],
             "#{if rule["access"] == "read", do: "Read", else: "Edit"}(#{rule["pattern"]})"}

    # A bare tool name removes that tool from the request (`spec.context.deny_tools`).
    unused = for name <- get_in(spec, ["context", "deny_tools"]) || [], do: {"deny", name}

    # `context.disable_builtin_agents`: one deny rule per built-in subagent takes it out
    # of the Agent tool's listing (measured on 2.1.311: -971 B on the first request; a
    # call for one gets "Agent type 'Explore' has been denied by permission rule", the
    # repository's, the user's and the generated subagents stay listed and callable).
    builtin =
      if get_in(spec, ["context", "disable_builtin_agents"]) == true,
        do: Enum.map(@builtin_agents, &{"deny", "Agent(#{&1})"}),
        else: []

    grouped =
      Enum.group_by(tools ++ commands ++ paths ++ unused ++ builtin, &elem(&1, 0), &elem(&1, 1))

    %{
      "allow" => Enum.sort(Map.get(grouped, "allow", [])),
      "ask" => Enum.sort(Map.get(grouped, "ask", [])),
      "deny" => grouped |> Map.get("deny", []) |> Enum.uniq() |> Enum.sort(),
      "defaultMode" => "default"
    }
  end

  # An allowed Skill tool is allowed for the package's own skills only, one rule per
  # name (`Skill(olivium-area-x)`), so a skill the repository, a plugin or a session
  # adds still needs approval. Every other tool policy is one bare rule.
  defp tool_rules("skill", "allow", %{"skills" => [_ | _] = skills}),
    do: Enum.map(skills, &"Skill(#{&1["name"]})")

  defp tool_rules(tool, _value, _spec), do: [Map.fetch!(@tools, tool)]

  # An exact rule keeps `npm install` from approving `npm install any-package`.
  defp command_rule(%{"exact" => true, "command" => command}), do: "Bash(#{command})"
  defp command_rule(%{"command" => command}), do: "Bash(#{command}:*)"

  defp put_guard(settings, nil), do: settings

  defp put_guard(settings, guard) do
    Map.put(settings, "PreToolUse", [
      %{
        "matcher" => @guarded_tools,
        "hooks" => [
          %{
            "type" => "command",
            "command" => guard_command(guard),
            "timeout" => @guard_timeout
          }
        ]
      }
    ])
  end

  # A separate PreToolUse entry after the guard: Claude Code runs both, and a guard
  # refusal wins over a rewrite.
  defp put_rewrite(settings, nil, _timeout), do: settings

  defp put_rewrite(settings, script, timeout) do
    entry = %{
      "matcher" => "Bash",
      "hooks" => [
        %{"type" => "command", "command" => Rewrite.command(script), "timeout" => timeout}
      ]
    }

    Map.update(settings, "PreToolUse", [entry], &(&1 ++ [entry]))
  end

  defp put_locator(settings, nil, _hooks), do: settings

  defp put_locator(settings, script, hooks) do
    timeout =
      hooks
      |> Enum.filter(&(&1["event"] == "prompt_submit"))
      |> Enum.map(& &1["timeout_seconds"])
      |> Enum.max()

    Map.put(settings, "UserPromptSubmit", [
      %{
        "hooks" => [
          %{"type" => "command", "command" => Locator.command(script), "timeout" => timeout}
        ]
      }
    ])
  end

  # The one line the guard prints when it refuses a call. The hook command passes on
  # this line and nothing else, so the hook can only refuse or stay silent: never
  # approve, never change the tool input. The guard keeps `"` and `\` out of its reason.
  @guard_deny_line ~S(^[{]"hookSpecificOutput":[{]"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Olivium guard: [^"\\]*"[}][}]$)

  # The PreToolUse hook command. Claude Code runs it with /bin/sh and the session's
  # PATH, where a program the agent runs can put its own `grep` (.venv/bin,
  # node_modules/.bin, ~/.local/bin), so the command first sets PATH to /usr/bin:/bin.
  # The guard file is read once and runs only when its SHA-256 is the one generated
  # with it: a changed file never runs. The checksum line is compared whole, so text
  # another process adds to the command's pipes makes the check fail. (A process that
  # can also read those pipes could swap both texts; the filter still passes on only a
  # refusal.)
  # The guard gets the session PATH as OLIVIUM_PATH, only to look up whether a package
  # npx would run is installed.
  #
  # A PreToolUse hook that exits 2 blocks the call, and `sh missing-file` exits 2 in
  # dash, so a deleted guard would block every tool call. When the file is missing,
  # changed or cannot be checked (no sha256sum or shasum), or the guard fails, the
  # command prints one line to stderr and exits 0, and Claude Code's own rules decide
  # alone. The filter's exit status is dropped for the same reason.
  @doc false
  def guard_command(script) do
    path = Guard.path()
    digest = :crypto.hash(:sha256, script) |> Base.encode16(case: :lower)

    """
    p=$PATH; PATH=/usr/bin:/bin; g="$CLAUDE_PROJECT_DIR/#{path}"; s=$(cat "$g" 2>/dev/null); h=$(printf '%s\\n' "$s" | { sha256sum || shasum -a 256; } 2>/dev/null); if [ "$h" = "#{digest}  -" ]; then { OLIVIUM_PATH=$p /bin/sh -c "$s" olivium-guard || echo "Olivium guard: #{path} failed; only Claude Code's own permission rules apply." >&2; } | grep -E '#{@guard_deny_line}'; true; else echo "Olivium guard: #{path} is missing, changed or cannot be checked; only Claude Code's own permission rules apply." >&2; fi
    """
    |> String.trim_trailing()
  end

  @doc false
  def guard_deny_line, do: @guard_deny_line

  defp guard_script(spec) do
    case Guard.render(spec) do
      nil -> %{}
      script -> %{Guard.path() => script}
    end
  end

  # Every withheld line is in the report with its reason code (contract section 6).
  defp guidance_diagnostics(%{"withheld" => []}), do: []

  defp guidance_diagnostics(%{"withheld" => withheld} = report) when is_list(withheld) do
    counts =
      case report["withheld_counts"] do
        counts when is_map(counts) -> counts
        _ -> Enum.frequencies_by(withheld, & &1["reason"])
      end

    detail =
      counts
      |> Enum.filter(fn {_code, count} -> is_integer(count) and count > 0 end)
      |> Enum.sort()
      |> Enum.map_join(", ", fn {code, count} -> "#{count} #{code}" end)

    [
      %{
        "code" => "guidance_withheld",
        "severity" => "info",
        "message" =>
          "#{length(withheld)} lines were withheld from CLAUDE.md (#{detail}). See #{@guidance_report}."
      }
    ]
  end

  defp guidance_diagnostics(%{"dropped" => []}), do: []

  defp guidance_diagnostics(%{"dropped" => dropped, "budget_bytes" => budget}) do
    [
      %{
        "code" => "guidance_truncated",
        "severity" => "warning",
        "message" =>
          "#{length(dropped)} guidance lines were left out of CLAUDE.md (budget #{budget} bytes). See #{@guidance_report}."
      }
    ]
  end

  defp guidance_diagnostics(_report), do: []

  defp runtime_format(%{"name" => "claude_code", "version" => version})
       when version in ["unqualified", @observed_version],
       do: :ok

  defp runtime_format(_),
    do:
      error(
        "unsupported_runtime",
        "Claude Code previews require unqualified or the observed exact version #{@observed_version}"
      )

  defp mode(%{"mode" => "preview"}), do: :ok

  defp mode(_),
    do:
      error(
        "runtime_unqualified",
        "Managed execution requires a separately qualified runtime and execution backend"
      )

  defp native_names(spec) do
    names = Enum.map(spec["agents"] ++ spec["skills"], & &1["name"])

    if Enum.all?(names, &safe_name?/1),
      do: :ok,
      else:
        error(
          "invalid_runtime_intent",
          "Claude agent and skill names require 1–64 lowercase letters/digits with single hyphens"
        )
  end

  defp safe_name?(name) when is_binary(name),
    do: byte_size(name) <= 64 and Regex.match?(~r/^[a-z0-9]+(-[a-z0-9]+)*$/, name)

  defp safe_name?(_), do: false

  # CLAUDE.md expands @path references, including absolute paths. Restrict this
  # preview to static text rather than letting rule text import host files.
  defp static_rules(rules) do
    if Enum.any?(rules, &String.contains?(&1["statement"], "@")),
      do: error("invalid_runtime_intent", "CLAUDE.md file-import markers are unsupported"),
      else: :ok
  end

  # Claude interprets this special skill syntax as a shell command before it
  # sends the skill to the model. Native previews support static instruction data.
  defp static_skills(skills) do
    unsafe? =
      Enum.any?(skills, fn skill ->
        Enum.any?(Map.take(skill, ~w(name description instructions)), fn {_key, value} ->
          String.contains?(value, ["!`", "@"]) or Regex.match?(~r/(?:`{3,}|~{3,})[ \t]*!/, value)
        end)
      end)

    if unsafe?,
      do:
        error(
          "invalid_runtime_intent",
          "Dynamic shell and file-import expansion in skills is unsupported"
        ),
      else: :ok
  end

  defp permission_values(policies) do
    tool_policies =
      Enum.filter(policies, &String.starts_with?(&1["capability"], "tool_permissions."))

    names = Enum.map(tool_policies, & &1["capability"])

    valid? =
      Enum.all?(tool_policies, fn policy ->
        "tool_permissions." <> tool = policy["capability"]
        Map.has_key?(@tools, tool) and policy["value"] in ["allow", "ask", "deny"]
      end)

    cond do
      not valid? ->
        error(
          "invalid_runtime_intent",
          "Claude tool permissions require a known portable tool and allow, ask or deny"
        )

      length(Enum.uniq(names)) != length(names) ->
        error("invalid_runtime_intent", "A tool cannot have duplicate permission policies")

      true ->
        :ok
    end
  end

  defp policy_capability(policy) do
    {status, boundary, note} =
      case policy["capability"] do
        "tool_permissions." <> tool when is_map_key(@tools, tool) ->
          {"advisory", "claude_code.permissions",
           "Native approval rules are runtime UX; compatibility and external isolation are unqualified."}

        _ ->
          {"unsupported", "none", "No qualified enforcement exists for this control."}
      end

    capability(policy["capability"], policy["required"], policy["value"], status, boundary, note)
    |> Map.put("policy_id", policy["id"])
  end

  defp capability(id, required, value, status, boundary, note) do
    %{
      "id" => id,
      "required" => required,
      "requested_value" => value,
      "mapping_version" => @mapping_version,
      "status" => status,
      "enforcement_boundary" => boundary,
      "environment_profile_digest" => nil,
      "compatibility_test_reference" => nil,
      "diagnostics" => [note]
    }
  end

  defp required_controls(report) do
    failed = Enum.filter(report, & &1["required"])

    if failed == [],
      do: :ok,
      else:
        error(
          "unsupported_required_control",
          "Required controls have no qualified enforcement",
          Enum.map(failed, & &1["id"])
        )
  end

  defp diagnostics(report) do
    [
      %{
        "code" => "runtime_unqualified",
        "severity" => "warning",
        "message" =>
          "Claude Code native preview only. A rendered configuration does not establish authenticated execution or isolation."
      }
    ] ++
      for item <- report,
          item["status"] == "unsupported",
          do: %{
            "code" => "unsupported_control",
            "severity" => "warning",
            "capability" => item["id"],
            "message" => "Requested control is not enforced by this export."
          }
  end

  defp permissions(policies) do
    requested =
      for %{"capability" => "tool_permissions." <> tool, "value" => value} <- policies,
          into: %{},
          do: {tool, value}

    Enum.reduce(@tools, %{"allow" => [], "ask" => [], "deny" => []}, fn {portable, native}, acc ->
      Map.update!(acc, Map.get(requested, portable, "ask"), &[native | &1])
    end)
    |> Map.new(fn {key, values} -> {key, Enum.sort(values)} end)
    |> Map.merge(%{"defaultMode" => "default", "disableBypassPermissionsMode" => "disable"})
  end

  defp agent_markdown(agent, max_turns) do
    "---\nname: #{quoted(agent["name"])}\ndescription: #{quoted(agent["description"])}\n" <>
      "permissionMode: default\nmaxTurns: #{max_turns}\n---\n\n" <>
      agent["instructions"] <> "\n"
  end

  defp skill_markdown(skill) do
    "---\nname: #{quoted(skill["name"])}\ndescription: #{quoted(skill["description"])}\n---\n\n" <>
      skill["instructions"] <> "\n"
  end

  defp quoted(text) do
    text
    |> Jason.encode!(escape: :javascript_safe)
    |> String.replace(~r/[\x{007f}-\x{009f}]/u, fn character ->
      [point] = String.to_charlist(character)
      "\\u" <> String.pad_leading(Integer.to_string(point, 16), 4, "0")
    end)
  end

  defp guidance(harness) do
    rules =
      harness["spec"]["rules"]
      |> Enum.sort_by(& &1["id"])
      |> Enum.map_join("\n\n", fn rule ->
        "<!-- rule: #{rule["id"]}; revision: #{rule["revision_hash"]} -->\n" <> rule["statement"]
      end)

    "# #{harness["metadata"]["name"]}\n\n" <>
      "Native preview; runtime qualification is unverified. See harnessforge.capabilities.json.\n\n" <>
      "These instructions guide the model. They do not enforce filesystem, network, timeout or spending restrictions.\n\n" <>
      rules <> "\n"
  end

  defp error(code, message, details \\ []),
    do: {:error, %Error{code: code, message: message, details: details}}
end
