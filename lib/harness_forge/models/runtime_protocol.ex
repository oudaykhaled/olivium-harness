defmodule HarnessForge.Models.RuntimeProtocol do
  @moduledoc false
  @body_limit 131_072
  @output_limit 131_072
  @fields ~w(model messages tools tool_choice max_tokens max_completion_tokens stream stream_options temperature top_p seed parallel_tool_calls stop)

  def body_limit, do: @body_limit

  def request(body, scope) when is_map(body) do
    output = body["max_completion_tokens"] || body["max_tokens"] || scope.max_output_tokens
    tools = body["tools"] || []

    with true <- byte_size(Jason.encode!(body)) <= @body_limit,
         true <- Map.keys(body) -- @fields == [],
         true <- body["model"] == scope.config["model"],
         true <- is_integer(output) and output in 1..scope.max_output_tokens,
         true <- body["stream"] in [nil, true, false],
         true <- body["tool_choice"] in [nil, "auto", "none"],
         true <- body["parallel_tool_calls"] in [nil, true, false],
         true <-
           body["stream_options"] in [
             nil,
             %{},
             %{"include_usage" => true},
             %{"include_usage" => false}
           ],
         true <- body["stop"] in [nil, [], ""] and is_nil(body["seed"]),
         true <- number_in?(body["temperature"], 0, 2) and number_in?(body["top_p"], 0, 1),
         :ok <- tools(tools),
         {:ok, messages} <- messages(body["messages"]) do
      options = %{"num_predict" => output, "temperature" => body["temperature"] || 0}
      options = if body["top_p"], do: Map.put(options, "top_p", body["top_p"]), else: options

      payload = %{
        "model" => scope.config["model"],
        "messages" => messages,
        "stream" => false,
        "options" => options
      }

      payload =
        if tools == [] or body["tool_choice"] == "none",
          do: payload,
          else: Map.put(payload, "tools", tools)

      {:ok, payload, body["stream"] == true}
    else
      _ -> {:error, :invalid_runtime_request}
    end
  rescue
    _ -> {:error, :invalid_runtime_request}
  end

  def request(_, _), do: {:error, :invalid_runtime_request}

  defp tools(value) when is_list(value) and length(value) <= 32 do
    if Enum.all?(value, fn
         %{"type" => "function", "function" => %{"name" => name, "parameters" => params} = f} =
             tool ->
           Map.keys(tool) -- ~w(type function) == [] and
             Map.keys(f) -- ~w(name description parameters strict) == [] and
             name?(name) and is_map(params) and
             (is_nil(f["description"]) or is_binary(f["description"]))

         _ ->
           false
       end), do: :ok, else: {:error, :invalid_tools}
  end

  defp tools(_), do: {:error, :invalid_tools}

  defp messages(value) when is_list(value) and length(value) in 1..128 do
    Enum.reduce_while(value, {:ok, [], %{}}, fn message, {:ok, converted, calls} ->
      case message(message, calls) do
        {:ok, translated, next} -> {:cont, {:ok, [translated | converted], next}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values, _} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp messages(_), do: {:error, :invalid_messages}

  defp message(%{"role" => role} = message, calls)
       when role in ["system", "developer", "user", "assistant", "tool"] do
    with true <- Map.keys(message) -- ~w(role content tool_calls tool_call_id name) == [],
         {:ok, content} <- content(message["content"]),
         {:ok, translated_calls, next_calls} <-
           translate_calls(message["tool_calls"] || [], calls),
         true <- role == "assistant" or translated_calls == [],
         true <- role != "tool" or Map.has_key?(calls, message["tool_call_id"]) do
      translated = %{
        "role" => if(role == "developer", do: "system", else: role),
        "content" => content
      }

      translated =
        if translated_calls == [],
          do: translated,
          else: Map.put(translated, "tool_calls", translated_calls)

      translated =
        if role == "tool",
          do: Map.put(translated, "tool_name", calls[message["tool_call_id"]]),
          else: translated

      {:ok, translated, next_calls}
    else
      _ -> {:error, :invalid_messages}
    end
  end

  defp message(_, _), do: {:error, :invalid_messages}

  defp content(nil), do: {:ok, ""}
  defp content(value) when is_binary(value), do: {:ok, value}

  defp content(value) when is_list(value) do
    if Enum.all?(value, &match?(%{"type" => "text", "text" => text} when is_binary(text), &1)),
      do: {:ok, Enum.map_join(value, "\n", & &1["text"])},
      else: {:error, :unsupported_content}
  end

  defp content(_), do: {:error, :unsupported_content}

  defp translate_calls(value, calls) when is_list(value) and length(value) <= 32 do
    Enum.reduce_while(value, {:ok, [], calls}, fn
      %{"id" => id, "type" => "function", "function" => %{"name" => name, "arguments" => args}},
      {:ok, out, known}
      when is_binary(id) and is_binary(args) ->
        with true <- byte_size(id) in 1..200 and name?(name) and not Map.has_key?(known, id),
             {:ok, decoded} when is_map(decoded) <- Jason.decode(args) do
          {:cont,
           {:ok, out ++ [%{"function" => %{"name" => name, "arguments" => decoded}}],
            Map.put(known, id, name)}}
        else
          _ -> {:halt, {:error, :invalid_tool_call}}
        end

      _, _ ->
        {:halt, {:error, :invalid_tool_call}}
    end)
  end

  defp translate_calls(_, _), do: {:error, :invalid_tool_call}

  def response(%{"done" => true, "message" => %{"role" => "assistant"} = message} = body, payload) do
    content = message["content"] || ""
    offered = Enum.map(payload["tools"] || [], & &1["function"]["name"])

    with true <- is_binary(content),
         {:ok, calls} <- output_calls(message["tool_calls"] || [], offered),
         true <- byte_size(content) + byte_size(Jason.encode!(calls)) <= @output_limit,
         true <-
           is_nil(body["eval_count"]) or
             (is_integer(body["eval_count"]) and
                body["eval_count"] in 0..payload["options"]["num_predict"]) do
      known =
        is_integer(body["prompt_eval_count"]) and body["prompt_eval_count"] >= 0 and
          is_integer(body["eval_count"]) and body["eval_count"] >= 0

      {:ok,
       %{
         content: content,
         tool_calls: calls,
         input_tokens: if(known, do: body["prompt_eval_count"], else: nil),
         output_tokens: if(known, do: body["eval_count"], else: nil),
         finish:
           cond do
             calls != [] -> "tool_calls"
             body["done_reason"] == "length" -> "length"
             true -> "stop"
           end
       }}
    else
      _ -> {:error, :invalid_runtime_response}
    end
  end

  def response(_, _), do: {:error, :invalid_runtime_response}

  defp output_calls(value, offered) when is_list(value) and length(value) <= 32 do
    Enum.reduce_while(value, {:ok, []}, fn
      %{"function" => %{"name" => name, "arguments" => args}}, {:ok, out} when is_map(args) ->
        if name in offered,
          do:
            {:cont,
             {:ok,
              out ++
                [
                  %{
                    "id" =>
                      "call_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false),
                    "type" => "function",
                    "function" => %{"name" => name, "arguments" => Jason.encode!(args)}
                  }
                ]}},
          else: {:halt, {:error, :unexpected_tool_call}}

      _, _ ->
        {:halt, {:error, :invalid_tool_call}}
    end)
  end

  defp output_calls(_, _), do: {:error, :invalid_tool_call}

  def completion(output, model, stream?) do
    base = %{
      "id" => "chatcmpl-" <> Ecto.UUID.generate(),
      "created" => System.os_time(:second),
      "model" => model
    }

    message = %{"role" => "assistant", "content" => output.content}

    message =
      if output.tool_calls == [],
        do: message,
        else: Map.put(message, "tool_calls", output.tool_calls)

    usage =
      if is_integer(output.input_tokens),
        do: %{
          "prompt_tokens" => output.input_tokens,
          "completion_tokens" => output.output_tokens,
          "total_tokens" => output.input_tokens + output.output_tokens
        },
        else: nil

    if stream? do
      delta =
        if output.tool_calls == [],
          do: message,
          else:
            Map.put(
              message,
              "tool_calls",
              Enum.with_index(output.tool_calls, fn call, index ->
                Map.put(call, "index", index)
              end)
            )

      chunk =
        Map.merge(base, %{
          "object" => "chat.completion.chunk",
          "choices" => [%{"index" => 0, "delta" => delta, "finish_reason" => nil}]
        })

      finish =
        Map.put(chunk, "choices", [
          %{"index" => 0, "delta" => %{}, "finish_reason" => output.finish}
        ])

      finish = if usage, do: Map.put(finish, "usage", usage), else: finish

      {:sse,
       "data: " <>
         Jason.encode!(chunk) <> "\n\ndata: " <> Jason.encode!(finish) <> "\n\ndata: [DONE]\n\n"}
    else
      result =
        Map.merge(base, %{
          "object" => "chat.completion",
          "choices" => [%{"index" => 0, "message" => message, "finish_reason" => output.finish}]
        })

      {:json, if(usage, do: Map.put(result, "usage", usage), else: result)}
    end
  end

  defp name?(name), do: is_binary(name) and Regex.match?(~r/\A[a-zA-Z0-9_-]{1,64}\z/, name)
  defp number_in?(nil, _, _), do: true
  defp number_in?(value, min, max), do: is_number(value) and value >= min and value <= max
end
