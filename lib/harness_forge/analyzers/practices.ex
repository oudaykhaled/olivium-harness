defmodule HarnessForge.Analyzers.Practices do
  @moduledoc """
  Counts two engineering practices that a literal reading of an issue can contradict
  (item 7 of the harness enhancement plan):

    * **Deprecate before removing.** Deprecation warnings emitted by the project's own
      source, and sentences in maintainer documents that state the policy.
    * **Warnings fail tests.** A pytest configuration whose `filterwarnings` has an entry
      starting with `error`, or whose `addopts` passes `-W error`.

  Counts only. No repository text leaves this module: the signal carries integers, a
  boolean and file paths as evidence, and the sentences a harness carries are fixed
  text in `priv/blueprints/*.json`, switched on by thresholds there.

  The read is bounded and linear. Source files are taken in sorted path order, at most
  #{400} of them; maintainer documents (root, `.github/`, `docs/`, `doc/`) at most #{100};
  each file at most 256 KiB, and all of them together at most 16 MiB. A line longer
  than 4 KiB (minified code, data) is never matched, and every pattern is anchored on
  a literal, so hostile input costs time proportional to its size. Nothing is executed.

  What counts as a deprecation site, per source file:

    * Python: a `warn(` call where its line or the seven after it mention "deprecat"
      or a `RemovedIn...Warning`; a `@deprecated` decorator.
    * JavaScript and TypeScript: a call of a deprecation helper (`depd(`,
      `deprecate(`, `util.deprecate(`, `deprecated(`, `deprecatedMethod(`, ...), not its
      definition; a `console.warn(`, `emitWarning(` or `warn(` call where its line or
      the three after it mention "deprecat"; a JSDoc `@deprecated` tag.

  A policy sentence is a sentence in a maintainer document (not a changelog) that
  mentions deprecation together with a time word ("before", "prior to", "rather than",
  "at least", "deprecation period", "deprecation cycle", "deprecation policy") and a
  break word ("remove", "break", "broken", "drop", "incompatible").
  """

  alias HarnessForge.Analyzers.{Inventory, Manifests, Paths, Signal}

  @detector "practices"
  @max_sources 400
  @max_documents 100
  @max_file_bytes 256 * 1024
  @max_total_bytes 16 * 1024 * 1024
  @max_line_bytes 4096
  @max_sentence_bytes 2048
  @python_window 8
  @script_window 4
  @definition_prefix_bytes 32

  @source_extensions ~w(.py .js .jsx .mjs .cjs .ts .tsx)
  @script_extensions ~w(.js .jsx .mjs .cjs .ts .tsx)
  @skipped_directories ~w(vendor vendored third_party third-party dist build node_modules site-packages)
  @document_extensions ~w(.md .rst .txt .adoc)
  @document_roots ~w(.github docs doc)
  @fragment_directories ~w(changelog.d newsfragments changes .changeset)
  @changelog_stem ~r/\A(?:changes|changelog|history|news|release[-_]?notes|releases)\z/i

  @python_warn ~r/\bwarn\s*\(/
  @python_decorator ~r/\A\s*@(?:[A-Za-z_][A-Za-z0-9_]*\.)*deprecated\b/
  @deprecation_word ~r/deprecat|RemovedIn[A-Za-z0-9]*Warning/i
  @script_helper ~r/(?<![A-Za-z0-9_$])(?:depd|deprecate|deprecated|deprecatedMethod|warnDeprecated|deprecationWarning)\s*\(/
  @script_definition ~r/(?:\bfunction\s*\*?\s*|\bdef\s+)\z/
  @script_method_definition ~r/\A\s*(?:async\s+|static\s+)*[A-Za-z_$][A-Za-z0-9_$]*\s*\([^()]*\)\s*\{\s*\z/
  @script_warn ~r/\b(?:console\.warn|emitWarning|warn)\s*\(/
  @jsdoc_tag ~r/\A\s*(?:\/\*\*|\*|\/\/).*@deprecated\b/
  @string_join ~r/["'`]\s*+(?:\+\s*+)?["'`]/
  @removal ~r/will\s++be\s++removed/i
  @policy_subject ~r/deprecat/i
  @policy_when ~r/\b(?:before|prior to|rather than|at least|deprecation (?:period|cycle|policy))\b/i
  @policy_what ~r/\b(?:remov\w*|break\w*|broken|drop\w*|incompatib\w*)\b/i

  @pytest_sections [
    {"pyproject.toml", "tool.pytest.ini_options"},
    {"pyproject.toml", "tool.pytest"},
    {"pytest.ini", "pytest"},
    {"setup.cfg", "tool:pytest"},
    {"tox.ini", "pytest"}
  ]

  @doc "The keys of the counts object, in the order the profile schema lists them."
  @spec count_keys() :: [String.t()]
  def count_keys,
    do:
      ~w(deprecation_sites deprecation_files removal_phrases policy_sentences warnings_as_errors)

  @doc """
  Analyze an inventory. `contents` holds the manifest files `Inventory.load/2` already
  read (the pytest configuration comes from there). Returns `{signals, state}` where
  `state` has `:complete` and `:truncated` for the detector record.
  """
  @spec analyze(Inventory.t(), map()) :: {[map()], %{complete: boolean(), truncated: boolean()}}
  def analyze(%Inventory{} = inventory, contents) when is_map(contents) do
    files = Enum.sort(inventory.files)
    sources = Enum.filter(files, &source?/1)
    documents = files |> Enum.filter(&document?/1) |> Enum.sort_by(&{document_rank(&1), &1})

    {source_counts, budget, source_cut} = read_sources(inventory, sources, @max_total_bytes)
    {policy, documents_read, document_cut} = read_documents(inventory, documents, budget)
    {warnings_as_errors, config} = warnings_as_errors(contents)

    truncated =
      length(sources) > @max_sources or length(documents) > @max_documents or source_cut or
        document_cut

    value = %{
      "deprecation_sites" => source_counts.sites,
      "deprecation_files" => length(source_counts.files),
      "removal_phrases" => source_counts.removals,
      "policy_sentences" => policy.sentences,
      "warnings_as_errors" => warnings_as_errors,
      "sources_read" => source_counts.read,
      "documents_read" => documents_read
    }

    evidence =
      Enum.map(Enum.reverse(source_counts.files), &Signal.file/1) ++
        Enum.map(Enum.reverse(policy.files), &Signal.file/1) ++
        if(config, do: [Signal.file(config)], else: [])

    signal = Signal.new("practices.counts", value, 90, @detector, evidence)
    {[signal], %{complete: not truncated, truncated: truncated}}
  end

  # -- Which files are read ---------------------------------------------------------

  defp source?(path) do
    {directories, name} = split(path)

    Path.extname(name) in @source_extensions and Paths.source_path?(path) and
      not String.ends_with?(name, [".d.ts", ".min.js"]) and
      not Enum.any?(directories, &(String.downcase(&1) in @skipped_directories))
  end

  defp document?(path) do
    {directories, name} = split(path)

    String.downcase(Path.extname(name)) in @document_extensions and
      not Regex.match?(@changelog_stem, Path.rootname(name)) and
      not Enum.any?(directories, &(&1 in @fragment_directories)) and
      (directories == [] or hd(directories) in @document_roots) and
      length(directories) <= 4
  end

  defp document_rank(path) do
    case split(path) do
      {[], _name} -> 0
      {[".github" | _], _name} -> 1
      _ -> 2
    end
  end

  defp split(path) do
    parts = String.split(path, "/")
    {Enum.drop(parts, -1), List.last(parts)}
  end

  # -- Source files -----------------------------------------------------------------

  defp read_sources(inventory, sources, budget) do
    initial = {%{sites: 0, files: [], removals: 0, read: 0}, budget, false}

    sources
    |> Enum.take(@max_sources)
    |> Enum.reduce_while(initial, fn path, {counts, left, _cut} ->
      case Inventory.read_text(inventory, path, @max_file_bytes) do
        {:ok, text} when byte_size(text) > left ->
          {:halt, {counts, left, true}}

        {:ok, text} ->
          sites = sites(path, text)

          counts = %{
            counts
            | sites: counts.sites + sites,
              files: if(sites > 0, do: [path | counts.files], else: counts.files),
              removals: counts.removals + removals(text),
              read: counts.read + 1
          }

          {:cont, {counts, left - byte_size(text), false}}

        {:skip, _counter} ->
          {:cont, {counts, left, false}}
      end
    end)
  end

  @doc false
  # Deprecation sites in one source file. Public for the unit tests.
  @spec sites(String.t(), String.t()) :: non_neg_integer()
  def sites(path, text) do
    lines = text |> String.split("\n") |> Enum.map(&bounded_line/1)
    indexed = Enum.with_index(lines)
    # Whether each line mentions deprecation, computed once, so a window check costs
    # its size and not the bytes of the lines in it.
    mentions = lines |> Enum.map(&Regex.match?(@deprecation_word, &1)) |> List.to_tuple()

    if Path.extname(path) in @script_extensions,
      do: script_sites(mentions, indexed),
      else: python_sites(mentions, indexed)
  end

  # A line too long to be hand-written code is never matched.
  defp bounded_line(line) when byte_size(line) > @max_line_bytes, do: ""
  defp bounded_line(line), do: line

  defp python_sites(mentions, indexed) do
    Enum.reduce(indexed, 0, fn {line, index}, total ->
      warns = warn_calls(@python_warn, line, mentions, index, @python_window)
      decorator = if Regex.match?(@python_decorator, line), do: 1, else: 0
      total + warns + decorator
    end)
  end

  defp script_sites(mentions, indexed) do
    Enum.reduce(indexed, 0, fn {line, index}, total ->
      helpers =
        if Regex.match?(@script_method_definition, line),
          do: 0,
          else:
            @script_helper
            |> Regex.scan(line, return: :index)
            |> Enum.count(fn [{start, _length}] -> not definition?(line, start) end)

      warns = warn_calls(@script_warn, line, mentions, index, @script_window)
      tag = if Regex.match?(@jsdoc_tag, line), do: 1, else: 0
      total + helpers + warns + tag
    end)
  end

  # The warn calls on a line count when the line or the next ones mention deprecation.
  defp warn_calls(pattern, line, mentions, index, window) do
    case length(Regex.scan(pattern, line)) do
      0 -> 0
      calls -> if window_mentions?(mentions, index, window), do: calls, else: 0
    end
  end

  defp window_mentions?(mentions, index, size) do
    last = min(index + size, tuple_size(mentions)) - 1
    Enum.any?(index..last//1, &elem(mentions, &1))
  end

  # `function deprecate(` or `def deprecate(` defines the helper; only the few bytes
  # before the name are looked at, so many calls on one line stay linear.
  defp definition?(line, start) do
    from = max(start - @definition_prefix_bytes, 0)
    Regex.match?(@script_definition, binary_part(line, from, start - from))
  end

  # "will be removed" phrases, also when a message is split over joined string literals.
  defp removals(text) do
    text
    |> String.split("\n")
    |> Enum.map(&bounded_line/1)
    |> Enum.join("\n")
    |> then(&Regex.replace(@string_join, &1, ""))
    |> then(&Regex.scan(@removal, &1))
    |> length()
  end

  # -- Maintainer documents ---------------------------------------------------------

  defp read_documents(inventory, documents, budget) do
    initial = {%{sentences: 0, files: []}, 0, budget, false}

    {policy, read, _left, cut} =
      documents
      |> Enum.take(@max_documents)
      |> Enum.reduce_while(initial, fn path, {policy, read, left, _cut} ->
        case Inventory.read_text(inventory, path, @max_file_bytes) do
          {:ok, text} when byte_size(text) > left ->
            {:halt, {policy, read, left, true}}

          {:ok, text} ->
            found = policy_sentences(text)

            policy = %{
              sentences: policy.sentences + found,
              files: if(found > 0, do: [path | policy.files], else: policy.files)
            }

            {:cont, {policy, read + 1, left - byte_size(text), false}}

          {:skip, _counter} ->
            {:cont, {policy, read, left, false}}
        end
      end)

    {policy, read, cut}
  end

  @doc false
  # Policy sentences in one document. Public for the unit tests.
  @spec policy_sentences(String.t()) :: non_neg_integer()
  def policy_sentences(text) do
    text
    |> String.split(~r/\n[ \t]*\r?\n/)
    |> Enum.flat_map(fn paragraph ->
      paragraph
      |> String.split()
      |> Enum.join(" ")
      |> String.split(~r/(?<=[.!?])\s+/)
    end)
    |> Enum.count(&policy_sentence?/1)
  end

  defp policy_sentence?(sentence) do
    byte_size(sentence) <= @max_sentence_bytes and Regex.match?(@policy_subject, sentence) and
      Regex.match?(@policy_when, sentence) and Regex.match?(@policy_what, sentence)
  end

  # -- Warnings as errors -----------------------------------------------------------

  @doc false
  # `{true, config_path}` when a pytest configuration turns warnings into errors.
  @spec warnings_as_errors(map()) :: {boolean(), String.t() | nil}
  def warnings_as_errors(contents) do
    Enum.find_value(@pytest_sections, {false, nil}, fn {file, section} ->
      with text when is_binary(text) <- contents[file],
           true <- errors?(file, section, text) do
        {true, file}
      else
        _ -> nil
      end
    end)
  end

  defp errors?("pyproject.toml", section, text) do
    sections = Manifests.toml(text)

    filters =
      case Manifests.toml_value(sections, section, "filterwarnings") do
        {_, raw} -> toml_entries(raw)
        nil -> []
      end

    addopts =
      case Manifests.toml_value(sections, section, "addopts") do
        {_, raw} -> raw |> toml_entries() |> Enum.join(" ")
        nil -> ""
      end

    error_entry?(filters) or werror?(addopts)
  end

  defp errors?(_file, section, text) do
    entries = ini_section(text, section)

    error_entry?(Map.get(entries, "filterwarnings", [])) or
      werror?(entries |> Map.get("addopts", []) |> Enum.join(" "))
  end

  defp toml_entries(raw) do
    case Manifests.strings(raw) do
      [] -> [String.trim(raw)]
      strings -> strings
    end
  end

  defp error_entry?(entries),
    do: Enum.any?(entries, &(&1 |> String.trim() |> String.starts_with?("error")))

  defp werror?(text),
    do: Regex.match?(~r/(?:\A|\s)-W\s*["']?error\b|(?:\A|\s)-Werror\b/, text)

  # The lines of one INI section as `%{key => [value lines]}`; indented lines continue
  # the previous key, and `#` or `;` lines are comments. Values are gathered in reverse
  # and turned once at the end, so a long continuation costs linear time.
  defp ini_section(text, wanted) do
    text
    |> String.split(~r/\r?\n/)
    |> Enum.reduce({nil, nil, %{}}, fn line, {section, key, acc} ->
      trimmed = String.trim(line)

      cond do
        trimmed == "" or String.starts_with?(trimmed, ["#", ";"]) ->
          {section, key, acc}

        Regex.match?(~r/\A\[[^\]]+\]\z/, trimmed) ->
          {String.trim(trimmed, "[") |> String.trim("]") |> String.trim(), nil, acc}

        section != wanted ->
          {section, nil, acc}

        key != nil and Regex.match?(~r/\A[ \t]/, line) ->
          {section, key, Map.update(acc, key, [trimmed], &[trimmed | &1])}

        match = Regex.run(~r/\A([A-Za-z0-9_.-]+)\s*[=:]\s*(.*)\z/, trimmed) ->
          [_, name, value] = match
          values = if String.trim(value) == "", do: [], else: [String.trim(value)]
          {section, name, Map.put(acc, name, values)}

        true ->
          {section, key, acc}
      end
    end)
    |> elem(2)
    |> Map.new(fn {name, values} -> {name, Enum.reverse(values)} end)
  end
end
