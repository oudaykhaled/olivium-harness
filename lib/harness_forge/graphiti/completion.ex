defmodule HarnessForge.Graphiti.Completion do
  @moduledoc """
  One-intent append completion behind root's irreversible writer retirement.

  Independent reader I/O runs outside SQL/privacy locks. Every bounded manifest
  and publication page revalidates the owner-local completion capability. Only
  an exhausted, bidirectional native inventory comparison permits the scalar
  binding/partition/operation CAS. This grants neither provider execution nor
  semantic, claim or plan approval. Each append captures the unchanged source
  certificate and exact previous inventory before any authoritative write.
  """
  alias HarnessForge.{Contracts, Repo}
  alias HarnessForge.Evidence.{Corpora, GraphManifests, Store}
  alias HarnessForge.Graphiti.{CompletionCommitment, IngestIntent, Protocol, Runtime}
  alias HarnessForge.Models.{StageAuthority, StageControl, Stages}

  @error {:error, :closure_incomplete}
  @ref ~w(id inventory_revision writer_id worker_image_id receipt_ids job_digest completion_digest base_inventory)
  @context ~w(graph_kind operation_manifest_ref operation_manifest_digest base_context_ref base_context_digest context_id logical_call_id seam_id stage_id prompt_name config_digest schema_digest raw_body_sha256 rendered_projection_digest transform_id receipt_ref receipt_digest)
  @row ~w(dependency_key kind source_id revision_id content_hash role episode_binding_id derivative_version_id projection_id projection_hash parent_manifest_id)
  @types [
    {"episode", "EpisodicNode", "deterministic_output"},
    {"entity", "EntityNode", "deterministic_output"},
    {"edge", "EntityEdge", "edge"},
    {"mention", "EpisodicEdge", "deterministic_output"}
  ]

  @spec publish(struct(), map(), map()) :: {:ok, map()} | {:error, atom()}
  def publish(%StageAuthority{operation_type: "ingest"} = auth, job, result) do
    with false <- Repo.in_transaction?(),
         :ok <- validate_request(auth, job, result),
         {:ok, ref} <- Runtime.begin_completion(auth, job, result) do
      # Normalize every handled work outcome before the mandatory owner cleanup.
      # Untrappable owner death is handled by Runtime's completion monitor.
      outcome = safely(fn -> complete(auth, job, result, ref) end)

      case safely(fn -> Runtime.end_completion(auth, ref, outcome) end) do
        :ok -> outcome
        _ -> @error
      end
    else
      error -> failure(error)
    end
  rescue
    _ -> @error
  catch
    :exit, _ -> @error
  end

  def publish(_, _, _), do: @error

  @doc false
  def validate_request(%StageAuthority{operation_type: "ingest"} = auth, job, result) do
    with :ok <- Protocol.validate_payload("job", job),
         {:ok, _} <- CompletionCommitment.digest(result),
         true <-
           job["op"] == "ingest" and is_list(job["args"]["prior_episode_ids"]) and
             length(job["args"]["prior_episode_ids"]) <= 24,
         true <- job["job_id"] == auth.operation_id and result["job_id"] == auth.operation_id,
         true <- result["generation"] == auth.semantic_generation,
         true <- result["closure_digest"] == auth.manifest_digest,
         true <- result["result"] == Map.take(job["args"], ~w(binding_id episode_uuid)),
         true <-
           job["scope_ref"] == auth.scope_ref and job["partition_id"] == auth.partition_id and
             job["worker_session_id"] == auth.worker_session_id and
             job["lease_id"] == auth.lease_id and job["cancel_epoch"] == auth.cancel_epoch and
             job["semantic_generation"] == auth.semantic_generation and
             job["authorization_generation"] == auth.authorization_generation and
             job["closure_ref"] == auth.manifest_id and
             job["closure_digest"] == auth.manifest_digest and
             job["stage_set_digest"] == StageAuthority.stage_set_digest(auth),
         true <- result["receipt_count"] in 1..256,
         do: :ok,
         else: (_ -> @error)
  rescue
    _ -> @error
  end

  def validate_request(_, _, _), do: @error

  @doc false
  def validate_reference(ref, job, result) do
    with true <- keys?(ref, @ref),
         true <-
           Corpora.uuid?(ref["id"]) and valid_base?(ref["base_inventory"]) and
             ref["inventory_revision"] == ref["base_inventory"]["inventory_revision"],
         true <- Stages.digest?(ref["writer_id"]) and image_id?(ref["worker_image_id"]),
         ids when is_list(ids) and length(ids) in 1..256 <- ref["receipt_ids"],
         true <- Enum.all?(ids, &Corpora.uuid?/1) and ids == Enum.uniq(ids),
         true <- ref["job_digest"] == Contracts.digest(job),
         {:ok, digest} <- CompletionCommitment.digest(result),
         true <- ref["completion_digest"] == digest,
         true <- result["receipt_count"] == length(ids),
         true <- result["receipt_digest"] == Contracts.digest(ids),
         do: :ok,
         else: (_ -> @error)
  rescue
    _ -> @error
  end

  @doc false
  def valid_base?(base) do
    keys?(base, ~w(inventory_revision inventory_manifest_id inventory_manifest_digest)) and
      is_integer(base["inventory_revision"]) and base["inventory_revision"] >= 0 and
      if(base["inventory_revision"] == 0,
        do: is_nil(base["inventory_manifest_id"]) and is_nil(base["inventory_manifest_digest"]),
        else:
          Corpora.uuid?(base["inventory_manifest_id"]) and
            Stages.digest?(base["inventory_manifest_digest"])
      )
  end

  @doc false
  def native_identity(record) do
    with true <- keys?(record, ~w(object_type fields vector_commitments)),
         true <- is_map(record["fields"]) and is_map(record["vector_commitments"]),
         uuid when is_binary(uuid) <- record["fields"]["uuid"],
         true <- Corpora.uuid?(uuid),
         {_, type, kind} <-
           Enum.find(@types, fn {_, type, _} -> type == record["object_type"] end),
         do: {:ok, {kind, type <> ":" <> uuid}},
         else: (_ -> @error)
  rescue
    _ -> @error
  end

  @doc false
  def compare_native(version, record, group) do
    with {:ok, {kind, object}} <- native_identity(record),
         true <-
           is_map(version) and version["object_kind"] == kind and version["object_id"] == object,
         true <- version["state"] in ~w(staging published),
         {:ok, value} <- canonical_value(version),
         true <- value == record and record["fields"]["group_id"] == group,
         do: :ok,
         else: (_ -> @error)
  rescue
    _ -> @error
  end

  defp complete(auth, job, result, ref) do
    with :ok <- validate_reference(ref, job, result),
         {:ok, state} <-
           guarded(auth, job, result, ref, fn -> start_inventory(auth, job, ref) end),
         {:ok, measured} <- measure(auth, job, result, ref, query("identity", nil, nil, 1)),
         :ok <- identity(measured),
         state = chain(state, "identity", measured),
         {:ok, state} <- scan_kinds(auth, job, result, ref, state),
         true <- state.counts["episode"] == ref["inventory_revision"] + 1,
         :ok <- support_pages(auth, job, result, ref, state.id, -1),
         {:ok, inventory} <- finish_inventory(auth, job, result, ref, state),
         :ok <- publish_versions(auth, job, result, ref, inventory, 0),
         {:ok, _} <- finalize(auth, job, result, ref, inventory, state),
         do: {:ok, result},
         else: (error -> failure(error))
  end

  defp start_inventory(auth, job, ref) do
    with {:ok, binding} <- binding(auth, job, ref["base_inventory"]),
         {:ok, prior} <- GraphManifests.inventory_parent(ref["base_inventory"], auth),
         {:ok, started} <-
           GraphManifests.begin_manifest(
             auth,
             "derivative",
             context(auth, ref["id"], auth.manifest_id, auth.manifest_digest)
           ),
         true <- started["phase"] == "receiving" and started["next_ordinal"] == 0,
         state = %{
           id: started["manifest_id"],
           page: 0,
           ordinal: 0,
           previous: nil,
           chain: Contracts.sha256("HF-GRAPH-COMPLETION-INVENTORY-v1\n"),
           pages: 0,
           counts: Map.new(@types, fn {kind, _, _} -> {kind, 0} end)
         },
         {:ok, state} <-
           append(
             auth,
             state,
             [parent_row(auth.manifest_id, auth.manifest_digest), binding_row(binding)] ++
               if(is_nil(prior),
                 do: [],
                 else: [
                   parent_row(prior["manifest_ref"], prior["manifest_digest"]),
                   parent_row(
                     ref["base_inventory"]["inventory_manifest_id"],
                     ref["base_inventory"]["inventory_manifest_digest"]
                   )
                 ]
               ),
             false
           ),
         do: {:ok, state},
         else: (_ -> @error)
  end

  defp scan_kinds(auth, job, result, ref, state) do
    Enum.reduce_while(@types, {:ok, state}, fn {kind, type, vkind}, {:ok, acc} ->
      case scan(auth, job, result, ref, acc, kind, type, vkind, nil) do
        {:ok, next} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
  end

  defp scan(auth, job, result, ref, state, kind, type, vkind, cursor) do
    with {:ok, measured} <- measure(auth, job, result, ref, query("page", kind, cursor, 10)),
         page = measured["result"],
         :ok <- page_order(page, cursor),
         {:ok, next} <-
           guarded(auth, job, result, ref, fn ->
             with {:ok, versions} <- native_page(auth, type, vkind, cursor, 10),
                  true <-
                    Enum.map(versions, & &1["object_id"]) ==
                      Enum.map(page["records"], &(type <> ":" <> &1["fields"]["uuid"])),
                  {:ok, rows} <-
                    compare_page(
                      auth,
                      job,
                      state.id,
                      versions,
                      page["records"],
                      ref["base_inventory"]
                    ),
                  :ok <- sql_exhaustion(auth, type, vkind, page, cursor),
                  {:ok, updated} <- append(auth, state, rows, false),
                  do: {:ok, updated},
                  else: (_ -> @error)
           end),
         next = chain(next, kind, measured),
         next = %{next | counts: Map.update!(next.counts, kind, &(&1 + length(page["records"])))} do
      if page["exhausted"],
        do: {:ok, next},
        else: scan(auth, job, result, ref, next, kind, type, vkind, page["next_cursor"])
    else
      error -> failure(error)
    end
  end

  defp measure(auth, job, result, ref, query) do
    with false <- Repo.in_transaction?(),
         :ok <- current(auth, job, result, ref),
         {:ok, measured} <- Runtime.completion_inventory(auth, ref, query),
         true <- keys?(measured, ~w(result receipt)) and is_map(measured["receipt"]),
         true <- measured["receipt"]["response_digest"] == Contracts.digest(measured["result"]),
         true <-
           measured["receipt"]["measurement"] ==
             "trusted-application-read-only-independent-path-v1",
         :ok <- current(auth, job, result, ref),
         do: {:ok, measured},
         else: (_ -> @error)
  end

  defp identity(%{"result" => %{"records" => [value], "exhausted" => true, "next_cursor" => nil}}) do
    if keys?(
         value,
         ~w(edition version database foreign_nodes foreign_edges unknown_nodes unknown_edges)
       ) and
         value["edition"] == "community" and value["version"] == "5.26.32" and
         is_binary(value["database"]) and byte_size(value["database"]) in 1..200 and
         Enum.all?(
           ~w(foreign_nodes foreign_edges unknown_nodes unknown_edges),
           &(value[&1] === 0)
         ), do: :ok, else: @error
  end

  defp identity(_), do: @error

  defp page_order(page, cursor) do
    ids = Enum.map(page["records"], &get_in(&1, ["fields", "uuid"]))

    if is_list(page["records"]) and length(ids) <= 10 and Enum.all?(ids, &Corpora.uuid?/1) and
         ids == Enum.sort(Enum.uniq(ids), :desc) and
         (is_nil(cursor) or Enum.all?(ids, &(&1 < cursor))) and
         is_boolean(page["exhausted"]) and
         ((page["exhausted"] and is_nil(page["next_cursor"])) or
            (not page["exhausted"] and ids != [] and page["next_cursor"] == List.last(ids))),
       do: :ok,
       else: @error
  end

  # Classify identities by any certified save, THEN select their absolute latest
  # version. A later denied, null or unsaved version can never expose an older one.
  defp native_page(auth, type, kind, cursor, limit) do
    prefix = type <> ":"

    sql = """
    SELECT v.id,v.object_kind,v.object_id,v.version,v.value_hash,v.state
    FROM graph_derivative_versions v
    WHERE v.workspace_id=? AND v.partition_id=? AND v.object_kind=?
      AND substr(v.object_id,1,?)=? AND (? IS NULL OR v.object_id<?)
      AND NOT EXISTS(SELECT 1 FROM graph_derivative_versions newer
        WHERE newer.workspace_id=v.workspace_id AND newer.partition_id=v.partition_id
          AND newer.object_kind=v.object_kind AND newer.object_id=v.object_id AND newer.version>v.version)
      AND EXISTS(SELECT 1 FROM graph_derivative_versions saved
        JOIN origin_dependencies d ON d.workspace_id=saved.workspace_id AND d.derivative_version_id=saved.id
        JOIN dependency_manifests m ON m.workspace_id=d.workspace_id AND m.id=d.manifest_id
        JOIN graph_manifest_builds b ON b.workspace_id=m.workspace_id AND b.manifest_id=m.id
        JOIN graph_observation_events e ON e.workspace_id=m.workspace_id AND e.manifest_id=m.id
        WHERE saved.workspace_id=v.workspace_id AND saved.partition_id=v.partition_id
          AND saved.object_kind=v.object_kind AND saved.object_id=v.object_id
          AND d.kind=saved.object_kind AND d.content_hash=saved.value_hash
          AND m.state='sealed' AND b.phase='sealed' AND b.partition_id=v.partition_id
          AND b.source_manifest_id=? AND b.source_manifest_digest=? AND e.phase='derived'
          AND json_extract(b.header_json,'$.context.seam_id')='graphiti.save.v1')
    ORDER BY v.object_id DESC LIMIT ?
    """

    rows(sql, [
      Store.workspace(),
      auth.partition_id,
      kind,
      byte_size(prefix),
      prefix,
      cursor,
      if(is_nil(cursor), do: nil, else: prefix <> cursor),
      auth.manifest_id,
      auth.manifest_digest,
      limit
    ])
  end

  defp sql_exhaustion(auth, type, kind, %{"exhausted" => true, "records" => records}, cursor) do
    after_id = if records == [], do: cursor, else: List.last(records)["fields"]["uuid"]

    case native_page(auth, type, kind, after_id, 1) do
      {:ok, []} -> :ok
      _ -> @error
    end
  end

  defp sql_exhaustion(_, _, _, _, _), do: :ok

  defp compare_page(auth, job, manifest, versions, records, base) do
    Enum.zip(versions, records)
    |> Enum.reduce_while({:ok, []}, fn {version, record}, {:ok, acc} ->
      with {:ok, full} <- full_version(version),
           :ok <- compare_native(full, record, auth.scope_ref),
           :ok <- support(auth, job, manifest, record, base),
           {:ok, deps} <- certified_version(auth, full, base),
           {:ok, projections} <- projections(auth, record, base),
           {:ok, bindings} <- episode_row(auth, record),
           do: {:cont, {:ok, acc ++ deps ++ projections ++ bindings}},
           else: (_ -> {:halt, @error})
    end)
  end

  defp full_version(version) do
    with {:ok, full} <-
           one("SELECT value_json FROM graph_derivative_versions WHERE workspace_id=? AND id=?", [
             Store.workspace(),
             version["id"]
           ]),
         do: {:ok, Map.merge(version, full)}
  end

  defp certified_version(auth, version, base) do
    case GraphManifests.inventory_version(
           base,
           version["object_kind"],
           version["object_id"],
           auth
         ) do
      {:ok, %{"id" => id, "value_hash" => hash, "parent" => parent}} ->
        if id == version["id"] and hash == version["value_hash"],
          do:
            {:ok,
             [parent_row(parent["manifest_ref"], parent["manifest_digest"]), version_row(version)]},
          else: current_saved_version(auth, version)

      _ ->
        current_saved_version(auth, version)
    end
  end

  defp current_saved_version(auth, version) do
    with {:ok, proof} <-
           one(
             """
             SELECT m.id,m.digest,d.projection_id,d.projection_hash
             FROM origin_dependencies d JOIN dependency_manifests m ON m.workspace_id=d.workspace_id AND m.id=d.manifest_id
             JOIN graph_manifest_builds b ON b.workspace_id=m.workspace_id AND b.manifest_id=m.id
             JOIN graph_observation_events e ON e.workspace_id=m.workspace_id AND e.manifest_id=m.id
             WHERE d.workspace_id=? AND d.derivative_version_id=? AND d.kind=? AND d.content_hash=?
               AND d.projection_id='identity_v1' AND d.projection_hash=d.content_hash
               AND m.state='sealed' AND b.phase='sealed' AND b.graph_kind='derived' AND b.partition_id=?
               AND b.source_manifest_id=? AND b.source_manifest_digest=? AND b.builder_operation_id=?
               AND e.operation_id=? AND e.phase='derived'
               AND json_extract(b.header_json,'$.context.seam_id')='graphiti.save.v1'
             ORDER BY m.id LIMIT 1
             """,
             [
               Store.workspace(),
               version["id"],
               version["object_kind"],
               version["value_hash"],
               auth.partition_id,
               auth.manifest_id,
               auth.manifest_digest,
               auth.operation_id,
               auth.operation_id
             ]
           ),
         {:ok, _} <- GraphManifests.validate_current(proof["id"], proof["digest"], auth),
         do: {:ok, [parent_row(proof["id"], proof["digest"]), version_row(version)]},
         else: (_ -> @error)
  end

  defp projections(auth, %{"object_type" => "EntityNode", "fields" => fields}, base) do
    Enum.reduce_while(~w(summary attribute), {:ok, []}, fn kind, {:ok, acc} ->
      field = if kind == "summary", do: "summary", else: "attributes"

      with {:ok, version} <- latest(auth, kind, "EntityNode:" <> fields["uuid"]),
           {:ok, value} <- canonical_value(version),
           true <- version["state"] in ~w(staging published) and value == fields[field],
           {:ok, deps} <- certified_version(auth, version, base),
           do: {:cont, {:ok, acc ++ deps}},
           else: (_ -> {:halt, @error})
    end)
  end

  defp projections(_, _, _), do: {:ok, []}

  defp support(auth, job, _manifest, %{"object_type" => "EpisodicNode", "fields" => fields}, base) do
    with {:ok, b} <-
           one(
             "SELECT id,passage_id,revision_id,payload_hash,state FROM graph_episode_bindings WHERE workspace_id=? AND partition_id=? AND episode_uuid=?",
             [Store.workspace(), auth.partition_id, fields["uuid"]]
           ),
         true <-
           (b["id"] == job["args"]["binding_id"] and b["state"] in ~w(staging indexing)) or
             b["state"] == "ready",
         {:ok, window} <- HarnessForge.Evidence.Passages.envelope(b["passage_id"]),
         true <-
           window["revision_id"] == b["revision_id"] and fields["name"] == b["id"] and
             fields["content"] == window["snippet"] and
             fields["source_description"] == b["revision_id"] and fields["source"] == "text" and
             fields["group_id"] == auth.scope_ref,
         true <-
           same_time?(
             fields["valid_at"],
             window["effective_at"] || window["event_at"] || window["captured_at"]
           ),
         {:ok, true} <-
           GraphManifests.contains_source?(
             auth.manifest_id,
             auth.manifest_digest,
             window["source_id"],
             auth
           ),
         :ok <- old_binding_member(auth, base, b),
         do: :ok,
         else: (_ -> @error)
  end

  defp support(_, _, _, %{"object_type" => "EntityNode"}, _), do: :ok

  defp support(auth, _job, manifest, %{"object_type" => type, "fields" => fields}, _base)
       when type in ~w(EntityEdge EpisodicEdge) do
    with :ok <- edge_episodes(auth, manifest, type, fields),
         :ok <-
           recorded_native(
             auth,
             manifest,
             if(type == "EntityEdge", do: "EntityNode", else: "EpisodicNode"),
             fields["source_node_uuid"]
           ),
         :ok <- recorded_native(auth, manifest, "EntityNode", fields["target_node_uuid"]),
         do: :ok,
         else: (_ -> @error)
  end

  defp support(_, _, _, _, _), do: @error

  defp edge_episodes(auth, manifest, "EntityEdge", fields) do
    ids = fields["episodes"]

    if is_list(ids) and length(ids) in 1..100 and ids == Enum.uniq(ids),
      do:
        Enum.reduce_while(ids, :ok, fn id, :ok ->
          case recorded_native(auth, manifest, "EpisodicNode", id) do
            :ok -> {:cont, :ok}
            _ -> {:halt, @error}
          end
        end),
      else: @error
  end

  defp edge_episodes(_, _, _, _), do: :ok

  defp old_binding_member(_, _, %{"state" => state}) when state in ~w(staging indexing), do: :ok

  defp old_binding_member(auth, base, b) do
    with {:ok, p} when is_map(p) <- GraphManifests.inventory_parent(base, auth),
         {:ok, %{rows: [[1]]}} <-
           Repo.query(
             "SELECT 1 FROM origin_dependencies WHERE workspace_id=? AND manifest_id=? AND kind='episode' AND episode_binding_id=? AND content_hash=? LIMIT 1",
             [Store.workspace(), p["manifest_ref"], b["id"], b["payload_hash"]]
           ),
         do: :ok,
         else: (_ -> @error)
  end

  defp episode_row(auth, %{"object_type" => "EpisodicNode", "fields" => f}) do
    with {:ok, b} <-
           one(
             "SELECT id,payload_hash FROM graph_episode_bindings WHERE workspace_id=? AND partition_id=? AND episode_uuid=?",
             [Store.workspace(), auth.partition_id, f["uuid"]]
           ),
         do: {:ok, [binding_row(b)]}
  end

  defp episode_row(_, _), do: {:ok, []}

  defp recorded_native(auth, manifest, type, uuid) do
    kind = if type == "EntityEdge", do: "edge", else: "deterministic_output"

    with true <- Corpora.uuid?(uuid),
         {:ok, %{rows: [[1]]}} <-
           Repo.query(
             """
             SELECT 1 FROM origin_dependencies d JOIN graph_derivative_versions v
               ON v.workspace_id=d.workspace_id AND v.id=d.derivative_version_id
             WHERE d.workspace_id=? AND d.manifest_id=? AND v.partition_id=?
               AND v.object_id=? AND v.object_kind=? AND d.kind=v.object_kind
               AND d.content_hash=v.value_hash AND v.state IN('staging','published') LIMIT 1
             """,
             [Store.workspace(), manifest, auth.partition_id, type <> ":" <> uuid, kind]
           ),
         do: :ok,
         else: (_ -> @error)
  end

  defp support_pages(auth, job, result, ref, manifest, after_ordinal) do
    with {:ok, page} <-
           guarded(auth, job, result, ref, fn ->
             with {:ok, page} <-
                    rows(
                      "SELECT d.ordinal,v.id FROM origin_dependencies d JOIN graph_derivative_versions v ON v.workspace_id=d.workspace_id AND v.id=d.derivative_version_id WHERE d.workspace_id=? AND d.manifest_id=? AND d.ordinal>? AND v.object_kind='deterministic_output' AND v.object_id LIKE 'EpisodicNode:%' ORDER BY d.ordinal LIMIT 100",
                      [Store.workspace(), manifest, after_ordinal]
                    ),
                  :ok <-
                    Enum.reduce_while(page, :ok, fn row, :ok ->
                      with {:ok, v} <-
                             one(
                               "SELECT value_hash,value_json FROM graph_derivative_versions WHERE workspace_id=? AND id=?",
                               [Store.workspace(), row["id"]]
                             ),
                           {:ok, value} <- canonical_value(v),
                           ids when is_list(ids) and length(ids) <= 100 <-
                             get_in(value, ["fields", "entity_edges"]),
                           true <- ids == Enum.uniq(ids),
                           :ok <-
                             Enum.reduce_while(ids, :ok, fn id, :ok ->
                               case recorded_native(auth, manifest, "EntityEdge", id) do
                                 :ok -> {:cont, :ok}
                                 _ -> {:halt, @error}
                               end
                             end),
                           do: {:cont, :ok},
                           else: (_ -> {:halt, @error})
                    end),
                  do: {:ok, page}
           end) do
      if length(page) < 100,
        do: :ok,
        else: support_pages(auth, job, result, ref, manifest, List.last(page)["ordinal"])
    end
  end

  defp latest(auth, kind, object) do
    one(
      "SELECT id,object_kind,object_id,version,value_hash,value_json,state FROM graph_derivative_versions WHERE workspace_id=? AND partition_id=? AND object_kind=? AND object_id=? ORDER BY version DESC LIMIT 1",
      [Store.workspace(), auth.partition_id, kind, object]
    )
  end

  defp finish_inventory(auth, job, result, ref, state) do
    with {:ok, closed} <- guarded(auth, job, result, ref, fn -> append(auth, state, [], true) end),
         {:ok, _} <-
           guarded(auth, job, result, ref, fn ->
             GraphManifests.finish_manifest(
               state.id,
               %{"dependency_count" => closed.ordinal, "source_count" => 0},
               auth
             )
           end),
         {:ok, sealed} <- validate_manifest(auth, job, result, ref, state.id),
         do: {:ok, sealed}
  end

  defp validate_manifest(auth, job, result, ref, id) do
    with {:ok, status} <-
           guarded(auth, job, result, ref, fn -> GraphManifests.advance_validation(id, auth) end) do
      if status["phase"] == "sealed" or status["state"] == "sealed",
        do: {:ok, status},
        else: validate_manifest(auth, job, result, ref, id)
    end
  end

  defp publish_versions(auth, job, result, ref, inventory, ordinal) do
    with {:ok, page} <-
           guarded(auth, job, result, ref, fn ->
             with {:ok, page} <-
                    GraphManifests.read_page(
                      inventory["manifest_id"],
                      inventory["digest"],
                      ordinal,
                      auth
                    ),
                  :ok <- publish_page(auth, page["rows"]),
                  do: {:ok, page}
           end) do
      if page["exhausted"],
        do: :ok,
        else: publish_versions(auth, job, result, ref, inventory, page["next_ordinal"])
    end
  end

  defp publish_page(auth, rows) when length(rows) <= 100 do
    Enum.reduce_while(rows, :ok, fn row, :ok ->
      if is_nil(row["derivative_version_id"]) do
        {:cont, :ok}
      else
        case Repo.query(
               "SELECT state FROM graph_derivative_versions WHERE workspace_id=? AND partition_id=? AND id=? AND value_hash=? AND object_kind=? AND state IN('staging','published') AND NOT EXISTS(SELECT 1 FROM graph_derivative_versions newer WHERE newer.workspace_id=graph_derivative_versions.workspace_id AND newer.partition_id=graph_derivative_versions.partition_id AND newer.object_kind=graph_derivative_versions.object_kind AND newer.object_id=graph_derivative_versions.object_id AND newer.version>graph_derivative_versions.version)",
               [
                 Store.workspace(),
                 auth.partition_id,
                 row["derivative_version_id"],
                 row["content_hash"],
                 row["kind"]
               ]
             ) do
          {:ok, %{rows: [["published"]]}} ->
            {:cont, :ok}

          {:ok, %{rows: [["staging"]]}} ->
            case Repo.query(
                   "UPDATE graph_derivative_versions SET state='published' WHERE workspace_id=? AND id=? AND state='staging'",
                   [Store.workspace(), row["derivative_version_id"]]
                 ) do
              {:ok, %{num_rows: 1}} -> {:cont, :ok}
              _ -> {:halt, @error}
            end

          _ ->
            {:halt, @error}
        end
      end
    end)
  end

  defp finalize(auth, job, result, ref, inventory, state) do
    guarded(
      auth,
      job,
      result,
      ref,
      fn ->
        value = %{
          "format" => "graph-ingest-completion-v2",
          "stage_pin_ids" => auth.stage_pins |> Enum.map(& &1["id"]) |> Enum.sort(),
          "stage_set_digest" => StageAuthority.stage_set_digest(auth),
          "job_digest" => ref["job_digest"],
          "completion_digest" => ref["completion_digest"],
          "writer_id" => ref["writer_id"],
          "worker_image_id" => ref["worker_image_id"],
          "receipt_ids" => ref["receipt_ids"],
          "source_manifest_ref" => auth.manifest_id,
          "source_manifest_digest" => auth.manifest_digest,
          "inventory_manifest_ref" => inventory["manifest_id"],
          "inventory_manifest_digest" => inventory["digest"],
          "inventory_revision" => ref["inventory_revision"] + 1,
          "previous_inventory_revision" => ref["inventory_revision"],
          "base_inventory" => ref["base_inventory"],
          "counts" => state.counts,
          "reader_receipt_chain" => state.chain,
          "reader_pages" => state.pages,
          "measurement_policy" => "trusted-application-read-only-independent-path-v1"
        }

        id = Ecto.UUID.generate()
        hash = Contracts.digest(value)

        with {:ok, %{rows: [[0]]}} <-
               Repo.query(
                 "SELECT count(*) FROM origin_dependencies d JOIN graph_derivative_versions v ON v.workspace_id=d.workspace_id AND v.id=d.derivative_version_id WHERE d.workspace_id=? AND d.manifest_id=? AND (v.state!='published' OR v.value_hash!=d.content_hash OR EXISTS(SELECT 1 FROM graph_derivative_versions n WHERE n.workspace_id=v.workspace_id AND n.partition_id=v.partition_id AND n.object_kind=v.object_kind AND n.object_id=v.object_id AND n.version>v.version))",
                 [Store.workspace(), inventory["manifest_id"]]
               ),
             {:ok, %{num_rows: 1}} <-
               Repo.query(
                 "INSERT INTO graph_derivative_versions(id,workspace_id,partition_id,object_kind,object_id,version,value_hash,value_json,manifest_id,predecessor_id,state,inserted_at) VALUES(?,?,?,'deterministic_output',?,1,?,?,?,NULL,'published',?)",
                 [
                   id,
                   Store.workspace(),
                   auth.partition_id,
                   "root_completion:" <> auth.operation_id,
                   hash,
                   Contracts.canonical_json(value),
                   inventory["manifest_id"],
                   now()
                 ]
               ),
             {:ok, started} <-
               GraphManifests.begin_manifest(
                 auth,
                 "derivative",
                 context(
                   auth,
                   Ecto.UUID.generate(),
                   inventory["manifest_id"],
                   inventory["digest"]
                 )
               ),
             receipt = %{
               "id" => id,
               "object_kind" => "deterministic_output",
               "value_hash" => hash
             },
             {:ok, _} <-
               GraphManifests.append_page(
                 started["manifest_id"],
                 %{
                   "page_index" => 0,
                   "first_ordinal" => 0,
                   "previous_page_digest" => nil,
                   "final" => true,
                   "rows" => [
                     parent_row(inventory["manifest_id"], inventory["digest"]),
                     version_row(receipt)
                   ]
                 },
                 auth
               ),
             {:ok, _} <-
               GraphManifests.finish_manifest(
                 started["manifest_id"],
                 %{"dependency_count" => 2, "source_count" => 0},
                 auth
               ),
             {:ok, sealed} <- seal_small(started["manifest_id"], auth, 2),
             :ok <- current(auth, job, result, ref),
             :ok <- ready_cas(auth, job, ref, sealed),
             do: {:ok, sealed},
             else: (_ -> @error)
      end,
      terminal: true
    )
  end

  defp ready_cas(auth, job, ref, sealed) do
    n = ref["inventory_revision"] + 1

    with {:ok, %{num_rows: 1}} <-
           Repo.query(
             "UPDATE graph_episode_bindings SET state='ready',publication_generation=?,updated_at=? WHERE workspace_id=? AND partition_id=? AND id=? AND episode_uuid=? AND state IN('staging','indexing') AND publication_generation IS NULL AND payload_hash=?",
             [
               n,
               now(),
               Store.workspace(),
               auth.partition_id,
               job["args"]["binding_id"],
               job["args"]["episode_uuid"],
               Contracts.digest(job["args"])
             ]
           ),
         {:ok, %{num_rows: 1}} <-
           Repo.query(
             "UPDATE graph_partition_controls SET state='ready',inventory_manifest_id=?,inventory_manifest_digest=?,inventory_revision=?,updated_at=? WHERE workspace_id=? AND id=? AND state='staging' AND inventory_revision=? AND inventory_manifest_id IS ? AND inventory_manifest_digest IS ? AND manifest_id=? AND lock_version=? AND cancel_epoch=? AND semantic_generation=? AND authorization_generation=? AND source_lock_digest=? AND backend_pin_digest=?",
             [
               sealed["manifest_id"],
               sealed["digest"],
               n,
               now(),
               Store.workspace(),
               auth.partition_id,
               ref["inventory_revision"],
               ref["base_inventory"]["inventory_manifest_id"],
               ref["base_inventory"]["inventory_manifest_digest"],
               auth.manifest_id,
               auth.partition_lock_version,
               auth.cancel_epoch,
               auth.semantic_generation,
               auth.authorization_generation,
               auth.source_lock_digest,
               auth.backend_pin_digest
             ]
           ),
         {:ok, %{num_rows: 1}} <-
           Repo.query(
             "UPDATE stage_operations SET state='completed',result_digest=?,updated_at=? WHERE workspace_id=? AND id=? AND state='active' AND control_token=? AND cancel_epoch=? AND partition_id=? AND worker_session_id=? AND lease_id=?",
             [
               ref["completion_digest"],
               now(),
               Store.workspace(),
               auth.operation_id,
               auth.control_token,
               auth.cancel_epoch,
               auth.partition_id,
               auth.worker_session_id,
               auth.lease_id
             ]
           ),
         do: :ok,
         else: (_ -> @error)
  end

  defp seal_small(_, _, 0), do: @error

  defp seal_small(id, auth, remaining) do
    with {:ok, status} <- GraphManifests.advance_validation(id, auth) do
      if status["phase"] == "sealed" or status["state"] == "sealed",
        do: {:ok, status},
        else: seal_small(id, auth, remaining - 1)
    end
  end

  defp guarded(auth, job, result, ref, fun, opts \\ []) do
    HarnessForge.Privacy.Purge.synchronize(fn ->
      Store.transaction(fn ->
        with :ok <- current(auth, job, result, ref),
             {:ok, value} <- fun.() do
          if opts[:terminal],
            do: {:ok, value},
            else: with(:ok <- current(auth, job, result, ref), do: {:ok, value})
        else
          error -> failure(error)
        end
      end)
    end)
  end

  defp current(auth, job, result, ref) do
    with :ok <- validate_request(auth, job, result),
         :ok <- validate_reference(ref, job, result),
         :ok <- Runtime.completion_current(auth, job, result, ref),
         {:ok, _} <- StageControl.graph_current(auth),
         {:ok, _} <-
           GraphManifests.validate_scope_certificate(auth.manifest_id, auth.manifest_digest, auth),
         :ok <- IngestIntent.validate(auth, job),
         {:ok, partition} <-
           one(
             "SELECT state,inventory_revision,inventory_manifest_id,inventory_manifest_digest FROM graph_partition_controls WHERE workspace_id=? AND id=?",
             [Store.workspace(), auth.partition_id]
           ),
         true <- partition == Map.put(ref["base_inventory"], "state", "staging"),
         {:ok, _} <- GraphManifests.inventory_parent(ref["base_inventory"], auth),
         {:ok, _} <- binding(auth, job, ref["base_inventory"]),
         :ok <- settled(auth, ref),
         do: :ok,
         else: (_ -> @error)
  end

  defp binding(auth, job, base) do
    with {:ok, %{rows: [[total, ready]]}} <-
           Repo.query(
             "SELECT count(*),coalesce(sum(CASE WHEN state='ready' AND publication_generation BETWEEN 1 AND ? THEN 1 ELSE 0 END),0) FROM graph_episode_bindings WHERE workspace_id=? AND partition_id=?",
             [base["inventory_revision"], Store.workspace(), auth.partition_id]
           ),
         true <- total == base["inventory_revision"] + 1 and ready == base["inventory_revision"],
         {:ok, binding} <-
           one(
             "SELECT id,payload_hash,manifest_id FROM graph_episode_bindings WHERE workspace_id=? AND partition_id=? AND id=? AND episode_uuid=? AND revision_id=? AND payload_hash=? AND state IN('staging','indexing') AND publication_generation IS NULL",
             [
               Store.workspace(),
               auth.partition_id,
               job["args"]["binding_id"],
               job["args"]["episode_uuid"],
               job["args"]["revision_id"],
               Contracts.digest(job["args"])
             ]
           ),
         do: {:ok, binding},
         else: (_ -> @error)
  end

  defp settled(auth, ref) do
    with {:ok, %{rows: [[total, 0]]}} <-
           Repo.query(
             "SELECT count(*),coalesce(sum(CASE WHEN a.state='completed' AND r.state='completed' AND r.usage_status='reported' AND r.run_id=a.operation_id AND r.request_id=a.id AND a.result_hash IS NOT NULL AND a.response_status IS NOT NULL AND a.response_bytes IS NOT NULL THEN 0 ELSE 1 END),0) FROM stage_attempts a LEFT JOIN model_requests r ON r.workspace_id=a.workspace_id AND r.id=a.model_request_id WHERE a.workspace_id=? AND a.operation_id=?",
             [Store.workspace(), auth.operation_id]
           ),
         true <- total == length(ref["receipt_ids"]) and total > 0,
         {:ok, %{rows: [[0]]}} <-
           Repo.query(
             "SELECT count(*) FROM graph_observation_calls WHERE workspace_id=? AND operation_id=? AND state!='finished'",
             [Store.workspace(), auth.operation_id]
           ),
         {:ok, %{rows: [[0]]}} <-
           Repo.query(
             "SELECT count(*) FROM graph_observation_events WHERE workspace_id=? AND operation_id=? AND binding_state='unused'",
             [Store.workspace(), auth.operation_id]
           ),
         {:ok, %{rows: [[physical]]}} <-
           Repo.query(
             "SELECT count(*) FROM graph_observation_events e JOIN graph_manifest_builds b ON b.workspace_id=e.workspace_id AND b.manifest_id=e.manifest_id JOIN dependency_manifests m ON m.workspace_id=b.workspace_id AND m.id=b.manifest_id WHERE e.workspace_id=? AND e.operation_id=? AND e.phase='derived' AND b.phase='sealed' AND m.state='sealed' AND json_extract(b.header_json,'$.context.seam_id')='llm.response.v1' AND json_extract(b.header_json,'$.context.receipt_ref') IS NOT NULL",
             [Store.workspace(), auth.operation_id]
           ),
         true <- physical == total,
         {:ok, %{rows: [[0]]}} <-
           Repo.query(
             "SELECT count(*) FROM graph_manifest_builds WHERE workspace_id=? AND builder_operation_id=? AND phase!='sealed' AND coalesce(json_extract(header_json,'$.context.seam_id'),'')!='root.inventory_completion.v1'",
             [Store.workspace(), auth.operation_id]
           ),
         :ok <- physical_receipts(auth, ref["receipt_ids"]),
         do: :ok,
         else: (_ -> @error)
  end

  defp physical_receipts(auth, ids) do
    Enum.reduce_while(ids, :ok, fn id, :ok ->
      case Repo.query(
             """
             SELECT 1 FROM stage_attempts a JOIN graph_observation_events consumed
               ON consumed.workspace_id=a.workspace_id AND consumed.consumed_attempt_id=a.id
             WHERE a.workspace_id=? AND a.operation_id=? AND a.id=? AND a.state='completed'
               AND consumed.operation_id=a.operation_id AND consumed.logical_call_id=a.logical_call_id
               AND consumed.binding_state='consumed' AND consumed.manifest_id=a.manifest_id
               AND json_extract(consumed.ack_json,'$.allowed_body_sha256')=a.payload_hash
               AND EXISTS(SELECT 1 FROM graph_observation_events e
                 JOIN graph_manifest_builds b ON b.workspace_id=e.workspace_id AND b.manifest_id=e.manifest_id
                 JOIN dependency_manifests m ON m.workspace_id=b.workspace_id AND m.id=b.manifest_id
                 WHERE e.workspace_id=a.workspace_id AND e.operation_id=a.operation_id
                   AND e.logical_call_id=a.logical_call_id AND e.phase='derived' AND b.phase='sealed' AND m.state='sealed'
                   AND json_extract(b.header_json,'$.context.seam_id')='llm.response.v1'
                   AND json_extract(b.header_json,'$.context.receipt_ref')=a.id
                   AND json_extract(b.header_json,'$.context.receipt_digest')=a.result_hash) LIMIT 1
             """,
             [Store.workspace(), auth.operation_id, id]
           ) do
        {:ok, %{rows: [[1]]}} -> {:cont, :ok}
        _ -> {:halt, @error}
      end
    end)
  end

  defp append(auth, state, entries, final) do
    with {:ok, entries} <- unique_dependencies(entries),
         {:ok, entries} <- new_rows(state.id, entries) do
      if entries == [] and not final do
        {:ok, state}
      else
        with {:ok, ack} <-
               GraphManifests.append_page(
                 state.id,
                 %{
                   "page_index" => state.page,
                   "first_ordinal" => state.ordinal,
                   "previous_page_digest" => state.previous,
                   "final" => final,
                   "rows" => entries
                 },
                 auth
               ),
             do:
               {:ok,
                %{
                  state
                  | page: state.page + 1,
                    ordinal: state.ordinal + length(entries),
                    previous: ack["page_digest"]
                }}
      end
    else
      _ -> @error
    end
  end

  @doc false
  def unique_dependencies(entries) when is_list(entries) and length(entries) <= 100 do
    Enum.reduce_while(entries, {:ok, %{}, []}, fn entry, {:ok, seen, ordered} ->
      if keys?(entry, @row) and is_binary(entry["dependency_key"]) do
        case Map.fetch(seen, entry["dependency_key"]) do
          :error ->
            {:cont, {:ok, Map.put(seen, entry["dependency_key"], entry), [entry | ordered]}}

          {:ok, ^entry} ->
            {:cont, {:ok, seen, ordered}}

          _ ->
            {:halt, @error}
        end
      else
        {:halt, @error}
      end
    end)
    |> case do
      {:ok, _, ordered} -> {:ok, Enum.reverse(ordered)}
      _ -> @error
    end
  end

  def unique_dependencies(_), do: @error

  defp new_rows(id, entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case rows(
             "SELECT kind,content_hash,source_id,revision_id,episode_binding_id,derivative_version_id,projection_id,projection_hash,parent_manifest_id,role,dependency_key FROM origin_dependencies WHERE workspace_id=? AND manifest_id=? AND dependency_key=?",
             [Store.workspace(), id, entry["dependency_key"]]
           ) do
        {:ok, []} -> {:cont, {:ok, acc ++ [entry]}}
        {:ok, [^entry]} -> {:cont, {:ok, acc}}
        _ -> {:halt, @error}
      end
    end)
  end

  defp context(auth, id, base, digest) do
    Map.new(@context, &{&1, nil})
    |> Map.merge(%{
      "graph_kind" => "derived",
      "operation_manifest_ref" => auth.manifest_id,
      "operation_manifest_digest" => auth.manifest_digest,
      "base_context_ref" => base,
      "base_context_digest" => digest,
      "context_id" => id,
      "logical_call_id" => auth.operation_id,
      "seam_id" => "root.inventory_completion.v1",
      "transform_id" => "root_inventory_compare_v2"
    })
  end

  defp parent_row(id, digest),
    do:
      row(%{
        "kind" => "manifest",
        "dependency_key" => "manifest:" <> id,
        "parent_manifest_id" => id,
        "content_hash" => digest
      })

  defp binding_row(b),
    do:
      row(%{
        "kind" => "episode",
        "dependency_key" => "episode:" <> b["id"],
        "episode_binding_id" => b["id"],
        "content_hash" => b["payload_hash"]
      })

  defp version_row(v),
    do:
      row(%{
        "kind" => v["object_kind"],
        "dependency_key" => v["object_kind"] <> ":" <> v["id"] <> ":identity_v1",
        "derivative_version_id" => v["id"],
        "content_hash" => v["value_hash"],
        "projection_id" => "identity_v1",
        "projection_hash" => v["value_hash"]
      })

  defp row(fields),
    do: Map.new(@row, &{&1, nil}) |> Map.merge(Map.put(fields, "role", "transitive"))

  defp chain(state, kind, measured),
    do: %{
      state
      | chain:
          GraphManifests.hash_row(state.chain, state.pages, %{
            "kind" => kind,
            "response_digest" => Contracts.digest(measured["result"]),
            "receipt_digest" => Contracts.digest(measured["receipt"])
          }),
        pages: state.pages + 1
    }

  defp query(action, kind, cursor, limit),
    do: %{
      "action" => action,
      "kind" => kind,
      "cursor" => cursor,
      "limit" => limit,
      "object_ids" => []
    }

  defp canonical_value(%{"value_json" => json, "value_hash" => hash})
       when is_binary(json) and byte_size(json) <= 98_304 do
    with {:ok, value} <- Contracts.decode_json(json),
         true <- Contracts.canonical_json(value) == json and Contracts.sha256(json) == hash,
         do: {:ok, value},
         else: (_ -> @error)
  end

  defp canonical_value(_), do: @error

  defp same_time?(a, b) do
    with {:ok, left, _} <- DateTime.from_iso8601(a),
         {:ok, right, _} <- DateTime.from_iso8601(b),
         do: DateTime.compare(left, right) == :eq,
         else: (_ -> false)
  end

  defp rows(sql, params) do
    case Repo.query(sql, params) do
      {:ok, %{columns: columns, rows: values}} ->
        {:ok, Enum.map(values, &Map.new(Enum.zip(columns, &1)))}

      _ ->
        @error
    end
  end

  defp one(sql, params) do
    case rows(sql, params) do
      {:ok, [value]} -> {:ok, value}
      _ -> @error
    end
  end

  defp image_id?("sha256:" <> hash), do: Stages.digest?(hash)
  defp image_id?(_), do: false
  defp keys?(map, fields), do: is_map(map) and Enum.sort(Map.keys(map)) == Enum.sort(fields)

  defp safely(fun) do
    fun.()
  rescue
    _ -> @error
  catch
    _, _ -> @error
  end

  defp failure({:error, code}) when is_atom(code),
    do: if(Atom.to_string(code) in Protocol.error_codes(), do: {:error, code}, else: @error)

  defp failure(_), do: @error
  defp now, do: DateTime.to_iso8601(Store.now())
end
