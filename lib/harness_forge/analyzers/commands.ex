defmodule HarnessForge.Analyzers.Commands do
  @moduledoc """
  Finds the project's own install, build, test, lint, format and typecheck commands.

  Candidates are collected from CI run lines, contributor documents, tool and manifest
  configuration, and finally ecosystem convention, in descending confidence. CI wrappers
  such as tox and pre-commit are resolved to the tool they run, because that is what a
  person or agent runs locally. Commands are text from the repository: they are detected
  and written out and are never executed.
  """

  alias HarnessForge.Analyzers.{Manifests, Privacy, Signal}

  @detector "stack.commands"
  @keys ~w(install build test test_single lint format typecheck run)
  @command ~r/\A[A-Za-z0-9_.\/][A-Za-z0-9_.\/:=@+,-]*(?: [A-Za-z0-9_.\/:=@+,-]+)*\z/

  @ci 90
  @ci_wrapped 88
  @contributing 85
  @manifest 80
  @wrapper 78
  @lockfile 78
  @ecosystem 75
  @tool_config 72

  @noise_exact ~w(-v -vv -vvv -q -qq -ra -rA -s --verbose --quiet --cov --cov-append --cov-branch --no-cov -x --exitfirst)
  @noise_prefix ~w(--tb= --color= --basetemp= --junitxml= --junit-xml= --cov= --cov-report= --cov-config= --cov-fail-under= --durations= --numprocesses= -p=)
  @noise_with_value ~w(--tb --color --basetemp --cov-report -n -p --numprocesses --durations)
  @subset_flags ~w(-k -m --lf --ff --last-failed --failed-first)
  @check_flags ~w(--check --check-only --check-formatted --diff --exit-non-zero-on-format --exit-non-zero-on-fix)
  @lint_noise ~w(--fix --fix-only --unsafe-fixes --exit-non-zero-on-fix --show-fixes)
  @uv_flags_with_value ~w(--group --extra --with --python --project --directory --env-file --index)
  @python_tools ~w(pytest ruff flake8 pylint black mypy pyright ty pyrefly pre-commit prek tox nox)
  @package_script ~r/\A(?:npm|pnpm|yarn|bun) (?:test|run [A-Za-z0-9:._-]+)\z/
  @test_slice ~r/(?:\A|[ :._-])(?:browser|browsers|e2e|smoke|module|modules|integration|playwright|cypress|headless|watch|bench|benchmark|perf|visual|dist|bundle|types|coverage|cov|report|clean|lint|build|install|setup|prepare)(?:\z|[:._-])/
  # Test tools whose command line takes test files (after the tool and its own flags),
  # as a package script may call them: the file form of such a script is the script
  # with the files appended (`npm run <script> -- <file>`).
  @file_test_tools [
    ["vitest", "run"],
    ["vitest"],
    ["jest"],
    ["mocha"],
    ["ava"],
    ["tap"],
    ["node", "--test"]
  ]
  @script_word ~r/\A[A-Za-z0-9_.\/:=@+,%-]+\z/
  @script_path_words ~w(test tests spec specs src lib)

  @hook_tools %{
    "ruff" => {"lint", ~w(ruff check)},
    "ruff-check" => {"lint", ~w(ruff check)},
    "ruff-format" => {"format", ~w(ruff format)},
    "black" => {"format", ~w(black)},
    "flake8" => {"lint", ~w(flake8)},
    "pylint" => {"lint", ~w(pylint)},
    "mypy" => {"typecheck", ~w(mypy)},
    "pyright" => {"typecheck", ~w(pyright)},
    "eslint" => {"lint", ~w(npx eslint)},
    "prettier" => {"format", ~w(npx prettier --write)},
    "clippy" => {"lint", ~w(cargo clippy)},
    "fmt" => {"format", ~w(cargo fmt)},
    "golangci-lint" => {"lint", ~w(golangci-lint run)},
    "go-fmt" => {"format", ~w(gofmt -w)}
  }

  @doc """
  Detect commands. `documents` maps contributor-document paths to their text and is
  searched for runnable commands. Returns signals in key order.
  """
  @spec detect(MapSet.t(String.t()), map(), map()) :: [map()]
  def detect(files, contents, documents) do
    context = context(files, contents)

    candidates =
      ci(context, contents) ++
        contributor(context, documents) ++
        manifests(context, contents) ++ conventions(context, contents)

    selected =
      candidates
      |> Enum.filter(&usable?(&1.command))
      |> Enum.group_by(& &1.key)
      |> select(context)

    selected ++ tools(selected, context, contents)
  end

  @interpreter_files ~w(.python-version .python-version-default)

  @doc """
  The files that pin a development interpreter, to be read with the manifests:
  `.python-version` (read by uv and pyenv) and `.python-version-default` (a pin some
  projects keep under that name so uv does not pick it up, and point CI at with
  `python-version-file`).
  """
  @spec interpreter_paths([String.t()]) :: [String.t()]
  def interpreter_paths(files), do: Enum.filter(@interpreter_files, &(&1 in files))

  @doc "CI run lines that are plain commands, for the record."
  @spec ci_runs(map()) :: [map()]
  def ci_runs(contents) do
    workflows(contents)
    |> Enum.flat_map(fn {path, text} ->
      for %{line: line, command: command} <- Manifests.workflow_runs(text),
          clean = clean_tokens(command) |> Enum.join(" "),
          usable?(clean),
          do: %{"path" => path, "line" => line, "command" => clean}
    end)
  end

  defp usable?(command) do
    byte_size(command) <= 512 and Regex.match?(@command, command) and
      not Privacy.secret?(command) and not absolute_path?(command)
  end

  # A CI-only path such as /home/runner/cov.out does not exist on a developer's machine
  # and must not reach the output.
  defp absolute_path?(command) do
    command |> String.split(" ") |> Enum.any?(&Regex.match?(~r{^(?:[^=/]*=)?/}, &1))
  end

  defp workflows(contents) do
    contents
    |> Enum.filter(fn {path, _} -> String.starts_with?(path, ".github/workflows/") end)
    |> Enum.sort()
  end

  defp clean_tokens(command) do
    command
    |> String.split()
    |> Enum.drop_while(&Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*=/, &1))
  end

  # Context

  defp context(files, contents) do
    sections =
      case contents["pyproject.toml"] do
        nil -> %{}
        text -> Manifests.toml(text)
      end

    tox_ini = if contents["tox.ini"], do: Manifests.tox_ini(contents["tox.ini"]), else: []
    tox_toml = Manifests.tox_toml(sections)

    {tox, tox_path} =
      if tox_ini == [], do: {tox_toml, "pyproject.toml"}, else: {tox_ini, "tox.ini"}

    package = contents["package.json"] && Manifests.package_json(contents["package.json"])

    hooks =
      case contents[".pre-commit-config.yaml"] do
        nil -> []
        text -> Manifests.pre_commit_hooks(text)
      end

    default_groups =
      case Manifests.toml_value(sections, "tool.uv", "default-groups") do
        {_, raw} -> Manifests.strings(raw)
        nil -> ["dev"]
      end

    %{
      files: files,
      sections: sections,
      tox: tox,
      tox_path: tox_path,
      hooks: hooks,
      scripts: (package && package["scripts"]) || %{},
      package?: package != nil,
      node_manager: node_manager(files),
      python_manager: python_manager(files, contents),
      groups: Manifests.dependency_groups(sections),
      default_groups: default_groups,
      python_dependencies: Manifests.python_dependencies(sections)
    }
  end

  defp node_manager(files) do
    cond do
      MapSet.member?(files, "pnpm-lock.yaml") -> "pnpm"
      MapSet.member?(files, "yarn.lock") -> "yarn"
      MapSet.member?(files, "bun.lockb") or MapSet.member?(files, "bun.lock") -> "bun"
      true -> "npm"
    end
  end

  defp python_manager(files, contents) do
    cond do
      MapSet.member?(files, "uv.lock") -> "uv"
      MapSet.member?(files, "poetry.lock") -> "poetry"
      MapSet.member?(files, "pdm.lock") -> "pdm"
      MapSet.member?(files, "Pipfile.lock") -> "pipenv"
      contents["pyproject.toml"] || requirements(files) != [] -> "pip"
      true -> nil
    end
  end

  defp requirements(files) do
    files
    |> Enum.filter(
      &Regex.match?(~r/\A(?:requirements(?:[-_.][^\/]*)?|requirements\/[^\/]+)\.txt\z/, &1)
    )
    |> Enum.sort()
  end

  # Sources

  defp ci(context, contents) do
    for {path, text} <- workflows(contents),
        %{line: line, command: command} <- Manifests.workflow_root_runs(text),
        {key, detected, extra, wrapped?} <- interpret(command, context),
        do:
          candidate(
            key,
            detected,
            "ci",
            if(wrapped?, do: @ci_wrapped, else: @ci),
            [{path, line} | extra]
          )
  end

  defp contributor(context, documents) do
    for {path, text} <- Enum.sort(documents),
        {line, command} <- code_mentions(text),
        {key, detected, extra, _} <- interpret(command, context),
        do:
          candidate(
            key,
            detected,
            "contributing",
            penalty(key, detected, context, @contributing),
            [{path, line} | extra]
          )
  end

  # A contributor guide that also lists an alternative for people outside the project's
  # own package manager must not beat the lockfile.
  defp penalty("install", command, %{python_manager: "uv"}, confidence) do
    if String.starts_with?(command, "uv "), do: confidence, else: confidence - 20
  end

  defp penalty(_key, _command, _context, confidence), do: confidence

  defp code_mentions(text) do
    text
    |> Manifests.numbered()
    |> Enum.reduce({[], false}, fn {number, line}, {found, fenced} ->
      trimmed = String.trim(line)

      cond do
        String.starts_with?(trimmed, ["```", "~~~"]) ->
          {found, not fenced}

        fenced ->
          {[{number, trimmed |> String.trim_leading("$ ")} | found], true}

        String.starts_with?(trimmed, "$ ") ->
          {[{number, String.trim_leading(trimmed, "$ ")} | found], false}

        true ->
          spans =
            Regex.scan(~r/`{1,2}([^`]+)`{1,2}/, line, capture: :all_but_first)
            |> List.flatten()
            |> Enum.map(&{number, String.trim_leading(&1, "$ ")})

          {Enum.reverse(spans) ++ found, false}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp manifests(context, contents) do
    scripts(context) ++
      make(contents) ++
      just(contents) ++ nox(contents) ++ pre_commit(context) ++ tox_direct(context)
  end

  defp scripts(%{package?: false}), do: []

  defp scripts(context) do
    for {name, {body, line}} <- Enum.sort(context.scripts),
        key = script_key(name),
        key != nil,
        not placeholder?(body),
        do:
          candidate(key, script_command(context.node_manager, name, key), "manifest", @manifest, [
            {"package.json", line}
          ])
  end

  defp placeholder?(body), do: String.contains?(body, "no test specified")

  defp make(contents) do
    for path <- ["Makefile", "makefile", "GNUmakefile"],
        text = contents[path],
        text != nil,
        %{line: line, name: name} <- Manifests.make_targets(text),
        key = target_key(name),
        key != nil,
        do: candidate(key, "make " <> name, "manifest", @manifest, [{path, line}])
  end

  defp just(contents) do
    for path <- ["justfile", "Justfile", ".justfile"],
        text = contents[path],
        text != nil,
        %{line: line, name: name} <- Manifests.just_recipes(text),
        key = target_key(name),
        key != nil,
        do: candidate(key, "just " <> name, "manifest", @manifest, [{path, line}])
  end

  defp nox(contents) do
    case contents["noxfile.py"] do
      nil ->
        []

      text ->
        for name <- Manifests.nox_sessions(text),
            key = target_key(name),
            key != nil,
            do: candidate(key, "nox -s " <> name, "manifest", @wrapper, [{"noxfile.py", nil}])
    end
  end

  defp tox_direct(%{tox: []}), do: []

  defp tox_direct(context) do
    entries = select_tox(context.tox, :base)

    named =
      Enum.filter(context.tox, fn entry ->
        entry.env != "testenv" and
          Enum.any?(segments(entry.env), &(&1 in ~w(lint style typing mypy type)))
      end)

    for entry <- entries ++ named,
        {key, detected, _extra, _} <- interpret(entry.command, %{context | tox: []}),
        do: candidate(key, detected, "manifest", @wrapper, [{context.tox_path, entry.line}])
  end

  defp pre_commit(context) do
    for %{id: id, line: line} <- context.hooks,
        {key, tokens} <- [Map.get(@hook_tools, id)],
        do:
          candidate(key, runnable(tokens, context), "manifest", @wrapper, [
            {".pre-commit-config.yaml", line}
          ])
  end

  defp conventions(context, contents) do
    python_conventions(context, contents) ++
      node_conventions(context) ++
      elixir_conventions(context, contents) ++
      rust_conventions(context) ++ go_conventions(context)
  end

  defp python_conventions(%{python_manager: nil}, _), do: []

  defp python_conventions(context, contents) do
    files = context.files
    manager = context.python_manager
    sections = context.sections

    install =
      case manager do
        "uv" -> [{"install", "uv sync", @lockfile, "uv.lock"}]
        "poetry" -> [{"install", "poetry install", @lockfile, "poetry.lock"}]
        "pdm" -> [{"install", "pdm install", @lockfile, "pdm.lock"}]
        "pipenv" -> [{"install", "pipenv sync --dev", @lockfile, "Pipfile.lock"}]
        "pip" -> pip_install(files, contents)
      end

    build =
      if Map.has_key?(sections, "build-system") and manager in ~w(uv poetry pdm),
        do: [{"build", manager <> " build", @tool_config, "pyproject.toml"}],
        else: []

    pytest? =
      Map.has_key?(sections, "tool.pytest.ini_options") or MapSet.member?(files, "pytest.ini") or
        MapSet.member?(files, "conftest.py") or MapSet.member?(files, "tests/conftest.py") or
        declared?("pytest", context, contents)

    tools =
      Enum.filter(
        [
          {"test", ~w(pytest), pytest?},
          {"lint", ~w(ruff check), config?(context, "tool.ruff", "ruff")},
          {"format", ~w(ruff format), config?(context, "tool.ruff", "ruff")},
          {"format", ~w(black), config?(context, "tool.black", "black")},
          {"typecheck", ~w(mypy),
           config?(context, "tool.mypy", "mypy") or MapSet.member?(files, "mypy.ini")},
          {"lint", ~w(flake8), MapSet.member?(files, ".flake8")}
        ],
        &elem(&1, 2)
      )

    Enum.map(install ++ build, fn {key, command, confidence, path} ->
      candidate(key, command, "convention", confidence, [{path, nil}])
    end) ++
      Enum.map(tools, fn {key, tokens, _} ->
        candidate(key, runnable(tokens, context), "convention", @tool_config, [
          {"pyproject.toml", nil}
        ])
      end)
  end

  defp pip_install(files, _contents) do
    case requirements(files) do
      [] ->
        [{"install", "pip install -e .", 60, "pyproject.toml"}]

      paths ->
        [
          {"install", "pip install -r " <> preferred_requirements(paths), @tool_config,
           preferred_requirements(paths)}
        ]
    end
  end

  defp preferred_requirements(paths) do
    Enum.find(paths, List.first(paths), &String.contains?(&1, "dev"))
  end

  defp declared?(tool, context, contents) do
    tool in context.python_dependencies or
      Enum.any?(context.groups, fn {_, deps} -> tool in deps end) or
      Enum.any?(contents, fn {path, text} ->
        String.ends_with?(path, ".txt") and String.contains?(path, "requirements") and
          tool in Manifests.requirement_names(text)
      end)
  end

  defp config?(context, section, tool) do
    Map.has_key?(context.sections, section) and
      (tool in context.python_dependencies or
         Enum.any?(context.groups, fn {_, deps} -> tool in deps end) or context.groups == %{})
  end

  defp node_conventions(%{package?: false}), do: []

  defp node_conventions(context) do
    files = context.files

    command =
      case context.node_manager do
        "npm" -> if(MapSet.member?(files, "package-lock.json"), do: "npm ci", else: "npm install")
        "pnpm" -> "pnpm install --frozen-lockfile"
        "yarn" -> "yarn install --frozen-lockfile"
        "bun" -> "bun install --frozen-lockfile"
      end

    [candidate("install", command, "convention", @lockfile, [{"package.json", nil}])]
  end

  defp elixir_conventions(context, contents) do
    case contents["mix.exs"] do
      nil -> []
      text -> mix_candidates(Manifests.mix_dependencies(text), context.files)
    end
  end

  defp mix_candidates(deps, files) do
    base = [
      {"install", "mix deps.get", @manifest},
      {"build", "mix compile", @ecosystem},
      {"format", "mix format",
       if(MapSet.member?(files, ".formatter.exs"), do: 85, else: @ecosystem)}
    ]

    tests =
      if Enum.any?(files, &String.starts_with?(&1, "test/")),
        do: [{"test", "mix test", @manifest}],
        else: []

    credo = if "credo" in deps, do: [{"lint", "mix credo --strict", @ecosystem}], else: []
    dialyzer = if "dialyxir" in deps, do: [{"typecheck", "mix dialyzer", @ecosystem}], else: []
    run = if "phoenix" in deps, do: [{"run", "mix phx.server", @ecosystem}], else: []

    Enum.map(base ++ tests ++ credo ++ dialyzer ++ run, fn {key, command, confidence} ->
      candidate(key, command, "convention", confidence, [{"mix.exs", nil}])
    end)
  end

  defp rust_conventions(context) do
    if MapSet.member?(context.files, "Cargo.toml") do
      [
        {"build", "cargo build", @ecosystem},
        {"test", "cargo test", @ecosystem},
        {"format", "cargo fmt", @ecosystem},
        {"lint", "cargo clippy", @tool_config}
      ]
      |> Enum.map(fn {key, command, confidence} ->
        candidate(key, command, "convention", confidence, [{"Cargo.toml", nil}])
      end)
    else
      []
    end
  end

  defp go_conventions(context) do
    if MapSet.member?(context.files, "go.mod") do
      lint =
        if Enum.any?(context.files, &(&1 in [".golangci.yml", ".golangci.yaml"])),
          do: {"lint", "golangci-lint run", @manifest},
          else: {"lint", "go vet ./...", @tool_config}

      [
        {"build", "go build ./...", @ecosystem},
        {"test", "go test ./...", @ecosystem},
        {"format", "gofmt -w", @tool_config},
        lint
      ]
      |> Enum.map(fn {key, command, confidence} ->
        candidate(key, command, "convention", confidence, [{"go.mod", nil}])
      end)
    else
      []
    end
  end

  defp candidate(key, command, source, confidence, evidence) do
    %{key: key, command: command, source: source, confidence: confidence, evidence: evidence}
  end

  # Interpretation

  defp interpret(command, context) do
    command = neutralize_tox_substitution(command)

    if unsafe_shell?(command) do
      []
    else
      command |> clean_tokens() |> unwrap() |> dispatch(context)
    end
  end

  # CI often passes `$(cat .python-version)` as a flag value around tox. The value does
  # not decide what the environment runs, so the substitution is replaced by a token.
  defp neutralize_tox_substitution(command) do
    if String.contains?(command, "tox") do
      Regex.replace(~r/\$\([^()]*\)/, command, "__shell__")
    else
      command
    end
  end

  # `$VAR` survives only inside a tox environment name, where the fixed factors around
  # it still identify the environment; everything else with shell syntax is dropped.
  defp unsafe_shell?(command) do
    Regex.match?(~r/[|;<>`"'()]|\$\{\{|\$\(/, command) or
      (String.contains?(command, "$") and not String.contains?(command, "tox"))
  end

  defp unwrap(["uv", "run" | rest]), do: rest |> drop_uv_flags() |> unwrap()
  defp unwrap(["uvx" | rest]), do: rest |> drop_uv_flags() |> unwrap()
  defp unwrap(["-m" | rest]), do: unwrap(rest)
  defp unwrap(["poetry", "run" | rest]), do: unwrap(rest)
  defp unwrap(["pipenv", "run" | rest]), do: unwrap(rest)
  defp unwrap(["pdm", "run" | rest]), do: unwrap(rest)
  defp unwrap(["hatch", "run" | rest]), do: unwrap(rest)
  defp unwrap([python, "-m" | rest]) when python in ~w(python python3), do: unwrap(rest)
  defp unwrap(["coverage", "run" | rest]), do: rest |> Enum.drop_while(&(&1 != "-m")) |> unwrap()
  defp unwrap(["bundle", "exec" | rest]), do: rest

  defp unwrap(["npx" | rest]),
    do: rest |> Enum.reject(&(&1 in ~w(--yes -y --no-install))) |> unwrap_node()

  defp unwrap(tokens), do: tokens

  defp unwrap_node([tool | _] = tokens) when tool in ~w(eslint prettier tsc jest vitest mocha),
    do: tokens

  defp unwrap_node(tokens), do: tokens

  defp drop_uv_flags([flag, _value | rest]) when flag in @uv_flags_with_value,
    do: drop_uv_flags(rest)

  defp drop_uv_flags(["--" <> _ | rest]), do: drop_uv_flags(rest)
  defp drop_uv_flags(rest), do: rest

  defp dispatch(["tox" | args], %{tox: []}), do: tox_placeholder(args)
  defp dispatch(["tox" | args], context), do: tox_results(args, context)

  defp dispatch([tool, "run" | _], context) when tool in ~w(pre-commit prek),
    do: pre_commit_results(tool, context)

  defp dispatch(["nox" | args], _context), do: nox_result(args)

  defp dispatch(tokens, context) do
    case classify(tokens, context) do
      nil -> []
      {key, command} -> [{key, command, [], false}]
    end
  end

  defp tox_placeholder(_), do: []

  defp nox_result(args) do
    case args do
      ["-s", session | _] ->
        case target_key(session) do
          nil -> []
          key -> [{key, "nox -s " <> session, [], false}]
        end

      _ ->
        []
    end
  end

  defp tox_results(args, context) do
    selector =
      case tox_names(args) do
        [] -> :base
        names -> names
      end

    for entry <- select_tox(context.tox, selector),
        {key, command, _, _} <-
          entry.command |> clean_tokens() |> unwrap() |> dispatch(%{context | tox: []}),
        do: {key, command, [{context.tox_path, entry.line}], true}
  end

  defp tox_names(args) do
    args
    |> Enum.reject(&(&1 == "run"))
    |> names_from([])
  end

  defp names_from([], found), do: Enum.reverse(found)

  defp names_from([flag, value | rest], found) when flag in ~w(-e --env -f --factors),
    do: names_from(rest, [value | found])

  defp names_from(["-e" <> value | rest], found) when value != "",
    do: names_from(rest, [value | found])

  defp names_from([_ | rest], found), do: names_from(rest, found)

  defp select_tox(entries, :base) do
    Enum.filter(entries, &(&1.env == "testenv" and &1.factor in [nil, "tests", "test", "py"]))
  end

  defp select_tox(entries, names) do
    wanted =
      names
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.flat_map(&segments/1)
      |> Enum.reject(&String.contains?(&1, "$"))

    Enum.filter(entries, fn entry ->
      env = entry.env |> String.trim_leading("testenv") |> String.trim_leading(":")
      factors = if entry.factor, do: String.split(entry.factor, ","), else: []
      Enum.any?(segments(env) ++ factors, &(&1 in wanted))
    end)
  end

  defp segments(name), do: name |> String.trim_leading("testenv:") |> String.split("-")

  defp pre_commit_results(tool, context) do
    mapped =
      for %{id: id, line: line} <- context.hooks,
          {key, tokens} <- [Map.get(@hook_tools, id)],
          do: {key, runnable(tokens, context), [{".pre-commit-config.yaml", line}], true}

    if mapped == [] do
      [{"lint", runnable([tool, "run", "--all-files"], context), [], true}]
    else
      mapped
    end
  end

  # Classification. Returns `{key, command}` for a token list without wrappers.

  defp classify(["pytest" | args], context), do: pytest(args, context)
  defp classify(["py.test" | args], context), do: pytest(args, context)

  defp classify(["ruff", "check" | args], context),
    do: {"lint", runnable(["ruff", "check" | args -- @lint_noise], context)}

  defp classify(["ruff", "format" | args], context),
    do: {"format", runnable(["ruff", "format" | format_args(args)], context)}

  defp classify(["flake8" | args], context), do: {"lint", runnable(["flake8" | args], context)}
  defp classify(["pylint" | args], context), do: {"lint", runnable(["pylint" | args], context)}

  defp classify(["black" | args], context),
    do: {"format", runnable(["black" | format_args(args)], context)}

  defp classify(["mypy" | args], context), do: {"typecheck", runnable(["mypy" | args], context)}

  defp classify(["pyright" | args], context),
    do: {"typecheck", runnable(["pyright" | args], context)}

  defp classify(["ty", "check" | args], context),
    do: {"typecheck", runnable(["ty", "check" | args], context)}

  defp classify(["pyrefly", "check" | args], context),
    do: {"typecheck", runnable(["pyrefly", "check" | args], context)}

  defp classify(["uv", "build" | _], _), do: {"build", "uv build"}
  defp classify(["uv", "sync" | args], _), do: {"install", Enum.join(["uv", "sync" | args], " ")}
  defp classify(["python", "-m", "build" | _], _), do: {"build", "python -m build"}
  defp classify(["python3", "-m", "build" | _], _), do: {"build", "python3 -m build"}

  defp classify(["poetry", "install" | args], _),
    do: {"install", Enum.join(["poetry", "install" | args], " ")}

  defp classify(["poetry", "build" | _], _), do: {"build", "poetry build"}

  defp classify(["pdm", "install" | args], _),
    do: {"install", Enum.join(["pdm", "install" | args], " ")}

  defp classify([pip, "install" | args], _) when pip in ~w(pip pip3) do
    if Enum.any?(args, &(&1 in ~w(-r --requirement -e --editable .))),
      do: {"install", Enum.join([pip, "install" | args], " ")},
      else: nil
  end

  defp classify(["npm", install | args], _) when install in ~w(install i ci),
    do: {"install", Enum.join(["npm", install | args], " ")}

  defp classify(["yarn", "install" | args], _),
    do: {"install", Enum.join(["yarn", "install" | args], " ")}

  defp classify(["pnpm", "install" | args], _),
    do: {"install", Enum.join(["pnpm", "install" | args], " ")}

  defp classify(["bun", "install" | args], _),
    do: {"install", Enum.join(["bun", "install" | args], " ")}

  defp classify(["npm", "test" | _], context), do: node_script("npm", "test", context)
  defp classify(["npm", "t" | _], context), do: node_script("npm", "test", context)

  defp classify(["npm", run, name | _], context) when run in ~w(run run-script),
    do: node_script("npm", name, context)

  defp classify(["yarn", "run", name | _], context), do: node_script("yarn", name, context)
  defp classify(["yarn", "test" | _], context), do: node_script("yarn", "test", context)
  defp classify(["pnpm", "run", name | _], context), do: node_script("pnpm", name, context)
  defp classify(["pnpm", "test" | _], context), do: node_script("pnpm", "test", context)
  defp classify(["bun", "run", name | _], context), do: node_script("bun", name, context)

  defp classify(["eslint" | args], _), do: {"lint", Enum.join(["npx", "eslint" | args], " ")}

  defp classify(["prettier" | args], _),
    do:
      {"format",
       Enum.join(["npx", "prettier", "--write" | format_args(args -- ["--write"])], " ")}

  defp classify(["tsc" | args], _), do: {"typecheck", Enum.join(["npx", "tsc" | args], " ")}

  defp classify([runner | args], _) when runner in ~w(jest vitest mocha) do
    if subset?(args), do: nil, else: {"test", Enum.join(["npx", runner | args], " ")}
  end

  defp classify(["mix", "test" | args], _) do
    if subset?(args),
      do: nil,
      else: {"test", Enum.join(["mix", "test" | args -- ["--trace"]], " ")}
  end

  defp classify(["mix", "format" | args], _),
    do: {"format", Enum.join(["mix", "format" | format_args(args)], " ")}

  defp classify(["mix", "credo" | args], _), do: {"lint", Enum.join(["mix", "credo" | args], " ")}

  defp classify(["mix", "dialyzer" | args], _),
    do: {"typecheck", Enum.join(["mix", "dialyzer" | args], " ")}

  defp classify(["mix", "compile" | args], _),
    do: {"build", Enum.join(["mix", "compile" | args], " ")}

  defp classify(["mix", "deps.get" | _], _), do: {"install", "mix deps.get"}

  defp classify(["cargo", "test" | args], _) do
    if subset?(args), do: nil, else: {"test", Enum.join(["cargo", "test" | args], " ")}
  end

  defp classify(["cargo", "build" | args], _),
    do: {"build", Enum.join(["cargo", "build" | args], " ")}

  defp classify(["cargo", "fmt" | args], _),
    do: {"format", Enum.join(["cargo", "fmt" | format_args(args)], " ")}

  defp classify(["cargo", "clippy" | args], _),
    do: {"lint", Enum.join(["cargo", "clippy" | args], " ")}

  defp classify(["go", "test" | args], _) do
    if subset?(args), do: nil, else: {"test", Enum.join(["go", "test" | args], " ")}
  end

  defp classify(["go", "build" | args], _), do: {"build", Enum.join(["go", "build" | args], " ")}
  defp classify(["go", "vet" | args], _), do: {"lint", Enum.join(["go", "vet" | args], " ")}
  defp classify(["gofmt" | args], _), do: {"format", Enum.join(["gofmt" | args], " ")}

  defp classify(["golangci-lint", "run" | args], _),
    do: {"lint", Enum.join(["golangci-lint", "run" | args], " ")}

  defp classify(["make", target | _], _) do
    case target_key(target) do
      nil -> nil
      key -> {key, "make " <> target}
    end
  end

  defp classify(["just", target | _], _) do
    case target_key(target) do
      nil -> nil
      key -> {key, "just " <> target}
    end
  end

  defp classify(_, _), do: nil

  defp pytest(args, context) do
    cleaned = strip_noise(args)
    if subset?(args), do: nil, else: {"test", runnable(["pytest" | cleaned], context)}
  end

  # True when arguments narrow a run to part of the suite. A bare directory still
  # means the whole suite.
  defp subset?(args) do
    Enum.any?(args, fn arg ->
      arg in @subset_flags or String.ends_with?(arg, [".py", ".exs", ".js", ".ts", ".rs", ".go"])
    end)
  end

  defp strip_noise(args), do: strip_noise(args, [])

  defp strip_noise([], kept), do: Enum.reverse(kept)

  defp strip_noise([arg, _ | rest], kept) when arg in @noise_with_value,
    do: strip_noise(rest, kept)

  defp strip_noise([arg | rest], kept) do
    if arg in @noise_exact or String.starts_with?(arg, @noise_prefix) do
      strip_noise(rest, kept)
    else
      strip_noise(rest, [arg | kept])
    end
  end

  defp format_args(args) do
    args
    |> Enum.reject(
      &(&1 in @check_flags or &1 == "-c" or &1 == "-d" or String.starts_with?(&1, "--color="))
    )
    |> Enum.reject(&(&1 == "."))
  end

  defp node_script(manager, name, context) do
    case Map.fetch(context.scripts, name) do
      {:ok, {body, _}} ->
        {final, key} = resolve_script(name, body, context)
        if key, do: {key, script_command(manager, final, key)}, else: nil

      :error ->
        nil
    end
  end

  # `test-ci` usually wraps `npm test` with coverage. The inner script is the one a
  # developer runs and the one the same CI line exercises.
  defp resolve_script(name, body, context) do
    inner =
      case Regex.run(~r/\b(?:npm|pnpm|yarn|bun)\s+(?:run\s+)?([A-Za-z0-9:._-]+)/, body) do
        [_, candidate] when candidate != name -> candidate
        _ -> nil
      end

    key = script_key(name)

    if inner && Map.has_key?(context.scripts, inner) && script_key(inner) == key do
      {inner, key}
    else
      {name, key}
    end
  end

  defp script_command("npm", "test", "test"), do: "npm test"
  defp script_command("pnpm", "test", "test"), do: "pnpm test"
  defp script_command("yarn", "test", "test"), do: "yarn test"
  defp script_command(manager, name, _key), do: manager <> " run " <> name

  defp script_key(name) do
    cond do
      Regex.match?(~r/\Atest(?:s)?(?:$|[-:_])/, name) ->
        "test"

      Regex.match?(~r/\Alint(?:$|:)/, name) and not String.contains?(name, "fix") ->
        "lint"

      Regex.match?(~r/\A(?:format|fmt|prettier)(?:$|:)/, name) and
          not String.contains?(name, "check") ->
        "format"

      Regex.match?(~r/\A(?:typecheck|type-check|types|tsc|check-types)\z/, name) ->
        "typecheck"

      Regex.match?(~r/\Abuild(?:$|:)/, name) ->
        "build"

      name in ~w(start dev serve) ->
        "run"

      true ->
        nil
    end
  end

  defp target_key(name) do
    case String.downcase(name) do
      n when n in ~w(test tests) -> "test"
      n when n in ~w(lint lints) -> "lint"
      n when n in ~w(format fmt) -> "format"
      n when n in ~w(typecheck types mypy) -> "typecheck"
      "build" -> "build"
      n when n in ~w(install setup deps bootstrap) -> "install"
      n when n in ~w(run serve dev start) -> "run"
      _ -> nil
    end
  end

  defp runnable([tool | _] = tokens, context) when tool in @python_tools do
    prefix(tool, context) <> Enum.join(tokens, " ")
  end

  defp runnable(tokens, _context), do: Enum.join(tokens, " ")

  defp prefix(tool, %{python_manager: "uv"} = context), do: uv_prefix(tool, context)
  defp prefix(_tool, %{python_manager: "poetry"}), do: "poetry run "
  defp prefix(_tool, %{python_manager: "pdm"}), do: "pdm run "
  defp prefix(_tool, %{python_manager: "pipenv"}), do: "pipenv run "
  defp prefix(_tool, _context), do: ""

  # `uv run` installs the default dependency groups only, so a tool that lives in
  # another group needs `--group` or the command fails on a clean checkout.
  defp uv_prefix(tool, context) do
    in_default? =
      Enum.any?(context.default_groups, fn group -> tool in Map.get(context.groups, group, []) end) or
        tool in context.python_dependencies

    group =
      if in_default?,
        do: nil,
        else:
          context.groups
          |> Enum.sort()
          |> Enum.find_value(fn {name, _deps} -> if name == tool, do: name end) ||
            context.groups
            |> Enum.sort()
            |> Enum.find_value(fn {name, deps} -> if tool in deps, do: name end)

    if group, do: "uv run --group #{group} ", else: "uv run "
  end

  # Probes: the executable each role's command needs, so a session-start check can say
  # which one is missing (`command -v` and `test -x` only; nothing is run). Derived from
  # the command text and package.json scripts, never by running anything. A role whose
  # executable cannot be named is listed in `unknown`.

  @probe_roles ~w(test lint typecheck format)
  @probe_name ~r/\A[A-Za-z0-9][A-Za-z0-9._+-]{0,63}\z/
  @python_runners ~w(uv poetry pdm hatch pipenv)
  @node_managers ~w(npm pnpm yarn bun)
  @extensions %{
    "pytest" => ~w(.py),
    "py.test" => ~w(.py),
    "ruff" => ~w(.py .pyi),
    "black" => ~w(.py .pyi),
    "isort" => ~w(.py .pyi),
    "flake8" => ~w(.py),
    "pylint" => ~w(.py),
    "mypy" => ~w(.py .pyi),
    "pyright" => ~w(.py .pyi),
    "ty" => ~w(.py .pyi),
    "pyrefly" => ~w(.py .pyi),
    "eslint" => ~w(.cjs .js .jsx .mjs .ts .tsx),
    "prettier" => ~w(.css .js .json .jsx .md .mjs .ts .tsx),
    "biome" => ~w(.cjs .js .json .jsx .mjs .ts .tsx),
    "standard" => ~w(.cjs .js .jsx .mjs),
    "xo" => ~w(.cjs .js .jsx .mjs .ts .tsx),
    "tsc" => ~w(.ts .tsx),
    "mocha" => ~w(.cjs .js .mjs),
    "jest" => ~w(.js .jsx .ts .tsx),
    "vitest" => ~w(.js .jsx .ts .tsx),
    "ava" => ~w(.cjs .js .mjs),
    "gofmt" => ~w(.go),
    "golangci-lint" => ~w(.go),
    "rustfmt" => ~w(.rs),
    "rubocop" => ~w(.rb),
    "rspec" => ~w(.rb)
  }
  @mix_extensions %{"format" => ~w(.ex .exs .heex), "credo" => ~w(.ex .exs), "test" => ~w(.exs)}

  defp tools(selected, context, contents) do
    by_key = Map.new(selected, &{&1["key"], &1})

    {entries, unknown} =
      Enum.reduce(@probe_roles, {[], []}, fn role, {entries, unknown} ->
        case by_key["commands." <> role] do
          %{"value" => %{"command" => command}} ->
            case probe(command, context) do
              {name, source, words} ->
                entry = %{
                  "role" => role,
                  "command" => command,
                  "probe" => [name],
                  "extensions" => extensions(name, words),
                  "source" => source
                }

                {[entry | entries], unknown}

              nil ->
                {entries, [role | unknown]}
            end

          _ ->
            {entries, unknown}
        end
      end)

    entries = Enum.reverse(entries) ++ interpreter(contents)

    if entries == [] and unknown == [] do
      []
    else
      value = %{"tools" => entries, "unknown" => Enum.reverse(unknown)}
      [Signal.new("commands.tools", value, 90, @detector)]
    end
  end

  # The interpreter a project pins for development, as `python3.N` probe names: the
  # first pin file that names a CPython 3 version, up to three distinct versions from
  # its lines (pyenv allows several). A lower bound such as `requires-python >=3.10` is
  # not a pin: any newer interpreter satisfies it, so probing `python3.10` would report
  # a missing interpreter that the project does not need. A classifier lists supported
  # versions, not a required one. Neither is used.
  @python_pin ~r/\A(?:cpython[-@])?3\.(\d{1,2})(?:\.\d{1,3})?(?:(?:a|b|rc)\d{1,2})?\z/

  defp interpreter(contents) do
    @interpreter_files
    |> Enum.find_value([], fn file ->
      case pinned_versions(contents[file]) do
        [] ->
          nil

        probes ->
          [
            %{
              "role" => "interpreter",
              "command" => nil,
              "probe" => probes,
              "extensions" => [],
              "source" => "requires_python"
            }
          ]
      end
    end)
  end

  defp pinned_versions(nil), do: []

  defp pinned_versions(text) do
    text
    |> String.split(~r/\r?\n/)
    |> Enum.take(16)
    |> Enum.map(&(&1 |> String.split("#") |> hd() |> String.trim()))
    |> Enum.flat_map(fn line ->
      case Regex.run(@python_pin, line) do
        [_, minor] -> ["python3." <> Integer.to_string(String.to_integer(minor))]
        nil -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.take(3)
  end

  # Returns `{probe, source, words after the probe}` or nil.
  defp probe(command, context) do
    command
    |> String.split(" ", trim: true)
    |> Enum.drop_while(&Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*=/, &1))
    |> probe_tokens(context)
    |> case do
      {name, source, words} -> if Regex.match?(@probe_name, name), do: {name, source, words}
      nil -> nil
    end
  end

  defp probe_tokens([runner, "run" | rest], _context) when runner in @python_runners,
    do: runner_probe(rest)

  defp probe_tokens([python, "-m", tool | words], _context) when python in ~w(python python3),
    do: {tool, "runner_prefix", words}

  defp probe_tokens(["npx" | rest], _context), do: runner_probe(rest)
  defp probe_tokens(["bunx" | rest], _context), do: runner_probe(rest)

  defp probe_tokens([manager, "exec" | rest], _context) when manager in ~w(npm pnpm),
    do: runner_probe(rest)

  defp probe_tokens([manager, "test" | _], context) when manager in @node_managers,
    do: script_probe("test", context)

  defp probe_tokens([manager, "run", script | _], context) when manager in @node_managers,
    do: script_probe(script, context)

  defp probe_tokens([manager, name | words], context) when manager in ~w(yarn pnpm) do
    if Map.has_key?(context.scripts, name),
      do: script_probe(name, context),
      else: {name, "runner_prefix", words}
  end

  defp probe_tokens([tool | words], _context) do
    if String.starts_with?(tool, ["-", "."]) or String.contains?(tool, "/"),
      do: nil,
      else: {tool, "manifest_tool", words}
  end

  defp probe_tokens([], _context), do: nil

  defp runner_probe([flag, _value | rest]) when flag in @uv_flags_with_value,
    do: runner_probe(rest)

  defp runner_probe(["-" <> _ | rest]), do: runner_probe(rest)
  defp runner_probe([tool | words]), do: {tool, "runner_prefix", words}
  defp runner_probe([]), do: nil

  # The first word of the script, when it is a plain executable name.
  defp script_probe(name, context) do
    case Map.get(context.scripts, name) do
      {body, _line} ->
        case String.split(body, ~r/\s+/, trim: true) do
          [first | words] ->
            if Regex.match?(@probe_name, first),
              do: {first, "package_script", words},
              else: nil

          [] ->
            nil
        end

      nil ->
        nil
    end
  end

  defp extensions("mix", [task | _]), do: Map.get(@mix_extensions, task, []) |> Enum.sort()
  defp extensions(name, _words), do: Map.get(@extensions, name, []) |> Enum.sort()

  # Selection

  defp select(grouped, context) do
    selected =
      @keys
      |> Enum.reject(&(&1 == "test_single"))
      |> Enum.flat_map(fn key -> Map.get(grouped, key, []) |> pick(key) end)

    test = Enum.find(selected, &(&1["key"] == "commands.test"))
    selected ++ single(test, context)
  end

  defp pick([], _key), do: []

  defp pick(candidates, key) do
    ranked =
      candidates
      |> Enum.group_by(& &1.command)
      |> Enum.map(fn {command, group} -> summarize(command, group) end)
      |> Enum.sort_by(fn c ->
        {preference(key, c.command), -c.confidence, byte_size(c.command), c.command}
      end)

    [winner | others] = ranked

    value = %{
      "command" => winner.command,
      "sources" => winner.sources,
      "alternatives" => others |> Enum.take(4) |> Enum.map(& &1.command)
    }

    evidence =
      winner.evidence
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(fn {path, line} -> Signal.file(path, line) end)

    [Signal.new("commands." <> key, value, winner.confidence, @detector, evidence)]
  end

  # Several type checkers may run in CI. mypy is the broad project-wide check there;
  # the others are usually aimed at a single file, so they rank after it.
  defp preference("typecheck", command) do
    cond do
      Regex.match?(~r/(?:^| )mypy(?: |$)/, command) -> 0
      Regex.match?(~r/(?:^| )pyright(?: |$)/, command) -> 1
      true -> 2
    end
  end

  # A package script for one slice of the tests (browser, end-to-end, smoke, module,
  # integration, watch...) or for a step around them (coverage report, clean, build,
  # install) is not the project's test command while another script runs the main
  # suite.
  defp preference("test", command) do
    if Regex.match?(@package_script, command) and Regex.match?(@test_slice, command),
      do: 1,
      else: 0
  end

  defp preference(_key, _command), do: 0

  defp summarize(command, group) do
    sources = group |> Enum.map(& &1.source) |> Enum.uniq() |> Enum.sort()
    bonus = if length(sources) > 1, do: 10, else: 0

    %{
      command: command,
      sources: sources,
      confidence: min(Enum.max(Enum.map(group, & &1.confidence)) + bonus, 100),
      evidence: Enum.flat_map(group, & &1.evidence)
    }
  end

  defp single(nil, _context), do: []

  defp single(signal, context) do
    command = signal["value"]["command"]

    case single_command(command, context) do
      nil ->
        []

      single ->
        value = %{"command" => single, "sources" => ["derived"], "alternatives" => []}

        [
          Signal.new(
            "commands.test_single",
            value,
            signal["confidence"] - 10,
            @detector,
            signal["evidence"]
          )
        ]
    end
  end

  defp single_command(command, context) do
    cond do
      String.contains?(command, "pytest") ->
        [String.split(command, "pytest") |> hd(), "pytest -k"] |> Enum.join()

      Regex.match?(~r/\A(?:npm|pnpm|yarn) test\z/, command) ->
        script_single(context) || script_file_form(command, context)

      Regex.match?(~r/\A(?:npm|pnpm|yarn) run [A-Za-z0-9:._-]+\z/, command) ->
        script_file_form(command, context)

      String.starts_with?(command, "mix test") ->
        "mix test"

      String.starts_with?(command, "cargo test") ->
        "cargo test"

      String.starts_with?(command, "go test") ->
        "go test -run"

      true ->
        nil
    end
  end

  # The direct tool form of a `test` script that is one plain call of mocha, jest or
  # vitest: nil when npm would also run a `pretest`/`posttest` script, or when the body
  # has a shell operator, quote, variable, `--` or a watch flag, since the tool alone
  # would then skip steps of the script. Positional directories are dropped; the runner
  # adds the file instead.
  defp script_single(%{scripts: scripts}) do
    with {body, _} <- Map.get(scripts, "test"),
         false <- Map.has_key?(scripts, "pretest") or Map.has_key?(scripts, "posttest"),
         words = String.split(body, " ", trim: true),
         true <- words != [] and Enum.all?(words, &Regex.match?(@script_word, &1)),
         false <- Enum.any?(words, &(&1 in ["--", "-w"] or Regex.match?(~r/watch/i, &1))) do
      runner_single(words)
    else
      _ -> nil
    end
  end

  # The file form of a package script that is one plain call of a test tool taking test
  # files (`vitest run --project unit`, `jest`, `mocha --timeout 5000`, `node --test`),
  # following at most two `npm run <other>` hops: npm `npm run <script> --` (npm needs
  # `--` before arguments for the script), pnpm and yarn `<manager> run <script>` (they
  # pass what follows the script name on). nil when the chain has a shell operator,
  # quote, glob, variable or environment assignment, a positional argument (it would be
  # run with the files), a watch flag, or a `pre`/`post` script (npm runs it too).
  defp script_file_form(command, context) do
    [manager | rest] = String.split(command, " ")
    name = if rest == ["test"], do: "test", else: List.last(rest)

    case direct_script(name, context.scripts, 2) do
      nil -> nil
      "test" when manager == "npm" -> "npm test --"
      final when manager == "npm" -> "npm run " <> final <> " --"
      "test" -> manager <> " test"
      final -> manager <> " run " <> final
    end
  end

  defp direct_script(name, scripts, hops) do
    with {body, _line} <- Map.get(scripts, name),
         false <- Map.has_key?(scripts, "pre" <> name) or Map.has_key?(scripts, "post" <> name),
         words = String.split(body, " ", trim: true),
         true <- words != [] and Enum.all?(words, &Regex.match?(@script_word, &1)) do
      case words do
        [manager, "run", other] when manager in ~w(npm pnpm yarn) and hops > 0 ->
          direct_script(other, scripts, hops - 1)

        [manager, "test"] when manager in ~w(npm pnpm yarn) and hops > 0 and name != "test" ->
          direct_script("test", scripts, hops - 1)

        _ ->
          if direct_tool_call?(words), do: name, else: nil
      end
    else
      _ -> nil
    end
  end

  defp direct_tool_call?(words) do
    case Enum.find(@file_test_tools, &(Enum.take(words, length(&1)) == &1)) do
      nil -> false
      tool -> plain_flags?(Enum.drop(words, length(tool)), hd(tool), nil)
    end
  end

  # Flags and their values only: a word after a flag without `=` is that flag's value
  # unless it looks like a path; any other word is a positional argument.
  defp plain_flags?([], _tool, _previous), do: true

  defp plain_flags?([word | rest], tool, previous) do
    cond do
      word == "--" or Regex.match?(~r/watch/i, word) or (tool == "mocha" and word == "-w") ->
        false

      String.starts_with?(word, "-") ->
        plain_flags?(rest, tool, if(String.contains?(word, "="), do: nil, else: word))

      is_binary(previous) and not String.contains?(word, ["/", "*"]) and
          word not in @script_path_words ->
        plain_flags?(rest, tool, nil)

      true ->
        false
    end
  end

  defp runner_single(["mocha" | args]), do: Enum.join(["npx", "mocha" | mocha_flags(args)], " ")
  defp runner_single(["jest" | _]), do: "npx jest"
  defp runner_single(["vitest" | _]), do: "npx vitest run"
  defp runner_single(_), do: nil

  defp mocha_flags(args), do: mocha_flags(args, [])
  defp mocha_flags([], kept), do: Enum.reverse(kept)

  defp mocha_flags([flag, _ | rest], kept) when flag in ~w(--reporter -R),
    do: mocha_flags(rest, kept)

  defp mocha_flags([flag, value | rest], kept) when flag in ~w(--require -r --timeout -t),
    do: mocha_flags(rest, [value, flag | kept])

  defp mocha_flags([arg | rest], kept) do
    if String.starts_with?(arg, "-"),
      do: mocha_flags(rest, [arg | kept]),
      else: mocha_flags(rest, kept)
  end
end
