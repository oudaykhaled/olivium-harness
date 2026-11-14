defmodule HarnessForge.Generation.LearnedRender do
  @moduledoc """
  Turns a learned bundle (`olivium.learned/v1`, written by `olivium learn`) and the
  repository's own git history into the parts of a `lean-ai` spec.

  - `read/1` reads `learned.json` and `learned.sha256` from a bundle directory and
    refuses (`learned_invalid`) a bundle whose file checksum, canonical form, `sha256`
    field or fields do not hold. Every value that can reach an exported file is
    checked again here against the contract's character rules: a value outside them
    refuses the bundle, it is never repaired.
  - `prepare/2` adds what only git can tell: the bundle's base must be HEAD or an
    ancestor of HEAD (`learned_base_mismatch` otherwise), the index rows
    (`HarnessForge.Generation.Index`), the tracked files and the locator gate
    (`HarnessForge.Generation.LocatorGate`). git and pattern matching only; nothing from
    the repository runs, and no model is called.
  - `spec_parts/3` is pure: from that prepared map, the profile and the blueprint it
    gives `spec.learning`, `spec.locator` (gate numbers, frozen constants, index rows,
    the verified test command, concept pitfalls), `spec.rewrites`, `spec.learned` (the
    bundle, exported byte for byte as `.olivium/learned.json`), the learned
    `CLAUDE.md` rule candidates, the learned skill and agent candidates for
    `HarnessForge.Generation.Native` (`native_candidates`) and the diagnostics.

  A learned `CLAUDE.md` line only ever replaces a static line: only global pitfalls of
  the kinds deprecation, warnings and changelog are candidates, each names the static
  rule it replaces, and the spec keeps it only when that static rule is there (so the
  learned file never has more lines than the static one). Every line costs about 36
  tokens on every request.

  A learner that did not run (`failed` or `unavailable`) leaves only the deterministic
  commands and rewrites in the bundle; the export says so with the warning
  `ai_learning_unavailable`, never quietly. Items whose paths are missing at HEAD (a
  bundle made at an ancestor) are left out at render and counted
  (`learned_item_dropped_at_render`).

  Learned skills and agents become Native candidates (design section 3.2) with
  `"origin" => "learned"`: an `area` skill gets its paths, the tests with their pair
  support from the profile (0 when no pair names them), the evidence commits, the terms
  of its concept, its symbols located in the index rows (`name`, `path`, `start`, `end`)
  and the text of at most 2 of its pitfalls; a `locator` gets its paths as scope; a
  `test_runner` gets the verified commands it names. Each is checked with
  `Native.validate_candidate/1` here; one that fails is left out and reported
  (`learned_native_invalid`), never repaired.
  """

  alias HarnessForge.Analyzers.Git
  alias HarnessForge.Contracts
  alias HarnessForge.Contracts.Error
  alias HarnessForge.Generation.{Blueprint, Guidance, Index, LocatorGate, Native}
  alias HarnessForge.Learning.Bundle

  @schema "olivium.learned/v1"
  @bundle_file "learned.json"
  @checksum_file "learned.sha256"
  @max_bundle_bytes 1_048_576
  @hex40 ~r/\A[0-9a-f]{40}\z/
  @hex64 ~r/\A[0-9a-f]{64}\z/
  @repository_name ~r/\A[A-Za-z0-9._-]{1,100}\z/
  @learner_statuses ~w(ok mock failed unavailable)
  @learner_reasons ~w(none cloud_not_allowed no_key_file no_docker image_missing meter_unavailable cap_reached turn_cap timeout invalid_output model_error)
  @verification_statuses ~w(ok unavailable)
  @verification_reasons ~w(none no_docker image_missing)
  @drop_kinds ~w(concept pitfall command rewrite skill agent)
  @drop_reasons ~w(schema_invalid over_limit text_unsafe duplicate path_missing_at_base evidence_missing evidence_after_base evidence_mismatch unsafe_argv network_required verify_failed verify_timeout tool_missing output_not_smaller not_verified pattern_too_common example_copy)
  @models ~w(claude-haiku-5-5 claude-sonnet-5-5 mock none)
  @engines ~w(claude-code none)
  @concept_id ~r/\Ac[0-9]{2}\z/
  @pitfall_id ~r/\Ap[0-9]{2}\z/
  @command_id ~r/\Acmd-[a-z0-9-]{1,30}\z/
  @rewrite_id ~r/\Arw[0-9]{2}\z/
  @skill_id ~r/\As[0-9]{2}\z/
  @agent_id ~r/\Aa[0-9]{2}\z/
  @slug_rule ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/
  @agent_kinds ~w(locator test_runner)
  @runner_command_ids ~w(cmd-test cmd-test-file)
  @term_rule ~r/\A[a-z0-9][a-z0-9 _.-]{1,39}\z/
  @symbol_rule ~r/\A[A-Za-z_][A-Za-z0-9_.]{0,79}\z/
  @word_rule ~r/\A[A-Za-z0-9_.\/:=+@,%-]+\z/
  @tool_rule ~r/\A[A-Za-z0-9][A-Za-z0-9._+-]{0,63}\z/
  @pitfall_text ~r/\A[\x20-\x7e]{20,200}\z/
  @pitfall_kinds ~w(deprecation warnings changelog test_location api_compat typing docs other)
  @command_roles ~w(test test_file lint format typecheck)
  @command_sources ~w(deterministic learned)
  @rewrite_kinds ~w(missing_tool wrong_runner quiet_flags)
  @signatures ~w(exit_127 module_not_found spawn_failed none)
  # The practice rule a learned global pitfall replaces, by pitfall kind.
  @replaces %{
    "deprecation" => "practices.deprecation",
    "warnings" => "practices.warnings_as_errors",
    "changelog" => "history.fix_changelog"
  }
  @max_learned_lines 3
  @min_global_evidence 3
  @learned_weight 1000
  @constant_keys ~w(path_weight symbol_weight symbol_max_locations stem_weight history_scale term_top_k learned_scale min_score min_margin min_margin_percent card_bytes)

  @doc "The frozen locator constants of the base blueprint."
  @spec constants() :: map()
  def constants, do: Blueprint.all()["base"]["locator"]

  # -- reading a bundle ---------------------------------------------------------------

  @doc """
  Reads and checks a bundle directory. Returns
  `{:ok, %{"doc" => map, "file_sha256" => hex}}` or `{:error, %Error{code: "learned_invalid"}}`.
  """
  @spec read(Path.t()) :: {:ok, map()} | {:error, Error.t()}
  def read(dir) when is_binary(dir) do
    with {:ok, bytes} <- bounded_read(Path.join(dir, @bundle_file), @max_bundle_bytes),
         {:ok, checksum} <- bounded_read(Path.join(dir, @checksum_file), 200),
         file_sha = Contracts.sha256(bytes),
         :ok <-
           check(
             checksum == "#{file_sha}  #{@bundle_file}\n",
             "learned.sha256 does not match learned.json"
           ),
         {:ok, doc} <- decode(bytes),
         :ok <- check(is_map(doc), "learned.json is not an object"),
         :ok <-
           check(
             Contracts.canonical_json(doc) <> "\n" == bytes,
             "learned.json is not canonical JSON"
           ),
         :ok <-
           check(
             doc["sha256"] == Contracts.digest(Map.delete(doc, "sha256")),
             "the sha256 field does not match the document"
           ),
         :ok <- validate(doc) do
      {:ok, %{"doc" => doc, "file_sha256" => file_sha}}
    end
  end

  def read(_), do: invalid("The bundle path must be a directory path")

  defp bounded_read(path, max) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= max ->
        case File.read(path) do
          {:ok, bytes} when byte_size(bytes) <= max -> {:ok, bytes}
          _ -> invalid("#{Path.basename(path)} cannot be read")
        end

      {:ok, %File.Stat{type: :regular}} ->
        invalid("#{Path.basename(path)} is larger than #{max} bytes")

      _ ->
        invalid("#{Path.basename(path)} is missing or not a regular file")
    end
  end

  defp decode(bytes) do
    case Contracts.decode_json(bytes) do
      {:ok, doc} -> {:ok, doc}
      {:error, _} -> invalid("learned.json is not valid bounded JSON")
    end
  end

  @doc "Checks a decoded bundle against the parts of `olivium.learned/v1` the export uses."
  @spec validate(map()) :: :ok | {:error, Error.t()}
  def validate(doc) do
    learner = doc["learner"] || %{}
    verification = doc["verification"] || %{}
    repository = doc["repository"] || %{}

    checks = [
      {doc["schema"] == @schema, "schema must be #{@schema}"},
      {hex?(doc["sha256"], @hex64), "sha256"},
      {is_binary(repository["name"]) and Regex.match?(@repository_name, repository["name"]),
       "repository.name"},
      {hex?(repository["base_commit"], @hex40), "repository.base_commit"},
      {count?(repository["base_commit_time"]), "repository.base_commit_time"},
      {learner["status"] in @learner_statuses, "learner.status"},
      {learner["status_reason"] in @learner_reasons, "learner.status_reason"},
      {learner["model"] in @models, "learner.model"},
      {learner["engine"] in @engines, "learner.engine"},
      {Enum.all?(~w(requests cost_nanousd cap_nanousd wall_ms max_turns), &count?(learner[&1])),
       "learner counts"},
      {is_map(learner["tokens"]) and
         Enum.all?(~w(input output cache_read cache_write), &count?(learner["tokens"][&1])),
       "learner.tokens"},
      {verification["status"] in @verification_statuses, "verification.status"},
      {verification["status_reason"] in @verification_reasons, "verification.status_reason"},
      {list?(doc["concepts"], 60) and Enum.all?(doc["concepts"], &concept?/1), "concepts"},
      {list?(doc["pitfalls"], 12) and Enum.all?(doc["pitfalls"], &pitfall?/1), "pitfalls"},
      {list?(doc["commands"], 8) and Enum.all?(doc["commands"], &command?/1), "commands"},
      {list?(doc["rewrites"], 12) and Enum.all?(doc["rewrites"], &rewrite?/1), "rewrites"},
      {list?(doc["dropped"], 300) and Enum.all?(doc["dropped"], &dropped?/1), "dropped"},
      # Bundles from learner prompt v1 have no skills or agents key.
      {list?(Map.get(doc, "skills", []), 3) and Enum.all?(Map.get(doc, "skills", []), &skill?/1),
       "skills"},
      {list?(Map.get(doc, "agents", []), 2) and Enum.all?(Map.get(doc, "agents", []), &agent?/1),
       "agents"},
      {native_references?(doc), "skill and agent references"},
      {unique_ids?(doc), "item ids must be unique"},
      {learner["status"] not in ~w(failed unavailable) or
         (doc["concepts"] == [] and doc["pitfalls"] == [] and Map.get(doc, "skills", []) == [] and
            Map.get(doc, "agents", []) == [] and
            Enum.all?(doc["commands"] ++ doc["rewrites"], &(&1["source"] == "deterministic"))),
       "a learner that did not run leaves only deterministic items"},
      {verification["status"] == "ok" or (doc["commands"] == [] and doc["rewrites"] == []),
       "unverified commands or rewrites"}
    ]

    case Enum.find(checks, fn {ok, _} -> ok != true end) do
      nil -> :ok
      {_, field} -> invalid("learned.json fails the contract at #{field}")
    end
  end

  defp concept?(%{} = c) do
    is_binary(c["id"]) and Regex.match?(@concept_id, c["id"]) and
      words?(c["terms"], 1, 8, @term_rule) and paths?(c["paths"], 1, 4) and
      words?(c["symbols"], 0, 6, @symbol_rule) and paths?(c["tests"], 0, 3) and
      words?(c["evidence"], 2, 5, @hex40) and count?(c["support"])
  end

  defp concept?(_), do: false

  defp pitfall?(%{} = p) do
    is_binary(p["id"]) and Regex.match?(@pitfall_id, p["id"]) and p["scope"] in ~w(global concept) and
      ((p["scope"] == "global" and is_nil(p["concept"])) or
         (p["scope"] == "concept" and is_binary(p["concept"]) and
            Regex.match?(@concept_id, p["concept"]))) and
      p["kind"] in @pitfall_kinds and text_safe?(p["text"]) and
      words?(p["trigger_terms"], 0, 6, @term_rule) and
      words?(p["evidence"], 2, 5, @hex40) and p["status"] == "verified"
  end

  defp pitfall?(_), do: false

  defp command?(%{} = c) do
    is_binary(c["id"]) and Regex.match?(@command_id, c["id"]) and c["source"] in @command_sources and
      c["role"] in @command_roles and argv?(c["argv"], 1, 16, true) and
      is_map(c["verify"]) and c["verify"]["status"] == "verified"
  end

  defp command?(_), do: false

  defp rewrite?(%{} = r) do
    match = r["match"] || %{}
    replace = r["replace"] || %{}

    replacement? =
      case r["kind"] do
        "missing_tool" ->
          replace["message_id"] == "tool_missing" and is_binary(replace["tool"]) and
            Regex.match?(@tool_rule, replace["tool"]) and map_size(replace) == 2

        "wrong_runner" ->
          argv?(replace["argv_prefix"], 1, 10, false) and map_size(replace) == 1

        "quiet_flags" ->
          argv?(replace["argv_prefix"], 1, 10, false) and map_size(replace) == 1 and
            Bundle.quiet_flags?(match["argv_prefix"] || [], replace["argv_prefix"])

        _ ->
          false
      end

    is_binary(r["id"]) and Regex.match?(@rewrite_id, r["id"]) and r["kind"] in @rewrite_kinds and
      r["source"] in @command_sources and
      argv?(match["argv_prefix"], 1, 6, false) and replacement? and is_map(r["verify"]) and
      r["verify"]["wrong_signature"] in @signatures
  end

  defp rewrite?(_), do: false

  defp skill?(%{} = s) do
    is_binary(s["id"]) and Regex.match?(@skill_id, s["id"]) and s["kind"] == "area" and
      is_binary(s["concept"]) and Regex.match?(@concept_id, s["concept"]) and
      is_binary(s["slug"]) and byte_size(s["slug"]) <= 24 and Regex.match?(@slug_rule, s["slug"]) and
      paths?(s["paths"], 2, 6) and paths?(s["tests"], 0, 4) and
      words?(s["symbols"], 0, 6, @symbol_rule) and words?(s["pitfalls"], 0, 2, @pitfall_id) and
      words?(s["evidence"], 2, 5, @hex40) and map_size(s) == 9
  end

  defp skill?(_), do: false

  defp agent?(%{} = a) do
    is_binary(a["id"]) and Regex.match?(@agent_id, a["id"]) and a["kind"] in @agent_kinds and
      paths?(a["paths"], 1, 8) and words?(a["commands"], 0, 4, @command_id) and
      words?(a["evidence"], 2, 5, @hex40) and map_size(a) == 5 and
      ((a["kind"] == "locator" and a["commands"] == []) or
         (a["kind"] == "test_runner" and a["commands"] != [] and
            Enum.all?(a["commands"], &(&1 in @runner_command_ids))))
  end

  defp agent?(_), do: false

  # A skill names a concept and pitfalls of the bundle; an agent names its commands; one
  # agent per kind.
  defp native_references?(doc) do
    ids = fn key -> MapSet.new(List.wrap(doc[key]), &(is_map(&1) && &1["id"])) end
    concepts = ids.("concepts")
    pitfalls = ids.("pitfalls")
    commands = ids.("commands")
    skills = List.wrap(Map.get(doc, "skills", []))
    agents = List.wrap(Map.get(doc, "agents", []))
    kinds = Enum.map(agents, &(is_map(&1) && &1["kind"]))

    Enum.all?(skills, fn skill ->
      is_map(skill) and MapSet.member?(concepts, skill["concept"]) and
        Enum.all?(List.wrap(skill["pitfalls"]), &MapSet.member?(pitfalls, &1))
    end) and
      Enum.all?(agents, fn agent ->
        is_map(agent) and Enum.all?(List.wrap(agent["commands"]), &MapSet.member?(commands, &1))
      end) and length(Enum.uniq(kinds)) == length(kinds)
  end

  defp dropped?(%{"kind" => kind, "id" => id, "reason" => reason}),
    do: kind in @drop_kinds and is_binary(id) and byte_size(id) <= 40 and reason in @drop_reasons

  defp dropped?(_), do: false

  defp unique_ids?(doc) do
    ids =
      Enum.flat_map(~w(concepts pitfalls commands rewrites skills agents), fn key ->
        Enum.map(Map.get(doc, key, []), & &1["id"])
      end)

    length(Enum.uniq(ids)) == length(ids)
  end

  # Printable ASCII, 20 to 200 bytes, no newline, no `!` before a backtick (a shell
  # expansion in Claude Code skills) and no `@` outside a code span (a file import).
  defp text_safe?(text) when is_binary(text),
    do:
      Regex.match?(@pitfall_text, text) and not String.contains?(text, "!`") and
        Guidance.import_safe?(text)

  defp text_safe?(_), do: false

  defp argv?(argv, min, max, file?) do
    is_list(argv) and length(argv) in min..max and
      Enum.all?(argv, fn word ->
        is_binary(word) and (Regex.match?(@word_rule, word) or (file? and word == "{file}"))
      end) and Regex.match?(~r/\A[A-Za-z0-9_.\/]/, hd(argv))
  end

  defp words?(list, min, max, rule) do
    is_list(list) and length(list) in min..max and
      Enum.all?(list, &(is_binary(&1) and Regex.match?(rule, &1)))
  end

  defp paths?(list, min, max),
    do: is_list(list) and length(list) in min..max and Enum.all?(list, &Index.plain_path?/1)

  defp list?(list, max), do: is_list(list) and length(list) <= max
  defp hex?(value, rule), do: is_binary(value) and Regex.match?(rule, value)
  defp count?(value), do: is_integer(value) and value >= 0

  # -- preparing from git -----------------------------------------------------------------

  @doc """
  Reads the bundle in `dir`, checks its base against the repository at `root`, and
  builds the index rows and the locator gate. Returns the map `spec_parts/3` takes.
  """
  @spec prepare(Path.t(), Path.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def prepare(root, dir, constants \\ constants()) do
    with {:ok, bundle} <- read(dir),
         {:ok, collected} <- Index.collect(root),
         :ok <- base_check(collected, bundle["doc"]["repository"]["base_commit"]) do
      {:ok, from_collected(bundle, collected, constants)}
    end
  end

  @doc false
  def from_collected(bundle, collected, constants) do
    stopwords = MapSet.new(constants["term_stopwords"] || [])
    sources = Enum.filter(collected.files, &Index.indexable?/1)

    extras = %{
      "tests" => Index.test_rows([], collected.files, sources),
      "cochange" => [],
      "test_command" => nil
    }

    gate = collected |> LocatorGate.run(extras, constants) |> Map.delete("cases")

    %{
      "bundle" => bundle["doc"],
      "file_sha256" => bundle["file_sha256"],
      "head" => collected.head,
      "files" => collected.files,
      "symbols" => Index.symbol_rows(collected.snapshot),
      "terms" => Index.term_rows(collected.commits, stopwords, Map.keys(collected.snapshot)),
      "gate" => gate
    }
  end

  # The base must be HEAD or one of its ancestors: `git log HEAD..BASE` lists the
  # commits of BASE that HEAD does not have, so it is empty exactly then. A base the
  # repository does not have fails the same way.
  defp base_check(collected, base) do
    cond do
      base == collected.head ->
        :ok

      true ->
        case Git.log(collected.repo, ["--format=%H", "--max-count=1", "HEAD.." <> base]) do
          {:ok, ""} ->
            :ok

          _ ->
            {:error,
             %Error{
               code: "learned_base_mismatch",
               message:
                 "The bundle was learned at #{String.slice(base, 0, 12)}, which is not HEAD or an ancestor of HEAD; learn again at this commit"
             }}
        end
    end
  end

  # -- spec parts (pure) --------------------------------------------------------------------

  @doc """
  The `lean-ai` parts of a spec, from `prepare/3` output, the (command-filtered)
  profile and the blueprint. Returns
  `%{"learning", "locator", "rewrites", "learned", "learned_rules", "hooks", "diagnostics"}`;
  each `learned_rules` entry is `%{"replaces" => static signal, "rule" => rule}`.
  """
  @spec spec_parts(map(), map(), map()) :: map()
  def spec_parts(prepared, profile, blueprint) do
    doc = prepared["bundle"]
    constants = blueprint["locator"]
    present = MapSet.new(prepared["files"] || [])
    at_head? = fn paths -> Enum.all?(paths, &MapSet.member?(present, &1)) end

    {concepts, lost_concepts} =
      Enum.split_with(doc["concepts"], &(at_head?.(&1["paths"]) and at_head?.(&1["tests"])))

    kept_ids = MapSet.new(concepts, & &1["id"])

    {pitfalls, lost_pitfalls} =
      Enum.split_with(
        doc["pitfalls"],
        &(&1["scope"] == "global" or MapSet.member?(kept_ids, &1["concept"]))
      )

    {native_candidates, lost_native, invalid_native} =
      native_candidates(doc, concepts, pitfalls, prepared, profile, at_head?)

    dropped_at_render = length(lost_concepts) + length(lost_pitfalls) + lost_native
    learned_terms? = constants["learned_terms"] == true
    gate = prepared["gate"]
    rendered? = gate["status"] == "passed"
    sources = Enum.filter(prepared["files"] || [], &Index.indexable?/1)

    terms =
      (prepared["terms"] ++ if(learned_terms?, do: learned_rows(concepts), else: []))
      |> Enum.uniq()
      |> Enum.sort()

    tests = Index.test_rows(profile["test_pairs"] || [], prepared["files"] || [], sources)

    %{
      "learning" => learning(doc, prepared["file_sha256"], concepts, pitfalls, dropped_at_render),
      "locator" => %{
        "rendered" => rendered?,
        "status" => gate["status"],
        "replay_n" => gate["replay_n"],
        "top3_hits" => gate["top3_hits"],
        "wrong" => gate["wrong"],
        "max_card_bytes" => gate["max_card_bytes"],
        "version" => constants["version"],
        "constants" => Map.take(constants, @constant_keys),
        "stem_stopwords" => constants["stem_stopwords"] |> Enum.uniq() |> Enum.sort(),
        "learned_terms" => learned_terms?,
        "test_command" => test_command(doc["commands"]),
        "pitfalls" => concept_pitfalls(pitfalls, concepts),
        "index" => %{"symbols" => prepared["symbols"], "terms" => terms, "tests" => tests}
      },
      "rewrites" => %{
        "timeout_seconds" => blueprint["hook_timeouts"]["rewrite"],
        "items" => Enum.map(Enum.sort_by(doc["rewrites"], & &1["id"]), &rewrite_item/1)
      },
      "learned" => doc,
      "learned_rules" => learned_rules(pitfalls),
      "native_candidates" => native_candidates,
      "hooks" =>
        if(rendered?,
          do: [
            %{
              "id" => "locator",
              "event" => "prompt_submit",
              "builtin" => "locator",
              "timeout_seconds" => blueprint["hook_timeouts"]["locator"]
            }
          ],
          else: []
        ),
      "diagnostics" =>
        diagnostics(doc, gate, learned_terms?, dropped_at_render) ++
          native_diagnostics(invalid_native)
    }
  end

  # Learned skills and agents in the candidate shape of `Native.validate_candidate/1`.
  # Returns `{candidates, dropped_at_head, invalid}`.
  defp native_candidates(doc, concepts, pitfalls, prepared, profile, at_head?) do
    skills = Map.get(doc, "skills", [])
    agents = Map.get(doc, "agents", [])

    {present, lost} =
      Enum.split_with(skills ++ agents, fn item ->
        at_head?.(item["paths"]) and at_head?.(Map.get(item, "tests", []))
      end)

    concept_terms = Map.new(concepts, &{&1["id"], &1["terms"]})
    pitfall_texts = Map.new(pitfalls, &{&1["id"], &1["text"]})
    commands = Map.new(doc["commands"], &{&1["id"], &1})
    symbol_rows = Enum.map(prepared["symbols"] || [], &String.split(&1, "\t"))

    {valid, invalid} =
      present
      |> Enum.sort_by(& &1["id"])
      |> Enum.map(fn item ->
        candidate =
          native_candidate(item, %{
            terms: concept_terms,
            texts: pitfall_texts,
            commands: commands,
            symbols: symbol_rows,
            pairs: profile["test_pairs"] || []
          })

        case Native.validate_candidate(candidate) do
          {:ok, _} -> {:ok, candidate}
          {:error, reason} -> {:error, %{"id" => item["id"], "reason" => reason}}
        end
      end)
      |> Enum.split_with(&(elem(&1, 0) == :ok))

    {Enum.map(valid, &elem(&1, 1)), length(lost), Enum.map(invalid, &elem(&1, 1))}
  end

  defp native_candidate(%{"kind" => "area"} = skill, ctx) do
    %{
      "template" => "area",
      "origin" => "learned",
      "slug" => skill["slug"],
      "files" => skill["paths"],
      "tests" =>
        Enum.map(
          skill["tests"],
          &%{"path" => &1, "support" => pair_support(&1, skill["paths"], ctx.pairs)}
        ),
      "commit_count" => length(skill["evidence"]),
      "commits" => skill["evidence"],
      "fix_commits" => [],
      "risk" => [],
      # A concept left out at HEAD gives no terms; the skill's own paths are present.
      "terms" => ctx.terms |> Map.get(skill["concept"], []) |> Enum.take(6),
      "symbols" =>
        skill["symbols"]
        |> Enum.flat_map(&List.wrap(locate_symbol(&1, skill["paths"], ctx.symbols)))
        |> Enum.take(6),
      "notes" =>
        skill["pitfalls"]
        |> Enum.flat_map(&List.wrap(Map.get(ctx.texts, &1)))
        |> Enum.take(2),
      "evidence" => evidence(skill, "learning.skill.area")
    }
  end

  defp native_candidate(%{"kind" => "locator"} = agent, _ctx) do
    %{
      "template" => "locator",
      "origin" => "learned",
      "scope" => agent["paths"],
      "evidence" => evidence(agent, "learning.agent.locator")
    }
  end

  defp native_candidate(%{"kind" => "test_runner"} = agent, ctx) do
    %{
      "template" => "test_runner",
      "origin" => "learned",
      "commands" =>
        for id <- agent["commands"],
            command = ctx.commands[id],
            command != nil do
          %{"role" => command["role"], "argv" => Enum.join(command["argv"], " "), "id" => id}
        end,
      "evidence" => evidence(agent, "learning.agent.test_runner")
    }
  end

  defp evidence(item, signal),
    do: %{"signals" => [signal], "commits" => item["evidence"], "learned_id" => item["id"]}

  # The strongest pair support between a test and one of the skill's paths, or 0.
  defp pair_support(test, paths, pairs) do
    pairs
    |> Enum.filter(&(is_map(&1) and &1["test"] == test and &1["source"] in paths))
    |> Enum.map(&(&1["support"] || 0))
    |> Enum.max(fn -> 0 end)
  end

  # The index row of a symbol in one of the skill's paths, or nil when it cannot be
  # placed for sure. A plain name matches the definitions of that name that no class
  # row encloses (a function nested in a function still counts); `Owner.member`
  # (`Widget.resize`, indexed as `resize`) matches the definitions of `member` inside
  # the span of the one class row named `Owner`. One match is taken as it is. Several
  # are taken only when they are one run of adjacent definitions in one file, such as
  # `@overload` stubs and then the implementation: the last one, the implementation.
  # Anything else (several files, owners or separate definitions) gives nil, so no
  # wrong location is shown.
  defp locate_symbol(name, paths, rows) do
    defs =
      for [row_name, path, first, stop | rest] <- rows,
          path in paths,
          {first, ""} <- [Integer.parse(first)],
          {stop, ""} <- [Integer.parse(stop)],
          do: {row_name, path, first, stop, List.first(rest)}

    classes = Enum.filter(defs, &(elem(&1, 4) == "class"))

    matches =
      case String.split(name, ".") do
        [single] ->
          Enum.filter(defs, fn row ->
            elem(row, 0) == single and not Enum.any?(classes, &encloses?(&1, row))
          end)

        parts ->
          [owner, member] = Enum.take(parts, -2)

          case Enum.filter(defs, &(elem(&1, 0) == name)) do
            [] ->
              case Enum.filter(classes, &(elem(&1, 0) == owner)) do
                [scope] -> Enum.filter(defs, &(elem(&1, 0) == member and encloses?(scope, &1)))
                _ -> []
              end

            exact ->
              exact
          end
      end

    case matches |> Enum.sort_by(&elem(&1, 2)) |> adjacent_run() do
      {_, path, first, stop, _} ->
        %{"name" => name, "path" => path, "start" => first, "end" => stop}

      nil ->
        nil
    end
  end

  # The last of definitions that follow each other in one file (each starts at most 2
  # lines after the previous one ends), or nil.
  defp adjacent_run([]), do: nil

  defp adjacent_run([first | rest]) do
    Enum.reduce_while(rest, first, fn {_, path, start, _, _} = row,
                                      {_, prev_path, _, prev_stop, _} ->
      if path == prev_path and start <= prev_stop + 2,
        do: {:cont, row},
        else: {:halt, nil}
    end)
  end

  defp encloses?({_, path, first, stop, _}, {_, path, other_first, other_stop, _}),
    do: first < other_first and other_stop <= stop

  defp encloses?(_, _), do: false

  defp native_diagnostics([]), do: []

  defp native_diagnostics(invalid) do
    [
      %{
        "code" => "learned_native_invalid",
        "severity" => "info",
        "count" => length(invalid),
        "message" =>
          "#{length(invalid)} learned skill or agent #{if length(invalid) == 1, do: "proposal does", else: "proposals do"} not fit the generator's contract and #{if length(invalid) == 1, do: "was", else: "were"} left out (" <>
            Enum.map_join(invalid, ", ", &"#{&1["id"]}: #{&1["reason"]}") <> ")."
      }
    ]
  end

  defp learning(doc, file_sha, concepts, pitfalls, dropped_at_render) do
    learner = doc["learner"]
    tokens = learner["tokens"]

    %{
      "bundle_sha256" => doc["sha256"],
      "file_sha256" => file_sha,
      "repository" => doc["repository"]["name"],
      "base_commit" => doc["repository"]["base_commit"],
      "status" => learner["status"],
      "status_reason" => learner["status_reason"],
      "model" => learner["model"],
      "requests" => learner["requests"],
      "tokens_total" =>
        tokens["input"] + tokens["output"] + tokens["cache_read"] + tokens["cache_write"],
      "cost_nanousd" => learner["cost_nanousd"],
      "verification" => doc["verification"]["status"],
      "kept" => %{
        "concepts" => length(concepts),
        "pitfalls" => length(pitfalls),
        "commands" => length(doc["commands"]),
        "rewrites" => length(doc["rewrites"])
      },
      "dropped" => length(doc["dropped"]),
      "dropped_at_render" => dropped_at_render
    }
  end

  # Concept terms point at the concept's files with one fixed weight.
  defp learned_rows(concepts) do
    for concept <- concepts,
        term <- concept["terms"],
        path <- concept["paths"],
        Index.plain_path?(path) do
      "#{Index.normalize(term)}\t#{path}\t#{@learned_weight}\tlearned"
    end
    |> Enum.reject(&String.starts_with?(&1, "\t"))
  end

  # The verified command for one test file, if the bundle has one.
  defp test_command(commands) do
    commands
    |> Enum.filter(&("{file}" in &1["argv"]))
    |> Enum.sort_by(&{if(&1["role"] == "test_file", do: 0, else: 1), &1["id"]})
    |> Enum.find(&(&1["role"] in ~w(test_file test)))
    |> case do
      nil -> nil
      command -> command["argv"]
    end
  end

  defp concept_pitfalls(pitfalls, concepts) do
    paths = Map.new(concepts, &{&1["id"], &1["paths"]})

    for pitfall <- Enum.sort_by(pitfalls, & &1["id"]),
        pitfall["scope"] == "concept",
        triggers =
          pitfall["trigger_terms"] |> Enum.map(&Index.normalize/1) |> Enum.reject(&(&1 == "")),
        triggers != [] do
      %{
        "id" => pitfall["id"],
        "paths" => paths[pitfall["concept"]],
        "triggers" => triggers |> Enum.uniq() |> Enum.sort(),
        "text" => pitfall["text"]
      }
    end
  end

  # Global pitfalls of a replaceable kind with at least 3 evidence commits become rule
  # candidates, one per kind (at most 3), by kind then id. Each names the static rule on
  # the same topic; `Generation.Spec` keeps it only where that rule exists.
  defp learned_rules(pitfalls) do
    pitfalls
    |> Enum.filter(
      &(&1["scope"] == "global" and Map.has_key?(@replaces, &1["kind"]) and
          length(&1["evidence"]) >= @min_global_evidence)
    )
    |> Enum.sort_by(&{&1["kind"], &1["id"]})
    |> Enum.uniq_by(& &1["kind"])
    |> Enum.take(@max_learned_lines)
    |> Enum.map(fn pitfall ->
      fingerprint = Contracts.sha256(pitfall["text"])

      %{
        "replaces" => Map.fetch!(@replaces, pitfall["kind"]),
        "rule" => %{
          "id" => uuid("rule:" <> fingerprint),
          "origin" => "derived",
          "statement" => pitfall["text"],
          "fingerprint" => fingerprint,
          "source" => %{
            "detector" => "learning",
            "signal" => "learning.pitfall." <> pitfall["kind"],
            "path" => nil,
            "line" => nil
          }
        }
      }
    end)
  end

  defp rewrite_item(rewrite) do
    replace = rewrite["replace"]

    %{
      "id" => rewrite["id"],
      "kind" => rewrite["kind"],
      "match" => rewrite["match"]["argv_prefix"],
      "replace" => replace["argv_prefix"],
      "tool" => replace["tool"]
    }
  end

  defp diagnostics(doc, gate, learned_terms?, dropped_at_render) do
    learner = doc["learner"]

    unavailable =
      if learner["status"] in ~w(failed unavailable),
        do: [
          %{
            "code" => "ai_learning_unavailable",
            "severity" => "warning",
            "message" =>
              "AI learning did not run (#{learner["status"]}: #{learner["status_reason"]}). This export holds only the deterministic index, verified commands and rewrites: no learned concepts or pitfalls."
          }
        ],
        else: []

    locator =
      if gate["status"] == "passed",
        do: [],
        else: [
          %{
            "code" => "locator_gate_failed",
            "severity" => "info",
            "message" =>
              "The prompt-time locator is not rendered: on this repository's last fix commits it named a changed file in #{gate["top3_hits"]} of #{gate["replay_n"]} replays with #{gate["wrong"]} wrong cards (needs at least 10 replays, 70% hits among printed cards and at most 15% wrong). The index is still exported."
          }
        ]

    terms =
      if learned_terms?,
        do: [],
        else: [
          %{
            "code" => "learned_terms_off",
            "severity" => "info",
            "message" =>
              "Learned concept terms are not written to the index: no time-split test has shown yet that they help the locator."
          }
        ]

    dropped =
      if dropped_at_render == 0,
        do: [],
        else: [
          %{
            "code" => "learned_item_dropped_at_render",
            "severity" => "info",
            "count" => dropped_at_render,
            "message" =>
              "#{dropped_at_render} learned #{if dropped_at_render == 1, do: "item names", else: "items name"} a file missing at HEAD and #{if dropped_at_render == 1, do: "was", else: "were"} left out (path_missing_at_base)."
          }
        ]

    unavailable ++ locator ++ terms ++ dropped
  end

  defp uuid(seed) do
    <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
      e::binary-size(12), _rest::binary>> =
      Contracts.sha256(seed)

    Enum.join([a, b, c, d, e], "-")
  end

  defp check(true, _message), do: :ok
  defp check(_, message), do: invalid(message)

  defp invalid(message), do: {:error, %Error{code: "learned_invalid", message: message}}
end
