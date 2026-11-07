defmodule HarnessForgeWeb.Company.Plan do
  @moduledoc false
  use HarnessForgeWeb, :html
  alias HarnessForge.Goals
  alias HarnessForgeWeb.Company.Catalog
  alias HarnessForgeWeb.Company.Guide

  attr :target, :any, required: true
  attr :company_event_generation, :string, required: true
  attr :profile, :any, required: true
  attr :sources, :list, required: true
  attr :goals, :list, required: true
  attr :repositories, :list, required: true
  attr :projects, :list, required: true
  attr :approved, :list, required: true
  attr :plans, :list, required: true
  attr :draft, :map, required: true
  attr :selected, :any, required: true
  attr :artifacts, :list, required: true
  attr :built, :any, required: true
  attr :diff, :any, required: true
  attr :open_sections, :any, required: true
  attr :form_error, :any, default: nil
  attr :plan_preflight, :any, default: :none
  attr :company_reset_token, :integer, required: true
  attr :assessment_event_generation, :string, default: nil
  attr :assessment_binding, :map, default: nil

  def builder(assigns) do
    project = Enum.find(assigns.projects, &(&1["id"] == assigns.draft["project_id"]))
    source_ids = applicable(assigns.profile, project, "source_ids")

    name_error =
      case assigns.form_error do
        %{section: "plan", field: "name", message: message} when is_binary(message) -> message
        _ -> nil
      end

    revision_ids =
      assigns.sources
      |> Enum.filter(&(&1["id"] in source_ids))
      |> Enum.map(&get_in(&1, ["latest_revision", "id"]))

    goal_ids = applicable(assigns.profile, project, "goal_ids")
    repository_ids = if project, do: project["payload"]["repository_ids"], else: []

    assigns =
      assigns
      |> assign(:project, project)
      |> assign(:name_error, name_error)
      |> assign(
        :project_repositories,
        Enum.filter(assigns.repositories, &(&1["id"] in repository_ids))
      )
      |> assign(:project_goals, Enum.filter(assigns.goals, &(&1["id"] in goal_ids)))
      |> assign(
        :eligible_claims,
        Enum.filter(
          assigns.approved,
          &claim_in_scope?(&1, revision_ids, goal_ids, assigns.profile, project)
        )
      )

    ~H"""
    <Guide.section
      name="evidence"
      title="4. Claim review"
      open={MapSet.member?(@open_sections, "evidence")}
      target={@target}
      company_event_generation={@company_event_generation}
    >
      <div class="company-step" id="company-evidence-step">
        <Catalog.form_error section="evidence" error={@form_error} />
        <h3>Review the claims you intend to use</h3>
        <p>
          Review each claim and its source citation or saved goal in Evidence. Only an eligible, explicitly approved exact claim revision can be selected below. Company setup and plan approval cannot approve a claim.
        </p>
        <p :if={@approved == []} id="company-claims-empty" class="context-note">
          No approved claims are available. Capture a source or save a goal, propose a claim and review its exact revision first.
        </p>
        <button
          id="company-review-evidence"
          phx-click="company_navigate"
          phx-value-company_event_generation={@company_event_generation}
          phx-value-tab="evidence"
          phx-target={@target}
          class="button secondary"
        >Review claims in Evidence</button>
      </div>
    </Guide.section>

    <Guide.section
      name="plan"
      title="5. Propose a plan"
      open={MapSet.member?(@open_sections, "plan")}
      target={@target}
      company_event_generation={@company_event_generation}
    >
      <div class="company-step" id="company-plan-step">
        <h3>Choose an exact package plan</h3>
        <p>
          Choose a project, repositories, current eligible exact approved claims and workflow presets. Select the saved goal for each goal-based rule. Corpus claims need no manual per-document assignments. Milestones are optional future intent. Saving creates a proposed plan; each exact version needs its own separate decision.
        </p>
        <p :if={@profile == nil || @projects == []} id="company-plan-blocked" class="context-note">
          Save a company profile and a project before proposing a plan.
        </p>
        <.form
          for={%{}}
          id="company-plan-form"
          data-company-reset-token={@company_reset_token}
          phx-change="company_plan_change"
          phx-submit="company_plan_create"
          phx-target={@target}
          class="stack"
        >
          <input type="hidden" name="company_event_generation" value={@company_event_generation} />
          <Catalog.form_error :if={is_nil(@name_error)} section="plan" error={@form_error} />
          <input
            id="company-plan-supersedes"
            type="hidden"
            name="plan[supersedes_id]"
            value={@draft["supersedes_id"]}
          />
          <p :if={@draft["supersedes_id"] != ""} id="company-plan-successor-note" class="context-note">
            This proposal succeeds plan {@draft["supersedes_id"]}. Earlier approved versions retain their own approval.
          </p>
          <label for="company-plan-name">Package name</label><input
            id="company-plan-name"
            name="plan[name]"
            value={@draft["name"]}
            required
            maxlength="64"
            aria-describedby={
              if @name_error,
                do: "company-plan-name-help company-plan-name-error",
                else: "company-plan-name-help"
            }
            aria-invalid={if @name_error, do: "true", else: nil}
            placeholder="company-project-harness"
          />
          <p id="company-plan-name-help" class="field-help">
            Use 1–64 characters: start with a lowercase letter, then use only lowercase letters, numbers, hyphens or underscores. Example: company-project-harness. Spaces and other punctuation are not allowed.
          </p>
          <p :if={@name_error} id="company-plan-name-error" class="notice error" role="alert">
            {@name_error}
          </p>
          <label for="company-plan-version">Package version</label><input
            id="company-plan-version"
            name="plan[package_version]"
            value={@draft["package_version"]}
            required
            maxlength="128"
            placeholder="0.1.0"
          />
          <label for="company-plan-project">Project</label>
          <select id="company-plan-project" name="plan[project_id]" required>
            <option value="" selected={@draft["project_id"] == ""}>Choose a saved project</option>
            <option
              :for={project <- @projects}
              value={project["id"]}
              selected={project["id"] == @draft["project_id"]}
            >
              {project["payload"]["name"]}
            </option>
          </select>
          <Catalog.choices
            id="company-plan-repositories"
            name="plan[repository_ids][]"
            label="Repositories selected for this package · select at least one"
            options={Catalog.repository_options(@project_repositories)}
            selected={@draft["repository_ids"]}
            empty="Choose a project to see its repositories."
          />
          <Catalog.choices
            id="company-plan-claims"
            name="plan[claim_refs][]"
            label="Approved exact claim revisions · select deliberately"
            options={claim_options(@eligible_claims, @goals)}
            selected={@draft["claim_refs"]}
            empty="No current eligible approved claims match this project and its saved goals. Corpus claims do not require manual source assignments. Review the exact claim and selected context in Evidence."
          />
          <Catalog.choices
            id="company-plan-goals"
            name="plan[goal_ids][]"
            label="Selected goals · required for claims based on them; selection grants no approval"
            options={Catalog.goal_options(@project_goals)}
            selected={@draft["goal_ids"]}
            empty="No goals are assigned to this project or company."
          />
          <Catalog.choices
            id="company-plan-presets"
            name="plan[template_ids][]"
            label="Workflow presets · advisory instructions only"
            options={preset_options()}
            selected={@draft["template_ids"]}
          />
          <label for="company-plan-runtime">Coding agent target</label>
          <select id="company-plan-runtime" name="plan[runtime]">
            <option value="opencode" selected={@draft["runtime"] == "opencode"}>OpenCode</option>
            <option value="codex" selected={@draft["runtime"] == "codex"}>Codex CLI</option>
            <option value="claude_code" selected={@draft["runtime"] == "claude_code"}>
              Claude Code
            </option>
          </select>
          <label for="company-plan-runtime-version">Exact target version</label><input
            id="company-plan-runtime-version"
            name="plan[runtime_version]"
            value={@draft["runtime_version"]}
            required
            maxlength="128"
          />
          <p class="field-help">
            Supported profiles: OpenCode 1.x, Codex 0.156.0 and Claude Code 2.1.311. Use unqualified for a native preview. All three targets support export. Building does not run an agent; managed Codex and Claude execution is unavailable.
          </p>
          <div class="company-field-row">
            <div>
              <label for="company-plan-max-turns">Maximum agent turns</label><input
                id="company-plan-max-turns"
                type="number"
                min="1"
                max="1000"
                name="plan[execution][max_turns]"
                value={@draft["execution"]["max_turns"]}
                required
              />
            </div>
            <div>
              <label for="company-plan-timeout">Time limit in seconds</label><input
                id="company-plan-timeout"
                type="number"
                min="1"
                max="86400"
                name="plan[execution][timeout_seconds]"
                value={@draft["execution"]["timeout_seconds"]}
                required
              />
            </div>
          </div>
          <fieldset id="company-plan-milestones" class="company-milestones">
            <legend>Proposed milestones · optional</legend>
            <p class="field-help">
              Optional future work. Each milestone states its acceptance check and may depend on earlier milestones. Dependencies must form an acyclic plan.
            </p>
            <p :if={@draft["milestones"] == []} id="company-milestones-empty" class="field-help">
              No milestones proposed.
            </p>
            <.milestone
              :for={{row, index} <- Enum.with_index(@draft["milestones"])}
              row={row}
              index={index}
              rows={@draft["milestones"]}
              goals={@project_goals}
              selected_goals={@draft["goal_ids"]}
              target={@target}
              company_event_generation={@company_event_generation}
            />
            <button
              id="company-milestone-add"
              type="button"
              phx-click="company_milestone_add"
              phx-value-company_event_generation={@company_event_generation}
              phx-target={@target}
              class="button secondary"
              disabled={length(@draft["milestones"]) >= 100}
            >Add proposed milestone</button>
          </fieldset>
          <div class="company-actions">
            <button
              id="company-plan-save"
              type="submit"
              class="button primary"
              disabled={@profile == nil || @projects == []}
            >Save proposed plan for review</button>
            <Catalog.discard
              form="plan"
              target={@target}
              company_event_generation={@company_event_generation}
            />
          </div>
        </.form>
      </div>
    </Guide.section>

    <Guide.section
      name="review"
      title="6. Review an exact plan"
      open={MapSet.member?(@open_sections, "review")}
      target={@target}
      company_event_generation={@company_event_generation}
    >
      <div class="company-step" id="company-plan-review-step" tabindex="-1">
        <h3>Make a separate plan decision</h3>
        <Catalog.form_error section="review" error={@form_error} />
        <p :if={@plans == []} id="company-plans-empty" class="context-note">
          No plans saved. A new plan starts proposed and cannot be built until you approve its exact revision.
        </p>
        <div class="company-records">
          <article :for={plan <- @plans} id={"company-plan-#{plan["id"]}"} class="company-record">
            <strong>{plan["payload"]["name"]} · {plan["payload"]["package_version"]}</strong>
            <span class={["pill", plan["status"]]}>{String.upcase(plan["status"])}</span>
            <span :if={plan["superseded"]} class="pill neutral">HAS SUCCESSOR</span>
            <button
              id={"company-plan-select-#{plan["id"]}"}
              phx-click="company_plan_select"
              phx-value-company_event_generation={@company_event_generation}
              phx-value-id={plan["id"]}
              phx-target={@target}
              aria-pressed={@selected != nil && @selected["id"] == plan["id"]}
              class="button secondary"
            >{if @selected && @selected["id"] == plan["id"],
              do: "Review selected plan",
              else: "Review exact plan"}</button>
          </article>
        </div>
        <.review
          :if={@selected}
          selected={@selected}
          repositories={@repositories}
          projects={@projects}
          approved={@approved}
          goals={@goals}
          target={@target}
          company_event_generation={@company_event_generation}
          company_reset_token={@company_reset_token}
        />
      </div>
    </Guide.section>

    <Guide.section
      name="build"
      title="7. Build and hand off"
      open={MapSet.member?(@open_sections, "build")}
      target={@target}
      company_event_generation={@company_event_generation}
    >
      <div class="company-step" id="company-build-step" tabindex="-1">
        <h3>Build the selected approved plan</h3>
        <Catalog.form_error section="build" error={@form_error} />
        <p>
          Building checks the exact approval and current selected context again. It creates an immutable package; export, evaluation and release remain separate.
        </p>
        <p :if={is_nil(@selected)} id="company-build-blocked" class="context-note">
          Select a saved plan above to see its approval and build controls.
        </p>
        <.form
          :if={@selected}
          for={%{}}
          id="company-plan-build-form"
          data-company-reset-token={@company_reset_token}
          phx-submit="company_plan_build"
          phx-target={@target}
          class="stack"
        >
          <input type="hidden" name="company_event_generation" value={@company_event_generation} />
          <input
            id="company-build-plan-id"
            type="hidden"
            name="plan_build[id]"
            value={@selected["id"]}
          />
          <input
            id="company-build-plan-hash"
            type="hidden"
            name="plan_build[expected_revision_hash]"
            value={@selected["revision_hash"]}
          />
          <p>
            Selected:
            <strong>{@selected["payload"]["name"]} · {@selected["payload"]["package_version"]}</strong>
            · {@selected["status"]}
          </p>
          <p class="field-help">Exact plan revision <code>{@selected["revision_hash"]}</code></p>
          <p
            :if={@selected["status"] != "approved"}
            id="company-plan-needs-approval"
            class="context-note"
          >
            This plan needs an explicit approval before it can be built.
          </p>
          <div
            :if={match?({:blocked, _}, @plan_preflight)}
            id="company-plan-current-context-blocked"
            class="context-note"
          >
            <strong>Current saved context needs review</strong>
            <p>{preflight_reason(@plan_preflight)}</p>
            <button
              type="button"
              phx-click="company_guide_open"
              phx-value-company_event_generation={@company_event_generation}
              phx-value-section="review"
              phx-target={@target}
              class="button secondary"
            >Review plan and propose next version</button>
          </div>
          <p
            :if={@selected["status"] == "approved" && @plan_preflight == :none}
            id="company-plan-preflight-unavailable"
            class="context-note"
          >
            Current build eligibility is unconfirmed. Select this exact saved plan again to check its current context.
          </p>
          <p
            :if={@plan_preflight == :eligible}
            id="company-plan-current-context-ready"
            class="field-help"
          >
            Current saved inputs passed the build check. Building checks them again; runtime availability and task qualification remain separate.
          </p>
          <button
            id="company-plan-build"
            type="submit"
            disabled={@selected["status"] != "approved" || @plan_preflight != :eligible}
            phx-disable-with="Building…"
            class="button primary"
          >Build this approved plan</button>
        </.form>
        <article :if={@built} id="company-built-package" class="context-note">
          <h3>Your harness was generated</h3>
          <p>{artifact_name(@built)} · {artifact_version(@built)}</p>
          <p>Native target: {get_in(@built, ["spec", "spec", "runtime", "name"])}</p>
          <div class="company-actions">
            <.link
              id="company-built-open"
              href={"/harnesses/" <> @built["digest"]}
              class="button primary"
            >Open your harness</.link>
            <a
              id="company-built-download"
              href={"/harnesses/" <> @built["digest"] <> "/download"}
              class="button secondary"
              download
            >Download ZIP</a>
          </div>
          <p>
            Inspect the exact generated files, then download them in your browser. Building does not establish representative-task success or release qualification.
          </p>
          <details>
            <summary>Exact harness identity</summary><p>
              Package digest <code>{@built["digest"]}</code>
            </p>
          </details>
          <div :if={
            assessment_ready?(@assessment_binding, @selected, @built, @assessment_event_generation)
          }>
            <p>
              Assess one representative task and one explicitly selected goal against this exact package.
              Other package goals remain outside this assessment; owner observations grant no runtime or release qualification.
            </p>
            <button
              id="company-built-assess"
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
        </article>
        <.form
          :if={length(@artifacts) >= 2}
          for={%{}}
          id="company-diff-form"
          data-company-reset-token={@company_reset_token}
          phx-submit="company_package_diff"
          phx-target={@target}
          class="stack"
        >
          <input type="hidden" name="company_event_generation" value={@company_event_generation} />
          <h3>Compare package versions</h3>
          <label for="company-diff-left">Baseline package</label><select
            id="company-diff-left"
            name="company_diff[left]"
            required
          ><option :for={artifact <- @artifacts} value={artifact["digest"]}>
            {artifact_name(artifact)} · {artifact_version(artifact)} · {artifact["digest"]}
          </option></select>
          <label for="company-diff-right">Candidate package</label><select
            id="company-diff-right"
            name="company_diff[right]"
            required
          ><option :for={artifact <- @artifacts} value={artifact["digest"]}>
            {artifact_name(artifact)} · {artifact_version(artifact)} · {artifact["digest"]}
          </option></select>
          <button id="company-diff-compare" type="submit" class="button secondary">Compare exact package versions</button>
        </.form>
        <div :if={@diff} id="company-diff-result" class="company-diff" role="status">
          <h3>Package version differences</h3>
          <p>Baseline <code>{@diff["left_digest"]}</code></p><p>
            Candidate <code>{@diff["right_digest"]}</code>
          </p>
          <div :for={{label, key} <- [{"Files", "files"}, {"Approved rules", "rules"}]}>
            <h4>{label}</h4>
            <p :for={action <- ~w(added removed changed)}>
              <strong>{String.capitalize(action)}:</strong> {diff_names(@diff[key][action])}
            </p>
          </div>
        </div>
        <div class="company-actions company-next-steps">
          <button
            id="company-open-packages"
            phx-click="company_navigate"
            phx-value-company_event_generation={@company_event_generation}
            phx-value-tab="package"
            phx-target={@target}
            class="button secondary"
          >Open packages and export</button>
          <button
            id="company-open-evaluations"
            phx-click="company_navigate"
            phx-value-company_event_generation={@company_event_generation}
            phx-value-tab="evaluations"
            phx-target={@target}
            class="button secondary"
          >Evaluate built packages</button>
          <button
            id="company-open-releases"
            phx-click="company_navigate"
            phx-value-company_event_generation={@company_event_generation}
            phx-value-tab="releases"
            phx-target={@target}
            class="button secondary"
          >Review release gates</button>
        </div>
      </div>
    </Guide.section>
    """
  end

  attr :row, :map, required: true
  attr :index, :integer, required: true
  attr :rows, :list, required: true
  attr :goals, :list, required: true
  attr :selected_goals, :list, required: true
  attr :target, :any, required: true
  attr :company_event_generation, :string, required: true

  defp milestone(assigns) do
    assigns = assign(assigns, :prefix, "company-milestone-#{assigns.index}")

    ~H"""
    <div id={@prefix} class="company-milestone stack">
      <h4>Proposed milestone {@index + 1}</h4>
      <label for={@prefix <> "-id"}>Milestone identifier</label><input
        id={@prefix <> "-id"}
        name={"plan[milestones][#{@index}][id]"}
        value={@row["id"]}
        required
        maxlength="128"
      />
      <label for={@prefix <> "-title"}>Milestone title</label><input
        id={@prefix <> "-title"}
        name={"plan[milestones][#{@index}][title]"}
        value={@row["title"]}
        required
        maxlength="256"
      />
      <Catalog.choices
        id={@prefix <> "-goals"}
        name={"plan[milestones][#{@index}][goal_ids][]"}
        label="Selected goals this milestone advances"
        options={Catalog.goal_options(Enum.filter(@goals, &(&1["id"] in @selected_goals)))}
        selected={@row["goal_ids"]}
        empty="Select plan goals above first."
      />
      <Catalog.choices
        id={@prefix <> "-dependencies"}
        name={"plan[milestones][#{@index}][depends_on][]"}
        label="Depends on milestones"
        options={milestone_options(@rows, @index)}
        selected={@row["depends_on"]}
        empty="Add another milestone to declare a dependency."
      />
      <label for={@prefix <> "-acceptance"}>Acceptance criteria</label><textarea
        id={@prefix <> "-acceptance"}
        name={"plan[milestones][#{@index}][acceptance]"}
        required
        maxlength="4096"
      >{@row["acceptance"]}</textarea>
      <label for={@prefix <> "-evaluation"}>How will you evaluate it?</label><textarea
        id={@prefix <> "-evaluation"}
        name={"plan[milestones][#{@index}][evaluation_method]"}
        required
        maxlength="4096"
      >{@row["evaluation_method"]}</textarea>
      <label for={@prefix <> "-version"}>Target version</label><input
        id={@prefix <> "-version"}
        name={"plan[milestones][#{@index}][target_version]"}
        value={@row["target_version"]}
        maxlength="128"
      />
      <button
        id={@prefix <> "-remove"}
        type="button"
        phx-click="company_milestone_remove"
        phx-value-company_event_generation={@company_event_generation}
        phx-value-index={@index}
        phx-target={@target}
        class="button secondary"
        aria-label={"Remove milestone #{@index + 1}"}
      >Remove milestone</button>
    </div>
    """
  end

  attr :selected, :map, required: true
  attr :repositories, :list, required: true
  attr :projects, :list, required: true
  attr :approved, :list, required: true
  attr :goals, :list, required: true
  attr :target, :any, required: true
  attr :company_event_generation, :string, required: true
  attr :company_reset_token, :integer, required: true

  defp review(assigns) do
    assigns = assign(assigns, :payload, assigns.selected["payload"])

    ~H"""
    <article id="company-plan-review" class="company-plan-review">
      <h3>{@payload["name"]} · {@payload["package_version"]}</h3>
      <p>Status: <strong>{@selected["status"]}</strong></p>
      <p :if={@selected["status"] == "rejected"} class="context-note">
        This decision is final for this exact revision. Propose a new version to make changes and request a new decision.
      </p>
      <p>
        Exact plan revision <code id="company-displayed-plan-hash">{@selected["revision_hash"]}</code>
      </p>
      <dl>
        <dt>Plan identifier</dt><dd>{@selected["id"]}</dd>
        <dt>Project</dt><dd>
          {project_name(@payload["project_id"], @projects)} · {@payload["project_id"]}
        </dd>
        <dt>Selected repositories</dt><dd>
          {Catalog.repository_names(@payload["repository_ids"], @repositories)}
        </dd>
        <dt>Target</dt><dd>{@payload["runtime"]} · {@payload["runtime_version"]}</dd>
        <dt>Limits</dt><dd>
          {@payload["execution"]["max_turns"]} turns · {@payload["execution"]["timeout_seconds"]} seconds
        </dd>
        <dt>Workflow presets</dt><dd>{Enum.join(@payload["template_ids"], ", ")}</dd>
      </dl>
      <h4>Exact approved claims selected</h4>
      <div :for={ref <- @payload["claim_refs"]} class="company-exact-reference">
        <p>{pinned_claim_text(ref, @approved)}</p>
        <p>{pinned_claim_origin(ref, @approved, @goals)}</p>
        <p>Claim {ref["id"]} · revision <code>{ref["revision_hash"]}</code></p>
      </div>
      <h4>Selected goals · selection grants no approval</h4>
      <p :for={id <- @payload["goal_ids"]}>{goal_description(id, @goals)} · {id}</p>
      <p :if={@payload["goal_ids"] == []}>No goals selected.</p>
      <h4>Proposed milestones</h4>
      <article :for={row <- @payload["milestones"]} class="company-record">
        <strong>{row["id"]} · {row["title"]}</strong>
        <p>
          Goals: {if row["goal_ids"] == [],
            do: "None",
            else: Enum.map_join(row["goal_ids"], "; ", &goal_description(&1, @goals))}
        </p>
        <p>
          Depends on: {if row["depends_on"] == [],
            do: "None",
            else: Enum.join(row["depends_on"], ", ")}
        </p>
        <p>Acceptance: {row["acceptance"]}</p><p>Evaluation: {row["evaluation_method"]}</p><p>
          Target version: {row["target_version"]}
        </p>
      </article>
      <p :if={@payload["milestones"] == []}>No milestones proposed.</p>
      <p class="field-help">
        This decision applies only to this saved plan revision. It grants no source access, claim approval, execution or release authority.
      </p>
      <.form
        :if={@selected["status"] == "proposed" && !@selected["superseded"]}
        for={%{}}
        id="company-plan-decision-form"
        data-company-reset-token={@company_reset_token}
        phx-submit="company_plan_decide"
        phx-target={@target}
        class="stack"
      >
        <input type="hidden" name="company_event_generation" value={@company_event_generation} />
        <input
          id="company-decision-plan-id"
          type="hidden"
          name="plan_decision[id]"
          value={@selected["id"]}
        />
        <input
          id="company-decision-plan-hash"
          type="hidden"
          name="plan_decision[expected_revision_hash]"
          value={@selected["revision_hash"]}
        />
        <label for="company-plan-decision">Decision on this exact plan</label><select
          id="company-plan-decision"
          name="plan_decision[decision]"
        ><option value="approve">Approve this exact plan revision</option><option value="reject">
          Reject this exact plan revision
        </option></select>
        <button id="company-plan-decide" type="submit" class="button primary">Record exact plan decision</button>
      </.form>
      <button
        id="company-plan-successor"
        phx-click="company_plan_successor"
        phx-value-company_event_generation={@company_event_generation}
        phx-value-id={@selected["id"]}
        phx-target={@target}
        class="button secondary"
        disabled={@selected["superseded"]}
      >Propose next package version</button>
    </article>
    """
  end

  defp applicable(profile, project, key) do
    Enum.uniq(
      (get_in(profile || %{}, ["payload", key]) || []) ++
        (get_in(project || %{}, ["payload", key]) || [])
    )
  end

  # approved is supplied by Evidence's shared current-authority validator.
  # This projection adds only the chosen company's/project's scope.
  defp claim_in_scope?(claim, revision_ids, goal_ids, profile, project) do
    case claim["basis"] do
      %{"kind" => "company_analysis", "version" => 2, "goal_id" => id, "context" => context} ->
        # Current manifest authority is already checked by Evidence.approved_claims/0.
        # Corpus evidence does not require legacy manual source assignments.
        project != nil && profile != nil && id in goal_ids &&
          context["project"] == Map.take(project, ~w(id content_hash)) &&
          context["profile"] == Map.take(profile, ~w(id content_hash))

      %{
        "kind" => "company_analysis",
        "version" => 1,
        "goal_id" => id,
        "context" => %{"sources" => refs} = context
      }
      when is_list(refs) ->
        project != nil && profile != nil && id in goal_ids &&
          context["project"] == Map.take(project, ~w(id content_hash)) &&
          context["profile"] == Map.take(profile, ~w(id content_hash)) &&
          Enum.all?(refs, &(&1["revision_id"] in revision_ids))

      %{"kind" => "goal", "goal_id" => id} ->
        id in goal_ids

      nil ->
        citations = claim["citations"] || []
        citations != [] && Enum.all?(citations, &(&1["revision_id"] in revision_ids))

      _ ->
        false
    end
  end

  defp preflight_reason({:blocked, reason}), do: reason

  defp claim_options(claims, goals),
    do:
      Enum.map(
        claims,
        &%{
          key: &1["id"],
          value: &1["id"] <> ":" <> &1["revision_hash"],
          label: &1["text"],
          detail: claim_origin(&1, goals) <> " · Exact approved revision " <> &1["revision_hash"]
        }
      )

  defp preset_options,
    do: [
      %{
        key: "reviewed-change-v1",
        value: "reviewed-change-v1",
        label: "Reviewed change",
        detail: "Plan a bounded change with explicit review."
      },
      %{
        key: "reuse-before-build-v1",
        value: "reuse-before-build-v1",
        label: "Reuse before building",
        detail: "Consult the selected catalogue and explain the reuse choice."
      }
    ]

  defp milestone_options(rows, index),
    do:
      rows
      |> Enum.with_index()
      |> Enum.reject(fn {_, i} -> i == index end)
      |> Enum.map(fn {row, i} ->
        %{key: Integer.to_string(i), value: row["id"], label: row["id"] <> " · " <> row["title"]}
      end)

  defp artifact_name(artifact),
    do: get_in(artifact, ["spec", "metadata", "name"]) || "Harness package"

  defp artifact_version(artifact),
    do: get_in(artifact, ["spec", "metadata", "version"]) || "built"

  # Root has already resolved the durable binding; these are display correspondence checks.
  defp assessment_ready?(binding, selected, built, generation)
       when is_map(binding) and is_map(selected) and is_map(built) and is_binary(generation) do
    selected["status"] == "approved" and selected["superseded"] == false and
      binding["plan_id"] == selected["id"] and
      binding["expected_plan_revision_hash"] == selected["revision_hash"] and
      binding["artifact_digest"] == built["digest"] and generation != ""
  end

  defp assessment_ready?(_, _, _, _), do: false

  defp project_name(id, projects) do
    case Enum.find(projects, &(&1["id"] == id)) do
      nil -> "Unavailable project"
      project -> project["payload"]["name"]
    end
  end

  defp pinned_claim_text(ref, approved) do
    case Enum.find(
           approved,
           &(&1["id"] == ref["id"] && &1["revision_hash"] == ref["revision_hash"])
         ) do
      nil ->
        "This exact approved claim revision is no longer available. Review current evidence before building."

      claim ->
        claim["text"]
    end
  end

  defp pinned_claim_origin(ref, approved, goals) do
    case Enum.find(
           approved,
           &(&1["id"] == ref["id"] && &1["revision_hash"] == ref["revision_hash"])
         ) do
      nil -> "Current claim origin is unavailable."
      claim -> claim_origin(claim, goals)
    end
  end

  defp claim_origin(%{"basis" => %{"kind" => "goal"} = basis}, goals) do
    case Enum.find(goals, fn goal ->
           goal["id"] == basis["goal_id"] &&
             Goals.content_hash(goal) == basis["goal_content_hash"]
         end) do
      nil -> "Goal-based rule · Saved goal unavailable or changed"
      goal -> "Goal-based rule · Goal: " <> goal_description(goal["id"], [goal])
    end
  end

  defp claim_origin(%{"basis" => %{"kind" => "company_analysis"} = basis}, goals),
    do:
      "Company analysis · captured history and saved future intent · Goal: " <>
        goal_description(basis["goal_id"], goals) <>
        " · Includes every examined source, including uncited context."

  defp claim_origin(_, _), do: "Sourced claim"

  defp goal_description(id, goals) do
    case Enum.find(goals, &(&1["id"] == id)) do
      nil ->
        "Unavailable goal"

      goal ->
        goal["title"] <> " · Owner: " <> goal["owner"] <> " · Acceptance: " <> goal["acceptance"]
    end
  end

  defp diff_names([]), do: "None"
  defp diff_names(values) when is_list(values), do: Enum.map_join(values, ", ", &to_string/1)
  defp diff_names(_), do: "None"
end
