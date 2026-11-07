defmodule HarnessForge.GoalBasisMigrationTest do
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
    {20_261_031_000_700, Migrations.CompanyBuilder, "company_builder"}
  ]
  @version 20_261_101_000_500
  @legacy_columns "id, workspace_id, family_id, supersedes_id, text, citations, revision_hash, inserted_at"

  setup_all do
    entries = @baseline ++ [{@version, Migrations.AddClaimBasis, "add_claim_basis"}]

    for {version, module, suffix} <- entries, not Code.ensure_loaded?(module) do
      Code.compile_file(
        Path.join([File.cwd!(), "priv/repo/migrations", "#{version}_#{suffix}.exs"])
      )
    end

    :ok
  end

  setup do
    base = Path.join([File.cwd!(), "tmp", "hf-goal-migration-#{Ecto.UUID.generate()}"])
    File.mkdir_p!(base)
    database = Path.join(base, "legacy.sqlite3")
    start_repo(database)

    Ecto.Migrator.run(MigrationRepo, baseline(), :up, all: true, log: false)
    workspace = Ecto.UUID.generate()
    claim = Ecto.UUID.generate()
    revision = Contracts.sha256("opaque synthetic pre05 revision")
    insert_claim(claim, workspace, revision)
    on_exit(fn -> File.rm_rf!(base) end)
    %{base: base, database: database, workspace: workspace, claim: claim, revision: revision}
  end

  test "actual additive migration and empty-basis rollback preserve opaque legacy rows and triggers" do
    before_rows = rows("SELECT #{@legacy_columns} FROM evidence_claims")
    before_triggers = triggers()
    refute basis_column?()

    assert :ok = Ecto.Migrator.up(MigrationRepo, @version, Migrations.AddClaimBasis, log: false)
    assert rows("SELECT #{@legacy_columns} FROM evidence_claims") == before_rows
    assert rows("SELECT basis FROM evidence_claims") == [[nil]]
    assert triggers() == before_triggers

    basis_column =
      Enum.find(rows("PRAGMA table_info(evidence_claims)"), &(&1 |> Enum.at(1) == "basis"))

    assert Enum.at(basis_column, 3) == 0
    assert Enum.at(basis_column, 4) == nil
    assert_immutable()

    assert :ok = Ecto.Migrator.down(MigrationRepo, @version, Migrations.AddClaimBasis, log: false)
    refute basis_column?()
    assert rows("SELECT #{@legacy_columns} FROM evidence_claims") == before_rows
    assert triggers() == before_triggers
    assert_immutable()
  end

  test "rollback refuses non-null basis in any workspace without dropping data or migration state",
       ctx do
    assert :ok = Ecto.Migrator.up(MigrationRepo, @version, Migrations.AddClaimBasis, log: false)
    foreign_workspace = Ecto.UUID.generate()

    basis = %{
      "version" => 1,
      "kind" => "goal",
      "goal_id" => Ecto.UUID.generate(),
      "goal_content_hash" => Contracts.sha256("synthetic goal")
    }

    # Deliberately unapproved raw storage: rollback must protect even data that
    # the domain would reject. This fixture grants no rule authority.
    insert_claim(Ecto.UUID.generate(), foreign_workspace, ctx.revision, basis)
    before_rows = rows("SELECT * FROM evidence_claims ORDER BY id")
    before_triggers = triggers()

    assert_raise RuntimeError, ~r/goal-origin claim data remains/, fn ->
      Ecto.Migrator.down(MigrationRepo, @version, Migrations.AddClaimBasis, log: false)
    end

    assert basis_column?()
    assert rows("SELECT * FROM evidence_claims ORDER BY id") == before_rows
    assert triggers() == before_triggers
    assert @version in Ecto.Migrator.migrated_versions(MigrationRepo)
    assert_immutable()
  end

  test "pre05 backup restores quarantined before the actual startup migration runner adds basis",
       ctx do
    sql!(
      "INSERT INTO claim_decisions (id, workspace_id, claim_id, actor, decision, revision_hash, inserted_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
      [
        Ecto.UUID.generate(),
        ctx.workspace,
        ctx.claim,
        "Synthetic migration test",
        "approved",
        ctx.revision,
        "2026-11-01T00:00:00.000000Z"
      ]
    )

    stop_supervised!(MigrationRepo)
    backup = Path.join(ctx.base, "backup")
    restored = Path.join(ctx.base, "restored")
    File.mkdir_p!(backup)
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

    assert {:ok, %{"workspace_id" => restored_id, "approvals_restored" => false}} =
             Privacy.restore(backup, restored)

    refute restored_id == ctx.workspace
    start_repo(Path.join(restored, "data.sqlite3"))
    refute basis_column?()
    assert rows("SELECT count(*) FROM claim_decisions") == [[0]]

    assert rows("SELECT workspace_id, revision_hash FROM evidence_claims") == [
             [restored_id, ctx.revision]
           ]

    # StartupGate uses this real Ecto runner before recovery/endpoint startup.
    # The complete application lifecycle is verified separately by root native QA.
    migrations = baseline() ++ [{@version, Migrations.AddClaimBasis}]
    assert [@version] = Ecto.Migrator.run(MigrationRepo, migrations, :up, all: true, log: false)

    assert rows("SELECT workspace_id, revision_hash, basis FROM evidence_claims") ==
             [[restored_id, ctx.revision, nil]]

    assert rows("SELECT count(*) FROM claim_decisions") == [[0]]
    assert_immutable()
  end

  defp start_repo(database) do
    start_supervised!(
      {MigrationRepo,
       database: database, pool: DBConnection.ConnectionPool, pool_size: 2, journal_mode: :delete}
    )
  end

  defp baseline, do: Enum.map(@baseline, fn {version, module, _} -> {version, module} end)

  defp insert_claim(id, workspace, revision, basis \\ nil) do
    values = [
      id,
      workspace,
      Ecto.UUID.generate(),
      nil,
      "Synthetic opaque legacy row",
      Jason.encode!([]),
      revision,
      "2026-11-01T00:00:00.000000Z"
    ]

    if is_nil(basis) do
      sql!(
        "INSERT INTO evidence_claims (#{@legacy_columns}) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        values
      )
    else
      sql!(
        "INSERT INTO evidence_claims (#{@legacy_columns}, basis) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        values ++ [Jason.encode!(basis)]
      )
    end
  end

  defp basis_column?,
    do: Enum.any?(rows("PRAGMA table_info(evidence_claims)"), &(Enum.at(&1, 1) == "basis"))

  defp triggers do
    rows(
      "SELECT name, sql FROM sqlite_master WHERE type = 'trigger' AND tbl_name = 'evidence_claims' ORDER BY name"
    )
  end

  defp assert_immutable do
    for statement <- [
          "UPDATE evidence_claims SET text = 'changed'",
          "DELETE FROM evidence_claims"
        ] do
      assert {:error, error} = Ecto.Adapters.SQL.query(MigrationRepo, statement, [], log: false)
      assert Exception.message(error) =~ "immutable record"
    end
  end

  defp sql!(statement, params \\ []),
    do: Ecto.Adapters.SQL.query!(MigrationRepo, statement, params, log: false)

  defp rows(statement), do: sql!(statement).rows
end
