defmodule HarnessForge.Graphiti.ObservationFlow do
  @moduledoc """
  Pure, bounded sequencing for one observed logical call.

  Root calls `check/2` before independently validating and sealing a page, then
  `record/3` with its sealed handle. A successful check grants no authority and
  verifies neither source values, transformations, receipts nor schema policy.
  State contains no entries, messages, response bodies or native object values.
  Its string keys survive JSON persistence without allocating dynamic atoms.
  """

  alias HarnessForge.Models.Stages

  @error {:error, :closure_incomplete}
  @format "graph-observation-flow-v1"
  @identity ~w(stage_id config_digest schema_digest prompt_name logical_call_id)
  @page ~w(context_id page_index previous_page_digest final entries parent_contexts base_context_ref base_context_digest phase seam_id transform_id raw_body_sha256 rendered_projection_digest)
  @state ~w(format family identity native_seam native_transform base pending_bind responses step finished last_context_id)
  @handle ~w(manifest_ref manifest_digest)
  @native %{
    "graphiti.extract_nodes.v1" => "graphiti_extract_nodes_v1",
    "graphiti.resolve_nodes.v1" => "graphiti_resolve_nodes_v1",
    "graphiti.extract_edges.v1" => "graphiti_extract_edges_v1",
    "graphiti.attributes.v1" => "graphiti_attribute_overlay_v1",
    "graphiti.summary_flight.v1" => "graphiti_summary_flight_v1",
    "graphiti.summary_batch.v1" => "graphiti_fact_append_v1",
    "graphiti.temporal.v1" => "graphiti_temporal_v1",
    "graphiti.save.v1" => "graphiti_save_v1"
  }

  @type state :: %{String.t() => term()}
  @type handle :: %{String.t() => String.t()}
  @type error :: {:error, :closure_incomplete}

  @spec check(state() | nil, map()) :: :ok | error()
  def check(state, page) do
    with true <- page_shape?(page),
         {:ok, event} <- event(page),
         true <- allowed?(state, page, event) do
      :ok
    else
      _ -> @error
    end
  end

  @spec record(state() | nil, map(), handle()) :: {:ok, state()} | error()
  def record(state, page, handle) do
    with :ok <- check(state, page),
         true <- handle?(handle) and fresh_handle?(state, handle),
         {:ok, event} <- event(page) do
      state = state || initial(page, event)
      {:ok, advance(state, page, event, handle)}
    else
      _ -> @error
    end
  end

  defp page_shape?(page) when is_map(page) and not is_struct(page) do
    Enum.all?(@page, &Map.has_key?(page, &1)) and identity?(Map.take(page, @identity)) and
      Stages.identifier?(page["context_id"]) and
      page["page_index"] === 0 and page["previous_page_digest"] === nil and
      page["final"] === true and
      is_list(page["entries"]) and length(page["entries"]) in 1..100 and
      Enum.all?(page["entries"], &(is_map(&1) and not is_struct(&1))) and
      handles?(page["parent_contexts"], 100) and
      base_pair?(page["base_context_ref"], page["base_context_digest"])
  end

  defp page_shape?(_), do: false

  defp event(%{"phase" => "inputs", "seam_id" => "llm.context.v1"} = page) do
    event_if(
      page["transform_id"] == "graphiti_builder_v1" and
        entries?(page, "deterministic_output", "graphiti_context_v1", 1),
      :model_inputs
    )
  end

  defp event(%{"phase" => "inputs", "seam_id" => "graphiti.bootstrap.v1"} = page) do
    event_if(
      page["transform_id"] == "root_inventory_bootstrap_v1" and
        page["parent_contexts"] == [] and is_nil(page["raw_body_sha256"]) and
        Enum.all?(
          page["entries"],
          &(is_nil(&1["receipt_ref"]) and is_nil(&1["version_ref"]) and
              is_nil(&1["predecessor_version_ref"]))
        ),
      :bootstrap
    )
  end

  defp event(%{"seam_id" => "graphiti.search.v1", "phase" => phase} = page)
       when phase in ~w(inputs derived) do
    expected = if phase == "inputs", do: "root_search_intent_v1", else: "native_search_rrf_v1"

    with {:ok, _} <- native_detail(page) do
      event_if(
        length(page["entries"]) == 1 and page["transform_id"] == expected and
          is_nil(page["raw_body_sha256"]),
        if(phase == "inputs", do: :search_inputs, else: :search_final)
      )
    end
  end

  defp event(%{"phase" => "inputs", "seam_id" => "llm.messages.v1"} = page) do
    event_if(
      page["transform_id"] == "graphiti_builder_v1" and
        entries?(page, "rendered_message", "messages_v1", 100),
      :messages
    )
  end

  defp event(%{"phase" => "inputs", "seam_id" => "embedder.input.v1"} = page) do
    event_if(
      page["transform_id"] == "identity_v1" and entries?(page, "embed_input", "embed_text_v1", 1),
      :embed_inputs
    )
  end

  defp event(%{"phase" => "attempt_bind", "seam_id" => "http.serialized.v1"} = page) do
    cond do
      not Stages.digest?(page["raw_body_sha256"]) or
          not Stages.digest?(page["rendered_projection_digest"]) ->
        @error

      page["transform_id"] == "official_openai_embed_v1" and
          entries?(page, "embed_input", "embed_text_v1", 1) ->
        {:ok, :embed_bind}

      page["transform_id"] == "official_openai_chat_v1" and
          entries?(page, "rendered_message", "messages_v1", 100) ->
        {:ok, :model_bind}

      page["transform_id"] == "native_jev_fit_v1" and
          entries?(page, "rendered_message", "native_jev_fit_v1", 1) ->
        {:ok, :model_bind}

      true ->
        @error
    end
  end

  defp event(%{"phase" => "derived", "seam_id" => "llm.response.v1"} = page) do
    case page["entries"] do
      [
        %{
          "kind" => "deterministic_output",
          "projection_id" => "identity_v1",
          "receipt_ref" => receipt
        }
      ]
      when is_nil(receipt) or is_binary(receipt) ->
        event_if(
          page["transform_id"] == "model_response_v1" and
            (is_nil(receipt) or Stages.identifier?(receipt)),
          if(is_nil(receipt), do: :logical_response, else: :physical_response)
        )

      _ ->
        @error
    end
  end

  defp event(%{"seam_id" => seam} = page) when is_map_key(@native, seam) do
    with true <- page["transform_id"] == @native[seam],
         true <- Enum.all?(page["entries"], &(&1["receipt_ref"] === nil)),
         {:ok, detail} <- native_detail(page) do
      case {page["phase"], Enum.sort(Map.keys(detail))} do
        {"inputs", ["arguments"]} -> {:ok, :native_inputs}
        {"derived", ["after", "before"]} -> {:ok, :checkpoint}
        {"derived", ["after", "before", "result"]} -> {:ok, :native_final}
        {"derived", ["temporal_context"]} -> {:ok, :temporal_final}
        _ -> @error
      end
    else
      _ -> @error
    end
  end

  defp event(_), do: @error
  defp event_if(true, event), do: {:ok, event}
  defp event_if(_, _), do: @error

  defp entries?(page, kind, projection, limit) do
    length(page["entries"]) <= limit and
      Enum.all?(page["entries"], fn entry ->
        entry["kind"] == kind and entry["projection_id"] == projection and
          Map.has_key?(entry, "receipt_ref") and entry["receipt_ref"] === nil
      end)
  end

  defp native_detail(page) do
    case Enum.filter(page["entries"], fn entry ->
           entry["kind"] == "deterministic_output" and
             entry["object_id"] == page["logical_call_id"]
         end) do
      [%{"value" => value, "projection_id" => "identity_v1", "receipt_ref" => nil}]
      when is_map(value) and not is_struct(value) ->
        {:ok, value}

      _ ->
        @error
    end
  end

  defp allowed?(nil, page, event) do
    is_nil(base(page)) and
      (event in [:model_inputs, :embed_inputs, :native_inputs, :bootstrap, :search_inputs] or
         (event == :checkpoint and page["seam_id"] == "graphiti.temporal.v1" and
            page["parent_contexts"] != [] and length(page["entries"]) == 1))
  end

  defp allowed?(state, page, event) do
    state?(state) and not state["finished"] and
      state["identity"] == Map.take(page, @identity) and
      state["last_context_id"] != page["context_id"] and
      base(page) == state["base"] and next?(state, page, event)
  end

  defp next?(%{"family" => "model", "step" => "inputs"}, _page, :messages), do: true

  defp next?(%{"family" => "search", "step" => "search"}, _page, :search_final), do: true

  defp next?(%{"family" => "model", "step" => step} = state, _page, :model_bind)
       when step in ~w(messages response),
       do: length(state["responses"]) < 3

  defp next?(%{"family" => "embed", "step" => step} = state, _page, :embed_bind)
       when step in ~w(inputs response),
       do: length(state["responses"]) < 3

  defp next?(%{"family" => family, "step" => "bound"} = state, page, :physical_response)
       when family in ~w(model embed),
       do:
         length(state["responses"]) < 3 and
           same_parents?(page["parent_contexts"], [state["pending_bind"] | state["responses"]])

  defp next?(%{"family" => family, "step" => "response"} = state, page, :logical_response)
       when family in ~w(model embed),
       do: same_parents?(page["parent_contexts"], state["responses"])

  defp next?(%{"family" => "native", "step" => "native"} = state, page, event)
       when event in [:checkpoint, :native_final] do
    same_native?(state, page) and
      (event == :native_final or state["native_seam"] == "graphiti.summary_batch.v1")
  end

  defp next?(%{"family" => "native", "step" => "temporal"} = state, page, :temporal_final) do
    with true <- same_native?(state, page),
         {:ok, detail} <- native_detail(page) do
      detail["temporal_context"] == state["base"]["manifest_ref"] and
        state["base"] in page["parent_contexts"]
    else
      _ -> false
    end
  end

  defp next?(_, _, _), do: false

  defp initial(page, event) do
    native? = event in [:native_inputs, :checkpoint]

    family =
      cond do
        event == :search_inputs -> "search"
        event == :bootstrap -> "bootstrap"
        native? -> "native"
        event == :embed_inputs -> "embed"
        true -> "model"
      end

    %{
      "format" => @format,
      "family" => family,
      "identity" => Map.take(page, @identity),
      "native_seam" => if(native?, do: page["seam_id"]),
      "native_transform" => if(native?, do: page["transform_id"]),
      "base" => nil,
      "pending_bind" => nil,
      "responses" => [],
      "step" => "inputs",
      "finished" => false,
      "last_context_id" => nil
    }
  end

  defp advance(state, page, event, handle) do
    state = Map.put(state, "last_context_id", page["context_id"])

    case event do
      event when event in [:model_inputs, :embed_inputs] ->
        Map.merge(state, %{"base" => handle, "step" => "inputs"})

      :messages ->
        Map.merge(state, %{"base" => handle, "step" => "messages"})

      event when event in [:model_bind, :embed_bind] ->
        Map.merge(state, %{"pending_bind" => handle, "step" => "bound"})

      :physical_response ->
        Map.merge(state, %{
          "base" => handle,
          "pending_bind" => nil,
          "responses" => state["responses"] ++ [handle],
          "step" => "response"
        })

      event
      when event in [:logical_response, :native_final, :temporal_final, :bootstrap, :search_final] ->
        Map.merge(state, %{"base" => handle, "step" => "finished", "finished" => true})

      :native_inputs ->
        Map.merge(state, %{"base" => handle, "step" => "native"})

      :search_inputs ->
        Map.merge(state, %{"base" => handle, "step" => "search"})

      :checkpoint ->
        step = if(state["native_seam"] == "graphiti.temporal.v1", do: "temporal", else: "native")
        Map.merge(state, %{"base" => handle, "step" => step})
    end
  end

  defp same_native?(state, page),
    do:
      state["native_seam"] == page["seam_id"] and
        state["native_transform"] == page["transform_id"]

  defp state?(state) when is_map(state) and not is_struct(state) do
    keys?(state, @state) and state["format"] == @format and identity?(state["identity"]) and
      handle?(state["base"]) and nullable_handle?(state["pending_bind"]) and
      handles?(state["responses"], 3) and Stages.identifier?(state["last_context_id"]) and
      is_boolean(state["finished"]) and
      state["finished"] == (state["step"] == "finished") and state_phase?(state)
  end

  defp state?(_), do: false

  defp state_phase?(%{"family" => "native"} = state) do
    Map.get(@native, state["native_seam"]) == state["native_transform"] and
      not is_nil(state["native_transform"]) and state["responses"] == [] and
      is_nil(state["pending_bind"]) and
      (state["step"] in ~w(native finished) or
         (state["step"] == "temporal" and state["native_seam"] == "graphiti.temporal.v1"))
  end

  defp state_phase?(%{"family" => "bootstrap"} = state),
    do:
      state["step"] == "finished" and state["finished"] and is_nil(state["native_seam"]) and
        is_nil(state["native_transform"]) and is_nil(state["pending_bind"]) and
        state["responses"] == []

  defp state_phase?(%{"family" => "search"} = state),
    do:
      state["step"] in ~w(search finished) and is_nil(state["native_seam"]) and
        is_nil(state["native_transform"]) and is_nil(state["pending_bind"]) and
        state["responses"] == []

  defp state_phase?(%{"family" => family} = state) when family in ~w(model embed) do
    is_nil(state["native_seam"]) and is_nil(state["native_transform"]) and
      case state["step"] do
        "inputs" ->
          state["responses"] == [] and is_nil(state["pending_bind"])

        "messages" ->
          family == "model" and state["responses"] == [] and is_nil(state["pending_bind"])

        "bound" ->
          handle?(state["pending_bind"]) and length(state["responses"]) < 3 and
            response_base?(state)

        "response" ->
          state["responses"] != [] and is_nil(state["pending_bind"]) and response_base?(state)

        "finished" ->
          state["responses"] != [] and is_nil(state["pending_bind"])

        _ ->
          false
      end
  end

  defp state_phase?(_), do: false

  defp response_base?(%{"responses" => []}), do: true
  defp response_base?(state), do: state["base"] == List.last(state["responses"])

  defp identity?(identity) when is_map(identity) and not is_struct(identity) do
    keys?(identity, @identity) and
      Enum.all?(~w(stage_id logical_call_id), &Stages.identifier?(identity[&1])) and
      Enum.all?(~w(config_digest schema_digest), &Stages.digest?(identity[&1])) and
      is_binary(identity["prompt_name"]) and byte_size(identity["prompt_name"]) in 1..200 and
      String.valid?(identity["prompt_name"])
  end

  defp identity?(_), do: false

  defp base(page) do
    if is_nil(page["base_context_ref"]),
      do: nil,
      else: %{
        "manifest_ref" => page["base_context_ref"],
        "manifest_digest" => page["base_context_digest"]
      }
  end

  defp base_pair?(nil, nil), do: true
  defp base_pair?(ref, digest), do: handle?(%{"manifest_ref" => ref, "manifest_digest" => digest})

  defp handle?(handle) when is_map(handle) and not is_struct(handle),
    do:
      keys?(handle, @handle) and uuid?(handle["manifest_ref"]) and
        Stages.digest?(handle["manifest_digest"])

  defp handle?(_), do: false
  defp nullable_handle?(nil), do: true
  defp nullable_handle?(handle), do: handle?(handle)

  defp handles?(handles, limit) when is_list(handles) do
    length(handles) <= limit and Enum.all?(handles, &handle?/1) and
      length(Enum.uniq_by(handles, & &1["manifest_ref"])) == length(handles)
  end

  defp handles?(_, _), do: false
  defp same_parents?(actual, expected), do: MapSet.new(actual) == MapSet.new(expected)
  defp fresh_handle?(nil, _handle), do: true

  defp fresh_handle?(state, handle),
    do:
      Enum.all?([state["base"], state["pending_bind"] | state["responses"]], fn existing ->
        is_nil(existing) or existing["manifest_ref"] != handle["manifest_ref"]
      end)

  defp keys?(map, keys), do: Enum.sort(Map.keys(map)) == Enum.sort(keys)

  defp uuid?(id),
    do: is_binary(id) and byte_size(id) == 36 and match?({:ok, _}, Ecto.UUID.cast(id))
end
