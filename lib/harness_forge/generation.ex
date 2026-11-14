defmodule HarnessForge.Generation do
  @moduledoc """
  Hands-free generation: profile to blueprint to spec to compile to publish.

  Input is a string-keyed map with `"root"` (a local repository path) or `"profile"`
  (a RepoProfile), an optional `"target"` (default `claude_code`), an optional
  `"mode"` (default `solo`) and an optional `"context"` (`"lean"`, the solo default, or
  `"standard"`). `lean` is refused for a package with agents or skills, never swapped
  for `standard`. `plan/1` stops after compiling and writes nothing.
  `generate/2` also publishes the content-addressed artifact and audits
  `harness.generated`. Export stays with `Harnesses.export/2`.

  Generated rules are `derived`; solo mode creates no claims or decisions. Codex,
  OpenCode and team mode are visibly unsupported on this path, never substituted.
  Nothing from the repository is executed.
  """

  alias HarnessForge.{Analyzers, Artifacts, Audit, Compiler, Repo, Workspaces}
  alias HarnessForge.Contracts.Error
  alias HarnessForge.Generation.{Blueprint, Native, Profile, Spec}

  @target "claude_code"
  @guidance_report ".olivium/guidance-provenance.json"
  @analysis_timeout_ms 120_000
  @ai_policy_signal "instructions.ai_policy"
  # The summary always shows the native context keys; the spec carries them only when a
  # skill or subagent was generated.
  @context_defaults %{
    "kept_tools" => [],
    "disable_bundled_skills" => false,
    "disable_builtin_agents" => false
  }

  @doc "Compile a package without publishing it."
  @spec plan(map()) :: {:ok, map()} | {:error, Error.t()}
  def plan(request) when is_map(request) do
    with {:ok, build} <- build(request), do: {:ok, summary(build)}
  end

  @doc "Compile, publish and audit a package. `:artifact_root` is a trusted test option."
  @spec generate(map(), keyword()) :: {:ok, map()} | {:error, Error.t() | term()}
  def generate(request, opts \\ []) when is_map(request) do
    with {:ok, build} <- build(request),
         :ok <- Workspaces.ensure_writable(),
         {:ok, _} <- publish(build, opts) do
      {:ok, summary(build)}
    end
  end

  defp build(request) do
    with {:ok, target} <- target(request),
         {:ok, mode} <- mode(request),
         {:ok, profile} <- profile(request),
         blueprint = Blueprint.select(profile),
         {:ok, built} <- Spec.build(profile, blueprint, mode, context_option(request)),
         {:ok, artifact} <- Compiler.compile(built["spec"]) do
      {:ok, Map.merge(built, %{"artifact" => artifact, "profile" => profile, "target" => target})}
    end
  end

  # Absent means the mode's default profile and native selection (`all`, or `none` for
  # lean-x); any other value is checked by `Spec.build/4`.
  defp context_option(request), do: Map.take(request, ["context", "native"])

  defp target(request) do
    case Map.get(request, "target", @target) do
      @target ->
        {:ok, @target}

      target when is_binary(target) ->
        {:error,
         %Error{
           code: "unsupported_runtime",
           message: "Generated packages are only supported for claude_code in this build",
           details: [target]
         }}

      _ ->
        invalid_request("Target must be a runtime name")
    end
  end

  defp mode(request) do
    case Map.get(request, "mode", "solo") do
      "solo" ->
        {:ok, "solo"}

      "team" ->
        {:error,
         %Error{
           code: "unsupported_mode",
           message: "Team mode generation is not available in this build",
           details: ["team"]
         }}

      _ ->
        invalid_request("Mode must be solo or team")
    end
  end

  defp profile(%{"root" => _, "profile" => _}),
    do: invalid_request("Provide either root or profile, not both")

  defp profile(%{"profile" => profile}), do: Profile.validate(profile)

  defp profile(%{"root" => root}) when is_binary(root) do
    with {:ok, signals} <- analyze(root),
         {:ok, profile} <- Analyzers.Mapping.profile(signals) do
      Profile.validate(profile)
    end
  end

  defp profile(_), do: invalid_request("Provide a repository root or a profile")

  # A repository is untrusted input, and the file caps alone do not bound CPU time.
  defp analyze(root) do
    limit = Application.get_env(:harness_forge, :analysis_timeout_ms, @analysis_timeout_ms)
    task = Task.async(fn -> Analyzers.Repository.analyze(root) end)

    case Task.yield(task, limit) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      _ ->
        {:error,
         %Error{code: "analysis_timeout", message: "Repository analysis exceeded its time limit"}}
    end
  end

  defp invalid_request(message),
    do: {:error, %Error{code: "invalid_generation_request", message: message}}

  defp publish(%{"artifact" => artifact} = build, opts) do
    publish_opts =
      case Keyword.fetch(opts, :artifact_root) do
        {:ok, root} -> [root: root]
        :error -> []
      end

    Repo.transaction(fn ->
      with {:ok, _} <- Artifacts.publish(artifact, publish_opts),
           {:ok, _} <- Audit.append("harness.generated", audit_details(build)) do
        :ok
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp audit_details(%{"artifact" => artifact} = build) do
    %{
      "artifact_digest" => artifact["digest"],
      "profile_digest" => Profile.digest(build["profile"]),
      "status" => "generated",
      "count" => length(artifact["spec"]["spec"]["rules"])
    }
  end

  defp summary(%{"artifact" => artifact} = build) do
    spec = artifact["spec"]["spec"]

    %{
      "digest" => artifact["digest"],
      "target" => build["target"],
      "mode" => spec["generation"]["mode"],
      "profile" => build["profile"],
      "profile_digest" => spec["generation"]["profile_digest"],
      "blueprint_version" => spec["generation"]["blueprint_version"],
      "files" => artifact["manifest"]["files"],
      "artifact" => artifact,
      "context" => Map.merge(@context_defaults, spec["context"] || %{}),
      "native" => native_summary(build["native"], spec),
      "guidance" => guidance_report(artifact),
      "counts" => %{
        "rules" => length(spec["rules"]),
        "agents" => length(spec["agents"]),
        "skills" => length(spec["skills"]),
        "hooks" => length(spec["hooks"]),
        "allowed_commands" => Enum.count(spec["permissions"]["commands"], &allowed?/1),
        "denied_commands" => Enum.count(spec["permissions"]["commands"], &(not allowed?(&1)))
      },
      "skipped_commands" => build["skipped_commands"],
      "excluded_candidates" => build["excluded_candidates"],
      "existing_harness" => build["profile"]["existing_harness"]["files"],
      "diagnostics" =>
        artifact["diagnostics"] ++ build["diagnostics"] ++ ai_policy_diagnostics(build["profile"])
    }
  end

  # The policy is for the person generating the package; CLAUDE.md no longer asks the
  # agent to read it first (it cost a turn per run and changed no patch).
  defp ai_policy_diagnostics(profile) do
    paths =
      for candidate <- profile["rule_candidates"],
          citation <- candidate["citations"],
          citation["signal"] == @ai_policy_signal,
          uniq: true,
          do: citation["path"]

    Enum.map(paths, fn path ->
      %{
        "code" => "ai_policy_detected",
        "severity" => "warning",
        "message" =>
          "#{path} sets this project's rules for AI tools. Read it before running an agent unattended."
      }
    end)
  end

  defp allowed?(%{"action" => action}), do: action == "allow"

  # The contract the CLI and the portal read (design section 3.4).
  defp native_summary(native, spec) do
    entries =
      Map.new(spec["skills"] ++ spec["agents"], fn entry -> {entry["name"], entry} end)

    items =
      Enum.map(native["items"], fn item ->
        entry = entries[item["name"]]
        commits = Enum.uniq(item["evidence"]["commits"] ++ item["evidence"]["fix_commits"])

        %{
          "name" => item["name"],
          "kind" => item["kind"],
          "template" => item["template"],
          "origin" => item["origin"],
          "path" => item["path"],
          "description" => entry["description"],
          "description_bytes" => item["description_bytes"],
          "body_bytes" => item["body_bytes"],
          "evidence_commits" => item["evidence_commits"],
          "evidence" => Enum.take(commits, 5)
        }
        |> then(&if(item["kind"] == "agent", do: Map.put(&1, "tools", entry["tools"]), else: &1))
      end)

    %{
      "select" => native["select"],
      "items" => items,
      "listing_bytes" => native["listing_bytes"],
      "est_tokens_per_request" => native["cost"]["est_tokens_per_request"],
      "est_tokens_per_request_low" => native["cost"]["est_tokens_per_request_low"],
      "measured_on" => native["measured_on"],
      "dropped" => native["dropped"],
      "test_runner_commands" => native["test_runner_commands"],
      "cost" => native["cost"],
      # Claude Code's built-in subagents the lean settings deny by name (Task kept), and
      # the tokens that takes off every request; [] and 0 when they stay listed.
      "builtin_agents_denied" =>
        if((native["cost"]["builtin_agents_denied_tokens"] || 0) > 0,
          do: Native.builtin_agents(),
          else: []
        ),
      "builtin_agents_denied_tokens" => native["cost"]["builtin_agents_denied_tokens"] || 0
    }
    |> then(fn summary ->
      if Enum.any?(items, &(&1["kind"] == "agent")),
        do: Map.put(summary, "subagent_turn_tokens", Native.subagent_turn_tokens(nil)),
        else: summary
    end)
  end

  defp guidance_report(%{"files" => files}) do
    case files do
      %{@guidance_report => bytes} -> Jason.decode!(bytes)
      _ -> nil
    end
  end
end
