defmodule HarnessForge.Graphiti.SearchCompletion do
  @moduledoc "Fixed-inventory native search publication; scores attest native bytes, never evidence confidence."
  alias HarnessForge.{Contracts, Repo}
  alias HarnessForge.Evidence.{Corpora, GraphManifests, Passages, Store}
  alias HarnessForge.Graphiti.{Completion, CompletionCommitment, Runtime, SearchIntent}
  alias HarnessForge.Models.{StageAuthority, StageControl, Stages}
  @error {:error, :closure_incomplete}
  @cert ~w(format search_ref search_digest partition_id base_inventory query_digest result_digest)
  @context ~w(graph_kind operation_manifest_ref operation_manifest_digest base_context_ref base_context_digest context_id logical_call_id seam_id stage_id prompt_name config_digest schema_digest raw_body_sha256 rendered_projection_digest transform_id receipt_ref receipt_digest)

  def publish(%StageAuthority{operation_type: "search"} = auth, job, result) do
    with false <- Repo.in_transaction?(),
         :ok <- validate_request(auth, job, result),
         {:ok, ref} <- Runtime.begin_completion(auth, job, result) do
      outcome = safely(fn -> complete(auth, job, result, ref) end)

      case safely(fn -> Runtime.end_completion(auth, ref, outcome) end) do
        :ok -> outcome
        _ -> @error
      end
    else
      _ -> @error
    end
  rescue
    _ -> @error
  catch
    _, _ -> @error
  end

  def publish(_, _, _), do: @error

  @doc false
  def validate_request(auth, job, result) do
    with :ok <- SearchIntent.validate_shape(auth, job),
         {:ok, projection} <- CompletionCommitment.projection(result),
         true <-
           result["job_id"] == auth.operation_id and
             result["generation"] == auth.semantic_generation and
             result["closure_digest"] == auth.manifest_digest,
         true <-
           result["receipt_count"] == 1 and
             valid_projection?(projection["envelope"]["result"], job["args"]["limit"]),
         do: :ok,
         else: (_ -> @error)
  rescue
    _ -> @error
  end

  @doc false
  def valid_projection?(%{"candidates" => candidates} = value, limit)
      when map_size(value) == 1 and is_list(candidates) and is_integer(limit) and limit in 1..10 do
    length(candidates) <= limit and
      Enum.all?(candidates, fn c ->
        is_map(c) and Enum.sort(Map.keys(c)) == ~w(edge_id episode_ids score) and
          Corpora.uuid?(c["edge_id"]) and
          is_list(c["episode_ids"]) and length(c["episode_ids"]) in 1..24 and
          c["episode_ids"] == Enum.uniq(c["episode_ids"]) and
          Enum.all?(c["episode_ids"], &Corpora.uuid?/1) and finite_bits?(c["score"])
      end) and length(Enum.uniq_by(candidates, & &1["edge_id"])) == length(candidates)
  end

  def valid_projection?(_, _), do: false

  defp finite_bits?(%{"format" => "ieee754-be-f64-v1", "bits" => bits} = score)
       when map_size(score) == 2 and is_binary(bits) do
    with true <- Regex.match?(~r/\A[0-9a-f]{16}\z/, bits),
         {:ok, <<_::1, exponent::11, _::52>>} <- Base.decode16(bits, case: :lower),
         do: exponent != 2047,
         else: (_ -> false)
  end

  defp finite_bits?(_), do: false

  @doc false
  def validate_outer_parents(auth, page) do
    ids = Enum.map(page["parent_contexts"], & &1["manifest_ref"])
    # Every independently ACKed read, including discarded ranking candidates,
    # and the one finished logical embedding response must be direct parents.
    with true <- length(ids) in 1..100,
         {:ok, %{rows: [[1]]}} <-
           Repo.query(
             "SELECT count(*) FROM graph_observation_calls WHERE workspace_id=? AND operation_id=? AND state='finished' AND json_extract(state_json,'$.family')='embed'",
             [Store.workspace(), auth.operation_id]
           ),
         {:ok, %{rows: [[0]]}} <-
           Repo.query(
             "SELECT count(*) FROM graph_observation_events e JOIN graph_manifest_builds b ON b.workspace_id=e.workspace_id AND b.manifest_id=e.manifest_id WHERE e.workspace_id=? AND e.operation_id=? AND (json_extract(b.header_json,'$.context.seam_id')='graphiti.bootstrap.v1' OR (json_extract(b.header_json,'$.context.seam_id')='llm.response.v1' AND json_extract(b.header_json,'$.context.receipt_ref') IS NULL)) AND e.manifest_id NOT IN(" <>
               placeholders(ids) <> ")",
             [Store.workspace(), auth.operation_id] ++ ids
           ),
         do: :ok,
         else: (_ -> @error)
  end

  defp complete(auth, job, result, ref) do
    with :ok <- Completion.validate_reference(ref, job, result),
         {:ok, proof} <- guarded(auth, job, result, ref, fn -> outer_proof(auth, job, result) end),
         {:ok, state} <- guarded(auth, job, result, ref, fn -> start(auth, ref, proof) end),
         {:ok, state} <-
           Enum.reduce_while(result["result"]["candidates"], {:ok, state}, fn candidate,
                                                                              {:ok, acc} ->
             case candidate(auth, job, result, ref, candidate, acc) do
               {:ok, next} -> {:cont, {:ok, next}}
               _ -> {:halt, @error}
             end
           end),
         {:ok, inventory} <- finish(auth, job, result, ref, state),
         {:ok, _} <- finalize(auth, job, result, ref, proof, inventory),
         do: {:ok, result},
         else: (_ -> @error)
  end

  defp current(auth, job, result, ref) do
    with :ok <- validate_request(auth, job, result),
         :ok <- Completion.validate_reference(ref, job, result),
         :ok <- Runtime.completion_current(auth, job, result, ref),
         {:ok, _} <- StageControl.graph_current(auth),
         :ok <- SearchIntent.validate_bound(auth, job, ref["base_inventory"]),
         :ok <- settled(auth, ref),
         do: :ok,
         else: (_ -> @error)
  end

  defp settled(auth, ref) do
    with {:ok, %{rows: [[count, 1, 0]]}} <-
           Repo.query(
             "SELECT count(*),count(DISTINCT a.logical_call_id),coalesce(sum(CASE WHEN a.state='completed' AND r.state='completed' AND r.usage_status='reported' AND r.run_id=a.operation_id AND r.request_id=a.id AND a.result_hash IS NOT NULL AND a.response_status IS NOT NULL AND a.response_bytes IS NOT NULL AND a.stage_config_id=? THEN 0 ELSE 1 END),0) FROM stage_attempts a LEFT JOIN model_requests r ON r.workspace_id=a.workspace_id AND r.id=a.model_request_id WHERE a.workspace_id=? AND a.operation_id=?",
             [embedder(auth)["id"], Store.workspace(), auth.operation_id]
           ),
         true <- count == length(ref["receipt_ids"]) and count == 1,
         {:ok, %{rows: [[0]]}} <-
           Repo.query(
             "SELECT count(*) FROM graph_observation_calls WHERE workspace_id=? AND operation_id=? AND (state!='finished' OR json_extract(state_json,'$.family') NOT IN('search','embed','bootstrap'))",
             [Store.workspace(), auth.operation_id]
           ),
         {:ok, %{rows: [[1, 1]]}} <-
           Repo.query(
             "SELECT sum(CASE WHEN json_extract(state_json,'$.family')='search' THEN 1 ELSE 0 END),sum(CASE WHEN json_extract(state_json,'$.family')='embed' THEN 1 ELSE 0 END) FROM graph_observation_calls WHERE workspace_id=? AND operation_id=?",
             [Store.workspace(), auth.operation_id]
           ),
         {:ok, %{rows: [[0]]}} <-
           Repo.query(
             "SELECT count(*) FROM graph_observation_events WHERE workspace_id=? AND operation_id=? AND binding_state='unused'",
             [Store.workspace(), auth.operation_id]
           ),
         {:ok, %{rows: [[^count]]}} <-
           Repo.query(
             "SELECT count(*) FROM graph_observation_events e JOIN graph_manifest_builds b ON b.workspace_id=e.workspace_id AND b.manifest_id=e.manifest_id WHERE e.workspace_id=? AND e.operation_id=? AND e.phase='derived' AND b.phase='sealed' AND json_extract(b.header_json,'$.context.seam_id')='llm.response.v1' AND json_extract(b.header_json,'$.context.receipt_ref') IS NOT NULL",
             [Store.workspace(), auth.operation_id]
           ),
         :ok <- physical_receipts(auth, ref["receipt_ids"]),
         do: :ok,
         else: (_ -> @error)
  end

  defp physical_receipts(auth, ids) do
    Enum.reduce_while(ids, :ok, fn id, :ok ->
      case Repo.query(
             "SELECT 1 FROM stage_attempts a JOIN graph_observation_events e ON e.workspace_id=a.workspace_id AND e.consumed_attempt_id=a.id WHERE a.workspace_id=? AND a.operation_id=? AND a.id=? AND a.state='completed' AND e.operation_id=a.operation_id AND e.logical_call_id=a.logical_call_id AND e.binding_state='consumed' AND e.manifest_id=a.manifest_id AND json_extract(e.ack_json,'$.allowed_body_sha256')=a.payload_hash AND EXISTS(SELECT 1 FROM graph_manifest_builds b JOIN graph_observation_events p ON p.workspace_id=b.workspace_id AND p.manifest_id=b.manifest_id WHERE b.workspace_id=a.workspace_id AND p.operation_id=a.operation_id AND p.logical_call_id=a.logical_call_id AND b.phase='sealed' AND json_extract(b.header_json,'$.context.receipt_ref')=a.id AND json_extract(b.header_json,'$.context.receipt_digest')=a.result_hash) LIMIT 1",
             [Store.workspace(), auth.operation_id, id]
           ) do
        {:ok, %{rows: [[1]]}} -> {:cont, :ok}
        _ -> {:halt, @error}
      end
    end)
  end

  defp outer_proof(auth, job, result) do
    with {:ok, projected} <- CompletionCommitment.projection(result),
         {:ok, proof} <-
           SearchIntent.one(
             "SELECT e.manifest_id,m.digest,b.header_json,v.value_hash,v.value_json,e.logical_call_id FROM graph_observation_events e JOIN graph_manifest_builds b ON b.workspace_id=e.workspace_id AND b.manifest_id=e.manifest_id JOIN dependency_manifests m ON m.workspace_id=b.workspace_id AND m.id=b.manifest_id JOIN origin_dependencies d ON d.workspace_id=m.workspace_id AND d.manifest_id=m.id AND d.kind='deterministic_output' JOIN graph_derivative_versions v ON v.workspace_id=d.workspace_id AND v.id=d.derivative_version_id WHERE e.workspace_id=? AND e.operation_id=? AND e.phase='derived' AND b.phase='sealed' AND m.state='sealed' AND json_extract(b.header_json,'$.context.seam_id')='graphiti.search.v1' AND json_extract(b.header_json,'$.context.transform_id')='native_search_rrf_v1' AND d.content_hash=v.value_hash AND d.projection_id='identity_v1' AND d.projection_hash=v.value_hash AND v.partition_id=? AND v.state='staging' AND NOT EXISTS(SELECT 1 FROM graph_derivative_versions n WHERE n.workspace_id=v.workspace_id AND n.partition_id=v.partition_id AND n.object_kind=v.object_kind AND n.object_id=v.object_id AND n.version>v.version)",
             [Store.workspace(), auth.operation_id, auth.partition_id]
           ),
         {:ok, value} <- SearchIntent.canonical_value(proof),
         true <- value == projected["envelope"]["result"],
         {:ok, _} <- GraphManifests.validate_current(proof["manifest_id"], proof["digest"], auth),
         {:ok, header} <- Contracts.decode_json(proof["header_json"]),
         parent = header["context"]["base_context_ref"],
         {:ok, %{rows: [[0]]}} <-
           Repo.query(
             "SELECT count(*) FROM graph_observation_events e JOIN graph_manifest_builds b ON b.workspace_id=e.workspace_id AND b.manifest_id=e.manifest_id WHERE e.workspace_id=? AND e.operation_id=? AND (json_extract(b.header_json,'$.context.seam_id')='graphiti.bootstrap.v1' OR (json_extract(b.header_json,'$.context.seam_id')='llm.response.v1' AND json_extract(b.header_json,'$.context.receipt_ref') IS NULL)) AND NOT EXISTS(SELECT 1 FROM origin_dependencies d WHERE d.workspace_id=e.workspace_id AND d.manifest_id=? AND d.kind='manifest' AND d.parent_manifest_id=e.manifest_id)",
             [Store.workspace(), auth.operation_id, parent]
           ),
         {:ok, intent} <- SearchIntent.handle(auth, job),
         do:
           {:ok,
            %{
              outer: %{
                "manifest_ref" => proof["manifest_id"],
                "manifest_digest" => proof["digest"]
              },
              intent: intent
            }},
         else: (_ -> @error)
  end

  defp start(auth, ref, proof) do
    base = ref["base_inventory"]

    with {:ok, prior} <- GraphManifests.inventory_parent(base, auth),
         {:ok, build} <-
           GraphManifests.begin_manifest(
             auth,
             "derivative",
             context(auth, auth.manifest_id, auth.manifest_digest)
           ),
         {:ok, state} <-
           append(
             auth,
             %{id: build["manifest_id"], page: 0, ordinal: 0, previous: nil},
             [
               SearchIntent.parent(auth.manifest_id, auth.manifest_digest),
               SearchIntent.parent(
                 base["inventory_manifest_id"],
                 base["inventory_manifest_digest"]
               ),
               SearchIntent.parent(prior["manifest_ref"], prior["manifest_digest"]),
               SearchIntent.parent(proof.outer["manifest_ref"], proof.outer["manifest_digest"]),
               SearchIntent.parent(proof.intent["manifest_ref"], proof.intent["manifest_digest"])
             ],
             false
           ),
         do: {:ok, state}
  end

  defp candidate(auth, job, result, ref, candidate, state) do
    with {:ok, state, [edge]} <-
           measure(auth, job, result, ref, "edge", [candidate["edge_id"]], state),
         true <- edge["fields"]["episodes"] == candidate["episode_ids"],
         endpoints =
           Enum.uniq([edge["fields"]["source_node_uuid"], edge["fields"]["target_node_uuid"]]),
         {:ok, state, _} <- measure(auth, job, result, ref, "entity", endpoints, state),
         {:ok, state} <-
           Enum.reduce_while(Enum.chunk_every(candidate["episode_ids"], 10), {:ok, state}, fn ids,
                                                                                              {:ok,
                                                                                               acc} ->
             case measure(auth, job, result, ref, "episode", ids, acc) do
               {:ok, next, _} -> {:cont, {:ok, next}}
               _ -> {:halt, @error}
             end
           end),
         do: {:ok, state},
         else: (_ -> @error)
  end

  defp measure(auth, job, result, ref, kind, ids, state) do
    with true <- length(ids) in 1..10 and Enum.all?(ids, &Corpora.uuid?/1),
         :ok <- current(auth, job, result, ref),
         false <- Repo.in_transaction?(),
         {:ok, measured} <-
           Runtime.completion_inventory(auth, ref, %{
             "action" => "objects",
             "kind" => kind,
             "cursor" => nil,
             "limit" => length(ids),
             "object_ids" => ids
           }),
         records when is_list(records) <- get_in(measured, ["result", "records"]),
         true <-
           length(records) == length(ids) and
             Enum.sort(Enum.map(records, &get_in(&1, ["fields", "uuid"]))) == Enum.sort(ids),
         {:ok, next} <-
           guarded(auth, job, result, ref, fn ->
             with {:ok, rows} <-
                    Enum.reduce_while(records, {:ok, []}, fn record, {:ok, acc} ->
                      case record_rows(auth, ref["base_inventory"], record) do
                        {:ok, rows} -> {:cont, {:ok, acc ++ rows}}
                        _ -> {:halt, @error}
                      end
                    end),
                  do: append(auth, state, rows, false)
           end),
         do: {:ok, next, records},
         else: (_ -> @error)
  end

  defp record_rows(auth, base, record) do
    with {:ok, {kind, object}} <- Completion.native_identity(record),
         {:ok, version} <- GraphManifests.inventory_version(base, kind, object, auth),
         {:ok, value} <- SearchIntent.canonical_value(version),
         true <- value == record and record["fields"]["group_id"] == auth.scope_ref,
         :ok <- read_proof(auth, record, version),
         {:ok, extra} <- scalar_rows(auth, base, record),
         {:ok, bindings} <- binding_rows(auth, base, record),
         do:
           {:ok,
            [
              SearchIntent.parent(
                version["parent"]["manifest_ref"],
                version["parent"]["manifest_digest"]
              ),
              SearchIntent.version_row(version["id"], kind, version["value_hash"])
            ] ++ extra ++ bindings},
         else: (_ -> @error)
  end

  defp read_proof(auth, %{"object_type" => "EntityEdge"}, version) do
    case Repo.query(
           "SELECT 1 FROM origin_dependencies d JOIN graph_observation_events e ON e.workspace_id=d.workspace_id AND e.manifest_id=d.manifest_id JOIN graph_manifest_builds b ON b.workspace_id=e.workspace_id AND b.manifest_id=e.manifest_id WHERE d.workspace_id=? AND e.operation_id=? AND d.derivative_version_id=? AND d.kind='edge' AND d.content_hash=? AND d.projection_id='native_loader_no_vector_v1' AND b.phase='sealed' AND json_extract(b.header_json,'$.context.seam_id')='graphiti.bootstrap.v1' LIMIT 1",
           [Store.workspace(), auth.operation_id, version["id"], version["value_hash"]]
         ) do
      {:ok, %{rows: [[1]]}} -> :ok
      _ -> @error
    end
  end

  defp read_proof(_, _, _), do: :ok

  defp scalar_rows(auth, base, %{"object_type" => "EntityNode", "fields" => f}) do
    Enum.reduce_while(~w(summary attribute), {:ok, []}, fn kind, {:ok, acc} ->
      with {:ok, v} <-
             GraphManifests.inventory_version(base, kind, "EntityNode:" <> f["uuid"], auth),
           {:ok, value} <- SearchIntent.canonical_value(v),
           true <- value == f[if(kind == "summary", do: "summary", else: "attributes")],
           do: {:cont, {:ok, acc ++ [SearchIntent.version_row(v["id"], kind, v["value_hash"])]}},
           else: (_ -> {:halt, @error})
    end)
  end

  defp scalar_rows(_, _, _), do: {:ok, []}

  defp binding_rows(auth, base, %{"object_type" => "EpisodicNode", "fields" => f}) do
    with {:ok, b} <-
           SearchIntent.one(
             "SELECT id,revision_id,passage_id,payload_hash,publication_generation FROM graph_episode_bindings WHERE workspace_id=? AND partition_id=? AND episode_uuid=? AND state='ready'",
             [Store.workspace(), auth.partition_id, f["uuid"]]
           ),
         true <- b["publication_generation"] in 1..base["inventory_revision"],
         {:ok, window} <- Passages.envelope(b["passage_id"]),
         true <-
           window["revision_id"] == b["revision_id"] and f["name"] == b["id"] and
             f["content"] == window["snippet"] and f["source_description"] == b["revision_id"] and
             f["source"] == "text",
         true <-
           same_time?(
             f["valid_at"],
             window["effective_at"] || window["event_at"] || window["captured_at"]
           ),
         {:ok, true} <-
           GraphManifests.contains_source?(
             auth.manifest_id,
             auth.manifest_digest,
             window["source_id"],
             auth
           ),
         {:ok, p} <- GraphManifests.inventory_parent(base, auth),
         {:ok, %{rows: [[1]]}} <-
           Repo.query(
             "SELECT 1 FROM origin_dependencies WHERE workspace_id=? AND manifest_id=? AND episode_binding_id=? AND kind='episode' AND content_hash=? LIMIT 1",
             [Store.workspace(), p["manifest_ref"], b["id"], b["payload_hash"]]
           ),
         do:
           {:ok,
            [
              SearchIntent.row(%{
                "kind" => "episode",
                "dependency_key" => "episode:" <> b["id"],
                "episode_binding_id" => b["id"],
                "content_hash" => b["payload_hash"]
              })
            ]},
         else: (_ -> @error)
  end

  defp binding_rows(_, _, _), do: {:ok, []}

  defp append(auth, state, rows, final) do
    with {:ok, rows} <- Completion.unique_dependencies(rows),
         {:ok, rows} <-
           Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
             case Repo.query(
                    "SELECT kind,content_hash,source_id,revision_id,episode_binding_id,derivative_version_id,projection_id,projection_hash,parent_manifest_id,role,dependency_key FROM origin_dependencies WHERE workspace_id=? AND manifest_id=? AND dependency_key=?",
                    [Store.workspace(), state.id, row["dependency_key"]]
                  ) do
               {:ok, %{rows: []}} ->
                 {:cont, {:ok, acc ++ [row]}}

               {:ok, %{columns: cols, rows: [values]}} ->
                 if Map.new(Enum.zip(cols, values)) == row,
                   do: {:cont, {:ok, acc}},
                   else: {:halt, @error}

               _ ->
                 {:halt, @error}
             end
           end) do
      if rows == [] and not final do
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
                   "rows" => rows
                 },
                 auth
               ),
             do:
               {:ok,
                %{
                  state
                  | page: state.page + 1,
                    ordinal: state.ordinal + length(rows),
                    previous: ack["page_digest"]
                }}
      end
    end
  end

  defp finish(auth, job, result, ref, state) do
    with {:ok, closed} <- guarded(auth, job, result, ref, fn -> append(auth, state, [], true) end),
         {:ok, _} <-
           guarded(auth, job, result, ref, fn ->
             GraphManifests.finish_manifest(
               state.id,
               %{"dependency_count" => closed.ordinal, "source_count" => 0},
               auth
             )
           end),
         do: advance(auth, job, result, ref, state.id)
  end

  defp advance(auth, job, result, ref, id) do
    with {:ok, status} <-
           guarded(auth, job, result, ref, fn -> GraphManifests.advance_validation(id, auth) end) do
      if status["phase"] == "sealed", do: {:ok, status}, else: advance(auth, job, result, ref, id)
    end
  end

  defp finalize(auth, job, result, ref, proof, inventory) do
    guarded(
      auth,
      job,
      result,
      ref,
      fn ->
        with {:ok, intent, _} <- SearchIntent.stored(auth, job),
             {:ok, projected} <- CompletionCommitment.projection(result),
             value = %{
               "format" => "graph-search-completion-v1",
               "job_digest" => ref["job_digest"],
               "completion_digest" => ref["completion_digest"],
               "query_digest" => Contracts.digest(SearchIntent.input(job)),
               "base_inventory" => ref["base_inventory"],
               "input" => SearchIntent.input(job),
               "result_projection" => projected["envelope"]["result"],
               "retrieval_scope_digest" => intent["retrieval_scope_digest"],
               "receipt_ids" => ref["receipt_ids"],
               "source_manifest_ref" => auth.manifest_id,
               "source_manifest_digest" => auth.manifest_digest,
               "partition_id" => auth.partition_id,
               "stage_set_digest" => StageAuthority.stage_set_digest(auth),
               "writer_id" => ref["writer_id"],
               "worker_image_id" => ref["worker_image_id"],
               "outer_context" => proof.outer
             },
             id = Ecto.UUID.generate(),
             :ok <-
               SearchIntent.insert_version(
                 auth,
                 id,
                 "root_search:" <> auth.operation_id,
                 value,
                 inventory,
                 "published"
               ),
             {:ok, c} <-
               SearchIntent.seal(
                 auth,
                 context(auth, inventory["manifest_id"], inventory["digest"]),
                 [
                   SearchIntent.parent(inventory["manifest_id"], inventory["digest"]),
                   SearchIntent.version_row(id, "deterministic_output", Contracts.digest(value))
                 ]
               ),
             :ok <- current(auth, job, result, ref),
             {:ok, %{num_rows: 1}} <-
               Repo.query(
                 "UPDATE stage_operations SET state='completed',result_digest=?,updated_at=? WHERE workspace_id=? AND id=? AND state='active' AND operation_type='search' AND control_token=? AND cancel_epoch=? AND partition_id=? AND worker_session_id=? AND lease_id=? AND EXISTS(SELECT 1 FROM graph_partition_controls p WHERE p.workspace_id=stage_operations.workspace_id AND p.id=stage_operations.partition_id AND p.state='ready' AND p.inventory_revision=? AND p.inventory_manifest_id=? AND p.inventory_manifest_digest=? AND p.lock_version=? AND p.cancel_epoch=? AND p.manifest_id=?)",
                 [
                   ref["completion_digest"],
                   DateTime.to_iso8601(Store.now()),
                   Store.workspace(),
                   auth.operation_id,
                   auth.control_token,
                   auth.cancel_epoch,
                   auth.partition_id,
                   auth.worker_session_id,
                   auth.lease_id,
                   ref["inventory_revision"],
                   ref["base_inventory"]["inventory_manifest_id"],
                   ref["base_inventory"]["inventory_manifest_digest"],
                   auth.partition_lock_version,
                   auth.cancel_epoch,
                   auth.manifest_id
                 ]
               ),
             do: {:ok, c},
             else: (_ -> @error)
      end,
      true
    )
  end

  def certificate(job, result, scope, caller) do
    with {:ok, digest} <- CompletionCommitment.digest(result),
         {:ok, cert} <-
           Corpora.guard(caller, fn ->
             with {:ok, data} <- receipt_for_operation(job["job_id"]),
                  true <-
                    data.value["job_digest"] == Contracts.digest(job) and
                      data.value["completion_digest"] == digest and
                      data.value["input"] == SearchIntent.input(job),
                  cert = %{
                    "format" => "graph-search-certificate-v1",
                    "search_ref" => data.manifest["id"],
                    "search_digest" => data.manifest["digest"],
                    "partition_id" => data.value["partition_id"],
                    "base_inventory" => data.value["base_inventory"],
                    "query_digest" => data.value["query_digest"],
                    "result_digest" => digest
                  },
                  :ok <- validate_stored_certificate(cert, scope),
                  do: {:ok, cert},
                  else: (_ -> @error)
           end),
         do: {:ok, cert},
         else: (_ -> @error)
  rescue
    _ -> @error
  end

  def validate_certificate(cert, scope, caller) do
    case Corpora.guard(caller, fn ->
           with :ok <- validate_stored_certificate(cert, scope), do: {:ok, true}
         end) do
      {:ok, true} -> :ok
      _ -> @error
    end
  rescue
    _ -> @error
  end

  @doc "Metadata-only reuse proof inside the caller's currentness guard; grants no execution or consent."
  def validate_stored_certificate(cert, scope) do
    with true <- valid_certificate?(cert),
         {:ok, manifest} <-
           SearchIntent.one(
             "SELECT m.id,m.digest,b.builder_operation_id,b.partition_id,b.source_manifest_id,b.source_manifest_digest,b.header_json FROM dependency_manifests m JOIN graph_manifest_builds b ON b.workspace_id=m.workspace_id AND b.manifest_id=m.id WHERE m.workspace_id=? AND m.id=? AND m.digest=? AND m.state='sealed' AND b.phase='sealed' AND b.candidate_digest=m.digest AND b.validated_count=b.dependency_count AND b.validated_page_index=b.next_page_index AND b.validation_row_chain_hash=b.row_chain_hash AND b.dependency_count=2",
             [Store.workspace(), cert["search_ref"], cert["search_digest"]]
           ),
         {:ok, data} <- receipt_for_operation(manifest["builder_operation_id"]),
         true <-
           data.manifest["id"] == cert["search_ref"] and
             data.manifest["digest"] == cert["search_digest"],
         value = data.value,
         true <-
           value["format"] == "graph-search-completion-v1" and
             value["base_inventory"] == cert["base_inventory"] and
             value["partition_id"] == cert["partition_id"] and
             value["query_digest"] == cert["query_digest"] and
             value["completion_digest"] == cert["result_digest"] and
             value["query_digest"] == Contracts.digest(value["input"]) and
             valid_input_and_projection?(value),
         true <-
           value["retrieval_scope_digest"] == Contracts.digest(SearchIntent.scope_pins(scope)),
         {:ok, config} <- GraphManifests.inventory_configuration_current(cert["partition_id"]),
         true <-
           config["base_inventory"] == cert["base_inventory"] and
             config["stage_set_digest"] == value["stage_set_digest"],
         {:ok, %{rows: [[0]]}} <-
           Repo.query(
             "SELECT count(*) FROM origin_dependencies d JOIN graph_derivative_versions v ON v.workspace_id=d.workspace_id AND v.id=d.derivative_version_id WHERE d.workspace_id=? AND d.manifest_id=? AND (v.partition_id!=? OR v.state!='published' OR v.value_json IS NULL OR d.kind!=v.object_kind OR d.content_hash!=v.value_hash OR EXISTS(SELECT 1 FROM graph_derivative_versions n WHERE n.workspace_id=v.workspace_id AND n.partition_id=v.partition_id AND n.object_kind=v.object_kind AND n.object_id=v.object_id AND n.version>v.version))",
             [Store.workspace(), data.inventory, cert["partition_id"]]
           ),
         {:ok, %{rows: [[0]]}} <-
           Repo.query(
             "SELECT count(*) FROM origin_dependencies d LEFT JOIN graph_episode_bindings b ON b.workspace_id=d.workspace_id AND b.id=d.episode_binding_id WHERE d.workspace_id=? AND d.manifest_id=? AND d.kind='episode' AND (b.id IS NULL OR b.partition_id!=? OR b.state!='ready' OR b.payload_hash!=d.content_hash OR b.publication_generation NOT BETWEEN 1 AND ?)",
             [
               Store.workspace(),
               data.inventory,
               cert["partition_id"],
               cert["base_inventory"]["inventory_revision"]
             ]
           ),
         {:ok, creator} <-
           SearchIntent.one(
             "SELECT result_digest,stage_set_digest,worker_session_id,lease_id,manifest_id,manifest_digest,corpus_id,semantic_generation,authorization_generation FROM stage_operations WHERE workspace_id=? AND id=? AND partition_id=? AND operation_type='search' AND state='completed'",
             [Store.workspace(), manifest["builder_operation_id"], cert["partition_id"]]
           ),
         true <-
           creator["result_digest"] == cert["result_digest"] and
             creator["stage_set_digest"] == value["stage_set_digest"] and
             creator["manifest_id"] == value["source_manifest_ref"] and
             creator["manifest_digest"] == value["source_manifest_digest"] and
             creator["corpus_id"] == scope["corpus_id"] and
             creator["semantic_generation"] == scope["semantic_generation"] and
             creator["authorization_generation"] == scope["authorization_generation"],
         true <-
           manifest["partition_id"] == cert["partition_id"] and
             manifest["source_manifest_id"] == creator["manifest_id"] and
             manifest["source_manifest_digest"] == creator["manifest_digest"],
         {:ok, header} <- Contracts.decode_json(manifest["header_json"]),
         true <-
           header["context"]["seam_id"] == "root.search_completion.v1" and
             header["context"]["transform_id"] == "root_search_completion_v1" and
             header["execution_identity"]["operation_id"] == manifest["builder_operation_id"] and
             header["execution_identity"]["session_id"] == creator["worker_session_id"] and
             header["execution_identity"]["lease_id"] == creator["lease_id"] and
             header["execution_identity"]["stage_set_digest"] == creator["stage_set_digest"],
         {:ok, %{rows: [[1]]}} <-
           Repo.query(
             "SELECT 1 FROM graph_partition_controls p JOIN graph_worker_sessions s ON s.workspace_id=p.workspace_id AND s.id=? WHERE p.workspace_id=? AND p.id=? AND p.state='ready' AND p.manifest_id=? AND s.operation_id=? AND s.partition_id=p.id AND s.stage_set_digest=? LIMIT 1",
             [
               creator["worker_session_id"],
               Store.workspace(),
               cert["partition_id"],
               creator["manifest_id"],
               manifest["builder_operation_id"],
               value["stage_set_digest"]
             ]
           ),
         do: :ok,
         else: (_ -> @error)
  rescue
    _ -> @error
  end

  defp receipt_for_operation(operation) do
    with true <- Corpora.uuid?(operation),
         {:ok, v} <-
           SearchIntent.one(
             "SELECT id,value_json,value_hash,manifest_id FROM graph_derivative_versions WHERE workspace_id=? AND object_kind='deterministic_output' AND object_id=? AND state='published' AND version=1 AND predecessor_id IS NULL AND NOT EXISTS(SELECT 1 FROM graph_derivative_versions n WHERE n.workspace_id=graph_derivative_versions.workspace_id AND n.partition_id=graph_derivative_versions.partition_id AND n.object_kind=graph_derivative_versions.object_kind AND n.object_id=graph_derivative_versions.object_id AND n.version>graph_derivative_versions.version)",
             [Store.workspace(), "root_search:" <> operation]
           ),
         {:ok, value} <- SearchIntent.canonical_value(v),
         {:ok, manifest} <-
           SearchIntent.one(
             "SELECT m.id,m.digest FROM origin_dependencies d JOIN dependency_manifests m ON m.workspace_id=d.workspace_id AND m.id=d.manifest_id JOIN graph_manifest_builds b ON b.workspace_id=m.workspace_id AND b.manifest_id=m.id WHERE d.workspace_id=? AND d.derivative_version_id=? AND d.content_hash=? AND d.kind='deterministic_output' AND d.projection_id='identity_v1' AND d.projection_hash=d.content_hash AND m.state='sealed' AND b.phase='sealed' AND b.builder_operation_id=? AND json_extract(b.header_json,'$.context.seam_id')='root.search_completion.v1' AND json_extract(b.header_json,'$.context.base_context_ref')=? AND EXISTS(SELECT 1 FROM origin_dependencies p WHERE p.workspace_id=d.workspace_id AND p.manifest_id=m.id AND p.kind='manifest' AND p.parent_manifest_id=?)",
             [
               Store.workspace(),
               v["id"],
               v["value_hash"],
               operation,
               v["manifest_id"],
               v["manifest_id"]
             ]
           ),
         do: {:ok, %{value: value, manifest: manifest, inventory: v["manifest_id"]}},
         else: (_ -> @error)
  end

  @doc false
  def valid_certificate?(cert) do
    is_map(cert) and Enum.sort(Map.keys(cert)) == Enum.sort(@cert) and
      cert["format"] == "graph-search-certificate-v1" and Corpora.uuid?(cert["search_ref"]) and
      Corpora.uuid?(cert["partition_id"]) and
      Enum.all?(~w(search_digest query_digest result_digest), &Stages.digest?(cert[&1])) and
      Completion.valid_base?(cert["base_inventory"]) and
      cert["base_inventory"]["inventory_revision"] > 0
  end

  defp valid_input_and_projection?(value),
    do:
      SearchIntent.valid_input?(value["input"]) and
        valid_projection?(value["result_projection"], value["input"]["limit"])

  defp guarded(auth, job, result, ref, fun, terminal \\ false) do
    HarnessForge.Privacy.Purge.synchronize(fn ->
      Store.transaction(fn ->
        with :ok <- current(auth, job, result, ref), {:ok, value} <- fun.() do
          if terminal,
            do: {:ok, value},
            else: with(:ok <- current(auth, job, result, ref), do: {:ok, value})
        else
          _ -> @error
        end
      end)
    end)
  end

  defp context(auth, base, digest),
    do:
      Map.new(@context, &{&1, nil})
      |> Map.merge(%{
        "graph_kind" => "derived",
        "operation_manifest_ref" => auth.manifest_id,
        "operation_manifest_digest" => auth.manifest_digest,
        "base_context_ref" => base,
        "base_context_digest" => digest,
        "context_id" => Ecto.UUID.generate(),
        "logical_call_id" => auth.operation_id,
        "seam_id" => "root.search_completion.v1",
        "transform_id" => "root_search_completion_v1"
      })

  defp embedder(auth), do: Enum.find(auth.stage_pins, &(&1["stage"] == "embedder"))
  defp placeholders(ids), do: Enum.map_join(ids, ",", fn _ -> "?" end)

  defp same_time?(a, b) do
    with {:ok, left, _} <- DateTime.from_iso8601(a),
         {:ok, right, _} <- DateTime.from_iso8601(b),
         do: DateTime.compare(left, right) == :eq,
         else: (_ -> false)
  end

  defp safely(fun) do
    fun.()
  rescue
    _ -> @error
  catch
    _, _ -> @error
  end
end
