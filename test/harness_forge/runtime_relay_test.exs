defmodule HarnessForge.RuntimeRelayTest.Upstream do
  import Plug.Conn
  def init(options), do: options

  def call(conn, %{owner: owner, mode: mode}) do
    case conn.request_path do
      "/api/tags" ->
        model = %{"name" => "synthetic:fixture"}

        model =
          if Agent.get(mode, & &1) == :remote,
            do: Map.put(model, "remote_host", "https://invalid.example"),
            else: model

        json(conn, %{"models" => [model]})

      "/api/chat" ->
        {:ok, bytes, conn} = read_body(conn)
        body = Jason.decode!(bytes)
        send(owner, {:upstream_chat, body})

        case Agent.get(mode, & &1) do
          :redirect ->
            conn |> put_resp_header("location", "https://invalid.example") |> send_resp(307, "")

          mode ->
            message =
              if mode == :tools,
                do: %{
                  "role" => "assistant",
                  "content" => "",
                  "tool_calls" => [
                    %{"function" => %{"name" => "read", "arguments" => %{"path" => "README.md"}}}
                  ]
                },
                else: %{"role" => "assistant", "content" => "Synthetic coding response"}

            output = %{"done" => true, "message" => message, "done_reason" => "stop"}

            output =
              if mode == :unknown,
                do: output,
                else: Map.merge(output, %{"prompt_eval_count" => 11, "eval_count" => 7})

            json(conn, output)
        end

      _ ->
        send_resp(conn, 404, "")
    end
  end

  defp json(conn, value),
    do: conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(value))
end

