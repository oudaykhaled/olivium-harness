defmodule HarnessForgeWeb.SetupLive do
  @moduledoc "Versioned, explicitly acknowledged setup drafts; navigation grants no domain authority."
  use HarnessForgeWeb, :live_view
  alias HarnessForge.{Company, Contracts, Goals, Workspaces}
  alias HarnessForge.Company.{CorpusReview, SetupSessions, SetupRuns}
  alias HarnessForge.Evidence.{Corpora, Capture, Connection, Store}
  alias HarnessForge.Privacy.Purge
  alias HarnessForgeWeb.Plugs.OperatorSession
  alias Phoenix.LiveView.JS

  @steps ~w(outcome scope understanding review candidate evaluation release)
  @titles %{
    "outcome" => "Company context",
    "scope" => "Source scope",
    "understanding" => "Company understanding",
    "review" => "Exact review",
    "candidate" => "Harness candidate",
    "evaluation" => "Task evaluation",
    "release" => "Release"
  }
  @outcome_fields ~w(profile project repository goal outcome_note)
  @scope_fields ~w(corpus_id declaration scope_note)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket),
      do: Phoenix.PubSub.subscribe(HarnessForge.PubSub, "workspace:" <> Workspaces.current_id())

    {:ok,
     socket
     |> detach_hook(:authenticate_event, :handle_event)
     |> attach_hook(:authenticate_event, :handle_event, &authenticate/3)
     |> assign(
       page_title: "Saved company setup",
       workspace_id: Workspaces.current_id(),
       generation: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
       reset_token: 0,
       ready: connected?(socket),
       route_step: nil,
       saved: nil,
       saved_id: nil,
       sessions: [],
       inputs: %{},
       choices: %{},
       choices_error: nil,
       choices_warning: nil,
       dirty: false,
       conflict: nil,
       analysis: nil,
       analysis_error: nil,
       analysis_busy: false,
       analysis_command_id: Ecto.UUID.generate(),
       analysis_connections: %{"rows" => [], "next_cursor" => nil},
       analysis_connection: "",
       analysis_connection_name: nil,
       analysis_capture: nil,
       error: nil,
       notice: nil
     )}
  end

  @impl true
  def handle_params(%{"id" => id, "step" => step}, _uri, socket) when step in @steps do
    if authorized?(socket),
      do: {:noreply, socket |> assign(:route_step, step) |> load_saved(id)},
      else: {:noreply, revoke(socket)}
  end

  def handle_params(%{"id" => _}, _uri, socket),
    do: {:noreply, clear_saved(socket) |> fail("invalid_input")}

  def handle_params(_, _uri, socket) do
    if authorized?(socket) do
      case SetupSessions.list(%{}, caller(socket)) do
        {:ok, rows} -> {:noreply, socket |> clear_saved() |> assign(sessions: rows, error: nil)}
        _ -> {:noreply, socket |> clear_saved() |> assign(sessions: []) |> fail("unavailable")}
      end
    else
      {:noreply, revoke(socket)}
    end
  end

  @impl true
  def handle_event("setup_create", attrs, socket) do
    if simple_envelope?(attrs, socket) do
      case SetupSessions.create(%{}, caller(socket)) do
        {:ok, saved} -> {:noreply, push_navigate(socket, to: saved_path(saved))}
        {:error, error} -> {:noreply, fail(socket, error["code"])}
      end
    else
      {:noreply, fail(socket, "invalid_input")}
    end
  end

  def handle_event(event, attrs, socket) when event in ~w(setup_edit setup_submit) do
    case form_input(attrs, socket, event) do
      {:ok, inputs, version, command} ->
        inputs =
          if event == "setup_edit",
            do: clear_dependents(inputs, socket.assigns.inputs),
            else: inputs

        edited =
          assign(socket,
            inputs: inputs,
            dirty: inputs != saved_inputs(socket.assigns.saved),
            error: nil,
            notice: nil
          )

        {:noreply, if(event == "setup_edit", do: edited, else: submit(edited, command, version))}

      _ ->
        {:noreply, fail(socket, "invalid_input")}
    end
  end

  def handle_event(event, attrs, socket) when event in ~w(setup_back setup_continue) do
    with {:ok, version} <- navigation_input(attrs, socket),
         false <- socket.assigns.dirty do
      command = if event == "setup_back", do: "back", else: "continue"
      {:noreply, command(socket, command, %{}, version)}
    else
      true ->
        {:noreply,
         assign(socket,
           error:
             "Save your note and choices before navigating. Back and Continue do not save changes."
         )}

      _ ->
        {:noreply, fail(socket, "invalid_input")}
    end
  end

  def handle_event("setup_reload", attrs, socket) do
    if simple_envelope?(attrs, socket) && socket.assigns.saved_id,
      do:
        {:noreply, socket |> assign(analysis_busy: false) |> load_saved(socket.assigns.saved_id)},
      else: {:noreply, fail(socket, "invalid_input")}
  end

  def handle_event("setup_connection", attrs, socket) do
    attrs = clean(attrs)

    if Enum.sort(Map.keys(attrs)) == ~w(connection_id setup_generation) and
         attrs["setup_generation"] == socket.assigns.generation and
         not socket.assigns.analysis_busy and
         (attrs["connection_id"] == "" or
            Enum.any?(
              socket.assigns.analysis_connections["rows"],
              &(&1["id"] == attrs["connection_id"])
            )) do
      {:noreply, assign(socket, analysis_connection: attrs["connection_id"], analysis_error: nil)}
    else
      {:noreply, fail(socket, "invalid_input")}
    end
  end

  def handle_event("setup_connections_more", attrs, socket) do
    if simple_envelope?(attrs, socket) and
         is_binary(socket.assigns.analysis_connections["next_cursor"]) and
         not socket.assigns.analysis_busy do
      case CorpusReview.choices(
             %{
               "kind" => "connection",
               "cursor" => socket.assigns.analysis_connections["next_cursor"]
             },
             caller(socket)
           ) do
        {:ok, page} ->
          {:noreply,
           assign(socket, :analysis_connections, %{
             page
             | "rows" =>
                 socket.assigns.analysis_connections["rows"] ++
                   Enum.filter(page["rows"], &(&1["provider"] == "local"))
           })}

        _ ->
          {:noreply,
           assign(socket,
             analysis_error: "Connection choices could not be confirmed. Reload saved setup."
           )}
      end
    else
      {:noreply, fail(socket, "invalid_input")}
    end
  end

  def handle_event("setup_run", attrs, socket) do
    with false <-
           socket.assigns.analysis_busy or socket.assigns.dirty or
             not is_nil(socket.assigns.conflict),
         {:ok, envelope} <- run_envelope(attrs, socket),
         options = caller(socket),
         {:ok, source_context} <-
           HarnessForge.Evidence.SourceUseContext.interactive(
             socket.assigns.operator_auth,
             options
           ) do
      generation = socket.assigns.generation

      {:noreply,
       socket
       |> assign(analysis_busy: true, analysis_error: nil, notice: nil)
       |> start_async({:setup_run, generation, envelope["command_id"]}, fn ->
         SetupRuns.command(envelope, options, source_context)
       end)}
    else
      _ ->
        {:noreply,
         assign(socket,
           analysis_error: "Save local changes and reload the current setup before this action."
         )}
    end
  end

  def handle_event("setup_history", attrs, socket) do
    view = socket.assigns.analysis

    if simple_envelope?(attrs, socket) and is_map(view) and is_binary(view["history_cursor"]) do
      case SetupRuns.history(socket.assigns.saved_id, view["history_cursor"], caller(socket)) do
        {:ok, page} ->
          {:noreply,
           assign(socket, :analysis, %{
             view
             | "predecessor_usage" => view["predecessor_usage"] ++ page["predecessor_usage"],
               "history_cursor" => page["history_cursor"]
           })}

        _ ->
          {:noreply,
           assign(socket,
             analysis_error:
               "Earlier usage could not be confirmed. Reload saved state to inspect current history."
           )}
      end
    else
      {:noreply, fail(socket, "invalid_input")}
    end
  end

  def handle_event(_, _, socket), do: {:noreply, fail(socket, "invalid_input")}

  @impl true
  def handle_async({:setup_run, generation, _command}, {:ok, result}, socket) do
    if generation == socket.assigns.generation do
      if authorized?(socket) do
        case result do
          {:ok, _receipt} ->
            if socket.assigns.dirty or not is_nil(socket.assigns.conflict) do
              {:noreply,
               socket
               |> assign(
                 analysis_busy: false,
                 notice:
                   "Work finished. Your local input is retained. Reload saved setup to inspect the current run."
               )
               |> load_analysis()}
            else
              {:noreply,
               socket |> assign(analysis_busy: false) |> load_saved(socket.assigns.saved_id)}
            end

          {:error, failure} ->
            {:noreply,
             assign(socket,
               analysis_busy: false,
               analysis_error: run_error(failure["code"]),
               notice: nil
             )}
        end
      else
        {:noreply, revoke(socket)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_async({:setup_run, generation, _command}, {:exit, _}, socket) do
    cond do
      generation != socket.assigns.generation ->
        {:noreply, socket}

      not authorized?(socket) ->
        {:noreply, revoke(socket)}

      true ->
        {:noreply,
         assign(socket,
           analysis_busy: false,
           analysis_error:
             "The work outcome could not be confirmed. Reload saved setup; no automatic resend will occur."
         )}
    end
  end

  @impl true
  def handle_info(:operator_session_revoked, socket), do: {:noreply, revoke(socket)}

  def handle_info(event, socket) when event in [:company_cache_reset, :corpus_cache_reset] do
    {:noreply,
     socket
     |> clear_saved()
     |> assign(
       sessions: [],
       generation: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
       reset_token: socket.assigns.reset_token + 1,
       error: "Evidence or privacy changed. Reload the saved setup to recheck its references."
     )}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  defp authenticate(event, _attrs, socket) do
    cond do
      !authorized?(socket) ->
        {:halt, revoke(socket)}

      !connected?(socket) ->
        {:halt, assign(socket, error: "Connecting. Saved actions are not available yet.")}

      socket.assigns.analysis_busy and
          event in ~w(setup_edit setup_submit setup_back setup_continue setup_connection) ->
        {:halt,
         assign(socket,
           analysis_error:
             "This accepted action is still working. Refresh saved state before making another change."
         )}

      true ->
        {:cont, socket}
    end
  end

  defp authorized?(socket),
    do:
      OperatorSession.valid?(socket.assigns.operator_auth) &&
        socket.assigns.workspace_id == Workspaces.current_id()

  defp caller(socket) do
    auth = socket.assigns.operator_auth
    workspace = socket.assigns.workspace_id

    [
      authorize: fn -> workspace == Workspaces.current_id() && OperatorSession.valid?(auth) end,
      session_fingerprint: Contracts.digest(auth),
      view_generation: socket.assigns.generation,
      reset_token: socket.assigns.reset_token
    ]
  end

  defp clear_saved(socket),
    do:
      assign(socket,
        saved: nil,
        inputs: %{},
        choices: %{},
        choices_error: nil,
        choices_warning: nil,
        dirty: false,
        conflict: nil,
        analysis: nil,
        analysis_error: nil,
        analysis_busy: false,
        analysis_capture: nil,
        analysis_connections: %{"rows" => [], "next_cursor" => nil},
        analysis_connection: "",
        analysis_connection_name: nil,
        notice: nil
      )

  defp revoke(socket),
    do: socket |> clear_saved() |> assign(sessions: [], saved_id: nil) |> redirect(to: "/login")

  defp load_saved(socket, id) do
    case SetupSessions.get(%{"id" => id}, caller(socket)) do
      {:ok, saved} ->
        socket = accept_saved(socket, saved)

        if socket.assigns.route_step != saved["step"],
          do: push_patch(socket, to: saved_path(saved), replace: true),
          else: socket

      {:error, error} ->
        socket |> clear_saved() |> assign(:saved_id, id) |> fail(error["code"])
    end
  end

  defp accept_saved(socket, saved) do
    socket =
      assign(socket,
        saved: saved,
        saved_id: saved["id"],
        inputs: saved_inputs(saved),
        dirty: false,
        conflict: nil,
        error: nil,
        notice: "Showing saved version #{saved["version"]}."
      )

    socket |> load_choices() |> load_analysis()
  end

  defp load_analysis(%{assigns: %{saved: %{"step" => step}}} = socket)
       when step in ~w(scope understanding) do
    options = caller(socket)

    result =
      with {:ok, context} <-
             HarnessForge.Evidence.SourceUseContext.interactive(
               socket.assigns.operator_auth,
               options
             ),
           do: SetupRuns.get(socket.assigns.saved_id, options, context)

    case result do
      {:ok, view} ->
        capture =
          case get_in(view, ["run", "capture_ref"]) do
            ref when is_map(ref) ->
              case Capture.setup_status(ref, caller(socket)) do
                {:ok, status} -> status
                _ -> nil
              end

            _ ->
              nil
          end

        choices =
          case CorpusReview.choices(%{"kind" => "connection"}, caller(socket)) do
            {:ok, page} ->
              %{page | "rows" => Enum.filter(page["rows"], &(&1["provider"] == "local"))}

            _ ->
              %{"rows" => [], "next_cursor" => nil}
          end

        connection_name =
          case get_in(view, ["run", "config", "connection_id"]) do
            id when is_binary(id) ->
              case Corpora.guard(caller(socket), fn ->
                     with {:ok, connection} <- Store.get(Connection, id),
                          true <- connection.status == "active" and connection.provider == "local",
                          do: {:ok, connection.name},
                          else: (_ -> {:error, :not_found})
                   end) do
                {:ok, name} -> name
                _ -> "Unavailable saved connection"
              end

            _ ->
              nil
          end

        assign(socket,
          analysis: view,
          analysis_capture: capture,
          analysis_connections: choices,
          analysis_connection_name: connection_name,
          analysis_error: nil,
          analysis_command_id: Ecto.UUID.generate()
        )

      _ ->
        assign(socket,
          analysis: nil,
          analysis_capture: nil,
          analysis_error: "Saved analysis state is unavailable. Reload saved setup to check it."
        )
    end
  end

  defp load_analysis(socket), do: assign(socket, analysis: nil, analysis_capture: nil)

  defp run_envelope(attrs, socket) do
    attrs = clean(attrs)
    view = socket.assigns.analysis
    run = if is_map(view), do: view["run"]
    prepared = if run, do: run["prepared"]
    prepared_token = if prepared, do: ref_token(prepared["prepared_ref"]), else: ""

    with true <- is_map(view) and is_map(socket.assigns.saved),
         true <-
           Enum.sort(Map.keys(attrs)) ==
             ~w(action command_id expected_run_version expected_session_version prepared_ref setup_generation),
         true <-
           attrs["setup_generation"] == socket.assigns.generation and
             attrs["command_id"] == socket.assigns.analysis_command_id,
         true <- attrs["action"] in view["available_actions"],
         {:ok, session_version} <- parse_version(attrs["expected_session_version"]),
         {:ok, run_version} <-
           if(run,
             do: parse_version(attrs["expected_run_version"]),
             else: if(attrs["expected_run_version"] == "", do: {:ok, nil}, else: :error)
           ),
         true <-
           session_version == view["session_version"] and
             (is_nil(run) or run_version == run["run_version"]),
         true <- attrs["prepared_ref"] == prepared_token do
      action = attrs["action"]

      payload =
        case action do
          "prepare" ->
            %{
              "profile_version" => "setup-local-synthesis.v1",
              "connection_id" => socket.assigns.analysis_connection
            }

          "new_run" ->
            %{"predecessor_run_ref" => run["run_ref"]}

          action when action in ~w(authorize analyze retry) ->
            %{"prepared_ref" => prepared["prepared_ref"]}

          _ ->
            %{}
        end

      {:ok,
       %{
         "version" => 1,
         "id" => socket.assigns.saved_id,
         "expected_session_version" => session_version,
         "expected_run_version" => run_version,
         "run_ref" => if(run, do: run["run_ref"]),
         "command_id" => attrs["command_id"],
         "action" => action,
         "payload" => payload
       }}
    else
      _ -> :error
    end
  end

  defp run_error(code) when code in ~w(model_unavailable unsupported_configuration),
    do:
      "A configured local Ollama model and supported local source are required. Review Connections, then reload. No cloud fallback is used."

  defp run_error(code) when code in ~w(conflict command_conflict stale_scope stale_preparation),
    do:
      "This run or its evidence changed. The displayed preparation was not authorized. Reload the current saved setup."

  defp run_error("acquisition_incomplete"),
    do:
      "Capture and its index are not complete. Refresh saved state to inspect progress; incomplete evidence cannot be analyzed."

  defp run_error(code) when code in ~w(request_outcome_unknown acquisition_outcome_unknown),
    do:
      "A previous outcome is uncertain. No automatic resend is permitted. Inspect retained usage, cancel this run and explicitly prepare a replacement if needed."

  defp run_error(code)
       when code in ~w(authorization_expired budget_exhausted run_replacement_required cancelled),
       do:
         "This run cannot admit more work. Its usage is retained. Cancel if necessary, then explicitly create and review a replacement run."

  defp run_error("invalid_input"),
    do:
      "Check the saved outcome and source. The displayed search must fit 256 characters and 1,024 bytes; it is never silently shortened."

  defp run_error(_),
    do:
      "The saved work outcome could not be confirmed. Reload saved setup before any further action; no automatic retry occurs."

  defp run_primary(nil), do: nil

  defp run_primary(view),
    do:
      Enum.find(
        ~w(prepare acquire retrieve authorize analyze retry new_run),
        &(&1 in view["available_actions"])
      )

  defp run_label("prepare"), do: "Review local analysis proposal"
  defp run_label("acquire"), do: "Approve and capture this local scope"
  defp run_label("retrieve"), do: "Prepare evidence for the displayed search"
  defp run_label("authorize"), do: "Authorize this exact preparation and limits"
  defp run_label("analyze"), do: "Analyze the authorized evidence"
  defp run_label("retry"), do: "Retry this preparation with remaining budget"
  defp run_label("new_run"), do: "Prepare a replacement run"
  defp run_label(_), do: "Unavailable"

  attr :view, :map, required: true
  attr :generation, :string, required: true
  attr :command_id, :string, required: true
  attr :connection, :string, required: true
  attr :connection_name, :any, default: nil
  attr :connections, :map, required: true
  attr :capture, :any, default: nil
  attr :busy, :boolean, required: true
  attr :disabled, :boolean, required: true
  attr :error, :any, default: nil

  defp analysis_panel(assigns) do
    assigns = assign(assigns, run: assigns.view["run"], action: run_primary(assigns.view))

    ~H"""
    <section id="setup-analysis" class="context-note" aria-labelledby="setup-analysis-title">
      <h3 id="setup-analysis-title">Local evidence analysis</h3>
      <p :if={@busy} id="setup-analysis-busy" role="status">
        Working on this accepted action. Reloading will not resend it.
      </p>
      <p :if={@error} id="setup-analysis-error" class="notice error" role="alert">{@error}</p>
      <%= if @run do %>
        <p id="setup-analysis-phase" role="status">
          Run state: {@run["phase"]}. Capture, analysis and human approval are separate.
        </p>
        <p :if={@run["phase"] == "expired"} id="setup-analysis-recovery" role="alert">
          Authorization expired.
          <%= if @run["usage"]["uncertain_requests"] > 0 do %>
            The previous request's outcome is uncertain; its reservation remains accounted.
          <% end %>
          This run cannot retry. Cancel closes this run without refunding usage. Preparing a replacement creates a separate run; it does not authorize capture or analysis.
        </p>
        <p id="setup-analysis-source">
          Saved source: {@connection_name}. Current snapshot only; no repository or document code is executed.
        </p>
        <p :if={@run["failure_code"]} role="alert">{run_error(@run["failure_code"])}</p>
        <p id="setup-analysis-query">Displayed search: <q>{@run["config"]["query_text"]}</q></p>
        <p id="setup-analysis-profile">
          Current local snapshot · Markdown and text · up to 500 files / 16 MiB body bytes / 10,000 admitted entries · original 600-second capture deadline.
        </p>
        <p id="setup-analysis-model">
          Local {@run["config"]["descriptor"]["model"]} at <code>{@run["config"]["descriptor"]["endpoint"]}</code>. Model access requires separate exact-preparation authorization: two reservations, 100,000 tokens, zero estimated cost, 300 seconds. No model call is made by reviewing or acquiring.
        </p>
        <p :if={@capture} id="setup-analysis-capture" role="status">
          Capture: {@capture["state"]}. Index: {if @capture["index_ready"],
            do: "ready",
            else: "not ready"}. Captured scope does not establish semantic sufficiency.
        </p>
        <p
          :if={@capture && @capture["incomplete"]}
          id="setup-analysis-capture-incomplete"
          role="alert"
        >
          This capture is incomplete. It cannot support analysis. Cancel this run and explicitly review a replacement; the original deadline and recorded usage are retained.
        </p>
        <div :if={@run["prepared"]} id="setup-analysis-disclosure">
          <p>
            Prepared {@run["prepared"]["source_count"]} sources / {@run["prepared"]["bytes"]} bytes for local {@run[
              "prepared"
            ]["descriptor"]["model"]} at <code>{@run["prepared"]["descriptor"]["endpoint"]}</code>.
          </p>
          <p>
            Disclosure: source bodies and company context. Consent: {String.replace(
              @run["prepared"]["consent_status"],
              "_",
              " "
            )}. Authorize only the exact preparation shown below.
          </p>
          <p>
            This run's limit: two reservations, 100,000 tokens, zero estimated cost, 300 seconds from authorization. Reservations do not promise successful sends.
          </p>
          <details id="setup-prepared-reference">
            <summary>Exact preparation and source manifest</summary><p>
              Preparation <code>{ref_token(@run["prepared"]["prepared_ref"])}</code>
            </p><p>Manifest <code>{ref_token(@run["prepared"]["manifest_ref"])}</code></p>
          </details>
        </div>
      <% else %>
        <p>
          Save a source corpus above, then explicitly choose its approved local connection. Reviewing a proposal does not capture files or grant model access.
        </p>
        <form id="setup-analysis-connection-form" phx-change="setup_connection">
          <input type="hidden" name="setup_generation" value={@generation} />
          <label for="setup-analysis-connection">Approved local source connection</label>
          <select id="setup-analysis-connection" name="connection_id" disabled={@disabled || @busy}>
            <option value="" selected={@connection == ""}>Choose a local connection</option>
            <option
              :for={row <- @connections["rows"]}
              value={row["id"]}
              selected={@connection == row["id"]}
            >
              {row["title"]}
            </option>
          </select>
        </form>
        <button
          :if={@connections["next_cursor"]}
          type="button"
          class="button secondary"
          phx-click="setup_connections_more"
          phx-value-setup_generation={@generation}
          disabled={@disabled || @busy}
        >More connections</button>
      <% end %>
      <button
        :if={@action}
        id="setup-analysis-next"
        type="button"
        class={
          if @run && @run["phase"] == "completed", do: "button secondary", else: "button primary"
        }
        phx-click="setup_run"
        phx-value-setup_generation={@generation}
        phx-value-command_id={@command_id}
        phx-value-action={@action}
        phx-value-expected_session_version={@view["session_version"]}
        phx-value-expected_run_version={if @run, do: @run["run_version"], else: ""}
        phx-value-prepared_ref={
          if @run && @run["prepared"], do: ref_token(@run["prepared"]["prepared_ref"]), else: ""
        }
        disabled={
          @disabled || @busy || (@action == "prepare" && @connection == "") ||
            (@action == "retrieve" &&
               (is_nil(@capture) || !@capture["scan_complete"] || !@capture["index_ready"] ||
                  @capture["incomplete"]))
        }
      >{run_label(@action)}</button>
      <button
        :if={@run && "cancel" in @view["available_actions"]}
        id="setup-analysis-cancel"
        type="button"
        class={if is_nil(@action), do: "button primary", else: "button secondary"}
        phx-click="setup_run"
        phx-value-setup_generation={@generation}
        phx-value-command_id={@command_id}
        phx-value-action="cancel"
        phx-value-expected_session_version={@view["session_version"]}
        phx-value-expected_run_version={@run["run_version"]}
        phx-value-prepared_ref={
          if @run["prepared"], do: ref_token(@run["prepared"]["prepared_ref"]), else: ""
        }
        aria-describedby={if @run["phase"] == "expired", do: "setup-analysis-recovery"}
        disabled={@disabled || @busy}
      >Cancel this run</button>
      <p>
        <.link href="/?view=connections">Review Connections</.link>. Refresh saved state to observe capture progress. No action runs on reopening.
      </p>
      <details :if={@run} id="setup-analysis-usage">
        <summary>Usage, uncertainty and exact run</summary>
        <p>
          {@run["usage"]["requests_reserved"]} reservations · {@run["usage"]["tokens_accounted"]} tokens accounted · {@run[
            "usage"
          ]["pending_requests"]} pending · {@run["usage"]["uncertain_requests"]} uncertain. Unused request slots in this run's budget: {@run[
            "usage"
          ]["remaining_requests"]}.
        </p>
        <p>
          Expiry: {@run["usage"]["expires_at"] || "Not authorized"}. Run
          <code>{ref_token(@run["run_ref"])}</code>
          · version {@run["run_version"]}.
        </p>
        <p>Unused slots do not authorize retries. Each authorized run has a separate budget.</p>
        <p :for={prior <- @view["predecessor_usage"]}>
          Previous run <code>{ref_token(prior["run_ref"])}</code>: {prior["usage"][
            "requests_reserved"
          ]} reservations; {prior["usage"]["tokens_accounted"]} tokens accounted; {prior["usage"][
            "uncertain_requests"
          ]} uncertain. Its budget and retained usage remain separate.
        </p>
        <button
          :if={@view["history_cursor"]}
          id="setup-analysis-history"
          type="button"
          class="button secondary"
          phx-click="setup_history"
          phx-value-setup_generation={@generation}
          disabled={@disabled}
        >More previous usage</button>
      </details>
      <p :if={@run && @run["phase"] == "completed"} id="setup-analysis-result">
        Analysis recorded. <.link href="/?view=company" class="button primary">Review the proposed company findings</.link>. Claim and harness-plan decisions remain separate; task quality and release are unobserved.
      </p>
    </section>
    """
  end

  defp saved_path(saved), do: "/setup/" <> saved["id"] <> "/" <> saved["step"]

  defp home_path(%{"id" => id}) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> "/?" <> URI.encode_query(%{"setup" => id})
      :error -> "/"
    end
  end

  defp home_path(_), do: "/"

  defp creation_path(%{"id" => id, "step" => step}, field)
       when step in ~w(outcome scope) and field in ~w(profile repository project goal) do
    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        "/?" <>
          URI.encode_query(%{"create" => field, "return_setup" => id, "return_step" => step})

      _ ->
        nil
    end
  end

  defp creation_path(_, _), do: nil

  defp saved_inputs(nil), do: %{}

  defp saved_inputs(saved) do
    selection = saved["selection"]

    if saved["step"] == "outcome" do
      Map.new(~w(profile project repository goal), &{&1, ref_token(selection[&1])})
      |> Map.put("outcome_note", saved["draft"]["outcome_note"] || "")
    else
      %{
        "corpus_id" => selection["corpus_id"] || "",
        "declaration" => ref_token(selection["declaration"]),
        "scope_note" => saved["draft"]["scope_note"] || ""
      }
    end
  end

  defp ref_token(%{"id" => id, "content_hash" => hash}), do: id <> ":" <> hash
  defp ref_token(%{"id" => id, "digest" => hash}), do: id <> ":" <> hash
  defp ref_token(_), do: ""

  defp load_choices(socket) do
    Purge.synchronize(fn -> load_current_choices(socket) end)
  end

  defp load_current_choices(socket) do
    current_caller = caller(socket)

    result =
      Corpora.guard(current_caller, fn ->
        with {:ok, profile} <- Company.get_profile(),
             {:ok, projects} <- Company.list_projects(),
             {:ok, repositories} <- Company.list_repositories(),
             {:ok, goals} <- Goals.list_goals() do
          {:ok,
           %{
             profiles: List.wrap(profile),
             projects: projects,
             repositories: Enum.map(repositories, &catalog_choice/1),
             goals:
               Enum.map(
                 goals,
                 &%{
                   "id" => &1["id"],
                   "content_hash" => Goals.content_hash(&1),
                   "label" => &1["title"]
                 }
               )
           }}
        end
      end)
      |> checked_catalog_choices(current_caller)

    case result do
      {:ok, choices, withheld?} ->
        loaded =
          assign(socket,
            choices: choices,
            choices_error: nil,
            choices_warning:
              if(withheld?,
                do: "Some saved choices are unavailable. Review source access.",
                else: nil
              )
          )

        if socket.assigns.saved["step"] == "outcome", do: loaded, else: scope_choices(loaded)

      _ ->
        assign(socket,
          choices: %{},
          choices_warning: nil,
          choices_error: "Saved choices are unavailable. Reload before acknowledging a selection."
        )
    end
  end

  defp checked_catalog_choices({:ok, choices}, current_caller) do
    with {:ok, profiles} <- available_catalog_rows(choices.profiles, current_caller),
         {:ok, projects} <- available_catalog_rows(choices.projects, current_caller) do
      withheld? =
        length(profiles) != length(choices.profiles) ||
          length(projects) != length(choices.projects)

      {:ok, %{choices | profiles: profiles, projects: projects}, withheld?}
    end
  end

  defp checked_catalog_choices(error, _current_caller), do: error

  # The catalogue transaction has ended before guarded source observations begin.
  defp available_catalog_rows(rows, current_caller) do
    result =
      Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, visible} ->
        case CorpusReview.summary_refs(
               %{"profile_ids" => row["payload"]["source_ids"] || []},
               current_caller
             ) do
          {:ok, %{"unavailable_ids" => []}} ->
            {:cont, {:ok, [catalog_choice(row) | visible]}}

          {:ok, %{"unavailable_ids" => ids}} when is_list(ids) ->
            {:cont, {:ok, visible}}

          {:error, _} = error ->
            {:halt, error}

          _ ->
            {:halt, {:error, :choices_unavailable}}
        end
      end)

    case result do
      {:ok, visible} -> {:ok, Enum.reverse(visible)}
      error -> error
    end
  end

  defp catalog_choice(row) do
    %{
      "id" => row["id"],
      "content_hash" => row["content_hash"],
      "label" => row["payload"]["name"],
      "repository_ids" => row["payload"]["repository_ids"] || [],
      "goal_ids" => row["payload"]["goal_ids"] || []
    }
  end

  defp scope_choices(socket) do
    selection = socket.assigns.saved["selection"]
    project = selection["project"]
    goal = selection["goal"]

    result =
      if project && goal do
        Corpora.guard(caller(socket), fn ->
          with {:ok, corpus} <- Company.bound_corpus(project["id"]) do
            if corpus && corpus["state"] == "active" do
              with {:ok, declarations} <-
                     Corpora.requirements_saved_choice(
                       corpus["id"],
                       project["id"],
                       goal["id"],
                       goal["content_hash"],
                       caller(socket)
                     ) do
                {:ok,
                 %{
                   corpora: [%{"id" => corpus["id"], "label" => corpus["name"]}],
                   declarations:
                     Enum.map(
                       declarations,
                       &Map.put(&1, "label", "Saved coverage revision #{&1["revision"]}")
                     )
                 }}
              end
            else
              {:ok, %{corpora: [], declarations: []}}
            end
          end
        end)
      else
        {:ok, %{corpora: [], declarations: []}}
      end

    case result do
      {:ok, choices} ->
        assign(socket, :choices, Map.merge(socket.assigns.choices, choices))

      _ ->
        assign(socket,
          choices: Map.merge(socket.assigns.choices, %{corpora: [], declarations: []}),
          choices_warning: nil,
          choices_error:
            "Saved source coverage is unavailable or stale. Review corpus scope, then reload saved choices."
        )
    end
  end

  defp clean(attrs) when is_map(attrs) do
    attrs
    |> Enum.reject(fn {k, v} ->
      (is_binary(k) && String.starts_with?(k, "_unused_") && v == "") || (k == "value" && v == "")
    end)
    |> Map.new(fn {k, v} -> {k, if(is_map(v), do: clean(v), else: v)} end)
    |> Map.drop(["_target"])
  end

  defp simple_envelope?(attrs, socket) do
    attrs = clean(attrs)
    attrs == %{"setup_generation" => socket.assigns.generation}
  end

  defp parse_version(value) when is_binary(value) do
    if Regex.match?(~r/\A[1-9][0-9]{0,17}\z/, value),
      do: {:ok, String.to_integer(value)},
      else: :error
  end

  defp parse_version(_), do: :error

  defp navigation_input(attrs, socket) do
    attrs = clean(attrs)

    with true <- Enum.sort(Map.keys(attrs)) == ~w(expected_version setup_generation),
         true <- attrs["setup_generation"] == socket.assigns.generation,
         true <- is_map(socket.assigns.saved),
         {:ok, version} <- parse_version(attrs["expected_version"]) do
      {:ok, version}
    else
      _ -> :error
    end
  end

  defp form_input(attrs, socket, event) do
    attrs = clean(attrs)
    saved = socket.assigns.saved
    fields = if saved && saved["step"] == "outcome", do: @outcome_fields, else: @scope_fields

    allowed =
      if event == "setup_submit",
        do: ~w(expected_version setup setup_command setup_generation),
        else: ~w(expected_version setup setup_generation)

    with true <- is_map(saved) && saved["step"] in ~w(outcome scope),
         true <- Enum.sort(Map.keys(attrs)) == allowed,
         true <- attrs["setup_generation"] == socket.assigns.generation,
         {:ok, version} <- parse_version(attrs["expected_version"]),
         inputs when is_map(inputs) <- attrs["setup"],
         true <- Enum.sort(Map.keys(inputs)) == Enum.sort(fields),
         true <-
           Enum.all?(
             Map.values(inputs),
             &(is_binary(&1) && String.valid?(&1) && byte_size(&1) <= 4096)
           ),
         true <- event == "setup_edit" || attrs["setup_command"] in ~w(save change) do
      {:ok, inputs, version, attrs["setup_command"]}
    else
      _ -> :error
    end
  end

  defp clear_dependents(inputs, previous) do
    cond do
      Map.has_key?(inputs, "project") && inputs["project"] != previous["project"] ->
        Map.merge(inputs, %{"repository" => "", "goal" => ""})

      Map.has_key?(inputs, "profile") && inputs["profile"] != previous["profile"] ->
        Map.put(inputs, "goal", "")

      Map.has_key?(inputs, "corpus_id") && inputs["corpus_id"] != previous["corpus_id"] ->
        Map.put(inputs, "declaration", "")

      true ->
        inputs
    end
  end

  defp submit(socket, "save", version) do
    saved = socket.assigns.saved
    note = if saved["step"] == "outcome", do: "outcome_note", else: "scope_note"

    draft =
      Map.put(saved["draft"], note, socket.assigns.inputs[note])
      |> Map.take(~w(outcome_note scope_note))

    command(socket, "save", %{"draft" => draft}, version)
  end

  defp submit(socket, "change", version) do
    with {:ok, selection} <- selected_refs(socket) do
      command(socket, "change", %{"selection" => selection}, version)
    else
      _ -> fail(socket, "stale_reference")
    end
  end

  defp selected_refs(socket) do
    saved = socket.assigns.saved

    fields =
      if saved["step"] == "outcome",
        do: ~w(profile project repository goal),
        else: ~w(corpus_id declaration)

    initial = if saved["step"] == "outcome", do: %{}, else: saved["selection"]

    Enum.reduce_while(fields, {:ok, initial}, fn key, {:ok, acc} ->
      value = socket.assigns.inputs[key]
      rows = choices_for(socket.assigns, key)
      row = Enum.find(rows, &(choice_value(&1, key) == value))

      cond do
        value == "" ->
          {:cont, {:ok, Map.put(acc, key, nil)}}

        row && key == "corpus_id" ->
          {:cont, {:ok, Map.put(acc, key, row["id"])}}

        row && key == "declaration" ->
          {:cont, {:ok, Map.put(acc, key, Map.take(row, ~w(id digest)))}}

        row ->
          {:cont, {:ok, Map.put(acc, key, Map.take(row, ~w(id content_hash)))}}

        true ->
          {:halt, :error}
      end
    end)
  end

  defp command(socket, name, payload, version) do
    case SetupSessions.command(
           %{
             "id" => socket.assigns.saved["id"],
             "expected_version" => version,
             "command" => name,
             "payload" => payload
           },
           caller(socket)
         ) do
      {:ok, saved} ->
        previous = socket.assigns.inputs
        updated = accept_saved(socket, saved)

        updated =
          if name in ~w(save change) do
            inputs =
              if name == "save",
                do: previous,
                else:
                  Map.merge(
                    updated.assigns.inputs,
                    Map.take(previous, ~w(outcome_note scope_note))
                  )

            dirty = inputs != saved_inputs(saved)

            assign(updated,
              inputs: inputs,
              dirty: dirty,
              notice:
                if(name == "save",
                  do: "Note saved. Changed choices still need Save choices.",
                  else: "Choices saved. Edited notes still need Save note."
                )
            )
          else
            updated
          end

        if name in ~w(back continue),
          do: push_patch(updated, to: saved_path(saved), replace: true),
          else: updated

      {:error, %{"code" => "conflict", "current" => current}} ->
        assign(socket,
          conflict: current,
          error:
            "This setup changed in another view. Your local input is retained. Reload saved setup before retrying.",
          notice: nil
        )

      {:error, error} ->
        fail(socket, error["code"])
    end
  end

  defp choices_for(assigns, key) do
    choices = assigns.choices

    project =
      Enum.find(Map.get(choices, :projects, []), &(ref_token(&1) == assigns.inputs["project"]))

    profile =
      Enum.find(Map.get(choices, :profiles, []), &(ref_token(&1) == assigns.inputs["profile"]))

    case key do
      "profile" ->
        Map.get(choices, :profiles, [])

      "project" ->
        Map.get(choices, :projects, [])

      "repository" ->
        Enum.filter(
          Map.get(choices, :repositories, []),
          &(&1["id"] in ((project && project["repository_ids"]) || []))
        )

      "goal" ->
        Enum.filter(
          Map.get(choices, :goals, []),
          &(&1["id"] in (((profile && profile["goal_ids"]) || []) ++
                           ((project && project["goal_ids"]) || [])))
        )

      "corpus_id" ->
        Map.get(choices, :corpora, [])

      "declaration" ->
        if assigns.inputs["corpus_id"] in [nil, ""],
          do: [],
          else: Map.get(choices, :declarations, [])
    end
  end

  defp choice_value(row, "corpus_id"), do: row["id"]
  defp choice_value(row, _), do: ref_token(row)
  defp fail(socket, code), do: assign(socket, error: error_message(code), notice: nil)

  defp error_message("conflict"),
    do: "This setup changed in another view. Reload saved setup before retrying."

  defp error_message("stale_reference"),
    do:
      "A saved reference changed or is unavailable. Reload the current saved version before choosing and acknowledging current records."

  defp error_message("capability_unavailable"),
    do:
      "This later setup capability is unavailable. Existing workflows remain separate; no work was dispatched."

  defp error_message("unavailable"),
    do:
      "Saved state could not be confirmed. Resolve workspace or privacy access, then reload the current saved version before retrying."

  defp error_message(code) when code in ~w(not_found unauthorized),
    do:
      "This saved setup is unavailable for the current workspace and operator. Its saved state could not be confirmed."

  defp error_message(_),
    do:
      "This setup form changed or contains invalid input. Reload the saved version or correct your local input."

  defp step_title(step), do: Map.get(@titles, step, "Unknown step")
  defp status_label("current"), do: "Saved records match this setup"
  defp status_label("needs_input"), do: "Choose the required records"
  defp status_label("stale"), do: "Some saved records have changed"
  defp status_label(_), do: "Could not check saved choices"

  defp historical_coverage?(assigns) do
    is_map(assigns.saved) and assigns.saved["step"] in ~w(scope understanding) and
      is_map(assigns.analysis) and is_map(assigns.analysis["run"]) and
      is_map(assigns.saved["selection"]["declaration"])
  end

  defp next_reason("outcome_references_required"),
    do: "Choose a company profile, project, repository and assigned goal, then Save choices."

  defp next_reason("scope_references_required"),
    do: "Choose a source collection and saved coverage revision, then Save choices."

  defp next_reason(reason) when reason in ~w(saved_outcome_ready saved_scope_ready),
    do: "Your choices are saved. Continue opens the next step."

  defp next_reason(reason) when reason in ~w(stale_reference reference_unavailable),
    do:
      "Review changed or unavailable choices before continuing. Use Back to update earlier choices."

  defp next_reason("run_authorization_required"),
    do:
      "Review and explicitly authorize the exact prepared local evidence below before opening Understanding."

  defp next_reason(_),
    do: "This step is not available here yet. You can use the separate workflows below."

  # Presentation only. Command handlers and their admission/disabled checks stay authoritative.
  defp primary_action(%{ready: false}), do: nil
  defp primary_action(%{saved: nil}), do: nil

  defp primary_action(assigns) do
    saved = saved_inputs(assigns.saved)

    fields =
      if assigns.saved["step"] == "outcome",
        do: ~w(profile project repository goal),
        else: ~w(corpus_id declaration)

    note = if assigns.saved["step"] == "outcome", do: "outcome_note", else: "scope_note"

    cond do
      assigns.conflict || (assigns.choices_error && is_nil(assigns.analysis)) -> "reload"
      Enum.any?(fields, &(assigns.inputs[&1] != saved[&1])) -> "choices"
      assigns.inputs[note] != saved[note] -> "note"
      assigns.analysis && run_primary(assigns.analysis) -> nil
      assigns.saved["next_action"]["code"] == "continue" && !assigns.dirty -> "continue"
      true -> nil
    end
  end

  defp corpus_path(saved) do
    refs = saved["reference_status"]
    declaration = saved["selection"]["declaration"]

    if refs["status"] == "current" && refs["fields"]["declaration"] == "current" &&
         refs["fields"]["corpus_id"] == "current" && is_map(declaration) do
      "/company/corpus?" <>
        URI.encode_query(%{
          "declaration" => declaration["id"],
          "declaration_digest" => declaration["digest"]
        })
    else
      "/company/corpus"
    end
  end

  attr :field, :string, required: true
  attr :label, :string, required: true
  attr :rows, :list, required: true
  attr :value, :string, required: true
  attr :disabled, :boolean, default: false
  attr :historical, :boolean, default: false
  attr :create_href, :any, default: nil
  attr :create_available, :boolean, default: false
  attr :create_dirty, :boolean, default: false

  defp choice(assigns) do
    assigns =
      assign(
        assigns,
        :off_page,
        assigns.value != "" &&
          !Enum.any?(assigns.rows, &(choice_value(&1, assigns.field) == assigns.value))
      )

    ~H"""
    <div>
      <label for={"setup-" <> String.replace(@field, "_id", "")}>{@label}</label>
      <select
        id={"setup-" <> String.replace(@field, "_id", "")}
        name={"setup[#{@field}]"}
        disabled={@disabled}
      >
        <option value="" selected={@value == ""}>Choose {@label}</option>
        <option :if={@off_page} value={@value} selected>
          {if @historical,
            do: "Previously saved coverage reference · retained for this setup",
            else: "Previously saved reference · recheck before acknowledgement"}
        </option>
        <option
          :for={row <- @rows}
          value={choice_value(row, @field)}
          selected={choice_value(row, @field) == @value}
        >
          {row["label"]}
        </option>
      </select>
      <p
        :if={@rows == [] && @value == "" && @field in ~w(profile project repository goal)}
        id={"setup-empty-" <> @field}
        class="field-help"
      >
        No {@label} choice is available.
        <.link
          :if={@create_href && @create_available}
          id={"setup-create-" <> @field}
          href={@create_href}
          class="button secondary"
        >Create {@label}</.link>
        <span :if={@create_dirty}>Save your note and choices before leaving this saved setup.</span>
        <span :if={!@create_dirty && !@create_available}>Finish the current action or reload saved choices before creating a record.</span>
      </p>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        primary_action: primary_action(assigns),
        historical_coverage: historical_coverage?(assigns)
      )

    ~H"""
    <main
      id="setup-workbench"
      class="content company-builder"
      aria-label="Saved company setup"
      phx-disconnected={
        JS.set_attribute({"disabled", ""}, to: "#setup-connected-controls")
        |> JS.remove_attribute("hidden", to: "#setup-connecting")
      }
      phx-connected={
        JS.remove_attribute("disabled", to: "#setup-connected-controls")
        |> JS.set_attribute({"hidden", ""}, to: "#setup-connecting")
      }
    >
      <.link id="setup-return-home" href={home_path(@saved)} class="button secondary">Return to Home</.link>
      <h1>Saved company setup</h1>
      <p>
        Save company context, choose sources, then use the explicit local analysis controls. Notes are optional.
      </p>
      <p id="setup-connecting" role="status" hidden={@ready}>
        Connecting. Saved actions become available when the workspace connection is ready.
      </p>
      <p :if={@error} id="setup-error" class="notice error" role="alert">{@error}</p>
      <p :if={@notice} id="setup-notice" class="notice" role="status">{@notice}</p>
      <p :if={@dirty} id="setup-unsaved" role="status">
        Unsaved local input. Continue and Back do not save it.
      </p>
      <p :if={@conflict} id="setup-conflict" role="alert">
        Current saved version: {@conflict["version"]}. Your input remains local until you reload.
      </p>
      <fieldset
        id="setup-connected-controls"
        class="company-analysis-selection"
        disabled={!@ready}
        aria-label="Saved setup controls"
      >
        <%= if @saved do %>
          <section id="setup-session" class="panel" aria-labelledby="setup-step-title">
            <p id="setup-saved-version">Saved version {@saved["version"]} · {@saved["updated_at"]}</p>
            <ol id="setup-context-steps" aria-label="Editable context steps">
              <li aria-current={@saved["step"] == "outcome" && "step"}>Company context</li>
              <li aria-current={@saved["step"] == "scope" && "step"}>Source scope</li>
            </ol>
            <h2 id="setup-step-title">{step_title(@saved["step"])}</h2>
            <p id="setup-reference-status" role="status">
              {status_label(@saved["reference_status"]["status"])}
            </p>
            <p id="setup-next-reason">{next_reason(@saved["next_action"]["reason"])}</p>
            <p :if={@choices_error} id="setup-choices-error" class="notice error" role="alert">
              {@choices_error}
            </p>
            <p :if={@choices_warning} id="setup-choices-warning" class="notice" role="status">
              {@choices_warning}
            </p>
            <p :if={@historical_coverage} id="setup-saved-coverage" class="field-help">
              Previously saved coverage: <code>{ref_token(@saved["selection"]["declaration"])}</code>.
              A newer capture may supersede this saved coverage reference. Review the current run's capture and exact preparation below.
            </p>
            <.analysis_panel
              :if={@analysis && @saved["step"] in ~w(scope understanding)}
              view={@analysis}
              generation={@generation}
              command_id={@analysis_command_id}
              connection={@analysis_connection}
              connections={@analysis_connections}
              capture={@analysis_capture}
              connection_name={@analysis_connection_name}
              busy={@analysis_busy}
              error={@analysis_error}
              disabled={!@ready || @dirty || !is_nil(@conflict)}
            />
            <p :if={@analysis_error && is_nil(@analysis)} id="setup-analysis-error" role="alert">
              {@analysis_error}
            </p>
            <%= if @saved["step"] in ~w(outcome scope) do %>
              <.form
                for={%{}}
                id="setup-step-form"
                phx-change="setup_edit"
                phx-submit="setup_submit"
                phx-auto-recover="ignore"
                class="stack"
              >
                <input type="hidden" name="setup_generation" value={@generation} />
                <input type="hidden" name="expected_version" value={@saved["version"]} />
                <%= if @saved["step"] == "outcome" do %>
                  <.choice
                    :for={
                      {field, label} <- [
                        {"profile", "company profile"},
                        {"project", "project"},
                        {"repository", "repository"},
                        {"goal", "assigned saved goal"}
                      ]
                    }
                    field={field}
                    label={label}
                    rows={choices_for(assigns, field)}
                    value={@inputs[field] || ""}
                    disabled={@analysis_busy}
                    create_href={creation_path(@saved, field)}
                    create_available={
                      @ready && !@dirty && !@analysis_busy && is_nil(@conflict) &&
                        is_nil(@choices_error)
                    }
                    create_dirty={@dirty}
                  />
                  <p class="field-help">
                    Saving these choices clears later source choices in this setup. Company records stay unchanged.
                  </p>
                <% else %>
                  <.choice
                    field="corpus_id"
                    label="saved source corpus"
                    rows={choices_for(assigns, "corpus_id")}
                    value={@inputs["corpus_id"] || ""}
                    disabled={@analysis_busy}
                  />
                  <.choice
                    field="declaration"
                    label={
                      if @historical_coverage,
                        do: "Previously saved coverage",
                        else: "saved coverage declaration"
                    }
                    rows={choices_for(assigns, "declaration")}
                    value={@inputs["declaration"] || ""}
                    disabled={@analysis_busy}
                    historical={@historical_coverage}
                  />
                  <p :if={Map.get(@choices, :declarations, []) == []} id="setup-no-declaration">
                    No current saved coverage choice is available. A new local run can capture the saved corpus and record exact coverage, or
                    <.link href="/company/corpus">review existing corpus coverage</.link>
                    and reload choices.
                  </p>
                  <p class="field-help">
                    Saved source choices do not confirm that sources are complete or up to date.
                  </p>
                <% end %>
                <details id="setup-optional-note" open={@primary_action == "note"}>
                  <summary>Optional note</summary>
                  <%= if @saved["step"] == "outcome" do %>
                    <label for="setup-outcome-note">Outcome draft</label>
                    <textarea
                      id="setup-outcome-note"
                      name="setup[outcome_note]"
                      maxlength="2048"
                      rows="3"
                      disabled={@analysis_busy}
                      aria-describedby="setup-note-help"
                    >{@inputs["outcome_note"]}</textarea>
                    <p id="setup-measurement" class="field-help">
                      Measurement status: unknown. The saved goal records your intent; results have not been measured here.
                    </p>
                  <% else %>
                    <label for="setup-scope-note">Scope draft</label>
                    <textarea
                      id="setup-scope-note"
                      name="setup[scope_note]"
                      maxlength="2048"
                      rows="3"
                      disabled={@analysis_busy}
                      aria-describedby="setup-note-help"
                    >{@inputs["scope_note"]}</textarea>
                  <% end %>
                  <p id="setup-note-help" class="field-help">
                    Save note saves only this note. Save choices saves only the selections. Save all changes before continuing. Limit: 2,048 bytes per note.
                    <%= if @saved["step"] == "outcome" do %>
                      Changing the outcome note cancels any current run and revokes its authorization. Retained usage remains.
                    <% end %>
                  </p>
                  <button
                    id="setup-save"
                    name="setup_command"
                    value="save"
                    type="submit"
                    class={
                      if @primary_action == "note", do: "button primary", else: "button secondary"
                    }
                    disabled={!@ready || @analysis_busy}
                  >Save note</button>
                </details>
                <p id="setup-choices-run-warning" class="field-help">
                  Saving choices cancels any current run and revokes its authorization. Retained usage remains.
                </p>
                <div class="company-actions">
                  <button
                    id="setup-acknowledge"
                    name="setup_command"
                    value="change"
                    type="submit"
                    class={
                      if @primary_action == "choices", do: "button primary", else: "button secondary"
                    }
                    aria-describedby="setup-choices-run-warning"
                    disabled={!@ready || @analysis_busy || !is_nil(@choices_error)}
                  >Save choices</button>
                </div>
              </.form>
            <% else %>
              <div id="setup-capability-unavailable" class="context-note">
                <h3>
                  {if @saved["step"] == "understanding" && @analysis && @analysis["run"],
                    do: "Your context is saved",
                    else: "Continue in a separate workflow"}
                </h3>
                <p>
                  Local analysis uses only the explicit controls above. Open evidence review to inspect current sources and proposed claims; opening it does not save, approve or run anything.
                </p>
                <div class="company-actions">
                  <.link id="setup-open-corpus" href={corpus_path(@saved)} class="button secondary">Open evidence review</.link>
                </div>
              </div>
            <% end %>
            <div class="company-actions">
              <button
                id="setup-back"
                type="button"
                class="button secondary"
                phx-click="setup_back"
                phx-value-setup_generation={@generation}
                phx-value-expected_version={@saved["version"]}
                disabled={!@ready || @analysis_busy || @saved["step"] == "outcome"}
              >Back</button>
              <button
                id="setup-continue"
                type="button"
                class={
                  if @primary_action == "continue", do: "button primary", else: "button secondary"
                }
                phx-click="setup_continue"
                phx-value-setup_generation={@generation}
                phx-value-expected_version={@saved["version"]}
                disabled={
                  !@ready || @analysis_busy || @saved["next_action"]["code"] != "continue" || @dirty ||
                    !is_nil(@conflict)
                }
              >Continue</button>
              <button
                id="setup-reload"
                type="button"
                class={if @primary_action == "reload", do: "button primary", else: "button secondary"}
                phx-click="setup_reload"
                phx-value-setup_generation={@generation}
                disabled={!@ready}
              >Reload saved setup{if @dirty || @conflict, do: " (discard local input)"}</button>
            </div>
            <details id="setup-steps">
              <summary>Later workflows and saved references</summary>
              <p>
                Plan review, harness building, task checks and release are separate workflows. They are not editable steps in this setup.
              </p>
              <div class="company-actions">
                <.link href={home_path(@saved)} class="button secondary">Review company workflow</.link>
                <.link href="/?view=package" class="button secondary">Your harnesses</.link>
              </div>
              <p>
                Company context and source scope are editable here. Local analysis requires explicit capture, preparation and authorization. Saved setup does not establish task or release qualification.
              </p>
              <p>
                Setup <code>{@saved["id"]}</code>. Workspace-local operator ownership survives reauthentication; it is not named-user isolation.
              </p>
              <p :for={{field, status} <- @saved["reference_status"]["fields"]}>{field}: {status}</p>
            </details>
          </section>
        <% else %>
          <section class="panel" aria-labelledby="setup-list-title">
            <h2 id="setup-list-title">Your saved setups</h2>
            <button
              id="setup-create"
              type="button"
              class="button primary"
              phx-click="setup_create"
              phx-value-setup_generation={@generation}
              disabled={!@ready}
            >Create saved setup</button>
            <button
              :if={@saved_id}
              id="setup-reload"
              type="button"
              class="button secondary"
              phx-click="setup_reload"
              phx-value-setup_generation={@generation}
              disabled={!@ready}
            >Reload saved setup</button>
            <p :if={@sessions == []}>
              No saved setups are shown. Creating one is an explicit action.
            </p>
            <ul>
              <li :for={saved <- @sessions}>
                <.link href={saved_path(saved)}>Reopen {step_title(saved["step"])} · version {saved[
                  "version"
                ]} · {saved["updated_at"]}</.link>
              </li>
            </ul>
            <p>
              Up to 20 most recently updated setups. Reopening never repeats a save, consent or operation.
            </p>
          </section>
        <% end %>
      </fieldset>
    </main>
    """
  end
end
