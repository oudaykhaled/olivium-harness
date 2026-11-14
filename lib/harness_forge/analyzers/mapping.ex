defmodule HarnessForge.Analyzers.Mapping do
  @moduledoc """
  Maps a signals document to the RepoProfile the engine consumes.

  Commands, layout and conventions enter the profile only from the `auto` bucket.
  Rule candidates keep their bucket so generation can select `auto` and a review
  flow can offer the rest.

  Test pairs and co-change partners come from history (`auto` only) and feed hook data
  files that plain `sh` reads, so each path must match `^[A-Za-z0-9_./-]{1,200}$`, not
  start with `/` or `-` and contain no `..` or `//`. A row that fails is dropped, never
  repaired, and counted in `paths_dropped_charset`. Lists are capped and sorted so the
  same repository state gives the same bytes.
  """

  alias HarnessForge.Analyzers.{Paths, Practices}
  alias HarnessForge.Contracts.{Error, Signals}
  alias HarnessForge.Generation.Profile

  @self_describing ~w(test tests spec docs doc examples example bench benchmarks changelog.d .github/workflows)
  @plain_path ~r/\A[A-Za-z0-9_.\/-]{1,200}\z/
  @pair_cap 200
  @sha ~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/
  @tests_per_source 5
  @partners_per_path 3
  @tool_roles ~w(test lint typecheck format interpreter)

  @spec profile(map()) :: {:ok, map()} | {:error, Error.t()}
  def profile(%{"repository" => %{"identity" => identity}, "signals" => signals})
      when is_binary(identity) and is_list(signals) do
    by_key = Map.new(signals, &{&1["key"], &1})
    commands = commands(by_key)
    {test_pairs, test_drops} = test_pairs(by_key)
    {cochange, cochange_drops} = cochange(by_key)
    {native, native_drops} = native_evidence(by_key)

    identity
    |> String.slice(0, 128)
    |> Profile.empty()
    |> Map.merge(%{
      "languages" => languages(by_key),
      "frameworks" => list(by_key, "stack.frameworks", "frameworks"),
      "package_managers" => list(by_key, "stack.package_managers", "package_managers"),
      "commands" => commands,
      "layout" => layout(by_key),
      "conventions" => conventions(by_key),
      "ci" => list(by_key, "ci.systems", "systems"),
      "existing_harness" => %{"files" => list(by_key, "instructions.existing", "files")},
      "rule_candidates" => rule_candidates(signals),
      "tools" => tools(by_key, commands),
      "test_pairs" => test_pairs,
      "cochange" => cochange,
      "paths_dropped_charset" => test_drops + cochange_drops + native_drops,
      "practices" => practices(by_key)
    })
    |> then(&if(native, do: Map.put(&1, "native_evidence", native), else: &1))
    |> Profile.validate()
  end

  def profile(_),
    do:
      {:error, %Error{code: "invalid_signals", message: "Expected a repository signals document"}}

  @doc "True for a path the hooks' plain-text data files may carry (contract section 0)."
  @spec plain_path?(term()) :: boolean()
  def plain_path?(path) when is_binary(path) do
    Regex.match?(@plain_path, path) and not String.starts_with?(path, ["/", "-"]) and
      not String.contains?(path, ["..", "//"])
  end

  def plain_path?(_), do: false

  # A probe entry is kept only for a role whose command made it into the profile, with
  # the same text, so the environment check describes the command the package uses.
  defp tools(by_key, commands) do
    by_key
    |> list("commands.tools", "tools")
    |> Enum.filter(fn entry ->
      entry["role"] in @tool_roles and
        (entry["role"] == "interpreter" or
           (is_binary(entry["command"]) and commands[entry["role"]] == entry["command"]))
    end)
    |> Enum.uniq_by(& &1["role"])
    |> Enum.sort_by(fn entry -> Enum.find_index(@tool_roles, &(&1 == entry["role"])) end)
    |> Enum.take(5)
  end

  # Counts only (no text), from the bounded practices read. Absent or below the auto
  # bucket, every count is zero, so no practice rule can fire on a guess.
  defp practices(by_key) do
    found = auto(by_key, "practices.counts") || %{}

    Map.new(Practices.count_keys(), fn
      "warnings_as_errors" = key -> {key, found[key] == true}
      key -> {key, count(found[key])}
    end)
  end

  defp count(value) when is_integer(value) and value >= 0, do: min(value, 1_000_000)
  defp count(_), do: 0

  defp test_pairs(by_key) do
    rows = list(by_key, "history.test_pairs", "pairs")

    {plain, dropped} =
      Enum.split_with(rows, &(plain_path?(&1["source"]) and plain_path?(&1["test"])))

    selected =
      plain
      |> Enum.filter(&(not Paths.test_path?(&1["source"]) and Paths.test_path?(&1["test"])))
      |> Enum.group_by(& &1["source"])
      |> Enum.flat_map(fn {_source, group} ->
        group |> Enum.sort_by(&{-&1["support"], &1["test"]}) |> Enum.take(@tests_per_source)
      end)
      |> Enum.sort_by(&{-&1["support"], &1["source"], &1["test"]})
      |> Enum.take(@pair_cap)
      |> Enum.sort_by(&{&1["source"], &1["test"]})
      |> Enum.map(&Map.take(&1, ~w(source test support kind)))

    {selected, length(dropped)}
  end

  defp cochange(by_key) do
    rows = list(by_key, "history.source_cochange", "pairs")

    {plain, dropped} =
      Enum.split_with(rows, &(plain_path?(&1["path"]) and plain_path?(&1["partner"])))

    selected =
      plain
      |> Enum.reject(&(&1["path"] == &1["partner"]))
      |> Enum.group_by(& &1["path"])
      |> Enum.flat_map(fn {_path, group} ->
        group |> Enum.sort_by(&{-&1["support"], &1["partner"]}) |> Enum.take(@partners_per_path)
      end)
      |> Enum.sort_by(&{-&1["support"], &1["path"], &1["partner"]})
      |> Enum.take(@pair_cap)
      |> Enum.sort_by(&{&1["path"], &1["partner"]})
      |> Enum.map(&Map.take(&1, ~w(path partner support percent)))

    {selected, length(dropped)}
  end

  # The history behind generated skills and subagents, only from the `auto` bucket (a
  # shallow history never reaches it). A cluster file, test or risk row whose path is
  # not plain is dropped and counted; a cluster left with fewer than 2 files goes too.
  defp native_evidence(by_key) do
    case auto(by_key, "history.native_clusters") do
      %{"clusters" => clusters, "head" => head} = value
      when is_list(clusters) and is_binary(head) ->
        if Regex.match?(@sha, head) do
          {kept, drops} =
            Enum.map_reduce(clusters, 0, fn cluster, drops ->
              {files, a} = plain_rows(cluster["files"] || [], & &1)
              {tests, b} = plain_rows(cluster["tests"] || [], & &1["path"])
              {risk, c} = plain_rows(cluster["risk"] || [], & &1["path"])
              {fixes, d} = fix_rows(cluster["fixes"])

              row = %{
                "files" => files |> Enum.uniq() |> Enum.sort() |> Enum.take(6),
                "support" => count(cluster["support"]),
                "commits" => shas(cluster["commits"]),
                "fix_commits" => shas(cluster["fix_commits"]),
                "tests" => tests |> Enum.map(&Map.take(&1, ~w(path support))) |> Enum.take(4),
                "risk" =>
                  risk
                  |> Enum.map(&Map.take(&1, ~w(path reverts followups fixes)))
                  |> Enum.take(4),
                "fixes" => fixes
              }

              {row, drops + a + b + c + d}
            end)

          evidence = %{
            "head" => head,
            "history_state" =>
              if(value["history_state"] == "truncated", do: "truncated", else: "complete"),
            "source_files" => count(value["source_files"]),
            "clusters" => kept |> Enum.filter(&(length(&1["files"]) >= 2)) |> Enum.take(8)
          }

          {evidence, drops}
        else
          {nil, 0}
        end

      _ ->
        {nil, 0}
    end
  end

  # What each past fix changed: a SHA and at most 3 plain paths; a non-plain path is
  # dropped and counted, a row with a bad SHA goes.
  defp fix_rows(rows) when is_list(rows) do
    rows
    |> Enum.filter(&(is_map(&1) and is_binary(&1["sha"]) and Regex.match?(@sha, &1["sha"])))
    |> Enum.take(5)
    |> Enum.map_reduce(0, fn row, drops ->
      {files, dropped} = plain_rows(row["files"] || [], & &1)
      {%{"sha" => row["sha"], "files" => Enum.take(files, 3)}, drops + dropped}
    end)
  end

  defp fix_rows(_), do: {[], 0}

  defp plain_rows(rows, path_of) when is_list(rows),
    do:
      {Enum.filter(rows, &plain_path?(path_of.(&1))),
       Enum.count(rows, &(not plain_path?(path_of.(&1))))}

  defp shas(list) when is_list(list),
    do: list |> Enum.filter(&(is_binary(&1) and Regex.match?(@sha, &1))) |> Enum.take(5)

  defp shas(_), do: []

  defp auto(by_key, key) do
    case by_key[key] do
      %{"bucket" => "auto", "value" => value} -> value
      _ -> nil
    end
  end

  defp list(by_key, key, field), do: (auto(by_key, key) || %{})[field] || []

  # The eight largest languages, plus "jupyter" whenever a notebook is tracked: the lean
  # context profile keeps the notebook tool for such a repository (contract section 5),
  # so a notebook must not drop out of the list just because it is the rarest language.
  defp languages(by_key) do
    all = by_key |> list("stack.languages", "languages") |> Enum.map(& &1["name"])
    top = Enum.take(all, 8)
    if "jupyter" in all and "jupyter" not in top, do: top ++ ["jupyter"], else: top
  end

  defp commands(by_key) do
    Map.new(Profile.command_keys(), fn key ->
      value = auto(by_key, "commands." <> key)
      {key, value && value["command"]}
    end)
  end

  # A directory whose name already says what it holds tells an agent nothing `ls` does not.
  defp layout(by_key) do
    by_key
    |> list("layout.paths", "entries")
    |> Enum.reject(&(&1["path"] in @self_describing))
    |> Enum.map(&Map.take(&1, ~w(path purpose)))
  end

  defp conventions(by_key) do
    case auto(by_key, "conventions.tests") do
      %{"directory" => directory, "pattern" => pattern} when is_binary(pattern) ->
        ["Tests live under #{directory}/ as #{pattern} files"]

      _ ->
        []
    end
  end

  # Every detector lists its rules under `value.rules`. A topic groups rules that say
  # the same thing in different words, keeping the one with most confidence, which
  # is the human instruction when its confidence matches a measured rate.
  defp rule_candidates(signals) do
    corroborated =
      signals
      |> Enum.find_value([], fn
        %{"key" => "instructions.rule_candidates", "value" => %{"corroborates" => topics}} ->
          topics

        _ ->
          nil
      end)

    signals
    |> Enum.flat_map(fn signal ->
      for rule <- rules(signal),
          text = rule["text"],
          is_binary(text) and text != "" do
        confidence = rule["confidence"]

        %{
          "text" => text,
          "confidence" => confidence,
          "bucket" => Signals.bucket(confidence),
          "topic" => rule["topic"],
          "citations" => [citation(signal, rule)]
        }
      end
    end)
    |> merge_topics(corroborated)
    |> Enum.sort_by(fn c -> {-c["confidence"], c["text"]} end)
    |> Enum.uniq_by(& &1["text"])
    |> Enum.take(200)
  end

  defp rules(%{"value" => %{"rules" => rules}}) when is_list(rules), do: rules
  defp rules(_), do: []

  defp citation(signal, rule) do
    %{
      "detector" => signal["detector"],
      "signal" => signal["key"],
      "path" => rule["path"],
      "line" => rule["line"]
    }
  end

  # Several sources saying the same thing about the changelog keep the generator's
  # measured sentence: it says the same in fewer bytes and copies no repository prose.
  defp wording(group, best) do
    measured =
      Enum.find(group, fn candidate ->
        Enum.any?(candidate["citations"], &(&1["signal"] == "history.fix_changelog"))
      end)

    if measured, do: measured["text"], else: best["text"]
  end

  defp merge_topics(candidates, corroborated) do
    {with_topic, without} = Enum.split_with(candidates, &is_binary(&1["topic"]))

    merged =
      with_topic
      |> Enum.group_by(& &1["topic"])
      |> Enum.map(fn {topic, group} -> merge_group(group, topic in corroborated) end)

    Enum.map(merged ++ without, &Map.delete(&1, "topic"))
  end

  defp merge_group([single], false), do: single

  defp merge_group(group, _corroborated) do
    [best | rest] = Enum.sort_by(group, fn c -> {-c["confidence"], c["text"]} end)
    confidence = min(best["confidence"] + 10, 100)

    best
    |> Map.put("text", wording(group, best))
    |> Map.put("confidence", confidence)
    |> Map.put("bucket", Signals.bucket(confidence))
    |> Map.put(
      "citations",
      (best["citations"] ++ Enum.flat_map(rest, & &1["citations"]))
      |> Enum.uniq()
      |> Enum.take(16)
    )
  end
end