defmodule HarnessForge.RuntimeRelayTest do
  use HarnessForge.DataCase, async: false
  alias HarnessForge.{Models, Evidence}
  alias HarnessForge.Execution.Relay

  setup do
    previous = Application.get_env(:harness_forge, :model_test_plug)
    Application.delete_env(:harness_forge, :model_test_plug)
    {:ok, mode} = Agent.start_link(fn -> :text end)

    upstream =
      start_supervised!(
        {Bandit,
         [
           plug: {__MODULE__.Upstream, %{owner: self(), mode: mode}},
           ip: {127, 0, 0, 1},
           port: 0,
           startup_log: false
         ]}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(upstream)

    {:ok, _} =
      Models.configure(%{
        "model" => "synthetic:fixture",
        "endpoint" => "http://127.0.0.1:#{port}"
      })

    on_exit(fn ->
      if previous,
        do: Application.put_env(:harness_forge, :model_test_plug, previous),
        else: Application.delete_env(:harness_forge, :model_test_plug)
    end)

    %{mode: mode, port: port}
  end

  test "actual loopback HTTP chat meters shared ledger and returns text without persistent prompt" do
    {:ok, handle} = Relay.start_run("relay-http")
    assert handle.provider_config["enabled_providers"] == ["harnessforge"]
    refute inspect(handle) =~ handle.token
    assert {:ok, response} = send_chat(handle, request())
    assert response.status == 200

    assert get_in(response.body, ["choices", Access.at(0), "message", "content"]) ==
             "Synthetic coding response"

    assert response.body["usage"] == %{
             "prompt_tokens" => 11,
             "completion_tokens" => 7,
             "total_tokens" => 18
           }

    assert_receive {:upstream_chat, payload}
    assert payload["model"] == "synthetic:fixture"
    assert payload["stream"] == false
    assert payload["options"]["num_predict"] == 128

    assert {:ok, [%{"state" => "completed", "billing_status" => "local_unpriced"}]} =
             Models.list_requests("relay-http")

    assert {:ok, %{"reserved_tokens" => 18}} = Models.budget("relay-http")
    assert :ok = Relay.stop(handle)
    refute Process.alive?(handle.pid)
    assert :ok = Relay.stop(handle)
  end

  test "tool calls translate both directions and SSE returns valid indices and DONE", %{
    mode: mode
  } do
    Agent.update(mode, fn _ -> :tools end)
    {:ok, handle} = Relay.start_run("relay-tools")

    tool = %{
      "type" => "function",
      "function" => %{
        "name" => "read",
        "description" => "Synthetic read",
        "parameters" => %{"type" => "object", "properties" => %{"path" => %{"type" => "string"}}}
      }
    }

    body = request() |> Map.put("tools", [tool]) |> Map.put("stream", true)
    {:ok, response} = send_chat(handle, body, decode_body: false)
    assert response.status == 200
    assert response.body =~ "data: [DONE]\n\n"

    [delta, finish] =
      response.body
      |> String.split("\n\n", trim: true)
      |> Enum.reject(&(&1 == "data: [DONE]"))
      |> Enum.map(fn "data: " <> json -> Jason.decode!(json) end)

    call = get_in(delta, ["choices", Access.at(0), "delta", "tool_calls", Access.at(0)])
    assert call["index"] == 0
    assert Jason.decode!(call["function"]["arguments"]) == %{"path" => "README.md"}
    assert get_in(finish, ["choices", Access.at(0), "finish_reason"]) == "tool_calls"

    history =
      body["messages"] ++
        [
          %{"role" => "assistant", "content" => nil, "tool_calls" => [Map.delete(call, "index")]},
          %{"role" => "tool", "tool_call_id" => call["id"], "content" => "Synthetic result"}
        ]

    assert {:ok, %{status: 200}} = send_chat(handle, %{body | "messages" => history})
    assert_receive {:upstream_chat, _}
    assert_receive {:upstream_chat, translated}
    assert List.last(translated["messages"])["tool_name"] == "read"

    assert Enum.at(translated["messages"], 1)["tool_calls"] == [
             %{"function" => %{"name" => "read", "arguments" => %{"path" => "README.md"}}}
           ]

    assert :ok = Relay.stop(handle)
  end

  test "paths, capabilities, origins, model override and oversized bodies deny before inference" do
    {:ok, handle} = Relay.start_run("relay-denials")

    for path <- [
          "/api/pull",
          "/v1/models",
          "/v1/chat/completions?destination=evil",
          "/v1/chat/completions/extra"
        ] do
      assert {:ok, %{status: 404}} =
               Req.post(url(handle, path), json: request(), headers: auth(handle), retry: false)
    end

    assert {:ok, %{status: 401}} =
             Req.post(url(handle),
               json: request(),
               headers: [{"authorization", "Bearer wrong"}],
               retry: false
             )

    assert {:ok, %{status: 403}} =
             Req.post(url(handle),
               json: request(),
               headers: auth(handle) ++ [{"origin", "https://invalid.example"}],
               retry: false
             )

    assert {:ok, %{status: 400}} = send_chat(handle, %{request() | "model" => "other"})

    assert {:ok, %{status: 400}} =
             send_chat(handle, Map.put(request(), "destination", "http://invalid.example"))

    assert {:ok, %{status: 413}} =
             Req.post(url(handle),
               body: String.duplicate("x", 131_073),
               headers: auth(handle) ++ [{"content-type", "application/json"}],
               retry: false
             )

    refute_receive {:upstream_chat, _}, 30
    assert {:ok, []} = Models.list_requests("relay-denials")
    assert {:error, :invalid_relay_capability} = Relay.stop(%{handle | token: "wrong"})
    assert Process.alive?(handle.pid)
    assert :ok = Relay.stop(handle)
  end

  test "turn and shared request budgets deny retries before upstream" do
    {:ok, _} = Models.start_run("relay-budget", %{"max_requests" => 1})
    {:ok, handle} = Relay.start_run("relay-budget", max_turns: 3)
    assert {:ok, %{status: 200}} = send_chat(handle, request())
    assert {:ok, %{status: 429}} = send_chat(handle, request())
    assert_receive {:upstream_chat, _}
    refute_receive {:upstream_chat, _}, 30
    assert {:ok, [%{"state" => "completed"}]} = Models.list_requests("relay-budget")
    assert :ok = Relay.stop(handle)
    {:ok, handle} = Relay.start_run("relay-turns", max_turns: 1)
    assert {:ok, %{status: 200}} = send_chat(handle, request())
    assert {:ok, %{status: 429}} = send_chat(handle, request())
    assert :ok = Relay.stop(handle)
  end

  test "runtime reopening preserves exact existing caps and refuses an explicit increase" do
    limits = %{
      "max_requests" => 1,
      "max_tokens" => 5_000,
      "max_estimated_microusd" => 0
    }

    assert {:ok, _} = Models.start_run("relay-exact-caps", limits)

    assert {:error, _} =
             HarnessForge.Models.Runtime.prepare("relay-exact-caps",
               budget: Map.put(limits, "max_requests", 2)
             )

    assert {:ok, _} = HarnessForge.Models.Runtime.prepare("relay-exact-caps")
    assert {:ok, budget} = Models.budget("relay-exact-caps")
    assert Map.take(budget, Map.keys(limits)) == limits
    assert budget["reserved_requests"] == 0
    assert {:ok, []} = Models.list_requests("relay-exact-caps")
    refute_receive {:upstream_chat, _}, 30
  end

  test "redirect is never followed and uncertain retry stays fenced; missing usage stays unknown",
       %{mode: mode} do
    {:ok, handle} = Relay.start_run("relay-uncertain")
    Agent.update(mode, fn _ -> :redirect end)

    assert {:ok, %{status: 503, body: %{"error" => %{"code" => "model_redirect_denied"}}}} =
             send_chat(handle, request())

    assert {:ok, %{status: 503, body: %{"error" => %{"code" => "request_outcome_unknown"}}}} =
             send_chat(handle, request())

    assert_receive {:upstream_chat, _}
    refute_receive {:upstream_chat, _}, 30

    assert {:ok, [%{"state" => "uncertain", "input_tokens" => nil}]} =
             Models.list_requests("relay-uncertain")

    assert :ok = Relay.stop(handle)
    Agent.update(mode, fn _ -> :unknown end)
    {:ok, handle} = Relay.start_run("relay-unknown")
    assert {:ok, %{status: 200, body: body}} = send_chat(handle, request())
    refute Map.has_key?(body, "usage")

    assert {:ok, [%{"state" => "uncertain", "billing_status" => "unknown"}]} =
             Models.list_requests("relay-unknown")

    assert :ok = Relay.stop(handle)
  end

  test "Unix socket is private, uses same protocol and is removed on stop" do
    {:ok, handle} = Relay.start_run("relay-unix", unix_socket: true)
    assert is_binary(handle.socket_path)
    assert {:ok, stat} = File.stat(handle.socket_path)
    assert Bitwise.band(stat.mode, 0o777) == 0o600

    assert {:ok, %{status: 200}} =
             Req.post("http://localhost/v1/chat/completions",
               unix_socket: handle.socket_path,
               json: request(),
               headers: auth(handle),
               retry: false
             )

    assert :ok = Relay.stop(handle)
    refute File.exists?(handle.socket_path)
    refute File.exists?(Path.dirname(handle.socket_path))
  end

  test "cloud and remote Ollama metadata cannot start a coding route", %{mode: mode} do
    Agent.update(mode, fn _ -> :remote end)
    assert {:error, :cloud_model_denied} = Relay.start_run("relay-remote")

    {:ok, _} =
      Models.configure(%{
        "provider" => "openai",
        "endpoint" => "https://api.openai.com/v1",
        "model" => "synthetic"
      })

    assert {:error, :runtime_cloud_disabled} = Relay.start_run("relay-cloud")
    assert {:ok, []} = Models.list_requests("relay-cloud")
    refute_receive {:upstream_chat, _}, 30
  end

  test "source revocation applies after a scoped relay starts" do
    directory = Path.join(File.cwd!(), ".hf-relay-source-" <> Ecto.UUID.generate())
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    {:ok, connection} =
      Evidence.connect(%{"name" => "Synthetic", "provider" => "local", "directory" => directory})

    {:ok, source} =
      Evidence.import_markdown(connection["id"], %{
        "external_id" => "synthetic.md",
        "title" => "Synthetic",
        "body" => "Public synthetic only"
      })

    {:ok, handle} = Relay.start_run("relay-revoked", source_ids: [source["id"]])
    {:ok, _} = Evidence.revoke_connection(connection["id"])
    assert {:ok, %{status: 403}} = send_chat(handle, request())
    refute_receive {:upstream_chat, _}, 30
    assert :ok = Relay.stop(handle)
  end

  defp request,
    do: %{
      "model" => "synthetic:fixture",
      "messages" => [%{"role" => "user", "content" => "Synthetic coding task"}],
      "max_tokens" => 128
    }

  defp url(handle, path \\ "/v1/chat/completions"), do: "http://127.0.0.1:#{handle.port}" <> path
  defp auth(handle), do: [{"authorization", "Bearer " <> handle.token}]

  defp send_chat(handle, body, opts \\ []),
    do: Req.post([url: url(handle), json: body, headers: auth(handle), retry: false] ++ opts)
end
