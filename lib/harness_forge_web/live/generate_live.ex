defmodule HarnessForgeWeb.GenerateLive do
  @moduledoc """
  One screen from a repository path to an exportable Claude Code harness.

  The pipeline runs in a task so the page stays responsive. Each stage reports its
  status to the view, and every element that a browser test or recording targets has
  a stable id. Copy is limited to labels: the numbers, meters and preview carry it.

  The context profile is chosen next to the path (`lean`, the solo default,
  `standard`, or `lean-ai`), and the result shows what CLAUDE.md costs on every model
  request, how many lines it withheld and what the profile removes.

  `lean-ai` also takes the folder of a learned bundle (`bin/harnessforge learn --out`),
  read and checked against the repository before anything is generated. The result then
  shows the same two lines as the CLI: the AI learning status, model, cost, tokens and
  kept and dropped items, and whether the locator passed its replay gate. A bundle whose
  learner did not run is shown as such, with its warning; nothing is quietly static.

  The skills and subagents generated from the repository's history (`all`, the default,
  `skills`, `agents` or `none`, as `--native` in the CLI) are listed with what each adds
  to every request and loads on use, and their measured cost together. When none is
  generated the page says so and why.
  """
  use HarnessForgeWeb, :live_view

  alias HarnessForge.Analyzers.{Git, Mapping, Repository}
  alias HarnessForge.Contracts.Error
  alias HarnessForge.{Generation, Harnesses, Workspaces}
  alias HarnessForgeWeb.Plugs.OperatorSession

  @nodes [
    {"detect", "Detect", 12.5},
    {"analyze", "Analyze", 37.5},
    {"generate", "Generate", 62.5},
    {"export", "Export", 87.5}
  ]
  @stages Enum.map(@nodes, &elem(&1, 0))
  @command_order ~w(test test_single lint format typecheck build install run)
  @context_profiles ~w(lean standard lean-ai)
  @default_context "lean"
  @native_selects ~w(all skills agents none)
  @default_native "all"
  # Facts about this generation (contract section 7), shown with the warnings.
  @generation_notices ~w(guidance_withheld paths_dropped_charset probe_unknown stop_check_unavailable
                         locator_gate_failed learned_terms_off learned_item_dropped_at_render
                         learned_native_invalid)
  @path_limit 4096
  @target "claude_code"

  @impl true
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, _session, socket) do
    if connected?(socket),
      do: Phoenix.PubSub.subscribe(HarnessForge.PubSub, "workspace:" <> Workspaces.current_id())

    {:ok,
     assign(socket,
       page_title: "Generate",
       path: "",
       context: @default_context,
       native: @default_native,
       learned: "",
       run: 0,
       state: "idle",
       export_state: "idle",
       stages: idle_stages(),
       error: nil,
       package: nil,
       export: nil,
       export_target: ""
     )}
  end

  @impl true
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("generate", %{"generate" => %{"path" => path} = params}, socket)
      when is_binary(path) do
    if busy?(socket),
      do: {:noreply, socket},
      else:
        {:noreply,
         start_generate(
           socket,
           path,
           context(params["context"]),
           native(params["native"]),
           learned(params["learned"])
         )}
  end

  # Shows the bundle field only for lean-ai; nothing runs.
  def handle_event("pick", %{"generate" => params}, socket) when is_map(params) do
    {:noreply,
     assign(socket,
       context: context(params["context"]),
       native: native(params["native"]),
       path: learned(params["path"]) || socket.assigns.path,
       learned: learned(params["learned"]) || socket.assigns.learned
     )}
  end

  def handle_event("export", %{"export" => %{"target" => target}}, socket)
      when is_binary(target) do
    if busy?(socket) or is_nil(socket.assigns.package),
      do: {:noreply, socket},
      else: {:noreply, start_export(socket, target)}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  @spec handle_info(term(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info({:stage, run, stage, status}, %{assigns: %{run: run}} = socket),
    do: {:noreply, put_stage(socket, stage, status)}

  def handle_info(:operator_session_revoked, socket), do: {:noreply, revoke(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  @spec handle_async(term(), term(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_async({kind, run}, result, %{assigns: %{run: run}} = socket)
      when kind in [:generate, :export] do
    cond do
      not OperatorSession.valid?(socket.assigns.operator_auth) -> {:noreply, revoke(socket)}
      kind == :generate -> {:noreply, finish_generate(socket, result)}
      true -> {:noreply, finish_export(socket, result)}
    end
  end

  def handle_async(_key, _result, socket), do: {:noreply, socket}

  defp busy?(socket),
    do: socket.assigns.state == "running" or socket.assigns.export_state == "running"

  defp revoke(socket), do: redirect(socket, to: "/login")

  # Generation

  # Only the known profiles; anything else falls back to the visible default.
  defp context(value) when value in @context_profiles, do: value
  defp context(_), do: @default_context

  defp native(value) when value in @native_selects, do: value
  defp native(_), do: @default_native

  # A bounded text field value (the path or the bundle folder), or nil.
  defp learned(value) when is_binary(value) and byte_size(value) <= @path_limit,
    do: String.trim(value)

  defp learned(_), do: nil

  defp start_generate(socket, input, context, native, learned) do
    path = String.trim(input)
    learned = learned || ""
    run = socket.assigns.run + 1

    socket =
      assign(socket,
        run: run,
        path: path,
        context: context,
        native: native,
        learned: learned,
        state: "running",
        export_state: "idle",
        stages: idle_stages(),
        error: nil,
        package: nil,
        export: nil,
        export_target: ""
      )

    cond do
      not usable_path?(path) ->
        fail(
          socket,
          "detect",
          %Error{code: "invalid_repository_path", message: "Enter an absolute path"}
        )

      context == "lean-ai" and not usable_path?(learned) ->
        fail(
          socket,
          "generate",
          %Error{
            code: "invalid_generation_request",
            message:
              "lean-ai needs the absolute path of a learned bundle folder (bin/harnessforge learn --out)"
          }
        )

      true ->
        view = self()
        bundle = if context == "lean-ai", do: learned

        start_async(socket, {:generate, run}, fn ->
          pipeline(path, {context, native}, bundle, view, run)
        end)
    end
  end

  defp usable_path?(path),
    do: bounded_text?(path) and Path.type(path) == :absolute

  defp bounded_text?(text) do
    String.valid?(text) and text != "" and byte_size(text) <= @path_limit and
      not String.contains?(text, <<0>>)
  end

  defp pipeline(path, context, learned, view, run) do
    step = fn stage, work ->
      send(view, {:stage, run, stage, "running"})

      case work.() do
        {:ok, _} = done ->
          send(view, {:stage, run, stage, "done"})
          done

        {:error, reason} ->
          {:error, {stage, reason}}
      end
    end

    with {:ok, root} <- step.("detect", fn -> detect(path) end),
         {:ok, profile} <- step.("analyze", fn -> analyze(root) end),
         {:ok, generated} <-
           step.("generate", fn -> generate(root, profile, context, learned) end) do
      {:ok, {root, generated}}
    end
  end

  # lean-ai: the bundle is read, checked against HEAD and the locator gate replayed
  # from git first (learned_invalid, learned_base_mismatch), as in the CLI.
  defp generate(root, profile, {"lean-ai", native}, learned) do
    with {:ok, prepared} <- Generation.LearnedRender.prepare(root, learned) do
      Generation.generate(%{
        "profile" => profile,
        "target" => @target,
        "context" => %{"profile" => "lean-ai", "learned" => prepared},
        "native" => native
      })
    end
  end

  defp generate(_root, profile, {context, native}, _learned) do
    Generation.generate(%{
      "profile" => profile,
      "target" => @target,
      "context" => context,
      "native" => native
    })
  end

  defp detect(path) do
    with {:ok, root} <- Git.real_directory(path) do
      case Git.availability(root) do
        %{"status" => "available"} ->
          {:ok, root}

        %{"reason" => "not_a_repository"} ->
          {:error, %Error{code: "not_a_git_repository", message: "Not a git repository"}}

        %{"reason" => reason} ->
          {:error, %Error{code: "git_unavailable", message: "Git unavailable", details: [reason]}}
      end
    end
  end

  defp analyze(root) do
    with {:ok, signals} <- Repository.analyze(root), do: Mapping.profile(signals)
  end

  defp finish_generate(socket, {:ok, {:ok, {root, generated}}}) do
    package = package(generated)

    assign(socket,
      state: "ready",
      package: package,
      export_target: default_target(root, package.digest)
    )
  end

  defp finish_generate(socket, {:ok, {:error, {stage, reason}}}), do: fail(socket, stage, reason)

  defp finish_generate(socket, _crashed),
    do: fail(socket, running_stage(socket), :generation_failed)

  defp running_stage(socket) do
    Enum.find(@stages, "detect", &(socket.assigns.stages[&1] == "running"))
  end

  defp fail(socket, stage, reason) do
    socket
    |> put_stage(stage, "failed")
    |> assign(state: "failed", error: present_error(stage, reason))
  end

  defp default_target(root, digest) do
    Path.join(Path.dirname(root), "#{Path.basename(root)}-harness-#{String.slice(digest, 0, 8)}")
  end

  # Export

  defp start_export(socket, input) do
    target = String.trim(input)
    run = socket.assigns.run

    socket =
      socket
      |> put_stage("export", "running")
      |> assign(export_state: "running", export_target: target, export: nil, error: nil)

    if bounded_text?(target) do
      digest = socket.assigns.package.digest
      start_async(socket, {:export, run}, fn -> Harnesses.export(digest, target) end)
    else
      finish_export(
        socket,
        {:ok,
         {:error, %Error{code: "unsafe_artifact_path", message: "Enter a fresh absolute path"}}}
      )
    end
  end

  defp finish_export(socket, {:ok, {:ok, exported}}) do
    socket
    |> put_stage("export", "done")
    |> assign(
      export_state: "done",
      export: %{path: exported["path"], files: length(socket.assigns.package.files)}
    )
  end

  defp finish_export(socket, {:ok, {:error, reason}}) do
    socket
    |> put_stage("export", "failed")
    |> assign(export_state: "idle", error: present_error("export", reason))
  end

  defp finish_export(socket, _crashed), do: finish_export(socket, {:ok, {:error, :export_failed}})

  # View model

  defp idle_stages, do: Map.new(@stages, &{&1, "idle"})

  defp put_stage(socket, stage, status),
    do: update(socket, :stages, &Map.put(&1, stage, status))

  defp package(generated) do
    profile = generated["profile"]
    candidates = Enum.filter(profile["rule_candidates"], &(&1["bucket"] == "auto"))
    {cochange, others} = Enum.split_with(candidates, &cites?(&1, "cochange"))
    measured = Enum.filter(others, &cites?(&1, "history."))
    commands = commands(profile["commands"])
    counts = generated["counts"]

    %{
      name: profile["name"],
      digest: generated["digest"],
      commands: commands,
      conventions: length(profile["conventions"]) + length(measured),
      cochange: length(cochange),
      meters: meters(profile, counts, commands, generated["artifact"]["files"]),
      preview: generated["artifact"]["files"]["CLAUDE.md"],
      price: price(generated["guidance"]),
      context: context_summary(generated["context"]),
      native: native_summary(generated["native"]),
      learning: learning_summary(get_in(generated, ["artifact", "spec", "spec"]) || %{}),
      notices:
        Enum.filter(
          generated["diagnostics"],
          &(&1["severity"] == "warning" or &1["code"] in @generation_notices)
        ),
      files:
        generated["artifact"]["files"]
        |> Enum.map(fn {path, bytes} -> %{path: path, size: byte_size(bytes)} end)
        |> Enum.sort_by(& &1.path)
    }
  end

  # What CLAUDE.md costs on every model request (contract section 6 formula, computed by
  # the adapter) and how many lines it withheld, with reasons in the provenance file.
  defp price(%{"rendered_bytes" => bytes, "est_tokens_per_request" => tokens} = report)
       when is_integer(bytes) and is_integer(tokens) do
    %{bytes: bytes, tokens: tokens, withheld: length(report["withheld"] || [])}
  end

  defp price(_), do: nil

  defp context_summary(%{"profile" => profile} = context) when profile in @context_profiles do
    %{
      profile: profile,
      removed: context["deny_tools"] || [],
      lost: Generation.Economy.lost_capabilities(context["deny_tools"] || []),
      saved: context["est_tokens_saved_per_request"] || 0,
      git: context["include_git_instructions"],
      kept: context["kept_tools"] || [],
      measured_on: measured_on(context["measured_on"])
    }
  end

  defp context_summary(_), do: nil

  # The generated skills and subagents (design section 5), as the CLI prints them.
  defp native_summary(%{"items" => items} = native) when is_list(items) do
    %{
      select: native["select"],
      items:
        Enum.map(items, fn item ->
          %{
            name: item["name"],
            kind: item["kind"],
            template: item["template"],
            origin: item["origin"],
            path: item["path"],
            listed: byte_size(item["name"]) + item["description_bytes"] + 4,
            description_bytes: item["description_bytes"],
            body_bytes: item["body_bytes"],
            tools: item["tools"] || [],
            evidence: item["evidence"] || []
          }
        end),
      tokens: native["est_tokens_per_request"],
      listing: native["listing_bytes"],
      measured_on: measured_on(native["measured_on"]),
      subagent_turn: native["subagent_turn_tokens"],
      builtin_denied: native["builtin_agents_denied"] || [],
      builtin_denied_tokens: native["builtin_agents_denied_tokens"] || 0,
      reasons: (native["dropped"] || []) |> Enum.map(& &1["reason"]) |> Enum.uniq() |> Enum.sort()
    }
  end

  defp native_summary(_), do: nil

  defp kept_uses(kept) do
    for({tool, use} <- [{"Skill", "skills"}, {"Task", "subagents"}], tool in kept, do: use)
    |> Enum.join(" and ")
  end

  # The CLI's two lines (contract 2.2), from the spec the export compiles from.
  defp learning_summary(%{"learning" => %{} = learning, "locator" => %{} = locator}) do
    %{
      status: learning["status"],
      reason: learning["status_reason"],
      model: learning["model"],
      cost: dollars(learning["cost_nanousd"]),
      tokens: learning["tokens_total"],
      kept: learning["kept"] |> Map.values() |> Enum.sum(),
      dropped: learning["dropped"] + learning["dropped_at_render"],
      locator: if(locator["rendered"], do: "on", else: "off"),
      top3: locator["top3_hits"],
      wrong: locator["wrong"],
      replay: locator["replay_n"]
    }
  end

  defp learning_summary(_spec), do: nil

  # Nanodollars as dollars with 4 decimals, rounded half up, as in the CLI.
  defp dollars(nanousd) when is_integer(nanousd) and nanousd >= 0 do
    units = div(nanousd + 50_000, 100_000)

    "#{div(units, 10_000)}.#{units |> rem(10_000) |> Integer.to_string() |> String.pad_leading(4, "0")}"
  end

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

  defp lines_word(1), do: "line"
  defp lines_word(_), do: "lines"

  defp cites?(candidate, fragment) do
    Enum.any?(candidate["citations"], fn citation ->
      String.contains?(citation["signal"] || "", fragment)
    end)
  end

  defp commands(profile_commands) do
    for key <- @command_order, command = profile_commands[key], do: {key, command}
  end

  defp meters(profile, counts, commands, files) do
    [
      {"commands", "Commands", length(commands), length(@command_order)},
      {"layout", "Layout", length(profile["layout"]), 5},
      {"conventions", "Conventions", length(profile["conventions"]), 3},
      {"rules", "Rules", counts["rules"], 5},
      {"hooks", "Hooks", counts["hooks"], 3},
      {"permissions", "Permissions", permissions(files, profile["commands"]["test"]), 3}
    ]
    |> Enum.map(fn {id, label, filled, total} ->
      %{id: id, label: label, filled: min(filled, total), total: total}
    end)
  end

  defp permissions(files, test_command) do
    case Jason.decode(files[".claude/settings.json"] || "") do
      {:ok, %{"permissions" => %{"allow" => allow}}} when is_list(allow) ->
        Enum.count(["Read", "Edit", test_command && "Bash(#{test_command}:*)"], &(&1 in allow))

      _ ->
        0
    end
  end

  defp present_error(stage, %Error{code: code, message: message}),
    do: %{stage: stage, code: code, message: message}

  defp present_error(stage, reason) when is_atom(reason),
    do: %{stage: stage, code: Atom.to_string(reason), message: humanize(reason)}

  defp present_error(stage, _reason),
    do: %{stage: stage, code: "generation_failed", message: "Stopped"}

  defp humanize(reason) do
    reason |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  defp pipeline_nodes, do: @nodes

  defp edges do
    @nodes
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [{left, _, x1}, {_, _, x2}] -> {left, x1, x2} end)
  end

  defp status_label("running"), do: "Working"
  defp status_label("ready"), do: "Ready"
  defp status_label("failed"), do: "Failed"
  defp status_label(_), do: ""

  defp segments(total), do: Enum.to_list(0..(total - 1))

  defp segment_x(index, total), do: "#{Float.round(index * 100 / total, 3)}%"

  defp segment_width(total), do: "#{Float.round(100 / total - 2, 3)}%"

  @impl true
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <main
      id="generate-page"
      class="content gen-page"
      data-state={@state}
      data-export={@export_state}
      data-run={@run}
      aria-label="Generate harness"
    >
      <header class="gen-head">
        <a id="generate-home" class="gen-home" href={~p"/"} aria-label="Home">←</a>
        <h1 id="generate-title">Generate</h1>
        <p id="generate-status" class="gen-status" role="status">{status_label(@state)}</p>
      </header>

      <form id="generate-form" class="gen-form" phx-submit="generate" phx-change="pick">
        <input
          id="generate-path"
          name="generate[path]"
          type="text"
          value={@path}
          placeholder="/path/to/repository"
          aria-label="Repository path"
          autocomplete="off"
          spellcheck="false"
          required
        />
        <select id="generate-context" name="generate[context]" aria-label="Context profile">
          <option :for={name <- ~w(lean standard lean-ai)} value={name} selected={name == @context}>
            {name}
          </option>
        </select>
        <select id="generate-native" name="generate[native]" aria-label="Skills and subagents">
          <option :for={name <- ~w(all skills agents none)} value={name} selected={name == @native}>
            {name}
          </option>
        </select>
        <input
          :if={@context == "lean-ai"}
          id="generate-learned"
          name="generate[learned]"
          type="text"
          value={@learned}
          placeholder="/path/to/learned-bundle"
          aria-label="Learned bundle folder"
          autocomplete="off"
          spellcheck="false"
        />
        <button
          id="generate-submit"
          class="button primary"
          type="submit"
          disabled={@state == "running"}
        >
          Generate
        </button>
      </form>

      <svg
        id="generate-pipeline"
        class="gen-pipeline"
        width="100%"
        height="84"
        role="group"
        aria-label="Pipeline"
      >
        <line
          :for={{left, x1, x2} <- edges()}
          id={"generate-edge-#{left}"}
          class="gen-edge"
          x1={"#{x1}%"}
          x2={"#{x2}%"}
          y1="30"
          y2="30"
          data-status={@stages[left]}
        />
        <svg
          :for={{stage, label, x} <- pipeline_nodes()}
          id={"generate-node-#{stage}"}
          class="gen-node"
          x={"#{x}%"}
          y="0"
          overflow="visible"
          data-status={@stages[stage]}
          role="img"
          aria-label={"#{label}: #{@stages[stage]}"}
        >
          <rect x="-15" y="15" width="30" height="30" />
          <path :if={@stages[stage] == "done"} class="gen-glyph" d="M-7 30 l5 6 l10 -12" />
          <path :if={@stages[stage] == "failed"} class="gen-glyph" d="M-6 24 l12 12 M6 24 l-12 12" />
          <rect
            :if={@stages[stage] in ["idle", "running"]}
            class="gen-dot"
            x="-3"
            y="27"
            width="6"
            height="6"
          />
          <text x="0" y="66" text-anchor="middle">{label}</text>
        </svg>
      </svg>

      <p
        :if={@error}
        id="generate-error"
        class="notice error"
        role="alert"
        data-code={@error.code}
        data-stage={@error.stage}
      >
        {@error.message}
      </p>

      <section :if={@package} id="generate-package" class="gen-package" aria-label="Harness">
        <div id="generate-tiles" class="gen-tiles">
          <div id="generate-tile-commands" class="gen-tile">
            <strong id="generate-tile-commands-value">{length(@package.commands)}</strong>
            <span>Commands found</span>
          </div>
          <div id="generate-tile-conventions" class="gen-tile">
            <strong id="generate-tile-conventions-value">{@package.conventions}</strong>
            <span>Conventions measured</span>
          </div>
          <div id="generate-tile-cochange" class="gen-tile">
            <strong id="generate-tile-cochange-value">{@package.cochange}</strong>
            <span>Files that change together</span>
          </div>
        </div>

        <ul id="generate-commands" class="gen-chips">
          <li :for={{key, command} <- @package.commands} id={"generate-command-#{key}"} data-key={key}>
            <code>{command}</code>
          </li>
        </ul>

        <ol id="generate-meters" class="gen-meters">
          <li
            :for={meter <- @package.meters}
            id={"generate-meter-#{meter.id}"}
            data-filled={meter.filled}
            data-total={meter.total}
          >
            <svg class="gen-meter" width="100%" height="8" aria-hidden="true">
              <rect
                :for={index <- segments(meter.total)}
                class={if index < meter.filled, do: "on", else: "off"}
                x={segment_x(index, meter.total)}
                y="0"
                width={segment_width(meter.total)}
                height="8"
              />
            </svg>
            <span>{meter.label}</span>
          </li>
        </ol>

        <ul id="generate-notices" class="gen-notices">
          <li
            :if={@package.price}
            id="generate-price"
            data-kind="info"
            data-bytes={@package.price.bytes}
            data-tokens={@package.price.tokens}
            data-withheld={@package.price.withheld}
          >
            <%= if @package.price.bytes == 0 do %>
              CLAUDE.md: 0 bytes the model reads, 0 tokens per request;
            <% else %>
              CLAUDE.md: {delimited(@package.price.bytes)} bytes the model reads, about {delimited(
                @package.price.tokens
              )} tokens on every request;
            <% end %>
            {@package.price.withheld} {lines_word(@package.price.withheld)} withheld (reasons in .olivium/guidance-provenance.json).
          </li>
          <li
            :if={@package.context}
            id="generate-context-profile"
            data-kind="info"
            data-profile={@package.context.profile}
            data-removed={Enum.join(@package.context.removed, " ")}
            data-saved={@package.context.saved}
          >
            <%= cond do %>
              <% @package.context.profile == "lean-ai" -> %>
                Context profile: lean-ai. The lean settings ({length(@package.context.removed)} tools removed{@package.context.lost}), plus what was learned from this repository's history: a local index, a prompt-time locator when its replay gate passes, verified command rewrites and learned pitfalls.
              <% @package.context.profile == "lean" -> %>
                Context profile: lean. Removes git instructions and {length(@package.context.removed)} tools no recorded benchmark run used{@package.context.lost} ({Enum.join(
                  @package.context.removed,
                  ", "
                )}){if @package.context.kept != [],
                  do:
                    "; keeps #{Enum.join(@package.context.kept, ", ")} for the generated #{kept_uses(@package.context.kept)}"}:
                <%= cond do %>
                  <% @package.context.saved > 0 and @package.context.kept != [] -> %>
                    about {delimited(@package.context.saved)} fewer tokens on every model request than no settings, estimated from measurements on {@package.context.measured_on} for this tool set and listing.
                  <% @package.context.saved > 0 -> %>
                    about {delimited(@package.context.saved)} fewer tokens on every model request, measured on {@package.context.measured_on}.
                  <% true -> %>
                    keeps the tools this repository's own subagents or skills need; the saving for this tool set was not measured.
                <% end %>
                This is a settings change you could also make by hand. Choose standard to keep them.
              <% true -> %>
                Context profile: standard. Keeps git instructions and every Claude Code tool. Choose lean to remove git instructions and the tools no recorded benchmark run used from every model request.
            <% end %>
          </li>
          <li
            :if={@package.learning}
            id="generate-learning"
            data-kind={if @package.learning.status in ["ok", "mock"], do: "info", else: "warning"}
            data-status={@package.learning.status}
            data-reason={@package.learning.reason}
            data-model={@package.learning.model}
            data-cost={@package.learning.cost}
            data-tokens={@package.learning.tokens}
            data-kept={@package.learning.kept}
            data-dropped={@package.learning.dropped}
          >
            AI learning: {@package.learning.status} ({@package.learning.model}, ${@package.learning.cost}, {delimited(
              @package.learning.tokens
            )} tokens), {@package.learning.kept} kept, {@package.learning.dropped} dropped
          </li>
          <li
            :if={@package.learning}
            id="generate-locator"
            data-kind="info"
            data-locator={@package.learning.locator}
            data-top3={@package.learning.top3}
            data-wrong={@package.learning.wrong}
            data-replay={@package.learning.replay}
          >
            Locator: {@package.learning.locator} (top-3 {@package.learning.top3}/{@package.learning.replay}, wrong {@package.learning.wrong}/{@package.learning.replay})
          </li>
          <li
            :for={notice <- @package.notices}
            id={"generate-notice-#{notice["code"]}"}
            data-code={notice["code"]}
          >
            {notice["message"]}
          </li>
        </ul>

        <section
          :if={@package.native}
          id="generate-native-panel"
          class="gen-native"
          aria-labelledby="generate-native-heading"
          data-select={@package.native.select}
        >
          <h2 id="generate-native-heading">Skills and subagents</h2>
          <ul id="generate-native-list" class="gen-files">
            <li
              :for={item <- @package.native.items}
              id={"generate-native-#{item.name}"}
              data-name={item.name}
              data-kind={item.kind}
              data-template={item.template}
              data-origin={item.origin}
              data-path={item.path}
              data-listed-bytes={item.listed}
              data-description-bytes={item.description_bytes}
              data-body-bytes={item.body_bytes}
              data-tools={Enum.join(item.tools, ",")}
              data-evidence={Enum.join(item.evidence, " ")}
            >
              <code>{item.name}</code>
              <span :if={item.kind == "agent"}>{Enum.join(item.tools, ", ")}</span>
              <span>{item.listed} B listed, {delimited(item.body_bytes)} B on use</span>
            </li>
          </ul>
          <p
            :if={@package.native.items != []}
            id="generate-native-cost"
            data-tokens={@package.native.tokens}
            data-listing-bytes={@package.native.listing}
          >
            About {delimited(@package.native.tokens)} tokens on every model request for these (measured on {@package.native.measured_on}); choose none to remove them.
          </p>
          <p
            :if={@package.native.subagent_turn != nil}
            id="generate-native-subagent-cost"
            data-min={@package.native.subagent_turn["min"]}
            data-max={@package.native.subagent_turn["max"]}
            data-builtin-denied={Enum.join(@package.native.builtin_denied, ",")}
            data-builtin-denied-tokens={@package.native.builtin_denied_tokens}
          >
            Each subagent call costs about {delimited(@package.native.subagent_turn["min"])}-{delimited(
              @package.native.subagent_turn["max"]
            )} tokens per turn of its own, not in the figure above; {if @package.native.builtin_denied !=
                                                                          [],
                                                                        do:
                                                                          "Claude Code's built-in subagents (#{Enum.join(@package.native.builtin_denied, ", ")}) are denied by name, which takes about #{delimited(@package.native.builtin_denied_tokens)} tokens off every request (included above); your own and the repository's skills and subagents stay listed.",
                                                                        else:
                                                                          "Claude Code's built-in subagents stay listed, and the figure above includes them."}
          </p>
          <p
            :if={@package.native.items == []}
            id="generate-native-none"
            data-reasons={Enum.join(@package.native.reasons, " ")}
          >
            None generated{if @package.native.reasons != [],
              do: " (#{Enum.join(@package.native.reasons, ", ")})"}.
          </p>
        </section>

        <code id="generate-digest" class="gen-digest">{@package.digest}</code>

        <div class="gen-output">
          <section id="generate-preview-panel" aria-labelledby="generate-preview-heading">
            <h2 id="generate-preview-heading">CLAUDE.md</h2>
            <pre id="generate-preview">{@package.preview}</pre>
          </section>
          <section id="generate-files-panel" aria-labelledby="generate-files-heading">
            <h2 id="generate-files-heading">Files</h2>
            <ul id="generate-files" class="gen-files">
              <li
                :for={{file, index} <- Enum.with_index(@package.files)}
                id={"generate-file-#{index}"}
                data-path={file.path}
                data-bytes={file.size}
              >
                <code>{file.path}</code>
                <span>{file.size} B</span>
              </li>
            </ul>
          </section>
        </div>

        <form id="generate-export-form" class="gen-form" phx-submit="export">
          <input
            id="generate-export-target"
            name="export[target]"
            type="text"
            value={@export_target}
            aria-label="Export directory"
            autocomplete="off"
            spellcheck="false"
            required
          />
          <button
            id="generate-export-submit"
            class="button secondary"
            type="submit"
            disabled={@export_state == "running"}
          >
            Export
          </button>
        </form>

        <p
          :if={@export}
          id="generate-export-result"
          class="notice success"
          role="status"
          data-path={@export.path}
          data-files={@export.files}
        >
          <span aria-hidden="true">✓</span> <code>{@export.path}</code>
        </p>
      </section>
    </main>
    """
  end
end
