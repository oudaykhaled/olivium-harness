defmodule HarnessForge.Adapters.OpenCode do
  @moduledoc """
  OpenCode 1 format renderer, based on the official rules/agents/skills/permissions
  documentation. This adapter never runs OpenCode and has no qualified executable
  profile. Rendered permissions are runtime UX, not a filesystem/network sandbox.

  `unqualified` explicitly selects this documented format for native previews.
  Numeric 1.x versions can also be previewed; neither implies compatibility proof.
  """
  @behaviour HarnessForge.Contracts.RuntimeAdapter
  alias HarnessForge.Contracts
  alias HarnessForge.Contracts.Error

  @mapping_version "opencode-1-docs-v1"
  @tools ~w(read edit glob grep bash task todowrite skill lsp question webfetch websearch external_directory doom_loop)
  @sources [
    "https://opencode.ai/docs/rules/",
    "https://opencode.ai/docs/agents/",
    "https://opencode.ai/docs/skills/",
    "https://opencode.ai/docs/permissions/"
  ]

  @spec identity() :: map()
  def identity do
    %{
      "name" => "opencode",
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
    requested = harness["spec"]["policies"]
    entries = Enum.map(requested, &policy_capability/1)
    execution = harness["spec"]["execution"]

    {:ok,
     entries ++
       [
         capability(
           "execution.max_turns",
           false,
           execution["max_turns"],
           "advisory",
           "agent.steps",
           ["Per-agent steps are advisory; no global request, token or cost budget is enforced."]
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
    runtime = harness["spec"]["runtime"]

    with :ok <- runtime_format(runtime),
         :ok <- mode(config),
         :ok <- skill_names(harness["spec"]["skills"]),
         :ok <- permission_values(harness["spec"]["policies"]),
         {:ok, report} <- capabilities(harness, config),
         :ok <- required_controls(report) do
      {:ok, %{"capabilities" => report, "diagnostics" => diagnostics(report)}}
    end
  end

  @impl true
  def compile(harness, config) do
    with {:ok, intent} <- validate_intent(harness, config) do
      spec = harness["spec"]
      permission = permissions(spec["policies"])

      config_file = %{
        "$schema" => "https://opencode.ai/config.json",
        "permission" => permission,
        "agent" =>
          Map.new(spec["agents"], &{&1["name"], %{"steps" => spec["execution"]["max_turns"]}})
      }

      agents =
        Map.new(spec["agents"], fn agent ->
          {".opencode/agents/#{agent["name"]}.md", agent_markdown(agent)}
        end)

      skills =
        Map.new(spec["skills"], fn skill ->
          {".opencode/skills/#{skill["name"]}/SKILL.md", skill_markdown(skill)}
        end)

      files =
        agents
        |> Map.merge(skills)
        |> Map.merge(%{
          "AGENTS.md" => guidance(harness),
          "opencode.json" => Contracts.canonical_json(config_file) <> "\n"
        })

      {:ok, Map.put(intent, "files", files)}
    end
  end

  defp runtime_format(%{"name" => "opencode", "version" => "unqualified"}), do: :ok

  defp runtime_format(%{"name" => "opencode", "version" => version}) do
    case Version.parse(version) do
      {:ok, %Version{major: 1}} ->
        :ok

      _ ->
        error("unsupported_runtime", "Only the documented OpenCode 1 preview format is available")
    end
  end

  defp runtime_format(_),
    do: error("unsupported_runtime", "The requested runtime has no registered adapter")

  defp mode(%{"mode" => "preview"}), do: :ok

  defp mode(_),
    do:
      error(
        "runtime_unqualified",
        "Managed compilation requires an actually qualified runtime and execution profile"
      )

  defp skill_names(skills) do
    if Enum.all?(skills, &Regex.match?(~r/^[a-z0-9]+(-[a-z0-9]+)*$/, &1["name"])),
      do: :ok,
      else:
        error(
          "invalid_runtime_intent",
          "OpenCode skill names require lowercase letters/digits separated by single hyphens"
        )
  end

  defp permission_values(policies) do
    valid? =
      Enum.all?(policies, fn policy ->
        case policy["capability"] do
          "tool_permissions." <> tool when tool in @tools ->
            policy["value"] in ["allow", "ask", "deny"]

          _ ->
            true
        end
      end)

    names =
      for %{"capability" => "tool_permissions." <> tool} <- policies, tool in @tools, do: tool

    cond do
      not valid? ->
        error("invalid_runtime_intent", "Tool permissions must be allow, ask or deny")

      length(Enum.uniq(names)) != length(names) ->
        error("invalid_runtime_intent", "A tool cannot have conflicting permission policies")

      true ->
        :ok
    end
  end

  defp policy_capability(policy) do
    {status, boundary, notes} =
      case policy["capability"] do
        "tool_permissions." <> tool when tool in @tools ->
          {"advisory", "opencode.permission",
           [
             "Documented runtime setting; compatibility unverified. This does not provide adversarial isolation."
           ]}

        _ ->
          {"unsupported", "none", ["No qualified enforcement exists for this control."]}
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
    failed =
      Enum.filter(
        report,
        &(&1["required"] and &1["status"] not in ["supported_runtime", "enforced_external"])
      )

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
          "Native preview only. OpenCode was not executed or qualified; managed execution and promotion remain unavailable."
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
    Enum.reduce(policies, %{"*" => "ask", "external_directory" => "deny"}, fn policy, acc ->
      case policy["capability"] do
        "tool_permissions." <> tool when tool in @tools -> Map.put(acc, tool, policy["value"])
        _ -> acc
      end
    end)
  end

  defp agent_markdown(agent) do
    "---\ndescription: #{Jason.encode!(agent["description"])}\nmode: subagent\n---\n\n" <>
      agent["instructions"] <> "\n"
  end

  defp skill_markdown(skill) do
    "---\nname: #{Jason.encode!(skill["name"])}\ndescription: #{Jason.encode!(skill["description"])}\n---\n\n" <>
      skill["instructions"] <> "\n"
  end

  defp guidance(harness) do
    rules =
      harness["spec"]["rules"]
      |> Enum.sort_by(& &1["id"])
      |> Enum.map_join("\n\n", fn rule ->
        "<!-- rule: #{rule["id"]}; revision: #{rule["revision_hash"]} -->\n" <> rule["statement"]
      end)

    "# #{harness["metadata"]["name"]}\n\nNative preview; runtime compatibility is unverified. See harnessforge.capabilities.json.\n\n" <>
      "These instructions guide the model. They do not enforce filesystem, network, timeout or spending restrictions.\n\n" <>
      rules <> "\n"
  end

  defp error(code, message, details \\ []),
    do: {:error, %Error{code: code, message: message, details: details}}
end
