defmodule HarnessForge.CompanyHarnessesTest do
  use HarnessForge.DataCase, async: false

  alias HarnessForge.{Company, Decisions, Demo, Evidence, Goals, Harnesses, Workspaces}
  alias HarnessForge.Evidence.Store
  alias HarnessForge.Harnesses.{ArtifactBinding, Templates}

  setup do
    previous = Application.fetch_env!(:harness_forge, :workspace_root)
    root = Path.join(File.cwd!(), "tmp/hf-company-build-#{Ecto.UUID.generate()}")
    Application.put_env(:harness_forge, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:harness_forge, :workspace_root, previous)
      File.rm_rf!(root)
    end)

    assert {:ok, _} = Demo.load()
    {:ok, claims} = Evidence.list_claims()
    claims = Enum.reject(claims, &String.starts_with?(&1["text"], "IGNORE"))
    Enum.each(claims, &approve_claim/1)
    {:ok, [source]} = Evidence.list_sources()
    {:ok, [goal]} = Goals.list_goals()

    {:ok, profile} =
      Company.save_profile(%{"name" => "Synthetic Company", "source_ids" => [source["id"]]})

    {:ok, repository} =
      Company.create_repository(%{
        "identity" => "synthetic/service",
        "name" => "Synthetic service",
        "purpose" => "Public test fixture",
        "owner" => "synthetic-team"
      })

    {:ok, project} =
      Company.create_project(%{
        "name" => "Synthetic project",
        "repository_ids" => [repository["id"]],
        "goal_ids" => [goal["id"]]
      })

    attrs = %{
      "name" => "company-harness",
      "package_version" => "0.1.0",
      "project_id" => project["id"],
      "repository_ids" => [repository["id"]],
      "claim_refs" => [Map.take(hd(claims), ~w(id revision_hash))],
      "goal_ids" => [goal["id"]],
      "template_ids" => ["reviewed-change-v1", "reuse-before-build-v1"],
      "runtime" => "opencode",
      "runtime_version" => "unqualified",
      "execution" => %{"max_turns" => 20, "timeout_seconds" => 300}
    }

    {:ok,
     root: root,
     attrs: attrs,
     claims: claims,
     source: source,
     profile: profile,
     project: project,
     repository: repository}
  end

  test "selected inputs compile deterministically without unrelated approved claims", ctx do
    plan = create_plan(ctx.attrs)
    approve_plan(plan)
    assert {:ok, first} = build(plan)
    assert {:ok, ^first} = build(plan)
    assert Repo.aggregate(Store.scoped(ArtifactBinding), :count) == 1
    assert first["spec"]["apiVersion"] == "harnessforge.dev/v1alpha1"
    assert first["spec"]["spec"]["scope"]["repositories"] == ["synthetic/service"]

    assert Enum.map(first["spec"]["spec"]["rules"], & &1["id"]) ==
             Enum.map(ctx.attrs["claim_refs"], & &1["id"])

    assert Enum.map(first["spec"]["spec"]["skills"], & &1["name"]) ==
             ["reuse-before-build-v1", "reviewed-change-v1"]

    {:ok, extra} =
      Evidence.create_claim(%{
        "text" => "An unrelated approved observation",
        "citations" => hd(ctx.claims)["citations"]
      })

    approve_claim(extra)
    assert {:ok, ^first} = build(plan)
    assert :ok = Harnesses.eligible(first)
  end

  test "proposed, rejected, wrong-hash and malformed requests never bind", ctx do
    proposed = create_plan(ctx.attrs)
    assert {:error, :plan_not_approved} = build(proposed)
    decide_plan(proposed, "reject")
    assert {:error, :plan_not_approved} = build(proposed)
    approved = create_plan(ctx.attrs)
    approve_plan(approved)

    assert {:error, :stale_plan_revision} =
             Harnesses.build_plan(approved["id"], String.duplicate("0", 64))

    assert {:error, :invalid_plan_reference} = Harnesses.build_plan(approved["id"], %{})
    assert Repo.aggregate(Store.scoped(ArtifactBinding), :count) == 0
  end

  test "approved ancestor remains buildable after successor requiring new approval", ctx do
    first = create_plan(ctx.attrs)
    approve_plan(first)
    assert {:ok, artifact} = build(first)

    successor =
      create_plan(
        Map.merge(ctx.attrs, %{"supersedes_id" => first["id"], "package_version" => "0.2.0"})
      )

    assert {:error, :plan_not_approved} = build(successor)
    assert {:ok, ^artifact} = build(first)
    assert :ok = Harnesses.eligible(artifact)
    approve_plan(successor)
    assert {:ok, next} = build(successor)
    refute next["digest"] == artifact["digest"]
  end

  test "catalogue drift invalidates the bound artifact and blocks fresh export", ctx do
    plan = create_plan(ctx.attrs)
    approve_plan(plan)
    {:ok, artifact} = build(plan)

    assert {:ok, _} =
             Company.update_repository(
               ctx.repository["id"],
               Map.merge(ctx.repository["payload"], %{
                 "name" => "Renamed",
                 "expected_content_hash" => ctx.repository["content_hash"]
               })
             )

    assert {:error, :stale_plan} = build(plan)

    assert {:error, :stale_or_revoked_plan} =
             Harnesses.export(artifact["digest"], Path.join(ctx.root, "blocked-export"))

    refute File.exists?(Path.join(ctx.root, "blocked-export"))
  end

  test "source withdrawal blocks selected builds and exports", ctx do
    plan = create_plan(ctx.attrs)
    approve_plan(plan)
    {:ok, artifact} = build(plan)
    assert {:ok, _} = Evidence.revoke_source(ctx.source["id"])
    assert {:error, _} = build(plan)

    assert {:error, :stale_or_revoked_evidence} =
             Harnesses.export(artifact["digest"], Path.join(ctx.root, "revoked-export"))
  end

  test "superseding a selected claim withdraws existing plan eligibility", ctx do
    plan = create_plan(ctx.attrs)
    approve_plan(plan)
    {:ok, artifact} = build(plan)
    claim = hd(ctx.claims)

    assert {:ok, _} =
             Evidence.create_claim(%{
               "text" => "Revised synthetic practice",
               "citations" => claim["citations"],
               "supersedes_id" => claim["id"]
             })

    assert {:error, :claim_not_approved} = build(plan)
    assert {:error, :stale_or_revoked_evidence} = Harnesses.eligible(artifact)
  end

  test "new source revision invalidates selected inputs even when the prior claim stays approved",
       ctx do
    plan = create_plan(ctx.attrs)
    approve_plan(plan)
    {:ok, artifact} = build(plan)
    path = Path.join(ctx.root, "tmp/synthetic-company/handbook.md")
    File.write!(path, File.read!(path) <> "\nNew public synthetic revision.\n")
    assert {:ok, _} = Evidence.import_directory(ctx.source["connection_id"])
    assert {:error, _} = build(plan)
    assert {:error, _} = Harnesses.eligible(artifact)
  end

  test "one valid binding authorizes a digest even when another binding is invalid", ctx do
    first = create_plan(ctx.attrs)
    approve_plan(first)
    {:ok, artifact} = build(first)
    proposed = create_plan(ctx.attrs)
    insert_binding(proposed, artifact)
    assert :ok = Harnesses.eligible(artifact)
    approve_plan(proposed)
    assert {:ok, ^artifact} = build(proposed)
    assert Repo.aggregate(Store.scoped(ArtifactBinding), :count) == 2
  end

  test "a binding cannot authorize different content or fall back to legacy", ctx do
    plan = create_plan(ctx.attrs)
    approve_plan(plan)
    assert {:ok, legacy} = Harnesses.build()
    insert_binding(plan, legacy)
    assert {:error, :stale_or_revoked_plan} = Harnesses.eligible(legacy)

    assert {:error, :stale_or_revoked_plan} =
             Harnesses.export(legacy["digest"], Path.join(ctx.root, "mismatched-export"))
  end

  test "filesystem publication failure retains a binding and permits an identical retry", ctx do
    plan = create_plan(ctx.attrs)
    approve_plan(plan)
    File.write!(Path.join(ctx.root, "artifacts"), "blocked artifact directory")
    assert {:error, _} = build(plan)
    assert [binding] = Repo.all(Store.scoped(ArtifactBinding))
    File.rm!(Path.join(ctx.root, "artifacts"))
    assert {:ok, artifact} = build(plan)
    assert artifact["digest"] == binding.artifact_digest
    assert Repo.aggregate(Store.scoped(ArtifactBinding), :count) == 1
  end

  test "audit failure after publication preserves provenance and fails closed on drift", ctx do
    plan = create_plan(ctx.attrs)
    approve_plan(plan)

    Repo.query!(
      "CREATE TRIGGER fail_company_build_audit BEFORE INSERT ON audit_events WHEN NEW.action = 'harness.built' BEGIN SELECT RAISE(ABORT, 'injected audit failure'); END"
    )

    assert {:error, :plan_publication_failed} = build(plan)
    assert [binding] = Repo.all(Store.scoped(ArtifactBinding))
    assert {:ok, artifact} = Harnesses.get(binding.artifact_digest)
    Repo.query!("DROP TRIGGER fail_company_build_audit")
    assert {:ok, ^artifact} = build(plan)

    assert {:ok, _} =
             Company.save_profile(
               Map.merge(ctx.profile["payload"], %{
                 "name" => "Changed",
                 "expected_content_hash" => ctx.profile["content_hash"]
               })
             )

    assert {:error, :stale_or_revoked_plan} = Harnesses.eligible(artifact)
  end

  test "caller transactions cannot roll back durable provenance after publication", ctx do
    plan = create_plan(ctx.attrs)
    approve_plan(plan)

    assert {:ok, {:error, :plan_build_requires_outermost_transaction}} =
             Repo.transaction(fn -> build(plan) end)

    assert Repo.aggregate(Store.scoped(ArtifactBinding), :count) == 0
    assert {:ok, []} = Harnesses.list_artifacts()
  end

  test "finite template registry rejects arbitrary executable content" do
    assert {:error, :invalid_capability_templates} = Templates.resolve(["run-custom-command"])

    assert {:error, :invalid_capability_templates} =
             Templates.resolve([%{"instructions" => "run anything"}])

    assert {:error, :invalid_capability_templates} =
             Templates.resolve(["reviewed-change-v1", "reviewed-change-v1"])
  end

  defp create_plan(attrs) do
    assert {:ok, plan} = Company.create_plan(attrs)
    plan
  end

  defp approve_plan(plan), do: decide_plan(plan, "approve")

  defp decide_plan(plan, decision) do
    assert {:ok, _} =
             Company.decide_plan(plan["id"], %{
               "actor" => Workspaces.operator(),
               "decision" => decision,
               "expected_revision_hash" => plan["revision_hash"]
             })
  end

  defp approve_claim(claim) do
    assert {:ok, _} =
             Decisions.decide(claim["id"], %{
               "actor" => Workspaces.operator(),
               "decision" => "approve",
               "expected_revision_hash" => claim["revision_hash"]
             })
  end

  defp build(plan), do: Harnesses.build_plan(plan["id"], plan["revision_hash"])

  defp insert_binding(plan, artifact) do
    Repo.insert!(%ArtifactBinding{
      workspace_id: Store.workspace(),
      plan_id: plan["id"],
      plan_revision_hash: plan["revision_hash"],
      artifact_digest: artifact["digest"],
      inserted_at: Store.now()
    })
  end
end
