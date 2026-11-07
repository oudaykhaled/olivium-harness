defmodule HarnessForgeWeb.Company.Guide do
  @moduledoc "Pure guidance over saved company records; never an admission decision."
  use HarnessForgeWeb, :html

  @sections [
    {"profile", "Company profile"},
    {"repository", "Repositories and services"},
    {"project", "Project membership"},
    {"evidence", "Claim review"},
    {"plan", "Propose a plan"},
    {"review", "Review an exact plan"},
    {"build", "Build and compare"}
  ]

  @doc "Projects already-loaded saved state without I/O or draft-derived completion."
  @spec project(map()) :: map()
  def project(assigns) do
    scope = scoped_project(assigns)
    saved_repositories = MapSet.new(Enum.map(assigns.repositories, & &1["id"]))
    memberships = get_in(scope || %{}, ["payload", "repository_ids"]) || []

    membership? =
      memberships != [] and Enum.all?(memberships, &MapSet.member?(saved_repositories, &1))

    sources = assigned_sources(assigns, scope)
    revisions = MapSet.new(Enum.map(sources, & &1["latest_revision"]["id"]))

    goal_ids =
      (get_in(assigns.profile || %{}, ["payload", "goal_ids"]) || []) ++
        (get_in(scope || %{}, ["payload", "goal_ids"]) || [])

    claims =
      Enum.filter(
        assigns.approved,
        &eligible_claim?(&1, revisions, goal_ids, assigns.profile, scope)
      )

    unavailable =
      assigns.company_load_error or
        Enum.any?(assigns.data_errors, &(&1 in ~w(connections sources goals claims approved)))

    selected = assigns.selected_plan

    scoped_plans =
      if scope,
        do: Enum.filter(assigns.plans, &(&1["payload"]["project_id"] == scope["id"])),
        else: []

    selected_in_scope? = selected && scope && selected["payload"]["project_id"] == scope["id"]

    complete = %{
      "profile" => !is_nil(assigns.profile),
      "repository" => assigns.repositories != [],
      "project" => !is_nil(scope) and membership?,
      "evidence" => !is_nil(scope) and membership? and claims != [],
      "plan" => scoped_plans != [],
      "review" => selected_in_scope? && selected["status"] == "approved",
      "build" => selected_in_scope? && assigns.plan_preflight == :eligible
    }

    next = next_action(assigns, complete, scope, scoped_plans, unavailable)

    %{
      reset_token: assigns.company_reset_token,
      scope: scope,
      projects: assigns.projects,
      selected: selected,
      home_resume: Map.get(assigns, :home_resume, %{"state" => "empty"}),
      saved_harnesses:
        assigns
        |> Map.get(:artifacts, [])
        |> Enum.map(fn artifact ->
          %{
            "digest" => artifact["digest"],
            "name" => get_in(artifact, ["spec", "metadata", "name"]) || "Harness package",
            "version" => get_in(artifact, ["spec", "metadata", "version"]) || "built"
          }
        end)
        |> Enum.sort_by(&{&1["name"], &1["version"], &1["digest"]}),
      harnesses_unavailable: Enum.any?(~w(artifacts privacy), &(&1 in assigns.data_errors)),
      profile_name: get_in(assigns.profile || %{}, ["payload", "name"]),
      repository_count: length(assigns.repositories),
      assigned_goals:
        assigns
        |> Map.get(:goals, [])
        |> Enum.filter(&(&1["id"] in goal_ids))
        |> Enum.map(&Map.take(&1, ~w(id title))),
      assigned_goal_count: goal_ids |> Enum.uniq() |> length(),
      unavailable: unavailable,
      next: next,
      claim_review_count: assigns.claim_review_count,
      plan_review_count:
        if(assigns.company_load_error,
          do: nil,
          else: Enum.count(assigns.plans, &(&1["status"] == "proposed" and !&1["superseded"]))
        ),
      tasks:
        Enum.map(@sections, fn {name, title} ->
          saved = !unavailable && !!complete[name]
          %{name: name, title: title, saved: saved, status: task_status(name, saved, unavailable)}
        end),
      source_count: length(sources),
      claim_count: length(claims),
      preflight: assigns.plan_preflight,
      readiness: Map.get(assigns, :company_readiness)
    }
  end

  defp scoped_project(assigns) do
    selected_id = get_in(assigns.selected_plan || %{}, ["payload", "project_id"])
    id = assigns.guide_project_id || selected_id

    cond do
      id -> Enum.find(assigns.projects, &(&1["id"] == id))
      length(assigns.projects) == 1 -> hd(assigns.projects)
      true -> nil
    end
  end

  defp assigned_sources(assigns, scope) do
    ids =
      (get_in(assigns.profile || %{}, ["payload", "source_ids"]) || []) ++
        (get_in(scope || %{}, ["payload", "source_ids"]) || [])

    Enum.filter(assigns.sources, fn source ->
      source["id"] in ids and HarnessForgeWeb.Company.Analysis.current_source?(source)
    end)
  end

  defp eligible_claim?(claim, revisions, goal_ids, profile, scope) do
    # Evidence.approved_claims/0 already validates current exact authority.
    case claim["basis"] do
      %{"kind" => "company_analysis", "version" => 2, "goal_id" => id, "context" => context} ->
        # Current manifest authority is already checked by Evidence.approved_claims/0.
        # Corpus evidence does not require legacy manual source assignments.
        scope != nil && profile != nil && id in goal_ids &&
          context["project"] == Map.take(scope, ~w(id content_hash)) &&
          context["profile"] == Map.take(profile, ~w(id content_hash))

      %{
        "kind" => "company_analysis",
        "version" => 1,
        "goal_id" => id,
        "context" => %{"sources" => refs} = context
      }
      when is_list(refs) ->
        scope != nil && profile != nil && id in goal_ids &&
          context["project"] == Map.take(scope, ~w(id content_hash)) &&
          context["profile"] == Map.take(profile, ~w(id content_hash)) &&
          Enum.all?(refs, &MapSet.member?(revisions, &1["revision_id"]))

      %{"kind" => "goal", "goal_id" => id} ->
        id in goal_ids

      nil ->
        citations = claim["citations"] || []

        claim["status"] == "approved" and !claim["superseded"] and citations != [] and
          Enum.all?(citations, &MapSet.member?(revisions, &1["revision_id"]))

      _ ->
        false
    end
  end

  defp next_action(assigns, complete, scope, plans, unavailable) do
    resume = Map.get(assigns, :home_resume, %{})

    cond do
      unavailable ->
        action(
          "review",
          "Review unavailable records",
          "Saved prerequisites are unavailable. Restore workspace access and reload before continuing."
        )

      resume["state"] in ~w(invalid unavailable) ->
        setup_action(
          "company_setup_refresh",
          "Refresh saved setup",
          if(resume["state"] == "invalid",
            do:
              "This saved setup address is invalid. Refresh keeps this address; use Saved setup to choose an owned record.",
            else:
              "Saved setup metadata is unavailable. Refresh to read it again, or use Saved setup to choose an owned record."
          )
        )

      assigns.selected_plan ->
        selected_plan_action(assigns)

      resume["state"] == "selected" ->
        recovery =
          resume["reference_status"] in ~w(stale unavailable) or
            resume["run_phase"] in ~w(blocked expired cancelled)

        setup_action(
          "company_setup_resume",
          if(recovery, do: "Review saved setup recovery", else: "Resume saved setup"),
          if(resume["origin"] == "sole",
            do: "Open your only saved setup at its current step.",
            else: "Open this saved setup at its current step."
          )
        )

      resume["state"] == "choose" ->
        setup_action(
          "company_setup_open",
          "Choose saved setup",
          "Multiple saved setup records appear in the bounded list of up to 20. Choose one explicitly; none is selected for Home."
        )

      !complete["profile"] ->
        action("profile", "Save company profile", "Start with a saved company name and context.")

      !complete["repository"] ->
        action("repository", "Add a repository", "Save at least one repository or service.")

      is_nil(scope) and length(assigns.projects) > 1 ->
        %{
          section: nil,
          focus: "company-guide-project",
          label: "Choose guide project",
          message:
            "Choose a saved project to scope prerequisites. No project is selected automatically."
        }

      !complete["project"] ->
        action(
          "project",
          "Save project membership",
          "Save a project with explicit repository membership."
        )

      !complete["evidence"] ->
        %{
          section: nil,
          corpus: true,
          label: "Select corpus and goal",
          message:
            "Choose an authorised corpus, project and assigned saved goal in corpus review. Manual per-document assignments are not required. Review the exact proposed claim and separately decide its plan."
        }

      plans == [] ->
        action(
          "plan",
          "Propose a plan",
          "Choose this project's saved context. Select the goal for each goal-based rule; milestones are optional future intent."
        )

      true ->
        action(
          "review",
          "Choose an exact plan",
          "Choose a saved plan."
        )
    end
  end

  defp selected_plan_action(assigns) do
    cond do
      assigns.selected_plan["status"] == "rejected" ->
        action(
          "review",
          "Propose a new plan version",
          "The rejection is immutable. Use Propose next package version to create a separate proposal."
        )

      assigns.selected_plan["status"] == "proposed" ->
        action(
          "review",
          "Review exact plan",
          "Review the selected immutable revision before recording an explicit decision."
        )

      assigns.plan_preflight == :eligible and !is_nil(assigns.built_artifact) ->
        %{
          section: nil,
          href: "/harnesses/" <> assigns.built_artifact["digest"],
          label: "Open your harness",
          message: "✓ Generated · Your saved files are ready to inspect."
        }

      assigns.plan_preflight == :eligible ->
        action(
          "build",
          "Build selected approved plan",
          "Current saved inputs passed preflight. Building checks the exact revision and context again."
        )

      true ->
        action("review", "Review current plan context", preflight_message(assigns.plan_preflight))
    end
  end

  defp setup_action(event, label, message),
    do: %{section: nil, setup_event: event, label: label, message: message}

  defp action(section, label, message), do: %{section: section, label: label, message: message}
  defp preflight_message({:blocked, message}), do: message

  defp preflight_message(_),
    do:
      "Current eligibility is unavailable. Reload saved records and review current evidence before building."

  attr :name, :string, required: true
  attr :title, :string, required: true
  attr :open, :boolean, required: true
  attr :target, :any, required: true
  attr :company_event_generation, :string, required: true
  slot :inner_block, required: true

  def section(assigns) do
    ~H"""
    <section class="company-disclosure" aria-labelledby={"company-toggle-" <> @name}>
      <h2>
        <button
          id={"company-toggle-" <> @name}
          type="button"
          class="company-section-toggle"
          aria-expanded={to_string(@open)}
          aria-controls={"company-section-" <> @name}
          phx-click="company_section_toggle"
          phx-value-company_event_generation={@company_event_generation}
          phx-value-section={@name}
          phx-target={@target}
        >
          <span>{@title}</span><span aria-hidden="true">{if @open, do: "−", else: "+"}</span>
        </button>
      </h2>
      <div id={"company-section-" <> @name} class="company-section-content" hidden={!@open}>
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end

  attr :data, :map, required: true
  attr :target, :any, required: true
  attr :company_event_generation, :string, required: true
  attr :assessment_event_generation, :string, default: nil
  attr :assessment_binding, :map, default: nil
  attr :connected, :boolean, default: false

  def workflow(assigns) do
    assigns =
      assigns
      |> assign(
        :data,
        assigns.data
        |> Map.put_new(:home_resume, %{"state" => "empty"})
        |> Map.put_new(:saved_harnesses, [])
        |> Map.put_new(:harnesses_unavailable, false)
      )
      |> assign(:assigned_goals, Map.get(assigns.data, :assigned_goals, []))
      |> assign(:assigned_goal_count, Map.get(assigns.data, :assigned_goal_count, 0))

    ~H"""
    <section id="company-guide" class="panel company-guide" aria-labelledby="company-guide-title">
      <p class="eyebrow">COMPANY HOME</p>
      <h2 id="company-guide-title">Build your company harness</h2>
      <p :if={@data.unavailable} id="company-guide-unavailable" role="status">
        Saved prerequisites are unavailable; completion and build guidance are withheld.
      </p>
      <div
        :if={!@data.unavailable && @data.home_resume["state"] != "empty"}
        id="company-home-resume"
        class="context-note"
        data-home-resume-state={@data.home_resume["state"]}
      >
        <%= if @data.home_resume["state"] == "selected" do %>
          <p id="company-home-resume-compact">
            {if @data.home_resume["origin"] == "sole", do: "Only saved setup", else: "Saved setup"} · {metadata_label(
              @data.home_resume["step"]
            )} · version {metadata_label(@data.home_resume["version"])}.
            <%= if @data.home_resume["run_id"] do %>
              Run {metadata_label(@data.home_resume["run_phase"])}.
            <% else %>
              No saved run; completion unknown.
            <% end %>
            <span :if={@data.home_resume["reference_status"] in ~w(stale unavailable)}>
              Saved references {@data.home_resume["reference_status"]}; review recovery.
            </span>
            <span :if={@data.home_resume["run_phase"] == "blocked"}>
              Review blocked run recovery in saved setup.
            </span>
            <span :if={
              @data.home_resume["failure_code"] &&
                @data.home_resume["run_phase"] not in ~w(blocked cancelled expired)
            }>
              Recovery status requires review in saved setup.
            </span>
          </p>
          <p
            :if={@data.home_resume["run_phase"] in ~w(cancelled expired)}
            id="company-home-resume-recovery"
          >
            Explicit recovery required in saved setup; reopening does not retry or create a new run.
          </p>
        <% else %>
          <p id="company-home-resume-status" role="status">
            <%= case @data.home_resume["state"] do %>
              <% "choose" -> %>
                Multiple saved setup records are available in the bounded list of up to 20. Choose one explicitly.
              <% "invalid" -> %>
                This saved setup address is invalid. Use Saved setup to choose a record.
              <% _ -> %>
                Saved setup metadata is unavailable. No previous summary is retained.
            <% end %>
          </p>
        <% end %>
      </div>
      <div class="company-guide-next">
        <p id="company-guide-next-message" role="status">{@data.next.message}</p>
        <.link
          :if={@data.next[:href]}
          id="company-guide-next"
          href={@data.next.href}
          class="button primary"
        >{@data.next.label}</.link>
        <button
          :if={@data.next[:setup_event]}
          id="company-guide-next"
          type="button"
          class="button primary"
          phx-click={@data.next.setup_event}
          phx-value-company_event_generation={@company_event_generation}
          phx-target={@target}
          disabled={!@connected}
        >{@data.next.label}</button>
        <button
          :if={@data.next[:corpus]}
          id="company-guide-next"
          type="button"
          class="button primary"
          phx-click="company_corpus_open"
          phx-value-company_event_generation={@company_event_generation}
          phx-target={@target}
          disabled={!@connected}
        >{@data.next.label}</button>
        <button
          :if={@data.next.section}
          id="company-guide-next"
          type="button"
          class="button primary"
          phx-click="company_guide_open"
          phx-value-company_event_generation={@company_event_generation}
          phx-value-section={@data.next.section}
          phx-target={@target}
          disabled={!@connected}
        >{@data.next.label}</button>
        <button
          :if={@data.next[:tab]}
          id="company-guide-next"
          type="button"
          class="button primary"
          phx-click="company_navigate"
          phx-value-company_event_generation={@company_event_generation}
          phx-value-tab={@data.next.tab}
          phx-target={@target}
          disabled={!@connected}
        >{@data.next.label}</button>
        <button
          :if={@data.next[:focus]}
          id="company-guide-next"
          type="button"
          class="button primary"
          phx-click="company_guide_open"
          phx-value-company_event_generation={@company_event_generation}
          phx-value-section="project"
          phx-target={@target}
          disabled={!@connected}
        >{@data.next.label}</button>
      </div>
      <p
        :if={@data.selected && match?({:blocked, _}, @data.preflight)}
        id="company-guide-plan-blocker"
        class="notice error"
        role="status"
      >
        {preflight_message(@data.preflight)}
      </p>
      <section id="company-home-harnesses" aria-labelledby="company-home-harnesses-title">
        <h3 id="company-home-harnesses-title"><span aria-hidden="true">▣</span> Your harnesses</h3>
        <p
          :if={!@data.harnesses_unavailable && @data.saved_harnesses != []}
          id="company-home-harnesses-scope"
        >
          Up to three saved harnesses, ordered by name. Choose one explicitly.
          <.link id="company-home-harnesses-all" href="/?view=package">View all saved harnesses</.link>
        </p>
        <p :if={@data.harnesses_unavailable} id="company-home-harnesses-unavailable" role="status">
          Saved harnesses are unavailable. Restore workspace access and reload.
        </p>
        <p
          :if={!@data.harnesses_unavailable && @data.saved_harnesses == []}
          id="company-home-harnesses-empty"
        >
          No saved harnesses yet. Built harnesses appear here so you can reopen or download them later.
        </p>
        <article
          :for={artifact <- Enum.take(@data.saved_harnesses, 3)}
          :if={!@data.harnesses_unavailable}
          id={"company-home-harness-" <> artifact["digest"]}
          class="artifact-row"
        >
          <strong>{artifact["name"]} · {artifact["version"]}</strong>
          <details id={"company-home-harness-identity-" <> artifact["digest"]}>
            <summary>Exact harness identity</summary>
            <code>{artifact["digest"]}</code>
          </details>
          <p class="field-help">✓ Saved · Eligibility checked when opened.</p>
          <div class="company-actions">
            <.link
              id={"company-home-harness-open-" <> artifact["digest"]}
              href={"/harnesses/" <> artifact["digest"]}
              class="button secondary"
            >Open your harness</.link>
            <a
              id={"company-home-harness-download-" <> artifact["digest"]}
              href={"/harnesses/" <> artifact["digest"] <> "/download"}
              class="button secondary"
              download
            >Download ZIP</a>
          </div>
        </article>
      </section>
      <details
        :if={!@data.unavailable && @data.home_resume["state"] == "selected"}
        id="company-home-resume-details"
        class="company-disclosure"
      >
        <summary id="company-home-resume-details-toggle" class="company-section-toggle">
          Saved setup details and usage
        </summary>
        <div class="company-section-content context-note">
          <p id="company-home-resume-origin">
            <%= if @data.home_resume["origin"] == "sole" do %>
              This is the only saved setup record.
            <% else %>
              This address identifies one exact saved setup.
            <% end %>
          </p>
          <p id="company-home-resume-identity">
            Saved setup <code>{@data.home_resume["id"]}</code>
            · version {metadata_label(@data.home_resume["version"])} · step {metadata_label(
              @data.home_resume["step"]
            )} · updated {metadata_label(@data.home_resume["updated_at"])}.
          </p>
          <p id="company-home-resume-reference">
            Saved reference status: {metadata_label(@data.home_resume["reference_status"])}.
            This observation does not establish readiness or grant approval.
          </p>
          <p id="company-home-resume-run">
            <%= if @data.home_resume["run_id"] do %>
              Run <code>{@data.home_resume["run_id"]}</code>
              · version {metadata_label(@data.home_resume["run_version"])} · phase {metadata_label(
                @data.home_resume["run_phase"]
              )}.
              <span :if={@data.home_resume["failure_code"]}>
                Recovery code: {@data.home_resume["failure_code"]}.
              </span>
            <% else %>
              No saved run is attached. Run completion is unknown.
            <% end %>
          </p>
          <p :if={@data.home_resume["run_id"]} id="company-home-resume-usage">
            Reservations: {metadata_label(@data.home_resume["requests_reserved"])} · pending: {metadata_label(
              @data.home_resume["pending_requests"]
            )} · uncertain: {metadata_label(@data.home_resume["uncertain_requests"])} · tokens accounted: {metadata_label(
              @data.home_resume["tokens_accounted"]
            )} · cost accounted (micro-USD): {metadata_label(
              @data.home_resume["cost_microusd_accounted"]
            )}.
          </p>
          <p id="company-home-resume-history">
            Predecessor uncertain requests in the returned history page: {metadata_label(
              @data.home_resume["predecessor_uncertain_requests"]
            )}.
            <%= if @data.home_resume["history_partial"] do %>
              History is partial; more predecessor records exist. This is not a historical total.
            <% else %>
              This count covers only the returned history page.
            <% end %>
          </p>
          <button
            id="company-home-resume-refresh"
            type="button"
            class="button secondary"
            phx-click="company_setup_refresh"
            phx-value-company_event_generation={@company_event_generation}
            phx-target={@target}
            disabled={!@connected}
          >Refresh saved setup</button>
        </div>
      </details>
      <details id="company-guide-context" class="company-disclosure">
        <summary id="company-guide-context-toggle" class="company-section-toggle">
          Company context and readiness
        </summary>
        <div class="company-section-content">
          <p :if={!@data.unavailable} id="company-guide-saved-summary">
            Company: {@data.profile_name || "No saved profile"}.
          </p>
          <p id="company-guide-scope">
            <strong>Guide project:</strong>
            <%= cond do %>
              <% @data.unavailable -> %>
                Unavailable
              <% @data.scope -> %>
                {@data.scope["payload"]["name"]}
              <% true -> %>
                Choose a saved project; none is selected for this guide.
            <% end %>
          </p>
          <p :if={!@data.unavailable} id="company-guide-assigned-goals">
            <strong>Assigned saved goals:</strong>
            <%= cond do %>
              <% is_nil(@data.scope) -> %>
                Choose a guide project to see its assignments.
              <% @assigned_goals != [] -> %>
                {Enum.map_join(@assigned_goals, "; ", &(&1["title"] || "Unavailable saved goal"))}
              <% @assigned_goal_count > 0 -> %>
                {@assigned_goal_count} assigned; saved goal details are unavailable.
              <% true -> %>
                No saved goals are assigned to this guide scope.
            <% end %>
            <span :if={
              @data.scope && @assigned_goals != [] && @assigned_goal_count > length(@assigned_goals)
            }>
              {@assigned_goal_count - length(@assigned_goals)} other assigned goal details are unavailable.
            </span>
          </p>
          <p id="company-guide-analysis-goal-note" class="field-help">
            No analysis goal is selected here. Choose it explicitly in corpus review.
          </p>
          <.form
            :if={@data.projects != []}
            for={%{}}
            id="company-guide-project-form"
            data-company-reset-token={@data.reset_token}
            phx-change="company_guide_project_change"
            phx-target={@target}
          >
            <input
              id="company-guide-event-generation"
              type="hidden"
              name="company_event_generation"
              value={@company_event_generation}
            />
            <label for="company-guide-project">Saved project for this guide</label>
            <select id="company-guide-project" name="guide[project_id]">
              <option value="" selected={is_nil(@data.scope)}>Choose a saved project</option>
              <option
                :for={project <- @data.projects}
                value={project["id"]}
                selected={@data.scope && @data.scope["id"] == project["id"]}
              >
                {project["payload"]["name"]}
              </option>
            </select>
          </.form>
          <HarnessForgeWeb.Company.ReadinessFacts.panel
            :if={@data[:readiness]}
            data={@data.readiness}
          />
        </div>
      </details>

      <details :if={@data.selected} id="company-guide-plan-context" class="company-disclosure">
        <summary id="company-guide-plan-context-toggle" class="company-section-toggle">
          Selected plan and task assessment
        </summary>
        <div class="company-section-content">
          <div :if={@data.selected} id="company-guide-selected-plan" class="context-note">
            <strong>Selected exact plan:</strong> {@data.selected["payload"]["name"]} · {@data.selected[
              "payload"
            ]["package_version"]} · {@data.selected["status"]}
            <details id="company-guide-selected-plan-identities">
              <summary>Exact plan identity</summary>
              <p>
                Plan {@data.selected["id"]} · revision <code>{@data.selected["revision_hash"]}</code>. Its lifecycle is independent of guide scope.
              </p>
            </details>
          </div>
          <div
            :if={assessment_ready?(@assessment_binding, @data.selected, @assessment_event_generation)}
            id="company-guide-assessment"
            class="context-note"
          >
            <p>
              Assess one representative task against this exact built package and one selected goal.
              Other package goals remain outside the assessment. A recorded assessment grants no runtime or release qualification.
            </p>
            <button
              id="company-guide-assess"
              type="button"
              class="button secondary"
              phx-click="company_assessment_open"
              phx-value-assessment_event_generation={@assessment_event_generation}
              phx-value-plan_id={@assessment_binding["plan_id"]}
              phx-value-expected_plan_revision_hash={
                @assessment_binding["expected_plan_revision_hash"]
              }
              phx-value-artifact_digest={@assessment_binding["artifact_digest"]}
            >Assess representative task</button>
          </div>
        </div>
      </details>
      <details id="company-guide-details" class="company-guide-details">
        <summary id="company-guide-details-toggle">Review saved setup and plan steps</summary>
        <p class="company-guide-summary">
          Turn company evidence and future goals into a reviewed harness, one deliberate step at a time.
        </p>
        <p :if={!@data.unavailable} id="company-guide-repository-count">
          {@data.repository_count} saved repositories or services.
        </p>
        <p>
          Saved records determine this guide. Draft text and connected accounts do not complete prerequisites or grant approval. Assigned goals express future intent.
        </p>
        <div class="company-guide-counts" aria-label="Workspace-wide review queues">
          <p id="company-claim-review-count">
            <strong>Claims to review:</strong> {count_label(@data.claim_review_count)}
            <small>workspace-wide</small>
          </p>
          <p id="company-plan-review-count">
            <strong>Plans to review:</strong> {count_label(@data.plan_review_count)}
            <small>workspace-wide</small>
          </p>
        </div>
        <p :if={@data.scope && !@data.unavailable}>
          Guide project <code>{@data.scope["id"]}</code>
          · {@data.claim_count} eligible approved claims.
        </p>
        <ol class="company-guide-tasks" aria-label="Saved prerequisites and plan steps">
          <li :for={task <- @data.tasks} class="company-guide-task" data-saved={to_string(task.saved)}>
            <button
              id={"company-guide-task-" <> task.name}
              type="button"
              phx-click="company_guide_open"
              phx-value-company_event_generation={@company_event_generation}
              phx-value-section={task.name}
              phx-target={@target}
            >{task.title}</button>
            <span>{task.status}</span>
          </li>
        </ol>
      </details>
    </section>
    """
  end

  defp task_status(_, _, true), do: "Unavailable"
  defp task_status("review", true, _), do: "Exact plan approved"
  defp task_status("build", true, _), do: "Current inputs checked"
  defp task_status("evidence", true, _), do: "Eligible approved claims"
  defp task_status(_, true, _), do: "Saved"
  defp task_status(_, false, _), do: "To review"

  defp count_label(nil), do: "Unavailable"
  defp count_label(count), do: Integer.to_string(count)
  defp metadata_label(nil), do: "Unknown"
  defp metadata_label(value), do: to_string(value)

  # The root supplies this binding only after verifying its durable package binding.
  # This projection checks correspondence; it cannot grant assessment authority.
  defp assessment_ready?(binding, selected, generation)
       when is_map(binding) and is_map(selected) and is_binary(generation) do
    selected["status"] == "approved" and selected["superseded"] == false and
      binding["plan_id"] == selected["id"] and
      binding["expected_plan_revision_hash"] == selected["revision_hash"] and
      is_binary(binding["artifact_digest"]) and binding["artifact_digest"] != "" and
      generation != ""
  end

  defp assessment_ready?(_, _, _), do: false
end
