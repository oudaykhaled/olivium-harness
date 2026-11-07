defmodule HarnessForgeWeb.Company.Assessment do
  @moduledoc "Stateless, escaped presentation for an exact-package owner-reported assessment."
  use HarnessForgeWeb, :html

  alias HarnessForgeWeb.Company.Analysis

  @qualification "Owner-reported assessment; not independently verified; no runtime or release qualification."
  @stages [
    {"scope", "Choose scope"},
    {"rubric", "Write task and freeze rubric"},
    {"results", "Record observations"},
    {"receipt", "Review recorded assessment"}
  ]
  @errors %{
    "invalid_input" =>
      "Review the explicit choices and field values. Use valid identifiers and enter every required field; unsupported fields are refused.",
    "input_too_large" =>
      "Reduce the entered text or obligation count. Each text field allows 1,000 Unicode characters and 4,000 UTF-8 bytes; the complete canonical input allows 128 KiB. Your entered text is retained.",
    "rubric_limit" =>
      "This workspace has reached its limit of 100 rubric revisions, including history. No revision was removed or saved.",
    "assessment_limit" =>
      "This workspace has reached its limit of 1,000 recorded assessments, including history. No assessment was removed or saved.",
    "not_found" =>
      "This assessment record or package is unavailable in this workspace. Reload saved records before continuing.",
    "stale_plan_revision" =>
      "The selected plan revision changed. Review the exact current plan and choose an eligible built package again.",
    "superseded_plan" =>
      "This plan has a successor. Review and explicitly approve an eligible exact plan and choose its built package.",
    "plan_not_approved" =>
      "Approve the exact selected plan revision separately before assessing its built package.",
    "package_not_bound" =>
      "This package is not bound to the exact selected plan revision. Review and build that approved plan before continuing.",
    "invalid_package" =>
      "The saved package could not be verified. Review the exact approved plan and rebuild its package before continuing.",
    "goal_not_selected" =>
      "Choose one saved goal selected in this exact package. Other goals remain outside this assessment.",
    "stale_goal" =>
      "The saved goal changed. Review current intent and create a new eligible rubric against exact current inputs.",
    "analysis_recommendation_required" =>
      "This goal needs at least one plan-selected approved company-analysis recommendation. Review recommendations and the exact package plan first.",
    "incomplete_obligation_mapping" =>
      "Keep exactly one goal-acceptance obligation and map every required approved recommendation to at least one mandatory obligation.",
    "stale_authority" =>
      "Inputs changed. This attempt was not recorded. Review the current evidence and create a new eligible rubric.",
    "stale_rubric" =>
      "This rubric is no longer current. Review its successor and current evidence before recording acceptance.",
    "already_superseded" =>
      "This rubric already has a successor. Review the existing successor before creating another revision.",
    "invalid_record_hash" =>
      "This saved record could not be verified. Reload saved records; no assessment was recorded.",
    "restored_historical" =>
      "Restored history — a new eligible rubric and assessment are required. Historical judgments do not grant current authority.",
    "operator_session_revoked" =>
      "Your local operator session is unavailable or expired. Sign in again before continuing.",
    "invalid_attempt_token" =>
      "This attempt is unavailable or expired. Review saved history, then explicitly start a new attempt.",
    "conflicting_attempt_replay" =>
      "This attempt already recorded different content. View its saved receipt or explicitly start a new attempt; the saved receipt is unchanged.",
    "invalid_obligation_results" =>
      "Enter one explicit result for every frozen obligation, with no missing, extra or repeated obligation IDs. Review the identified obligations below.",
    "acceptance_requirements_unmet" =>
      "Acceptance requires completed work, every mandatory obligation Met with a nonblank observation, explicitly no critical violation and current exact inputs. Choose Not accepted to record an unsuccessful attempt.",
    "assessment_storage_failed" =>
      "The assessment could not be saved. Your entered text is retained. Retry the same attempt; no success is claimed.",
    "audit_failed" =>
      "The assessment and its audit could not be saved together. Your entered text is retained. Retry the same attempt.",
    "privacy_operation_incomplete" =>
      "Finish the pending privacy removal and reload saved records before continuing.",
    "privacy_state_unavailable" =>
      "Privacy readiness is unavailable. Restore workspace access and reload before continuing."
  }

  @doc "Returns fixed actionable copy; arbitrary reason text is never reflected."
  @spec error_message(term()) :: String.t()
  def error_message(reason) when is_atom(reason), do: error_message(Atom.to_string(reason))
  def error_message(%{"reason" => reason}), do: error_message(reason)
  def error_message(reason) when is_binary(reason), do: Map.get(@errors, reason, fallback_error())
  def error_message(_), do: fallback_error()

  attr :state, :map, required: true
  attr :assessment_event_generation, :string, required: true
  attr :company_reset_token, :integer, required: true
  attr :sources, :list, default: []
  attr :package_label, :string, default: nil

  def panel(assigns) do
    assigns =
      assigns
      |> assign(:stage, assigns.state["stage"] || "scope")
      |> assign(:context, assigns.state["context"])
      |> assign(:scope, assigns.state["scope_input"] || %{})
      |> assign(:draft, assigns.state["rubric_draft"] || %{})
      |> assign(:frozen, assigns.state["frozen_rubric"])
      |> assign(:result_draft, assigns.state["result_draft"] || %{})
      |> assign(:receipt, assigns.state["receipt"])
      |> assign(:history, assigns.state["history"] || [])
      |> assign(:error, assigns.state["error"])
      |> assign(:generation, assigns.assessment_event_generation)

    ~H"""
    <div
      id="company-assessment-start"
      class="company-step company-analysis company-analysis-report"
      tabindex="-1"
    >
      <h3>Assess representative task</h3>
      <p :if={@package_label}>Exact selected package: <strong>{@package_label}</strong></p>
      <p>
        Choose one exact built package and one saved goal, freeze your task and mandatory rubric, then record your observations.
      </p>
      <p class="context-note">{qualification()}</p>
      <p>
        Declared mapping does not prove that all company obligations were discovered or that an observation is true. Other package goals remain outside this assessment.
      </p>
      <ol
        id="company-assessment-stages"
        class="company-guide-tasks"
        aria-label="Stages of this assessment only"
      >
        <li
          :for={{key, title} <- stages()}
          class="company-guide-task"
          aria-current={if key == @stage, do: "step"}
        >
          <strong>{title}</strong><span>{stage_status(key, @stage, @frozen, @receipt)}</span>
        </li>
      </ol>
      <p :if={@state["notice"]} id="company-assessment-notice" role="status">{@state["notice"]}</p>
      <div
        :if={@error}
        id="company-assessment-error"
        class="company-form-error"
        role="alert"
        tabindex="-1"
      >
        <h4>Review this assessment</h4>
        <p>{error_message(@error)}</p>
        <ul>
          <li :for={{id, label} <- error_fields(@stage, @draft, @frozen)}>
            <a href={"#" <> id}>{label}</a>
          </li>
        </ul>
      </div>
      <.departure :if={@state["pending_destination"]} stage={@stage} generation={@generation} />
      <.scope_form
        :if={@stage == "scope"}
        context={@context}
        input={@scope}
        generation={@generation}
        reset_token={@company_reset_token}
        error={@error}
      />
      <.context_details :if={@context} context={@context} sources={@sources} />
      <.rubric_form
        :if={@stage == "rubric" && @context}
        draft={@draft}
        context={@context}
        generation={@generation}
        reset_token={@company_reset_token}
        error={@error}
      />
      <.frozen
        :if={@frozen && @stage in ["results", "receipt"]}
        rubric={@frozen}
        generation={@generation}
      />
      <div :if={@stage == "receipt" && @frozen && !@receipt}>
        <p>
          Unassessed — choose a recorded assessment below, or explicitly start an available new attempt.
        </p>
        <.rubric_actions rubric={@frozen} generation={@generation} />
      </div>
      <.results_form
        :if={@stage == "results" && @frozen && @state["attempt"] && !restored?(@frozen)}
        rubric={@frozen}
        draft={@result_draft}
        attempt={@state["attempt"]}
        generation={@generation}
        reset_token={@company_reset_token}
        error={@error}
      />
      <p :if={@stage == "results" && @frozen && restored?(@frozen)} class="context-note">
        Restored history — a new rubric and assessment are required.
      </p>
      <.receipt
        :if={@stage == "receipt" && @receipt && @frozen}
        receipt={@receipt}
        rubric={@frozen}
        generation={@generation}
      />
      <.history rows={@history} generation={@generation} />
    </div>
    """
  end

  attr :context, :any, required: true
  attr :input, :map, required: true
  attr :generation, :string, required: true
  attr :reset_token, :integer, required: true
  attr :error, :any, required: true

  defp scope_form(assigns) do
    ~H"""
    <section aria-labelledby="company-assessment-scope-title">
      <h4 id="company-assessment-scope-title">1. Choose scope</h4>
      <div :if={!@context} id="company-assessment-unavailable" class="context-note">
        <p>
          Unassessed. Choose an eligible, durably built package from the Company guide or built-package review. Plan approval and build preflight alone do not select a package.
        </p>
        <p>
          <a href="#company-toggle-review">Review an exact plan</a>
          · <a href="#company-toggle-build">Review the build step</a>
        </p>
      </div>
      <.form
        :if={@context}
        for={%{}}
        id="company-assessment-scope-form"
        class="stack"
        data-company-reset-token={@reset_token}
        phx-submit="assessment_goal_change"
      >
        <input type="hidden" name="assessment_event_generation" value={@generation} />
        <.binding_fields root="scope" binding={@context["binding"]} />
        <label for="company-assessment-goal">One saved package goal</label>
        <select
          id="company-assessment-goal"
          name="scope[goal_snapshot]"
          required
          aria-invalid={to_string(!!@error)}
          aria-describedby="company-assessment-goal-help"
        >
          <option value="" selected={blank?(@input["goal_snapshot"])}>Choose one saved goal</option>
          <option
            :for={goal <- @context["goals"] || []}
            value={goal["id"] <> ":" <> goal["content_hash"]}
            selected={goal["id"] <> ":" <> goal["content_hash"] == @input["goal_snapshot"]}
          >
            {goal["title"]}
          </option>
        </select>
        <p id="company-assessment-goal-help" class="field-help">
          Choose deliberately. The goal's exact saved content is checked with the selected package; choosing it grants no approval.
        </p>
        <button
          id="company-assessment-scope-use"
          type="submit"
          class="button primary"
          phx-disable-with="Loading exact scope…"
        >Use this goal and package</button>
      </.form>
    </section>
    """
  end

  attr :context, :map, required: true
  attr :sources, :list, required: true

  defp context_details(assigns) do
    ~H"""
    <section id="company-assessment-context" aria-labelledby="company-assessment-context-title">
      <h4 id="company-assessment-context-title">Exact package and goal context</h4>
      <.applicability value={@context["applicability"]} />
      <details>
        <summary>Package identity and plan snapshot</summary>
        <.exact_binding binding={@context["binding"]} />
      </details>
      <div :if={@context["selected_goal"]} class="context-note">
        <h5>Selected goal: {@context["selected_goal"]["title"]}</h5>
        <p>Owner: {@context["selected_goal"]["owner"]}</p>
        <p><strong>Acceptance:</strong> {@context["selected_goal"]["acceptance"]}</p>
        <p>
          Goal {@context["selected_goal"]["id"]} · content hash
          <code>{@context["selected_goal"]["content_hash"]}</code>
        </p>
      </div>
      <div :if={@context["selected_goal"]}>
        <h5>Relevant selected milestones</h5>
        <p :if={(@context["milestones"] || []) == []}>No selected milestone covers this goal.</p>
        <article :for={milestone <- @context["milestones"] || []} class="company-record">
          <strong>{milestone["title"]} · {milestone["id"]}</strong>
          <p>Acceptance: {milestone["acceptance"]}</p><p>
            Evaluation: {milestone["evaluation_method"]}
          </p>
        </article>
        <h5>All selected approved recommendations for this goal</h5>
        <article
          :for={{claim, index} <- Enum.with_index(@context["recommendations"] || [])}
          class="company-record"
        >
          <h5>Approved guidance</h5><p>{claim["text"]}</p>
          <p>Claim {claim["id"]} · revision <code>{claim["revision_hash"]}</code></p>
          <Analysis.report
            claim={claim}
            id={"company-assessment-recommendation-#{index}"}
            goals={[@context["selected_goal"]]}
            sources={@sources}
          />
        </article>
        <.outside_goals goals={@context["outside_goals"] || []} />
      </div>
    </section>
    """
  end

  attr :draft, :map, required: true
  attr :context, :map, required: true
  attr :generation, :string, required: true
  attr :reset_token, :integer, required: true
  attr :error, :any, required: true

  defp rubric_form(assigns) do
    assigns = assign(assigns, :rows, assigns.draft["obligations"] || [])

    ~H"""
    <section aria-labelledby="company-assessment-rubric-title">
      <h4 id="company-assessment-rubric-title">2. Write task and freeze rubric</h4>
      <p class="field-help">
        Editable suggestions — review before freezing. Nothing here records a result. Keep 1–20 mandatory obligations, including exactly one goal-acceptance obligation and every required recommendation mapping.
      </p>
      <.form
        for={%{}}
        id="company-assessment-rubric-form"
        class="stack"
        data-company-reset-token={@reset_token}
        phx-change="assessment_rubric_change"
        phx-submit="assessment_rubric_freeze"
      >
        <input type="hidden" name="assessment_event_generation" value={@generation} />
        <.binding_fields root="rubric" binding={@context["binding"]} />
        <input type="hidden" name="rubric[goal_id]" value={get_in(@context, ["selected_goal", "id"])} />
        <input
          type="hidden"
          name="rubric[goal_content_hash]"
          value={get_in(@context, ["selected_goal", "content_hash"])}
        />
        <input
          :if={@draft["supersedes_id"]}
          type="hidden"
          name="rubric[supersedes_id]"
          value={@draft["supersedes_id"]}
        />
        <input
          :if={@draft["expected_predecessor_hash"]}
          type="hidden"
          name="rubric[expected_predecessor_hash]"
          value={@draft["expected_predecessor_hash"]}
        />
        <p :if={@draft["supersedes_id"]} class="context-note">
          Explicit successor of rubric {@draft["supersedes_id"]}, revision <code>{@draft["expected_predecessor_hash"]}</code>. Reusing an obligation ID preserves its exact meaning; give changed obligations a new ID. No results or acceptance carry forward.
        </p>
        <label for="company-assessment-task">Representative task</label>
        <textarea
          id="company-assessment-task"
          name="rubric[task]"
          required
          aria-invalid={to_string(!!@error && blank?(@draft["task"]))}
          aria-describedby="company-assessment-text-limit"
        >{@draft["task"]}</textarea>
        <p id="company-assessment-text-limit" class="field-help">
          Each task, obligation and observation allows at most 1,000 Unicode characters and 4,000 UTF-8 bytes. Excess is refused with your text retained; it is never truncated.
        </p>
        <fieldset class="company-milestones">
          <legend>Mandatory obligations · {length(@rows)} of at most 20</legend>
          <.obligation_editor
            :for={{row, index} <- Enum.with_index(@rows)}
            row={row}
            index={index}
            recommendations={@context["recommendations"] || []}
            generation={@generation}
            error={@error}
          />
          <div class="company-actions">
            <button
              id="company-assessment-add-guidance"
              type="button"
              class="button secondary"
              phx-click="assessment_rubric_change"
              phx-value-assessment_event_generation={@generation}
              phx-value-action="add_guidance"
              disabled={length(@rows) >= 20}
            >Add another mapped guidance obligation</button>
            <button
              id="company-assessment-add-owner"
              type="button"
              class="button secondary"
              phx-click="assessment_rubric_change"
              phx-value-assessment_event_generation={@generation}
              phx-value-action="add_owner"
              disabled={length(@rows) >= 20}
            >Add owner-authored obligation</button>
          </div>
        </fieldset>
        <p>
          Map every required recommendation at least once. One recommendation can support multiple obligations; one obligation can explicitly map multiple recommendations. Declared mapping does not prove complete coverage.
        </p>
        <div class="company-actions">
          <button
            id="company-assessment-freeze"
            type="submit"
            class="button primary"
            phx-disable-with="Freezing exact rubric…"
          >Freeze task and rubric</button>
          <button
            id="company-assessment-discard-rubric"
            type="button"
            class="button secondary"
            phx-click="assessment_discard"
            phx-value-assessment_event_generation={@generation}
            phx-value-stage="rubric"
          >Discard unsaved rubric</button>
        </div>
      </.form>
    </section>
    """
  end

  attr :row, :map, required: true
  attr :index, :integer, required: true
  attr :recommendations, :list, required: true
  attr :generation, :string, required: true
  attr :error, :any, required: true

  defp obligation_editor(assigns) do
    assigns = assign(assigns, :prefix, "company-assessment-obligation-#{assigns.index}")

    ~H"""
    <div id={@prefix} class="company-record stack">
      <h5>Mandatory obligation {@index + 1} · {kind_label(@row["kind"])}</h5>
      <input
        :if={@row["kind"] == "goal_acceptance"}
        type="hidden"
        name={"rubric[obligations][#{@index}][kind]"}
        value="goal_acceptance"
      />
      <label :if={@row["kind"] != "goal_acceptance"} for={@prefix <> "-kind"}>Origin for obligation {@index +
        1}</label>
      <select
        :if={@row["kind"] != "goal_acceptance"}
        id={@prefix <> "-kind"}
        name={"rubric[obligations][#{@index}][kind]"}
      >
        <option
          value="approved_analysis_guidance"
          selected={@row["kind"] == "approved_analysis_guidance"}
        >
          Mapped approved analysis guidance
        </option>
        <option value="owner_authored" selected={@row["kind"] == "owner_authored"}>
          Owner-authored
        </option>
      </select>
      <input type="hidden" name={"rubric[obligations][#{@index}][mandatory]"} value="true" />
      <label for={@prefix <> "-id"}>Stable ID for obligation {@index + 1}</label>
      <input
        id={@prefix <> "-id"}
        name={"rubric[obligations][#{@index}][id]"}
        value={@row["id"]}
        required
        pattern="[a-z][a-z0-9_-]{0,63}"
        aria-describedby={@prefix <> "-help"}
        aria-invalid={to_string(!!@error && blank?(@row["id"]))}
      />
      <label for={@prefix <> "-text"}>Obligation {@index + 1} text</label>
      <textarea
        id={@prefix <> "-text"}
        name={"rubric[obligations][#{@index}][text]"}
        required
        aria-describedby={@prefix <> "-help"}
        aria-invalid={to_string(!!@error && blank?(@row["text"]))}
      >{@row["text"]}</textarea>
      <p id={@prefix <> "-help"} class="field-help">
        Mandatory. Text limit: 1,000 Unicode characters and 4,000 UTF-8 bytes. IDs use a lowercase letter followed by lowercase letters, numbers, underscores or hyphens; at most 64 characters.
      </p>
      <fieldset :if={@row["kind"] == "approved_analysis_guidance"} class="company-choices">
        <legend>Exact approved recommendations mapped to obligation {@index + 1}</legend>
        <label
          :for={{claim, ref_index} <- Enum.with_index(@recommendations)}
          class="company-choice"
          for={@prefix <> "-claim-#{ref_index}"}
        >
          <input
            id={@prefix <> "-claim-#{ref_index}"}
            type="checkbox"
            name={"rubric[obligations][#{@index}][claim_refs][]"}
            value={ref_value(claim)}
            checked={mapped?(@row, claim)}
          />
          <span><strong>{claim["text"]}</strong><small>{claim["id"]} · revision {claim[
            "revision_hash"
          ]}</small></span>
        </label>
      </fieldset>
      <p :if={@row["kind"] == "goal_acceptance"} class="field-help">
        Goal acceptance · required exactly once; no claim reference is assigned to this obligation.
      </p>
      <p :if={@row["kind"] == "owner_authored"} class="field-help">
        Owner-authored obligation · no recommendation reference is implied.
      </p>
      <button
        :if={@row["kind"] != "goal_acceptance"}
        id={@prefix <> "-remove"}
        type="button"
        class="button secondary"
        phx-click="assessment_rubric_change"
        phx-value-assessment_event_generation={@generation}
        phx-value-action="remove_row"
        phx-value-index={@index}
        aria-label={"Remove obligation #{@index + 1} if required mapping remains covered"}
      >Remove obligation</button>
    </div>
    """
  end

  attr :rubric, :map, required: true

  attr :generation, :string, required: true

  defp frozen(assigns) do
    ~H"""
    <section
      id="company-assessment-frozen"
      tabindex="-1"
      aria-labelledby="company-assessment-frozen-title"
    >
      <h4 id="company-assessment-frozen-title">Frozen task and rubric</h4>
      <p><strong>{@rubric["payload"]["task"]}</strong></p>
      <.applicability value={@rubric["applicability"]} />
      <details>
        <summary>Immutable rubric identity, lineage and captured inputs</summary>
        <p>Rubric {@rubric["id"]} · revision <code>{@rubric["revision_hash"]}</code></p>
        <p>Family {@rubric["family_id"]}</p>
        <p :if={@rubric["supersedes_id"]}>
          Predecessor rubric: <code>{@rubric["supersedes_id"]}</code>
        </p>
        <button
          :if={@rubric["supersedes_id"]}
          id="company-assessment-predecessor"
          type="button"
          class="button secondary"
          phx-click="assessment_history_open"
          phx-value-assessment_event_generation={@generation}
          phx-value-rubric_id={@rubric["supersedes_id"]}
        >Review predecessor rubric</button>
        <p :if={@rubric["successor_id"]}>Successor rubric: <code>{@rubric["successor_id"]}</code></p>
        <button
          :if={@rubric["successor_id"]}
          id="company-assessment-successor-history"
          type="button"
          class="button secondary"
          phx-click="assessment_history_open"
          phx-value-assessment_event_generation={@generation}
          phx-value-rubric_id={@rubric["successor_id"]}
        >Review successor rubric</button>
        <.exact_binding binding={@rubric["payload"]["binding"]} />
        <p>
          Captured goal: {@rubric["payload"]["goal"]["title"]} · {@rubric["payload"]["goal"]["id"]}
        </p>
        <p>Captured acceptance: {@rubric["payload"]["goal"]["acceptance"]}</p>
        <p :for={ref <- @rubric["payload"]["required_claim_refs"] || []}>
          Required claim {ref["id"]} · revision <code>{ref["revision_hash"]}</code>
        </p>
        <div :for={claim <- @rubric["payload"]["claim_contexts"] || []}>
          <p>
            Captured claim {claim["id"]} · revision <code>{claim["revision_hash"]}</code>
            · examined-context digest <code>{claim["context_digest"]}</code>
          </p>
          <p :for={source <- get_in(claim, ["context", "sources"]) || []}>
            Examined source {source["source_id"]} · revision {source["revision_id"]} · body hash <code>{source["body_hash"]}</code>. Examined context can include uncited sources.
          </p>
        </div>
        <h5>Every frozen mandatory obligation</h5>
        <article :for={obligation <- @rubric["payload"]["obligations"]} class="company-record">
          <strong>{obligation["id"]} · {kind_label(obligation["kind"])}</strong><p>
            {obligation["text"]}
          </p>
          <p :for={ref <- obligation["claim_refs"] || []}>
            Mapped claim {ref["id"]} · revision <code>{ref["revision_hash"]}</code>
          </p>
        </article>
      </details>
      <div id="company-assessment-frozen-outside-goals" class="context-note">
        <h5>Captured other package goals — outside this assessment</h5>
        <p :if={outside_goal_pins(@rubric) == []}>No other package goals were selected.</p>
        <p :for={goal <- outside_goal_pins(@rubric)}>
          Goal <code>{goal["id"]}</code>
          · captured content hash <code>{goal["content_hash"]}</code>. Unassessed by this task. Historical pins do not establish a current title or acceptance.
        </p>
      </div>
    </section>
    """
  end

  attr :rubric, :map, required: true
  attr :draft, :map, required: true
  attr :attempt, :map, required: true
  attr :generation, :string, required: true
  attr :reset_token, :integer, required: true
  attr :error, :any, required: true

  defp results_form(assigns) do
    ~H"""
    <section
      id="company-assessment-results"
      tabindex="-1"
      aria-labelledby="company-assessment-results-title"
    >
      <h4 id="company-assessment-results-title">3. Record observations</h4>
      <p>{qualification()}</p>
      <p id="company-assessment-outcome-help">
        Acceptance requires completed work, every mandatory obligation Met with a nonblank observation, explicitly no critical violation and current exact authority. Interrupted work can be recorded as Not accepted.
      </p>
      <p
        :if={@draft["critical_status"] == "present" && @draft["judgment"] == "accepted"}
        class="context-note"
      >
        Cannot accept: a critical violation is present. Choose Not accepted to record this attempt.
      </p>
      <.form
        for={%{}}
        id="company-assessment-results-form"
        class="stack"
        data-company-reset-token={@reset_token}
        phx-change="assessment_result_change"
        phx-submit="assessment_record"
      >
        <input type="hidden" name="assessment_event_generation" value={@generation} />
        <input type="hidden" name="assessment[rubric_id]" value={@rubric["id"]} />
        <input type="hidden" name="assessment[expected_rubric_hash]" value={@rubric["revision_hash"]} />
        <input type="hidden" name="assessment[attempt_id]" value={@attempt["attempt_id"]} />
        <input type="hidden" name="assessment[attempt_token]" value={@attempt["attempt_token"]} />
        <ol aria-label="Every frozen mandatory obligation">
          <.result_editor
            :for={{obligation, index} <- Enum.with_index(@rubric["payload"]["obligations"])}
            obligation={obligation}
            index={index}
            result={result_for(@draft, obligation["id"])}
            error={@error}
          />
        </ol>
        <fieldset class="company-choices stack">
          <legend>Explicit attempt outcome</legend>
          <label for="company-assessment-task-status">Task status</label>
          <select
            id="company-assessment-task-status"
            aria-describedby="company-assessment-outcome-help"
            name="assessment[task_status]"
            required
            aria-invalid={to_string(!!@error && blank?(@draft["task_status"]))}
          >
            <option value="" selected={blank?(@draft["task_status"])}>Choose task status</option>
            <option value="completed" selected={@draft["task_status"] == "completed"}>
              Completed
            </option>
            <option value="interrupted" selected={@draft["task_status"] == "interrupted"}>
              Interrupted
            </option>
          </select>
          <label for="company-assessment-critical-status">Critical-violation status</label>
          <select
            id="company-assessment-critical-status"
            aria-describedby="company-assessment-outcome-help"
            name="assessment[critical_status]"
            required
            aria-invalid={to_string(!!@error && blank?(@draft["critical_status"]))}
          >
            <option value="" selected={blank?(@draft["critical_status"])}>
              Choose critical-violation status
            </option>
            <option value="none" selected={@draft["critical_status"] == "none"}>
              None observed — explicitly no critical violation
            </option>
            <option value="present" selected={@draft["critical_status"] == "present"}>
              Critical violation present
            </option>
            <option value="unobserved" selected={@draft["critical_status"] == "unobserved"}>
              Unobserved
            </option>
          </select>
          <label for="company-assessment-judgment">Your reported judgment</label>
          <select
            id="company-assessment-judgment"
            aria-describedby="company-assessment-outcome-help"
            name="assessment[judgment]"
            required
            aria-invalid={to_string(!!@error && blank?(@draft["judgment"]))}
          >
            <option value="" selected={blank?(@draft["judgment"])}>Choose judgment</option>
            <option value="accepted" selected={@draft["judgment"] == "accepted"}>Accepted</option>
            <option value="not_accepted" selected={@draft["judgment"] == "not_accepted"}>
              Not accepted
            </option>
          </select>
        </fieldset>
        <p class="field-help">
          A record is saved only after server validation and commit. Retrying the same committed attempt returns its same receipt; changed content needs a new attempt.
        </p>
        <div class="company-actions">
          <button
            id="company-assessment-record"
            type="submit"
            class="button primary"
            phx-disable-with="Recording assessment…"
          >Record assessment</button>
          <button
            id="company-assessment-discard-results"
            type="button"
            class="button secondary"
            phx-click="assessment_discard"
            phx-value-assessment_event_generation={@generation}
            phx-value-stage="results"
          >Discard unsaved observations</button>
        </div>
      </.form>
    </section>
    """
  end

  attr :obligation, :map, required: true
  attr :index, :integer, required: true
  attr :result, :map, required: true
  attr :error, :any, required: true

  defp result_editor(assigns) do
    assigns = assign(assigns, :prefix, "company-assessment-result-#{assigns.index}")

    ~H"""
    <li id={@prefix} class="company-record stack">
      <h5>Mandatory: {@obligation["id"]}</h5><p>{@obligation["text"]}</p>
      <p>{kind_label(@obligation["kind"])}</p>
      <p :for={ref <- @obligation["claim_refs"] || []}>
        Mapped claim {ref["id"]} · revision <code>{ref["revision_hash"]}</code>
      </p>
      <input
        type="hidden"
        name={"assessment[results][#{@index}][obligation_id]"}
        value={@obligation["id"]}
      />
      <label for={@prefix <> "-status"}>Result for obligation {@obligation["id"]}</label>
      <select
        id={@prefix <> "-status"}
        name={"assessment[results][#{@index}][status]"}
        required
        aria-describedby={@prefix <> "-help"}
        aria-invalid={to_string(!!@error && blank?(@result["status"]))}
      >
        <option value="" selected={blank?(@result["status"])}>Choose result</option>
        <option value="met" selected={@result["status"] == "met"}>Met</option>
        <option value="unmet" selected={@result["status"] == "unmet"}>Unmet</option>
        <option value="unobserved" selected={@result["status"] == "unobserved"}>Unobserved</option>
      </select>
      <label for={@prefix <> "-observation"}>Observation for obligation {@obligation["id"]}</label>
      <textarea
        id={@prefix <> "-observation"}
        name={"assessment[results][#{@index}][observation]"}
        aria-describedby={@prefix <> "-help"}
        aria-invalid={
          to_string(!!@error && @result["status"] == "met" && blank?(@result["observation"]))
        }
      >{@result["observation"]}</textarea>
      <p id={@prefix <> "-help"} class="field-help">
        At most 1,000 Unicode characters and 4,000 UTF-8 bytes. Accepted assessments need a nonblank observation for every mandatory Met result. An explicitly Unobserved result can have an empty observation in a Not accepted attempt.
      </p>
    </li>
    """
  end

  attr :receipt, :map, required: true
  attr :rubric, :map, required: true
  attr :generation, :string, required: true

  defp receipt(assigns) do
    ~H"""
    <section
      id="company-assessment-receipt"
      tabindex="-1"
      aria-labelledby="company-assessment-receipt-title"
    >
      <h4 id="company-assessment-receipt-title">4. Review recorded assessment</h4>
      <p role="status">{receipt_heading(@receipt)}</p>
      <p><strong>Captured judgment:</strong> {judgment_label(@receipt["payload"]["judgment"])}</p>
      <.applicability value={@receipt["applicability"]} />
      <p>{qualification()}</p>
      <p>
        Recorded by {@receipt["payload"]["operator"]} (local workspace access; corporate ownership and personal identity are not attested).
      </p>
      <p>Recorded at <time datetime={@receipt["inserted_at"]}>{@receipt["inserted_at"]}</time></p>
      <p>
        Captured task status: {status_label(@receipt["payload"]["task_status"])} · Captured critical-violation status: {status_label(
          @receipt["payload"]["critical_status"]
        )}
      </p>
      <p>Authority at record: {status_label(@receipt["payload"]["authority_at_record"])}</p>
      <ol aria-label="Recorded observations for every frozen obligation">
        <li :for={obligation <- @rubric["payload"]["obligations"]} class="company-record">
          <strong>{obligation["id"]} · {obligation["text"]}</strong>
          <p>Result: {status_label(result_for(@receipt["payload"], obligation["id"])["status"])}</p>
          <p>Observation: {result_for(@receipt["payload"], obligation["id"])["observation"]}</p>
        </li>
      </ol>
      <details>
        <summary>Immutable assessment identity</summary>
        <p>Assessment {@receipt["id"]} · hash <code>{@receipt["assessment_hash"]}</code></p>
        <p>
          Rubric {@receipt["rubric_id"]} · revision
          <code>{@receipt["payload"]["rubric_revision_hash"]}</code>
        </p>
        <p>Attempt {@receipt["attempt_id"]}</p>
      </details>
      <.rubric_actions rubric={@rubric} generation={@generation} />
      <p :if={restored?(@receipt)} class="context-note">
        Restored history — a new rubric and assessment are required. Review a currently eligible exact package before creating a successor.
      </p>
    </section>
    """
  end

  attr :rubric, :map, required: true
  attr :generation, :string, required: true

  defp rubric_actions(assigns) do
    ~H"""
    <p
      :if={stale?(@rubric) && !@rubric["superseded"]}
      id="company-assessment-stale-attempt-help"
      class="context-note"
    >
      Stale acceptance is unavailable. You may record complete unsuccessful observations as Not accepted; every frozen obligation and explicit outcome is still required.
    </p>
    <div class="company-actions">
      <button
        :if={attemptable?(@rubric) && !@rubric["superseded"]}
        id="company-assessment-another-attempt"
        type="button"
        class="button secondary"
        phx-click="assessment_attempt_start"
        phx-value-assessment_event_generation={@generation}
        phx-value-rubric_id={@rubric["id"]}
        phx-value-expected_rubric_hash={@rubric["revision_hash"]}
      >Record another attempt</button>
      <button
        :if={!@rubric["superseded"]}
        id="company-assessment-successor"
        type="button"
        class="button secondary"
        phx-click="assessment_rubric_change"
        phx-value-assessment_event_generation={@generation}
        phx-value-action="successor"
        phx-value-rubric_id={@rubric["id"]}
        phx-value-expected_rubric_hash={@rubric["revision_hash"]}
      >Create rubric successor</button>
    </div>
    """
  end

  attr :rows, :list, required: true
  attr :generation, :string, required: true

  defp history(assigns) do
    ~H"""
    <section id="company-assessment-history" aria-labelledby="company-assessment-history-title">
      <h4 id="company-assessment-history-title">Recorded assessment history</h4>
      <p :if={@rows == []}>Unassessed — no recorded assessment is loaded.</p>
      <article :for={row <- @rows} class="company-record">
        <p><strong>Captured judgment:</strong> {judgment_label(row["payload"]["judgment"])}</p>
        <.applicability value={row["applicability"]} />
        <p>{qualification()}</p>
        <p>{row["inserted_at"]} · assessment {row["id"]}</p>
        <button
          id={"company-assessment-history-" <> row["id"]}
          type="button"
          class="button secondary"
          phx-click="assessment_history_open"
          phx-value-assessment_event_generation={@generation}
          phx-value-assessment_id={row["id"]}
        >Review recorded assessment</button>
      </article>
    </section>
    """
  end

  attr :stage, :string, required: true
  attr :generation, :string, required: true

  defp departure(assigns) do
    ~H"""
    <section
      id="company-assessment-departure"
      class="context-note"
      tabindex="-1"
      aria-labelledby="company-assessment-departure-title"
    >
      <h4 id="company-assessment-departure-title">This assessment has unsaved changes</h4>
      <p>
        Choose what happens to this mounted draft before leaving. Unsaved text is not durably saved across a reload.
      </p>
      <div class="company-actions">
        <button
          id="company-assessment-keep-editing"
          type="button"
          class="button secondary"
          phx-click="assessment_departure_resolve"
          phx-value-assessment_event_generation={@generation}
          phx-value-action="keep"
        >Keep editing</button>
        <button
          id="company-assessment-discard-leave"
          type="button"
          class="button secondary"
          phx-click="assessment_departure_resolve"
          phx-value-assessment_event_generation={@generation}
          phx-value-action="discard"
        >Discard and leave</button>
        <button
          :if={@stage == "rubric"}
          id="company-assessment-freeze-leave"
          type="button"
          class="button primary"
          phx-click="assessment_departure_resolve"
          phx-value-assessment_event_generation={@generation}
          phx-value-action="freeze"
          phx-disable-with="Freezing rubric…"
        >Freeze rubric and leave</button>
        <button
          :if={@stage == "results"}
          id="company-assessment-record-leave"
          type="button"
          class="button primary"
          phx-click="assessment_departure_resolve"
          phx-value-assessment_event_generation={@generation}
          phx-value-action="record_not_accepted"
          phx-disable-with="Recording not accepted…"
        >Record not accepted and leave</button>
      </div>
      <p>
        Saving uses the same strict validation. Missing statuses and mappings keep this draft open; no outcome is filled automatically.
      </p>
    </section>
    """
  end

  attr :root, :string, required: true
  attr :binding, :map, required: true

  defp binding_fields(assigns) do
    ~H"""
    <input type="hidden" name={@root <> "[plan_id]"} value={@binding["plan_id"]} />
    <input
      type="hidden"
      name={@root <> "[expected_plan_revision_hash]"}
      value={@binding["plan_revision_hash"] || @binding["expected_plan_revision_hash"]}
    />
    <input type="hidden" name={@root <> "[artifact_digest]"} value={@binding["artifact_digest"]} />
    """
  end

  attr :binding, :map, required: true

  defp exact_binding(assigns) do
    ~H"""
    <p>
      Plan <code>{@binding["plan_id"]}</code>
      · revision
      <code>{@binding["plan_revision_hash"] || @binding["expected_plan_revision_hash"]}</code>
    </p>
    <p>Package digest <code>{@binding["artifact_digest"]}</code></p>
    """
  end

  attr :goals, :list, required: true

  defp outside_goals(assigns) do
    ~H"""
    <div id="company-assessment-outside-goals" class="context-note">
      <h5>Other package goals — outside this assessment</h5>
      <p :if={@goals == []}>No other package goals.</p>
      <p :for={goal <- @goals}>
        <strong>{goal["title"]}</strong>
        · {goal["id"]} · Acceptance: {goal["acceptance"]}. Unassessed by this task.
      </p>
    </div>
    """
  end

  attr :value, :any, required: true

  defp applicability(assigns) do
    ~H"""
    <p class="company-assessment-applicability">
      <strong>Current applicability:</strong> {applicability_label(@value)}
    </p>
    """
  end

  defp applicability_label(%{"status" => "current"}),
    do: "Current — exact inputs are currently eligible"

  defp applicability_label(%{"status" => "restored_historical"}),
    do: "Restored history — a new rubric and assessment are required"

  defp applicability_label(%{"status" => "stale"}),
    do: "Stale — inputs or rubric authority changed"

  defp applicability_label(_), do: "Unavailable — current eligibility is unconfirmed"

  defp outside_goal_pins(rubric) do
    goal_id = get_in(rubric, ["payload", "goal", "id"])

    Enum.reject(
      get_in(rubric, ["payload", "plan_snapshot", "goals"]) || [],
      &(&1["id"] == goal_id)
    )
  end

  defp restored?(value), do: get_in(value, ["applicability", "status"]) == "restored_historical"
  defp stale?(value), do: get_in(value, ["applicability", "status"]) == "stale"
  defp attemptable?(value), do: get_in(value, ["applicability", "status"]) in ["current", "stale"]
  defp qualification, do: @qualification
  defp stages, do: @stages
  defp stage_status(key, stage, _, _) when key == stage, do: "Current stage"
  defp stage_status("scope", _, frozen, _) when is_map(frozen), do: "Saved scope"
  defp stage_status("rubric", _, frozen, _) when is_map(frozen), do: "Immutable rubric saved"
  defp stage_status("results", _, _, receipt) when is_map(receipt), do: "Assessment recorded"
  defp stage_status(_, _, _, _), do: "Not yet recorded"
  defp kind_label("goal_acceptance"), do: "Goal acceptance"
  defp kind_label("approved_analysis_guidance"), do: "Mapped approved analysis guidance"
  defp kind_label("owner_authored"), do: "Owner-authored"
  defp kind_label(_), do: "Unknown origin"
  defp judgment_label("accepted"), do: "Accepted"
  defp judgment_label("not_accepted"), do: "Not accepted"
  defp judgment_label(_), do: "Unassessed"

  defp status_label(value)
       when value in ~w(completed interrupted none present unobserved met unmet current stale),
       do: String.capitalize(String.replace(value, "_", " "))

  defp status_label(_), do: "Unobserved or unavailable"

  defp receipt_heading(%{
         "payload" => %{"judgment" => "accepted"},
         "applicability" => %{"status" => "current"}
       }),
       do: "Owner accepted this task assessment"

  defp receipt_heading(%{"payload" => %{"judgment" => "accepted"}}),
    do: "Recorded historical acceptance — review current applicability"

  defp receipt_heading(_), do: "Recorded — not accepted"
  defp ref_value(ref), do: ref["id"] <> ":" <> ref["revision_hash"]

  defp mapped?(row, claim),
    do:
      Enum.any?(
        row["claim_refs"] || [],
        &(&1 == Map.take(claim, ~w(id revision_hash)) or &1 == ref_value(claim))
      )

  defp result_for(draft, id),
    do: Enum.find(draft["results"] || [], %{}, &(&1["obligation_id"] == id))

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(value), do: is_nil(value)

  defp fallback_error,
    do:
      "This assessment could not be completed. Review the explicit fields and reload saved records if needed. No success is claimed."

  defp error_fields("scope", _, _),
    do: [{"company-assessment-goal", "Review the selected package goal"}]

  defp error_fields("rubric", draft, _) do
    [{"company-assessment-task", "Review the representative task"}] ++
      Enum.map(Enum.with_index(draft["obligations"] || []), fn {row, i} ->
        {"company-assessment-obligation-#{i}-text",
         "Review obligation #{row["id"] || i + 1} and its mapping"}
      end)
  end

  defp error_fields("results", _, frozen) when is_map(frozen) do
    Enum.map(Enum.with_index(frozen["payload"]["obligations"]), fn {row, i} ->
      {"company-assessment-result-#{i}-status", "Review result and observation for #{row["id"]}"}
    end) ++
      [
        {"company-assessment-task-status", "Review task status"},
        {"company-assessment-critical-status", "Review critical-violation status"},
        {"company-assessment-judgment", "Review your judgment"}
      ]
  end

  defp error_fields(_, _, _), do: [{"company-assessment-start", "Review assessment context"}]
end
