defmodule HarnessForge.Company.Validation do
  @moduledoc false
  alias HarnessForge.Company.{Profile, Repository, Project}
  @templates ~w(reviewed-change-v1 reuse-before-build-v1)
  @plan_fields ~w(name package_version project_id repository_ids claim_refs goal_ids template_ids runtime runtime_version execution milestones)

  def catalog(schema, attrs) do
    {required, strings, arrays} =
      case schema do
        Profile ->
          {~w(name), ~w(name description), ~w(source_ids goal_ids)}

        Repository ->
          {~w(identity name purpose owner), ~w(identity name purpose owner version_strategy),
           ~w(capabilities interfaces dependency_ids examples)}

        Project ->
          {~w(name repository_ids), ~w(name description), ~w(repository_ids source_ids goal_ids)}
      end

    with true <- keys?(attrs, strings ++ arrays ++ ["expected_content_hash"]),
         true <- Enum.all?(required, &Map.has_key?(attrs, &1)),
         payload = Map.drop(attrs, ["expected_content_hash"]),
         payload = Enum.reduce(strings, payload, &Map.put_new(&2, &1, "")),
         payload = Enum.reduce(arrays, payload, &Map.put_new(&2, &1, [])),
         true <- Enum.all?(strings, &text?(payload[&1], string_limit(&1), &1 in required)),
         true <- Enum.all?(arrays, &catalog_array?(&1, payload[&1])),
         true <- schema != Repository or identity?(payload["identity"]),
         expected = attrs["expected_content_hash"],
         true <- is_nil(expected) or digest?(expected) do
      {:ok, sort_arrays(payload, arrays), expected}
    else
      _ -> {:error, :invalid_input}
    end
  end

  def plan(attrs) do
    with true <- keys?(attrs, @plan_fields ++ ["supersedes_id"]),
         true <- Enum.all?(@plan_fields -- ["milestones"], &Map.has_key?(attrs, &1)),
         attrs = Map.put_new(attrs, "milestones", []),
         true <- plan_name_valid?(attrs["name"]),
         true <- version?(attrs["package_version"]),
         true <- uuid?(attrs["project_id"]),
         true <- ids?(attrs["repository_ids"], 100) and attrs["repository_ids"] != [],
         true <- ids?(attrs["goal_ids"], 100),
         true <- list?(attrs["claim_refs"], 500) and attrs["claim_refs"] != [],
         true <- Enum.all?(attrs["claim_refs"], &claim_ref?/1),
         true <- unique?(Enum.map(attrs["claim_refs"], & &1["id"])),
         true <- list?(attrs["template_ids"], 2) and attrs["template_ids"] != [],
         true <- Enum.all?(attrs["template_ids"], &(&1 in @templates)),
         true <- attrs["runtime"] in ~w(opencode codex claude_code),
         true <- text?(attrs["runtime_version"], 64, true),
         true <- execution?(attrs["execution"]),
         true <- milestones?(attrs["milestones"], attrs["goal_ids"]),
         true <- is_nil(attrs["supersedes_id"]) or uuid?(attrs["supersedes_id"]) do
      payload =
        attrs
        |> Map.take(@plan_fields)
        |> sort_arrays(~w(repository_ids goal_ids template_ids))
        |> Map.update!("claim_refs", &Enum.sort_by(&1, fn ref -> ref["id"] end))
        |> Map.update!("milestones", fn milestones ->
          milestones
          |> Enum.map(&sort_arrays(&1, ~w(goal_ids depends_on)))
          |> Enum.sort_by(& &1["id"])
        end)

      {:ok, payload, attrs["supersedes_id"]}
    else
      _ -> {:error, :invalid_input}
    end
  end

  @doc "Checks the existing package-name rule without normalizing the supplied value."
  @spec plan_name_valid?(term()) :: boolean()
  def plan_name_valid?(value), do: slug?(value)

  def decision(attrs) do
    if keys?(attrs, ~w(actor decision expected_revision_hash)) and
         text?(attrs["actor"], 256, true) and attrs["decision"] in ~w(approve reject) and
         digest?(attrs["expected_revision_hash"]), do: :ok, else: {:error, :invalid_input}
  end

  defp milestones?(values, goals) do
    list?(values, 100) and Enum.all?(values, &milestone?(&1, goals)) and
      unique?(Enum.map(values, & &1["id"])) and
      acyclic?(Map.new(values, &{&1["id"], &1["depends_on"]}))
  end

  defp milestone?(value, goals) do
    keys = ~w(id title goal_ids depends_on acceptance evaluation_method target_version)

    keys?(value, keys) and Enum.all?(keys, &Map.has_key?(value, &1)) and
      slug?(value["id"]) and text?(value["title"], 256, true) and
      ids?(value["goal_ids"], 100) and Enum.all?(value["goal_ids"], &(&1 in goals)) and
      list?(value["depends_on"], 100) and Enum.all?(value["depends_on"], &slug?/1) and
      text?(value["acceptance"], 4096, true) and text?(value["evaluation_method"], 4096, true) and
      text?(value["target_version"], 64, false)
  end

  def acyclic?(graph) do
    if Enum.all?(graph, fn {_, edges} -> Enum.all?(edges, &Map.has_key?(graph, &1)) end) do
      drain(graph)
    else
      false
    end
  end

  defp drain(graph) when map_size(graph) == 0, do: true

  defp drain(graph) do
    leaves = for {id, []} <- graph, do: id

    if leaves == [],
      do: false,
      else:
        graph |> Map.drop(leaves) |> Map.new(fn {id, deps} -> {id, deps -- leaves} end) |> drain()
  end

  defp claim_ref?(ref),
    do: keys?(ref, ~w(id revision_hash)) and uuid?(ref["id"]) and digest?(ref["revision_hash"])

  defp execution?(value),
    do:
      keys?(value, ~w(max_turns timeout_seconds)) and integer?(value["max_turns"], 1, 1000) and
        integer?(value["timeout_seconds"], 1, 86400)

  defp integer?(value, min, max), do: is_integer(value) and value >= min and value <= max

  defp keys?(value, allowed),
    do: is_map(value) and not is_struct(value) and Enum.all?(Map.keys(value), &(&1 in allowed))

  defp list?(value, max), do: is_list(value) and length(value) <= max and unique?(value)
  defp unique?(values), do: length(values) == length(Enum.uniq(values))
  defp ids?(value, max), do: list?(value, max) and Enum.all?(value, &uuid?/1)

  defp uuid?(value),
    do:
      is_binary(value) and
        Regex.match?(~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/, value)

  defp digest?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
  defp slug?(value), do: text?(value, 64, true) and Regex.match?(~r/\A[a-z][a-z0-9_-]*\z/, value)

  defp version?(value),
    do:
      text?(value, 64, true) and
        Regex.match?(~r/\A[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?\z/, value)

  defp identity?(value),
    do:
      text?(value, 1024, true) and
        Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]*(\/[A-Za-z0-9][A-Za-z0-9._-]*)*\z/, value)

  defp text?(value, max, required),
    do:
      is_binary(value) and byte_size(value) <= max * 4 and String.valid?(value) and
        String.length(value) <= max and (not required or String.trim(value) != "")

  defp string_limit("identity"), do: 1024
  defp string_limit(field) when field in ~w(name owner), do: 256
  defp string_limit(_), do: 4096

  defp catalog_array?(field, value) when field in ~w(capabilities interfaces examples),
    do: list?(value, 100) and Enum.all?(value, &text?(&1, 4096, true))

  defp catalog_array?(_, value), do: ids?(value, 100)

  defp sort_arrays(payload, arrays),
    do: Enum.reduce(arrays, payload, &Map.update!(&2, &1, fn value -> Enum.sort(value) end))
end
