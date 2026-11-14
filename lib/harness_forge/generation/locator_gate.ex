defmodule HarnessForge.Generation.LocatorGate do
  @moduledoc """
  The per-repository replay that decides whether the prompt-time locator is rendered
  (v4 design, section 4.2). Deterministic and model-free: git and pattern matching only.

  For the last `replay_commits` fix-like first-parent commits (the history analyzer's fix
  words, without the documentation and tooling words) that change 1 to 6 indexable
  source files, the index is rebuilt at the commit's parent (definitions read from that
  revision, history terms from that commit and older ones) and the card is computed for
  the commit message, `#123` references removed. Learned terms are never used here: they
  were learned from these same commits.

  The gate passes when at least `min_replay` commits were replayed, at least one card was
  printed, at least `min_top3_percent` of printed cards name a changed source file, the
  wrong cards (printed, no changed file named) are at most `max_wrong_percent` of the
  replayed commits, and every card fits `card_bytes`. The numbers are recorded whether it
  passes or not.
  """

  alias HarnessForge.Analyzers.Git
  alias HarnessForge.Generation.Index

  @fix ~r/(?i)\b(?:fix|fixes|fixed|fixing|bugfix|hotfix|regression)\b/
  @not_a_code_fix ~r/(?i)\b(?:typo|typos|typing|docs?|documentation|readme|lint|linting|changelog|style|ci|deps?|dependency|dependencies|flaky)\b/
  @reference ~r/\(#\d+\)|#\d+/
  @max_sources 6

  @doc """
  Replays the repository collected by `Index.collect/1`. `extras` are the card inputs
  other than the index (tests, co-change, test command; pitfalls are not used).
  Returns the gate numbers (`replay_n`, `top3_hits`, `wrong`, `max_card_bytes`,
  `status`) and, under `"cases"`, one row per replayed commit for analysis.
  """
  @spec run(map(), map(), map()) :: map()
  def run(collected, extras, constants) do
    collected
    |> cases(constants)
    |> evaluate(Map.delete(extras, "pitfalls"), constants)
  end

  @doc "The replay cases: commit, prompt, changed source files, the index at the parent."
  @spec cases(map(), map()) :: [map()]
  def cases(%{commits: commits} = collected, constants) do
    stopwords = MapSet.new(constants["term_stopwords"] || [])
    inputs = Index.term_inputs(commits, stopwords)
    parents = if commits == [], do: [], else: tl(commits) ++ [nil]

    picked =
      commits
      |> Enum.zip(parents)
      |> Enum.with_index()
      |> Enum.filter(fn {{commit, parent}, _i} -> replayable?(commit, parent) end)
      |> Enum.map(fn {{commit, _parent}, i} -> {commit, i} end)
      |> Enum.take(constants["replay_commits"])

    {cases, _state} =
      Enum.map_reduce(picked, {0, collected.snapshot}, fn {commit, i}, {at, snapshot} ->
        target = i + 1
        snapshot = move(collected.repo, commits, snapshot, at, target)
        terms = inputs |> Enum.drop(target) |> Index.rows_from_inputs(Map.keys(snapshot))
        symbols = Index.symbol_rows(snapshot)

        replay = %{
          "commit" => commit.hash,
          "prompt" => Regex.replace(@reference, commit.message, ""),
          "gold" => sources(commit),
          "prepared" => Index.prepare(symbols, terms)
        }

        {replay, {target, snapshot}}
      end)

    cases
  end

  defp replayable?(commit, parent) do
    parent != nil and commit.parent == parent.hash and Regex.match?(@fix, commit.subject) and
      not Regex.match?(@not_a_code_fix, commit.subject) and not Index.noise?(commit.subject) and
      length(sources(commit)) in 1..@max_sources
  end

  defp sources(commit), do: commit.files |> Enum.filter(&Index.indexable?/1) |> Enum.uniq()

  # The snapshot holds the definitions after commit `at` (0 is the working tree at HEAD).
  # Moving it to the older commit `target` re-reads every file the commits in between
  # changed, at `target`; a file missing there leaves the snapshot.
  # A file exists at `target` unless the oldest commit in between that touches it added
  # it; only existing files are read, eight at a time.
  defp move(repo, commits, snapshot, at, target) do
    hash = Enum.at(commits, target).hash

    oldest =
      commits
      |> Enum.slice(at, target - at)
      |> Enum.flat_map(& &1.changes)
      |> Enum.filter(fn {_status, path} -> Index.indexable?(path) end)
      |> Map.new(fn {status, path} -> {path, status} end)

    {present, absent} =
      oldest |> Enum.sort() |> Enum.split_with(fn {_path, status} -> status != "A" end)

    snapshot = Map.drop(snapshot, Enum.map(absent, &elem(&1, 0)))

    present
    |> Task.async_stream(
      fn {path, _status} ->
        case Git.show_path(repo, hash, path, max_bytes: 1_048_576) do
          {:ok, bytes} -> {path, Index.symbols_of(path, bytes)}
          {:error, _} -> {path, nil}
        end
      end,
      max_concurrency: 8,
      ordered: true,
      timeout: 120_000
    )
    |> Enum.reduce(snapshot, fn
      {:ok, {path, nil}}, snapshot -> Map.delete(snapshot, path)
      {:ok, {path, symbols}}, snapshot -> Map.put(snapshot, path, symbols)
    end)
  end

  @doc "Gate numbers for replay cases under the given constants."
  @spec evaluate([map()], map(), map()) :: map()
  def evaluate(cases, extras, constants) do
    rows =
      Enum.map(cases, fn replay ->
        {card, printed} = Index.card(replay["prompt"], replay["prepared"], extras, constants)
        hit = Enum.any?(printed, &(&1 in replay["gold"]))

        %{
          "commit" => String.slice(replay["commit"], 0, 12),
          "gold" => replay["gold"],
          "printed" => printed,
          "card_bytes" => if(card, do: byte_size(card), else: 0),
          "hit" => card != nil and hit
        }
      end)

    printed = Enum.count(rows, &(&1["card_bytes"] > 0))
    hits = Enum.count(rows, & &1["hit"])
    wrong = printed - hits
    max_bytes = rows |> Enum.map(& &1["card_bytes"]) |> Enum.max(fn -> 0 end)
    replayed = length(rows)
    gate = constants["gate"]

    passed =
      replayed >= gate["min_replay"] and printed >= 1 and
        hits * 100 >= gate["min_top3_percent"] * printed and
        wrong * 100 <= gate["max_wrong_percent"] * replayed and
        max_bytes <= constants["card_bytes"]

    %{
      "status" => if(passed, do: "passed", else: "failed"),
      "replay_n" => replayed,
      "top3_hits" => hits,
      "wrong" => wrong,
      "max_card_bytes" => max_bytes,
      "cases" => rows
    }
  end
end
