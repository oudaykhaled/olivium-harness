defmodule HarnessForgeWeb.PortalLive do
  use HarnessForgeWeb, :live_view
  alias HarnessForge.{Evidence, Decisions, Goals, Audit, Workspaces}
  alias HarnessForgeWeb.{CompanyAssessmentState, PackageBuild, PackageExport}
  alias HarnessForgeWeb.Company.Analysis, as: AnalysisUI
  alias HarnessForgeWeb.Plugs.OperatorSession
  alias HarnessForge.Company.{Analysis, CorpusReview, SetupSessions}

  @tabs ~w(chat company evidence connections goals package evaluations releases audit privacy)
  @assessment_events ~w(company_assessment_open assessment_goal_change assessment_rubric_change assessment_rubric_freeze assessment_attempt_start assessment_result_change assessment_record assessment_history_open assessment_discard assessment_departure_resolve)
  @company_destinations %{
    "connections" => "connections-panel",
    "evidence" => "evidence-panel",
    "goals" => "goals-panel",
    "package" => "package-panel",
    "evaluations" => "evaluations-panel",
    "releases" => "releases-panel"
  }

  @readiness_destinations Map.take(
                            Map.put(@company_destinations, "company", "company-panel"),
                            ~w(company connections evaluations releases package)
                          )

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(HarnessForge.PubSub, "workspace:" <> Workspaces.current_id())
      Process.send_after(self(), :refresh_evaluations, 2_000)
    end

    {:ok,
     socket
     |> detach_hook(:authenticate_event, :handle_event)
     |> attach_hook(:authenticate_event, :handle_event, &authenticate_portal_event/3)
     |> assign(:page_title, "Workspace")
     |> assign(:tab, "company")
     |> assign(:query, "")
     |> assign(:remote_provider, "github")
     |> assign(:search_results, nil)
     |> assign(:source_cursor_stack, [nil])
     |> assign(:source_page, %{"rows" => [], "next_cursor" => nil})
     |> assign(:source_total, nil)
     |> assign(:source_passage, nil)
     |> assign(:source_passage_token, nil)
     |> assign(:model_source_ids, nil)
     |> assign(:model_source_error, false)
     |> assign(:model_selected_sources, [])
     |> assign(
       :source_view_generation,
       Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
     )
     |> reset_build()
     |> reset_export()
     |> assign(:diff, nil)
     |> assign(:comparison, nil)
     |> reset_command_review()
     |> assign(:command_approval_notice, nil)
     |> assign(:privacy_result, nil)
     |> reset_goal_claim()
     |> reset_readiness()
     |> assign(:company_reset_token, 0)
     |> assign(:company_sensitive_reset_token, 0)
     |> assign(:company_refresh_token, 0)
     |> assign(:company_analysis_pending, nil)
     |> assign(:requested_company_review, nil)
     |> assign(:home_setup_id, nil)
     |> assign(:home_setup_invalid, false)
     |> assign(:setup_creation_request, nil)
     |> assign(:setup_goal_dirty, false)
     |> assign(:evidence_review, nil)
     |> reset_assessment()
     |> assign(:chat_turns, [])
     |> assign(:chat_pending, nil)
     |> assign(:chat_error, nil)
     |> assign(:chat_run_id, Ecto.UUID.generate())
     |> assign(:chat_generation, Ecto.UUID.generate())
     |> assign(:chat_mode, "assistant")
     |> assign(:chat_requires_live, false)
     |> assign(:account_service, "github")
     |> assign(:account_pending, nil)
     |> assign(:workspace_id, Workspaces.current_id())
     |> assign(:workspace_root, Workspaces.root())
     |> reload()}
  end

  @impl true
  def handle_params(%{"company_review" => id, "revision_hash" => hash}, _uri, socket) do
    socket = home_setup_selector(socket, nil, false)

    case current_review(id, hash) do
      {:ok, _} ->
        request = %{"id" => id, "revision_hash" => hash, "request_id" => Ecto.UUID.generate()}
        {:noreply, socket |> change_tab("company") |> assign(:requested_company_review, request)}

      _ ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "This recommendation changed or is unavailable. Select current evidence before review."
         )}
    end
  end

  def handle_params(%{"create" => _} = params, _uri, socket),
    do: {:noreply, open_setup_creation(socket, params)}

  def handle_params(%{"return_setup" => _} = params, _uri, socket),
    do: {:noreply, open_setup_creation(socket, params)}

  def handle_params(%{"return_step" => _} = params, _uri, socket),
    do: {:noreply, open_setup_creation(socket, params)}

  def handle_params(%{"setup" => tab}, _uri, socket)
      when tab in ~w(company connections goals) do
    {:noreply, socket |> home_setup_selector(nil, false) |> change_tab(tab)}
  end

  def handle_params(%{"setup" => id}, _uri, socket) do
    socket =
      case Ecto.UUID.cast(id) do
        {:ok, id} -> home_setup_selector(socket, id, false)
        :error -> home_setup_selector(socket, nil, true)
      end

    {:noreply, change_tab(socket, "company")}
  end

  def handle_params(%{"view" => tab}, _uri, socket) when tab in @tabs,
    do: {:noreply, socket |> home_setup_selector(nil, false) |> change_tab(tab)}

  def handle_params(_, _uri, socket),
    do: {:noreply, home_setup_selector(socket, nil, false)}

  defp home_setup_selector(socket, id, invalid),
    do:
      assign(socket,
        home_setup_id: id,
        home_setup_invalid: invalid,
        setup_creation_request: nil,
        setup_goal_dirty: false
      )

  defp open_setup_creation(socket, params) do
    cond do
      not setup_authorized?(socket) ->
        revoke_operator(socket)

      socket.assigns.assessment_state["dirty"] ->
        put_flash(
          socket,
          :error,
          "Record or discard your assessment draft before creating saved choices."
        )

      true ->
        with true <- Enum.sort(Map.keys(params)) == ~w(create return_setup return_step),
             section when section in ~w(profile repository project goal) <- params["create"],
             step when step in ~w(outcome scope) <- params["return_step"],
             {:ok, id} <- Ecto.UUID.cast(params["return_setup"]),
             {:ok, saved} <- setup_creation_target(id, setup_caller(socket)) do
          request = %{
            "request_id" => Ecto.UUID.generate(),
            "section" => section,
            "return_id" => saved["id"],
            "return_step" => saved["step"],
            "return_path" => "/setup/" <> saved["id"] <> "/" <> saved["step"],
            "reset_token" => socket.assigns.company_reset_token
          }

          socket
          |> home_setup_selector(saved["id"], false)
          |> assign(:setup_creation_request, request)
          |> change_tab(if(section == "goal", do: "goals", else: "company"))
        else
          {:error, %{"code" => "unauthorized"}} -> revoke_operator(socket)
          {:error, %{"code" => code}} -> setup_creation_failure(socket, params, code)
          _ -> setup_creation_failure(socket, params, "invalid_input")
        end
    end
  end

  defp setup_creation_target(id, caller) do
    case SetupSessions.get(%{"id" => id}, caller) do
      {:ok, %{"id" => ^id, "step" => step}} when step in ~w(outcome scope) ->
        {:ok, %{"id" => id, "step" => step}}

      {:error, _} = failure ->
        failure

      _ ->
        {:error, %{"code" => "unavailable"}}
    end
  end

  defp setup_creation_failure(socket, params, code) do
    socket =
      case Ecto.UUID.cast(params["return_setup"]) do
        {:ok, id} -> home_setup_selector(socket, id, false)
        _ -> home_setup_selector(socket, nil, true)
      end

    socket
    |> change_tab("company")
    |> put_flash(:error, setup_navigation_error(code))
  end

  @impl true
  def handle_event("tab", %{"tab" => tab}, socket) when tab in @tabs do
    {:noreply, change_tab(socket, tab)}
  end

  def handle_event(event, attrs, socket) when event in @assessment_events do
    case CompanyAssessmentState.envelope(attrs, socket.assigns.assessment_event_generation, event) do
      {:ok, payload} when socket.assigns.tab == "company" ->
        {:noreply, assessment_event(socket, event, payload)}

      _ ->
        if is_map(attrs) and
             attrs["assessment_event_generation"] == socket.assigns.assessment_event_generation and
             socket.assigns.tab == "company" and
             event in ~w(assessment_rubric_change assessment_rubric_freeze assessment_result_change assessment_record) do
          {:noreply,
           assign(
             socket,
             :assessment_state,
             CompanyAssessmentState.uncaptured(socket.assigns.assessment_state)
           )}
        else
          {:noreply, socket}
        end
    end
  end

  def handle_event("chat_send", %{"chat" => attrs}, socket) when is_map(attrs) do
    question = attrs["question"]

    cond do
      socket.assigns.chat_pending != nil ->
        {:noreply, socket}

      not is_binary(question) or byte_size(question) > 4_000 or
        not String.valid?(question) or String.trim(question) == "" ->
        {:noreply, assign(socket, :chat_error, "Enter a question of at most 4,000 UTF-8 bytes.")}

      attrs["mode"] not in ~w(assistant evidence model) ->
        {:noreply,
         assign(
           socket,
           :chat_error,
           "Choose evidence search, live assistant or the configured AI model."
         )}

      true ->
        start_chat(socket, String.trim(question), attrs["mode"])
    end
  end

  def handle_event("chat_mode_changed", %{"chat" => %{"mode" => mode}}, socket)
      when mode in ~w(assistant evidence model),
      do: {:noreply, assign(socket, :chat_mode, mode)}

  def handle_event("chat_use_assistant", _attrs, socket),
    do:
      {:noreply,
       assign(socket, chat_mode: "assistant", chat_error: nil, chat_requires_live: false)}

  def handle_event("account_setup", %{"service" => service}, socket)
      when service in ~w(github github_projects slack jira confluence),
      do: {:noreply, socket |> change_tab("connections") |> assign(:account_service, service)}

  def handle_event("account_changed", %{"account" => %{"service" => service}}, socket)
      when service in ~w(github github_projects slack jira confluence),
      do: {:noreply, assign(socket, :account_service, service)}

  def handle_event("account_connect", %{"account" => attrs}, socket) when is_map(attrs) do
    if socket.assigns.account_pending do
      {:noreply, socket}
    else
      config =
        Map.take(attrs, ~w(service credential_ref endpoint username_ref))
        |> Map.reject(fn {_key, value} -> value == "" end)

      auth = socket.assigns.operator_auth
      token = Ecto.UUID.generate()

      {:noreply,
       socket
       |> clear_flash()
       |> assign(:account_pending, token)
       |> start_async({:account_connect, token}, fn ->
         HarnessForge.Accounts.connect(config,
           authorize: fn -> HarnessForgeWeb.Plugs.OperatorSession.valid?(auth) end
         )
       end)}
    end
  end

  def handle_event("account_disconnect", %{"id" => id}, socket),
    do: finish(socket, HarnessForge.Accounts.disconnect(id), "Live account access disconnected.")

  def handle_event("chat_clear", _attrs, socket),
    do: {:noreply, socket |> reset_chat() |> push_event("chat-clear-composer", %{})}

  def handle_event("chat_sync", %{"id" => id}, socket) do
    result =
      with {:ok, connections} <- Evidence.list_connections(),
           true <- Enum.any?(connections, &(&1["id"] == id and &1["status"] == "active")) do
        enqueue("sync", id)
      else
        _ -> {:error, :source_unavailable}
      end

    finish(socket, result, "Selected connector sync queued. One bounded page will be captured.")
  end

  def handle_event("demo", _params, socket) do
    finish(
      socket,
      invoke(HarnessForge.Demo, :load, []),
      "Synthetic examples loaded. Review each claim before approval."
    )
  end

  def handle_event("connect", %{"connection" => attrs}, socket) do
    finish(
      socket,
      Evidence.connect(Map.put(attrs, "provider", "local")),
      "Local directory connected. Select Import to capture its text files."
    )
  end

  def handle_event("import", %{"id" => id}, socket) do
    finish(
      socket,
      enqueue("sync", id),
      "Source sync queued. Each bounded page reports whether more pages remain."
    )
  end

  def handle_event("remote_changed", %{"remote" => %{"provider" => provider}}, socket)
      when provider in ~w(github jira github_projects slack confluence) do
    {:noreply, assign(socket, :remote_provider, provider)}
  end

  def handle_event("connect_remote", %{"remote" => attrs}, socket) do
    keys =
      case attrs["provider"] do
        "github" -> ~w(repository credential_ref)
        "jira" -> ~w(endpoint project credential_ref username_ref)
        "github_projects" -> ~w(project_url credential_ref)
        "slack" -> ~w(team_id channel_id credential_ref)
        "confluence" -> ~w(endpoint space_id credential_ref username_ref)
        _ -> []
      end

    config = Map.take(attrs, keys) |> Map.reject(fn {_k, v} -> v == "" end)

    finish(
      socket,
      Evidence.connect(%{
        "name" => attrs["name"],
        "provider" => attrs["provider"],
        "config" => config
      }),
      "Read-only connection saved. Sync explicitly to import the selected scope."
    )
  end

  def handle_event("model_changed", %{"model" => %{"provider" => provider} = attrs}, socket)
      when provider in ~w(ollama openai openai_responses anthropic) do
    {:noreply, socket |> assign(:model_provider, provider) |> capture_model_sources(attrs)}
  end

  def handle_event("model_configure", %{"model" => attrs}, socket) do
    socket = capture_model_sources(socket, attrs)

    result =
      with true <- not socket.assigns.model_source_error,
           attrs = Map.put(attrs, "source_ids", socket.assigns.model_source_ids || []),
           {:ok, config} <- model_configuration(attrs),
           do: HarnessForge.Models.configure(config)

    result = if result == false, do: {:error, :invalid_model_configuration}, else: result

    finish(
      socket,
      result,
      "Model settings saved. No inference was started. Cloud use requires source consent; chat and Company analysis each require their own context consent."
    )
  end

  def handle_event("model_propose", %{"id" => id}, socket),
    do:
      finish(
        socket,
        enqueue("propose", id),
        "Model proposal queued. Every extracted claim still requires review."
      )

  def handle_event("readiness_select", %{"readiness" => attrs}, socket) when is_map(attrs) do
    readiness_event(socket, attrs, fn socket ->
      {:noreply, select_readiness(socket, attrs)}
    end)
  end

  def handle_event("inspect_readiness", %{"readiness" => attrs}, socket) when is_map(attrs) do
    readiness_event(socket, attrs, fn socket ->
      if readiness_pair(socket) == submitted_readiness_pair(attrs) do
        socket = refresh_readiness_records(socket)

        case HarnessForge.Readiness.for_artifact(
               socket.assigns.readiness_digest,
               socket.assigns.readiness_evaluation_id
             ) do
          {:ok, report} ->
            {:noreply, assign(socket, readiness_report: report, readiness_message: nil)}

          {:error, _reason} ->
            {:noreply,
             assign(socket,
               readiness_report: nil,
               readiness_message:
                 "Readiness is unavailable. Check the selection and workspace privacy state, then refresh."
             )}
        end
      else
        {:noreply, select_readiness(socket, attrs)}
      end
    end)
  end

  def handle_event("readiness_next", attrs, socket) when is_map(attrs) do
    readiness_event(socket, attrs, fn socket ->
      destination = get_in(socket.assigns.readiness_report || %{}, ["next_action", "destination"])

      if is_map_key(@readiness_destinations, destination) do
        {:noreply,
         socket
         |> change_tab(destination)
         |> push_event("company-focus", %{id: @readiness_destinations[destination]})}
      else
        {:noreply, socket}
      end
    end)
  end

  def handle_event("evaluate", %{"evaluation" => %{"digest" => id, "kind" => kind}}, socket) do
    finish(
      socket,
      enqueue("evaluate", id, %{"kind" => kind}),
      "Evaluation queued. Inspect its actual recorded outcome."
    )
  end

  def handle_event("release_approve", %{"release" => attrs}, socket) do
    result =
      with {:ok, artifact} <- HarnessForge.Harnesses.get(attrs["artifact_digest"]) do
        HarnessForge.Releases.approve(
          Map.merge(attrs, %{
            "actor" => Workspaces.operator(),
            "scope" => artifact["spec"]["spec"]["scope"]
          })
        )
      end

    finish(socket, result, "Approval recorded for the exact qualified artifact and evaluation.")
  end

  def handle_event("cancel_run", %{"id" => id}, socket),
    do:
      finish(
        socket,
        HarnessForge.Evaluations.cancel(id),
        "Cancellation processed. Inspect the recorded cleanup state."
      )

  def handle_event("command_review_open", %{"id" => id} = attrs, socket)
      when map_size(attrs) == 1 do
    if socket.assigns.tab == "evaluations" do
      {:noreply, load_command_requests(socket, id)}
    else
      {:noreply, reset_command_review(socket)}
    end
  end

  def handle_event("command_approval_decide", envelope, socket) when is_map(envelope) do
    socket = assign(socket, command_requests: [], command_review_message: nil)

    if socket.assigns.tab == "evaluations" and
         is_binary(socket.assigns.command_review_run) and
         envelope["run_id"] == socket.assigns.command_review_run do
      result = HarnessForge.Execution.CommandApprovals.decide(envelope, command_caller(socket))

      message =
        case result do
          {:ok, %{"state" => "accepted"}} ->
            "One decision recorded. Execution and task results are separate."

          {:ok, %{"state" => "consumed"}} ->
            "This decision was already delivered; it cannot be reused."

          {:ok, _} ->
            "Denial recorded."

          _ ->
            "The decision could not be confirmed. Review the current request before trying again."
        end

      {:noreply,
       socket
       |> refresh_command_requests()
       |> assign(:command_review_message, message)}
    else
      {:noreply, reset_command_review(socket)}
    end
  end

  def handle_event(
        "compare_runs",
        %{"comparison" => %{"baseline" => baseline, "candidate" => candidate}},
        socket
      ) do
    case HarnessForge.Evaluations.compare(baseline, candidate) do
      {:ok, result} ->
        finish(assign(socket, :comparison, result), {:ok, result}, "Evaluation records compared.")

      error ->
        finish(socket, error, "")
    end
  end

  def handle_event(action, %{"id" => id} = attrs, socket)
      when action in ["promote", "rollback"] do
    expected = if attrs["expected"] in [nil, ""], do: nil, else: attrs["expected"]

    result =
      if action == "promote",
        do: HarnessForge.Releases.promote(id, expected),
        else: HarnessForge.Releases.rollback(id, expected)

    finish(
      socket,
      result,
      "Pilot channel assignment recorded. Export is a separate local operation."
    )
  end

  def handle_event("diff", %{"diff" => %{"left" => left, "right" => right}}, socket) do
    case HarnessForge.Releases.diff(left, right) do
      {:ok, diff} -> {:noreply, assign(socket, :diff, diff)}
      error -> finish(socket, error, "")
    end
  end

  def handle_event("search", %{"query" => query}, socket) when is_binary(query) do
    {:noreply,
     socket
     |> assign(query: query, source_cursor_stack: [nil], source_passage: nil)
     |> load_source_page(nil)}
  end

  def handle_event("source_page_next", _attrs, socket) do
    next = socket.assigns.source_page["next_cursor"]

    {:noreply,
     if(next,
       do:
         socket
         |> assign(:source_cursor_stack, [next | socket.assigns.source_cursor_stack])
         |> load_source_page(next),
       else: socket
     )}
  end

  def handle_event("source_page_previous", _attrs, socket) do
    case socket.assigns.source_cursor_stack do
      [_, previous | rest] ->
        {:noreply,
         socket |> assign(:source_cursor_stack, [previous | rest]) |> load_source_page(previous)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("source_open", %{"id" => id}, socket) do
    source = Enum.find(socket.assigns.sources, &(&1["id"] == id))
    revision = source && source["latest_revision"]

    if revision do
      attrs = %{
        "source_id" => id,
        "revision_id" => revision["id"],
        "body_hash" => revision["body_hash"],
        "start_byte" => source["match_start_byte"] || 0
      }

      {:noreply, read_source_passage(socket, source["passage_token"], attrs)}
    else
      {:noreply, assign(socket, :source_passage, nil)}
    end
  end

  def handle_event("source_passage_next", _attrs, socket) do
    passage = socket.assigns.source_passage

    if passage && passage["next_start_byte"] do
      attrs = %{
        "source_id" => passage["source"]["id"],
        "revision_id" => passage["revision_id"],
        "body_hash" => passage["body_hash"],
        "start_byte" => passage["next_start_byte"]
      }

      {:noreply, read_source_passage(socket, socket.assigns.source_passage_token, attrs)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("source_passage_first", _attrs, socket) do
    passage = socket.assigns.source_passage

    if passage && passage["truncated_before"] do
      attrs = %{
        "source_id" => passage["source"]["id"],
        "revision_id" => passage["revision_id"],
        "body_hash" => passage["body_hash"],
        "start_byte" => 0
      }

      {:noreply, read_source_passage(socket, socket.assigns.source_passage_token, attrs)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("source_close", _attrs, socket) do
    {:noreply,
     socket
     |> assign(source_passage: nil, source_passage_token: nil)
     |> push_event("company-focus", %{id: "source-snapshots"})}
  end

  def handle_event("propose", %{"claim" => attrs}, socket) do
    result =
      with snapshot when is_binary(snapshot) <- attrs["source_snapshot"],
           [source_id, revision_id] <- String.split(snapshot, ":", parts: 2),
           {:ok, source} <- Evidence.get_source(source_id),
           revision when is_map(revision) <- source["latest_revision"],
           true <- revision["id"] == revision_id,
           {:ok, citation} <- Evidence.citation(revision["id"], 0, byte_size(revision["body"])),
           {:ok, claim} <-
             Evidence.create_claim(%{"text" => attrs["text"], "citations" => [citation]}) do
        {:ok, claim}
      else
        false -> {:error, :stale_revision}
        nil -> {:error, :source_unavailable}
        [_] -> {:error, :invalid_input}
        error -> error
      end

    finish(
      socket,
      result,
      "Claim proposed with its source citation. Approval is a separate decision."
    )
  end

  def handle_event("goal_claim_change", attrs, socket) do
    case goal_claim_input(attrs, socket) do
      {:ok, draft} -> {:noreply, assign(socket, :goal_claim_draft, draft)}
      error -> finish(socket, error, "")
    end
  end

  def handle_event("propose_goal", attrs, socket) do
    result =
      with {:ok, draft} <- goal_claim_input(attrs, socket),
           [id, hash] <- String.split(draft["goal_snapshot"], ":", parts: 2) do
        Evidence.create_claim(%{
          "text" => draft["text"],
          "citations" => [],
          "basis" => %{
            "version" => 1,
            "kind" => "goal",
            "goal_id" => id,
            "goal_content_hash" => hash
          }
        })
      else
        [_] -> {:error, :invalid_claim_basis}
        error -> error
      end

    socket =
      if match?({:ok, _}, result),
        do: socket |> reset_goal_claim() |> push_event("company-focus", %{id: "evidence-panel"}),
        else: socket

    finish(
      socket,
      result,
      "Goal-based rule proposed. Review its saved goal and exact revision before deciding."
    )
  end

  def handle_event("company_analysis_review", %{"id" => id, "revision_hash" => hash}, socket) do
    case current_review(id, hash) do
      {:ok, _claim} ->
        send_update(HarnessForgeWeb.CompanyPanel,
          id: "company-builder",
          analysis_open: %{"id" => id, "revision_hash" => hash}
        )

        {:noreply, change_tab(socket, "company")}

      _ ->
        finish(socket, {:error, :stale_revision}, "")
    end
  end

  def handle_event(
        "decide",
        %{"id" => id, "decision" => decision, "revision" => revision},
        socket
      ) do
    result =
      Decisions.decide(id, %{
        "actor" => Workspaces.operator(),
        "decision" => decision,
        "expected_revision_hash" => revision
      })

    {:noreply, socket} =
      finish(socket, result, "Decision recorded for this exact claim revision.")

    socket =
      if match?({:ok, _}, result),
        do: push_event(socket, "company-focus", %{id: "evidence-panel"}),
        else: socket

    {:noreply, socket}
  end

  def handle_event("setup_goal_edit", %{"goal" => attrs}, socket) when is_map(attrs) do
    if socket.assigns.setup_creation_request &&
         socket.assigns.setup_creation_request["section"] == "goal",
       do: {:noreply, assign(socket, :setup_goal_dirty, true)},
       else: {:noreply, socket}
  end

  def handle_event("goal", %{"goal" => attrs}, socket) do
    result = Goals.add_goal(attrs)

    socket =
      if match?({:ok, _}, result), do: assign(socket, :setup_goal_dirty, false), else: socket

    finish(socket, result, "Goal saved with its owner and acceptance criteria.")
  end

  def handle_event("build", params, socket) do
    if socket.assigns.tab == "package" do
      params = build_transport(params, socket.assigns.build_generation)

      case PackageBuild.input(params, socket.assigns.build_generation) do
        {:ok, draft} -> build_package(socket, draft)
        :invalid -> {:noreply, socket |> reset_build() |> build_refusal(:generic)}
        :stale -> {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("export", attrs, socket) do
    case export_input(attrs, socket) do
      {:ok, digest, target} ->
        outcome =
          HarnessForge.Harnesses.export(digest, target)
          |> PackageExport.present(digest, target)

        socket = reset_export(socket)
        kind = if outcome.status == :success, do: "result", else: "target"

        outcome =
          Map.merge(outcome, %{
            digest: digest,
            generation: socket.assigns.export_generation,
            target: if(outcome.status == :success, do: "", else: target)
          })

        socket = assign(socket, :export_outcome, outcome)
        socket = if outcome.status == :success, do: reload(socket), else: socket

        {:noreply,
         socket
         |> push_event("package-export-focus", %{
           kind: kind,
           digest: digest,
           generation: socket.assigns.export_generation
         })}

      :invalid ->
        {:noreply,
         assign(
           socket,
           :export_message,
           "This export form is no longer current. Use the refreshed Packages controls."
         )}
    end
  end

  def handle_event("backup", %{"privacy" => %{"target" => target}}, socket) do
    privacy_result(socket, :backup, HarnessForge.Privacy.backup(target))
  end

  def handle_event("restore", %{"privacy" => %{"backup" => backup, "target" => target}}, socket) do
    socket = privacy_start(socket)
    privacy_result(socket, :restore, HarnessForge.Privacy.restore(backup, target))
  end

  def handle_event(
        "purge_source",
        %{"privacy" => %{"id" => id, "confirmation" => confirmation}},
        socket
      ) do
    socket = privacy_start(socket)
    privacy_result(socket, :purge_source, HarnessForge.Privacy.purge_source(id, confirmation))
  end

  def handle_event("purge_workspace", %{"privacy" => %{"confirmation" => confirmation}}, socket) do
    socket = privacy_start(socket)
    privacy_result(socket, :purge_workspace, HarnessForge.Privacy.purge_workspace(confirmation))
  end

  def handle_event(_event, _params, socket),
    do:
      {:noreply, put_flash(socket, :error, "This action is unavailable. Refresh and try again.")}

  @impl true
  def handle_info(
        {:company_analysis_start,
         %{
           generation: generation,
           request_id: request_id,
           run_id: run_id,
           input: input,
           reset_token: reset_token
         }},
        socket
      ) do
    cond do
      !HarnessForgeWeb.Plugs.OperatorSession.valid?(socket.assigns.operator_auth) ->
        {:noreply, revoke_operator(socket)}

      socket.assigns.tab != "company" || socket.assigns.company_analysis_pending != nil ||
          reset_token != socket.assigns.company_reset_token ->
        {:noreply, socket}

      true ->
        token = %{
          generation: generation,
          request_id: request_id,
          run_id: run_id,
          input_digest: HarnessForge.Contracts.digest(input),
          reset_token: reset_token
        }

        auth = socket.assigns.operator_auth
        name = {:company_analysis, {generation, request_id, token.input_digest}}

        {:noreply,
         socket
         |> assign(:company_analysis_pending, token)
         |> start_async(name, fn ->
           if HarnessForgeWeb.Plugs.OperatorSession.valid?(auth),
             do:
               HarnessForge.Company.Analysis.analyze(input,
                 run_id: run_id,
                 request_id: request_id
               ),
             else: {:error, :operator_session_revoked}
         end)}
    end
  end

  def handle_info({:company_changed, _summary}, socket), do: {:noreply, reload(socket)}

  def handle_info(:company_inspect_setup, socket) do
    cond do
      not setup_authorized?(socket) ->
        {:noreply, revoke_operator(socket)}

      socket.assigns.assessment_state["dirty"] ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Record or discard your assessment draft before opening saved setup."
         )}

      true ->
        {:noreply, redirect(socket, to: "/setup")}
    end
  end

  def handle_info({:company_inspect_setup, id}, socket) do
    cond do
      not setup_authorized?(socket) ->
        {:noreply, revoke_operator(socket)}

      socket.assigns.assessment_state["dirty"] ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Record or discard your assessment draft before opening saved setup."
         )}

      true ->
        case SetupSessions.get(%{"id" => id}, setup_caller(socket)) do
          {:ok, %{"id" => saved_id, "step" => step}}
          when is_binary(saved_id) and
                 step in ~w(outcome scope understanding review candidate evaluation release) ->
            {:noreply, redirect(socket, to: "/setup/" <> saved_id <> "/" <> step)}

          {:error, %{"code" => "unauthorized"}} ->
            {:noreply, revoke_operator(socket)}

          {:error, %{"code" => code}} ->
            {:noreply, put_flash(socket, :error, setup_navigation_error(code))}

          _ ->
            {:noreply, put_flash(socket, :error, setup_navigation_error("unavailable"))}
        end
    end
  end

  def handle_info(:company_inspect_corpus, socket) do
    if socket.assigns.assessment_state["dirty"] do
      {:noreply,
       put_flash(
         socket,
         :error,
         "Record or discard your assessment draft before opening corpus evidence review."
       )}
    else
      {:noreply, redirect(socket, to: "/company/corpus")}
    end
  end

  def handle_info({:company_navigate, "evidence", %{"id" => id, "revision_hash" => hash}}, socket) do
    if HarnessForgeWeb.Plugs.OperatorSession.valid?(socket.assigns.operator_auth) do
      socket = bind_evidence_review(socket, id, hash)
      handle_info({:company_navigate, "evidence"}, socket)
    else
      {:noreply, revoke_operator(socket)}
    end
  end

  def handle_info({:company_navigate, tab}, socket) when is_map_key(@company_destinations, tab) do
    socket = change_tab(socket, tab)

    focus =
      if socket.assigns.tab == tab,
        do: @company_destinations[tab],
        else: "company-assessment-departure"

    {:noreply, push_event(socket, "company-focus", %{id: focus})}
  end

  def handle_info(:company_cache_reset, socket) do
    if HarnessForgeWeb.Plugs.OperatorSession.valid?(socket.assigns.operator_auth) do
      {:noreply, socket |> reset_company_cache() |> reload()}
    else
      {:noreply, revoke_operator(socket)}
    end
  end

  def handle_info(:corpus_cache_reset, socket) do
    {:noreply, clear_sensitive_previews(socket)}
  end

  def handle_info({:operation_finished, summary}, socket),
    do: {:noreply, socket |> put_flash(:info, summary) |> reload()}

  def handle_info({:command_approval_requested, run_id}, socket) do
    if OperatorSession.valid?(socket.assigns.operator_auth) do
      socket = assign(socket, :command_approval_notice, run_id)
      {:noreply, refresh_command_requests(socket)}
    else
      {:noreply, revoke_operator(socket)}
    end
  end

  def handle_info(:refresh_evaluations, socket) do
    Process.send_after(self(), :refresh_evaluations, 2_000)

    case {socket.assigns.tab,
          HarnessForgeWeb.Plugs.OperatorSession.valid?(socket.assigns.operator_auth)} do
      {_, false} ->
        {:noreply, revoke_operator(socket)}

      {tab, true} when tab in ["evaluations", "package"] ->
        case load_records(HarnessForge.Evaluations, :list_runs) do
          {:ok, runs} ->
            socket =
              if runs == socket.assigns.runs,
                do: socket,
                else: invalidate_readiness(socket)

            {:noreply,
             socket |> assign(:runs, runs) |> refresh_command_requests() |> refresh_chat()}

          _ ->
            {:noreply,
             socket
             |> invalidate_readiness()
             |> assign(:runs, [])
             |> reset_command_review()
             |> refresh_chat()}
        end

      _ ->
        {:noreply, refresh_chat(socket)}
    end
  end

  def handle_info(:operator_session_revoked, socket),
    do: {:noreply, revoke_operator(socket)}

  @impl true
  def handle_async({:company_analysis, {generation, request_id, digest}}, result, socket) do
    token = socket.assigns.company_analysis_pending

    cond do
      !HarnessForgeWeb.Plugs.OperatorSession.valid?(socket.assigns.operator_auth) ->
        {:noreply, revoke_operator(socket)}

      socket.assigns.tab != "company" || is_nil(token) ||
        token.generation != generation || token.request_id != request_id ||
        token.input_digest != digest || token.reset_token != socket.assigns.company_reset_token ->
        {:noreply, socket}

      true ->
        outcome =
          case result do
            {:ok, value} -> value
            _ -> {:error, :service_unavailable}
          end

        send_update(HarnessForgeWeb.CompanyPanel,
          id: "company-builder",
          analysis_result: %{token: token, result: outcome}
        )

        {:noreply, socket |> assign(:company_analysis_pending, nil) |> reload()}
    end
  end

  def handle_async({:chat, token}, result, socket) do
    cond do
      not HarnessForgeWeb.Plugs.OperatorSession.valid?(socket.assigns.operator_auth) ->
        {:noreply, revoke_operator(socket)}

      is_nil(socket.assigns.chat_pending) or socket.assigns.chat_pending.token != token ->
        {:noreply, socket}

      true ->
        {:noreply, finish_chat(socket, result)}
    end
  end

  def handle_async({:account_connect, token}, result, socket) do
    cond do
      not HarnessForgeWeb.Plugs.OperatorSession.valid?(socket.assigns.operator_auth) ->
        {:noreply, revoke_operator(socket)}

      token != socket.assigns.account_pending ->
        {:noreply, socket}

      true ->
        result =
          case result do
            {:ok, outcome} -> outcome
            _ -> {:error, :service_unavailable}
          end

        finish(
          assign(socket, :account_pending, nil),
          result,
          "Live account verified through its API and connected. No source content was imported."
        )
    end
  end

  defp start_chat(socket, question, mode) do
    token = {socket.assigns.chat_generation, Ecto.UUID.generate()}
    auth = socket.assigns.operator_auth

    opts = [
      mode:
        case mode do
          "model" -> :model
          "assistant" -> :assistant
          _ -> :evidence
        end,
      history: socket.assigns.chat_turns |> Enum.map(& &1.question) |> Enum.take(-4),
      run_id: socket.assigns.chat_run_id,
      request_id: Ecto.UUID.generate()
    ]

    socket =
      socket
      |> clear_flash()
      |> assign(:chat_error, nil)
      |> assign(:chat_requires_live, false)
      |> assign(:chat_mode, mode)
      |> assign(:chat_pending, %{token: token, question: question})
      |> push_event("chat-clear-composer", %{})
      |> start_async({:chat, token}, fn ->
        if HarnessForgeWeb.Plugs.OperatorSession.valid?(auth),
          do: HarnessForge.Chat.ask(question, opts),
          else: {:error, :chat_session_expired}
      end)

    {:noreply, socket}
  end

  defp finish_chat(socket, {:ok, {:ok, reply}}) do
    if HarnessForge.Chat.valid?(reply) do
      turn = %{
        id: Ecto.UUID.generate(),
        question: socket.assigns.chat_pending.question,
        reply: reply
      }

      socket
      |> assign(:chat_turns, Enum.take(socket.assigns.chat_turns ++ [turn], -10))
      |> assign(:chat_pending, nil)
      |> assign(:chat_error, nil)
    else
      reset_chat(socket)
      |> assign(
        :chat_error,
        "Evidence or permissions changed. Ask again using the current sources."
      )
    end
  end

  defp finish_chat(socket, {:ok, {:error, reason}}) do
    question = socket.assigns.chat_pending.question

    socket
    |> assign(:chat_pending, nil)
    |> assign(:chat_error, chat_error(reason))
    |> assign(:chat_requires_live, reason == :live_request_requires_assistant)
    |> push_event("chat-restore-composer", %{question: question})
  end

  defp finish_chat(socket, _),
    do:
      socket
      |> assign(:chat_pending, nil)
      |> assign(:chat_error, "The answer could not be completed. No automatic retry was made.")

  defp reset_chat(socket) do
    socket =
      if socket.assigns.chat_pending,
        do: cancel_async(socket, {:chat, socket.assigns.chat_pending.token}),
        else: socket

    socket
    |> assign(:chat_turns, [])
    |> assign(:chat_pending, nil)
    |> assign(:chat_error, nil)
    |> assign(:chat_requires_live, false)
    |> assign(:chat_generation, Ecto.UUID.generate())
  end

  defp refresh_chat(socket) do
    if HarnessForge.Chat.valid_many?(Enum.map(socket.assigns.chat_turns, & &1.reply)) do
      socket
    else
      socket
      |> reset_chat()
      |> assign(
        :chat_error,
        "Evidence or permissions changed. The previous conversation was cleared."
      )
    end
  end

  defp chat_error(reason)
       when reason in [
              :cloud_consent_required,
              :chat_consent_required,
              :chat_context_consent_required
            ],
       do:
         "Enable source and chat-context consent for this model in Connections before asking AI."

  defp chat_error(reason)
       when reason in [
              :model_not_selected,
              :local_model_unavailable,
              :model_unavailable,
              :model_service_unavailable
            ],
       do: "Configure an available model in Connections, or choose local evidence search."

  defp chat_error(reason)
       when reason in [:invalid_chat_response, :invalid_chat_output, :invalid_citation],
       do:
         "The model returned an answer without valid supporting citations. It was not displayed."

  defp chat_error(reason)
       when reason in [:budget_exhausted, :request_already_dispatched, :request_in_progress],
       do: "This conversation reached a usage or request limit. No automatic retry was made."

  defp chat_error(:stale_chat_context),
    do: "Evidence or permissions changed while answering. Ask again using the current sources."

  defp chat_error(:chat_context_too_large),
    do:
      "The question and recent context are too large. Clear the conversation or shorten the question."

  defp chat_error(:request_outcome_unknown),
    do: "A previous request has an uncertain outcome. It was not retried automatically."

  defp chat_error(:github_account_not_connected),
    do:
      "Connect your GitHub account in Connections → Live accounts. Repository listings use live API access, not imported source search."

  defp chat_error(:service_account_not_connected),
    do: "Connect this service in Connections → Live accounts before requesting live data."

  defp chat_error(:live_request_requires_assistant),
    do:
      "This question needs live account access. Choose Live connector assistant, then send it again."

  defp chat_error(:unsupported_repository_ordering),
    do:
      "Repository listings currently show the most recently updated owned repositories. Ask for your latest repositories."

  defp chat_error(:live_query_limit_exceeded),
    do: "Ask for between 1 and 20 live results per message."

  defp chat_error(:unsupported_live_operation),
    do:
      "Live assistant supports repository, board, channel, project and space listings. Use evidence search or AI mode for questions about captured content."

  defp chat_error(reason) when reason in [:invalid_question, :invalid_chat_options],
    do: "Enter a valid question of at most 4,000 UTF-8 bytes and choose an answer mode."

  defp chat_error(reason), do: error_message(reason)

  defp enqueue(action, id, extra \\ %{}) do
    if action in ["sync", "propose", "evaluate"] do
      args =
        Map.merge(
          %{"action" => action, "id" => id, "workspace_id" => Workspaces.current_id()},
          extra
        )

      args |> HarnessForge.Jobs.Operation.new() |> Oban.insert()
    else
      {:error, :invalid_operation}
    end
  end

  defp finish(socket, {:ok, _}, message),
    do: {:noreply, socket |> clear_flash() |> put_flash(:info, message) |> reload()}

  defp finish(socket, {:error, reason}, _),
    do:
      {:noreply, socket |> clear_flash() |> put_flash(:error, error_message(reason)) |> reload()}

  defp finish(socket, _, _),
    do: {:noreply, put_flash(socket, :error, "The operation could not be completed.")}

  defp privacy_result(socket, operation, {:ok, result}) do
    socket =
      if operation in [:restore, :purge_source, :purge_workspace] do
        Phoenix.PubSub.broadcast_from(
          HarnessForge.PubSub,
          self(),
          "workspace:" <> socket.assigns.workspace_id,
          :company_cache_reset
        )

        reset_company_cache(socket)
      else
        socket
      end

    {:noreply,
     socket
     |> reset_chat()
     |> clear_flash()
     |> assign(:privacy_result, result)
     |> put_flash(:info, "Privacy operation completed. Review its scope and limitations below.")
     |> reload()}
  end

  defp privacy_result(socket, operation, error) do
    if operation in [:restore, :purge_source, :purge_workspace] and
         HarnessForge.Privacy.ready() != :ok do
      Phoenix.PubSub.broadcast_from(
        HarnessForge.PubSub,
        self(),
        "workspace:" <> socket.assigns.workspace_id,
        :company_cache_reset
      )
    end

    finish(socket, error, "")
  end

  defp privacy_start(socket) do
    Phoenix.PubSub.broadcast_from(
      HarnessForge.PubSub,
      self(),
      "workspace:" <> socket.assigns.workspace_id,
      :corpus_cache_reset
    )

    clear_sensitive_previews(socket)
  end

  defp clear_sensitive_previews(socket) do
    socket
    |> reset_command_review()
    |> assign(:command_approval_notice, nil)
    |> reset_chat()
    |> assign(
      source_passage: nil,
      source_passage_token: nil,
      claims: [],
      approved: [],
      requested_company_review: nil,
      setup_creation_request: nil,
      setup_goal_dirty: false,
      evidence_review: nil
    )
    |> assign(:company_sensitive_reset_token, socket.assigns.company_sensitive_reset_token + 1)
  end

  defp reset_company_cache(socket) do
    socket
    |> reset_command_review()
    |> assign(:command_approval_notice, nil)
    |> reset_goal_claim()
    |> reset_readiness()
    |> reset_build()
    |> reset_export()
    |> assign(
      source_passage: nil,
      source_passage_token: nil,
      evidence_review: nil,
      source_cursor_stack: [nil],
      model_source_ids: nil,
      model_selected_sources: []
    )
    |> assign(:source_view_generation, Base.encode16(:crypto.strong_rand_bytes(16), case: :lower))
    |> assign(:company_analysis_pending, nil)
    |> assign(:requested_company_review, nil)
    |> assign(:setup_creation_request, nil)
    |> assign(:setup_goal_dirty, false)
    |> reset_assessment()
    |> assign(:company_reset_token, socket.assigns.company_reset_token + 1)
  end

  defp revoke_operator(socket) do
    socket
    |> reset_chat()
    |> reset_company_cache()
    |> assign(sources: [], approved: [], claims: [], goals: [], artifacts: [])
    |> redirect(to: "/login")
  end

  defp reload(socket) do
    case HarnessForge.Privacy.ready() do
      :ok ->
        reload_ready(socket)

      _ ->
        error = Phoenix.Flash.get(socket.assigns.flash, :error)
        socket = reset_company_cache(socket)
        socket = if error, do: put_flash(socket, :error, error), else: socket

        socket
        |> assign(
          connections: [],
          sources: [],
          claims: [],
          approved: [],
          goals: [],
          artifacts: [],
          audit: [],
          runs: [],
          releases: [],
          assessment_rubrics: [],
          goal_claim_reviews: %{},
          data_errors: ["privacy"],
          claim_review_count: nil,
          chat_catalog: %{},
          source_total: nil,
          source_page: %{"rows" => [], "next_cursor" => nil},
          model_status: %{
            "availability" => "unavailable",
            "reason" => "privacy_operation_incomplete"
          }
        )
        |> assign_new(:model_provider, fn -> "ollama" end)
    end
  end

  defp reload_ready(socket) do
    loaders = [
      {:connections, Evidence, :list_connections},
      {:claims, Evidence, :list_claims},
      {:approved, Evidence, :approved_claims},
      {:goals, Goals, :list_goals},
      {:artifacts, HarnessForge.Harnesses, :list_artifacts},
      {:audit, Audit, :list_events},
      {:runs, HarnessForge.Evaluations, :list_runs},
      {:releases, HarnessForge.Releases, :list},
      {:assessment_rubrics, HarnessForge.Company.Assessments, :list_rubrics}
    ]

    {data, errors} =
      Enum.reduce(loaders, {%{}, []}, fn {key, module, function}, {data, errors} ->
        case load_records(module, function) do
          {:ok, values} when is_list(values) ->
            values =
              if key == :connections,
                do: Enum.reject(values, &(&1["provider"] == "service_account")),
                else: values

            {Map.put(data, key, values), errors}

          _ ->
            {Map.put(data, key, []), [Atom.to_string(key) | errors]}
        end
      end)

    status =
      if Code.ensure_loaded?(HarnessForge.Models),
        do: HarnessForge.Models.status(),
        else: %{"availability" => "unavailable"}

    socket
    |> refresh_assessment()
    |> invalidate_readiness()
    |> assign(data)
    |> retain_export()
    |> assign(:model_status, status)
    |> assign_new(:model_provider, fn -> status["provider"] || "ollama" end)
    |> then(fn socket ->
      if socket.assigns.model_source_ids == nil,
        do:
          assign(socket, :model_source_ids, get_in(status, ["cloud_consent", "source_ids"]) || []),
        else: socket
    end)
    |> assign(:data_errors, Enum.reverse(errors))
    |> assign(:claim_review_count, if("claims" in errors, do: nil, else: proposed(data.claims)))
    |> assign(:goal_claim_reviews, goal_claim_reviews(data.claims, data.goals))
    |> assign(:company_refresh_token, socket.assigns.company_refresh_token + 1)
    |> load_source_page(hd(socket.assigns.source_cursor_stack))
    |> assign(:chat_catalog, chat_catalog())
    |> refresh_command_requests()
    |> refresh_chat()
  end

  defp reset_command_review(socket),
    do: assign(socket, command_review_run: nil, command_requests: [], command_review_message: nil)

  defp setup_authorized?(socket),
    do:
      OperatorSession.valid?(socket.assigns.operator_auth) and
        socket.assigns.workspace_id == Workspaces.current_id()

  defp setup_caller(socket) do
    auth = socket.assigns.operator_auth
    workspace = socket.assigns.workspace_id

    [
      authorize: fn -> OperatorSession.valid?(auth) and workspace == Workspaces.current_id() end,
      session_fingerprint: HarnessForge.Contracts.digest(auth),
      view_generation: socket.assigns.assessment_event_generation,
      reset_token: socket.assigns.company_reset_token
    ]
  end

  defp setup_navigation_error("invalid_input"),
    do: "This saved setup address is invalid. Choose a saved setup from the current workspace."

  defp setup_navigation_error("not_found"),
    do: "This saved setup is unavailable for the current workspace and operator."

  defp setup_navigation_error(_),
    do: "Saved setup could not be confirmed. Refresh saved setup before continuing."

  defp command_caller(socket) do
    auth = socket.assigns.operator_auth
    workspace = socket.assigns.workspace_id

    [authorize: fn -> OperatorSession.valid?(auth) and workspace == Workspaces.current_id() end]
  end

  defp load_command_requests(socket, run_id) do
    socket =
      assign(socket, command_requests: [], command_review_run: nil, command_review_message: nil)

    with true <- OperatorSession.valid?(socket.assigns.operator_auth),
         true <-
           Enum.any?(socket.assigns.runs, &(&1["id"] == run_id and &1["outcome"] == "running")),
         {:ok, rows} <-
           HarnessForge.Execution.CommandApprovals.list(run_id, command_caller(socket)),
         true <- OperatorSession.valid?(socket.assigns.operator_auth) do
      assign(socket,
        command_review_run: run_id,
        command_requests: rows,
        command_approval_notice: nil
      )
    else
      _ ->
        assign(
          socket,
          :command_review_message,
          "This command review is unavailable. Refresh the evaluation and current harness inputs."
        )
    end
  end

  defp refresh_command_requests(socket) do
    if socket.assigns[:command_review_run] && socket.assigns.tab == "evaluations",
      do: load_command_requests(socket, socket.assigns.command_review_run),
      else: socket
  end

  defp source_caller(socket) do
    auth = socket.assigns.operator_auth

    [
      authorize: fn -> HarnessForgeWeb.Plugs.OperatorSession.valid?(auth) end,
      session_fingerprint: HarnessForge.Contracts.digest(auth),
      view_generation: socket.assigns.source_view_generation,
      reset_token: socket.assigns.company_reset_token
    ]
  end

  defp consent_source_options(page, selected, ids) do
    available = Map.new(page ++ selected, &{&1["id"], &1})

    Enum.uniq(Enum.map(page, & &1["id"]) ++ ids)
    |> Enum.map(fn id ->
      available[id] ||
        %{"id" => id, "title" => "Unavailable saved selection · " <> id, "eligible" => false}
    end)
  end

  defp source_pagination(assigns) do
    ~H"""
    <nav id={@id} aria-label="Captured source metadata pages" class="action-row">
      <button
        type="button"
        phx-click="source_page_previous"
        disabled={length(@stack) < 2}
        class="button secondary"
      >Previous sources</button>
      <button
        type="button"
        phx-click="source_page_next"
        disabled={is_nil(@page["next_cursor"])}
        class="button secondary"
      >Next sources</button>
      <span>Page {length(@stack)} · up to 25 sources per page</span>
    </nav>
    """
  end

  defp load_source_page(socket, cursor) do
    socket = refresh_evidence_review(socket)
    attrs = %{"query" => socket.assigns.query, "cursor" => cursor}

    case CorpusReview.source_page(attrs, source_caller(socket)) do
      {:ok, page} ->
        selected =
          case CorpusReview.summary_refs(
                 %{"consent_ids" => socket.assigns.model_source_ids || []},
                 source_caller(socket)
               ) do
            {:ok, %{"sources" => values}} -> values
            _ -> []
          end

        socket
        |> assign(
          sources: page["rows"],
          source_page: page,
          source_total: page["counts"]["captured"],
          search_results: if(socket.assigns.query == "", do: nil, else: page["rows"]),
          source_passage: nil,
          source_passage_token: nil,
          model_selected_sources: selected
        )

      {:error, _} ->
        socket
        |> assign(
          sources: [],
          source_page: %{"rows" => [], "next_cursor" => nil},
          source_total: nil,
          source_passage: nil,
          source_passage_token: nil,
          model_selected_sources: []
        )
        |> put_flash(
          :error,
          "Captured evidence is unavailable or changed. Clear the query and refresh current records."
        )
    end
  end

  defp read_source_passage(socket, token, attrs) do
    case CorpusReview.passage(token, attrs, source_caller(socket)) do
      {:ok, passage} ->
        socket
        |> assign(source_passage: passage, source_passage_token: token)
        |> push_event("company-focus", %{id: "source-opened-passage"})

      {:error, _} ->
        socket
        |> assign(source_passage: nil, source_passage_token: nil)
        |> put_flash(
          :error,
          "This source changed or is unavailable. Its preview was cleared; search or refresh to select a current revision."
        )
    end
  end

  defp capture_model_sources(socket, attrs) do
    cond do
      Map.has_key?(attrs, "source_generation") and
          attrs["source_generation"] != socket.assigns.source_view_generation ->
        assign(socket, :model_source_error, true)

      not Map.has_key?(attrs, "source_ids") ->
        socket

      true ->
        submitted = attrs["source_ids"] || []

        allowed =
          MapSet.new(
            Enum.map(socket.assigns.sources, & &1["id"]) ++
              (socket.assigns.model_source_ids || [])
          )

        if is_list(submitted) and length(submitted) <= 101 and
             Enum.all?(submitted, &(is_binary(&1) and (&1 == "" or MapSet.member?(allowed, &1)))) do
          assign(socket,
            model_source_ids: submitted |> Enum.reject(&(&1 == "")) |> Enum.uniq(),
            model_source_error: false
          )
        else
          assign(socket, :model_source_error, true)
        end
    end
  end

  defp current_review(id, hash) do
    with :ok <- HarnessForge.Privacy.ready(),
         {:ok, %{"revision_hash" => ^hash, "basis" => %{"kind" => "company_analysis"}} = claim} <-
           Evidence.get_claim(id),
         false <- claim["superseded"],
         {:ok, _} <- Analysis.validate_origin(claim["basis"], claim["citations"]) do
      {:ok, claim}
    else
      _ -> {:error, :stale_revision}
    end
  end

  defp bind_evidence_review(socket, id, hash) do
    with true <- HarnessForgeWeb.Plugs.OperatorSession.valid?(socket.assigns.operator_auth),
         {:ok, claim} <- current_review(id, hash),
         {:ok, %{"sources" => sources, "source_refs" => refs}} <-
           CorpusReview.recommendation_sources(
             %{"claim_id" => claim["id"], "revision_hash" => claim["revision_hash"]},
             source_caller(socket)
           ) do
      assign(socket, :evidence_review, %{
        "id" => id,
        "revision_hash" => hash,
        "sources" => sources,
        "source_refs" => refs
      })
    else
      _ -> assign(socket, :evidence_review, nil)
    end
  end

  defp refresh_evidence_review(socket) do
    case socket.assigns.evidence_review do
      %{"id" => id, "revision_hash" => hash} -> bind_evidence_review(socket, id, hash)
      _ -> socket
    end
  end

  defp evidence_report_sources(
         %{"id" => id, "revision_hash" => hash},
         %{"id" => id, "revision_hash" => hash, "sources" => sources},
         _fallback
       ),
       do: sources

  defp evidence_report_sources(_claim, _review, fallback), do: fallback

  defp evidence_report_refs(
         %{"id" => id, "revision_hash" => hash},
         %{"id" => id, "revision_hash" => hash, "source_refs" => refs}
       ),
       do: refs

  defp evidence_report_refs(_, _), do: nil

  # Keep the inherited session predicate while clearing cached observations before
  # its halt/redirect. This hook runs before every parent LiveView event.
  defp authenticate_portal_event(_event, _attrs, socket) do
    if HarnessForgeWeb.Plugs.OperatorSession.valid?(socket.assigns.operator_auth),
      do: {:cont, socket},
      else: {:halt, revoke_operator(socket)}
  end

  defp change_tab(socket, tab) do
    if socket.assigns.tab == "company" and tab != "company" and
         socket.assigns.assessment_state["dirty"] do
      state = CompanyAssessmentState.pending(socket.assigns.assessment_state, %{"tab" => tab})

      socket
      |> assign(:assessment_state, state)
      |> push_event("company-focus", %{id: "company-assessment-departure"})
    else
      change_tab_now(socket, tab)
    end
  end

  defp change_tab_now(socket, tab) do
    socket =
      if socket.assigns.tab == "company" && tab != "company",
        do:
          socket
          |> reset_assessment()
          |> assign(
            company_analysis_pending: nil,
            company_reset_token: socket.assigns.company_reset_token + 1
          ),
        else: socket

    socket =
      if socket.assigns.tab == "package" and tab != "package",
        do: socket |> reset_build() |> reset_export(),
        else: socket

    socket = if tab != "evaluations", do: reset_command_review(socket), else: socket
    assign(socket, :tab, tab)
  end

  defp reset_assessment(socket) do
    assign(socket,
      assessment_state: CompanyAssessmentState.empty(),
      assessment_event_generation: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    )
  end

  defp refresh_assessment(socket) do
    case CompanyAssessmentState.refresh(socket.assigns.assessment_state) do
      {:ok, state} ->
        assign(socket, :assessment_state, state)

      {:reset, _reason} ->
        socket
        |> reset_assessment()
        |> assign(:company_reset_token, socket.assigns.company_reset_token + 1)
    end
  end

  defp assessment_options(socket) do
    auth = socket.assigns.operator_auth

    [
      authorize: fn -> HarnessForgeWeb.Plugs.OperatorSession.valid?(auth) end,
      session_fingerprint: HarnessForge.Contracts.digest(auth),
      view_generation: socket.assigns.assessment_event_generation,
      reset_token: socket.assigns.company_reset_token
    ]
  end

  defp assessment_event(socket, "assessment_departure_resolve", %{"action" => action} = attrs)
       when map_size(attrs) == 1 do
    state = socket.assigns.assessment_state
    destination = state["pending_destination"]

    cond do
      is_nil(destination) ->
        socket

      action == "keep" ->
        socket
        |> assign(:assessment_state, CompanyAssessmentState.clear_pending(state))
        |> push_event("company-focus", %{id: state["departure_origin"]})

      action == "discard" ->
        assessment_destination(socket, destination)

      action in ~w(freeze record_not_accepted) ->
        {next, focus} =
          CompanyAssessmentState.save_before_departure(state, action, assessment_options(socket))

        socket = assign(socket, :assessment_state, next)

        if is_nil(next["error"]),
          do: socket |> reload() |> assessment_destination(destination),
          else: push_event(socket, "company-focus", %{id: focus})

      true ->
        socket
    end
  end

  defp assessment_event(socket, event, attrs) do
    state = socket.assigns.assessment_state

    if state["dirty"] and CompanyAssessmentState.replacing?(event, attrs) do
      next = CompanyAssessmentState.pending(state, %{"event" => event, "attrs" => attrs})

      socket
      |> assign(:assessment_state, next)
      |> push_event("company-focus", %{id: "company-assessment-departure"})
    else
      {next, focus} =
        CompanyAssessmentState.dispatch(event, attrs, state, assessment_options(socket))

      socket = assign(socket, :assessment_state, next)

      socket =
        if event in ~w(assessment_rubric_freeze assessment_record),
          do: reload(socket),
          else: socket

      if focus, do: push_event(socket, "company-focus", %{id: focus}), else: socket
    end
  end

  defp assessment_destination(socket, %{"tab" => tab}) when tab in @tabs,
    do: socket |> reset_assessment() |> change_tab_now(tab)

  defp assessment_destination(socket, %{"event" => event, "attrs" => attrs}),
    do: socket |> reset_assessment() |> assessment_event(event, attrs)

  defp reset_build(socket) do
    outcome = Map.get(socket.assigns, :build_outcome)

    socket =
      if outcome &&
           Phoenix.Flash.get(socket.assigns.flash, :error) ==
             "Package build: " <> build_message(outcome),
         do: clear_flash(socket, :error),
         else: socket

    assign(socket,
      build_draft: PackageBuild.defaults(),
      build_generation: Ecto.UUID.generate(),
      build_outcome: nil
    )
  end

  # Phoenix marks untouched visible inputs; hidden generation is never marked.
  # Strip only the serializer's empty marker beside an actual visible field.
  defp build_transport(
         %{"package" => %{"generation" => generation} = attrs} = params,
         current_generation
       )
       when is_binary(generation) and generation == current_generation and not is_struct(attrs) do
    attrs =
      Enum.reduce(~w(name version runtime runtime_version), attrs, fn field, acc ->
        marker = "_unused_" <> field

        if Map.has_key?(acc, field) and Map.get(acc, marker) == "",
          do: Map.delete(acc, marker),
          else: acc
      end)

    Map.put(params, "package", attrs)
  end

  defp build_transport(params, _current_generation), do: params

  defp build_package(socket, draft) do
    socket =
      assign(socket,
        build_draft: draft,
        build_generation: Ecto.UUID.generate(),
        build_outcome: nil
      )

    case invoke(HarnessForge.Harnesses, :build, [draft]) do
      {:ok, _} = result ->
        finish(
          socket,
          result,
          "Package build: Immutable harness package built from approved evidence."
        )

      {:error, reason} ->
        {:noreply, build_refusal(socket, PackageBuild.classify(reason))}

      _ ->
        {:noreply, build_refusal(socket, :generic)}
    end
  end

  defp build_refusal(socket, outcome) do
    socket =
      socket
      |> assign(:build_outcome, outcome)
      |> clear_flash()
      |> put_flash(:error, "Package build: " <> build_message(outcome))
      |> reload()

    if outcome == :name,
      do:
        push_event(socket, "package-build-focus", %{
          kind: "name",
          generation: socket.assigns.build_generation
        }),
      else: socket
  end

  defp build_message({:known, reason}), do: error_message(reason)
  defp build_message(outcome), do: PackageBuild.message(outcome)

  defp reset_export(socket) do
    assign(socket,
      export_generation: Ecto.UUID.generate(),
      export_outcome: nil,
      export_message: nil
    )
  end

  defp retain_export(socket) do
    case socket.assigns.export_outcome do
      %{digest: digest} ->
        if Enum.any?(socket.assigns.artifacts, &(&1["digest"] == digest)),
          do: socket,
          else: reset_export(socket)

      nil ->
        socket
    end
  end

  defp export_input(%{"export" => attrs}, socket) when is_map(attrs) do
    digest = attrs["digest"]
    target = attrs["target"]
    generation = attrs["generation"]

    if socket.assigns.tab == "package" and
         Enum.sort(Map.keys(attrs)) == ~w(digest generation target) and
         is_binary(generation) and generation == socket.assigns.export_generation and
         PackageExport.valid_digest?(digest) and PackageExport.valid_target?(target) and
         Enum.any?(socket.assigns.artifacts, &(&1["digest"] == digest)),
       do: {:ok, digest, target},
       else: :invalid
  end

  defp export_input(_, _), do: :invalid

  defp export_outcome(%{digest: digest, generation: generation} = outcome, digest, generation),
    do: outcome

  defp export_outcome(_, _, _), do: nil

  defp export_id(kind, generation, digest),
    do: "package-export-#{kind}-#{generation}-#{digest}"

  defp reset_goal_claim(socket) do
    assign(socket,
      goal_claim_draft: %{"goal_snapshot" => "", "text" => ""},
      goal_claim_generation: Ecto.UUID.generate(),
      goal_claim_reviews: %{}
    )
  end

  defp goal_claim_input(
         %{"goal_claim_generation" => generation, "goal_claim" => draft},
         socket
       )
       when is_map(draft) do
    cond do
      generation != socket.assigns.goal_claim_generation ->
        {:error, :stale_goal_form}

      not is_binary(draft["goal_snapshot"]) or not is_binary(draft["text"]) or
        byte_size(draft["goal_snapshot"]) > 101 or byte_size(draft["text"]) > 10_000 ->
        {:error, :invalid_input}

      true ->
        {:ok, Map.take(draft, ~w(goal_snapshot text))}
    end
  end

  defp goal_claim_input(_, _), do: {:error, :stale_goal_form}

  defp goal_claim_reviews(claims, goals) do
    Map.new(claims, fn claim ->
      goal =
        with %{"kind" => "goal"} = basis <- claim["basis"],
             {:ok, _} <- Evidence.validate_claim(claim),
             goal when is_map(goal) <- Enum.find(goals, &(&1["id"] == basis["goal_id"])),
             true <- Goals.content_hash(goal) == basis["goal_content_hash"] do
          goal
        else
          _ -> nil
        end

      {claim["id"], goal}
    end)
  end

  # The general reload also reads model availability. Inspection refreshes only
  # persisted runs; Readiness verifies the selected artifact itself.
  defp refresh_readiness_records(socket) do
    runs =
      case load_records(HarnessForge.Evaluations, :list_runs) do
        {:ok, records} when is_list(records) -> records
        _ -> []
      end

    socket
    |> invalidate_readiness()
    |> assign(:runs, runs)
  end

  defp readiness_event(socket, attrs, callback) do
    cond do
      not HarnessForgeWeb.Plugs.OperatorSession.valid?(socket.assigns.operator_auth) ->
        {:noreply, revoke_operator(socket)}

      attrs["generation"] != socket.assigns.readiness_generation ->
        {:noreply, socket}

      true ->
        callback.(socket)
    end
  end

  defp select_readiness(socket, attrs) do
    {digest, evaluation_id} = submitted_readiness_pair(attrs)

    digest =
      if Enum.any?(socket.assigns.artifacts, &(&1["digest"] == digest)), do: digest, else: nil

    evaluation_id =
      if digest == socket.assigns.readiness_digest and
           Enum.any?(socket.assigns.runs, fn run ->
             run["id"] == evaluation_id and run["artifact_digest"] == digest
           end),
         do: evaluation_id,
         else: nil

    assign(socket,
      readiness_digest: digest,
      readiness_evaluation_id: evaluation_id,
      readiness_report: nil,
      readiness_generation: Ecto.UUID.generate(),
      readiness_message: "Selection changed. Inspect readiness to view current results."
    )
  end

  defp readiness_pair(socket),
    do: {socket.assigns.readiness_digest, socket.assigns.readiness_evaluation_id}

  defp submitted_readiness_pair(attrs),
    do: {readiness_reference(attrs["digest"]), readiness_reference(attrs["evaluation_id"])}

  defp readiness_reference(value) when is_binary(value) and byte_size(value) in 1..64,
    do: value

  defp readiness_reference(_), do: nil

  defp reset_readiness(socket) do
    assign(socket,
      readiness_digest: nil,
      readiness_evaluation_id: nil,
      readiness_report: nil,
      readiness_message: nil,
      readiness_generation: Ecto.UUID.generate(),
      readiness_controls_generation: Ecto.UUID.generate()
    )
  end

  defp invalidate_readiness(socket) do
    assign(socket,
      readiness_report: nil,
      readiness_generation: Ecto.UUID.generate(),
      readiness_message:
        if(socket.assigns[:readiness_report],
          do: "Workspace records changed. Refresh readiness to view current results.",
          else: socket.assigns[:readiness_message]
        )
    )
  end

  defp load_records(module, function) do
    invoke(module, function, [])
  rescue
    _ -> {:error, :storage_unavailable}
  end

  defp chat_catalog do
    case invoke(HarnessForge.Chat, :catalog, []) do
      {:ok, catalog} -> catalog
      _ -> %{"connectors" => [], "runtimes" => [], "model" => %{}, "accounts" => []}
    end
  end

  defp model_configuration(attrs) do
    provider = attrs["provider"] || "ollama"

    endpoints = %{
      "openai" => "https://api.openai.com/v1",
      "openai_responses" => "https://api.openai.com/v1",
      "anthropic" => "https://api.anthropic.com/v1"
    }

    if provider == "ollama" do
      {:ok, Map.take(attrs, ~w(model endpoint)) |> Map.put("provider", "ollama")}
    else
      with true <- Map.has_key?(endpoints, provider),
           {:ok, input_rate} <- model_rate(attrs["input_price"]),
           {:ok, output_rate} <- model_rate(attrs["output_price"]),
           sources when is_list(sources) <- attrs["source_ids"] || [],
           true <- Enum.all?(sources, &is_binary/1) do
        endpoint = endpoints[provider]

        consent =
          if attrs["cloud_consent_ack"] == "true",
            do: %{
              "provider" => provider,
              "endpoint" => endpoint,
              "source_ids" => Enum.reject(sources, &(&1 == "")),
              "data_categories" =>
                ["source_body"] ++
                  if(attrs["chat_consent_ack"] == "true", do: ["chat_context"], else: []) ++
                  if(attrs["company_context_consent_ack"] == "true",
                    do: ["company_context"],
                    else: []
                  )
            },
            else: nil

        {:ok,
         %{
           "provider" => provider,
           "endpoint" => endpoint,
           "model" => attrs["model"],
           "credential_env" => attrs["credential_env"],
           "input_microusd_per_million" => input_rate,
           "output_microusd_per_million" => output_rate,
           "cloud_consent" => consent
         }}
      else
        _ -> {:error, :invalid_model_configuration}
      end
    end
  end

  defp model_rate(value) when is_binary(value) do
    case Regex.run(~r/\A([0-9]{1,7})(?:\.([0-9]{1,6}))?\z/, value) do
      [_, whole] ->
        {:ok, String.to_integer(whole) * 1_000_000}

      [_, whole, fraction] ->
        {:ok,
         String.to_integer(whole) * 1_000_000 +
           String.to_integer(String.pad_trailing(fraction, 6, "0"))}

      _ ->
        {:error, :invalid_model_configuration}
    end
  end

  defp model_rate(_), do: {:error, :invalid_model_configuration}

  defp claim_origin_label(%{"basis" => %{"kind" => "company_analysis"}}),
    do: "Company analysis recommendation"

  defp claim_origin_label(%{"basis" => %{"kind" => "goal"}}), do: "Goal-based rule"

  defp claim_origin_label(%{"basis" => basis}) when not is_nil(basis),
    do: "Unknown claim origin · unavailable"

  defp claim_origin_label(_), do: "Sourced claim"

  defp claim_approval_blocked?(%{"basis" => %{"kind" => "company_analysis"}} = claim, _),
    do: !HarnessForge.Company.Analysis.approval_ready?(claim)

  defp claim_approval_blocked?(%{"basis" => %{"kind" => "goal"}, "id" => id}, reviews),
    do: is_nil(reviews[id])

  defp claim_approval_blocked?(%{"basis" => basis}, _) when not is_nil(basis), do: true
  defp claim_approval_blocked?(_, _), do: false

  defp invoke(module, function, args) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, length(args)),
      do: apply(module, function, args),
      else: {:error, :service_unavailable}
  end

  defp error_message(:invalid_model_configuration),
    do: "Check the model name, API key reference and price estimates."

  defp error_message(:invalid_cloud_consent),
    do: "Select at least one source and consent to sending its text to the chosen provider."

  defp error_message(:cloud_consent_required),
    do:
      "This source is not approved for this model provider. Update source consent before requesting a proposal."

  defp error_message(:cloud_cost_estimate_required),
    do: "Set positive input and output price estimates before using a cloud model."

  defp error_message(:credential_unavailable),
    do: "The referenced model API key is missing from the server environment."

  defp error_message(:model_authentication_denied),
    do: "The model API rejected authentication. Check the configured key and model access."

  defp error_message(:model_rate_limited),
    do: "The model API rate limited the request. No automatic retry was made."

  defp error_message(:service_unavailable),
    do: "This service is unavailable in the current build."

  defp error_message(:stale_revision),
    do: "The revision changed. Review the current evidence before deciding."

  defp error_message(reason)
       when reason in [:analysis_resolution_required, :stale_company_analysis_context],
       do: AnalysisUI.error_message(reason)

  defp error_message(:already_decided),
    do: "A decision is already recorded for this claim revision."

  defp error_message(:superseded_revision),
    do: "This claim has a newer revision. Review that revision instead."

  defp error_message(:invalid_citation),
    do: "The citation is unavailable or no longer eligible. Import current evidence."

  defp error_message(:invalid_claim_basis),
    do: "Choose a saved goal and its current version, then propose the rule again."

  defp error_message(:stale_goal_basis),
    do:
      "The saved goal is unavailable or has changed. Review the current goal and propose a new rule revision."

  defp error_message(:stale_goal_form),
    do: "This goal-rule form changed. Use the refreshed controls before retrying."

  defp error_message(:claim_origin_change),
    do: "A claim revision must keep its original source or goal basis. Propose a separate rule."

  defp error_message(:goal_claim_requires_plan),
    do:
      "Goal-based rules require an approved Company plan. Select the rule and its goal, then approve the exact plan before building."

  defp error_message(:source_unavailable),
    do: "The source is unavailable. Import current evidence."

  defp error_message(:provider_unavailable),
    do: "This provider is not configured for this workspace."

  defp error_message(:path_escape),
    do: "Choose an allowed directory without traversal or symbolic links."

  defp error_message(:no_approved_claims),
    do: "Approve at least one eligible claim before building a package."

  defp error_message(:unsafe_directory),
    do: "Select an existing absolute directory without symbolic links."

  defp error_message(:invalid_input), do: "Complete all required fields with valid values."

  defp error_message(:target_exists),
    do: "The export destination already exists. Choose a new directory."

  defp error_message(:qualified_task_evaluation_required),
    do:
      "Release approval requires passed model-backed tasks. A diagnostic or blocked run cannot qualify."

  defp error_message(:runtime_unqualified),
    do:
      "Use the supported runtime version and complete its task evaluation before approving a release."

  defp error_message(:stale_or_revoked_evidence),
    do: "This package uses withdrawn or changed evidence. Review current claims and rebuild."

  defp error_message(:confirmation_mismatch),
    do: "Enter the exact displayed identifier to confirm content removal."

  defp error_message(:privacy_operation_incomplete),
    do:
      "Content removal is incomplete. Restore Docker access if needed, then retry or restart to recover."

  defp error_message(:cleanup_failed),
    do:
      "Container cleanup is incomplete. Restore Docker access and retry before removing content."

  defp error_message(:jobs_still_executing),
    do:
      "A related operation is still running. Wait for it to finish before removing this content."

  defp error_message(:stale_channel),
    do: "The release channel changed. Refresh and review its current assignment."

  defp error_message(:evaluations_still_running),
    do: "An evaluation is still running. Finish or cancel it before removing content."

  defp error_message(:evaluation_identities_differ),
    do:
      "These runs use different tasks, scope, runtime or model settings. Run both under matching conditions."

  defp error_message(%HarnessForge.Contracts.Error{code: code, message: message})
       when code in ~w(unsupported_runtime invalid_runtime_intent unsupported_required_control runtime_unqualified),
       do: message

  defp error_message(%HarnessForge.Contracts.Error{code: code}), do: connector_error(code)

  defp error_message(_),
    do: "The operation was rejected. Check the supplied values and current evidence."

  defp connector_error("invalid_connector_config"),
    do: "Check the selected scope, site origin and environment reference names."

  defp connector_error("credential_unavailable"),
    do:
      "A referenced API credential is missing from the server environment. Set it and restart the server."

  defp connector_error("source_access_denied"),
    do: "API access was denied. Correct token permissions and save a new connection."

  defp connector_error("rate_limited"),
    do: "The provider rate limited this page. Wait before syncing again."

  defp connector_error(_),
    do: "The provider page could not be imported. Inspect the connection status."

  defp title("evidence"), do: "Evidence, with a paper trail."
  defp title("company"), do: "Build around your company."
  defp title("chat"), do: "Ask across your connected sources."
  defp title("connections"), do: "Bring your context together."
  defp title("goals"), do: "Give your agents a clear finish line."
  defp title("package"), do: "Turn decisions into a harness."
  defp title("evaluations"), do: "Prove it before you ship it."
  defp title("releases"), do: "Every release, accounted for."
  defp title("audit"), do: "A record of what changed."
  defp title("privacy"), do: "Your workspace stays yours."
  defp label("company"), do: "Home"
  defp label("connections"), do: "Sources"
  defp label("evidence"), do: "Review"
  defp label("package"), do: "Your harness"
  defp label("evaluations"), do: "Checks"
  defp label("audit"), do: "Audit trail"
  defp label("privacy"), do: "Privacy & storage"
  defp label(tab), do: String.capitalize(tab)

  defp proposed(claims),
    do: Enum.count(claims, &(&1["status"] == "proposed" and not &1["superseded"]))

  defp short(value) when is_binary(value), do: String.slice(value, 0, 12)
  defp short(_), do: "—"

  defp artifact_name(artifact),
    do: get_in(artifact, ["spec", "metadata", "name"]) || "Harness package"

  defp artifact_version(artifact),
    do: get_in(artifact, ["spec", "metadata", "version"]) || "built"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="workspace-shell">
      <aside class="sidebar" aria-label="Workspace navigation">
        <a class="brand" href={~p"/"} aria-label="HarnessForge workspace"><span class="brand-mark">H</span>
        HarnessForge</a>
        <div class="workspace-switch">
          <span class="workspace-avatar">W</span><div>
            <strong>Local workspace</strong><small>Personal · Open source</small>
          </div><span class="workspace-lock" aria-label="Private workspace">⌑</span>
        </div>
        <p class="nav-heading">BUILD YOUR HARNESS</p>
        <nav aria-label="Company harness journey">
          <button
            :for={tab <- ~w(company connections evidence package evaluations)}
            id={"nav-#{tab}"}
            phx-click="tab"
            phx-value-tab={tab}
            class={["nav-item", @tab == tab && "active"]}
            aria-current={@tab == tab && "page"}
          >
            <span class="nav-dot" aria-hidden="true">{nav_symbol(tab)}</span><span>{label(tab)}</span><span
              :if={tab == "evidence" and proposed(@claims) > 0}
              class="nav-count"
            >{proposed(@claims)}</span>
          </button>
        </nav>
        <div class="sidebar-bottom">
          <details
            id="workspace-tools"
            class="workspace-tools"
            open={@tab in ~w(chat goals releases audit privacy)}
          >
            <summary>More workspace tools</summary>
            <nav aria-label="Additional workspace tools">
              <button
                :for={tab <- ~w(chat goals releases audit privacy)}
                id={"nav-#{tab}"}
                class={["nav-item", @tab == tab && "active"]}
                phx-click="tab"
                phx-value-tab={tab}
                aria-current={@tab == tab && "page"}
              >
                <span class="nav-dot" aria-hidden="true">{nav_symbol(tab)}</span>{label(tab)}
              </button>
            </nav>
          </details>
          <div class="local-indicator">
            <span></span> Running locally
          </div>
        </div>
      </aside>
      <div class="workspace-main">
        <header class="topbar">
          <div>
            <span class="breadcrumb">Workspace</span><span aria-hidden="true"> / </span><strong>{label(
              @tab
            )}</strong>
          </div><div class="topbar-actions">
            <span class="pill local">LOCAL-FIRST</span><.form
              for={%{}}
              action={~p"/session"}
              method="delete"
              id="logout-form"
            >
              <button class="text-button" id="lock-workspace" type="submit">Lock workspace</button>
            </.form><span class="operator-avatar" aria-label="Local operator">LO</span>
          </div>
        </header>
        <main id="main-content" class="content" aria-label={if @tab == "company", do: "Company home"}>
          <div
            :if={@command_approval_notice && @tab != "evaluations"}
            id="command-approval-notice"
            class="context-note"
            role="status"
          >
            <p>An isolated agent requested a command decision.</p>
            <button type="button" class="button secondary" phx-click="tab" phx-value-tab="evaluations">Review command request</button>
          </div>
          <.workspace_hero :if={@tab != "company"} tab={@tab} />
          <div :if={Phoenix.Flash.get(@flash, :info)} id="notice" class="notice success" role="status">
            {Phoenix.Flash.get(@flash, :info)}
          </div>
          <div :if={Phoenix.Flash.get(@flash, :error)} id="error" class="notice error" role="alert">
            {Phoenix.Flash.get(@flash, :error)}
          </div>
          <div :if={@data_errors != []} id="data-unavailable" class="notice error" role="alert">
            Some workspace records are unavailable: {Enum.join(@data_errors, ", ")}. Check workspace storage before continuing.
          </div>
          <section
            :if={@tab not in ["chat", "company"]}
            class="metrics"
            aria-label="Workspace summary"
          >
            <div>
              <span class="metric-label">SOURCES CAPTURED</span><strong>{@source_total || "Unknown"}</strong><small>Local captures; company coverage unknown</small>
            </div><div>
              <span class="metric-label">AWAITING A DECISION</span><strong>{proposed(@claims)}<span class="metric-dot amber"></span></strong><small>Proposals need your review</small>
            </div><div>
              <span class="metric-label">APPROVED CLAIMS</span><strong>{length(@approved)}<span class="metric-dot green"></span></strong><small>Eligible for compilation</small>
            </div><div>
              <span class="metric-label">HARNESS PACKAGES</span><strong>{length(@artifacts)}</strong><small>Deterministic &amp; versioned</small>
            </div>
          </section>
          <.live_component
            module={HarnessForgeWeb.CompanyPanel}
            id="company-builder"
            active={@tab == "company"}
            operator_auth={@operator_auth}
            workspace_id={@workspace_id}
            home_setup_id={@home_setup_id}
            home_setup_invalid={@home_setup_invalid}
            setup_creation_request={@setup_creation_request}
            company_reset_token={@company_reset_token}
            company_sensitive_reset_token={@company_sensitive_reset_token}
            company_refresh_token={@company_refresh_token}
            claim_review_count={@claim_review_count}
            analysis_open={@requested_company_review}
            data_errors={@data_errors}
            sources={@sources}
            goals={@goals}
            approved={@approved}
            claims={@claims}
            model_status={@model_status}
            artifacts={@artifacts}
            assessment_state={@assessment_state}
            assessment_event_generation={@assessment_event_generation}
            assessment_rubrics={@assessment_rubrics}
          />

          <details :if={@tab == "company"} id="company-home-about">
            <summary id="company-home-about-toggle">About this workspace and demo</summary>
            <.workspace_hero tab={@tab} />
          </details>

          <section :if={@tab == "evidence"} id="evidence-panel" class="tab-panel" tabindex="-1">
            <div class="section-heading">
              <div>
                <h2>Evidence review</h2><p>
                  Review captured evidence or saved intent. Only your explicit approval makes a claim eligible.
                </p>
              </div><span class="pill neutral">HUMAN DECISION REQUIRED</span>
            </div>
            <div :if={@claims == []} class="empty-state">
              <div class="empty-icon" aria-hidden="true">≋</div><h3>
                A well-grounded harness starts here.
              </h3><p>
                Capture a source or save a goal to propose a claim for review.
              </p><button
                id="empty-connect"
                phx-click="tab"
                phx-value-tab="connections"
                class="button primary"
              >Connect a source <span aria-hidden="true">→</span></button>
            </div>
            <div :for={claim <- @claims} id={"claim-#{claim["id"]}"} class="claim-card">
              <div class="claim-meta">
                <span class={["pill", claim["status"]]}>{String.upcase(claim["status"])}</span><span
                  :if={claim["superseded"]}
                  class="pill neutral"
                >SUPERSEDED</span><code>revision {short(claim["revision_hash"])}</code>
              </div>
              <h3>{claim["text"]}</h3>
              <p>{claim_origin_label(claim)}</p>
              <AnalysisUI.report
                :if={AnalysisUI.analysis?(claim)}
                claim={claim}
                id={"analysis-origin-" <> claim["id"]}
                goals={@goals}
                sources={evidence_report_sources(claim, @evidence_review, @sources)}
                source_refs={evidence_report_refs(claim, @evidence_review)}
              />
              <button
                :if={AnalysisUI.analysis?(claim)}
                id={"analysis-edit-" <> claim["id"]}
                phx-click="company_analysis_review"
                phx-value-id={claim["id"]}
                phx-value-revision_hash={claim["revision_hash"]}
                class="button secondary"
              >Open current guidance in Company</button>
              <div :if={match?(%{"kind" => "goal"}, claim["basis"])} id={"goal-origin-#{claim["id"]}"}>
                <p>This rule is based on saved intent and has no source citation.</p>
                <dl :if={@goal_claim_reviews[claim["id"]]}>
                  <dt>Goal</dt><dd>{@goal_claim_reviews[claim["id"]]["title"]}</dd>
                  <dt>Owner</dt><dd>{@goal_claim_reviews[claim["id"]]["owner"]}</dd>
                  <dt>Acceptance criteria</dt><dd>
                    {@goal_claim_reviews[claim["id"]]["acceptance"]}
                  </dd>
                </dl>
                <p :if={!@goal_claim_reviews[claim["id"]]} class="context-note">
                  The saved goal is unavailable or has changed. This rule cannot be approved; review the current goal and propose a new rule revision.
                </p>
                <details id={"goal-origin-details-#{claim["id"]}"} class="citation">
                  <summary aria-label={"Exact origin details for claim: #{claim["text"]}"}>
                    Exact origin details
                  </summary>
                  <p>Claim revision <code>{claim["revision_hash"]}</code></p>
                  <p>Goal ID <code>{claim["basis"]["goal_id"]}</code></p>
                  <p>Pinned goal content hash <code>{claim["basis"]["goal_content_hash"]}</code></p>
                </details>
              </div>
              <details
                :for={citation <- claim["citations"]}
                id={"citation-#{claim["id"]}-#{citation["id"]}"}
                class="citation"
              >
                <summary aria-label="View supporting source citation">
                  Supporting source · {short(citation["revision_id"])}
                </summary><blockquote>{citation["snippet"]}</blockquote><span>Exact captured source · bytes {citation[
                  "start_byte"
                ]}–{citation["end_byte"]}</span>
              </details>
              <div class="claim-actions">
                <span>{if AnalysisUI.analysis?(claim),
                  do:
                    "Review the original report, uncertainty, current guidance and saved human resolution before deciding.",
                  else:
                    if(claim["basis"],
                      do:
                        "Review the claim and saved goal version before approving this exact revision.",
                      else: "Review the citation before making a decision."
                    )}</span><div :if={claim["status"] == "proposed" and not claim["superseded"]}>
                  <button
                    id={"reject-#{claim["id"]}"}
                    phx-click="decide"
                    phx-value-id={claim["id"]}
                    phx-value-revision={claim["revision_hash"]}
                    phx-value-decision="reject"
                    class="button secondary"
                    aria-label={"Reject claim: #{claim["text"]}"}
                  >Reject</button><button
                    id={"approve-#{claim["id"]}"}
                    phx-click="decide"
                    phx-value-id={claim["id"]}
                    phx-value-revision={claim["revision_hash"]}
                    phx-value-decision="approve"
                    class="button primary"
                    disabled={claim_approval_blocked?(claim, @goal_claim_reviews)}
                    aria-label={"Approve claim: #{claim["text"]}"}
                  >Approve revision <span aria-hidden="true">✓</span></button>
                </div>
              </div>
            </div>
            <div :if={@sources != []} class="panel">
              <h3>Propose a sourced claim</h3><p>
                Use one captured document as its citation. The full source is linked; no automatic approval occurs.
              </p><.form for={%{}} id="propose-form" phx-submit="propose" class="stack">
                <label for="claim-source">Source snapshot</label><select
                  id="claim-source"
                  name="claim[source_snapshot]"
                  required
                ><option value="">Choose a captured document</option><option
                  :for={source <- @sources}
                  :if={source["latest_revision"] && source["status"] == "active"}
                  value={source["id"] <> ":" <> source["latest_revision"]["id"]}
                >
                  {source["title"]} · {short(source["latest_revision"]["body_hash"])}
                </option></select><label for="claim-text">Claim to review</label><textarea
                  id="claim-text"
                  name="claim[text]"
                  required
                  rows="3"
                  maxlength="10000"
                  placeholder="State one clear, verifiable instruction or constraint."
                ></textarea><button id="propose-claim" class="button primary" type="submit">Propose for review</button>
              </.form>
            </div>
            <div id="goal-rule-proposal" class="panel">
              <h3>Propose a goal-based rule</h3>
              <p id="goal-rule-help">
                Choose a saved goal and write the rule separately. Saving or selecting a goal does not approve a rule.
              </p>
              <p :if={"goals" in @data_errors} id="goal-rule-unavailable" class="context-note">
                Saved goals are unavailable. Reload before proposing a goal-based rule.
              </p>
              <div :if={@goals == [] && "goals" not in @data_errors}>
                <p>No saved goals are available. Save a goal in Goals, then return here.</p>
                <button
                  id="goal-rule-save-goal"
                  phx-click="tab"
                  phx-value-tab="goals"
                  class="button secondary"
                >Save a goal</button>
              </div>
              <div
                :if={@goals != [] && "goals" not in @data_errors}
                id={"goal-rule-draft-#{@goal_claim_generation}"}
              >
                <.form
                  for={%{}}
                  id="propose-goal-form"
                  phx-change="goal_claim_change"
                  phx-submit="propose_goal"
                  phx-auto-recover="ignore"
                  class="stack"
                >
                  <input type="hidden" name="goal_claim_generation" value={@goal_claim_generation} />
                  <label for={"goal-claim-goal-#{@goal_claim_generation}"}>Saved goal</label>
                  <select
                    id={"goal-claim-goal-#{@goal_claim_generation}"}
                    name="goal_claim[goal_snapshot]"
                    aria-describedby="goal-rule-help"
                    required
                  >
                    <option value="" selected={@goal_claim_draft["goal_snapshot"] == ""}>
                      Choose a saved goal
                    </option>
                    <option
                      :for={goal <- @goals}
                      value={goal["id"] <> ":" <> Goals.content_hash(goal)}
                      selected={
                        @goal_claim_draft["goal_snapshot"] ==
                          goal["id"] <> ":" <> Goals.content_hash(goal)
                      }
                    >
                      {goal["title"]} · {goal["owner"]} · {short(goal["id"])}
                    </option>
                  </select>
                  <label for={"goal-claim-text-#{@goal_claim_generation}"}>Rule to review</label>
                  <textarea
                    id={"goal-claim-text-#{@goal_claim_generation}"}
                    name="goal_claim[text]"
                    required
                    rows="3"
                    maxlength="10000"
                  >{@goal_claim_draft["text"]}</textarea>
                  <button id="propose-goal-claim" class="button primary" type="submit">Propose goal-based rule for review</button>
                </.form>
              </div>
            </div>
            <div class="section-heading source-heading">
              <div>
                <h2 id="source-snapshots" tabindex="-1">Source snapshots</h2><p>
                  Up to 25 metadata rows per page. Open one bounded captured-text window for inspection.
                </p>
              </div><.form for={%{}} id="search-form" phx-submit="search" class="search-form">
                <label class="sr-only" for="evidence-query">Search source text</label><input
                  id="evidence-query"
                  name="query"
                  value={@query}
                  placeholder="Search captured text…"
                /><button id="search-evidence" class="button secondary" type="submit">Search</button>
              </.form>
            </div>
            <p :if={@search_results == []} class="muted">
              No matching sources. Clear the search to show all snapshots.
            </p>
            <article
              :for={source <- @search_results || @sources}
              id={"source-#{source["id"]}"}
              class="source-card"
            >
              <h3>{source["title"]}<span class="pill neutral">{source["status"]}</span></h3><div :if={
                source["latest_revision"]
              }>
                <p>
                  Captured revision <code>{source["latest_revision"]["id"]}</code>
                  · {source["latest_revision"]["body_bytes"]} bytes
                </p>
                <button
                  id={"source-open-" <> source["id"]}
                  phx-click="source_open"
                  phx-value-id={source["id"]}
                  class="button secondary"
                >Open captured text window</button>
                <button
                  phx-click="model_propose"
                  phx-value-id={source["id"]}
                  class="button secondary"
                  phx-disable-with="Queuing…"
                >Propose with configured model</button>
              </div>
            </article>
            <.source_pagination
              page={@source_page}
              stack={@source_cursor_stack}
              id="evidence-source-pages"
            />
            <section
              :if={@source_passage}
              id="source-opened-passage"
              class="panel"
              tabindex="-1"
              aria-label="Opened captured text window"
            >
              <h3>{@source_passage["source"]["title"]}</h3>
              <p>
                Exact UTF-8 bytes {@source_passage["start_byte"]}–{@source_passage["end_byte"]} (end exclusive), of {@source_passage[
                  "body_bytes"
                ]}. This preview grants no approval.
              </p>
              <p :if={@source_passage["truncated_before"] || @source_passage["truncated_after"]}>
                Partial parent context. Other text may change the meaning.
              </p>
              <pre>{@source_passage["text"]}</pre>
              <button
                :if={@source_passage["truncated_before"]}
                id="source-passage-first"
                phx-click="source_passage_first"
                class="button secondary"
              >Read context from start</button>
              <button
                :if={@source_passage["next_start_byte"]}
                phx-click="source_passage_next"
                class="button secondary"
              >Next text window</button>
              <button phx-click="source_close" class="button secondary">Close captured text</button>
            </section>
          </section>

          <section
            :if={@tab == "connections"}
            id="connections-panel"
            class="tab-panel two-column"
            tabindex="-1"
          >
            <div class="panel">
              <p class="eyebrow">SOURCE CONNECTION</p><h2>Connect a local directory</h2><p>
                Approve one absolute directory. Import captures supported text files without running project code.
              </p><.form for={%{}} id="connection-form" phx-submit="connect" class="stack">
                <label for="connection-name">Connection name</label><input
                  id="connection-name"
                  name="connection[name]"
                  placeholder="Project documentation"
                  required
                  maxlength="120"
                /><label for="connection-directory">Absolute directory path</label><input
                  id="connection-directory"
                  name="connection[directory]"
                  placeholder="/path/to/approved/docs"
                  required
                /><p class="field-help">
                  Selected text is captured as written. Review documents for secrets before connecting a directory.
                </p><button id="connect-directory" class="button primary" type="submit">Approve directory connection</button>
              </.form>
            </div>
            <div>
              <div class="panel">
                <h3>Connected sources</h3><p :if={@connections == []} class="muted">
                  No directories connected yet.
                </p><article
                  :for={connection <- @connections}
                  class="connection-row"
                  id={"connection-#{connection["id"]}"}
                >
                  <div>
                    <strong>{connection["name"]}</strong><small>{connection["provider"]} · {connection[
                      "status"
                    ]}</small>
                  </div><button
                    :if={connection["status"] == "active"}
                    id={"import-#{connection["id"]}"}
                    phx-click="import"
                    phx-value-id={connection["id"]}
                    class="button secondary"
                    phx-disable-with="Importing…"
                  >Sync next page</button>
                  <small>Complete: {inspect(connection["sync_complete"])} · {connection["sync_state"] ||
                    "not synced"}</small>
                  <p
                    :if={
                      connection["sync_state"] in ~w(credential_unavailable source_access_denied rate_limited)
                    }
                    class="field-help"
                  >
                    {connector_error(connection["sync_state"])}
                  </p>
                </article>
              </div><div class="context-note">
                <h3>Read-only remote sources</h3><p>
                  Choose one repository, board, channel, project or space. API credentials use environment variable names; signing into a browser does not authenticate this connection.
                </p>
                <.form
                  for={%{}}
                  id="remote-form"
                  phx-change="remote_changed"
                  phx-submit="connect_remote"
                  class="stack"
                >
                  <label for="remote-provider">Provider</label><select
                    id="remote-provider"
                    name="remote[provider]"
                  >
                    <option value="github" selected={@remote_provider == "github"}>
                      GitHub repository
                    </option>
                    <option value="github_projects" selected={@remote_provider == "github_projects"}>
                      GitHub Projects board
                    </option>
                    <option value="jira" selected={@remote_provider == "jira"}>Jira Cloud</option>
                    <option value="slack" selected={@remote_provider == "slack"}>
                      Slack channel
                    </option>
                    <option value="confluence" selected={@remote_provider == "confluence"}>
                      Confluence Cloud
                    </option>
                  </select>
                  <label for="remote-name">Connection name</label><input
                    id="remote-name"
                    name="remote[name]"
                    required
                    maxlength="120"
                  />
                  <div :if={@remote_provider == "github"} class="stack">
                    <label for="remote-repository">Repository (owner/repository)</label><input
                      id="remote-repository"
                      name="remote[repository]"
                      required
                      placeholder="owner/repository"
                    />
                    <p class="field-help">
                      Repository metadata, issues, pull requests and reviews. A token is optional for public reads.
                    </p>
                  </div>
                  <div :if={@remote_provider == "github_projects"} class="stack">
                    <label for="remote-project-url">Projects board URL</label><input
                      id="remote-project-url"
                      name="remote[project_url]"
                      required
                      placeholder="https://github.com/orgs/OWNER/projects/1"
                    />
                    <p class="field-help">
                      One organization or user project: metadata, fields, views and items. Token needs Projects read access; repository access affects visible item content.
                    </p>
                  </div>
                  <div :if={@remote_provider in ~w(jira confluence)} class="stack">
                    <label for="remote-endpoint">Atlassian site origin</label><input
                      id="remote-endpoint"
                      name="remote[endpoint]"
                      required
                      placeholder="https://your-site.atlassian.net"
                    />
                    <label for="remote-username">Email environment reference</label><input
                      id="remote-username"
                      name="remote[username_ref]"
                      required
                      placeholder="HARNESSFORGE_ATLASSIAN_EMAIL"
                    />
                    <p class="field-help">
                      Email and API-token values must be set in the server environment. Use the site origin without /wiki.
                    </p>
                  </div>
                  <div :if={@remote_provider == "jira"} class="stack">
                    <label for="remote-project">Jira project key</label><input
                      id="remote-project"
                      name="remote[project]"
                      required
                      placeholder="DEMO"
                    />
                    <p class="field-help">
                      Selected-project issues, text descriptions and changelogs.
                    </p>
                  </div>
                  <div :if={@remote_provider == "confluence"} class="stack">
                    <label for="remote-space">Confluence numeric space ID</label><input
                      id="remote-space"
                      name="remote[space_id]"
                      required
                      inputmode="numeric"
                      pattern="[1-9][0-9]*"
                      placeholder="12345"
                    />
                    <p class="field-help">
                      Current pages in one space. Text only; macros and attachments are omitted. Use a site API token; scoped tokens requiring the Atlassian gateway are unsupported.
                    </p>
                  </div>
                  <div :if={@remote_provider == "slack"} class="stack">
                    <label for="remote-team">Slack workspace ID</label><input
                      id="remote-team"
                      name="remote[team_id]"
                      required
                      placeholder="T0123456789"
                    />
                    <label for="remote-channel">Slack channel ID</label><input
                      id="remote-channel"
                      name="remote[channel_id]"
                      required
                      placeholder="C0123456789"
                    />
                    <p class="field-help">
                      Messages and replies in one joined channel. User token with team:read and the selected channel's read/history scopes; no direct messages or files.
                    </p>
                  </div>
                  <label for="remote-credential">Token environment reference</label><input
                    id="remote-credential"
                    name="remote[credential_ref]"
                    required={@remote_provider != "github"}
                    placeholder="HARNESSFORGE_SOURCE_TOKEN"
                  />
                  <p class="field-help">
                    Set the referenced variables before starting the server. Only their names are stored. Sync next page continues a bounded scan; errors preserve the last committed cursor.
                  </p>
                  <button class="button primary" type="submit">Save selected scope</button>
                </.form>
              </div>
            </div>
          </section>

          <section :if={@tab == "connections"} class="panel">
            <HarnessForgeWeb.AccountPanel.accounts
              catalog={@chat_catalog["accounts"] || []}
              service={@account_service}
              pending={@account_pending}
              available_github_refs={github_credential_refs()}
            />
          </section>

          <section :if={@tab == "connections"} class="panel">
            <h2>Model API connections</h2><p>
              Provider: {@model_status["provider"]} · Destination: {@model_status["endpoint"] ||
                "not configured"} · {@model_status["availability"]} · {@model_status["reason"]}
            </p>
            <p>
              Configuration readiness does not verify provider access. Cloud requests require an API key reference, declared price estimates and consent for specific sources. Saving settings makes no model call.
            </p>
            <.form
              for={%{}}
              id="model-form"
              phx-change="model_changed"
              phx-submit="model_configure"
              class="stack"
            >
              <input type="hidden" name="model[source_generation]" value={@source_view_generation} />
              <label for="model-provider">Model provider</label><select
                id="model-provider"
                name="model[provider]"
              >
                <option value="ollama" selected={@model_provider == "ollama"}>Local Ollama</option>
                <option value="openai_responses" selected={@model_provider == "openai_responses"}>
                  OpenAI Responses / Codex models
                </option>
                <option value="anthropic" selected={@model_provider == "anthropic"}>
                  Anthropic / Claude models
                </option>
                <option value="openai" selected={@model_provider == "openai"}>
                  OpenAI Chat Completions
                </option>
              </select>
              <div :if={@model_provider == "ollama"} class="stack">
                <label for="model-endpoint">Ollama endpoint</label><input
                  id="model-endpoint"
                  name="model[endpoint]"
                  value="http://127.0.0.1:11434"
                  required
                />
                <p class="field-help">
                  Choose an already installed local model. HarnessForge does not download models or use a cloud fallback.
                </p>
              </div>
              <label for="model-name">Model name</label><input
                id="model-name"
                name="model[model]"
                required
              />
              <div :if={@model_provider != "ollama"} class="stack">
                <label for="model-key">API key environment reference</label><input
                  id="model-key"
                  name="model[credential_env]"
                  placeholder="HARNESSFORGE_MODEL_API_KEY"
                  required
                />
                <p class="field-help">
                  Enter the name of a server environment variable, never the key value. Browser and coding-agent logins are separate from API authentication.
                </p>
                <label for="model-input-price">Estimated input price (USD per million tokens)</label><input
                  id="model-input-price"
                  name="model[input_price]"
                  type="number"
                  min="0.000001"
                  step="0.000001"
                  required
                />
                <label for="model-output-price">Estimated output price (USD per million tokens)</label><input
                  id="model-output-price"
                  name="model[output_price]"
                  type="number"
                  min="0.000001"
                  step="0.000001"
                  required
                />
                <p class="field-help">
                  Set conservative prices for your chosen model, including any cache-writing premium. Ledger totals are estimates, not invoices. Default proposal limits: 10 requests, 100,000 tokens and USD 1 estimated spend per run.
                </p>
                <fieldset>
                  <legend>Sources permitted for this provider</legend>
                  <input type="hidden" name="model[source_ids][]" value="" />
                  <p>
                    Current metadata page plus your saved selections. Paging does not remove checked sources. At most 100 sources can be permitted.
                  </p>
                  <p :if={@sources == [] && @model_source_ids == []}>
                    Import a source before enabling cloud consent.
                  </p>
                  <label :for={
                    source <-
                      consent_source_options(@sources, @model_selected_sources, @model_source_ids)
                  }>
                    <input
                      type="checkbox"
                      name="model[source_ids][]"
                      value={source["id"]}
                      checked={source["id"] in @model_source_ids}
                      disabled={!source["eligible"] && source["id"] not in @model_source_ids}
                    /> {source[
                      "title"
                    ]}
                    <span :if={!source["eligible"]}>(unavailable; remove explicitly)</span>
                  </label>
                </fieldset>
                <.source_pagination
                  page={@source_page}
                  stack={@source_cursor_stack}
                  id="model-source-pages"
                />
                <label for="model-cloud-consent"><input
                  id="model-cloud-consent"
                  type="checkbox"
                  name="model[cloud_consent_ack]"
                  value="true"
                  checked={
                    @model_status["provider"] == @model_provider &&
                      is_map(@model_status["cloud_consent"])
                  }
                />
                I allow source text from the checked sources to be sent to this provider when I explicitly request a proposal or AI answer.</label>
                <label for="model-chat-consent"><input
                  id="model-chat-consent"
                  type="checkbox"
                  name="model[chat_consent_ack]"
                  value="true"
                  checked={
                    @model_status["provider"] == @model_provider &&
                      "chat_context" in (get_in(@model_status, ["cloud_consent", "data_categories"]) ||
                                           [])
                  }
                />
                I also allow chat questions, up to four recent questions, and source labels to be sent to this provider for AI answers.</label>
                <label for="model-company-context-consent"><input
                  id="model-company-context-consent"
                  type="checkbox"
                  name="model[company_context_consent_ack]"
                  value="true"
                  checked={
                    @model_status["provider"] == @model_provider &&
                      "company_context" in (get_in(@model_status, ["cloud_consent", "data_categories"]) ||
                                              [])
                  }
                />
                I also allow the selected saved goal and company/project context to be sent to this provider when I explicitly request Company analysis.</label>
              </div>
              <button class="button secondary" type="submit">Save model connection</button>
            </.form>
          </section>

          <HarnessForgeWeb.ChatPanel.chat
            :if={@tab == "chat"}
            turns={@chat_turns}
            pending={@chat_pending}
            error={@chat_error}
            catalog={@chat_catalog}
            mode={@chat_mode}
            requires_live={@chat_requires_live}
          />

          <section :if={@tab == "goals"} id="goals-panel" class="tab-panel two-column" tabindex="-1">
            <div class="panel">
              <div
                :if={@setup_creation_request && @setup_creation_request["section"] == "goal"}
                id="setup-create-goal-return"
                class="context-note"
              >
                <p>
                  Save the goal, then explicitly assign it to your company profile or project before choosing it in setup.
                </p>
                <p :if={@setup_goal_dirty} role="status">Save your goal before leaving this form.</p>
                <div :if={!@setup_goal_dirty && connected?(@socket)} class="company-actions">
                  <.link
                    id="setup-create-goal-return-link"
                    href={@setup_creation_request["return_path"]}
                    class="button secondary"
                  >Return to saved setup</.link>
                  <.link
                    id="setup-create-goal-assign"
                    href={"/?" <> URI.encode_query(%{"create" => "profile", "return_setup" => @setup_creation_request["return_id"], "return_step" => @setup_creation_request["return_step"]})}
                    class="button secondary"
                  >Assign saved goals in company context</.link>
                </div>
              </div>
              <h2>Define a goal</h2><p>
                A named owner and observable acceptance criteria keep agent work bounded.
              </p><.form
                for={%{}}
                id="goal-form"
                phx-submit="goal"
                phx-change={
                  if @setup_creation_request && @setup_creation_request["section"] == "goal",
                    do: "setup_goal_edit"
                }
                class="stack"
              >
                <label for="goal-title">Goal</label><input
                  id="goal-title"
                  name="goal[title]"
                  required
                  placeholder="Deliver a cited, reproducible harness"
                /><label for="goal-owner">Owner</label><input
                  id="goal-owner"
                  name="goal[owner]"
                  required
                  placeholder="Maintainer or team"
                /><label for="goal-acceptance">Acceptance criteria</label><textarea
                  id="goal-acceptance"
                  name="goal[acceptance]"
                  required
                  rows="4"
                  placeholder="What specific check establishes completion?"
                ></textarea><button id="save-goal" type="submit" class="button primary">Save goal</button>
              </.form>
            </div><div>
              <div :if={@goals == []} class="empty-state compact">
                <h3>No goals yet.</h3><p>
                  Make the expected result explicit before building your package.
                </p>
              </div><article :for={goal <- @goals} class="panel" id={"goal-#{goal["id"]}"}>
                <span class="pill neutral">{goal["owner"]}</span><h3>{goal["title"]}</h3><p>
                  {goal["acceptance"]}
                </p>
              </article>
            </div>
          </section>

          <section
            :if={@tab == "package"}
            id="package-panel"
            data-export-generation={@export_generation}
            class="tab-panel two-column"
            tabindex="-1"
          >
            <HarnessForgeWeb.PackageReadiness.inspector
              artifacts={@artifacts}
              runs={@runs}
              digest={@readiness_digest}
              evaluation_id={@readiness_evaluation_id}
              report={@readiness_report}
              message={@readiness_message}
              generation={@readiness_generation}
              controls_generation={@readiness_controls_generation}
            />
            <div class="panel">
              <p class="eyebrow">DETERMINISTIC COMPILER</p><h2>Build a harness package</h2><p>
                Only eligible, explicitly approved claim revisions compile. The output is immutable and identified by its digest.
              </p><.form
                for={%{}}
                id="build-form"
                phx-submit="build"
                phx-auto-recover="ignore"
                data-build-generation={@build_generation}
                data-company-reset-token={@company_reset_token}
                data-build-outcome={if @build_outcome == :name, do: "name"}
                class="stack"
              >
                <input type="hidden" name="package[generation]" value={@build_generation} />
                <label for="package-name">Package name</label><input
                  id="package-name"
                  name="package[name]"
                  required
                  value={@build_draft["name"]}
                  aria-invalid={if @build_outcome == :name, do: "true"}
                  aria-describedby={
                    if @build_outcome == :name,
                      do: "package-name-help package-name-error",
                      else: "package-name-help"
                  }
                /><p id="package-name-help" class="field-help">{PackageBuild.message(:name_help)}</p>
                <p :if={@build_outcome == :name} id="package-name-error" class="field-help">
                  {PackageBuild.message(:name)}
                </p><label for="package-version">Package version</label><input
                  id="package-version"
                  name="package[version]"
                  required
                  value={@build_draft["version"]}
                /><label for="package-runtime">Coding agent target</label><select
                  id="package-runtime"
                  name="package[runtime]"
                >
                  <option value="opencode" selected={@build_draft["runtime"] == "opencode"}>
                    OpenCode
                  </option><option value="codex" selected={@build_draft["runtime"] == "codex"}>
                    Codex CLI
                  </option><option
                    value="claude_code"
                    selected={@build_draft["runtime"] == "claude_code"}
                  >
                    Claude Code
                  </option>
                </select><label for="runtime-version">Runtime version</label><input
                  id="runtime-version"
                  name="package[runtime_version]"
                  required
                  value={@build_draft["runtime_version"]}
                  placeholder="Exact runtime version to target"
                /><p class="field-help">
                  Supported profiles: OpenCode 1.x, Codex 0.156.0 and Claude Code 2.1.311. Use unqualified for a native preview. Building does not execute the agent. Codex and Claude managed evaluations remain unavailable.
                </p><button
                  id="build-package"
                  type="submit"
                  class="button primary"
                  phx-disable-with="Compiling…"
                >Build immutable package <span aria-hidden="true">→</span></button>
              </.form>
            </div><div>
              <div class="panel">
                <h3>Built packages</h3>
                <p :if={@export_message} id="package-export-message" role="status" class="notice">
                  {@export_message}
                </p><p :if={@artifacts == []} class="muted">
                  No packages built yet.
                </p><article
                  :for={artifact <- @artifacts}
                  class="artifact-row"
                  id={"artifact-#{artifact["digest"]}"}
                  data-export-digest={artifact["digest"]}
                  data-export-active={
                    export_outcome(@export_outcome, artifact["digest"], @export_generation) && "true"
                  }
                  data-export-focus-kind={
                    if export_outcome(@export_outcome, artifact["digest"], @export_generation),
                      do: if(@export_outcome.status == :success, do: "result", else: "target")
                  }
                >
                  <strong>{artifact_name(artifact)}
                  <span class="pill neutral">{artifact_version(artifact)}</span>
                  <span class="pill neutral">{get_in(artifact, ["spec", "spec", "runtime", "name"])}</span></strong>
                  <code>{artifact["digest"]}</code>
                  <div class="company-actions">
                    <.link
                      id={"artifact-preview-#{artifact["digest"]}"}
                      href={"/harnesses/" <> artifact["digest"]}
                      class="button primary"
                    >Open your harness</.link>
                    <a
                      id={"artifact-download-#{artifact["digest"]}"}
                      href={"/harnesses/" <> artifact["digest"] <> "/download"}
                      class="button secondary"
                      download
                    >Download ZIP</a>
                  </div>
                  <p class="field-help">
                    Inspect the exact generated files or download them in your browser. Representative-task and release checks remain separate.
                  </p>
                  <details
                    id={"package-export-options-#{artifact["digest"]}"}
                    open={
                      !is_nil(export_outcome(@export_outcome, artifact["digest"], @export_generation))
                    }
                  >
                    <summary>Advanced: export to a local directory</summary>
                    <.form
                      for={%{}}
                      id={export_id("form", @export_generation, artifact["digest"])}
                      phx-submit="export"
                      phx-auto-recover="ignore"
                      class="stack"
                    >
                      <input type="hidden" name="export[generation]" value={@export_generation} />
                      <input type="hidden" name="export[digest]" value={artifact["digest"]} />
                      <label for={export_id("target", @export_generation, artifact["digest"])}>New export directory</label>
                      <p
                        id={export_id("help", @export_generation, artifact["digest"])}
                        class="field-help"
                      >
                        Choose a new absolute directory under an existing parent. Existing destinations are never replaced.
                      </p>
                      <input
                        type="text"
                        id={export_id("target", @export_generation, artifact["digest"])}
                        name="export[target]"
                        value={
                          if export_outcome(@export_outcome, artifact["digest"], @export_generation),
                            do: @export_outcome.target,
                            else: ""
                        }
                        aria-describedby={export_id("help", @export_generation, artifact["digest"]) <> if(export_outcome(@export_outcome, artifact["digest"], @export_generation) && @export_outcome.status == :error, do: " " <> export_id("error", @export_generation, artifact["digest"]), else: "")}
                        aria-invalid={
                          if export_outcome(@export_outcome, artifact["digest"], @export_generation) &&
                               @export_outcome.invalid_target,
                             do: "true"
                        }
                        required
                        maxlength="4096"
                        placeholder="/absolute/path/to/new-export"
                      />
                      <p
                        :if={
                          export_outcome(@export_outcome, artifact["digest"], @export_generation) &&
                            @export_outcome.status == :error
                        }
                        id={export_id("error", @export_generation, artifact["digest"])}
                        class="notice error"
                      >
                        {@export_outcome.message}
                      </p>
                      <button
                        id={export_id("action", @export_generation, artifact["digest"])}
                        type="submit"
                        class="button secondary"
                      >Export package</button>
                    </.form>
                  </details>
                  <div
                    :if={
                      export_outcome(@export_outcome, artifact["digest"], @export_generation) &&
                        @export_outcome.status == :success
                    }
                    id={export_id("result", @export_generation, artifact["digest"])}
                    class="notice success"
                    tabindex="-1"
                    role="status"
                    aria-live="polite"
                    aria-atomic="true"
                  >
                    <strong>Export complete</strong>
                    <p>{artifact_name(artifact)} · {artifact_version(artifact)}</p>
                    <p>Destination: <code>{@export_outcome.path}</code></p>
                    <p>Package digest: <code>{artifact["digest"]}</code></p>
                    <p>Files exported. Evaluation and release remain separate decisions.</p>
                  </div>
                </article>
              </div><div class="context-note">
                <h3>Review before execution</h3><p>
                  A package is a collection of context and configuration. Evaluation and release are separate decisions; compilation does not certify runtime behavior.
                </p>
              </div>
            </div>
          </section>

          <section :if={@tab == "evaluations"} id="evaluations-panel" class="tab-panel" tabindex="-1">
            <div class="panel">
              <h2>Evaluate a package</h2><p>
                Static checks and runtime configuration smokes are distinct from model-backed task results. Blocked runs remain visible and cannot approve a release. Repository code is never executed on this host.
              </p>
              <.form for={%{}} id="evaluation-form" phx-submit="evaluate" class="stack">
                <label for="evaluation-digest">Artifact</label><select
                  id="evaluation-digest"
                  name="evaluation[digest]"
                  required
                ><option :for={artifact <- @artifacts} value={artifact["digest"]}>
                  {artifact_name(artifact)} · {short(artifact["digest"])}
                </option></select>
                <label for="evaluation-kind">Check</label><select
                  id="evaluation-kind"
                  name="evaluation[kind]"
                ><option value="static_integrity">Static package integrity</option><option value="runtime_smoke">
                  Isolated runtime configuration smoke
                </option><option value="task">Isolated model-backed tasks</option></select>
                <button class="button primary" type="submit">Queue evaluation</button>
              </.form>
            </div>
            <div :if={length(@runs) >= 2} class="panel">
              <h3>Compare evaluation records</h3>
              <p>
                Compare matching task, scope, runtime and model conditions. Finite checks do not establish a productivity benefit.
              </p>
              <.form for={%{}} id="comparison-form" phx-submit="compare_runs" class="stack">
                <label for="comparison-baseline">Baseline run</label>
                <select id="comparison-baseline" name="comparison[baseline]" required>
                  <option :for={run <- @runs} value={run["id"]}>
                    {run["kind"]} · {run["outcome"]} · {short(run["id"])}
                  </option>
                </select>
                <label for="comparison-candidate">Candidate run</label>
                <select id="comparison-candidate" name="comparison[candidate]" required>
                  <option :for={run <- @runs} value={run["id"]}>
                    {run["kind"]} · {run["outcome"]} · {short(run["id"])}
                  </option>
                </select>
                <button class="button secondary" type="submit">Compare runs</button>
              </.form>
              <div :if={@comparison} id="comparison-result">
                <p>
                  Baseline: {@comparison["baseline"]["outcome"]} · Candidate: {@comparison[
                    "candidate"
                  ]["outcome"]}
                </p>
                <p>
                  Qualified pair: {inspect(@comparison["qualified"])} · {@comparison["conclusion"]}
                </p>
              </div>
            </div>
            <p :if={@command_review_message && !@command_review_run} role="status">
              {@command_review_message}
            </p>
            <HarnessForgeWeb.CommandApproval.panel
              :if={@command_review_run}
              rows={@command_requests}
              run_id={@command_review_run}
              message={@command_review_message}
              ready={connected?(@socket)}
            />
            <article :for={run <- @runs} class="panel" id={"run-#{run["id"]}"}>
              <span class="pill neutral">{run["outcome"]}</span><h3>
                {run["kind"]} · {short(run["artifact_digest"])}
              </h3><p>{HarnessForgeWeb.EvaluationReason.label(run["reason"])}</p><p>
                Runtime qualified: {inspect(run["runtime_qualified"])} · Cleanup: {run[
                  "cleanup_status"
                ]}
              </p><code>Evaluation {run["id"]}</code>
              <button
                :if={run["outcome"] == "running" && run["runtime_name"] == "codex"}
                type="button"
                phx-click="command_review_open"
                phx-value-id={run["id"]}
                class="button secondary"
              >Review commands</button>
              <button
                :if={run["outcome"] in ~w(pending running)}
                phx-click="cancel_run"
                phx-value-id={run["id"]}
                class="button secondary"
                phx-disable-with="Cancelling…"
              >Cancel evaluation</button>
            </article>
          </section>

          <section :if={@tab == "releases"} id="releases-panel" class="tab-panel" tabindex="-1">
            <div class="panel">
              <h2>Approve an evaluated release</h2><p>
                Approval requires an exact, qualified task evaluation. Static checks, configuration smokes and blocked runs cannot qualify a release.
              </p>
              <.form for={%{}} id="release-form" phx-submit="release_approve" class="stack">
                <label for="release-artifact">Artifact</label><select
                  id="release-artifact"
                  name="release[artifact_digest]"
                  required
                ><option :for={artifact <- @artifacts} value={artifact["digest"]}>
                  {artifact_name(artifact)} · {short(artifact["digest"])}
                </option></select>
                <label for="release-evaluation">Evaluation</label><select
                  id="release-evaluation"
                  name="release[evaluation_id]"
                  required
                ><option :for={run <- @runs} value={run["id"]}>
                  {run["kind"]} · {run["outcome"]} · {short(run["id"])}
                </option></select>
                <button class="button primary" type="submit">Review and approve exact release</button>
              </.form>
            </div>
            <article :for={release <- @releases} class="panel">
              <h3>Approved {short(release["artifact_digest"])}</h3><p>
                Scope: {Jason.encode!(release["scope"])}
              </p>
              <button
                phx-click="promote"
                phx-value-id={release["id"]}
                phx-value-expected={current_release(release)}
                class="button primary"
              >Assign pilot channel</button>
              <button
                phx-click="rollback"
                phx-value-id={release["id"]}
                phx-value-expected={current_release(release)}
                class="button secondary"
              >Restore prior assignment</button>
            </article>
            <div :if={length(@artifacts) >= 2} class="panel">
              <h3>Compare package versions</h3><.form
                for={%{}}
                id="diff-form"
                phx-submit="diff"
                class="stack"
              >
                <label for="diff-left">Baseline</label><select id="diff-left" name="diff[left]"><option
                  :for={artifact <- @artifacts}
                  value={artifact["digest"]}
                >
                  {artifact_version(artifact)} · {short(artifact["digest"])}
                </option></select>
                <label for="diff-right">Candidate</label><select id="diff-right" name="diff[right]"><option
                  :for={artifact <- @artifacts}
                  value={artifact["digest"]}
                >
                  {artifact_version(artifact)} · {short(artifact["digest"])}
                </option></select><button class="button secondary" type="submit">Compare exact versions</button>
              </.form><pre :if={@diff}>{Jason.encode!(@diff, pretty: true)}</pre>
            </div>
          </section>

          <section :if={@tab == "audit"} id="audit-panel" class="tab-panel panel">
            <div class="section-heading">
              <div>
                <h2>Workspace audit trail</h2><p>
                  Append-only decisions and operations. Credentials and evidence bodies are excluded.
                </p>
              </div><span class="pill neutral">LATEST 200</span>
            </div><p :if={@audit == []} class="muted">No recorded activity yet.</p><ol class="audit-list">
              <li :for={event <- @audit} id={"audit-#{event["id"]}"}>
                <span class="audit-dot"></span><div>
                  <strong>{event["action"]}</strong><p>{Jason.encode!(event["details"])}</p>
                </div><time>{event["inserted_at"]}</time>
              </li>
            </ol>
          </section>

          <section :if={@tab == "privacy"} id="privacy-panel" class="tab-panel two-column">
            <div class="panel">
              <p class="eyebrow">LOCAL STORAGE</p><h2>One workspace. Your computer.</h2><p>
                Evidence snapshots, decisions, generated packages, and audit records are stored in this workspace.
              </p><dl class="storage-info">
                <dt>Workspace ID</dt><dd><code>{@workspace_id}</code></dd><dt>Workspace directory</dt><dd>
                  <code>{@workspace_root}</code>
                </dd><dt>Cloud inference</dt><dd>
                  <span class="pill neutral">DISABLED BY DEFAULT</span>
                </dd><dt>Session</dt><dd>
                  Local operator · expires after 12 hours or application restart
                </dd>
              </dl>
            </div><div class="context-note">
              <h3>Deliberate boundaries</h3><p>
                Imported text is treated as untrusted evidence. Claim approval is explicit, generated packages are immutable, and unavailable runtimes cannot silently fall back to host execution.
              </p><p>
                Backups below are unencrypted and contain private evidence. Keep them in storage you control. Local session secrets are excluded. Restored workspaces require fresh connection, model and policy review.
              </p>
            </div>
          </section>
          <section :if={@tab == "privacy"} class="tab-panel two-column">
            <div class="panel">
              <h3>Consistent backup</h3><.form
                for={%{}}
                id="backup-form"
                phx-submit="backup"
                class="stack"
              >
                <label for="backup-target">New directory outside this workspace</label><input
                  id="backup-target"
                  name="privacy[target]"
                  required
                /><button class="button secondary" type="submit">Create unencrypted local backup</button>
              </.form><h3>Restore into a new workspace</h3><.form
                for={%{}}
                id="restore-form"
                phx-submit="restore"
                class="stack"
              >
                <label for="restore-backup">Backup directory</label><input
                  id="restore-backup"
                  name="privacy[backup]"
                  required
                />
                <label for="restore-target">New workspace directory</label><input
                  id="restore-target"
                  name="privacy[target]"
                  required
                /><button class="button secondary" type="submit">Verify and restore without prior authority</button>
              </.form>
            </div>
            <div class="panel">
              <h3>Remove a source and its derived content</h3><p>
                The owning connection is revoked to prevent automatic reimport. Unrelated content is preserved.
              </p><.form for={%{}} id="purge-source-form" phx-submit="purge_source" class="stack">
                <label for="purge-source-id">Source</label><select
                  id="purge-source-id"
                  name="privacy[id]"
                  required
                ><option :for={source <- @sources} value={source["id"]}>
                  {source["title"]} · {source["id"]}
                </option></select>
                <label for="purge-source-confirm">Type the complete selected source ID</label><input
                  id="purge-source-confirm"
                  name="privacy[confirmation]"
                  required
                /><button class="button secondary" type="submit">Purge selected source content</button>
              </.form><h3>Erase active workspace content</h3><p>
                Type the workspace ID to erase active content. The running database/session stays open. Backups, independent exports and physical disk remnants are outside this operation.
              </p><code>{@workspace_id}</code><.form
                for={%{}}
                id="purge-workspace-form"
                phx-submit="purge_workspace"
                class="stack"
              >
                <label for="purge-workspace-confirm">Complete workspace ID</label><input
                  id="purge-workspace-confirm"
                  name="privacy[confirmation]"
                  required
                /><button class="button secondary" type="submit">Erase active workspace content</button>
              </.form>
            </div>
            <pre :if={@privacy_result} id="privacy-result">{Jason.encode!(@privacy_result, pretty: true)}</pre>
          </section>
          <footer class="workspace-footer">
            <span><span class="footer-mark">H</span>
            HarnessForge <span class="muted">/</span>
            Context you can account for.</span><span>Open source · v0.1.0</span>
          </footer>
        </main>
      </div>
    </div>
    """
  end

  attr :tab, :string, required: true

  defp workspace_hero(assigns) do
    ~H"""
    <div class="page-heading">
      <div>
        <p class="eyebrow">HARNESS WORKBENCH</p><h1>{title(@tab)}</h1><p>
          {if @tab == "chat",
            do: "Current evidence, supporting citations, and optional AI answers.",
            else:
              "Scope → Sources → Review → Your harness → Checks. Review evidence and goals, then generate files you can inspect and download."}
        </p>
      </div><button
        :if={@tab != "chat"}
        id="load-demo"
        phx-click="demo"
        class="button secondary"
        phx-disable-with="Loading…"
      ><span aria-hidden="true">＋</span> Load synthetic demo</button>
    </div>
    """
  end

  defp current_release(release) do
    case HarnessForge.Releases.current(release["scope"]) do
      {:ok, %{"release_id" => id}} -> id
      _ -> ""
    end
  end

  defp github_credential_refs do
    Enum.filter(~w(GITHUB_PERSONAL_ACCESS_TOKEN GH_TOKEN), fn reference ->
      case System.get_env(reference) do
        value when is_binary(value) and byte_size(value) in 1..16_384 -> true
        _ -> false
      end
    end)
  end

  defp nav_symbol("connections"), do: "⌘"
  defp nav_symbol("company"), do: "▦"
  defp nav_symbol("chat"), do: "◇"
  defp nav_symbol("evidence"), do: "≋"
  defp nav_symbol("goals"), do: "◎"
  defp nav_symbol("package"), do: "⬡"
  defp nav_symbol("evaluations"), do: "◴"
  defp nav_symbol("releases"), do: "↗"
  defp nav_symbol("audit"), do: "↺"
  defp nav_symbol("privacy"), do: "◇"
end
