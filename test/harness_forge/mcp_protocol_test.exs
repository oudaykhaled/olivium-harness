defmodule HarnessForge.MCP.ProtocolTest do
  use HarnessForge.DataCase, async: false

  alias HarnessForge.MCP.Protocol

  test "initialization negotiates the pinned profile and advertises only read-only tools" do
    assert Protocol.version() == "2025-11-25"

    for requested <- [Protocol.version(), "2099-01-01"] do
      assert {:reply, response} =
               Protocol.handle(
                 request("initialize", %{
                   "protocolVersion" => requested,
                   "capabilities" => %{},
                   "clientInfo" => %{"name" => "Synthetic client", "version" => "1.0"}
                 })
               )

      assert response["id"] == 1
      assert response["result"]["protocolVersion"] == Protocol.version()
      assert response["result"]["capabilities"] == %{"tools" => %{"listChanged" => false}}
      refute Map.has_key?(response["result"], "instructions")
    end

    assert :accepted_notification =
             Protocol.handle(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"})

    assert {:reply, %{"result" => %{}}} = Protocol.handle(request("ping"))
    assert {:reply, %{"result" => %{"tools" => tools}}} = Protocol.handle(request("tools/list"))

    assert Enum.sort(Enum.map(tools, & &1["name"])) ==
             ~w(harnessforge_company_plans harnessforge_company_run_readiness harnessforge_inspect_package harnessforge_search_repositories)

    for tool <- tools do
      assert tool["annotations"] == %{
               "readOnlyHint" => true,
               "destructiveHint" => false,
               "idempotentHint" => true,
               "openWorldHint" => false
             }
    end
  end

  test "malformed IDs, batches, responses and unknown envelope keys are rejected" do
    for id <- [nil, true, false, 1.5, %{}, [], 9_007_199_254_740_992, String.duplicate("a", 129)] do
      assert {:reject, 400, %{"id" => nil, "error" => %{"code" => -32600}}} =
               Protocol.handle(Map.put(request("ping"), "id", id))
    end

    for value <- [
          [],
          [request("ping")],
          nil,
          true,
          %{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}
        ] do
      assert {:reject, 400, _} = Protocol.handle(value)
    end

    assert {:reject, 400, _} =
             Protocol.handle(Map.put(request("ping"), "extra", "PRIVATE_SENTINEL"))

    assert {:reject, 400, _} =
             Protocol.handle(Map.put(request("ping"), "params", []))

    for id <- [-9_007_199_254_740_991, 9_007_199_254_740_991, "", "request-α"] do
      assert {:reply, %{"id" => ^id, "result" => %{}}} =
               Protocol.handle(Map.put(request("ping"), "id", id))
    end
  end

  test "invalid params are protocol failures and unavailable data are safe tool failures" do
    for {method, params} <- [
          {"initialize", %{}},
          {"initialize",
           %{"protocolVersion" => "2025-11-25", "capabilities" => [], "clientInfo" => %{}}},
          {"ping", %{"extra" => true}},
          {"tools/list", %{"cursor" => "unsupported"}},
          {"tools/call", %{}},
          {"tools/call", %{"name" => "approve_claim", "arguments" => %{}}},
          {"tools/call", %{"name" => "harnessforge_company_plans", "arguments" => nil}},
          {"tools/call",
           %{"name" => "harnessforge_company_plans", "arguments" => %{"limit" => 21}}},
          {"tools/call",
           %{"name" => "harnessforge_company_plans", "arguments" => %{}, "actor" => "root"}}
        ] do
      assert {:reply, %{"error" => %{"code" => -32602}}} =
               Protocol.handle(request(method, params))
    end

    assert {:reply, %{"error" => %{"code" => -32601}}} =
             Protocol.handle(request("claims/approve"))

    assert {:reply, %{"result" => result}} =
             Protocol.handle(
               request("tools/call", %{
                 "name" => "harnessforge_company_plans",
                 "arguments" => %{"plan_id" => Ecto.UUID.generate()}
               })
             )

    assert result["isError"]
    assert result["structuredContent"]["error"]["code"] == "not_found"
    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert Jason.decode!(text) == result["structuredContent"]
  end

  test "successful structured result has matching text JSON and no invented qualification" do
    assert {:reply, %{"result" => result}} =
             Protocol.handle(
               request("tools/call", %{
                 "name" => "harnessforge_search_repositories",
                 "arguments" => %{"query" => ""},
                 "_meta" => %{}
               })
             )

    refute result["isError"]
    assert result["structuredContent"]["repositories"] == []
    assert result["structuredContent"]["authority"] == "operator_authored_catalogue"
    assert Jason.decode!(hd(result["content"])["text"]) == result["structuredContent"]
    refute inspect(result) =~ "runtime_qualified"

    assert {:reply, %{"result" => %{"isError" => false}}} =
             Protocol.handle(request("tools/call", %{"name" => "harnessforge_company_plans"}))
  end

  test "only initialized notifications are accepted without an ID" do
    for message <- [
          %{"jsonrpc" => "2.0", "method" => "notifications/cancelled"},
          %{"jsonrpc" => "2.0", "method" => "tools/list"},
          %{"jsonrpc" => "2.0", "method" => "notifications/initialized", "id" => 3},
          %{
            "jsonrpc" => "2.0",
            "method" => "notifications/initialized",
            "params" => %{"extra" => true}
          }
        ] do
      assert {:reject, 400, _} = Protocol.handle(message)
    end
  end

  defp request(method, params \\ %{}),
    do: %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}
end
