defmodule HarnessForgeWeb.CorpusReviewLive do
  @moduledoc "Authenticated company evidence capture, passage inspection and explicit synthesis review."
  use HarnessForgeWeb, :live_view

  alias HarnessForge.{Contracts, Evidence, Workspaces}
  alias HarnessForge.Company.CorpusReview
  alias HarnessForge.Evidence.{Corpora, RevisionUseHolds}
  alias HarnessForgeWeb.Company.CorpusReview, as: CorpusUI
  alias HarnessForgeWeb.Plugs.OperatorSession

  @kinds %{
    "connection" => :connections,
    "project" => :projects,
    "goal" => :goals,
    "recommendation" => :recommendations
  }
  @scope_keys ~w(connection_id project_id goal_id goal_content_hash)
  @restriction_events ~w(corpus_revision_block corpus_revision_retry corpus_revision_cleanup corpus_revision_status)
  @events ~w(corpus_scope_change corpus_scope_open corpus_choices_next corpus_search corpus_page_next corpus_page_previous corpus_passage_open corpus_passage_next corpus_passage_close corpus_recommendation_open corpus_continue_review corpus_refresh corpus_capture_start corpus_capture_status corpus_question_change corpus_retrieve corpus_run_passage corpus_run_passage_close corpus_run_next corpus_stage_prepare corpus_synthesize corpus_requirements_begin corpus_requirements_change corpus_requirements_next corpus_requirements_save corpus_requirements_refresh) ++
            @restriction_events

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket),
      do: Phoenix.PubSub.subscribe(HarnessForge.PubSub, "workspace:" <> Workspaces.current_id())

    {:ok,
     socket
     |> detach_hook(:authenticate_event, :handle_event)
     |> attach_hook(:authenticate_event, :handle_event, &authenticate/3)
     |> assign(:page_title, "Corpus evidence review")
     |> assign(:interactive, connected?(socket))
     |> assign(:workspace_id, Workspaces.current_id())
     |> assign(:reset_token, 0)
     |> reset()
     |> load_choices("connection")
     |> load_choices("project")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    if OperatorSession.valid?(socket.assigns.operator_auth) and
         socket.assigns.workspace_id == Workspaces.current_id() do
      case params do
        %{"restriction_event" => id} when map_size(params) == 1 ->
          {:noreply, restore_restriction(socket, id)}

        %{"restriction_event" => _} ->
          {:noreply, restriction_failure(socket, :invalid_input)}

        %{"declaration" => id, "declaration_digest" => digest} when map_size(params) == 2 ->
          {:noreply, restore_declaration(socket, id, digest)}

        refs when map_size(refs) == 0 ->
          {:noreply, clear_requirements(socket)}

        _ ->
          {:noreply,
           socket
           |> clear_requirements()
           |> large_assign(declaration_ref: %{"id" => nil, "digest" => nil})
           |> requirements_failure(:invalid_input)}
      end
    else
      {:noreply, socket |> reset() |> redirect(to: "/login")}
    end
  end

  @impl true
  def handle_event(event, attrs, socket) when event in @events do
    case envelope(attrs, socket.assigns.generation) do
      {:ok, payload} ->
        dispatch(event, payload, socket)

      :error when event in @restriction_events ->
        {:noreply, restriction_failure(socket, :stale_view)}

      :error ->
        {:noreply, failure(socket, :stale_view)}
    end
  end

  def handle_event(_, _, socket), do: {:noreply, failure(socket, :invalid_input)}

  @impl true
  def handle_info(event, socket) when event in [:company_cache_reset, :corpus_cache_reset] do
    event_id = get_in(socket.assigns.restriction, [:receipt, "event_id"])

    {:noreply,
     socket
     |> assign(:reset_token, socket.assigns.reset_token + 1)
     |> reset()
     |> then(fn cleared ->
       if event_id,
         do: restore_restriction(cleared, event_id),
         else: notice(cleared, "Evidence or privacy scope changed. Select current context again.")
     end)}
  end

  def handle_info(:operator_session_revoked, socket),
    do: {:noreply, socket |> reset() |> redirect(to: "/login")}

  def handle_info(_, socket), do: {:noreply, socket}

  defp authenticate(_event, _attrs, socket) do
    if OperatorSession.valid?(socket.assigns.operator_auth) and
         socket.assigns.workspace_id == Workspaces.current_id(),
       do: {:cont, socket |> revalidate_large() |> revalidate_visible_sources()},
       else: {:halt, socket |> reset() |> redirect(to: "/login")}
  end

  defp reset(socket) do
    choices = Map.new(Map.values(@kinds), &{&1, %{"rows" => [], "next_cursor" => nil}})

    assign(socket,
      generation: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
      scope_token: nil,
      restriction: %{receipt: nil, operation: nil, error: nil, event_id: nil},
      restriction_commands: %{},
      large: %{
        corpus: nil,
        capture: nil,
        run: nil,
        page: nil,
        passage: nil,
        stage: nil,
        claim: nil,
        analysis_observation: nil,
        declaration: nil,
        declaration_ref: nil,
        requirements_context: nil,
        requirements_draft: %{"optional_connection_id" => "", "capture_run_id" => ""},
        requirements_choices: %{"rows" => [], "next_cursor" => nil},
        question: "",
        mode: "fts",
        submitted_question: nil,
        busy: false,
        error: nil
      },
      readiness: HarnessForge.Company.ReadinessProjection.project(%{}),
      cursors: [nil],
      state: %{
        choices: choices,
        selected_choices: Map.new(Map.values(@kinds), &{&1, nil}),
        selection: Map.new(@scope_keys, &{&1, ""}),
        scope: nil,
        page: nil,
        query: "",
        passage: nil,
        recommendation: nil,
        previous?: false,
        error: nil,
        notice: nil
      }
    )
  end

  defp caller(socket) do
    auth = socket.assigns.operator_auth
    workspace = socket.assigns.workspace_id

    [
      authorize: fn ->
        workspace == Workspaces.current_id() and OperatorSession.valid?(auth)
      end,
      session_fingerprint: Contracts.digest(auth),
      view_generation: socket.assigns.generation,
      reset_token: socket.assigns.reset_token
    ]
  end

  defp envelope(attrs, generation) when is_map(attrs) do
    with ^generation <- attrs["corpus_generation"],
         true <- is_nil(attrs["_target"]) or is_list(attrs["_target"]),
         true <- byte_size(Jason.encode!(attrs)) <= 8_192 do
      {:ok, attrs |> Map.drop(~w(corpus_generation _target)) |> transport()}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp envelope(_, _), do: :error

  # Only browser-generated empty unused markers and the empty button value are metadata.
  defp transport(attrs) do
    attrs
    |> Enum.reject(fn {key, value} ->
      (String.starts_with?(key, "_unused_") and value == "") or
        (key == "value" and value == "")
    end)
    |> Map.new(fn {key, value} -> {key, if(is_map(value), do: transport(value), else: value)} end)
  end

  defp dispatch(event, %{"scope" => attrs} = payload, socket)
       when event in ~w(corpus_scope_change corpus_scope_open) and is_map(attrs) and
              map_size(payload) == 1 do
    if Enum.sort(Map.keys(attrs)) == Enum.sort(@scope_keys) and
         Enum.all?(Map.values(attrs), &(is_binary(&1) and byte_size(&1) <= 128)) do
      socket = select_scope(socket, attrs)
      {:noreply, if(event == "corpus_scope_open", do: open_scope(socket), else: socket)}
    else
      {:noreply, failure(socket, :invalid_input)}
    end
  end

  defp dispatch("corpus_choices_next", %{"kind" => kind} = attrs, socket)
       when is_map_key(@kinds, kind) and map_size(attrs) == 1 do
    cursor = get_in(socket.assigns.state, [:choices, @kinds[kind], "next_cursor"])
    {:noreply, if(cursor, do: load_choices(socket, kind, cursor), else: socket)}
  end

  defp dispatch("corpus_search", %{"search" => %{"query" => query} = search} = attrs, socket)
       when is_binary(query) and map_size(attrs) == 1 and map_size(search) == 1 do
    {:noreply,
     socket
     |> update_state(query: query, passage: nil)
     |> assign(:cursors, [nil])
     |> fetch_page(nil)}
  end

  defp dispatch(event, _attrs, %{assigns: %{large: %{requirements_read_only: true}}} = socket)
       when event in ~w(corpus_requirements_begin corpus_requirements_change corpus_requirements_next corpus_requirements_save) do
    {:noreply,
     socket
     |> large_assign(
       requirements_context: nil,
       error:
         "This saved declaration includes additional scopes and is read-only in this editor. All declared scopes remain included."
     )
     |> focus("company-corpus-error")}
  end

  defp dispatch("corpus_requirements_begin", attrs, socket) when map_size(attrs) == 0,
    do: {:noreply, requirements_context(socket)}

  defp dispatch(event, %{"requirements" => draft} = attrs, socket)
       when event in ~w(corpus_requirements_change corpus_requirements_save) and
              map_size(attrs) == 1 and is_map(draft) do
    case requirements_draft(socket, draft) do
      {:ok, edited} ->
        {:noreply,
         if(event == "corpus_requirements_save", do: save_requirements(edited), else: edited)}

      {:error, reason} ->
        {:noreply, requirements_failure(socket, reason)}
    end
  end

  defp dispatch("corpus_requirements_next", attrs, socket) when map_size(attrs) == 0 do
    cursor = socket.assigns.large.requirements_choices["next_cursor"]
    {:noreply, if(cursor, do: requirements_choices(socket, cursor), else: socket)}
  end

  defp dispatch("corpus_requirements_refresh", attrs, socket) when map_size(attrs) == 0 do
    case socket.assigns.large.declaration do
      %{"id" => id, "digest" => digest} -> {:noreply, restore_declaration(socket, id, digest)}
      _ -> {:noreply, requirements_failure(socket, :not_found)}
    end
  end

  defp dispatch("corpus_page_next", attrs, socket) when map_size(attrs) == 0 do
    next = get_in(socket.assigns.state, [:page, "next_cursor"])

    {:noreply,
     if(next,
       do: socket |> assign(:cursors, [next | socket.assigns.cursors]) |> fetch_page(next),
       else: socket
     )}
  end

  defp dispatch("corpus_page_previous", attrs, socket) when map_size(attrs) == 0 do
    case socket.assigns.cursors do
      [_, previous | rest] ->
        {:noreply, socket |> assign(:cursors, [previous | rest]) |> fetch_page(previous)}

      _ ->
        {:noreply, socket}
    end
  end

  defp dispatch("corpus_passage_open", attrs, socket),
    do: {:noreply, open_passage(socket, attrs)}

  defp dispatch("corpus_revision_block", %{"inspection" => inspection} = attrs, socket)
       when inspection in ~w(supplementary selected) and map_size(attrs) == 1 do
    passage =
      if inspection == "supplementary",
        do: socket.assigns.state.passage,
        else: socket.assigns.large.passage

    operation = socket.assigns.restriction_commands[inspection]

    if passage && operation &&
         revision_pin(passage) == Map.take(operation, ~w(source_id revision_id body_hash)),
       do: {:noreply, restrict_revision(socket, operation)},
       else: {:noreply, restriction_failure(socket, :stale_view)}
  end

  defp dispatch("corpus_revision_retry", attrs, socket) when map_size(attrs) == 0 do
    case socket.assigns.restriction.operation do
      operation when is_map(operation) -> {:noreply, restrict_revision(socket, operation)}
      _ -> {:noreply, restriction_failure(socket, :stale_view)}
    end
  end

  defp dispatch("corpus_revision_status", attrs, socket) when map_size(attrs) == 0 do
    case socket.assigns.restriction.event_id do
      id when is_binary(id) -> {:noreply, restore_restriction(socket, id)}
      _ -> {:noreply, restriction_failure(socket, :stale_view)}
    end
  end

  defp dispatch("corpus_revision_cleanup", attrs, socket) when map_size(attrs) == 0 do
    receipt = socket.assigns.restriction.receipt
    cleared = reset(socket)

    result =
      if receipt,
        do:
          Evidence.resume_revision_cleanup(
            receipt["event_id"],
            receipt["cleanup_version"],
            caller(cleared)
          ),
        else: {:error, :stale_view}

    response = restriction_result(cleared, result)

    response =
      if receipt && match?({:error, _}, result),
        do:
          assign(
            response,
            :restriction,
            Map.put(response.assigns.restriction, :event_id, receipt["event_id"])
          ),
        else: response

    {:noreply, response}
  end

  defp dispatch(event, _attrs, socket) when event in @restriction_events,
    do: {:noreply, restriction_failure(socket, :invalid_input)}

  defp dispatch("corpus_passage_next", attrs, socket) do
    passage = socket.assigns.state.passage

    if passage && passage["next_start_byte"] do
      expected = %{
        "source_id" => passage["source"]["id"],
        "revision_id" => passage["revision_id"],
        "body_hash" => passage["body_hash"],
        "start_byte" => passage["next_start_byte"]
      }

      case passage_input(attrs) do
        {:ok, ^expected} -> {:noreply, open_passage(socket, expected)}
        _ -> {:noreply, failure(socket, :stale_view)}
      end
    else
      {:noreply, socket}
    end
  end

  defp dispatch("corpus_passage_close", attrs, socket) when map_size(attrs) == 0,
    do: {:noreply, socket |> update_state(passage: nil) |> focus("corpus-results")}

  defp dispatch("corpus_recommendation_open", attrs, socket) do
    case CorpusReview.recommendation(socket.assigns.scope_token, attrs, caller(socket)) do
      {:ok, recommendation} ->
        {:noreply,
         socket
         |> update_state(recommendation: recommendation, error: nil, notice: nil)
         |> focus("corpus-original-report-title")}

      {:error, reason} ->
        {:noreply, failure(socket, reason)}
    end
  end

  defp dispatch(
         "corpus_continue_review",
         %{"claim_id" => id, "revision_hash" => hash} = attrs,
         socket
       )
       when map_size(attrs) == 2 do
    case socket.assigns.state.recommendation do
      %{"claim_id" => ^id, "revision_hash" => ^hash} ->
        case CorpusReview.recommendation(
               socket.assigns.scope_token,
               %{"claim_id" => id, "revision_hash" => hash},
               caller(socket)
             ) do
          {:ok, _} ->
            {:noreply,
             redirect(socket,
               to: "/?" <> URI.encode_query(%{"company_review" => id, "revision_hash" => hash})
             )}

          {:error, reason} ->
            {:noreply, failure(socket, reason)}
        end

      _ ->
        {:noreply, failure(socket, :invalid_input)}
    end
  end

  defp dispatch("corpus_refresh", attrs, socket) when map_size(attrs) == 0 do
    selection = socket.assigns.state.selection
    query = socket.assigns.state.query
    draft = Map.take(socket.assigns.large, [:question, :mode])

    {:noreply,
     socket
     |> assign(:reset_token, socket.assigns.reset_token + 1)
     |> reset()
     |> update_state(selection: selection, query: query)
     |> load_choices("connection")
     |> load_choices("project")
     |> load_choices("goal")
     |> open_scope()
     |> then(fn refreshed ->
       if refreshed.assigns.state.scope do
         refreshed
         |> large_assign(draft)
         |> notice(
           "Refreshed current captured evidence. Existing recommendations were not repinned or approved."
         )
       else
         refreshed
       end
     end)}
  end

  defp dispatch("corpus_capture_start", attrs, socket) when map_size(attrs) == 0 do
    selection = socket.assigns.state.selection

    result =
      with true <- not is_nil(socket.assigns.state.scope),
           {:ok, profile} when not is_nil(profile) <- HarnessForge.Company.get_profile(),
           {:ok, project} <-
             HarnessForge.Evidence.Store.get(
               HarnessForge.Company.Project,
               selection["project_id"]
             ),
           {:ok, corpus} <- selected_or_new_corpus(socket),
           {:ok, _} <-
             HarnessForge.Company.bind_corpus(
               project.id,
               corpus["id"],
               profile["content_hash"],
               project.content_hash,
               caller(socket)
             ),
           {:ok, capture} <-
             HarnessForge.Evidence.Capture.start_capture(
               corpus["id"],
               selection["connection_id"],
               corpus["semantic_generation"],
               caller(socket)
             ) do
        {:ok, corpus, capture}
      end

    case result do
      {:ok, c, capture} ->
        {:noreply,
         large_assign(socket,
           corpus: c,
           capture: capture,
           error: nil,
           run: nil,
           page: nil,
           passage: nil,
           stage: nil,
           claim: nil,
           analysis_observation: nil,
           declaration: nil,
           declaration_ref: nil,
           requirements_context: nil,
           requirements_draft: %{"optional_connection_id" => "", "capture_run_id" => ""},
           requirements_choices: %{"rows" => [], "next_cursor" => nil}
         )}

      {:error, reason} ->
        {:noreply, large_failure(socket, reason)}

      _ ->
        {:noreply, large_failure(socket, :invalid_scope)}
    end
  end

  defp dispatch("corpus_capture_status", attrs, socket) when map_size(attrs) == 0 do
    capture = socket.assigns.large.capture

    result =
      if capture,
        do: HarnessForge.Evidence.Capture.capture_status(capture["run_id"], %{}, caller(socket)),
        else: {:error, :not_found}

    case result do
      {:ok, status} ->
        {:noreply, socket |> load_large_corpus() |> large_assign(capture: status, error: nil)}

      {:error, reason} ->
        {:noreply, large_failure(socket, reason)}
    end
  end

  defp dispatch(event, %{"retrieval" => draft} = attrs, socket)
       when event in ~w(corpus_question_change corpus_retrieve) and is_map(draft) and
              map_size(attrs) == 1 do
    socket =
      if event == "corpus_retrieve" && !socket.assigns.large.busy,
        do: clear_run(socket),
        else: socket

    cond do
      is_nil(socket.assigns.state.scope) ->
        {:noreply, failure(socket, :invalid_scope)}

      socket.assigns.large.busy ->
        {:noreply, large_failure(socket, :queue_full)}

      valid_draft?(draft) ->
        socket =
          if draft["question"] != socket.assigns.large.question or
               draft["mode"] != socket.assigns.large.mode,
             do: clear_run(socket),
             else: socket

        socket = large_assign(socket, question: draft["question"], mode: draft["mode"])
        if event == "corpus_retrieve", do: retrieve(socket), else: {:noreply, socket}

      true ->
        {:noreply, large_failure(socket, :invalid_question)}
    end
  end

  defp dispatch("corpus_run_next", attrs, socket) when map_size(attrs) == 0 do
    page = socket.assigns.large.page

    {:noreply,
     if(page && page["next_cursor"],
       do: load_large_run(socket, page["next_cursor"]),
       else: socket
     )}
  end

  defp dispatch("corpus_run_passage", %{"passage_id" => id} = attrs, socket)
       when map_size(attrs) == 1 do
    run = socket.assigns.large.run

    open =
      if evidence_bundle_run?(run),
        do: &HarnessForge.Company.Retrieval.open_evidence_passage/4,
        else: &HarnessForge.Company.Retrieval.open_passage/4

    result =
      if run,
        do:
          open.(
            run["run_id"],
            run["digest"],
            id,
            caller(socket)
          ),
        else: {:error, :not_found}

    case result do
      {:ok, p} ->
        {:noreply,
         socket
         |> large_assign(passage: p, error: nil)
         |> remember_revision("selected", p)
         |> focus("company-corpus-exact-passage")}

      {:error, reason} ->
        {:noreply, socket |> large_assign(passage: nil) |> large_failure(reason)}
    end
  end

  defp dispatch("corpus_run_passage_close", attrs, socket) when map_size(attrs) == 0,
    do: {:noreply, socket |> large_assign(passage: nil) |> focus("company-corpus-results")}

  defp dispatch("corpus_stage_prepare", attrs, socket) when map_size(attrs) == 0 do
    run = socket.assigns.large.run

    result =
      if run,
        do:
          HarnessForge.Models.StageAuthority.prepare_synthesis(
            run["run_id"],
            run["digest"],
            caller(socket)
          ),
        else: {:error, :not_found}

    case result do
      {:ok, stage} ->
        {:noreply,
         socket
         |> large_assign(stage: stage, error: nil)
         |> focus("company-corpus-synthesis-title")}

      {:error, reason} ->
        {:noreply, socket |> large_assign(stage: nil) |> large_failure(reason)}
    end
  end

  defp dispatch("corpus_synthesize", attrs, socket) when map_size(attrs) == 0 do
    stage = socket.assigns.large.stage
    run = socket.assigns.large.run
    options = caller(socket)

    if stage && run && !socket.assigns.large.busy do
      result =
        HarnessForge.Models.StageAuthority.grant_consent(
          stage["stage_id"],
          stage["manifest_id"],
          stage["manifest_digest"],
          options
        )

      case result do
        {:ok, _} ->
          analysis_id = Ecto.UUID.generate()
          request_id = Ecto.UUID.generate()

          {:noreply,
           socket
           |> large_assign(
             busy: true,
             error: nil,
             claim: nil,
             analysis_observation: %{
               "status" => "running",
               "analysis_id" => analysis_id,
               "request_id" => request_id,
               "run_id" => run["run_id"],
               "run_digest" => run["digest"]
             }
           )
           |> start_async({:corpus_synthesis, socket.assigns.generation, analysis_id}, fn ->
             HarnessForge.Company.Analysis.analyze_retrieval(run["run_id"], run["digest"],
               caller: options,
               stage_id: stage["stage_id"],
               run_id: analysis_id,
               request_id: request_id
             )
           end)}

        {:error, reason} ->
          {:noreply, socket |> large_assign(stage: nil) |> large_failure(reason)}
      end
    else
      {:noreply, large_failure(socket, :stage_review_required)}
    end
  end

  defp dispatch(_, _, socket), do: {:noreply, failure(socket, :invalid_input)}

  defp retrieve(socket) do
    c = socket.assigns.large.corpus
    selection = socket.assigns.state.selection

    cond do
      socket.assigns.large.busy ->
        {:noreply, large_failure(socket, :queue_full)}

      String.trim(socket.assigns.large.question) == "" ->
        {:noreply, large_failure(socket, :invalid_question)}

      c ->
        input = %{
          "corpus_id" => c["id"],
          "project_id" => selection["project_id"],
          "goal_id" => selection["goal_id"],
          "goal_hash" => selection["goal_content_hash"],
          "expected_generation" => c["semantic_generation"],
          "question" => socket.assigns.large.question,
          "mode" => socket.assigns.large.mode
        }

        input =
          if socket.assigns.large.declaration_ref,
            do: Map.put(input, "declaration_ref", socket.assigns.large.declaration_ref),
            else: input

        options = caller(socket)

        retrieve =
          if input["mode"] == "fts",
            do: &HarnessForge.Company.Retrieval.retrieve_evidence/2,
            else: &HarnessForge.Company.Retrieval.retrieve/2

        {:noreply,
         socket
         |> large_assign(
           busy: true,
           submitted_question: socket.assigns.large.question,
           error: nil
         )
         |> start_async({:corpus_retrieval, socket.assigns.generation}, fn ->
           retrieve.(input, options)
         end)}

      true ->
        {:noreply, large_failure(socket, :capture_required)}
    end
  end

  defp clear_requirements(socket),
    do:
      large_assign(socket,
        declaration: nil,
        declaration_ref: nil,
        requirements_context: nil,
        requirements_draft: %{"optional_connection_id" => "", "capture_run_id" => ""},
        requirements_choices: %{"rows" => [], "next_cursor" => nil}
      )

  defp requirements_context(socket) do
    c = socket.assigns.large.corpus
    s = socket.assigns.state.selection

    if c && socket.assigns.state.scope && !socket.assigns.large.busy do
      case Corpora.requirements_context(
             c["id"],
             s["project_id"],
             s["goal_id"],
             s["goal_content_hash"],
             caller(socket)
           ) do
        {:ok, context} ->
          large_assign(socket,
            requirements_context: context,
            error: nil,
            requirements_draft: %{"optional_connection_id" => "", "capture_run_id" => ""},
            requirements_choices: %{"rows" => [], "next_cursor" => nil}
          )

        {:error, reason} ->
          requirements_failure(socket, reason)
      end
    else
      requirements_failure(socket, :capture_required)
    end
  end

  defp requirements_draft(socket, draft) do
    old = socket.assigns.large.requirements_draft
    choices = socket.assigns.large.requirements_choices
    connection = draft["optional_connection_id"]
    capture = draft["capture_run_id"]
    rows = socket.assigns.state.choices.connections["rows"]
    selected = Enum.find(rows, &(&1["id"] == connection)) || choices["connection"]
    receipt = Enum.find(choices["rows"], &(&1["id"] == capture)) || choices["selected"]

    cond do
      socket.assigns.large.busy || is_nil(socket.assigns.large.requirements_context) ->
        {:error, :stale_view}

      Enum.sort(Map.keys(draft)) != ~w(capture_run_id optional_connection_id) ->
        {:error, :invalid_input}

      !Enum.all?(Map.values(draft), &(is_binary(&1) and byte_size(&1) <= 128)) ->
        {:error, :invalid_input}

      connection == socket.assigns.state.selection["connection_id"] ->
        {:error, :invalid_input}

      connection != "" && (!selected || selected["id"] != connection) ->
        {:error, :invalid_input}

      connection != old["optional_connection_id"] ->
        updated =
          large_assign(socket,
            requirements_draft: %{draft | "capture_run_id" => ""},
            requirements_choices: %{"rows" => [], "next_cursor" => nil, "connection" => selected}
          )

        {:ok, if(connection == "", do: updated, else: requirements_choices(updated, nil))}

      capture != "" && (!receipt || receipt["id"] != capture) ->
        {:error, :invalid_input}

      true ->
        {:ok,
         large_assign(socket,
           requirements_draft: draft,
           requirements_choices: Map.put(choices, "selected", if(capture != "", do: receipt))
         )}
    end
  end

  defp requirements_choices(socket, cursor) do
    c = socket.assigns.large.corpus
    connection = socket.assigns.large.requirements_draft["optional_connection_id"]

    if c && connection != "" && !socket.assigns.large.busy do
      case Corpora.requirement_capture_choices(
             c["id"],
             connection,
             %{"cursor" => cursor},
             caller(socket)
           ) do
        {:ok, page} ->
          retained = Map.take(socket.assigns.large.requirements_choices, ~w(connection selected))
          large_assign(socket, requirements_choices: Map.merge(page, retained))

        {:error, reason} ->
          requirements_failure(socket, reason)
      end
    else
      requirements_failure(socket, :invalid_input)
    end
  end

  defp save_requirements(socket) do
    l = socket.assigns.large
    draft = l.requirements_draft
    selected = l.requirements_choices["selected"]
    s = socket.assigns.state.selection

    if l.capture && l.requirements_context && !l.busy &&
         (draft["optional_connection_id"] == "" || selected) do
      primary = %{
        "connection_id" => s["connection_id"],
        "requirement" => "required",
        "capture_run_id" => l.capture["run_id"],
        "capture_revision" => l.capture["revision"]
      }

      entries =
        if draft["optional_connection_id"] == "",
          do: [primary],
          else: [
            primary,
            %{
              "connection_id" => draft["optional_connection_id"],
              "requirement" => "optional",
              "capture_run_id" => selected["id"],
              "capture_revision" => selected["revision"]
            }
          ]

      attrs = %{
        "project_id" => s["project_id"],
        "goal_id" => s["goal_id"],
        "primary_connection_id" => s["connection_id"],
        "entries" => entries
      }

      case Corpora.declare_requirements(
             l.corpus["id"],
             l.requirements_context["expected"],
             attrs,
             caller(socket)
           ) do
        {:ok, saved} ->
          push_patch(socket,
            to:
              "/company/corpus?" <>
                URI.encode_query(%{
                  "declaration" => saved["id"],
                  "declaration_digest" => saved["digest"]
                })
          )

        {:error, reason} ->
          requirements_failure(socket, reason)
      end
    else
      requirements_failure(socket, :capture_required)
    end
  end

  defp restore_declaration(socket, id, digest) do
    bounded? =
      is_binary(id) && byte_size(id) <= 128 && is_binary(digest) && byte_size(digest) <= 128

    ref =
      if bounded?, do: %{"id" => id, "digest" => digest}, else: %{"id" => nil, "digest" => nil}

    socket = socket |> clear_requirements() |> large_assign(declaration_ref: ref)

    with true <- bounded? && !socket.assigns.large.busy,
         {:ok, summary} <- Corpora.requirements_summary(id, digest, caller(socket)),
         %{} = selection <- summary["selection"],
         %{} = display <- summary["selection_display"] do
      selected =
        Map.new(
          [{"connection", :connections}, {"project", :projects}, {"goal", :goals}],
          fn {kind, key} ->
            row = display[kind]
            {key, Map.put(row, "title", row["title"] || row["name"])}
          end
        )

      socket =
        socket
        |> select_scope(selection)
        |> update_state(
          selection: selection,
          selected_choices: Map.merge(socket.assigns.state.selected_choices, selected)
        )
        |> large_assign(declaration_ref: ref)
        |> load_choices("goal")
        |> open_scope()

      if socket.assigns.state.scope do
        capture =
          Enum.find(
            summary["entries"],
            &(&1["connection_id"] == summary["primary_connection_id"])
          )

        capture =
          if capture,
            do: %{
              "run_id" => capture["capture_run_id"],
              "revision" => capture["capture_revision"]
            }

        socket
        |> large_assign(declaration: summary, declaration_ref: ref, capture: nil)
        |> then(fn s ->
          if s.assigns.large[:requirements_read_only], do: s, else: requirements_context(s)
        end)
        |> large_assign(declaration: summary, declaration_ref: ref)
        |> then(fn s -> if capture, do: restore_primary_capture(s, capture), else: s end)
        |> restore_requirements_draft(summary)
        |> focus("corpus-requirements-saved")
      else
        requirements_failure(socket, :stale_scope)
      end
    else
      _ -> requirements_failure(socket, :stale_scope)
    end
  end

  defp restore_primary_capture(socket, ref) do
    case HarnessForge.Evidence.Capture.capture_status(ref["run_id"], %{}, caller(socket)) do
      {:ok, capture} ->
        if capture["revision"] == ref["revision"],
          do: large_assign(socket, capture: capture),
          else: socket

      _ ->
        socket
    end
  end

  defp restore_requirements_draft(socket, summary) do
    case Enum.find(summary["entries"], &(&1["requirement"] == "optional")) do
      nil ->
        socket

      entry ->
        receipt =
          if entry["capture_run_id"],
            do: %{
              "id" => entry["capture_run_id"],
              "revision" => entry["capture_revision"],
              "state" => entry["capture_state"]
            }

        socket
        |> large_assign(
          requirements_draft: %{
            "optional_connection_id" => entry["connection_id"],
            "capture_run_id" => entry["capture_run_id"] || ""
          },
          requirements_choices: %{
            "rows" => [],
            "next_cursor" => nil,
            "selected" => receipt,
            "connection" => %{"id" => entry["connection_id"], "title" => entry["name"]}
          }
        )
        |> requirements_choices(nil)
    end
  end

  defp requirements_failure(socket, reason) do
    message =
      case reason do
        :capture_required ->
          "Capture the selected primary directory and choose an existing optional capture, if declared, before saving coverage."

        reason
        when reason in [
               :stale_revision,
               :stale_generation,
               :stale_scope,
               :stale_view,
               :stale_declaration,
               :stale_receipt
             ] ->
          "Coverage context changed or is unavailable. Load current coverage choices before saving again."

        _ ->
          "Coverage could not be saved or verified. Select current context and recorded captures again."
      end

    ref = socket.assigns.large[:declaration_ref]

    socket
    |> clear_requirements()
    |> large_assign(error: message, declaration_ref: ref)
    |> then(fn s ->
      if s.assigns.state.scope,
        do: focus(s, "company-corpus-error"),
        else: s |> update_state(error: message) |> focus("corpus-error")
    end)
  end

  defp large_assign(socket, attrs) do
    socket
    |> assign(:large, Map.merge(socket.assigns.large, Map.new(attrs)))
    |> refresh_readiness()
  end

  defp refresh_readiness(socket) do
    large = socket.assigns.large

    large =
      case large[:declaration] do
        %{"id" => id, "digest" => digest} ->
          case Corpora.requirements_summary(id, digest, caller(socket)) do
            {:ok, checked} ->
              Map.put(large, :declaration, checked)

            _ ->
              Map.merge(large, %{
                declaration: nil,
                requirements_context: nil,
                requirements_draft: %{"optional_connection_id" => "", "capture_run_id" => ""},
                requirements_choices: %{"rows" => [], "next_cursor" => nil}
              })
          end

        _ ->
          large
      end

    socket =
      assign(
        socket,
        :large,
        Map.put(large, :requirements_read_only, !requirements_editable?(large[:declaration]))
      )

    assign(
      socket,
      :readiness,
      HarnessForge.Company.Readiness.for_corpus(
        socket.assigns.state.selection,
        socket.assigns.large,
        caller(socket)
      )
    )
  end

  defp requirements_editable?(nil), do: true

  defp requirements_editable?(%{"entries" => entries, "primary_connection_id" => primary}) do
    Enum.count(entries, &(&1["requirement"] == "required" and &1["connection_id"] == primary)) ==
      1 and
      Enum.all?(entries, &(&1["connection_id"] == primary or &1["requirement"] == "optional")) and
      Enum.count(entries, &(&1["requirement"] == "optional")) <= 1
  end

  defp valid_draft?(draft),
    do:
      Enum.sort(Map.keys(draft)) == ~w(mode question) and is_binary(draft["question"]) and
        String.valid?(draft["question"]) and byte_size(draft["question"]) <= 1024 and
        String.length(draft["question"]) <= 256 and draft["mode"] in ~w(fts graphiti_hybrid)

  defp clear_run(socket),
    do:
      large_assign(socket,
        run: nil,
        page: nil,
        passage: nil,
        stage: nil,
        claim: nil,
        analysis_observation: nil,
        submitted_question: nil
      )

  defp revalidate_large(socket) do
    corpus = socket.assigns.large.corpus
    run = socket.assigns.large.run

    stale_corpus =
      corpus &&
        HarnessForge.Evidence.Corpora.assert_current(
          corpus["id"],
          corpus["semantic_generation"],
          corpus["authorization_generation"]
        ) != :ok

    stale_run =
      run && HarnessForge.Company.Retrieval.validate_current(run["run_id"], run["digest"]) != :ok

    if stale_corpus || stale_run do
      large_assign(socket,
        run: nil,
        page: nil,
        passage: nil,
        stage: nil,
        claim: nil,
        analysis_observation: nil,
        declaration: nil,
        declaration_ref: socket.assigns.large[:declaration_ref],
        requirements_context: nil,
        requirements_draft: %{"optional_connection_id" => "", "capture_run_id" => ""},
        requirements_choices: %{"rows" => [], "next_cursor" => nil},
        busy: false,
        question: "",
        mode: "fts",
        submitted_question: nil,
        error: "Evidence or permissions changed. Retrieve current evidence before continuing."
      )
    else
      socket
    end
  end

  defp load_large_corpus(socket) do
    socket = revalidate_large(socket)

    case HarnessForge.Company.bound_corpus(socket.assigns.state.selection["project_id"]) do
      {:ok, c} -> large_assign(socket, corpus: c)
      _ -> large_assign(socket, corpus: nil)
    end
  end

  defp selected_or_new_corpus(socket) do
    case HarnessForge.Company.bound_corpus(socket.assigns.state.selection["project_id"]) do
      {:ok, nil} ->
        HarnessForge.Evidence.Corpora.create(
          %{"name" => "Company evidence corpus"},
          caller(socket)
        )

      {:ok, c} ->
        {:ok, c}

      e ->
        e
    end
  end

  defp load_large_run(socket, cursor) do
    run = socket.assigns.large.run

    read =
      if evidence_bundle_run?(run),
        do: &HarnessForge.Company.Retrieval.read_evidence/4,
        else: &HarnessForge.Company.Retrieval.read_run/4

    case read.(
           run["run_id"],
           run["digest"],
           %{"cursor" => cursor},
           caller(socket)
         ) do
      {:ok, page} ->
        socket
        |> large_assign(page: page, passage: nil, error: nil)
        |> focus("company-corpus-results")

      {:error, reason} ->
        socket |> clear_run() |> large_failure(reason)
    end
  end

  defp evidence_bundle_run?(%{"evidence_bundle" => %{"version" => "EvidenceBundle.v1"}}), do: true
  defp evidence_bundle_run?(_), do: false

  @impl true
  def handle_async({kind, generation}, {:ok, result}, socket)
      when kind == :corpus_retrieval do
    if async_current?(socket, generation) do
      socket = socket |> revalidate_large() |> large_assign(busy: false)

      case {kind, result} do
        {:corpus_retrieval, {:ok, run}} ->
          {:noreply,
           socket |> large_assign(run: run, passage: nil, stage: nil) |> load_large_run(nil)}

        {_, {:error, reason}} ->
          {:noreply, socket |> large_assign(stage: nil) |> large_failure(reason)}

        _ ->
          {:noreply, socket |> large_assign(stage: nil) |> large_failure(:unknown)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_async({kind, generation}, {:exit, _}, socket)
      when kind == :corpus_retrieval do
    if async_current?(socket, generation),
      do:
        {:noreply,
         socket |> large_assign(busy: false, stage: nil) |> large_failure(:operation_stopped)},
      else: {:noreply, socket}
  end

  # Previous synthesis names carried no operation identity. They cannot bind a
  # result to a selected request and are safely ignored, including late exits.
  def handle_async({:corpus_synthesis, _generation}, _outcome, socket),
    do: {:noreply, socket}

  def handle_async({:corpus_synthesis, generation, analysis_id}, outcome, socket) do
    if async_current?(socket, generation) do
      socket = revalidate_large(socket)
      observation = socket.assigns.large.analysis_observation
      run = socket.assigns.large.run

      if is_map(observation) and is_map(run) and observation["analysis_id"] == analysis_id and
           observation["run_id"] == run["run_id"] and observation["run_digest"] == run["digest"] do
        finish_synthesis(socket, observation, outcome)
      else
        # Revalidation can clear a run without changing the view generation.
        # Such a late result cannot repopulate its claim or observed outcome.
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  defp finish_synthesis(
         socket,
         observation,
         {:ok, {:ok, %{"status" => "proposed", "claim" => claim}}}
       ) do
    with true <- get_in(claim, ["basis", "run_id"]) == observation["analysis_id"],
         true <- get_in(claim, ["basis", "request_id"]) == observation["request_id"],
         {:ok, _} <- HarnessForge.Evidence.validate_claim(claim) do
      observation =
        Map.merge(observation, %{
          "status" => "proposed",
          "claim_id" => claim["id"],
          "claim_revision_hash" => claim["revision_hash"]
        })

      {:noreply,
       socket
       |> large_assign(
         busy: false,
         claim: claim,
         stage: nil,
         error: nil,
         analysis_observation: observation
       )
       |> focus("company-corpus-proposal")}
    else
      _ ->
        {:noreply,
         socket |> clear_run() |> large_assign(busy: false) |> large_failure(:stale_scope)}
    end
  end

  defp finish_synthesis(socket, observation, {:ok, {:ok, %{"status" => "abstained"}}}),
    do:
      {:noreply,
       socket
       |> large_assign(
         busy: false,
         stage: nil,
         analysis_observation: Map.put(observation, "status", "abstained")
       )
       |> large_failure(:model_abstained)}

  defp finish_synthesis(socket, observation, {:ok, {:error, reason}}),
    do:
      {:noreply,
       socket
       |> large_assign(
         busy: false,
         stage: nil,
         analysis_observation: Map.put(observation, "status", "failed")
       )
       |> large_failure(reason)}

  defp finish_synthesis(socket, observation, _),
    do:
      {:noreply,
       socket
       |> large_assign(
         busy: false,
         stage: nil,
         analysis_observation: Map.put(observation, "status", "unknown")
       )
       |> large_failure(:operation_stopped)}

  defp async_current?(socket, generation),
    do:
      generation == socket.assigns.generation and
        socket.assigns.workspace_id == Workspaces.current_id() and
        OperatorSession.valid?(socket.assigns.operator_auth)

  defp select_scope(socket, attrs) do
    previous = socket.assigns.state.selection
    project_changed = attrs["project_id"] != previous["project_id"]

    attrs =
      if project_changed,
        do: Map.merge(attrs, %{"goal_id" => "", "goal_content_hash" => ""}),
        else: attrs

    choices = socket.assigns.state.choices

    selected =
      Enum.reduce(@kinds, socket.assigns.state.selected_choices, fn {kind, key}, acc ->
        id = attrs[kind <> "_id"]
        current = Enum.find(choices[key]["rows"], &(&1["id"] == id))
        prior = acc[key]
        Map.put(acc, key, current || if(prior && prior["id"] == id, do: prior))
      end)

    goal = selected.goals
    attrs = if goal, do: Map.put(attrs, "goal_content_hash", goal["content_hash"]), else: attrs

    if attrs == previous do
      socket
    else
      socket
      |> assign(:generation, Base.encode16(:crypto.strong_rand_bytes(16), case: :lower))
      |> assign(
        scope_token: nil,
        restriction_commands: %{},
        cursors: [nil],
        large: %{
          corpus: nil,
          capture: nil,
          run: nil,
          page: nil,
          passage: nil,
          stage: nil,
          claim: nil,
          analysis_observation: nil,
          declaration: nil,
          declaration_ref: nil,
          requirements_context: nil,
          requirements_draft: %{"optional_connection_id" => "", "capture_run_id" => ""},
          requirements_choices: %{"rows" => [], "next_cursor" => nil},
          question: "",
          mode: "fts",
          submitted_question: nil,
          busy: false,
          error: nil
        }
      )
      |> assign(:readiness, HarnessForge.Company.ReadinessProjection.project(%{}))
      |> update_state(
        selection: attrs,
        selected_choices: selected,
        scope: nil,
        page: nil,
        passage: nil,
        recommendation: nil,
        previous?: false,
        error: nil
      )
      |> then(fn socket -> if project_changed, do: load_choices(socket, "goal"), else: socket end)
    end
  end

  defp open_scope(socket) do
    case CorpusReview.open_scope(socket.assigns.state.selection, caller(socket)) do
      {:ok, %{"token" => token, "scope" => scope}} ->
        socket
        |> assign(:scope_token, token)
        |> update_state(scope: scope, error: nil, notice: nil)
        |> load_choices("recommendation")
        |> fetch_page(nil, "company-corpus-pipeline-title")
        |> load_large_corpus()

      {:error, reason} ->
        socket
        |> assign(:scope_token, nil)
        |> update_state(scope: nil)
        |> clear_run()
        |> failure(reason)
    end
  end

  defp load_choices(socket, kind, cursor \\ nil) do
    selection = socket.assigns.state.selection

    attrs = %{
      "kind" => kind,
      "project_id" => selection["project_id"],
      "goal_id" => selection["goal_id"],
      "cursor" => cursor
    }

    case CorpusReview.choices(attrs, caller(socket)) do
      {:ok, page} ->
        choices = Map.put(socket.assigns.state.choices, @kinds[kind], page)
        update_state(socket, choices: choices)

      {:error, reason} ->
        failure(socket, reason)
    end
  end

  defp fetch_page(socket, cursor, focus_target \\ "corpus-results") do
    case CorpusReview.page(
           socket.assigns.scope_token,
           %{"query" => socket.assigns.state.query, "cursor" => cursor},
           caller(socket)
         ) do
      {:ok, page} ->
        socket
        |> update_state(
          scope: page["scope"],
          page: page,
          passage: nil,
          error: nil,
          previous?: length(socket.assigns.cursors) > 1
        )
        |> focus(focus_target)

      {:error, reason} ->
        failure(socket, reason)
    end
  end

  defp open_passage(socket, attrs) do
    with {:ok, attrs} <- passage_input(attrs),
         {:ok, passage} <- CorpusReview.passage(socket.assigns.scope_token, attrs, caller(socket)) do
      socket
      |> update_state(passage: passage, error: nil, notice: nil)
      |> remember_revision("supplementary", passage)
      |> focus("corpus-passage")
    else
      {:error, reason} -> failure(socket, reason)
    end
  end

  defp passage_input(attrs) when is_map(attrs) do
    case attrs["start_byte"] do
      value when is_integer(value) and value >= 0 ->
        {:ok, attrs}

      value when is_binary(value) ->
        case Integer.parse(value) do
          {integer, ""} when integer >= 0 -> {:ok, Map.put(attrs, "start_byte", integer)}
          _ -> {:error, :invalid_input}
        end

      _ ->
        {:error, :invalid_input}
    end
  end

  defp revision_pin(passage) do
    %{
      "source_id" => passage["source_id"] || get_in(passage, ["source", "id"]),
      "revision_id" => passage["revision_id"] || get_in(passage, ["latest_revision", "id"]),
      "body_hash" => passage["body_hash"] || get_in(passage, ["latest_revision", "body_hash"])
    }
  end

  defp remember_revision(socket, inspection, passage) do
    pin = revision_pin(passage)
    previous = socket.assigns.restriction_commands[inspection]

    command =
      if previous && Map.take(previous, Map.keys(pin)) == pin do
        previous
      else
        Map.merge(pin, %{
          "version" => 1,
          "expected_generation" => 0,
          "command_id" => Ecto.UUID.generate(),
          "reason_code" => "operator_restriction"
        })
      end

    assign(
      socket,
      :restriction_commands,
      Map.put(socket.assigns.restriction_commands, inspection, command)
    )
  end

  defp restrict_revision(socket, operation) do
    cleared = reset(socket)
    result = Evidence.restrict_revision(operation, caller(cleared))
    restriction_result(cleared, result, operation)
  end

  defp restore_restriction(socket, event_id) do
    cleared = reset(socket)

    case Evidence.revision_restriction_status(event_id, caller(cleared)) do
      {:ok, receipt} -> show_restriction(cleared, receipt)
      {:error, reason} -> restriction_failure(cleared, reason)
    end
  end

  defp restriction_result(socket, result, operation \\ nil)

  defp restriction_result(socket, {:ok, receipt}, _operation) do
    socket
    |> show_restriction(receipt)
    |> push_patch(
      to: "/company/corpus?" <> URI.encode_query(%{"restriction_event" => receipt["event_id"]})
    )
  end

  defp restriction_result(socket, {:error, reason}, operation),
    do: restriction_failure(socket, reason, operation)

  defp show_restriction(socket, receipt) do
    socket
    |> assign(:restriction, %{
      receipt: receipt,
      operation: nil,
      error: nil,
      event_id: receipt["event_id"]
    })
    |> focus("corpus-restriction-receipt")
  end

  defp restriction_failure(socket, reason, operation \\ nil) do
    socket
    |> reset()
    |> assign(:restriction, %{
      receipt: nil,
      operation: operation,
      error: restriction_error(reason),
      event_id: nil
    })
    |> focus("corpus-restriction-error")
  end

  defp restriction_error(reason) when reason in [:stale_view, :invalid_input],
    do:
      "This action is no longer current. The evidence view was cleared. Inspect the exact revision again before blocking use."

  defp restriction_error(:not_found),
    do:
      "This restriction receipt is unavailable in the current workspace. The evidence view was cleared."

  defp restriction_error(_),
    do:
      "The restriction status could not be confirmed. The evidence view was cleared; do not assume access or cleanup."

  defp revalidate_visible_sources(socket) do
    pins =
      Enum.map((socket.assigns.state.page && socket.assigns.state.page["rows"]) || [], fn row ->
        %{
          "source_id" => row["id"],
          "revision_id" => get_in(row, ["latest_revision", "id"]),
          "body_hash" => get_in(row, ["latest_revision", "body_hash"])
        }
      end) ++
        Enum.map(
          (socket.assigns.large.page && socket.assigns.large.page["rows"]) || [],
          &revision_pin/1
        ) ++
        Enum.map(
          List.wrap(socket.assigns.state.passage) ++ List.wrap(socket.assigns.large.passage),
          &revision_pin/1
        ) ++
        Enum.map(
          get_in(socket.assigns.state.recommendation || %{}, ["analyzed_sources"]) || [],
          fn row ->
            %{
              "source_id" => row["source_id"] || row["id"],
              "revision_id" => row["revision_id"] || get_in(row, ["latest_revision", "id"]),
              "body_hash" => row["body_hash"] || get_in(row, ["latest_revision", "body_hash"])
            }
          end
        )

    if pins == [] do
      socket
    else
      ids = Enum.map(pins, & &1["source_id"]) |> Enum.uniq()

      if Enum.all?(ids, &(RevisionUseHolds.assert_source_unheld(&1) == :ok)),
        do: socket,
        else: restriction_failure(socket, :revision_use_state_unavailable)
    end
  end

  defp failure(socket, reason) do
    socket
    |> update_state(passage: nil, recommendation: nil, error: error_message(reason), notice: nil)
    |> focus("corpus-error")
  end

  defp notice(socket, message), do: update_state(socket, notice: message)

  defp update_state(socket, attrs),
    do: assign(socket, :state, Map.merge(socket.assigns.state, Map.new(attrs)))

  defp focus(socket, id), do: push_event(socket, "company-focus", %{id: id})

  defp large_failure(socket, reason),
    do: socket |> large_assign(error: operation_error(reason)) |> focus("company-corpus-error")

  defp operation_error(:invalid_question),
    do:
      "Use at most 256 characters and 1,024 UTF-8 bytes, and choose keyword or graph search. The previous bounded draft is retained."

  defp operation_error(:capture_required),
    do: "Capture the selected local directory before asking a question."

  defp operation_error(:queue_full),
    do:
      "The operation queue is busy, possibly with a paused capture. Refresh status and try explicitly when it is available."

  defp operation_error(reason) when reason in [:unsafe_directory, :connection_unavailable],
    do:
      "Directory capture requires an active local connection with an approved directory. Check Connections or inspect the existing remote captures."

  defp operation_error(:graph_unavailable),
    do:
      "Graph search is unavailable. Refresh or reselect current scope; you can explicitly choose Keyword passages. This request did not change the search mode."

  defp operation_error(:closure_incomplete),
    do:
      "The evidence closure could not be verified. Refresh or reselect current scope before reviewing synthesis. Graph search requires a qualified graph; keyword search remains an explicit choice."

  defp operation_error(:capture_incomplete),
    do:
      "Capture, indexing or selected context is incomplete. Refresh capture and index status and inspect the evidence before retrieving again."

  defp operation_error(reason)
       when reason in [
              :stage_unavailable,
              :model_not_selected,
              :model_unavailable,
              :model_service_unavailable
            ],
       do:
         "The model stage is unavailable. Check the configured, versioned model in Connections, then review synthesis scope again."

  defp operation_error(:stage_review_required),
    do: "Review the model and exact passage scope before allowing synthesis."

  defp operation_error(:consent_required),
    do:
      "Consent is required for this exact model and evidence scope. Review synthesis scope again; no consent or approval was granted automatically."

  defp operation_error(:budget_exhausted),
    do: "The model budget is exhausted. No automatic retry or alternative model was used."

  defp operation_error(reason)
       when reason in [
              :invalid_scope,
              :stale_scope,
              :stale_generation,
              :stale_revision,
              :source_unavailable,
              :stale_company_analysis_context,
              :scope_denied,
              :invalid_passage
            ],
       do:
         "Evidence or permissions changed. Refresh and explicitly reselect current project, assigned goal and connection; retrieve evidence again."

  defp operation_error(:model_abstained),
    do: "The model found insufficient evidence and saved no recommendation."

  defp operation_error(:operation_stopped),
    do:
      "The operation stopped; its outcome is unknown. Review current status before explicitly trying again. No approval was granted."

  defp operation_error(_),
    do:
      "The operation could not finish; the reason is unknown. Refresh current scope before explicitly trying again. No approval was granted."

  defp error_message(reason) when reason in [:invalid_input, :invalid_query],
    do:
      "Check the saved project, assigned goal and captured corpus. Use at most eight literal search words."

  defp error_message(reason) when reason in [:invalid_cursor, :expired_cursor, :stale_view],
    do: "This view or page changed. Refresh current evidence before continuing."

  defp error_message(_),
    do:
      "This evidence or recommendation is unavailable or changed. Its preview was cleared. Refresh and explicitly select current context."

  @impl true
  def render(assigns) do
    ~H"""
    <main class="workspace-main company-builder" id="corpus-review">
      <.link href="/" class="button secondary">Return to workspace</.link>
      <CorpusUI.review
        state={@state}
        pipeline={@large}
        generation={@generation}
        restriction={@restriction}
        interactive={@interactive}
      />
      <HarnessForgeWeb.Company.ReadinessFacts.panel id="corpus-readiness" data={@readiness} />
    </main>
    """
  end
end
