defmodule HarnessForge.Evaluations do
  @moduledoc """
  Durable, workspace-scoped evaluations authored only by trusted checks.

  Static integrity and offline runtime smoke never qualify a coding runtime for
  release. Coding tasks qualify only from an observed isolated, metered model route
  and an independent protected grader under matching immutable identities.
  """
  import Ecto.Query
  alias HarnessForge.{Compiler, Contracts, Execution, Harnesses, Repo, Workspaces}
  alias HarnessForge.Evaluation.{Run, TaskSuite}
  alias HarnessForge.Execution.{Coding, Docker}
  alias HarnessForge.Models.Configuration

  @suite "synthetic-go-v1"
  @coding_profile "docker-coding-isolated-v2"
  @codex_profile "docker-codex-isolated-v1"
  @summary_kinds ~w(static_integrity runtime_smoke task)
  @summary_outcomes ~w(pending running passed failed blocked cancelled interrupted)
  @summary_reasons ~w(integrity_only offline_runtime_smoke_only finite_synthetic_task_observations operator_cancelled application_restarted restored_requires_reevaluation teardown_failed usage_or_cleanup_unverified model_service_unavailable model_unavailable runtime_cloud_disabled cloud_model_denied model_configuration_changed runtime_version_not_qualified model_not_selected runtime_backend_unavailable coding_transport_unavailable coding_transport_unsupported local_docker_required coding_transport_changed coding_cleanup_context_invalid coding_cleanup_origin_unknown runtime_config_unavailable runtime_smoke_not_qualified codex_image_receipt_missing codex_image_receipt_untrusted codex_image_receipt_mismatch codex_image_unverified codex_tools_unverified local_model_identity_unavailable local_model_identity_changed codex_preflight_rejected codex_events_rejected codex_runtime_config_invalid evaluation_authority_withdrawn task_runtime_failed task_time_limit task_output_limit protected_tests_failed protected_build_failed)

  @doc "Bounded historical metadata only; callers separately establish current artifact access."
  @spec recent_summaries(String.t()) :: {:ok, [map()]} | {:error, :evaluation_history_unavailable}
  def recent_summaries(digest) when is_binary(digest) and byte_size(digest) == 64 do
    with true <- String.valid?(digest) and Regex.match?(~r/\A[a-f0-9]{64}\z/, digest),
         {:ok, %{rows: rows}} <-
           Repo.query(
             """
             SELECT CASE WHEN typeof(id)='text' AND length(CAST(id AS BLOB))=36 THEN id ELSE NULL END,
               CASE WHEN typeof(inserted_at)='text' AND length(CAST(inserted_at AS BLOB))<=64 THEN inserted_at ELSE NULL END,
               #{summary_scalar("kind", @summary_kinds)},
               #{summary_scalar("outcome", @summary_outcomes)},
               CASE WHEN json_valid(result) THEN
                 CASE WHEN json_type(result,'$.reason')='null' THEN NULL
                   ELSE #{summary_scalar("reason", @summary_reasons)} END
                 ELSE 'unknown' END
             FROM evaluation_runs WHERE workspace_id=? AND artifact_digest=?
             ORDER BY inserted_at DESC,id DESC LIMIT 10
             """,
             @summary_kinds ++
               @summary_outcomes ++
               @summary_reasons ++
               [Workspaces.current_id(), digest],
             log: false
           ) do
      {:ok,
       Enum.map(rows, fn [id, inserted_at, kind, outcome, reason] ->
         %{
           "id" => if(match?({:ok, _}, Ecto.UUID.cast(id)), do: id, else: "unknown"),
           "inserted_at" => summary_timestamp(inserted_at),
           "kind" => kind,
           "outcome" => outcome,
           "reason" => reason
         }
       end)}
    else
      _ -> {:error, :evaluation_history_unavailable}
    end
  rescue
    _ -> {:error, :evaluation_history_unavailable}
  end

  def recent_summaries(_), do: {:error, :evaluation_history_unavailable}

  # SQL projects only bounded approved scalar values, never result/context maps.
  defp summary_scalar(field, values) do
    placeholders = Enum.map_join(values, ",", fn _ -> "?" end)

    "CASE WHEN json_valid(result) THEN CASE WHEN json_type(result,'$.#{field}')='text' " <>
      "AND json_extract(result,'$.#{field}') IN(#{placeholders}) " <>
      "THEN json_extract(result,'$.#{field}') ELSE 'unknown' END ELSE 'unknown' END"
  end

  defp summary_timestamp(value) when is_binary(value) do
    value = String.replace(value, " ", "T")

    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _} ->
        DateTime.to_iso8601(timestamp)

      _ ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, timestamp} ->
            timestamp |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()

          _ ->
            "unknown"
        end
    end
  end

  defp summary_timestamp(_), do: "unknown"

  @spec capabilities() :: map()
  def capabilities do
    probe = Execution.probe()
    tasks = Coding.availability()

    %{
      "status" => "limited",
      "static_integrity" => "available",
      "runtime_smoke" => if(match?({:ok, _}, probe), do: "available", else: "unavailable"),
      "task_evaluation" => if(tasks == :ok, do: "ready_unqualified", else: "blocked"),
      "reason" =>
        case tasks do
          :ok -> nil
          {:error, reason} -> Atom.to_string(reason)
        end,
      "runtime_qualified" => false,
      "runtime_image" => Docker.image(),
      "runtime_version" => Docker.version(),
      "environment_profile_digest" => Docker.profile_digest()
    }
  end

  @spec list_runs() :: {:ok, [map()]}
  def list_runs do
    {:ok,
     Repo.all(
       from r in Run,
         where: r.workspace_id == ^Workspaces.current_id(),
         order_by: [desc: r.inserted_at]
     )
     |> Enum.map(& &1.result)}
  end

  def get(id) when is_binary(id) do
    case Repo.one(
           from r in Run, where: r.workspace_id == ^Workspaces.current_id() and r.id == ^id
         ) do
      nil -> {:error, :evaluation_not_found}
      run -> {:ok, run.result}
    end
  rescue
    Ecto.Query.CastError -> {:error, :evaluation_not_found}
  end

  def get(_), do: {:error, :evaluation_not_found}

  @doc "Current trusted applicability identities for release validation."
  def applicability(artifact) do
    configuration = if coding?(artifact), do: Configuration.get()

    observation =
      if coding?(artifact) do
        case Coding.admit(artifact) do
          {:ok, observation} -> observation
          _ -> nil
        end
      end

    identity = applicability_identity(artifact, "task", observation, configuration)

    if coding?(artifact) and configuration != Configuration.get(),
      do: Map.put(identity, "environment_profile_digest", nil),
      else: identity
  end

  def applicability(artifact, run) when is_map(artifact) and is_map(run) do
    with {:ok, record} <- owned_record(run["id"]),
         true <- record.result == run and record.artifact_digest == artifact["digest"],
         true <- run["artifact_digest"] == artifact["digest"],
         :ok <- current_applicability(artifact, record, run) do
      :ok
    else
      _ -> {:error, :evaluation_inapplicable}
    end
  rescue
    _ -> {:error, :evaluation_inapplicable}
  end

  def applicability(_, _), do: {:error, :evaluation_inapplicable}

  defp current_applicability(artifact, record, candidate) do
    if candidate["kind"] == "task" and coding?(artifact) do
      configuration = Configuration.get()

      with {:ok, original} <- stored_observation(record),
           :ok <- Harnesses.eligible(artifact),
           {:ok, current} <- Coding.admit(artifact),
           true <- Coding.profile_digest(original) == Coding.profile_digest(current),
           identity = applicability_identity(artifact, "task", current, configuration),
           true <- Configuration.get() == configuration,
           true <- Map.take(candidate, Map.keys(identity)) == identity do
        :ok
      else
        _ -> {:error, :evaluation_inapplicable}
      end
    else
      identity = applicability_identity(artifact, candidate["kind"])

      if Map.take(candidate, Map.keys(identity)) == identity,
        do: :ok,
        else: {:error, :evaluation_inapplicable}
    end
  end

  defp applicability_identity(artifact, kind, observation \\ nil, configuration \\ nil) do
    task? = kind == "task"
    runtime = artifact["spec"]["spec"]["runtime"]
    opencode? = runtime["name"] == "opencode"
    coding? = runtime["name"] in ["opencode", "codex"]
    configuration = if task? and coding?, do: configuration || Configuration.get(), else: %{}

    config_files =
      Map.take(artifact["files"], HarnessForge.Adapters.Registry.config_paths(runtime["name"]))

    unavailable_profile =
      Contracts.digest(%{"runtime" => runtime, "execution_backend" => "unavailable"})

    identity =
      TaskSuite.identities()
      |> Map.merge(%{
        "artifact_digest" => artifact["digest"],
        "runtime_image" =>
          if(is_map(observation) and Map.has_key?(observation, :driver),
            do: Coding.runtime_image(observation),
            else: if(opencode?, do: Docker.image(), else: "unavailable:" <> runtime["name"])
          ),
        "runtime_version" => if(opencode?, do: Docker.version(), else: runtime["version"]),
        "environment_profile_digest" =>
          if(coding?,
            do:
              if(task?,
                do: if(observation, do: Coding.profile_digest(observation), else: nil),
                else: if(opencode?, do: Docker.profile_digest(), else: unavailable_profile)
              ),
            else: unavailable_profile
          ),
        "effective_config_digest" =>
          if(coding?,
            do:
              if(task?,
                do: Coding.config_digest(artifact),
                else:
                  if(opencode?,
                    do: Contracts.sha256(artifact["files"]["opencode.json"]),
                    else: Contracts.digest(config_files)
                  )
              ),
            else: Contracts.digest(config_files)
          ),
        "capability_report_digest" => Contracts.digest(artifact["capabilities"]),
        "policy_digest" => Contracts.digest(artifact["spec"]["spec"]["policies"]),
        "scope" => artifact["spec"]["spec"]["scope"],
        "model_id" =>
          if(task? and coding? and is_binary(configuration["model"]),
            do: "ollama/" <> configuration["model"],
            else: "unavailable"
          ),
        "model_context_digest" => Contracts.digest(configuration)
      })

    identity =
      if observation, do: Map.merge(identity, Coding.identity(observation)), else: identity

    identity =
      if task? and runtime["name"] == "codex",
        do:
          Map.put(
            identity,
            "execution_limits_digest",
            Contracts.digest(artifact["spec"]["spec"]["execution"])
          ),
        else: identity

    if task? and coding?,
      do: Map.put(identity, "execution_profile_id", Coding.profile_id(artifact)),
      else: identity
  end

  @spec run(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(digest, opts \\ []) do
    admission =
      HarnessForge.Privacy.Purge.synchronize(fn ->
        with :ok <- Workspaces.ensure_writable(),
             :ok <- valid_options(opts),
             {:ok, artifact} <- Harnesses.get(digest),
             :ok <- Harnesses.eligible(artifact),
             :ok <- Compiler.verify(artifact) do
          kind = normalize_kind(Keyword.get(opts, :kind, :task))

          if kind == :task and get_in(artifact, ["spec", "spec", "runtime", "name"]) == "codex" do
            {:codex_admission, artifact, kind}
          else
            with {:ok, record} <- create(artifact, kind), do: {:ok, {record, artifact}}
          end
        end
      end)

    # Codex metadata/image admission performs I/O. The second, local-only fence
    # establishes authority again before persisting any resource ownership.
    admission =
      case admission do
        {:codex_admission, artifact, kind} ->
          configuration = Configuration.get()
          observed = Coding.admit(artifact)

          HarnessForge.Privacy.Purge.synchronize(fn ->
            with :ok <- Workspaces.ensure_writable(),
                 :ok <- Harnesses.eligible(artifact),
                 :ok <- Compiler.verify(artifact),
                 {:ok, record} <- create(artifact, kind, {configuration, observed}),
                 do: {:ok, {record, artifact}}
          end)

        result ->
          result
      end

    with {:ok, {record, artifact}} <- admission do
      execute(record, artifact)
    end
  end

  @doc "Cancellation is accepted only for a persisted owned run; teardown is verified before completion."
  def cancel(id) do
    with {:ok, run} <- get(id) do
      cond do
        run["outcome"] in ~w(running pending) ->
          {:ok, _} =
            finish(id, %{
              "outcome" => "cancelled",
              "cleanup_status" => "pending",
              "runtime_qualified" => false,
              "reason" => "operator_cancelled"
            })

          case cleanup_record(id) do
            :ok ->
              finish(id, %{
                "outcome" => "cancelled",
                "cleanup_status" => "complete",
                "reason" => "operator_cancelled"
              })

            {:error, reason} ->
              finish(id, %{
                "outcome" => "cancelled",
                "cleanup_status" => "cleanup_failed",
                "reason" => cleanup_reason(reason)
              })
          end

        run["outcome"] == "cancelled" ->
          finish(id, %{})

        true ->
          {:ok, run}
      end
    end
  end

  @doc "Compare two observed runs only under matching suite/runtime/environment/grader/model identities."
  def compare(baseline_id, candidate_id) do
    with {:ok, baseline} <- get(baseline_id), {:ok, candidate} <- get(candidate_id) do
      keys =
        ~w(kind suite_id suite_digest grader_digest task_fixture_digest runtime_image runtime_version environment_profile_digest model_id model_context_digest scope driver_descriptor_digest image_receipt_digest protocol model_identity_digest codex_tools_digest codex_tools_profile_digest execution_limits_digest)

      if Map.take(baseline, keys) == Map.take(candidate, keys) do
        {:ok,
         %{
           "baseline" => baseline,
           "candidate" => candidate,
           "comparable" => true,
           "sample_count" => 1,
           "qualified" => baseline["runtime_qualified"] and candidate["runtime_qualified"],
           "conclusion" => "Finite observations only; no productivity claim."
         }}
      else
        {:error, :evaluation_identities_differ}
      end
    end
  end

  @doc "Boot barrier: retry failed cleanup and mark unfinished attempts interrupted."
  def reconcile, do: reconcile_unfinished()

  @doc false
  @spec cleanup_runs(:all | {:ids, [String.t()]}) :: :ok | {:error, :cleanup_failed}
  def cleanup_runs(scope) do
    with {:ok, records} <- cleanup_records(scope) do
      Enum.reduce_while(records, :ok, fn record, :ok ->
        case cleanup_record(record) do
          :ok ->
            persisted =
              if cleanup_backend(record) == :none,
                do: :ok,
                else: finish(record.id, %{"cleanup_status" => "complete"})

            if persisted == :ok or match?({:ok, _}, persisted),
              do: {:cont, :ok},
              else: {:halt, {:error, :cleanup_failed}}

          {:error, reason} ->
            finish(record.id, %{
              "cleanup_status" => "cleanup_failed",
              "runtime_qualified" => false,
              "reason" => cleanup_reason(reason)
            })

            {:halt, {:error, :cleanup_failed}}
        end
      end)
    end
  rescue
    _ -> {:error, :cleanup_failed}
  end

  defp reconcile_unfinished do
    unfinished =
      Repo.all(from r in Run, where: r.workspace_id == ^Workspaces.current_id())
      |> Enum.filter(
        &(&1.result["outcome"] in ~w(running pending) or
            &1.result["cleanup_status"] in ["cleanup_failed", "pending"])
      )

    if unfinished == [] do
      :ok
    else
      Enum.reduce_while(unfinished, :ok, fn record, :ok ->
        outcome =
          if record.result["outcome"] in ~w(running pending),
            do: "interrupted",
            else: record.result["outcome"]

        case cleanup_record(record) do
          :ok ->
            finish(record.id, %{
              "outcome" => outcome,
              "reason" =>
                if(record.result["outcome"] in ~w(running pending),
                  do: "application_restarted",
                  else: record.result["reason"]
                ),
              "cleanup_status" => "complete",
              "runtime_qualified" => false
            })

            {:cont, :ok}

          {:error, reason} ->
            finish(record.id, %{
              "outcome" => outcome,
              "reason" => cleanup_reason(reason),
              "cleanup_status" => "cleanup_failed",
              "runtime_qualified" => false
            })

            {:halt, {:error, :cleanup_failed}}
        end
      end)
    end
  end

  defp execute(record, artifact) do
    if (not coding?(artifact) or
          (not opencode?(artifact) and record.result["kind"] == "runtime_smoke")) and
         record.result["kind"] != "static_integrity" do
      finish(record.id, %{
        "outcome" => "blocked",
        "reason" => "runtime_backend_unavailable",
        "runtime_qualified" => false,
        "cleanup_status" => "not_started"
      })
    else
      execute_supported(record, artifact)
    end
  end

  defp execute_supported(record, artifact) do
    case record.result["kind"] do
      "task" ->
        if record.result["outcome"] == "blocked" do
          {:ok, record.result}
        else
          with {:ok, observation} <- stored_observation(record),
               {:ok, _} <- finish(record.id, %{"outcome" => "running"}) do
            finish(record.id, Coding.run(record.id, artifact, observation), artifact)
          else
            _ ->
              finish(record.id, %{
                "outcome" => "blocked",
                "reason" => "coding_cleanup_context_invalid",
                "runtime_qualified" => false,
                "cleanup_status" => "cleanup_failed"
              })
          end
        end

      "static_integrity" ->
        finish(record.id, %{
          "outcome" => "passed",
          "reason" => "integrity_only",
          "checks" => [%{"id" => "artifact_digest_and_manifest", "outcome" => "passed"}]
        })

      "runtime_smoke" ->
        runtime_smoke(record.id, artifact)
    end
  end

  defp runtime_smoke(id, artifact) do
    with {:ok, config} <- Jason.decode(artifact["files"]["opencode.json"]),
         {:ok, _} <- finish(id, %{"outcome" => "running"}) do
      Enum.reduce_while([:containment, :version, :config], {:ok, []}, fn kind, {:ok, checks} ->
        case execute_check(id, kind, config) do
          {:ok, check} ->
            {:cont, {:ok, checks ++ [check]}}

          {:error, outcome, reason, cleanup, check} ->
            {:halt, {:error, outcome, reason, cleanup, checks ++ [check]}}
        end
      end)
      |> case do
        {:ok, checks} ->
          finish(id, %{
            "outcome" => "passed",
            "reason" => "offline_runtime_smoke_only",
            "checks" => checks,
            "cleanup_status" => "complete"
          })

        {:error, outcome, reason, cleanup, checks} ->
          finish(id, %{
            "outcome" => outcome,
            "reason" => reason,
            "checks" => checks,
            "cleanup_status" => cleanup
          })
      end
    else
      _ -> finish(id, %{"outcome" => "blocked", "reason" => "runtime_config_unavailable"})
    end
  end

  defp execute_check(id, kind, config) do
    with {:ok, current} <- get(id),
         true <- current["outcome"] == "running",
         {:ok, handle} <- start_runtime(id, kind, config),
         {:ok, current} <- get(id),
         true <- current["outcome"] == "running",
         {:ok, result} <- Execution.await(handle),
         :ok <- sandbox_passed(result),
         :ok <- check_output(kind, result["output"]) do
      {:ok,
       %{
         "id" => Atom.to_string(kind),
         "outcome" => "passed",
         "output_digest" => Contracts.sha256(result["output"]),
         "duration_ms" => result["duration_ms"]
       }}
    else
      {:error, {:observed, result}} ->
        outcome = if result["outcome"] == "passed", do: "inconclusive", else: result["outcome"]
        reason = result["reason"] || "runtime_check_failed"

        {:error, outcome, reason, result["cleanup_status"],
         %{
           "id" => Atom.to_string(kind),
           "outcome" => outcome,
           "reason" => reason,
           "duration_ms" => result["duration_ms"],
           "output_digest" => Contracts.sha256(result["output"])
         }}

      {:error, reason}
      when reason in [
             :runtime_version_mismatch,
             :containment_checks_failed,
             :effective_runtime_config_mismatch
           ] ->
        cleanup = if Execution.cleanup(id) == :ok, do: "complete", else: "cleanup_failed"
        reason = Atom.to_string(reason)

        {:error, "failed", reason, cleanup,
         %{"id" => Atom.to_string(kind), "outcome" => "failed", "reason" => reason}}

      _ ->
        cleanup = if Execution.cleanup(id) == :ok, do: "complete", else: "cleanup_failed"

        {:error, "blocked", "runtime_smoke_not_qualified", cleanup,
         %{
           "id" => Atom.to_string(kind),
           "outcome" => "blocked",
           "reason" => "runtime_smoke_not_qualified"
         }}
    end
  end

  defp sandbox_passed(%{"outcome" => "passed", "cleanup_status" => "complete"}), do: :ok
  defp sandbox_passed(result), do: {:error, {:observed, result}}

  defp check_output(:version, output) do
    if String.trim(output) == Docker.version(), do: :ok, else: {:error, :runtime_version_mismatch}
  end

  defp check_output(:containment, output) do
    if String.trim(output) == "containment_checks_passed",
      do: :ok,
      else: {:error, :containment_checks_failed}
  end

  defp check_output(:config, output) do
    with {:ok, config} <- Jason.decode(output),
         true <-
           config["autoupdate"] == false and config["plugin"] == [] and
             config["enabled_providers"] == [] and config["mcp"] == %{} and
             config["lsp"] == false and config["formatter"] == false and
             get_in(config, ["permission", "*"]) == "deny" do
      :ok
    else
      _ -> {:error, :effective_runtime_config_mismatch}
    end
  end

  defp create(artifact, kind, prepared \\ :observe) do
    id = Ecto.UUID.generate()

    result = %{
      "id" => id,
      "workspace_id" => Workspaces.current_id(),
      "kind" => Atom.to_string(kind),
      "runtime_name" => artifact["spec"]["spec"]["runtime"]["name"],
      "runtime_qualified" => false,
      "outcome" => "pending",
      "reason" => nil,
      "checks" => [],
      "duration_ms" => 0,
      "usage_status" => "not_dispatched",
      "cleanup_status" => "not_started",
      "inserted_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "completed_at" => nil
    }

    coding? = kind == :task and coding?(artifact)

    {configuration, admission} =
      case prepared do
        {configuration, admission} ->
          {configuration, admission}

        :observe ->
          {if(coding?, do: Configuration.get()),
           if(coding?, do: Coding.admit(artifact), else: :none)}
      end

    Repo.transaction(fn ->
      with {:ok, result, context} <- admitted_result(artifact, result, admission, configuration),
           {:ok, record} <-
             Repo.insert(%Run{
               id: id,
               workspace_id: Workspaces.current_id(),
               artifact_digest: artifact["digest"],
               result: result,
               execution_context: context
             }) do
        if not is_nil(context) and Configuration.get() != configuration do
          {:ok, refused, nil} =
            admitted_result(
              artifact,
              result,
              {:error, :model_configuration_changed},
              configuration
            )

          case Repo.update(Ecto.Changeset.change(record, result: refused, execution_context: nil)) do
            {:ok, record} -> record
            _ -> Repo.rollback(:evaluation_persistence_failed)
          end
        else
          record
        end
      else
        _ -> Repo.rollback(:evaluation_persistence_failed)
      end
    end)
  rescue
    _ -> {:error, :evaluation_persistence_failed}
  end

  defp admitted_result(artifact, result, {:ok, observation}, configuration) do
    with {:ok, context} <-
           Coding.context(observation, Workspaces.current_id(), result["id"]) do
      identity = applicability_identity(artifact, result["kind"], observation, configuration)

      if Configuration.get() == configuration,
        do: {:ok, Map.merge(result, identity), context},
        else:
          admitted_result(artifact, result, {:error, :model_configuration_changed}, configuration)
    end
  end

  defp admitted_result(artifact, result, {:error, reason}, configuration) do
    result =
      result
      |> Map.merge(applicability_identity(artifact, result["kind"], nil, configuration))
      |> Map.merge(%{
        "outcome" => "blocked",
        "reason" => Atom.to_string(reason),
        "completed_at" => DateTime.to_iso8601(DateTime.utc_now())
      })

    {:ok, result, nil}
  end

  defp admitted_result(artifact, result, :none, _),
    do: {:ok, Map.merge(result, applicability_identity(artifact, result["kind"])), nil}

  defp finish(id, changes, artifact \\ nil) do
    pin = completion_pin(id, changes, artifact)

    persist = fn ->
      Repo.transaction(fn ->
        record =
          Repo.one!(
            from r in Run, where: r.id == ^id and r.workspace_id == ^Workspaces.current_id()
          )

        result =
          if record.result["outcome"] == "cancelled" do
            cancelled_result(record, changes, artifact)
          else
            changes = completion_changes(record, changes, artifact, pin)
            terminal = changes["outcome"] not in [nil, "running", "pending"]
            result = Map.merge(record.result, changes)

            result =
              if changes["outcome"] == "cancelled",
                do: Map.merge(result, Coding.settled_usage(record.id)),
                else: result

            result =
              if is_list(changes["checks"]),
                do:
                  Map.put(
                    result,
                    "duration_ms",
                    Enum.reduce(changes["checks"], 0, &((&1["duration_ms"] || 0) + &2))
                  ),
                else: result

            result =
              if terminal and is_nil(record.result["completed_at"]),
                do: Map.put(result, "completed_at", DateTime.to_iso8601(DateTime.utc_now())),
                else: result

            result
          end

        case record |> Ecto.Changeset.change(result: result) |> Repo.update() do
          {:ok, updated} -> updated.result
          _ -> Repo.rollback(:evaluation_persistence_failed)
        end
      end)
    end

    if pin == :none, do: persist.(), else: HarnessForge.Privacy.Purge.synchronize(persist)
  rescue
    _ -> {:error, :evaluation_persistence_failed}
  end

  # Cancellation wins the outcome race, not the accounting race. This path
  # reads settled usage from the owned Ledger and never trusts returned usage,
  # qualification, timestamps or identity fields from an execution result.
  defp cancelled_result(record, changes, _artifact) do
    cleanup =
      if changes["cleanup_status"] in ["complete", "cleanup_failed"],
        do: Map.take(changes, ["cleanup_status"]),
        else: %{}

    cleanup =
      if changes["outcome"] in [nil, "cancelled"],
        do: Map.merge(cleanup, Map.take(changes, ["reason"])),
        else: cleanup

    # Optional new task transcripts are deliberately withheld after cancellation.
    # In particular, do not run plan eligibility (which may roll back a nested
    # transaction on expected stale authority) inside this accounting write.
    # Previously stored checks and the noncancelled evidence path are unchanged.
    record.result
    |> Map.merge(cleanup)
    |> Map.merge(Coding.settled_usage(record.id))
    |> Map.merge(%{"outcome" => "cancelled", "runtime_qualified" => false})
  end

  defp completion_changes(record, %{"runtime_qualified" => true} = changes, artifact, pin) do
    candidate = Map.merge(record.result, changes)

    valid =
      with true <- is_map(artifact) and record.artifact_digest == artifact["digest"],
           true <- record.result["outcome"] in ~w(running pending),
           {:ok, original} <- stored_observation(record),
           keys = Map.keys(applicability_identity(artifact, "task", original)),
           true <- Map.take(candidate, keys) == Map.take(record.result, keys),
           :ok <- completion_applicability(artifact, record, candidate, pin) do
        :ok
      else
        _ -> :error
      end

    if valid == :ok do
      changes
    else
      Map.merge(changes, %{
        "runtime_qualified" => false,
        "outcome" =>
          if(changes["outcome"] == "passed", do: "inconclusive", else: changes["outcome"]),
        "reason" =>
          if(match?({:ok, _}, stored_observation(record)),
            do: "coding_transport_changed",
            else: "coding_cleanup_context_invalid"
          )
      })
    end
  end

  defp completion_changes(_, changes, _, _), do: changes

  defp completion_pin(id, %{"runtime_qualified" => true} = changes, artifact)
       when is_map(artifact) do
    if get_in(artifact, ["spec", "spec", "runtime", "name"]) == "codex" do
      configuration = Configuration.get()

      with false <- Repo.in_transaction?(),
           {:ok, record} <- owned_record(id),
           true <- record.result["outcome"] in ~w(running pending),
           {:ok, original} <- stored_observation(record),
           {:ok, current} <- Coding.admit(artifact),
           true <- Coding.profile_digest(original) == Coding.profile_digest(current),
           identity = applicability_identity(artifact, "task", current, configuration),
           true <- Configuration.get() == configuration,
           true <- Map.take(Map.merge(record.result, changes), Map.keys(identity)) == identity do
        %{record: record, observation: current, configuration: configuration}
      else
        _ -> :codex_rejected
      end
    else
      :none
    end
  end

  defp completion_pin(_, _, _), do: :none

  defp completion_applicability(artifact, record, candidate, %{
         record: original,
         observation: observed,
         configuration: config
       }) do
    with true <- record.id == original.id and record.workspace_id == original.workspace_id,
         true <- record.artifact_digest == original.artifact_digest,
         true <-
           record.execution_context == original.execution_context and
             record.result == original.result,
         true <- Configuration.get() == config,
         :ok <- Harnesses.eligible(artifact),
         identity = applicability_identity(artifact, "task", observed, config),
         true <- Map.take(candidate, Map.keys(identity)) == identity,
         do: :ok,
         else: (_ -> {:error, :evaluation_inapplicable})
  end

  defp completion_applicability(_, _, _, :codex_rejected), do: {:error, :evaluation_inapplicable}

  defp completion_applicability(artifact, record, candidate, :none),
    do: current_applicability(artifact, record, candidate)

  defp start_runtime(id, kind, config) do
    :global.trans({{Docker, Workspaces.current_id(), id}, self()}, fn ->
      with {:ok, current} <- get(id), true <- current["outcome"] == "running" do
        Execution.start(id, kind, config)
      else
        _ -> {:error, :evaluation_cancelled}
      end
    end)
  end

  defp owned_record(id) when is_binary(id) do
    case Repo.one(
           from r in Run, where: r.workspace_id == ^Workspaces.current_id() and r.id == ^id
         ) do
      nil -> {:error, :evaluation_not_found}
      record -> {:ok, record}
    end
  rescue
    Ecto.Query.CastError -> {:error, :evaluation_not_found}
  end

  defp owned_record(_), do: {:error, :evaluation_not_found}

  defp stored_observation(record) do
    with true <- record.result["execution_profile_id"] in [@coding_profile, @codex_profile],
         true <- record.result["kind"] == "task" and coding_runtime?(record.result),
         true <- record.result["id"] == record.id,
         true <- record.result["workspace_id"] == record.workspace_id,
         true <- record.result["artifact_digest"] == record.artifact_digest,
         {:ok, observation} <-
           Coding.decode_context(
             record.execution_context,
             record.result,
             Workspaces.current_id(),
             record.id
           ),
         true <-
           Coding.profile_digest(observation) == record.result["environment_profile_digest"] do
      {:ok, observation}
    else
      _ -> {:error, :coding_cleanup_context_invalid}
    end
  end

  defp cleanup_records(:all),
    do: {:ok, Repo.all(from r in Run, where: r.workspace_id == ^Workspaces.current_id())}

  defp cleanup_records({:ids, ids}) when is_list(ids) do
    if Enum.all?(ids, &match?({:ok, _}, Ecto.UUID.cast(&1))) do
      {:ok,
       Repo.all(from r in Run, where: r.workspace_id == ^Workspaces.current_id() and r.id in ^ids)}
    else
      {:error, :cleanup_failed}
    end
  end

  defp cleanup_records(_), do: {:error, :cleanup_failed}

  defp cleanup_record(id) when is_binary(id) do
    with {:ok, record} <- owned_record(id), do: cleanup_record(record)
  end

  defp cleanup_record(%Run{} = record) do
    result =
      with :ok <- Coding.stop_session(record.id) do
        case cleanup_backend(record) do
          :none -> :ok
          :smoke -> Execution.cleanup(record.id)
          :coding -> Coding.cleanup(record.id)
          {:error, reason} -> {:error, reason}
        end
      end

    case result do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      _ -> {:error, :cleanup_failed}
    end
  rescue
    _ -> {:error, :cleanup_failed}
  end

  defp cleanup_backend(%Run{result: result, execution_context: context} = record) do
    cond do
      result["reason"] == "restored_requires_reevaluation" and
        result["cleanup_status"] == "not_dispatched" and is_nil(context) ->
        :none

      not is_nil(context) ->
        if match?({:ok, _}, stored_observation(record)),
          do: :coding,
          else: {:error, :coding_cleanup_context_invalid}

      result["kind"] == "static_integrity" ->
        :none

      result["runtime_name"] == "claude_code" ->
        :none

      result["runtime_name"] == "codex" and result["execution_profile_id"] != @codex_profile ->
        :none

      result["kind"] == "runtime_smoke" and coding_runtime?(result) ->
        :smoke

      result["kind"] == "task" and
          result["execution_profile_id"] in [@coding_profile, @codex_profile] ->
        if result["outcome"] == "blocked" and result["cleanup_status"] == "not_started" and
             result["usage_status"] == "not_dispatched",
           do: :none,
           else: {:error, :coding_cleanup_context_invalid}

      result["kind"] == "task" and unresolved?(result) ->
        {:error, :coding_cleanup_origin_unknown}

      unresolved?(result) ->
        {:error, :coding_cleanup_origin_unknown}

      true ->
        :none
    end
  end

  defp coding_runtime?(result),
    do:
      result["runtime_name"] in ["opencode", "codex"] or
        (is_nil(result["runtime_name"]) and result["runtime_image"] == Docker.image())

  defp unresolved?(result),
    do:
      result["outcome"] in ~w(running pending) or
        result["cleanup_status"] in ~w(pending cleanup_failed)

  defp cleanup_reason(reason)
       when reason in [
              :coding_transport_unavailable,
              :coding_transport_unsupported,
              :local_docker_required,
              :coding_transport_changed,
              :coding_cleanup_context_invalid,
              :coding_cleanup_origin_unknown
            ],
       do: Atom.to_string(reason)

  defp cleanup_reason(_), do: "teardown_failed"

  defp opencode?(artifact),
    do: get_in(artifact, ["spec", "spec", "runtime", "name"]) == "opencode"

  defp coding?(artifact),
    do: get_in(artifact, ["spec", "spec", "runtime", "name"]) in ["opencode", "codex"]

  defp valid_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) -- [:suite, :kind] == [] and
         Keyword.get(opts, :suite, @suite) == @suite and
         Keyword.get(opts, :kind, :task) in [
           :task,
           :static_integrity,
           :runtime_smoke,
           "task",
           "static_integrity",
           "runtime_smoke"
         ],
       do: :ok,
       else: {:error, :invalid_evaluation_options}
  end

  defp valid_options(_), do: {:error, :invalid_evaluation_options}
  defp normalize_kind("task"), do: :task
  defp normalize_kind("static_integrity"), do: :static_integrity
  defp normalize_kind("runtime_smoke"), do: :runtime_smoke
  defp normalize_kind(kind), do: kind
end
