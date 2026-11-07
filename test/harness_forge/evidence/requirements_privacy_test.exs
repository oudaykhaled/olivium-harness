defmodule HarnessForge.Evidence.RequirementsPrivacyTest do
  use ExUnit.Case, async: false

  alias Exqlite.Sqlite3
  alias HarnessForge.{Company, CompanyAnalysisFixture, Contracts, Evidence, Goals, Privacy, Repo}
  alias HarnessForge.Evidence.Corpora

  @triggers ~w(immutable_corpus_requirements_delete immutable_corpus_requirements_update)
  @record "SELECT id,workspace_id,corpus_id,project_id,goal_id,revision,digest,payload FROM corpus_requirements WHERE id=?"
  @trigger_sql "SELECT name,sql FROM sqlite_master WHERE type='trigger' AND tbl_name='corpus_requirements' ORDER BY name"

  setup tags do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: tags[:committed] != true)

    previous =
      Map.new([:workspace_id, :workspace_root], &{&1, Application.get_env(:harness_forge, &1)})

    id = Ecto.UUID.generate()
    base = Path.join(File.cwd!(), "tmp/requirements-privacy-#{id}")
    root = Path.join(base, "workspace")
    Enum.each(["", "artifacts", "runs", "tmp"], &File.mkdir_p!(Path.join(root, &1)))
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

      Enum.each(previous, fn {key, value} ->
        if is_nil(value),
          do: Application.delete_env(:harness_forge, key),
          else: Application.put_env(:harness_forge, key, value)
      end)

      File.rm_rf!(base)
    end)

    fixture = CompanyAnalysisFixture.create!(root)
    {:ok, corpus} = Corpora.create(%{"name" => "Synthetic declaration privacy"}, caller())

    assert {:ok, _} =
             Company.bind_corpus(
               fixture.project["id"],
               corpus["id"],
               fixture.profile["content_hash"],
               fixture.project["content_hash"],
               caller()
             )

    %{id: id, base: base, root: root, fixture: fixture, corpus: corpus}
  end

  test "source purge removes member-corpus declarations and restores immutable triggers", c do
    source = hd(c.fixture.sources)

    assert {:ok, _} =
             Corpora.apply_members(
               c.corpus["id"],
               0,
               [
                 %{
                   "source_id" => source["id"],
                   "revision_id" => source["latest_revision"]["id"],
                   "action" => "include"
                 }
               ],
               caller()
             )

    declaration = declare(c, c.corpus, c.fixture.project, c.fixture.connection)
    safe = independent_declaration(c)
    safe_record = record(safe)
    triggers = assert_immutable(declaration)

    assert {:ok, %{"kind" => "source", "state" => "completed"}} =
             Privacy.purge_source(source["id"], source["id"])

    assert record(declaration) == []
    assert record(safe) == safe_record

    assert {:error, :not_found} =
             Corpora.requirements_summary(declaration["id"], declaration["digest"], caller())

    assert triggers() == triggers
    assert_immutable(safe)
    assert :ok = Privacy.ready()
  end

  test "source purge also removes declarations of the revoked connection outside its member corpora",
       c do
    declaration = declare(c, c.corpus, c.fixture.project, c.fixture.connection)
    safe = independent_declaration(c)
    safe_record = record(safe)

    assert Repo.query!("SELECT count(*) FROM corpus_members WHERE corpus_id=?", [c.corpus["id"]]).rows ==
             [[0]]

    triggers = assert_immutable(declaration)
    source = hd(c.fixture.sources)

    assert {:ok, _} = Privacy.purge_source(source["id"], source["id"])
    assert record(declaration) == []
    assert record(safe) == safe_record

    assert Repo.query!("SELECT status,directory,config FROM source_connections WHERE id=?", [
             c.fixture.connection["id"]
           ]).rows == [["revoked", nil, "{}"]]

    assert triggers() == triggers
    assert_immutable(safe)
    assert :ok = Privacy.ready()
  end

  test "workspace purge deletes real declarations before their referenced records", c do
    declaration = declare(c, c.corpus, c.fixture.project, c.fixture.connection)
    independent_declaration(c)
    triggers = assert_immutable(declaration)

    assert Repo.query!("SELECT count(*) FROM corpus_requirements WHERE workspace_id=?", [c.id]).rows ==
             [[2]]

    assert {:ok, %{"kind" => "workspace", "state" => "completed"}} = Privacy.purge_workspace(c.id)

    for table <-
          ~w(corpus_requirements corpora company_corpus_bindings company_projects workspace_goals source_connections) do
      assert Repo.query!("SELECT count(*) FROM #{table} WHERE workspace_id=?", [c.id]).rows == [
               [0]
             ]
    end

    assert triggers() == triggers
    assert Repo.query!("PRAGMA foreign_key_check", []).rows == []
    assert :ok = Privacy.ready()
  end

  @tag :committed
  test "committed backup preserves declaration bytes while restore remaps rows and quarantines authority",
       c do
    declaration = declare(c, c.corpus, c.fixture.project, c.fixture.connection)
    [original] = record(declaration)
    payload = List.last(original)
    assert Jason.decode!(payload)["scope"]["workspace_id"] == c.id
    triggers = assert_immutable(declaration)
    {:ok, corpus_before} = Corpora.get(c.corpus["id"])
    backup = Path.join(c.base, "backup")
    restored = Path.join(c.base, "restored")
    assert {:ok, _} = Privacy.backup(backup)
    assert {:ok, manifest} = Privacy.verify_backup(backup)
    assert manifest["workspace_id"] == c.id

    with_database(backup, fn conn ->
      assert rows(conn, @record, [declaration["id"]]) == [original]
      assert rows(conn, @trigger_sql, []) == triggers
    end)

    assert {:ok,
            %{
              "state" => "quarantined",
              "workspace_id" => new_id,
              "source_revalidation_required" => true,
              "approvals_restored" => false
            }} = Privacy.restore(backup, restored)

    assert new_id != c.id
    assert Jason.decode!(File.read!(Path.join(restored, "workspace.json")))["id"] == new_id
    restore_state = Jason.decode!(File.read!(Path.join(restored, "restore.json")))
    assert restore_state["state"] == "quarantined"
    assert restore_state["source_workspace_id"] == c.id
    assert "reconnect_sources" in restore_state["requires"]

    with_database(restored, fn conn ->
      assert rows(conn, @record, [declaration["id"]]) == [List.replace_at(original, 1, new_id)]

      assert rows(conn, "SELECT payload,digest FROM corpus_requirements WHERE id=?", [
               declaration["id"]
             ]) == [[payload, declaration["digest"]]]

      assert rows(
               conn,
               "SELECT workspace_id,state,semantic_generation,authorization_generation FROM corpora WHERE id=?",
               [c.corpus["id"]]
             ) == [
               [
                 new_id,
                 "denied",
                 corpus_before.semantic_generation,
                 corpus_before.authorization_generation + 1
               ]
             ]

      assert rows(
               conn,
               "SELECT workspace_id,status,directory,config,sync_state FROM source_connections WHERE id=?",
               [c.fixture.connection["id"]]
             ) == [[new_id, "revoked", nil, "{}", "restored_requires_revalidation"]]

      assert rows(conn, @trigger_sql, []) == triggers
      assert {:error, _} = Sqlite3.execute(conn, "UPDATE corpus_requirements SET digest=digest")
      assert {:error, _} = Sqlite3.execute(conn, "DELETE FROM corpus_requirements")
      assert rows(conn, @record, [declaration["id"]]) == [List.replace_at(original, 1, new_id)]
      assert rows(conn, "PRAGMA foreign_key_check", []) == []
    end)

    {:ok, restored_repo} =
      Repo.start_link(
        name: nil,
        database: Path.join(restored, "data.sqlite3"),
        pool: DBConnection.ConnectionPool,
        pool_size: 1
      )

    previous_repo = Repo.put_dynamic_repo(restored_repo)
    Application.put_env(:harness_forge, :workspace_id, new_id)
    Application.put_env(:harness_forge, :workspace_root, restored)

    try do
      assert {:error, :invalid_scope} =
               Corpora.requirements_summary(declaration["id"], declaration["digest"], caller())

      assert {:error, :stale_generation} =
               Corpora.assert_current(
                 c.corpus["id"],
                 corpus_before.semantic_generation,
                 corpus_before.authorization_generation
               )

      assert {:ok, _} = Privacy.purge_workspace(new_id)
      assert record(declaration) == []
      assert triggers() == triggers
    after
      Repo.put_dynamic_repo(previous_repo)
      Application.put_env(:harness_forge, :workspace_id, c.id)
      Application.put_env(:harness_forge, :workspace_root, c.root)
      GenServer.stop(restored_repo)
    end
  end

  defp independent_declaration(c) do
    directory = Path.join(c.root, "independent-public-documents")
    File.mkdir_p!(directory)

    {:ok, connection} =
      Evidence.connect(%{
        "name" => "Unrelated synthetic connection",
        "provider" => "local",
        "directory" => directory
      })

    {:ok, project} =
      Company.create_project(%{
        "name" => "Unrelated synthetic project",
        "repository_ids" => [c.fixture.repository["id"]],
        "source_ids" => []
      })

    {:ok, corpus} = Corpora.create(%{"name" => "Unrelated synthetic corpus"}, caller())

    assert {:ok, _} =
             Company.bind_corpus(
               project["id"],
               corpus["id"],
               c.fixture.profile["content_hash"],
               project["content_hash"],
               caller()
             )

    declare(c, corpus, project, connection)
  end

  defp declare(c, corpus, project, connection) do
    assert {:ok, context} =
             Corpora.requirements_context(
               corpus["id"],
               project["id"],
               c.fixture.goal["id"],
               Goals.content_hash(c.fixture.goal),
               caller()
             )

    assert {:ok, declaration} =
             Corpora.declare_requirements(
               corpus["id"],
               context["expected"],
               %{
                 "project_id" => project["id"],
                 "goal_id" => c.fixture.goal["id"],
                 "primary_connection_id" => connection["id"],
                 "entries" => [
                   %{
                     "connection_id" => connection["id"],
                     "requirement" => "required",
                     "capture_run_id" => nil,
                     "capture_revision" => nil
                   }
                 ]
               },
               caller()
             )

    assert declaration["required_status"] == "unknown"
    declaration
  end

  defp assert_immutable(declaration) do
    triggers = triggers()
    assert Enum.map(triggers, &hd/1) == @triggers
    before = record(declaration)

    assert {:error, _} =
             Repo.query(
               "UPDATE corpus_requirements SET digest=digest WHERE id=?",
               [declaration["id"]],
               log: false
             )

    assert {:error, _} =
             Repo.query("DELETE FROM corpus_requirements WHERE id=?", [declaration["id"]],
               log: false
             )

    assert record(declaration) == before
    triggers
  end

  defp record(declaration), do: Repo.query!(@record, [declaration["id"]]).rows
  defp triggers, do: Repo.query!(@trigger_sql, []).rows

  defp caller,
    do: [
      authorize: fn -> true end,
      session_fingerprint: Contracts.sha256("requirements privacy caller"),
      view_generation: String.duplicate("e", 32),
      reset_token: 0
    ]

  defp with_database(root, fun) do
    {:ok, conn} = Sqlite3.open(Path.join(root, "data.sqlite3"))

    try do
      fun.(conn)
    after
      Sqlite3.close(conn)
    end
  end

  defp rows(conn, query, params) do
    {:ok, statement} = Sqlite3.prepare(conn, query)

    try do
      :ok = Sqlite3.bind(statement, params)
      {:ok, result} = Sqlite3.fetch_all(conn, statement)
      result
    after
      Sqlite3.release(conn, statement)
    end
  end
end
