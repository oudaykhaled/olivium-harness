defmodule HarnessForge.Graphiti.Bootstrap do
  @moduledoc "Bounded native-read certification into fresh current-operation provenance."
  alias HarnessForge.{Contracts, Repo}
  alias HarnessForge.Evidence.{Corpora, GraphManifests, Passages, Store}

  alias HarnessForge.Graphiti.{
    IngestIntent,
    NativeProjection,
    ObservationFlow,
    ObservationLedger,
    Protocol,
    Runtime,
    SchemaPolicy,
    SearchIntent
  }

  alias HarnessForge.Models.{StageAuthority, StageControl}
  @error {:error, :closure_incomplete}
  @row ~w(dependency_key kind source_id revision_id content_hash role episode_binding_id derivative_version_id projection_id projection_hash parent_manifest_id)
  @context ~w(graph_kind operation_manifest_ref operation_manifest_digest base_context_ref base_context_digest context_id logical_call_id seam_id stage_id prompt_name config_digest schema_digest raw_body_sha256 rendered_projection_digest transform_id receipt_ref receipt_digest)
  @types %{
    "EpisodicNode" => {"episode", "deterministic_output", "episode"},
    "EntityNode" => {"deterministic_output", "deterministic_output", "entity"},
    "EntityEdge" => {"edge", "edge", "edge"},
    "EpisodicEdge" => {"deterministic_output", "deterministic_output", "mention"}
  }

  def observe(%StageAuthority{operation_type: type} = auth, job, page)
      when type in ~w(ingest search) do
    with false <- Repo.in_transaction?(),
         :ok <- validate_packet(auth, job, page),
         {:ok, base} <- current(auth, job, page),
         {:ok, replay} <- ObservationLedger.lookup(auth, page) do
      if is_map(replay), do: {:ok, replay}, else: observe_new(auth, job, page, base)
    else
      _ -> @error
    end
  rescue
    _ -> @error
  catch
    _, _ -> @error
  end

  def observe(_, _, _), do: @error

  @doc false
  def validate_packet(auth, job, page) do
    with :ok <- Protocol.validate_payload("job", job),
         :ok <- Protocol.validate_payload("context_page", page),
         true <-
           job["op"] == auth.operation_type and auth.operation_type in ~w(ingest search) and
             job["job_id"] == auth.operation_id,
         true <-
           page["job_id"] == auth.operation_id and page["partition_id"] == auth.partition_id and
             page["lease_id"] == auth.lease_id,
         true <-
           page["operation_manifest_ref"] == auth.manifest_id and
             page["operation_manifest_digest"] == auth.manifest_digest,
         true <-
           page["semantic_generation"] == auth.semantic_generation and
             page["authorization_generation"] == auth.authorization_generation and
             page["cancel_epoch"] == auth.cancel_epoch,
         true <-
           page["seam_id"] == "graphiti.bootstrap.v1" and
             page["prompt_name"] == "graphiti.bootstrap.v1" and page["phase"] == "inputs" and
             page["transform_id"] == "root_inventory_bootstrap_v1",
         true <-
           page["page_index"] == 0 and page["final"] === true and
             is_nil(page["previous_page_digest"]) and is_nil(page["base_context_ref"]) and
             is_nil(page["base_context_digest"]) and page["parent_contexts"] == [] and
             is_nil(page["raw_body_sha256"]),
         pin when is_map(pin) <-
           Enum.find(
             auth.stage_pins,
             &(&1["id"] == page["stage_id"] and &1["stage"] == "extraction")
           ),
         :ok <- SchemaPolicy.validate_context(pin, page),
         true <- page["rendered_projection_digest"] == Contracts.digest(page["entries"]),
         true <-
           Enum.all?(page["entries"], fn e ->
             is_nil(e["version_ref"]) and is_nil(e["predecessor_version_ref"]) and
               is_nil(e["receipt_ref"]) and e["parent_manifest_ref"] == auth.manifest_id and
               e["parent_manifest_digest"] == auth.manifest_digest and
               e["value_hash"] == Contracts.digest(e["value"]) and
               e["projection_hash"] == e["value_hash"]
           end),
         {:ok, ids} <- identities(page["entries"]),
         true <- length(ids) == length(Enum.uniq(ids)),
         native =
           Enum.filter(
             page["entries"],
             &(is_map(&1["value"]) and Map.has_key?(&1["value"], "object_type"))
           ),
         true <- length(native) in 1..10,
         true <- Enum.all?(native, &(&1["value"]["fields"]["group_id"] == auth.scope_ref)),
         true <- scalar_pairs?(page["entries"], native),
         true <-
           auth.operation_type != "search" or
             Enum.all?(
               native,
               &(&1["value"]["object_type"] == "EntityEdge" and
                   &1["projection_id"] == "native_loader_no_vector_v1")
             ),
         do: :ok,
         else: (_ -> @error)
  rescue
    _ -> @error
  end

  @doc false
  def entry_identity(entry) do
    value = entry["value"]

    cond do
      is_map(value) and Map.has_key?(value, "object_type") ->
        with {wire, kind, _} <- @types[value["object_type"]],
             true <- is_map(value["fields"]) and Corpora.uuid?(value["fields"]["uuid"]),
             object = value["object_type"] <> ":" <> value["fields"]["uuid"],
             true <- entry["object_id"] == object and entry["kind"] == wire,
             true <-
               entry["projection_id"] == "identity_v1" or
                 (value["object_type"] in ~w(EntityNode EntityEdge) and
                    entry["projection_id"] == "native_loader_no_vector_v1" and
                    value["vector_commitments"] == %{}),
             do: {:ok, {kind, object}},
             else: (_ -> @error)

      entry["kind"] in ~w(summary attribute) ->
        with "EntityNode:" <> uuid <- entry["object_id"],
             true <- Corpora.uuid?(uuid) and entry["projection_id"] == "identity_v1",
             do: {:ok, {entry["kind"], entry["object_id"]}},
             else: (_ -> @error)

      true ->
        @error
    end
  rescue
    _ -> @error
  end

  defp identities(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn e, {:ok, ids} ->
      case entry_identity(e) do
        {:ok, id} -> {:cont, {:ok, [id | ids]}}
        _ -> {:halt, @error}
      end
    end)
  end

  defp scalar_pairs?(entries, native) do
    Enum.all?(entries, fn e ->
      if e["kind"] in ~w(summary attribute) do
        Enum.any?(native, fn n ->
          n["value"]["object_type"] == "EntityNode" and n["object_id"] == e["object_id"] and
            e["value"] ==
              n["value"]["fields"][if(e["kind"] == "summary", do: "summary", else: "attributes")]
        end)
      else
        true
      end
    end) and
      Enum.all?(native, fn n ->
        n["value"]["object_type"] != "EntityNode" or
          Enum.all?(~w(summary attribute), fn k ->
            Enum.count(entries, &(&1["kind"] == k and &1["object_id"] == n["object_id"])) == 1
          end)
      end)
  end

  defp current(auth, job, page) do
    with :ok <- Runtime.observation_page_current(auth, job, page),
         :ok <- StageAuthority.revalidate_job(%{"authority" => auth, "job" => job}),
         :ok <- validate_intent(auth, job),
         {:ok, _} <- StageControl.graph_current(auth),
         {:ok, base} <- Runtime.base_inventory(auth, job),
         {:ok, _} <- GraphManifests.inventory_parent(base, auth),
         do: {:ok, base}
  end

  defp observe_new(auth, job, page, base) do
    with {:ok, previous} <- ObservationLedger.call_state(auth, page["logical_call_id"]),
         :ok <- ObservationFlow.check(previous.state, page),
         {:ok, plans} <- plans(auth, base, page["entries"]),
         :ok <- measure(auth, job, page, base, plans),
         {:ok, ^base} <- current(auth, job, page) do
      HarnessForge.Privacy.Purge.synchronize(fn ->
        Store.transaction(fn ->
          with {:ok, ^base} <- current(auth, job, page),
               {:ok, ^previous} <- ObservationLedger.call_state(auth, page["logical_call_id"]),
               :ok <- ObservationFlow.check(previous.state, page),
               {:ok, ^plans} <- plans(auth, base, page["entries"]),
               {:ok, parents} <- parents(auth, base, plans),
               {:ok, bindings} <- bindings(auth, job, base, plans),
               {:ok, p} <- seal(auth, context(auth, page, "inputs", nil), parents ++ bindings),
               {:ok, c} <-
                 seal(auth, context(auth, page, "derived", p), [
                   parent(p["manifest_id"], p["digest"]) | Enum.map(plans, &version_row/1)
                 ]),
               ack = ack(page, c, plans),
               {:ok, _} <- ObservationLedger.append(auth, page, ack, previous.sequence),
               {:ok, ^base} <- current(auth, job, page),
               do: {:ok, ack},
               else: (_ -> @error)
        end)
      end)
    else
      _ -> @error
    end
  end

  defp plans(auth, base, entries) do
    Enum.reduce_while(entries, {:ok, []}, fn e, {:ok, acc} ->
      with {:ok, {kind, object}} <- entry_identity(e),
           {:ok, v} <- certified_version(auth, base, kind, object),
           {:ok, full} <- Contracts.decode_json(v["value_json"]),
           true <-
             Contracts.canonical_json(full) == v["value_json"] and
               Contracts.digest(full) == v["value_hash"],
           :ok <- NativeProjection.compare(full, e["value"], e["projection_id"]),
           do: {:cont, {:ok, acc ++ [%{entry: e, version: v, full: full}]}},
           else: (_ -> {:halt, @error})
    end)
  end

  # Published base membership and current saved re-reads are separate proofs.
  def certified_version(auth, base, kind, object) do
    case GraphManifests.inventory_version(base, kind, object, auth) do
      {:ok, value} -> {:ok, value}
      _ -> if(auth.operation_type == "ingest", do: current_save(auth, kind, object), else: @error)
    end
  end

  defp validate_intent(%StageAuthority{operation_type: "search"} = auth, job),
    do: SearchIntent.validate_current(auth, job)

  defp validate_intent(auth, job), do: IngestIntent.validate(auth, job)

  defp current_save(auth, kind, object) do
    with {:ok, v} <-
           one(
             "SELECT id,object_kind,object_id,value_hash,value_json,state FROM graph_derivative_versions WHERE workspace_id=? AND partition_id=? AND object_kind=? AND object_id=? ORDER BY version DESC LIMIT 1",
             [Store.workspace(), auth.partition_id, kind, object]
           ),
         true <- v["state"] in ~w(staging published) and is_binary(v["value_json"]),
         {:ok, p} <-
           one(
             "SELECT m.id,m.digest FROM origin_dependencies d JOIN dependency_manifests m ON m.workspace_id=d.workspace_id AND m.id=d.manifest_id JOIN graph_manifest_builds b ON b.workspace_id=m.workspace_id AND b.manifest_id=m.id JOIN graph_observation_events e ON e.workspace_id=m.workspace_id AND e.manifest_id=m.id WHERE d.workspace_id=? AND d.derivative_version_id=? AND d.kind=? AND d.content_hash=? AND d.projection_id='identity_v1' AND d.projection_hash=d.content_hash AND b.builder_operation_id=? AND b.partition_id=? AND b.source_manifest_id=? AND b.source_manifest_digest=? AND b.phase='sealed' AND m.state='sealed' AND e.operation_id=? AND e.phase='derived' AND json_extract(b.header_json,'$.context.seam_id')='graphiti.save.v1' ORDER BY m.id LIMIT 1",
             [
               Store.workspace(),
               v["id"],
               kind,
               v["value_hash"],
               auth.operation_id,
               auth.partition_id,
               auth.manifest_id,
               auth.manifest_digest,
               auth.operation_id
             ]
           ),
         {:ok, _} <- GraphManifests.validate_current(p["id"], p["digest"], auth),
         do:
           {:ok,
            Map.put(v, "parent", %{"manifest_ref" => p["id"], "manifest_digest" => p["digest"]})},
         else: (_ -> @error)
  end

  defp measure(auth, job, page, base, plans) do
    plans
    |> Enum.filter(fn p -> is_map(p.full) and Map.has_key?(p.full, "object_type") end)
    |> Enum.group_by(& &1.full["object_type"])
    |> Enum.reduce_while(:ok, fn {type, group}, :ok ->
      {_, _, kind} = @types[type]
      ids = Enum.map(group, & &1.full["fields"]["uuid"])

      with true <- length(ids) in 1..10 and ids == Enum.uniq(ids),
           {:ok, ^base} <- current(auth, job, page),
           {:ok, measured} <-
             Runtime.inventory(auth, %{
               "action" => "objects",
               "kind" => kind,
               "cursor" => nil,
               "limit" => length(ids),
               "object_ids" => ids
             }),
           true <-
             Map.new(measured["result"]["records"], &{&1["fields"]["uuid"], &1}) ==
               Map.new(group, &{&1.full["fields"]["uuid"], &1.full}),
           {:ok, ^base} <- current(auth, job, page),
           do: {:cont, :ok},
           else: (_ -> {:halt, @error})
    end)
  end

  defp parents(auth, base, plans) do
    with {:ok, prior} <- GraphManifests.inventory_parent(base, auth) do
      handles =
        [%{"manifest_ref" => auth.manifest_id, "manifest_digest" => auth.manifest_digest}] ++
          if(is_nil(prior), do: [], else: [prior]) ++ Enum.map(plans, & &1.version["parent"])

      {:ok,
       handles |> Enum.uniq() |> Enum.map(&parent(&1["manifest_ref"], &1["manifest_digest"]))}
    end
  end

  defp bindings(auth, job, base, plans) do
    ids =
      Enum.flat_map(plans, fn p ->
        case p.full do
          %{"object_type" => "EpisodicNode", "fields" => f} -> [f["uuid"]]
          %{"object_type" => "EntityEdge", "fields" => f} -> f["episodes"]
          %{"object_type" => "EpisodicEdge", "fields" => f} -> [f["source_node_uuid"]]
          _ -> []
        end
      end)
      |> Enum.uniq()

    if length(ids) <= 100 do
      Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
        with {:ok, b} <-
               one(
                 "SELECT id,passage_id,revision_id,payload_hash,state FROM graph_episode_bindings WHERE workspace_id=? AND partition_id=? AND episode_uuid=? AND state IN('ready','staging','indexing')",
                 [Store.workspace(), auth.partition_id, id]
               ),
             true <- b["state"] == "ready" or b["id"] == job["args"]["binding_id"],
             {:ok, window} <- Passages.envelope(b["passage_id"]),
             true <- window["revision_id"] == b["revision_id"],
             {:ok, true} <-
               GraphManifests.contains_source?(
                 auth.manifest_id,
                 auth.manifest_digest,
                 window["source_id"],
                 auth
               ),
             true <-
               Enum.all?(plans, fn p -> episode_value?(p.full, id, b, window, auth.scope_ref) end),
             :ok <- binding_membership(auth, base, b),
             do:
               {:cont,
                {:ok,
                 acc ++
                   [
                     row(%{
                       "kind" => "episode",
                       "dependency_key" => "episode:" <> b["id"],
                       "episode_binding_id" => b["id"],
                       "content_hash" => b["payload_hash"]
                     })
                   ]}},
             else: (_ -> {:halt, @error})
      end)
    else
      @error
    end
  end

  defp binding_membership(_, _, %{"state" => state}) when state in ~w(staging indexing), do: :ok

  defp binding_membership(auth, base, b) do
    with {:ok, prior} when is_map(prior) <- GraphManifests.inventory_parent(base, auth),
         {:ok, %{rows: [[1]]}} <-
           Repo.query(
             "SELECT 1 FROM origin_dependencies WHERE workspace_id=? AND manifest_id=? AND kind='episode' AND episode_binding_id=? AND content_hash=? LIMIT 1",
             [Store.workspace(), prior["manifest_ref"], b["id"], b["payload_hash"]]
           ),
         do: :ok,
         else: (_ -> @error)
  end

  defp episode_value?(%{"object_type" => "EpisodicNode", "fields" => f}, id, b, window, group) do
    if f["uuid"] == id,
      do:
        f["name"] == b["id"] and f["content"] == window["snippet"] and
          f["source_description"] == b["revision_id"] and f["group_id"] == group and
          f["source"] == "text" and
          same_time?(
            f["valid_at"],
            window["effective_at"] || window["event_at"] || window["captured_at"]
          ),
      else: true
  end

  defp episode_value?(_, _, _, _, _), do: true

  defp same_time?(a, b) do
    with {:ok, left, _} <- DateTime.from_iso8601(a),
         {:ok, right, _} <- DateTime.from_iso8601(b),
         do: DateTime.compare(left, right) == :eq,
         else: (_ -> false)
  end

  defp context(auth, page, kind, p) do
    Map.new(@context, &{&1, nil})
    |> Map.merge(%{
      "graph_kind" => kind,
      "operation_manifest_ref" => auth.manifest_id,
      "operation_manifest_digest" => auth.manifest_digest,
      "context_id" => Ecto.UUID.generate(),
      "logical_call_id" => page["logical_call_id"],
      "seam_id" => page["seam_id"],
      "stage_id" => page["stage_id"],
      "prompt_name" => page["prompt_name"],
      "config_digest" => page["config_digest"],
      "schema_digest" => page["schema_digest"],
      "base_context_ref" => p && p["manifest_id"],
      "base_context_digest" => p && p["digest"],
      "transform_id" => if(kind == "derived", do: "root_inventory_bootstrap_v1", else: nil)
    })
  end

  defp seal(auth, context, entries) do
    entries = Enum.uniq(entries)

    with true <- length(entries) in 1..100,
         {:ok, build} <- GraphManifests.begin_manifest(auth, "derivative", context),
         {:ok, _} <-
           GraphManifests.append_page(
             build["manifest_id"],
             %{
               "page_index" => 0,
               "first_ordinal" => 0,
               "previous_page_digest" => nil,
               "final" => true,
               "rows" => entries
             },
             auth
           ),
         {:ok, _} <-
           GraphManifests.finish_manifest(
             build["manifest_id"],
             %{"dependency_count" => length(entries), "source_count" => 0},
             auth
           ),
         {:ok, status} <- seal_step(auth, build["manifest_id"], 2),
         do: {:ok, status},
         else: (_ -> @error)
  end

  defp seal_step(_, _, 0), do: @error

  defp seal_step(auth, id, n) do
    with {:ok, s} <- GraphManifests.advance_validation(id, auth) do
      if s["phase"] == "sealed", do: {:ok, s}, else: seal_step(auth, id, n - 1)
    end
  end

  defp ack(page, c, plans),
    do: %{
      "job_id" => page["job_id"],
      "context_id" => page["context_id"],
      "page_index" => 0,
      "page_digest" => Protocol.context_page_digest(page),
      "state" => "sealed",
      "version_refs" =>
        Enum.map(plans, &%{"entry_id" => &1.entry["entry_id"], "version_ref" => &1.version["id"]}),
      "context_manifest_ref" => c["manifest_id"],
      "context_manifest_digest" => c["digest"],
      "allowed_body_sha256" => nil,
      "error_code" => nil
    }

  defp version_row(p),
    do:
      row(%{
        "kind" => p.version["object_kind"],
        "dependency_key" =>
          p.version["object_kind"] <> ":" <> p.version["id"] <> ":" <> p.entry["projection_id"],
        "derivative_version_id" => p.version["id"],
        "content_hash" => p.version["value_hash"],
        "projection_id" => p.entry["projection_id"],
        "projection_hash" => p.entry["projection_hash"]
      })

  defp parent(id, digest),
    do:
      row(%{
        "kind" => "manifest",
        "dependency_key" => "manifest:" <> id,
        "parent_manifest_id" => id,
        "content_hash" => digest
      })

  defp row(fields),
    do: Map.new(@row, &{&1, nil}) |> Map.merge(Map.put(fields, "role", "transitive"))

  defp one(sql, params) do
    case Repo.query(sql, params) do
      {:ok, %{columns: cs, rows: [vs]}} -> {:ok, Map.new(Enum.zip(cs, vs))}
      _ -> @error
    end
  end
end
