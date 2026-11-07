defmodule HarnessForge.Evidence.GraphManifests do
  @moduledoc """
  Paged graph source certificates and local immutable context manifests.

  Source certificates certify a flat, exact source set once. Local contexts
  inherit that conservative authority by reference, and check only their new
  inputs and already-certified parents. This module never hydrates revision
  bodies, walks historical ancestry, verifies model semantics or sends I/O.
  Root-owned StageControl supplies durable authorization and invalidation.
  """
  alias HarnessForge.{Contracts, Repo}
  alias HarnessForge.Evidence.{RevisionUseHolds, Store}
  alias HarnessForge.Graphiti.SchemaPolicy
  alias HarnessForge.Models.{Ledger, StageAuthority, StageControl, Stages}

  @format "graph-manifest-v2"
  @page_format "graph-manifest-page-v2"
  @max 9_007_199_254_740_991
  @control ~w(workspace_id corpus_id semantic_generation authorization_generation partition_id group_id operation_id job_id session_id lease_id cancel_epoch stage_set_digest operation_manifest_ref operation_manifest_digest partition_lock_version source_lock_digest backend_pin_digest)
  @source ~w(workspace_id corpus_id semantic_generation authorization_generation partition_id group_id source_lock_digest backend_pin_digest)
  @execution ~w(operation_id job_id session_id lease_id cancel_epoch partition_lock_version stage_set_digest)
  @context ~w(graph_kind operation_manifest_ref operation_manifest_digest base_context_ref base_context_digest context_id logical_call_id seam_id stage_id prompt_name config_digest schema_digest raw_body_sha256 rendered_projection_digest transform_id receipt_ref receipt_digest)
  @row ~w(dependency_key kind source_id revision_id content_hash role episode_binding_id derivative_version_id projection_id projection_hash parent_manifest_id)
  @page ~w(page_index first_ordinal previous_page_digest final rows)
  @kinds ~w(source_revision goal project profile stage episode summary attribute edge rendered_message embed_input deterministic_output manifest)
  @purposes ~w(graph_ingest partition derivative purge_rebuild)
  @fatal ~w(invalid_input source_unavailable closure_incomplete)a
  @type error :: {:error, atom()}
  @type result :: {:ok, map()} | error()

  @spec begin_manifest(struct(), String.t(), map()) :: result()
  def begin_manifest(control_ref, purpose, context) do
    guarded(control_ref, nil, fn control ->
      with true <- purpose in @purposes,
           :ok <- context_shape(context, control, control_ref),
           {:ok, scope} <- context_scope(context, control),
           header = header(control, purpose, context, scope),
           encoded = Contracts.canonical_json(header),
           true <- byte_size(encoded) <= 32_768,
           {:ok, existing} <- existing_build(context, control) do
        case existing do
          nil ->
            create_build(control, purpose, context, scope, header, encoded)

          build ->
            with true <- build["header_json"] == encoded,
                 :ok <- build_current(build, control, false) do
              {:ok, status(build)}
            else
              _ -> {:error, :closure_incomplete}
            end
        end
      else
        false -> {:error, :invalid_input}
        error -> error
      end
    end)
  end

  @spec append_page(String.t(), map(), struct()) :: result()
  def append_page(id, page, control_ref) do
    guarded(control_ref, id, fn control ->
      with true <- uuid?(id),
           :ok <- page_shape(page),
           {:ok, build} <- load(id),
           :ok <- build_current(build, control, false),
           digest = page_digest(build, page),
           {:ok, stored} <-
             optional_one(
               "SELECT page_digest,ack_json FROM graph_manifest_pages WHERE workspace_id=? AND manifest_id=? AND page_index=?",
               [Store.workspace(), id, page["page_index"]]
             ) do
        case stored do
          nil -> append_new(build, page, digest, control)
          %{"page_digest" => ^digest, "ack_json" => ack} -> decode(ack)
          _ -> {:error, :closure_incomplete}
        end
      else
        false -> {:error, :invalid_input}
        error -> error
      end
    end)
  end

  @spec finish_manifest(String.t(), map(), struct()) :: result()
  def finish_manifest(id, totals, control_ref) do
    guarded(control_ref, id, fn control ->
      with true <- uuid?(id) and keys?(totals, ~w(dependency_count source_count)),
           true <- integer?(totals["dependency_count"]) and integer?(totals["source_count"]),
           {:ok, build} <- load(id),
           :ok <- build_current(build, control, false),
           true <-
             build["dependency_count"] == totals["dependency_count"] and
               build["source_count"] == totals["source_count"],
           true <- build["final_received"] == 1 do
        if build["phase"] == "receiving" do
          with :ok <- source_set_complete(build),
               candidate = final_digest(build),
               :ok <-
                 update_build(id, %{
                   "expected_dependency_count" => totals["dependency_count"],
                   "expected_source_count" => totals["source_count"],
                   "candidate_digest" => candidate,
                   "phase" => "validating"
                 }),
               {:ok, updated} <- load(id) do
            {:ok, status(updated)}
          end
        else
          if build["phase"] in ~w(validating sealed),
            do: {:ok, status(build)},
            else: {:error, :closure_incomplete}
        end
      else
        false -> {:error, :closure_incomplete}
        error -> error
      end
    end)
  end

  @spec advance_validation(String.t(), struct()) :: result()
  def advance_validation(id, control_ref) do
    guarded(control_ref, id, fn control ->
      with true <- uuid?(id),
           {:ok, build} <- load(id),
           :ok <- build_current(build, control, false) do
        case build["phase"] do
          "sealed" -> {:ok, status(build)}
          "validating" -> validate_next_page(build, control)
          _ -> {:error, :closure_incomplete}
        end
      else
        false -> {:error, :invalid_input}
        error -> error
      end
    end)
  end

  @spec validate_scope_certificate(String.t(), String.t(), struct()) :: result()
  def validate_scope_certificate(id, digest, control_ref) do
    guarded(control_ref, nil, fn control ->
      with {:ok, build} <- scope_certificate(id, digest, control), do: {:ok, metadata(build)}
    end)
  end

  @spec validate_current(String.t(), String.t(), struct()) :: result()
  def validate_current(id, digest, control_ref) do
    guarded(control_ref, nil, fn control ->
      with {:ok, build} <- sealed(id, digest),
           :ok <- build_current(build, control, true),
           do: {:ok, metadata(build)}
    end)
  end

  @spec read_page(String.t(), String.t(), non_neg_integer(), struct()) :: result()
  def read_page(id, digest, next, control_ref) do
    guarded(control_ref, nil, fn control ->
      with true <- integer?(next),
           {:ok, build} <- sealed(id, digest),
           :ok <- build_current(build, control, true),
           true <- next <= build["dependency_count"],
           count = min(100, build["dependency_count"] - next),
           {:ok, rows} <- dependency_rows(id, next, count),
           true <- length(rows) == count and consecutive?(rows, next),
           result = %{
             "manifest_id" => id,
             "digest" => digest,
             "rows" => rows,
             "next_ordinal" => next + count,
             "exhausted" => next + count == build["dependency_count"],
             "dependency_count" => build["dependency_count"],
             "source_count" => build["source_count"],
             "effective_source_count" => build["effective_source_count"]
           },
           true <- byte_size(Contracts.canonical_json(result)) <= 98_304 do
        {:ok, result}
      else
        false -> {:error, :closure_incomplete}
        error -> error
      end
    end)
  end

  @spec contains_source?(String.t(), String.t(), String.t(), struct()) ::
          {:ok, boolean()} | error()
  def contains_source?(id, digest, source_id, control_ref) do
    guarded(control_ref, nil, fn control ->
      with true <- uuid?(source_id),
           {:ok, build} <- sealed(id, digest),
           :ok <- build_current(build, control, true),
           {:ok, rows} <-
             query(
               "SELECT 1 AS present FROM origin_dependencies WHERE workspace_id=? AND manifest_id=? AND source_id=? AND kind='source_revision' LIMIT 1",
               [Store.workspace(), scope_id(build), source_id]
             ) do
        {:ok, rows != []}
      else
        false -> {:error, :invalid_input}
        error -> error
      end
    end)
  end

  @doc "Prove the direct inventory parent at an exact captured base; this grants no execution."
  def inventory_parent(base, %StageAuthority{} = auth) do
    guarded(auth, nil, fn control ->
      with {:ok, inventory} <- inventory_anchor(base, control) do
        {:ok, if(is_nil(inventory), do: nil, else: inventory_handle(inventory))}
      end
    end)
  end

  def inventory_parent(_, _), do: {:error, :closure_incomplete}

  @doc "Return one absolute-latest published full value directly certified in the captured inventory."
  def inventory_version(base, kind, object, %StageAuthority{} = auth) do
    result =
      guarded(auth, nil, fn control ->
        with true <- inventory_object?(kind, object),
             {:ok, inventory} when not is_nil(inventory) <- inventory_anchor(base, control),
             {:ok, version} <-
               one(
                 "SELECT id,object_kind,object_id,value_hash,value_json,state FROM graph_derivative_versions WHERE workspace_id=? AND partition_id=? AND object_kind=? AND object_id=? ORDER BY version DESC LIMIT 1",
                 [Store.workspace(), control["partition_id"], kind, object]
               ),
             true <- version["state"] == "published" and canonical_inventory_value?(version),
             {:ok, %{"present" => 1}} <-
               one(
                 "SELECT 1 AS present FROM origin_dependencies WHERE workspace_id=? AND manifest_id=? AND derivative_version_id=? AND kind=? AND content_hash=? AND projection_id='identity_v1' AND projection_hash=content_hash LIMIT 1",
                 [
                   Store.workspace(),
                   inventory["manifest_id"],
                   version["id"],
                   kind,
                   version["value_hash"]
                 ]
               ) do
          {:ok,
           Map.take(version, ~w(id object_kind object_id value_hash value_json))
           |> Map.put("parent", inventory_handle(inventory))}
        else
          # A missing historical member is an expected read outcome: callers may
          # separately prove a current-operation save. Do not roll back their
          # enclosing transaction before that independent proof can run. The
          # guarded authority checks still fail and roll back normally.
          _ -> {:ok, :inventory_member_unavailable}
        end
      end)

    case result do
      {:ok, :inventory_member_unavailable} -> {:error, :closure_incomplete}
      other -> other
    end
  end

  def inventory_version(_, _, _, _), do: {:error, :closure_incomplete}

  @doc "Caller-authorized metadata only: exact current inventory configuration, never execution authority."
  def inventory_configuration(partition, caller) do
    HarnessForge.Evidence.Corpora.guard(caller, fn ->
      inventory_configuration_current(partition)
    end)
  end

  @doc "Stored-certificate metadata revalidation only; no caller, old token, provider or execution capability."
  def inventory_configuration_current(partition) do
    HarnessForge.Privacy.Purge.synchronize(fn ->
      Store.transaction(fn ->
        with :ok <- HarnessForge.Workspaces.ensure_writable(),
             :ok <- HarnessForge.Privacy.Purge.ready(),
             true <- uuid?(partition),
             {:ok, row} <-
               one(
                 "SELECT p.workspace_id,p.id AS partition_id,p.corpus_id,p.group_id,p.semantic_generation,p.authorization_generation,p.source_lock_digest,p.backend_pin_digest,p.manifest_id AS operation_manifest_ref,m.digest AS operation_manifest_digest,p.inventory_revision,p.inventory_manifest_id,p.inventory_manifest_digest FROM graph_partition_controls p JOIN dependency_manifests m ON m.workspace_id=p.workspace_id AND m.id=p.manifest_id AND m.state='sealed' WHERE p.workspace_id=? AND p.id=? AND p.state='ready' AND p.inventory_revision>0",
                 [Store.workspace(), partition]
               ),
             :ok <-
               HarnessForge.Evidence.Corpora.assert_current(
                 row["corpus_id"],
                 row["semantic_generation"],
                 row["authorization_generation"]
               ),
             {:ok, bundle} <- HarnessForge.Evidence.GraphSources.runtime_for(partition),
             true <- Contracts.digest(bundle) == row["backend_pin_digest"],
             base =
               Map.take(
                 row,
                 ~w(inventory_revision inventory_manifest_id inventory_manifest_digest)
               ),
             control =
               Map.take(row, @source ++ ~w(operation_manifest_ref operation_manifest_digest)),
             {:ok, _} <- inventory_anchor(base, control),
             {:ok, proof} <- inventory_receipt_proof(base, control),
             {:ok, pins} <- inventory_pin_proof(proof),
             {:ok, final} <-
               one(
                 "SELECT inventory_revision,inventory_manifest_id,inventory_manifest_digest FROM graph_partition_controls WHERE workspace_id=? AND id=? AND state='ready'",
                 [Store.workspace(), partition]
               ),
             true <- final == base,
             do: {:ok, Map.put(pins, "base_inventory", base)},
             else: (_ -> {:error, :closure_incomplete})
      end)
    end)
  end

  @doc "Reprove exact durable base pins under a fresh live authority; v1 receipts cannot select configurations."
  def inventory_stage_pins(base, %StageAuthority{} = auth) do
    guarded(auth, nil, fn control ->
      with true <- base["inventory_revision"] > 0,
           {:ok, _} <- inventory_anchor(base, control),
           {:ok, proof} <- inventory_receipt_proof(base, control),
           {:ok, pins} <- inventory_pin_proof(proof),
           true <-
             pins["stage_pins"] == Enum.sort_by(auth.stage_pins, & &1["id"]) and
               pins["stage_set_digest"] == StageAuthority.stage_set_digest(auth),
           do: {:ok, pins},
           else: (_ -> {:error, :closure_incomplete})
    end)
  end

  def inventory_stage_pins(_, _), do: {:error, :closure_incomplete}

  defp inventory_pin_proof(proof) do
    receipt = proof.receipt
    creator = proof.creator
    ids = receipt["stage_pin_ids"]

    with true <-
           receipt["format"] == "graph-ingest-completion-v2" and is_list(ids) and length(ids) == 5,
         true <- ids == Enum.sort(Enum.uniq(ids)) and Enum.all?(ids, &uuid?/1),
         true <- receipt["stage_set_digest"] == creator["stage_set_digest"],
         {:ok, session} <-
           one(
             "SELECT stage_set_digest FROM graph_worker_sessions WHERE workspace_id=? AND id=? AND partition_id=? AND operation_id=?",
             [
               Store.workspace(),
               creator["worker_session_id"],
               creator["partition_id"],
               creator["id"]
             ]
           ),
         true <- session["stage_set_digest"] == receipt["stage_set_digest"],
         loaded = Enum.map(ids, &StageAuthority.load_pin/1),
         true <- Enum.all?(loaded, &match?({:ok, _}, &1)),
         pins = Enum.map(loaded, &elem(&1, 1)),
         true <-
           Enum.sort(Enum.map(pins, & &1["stage"])) ==
             ~w(edge_dedupe embedder extraction node_dedupe summary),
         true <- Enum.all?(pins, &(SchemaPolicy.validate_pin(&1) == :ok)),
         {:ok, digest} <- Stages.set_digest(pins),
         true <- digest == receipt["stage_set_digest"],
         do: {:ok, %{"stage_pin_ids" => ids, "stage_set_digest" => digest, "stage_pins" => pins}},
         else: (_ -> {:error, :closure_incomplete})
  end

  defp inventory_base_shape?(base) do
    keys?(base, ~w(inventory_revision inventory_manifest_id inventory_manifest_digest)) and
      integer?(base["inventory_revision"]) and
      if(base["inventory_revision"] == 0,
        do: is_nil(base["inventory_manifest_id"]) and is_nil(base["inventory_manifest_digest"]),
        else: uuid?(base["inventory_manifest_id"]) and digest?(base["inventory_manifest_digest"])
      )
  end

  defp inventory_anchor(base, control) do
    with true <- inventory_base_shape?(base),
         {:ok, partition} <-
           one(
             "SELECT inventory_revision,inventory_manifest_id,inventory_manifest_digest,manifest_id,state FROM graph_partition_controls WHERE workspace_id=? AND id=?",
             [Store.workspace(), control["partition_id"]]
           ),
         true <-
           Map.take(partition, Map.keys(base)) == base and
             partition["manifest_id"] == control["operation_manifest_ref"] and
             partition["state"] in ~w(staging ready),
         {:ok, _} <-
           scope_certificate(
             control["operation_manifest_ref"],
             control["operation_manifest_digest"],
             control
           ) do
      if base["inventory_revision"] == 0 do
        if partition["state"] == "staging", do: {:ok, nil}, else: {:error, :closure_incomplete}
      else
        inventory_receipt(base, control)
      end
    else
      _ -> {:error, :closure_incomplete}
    end
  end

  defp inventory_receipt(base, control) do
    with {:ok, proof} <- inventory_receipt_proof(base, control), do: {:ok, proof.inventory}
  end

  defp inventory_receipt_proof(base, control) do
    with {:ok, completion} <-
           sealed(base["inventory_manifest_id"], base["inventory_manifest_digest"]),
         true <-
           completion["graph_kind"] == "derived" and completion["dependency_count"] == 2 and
             completion["partition_id"] == control["partition_id"] and
             completion["source_scope_hash"] == Contracts.digest(Map.take(control, @source)) and
             completion["source_manifest_id"] == control["operation_manifest_ref"] and
             completion["source_manifest_digest"] == control["operation_manifest_digest"],
         context = completion["header"]["context"],
         true <-
           context["seam_id"] == "root.inventory_completion.v1" and
             context["transform_id"] in ~w(root_inventory_compare_v1 root_inventory_compare_v2),
         {:ok, creator} <-
           one(
             "SELECT id,operation_type,state,result_digest,stage_set_digest,partition_id,worker_session_id,lease_id,manifest_id,manifest_digest,source_lock_digest,backend_pin_digest FROM stage_operations WHERE workspace_id=? AND id=?",
             [Store.workspace(), completion["builder_operation_id"]]
           ),
         true <-
           creator["state"] == "completed" and creator["operation_type"] == "ingest" and
             creator["partition_id"] == control["partition_id"] and
             creator["manifest_id"] == control["operation_manifest_ref"] and
             creator["manifest_digest"] == control["operation_manifest_digest"] and
             creator["source_lock_digest"] == control["source_lock_digest"] and
             creator["backend_pin_digest"] == control["backend_pin_digest"],
         execution = completion["header"]["execution_identity"],
         true <-
           execution["operation_id"] == creator["id"] and execution["job_id"] == creator["id"] and
             execution["stage_set_digest"] == creator["stage_set_digest"] and
             execution["session_id"] == creator["worker_session_id"] and
             execution["lease_id"] == creator["lease_id"],
         {:ok, version} <-
           one(
             "SELECT v.id,v.object_kind,v.object_id,v.value_hash,v.value_json,v.manifest_id,v.state FROM origin_dependencies d JOIN graph_derivative_versions v ON v.workspace_id=d.workspace_id AND v.id=d.derivative_version_id WHERE d.workspace_id=? AND d.manifest_id=? AND d.kind='deterministic_output' AND d.content_hash=v.value_hash AND d.projection_id='identity_v1' AND d.projection_hash=v.value_hash AND v.partition_id=? AND v.object_kind='deterministic_output' AND v.object_id=? AND v.version=1 AND v.predecessor_id IS NULL AND NOT EXISTS(SELECT 1 FROM graph_derivative_versions n WHERE n.workspace_id=v.workspace_id AND n.partition_id=v.partition_id AND n.object_kind=v.object_kind AND n.object_id=v.object_id AND n.version>v.version)",
             [
               Store.workspace(),
               completion["manifest_id"],
               control["partition_id"],
               "root_completion:" <> creator["id"]
             ]
           ),
         true <- version["state"] == "published" and canonical_inventory_value?(version),
         {:ok, receipt} <- Contracts.decode_json(version["value_json"]),
         true <-
           receipt["format"] in ~w(graph-ingest-completion-v1 graph-ingest-completion-v2) and
             receipt["inventory_revision"] == base["inventory_revision"] and
             receipt["previous_inventory_revision"] == base["inventory_revision"] - 1 and
             receipt["source_manifest_ref"] == control["operation_manifest_ref"] and
             receipt["source_manifest_digest"] == control["operation_manifest_digest"] and
             digest?(receipt["job_digest"]) and digest?(receipt["completion_digest"]) and
             receipt["completion_digest"] == creator["result_digest"] and
             version["manifest_id"] == receipt["inventory_manifest_ref"] and
             context["base_context_ref"] == receipt["inventory_manifest_ref"] and
             context["base_context_digest"] == receipt["inventory_manifest_digest"],
         {:ok, %{"present" => 1}} <-
           one(
             "SELECT 1 AS present FROM origin_dependencies WHERE workspace_id=? AND manifest_id=? AND kind='manifest' AND parent_manifest_id=? AND content_hash=? LIMIT 1",
             [
               Store.workspace(),
               completion["manifest_id"],
               receipt["inventory_manifest_ref"],
               receipt["inventory_manifest_digest"]
             ]
           ),
         {:ok, inventory} <-
           parent(
             receipt["inventory_manifest_ref"],
             receipt["inventory_manifest_digest"],
             completion
           ),
         true <-
           inventory["graph_kind"] == "derived" and
             inventory["builder_operation_id"] == creator["id"] and
             inventory["header"]["context"]["seam_id"] == "root.inventory_completion.v1" and
             inventory["header"]["context"]["transform_id"] == context["transform_id"] do
      {:ok, %{inventory: inventory, receipt: receipt, creator: creator}}
    else
      _ -> {:error, :closure_incomplete}
    end
  end

  defp canonical_inventory_value?(%{"value_json" => json, "value_hash" => hash})
       when is_binary(json) and byte_size(json) <= 16_384 do
    with {:ok, value} <- Contracts.decode_json(json),
         do: Contracts.canonical_json(value) == json and Contracts.sha256(json) == hash,
         else: (_ -> false)
  end

  defp canonical_inventory_value?(_), do: false

  defp inventory_handle(build),
    do: %{"manifest_ref" => build["manifest_id"], "manifest_digest" => build["digest"]}

  defp inventory_object?(kind, object) when is_binary(object) do
    case String.split(object, ":") do
      [type, uuid] ->
        uuid?(uuid) and
          case kind do
            "deterministic_output" -> type in ~w(EpisodicNode EntityNode EpisodicEdge)
            "edge" -> type == "EntityEdge"
            k when k in ~w(summary attribute) -> type == "EntityNode"
            _ -> false
          end

      _ ->
        false
    end
  end

  defp inventory_object?(_, _), do: false

  @doc "Pure seed for root's independently paged original-source inventory."
  @spec source_set_seed() :: String.t()
  def source_set_seed, do: Contracts.sha256("HF-GRAPH-SOURCE-ROWS-v1\n")

  @doc "Hash one canonical source triple; no source list or database access."
  @spec source_set_step(String.t(), non_neg_integer(), map()) :: String.t()
  def source_set_step(hash, ordinal, triple) do
    if keys?(triple, ~w(source_id revision_id body_hash)) and uuid?(triple["source_id"]) and
         uuid?(triple["revision_id"]) and digest?(triple["body_hash"]) do
      hash_row(hash, ordinal, triple)
    else
      raise ArgumentError, "invalid source triple"
    end
  end

  @spec source_set_finish(String.t(), non_neg_integer()) :: String.t()
  def source_set_finish(hash, count) do
    if digest?(hash) and integer?(count),
      do:
        Contracts.digest(%{
          "format" => "graph-source-set-v1",
          "rows_hash" => hash,
          "source_count" => count
        }),
      else: raise(ArgumentError, "invalid source chain")
  end

  @doc false
  def row_seed, do: Contracts.sha256("HF-GRAPH-MANIFEST-ROWS-v2\n")

  @doc false
  def hash_row(hash, ordinal, row) do
    if digest?(hash) and integer?(ordinal) do
      bytes = Contracts.canonical_json(row)

      Contracts.sha256(
        <<Base.decode16!(hash, case: :lower)::binary, ordinal::unsigned-big-64,
          byte_size(bytes)::unsigned-big-64, bytes::binary>>
      )
    else
      raise ArgumentError, "invalid canonical row chain"
    end
  end

  defp create_build(control, purpose, context, scope, header, encoded) do
    id = Ecto.UUID.generate()
    now = now()
    source? = context["graph_kind"] == "operation"
    source_identity = Map.take(control, @source)

    with :ok <-
           insert("dependency_manifests", %{
             "id" => id,
             "workspace_id" => Store.workspace(),
             "corpus_id" => control["corpus_id"],
             "semantic_generation" => control["semantic_generation"],
             "authorization_generation" => control["authorization_generation"],
             "purpose" => purpose,
             "state" => "building",
             "digest" => nil,
             "source_count" => 0,
             "context_json" => Contracts.canonical_json(context),
             "inserted_at" => now
           }),
         :ok <-
           insert("graph_manifest_builds", %{
             "workspace_id" => Store.workspace(),
             "manifest_id" => id,
             "format" => @format,
             "partition_id" => control["partition_id"],
             "builder_operation_id" => control["operation_id"],
             "graph_kind" => context["graph_kind"],
             "context_id" => context["context_id"],
             "source_manifest_id" => if(source?, do: nil, else: scope["manifest_id"]),
             "source_manifest_digest" => if(source?, do: nil, else: scope["digest"]),
             "source_scope_json" => Contracts.canonical_json(source_identity),
             "source_scope_hash" => Contracts.digest(source_identity),
             "control_hash" => if(source?, do: nil, else: Contracts.digest(control)),
             "header_json" => encoded,
             "header_hash" => Contracts.digest(header),
             "row_chain_hash" => row_seed(),
             "source_chain_hash" => if(source?, do: source_set_seed()),
             "last_source_id" => "",
             "dependency_count" => 0,
             "source_count" => 0,
             "effective_source_count" => if(source?, do: 0, else: scope["source_count"]),
             "next_page_index" => 0,
             "final_received" => 0,
             "phase" => "receiving",
             "validated_page_index" => 0,
             "validated_count" => 0,
             "validation_row_chain_hash" => row_seed(),
             "validation_source_chain_hash" => if(source?, do: source_set_seed()),
             "validation_last_source_id" => "",
             "inserted_at" => now,
             "updated_at" => now
           }),
         {:ok, build} <- load(id) do
      {:ok, status(build)}
    end
  end

  defp append_new(build, page, digest, control) do
    with true <-
           build["phase"] == "receiving" and build["manifest_state"] == "building" and
             build["final_received"] == 0,
         true <-
           page["page_index"] == build["next_page_index"] and
             page["first_ordinal"] == build["dependency_count"],
         {:ok, previous} <- previous_page(build),
         true <- page["previous_page_digest"] == previous,
         rows =
           Enum.with_index(page["rows"], page["first_ordinal"])
           |> Enum.map(fn {row, ordinal} -> Map.put(row, "ordinal", ordinal) end),
         :ok <- validate_rows(rows, build, control),
         {:ok, source_hash, last_source} <-
           source_chain(rows, build["source_chain_hash"], build["last_source_id"], build),
         chain =
           Enum.reduce(rows, build["row_chain_hash"], fn row, hash ->
             hash_row(hash, row["ordinal"], row)
           end),
         changes = %{
           "dependency_count" => build["dependency_count"] + length(rows),
           "source_count" =>
             build["source_count"] + Enum.count(rows, &(&1["kind"] == "source_revision")),
           "row_chain_hash" => chain,
           "source_chain_hash" => source_hash,
           "last_source_id" => last_source,
           "next_page_index" => build["next_page_index"] + 1,
           "final_received" => if(page["final"], do: 1, else: 0)
         },
         ack =
           status(Map.merge(build, changes))
           |> Map.merge(%{"page_index" => page["page_index"], "page_digest" => digest}),
         :ok <-
           insert("graph_manifest_pages", %{
             "workspace_id" => Store.workspace(),
             "manifest_id" => build["manifest_id"],
             "page_index" => page["page_index"],
             "first_ordinal" => page["first_ordinal"],
             "row_count" => length(rows),
             "previous_page_digest" => previous,
             "page_digest" => digest,
             "row_chain_hash" => chain,
             "final" => if(page["final"], do: 1, else: 0),
             "ack_json" => Contracts.canonical_json(ack),
             "inserted_at" => now()
           }),
         :ok <- insert_rows(build["manifest_id"], rows),
         :ok <- update_build(build["manifest_id"], changes) do
      {:ok, ack}
    else
      false -> {:error, :closure_incomplete}
      error -> error
    end
  end

  defp validate_next_page(build, control) do
    with {:ok, page} <-
           one(
             "SELECT * FROM graph_manifest_pages WHERE workspace_id=? AND manifest_id=? AND page_index=?",
             [Store.workspace(), build["manifest_id"], build["validated_page_index"]]
           ),
         true <-
           page["first_ordinal"] == build["validated_count"] and
             page["previous_page_digest"] == build["validated_page_digest"],
         {:ok, rows} <-
           dependency_rows(build["manifest_id"], page["first_ordinal"], page["row_count"]),
         true <- length(rows) == page["row_count"] and consecutive?(rows, page["first_ordinal"]),
         :ok <- validate_rows(rows, build, control),
         dto = %{
           "page_index" => page["page_index"],
           "first_ordinal" => page["first_ordinal"],
           "previous_page_digest" => page["previous_page_digest"],
           "final" => page["final"] == 1,
           "rows" => Enum.map(rows, &Map.delete(&1, "ordinal"))
         },
         true <- page_digest(build, dto) == page["page_digest"],
         chain =
           Enum.reduce(rows, build["validation_row_chain_hash"], fn row, hash ->
             hash_row(hash, row["ordinal"], row)
           end),
         true <- chain == page["row_chain_hash"],
         {:ok, source_hash, last_source} <-
           source_chain(
             rows,
             build["validation_source_chain_hash"],
             build["validation_last_source_id"],
             build
           ),
         changes = %{
           "validated_page_index" => build["validated_page_index"] + 1,
           "validated_page_digest" => page["page_digest"],
           "validated_count" => build["validated_count"] + length(rows),
           "validation_row_chain_hash" => chain,
           "validation_source_chain_hash" => source_hash,
           "validation_last_source_id" => last_source
         },
         updated = Map.merge(build, changes),
         :ok <- page_end(page, updated),
         :ok <- update_build(build["manifest_id"], changes) do
      if page["final"] == 1,
        do: seal_build(updated, control),
        else: load_status(build["manifest_id"])
    else
      false -> {:error, :closure_incomplete}
      error -> error
    end
  end

  defp page_end(page, build) do
    last? = build["validated_page_index"] == build["next_page_index"]

    if page["final"] == 1 == last? and build["validated_count"] <= build["dependency_count"],
      do: :ok,
      else: {:error, :closure_incomplete}
  end

  defp seal_build(build, control) do
    with true <-
           build["validated_count"] == build["dependency_count"] and
             build["validation_row_chain_hash"] == build["row_chain_hash"],
         true <- final_digest(build) == build["candidate_digest"],
         :ok <- source_set_complete(build),
         true <-
           build["graph_kind"] != "operation" or
             build["validation_source_chain_hash"] == build["source_chain_hash"],
         {:ok, extra} <-
           query(
             "SELECT 1 AS extra FROM origin_dependencies WHERE workspace_id=? AND manifest_id=? AND ordinal>=? LIMIT 1",
             [Store.workspace(), build["manifest_id"], build["dependency_count"]]
           ),
         true <- extra == [],
         :ok <- build_current(build, control, false),
         :ok <-
           update_build(build["manifest_id"], %{
             "phase" => "sealed",
             "effective_source_count" =>
               if(build["graph_kind"] == "operation",
                 do: build["source_count"],
                 else: build["effective_source_count"]
               ),
             "validated_at" => now()
           }),
         :ok <-
           write(
             "UPDATE dependency_manifests SET state='sealed',digest=?,source_count=? WHERE workspace_id=? AND id=? AND state='building'",
             [
               build["candidate_digest"],
               build["source_count"],
               Store.workspace(),
               build["manifest_id"]
             ]
           ) do
      load_status(build["manifest_id"])
    else
      false -> {:error, :closure_incomplete}
      error -> error
    end
  end

  defp source_set_complete(%{"graph_kind" => "operation"} = build) do
    expected = build["header"]["source_identity"]["source_lock_digest"]

    if build["source_count"] > 0 and build["source_count"] == build["dependency_count"] and
         source_set_finish(build["source_chain_hash"], build["source_count"]) == expected,
       do: :ok,
       else: {:error, :closure_incomplete}
  end

  defp source_set_complete(_), do: :ok

  defp source_chain(_rows, nil, last, %{"graph_kind" => kind}) when kind != "operation",
    do: {:ok, nil, last}

  defp source_chain(rows, hash, last, build) do
    Enum.reduce_while(rows, {:ok, hash, last}, fn row, {:ok, acc, previous} ->
      if build["graph_kind"] == "operation" and row["kind"] == "source_revision" and
           row["source_id"] > previous do
        triple = %{
          "source_id" => row["source_id"],
          "revision_id" => row["revision_id"],
          "body_hash" => row["content_hash"]
        }

        {:cont, {:ok, source_set_step(acc, row["ordinal"], triple), row["source_id"]}}
      else
        {:halt, {:error, :closure_incomplete}}
      end
    end)
  end

  defp validate_rows(rows, build, control) do
    Enum.reduce_while(rows, :ok, fn row, :ok ->
      with :ok <- row_shape(row),
           true <-
             build["graph_kind"] != "operation" or
               (row["kind"] == "source_revision" and row["role"] == "uncited"),
           :ok <- validate_row(row, build, control) do
        {:cont, :ok}
      else
        false -> {:halt, {:error, :closure_incomplete}}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_row(%{"kind" => "source_revision"} = row, build, _control) do
    with :ok <- source_current(row["source_id"], row["revision_id"], row["content_hash"], build),
         :ok <- source_membership(row, build),
         do: :ok
  end

  defp validate_row(%{"kind" => "manifest"} = row, build, _control) do
    with {:ok, _} <- parent(row["parent_manifest_id"], row["content_hash"], build), do: :ok
  end

  defp validate_row(%{"kind" => "episode"} = row, build, _control) do
    with {:ok, binding} <-
           one(
             "SELECT b.id,b.partition_id,b.revision_id,b.passage_id,b.chunker_version,b.payload_hash,b.state,b.manifest_id,s.revision_id AS passage_revision,s.source_id,s.body_hash,s.chunker_version AS indexed_chunker,s.state AS index_state FROM graph_episode_bindings b JOIN passages p ON p.workspace_id=b.workspace_id AND p.id=b.passage_id JOIN passage_sets s ON s.workspace_id=p.workspace_id AND s.id=p.passage_set_id WHERE b.workspace_id=? AND b.id=?",
             [Store.workspace(), row["episode_binding_id"]]
           ),
         true <-
           binding["partition_id"] == build["partition_id"] and
             binding["payload_hash"] == row["content_hash"] and
             binding["revision_id"] == binding["passage_revision"] and
             binding["chunker_version"] == binding["indexed_chunker"] and
             binding["index_state"] == "ready",
         {:ok, input} <- parent_id(binding["manifest_id"], build),
         true <- eligible_state?(binding["state"], ~w(ready), ~w(staging indexing), input, build),
         :ok <-
           source_current(
             binding["source_id"],
             binding["revision_id"],
             binding["body_hash"],
             build
           ),
         :ok <-
           source_membership(
             %{
               "source_id" => binding["source_id"],
               "revision_id" => binding["revision_id"],
               "content_hash" => binding["body_hash"]
             },
             build
           ) do
      :ok
    else
      false -> {:error, :closure_incomplete}
      error -> error
    end
  end

  defp validate_row(%{"kind" => kind} = row, build, _control)
       when kind in ~w(summary attribute edge rendered_message embed_input deterministic_output) do
    with {:ok, version} <-
           one(
             "SELECT id,partition_id,object_kind,object_id,version,value_hash,value_json,manifest_id,predecessor_id,state FROM graph_derivative_versions WHERE workspace_id=? AND id=?",
             [Store.workspace(), row["derivative_version_id"]]
           ),
         true <-
           version["partition_id"] == build["partition_id"] and version["object_kind"] == kind and
             version["value_hash"] == row["content_hash"],
         :ok <- validate_named_projection(row, version),
         {:ok, input} <- parent_id(version["manifest_id"], build),
         true <- eligible_state?(version["state"], ~w(published), ~w(staging), input, build),
         :ok <- predecessor(version, build) do
      :ok
    else
      false -> {:error, :closure_incomplete}
      error -> error
    end
  end

  defp validate_row(%{"kind" => kind} = row, _build, _control)
       when kind in ~w(goal project profile stage) do
    id = String.replace_prefix(row["dependency_key"], kind <> ":", "")

    case kind do
      "goal" ->
        # Goals hash title/owner/acceptance; these bounded fields, never bodies,
        # are the existing saved-goal content contract.
        with {:ok, goal} <-
               one(
                 "SELECT id,title,owner,acceptance FROM workspace_goals WHERE workspace_id=? AND id=? LIMIT 1",
                 [Store.workspace(), id]
               ),
             true <- HarnessForge.Goals.content_hash(goal) == row["content_hash"] do
          :ok
        else
          _ -> {:error, :closure_incomplete}
        end

      _ ->
        {table, field} =
          case kind do
            "project" -> {"company_projects", "content_hash"}
            "profile" -> {"company_profiles", "content_hash"}
            "stage" -> {"stage_configs", "config_hash"}
          end

        case query(
               "SELECT id FROM #{table} WHERE workspace_id=? AND id=? AND #{field}=? LIMIT 1",
               [Store.workspace(), id, row["content_hash"]]
             ) do
          {:ok, [_]} -> :ok
          _ -> {:error, :closure_incomplete}
        end
    end
  end

  defp validate_named_projection(
         %{"projection_id" => "native_loader_no_vector_v1"} = row,
         version
       ) do
    with true <-
           version["object_kind"] in ~w(deterministic_output edge) and
             inventory_object?(version["object_kind"], version["object_id"]),
         {:ok, hash} <-
           HarnessForge.Graphiti.NativeProjection.projection_hash(
             version["value_json"],
             "native_loader_no_vector_v1"
           ),
         true <- hash == row["projection_hash"],
         do: :ok,
         else: (_ -> {:error, :closure_incomplete})
  end

  defp validate_named_projection(_, _), do: :ok

  defp source_current(source, revision, hash, build) do
    with {:ok, {policy_sql, policy_params}} <- HarnessForge.Evidence.LocalUsePolicies.not_denied_sql("r", "analysis", nil) do
    permission = HarnessForge.Company.CorpusReview.document_scope_sql()

    case query(
           """
           SELECT s.id,r.id AS revision_id,r.body_hash
           FROM evidence_sources s
           JOIN source_connections c ON c.workspace_id=s.workspace_id AND c.id=s.connection_id
           JOIN evidence_revisions r ON r.workspace_id=s.workspace_id AND r.source_id=s.id AND r.id=s.latest_revision_id
           JOIN corpus_members cm ON cm.workspace_id=s.workspace_id AND cm.corpus_id=? AND cm.source_id=s.id
           WHERE s.workspace_id=? AND s.id=? AND r.id=? AND r.body_hash=?
           AND s.status='active' AND c.status='active' AND cm.status='active' AND cm.revision_id=r.id
           AND (#{RevisionUseHolds.not_held_sql("r")})
           AND (#{permission}) AND (#{policy_sql}) LIMIT 1
           """,
           [
             build["header"]["source_identity"]["corpus_id"],
             Store.workspace(),
             source,
             revision,
             hash
           ] ++ policy_params
         ) do
      {:ok, [_]} -> :ok
      _ -> {:error, :source_unavailable}
    end
  end

    end

  defp source_membership(_row, %{"graph_kind" => "operation"}), do: :ok

  defp source_membership(row, build) do
    case query(
           "SELECT 1 AS present FROM origin_dependencies WHERE workspace_id=? AND manifest_id=? AND kind='source_revision' AND source_id=? AND revision_id=? AND content_hash=? LIMIT 1",
           [
             Store.workspace(),
             build["source_manifest_id"],
             row["source_id"],
             row["revision_id"],
             row["content_hash"]
           ]
         ) do
      {:ok, [_]} -> :ok
      _ -> {:error, :closure_incomplete}
    end
  end

  defp predecessor(%{"version" => 1, "predecessor_id" => nil}, _build), do: :ok

  defp predecessor(version, build) do
    with true <- is_integer(version["version"]) and version["version"] > 1,
         {:ok, previous} <-
           one(
             "SELECT partition_id,object_kind,object_id,version,manifest_id,state FROM graph_derivative_versions WHERE workspace_id=? AND id=?",
             [Store.workspace(), version["predecessor_id"]]
           ),
         true <-
           previous["partition_id"] == version["partition_id"] and
             previous["object_kind"] == version["object_kind"] and
             previous["object_id"] == version["object_id"] and
             previous["version"] + 1 == version["version"] and previous["state"] != "denied",
         {:ok, _} <- parent_id(previous["manifest_id"], build) do
      :ok
    else
      _ -> {:error, :closure_incomplete}
    end
  end

  defp eligible_state?(state, published, staging, input, build) do
    state in published or
      (state in staging and input["graph_kind"] != "operation" and
         input["control_hash"] == build["control_hash"] and
         input["builder_operation_id"] == build["builder_operation_id"])
  end

  defp parent_id(id, build) do
    with {:ok, input} <- load(id), do: parent(id, input["digest"], build)
  end

  defp parent(id, digest, build) do
    with {:ok, input} <- sealed(id, digest),
         true <-
           input["source_scope_hash"] == build["source_scope_hash"] and
             input["partition_id"] == build["partition_id"],
         true <-
           (input["graph_kind"] == "operation" and
              input["manifest_id"] == build["source_manifest_id"] and
              input["digest"] == build["source_manifest_digest"]) or
             (input["graph_kind"] != "operation" and
                input["source_manifest_id"] == build["source_manifest_id"] and
                input["source_manifest_digest"] == build["source_manifest_digest"]) do
      {:ok, input}
    else
      _ -> {:error, :closure_incomplete}
    end
  end

  defp context_scope(%{"graph_kind" => "operation"}, _control), do: {:ok, nil}

  defp context_scope(context, control) do
    with {:ok, scope} <-
           scope_certificate(
             context["operation_manifest_ref"],
             context["operation_manifest_digest"],
             control
           ),
         true <-
           context["operation_manifest_ref"] == control["operation_manifest_ref"] and
             context["operation_manifest_digest"] == control["operation_manifest_digest"],
         :ok <- base_context(context, control, scope) do
      {:ok, scope}
    else
      false -> {:error, :closure_incomplete}
      error -> error
    end
  end

  defp base_context(%{"base_context_ref" => nil}, _control, _scope), do: :ok

  defp base_context(context, control, scope) do
    temporary = %{
      "source_scope_hash" => Contracts.digest(Map.take(control, @source)),
      "partition_id" => control["partition_id"],
      "source_manifest_id" => scope["manifest_id"],
      "source_manifest_digest" => scope["digest"]
    }

    with {:ok, input} <-
           parent(context["base_context_ref"], context["base_context_digest"], temporary),
         true <-
           input["graph_kind"] == "operation" or
             input["control_hash"] == Contracts.digest(control) do
      :ok
    else
      _ -> {:error, :closure_incomplete}
    end
  end

  defp scope_certificate(id, digest, control) do
    with {:ok, scope} <- sealed(id, digest),
         true <-
           scope["graph_kind"] == "operation" and
             scope["source_scope_hash"] == Contracts.digest(Map.take(control, @source)),
         {:ok, partition} <-
           one("SELECT manifest_id FROM graph_partition_controls WHERE workspace_id=? AND id=?", [
             Store.workspace(),
             control["partition_id"]
           ]),
         true <- partition["manifest_id"] == id do
      {:ok, scope}
    else
      _ -> {:error, :closure_incomplete}
    end
  end

  defp build_current(build, control, bound?) do
    with true <- build["manifest_state"] != "denied" and build["phase"] != "denied",
         true <- build["source_scope_hash"] == Contracts.digest(Map.take(control, @source)) do
      if build["graph_kind"] == "operation" do
        if bound? do
          with {:ok, _} <- scope_certificate(build["manifest_id"], build["digest"], control),
               do: :ok
        else
          :ok
        end
      else
        with true <- build["control_hash"] == Contracts.digest(control),
             true <-
               build["source_manifest_id"] == control["operation_manifest_ref"] and
                 build["source_manifest_digest"] == control["operation_manifest_digest"],
             {:ok, _} <-
               scope_certificate(
                 build["source_manifest_id"],
                 build["source_manifest_digest"],
                 control
               ),
             :ok <-
               base_context(build["header"]["context"], control, %{
                 "manifest_id" => build["source_manifest_id"],
                 "digest" => build["source_manifest_digest"]
               }) do
          :ok
        else
          _ -> {:error, :closure_incomplete}
        end
      end
    else
      _ -> {:error, :stale_generation}
    end
  end

  defp sealed(id, digest) do
    with true <- uuid?(id) and digest?(digest),
         {:ok, build} <- load(id),
         true <-
           build["manifest_state"] == "sealed" and build["phase"] == "sealed" and
             build["digest"] == digest and build["candidate_digest"] == digest and
             final_digest(build) == digest and
             build["manifest_source_count"] == build["source_count"],
         true <-
           build["validated_at"] != nil and build["validated_count"] == build["dependency_count"] and
             build["validated_page_index"] == build["next_page_index"] and
             build["validation_row_chain_hash"] == build["row_chain_hash"] and
             build["effective_source_count"] > 0 do
      {:ok, build}
    else
      _ -> {:error, :closure_incomplete}
    end
  end

  defp load(id) do
    with true <- uuid?(id),
         {:ok, build} <-
           one(
             "SELECT b.*,m.state AS manifest_state,m.digest,m.purpose,m.corpus_id,m.semantic_generation,m.authorization_generation,m.context_json AS manifest_context_json,m.source_count AS manifest_source_count FROM graph_manifest_builds b JOIN dependency_manifests m ON m.workspace_id=b.workspace_id AND m.id=b.manifest_id WHERE b.workspace_id=? AND b.manifest_id=?",
             [Store.workspace(), id]
           ),
         true <- build["format"] == @format,
         {:ok, header} <- decode(build["header_json"]),
         {:ok, source} <- decode(build["source_scope_json"]),
         {:ok, context} <- decode(build["manifest_context_json"]),
         true <-
           keys?(
             header,
             ~w(format purpose source_identity execution_identity scope_certificate context)
           ) and header["format"] == @format,
         true <-
           header["source_identity"] == source and keys?(source, @source) and
             source["workspace_id"] == Store.workspace() and
             source["partition_id"] == build["partition_id"] and
             source["corpus_id"] == build["corpus_id"] and
             source["semantic_generation"] == build["semantic_generation"] and
             source["authorization_generation"] == build["authorization_generation"],
         true <-
           Contracts.digest(header) == build["header_hash"] and
             Contracts.digest(source) == build["source_scope_hash"] and
             Contracts.canonical_json(header) == build["header_json"] and
             Contracts.canonical_json(source) == build["source_scope_json"],
         true <-
           header["context"] == context and keys?(context, @context) and
             context["graph_kind"] == build["graph_kind"] and
             context["context_id"] == build["context_id"] and
             header["purpose"] == build["purpose"],
         :ok <- stored_execution(build, header) do
      {:ok, Map.put(build, "header", header)}
    else
      _ -> {:error, :closure_incomplete}
    end
  end

  defp stored_execution(%{"graph_kind" => "operation"} = build, header) do
    if is_nil(header["execution_identity"]) and is_nil(header["scope_certificate"]) and
         is_nil(build["source_manifest_id"]) and is_nil(build["control_hash"]),
       do: :ok,
       else: {:error, :closure_incomplete}
  end

  defp stored_execution(build, header) do
    scope = header["scope_certificate"]
    execution = header["execution_identity"]

    if keys?(execution, @execution) and keys?(scope, ~w(ref digest source_count)) and
         scope["ref"] == build["source_manifest_id"] and
         scope["digest"] == build["source_manifest_digest"] and
         scope["source_count"] == build["effective_source_count"] and
         header["context"]["operation_manifest_ref"] == scope["ref"] and
         header["context"]["operation_manifest_digest"] == scope["digest"] do
      control =
        Map.merge(header["source_identity"], execution)
        |> Map.merge(%{
          "operation_manifest_ref" => scope["ref"],
          "operation_manifest_digest" => scope["digest"]
        })

      if Contracts.digest(control) == build["control_hash"] and
           execution["operation_id"] == build["builder_operation_id"],
         do: :ok,
         else: {:error, :closure_incomplete}
    else
      {:error, :closure_incomplete}
    end
  end

  defp existing_build(context, control) do
    {sql, args} =
      if context["graph_kind"] == "operation" do
        {"SELECT manifest_id FROM graph_manifest_builds WHERE workspace_id=? AND partition_id=? AND source_scope_hash=? AND graph_kind='operation'",
         [
           Store.workspace(),
           control["partition_id"],
           Contracts.digest(Map.take(control, @source))
         ]}
      else
        {"SELECT manifest_id FROM graph_manifest_builds WHERE workspace_id=? AND builder_operation_id=? AND graph_kind=? AND context_id=?",
         [
           Store.workspace(),
           control["operation_id"],
           context["graph_kind"],
           context["context_id"]
         ]}
      end

    with {:ok, found} <- optional_one(sql, args) do
      case found do
        nil -> {:ok, nil}
        %{"manifest_id" => id} -> load(id)
      end
    end
  end

  defp context_shape(context, control, auth) do
    with true <- keys?(context, @context) and bounded_json?(context, 16_384),
         true <- context["graph_kind"] in ~w(operation inputs derived attempt_bind),
         true <-
           Enum.all?(
             ~w(operation_manifest base_context),
             &pair?(context[&1 <> "_ref"], context[&1 <> "_digest"])
           ),
         true <- pair?(context["receipt_ref"], context["receipt_digest"], &Ledger.identifier?/1),
         true <-
           Enum.all?(
             ~w(config_digest schema_digest raw_body_sha256 rendered_projection_digest),
             &(is_nil(context[&1]) or digest?(context[&1]))
           ),
         true <- Enum.all?(~w(context_id stage_id), &(is_nil(context[&1]) or uuid?(context[&1]))),
         true <-
           Enum.all?(
             ~w(logical_call_id seam_id prompt_name transform_id),
             &(is_nil(context[&1]) or Ledger.identifier?(context[&1]))
           ) do
      with :ok <- context_phase(context, control), :ok <- context_stage(context, auth), do: :ok
    else
      _ -> {:error, :invalid_input}
    end
  end

  defp context_phase(%{"graph_kind" => "operation"} = context, _control) do
    if Enum.all?(Map.delete(context, "graph_kind"), fn {_, value} -> is_nil(value) end),
      do: :ok,
      else: {:error, :invalid_input}
  end

  defp context_phase(context, control) do
    common =
      Enum.all?(
        ~w(operation_manifest_ref operation_manifest_digest context_id logical_call_id seam_id),
        &(not is_nil(context[&1]))
      )

    stage_fields = ~w(stage_id prompt_name config_digest schema_digest)
    stage? = Enum.all?(stage_fields, &(not is_nil(context[&1])))
    no_stage? = Enum.all?(stage_fields, &is_nil(context[&1]))
    producer? = not is_nil(context["receipt_ref"]) or not is_nil(context["transform_id"])

    valid =
      common and
        case context["graph_kind"] do
          "inputs" ->
            stage? and
              Enum.all?(
                ~w(raw_body_sha256 rendered_projection_digest transform_id receipt_ref receipt_digest),
                &is_nil(context[&1])
              )

          "derived" ->
            not is_nil(context["base_context_ref"]) and producer? and (stage? or no_stage?) and
              is_nil(context["raw_body_sha256"]) and is_nil(context["rendered_projection_digest"])

          "attempt_bind" ->
            stage? and
              Enum.all?(
                ~w(base_context_ref raw_body_sha256 rendered_projection_digest transform_id),
                &(not is_nil(context[&1]))
              ) and is_nil(context["receipt_ref"])
        end

    with true <- valid,
         :ok <- context_receipt(context, control) do
      :ok
    else
      _ -> {:error, :invalid_input}
    end
  end

  defp context_stage(%{"stage_id" => nil}, _control), do: :ok

  defp context_stage(context, auth) do
    with {:ok, pin} <- StageAuthority.load_pin(context["stage_id"]),
         true <- Enum.any?(auth.stage_pins, &(&1 == pin)),
         true <- pin["config_digest"] == context["config_digest"] do
      case pin["stage"] do
        "synthesis" ->
          if pin["schema_digest"] == context["schema_digest"],
            do: :ok,
            else: {:error, :stage_unavailable}

        _ ->
          SchemaPolicy.validate_context(pin, context)
      end
    else
      _ -> {:error, :stage_unavailable}
    end
  end

  defp context_receipt(%{"receipt_ref" => nil}, _control), do: :ok

  defp context_receipt(context, control) do
    # This digest is the settled raw response body hash, not a receipt-envelope
    # digest. Root verifies output/value correspondence separately before use.
    case query(
           "SELECT id FROM stage_attempts WHERE workspace_id=? AND id=? AND operation_id=? AND state='completed' AND result_hash=? LIMIT 1",
           [
             Store.workspace(),
             context["receipt_ref"],
             control["operation_id"],
             context["receipt_digest"]
           ]
         ) do
      {:ok, [_]} -> :ok
      _ -> {:error, :closure_incomplete}
    end
  end

  defp page_shape(page) do
    if keys?(page, @page) and integer?(page["page_index"]) and integer?(page["first_ordinal"]) and
         is_boolean(page["final"]) and is_list(page["rows"]) and length(page["rows"]) <= 100 and
         (page["rows"] != [] or page["final"]) and
         ((page["page_index"] == 0 and is_nil(page["previous_page_digest"])) or
            (page["page_index"] > 0 and digest?(page["previous_page_digest"]))) and
         bounded_json?(page, 98_304) do
      if Enum.all?(page["rows"], &keys?(&1, @row)), do: :ok, else: {:error, :invalid_input}
    else
      {:error, :invalid_input}
    end
  end

  defp row_shape(row) do
    with true <-
           keys?(row, @row ++ ["ordinal"]) and integer?(row["ordinal"]) and row["kind"] in @kinds and
             row["role"] in ~w(cited uncited transitive) and digest?(row["content_hash"]),
         true <- is_binary(row["dependency_key"]) and byte_size(row["dependency_key"]) <= 512,
         true <- pair?(row["projection_id"], row["projection_hash"], &Ledger.identifier?/1),
         true <-
           Enum.all?(
             ~w(source_id revision_id episode_binding_id derivative_version_id parent_manifest_id),
             &(is_nil(row[&1]) or uuid?(row[&1]))
           ),
         {:ok, ref, nullable, projection?} <- row_identity(row),
         true <- Enum.all?(nullable, &is_nil(row[&1])),
         true <- projection? or is_nil(row["projection_id"]),
         suffix = if(is_nil(row["projection_id"]), do: "", else: ":" <> row["projection_id"]),
         true <- row["dependency_key"] == row["kind"] <> ":" <> ref <> suffix do
      :ok
    else
      _ -> {:error, :invalid_input}
    end
  end

  defp row_identity(%{"kind" => "source_revision"} = row) do
    if uuid?(row["source_id"]) and uuid?(row["revision_id"]),
      do:
        {:ok, row["revision_id"], ~w(episode_binding_id derivative_version_id parent_manifest_id),
         false},
      else: {:error, :invalid_input}
  end

  defp row_identity(%{"kind" => "episode"} = row),
    do:
      typed_identity(
        row,
        "episode_binding_id",
        ~w(source_id revision_id derivative_version_id parent_manifest_id),
        true
      )

  defp row_identity(%{"kind" => kind} = row)
       when kind in ~w(summary attribute edge rendered_message embed_input deterministic_output),
       do:
         typed_identity(
           row,
           "derivative_version_id",
           ~w(source_id revision_id episode_binding_id parent_manifest_id),
           true
         )

  defp row_identity(%{"kind" => "manifest", "role" => "transitive"} = row),
    do:
      typed_identity(
        row,
        "parent_manifest_id",
        ~w(source_id revision_id episode_binding_id derivative_version_id),
        false
      )

  defp row_identity(%{"kind" => kind} = row) when kind in ~w(goal project profile stage) do
    id = String.replace_prefix(row["dependency_key"], kind <> ":", "")

    if uuid?(id),
      do:
        {:ok, id,
         ~w(source_id revision_id episode_binding_id derivative_version_id parent_manifest_id),
         false},
      else: {:error, :invalid_input}
  end

  defp row_identity(_), do: {:error, :invalid_input}

  defp typed_identity(row, field, nullable, projection?) do
    if uuid?(row[field]),
      do: {:ok, row[field], nullable, projection?},
      else: {:error, :invalid_input}
  end

  defp header(control, purpose, context, scope) do
    %{
      "format" => @format,
      "purpose" => purpose,
      "source_identity" => Map.take(control, @source),
      "execution_identity" => if(is_nil(scope), do: nil, else: Map.take(control, @execution)),
      "scope_certificate" =>
        if(is_nil(scope),
          do: nil,
          else: %{
            "ref" => scope["manifest_id"],
            "digest" => scope["digest"],
            "source_count" => scope["source_count"]
          }
        ),
      "context" => context
    }
  end

  defp final_digest(build),
    do:
      Contracts.digest(%{
        "format" => @format,
        "header_hash" => build["header_hash"],
        "rows_hash" => build["row_chain_hash"],
        "dependency_count" => build["dependency_count"],
        "source_count" => build["source_count"]
      })

  defp page_digest(build, page),
    do:
      Contracts.digest(%{
        "format" => @page_format,
        "manifest_id" => build["manifest_id"],
        "header_hash" => build["header_hash"],
        "page" => page
      })

  defp status(build) do
    %{
      "manifest_id" => build["manifest_id"],
      "digest" => build["digest"],
      "state" => build["manifest_state"],
      "phase" => build["phase"],
      "next_page_index" => build["next_page_index"],
      "next_ordinal" => build["dependency_count"],
      "dependency_count" => build["dependency_count"],
      "source_count" => build["source_count"],
      "effective_source_count" => build["effective_source_count"],
      "final_received" => build["final_received"] == 1,
      "exhausted" => build["phase"] == "sealed",
      "page_index" => nil,
      "page_digest" => nil
    }
  end

  defp metadata(build) do
    %{
      "manifest_id" => build["manifest_id"],
      "digest" => build["digest"],
      "format" => @format,
      "purpose" => build["purpose"],
      "graph_kind" => build["graph_kind"],
      "context" => build["header"]["context"],
      "dependency_count" => build["dependency_count"],
      "source_count" => build["source_count"],
      "effective_source_count" => build["effective_source_count"],
      "source_identity" => build["header"]["source_identity"],
      "execution_identity" => build["header"]["execution_identity"],
      "scope_certificate_ref" => scope_id(build),
      "scope_certificate_digest" =>
        if(build["graph_kind"] == "operation",
          do: build["digest"],
          else: build["source_manifest_digest"]
        )
    }
  end

  defp scope_id(%{"graph_kind" => "operation"} = build), do: build["manifest_id"]
  defp scope_id(build), do: build["source_manifest_id"]

  defp load_status(id) do
    with {:ok, build} <- load(id), do: {:ok, status(build)}
  end

  defp previous_page(%{"next_page_index" => 0}), do: {:ok, nil}

  defp previous_page(build) do
    with {:ok, page} <-
           one(
             "SELECT page_digest FROM graph_manifest_pages WHERE workspace_id=? AND manifest_id=? AND page_index=?",
             [Store.workspace(), build["manifest_id"], build["next_page_index"] - 1]
           ),
         do: {:ok, page["page_digest"]}
  end

  defp dependency_rows(_id, _first, 0), do: {:ok, []}

  defp dependency_rows(id, first, count) when count in 1..100 do
    query(
      "SELECT " <>
        Enum.join(@row ++ ["ordinal"], ",") <>
        " FROM origin_dependencies WHERE workspace_id=? AND manifest_id=? AND ordinal>=? ORDER BY ordinal LIMIT ?",
      [Store.workspace(), id, first, count]
    )
  end

  defp consecutive?(rows, first),
    do:
      rows
      |> Enum.with_index(first)
      |> Enum.all?(fn {row, ordinal} -> row["ordinal"] == ordinal end)

  defp insert_rows(id, rows),
    do:
      Enum.reduce_while(rows, :ok, fn row, :ok ->
        case insert(
               "origin_dependencies",
               Map.merge(row, %{"workspace_id" => Store.workspace(), "manifest_id" => id})
             ) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)

  defp guarded(%StageAuthority{} = auth, id, fun) do
    result =
      HarnessForge.Privacy.Purge.synchronize(fn ->
        Store.transaction(fn ->
          with {:ok, control} <- current(auth) do
            case fun.(control) do
              {:ok, value} ->
                with {:ok, final} <- current(auth), true <- final == control do
                  {:ok, {:success, value}}
                else
                  _ -> {:error, :stale_generation}
                end

              {:error, reason} when reason in @fatal ->
                if uuid?(id) do
                  with :ok <- deny(id, reason), do: {:ok, {:failure, reason}}
                else
                  {:error, reason}
                end

              error ->
                error
            end
          end
        end)
      end)

    case result do
      {:ok, {:success, value}} -> {:ok, value}
      {:ok, {:failure, reason}} -> {:error, reason}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :graph_unavailable}
    end
  rescue
    error ->
      :telemetry.execute([:harness_forge, :graph_manifest, :boundary_error], %{count: 1}, %{
        exception: error.__struct__
      })

      {:error, :graph_unavailable}
  end

  defp guarded(_, _, _), do: {:error, :invalid_scope}

  defp current(auth) do
    with {:ok, control} <- StageControl.graph_current(auth),
         true <- keys?(control, @control) and control["workspace_id"] == Store.workspace(),
         true <- Enum.all?(~w(workspace_id corpus_id partition_id lease_id), &uuid?(control[&1])),
         true <-
           Enum.all?(
             ~w(group_id operation_id job_id session_id),
             &Ledger.identifier?(control[&1])
           ),
         true <-
           Enum.all?(
             ~w(semantic_generation authorization_generation cancel_epoch partition_lock_version),
             &integer?(control[&1])
           ),
         true <-
           Enum.all?(
             ~w(source_lock_digest backend_pin_digest stage_set_digest),
             &digest?(control[&1])
           ),
         true <- pair?(control["operation_manifest_ref"], control["operation_manifest_digest"]) do
      {:ok, control}
    else
      false ->
        {:error, :invalid_scope}

      {:error, reason}
      when reason in ~w(invalid_input invalid_scope stale_generation source_unavailable closure_incomplete graph_unavailable privacy_operation_incomplete stage_unavailable)a ->
        {:error, reason}

      _ ->
        {:error, :stale_generation}
    end
  end

  defp deny(id, reason) do
    with {:ok, existing} <-
           optional_one(
             "SELECT phase FROM graph_manifest_builds WHERE workspace_id=? AND manifest_id=?",
             [Store.workspace(), id]
           ) do
      case existing do
        nil ->
          :ok

        # A malformed replay cannot revoke immutable, already-certified
        # provenance behind other contexts. Root fences the failing operation;
        # revocation of sealed eligibility is a separate root-owned transition.
        %{"phase" => "sealed"} ->
          :ok

        %{"phase" => phase} ->
          with :ok <-
                 if(phase == "denied",
                   do: :ok,
                   else:
                     update_build(id, %{
                       "phase" => "denied",
                       "error_code" => Atom.to_string(reason)
                     })
                 ),
               :ok <-
                 execute(
                   "UPDATE dependency_manifests SET state='denied' WHERE workspace_id=? AND id=? AND state!='denied'",
                   [Store.workspace(), id]
                 ) do
            :ok
          end
      end
    end
  end

  defp update_build(id, changes) do
    changes = Map.put(changes, "updated_at", now()) |> Enum.sort()

    write(
      "UPDATE graph_manifest_builds SET " <>
        Enum.map_join(changes, ",", fn {key, _} -> key <> "=?" end) <>
        " WHERE workspace_id=? AND manifest_id=?",
      Enum.map(changes, &elem(&1, 1)) ++ [Store.workspace(), id]
    )
  end

  defp insert(table, attrs) do
    fields = Enum.sort(attrs)

    write(
      "INSERT INTO " <>
        table <>
        "(" <>
        Enum.map_join(fields, ",", &elem(&1, 0)) <>
        ") VALUES(" <> Enum.map_join(fields, ",", fn _ -> "?" end) <> ")",
      Enum.map(fields, &elem(&1, 1))
    )
  end

  defp query(sql, args) do
    case Repo.query(sql, args) do
      {:ok, %{columns: columns, rows: rows}} ->
        {:ok, Enum.map(rows, &Map.new(Enum.zip(columns, &1)))}

      _ ->
        {:error, :graph_unavailable}
    end
  end

  defp optional_one(sql, args) do
    case query(sql, args) do
      {:ok, []} -> {:ok, nil}
      {:ok, [row]} -> {:ok, row}
      {:ok, _} -> {:error, :closure_incomplete}
      error -> error
    end
  end

  defp one(sql, args) do
    with {:ok, row} <- optional_one(sql, args), true <- is_map(row) do
      {:ok, row}
    else
      _ -> {:error, :closure_incomplete}
    end
  end

  defp write(sql, args) do
    case Repo.query(sql, args) do
      {:ok, %{num_rows: 1}} -> :ok
      _ -> {:error, :graph_unavailable}
    end
  end

  defp execute(sql, args) do
    case Repo.query(sql, args) do
      {:ok, _} -> :ok
      _ -> {:error, :graph_unavailable}
    end
  end

  defp decode(json) when is_binary(json) do
    case Contracts.decode_json(json) do
      {:ok, value} when is_map(value) -> {:ok, value}
      _ -> {:error, :closure_incomplete}
    end
  end

  defp decode(_), do: {:error, :closure_incomplete}

  defp bounded_json?(value, limit) do
    byte_size(Contracts.canonical_json(value)) <= limit
  rescue
    _ -> false
  end

  defp keys?(value, keys),
    do:
      is_map(value) and not is_struct(value) and map_size(value) == length(keys) and
        Enum.all?(keys, &Map.has_key?(value, &1))

  defp pair?(ref, hash, validator \\ &uuid?/1),
    do: (is_nil(ref) and is_nil(hash)) or (validator.(ref) and digest?(hash))

  defp uuid?(value), do: is_binary(value) and match?({:ok, ^value}, Ecto.UUID.cast(value))
  defp digest?(value), do: is_binary(value) and Regex.match?(~r/\A[a-f0-9]{64}\z/, value)
  defp integer?(value), do: is_integer(value) and value >= 0 and value <= @max
  defp now, do: DateTime.to_iso8601(Store.now())
end
