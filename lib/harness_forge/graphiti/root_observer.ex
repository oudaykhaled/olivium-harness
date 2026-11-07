defmodule HarnessForge.Graphiti.RootObserver do
  @moduledoc """
  Root's atomic observation-to-provenance bridge. This grants no model execution.

  Live Runtime ownership, the exact privately registered ingest job, original
  passage intent, qualified schema policy, finite flow and current scope are
  independent prerequisites. Logical model/embed outputs additionally require
  Runtime's qualified raw-response/value proof. Save results require its
  independent quiescent inventory proof. Missing proof interfaces deny.

  Slow proof callbacks run outside SQL/privacy locks. Root holds their private
  observation reservation through commit; control/inventory identity and call
  CAS are checked again inside the single P -> V -> C -> event transaction.
  Only bounded canonical derivative values persist; ACKs/call capsules stay
  body-free. Historical metadata-only versions cannot supply a value proof.
  """
  alias HarnessForge.{Contracts, Repo}
  alias HarnessForge.Evidence.{Corpora, GraphManifests, Passages, Store}

  alias HarnessForge.Graphiti.{
    IngestIntent,
    Bootstrap,
    NativeProjection,
    ObservationFlow,
    ObservationLedger,
    Protocol,
    Runtime,
    SchemaPolicy,
    SearchIntent,
    SearchCompletion
  }

  alias HarnessForge.Models.{StageAuthority, StageControl}

  @error {:error, :closure_incomplete}
  @context ~w(graph_kind operation_manifest_ref operation_manifest_digest base_context_ref base_context_digest context_id logical_call_id seam_id stage_id prompt_name config_digest schema_digest raw_body_sha256 rendered_projection_digest transform_id receipt_ref receipt_digest)
  @row ~w(dependency_key kind source_id revision_id content_hash role episode_binding_id derivative_version_id projection_id projection_hash parent_manifest_id)
  @object_kinds %{
    "EpisodicNode" => "episode",
    "EntityNode" => "deterministic_output",
    "EntityEdge" => "edge",
    "EpisodicEdge" => "deterministic_output"
  }

  @spec observe(struct(), map(), map()) :: {:ok, map()} | {:error, atom()}
  def observe(auth, job, %{"seam_id" => "graphiti.bootstrap.v1"} = page),
    do: Bootstrap.observe(auth, job, page)

  def observe(%StageAuthority{operation_type: type} = auth, job, page)
      when type in ~w(ingest search) do
    with false <- Repo.in_transaction?(),
         :ok <- validate_packet(auth, job, page),
         :ok <- current(auth, job, page),
         {:ok, existing} <- ObservationLedger.lookup(auth, page) do
      if is_map(existing), do: {:ok, existing}, else: observe_new(auth, job, page)
    else
      error -> failure(error)
    end
  rescue
    _ -> @error
  catch
    :exit, _ -> @error
  end

  def observe(_, _, _), do: @error

  defp observe_new(auth, job, page) do
    with {:ok, previous} <- ObservationLedger.call_state(auth, page["logical_call_id"]),
         :ok <- ObservationFlow.check(previous.state, page),
         {:ok, before} <- fence(auth),
         :ok <- outside_proofs(auth, job, page) do
      HarnessForge.Privacy.Purge.synchronize(fn ->
        Store.transaction(fn ->
          with :ok <- current(auth, job, page),
               :ok <- validate_packet(auth, job, page),
               {:ok, ^before} <- fence(auth),
               {:ok, replay} <- ObservationLedger.lookup(auth, page) do
            if is_map(replay) do
              {:ok, replay}
            else
              commit(auth, job, page, previous)
            end
          else
            error -> failure(error)
          end
        end)
      end)
    else
      error -> failure(error)
    end
  end

  defp current(auth, job, page) do
    with :ok <- Runtime.current(auth),
         :ok <- StageAuthority.revalidate_job(%{"authority" => auth, "job" => job}),
         :ok <- validate_intent(auth, job),
         {:ok, base} <- Runtime.base_inventory(auth, job),
         {:ok, _} <- GraphManifests.inventory_parent(base, auth),
         :ok <- runtime_proof(:observation_page_current, [auth, job, page]),
         do: :ok
  end

  defp outside_proofs(auth, job, page) do
    with :ok <- logical_proof(auth, job, page), :ok <- inventory_proof(auth, job, page), do: :ok
  end

  defp logical_proof(
         auth,
         job,
         %{"seam_id" => "llm.response.v1", "entries" => [%{"receipt_ref" => nil}]} = page
       ),
       do: runtime_proof(:observe_values, [auth, page, job])

  defp logical_proof(_, _, _), do: :ok

  defp inventory_proof(
         auth,
         job,
         %{"seam_id" => "graphiti.save.v1", "phase" => "derived"} = page
       ),
       do: runtime_proof(:observe_inventory, [auth, page, job])

  defp inventory_proof(_, _, _), do: :ok

  defp runtime_proof(name, args) do
    if Code.ensure_loaded?(Runtime) and function_exported?(Runtime, name, length(args)) do
      case apply(Runtime, name, args) do
        :ok -> :ok
        error -> failure(error)
      end
    else
      @error
    end
  end

  defp fence(auth) do
    with {:ok, control} <- StageControl.graph_current(auth),
         {:ok, %{rows: [[revision]]}} <-
           Repo.query(
             "SELECT inventory_revision FROM graph_partition_controls WHERE workspace_id=? AND id=?",
             [Store.workspace(), auth.partition_id]
           ),
         do: {:ok, {control, revision}}
  end

  @doc false
  def validate_packet(%StageAuthority{operation_type: type} = auth, job, page)
      when type in ~w(ingest search) do
    with :ok <- Protocol.validate_payload("job", job),
         :ok <- Protocol.validate_payload("context_page", page),
         true <- job["op"] == type and job_control?(auth, job),
         :ok <- packet_intent(auth, job),
         true <- page_control?(auth, job, page),
         true <-
           page["page_index"] == 0 and page["final"] === true and
             is_nil(page["previous_page_digest"]),
         pin when is_map(pin) <- Enum.find(auth.stage_pins, &(&1["id"] == page["stage_id"])),
         :ok <- SchemaPolicy.validate_context(pin, schema_context(page)),
         true <- type != "search" or pin["stage"] == "embedder",
         true <- page["rendered_projection_digest"] == Contracts.digest(page["entries"]),
         true <-
           Enum.all?(page["entries"], fn entry ->
             entry["value_hash"] == Contracts.digest(entry["value"]) and
               entry["projection_hash"] == Contracts.digest(entry["value"])
           end),
         :ok <- validate_values(page, job),
         {:ok, identities} <- identities(page),
         true <- length(Enum.uniq(identities)) == length(identities) do
      :ok
    else
      _ -> @error
    end
  rescue
    _ -> @error
  end

  def validate_packet(_, _, _), do: @error

  defp schema_context(%{"seam_id" => "graphiti.search.v1"} = page), do: page
  defp schema_context(page), do: Map.put(page, "graph_kind", page["phase"])

  defp packet_intent(%StageAuthority{operation_type: "search"} = auth, job),
    do: SearchIntent.validate_shape(auth, job)

  defp packet_intent(_, _), do: :ok

  defp validate_intent(%StageAuthority{operation_type: "search"} = auth, job),
    do: SearchIntent.validate_current(auth, job)

  defp validate_intent(auth, job), do: IngestIntent.validate(auth, job)

  defp job_control?(auth, job) do
    job["job_id"] == auth.operation_id and job["scope_ref"] == auth.scope_ref and
      job["partition_id"] == auth.partition_id and job["lease_id"] == auth.lease_id and
      job["worker_session_id"] == auth.worker_session_id and
      job["closure_ref"] == auth.manifest_id and
      job["closure_digest"] == auth.manifest_digest and
      job["stage_set_digest"] == StageAuthority.stage_set_digest(auth) and
      job["semantic_generation"] == auth.semantic_generation and
      job["authorization_generation"] == auth.authorization_generation and
      job["cancel_epoch"] == auth.cancel_epoch
  end

  defp page_control?(auth, job, page) do
    page["job_id"] == job["job_id"] and page["partition_id"] == auth.partition_id and
      page["lease_id"] == auth.lease_id and page["cancel_epoch"] == auth.cancel_epoch and
      page["semantic_generation"] == auth.semantic_generation and
      page["authorization_generation"] == auth.authorization_generation and
      page["operation_manifest_ref"] == auth.manifest_id and
      page["operation_manifest_digest"] == auth.manifest_digest
  end

  @doc false
  def entry_identity(page, entry, ordinal) when is_integer(ordinal) and ordinal >= 0 do
    value = entry["value"]

    cond do
      entry["kind"] == "deterministic_output" and is_binary(entry["object_id"]) and
          String.starts_with?(entry["object_id"], "loader_view:") ->
        with true <- entry["projection_id"] == "identity_v1" and Corpora.uuid?(page["job_id"]),
             {:ok, {kind, "loader_view:" <> suffix, stable}} <-
               NativeProjection.view_identity(value, entry["object_id"]),
             do: {:ok, {kind, "loader_view:" <> page["job_id"] <> ":" <> suffix, stable}},
             else: (_ -> @error)

      is_map(value) and Map.has_key?(value, "object_type") ->
        type = value["object_type"]
        uuid = get_in(value, ["fields", "uuid"])

        if @object_kinds[type] == entry["kind"] and Corpora.uuid?(uuid) and
             entry["object_id"] == uuid,
           do:
             {:ok,
              {if(type == "EpisodicNode", do: "deterministic_output", else: entry["kind"]),
               type <> ":" <> uuid, true}},
           else: @error

      entry["kind"] in ~w(summary attribute) and Corpora.uuid?(entry["object_id"]) ->
        {:ok, {entry["kind"], "EntityNode:" <> entry["object_id"], true}}

      entry["kind"] in ~w(rendered_message embed_input deterministic_output) ->
        {:ok,
         {entry["kind"],
          "call:" <>
            page["logical_call_id"] <>
            ":" <> page["context_id"] <> ":" <> Integer.to_string(ordinal), false}}

      true ->
        @error
    end
  rescue
    _ -> @error
  end

  def entry_identity(_, _, _), do: @error

  defp identities(page) do
    Enum.with_index(page["entries"])
    |> Enum.reduce_while({:ok, []}, fn {entry, ordinal}, {:ok, ids} ->
      case entry_identity(page, entry, ordinal) do
        {:ok, {kind, object, _}} -> {:cont, {:ok, [{kind, object} | ids]}}
        _ -> {:halt, @error}
      end
    end)
  end

  defp validate_values(page, %{"op" => "search"} = job) do
    case {page["seam_id"], page["phase"], page["entries"]} do
      {"graphiti.search.v1", phase,
       [
         %{
           "kind" => "deterministic_output",
           "projection_id" => "identity_v1",
           "receipt_ref" => nil
         } = entry
       ]}
      when phase in ~w(inputs derived) ->
        if entry["object_id"] == page["logical_call_id"] and is_nil(entry["version_ref"]) and
             is_nil(entry["predecessor_version_ref"]) and
             ((phase == "inputs" and entry["value"] == SearchIntent.input(job)) or
                (phase == "derived" and
                   SearchCompletion.valid_projection?(entry["value"], job["args"]["limit"]))),
           do: :ok,
           else: @error

      {"embedder.input.v1", "inputs",
       [
         %{
           "kind" => "embed_input",
           "projection_id" => "embed_text_v1",
           "receipt_ref" => nil,
           "value" => value
         }
       ]} ->
        if value == SearchIntent.normalized_input(job), do: :ok, else: @error

      {"http.serialized.v1", "attempt_bind",
       [
         %{
           "kind" => "embed_input",
           "projection_id" => "embed_text_v1",
           "receipt_ref" => nil,
           "value" => value
         }
       ]} ->
        if page["transform_id"] == "official_openai_embed_v1" and
             value == SearchIntent.normalized_input(job), do: :ok, else: @error

      {"llm.response.v1", "derived",
       [
         %{"kind" => "deterministic_output", "projection_id" => "identity_v1", "value" => value} =
             entry
       ]}
      when is_map(value) ->
        valid =
          if is_nil(entry["receipt_ref"]) do
            entry["object_id"] == page["logical_call_id"] and
              Enum.sort(Map.keys(value)) == ["embedding_vectors"] and
              is_list(value["embedding_vectors"]) and length(value["embedding_vectors"]) == 1
          else
            entry["object_id"] == value["attempt_id"] and
              Enum.sort(Map.keys(value)) == ~w(attempt_id body_bytes body_sha256 http_status)
          end

        if valid, do: :ok, else: @error

      _ ->
        @error
    end
  end

  defp validate_values(page, job) do
    values = Enum.map(page["entries"], & &1["value"])

    with true <- Enum.all?(values, &native_tree?(&1, job)),
         true <- Enum.all?(page["entries"], &attribute_value?(&1, page, values)),
         true <- save_result?(page),
         do: :ok,
         else: (_ -> @error)
  end

  defp save_result?(%{"seam_id" => "graphiti.save.v1", "phase" => "derived"} = page) do
    detail =
      Enum.filter(page["entries"], fn entry ->
        entry["kind"] == "deterministic_output" and entry["object_id"] == page["logical_call_id"]
      end)

    with [%{"value" => value, "projection_id" => "identity_v1"}] <- detail,
         true <- is_map(value) and Enum.sort(Map.keys(value)) == ~w(after before result),
         true <- is_map(value["before"]) and is_map(value["after"]) do
      result = value["result"]

      if is_map(result) do
        save_descriptor?(result, value["after"])
      else
        # Qualified _process_episode_data returns (episodic_edges, episode).
        # Its domain projection is distinct from a concrete-save descriptor.
        case result do
          [edges, %{"object_type" => "EpisodicNode"} = episode] when is_list(edges) ->
            not Map.has_key?(value["after"], "object") and
              Enum.all?(edges, &(is_map(&1) and &1["object_type"] == "EpisodicEdge")) and
              is_map(episode["fields"])

          _ ->
            false
        end
      end
    else
      _ -> false
    end
  end

  defp save_result?(_), do: true

  defp save_descriptor?(result, arguments) do
    with {:ok, catalogue} <- SchemaPolicy.catalogue(),
         policy when is_map(policy) <- catalogue["route_policy"]["save_completion"],
         true <-
           policy["format"] == "native-save-completion-policy-v1" and policy["v"] == 1 and
             policy["descriptor_format"] == "native-save-completion-v1" and
             Enum.sort(policy["descriptor_fields"]) == ~w(format method return_kind returned_uuid),
         true <-
           Enum.sort(Map.keys(result)) == ~w(format method return_kind returned_uuid) and
             result["format"] == policy["descriptor_format"],
         [variant] <- Enum.filter(policy["variants"], &(&1["method"] == result["method"])),
         true <- variant["return_kind"] == result["return_kind"] do
      if result["method"] == "add_nodes_and_edges_bulk" do
        result["return_kind"] == "none" and is_nil(result["returned_uuid"]) and
          is_nil(variant["object_type"]) and is_nil(variant["returned_uuid"]) and
          not Map.has_key?(arguments, "object") and native_objects(arguments) != []
      else
        type = variant["object_type"]
        object = arguments["object"]

        Map.has_key?(@object_kinds, type) and result["method"] == type <> ".save" and
          result["return_kind"] == "neo4j-eager-uuid" and
          variant["returned_uuid"] == "saved_object.uuid" and
          is_map(object) and object["object_type"] == type and
          Corpora.uuid?(result["returned_uuid"]) and
          get_in(object, ["fields", "uuid"]) == result["returned_uuid"]
      end
    else
      _ -> false
    end
  end

  defp native_tree?(value, job) when is_map(value) do
    valid = if Map.has_key?(value, "object_type"), do: native_object?(value, job), else: true
    valid and Enum.all?(Map.values(value), &native_tree?(&1, job))
  end

  defp native_tree?(value, job) when is_list(value), do: Enum.all?(value, &native_tree?(&1, job))
  defp native_tree?(_, _), do: true

  defp native_object?(value, job) do
    fields = value["fields"]
    type = value["object_type"]

    Enum.sort(Map.keys(value)) == ~w(fields object_type vector_commitments) and
      Map.has_key?(@object_kinds, type) and is_map(fields) and is_map(value["vector_commitments"]) and
      Corpora.uuid?(fields["uuid"]) and fields["group_id"] == job["scope_ref"] and
      if(type == "EpisodicNode",
        do: episode_job?(fields, job) or ready_episode?(fields, job),
        else: true
      ) and
      if type == "EntityEdge",
        do:
          is_list(fields["episodes"]) and length(fields["episodes"]) <= 100 and
            Enum.all?(fields["episodes"], &Corpora.uuid?/1),
        else: true
  end

  @doc false
  def episode_job?(fields, job) do
    args = job["args"]

    if fields["uuid"] == args["episode_uuid"] do
      fields["group_id"] == job["scope_ref"] and fields["name"] == args["binding_id"] and
        fields["content"] == args["body"] and fields["source_description"] == args["revision_id"] and
        fields["source"] == "text" and same_time?(fields["valid_at"], args["reference_time"])
    else
      fields["uuid"] in args["prior_episode_ids"] and fields["group_id"] == job["scope_ref"]
    end
  rescue
    _ -> false
  end

  defp ready_episode?(fields, job) do
    with true <-
           fields["uuid"] != job["args"]["episode_uuid"] and
             fields["group_id"] == job["scope_ref"],
         {:ok, %{rows: [[id, revision, passage]]}} <-
           Repo.query(
             "SELECT id,revision_id,passage_id FROM graph_episode_bindings WHERE workspace_id=? AND partition_id=? AND episode_uuid=? AND state='ready'",
             [Store.workspace(), job["partition_id"], fields["uuid"]]
           ),
         {:ok, window} <- Passages.envelope(passage),
         true <-
           window["revision_id"] == revision and fields["name"] == id and
             fields["source_description"] == revision and fields["content"] == window["snippet"] and
             fields["source"] == "text" and same_time?(fields["valid_at"], reference_time(window)),
         do: true,
         else: (_ -> false)
  rescue
    _ -> false
  end

  defp same_time?(left, right) do
    with {:ok, a, _} <- DateTime.from_iso8601(left),
         {:ok, b, _} <- DateTime.from_iso8601(right),
         do: DateTime.compare(a, b) == :eq,
         else: (_ -> false)
  end

  defp attribute_value?(entry, page, values) do
    if entry["kind"] in ~w(summary attribute) do
      field = if entry["kind"] == "summary", do: "summary", else: "attributes"

      matching =
        native_objects(values)
        |> Enum.find(fn value ->
          value["object_type"] == "EntityNode" and value["fields"]["uuid"] == entry["object_id"]
        end)

      ordinary = is_map(matching) and matching["fields"][field] == entry["value"]

      override =
        is_map(matching) and entry["kind"] == "attribute" and
          page["seam_id"] == "graphiti.attributes.v1" and page["phase"] == "derived" and
          Enum.any?(page["entries"], fn detail ->
            detail["kind"] == "deterministic_output" and
              detail["object_id"] == page["logical_call_id"] and is_map(detail["value"]) and
              Map.has_key?(detail["value"], "result") and
              detail["value"]["result"] == entry["value"]
          end)

      ordinary or override
    else
      true
    end
  end

  defp native_objects(value) when is_list(value), do: Enum.flat_map(value, &native_objects/1)

  defp native_objects(value) when is_map(value) do
    here = if Map.has_key?(value, "object_type"), do: [value], else: []
    here ++ Enum.flat_map(Map.values(value), &native_objects/1)
  end

  defp native_objects(_), do: []

  defp commit(auth, job, page, previous) do
    with {:ok, ^previous} <- ObservationLedger.call_state(auth, page["logical_call_id"]),
         :ok <- ObservationFlow.check(previous.state, page),
         :ok <- search_parents(auth, job, page),
         {:ok, receipt} <- physical_receipt(auth, page, previous.state),
         {:ok, intent} <- intent(auth, job),
         {:ok, bindings} <- episode_bindings(auth, job, page, intent),
         {:ok, declared} <- parent_handles(auth, page, intent, bindings),
         {:ok, plans} <- plans(auth, page, declared),
         parents = unique_handles(declared ++ Enum.flat_map(plans, & &1.proofs)),
         {:ok, p} <-
           seal(
             auth,
             context(auth, page, "inputs", nil, nil),
             Enum.map(parents, &parent_row/1) ++ Enum.map(bindings, &binding_row/1)
           ),
         {:ok, versions} <- persist_versions(auth, p, plans),
         c_kind = if(page["phase"] == "attempt_bind", do: "attempt_bind", else: "derived"),
         {:ok, c} <-
           seal(auth, context(auth, page, c_kind, p, receipt), [
             parent_row(handle(p)) | Enum.map(versions, &version_row/1)
           ]),
         ack = acknowledgement(auth, page, c, versions),
         {:ok, _} <- ObservationLedger.append(auth, page, ack, previous.sequence),
         :ok <- current(auth, job, page) do
      {:ok, ack}
    else
      error -> failure(error)
    end
  end

  defp search_parents(
         auth,
         %{"op" => "search"},
         %{"seam_id" => "graphiti.search.v1", "phase" => "derived"} = page
       ),
       do: SearchCompletion.validate_outer_parents(auth, page)

  defp search_parents(auth, %{"op" => "search"}, %{"seam_id" => "embedder.input.v1"} = page) do
    ids = Enum.map(page["parent_contexts"], & &1["manifest_ref"])

    if ids == [] do
      @error
    else
      case Repo.query(
             "SELECT 1 FROM graph_observation_events e JOIN graph_manifest_builds b ON b.workspace_id=e.workspace_id AND b.manifest_id=e.manifest_id JOIN graph_observation_calls c ON c.workspace_id=e.workspace_id AND c.operation_id=e.operation_id AND c.logical_call_id=e.logical_call_id WHERE e.workspace_id=? AND e.operation_id=? AND e.phase='inputs' AND b.phase='sealed' AND json_extract(b.header_json,'$.context.seam_id')='graphiti.search.v1' AND c.state='active' AND json_extract(c.state_json,'$.family')='search' AND json_extract(c.state_json,'$.step')='search' AND json_extract(c.state_json,'$.base.manifest_ref')=e.manifest_id AND e.manifest_id IN(" <>
               Enum.map_join(ids, ",", fn _ -> "?" end) <> ") LIMIT 1",
             [Store.workspace(), auth.operation_id] ++ ids
           ) do
        {:ok, %{rows: [[1]]}} -> :ok
        _ -> @error
      end
    end
  end

  defp search_parents(_, _, _), do: :ok

  defp physical_receipt(
         auth,
         %{
           "seam_id" => "llm.response.v1",
           "entries" => [%{"receipt_ref" => receipt, "value" => value}]
         } = page,
         state
       )
       when is_binary(receipt) do
    pending = state && state["pending_bind"]

    with true <-
           is_map(value) and
             Enum.sort(Map.keys(value)) == ~w(attempt_id body_bytes body_sha256 http_status),
         true <-
           value["attempt_id"] == receipt and Map.get(hd(page["entries"]), "object_id") == receipt,
         true <- is_map(pending),
         {:ok, predecessor} <- previous_receipt(auth, state),
         {:ok, %{rows: [[hash, status, bytes, payload]]}} <-
           Repo.query(
             "SELECT a.result_hash,a.response_status,a.response_bytes,a.payload_hash FROM stage_attempts a JOIN model_requests r ON r.workspace_id=a.workspace_id AND r.id=a.model_request_id JOIN graph_observation_events e ON e.workspace_id=a.workspace_id AND e.operation_id=a.operation_id AND e.consumed_attempt_id=a.id WHERE a.workspace_id=? AND a.id=? AND a.operation_id=? AND a.logical_call_id=? AND a.stage_config_id=? AND a.state='completed' AND a.ordinal=? AND a.predecessor_attempt_id IS ? AND r.state='completed' AND r.usage_status='reported' AND r.run_id=? AND r.request_id=a.id AND r.provider=? AND r.model=? AND e.binding_state='consumed' AND e.manifest_id=? AND e.logical_call_id=a.logical_call_id AND json_extract(e.ack_json,'$.allowed_body_sha256')=a.payload_hash",
             [
               Store.workspace(),
               receipt,
               auth.operation_id,
               page["logical_call_id"],
               page["stage_id"],
               length(state["responses"]) + 1,
               predecessor,
               auth.operation_id,
               Enum.find(auth.stage_pins, &(&1["id"] == page["stage_id"]))["provider"],
               Enum.find(auth.stage_pins, &(&1["id"] == page["stage_id"]))["model"],
               pending["manifest_ref"]
             ]
           ),
         true <-
           hash == value["body_sha256"] and status == value["http_status"] and
             bytes == value["body_bytes"] and is_binary(payload),
         {:ok, %{rows: [[digest]]}} <-
           Repo.query(
             "SELECT digest FROM dependency_manifests WHERE id=? AND workspace_id=? AND state='sealed'",
             [pending["manifest_ref"], Store.workspace()]
           ),
         true <- digest == pending["manifest_digest"] do
      {:ok, %{"id" => receipt, "hash" => hash}}
    else
      _ -> @error
    end
  end

  defp physical_receipt(_, _, _), do: {:ok, nil}

  defp previous_receipt(_auth, %{"responses" => []}), do: {:ok, nil}

  defp previous_receipt(auth, state) do
    previous = List.last(state["responses"])

    case Repo.query(
           "SELECT json_extract(v.value_json,'$.attempt_id') FROM graph_observation_events e JOIN origin_dependencies d ON d.workspace_id=e.workspace_id AND d.manifest_id=e.manifest_id AND d.kind='deterministic_output' JOIN graph_derivative_versions v ON v.workspace_id=d.workspace_id AND v.id=d.derivative_version_id WHERE e.workspace_id=? AND e.operation_id=? AND e.manifest_id=? AND e.phase='derived' AND v.value_json IS NOT NULL LIMIT 2",
           [Store.workspace(), auth.operation_id, previous["manifest_ref"]]
         ) do
      {:ok, %{rows: [[id]]}} -> if Corpora.uuid?(id), do: {:ok, id}, else: @error
      _ -> @error
    end
  end

  defp intent(auth, %{"op" => "search"} = job) do
    with {:ok, handle} <- SearchIntent.handle(auth, job),
         do: {:ok, %{input: handle["manifest_ref"], digest: handle["manifest_digest"]}}
  end

  defp intent(auth, job) do
    with {:ok, %{rows: [[id, episode, revision, passage, payload, input, digest]]}} <-
           Repo.query(
             "SELECT b.id,b.episode_uuid,b.revision_id,b.passage_id,b.payload_hash,b.manifest_id,m.digest FROM graph_episode_bindings b JOIN dependency_manifests m ON m.workspace_id=b.workspace_id AND m.id=b.manifest_id AND m.state='sealed' WHERE b.workspace_id=? AND b.partition_id=? AND b.id=? AND b.state IN('staging','indexing')",
             [Store.workspace(), auth.partition_id, job["args"]["binding_id"]]
           ),
         true <-
           episode == job["args"]["episode_uuid"] and revision == job["args"]["revision_id"] and
             payload == Contracts.digest(job["args"]) do
      {:ok,
       %{
         id: id,
         episode: episode,
         revision: revision,
         passage: passage,
         payload: payload,
         input: input,
         digest: digest
       }}
    else
      _ -> @error
    end
  end

  defp episode_bindings(_auth, %{"op" => "search"}, _page, _intent), do: {:ok, []}

  defp episode_bindings(auth, job, page, intent) do
    objects = native_objects(Enum.map(page["entries"], & &1["value"]))

    ids =
      objects
      |> Enum.flat_map(fn object ->
        fields = object["fields"]

        case object["object_type"] do
          "EpisodicNode" -> [fields["uuid"]]
          "EntityEdge" -> fields["episodes"] || []
          "EpisodicEdge" -> [fields["source_node_uuid"]]
          _ -> []
        end
      end)
      |> Enum.uniq()

    Enum.reduce_while(ids, {:ok, [intent]}, fn episode, {:ok, bindings} ->
      with true <- Corpora.uuid?(episode),
           {:ok, binding} <- binding(auth, episode),
           true <- binding.id == intent.id or binding.state == "ready",
           :ok <- prior_binding(auth, job, binding),
           :ok <- original_episode(binding, objects, job) do
        {:cont, {:ok, [binding | bindings]}}
      else
        _ -> {:halt, @error}
      end
    end)
    |> case do
      {:ok, bindings} -> {:ok, Enum.uniq_by(bindings, & &1.id)}
      error -> error
    end
  end

  defp prior_binding(_auth, _job, %{state: state}) when state in ~w(staging indexing), do: :ok

  defp prior_binding(auth, job, binding) do
    with {:ok, base} <- Runtime.base_inventory(auth, job),
         {:ok, parent} when is_map(parent) <- GraphManifests.inventory_parent(base, auth),
         {:ok, %{rows: [[1]]}} <-
           Repo.query(
             "SELECT 1 FROM origin_dependencies WHERE workspace_id=? AND manifest_id=? AND kind='episode' AND episode_binding_id=? AND content_hash=? LIMIT 1",
             [Store.workspace(), parent["manifest_ref"], binding.id, binding.payload]
           ),
         do: :ok,
         else: (_ -> @error)
  end

  defp binding(auth, episode) do
    case Repo.query(
           "SELECT b.id,b.episode_uuid,b.revision_id,b.passage_id,b.payload_hash,b.manifest_id,m.digest,b.state FROM graph_episode_bindings b JOIN dependency_manifests m ON m.workspace_id=b.workspace_id AND m.id=b.manifest_id AND m.state='sealed' WHERE b.workspace_id=? AND b.partition_id=? AND b.episode_uuid=? AND b.state IN('staging','indexing','ready') LIMIT 1",
           [Store.workspace(), auth.partition_id, episode]
         ) do
      {:ok, %{rows: [[id, uuid, revision, passage, payload, input, digest, state]]}} ->
        {:ok,
         %{
           id: id,
           episode: uuid,
           revision: revision,
           passage: passage,
           payload: payload,
           input: input,
           digest: digest,
           state: state
         }}

      _ ->
        @error
    end
  end

  defp original_episode(binding, objects, job) do
    snapshots =
      Enum.filter(
        objects,
        &(&1["object_type"] == "EpisodicNode" and &1["fields"]["uuid"] == binding.episode)
      )

    if snapshots == [] do
      :ok
    else
      with {:ok, window} <- Passages.envelope(binding.passage),
           true <- window["revision_id"] == binding.revision,
           true <-
             Enum.all?(snapshots, fn snapshot ->
               fields = snapshot["fields"]

               fields["content"] == window["snippet"] and fields["name"] == binding.id and
                 fields["source_description"] == binding.revision and fields["source"] == "text" and
                 (episode_job?(fields, job) or binding.state == "ready") and
                 same_time?(fields["valid_at"], reference_time(window))
             end),
           do: :ok,
           else: (_ -> @error)
    end
  end

  defp reference_time(window) do
    Enum.find_value(~w(effective_at event_at captured_at), fn field ->
      case window[field] do
        value when is_binary(value) ->
          case DateTime.from_iso8601(value) do
            {:ok, date, _} -> DateTime.to_iso8601(date)
            _ -> nil
          end

        _ ->
          nil
      end
    end)
  end

  defp parent_handles(auth, page, intent, bindings) do
    base =
      if page["base_context_ref"],
        do: [
          %{
            "manifest_ref" => page["base_context_ref"],
            "manifest_digest" => page["base_context_digest"]
          }
        ],
        else: []

    entries =
      Enum.map(
        page["entries"],
        &%{
          "manifest_ref" => &1["parent_manifest_ref"],
          "manifest_digest" => &1["parent_manifest_digest"]
        }
      )

    inputs =
      Enum.map(
        [intent | bindings],
        &%{"manifest_ref" => &1.input, "manifest_digest" => &1.digest}
      )

    handles = [
      %{"manifest_ref" => auth.manifest_id, "manifest_digest" => auth.manifest_digest}
      | base ++ page["parent_contexts"] ++ entries ++ inputs
    ]

    by_id = Enum.group_by(handles, & &1["manifest_ref"])

    if Enum.all?(by_id, fn {id, values} ->
         Corpora.uuid?(id) and length(Enum.uniq(values)) == 1
       end), do: {:ok, unique_handles(handles)}, else: @error
  end

  defp plans(auth, page, parents) do
    Enum.with_index(page["entries"])
    |> Enum.reduce_while({:ok, []}, fn {entry, ordinal}, {:ok, plans} ->
      with {:ok, {kind, object, stable}} <- entry_identity(page, entry, ordinal),
           {:ok, latest} <- latest(auth, kind, object),
           {:ok, plan} <- entry_plan(auth, entry, kind, object, stable, latest, parents) do
        {:cont, {:ok, [plan | plans]}}
      else
        _ -> {:halt, @error}
      end
    end)
    |> case do
      {:ok, plans} -> {:ok, Enum.reverse(plans)}
      error -> error
    end
  end

  defp entry_plan(auth, entry, kind, object, stable, latest, parents) do
    cond do
      entry["projection_id"] == "native_loader_no_vector_v1" ->
        with true <- stable and not is_nil(latest) and latest.state in ~w(staging published),
             true <-
               entry["version_ref"] == latest.id and is_nil(entry["predecessor_version_ref"]),
             true <- canonical_value?(latest.json, latest.hash),
             {:ok, full} <- Contracts.decode_json(latest.json),
             :ok <- NativeProjection.compare(full, entry["value"], "native_loader_no_vector_v1"),
             {:ok, proof} <- read_parent(auth, latest, parents),
             do:
               {:ok,
                %{
                  entry: entry,
                  kind: kind,
                  object: object,
                  id: latest.id,
                  version: latest.version,
                  predecessor: nil,
                  new: false,
                  proofs: [proof],
                  full_hash: latest.hash
                }},
             else: (_ -> @error)

      String.starts_with?(object, "loader_view:") ->
        value = entry["value"]

        full_kind =
          if value["object_type"] == "EntityEdge", do: "edge", else: "deterministic_output"

        full_object = value["object_type"] <> ":" <> value["fields"]["uuid"]

        with {:ok, full} when not is_nil(full) <- latest(auth, full_kind, full_object),
             true <-
               full.state in ~w(staging published) and canonical_value?(full.json, full.hash),
             {:ok, anchor} <- version_parent(auth, full, Enum.map(parents, & &1["manifest_ref"])),
             {:ok, p} <- plan(auth, entry, kind, object, stable, latest, parents),
             do: {:ok, %{p | proofs: [anchor | p.proofs]}},
             else: (_ -> @error)

      true ->
        with :ok <- complete_snapshot?(entry, object, latest),
             {:ok, p} <- plan(auth, entry, kind, object, stable, latest, parents),
             {:ok, view_parents} <- materialized_view(auth, object, p, parents),
             do: {:ok, %{p | proofs: p.proofs ++ view_parents}}
    end
  end

  defp complete_snapshot?(entry, object, latest) do
    if not is_nil(latest) and
         (String.starts_with?(object, "EntityNode:") or String.starts_with?(object, "EntityEdge:")) and
         is_map(entry["value"]) and entry["value"]["vector_commitments"] == %{} do
      # A persisted loader view is never a changed full native identity.
      with {:ok, previous} <- Contracts.decode_json(latest.json) do
        if (latest.state == "staging" and previous["vector_commitments"] == %{}) or
             (latest.hash == entry["value_hash"] and
                latest.json == Contracts.canonical_json(entry["value"])), do: :ok, else: @error
      else
        _ -> @error
      end
    else
      :ok
    end
  end

  defp read_parent(auth, version, parents) do
    ids = Enum.map(parents, & &1["manifest_ref"])
    placeholders = Enum.map_join(ids, ",", fn _ -> "?" end)

    case Repo.query(
           "SELECT m.id,m.digest FROM origin_dependencies d JOIN dependency_manifests m ON m.workspace_id=d.workspace_id AND m.id=d.manifest_id JOIN graph_manifest_builds b ON b.workspace_id=m.workspace_id AND b.manifest_id=m.id WHERE d.workspace_id=? AND d.derivative_version_id=? AND d.content_hash=? AND b.builder_operation_id=? AND b.partition_id=? AND b.source_manifest_id=? AND b.source_manifest_digest=? AND m.state='sealed' AND b.phase='sealed' AND json_extract(b.header_json,'$.context.seam_id') IN('graphiti.bootstrap.v1','graphiti.save.v1') AND d.manifest_id IN(" <>
             placeholders <> ") ORDER BY m.id LIMIT 1",
           [
             Store.workspace(),
             version.id,
             version.hash,
             auth.operation_id,
             auth.partition_id,
             auth.manifest_id,
             auth.manifest_digest
           ] ++ ids
         ) do
      {:ok, %{rows: [[id, digest]]}} ->
        with {:ok, _} <- GraphManifests.validate_current(id, digest, auth),
             do: {:ok, %{"manifest_ref" => id, "manifest_digest" => digest}}

      _ ->
        @error
    end
  end

  defp materialized_view(auth, object, %{new: true}, parents) do
    if String.starts_with?(object, "EntityNode:") or String.starts_with?(object, "EntityEdge:") do
      with {:ok, view} <-
             latest(
               auth,
               "deterministic_output",
               "loader_view:" <> auth.operation_id <> ":" <> object
             ) do
        if is_nil(view) do
          {:ok, []}
        else
          with true <-
                 view.state in ~w(staging published) and canonical_value?(view.json, view.hash),
               {:ok, proof} <- version_parent(auth, view, Enum.map(parents, & &1["manifest_ref"])),
               do: {:ok, [proof]},
               else: (_ -> @error)
        end
      end
    else
      {:ok, []}
    end
  end

  defp materialized_view(_, _, _, _), do: {:ok, []}

  defp latest(auth, kind, object) do
    case Repo.query(
           "SELECT id,version,value_hash,value_json,state FROM graph_derivative_versions WHERE workspace_id=? AND partition_id=? AND object_kind=? AND object_id=? ORDER BY version DESC LIMIT 1",
           [Store.workspace(), auth.partition_id, kind, object]
         ) do
      {:ok, %{rows: []}} ->
        {:ok, nil}

      {:ok, %{rows: [[id, version, hash, json, state]]}} ->
        {:ok, %{id: id, version: version, hash: hash, json: json, state: state}}

      _ ->
        @error
    end
  end

  defp plan(_auth, entry, kind, object, _stable, nil, _parents) do
    if is_nil(entry["version_ref"]) and is_nil(entry["predecessor_version_ref"]),
      do:
        {:ok,
         %{
           entry: entry,
           kind: kind,
           object: object,
           id: Ecto.UUID.generate(),
           version: 1,
           predecessor: nil,
           new: true,
           proofs: []
         }},
      else: @error
  end

  defp plan(auth, entry, kind, object, true, latest, parents) do
    json = Contracts.canonical_json(entry["value"])
    ref = entry["version_ref"]
    predecessor = entry["predecessor_version_ref"]
    same = latest.hash == entry["value_hash"] and latest.json == json
    valid = latest.state in ~w(staging published) and canonical_value?(latest.json, latest.hash)

    cond do
      not valid ->
        @error

      same and (is_nil(predecessor) or predecessor == latest.id) and
        (is_nil(ref) or ref == latest.id) and
          not (is_binary(ref) and is_binary(predecessor)) ->
        allowed =
          if is_nil(ref) and is_nil(predecessor),
            do: nil,
            else: Enum.map(parents, & &1["manifest_ref"])

        with {:ok, proof} <- version_parent(auth, latest, allowed),
             do:
               {:ok,
                %{
                  entry: entry,
                  kind: kind,
                  object: object,
                  id: latest.id,
                  version: latest.version,
                  predecessor: nil,
                  new: false,
                  proofs: [proof]
                }}

      not same and is_nil(ref) and predecessor == latest.id ->
        with {:ok, proof} <- version_parent(auth, latest, Enum.map(parents, & &1["manifest_ref"])),
             do:
               {:ok,
                %{
                  entry: entry,
                  kind: kind,
                  object: object,
                  id: Ecto.UUID.generate(),
                  version: latest.version + 1,
                  predecessor: latest.id,
                  new: true,
                  proofs: [proof]
                }}

      true ->
        @error
    end
  end

  defp plan(_, _, _, _, _, _, _), do: @error

  defp canonical_value?(json, hash) when is_binary(json) do
    with {:ok, value} <- Contracts.decode_json(json),
         do: Contracts.canonical_json(value) == json and Contracts.sha256(json) == hash,
         else: (_ -> false)
  end

  defp canonical_value?(_, _), do: false

  defp version_parent(auth, version, allowed) do
    filter =
      if is_list(allowed),
        do: " AND d.manifest_id IN (" <> Enum.map_join(allowed, ",", fn _ -> "?" end) <> ")",
        else: ""

    params =
      [
        Store.workspace(),
        version.id,
        version.hash,
        auth.partition_id,
        auth.manifest_id,
        auth.manifest_digest
      ] ++ (allowed || [])

    case Repo.query(
           "SELECT m.id,m.digest FROM origin_dependencies d JOIN dependency_manifests m ON m.workspace_id=d.workspace_id AND m.id=d.manifest_id JOIN graph_manifest_builds b ON b.workspace_id=m.workspace_id AND b.manifest_id=m.id WHERE d.workspace_id=? AND d.derivative_version_id=? AND d.content_hash=? AND m.state='sealed' AND b.phase='sealed' AND b.partition_id=? AND b.source_manifest_id=? AND b.source_manifest_digest=?" <>
             filter <> " ORDER BY d.manifest_id LIMIT 1",
           params
         ) do
      {:ok, %{rows: [[id, digest]]}} ->
        {:ok, %{"manifest_ref" => id, "manifest_digest" => digest}}

      _ ->
        @error
    end
  end

  defp persist_versions(auth, parent, plans) do
    Enum.reduce_while(plans, {:ok, []}, fn plan, {:ok, versions} ->
      result =
        if plan.new do
          Repo.query(
            "INSERT INTO graph_derivative_versions(id,workspace_id,partition_id,object_kind,object_id,version,value_hash,value_json,manifest_id,predecessor_id,state,inserted_at) VALUES(?,?,?,?,?,?,?,?,?,?,'staging',?)",
            [
              plan.id,
              Store.workspace(),
              auth.partition_id,
              plan.kind,
              plan.object,
              plan.version,
              plan.entry["value_hash"],
              Contracts.canonical_json(plan.entry["value"]),
              parent["manifest_id"],
              plan.predecessor,
              now()
            ]
          )
        else
          {:ok, :existing}
        end

      case result do
        {:ok, _} -> {:cont, {:ok, [plan | versions]}}
        _ -> {:halt, @error}
      end
    end)
    |> case do
      {:ok, versions} -> {:ok, Enum.reverse(versions)}
      error -> error
    end
  end

  defp context(auth, page, kind, parent, receipt) do
    Map.new(@context, &{&1, nil})
    |> Map.merge(%{
      "graph_kind" => kind,
      "operation_manifest_ref" => auth.manifest_id,
      "operation_manifest_digest" => auth.manifest_digest,
      "context_id" => Ecto.UUID.generate(),
      "logical_call_id" => page["logical_call_id"],
      "stage_id" => page["stage_id"],
      "prompt_name" => page["prompt_name"],
      "config_digest" => page["config_digest"],
      "schema_digest" => page["schema_digest"],
      "seam_id" => page["seam_id"],
      "base_context_ref" => if(parent, do: parent["manifest_id"], else: page["base_context_ref"]),
      "base_context_digest" =>
        if(parent, do: parent["digest"], else: page["base_context_digest"]),
      "transform_id" => if(kind != "inputs", do: page["transform_id"]),
      "raw_body_sha256" => if(kind == "attempt_bind", do: page["raw_body_sha256"]),
      "rendered_projection_digest" =>
        if(kind == "attempt_bind", do: page["rendered_projection_digest"]),
      "receipt_ref" => if(receipt && kind != "inputs", do: receipt["id"]),
      "receipt_digest" => if(receipt && kind != "inputs", do: receipt["hash"])
    })
  end

  defp seal(auth, context, rows) do
    rows = Enum.uniq_by(rows, & &1["dependency_key"]) |> Enum.sort_by(& &1["dependency_key"])

    with {:ok, started} <- GraphManifests.begin_manifest(auth, "derivative", context),
         :ok <- append_pages(auth, started["manifest_id"], rows),
         {:ok, _} <-
           GraphManifests.finish_manifest(
             started["manifest_id"],
             %{"dependency_count" => length(rows), "source_count" => 0},
             auth
           ),
         {:ok, sealed} <-
           validate_pages(auth, started["manifest_id"], div(length(rows) + 99, 100) + 1),
         do: {:ok, sealed}
  end

  defp append_pages(auth, id, rows) do
    pages = Enum.chunk_every(rows, 100)

    Enum.with_index(pages)
    |> Enum.reduce_while({:ok, nil}, fn {entries, index}, {:ok, previous} ->
      case GraphManifests.append_page(
             id,
             %{
               "page_index" => index,
               "first_ordinal" => index * 100,
               "previous_page_digest" => previous,
               "final" => index == length(pages) - 1,
               "rows" => entries
             },
             auth
           ) do
        {:ok, ack} -> {:cont, {:ok, ack["page_digest"]}}
        _ -> {:halt, @error}
      end
    end)
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp validate_pages(_, _, 0), do: @error

  defp validate_pages(auth, id, remaining) do
    case GraphManifests.advance_validation(id, auth) do
      {:ok, %{"state" => "sealed"} = sealed} -> {:ok, sealed}
      {:ok, _} -> validate_pages(auth, id, remaining - 1)
      _ -> @error
    end
  end

  defp parent_row(handle),
    do:
      Map.new(@row, &{&1, nil})
      |> Map.merge(%{
        "kind" => "manifest",
        "dependency_key" => "manifest:" <> handle["manifest_ref"],
        "parent_manifest_id" => handle["manifest_ref"],
        "content_hash" => handle["manifest_digest"],
        "role" => "transitive"
      })

  defp binding_row(binding),
    do:
      Map.new(@row, &{&1, nil})
      |> Map.merge(%{
        "kind" => "episode",
        "dependency_key" => "episode:" <> binding.id,
        "episode_binding_id" => binding.id,
        "content_hash" => binding.payload,
        "role" => "transitive"
      })

  defp version_row(plan),
    do:
      Map.new(@row, &{&1, nil})
      |> Map.merge(%{
        "kind" => plan.kind,
        "dependency_key" => plan.kind <> ":" <> plan.id <> ":" <> plan.entry["projection_id"],
        "derivative_version_id" => plan.id,
        "content_hash" => Map.get(plan, :full_hash, plan.entry["value_hash"]),
        "projection_id" => plan.entry["projection_id"],
        "projection_hash" => plan.entry["projection_hash"],
        "role" => "transitive"
      })

  defp handle(manifest),
    do: %{"manifest_ref" => manifest["manifest_id"], "manifest_digest" => manifest["digest"]}

  defp unique_handles(handles), do: Enum.uniq_by(handles, & &1["manifest_ref"])

  defp acknowledgement(auth, page, manifest, versions),
    do: %{
      "job_id" => auth.operation_id,
      "context_id" => page["context_id"],
      "page_index" => 0,
      "page_digest" => Protocol.context_page_digest(page),
      "state" => "sealed",
      "version_refs" =>
        Enum.map(versions, &%{"entry_id" => &1.entry["entry_id"], "version_ref" => &1.id}),
      "context_manifest_ref" => manifest["manifest_id"],
      "context_manifest_digest" => manifest["digest"],
      "allowed_body_sha256" => page["raw_body_sha256"],
      "error_code" => nil
    }

  defp failure({:error, reason}) when is_atom(reason) do
    if Atom.to_string(reason) in Protocol.error_codes() or reason == :changed_replay,
      do: {:error, reason},
      else: @error
  end

  defp failure(_), do: @error
  defp now, do: DateTime.to_iso8601(Store.now())
end
