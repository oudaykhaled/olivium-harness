defmodule HarnessForge.Graphiti.SchemaPolicy do
  @moduledoc "Closed native schema catalogue. Membership does not release graph operations."
  alias HarnessForge.{Contracts, Models.Stages}
  @root Path.expand("../../../priv/graphiti_worker", __DIR__)
  @catalogue_path Path.join(@root, "schema-catalogue.json")
  @source_path Path.join(@root, "source.lock.json")
  @dependency_path Path.join(@root, "dependencies.lock.json")
  @external_resource @catalogue_path
  @external_resource @source_path
  @external_resource @dependency_path
  @catalogue_digest @catalogue_path |> File.read!() |> Contracts.sha256()
  @source_digest @source_path |> File.read!() |> Contracts.sha256()
  @dependency_digest @dependency_path |> File.read!() |> Contracts.sha256()
  @stages ~w(extraction summary node_dedupe edge_dedupe embedder)
  @error {:error, :stage_unavailable}

  @bootstrap_schema Jason.decode!(
                      ~S'{"$id":"hf.graph.bootstrap.v1","items":{"additionalProperties":false,"properties":{"entry_id":{"format":"uuid","type":"string"},"kind":{"enum":["episode","deterministic_output","edge","summary","attribute"]},"object_id":{"type":"string"},"parent_manifest_digest":{"pattern":"^[0-9a-f]{64}$","type":"string"},"parent_manifest_ref":{"format":"uuid","type":"string"},"predecessor_version_ref":{"type":"null"},"projection_hash":{"pattern":"^[0-9a-f]{64}$","type":"string"},"projection_id":{"enum":["identity_v1","native_loader_no_vector_v1"]},"receipt_ref":{"type":"null"},"value":{},"value_hash":{"pattern":"^[0-9a-f]{64}$","type":"string"},"version_ref":{"type":"null"}},"required":["entry_id","kind","object_id","parent_manifest_digest","parent_manifest_ref","predecessor_version_ref","projection_hash","projection_id","receipt_ref","value","value_hash","version_ref"],"type":"object"},"maxItems":100,"minItems":1,"type":"array"}'
                    )
  @bootstrap_prompt_policy Jason.decode!(
                             ~S'{"format":"root-bootstrap-prompt-policy-v1","prompt_name":"graphiti.bootstrap.v1","provider_attempt":false,"stage":"extraction","transform_id":"root_inventory_bootstrap_v1"}'
                           )

  @search_schema Jason.decode!(
                   ~S'{"$id":"hf.graph.search.v1","oneOf":[{"additionalProperties":false,"properties":{"group_id":{"maxLength":200,"minLength":1,"type":"string"},"limit":{"maximum":10,"minimum":1,"type":"integer"},"query":{"maxLength":256,"minLength":1,"type":"string"},"recipe_id":{"enum":["edge_hybrid_rrf_v1"]}},"required":["query","limit","recipe_id","group_id"],"type":"object"},{"additionalProperties":false,"properties":{"candidates":{"items":{"additionalProperties":false,"properties":{"edge_id":{"format":"uuid","type":"string"},"episode_ids":{"items":{"format":"uuid","type":"string"},"maxItems":24,"minItems":1,"type":"array","uniqueItems":true},"score":{"additionalProperties":false,"properties":{"bits":{"pattern":"^[0-9a-f]{16}$","type":"string"},"format":{"enum":["ieee754-be-f64-v1"]}},"required":["format","bits"],"type":"object"}},"required":["edge_id","episode_ids","score"],"type":"object"},"maxItems":10,"minItems":0,"type":"array"}},"required":["candidates"],"type":"object"}]}'
                 )
  @search_prompt_policy Jason.decode!(
                          ~S'{"format":"root-search-prompt-policy-v1","input_transform_id":"root_search_intent_v1","prompt_name":"graphiti.search.v1","provider_attempt":false,"result_transform_id":"native_search_rrf_v1","stage":"embedder"}'
                        )

  def search_schema, do: @search_schema
  def search_schema_digest, do: Contracts.digest(@search_schema)
  def search_prompt_policy, do: @search_prompt_policy

  def bootstrap_schema, do: @bootstrap_schema
  def bootstrap_schema_digest, do: Contracts.digest(@bootstrap_schema)
  def bootstrap_prompt_policy, do: @bootstrap_prompt_policy

  def digest, do: @catalogue_digest

  # This identifies the stage's qualified native prompt policy. Exact upstream
  # prompt bytes and the exporter are additionally pinned in the runtime bundle.
  def prompt_policy_digest(stage) when stage in @stages do
    Contracts.digest(%{
      "format" => "graphiti-prompt-policy-v1",
      "stage" => stage,
      "route_id" => "graphiti_" <> stage,
      "catalogue_digest" => @catalogue_digest
    })
  end

  def catalogue do
    root = Application.app_dir(:harness_forge, "priv/graphiti_worker")
    catalogue_path = Path.join(root, "schema-catalogue.json")

    with {:ok, %{size: size, type: :regular}} <- File.lstat(catalogue_path),
         true <- size in 1..524_288,
         {:ok, bytes} <- File.read(catalogue_path),
         true <- Contracts.sha256(bytes) == @catalogue_digest,
         {:ok, source} <- File.read(Path.join(root, "source.lock.json")),
         {:ok, dependencies} <- File.read(Path.join(root, "dependencies.lock.json")),
         true <-
           Contracts.sha256(source) == @source_digest and
             Contracts.sha256(dependencies) == @dependency_digest,
         {:ok, value} <- Contracts.decode_json(bytes),
         true <-
           Contracts.canonical_json(value) == bytes and
             value["format"] == "graphiti-schema-catalogue-v1" and
             value["adapter_export_version"] == 1 and
             value["source_lock_digest"] == @source_digest and
             value["dependency_lock_digest"] == @dependency_digest and
             value["route_policy"]["catalogue_membership_releases_routes"] == false and
             value["route_policy"]["dynamic_schemas"] == "denied" and
             value["route_policy"]["unknown_prompts"] == "denied" do
      {:ok, value}
    else
      _ -> @error
    end
  rescue
    _ -> @error
  end

  def validate_pin(pin) do
    with {:ok, _} <- Stages.validate_pin(pin),
         true <- pin["stage"] in @stages and pin["route_id"] == "graphiti_" <> pin["stage"],
         true <-
           pin["schema_digest"] == @catalogue_digest and
             pin["prompt_digest"] == prompt_policy_digest(pin["stage"]),
         true <- compatible_provider?(pin),
         {:ok, _} <- catalogue(),
         do: :ok,
         else: (_ -> @error)
  end

  def entry(pin, prompt) do
    with :ok <- validate_pin(pin),
         {:ok, catalogue} <- catalogue(),
         [entry] <-
           Enum.filter(
             catalogue["entries"],
             &(&1["stage"] == pin["stage"] and &1["prompt_name"] == prompt)
           ),
         true <- entry["schema_digest"] == Contracts.digest(entry["schema"]) do
      {:ok, entry}
    else
      _ -> @error
    end
  end

  # This root validation seam is deliberately absent from provider entry/body
  # routing. A bootstrap ACK confers no physical-send capability.
  def validate_context(pin, %{"prompt_name" => "graphiti.bootstrap.v1"} = context) do
    wire? =
      is_nil(context["graph_kind"]) and context["phase"] == "inputs" and
        context["transform_id"] == "root_inventory_bootstrap_v1" and
        context["base_context_ref"] == nil and context["base_context_digest"] == nil and
        context["parent_contexts"] == [] and context["page_index"] == 0 and
        context["final"] == true and
        is_nil(context["previous_page_digest"]) and
        Stages.digest?(context["rendered_projection_digest"])

    inputs? =
      context["graph_kind"] == "inputs" and is_nil(context["transform_id"]) and
        is_nil(context["base_context_ref"]) and is_nil(context["base_context_digest"])

    derived? =
      context["graph_kind"] == "derived" and
        context["transform_id"] == "root_inventory_bootstrap_v1" and
        HarnessForge.Evidence.Corpora.uuid?(context["base_context_ref"]) and
        Stages.digest?(context["base_context_digest"])

    with :ok <- validate_pin(pin),
         true <- pin["stage"] == "extraction" and (wire? or inputs? or derived?),
         true <-
           context["stage_id"] == pin["id"] and context["config_digest"] == pin["config_digest"],
         true <-
           context["seam_id"] == "graphiti.bootstrap.v1" and
             context["schema_digest"] == bootstrap_schema_digest(),
         true <-
           Enum.all?(
             ~w(receipt_ref receipt_digest raw_body_sha256 rendered_projection_digest),
             fn key ->
               is_nil(context[key]) or
                 (wire? and key == "rendered_projection_digest" and Stages.digest?(context[key]))
             end
           ),
         do: :ok,
         else: (_ -> @error)
  end

  # A closed query observation has no provider-entry or physical-send route.
  def validate_context(pin, %{"prompt_name" => "graphiti.search.v1"} = context) do
    wire? = is_nil(context["graph_kind"])

    inputs? =
      (wire? and context["phase"] == "inputs" and
         context["transform_id"] == "root_search_intent_v1") or
        (context["graph_kind"] == "inputs" and is_nil(context["transform_id"]))

    derived? =
      (wire? and context["phase"] == "derived" and
         context["transform_id"] == "native_search_rrf_v1") or
        (context["graph_kind"] == "derived" and
           context["transform_id"] in ~w(native_search_rrf_v1 root_search_intent_v1))

    empty_base? = is_nil(context["base_context_ref"]) and is_nil(context["base_context_digest"])

    bound_base? =
      HarnessForge.Evidence.Corpora.uuid?(context["base_context_ref"]) and
        Stages.digest?(context["base_context_digest"])

    base? =
      cond do
        wire? and inputs? -> empty_base?
        inputs? -> empty_base? or bound_base?
        true -> bound_base?
      end

    with :ok <- validate_pin(pin),
         true <- pin["stage"] == "embedder" and (inputs? or derived?) and base?,
         true <-
           context["stage_id"] == pin["id"] and context["config_digest"] == pin["config_digest"],
         true <-
           context["seam_id"] == "graphiti.search.v1" and
             context["schema_digest"] == search_schema_digest(),
         true <-
           is_nil(context["receipt_ref"]) and is_nil(context["receipt_digest"]) and
             is_nil(context["raw_body_sha256"]),
         true <-
           if(wire?,
             do:
               context["page_index"] == 0 and context["final"] == true and
                 is_nil(context["previous_page_digest"]) and
                 Stages.digest?(context["rendered_projection_digest"]),
             else: is_nil(context["rendered_projection_digest"])
           ),
         do: :ok,
         else: (_ -> @error)
  end

  def validate_context(pin, context) do
    with true <-
           context["stage_id"] == pin["id"] and context["config_digest"] == pin["config_digest"],
         {:ok, entry} <- entry(pin, context["prompt_name"]),
         true <-
           context["schema_digest"] == entry["schema_digest"] and
             context["seam_id"] in entry["allowed_seams"],
         true <-
           (context["graph_kind"] == "inputs" and is_nil(context["transform_id"])) or
             context["transform_id"] in entry["transforms"],
         do: :ok,
         else: (_ -> @error)
  end

  @doc "Validate actual serialized bytes and their measured ordered projections; dispatch preserves bytes."
  def validate_body(pin, prompt, raw, projections) when is_binary(raw) and is_list(projections) do
    with true <- byte_size(raw) in 1..98_304,
         {:ok, entry} <- entry(pin, prompt),
         profile when is_map(profile) <- entry["physical_profile"],
         true <-
           pin["provider"] in profile["providers"] and
             String.ends_with?(pin["endpoint"], profile["endpoint_suffix"]),
         {:ok, body} <- strict_body(raw),
         true <-
           is_map(body) and body["model"] == pin["model"] and
             Enum.sort(Map.keys(body)) == Enum.sort(profile["required_keys"]),
         :ok <- physical(profile["id"], body, profile, pin, projections),
         do: :ok,
         else: (_ -> @error)
  rescue
    _ -> @error
  end

  def validate_body(_, _, _, _), do: @error

  defp physical("openai_chat_completions_v1", body, profile, pin, projections) do
    if body["messages"] == projections and length(projections) in 1..100 and
         body["temperature"] == profile["temperature"] and
         Stages.integer_in?(body["max_tokens"], 1, pin["max_output_tokens"]) and
         body["response_format"] == profile["response_format"], do: :ok, else: @error
  end

  defp physical("native_jev_systemone_v1", body, _profile, _pin, [projection]) do
    if projection == Map.take(body, ~w(state questions)) and is_map(body["questions"]) and
         map_size(body["questions"]) in 1..100, do: :ok, else: @error
  end

  defp physical("openai_embeddings_sdk_v1", body, profile, _pin, [projection]) do
    if body["input"] == projection and body["encoding_format"] == profile["encoding_format"],
      do: :ok,
      else: @error
  end

  defp physical(_, _, _, _, _), do: @error

  defp compatible_provider?(%{"stage" => stage, "provider" => provider}) do
    if stage in ~w(node_dedupe edge_dedupe),
      do: provider == "jev",
      else: provider in ~w(ollama openai)
  end

  # Physical SDK JSON may contain a finite temperature float. Canonical graph
  # values never do. Reject duplicate keys before decoding to maps, and retain
  # raw request bytes for the body hash and actual dispatch.
  defp strict_body(raw) do
    with {:ok, ordered} <- Jason.decode(raw, objects: :ordered_objects), do: normalize(ordered, 0)
  end

  defp normalize(_, depth) when depth > 20, do: @error

  defp normalize(%Jason.OrderedObject{values: pairs}, depth) when length(pairs) <= 100 do
    if length(Enum.uniq_by(pairs, &elem(&1, 0))) == length(pairs) do
      Enum.reduce_while(pairs, {:ok, %{}}, fn {key, value}, {:ok, result} ->
        case normalize(value, depth + 1) do
          {:ok, value} -> {:cont, {:ok, Map.put(result, key, value)}}
          _ -> {:halt, @error}
        end
      end)
    else
      @error
    end
  end

  defp normalize(values, depth) when is_list(values) and length(values) <= 100 do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, result} ->
      case normalize(value, depth + 1) do
        {:ok, value} -> {:cont, {:ok, [value | result]}}
        _ -> {:halt, @error}
      end
    end)
    |> case do
      {:ok, result} -> {:ok, Enum.reverse(result)}
      error -> error
    end
  end

  defp normalize(value, _)
       when is_binary(value) or is_integer(value) or is_boolean(value) or is_nil(value),
       do: {:ok, value}

  defp normalize(value, _) when is_float(value) do
    if value >= -1.0e308 and value <= 1.0e308, do: {:ok, value}, else: @error
  end

  defp normalize(_, _), do: @error
end
