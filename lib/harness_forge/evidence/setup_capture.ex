defmodule HarnessForge.Evidence.SetupCapture do
  @moduledoc false
  import Kernel, except: [binding: 1]
  import Ecto.Query
  alias HarnessForge.{Company, Contracts, Repo, Workspaces}

  alias HarnessForge.Company.{
    SetupRunCommand,
    SetupRunConfig,
    SetupRuns,
    SetupSession,
    SetupSessions
  }

  alias HarnessForge.Evidence.{
    Capture,
    CaptureRun,
    Connection,
    Corpora,
    LocalImport,
    LocalUseLifecycle,
    SetupCaptureBinding,
    SetupCaptureCounter,
    Store
  }

  @limits %{
    "max_files" => 500,
    "max_body_bytes" => 16_777_216,
    "max_file_bytes" => 1_048_576,
    "max_admitted_entries" => 10_000,
    "deadline_seconds" => 600
  }

  def limits, do: @limits

  # Internal setup cancellation joins the accepted command/selection transaction.
  # No scanner control or filesystem operation is performed while SQL is held.
  def cancel_bound_run(run_id) do
    if Repo.in_transaction?() do
      args = [Corpora.now(), Store.workspace(), Workspaces.operator(), run_id]

      Corpora.query!(
        """
        UPDATE capture_runs SET state='cancelled',lock_version=lock_version+1,
          lease_token=NULL,lease_until=NULL,updated_at=?
        WHERE workspace_id=? AND state IN('queued','running','paused') AND id IN(
          SELECT capture_id FROM setup_capture_bindings WHERE workspace_id=capture_runs.workspace_id
            AND owner_id=? AND run_id=?)
        """,
        args
      )

      Corpora.query!(
        """
        UPDATE setup_capture_charges SET state='uncertain',lock_version=lock_version+1
        WHERE workspace_id=? AND owner_id=? AND state='reserved' AND capture_id IN(
          SELECT capture_id FROM setup_capture_bindings WHERE workspace_id=? AND owner_id=? AND run_id=?)
        """,
        [
          Store.workspace(),
          Workspaces.operator(),
          Store.workspace(),
          Workspaces.operator(),
          run_id
        ]
      )

      :ok
    else
      {:error, :invalid_input}
    end
  end

  # Filesystem observation is deliberately outside the two short SQL fences.
  def preflight(session_id, connection_id, caller) do
    with {:ok, before} <- basis(session_id, connection_id, caller),
         {:ok, root} <- LocalImport.approved_directory(before.connection.directory),
         {:ok, fingerprint} <- Capture.fingerprint_for_setup(before.connection, root),
         {:ok, after_basis} <- basis(session_id, connection_id, caller),
         true <- before == after_basis do
      {:ok,
       %{
         "connection_id" => connection_id,
         "root_fingerprint" => fingerprint,
         "corpus_id" => before.corpus["id"],
         "semantic_generation" => before.corpus["semantic_generation"],
         "authorization_generation" => before.corpus["authorization_generation"]
       }}
    else
      false -> {:error, :stale_scope}
      error -> error
    end
  end

  defp basis(session_id, connection_id, caller) do
    with {:ok, dto} <- SetupSessions.get(%{"id" => session_id}, caller) do
      Corpora.guard(caller, fn ->
        with {:ok, session} <- Store.get(SetupSession, session_id),
             true <-
               session.owner == Workspaces.operator() and session.lock_version == dto["version"],
             selection = session.payload["selection"],
             true <-
               Enum.all?(
                 ~w(profile project repository goal),
                 &(get_in(dto, ["reference_status", "fields", &1]) == "current")
               ),
             %{"id" => project_id} <- selection["project"],
             {:ok, %{"id" => corpus_id, "state" => "active"} = corpus} <-
               Company.bound_corpus(project_id),
             true <- corpus_id == selection["corpus_id"],
             {:ok, connection} <- Store.get(Connection, connection_id),
             true <- connection.provider == "local" and connection.status == "active",
             :ok <- sole_connection(corpus_id, connection_id) do
          {:ok, %{connection: connection, corpus: corpus, session_version: session.lock_version}}
        else
          false -> {:error, :unsupported_configuration}
          {:ok, nil} -> {:error, :stale_scope}
          error -> error
        end
      end)
    end
  end

  defp sole_connection(corpus_id, connection_id) do
    %{rows: [[n]]} =
      Repo.query!(
        """
        SELECT count(*) FROM corpus_members m
        JOIN evidence_sources s ON s.id=m.source_id AND s.workspace_id=m.workspace_id
        JOIN corpora c ON c.id=m.corpus_id AND c.workspace_id=m.workspace_id
        WHERE m.workspace_id=? AND m.status='active' AND s.status='active' AND c.state='active'
          AND ((m.corpus_id=? AND s.connection_id!=?) OR (s.connection_id=? AND m.corpus_id!=?))
        """,
        [Store.workspace(), corpus_id, connection_id, connection_id, corpus_id]
      )

    if n == 0, do: :ok, else: {:error, :unsupported_configuration}
  end

  # Called only as part of the already accepted acquire command transaction.
  def start(config_ref, command_ref, caller) do
    with true <- Repo.in_transaction?(),
         {:ok, command} <- owned(SetupRunCommand, command_ref["id"]),
         true <-
           command.request_digest == command_ref["digest"] and
             command.request_json["action"] == "acquire",
         {:ok, config} <- owned(SetupRunConfig, config_ref["id"]),
         true <- config.digest == config_ref["digest"] and config.session_id == command.session_id,
         true <- config.scope_json["capture_limits"] == @limits,
         {:ok, operation} <- registered_capture(command, caller),
         true <- operation["config_ref"] == config_ref,
         {:ok, session} <- Store.get(SetupSession, command.session_id),
         {:ok, corpus} <- Company.bound_corpus(config.scope_json["project_ref"]["id"]),
         true <-
           is_map(corpus) and corpus["id"] == session.payload["selection"]["corpus_id"] and
             corpus["state"] == "active",
         {:ok, connection} <- Store.get(Connection, config.scope_json["connection_id"]),
         true <- connection.provider == "local" and connection.status == "active",
         :ok <- sole_connection(corpus["id"], connection.id),
         false <-
           Repo.exists?(
             from r in Store.scoped(CaptureRun), where: r.state in ["queued", "running", "paused"]
           ),
         {:ok, result} <- insert_capture(command, config, operation, corpus, connection) do
      {:ok, result}
    else
      true -> {:error, :queue_full}
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  defp registered_capture(command, caller) do
    case Corpora.rows(
           "SELECT operation_id FROM setup_run_operations WHERE workspace_id=? AND owner_id=? AND session_id=? AND command_id=? AND kind='capture'",
           [Store.workspace(), command.owner_id, command.session_id, command.command_id]
         ) do
      [%{"operation_id" => id}] -> SetupRuns.operation_binding(id, caller)
      _ -> {:error, :invalid_input}
    end
  end

  defp insert_capture(command, config, operation, corpus, connection) do
    now = Store.now()
    deadline = DateTime.add(now, 600, :second)
    id = operation["operation_ref"]["id"]

    scope = %{
      workspace_id: Store.workspace(),
      owner_id: command.owner_id,
      session_id: command.session_id
    }

    immutable = %{
      "run_id" => command.run_id,
      "config_ref" => %{"id" => config.id, "digest" => config.digest},
      "capture_id" => id,
      "command_id" => command.command_id,
      "connection_id" => connection.id,
      "root_fingerprint" => config.scope_json["root_fingerprint"],
      "limits" => @limits,
      "accepted_at" => DateTime.to_iso8601(now),
      "deadline" => DateTime.to_iso8601(deadline)
    }

    digest = Contracts.digest(immutable)

    with {:ok, _} <-
           Repo.insert(%CaptureRun{
             id: id,
             workspace_id: Store.workspace(),
             corpus_id: corpus["id"],
             connection_id: connection.id,
             root_fingerprint: immutable["root_fingerprint"],
             idempotency_key: digest,
             counts: %{
               "start_generation" => corpus["semantic_generation"],
               "setup_connection_digest" =>
                 Contracts.digest(%{
                   "directory" => connection.directory,
                   "config" => connection.config
                 })
             }
           }),
         {:ok, _} <-
           Repo.insert(
             struct(
               SetupCaptureBinding,
               Map.merge(scope, %{
                 run_id: command.run_id,
                 config_id: config.id,
                 capture_id: id,
                 command_id: command.command_id,
                 connection_id: connection.id,
                 root_fingerprint: immutable["root_fingerprint"],
                 limits_json: @limits,
                 accepted_at: now,
                 deadline: deadline,
                 digest: digest
               })
             )
           ),
         {:ok, _} <- Repo.insert(struct(SetupCaptureCounter, Map.merge(scope, %{capture_id: id}))),
         :ok <- bind_refresh(command, id),
         {:ok, _} <-
           HarnessForge.Jobs.Capture.new(%{"workspace_id" => Store.workspace(), "run_id" => id})
           |> Oban.insert() do
      Corpora.query!(
        "INSERT INTO capture_frontier(run_id,relative_path,state,scan_epoch,entry_count) VALUES(?,'','pending',1,0)",
        [id]
      )

      {:ok,
       %{
         "operation_ref" => operation["operation_ref"],
         "capture_ref" => %{"id" => id, "digest" => digest},
         "deadline" => immutable["deadline"]
       }}
    end
  end

  defp bind_refresh(command, capture_id) do
    case get_in(command.request_json, ["payload", "source_update_ref"]) do
      nil -> :ok
      reference ->
        case LocalUseLifecycle.bind_refresh_capture(
               reference,
               %{"id" => command.id, "digest" => command.request_digest},
               capture_id
             ) do
          :ok -> :ok
          {:ok, _} -> :ok
          {:error, _} = error -> error
        end
    end
  end

  def status(ref, caller) do
    Corpora.guard(caller, fn ->
      with {:ok, binding} <- binding(ref["id"]),
           true <- binding.owner_id == Workspaces.operator() and binding.digest == ref["digest"],
           {:ok, run} <- Store.get(CaptureRun, binding.capture_id),
           summary = Capture.snapshot_for_setup(run) do
        {:ok,
         %{
           "capture_ref" => ref,
           "run_id" => run.id,
           "state" => run.state,
           "scan_complete" => run.state == "scan_complete",
           "scan_verified" => run.scan_verified,
           "index_ready" =>
             summary["fts"]["state"] == "ready" and summary["scope_current"] == "current",
           "incomplete" => run.incomplete,
           "error_code" => run.error_code,
           "counts" => summary["capture"]["counts"],
           "limits" => binding.limits_json,
           "deadline" => DateTime.to_iso8601(binding.deadline)
         }}
      else
        false -> {:error, :not_found}
        error -> error
      end
    end)
  end

  def binding(capture_id) do
    case Repo.one(from b in Store.scoped(SetupCaptureBinding), where: b.capture_id == ^capture_id) do
      nil -> {:error, :not_found}
      value -> {:ok, value}
    end
  end

  defp owned(schema, id) do
    with {:ok, record} <- Store.get(schema, id),
         true <- record.owner_id == Workspaces.operator(),
         do: {:ok, record},
         else: (_ -> {:error, :not_found})
  end
end
