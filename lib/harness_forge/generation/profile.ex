defmodule HarnessForge.Generation.Profile do
  @moduledoc """
  The RepoProfile contract between the analyzer and the engine
  (`priv/schemas/repo-profile-v1.json`, fixtures in `examples/profiles/`).

  A profile is string-keyed JSON. Commands are plain argv strings with no shell
  metacharacters, and they are never executed to verify them. Paths are relative
  to the repository root. The engine reads a profile and never the repository.

  `tools` (executables to probe per role), `test_pairs`, `cochange`,
  `paths_dropped_charset` and `practices` (integer counts and one boolean from the
  bounded practices read) are optional so older profiles still validate; a missing
  list means nothing was found. Pair paths use only `[A-Za-z0-9_./-]`.
  """

  alias HarnessForge.Contracts
  alias HarnessForge.Contracts.{Error, Signals}

  @schema_path Path.expand("../../../priv/schemas/repo-profile-v1.json", __DIR__)
  @external_resource @schema_path
  @schema @schema_path |> File.read!() |> Jason.decode!()
  @command_keys ~w(install build test test_single lint format typecheck run)

  @spec schema() :: map()
  def schema, do: @schema

  @spec command_keys() :: [String.t()]
  def command_keys, do: @command_keys

  @doc "A valid profile with nothing detected, for a repository that yields no facts."
  @spec empty(String.t()) :: map()
  def empty(name) when is_binary(name) do
    %{
      "name" => name,
      "languages" => [],
      "frameworks" => [],
      "package_managers" => [],
      "commands" => Map.new(@command_keys, &{&1, nil}),
      "layout" => [],
      "conventions" => [],
      "ci" => [],
      "existing_harness" => %{"files" => []},
      "rule_candidates" => [],
      "tools" => [],
      "test_pairs" => [],
      "cochange" => [],
      "paths_dropped_charset" => 0,
      "practices" => %{
        "deprecation_sites" => 0,
        "deprecation_files" => 0,
        "removal_phrases" => 0,
        "policy_sentences" => 0,
        "warnings_as_errors" => false
      }
    }
  end

  @spec digest(map()) :: String.t()
  def digest(profile) when is_map(profile), do: Contracts.digest(profile)

  @spec validate(term()) :: {:ok, map()} | {:error, Error.t()}
  def validate(profile) do
    with {:ok, profile} <- Contracts.validate_document(profile, @schema, "invalid_profile") do
      case semantic_errors(profile) do
        [] ->
          {:ok, profile}

        errors ->
          {:error,
           %Error{
             code: "invalid_profile",
             message: "Document failed contract validation",
             details: Enum.take(Enum.sort(errors), 100)
           }}
      end
    end
  end

  defp semantic_errors(profile) do
    layout =
      for {entry, index} <- Enum.with_index(profile["layout"]),
          not Contracts.relative_path?(entry["path"]),
          do: "$.layout[#{index}].path: must be a contained relative path"

    existing =
      for path <- profile["existing_harness"]["files"],
          not Contracts.relative_path?(path),
          do: "$.existing_harness.files: must be contained relative paths"

    candidates =
      profile["rule_candidates"]
      |> Enum.with_index()
      |> Enum.flat_map(fn {candidate, index} -> candidate_errors(candidate, index) end)

    pairs =
      for {row, index} <- Enum.with_index(profile["cochange"] || []),
          row["path"] == row["partner"],
          do: "$.cochange[#{index}].partner: must differ from path"

    tools =
      for {entry, index} <- Enum.with_index(profile["tools"] || []),
          entry["role"] != "interpreter" and not is_binary(entry["command"]),
          do: "$.tools[#{index}].command: required for #{entry["role"]}"

    layout ++ existing ++ candidates ++ pairs ++ tools
  end

  defp candidate_errors(candidate, index) do
    bucket =
      if candidate["bucket"] == Signals.bucket(candidate["confidence"]),
        do: [],
        else: ["$.rule_candidates[#{index}].bucket: does not match confidence"]

    citations =
      for citation <- candidate["citations"],
          is_binary(citation["path"]),
          not Contracts.relative_path?(citation["path"]),
          do: "$.rule_candidates[#{index}].citations: path must be a contained relative path"

    bucket ++ citations
  end
end
