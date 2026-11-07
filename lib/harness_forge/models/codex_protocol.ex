defmodule HarnessForge.Models.CodexProtocol do
  @moduledoc """
  Bounded admission and verification of Ollama 0.40.14 native Responses.

  No tools execute here and no successful event is synthesized. Complete SSE
  bytes are returned unchanged only after event, tool and usage validation.
  Tool schemas originate in trusted preflight, never in the inbound request.
  """
  alias HarnessForge.Contracts
  alias HarnessForge.Execution.CodexCommandPolicy
  @body_limit 131_072
  @response_limit 262_144
  @event_limit 131_072
  @event_count 4096
  @fields ~w(model input instructions max_output_tokens stream store tools tool_choice temperature top_p reasoning text truncation parallel_tool_calls background include prompt_cache_key client_metadata)
  @response_fields ~w(id object created_at completed_at status incomplete_details model previous_response_id instructions output error tools tool_choice truncation parallel_tool_calls text top_p presence_penalty frequency_penalty top_logprobs temperature reasoning usage max_output_tokens max_tool_calls store background service_tier metadata safety_identifier prompt_cache_key)

  def body_limit, do: @body_limit

  def limits,
    do: %{
      "request_bytes" => @body_limit,
      "response_bytes" => @response_limit,
      "event_bytes" => @event_limit,
      "events" => @event_count,
      "input_items" => 128,
      "tools" => 32
    }

  def tool_scope(tools) when is_list(tools) and length(tools) <= 32 do
    with {:ok, names} <- tool_names(tools),
         true <- length(names) <= 32 and length(Enum.uniq(names)) == length(names),
         true <- byte_size(Jason.encode!(tools)) <= 65_536 do
      {:ok, tools}
    else
      _ -> {:error, :invalid_codex_tools}
    end
  rescue
    _ -> {:error, :invalid_codex_tools}
  end

  def tool_scope(_), do: {:error, :invalid_codex_tools}

  def request(body, scope) when is_map(body) do
    output = body["max_output_tokens"] || scope.max_output_tokens
    tools = body["tools"] || []

    with true <- byte_size(Jason.encode!(body)) <= @body_limit and keys?(body, @fields),
         true <- body["model"] == scope.config["model"],
         true <- body["stream"] == true and body["store"] == false,
         true <- is_integer(output) and output in 1..scope.max_output_tokens,
         true <- body["tool_choice"] in [nil, "auto"],
         true <- body["parallel_tool_calls"] in [nil, true],
         true <-
           body["background"] in [nil, false] and
             body["include"] in [nil, [], ["reasoning.encrypted_content"]],
         :ok <- native_metadata(body, Map.get(scope, :native_commands, false)),
         true <- body["truncation"] in [nil, "disabled"],
         true <- text?(body["instructions"], true),
         true <- number_in?(body["temperature"], 0, 2) and number_in?(body["top_p"], 0, 1),
         true <- body["text"] in [nil, %{"format" => %{"type" => "text"}}],
         true <- reasoning?(body["reasoning"]),
         {:ok, _} <- tool_scope(tools),
         true <-
           Enum.all?(tools, fn tool ->
             Enum.any?(
               scope.codex_tools,
               &(Contracts.canonical_json(&1) == Contracts.canonical_json(tool))
             )
           end),
         {:ok, offered} <- tool_names(tools),
         :ok <- input(body["input"], offered),
         payload = Map.put(body, "max_output_tokens", output),
         true <- byte_size(Jason.encode!(payload)) <= @body_limit do
      {:ok, payload}
    else
      _ -> {:error, :invalid_runtime_request}
    end
  rescue
    _ -> {:error, :invalid_runtime_request}
  end

  def request(_, _), do: {:error, :invalid_runtime_request}

  def response(%{"status" => 200, "content_type" => [content_type], "body" => bytes}, payload)
      when is_binary(content_type) and is_binary(bytes) and byte_size(bytes) <= @response_limit do
    with true <- hd(String.split(content_type, ";")) == "text/event-stream",
         {:ok, offered} <- tool_names(payload["tools"] || []),
         {:ok, events} <- events(bytes),
         {:ok, state} <- consume(events, payload, offered),
         true <- state.phase == :completed do
      {:ok,
       %{
         input_tokens: state.usage["input_tokens"],
         output_tokens: state.usage["output_tokens"],
         response_id: state.id,
         function_calls:
           state.items
           |> Enum.sort_by(&elem(&1, 0))
           |> Enum.map(fn {_, entry} -> entry.final end)
           |> Enum.filter(&(&1["type"] == "function_call")),
         bytes: bytes
       }}
    else
      _ -> {:error, :invalid_runtime_response}
    end
  rescue
    _ -> {:error, :invalid_runtime_response}
  end

  def response(_, _), do: {:error, :invalid_runtime_response}

  defp native_metadata(body, required?) do
    if required? or Map.has_key?(body, "client_metadata") or
         Map.has_key?(body, "prompt_cache_key") do
      case CodexCommandPolicy.metadata(body) do
        {:ok, _} -> :ok
        _ -> {:error, :invalid_runtime_request}
      end
    else
      :ok
    end
  end

  defp tool_names(tools) do
    Enum.reduce_while(tools, {:ok, []}, fn tool, {:ok, names} ->
      case tool do
        %{"type" => "namespace", "name" => namespace, "tools" => members} ->
          if keys?(tool, ~w(type name description tools)) and name?(namespace) and
               text?(tool["description"], true) and is_list(members) and length(members) in 1..32 do
            case functions(members, namespace) do
              {:ok, found} -> {:cont, {:ok, names ++ found}}
              _ -> {:halt, {:error, :invalid_codex_tools}}
            end
          else
            {:halt, {:error, :invalid_codex_tools}}
          end

        %{"type" => "function"} ->
          case functions([tool], nil) do
            {:ok, found} -> {:cont, {:ok, names ++ found}}
            _ -> {:halt, {:error, :invalid_codex_tools}}
          end

        _ ->
          {:halt, {:error, :invalid_codex_tools}}
      end
    end)
  end

  defp functions(tools, namespace) do
    if Enum.all?(tools, fn
         %{"type" => "function", "name" => name, "parameters" => params} = tool ->
           keys?(tool, ~w(type name description parameters strict)) and name?(name) and
             name not in ["web_search", "tool_search"] and is_map(params) and
             params["type"] == "object" and json_depth?(params, 0) and
             text?(tool["description"], true) and tool["strict"] in [nil, true, false]

         _ ->
           false
       end),
       do: {:ok, Enum.map(tools, &{namespace, &1["name"]})},
       else: {:error, :invalid_codex_tools}
  end

  defp input(value, _) when is_binary(value) and byte_size(value) > 0, do: :ok

  defp input(items, offered) when is_list(items) and length(items) in 1..128 do
    Enum.reduce_while(items, {:ok, %{}, MapSet.new()}, fn item, {:ok, calls, results} ->
      case input_item(item, offered, calls, results) do
        {:ok, next_calls, next_results} -> {:cont, {:ok, next_calls, next_results}}
        _ -> {:halt, {:error, :invalid_input}}
      end
    end)
    |> case do
      {:ok, calls, results} ->
        if map_size(calls) == MapSet.size(results), do: :ok, else: {:error, :unresolved_tool_call}

      error ->
        error
    end
  end

  defp input(_, _), do: {:error, :invalid_input}

  defp input_item(%{"role" => role, "content" => content} = item, _, calls, results)
       when role in ["system", "developer", "user", "assistant"] do
    if keys?(item, ~w(type role content id status)) and item["type"] in [nil, "message"] and
         optional_id?(item["id"]) and item["status"] in [nil, "completed"] and
         input_content?(content, role), do: {:ok, calls, results}, else: :error
  end

  defp input_item(
         %{"type" => "function_call", "call_id" => id, "name" => name, "arguments" => args} = item,
         offered,
         calls,
         results
       ) do
    key = {item["namespace"], name}

    if keys?(item, ~w(type id call_id name namespace arguments status)) and identifier?(id) and
         optional_id?(item["id"]) and key in offered and not Map.has_key?(calls, id) and
         json_object?(args) and item["status"] in [nil, "completed"],
       do: {:ok, Map.put(calls, id, key), results},
       else: :error
  end

  defp input_item(
         %{"type" => "function_call_output", "call_id" => id, "output" => output} = item,
         _,
         calls,
         results
       ) do
    expected = calls[id]

    if keys?(item, ~w(type id call_id name namespace output)) and optional_id?(item["id"]) and
         not is_nil(expected) and not MapSet.member?(results, id) and
         (is_nil(item["name"]) or {item["namespace"], item["name"]} == expected) and
         (is_nil(item["namespace"]) or elem(expected, 0) == item["namespace"]) and
         (is_binary(output) or input_content?(output, "user")),
       do: {:ok, calls, MapSet.put(results, id)},
       else: :error
  end

  defp input_item(%{"type" => "reasoning", "summary" => summary} = item, _, calls, results) do
    if keys?(item, ~w(type id summary encrypted_content)) and optional_id?(item["id"]) and
         summary?(summary) and
         (is_nil(item["encrypted_content"]) or
            item["encrypted_content"] == Enum.map_join(summary, "", & &1["text"])),
       do: {:ok, calls, results},
       else: :error
  end

  defp input_item(_, _, _, _), do: :error

  defp input_content?(content, _) when is_binary(content), do: true

  defp input_content?(content, role) when is_list(content) and length(content) in 1..32 do
    Enum.all?(content, fn
      %{"type" => type, "text" => text} = part ->
        keys?(part, ~w(type text)) and is_binary(text) and
          (type == "input_text" or (type == "output_text" and role == "assistant"))

      _ ->
        false
    end)
  end

  defp input_content?(_, _), do: false

  defp reasoning?(nil), do: true

  defp reasoning?(value) when is_map(value) do
    keys?(value, ~w(effort summary)) and
      value["effort"] in [nil, "none", "minimal", "low", "medium", "high"] and
      value["summary"] in [nil, "auto", "concise", "detailed"]
  end

  defp reasoning?(_), do: false

  defp events(bytes) do
    normalized = String.replace(bytes, "\r\n", "\n")
    chunks = String.split(normalized, "\n\n")

    with true <- String.valid?(bytes) and List.last(chunks) == "",
         frames = Enum.drop(chunks, -1),
         true <- length(frames) in 3..@event_count do
      Enum.reduce_while(Enum.with_index(frames), {:ok, []}, fn {frame, index}, {:ok, acc} ->
        with true <- byte_size(frame) <= @event_limit,
             ["event: " <> event, "data: " <> data] <- String.split(frame, "\n"),
             {:ok, %{"type" => ^event, "sequence_number" => ^index} = value} <- Jason.decode(data) do
          {:cont, {:ok, [value | acc]}}
        else
          _ -> {:halt, {:error, :invalid_sse}}
        end
      end)
      |> case do
        {:ok, found} -> {:ok, Enum.reverse(found)}
        error -> error
      end
    else
      _ -> {:error, :invalid_sse}
    end
  end

  defp consume(events, payload, offered) do
    initial = %{
      phase: :new,
      id: nil,
      items: %{},
      ids: MapSet.new(),
      call_ids: MapSet.new(),
      usage: nil
    }

    Enum.reduce_while(events, {:ok, initial}, fn event, {:ok, state} ->
      case event(event, state, payload, offered) do
        {:ok, next} -> {:cont, {:ok, next}}
        _ -> {:halt, {:error, :invalid_sse}}
      end
    end)
  end

  defp event(
         %{"type" => "response.created", "response" => response} = event,
         %{phase: :new} = state,
         payload,
         _
       ) do
    if event_keys?(event, ~w(response)) and response?(response, payload, "in_progress") and
         response["output"] == [] and is_nil(response["usage"]),
       do: {:ok, %{state | phase: :created, id: response["id"]}},
       else: :error
  end

  defp event(
         %{"type" => "response.in_progress", "response" => response} = event,
         %{phase: :created} = state,
         payload,
         _
       ) do
    if event_keys?(event, ~w(response)) and response?(response, payload, "in_progress") and
         response["id"] == state.id and response["output"] == [] and is_nil(response["usage"]),
       do: {:ok, %{state | phase: :streaming}},
       else: :error
  end

  defp event(
         %{"type" => "response.output_item.added", "output_index" => index, "item" => item} =
           event,
         %{phase: :streaming} = state,
         _,
         offered
       ) do
    with true <-
           event_keys?(event, ~w(output_index item)) and index == map_size(state.items) and
             index < 128,
         true <- Enum.all?(state.items, fn {_, entry} -> entry.done end),
         true <-
           is_map(item) and identifier?(item["id"]) and not MapSet.member?(state.ids, item["id"]),
         {:ok, entry} <- added_item(item, offered),
         true <- is_nil(entry.call_id) or not MapSet.member?(state.call_ids, entry.call_id) do
      {:ok,
       %{
         state
         | items: Map.put(state.items, index, entry),
           ids: MapSet.put(state.ids, item["id"]),
           call_ids:
             if(entry.call_id,
               do: MapSet.put(state.call_ids, entry.call_id),
               else: state.call_ids
             )
       }}
    else
      _ -> :error
    end
  end

  defp event(
         %{"type" => "response.completed", "response" => response} = event,
         %{phase: :streaming} = state,
         payload,
         _
       ) do
    output =
      state.items |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(fn {_, value} -> value.final end)

    if event_keys?(event, ~w(response)) and response?(response, payload, "completed") and
         response["id"] == state.id and
         Enum.all?(state.items, fn {_, entry} -> entry.done end) and response["output"] == output and
         usage?(response["usage"], payload["max_output_tokens"]),
       do: {:ok, %{state | phase: :completed, usage: response["usage"]}},
       else: :error
  end

  defp event(%{"output_index" => index} = event, %{phase: :streaming} = state, _, _) do
    with entry when is_map(entry) <- state.items[index],
         true <- not entry.done,
         {:ok, next} <- item_event(event, entry) do
      {:ok, %{state | items: Map.put(state.items, index, next)}}
    else
      _ -> :error
    end
  end

  defp event(_, _, _, _), do: :error

  defp added_item(
         %{
           "id" => id,
           "type" => "message",
           "status" => "in_progress",
           "role" => "assistant",
           "content" => []
         } = item,
         _
       ) do
    if keys?(item, ~w(id type status role content)), do: {:ok, entry(id, "message")}, else: :error
  end

  defp added_item(
         %{
           "id" => id,
           "type" => "function_call",
           "status" => "in_progress",
           "call_id" => call,
           "name" => name,
           "arguments" => ""
         } = item,
         offered
       ) do
    if keys?(item, ~w(id type status call_id name namespace arguments)) and identifier?(call) and
         {item["namespace"], name} in offered,
       do:
         {:ok,
          %{entry(id, "function_call") | call_id: call, name: name, namespace: item["namespace"]}},
       else: :error
  end

  defp added_item(%{"id" => id, "type" => "reasoning", "summary" => []} = item, _) do
    if keys?(item, ~w(id type summary)), do: {:ok, entry(id, "reasoning")}, else: :error
  end

  defp added_item(_, _), do: :error

  defp entry(id, type),
    do: %{
      id: id,
      type: type,
      call_id: nil,
      name: nil,
      namespace: nil,
      delta: "",
      part: :none,
      text_done: false,
      done: false,
      final: nil
    }

  defp item_event(
         %{
           "type" => "response.content_part.added",
           "item_id" => id,
           "content_index" => 0,
           "part" => part
         } = event,
         %{id: id, type: "message", part: :none} = entry
       ) do
    if event_keys?(event, ~w(item_id output_index content_index part)) and output_part?(part, ""),
      do: {:ok, %{entry | part: :added}},
      else: :error
  end

  defp item_event(
         %{
           "type" => "response.output_text.delta",
           "item_id" => id,
           "content_index" => 0,
           "delta" => delta
         } = event,
         %{id: id, type: "message", part: :added, text_done: false} = entry
       ) do
    if event_keys?(event, ~w(item_id output_index content_index delta logprobs)) and
         event["logprobs"] == [] and is_binary(delta),
       do: {:ok, %{entry | delta: entry.delta <> delta}},
       else: :error
  end

  defp item_event(
         %{
           "type" => "response.output_text.done",
           "item_id" => id,
           "content_index" => 0,
           "text" => text
         } = event,
         %{id: id, type: "message", part: :added, text_done: false, delta: text} = entry
       ) do
    if event_keys?(event, ~w(item_id output_index content_index text logprobs)) and
         event["logprobs"] == [], do: {:ok, %{entry | text_done: true}}, else: :error
  end

  defp item_event(
         %{
           "type" => "response.content_part.done",
           "item_id" => id,
           "content_index" => 0,
           "part" => part
         } = event,
         %{id: id, type: "message", part: :added, text_done: true} = entry
       ) do
    if event_keys?(event, ~w(item_id output_index content_index part)) and
         output_part?(part, entry.delta), do: {:ok, %{entry | part: :done}}, else: :error
  end

  defp item_event(
         %{"type" => "response.function_call_arguments.delta", "item_id" => id, "delta" => delta} =
           event,
         %{id: id, type: "function_call", text_done: false} = entry
       ) do
    if event_keys?(event, ~w(item_id output_index delta)) and is_binary(delta),
      do: {:ok, %{entry | delta: entry.delta <> delta}},
      else: :error
  end

  defp item_event(
         %{
           "type" => "response.function_call_arguments.done",
           "item_id" => id,
           "arguments" => args
         } = event,
         %{id: id, type: "function_call", text_done: false, delta: args} = entry
       ) do
    if event_keys?(event, ~w(item_id output_index arguments)) and json_object?(args),
      do: {:ok, %{entry | text_done: true}},
      else: :error
  end

  defp item_event(
         %{
           "type" => "response.reasoning_summary_text.delta",
           "item_id" => id,
           "summary_index" => 0,
           "delta" => delta
         } = event,
         %{id: id, type: "reasoning", text_done: false} = entry
       ) do
    if event_keys?(event, ~w(item_id output_index summary_index delta)) and is_binary(delta),
      do: {:ok, %{entry | delta: entry.delta <> delta}},
      else: :error
  end

  defp item_event(
         %{
           "type" => "response.reasoning_summary_text.done",
           "item_id" => id,
           "summary_index" => 0,
           "text" => text
         } = event,
         %{id: id, type: "reasoning", text_done: false, delta: text} = entry
       ) do
    if event_keys?(event, ~w(item_id output_index summary_index text)),
      do: {:ok, %{entry | text_done: true}},
      else: :error
  end

  defp item_event(%{"type" => "response.output_item.done", "item" => item} = event, entry) do
    if event_keys?(event, ~w(output_index item)) and final_item?(item, entry),
      do: {:ok, %{entry | done: true, final: item}},
      else: :error
  end

  defp item_event(_, _), do: :error

  defp final_item?(item, %{type: "message", part: :done, text_done: true} = entry) do
    keys?(item, ~w(id type status role content)) and item["id"] == entry.id and
      item["type"] == "message" and item["status"] == "completed" and item["role"] == "assistant" and
      match?([_], item["content"]) and output_part?(hd(item["content"]), entry.delta)
  end

  defp final_item?(item, %{type: "function_call", text_done: true} = entry) do
    keys?(item, ~w(id type status call_id name namespace arguments)) and item["id"] == entry.id and
      item["type"] == "function_call" and item["status"] == "completed" and
      item["call_id"] == entry.call_id and item["name"] == entry.name and
      item["namespace"] == entry.namespace and item["arguments"] == entry.delta
  end

  defp final_item?(item, %{type: "reasoning", text_done: true} = entry) do
    keys?(item, ~w(id type summary encrypted_content)) and item["id"] == entry.id and
      item["type"] == "reasoning" and
      item["summary"] == [%{"type" => "summary_text", "text" => entry.delta}] and
      item["encrypted_content"] == entry.delta
  end

  defp final_item?(_, _), do: false

  defp response?(value, payload, status) when is_map(value) do
    keys?(value, @response_fields) and identifier?(value["id"]) and value["object"] == "response" and
      value["status"] == status and value["model"] == payload["model"] and value["store"] == false and
      value["background"] == false and is_nil(value["error"]) and
      is_nil(value["incomplete_details"]) and is_nil(value["previous_response_id"]) and
      is_list(value["output"]) and value["max_output_tokens"] == payload["max_output_tokens"] and
      (value["tools"] || []) == (payload["tools"] || [])
  end

  defp response?(_, _, _), do: false

  defp usage?(
         %{"input_tokens" => input, "output_tokens" => output, "total_tokens" => total} = usage,
         limit
       ) do
    keys?(
      usage,
      ~w(input_tokens output_tokens total_tokens input_tokens_details output_tokens_details)
    ) and is_integer(input) and input in 0..1_000_000 and is_integer(output) and output >= 0 and
      output < limit and total == input + output
  end

  defp usage?(_, _), do: false

  defp output_part?(
         %{"type" => "output_text", "text" => text, "annotations" => [], "logprobs" => []} = part,
         text
       ),
       do: keys?(part, ~w(type text annotations logprobs))

  defp output_part?(_, _), do: false

  defp summary?(list) when is_list(list) and length(list) <= 32,
    do:
      Enum.all?(list, fn part ->
        is_map(part) and keys?(part, ~w(type text)) and part["type"] == "summary_text" and
          is_binary(part["text"])
      end)

  defp summary?(_), do: false

  defp name?(value),
    do: is_binary(value) and Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_-]{0,63}\z/, value)

  defp identifier?(value),
    do:
      is_binary(value) and byte_size(value) in 1..200 and
        Regex.match?(~r/\A[A-Za-z0-9_.:-]+\z/, value)

  defp optional_id?(nil), do: true
  defp optional_id?(value), do: identifier?(value)
  defp keys?(map, keys), do: is_map(map) and Map.keys(map) -- keys == []
  defp event_keys?(event, fields), do: keys?(event, ["type", "sequence_number" | fields])
  defp text?(nil, true), do: true
  defp text?(value, _), do: is_binary(value)
  defp number_in?(nil, _, _), do: true
  defp number_in?(value, min, max), do: is_number(value) and value >= min and value <= max

  defp json_object?(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, object} when is_map(object) -> json_depth?(object, 0)
      _ -> false
    end
  end

  defp json_object?(_), do: false
  defp json_depth?(_, depth) when depth > 16, do: false

  defp json_depth?(map, depth) when is_map(map),
    do: Enum.all?(map, fn {key, value} -> is_binary(key) and json_depth?(value, depth + 1) end)

  defp json_depth?(list, depth) when is_list(list),
    do: Enum.all?(list, &json_depth?(&1, depth + 1))

  defp json_depth?(_, _), do: true
end
