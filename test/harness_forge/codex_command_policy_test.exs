defmodule HarnessForge.CodexCommandPolicyTest do
  use ExUnit.Case, async: true
  alias HarnessForge.Contracts
  alias HarnessForge.Execution.CodexCommandPolicy, as: Policy

  test "admission preserves original argument bytes and grants no execution" do
    original = ~s({ "cmd": "cat utility.go", "login": false, "timeout_ms": 10000 })
    assert {:ok, result} = Policy.arguments(original)
    assert result == %{"arguments" => original, "arguments_digest" => Contracts.sha256(original)}
    assert {:ok, _} = Policy.arguments(Jason.encode!(%{"cmd" => "printf 'مرحبا'"}))
  end

  test "permissions, interactivity and runtime limits fail closed before publication" do
    invalid = [
      %{"sandbox_permissions" => "require_escalated"},
      %{"additional_permissions" => %{}},
      %{"prefix_rule" => ["bash"]},
      %{"tty" => false},
      %{"yield_time_ms" => 1},
      %{"environment_id" => "other"},
      %{"workdir" => "/"},
      %{"shell" => "/bin/sh"},
      %{"login" => true},
      %{"timeout_ms" => 10_001},
      %{"timeout_ms" => 0},
      %{"max_output_tokens" => 2001},
      %{"cmd" => ""},
      %{"cmd" => "bad\u0000command"},
      %{"cmd" => String.duplicate("x", 4097)},
      %{"sandbox_permissions" => nil}
    ]

    for extra <- invalid do
      assert {:error, :codex_command_arguments_rejected} =
               Policy.arguments(Jason.encode!(Map.merge(%{"cmd" => "cat utility.go"}, extra)))
    end

    for malformed <- ["[]", "null", "{", <<255>>, String.duplicate("x", 8193)] do
      assert {:error, :codex_command_arguments_rejected} = Policy.arguments(malformed)
    end
  end

  test "native metadata is inert, bounded and tied to the same thread and turn" do
    body = request()
    assert {:ok, %{"thread_id" => "thread-1", "turn_id" => "turn-1"}} = Policy.metadata(body)

    for extra <- [
          %{"thread_id" => ""},
          %{"thread_id" => "other"},
          %{"turn_id" => "other"},
          %{"unexpected" => "value"},
          %{"x-codex-window-id" => String.duplicate("x", 2049)},
          %{"x-codex-turn-metadata" => "[]"},
          %{"x-codex-turn-metadata" => Jason.encode!(%{"thread_id" => "other"})}
        ] do
      assert {:error, :codex_command_context_rejected} =
               Policy.metadata(Map.update!(body, "client_metadata", &Map.merge(&1, extra)))
    end
  end

  test "one-shot call identity uses call_id and preserves arguments, never Responses item id" do
    args = ~s({"cmd":"cat utility.go","sandbox_permissions":"use_default"})

    call = %{
      "type" => "function_call",
      "name" => "exec_command",
      "id" => "fc-different-id",
      "call_id" => "call-1",
      "arguments" => args
    }

    response = %{response_id: "resp-1", function_calls: [call]}
    assert {:ok, [record]} = Policy.response_calls(response, request())
    assert record["call_id"] == "call-1"
    assert record["arguments"] == args
    assert record["provider_response_id"] == "resp-1"

    history_call = Map.delete(call, "id")
    result = %{"type" => "function_call_output", "call_id" => "call-1", "output" => "completed"}

    assert {:error, :codex_command_context_rejected} =
             Policy.continuation(record, %{"input" => [history_call]})

    assert :ok = Policy.continuation(record, %{"input" => [history_call, result]})

    assert {:error, :codex_command_context_rejected} =
             Policy.continuation(record, %{
               "input" => [Map.put(history_call, "arguments", "{}"), result]
             })

    assert {:error, :codex_command_arguments_rejected} =
             Policy.response_calls(%{response | function_calls: [call, call]}, request())

    for changed <- [Map.put(call, "name", "apply_patch"), Map.put(call, "namespace", "other")] do
      assert {:error, :codex_command_arguments_rejected} =
               Policy.response_calls(%{response | function_calls: [changed]}, request())
    end
  end

  defp request do
    %{
      "model" => "synthetic:fixture",
      "prompt_cache_key" => "thread-1",
      "client_metadata" => %{
        "thread_id" => "thread-1",
        "session_id" => "thread-1",
        "turn_id" => "turn-1",
        "root_turn_id" => "turn-1",
        "x-codex-turn-metadata" =>
          Jason.encode!(%{
            "thread_id" => "thread-1",
            "turn_id" => "turn-1",
            "model" => "synthetic:fixture"
          })
      }
    }
  end

  test "native callback joins call_id, exact run-local context and original arguments" do
    {rpc, context, call} = callback()
    frame = Jason.encode!(rpc)
    assert {:ok, payload} = Policy.approval(frame, context, call)
    assert payload["item_id"] == call["call_id"]
    assert payload["json_rpc_id"] == 42
    assert payload["native_context_digest"] == Contracts.sha256(frame)
    assert payload["original_arguments"] == call["arguments"]
    assert payload["command"] == rpc["params"]["command"]

    for changes <- [
          %{"itemId" => "fc-not-the-call-id"},
          %{"threadId" => "another-thread"},
          %{"turnId" => "another-turn"},
          %{"environmentId" => "another-environment"},
          %{"cwd" => "/"},
          %{"approvalId" => "different-path"},
          %{"kind" => "writeStdin"},
          %{"additionalPermissions" => %{}},
          %{"networkApprovalContext" => %{}},
          %{"availableDecisions" => ["acceptForSession"]},
          %{"availableDecisions" => []},
          %{"unexpected" => true}
        ] do
      altered = Map.update!(rpc, "params", &Map.merge(&1, changes)) |> Jason.encode!()
      assert {:error, :codex_command_approval_rejected} = Policy.approval(altered, context, call)
    end
  end

  defp callback do
    original = ~s({"cmd":"cat utility.go","login":false})

    context = %{
      "driver_nonce" => String.duplicate("a", 32),
      "thread_id" => "thread-1",
      "environment_id" => "env-1"
    }

    call = %{
      "thread_id" => "thread-1",
      "turn_id" => "turn-1",
      "call_id" => "call-1",
      "provider_response_id" => "resp-1",
      "arguments" => original,
      "arguments_digest" => Contracts.sha256(original)
    }

    rpc = %{
      "id" => 42,
      "method" => "item/commandExecution/requestApproval",
      "params" => %{
        "kind" => "command",
        "threadId" => "thread-1",
        "turnId" => "turn-1",
        "itemId" => "call-1",
        "environmentId" => "env-1",
        "command" => "/bin/bash -c 'cat utility.go'",
        "cwd" => "/candidate",
        "proposedExecpolicyAmendment" => ["cat", "utility.go"],
        "availableDecisions" => ["accept", "acceptForSession", "decline", "cancel"]
      }
    }

    {rpc, context, call}
  end
end
