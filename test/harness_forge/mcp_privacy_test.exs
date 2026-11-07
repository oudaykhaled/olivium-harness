defmodule HarnessForge.MCP.PrivacyTest do
  use ExUnit.Case, async: false

  alias Exqlite.Sqlite3
  alias HarnessForge.{Company, CompanyAnalysisFixture, Contracts, Privacy, Repo, Workspaces}
  alias HarnessForge.Evidence.{Corpora, Passages, Store}
  alias HarnessForge.MCP.{Clients, DisclosureGrants}

  @tables ~w(mcp_clients mcp_disclosure_grants mcp_disclosure_grant_items)

  setup tags do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: tags[:committed] != true)
    previous = {Workspaces.current_id(), Workspaces.root()}
    id = Ecto.UUID.generate()
    base = Path.join(File.cwd!(), "tmp/mcp-privacy-#{id}")
    root = Path.join(base, "workspace")
    for dir <- ~w(artifacts runs tmp), do: File.mkdir_p!(Path.join(root, dir))
    Application.put_env(:harness_forge, :workspace_id, id)
    Application.put_env(:harness_forge, :workspace_root, root)

    on_exit(fn ->
      if tags[:committed] do
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          Application.put_env(:harness_forge, :workspace_id, id)
          Application.put_env(:harness_forge, :workspace_root, root)
          assert {:ok, _} = Privacy.purge_workspace(id)
        end)
      end

      {old_id, old_root} = previous
      Application.put_env(:harness_forge, :workspace_id, old_id)
      Application.put_env(:harness_forge, :workspace_root, old_root)
      File.rm_rf!(base)
    end)

    fixture = CompanyAnalysisFixture.create!(root)
    authority = issue(fixture, Enum.take(fixture.sources, 2))
    %{id: id, base: base, root: root, fixture: fixture, authority: authority}
  end

  test "inventory and workspace purge scope clients, grants and joined items to their workspace",
       c do
    foreign_id = Ecto.UUID.generate()
    foreign = copy_to_workspace(c.authority, foreign_id)
    foreign_before = authority_records(foreign)

    assert {:ok, inventory} = Privacy.inventory()
    assert inventory["records"]["mcp_clients"] == 1
    assert inventory["records"]["mcp_disclosure_grants"] == 1
    assert inventory["records"]["mcp_disclosure_grant_items"] == 2
    assert {:ok, _} = Privacy.purge_workspace(c.id)
    assert {:ok, inventory} = Privacy.inventory()
    for table <- @tables, do: assert(inventory["records"][table] == 0)
    assert authority_records(foreign) == foreign_before
    assert {:error, :unauthorized} = Clients.authenticate(c.authority.client["credential"])
    assert Repo.query!("PRAGMA foreign_key_check").rows == []
  end

  test "source purge freezes whole historical grants and preserves unrelated client decisions",
       c do
    [source, _, other, unrelated] = c.fixture.sources
    historical = issue(c.fixture, [source, other])
    retained = issue(c.fixture, [unrelated])
    retained_before = authority_records(retained)

    # A historical exact grant can outlive every relational membership row.
    Repo.query!("DELETE FROM corpus_members WHERE workspace_id=? AND corpus_id=?", [
      c.id,
      historical.corpus_id
    ])

    assert {:ok, %{"state" => "completed"}} = Privacy.purge_source(source["id"], source["id"])

    for authority <- [c.authority, historical] do
      assert Repo.query!("SELECT count(*) FROM mcp_disclosure_grants WHERE id=?", [
               authority.grant["id"]
             ]).rows == [[0]]

      assert Repo.query!("SELECT count(*) FROM mcp_disclosure_grant_items WHERE grant_id=?", [
               authority.grant["id"]
             ]).rows == [[0]]

      assert {:ok, _} = Clients.authenticate(authority.client["credential"])
    end

    assert authority_records(retained) == retained_before
    assert {:ok, _} = Clients.authenticate(retained.client["credential"])
    assert Repo.query!("PRAGMA foreign_key_check").rows == []
    assert :ok = Privacy.ready()
  end

  @tag :committed
  test "committed backup excludes verifiers and restore also scrubs older active and revoked authority",
       c do
    revoked = issue(c.fixture, [List.last(c.fixture.sources)])
    assert {:ok, _} = DisclosureGrants.revoke(revoked.grant["id"], owner())
    assert {:ok, _} = Clients.revoke(revoked.client["client_id"], owner())
    retained = authority_records(c.authority) ++ authority_records(revoked)
    backup = Path.join(c.base, "backup")
    restored = Path.join(c.base, "restored")

    assert {:ok, _} = Privacy.backup(backup)
    assert {:ok, _} = Privacy.verify_backup(backup)
    for table <- @tables, do: assert(db_rows(backup, "SELECT count(*) FROM #{table}") == [[0]])

    bytes = File.read!(Path.join(backup, "data.sqlite3"))

    for authority <- [c.authority, revoked] do
      refute bytes =~ authority.client["credential"]
      refute bytes =~ Store.hash(authority.client["credential"])
    end

    assert {:ok, _} = Clients.authenticate(c.authority.client["credential"])

    # Model a valid pre-scrub backup: restore must independently withdraw its
    # authority instead of trusting that the producer removed credential rows.
    with_database(backup, fn conn ->
      :ok = Sqlite3.execute(conn, "PRAGMA foreign_keys=ON")

      Enum.each(retained, fn {table, columns, rows} ->
        insert_records(table, columns, rows, conn)
      end)
    end)

    rehash_database(backup)
    assert {:ok, _} = Privacy.verify_backup(backup)

    assert {:ok, %{"workspace_id" => restored_id, "approvals_restored" => false}} =
             Privacy.restore(backup, restored)

    refute restored_id == c.id
    for table <- @tables, do: assert(db_rows(restored, "SELECT count(*) FROM #{table}") == [[0]])
    assert db_rows(restored, "PRAGMA foreign_key_check") == []
    assert db_rows(backup, "SELECT count(*) FROM mcp_clients") == [[2]]
    refute File.exists?(Path.join(restored, "access-token"))

    {:ok, restored_repo} =
      Repo.start_link(
        name: nil,
        database: Path.join(restored, "data.sqlite3"),
        pool: DBConnection.ConnectionPool,
        pool_size: 1
      )

    old_repo = Repo.put_dynamic_repo(restored_repo)
    Application.put_env(:harness_forge, :workspace_id, restored_id)
    Application.put_env(:harness_forge, :workspace_root, restored)

    try do
      for authority <- [c.authority, revoked],
          do:
            assert(
              {:error, :unauthorized} == Clients.authenticate(authority.client["credential"])
            )

      assert {:ok, inventory} = Privacy.inventory()
      for table <- @tables, do: assert(inventory["records"][table] == 0)
    after
      Repo.put_dynamic_repo(old_repo)
      Supervisor.stop(restored_repo)
      Application.put_env(:harness_forge, :workspace_id, c.id)
      Application.put_env(:harness_forge, :workspace_root, c.root)
    end
  end

  defp issue(fixture, sources) do
    name = "Synthetic privacy recipient #{Ecto.UUID.generate()}"
    {:ok, corpus} = Corpora.create(%{"name" => name}, owner())

    changes =
      Enum.map(sources, fn source ->
        %{
          "source_id" => source["id"],
          "revision_id" => source["latest_revision"]["id"],
          "action" => "include"
        }
      end)

    {:ok, _} = Corpora.apply_members(corpus["id"], 0, changes, owner())
    for source <- sources, do: {:ok, _} = Passages.index_revision(source["latest_revision"]["id"])

    {:ok, project} =
      Company.create_project(%{
        "name" => name,
        "repository_ids" => [fixture.repository["id"]],
        "source_ids" => Enum.map(sources, & &1["id"])
      })

    now = Corpora.now()

    Repo.query!(
      "INSERT INTO company_corpus_bindings(workspace_id,project_id,profile_id,corpus_id,inserted_at,updated_at) VALUES(?,?,?,?,?,?)",
      [Store.workspace(), project["id"], fixture.profile["id"], corpus["id"], now, now]
    )

    {:ok, current} = Corpora.get(corpus["id"])

    attrs = %{
      "corpus_id" => corpus["id"],
      "project_id" => project["id"],
      "goal_id" => fixture.goal["id"],
      "goal_hash" => fixture.input["goal_content_hash"],
      "expected_generation" => current.semantic_generation
    }

    {:ok, client} = Clients.register(%{"name" => name}, owner())
    {:ok, preview} = DisclosureGrants.preview(attrs, owner())

    {:ok, grant} =
      DisclosureGrants.issue(
        Map.merge(attrs, %{
          "client_id" => client["client_id"],
          "members" => preview["members"],
          "profile" => preview["profile"],
          "ttl_seconds" => 3600
        }),
        owner()
      )

    %{client: client, grant: grant, corpus_id: corpus["id"]}
  end

  defp authority_records(authority) do
    Enum.map(
      [
        {"mcp_clients", "id", authority.client["client_id"]},
        {"mcp_disclosure_grants", "id", authority.grant["id"]},
        {"mcp_disclosure_grant_items", "grant_id", authority.grant["id"]}
      ],
      fn {table, column, id} ->
        result =
          Repo.query!("SELECT * FROM #{table} WHERE #{column}=? ORDER BY 1,2", [id], log: false)

        {table, result.columns, result.rows}
      end
    )
  end

  defp copy_to_workspace(authority, workspace_id) do
    client_id = Ecto.UUID.generate()
    grant_id = Ecto.UUID.generate()

    Enum.each(authority_records(authority), fn {table, columns, rows} ->
      rows =
        Enum.map(rows, fn row ->
          Enum.zip(columns, row)
          |> Enum.map(fn
            {"workspace_id", _} -> workspace_id
            {"client_id", _} -> client_id
            {"grant_id", _} -> grant_id
            {"id", _} when table == "mcp_clients" -> client_id
            {"id", _} -> grant_id
            {_, value} -> value
          end)
        end)

      insert_records(table, columns, rows)
    end)

    %{client: %{"client_id" => client_id}, grant: %{"id" => grant_id}}
  end

  defp insert_records(table, columns, rows, conn \\ nil) do
    marks = Enum.map_join(columns, ",", fn _ -> "?" end)
    query = "INSERT INTO #{table}(#{Enum.join(columns, ",")}) VALUES(#{marks})"

    Enum.each(rows, fn row ->
      if conn, do: sql(conn, query, row), else: Repo.query!(query, row, log: false)
    end)
  end

  defp rehash_database(backup) do
    bytes = File.read!(Path.join(backup, "data.sqlite3"))
    path = Path.join(backup, "manifest.json")
    manifest = path |> File.read!() |> Jason.decode!()

    files =
      Enum.map(manifest["files"], fn
        %{"path" => "data.sqlite3"} = entry ->
          Map.merge(entry, %{"bytes" => byte_size(bytes), "sha256" => Contracts.sha256(bytes)})

        entry ->
          entry
      end)

    File.write!(path, Contracts.canonical_json(Map.put(manifest, "files", files)))
  end

  defp db_rows(root, query), do: with_database(root, &sql(&1, query, []))

  defp with_database(root, fun) do
    {:ok, conn} = Sqlite3.open(Path.join(root, "data.sqlite3"))

    try do
      fun.(conn)
    after
      Sqlite3.close(conn)
    end
  end

  defp sql(conn, query, params) do
    {:ok, statement} = Sqlite3.prepare(conn, query)

    try do
      :ok = Sqlite3.bind(statement, params)
      {:ok, rows} = Sqlite3.fetch_all(conn, statement)
      rows
    after
      Sqlite3.release(conn, statement)
    end
  end

  defp owner,
    do: [
      authorize: fn -> true end,
      session_fingerprint: Contracts.sha256("synthetic privacy owner"),
      view_generation: String.duplicate("b", 32),
      reset_token: 0
    ]
end
