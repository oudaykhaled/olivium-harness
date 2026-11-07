defmodule HarnessForge.CompanyAnalysisIntegrationTest do
  use HarnessForge.DataCase, async: false
  alias HarnessForge.{Company, Contracts, Decisions, Evidence, Goals, Harnesses, Models}
  alias HarnessForge.Company.Analysis
  alias HarnessForge.CompanyAnalysisFixture, as: Fixture
  alias HarnessForge.Evidence.{Claim, Citation, Store}

  setup do
    keys = [:workspace_id, :workspace_root, :model_test_plug]
    previous = Map.new(keys, &{&1, Application.get_env(:harness_forge, &1)})
    root = Path.join(File.cwd!(), "tmp/analysis-integration-" <> Ecto.UUID.generate())
    File.mkdir_p!(root)
    Application.put_env(:harness_forge, :workspace_id, Ecto.UUID.generate())
    Application.put_env(:harness_forge, :workspace_root, root)
    Application.put_env(:harness_forge, :model_test_plug, {Req.Test, __MODULE__})
    fixture = Fixture.create!(root)
    {:ok, _} = Models.configure(%{"model" => "synthetic:company-workflow"})

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        if is_nil(value),
          do: Application.delete_env(:harness_forge, key),
          else: Application.put_env(:harness_forge, key, value)
      end)

      File.rm_rf!(root)
    end)

    %{fixture: fixture, root: root}
  end

  test "reviewed cross-source guidance builds and exports deterministically with no current model",
       c do
    proposal = propose(c.fixture)
    assert length(proposal["basis"]["context"]["sources"]) == 4
    assert proposal["basis"]["report"] == c.fixture.report

    assert {:error, :analysis_resolution_required} =
             Decisions.decide(proposal["id"], Fixture.decision(proposal))

    edits =
      Map.merge(proposal["basis"]["guidance"], %{
        "rule" =>
          "HUMAN_EDITED: emergency changes require a named reviewer and documented exception.",
        "review_resolution" =>
          "The later explicit emergency exception applies only to emergency patches; retain two reviewers otherwise."
      })

    assert {:ok, revised} = Analysis.revise(proposal["id"], proposal["revision_hash"], edits)
    assert revised["status"] == "proposed"
    assert revised["basis"]["report"] == proposal["basis"]["report"]
    assert {:ok, approved} = Decisions.decide(revised["id"], Fixture.decision(revised))
    assert {:ok, plan} = Company.create_plan(Fixture.plan_attrs(c.fixture, approved))
    assert length(plan["snapshot"]["sources"]) == 4
    assert c.fixture.uncited_source["id"] in Enum.map(plan["snapshot"]["sources"], & &1["id"])
    assert {:ok, _} = Company.decide_plan(plan["id"], Fixture.decision(plan))
    assert {:ok, _} = Models.configure(%{})
    assert {:ok, artifact} = Harnesses.build_plan(plan["id"], plan["revision_hash"])
    assert {:ok, same} = Harnesses.build_plan(plan["id"], plan["revision_hash"])
    assert same == artifact
    assert :ok = Harnesses.eligible(artifact)
    assert {:ok, _} = Harnesses.export(artifact["digest"], Path.join(c.root, "fresh-export"))
    bytes = artifact["files"] |> Map.values() |> Enum.join("\n")
    assert bytes =~ "HUMAN_EDITED"
    refute bytes =~ c.fixture.report["recommendation"]["rule"]
    refute bytes =~ "Original model report"
    rule = hd(artifact["spec"]["spec"]["rules"])
    assert rule["goal_id"] == c.fixture.goal["id"]
    assert rule["evidence"] != []
    assert {:error, :goal_claim_requires_plan} = Harnesses.build()
  end

  test "a supported label cannot hide a declared conflict; rejection remains available", c do
    report = put_in(c.fixture.report, ["recommendation", "status"], "supported")
    proposal = propose(c.fixture, report)

    assert {:error, :analysis_resolution_required} =
             Decisions.decide(proposal["id"], Fixture.decision(proposal))

    assert {:ok, rejected} =
             Decisions.decide(proposal["id"], Fixture.decision(proposal, "reject"))

    assert rejected["status"] == "rejected"
    assert {:ok, []} = Evidence.approved_claims()
  end

  test "generic Evidence callers cannot launder or rewrite original analysis provenance", c do
    proposal = propose(c.fixture)

    attrs =
      Map.take(proposal, ~w(text citations basis)) |> Map.put("supersedes_id", proposal["id"])

    assert {:error, :claim_origin_change} = Evidence.create_claim(Map.delete(attrs, "basis"))

    goal_basis = %{
      "kind" => "goal",
      "version" => 1,
      "goal_id" => c.fixture.goal["id"],
      "goal_content_hash" => Goals.content_hash(c.fixture.goal)
    }

    assert {:error, :claim_origin_change} =
             Evidence.create_claim(Map.merge(attrs, %{"basis" => goal_basis, "citations" => []}))

    altered = put_in(attrs, ["basis", "report", "uncertainty"], "Silently changed report")
    assert {:error, :claim_origin_change} = Evidence.create_claim(altered)

    assert {:error, :invalid_claim_basis} =
             Evidence.create_claim(Map.put(attrs, "text", "Unbound arbitrary instructions"))

    assert {:ok, %{"superseded" => false}} = Evidence.get_claim(proposal["id"])
  end

  test "uncited examined-source drift invalidates a previously approved plan and artifact", c do
    proposal = propose(c.fixture)

    attrs =
      Map.put(
        proposal["basis"]["guidance"],
        "review_resolution",
        "Use the explicit emergency exception only for emergency work."
      )

    {:ok, revised} = Analysis.revise(proposal["id"], proposal["revision_hash"], attrs)
    {:ok, approved} = Decisions.decide(revised["id"], Fixture.decision(revised))
    {:ok, plan} = Company.create_plan(Fixture.plan_attrs(c.fixture, approved))
    {:ok, _} = Company.decide_plan(plan["id"], Fixture.decision(plan))
    {:ok, artifact} = Harnesses.build_plan(plan["id"], plan["revision_hash"])
    drift(c.fixture)
    assert {:error, :stale_company_analysis_context} = Evidence.validate_claim(approved)
    assert {:ok, []} = Evidence.approved_claims()
    assert {:error, _} = Company.build_inputs(plan["id"])
    assert {:error, :stale_or_revoked_evidence} = Harnesses.eligible(artifact)
    assert {:error, _} = Harnesses.export(artifact["digest"], Path.join(c.root, "must-not-exist"))
    refute File.exists?(Path.join(c.root, "must-not-exist"))
  end

  test "stale proposal and stale abstention admit no evidence", c do
    for report <- [c.fixture.report, Map.put(c.fixture.report, "recommendation", nil)] do
      before_counts = counts()

      refs =
        Enum.map(c.fixture.input["source_refs"], fn ref ->
          {:ok, source} = Evidence.get_source(ref["source_id"])

          %{
            ref
            | "revision_id" => source["latest_revision"]["id"],
              "body_hash" => source["latest_revision"]["body_hash"]
          }
        end)

      stub(report, fn -> drift(c.fixture) end)

      assert {:error, :stale_company_analysis_context} =
               Analysis.analyze(Map.put(c.fixture.input, "source_refs", refs))

      assert counts() == before_counts
      # Re-capture only in this explicit test setup, never inside the operation.
      {:ok, current} = Evidence.get_source(c.fixture.uncited_source["id"])
      assert current["latest_revision"]["id"] != c.fixture.uncited_source["latest_revision"]["id"]
    end
  end

  test "initial resolution cannot be forged and successor resolution cannot be cleared", c do
    proposal = propose(c.fixture)
    forged = Map.take(proposal, ~w(text citations basis))
    forged = put_in(forged, ["basis", "review_resolution"], "Pretend a human reviewed this")
    assert {:error, :claim_origin_change} = Evidence.create_claim(forged)
    attrs = Map.put(proposal["basis"]["guidance"], "review_resolution", "Explicit human judgment")
    {:ok, revised} = Analysis.revise(proposal["id"], proposal["revision_hash"], attrs)

    assert {:error, _} =
             Analysis.revise(
               revised["id"],
               revised["revision_hash"],
               Map.put(attrs, "review_resolution", "")
             )

    {:ok, next} =
      Analysis.revise(revised["id"], revised["revision_hash"], revised["basis"]["guidance"])

    assert next["basis"]["review_resolution"] == "Explicit human judgment"

    canonical =
      next["citations"]
      |> Enum.map(&Map.take(&1, ~w(id revision_id start_byte end_byte snippet_hash)))
      |> Enum.sort_by(&{&1["revision_id"], &1["start_byte"], &1["end_byte"], &1["id"]})

    assert next["revision_hash"] ==
             Contracts.digest(%{
               "kind" => "company-analysis-claim",
               "version" => 1,
               "text" => next["text"],
               "citations" => canonical,
               "basis" => next["basis"]
             })
  end

  defp propose(fixture, report \\ nil) do
    stub(report || fixture.report)
    assert {:ok, %{"status" => "proposed", "claim" => claim}} = Analysis.analyze(fixture.input)
    claim
  end

  defp stub(report, after_dispatch \\ fn -> :ok end) do
    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/api/tags" ->
          Req.Test.json(conn, %{"models" => [%{"name" => "synthetic:company-workflow"}]})

        "/api/generate" ->
          after_dispatch.()
          Req.Test.json(conn, Fixture.response(report))
      end
    end)
  end

  defp drift(fixture) do
    {:ok, _} =
      Evidence.import_markdown(fixture.connection["id"], %{
        "external_id" => fixture.uncited_source["external_id"],
        "title" => "Synthetic inventory revised",
        "body" => "Changed examined inventory " <> Ecto.UUID.generate()
      })
  end

  defp counts,
    do:
      {Repo.aggregate(Store.scoped(Claim), :count),
       Repo.aggregate(Store.scoped(Citation), :count)}
end
