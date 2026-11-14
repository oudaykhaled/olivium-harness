defmodule HarnessForge.Generation.Native do
  @moduledoc """
  Claude Code skills and subagents derived from repository history (design: sa
  workflow 2026-11-13, sections 2 and 3.2).

  Three fixed templates, all filled from the RepoProfile and never from repository
  prose:

    * `area`: a skill `olivium-area-<slug>` per cluster of source files that history
      shows changing together (`profile.native_evidence`), with the tests history pairs
      with them, the SHAs of past changes and fixes, and the files reverted or fixed
      again soon. At most 3.
    * `locator`: a read-only subagent (`Read, Grep, Glob`) that answers with file paths
      and line ranges only, primed with the layout, the clusters and the test pairs.
    * `test_runner`: a subagent (`Bash, Read`) that runs only the detected test
      commands and replies with failures only. The guard refuses any other Bash call it
      makes (`spec.native.test_runner_commands`).

  The only values filled in are paths, commands, commit SHAs and counts, plus, for an
  item a learned bundle proposed (`"origin" => "learned"`), checked terms, symbols and
  pitfall text (`HarnessForge.Learning.Bundle.safe_text?/1`). Every rendered string must
  be printable ASCII with no dynamic shell (`!` followed by a backtick) and no file
  import marker; an item that fails is dropped as `text_unsafe`, never repaired.

  Every constant and sentence comes from the blueprint's `native` section. Pure: the
  same profile, blueprint and options give the same bytes. Nothing is executed.
  """

  alias HarnessForge.Generation.{Blueprint, Guidance, Spec}
  alias HarnessForge.Analyzers.Mapping
  alias HarnessForge.Learning.Bundle

  @templates ~w(area locator test_runner)
  @selects ~w(all skills agents none)
  @origins ~w(history learned)
  @sha ~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/
  @slug ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/
  @name ~r/\Aolivium-[a-z0-9]+(?:-[a-z0-9]+)*\z/
  @term ~r/\A[a-z0-9][a-z0-9 _.-]{1,39}\z/
  @symbol ~r/\A[A-Za-z_][A-Za-z0-9_.]{0,79}\z/
  @learned_id ~r/\A[a-z][0-9]{2}\z/
  @signal ~r/\A[a-z][a-z0-9_.-]{0,63}\z/
  # The RepoProfile command charset.
  @command ~r/\A[A-Za-z0-9_.\/][A-Za-z0-9_.\/:=@+,-]*(?: [A-Za-z0-9_.\/:=@+,-]+)*\z/
  @package_script ~r/\A(?:npm|pnpm|yarn) (?:test|run [A-Za-z0-9:._-]+)\z/
  @package_file_form ~r/\A(?:npm (?:test|run [A-Za-z0-9:._-]+) --|(?:pnpm|yarn) (?:test|run [A-Za-z0-9:._-]+))\z/
  @locator_tools ["Read", "Grep", "Glob"]
  @runner_tools ["Bash", "Read"]
  @agent_tools ["Read", "Grep", "Glob", "Bash"]
  @locator_name "olivium-locator"
  @runner_name "olivium-test-runner"
  @area_signal "history.native_clusters"
  # Directory names that say nothing about an area; a slug skips them.
  @generic_dirs ~w(src lib source sources app apps pkg internal main java python js ts)
  # File stems too common to tie a repository rule to one file.
  @generic_stems ~w(index utils util helpers common types config settings constants models errors init __init__ main core base client server)

  @doc "The template names, in rendering order."
  @spec templates() :: [String.t()]
  def templates, do: @templates

  @doc "The accepted `select` values."
  @spec selects() :: [String.t()]
  def selects, do: @selects

  @doc "The tools an agent may list (closed enum)."
  @spec agent_tools() :: [String.t()]
  def agent_tools, do: @agent_tools

  @doc "The name of the generated test-runner subagent, the only one that may list Bash."
  @spec runner_name() :: String.t()
  def runner_name, do: @runner_name

  @doc "The blueprint's `native.limits`."
  @spec limits(map()) :: map()
  def limits(blueprint), do: config(blueprint)["limits"]

  @doc """
  Bytes the skill and agent listings add to every request: per skill
  `name + description + 4`, per agent `name + description + " (Tools: a, b)" + 4`, plus
  the agent header (185 B, measured) once any agent exists.
  """
  @spec listing_bytes([map()], [map()]) :: non_neg_integer()
  def listing_bytes(skills, agents) do
    header = if agents == [], do: 0, else: config(nil)["costs"]["agent_header_bytes"]

    Enum.sum(Enum.map(skills, &(byte_size(&1["name"]) + byte_size(&1["description"]) + 4))) +
      Enum.sum(
        Enum.map(agents, fn agent ->
          byte_size(agent["name"]) + byte_size(agent["description"]) +
            byte_size(" (Tools: " <> Enum.join(agent["tools"] || [], ", ") <> ")") + 4
        end)
      ) + header
  end

  @doc """
  The measured cost of the generated items. `kinds` is `%{"skills" => bool, "agents" =>
  bool}`: the tools the items make the profile keep (`Skill`, `Task`). For `standard`,
  which keeps every tool anyway, only the listing is counted. The fixed costs were
  measured with Claude Code's built-in subagents listed; a lean profile that keeps
  `Task` denies them by name (`Spec`, `context.disable_builtin_agents`), so their
  measured listing is taken off (`builtin_agents_denied_tokens`). Returns
  `%{"est_tokens_per_request", "est_tokens_per_request_low", "fixed_tokens",
  "listing_tokens", "builtin_agents_denied_tokens", "config", "basis"}`; `config` is
  `skills`, `agents`, `skills_agents` or `none`.
  """
  @spec cost(map(), non_neg_integer(), String.t(), map()) :: map()
  def cost(kinds, listing_bytes, profile_name, blueprint) do
    costs = config(blueprint)["costs"]
    config = config_name(kinds)
    listing = ceil_div(listing_bytes * 1000, costs["listing_bytes_per_1000_tokens"])
    listing_low = ceil_div(listing_bytes * 1000, costs["listing_bytes_per_1000_tokens_low"])
    lean? = config != "none" and profile_name != "standard"
    {builtin, builtin_low} = builtin_agents_tokens(kinds, lean?, costs)

    {fixed, fixed_low} =
      if lean?,
        do:
          {costs["fixed_tokens"][config] - builtin,
           costs["fixed_tokens_low"][config] - builtin_low},
        else: {0, 0}

    %{
      "est_tokens_per_request" => fixed + listing,
      "est_tokens_per_request_low" => fixed_low + listing_low,
      "fixed_tokens" => fixed,
      "listing_tokens" => listing,
      "builtin_agents_denied_tokens" => builtin,
      "config" => config,
      "basis" => config(blueprint)["basis"]
    }
  end

  # The built-in subagent listing (measured bytes) in tokens, at the listing rate and
  # the low rate, when a lean profile keeps Task and so denies the built-in subagents.
  defp builtin_agents_tokens(%{"agents" => true}, true, costs) do
    bytes = costs["builtin_agents_bytes"]

    {ceil_div(bytes * 1000, costs["listing_bytes_per_1000_tokens"]),
     ceil_div(bytes * 1000, costs["listing_bytes_per_1000_tokens_low"])}
  end

  defp builtin_agents_tokens(_kinds, _lean?, _costs), do: {0, 0}

  @doc """
  Tokens a lean profile saves against no settings once it keeps the tools `kinds`
  names: the blueprint's measured value for that configuration (built-in subagents
  listed) less the listing, plus the built-in subagent listing the deny rules remove.
  """
  @spec saved_vs_none(map(), non_neg_integer(), map()) :: non_neg_integer()
  def saved_vs_none(kinds, listing_bytes, blueprint) do
    costs = config(blueprint)["costs"]
    listing = ceil_div(listing_bytes * 1000, costs["listing_bytes_per_1000_tokens"])
    config = config_name(kinds)
    {builtin, _low} = builtin_agents_tokens(kinds, config != "none", costs)
    max(costs["saved_vs_none"][config] + builtin - listing, 0)
  end

  @doc "The built-in subagents a lean profile that keeps Task denies (Claude Code 2.1.311)."
  @spec builtin_agents() :: [String.t()]
  def builtin_agents, do: config(nil)["builtin_agents"]

  @doc """
  What one turn of a generated subagent costs on its own requests (its system prompt,
  tools and the task; measured 8,540 to 11,271 B on 2.1.311), in tokens at the listing
  rate: `%{"min", "max"}`. Not part of the per-request cost; paid only when the main
  session calls the subagent, once per turn it takes.
  """
  @spec subagent_turn_tokens(map() | nil) :: map()
  def subagent_turn_tokens(blueprint) do
    costs = config(blueprint)["costs"]
    rate = costs["listing_bytes_per_1000_tokens"]

    Map.new(costs["subagent_turn_bytes"], fn {key, bytes} ->
      {key, ceil_div(bytes * 1000, rate)}
    end)
  end

  defp config_name(%{"skills" => true, "agents" => true}), do: "skills_agents"
  defp config_name(%{"skills" => true}), do: "skills"
  defp config_name(%{"agents" => true}), do: "agents"
  defp config_name(_), do: "none"

  defp ceil_div(a, b), do: div(a + b - 1, b)

  @doc """
  Checks a candidate (from history or a learned bundle) against the contract of design
  section 3.2 and fills the optional keys. Returns `{:error, "schema_invalid"}` for a
  wrong shape, a non-plain path, a bad SHA or too many entries, and
  `{:error, "text_unsafe"}` for a term, symbol or note that could be read as anything
  but data.
  """
  @spec validate_candidate(term()) :: {:ok, map()} | {:error, String.t()}
  def validate_candidate(%{"template" => template, "origin" => origin} = candidate)
      when template in @templates and origin in @origins do
    with {:ok, evidence} <- evidence(candidate["evidence"]) do
      candidate(template, Map.put(candidate, "evidence", evidence))
    end
  end

  def validate_candidate(_), do: {:error, "schema_invalid"}

  defp candidate("area", c) do
    files = c["files"]
    tests = Map.get(c, "tests", [])
    risk = Map.get(c, "risk", [])
    terms = Map.get(c, "terms", [])
    symbols = Map.get(c, "symbols", [])
    notes = Map.get(c, "notes", [])

    cond do
      not (is_binary(c["slug"]) and byte_size(c["slug"]) <= 24 and Regex.match?(@slug, c["slug"])) ->
        {:error, "schema_invalid"}

      not (is_list(files) and length(files) in 2..6 and Enum.all?(files, &Mapping.plain_path?/1) and
               Enum.uniq(files) == files) ->
        {:error, "schema_invalid"}

      not (is_list(tests) and length(tests) <= 4 and Enum.all?(tests, &test_row?/1)) ->
        {:error, "schema_invalid"}

      not (is_list(risk) and length(risk) <= 4 and Enum.all?(risk, &risk_row?/1)) ->
        {:error, "schema_invalid"}

      not (count?(Map.get(c, "commit_count", 0)) and shas?(Map.get(c, "commits", [])) and
               shas?(Map.get(c, "fix_commits", []))) ->
        {:error, "schema_invalid"}

      not (is_list(terms) and is_list(symbols) and is_list(notes) and length(terms) <= 6 and
             length(symbols) <= 6 and length(notes) <= 2) ->
        {:error, "schema_invalid"}

      not Enum.all?(symbols, &symbol_row?/1) ->
        {:error, "schema_invalid"}

      not Enum.all?(terms, &(is_binary(&1) and Regex.match?(@term, &1))) ->
        {:error, "text_unsafe"}

      not Enum.all?(notes, &(Bundle.safe_text?(&1) and safe_text?(&1))) ->
        {:error, "text_unsafe"}

      c["origin"] == "history" and (terms != [] or symbols != [] or notes != []) ->
        {:error, "schema_invalid"}

      true ->
        {:ok,
         %{
           "template" => "area",
           "origin" => c["origin"],
           "slug" => c["slug"],
           "files" => files,
           "tests" => Enum.map(tests, &Map.take(&1, ~w(path support))),
           "commit_count" => Map.get(c, "commit_count", 0),
           "commits" => Map.get(c, "commits", []),
           "fix_commits" => Map.get(c, "fix_commits", []),
           "risk" => Enum.map(risk, &Map.take(&1, ~w(path reverts followups))),
           "terms" => terms,
           "symbols" => Enum.map(symbols, &Map.take(&1, ~w(name path start end))),
           "notes" => notes,
           "evidence" => c["evidence"]
         }}
    end
  end

  defp candidate("locator", c) do
    scope = c["scope"]

    if is_list(scope) and length(scope) in 1..8 and Enum.all?(scope, &Mapping.plain_path?/1) and
         Enum.uniq(scope) == scope,
       do:
         {:ok,
          %{
            "template" => "locator",
            "origin" => c["origin"],
            "scope" => scope,
            "evidence" => c["evidence"]
          }},
       else: {:error, "schema_invalid"}
  end

  defp candidate("test_runner", c) do
    commands = c["commands"]

    valid? = fn
      %{"role" => role, "argv" => argv, "id" => id}
      when role in ["test", "test_file"] and is_binary(argv) and is_binary(id) ->
        byte_size(argv) <= 512 and Regex.match?(@command, strip_file(argv)) and
          byte_size(id) <= 64 and Regex.match?(~r/\A[a-z0-9][a-z0-9_-]*\z/, id)

      _ ->
        false
    end

    if is_list(commands) and length(commands) in 1..4 and Enum.all?(commands, valid?),
      do:
        {:ok,
         %{
           "template" => "test_runner",
           "origin" => c["origin"],
           "commands" => Enum.map(commands, &Map.take(&1, ~w(role argv id))),
           "evidence" => c["evidence"]
         }},
      else: {:error, "schema_invalid"}
  end

  defp evidence(nil), do: {:ok, %{"signals" => [], "commits" => [], "learned_id" => nil}}

  defp evidence(%{} = e) do
    signals = Map.get(e, "signals", [])
    commits = Map.get(e, "commits", [])
    learned_id = Map.get(e, "learned_id")

    if is_list(signals) and length(signals) <= 8 and
         Enum.all?(signals, &(is_binary(&1) and Regex.match?(@signal, &1))) and
         is_list(commits) and length(commits) <= 5 and
         Enum.all?(commits, &(is_binary(&1) and Regex.match?(@sha, &1))) and
         (is_nil(learned_id) or (is_binary(learned_id) and Regex.match?(@learned_id, learned_id))),
       do: {:ok, %{"signals" => signals, "commits" => commits, "learned_id" => learned_id}},
       else: {:error, "schema_invalid"}
  end

  defp evidence(_), do: {:error, "schema_invalid"}

  defp test_row?(%{"path" => path, "support" => support}),
    do: Mapping.plain_path?(path) and count?(support)

  defp test_row?(_), do: false

  defp risk_row?(%{"path" => path, "reverts" => reverts, "followups" => followups}),
    do: Mapping.plain_path?(path) and count?(reverts) and count?(followups)

  defp risk_row?(_), do: false

  defp symbol_row?(%{"name" => name, "path" => path, "start" => first, "end" => last}),
    do:
      is_binary(name) and Regex.match?(@symbol, name) and Mapping.plain_path?(path) and
        is_integer(first) and is_integer(last) and first >= 1 and last >= first and
        last <= 10_000_000

  defp symbol_row?(_), do: false

  defp count?(value), do: is_integer(value) and value >= 0 and value <= 1_000_000

  defp shas?(list),
    do:
      is_list(list) and length(list) <= 5 and
        Enum.all?(list, &(is_binary(&1) and Regex.match?(@sha, &1)))

  # A learned argv names where the file goes with `{file}`; the guard and the body use
  # the prefix.
  defp strip_file(argv),
    do: argv |> String.replace("{file}", "") |> String.split(" ", trim: true) |> Enum.join(" ")

  @doc """
  The skills and subagents for a profile. `profile` is the command-filtered profile
  (`Spec` removes denied commands first). `opts`: `"select"` (`all`, `skills`, `agents`
  or `none`, already checked by `Spec`) and `"candidates"` (learned candidates in the
  shape of `validate_candidate/1`, default `[]`).

  Returns `%{"skills", "agents", "test_runner_commands", "items", "dropped",
  "listing_bytes", "diagnostics"}`. Skills and agents are spec entries
  (`name`, `description`, `instructions`, and `tools` for agents); `items` is the
  provenance of each; `dropped` names every item left out and why (`gate_failed`,
  `history_unavailable`, `name_taken`, `over_limit`, `not_selected`, `text_unsafe`,
  `schema_invalid`, `runner_command_unsuitable`: no command runs one test file, since
  the test command is neither the test tool nor a package script that is one plain
  call of it).
  """
  @spec build(map(), map(), map()) :: map()
  def build(profile, blueprint, opts) do
    cfg = config(blueprint)
    select = Map.get(opts, "select", "all")
    {learned, invalid} = learned_candidates(Map.get(opts, "candidates", []))
    evidence = profile["native_evidence"]
    taken = MapSet.new(get_in(profile, ["existing_harness", "files"]) || [])
    one_test = one_test_command(profile, blueprint)

    {areas, area_drops} = areas(evidence, learned, cfg, taken, one_test, doc_rules(profile))
    {locator, locator_drops} = locator(evidence, learned, cfg, taken, profile)

    {runner, runner_commands, runner_drops} =
      runner(learned, cfg, taken, profile, blueprint, one_test)

    agents = Enum.reject([locator, runner], &is_nil/1)

    {skills, agents, select_drops} = select(select, areas, agents)
    {skills, agents, listing_drops} = listing_cap(skills, agents, cfg["limits"]["listing_bytes"])

    runner_commands =
      if Enum.any?(agents, &(&1.entry["name"] == @runner_name)), do: runner_commands, else: []

    # A learned and a history item with the same name and reason make one row.
    dropped =
      (invalid ++ area_drops ++ locator_drops ++ runner_drops ++ select_drops ++ listing_drops)
      |> Enum.uniq()
      |> Enum.sort_by(&{&1["name"] || "", &1["template"] || "", &1["reason"]})

    skill_entries = Enum.map(skills, & &1.entry)
    agent_entries = Enum.map(agents, & &1.entry)
    listing = listing_bytes(skill_entries, agent_entries)

    %{
      "skills" => skill_entries,
      "agents" => agent_entries,
      "test_runner_commands" => runner_commands,
      "items" => Enum.map(skills ++ agents, & &1.item),
      "dropped" => dropped,
      "listing_bytes" => listing,
      "diagnostics" => diagnostics(select, skills ++ agents, dropped, evidence)
    }
  end

  defp config(nil), do: Blueprint.all()["base"]["native"]
  defp config(blueprint), do: blueprint["native"] || Blueprint.all()["base"]["native"]

  defp learned_candidates(candidates) when is_list(candidates) do
    candidates
    |> Enum.map(fn candidate ->
      case validate_candidate(candidate) do
        {:ok, valid} ->
          {:ok, valid}

        {:error, reason} ->
          template = if is_map(candidate), do: candidate["template"], else: nil

          {:error,
           %{
             "template" => if(template in @templates, do: template, else: "unknown"),
             "reason" => reason
           }}
      end
    end)
    |> Enum.split_with(&(elem(&1, 0) == :ok))
    |> then(fn {ok, errors} -> {Enum.map(ok, &elem(&1, 1)), Enum.map(errors, &elem(&1, 1))} end)
  end

  defp learned_candidates(_), do: {[], [%{"template" => "unknown", "reason" => "schema_invalid"}]}

  # ---- area skills -----------------------------------------------------------------

  defp areas(evidence, learned, cfg, taken, one_test, rules) do
    gates = cfg["gates"]
    limits = cfg["limits"]
    head = evidence && evidence["head"]

    {history, gate_drops} =
      ((evidence && evidence["clusters"]) || [])
      |> Enum.sort_by(&{-&1["support"], hd(&1["files"])})
      |> Enum.split_with(
        &(&1["support"] >= gates["area_min_support"] and length(&1["files"]) >= 2)
      )

    history =
      Enum.map(history, fn cluster ->
        %{
          "template" => "area",
          "origin" => "history",
          "slug" => slug(cluster["files"]),
          "files" => Enum.take(cluster["files"], limits["cluster_files"]),
          "tests" => Enum.take(cluster["tests"], limits["area_tests"]),
          "commit_count" => cluster["support"],
          "commits" => Enum.take(cluster["commits"], limits["shas"]),
          "fix_commits" => Enum.take(cluster["fix_commits"], limits["shas"]),
          "fixes" => Enum.take(cluster["fixes"] || [], limits["shas"]),
          "risk" => Enum.take(cluster["risk"], limits["risk_lines"]),
          "terms" => [],
          "symbols" => [],
          "notes" => [],
          "evidence" => %{
            "signals" => [@area_signal],
            "commits" => Enum.take(cluster["commits"], limits["shas"]),
            "learned_id" => nil
          }
        }
      end)

    learned_areas =
      learned
      |> Enum.filter(&(&1["template"] == "area"))
      |> Enum.sort_by(&{-length(&1["evidence"]["commits"]), &1["slug"], &1["files"]})

    {merged, history_left} = merge_learned(learned_areas, history, limits)

    ranked =
      Enum.sort_by(merged, &{-length(&1["evidence"]["commits"]), &1["slug"]}) ++ history_left

    gate_dropped =
      Enum.map(
        gate_drops,
        &%{
          "name" => name("area-" <> slug(&1["files"])),
          "template" => "area",
          "reason" => "gate_failed"
        }
      )

    no_history =
      cond do
        learned_areas != [] or history != [] or gate_drops != [] -> []
        is_nil(evidence) -> [%{"template" => "area", "reason" => "history_unavailable"}]
        true -> [%{"template" => "area", "reason" => "gate_failed"}]
      end

    {named, _used} =
      Enum.map_reduce(ranked, MapSet.new(), fn candidate, used ->
        base = "area-" <> candidate["slug"]
        unique = unique_name(base, used)
        {Map.put(candidate, "name", name(unique)), MapSet.put(used, unique)}
      end)

    {kept, drops} =
      Enum.reduce(named, {[], []}, fn candidate, {kept, drops} ->
        path = skill_path(candidate["name"])

        cond do
          MapSet.member?(taken, path) ->
            {kept, [drop(candidate, "name_taken") | drops]}

          length(kept) >= limits["skills"] ->
            {kept, [drop(candidate, "over_limit") | drops]}

          true ->
            case render_area(candidate, cfg, head, one_test, rules) do
              {:ok, rendered} -> {kept ++ [rendered], drops}
              {:error, reason} -> {kept, [drop(candidate, reason) | drops]}
            end
        end
      end)

    {kept, gate_dropped ++ no_history ++ Enum.reverse(drops)}
  end

  defp drop(candidate, reason),
    do: %{"name" => candidate["name"], "template" => candidate["template"], "reason" => reason}

  # A learned area that shares a file with a history area takes its place: the history
  # changes, tests and fragile files stay, the files are united (at most 6), and the
  # learned terms, symbols and notes are added.
  defp merge_learned(learned, history, limits) do
    Enum.reduce(learned, {[], history}, fn candidate, {merged, left} ->
      case Enum.find_index(
             left,
             &(not MapSet.disjoint?(MapSet.new(&1["files"]), MapSet.new(candidate["files"])))
           ) do
        nil ->
          {merged ++ [candidate], left}

        index ->
          base = Enum.at(left, index)

          files =
            (candidate["files"] ++ base["files"])
            |> Enum.uniq()
            |> Enum.take(limits["cluster_files"])

          replaced =
            candidate
            |> Map.merge(%{
              "files" => files,
              "tests" => base["tests"],
              "commit_count" => base["commit_count"],
              "commits" => base["commits"],
              "fix_commits" => base["fix_commits"],
              "fixes" => base["fixes"],
              "risk" => base["risk"],
              "history_commits" => true
            })
            |> update_in(["evidence", "signals"], &Enum.uniq(base["evidence"]["signals"] ++ &1))

          {merged ++ [replaced], List.delete_at(left, index)}
      end
    end)
  end

  defp unique_name(base, used) do
    if MapSet.member?(used, base),
      do:
        Enum.find_value(
          2..99,
          &if(MapSet.member?(used, "#{base}-#{&1}"), do: nil, else: "#{base}-#{&1}")
        ),
      else: base
  end

  defp name(suffix), do: config(nil)["prefix"] <> suffix

  @doc false
  # The last two segments of the files' common directory that say something (not `src`,
  # `lib` and the like), else the stems of the first two files (every extension
  # removed: `index.d.ts` is `index`); lowercase, `[^a-z0-9]+` as `-`, at most 24 bytes;
  # `area` when nothing is left.
  def slug(files) do
    dirs =
      Enum.map(files, fn file ->
        file |> Path.dirname() |> String.split("/") |> Enum.reject(&(&1 in ["", "."]))
      end)

    common =
      dirs
      |> Enum.reduce(fn dir, acc ->
        acc |> Enum.zip(dir) |> Enum.take_while(fn {a, b} -> a == b end) |> Enum.map(&elem(&1, 0))
      end)
      |> Enum.reject(&(String.downcase(&1) in @generic_dirs))

    raw =
      case common do
        [] ->
          files
          |> Enum.map(&(&1 |> Path.basename() |> String.split(".") |> hd()))
          |> Enum.reject(&(&1 == ""))
          |> Enum.uniq()
          |> Enum.take(2)
          |> Enum.join("-")

        segments ->
          segments |> Enum.take(-2) |> Enum.join("-")
      end

    cleaned =
      raw
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> binary_part_safe(24)
      |> String.trim("-")

    if cleaned == "", do: "area", else: cleaned
  end

  defp binary_part_safe(text, max) when byte_size(text) <= max, do: text
  defp binary_part_safe(text, max), do: binary_part(text, 0, max)

  defp render_area(candidate, cfg, head, one_test, rules) do
    t = cfg["templates"]
    limits = cfg["limits"]

    files_line =
      if is_binary(head) and (candidate["origin"] == "history" or candidate["history_commits"]),
        do:
          fill(t["area_files"], %{
            "support" => candidate["commit_count"],
            "head" => String.slice(head, 0, 10)
          }),
        else:
          fill(t["area_files_learned"], %{"support" => length(candidate["evidence"]["commits"])})

    shas = Enum.uniq(candidate["fix_commits"])
    fixes = Enum.filter(candidate["fixes"] || [], &(&1["sha"] in shas and &1["files"] != []))
    # Tests history pairs with the files carry their joint-change count and go under the
    # history heading; tests a learner linked (support 0) go under their own heading.
    {paired, linked} = Enum.split_with(candidate["tests"], &(&1["support"] > 0))
    area_rules = area_rules(rules, candidate["files"], limits)

    fix_sections =
      cond do
        fixes != [] ->
          [
            {{:head, :fixes}, [t["area_fixes_head"]]},
            {:fixes,
             Enum.map(fixes, fn fix ->
               fill(t["area_fix"], %{
                 "sha" => String.slice(fix["sha"], 0, 10),
                 "files" => Enum.map_join(fix["files"], ", ", &"`#{&1}`")
               })
             end)}
          ]

        shas == [] ->
          []

        true ->
          [
            {:fixed,
             [
               fill(t["area_fixes"], %{
                 "shas" => Enum.map_join(shas, ", ", &String.slice(&1, 0, 10))
               })
             ]}
          ]
      end

    sections =
      [
        {:fixed, [fill(t["area_title"], %{"slug" => candidate["slug"]}), "", files_line]},
        {:files, Enum.map(candidate["files"], &"- `#{&1}`")},
        {{:head, :paired}, [t["area_tests"]]},
        {:paired, Enum.map(paired, &test_line(&1, one_test, t))},
        {{:head, :linked}, [t["area_tests_linked"]]},
        {:linked, Enum.map(linked, &test_line(&1, one_test, t))}
      ] ++
        fix_sections ++
        [
          {:risk,
           Enum.map(candidate["risk"], fn row ->
             if is_integer(row["fixes"]) and row["fixes"] > 0,
               do: fill(t["area_risk_of"], row),
               else: fill(t["area_risk"], row)
           end)},
          {:rules, Enum.map(area_rules, &fill(t["area_rule"], %{"rule" => &1}))},
          {:fixed, learned_terms_line(candidate, t)},
          {:notes, Enum.map(candidate["notes"], &fill(t["area_note"], %{"note" => &1}))},
          {:close, [area_close(paired != [], linked != [], t)]}
        ]

    with {:ok, _body, kept} <- fit(sections, limits["skill_body_bytes"]),
         # What the body still says once rows were cut decides the closing line and the
         # description, so neither promises tests or fixes the body no longer has. The
         # final closing line is never longer than the one the body was fitted with.
         has_paired = rows(kept, :paired) != [],
         has_linked = rows(kept, :linked) != [],
         has_fixes = rows(kept, :fixes) != [] or (fixes == [] and shas != []),
         kept = put_rows(kept, :close, [area_close(has_paired, has_linked, t)]),
         body = join(kept),
         description =
           area_description(
             candidate["files"],
             area_description_template(has_paired or has_linked, has_fixes, t),
             limits["description_bytes"]
           ),
         true <- safe_text?(description) and safe_text?(body) do
      entry = %{"name" => candidate["name"], "description" => description, "instructions" => body}

      evidence_commits =
        Enum.uniq(
          candidate["evidence"]["commits"] ++ candidate["commits"] ++ candidate["fix_commits"]
        )

      item = %{
        "name" => candidate["name"],
        "kind" => "skill",
        "template" => "area",
        "origin" => candidate["origin"],
        "path" => skill_path(candidate["name"]),
        "description_bytes" => byte_size(description),
        "body_bytes" => byte_size(body),
        "evidence" => %{
          "signals" => candidate["evidence"]["signals"],
          "commits" => Enum.uniq(candidate["evidence"]["commits"] ++ candidate["commits"]),
          "fix_commits" => candidate["fix_commits"],
          "files" => candidate["files"],
          "learned_id" => candidate["evidence"]["learned_id"]
        },
        "evidence_commits" => length(evidence_commits)
      }

      {:ok, %{entry: entry, item: item}}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, "text_unsafe"}
    end
  end

  defp area_close(true, _linked, t), do: t["area_close"]
  defp area_close(false, true, t), do: t["area_close_linked"]
  defp area_close(false, false, t), do: t["area_close_no_tests"]

  defp area_description_template(true, true, t), do: t["area_description"]
  defp area_description_template(true, false, t), do: t["area_description_no_fixes"]
  defp area_description_template(false, true, t), do: t["area_description_fixes_only"]
  defp area_description_template(false, false, t), do: t["area_description_plain"]

  defp test_line(%{"support" => 0} = test, one_test, t) do
    if one_test,
      do: fill(t["area_test_linked"], %{"test" => test["path"], "command" => one_test}),
      else: fill(t["area_test_linked_no_command"], %{"test" => test["path"]})
  end

  defp test_line(test, one_test, t) do
    if one_test,
      do:
        fill(t["area_test"], %{
          "test" => test["path"],
          "support" => test["support"],
          "command" => one_test
        }),
      else:
        fill(t["area_test_no_command"], %{"test" => test["path"], "support" => test["support"]})
  end

  # The repository's own rules (its instruction files, `auto` bucket, as CLAUDE.md
  # would take them) that name one of the area's files: the whole path, the file name,
  # or a distinctive stem (6 characters or more, not a name like `index` or `utils`).
  # Each is checked like any rendered line; at most `area_rules` of them.
  defp doc_rules(profile) do
    for candidate <- profile["rule_candidates"] || [],
        candidate["bucket"] == "auto",
        Enum.any?(candidate["citations"] || [], fn citation ->
          is_binary(citation["signal"]) and
            String.starts_with?(citation["signal"], "instructions.")
        end),
        text = candidate["text"],
        is_binary(text),
        do: text
  end

  defp area_rules(rules, files, limits) do
    rules
    |> Enum.filter(fn text ->
      byte_size(text) <= limits["area_rule_bytes"] and safe_text?(text) and
        not String.contains?(text, "\n") and Enum.any?(files, &names_file?(text, &1))
    end)
    |> Enum.uniq()
    |> Enum.take(limits["area_rules"])
  end

  defp names_file?(text, file) do
    base = Path.basename(file)
    stem = base |> String.split(".") |> hd()

    String.contains?(text, file) or
      (byte_size(base) >= 5 and word?(text, base)) or
      (byte_size(stem) >= 6 and String.downcase(stem) not in @generic_stems and word?(text, stem))
  end

  defp word?(text, word),
    do: Regex.match?(~r/(?<![A-Za-z0-9_])#{Regex.escape(word)}(?![A-Za-z0-9_])/, text)

  defp learned_terms_line(%{"terms" => [], "symbols" => []}, _t), do: []

  defp learned_terms_line(candidate, t) do
    terms =
      if candidate["terms"] == [],
        do: [],
        else: [fill(t["area_terms"], %{"terms" => Enum.join(candidate["terms"], ", ")})]

    symbols =
      if candidate["symbols"] == [],
        do: [],
        else: [
          fill(t["area_symbols"], %{
            "symbols" =>
              Enum.map_join(
                candidate["symbols"],
                ", ",
                &"`#{&1["name"]}` in `#{&1["path"]}`:#{&1["start"]}-#{&1["end"]}"
              )
          })
        ]

    [Enum.join(terms ++ symbols, " ")]
  end

  # Paths in cluster order while the line stays within the cap; the first is kept, by
  # its base name when the whole path is too long.
  defp area_description([first | rest] = files, template, cap) do
    render = fn listed ->
      more = length(files) - length(listed)
      suffix = if more > 0, do: " (+#{more} more)", else: ""
      fill(template, %{"files" => Enum.join(listed, ", ") <> suffix})
    end

    initial = if byte_size(render.([first])) <= cap, do: [first], else: [Path.basename(first)]

    rest
    |> Enum.take(2)
    |> Enum.reduce_while(initial, fn file, listed ->
      candidate = listed ++ [file]
      if byte_size(render.(candidate)) <= cap, do: {:cont, candidate}, else: {:halt, listed}
    end)
    |> render.()
  end

  # ---- locator ---------------------------------------------------------------------

  defp locator(evidence, learned, cfg, taken, profile) do
    gates = cfg["gates"]
    limits = cfg["limits"]
    t = cfg["templates"]
    layout = Enum.filter(profile["layout"] || [], &layout_row?/1)
    clusters = (evidence && evidence["clusters"]) || []
    learned_locators = Enum.filter(learned, &(&1["template"] == "locator"))

    # The locator earns its place (Task, and the built-in subagents with it, on every
    # request) only with history to prime it: a cluster strong enough for an area skill.
    gate? =
      is_map(evidence) and evidence["source_files"] >= gates["locator_min_source_files"] and
        Enum.any?(clusters, &(&1["support"] >= gates["area_min_support"]))

    learned_drops =
      if gate?,
        do: [],
        else:
          Enum.map(learned_locators, fn _ ->
            %{"name" => @locator_name, "template" => "locator", "reason" => "gate_failed"}
          end)

    cond do
      is_nil(evidence) ->
        {nil,
         [
           %{"name" => @locator_name, "template" => "locator", "reason" => "history_unavailable"}
           | learned_drops
         ]}

      not gate? ->
        {nil,
         [
           %{"name" => @locator_name, "template" => "locator", "reason" => "gate_failed"}
           | learned_drops
         ]}

      MapSet.member?(taken, agent_path(@locator_name)) ->
        {nil, [%{"name" => @locator_name, "template" => "locator", "reason" => "name_taken"}]}

      true ->
        scope =
          learned_locators
          |> Enum.flat_map(& &1["scope"])
          |> Enum.uniq()
          |> Enum.take(limits["learned_scope"])

        pairs =
          (profile["test_pairs"] || [])
          |> Enum.sort_by(
            &{if(&1["kind"] == "cochange", do: 0, else: 1), -&1["support"], &1["source"],
             &1["test"]}
          )
          |> Enum.take(limits["locator_pairs"])

        sections = [
          {:fixed, String.split(t["locator_head"], "\n")},
          {:fixed, if(layout == [], do: [], else: [t["locator_layout"]])},
          {:layout,
           layout
           |> Enum.take(limits["locator_layout"])
           |> Enum.map(&"- `#{&1["path"]}/`: #{&1["purpose"]}")},
          {:fixed, if(clusters == [], do: [], else: [t["locator_clusters"]])},
          {:clusters,
           clusters
           |> Enum.take(limits["locator_clusters"])
           |> Enum.map(fn c ->
             "- " <> Enum.map_join(Enum.take(c["files"], 6), ", ", &"`#{&1}`")
           end)},
          {:fixed, if(pairs == [], do: [], else: [t["locator_pairs"]])},
          {:pairs, Enum.map(pairs, &"- `#{&1["source"]}` -> `#{&1["test"]}`")},
          {:fixed,
           if(scope == [],
             do: [],
             else: [
               fill(t["locator_scope"], %{"paths" => Enum.map_join(scope, ", ", &"`#{&1}`")})
             ]
           )}
        ]

        learned_ids =
          learned_locators |> Enum.map(& &1["evidence"]["learned_id"]) |> Enum.reject(&is_nil/1)

        agent(
          @locator_name,
          "locator",
          if(learned_locators == [], do: "history", else: "learned"),
          t["locator_description"],
          sections,
          @locator_tools,
          cfg,
          %{
            "signals" =>
              Enum.uniq(
                [@area_signal, "history.test_pairs"] ++
                  if(layout == [], do: [], else: ["layout.paths"]) ++
                  Enum.flat_map(learned_locators, & &1["evidence"]["signals"])
              ),
            "commits" =>
              (Enum.flat_map(learned_locators, & &1["evidence"]["commits"]) ++
                 Enum.flat_map(clusters, & &1["commits"]))
              |> Enum.uniq()
              |> Enum.take(limits["shas"]),
            "fix_commits" => [],
            "files" =>
              clusters |> Enum.flat_map(& &1["files"]) |> Kernel.++(scope) |> Enum.uniq(),
            "learned_id" => List.first(learned_ids)
          }
        )
        |> case do
          {:ok, rendered} ->
            {rendered, learned_drops}

          {:error, reason} ->
            {nil, [%{"name" => @locator_name, "template" => "locator", "reason" => reason}]}
        end
    end
  end

  defp layout_row?(%{"path" => path, "purpose" => purpose}),
    do:
      Mapping.plain_path?(path) and is_binary(purpose) and byte_size(purpose) <= 80 and
        Regex.match?(~r/\A[ -~]+\z/, purpose) and not String.contains?(purpose, ["`", "@", "!"])

  defp layout_row?(_), do: false

  # ---- test runner -----------------------------------------------------------------

  defp runner(learned, cfg, taken, profile, blueprint, one_test) do
    gates = cfg["gates"]
    limits = cfg["limits"]
    t = cfg["templates"]
    commands = profile["commands"] || %{}
    denied = blueprint["denied_commands"] || []
    pairs = profile["test_pairs"] || []
    learned_runners = Enum.filter(learned, &(&1["template"] == "test_runner"))

    usable? = fn command ->
      is_binary(command) and Regex.match?(@command, command) and not Spec.denied?(command, denied)
    end

    # A command the subagent may run must take test files: the test tool itself
    # (pytest, jest, mix test...), or a package script the analyzer found to be one
    # plain call of such a tool (`commands.test_single` is then its file form, `npm run
    # <script> --`). Never another package script such as `npm run test-browser`, which
    # may build, install or run another suite.
    direct? = fn command -> usable?.(command) and direct_test_command?(command, blueprint) end
    package_form = package_file_form(commands)

    suite =
      cond do
        direct?.(commands["test"]) -> commands["test"]
        package_form != nil and usable?.(commands["test"]) -> commands["test"]
        true -> nil
      end

    file = if usable?.(one_test), do: one_test, else: nil

    learned_commands =
      for runner <- learned_runners,
          %{"role" => role, "argv" => argv} <- runner["commands"],
          command = strip_file(argv),
          if(role == "test", do: direct?.(command), else: usable?.(command)),
          do: {role, command}

    learned_suite = for {"test", command} <- learned_commands, do: command
    learned_file = for {"test_file", command} <- learned_commands, do: command

    suites = Enum.uniq(Enum.reject([suite | learned_suite], &is_nil/1))
    files = Enum.uniq(Enum.reject([file | learned_file], &is_nil/1))
    allowed = Enum.uniq(suites ++ files)

    # A runner that cannot run one test file cannot run the paired tests it lists.
    gate? =
      (usable?.(commands["test"]) and length(pairs) >= gates["runner_min_test_pairs"]) or
        learned_runners != []

    cond do
      not gate? ->
        {nil, [],
         [%{"name" => @runner_name, "template" => "test_runner", "reason" => "gate_failed"}]}

      files == [] ->
        {nil, [],
         [
           %{
             "name" => @runner_name,
             "template" => "test_runner",
             "reason" => "runner_command_unsuitable"
           }
         ]}

      MapSet.member?(taken, agent_path(@runner_name)) ->
        {nil, [],
         [%{"name" => @runner_name, "template" => "test_runner", "reason" => "name_taken"}]}

      true ->
        ranked =
          pairs
          |> Enum.sort_by(&{-&1["support"], &1["source"], &1["test"]})
          |> Enum.take(limits["runner_pairs"])

        sections = [
          {:fixed, [t["runner_head"]]},
          {:fixed, Enum.map(suites, &fill(t["runner_suite"], %{"command" => &1}))},
          {:fixed, Enum.map(files, &fill(t["runner_file"], %{"command" => &1}))},
          {:fixed, if(ranked == [], do: [], else: [t["runner_prefer"], t["runner_pairs"]])},
          {:pairs, Enum.map(ranked, &"- `#{&1["source"]}` -> `#{&1["test"]}`")},
          {:fixed, [t["runner_reply"], t["runner_close"]]}
        ]

        learned_ids =
          learned_runners |> Enum.map(& &1["evidence"]["learned_id"]) |> Enum.reject(&is_nil/1)

        case agent(
               @runner_name,
               "test_runner",
               if(learned_commands == [], do: "history", else: "learned"),
               t["runner_description"],
               sections,
               @runner_tools,
               cfg,
               %{
                 "signals" =>
                   Enum.uniq(
                     ["commands.test", "history.test_pairs"] ++
                       Enum.flat_map(learned_runners, & &1["evidence"]["signals"])
                   ),
                 "commits" =>
                   learned_runners
                   |> Enum.flat_map(& &1["evidence"]["commits"])
                   |> Enum.uniq()
                   |> Enum.take(limits["shas"]),
                 "fix_commits" => [],
                 "files" => ranked |> Enum.map(& &1["test"]) |> Enum.uniq(),
                 "learned_id" => List.first(learned_ids)
               }
             ) do
          {:ok, rendered} ->
            {rendered, allowed, []}

          {:error, reason} ->
            {nil, [],
             [%{"name" => @runner_name, "template" => "test_runner", "reason" => reason}]}
        end
    end
  end

  defp direct_test_command?(command, blueprint) do
    table = blueprint["stop_file_arguments"]
    is_map(table) and is_binary(Spec.file_command(command, table["test"] || [], table))
  end

  # The one-test command: the file form of `test_single`, else of `test` (as the stop
  # hook picks it), else the package-script file form, or nil.
  defp one_test_command(profile, blueprint) do
    commands = profile["commands"] || %{}
    table = blueprint["stop_file_arguments"]

    tool =
      if is_map(table) do
        [commands["test_single"], commands["test"]]
        |> Enum.filter(&is_binary/1)
        |> Enum.find_value(&Spec.file_command(&1, table["test"] || [], table))
      end

    tool || package_file_form(commands)
  end

  # `commands.test_single` when the analyzer derived it as the file form of the package
  # script in `commands.test` (`npm run <script> --`, `pnpm run <script>`, `yarn test`):
  # it does so only for a script that is one plain call of a test tool taking files.
  defp package_file_form(commands) do
    single = commands["test_single"]
    test = commands["test"]

    if is_binary(single) and is_binary(test) and Regex.match?(@package_script, test) and
         Regex.match?(@package_file_form, single),
       do: single
  end

  defp agent(name, template, origin, description, sections, tools, cfg, evidence) do
    with {:ok, body, _kept} <- fit(sections, cfg["limits"]["agent_body_bytes"]),
         true <-
           safe_text?(description) and safe_text?(body) and
             byte_size(description) <= cfg["limits"]["description_bytes"] do
      entry = %{
        "name" => name,
        "description" => description,
        "instructions" => body,
        "tools" => tools
      }

      item = %{
        "name" => name,
        "kind" => "agent",
        "template" => template,
        "origin" => origin,
        "path" => agent_path(name),
        "description_bytes" => byte_size(description),
        "body_bytes" => byte_size(body),
        "max_turns" => cfg["max_turns"][template],
        "evidence" => evidence,
        "evidence_commits" => length(evidence["commits"])
      }

      {:ok, %{entry: entry, item: item}}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, "text_unsafe"}
    end
  end

  # ---- shared ----------------------------------------------------------------------

  # Joins the sections into a body; while it is over `cap`, the last row of the longest
  # cuttable list goes (never a fixed line, a heading or the closing line, never below 2
  # files). A heading `{{:head, kind}, lines}` is written only while its list `kind`
  # has rows. Over with nothing left to cut: `over_limit`. Returns the body and the
  # sections it was joined from.
  defp fit(sections, cap) do
    body = join(sections)

    if byte_size(body) <= cap do
      {:ok, body, sections}
    else
      cuttable =
        sections
        |> Enum.with_index()
        |> Enum.filter(fn {{kind, rows}, _} ->
          is_atom(kind) and kind not in [:fixed, :close] and
            length(rows) > if(kind == :files, do: 2, else: 0)
        end)

      case cuttable do
        [] ->
          {:error, "over_limit"}

        _ ->
          {{kind, rows}, index} =
            Enum.max_by(cuttable, fn {{_kind, rows}, index} -> {length(rows), -index} end)

          fit(List.replace_at(sections, index, {kind, Enum.drop(rows, -1)}), cap)
      end
    end
  end

  defp join(sections) do
    sections
    |> Enum.flat_map(fn
      {{:head, kind}, lines} -> if rows(sections, kind) == [], do: [], else: lines
      {_kind, lines} -> lines
    end)
    |> Enum.join("\n")
  end

  defp rows(sections, kind) do
    Enum.find_value(sections, [], fn
      {^kind, rows} -> rows
      _ -> nil
    end)
  end

  defp put_rows(sections, kind, rows) do
    Enum.map(sections, fn
      {^kind, _} -> {kind, rows}
      other -> other
    end)
  end

  defp fill(template, values) do
    Regex.replace(~r/\{([a-z_]+)\}/, template, fn whole, key ->
      case Map.fetch(values, key) do
        {:ok, value} -> to_string(value)
        :error -> whole
      end
    end)
  end

  @doc false
  # Printable ASCII and newlines only; no dynamic shell (`!` and a backtick, or a fence
  # opened with `!`) and no `@` a reader could take for a file import.
  def safe_text?(text) when is_binary(text) do
    Regex.match?(~r/\A[ -~\n]*\z/, text) and not String.contains?(text, "!`") and
      not Regex.match?(~r/(?:`{3,}|~{3,})[ \t]*!/, text) and
      text |> String.split("\n") |> Enum.all?(&Guidance.import_safe?/1)
  end

  def safe_text?(_), do: false

  defp select(select, skills, agents) do
    drop_all = fn items ->
      Enum.map(
        items,
        &%{
          "name" => &1.entry["name"],
          "template" => &1.item["template"],
          "reason" => "not_selected"
        }
      )
    end

    case select do
      "all" -> {skills, agents, []}
      "skills" -> {skills, [], drop_all.(agents)}
      "agents" -> {[], agents, drop_all.(skills)}
      _ -> {[], [], drop_all.(skills ++ agents)}
    end
  end

  # The listing is paid on every request: over the cap, the lowest-ranked skill goes
  # first, then the agents from the last.
  defp listing_cap(skills, agents, cap) do
    total = listing_bytes(Enum.map(skills, & &1.entry), Enum.map(agents, & &1.entry))

    cond do
      total <= cap ->
        {skills, agents, []}

      skills != [] ->
        {last, kept} = List.pop_at(skills, -1)
        {s, a, d} = listing_cap(kept, agents, cap)

        {s, a,
         [%{"name" => last.entry["name"], "template" => "area", "reason" => "over_limit"} | d]}

      true ->
        {last, kept} = List.pop_at(agents, -1)
        {s, a, d} = listing_cap(skills, kept, cap)

        {s, a,
         [
           %{
             "name" => last.entry["name"],
             "template" => last.item["template"],
             "reason" => "over_limit"
           }
           | d
         ]}
    end
  end

  defp diagnostics("none", _items, _dropped, _evidence), do: []

  defp diagnostics(_select, [], dropped, evidence) do
    reasons = dropped |> Enum.map(& &1["reason"]) |> Enum.uniq() |> Enum.sort() |> Enum.join(", ")

    history =
      if is_nil(evidence),
        do:
          " No usable git history was analyzed (no git, too few changes, or a shallow clone with fewer than 200 commits; for a shallow clone run `git fetch --unshallow` and generate again), so no history-based item can be derived.",
        else: ""

    [
      %{
        "code" => "native_none_generated",
        "severity" => "info",
        "message" => "No Claude Code skill or subagent was generated (#{reasons}).#{history}"
      }
    ]
  end

  defp diagnostics(_select, _items, _dropped, _evidence), do: []

  defp skill_path(name), do: ".claude/skills/#{name}/SKILL.md"
  defp agent_path(name), do: ".claude/agents/#{name}.md"

  @doc "True for a generated item name (`olivium-` and lowercase words)."
  @spec name?(term()) :: boolean()
  def name?(name) when is_binary(name), do: byte_size(name) <= 64 and Regex.match?(@name, name)
  def name?(_), do: false
end
