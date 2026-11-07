defmodule HarnessForge.Readiness do
  @moduledoc """
  Read-only observations about one saved package and one explicitly selected run.

  A report confers no approval or execution authority. The release-admission
  observation delegates to the release gate only on audited pure identity paths.
  Managed coding task applicability and release admission abstain because their current
  identity requires a live transport check. Release commands repeat full admission.
  """
  import Ecto.Query
  alias HarnessForge.{Contracts, Evaluations, Harnesses, Repo, Workspaces}
  alias HarnessForge.Adapters.Registry
  alias HarnessForge.Evidence.Store
  alias HarnessForge.Harnesses.ArtifactBinding
  alias HarnessForge.Execution.Coding
  alias HarnessForge.Privacy.Purge
  alias HarnessForge.Releases.Validation

  @stage_names ~w(integrity eligibility managed_runtime evaluation applicability cleanup release_admission)
  @identity_digests ~w(artifact_digest suite_digest grader_digest task_fixture_digest model_context_digest environment_profile_digest effective_config_digest capability_report_digest policy_digest)
  @identity_labels ~w(suite_id runtime_image runtime_version model_id)
  @kinds ~w(task static_integrity runtime_smoke)
  @outcomes ~w(pending running passed blocked failed cancelled interrupted inconclusive timed_out)
  @cleanup_statuses ~w(complete not_started not_dispatched pending cleanup_failed)
  @gate_reasons ~w(evaluation_workspace_mismatch evaluation_artifact_mismatch qualified_task_evaluation_required evaluation_cleanup_incomplete evaluation_incomplete release_scope_mismatch runtime_unqualified evaluation_inapplicable evaluation_checks_incomplete unsupported_required_control stale_or_revoked_evidence stale_or_revoked_plan)
  @recorded_reasons ~w(runtime_backend_unavailable model_not_selected runtime_cloud_disabled cloud_model_denied model_service_unavailable model_unavailable runtime_image_unavailable local_docker_or_pinned_image_unavailable docker_unavailable docker_operation_failed coding_docker_operation_failed relay_socket_unavailable runtime_version_not_qualified model_configuration_changed teardown_failed usage_or_cleanup_unverified restored_requires_reevaluation)
  @recorded_reasons @recorded_reasons ++
                      ~w(coding_transport_unavailable coding_transport_unsupported local_docker_required coding_transport_changed coding_cleanup_context_invalid coding_cleanup_origin_unknown)
  @limitations [
    "This read-only observation is not approval; release commands repeat admission.",
    "Live runtime and model availability were not checked. Recorded run observations are historical.",
    "Current Managed coding task applicability and release admission require a live runtime identity check and are not assessed here.",
    "The built-in suite is synthetic; its results do not establish company fitness.",
    "Local plan bindings do not establish portable approval authority.",
    "Eligibility rechecks stored policy origin and required saved conflict resolution; semantic correctness and authenticated portable approvals remain outside this inspection."
  ]

  @spec for_artifact(String.t(), String.t() | nil) :: {:ok, map()} | {:error, atom()}
  def for_artifact(digest, evaluation_id \\ nil) do
    if digest_reference?(digest) and evaluation_reference?(evaluation_id) do
      Purge.synchronize(fn ->
        with :ok <- Workspaces.ensure_writable() do
          {:ok, inspect_artifact(digest, evaluation_id)}
        end
      end)
    else
      {:error, :invalid_readiness_reference}
    end
  end

  defp digest_reference?(digest),
    do: is_binary(digest) and byte_size(digest) == 64 and Validation.digest?(digest)

  defp evaluation_reference?(nil), do: true

  defp evaluation_reference?(id) when is_binary(id) and byte_size(id) == 36,
    do: match?({:ok, _}, Ecto.UUID.cast(id))

  defp evaluation_reference?(_), do: false

  defp inspect_artifact(digest, evaluation_id) do
    report = base_report(digest, evaluation_id)

    # Artifacts.read/1 may create a missing store. A diagnostic query must not.
    with {:ok, %{type: :directory}} <- File.lstat(Path.join(Workspaces.root(), "artifacts")),
         {:ok, artifact} <- Harnesses.get(digest) do
      inspect_verified(report, artifact, evaluation_id)
    else
      _ ->
        finish(report, [stage("integrity", "blocked", "artifact_integrity_unavailable")])
    end
  end

  defp inspect_verified(report, artifact, evaluation_id) do
    {identities, assessment} = current_task_identities(artifact)
    eligibility = result_stage("eligibility", Harnesses.eligible(artifact), "currently_eligible")
    runtime = runtime_stage(artifact)
    {run_stages, run_identities} = inspect_evaluation(artifact, evaluation_id)

    report
    |> Map.put("plan_bindings", plan_bindings(artifact["digest"]))
    |> Map.put("current_identities", safe_identities(identities))
    |> Map.put("current_identity_assessment", assessment)
    |> Map.put("evaluation_identities", run_identities)
    |> finish(
      [stage("integrity", "passed", "artifact_verified"), eligibility, runtime] ++ run_stages
    )
  end

  defp base_report(digest, evaluation_id) do
    %{
      "artifact_digest" => digest,
      "evaluation_id" => evaluation_id,
      "observed_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "plan_bindings" => [],
      "current_identities" => %{},
      "current_identity_assessment" =>
        identity_assessment("not_assessed", "artifact_integrity_required"),
      "evaluation_identities" => %{},
      "stages" => [],
      "blockers" => [],
      "next_action" => %{},
      "limitations" => @limitations
    }
  end

  defp current_task_identities(artifact) do
    if managed_coding?(artifact) do
      {%{}, identity_assessment("not_assessed", "runtime_identity_check_required")}
    else
      {Evaluations.applicability(artifact),
       identity_assessment("passed", "current_task_identities_observed")}
    end
  end

  defp identity_assessment(status, reason),
    do: %{"kind" => "task", "status" => status, "reason_code" => reason}

  defp managed_coding?(artifact),
    do: get_in(artifact, ["spec", "spec", "runtime", "name"]) in ~w(opencode codex)

  defp plan_bindings(digest) do
    Repo.all(from b in Store.scoped(ArtifactBinding), where: b.artifact_digest == ^digest)
    |> Enum.filter(
      &(evaluation_reference?(&1.plan_id) and digest_reference?(&1.plan_revision_hash))
    )
    |> Enum.map(&%{"plan_id" => &1.plan_id, "plan_revision_hash" => &1.plan_revision_hash})
    |> Enum.sort_by(&{&1["plan_id"], &1["plan_revision_hash"]})
  end

  defp safe_identities(identities) do
    digests =
      for key <- @identity_digests,
          digest_reference?(identities[key]),
          into: %{},
          do: {key, identities[key]}

    labels =
      for key <- @identity_labels,
          safe_label?(identities[key]),
          into: %{},
          do: {key, identities[key]}

    Map.merge(digests, labels)
    |> maybe_scope_digest(identities["scope"])
  end

  defp safe_label?(value) when is_binary(value) and byte_size(value) in 1..512,
    do: Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._:\/@+-]*\z/, value)

  defp safe_label?(_), do: false

  defp maybe_scope_digest(identities, scope) when is_map(scope),
    do: Map.put(identities, "scope_digest", Contracts.digest(scope))

  defp maybe_scope_digest(identities, _), do: identities

  defp runtime_stage(artifact) do
    runtime = get_in(artifact, ["spec", "spec", "runtime", "name"])
    target = Enum.find(Registry.list(), &(&1["name"] == runtime))

    cond do
      is_nil(target) or target["managed_backend"] == "unavailable" ->
        stage("managed_runtime", "unavailable", "runtime_backend_unavailable")

      Coding.model_identity() == "unavailable" ->
        stage("managed_runtime", "unavailable", "model_not_selected")

      true ->
        stage("managed_runtime", "not_assessed", "live_availability_not_assessed")
    end
  end

  defp inspect_evaluation(_artifact, nil), do: unavailable_evaluation("no_evaluation_selected")

  defp inspect_evaluation(artifact, id) do
    case Evaluations.get(id) do
      {:ok, run} when is_map(run) -> inspect_owned_run(artifact, run)
      {:ok, _} -> unavailable_evaluation("invalid_evaluation_record")
      _ -> unavailable_evaluation("evaluation_unavailable")
    end
  end

  defp inspect_owned_run(artifact, run) do
    cond do
      run["artifact_digest"] != artifact["digest"] ->
        unavailable_evaluation("evaluation_artifact_mismatch")

      run["workspace_id"] != Workspaces.current_id() ->
        unavailable_evaluation("evaluation_workspace_mismatch")

      true ->
        {applicability, admission} = admission_stages(artifact, run)

        {[evaluation_stage(run), applicability, cleanup_stage(run), admission],
         safe_identities(run)}
    end
  end

  defp admission_stages(artifact, run) do
    cond do
      run["kind"] not in @kinds ->
        {stage("applicability", "not_assessed", "invalid_evaluation_record"),
         stage("release_admission", "blocked", "invalid_evaluation_record")}

      managed_coding?(artifact) and run["kind"] == "task" ->
        {stage("applicability", "not_assessed", "runtime_identity_check_required"),
         stage("release_admission", "not_assessed", "runtime_identity_check_required")}

      true ->
        {result_stage(
           "applicability",
           Evaluations.applicability(artifact, run),
           "identities_match"
         ),
         result_stage(
           "release_admission",
           Validation.check(artifact, run, artifact["spec"]["spec"]["scope"]),
           "ready_for_release_review"
         )}
    end
  end

  defp unavailable_evaluation(reason) do
    status = if reason == "no_evaluation_selected", do: "not_assessed", else: "blocked"

    {[
       stage("evaluation", status, reason),
       stage("applicability", "not_assessed", "selected_evaluation_required"),
       stage("cleanup", "not_assessed", "selected_evaluation_required"),
       stage("release_admission", "blocked", reason)
     ], %{}}
  end

  defp evaluation_stage(run) do
    kind = known(run["kind"], @kinds)
    outcome = known(run["outcome"], @outcomes)

    {status, reason} =
      cond do
        kind == "unknown" or outcome == "unknown" -> {"blocked", "invalid_evaluation_record"}
        outcome != "passed" -> {"blocked", "evaluation_" <> outcome}
        is_nil(run["completed_at"]) -> {"blocked", "evaluation_incomplete"}
        true -> {"passed", "evaluation_observed_pass"}
      end

    stage("evaluation", status, reason)
    |> Map.merge(%{"kind" => kind, "outcome" => outcome})
    |> recorded_reason(run["reason"])
  end

  defp recorded_reason(stage, reason) when reason in @recorded_reasons,
    do: Map.put(stage, "recorded_reason_code", reason)

  defp recorded_reason(stage, _), do: stage

  defp cleanup_stage(run) do
    cleanup = known(run["cleanup_status"], @cleanup_statuses)

    stage(
      "cleanup",
      if(cleanup == "complete", do: "passed", else: "blocked"),
      if(cleanup == "complete", do: "cleanup_complete", else: "evaluation_cleanup_incomplete")
    )
    |> Map.put("cleanup_status", cleanup)
  end

  defp known(value, values), do: if(value in values, do: value, else: "unknown")

  defp stage(name, status, reason),
    do: %{"name" => name, "status" => status, "reason_code" => reason}

  defp result_stage(name, :ok, success), do: stage(name, "passed", success)

  defp result_stage(name, {:error, reason}, _success) when is_atom(reason) do
    code = Atom.to_string(reason)
    stage(name, "blocked", if(code in @gate_reasons, do: code, else: "readiness_not_established"))
  end

  defp finish(report, observed) do
    stages =
      Enum.map(@stage_names, fn name ->
        Enum.find(observed, &(&1["name"] == name)) ||
          stage(name, "not_assessed", "artifact_integrity_required")
      end)

    blockers =
      stages
      |> Enum.filter(&(&1["status"] in ["blocked", "unavailable"]))
      |> Enum.map(fn item ->
        %{
          "stage" => item["name"],
          "code" => item["reason_code"],
          "action" => action(item)["code"]
        }
      end)

    report
    |> Map.put("stages", stages)
    |> Map.put("blockers", blockers)
    |> Map.put("next_action", next_action(stages))
  end

  defp next_action(stages) do
    [integrity, eligibility, runtime, evaluation, applicability, cleanup, admission] = stages

    cond do
      integrity["status"] != "passed" -> action(integrity)
      eligibility["status"] != "passed" -> action(eligibility)
      runtime["reason_code"] == "runtime_backend_unavailable" -> action(runtime)
      evaluation["status"] != "passed" -> action(evaluation)
      cleanup["status"] != "passed" -> action(cleanup)
      true -> evidence_action([applicability, admission])
    end
  end

  defp evidence_action(stages) do
    case Enum.find(stages, &(&1["status"] != "passed")) do
      nil -> %{"code" => "review_release", "destination" => "releases"}
      item -> action(item)
    end
  end

  defp action(%{"name" => "integrity"}),
    do: %{"code" => "review_package", "destination" => "package"}

  defp action(%{"name" => "eligibility"}),
    do: %{"code" => "review_company_plan", "destination" => "company"}

  defp action(%{"reason_code" => "runtime_backend_unavailable"}),
    do: %{"code" => "review_supported_runtime", "destination" => "company"}

  defp action(%{"reason_code" => "model_not_selected"}),
    do: %{"code" => "configure_model", "destination" => "connections"}

  defp action(%{"reason_code" => "runtime_identity_check_required"}),
    do: %{"code" => "review_runtime_identity", "destination" => "releases"}

  defp action(%{"reason_code" => code})
       when code in [
              "no_evaluation_selected",
              "evaluation_unavailable",
              "evaluation_artifact_mismatch",
              "evaluation_workspace_mismatch"
            ],
       do: %{"code" => "select_evaluation", "destination" => "evaluations"}

  defp action(%{"reason_code" => code})
       when code in [
              "stale_or_revoked_plan",
              "stale_or_revoked_evidence",
              "runtime_unqualified",
              "unsupported_required_control"
            ],
       do: %{"code" => "review_company_plan", "destination" => "company"}

  defp action(_), do: %{"code" => "review_evaluation", "destination" => "evaluations"}
end
