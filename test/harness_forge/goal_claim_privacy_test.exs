defmodule HarnessForge.GoalClaimPrivacyTest do
  use ExUnit.Case, async: false

  alias HarnessForge.{
    Company,
    Compiler,
    Decisions,
    Evidence,
    Goals,
    Harnesses,
    Privacy,
    Repo,
    Workspaces
  }

  setup tags do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: tags[:committed] != true)
    previous_root = Workspaces.root()
    previous_id = Workspaces.current_id()
    id = Ecto.UUID.generate()
    base = Path.join(File.cwd!(), "tmp/goal-privacy-#{id}")
    root = Path.join(base, "workspace")
    for directory <- ~w(artifacts runs tmp), do: File.mkdir_p!(Path.join(root, directory))
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

      Application.put_env(:harness_forge, :workspace_root, previous_root)
      Application.put_env(:harness_forge, :workspace_id, previous_id)
      File.rm_rf!(base)
    end)

    %{id: id, root: root, base: base}
  end

  test "unrelated source purge retains independent goal family, approved plan and artifact",
       ctx do
    fixture = goal_fixture()
    source = source_fixture(ctx)

    {:ok, successor} =
      Evidence.create_claim(
        Map.merge(goal_attrs(fixture.goal), %{
          "supersedes_id" => fixture.claim["id"],
          "text" => "Record the final review outcome"
        })
      )

    {:ok, successor} = Decisions.decide(successor["id"], decision(successor))

    {:ok, plan} =
      Company.create_plan(
        Map.put(fixture.attrs, "claim_refs", [Map.take(successor, ~w(id revision_hash))])
      )

    {:ok, _} = Company.decide_plan(plan["id"], decision(plan))
    {:ok, artifact} = Harnesses.build_plan(plan["id"], plan["revision_hash"])
    assert {:ok, _} = Privacy.purge_source(source.source["id"], source.source["id"])
    assert {:ok, retained} = Evidence.get_claim(successor["id"])
    assert retained["basis"] == successor["basis"]
    assert retained["family_id"] == fixture.claim["family_id"]
    assert retained["status"] == "approved"
    assert {:ok, %{"superseded" => true}} = Evidence.get_claim(fixture.claim["id"])
    assert :ok = Harnesses.eligible(artifact)
    assert {:ok, _} = Harnesses.export(artifact["digest"], Path.join(ctx.root, "retained-export"))
    assert {:error, :not_found} = Evidence.get_claim(source.claim["id"])
  end

  test "purging a separate source dependency removes mixed plan artifacts but keeps goal authority",
       ctx do
    fixture = goal_fixture()
    source = source_fixture(ctx)

    {:ok, _} =
      Company.update_project(
        fixture.project["id"],
        replacement(fixture.project, %{"source_ids" => [source.source["id"]]})
      )

    attrs =
      Map.put(fixture.attrs, "claim_refs", [
        Map.take(fixture.claim, ~w(id revision_hash)),
        Map.take(source.claim, ~w(id revision_hash))
      ])

    {:ok, plan} = Company.create_plan(attrs)
    {:ok, _} = Company.decide_plan(plan["id"], decision(plan))
    {:ok, artifact} = Harnesses.build_plan(plan["id"], plan["revision_hash"])
    assert {:ok, _} = Privacy.purge_source(source.source["id"], source.source["id"])
    assert {:error, :not_found} = Company.get_plan(plan["id"])
    assert {:error, _} = Harnesses.get(artifact["digest"])
    assert {:error, :stale_or_revoked_evidence} = Harnesses.eligible(artifact)

    assert {:ok, %{"status" => "approved", "basis" => basis}} =
             Evidence.get_claim(fixture.claim["id"])

    assert basis == fixture.claim["basis"]
    assert count("company_artifact_bindings", ctx.id) == 1
  end

  test "workspace purge removes goal bases and all associated approvals and bindings", ctx do
    fixture = goal_fixture()
    assert {:ok, inventory} = Privacy.inventory()
    assert inventory["records"]["evidence_claims"] == 1
    assert {:ok, _} = Privacy.purge_workspace(ctx.id)

    for table <-
          ~w(evidence_claims workspace_goals claim_decisions company_plans company_plan_decisions company_artifact_bindings),
        do: assert(count(table, ctx.id) == 0)

    assert {:ok, []} = Harnesses.list_artifacts()
    assert {:error, :stale_or_revoked_evidence} = Harnesses.eligible(fixture.artifact)
  end

  test "failed selective file removal retains binding evidence and cannot authorize a goal descendant",
       ctx do
    fixture = goal_fixture()
    source = source_fixture(ctx)

    {:ok, _} =
      Company.update_project(
        fixture.project["id"],
        replacement(fixture.project, %{"source_ids" => [source.source["id"]]})
      )

    {:ok, ancestor} =
      Company.create_plan(
        Map.merge(fixture.attrs, %{
          "claim_refs" => [Map.take(source.claim, ~w(id revision_hash))],
          "goal_ids" => []
        })
      )

    {:ok, _} = Company.decide_plan(ancestor["id"], decision(ancestor))

    {:ok, descendant} =
      Company.create_plan(
        Map.merge(fixture.attrs, %{
          "supersedes_id" => ancestor["id"],
          "package_version" => "0.2.0"
        })
      )

    {:ok, _} = Company.decide_plan(descendant["id"], decision(descendant))
    {:ok, artifact} = Harnesses.build_plan(descendant["id"], descendant["revision_hash"])

    run =
      Repo.insert!(%HarnessForge.Evaluation.Run{
        id: Ecto.UUID.generate(),
        workspace_id: ctx.id,
        artifact_digest: artifact["digest"],
        result: %{
          "kind" => "runtime_smoke",
          "outcome" => "interrupted",
          "cleanup_status" => "cleanup_failed"
        }
      })

    previous_docker = System.get_env("DOCKER_HOST")
    System.put_env("DOCKER_HOST", "tcp://untrusted.invalid:2375")

    try do
      assert {:error, :cleanup_failed} =
               Privacy.purge_source(source.source["id"], source.source["id"])

      Repo.delete!(run)
      owned = Path.join([ctx.root, "artifacts", artifact["digest"]])
      saved = Path.join(ctx.base, "saved-artifact")
      outside = Path.join(ctx.base, "outside")
      File.rename!(owned, saved)
      File.mkdir!(outside)
      File.write!(Path.join(outside, "keep.txt"), "untouched")
      File.ln_s!(outside, owned)

      assert {:error, :unsafe_path} =
               Privacy.purge_source(source.source["id"], source.source["id"])

      assert {:error, :privacy_operation_incomplete} = Privacy.ready()

      assert Repo.query!(
               "SELECT count(*) FROM company_artifact_bindings WHERE workspace_id = ? AND artifact_digest = ?",
               [ctx.id, artifact["digest"]]
             ).rows == [[1]]

      assert {:error, :stale_or_revoked_plan} = Harnesses.eligible(artifact)
      assert File.read!(Path.join(outside, "keep.txt")) == "untouched"
      File.rm!(owned)
      File.rename!(saved, owned)
      assert :ok = Privacy.reconcile()
      assert :ok = Privacy.ready()
      refute File.exists?(owned)
      assert {:error, :stale_or_revoked_plan} = Harnesses.eligible(artifact)

      assert Repo.query!(
               "SELECT count(*) FROM company_artifact_bindings WHERE workspace_id = ? AND artifact_digest = ?",
               [ctx.id, artifact["digest"]]
             ).rows == [[0]]
    after
      if previous_docker,
        do: System.put_env("DOCKER_HOST", previous_docker),
        else: System.delete_env("DOCKER_HOST")
    end
  end

  test "failed workspace file removal retains goal binding until successful retry", ctx do
    fixture = goal_fixture()

    run =
      Repo.insert!(%HarnessForge.Evaluation.Run{
        id: Ecto.UUID.generate(),
        workspace_id: ctx.id,
        artifact_digest: fixture.artifact["digest"],
        result: %{
          "kind" => "runtime_smoke",
          "outcome" => "interrupted",
          "cleanup_status" => "cleanup_failed"
        }
      })

    previous_docker = System.get_env("DOCKER_HOST")
    System.put_env("DOCKER_HOST", "tcp://untrusted.invalid:2375")

    try do
      assert {:error, :cleanup_failed} = Privacy.purge_workspace(ctx.id)
      Repo.delete!(run)
      owned = Path.join(ctx.root, "artifacts")
      saved = Path.join(ctx.base, "saved-artifacts")
      outside = Path.join(ctx.base, "outside")
      File.rename!(owned, saved)
      File.mkdir!(outside)
      File.write!(Path.join(outside, "keep.txt"), "untouched")
      File.ln_s!(outside, owned)
      assert {:error, :unsafe_path} = Privacy.purge_workspace(ctx.id)
      assert {:error, :privacy_operation_incomplete} = Privacy.ready()
      assert count("company_artifact_bindings", ctx.id) == 1
      assert count("evidence_claims", ctx.id) == 0
      assert {:error, :stale_or_revoked_evidence} = Harnesses.eligible(fixture.artifact)
      assert File.read!(Path.join(outside, "keep.txt")) == "untouched"
      File.rm!(owned)
      File.rename!(saved, owned)
      assert :ok = Privacy.reconcile()
      assert :ok = Privacy.ready()
      assert count("company_artifact_bindings", ctx.id) == 0
      refute File.exists?(owned)
      assert File.read!(Path.join(outside, "keep.txt")) == "untouched"
    after
      if previous_docker,
        do: System.put_env("DOCKER_HOST", previous_docker),
        else: System.delete_env("DOCKER_HOST")
    end
  end

  @tag :committed
  test "goal backup preserves immutable bytes and basis while actual restored admission lacks approval",
       ctx do
    fixture = goal_fixture()
    backup = Path.join(ctx.base, "backup")
    restored = Path.join(ctx.base, "restored")
    assert {:ok, _} = Privacy.backup(backup)

    assert {:ok,
            %{
              "workspace_id" => restored_id,
              "approvals_restored" => false,
              "state" => "quarantined"
            }} = Privacy.restore(backup, restored)

    refute restored_id == ctx.id

    {:ok, restored_repo} =
      Repo.start_link(
        name: nil,
        database: Path.join(restored, "data.sqlite3"),
        pool: DBConnection.ConnectionPool,
        pool_size: 1
      )

    original_repo = Repo.put_dynamic_repo(restored_repo)
    Application.put_env(:harness_forge, :workspace_id, restored_id)
    Application.put_env(:harness_forge, :workspace_root, restored)

    try do
      assert {:ok, restored_claim} = Evidence.get_claim(fixture.claim["id"])
      assert restored_claim["basis"] == fixture.claim["basis"]
      assert restored_claim["revision_hash"] == fixture.claim["revision_hash"]
      assert restored_claim["workspace_id"] == restored_id
      assert restored_claim["status"] == "proposed"
      assert {:ok, [goal]} = Goals.list_goals()
      assert Goals.content_hash(goal) == fixture.claim["basis"]["goal_content_hash"]
      assert {:ok, []} = Evidence.approved_claims()
      assert count("claim_decisions", restored_id) == 0
      assert count("company_plan_decisions", restored_id) == 0
      assert count("company_artifact_bindings", restored_id) == 1
      assert {:error, :plan_not_approved} = Company.build_inputs(fixture.plan["id"])
      assert {:ok, historical} = Harnesses.get(fixture.artifact["digest"])
      assert historical == fixture.artifact
      assert :ok = Compiler.verify(historical)
      assert {:error, :stale_or_revoked_evidence} = Harnesses.eligible(historical)
      target = Path.join(restored, "refused-export")
      assert {:error, :stale_or_revoked_evidence} = Harnesses.export(historical["digest"], target)
      refute File.exists?(target)
    after
      Repo.put_dynamic_repo(original_repo)
      Application.put_env(:harness_forge, :workspace_id, ctx.id)
      Application.put_env(:harness_forge, :workspace_root, ctx.root)
      GenServer.stop(restored_repo)
    end
  end

  defp goal_fixture do
    {:ok, goal} =
      Goals.add_goal(%{
        "title" => "Review each change",
        "owner" => "Synthetic",
        "acceptance" => "Record the review"
      })

    {:ok, claim} = Evidence.create_claim(goal_attrs(goal))
    {:ok, claim} = Decisions.decide(claim["id"], decision(claim))
    {:ok, _} = Company.save_profile(%{"name" => "Synthetic Company", "goal_ids" => [goal["id"]]})

    {:ok, repository} =
      Company.create_repository(%{
        "identity" => "synthetic/service",
        "name" => "Service",
        "purpose" => "Synthetic fixture",
        "owner" => "Synthetic"
      })

    {:ok, project} =
      Company.create_project(%{
        "name" => "Synthetic Project",
        "repository_ids" => [repository["id"]]
      })

    attrs = %{
      "name" => "goal-harness",
      "package_version" => "0.1.0",
      "project_id" => project["id"],
      "repository_ids" => [repository["id"]],
      "claim_refs" => [Map.take(claim, ~w(id revision_hash))],
      "goal_ids" => [goal["id"]],
      "template_ids" => ["reviewed-change-v1"],
      "runtime" => "opencode",
      "runtime_version" => "unqualified",
      "execution" => %{"max_turns" => 20, "timeout_seconds" => 300}
    }

    {:ok, plan} = Company.create_plan(attrs)
    {:ok, _} = Company.decide_plan(plan["id"], decision(plan))
    {:ok, artifact} = Harnesses.build_plan(plan["id"], plan["revision_hash"])
    %{goal: goal, claim: claim, project: project, attrs: attrs, plan: plan, artifact: artifact}
  end

  defp source_fixture(ctx) do
    input = Path.join(ctx.base, "input")
    File.mkdir_p!(input)

    {:ok, connection} =
      Evidence.connect(%{
        "name" => "Synthetic source",
        "provider" => "local",
        "directory" => input
      })

    {:ok, source} =
      Evidence.import_markdown(connection["id"], %{
        "external_id" => "source.md",
        "title" => "Synthetic",
        "body" => "Review changes"
      })

    {:ok, citation} = Evidence.citation(source["latest_revision"]["id"], 0, 14)
    {:ok, claim} = Evidence.create_claim(%{"text" => "Review changes", "citations" => [citation]})
    {:ok, claim} = Decisions.decide(claim["id"], decision(claim))
    %{source: source, claim: claim}
  end

  defp goal_attrs(goal),
    do: %{
      "text" => "Record the review outcome",
      "citations" => [],
      "basis" => %{
        "version" => 1,
        "kind" => "goal",
        "goal_id" => goal["id"],
        "goal_content_hash" => Goals.content_hash(goal)
      }
    }

  defp decision(dto),
    do: %{
      "actor" => "synthetic-reviewer",
      "decision" => "approve",
      "expected_revision_hash" => dto["revision_hash"]
    }

  defp replacement(dto, changes),
    do:
      dto["payload"]
      |> Map.merge(changes)
      |> Map.put("expected_content_hash", dto["content_hash"])

  defp count(table, workspace),
    do:
      Repo.query!("SELECT count(*) FROM #{table} WHERE workspace_id = ?", [workspace]).rows
      |> hd()
      |> hd()
end
