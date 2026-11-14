defmodule HarnessForge.Contracts.HarnessV2 do
  @moduledoc """
  Semantic rules for `harnessforge.dev/v1alpha2` that the JSON Schema keyword
  subset cannot express, plus the origin query eligibility checks depend on.

  A rule's `origin` decides what backs it. `approved_claim` means a human approved
  an immutable revision: it carries `revision_hash` plus evidence or a goal, and
  build eligibility must still confirm the decision exists. `derived` and `overlay`
  never pass through a decision: they carry a `fingerprint` and a `source` pointer
  instead, and cannot present a `revision_hash`, evidence or a goal.
  """

  alias HarnessForge.Contracts

  @api_version "harnessforge.dev/v1alpha2"

  @spec api_version() :: String.t()
  def api_version, do: @api_version

  @doc """
  Rules that need a current human decision before a build or export.
  Every rule in a v1alpha1 spec is an approved claim.
  """
  @spec approved_claim_rules(term()) :: [map()]
  def approved_claim_rules(%{"apiVersion" => @api_version, "spec" => %{"rules" => rules}})
      when is_list(rules),
      do: Enum.filter(rules, &(is_map(&1) and &1["origin"] == "approved_claim"))

  def approved_claim_rules(%{"spec" => %{"rules" => rules}}) when is_list(rules), do: rules
  def approved_claim_rules(_), do: []

  @doc "True for a v1alpha2 spec generated in solo mode, which needs no approved claims."
  @spec solo_generated?(term()) :: boolean()
  def solo_generated?(%{
        "apiVersion" => @api_version,
        "spec" => %{"generation" => %{"mode" => "solo"}}
      }),
      do: true

  def solo_generated?(_), do: false

  @spec semantic_errors(map()) :: [String.t()]
  def semantic_errors(%{"spec" => spec}) do
    goals = MapSet.new(spec["goals"], & &1["id"])

    duplicate_errors(spec) ++
      rule_errors(spec["rules"], goals) ++
      hook_errors(spec["hooks"], spec["project"]["commands"]) ++
      path_errors(spec)
  end

  defp duplicate_errors(spec) do
    permissions = spec["permissions"]

    [
      {"$.spec.rules", spec["rules"], & &1["id"]},
      {"$.spec.goals", spec["goals"], & &1["id"]},
      {"$.spec.policies", spec["policies"], & &1["id"]},
      {"$.spec.agents", spec["agents"], & &1["name"]},
      {"$.spec.skills", spec["skills"], & &1["name"]},
      {"$.spec.guidance", spec["guidance"], & &1["id"]},
      {"$.spec.hooks", spec["hooks"], & &1["id"]},
      {"$.spec.permissions.commands", permissions["commands"], & &1["id"]},
      {"$.spec.permissions.commands", permissions["commands"], & &1["command"]},
      {"$.spec.permissions.paths", permissions["paths"], & &1["id"]},
      {"$.spec.permissions.paths", permissions["paths"], &{&1["pattern"], &1["access"]}}
    ]
    |> Enum.flat_map(fn {path, items, identity} ->
      identities = Enum.map(items, identity)

      if length(Enum.uniq(identities)) == length(identities),
        do: [],
        else: [path <> ": duplicate identifiers"]
    end)
    |> Enum.uniq()
  end

  defp rule_errors(rules, goals) do
    rules
    |> Enum.with_index()
    |> Enum.flat_map(fn {rule, index} -> rule_error(rule, "$.spec.rules[#{index}]", goals) end)
  end

  defp rule_error(%{"origin" => "approved_claim"} = rule, path, goals) do
    missing =
      for key <- ~w(revision_hash evidence goal_id),
          not Map.has_key?(rule, key),
          do: "#{path}.#{key}: required for approved_claim"

    forbidden =
      for key <- ~w(fingerprint source),
          Map.has_key?(rule, key),
          do: "#{path}.#{key}: not allowed for approved_claim"

    evidence = rule["evidence"] || []
    goal_id = rule["goal_id"]

    citations =
      for citation <- evidence,
          citation["start_byte"] >= citation["end_byte"],
          do: "#{path}.evidence: citation must have a nonempty byte range"

    goal =
      if goal_id && not MapSet.member?(goals, goal_id),
        do: ["#{path}.goal_id: does not reference a supplied goal"],
        else: []

    basis =
      if missing == [] and evidence == [] and is_nil(goal_id),
        do: ["#{path}: evidence or an explicit goal is required"],
        else: []

    missing ++ forbidden ++ citations ++ goal ++ basis
  end

  defp rule_error(%{"origin" => origin} = rule, path, _goals) do
    missing =
      for key <- ~w(fingerprint source),
          not Map.has_key?(rule, key),
          do: "#{path}.#{key}: required for #{origin}"

    forbidden =
      for key <- ~w(revision_hash evidence goal_id),
          Map.has_key?(rule, key),
          do: "#{path}.#{key}: not allowed for #{origin}"

    single_line =
      if String.contains?(rule["statement"], ["\n", "\r"]),
        do: ["#{path}.statement: must be a single line for #{origin}"],
        else: []

    missing ++ forbidden ++ single_line ++ source_errors(rule["source"], path)
  end

  defp source_errors(%{"path" => path}, rule_path) when is_binary(path) do
    if Contracts.relative_path?(path),
      do: [],
      else: ["#{rule_path}.source.path: must be a contained relative path"]
  end

  defp source_errors(_, _), do: []

  @builtin_events %{"env_check" => "session_start", "locator" => "prompt_submit"}
  @selectors %{"format" => "changed_files", "lint" => "changed_files", "test" => "related_tests"}

  # Hook commands must come from the validated project commands, so a hook can
  # never carry a command that the profile did not declare. A `before_stop` hook with
  # a role may carry the argv prefix of a declared command (its trailing path
  # arguments removed), because its script appends the changed files. A built-in hook
  # carries no command at all: its script text belongs to the adapter.
  defp hook_errors(hooks, commands) do
    declared = commands |> Map.values() |> Enum.reject(&is_nil/1)

    hooks
    |> Enum.with_index()
    |> Enum.flat_map(fn {hook, index} -> hook_error(hook, "$.spec.hooks[#{index}]", declared) end)
  end

  defp hook_error(%{"builtin" => builtin, "event" => event}, path, _declared) do
    if @builtin_events[builtin] == event,
      do: [],
      else: ["#{path}.event: #{builtin} runs only on #{@builtin_events[builtin]}"]
  end

  defp hook_error(hook, path, declared) do
    role = hook["role"]
    staged? = is_binary(role) and hook["event"] == "before_stop"

    undeclared =
      if hook["command"] in declared or (staged? and declared_prefix?(hook["command"], declared)),
        do: [],
        else: ["#{path}.command: must be a declared project command"]

    shape =
      cond do
        is_nil(role) and is_nil(hook["selector"]) -> []
        not staged? -> ["#{path}.role: only before_stop hooks have a role"]
        @selectors[role] != hook["selector"] -> ["#{path}.selector: does not match the role"]
        true -> []
      end

    file_argument =
      if hook["file_argument"] and hook["event"] != "after_edit" and not staged?,
        do: ["#{path}.file_argument: only after_edit hooks and role hooks receive files"],
        else: []

    undeclared ++ shape ++ file_argument
  end

  defp declared_prefix?(command, declared) do
    words = String.split(command, " ")

    Enum.any?(declared, fn full ->
      full_words = String.split(full, " ")
      length(words) < length(full_words) and Enum.take(full_words, length(words)) == words
    end)
  end

  defp path_errors(spec) do
    layout =
      for {entry, index} <- Enum.with_index(spec["project"]["layout"]),
          not Contracts.relative_path?(entry["path"]),
          do: "$.spec.project.layout[#{index}].path: must be a contained relative path"

    patterns =
      for {entry, index} <- Enum.with_index(spec["permissions"]["paths"]),
          not Contracts.relative_path?(entry["pattern"]),
          do: "$.spec.permissions.paths[#{index}].pattern: must be a contained relative path"

    layout ++ patterns
  end
end
