defmodule HarnessForge.Analyzers.Paths do
  @moduledoc "Classifies repository paths as test, source or changelog files."

  @source_extensions ~w(.py .pyi .js .jsx .mjs .cjs .ts .tsx .ex .exs .erl .go .rs .rb .java .kt .c .h .cc .cpp .hpp .cs .php .swift .scala .lua .sh)
  @not_source_directories ~w(docs doc examples example benchmarks benchmark bench .github)
  @changelog_stem ~r/\A(?:changes|changelog|history|news)\z/i
  @fragment_directories ~w(changelog.d newsfragments changes .changeset)

  @spec test_path?(String.t()) :: boolean()
  def test_path?(path) do
    {directories, name} = split(path)

    Enum.any?(directories, &(String.downcase(&1) in ~w(tests test __tests__ spec))) or
      Regex.match?(
        ~r/\A(?:test_.+\.py|.+_test\.(?:py|go|exs|rb)|conftest\.py|.+\.(?:test|spec)\.[a-z]+|.+_spec\.rb)\z/,
        name
      )
  end

  @spec source_path?(String.t()) :: boolean()
  def source_path?(path) do
    {directories, _name} = split(path)

    Path.extname(path) in @source_extensions and not test_path?(path) and
      not Enum.any?(directories, &(String.downcase(&1) in @not_source_directories))
  end

  @spec code_path?(String.t()) :: boolean()
  def code_path?(path), do: Path.extname(path) in @source_extensions

  @doc "The changelog file or fragment directory a path belongs to, or nil."
  @spec changelog_target(String.t()) :: String.t() | nil
  def changelog_target(path) do
    {directories, name} = split(path)

    cond do
      directories != [] and hd(directories) in @fragment_directories ->
        hd(directories) <> "/"

      directories == [] and Regex.match?(@changelog_stem, Path.rootname(name)) ->
        name

      true ->
        nil
    end
  end

  defp split(path) do
    parts = String.split(path, "/")
    {Enum.drop(parts, -1), List.last(parts)}
  end
end
