defmodule HarnessForge.Releases.Validation do
  @moduledoc false
  alias HarnessForge.{Contracts, Evaluations, Harnesses, Workspaces}

  @binding_fields ~w(suite_id suite_digest grader_digest task_fixture_digest runtime_version runtime_image model_id environment_profile_digest effective_config_digest capability_report_digest)
  @digests ~w(suite_digest grader_digest task_fixture_digest environment_profile_digest effective_config_digest capability_report_digest)

  def check(artifact, run, scope) do
    cond do
      run["workspace_id"] != Workspaces.current_id() ->
        {:error, :evaluation_workspace_mismatch}

      run["artifact_digest"] != artifact["digest"] ->
        {:error, :evaluation_artifact_mismatch}

      run["kind"] != "task" or run["outcome"] != "passed" or
          run["runtime_qualified"] != true ->
        {:error, :qualified_task_evaluation_required}

      run["cleanup_status"] != "complete" ->
        {:error, :evaluation_cleanup_incomplete}

      is_nil(run["completed_at"]) ->
        {:error, :evaluation_incomplete}

      scope != artifact["spec"]["spec"]["scope"] ->
        {:error, :release_scope_mismatch}

      artifact["spec"]["spec"]["runtime"]["version"] == "unqualified" ->
        {:error, :runtime_unqualified}

      run["runtime_version"] != artifact["spec"]["spec"]["runtime"]["version"] or
          run["suite_id"] != artifact["spec"]["spec"]["evaluation"]["suite"] ->
        {:error, :evaluation_inapplicable}

      not successful_checks?(run["checks"]) ->
        {:error, :evaluation_checks_incomplete}

      not Enum.all?(@digests, &digest?(run[&1])) ->
        {:error, :evaluation_inapplicable}

      not required_controls?(artifact) ->
        {:error, :unsupported_required_control}

      true ->
        with :ok <- Harnesses.eligible(artifact),
             :ok <- Evaluations.applicability(artifact, run) do
          :ok
        end
    end
  end

  def bindings(artifact, run) do
    Map.take(run, @binding_fields)
    |> Map.merge(%{
      "artifact_digest" => artifact["digest"],
      "spec_digest" => artifact["manifest"]["spec_digest"],
      "manifest_digest" => Contracts.digest(artifact["manifest"]),
      "evaluation_id" => run["id"],
      "evaluation_digest" => Contracts.digest(run),
      "scope" => artifact["spec"]["spec"]["scope"],
      "scope_digest" => Contracts.digest(artifact["spec"]["spec"]["scope"]),
      "policy_digest" => Contracts.digest(artifact["spec"]["spec"]["policies"])
    })
  end

  def digest?(value),
    do: is_binary(value) and Regex.match?(~r/^[a-f0-9]{64}$/, value)

  defp required_controls?(artifact) do
    Enum.all?(artifact["capabilities"], fn control ->
      control["required"] != true or
        control["status"] in ["supported_runtime", "enforced_external"]
    end)
  end

  defp successful_checks?(checks) when is_list(checks) and checks != [],
    do: Enum.all?(checks, &(is_map(&1) and &1["outcome"] == "passed"))

  defp successful_checks?(_), do: false
end
