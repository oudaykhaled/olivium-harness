defmodule HarnessForge.Analyzers.History do
  @moduledoc """
  Model-free repository history statistics, from `git log` only.

  Each entry of the first-parent history is one integrated change, which keeps
  pull-request merges and squash merges comparable. Commit subjects are held only
  while computing and never appear in the output. No author identity is read at all.
  Rates are measured over the commits within #{1095} days of the newest analyzed commit,
  so the result depends on repository state and not on the clock.
  """

  alias HarnessForge.Analyzers.{Git, Inventory, Paths, Privacy, Signal}

  @detector "git.history"
  @hash ~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/
  @window_days 1095
  @minimum_sample 200
  @default_commits 5_000
  @format "--format=%x01%H%x02%ct%x02%P%x02%s%x03"
  @max_files_per_change 25
  @conventional ~r/\A(feat|fix|docs|style|refactor|perf|test|tests|build|ci|chore|revert)(\([^)]+\))?!?: \S/
  @fix ~r/(?i)\b(?:fix|fixes|fixed|fixing|bugfix|hotfix|regression)\b/
  @not_a_code_fix ~r/(?i)\b(?:typo|typos|typing|docs?|documentation|readme|lint|linting|changelog|style|ci|deps?|dependency|dependencies|flaky)\b/
  @merge_noise ~r/\AMerge (?:branch|remote|tag|commit)\b|\AMerge .* into /
  @dependency_bump ~r/(?i)\A(?:build\(deps|chore\(deps|bump |\[pre-commit\.ci\])/
  @revert ~r/(?i)\Arevert\b/
  # A test with every fix is what any agent does unasked, so measuring it alone does
  # not earn a line in the output. A contributing document can still raise it.
  @generic_rule_limit 69
  # Candidate rows for the hooks' data files; the mapping applies the contract caps.
  @pair_candidates 1_000
  @test_pair_support 2
  @partner_support 4
  @partner_percent 40
  @not_a_test_module ~w(conftest.py __init__.py)
  # `history.native_clusters` (design: skills and subagents from history, section 3.1).
  @max_clusters 8
  @cluster_files 6
  @cluster_shas 5
  @cluster_tests 4
  @cluster_risk 4
  @followup_seconds 7 * 86_400
  # Commits that move many files for reasons unrelated to how the code works (formatting,
  # linting, version-support drops, migrations, version bumps, maintenance-only types).
  # They say nothing about which files belong together, so the clusters ignore them.
  @maintenance ~r/\b(?:ruff|black|isort|prettier|eslint|flake8|pyupgrade|pre-commit|reformat\w*|formatting|lint|linting|typos?|copyright|licen[cs]e|bump\w*)\b|\bdrop(?:s|ped|ping)?\b.*\bsupport\b|\bmigrat\w*\b.*\bto\b|\A(?:style|chore|ci|build|docs)(?:\([^)]*\))?!?:/i
  @cluster_fix_files 3

  @doc """
  Analyze the repository. `git` is `{:ok, repo}` or `{:unavailable, reason}`.
  Returns the signals and the detector's completeness flags.
  """
  @spec analyze({:ok, Git.t()} | {:unavailable, String.t()}, keyword()) :: {[map()], map()}
  def analyze({:unavailable, reason}, _opts) do
    sample = %{
      "state" => "git_unavailable",
      "reason" => reason,
      "commits" => 0,
      "window_days" => @window_days
    }

    {[Signal.new("history.sample", sample, 0, @detector)], %{complete: false, truncated: false}}
  end

  def analyze({:ok, repo}, opts) do
    limit = max_commits(opts)

    case read_log(repo, limit) do
      {:ok, commits} ->
        known = Keyword.get(opts, :files, [])
        renames = if commits == [], do: %{}, else: read_renames(repo, limit)
        summarize(commits, shallow?(repo), limit, known, renames)

      {:error, _} ->
        sample = %{"state" => "unreadable", "commits" => 0, "window_days" => @window_days}

        {[Signal.new("history.sample", sample, 0, @detector)],
         %{complete: false, truncated: false}}
    end
  end

  defp max_commits(opts) do
    case opts[:max_commits] do
      value when is_integer(value) and value > 0 -> min(value, 100_000)
      _ -> @default_commits
    end
  end

  defp shallow?(repo) do
    case Git.rev_parse(repo, ["--is-shallow-repository"]) do
      {:ok, output} -> String.trim(output) == "true"
      _ -> false
    end
  end

  defp read_log(repo, limit) do
    args = [
      "--first-parent",
      "--name-only",
      "--no-renames",
      "-z",
      @format,
      "--max-count=#{limit}"
    ]

    case Git.log(repo, args, max_bytes: 64 * 1024 * 1024) do
      {:ok, output} ->
        with {:ok, hashes} <- read_hashes(repo, limit), do: {:ok, verified(parse(output), hashes)}

      {:error, %{code: "git_failed"}} ->
        {:ok, []}

      {:error, _} = failure ->
        failure
    end
  end

  # The first-parent hashes alone, one per line: hexadecimal only, so no commit subject
  # or file name can change them.
  defp read_hashes(repo, limit) do
    case Git.log(repo, ["--first-parent", "--format=%H", "--max-count=#{limit}"],
           max_bytes: 16 * 1024 * 1024
         ) do
      {:ok, output} ->
        {:ok, output |> String.split("\n", trim: true) |> Enum.filter(&Regex.match?(@hash, &1))}

      {:error, %{code: "git_failed"}} ->
        {:ok, []}

      {:error, _} = failure ->
        failure
    end
  end

  @doc false
  # A commit subject or a file name may itself hold the record separators (bytes 1, 2
  # and 3) and so forge a record with a hash that is not in this history, or take
  # another commit's files. A record is kept only when its hash is one of `hashes`, it
  # is the only record with that hash, and it comes in history order; the others are
  # dropped, never repaired.
  def verified(records, hashes) do
    index = hashes |> Enum.with_index() |> Map.new()
    counts = Enum.frequencies_by(records, & &1.hash)

    {kept, _last} =
      Enum.reduce(records, {[], -1}, fn record, {kept, last} ->
        position = Map.get(index, record.hash)

        if is_integer(position) and counts[record.hash] == 1 and position > last,
          do: {[record | kept], position},
          else: {kept, last}
      end)

    Enum.reverse(kept)
  end

  # Renamed files, mapped to their newest names (`git log -M`, renames only), so the
  # history of a file that moved counts for the file as it is named now. A name that is
  # not reportable is left out of the map. Unreadable output gives an empty map.
  defp read_renames(repo, limit) do
    args = [
      "--first-parent",
      "-M",
      "--diff-filter=R",
      "--name-status",
      "-z",
      "--format=",
      "--max-count=#{limit}"
    ]

    case Git.log(repo, args, max_bytes: 16 * 1024 * 1024) do
      {:ok, output} -> output |> String.replace_invalid("?") |> parse_renames()
      {:error, _} -> %{}
    end
  end

  @doc false
  def parse_renames(output) do
    output
    |> :binary.split(<<0>>, [:global])
    |> Enum.map(&String.trim(&1, "\n"))
    |> rename_rows([])
    # Newest first: a later rename of the new name is already in the map.
    |> Enum.reduce(%{}, fn {old, new}, map ->
      newest = Map.get(map, new, new)
      if old == newest, do: map, else: Map.put_new(map, old, newest)
    end)
  end

  defp rename_rows(["R" <> score, old, new | rest], acc) do
    if Regex.match?(~r/\A[0-9]{0,3}\z/, score) and reportable?(old) and reportable?(new),
      do: rename_rows(rest, [{old, new} | acc]),
      else: rename_rows(rest, acc)
  end

  defp rename_rows([_ | rest], acc), do: rename_rows(rest, acc)
  defp rename_rows([], acc), do: Enum.reverse(acc)

  @doc false
  def parse(output) do
    output
    |> String.replace_invalid("?")
    |> :binary.split(<<1>>, [:global])
    |> Enum.flat_map(&parse_record/1)
  end

  defp parse_record(record) do
    case :binary.split(record, <<3>>) do
      [header, rest] ->
        case String.split(header, <<2>>) do
          [hash, stamp, parents, subject] ->
            case Integer.parse(stamp) do
              {time, ""} ->
                [
                  %{
                    hash: hash,
                    time: time,
                    merge?: length(String.split(parents)) > 1,
                    subject: subject,
                    files: parse_files(rest)
                  }
                ]

              _ ->
                []
            end

          _ ->
            []
        end

      _ ->
        []
    end
  end

  defp parse_files(rest) do
    rest
    |> :binary.split(<<0>>, [:global])
    |> Enum.map(&String.trim(&1, "\n"))
    |> Enum.filter(&reportable?/1)
  end

  # A path may be unrepresentable in the signals contract, or name a person or a secret.
  defp reportable?(path) do
    path != "" and Inventory.representable?(path) and not Privacy.secret_path?(path) and
      not Privacy.identity?(path)
  end

  defp summarize([], _shallow?, _limit, _known, _renames) do
    sample = %{"state" => "empty", "commits" => 0, "window_days" => @window_days}
    {[Signal.new("history.sample", sample, 0, @detector)], %{complete: true, truncated: false}}
  end

  defp summarize(commits, shallow?, limit, known, renames) do
    newest = commits |> Enum.map(& &1.time) |> Enum.max()
    {recent, _older} = split_window(commits, newest)
    truncated? = length(commits) >= limit and List.last(commits).time >= newest - window_seconds()

    state =
      cond do
        shallow? -> "shallow"
        truncated? -> "truncated"
        true -> "complete"
      end

    changes = Enum.reject(recent, &Regex.match?(@merge_noise, &1.subject))

    sample = %{
      "state" => state,
      "commits" => length(commits),
      "changes_in_window" => length(changes),
      "window_days" => @window_days,
      "newest_commit" => hd(commits).hash
    }

    sample_confidence = %{"complete" => 100, "truncated" => 75, "shallow" => 30}[state]

    factor = %{state: state}

    # A shallow clone that holds a full sample is graded by what it holds, like a
    # history cut off at the commit limit; a smaller one stays out of the auto bucket.
    # This covers the data behind the generated skills and subagents and the stop
    # hook's test pairs; the CLAUDE.md signals keep the shallow cap.
    native_factor =
      if state == "shallow" and length(commits) >= @minimum_sample,
        do: %{state: "truncated"},
        else: factor

    signals =
      [
        Signal.new("history.sample", sample, sample_confidence, @detector, [
          Signal.commits([hd(commits).hash])
        ])
      ] ++
        commit_style(changes, factor) ++
        fix_signals(changes, known, factor) ++
        hot_signals(changes, factor) ++
        cochange(changes, factor, known) ++
        pair_signals(changes, native_factor, known) ++
        native_clusters(changes, native_factor, known, hd(commits).hash, renames)

    {signals, %{complete: state == "complete", truncated: truncated?}}
  end

  defp window_seconds, do: @window_days * 86_400

  # Keeps at least a minimum sample so a repository with a long quiet stretch before
  # its newest commit still gets rates, computed against commit timestamps only.
  defp split_window(commits, newest) do
    {inside, rest} =
      commits
      |> Enum.with_index()
      |> Enum.split_with(fn {commit, index} ->
        commit.time >= newest - window_seconds() or index < @minimum_sample
      end)

    {Enum.map(inside, &elem(&1, 0)), Enum.map(rest, &elem(&1, 0))}
  end

  # Confidence for a rate rises with the size of the sample and is capped when the
  # history is shallow, so such a result stays out of the auto bucket.
  defp confidence(rate, sample, %{state: state}) do
    base = div(rate * min(sample, 10), 10)

    case state do
      "shallow" -> min(base, 39)
      "truncated" -> max(base - 10, 0)
      _ -> base
    end
  end

  defp commit_style(changes, factor) do
    total = length(changes)

    subjects = Enum.map(changes, & &1.subject)
    conventional = Enum.filter(subjects, &Regex.match?(@conventional, &1))
    rate = Signal.percent(length(conventional), total)

    types =
      conventional
      |> Enum.map(fn subject -> Regex.run(@conventional, subject) |> Enum.at(1) end)
      |> Enum.frequencies()
      |> Enum.sort_by(fn {type, count} -> {-count, type} end)
      |> Enum.map(fn {type, _} -> type end)

    value =
      %{
        "conventional_percent" => rate,
        "conventional_commits" => length(conventional),
        "changes" => total,
        "types" => types
      }
      |> with_rules(style_rule(rate, total, types, factor))

    [Signal.new("history.commit_style", value, confidence(rate, total, factor), @detector)]
  end

  defp style_rule(rate, total, types, factor) when rate >= 60 and total >= 20 do
    examples = types |> Enum.take(3) |> Enum.join(", ")

    [
      %{
        "text" =>
          "Write commit subjects as Conventional Commits, `type(scope): summary` with types such as #{examples}",
        "confidence" => confidence(rate, total, factor),
        "topic" => "commit_style"
      }
    ]
  end

  defp style_rule(_, _, _, _), do: []

  defp source_change?(change) do
    Enum.any?(change.files, &Paths.source_path?/1) and
      not Regex.match?(@dependency_bump, change.subject)
  end

  defp fix?(change) do
    Regex.match?(@fix, change.subject) and not Regex.match?(@not_a_code_fix, change.subject)
  end

  defp fix_signals(changes, known, factor) do
    source_changes = Enum.filter(changes, &source_change?/1)
    fixes = Enum.filter(source_changes, &fix?/1)

    [
      tests_signal(fixes, source_changes, factor),
      changelog_signal(fixes, source_changes, known, factor)
    ]
  end

  # A rule is measured on bug fixes when they are numerous enough, and on all source
  # changes otherwise, so a project that rarely says "fix" still gets a result.
  defp measures(fixes, source_changes, predicate, factor) do
    [
      {:fix, "bug fix", "recent fixes", length(Enum.filter(fixes, predicate)), length(fixes)},
      {:source, "source change", "recent source changes",
       length(Enum.filter(source_changes, predicate)), length(source_changes)}
    ]
    |> Enum.map(fn {kind, scope, sample, matching, total} ->
      rate = Signal.percent(matching, total)

      %{
        kind: kind,
        scope: scope,
        sample: sample,
        matching: matching,
        total: total,
        rate: rate,
        confidence: confidence(rate, total, factor)
      }
    end)
  end

  defp best([fix, source]) do
    if source.confidence > fix.confidence, do: source, else: fix
  end

  defp tests_signal(fixes, source_changes, factor) do
    predicate = fn change -> Enum.any?(change.files, &Paths.test_path?/1) end
    measured = measures(fixes, source_changes, predicate, factor)
    chosen = best(measured)

    directory =
      fixes |> Enum.flat_map(& &1.files) |> Enum.filter(&Paths.test_path?/1) |> top_directory()

    place = if directory, do: " under #{directory}/", else: ""

    rule =
      if chosen.total >= 5 and chosen.rate >= 50 do
        [
          %{
            "text" => "Include a test change#{place} with every #{chosen.scope}",
            "confidence" => min(chosen.confidence, @generic_rule_limit),
            "topic" => "tests"
          }
        ]
      else
        []
      end

    value =
      measure_values(measured)
      |> with_rules(rule)

    evidence = [
      Signal.commits(
        fixes
        |> Enum.filter(predicate)
        |> Enum.map(& &1.hash)
        |> Enum.sort()
        |> Enum.take(10)
      )
    ]

    Signal.new("history.fix_tests", value, chosen.confidence, @detector, evidence)
  end

  defp measure_values([fix, source]) do
    %{
      "fix_changes" => fix.total,
      "fix_matching" => fix.matching,
      "fix_percent" => fix.rate,
      "source_changes" => source.total,
      "source_matching" => source.matching,
      "source_percent" => source.rate
    }
  end

  defp top_directory([]), do: nil

  defp top_directory(paths) do
    paths
    |> Enum.map(&(&1 |> String.split("/") |> hd()))
    |> Enum.frequencies()
    |> Enum.sort_by(fn {name, count} -> {-count, name} end)
    |> hd()
    |> elem(0)
  end

  defp changelog_signal(fixes, source_changes, known, factor) do
    predicate = fn change -> Enum.any?(change.files, &Paths.changelog_target/1) end

    target =
      source_changes
      |> Enum.flat_map(fn change ->
        change.files
        |> Enum.map(&Paths.changelog_target/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
      end)
      |> Enum.frequencies()
      |> Enum.filter(fn {name, _} -> changelog_exists?(name, known) end)
      |> Enum.sort_by(fn {name, count} -> {-count, name} end)
      |> List.first()

    measured = measures(fixes, source_changes, predicate, factor)
    chosen = best(measured)

    value =
      measure_values(measured)
      |> Map.put("file", target && elem(target, 0))
      |> with_rules(changelog_rule(target, chosen))

    confidence = if target, do: chosen.confidence, else: 0
    evidence = if target, do: [Signal.file(file_path(elem(target, 0)))], else: []
    Signal.new("history.fix_changelog", value, confidence, @detector, evidence)
  end

  defp changelog_exists?(name, known) do
    if String.ends_with?(name, "/"),
      do: Enum.any?(known, &String.starts_with?(&1, name)),
      else: name in known
  end

  defp file_path(file), do: String.trim_trailing(file, "/")

  defp changelog_rule(nil, _chosen), do: []

  # Measured on fixes or source changes, but stated for what a reader of the changelog
  # sees: an internal refactor needs no entry.
  defp changelog_rule({file, _count}, chosen) when chosen.total >= 5 and chosen.rate >= 30 do
    action =
      if String.ends_with?(file, "/"),
        do: "Add a news fragment under `#{file}`",
        else: "Add an entry to `#{file}`"

    [
      %{
        "text" => "#{action} for every user-visible change.",
        "confidence" => chosen.confidence,
        "path" => file_path(file),
        "topic" => "changelog"
      }
    ]
  end

  defp changelog_rule(_, _), do: []

  defp hot_signals(changes, factor) do
    relevant = fn change ->
      Enum.filter(change.files, &(Paths.source_path?(&1) or Paths.test_path?(&1)))
    end

    all = changes |> Enum.flat_map(&relevant.(&1)) |> top(15, 3)

    fixes =
      changes |> Enum.filter(&fix_or_revert?/1) |> Enum.flat_map(&relevant.(&1)) |> top(10, 2)

    reverts =
      changes
      |> Enum.filter(&Regex.match?(@revert, &1.subject))
      |> Enum.flat_map(&relevant.(&1))
      |> top(10, 2)

    conf = confidence(90, length(changes), factor)

    [
      Signal.new("history.hot_files", %{"files" => all}, conf, @detector),
      Signal.new("history.fix_hotspots", %{"files" => fixes}, conf, @detector),
      Signal.new("history.revert_hotspots", %{"files" => reverts}, conf, @detector)
    ]
  end

  defp fix_or_revert?(change) do
    Regex.match?(@fix, change.subject) or Regex.match?(@revert, change.subject)
  end

  defp top(paths, count, minimum) do
    paths
    |> Enum.frequencies()
    |> Enum.filter(fn {_, n} -> n >= minimum end)
    |> Enum.sort_by(fn {path, n} -> {-n, path} end)
    |> Enum.take(count)
    |> Enum.map(fn {path, n} -> %{"path" => path, "changes" => n} end)
  end

  defp cochange(changes, factor, known) do
    known = MapSet.new(known)

    focused = Enum.filter(changes, &(length(&1.files) in 2..@max_files_per_change))

    pairs =
      for change <- focused,
          source <- change.files |> Enum.filter(&Paths.source_path?/1) |> Enum.uniq(),
          test <- change.files |> Enum.filter(&Paths.test_path?/1) |> Enum.uniq() do
        {source, test}
      end

    frequencies = Enum.frequencies(pairs)

    source_counts =
      focused
      |> Enum.flat_map(fn change ->
        change.files |> Enum.filter(&Paths.source_path?/1) |> Enum.uniq()
      end)
      |> Enum.frequencies()

    entries =
      frequencies
      |> Enum.filter(fn {{source, test}, support} ->
        support >= 3 and support * 100 >= Map.fetch!(source_counts, source) * 30 and
          (MapSet.size(known) == 0 or
             (MapSet.member?(known, source) and MapSet.member?(known, test)))
      end)
      |> Enum.sort_by(fn {{source, test}, support} -> {-support, source, test} end)
      |> Enum.take(20)
      |> Enum.map(fn {{source, test}, support} ->
        changes_with_source = Map.fetch!(source_counts, source)

        %{
          "source" => source,
          "test" => test,
          "together" => support,
          "source_changes" => changes_with_source,
          "percent" => Signal.percent(support, changes_with_source)
        }
      end)

    rules = cochange_rules(entries, factor)
    value = with_rules(%{"pairs" => entries}, rules)
    conf = rules |> Enum.map(& &1["confidence"]) |> Enum.max(fn -> 0 end)

    [
      Signal.new(
        "history.cochange",
        value,
        conf,
        @detector,
        Enum.map(entries |> Enum.take(5), &Signal.file(&1["source"]))
      )
    ]
  end

  defp cochange_rules(entries, factor) do
    entries
    |> Enum.filter(&(&1["together"] >= 4 and &1["percent"] >= 40))
    |> Enum.reject(&named_after?(&1["source"], &1["test"]))
    |> Enum.take(5)
    |> Enum.map(fn entry ->
      %{
        "text" => "Change `#{entry["source"]}` and `#{entry["test"]}` together",
        "confidence" => confidence(entry["percent"], entry["source_changes"], factor),
        "path" => entry["source"],
        "topic" => "cochange:" <> entry["source"]
      }
    end)
  end

  # `tests/test_core.py` for `src/core.py` is what the layout already says.
  defp named_after?(source, test) do
    stem = source |> Path.basename() |> Path.rootname()

    subject =
      test
      |> Path.basename()
      |> Path.rootname()
      |> String.replace(~r/\A(?:test_)|(?:_test|_spec|\.test|\.spec)\z/, "")

    subject == stem or String.starts_with?(subject, stem <> "_")
  end

  # Data for the stop hook and the locator (contract section 4), computed from the same
  # focused changes as `cochange/3`. `history.test_pairs`: a source file and a test file
  # changed together in at least 2 changes, `named_after` when the test is named after
  # the source. `history.source_cochange`: two source files changed together in at least
  # 4 changes and in at least 40% of the first file's changes, one row per direction.
  # Only files tracked at analysis time are kept.
  defp pair_signals(changes, factor, known) do
    known = MapSet.new(known)
    tracked? = fn path -> MapSet.size(known) == 0 or MapSet.member?(known, path) end
    focused = Enum.filter(changes, &(length(&1.files) in 2..@max_files_per_change))

    sources_of = fn change ->
      change.files |> Enum.filter(&(Paths.source_path?(&1) and tracked?.(&1))) |> Enum.uniq()
    end

    tests_of = fn change ->
      change.files
      |> Enum.filter(&(test_module?(&1) and tracked?.(&1)))
      |> Enum.uniq()
    end

    test_pairs =
      focused
      |> Enum.flat_map(fn change ->
        for source <- sources_of.(change), test <- tests_of.(change), do: {source, test}
      end)
      |> Enum.frequencies()
      |> Enum.filter(fn {_pair, support} -> support >= @test_pair_support end)
      |> Enum.sort_by(fn {{source, test}, support} -> {-support, source, test} end)
      |> Enum.take(@pair_candidates)
      |> Enum.map(fn {{source, test}, support} ->
        %{
          "source" => source,
          "test" => test,
          "support" => support,
          "kind" => if(named_after?(source, test), do: "named_after", else: "cochange")
        }
      end)

    source_sets = Enum.map(focused, sources_of)
    counts = source_sets |> List.flatten() |> Enum.frequencies()

    together =
      source_sets
      |> Enum.flat_map(fn sources ->
        sorted = Enum.sort(sources)
        for a <- sorted, b <- sorted, a < b, do: {a, b}
      end)
      |> Enum.frequencies()

    partners =
      together
      |> Enum.flat_map(fn {{a, b}, support} -> [{a, b, support}, {b, a, support}] end)
      |> Enum.filter(fn {path, _partner, support} ->
        support >= @partner_support and support * 100 >= counts[path] * @partner_percent
      end)
      |> Enum.sort_by(fn {path, partner, support} -> {-support, path, partner} end)
      |> Enum.take(@pair_candidates)
      |> Enum.map(fn {path, partner, support} ->
        %{
          "path" => path,
          "partner" => partner,
          "support" => support,
          "percent" => Signal.percent(support, counts[path])
        }
      end)

    conf = confidence(90, length(changes), factor)

    [
      Signal.new("history.test_pairs", %{"pairs" => test_pairs}, conf, @detector),
      Signal.new("history.source_cochange", %{"pairs" => partners}, conf, @detector)
    ]
  end

  # Data for the generated skills and subagents (design section 3.1): groups of source
  # files that change together, with the changes, fixes, paired tests and fragile files
  # behind each group. Only paths, SHAs and counts; no commit subject leaves this
  # function. Only focused changes count (2 to 25 files, not maintenance
  # such as formatting, linting, version-support drops or migrations), and file names
  # follow renames to their current names. Greedy and deterministic: the qualifying
  # source pairs (at least 4 shared changes and 40 % of either file's changes) are taken
  # by `{-support, a, b}`; a pair whose files are both unclustered starts a cluster (at
  # most 8), a pair with exactly one clustered file adds the other to that cluster (at
  # most 6 files), any other pair is skipped. A cluster's support is the number of
  # focused changes touching at least 2 of its files.
  defp native_clusters(changes, factor, known, head, renames) do
    known_set = MapSet.new(known)
    tracked? = fn path -> MapSet.size(known_set) == 0 or MapSet.member?(known_set, path) end

    renamed =
      Enum.map(changes, fn change ->
        %{change | files: change.files |> Enum.map(&Map.get(renames, &1, &1)) |> Enum.uniq()}
      end)

    focused = Enum.filter(renamed, &focused?/1)

    sources_of = fn change ->
      change.files |> Enum.filter(&(Paths.source_path?(&1) and tracked?.(&1))) |> Enum.uniq()
    end

    source_sets = Enum.map(focused, sources_of)
    counts = source_sets |> List.flatten() |> Enum.frequencies()

    qualifying =
      source_sets
      |> Enum.flat_map(fn sources ->
        sorted = Enum.sort(sources)
        for a <- sorted, b <- sorted, a < b, do: {a, b}
      end)
      |> Enum.frequencies()
      |> Enum.filter(fn {{a, b}, support} ->
        support >= @partner_support and
          (support * 100 >= counts[a] * @partner_percent or
             support * 100 >= counts[b] * @partner_percent)
      end)
      |> Enum.sort_by(fn {{a, b}, support} -> {-support, a, b} end)

    tests_of = fn change ->
      change.files |> Enum.filter(&(test_module?(&1) and tracked?.(&1))) |> Enum.uniq()
    end

    test_pairs =
      focused
      |> Enum.flat_map(fn change ->
        for source <- sources_of.(change), test <- tests_of.(change), do: {source, test}
      end)
      |> Enum.frequencies()
      |> Enum.filter(fn {_pair, support} -> support >= @test_pair_support end)

    clusters =
      qualifying
      |> greedy_clusters()
      |> Enum.map(&cluster_row(&1, focused, test_pairs, tests_of))
      |> Enum.sort_by(&{-&1["support"], hd(&1["files"])})

    value = %{
      "clusters" => clusters,
      "source_files" => Enum.count(known, &Paths.source_path?/1),
      "head" => head,
      "history_state" => factor.state
    }

    [
      Signal.new(
        "history.native_clusters",
        value,
        confidence(90, length(changes), factor),
        @detector,
        if(head, do: [Signal.commits([head])], else: [])
      )
    ]
  end

  defp focused?(change) do
    length(change.files) in 2..@max_files_per_change and
      not Regex.match?(@maintenance, change.subject) and
      not Regex.match?(@dependency_bump, change.subject) and
      not Regex.match?(@merge_noise, change.subject)
  end

  # A fix of code (not of documentation, CI or typing) or a revert, never a merge: a
  # merge subject names a branch, not what changed.
  defp code_fix_or_revert?(change),
    do: not change.merge? and (fix?(change) or Regex.match?(@revert, change.subject))

  defp greedy_clusters(pairs) do
    {clusters, _owner} =
      Enum.reduce(pairs, {%{}, %{}}, fn {{a, b}, _support}, {clusters, owner} ->
        case {owner[a], owner[b]} do
          {nil, nil} when map_size(clusters) < @max_clusters ->
            id = map_size(clusters)
            {Map.put(clusters, id, [a, b]), owner |> Map.put(a, id) |> Map.put(b, id)}

          {id, nil} when is_integer(id) ->
            grow(clusters, owner, id, b)

          {nil, id} when is_integer(id) ->
            grow(clusters, owner, id, a)

          _ ->
            {clusters, owner}
        end
      end)

    clusters |> Map.values() |> Enum.map(&Enum.sort/1)
  end

  defp grow(clusters, owner, id, file) do
    if length(clusters[id]) < @cluster_files,
      do: {Map.update!(clusters, id, &[file | &1]), Map.put(owner, file, id)},
      else: {clusters, owner}
  end

  defp cluster_row(files, focused, test_pairs, tests_of) do
    members = MapSet.new(files)
    count_in = fn change -> Enum.count(change.files, &MapSet.member?(members, &1)) end

    # `focused` is newest first, as `git log` printed it.
    joint = Enum.filter(focused, &(count_in.(&1) >= 2))
    touching = Enum.filter(focused, &(count_in.(&1) >= 1))
    fixes = touching |> Enum.filter(&code_fix_or_revert?/1) |> Enum.take(@cluster_shas)

    tests =
      test_pairs
      |> Enum.filter(fn {{source, _test}, _support} -> MapSet.member?(members, source) end)
      |> Enum.group_by(fn {{_source, test}, _} -> test end, fn {_, support} -> support end)
      |> Enum.map(fn {test, supports} -> %{"path" => test, "support" => Enum.max(supports)} end)
      |> Enum.sort_by(&{-&1["support"], &1["path"]})
      |> Enum.take(@cluster_tests)

    %{
      "files" => files,
      "support" => length(joint),
      "commits" => joint |> Enum.take(@cluster_shas) |> Enum.map(& &1.hash),
      "fix_commits" => Enum.map(fixes, & &1.hash),
      "fixes" => Enum.map(fixes, &fix_row(&1, members, tests_of)),
      "tests" => tests,
      "risk" => risk(files, touching, tests_of)
    }
  end

  # What a fix changed: the cluster files it touched, then its tests (at most 3 paths).
  defp fix_row(change, members, tests_of) do
    in_cluster = change.files |> Enum.filter(&MapSet.member?(members, &1)) |> Enum.sort()
    tests = change |> tests_of.() |> Enum.sort()

    %{
      "sha" => change.hash,
      "files" => Enum.take(in_cluster ++ tests, @cluster_fix_files)
    }
  end

  # A file is fragile when a change touching it was reverted, or when a fix touching it
  # was followed within 7 days by another fix touching it and one of the same tests (the
  # same behaviour fixed again), at least twice.
  defp risk(files, touching, tests_of) do
    files
    |> Enum.map(fn file ->
      with_file = Enum.filter(touching, &(file in &1.files))
      reverts = Enum.count(with_file, &Regex.match?(@revert, &1.subject))
      fixes = Enum.filter(with_file, &fix?/1)

      followups =
        fixes
        |> Enum.sort_by(& &1.time)
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.count(fn [earlier, later] ->
          later.time - earlier.time <= @followup_seconds and
            not MapSet.disjoint?(MapSet.new(tests_of.(earlier)), MapSet.new(tests_of.(later)))
        end)

      %{"path" => file, "reverts" => reverts, "followups" => followups, "fixes" => length(fixes)}
    end)
    |> Enum.filter(&(&1["reverts"] >= 1 or &1["followups"] >= 2))
    |> Enum.sort_by(&{-(2 * &1["reverts"] + &1["followups"]), &1["path"]})
    |> Enum.take(@cluster_risk)
  end

  defp test_module?(path) do
    Paths.test_path?(path) and Paths.code_path?(path) and
      Path.basename(path) not in @not_a_test_module
  end

  defp with_rules(value, rules), do: Map.put(value, "rules", rules)
end
