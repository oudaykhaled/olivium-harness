defmodule HarnessForgeWeb.PackageReadiness do
  @moduledoc "Stateless presentation of an exact-package readiness observation."
  use HarnessForgeWeb, :html

  @stages [
    {"integrity", "Package integrity"},
    {"eligibility", "Current build eligibility"},
    {"managed_runtime", "Managed runtime availability"},
    {"evaluation", "Selected evaluation"},
    {"applicability", "Evaluation applicability"},
    {"cleanup", "Evaluation cleanup"},
    {"release_admission", "Release admission"}
  ]
  @identities ~w(artifact_digest suite_id suite_digest grader_digest task_fixture_digest runtime_image runtime_version environment_profile_digest effective_config_digest capability_report_digest policy_digest model_id model_context_digest scope_digest)
  @kinds %{
    "static_integrity" => "Static package integrity",
    "runtime_smoke" => "Runtime configuration smoke",
    "task" => "Model-backed task evaluation"
  }
  @outcomes ~w(pending running passed blocked failed cancelled interrupted inconclusive timed_out)
  @cleanup ~w(not_started not_dispatched pending complete cleanup_failed)
  @transport_reasons HarnessForgeWeb.EvaluationReason.transport_codes()
  @static_integrity_explanation "This static evaluation checked package integrity only. No model-backed task or runtime cleanup was attempted. Release review still requires a qualified model-backed task evaluation."
  @actions %{
    {"review_package", "package"} => "Review and rebuild package",
    {"review_company_plan", "company"} => "Review company evidence and plan",
    {"review_supported_runtime", "company"} => "Review supported runtime targets",
    {"configure_model", "connections"} => "Review model connections",
    {"select_evaluation", "evaluations"} => "Review evaluations",
    {"review_evaluation", "evaluations"} => "Review evaluations",
    {"review_release", "releases"} => "Open release review",
    {"review_runtime_identity", "releases"} => "Open release review — runtime check required"
  }

  attr :artifacts, :list, required: true
  attr :runs, :list, required: true
  attr :digest, :any, required: true
  attr :evaluation_id, :any, required: true
  attr :report, :any, required: true
  attr :message, :any, required: true
  attr :generation, :string, required: true
  attr :controls_generation, :string, required: true

  def inspector(assigns) do
    assigns = assign(assigns, :matching_runs, matching_runs(assigns.runs, assigns.digest))

    ~H"""
    <div id="package-readiness" class="panel" style="grid-column: 1 / -1; min-width: 0;">
      <h2>Package readiness</h2>
      <p>
        Inspect a saved package and optional evaluation. Inspection does not run an evaluation or approve a release.
      </p>
      <p :if={@artifacts == []} id="readiness-empty" class="muted">No saved packages to inspect.</p>
      <.form
        :if={@artifacts != []}
        for={%{}}
        id="package-readiness-form"
        phx-change="readiness_select"
        phx-submit="inspect_readiness"
        aria-describedby="readiness-selection-status"
        class="stack"
      >
        <input type="hidden" name="readiness[generation]" value={@generation} />
        <label for={"readiness-package-#{@controls_generation}"}>Saved package</label>
        <select
          id={"readiness-package-#{@controls_generation}"}
          data-readiness-field="package"
          name="readiness[digest]"
          required
        >
          <option value="" selected={is_nil(@digest)}>Choose a saved package</option>
          <option
            :for={artifact <- @artifacts}
            value={artifact["digest"]}
            selected={artifact["digest"] == @digest}
          >
            {package_label(artifact)}
          </option>
        </select>
        <p :if={@digest} id="readiness-selected-digest" style="overflow-wrap: anywhere;">
          Exact package: <code>{@digest}</code>
        </p>
        <label for={"readiness-evaluation-#{@controls_generation}"}>Persisted evaluation (optional)</label>
        <select
          id={"readiness-evaluation-#{@controls_generation}"}
          data-readiness-field="evaluation"
          name="readiness[evaluation_id]"
          disabled={is_nil(@digest)}
        >
          <option value="" selected={is_nil(@evaluation_id)}>No evaluation selected</option>
          <option
            :for={run <- @matching_runs}
            value={run["id"]}
            selected={run["id"] == @evaluation_id}
          >
            {run_label(run)}
          </option>
        </select>
        <button
          id="inspect-readiness"
          type="submit"
          class="button secondary"
          disabled={is_nil(@digest)}
          phx-disable-with="Inspecting readiness…"
        >{if @report, do: "Refresh readiness", else: "Inspect readiness"}</button>
      </.form>
      <p id="readiness-selection-status" role="status" aria-live="polite" class="field-help">
        {if @report, do: announcement(@report), else: @message}
      </p>
      <section
        :if={@report}
        id="readiness-report"
        aria-label="Exact package readiness result"
        style="overflow-wrap: anywhere;"
      >
        <p>Package <code>{@report["artifact_digest"]}</code></p>
        <p>Evaluation <code>{@report["evaluation_id"] || "No evaluation selected"}</code></p>
        <p class="field-help">
          Observed at {@report["observed_at"]}. Actual approval rechecks admission.
        </p>
        <p id="readiness-summary">{announcement(@report)}</p>
        <button
          :if={action_label(@report)}
          id="readiness-next-action"
          type="button"
          phx-click="readiness_next"
          phx-value-generation={@generation}
          class="button primary"
        >{action_label(@report)}</button>
        <p :if={runtime_check_action?(@report)} id="readiness-runtime-action-help" class="field-help">
          Opening release review does not approve or run anything. An explicit release approval attempt repeats the full existing validation and may check the runtime.
        </p>
        <ol id="readiness-stages" class="stack" aria-label="Independent admission stages">
          <li :for={{name, label} <- stages()} id={"readiness-stage-#{name}"}>
            <strong>{label}</strong>
            <span class="pill neutral" data-status={stage(@report, name)["status"]}>
              {status_label(stage(@report, name)["status"])}
            </span>
            <p>{stage_reason(@report, stage(@report, name))}</p>
            <p :if={name == "evaluation"} class="field-help">
              Kind: {kind_label(stage(@report, name)["kind"])} ·
              Outcome: {outcome_label(stage(@report, name)["outcome"])}
            </p>
            <p
              :if={name == "evaluation" and stage(@report, name)["recorded_reason_code"]}
              class="field-help"
            >
              Selected run observation: {reason_label(stage(@report, name)["recorded_reason_code"])} This is a historical observation, not current live health.
            </p>
            <p :if={name == "cleanup"} class="field-help">
              Recorded cleanup: {cleanup_label(stage(@report, name)["cleanup_status"])}
            </p>
            <p :if={name == "managed_runtime"} class="field-help">
              Live availability was not checked.
            </p>
          </li>
        </ol>
        <details id="readiness-identities">
          <summary id="readiness-identities-toggle">Identities</summary>
          <h3>Retained local plan bindings</h3>
          <p :if={@report["plan_bindings"] == []}>No retained local plan binding.</p>
          <p>
            Bindings record local provenance; they do not assert that every plan is currently approved.
          </p>
          <dl :for={binding <- @report["plan_bindings"] || []}>
            <dt>Plan ID</dt><dd><code>{metadata(binding["plan_id"])}</code></dd>
            <dt>Plan revision hash</dt><dd><code>{metadata(binding["plan_revision_hash"])}</code></dd>
          </dl>
          <div :for={
            {key, label} <- [
              {"current_identities", "Current task identities"},
              {"evaluation_identities", "Selected evaluation identities (historical)"}
            ]
          }>
            <h3>{label}</h3>
            <p :if={key == "current_identities"} id="readiness-current-identity-assessment">
              Task identity assessment: {assessment_status(@report)}. {reason_label(
                assessment_reason(@report)
              )}
            </p>
            <p :if={identity_rows(@report[key]) == []}>{empty_identity_explanation(@report, key)}</p>
            <dl>
              <div :for={{name, value} <- identity_rows(@report[key])}>
                <dt>{identity_label(name)}</dt><dd><code>{value}</code></dd>
              </div>
            </dl>
          </div>
        </details>
        <details id="readiness-limitations">
          <summary id="readiness-limitations-toggle">Limitations</summary>
          <p>
            This is a local observation of one exact package and explicitly selected persisted evaluation.
            Live runtime and model availability were not checked. Inspection grants no approval.
            Current OpenCode task applicability and release admission require a runtime identity check outside this inspector.
          </p>
          <p>
            Static integrity and runtime configuration smokes do not qualify a release.
            Synthetic task results do not establish company fitness. Intended-policy completeness,
            contradiction detection and portable authenticated approval remain unproven.
          </p>
        </details>
      </section>
    </div>
    """
  end

  defp stages, do: @stages

  defp stage(report, name),
    do: Enum.find(report["stages"] || [], %{}, &(&1["name"] == name))

  defp announcement(report) do
    runtime = stage(report, "managed_runtime")

    unsupported =
      if runtime["reason_code"] == "runtime_backend_unavailable", do: [runtime], else: []

    priority =
      Enum.map(~w(integrity eligibility), &stage(report, &1)) ++
        unsupported ++
        Enum.map(~w(evaluation cleanup applicability release_admission), &stage(report, &1))

    blocker = Enum.find(priority, &(&1["status"] in ["blocked", "unavailable"]))
    admission = stage(report, "release_admission")

    cond do
      blocker ->
        "Release review is blocked. " <> stage_reason(report, blocker)

      admission["status"] == "not_assessed" and
          admission["reason_code"] == "runtime_identity_check_required" ->
        "Release admission was not assessed. A current runtime identity check is required."

      admission["status"] == "passed" ->
        "Ready for release review"

      true ->
        "Release admission could not be established from the selected records."
    end
  end

  defp stage_reason(report, %{"name" => "cleanup"} = cleanup) do
    if static_integrity_only?(report, cleanup),
      do: @static_integrity_explanation,
      else: reason_label(cleanup["reason_code"])
  end

  defp stage_reason(_report, stage), do: reason_label(stage["reason_code"])

  defp static_integrity_only?(report, cleanup) do
    match?(
      %{"kind" => "static_integrity", "outcome" => "passed", "status" => "passed"},
      stage(report, "evaluation")
    ) and
      match?(
        %{
          "status" => "blocked",
          "reason_code" => "evaluation_cleanup_incomplete",
          "cleanup_status" => "not_started"
        },
        cleanup
      ) and
      match?(
        %{"status" => "blocked", "reason_code" => "qualified_task_evaluation_required"},
        stage(report, "release_admission")
      )
  end

  defp action_label(report) do
    action = report["next_action"] || %{}
    @actions[{action["code"], action["destination"]}]
  end

  defp runtime_check_action?(report),
    do:
      report["next_action"] == %{"code" => "review_runtime_identity", "destination" => "releases"}

  defp assessment_reason(%{
         "current_identity_assessment" => %{
           "kind" => "task",
           "status" => "not_assessed",
           "reason_code" => reason
         }
       })
       when reason in ~w(runtime_identity_check_required artifact_integrity_required), do: reason

  defp assessment_reason(%{
         "current_identity_assessment" => %{
           "kind" => "task",
           "status" => "passed",
           "reason_code" => "current_task_identities_observed"
         }
       }),
       do: "current_task_identities_observed"

  defp assessment_reason(_), do: "readiness_not_established"

  defp assessment_status(report),
    do:
      if(assessment_reason(report) == "current_task_identities_observed",
        do: "Passed",
        else: "Not assessed"
      )

  defp empty_identity_explanation(report, "current_identities") do
    if assessment_reason(report) == "runtime_identity_check_required",
      do:
        "Current OpenCode task identities were not checked because resolving the runtime transport requires a live check.",
      else: "No assessed identities."
  end

  defp empty_identity_explanation(_report, _key), do: "No assessed identities."

  defp status_label("passed"), do: "Passed"
  defp status_label("blocked"), do: "Blocked"
  defp status_label("unavailable"), do: "Unavailable"
  defp status_label(_), do: "Not assessed"
  defp kind_label(value), do: @kinds[value] || "Not available"
  defp outcome_label(value) when value in @outcomes, do: String.capitalize(value)
  defp outcome_label(_), do: "Not available"

  defp cleanup_label(value) when value in @cleanup,
    do: value |> String.replace("_", " ") |> String.capitalize()

  defp cleanup_label(_), do: "Not available"

  defp matching_runs(runs, digest) do
    Enum.filter(runs, fn run ->
      is_map(run) and digest != nil and run["artifact_digest"] == digest and
        valid_uuid?(run["id"])
    end)
  end

  defp valid_uuid?(value) when is_binary(value) and byte_size(value) == 36,
    do: match?({:ok, _}, Ecto.UUID.cast(value))

  defp valid_uuid?(_), do: false

  defp package_label(artifact) do
    name = get_in(artifact, ["spec", "metadata", "name"]) || "Harness package"
    version = get_in(artifact, ["spec", "metadata", "version"]) || "built"
    "#{name} · #{version} · #{String.slice(artifact["digest"], 0, 12)}"
  end

  defp run_label(run),
    do: "#{kind_label(run["kind"])} · #{outcome_label(run["outcome"])} · #{run["id"]}"

  defp identity_rows(identities) when is_map(identities) do
    for key <- @identities, Map.has_key?(identities, key), do: {key, metadata(identities[key])}
  end

  defp identity_rows(_), do: []
  defp identity_label(key), do: key |> String.replace("_", " ") |> String.capitalize()
  defp metadata(value) when is_binary(value) and byte_size(value) <= 512, do: value
  defp metadata(_), do: "Unavailable"

  defp reason_label(code) when code in @transport_reasons,
    do: HarnessForgeWeb.EvaluationReason.label(code)

  defp reason_label("runtime_identity_check_required"),
    do:
      "Not assessed: the current runtime identity requires a live check. This inspector did not run that check."

  defp reason_label("current_task_identities_observed"),
    do: "Current task identities were observed; this does not establish runtime support."

  defp reason_label("ready_for_release_review"), do: "Ready for release review"
  defp reason_label("artifact_verified"), do: "Saved package bytes and metadata were verified."
  defp reason_label("currently_eligible"), do: "Current local evidence and plan admission passed."
  defp reason_label("identities_match"), do: "Selected evidence matches current exact identities."

  defp reason_label("evaluation_observed_pass"),
    do: "The selected evaluation recorded a completed pass."

  defp reason_label("cleanup_complete"), do: "The selected evaluation recorded complete cleanup."

  defp reason_label("no_evaluation_selected"),
    do: "No evaluation selected. Choose a persisted evaluation explicitly."

  defp reason_label("selected_evaluation_required"),
    do: "Select an evaluation before assessing this stage."

  defp reason_label("evaluation_artifact_mismatch"),
    do: "The selected evaluation does not match this package."

  defp reason_label(code) when code in ~w(evaluation_unavailable evaluation_workspace_mismatch),
    do: "The selected evaluation is unavailable in this workspace."

  defp reason_label("evaluation_inapplicable"),
    do: "The selected evaluation does not match current exact identities."

  defp reason_label("qualified_task_evaluation_required"),
    do: "Release review requires a qualified model-backed task evaluation."

  defp reason_label(code) when code in ~w(stale_or_revoked_evidence stale_or_revoked_plan),
    do: "Current evidence or plan admission changed. Review and rebuild the package."

  defp reason_label("evaluation_cleanup_incomplete"),
    do: "Recorded evaluation cleanup is incomplete."

  defp reason_label("runtime_backend_unavailable"),
    do: "This target has no managed execution backend. Review a supported target."

  defp reason_label("model_not_selected"),
    do: "No selected model is configured for managed tasks."

  defp reason_label("live_availability_not_assessed"),
    do: "Configuration does not establish current live availability."

  defp reason_label("artifact_integrity_unavailable"),
    do: "The saved package is unavailable or could not be verified."

  defp reason_label("artifact_integrity_required"),
    do: "Verify the saved package before assessing this stage."

  defp reason_label("invalid_evaluation_record"),
    do: "The selected evaluation has incomplete or unknown recorded metadata."

  defp reason_label("evaluation_incomplete"),
    do: "The selected evaluation has no completed observation."

  defp reason_label("evaluation_pending"), do: "The selected evaluation is pending."
  defp reason_label("evaluation_running"), do: "The selected evaluation is still running."
  defp reason_label("evaluation_blocked"), do: "The selected evaluation recorded a blocker."
  defp reason_label("evaluation_failed"), do: "The selected evaluation recorded a failed outcome."
  defp reason_label("evaluation_cancelled"), do: "The selected evaluation was cancelled."
  defp reason_label("evaluation_interrupted"), do: "The selected evaluation was interrupted."
  defp reason_label("evaluation_inconclusive"), do: "The selected evaluation was inconclusive."
  defp reason_label("evaluation_timed_out"), do: "The selected evaluation timed out."

  defp reason_label("runtime_unqualified"),
    do: "The package targets a runtime version that is not qualified for release."

  defp reason_label("release_scope_mismatch"),
    do: "Selected evidence does not cover this package's exact scope."

  defp reason_label("evaluation_checks_incomplete"),
    do: "The selected evaluation lacks complete qualifying checks."

  defp reason_label("unsupported_required_control"),
    do: "A required package control is unsupported. Review the plan and target."

  defp reason_label(code)
       when code in ~w(runtime_image_unavailable local_docker_or_pinned_image_unavailable),
       do: "The selected run recorded a missing runtime image or local isolation service."

  defp reason_label("relay_socket_unavailable"),
    do: "The selected run recorded an unavailable runtime socket."

  defp reason_label(code) when code in ~w(model_service_unavailable model_unavailable),
    do: "The selected run recorded an unavailable model service."

  defp reason_label(code) when code in ~w(runtime_cloud_disabled cloud_model_denied),
    do: "The selected run recorded that its cloud model route was not permitted."

  defp reason_label(code)
       when code in ~w(docker_unavailable docker_operation_failed coding_docker_operation_failed),
       do: "The selected run recorded an isolation-service failure."

  defp reason_label("runtime_version_not_qualified"),
    do: "The selected run recorded an unqualified runtime version."

  defp reason_label("model_configuration_changed"),
    do: "The selected run recorded a model configuration change."

  defp reason_label(code) when code in ~w(teardown_failed usage_or_cleanup_unverified),
    do: "The selected run could not verify complete cleanup or usage."

  defp reason_label("restored_requires_reevaluation"),
    do: "Restored evidence requires a fresh evaluation."

  defp reason_label(_), do: "This stage could not be established from the selected records."
end
