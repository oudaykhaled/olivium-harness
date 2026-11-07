defmodule HarnessForge.CompanyAnalysisPrivacyTest do
  use ExUnit.Case, async: false
  alias HarnessForge.{Company, Decisions, Evidence, Goals, Harnesses, Models, Privacy, Repo}
  alias HarnessForge.Company.Analysis
  alias HarnessForge.CompanyAnalysisFixture, as: Fixture
  alias HarnessForge.Evidence.{Claim, Store}
  alias Exqlite.Sqlite3

  setup tags do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: tags[:committed] != true)

    previous =
      Map.new(
        [:workspace_id, :workspace_root, :model_test_plug],
        &{&1, Application.get_env(:harness_forge, &1)}
      )

    base = Path.join(File.cwd!(), "tmp/analysis-privacy-" <> Ecto.UUID.generate())
    root = Path.join(base, "workspace")
    File.mkdir_p!(root)
    id = Ecto.UUID.generate()
    Application.put_env(:harness_forge, :workspace_id, id)
    Application.put_env(:harness_forge, :workspace_root, root)
    Application.put_env(:harness_forge, :model_test_plug, {Req.Test, __MODULE__})
    f = Fixture.create!(root)
    {:ok, _} = Models.configure(%{"model" => "synthetic:company-workflow"})

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/api/tags" ->
          Req.Test.json(conn, %{"models" => [%{"name" => "synthetic:company-workflow"}]})

        "/api/generate" ->
          Req.Test.json(conn, Fixture.response(f.report))
      end
    end)

    on_exit(fn ->
      if tags[:committed] do
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          Application.put_env(:harness_forge, :workspace_id, id)
          Application.put_env(:harness_forge, :workspace_root, root)
          {:ok, _} = Privacy.purge_workspace(id)
        end)
      end

      Enum.each(previous, fn {key, value} ->
        if is_nil(value),
          do: Application.delete_env(:harness_forge, key),
          else: Application.put_env(:harness_forge, key, value)
      end)

      File.rm_rf!(base)
    end)

    %{fixture: f, base: base, root: root}
  end

  test "purging a revoked examined-but-uncited source removes the whole family and local artifact, retaining unrelated goal policy",
       c do
    {original, revised, plan, artifact} = approved(c.fixture)

    {:ok, goal} =
      Goals.add_goal(%{
        "title" => "Independent goal",
        "owner" => "Other owner",
        "acceptance" => "Keep independent record"
      })

    {:ok, independent} =
      Evidence.create_claim(%{
        "text" => "Retain this unrelated goal policy",
        "citations" => [],
        "basis" => %{
          "kind" => "goal",
          "version" => 1,
          "goal_id" => goal["id"],
          "goal_content_hash" => Goals.content_hash(goal)
        }
      })

    {:ok, _} = Decisions.decide(independent["id"], Fixture.decision(independent))
    uncited = c.fixture.uncited_source

    refute Enum.any?(
             revised["citations"],
             &(&1["revision_id"] == uncited["latest_revision"]["id"])
           )

    {:ok, _} = Evidence.revoke_source(uncited["id"])
    assert {:error, _} = Harnesses.eligible(artifact)
    assert {:ok, _} = Privacy.purge_source(uncited["id"], uncited["id"])
    assert {:error, :not_found} = Evidence.get_claim(original["id"])
    assert {:error, :not_found} = Evidence.get_claim(revised["id"])
    assert {:error, :not_found} = Company.get_plan(plan["id"])
    assert {:error, _} = Harnesses.get(artifact["digest"])
    refute File.exists?(Path.join([c.root, "artifacts", artifact["digest"]]))
    assert {:ok, %{"status" => "approved"}} = Evidence.get_claim(independent["id"])
    assert Repo.aggregate(Store.scoped(Claim), :count) == 1

    for source <- Enum.take(c.fixture.sources, 3),
        do: assert({:ok, _} = Evidence.get_source(source["id"]))
  end

  @tag :committed
  test "backup retains exact analysis provenance and restore quarantines authority without model access",
       c do
    {_, revised, _, artifact} = approved(c.fixture)
    {:ok, _} = Models.configure(%{})
    backup = Path.join(c.base, "backup")
    restored = Path.join(c.base, "restored")
    assert {:ok, _} = Privacy.backup(backup)
    assert {:ok, manifest} = Privacy.verify_backup(backup)
    {:ok, copied} = Sqlite3.open(Path.join(backup, "data.sqlite3"))

    try do
      assert [[basis, citations]] =
               rows(copied, "SELECT basis, citations FROM evidence_claims WHERE id = ?", [
                 revised["id"]
               ])

      assert Jason.decode!(basis) == revised["basis"]

      {:ok, loaded_citations} =
        Ecto.Type.adapter_load(Repo.__adapter__(), {:array, :map}, citations)

      assert loaded_citations == revised["citations"]
      dto = %{"basis" => Jason.decode!(basis), "citations" => loaded_citations}
      assert {:ok, refs} = HarnessForge.Evidence.Origin.references(dto)

      for {key, table} <- %{
            "revision_ids" => "evidence_revisions",
            "source_ids" => "evidence_sources",
            "goal_ids" => "workspace_goals",
            "project_ids" => "company_projects",
            "profile_ids" => "company_profiles"
          } do
        ids =
          rows(copied, "SELECT id FROM #{table} WHERE workspace_id = ?", [
            HarnessForge.Workspaces.current_id()
          ])
          |> List.flatten()

        assert refs[key] -- ids == [], "Copied #{key} missing: #{inspect(refs[key] -- ids)}"
      end
    after
      Sqlite3.close(copied)
    end

    assert artifact["digest"] in manifest["artifact_digests"]

    assert {:ok, %{"approvals_restored" => false, "state" => "quarantined"}} =
             Privacy.restore(backup, restored)

    {:ok, conn} = Sqlite3.open(Path.join(restored, "data.sqlite3"))

    try do
      assert [[basis]] =
               rows(conn, "SELECT basis FROM evidence_claims WHERE id = ?", [revised["id"]])

      assert Jason.decode!(basis) == revised["basis"]
      assert [[0]] = rows(conn, "SELECT COUNT(*) FROM claim_decisions", [])
      assert [[0]] = rows(conn, "SELECT COUNT(*) FROM company_plan_decisions", [])
      assert [[0]] = rows(conn, "SELECT COUNT(*) FROM model_settings", [])

      assert [[0]] =
               rows(conn, "SELECT COUNT(*) FROM source_connections WHERE status != 'revoked'", [])
    after
      Sqlite3.close(conn)
    end
  end

  defp approved(fixture) do
    {:ok, %{"claim" => original}} = Analysis.analyze(fixture.input)

    {:ok, revised} =
      Analysis.revise(
        original["id"],
        original["revision_hash"],
        Map.put(
          original["basis"]["guidance"],
          "review_resolution",
          "Explicit emergency exception applies only to emergency patches."
        )
      )

    {:ok, revised} = Decisions.decide(revised["id"], Fixture.decision(revised))
    {:ok, plan} = Company.create_plan(Fixture.plan_attrs(fixture, revised))
    {:ok, _} = Company.decide_plan(plan["id"], Fixture.decision(plan))
    {:ok, artifact} = Harnesses.build_plan(plan["id"], plan["revision_hash"])
    {original, revised, plan, artifact}
  end

  defp rows(conn, query, params) do
    {:ok, statement} = Sqlite3.prepare(conn, query)

    try do
      :ok = Sqlite3.bind(statement, params)
      {:ok, rows} = Sqlite3.fetch_all(conn, statement)
      rows
    after
      Sqlite3.release(conn, statement)
    end
  end
end
