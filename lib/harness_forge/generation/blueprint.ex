defmodule HarnessForge.Generation.Blueprint do
  @moduledoc """
  Data-driven package defaults from `priv/blueprints/`: a base file plus one file
  per stack. Text carries placeholders such as `{{commands.test}}`.

  A line whose placeholder has no value is left out, and an agent or skill whose
  `requires` entries have no value is left out entirely, so a repository with no
  detected commands gets no filler. Blueprints are read at compile time; generation
  never touches the filesystem.
  """

  @directory Path.expand("../../../priv/blueprints", __DIR__)
  @names ~w(base elixir node python)
  @stacks %{
    "elixir" => "elixir",
    "python" => "python",
    "typescript" => "node",
    "javascript" => "node"
  }
  @placeholder ~r/\{\{([a-z_.]+)\}\}/

  for name <- @names do
    @external_resource Path.join(@directory, name <> ".json")
  end

  @blueprints Map.new(@names, fn name ->
                {name,
                 @directory |> Path.join(name <> ".json") |> File.read!() |> Jason.decode!()}
              end)

  @doc "The base blueprint overlaid with the first stack the profile's languages name."
  @spec select(map()) :: map()
  def select(%{"languages" => languages}) do
    stack = Enum.find_value(languages, &Map.get(@stacks, String.downcase(&1)))
    base = @blueprints["base"]

    if stack, do: Map.merge(base, @blueprints[stack]), else: base
  end

  @spec version(map()) :: String.t()
  def version(%{"id" => id, "version" => version}), do: id <> "@" <> version

  @doc "Fill an agent or skill entry from a profile, or nil when it should be left out."
  @spec render(map(), map()) :: map() | nil
  def render(%{"requires" => requires} = entry, profile) do
    if Enum.all?(requires, &value(&1, profile)) do
      %{
        "name" => entry["name"],
        "description" => fill(entry["description"], profile) || entry["name"],
        "instructions" =>
          entry["instructions"]
          |> Enum.map(&fill(&1, profile))
          |> Enum.reject(&is_nil/1)
          |> Enum.join("\n")
      }
    end
  end

  @doc "Placeholder keys used by a blueprint entry. Used to keep the data honest in tests."
  @spec placeholders(String.t()) :: [String.t()]
  def placeholders(text) do
    @placeholder |> Regex.scan(text, capture: :all_but_first) |> List.flatten()
  end

  @doc "All shipped blueprints by name."
  @spec all() :: map()
  def all, do: @blueprints

  defp fill(text, profile) do
    values = text |> placeholders() |> Map.new(&{&1, value(&1, profile)})

    if Enum.any?(values, fn {_key, item} -> is_nil(item) end),
      do: nil,
      else: Regex.replace(@placeholder, text, fn _match, key -> values[key] end)
  end

  defp value("commands." <> key, profile), do: profile["commands"][key]
  defp value("project.name", profile), do: profile["name"]
  defp value(_key, _profile), do: nil
end
