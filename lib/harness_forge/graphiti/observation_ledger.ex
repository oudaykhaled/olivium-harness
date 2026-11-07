defmodule HarnessForge.Graphiti.ObservationLedger do
  @moduledoc "Body-free wire identity, finite call state and single-use physical request bindings."
  alias HarnessForge.{Contracts, Repo}
  alias HarnessForge.Evidence.{GraphManifests, Store}
  alias HarnessForge.Graphiti.{ObservationFlow, Protocol}
  alias HarnessForge.Models.StageControl
  @error {:error, :closure_incomplete}

  # These helpers never dispatch or recover a capability. The live owner must
  # additionally validate its private session and ephemeral measured projection.
  def lookup(auth, page) do
    with {:ok, _} <- StageControl.graph_current(auth),
         :ok <- Protocol.validate_payload("context_page", page),
         {:ok, %{rows: rows}} <-
           Repo.query(
             "SELECT wire_digest,ack_json FROM graph_observation_events WHERE workspace_id=? AND operation_id=? AND context_id=?",
             [Store.workspace(), auth.operation_id, page["context_id"]]
           ) do
      case rows do
        [] ->
          {:ok, nil}

        [[digest, json]] ->
          with true <- digest == Protocol.context_page_digest(page),
               {:ok, ack} <- Contracts.decode_json(json),
               :ok <- Protocol.validate_payload("context_ack", ack),
               do: {:ok, ack},
               else: (_ -> {:error, :changed_replay})
      end
    else
      _ -> @error
    end
  end

  def call_state(auth, logical_call) do
    with {:ok, _} <- StageControl.graph_current(auth),
         {:ok, %{rows: rows}} <-
           Repo.query(
             "SELECT call_version,state_json FROM graph_observation_calls WHERE workspace_id=? AND operation_id=? AND logical_call_id=?",
             [Store.workspace(), auth.operation_id, logical_call]
           ) do
      case rows do
        [] ->
          {:ok, %{sequence: 0, state: nil}}

        [[sequence, json]] ->
          with {:ok, state} <- Contracts.decode_json(json),
               do: {:ok, %{sequence: sequence, state: state}}
      end
    else
      _ -> @error
    end
  end

  @doc "Commit after P/version/C sealing, within that same caller transaction; ACK only after commit."
  def append(auth, page, ack, sequence) do
    with true <- Repo.in_transaction?(),
         {:ok, _} <- StageControl.graph_current(auth),
         :ok <- Protocol.validate_payload("context_page", page),
         true <-
           page["page_index"] == 0 and page["final"] == true and
             is_nil(page["previous_page_digest"]),
         :ok <- Protocol.validate_payload("context_ack", ack),
         true <-
           ack["state"] == "sealed" and ack["job_id"] == auth.operation_id and
             ack["context_id"] == page["context_id"] and ack["page_index"] == 0 and
             ack["page_digest"] == Protocol.context_page_digest(page) and
             ack["allowed_body_sha256"] == page["raw_body_sha256"] and
             ack["context_manifest_ref"] != auth.manifest_id,
         {:ok, _} <-
           GraphManifests.validate_current(
             ack["context_manifest_ref"],
             ack["context_manifest_digest"],
             auth
           ),
         :ok <- version_ack(auth, page, ack),
         {:ok, %{sequence: ^sequence, state: previous}} <-
           call_state(auth, page["logical_call_id"]),
         {:ok, next} <-
           ObservationFlow.record(previous, page, %{
             "manifest_ref" => ack["context_manifest_ref"],
             "manifest_digest" => ack["context_manifest_digest"]
           }),
         encoded = Contracts.canonical_json(next),
         true <- byte_size(encoded) <= 16_384,
         :ok <- write_call(auth, page, sequence, next, encoded),
         {:ok, _} <-
           Repo.query(
             "INSERT INTO graph_observation_events(workspace_id,operation_id,context_id,logical_call_id,phase,wire_digest,manifest_id,ack_json,binding_state,inserted_at) VALUES(?,?,?,?,?,?,?,?,?,?)",
             [
               Store.workspace(),
               auth.operation_id,
               page["context_id"],
               page["logical_call_id"],
               page["phase"],
               Protocol.context_page_digest(page),
               ack["context_manifest_ref"],
               Contracts.canonical_json(ack),
               if(page["phase"] == "attempt_bind", do: "unused", else: "none"),
               now()
             ]
           ) do
      {:ok, next}
    else
      _ -> @error
    end
  rescue
    _ -> @error
  end

  defp version_ack(auth, page, ack) do
    entries = Map.new(page["entries"], &{&1["entry_id"], &1})
    references = ack["version_refs"]
    ids = Enum.uniq(Enum.map(references, & &1["version_ref"]))

    with true <-
           length(references) == map_size(entries) and
             Enum.sort(Enum.map(references, & &1["entry_id"])) == Enum.sort(Map.keys(entries)),
         true <- Enum.all?(ids, &HarnessForge.Evidence.Corpora.uuid?/1),
         {:ok, %{rows: rows}} <-
           Repo.query(
             "SELECT v.id,v.object_kind,v.value_hash,v.value_json,d.kind,d.content_hash,d.projection_id,d.projection_hash FROM graph_derivative_versions v JOIN origin_dependencies d ON d.workspace_id=v.workspace_id AND d.derivative_version_id=v.id AND d.manifest_id=? WHERE v.workspace_id=? AND v.partition_id=? AND v.id IN (" <>
               Enum.map_join(ids, ",", fn _ -> "?" end) <> ")",
             [ack["context_manifest_ref"], Store.workspace(), auth.partition_id] ++ ids
           ),
         versions = Enum.group_by(rows, &hd/1),
         true <-
           Enum.all?(references, fn reference ->
             entry = entries[reference["entry_id"]]
             kind = if entry["kind"] == "episode", do: "deterministic_output", else: entry["kind"]

             Enum.any?(Map.get(versions, reference["version_ref"], []), fn
               [_id, ^kind, full_hash, json, ^kind, full_hash, projection, projected] ->
                 projection == entry["projection_id"] and projected == entry["projection_hash"] and
                   ack_value?(entry, full_hash, json)

               _ ->
                 false
             end)
           end),
         do: :ok,
         else: (_ -> @error)
  end

  defp ack_value?(%{"projection_id" => "native_loader_no_vector_v1"} = entry, full_hash, json)
       when is_binary(json) do
    with true <- Contracts.sha256(json) == full_hash,
         {:ok, projected} <-
           HarnessForge.Graphiti.NativeProjection.projection_hash(
             json,
             "native_loader_no_vector_v1"
           ),
         do: projected == entry["value_hash"] and projected == entry["projection_hash"],
         else: (_ -> false)
  end

  defp ack_value?(%{"projection_id" => "native_loader_no_vector_v1"}, _, _), do: false
  defp ack_value?(entry, full_hash, _json), do: full_hash == entry["value_hash"]

  @doc "Atomically consume only after its exact stage-attempt reservation exists, in the admission transaction."
  def consume_binding(auth, attempt) do
    with true <- Repo.in_transaction?(),
         {:ok, _} <- StageControl.graph_current(auth),
         {:ok, %{num_rows: 1}} <-
           Repo.query(
             """
             UPDATE graph_observation_events SET binding_state='consumed',consumed_attempt_id=?
             WHERE workspace_id=? AND operation_id=? AND manifest_id=? AND logical_call_id=? AND binding_state='unused'
               AND json_extract(ack_json,'$.allowed_body_sha256')=?
               AND EXISTS(SELECT 1 FROM stage_attempts a JOIN graph_observation_calls c
                 ON c.workspace_id=a.workspace_id AND c.operation_id=a.operation_id AND c.logical_call_id=a.logical_call_id
                 WHERE a.workspace_id=graph_observation_events.workspace_id AND a.operation_id=graph_observation_events.operation_id
                   AND a.id=? AND a.logical_call_id=graph_observation_events.logical_call_id AND a.stage_config_id=c.stage_config_id
                   AND a.state='reserved' AND a.payload_hash=? AND c.state='active')
             """,
             [
               attempt["attempt_id"],
               Store.workspace(),
               auth.operation_id,
               attempt["context_manifest_ref"],
               attempt["logical_call_id"],
               attempt["payload_sha256"],
               attempt["attempt_id"],
               attempt["payload_sha256"]
             ]
           ) do
      :ok
    else
      _ -> @error
    end
  rescue
    _ -> @error
  end

  defp write_call(auth, page, 0, next, encoded) do
    case Repo.query(
           "INSERT INTO graph_observation_calls(workspace_id,operation_id,logical_call_id,stage_config_id,config_digest,schema_digest,prompt_name,call_version,state,state_json,inserted_at,updated_at) VALUES(?,?,?,?,?,?,?,1,?,?,?,?)",
           [
             Store.workspace(),
             auth.operation_id,
             page["logical_call_id"],
             page["stage_id"],
             page["config_digest"],
             page["schema_digest"],
             page["prompt_name"],
             if(next["finished"], do: "finished", else: "active"),
             encoded,
             now(),
             now()
           ]
         ) do
      {:ok, %{num_rows: 1}} -> :ok
      _ -> @error
    end
  end

  defp write_call(auth, page, sequence, next, encoded) do
    case Repo.query(
           "UPDATE graph_observation_calls SET call_version=call_version+1,state=?,state_json=?,updated_at=? WHERE workspace_id=? AND operation_id=? AND logical_call_id=? AND state='active' AND call_version=? AND stage_config_id=? AND config_digest=? AND schema_digest=? AND prompt_name=?",
           [
             if(next["finished"], do: "finished", else: "active"),
             encoded,
             now(),
             Store.workspace(),
             auth.operation_id,
             page["logical_call_id"],
             sequence,
             page["stage_id"],
             page["config_digest"],
             page["schema_digest"],
             page["prompt_name"]
           ]
         ) do
      {:ok, %{num_rows: 1}} -> :ok
      _ -> @error
    end
  end

  defp now, do: DateTime.to_iso8601(Store.now())
end
