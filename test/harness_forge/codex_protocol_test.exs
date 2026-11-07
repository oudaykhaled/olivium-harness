defmodule HarnessForge.CodexProtocolFixture do
  def tool(namespace \\ nil) do
    function = %{
      "type" => "function",
      "name" => "read_file",
      "description" => "Read a task file",
      "parameters" => %{"type" => "object", "properties" => %{"path" => %{"type" => "string"}}},
      "strict" => false
    }

    if namespace,
      do: %{"type" => "namespace", "name" => namespace, "tools" => [function]},
      else: function
  end

  def request(tools \\ []),
    do: %{
      "model" => "synthetic:fixture",
      "input" => [
        %{
          "role" => "user",
          "content" => [%{"type" => "input_text", "text" => "Public synthetic coding task"}]
        }
      ],
      "stream" => true,
      "store" => false,
      "max_output_tokens" => 128,
      "tools" => tools
    }

  def events(payload, kind \\ :text) do
    base = %{
      "id" => "resp_synthetic",
      "object" => "response",
      "status" => "in_progress",
      "model" => payload["model"],
      "output" => [],
      "usage" => nil,
      "store" => false,
      "background" => false,
      "error" => nil,
      "incomplete_details" => nil,
      "previous_response_id" => nil,
      "max_output_tokens" => payload["max_output_tokens"],
      "tools" => payload["tools"] || []
    }

    opening = [
      %{"type" => "response.created", "response" => base},
      %{"type" => "response.in_progress", "response" => base}
    ]

    {middle, item} =
      case kind do
        :text ->
          part = %{
            "type" => "output_text",
            "text" => "Synthetic complete response",
            "annotations" => [],
            "logprobs" => []
          }

          item = %{
            "id" => "msg_synthetic",
            "type" => "message",
            "status" => "completed",
            "role" => "assistant",
            "content" => [part]
          }

          added = %{item | "status" => "in_progress", "content" => []}

          {[
             %{"type" => "response.output_item.added", "output_index" => 0, "item" => added},
             %{
               "type" => "response.content_part.added",
               "output_index" => 0,
               "item_id" => item["id"],
               "content_index" => 0,
               "part" => %{part | "text" => ""}
             },
             %{
               "type" => "response.output_text.delta",
               "output_index" => 0,
               "item_id" => item["id"],
               "content_index" => 0,
               "delta" => part["text"],
               "logprobs" => []
             },
             %{
               "type" => "response.output_text.done",
               "output_index" => 0,
               "item_id" => item["id"],
               "content_index" => 0,
               "text" => part["text"],
               "logprobs" => []
             },
             %{
               "type" => "response.content_part.done",
               "output_index" => 0,
               "item_id" => item["id"],
               "content_index" => 0,
               "part" => part
             },
             %{"type" => "response.output_item.done", "output_index" => 0, "item" => item}
           ], item}

        namespace ->
          item = %{
            "id" => "fc_synthetic",
            "type" => "function_call",
            "status" => "completed",
            "call_id" => "call_synthetic",
            "name" => "read_file",
            "arguments" => "{\"path\":\"README.md\"}"
          }

          item = if namespace == :function, do: item, else: Map.put(item, "namespace", namespace)

          {[
             %{
               "type" => "response.output_item.added",
               "output_index" => 0,
               "item" => %{item | "status" => "in_progress", "arguments" => ""}
             },
             %{
               "type" => "response.function_call_arguments.delta",
               "output_index" => 0,
               "item_id" => item["id"],
               "delta" => item["arguments"]
             },
             %{
               "type" => "response.function_call_arguments.done",
               "output_index" => 0,
               "item_id" => item["id"],
               "arguments" => item["arguments"]
             },
             %{"type" => "response.output_item.done", "output_index" => 0, "item" => item}
           ], item}
      end

    final =
      base
      |> Map.merge(%{
        "status" => "completed",
        "output" => [item],
        "usage" => %{"input_tokens" => 11, "output_tokens" => 7, "total_tokens" => 18}
      })

    opening ++ middle ++ [%{"type" => "response.completed", "response" => final}]
  end

  def encode(events),
    do:
      events
      |> Enum.with_index()
      |> Enum.map_join(fn {event, index} ->
        "event: " <>
          event["type"] <>
          "\ndata: " <> Jason.encode!(Map.put(event, "sequence_number", index)) <> "\n\n"
      end)

  def raw(bytes), do: %{"status" => 200, "content_type" => ["text/event-stream"], "body" => bytes}
end

