defmodule HarnessForge.CompanyPrivacyTest do
  use ExUnit.Case, async: false

  alias HarnessForge.{Company, Decisions, Evidence, Harnesses, Privacy, Repo}
  alias Exqlite.Sqlite3

  @tables ~w(company_profiles company_repositories company_projects company_plans company_plan_decisions company_artifact_bindings)

  setup tags do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: tags[:committed] != true)
    previous = Application.get_env(:harness_forge, :workspace_root)
    previous_id = Application.get_env(:harness_forge, :workspace_id)
    id = Ecto.UUID.generate()
    base = Path.join(File.cwd!(), "tmp/company-privacy-#{id}")
    root = Path.join(base, "workspace")
    for dir <- ~w(artifacts runs tmp), do: File.mkdir_p!(Path.join(root, dir))
    Application.put_env(:harness_forge, :workspace_root, root)
    Application.put_env(:harness_forge, :workspace_id, id)

    on_exit(fn ->
      if tags[:committed] do
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          Application.put_env(:harness_forge, :workspace_root, root)
          Application.put_env(:harness_forge, :workspace_id, id)
          {:ok, _} = Privacy.purge_workspace(id)
        end)
      end

      Application.put_env(:harness_forge, :workspace_root, previous)
      Application.put_env(:harness_forge, :workspace_id, previous_id)
      File.rm_rf!(base)
    end)

    %{base: base, root: root, id: id}
  end

  test "source purge removes company scope, dependent plans and artifacts but retains other projects",
       ctx do
    fixture = fixture(ctx)
    {:ok, safe_repo} = Company.create_repository(repository("example/unrelated"))

    {:ok, safe_project} =
      Company.create_project(%{"name" => "Unrelated", "repository_ids" => [safe_repo["id"]]})

    assert {:ok, _} = Privacy.purge_source(fixture.source["id"], fixture.source["id"])
    assert {:ok, []} = Company.list_plans()
    assert count("company_artifact_bindings", ctx.id) == 0
    assert count("company_plan_decisions", ctx.id) == 0
    assert {:ok, projects} = Company.list_projects()
    assert safe_project in projects
    assert length(projects) == 2
    assert Enum.all?(projects, &(fixture.source["id"] not in &1["payload"]["source_ids"]))
    assert {:ok, repos} = Company.list_repositories()
    assert Enum.any?(repos, &(&1["id"] == safe_repo["id"]))
    assert {:error, _} = Harnesses.get(fixture.artifact["digest"])
    assert :ok = Privacy.ready()
  end

  test "workspace inventory and purge include all company payload and authority tables", ctx do
    _ = fixture(ctx)
    assert {:ok, inventory} = Privacy.inventory()
    for table <- @tables, do: assert(inventory["records"][table] == 1)
    assert {:ok, _} = Privacy.purge_workspace(ctx.id)
    for table <- @tables, do: assert(count(table, ctx.id) == 0)
    assert {:ok, nil} = Company.get_profile()
    assert {:ok, []} = Harnesses.list_artifacts()
  end

  @tag :committed
  test "restore retains and remaps plan bindings while withdrawing plan and claim approval",
       ctx do
    fixture = fixture(ctx)
    backup = Path.join(ctx.base, "backup")
    restored = Path.join(ctx.base, "restored")
    assert {:ok, _} = Privacy.backup(backup)
    assert {:ok, %{"workspace_id" => new_id}} = Privacy.restore(backup, restored)
    refute new_id == ctx.id

    for table <-
          ~w(company_profiles company_repositories company_projects company_plans company_artifact_bindings) do
      assert db_rows(restored, "SELECT DISTINCT workspace_id FROM #{table}") == [[new_id]]
    end

    assert db_rows(restored, "SELECT count(*) FROM company_plan_decisions") == [[0]]
    assert db_rows(restored, "SELECT count(*) FROM claim_decisions") == [[0]]

    assert db_rows(restored, "SELECT plan_id, artifact_digest FROM company_artifact_bindings") ==
             [[fixture.plan["id"], fixture.artifact["digest"]]]

    assert File.exists?(
             Path.join([restored, "artifacts", fixture.artifact["digest"], "artifact.json"])
           )

    assert db_rows(restored, "SELECT DISTINCT status FROM source_connections") == [["revoked"]]
  end

  defp fixture(ctx) do
    input = Path.join(ctx.base, "input")
    File.mkdir_p!(input)
    text = "Synthetic policy: report the test outcome for a bounded change."

    {:ok, connection} =
      Evidence.connect(%{"provider" => "local", "name" => "Synthetic", "directory" => input})

    {:ok, source} =
      Evidence.import_markdown(connection["id"], %{
        "external_id" => "policy.md",
        "title" => "Synthetic policy",
        "body" => text
      })

    {:ok, citation} = Evidence.citation(source["latest_revision"]["id"], 0, byte_size(text))
    {:ok, claim} = Evidence.create_claim(%{"text" => text, "citations" => [citation]})

    {:ok, _} =
      Decisions.decide(claim["id"], %{
        "actor" => "synthetic-test",
        "decision" => "approve",
        "expected_revision_hash" => claim["revision_hash"]
      })

    {:ok, _} = Company.save_profile(%{"name" => "Synthetic Company"})
    {:ok, repo} = Company.create_repository(repository("example/service"))

    {:ok, project} =
      Company.create_project(%{
        "name" => "Selected",
        "repository_ids" => [repo["id"]],
        "source_ids" => [source["id"]]
      })

    {:ok, plan} =
      Company.create_plan(%{
        "name" => "synthetic-company",
        "package_version" => "0.1.0",
        "project_id" => project["id"],
        "repository_ids" => [repo["id"]],
        "claim_refs" => [Map.take(claim, ~w(id revision_hash))],
        "goal_ids" => [],
        "template_ids" => ["reviewed-change-v1"],
        "runtime" => "opencode",
        "runtime_version" => "unqualified",
        "execution" => %{"max_turns" => 20, "timeout_seconds" => 300}
      })

    {:ok, _} =
      Company.decide_plan(plan["id"], %{
        "actor" => "synthetic-test",
        "decision" => "approve",
        "expected_revision_hash" => plan["revision_hash"]
      })

    {:ok, artifact} = Harnesses.build_plan(plan["id"], plan["revision_hash"])
    %{source: source, plan: plan, artifact: artifact}
  end

  defp repository(identity),
    do: %{
      "identity" => identity,
      "name" => identity,
      "purpose" => "Synthetic privacy fixture",
      "owner" => "test-team"
    }

  defp count(table, id),
    do:
      Repo.query!("SELECT count(*) FROM #{table} WHERE workspace_id = ?", [id]).rows
      |> hd()
      |> hd()

  defp db_rows(root, query) do
    {:ok, connection} = Sqlite3.open(Path.join(root, "data.sqlite3"))

    try do
      {:ok, statement} = Sqlite3.prepare(connection, query)

      try do
        {:ok, rows} = Sqlite3.fetch_all(connection, statement)
        rows
      after
        Sqlite3.release(connection, statement)
      end
    after
      Sqlite3.close(connection)
    end
  end
end
