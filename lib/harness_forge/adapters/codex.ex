defmodule HarnessForge.Adapters.Codex do
  @moduledoc """
  Deterministic native preview renderer for the documented Codex 0.156.0 format.

  Project settings, standalone agent TOML files and instruction-only skills are
  exported without executing Codex. Project trust, higher-priority configuration
  and the actual execution environment remain outside this renderer's authority.
  A documented sandbox setting is never treated as qualified external isolation.
  """
  @behaviour HarnessForge.Contracts.RuntimeAdapter
  alias HarnessForge.Contracts
  alias HarnessForge.Contracts.Error

  @mapping_version "codex-0.156.0-docs-v1"
  @sources [
    "https://learn.chatgpt.com/docs/config-file/config-basic",
    "https://learn.chatgpt.com/docs/config-file/config-reference",
    "https://learn.chatgpt.com/docs/agent-configuration/subagents",
    "https://learn.chatgpt.com/docs/build-skills"
  ]

  @spec identity() :: map()
  def identity do
    %{
      "name" => "codex",
      "mapping_version" => @mapping_version,
      "qualification" => "unverified",
      "documentation" => @sources
    }
  end

  @impl true
  def probe(_config),
    do: {:ok, Map.merge(identity(), %{"available" => false, "reason" => "runtime_unqualified"})}

  @impl true
  def capabilities(harness, _config) do
    execution = harness["spec"]["execution"]

    {:ok,
     Enum.map(harness["spec"]["policies"], &policy_capability/1) ++
       [
         capability(
           "execution.max_turns",
           false,
           execution["max_turns"],
           "unsupported",
           "none",
           ["No documented Codex global turn budget is mapped by this format."]
         ),
         capability(
           "execution.timeout_seconds",
           false,
           execution["timeout_seconds"],
           "unsupported",
           "none",
           ["Timeout requires a qualified external execution backend."]
         )
       ]}
  end

  @impl true
  def validate_intent(harness, config) do
    with {:ok, harness} <- Contracts.validate_harness(harness),
         :ok <- runtime_format(harness["spec"]["runtime"]),
         :ok <- mode(config),
         :ok <- native_names(harness["spec"]),
         :ok <- policy_values(harness["spec"]["policies"]),
         {:ok, report} <- capabilities(harness, config),
         :ok <- required_controls(report) do
      {:ok, %{"capabilities" => report, "diagnostics" => diagnostics(report)}}
    end
  end

  @impl true
  def compile(harness, config) do
    with {:ok, intent} <- validate_intent(harness, config) do
      spec = harness["spec"]
      instructions = guidance(harness)

      files =
        Map.new(spec["agents"], fn agent ->
          {".codex/agents/#{agent["name"]}.toml", agent_toml(agent)}
        end)
        |> Map.merge(
          Map.new(spec["skills"], fn skill ->
            {".agents/skills/#{skill["name"]}/SKILL.md", skill_markdown(skill)}
          end)
        )
        |> Map.merge(%{
          "AGENTS.md" => instructions,
          ".codex/config.toml" => config_toml(spec, byte_size(instructions))
        })

      {:ok, Map.put(intent, "files", files)}
    end
  end

  defp runtime_format(%{"name" => "codex", "version" => version})
       when version in ["unqualified", "0.156.0"],
       do: :ok

  defp runtime_format(_),
    do:
      error(
        "unsupported_runtime",
        "Only the documented Codex 0.156.0 native preview format is available"
      )

  defp mode(%{"mode" => "preview"}), do: :ok

  defp mode(_),
    do:
      error(
        "runtime_unqualified",
        "Managed compilation requires a qualified Codex runtime and execution profile"
      )

  defp native_names(spec) do
    valid? =
      Enum.all?(spec["agents"] ++ spec["skills"], fn item ->
        byte_size(item["name"]) <= 64 and
          Regex.match?(~r/^[a-z][a-z0-9]*(-[a-z0-9]+)*$/, item["name"])
      end)

    if valid?,
      do: :ok,
      else:
        error(
          "invalid_runtime_intent",
          "Codex export names require lowercase letters/digits separated by single hyphens"
        )
  end

  defp policy_values(policies) do
    mapped =
      Enum.filter(policies, &(&1["capability"] in ["network.denied", "tool_permissions.bash"]))

    valid? =
      Enum.all?(mapped, fn policy ->
        case policy["capability"] do
          "network.denied" -> is_boolean(policy["value"])
          "tool_permissions.bash" -> policy["value"] in ["allow", "ask", "deny"]
        end
      end)

    names = Enum.map(mapped, & &1["capability"])

    if valid? and length(names) == length(Enum.uniq(names)),
      do: :ok,
      else:
        error(
          "invalid_runtime_intent",
          "Codex policies require valid values and one policy per mapped control"
        )
  end

  defp policy_capability(policy) do
    {status, boundary, notes} =
      case {policy["capability"], policy["value"]} do
        {"network.denied", true} ->
          {"advisory", "codex.sandbox_workspace_write.network_access+web_search",
           [
             "Renders network_access=false and web_search=disabled. Project trust, overrides and external connectors remain separate; isolation is unqualified."
           ]}

        {"tool_permissions.bash", "deny"} ->
          {"advisory", "codex.features.shell_tool",
           [
             "Renders shell_tool=false. This disables a documented command tool surface, not every possible execution path."
           ]}

        _ ->
          {"unsupported", "none", ["No qualified enforcement exists for this requested control."]}
      end

    capability(policy["capability"], policy["required"], policy["value"], status, boundary, notes)
    |> Map.put("policy_id", policy["id"])
  end

  defp capability(id, required, value, status, boundary, notes) do
    %{
      "id" => id,
      "required" => required,
      "requested_value" => value,
      "mapping_version" => @mapping_version,
      "status" => status,
      "enforcement_boundary" => boundary,
      "environment_profile_digest" => nil,
      "compatibility_test_reference" => nil,
      "diagnostics" => notes
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
          "Native Codex preview only. This renderer does not execute or qualify Codex; managed execution and promotion remain unavailable."
      },
      %{
        "code" => "project_configuration_advisory",
        "severity" => "warning",
        "message" =>
          "Codex loads project configuration only in trusted projects. Higher-priority settings and parent-session permissions can override defaults."
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

  defp config_toml(spec, document_bytes) do
    shell =
      if Enum.any?(spec["policies"], fn policy ->
           policy["capability"] == "tool_permissions.bash" and policy["value"] == "deny"
         end),
         do: "\n[features]\nshell_tool = false\n",
         else: ""

    "# HarnessForge native preview; project defaults are not qualification evidence.\n" <>
      "approval_policy = \"on-request\"\n" <>
      "sandbox_mode = \"workspace-write\"\n" <>
      "web_search = \"disabled\"\n" <>
      "project_doc_max_bytes = #{max(32_768, document_bytes)}\n" <>
      "\n[sandbox_workspace_write]\nnetwork_access = false\n" <> shell
  end

  defp agent_toml(agent) do
    "name = #{toml_string(agent["name"])}\n" <>
      "description = #{toml_string(agent["description"])}\n" <>
      "developer_instructions = #{toml_string(agent["instructions"])}\n"
  end

  # TOML basic strings forbid literal DEL as well as C0 controls. Escape the
  # remaining C1 range too so the same quoted subset is valid YAML frontmatter.
  defp toml_string(value) do
    escaped =
      value
      |> String.to_charlist()
      |> Enum.map_join(fn
        ?" ->
          "\\\""

        ?\\ ->
          "\\\\"

        ?\n ->
          "\\n"

        ?\r ->
          "\\r"

        ?\t ->
          "\\t"

        codepoint when codepoint < 32 or codepoint in 127..159 ->
          "\\u" <> String.pad_leading(Integer.to_string(codepoint, 16), 4, "0")

        codepoint ->
          <<codepoint::utf8>>
      end)

    "\"" <> escaped <> "\""
  end

  defp skill_markdown(skill) do
    "---\nname: #{toml_string(skill["name"])}\ndescription: #{toml_string(skill["description"])}\n---\n\n" <>
      skill["instructions"] <> "\n"
  end

  defp guidance(harness) do
    rules =
      harness["spec"]["rules"]
      |> Enum.sort_by(& &1["id"])
      |> Enum.map_join("\n\n", fn rule ->
        "<!-- rule: #{rule["id"]}; revision: #{rule["revision_hash"]} -->\n" <> rule["statement"]
      end)

    "# #{harness["metadata"]["name"]}\n\n" <>
      "Native Codex preview; runtime compatibility is unverified. See harnessforge.capabilities.json.\n\n" <>
      "These instructions guide the model. They do not enforce filesystem, network, timeout, turn or spending restrictions.\n\n" <>
      rules <> "\n"
  end

  defp error(code, message, details \\ []),
    do: {:error, %Error{code: code, message: message, details: details}}
end