defmodule HarnessForge.CodexProtocolTest do
  use ExUnit.Case, async: true
  alias HarnessForge.Models.CodexProtocol
  alias HarnessForge.CodexProtocolFixture, as: F

  defp scope(tools \\ []),
    do: %{config: %{"model" => "synthetic:fixture"}, max_output_tokens: 128, codex_tools: tools}

  test "native function and namespace calls retain IDs and correlated results without translation" do
    for namespace <- [nil, "files"] do
      tools = [F.tool(namespace)]
      assert {:ok, ^tools} = CodexProtocol.tool_scope(tools)
      assert {:ok, payload} = CodexProtocol.request(F.request(tools), scope(tools))
      events = F.events(payload, namespace || :function)
      bytes = F.encode(events)

      assert {:ok, %{bytes: ^bytes, input_tokens: 11, output_tokens: 7}} =
               CodexProtocol.response(F.raw(bytes), payload)

      [call] = List.last(events)["response"]["output"]
      history_call = call |> Map.delete("status")

      result = %{
        "type" => "function_call_output",
        "call_id" => call["call_id"],
        "output" => "Public fixture file"
      }

      history = payload["input"] ++ [history_call, result]

      assert {:ok, continued} =
               CodexProtocol.request(%{payload | "input" => history}, scope(tools))

      assert continued["input"] == history

      assert {:error, :invalid_runtime_request} =
               CodexProtocol.request(%{payload | "input" => history ++ [result]}, scope(tools))

      assert {:error, :invalid_runtime_request} =
               CodexProtocol.request(%{payload | "input" => [result]}, scope(tools))

      assert {:error, :invalid_runtime_request} =
               CodexProtocol.request(
                 %{payload | "input" => payload["input"] ++ [history_call]},
                 scope(tools)
               )
    end
  end

  test "only preflight-pinned complete schemas are admitted; remote/stateful/server-tool settings fail closed" do
    request = F.request()
    assert {:ok, _} = CodexProtocol.request(request, scope())
    assert {:error, _} = CodexProtocol.request(F.request([F.tool()]), scope())

    for {key, value} <- [
          {"previous_response_id", "resp_remote"},
          {"conversation", "conversation_remote"},
          {"background", true},
          {"store", true},
          {"stream", false},
          {"tool_choice", "required"},
          {"parallel_tool_calls", false},
          {"truncation", "auto"},
          {"include", ["unsupported_field"]},
          {"metadata", %{}},
          {"max_output_tokens", 129},
          {"model", "other"}
        ] do
      assert {:error, :invalid_runtime_request} =
               CodexProtocol.request(Map.put(request, key, value), scope())
    end

    for type <- ~w(web_search web_search_preview tool_search computer custom) do
      assert {:error, _} = CodexProtocol.tool_scope([%{"type" => type, "name" => "unsafe"}])
    end

    assert {:error, _} =
             CodexProtocol.request(
               %{
                 request
                 | "input" => [
                     %{
                       "role" => "user",
                       "content" => [
                         %{
                           "type" => "input_image",
                           "image_url" => "https://invalid.example/image"
                         }
                       ]
                     }
                   ]
               },
               scope()
             )

    mutated = put_in(F.tool(), ["parameters", "properties", "path", "type"], "number")
    assert {:error, _} = CodexProtocol.request(F.request([mutated]), scope([F.tool()]))
  end

  test "observed native cache and turn metadata pass unchanged without selecting runtime authority" do
    metadata = %{
      "thread_id" => "thread-1",
      "session_id" => "thread-1",
      "turn_id" => "turn-1",
      "root_turn_id" => "turn-1",
      "x-codex-turn-metadata" =>
        Jason.encode!(%{"thread_id" => "thread-1", "turn_id" => "turn-1"})
    }

    request =
      Map.merge(F.request(), %{
        "include" => ["reasoning.encrypted_content"],
        "prompt_cache_key" => "thread-1",
        "client_metadata" => metadata
      })

    assert {:ok, ^request} = CodexProtocol.request(request, scope())

    assert {:error, :invalid_runtime_request} =
             CodexProtocol.request(
               Map.put(request, "client_metadata", Map.put(metadata, "endpoint", "http://other")),
               scope()
             )

    assert {:error, :invalid_runtime_request} =
             CodexProtocol.request(F.request(), Map.put(scope(), :native_commands, true))
  end

  test "original complete SSE is preserved; truncated, duplicated, reordered, failed and forged outputs are rejected" do
    payload = F.request()
    events = F.events(payload)
    bytes = F.encode(events)
    assert {:ok, %{bytes: ^bytes}} = CodexProtocol.response(F.raw(bytes), payload)
    final = List.last(events)

    bad_events = [
      Enum.drop(events, -1),
      events ++ [final],
      Enum.reverse(events),
      List.replace_at(events, 3, Map.put(Enum.at(events, 3), "item_id", "other")),
      List.replace_at(events, 4, Map.put(Enum.at(events, 4), "delta", "forged")),
      List.replace_at(events, -1, put_in(final, ["response", "usage"], nil)),
      List.replace_at(events, -1, put_in(final, ["response", "usage", "output_tokens"], 128)),
      List.replace_at(events, -1, put_in(final, ["response", "status"], "failed")),
      List.replace_at(events, -1, %{final | "type" => "response.failed"}),
      List.replace_at(events, -1, put_in(final, ["response", "output"], []))
    ]

    for changed <- bad_events,
        do:
          assert(
            {:error, :invalid_runtime_response} =
              CodexProtocol.response(F.raw(F.encode(changed)), payload)
          )

    for changed <- [
          String.trim_trailing(bytes),
          bytes <> "data: [DONE]\n\n",
          String.replace(bytes, "\"sequence_number\":0", "\"sequence_number\":9"),
          String.duplicate("x", 262_145)
        ] do
      assert {:error, :invalid_runtime_response} = CodexProtocol.response(F.raw(changed), payload)
    end

    assert {:error, _} =
             CodexProtocol.response(
               %{F.raw(bytes) | "content_type" => ["application/json"]},
               payload
             )
  end

  test "a tool call not offered to this attempt cannot be published" do
    payload = F.request([F.tool()])
    events = F.events(payload, :function)
    assert {:ok, _} = CodexProtocol.response(F.raw(F.encode(events)), payload)

    assert {:error, _} =
             CodexProtocol.response(F.raw(F.encode(events)), %{payload | "tools" => []})

    changed = List.update_at(events, 2, &put_in(&1, ["item", "name"], "web_search"))
    assert {:error, _} = CodexProtocol.response(F.raw(F.encode(changed)), payload)
  end
end
