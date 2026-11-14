defmodule HarnessForge.Generation.Guidance do
  @moduledoc """
  Renders the root guidance file (`CLAUDE.md`) from a v1alpha2 spec, lean.

  Every model-visible byte here is sent with every model request, so a line enters
  the file only if it passes the inclusion test in `HarnessForge.Generation.Economy`
  and fits the budget. Nothing is withheld silently: every line left out is reported,
  with its reason code, in `.olivium/guidance-provenance.json`.

  The file is a header in an HTML comment (Claude Code strips HTML comments before
  the model sees the file, so it costs nothing) followed by the kept lines as one
  flat list. There is no title and there are no section headings: they would cost
  bytes on every request and tell the agent nothing. When no line survives, the file
  holds only the comment and adds nothing to any request. The comment carries only
  fixed text and paths checked against a strict character set, never repository
  prose, so it cannot close itself early.

  Truncation is deterministic. Kept lines are considered by tier: the generator's
  fixed sentences, then a non-default test command, practice rules and the measured
  changelog rule (practice rules first, as the spec lists them first), conventions,
  other rules in spec order (the generator orders them by confidence), then any other
  section. A line that does not fit is withheld as `over_budget` and
  later, shorter lines are still considered. A line with an `@` is withheld as
  `import_marker` unless every `@` sits inside a code span of a well-formed line,
  because Claude Code would treat it as a file import.

  `lean-ai`: when the learned bundle (`spec.learned`) shows that the analyzer's test
  command does not work in the verification image, its `Test:` or `Test one:` line is
  withheld as `tool_unverified`. That is the case when the bundle dropped `cmd-test-d`
  or `cmd-test-file-d` with reason `tool_missing` (exit 127, module not found or spawn
  failed) or `not_verified` (verification ran but found nothing to check it on), or
  with reason `verify_failed` while the bundle kept a verified command for the same
  role (so the role's tests do run here, just not with that command). A command that
  is known not to work here would only cost the agent a request. A `verify_failed`
  with no verified alternative keeps the line: the suite may simply fail at the base.

  `lean-ai` also leaves out the fixed sentences the blueprint lists in
  `guidance.lean_ai_left_out` (the lint-and-format sentence and its lint-only and
  format-only forms), withheld as `process_only`: the stop hook runs lint and format
  whether or not the file says so, and the sentence would cost about 35 tokens on every
  request. The bytes a left-out sentence would have taken are not given to other
  lines: the budget shrinks by them (the report's `budget_bytes` says by how much), so
  the `lean-ai` file is the file with the sentence, minus that one line. `lean` and
  `standard` keep the sentence and the full budget.
  """

  alias HarnessForge.Generation.Economy

  @header "<!-- Olivium Harness. Lines left out of this file, and why: .olivium/guidance-provenance.json -->\n"
  @display ~w(commands project-map conventions rules do-dont architecture review-checklist notes)
  # Dropped deterministic command ids of a learned bundle: the command line each one is,
  # and the role a kept verified command must have for a `verify_failed` drop to count.
  @unrunnable_lines %{
    "cmd-test-d" => {"Test: `", "test"},
    "cmd-test-file-d" => {"Test one: `", "test_file"}
  }

  @spec budget_bytes() :: pos_integer()
  def budget_bytes, do: Economy.budget_bytes()

  @doc """
  Returns `{markdown, report}`. The report is the provenance document: `budget_bytes`
  (600, less what left-out `lean-ai` sentences would have taken),
  `rendered_bytes` (model-visible bytes), `est_tokens_per_request`, `kept_lines`,
  `withheld[{section, text, bytes, reason}]` and `withheld_counts`.
  """
  @spec render(map()) :: {binary(), map()}
  def render(%{"spec" => spec}) do
    tables = Economy.tables(spec["project"] || %{})
    items = items(spec, tables)
    unrunnable = unrunnable_prefixes(spec["learned"])
    left_out = left_out_fixed(spec, tables)
    in_skill = skill_files(spec["native"])

    {candidates, unsafe} = Enum.split_with(items, &import_safe?(&1.text))
    {candidates, subjectless} = Enum.split_with(candidates, &(not no_subject?(&1)))

    {keep, withheld} =
      Enum.reduce(candidates, {[], []}, fn item, {keep, withheld} ->
        case classify(item, tables, unrunnable, left_out, in_skill) do
          :keep -> {[item | keep], withheld}
          {:withhold, reason} -> {keep, [Map.put(item, :reason, reason) | withheld]}
        end
      end)

    header = @header <> policy_comment(withheld)
    budget = Economy.budget_bytes() - left_out_bytes(withheld, left_out, byte_size(header))

    {kept, over_budget, duplicates} =
      keep
      |> Enum.sort_by(&{&1.tier, &1.rank, &1.order})
      |> select(byte_size(header), budget)

    body = body(kept)
    markdown = header <> body

    withheld =
      Enum.map(unsafe, &Map.put(&1, :reason, "import_marker")) ++
        Enum.map(subjectless, &Map.put(&1, :reason, "no_subject")) ++
        withheld ++
        Enum.map(over_budget, &Map.put(&1, :reason, "over_budget")) ++
        Enum.map(duplicates, &Map.put(&1, :reason, "duplicate"))

    {markdown, Economy.report(withheld, byte_size(body), length(kept), budget)}
  end

  # The bytes the left-out fixed sentences would have taken had they been kept. They
  # are tier 0, so they would have been placed first; 0 outside lean-ai.
  defp left_out_bytes(withheld, left_out, header_bytes) do
    {placed, _over, _duplicates} =
      withheld
      |> Enum.filter(&MapSet.member?(left_out, &1.text))
      |> Enum.sort_by(&{&1.tier, &1.rank, &1.order})
      |> select(header_bytes, Economy.budget_bytes())

    placed |> Enum.map(&byte_size(line(&1.text))) |> Enum.sum()
  end

  # A co-change rule about a file a generated area skill covers is said there, loaded
  # only when the skill is used.
  defp classify(
         %{section: "rules", signal: "history.cochange", path: path} = item,
         tables,
         _unrunnable,
         left_out,
         in_skill
       )
       when is_binary(path) do
    cond do
      MapSet.member?(in_skill, path) -> {:withhold, "in_skill"}
      MapSet.member?(left_out, item.text) -> {:withhold, "process_only"}
      true -> Economy.classify(item, tables)
    end
  end

  defp classify(
         %{section: "commands", text: text} = item,
         tables,
         unrunnable,
         _left_out,
         _in_skill
       ) do
    if Enum.any?(unrunnable, &String.starts_with?(text, &1)),
      do: {:withhold, "tool_unverified"},
      else: Economy.classify(item, tables)
  end

  defp classify(%{text: text} = item, tables, _unrunnable, left_out, _in_skill) do
    if MapSet.member?(left_out, text),
      do: {:withhold, "process_only"},
      else: Economy.classify(item, tables)
  end

  defp skill_files(%{"items" => items}) when is_list(items) do
    for %{"kind" => "skill", "evidence" => %{"files" => files}} <- items,
        file <- files,
        into: MapSet.new(),
        do: file
  end

  defp skill_files(_native), do: MapSet.new()

  # The fixed sentences a lean-ai CLAUDE.md leaves out; none in any other profile.
  defp left_out_fixed(%{"context" => %{"profile" => "lean-ai"}}, tables),
    do: tables.lean_ai_left_out

  defp left_out_fixed(_spec, _tables), do: MapSet.new()

  # The command lines a learned bundle proved do not work in the verification image.
  defp unrunnable_prefixes(
         %{"verification" => %{"status" => "ok"}, "dropped" => dropped} = learned
       )
       when is_list(dropped) do
    verified_roles = verified_roles(learned["commands"])

    Enum.flat_map(dropped, fn
      %{"kind" => "command", "id" => id, "reason" => reason} ->
        case {Map.get(@unrunnable_lines, id), reason} do
          {{prefix, _role}, reason} when reason in ["tool_missing", "not_verified"] ->
            [prefix]

          {{prefix, role}, "verify_failed"} ->
            if MapSet.member?(verified_roles, role), do: [prefix], else: []

          _ ->
            []
        end

      _ ->
        []
    end)
  end

  defp unrunnable_prefixes(_learned), do: []

  defp verified_roles(commands) when is_list(commands) do
    for %{"role" => role, "verify" => %{"status" => "verified"}} when is_binary(role) <- commands,
        into: MapSet.new(),
        do: role
  end

  defp verified_roles(_commands), do: MapSet.new()

  defp items(spec, tables) do
    guidance =
      for section <- spec["guidance"] || [],
          {text, order} <- Enum.with_index(section["lines"]),
          String.trim(text) != "" do
        %{section: section["id"], text: text, order: order, rank: rank(section["id"])}
        |> Map.put(:tier, tier(section["id"], text, tables))
      end

    rules =
      for {rule, order} <- Enum.with_index(spec["rules"] || []) do
        signal = get_in(rule, ["source", "signal"])

        %{
          section: "rules",
          text: rule["statement"],
          order: order,
          rank: rank("rules"),
          signal: signal,
          origin: rule["origin"],
          path: get_in(rule, ["source", "path"]),
          tier: rule_tier(rule["origin"], signal)
        }
      end

    guidance ++ rules
  end

  defp rank(section), do: Enum.find_index(@display, &(&1 == section)) || length(@display)

  # Budget order: fixed sentences, a test command, practice rules and the changelog
  # rule, conventions, other rules, anything else.
  defp tier(section, text, tables) do
    cond do
      MapSet.member?(tables.fixed, text) -> 0
      section == "commands" -> 1
      section == "conventions" -> 3
      true -> 5
    end
  end

  defp rule_tier("approved_claim", _signal), do: 2
  defp rule_tier(_origin, "practices." <> _practice), do: 2
  defp rule_tier(_origin, "history.fix_changelog"), do: 2
  defp rule_tier(_origin, "learning.pitfall." <> _kind), do: 2
  defp rule_tier(_origin, _signal), do: 4

  # The AI policy stays visible to the person reading the file, at no cost to the model.
  defp policy_comment(withheld) do
    withheld
    |> Enum.filter(
      &(&1[:signal] == "instructions.ai_policy" and Economy.comment_path?(&1[:path]))
    )
    |> Enum.map(& &1.path)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map_join("", &"<!-- This project has an AI policy for people to read: #{&1} -->\n")
  end

  @doc """
  True when no `@` in `text` can be read as a file import. Pairing backticks one by one
  differs from CommonMark when runs are unbalanced or escaped, so a line with an `@` and
  anything other than simple single-backtick spans counts as unsafe.
  """
  @spec import_safe?(String.t()) :: boolean()
  def import_safe?(text) do
    not String.contains?(text, "@") or
      (simple_code_spans?(text) and
         not (text |> String.replace(~r/`[^`]*`/, "") |> String.contains?("@")))
  end

  defp simple_code_spans?(text) do
    runs = ~r/`+/ |> Regex.scan(text) |> List.flatten()

    not String.contains?(text, "\\`") and rem(length(runs), 2) == 0 and
      Enum.all?(runs, &(&1 == "`"))
  end

  # In budget order: a line that repeats a kept line (`duplicate?/2`) is withheld as
  # `duplicate` before its bytes are counted; then a line that does not fit is
  # `over_budget`.
  defp select(items, header_bytes, budget) do
    {kept, dropped, duplicates, _used} =
      Enum.reduce(items, {[], [], [], header_bytes}, fn item, {kept, dropped, dups, used} ->
        cost = byte_size(line(item.text))

        cond do
          Enum.any?(kept, &duplicate?(item, &1)) -> {kept, dropped, [item | dups], used}
          used + cost <= budget -> {[item | kept], dropped, dups, used + cost}
          true -> {kept, [item | dropped], dups, used}
        end
      end)

    {Enum.reverse(kept), Enum.reverse(dropped), Enum.reverse(duplicates)}
  end

  # A repository line that says what a kept line says: outside the commands section and
  # the generator's fixed sentences, code spans that are a subset of the kept line's (or
  # the other way round, never empty) and at least one shared word of 4 or more letters,
  # "modify" and "alter" counting as "edit" ("Do not edit `a.js` or `a.js.map`
  # by hand" and "Do not modify the root `a.js` file directly").
  defp duplicate?(%{tier: 0}, _kept), do: false
  defp duplicate?(%{section: "commands"}, _kept), do: false
  defp duplicate?(_item, %{section: "commands"}), do: false

  defp duplicate?(item, kept) do
    spans = code_spans(item.text)
    other = code_spans(kept.text)

    spans != MapSet.new() and other != MapSet.new() and
      (MapSet.subset?(spans, other) or MapSet.subset?(other, spans)) and
      not MapSet.disjoint?(plain_words(item.text), plain_words(kept.text))
  end

  # A line that is a code example with no subject: outside its code spans at most one
  # word, and a span that is a statement (`=` or a call), such as
  # "Use `const { A } = require(\"./a.mjs\");`" whose context line was left out.
  defp no_subject?(%{section: "commands"}), do: false

  defp no_subject?(%{text: text}) do
    words = Regex.scan(~r/[A-Za-z]+/, String.replace(text, ~r/`[^`]*`/, " "))

    length(words) <= 1 and Enum.any?(code_spans(text), &String.match?(&1, ~r/[=(]/))
  end

  defp code_spans(text),
    do:
      ~r/`([^`]+)`/ |> Regex.scan(text, capture: :all_but_first) |> List.flatten() |> MapSet.new()

  @edit_words ~w(edit edits edited editing modify modifies modified alter altered)
  @common_words ~w(this that with from your when then them they have should must only into also each will what which where there their about more than)
  defp plain_words(text) do
    ~r/[a-z]{4,}/
    |> Regex.scan(text |> String.replace(~r/`[^`]*`/, " ") |> String.downcase())
    |> List.flatten()
    |> Enum.reject(&(&1 in @common_words))
    |> Enum.map(&if(&1 in @edit_words, do: "edit", else: &1))
    |> MapSet.new()
  end

  defp line(text), do: "- #{text}\n"

  defp body(kept) do
    kept
    |> Enum.sort_by(&{&1.tier == 0, &1.rank, &1.order})
    |> Enum.map_join("", &line(&1.text))
  end
end
