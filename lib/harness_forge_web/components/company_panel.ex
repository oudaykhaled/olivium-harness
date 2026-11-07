defmodule HarnessForgeWeb.CompanyPanel do
  @moduledoc "Guided local company setup and explicit immutable plan decisions."
  use HarnessForgeWeb, :live_component

  alias HarnessForge.{Company, Contracts, Evidence, Harnesses, Releases, Workspaces}
  alias HarnessForge.Company.{Analysis, SetupRuns, SetupSessions, Validation}
  alias HarnessForgeWeb.Company.{Catalog, Guide, Plan}
  alias HarnessForgeWeb.Company.Assessment, as: AssessmentUI
  alias HarnessForgeWeb.Company.Analysis, as: AnalysisUI
  alias HarnessForgeWeb.Plugs.OperatorSession

  @sections ~w(profile repository project analysis evidence plan review build)
  @destinations %{
    "profile" => "company-profile-name",
    "repository" => "company-repository-identity",
    "project" => "company-project-name",
    "analysis" => "company-analysis-project",
    "evidence" => "company-review-evidence",
    "plan" => "company-plan-name",
    "review" => "company-plan-review-step",
    "build" => "company-build-step"
  }
  @draft_keys %{
    "profile" => :profile_draft,
    "repository" => :repository_draft,
    "project" => :project_draft,
    "plan" => :plan_draft
  }
  @home_resume_fields ~w(id version step updated_at reference_status run_id run_version run_phase failure_code requests_reserved pending_requests uncertain_requests tokens_accounted cost_microusd_accounted predecessor_uncertain_requests history_partial error_code)
  @home_usage_fields ~w(requests_reserved pending_requests uncertain_requests tokens_accounted cost_microusd_accounted)

  @impl true
  def mount(socket),
    do:
      {:ok,
       socket
       |> clear_cache()
       |> rotate_event_generation()
       |> assign(company_reset_token: 0, company_sensitive_reset_token: 0)}

  @impl true
  def update(assigns, socket) do
    assigns = Map.drop(assigns, [:company_event_generation, "company_event_generation"])
    {outcome, assigns} = Map.pop(assigns, :analysis_result)
    {review, assigns} = Map.pop(assigns, :analysis_open)
    leaving = socket.assigns[:active] == true && Map.get(assigns, :active) == false

    selector_changed =
      {Map.get(assigns, :home_setup_id, socket.assigns.home_setup_id),
       Map.get(assigns, :home_setup_invalid, socket.assigns.home_setup_invalid)} !=
        {socket.assigns.home_setup_id, socket.assigns.home_setup_invalid}

    socket =
      if Map.get(
           assigns,
           :company_sensitive_reset_token,
           socket.assigns.company_sensitive_reset_token
         ) != socket.assigns.company_sensitive_reset_token,
         do: socket |> clear_analysis() |> clear_home_resume() |> rotate_event_generation(),
         else: socket

    # Compare the server-owned generation before touching any cached company state.
    socket =
      if Map.get(assigns, :company_reset_token, socket.assigns.company_reset_token) !=
           socket.assigns.company_reset_token,
         do:
           if(leaving, do: clear_analysis(socket), else: clear_cache(socket))
           |> rotate_event_generation(),
         else: socket

    socket =
      if leaving,
        do: socket |> clear_analysis() |> clear_home_resume() |> rotate_event_generation(),
        else: socket

    socket =
      if selector_changed,
        do: socket |> clear_home_resume() |> rotate_event_generation(),
        else: socket

    socket =
      socket
      |> assign(assigns)
      |> then(fn socket ->
        if Map.has_key?(assigns, :sources),
          do: assign(socket, :catalog_sources, assigns.sources),
          else: socket
      end)

    if OperatorSession.valid?(socket.assigns.operator_auth),
      do:
        {:ok,
         socket
         |> receive_analysis(outcome)
         |> receive_review(review)
         |> receive_creation()
         |> reload()},
      else:
        {:ok, socket |> clear_cache() |> assign(:operator_auth, nil) |> redirect(to: "/login")}
  end

  defp clear_cache(socket) do
    socket
    |> clear_analysis()
    |> assign(
      company_event_generation: nil,
      assessment_binding: nil,
      assessment_state: HarnessForgeWeb.CompanyAssessmentState.empty(),
      assessment_event_generation: nil,
      assessment_rubrics: [],
      profile: nil,
      repositories: [],
      projects: [],
      plans: [],
      repository_edit: nil,
      project_edit: nil,
      profile_draft: nil,
      repository_draft: nil,
      project_draft: nil,
      plan_draft: empty_plan(),
      plan_dirty: false,
      selected_plan: nil,
      plan_preflight: :none,
      plan_preflight_at: nil,
      plan_preflight_key: nil,
      guide_project_id: nil,
      home_setup_id: socket.assigns[:home_setup_id],
      home_setup_invalid: Map.get(socket.assigns, :home_setup_invalid, false),
      home_resume: empty_home_resume(),
      setup_creation_request: nil,
      setup_creation_seen: nil,
      open_sections: MapSet.new(),
      form_error: nil,
      capability_query: "",
      capability_results: nil,
      consumer_results: nil,
      consumer_repository: nil,
      built_artifact: nil,
      package_diff: nil,
      company_notice: nil,
      company_error: nil,
      company_load_error: false,
      sources: [],
      catalog_sources: [],
      goals: [],
      approved: [],
      artifacts: [],
      data_errors: [],
      claim_review_count: nil
    )
  end

  defp clear_analysis(socket) do
    assign(socket,
      analysis_draft: AnalysisUI.empty(),
      analysis_pins: %{},
      analysis_pending: nil,
      analysis_selected: nil,
      analysis_edit: nil,
      analysis_dirty: false,
      analysis_error: nil,
      analysis_notice: nil
    )
  end

  defp receive_creation(socket) do
    request = socket.assigns.setup_creation_request

    if is_map(request) && socket.assigns[:active] &&
         request["section"] in ~w(profile repository project) &&
         request["request_id"] != socket.assigns.setup_creation_seen &&
         request["reset_token"] == socket.assigns.company_reset_token &&
         OperatorSession.valid?(socket.assigns.operator_auth) do
      socket = assign(socket, :setup_creation_seen, request["request_id"])

      if company_draft?(socket) do
        assign(
          socket,
          :company_error,
          "Save or discard your Company draft before opening another creation form."
        )
      else
        section = request["section"]

        socket =
          case section do
            "repository" -> assign(socket, :repository_edit, nil)
            "project" -> assign(socket, :project_edit, nil)
            _ -> socket
          end

        socket
        |> rotate_event_generation()
        |> assign(:open_sections, MapSet.new([section]))
        |> focus(@destinations[section])
      end
    else
      socket
    end
  end

  defp receive_analysis(socket, %{token: token, result: result}) do
    if socket.assigns[:active] && token == socket.assigns.analysis_pending &&
         token.generation == socket.assigns.company_event_generation &&
         token.reset_token == socket.assigns.company_reset_token do
      socket = assign(socket, analysis_pending: nil, analysis_error: nil)

      case result do
        {:ok, %{"status" => "proposed", "claim" => claim}} ->
          send(self(), {:company_changed, "Analysis proposal saved"})

          socket
          |> select_analysis(claim)
          |> assign(
            :analysis_notice,
            "Recommendation saved as proposed. Review the original report and current guidance before deciding in Evidence."
          )
          |> focus("company-analysis-review")

        {:ok, %{"status" => "abstained", "uncertainty" => uncertainty}} ->
          socket
          |> assign(
            :analysis_notice,
            "The model abstained; no recommendation was saved. " <> uncertainty
          )
          |> focus("company-analysis-result")

        {:error, reason} ->
          analysis_failure(socket, reason)

        _ ->
          analysis_failure(socket, :service_unavailable)
      end
    else
      socket
    end
  end

  defp receive_analysis(socket, _), do: socket

  defp receive_review(socket, %{"request_id" => request} = attrs) do
    if socket.assigns[:analysis_request_seen] == request do
      socket
    else
      socket
      |> assign(:analysis_request_seen, request)
      |> receive_review(Map.delete(attrs, "request_id"))
    end
  end

  defp receive_review(socket, %{"id" => id, "revision_hash" => hash}) do
    if socket.assigns.analysis_dirty do
      analysis_failure(socket, :dirty_draft)
    else
      case current_analysis(id, hash) do
        {:ok, claim} ->
          socket |> select_analysis(claim) |> focus("company-analysis-review")

        _ ->
          analysis_failure(socket, :stale_revision)
      end
    end
  end

  defp receive_review(socket, _), do: socket

  defp select_analysis(socket, claim),
    do:
      socket
      |> assign(
        analysis_selected: claim,
        analysis_edit: AnalysisUI.edit(claim),
        analysis_dirty: false,
        analysis_error: nil
      )
      |> open("analysis")

  defp analysis_failure(socket, reason),
    do:
      socket
      |> assign(analysis_error: AnalysisUI.error_message(reason), analysis_notice: nil)
      |> open("analysis")
      |> focus("company-analysis-error")

  defp rotate_event_generation(socket) do
    assign(
      socket,
      :company_event_generation,
      Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    )
  end

  # LiveComponents do not inherit the parent LiveView's event authentication hook.
  @impl true
  def handle_event(event, attrs, socket) do
    if OperatorSession.valid?(socket.assigns.operator_auth) do
      case current_envelope(attrs, socket.assigns.company_event_generation) do
        {:ok, payload} ->
          payload = strip_unused_markers(payload)

          if valid_event_shape?(event, payload),
            do: dispatch(event, payload, socket) |> refresh_event_sources(),
            else: fail(socket, event_section(event), :invalid_input)

        :error ->
          {:noreply,
           assign(
             socket,
             :company_notice,
             "This Company view changed. Use the refreshed controls before retrying."
           )}
      end
    else
      {:noreply, socket |> clear_cache() |> assign(:operator_auth, nil) |> redirect(to: "/login")}
    end
  end

  defp refresh_event_sources({:noreply, socket}),
    do: {:noreply, socket |> refresh_source_summaries() |> preflight()}

  defp current_envelope(%{"company_event_generation" => generation} = attrs, current)
       when is_binary(generation) and byte_size(generation) == 32 and is_binary(current) do
    marker_valid =
      case Map.fetch(attrs, "_unused_company_event_generation") do
        :error -> true
        {:ok, ""} -> true
        _ -> false
      end

    if generation == current and Regex.match?(~r/\A[0-9a-f]{32}\z/, generation) and marker_valid,
      do: {:ok, Map.drop(attrs, ~w(company_event_generation _unused_company_event_generation))},
      else: :error
  end

  defp current_envelope(_, _), do: :error

  defp dispatch("company_navigate", _, %{assigns: %{analysis_dirty: true}} = socket),
    do: {:noreply, analysis_failure(socket, :dirty_draft)}

  defp dispatch("company_corpus_open", _, socket) do
    dirty =
      socket.assigns.analysis_dirty or socket.assigns.plan_dirty or
        Enum.any?(~w(profile repository project), &(socket.assigns[@draft_keys[&1]] != nil))

    if dirty do
      {:noreply,
       assign(
         socket,
         :company_error,
         "Save or discard your Company draft before opening corpus evidence review."
       )}
    else
      send(self(), :company_inspect_corpus)
      {:noreply, socket}
    end
  end

  defp dispatch("company_setup_open", _, socket) do
    if company_draft?(socket) do
      setup_draft_failure(socket)
    else
      send(self(), :company_inspect_setup)
      {:noreply, socket}
    end
  end

  defp dispatch("company_setup_resume", _, socket) do
    if company_draft?(socket) do
      setup_draft_failure(socket)
    else
      resume_home_setup(socket)
    end
  end

  defp dispatch("company_setup_refresh", _, socket) do
    if company_draft?(socket),
      do: setup_draft_failure(socket, "refreshing"),
      else: {:noreply, refresh_home_resume(socket)}
  end

  defp dispatch("company_navigate", %{"tab" => tab}, socket)
       when tab in ~w(connections evidence goals package evaluations releases) do
    case {tab, socket.assigns.analysis_selected} do
      {"evidence", %{"id" => id, "revision_hash" => hash}} ->
        send(self(), {:company_navigate, tab, %{"id" => id, "revision_hash" => hash}})

      _ ->
        send(self(), {:company_navigate, tab})
    end

    {:noreply, socket}
  end

  defp dispatch("company_section_toggle", %{"section" => section}, socket)
       when section in @sections do
    open = socket.assigns.open_sections
    closing = MapSet.member?(open, section)
    open = if closing, do: MapSet.delete(open, section), else: MapSet.put(open, section)
    socket = assign(socket, :open_sections, open)
    {:noreply, if(closing, do: focus(socket, "company-toggle-" <> section), else: socket)}
  end

  defp dispatch("company_guide_open", %{"section" => section}, socket)
       when section in @sections do
    if section == "project" and length(socket.assigns.projects) > 1 and
         is_nil(Guide.project(socket.assigns).scope) do
      {:noreply, focus(socket, "company-guide-project")}
    else
      {:noreply, socket |> open(section) |> focus(@destinations[section])}
    end
  end

  defp dispatch("company_guide_project_change", %{"guide" => %{"project_id" => id}}, socket) do
    if id == "" or Enum.any?(socket.assigns.projects, &(&1["id"] == id)),
      do: {:noreply, assign(socket, :guide_project_id, if(id == "", do: nil, else: id))},
      else: fail(socket, "project", :invalid_input)
  end

  defp dispatch(event, params, socket)
       when event in ~w(company_profile_change company_repository_change company_project_change) do
    form =
      %{
        "company_profile_change" => "profile",
        "company_repository_change" => "repository",
        "company_project_change" => "project"
      }[event]

    {:noreply, capture_draft(socket, form, params[form])}
  end

  defp dispatch("company_draft_discard", %{"form" => form}, socket)
       when form in ~w(profile repository project plan) do
    socket = assign(socket, @draft_keys[form], if(form == "plan", do: empty_plan(), else: nil))

    socket =
      if form == "plan", do: assign(socket, :plan_dirty, false), else: refresh_edit(socket, form)

    {:noreply, assign(socket, company_error: nil, form_error: nil)}
  end

  defp dispatch("company_profile_save", %{"profile" => attrs}, socket) do
    socket = capture_draft(socket, "profile", attrs)

    input =
      socket.assigns.profile_draft
      |> Map.take(~w(name description expected_content_hash))
      |> Map.merge(references(socket.assigns.profile_draft, ~w(source_ids goal_ids)))

    result = with :ok <- pinned_input(socket, "profile", attrs), do: Company.save_profile(input)
    finish(socket, result, "Company profile saved.", section: "profile", draft: :profile_draft)
  end

  defp dispatch("company_repository_save", %{"repository" => attrs}, socket) do
    socket = capture_draft(socket, "repository", attrs)
    draft = socket.assigns.repository_draft

    input =
      draft
      |> Map.take(~w(identity name purpose owner version_strategy expected_content_hash))
      |> Map.merge(references(draft, ~w(dependency_ids)))
      |> Map.merge(
        Map.new(~w(capabilities interfaces examples), &{&1, lines(draft[&1 <> "_text"])})
      )

    result =
      with :ok <- pinned_input(socket, "repository", attrs) do
        if draft["id"] in [nil, ""],
          do: Company.create_repository(input),
          else: Company.update_repository(draft["id"], input)
      end

    finish(socket, result, "Repository saved. Its descriptions do not approve company policy.",
      reset: :repository_edit,
      draft: :repository_draft,
      section: "repository"
    )
  end

  defp dispatch("company_repository_edit", %{"id" => id}, socket),
    do: edit(socket, :repository_edit, socket.assigns.repositories, id)

  defp dispatch("company_repository_new", _, socket),
    do: new_record(socket, "repository", :repository_edit)

  defp dispatch("company_project_save", %{"project" => attrs}, socket) do
    socket = capture_draft(socket, "project", attrs)
    draft = socket.assigns.project_draft

    input =
      draft
      |> Map.take(~w(name description expected_content_hash))
      |> Map.merge(references(draft, ~w(repository_ids source_ids goal_ids)))

    result =
      with :ok <- pinned_input(socket, "project", attrs) do
        if draft["id"] in [nil, ""],
          do: Company.create_project(input),
          else: Company.update_project(draft["id"], input)
      end

    finish(socket, result, "Project saved with its explicit repositories, sources and goals.",
      reset: :project_edit,
      draft: :project_draft,
      section: "project"
    )
  end

  defp dispatch("company_project_edit", %{"id" => id}, socket),
    do: edit(socket, :project_edit, socket.assigns.projects, id)

  defp dispatch("company_project_new", _, socket),
    do: new_record(socket, "project", :project_edit)

  defp dispatch(event, _, %{assigns: %{active: false}} = socket)
       when event in ~w(company_analysis_change company_analysis_start company_analysis_clear company_analysis_open company_analysis_edit_change company_analysis_revise company_analysis_discard),
       do: {:noreply, socket}

  defp dispatch(event, _, %{assigns: %{analysis_pending: pending}} = socket)
       when not is_nil(pending) and
              event in ~w(company_analysis_change company_analysis_start company_analysis_clear company_analysis_open),
       do: {:noreply, socket}

  defp dispatch(event, _, %{assigns: %{analysis_dirty: true}} = socket)
       when event in ~w(company_analysis_change company_analysis_start company_analysis_clear company_analysis_open),
       do: {:noreply, analysis_failure(socket, :dirty_draft)}

  defp dispatch("company_analysis_clear", _, socket), do: {:noreply, clear_analysis(socket)}

  defp dispatch(event, %{"analysis" => attrs}, socket)
       when event in ~w(company_analysis_change company_analysis_start) do
    {draft, pins} =
      AnalysisUI.capture(
        attrs,
        socket.assigns.analysis_draft,
        socket.assigns.analysis_pins,
        socket.assigns.sources,
        socket.assigns.goals
      )

    socket = assign(socket, analysis_draft: draft, analysis_pins: pins, analysis_error: nil)

    if event == "company_analysis_change" do
      {:noreply, socket}
    else
      case AnalysisUI.input(draft, pins) do
        {:ok, input} ->
          token = %{
            generation: socket.assigns.company_event_generation,
            request_id: Ecto.UUID.generate(),
            run_id: Ecto.UUID.generate(),
            input_digest: Contracts.digest(input),
            reset_token: socket.assigns.company_reset_token
          }

          send(
            self(),
            {:company_analysis_start,
             %{
               generation: token.generation,
               request_id: token.request_id,
               run_id: token.run_id,
               input: input,
               reset_token: token.reset_token
             }}
          )

          {:noreply,
           socket |> assign(analysis_pending: token, analysis_notice: nil) |> open("analysis")}

        {:error, reason} ->
          {:noreply, analysis_failure(socket, reason)}
      end
    end
  end

  defp dispatch("company_analysis_open", %{"id" => id, "revision_hash" => hash}, socket) do
    case current_analysis(id, hash) do
      {:ok, claim} ->
        {:noreply, socket |> select_analysis(claim) |> focus("company-analysis-review")}

      _ ->
        {:noreply, analysis_failure(socket, :stale_revision)}
    end
  end

  defp dispatch("company_analysis_discard", _, socket) do
    claim = socket.assigns.analysis_selected
    {:noreply, if(claim, do: select_analysis(socket, claim), else: socket)}
  end

  defp dispatch(event, %{"analysis_edit" => attrs}, socket)
       when event in ~w(company_analysis_edit_change company_analysis_revise) do
    selected = socket.assigns.analysis_selected

    if selected && attrs["id"] == selected["id"] &&
         attrs["expected_revision_hash"] == selected["revision_hash"] do
      socket =
        assign(socket,
          analysis_edit: attrs,
          analysis_dirty: attrs != AnalysisUI.edit(selected),
          analysis_error: nil
        )

      if event == "company_analysis_edit_change" do
        {:noreply, socket}
      else
        input = Map.take(attrs, AnalysisUI.fields() ++ ["review_resolution"])

        input =
          if input["review_resolution"] == "" && is_nil(selected["basis"]["review_resolution"]),
            do: Map.delete(input, "review_resolution"),
            else: input

        case Analysis.revise(attrs["id"], attrs["expected_revision_hash"], input) do
          {:ok, claim} ->
            send(self(), {:company_changed, "Guidance successor saved"})

            {:noreply,
             socket
             |> select_analysis(claim)
             |> assign(
               :analysis_notice,
               "Guidance saved as a new proposed revision. Approve only this exact saved revision in Evidence."
             )
             |> focus("company-analysis-review")}

          {:error, reason} ->
            {:noreply, analysis_failure(socket, reason)}
        end
      end
    else
      {:noreply, analysis_failure(socket, :stale_revision)}
    end
  end

  defp dispatch("company_capability_search", %{"capability" => %{"query" => query}}, socket) do
    case Company.search_capabilities(query) do
      {:ok, rows} ->
        {:noreply,
         assign(socket, capability_query: query, capability_results: rows, company_error: nil)}

      error ->
        finish(socket, error, "", section: "repository")
    end
  end

  defp dispatch("company_consumers", %{"id" => id}, socket) do
    case Company.consumers(id) do
      {:ok, rows} ->
        {:noreply,
         assign(socket, consumer_repository: id, consumer_results: rows, company_error: nil)}

      error ->
        finish(socket, error, "")
    end
  end

  defp dispatch("company_plan_change", %{"plan" => attrs}, socket) do
    draft = normalize_draft(attrs)

    draft =
      if draft["project_id"] != socket.assigns.plan_draft["project_id"],
        do: Map.merge(draft, %{"repository_ids" => [], "claim_refs" => [], "goal_ids" => []}),
        else: draft

    {:noreply, socket |> assign(plan_draft: draft, plan_dirty: true) |> clear_plan_name_error()}
  end

  defp dispatch("company_milestone_add", _, socket) do
    draft = socket.assigns.plan_draft
    rows = draft["milestones"]

    if length(rows) < 100 do
      used = Enum.map(rows, & &1["id"])
      number = Enum.find(1..101, &("milestone-#{&1}" not in used))
      row = empty_milestone("milestone-#{number}")

      {:noreply,
       assign(socket, plan_draft: Map.put(draft, "milestones", rows ++ [row]), plan_dirty: true)}
    else
      finish(socket, {:error, :invalid_input}, "")
    end
  end

  defp dispatch("company_milestone_remove", %{"index" => index}, socket) when is_binary(index) do
    with {number, ""} <- Integer.parse(index),
         true <- number >= 0 and number < length(socket.assigns.plan_draft["milestones"]) do
      draft = socket.assigns.plan_draft
      removed = Enum.at(draft["milestones"], number)["id"]

      rows =
        draft["milestones"]
        |> List.delete_at(number)
        |> Enum.map(&Map.update!(&1, "depends_on", fn ids -> List.delete(ids, removed) end))

      {:noreply, assign(socket, plan_draft: Map.put(draft, "milestones", rows), plan_dirty: true)}
    else
      _ -> finish(socket, {:error, :invalid_input}, "")
    end
  end

  defp dispatch("company_plan_create", %{"plan" => attrs}, socket) do
    socket = assign(socket, plan_draft: normalize_draft(attrs), plan_dirty: true)

    with {:ok, input} <- plan_input(attrs),
         :ok <- validate_plan_name(input["name"]),
         {:ok, plan} <- Company.create_plan(input) do
      finish(
        assign(socket,
          selected_plan: plan,
          guide_project_id: plan["payload"]["project_id"],
          plan_draft: empty_plan(),
          plan_dirty: false
        ),
        {:ok, plan},
        "Plan saved as proposed. Review this exact revision before approving it.",
        section: "plan"
      )
    else
      error -> finish(socket, error, "", section: "plan")
    end
  end

  defp dispatch("company_plan_select", %{"id" => id}, socket) do
    case Company.get_plan(id) do
      {:ok, plan} when is_map(plan) ->
        socket =
          if socket.assigns.selected_plan && socket.assigns.selected_plan["id"] == plan["id"],
            do: socket,
            else: assign(socket, :built_artifact, nil)

        {:noreply,
         socket
         |> assign(
           selected_plan: plan,
           guide_project_id: plan["payload"]["project_id"],
           company_error: nil,
           form_error: nil
         )
         |> preflight()
         |> open("review")
         |> focus(@destinations["review"])}

      _ ->
        finish(socket, {:error, :plan_unavailable}, "")
    end
  end

  defp dispatch(
         "company_plan_successor",
         %{"id" => _id},
         %{assigns: %{plan_dirty: true}} = socket
       ),
       do: fail(socket, "plan", :dirty_draft)

  defp dispatch("company_plan_successor", %{"id" => id}, socket) do
    case Company.get_plan(id) do
      {:ok, %{"payload" => payload} = plan} ->
        draft =
          payload
          |> Map.put("supersedes_id", plan["id"])
          |> Map.put("package_version", "")
          |> Map.update!("claim_refs", fn refs ->
            Enum.map(refs, &(&1["id"] <> ":" <> &1["revision_hash"]))
          end)

        {:noreply,
         socket
         |> assign(
           plan_draft: draft,
           plan_dirty: true,
           company_error: nil,
           company_notice:
             "Previous selections copied. Choose a new version and save a new proposed plan."
         )
         |> open("plan")
         |> focus(@destinations["plan"])}

      _ ->
        finish(socket, {:error, :plan_unavailable}, "")
    end
  end

  defp dispatch("company_plan_decide", %{"plan_decision" => attrs}, socket) do
    result =
      Company.decide_plan(attrs["id"], %{
        "actor" => Workspaces.operator(),
        "decision" => attrs["decision"],
        "expected_revision_hash" => attrs["expected_revision_hash"]
      })

    {:noreply, socket} =
      finish(socket, result, "Decision recorded for the displayed plan revision.",
        section: "review"
      )

    socket =
      if match?({:ok, _}, result),
        do: socket |> open("review") |> focus(@destinations["review"]),
        else: socket

    {:noreply, socket}
  end

  defp dispatch("company_plan_build", %{"plan_build" => attrs}, socket) do
    case Harnesses.build_plan(attrs["id"], attrs["expected_revision_hash"]) do
      {:ok, artifact} ->
        finish(
          assign(socket, :built_artifact, artifact),
          {:ok, artifact},
          "Package built. Export, evaluation and release approval remain separate steps.",
          section: "build"
        )

      error ->
        finish(socket, error, "", section: "build")
    end
  end

  defp dispatch("company_package_diff", %{"company_diff" => attrs}, socket) do
    case Releases.diff(attrs["left"], attrs["right"]) do
      {:ok, diff} -> {:noreply, assign(socket, package_diff: diff, company_error: nil)}
      error -> finish(socket, error, "", section: "build")
    end
  end

  defp dispatch(_, _, socket), do: finish(socket, {:error, :invalid_input}, "")

  defp company_draft?(socket),
    do:
      socket.assigns.analysis_dirty or socket.assigns.plan_dirty or
        Enum.any?(~w(profile repository project), &(socket.assigns[@draft_keys[&1]] != nil))

  defp setup_draft_failure(socket, action \\ "opening"),
    do:
      {:noreply,
       assign(
         socket,
         :company_error,
         "Save or discard your Company draft before #{action} saved setup."
       )}

  defp resume_home_setup(socket) do
    case socket.assigns.home_resume do
      %{"state" => "selected", "id" => id} when is_binary(id) ->
        case read_home_setup(id, home_resume_caller(socket)) do
          {:ok, %{"id" => ^id}} ->
            send(self(), {:company_inspect_setup, id})
            {:noreply, socket}

          {:ok, _} ->
            {:noreply, home_resume_failure(socket, "conflict")}

          {:error, reason} ->
            {:noreply, home_resume_failure(socket, reason)}
        end

      _ ->
        {:noreply, home_resume_failure(socket, "invalid_input")}
    end
  end

  # Phoenix serializeForm marks untouched inputs at their final field segment.
  # Array markers are lists of empty strings. Remove only that transport shape
  # beside a real field; all real fields still pass the strict validators below.
  defp strip_unused_markers(params) when is_map(params) do
    params
    |> Enum.reject(fn
      {"_unused_" <> field, value} -> Map.has_key?(params, field) and unused_marker?(value)
      _ -> false
    end)
    |> Map.new(fn {key, value} -> {key, strip_unused_markers(value)} end)
  end

  defp strip_unused_markers(value), do: value
  defp unused_marker?(""), do: true
  defp unused_marker?([_ | _] = values), do: Enum.all?(values, &(&1 == ""))
  defp unused_marker?(_), do: false

  defp valid_event_shape?(event, attrs)
       when event in ~w(company_setup_open company_setup_resume company_setup_refresh),
       # LiveView's native button transport includes its empty HTML value.
       do: attrs in [%{}, %{"value" => ""}]

  defp valid_event_shape?(event, %{"analysis" => attrs})
       when event in ~w(company_analysis_change company_analysis_start) and is_map(attrs) do
    Enum.sort(Map.keys(attrs)) == ~w(goal_id project_id source_ids) and
      valid_fields?(attrs, ~w(source_ids)) and length(attrs["source_ids"]) <= 5
  end

  defp valid_event_shape?(event, %{"analysis_edit" => attrs})
       when event in ~w(company_analysis_edit_change company_analysis_revise) and is_map(attrs) do
    keys = AnalysisUI.fields() ++ ~w(id expected_revision_hash review_resolution)

    Enum.all?(Map.keys(attrs), &(&1 in keys)) and
      Enum.all?(AnalysisUI.fields() ++ ~w(id expected_revision_hash), &Map.has_key?(attrs, &1)) and
      valid_fields?(attrs, [])
  end

  defp valid_event_shape?(event, attrs) when is_map(attrs) do
    root =
      %{
        "company_profile_change" => "profile",
        "company_repository_change" => "repository",
        "company_project_change" => "project",
        "company_guide_project_change" => "guide",
        "company_profile_save" => "profile",
        "company_repository_save" => "repository",
        "company_project_save" => "project",
        "company_capability_search" => "capability",
        "company_plan_change" => "plan",
        "company_plan_create" => "plan",
        "company_plan_decide" => "plan_decision",
        "company_plan_build" => "plan_build",
        "company_package_diff" => "company_diff"
      }[event]

    cond do
      is_nil(root) -> valid_fields?(attrs, [])
      not is_map(attrs[root]) -> false
      root == "plan" -> valid_plan_shape?(attrs[root])
      true -> valid_fields?(attrs[root], ~w(source_ids goal_ids repository_ids dependency_ids))
    end
  end

  defp valid_event_shape?(_, _), do: false

  defp valid_plan_shape?(attrs) do
    fields = Map.drop(attrs, ~w(execution milestones))
    execution = Map.get(attrs, "execution", %{})
    rows = Map.get(attrs, "milestones", %{})

    valid_fields?(fields, ~w(repository_ids claim_refs goal_ids template_ids)) and
      is_map(execution) and
      Enum.all?(execution, fn {key, value} ->
        key in ~w(max_turns timeout_seconds) and (bounded_text?(value) or is_integer(value))
      end) and
      is_map(rows) and map_size(rows) <= 100 and
      Enum.all?(rows, fn {index, row} ->
        is_binary(index) and Regex.match?(~r/\A[0-9]{1,3}\z/, index) and
          is_map(row) and
          Enum.all?(
            ~w(id title acceptance evaluation_method target_version),
            &Map.has_key?(row, &1)
          ) and
          valid_fields?(row, ~w(goal_ids depends_on))
      end)
  end

  defp valid_fields?(attrs, arrays) do
    map_size(attrs) <= 30 and
      Enum.all?(attrs, fn {key, value} ->
        is_binary(key) and byte_size(key) <= 128 and
          if key in arrays,
            do: is_list(value) and length(value) <= 501 and Enum.all?(value, &bounded_text?/1),
            else: bounded_text?(value)
      end)
  end

  defp bounded_text?(value), do: is_binary(value) and byte_size(value) <= 16_384

  defp edit(socket, key, records, id) do
    form = if key == :repository_edit, do: "repository", else: "project"
    current = socket.assigns[key]

    cond do
      current && current["id"] == id ->
        {:noreply, socket}

      socket.assigns[@draft_keys[form]] != nil ->
        fail(socket, form, :dirty_draft)

      true ->
        case Enum.find(records, &(&1["id"] == id)) do
          nil ->
            fail(socket, form, :invalid_input)

          record ->
            {:noreply, socket |> assign(key, record) |> open(form) |> focus(@destinations[form])}
        end
    end
  end

  defp new_record(socket, form, key) do
    if socket.assigns[@draft_keys[form]] != nil,
      do: fail(socket, form, :dirty_draft),
      else: {:noreply, assign(socket, key, nil)}
  end

  defp refresh_edit(socket, form) when form in ~w(repository project) do
    {key, records} =
      if form == "repository",
        do: {:repository_edit, socket.assigns.repositories},
        else: {:project_edit, socket.assigns.projects}

    record = socket.assigns[key]
    assign(socket, key, if(record, do: Enum.find(records, &(&1["id"] == record["id"]))))
  end

  defp refresh_edit(socket, _), do: socket

  defp capture_draft(socket, form, attrs) do
    {fields, arrays, record} =
      case form do
        "profile" ->
          {~w(name description), ~w(source_ids goal_ids), socket.assigns.profile}

        "repository" ->
          {~w(identity name purpose owner version_strategy capabilities_text interfaces_text examples_text),
           ~w(dependency_ids), socket.assigns.repository_edit}

        "project" ->
          {~w(name description), ~w(repository_ids source_ids goal_ids),
           socket.assigns.project_edit}
      end

    prior = socket.assigns[@draft_keys[form]]
    hash = if prior, do: prior["expected_content_hash"], else: record && record["content_hash"]
    draft = attrs |> Map.take(fields) |> Map.merge(references(attrs, arrays))
    draft = if hash, do: Map.put(draft, "expected_content_hash", hash), else: draft
    draft = if record, do: Map.put(draft, "id", record["id"]), else: draft
    assign(socket, @draft_keys[form], draft)
  end

  defp pinned_input(socket, form, attrs) do
    draft = socket.assigns[@draft_keys[form]]
    same_hash = draft["expected_content_hash"] == attrs["expected_content_hash"]
    same_id = form == "profile" or (draft["id"] || "") == (attrs["id"] || "")
    if same_hash and same_id, do: :ok, else: {:error, :stale_content_hash}
  end

  defp finish(socket, result, message, opts \\ [])

  defp finish(socket, {:ok, _}, message, opts) do
    send(self(), {:company_changed, message})
    socket = if opts[:reset], do: assign(socket, opts[:reset], nil), else: socket
    socket = if opts[:draft], do: assign(socket, opts[:draft], nil), else: socket

    {:noreply,
     socket |> assign(company_error: nil, form_error: nil, company_notice: message) |> reload()}
  end

  defp finish(socket, {:error, reason}, _, opts),
    do: fail(socket, opts[:section] || "review", reason)

  defp fail(socket, "analysis", reason), do: {:noreply, analysis_failure(socket, reason)}

  defp fail(socket, section, reason) do
    message = error_message(reason)
    name_error? = section == "plan" and reason == :invalid_plan_name
    error = %{section: section, message: message}
    error = if name_error?, do: Map.put(error, :field, "name"), else: error

    socket =
      assign(socket,
        company_error: if(name_error?, do: nil, else: message),
        company_notice: nil,
        form_error: error
      )

    socket =
      if section in ~w(review build),
        do: assign(socket, plan_preflight: :none, plan_preflight_key: nil),
        else: socket

    focus_id = if name_error?, do: "company-plan-name", else: "company-" <> section <> "-error"
    {:noreply, socket |> open(section) |> focus(focus_id)}
  end

  defp clear_plan_name_error(
         %{assigns: %{form_error: %{section: "plan", field: "name"}}} = socket
       ),
       do: assign(socket, form_error: nil, company_error: nil)

  defp clear_plan_name_error(socket), do: socket

  defp validate_plan_name(value) do
    if Validation.plan_name_valid?(value), do: :ok, else: {:error, :invalid_plan_name}
  end

  defp open(socket, section),
    do: assign(socket, :open_sections, MapSet.put(socket.assigns.open_sections, section))

  defp focus(socket, id), do: push_event(socket, "company-focus", %{id: id})

  defp event_section(event) do
    cond do
      String.starts_with?(event, "company_analysis") ->
        "analysis"

      String.starts_with?(event, "company_profile") ->
        "profile"

      String.starts_with?(event, "company_repository") or event == "company_capability_search" ->
        "repository"

      String.starts_with?(event, "company_project") or event == "company_guide_project_change" ->
        "project"

      event in ~w(company_plan_change company_plan_create company_milestone_add company_milestone_remove company_plan_successor) ->
        "plan"

      event in ~w(company_plan_build company_package_diff) ->
        "build"

      true ->
        "review"
    end
  end

  defp reload(socket) do
    results =
      Enum.map(
        [
          &Company.get_profile/0,
          &Company.list_repositories/0,
          &Company.list_projects/0,
          &Company.list_plans/0
        ],
        &safe_read/1
      )

    socket =
      case results do
        [{:ok, profile}, {:ok, repositories}, {:ok, projects}, {:ok, plans}] ->
          selected = socket.assigns.selected_plan
          selected = if selected, do: Enum.find(plans, &(&1["id"] == selected["id"]))

          socket
          |> assign(
            profile: profile,
            repositories: repositories,
            projects: projects,
            plans: plans,
            selected_plan: selected,
            company_load_error: false
          )
          |> refresh_source_summaries()
          |> preflight()

        _ ->
          assign(socket,
            profile: nil,
            repositories: [],
            projects: [],
            plans: [],
            selected_plan: nil,
            plan_preflight: :none,
            plan_preflight_at: nil,
            plan_preflight_key: nil,
            company_load_error: true
          )
      end

    refresh_home_resume(socket)
  end

  defp empty_home_resume(state \\ "empty", origin \\ "none") do
    @home_resume_fields
    |> Map.new(&{&1, nil})
    |> Map.merge(%{"state" => state, "origin" => origin})
  end

  defp clear_home_resume(socket), do: assign(socket, :home_resume, empty_home_resume())

  defp home_resume_caller(socket) do
    auth = socket.assigns.operator_auth
    workspace = socket.assigns[:workspace_id]

    [
      authorize: fn -> workspace == Workspaces.current_id() && OperatorSession.valid?(auth) end,
      session_fingerprint: Contracts.digest(auth),
      view_generation: socket.assigns.company_event_generation,
      reset_token: socket.assigns.company_reset_token
    ]
  end

  defp refresh_home_resume(socket) do
    socket = clear_home_resume(socket)
    caller = home_resume_caller(socket)

    cond do
      socket.assigns.home_setup_invalid ->
        assign(
          socket,
          :home_resume,
          Map.put(empty_home_resume("invalid"), "error_code", "invalid_input")
        )

      socket.assigns.home_setup_id ->
        load_home_resume(socket, socket.assigns.home_setup_id, "explicit", caller)

      true ->
        case safe_read(fn -> SetupSessions.list(%{}, caller) end) do
          {:ok, []} -> socket
          {:ok, [%{"id" => id}]} -> load_home_resume(socket, id, "sole", caller)
          {:ok, [_ | _]} -> assign(socket, :home_resume, empty_home_resume("choose"))
          {:error, reason} -> home_resume_failure(socket, reason)
          _ -> home_resume_failure(socket, "unavailable")
        end
    end
  end

  defp load_home_resume(socket, id, origin, caller) do
    with {:ok, %{"id" => ^id} = setup} <- read_home_setup(id, caller),
         {:ok, run} <- read_home_run(id, caller),
         {:ok, summary} <- project_home_resume(setup, run, origin) do
      assign(socket, :home_resume, summary)
    else
      {:error, reason} -> home_resume_failure(socket, reason)
      _ -> home_resume_failure(socket, "conflict")
    end
  end

  defp read_home_setup(id, caller) do
    safe_read(fn ->
      case SetupSessions.get(%{"id" => id}, caller) do
        {:ok, setup} when is_map(setup) -> {:ok, home_setup_metadata(setup)}
        {:error, _} = failure -> failure
        _ -> {:error, "unavailable"}
      end
    end)
  end

  defp home_setup_metadata(setup) do
    setup
    |> Map.take(~w(id version step updated_at))
    |> Map.put("reference_status", get_in(setup, ["reference_status", "status"]))
  end

  defp read_home_run(id, caller) do
    safe_read(fn ->
      case SetupRuns.get(id, caller) do
        {:ok, view} when is_map(view) ->
          {:ok,
           %{
             "id" => view["id"],
             "session_version" => view["session_version"],
             "run" => home_run_metadata(view["run"]),
             "predecessor_usage" => home_predecessor_metadata(view["predecessor_usage"]),
             "history_cursor" => if(is_nil(view["history_cursor"]), do: nil, else: true)
           }}

        {:error, _} = failure ->
          failure

        _ ->
          {:error, "unavailable"}
      end
    end)
  end

  defp home_predecessor_metadata(rows) when is_list(rows),
    do:
      Enum.map(
        rows,
        &%{"usage" => %{"uncertain_requests" => get_in(&1, ["usage", "uncertain_requests"])}}
      )

  defp home_predecessor_metadata(_), do: nil

  defp home_run_metadata(nil), do: nil

  defp home_run_metadata(run) when is_map(run) do
    run
    |> Map.take(~w(run_version phase failure_code))
    |> Map.put("run_ref", %{"id" => get_in(run, ["run_ref", "id"])})
    |> Map.put("usage", Map.take(run["usage"] || %{}, @home_usage_fields))
  end

  @doc false
  def project_home_resume(setup, view, origin)
      when is_map(setup) and is_map(view) and origin in ~w(sole explicit) do
    if is_binary(setup["id"]) and is_integer(setup["version"]) and
         view["id"] == setup["id"] and view["session_version"] == setup["version"] do
      reference = setup["reference_status"]
      reference = if is_map(reference), do: reference["status"], else: reference
      run = home_run_metadata(view["run"])
      usage = if run, do: run["usage"], else: %{}

      summary =
        empty_home_resume("selected", origin)
        |> Map.merge(Map.take(setup, ~w(id version step updated_at)))
        |> Map.merge(Map.take(usage, @home_usage_fields))
        |> Map.merge(%{
          "reference_status" => reference,
          "run_id" => get_in(run || %{}, ["run_ref", "id"]),
          "run_version" => (run || %{})["run_version"],
          "run_phase" => (run || %{})["phase"],
          "failure_code" => (run || %{})["failure_code"],
          "predecessor_uncertain_requests" => predecessor_uncertainty(view["predecessor_usage"]),
          "history_partial" => not is_nil(view["history_cursor"])
        })

      {:ok, Map.new(summary, fn {key, value} -> {key, home_scalar(value)} end)}
    else
      {:error, "conflict"}
    end
  end

  def project_home_resume(_, _, _), do: {:error, "unavailable"}

  defp predecessor_uncertainty(rows) when is_list(rows) do
    counts = Enum.map(rows, &get_in(&1, ["usage", "uncertain_requests"]))
    if Enum.all?(counts, &(is_integer(&1) and &1 >= 0)), do: Enum.sum(counts), else: nil
  end

  defp predecessor_uncertainty(_), do: nil

  defp home_scalar(value)
       when is_nil(value) or is_binary(value) or is_integer(value) or is_boolean(value), do: value

  defp home_scalar(_), do: nil

  defp home_resume_failure(socket, reason) do
    code =
      case reason do
        %{"code" => code} -> code
        code when is_binary(code) -> code
        _ -> "unavailable"
      end

    code =
      if code in ~w(invalid_input unauthorized not_found conflict unavailable),
        do: code,
        else: "unavailable"

    socket =
      assign(socket, :home_resume, Map.put(empty_home_resume("unavailable"), "error_code", code))

    if code == "unauthorized",
      do: socket |> clear_cache() |> assign(:operator_auth, nil) |> redirect(to: "/login"),
      else: socket
  end

  defp current_analysis(id, hash) do
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

  defp refresh_source_summaries(socket) do
    auth = socket.assigns.operator_auth

    caller = [
      authorize: fn -> OperatorSession.valid?(auth) end,
      session_fingerprint: Contracts.digest(auth),
      view_generation: socket.assigns.company_event_generation,
      reset_token: socket.assigns.company_reset_token
    ]

    profile_ids = get_in(socket.assigns.profile || %{}, ["payload", "source_ids"]) || []

    project_ids =
      [
        socket.assigns.project_edit && socket.assigns.project_edit["id"],
        socket.assigns.analysis_draft["project_id"],
        socket.assigns.plan_draft["project_id"],
        socket.assigns.guide_project_id,
        get_in(socket.assigns.selected_plan || %{}, ["payload", "project_id"])
      ]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()

    project_ids =
      if project_ids == [] and length(socket.assigns.projects) == 1,
        do: [hd(socket.assigns.projects)["id"]],
        else: project_ids

    groups =
      Enum.map(project_ids, fn id ->
        project = Enum.find(socket.assigns.projects, &(&1["id"] == id))
        %{"project_ids" => get_in(project || %{}, ["payload", "source_ids"]) || []}
      end)

    groups = [%{"profile_ids" => profile_ids} | groups]

    refs =
      case socket.assigns.analysis_selected do
        %{"basis" => %{"context" => %{"sources" => values}}} -> values
        _ -> []
      end

    groups = [%{"recommendation_refs" => refs} | groups]

    result =
      Enum.reduce_while(groups, {:ok, socket.assigns.catalog_sources}, fn attrs, {:ok, sources} ->
        case HarnessForge.Company.CorpusReview.summary_refs(attrs, caller) do
          {:ok, %{"sources" => values}} -> {:cont, {:ok, values ++ sources}}
          error -> {:halt, error}
        end
      end)

    case result do
      {:ok, sources} ->
        assign(socket, :sources, Enum.uniq_by(sources, & &1["id"]))

      _ ->
        assign(socket,
          sources: [],
          analysis_selected: nil,
          analysis_edit: nil,
          analysis_dirty: false
        )
    end
  end

  defp preflight(socket) do
    socket =
      assign(socket,
        plan_preflight: :none,
        plan_preflight_at: nil,
        plan_preflight_key: nil,
        assessment_binding: nil
      )

    plan = socket.assigns.selected_plan

    unavailable =
      Enum.any?(
        socket.assigns.data_errors,
        &(&1 in ~w(connections sources goals approved claims))
      )

    if plan && plan["status"] == "approved" && !unavailable && !socket.assigns.company_load_error do
      id = plan["id"]
      hash = plan["revision_hash"]

      result =
        case safe_read(fn -> Company.build_inputs(id) end) do
          {:ok, %{"plan_id" => ^id, "plan_revision_hash" => ^hash}} -> :eligible
          {:ok, _} -> {:blocked, error_message(:stale_plan_revision)}
          {:error, reason} -> {:blocked, error_message(reason)}
        end

      assign(socket,
        plan_preflight: result,
        plan_preflight_at: DateTime.to_iso8601(DateTime.utc_now()),
        plan_preflight_key: {plan["id"], plan["revision_hash"]},
        assessment_binding: verified_assessment_binding(plan, socket.assigns.built_artifact)
      )
    else
      socket
    end
  end

  defp verified_assessment_binding(plan, %{"digest" => digest}) do
    case safe_read(fn ->
           Harnesses.assessment_inputs(plan["id"], plan["revision_hash"], digest)
         end) do
      {:ok, _} ->
        %{
          "plan_id" => plan["id"],
          "expected_plan_revision_hash" => plan["revision_hash"],
          "artifact_digest" => digest
        }

      _ ->
        nil
    end
  end

  defp verified_assessment_binding(_, _), do: nil

  defp safe_read(function) do
    function.()
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp plan_input(attrs) do
    draft = normalize_draft(attrs)

    with {:ok, max_turns} <- number(get_in(draft, ["execution", "max_turns"])),
         {:ok, timeout} <- number(get_in(draft, ["execution", "timeout_seconds"])),
         {:ok, refs} <- claim_refs(draft["claim_refs"]) do
      input =
        draft
        |> Map.put("claim_refs", refs)
        |> Map.put("execution", %{"max_turns" => max_turns, "timeout_seconds" => timeout})

      {:ok, if(input["supersedes_id"] == "", do: Map.delete(input, "supersedes_id"), else: input)}
    end
  end

  defp normalize_draft(attrs) do
    empty_plan()
    |> Map.merge(
      Map.take(
        attrs,
        ~w(name package_version project_id runtime runtime_version supersedes_id execution)
      )
    )
    |> Map.merge(references(attrs, ~w(repository_ids claim_refs goal_ids template_ids)))
    |> Map.put(
      "execution",
      Map.merge(empty_plan()["execution"], Map.get(attrs, "execution", %{}))
    )
    |> Map.put("milestones", milestone_rows(attrs["milestones"]))
  end

  defp milestone_rows(rows) when is_map(rows) do
    rows
    |> Enum.sort_by(fn {index, _} -> String.to_integer(index) end)
    |> Enum.take(100)
    |> Enum.map(fn {_, row} ->
      Map.take(row, ~w(id title acceptance evaluation_method target_version))
      |> Map.merge(references(row, ~w(goal_ids depends_on)))
    end)
  end

  defp milestone_rows(_), do: []

  defp references(attrs, keys), do: Map.new(keys, &{&1, ids(attrs[&1])})
  defp ids(values) when is_list(values), do: Enum.reject(values, &(&1 == ""))
  defp ids(_), do: []

  defp lines(value) when is_binary(value),
    do: String.split(value, "\n", trim: true) |> Enum.map(&String.trim/1)

  defp lines(_), do: []
  defp number(value) when is_integer(value), do: {:ok, value}

  defp number(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> {:ok, number}
      _ -> {:error, :invalid_input}
    end
  end

  defp number(_), do: {:error, :invalid_input}

  defp claim_refs(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, refs} ->
      case String.split(value, ":", parts: 2) do
        [id, hash] -> {:cont, {:ok, refs ++ [%{"id" => id, "revision_hash" => hash}]}}
        _ -> {:halt, {:error, :invalid_input}}
      end
    end)
  end

  defp empty_plan do
    %{
      "name" => "",
      "package_version" => "0.1.0",
      "project_id" => "",
      "repository_ids" => [],
      "claim_refs" => [],
      "goal_ids" => [],
      "template_ids" => [],
      "runtime" => "opencode",
      "runtime_version" => "unqualified",
      "execution" => %{"max_turns" => "12", "timeout_seconds" => "600"},
      "milestones" => [],
      "supersedes_id" => ""
    }
  end

  defp empty_milestone(id),
    do: %{
      "id" => id,
      "title" => "",
      "goal_ids" => [],
      "depends_on" => [],
      "acceptance" => "",
      "evaluation_method" => "",
      "target_version" => ""
    }

  defp error_message(:dirty_draft),
    do:
      "This form has unsaved changes. Discard this draft before choosing a different record or proposal."

  defp error_message(:unavailable),
    do: "Current plan inputs are unavailable. Reload saved records before building."

  defp error_message(reason)
       when reason in [
              :stale_revision,
              :stale_content,
              :stale_content_hash,
              :stale_revision_hash,
              :stale_plan_revision
            ],
       do:
         "The displayed revision or its selected context changed. Reload and review the current records before deciding or building."

  defp error_message(reason)
       when reason in [
              :stale_catalog,
              :stale_plan,
              :stale_or_revoked_plan,
              :stale_or_revoked_evidence
            ],
       do:
         "This saved plan's selected context is no longer eligible. Review the current evidence and project membership, then propose and approve a new plan."

  defp error_message(reason)
       when reason in [:plan_not_approved, :unapproved_plan, :approval_required],
       do: "Approve the exact displayed plan revision before building."

  defp error_message(reason)
       when reason in [:already_decided, :superseded_plan, :superseded_revision],
       do:
         "This plan already has a decision or a successor. Select the current proposed plan to make a new decision."

  defp error_message(:no_approved_claims),
    do: "Review and explicitly approve eligible claims in Evidence first."

  defp error_message(:invalid_plan_name),
    do:
      "Use 1–64 characters: start with a lowercase letter, then use lowercase letters, digits, hyphens or underscores. For example: checkout-harness."

  defp error_message(:goal_not_selected),
    do: "Select the goal used by this approved claim before saving the plan."

  defp error_message(:stale_goal_basis),
    do:
      "A goal used by this claim is unavailable or has changed. Review the claim and propose a new plan version."

  defp error_message(:invalid_claim_basis),
    do:
      "This claim's saved origin is invalid. Review current claims in Evidence before proposing a plan."

  defp error_message(:plan_unavailable), do: "This plan is unavailable. Select a current plan."

  defp error_message(_),
    do:
      "The action was rejected. Check required fields, explicit memberships, current approved claims and milestone dependencies."

  @impl true
  def render(assigns) do
    guide = Guide.project(assigns)

    readiness =
      HarnessForge.Company.Readiness.for_plan(
        guide.scope,
        assigns.selected_plan,
        assigns.built_artifact,
        assigns.assessment_binding,
        assigns.plan_preflight,
        assigns.plan_preflight_at
      )

    assigns =
      assigns
      |> assign(:guide, Map.put(guide, :readiness, readiness))
      |> assign(:creation_dirty, company_draft?(%{assigns: assigns}))

    ~H"""
    <section
      id="company-panel"
      tabindex="-1"
      class="tab-panel company-builder"
      hidden={!@active}
      aria-label="Company harness builder"
    >
      <div :if={@company_notice} id="company-notice" class="notice success" role="status">
        {@company_notice}
      </div>
      <div :if={@company_error} id="company-error" class="notice error" role="alert">
        {@company_error}
      </div>
      <div :if={@company_load_error} id="company-unavailable" class="notice error" role="alert">
        Company records are unavailable. Check workspace storage before continuing.
      </div>
      <div id={"company-cache-#{@company_reset_token}"}>
        <div
          :if={
            @active && @setup_creation_request &&
              @setup_creation_request["section"] in ~w(profile repository project)
          }
          id="setup-create-company-return"
          class="context-note"
        >
          <p>
            Create or update the requested {@setup_creation_request["section"]}, then return to your saved setup to reload its choices.
          </p>
          <p :if={@setup_creation_request["section"] == "repository"}>
            A new repository must also be explicitly assigned to the selected project before setup can choose it.
          </p>
          <p :if={@creation_dirty} role="status">
            Save or discard your Company draft before returning.
          </p>
          <div :if={!@creation_dirty && Phoenix.LiveView.connected?(@socket)} class="company-actions">
            <.link
              id="setup-create-company-return-link"
              href={@setup_creation_request["return_path"]}
              class="button secondary"
            >Return to saved setup</.link>
            <.link
              :if={@setup_creation_request["section"] == "repository"}
              id="setup-create-repository-assign"
              href={"/?" <> URI.encode_query(%{"create" => "project", "return_setup" => @setup_creation_request["return_id"], "return_step" => @setup_creation_request["return_step"]})}
              class="button secondary"
            >Assign repositories to a project</.link>
          </div>
        </div>
        <Guide.workflow
          data={@guide}
          target={@myself}
          company_event_generation={@company_event_generation}
          assessment_event_generation={@assessment_event_generation}
          assessment_binding={@assessment_binding}
          connected={Phoenix.LiveView.connected?(@socket)}
        />
        <nav class="company-actions" aria-label="Other company tasks">
          <.link id="company-test-evidence" href="/verification" class="button secondary">Test evidence</.link>
          <button
            id="company-setup-open"
            phx-click="company_setup_open"
            phx-value-company_event_generation={@company_event_generation}
            phx-target={@myself}
            class="button secondary"
            disabled={!Phoenix.LiveView.connected?(@socket)}
          >Saved setup</button>
          <button
            id="company-corpus-review"
            phx-click="company_corpus_open"
            phx-value-company_event_generation={@company_event_generation}
            phx-target={@myself}
            class="button secondary"
          >Select corpus and goal</button>
        </nav>
        <details
          id="company-corpus-entry"
          class="panel company-corpus-entry"
          aria-labelledby="company-corpus-entry-title"
        >
          <summary id="company-corpus-entry-title">How this works</summary>
          <p class="eyebrow">COMPANY HARNESS</p>
          <h3>Build from company evidence</h3>
          <p class="company-intro">
            Combine company documents and history with a saved goal. Inspect supporting and contrary evidence, then review the guidance before building a harness.
          </p>
          <ol class="company-corpus-steps" aria-label="Evidence to harness journey">
            <li>Choose a corpus and goal</li>
            <li>Ask a question and review evidence</li>
            <li>Approve guidance, then a separate plan</li>
            <li>Export files and evaluate a representative task</li>
          </ol>

          <p class="field-help">
            Start with a saved company profile, project, assigned goal and approved local directory.
            Corpus analysis does not require manual document assignments. Account access does not import evidence.
            Export and static integrity do not establish task success.
          </p>
          <div class="company-actions">
            <button
              type="button"
              class="button secondary"
              phx-click="company_guide_open"
              phx-value-company_event_generation={@company_event_generation}
              phx-value-section={if @profile, do: "project", else: "profile"}
              phx-target={@myself}
            >Set up company and project</button>
            <button
              type="button"
              class="button secondary"
              phx-click="company_navigate"
              phx-value-company_event_generation={@company_event_generation}
              phx-value-tab="goals"
              phx-target={@myself}
            >Manage saved goals</button>
          </div>
        </details>
        <Catalog.setup
          target={@myself}
          company_reset_token={@company_reset_token}
          company_event_generation={@company_event_generation}
          profile={@profile}
          profile_draft={@profile_draft}
          repository_draft={@repository_draft}
          project_draft={@project_draft}
          open_sections={@open_sections}
          form_error={@form_error}
          sources={@sources}
          catalog_sources={@catalog_sources}
          source_selected_options={Catalog.source_options(@sources)}
          goals={@goals}
          repositories={@repositories}
          projects={@projects}
          repository_edit={@repository_edit}
          project_edit={@project_edit}
          capability_query={@capability_query}
          capability_results={@capability_results}
          consumer_repository={@consumer_repository}
          consumer_results={@consumer_results}
        />
        <AnalysisUI.builder
          target={@myself}
          generation={@company_event_generation}
          reset_token={@company_reset_token}
          draft={@analysis_draft}
          pins={@analysis_pins}
          projects={@projects}
          profile={@profile}
          sources={@sources}
          goals={@goals}
          claims={@claims}
          selected={@analysis_selected}
          edit={@analysis_edit}
          dirty={@analysis_dirty}
          pending={@analysis_pending}
          error={@analysis_error}
          notice={@analysis_notice}
          model_status={@model_status}
          open={MapSet.member?(@open_sections, "analysis")}
        />
        <Plan.builder
          target={@myself}
          company_reset_token={@company_reset_token}
          company_event_generation={@company_event_generation}
          open_sections={@open_sections}
          form_error={@form_error}
          plan_preflight={@plan_preflight}
          profile={@profile}
          sources={@sources}
          goals={@goals}
          repositories={@repositories}
          projects={@projects}
          approved={@approved}
          plans={@plans}
          draft={@plan_draft}
          selected={@selected_plan}
          artifacts={@artifacts}
          built={@built_artifact}
          diff={@package_diff}
          assessment_event_generation={@assessment_event_generation}
          assessment_binding={@assessment_binding}
        />
        <details
          id="company-assessment-section"
          class="company-step"
          open={
            !!(@assessment_state["context"] || @assessment_state["frozen_rubric"] ||
                 @assessment_state["error"] || @assessment_state["pending_destination"])
          }
        >
          <summary id="company-toggle-assessment">Assess representative task</summary>
          <p>
            Saved rubrics and observations remain available after reload. Unsaved text stays in this view only.
          </p>
          <div :if={@assessment_rubrics != []} id="company-assessment-saved-rubrics">
            <h3>Saved task rubrics</h3>
            <div :for={rubric <- @assessment_rubrics} class="company-record">
              <p>{rubric["payload"]["goal"]["title"]} · {rubric["applicability"]["status"]}</p>
              <button
                type="button"
                class="button secondary"
                id={"company-assessment-open-rubric-" <> rubric["id"]}
                phx-click="assessment_history_open"
                phx-value-assessment_event_generation={@assessment_event_generation}
                phx-value-rubric_id={rubric["id"]}
              >Review saved rubric and assessments</button>
            </div>
          </div>
          <AssessmentUI.panel
            state={@assessment_state}
            assessment_event_generation={@assessment_event_generation}
            company_reset_token={@company_reset_token}
            sources={@sources}
          />
        </details>
      </div>
    </section>
    """
  end
end
