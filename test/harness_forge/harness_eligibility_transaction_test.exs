defmodule HarnessForge.HarnessEligibilityTransactionTest do
  use HarnessForge.DataCase, async: false

  alias HarnessForge.{
    Company,
    CompanyAnalysisFixture,
    Decisions,
    Evidence,
    Evaluations,
    Harnesses,
    Workspaces
  }

  setup do
    previous = {Workspaces.root(), Workspaces.current_id()}
    id = Ecto.UUID.generate()
    root = Path.join(File.cwd!(), "tmp/eligibility-transaction-#{id}")
    Enum.each(~w(artifacts runs tmp evidence), &File.mkdir_p!(Path.join(root, &1)))
    Application.put_env(:harness_forge, :workspace_root, root)
    Application.put_env(:harness_forge, :workspace_id, id)

    on_exit(fn ->
      Application.put_env(:harness_forge, :workspace_root, elem(previous, 0))
      Application.put_env(:harness_forge, :workspace_id, elem(previous, 1))
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "stale plan denial preserves an owning transaction without granting eligibility", c do
    fixture = CompanyAnalysisFixture.create!(c.root)
    source = hd(fixture.sources)
    revision = source["latest_revision"]
    {:ok, citation} = Evidence.citation(revision["id"], 0, byte_size(revision["body"]))

    {:ok, claim} =
      Evidence.create_claim(%{"text" => "Public synthetic policy", "citations" => [citation]})

    {:ok, claim} = Decisions.decide(claim["id"], CompanyAnalysisFixture.decision(claim))

    attrs =
      Map.merge(CompanyAnalysisFixture.plan_attrs(fixture, claim), %{
        "runtime" => "codex",
        "runtime_version" => "0.156.0"
      })

    {:ok, plan} = Company.create_plan(attrs)
    {:ok, _} = Company.decide_plan(plan["id"], CompanyAnalysisFixture.decision(plan))
    {:ok, artifact} = Harnesses.build_plan(plan["id"], plan["revision_hash"])
    assert :ok = Harnesses.eligible(artifact)
    {:ok, run} = Evaluations.run(artifact["digest"], kind: :static_integrity)

    repository = fixture.repository

    {:ok, _} =
      Company.update_repository(
        repository["id"],
        Map.merge(repository["payload"], %{
          "purpose" => "Changed public synthetic purpose",
          "expected_content_hash" => repository["content_hash"]
        })
      )

    assert {:ok, :accounting_persisted} =
             Repo.transaction(fn ->
               assert {:error, :stale_or_revoked_plan} = Harnesses.eligible(artifact)
               # Test an unrelated safe result update after the expected read denial.
               # No execution outcome/qualification is granted by this sentinel.
               changed = Map.put(run, "test_accounting_sentinel", "persisted")

               Repo.query!(
                 "UPDATE evaluation_runs SET result=? WHERE id=? AND workspace_id=?",
                 [Jason.encode!(changed), run["id"], Workspaces.current_id()]
               )

               :accounting_persisted
             end)

    assert {:ok, stored} = Evaluations.get(run["id"])
    assert stored["test_accounting_sentinel"] == "persisted"
    refute stored["runtime_qualified"]
    assert {:error, :stale_or_revoked_plan} = Harnesses.eligible(artifact)

    assert {:error, :harness_unavailable} =
             HarnessForgeWeb.HarnessDelivery.preview(artifact["digest"])
  end
end
