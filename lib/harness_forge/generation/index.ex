defmodule HarnessForge.Generation.Index do
  @moduledoc """
  The local code index the prompt-time locator reads (`.olivium/index/`), built from the
  repository's tracked files and its first-parent history with git only. Nothing from
  the repository runs: file text and commit subjects are only matched against fixed
  patterns, and every value that reaches a row passes a fixed character rule.

  - `symbols.tsv` (`name path start end kind`): definitions in Python and
    JavaScript/TypeScript source files (`class`, `def`, `function`, `method`). A span
    ends where the next definition at the same or a smaller indent starts, trailing
    blank lines removed.
  - `terms.tsv` (`term path weight source`): words of commit subjects mapped to the
    source files those commits changed, weighted by term frequency times inverse
    document frequency (`history`), plus the concept terms of a learned bundle
    (`learned`, added by `HarnessForge.Generation.LearnedRender`).
  - `tests.tsv` (`source test support kind`): history test pairs from the profile
    (`history`) and test files named after a source file (`name`).

  Rows are TSV lines without the newline, sorted bytewise and bounded. `rank/3` and
  `card/4` are the reference the generated hook (`HarnessForge.Adapters.ClaudeCode.Locator`)
  implements in awk, and what the locator gate replays: integer arithmetic only, so the
  hook and this module agree byte for byte.
  """

  alias HarnessForge.Analyzers.{Git, Paths}
  alias HarnessForge.Contracts.Error

  @extensions ~w(.py .js .jsx .mjs .cjs .ts .tsx)
  @python ~w(.py)
  @skip_segments ~w(node_modules vendor vendored dist build third_party site-packages __pycache__ .venv venv)
  @path_rule ~r/\A[A-Za-z0-9_.\/-]{1,200}\z/
  @name_rule ~r/\A[A-Za-z_][A-Za-z0-9_]{0,79}\z/
  @token_run ~r/[A-Za-z0-9_]+/
  @token_rule ~r/\A[A-Za-z_][A-Za-z0-9_]{2,63}\z/
  @max_file_bytes 1_048_576
  @max_line_bytes 2_000
  @max_symbols 10_000
  # Byte bounds keep the index rows (carried in the spec, whose JSON is bounded at
  # 2,000,000 bytes) well inside that bound on any repository.
  @max_symbol_bytes 800_000
  @max_term_bytes 500_000
  @max_test_bytes 120_000
  @max_symbols_per_file 300
  @max_terms 12_000
  @max_paths_per_term 8
  @max_tests 2_000
  @max_commits 5_000
  @max_files_per_commit 15
  @max_prompt_tokens 400
  @header "Olivium locator (learned from this repository's history; check before relying on it):"

  @merge_noise ~r/\AMerge (?:branch|remote|tag|commit)\b|\AMerge .* into /
  @dependency_bump ~r/(?i)\A(?:build\(deps|chore\(deps|bump |\[pre-commit\.ci\])/
  @revert ~r/(?i)\Arevert\b/

  @python_patterns [
    {"def", ~r/\A([ \t]*)(?:async[ \t]+)?def[ \t]+([A-Za-z_][A-Za-z0-9_]*)[ \t]*[\(\[]/},
    {"class", ~r/\A([ \t]*)class[ \t]+([A-Za-z_][A-Za-z0-9_]*)[ \t]*[\(:\[]/}
  ]
  @script_patterns [
    {"class",
     ~r/\A([ \t]*)(?:export[ \t]+(?:default[ \t]+)?)?(?:abstract[ \t]+)?class[ \t]+([A-Za-z_][A-Za-z0-9_]*)/},
    {"function",
     ~r/\A([ \t]*)(?:export[ \t]+(?:default[ \t]+)?)?(?:async[ \t]+)?function[ \t]*\*?[ \t]*([A-Za-z_][A-Za-z0-9_]*)[ \t]*\(/},
    {"function",
     ~r/\A([ \t]*)(?:export[ \t]+)?(?:const|let|var)[ \t]+([A-Za-z_][A-Za-z0-9_]*)[ \t]*(?::[^=]*)?=[ \t]*(?:async[ \t]*)?(?:function\b|\([^)]*\)[ \t]*(?::[^=]*)?=>|[A-Za-z_][A-Za-z0-9_]*[ \t]*=>)/},
    {"function", ~r/\A([ \t]*)\S.*?\bfunction[ \t]*\*?[ \t]+([A-Za-z_][A-Za-z0-9_]*)[ \t]*\(/},
    {"function",
     ~r/\A([ \t]*)(?:[A-Za-z_$][A-Za-z0-9_$]*\.)+([A-Za-z_][A-Za-z0-9_]*)[ \t]*=[ \t]*(?:async[ \t]+)?(?:function\b|\([^)]*\)[ \t]*=>)/},
    {"method",
     ~r/\A([ \t]+)(?:(?:static|async|get|set|public|private|protected|readonly|override)[ \t]+)*\*?([A-Za-z_][A-Za-z0-9_]*)[ \t]*\([^;]*\)[ \t]*(?::[^{;]*)?\{[ \t]*\z/}
  ]
  @not_methods ~w(if for while switch catch function return else do try with new typeof constructor)
  @not_names ~w(exports prototype)

  @type commit :: %{
          hash: String.t(),
          parent: String.t() | nil,
          time: integer(),
          subject: String.t(),
          message: String.t(),
          files: [String.t()]
        }

  @spec header() :: String.t()
  def header, do: @header

  @spec bounds() :: map()
  def bounds,
    do: %{
      "symbols" => @max_symbols,
      "terms" => @max_terms,
      "tests" => @max_tests,
      "prompt_tokens" => @max_prompt_tokens
    }

  # -- collecting from git -----------------------------------------------------

  @doc """
  Reads what the index and the locator gate need: HEAD, the tracked files, the symbols
  of every indexable source file in the working tree, and up to #{@max_commits}
  first-parent commits (newest first) with their changed files. git only.
  """
  @spec collect(Path.t()) :: {:ok, map()} | {:error, Error.t()}
  def collect(root) do
    with {:ok, repo} <- Git.open(root),
         {:ok, head} when is_binary(head) <- Git.head(repo),
         {:ok, files} <- Git.ls_files(repo),
         {:ok, commits} <- read_log(repo) do
      files = Enum.filter(files, &plain_path?/1)

      snapshot =
        files
        |> Enum.filter(&indexable?/1)
        |> Map.new(fn path ->
          case Git.read_file(repo.root, path, max_bytes: @max_file_bytes) do
            {:ok, bytes} -> {path, symbols_of(path, bytes)}
            _ -> {path, []}
          end
        end)

      {:ok, %{repo: repo, head: head, files: files, commits: commits, snapshot: snapshot}}
    else
      {:ok, nil} ->
        {:error, %Error{code: "index_unavailable", message: "The repository has no commit"}}

      {:error, _} = error ->
        error
    end
  end

  @log_format "--format=%x01%H%x02%P%x02%ct%x02%B%x03"

  defp read_log(repo) do
    args = [
      "--first-parent",
      "--name-status",
      "--no-renames",
      "-z",
      @log_format,
      "--max-count=#{@max_commits}"
    ]

    case Git.log(repo, args, max_bytes: 64 * 1024 * 1024, timeout_ms: 120_000) do
      {:ok, output} -> {:ok, parse_log(output)}
      {:error, %Error{code: "git_failed"}} -> {:ok, []}
      {:error, _} = error -> error
    end
  end

  @doc false
  def parse_log(output) do
    output
    |> :binary.split(<<1>>, [:global])
    |> Enum.flat_map(fn record ->
      with [header, rest] <- :binary.split(record, <<3>>),
           [hash, parents, stamp, message] <- :binary.split(header, <<2>>, [:global]),
           {time, ""} <- Integer.parse(stamp) do
        message = String.replace_invalid(message, "?")
        changes = changes(rest)

        [
          %{
            hash: hash,
            parent: parents |> String.split(" ", trim: true) |> List.first(),
            time: time,
            subject: message |> String.split("\n", parts: 2) |> hd() |> String.trim(),
            message: String.trim(message),
            changes: changes,
            files: Enum.map(changes, &elem(&1, 1))
          }
        ]
      else
        _ -> []
      end
    end)
  end

  # `--name-status -z`: status and path alternate, NUL-separated (no renames).
  defp changes(rest) do
    rest
    |> :binary.split(<<0>>, [:global])
    |> Enum.map(&String.trim(&1, "\n"))
    |> Enum.reject(&(&1 == ""))
    |> Enum.chunk_every(2)
    |> Enum.flat_map(fn
      [status, path] ->
        if String.valid?(path) and status in ~w(A D M T), do: [{status, path}], else: []

      _ ->
        []
    end)
  end

  # -- paths --------------------------------------------------------------------

  @doc "The contract's plain path rule."
  @spec plain_path?(term()) :: boolean()
  def plain_path?(path) when is_binary(path) do
    Regex.match?(@path_rule, path) and not String.starts_with?(path, ["/", "-"]) and
      not String.contains?(path, ["..", "//"])
  end

  def plain_path?(_), do: false

  @doc "A source file whose definitions the index reads."
  @spec indexable?(String.t()) :: boolean()
  def indexable?(path) do
    plain_path?(path) and Path.extname(path) in @extensions and Paths.source_path?(path) and
      not String.ends_with?(path, [".d.ts", ".min.js"]) and
      not Enum.any?(String.split(path, "/"), &(&1 in @skip_segments))
  end

  # -- symbols ------------------------------------------------------------------

  @doc "Definitions in one file as `{name, path, start, end, kind}`, sorted by line."
  @spec symbols_of(String.t(), binary()) :: [tuple()]
  def symbols_of(path, bytes) when is_binary(bytes) do
    patterns = if Path.extname(path) in @python, do: @python_patterns, else: @script_patterns
    lines = String.split(bytes, "\n")
    count = length(lines)
    blank = blank_lines(lines)

    found =
      lines
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, number} ->
        if byte_size(line) > @max_line_bytes, do: [], else: definition(line, number, patterns)
      end)
      |> Enum.take(@max_symbols_per_file)

    last = last_content_line(count, blank)

    found
    |> Enum.with_index()
    |> Enum.map(fn {{name, number, indent, kind}, index} ->
      next =
        found
        |> Enum.drop(index + 1)
        |> Enum.find(fn {_name, _number, other, _kind} -> other <= indent end)

      stop = if next, do: elem(next, 1) - 1, else: last
      {name, path, number, trim_end(stop, number, blank), kind}
    end)
  end

  defp definition(line, number, patterns) do
    Enum.find_value(patterns, [], fn {kind, pattern} ->
      case Regex.run(pattern, line) do
        [_, indent, name] ->
          if Regex.match?(@name_rule, name) and name not in @not_names and
               not (kind == "method" and name in @not_methods),
             do: [{name, number, byte_size(indent), kind}],
             else: nil

        _ ->
          nil
      end
    end)
  end

  defp blank_lines(lines) do
    lines
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _} -> String.trim(line) == "" end)
    |> MapSet.new(&elem(&1, 1))
  end

  defp last_content_line(count, blank) do
    Enum.find(count..1//-1, 1, &(not MapSet.member?(blank, &1)))
  end

  defp trim_end(stop, start, blank) do
    if stop > start and MapSet.member?(blank, stop),
      do: trim_end(stop - 1, start, blank),
      else: max(stop, start)
  end

  @doc "Symbol rows for a snapshot (`path => symbols`), bounded and sorted bytewise."
  @spec symbol_rows(map()) :: [String.t()]
  def symbol_rows(snapshot) do
    snapshot
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(&elem(&1, 1))
    |> Enum.take(@max_symbols)
    |> Enum.map(fn {name, path, start, stop, kind} ->
      "#{name}\t#{path}\t#{start}\t#{stop}\t#{kind}"
    end)
    |> Enum.uniq()
    |> take_bytes(@max_symbol_bytes)
    |> Enum.sort()
  end

  # Rows in priority order while their bytes (newline included) stay within `cap`.
  defp take_bytes(rows, cap) do
    rows
    |> Enum.reduce_while({[], 0}, fn row, {kept, total} ->
      total = total + byte_size(row) + 1
      if total <= cap, do: {:cont, {[row | kept], total}}, else: {:halt, {kept, total}}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  # -- history terms --------------------------------------------------------------

  @doc """
  History term rows from first-parent commits (any order): each commit that changes 1 to
  #{@max_files_per_commit} indexable source files maps the words of its subject to those
  files. Weight `round(100 * ln(1 + tf) * ln(n / (1 + df)))`, clamped to 1..1000, where `n`
  is the number of such commits and `df` the number of them whose subject has the word.
  """
  @spec term_rows([commit()], MapSet.t(), [String.t()]) :: [String.t()]
  def term_rows(commits, stopwords, existing),
    do: commits |> term_inputs(stopwords) |> rows_from_inputs(existing)

  @doc "Per commit, `{words, sources}` or nil when it teaches nothing (see `term_rows/2`)."
  @spec term_inputs([commit()], MapSet.t()) :: [{[String.t()], [String.t()]} | nil]
  def term_inputs(commits, stopwords) do
    Enum.map(commits, fn commit ->
      sources = commit.files |> Enum.filter(&indexable?/1) |> Enum.uniq()
      words = if noise?(commit.subject), do: [], else: subject_words(commit.subject, stopwords)

      if words != [] and length(sources) in 1..@max_files_per_commit,
        do: {words, sources},
        else: nil
    end)
  end

  @doc """
  History term rows from `term_inputs/2` output (nil entries are skipped), for the files
  in `existing` only. A changed file that no longer exists counts for the one existing
  file whose path ends with it (`werkzeug/utils.py` for `src/werkzeug/utils.py` after a
  move into `src/`); otherwise it is left out, and so is a commit left with no file.
  """
  @spec rows_from_inputs([{[String.t()], [String.t()]} | nil], [String.t()]) :: [String.t()]
  def rows_from_inputs(inputs, existing) do
    relocate = relocation(existing)

    eligible =
      for {words, sources} <- Enum.reject(inputs, &is_nil/1),
          sources = sources |> Enum.flat_map(relocate) |> Enum.uniq(),
          sources != [],
          do: {words, sources}

    n = length(eligible)
    df = eligible |> Enum.flat_map(&elem(&1, 0)) |> Enum.frequencies()

    tf =
      eligible
      |> Enum.flat_map(fn {words, sources} -> for w <- words, p <- sources, do: {w, p} end)
      |> Enum.frequencies()

    tf
    |> Enum.flat_map(fn {{word, path}, count} ->
      idf = :math.log(n / (1 + df[word]))

      if idf > 0 do
        weight = round(100 * :math.log(1 + count) * idf)
        [{word, path, weight |> max(1) |> min(1000)}]
      else
        []
      end
    end)
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.flat_map(fn {_word, rows} ->
      rows
      |> Enum.sort_by(fn {_w, path, weight} -> {-weight, path} end)
      |> Enum.take(@max_paths_per_term)
    end)
    |> Enum.sort_by(fn {word, path, weight} -> {-weight, word, path} end)
    |> Enum.take(@max_terms)
    |> Enum.map(fn {word, path, weight} -> "#{word}\t#{path}\t#{weight}\thistory" end)
    |> take_bytes(@max_term_bytes)
    |> Enum.sort()
  end

  defp relocation(existing) do
    present = MapSet.new(existing)

    moved =
      existing
      |> Enum.flat_map(fn path ->
        parts = String.split(path, "/")
        for n <- 1..(length(parts) - 1)//1, do: {parts |> Enum.drop(n) |> Enum.join("/"), path}
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    fn path ->
      cond do
        MapSet.member?(present, path) -> [path]
        match?([_], Map.get(moved, path)) -> moved[path]
        true -> []
      end
    end
  end

  @doc "Merge noise, dependency bumps and reverts teach nothing about where code lives."
  @spec noise?(String.t()) :: boolean()
  def noise?(subject) do
    Regex.match?(@merge_noise, subject) or Regex.match?(@dependency_bump, subject) or
      Regex.match?(@revert, subject)
  end

  defp subject_words(subject, stopwords) do
    subject
    |> tokens()
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(stopwords, &1))
  end

  # -- test pairs -------------------------------------------------------------------

  @doc """
  `tests.tsv` rows: the profile's history pairs (`history`, or `name` when the test is
  named after the source) and, for every indexed source file, the tracked test files
  named after it (`name`, support 1). Bounded, sorted bytewise.
  """
  @spec test_rows([map()], [String.t()], [String.t()]) :: [String.t()]
  def test_rows(pairs, files, sources) do
    history =
      for pair <- pairs || [],
          plain_path?(pair["source"]) and plain_path?(pair["test"]),
          do:
            {pair["source"], pair["test"], pair["support"],
             if(pair["kind"] == "named_after", do: "name", else: "history")}

    known = MapSet.new(history, fn {source, test, _, _} -> {source, test} end)

    tests =
      files
      |> Enum.filter(
        &(plain_path?(&1) and Paths.test_path?(&1) and Path.extname(&1) in @extensions)
      )
      |> Enum.group_by(&test_subject/1)

    named =
      for source <- Enum.sort(sources),
          test <- Map.get(tests, stem(source), []),
          not MapSet.member?(known, {source, test}),
          do: {source, test, 1, "name"}

    (history ++ named)
    |> Enum.sort_by(fn {source, test, support, _} -> {-support, source, test} end)
    |> Enum.take(@max_tests)
    |> Enum.map(fn {source, test, support, kind} -> "#{source}\t#{test}\t#{support}\t#{kind}" end)
    |> take_bytes(@max_test_bytes)
    |> Enum.sort()
  end

  defp test_subject(test) do
    test
    |> Path.basename()
    |> strip_extensions()
    |> String.replace(~r/\Atest_|_test\z|_spec\z|\.test\z|\.spec\z/, "")
    |> String.downcase()
  end

  defp strip_extensions(name) do
    case Path.extname(name) do
      "" -> name
      extension -> String.trim_trailing(name, extension)
    end
  end

  @doc "The lowercase file name without its last extension, as the hook computes it."
  @spec stem(String.t()) :: String.t()
  def stem(path) do
    name = path |> String.split("/") |> List.last()

    case :binary.matches(name, ".") do
      [] -> String.downcase(name)
      matches -> name |> binary_part(0, elem(List.last(matches), 0)) |> String.downcase()
    end
  end

  # -- prompt text ----------------------------------------------------------------------

  @doc """
  Distinct tokens of a text in order of appearance, at most #{@max_prompt_tokens}: maximal
  runs of `[A-Za-z0-9_]` that start with a letter or `_` and are 3 to 64 characters long.
  """
  @spec tokens(String.t()) :: [String.t()]
  def tokens(text) do
    @token_run
    |> Regex.scan(text)
    |> List.flatten()
    |> Enum.filter(&Regex.match?(@token_rule, &1))
    |> Enum.uniq()
    |> Enum.take(@max_prompt_tokens)
  end

  @doc "Lowercase, every run of other characters one space, trimmed."
  @spec normalize(String.t()) :: String.t()
  def normalize(text) do
    text
    |> String.downcase(:ascii)
    |> String.replace(~r/[^a-z0-9_]+/, " ")
    |> String.trim()
  end

  # -- ranking and the card --------------------------------------------------------------

  @doc "Lookup tables for `rank/3` from exported rows (the hook reads the same rows)."
  @spec prepare([String.t()], [String.t()]) :: map()
  def prepare(symbol_rows, term_rows) do
    symbols =
      Enum.map(symbol_rows, fn row ->
        [name, path, start, stop, _kind] = String.split(row, "\t")
        {name, path, String.to_integer(start), String.to_integer(stop)}
      end)

    terms =
      Enum.map(term_rows, fn row ->
        [term, path, weight, source] = String.split(row, "\t")
        {term, path, String.to_integer(weight), source}
      end)

    %{
      symbols:
        Enum.group_by(symbols, &elem(&1, 0), fn {_, path, start, stop} -> {path, start, stop} end),
      history:
        terms
        |> Enum.filter(&(elem(&1, 3) == "history"))
        |> Enum.group_by(&elem(&1, 0), fn {_, path, weight, _} -> {path, weight} end),
      learned: for({term, path, weight, "learned"} <- terms, do: {term, path, weight}),
      paths:
        (Enum.map(symbols, &elem(&1, 1)) ++ Enum.map(terms, &elem(&1, 1)))
        |> Enum.uniq()
        |> Enum.sort()
    }
  end

  @doc """
  Paths with a positive score, best first (ties by path), with the symbol hits per path.
  Integer constants:

  - `path_weight` for a path the prompt names in full; a named file name with an
    extension (`request.js`) shares it between the indexed paths of that name, when there
    are at most `symbol_max_locations`.
  - `symbol_weight`, shared the same way between the locations of a prompt token that
    names a definition.
  - `stem_weight` once per path whose file stem is a prompt word (except `stem_stopwords`).
  - History term weights times `history_scale` / 100; per path only the
    `term_top_k` largest contributions count (0 = all), so a long prompt does not lift a
    file that many ordinary words point to. Learned terms times `learned_scale` / 100.
  """
  @spec rank(String.t(), map(), map()) :: {[{String.t(), integer()}], map()}
  def rank(prompt, prepared, constants) do
    toks = tokens(prompt)
    words = toks |> Enum.map(&String.downcase(&1, :ascii)) |> MapSet.new()
    norm = " " <> normalize(prompt) <> " "
    stop_stems = MapSet.new(constants["stem_stopwords"] || [])
    limit = constants["symbol_max_locations"]

    scores = path_mentions(prompt, prepared.paths, constants["path_weight"] || 0, limit)

    {scores, hits} =
      Enum.reduce(toks, {scores, %{}}, fn token, acc ->
        locations = Map.get(prepared.symbols, token, [])
        count = length(locations)

        if count >= 1 and count <= limit do
          Enum.reduce(locations, acc, fn {path, start, stop}, {scores, hits} ->
            {add(scores, path, div(constants["symbol_weight"], count)),
             Map.update(hits, path, [{start, token, stop}], &[{start, token, stop} | &1])}
          end)
        else
          acc
        end
      end)

    scores =
      Enum.reduce(prepared.paths, scores, fn path, scores ->
        stem = stem(path)

        if MapSet.member?(words, stem) and not MapSet.member?(stop_stems, stem),
          do: add(scores, path, constants["stem_weight"]),
          else: scores
      end)

    scores =
      words
      |> Enum.flat_map(fn word ->
        for {path, weight} <- Map.get(prepared.history, word, []),
            do: {path, div(weight * constants["history_scale"], 100)}
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.reduce(scores, fn {path, values}, scores ->
        values = Enum.sort(values, :desc)

        values =
          if constants["term_top_k"] > 0,
            do: Enum.take(values, constants["term_top_k"]),
            else: values

        add(scores, path, Enum.sum(values))
      end)

    scores =
      Enum.reduce(prepared.learned, scores, fn {term, path, weight}, scores ->
        if String.contains?(norm, " " <> term <> " "),
          do: add(scores, path, div(weight * constants["learned_scale"], 100)),
          else: scores
      end)

    ranked =
      scores
      |> Enum.filter(fn {_path, score} -> score > 0 end)
      |> Enum.sort_by(fn {path, score} -> {-score, path} end)

    {ranked, hits}
  end

  @doc """
  Path-like words of a text: maximal runs of `[A-Za-z0-9_./-]`, without trailing `.` or
  `-` and a leading `./`.
  """
  @spec path_words(String.t()) :: MapSet.t()
  def path_words(text) do
    ~r/[A-Za-z0-9_.\/-]+/
    |> Regex.scan(text)
    |> List.flatten()
    |> Enum.map(fn word ->
      word |> String.trim_trailing(".") |> String.trim_trailing("-") |> strip_dot_slash()
    end)
    |> MapSet.new()
  end

  defp strip_dot_slash("./" <> rest), do: rest
  defp strip_dot_slash(word), do: word

  defp path_mentions(_prompt, _paths, 0, _limit), do: %{}

  defp path_mentions(prompt, paths, weight, limit) do
    named = path_words(prompt)
    by_name = Enum.group_by(paths, &(&1 |> String.split("/") |> List.last()))

    Enum.reduce(paths, %{}, fn path, scores ->
      name = path |> String.split("/") |> List.last()
      count = length(by_name[name])

      cond do
        MapSet.member?(named, path) ->
          add(scores, path, weight)

        String.contains?(name, ".") and MapSet.member?(named, name) and count <= limit ->
          add(scores, path, div(weight, count))

        true ->
          scores
      end
    end)
  end

  defp add(scores, path, value), do: Map.update(scores, path, value, &(&1 + value))

  @doc """
  The card for a prompt, or nil when the locator abstains: it prints only when the best
  score is at least `min_score` and the best path has a symbol hit or leads the second by
  at least `min_margin` points and `min_margin_percent` percent. At most `card_bytes` bytes, cut after a whole line. `extras`:
  `tests` and `cochange` rows (TSV lines), `test_command` (argv with `{file}`, or nil),
  `pitfalls` (`%{"id", "paths", "triggers", "text"}`, triggers normalized).
  Returns `{card | nil, printed_paths}`.
  """
  @spec card(String.t(), map(), map(), map()) :: {String.t() | nil, [String.t()]}
  def card(prompt, prepared, extras, constants) do
    {ranked, hits} = rank(prompt, prepared, constants)

    case ranked do
      [{first, best} | rest] ->
        second =
          case rest,
            do: (
              [{_, score} | _] -> score
              [] -> 0
            )

        if best >= constants["min_score"] and
             (Map.has_key?(hits, first) or lead?(best, second, constants)) do
          render(Enum.take(ranked, 3) |> Enum.map(&elem(&1, 0)), hits, prompt, extras, constants)
        else
          {nil, []}
        end

      [] ->
        {nil, []}
    end
  end

  # The best path leads the second by `min_margin` points and by `min_margin_percent`.
  defp lead?(best, second, constants) do
    best - second >= constants["min_margin"] and
      best * 100 >= second * (100 + constants["min_margin_percent"])
  end

  defp render(top, hits, prompt, extras, constants) do
    path_lines =
      Enum.map(top, fn path ->
        spans =
          hits
          |> Map.get(path, [])
          |> Enum.uniq()
          |> Enum.sort()
          |> Enum.take(3)
          |> Enum.map_join(", ", fn {start, name, stop} -> "#{name} #{start}-#{stop}" end)

        {path, if(spans == "", do: "- #{path}", else: "- #{path}: #{spans}")}
      end)

    tests = card_tests(top, extras["tests"] || [])
    partners = card_partners(hd(top), top ++ tests, extras["cochange"] || [])
    norm = " " <> normalize(prompt) <> " "

    lines =
      Enum.map(path_lines, fn {path, line} -> {path, line} end) ++
        optional("Tests: ", tests) ++
        optional("Co-changed: ", partners) ++
        run_line(extras["test_command"], tests) ++
        pitfall_line(extras["pitfalls"] || [], top, norm)

    {text, printed} =
      Enum.reduce_while(lines, {@header <> "\n", []}, fn {path, line}, {text, printed} ->
        candidate = text <> line <> "\n"

        if byte_size(candidate) <= constants["card_bytes"],
          do: {:cont, {candidate, if(path, do: [path | printed], else: printed)}},
          else: {:halt, {text, printed}}
      end)

    {text, Enum.reverse(printed)}
  end

  defp optional(_label, []), do: []
  defp optional(label, items), do: [{nil, label <> Enum.join(items, ", ")}]

  defp card_tests(top, rows) do
    parsed =
      Enum.map(rows, fn row ->
        [source, test, support, _kind] = String.split(row, "\t")
        {source, test, String.to_integer(support)}
      end)

    top
    |> Enum.flat_map(fn path ->
      parsed
      |> Enum.filter(&(elem(&1, 0) == path))
      |> Enum.sort_by(fn {_, test, support} -> {-support, test} end)
      |> Enum.map(&elem(&1, 1))
    end)
    |> Enum.reject(&(&1 in top))
    |> Enum.uniq()
    |> Enum.take(2)
  end

  defp card_partners(first, shown, rows) do
    rows
    |> Enum.map(fn row -> String.split(row, "\t") end)
    |> Enum.filter(fn [path | _] -> path == first end)
    |> Enum.map(fn [_path, partner, support | _] -> {partner, String.to_integer(support)} end)
    |> Enum.sort_by(fn {partner, support} -> {-support, partner} end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.reject(&(&1 in shown))
    |> Enum.uniq()
    |> Enum.take(2)
  end

  defp run_line(argv, [test | _]) when is_list(argv) do
    if "{file}" in argv,
      do: [{nil, "Run: " <> Enum.map_join(argv, " ", &if(&1 == "{file}", do: test, else: &1))}],
      else: []
  end

  defp run_line(_argv, _tests), do: []

  defp pitfall_line(pitfalls, top, norm) do
    pitfalls
    |> Enum.sort_by(& &1["id"])
    |> Enum.find(fn pitfall ->
      Enum.any?(pitfall["paths"], &(&1 in top)) and
        Enum.any?(pitfall["triggers"], &String.contains?(norm, " " <> &1 <> " "))
    end)
    |> case do
      nil -> []
      pitfall -> [{nil, "Pitfall: " <> pitfall["text"]}]
    end
  end
end
