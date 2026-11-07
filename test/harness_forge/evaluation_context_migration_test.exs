defmodule HarnessForge.EvaluationContextMigrationTest do
  use ExUnit.Case, async: false

  alias HarnessForge.{Contracts, Privacy}
  alias HarnessForge.Repo.Migrations

  defmodule MigrationRepo do
    use Ecto.Repo, otp_app: :harness_forge, adapter: Ecto.Adapters.SQLite3
  end

  @baseline [
    {20_261_031_000_000, Migrations.AddOban, "add_oban"},
    {20_261_031_000_100, Migrations.CreateEvidence, "create_evidence"},
    {20_261_031_000_200, Migrations.CreateModelRequests, "create_model_requests"},
    {20_261_031_000_300, Migrations.RemoteConnections, "remote_connections"},
    {20_261_031_000_400, Migrations.EvaluationRuns, "evaluation_runs"},
    {20_261_031_000_500, Migrations.Releases, "releases"},
    {20_261_031_000_600, Migrations.PrivacyOperations, "privacy_operations"},
    {20_261_031_000_700, Migrations.CompanyBuilder, "company_builder"},
    {20_261_101_000_500, Migrations.AddClaimBasis, "add_claim_basis"}
  ]
  @version 20_261_101_000_700
  @legacy_columns "id, workspace_id, artifact_digest, result, inserted_at, updated_at"

  setup_all do
    migrations =
      @baseline ++
        [{@version, Migrations.AddEvaluationExecutionContext, "add_evaluation_execution_context"}]

    for {version, module, suffix} <- migrations, not Code.ensure_loaded?(module) do
      Code.compile_file(
        Path.join([File.cwd!(), "priv/repo/migrations", "#{version}_#{suffix}.exs"])
      )
    end

    :ok
  end

  setup do
    base = Path.join([File.cwd!(), "tmp", "hf-execution-migration-#{Ecto.UUID.generate()}"])
    File.mkdir_p!(base)
    database = Path.join(base, "legacy.sqlite3")
    start_repo(database)
    Ecto.Migrator.run(MigrationRepo, baseline(), :up, all: true, log: false)
    workspace = Ecto.UUID.generate()
    run_id = Ecto.UUID.generate()

    result = %{
      "id" => run_id,
      "workspace_id" => workspace,
      "kind" => "task",
      "outcome" => "blocked",
      "reason" => "model_not_selected",
      "runtime_qualified" => false,
      "cleanup_status" => "not_started",
      "opaque_legacy_data" => "preserve these exact bytes"
    }

    insert_run(run_id, workspace, result)
    on_exit(fn -> File.rm_rf!(base) end)
    %{base: base, database: database, workspace: workspace, run_id: run_id, result: result}
  end

  test "actual nullable migration and empty rollback preserve legacy evaluation bytes and triggers" do
    before_rows = rows("SELECT #{@legacy_columns} FROM evaluation_runs")
    before_triggers = triggers()
    refute context_column?()
    assert :ok = migrate_up()
    assert rows("SELECT #{@legacy_columns} FROM evaluation_runs") == before_rows
    assert rows("SELECT execution_context FROM evaluation_runs") == [[nil]]
    assert triggers() == before_triggers

    column =
      Enum.find(
        rows("PRAGMA table_info(evaluation_runs)"),
        &(Enum.at(&1, 1) == "execution_context")
      )

    assert Enum.at(column, 3) == 0
    assert Enum.at(column, 4) == nil
    assert :ok = migrate_down()
    refute context_column?()
    assert rows("SELECT #{@legacy_columns} FROM evaluation_runs") == before_rows
    assert triggers() == before_triggers
  end

  test "populated rollback refuses even corrupt context in another workspace without losing authority",
       ctx do
    assert :ok = migrate_up()
    foreign_id = Ecto.UUID.generate()
    foreign_workspace = Ecto.UUID.generate()
    insert_run(foreign_id, foreign_workspace, ctx.result)

    # Raw malformed storage is deliberately protected too: rollback does not
    # authorize deleting data just because execution would refuse its context.
    sql!("UPDATE evaluation_runs SET execution_context = ? WHERE id = ?", ["{}", foreign_id])
    before_rows = rows("SELECT * FROM evaluation_runs ORDER BY id")
    before_triggers = triggers()

    assert_raise RuntimeError, ~r/evaluation cleanup authority remains/, fn -> migrate_down() end
    assert context_column?()
    assert rows("SELECT * FROM evaluation_runs ORDER BY id") == before_rows
    assert triggers() == before_triggers
    assert @version in Ecto.Migrator.migrated_versions(MigrationRepo)
  end

  test "pre07 backup restores without a context column and later migrates to null", ctx do
    stop_supervised!(MigrationRepo)
    backup = backup(ctx)
    restored = Path.join(ctx.base, "restored")

    assert {:ok, %{"workspace_id" => restored_id, "approvals_restored" => false}} =
             Privacy.restore(backup, restored)

    start_repo(Path.join(restored, "data.sqlite3"))
    refute context_column?()
    assert_quarantine(restored_id)
    migrations = baseline() ++ [{@version, Migrations.AddEvaluationExecutionContext}]
    assert [@version] = Ecto.Migrator.run(MigrationRepo, migrations, :up, all: true, log: false)
    assert rows("SELECT execution_context FROM evaluation_runs") == [[nil]]
    assert_quarantine(restored_id)
  end

  test "new-schema restore clears original connection authority and preserves the private backup",
       ctx do
    assert :ok = migrate_up()

    context = %{
      "version" => "coding-transport-v2",
      "route" => "desktop_loopback_proxy",
      "endpoint" => "unix:///private/ORIGINAL_DAEMON_ONLY.sock",
      "daemon_id" => "ORIGINAL:DAEMON:ONLY",
      "workspace_id" => ctx.workspace,
      "run_id" => ctx.run_id
    }

    sql!("UPDATE evaluation_runs SET execution_context = ? WHERE id = ?", [
      Jason.encode!(context),
      ctx.run_id
    ])

    stop_supervised!(MigrationRepo)
    backup = backup(ctx)
    restored = Path.join(ctx.base, "restored")
    backup_hash = File.read!(Path.join(backup, "data.sqlite3")) |> Contracts.sha256()

    assert {:ok, %{"workspace_id" => restored_id}} = Privacy.restore(backup, restored)
    start_repo(Path.join(restored, "data.sqlite3"))
    assert context_column?()
    assert rows("SELECT execution_context FROM evaluation_runs") == [[nil]]
    assert_quarantine(restored_id)
    assert File.read!(Path.join(backup, "data.sqlite3")) |> Contracts.sha256() == backup_hash
  end

  defp assert_quarantine(workspace) do
    [[json]] = rows("SELECT result FROM evaluation_runs")
    result = Jason.decode!(json)
    assert result["workspace_id"] == workspace
    assert result["outcome"] == "interrupted"
    assert result["reason"] == "restored_requires_reevaluation"
    assert result["cleanup_status"] == "not_dispatched"
    refute result["runtime_qualified"]
    assert result["opaque_legacy_data"] == "preserve these exact bytes"
  end

  defp backup(ctx) do
    backup = Path.join(ctx.base, "backup")
    File.mkdir!(backup)
    File.cp!(ctx.database, Path.join(backup, "data.sqlite3"))

    File.write!(
      Path.join(backup, "workspace.json"),
      Jason.encode!(%{"id" => ctx.workspace, "version" => 1})
    )

    files =
      for name <- ["data.sqlite3", "workspace.json"] do
        bytes = File.read!(Path.join(backup, name))
        %{"path" => name, "bytes" => byte_size(bytes), "sha256" => Contracts.sha256(bytes)}
      end

    manifest = %{
      "format" => "harnessforge-backup-v1",
      "workspace_id" => ctx.workspace,
      "created_at" => "2026-11-01T00:00:00Z",
      "artifact_digests" => [],
      "files" => files
    }

    File.write!(Path.join(backup, "manifest.json"), Contracts.canonical_json(manifest))
    assert {:ok, _} = Privacy.verify_backup(backup)
    backup
  end

  defp start_repo(database) do
    start_supervised!(
      {MigrationRepo,
       database: database, pool: DBConnection.ConnectionPool, pool_size: 2, journal_mode: :delete}
    )
  end

  defp baseline, do: Enum.map(@baseline, fn {version, module, _} -> {version, module} end)

  defp insert_run(id, workspace, result) do
    sql!(
      "INSERT INTO evaluation_runs (#{@legacy_columns}) VALUES (?, ?, ?, ?, ?, ?)",
      [
        id,
        workspace,
        String.duplicate("a", 64),
        Jason.encode!(result),
        "2026-11-01 00:00:00",
        "2026-11-01 00:00:00"
      ]
    )
  end

  defp context_column?,
    do:
      Enum.any?(
        rows("PRAGMA table_info(evaluation_runs)"),
        &(Enum.at(&1, 1) == "execution_context")
      )

  defp migrate_up,
    do:
      Ecto.Migrator.up(MigrationRepo, @version, Migrations.AddEvaluationExecutionContext,
        log: false
      )

  defp migrate_down,
    do:
      Ecto.Migrator.down(MigrationRepo, @version, Migrations.AddEvaluationExecutionContext,
        log: false
      )

  defp triggers,
    do: rows("SELECT name, sql FROM sqlite_master WHERE type = 'trigger' ORDER BY name")

  defp sql!(statement, params \\ []),
    do: Ecto.Adapters.SQL.query!(MigrationRepo, statement, params, log: false)

  defp rows(statement), do: sql!(statement).rows
end
