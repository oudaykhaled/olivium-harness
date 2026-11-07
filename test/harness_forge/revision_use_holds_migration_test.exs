defmodule HarnessForge.RevisionUseHoldsMigrationTest do
  use ExUnit.Case, async: false
  alias HarnessForge.{Contracts, Repo.Migrations}

  defmodule MigrationRepo do
    use Ecto.Repo, otp_app: :harness_forge, adapter: Ecto.Adapters.SQLite3
  end

  @version 20_261_103_000_300

  setup_all do
    for {module, path} <- [
          {Migrations.CreateEvidence, "20261031000100_create_evidence.exs"},
          {Migrations.RevisionUseHolds, "20261103000300_revision_use_holds.exs"}
        ],
        not Code.ensure_loaded?(module),
        do: Code.compile_file(Path.join("priv/repo/migrations", path))

    :ok
  end

  setup do
    base = Path.join(File.cwd!(), "tmp/revision-use-migration-#{Ecto.UUID.generate()}")
    File.mkdir_p!(base)

    start_supervised!(
      {MigrationRepo,
       database: Path.join(base, "data.sqlite3"),
       pool: DBConnection.ConnectionPool,
       pool_size: 2,
       journal_mode: :delete}
    )

    :ok =
      Ecto.Migrator.up(MigrationRepo, 20_261_031_000_100, Migrations.CreateEvidence, log: false)

    workspace = Ecto.UUID.generate()
    connection = Ecto.UUID.generate()
    source = Ecto.UUID.generate()
    revision = Ecto.UUID.generate()
    body = "Synthetic immutable legacy migration bytes."
    hash = Contracts.sha256(body)
    now = "2026-11-03T00:00:00Z"

    sql!(
      "INSERT INTO source_connections(id,workspace_id,provider,name,inserted_at,updated_at) VALUES(?,?,'local','Synthetic',?,?)",
      [connection, workspace, now, now]
    )

    sql!(
      "INSERT INTO evidence_sources(id,workspace_id,connection_id,provider,external_id,title,latest_revision_id,inserted_at,updated_at) VALUES(?,?,?,'local','record.md','Synthetic',?,?,?)",
      [source, workspace, connection, revision, now, now]
    )

    sql!(
      "INSERT INTO evidence_revisions(id,source_id,workspace_id,body,body_hash,revision,captured_at) VALUES(?,?,?,?,?,1,?)",
      [revision, source, workspace, body, hash, now]
    )

    on_exit(fn -> File.rm_rf!(base) end)

    %{
      workspace: workspace,
      connection: connection,
      source: source,
      revision: revision,
      hash: hash,
      now: now
    }
  end

  test "additive migration and empty rollback preserve existing immutable bodies and trigger definitions" do
    before_rows = sql!("SELECT * FROM evidence_revisions").rows

    before_triggers =
      sql!(
        "SELECT name,sql FROM sqlite_master WHERE type='trigger' AND tbl_name='evidence_revisions' ORDER BY name"
      ).rows

    assert :ok =
             Ecto.Migrator.up(MigrationRepo, @version, Migrations.RevisionUseHolds, log: false)

    assert sql!("SELECT * FROM evidence_revisions").rows == before_rows
    assert [[0]] = sql!("SELECT count(*) FROM revision_use_holds").rows

    assert :ok =
             Ecto.Migrator.down(MigrationRepo, @version, Migrations.RevisionUseHolds, log: false)

    assert sql!("SELECT * FROM evidence_revisions").rows == before_rows

    assert sql!(
             "SELECT name,sql FROM sqlite_master WHERE type='trigger' AND tbl_name='evidence_revisions' ORDER BY name"
           ).rows == before_triggers

    assert {:error, _} =
             Ecto.Adapters.SQL.query(
               MigrationRepo,
               "UPDATE evidence_revisions SET body='changed'"
             )
  end

  test "scope identity, immutable holds and checkpoint identity are enforced; populated rollback refuses",
       c do
    assert :ok =
             Ecto.Migrator.up(MigrationRepo, @version, Migrations.RevisionUseHolds, log: false)

    event = Ecto.UUID.generate()

    values = [
      event,
      c.workspace,
      c.connection,
      "local",
      "record.md",
      c.source,
      c.revision,
      c.hash,
      Ecto.UUID.generate(),
      Contracts.sha256("synthetic command"),
      "[\"inspection\",\"retrieval\",\"analysis\",\"compile\"]",
      "operator_restriction",
      "local-operator",
      c.now
    ]

    insert =
      "INSERT INTO revision_use_holds(id,workspace_id,connection_id,provider,external_id,source_id,revision_id,body_hash,command_id,request_digest,denied_purposes,reason_code,actor,inserted_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)"

    for {index, wrong} <- [
          {1, Ecto.UUID.generate()},
          {2, Ecto.UUID.generate()},
          {3, "github"},
          {4, "foreign.md"},
          {5, Ecto.UUID.generate()},
          {6, Ecto.UUID.generate()},
          {7, Contracts.sha256("different bytes")},
          {10, "[]"}
        ] do
      assert {:error, _} =
               Ecto.Adapters.SQL.query(
                 MigrationRepo,
                 insert,
                 List.replace_at(values, index, wrong),
                 log: false
               )
    end

    sql!(insert, values)

    assert {:error, _} =
             Ecto.Adapters.SQL.query(
               MigrationRepo,
               "INSERT INTO revision_use_cleanup(event_id,workspace_id,updated_at) VALUES(?,?,?)",
               [event, Ecto.UUID.generate(), c.now],
               log: false
             )

    sql!("INSERT INTO revision_use_cleanup(event_id,workspace_id,updated_at) VALUES(?,?,?)", [
      event,
      c.workspace,
      c.now
    ])

    assert [["pending", "", 0]] =
             sql!("SELECT state,cursor,lock_version FROM revision_use_cleanup").rows

    assert {:error, _} =
             Ecto.Adapters.SQL.query(
               MigrationRepo,
               "UPDATE revision_use_holds SET actor='changed'",
               [],
               log: false
             )

    assert {:error, _} =
             Ecto.Adapters.SQL.query(MigrationRepo, "DELETE FROM revision_use_holds", [],
               log: false
             )

    assert {:error, _} =
             Ecto.Adapters.SQL.query(
               MigrationRepo,
               "UPDATE revision_use_cleanup SET workspace_id=?",
               [Ecto.UUID.generate()],
               log: false
             )

    sql!("UPDATE revision_use_cleanup SET state='completed',lock_version=1")

    assert_raise Ecto.MigrationError, ~r/cannot remove persisted revision-use restrictions/, fn ->
      Ecto.Migrator.down(MigrationRepo, @version, Migrations.RevisionUseHolds, log: false)
    end

    assert @version in Ecto.Migrator.migrated_versions(MigrationRepo)
    assert [[1]] = sql!("SELECT count(*) FROM revision_use_holds").rows
    assert [["completed", 1]] = sql!("SELECT state,lock_version FROM revision_use_cleanup").rows
    assert sql!("PRAGMA foreign_key_check").rows == []
  end

  defp sql!(statement, params \\ []),
    do: Ecto.Adapters.SQL.query!(MigrationRepo, statement, params, log: false)
end
