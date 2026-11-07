defmodule HarnessForgeWeb.MCPAccessControllerTest do
  use HarnessForgeWeb.ConnCase, async: false
  alias HarnessForge.{CompanyAnalysisFixture, Evidence, Repo, Workspaces}
  alias HarnessForge.Evidence.{Corpora, Passages, Store}
  alias HarnessForge.MCP.Clients
  alias HarnessForgeWeb.Plugs.OperatorSession

  setup %{conn: conn} do
    previous = {Workspaces.root(), Workspaces.current_id()}
    root = Path.join(File.cwd!(), "tmp/mcp-access-web-#{Ecto.UUID.generate()}")
    for dir <- ~w(artifacts runs tmp), do: File.mkdir_p!(Path.join(root, dir))
    Application.put_env(:harness_forge, :workspace_root, root)
    Application.put_env(:harness_forge, :workspace_id, Ecto.UUID.generate())

    on_exit(fn ->
      {old_root, old_id} = previous
      Application.put_env(:harness_forge, :workspace_root, old_root)
      Application.put_env(:harness_forge, :workspace_id, old_id)
      File.rm_rf!(root)
    end)

    auth = OperatorSession.new_auth()

    owner = [
      authorize: fn -> true end,
      session_fingerprint: HarnessForge.Contracts.digest(auth),
      view_generation: String.duplicate("a", 32),
      reset_token: 0
    ]

    fixture = CompanyAnalysisFixture.create!(root)
    {:ok, corpus} = Corpora.create(%{"name" => "Synthetic operator scope"}, owner)

    changes =
      Enum.map(
        fixture.sources,
        &%{
          "source_id" => &1["id"],
          "revision_id" => &1["latest_revision"]["id"],
          "action" => "include"
        }
      )

    {:ok, _} = Corpora.apply_members(corpus["id"], 0, changes, owner)

    for source <- fixture.sources,
        do: {:ok, _} = Passages.index_revision(source["latest_revision"]["id"])

    now = Corpora.now()

    Repo.query!(
      "INSERT INTO company_corpus_bindings(workspace_id,project_id,profile_id,corpus_id,inserted_at,updated_at) VALUES(?,?,?,?,?,?)",
      [Store.workspace(), fixture.project["id"], fixture.profile["id"], corpus["id"], now, now]
    )

    {:ok, current} = Corpora.get(corpus["id"])

    scope = %{
      "corpus_id" => corpus["id"],
      "project_id" => fixture.project["id"],
      "goal_id" => fixture.goal["id"],
      "goal_hash" => fixture.input["goal_content_hash"],
      "expected_generation" => current.semantic_generation
    }

    conn =
      conn
      |> Map.merge(%{host: "localhost", port: 4002})
      |> put_req_header("origin", "http://localhost:4002")
      |> init_test_session(%{"operator_auth" => auth})

    %{conn: conn, scope: scope, fixture: fixture}
  end

  test "exact owner review downloads one private key and revocation withdraws it", c do
    preview = get(c.conn, "/mcp/access?" <> URI.encode_query(c.scope))
    html = html_response(preview, 200)
    assert html =~ "4 current sources selected"
    token = token(html)

    issued =
      post(c.conn, "/mcp/access", %{
        "reviewed" => token,
        "name" => "Local QA",
        "synthetic" => "confirmed"
      })

    assert get_resp_header(issued, "cache-control") == ["no-store"]
    assert get_resp_header(issued, "content-disposition") |> hd() =~ "attachment"
    data = issued |> response(200) |> Jason.decode!()
    "Bearer " <> credential = data["headers"]["Authorization"]
    assert {:ok, _} = Clients.authenticate(credential)
    listing = c.conn |> get("/mcp/access") |> html_response(200)
    assert listing =~ "Local QA"
    refute listing =~ credential
    refute listing =~ "token_hash"

    revoked =
      post(c.conn, "/mcp/access/revoke", %{"kind" => "client", "target_id" => data["client_id"]})

    assert redirected_to(revoked) == "/mcp/access"
    assert {:error, :unauthorized} = Clients.authenticate(credential)
  end

  test "changed sources or missing declaration cannot create clients", c do
    token =
      c.conn |> get("/mcp/access?" <> URI.encode_query(c.scope)) |> html_response(200) |> token()

    rejected = post(c.conn, "/mcp/access", %{"reviewed" => token, "name" => "No declaration"})
    assert response(rejected, 409) =~ "Access changed"
    assert {:ok, _} = Evidence.revoke_connection(c.fixture.connection["id"])

    stale =
      post(c.conn, "/mcp/access", %{
        "reviewed" => token,
        "name" => "Stale",
        "synthetic" => "confirmed"
      })

    assert response(stale, 409) =~ "Access changed"

    assert Repo.query!("SELECT count(*) FROM mcp_clients WHERE workspace_id=?", [
             Store.workspace()
           ]).rows == [[0]]
  end

  test "changed company scope cannot reuse an exact reviewed source decision", c do
    token =
      c.conn |> get("/mcp/access?" <> URI.encode_query(c.scope)) |> html_response(200) |> token()

    assert {:ok, _} =
             HarnessForge.Company.save_profile(
               c.fixture.profile["payload"]
               |> Map.put("name", "Changed after review")
               |> Map.put("expected_content_hash", c.fixture.profile["content_hash"])
             )

    stale =
      post(c.conn, "/mcp/access", %{
        "reviewed" => token,
        "name" => "Stale scope",
        "synthetic" => "confirmed"
      })

    assert response(stale, 409) =~ "Access changed"

    assert Repo.query!("SELECT count(*) FROM mcp_clients WHERE workspace_id=?", [
             Store.workspace()
           ]).rows == [[0]]
  end

  test "login and malformed scope stay bounded", c do
    locked = c.conn |> clear_session() |> get("/mcp/access")
    assert redirected_to(locked) == "/login"

    html =
      c.conn
      |> get(
        "/mcp/access?" <> URI.encode_query(Map.put(c.scope, "expected_generation", "invalid"))
      )
      |> html_response(200)

    assert html =~ "Source selection changed"
    refute html =~ "mcp-access-form"

    forged =
      post(c.conn, "/mcp/access", %{
        "reviewed" => "forged",
        "name" => "Bad",
        "synthetic" => "confirmed"
      })

    assert response(forged, 409) =~ "Access changed"
  end

  defp token(html) do
    [token] =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("input[name=reviewed]")
      |> LazyHTML.attribute("value")

    token
  end
end
