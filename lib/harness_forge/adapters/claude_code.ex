defmodule HarnessForge.Adapters.ClaudeCode do
  @moduledoc """
  Deterministic Claude Code native preview renderer. This adapter does not start
  the CLI, authenticate, execute tools or establish an isolation boundary.

  The format follows current official documentation and the observed 2.1.311
  CLI. An exact version or `unqualified` requests a preview, not qualification.
  """
  @behaviour HarnessForge.Contracts.RuntimeAdapter

  alias HarnessForge.Contracts
  alias HarnessForge.Contracts.Error

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
