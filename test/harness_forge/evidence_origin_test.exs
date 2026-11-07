defmodule HarnessForge.EvidenceOriginTest do
  use ExUnit.Case, async: true
  alias HarnessForge.{Contracts, Evidence.Store}
  alias HarnessForge.Company.Analysis
  alias HarnessForge.Evidence.Origin

  setup do
    refs =
      for _ <- 1..3,
          do: %{
            "source_id" => Ecto.UUID.generate(),
            "revision_id" => Ecto.UUID.generate(),
            "body_hash" => Store.hash("a")
          }

    refs = Enum.sort_by(refs, & &1["source_id"])

    spans =
      refs
      |> Enum.take(2)
      |> Enum.map(fn ref ->
        %{
          "source_id" => ref["source_id"],
          "revision_id" => ref["revision_id"],
          "start_byte" => 0,
          "end_byte" => 1,
          "snippet" => "a"
        }
      end)

    citations =
      Enum.map(spans, fn span ->
        span
        |> Map.delete("source_id")
        |> Map.merge(%{"id" => Ecto.UUID.generate(), "snippet_hash" => Store.hash("a")})
      end)

    guidance = %{
      "rule" => "Rule",
      "workflow" => "Workflow",
      "check" => "Check",
      "evaluation_criterion" => "Evaluation"
    }

    report = %{
      "findings" => [%{"kind" => "practice", "statement" => "Practice", "citations" => spans}],
      "recommendation" =>
        Map.merge(guidance, %{"goal_rationale" => "Goal", "status" => "supported"}),
      "uncertainty" => "Unknown coverage"
    }

    context = %{
      "profile" => %{"id" => Ecto.UUID.generate(), "content_hash" => Store.hash("profile")},
      "project" => %{"id" => Ecto.UUID.generate(), "content_hash" => Store.hash("project")},
      "sources" => refs
    }

    basis = %{
      "kind" => "company_analysis",
      "version" => 1,
      "project_id" => context["project"]["id"],
      "goal_id" => Ecto.UUID.generate(),
      "goal_content_hash" => Store.hash("goal"),
      "context" => context,
      "context_digest" => Contracts.digest(context),
      "report" => report,
      "guidance" => guidance,
      "provider" => "ollama",
      "model" => "synthetic:fixture",
      "config_fingerprint" => Store.hash("config"),
      "run_id" => Ecto.UUID.generate(),
      "request_id" => Ecto.UUID.generate(),
      "review_resolution" => nil
    }

    %{claim: %{"basis" => basis, "citations" => citations}, refs: refs}
  end

  test "pure extraction includes examined uncited revisions and every authority pin", %{
    claim: claim,
    refs: refs
  } do
    assert {:ok, found} = Origin.references(claim)
    assert found["revision_ids"] == refs |> Enum.map(& &1["revision_id"]) |> Enum.sort()
    assert found["source_ids"] == refs |> Enum.map(& &1["source_id"]) |> Enum.sort()
    assert found["project_ids"] == [claim["basis"]["project_id"]]
    assert found["goal_ids"] == [claim["basis"]["goal_id"]]
    assert found["profile_ids"] == [claim["basis"]["context"]["profile"]["id"]]
  end

  test "legacy omitted/nil basis and duplicate citation order retain dependency compatibility", %{
    claim: claim
  } do
    [citation | _] = claim["citations"]

    for legacy <- [
          %{"citations" => [citation, citation]},
          %{"basis" => nil, "citations" => [citation, citation]}
        ] do
      assert {:ok, %{"revision_ids" => [revision], "source_ids" => [], "goal_ids" => []}} =
               Origin.references(legacy)

      assert revision == citation["revision_id"]
    end

    goal_basis =
      Map.take(claim["basis"], ~w(version goal_id goal_content_hash)) |> Map.put("kind", "goal")

    assert {:ok, %{"goal_ids" => [goal], "revision_ids" => []}} =
             Origin.references(%{"basis" => goal_basis, "citations" => []})

    assert goal == goal_basis["goal_id"]
  end

  test "malformed origins and citation elements fail safely", %{claim: claim} do
    for malformed <- [
          %{},
          %{"basis" => %{"kind" => "future"}, "citations" => []},
          %{"basis" => nil, "citations" => [123]},
          %{"basis" => nil, "citations" => [nil]},
          put_in(claim, ["basis", "version"], 2),
          put_in(claim, ["basis", "context_digest"], Store.hash("wrong")),
          put_in(claim, ["basis", "context", "sources"], []),
          Map.put(claim, "citations", [123]),
          Map.put(claim, "citations", [hd(claim["citations"]), hd(claim["citations"])])
        ] do
      assert {:error, :invalid_claim_basis} = Origin.references(malformed)
    end
  end

  test "supported status still requires saved resolution for a declared conflict", %{claim: claim} do
    assert Analysis.approval_ready?(claim)
    conflict = put_in(claim, ["basis", "report", "findings", Access.at(0), "kind"], "conflict")
    refute Analysis.approval_ready?(conflict)

    resolved =
      put_in(
        conflict,
        ["basis", "review_resolution"],
        "The emergency exception governs this goal."
      )

    assert Analysis.approval_ready?(resolved)
    refute Analysis.approval_ready?(%{"basis" => %{"kind" => "company_analysis"}})
  end

  test "successors preserve original report, attribution and canonical citation IDs", %{
    claim: claim
  } do
    assert :ok = Analysis.validate_successor(nil, claim)

    edited =
      claim
      |> put_in(["basis", "guidance", "rule"], "Edited rule")
      |> Map.update!("citations", &Enum.reverse/1)

    assert :ok = Analysis.validate_successor(claim, edited)

    for changed <- [
          put_in(edited, ["basis", "report", "uncertainty"], "Concealed uncertainty"),
          put_in(edited, ["basis", "model"], "different:model"),
          put_in(edited, ["citations", Access.at(0), "id"], Ecto.UUID.generate()),
          Map.put(edited, "basis", nil)
        ] do
      assert {:error, :claim_origin_change} = Analysis.validate_successor(claim, changed)
    end

    assert {:error, :claim_origin_change} = Analysis.validate_successor(%{"basis" => nil}, claim)
    assert {:error, :claim_origin_change} = Analysis.validate_successor(nil, edited)
    resolved = put_in(edited, ["basis", "review_resolution"], "Recorded human scope judgment.")
    assert :ok = Analysis.validate_successor(claim, resolved)
    assert {:error, :claim_origin_change} = Analysis.validate_successor(resolved, edited)
  end
end
