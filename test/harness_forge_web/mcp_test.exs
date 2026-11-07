defmodule HarnessForgeWeb.MCPTest do
  use HarnessForgeWeb.ConnCase, async: false

  alias HarnessForge.{Company, Privacy, Repo, Workspaces}
  alias HarnessForge.MCP.Protocol
  alias HarnessForge.Privacy.Purge
  alias HarnessForgeWeb.{Endpoint, Plugs.OperatorSession}

  @token_env "HARNESSFORGE_TEST_MCP_BEARER"
  @token String.duplicate("SYNTHETIC_", 5)

  defmodule RaisingBodyAdapter do
    @moduledoc false
    defdelegate get_peer_data(payload), to: Plug.Adapters.Test.Conn
    defdelegate send_resp(payload, status, headers, body), to: Plug.Adapters.Test.Conn

    def read_req_body(_payload, _options),
      do: raise("PRIVATE_EXCEPTION_SENTINEL_/host/private/source.md")
  end

  setup do
    keys = ~w(mcp_enabled mcp_token_env workspace_root workspace_id)a
    previous = Map.new(keys, &{&1, Application.fetch_env(:harness_forge, &1)})
    previous_token = System.get_env(@token_env)
    root = Path.join(File.cwd!(), "tmp/mcp-http-#{Ecto.UUID.generate()}")
    id = Ecto.UUID.generate()
    for path <- ~w(artifacts runs tmp), do: File.mkdir_p!(Path.join(root, path))
    Application.put_env(:harness_forge, :workspace_root, root)
    Application.put_env(:harness_forge, :workspace_id, id)
    Application.put_env(:harness_forge, :mcp_enabled, true)
    Application.put_env(:harness_forge, :mcp_token_env, @token_env)
    System.put_env(@token_env, @token)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:harness_forge, key, value)
        {key, :error} -> Application.delete_env(:harness_forge, key)
      end)

      if previous_token,
        do: System.put_env(@token_env, previous_token),
        else: System.delete_env(@token_env)

      File.rm_rf!(root)
    end)

    %{root: root, workspace_id: id}
  end

  test "real endpoint initializes and reads tools without a browser session" do
    initialized = request(initialize(), version: nil)
    assert initialized.status == 200
    assert json(initialized)["result"]["protocolVersion"] == Protocol.version()
    assert get_resp_header(initialized, "mcp-session-id") == []
    assert get_resp_header(initialized, "cache-control") == ["no-store"]
    assert get_resp_header(initialized, "access-control-allow-origin") == []

    notification = request(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
    assert notification.status == 202
    assert notification.resp_body == ""
    assert notification.halted

    tools = request(rpc("tools/list"))
    assert tools.status == 200
    assert length(json(tools)["result"]["tools"]) == 4
    assert request(rpc("ping")).status == 200
  end

  test "every method requires independent enablement and machine authorization" do
    for method <- ~w(POST GET DELETE OPTIONS HEAD PUT PATCH) do
      assert request(rpc("ping"), method: method, authorization: nil).status == 401
    end

    assert request(rpc("ping"), authorization: "Bearer " <> String.duplicate("x", 43)).status ==
             401

    assert request(rpc("ping"), authorization: "Bearer short").status == 401
    assert request(rpc("ping"), authorization: "Basic " <> @token).status == 401

    duplicate =
      raw_conn(Jason.encode!(rpc("ping")))
      |> Map.update!(:req_headers, &[{"authorization", "Bearer " <> @token} | &1])
      |> Endpoint.call([])

    assert duplicate.status == 401
    assert get_resp_header(duplicate, "www-authenticate") == ["Bearer"]

    Application.put_env(:harness_forge, :mcp_enabled, false)
    assert request(rpc("ping")).status == 404
    Application.put_env(:harness_forge, :mcp_enabled, true)

    for reference <- [nil, "", "bad-ref", String.duplicate("A", 129), "HARNESSFORGE_TEST_MISSING"] do
      Application.put_env(:harness_forge, :mcp_token_env, reference)
      assert request(rpc("ping")).status == 401
    end

    Application.put_env(:harness_forge, :mcp_token_env, @token_env)

    for value <- ["", "short", String.duplicate("x", 257), String.duplicate("x", 42) <> "!"] do
      System.put_env(@token_env, value)
      assert request(rpc("ping")).status == 401
    end
  end

  test "only exact local hosts, actual loopback peers and valid supplied Origins are accepted" do
    for origin <- ["https://foreign.example", "null", "http://localhost:4002.evil.example"] do
      assert request(rpc("ping"), origin: origin).status == 403
    end

    assert request(rpc("ping"), origin: "http://localhost:4002").status == 200
    assert request(rpc("ping"), url: "http://rebound.example:4002/mcp").status == 403
    assert request(rpc("ping"), url: "http://localhost:4003/mcp").status == 403

    for {header, value} <- [{"origin", "http://localhost:4002"}, {"host", "localhost:4002"}] do
      conn =
        raw_conn(Jason.encode!(rpc("ping")))
        |> Map.update!(:req_headers, &[{header, value}, {header, value} | &1])
        |> Endpoint.call([])

      assert conn.status == 403
    end

    hostile_host =
      raw_conn(Jason.encode!(rpc("ping")))
      |> Map.update!(:req_headers, &[{"host", "foreign.example:4002"} | &1])
      |> Endpoint.call([])

    assert hostile_host.status == 403

    # remote_ip can be rewritten by proxy plugs; only adapter peer metadata is authoritative.
    foreign_peer =
      raw_conn(Jason.encode!(rpc("ping")))
      |> Plug.Test.put_peer_data(%{address: {203, 0, 113, 1}, port: 1, ssl_cert: nil})
      |> Endpoint.call([])

    assert foreign_peer.remote_ip == {127, 0, 0, 1}
    assert foreign_peer.status == 403
  end

  test "authenticated unsupported methods and strict transport headers fail safely" do
    for method <- ~w(GET DELETE OPTIONS HEAD PUT PATCH) do
      conn = request(rpc("ping"), method: method)
      assert conn.status == 405
      assert get_resp_header(conn, "allow") == ["POST"]
    end

    for version <- [nil, "2026-07-28", "2025-03-26", "2025-11-25,2025-11-25"] do
      assert request(rpc("ping"), version: version).status == 400
    end

    assert request(initialize(), version: "2026-07-28").status == 400

    for type <- [nil, "text/plain", "application/json; charset=iso-8859-1"] do
      assert request(rpc("ping"), content_type: type).status == 415
    end

    for accept <- [
          nil,
          "*/*",
          "application/json",
          "text/event-stream",
          "application/json;q=0, text/event-stream"
        ] do
      assert request(rpc("ping"), accept: accept).status == 406
    end

    assert request(rpc("ping"), content_type: "application/json; charset=utf-8").status == 200

    assert request(rpc("ping"), accept: "text/event-stream;q=0.5, application/json;q=1").status ==
             200
  end

  test "raw duplicate keys, malformed JSON, batches, depth, IDs and body caps are enforced" do
    for body <- [
          ~s({"jsonrpc":"2.0","id":1,"method":"ping","method":"tools/list"}),
          ~s({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"harnessforge_company_plans","arguments":{"limit":1,"limit":20}}}),
          "{broken",
          String.duplicate("[", 18) <> "0" <> String.duplicate("]", 18),
          Jason.encode!([rpc("ping")]),
          Jason.encode!(Map.put(rpc("ping"), "id", nil)),
          Jason.encode!(Map.put(rpc("ping"), "id", false)),
          Jason.encode!(Map.put(rpc("ping"), "id", String.duplicate("a", 129)))
        ] do
      conn = request(body)
      assert conn.status == 400
      assert json(conn)["error"]["code"] in [-32700, -32600]
    end

    assert request(String.duplicate(" ", 65_537)).status == 413

    declared =
      raw_conn(Jason.encode!(rpc("ping")))
      |> put_req_header("content-length", "65537")
      |> Endpoint.call([])

    assert declared.status == 413
  end

  test "errors never reflect supplied secrets, file paths or arbitrary fields" do
    sentinel = "PRIVATE_SENTINEL_/host/private/source.md"

    for message <- [
          rpc("tools/call", %{"name" => sentinel, "arguments" => %{}}),
          rpc("tools/call", %{
            "name" => "harnessforge_search_repositories",
            "arguments" => %{"query" => "", "path" => sentinel}
          }),
          Map.put(rpc("ping"), "extra", sentinel)
        ] do
      conn = request(message)
      assert conn.status in [200, 400]
      refute conn.resp_body =~ sentinel
      refute conn.resp_body =~ @token
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end
  end

  test "unexpected adapter failure retains no-store and returns only a fixed safe error" do
    conn = raw_conn(Jason.encode!(rpc("ping")))
    {_adapter, payload} = conn.adapter
    result = Endpoint.call(%{conn | adapter: {RaisingBodyAdapter, payload}}, [])
    assert result.status == 500
    assert get_resp_header(result, "cache-control") == ["no-store"]
    assert json(result)["error"] == %{"code" => -32603, "message" => "Internal error"}
    refute result.resp_body =~ "PRIVATE_EXCEPTION_SENTINEL"
    refute result.resp_body =~ "/host/private/source.md"
    refute result.resp_body =~ @token
  end

  test "browser epoch rotation deliberately preserves MCP; machine credential rotation revokes it" do
    browser_auth = OperatorSession.new_auth()
    Workspaces.rotate_session_epoch()
    refute OperatorSession.valid?(browser_auth)
    assert request(rpc("ping")).status == 200

    replacement = String.duplicate("ROTATED_", 7)
    System.put_env(@token_env, replacement)
    assert request(rpc("ping")).status == 401
    assert request(rpc("ping"), authorization: "Bearer " <> replacement).status == 200
    System.delete_env(@token_env)
    assert request(rpc("ping"), authorization: "Bearer " <> replacement).status == 401
  end

  test "prepared privacy operation denies every dispatch without company metadata", context do
    {:ok, _} = Company.create_repository(repository("example/private-company"))
    now = DateTime.to_iso8601(DateTime.utc_now())

    Repo.query!(
      "INSERT INTO privacy_operations (id, workspace_id, kind, target_id, state, plan, inserted_at, updated_at) VALUES (?, ?, 'workspace', ?, 'prepared', '{}', ?, ?)",
      [Ecto.UUID.generate(), context.workspace_id, context.workspace_id, now, now]
    )

    conn = request(search("authentication"))
    assert conn.status == 503
    refute conn.resp_body =~ "private-company"
    assert json(conn)["error"]["message"] == "Workspace is temporarily unavailable"
  end

  test "privacy purge waits through the actual response send boundary", context do
    {:ok, _} = Company.create_repository(repository("example/before-purge"))
    parent = self()

    reader =
      Task.async(fn ->
        raw_conn(Jason.encode!(search("authentication")))
        |> register_before_send(fn conn ->
          send(parent, {:response_ready, self(), conn.resp_body})

          receive do
            :dispatch_response -> conn
          after
            5_000 -> raise "test response release timed out"
          end
        end)
        |> Endpoint.call([])
      end)

    assert_receive {:response_ready, reader_pid, encoded}, 2_000
    assert encoded =~ "example/before-purge"

    purger =
      Task.async(fn ->
        send(parent, :purge_attempting)
        result = Privacy.purge_workspace(context.workspace_id)
        send(parent, :purge_completed)
        result
      end)

    assert_receive :purge_attempting
    refute_receive :purge_completed, 100
    send(reader_pid, :dispatch_response)
    assert Task.await(reader, 5_000).status == 200
    assert {:ok, %{"state" => "completed"}} = Task.await(purger, 5_000)
    assert {:ok, []} = Company.list_repositories()

    assert json(request(search("authentication")))["result"]["structuredContent"]["repositories"] ==
             []
  end

  test "queued MCP request reauthenticates after acquiring the privacy fence" do
    parent = self()

    holder =
      Task.async(fn ->
        Purge.synchronize(fn ->
          send(parent, {:fence_held, self()})

          receive do
            :release_fence -> :ok
          after
            5_000 -> raise "test fence release timed out"
          end
        end)
      end)

    assert_receive {:fence_held, holder_pid}
    reader = Task.async(fn -> request(rpc("tools/list")) end)
    refute Task.yield(reader, 100)
    Application.put_env(:harness_forge, :mcp_enabled, false)
    send(holder_pid, :release_fence)
    assert Task.await(holder) == :ok
    assert Task.await(reader, 5_000).status == 404
  end

  test "oversized projected output becomes a fixed error without partial catalogue content" do
    # Twenty legal maximum-length names/owners exceed the response budget once the
    # matching structuredContent and compatibility text representations are encoded.
    for index <- 1..20 do
      attrs =
        repository("example/" <> Integer.to_string(index) <> String.duplicate("x", 900))
        |> Map.put("name", String.duplicate("名", 256))
        |> Map.put("owner", String.duplicate("者", 256))

      assert {:ok, _} = Company.create_repository(attrs)
    end

    conn = request(search("authentication", 20))
    assert conn.status == 500
    assert byte_size(conn.resp_body) < 256
    assert json(conn)["id"] == 1
    assert json(conn)["error"]["message"] == "Response exceeds the permitted size"
    refute conn.resp_body =~ "example/"
    refute conn.resp_body =~ "名"
  end

  defp request(message, opts \\ []) do
    bytes = if is_binary(message), do: message, else: Jason.encode!(message)
    bytes |> raw_conn(opts) |> Endpoint.call([])
  end

  defp raw_conn(bytes, opts \\ []) do
    conn =
      Plug.Test.conn(
        Keyword.get(opts, :method, "POST"),
        Keyword.get(opts, :url, "http://localhost:4002/mcp"),
        bytes
      )

    [
      {"authorization", Keyword.get(opts, :authorization, "Bearer " <> @token)},
      {"content-type", Keyword.get(opts, :content_type, "application/json")},
      {"accept", Keyword.get(opts, :accept, "application/json, text/event-stream")},
      {"mcp-protocol-version", Keyword.get(opts, :version, Protocol.version())},
      {"origin", Keyword.get(opts, :origin)}
    ]
    |> Enum.reduce(conn, fn
      {_key, nil}, acc -> acc
      {key, value}, acc -> put_req_header(acc, key, value)
    end)
  end

  defp initialize do
    rpc("initialize", %{
      "protocolVersion" => Protocol.version(),
      "capabilities" => %{},
      "clientInfo" => %{"name" => "Synthetic HTTP client", "version" => "1.0"}
    })
  end

  defp rpc(method, params \\ %{}),
    do: %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}

  defp search(query, limit \\ 10),
    do:
      rpc("tools/call", %{
        "name" => "harnessforge_search_repositories",
        "arguments" => %{"query" => query, "limit" => limit}
      })

  defp repository(identity),
    do: %{
      "identity" => identity,
      "name" => "Synthetic",
      "purpose" => "Not disclosed",
      "owner" => "Platform",
      "capabilities" => ["authentication"]
    }

  defp json(conn), do: Jason.decode!(conn.resp_body)
end
