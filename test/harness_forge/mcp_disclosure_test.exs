defmodule HarnessForge.MCP.DisclosureTest do
  use HarnessForge.DataCase, async: false
  import Plug.Conn
  alias HarnessForge.{CompanyAnalysisFixture, Contracts, Evidence, Repo}
  alias HarnessForge.Company.Retrieval
  alias HarnessForge.Evidence.{Corpora, Passages, Store}
  alias HarnessForge.MCP.{Auth, ClientContext, Clients, DisclosureGrants, Protocol, Tools}
  alias HarnessForgeWeb.Endpoint

  setup do
    previous =
      Map.new(
        ~w(workspace_root workspace_id mcp_enabled)a,
        &{&1, Application.fetch_env(:harness_forge, &1)}
      )

    root = Path.join(File.cwd!(), "tmp/mcp-disclosure-#{Ecto.UUID.generate()}")
    for dir <- ~w(artifacts runs tmp), do: File.mkdir_p!(Path.join(root, dir))
    Application.put_env(:harness_forge, :workspace_root, root)
    Application.put_env(:harness_forge, :workspace_id, Ecto.UUID.generate())
    Application.put_env(:harness_forge, :mcp_enabled, true)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:harness_forge, key, value)
        {key, :error} -> Application.delete_env(:harness_forge, key)
      end)

      File.rm_rf!(root)
    end)

    f = CompanyAnalysisFixture.create!(root)

    {:ok, corpus} =
      Corpora.create(%{"name" => "Explicit public synthetic client fixture"}, owner())

    changes =
      Enum.map(
        f.sources,
        &%{
          "source_id" => &1["id"],
          "revision_id" => &1["latest_revision"]["id"],
          "action" => "include"
        }
      )

    {:ok, _} = Corpora.apply_members(corpus["id"], 0, changes, owner())

    for source <- f.sources,
        do: {:ok, _} = Passages.index_revision(source["latest_revision"]["id"])

    now = Corpora.now()

    Repo.query!(
      "INSERT INTO company_corpus_bindings(workspace_id,project_id,profile_id,corpus_id,inserted_at,updated_at) VALUES(?,?,?,?,?,?)",
      [Store.workspace(), f.project["id"], f.profile["id"], corpus["id"], now, now]
    )

    {:ok, current} = Corpora.get(corpus["id"])

    attrs = %{
      "corpus_id" => corpus["id"],
      "project_id" => f.project["id"],
      "goal_id" => f.goal["id"],
      "goal_hash" => f.input["goal_content_hash"],
      "expected_generation" => current.semantic_generation
    }

    {:ok, client} = Clients.register(%{"name" => "Synthetic local inspection recipient"}, owner())
    {:ok, preview} = DisclosureGrants.preview(attrs, owner())

    issue =
      Map.merge(attrs, %{
        "client_id" => client["client_id"],
        "members" => preview["members"],
        "profile" => preview["profile"],
        "ttl_seconds" => 3600
      })

    {:ok, grant} = DisclosureGrants.issue(issue, owner())
    {:ok, context} = Auth.context(conn(rpc("tools/list"), client, grant))
    %{fixture: f, attrs: attrs, client: client, grant: grant, context: context, issue: issue}
  end

  test "owner-issued client reads actual FTS citations with separate disclosure authority", c do
    assert length(Tools.list()) == 4
    assert length(Tools.list(c.context)) == 5
    assert {:error, :unknown_tool} = Tools.call("harnessforge_company_plans", %{}, c.context)
    refute Enum.any?(Tools.list(c.context), &(&1["name"] == "harnessforge_graph_neighborhood"))

    assert {:ok, result} =
             Tools.call(
               "harnessforge_retrieve_evidence",
               %{"question" => "Which release records require review?"},
               c.context
             )

    bundle = result["evidence_bundle"]
    assert bundle["admission_basis"] == "owner_issued_synthetic_local_inspection"
    assert bundle["positive_purpose_policy"] == "unknown"
    assert bundle["history"]["historical_eligibility"] == "unavailable"
    assert bundle["client_disclosure"]["grant_digest"] == c.grant["revision_hash"]
    assert Repo.get!(HarnessForge.Company.RetrievalRun, result["run_id"]).envelope["version"] == 4
    assert [citation | _] = bundle["citations"]

    args =
      Map.merge(
        %{"run_id" => result["run_id"], "run_digest" => result["digest"]},
        Map.take(citation, ~w(passage_id citation_digest))
      )

    response =
      conn(
        rpc("tools/call", %{"name" => "harnessforge_read_citation", "arguments" => args}),
        c.client,
        c.grant
      )
      |> Endpoint.call([])

    assert response.status == 200
    body = Jason.decode!(response.resp_body)["result"]["structuredContent"]
    assert body["citation_digest"] == citation["citation_digest"]
    assert body["snippet_hash"] == Contracts.sha256(body["snippet"])
    source = Enum.find(c.fixture.sources, &(&1["id"] == body["source_id"]))

    assert binary_part(
             source["latest_revision"]["body"],
             body["start_byte"],
             body["end_byte"] - body["start_byte"]
           ) == body["snippet"]

    assert get_resp_header(response, "cache-control") == ["no-store"]
    refute response.resp_body =~ c.client["credential"]
    assert Repo.query!("SELECT count(*) FROM model_requests").rows == [[0]]
  end

  test "exact disclosure profile and full immutable member list are mandatory", c do
    before = Repo.query!("SELECT count(*) FROM mcp_disclosure_grants").rows

    for update <- [
          %{"members" => tl(c.issue["members"])},
          %{"members" => Enum.reverse(c.issue["members"])},
          %{"profile" => Map.put(DisclosureGrants.profile(), "purpose", "inference")},
          %{"ttl_seconds" => 3601},
          %{"ttl_seconds" => 0},
          %{"principal" => "operator"},
          %{"expected_generation" => c.attrs["expected_generation"] + 1}
        ] do
      assert {:error, _} = DisclosureGrants.issue(Map.merge(c.issue, update), owner())
    end

    assert {:error, :operator_session_revoked} =
             DisclosureGrants.issue(c.issue, Keyword.put(owner(), :authorize, fn -> false end))

    assert Repo.query!("SELECT count(*) FROM mcp_disclosure_grants").rows == before
  end

  test "owner lists exclude verifiers and outer issuance rollback removes a new client", c do
    assert {:ok, %{"clients" => [client], "truncated" => false}} = Clients.list(owner())
    assert client["id"] == c.client["client_id"]
    refute Map.has_key?(client, "token_hash")
    assert {:ok, %{"grants" => [grant], "truncated" => false}} = DisclosureGrants.list(owner())
    assert grant["id"] == c.grant["id"]
    refute inspect(grant) =~ c.client["credential"]
    before = Repo.query!("SELECT count(*) FROM mcp_clients").rows

    assert {:error, :invalid_disclosure_grant} =
             Corpora.guard(owner(), fn ->
               with {:ok, client} <- Clients.register(%{"name" => "Must roll back"}, owner()),
                    {:ok, grant} <-
                      DisclosureGrants.issue(
                        c.issue
                        |> Map.put("client_id", client["client_id"])
                        |> Map.put("members", []),
                        owner()
                      ),
                    do: {:ok, grant}
             end)

    assert Repo.query!("SELECT count(*) FROM mcp_clients").rows == before
  end

  test "client authority cannot mutate corpora or become operator/inference authority", c do
    assert {:error, _} = Corpora.create(%{"name" => "No machine mutation"}, c.context)
    assert {:error, _} = Retrieval.retrieve(Map.put(c.attrs, "mode", "fts"), c.context)

    assert {:error, _} =
             Tools.call(
               "harnessforge_retrieve_evidence",
               %{"question" => "review", "corpus_id" => Ecto.UUID.generate()},
               c.context
             )

    assert {:ok, result} =
             Tools.call("harnessforge_retrieve_evidence", %{"question" => "review"}, c.context)

    assert {:error, _} =
             Retrieval.read_evidence_summary(result["run_id"], result["digest"], owner())

    assert {:error, _} =
             Retrieval.resolve_for_analysis(result["run_id"], result["digest"], owner())

    operator_input = Map.put(c.attrs, "question", "review")
    assert {:ok, original} = Retrieval.retrieve_evidence(operator_input, owner())
    assert original["evidence_bundle"]["admission_basis"] == "legacy_operator_current_inspection"

    assert {:error, _} =
             Retrieval.read_evidence_summary(original["run_id"], original["digest"], c.context)
  end

  test "another client, grant, corpus and forged context cannot reuse the evidence binding", c do
    {:ok, result} =
      Tools.call("harnessforge_retrieve_evidence", %{"question" => "review"}, c.context)

    {:ok, second} = Clients.register(%{"name" => "Other recipient"}, owner())
    assert {:error, :unauthorized} = Auth.context(conn(rpc("tools/list"), second, c.grant))
    assert {:ok, grant2} = DisclosureGrants.issue(c.issue, owner())
    assert {:ok, context2} = Auth.context(conn(rpc("tools/list"), c.client, grant2))

    assert {:error, _} =
             Retrieval.read_evidence_summary(result["run_id"], result["digest"], context2)

    forged = %{c.context | scope: Map.put(c.context.scope, "corpus_id", Ecto.UUID.generate())}
    assert {:error, _} = ClientContext.authorize(forged)
    assert {:error, _} = Tools.call("harnessforge_connection_coverage", %{}, forged)
  end

  test "grant/client revocation, expiry and changed source withdraw old snapshots", c do
    {:ok, result} =
      Tools.call("harnessforge_retrieve_evidence", %{"question" => "review"}, c.context)

    assert {:ok, _} = DisclosureGrants.revoke(c.grant["id"], owner())

    assert {:error, _} =
             Retrieval.read_evidence(result["run_id"], result["digest"], %{}, c.context)

    assert (conn(rpc("tools/list"), c.client, c.grant) |> Endpoint.call([])).status == 401
    {:ok, grant2} = DisclosureGrants.issue(c.issue, owner())
    assert {:ok, context2} = Auth.context(conn(rpc("tools/list"), c.client, grant2))
    Repo.query!("UPDATE mcp_disclosure_grants SET expires_at=0 WHERE id=?", [grant2["id"]])
    assert {:error, _} = ClientContext.authorize(context2)
    {:ok, grant3} = DisclosureGrants.issue(c.issue, owner())
    assert {:ok, context3} = Auth.context(conn(rpc("tools/list"), c.client, grant3))
    assert {:ok, _} = Evidence.revoke_source(hd(c.fixture.sources)["id"])
    assert {:error, _} = ClientContext.authorize(context3)
    assert {:ok, _} = Clients.revoke(c.client["client_id"], owner())
    assert {:error, _} = Clients.authenticate(c.client["credential"])
  end

  test "unsupported remote source fails closed before disclosure", c do
    source = hd(c.fixture.sources)

    Repo.query!("UPDATE source_connections SET provider='github' WHERE id=?", [
      source["connection_id"]
    ])

    assert {:error, _} = ClientContext.authorize(c.context)
    assert {:error, _} = DisclosureGrants.preview(c.attrs, owner())

    assert (conn(
              rpc("tools/call", %{"name" => "harnessforge_browse_sources", "arguments" => %{}}),
              c.client,
              c.grant
            )
            |> Endpoint.call([])).status == 401
  end

  test "source computation leaves revocation unblocked and never sends late bytes", c do
    parent = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:harness_forge, :mcp, :source_response],
        fn _, _, _, _ ->
          send(parent, {:source_computed, self()})

          receive do
            :continue_source_send -> :ok
          after
            5000 -> raise "source response test release timed out"
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    reader =
      Task.async(fn ->
        conn(
          rpc("tools/call", %{
            "name" => "harnessforge_retrieve_evidence",
            "arguments" => %{"question" => "review"}
          }),
          c.client,
          c.grant
        )
        |> Endpoint.call([])
      end)

    assert_receive {:source_computed, reader_pid}, 3000
    # This must finish while response computation is paused outside the fence.
    revoker = Task.async(fn -> DisclosureGrants.revoke(c.grant["id"], owner()) end)
    assert {:ok, _} = Task.await(revoker, 2000)
    send(reader_pid, :continue_source_send)
    response = Task.await(reader, 3000)
    assert response.status == 401
    refute response.resp_body =~ "Every production change"
    refute response.resp_body =~ "selected_count"
    refute response.resp_body =~ "evidence_bundle"
  end

  test "revocation shares the final-send fence", c do
    parent = self()

    reader =
      Task.async(fn ->
        conn(
          rpc("tools/call", %{"name" => "harnessforge_browse_sources", "arguments" => %{}}),
          c.client,
          c.grant
        )
        |> register_before_send(fn conn ->
          send(parent, {:sending, self()})

          receive do
            :finish_send -> conn
          after
            5000 -> raise "send test release timed out"
          end
        end)
        |> Endpoint.call([])
      end)

    assert_receive {:sending, reader_pid}, 3000
    revoker = Task.async(fn -> DisclosureGrants.revoke(c.grant["id"], owner()) end)
    refute Task.yield(revoker, 100)
    send(reader_pid, :finish_send)
    assert Task.await(reader, 3000).status == 200
    assert {:ok, _} = Task.await(revoker, 3000)
    assert (conn(rpc("tools/list"), c.client, c.grant) |> Endpoint.call([])).status == 401
  end

  test "oversized source response never sends partial source data", c do
    # Exercise the machine response path with hostile persisted display data.
    # The exact revision/body and granted membership are unchanged.
    for source <- c.fixture.sources do
      Repo.query!("UPDATE evidence_sources SET title=? WHERE id=?", [
        String.duplicate("機", 12000),
        source["id"]
      ])
    end

    response =
      conn(
        rpc("tools/call", %{"name" => "harnessforge_browse_sources", "arguments" => %{}}),
        c.client,
        c.grant
      )
      |> Endpoint.call([])

    assert response.status == 500
    assert byte_size(response.resp_body) < 256

    assert Jason.decode!(response.resp_body)["error"]["message"] ==
             "Response exceeds the permitted size"

    refute response.resp_body =~ "機"
    refute response.resp_body =~ hd(c.fixture.sources)["id"]
  end

  test "legitimate escaped Unicode pages shrink without skipping rows or replaying cursors", c do
    extra =
      for index <- 1..12 do
        assert {:ok, source} =
                 Evidence.import_markdown(c.fixture.connection["id"], %{
                   "external_id" => "escaped-#{index}.md",
                   "title" => String.duplicate("名\\\"\n", 1000),
                   "body" => "review " <> String.duplicate("é\\\"\n", 300)
                 })

        source
      end

    {:ok, corpus} = Corpora.get(c.attrs["corpus_id"])

    changes =
      Enum.map(
        extra,
        &%{
          "source_id" => &1["id"],
          "revision_id" => &1["latest_revision"]["id"],
          "action" => "include"
        }
      )

    assert {:ok, _} =
             Corpora.apply_members(corpus.id, corpus.semantic_generation, changes, owner())

    for source <- extra,
        do: assert({:ok, _} = Passages.index_revision(source["latest_revision"]["id"]))

    {:ok, corpus} = Corpora.get(corpus.id)
    attrs = Map.put(c.attrs, "expected_generation", corpus.semantic_generation)
    {:ok, preview} = DisclosureGrants.preview(attrs, owner())

    {:ok, grant} =
      DisclosureGrants.issue(
        Map.merge(attrs, %{
          "client_id" => c.client["client_id"],
          "members" => preview["members"],
          "profile" => preview["profile"],
          "ttl_seconds" => 3600
        }),
        owner()
      )

    current = %{c | grant: grant}
    {source_rows, source_shrank?} = pages(current, "harnessforge_browse_sources", %{})
    assert source_shrank?

    assert Enum.sort(Enum.map(source_rows, & &1["source_id"])) ==
             Enum.sort(Enum.map(c.fixture.sources ++ extra, & &1["id"]))

    response =
      conn(
        rpc("tools/call", %{
          "name" => "harnessforge_retrieve_evidence",
          "arguments" => %{"question" => "review"}
        }),
        c.client,
        grant
      )
      |> Endpoint.call([])

    assert response.status == 200
    result = Jason.decode!(response.resp_body)["result"]["structuredContent"]
    assert result["evidence_bundle"]["citations"] != []
    args = %{"run_id" => result["run_id"], "run_digest" => result["digest"]}
    {evidence_rows, evidence_shrank?} = pages(current, "harnessforge_evidence_page", args)
    assert evidence_shrank?

    expected =
      Repo.query!("SELECT passage_id FROM retrieval_items WHERE run_id=? ORDER BY passage_id", [
        result["run_id"]
      ]).rows
      |> List.flatten()

    assert Enum.sort(Enum.map(evidence_rows, & &1["passage_id"])) == expected
  end

  test "a caller-owned transaction cannot bypass the top-level final writer reservation", c do
    assert {:ok, response} =
             Repo.transaction(fn ->
               conn(rpc("tools/list"), c.client, c.grant) |> Endpoint.call([])
             end)

    assert response.status == 503
    refute response.resp_body =~ "harnessforge_browse_sources"
  end

  defp pages(c, name, args, cursor \\ nil, seen \\ MapSet.new(), rows \\ [], shrank? \\ false) do
    args = if cursor, do: Map.put(args, "cursor", cursor), else: args

    response =
      conn(rpc("tools/call", %{"name" => name, "arguments" => args}), c.client, c.grant)
      |> Endpoint.call([])

    assert response.status == 200
    assert byte_size(response.resp_body) <= 65_536
    result = Jason.decode!(response.resp_body)["result"]
    refute result["isError"]
    page = result["structuredContent"]
    assert length(page["rows"]) in 1..8
    next = page["next_cursor"]
    shrank? = shrank? or (is_binary(next) and length(page["rows"]) < 8)

    if next do
      refute MapSet.member?(seen, next)
      assert MapSet.size(seen) < 100

      pages(
        c,
        name,
        Map.delete(args, "cursor"),
        next,
        MapSet.put(seen, next),
        rows ++ page["rows"],
        shrank?
      )
    else
      {rows ++ page["rows"], shrank?}
    end
  end

  defp conn(request, client, grant) do
    Plug.Test.conn("POST", "http://localhost:4002/mcp", Jason.encode!(request))
    |> put_req_header("authorization", "Bearer " <> client["credential"])
    |> put_req_header("x-harnessforge-disclosure-grant", grant["id"])
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> put_req_header("mcp-protocol-version", Protocol.version())
  end

  defp rpc(method, params \\ %{}),
    do: %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}

  defp owner,
    do: [
      authorize: fn -> true end,
      session_fingerprint: Contracts.sha256("public synthetic disclosure owner"),
      view_generation: String.duplicate("c", 32),
      reset_token: 0
    ]
end
