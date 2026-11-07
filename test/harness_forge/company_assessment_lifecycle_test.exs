defmodule HarnessForge.CompanyAssessmentLifecycleTest do
  use ExUnit.Case, async: false
  alias HarnessForge.{Company, Contracts, Evidence, Harnesses, Privacy, Repo}
  alias HarnessForge.Company.{Assessment, Assessments, Profile, Repository, TaskRubric}
  alias HarnessForge.CompanyAssessmentFixture, as: Fixture
  alias HarnessForge.Evidence.Store
  alias HarnessForge.Harnesses.ArtifactBinding
  alias Exqlite.Sqlite3

  setup tags do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: tags[:committed] != true)

    previous =
      Map.new([:workspace_root, :workspace_id], &{&1, Application.get_env(:harness_forge, &1)})

    base = Path.join(File.cwd!(), "tmp/assessment-lifecycle-" <> Ecto.UUID.generate())
    root = Path.join(base, "workspace")
    File.mkdir_p!(root)
    id = Ecto.UUID.generate()
    Application.put_env(:harness_forge, :workspace_root, root)
    Application.put_env(:harness_forge, :workspace_id, id)
    f = Fixture.create!(root)

    on_exit(fn ->
      if tags[:committed] do
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          Application.put_env(:harness_forge, :workspace_id, id)
          Application.put_env(:harness_forge, :workspace_root, root)
          {:ok, _} = Privacy.purge_workspace(id)
        end)
      end

      Enum.each(previous, fn {key, value} -> Application.put_env(:harness_forge, key, value) end)
      File.rm_rf!(base)
    end)

    %{f: f, base: base, root: root, id: id, opts: Fixture.server_opts()}
  end

  test "a generally eligible digest cannot lend chosen-plan approval, binding or content identity",
       c do
    assert :ok = Harnesses.eligible(c.f.artifact)
    assert {:ok, proposed} = Company.create_plan(c.f.plan_attrs)

    assert {:error, :plan_not_approved} =
             Harnesses.assessment_inputs(
               proposed["id"],
               proposed["revision_hash"],
               c.f.artifact["digest"]
             )

    assert {:ok, approved} = Company.decide_plan(proposed["id"], Fixture.decision(proposed))

    assert {:error, :package_not_bound} =
             Harnesses.assessment_inputs(
               approved["id"],
               approved["revision_hash"],
               c.f.artifact["digest"]
             )

    assert {:ok, different} =
             Company.create_plan(Map.put(c.f.plan_attrs, "name", "different-artifact-content"))

    assert {:ok, different} = Company.decide_plan(different["id"], Fixture.decision(different))

    Repo.insert!(%ArtifactBinding{
      workspace_id: c.id,
      plan_id: different["id"],
      plan_revision_hash: different["revision_hash"],
      artifact_digest: c.f.artifact["digest"],
      inserted_at: Store.now()
    })

    assert :ok = Harnesses.eligible(c.f.artifact)

    assert {:error, :invalid_package} =
             Harnesses.assessment_inputs(
               different["id"],
               different["revision_hash"],
               c.f.artifact["digest"]
             )

    assert {:ok, original} =
             Harnesses.assessment_inputs(
               c.f.plan["id"],
               c.f.plan["revision_hash"],
               c.f.artifact["digest"]
             )

    assert original["artifact"] == c.f.artifact
  end

  for source_kind <- ~w(cited uncited) do
    @source_kind source_kind
    test "purging #{@source_kind} input deletes assessment families before plans and preserves independent assessments",
         c do
      {:ok, first} = Assessments.freeze_rubric(c.f.freeze_attrs, c.opts)

      {:ok, first_receipt} =
        Assessments.record_assessment(Fixture.assessment_attrs(c.f, first), c.opts)

      {:ok, plan} =
        Company.create_plan(
          c.f.plan_attrs
          |> Map.put("supersedes_id", c.f.plan["id"])
          |> Map.put("package_version", "1.1.0")
        )

      {:ok, plan} = Company.decide_plan(plan["id"], Fixture.decision(plan))
      {:ok, artifact} = Harnesses.build_plan(plan["id"], plan["revision_hash"])

      successor_attrs =
        c.f.freeze_attrs
        |> Map.merge(%{
          "plan_id" => plan["id"],
          "expected_plan_revision_hash" => plan["revision_hash"],
          "artifact_digest" => artifact["digest"],
          "supersedes_id" => first["id"],
          "expected_predecessor_hash" => first["revision_hash"],
          "task" => "A separately frozen successor task."
        })

      {:ok, successor} = Assessments.freeze_rubric(successor_attrs, c.opts)

      {:ok, successor_receipt} =
        Assessments.record_assessment(Fixture.assessment_attrs(c.f, successor), c.opts)

      # Construct disjoint current history in the same workspace. The former
      # mutable catalog is deliberately removed, making the first family stale;
      # its immutable provenance must still be usable for selective deletion.
      Repo.delete!(Repo.get!(Profile, c.f.profile["id"]))
      Repo.delete!(Repo.get!(Repository, c.f.repository["id"]))
      other = Fixture.create!(Path.join(c.root, "independent"))
      {:ok, independent} = Assessments.freeze_rubric(other.freeze_attrs, c.opts)

      {:ok, independent_receipt} =
        Assessments.record_assessment(Fixture.assessment_attrs(other, independent), c.opts)

      source = if @source_kind == "cited", do: hd(c.f.sources), else: c.f.uncited_source
      assert {:ok, _} = Privacy.purge_source(source["id"], source["id"])

      for rubric <- [first, successor],
          do: assert({:error, :not_found} = Assessments.get_rubric(rubric["id"]))

      for receipt <- [first_receipt, successor_receipt],
          do: assert({:error, :not_found} = Assessments.get_assessment(receipt["id"]))

      assert {:ok, ^independent} = Assessments.get_rubric(independent["id"])
      assert {:ok, ^independent_receipt} = Assessments.get_assessment(independent_receipt["id"])
      assert {:ok, _} = Harnesses.get(other.artifact["digest"])
      assert Repo.aggregate(Store.scoped(TaskRubric), :count) == 1
      assert Repo.aggregate(Store.scoped(Assessment), :count) == 1
      assert {:ok, _} = Privacy.purge_source(source["id"], source["id"])
      assert {:ok, ^independent_receipt} = Assessments.get_assessment(independent_receipt["id"])
    end
  end

  test "workspace purge removes self-referencing rubric history leaf first and retains immutable guards",
       c do
    {:ok, first} = Assessments.freeze_rubric(c.f.freeze_attrs, c.opts)
    {:ok, _} = Assessments.record_assessment(Fixture.assessment_attrs(c.f, first), c.opts)

    attrs =
      Map.merge(c.f.freeze_attrs, %{
        "supersedes_id" => first["id"],
        "expected_predecessor_hash" => first["revision_hash"],
        "task" => "Explicit successor task"
      })

    {:ok, second} = Assessments.freeze_rubric(attrs, c.opts)
    {:ok, _} = Assessments.record_assessment(Fixture.assessment_attrs(c.f, second), c.opts)
    assert {:ok, _} = Privacy.purge_workspace(c.id)
    assert {:ok, []} = Assessments.list_rubrics()
    assert Repo.aggregate(Store.scoped(Assessment), :count) == 0
    assert Repo.query!("PRAGMA foreign_key_check").rows == []

    assert Repo.query!(
             "SELECT count(*) FROM sqlite_master WHERE type='trigger' AND name IN ('immutable_company_task_rubrics_delete','immutable_company_assessments_delete')"
           ).rows == [[2]]
  end

  test "resuming a pre-feature durable purge plan recomputes task and assessment dependencies",
       c do
    {:ok, rubric} = Assessments.freeze_rubric(c.f.freeze_attrs, c.opts)
    {:ok, receipt} = Assessments.record_assessment(Fixture.assessment_attrs(c.f, rubric), c.opts)

    run =
      Repo.insert!(%HarnessForge.Evaluation.Run{
        id: Ecto.UUID.generate(),
        workspace_id: c.id,
        artifact_digest: c.f.artifact["digest"],
        result: %{
          "kind" => "runtime_smoke",
          "outcome" => "interrupted",
          "cleanup_status" => "cleanup_failed"
        }
      })

    previous = System.get_env("DOCKER_HOST")
    System.put_env("DOCKER_HOST", "tcp://untrusted.invalid:2375")

    on_exit(fn ->
      if previous,
        do: System.put_env("DOCKER_HOST", previous),
        else: System.delete_env("DOCKER_HOST")
    end)

    source = c.f.uncited_source
    assert {:error, :cleanup_failed} = Privacy.purge_source(source["id"], source["id"])

    [[id, raw]] =
      Repo.query!(
        "SELECT id, plan FROM privacy_operations WHERE workspace_id = ? AND state = 'prepared'",
        [c.id]
      ).rows

    legacy =
      Jason.decode!(raw) |> Map.update!("company", &Map.drop(&1, ~w(rubric_ids assessment_ids)))

    Repo.query!("UPDATE privacy_operations SET plan = ? WHERE id = ?", [Jason.encode!(legacy), id])

    Repo.delete!(run)
    assert :ok = Privacy.reconcile()
    assert :ok = Privacy.ready()
    assert {:error, :not_found} = Assessments.get_rubric(rubric["id"])
    assert {:error, :not_found} = Assessments.get_assessment(receipt["id"])
    assert {:error, :not_found} = Evidence.get_source(source["id"])
    assert Repo.query!("PRAGMA foreign_key_check").rows == []
  end

  @tag :committed
  test "real backup and restore preserve raw history while permanently withdrawing inherited authority",
       c do
    {:ok, rubric} = Assessments.freeze_rubric(c.f.freeze_attrs, c.opts)
    attempt = Fixture.assessment_attrs(c.f, rubric)
    {:ok, receipt} = Assessments.record_assessment(attempt, c.opts)
    backup = Path.join(c.base, "backup")
    restored = Path.join(c.base, "restored")
    assert {:ok, _} = Privacy.backup(backup)
    raw_rubric = raw_row(backup, "company_task_rubrics", rubric["id"])
    raw_assessment = raw_row(backup, "company_assessments", receipt["id"])
    assert {:ok, %{"workspace_id" => restored_id}} = Privacy.restore(backup, restored)
    assert restored_id != c.id

    assert Map.delete(raw_row(restored, "company_task_rubrics", rubric["id"]), "workspace_id") ==
             Map.delete(raw_rubric, "workspace_id")

    assert Map.delete(raw_row(restored, "company_assessments", receipt["id"]), "workspace_id") ==
             Map.delete(raw_assessment, "workspace_id")

    assert raw_row(restored, "company_task_rubrics", rubric["id"])["workspace_id"] == restored_id

    with_restored(c, restored, restored_id, fn ->
      assert {:ok, history} = Assessments.get_assessment(receipt["id"])
      assert history["payload"] == receipt["payload"]
      assert history["assessment_hash"] == receipt["assessment_hash"]
      assert history["applicability"]["status"] == "restored_historical"

      assert {:error, :restored_historical} =
               Assessments.new_attempt(rubric["id"], rubric["revision_hash"], c.opts)

      assert {:error, :restored_historical} = Assessments.record_assessment(attempt, c.opts)
      # Re-establish equivalent public synthetic context through the ordinary
      # creation/review/build APIs in the new workspace; inherited judgment must
      # remain historical even after a newly eligible successor is assessed.
      Repo.delete!(Repo.get!(Profile, c.f.profile["id"]))
      Repo.delete!(Repo.get!(Repository, c.f.repository["id"]))
      fresh = Fixture.create!(Path.join(restored, "fresh-public-context"))

      attrs =
        fresh.freeze_attrs
        |> Map.put("supersedes_id", rubric["id"])
        |> Map.put("expected_predecessor_hash", rubric["revision_hash"])

      # Recreated guidance has different exact claim pins, hence different
      # obligation meaning: give every replacement obligation an explicit new ID.
      attrs =
        Map.update!(attrs, "obligations", fn rows ->
          Enum.map(rows, &Map.update!(&1, "id", fn id -> "restored-" <> id end))
        end)

      assert {:ok, new_rubric} = Assessments.freeze_rubric(attrs, c.opts)
      assert new_rubric["payload"]["origin_workspace_id"] == restored_id

      current_attrs = Fixture.assessment_attrs(fresh, new_rubric)

      current_attrs =
        Map.update!(current_attrs, "results", fn rows ->
          Enum.map(rows, &Map.update!(&1, "obligation_id", fn id -> "restored-" <> id end))
        end)

      assert {:ok, current} = Assessments.record_assessment(current_attrs, c.opts)

      assert current["applicability"]["status"] == "current"
      assert {:ok, historical} = Assessments.get_assessment(receipt["id"])
      assert historical["applicability"]["status"] == "restored_historical"
      assert historical["payload"] == receipt["payload"]
      assert {:error, :restored_historical} = Assessments.record_assessment(attempt, c.opts)
      assert {:ok, _} = Privacy.purge_workspace(restored_id)
    end)
  end

  @tag :committed
  test "pre-feature backup restores before additive migration without querying absent tables",
       c do
    backup = Path.join(c.base, "legacy-backup")
    restored = Path.join(c.base, "legacy-restored")
    assert {:ok, _} = Privacy.backup(backup)
    {:ok, db} = Sqlite3.open(Path.join(backup, "data.sqlite3"))

    try do
      :ok = Sqlite3.execute(db, "DROP TABLE company_assessments")
      :ok = Sqlite3.execute(db, "DROP TABLE company_task_rubrics")
      :ok = Sqlite3.execute(db, "DELETE FROM schema_migrations WHERE version=20261102000100")
    after
      Sqlite3.close(db)
    end

    path = Path.join(backup, "manifest.json")
    manifest = Jason.decode!(File.read!(path))
    bytes = File.read!(Path.join(backup, "data.sqlite3"))

    manifest =
      Map.update!(manifest, "files", fn entries ->
        Enum.map(entries, fn entry ->
          if entry["path"] == "data.sqlite3",
            do:
              Map.merge(entry, %{"bytes" => byte_size(bytes), "sha256" => Contracts.sha256(bytes)}),
            else: entry
        end)
      end)

    File.write!(path, Contracts.canonical_json(manifest))
    assert {:ok, _} = Privacy.verify_backup(backup)
    assert {:ok, %{"workspace_id" => id}} = Privacy.restore(backup, restored)

    with_restored(c, restored, id, fn ->
      assert Repo.query!(
               "SELECT count(*) FROM sqlite_master WHERE name IN ('company_assessments','company_task_rubrics')"
             ).rows == [[0]]

      assert :ok =
               Ecto.Migrator.up(
                 Repo,
                 20_261_102_000_100,
                 HarnessForge.Repo.Migrations.CompanyAssessments,
                 log: false
               )

      assert {:ok, []} = Assessments.list_rubrics()
      assert Repo.aggregate(Store.scoped(Assessment), :count) == 0
      assert {:ok, goals} = HarnessForge.Goals.list_goals()
      assert length(goals) == 2
      assert {:ok, []} = Evidence.approved_claims()
      assert {:ok, _} = Privacy.purge_workspace(id)
    end)
  end

  defp with_restored(c, path, id, fun) do
    {:ok, restored_repo} =
      Repo.start_link(
        name: nil,
        database: Path.join(path, "data.sqlite3"),
        pool: DBConnection.ConnectionPool,
        pool_size: 2
      )

    previous_repo = Repo.put_dynamic_repo(restored_repo)
    Application.put_env(:harness_forge, :workspace_id, id)
    Application.put_env(:harness_forge, :workspace_root, path)

    try do
      fun.()
    after
      Repo.put_dynamic_repo(previous_repo)
      Application.put_env(:harness_forge, :workspace_id, c.id)
      Application.put_env(:harness_forge, :workspace_root, c.root)
      GenServer.stop(restored_repo)
    end
  end

  defp raw_row(path, table, id) do
    {:ok, db} = Sqlite3.open(Path.join(path, "data.sqlite3"))

    try do
      {:ok, statement} = Sqlite3.prepare(db, "SELECT * FROM " <> table <> " WHERE id = ?")

      try do
        :ok = Sqlite3.bind(statement, [id])
        {:ok, columns} = Sqlite3.columns(db, statement)
        {:ok, [values]} = Sqlite3.fetch_all(db, statement)
        Map.new(Enum.zip(columns, values))
      after
        Sqlite3.release(db, statement)
      end
    after
      Sqlite3.close(db)
    end
  end
end
