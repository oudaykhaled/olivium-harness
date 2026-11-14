defmodule HarnessForge.Analyzers.Manifests do
  @moduledoc """
  Text-only readers for project manifests and CI files.

  Nothing here evaluates the repository: TOML, YAML, Makefiles, `mix.exs` and
  `noxfile.py` are scanned line by line, and only `package.json` goes through a
  JSON decoder. The readers accept the common shapes of these formats and return
  nothing for the rest, so a file they cannot follow yields no fact, not a wrong one.
  """

  @spec numbered(String.t()) :: [{pos_integer(), String.t()}]
  def numbered(text) do
    text |> String.split(~r/\r?\n/) |> Enum.with_index(1) |> Enum.map(fn {l, n} -> {n, l} end)
  end

  # GitHub Actions

  @doc "Each shell command of a workflow as `%{line:, command:}`, in file order."
  @spec workflow_runs(String.t()) :: [%{line: pos_integer(), command: String.t()}]
  def workflow_runs(text), do: text |> numbered() |> scan_runs([]) |> Enum.reverse()

  @doc """
  The commands of `workflow_runs/1` that run in the repository root: a step with its own
  `working-directory` (other than `.`), or a job or workflow whose `defaults.run` sets
  one, runs in another directory, so its commands are not the project's own (a
  `npm run test:module` inside `tests/module/cjs` is that package's script).
  """
  @spec workflow_root_runs(String.t()) :: [%{line: pos_integer(), command: String.t()}]
  def workflow_root_runs(text) do
    lines = numbered(text)
    elsewhere = subdirectory_lines(lines)
    lines |> scan_runs([]) |> Enum.reverse() |> Enum.reject(&MapSet.member?(elsewhere, &1.line))
  end

  @root_directories [".", "./", "${{ github.workspace }}"]

  # The line numbers inside a step, job or workflow that sets a working directory.
  defp subdirectory_lines(lines) do
    indexed = Enum.with_index(lines)

    for {{_number, line}, index} <- indexed,
        [_, indent, dash, value] <-
          [Regex.run(~r/^(\s*)(-\s+)?working-directory:\s*(.*?)\s*$/, line)],
        unquote_value(value) not in ["" | @root_directories],
        number <- scope(lines, index, String.length(indent), dash != ""),
        into: MapSet.new(),
        do: number
  end

  # A key on a step's own dash line: that step. A key under a step: the step. A key under
  # `defaults: run:`: the block that holds `defaults` (a job, or the whole workflow).
  defp scope(lines, index, column, true), do: block(lines, index, column)

  defp scope(lines, index, column, false) do
    case parent(lines, index, column) do
      nil ->
        []

      {parent_index, parent_column, parent_line} ->
        cond do
          Regex.match?(~r/^\s*-\s+/, parent_line) and parent_column + 2 == column ->
            block(lines, parent_index, parent_column)

          Regex.match?(~r/^\s*run:\s*$/, parent_line) ->
            case parent(lines, parent_index, parent_column) do
              {defaults_index, defaults_column, defaults_line} ->
                if Regex.match?(~r/^\s*defaults:\s*$/, defaults_line) do
                  case parent(lines, defaults_index, defaults_column) do
                    nil -> Enum.map(lines, &elem(&1, 0))
                    {owner_index, owner_column, _} -> block(lines, owner_index, owner_column)
                  end
                else
                  []
                end

              nil ->
                []
            end

          true ->
            []
        end
    end
  end

  # The nearest line above `index` indented less than `column`.
  defp parent(lines, index, column) do
    lines
    |> Enum.take(index)
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn {{_number, line}, i} ->
      trimmed = String.trim(line)

      if trimmed != "" and not String.starts_with?(trimmed, "#") and indentation(line) < column,
        do: {i, indentation(line), line}
    end)
  end

  # The line numbers of the block a line at `index` opens: it and every following line
  # indented more than `column` (blank and comment lines included).
  defp block(lines, index, column) do
    {first, _} = Enum.at(lines, index)

    rest =
      lines
      |> Enum.drop(index + 1)
      |> Enum.take_while(fn {_number, line} ->
        trimmed = String.trim(line)
        trimmed == "" or String.starts_with?(trimmed, "#") or indentation(line) > column
      end)
      |> Enum.map(&elem(&1, 0))

    [first | rest]
  end

  defp scan_runs([], found), do: found

  defp scan_runs([{number, line} | rest], found) do
    case Regex.run(~r/^(\s*)(-\s+)?run:\s*(.*?)\s*$/, line) do
      [_, indent, dash, value] ->
        # Sibling keys of a `- run:` step sit two columns right of the dash.
        parent = String.length(indent) + if(dash == "", do: 0, else: 2)

        if Regex.match?(~r/^[|>][+-]?\d*$/, value) do
          {body, remaining} =
            Enum.split_while(rest, fn {_, l} ->
              String.trim(l) == "" or indentation(l) > parent
            end)

          scan_runs(remaining, block(value, body) ++ found)
        else
          scan_runs(rest, Enum.reverse(pieces(number, unquote_value(value))) ++ found)
        end

      _ ->
        scan_runs(rest, found)
    end
  end

  defp indentation(line), do: String.length(line) - String.length(String.trim_leading(line))

  defp block(">" <> _, body) do
    lines = Enum.reject(body, fn {_, l} -> String.trim(l) == "" end)

    case lines do
      [] ->
        []

      [{number, _} | _] ->
        command = Enum.map_join(lines, " ", fn {_, l} -> String.trim(l) end)
        Enum.reverse(pieces(number, command))
    end
  end

  defp block(_literal, body) do
    body
    |> join_continuations()
    |> Enum.flat_map(fn {number, line} -> pieces(number, strip_comment(line)) end)
    |> Enum.reverse()
  end

  defp join_continuations(body) do
    body
    |> Enum.reduce({[], nil}, fn {number, line}, {done, open} ->
      trimmed = String.trim(line)

      case {open, String.ends_with?(trimmed, "\\")} do
        {nil, true} -> {done, {number, String.trim_trailing(trimmed, "\\")}}
        {nil, false} -> {[{number, trimmed} | done], nil}
        {{at, text}, true} -> {done, {at, text <> " " <> String.trim_trailing(trimmed, "\\")}}
        {{at, text}, false} -> {[{at, text <> " " <> trimmed} | done], nil}
      end
    end)
    |> then(fn
      {done, nil} -> done
      {done, open} -> [open | done]
    end)
    |> Enum.reverse()
    |> Enum.reject(fn {_, line} -> line == "" or String.starts_with?(line, "#") end)
  end

  defp pieces(number, command) do
    command
    |> String.split(" && ")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&%{line: number, command: &1})
  end

  defp unquote_value(value) do
    value = strip_comment(value)

    case Regex.run(~r/^(["'])(.*)\1$/, value) do
      [_, _, inner] -> inner
      _ -> value
    end
  end

  defp strip_comment(value), do: value |> String.split(" #", parts: 2) |> hd() |> String.trim()

  # pre-commit

  @doc "Hook ids of a `.pre-commit-config.yaml` as `%{line:, id:}`."
  @spec pre_commit_hooks(String.t()) :: [%{line: pos_integer(), id: String.t()}]
  def pre_commit_hooks(text) do
    for {number, line} <- numbered(text),
        [_, id] <- [Regex.run(~r/^\s*-\s*id:\s*["']?([A-Za-z0-9_.-]+)/, line)],
        do: %{line: number, id: id}
  end

  # TOML, line oriented

  @doc "Sections of a TOML file as `%{name => [{key, line, raw_value}]}`."
  @spec toml(String.t()) :: %{String.t() => [{String.t(), pos_integer(), String.t()}]}
  def toml(text) do
    text
    |> numbered()
    |> Enum.map(fn {number, line} -> {number, strip_toml_comment(line)} end)
    |> scan_toml("", %{})
    |> Map.new(fn {section, entries} -> {section, Enum.reverse(entries)} end)
  end

  defp scan_toml([], _section, sections), do: sections

  defp scan_toml([{number, line} | rest], section, sections) do
    trimmed = String.trim(line)

    cond do
      header = header(trimmed) ->
        scan_toml(rest, header, Map.put_new(sections, header, []))

      match = Regex.run(~r/^([A-Za-z0-9_."'-]+)\s*=\s*(.*)$/, trimmed) ->
        [_, key, value] = match
        {raw, remaining} = complete(value, rest)
        entry = {String.trim(key, "\""), number, raw}
        scan_toml(remaining, section, Map.update(sections, section, [entry], &[entry | &1]))

      true ->
        scan_toml(rest, section, sections)
    end
  end

  defp header(line) do
    case Regex.run(~r/^\[\[?([^\[\]]+)\]\]?$/, line) do
      [_, name] -> String.trim(name)
      _ -> nil
    end
  end

  defp complete(value, rest) do
    depth = balance(value)
    if depth <= 0, do: {value, rest}, else: consume([value], rest, depth)
  end

  defp consume(parts, [], _depth), do: {finish(parts), []}

  defp consume(parts, [{_, line} | rest], depth) do
    depth = depth + balance(line)
    parts = [line | parts]
    if depth <= 0, do: {finish(parts), rest}, else: consume(parts, rest, depth)
  end

  defp finish(parts), do: parts |> Enum.reverse() |> Enum.join("\n")

  defp balance(text) do
    text
    |> String.graphemes()
    |> Enum.reduce({0, nil}, fn
      char, {depth, nil} when char in ["\"", "'"] -> {depth, char}
      char, {depth, char} -> {depth, nil}
      _, {depth, quote_char} when quote_char != nil -> {depth, quote_char}
      "[", {depth, nil} -> {depth + 1, nil}
      "]", {depth, nil} -> {depth - 1, nil}
      _, state -> state
    end)
    |> elem(0)
  end

  defp strip_toml_comment(line) do
    line
    |> String.graphemes()
    |> Enum.reduce_while({[], nil}, fn
      "#", {kept, nil} -> {:halt, {kept, nil}}
      char, {kept, nil} when char in ["\"", "'"] -> {:cont, {[char | kept], char}}
      char, {kept, char} -> {:cont, {[char | kept], nil}}
      char, {kept, quote_char} -> {:cont, {[char | kept], quote_char}}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.join()
  end

  @doc "String literals of a TOML value, in order."
  @spec strings(String.t()) :: [String.t()]
  def strings(raw) do
    Regex.scan(~r/"((?:[^"\\]|\\.)*)"|'([^']*)'/, raw)
    |> Enum.map(fn
      [_, double] -> double
      [_, "", single] -> single
    end)
  end

  defp entry(entries, key), do: Enum.find(entries, fn {name, _, _} -> name == key end)

  @doc "Value of `key` in a TOML section, as `{line, raw}`."
  @spec toml_value(map(), String.t(), String.t()) :: {pos_integer(), String.t()} | nil
  def toml_value(sections, section, key) do
    case entry(Map.get(sections, section, []), key) do
      {_, line, raw} -> {line, raw}
      nil -> nil
    end
  end

  @doc "Dependency groups with their package names, inclusive of `include-group` entries."
  @spec dependency_groups(map()) :: %{String.t() => [String.t()]}
  def dependency_groups(sections) do
    groups =
      for {name, _, raw} <- Map.get(sections, "dependency-groups", []), into: %{} do
        includes =
          Regex.scan(~r/include-group\s*=\s*["']([^"']+)["']/, raw, capture: :all_but_first)
          |> List.flatten()

        direct =
          ~r/\{[^{}]*\}/
          |> Regex.replace(raw, "")
          |> strings()
          |> Enum.map(&package_name/1)

        {name, {direct, includes}}
      end

    Map.new(groups, fn {name, _} -> {name, expand_group(name, groups, [])} end)
  end

  defp expand_group(name, groups, seen) do
    if name in seen do
      []
    else
      {direct, includes} = Map.get(groups, name, {[], []})
      direct ++ Enum.flat_map(includes, &expand_group(&1, groups, [name | seen]))
    end
  end

  defp package_name(requirement) do
    case Regex.run(~r/^\s*([A-Za-z0-9][A-Za-z0-9_.-]*)/, requirement) do
      [_, name] -> String.downcase(name)
      _ -> requirement
    end
  end

  @doc "Package names from `[project]`, optional dependencies and legacy tool sections."
  @spec python_dependencies(map()) :: [String.t()]
  def python_dependencies(sections) do
    direct =
      case toml_value(sections, "project", "dependencies") do
        {_, raw} -> strings(raw)
        nil -> []
      end

    optional =
      sections
      |> Map.get("project.optional-dependencies", [])
      |> Enum.flat_map(fn {_, _, raw} -> strings(raw) end)

    poetry =
      ["tool.poetry.dependencies", "tool.poetry.group.dev.dependencies"]
      |> Enum.flat_map(&Map.get(sections, &1, []))
      |> Enum.map(fn {name, _, _} -> name end)

    Enum.map(direct ++ optional ++ poetry, &package_name/1)
  end

  # tox

  @doc "Commands of a `tox.ini` as `%{env:, factor:, line:, command:}`."
  @spec tox_ini(String.t()) :: [map()]
  def tox_ini(text) do
    text |> numbered() |> scan_tox(nil, [], false) |> Enum.reverse()
  end

  defp scan_tox([], _env, found, _in_commands), do: found

  defp scan_tox([{number, line} | rest], env, found, in_commands) do
    cond do
      section = Regex.run(~r/^\[([^\]]+)\]\s*$/, line) ->
        scan_tox(rest, Enum.at(section, 1), found, false)

      env != nil and String.starts_with?(env, "testenv") and
          Regex.match?(~r/^commands\s*=/, line) ->
        inline = line |> String.split("=", parts: 2) |> List.last() |> String.trim()
        scan_tox(rest, env, add_tox(found, env, number, inline), true)

      in_commands and Regex.match?(~r/^\s+\S/, line) ->
        scan_tox(rest, env, add_tox(found, env, number, String.trim(line)), true)

      in_commands and String.trim(line) == "" ->
        scan_tox(rest, env, found, true)

      true ->
        scan_tox(rest, env, found, false)
    end
  end

  defp add_tox(found, _env, _number, ""), do: found

  defp add_tox(found, env, number, text) do
    {factor, command} =
      case Regex.run(~r/^([A-Za-z0-9_.,{}-]+):\s+(.*)$/, text) do
        [_, factor, command] -> {factor, command}
        _ -> {nil, text}
      end

    case clean_tox_command(command) do
      "" -> found
      clean -> [%{env: env, factor: factor, line: number, command: clean} | found]
    end
  end

  defp clean_tox_command(command) do
    ~r/\{[^{}]*\}/
    |> Regex.replace(command, " ")
    |> String.replace("\\", " ")
    |> String.split()
    |> Enum.join(" ")
  end

  @doc "Commands from `[tool.tox]` tables in `pyproject.toml`, in the `tox_ini/1` shape."
  @spec tox_toml(map()) :: [map()]
  def tox_toml(sections) do
    sections
    |> Enum.flat_map(fn
      {"tool.tox.env_run_base", entries} -> tox_toml_commands("testenv", entries)
      {"tool.tox.env." <> name, entries} -> tox_toml_commands("testenv:" <> name, entries)
      _ -> []
    end)
    |> Enum.sort_by(& &1.line)
  end

  defp tox_toml_commands(env, entries) do
    case entry(entries, "commands") do
      {_, line, raw} ->
        for inner <-
              Regex.scan(~r/\[([^\[\]]*)\]/, Regex.replace(~r/\{[^{}]*\}/, raw, ""),
                capture: :all_but_first
              ),
            words = inner |> hd() |> strings() |> Enum.reject(&String.contains?(&1, "{")),
            words != [],
            do: %{env: env, factor: nil, line: line, command: Enum.join(words, " ")}

      nil ->
        []
    end
  end

  # package.json

  @doc "Decoded `package.json` with scripts mapped to `%{name => {body, line}}`, or nil."
  @spec package_json(String.t()) :: map() | nil
  def package_json(text) do
    case Jason.decode(text) do
      {:ok, %{} = data} ->
        scripts =
          for {name, body} <- Map.get(data, "scripts", %{}),
              is_binary(name) and is_binary(body),
              into: %{},
              do: {name, {body, script_line(text, name)}}

        %{
          "scripts" => scripts,
          "dependencies" =>
            Enum.sort(
              Map.keys(string_map(data["dependencies"])) ++
                Map.keys(string_map(data["devDependencies"]))
            )
        }

      _ ->
        nil
    end
  end

  defp string_map(%{} = map), do: map
  defp string_map(_), do: %{}

  defp script_line(text, name) do
    pattern = Regex.compile!("^\\s*\"" <> Regex.escape(name) <> "\"\\s*:")

    Enum.find_value(numbered(text), fn {number, line} ->
      if Regex.match?(pattern, line), do: number
    end)
  end

  # Make and just

  @doc "Target names of a Makefile as `%{line:, name:}`."
  @spec make_targets(String.t()) :: [map()]
  def make_targets(text) do
    for {number, line} <- numbered(text),
        [_, name] <- [Regex.run(~r/^([A-Za-z0-9][A-Za-z0-9_.-]*)\s*:(?![:=])/, line)],
        do: %{line: number, name: name}
  end

  @doc "Recipe names of a justfile as `%{line:, name:}`."
  @spec just_recipes(String.t()) :: [map()]
  def just_recipes(text) do
    for {number, line} <- numbered(text),
        [_, name] <- [Regex.run(~r/^@?([A-Za-z0-9][A-Za-z0-9_-]*)(?:\s+[^:=]*)?:(?!=)/, line)],
        name not in ~w(set import mod export),
        do: %{line: number, name: name}
  end

  # Other manifests

  @doc "Session names of a `noxfile.py`, read as text."
  @spec nox_sessions(String.t()) :: [String.t()]
  def nox_sessions(text) do
    Regex.scan(~r/@nox\.session[^\n]*\n\s*def\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(/, text,
      capture: :all_but_first
    )
    |> List.flatten()
  end

  @doc "Dependency atoms of a `mix.exs`, read as text."
  @spec mix_dependencies(String.t()) :: [String.t()]
  def mix_dependencies(text) do
    Regex.scan(~r/\{:([a-z_][a-z0-9_]*)\s*,/, text, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "Package names of a requirements file."
  @spec requirement_names(String.t()) :: [String.t()]
  def requirement_names(text) do
    text
    |> String.split(~r/\r?\n/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, ["#", "-"])))
    |> Enum.map(&package_name/1)
  end
end
