defmodule HarnessForge.Learning.Bundle do
  @moduledoc """
  The learned bundle, schema `olivium.learned/v1` (contract-v4.md section 2.1).

    * `check_raw/2` reads the learner's untrusted `learned.raw.json` as data and applies
      the schema, path and evidence checks (design.md section 3.3, steps 1 to 3). Every
      item that fails is dropped with a reason code from the closed list; commands and
      rewrites that pass go on to Docker verification (`HarnessForge.Learning.Verify`).
    * `deterministic_commands/1` derives command candidates from the existing analyzer.
    * `resolve_agents/2` runs after verification: a proposed agent keeps only command
      ids whose command was verified (`not_verified` otherwise), and one agent per kind.
    * `finalize/1` assembles the document: lists sorted, ids reassigned in a fixed order
      (`c01`, `p01`, `cmd-<role>`, `rw01`, `s01`, `a01`), measurements put in buckets so a
      re-run gives the same bytes, canonical JSON, and `sha256` over the document without
      that key.
    * `validate/1` is the normative validator; `read/1` checks a written bundle.
    * `write/2` writes `learned.json` and `learned.sha256` into a fresh directory, never
      over an existing one.

  Text from the learner can reach `CLAUDE.md` and hook output, so pitfall text must be
  printable ASCII of 20 to 200 bytes with no `!` + backtick, no `@` outside a code span
  and no URL, and every argv word must match `^[A-Za-z0-9_./:=+@,%-]+$`, start with a
  known tool and contain no shell, network or package-install word.

  Skills (`area`) and agents (`locator`, `test_runner`) are data only: a slug, paths,
  symbol names, ids of kept concepts, pitfalls and verified commands, and evidence
  hashes. No text of the learner reaches them; `HarnessForge.Generation.Native` renders
  them from fixed templates.
  """

  alias HarnessForge.Analyzers.{Git, Paths}
  alias HarnessForge.Contracts
  alias HarnessForge.Contracts.Error
  alias HarnessForge.Learning.Extract

  @schema_path Path.expand("../../../priv/schemas/learned-v1.json", __DIR__)
  @external_resource @schema_path
  @schema @schema_path |> File.read!() |> Jason.decode!()

  # The learner prompt's own example pitfall texts. A pitfall that repeats one of them
  # word for word was copied, not learned (review M4), whatever its evidence says.
  @prompt_path Path.expand("../../../priv/learner/prompt-v2.md", __DIR__)
  @external_resource @prompt_path
  @example_texts (case Regex.run(~r/```json\n(.*?)\n```/s, File.read!(@prompt_path)) do
                    [_, json] ->
                      json
                      |> Jason.decode!()
                      |> Map.get("pitfalls", [])
                      |> Enum.map(
                        &(&1["text"]
                          |> String.downcase()
                          |> String.replace(~r/[^a-z0-9]+/, " ")
                          |> String.trim())
                      )

                    nil ->
                      []
                  end)

  @raw_limit 256 * 1024
  # Verification timings change from run to run (shared Docker, load), and no bucket keeps a
  # continuous measurement stable at its edges. The bundle records 0 so that two runs give
  # the same bytes; exact timings stay in learn-report.json beside it.
  @verify_ms 0
  @limits %{
    "concepts" => 60,
    "pitfalls" => 12,
    "commands" => 8,
    "rewrites" => 12,
    "skills" => 3,
    "agents" => 2
  }
  @raw_considered %{
    "concepts" => 100,
    "pitfalls" => 30,
    "commands" => 16,
    "rewrites" => 24,
    "skills" => 6,
    "agents" => 4
  }
  @dropped_limit 300

  @reasons ~w(schema_invalid over_limit text_unsafe duplicate path_missing_at_base evidence_missing
              evidence_after_base evidence_mismatch unsafe_argv network_required verify_failed
              verify_timeout tool_missing output_not_smaller not_verified pattern_too_common
              example_copy)
  @roles ~w(test test_file lint format typecheck)
  @rewrite_kinds ~w(missing_tool wrong_runner quiet_flags)
  @pitfall_kinds ~w(deprecation warnings changelog test_location api_compat typing docs other)
  @agent_kinds ~w(locator test_runner)
  # The commands a test_runner agent may name: the verified suite and one-file commands.
  @runner_command_ids ~w(cmd-test cmd-test-file)

  @hex40 ~r/\A[0-9a-f]{40}\z/
  @path ~r/\A[A-Za-z0-9_.\/-]{1,200}\z/
  @term ~r/\A[a-z0-9][a-z0-9 _.-]{1,39}\z/
  @symbol ~r/\A[A-Za-z_][A-Za-z0-9_.]{0,79}\z/
  @word ~r/\A[A-Za-z0-9_.\/:=+@,%-]{1,200}\z/
  @tool ~r/\A[A-Za-z0-9][A-Za-z0-9._+-]{0,63}\z/
  @slug ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/
  @command_id ~r/\Acmd-[a-z0-9-]{1,30}\z/

  # The first word of a command must be one of these tools or runners.
  @programs ~w(uv uvx python python3 pytest tox nox ruff black isort flake8 pylint mypy pyright ty
               pyrefly coverage pre-commit prek poetry pdm hatch npm npx pnpm yarn node jest mocha
               vitest ava tap eslint prettier tsc biome go gofmt golangci-lint cargo rustfmt make
               mix bundle rake rspec ruby rubocop phpunit composer gradle mvn dotnet deno bun)
  # No word anywhere may be one of these: shells, network, privilege, VCS and installs.
  @denied_words ~w(rm rmdir mv cp curl wget sh bash zsh dash fish sudo su doas chmod chown dd mkfs
                   ssh scp sftp rsync nc ncat netcat telnet git eval source install uninstall
                   publish upgrade login logout)
  @interpreters ~w(python python3 node ruby perl deno bun)
  @inline_code ~w(-c -e --eval -p --print -r --require)
  @file_tools ~w(ruff black isort flake8 pylint mypy pyright ty pyrefly eslint prettier biome rubocop
                 pytest jest mocha vitest)
  @test_tools ~w(pytest jest mocha vitest tox nox ava tap rspec phpunit test)
  # Quiet flags may only make output shorter; they must not change what runs. `-p
  # no:cacheprovider`, for example, also removes `--lf`, `--ff`, `--sw` and
  # `--cache-clear`, so a rewrite that adds it breaks ordinary commands (review R3).
  @quiet_words ~w(-q -qq --quiet --no-header --tb=short --tb=line --silent --reporter=dot --reporter=min)
  @quiet_reporters ~w(dot min)
  @npm_like ~w(npm pnpm yarn)
  # A pitfall pattern found in more than this share of the extract's fix commits says
  # nothing about the rule (`def test_`, `it\(`). Changelog rules are exempt: their
  # marker is meant to appear in most fixes.
  @common_pattern_percent 25
  # Directories under a test tree that hold helpers rather than test files.
  @non_test_dirs ~w(support fixtures fixture helpers helper utils util mocks __mocks__ __fixtures__ __snapshots__ snapshots data)

  @spec schema() :: map()
  def schema, do: @schema

  @spec reasons() :: [String.t()]
  def reasons, do: @reasons

  # Validation ---------------------------------------------------------------------------

  @doc """
  The normative validator: the closed schema, then the semantic rules (no control
  characters anywhere, ids sorted and unique, pitfall rules, status consistency, digest).
  """
  @spec validate(term()) :: {:ok, map()} | {:error, Error.t()}
  def validate(doc) do
    with {:ok, doc} <- Contracts.validate_document(doc, @schema, "learned_invalid"),
         [] <- semantic_errors(doc) do
      {:ok, doc}
    else
      {:error, %Error{} = error} -> {:error, error}
      errors when is_list(errors) -> invalid(errors)
    end
  end

  defp semantic_errors(doc) do
    concept_ids = MapSet.new(doc["concepts"], & &1["id"])
    status = doc["learner"]["status"]
    # Bundles written before skills and agents existed have neither key.
    skills = Map.get(doc, "skills", [])
    agents = Map.get(doc, "agents", [])

    List.flatten([
      if(control_free?(doc), do: [], else: ["$: control character in a string"]),
      for(
        key <- ~w(concepts pitfalls commands rewrites skills agents),
        ids = Enum.map(Map.get(doc, key, []), & &1["id"]),
        ids != Enum.sort(ids) or length(Enum.uniq(ids)) != length(ids),
        do: "$.#{key}: ids must be sorted and unique"
      ),
      if(
        Enum.map(doc["dropped"], &{&1["kind"], &1["id"]}) ==
          Enum.sort(Enum.map(doc["dropped"], &{&1["kind"], &1["id"]})),
        do: [],
        else: ["$.dropped: must be sorted by kind and id"]
      ),
      Enum.flat_map(doc["pitfalls"], &pitfall_errors(&1, concept_ids)),
      Enum.flat_map(doc["commands"], &command_errors/1),
      Enum.flat_map(doc["rewrites"], &rewrite_errors/1),
      native_errors(doc, skills, agents, concept_ids),
      if(
        status in ["ok", "mock"] or
          (doc["concepts"] == [] and doc["pitfalls"] == [] and skills == [] and agents == []),
        do: [],
        else: [
          "$: concepts, pitfalls, skills and agents must be empty unless learner.status is ok or mock"
        ]
      ),
      if(
        status in ["ok", "mock"] or
          Enum.all?(doc["commands"] ++ doc["rewrites"], &(&1["source"] == "deterministic")),
        do: [],
        else: ["$: only deterministic commands and rewrites without a learner"]
      ),
      if(
        doc["verification"]["status"] == "ok" or (doc["commands"] == [] and doc["rewrites"] == []),
        do: [],
        else: ["$: commands and rewrites must be empty unless verification.status is ok"]
      ),
      if(Contracts.digest(Map.delete(doc, "sha256")) == doc["sha256"],
        do: [],
        else: ["$.sha256: does not match the canonical document"]
      )
    ])
  end

  defp pitfall_errors(pitfall, concept_ids) do
    id = pitfall["id"]

    [
      if(
        (pitfall["scope"] == "global" and is_nil(pitfall["concept"])) or
          (pitfall["scope"] == "concept" and MapSet.member?(concept_ids, pitfall["concept"])),
        do: nil,
        else: "#{id}: concept reference"
      ),
      if(pitfall["scope"] == "global" and length(pitfall["evidence"]) < 3,
        do: "#{id}: a global pitfall needs 3 or more evidence commits"
      ),
      if(safe_text?(pitfall["text"]), do: nil, else: "#{id}: unsafe text"),
      if(safe_pattern?(pitfall["check"]["pattern"]), do: nil, else: "#{id}: unsafe pattern"),
      if(pitfall["check"]["min_commits"] > length(pitfall["evidence"]),
        do: "#{id}: min_commits above the evidence count"
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  # Skills name a kept concept and kept pitfalls; agents name verified commands (a
  # test_runner only the suite and one-file commands, a locator none); one agent per kind.
  defp native_errors(doc, skills, agents, concept_ids) do
    pitfall_ids = MapSet.new(doc["pitfalls"], & &1["id"])
    command_ids = MapSet.new(doc["commands"], & &1["id"])

    skill_errors =
      for skill <- skills,
          error <- [
            if(MapSet.member?(concept_ids, skill["concept"]),
              do: nil,
              else: "#{skill["id"]}: concept reference"
            ),
            if(Enum.all?(skill["pitfalls"], &MapSet.member?(pitfall_ids, &1)),
              do: nil,
              else: "#{skill["id"]}: pitfall reference"
            )
          ],
          error,
          do: error

    agent_errors =
      for agent <- agents,
          error <- [
            if(Enum.all?(agent["commands"], &MapSet.member?(command_ids, &1)),
              do: nil,
              else: "#{agent["id"]}: command reference"
            ),
            if(
              (agent["kind"] == "locator" and agent["commands"] == []) or
                (agent["kind"] == "test_runner" and agent["commands"] != [] and
                   Enum.all?(agent["commands"], &(&1 in @runner_command_ids))),
              do: nil,
              else: "#{agent["id"]}: commands do not fit the kind"
            )
          ],
          error,
          do: error

    kinds = Enum.map(agents, & &1["kind"])

    skill_errors ++
      agent_errors ++
      if(length(Enum.uniq(kinds)) == length(kinds),
        do: [],
        else: ["$.agents: at most one agent per kind"]
      )
  end

  defp command_errors(command) do
    if command["argv"] |> Enum.reject(&(&1 == "{file}")) |> safe_argv?(),
      do: [],
      else: ["#{command["id"]}: unsafe argv"]
  end

  defp rewrite_errors(rewrite) do
    words =
      rewrite["match"]["argv_prefix"] ++ (get_in(rewrite, ["replace", "argv_prefix"]) || [])

    [
      if(safe_argv?(rewrite["match"]["argv_prefix"]) and safe_words?(words),
        do: nil,
        else: "#{rewrite["id"]}: unsafe argv"
      ),
      if(
        rewrite["kind"] != "quiet_flags" or
          rewrite["verify"]["bytes_after"] * 2 <= rewrite["verify"]["bytes_before"],
        do: nil,
        else: "#{rewrite["id"]}: output not halved"
      ),
      if(
        rewrite["kind"] != "quiet_flags" or
          quiet_flags?(
            rewrite["match"]["argv_prefix"],
            get_in(rewrite, ["replace", "argv_prefix"]) || []
          ),
        do: nil,
        else: "#{rewrite["id"]}: a quiet_flags rewrite may only add output flags"
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp control_free?(value) when is_binary(value),
    do: not Regex.match?(~r/[\x00-\x1f\x7f]/, value)

  defp control_free?(value) when is_map(value),
    do: Enum.all?(value, fn {key, item} -> control_free?(key) and control_free?(item) end)

  defp control_free?(value) when is_list(value), do: Enum.all?(value, &control_free?/1)
  defp control_free?(_), do: true

  @doc "Pitfall text rule: printable ASCII, 20 to 200 bytes, no `!` + backtick, no `@` outside a code span, no URL."
  @spec safe_text?(term()) :: boolean()
  def safe_text?(text) when is_binary(text) do
    byte_size(text) in 20..200 and Regex.match?(~r/\A[ -~]+\z/, text) and
      not String.contains?(text, ["!`", "://"]) and
      text
      |> String.split("`")
      |> Enum.take_every(2)
      |> Enum.all?(&(not String.contains?(&1, "@")))
  end

  def safe_text?(_), do: false

  @doc """
  Pitfall check patterns: 80 bytes or fewer, compiling, and inside a subset without
  backtracking traps: no `(?` groups, no back-references, no quantified group, no
  repetition count of three or more digits.
  """
  @spec safe_pattern?(term()) :: boolean()
  def safe_pattern?(pattern) when is_binary(pattern) do
    byte_size(pattern) in 1..80 and Regex.match?(~r/\A[ -~]+\z/, pattern) and
      not String.contains?(pattern, "(?") and
      not Regex.match?(~r/\\[1-9kgpPQEXCRK]/, pattern) and
      not Regex.match?(~r/\)[*+?{]/, pattern) and
      not Regex.match?(~r/\{[0-9]{3,}/, pattern) and
      match?({:ok, _}, Regex.compile(pattern))
  end

  def safe_pattern?(_), do: false

  @doc "argv rule: each word matches the charset; the first is a known tool; no denied word."
  @spec safe_argv?([String.t()]) :: boolean()
  def safe_argv?([first | _] = argv) do
    first in @programs and safe_words?(argv)
  end

  def safe_argv?(_), do: false

  defp safe_words?(words) do
    Enum.all?(words, &(is_binary(&1) and Regex.match?(@word, &1))) and
      not Enum.any?(words, &(&1 in @denied_words)) and
      not inline_code?(words)
  end

  defp inline_code?(words) do
    words
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.any?(fn [a, b] -> a in @interpreters and b in @inline_code end)
  end

  # Reading and writing -------------------------------------------------------------------

  @doc "Canonical bytes of a finalized document: canonical JSON plus a newline."
  @spec encode(map()) :: binary()
  def encode(doc), do: Contracts.canonical_json(doc) <> "\n"

  @doc """
  Write `learned.json` and `learned.sha256` into `dir`, which must not exist yet (its
  parent must). Files are staged next to it and renamed into place; nothing is ever
  overwritten. Extra files (the run report) go into the same directory.
  """
  @spec write(Path.t(), map(), [{String.t(), binary()}]) ::
          {:ok, %{String.t() => String.t()}} | {:error, Error.t()}
  def write(dir, doc, extra \\ []) do
    with {:ok, doc} <- validate(doc),
         :ok <- fresh(dir) do
      bytes = encode(doc)
      file_sha = Contracts.sha256(bytes)
      stage = Path.join(Path.dirname(dir), ".olivium-learn-stage-" <> suffix())

      files =
        [{"learned.json", bytes}, {"learned.sha256", "#{file_sha}  learned.json\n"} | extra]

      try do
        with :ok <- File.mkdir(stage),
             :ok <- write_files(stage, files),
             :ok <- fresh(dir),
             :ok <- File.rename(stage, dir) do
          {:ok,
           %{
             "dir" => dir,
             "path" => Path.join(dir, "learned.json"),
             "sha256" => doc["sha256"],
             "file_sha256" => file_sha
           }}
        else
          {:error, %Error{}} = failure -> failure
          {:error, reason} -> io_error(reason)
        end
      after
        File.rm_rf(stage)
      end
    end
  end

  defp write_files(stage, files) do
    Enum.reduce_while(files, :ok, fn {name, bytes}, :ok ->
      path = Path.join(stage, name)

      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(path, bytes, [:exclusive]) do
        {:cont, :ok}
      else
        failure -> {:halt, failure}
      end
    end)
  end

  @doc "`:ok` when `dir` is an absolute path that does not exist and whose parent is a directory."
  @spec ensure_fresh(term()) :: :ok | {:error, Error.t()}
  def ensure_fresh(dir), do: fresh(dir)

  defp fresh(dir) do
    cond do
      not is_binary(dir) or Path.type(dir) != :absolute ->
        {:error, %Error{code: "invalid_arguments", message: "--out must be an absolute path"}}

      match?({:ok, _}, File.lstat(dir)) ->
        {:error,
         %Error{code: "out_not_fresh", message: "--out already exists; give a new directory"}}

      not match?({:ok, %File.Stat{type: :directory}}, File.stat(Path.dirname(dir))) ->
        {:error,
         %Error{code: "out_parent_missing", message: "The parent of --out is not a directory"}}

      true ->
        :ok
    end
  end

  defp suffix, do: 6 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  defp io_error(reason),
    do:
      {:error, %Error{code: "io_error", message: "Writing the bundle failed: #{inspect(reason)}"}}

  @doc """
  Read and check a bundle directory: `learned.sha256` names the file's digest, the bytes
  are canonical, the document validates and its `sha256` matches.
  """
  @spec read(Path.t()) :: {:ok, map()} | {:error, Error.t()}
  def read(dir) do
    path = Path.join(dir, "learned.json")

    with {:ok, %File.Stat{type: :regular, size: size}} when size <= 2_000_000 <- File.lstat(path),
         {:ok, bytes} <- File.read(path),
         {:ok, %File.Stat{type: :regular}} <- File.lstat(Path.join(dir, "learned.sha256")),
         {:ok, listed} <- File.read(Path.join(dir, "learned.sha256")),
         true <- listed == "#{Contracts.sha256(bytes)}  learned.json\n",
         {:ok, doc} <- Contracts.decode_json(bytes),
         true <- is_map(doc) and encode(doc) == bytes,
         {:ok, doc} <- validate(doc) do
      {:ok, doc}
    else
      {:error, %Error{} = error} ->
        {:error, %{error | code: "learned_invalid"}}

      _ ->
        {:error,
         %Error{
           code: "learned_invalid",
           message: "The bundle is missing, not canonical, or its sha256 does not verify"
         }}
    end
  end

  # Raw learner output ---------------------------------------------------------------------

  @doc """
  Check the learner's raw output against the extract. Returns kept concepts and pitfalls
  (final shape without ids), command and rewrite candidates for verification, dropped
  rows, and counters for the run report; or `{:error, "invalid_output"}` when the file is
  not a bounded JSON object with list sections.
  """
  @spec check_raw(binary(), Extract.t()) :: {:ok, map()} | {:error, String.t()}
  def check_raw(bytes, extract) when is_binary(bytes) and byte_size(bytes) <= @raw_limit do
    with {:ok, raw} when is_map(raw) <- Contracts.decode_json(bytes),
         {:ok, sections} <- sections(raw) do
      context = %{
        extract: extract,
        ancestors: nil,
        all_commits: nil,
        contents: %{},
        fix_lines: nil
      }

      {concepts, concept_drops, concept_refs, context, symbols_removed} =
        check_concepts(sections["concepts"], context)

      {pitfalls, pitfall_drops, context} =
        check_pitfalls(sections["pitfalls"], concept_refs, context)

      {commands, command_drops} = check_commands(sections["commands"])
      {rewrites, rewrite_drops} = check_rewrites(sections["rewrites"])

      {skills, skill_drops, context, skill_symbols_removed} =
        check_skills(sections["skills"], concept_refs, pitfall_refs(pitfalls), context)

      {agents, agent_drops, _context} = check_agents(sections["agents"], context)

      {:ok,
       %{
         concepts: concepts,
         pitfalls: pitfalls,
         commands: commands,
         rewrites: rewrites,
         skills: skills,
         agents: agents,
         dropped:
           concept_drops ++
             pitfall_drops ++ command_drops ++ rewrite_drops ++ skill_drops ++ agent_drops,
         report: %{
           "raw_counts" => Map.new(sections, fn {key, items} -> {key, length(items)} end),
           "symbols_removed" => symbols_removed,
           "skill_symbols_removed" => skill_symbols_removed
         }
       }}
    else
      _ -> {:error, "invalid_output"}
    end
  end

  def check_raw(_, _), do: {:error, "invalid_output"}

  defp sections(raw) do
    Enum.reduce_while(~w(concepts pitfalls commands rewrites skills agents), {:ok, %{}}, fn key,
                                                                                            {:ok,
                                                                                             acc} ->
      case Map.get(raw, key, []) do
        items when is_list(items) -> {:cont, {:ok, Map.put(acc, key, items)}}
        _ -> {:halt, :error}
      end
    end)
  end

  defp drop(kind, id, reason) when reason in @reasons,
    do: %{"kind" => kind, "id" => id, "reason" => reason}

  defp positional(prefix, index),
    do: prefix <> String.pad_leading(Integer.to_string(index), 2, "0")

  # Concepts

  defp check_concepts(items, context) do
    {considered, extra} = Enum.split(items, @raw_considered["concepts"])

    over =
      extra
      |> Enum.with_index(@raw_considered["concepts"] + 1)
      |> Enum.map(fn {_, i} -> drop("concept", positional("c", i), "over_limit") end)

    {kept, drops, refs, context, removed, _seen} =
      considered
      |> Enum.with_index(1)
      |> Enum.reduce({[], [], %{}, context, 0, MapSet.new()}, fn {item, index},
                                                                 {kept, drops, refs, ctx, removed,
                                                                  seen} ->
        id = positional("c", index)

        case concept(item, ctx) do
          {:ok, concept, ctx, gone} ->
            key = {Enum.sort(concept["paths"]), Enum.sort(concept["terms"])}

            cond do
              MapSet.member?(seen, key) ->
                {kept, [drop("concept", id, "duplicate") | drops], refs, ctx, removed, seen}

              length(kept) >= @limits["concepts"] ->
                {kept, [drop("concept", id, "over_limit") | drops], refs, ctx, removed, seen}

              true ->
                position = length(kept)
                concept = Map.put(concept, :ref, position)

                refs =
                  refs
                  |> Map.put(id, position)
                  |> then(&if(raw_id(item), do: Map.put(&1, raw_id(item), position), else: &1))

                {[concept | kept], drops, refs, ctx, removed + gone, MapSet.put(seen, key)}
            end

          {:drop, reason, ctx} ->
            {kept, [drop("concept", id, reason) | drops], refs, ctx, removed, seen}
        end
      end)

    {Enum.reverse(kept), Enum.reverse(drops) ++ over, refs, context, removed}
  end

  defp raw_id(%{"id" => id}) when is_binary(id) and byte_size(id) in 1..40, do: id
  defp raw_id(_), do: nil

  defp concept(item, ctx) when is_map(item) do
    with {:ok, terms} <- terms(item["terms"], 1, 8),
         {:ok, paths} <- paths(item["paths"], 1, 4),
         {:ok, tests} <- paths(Map.get(item, "tests", []), 0, 3),
         {:ok, symbols} <- symbols(Map.get(item, "symbols", [])),
         {:ok, evidence} <- evidence_list(item["evidence"]),
         :ok <- present(paths ++ tests, ctx.extract),
         {:ok, ctx} <- evidence_known(evidence, ctx),
         :ok <- concept_evidence(evidence, paths, terms, ctx.extract) do
      {kept_symbols, ctx} = existing_symbols(symbols, paths, ctx)

      {:ok,
       %{
         "terms" => terms,
         "paths" => paths,
         "symbols" => kept_symbols,
         "tests" => tests,
         "evidence" => Enum.sort(evidence),
         "support" => support(paths, terms, ctx.extract)
       }, ctx, length(symbols) - length(kept_symbols)}
    else
      {:drop, reason, ctx} -> {:drop, reason, ctx}
      {:drop, reason} -> {:drop, reason, ctx}
    end
  end

  defp concept(_, ctx), do: {:drop, "schema_invalid", ctx}

  defp terms(items, low, high) when is_list(items) do
    normalized =
      items
      |> Enum.map(fn
        term when is_binary(term) ->
          term |> String.downcase() |> String.trim() |> String.replace(~r/\s+/, " ")

        _ ->
          nil
      end)

    cond do
      Enum.any?(normalized, &(is_nil(&1) or not Regex.match?(@term, &1))) ->
        {:drop, "schema_invalid"}

      length(Enum.uniq(normalized)) not in low..high ->
        {:drop, "schema_invalid"}

      true ->
        {:ok, Enum.uniq(normalized)}
    end
  end

  defp terms(nil, 0, _), do: {:ok, []}
  defp terms(_, _, _), do: {:drop, "schema_invalid"}

  defp paths(items, low, high) when is_list(items) do
    cond do
      not Enum.all?(items, &plain_path?/1) -> {:drop, "schema_invalid"}
      length(Enum.uniq(items)) not in low..high -> {:drop, "schema_invalid"}
      true -> {:ok, Enum.uniq(items)}
    end
  end

  defp paths(_, _, _), do: {:drop, "schema_invalid"}

  @doc "The contract path rule (section 2.1): charset, relative, no `..` or `//`, no leading `-`."
  @spec plain_path?(term()) :: boolean()
  def plain_path?(path) when is_binary(path) do
    Regex.match?(@path, path) and not String.starts_with?(path, ["/", "-"]) and
      not String.contains?(path, ["..", "//"]) and Contracts.relative_path?(path)
  end

  def plain_path?(_), do: false

  defp symbols(items) when is_list(items) do
    if length(items) <= 6 and Enum.all?(items, &(is_binary(&1) and Regex.match?(@symbol, &1))),
      do: {:ok, Enum.uniq(items)},
      else: {:drop, "schema_invalid"}
  end

  defp symbols(_), do: {:drop, "schema_invalid"}

  defp evidence_list(items) when is_list(items) do
    if length(Enum.uniq(items)) in 2..5 and length(Enum.uniq(items)) == length(items) and
         Enum.all?(items, &(is_binary(&1) and Regex.match?(@hex40, &1))),
       do: {:ok, items},
       else: {:drop, "schema_invalid"}
  end

  defp evidence_list(_), do: {:drop, "schema_invalid"}

  defp present(paths, extract) do
    if Enum.all?(paths, &MapSet.member?(extract.files, &1)),
      do: :ok,
      else: {:drop, "path_missing_at_base"}
  end

  # A cited commit outside the extract is after the base when the repository holds it
  # but HEAD does not reach it; otherwise the citation is simply missing.
  defp evidence_known(evidence, ctx) do
    unknown = Enum.reject(evidence, &Map.has_key?(ctx.extract.commits, &1))

    if unknown == [] do
      {:ok, ctx}
    else
      ancestors = ctx.ancestors || Extract.ancestors(ctx.extract)
      all = ctx.all_commits || Extract.all_commits(ctx.extract)
      ctx = %{ctx | ancestors: ancestors, all_commits: all}

      after_base? =
        Enum.any?(unknown, fn hash ->
          not MapSet.member?(ancestors, hash) and MapSet.member?(all, hash)
        end)

      {:drop, if(after_base?, do: "evidence_after_base", else: "evidence_missing"), ctx}
    end
  end

  defp concept_evidence(evidence, paths, terms, extract) do
    if Enum.all?(evidence, &concept_commit?(extract.commits[&1], paths, terms)),
      do: :ok,
      else: {:drop, "evidence_mismatch"}
  end

  defp concept_commit?(commit, paths, terms) do
    Enum.any?(paths, &(&1 in commit.files)) and term_in_message?(commit, terms)
  end

  defp term_in_message?(commit, terms) do
    text = normalize_message([commit.subject | commit.body])
    Enum.any?(terms, &String.contains?(text, normalize_message([&1])))
  end

  defp normalize_message(lines) do
    lines |> Enum.join(" ") |> String.downcase() |> String.replace(~r/[_\-\s]+/, " ")
  end

  defp support(paths, terms, extract) do
    Enum.count(extract.commits, fn {_hash, commit} -> concept_commit?(commit, paths, terms) end)
  end

  defp existing_symbols(symbols, paths, ctx) do
    {texts, ctx} =
      Enum.map_reduce(paths, ctx, fn path, ctx ->
        case Map.fetch(ctx.contents, path) do
          {:ok, text} ->
            {text, ctx}

          :error ->
            text =
              case Git.show_path(ctx.extract.repo, "HEAD", path, max_bytes: 1_048_577) do
                {:ok, bytes} when byte_size(bytes) <= 1_048_576 -> bytes
                _ -> ""
              end

            {text, %{ctx | contents: Map.put(ctx.contents, path, text)}}
        end
      end)

    kept =
      Enum.filter(symbols, fn symbol ->
        last = symbol |> String.split(".") |> List.last()
        word = Regex.compile!("\\b" <> Regex.escape(last) <> "\\b")
        Enum.any?(texts, &Regex.match?(word, &1))
      end)

    {kept, ctx}
  end

  # Pitfalls

  defp check_pitfalls(items, refs, context) do
    {considered, extra} = Enum.split(items, @raw_considered["pitfalls"])

    over =
      extra
      |> Enum.with_index(@raw_considered["pitfalls"] + 1)
      |> Enum.map(fn {_, i} -> drop("pitfall", positional("p", i), "over_limit") end)

    {kept, drops, context, _seen} =
      considered
      |> Enum.with_index(1)
      |> Enum.reduce({[], [], context, MapSet.new()}, fn {item, index},
                                                         {kept, drops, ctx, seen} ->
        id = positional("p", index)

        case pitfall(item, refs, ctx) do
          {:ok, pitfall, ctx} ->
            keys = [
              {:text, String.downcase(pitfall["text"])},
              {:check, pitfall["kind"], pitfall["check"]["pattern"]}
            ]

            cond do
              Enum.any?(keys, &MapSet.member?(seen, &1)) ->
                {kept, [drop("pitfall", id, "duplicate") | drops], ctx, seen}

              length(kept) >= @limits["pitfalls"] ->
                {kept, [drop("pitfall", id, "over_limit") | drops], ctx, seen}

              true ->
                pitfall = pitfall |> Map.put(:raw_id, id) |> Map.put(:learner_id, raw_id(item))
                {[pitfall | kept], drops, ctx, Enum.reduce(keys, seen, &MapSet.put(&2, &1))}
            end

          {:drop, reason, ctx} ->
            {kept, [drop("pitfall", id, reason) | drops], ctx, seen}
        end
      end)

    {Enum.reverse(kept), Enum.reverse(drops) ++ over, context}
  end

  # A kept pitfall is named by its positional id (`p03`) or by the learner's own id.
  defp pitfall_refs(pitfalls) do
    Enum.reduce(pitfalls, %{}, fn pitfall, refs ->
      refs
      |> Map.put(pitfall.raw_id, pitfall.raw_id)
      |> then(
        &if(pitfall[:learner_id], do: Map.put(&1, pitfall[:learner_id], pitfall.raw_id), else: &1)
      )
    end)
  end

  defp pitfall(item, refs, ctx) when is_map(item) do
    check = item["check"]

    with {:ok, scope, concept} <- scope(item, refs),
         true <- item["kind"] in @pitfall_kinds || {:drop, "schema_invalid"},
         text when is_binary(text) <- item["text"] || {:drop, "schema_invalid"},
         text = String.trim(text),
         true <- safe_text?(text) || {:drop, "text_unsafe"},
         true <- not example_copy?(text) || {:drop, "example_copy"},
         {:ok, triggers} <- terms(Map.get(item, "trigger_terms", []), 0, 6),
         {:ok, evidence} <- evidence_list(item["evidence"]),
         true <- (scope == "concept" or length(evidence) >= 3) || {:drop, "evidence_missing"},
         {:ok, pattern, min} <- check(check, length(evidence)),
         {:ok, ctx} <- evidence_known(evidence, ctx),
         :ok <- pattern_evidence(pattern, min, evidence, ctx.extract),
         {:ok, ctx} <- specific_pattern(item["kind"], pattern, ctx) do
      {:ok,
       %{
         "scope" => scope,
         :concept_ref => concept,
         "kind" => item["kind"],
         "text" => text,
         "trigger_terms" => triggers,
         "evidence" => Enum.sort(evidence),
         "check" => %{"type" => "diff_regex", "pattern" => pattern, "min_commits" => min},
         "status" => "verified"
       }, ctx}
    else
      {:drop, reason, ctx} -> {:drop, reason, ctx}
      {:drop, reason} -> {:drop, reason, ctx}
      _ -> {:drop, "schema_invalid", ctx}
    end
  end

  defp pitfall(_, _, ctx), do: {:drop, "schema_invalid", ctx}

  defp scope(%{"scope" => "global"} = item, _refs) do
    if is_nil(Map.get(item, "concept")), do: {:ok, "global", nil}, else: {:drop, "schema_invalid"}
  end

  defp scope(%{"scope" => "concept", "concept" => ref}, refs) when is_binary(ref) do
    case Map.fetch(refs, ref) do
      {:ok, position} -> {:ok, "concept", position}
      :error -> {:drop, "schema_invalid"}
    end
  end

  defp scope(_, _), do: {:drop, "schema_invalid"}

  defp check(%{"pattern" => pattern} = check, evidence_count) do
    min = Map.get(check, "min_commits", 2)

    cond do
      Map.get(check, "type", "diff_regex") != "diff_regex" -> {:drop, "schema_invalid"}
      not is_integer(min) or min not in 2..5 or min > evidence_count -> {:drop, "schema_invalid"}
      not safe_pattern?(pattern) -> {:drop, "schema_invalid"}
      true -> {:ok, pattern, min}
    end
  end

  defp check(_, _), do: {:drop, "schema_invalid"}

  defp pattern_evidence(pattern, min, evidence, extract) do
    regex = Regex.compile!(pattern)

    matching =
      Enum.count(evidence, fn hash ->
        extract |> Extract.changed_lines(hash) |> Enum.any?(&Regex.match?(regex, &1))
      end)

    if matching >= min, do: :ok, else: {:drop, "evidence_mismatch"}
  end

  defp specific_pattern("changelog", _pattern, ctx), do: {:ok, ctx}

  defp specific_pattern(_kind, pattern, ctx) do
    {fixes, ctx} = fix_lines(ctx)
    regex = Regex.compile!(pattern)
    hits = Enum.count(fixes, fn lines -> Enum.any?(lines, &Regex.match?(regex, &1)) end)

    if fixes != [] and hits * 100 > @common_pattern_percent * length(fixes),
      do: {:drop, "pattern_too_common", ctx},
      else: {:ok, ctx}
  end

  # Changed lines of every fix commit in the extract, computed once per raw output.
  defp fix_lines(%{fix_lines: nil} = ctx) do
    lines =
      for %{"hash" => hash} <- ctx.extract.doc["fix_diffs"] || [],
          do: Extract.changed_lines(ctx.extract, hash)

    {lines, %{ctx | fix_lines: lines}}
  end

  defp fix_lines(ctx), do: {ctx.fix_lines, ctx}

  defp example_copy?(text), do: normalize_text(text) in @example_texts

  defp normalize_text(text),
    do: text |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, " ") |> String.trim()

  @doc """
  After verification: pitfalls whose text names a tool that a kept `missing_tool`
  rewrite proved is not installed here are dropped with `tool_missing` (a line that
  says "run mypy" where mypy is missing invites a wasted request). Returns
  `{kept, dropped}`.
  """
  @spec drop_missing_tool_pitfalls([map()], [map()]) :: {[map()], [map()]}
  def drop_missing_tool_pitfalls(pitfalls, rewrites) do
    tools =
      for %{kind: "missing_tool", replace: {:message, tool}} <- rewrites, uniq: true, do: tool

    {named, kept} = Enum.split_with(pitfalls, &names_tool?(&1["text"], tools))
    {kept, Enum.map(named, &drop("pitfall", &1.raw_id, "tool_missing"))}
  end

  defp names_tool?(_text, []), do: false

  defp names_tool?(text, tools) do
    Enum.any?(tools, fn tool ->
      Regex.match?(~r/(?<![A-Za-z0-9_.-])#{Regex.escape(tool)}(?![A-Za-z0-9_-])/i, text)
    end)
  end

  # Commands and rewrites (candidates; verification decides)

  defp check_commands(items) do
    {considered, extra} = Enum.split(items, @raw_considered["commands"])

    over =
      extra
      |> Enum.with_index(@raw_considered["commands"] + 1)
      |> Enum.map(fn {item, i} -> drop("command", learned_command_id(item, i), "over_limit") end)

    {kept, drops} =
      considered
      |> Enum.with_index(1)
      |> Enum.reduce({[], []}, fn {item, index}, {kept, drops} ->
        id = learned_command_id(item, index)

        case command(item) do
          {:ok, role, argv} ->
            {[%{key: id, source: "learned", role: role, argv: argv} | kept], drops}

          {:drop, reason} ->
            {kept, [drop("command", id, reason) | drops]}
        end
      end)

    {Enum.reverse(kept), Enum.reverse(drops) ++ over}
  end

  defp learned_command_id(%{"role" => role}, index) when role in @roles,
    do: "cmd-" <> String.replace(role, "_", "-") <> "-l#{index}"

  defp learned_command_id(_, index), do: "cmd-l#{index}"

  defp command(%{"role" => role, "argv" => argv}) when role in @roles and is_list(argv) do
    words = Enum.reject(argv, &(&1 == "{file}"))
    files = length(argv) - length(words)

    cond do
      length(argv) not in 1..16 or not Enum.all?(argv, &is_binary/1) -> {:drop, "schema_invalid"}
      files > 1 or (role == "test_file" and files != 1) -> {:drop, "schema_invalid"}
      hd(argv) == "{file}" -> {:drop, "unsafe_argv"}
      not safe_argv?(words) -> {:drop, "unsafe_argv"}
      true -> {:ok, role, argv}
    end
  end

  defp command(_), do: {:drop, "schema_invalid"}

  defp check_rewrites(items) do
    {considered, extra} = Enum.split(items, @raw_considered["rewrites"])

    over =
      extra
      |> Enum.with_index(@raw_considered["rewrites"] + 1)
      |> Enum.map(fn {_, i} -> drop("rewrite", "rw-l#{i}", "over_limit") end)

    {kept, drops} =
      considered
      |> Enum.with_index(1)
      |> Enum.reduce({[], []}, fn {item, index}, {kept, drops} ->
        id = "rw-l#{index}"

        case rewrite(item) do
          {:ok, rewrite} -> {[Map.merge(rewrite, %{key: id, source: "learned"}) | kept], drops}
          {:drop, reason} -> {kept, [drop("rewrite", id, reason) | drops]}
        end
      end)

    {Enum.reverse(kept), Enum.reverse(drops) ++ over}
  end

  defp rewrite(%{"kind" => kind, "match" => %{"argv_prefix" => match}, "replace" => replace})
       when kind in @rewrite_kinds and is_list(match) and is_map(replace) do
    cond do
      length(match) not in 1..6 or not Enum.all?(match, &is_binary/1) ->
        {:drop, "schema_invalid"}

      not safe_argv?(match) ->
        {:drop, "unsafe_argv"}

      true ->
        rewrite_replacement(kind, match, replace)
    end
  end

  defp rewrite(_), do: {:drop, "schema_invalid"}

  defp rewrite_replacement("missing_tool", match, %{
         "message_id" => "tool_missing",
         "tool" => tool
       })
       when is_binary(tool) do
    if Regex.match?(@tool, tool) and tool in match,
      do: {:ok, %{kind: "missing_tool", match: match, replace: {:message, tool}}},
      else: {:drop, "schema_invalid"}
  end

  defp rewrite_replacement(kind, match, %{"argv_prefix" => replace})
       when kind in ~w(wrong_runner quiet_flags) and is_list(replace) do
    cond do
      length(replace) not in 1..10 or not Enum.all?(replace, &is_binary/1) ->
        {:drop, "schema_invalid"}

      not safe_argv?(replace) ->
        {:drop, "unsafe_argv"}

      replace == match ->
        {:drop, "schema_invalid"}

      kind == "quiet_flags" and quiet_flags?(match, replace) ->
        {:ok, %{kind: kind, match: match, replace: {:argv, replace}}}

      kind == "wrong_runner" and List.last(match) in replace ->
        {:ok, %{kind: kind, match: match, replace: {:argv, replace}}}

      true ->
        {:drop, "schema_invalid"}
    end
  end

  defp rewrite_replacement(_, _, _), do: {:drop, "schema_invalid"}

  @doc """
  True when `replace` is `match` plus output flags only: `-q`, `-qq`, `--quiet`,
  `--no-header`, `--tb=short`, `--tb=line`, `--silent`, `--reporter dot|min` (or
  `--reporter=dot|min`), and `-s` or `--` after npm, pnpm or yarn. Flags that change
  what runs (`-p no:cacheprovider`, `-x`, `-k`) are refused.
  """
  @spec quiet_flags?([String.t()], [String.t()]) :: boolean()
  def quiet_flags?([first | _] = match, replace) when is_list(replace) do
    List.starts_with?(replace, match) and length(replace) > length(match) and
      quiet_extra?(first in @npm_like, Enum.drop(replace, length(match)))
  end

  def quiet_flags?(_, _), do: false

  defp quiet_extra?(_npm?, []), do: true

  defp quiet_extra?(npm?, ["--reporter", reporter | rest]) when reporter in @quiet_reporters,
    do: quiet_extra?(npm?, rest)

  defp quiet_extra?(true, [word | rest]) when word in ["-s", "--"], do: quiet_extra?(true, rest)
  defp quiet_extra?(npm?, [word | rest]) when word in @quiet_words, do: quiet_extra?(npm?, rest)
  defp quiet_extra?(_npm?, _words), do: false

  # Skills and agents (data only; text comes from fixed templates at generation) ----------

  defp check_skills(items, concept_refs, pitfall_refs, context) do
    {considered, extra} = Enum.split(items, @raw_considered["skills"])

    over =
      extra
      |> Enum.with_index(@raw_considered["skills"] + 1)
      |> Enum.map(fn {_, i} -> drop("skill", positional("s", i), "over_limit") end)

    {kept, drops, context, removed, _seen} =
      considered
      |> Enum.with_index(1)
      |> Enum.reduce({[], [], context, 0, MapSet.new()}, fn {item, index},
                                                            {kept, drops, ctx, removed, seen} ->
        id = positional("s", index)

        case skill(item, concept_refs, pitfall_refs, ctx) do
          {:ok, skill, ctx, gone} ->
            keys = [{:slug, skill["slug"]}, {:paths, Enum.sort(skill["paths"])}]

            cond do
              Enum.any?(keys, &MapSet.member?(seen, &1)) ->
                {kept, [drop("skill", id, "duplicate") | drops], ctx, removed, seen}

              length(kept) >= @limits["skills"] ->
                {kept, [drop("skill", id, "over_limit") | drops], ctx, removed, seen}

              true ->
                {[Map.put(skill, :raw_id, id) | kept], drops, ctx, removed + gone,
                 Enum.reduce(keys, seen, &MapSet.put(&2, &1))}
            end

          {:drop, reason, ctx} ->
            {kept, [drop("skill", id, reason) | drops], ctx, removed, seen}
        end
      end)

    {Enum.reverse(kept), Enum.reverse(drops) ++ over, context, removed}
  end

  defp skill(item, concept_refs, pitfall_refs, ctx) when is_map(item) do
    with true <- item["kind"] == "area" || {:drop, "schema_invalid"},
         {:ok, concept} <- reference(item["concept"], concept_refs),
         {:ok, slug} <- slug(item["slug"]),
         {:ok, paths} <- paths(item["paths"], 2, 6),
         {:ok, tests} <- paths(Map.get(item, "tests", []), 0, 4),
         {:ok, symbols} <- symbols(Map.get(item, "symbols", [])),
         {:ok, pitfalls} <- references(Map.get(item, "pitfalls", []), pitfall_refs, 2),
         {:ok, evidence} <- evidence_list(item["evidence"]),
         :ok <- present(paths ++ tests, ctx.extract),
         {:ok, ctx} <- evidence_known(evidence, ctx),
         :ok <- touches(evidence, paths ++ tests, ctx.extract) do
      kept_symbols = extract_symbols(symbols, paths, ctx.extract)

      {:ok,
       %{
         "kind" => "area",
         :concept_ref => concept,
         :pitfall_refs => pitfalls,
         "slug" => slug,
         "paths" => paths,
         "tests" => tests,
         "symbols" => kept_symbols,
         "evidence" => Enum.sort(evidence)
       }, ctx, length(symbols) - length(kept_symbols)}
    else
      {:drop, reason, ctx} -> {:drop, reason, ctx}
      {:drop, reason} -> {:drop, reason, ctx}
    end
  end

  defp skill(_, _, _, ctx), do: {:drop, "schema_invalid", ctx}

  defp reference(ref, refs) when is_binary(ref) do
    case Map.fetch(refs, ref) do
      {:ok, target} -> {:ok, target}
      :error -> {:drop, "schema_invalid"}
    end
  end

  defp reference(_, _), do: {:drop, "schema_invalid"}

  defp references(items, refs, max) when is_list(items) and length(items) <= max do
    Enum.reduce_while(items, {:ok, []}, fn ref, {:ok, acc} ->
      case reference(ref, refs) do
        {:ok, target} -> {:cont, {:ok, acc ++ [target]}}
        drop -> {:halt, drop}
      end
    end)
    |> case do
      {:ok, targets} -> {:ok, Enum.uniq(targets)}
      drop -> drop
    end
  end

  defp references(_, _, _), do: {:drop, "schema_invalid"}

  defp slug(slug) when is_binary(slug) do
    if byte_size(slug) in 1..24 and Regex.match?(@slug, slug),
      do: {:ok, slug},
      else: {:drop, "schema_invalid"}
  end

  defp slug(_), do: {:drop, "schema_invalid"}

  # Each cited commit changes at least one listed path.
  defp touches(evidence, paths, extract) do
    if Enum.all?(evidence, fn hash -> Enum.any?(paths, &(&1 in extract.commits[hash].files)) end),
      do: :ok,
      else: {:drop, "evidence_mismatch"}
  end

  # Symbol names the extract's `facts.symbols` lists in one of the paths; others are left
  # out and counted in the run report (`skill_symbols_removed`).
  defp extract_symbols(symbols, paths, extract) do
    known =
      for %{"name" => name, "path" => path} <- get_in(extract.doc, ["facts", "symbols"]) || [],
          path in paths,
          into: MapSet.new(),
          do: name

    Enum.filter(symbols, &MapSet.member?(known, &1))
  end

  defp check_agents(items, context) do
    {considered, extra} = Enum.split(items, @raw_considered["agents"])

    over =
      extra
      |> Enum.with_index(@raw_considered["agents"] + 1)
      |> Enum.map(fn {_, i} -> drop("agent", positional("a", i), "over_limit") end)

    {kept, drops, context, _seen} =
      considered
      |> Enum.with_index(1)
      |> Enum.reduce({[], [], context, MapSet.new()}, fn {item, index},
                                                         {kept, drops, ctx, seen} ->
        id = positional("a", index)

        case agent(item, ctx) do
          {:ok, agent, ctx} ->
            key = {agent["kind"], Enum.sort(agent["paths"]), agent["commands"]}

            if MapSet.member?(seen, key),
              do: {kept, [drop("agent", id, "duplicate") | drops], ctx, seen},
              else: {[Map.put(agent, :raw_id, id) | kept], drops, ctx, MapSet.put(seen, key)}

          {:drop, reason, ctx} ->
            {kept, [drop("agent", id, reason) | drops], ctx, seen}
        end
      end)

    {Enum.reverse(kept), Enum.reverse(drops) ++ over, context}
  end

  defp agent(item, ctx) when is_map(item) do
    with true <- item["kind"] in @agent_kinds || {:drop, "schema_invalid"},
         {:ok, paths} <- paths(item["paths"], 1, 8),
         {:ok, commands} <- command_ids(item["kind"], Map.get(item, "commands", [])),
         {:ok, evidence} <- evidence_list(item["evidence"]),
         :ok <- present(paths, ctx.extract),
         {:ok, ctx} <- evidence_known(evidence, ctx),
         :ok <- touches(evidence, paths, ctx.extract) do
      {:ok,
       %{
         "kind" => item["kind"],
         "paths" => paths,
         "commands" => commands,
         "evidence" => Enum.sort(evidence)
       }, ctx}
    else
      {:drop, reason, ctx} -> {:drop, reason, ctx}
      {:drop, reason} -> {:drop, reason, ctx}
    end
  end

  defp agent(_, ctx), do: {:drop, "schema_invalid", ctx}

  # A locator runs nothing; a test_runner names 1 to 4 command ids, resolved after
  # verification (`resolve_agents/2`).
  defp command_ids("locator", []), do: {:ok, []}

  defp command_ids("test_runner", ids) when is_list(ids) do
    if length(ids) in 1..4 and length(Enum.uniq(ids)) == length(ids) and
         Enum.all?(ids, &(is_binary(&1) and Regex.match?(@command_id, &1))),
       do: {:ok, Enum.sort(ids)},
       else: {:drop, "schema_invalid"}
  end

  defp command_ids(_, _), do: {:drop, "schema_invalid"}

  @doc """
  After verification: an agent keeps its place only when every command id it names is
  the id (`cmd-<role>`) of a verified command (`not_verified` otherwise); a test_runner
  may name only the suite and one-file commands (`schema_invalid` otherwise); the first
  agent of each kind is kept and later ones are `over_limit`. Returns `{kept, dropped}`.
  """
  @spec resolve_agents([map()], [map()]) :: {[map()], [map()]}
  def resolve_agents(agents, verified_commands) do
    verified = MapSet.new(verified_commands, &("cmd-" <> String.replace(&1.role, "_", "-")))

    {kept, drops, _kinds} =
      Enum.reduce(agents, {[], [], MapSet.new()}, fn agent, {kept, drops, kinds} ->
        cond do
          not Enum.all?(agent["commands"], &MapSet.member?(verified, &1)) ->
            {kept, [drop("agent", agent.raw_id, "not_verified") | drops], kinds}

          agent["kind"] == "test_runner" and
              not Enum.all?(agent["commands"], &(&1 in @runner_command_ids)) ->
            {kept, [drop("agent", agent.raw_id, "schema_invalid") | drops], kinds}

          MapSet.member?(kinds, agent["kind"]) or length(kept) >= @limits["agents"] ->
            {kept, [drop("agent", agent.raw_id, "over_limit") | drops], kinds}

          true ->
            {[agent | kept], drops, MapSet.put(kinds, agent["kind"])}
        end
      end)

    {Enum.reverse(kept), Enum.reverse(drops)}
  end

  # Deterministic candidates ---------------------------------------------------------------

  @doc """
  Command candidates from the existing analyzer (`facts.analyzer.commands`): test, a
  per-file test command, lint, a format check and typecheck, as argv words with `{file}`
  where the tool takes a path. Returns `{candidates, dropped}`.
  """
  @spec deterministic_commands(map()) :: {[map()], [map()]}
  def deterministic_commands(extract_doc) do
    commands = get_in(extract_doc, ["facts", "analyzer", "commands"]) || %{}

    [
      {"test", commands["test"]},
      {"test_file", commands["test"]},
      {"lint", commands["lint"]},
      {"format", commands["format"]},
      {"typecheck", commands["typecheck"]}
    ]
    |> Enum.reduce({[], []}, fn
      {_role, nil}, acc ->
        acc

      {role, text}, {kept, drops} ->
        id = "cmd-" <> String.replace(role, "_", "-") <> "-d"

        case deterministic_argv(role, String.split(text, " ", trim: true)) do
          nil ->
            {kept, drops}

          argv ->
            words = Enum.reject(argv, &(&1 == "{file}"))

            if safe_argv?(words),
              do: {[%{key: id, source: "deterministic", role: role, argv: argv} | kept], drops},
              else: {kept, [drop("command", id, "unsafe_argv") | drops]}
        end
    end)
    |> then(fn {kept, drops} -> {Enum.reverse(kept), Enum.reverse(drops)} end)
  end

  defp deterministic_argv("test", argv), do: argv

  defp deterministic_argv("test_file", argv) do
    cond do
      Enum.any?(argv, &(&1 in ~w(-k -m))) ->
        nil

      match?(["npm", "test" | _], argv) or match?(["npm", "run", "test" | _], argv) ->
        argv ++ ["--", "{file}"]

      Enum.any?(argv, &(&1 in @test_tools)) ->
        argv ++ ["{file}"]

      true ->
        nil
    end
  end

  defp deterministic_argv("format", argv) do
    checked =
      cond do
        Enum.any?(argv, &(&1 in ~w(--check --check-only --diff -l))) -> argv
        "--write" in argv -> Enum.map(argv, &if(&1 == "--write", do: "--check", else: &1))
        List.last(argv) in ~w(black isort) -> argv ++ ["--check"]
        Enum.take(argv, -2) == ["ruff", "format"] -> argv ++ ["--check"]
        Enum.take(argv, -2) == ["cargo", "fmt"] -> argv ++ ["--check"]
        true -> nil
      end

    checked && with_file(checked)
  end

  defp deterministic_argv(role, argv) when role in ~w(lint typecheck), do: with_file(argv)

  defp with_file(argv) do
    if Enum.any?(argv, &(&1 in @file_tools)), do: argv ++ ["{file}"], else: argv
  end

  @doc """
  Tools the analyzer names, for the environment probe: `{tool, prefix}` where prefix is
  the runner the analyzer uses for it (for example `["uv", "run"]`) or `[]`.
  """
  @spec named_tools(map()) :: [{String.t(), [String.t()]}]
  def named_tools(extract_doc) do
    analyzer = get_in(extract_doc, ["facts", "analyzer"]) || %{}
    pyproject = get_in(extract_doc, ["facts", "pyproject_tools"]) || []
    managers = analyzer["package_managers"] || []

    from_tools =
      for tool <- analyzer["tools"] || [],
          is_map(tool),
          command = tool["command"],
          is_binary(command),
          probe <- tool["probe"] || [],
          is_binary(probe),
          words = String.split(command, " ", trim: true),
          probe in words do
        {probe, Enum.take_while(words, &(&1 != probe))}
      end

    runner = if "uv" in managers, do: ["uv", "run"], else: []

    python_tools =
      for tool <- pyproject,
          tool in ~w(mypy pyright ruff black isort flake8 pylint pytest),
          do: {tool, runner}

    (from_tools ++ python_tools)
    |> Enum.filter(fn {tool, prefix} ->
      Regex.match?(@tool, tool) and tool in @programs and safe_words?(prefix ++ [tool])
    end)
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.sort()
  end

  @doc "Deterministic sample files for `{file}`: a test file and a source file at the base."
  @spec samples(Extract.t()) :: %{test: String.t(), source: String.t()}
  def samples(extract) do
    analyzer = get_in(extract.doc, ["facts", "analyzer"]) || %{}
    present? = &(MapSet.member?(extract.files, &1) and plain_path?(&1))

    test =
      (analyzer["test_pairs"] || [])
      |> Enum.filter(&is_map/1)
      |> Enum.sort_by(&{-(&1["support"] || 0), &1["test"] || ""})
      |> Enum.map(& &1["test"])
      |> Enum.find(fn path -> is_binary(path) and present?.(path) and test_module?(path) end)
      |> Kernel.||(
        extract.files
        |> Enum.sort()
        |> Enum.find(&(present?.(&1) and test_module?(&1)))
      )
      # Test files without a test_ or .spec name (`test/res.send.js`): any code file in
      # a test tree outside helper directories.
      |> Kernel.||(
        extract.files
        |> Enum.sort()
        |> Enum.find(&(present?.(&1) and plain_test_file?(&1)))
      )

    source =
      (analyzer["hot_files"] || [])
      |> Enum.map(& &1["path"])
      |> Enum.find(fn path ->
        is_binary(path) and present?.(path) and Paths.source_path?(path)
      end)
      |> Kernel.||(
        extract.files
        |> Enum.sort()
        |> Enum.find(&(present?.(&1) and Paths.source_path?(&1)))
      )

    %{test: test || "", source: source || ""}
  end

  defp plain_test_file?(path) do
    name = Path.basename(path)

    Paths.test_path?(path) and Paths.code_path?(path) and
      not Enum.any?(Path.split(Path.dirname(path)), &(&1 in @non_test_dirs)) and
      not String.starts_with?(name, ["_", "."]) and
      Path.rootname(name) not in ~w(conftest index setup helpers helper env common mocha)
  end

  defp test_module?(path) do
    name = Path.basename(path)

    Paths.test_path?(path) and Paths.code_path?(path) and
      Regex.match?(~r/\A(?:test_.+|.+_test|.+\.test|.+\.spec|.+_spec)\.[a-z]+\z/, name)
  end

  @doc "True for match prefixes whose sample argument is a test file rather than a source file."
  @spec test_like?([String.t()]) :: boolean()
  def test_like?(words), do: Enum.any?(words, &(&1 in @test_tools))

  # Finalize ------------------------------------------------------------------------------

  @doc """
  Assemble the finalized document from its parts:

    * `:repository`, `:input`, `:learner`, `:verification` (maps in final shape);
    * `:concepts`, `:pitfalls` (kept, from `check_raw/2`);
    * `:commands`, `:rewrites` (verified, see `HarnessForge.Learning.Verify`);
    * `:skills`, `:agents` (optional; kept by `check_raw/2` and `resolve_agents/2`);
    * `:dropped` (rows).

  Ids are reassigned in content order; measurements are bucketed. `skills` and `agents`
  are always written (empty lists when there are none). A skill's reference to a
  pitfall that verification dropped afterwards (`tool_missing`) is removed with it.
  """
  @spec finalize(map()) :: map()
  def finalize(parts) do
    {concepts, concept_ids} = finalize_concepts(parts.concepts)
    {pitfalls, pitfall_ids} = finalize_pitfalls(parts.pitfalls, concept_ids)

    dropped =
      parts.dropped
      |> Enum.uniq()
      |> Enum.sort_by(&{&1["kind"], &1["id"], &1["reason"]})
      |> Enum.uniq_by(&{&1["kind"], &1["id"]})
      |> Enum.take(@dropped_limit)

    doc = %{
      "schema" => "olivium.learned/v1",
      "repository" => parts.repository,
      "input" => parts.input,
      "learner" => parts.learner,
      "verification" => parts.verification,
      "concepts" => concepts,
      "pitfalls" => pitfalls,
      "commands" => finalize_commands(parts.commands),
      "rewrites" => finalize_rewrites(parts.rewrites),
      "skills" => finalize_skills(Map.get(parts, :skills, []), concept_ids, pitfall_ids),
      "agents" => finalize_agents(Map.get(parts, :agents, [])),
      "dropped" => dropped
    }

    Map.put(doc, "sha256", Contracts.digest(doc))
  end

  defp finalize_concepts(concepts) do
    ordered =
      Enum.sort_by(concepts, fn concept ->
        {Enum.join(concept["paths"], "\n"), Enum.join(concept["terms"], "\n"),
         Enum.join(concept["evidence"], "\n")}
      end)

    ids =
      ordered
      |> Enum.with_index(1)
      |> Map.new(fn {concept, index} -> {concept[:ref], positional("c", index)} end)

    final =
      ordered
      |> Enum.with_index(1)
      |> Enum.map(fn {concept, index} ->
        concept |> Map.delete(:ref) |> Map.put("id", positional("c", index))
      end)

    {final, ids}
  end

  defp finalize_pitfalls(pitfalls, concept_ids) do
    ordered =
      pitfalls
      |> Enum.map(fn pitfall ->
        concept = if pitfall[:concept_ref], do: Map.fetch!(concept_ids, pitfall[:concept_ref])
        pitfall |> Map.drop([:concept_ref, :learner_id]) |> Map.put("concept", concept)
      end)
      |> Enum.sort_by(&{&1["scope"], &1["concept"] || "", &1["kind"], &1["text"]})
      |> Enum.with_index(1)

    ids = Map.new(ordered, fn {pitfall, index} -> {pitfall[:raw_id], positional("p", index)} end)

    final =
      Enum.map(ordered, fn {pitfall, index} ->
        pitfall |> Map.delete(:raw_id) |> Map.put("id", positional("p", index))
      end)

    {final, ids}
  end

  defp finalize_skills(skills, concept_ids, pitfall_ids) do
    skills
    |> Enum.map(fn skill ->
      %{
        "kind" => skill["kind"],
        "concept" => Map.fetch!(concept_ids, skill[:concept_ref]),
        "slug" => skill["slug"],
        "paths" => skill["paths"],
        "tests" => skill["tests"],
        "symbols" => skill["symbols"],
        "pitfalls" =>
          skill[:pitfall_refs]
          |> Enum.flat_map(&List.wrap(Map.get(pitfall_ids, &1)))
          |> Enum.sort(),
        "evidence" => skill["evidence"]
      }
    end)
    |> Enum.sort_by(&{&1["slug"], Enum.join(&1["paths"], "\n"), Enum.join(&1["evidence"], "\n")})
    |> Enum.with_index(1)
    |> Enum.map(fn {skill, index} -> Map.put(skill, "id", positional("s", index)) end)
  end

  defp finalize_agents(agents) do
    agents
    |> Enum.map(&Map.take(&1, ~w(kind paths commands evidence)))
    |> Enum.sort_by(&{&1["kind"], Enum.join(&1["paths"], "\n"), Enum.join(&1["evidence"], "\n")})
    |> Enum.with_index(1)
    |> Enum.map(fn {agent, index} -> Map.put(agent, "id", positional("a", index)) end)
  end

  defp finalize_commands(commands) do
    commands
    |> Enum.map(fn command ->
      %{
        "id" => "cmd-" <> String.replace(command.role, "_", "-"),
        "source" => command.source,
        "role" => command.role,
        "argv" => command.argv,
        "verify" => %{
          "status" => "verified",
          "exit" => command.verify.exit,
          "ms" => @verify_ms,
          "output_bytes" => bucket_bytes(command.verify.output_bytes),
          "sample_arg" => command.verify.sample_arg
        }
      }
    end)
    |> Enum.sort_by(& &1["id"])
  end

  defp finalize_rewrites(rewrites) do
    rewrites
    |> Enum.sort_by(fn rewrite ->
      {rewrite.kind, Enum.join(rewrite.match, " "), replace_key(rewrite.replace)}
    end)
    |> Enum.with_index(1)
    |> Enum.map(fn {rewrite, index} ->
      %{
        "id" => positional("rw", index),
        "source" => rewrite.source,
        "kind" => rewrite.kind,
        "match" => %{"argv_prefix" => rewrite.match},
        "replace" =>
          case rewrite.replace do
            {:argv, words} -> %{"argv_prefix" => words}
            {:message, tool} -> %{"message_id" => "tool_missing", "tool" => tool}
          end,
        "verify" => %{
          "wrong_exit" => rewrite.verify.wrong_exit,
          "wrong_signature" => rewrite.verify.wrong_signature,
          "right_exit" => rewrite.verify.right_exit,
          "ms" => @verify_ms,
          "bytes_before" => bucket_bytes(rewrite.verify.bytes_before),
          "bytes_after" => bucket_bytes(rewrite.verify.bytes_after)
        }
      }
    end)
  end

  defp replace_key({:argv, words}), do: Enum.join(words, " ")
  defp replace_key({:message, tool}), do: "message " <> tool

  @doc """
  Sizes are recorded as the next power of two (0 stays 0), so `a * 2 <= b` on exact values
  still holds on the buckets and small differences (a test's timing line) do not change
  the bundle.
  """
  @spec bucket_bytes(non_neg_integer()) :: non_neg_integer()
  def bucket_bytes(0), do: 0
  def bucket_bytes(n) when is_integer(n) and n > 0, do: next_power(1, n)

  defp next_power(p, n) when p >= n, do: p
  defp next_power(p, n), do: next_power(p * 2, n)

  @doc "Live learner wall time is recorded rounded up to whole 10 s steps (0 stays 0)."
  @spec bucket_ms(non_neg_integer()) :: non_neg_integer()
  def bucket_ms(0), do: 0
  def bucket_ms(ms) when is_integer(ms) and ms > 0, do: div(ms + 9_999, 10_000) * 10_000

  defp invalid(details) do
    {:error,
     %Error{
       code: "learned_invalid",
       message: "The learned bundle failed validation",
       details: details |> Enum.sort() |> Enum.take(100)
     }}
  end
end
