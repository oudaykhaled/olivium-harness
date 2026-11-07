defmodule HarnessForge.Evidence.LocalUseLifecycle do
  @moduledoc """
  Local source/policy journal and bounded, idempotent corpus invalidation.
  Call mutation hooks only inside their owning privacy-before-SQL transaction.
  Oban is a wake-up; committed events and checkpoint CAS are the durable truth.
  """
  import Ecto.Query
  alias HarnessForge.{Contracts, Repo, Workspaces}
  alias HarnessForge.Company.{SetupRunCommand, SetupRunConfig}
  alias HarnessForge.Evidence.{Capture, CaptureRun, Connection, Corpora, LocalUseCheckpoint,
    LocalUseEvent, LocalUsePolicies, LocalUseSet, RevisionUseHolds, SetupCapture, Store}
  alias HarnessForge.Privacy.Purge
  @kinds ~w(activate withdraw upsert delete refresh_prepared refresh_bound refresh_activated privacy_barrier connection_revalidated)

  @doc "Latest workspace privacy fence identity; metadata only, never an authority token."
  def privacy_barrier do
    case Corpora.rows("SELECT id,sequence FROM local_use_events WHERE workspace_id=? AND stream_key='privacy' AND kind='privacy_barrier' ORDER BY sequence DESC LIMIT 1", [Store.workspace()]) do
      [] -> nil
      [%{"id" => id, "sequence" => sequence} = row] when is_integer(sequence) and sequence > 0 ->
        if Corpora.uuid?(id), do: row, else: raise(ArgumentError, "invalid local privacy barrier")
      _ -> raise ArgumentError, "invalid local privacy barrier"
    end
  end

  def replay(key, digest) do
    case Corpora.rows("SELECT id,request_digest FROM local_use_events WHERE workspace_id=? AND command_key=?", [Store.workspace(), key]) do
      [] -> {:ok, nil}
      [%{"id" => id, "request_digest" => ^digest}] -> event(id)
      _ -> {:error, :idempotency_conflict}
    end
  end

  def append_in_transaction(kind, identity, basis) when kind in @kinds do
    with true <- Repo.in_transaction?() and is_map(identity) and is_map(basis) and
           ((kind == "privacy_barrier" and identity == %{}) or
             (kind != "privacy_barrier" and (Corpora.uuid?(identity["set_id"]) or Corpora.uuid?(identity["source_id"])))) and
           is_binary(basis["command_key"]) and Corpora.digest?(basis["request_digest"]),
         {:ok, existing} <- replay(basis["command_key"], basis["request_digest"]) do
      if existing do
        if existing["kind"] == kind and existing["set_id"] == identity["set_id"] and
          existing["source_id"] == identity["source_id"], do: {:ok, existing},
          else: {:error, :idempotency_conflict}
      else
        stream = cond do
          kind == "privacy_barrier" -> "privacy"
          identity["source_id"] -> "source:" <> identity["source_id"]
          true -> "set:" <> identity["set_id"]
        end
        [%{"sequence" => sequence}] = Corpora.rows("SELECT coalesce(max(sequence),0)+1 AS sequence FROM local_use_events WHERE workspace_id=? AND stream_key=?", [Store.workspace(), stream])
        with {:ok, record} <- Repo.insert(%LocalUseEvent{workspace_id: Store.workspace(),
          set_id: identity["set_id"], source_id: identity["source_id"], stream_key: stream,
          sequence: sequence, kind: kind, command_key: basis["command_key"],
          request_digest: basis["request_digest"], payload_json: basis["payload"], inserted_at: Store.now()}),
          do: event(record.id)
      end
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end
  def append_in_transaction(_, _, _), do: {:error, :invalid_input}

  def policy_event(kind, set_id, key, digest, payload) when kind in ~w(activate withdraw refresh_activated) do
    with {:ok, event} <- append_in_transaction(kind, %{"set_id" => set_id},
      %{"command_key" => key, "request_digest" => digest, "payload" => payload}),
      :ok <- create_checkpoint(event["id"], "pending"),
      {:ok, _} <- HarnessForge.Jobs.LocalUseCleanup.new(%{"workspace_id" => Store.workspace(),
        "event_id" => event["id"]}) |> Oban.insert(), do: {:ok, event}
  end

  def event(id) do
    if Corpora.uuid?(id) do
      case Corpora.rows("SELECT id,workspace_id,set_id,source_id,sequence,kind,command_key,request_digest,payload_json FROM local_use_events WHERE workspace_id=? AND id=?", [Store.workspace(), id]) do
        [row] -> {:ok, row |> Map.delete("payload_json") |> Map.put("payload", decode(row["payload_json"]))}
        _ -> {:error, :source_use_denied}
      end
    else
      {:error, :invalid_input}
    end
  end

  def checkpoint(id) do
    case Corpora.rows("SELECT state,cursor_source_id,cursor_corpus_id,lock_version FROM local_use_checkpoints WHERE workspace_id=? AND event_id=? AND consumer='corpus_invalidation'", [Store.workspace(), id]) do
      [row] -> {:ok, row}
      _ -> {:error, :source_use_denied}
    end
  end

  def record_capture_upsert(capture_id, path, source_id, revision_id, body_hash) do
    with true <- Repo.in_transaction?() and safe_path?(path),
         {:ok, proof} <- verified_capture(capture_id),
         :ok <- Capture.check_lease(capture_id, proof.run.lease_token),
         [item] <- Corpora.rows("SELECT state FROM capture_items WHERE run_id=? AND relative_path=? AND scan_epoch=? AND source_id=? AND revision_id=? AND body_hash=? AND state IN('captured','unchanged')", [capture_id, path, proof.run.scan_epoch, source_id, revision_id, body_hash]),
         [%{"provider" => "local", "external_id" => ^path}] <- Corpora.rows("SELECT s.provider,s.external_id FROM evidence_sources s JOIN evidence_revisions r ON r.id=s.latest_revision_id AND r.source_id=s.id AND r.workspace_id=s.workspace_id WHERE s.workspace_id=? AND s.id=? AND s.connection_id=? AND r.id=? AND r.body_hash=?", [Store.workspace(), source_id, proof.binding.connection_id, revision_id, body_hash]) do
      key = "upsert:" <> source_id <> ":" <> revision_id
      payload = %{"source_id" => source_id, "revision_id" => revision_id, "body_hash" => body_hash,
        "capture_id" => capture_id, "binding_digest" => proof.binding.digest, "capture_item_key" => path}
      with {:ok, existing} <- replay(key, Contracts.digest(Map.take(payload, ~w(source_id revision_id body_hash)))) do
        cond do
          existing ->
            with true <- existing["kind"] == "upsert" and existing["source_id"] == source_id,
                 {:ok, %{"state" => "completed"}} <- checkpoint(existing["id"]),
                 do: {:ok, existing}, else: (_ -> {:error, :idempotency_conflict})
          item["state"] == "unchanged" -> {:ok, :unchanged}
          true ->
            with {:ok, event} <- append_in_transaction("upsert", %{"source_id" => source_id},
              %{"command_key" => key, "request_digest" => Contracts.digest(Map.take(payload, ~w(source_id revision_id body_hash))), "payload" => payload}),
              :ok <- create_checkpoint(event["id"], "completed"), do: {:ok, event}
        end
      end
    else
      false -> {:error, :invalid_input}
      {:error, _} = error -> error
      _ -> {:error, :source_use_denied}
    end
  end

  def record_delete(source_id) do
    with :ok <- owning_transaction(source_id),
         [source] <- Corpora.rows("SELECT id,provider,status,latest_revision_id,updated_at FROM evidence_sources WHERE workspace_id=? AND id=?", [Store.workspace(), source_id]),
         true <- source["provider"] == "local" and source["status"] != "active",
         true <- known_local_source?(source_id) do
      payload = %{"source_id" => source_id, "revision_id" => source["latest_revision_id"],
        "transition" => source["status"], "transition_at" => source["updated_at"]}
      with {:ok, event} <- append_in_transaction("delete", %{"source_id" => source_id},
        %{"command_key" => "delete:" <> source_id <> ":" <> Contracts.digest(payload),
          "request_digest" => Contracts.digest(payload), "payload" => payload}),
        :ok <- create_checkpoint(event["id"], "completed"), do: {:ok, event}
    else
      false -> {:ok, :unmanaged}
      {:error, _} = error -> error
      _ -> {:error, :source_use_denied}
    end
  end

  def bind_refresh_capture(refresh_ref, command_ref, capture_id) do
    with true <- Repo.in_transaction?() and ref?(refresh_ref) and ref?(command_ref),
         {:ok, prepared} <- event(refresh_ref["id"]),
         true <- prepared["kind"] == "refresh_prepared" and prepared["request_digest"] == refresh_ref["digest"],
         {:ok, proof} <- verified_capture(capture_id),
         true <- proof.command.id == command_ref["id"] and proof.command.request_digest == command_ref["digest"] and
           proof.command.request_json["source_update_ref"] == refresh_ref,
         :ok <- current_refresh(prepared, proof, true) do
      payload = Map.merge(prepared["payload"], %{"refresh_ref" => refresh_ref,
        "command_ref" => command_ref, "capture_id" => capture_id, "binding_digest" => proof.binding.digest})
      append_in_transaction("refresh_bound", %{"set_id" => prepared["set_id"]},
        %{"command_key" => "refresh_bound:" <> prepared["id"],
          "request_digest" => Contracts.digest(payload), "payload" => payload})
    else
      false -> {:error, :source_use_denied}
      error -> error
    end
  end

  def refresh_for_capture(capture_id) do
    with {:ok, proof} <- verified_capture(capture_id) do
      case Map.fetch(proof.command.request_json, "source_update_ref") do
        :error -> {:ok, nil}
        {:ok, ref} ->
          with true <- ref?(ref),
               {:ok, prepared} <- event(ref["id"]),
               true <- prepared["kind"] == "refresh_prepared" and prepared["request_digest"] == ref["digest"],
               [%{"id" => bound_id}] <- Corpora.rows("SELECT id FROM local_use_events WHERE workspace_id=? AND command_key=?", [Store.workspace(), "refresh_bound:" <> ref["id"]]),
               {:ok, bound} <- event(bound_id),
               true <- bound["payload"]["capture_id"] == capture_id and
                 bound["payload"]["binding_digest"] == proof.binding.digest,
               :ok <- current_refresh(prepared, proof, false) do
            {:ok, Map.take(bound["payload"], ~w(refresh_ref policy_ref policy_generation source_set_digest capture_id binding_digest privacy_barrier))}
          else
            _ -> {:error, :source_use_denied}
          end
      end
    end
  end

  def assert_refresh_write(capture_id, lease, path, identity) do
    with true <- Repo.in_transaction?() and safe_path?(path) and is_binary(lease),
         {:ok, proof} <- verified_capture(capture_id),
         :ok <- Capture.check_lease(capture_id, lease),
         {:ok, refresh} <- refresh_for_capture(capture_id),
         true <- is_map(refresh) and identity["external_id"] == path and
           identity["connection_id"] == proof.binding.connection_id and identity["provider"] == "local",
         {:ok, prepared} <- event(refresh["refresh_ref"]["id"]),
         :ok <- current_refresh(prepared, proof, true),
         [_] <- Corpora.rows("SELECT e.source_id FROM local_use_enrollments e JOIN local_use_items i ON i.set_id=e.set_id AND i.source_id=e.source_id AND i.workspace_id=e.workspace_id WHERE e.workspace_id=? AND e.source_id=? AND e.set_id=? AND e.grant_generation=? AND e.state='bound' AND e.connection_id=? AND e.provider='local' AND e.external_id=?", [Store.workspace(), identity["source_id"], refresh["policy_ref"]["id"], refresh["policy_generation"], identity["connection_id"], path]),
         [_] <- Corpora.rows("SELECT relative_path FROM capture_items WHERE run_id=? AND relative_path=? AND scan_epoch=? AND kind='file' AND state IN('pending','captured','unchanged')", [capture_id, path, proof.run.scan_epoch]),
         :ok <- RevisionUseHolds.assert_source_unheld(identity["source_id"]), do: :ok,
      else: (_ -> {:error, :source_use_denied})
  end

  def resume_in_transaction(event_id, expected) do
    with true <- Repo.in_transaction?() and is_integer(expected) and expected >= 0,
         {:ok, event} <- event(event_id), {:ok, checkpoint} <- checkpoint(event_id) do
      cond do
        expected > checkpoint["lock_version"] -> {:error, :policy_generation_conflict}
        expected < checkpoint["lock_version"] or checkpoint["state"] == "completed" -> {:ok, checkpoint}
        event["kind"] not in ~w(activate withdraw refresh_activated) -> {:error, :source_use_denied}
        true -> invalidate_page(event, checkpoint)
      end
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  def resume_pending(event_id) do
    Purge.synchronize(fn -> Store.transaction(fn ->
      with :ok <- Workspaces.ensure_writable(), :ok <- Purge.ready(),
           {:ok, checkpoint} <- checkpoint(event_id),
           do: resume_in_transaction(event_id, checkpoint["lock_version"])
    end) end)
  rescue
    _ -> {:error, :source_use_denied}
  end

  def wake_pending do
    with :ok <- Workspaces.ensure_writable(), :ok <- Purge.ready() do
      pending = Corpora.rows("SELECT event_id FROM local_use_checkpoints WHERE workspace_id=? AND state='pending' ORDER BY event_id LIMIT 100", [Store.workspace()])
      Enum.reduce_while(pending, :ok, fn row, :ok ->
        case HarnessForge.Jobs.LocalUseCleanup.new(%{"workspace_id" => Store.workspace(), "event_id" => row["event_id"]}) |> Oban.insert() do
          {:ok, _} -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp invalidate_page(event, checkpoint) do
      # The owning SQLite transaction commits effects and this one cursor CAS
      # together. A lost CAS rolls back every effect, including generation bumps.
      rows = Corpora.rows("SELECT m.source_id,m.corpus_id FROM corpus_members m JOIN local_use_items i ON i.source_id=m.source_id AND i.workspace_id=m.workspace_id WHERE m.workspace_id=? AND i.set_id=? AND (m.source_id>? OR (m.source_id=? AND m.corpus_id>?)) ORDER BY m.source_id,m.corpus_id LIMIT 101", [Store.workspace(), event["set_id"], checkpoint["cursor_source_id"], checkpoint["cursor_source_id"], checkpoint["cursor_corpus_id"]])
      page = Enum.take(rows, 100)
      Enum.each(page, fn member ->
        if event["kind"] == "withdraw" do
          Corpora.query!("UPDATE corpus_members SET passage_set_id=NULL,updated_at=? WHERE workspace_id=? AND corpus_id=? AND source_id=?", [Corpora.now(), Store.workspace(), member["corpus_id"], member["source_id"]])
        else
          Corpora.query!("UPDATE corpus_members SET passage_set_id=CASE WHEN EXISTS(SELECT 1 FROM passage_sets p JOIN evidence_sources s ON s.id=p.source_id AND s.workspace_id=p.workspace_id JOIN evidence_revisions r ON r.id=p.revision_id AND r.source_id=s.id AND r.workspace_id=s.workspace_id WHERE p.workspace_id=corpus_members.workspace_id AND p.id=corpus_members.passage_set_id AND p.source_id=corpus_members.source_id AND p.revision_id=corpus_members.revision_id AND p.state='ready' AND p.body_hash=r.body_hash AND s.status='active' AND s.latest_revision_id=r.id) THEN passage_set_id ELSE NULL END,updated_at=? WHERE workspace_id=? AND corpus_id=? AND source_id=?", [Corpora.now(), Store.workspace(), member["corpus_id"], member["source_id"]])
        end
        Corpora.advance(member["corpus_id"], true)
      end)
      last = List.last(page)
      source = if last, do: last["source_id"], else: checkpoint["cursor_source_id"]
      corpus = if last, do: last["corpus_id"], else: checkpoint["cursor_corpus_id"]
      changed = Corpora.query!("UPDATE local_use_checkpoints SET state=?,cursor_source_id=?,cursor_corpus_id=?,lock_version=lock_version+1,updated_at=? WHERE workspace_id=? AND event_id=? AND consumer='corpus_invalidation' AND state='pending' AND lock_version=?", [if(length(rows) > 100, do: "pending", else: "completed"), source, corpus, Corpora.now(), Store.workspace(), event["id"], checkpoint["lock_version"]])
      if changed.num_rows == 1, do: checkpoint(event["id"]),
        else: Repo.rollback(:policy_generation_conflict)
  end

  defp create_checkpoint(id, state) do
    case checkpoint(id) do
      {:ok, %{"state" => ^state}} -> :ok
      {:ok, _} -> {:error, :source_use_denied}
      _ ->
        with {:ok, _} <- Repo.insert(%LocalUseCheckpoint{event_id: id, workspace_id: Store.workspace(),
          state: state, updated_at: Store.now()}), do: :ok
    end
  end

  defp current_refresh(event, proof, require_unexpired) do
    payload = event["payload"]
    with {:ok, set} <- Store.get(LocalUseSet, event["set_id"]),
         true <- set.owner_id == Workspaces.operator() and set.owner_id == payload["owner_id"] and
           set.policy_digest == payload["policy_ref"]["digest"] and
           set.connection_id == proof.binding.connection_id and
           set.connection_digest == payload["connection_digest"] and
           set.root_fingerprint == proof.binding.root_fingerprint and
           set.root_fingerprint == payload["root_fingerprint"] and payload["limits"] == SetupCapture.limits(),
         {:ok, survivors} <- LocalUsePolicies.effective_enrollments(set, payload["policy_generation"]),
         true <- survivors != [] and Map.has_key?(payload, "privacy_barrier") and payload["privacy_barrier"] == privacy_barrier(),
         {:ok, source_digest} <- LocalUsePolicies.refresh_source_set_digest(set),
         true <- source_digest == payload["source_set_digest"],
         true <- Enum.all?(survivors, fn item ->
           RevisionUseHolds.assert_source_unheld(item["source_id"]) == :ok
         end),
         {:ok, expires, _} <- DateTime.from_iso8601(payload["expires_at"]),
         true <- not require_unexpired or DateTime.compare(expires, Store.now()) == :gt,
         do: :ok, else: (_ -> {:error, :source_use_denied})
  end

  defp verified_capture(id) do
    with {:ok, binding} <- SetupCapture.binding(id),
         true <- binding.owner_id == Workspaces.operator(),
         {:ok, run} <- Store.get(CaptureRun, id),
         {:ok, config} <- Store.get(SetupRunConfig, binding.config_id),
         [command] <- Repo.all(from c in Store.scoped(SetupRunCommand), where:
           c.owner_id == ^binding.owner_id and c.session_id == ^binding.session_id and c.command_id == ^binding.command_id),
         {:ok, connection} <- Store.get(Connection, binding.connection_id),
         true <- connection.provider == "local" and connection.status == "active" and
           connection.id == run.connection_id and binding.run_id == command.run_id and
           command.request_json["action"] == "acquire" and command.request_digest == Contracts.digest(command.request_json) and
           command.receipt_json["action"] == "acquire" and
           command.receipt_json["command_ref"] == %{"id" => command.id, "digest" => command.request_digest} and
           config.digest == Contracts.digest(config.scope_json) and config.owner_id == binding.owner_id and
           config.session_id == binding.session_id and config.scope_json["connection_id"] == connection.id and
           config.scope_json["capture_limits"] == binding.limits_json and
           config.scope_json["root_fingerprint"] == binding.root_fingerprint and
           binding.root_fingerprint == run.root_fingerprint and
           run.counts["setup_connection_digest"] == Contracts.digest(%{"directory" => connection.directory, "config" => connection.config}) and
           binding.digest == binding_digest(binding, config) and binding.limits_json == SetupCapture.limits(),
         do: {:ok, %{binding: binding, run: run, command: command, config: config}},
      else: (_ -> {:error, :source_use_denied})
  end

  defp binding_digest(binding, config), do: Contracts.digest(%{"run_id" => binding.run_id,
    "config_ref" => %{"id" => config.id, "digest" => config.digest}, "capture_id" => binding.capture_id,
    "command_id" => binding.command_id, "connection_id" => binding.connection_id,
    "root_fingerprint" => binding.root_fingerprint, "limits" => binding.limits_json,
    "accepted_at" => DateTime.to_iso8601(binding.accepted_at), "deadline" => DateTime.to_iso8601(binding.deadline)})
  defp known_local_source?(source_id), do: Corpora.rows("SELECT source_id FROM local_use_enrollments WHERE workspace_id=? AND source_id=? UNION SELECT ci.source_id FROM capture_items ci JOIN setup_capture_bindings b ON b.capture_id=ci.run_id AND b.workspace_id=? WHERE ci.source_id=? AND ci.state IN('captured','unchanged') LIMIT 1", [Store.workspace(), source_id, Store.workspace(), source_id]) != []
  defp owning_transaction(source_id), do: if(Repo.in_transaction?() and Corpora.uuid?(source_id),
    do: :ok, else: {:error, :invalid_input})
  defp safe_path?(path), do: Corpora.text?(path, 4096) and Path.type(path) == :relative and ".." not in Path.split(path)
  defp ref?(ref), do: Corpora.keys(ref, ~w(id digest)) == :ok and Corpora.uuid?(ref["id"]) and Corpora.digest?(ref["digest"])
  defp decode(value) when is_map(value), do: value
  defp decode(value), do: Jason.decode!(value)
end
