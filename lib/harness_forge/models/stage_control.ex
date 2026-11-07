defmodule HarnessForge.Models.StageControl do
  @moduledoc false
  alias HarnessForge.{Contracts, Repo}
  alias HarnessForge.Evidence.Store

  # Control tokens are server-owned capabilities. They never cross the worker
  # boundary and are invalidated durably before cancellation is delivered.
  def open(auth) do
    token = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    now = DateTime.to_iso8601(Store.now())

    with {:ok, %{num_rows: 1}} <-
           Repo.query(
             """
             INSERT INTO stage_operations
               (workspace_id,id,corpus_id,scope_ref,manifest_id,manifest_digest,stage_set_digest,
                caller_digest,control_token,semantic_generation,authorization_generation,
                cancel_epoch,state,deadline_at,inserted_at,updated_at,
                operation_type,partition_id,lease_id,worker_session_id,partition_lock_version,source_lock_digest,backend_pin_digest,
                authorization_id,budget_id,operation_binding_digest)
             SELECT ?,?,?,?,?,?,?,?,?,?,?,?,'active',?,?,?,?,?,?,?,?,?,?,?,?,?
             WHERE ?='synthesis' OR EXISTS(
               SELECT 1 FROM graph_partition_controls p WHERE p.id=? AND p.workspace_id=? AND p.group_id=?
                 AND p.corpus_id=? AND p.semantic_generation=? AND p.authorization_generation=?
                 AND p.cancel_epoch=? AND p.lock_version=?
                 AND p.source_lock_digest=? AND p.backend_pin_digest=?
                 AND p.state=CASE WHEN ?='search' THEN 'ready' ELSE 'staging' END)
             """,
             [
               auth.workspace_id,
               auth.operation_id,
               corpus_id(auth),
               auth.scope_ref,
               auth.manifest_id,
               auth.manifest_digest,
               stages(auth),
               caller(auth),
               token,
               auth.semantic_generation,
               auth.authorization_generation,
               auth.cancel_epoch,
               DateTime.to_iso8601(auth.deadline_at),
               now,
               now,
               auth.operation_type,
               auth.partition_id,
               auth.lease_id,
               auth.worker_session_id,
               auth.partition_lock_version,
               auth.source_lock_digest,
               auth.backend_pin_digest,
               auth.authorization_id,
               auth.budget_id,
               auth.operation_binding_digest,
               auth.operation_type,
               auth.partition_id,
               Store.workspace(),
               auth.scope_ref,
               auth.corpus_id,
               auth.semantic_generation,
               auth.authorization_generation,
               auth.cancel_epoch,
               auth.partition_lock_version,
               auth.source_lock_digest,
               auth.backend_pin_digest,
               auth.operation_type
             ]
           ) do
      {:ok, %{auth | control_token: token}}
    else
      _ -> {:error, :operation_already_started}
    end
  end

  def current(auth) do
    with true <- is_binary(auth.control_token),
         {:ok,
          %{
            rows: [
              [
                epoch,
                "active",
                deadline,
                token,
                scope,
                manifest,
                digest,
                stage_set,
                caller_digest,
                sem,
                access,
                corpus,
                type,
                partition,
                lease,
                session,
                lock_version,
                source_lock,
                backend_pin,
                authorization_id,
                budget_id,
                operation_binding_digest
              ]
            ]
          }} <-
           Repo.query(
             """
             SELECT cancel_epoch,state,deadline_at,control_token,scope_ref,manifest_id,
                    manifest_digest,stage_set_digest,caller_digest,semantic_generation,authorization_generation,
                    corpus_id,operation_type,partition_id,lease_id,worker_session_id,partition_lock_version,source_lock_digest,backend_pin_digest,
                    authorization_id,budget_id,operation_binding_digest
             FROM stage_operations WHERE workspace_id=? AND id=?
             """,
             [Store.workspace(), auth.operation_id]
           ),
         true <-
           epoch == auth.cancel_epoch and token == auth.control_token and
             scope == auth.scope_ref and manifest == auth.manifest_id and
             digest == auth.manifest_digest and
             stage_set == stages(auth) and caller_digest == caller(auth) and
             sem == auth.semantic_generation and access == auth.authorization_generation and
             corpus == corpus_id(auth) and type == auth.operation_type and
             partition == auth.partition_id and
             lease == auth.lease_id and session == auth.worker_session_id and
             lock_version == auth.partition_lock_version and
             source_lock == auth.source_lock_digest and backend_pin == auth.backend_pin_digest and
             authorization_id == auth.authorization_id and budget_id == auth.budget_id and
             operation_binding_digest == auth.operation_binding_digest,
         {:ok, deadline, _} <- DateTime.from_iso8601(deadline),
         true <- DateTime.compare(Store.now(), deadline) == :lt,
         :ok <- HarnessForge.Models.StageAuthority.assert_source_use(auth) do
      :ok
    else
      _ -> {:error, :cancelled}
    end
  end

  @doc false
  def graph_current(%HarnessForge.Models.StageAuthority{} = auth) do
    with true <-
           auth.workspace_id == Store.workspace() and
             auth.operation_type in ~w(ingest search remove),
         true <-
           Enum.all?(
             [auth.partition_id, auth.lease_id, auth.worker_session_id],
             &HarnessForge.Models.Stages.identifier?/1
           ),
         true <-
           HarnessForge.Evidence.Corpora.uuid?(auth.partition_id) and
             HarnessForge.Evidence.Corpora.uuid?(auth.lease_id),
         true <-
           HarnessForge.Models.Stages.digest?(auth.source_lock_digest) and
             HarnessForge.Models.Stages.digest?(auth.backend_pin_digest),
         :ok <- HarnessForge.Workspaces.ensure_writable(),
         :ok <- HarnessForge.Company.AssessmentAttempts.authorize(auth.caller),
         :ok <- current(auth),
         {:ok,
          %{rows: [[corpus, group, sem, access, epoch, state, lock_version, source, backend]]}} <-
           Repo.query(
             """
             SELECT corpus_id,group_id,semantic_generation,authorization_generation,cancel_epoch,state,lock_version,source_lock_digest,backend_pin_digest
             FROM graph_partition_controls WHERE workspace_id=? AND id=?
             """,
             [Store.workspace(), auth.partition_id]
           ),
         true <-
           corpus == auth.corpus_id and group == auth.scope_ref and
             sem == auth.semantic_generation and
             access == auth.authorization_generation and epoch == auth.cancel_epoch and
             lock_version == auth.partition_lock_version and
             source == auth.source_lock_digest and backend == auth.backend_pin_digest and
             (state == "ready" or (state == "staging" and auth.operation_type != "search")),
         :ok <- HarnessForge.Evidence.Corpora.assert_current(corpus, sem, access) do
      {:ok,
       %{
         "workspace_id" => Store.workspace(),
         "corpus_id" => corpus,
         "semantic_generation" => sem,
         "authorization_generation" => access,
         "partition_id" => auth.partition_id,
         "group_id" => group,
         "operation_id" => auth.operation_id,
         "job_id" => auth.operation_id,
         "session_id" => auth.worker_session_id,
         "lease_id" => auth.lease_id,
         "cancel_epoch" => epoch,
         "partition_lock_version" => lock_version,
         "stage_set_digest" => stages(auth),
         "source_lock_digest" => auth.source_lock_digest,
         "backend_pin_digest" => auth.backend_pin_digest,
         "operation_manifest_ref" => auth.manifest_id,
         "operation_manifest_digest" => auth.manifest_digest
       }}
    else
      _ -> {:error, :stale_generation}
    end
  end

  def graph_current(_), do: {:error, :scope_denied}

  # Bind a certified source scope once. Updating the partition temporarily inside
  # this transaction is not publication; failed certificate checks roll it back.
  def bind_graph_manifest(auth, id, digest) do
    HarnessForge.Privacy.Purge.synchronize(fn ->
      Store.transaction(fn ->
        with {:ok, _} <- graph_current(auth),
             true <- is_nil(auth.manifest_id) and is_nil(auth.manifest_digest),
             true <-
               HarnessForge.Evidence.Corpora.uuid?(id) and
                 HarnessForge.Models.Stages.digest?(digest),
             {:ok, %{num_rows: 1}} <-
               Repo.query(
                 "UPDATE graph_partition_controls SET manifest_id=? WHERE workspace_id=? AND id=? AND (manifest_id IS NULL OR manifest_id=?)",
                 [id, Store.workspace(), auth.partition_id, id]
               ),
             {:ok, _} <-
               HarnessForge.Evidence.GraphManifests.validate_scope_certificate(id, digest, auth),
             {:ok, %{num_rows: 1}} <-
               Repo.query(
                 """
                 UPDATE stage_operations SET manifest_id=?,manifest_digest=?,updated_at=?
                 WHERE workspace_id=? AND id=? AND state='active' AND control_token=? AND cancel_epoch=?
                   AND manifest_id IS NULL AND manifest_digest IS NULL
                 """,
                 [
                   id,
                   digest,
                   DateTime.to_iso8601(Store.now()),
                   Store.workspace(),
                   auth.operation_id,
                   auth.control_token,
                   auth.cancel_epoch
                 ]
               ) do
          {:ok, %{auth | manifest_id: id, manifest_digest: digest}}
        else
          _ -> {:error, :closure_incomplete}
        end
      end)
    end)
  end

  def complete(auth, result) do
    with :ok <- current(auth),
         {:ok, %{rows: [[total, 0]]}} <-
           Repo.query(
             """
             SELECT count(*),coalesce(sum(CASE WHEN state='completed' THEN 0 ELSE 1 END),0)
             FROM stage_attempts WHERE workspace_id=? AND operation_id=?
             """,
             [Store.workspace(), auth.operation_id]
           ),
         true <- total > 0,
         {:ok, %{num_rows: 1}} <-
           Repo.query(
             """
             UPDATE stage_operations SET state='completed',result_digest=?,updated_at=?
             WHERE workspace_id=? AND id=? AND state='active' AND cancel_epoch=? AND control_token=?
             """,
             [
               Contracts.digest(result),
               DateTime.to_iso8601(Store.now()),
               Store.workspace(),
               auth.operation_id,
               auth.cancel_epoch,
               auth.control_token
             ]
           ) do
      {:ok, result}
    else
      _ -> {:error, :reconcile_required}
    end
  end

  def cancel(auth) do
    Store.transaction(fn ->
      with {:ok, %{num_rows: 1}} <-
             Repo.query(
               """
               UPDATE stage_operations SET state='cancelled',cancel_epoch=cancel_epoch+1,updated_at=?
               WHERE workspace_id=? AND id=? AND state='active' AND cancel_epoch=? AND control_token=?
               """,
               [
                 DateTime.to_iso8601(Store.now()),
                 Store.workspace(),
                 auth.operation_id,
                 auth.cancel_epoch,
                 auth.control_token
               ]
             ) do
        if auth.partition_id && auth.operation_type != "search" do
          Repo.query!(
            """
            UPDATE graph_partition_controls SET state='reconcile_required',cancel_epoch=cancel_epoch+1,
              lock_version=lock_version+1,updated_at=? WHERE workspace_id=? AND id=? AND cancel_epoch=?
            """,
            [
              DateTime.to_iso8601(Store.now()),
              Store.workspace(),
              auth.partition_id,
              auth.cancel_epoch
            ]
          )
        end

        {:ok, auth.cancel_epoch + 1}
      else
        _ -> {:error, :cancelled}
      end
    end)
  end

  @doc false
  def close_without_result(%{authorization_id: authorization} = auth)
      when is_binary(authorization) do
    # Closing a failed logical operation grants no publication or resend. Known
    # settled attempts become terminal cancelled; any unresolved accounting
    # remains uncertain and therefore blocks retry across operation IDs.
    Store.transaction(fn ->
      with true <- auth.workspace_id == Store.workspace(),
           {:ok, %{rows: [[unresolved]]}} <-
             Repo.query(
               "SELECT count(*) FROM stage_attempts WHERE workspace_id=? AND operation_id=? AND state!='completed'",
               [Store.workspace(), auth.operation_id]
             ),
           {:ok, _} <-
             Repo.query(
               "UPDATE stage_operations SET state=?,cancel_epoch=cancel_epoch+1,updated_at=? WHERE workspace_id=? AND id=? AND state='active' AND control_token=? AND cancel_epoch=? AND authorization_id=? AND budget_id=? AND operation_binding_digest=?",
               [
                 if(unresolved == 0, do: "cancelled", else: "uncertain"),
                 DateTime.to_iso8601(Store.now()),
                 Store.workspace(),
                 auth.operation_id,
                 auth.control_token,
                 auth.cancel_epoch,
                 auth.authorization_id,
                 auth.budget_id,
                 auth.operation_binding_digest
               ]
             ),
           do: {:ok, :closed},
           else: (_ -> {:error, :reconcile_required})
    end)
  end

  # StartupGate calls this after migrations and before queues/endpoints. Billing
  # reservations survive; neither worker loss nor restart authorises a retry.
  def reconcile do
    Store.transaction(fn ->
      now = DateTime.to_iso8601(Store.now())

      Repo.query!(
        """
        UPDATE model_requests SET state='uncertain',updated_at=?
        WHERE workspace_id=? AND id IN (
          SELECT a.model_request_id FROM stage_attempts a JOIN stage_operations o
            ON o.workspace_id=a.workspace_id AND o.id=a.operation_id
          WHERE o.workspace_id=? AND a.state IN('reserved','dispatched'))
        """,
        [now, Store.workspace(), Store.workspace()]
      )

      Repo.query!(
        """
        UPDATE stage_attempts SET state='uncertain',grant_hash=NULL,updated_at=?
        WHERE workspace_id=? AND state IN('reserved','dispatched')
        """,
        [now, Store.workspace()]
      )

      Repo.query!(
        """
        UPDATE stage_operations SET state='uncertain',cancel_epoch=cancel_epoch+1,updated_at=?
        WHERE workspace_id=? AND state='active'
        """,
        [now, Store.workspace()]
      )

      Repo.query!(
        """
        UPDATE graph_partition_controls SET state='reconcile_required',cancel_epoch=cancel_epoch+1,
          lock_version=lock_version+1,updated_at=? WHERE workspace_id=? AND state IN('staging','ready')
        """,
        [now, Store.workspace()]
      )

      Repo.query!(
        "UPDATE graph_worker_sessions SET state='uncertain',updated_at=? WHERE workspace_id=? AND state IN('launching','ready','bound')",
        [now, Store.workspace()]
      )

      Repo.query!(
        "UPDATE graph_runtime_backends SET state='reconcile_required',updated_at=? WHERE workspace_id=? AND state!='stopped'",
        [now, Store.workspace()]
      )

      {:ok, :reconciled}
    end)
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp stages(auth), do: HarnessForge.Models.StageAuthority.stage_set_digest(auth)

  defp caller(auth),
    do:
      Contracts.digest(
        Map.new(
          Keyword.take(auth.caller, [:session_fingerprint, :view_generation, :reset_token]),
          fn {key, value} -> {Atom.to_string(key), value} end
        )
      )

  defp corpus_id(%{corpus_id: id}) when is_binary(id), do: id

  defp corpus_id(auth) do
    %{rows: [[id]]} =
      Repo.query!(
        "SELECT corpus_id FROM dependency_manifests WHERE workspace_id=? AND id=?",
        [Store.workspace(), auth.manifest_id]
      )

    id
  end
end
