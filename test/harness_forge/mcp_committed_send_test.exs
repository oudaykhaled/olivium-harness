defmodule HarnessForge.MCP.CommittedSendTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  alias Ecto.Adapters.SQL.Sandbox
  alias HarnessForge.{Company, CompanyAnalysisFixture, Contracts, Evidence, Privacy, Repo}
  alias HarnessForge.Evidence.{Corpora, Passages, Store}
  alias HarnessForge.MCP.{Clients, DisclosureGrants}
  alias HarnessForgeWeb.Endpoint

  # Deliberately NOT DataCase: fixtures commit and writer uses an independent
  # plain pool against the same WAL database. Shared Sandbox cannot prove this.
  setup do
    previous =
      Map.new(
        ~w(workspace_root workspace_id mcp_enabled)a,
        &{&1, Application.fetch_env(:harness_forge, &1)}
      )

    root = Path.join(File.cwd!(), "tmp/mcp-committed-#{Ecto.UUID.generate()}")
    id = Ecto.UUID.generate()
    for dir <- ~w(artifacts runs tmp), do: File.mkdir_p!(Path.join(root, dir))
    Application.put_env(:harness_forge, :workspace_root, root)
    Application.put_env(:harness_forge, :workspace_id, id)
    Application.put_env(:harness_forge, :mcp_enabled, true)

    {:ok, writer} =
      Repo.start_link(
        name: nil,
        database: Repo.config()[:database],
        pool: DBConnection.ConnectionPool,
        pool_size: 1,
        busy_timeout: 5000
      )

    Process.unlink(writer)

    fixture =
      Sandbox.unboxed_run(Repo, fn ->
        assert Repo.query!("PRAGMA journal_mode").rows == [["wal"]]
        f = CompanyAnalysisFixture.create!(root)

        {:ok, corpus} =
          Corpora.create(%{"name" => "Committed public synthetic source scope"}, owner())

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

        {:ok, corpus} = Corpora.get(corpus["id"])

        attrs = %{
          "corpus_id" => corpus.id,
          "project_id" => f.project["id"],
          "goal_id" => f.goal["id"],
          "goal_hash" => f.input["goal_content_hash"],
          "expected_generation" => corpus.semantic_generation
        }

        {:ok, client} = Clients.register(%{"name" => "Committed synthetic local reader"}, owner())
        {:ok, preview} = DisclosureGrants.preview(attrs, owner())

        {:ok, grant} =
          DisclosureGrants.issue(
            Map.merge(attrs, %{
              "client_id" => client["client_id"],
              "profile" => preview["profile"],
              "members" => preview["members"],
              "ttl_seconds" => 3600
            }),
            owner()
          )

        %{fixture: f, client: client, grant: grant}
      end)

    on_exit(fn ->
      if Process.alive?(writer), do: Supervisor.stop(writer)

      assert {:ok, %{"state" => "completed"}} =
               Sandbox.unboxed_run(Repo, fn -> Privacy.purge_workspace(id) end)

      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:harness_forge, key, value)
        {key, :error} -> Application.delete_env(:harness_forge, key)
      end)

      File.rm_rf!(root)
    end)

    Map.put(fixture, :writer, writer)
  end

  test "independent source revocation cannot commit between authorization and send", c do
    assert_serialized(c, fn -> Evidence.revoke_source(hd(c.fixture.sources)["id"]) end)
  end

  test "independent connection revocation cannot commit between authorization and send", c do
    assert_serialized(c, fn -> Evidence.revoke_connection(c.fixture.connection["id"]) end)
  end

  test "independent changed revision cannot commit between authorization and send", c do
    source = hd(c.fixture.sources)

    assert_serialized(c, fn ->
      Evidence.import_markdown(c.fixture.connection["id"], %{
        "external_id" => source["external_id"],
        "title" => source["title"],
        "body" => "Changed synthetic policy after the response."
      })
    end)
  end

  test "independent project change cannot commit between authorization and send", c do
    assert_serialized(c, fn ->
      Company.update_project(
        c.fixture.project["id"],
        c.fixture.project["payload"]
        |> Map.put("name", "Changed synthetic project")
        |> Map.put("expected_content_hash", c.fixture.project["content_hash"])
      )
    end)
  end

  defp assert_serialized(c, mutation) do
    parent = self()

    reader =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          conn(c)
          |> register_before_send(fn conn ->
            send(parent, {:final_send_waiting, self()})

            receive do
              :finish_send -> conn
            after
              5000 -> raise "committed send release timed out"
            end
          end)
          |> Endpoint.call([])
        end)
      end)

    assert_receive {:final_send_waiting, reader_pid}, 3000

    writer =
      Task.async(fn ->
        send(parent, :independent_writer_started)
        mutate(c.writer, mutation)
      end)

    assert_receive :independent_writer_started

    # A deferred read/write transaction may immediately fail its lock upgrade;
    # a writer that waits must remain uncommitted until the final send returns.
    waiting = Task.yield(writer, 100)

    assert waiting in [nil, {:ok, :database_busy}],
           "WAL writer committed while final immediate reservation was held"

    send(reader_pid, :finish_send)
    assert Task.await(reader, 5000).status == 200
    result = if waiting, do: :database_busy, else: Task.await(writer, 5000)
    assert {:ok, _} = if(result == :database_busy, do: mutate(c.writer, mutation), else: result)
    # Revalidation after the committed mutation must withdraw later disclosures.
    assert Sandbox.unboxed_run(Repo, fn -> conn(c) |> Endpoint.call([]) end).status == 401
  end

  defp mutate(writer, mutation) do
    old = Repo.put_dynamic_repo(writer)

    try do
      mutation.()
    rescue
      error in Exqlite.Error ->
        if error.message == "Database busy",
          do: :database_busy,
          else: reraise(error, __STACKTRACE__)
    after
      Repo.put_dynamic_repo(old)
    end
  end

  defp conn(c) do
    request = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{"name" => "harnessforge_browse_sources", "arguments" => %{}}
    }

    Plug.Test.conn("POST", "http://localhost:4002/mcp", Jason.encode!(request))
    |> put_req_header("authorization", "Bearer " <> c.client["credential"])
    |> put_req_header("x-harnessforge-disclosure-grant", c.grant["id"])
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> put_req_header("mcp-protocol-version", "2025-11-25")
  end

  defp owner,
    do: [
      authorize: fn -> true end,
      session_fingerprint: Contracts.sha256("committed synthetic disclosure owner"),
      view_generation: String.duplicate("d", 32),
      reset_token: 0
    ]
end
