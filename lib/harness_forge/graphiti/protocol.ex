defmodule HarnessForge.Graphiti.Protocol do
  @moduledoc "Strict, bounded packet-4 worker protocol. Input never creates atoms."
  alias HarnessForge.{Contracts, Models.Stages}

  @max 131_072
  @body 98_304
  @errors ~w(invalid_frame invalid_dto scope_denied stale_generation closure_incomplete stage_unavailable consent_required budget_exhausted cancelled deadline_exceeded provider_error response_limit worker_lost reconcile_required purge_denied)
  @frame ~w(v kind session_id seq request_id payload)
  @job ~w(op job_id idempotency_key scope_ref semantic_generation authorization_generation cancel_epoch closure_ref closure_digest stage_set_digest partition_id lease_id worker_session_id deadline_ms args)
  @attempt ~w(job_id logical_call_id attempt_id stage_id stage_digest prompt_name closure_ref closure_digest context_manifest_ref context_manifest_digest cancel_epoch payload_sha256 method route_id body timeout_ms max_output_tokens context_changed ordinal predecessor_attempt_id)
  @grant ~w(attempt_id grant_id payload_sha256 expires_at cancel_epoch)
  @receipt ~w(attempt_id receipt_id state http_status body body_sha256 usage_status billing_status input_tokens output_tokens error_code)
  @result ~w(job_id state generation closure_digest receipt_count receipt_digest result)
  @context_page ~w(job_id partition_id lease_id cancel_epoch semantic_generation authorization_generation operation_manifest_ref operation_manifest_digest context_id logical_call_id phase seam_id stage_id prompt_name config_digest schema_digest page_index previous_page_digest final entries base_context_ref base_context_digest parent_contexts raw_body_sha256 rendered_projection_digest transform_id)
  @context_entry ~w(entry_id kind object_id version_ref predecessor_version_ref value_hash value projection_id projection_hash parent_manifest_ref parent_manifest_digest receipt_ref)
  @context_ack ~w(job_id context_id page_index page_digest state version_refs context_manifest_ref context_manifest_digest allowed_body_sha256 error_code)

  def max_frame, do: @max
  def error_codes, do: @errors
  def safe_code(value) when is_atom(value), do: safe_code(Atom.to_string(value))
  def safe_code(value) when value in @errors, do: value
  def safe_code(_), do: "provider_error"

  def decode(bytes) when is_binary(bytes) and byte_size(bytes) in 1..@max do
    with true <- String.valid?(bytes),
         {:ok, ordered} <- Jason.decode(bytes, objects: :ordered_objects),
         {:ok, frame} <- normalize(ordered, 0),
         :ok <- validate_frame(frame) do
      {:ok, frame}
    else
      _ -> {:error, :invalid_frame}
    end
  rescue
    _ -> {:error, :invalid_frame}
  end

  def decode(_), do: {:error, :invalid_frame}

  def encode(frame) do
    with :ok <- validate_frame(frame),
         {:ok, bytes} <- Jason.encode(frame),
         true <- byte_size(bytes) in 1..@max do
      {:ok, <<byte_size(bytes)::unsigned-big-32, bytes::binary>>}
    else
      _ -> {:error, :invalid_frame}
    end
  end

  @doc "Incremental raw-port decoding checks the prefix before buffering a body."
  def consume(buffer), do: consume(buffer, [])
  defp consume(buffer, acc) when byte_size(buffer) < 4, do: {:ok, Enum.reverse(acc), buffer}

  defp consume(<<length::unsigned-big-32, _::binary>>, _acc) when length < 1 or length > @max,
    do: {:error, :invalid_frame}

  defp consume(<<length::unsigned-big-32, rest::binary>> = buffer, acc) do
    if byte_size(rest) < length do
      {:ok, Enum.reverse(acc), buffer}
    else
      <<bytes::binary-size(length), tail::binary>> = rest
      with {:ok, frame} <- decode(bytes), do: consume(tail, [frame | acc])
    end
  end

  def validate_frame(frame) do
    valid =
      keys?(frame, @frame) and frame["v"] === 1 and
        Stages.identifier?(frame["session_id"]) and Stages.identifier?(frame["request_id"]) and
        Stages.integer_in?(frame["seq"], 1, 9_007_199_254_740_991)

    if valid,
      do: validate_payload(frame["kind"], frame["payload"]),
      else: {:error, :invalid_frame}
  end

  def validate_payload("boot", p) do
    valid =
      keys?(
        p,
        ~w(source_lock_digest backend_pin_digest backend_uri backend_user backend_password database stage_pins stage_set_digest)
      ) and
        hashes?(p, ~w(source_lock_digest backend_pin_digest stage_set_digest)) and
        Stages.identifier?(p["database"]) and bounded?(p["backend_user"], 16384, true) and
        bounded?(p["backend_password"], 16384, true) and backend?(p["backend_uri"]) and
        is_list(p["stage_pins"]) and length(p["stage_pins"]) <= 7 and
        Enum.all?(p["stage_pins"], &match?({:ok, _}, Stages.validate_pin(&1))) and
        Stages.set_digest(p["stage_pins"]) == {:ok, p["stage_set_digest"]}

    verdict(valid)
  end

  def validate_payload("prepare_runtime", p) do
    verdict(
      keys?(p, ~w(operation_id partition_id lease_id scope_ref stage_set_digest)) and
        ids?(p, ~w(operation_id partition_id lease_id scope_ref)) and
        hashes?(p, ~w(stage_set_digest))
    )
  end

  def validate_payload("prepare_runtime_ack", p) do
    verdict(
      keys?(
        p,
        ~w(operation_id partition_id lease_id scope_ref stage_set_digest initialized source_lock_digest backend_pin_digest error_code)
      ) and
        ids?(p, ~w(operation_id partition_id lease_id scope_ref)) and
        hashes?(p, ~w(stage_set_digest source_lock_digest backend_pin_digest)) and
        is_boolean(p["initialized"]) and
        ((p["initialized"] == true and is_nil(p["error_code"])) or
           (p["initialized"] == false and p["error_code"] in @errors))
    )
  end

  def validate_payload("job", p) do
    valid =
      keys?(p, @job) and
        ids?(p, ~w(job_id idempotency_key scope_ref closure_ref worker_session_id)) and
        hashes?(p, ~w(closure_digest stage_set_digest)) and
        counters?(p, ~w(semantic_generation authorization_generation cancel_epoch)) and
        Stages.integer_in?(p["deadline_ms"], 1, 3_600_000) and args?(p["op"], p["args"]) and
        job_controls?(p)

    verdict(valid)
  end

  def validate_payload("attempt", p) do
    valid =
      keys?(p, @attempt) and
        ids?(
          p,
          ~w(job_id logical_call_id attempt_id stage_id closure_ref context_manifest_ref route_id)
        ) and
        hashes?(p, ~w(stage_digest closure_digest context_manifest_digest payload_sha256)) and
        Stages.nonnegative?(p["cancel_epoch"]) and p["method"] == "POST" and
        bounded?(p["prompt_name"], 200) and bounded?(p["body"], @body) and
        p["payload_sha256"] == Contracts.sha256(p["body"] || "") and
        Stages.integer_in?(p["timeout_ms"], 1, 60000) and
        Stages.integer_in?(p["max_output_tokens"], 1, 4096) and
        is_boolean(p["context_changed"]) and Stages.integer_in?(p["ordinal"], 1, 3) and
        ((p["ordinal"] == 1 and is_nil(p["predecessor_attempt_id"])) or
           (p["ordinal"] in [2, 3] and Stages.identifier?(p["predecessor_attempt_id"])))

    verdict(valid)
  end

  def validate_payload("attempt_grant", p) do
    valid =
      keys?(p, @grant) and ids?(p, ~w(attempt_id grant_id)) and
        Stages.digest?(p["payload_sha256"]) and bounded?(p["expires_at"], 100) and
        Stages.nonnegative?(p["cancel_epoch"])

    verdict(valid)
  end

  def validate_payload("attempt_result", p) do
    valid =
      keys?(p, @receipt) and ids?(p, ~w(attempt_id receipt_id)) and
        p["state"] in ~w(completed denied cancelled uncertain stale invalid) and
        (is_nil(p["http_status"]) or Stages.integer_in?(p["http_status"], 100, 599)) and
        (is_nil(p["body"]) or
           (bounded?(p["body"], @body, true) and p["body_sha256"] == Contracts.sha256(p["body"]))) and
        (is_nil(p["body_sha256"]) or Stages.digest?(p["body_sha256"])) and
        p["usage_status"] in ~w(reported unknown) and
        p["billing_status"] in ~w(estimated local_unpriced unknown) and
        nullable_counter?(p["input_tokens"]) and nullable_counter?(p["output_tokens"]) and
        (p["usage_status"] != "reported" or
           (Stages.nonnegative?(p["input_tokens"]) and Stages.nonnegative?(p["output_tokens"]))) and
        (is_nil(p["error_code"]) or p["error_code"] in @errors)

    verdict(valid)
  end

  def validate_payload("result", p) do
    valid =
      keys?(p, @result) and Stages.identifier?(p["job_id"]) and
        p["state"] in ~w(completed cancelled failed unavailable stale reconcile_required) and
        counters?(p, ~w(generation receipt_count)) and
        hashes?(p, ~w(closure_digest receipt_digest)) and result?(p["result"])

    verdict(valid)
  end

  def validate_payload("context_page", p) do
    valid =
      keys?(p, @context_page) and
        ids?(
          p,
          ~w(job_id partition_id lease_id operation_manifest_ref context_id logical_call_id stage_id)
        ) and
        hashes?(p, ~w(operation_manifest_digest config_digest schema_digest)) and
        counters?(p, ~w(cancel_epoch semantic_generation authorization_generation page_index)) and
        p["phase"] in ~w(inputs derived attempt_bind) and
        p["seam_id"] in ~w(llm.context.v1 llm.messages.v1 embedder.input.v1 http.serialized.v1 graphiti.extract_nodes.v1 graphiti.resolve_nodes.v1 graphiti.extract_edges.v1 graphiti.attributes.v1 graphiti.summary_flight.v1 graphiti.summary_batch.v1 graphiti.temporal.v1 graphiti.save.v1 llm.response.v1 graphiti.bootstrap.v1 graphiti.search.v1) and
        p["transform_id"] in ~w(identity_v1 graphiti_builder_v1 official_openai_chat_v1 official_openai_embed_v1 native_jev_fit_v1 graphiti_extract_nodes_v1 graphiti_resolve_nodes_v1 graphiti_extract_edges_v1 graphiti_attribute_overlay_v1 graphiti_summary_flight_v1 graphiti_fact_append_v1 graphiti_temporal_v1 graphiti_save_v1 model_response_v1 root_inventory_bootstrap_v1 root_search_intent_v1 native_search_rrf_v1) and
        bounded?(p["prompt_name"], 200) and is_boolean(p["final"]) and
        nullable_hash?(p["previous_page_digest"]) and
        p["page_index"] == 0 == is_nil(p["previous_page_digest"]) and
        nullable_id?(p["base_context_ref"]) and nullable_hash?(p["base_context_digest"]) and
        is_nil(p["base_context_ref"]) == is_nil(p["base_context_digest"]) and
        is_list(p["parent_contexts"]) and length(p["parent_contexts"]) <= 100 and
        Enum.all?(
          p["parent_contexts"],
          &(keys?(&1, ~w(manifest_ref manifest_digest)) and
              Stages.identifier?(&1["manifest_ref"]) and Stages.digest?(&1["manifest_digest"]))
        ) and
        length(Enum.uniq_by(p["parent_contexts"], & &1["manifest_ref"])) ==
          length(p["parent_contexts"]) and
        nullable_hash?(p["raw_body_sha256"]) and nullable_hash?(p["rendered_projection_digest"]) and
        is_list(p["entries"]) and length(p["entries"]) in 1..100 and
        Enum.all?(p["entries"], &context_entry?/1) and
        length(Enum.uniq_by(p["entries"], & &1["entry_id"])) == length(p["entries"]) and
        context_binding?(p) and encoded_within?(p, @body) and rendered_within?(p["entries"])

    verdict(valid)
  end

  def validate_payload("context_ack", p) do
    valid =
      keys?(p, @context_ack) and ids?(p, ~w(job_id context_id)) and
        Stages.nonnegative?(p["page_index"]) and Stages.digest?(p["page_digest"]) and
        p["state"] in ~w(page_accepted sealed denied) and is_list(p["version_refs"]) and
        length(p["version_refs"]) <= 100 and
        Enum.all?(
          p["version_refs"],
          &(keys?(&1, ~w(entry_id version_ref)) and ids?(&1, ~w(entry_id version_ref)))
        ) and
        length(Enum.uniq_by(p["version_refs"], & &1["entry_id"])) == length(p["version_refs"]) and
        nullable_id?(p["context_manifest_ref"]) and nullable_hash?(p["context_manifest_digest"]) and
        nullable_hash?(p["allowed_body_sha256"]) and context_ack_binding?(p)

    verdict(valid)
  end

  def validate_payload(_, _), do: {:error, :invalid_dto}

  def context_page_digest(page), do: Contracts.digest(page)

  defp job_controls?(%{"op" => "health"} = p),
    do:
      is_nil(p["partition_id"]) and is_nil(p["lease_id"]) and p["scope_ref"] == "worker:health" and
        p["closure_ref"] == "source-lock" and p["semantic_generation"] == 0 and
        p["authorization_generation"] == 0 and p["cancel_epoch"] == 0 and p["deadline_ms"] <= 1000

  defp job_controls?(p), do: ids?(p, ~w(partition_id lease_id))

  defp context_entry?(p) do
    cap =
      case p["kind"] do
        "rendered_message" -> 49152
        kind when kind in ["episode", "embed_input"] -> 4096
        _ -> 16384
      end

    keys?(p, @context_entry) and ids?(p, ~w(entry_id object_id parent_manifest_ref)) and
      hashes?(p, ~w(value_hash projection_hash parent_manifest_digest)) and
      p["kind"] in ~w(episode summary attribute edge rendered_message embed_input deterministic_output) and
      p["projection_id"] in ~w(identity_v1 graphiti_context_v1 messages_v1 embed_text_v1 native_jev_fit_v1 native_loader_no_vector_v1) and
      nullable_id?(p["version_ref"]) and nullable_id?(p["predecessor_version_ref"]) and
      nullable_id?(p["receipt_ref"]) and
      canonical_value?(p["value"], cap, p["value_hash"]) and
      p["projection_hash"] == p["value_hash"]
  rescue
    _ -> false
  end

  defp context_binding?(%{"phase" => "attempt_bind"} = p),
    do:
      Stages.digest?(p["raw_body_sha256"]) and Stages.digest?(p["rendered_projection_digest"]) and
        Stages.identifier?(p["base_context_ref"])

  defp context_binding?(p), do: is_nil(p["raw_body_sha256"])

  defp context_ack_binding?(%{"state" => "sealed"} = p),
    do:
      Stages.identifier?(p["context_manifest_ref"]) and
        Stages.digest?(p["context_manifest_digest"]) and is_nil(p["error_code"])

  defp context_ack_binding?(p) do
    is_nil(p["context_manifest_ref"]) and is_nil(p["context_manifest_digest"]) and
      is_nil(p["allowed_body_sha256"]) and
      if(p["state"] == "denied",
        do: p["error_code"] in @errors and p["version_refs"] == [],
        else: is_nil(p["error_code"])
      )
  end

  defp canonical_value?(value, cap, hash) do
    bytes = Contracts.canonical_json(value)
    byte_size(bytes) <= cap and Contracts.sha256(bytes) == hash
  rescue
    _ -> false
  end

  defp encoded_within?(value, cap) do
    case Jason.encode(value) do
      {:ok, bytes} -> byte_size(bytes) <= cap
      _ -> false
    end
  end

  defp rendered_within?(entries),
    do:
      entries
      |> Enum.filter(&(&1["kind"] == "rendered_message"))
      |> Enum.reduce(0, &(byte_size(Contracts.canonical_json(&1["value"])) + &2)) <= 49152

  defp nullable_id?(nil), do: true
  defp nullable_id?(value), do: Stages.identifier?(value)
  defp nullable_hash?(nil), do: true
  defp nullable_hash?(value), do: Stages.digest?(value)

  defp args?("health", p), do: keys?(p, [])

  defp args?("ingest", p) do
    keys?(
      p,
      ~w(binding_id episode_uuid revision_id body_hash window_start window_end body reference_time time_basis prior_episode_ids)
    ) and
      ids?(p, ~w(binding_id episode_uuid revision_id)) and Stages.digest?(p["body_hash"]) and
      counters?(p, ~w(window_start window_end)) and bounded?(p["body"], 4096) and
      p["window_end"] - p["window_start"] == byte_size(p["body"]) and
      Contracts.sha256(p["body"]) == p["body_hash"] and bounded?(p["reference_time"], 100) and
      p["time_basis"] in ~w(event effective capture_fallback) and
      id_list?(p["prior_episode_ids"], 24)
  end

  defp args?("search", p),
    do:
      keys?(p, ~w(query limit recipe_id)) and bounded?(p["query"], 4096) and
        String.trim(p["query"]) != "" and Stages.integer_in?(p["limit"], 1, 100) and
        p["recipe_id"] == "edge_hybrid_rrf_v1"

  defp args?("remove", p),
    do:
      keys?(p, ~w(episode_uuid purge_fence_id rebuild_closure_ref)) and
        ids?(p, ~w(episode_uuid purge_fence_id rebuild_closure_ref))

  defp args?("cancel", p),
    do:
      keys?(p, ~w(target_job_id new_cancel_epoch)) and Stages.identifier?(p["target_job_id"]) and
        Stages.nonnegative?(p["new_cancel_epoch"])

  defp args?(_, _), do: false

  defp result?(%{"error_code" => code} = p), do: keys?(p, ["error_code"]) and code in @errors

  defp result?(%{"candidates" => candidates} = p),
    do:
      keys?(p, ["candidates"]) and is_list(candidates) and length(candidates) <= 100 and
        Enum.all?(candidates, &candidate?/1)

  defp result?(%{"binding_id" => _, "episode_uuid" => _} = p),
    do: keys?(p, ~w(binding_id episode_uuid)) and ids?(p, ~w(binding_id episode_uuid))

  defp result?(%{"cleanup_status" => status} = p),
    do:
      keys?(p, ~w(cleanup_status version_manifest_digest)) and status == "verification_required" and
        Stages.digest?(p["version_manifest_digest"])

  defp result?(%{"cancelled_job_id" => id} = p),
    do: keys?(p, ["cancelled_job_id"]) and Stages.identifier?(id)

  defp result?(%{"version" => version} = p),
    do:
      keys?(p, ~w(version source_lock_digest backend_pin_digest readiness)) and
        version == "0.31.2" and hashes?(p, ~w(source_lock_digest backend_pin_digest)) and
        p["readiness"] in ~w(configured stage_unavailable)

  defp result?(_), do: false

  defp candidate?(p),
    do:
      keys?(p, ~w(edge_id episode_ids score)) and Stages.identifier?(p["edge_id"]) and
        id_list?(p["episode_ids"], 100) and is_number(p["score"])

  defp keys?(p, keys),
    do: is_map(p) and not is_struct(p) and Enum.sort(Map.keys(p)) == Enum.sort(keys)

  defp ids?(p, keys), do: Enum.all?(keys, &Stages.identifier?(p[&1]))
  defp hashes?(p, keys), do: Enum.all?(keys, &Stages.digest?(p[&1]))
  defp counters?(p, keys), do: Enum.all?(keys, &Stages.nonnegative?(p[&1]))
  defp nullable_counter?(nil), do: true
  defp nullable_counter?(n), do: Stages.nonnegative?(n)

  defp bounded?(s, cap, empty \\ false),
    do: is_binary(s) and String.valid?(s) and byte_size(s) <= cap and (empty or byte_size(s) > 0)

  defp id_list?(values, cap),
    do:
      is_list(values) and length(values) <= cap and Enum.all?(values, &Stages.identifier?/1) and
        length(values) == length(Enum.uniq(values))

  defp verdict(true), do: :ok
  defp verdict(_), do: {:error, :invalid_dto}

  defp backend?(uri) when is_binary(uri) do
    p = URI.parse(uri)

    p.scheme == "bolt" and p.host in ["127.0.0.1", "::1", "neo4j"] and
      is_integer(p.port) and p.port in 1..65535 and p.path in [nil, "", "/"] and
      is_nil(p.userinfo) and is_nil(p.query) and is_nil(p.fragment)
  end

  defp backend?(_), do: false

  defp normalize(_, depth) when depth > 12, do: {:error, :invalid_frame}

  defp normalize(%Jason.OrderedObject{values: pairs}, depth) do
    keys = Enum.map(pairs, &elem(&1, 0))

    if length(keys) == length(Enum.uniq(keys)) do
      Enum.reduce_while(pairs, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
        case normalize(value, depth + 1) do
          {:ok, item} -> {:cont, {:ok, Map.put(acc, key, item)}}
          _ -> {:halt, {:error, :invalid_frame}}
        end
      end)
    else
      {:error, :invalid_frame}
    end
  end

  defp normalize(values, depth) when is_list(values) and length(values) <= 100 do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case normalize(value, depth + 1) do
        {:ok, item} -> {:cont, {:ok, [item | acc]}}
        _ -> {:halt, {:error, :invalid_frame}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp normalize(value, _)
       when is_binary(value) or is_integer(value) or is_float(value) or is_boolean(value) or
              is_nil(value),
       do: {:ok, value}

  defp normalize(_, _), do: {:error, :invalid_frame}
end
