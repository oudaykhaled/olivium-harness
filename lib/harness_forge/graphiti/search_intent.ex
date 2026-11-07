defmodule HarnessForge.Graphiti.SearchIntent do
  @moduledoc "Immutable root query intent. Preparation, registration and live execution are distinct proofs."
  alias HarnessForge.{Contracts, Repo}
  alias HarnessForge.Evidence.{Corpora, GraphManifests, Store}
  alias HarnessForge.Graphiti.{Completion, Protocol, Runtime, SchemaPolicy}
  alias HarnessForge.Models.{StageAuthority, StageControl}
  @error {:error, :closure_incomplete}
  @keys ~w(format job_digest query limit recipe_id base_inventory retrieval_scope_digest)
  @context ~w(graph_kind operation_manifest_ref operation_manifest_digest base_context_ref base_context_digest context_id logical_call_id seam_id stage_id prompt_name config_digest schema_digest raw_body_sha256 rendered_projection_digest transform_id receipt_ref receipt_digest)
  @row ~w(dependency_key kind source_id revision_id content_hash role episode_binding_id derivative_version_id projection_id projection_hash parent_manifest_id)

  def prepare(%StageAuthority{operation_type: "search"} = auth, job, scope) do
    with :ok <- validate_shape(auth, job),
         {:ok, base} <- Runtime.search_prepared(auth),
         true <-
           scope["corpus_id"] == auth.corpus_id and
             scope["semantic_generation"] == auth.semantic_generation and
             scope["authorization_generation"] == auth.authorization_generation do
      HarnessForge.Privacy.Purge.synchronize(fn ->
        Store.transaction(fn ->
          with {:ok, ^base} <- Runtime.search_prepared(auth),
               {:ok, _} <- GraphManifests.inventory_stage_pins(base, auth),
               {:ok, prior} when is_map(prior) <- GraphManifests.inventory_parent(base, auth),
               {:ok, %{rows: [[0]]}} <-
                 Repo.query(
                   "SELECT count(*) FROM graph_derivative_versions WHERE workspace_id=? AND partition_id=? AND object_id=?",
                   [Store.workspace(), auth.partition_id, object(auth)]
                 ),
               value = %{
                 "format" => "graph-search-intent-v1",
                 "job_digest" => Contracts.digest(job),
                 "query" => job["args"]["query"],
                 "limit" => job["args"]["limit"],
                 "recipe_id" => job["args"]["recipe_id"],
                 "base_inventory" => base,
                 "retrieval_scope_digest" => Contracts.digest(scope_pins(scope))
               },
               {:ok, p} <-
                 seal(auth, context(auth, "inputs", nil), [
                   parent(auth.manifest_id, auth.manifest_digest),
                   parent(prior["manifest_ref"], prior["manifest_digest"]),
                   parent(base["inventory_manifest_id"], base["inventory_manifest_digest"])
                 ]),
               id = Ecto.UUID.generate(),
               :ok <- insert_version(auth, id, object(auth), value, p, "staging"),
               {:ok, c} <-
                 seal(auth, context(auth, "derived", p), [
                   parent(p["manifest_id"], p["digest"]),
                   version_row(id, "deterministic_output", Contracts.digest(value))
                 ]),
               {:ok, ^base} <- Runtime.search_prepared(auth),
               do: {:ok, handle(c)},
               else: (_ -> @error)
        end)
      end)
    else
      _ -> @error
    end
  rescue
    _ -> @error
  end

  def prepare(_, _, _), do: @error

  def validate_prepared(auth, job) do
    with :ok <- validate_shape(auth, job),
         :ok <- StageAuthority.revalidate_job(%{"authority" => auth, "job" => job}),
         {:ok, base} <- Runtime.search_prepared(auth),
         :ok <- validate_bound(auth, job, base),
         do: :ok,
         else: (_ -> @error)
  end

  def validate_current(auth, job) do
    with :ok <- Runtime.observation_current(auth, job),
         {:ok, base} <- Runtime.base_inventory(auth, job),
         :ok <- validate_bound(auth, job, base),
         do: :ok,
         else: (_ -> @error)
  end

  @doc false
  def validate_bound(auth, job, base) do
    with :ok <- validate_shape(auth, job),
         true <- Completion.valid_base?(base) and base["inventory_revision"] > 0,
         {:ok, _} <- StageControl.graph_current(auth),
         {:ok, _} <- GraphManifests.inventory_stage_pins(base, auth),
         {:ok, value, _} <- stored(auth, job),
         true <- value["base_inventory"] == base,
         do: :ok,
         else: (_ -> @error)
  end

  @doc false
  def validate_shape(%StageAuthority{operation_type: "search"} = auth, job) do
    with :ok <- Protocol.validate_payload("job", job),
         true <- job["op"] == "search",
         true <-
           Enum.sort(Enum.map(auth.stage_pins, & &1["stage"])) ==
             ~w(edge_dedupe embedder extraction node_dedupe summary),
         true <-
           Map.take(
             job,
             ~w(job_id scope_ref semantic_generation authorization_generation cancel_epoch closure_ref closure_digest stage_set_digest partition_id lease_id worker_session_id)
           ) == %{
             "job_id" => auth.operation_id,
             "scope_ref" => auth.scope_ref,
             "semantic_generation" => auth.semantic_generation,
             "authorization_generation" => auth.authorization_generation,
             "cancel_epoch" => auth.cancel_epoch,
             "closure_ref" => auth.manifest_id,
             "closure_digest" => auth.manifest_digest,
             "stage_set_digest" => StageAuthority.stage_set_digest(auth),
             "partition_id" => auth.partition_id,
             "lease_id" => auth.lease_id,
             "worker_session_id" => auth.worker_session_id
           },
         true <- valid_input?(input(job)),
         do: :ok,
         else: (_ -> @error)
  rescue
    _ -> @error
  end

  def validate_shape(_, _), do: @error

  @doc false
  def valid_input?(value) do
    is_map(value) and Enum.sort(Map.keys(value)) == ~w(group_id limit query recipe_id) and
      Corpora.text?(value["query"], 1024) and String.length(value["query"]) <= 256 and
      String.trim(value["query"]) != "" and
      is_integer(value["limit"]) and value["limit"] in 1..10 and
      value["recipe_id"] == "edge_hybrid_rrf_v1" and
      is_binary(value["group_id"]) and byte_size(value["group_id"]) in 1..200
  end

  def input(job),
    do: Map.put(Map.take(job["args"], ~w(query limit recipe_id)), "group_id", job["scope_ref"])

  def normalized_input(job), do: [String.replace(job["args"]["query"], "\n", " ")]

  def scope_pins(scope) do
    Map.take(
      scope,
      ~w(corpus_id project_id goal_id goal_hash semantic_generation authorization_generation)
    )
    |> Map.put("workspace_id", Store.workspace())
    |> Map.merge(%{
      "profile" => Map.take(scope["profile"], ~w(id content_hash)),
      "project" => Map.take(scope["project"], ~w(id content_hash))
    })
  end

  def handle(auth, job) do
    with {:ok, _, handle} <- stored(auth, job), do: {:ok, handle}
  end

  def stored(auth, job) do
    with {:ok, v} <-
           one(
             "SELECT id,value_hash,value_json,state,manifest_id FROM graph_derivative_versions WHERE workspace_id=? AND partition_id=? AND object_kind='deterministic_output' AND object_id=? ORDER BY version DESC LIMIT 1",
             [Store.workspace(), auth.partition_id, object(auth)]
           ),
         true <- v["state"] in ~w(staging published),
         {:ok, value} <- canonical_value(v),
         true <-
           Enum.sort(Map.keys(value)) == Enum.sort(@keys) and
             value["format"] == "graph-search-intent-v1" and
             value["job_digest"] == Contracts.digest(job),
         true <- Map.take(value, ~w(query limit recipe_id)) == job["args"],
         {:ok, c} <-
           one(
             "SELECT m.id,m.digest FROM origin_dependencies d JOIN dependency_manifests m ON m.workspace_id=d.workspace_id AND m.id=d.manifest_id JOIN graph_manifest_builds b ON b.workspace_id=m.workspace_id AND b.manifest_id=m.id WHERE d.workspace_id=? AND d.derivative_version_id=? AND d.kind='deterministic_output' AND d.content_hash=? AND d.projection_id='identity_v1' AND d.projection_hash=d.content_hash AND m.state='sealed' AND b.phase='sealed' AND b.builder_operation_id=? AND b.partition_id=? AND b.source_manifest_id=? AND b.source_manifest_digest=? AND json_extract(b.header_json,'$.context.seam_id')='graphiti.search.v1' AND json_extract(b.header_json,'$.context.transform_id')='root_search_intent_v1' ORDER BY m.id LIMIT 1",
             [
               Store.workspace(),
               v["id"],
               v["value_hash"],
               auth.operation_id,
               auth.partition_id,
               auth.manifest_id,
               auth.manifest_digest
             ]
           ),
         {:ok, _} <- GraphManifests.validate_current(c["id"], c["digest"], auth),
         do: {:ok, value, %{"manifest_ref" => c["id"], "manifest_digest" => c["digest"]}},
         else: (_ -> @error)
  end

  @doc false
  def canonical_value(%{"value_json" => json, "value_hash" => hash})
      when is_binary(json) and byte_size(json) <= 98_304 do
    with true <- Contracts.sha256(json) == hash,
         {:ok, value} <- Contracts.decode_json(json),
         true <- Contracts.canonical_json(value) == json,
         do: {:ok, value},
         else: (_ -> @error)
  end

  def canonical_value(_), do: @error

  @doc false
  def context(auth, kind, p) do
    pin = Enum.find(auth.stage_pins, &(&1["stage"] == "embedder"))

    Map.new(@context, &{&1, nil})
    |> Map.merge(%{
      "graph_kind" => kind,
      "operation_manifest_ref" => auth.manifest_id,
      "operation_manifest_digest" => auth.manifest_digest,
      "base_context_ref" => p && p["manifest_id"],
      "base_context_digest" => p && p["digest"],
      "context_id" => Ecto.UUID.generate(),
      "logical_call_id" => auth.operation_id,
      "seam_id" => "graphiti.search.v1",
      "stage_id" => pin["id"],
      "prompt_name" => "graphiti.search.v1",
      "config_digest" => pin["config_digest"],
      "schema_digest" => SchemaPolicy.search_schema_digest(),
      "transform_id" => if(kind == "derived", do: "root_search_intent_v1", else: nil)
    })
  end

  @doc false
  def seal(auth, context, rows) when is_list(rows) and length(rows) in 1..100 do
    with {:ok, rows} <- Completion.unique_dependencies(rows),
         {:ok, started} <- GraphManifests.begin_manifest(auth, "derivative", context),
         {:ok, _} <-
           GraphManifests.append_page(
             started["manifest_id"],
             %{
               "page_index" => 0,
               "first_ordinal" => 0,
               "previous_page_digest" => nil,
               "final" => true,
               "rows" => rows
             },
             auth
           ),
         {:ok, _} <-
           GraphManifests.finish_manifest(
             started["manifest_id"],
             %{"dependency_count" => length(rows), "source_count" => 0},
             auth
           ),
         {:ok, sealed} <- finish(auth, started["manifest_id"], 2),
         do: {:ok, sealed},
         else: (_ -> @error)
  end

  def seal(_, _, _), do: @error

  defp finish(_, _, 0), do: @error

  defp finish(auth, id, left) do
    with {:ok, status} <- GraphManifests.advance_validation(id, auth) do
      if status["phase"] == "sealed", do: {:ok, status}, else: finish(auth, id, left - 1)
    end
  end

  def insert_version(auth, id, object, value, p, state) when state in ~w(staging published) do
    case Repo.query(
           "INSERT INTO graph_derivative_versions(id,workspace_id,partition_id,object_kind,object_id,version,value_hash,value_json,manifest_id,predecessor_id,state,inserted_at) VALUES(?,?,?,'deterministic_output',?,1,?,?,?,NULL,?,?)",
           [
             id,
             Store.workspace(),
             auth.partition_id,
             object,
             Contracts.digest(value),
             Contracts.canonical_json(value),
             p["manifest_id"],
             state,
             DateTime.to_iso8601(Store.now())
           ]
         ) do
      {:ok, %{num_rows: 1}} -> :ok
      _ -> @error
    end
  end

  def parent(id, digest),
    do:
      row(%{
        "kind" => "manifest",
        "dependency_key" => "manifest:" <> id,
        "parent_manifest_id" => id,
        "content_hash" => digest
      })

  def version_row(id, kind, hash),
    do:
      row(%{
        "kind" => kind,
        "dependency_key" => kind <> ":" <> id <> ":identity_v1",
        "derivative_version_id" => id,
        "content_hash" => hash,
        "projection_id" => "identity_v1",
        "projection_hash" => hash
      })

  def row(fields),
    do: Map.new(@row, &{&1, nil}) |> Map.merge(Map.put(fields, "role", "transitive"))

  def handle(manifest),
    do: %{"manifest_ref" => manifest["manifest_id"], "manifest_digest" => manifest["digest"]}

  def one(sql, params) do
    case Repo.query(sql, params) do
      {:ok, %{columns: columns, rows: [values]}} -> {:ok, Map.new(Enum.zip(columns, values))}
      _ -> @error
    end
  end

  defp object(auth), do: "root_search_intent:" <> auth.operation_id
end
