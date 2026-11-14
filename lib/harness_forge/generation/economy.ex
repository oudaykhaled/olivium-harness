defmodule HarnessForge.Generation.Economy do
  @moduledoc """
  Decides, line by line, what may enter the root guidance file, and what it costs.

  Every model-visible byte of `CLAUDE.md` is sent with every model request, behind a
  fixed wrapper of about 110 tokens (measured on Claude Code 2.1.311; an empty or
  comment-only file pays no wrapper). So a line ships only if it passes four tests,
  in this order, and the first failed test names the reason it was withheld:

    1. `default_guessable`: it does not just state the ecosystem default from the
       static tables in `priv/blueprints/*.json` (`pytest`, `npm test`, `src/<pkg>`,
       `tests/test_*.py`). An agent finds those by itself.
    2. `process_only`: it says what a correct change must contain, not what to run or
       how to work (lint, format, type check, build, install and run lines; test
       session runners and lint tools such as tox, nox and flake8; virtual
       environments; pull requests and commits, issue labels, and every line of a pull
       request or issue template; "read the AI policy first").
    3. `tool_unverified`: it does not tell the agent to use a tool the generator cannot
       see installed. Missing tools are reported at session start instead.
    4. `scoped`: it applies to the whole repository, not to one path.

  Three more codes come from the renderer: `import_marker` (an `@` outside a simple code
  span, which Claude Code would expand as a file import), `over_budget`, and `in_skill`
  (a co-change rule about a file that a generated area skill covers; such a rule is
  `scoped` anyway, so this code names where it went, not a byte saved). Two more are
  reported only when used: `duplicate` (a line whose code spans are a subset of a kept
  line's, or the other way round, with a shared word) and `no_subject` (a code example with at most one word
  outside its code spans, whose context line was left out).

  Exempt by construction: the generator's own fixed sentences (blueprint `guidance`)
  and a history-measured changelog rule. In the `lean-ai` profile the renderer leaves
  out the fixed sentences the blueprint lists in `guidance.lean_ai_left_out` (the
  lint-and-format sentence and its lint-only and format-only forms) as `process_only`:
  the stop hook runs lint and format whether or not the file says so. Their bytes are
  not given to other lines (`HarnessForge.Generation.Guidance`). A human-approved
  claim skips tests 1 and 2.
  A learned global pitfall (`learning.pitfall.*`, 3 or more evidence commits) skips
  tests 1 and 3.

  Pure: the same spec gives the same decisions. No repository text is read here and
  no model is involved.
  """

  alias HarnessForge.Generation.Blueprint

  @budget_bytes 600
  @wrapper_tokens 110
  @reasons ~w(default_guessable import_marker over_budget process_only scoped tool_unverified)
  # Reported in `withheld_counts` only when used, so a package without generated skills
  # keeps the provenance bytes it had before the code existed.
  @optional_reasons ~w(duplicate in_skill no_subject)
  @all_reasons Enum.sort(@reasons ++ @optional_reasons)
  @max_withheld 512
  @report_path ".olivium/guidance-provenance.json"

  @process_labels ~w(Lint Format Typecheck Build Run Install)
  @process ~r/\b(?:run|running|execute|invoke)\s+(?:`|the\s+(?:tests?|test suite|suite|linters?|formatters?|type ?checkers?|checks?)\b)|\b(?:lint|linter|linters|linting|linted|formatter|formatters|formatting|reformat|type[- ]?check(?:s|er|ers|ing|ed)?|pre-commit|install|installs|installed|installing|installation)\b|\bbuild(?:ing)?\s+(?:the\s+)?(?:docs|documentation|package|project|wheel|sdist)\b|\bpull[- ]requests?\b|\bcommit(?:s|ted|ting)?\b|\bcommit messages?\b|\bissue tracker\b|\bopen (?:an|a new) issue\b|\bissues? (?:is|are) labell?ed\b|\bcode review\b|\breviewers?\b|\bsquash\b|\brebase\b|\b(?:git|feature|topic|release|main|master|default|base|target|upstream|working|new|your)\s+branch(?:es)?\b|\bbranch(?:es)?\s+(?:off|from|name|names)\b|\bAI[- ]policy\b|\b(?:nox|tox|pycodestyle|flake8|pylint)\b|\bvirtual\s+environments?\b/i
  @process_acronyms ~r/\b(?:PRs?|CI)\b/
  # Pull request and issue templates are checklists for the person opening one.
  @template_path ~r/(?:\A|\/)(?:pull_request_template|issue_template)(?:\.[A-Za-z]+\z|\/)/i
  # A code span naming a path inside a directory, or a documentation file type: such a
  # rule applies to part of the repository, not to every change. A span that starts
  # with `@` is a scoped package name (`@acme/web`), not a path.
  @scoped ~r/`(?!@)[^`\s]*[A-Za-z0-9_.*-]\/[^`\s]*`|`\*?\.(?:md|rst|txt|adoc)`/
  @command_line ~r/\A(Test one|Test|Lint|Format|Typecheck|Build|Run|Install): `([^`]+)`\z/
  @layout_line ~r/\A`([^`]+)`: .+\z/
  @test_location ~r/\ATests live under ([^ ]+)\/ as ([^ ]+) files\z/
  @hints ~w(<expr> <regex> <file>)
  @comment_path ~r/\A[A-Za-z0-9_.][A-Za-z0-9_.\/-]{0,199}\z/

  @spec budget_bytes() :: pos_integer()
  def budget_bytes, do: @budget_bytes

  @doc "The withheld-line reason codes `withheld_counts` always reports, sorted."
  @spec reasons() :: [String.t()]
  def reasons, do: @reasons

  @doc "Every withheld-line reason code, sorted: `reasons/0` plus `in_skill`, reported only when used."
  @spec all_reasons() :: [String.t()]
  def all_reasons, do: @all_reasons

  @spec report_path() :: String.t()
  def report_path, do: @report_path

  # What a user loses with the lean profile's tool denies, named where the profile is
  # shown. A project-level deny cannot be lifted from user settings, so this covers the
  # user's own and plugin subagents and skills too.
  @lost_capabilities [{"Task", "subagents (Task)"}, {"Skill", "skills (Skill, Workflow)"}]

  @doc """
  The capabilities a context profile's denied tools take away, as a phrase that starts
  with ", including", or "" when it takes none of them.
  """
  @spec lost_capabilities([String.t()]) :: String.t()
  def lost_capabilities(names) when is_list(names) do
    case for({name, text} <- @lost_capabilities, name in names, do: text) do
      [] -> ""
      texts -> ", including " <> Enum.join(texts, " and ")
    end
  end

  @doc """
  Estimated tokens added to every model request by `bytes` of model-visible
  `CLAUDE.md` content: nothing for an empty or comment-only file, otherwise the
  measured wrapper plus 2.8 bytes per token, rounded up. Integers only.
  """
  @spec price(non_neg_integer()) :: non_neg_integer()
  def price(0), do: 0

  def price(bytes) when is_integer(bytes) and bytes > 0,
    do: @wrapper_tokens + div(bytes * 10 + 27, 28)

  @doc """
  The static tables the tests use for a spec's project: the base blueprint's
  guidance block overlaid with the stack's defaults, chosen by the project's
  languages exactly as generation chose its blueprint. `lean_ai_left_out` holds the
  fixed sentences the `lean-ai` profile leaves out of `CLAUDE.md` (lint and format,
  lint only, format only).
  """
  @spec tables(map()) :: map()
  def tables(project) when is_map(project) do
    blueprint = Blueprint.select(%{"languages" => project["languages"] || []})
    guidance = blueprint["guidance"] || %{}
    defaults = blueprint["guidance_defaults"] || %{}
    ignored = guidance["ignored_test_flags"] || []
    fixed_lines = Map.get(guidance, "fixed_lines", %{})

    %{
      fixed: fixed_lines |> Map.values() |> MapSet.new(),
      lean_ai_left_out:
        fixed_lines
        |> Map.take(guidance["lean_ai_left_out"] || [])
        |> Map.values()
        |> MapSet.new(),
      tests: defaults |> Map.get("test_commands", []) |> Enum.map(&normalize(&1, ignored)),
      singles:
        defaults |> Map.get("single_test_commands", []) |> Enum.map(&normalize(&1, ignored)),
      locations: MapSet.new(defaults["test_locations"] || []),
      layout: guidance["layout_defaults"] || [],
      ignored: ignored,
      tools: tool_pattern(guidance["tool_names"] || [])
    }
  end

  @doc """
  True when a learned global pitfall line would be kept in `CLAUDE.md`: not a process
  line and not scoped to one area. `Generation.Spec` lets a learned line replace a
  static one only then, so a withheld learned line never takes a kept static line
  with it.
  """
  @spec learned_line_kept?(String.t()) :: boolean()
  def learned_line_kept?(text) when is_binary(text), do: learned_tests(%{text: text}) == :keep

  @doc """
  Classify one candidate line. `item` is a map with `:section`, `:text`, and for
  rules `:signal` (the citing signal) and `:origin`. Returns `:keep` or
  `{:withhold, reason}`.
  """
  @spec classify(map(), map()) :: :keep | {:withhold, String.t()}
  def classify(%{text: text} = item, tables) do
    if MapSet.member?(tables.fixed, text),
      do: :keep,
      else: tests(item, tables)
  end

  defp tests(%{section: "commands", text: text} = item, tables) do
    case Regex.run(@command_line, text) do
      [_, "Test", command] ->
        if default_command?(command, tables.tests, tables), do: guessable(), else: :keep

      [_, "Test one", command] ->
        if default_command?(strip_hint(command), tables.singles, tables),
          do: guessable(),
          else: :keep

      [_, label, _command] when label in @process_labels ->
        {:withhold, "process_only"}

      _ ->
        text_tests(item, tables)
    end
  end

  defp tests(%{section: "project-map", text: text} = item, tables) do
    case Regex.run(@layout_line, text) do
      [_, path] -> if default_layout?(path, tables.layout), do: guessable(), else: scoped()
      _ -> text_tests(item, tables)
    end
  end

  defp tests(%{section: "conventions", text: text} = item, tables) do
    case Regex.run(@test_location, text) do
      [_, directory, pattern] ->
        if MapSet.member?(tables.locations, directory <> "|" <> pattern),
          do: guessable(),
          else: :keep

      _ ->
        text_tests(item, tables)
    end
  end

  defp tests(%{section: "rules"} = item, tables) do
    signal = item[:signal] || ""

    cond do
      item[:origin] == "approved_claim" ->
        reviewed_tests(item, tables)

      String.contains?(signal, "cochange") ->
        scoped()

      signal in ["instructions.ai_policy", "history.commit_style"] ->
        {:withhold, "process_only"}

      is_binary(item[:path]) and Regex.match?(@template_path, item[:path]) ->
        {:withhold, "process_only"}

      signal == "history.fix_tests" ->
        guessable()

      signal == "history.fix_changelog" ->
        :keep

      String.starts_with?(signal, "learning.pitfall.") ->
        learned_tests(item)

      true ->
        text_tests(item, tables)
    end
  end

  defp tests(item, tables), do: text_tests(item, tables)

  # A learned global pitfall reached the spec only with 3 or more evidence commits, so
  # it is not a guessable default, and the code it names (`pytest.deprecated_call`) is
  # an idiom those commits used, not a tool to install. It must still be about the
  # change itself and about the whole repository.
  defp learned_tests(%{text: text}) do
    cond do
      Regex.match?(@process, text) or Regex.match?(@process_acronyms, text) ->
        {:withhold, "process_only"}

      Regex.match?(@scoped, text) ->
        scoped()

      true ->
        :keep
    end
  end

  # A reviewed claim was approved by a person: tests 1 and 2 do not apply.
  defp reviewed_tests(%{text: text}, tables) do
    cond do
      tool_promised?(text, tables) -> {:withhold, "tool_unverified"}
      Regex.match?(@scoped, text) -> scoped()
      true -> :keep
    end
  end

  defp text_tests(%{text: text}, tables) do
    cond do
      Regex.match?(@process, text) or Regex.match?(@process_acronyms, text) ->
        {:withhold, "process_only"}

      tool_promised?(text, tables) ->
        {:withhold, "tool_unverified"}

      Regex.match?(@scoped, text) ->
        scoped()

      true ->
        :keep
    end
  end

  defp guessable, do: {:withhold, "default_guessable"}
  defp scoped, do: {:withhold, "scoped"}

  defp tool_promised?(_text, %{tools: nil}), do: false
  defp tool_promised?(text, %{tools: pattern}), do: Regex.match?(pattern, text)

  # "Run `mypy`", "use pre-commit", "with black", or a code span that starts with a
  # tool. Naming a tool to explain something ("coverage cannot measure") promises nothing.
  defp tool_pattern([]), do: nil

  defp tool_pattern(names) do
    alternatives = names |> Enum.sort_by(&(-byte_size(&1))) |> Enum.map_join("|", &Regex.escape/1)

    runners =
      "(?:uv run |poetry run |pdm run |hatch run |pipenv run |npx |pnpm |yarn |python3? -m )?"

    Regex.compile!(
      "(?i)\\b(?:use|using|with|via|through|call|calls)\\s+`?#{runners}(?:#{alternatives})(?![A-Za-z0-9_-])" <>
        "|`#{runners}(?:#{alternatives})(?![A-Za-z0-9_-])"
    )
  end

  defp strip_hint(command) do
    case String.split(command, " ") |> Enum.split(-1) do
      {rest, [hint]} when hint in @hints and rest != [] -> Enum.join(rest, " ")
      _ -> command
    end
  end

  defp default_command?(command, defaults, tables),
    do: normalize(command, tables.ignored) in defaults

  defp normalize(command, ignored) do
    command
    |> String.split(" ", trim: true)
    |> Enum.reject(&(&1 in ignored))
    |> Enum.join(" ")
  end

  # `*` stands for exactly one path segment.
  defp default_layout?(path, patterns) do
    segments = String.split(path, "/")

    Enum.any?(patterns, fn pattern ->
      parts = String.split(pattern, "/")

      length(parts) == length(segments) and
        Enum.zip(parts, segments)
        |> Enum.all?(fn {part, segment} -> part == "*" or part == segment end)
    end)
  end

  @doc """
  The provenance report written to `#{@report_path}`. `withheld` holds
  `%{section, text, reason}` rows; the list is capped and sorted, the counts are not.
  `budget_bytes` is the budget the renderer used: #{@budget_bytes}, or less in `lean-ai`
  when a left-out fixed sentence's bytes were not given to other lines.
  """
  @spec report([map()], non_neg_integer(), non_neg_integer(), non_neg_integer()) :: map()
  def report(withheld, rendered_bytes, kept_lines, budget_bytes \\ @budget_bytes) do
    rows =
      withheld
      |> Enum.map(fn row ->
        %{
          "section" => row.section,
          "text" => row.text,
          "bytes" => byte_size(row.text),
          "reason" => row.reason
        }
      end)
      |> Enum.sort_by(&{&1["section"], &1["reason"], &1["text"]})

    counts = Enum.frequencies_by(withheld, & &1.reason)

    %{
      "budget_bytes" => budget_bytes,
      "rendered_bytes" => rendered_bytes,
      "est_tokens_per_request" => price(rendered_bytes),
      "kept_lines" => kept_lines,
      "withheld" => Enum.take(rows, @max_withheld),
      "withheld_counts" =>
        @all_reasons
        |> Enum.reject(&(&1 in @optional_reasons and Map.get(counts, &1, 0) == 0))
        |> Map.new(&{&1, Map.get(counts, &1, 0)})
    }
  end

  @doc """
  The `guidance_withheld` diagnostic for a report, or none when nothing was
  withheld. Shown wherever the package is, so no line is left out silently.
  """
  @spec diagnostics(map()) :: [map()]
  def diagnostics(%{"withheld_counts" => counts} = report) do
    total = counts |> Map.values() |> Enum.sum()

    if total == 0 do
      []
    else
      parts =
        @all_reasons
        |> Enum.filter(&((counts[&1] || 0) > 0))
        |> Enum.map_join(", ", &"#{counts[&1]} #{&1}")

      [
        %{
          "code" => "guidance_withheld",
          "severity" => "info",
          "message" =>
            "#{total} guidance lines were left out of CLAUDE.md (#{parts}). It keeps #{report["kept_lines"]} lines: #{report["rendered_bytes"]} bytes, about #{report["est_tokens_per_request"]} tokens on every model request. See #{@report_path}."
        }
      ]
    end
  end

  @doc """
  True for a repository path that may be named inside an HTML comment: plain
  characters only, and no `..`, `//` or `--`, so it can neither leave the project nor
  close the comment.
  """
  @spec comment_path?(term()) :: boolean()
  def comment_path?(path) when is_binary(path),
    do: Regex.match?(@comment_path, path) and not String.contains?(path, ["..", "//", "--"])

  def comment_path?(_), do: false
end
