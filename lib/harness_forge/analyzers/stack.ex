defmodule HarnessForge.Analyzers.Stack do
  @moduledoc """
  Languages, frameworks, package managers, CI systems and directory layout, from
  the file listing and manifests read as text.
  """

  alias HarnessForge.Analyzers.{Manifests, Paths, Signal}

  @detector "stack"
  @languages %{
    ".py" => "python",
    ".pyi" => "python",
    ".js" => "javascript",
    ".mjs" => "javascript",
    ".cjs" => "javascript",
    ".jsx" => "javascript",
    ".ts" => "typescript",
    ".tsx" => "typescript",
    ".ex" => "elixir",
    ".exs" => "elixir",
    ".erl" => "erlang",
    ".go" => "go",
    ".rs" => "rust",
    ".rb" => "ruby",
    ".java" => "java",
    ".kt" => "kotlin",
    ".c" => "c",
    ".h" => "c",
    ".cc" => "cpp",
    ".cpp" => "cpp",
    ".cs" => "csharp",
    ".php" => "php",
    ".swift" => "swift",
    ".scala" => "scala",
    # Not a programming language, but a tracked notebook keeps the notebook tool in the
    # lean context profile.
    ".ipynb" => "jupyter"
  }
  @python_frameworks ~w(django flask fastapi starlette tornado aiohttp sqlalchemy celery pydantic)
  @node_frameworks ~w(react next vue svelte fastify koa vite express @angular/core @nestjs/core)
  @mix_frameworks ~w(phoenix phoenix_live_view ecto oban)
  @manifest_names ~w(pyproject.toml setup.cfg setup.py tox.ini noxfile.py pytest.ini mypy.ini .flake8 package.json mix.exs Makefile makefile GNUmakefile justfile Justfile .justfile Cargo.toml go.mod .pre-commit-config.yaml Pipfile uv.lock poetry.lock pdm.lock Pipfile.lock package-lock.json pnpm-lock.yaml yarn.lock bun.lockb bun.lock .formatter.exs .credo.exs .gitlab-ci.yml .circleci/config.yml .travis.yml Jenkinsfile azure-pipelines.yml)
  @presence_only ~w(uv.lock poetry.lock pdm.lock Pipfile.lock package-lock.json pnpm-lock.yaml yarn.lock bun.lockb bun.lock)
  @ci_markers [
    {".gitlab-ci.yml", "gitlab-ci"},
    {".circleci/config.yml", "circleci"},
    {".travis.yml", "travis"},
    {"Jenkinsfile", "jenkins"},
    {"azure-pipelines.yml", "azure-pipelines"}
  ]
  @layout_directories [
    {"tests", "test suite"},
    {"test", "test suite"},
    {"spec", "test suite"},
    {"__tests__", "test suite"},
    {"e2e", "browser or end-to-end tests"},
    {"docs", "documentation"},
    {"doc", "documentation"},
    {"examples", "usage examples"},
    {"example", "usage examples"},
    {"changelog.d", "changelog fragments"},
    {"newsfragments", "changelog fragments"},
    {".changeset", "changelog fragments"},
    {"benchmarks", "benchmarks"},
    {"bench", "benchmarks"},
    {"scripts", "project scripts"},
    {"bin", "executables"},
    {"priv/repo/migrations", "database migrations"},
    {"migrations", "database migrations"},
    {"cmd", "Go command entry points"},
    {"internal", "Go internal packages"},
    {"pkg", "Go library packages"},
    {"crates", "Rust workspace members"},
    {".github/workflows", "CI workflows"}
  ]

  @doc "Manifest and CI files present in the listing."
  @spec manifest_paths([String.t()]) :: [String.t()]
  def manifest_paths(files) do
    Enum.filter(files, fn path ->
      path in @manifest_names or
        Regex.match?(~r/\A\.github\/workflows\/[^\/]+\.ya?ml\z/, path) or
        Regex.match?(~r/\A(?:requirements(?:[-_.][^\/]*)?|requirements\/[^\/]+)\.txt\z/, path)
    end)
  end

  @doc "The manifest and CI files that are opened. Lockfiles only need to exist."
  @spec paths_to_read([String.t()]) :: [String.t()]
  def paths_to_read(files) do
    files |> manifest_paths() |> Enum.reject(&(&1 in @presence_only))
  end

  @spec analyze([String.t()], map()) :: [map()]
  def analyze(files, contents) do
    file_set = MapSet.new(files)

    [
      languages(files),
      manifests(files),
      frameworks(contents),
      package_managers(file_set, contents),
      ci_systems(file_set, files),
      layout(files),
      test_convention(files)
    ]
    |> List.flatten()
  end

  defp languages(files) do
    counts =
      files
      |> Enum.reject(&vendored?/1)
      |> Enum.map(&Map.get(@languages, Path.extname(&1)))
      |> Enum.reject(&is_nil/1)
      |> Enum.frequencies()
      |> Enum.sort_by(fn {name, count} -> {-count, name} end)
      |> Enum.map(fn {name, count} -> %{"name" => name, "files" => count} end)

    Signal.new("stack.languages", %{"languages" => counts}, 95, @detector)
  end

  defp vendored?(path),
    do: String.starts_with?(path, ["vendor/", "third_party/", "node_modules/"])

  defp manifests(files) do
    paths = manifest_paths(files)

    Signal.new(
      "stack.manifests",
      %{"files" => paths},
      95,
      @detector,
      Enum.map(Enum.take(paths, 32), &Signal.file/1)
    )
  end

  defp frameworks(contents) do
    python =
      for {path, text} <- contents,
          String.ends_with?(path, ".txt") or path == "pyproject.toml",
          name <- python_names(path, text),
          name in @python_frameworks,
          uniq: true,
          do: name

    node =
      case contents["package.json"] && Manifests.package_json(contents["package.json"]) do
        nil -> []
        %{"dependencies" => deps} -> Enum.filter(@node_frameworks, &(&1 in deps))
      end

    mix =
      case contents["mix.exs"] do
        nil -> []
        text -> Enum.filter(@mix_frameworks, &(&1 in Manifests.mix_dependencies(text)))
      end

    names = (python ++ node ++ mix) |> Enum.uniq() |> Enum.sort()
    Signal.new("stack.frameworks", %{"frameworks" => names}, 90, @detector)
  end

  defp python_names("pyproject.toml", text) do
    sections = Manifests.toml(text)
    groups = sections |> Manifests.dependency_groups() |> Map.values() |> List.flatten()
    Manifests.python_dependencies(sections) ++ groups
  end

  defp python_names(_path, text), do: Manifests.requirement_names(text)

  defp package_managers(files, contents) do
    markers = [
      {"uv.lock", "uv"},
      {"poetry.lock", "poetry"},
      {"pdm.lock", "pdm"},
      {"Pipfile.lock", "pipenv"},
      {"pnpm-lock.yaml", "pnpm"},
      {"yarn.lock", "yarn"},
      {"bun.lockb", "bun"},
      {"bun.lock", "bun"},
      {"package-lock.json", "npm"},
      {"Cargo.toml", "cargo"},
      {"go.mod", "go-modules"},
      {"mix.exs", "hex"}
    ]

    found = for {file, name} <- markers, MapSet.member?(files, file), do: name

    implicit =
      cond do
        contents["package.json"] && not Enum.any?(found, &(&1 in ~w(pnpm yarn bun npm))) ->
          ["npm"]

        true ->
          []
      end

    python =
      cond do
        Enum.any?(found, &(&1 in ~w(uv poetry pdm pipenv))) ->
          []

        contents["pyproject.toml"] || contents["requirements.txt"] || contents["setup.py"] ->
          ["pip"]

        true ->
          []
      end

    Signal.new(
      "stack.package_managers",
      %{"package_managers" => Enum.sort(Enum.uniq(found ++ implicit ++ python))},
      90,
      @detector
    )
  end

  defp ci_systems(file_set, files) do
    github =
      if Enum.any?(files, &String.starts_with?(&1, ".github/workflows/")),
        do: ["github-actions"],
        else: []

    others = for {marker, name} <- @ci_markers, MapSet.member?(file_set, marker), do: name
    Signal.new("ci.systems", %{"systems" => Enum.sort(github ++ others)}, 95, @detector)
  end

  defp layout(files) do
    packages = python_packages(files)
    library = source_directories(files, packages)

    known =
      for {directory, purpose} <- @layout_directories,
          count = count_under(files, directory),
          count > 0,
          do: %{"path" => directory, "purpose" => purpose, "files" => count}

    entries = (packages ++ library ++ known) |> Enum.uniq_by(& &1["path"]) |> Enum.take(40)

    Signal.new(
      "layout.paths",
      %{"entries" => entries},
      85,
      @detector,
      Enum.map(Enum.take(entries, 32), &Signal.file(&1["path"]))
    )
  end

  defp count_under(files, directory) do
    prefix = directory <> "/"
    Enum.count(files, &String.starts_with?(&1, prefix))
  end

  defp python_packages(files) do
    packages =
      files
      |> Enum.flat_map(fn path ->
        case Regex.run(~r/\A(?:src\/)?([A-Za-z_][A-Za-z0-9_]*)\/__init__\.py\z/, path) do
          [match, name] when name not in ~w(tests test docs examples) ->
            [String.trim_trailing(match, "/__init__.py")]

          _ ->
            []
        end
      end)
      |> Enum.uniq()

    Enum.map(packages, fn package ->
      %{
        "path" => package,
        "purpose" => "Python package source",
        "files" => count_under(files, package)
      }
    end)
  end

  defp source_directories(files, packages) do
    taken = MapSet.new(packages |> Enum.map(& &1["path"]))

    elixir =
      files
      |> Enum.flat_map(fn path ->
        case Regex.run(~r/\Alib\/([a-z_][a-z0-9_]*)\/.+\.ex\z/, path) do
          [_, name] -> ["lib/" <> name]
          _ -> []
        end
      end)
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(taken, &1))
      |> Enum.take(12)
      |> Enum.map(fn dir ->
        purpose =
          if String.ends_with?(dir, "_web"),
            do: "Phoenix web layer",
            else: "Elixir application code"

        %{"path" => dir, "purpose" => purpose, "files" => count_under(files, dir)}
      end)

    plain =
      for {directory, purpose} <- [{"lib", "library source"}, {"src", "application source"}],
          count = count_under(files, directory),
          count > 0,
          not Enum.any?(taken, &String.starts_with?(&1, directory)),
          elixir == [] or directory != "lib",
          do: %{"path" => directory, "purpose" => purpose, "files" => count}

    packages ++ elixir ++ plain
  end

  defp test_convention(files) do
    tests = Enum.filter(files, &Paths.test_path?/1)

    case tests do
      [] ->
        []

      _ ->
        directory =
          tests
          |> Enum.map(&(&1 |> String.split("/") |> hd()))
          |> Enum.frequencies()
          |> Enum.sort_by(fn {name, count} -> {-count, name} end)
          |> hd()
          |> elem(0)

        inside =
          Enum.filter(
            tests,
            &(String.starts_with?(&1, directory <> "/") and Paths.code_path?(&1))
          )

        {pattern, matching} =
          [
            {"test_*.py", ~r/\/test_[^\/]+\.py$/},
            {"*_test.py", ~r/_test\.py$/},
            {"*.test.js", ~r/\.test\.[jt]sx?$/},
            {"*.spec.js", ~r/\.spec\.[jt]sx?$/},
            {"*_test.exs", ~r/_test\.exs$/},
            {"*_test.go", ~r/_test\.go$/}
          ]
          |> Enum.map(fn {pattern, regex} ->
            {pattern, Enum.count(inside, &Regex.match?(regex, &1))}
          end)
          |> Enum.max_by(&elem(&1, 1), fn -> {nil, 0} end)

        if matching == 0 do
          []
        else
          rate = Signal.percent(matching, length(inside))

          value = %{
            "directory" => directory,
            "pattern" => pattern,
            "matching" => matching,
            "total" => length(inside),
            "percent" => rate
          }

          [Signal.new("conventions.tests", value, rate, @detector, [Signal.file(directory)])]
        end
    end
  end
end
