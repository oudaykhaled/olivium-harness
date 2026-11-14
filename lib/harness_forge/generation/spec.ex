defmodule HarnessForge.Generation.Spec do
  @moduledoc """
  Builds a `harnessforge.dev/v1alpha2` spec from a validated RepoProfile and a
  blueprint. Pure: the same profile and blueprint give the same spec.

  Only `auto` rule candidates enter the spec, as `derived` rules ordered by
  confidence. That order is the only confidence signal the adapter sees, so it
  decides what survives the guidance budget. Project commands that match a denied
  prefix are removed before anything else can reference them.

  A solo package carries no generic agent or skill: both are listed to the model on
  every request, and neither has shown value yet. A rule about writing commits is left
  out while the same package denies `git commit`, so the agent is never told to do
  something it cannot do.

  The spec also carries what the runtime hooks read (contract: stage 1 of the harness
  enhancement plan): the tools to probe per role, test pairs and co-change partners
  from history, one `before_stop` hook per role whose command takes file arguments,
  a `session_start` environment check, and the `context` profile. `lean` (the solo
  default) removes measured, unused prompt content; `standard` keeps it. `lean` is
  refused, never swapped for `standard`, when the package has agents or skills. When
  the repository has its own subagents (`.claude/agents/`) or skills and commands
  (`.claude/skills/`, `.claude/commands/`), the lean profiles keep `Task`, or `Skill`
  and `Workflow`, and record no saving, because only the full deny list was measured.
  `lean-x` has the settings of `lean` and no runtime hooks in the spec: its adapter
  renders only the guard, a Bash output shaper and an output style, and no `CLAUDE.md`.

  Practice rules (stage 2, item 7): the profile's `practices` counts are copied to
  `project.practices`, and each practice whose blueprint threshold they meet adds one
  `derived` rule whose statement is a fixed sentence from the stack blueprint, never
  repository text. At most two, placed before the other rules; the renderer still
  applies the inclusion test and the byte budget to them.
  """

  alias HarnessForge.Contracts
  alias HarnessForge.Contracts.{Error, HarnessV2}
  alias HarnessForge.Generation.{Blueprint, Economy, LearnedRender, Native, Profile}

  # Display and budget order; test_single is dropped when it repeats test.
  @command_labels [
    {"test", "Test"},
    {"test_single", "Test one"},
    {"lint", "Lint"},
    {"format", "Format"},
    {"typecheck", "Typecheck"},
    {"build", "Build"},
    {"run", "Run"},
    {"install", "Install"}
  ]

  @stop_roles ~w(format lint test)
  @selectors %{"format" => "changed_files", "lint" => "changed_files", "test" => "related_tests"}
  @tool_roles ~w(test lint typecheck format interpreter)
  @event_order %{
    "session_start" => 0,
    "prompt_submit" => 1,
    "before_stop" => 2,
    "after_edit" => 3
  }
  @role_order %{"format" => 0, "lint" => 1, "test" => 2}
  @pair_cap 200
  @context_profiles ~w(lean standard lean-ai lean-x)
  # Profiles whose settings facts are another profile's, unchanged.
  @trim_from %{"lean-x" => "lean"}
  @practice_ids ~w(deprecation warnings_as_errors)
  @max_practice_rules 2

  @commit_rule ~r/(?i)\bcommit (?:subject|message|title)s?\b|\bconventional commits?\b|\bin the same commit\b|\bgit commit\b/

  @doc """
  Returns the spec plus the facts it left out:
  `%{"spec", "skipped_commands", "excluded_candidates", "diagnostics"}`. Uses the mode's
  default context profile (`lean` for solo, `standard` otherwise), which is always
  available for that mode.
  """
  @spec build(map(), map(), String.t()) :: map()
  def build(profile, blueprint, mode) do
    {:ok, built} = build(profile, blueprint, mode, %{})
    built
  end

  @doc """
  Like `build/3`, with options: `"context"` is `"lean"`, `"standard"`, `"lean-x"`, or
  `%{"profile" => "lean-ai", "learned" => prepared}` where `prepared` comes from
  `HarnessForge.Generation.LearnedRender.prepare/3` (the learned bundle, the index rows
  and the locator gate). Returns `{:error, %Error{code: "lean_profile_unavailable"}}`
  when `lean`, `lean-ai` or `lean-x` is requested for a package with agents or skills,
  and never switches to `standard` on its own. `lean-ai` without a prepared bundle is
  refused. `lean-x` takes the `lean` settings facts unchanged and puts no hook in the
  spec.

  `lean-ai` has the settings of `lean` and adds the learned parts
  (`LearnedRender.spec_parts/3`): `spec.learning`, `spec.locator`, `spec.rewrites`,
  `spec.learned`, the locator hook when the repository's replay gate passed, and the
  learned global pitfalls as rules, each replacing the static rule on its topic. A
  learned rule whose static rule is not there is left out, so the learned `CLAUDE.md`
  never has more lines than the static one; so is one that `CLAUDE.md` would withhold
  (`Economy.learned_line_kept?/1`), which keeps the static rule in place.
  `spec.learning.claude_md_lines` counts all three.
  """
  @spec build(map(), map(), String.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def build(profile, blueprint, mode, opts) when is_map(opts) do
    {commands, skipped} = safe_commands(profile["commands"], blueprint["denied_commands"])
    safe_profile = Map.put(profile, "commands", commands)
    agents = entries(mode, blueprint["agent"], safe_profile)
    skills = entries(mode, blueprint["skill"], safe_profile)

    with {:ok, requested, learned} <- requested_context(opts, mode, blueprint),
         {:ok, select} <- native_select(opts, requested) do
      parts =
        if learned, do: LearnedRender.spec_parts(learned, safe_profile, blueprint), else: nil

      # Team mode ships the blueprint's agent and skill; it generates no native item.
      select = if mode == "solo", do: select, else: "none"

      native =
        Native.build(safe_profile, blueprint, %{
          "select" => select,
          "candidates" => (parts && parts["native_candidates"]) || []
        })

      with {:ok, context} <-
             context(requested, blueprint, profile, agents ++ skills, native) do
        built =
          assemble(
            profile,
            blueprint,
            mode,
            safe_profile,
            skipped,
            agents ++ native["agents"],
            skills ++ native["skills"],
            context,
            parts,
            native_spec(native, select, context, blueprint, profile)
          )

        {:ok, built}
      end
    end
  end

  # The request's `native` option: absent means `none` for lean-x and `all` otherwise.
  defp native_select(opts, requested) do
    default = if requested == "lean-x", do: "none", else: "all"

    case Map.get(opts, "native", default) do
      select when is_binary(select) ->
        if select in Native.selects(),
          do: {:ok, select},
          else: native_error()

      _ ->
        native_error()
    end
  end

  defp native_error,
    do:
      {:error,
       %Error{
         code: "invalid_generation_request",
         message: "native must be all, skills, agents or none"
       }}

  # What the spec and the summary carry about the generated skills and subagents.
  defp native_spec(native, select, context, blueprint, profile) do
    kinds = native_kinds(native)
    cfg = blueprint["native"] || %{}

    %{
      "select" => select,
      "measured_on" => cfg["measured_on"],
      "history_head" => get_in(profile, ["native_evidence", "head"]),
      "items" => native["items"],
      "dropped" => native["dropped"],
      "test_runner_commands" => native["test_runner_commands"],
      "listing_bytes" => native["listing_bytes"],
      "cost" =>
        Native.cost(
          kept_kinds(kinds, context),
          native["listing_bytes"],
          context["profile"],
          blueprint
        ),
      "diagnostics" => native["diagnostics"]
    }
  end

  defp native_kinds(native),
    do: %{"skills" => native["skills"] != [], "agents" => native["agents"] != []}

  # The tools the native items make the profile keep: none in standard (nothing is
  # denied there) and none a repository's own files already keep.
  defp kept_kinds(_kinds, %{"kept_tools" => kept}) when is_list(kept),
    do: %{"skills" => "Skill" in kept, "agents" => "Task" in kept}

  defp kept_kinds(_kinds, _context), do: %{"skills" => false, "agents" => false}

  defp assemble(
         profile,
         blueprint,
         mode,
         safe_profile,
         skipped,
         agents,
         skills,
         context,
         parts,
         native
       ) do
    commands = safe_profile["commands"]
    name = slug(profile["name"])
    {candidates, commit_rules} = applicable(profile["rule_candidates"], blueprint)
    tools = tools(profile["tools"] || [], commands)
    static_rules = practice_rules(profile["practices"], blueprint) ++ rules(candidates)
    {learned_rules, replaced, line_counts} = learned_rules(parts, static_rules)

    # lean-x renders no SessionStart, UserPromptSubmit or Stop hook, so its spec lists none.
    hooks =
      if context["profile"] == "lean-x",
        do: [],
        else:
          order_hooks(
            hooks(commands, blueprint, tools) ++ if(parts, do: parts["hooks"], else: [])
          )

    spec = %{
      "apiVersion" => HarnessV2.api_version(),
      "kind" => "Harness",
      "metadata" => %{"name" => name, "version" => "0.1.0"},
      "spec" => %{
        "runtime" => %{"name" => "claude_code", "version" => "unqualified"},
        "scope" => %{"repositories" => [name]},
        "project" =>
          safe_profile
          |> Map.take(
            ~w(name languages frameworks package_managers commands layout conventions ci)
          )
          |> Map.merge(%{
            "tools" => tools,
            "test_pairs" => pairs(profile["test_pairs"], &{&1["source"], &1["test"]}),
            "cochange" => pairs(profile["cochange"], &{&1["path"], &1["partner"]})
          })
          |> Map.merge(practices(profile["practices"])),
        "context" => context,
        "guidance" => guidance(safe_profile, fixed_line(hooks, blueprint)),
        "rules" =>
          Enum.uniq_by(
            learned_rules ++ without_signals(static_rules, replaced),
            & &1["statement"]
          ),
        "goals" => [],
        "policies" => policies(mode, blueprint, skills),
        "agents" => agents,
        "skills" => skills,
        "hooks" => hooks,
        "permissions" => permissions(safe_profile, blueprint),
        "execution" => blueprint["execution"],
        "evaluation" => %{"suite" => "none"},
        "generation" => %{
          "mode" => mode,
          "profile_digest" => Profile.digest(profile),
          "overlay_digest" => nil,
          "blueprint_version" => Blueprint.version(blueprint)
        }
      }
    }

    spec =
      if native["items"] == [],
        do: spec,
        else: put_in(spec, ["spec", "native"], Map.delete(native, "diagnostics"))

    spec =
      if parts,
        do:
          update_in(
            spec,
            ["spec"],
            &Map.merge(
              &1,
              parts
              |> Map.take(~w(learning locator rewrites learned))
              |> put_in(["learning", "claude_md_lines"], line_counts)
            )
          ),
        else: spec

    %{
      "spec" => spec,
      "native" => native,
      "skipped_commands" => skipped,
      "excluded_candidates" => excluded(candidates, commit_rules),
      "diagnostics" =>
        profile
        |> diagnostics(commands, tools, hooks)
        |> runtime_check_diagnostics(context["profile"])
        |> Kernel.++(if(parts, do: parts["diagnostics"], else: []))
        |> Kernel.++(native["diagnostics"])
    }
  end

  # lean-x has no session-start or stop check at all, so the notices that explain why one
  # role is not checked would give the wrong reason; one notice says so instead.
  defp runtime_check_diagnostics(diagnostics, "lean-x") do
    Enum.reject(diagnostics, &(&1["code"] in ~w(probe_unknown stop_check_unavailable))) ++
      [
        %{
          "code" => "runtime_checks_not_rendered",
          "severity" => "info",
          "message" =>
            "The lean-x profile runs no environment check at session start and no format, lint or test check at stop."
        }
      ]
  end

  defp runtime_check_diagnostics(diagnostics, _profile), do: diagnostics

  # A learned rule replaces the static rule on its topic (never two deprecation lines),
  # and only that: with no static rule to replace, it is left out.
  defp learned_rules(nil, _static), do: {[], [], nil}

  defp learned_rules(parts, static) do
    present = MapSet.new(static, &get_in(&1, ["source", "signal"]))
    {placed, left_out} = Enum.split_with(parts["learned_rules"], &(&1["replaces"] in present))

    # A learned line that `CLAUDE.md` would withhold (a process line, say) keeps the static
    # line in place: replacing it would lose both.
    {kept, withheld} =
      Enum.split_with(placed, &Economy.learned_line_kept?(&1["rule"]["statement"]))

    {Enum.map(kept, & &1["rule"]), Enum.map(kept, & &1["replaces"]),
     %{
       "replacing" => length(kept),
       "left_out_no_static_line" => length(left_out),
       "left_out_withheld" => length(withheld)
     }}
  end

  defp without_signals(rules, []), do: rules

  defp without_signals(rules, signals),
    do: Enum.reject(rules, &(get_in(&1, ["source", "signal"]) in signals))

  # Context profile. Every value comes from the blueprint, which records the Claude Code
  # version the saving was measured on; nothing here is computed from repository input.
  defp requested_context(opts, mode, blueprint) do
    profiles = blueprint["context_profiles"]
    default = if mode == "solo", do: profiles["solo_default"], else: "standard"

    case Map.get(opts, "context", default) do
      %{"profile" => "lean-ai", "learned" => %{} = learned} ->
        {:ok, "lean-ai", learned}

      "lean-ai" ->
        {:error,
         %Error{
           code: "invalid_generation_request",
           message: "The lean-ai context profile needs a learned bundle (--learned)"
         }}

      name when name in @context_profiles ->
        {:ok, name, nil}

      _ ->
        {:error,
         %Error{
           code: "invalid_generation_request",
           message: "Context must be lean, standard, lean-ai or lean-x"
         }}
    end
  end

  defp context(requested, blueprint, profile, entries, native) do
    profiles = blueprint["context_profiles"]

    case requested do
      name when name in ["lean", "lean-ai", "lean-x"] and entries != [] ->
        {:error,
         %Error{
           code: "lean_profile_unavailable",
           message:
             "The #{name} context profile removes the subagent and skill tools, and this package has agents or skills. Use the standard profile.",
           details: [name]
         }}

      name ->
        {:ok, context_profile(name, profiles, profile, native, blueprint)}
    end
  end

  defp context_profile(name, profiles, profile, native, blueprint) do
    chosen = profiles[Map.get(@trim_from, name, name)]

    # A repository that tracks notebooks keeps the notebook tool.
    notebook =
      if "jupyter" in (profile["languages"] || []), do: chosen["notebook_tools"], else: []

    # A repository with its own subagents keeps Task; one with its own skills or commands
    # keeps Skill and Workflow (they are denied together or not at all). The measured
    # saving is for the full deny list only, so a kept tool makes it 0 here and the CLI
    # and portal say it was not measured.
    own = own_tools(get_in(profile, ["existing_harness", "files"]) || [])
    trimmed = chosen["deny_tools"] |> Kernel.--(notebook ++ own) |> Enum.uniq() |> Enum.sort()

    # Generated skills keep Skill and generated subagents keep Task; Workflow stays
    # denied (a skill loads and runs without it, measured on 2.1.311).
    kinds = native_kinds(native)

    kept =
      for {tool, kind} <- [{"Skill", "skills"}, {"Task", "agents"}],
          kinds[kind] and tool in trimmed,
          do: tool

    deny = trimmed -- kept
    native? = kinds["skills"] or kinds["agents"]

    saved =
      cond do
        own != [] and chosen["deny_tools"] != [] ->
          0

        kept != [] ->
          Native.saved_vs_none(
            %{"skills" => "Skill" in kept, "agents" => "Task" in kept},
            native["listing_bytes"],
            blueprint
          )

        true ->
          chosen["est_tokens_saved_per_request"]
      end

    context = %{
      "profile" => name,
      "include_git_instructions" => chosen["include_git_instructions"],
      "auto_memory" => chosen["auto_memory"],
      "deny_tools" => deny,
      "measured_on" => profiles["measured_on"],
      "est_tokens_saved_per_request" => saved
    }

    # disableBundledSkills removes the bundled skill listing; it goes on only while
    # Workflow is denied: with Workflow kept its description inlines the skill text
    # (+11,178 B measured). With Task kept for the generated subagents, the built-in
    # ones (general-purpose, Explore, statusline-setup) are denied by name, which takes
    # them out of the listing (-971 B measured on 2.1.311; the env switch
    # CLAUDE_AGENT_SDK_DISABLE_BUILTIN_AGENTS has no effect from project settings). A
    # repository's or a user's own skills and subagents stay listed either way.
    if native?,
      do:
        Map.merge(context, %{
          "kept_tools" => kept,
          "disable_bundled_skills" => "Skill" in kept and "Workflow" in deny,
          "disable_builtin_agents" => "Task" in kept
        }),
      else: context
  end

  defp own_tools(files) do
    own = Enum.filter(files, &HarnessForge.Analyzers.Instructions.own_agent_or_skill?/1)

    agents =
      if Enum.any?(own, &String.starts_with?(&1, ".claude/agents/")), do: ["Task"], else: []

    skills =
      if Enum.any?(own, &(not String.starts_with?(&1, ".claude/agents/"))),
        do: ["Skill", "Workflow"],
        else: []

    agents ++ skills
  end

  # A tool entry survives only while its role's command is still the project's command
  # (a denied command removes the entry with it).
  defp tools(entries, commands) do
    entries
    |> Enum.filter(fn entry ->
      entry["role"] in @tool_roles and
        (entry["role"] == "interpreter" or
           (is_binary(entry["command"]) and commands[entry["role"]] == entry["command"]))
    end)
    |> Enum.uniq_by(& &1["role"])
    |> Enum.sort_by(fn entry -> Enum.find_index(@tool_roles, &(&1 == entry["role"])) end)
    |> Enum.take(5)
  end

  defp pairs(nil, _key), do: []

  defp pairs(rows, key) do
    rows |> Enum.uniq_by(key) |> Enum.sort_by(key) |> Enum.take(@pair_cap)
  end

  defp diagnostics(profile, commands, tools, hooks) do
    dropped = profile["paths_dropped_charset"] || 0

    charset =
      if dropped > 0,
        do: [
          %{
            "code" => "paths_dropped_charset",
            "severity" => "info",
            "message" =>
              "#{rows(dropped)} left out because a path is outside the plain character set [A-Za-z0-9_./-]."
          }
        ],
        else: []

    probed = MapSet.new(tools, & &1["role"])

    unknown =
      for role <- ~w(test lint typecheck format),
          is_binary(commands[role]),
          not MapSet.member?(probed, role),
          do: role

    probes =
      if unknown == [],
        do: [],
        else: [
          %{
            "code" => "probe_unknown",
            "severity" => "info",
            "message" =>
              "No executable to check at session start could be derived for: #{Enum.join(unknown, ", ")}. A missing tool for these roles is not reported to the agent."
          }
        ]

    stopped = MapSet.new(hooks, & &1["role"])

    unchecked =
      for role <- @stop_roles,
          command = stop_source(role, commands),
          is_binary(command),
          not MapSet.member?(stopped, role),
          do: role

    stop =
      if unchecked == [],
        do: [],
        else: [
          %{
            "code" => "stop_check_unavailable",
            "severity" => "info",
            "message" =>
              "No check runs at stop for: #{Enum.join(unchecked, ", ")}. Their commands do not take file arguments, and running them on the whole project is not done at stop."
          }
        ]

    charset ++ probes ++ stop
  end

  defp rows(1), do: "1 test-pair or co-change row was"
  defp rows(count), do: "#{count} test-pair or co-change rows were"

  defp stop_source("test", commands), do: commands["test"] || commands["test_single"]
  defp stop_source(role, commands), do: commands[role]

  defp entries("solo", _entry, _profile), do: []
  defp entries(_mode, entry, profile), do: render_entries(entry, profile)

  defp applicable(candidates, blueprint) do
    if "git commit" in blueprint["denied_commands"] do
      Enum.split_with(candidates, &(not Regex.match?(@commit_rule, &1["text"])))
    else
      {candidates, []}
    end
  end

  defp render_entries(entry, profile) do
    case Blueprint.render(entry, profile) do
      nil -> []
      rendered -> [rendered]
    end
  end

  defp safe_commands(commands, denied) do
    Enum.reduce(commands, {commands, []}, fn
      {key, command}, {safe, skipped} when is_binary(command) ->
        if denied?(command, denied),
          do: {Map.put(safe, key, nil), [key | skipped]},
          else: {safe, skipped}

      _other, acc ->
        acc
    end)
    |> then(fn {safe, skipped} -> {safe, Enum.sort(skipped)} end)
  end

  @doc false
  # Mirrors how Claude Code applies a deny rule: past leading assignments, and
  # hardened against an absolute path to the same program.
  def denied?(command, denied) do
    normalized =
      command
      |> String.split(" ")
      |> Enum.drop_while(&Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*=/, &1))
      |> case do
        [program | rest] -> Enum.join([Path.basename(program) | rest], " ")
        [] -> ""
      end

    Enum.any?(denied, &(normalized == &1 or String.starts_with?(normalized, &1 <> " ")))
  end

  # Every candidate line stays in the spec; the renderer decides what reaches CLAUDE.md
  # and reports the rest. The fixed line is the generator's own sentence about the
  # stop hook, so it is true only when lint or format really runs there.
  defp guidance(profile, fixed) do
    [
      %{"id" => "commands", "title" => "Commands", "lines" => command_lines(profile["commands"])},
      %{
        "id" => "project-map",
        "title" => "Layout",
        "lines" => Enum.map(profile["layout"], &"`#{&1["path"]}`: #{&1["purpose"]}")
      },
      %{"id" => "conventions", "title" => "Conventions", "lines" => profile["conventions"]},
      %{"id" => "notes", "title" => "Notes", "lines" => List.wrap(fixed)}
    ]
    |> Enum.reject(&(&1["lines"] == []))
  end

  defp fixed_line(hooks, blueprint) do
    roles = MapSet.new(hooks, & &1["role"])
    lines = blueprint["guidance"]["fixed_lines"]

    case {MapSet.member?(roles, "lint"), MapSet.member?(roles, "format")} do
      {true, true} -> lines["lint_format"]
      {true, false} -> lines["lint"]
      {false, true} -> lines["format"]
      {false, false} -> nil
    end
  end

  defp command_lines(commands) do
    for {key, label} <- @command_labels,
        command = commands[key],
        not (key == "test_single" and command == commands["test"]),
        do: "#{label}: `#{command}#{argument_hint(key, command)}`"
  end

  # A detected single-test command is a prefix; the line says what must follow it.
  defp argument_hint("test_single", command) do
    cond do
      String.ends_with?(command, " -k") -> " <expr>"
      String.ends_with?(command, " -run") -> " <regex>"
      Regex.match?(~r/\b(?:mocha|jest|vitest|ava)\b/, command) -> " <file>"
      # The file form of a package script: `npm run <script> --`, `pnpm run <script>`.
      String.ends_with?(command, " --") -> " <file>"
      Regex.match?(~r/\A(?:pnpm|yarn) (?:test|run [A-Za-z0-9:._-]+)\z/, command) -> " <file>"
      true -> ""
    end
  end

  defp argument_hint(_key, _command), do: ""

  defp rules(candidates) do
    candidates
    |> Enum.filter(&(&1["bucket"] == "auto"))
    |> Enum.sort_by(&{-&1["confidence"], &1["text"]})
    |> Enum.uniq_by(& &1["text"])
    |> Enum.map(&rule/1)
  end

  @practice_keys ~w(deprecation_sites deprecation_files removal_phrases policy_sentences warnings_as_errors)

  defp practices(%{} = counts), do: %{"practices" => Map.take(counts, @practice_keys)}
  defp practices(_), do: %{}

  # A practice fires on the counts and the stack blueprint's thresholds alone; the rule
  # says the blueprint's fixed sentence. A stack without a sentence for a practice (or a
  # threshold) never emits it.
  defp practice_rules(%{} = counts, blueprint) do
    config = blueprint["practices"] || %{}
    texts = config["rules"] || %{}
    thresholds = config["thresholds"] || %{}

    for id <- @practice_ids,
        practice_fired?(id, counts, thresholds),
        text = texts[id],
        is_binary(text) and text != "" do
      fingerprint = Contracts.sha256(text)

      %{
        "id" => uuid("rule:" <> fingerprint),
        "origin" => "derived",
        "statement" => text,
        "fingerprint" => fingerprint,
        "source" => %{
          "detector" => "practices",
          "signal" => "practices." <> id,
          "path" => nil,
          "line" => nil
        }
      }
    end
    |> Enum.take(@max_practice_rules)
  end

  defp practice_rules(_counts, _blueprint), do: []

  defp practice_fired?("deprecation", counts, thresholds) do
    at_least?(counts["deprecation_sites"], thresholds["deprecation_sites"]) or
      at_least?(counts["policy_sentences"], thresholds["policy_sentences"])
  end

  defp practice_fired?("warnings_as_errors", counts, _thresholds),
    do: counts["warnings_as_errors"] == true

  defp at_least?(count, threshold)
       when is_integer(count) and is_integer(threshold) and threshold > 0,
       do: count >= threshold

  defp at_least?(_count, _threshold), do: false

  defp rule(candidate) do
    fingerprint = Contracts.sha256(candidate["text"])

    %{
      "id" => uuid("rule:" <> fingerprint),
      "origin" => "derived",
      "statement" => candidate["text"],
      "fingerprint" => fingerprint,
      "source" => source(candidate["citations"])
    }
  end

  defp source(citations) do
    citations
    |> Enum.sort_by(&{&1["detector"], &1["signal"], &1["path"] || "", &1["line"] || 0})
    |> hd()
    |> Map.take(~w(detector signal path line))
  end

  # A stable UUID-shaped identifier; the schema requires the shape, not randomness.
  defp uuid(seed) do
    <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
      e::binary-size(12), _rest::binary>> = Contracts.sha256(seed)

    Enum.join([a, b, c, d, e], "-")
  end

  defp excluded(candidates, commit_rules) do
    counts =
      candidates |> Enum.reject(&(&1["bucket"] == "auto")) |> Enum.frequencies_by(& &1["bucket"])

    if commit_rules == [],
      do: counts,
      else: Map.put(counts, "commit_denied", length(commit_rules))
  end

  # Solo mode runs hands-free, so the shell is allowed as a whole: an unattended session
  # refuses every call Claude Code would ask about, and a list of command prefixes never
  # covers `cd dir && git ...`, a heredoc or `sed -i` with escapes. The deny rules and the
  # guard hook still refuse the dangerous calls (both run before any allow rule).
  defp policies(mode, blueprint, skills) do
    # The Skill tool needs a rule to run unattended; Agent does not.
    tools =
      blueprint["tool_allow"] ++
        if(mode == "solo", do: ["bash"], else: []) ++
        if(skills == [], do: [], else: ["skill"])

    Enum.map(tools, fn tool ->
      %{
        "id" => "allow-" <> tool,
        "required" => false,
        "capability" => "tool_permissions." <> tool,
        "value" => "allow"
      }
    end)
  end

  # The stop hook checks only what changed: format and lint the changed files, run the
  # changed tests and their history partners. So a role gets a hook only when its
  # command takes file arguments; the hook carries the command's argv prefix (trailing
  # path arguments such as `.` or `tests` removed), and the script appends the files.
  # The environment check runs at session start when there is a tool to probe.
  defp hooks(commands, blueprint, tools) do
    timeouts = blueprint["hook_timeouts"]
    table = blueprint["stop_file_arguments"]

    env =
      if tools == [],
        do: [],
        else: [
          %{
            "id" => "env-check",
            "event" => "session_start",
            "builtin" => "env_check",
            "timeout_seconds" => timeouts["env_check"]
          }
        ]

    stop =
      for role <- @stop_roles, command = stop_command(role, commands, table) do
        %{
          "id" => role <> "-before-stop",
          "event" => "before_stop",
          "role" => role,
          "command" => command,
          "file_argument" => true,
          "selector" => @selectors[role],
          "timeout_seconds" => timeouts[role]
        }
      end

    order_hooks(env ++ stop)
  end

  defp order_hooks(hooks) do
    Enum.sort_by(hooks, fn hook ->
      {@event_order[hook["event"]], Map.get(@role_order, hook["role"], -1), hook["id"]}
    end)
  end

  defp stop_command("test", commands, table) do
    # A one-test command in file form (not `pytest -k`) names the runner with the
    # project's flags; the suite command comes next.
    [commands["test_single"], commands["test"]]
    |> Enum.filter(&is_binary/1)
    |> Enum.find_value(&file_command(&1, table["test"], table))
  end

  defp stop_command(role, commands, table) do
    case commands[role] do
      command when is_binary(command) -> file_command(command, table[role], table)
      _ -> nil
    end
  end

  @doc false
  # The argv prefix of `command` that takes file arguments, or nil: a known runner
  # (`uv run --group lint`, `npx`), then a tool from the role's table, then its own
  # arguments with trailing path words (`.`, `tests`, `src/pkg`) removed. A flag's value
  # is never removed, and a command ending in a test-selection flag (`pytest -k`) is
  # refused, since the first file would become that flag's value.
  def file_command(command, tools, table) do
    tokens = String.split(command, " ", trim: true)
    {runner, rest} = split_runner(tokens, table)
    phrases = tools |> Enum.map(&String.split(&1, " ")) |> Enum.sort_by(&(-length(&1)))

    with words when is_list(words) <- Enum.find(phrases, &(Enum.take(rest, length(&1)) == &1)),
         args =
           rest
           |> Enum.drop(length(words))
           |> Enum.reverse()
           |> strip_paths(table)
           |> Enum.reverse(),
         false <- List.last(args) in table["selection_flags"] do
      Enum.join(runner ++ words ++ args, " ")
    else
      _ -> nil
    end
  end

  defp split_runner(tokens, table) do
    runner =
      table["runners"]
      |> Enum.map(&String.split(&1, " "))
      |> Enum.filter(&(Enum.take(tokens, length(&1)) == &1))
      |> Enum.max_by(&length/1, fn -> [] end)

    {flags, rest} = runner_flags(Enum.drop(tokens, length(runner)), table, [])
    {runner ++ flags, rest}
  end

  defp runner_flags([flag, value | rest], table, acc) do
    cond do
      flag in table["runner_flags_with_value"] -> runner_flags(rest, table, [value, flag | acc])
      String.starts_with?(flag, "-") -> runner_flags([value | rest], table, [flag | acc])
      true -> {Enum.reverse(acc), [flag, value | rest]}
    end
  end

  defp runner_flags(tokens, _table, acc), do: {Enum.reverse(acc), tokens}

  defp strip_paths([last | rest] = reversed, table) do
    previous = List.first(rest)

    if path_word?(last, table) and not (is_binary(previous) and value_flag?(previous, table)),
      do: strip_paths(rest, table),
      else: reversed
  end

  defp strip_paths([], _table), do: []

  defp path_word?(token, table) do
    not String.starts_with?(token, "-") and
      (token in [".", "./"] or String.contains?(token, "/") or token in table["path_words"])
  end

  defp value_flag?(token, table) do
    String.starts_with?(token, "-") and not String.contains?(token, "=") and
      token not in table["boolean_flags"]
  end

  # An unattended agent needs no approval for ordinary reads, edits, searches and the
  # project's own toolchain, so the allow list is the detected commands, the shell
  # utilities every project uses and the toolchain forms agents actually type
  # (`uv run --no-sync pytest`, bare `pytest`, `python3 - <<EOF`). Anything that can
  # destroy work, publish, or reach another machine is denied.
  defp permissions(profile, blueprint) do
    commands = profile["commands"]

    project =
      for {key, _label} <- @command_labels, command = commands[key] do
        rule = %{"id" => "project." <> key, "command" => command, "action" => "allow"}
        if key == "install", do: Map.put(rule, "exact", true), else: rule
      end

    routine = allow_rules(blueprint["routine_commands"], "routine")
    toolchain = allow_rules(toolchain(blueprint, profile), "toolchain")

    deny =
      blueprint["denied_commands"]
      |> indexed("deny")
      |> Enum.map(fn {id, command} ->
        %{"id" => id, "command" => command, "action" => "deny"}
      end)

    edits =
      for {pattern, index} <- Enum.with_index(blueprint["edit_paths"] || []) do
        %{
          "id" => "project.edit.#{index}",
          "pattern" => pattern,
          "access" => "edit",
          "action" => "allow"
        }
      end

    %{
      "commands" =>
        (project ++ routine ++ toolchain)
        |> Enum.uniq_by(& &1["command"])
        |> without_redundant()
        |> Kernel.++(deny)
        |> Enum.uniq_by(& &1["command"]),
      "paths" => edits ++ secret_paths(blueprint["secret_paths"])
    }
  end

  defp allow_rules(commands, prefix) do
    commands
    |> indexed(prefix)
    |> Enum.map(fn {id, command} -> %{"id" => id, "command" => command, "action" => "allow"} end)
  end

  # `Bash(uv run:*)` already allows `uv run pytest -k x`.
  defp without_redundant(rules) do
    prefixes = for rule <- rules, not Map.has_key?(rule, "exact"), do: rule["command"] <> " "

    Enum.reject(rules, fn rule ->
      Enum.any?(prefixes, &String.starts_with?(rule["command"], &1))
    end)
  end

  # The stack's interpreter and test runners, reached the way agents reach them: the
  # runner of a detected package manager or of a detected command (any arguments,
  # `uv run --no-sync` included), the interpreter itself, and each tool a detected
  # command names, bare, because an activated environment puts it on PATH. None of it
  # is more capable than the test command, which already runs project code.
  defp toolchain(%{"toolchain" => chain}, profile) do
    commands = profile["commands"] |> Map.values() |> Enum.filter(&is_binary/1)
    words = commands |> Enum.flat_map(&String.split(&1, " ")) |> MapSet.new()
    managers = profile["package_managers"] || []

    chain["commands"] ++
      Enum.flat_map(chain["package_managers"], fn {manager, prefixes} ->
        if manager in managers, do: prefixes, else: []
      end) ++
      Enum.filter(chain["runners"], fn runner ->
        Enum.any?(commands, &String.starts_with?(&1, runner <> " "))
      end) ++
      Enum.filter(chain["tools"], &MapSet.member?(words, &1))
  end

  defp toolchain(_blueprint, _profile), do: []

  defp secret_paths(patterns) do
    for {pattern, index} <- Enum.with_index(patterns), access <- ~w(read edit) do
      %{
        "id" => "secret.#{access}.#{index}",
        "pattern" => pattern,
        "access" => access,
        "action" => "deny"
      }
    end
  end

  defp indexed(items, prefix) do
    items |> Enum.with_index() |> Enum.map(fn {item, index} -> {"#{prefix}.#{index}", item} end)
  end

  defp slug(name) do
    cleaned =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_-]+/, "-")
      |> String.trim("-")

    prefixed = if Regex.match?(~r/^[a-z]/, cleaned), do: cleaned, else: "repo-" <> cleaned

    prefixed |> String.slice(0, 64) |> String.trim_trailing("-")
  end
end
