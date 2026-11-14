defmodule HarnessForge.Analyzers.Instructions do
  @moduledoc """
  Lifts imperative, repository-specific sentences from instruction files.

  A sentence is kept only when it tells an agent to do something and names something
  specific to this repository: a command, a path, a file pattern or a project tool.
  Descriptions of what the project is, generic advice, and sentences containing
  credentials or personal identifiers are dropped. The content is data from the
  repository; each kept sentence records the exact bytes it came from.
  """

  alias HarnessForge.Analyzers.{Privacy, Signal}

  @detector "instructions"
  @agent_paths ~w(CLAUDE.md .claude/CLAUDE.md AGENTS.md .cursorrules .windsurfrules .clinerules GEMINI.md .github/copilot-instructions.md)
  @contributing ~w(CONTRIBUTING CONTRIBUTING.md CONTRIBUTING.rst CONTRIBUTING.txt .github/CONTRIBUTING.md docs/CONTRIBUTING.md docs/contributing.md docs/contributing.rst DEVELOPMENT.md HACKING.md docs/development.md)
  @pr_templates ~w(.github/PULL_REQUEST_TEMPLATE.md .github/pull_request_template.md docs/pull_request_template.md)
  @readme ~w(README.md README.rst README.txt)
  @settings_files ~w(.claude/settings.json .codex/config.toml opencode.json)

  @max_per_file 12
  @max_total 32
  @max_sentence 280

  @verbs ~w(add always annotate avoid bump change create declare define delete describe document don't do ensure export fill follow format generate group import include keep label link make mark mention merge move must never pin place prefer put rebase refactor register remember remove rename replace require reuse run set sign skip sort split squash start stop submit target try update use verify wrap write)
  @modal ~r/\b(?:must(?: not)?|should(?: not)?|have to be|has to be|need to|needs to|are required|is required|shall|may not)\b/i
  @imperative_start ~r/^(?:please |also |then |you must |you should )*(?:be sure|make sure|do not|don't|#{Enum.join(@verbs, "|")})\b/i
  @conditional ~r/^(?:if|when|whenever|before|after|once|for|in|to|while|unless)\b[^,]{3,120},\s*(?:please\s+|also\s+)?(?:be sure|make sure|do not|don't|#{Enum.join(@verbs, "|")})\b/i
  # Verbs that are also ordinary nouns count only when a code span is their object.
  @imperative_with_object ~r/^(?:check|call|list|name|reference|record)\s+(?:that\s+|the\s+|your\s+|each\s+|all\s+)?`/i
  @not_instruction ~r/^(?:we|this|the|it|our|there|its|i|users?|note|check out|see|here|you (?:can|may|might|could)|feel free|thank)\b/i
  @directive ~r/\b(?:must|shall|(?:are|is) required)\b|\b(?:never|always)\s+(?:add|call|change|commit|edit|import|include|merge|put|run|update|use|write)\b/i
  @soft ~r/\b(?:consider|try to|recommended|optionally|optional|may want)\b/i
  @project_tool ~r/\b(?:tox|nox|ruff|pytest|mypy|pyright|pre-commit|towncrier|cargo|clippy|npm|pnpm|yarn|eslint|prettier|mix|credo|dialyzer|gofmt|golangci-lint|uv)\b/
  @file_pattern ~r/(?:^|[\s(`])(?:\*\.[A-Za-z0-9]{1,8}|[A-Za-z0-9_.-]+\.(?:py|pyi|ex|exs|js|ts|tsx|go|rs|rb|md|rst|toml|ya?ml|json|txt|lock|cfg|ini)\b)/
  @not_for_agents ~r/(?i)\b(?:radio button|button|fork|web ui|web interface|click on|clicking|sign[- ]?off)\b/
  @fragment_start ~r/^(?:\.\.\.|(?:and|or|but|then)\b)/i
  @depends_on_previous ~r/(?i)\b(?:instead|as well|above|below|the following|these|those|same|too|also)\.?$/
  @dangling_start ~r/^(?:(?:if|when|once|after|before|unless)\s+)?(?:they|it|these|those)\b/i
  @policy_file ~r/(?i)(?:^|\/)(?:ai|llm)[_-]?(?:policy|usage|guidelines?|contributions?)(?:\.(?:md|rst|txt))?$/
  @policy_heading ~r/\bAI\b|\bLLMs?\b|(?i:generative ai|copilot|chatgpt|machine[- ]generated)/
  @changelog_heading ~r/(?i)change\s?log|news fragment|release notes/
  @mentions_changelog ~r/(?i)change\s?log|news fragment|fragment/
  @file_token ~r/[A-Za-z0-9_.\/-]+\.(?:py|pyi|ex|exs|js|mjs|cjs|ts|tsx|go|rs|rb|md|rst|toml|ya?ml|json|txt|lock|cfg|ini)\b/
  @unsafe ~r/(?i)\b(?:curl|wget|sudo|rm\s+-rf|chmod|base64|eval|ssh|scp|nc|netcat|ignore (?:all |any )?(?:previous|prior|above)|disregard|system prompt|jailbreak)\b|\|\s*(?:ba|z)?sh\b|https?:\/\//

  @doc "Paths that may hold instructions, from the listing."
  @spec paths([String.t()]) :: [String.t()]
  def paths(files) do
    Enum.filter(files, &(kind(&1) != nil))
  end

  defp kind(path) do
    cond do
      path in @agent_paths or Regex.match?(~r/\A\.cursor\/rules\/[^\/]+\.mdc\z/, path) ->
        {:agent, 90}

      path in @contributing ->
        {:contributing, 80}

      path in @pr_templates ->
        {:template, 75}

      path in @readme ->
        {:readme, 60}

      true ->
        nil
    end
  end

  @doc "Contributor documents to search for commands: everything except the README."
  @spec documents(map()) :: map()
  def documents(contents) do
    contents
    |> Enum.filter(fn {path, _} ->
      match?({kind, _} when kind in [:agent, :contributing, :template], kind(path))
    end)
    |> Map.new()
  end

  @spec analyze(map(), [String.t()]) :: [map()]
  def analyze(contents, files) do
    known = MapSet.new(files ++ directories(files))

    {stale, current} =
      contents
      |> Enum.filter(fn {path, _} -> kind(path) != nil end)
      |> Enum.sort()
      |> Enum.flat_map(fn {path, text} -> lift_file(path, text, known) end)
      |> Enum.split_with(&stale_reference?(&1, files))

    lifted =
      current
      |> Enum.sort_by(fn r -> {-r["confidence"], r["path"], r["byte_start"]} end)
      |> deduplicate()
      |> Enum.take(@max_total)

    # An instruction naming a file that no longer exists cannot be repeated as written,
    # but it still shows the project cares about that topic.
    corroborates =
      stale |> Enum.map(& &1["topic"]) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort()

    [
      Signal.new(
        "instructions.existing",
        %{"files" => existing(files)},
        100,
        @detector,
        Enum.map(existing(files), &Signal.file/1)
      ),
      Signal.new(
        "instructions.rule_candidates",
        %{"rules" => lifted, "corroborates" => corroborates, "stale_references" => length(stale)},
        lifted |> Enum.map(& &1["confidence"]) |> Enum.max(fn -> 0 end),
        @detector,
        lifted |> Enum.map(&Signal.file(&1["path"], &1["line"])) |> Enum.take(32)
      )
    ] ++ ai_policy(contents, files)
  end

  # A project that limits AI tools must not have that hidden from an agent. Only the
  # location is reported; the policy's wording stays in the repository.
  defp ai_policy(contents, files) do
    case policy_files(files) ++ policy_sections(contents) do
      [] ->
        []

      [{path, line, text} | _] = found ->
        rule =
          %{"text" => text, "confidence" => 100, "path" => path, "topic" => "ai_policy"}
          |> then(&if(line, do: Map.put(&1, "line", line), else: &1))

        [
          Signal.new(
            "instructions.ai_policy",
            %{"rules" => [rule]},
            100,
            @detector,
            found |> Enum.map(fn {cited, at, _} -> Signal.file(cited, at) end) |> Enum.take(8)
          )
        ]
    end
  end

  defp policy_files(files) do
    files
    |> Enum.filter(&Regex.match?(@policy_file, &1))
    |> Enum.sort()
    |> Enum.map(fn path ->
      {path, nil, "Read `#{path}` first: this project restricts AI-assisted contributions."}
    end)
  end

  defp policy_sections(contents) do
    contents
    |> Enum.filter(fn {path, _} -> match?({:contributing, _}, kind(path)) end)
    |> Enum.sort()
    |> Enum.flat_map(fn {path, text} ->
      text
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _} ->
        heading_text?(line) and Regex.match?(@policy_heading, line)
      end)
      |> Enum.take(1)
      |> Enum.map(fn {_line, number} ->
        {path, number,
         "Read the section at line #{number} of `#{path}` first: this project sets rules for AI-assisted contributions."}
      end)
    end)
  end

  # Stops once enough rules are kept, so the comparisons stay bounded on hostile input.
  defp deduplicate(rules) do
    rules
    |> Enum.reduce_while([], fn rule, kept ->
      words = word_set(rule["text"])

      cond do
        length(kept) >= @max_total -> {:halt, kept}
        Enum.any?(kept, fn {_, seen} -> similar?(seen, words) end) -> {:cont, kept}
        true -> {:cont, kept ++ [{rule, words}]}
      end
    end)
    |> Enum.map(&elem(&1, 0))
  end

  defp similar?(a, b) do
    union = MapSet.size(MapSet.union(a, b))
    union > 0 and MapSet.size(MapSet.intersection(a, b)) * 100 >= union * 45
  end

  defp word_set(text) do
    ~r/[A-Za-z0-9_.\/`*-]{4,}/
    |> Regex.scan(String.downcase(text))
    |> List.flatten()
    |> MapSet.new()
  end

  defp stale_reference?(rule, files) do
    ~r/`[^`]*`/
    |> Regex.replace(rule["text"], " ")
    |> then(&Regex.scan(@file_token, &1))
    |> List.flatten()
    |> Kernel.++(code_span_paths(rule["text"]))
    |> Enum.any?(fn token -> not Enum.any?(files, &String.ends_with?(&1, token)) end)
  end

  defp code_span_paths(text) do
    ~r/`([^`]+)`/
    |> Regex.scan(text, capture: :all_but_first)
    |> List.flatten()
    |> Enum.filter(&Regex.match?(~r/\A#{@file_token.source}\z/, &1))
    |> Enum.reject(&String.match?(&1, ~r/[0-9<>{}*#]/))
  end

  # The repository's own Claude Code subagents and skills are listed too: the lean
  # context profile keeps the tools they need (`Generation.Spec`).
  defp existing(files) do
    agent = Enum.filter(files, &match?({:agent, _}, kind(&1)))
    settings = Enum.filter(files, &(&1 in @settings_files))
    own = Enum.filter(files, &own_agent_or_skill?/1)
    (agent ++ settings ++ own) |> Enum.uniq() |> Enum.sort() |> Enum.take(32)
  end

  @doc "True for a repository's own Claude Code subagent, skill or command file."
  @spec own_agent_or_skill?(String.t()) :: boolean()
  def own_agent_or_skill?(path) when is_binary(path) do
    case String.split(path, "/") do
      [".claude", "agents" | rest] when rest != [] -> String.ends_with?(path, ".md")
      [".claude", "skills", _name, "SKILL.md"] -> true
      [".claude", "commands" | rest] when rest != [] -> String.ends_with?(path, ".md")
      _ -> false
    end
  end

  defp directories(files) do
    files
    |> Enum.flat_map(fn path ->
      parts = String.split(path, "/")
      for n <- 1..(length(parts) - 1)//1, do: parts |> Enum.take(n) |> Enum.join("/")
    end)
    |> Enum.uniq()
  end

  defp lift_file(path, text, known) do
    {kind, base} = kind(path)
    text = text |> strip_managed() |> only_contribution_sections(kind)
    headings = headings(text)

    text
    |> paragraphs(kind)
    |> Enum.flat_map(&sentences/1)
    |> Enum.flat_map(&keep(&1, path, text, kind, base, known, headings))
    |> Enum.sort_by(fn r -> {-r["confidence"], r["byte_start"]} end)
    |> Enum.take(@max_per_file)
  end

  # Text inside an Olivium managed block was generated by this tool. Feeding it back
  # would let earlier output confirm itself. It is blanked and keeps its byte positions.
  defp strip_managed(text) do
    Regex.replace(~r/<!-- olivium:begin.*?<!-- olivium:end[^\n]*-->/s, text, fn match ->
      String.duplicate(" ", byte_size(match))
    end)
  end

  # A README mostly describes the project. Only its contribution and development
  # sections can hold instructions, and everything else is blanked in place.
  defp only_contribution_sections(text, :readme) do
    {spans, _keep?} =
      text
      |> line_spans()
      |> Enum.map_reduce(false, fn {_start, line}, keep? ->
        keep? =
          if heading_text?(line),
            do: Regex.match?(~r/(?i)contribut|develop|hacking|running tests|testing|build/, line),
            else: keep?

        {if(keep?, do: line, else: String.duplicate(" ", byte_size(line))), keep?}
      end)

    Enum.join(spans, "\n")
  end

  defp only_contribution_sections(text, _kind), do: text

  defp heading_text?(line), do: Regex.match?(~r/^\#{1,6}\s/, String.trim_leading(line))

  defp headings(text) do
    text
    |> line_spans()
    |> Enum.filter(fn {_start, line} -> heading_text?(line) end)
    |> Enum.reverse()
  end

  defp keep({offset, raw}, path, text, kind, base, known, headings) do
    clean = clean(raw)

    with true <- complete?(clean),
         false <- Privacy.secret?(raw) or Privacy.identity?(raw),
         false <- Regex.match?(@unsafe, clean),
         false <- Regex.match?(@not_for_agents, clean),
         false <- Regex.match?(@fragment_start, clean),
         false <- Regex.match?(@depends_on_previous, clean),
         false <- Regex.match?(@dangling_start, clean),
         true <- instruction?(clean, kind, checklist?(raw)),
         true <- specific?(clean, known) do
      confidence = confidence(base, clean)
      statement = scoped(clean, offset, headings)

      [
        %{
          "text" => statement,
          "confidence" => confidence,
          "path" => path,
          "line" => line_of(text, offset),
          "byte_start" => offset,
          "byte_length" => byte_size(raw),
          "source_text" => raw,
          "topic" => topic(clean)
        }
      ]
    else
      _ -> []
    end
  end

  # A formatting rule for changelog text reads as a project-wide rule once lifted out of
  # its section, so the section's scope is carried into the statement.
  defp scoped(text, offset, headings) do
    heading = Enum.find(headings, fn {start, _line} -> start <= offset end)

    if heading != nil and Regex.match?(@changelog_heading, elem(heading, 1)) and
         not Regex.match?(@mentions_changelog, text),
       do: "In changelog entries: " <> text,
       else: text
  end

  defp checklist?(raw), do: Regex.match?(~r/^\s*(?:[-*+]\s+)?\[[ xX]\]\s/, raw)

  defp line_of(text, offset) do
    text |> binary_part(0, offset) |> :binary.matches("\n") |> length() |> Kernel.+(1)
  end

  defp topic(text) do
    cond do
      Regex.match?(~r/(?i)chang(?:e|es)?log|news fragment|CHANGES\.|HISTORY\.|NEWS\./, text) ->
        "changelog"

      Regex.match?(
        ~r/(?i)\btests?\b.*\b(?:add|update|include|cover)\b|\b(?:add|update|include|cover)\b.*\btests?\b/,
        text
      ) ->
        "tests"

      true ->
        nil
    end
  end

  defp confidence(base, text) do
    if Regex.match?(@soft, text), do: max(base - 15, 40), else: base
  end

  defp complete?(text) do
    size = String.length(text)
    size >= 12 and size <= @max_sentence and not String.ends_with?(text, [":", ",", "?"])
  end

  # A template is a checklist or prose around one; only its checklist items are instructions
  # without an imperative form.
  defp instruction?(text, :template, checklist?) do
    not Regex.match?(~r/^(?:i|this pull request|you may|summary)\b/i, text) and
      ((checklist? and not Regex.match?(@not_instruction, text)) or instruction?(text))
  end

  defp instruction?(text, _kind, _checklist?), do: instruction?(text)

  defp instruction?(text) do
    cond do
      Regex.match?(@not_instruction, text) ->
        Regex.match?(@directive, text)

      Regex.match?(@imperative_start, text) ->
        true

      Regex.match?(@imperative_with_object, text) ->
        true

      Regex.match?(@conditional, text) ->
        true

      true ->
        Regex.match?(@modal, text) and not Regex.match?(~r/(?i)\bneeds? to know\b/, text)
    end
  end

  defp specific?(text, known) do
    specific_span?(text) or Regex.match?(@file_pattern, text) or
      Regex.match?(@project_tool, text) or mentions_known_path?(text, known)
  end

  # A code span counts when it looks like code: one token, a command such as
  # `make test`, or a lowercase phrase of three or more words. Titles and interface
  # labels in backticks do not count.
  defp specific_span?(text) do
    ~r/`([^`]+)`/
    |> Regex.scan(text, capture: :all_but_first)
    |> List.flatten()
    |> Enum.any?(fn span ->
      case String.split(span) do
        [_token] -> true
        [word | _] when word in ~w(make just go) -> true
        words -> length(words) >= 3 and not Regex.match?(~r/^[A-Z]/, span)
      end
    end)
  end

  defp mentions_known_path?(text, known) do
    ~r/[A-Za-z0-9_.\/-]+/
    |> Regex.scan(text)
    |> List.flatten()
    |> Enum.map(&String.trim_trailing(&1, "."))
    |> Enum.any?(fn token ->
      (String.contains?(token, "/") or String.contains?(token, ".")) and
        (MapSet.member?(known, token) or MapSet.member?(known, String.trim_trailing(token, "/")))
    end)
  end

  # Paragraphs and sentences. Everything keeps byte offsets into the original text.

  defp paragraphs(text, kind) do
    lines = line_spans(text)

    {paragraphs, open, _, _} =
      Enum.reduce(lines, {[], nil, false, false}, fn {start, line}, state ->
        step(state, start, line, kind)
      end)

    paragraphs
    |> flush(open)
    |> Enum.reverse()
    |> Enum.map(fn {start, stop} -> {start, binary_part(text, start, stop - start)} end)
  end

  defp line_spans(text) do
    {spans, _} =
      text
      |> String.split("\n")
      |> Enum.map_reduce(0, fn line, offset -> {{offset, line}, offset + byte_size(line) + 1} end)

    spans
  end

  defp step({done, open, fenced, comment}, start, line, kind) do
    trimmed = String.trim(line)

    cond do
      String.starts_with?(trimmed, ["```", "~~~"]) ->
        {flush(done, open), nil, not fenced, comment}

      fenced ->
        {done, open, true, comment}

      kind == :template and comment_start?(trimmed) ->
        {flush(done, open), nil, false, not String.contains?(trimmed, "-->")}

      kind == :template and comment and comment_end?(trimmed) ->
        {flush(done, open), nil, false, false}

      kind != :template and comment_start?(trimmed) ->
        {flush(done, open), nil, false, not String.contains?(trimmed, "-->")}

      kind != :template and comment ->
        {done, open, false, not comment_end?(trimmed)}

      trimmed == "" ->
        {flush(done, open), nil, false, comment}

      heading?(trimmed) ->
        {flush(done, open), nil, false, comment}

      String.starts_with?(trimmed, "|") ->
        {flush(done, open), nil, false, comment}

      list_item?(trimmed) ->
        {flush(done, open), {start, start + byte_size(line)}, false, comment}

      open != nil ->
        {begin, _} = open
        {done, {begin, start + byte_size(line)}, false, comment}

      true ->
        {done, {start, start + byte_size(line)}, false, comment}
    end
  end

  defp comment_start?(line), do: String.starts_with?(line, "<!--")
  defp comment_end?(line), do: String.contains?(line, "-->")

  defp flush(done, nil), do: done
  defp flush(done, span), do: [span | done]

  defp heading?(line) do
    Regex.match?(~r/^\#{1,6}\s/, line) or Regex.match?(~r/^[=\-~^"`*+#:]{3,}\s*$/, line) or
      String.starts_with?(line, [".. ", "<"])
  end

  defp list_item?(line) do
    Regex.match?(~r/^(?:[-*+]\s+|\d+[.)]\s+|-\s*\[[ xX]\]\s+)/, line)
  end

  defp sentences({start, raw}) do
    points =
      ~r/(?<=[.!?])["')*_`]*\s+(?=[A-Z`*_\[(])/
      |> Regex.scan(raw, return: :index)
      |> Enum.map(fn [{index, length}] -> index + length end)
      |> Enum.reject(&abbreviation_before?(raw, &1))

    [0 | points]
    |> Enum.zip(points ++ [byte_size(raw)])
    |> Enum.flat_map(fn {from, to} ->
      slice = binary_part(raw, from, to - from)
      trimmed = String.trim_trailing(slice)
      lead = byte_size(slice) - byte_size(String.trim_leading(slice))

      if trimmed == "" do
        []
      else
        [{start + from + lead, binary_part(raw, from + lead, byte_size(trimmed) - lead)}]
      end
    end)
  end

  # Only the bytes just before the boundary are examined, which keeps sentence splitting
  # linear in the size of the document.
  defp abbreviation_before?(raw, point) do
    start = max(point - 16, 0)

    Regex.match?(
      ~r/(?:\be\.g\.|\bi\.e\.|\betc\.|\bvs\.|\bcf\.)["')*_`]*\s*$/i,
      binary_part(raw, start, point - start)
    )
  end

  defp clean(raw) do
    raw
    |> String.replace(~r/[\r\n]+\s*/, " ")
    |> String.replace(~r/^\s*(?:>\s*)*(?:[-*+]\s+|\d+[.)]\s+)?(?:\[[ xX]\]\s+)?/, "")
    |> String.replace(~r/``([^`]+)``/, "`\\1`")
    |> String.replace(~r/:[a-z]+:`([^`]+)`/, "`\\1`")
    |> unlink()
    |> strip_emphasis()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp unlink(text) do
    text
    |> then(&Regex.replace(~r/!\[[^\]]*\]\([^)]*\)/, &1, ""))
    |> then(&Regex.replace(~r/\[([^\]]+)\]\([^)]*\)/, &1, "\\1"))
    |> then(&Regex.replace(~r/\[([^\]]+)\]\[[^\]]*\]/, &1, "\\1"))
  end

  # Emphasis markers are removed outside code spans only; `*.py` must survive.
  defp strip_emphasis(text) do
    Regex.split(~r/(`[^`]*`)/, text, include_captures: true)
    |> Enum.map_join(fn part ->
      if String.starts_with?(part, "`"), do: part, else: String.replace(part, ~r/\*+|__/, "")
    end)
  end
end
