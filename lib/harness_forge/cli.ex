defmodule HarnessForge.CLI do
  @moduledoc """
  Offline command entry point. The application must own the workspace lock.

  `analyze` and `generate` have their own output: a short text summary, or the usual
  JSON envelope with `--json`. Their exit status is 0 on success, 1 when the operation
  failed, 2 for a usage error and 3 for a runtime or mode this build does not generate.
  """
  alias HarnessForge.{Analyzers, Demo, Decisions, Evidence, Generation, Goals, Harnesses}
  alias HarnessForge.Workspaces
  alias HarnessForge.Contracts.Error

  @repository_commands ~w(analyze generate)
  @analyze_switches [json: :boolean]
  @generate_switches [
    json: :boolean,
    runtime: :string,
    export: :string,
    context: :string,
    learned: :string,
    native: :string
  ]
  # Switches that may be left out.
  @optional_switches [:json, :context, :learned, :native]
  @context_profiles ~w(lean standard lean-ai lean-x)
  @native_selects ~w(all skills agents none)
  @usage_analyze "analyze ABSOLUTE_PATH [--json]"
  @usage_generate "generate ABSOLUTE_PATH --runtime claude_code --export FRESH_DIRECTORY [--context lean|standard|lean-ai|lean-x] [--learned BUNDLE_DIRECTORY] [--native all|skills|agents|none] [--json]"
  @guidance_report ".olivium/guidance-provenance.json"
  # Shown by the `native` summary line instead of as a notice.
  @native_notices ~w(native_none_generated)
  @explained_notices ~w(guidance_withheld paths_dropped_charset probe_unknown stop_check_unavailable ai_policy_detected ai_learning_unavailable locator_gate_failed learned_terms_off learned_item_dropped_at_render learned_native_invalid claude_md_not_rendered runtime_checks_not_rendered bash_output_shaped)
  @path_limit 4096

  # `learn` has its own summary, exit codes (0 written, 1 I/O, 2 usage) and --json envelope.
  def main(["learn" | args]), do: HarnessForge.CLI.Learn.main(args)

  def main([command | args] = argv) when command in @repository_commands do
    json? = json_output?(args)

    case run(argv) do
      {:ok, value} ->
        IO.puts(
          if json?,
            do: Jason.encode!(%{"ok" => true, "result" => value}),
            else: summary(command, value)
        )

      {:error, reason} ->
        failure = describe(reason)
        IO.puts(:stderr, failure_output(failure, json?))
        System.halt(exit_status(failure["error"]))
    end
  end

  def main(args) do
    case run(args) do
      {:ok, value} ->
        IO.puts(Jason.encode!(%{"ok" => true, "result" => value}))

      {:error, reason} ->
        IO.puts(:stderr, Jason.encode!(%{"ok" => false, "error" => error_message(reason)}))
        System.halt(1)
    end
  end

  def run(["init"]),
    do: {:ok, %{"workspace_id" => Workspaces.current_id(), "root" => Workspaces.root()}}

  def run(["status"]) do
    {:ok,
     %{
       "workspace_id" => Workspaces.current_id(),
       "elixir" => System.version(),
       "otp" => System.otp_release(),
       "runtime_qualified" => false
     }}
  end

  def run(["demo"]), do: Demo.load()
  def run(["sources"]), do: Evidence.list_sources()
  def run(["claims"]), do: Evidence.list_claims()
  def run(["goals"]), do: Goals.list_goals()

  def run(["company", "profile"]), do: HarnessForge.Company.get_profile()
  def run(["company", "repositories"]), do: HarnessForge.Company.list_repositories()
  def run(["company", "projects"]), do: HarnessForge.Company.list_projects()
  def run(["company", "plans"]), do: HarnessForge.Company.list_plans()
  def run(["company", "search", query]), do: HarnessForge.Company.search_capabilities(query)
  def run(["company", "consumers", id]), do: HarnessForge.Company.consumers(id)

  def run(["company", kind, path]) when kind in ~w(profile repository project plan) do
    with {:ok, attrs} <- read_company_json(path) do
      case kind do
        "profile" -> HarnessForge.Company.save_profile(attrs)
        "repository" -> HarnessForge.Company.create_repository(attrs)
        "project" -> HarnessForge.Company.create_project(attrs)
        "plan" -> HarnessForge.Company.create_plan(attrs)
      end
    end
  end

  def run(["company", "decide", id, decision, hash]) when decision in ~w(approve reject) do
    HarnessForge.Company.decide_plan(id, %{
      "actor" => "local-operator",
      "decision" => decision,
      "expected_revision_hash" => hash
    })
  end

  def run(["company", "build", id, hash]) do
    with {:ok, artifact} <- Harnesses.build_plan(id, hash),
         do: {:ok, Map.take(artifact, ~w(digest manifest capabilities diagnostics))}
  end

  def run(["goal", path]) do
    with {:ok, attrs} <- read_company_json(path), do: Goals.add_goal(attrs)
  end

  def run(["connect", "local", name, directory]),
    do: Evidence.connect(%{"provider" => "local", "name" => name, "directory" => directory})

  def run(["connect", "github", name, repository]),
    do:
      Evidence.connect(%{
        "provider" => "github",
        "name" => name,
        "config" => %{"repository" => repository}
      })

  def run(["connect", "github", name, repository, reference]),
    do:
      Evidence.connect(%{
        "provider" => "github",
        "name" => name,
        "config" => %{"repository" => repository, "credential_ref" => reference}
      })

  def run(["connect", "jira", name, endpoint, project, username, credential]),
    do:
      Evidence.connect(%{
        "provider" => "jira",
        "name" => name,
        "config" => %{
          "endpoint" => endpoint,
          "project" => project,
          "username_ref" => username,
          "credential_ref" => credential
        }
      })

  def run(["connect", "github_projects", name, project_url, reference]),
    do:
      Evidence.connect(%{
        "provider" => "github_projects",
        "name" => name,
        "config" => %{"project_url" => project_url, "credential_ref" => reference}
      })

  def run(["connect", "slack", name, team, channel, reference]),
    do:
      Evidence.connect(%{
        "provider" => "slack",
        "name" => name,
        "config" => %{"team_id" => team, "channel_id" => channel, "credential_ref" => reference}
      })

  def run(["connect", "confluence", name, endpoint, space, username, credential]),
    do:
      Evidence.connect(%{
        "provider" => "confluence",
        "name" => name,
        "config" => %{
          "endpoint" => endpoint,
          "space_id" => space,
          "username_ref" => username,
          "credential_ref" => credential
        }
      })

  def run(["runtimes"]), do: {:ok, HarnessForge.Adapters.Registry.list()}
  def run(["chat-connectors"]), do: HarnessForge.Chat.catalog()
  def run(["chat", question]), do: HarnessForge.Chat.ask(question)

  def run(["chat", question, "assistant"]), do: HarnessForge.Chat.ask(question, mode: :assistant)

  def run(["chat", question, mode]) when mode in ~w(evidence model),
    do: HarnessForge.Chat.ask(question, mode: if(mode == "model", do: :model, else: :evidence))

  def run(["model", "status"]), do: {:ok, HarnessForge.Models.status()}

  def run(["model", "configure", path]) do
    with {:ok, stat} <- File.stat(path),
         true <- stat.type == :regular and stat.size <= 65_536,
         {:ok, bytes} <- File.read(path),
         true <- byte_size(bytes) <= 65_536,
         {:ok, config} when is_map(config) <- Jason.decode(bytes) do
      HarnessForge.Models.configure(config)
    else
      _ -> {:error, :invalid_model_configuration}
    end
  end

  def run(["model", name]),
    do:
      HarnessForge.Models.configure(%{
        "provider" => "ollama",
        "endpoint" => "http://127.0.0.1:11434",
        "model" => name
      })

  def run(["propose", id]), do: HarnessForge.Models.propose(id)
  def run(["sync", id]), do: Evidence.sync(id)

  def run(["decide", id, decision, hash]) do
    Decisions.decide(id, %{
      "actor" => Workspaces.operator(),
      "decision" => decision,
      "expected_revision_hash" => hash
    })
  end

  def run(["build", name, version]) do
    with {:ok, artifact} <- Harnesses.build(%{"name" => name, "version" => version}) do
      {:ok, Map.take(artifact, ["digest", "manifest", "capabilities", "diagnostics"])}
    end
  end

  def run(["build", name, version, runtime]),
    do: build_target(name, version, runtime, "unqualified")

  def run(["build", name, version, runtime, runtime_version]),
    do: build_target(name, version, runtime, runtime_version)

  def run(["export", digest, target]), do: Harnesses.export(digest, target)

  def run(["evaluate", digest, kind]) when kind in ~w(static_integrity runtime_smoke task),
    do: HarnessForge.Evaluations.run(digest, kind: kind)

  def run(["runs"]), do: HarnessForge.Evaluations.list_runs()

  def run(["compare", baseline, candidate]),
    do: HarnessForge.Evaluations.compare(baseline, candidate)

  def run(["cancel", id]), do: HarnessForge.Evaluations.cancel(id)
  def run(["releases"]), do: HarnessForge.Releases.list()

  def run(["approve-release", digest, evaluation]) do
    with {:ok, artifact} <- Harnesses.get(digest),
         do:
           HarnessForge.Releases.approve(%{
             "artifact_digest" => digest,
             "evaluation_id" => evaluation,
             "scope" => artifact["spec"]["spec"]["scope"],
             "actor" => Workspaces.operator()
           })
  end

  def run(["promote", id]), do: HarnessForge.Releases.promote(id)
  def run(["promote", id, expected]), do: HarnessForge.Releases.promote(id, expected)
  def run(["rollback", id, expected]), do: HarnessForge.Releases.rollback(id, expected)
  def run(["diff", left, right]), do: HarnessForge.Releases.diff(left, right)
  def run(["inventory"]), do: HarnessForge.Privacy.inventory()
  def run(["backup", target]), do: HarnessForge.Privacy.backup(target)
  def run(["restore", backup, target]), do: HarnessForge.Privacy.restore(backup, target)

  def run(["purge-source", id, confirmation]),
    do: HarnessForge.Privacy.purge_source(id, confirmation)

  def run(["purge", confirmation]), do: HarnessForge.Privacy.purge_workspace(confirmation)

  def run(["analyze" | args]) do
    with {:ok, %{"path" => path}} <- repository_arguments(args, @analyze_switches, @usage_analyze),
         {:ok, root} <- repository_root(path),
         {:ok, signals} <- Analyzers.Repository.analyze(root),
         {:ok, profile} <- Analyzers.Mapping.profile(signals) do
      {:ok,
       %{
         "repository" => signals["repository"],
         "detectors" => signals["detectors"],
         "profile" => profile,
         "signals" => signals["signals"]
       }}
    end
  end

  def run(["generate" | args]) do
    with {:ok, %{"path" => path, "runtime" => runtime, "export" => target} = arguments} <-
           repository_arguments(args, @generate_switches, @usage_generate),
         {:ok, request} <- generate_request(arguments, runtime),
         {:ok, request} <- native_request(request, arguments),
         {:ok, root} <- repository_root(path),
         {:ok, request} <- learned_context(request, root),
         {:ok, generated} <- Generation.generate(Map.put(request, "root", root)),
         {:ok, exported} <- Harnesses.export(generated["digest"], target) do
      spec = get_in(generated, ["artifact", "spec", "spec"]) || %{}

      {:ok,
       generated
       |> Map.take(
         ~w(digest target mode profile_digest blueprint_version files counts skipped_commands diagnostics context)
       )
       |> Map.put("export", exported["path"])
       |> Map.put("guidance", Map.drop(generated["guidance"] || %{}, ["dropped"]))
       |> Map.put("native", generated["native"])
       |> put_learned(spec)}
    end
  end

  def run(["learn" | args]), do: HarnessForge.CLI.Learn.run(args)

  def run(["help"]) do
    {:ok,
     %{
       "commands" => [
         "init",
         "serve",
         "status",
         @usage_analyze,
         HarnessForge.CLI.Learn.usage(),
         @usage_generate,
         "demo",
         "sources",
         "claims",
         "goals",
         "goal CONFIG_JSON_FILE",
         "company profile|repositories|projects|plans",
         "company profile|repository|project|plan CONFIG_JSON_FILE",
         "company search QUERY",
         "company consumers REPOSITORY_ID",
         "company decide PLAN_ID approve|reject REVISION_HASH",
         "company build PLAN_ID REVISION_HASH",
         "sync CONNECTION_ID",
         "decide CLAIM_ID approve|reject REVISION_HASH",
         "build NAME VERSION [opencode|codex|claude_code [RUNTIME_VERSION]]",
         "runtimes",
         "chat-connectors",
         "chat QUESTION [assistant|evidence|model]",
         "model status",
         "model configure CONFIG_JSON_FILE",
         "export DIGEST FRESH_DIRECTORY",
         "connect local NAME DIRECTORY",
         "connect github NAME OWNER/REPO [TOKEN_ENV_REF]",
         "connect jira NAME ENDPOINT PROJECT EMAIL_ENV_REF TOKEN_ENV_REF",
         "connect github_projects NAME PROJECT_URL TOKEN_ENV_REF",
         "connect slack NAME TEAM_ID CHANNEL_ID TOKEN_ENV_REF",
         "connect confluence NAME ENDPOINT SPACE_ID EMAIL_ENV_REF TOKEN_ENV_REF",
         "model INSTALLED_OLLAMA_MODEL",
         "propose SOURCE_ID",
         "evaluate DIGEST static_integrity|runtime_smoke|task",
         "runs",
         "compare BASELINE_RUN_ID CANDIDATE_RUN_ID",
         "cancel RUN_ID",
         "releases",
         "approve-release DIGEST EVALUATION_ID",
         "promote RELEASE_ID [EXPECTED_CURRENT_ID]",
         "rollback RELEASE_ID EXPECTED_CURRENT_ID",
         "diff BASELINE_DIGEST CANDIDATE_DIGEST",
         "inventory",
         "backup FRESH_DIRECTORY",
         "restore BACKUP_DIRECTORY FRESH_WORKSPACE",
         "purge-source SOURCE_ID SOURCE_ID",
         "purge WORKSPACE_ID"
       ],
       "ownership" =>
         "Stop the portal before offline mutation commands; a second owner is rejected."
     }}
  end

  def run(_), do: {:error, :unknown_command}

  defp read_company_json(path) do
    with {:ok, %{type: :regular, size: size}} when size <= 262_144 <- File.stat(path),
         {:ok, bytes} <- File.read(path),
         {:ok, attrs} when is_map(attrs) <- HarnessForge.Contracts.decode_json(bytes) do
      {:ok, attrs}
    else
      _ -> {:error, :invalid_company_config}
    end
  end

  defp build_target(name, version, runtime, runtime_version) do
    with {:ok, artifact} <-
           Harnesses.build(%{
             "name" => name,
             "version" => version,
             "runtime" => runtime,
             "runtime_version" => runtime_version
           }),
         do: {:ok, Map.take(artifact, ["digest", "manifest", "capabilities", "diagnostics"])}
  end

  # analyze and generate require a real repository: history is what makes the output
  # worth having, so a plain directory or an unusable git is refused visibly.
  defp repository_arguments(args, switches, usage) do
    case OptionParser.parse(args, strict: switches) do
      {options, [path], []} ->
        keys = Keyword.keys(switches)
        required = keys -- @optional_switches
        optional = Enum.filter(keys, &(&1 in @optional_switches and &1 != :json))

        cond do
          not valid_path?(path) ->
            usage_error("PATH must be an absolute path", usage)

          Enum.any?(required, &(length(Keyword.get_values(options, &1)) != 1)) ->
            usage_error("Each of #{option_names(required)} is required once", usage)

          true ->
            given = Enum.filter(required ++ optional, &Keyword.has_key?(options, &1))

            {:ok,
             Map.new(given, &{Atom.to_string(&1), Keyword.fetch!(options, &1)})
             |> Map.put("path", path)}
        end

      _ ->
        usage_error("Unexpected arguments", usage)
    end
  end

  # The context profile is checked here so a typo is a usage error (exit 2), not a
  # generation failure; the generator checks it again. lean-ai takes a learned bundle
  # (`learn` output) and nothing else does.
  defp generate_request(arguments, runtime) do
    learned = Map.get(arguments, "learned")

    case Map.fetch(arguments, "context") do
      {:ok, "lean-ai"} when is_nil(learned) ->
        usage_error("--context lean-ai needs --learned BUNDLE_DIRECTORY", @usage_generate)

      {:ok, "lean-ai"} ->
        if valid_path?(learned),
          do: {:ok, %{"target" => runtime, "context" => "lean-ai", "learned" => learned}},
          else: usage_error("--learned must be an absolute path", @usage_generate)

      _ when not is_nil(learned) ->
        usage_error("--learned is used only with --context lean-ai", @usage_generate)

      :error ->
        {:ok, %{"target" => runtime}}

      {:ok, context} when context in @context_profiles ->
        {:ok, %{"target" => runtime, "context" => context}}

      {:ok, _} ->
        usage_error(
          "--context must be lean or standard, or lean-x, or lean-ai with --learned BUNDLE_DIRECTORY",
          @usage_generate
        )
    end
  end

  # `--native` picks which generated skills and subagents the package keeps; a typo is a
  # usage error (exit 2). Left out, the generator's default applies (`all`, or `none`
  # for lean-x).
  defp native_request(request, %{"native" => select}) when select in @native_selects,
    do: {:ok, Map.put(request, "native", select)}

  defp native_request(_request, %{"native" => _}),
    do: usage_error("--native must be all, skills, agents or none", @usage_generate)

  defp native_request(request, _arguments), do: {:ok, request}

  # The bundle is read and checked, its base checked against HEAD, and the index and
  # the locator gate built from git, before anything is generated. A bad bundle is
  # learned_invalid and a base that is not HEAD or an ancestor learned_base_mismatch
  # (exit 1).
  defp learned_context(%{"context" => "lean-ai", "learned" => dir} = request, root) do
    with {:ok, prepared} <- Generation.LearnedRender.prepare(root, dir) do
      {:ok,
       request
       |> Map.delete("learned")
       |> Map.put("context", %{"profile" => "lean-ai", "learned" => prepared})}
    end
  end

  defp learned_context(request, _root), do: {:ok, request}

  defp put_learned(result, %{"learning" => learning, "locator" => locator}) do
    result
    |> Map.put("learning", learning)
    |> Map.put(
      "locator",
      Map.take(locator, ~w(rendered status replay_n top3_hits wrong max_card_bytes))
    )
  end

  defp put_learned(result, _spec), do: result

  defp option_names(required), do: Enum.map_join(required, ", ", &"--#{&1}")

  defp valid_path?(path) do
    String.valid?(path) and byte_size(path) <= @path_limit and not String.contains?(path, <<0>>) and
      Path.type(path) == :absolute
  end

  defp usage_error(message, usage) do
    {:error, %Error{code: "invalid_arguments", message: "#{message}. Usage: #{usage}"}}
  end

  defp repository_root(path) do
    with {:ok, root} <- Analyzers.Git.real_directory(path) do
      case Analyzers.Git.availability(root) do
        %{"status" => "available"} ->
          {:ok, root}

        %{"reason" => "not_a_repository"} ->
          {:error, %Error{code: "not_a_git_repository", message: "PATH is not a git repository"}}

        %{"reason" => reason} ->
          {:error,
           %Error{
             code: "git_unavailable",
             message: "git cannot be used for this repository",
             details: [reason]
           }}
      end
    end
  end

  defp json_output?(args) do
    {options, _, _} = OptionParser.parse(args, strict: @generate_switches)
    Keyword.get(options, :json, false)
  end

  defp describe(%Error{} = error) do
    %{"ok" => false, "error" => error.code, "message" => error.message}
    |> then(fn base ->
      case Enum.filter(error.details || [], &is_binary/1) do
        [] -> base
        details -> Map.put(base, "details", details)
      end
    end)
  end

  defp describe(reason), do: %{"ok" => false, "error" => error_message(reason)}

  defp failure_output(failure, true), do: Jason.encode!(failure)

  defp failure_output(%{"error" => code, "message" => message}, false),
    do: "error: #{code}: #{message}"

  defp failure_output(%{"error" => code}, false), do: "error: #{code}"

  defp exit_status("invalid_arguments"), do: 2
  defp exit_status(code) when code in ~w(unsupported_runtime unsupported_mode), do: 3
  defp exit_status(_), do: 1

  defp summary("analyze", %{"repository" => repository, "profile" => profile}) do
    commands = for {key, command} <- Enum.sort(profile["commands"]), command, do: {key, command}
    auto = Enum.count(profile["rule_candidates"], &(&1["bucket"] == "auto"))

    Enum.join(
      [
        "repository  #{repository["identity"]}",
        "head        #{repository["head"] || "none"}",
        "languages   #{Enum.join(profile["languages"], ", ")}",
        "commands    #{length(commands)}"
      ] ++
        Enum.map(commands, fn {key, command} -> "  #{String.pad_trailing(key, 11)} #{command}" end) ++
        [
          "conventions #{length(profile["conventions"])}",
          "rules       #{auto} auto, #{length(profile["rule_candidates"]) - auto} held back"
        ],
      "\n"
    )
  end

  defp summary("generate", value) do
    Enum.join(
      [
        "digest      #{value["digest"]}",
        "exported    #{value["export"]}",
        "files       #{length(value["files"])}",
        "rules       #{value["counts"]["rules"]}",
        "hooks       #{value["counts"]["hooks"]}",
        "commands    #{value["counts"]["allowed_commands"]} allowed, #{value["counts"]["denied_commands"]} denied"
      ] ++
        guidance_lines(value["guidance"]) ++
        native_lines(value["native"]) ++
        context_lines(value["context"]) ++
        learning_lines(value["learning"], value["locator"]) ++
        notice_lines(Enum.reject(value["diagnostics"] || [], &(&1["code"] in @native_notices))),
      "\n"
    )
  end

  # Generation facts are explained in full; the export's standing caveats are named by
  # code only (their full text is in --json and .olivium/capabilities.json).
  defp notice_lines(diagnostics) do
    {explained, named} = Enum.split_with(diagnostics, &(&1["code"] in @explained_notices))

    Enum.map(explained, &"notice      #{&1["code"]}: #{&1["message"]}") ++
      if named == [],
        do: [],
        else: [
          "caveats     #{Enum.map_join(named, ", ", & &1["code"])} (full text: --json or .olivium/capabilities.json)"
        ]
  end

  # What CLAUDE.md costs on every model request, and what it left out.
  defp guidance_lines(%{"rendered_bytes" => bytes, "est_tokens_per_request" => tokens} = report)
       when is_integer(bytes) and is_integer(tokens) do
    withheld = length(report["withheld"] || [])

    price =
      if bytes == 0,
        do: "0 bytes the model reads, 0 tokens per request",
        else:
          "#{delimited(bytes)} bytes the model reads, about #{delimited(tokens)} tokens on every request"

    [
      "CLAUDE.md   #{price}; #{withheld} #{lines(withheld)} withheld (reasons: #{@guidance_report})"
    ]
  end

  defp guidance_lines(_), do: []

  # The generated Claude Code skills and subagents (design section 5): what each lists
  # on every request and loads on use, and what they cost together. The cost is the
  # measured figure for this configuration, never the lean saving.
  defp native_lines(%{"items" => items} = native) when is_list(items) do
    {skills, agents} = Enum.split_with(items, &(&1["kind"] == "skill"))

    skill_line =
      if skills == [],
        do: [],
        else: [
          "skills      #{length(skills)}: " <>
            Enum.map_join(skills, ", ", fn item ->
              "#{item["name"]} (#{listed_bytes(item)} B listed, #{delimited(item["body_bytes"])} B on use)"
            end)
        ]

    agent_line =
      if agents == [],
        do: [],
        else: [
          "agents      #{length(agents)}: " <>
            Enum.map_join(agents, ", ", &"#{&1["name"]} (#{Enum.join(&1["tools"] || [], ", ")})")
        ]

    cost =
      if items == [],
        do: ["native      none generated#{native_reasons(native)}"],
        else: [
          "native      about #{delimited(native["est_tokens_per_request"])} tokens on every model request " <>
            "for these (measured on #{measured_on(native["measured_on"])}); --native none removes them"
        ]

    skill_line ++ agent_line ++ cost ++ subagent_cost_line(agents, native)
  end

  defp native_lines(_), do: []

  # A subagent call is paid on its own requests, per turn it takes. A lean profile that
  # keeps Task denies Claude Code's built-in subagents by name, which takes their listing
  # off every request; the standard profile keeps them listed.
  defp subagent_cost_line(
         [_ | _],
         %{"subagent_turn_tokens" => %{"min" => low, "max" => high}} = native
       ) do
    [
      "subagents   each call costs about #{delimited(low)}-#{delimited(high)} tokens per turn of its own, " <>
        "not in the figure above; " <> builtin_agents_text(native)
    ]
  end

  defp subagent_cost_line(_agents, _native), do: []

  defp builtin_agents_text(%{"builtin_agents_denied" => [_ | _] = names} = native) do
    "Claude Code's built-in subagents (#{Enum.join(names, ", ")}) are denied by name, which takes " <>
      "about #{delimited(native["builtin_agents_denied_tokens"])} tokens off every request (included above); " <>
      "your own and the repository's skills and subagents stay listed"
  end

  defp builtin_agents_text(_native),
    do: "Claude Code's built-in subagents stay listed, and the figure above includes them"

  # The bytes one item adds to the listing Claude Code sends on every request.
  defp listed_bytes(item) do
    byte_size(item["name"]) + (item["description_bytes"] || 0) + 4
  end

  defp native_reasons(native) do
    case (native["dropped"] || []) |> Enum.map(& &1["reason"]) |> Enum.uniq() |> Enum.sort() do
      [] -> ""
      reasons -> " (#{Enum.join(reasons, ", ")})"
    end
  end

  defp context_lines(%{"profile" => "lean"} = context) do
    names = context["deny_tools"] || []

    [
      "Context profile: lean (removes git instructions and #{length(names)} tools no recorded " <>
        "benchmark run used#{Generation.Economy.lost_capabilities(names)}: " <>
        "#{Enum.join(names, ", ")}#{kept(context)}; #{saving(context)}). " <>
        "This is a settings change you could also make by hand. Use --context standard to keep them."
    ]
  end

  defp context_lines(%{"profile" => "lean-ai"} = context) do
    names = context["deny_tools"] || []

    [
      "Context profile: lean-ai (the lean settings, removing git instructions and #{length(names)} tools " <>
        "no recorded benchmark run used#{Generation.Economy.lost_capabilities(names)}, plus what was " <>
        "learned from this repository's history: a local index, a prompt-time locator when its replay " <>
        "gate passes, verified command rewrites and learned pitfalls). Experimental: on development " <>
        "tasks it used 0.96x the tokens of the lean settings alone, a difference within noise."
    ]
  end

  defp context_lines(%{"profile" => "lean-x"} = context) do
    names = context["deny_tools"] || []

    [
      "Context profile: lean-x (the lean settings, removing git instructions and #{length(names)} tools " <>
        "no recorded benchmark run used#{Generation.Economy.lost_capabilities(names)}, plus the guard, " <>
        "a Bash output shaper that shortens long lines and long test output and runs tests in the " <>
        "foreground, and a four-line output style; no CLAUDE.md). Experimental: on 7 development tasks " <>
        "it used 0.80x the tokens of the lean settings alone with the same solve rate; not tested on " <>
        "held-out tasks or on a macOS host."
    ]
  end

  defp context_lines(%{"profile" => "standard"}) do
    [
      "Context profile: standard (keeps git instructions and every Claude Code tool). " <>
        "Use --context lean to remove git instructions and the tools no recorded benchmark " <>
        "run used from every model request."
    ]
  end

  defp context_lines(_), do: []

  defp kept(%{"kept_tools" => [_ | _] = kept}) do
    uses =
      for {tool, use} <- [{"Skill", "skills"}, {"Task", "subagents"}], tool in kept, do: use

    "; keeps #{Enum.join(kept, ", ")} for the generated #{Enum.join(uses, " and ")}"
  end

  defp kept(_), do: ""

  # With generated skills or subagents the profile keeps their tools, and the saving is
  # the measured one for that tool set less what the listing adds (Spec.context_profile).
  defp saving(%{"est_tokens_saved_per_request" => saved, "kept_tools" => [_ | _]} = context)
       when is_integer(saved) and saved > 0 do
    "about #{delimited(saved)} fewer tokens on every model request than no settings, estimated " <>
      "from measurements on #{measured_on(context["measured_on"])} for this tool set and listing"
  end

  defp saving(%{"est_tokens_saved_per_request" => saved} = context)
       when is_integer(saved) and saved > 0 do
    "about #{delimited(saved)} fewer tokens on every model request, measured on " <>
      measured_on(context["measured_on"])
  end

  defp saving(_context) do
    "keeps the tools this repository's own subagents or skills need; the saving for this tool set " <>
      "was not measured"
  end

  # The two lines the e2e tests and the bench grep (contract 2.2).
  defp learning_lines(%{} = learning, %{} = locator) do
    kept = learning["kept"] |> Map.values() |> Enum.sum()
    dropped = learning["dropped"] + learning["dropped_at_render"]

    [
      "AI learning: #{learning["status"]} (#{learning["model"]}, $#{dollars(learning["cost_nanousd"])}, " <>
        "#{delimited(learning["tokens_total"])} tokens), #{kept} kept, #{dropped} dropped",
      "Locator: #{if locator["rendered"], do: "on", else: "off"} (top-3 #{locator["top3_hits"]}/#{locator["replay_n"]}, " <>
        "wrong #{locator["wrong"]}/#{locator["replay_n"]})"
    ]
  end

  defp learning_lines(_learning, _locator), do: []

  # Nanodollars as dollars with 4 decimals, rounded half up; integers only.
  defp dollars(nanousd) when is_integer(nanousd) and nanousd >= 0 do
    units = div(nanousd + 50_000, 100_000)

    "#{div(units, 10_000)}.#{units |> rem(10_000) |> Integer.to_string() |> String.pad_leading(4, "0")}"
  end

  defp lines(1), do: "line"
  defp lines(_), do: "lines"

  defp measured_on("claude-code " <> version), do: "Claude Code " <> version
  defp measured_on(other) when is_binary(other), do: other
  defp measured_on(_), do: "an unrecorded Claude Code version"

  defp delimited(number) when is_integer(number) do
    number
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp error_message(%Error{code: code}), do: code
  defp error_message(%{message: message}) when is_binary(message), do: message
  defp error_message(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_message(_), do: "operation_failed"
end
