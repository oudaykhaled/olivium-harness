defmodule HarnessForge.Learning do
  @moduledoc """
  `learn`: learn from a repository's history, once per base commit, into a frozen,
  content-addressed bundle (`learned.json`, schema `olivium.learned/v1`).

  Steps (design.md section 3):

    1. `Learning.Extract` builds `history-extract/v1` from HEAD and its ancestors only.
    2. `Learning.Launcher` runs the AI learner (Claude Code in Docker behind a meter):
       live only with `allow_cloud` and a key file; mock with a scripted plan. Without
       either, the learner is `unavailable` (`cloud_not_allowed`) and no model runs.
    3. `Learning.Bundle.check_raw/2` applies the schema, path and evidence checks, also to
       the proposed skills (`area`) and agents (`locator`, `test_runner`), which are data
       only: paths, symbol names, ids and evidence hashes.
    4. `Learning.Verify` checks commands and rewrites in Docker with network none; a
       pitfall that names a tool verification proved missing is then dropped
       (`tool_missing`), and an agent that names a command id verification did not keep
       is dropped (`not_verified`).
    5. `Learning.Bundle` finalizes and writes the bundle into a fresh directory, with the
       run report, the extract, the learner's raw output and its transcript beside it
       (the transcript lets anyone audit what the learner read and ran).

  Whatever the learner status, a bundle is written and its status says what happened:
  `unavailable` and `failed` bundles keep only verified deterministic commands and
  rewrites, which is the `olivium-det` ablation. Nothing is quietly static.
  """

  alias HarnessForge.Contracts
  alias HarnessForge.Contracts.Error
  alias HarnessForge.Learning.{Bundle, Extract, Launcher, Verify}

  @prompt_path Path.expand("../../priv/learner/prompt-v2.md", __DIR__)
  @settings_path Path.expand("../../priv/learner/settings.json", __DIR__)
  @external_resource @prompt_path
  @external_resource @settings_path
  @prompt File.read!(@prompt_path)
  @settings File.read!(@settings_path)
  @prompt_id "learner-prompt/v2"
  @learner_image "olivium-bench-learner:v1"
  @meter_image "olivium-bench-meter:v1"
  @version_label "olivium.claude-code-version"
  @timeout_ms 900_000

  @spec prompt_sha256() :: String.t()
  def prompt_sha256, do: Contracts.sha256(@prompt)

  @spec prompt() :: binary()
  def prompt, do: @prompt

  @spec default_learner_image() :: String.t()
  def default_learner_image, do: @learner_image

  @spec default_meter_image() :: String.t()
  def default_meter_image, do: @meter_image

  @doc """
  Learn from the repository at `root` (HEAD is the base) and write the bundle to `out`.

  Options: `:verify_image` (required), `:allow_cloud`, `:key_file`, `:model`,
  `:cap_nanousd`, `:max_turns`, `:meter` (`{:image, tag}` or `{:url, url, network}`),
  `:learner_image`, `:mock_plan` (bytes), `:docker_env`; for tests `:launcher` (a
  function replacing `Launcher.run/1`) and `:verify_runner` (see `Verify.run/1`).
  """
  @spec learn(Path.t(), Path.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def learn(root, out, opts) do
    with :ok <- Bundle.ensure_fresh(out),
         {:ok, extract} <- Extract.build(root) do
      ctx = Launcher.context(env: opts[:docker_env] || [])
      learner = run_learner(extract, ctx, opts)
      {learner, learned, raw_report} = check_learned(learner, extract)

      {det_commands, det_drops} = Bundle.deterministic_commands(extract.doc)

      verified =
        Verify.run(%{
          ctx: ctx,
          image: opts[:verify_image],
          extract: extract,
          commands: det_commands ++ learned.commands,
          rewrites: learned.rewrites,
          tools: Bundle.named_tools(extract.doc),
          runner: opts[:verify_runner]
        })

      {pitfalls, tool_drops} =
        Bundle.drop_missing_tool_pitfalls(learned.pitfalls, verified.rewrites)

      {agents, agent_drops} = Bundle.resolve_agents(learned.agents, verified.commands)

      doc =
        Bundle.finalize(%{
          repository: extract.doc["repository"],
          input: %{
            "extract_version" => Extract.version(),
            "sha256" => extract.sha256,
            "bytes" => extract.bytes
          },
          learner: learner_record(learner, opts),
          verification: verified.verification,
          concepts: learned.concepts,
          pitfalls: pitfalls,
          commands: verified.commands,
          rewrites: verified.rewrites,
          skills: learned.skills,
          agents: agents,
          dropped: learned.dropped ++ tool_drops ++ agent_drops ++ det_drops ++ verified.dropped
        })

      report = %{
        "schema" => "olivium.learn-report/v1",
        "bundle_sha256" => doc["sha256"],
        "extract" => %{"sha256" => extract.sha256, "bytes" => extract.bytes},
        "learner" =>
          Map.merge(learner.report, %{
            "status" => learner.status,
            "status_reason" => learner.reason,
            "wall_ms_exact" => learner.wall_ms,
            "requests" => learner.requests,
            "tokens" => learner.tokens,
            "cost_nanousd" => learner.cost_nanousd
          }),
        "raw" => raw_report,
        "verification" => verified.report
      }

      extra =
        [
          {"learn-report.json", Jason.encode!(report, pretty: true) <> "\n"},
          {"learn-input.json", extract.json}
        ] ++
          if(learner.raw, do: [{"learner-raw.json", learner.raw}], else: []) ++
          if(is_binary(learner[:transcript]),
            do: [{"learner-transcript.jsonl", learner.transcript}],
            else: []
          )

      with {:ok, written} <- Bundle.write(out, doc, extra) do
        {:ok, summary(doc, written, report)}
      end
    end
  end

  defp run_learner(extract, ctx, opts) do
    cond do
      is_binary(opts[:mock_plan]) ->
        launch(extract, ctx, :mock, opts)

      opts[:allow_cloud] == true and is_binary(opts[:key_file]) ->
        launch(extract, ctx, :live, opts)

      true ->
        %{
          status: "unavailable",
          reason: "cloud_not_allowed",
          raw: nil,
          requests: 0,
          tokens: zero_tokens(),
          cost_nanousd: 0,
          wall_ms: 0,
          report: %{},
          mode: :none
        }
    end
  end

  defp launch(extract, ctx, mode, opts) do
    spec = %{
      ctx: ctx,
      extract: extract,
      prompt: @prompt,
      settings: @settings,
      plan: if(mode == :mock, do: opts[:mock_plan]),
      mode: mode,
      model: opts[:model] || "claude-haiku-5-5",
      max_turns: opts[:max_turns] || 15,
      cap_nanousd: opts[:cap_nanousd] || default_cap(opts[:model]),
      timeout_ms: @timeout_ms,
      learner_image: opts[:learner_image] || @learner_image,
      meter: opts[:meter] || {:image, @meter_image},
      key_file: if(mode == :live, do: opts[:key_file])
    }

    launcher = opts[:launcher] || (&Launcher.run/1)

    spec
    |> launcher.()
    |> Map.put(:mode, mode)
    |> Map.put(
      :engine_version,
      if(opts[:launcher],
        do: "2.1.311",
        else: Launcher.image_label(ctx, spec.learner_image, @version_label)
      )
    )
  end

  @doc "Default cost cap per learning run: $0.50 for Sonnet, $0.10 for Haiku."
  @spec default_cap(String.t() | nil) :: non_neg_integer()
  def default_cap("claude-sonnet-5-5"), do: 500_000_000
  def default_cap(_), do: 100_000_000

  defp zero_tokens, do: %{"input" => 0, "output" => 0, "cache_read" => 0, "cache_write" => 0}

  defp check_learned(%{status: status, raw: raw} = learner, extract)
       when status in ["ok", "mock"] and is_binary(raw) do
    case Bundle.check_raw(raw, extract) do
      {:ok, checked} ->
        {learner, checked, checked.report}

      {:error, reason} ->
        {%{learner | status: "failed", reason: reason, raw: raw}, empty(), %{"error" => reason}}
    end
  end

  defp check_learned(learner, _extract), do: {learner, empty(), %{}}

  defp empty,
    do: %{
      concepts: [],
      pitfalls: [],
      commands: [],
      rewrites: [],
      skills: [],
      agents: [],
      dropped: []
    }

  defp learner_record(learner, opts) do
    ran? = learner.mode in [:mock, :live]
    allowed? = learner.mode != :none

    model =
      cond do
        learner.mode == :mock -> "mock"
        learner.mode == :live -> opts[:model] || "claude-haiku-5-5"
        true -> "none"
      end

    started? = ran? and learner.status != "unavailable"

    %{
      "status" => learner.status,
      "status_reason" => learner.reason,
      "engine" => if(started?, do: "claude-code", else: "none"),
      "engine_version" => if(started?, do: learner[:engine_version] || "", else: ""),
      "model" => if(allowed?, do: model, else: "none"),
      "prompt_id" => @prompt_id,
      "prompt_sha256" => prompt_sha256(),
      "max_turns" => if(allowed?, do: opts[:max_turns] || 15, else: 0),
      "cap_nanousd" => if(allowed?, do: opts[:cap_nanousd] || default_cap(opts[:model]), else: 0),
      "requests" => learner.requests,
      "tokens" => learner.tokens,
      "cost_nanousd" => learner.cost_nanousd,
      # Mock timings are not real work; live wall time goes in 10 s steps (exact value in
      # learn-report.json), so the bundle bytes repeat.
      "wall_ms" => if(learner.mode == :live, do: Bundle.bucket_ms(learner.wall_ms), else: 0)
    }
  end

  defp summary(doc, written, report) do
    kinds = ~w(concepts pitfalls commands rewrites skills agents)

    %{
      "bundle" => written["path"],
      "dir" => written["dir"],
      "sha256" => doc["sha256"],
      "file_sha256" => written["file_sha256"],
      "repository" => doc["repository"],
      "learner" => doc["learner"],
      "verification" => doc["verification"],
      "kept" => Map.new(kinds, &{&1, length(Map.get(doc, &1, []))}),
      "kept_sources" =>
        Map.new(~w(commands rewrites), fn kind ->
          {kind, doc[kind] |> Enum.map(& &1["source"]) |> Enum.frequencies()}
        end),
      "dropped" => doc["dropped"] |> Enum.map(& &1["reason"]) |> Enum.frequencies(),
      "dropped_kinds" => doc["dropped"] |> Enum.map(& &1["kind"]) |> Enum.frequencies(),
      "dropped_items" => length(doc["dropped"]),
      "report" => Path.join(written["dir"], "learn-report.json"),
      "learner_wall_ms" => report["learner"]["wall_ms_exact"]
    }
  end
end
