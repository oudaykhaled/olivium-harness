defmodule HarnessForge.CompanyAnalysisOutputTest do
  use ExUnit.Case, async: true
  alias HarnessForge.Models.{CompanyAnalysis, Profile}

  setup do
    sources =
      for body <- ["Café policy", "Recurring failure"],
          do: %{
            "id" => Ecto.UUID.generate(),
            "latest_revision" => %{
              "id" => Ecto.UUID.generate(),
              "body" => body,
              "body_hash" => HarnessForge.Evidence.Store.hash(body)
            }
          }

    citations =
      Enum.map(sources, fn source ->
        %{
          "source_id" => source["id"],
          "revision_id" => source["latest_revision"]["id"],
          "start_byte" => 0,
          "end_byte" => byte_size(source["latest_revision"]["body"]),
          "snippet" => source["latest_revision"]["body"]
        }
      end)

    report = %{
      "findings" => [
        %{"kind" => "practice", "statement" => "A documented practice.", "citations" => citations}
      ],
      "recommendation" => %{
        "rule" => "Keep explicit review.",
        "workflow" => "Record review.",
        "check" => "Inspect the review record.",
        "evaluation_criterion" => "Missing review fails.",
        "goal_rationale" => "The saved goal requires review.",
        "status" => "supported"
      },
      "uncertainty" =>
        "Two sources provide structural coverage; their consistency needs human review."
    }

    %{sources: sources, report: report, citations: citations}
  end

  test "finite server-owned profile preserves the original report and UTF-8 bytes", ctx do
    assert Profile.schema(%{"purpose" => "company_analysis"}) == CompanyAnalysis.schema()
    assert Profile.name(%{"purpose" => "company_analysis"}) == "company_analysis"
    assert CompanyAnalysis.system() =~ "untrusted data"
    assert {:ok, report} = CompanyAnalysis.validate(Jason.encode!(ctx.report), ctx.sources)
    assert report == ctx.report

    assert {:ok, ^report} =
             CompanyAnalysis.validate_detailed(Jason.encode!(ctx.report), ctx.sources)
  end

  test "foreign references, forged spans and split UTF-8 codepoints refuse output", ctx do
    [citation | rest] = ctx.citations

    for bad <- [
          Map.put(citation, "source_id", Ecto.UUID.generate()),
          Map.put(citation, "revision_id", Ecto.UUID.generate()),
          Map.put(citation, "snippet", "forged"),
          Map.put(citation, "end_byte", 4),
          Map.merge(citation, %{"start_byte" => 0, "end_byte" => 4, "snippet" => "Caf?"}),
          Map.put(citation, "end_byte", 100_000),
          Map.put(citation, "start_byte", -1)
        ] do
      report = put_in(ctx.report, ["findings", Access.at(0), "citations"], [bad | rest])
      assert {:error, :invalid_company_analysis_output} = validate(report, ctx.sources)
    end
  end

  test "strict keys, duplicate JSON keys, depth, byte and character bounds fail closed", ctx do
    for report <- [
          Map.put(ctx.report, "approve", true),
          put_in(ctx.report, ["recommendation", "status"], "approved"),
          put_in(ctx.report, ["uncertainty"], " "),
          put_in(ctx.report, ["recommendation", "rule"], String.duplicate("é", 1001)),
          put_in(ctx.report, ["findings"], List.duplicate(hd(ctx.report["findings"]), 7)),
          put_in(ctx.report, ["findings", Access.at(0), "kind"], "policy")
        ] do
      assert {:error, :invalid_company_analysis_output} = validate(report, ctx.sources)
    end

    for bytes <- [
          "{\"findings\":[],\"findings\":[],\"recommendation\":null,\"uncertainty\":\"Unknown\"}",
          String.duplicate("[", 13) <> "null" <> String.duplicate("]", 13),
          String.duplicate("x", 32_769),
          <<255>>
        ] do
      assert {:error, :invalid_company_analysis_output} =
               CompanyAnalysis.validate(bytes, ctx.sources)
    end
  end

  test "two quotes from one source do not meet structural coverage; abstention and unknowns are valid",
       ctx do
    one_source =
      put_in(
        ctx.report,
        ["findings", Access.at(0), "citations"],
        List.duplicate(hd(ctx.citations), 2)
      )

    assert {:error, :invalid_company_analysis_output} = validate(one_source, ctx.sources)

    abstention = %{
      "findings" => [
        %{"kind" => "unknown", "statement" => "Missing decision history.", "citations" => []}
      ],
      "recommendation" => nil,
      "uncertainty" => "No sufficient basis for a recommendation."
    }

    assert {:ok, ^abstention} = validate(abstention, ctx.sources)

    assert {:error, :invalid_company_analysis_output} =
             validate(
               put_in(abstention, ["findings", Access.at(0), "citations"], ctx.citations),
               ctx.sources
             )
  end

  test "sixteen distinct spans is a global bound", ctx do
    source = hd(ctx.sources) |> put_in(["latest_revision", "body"], String.duplicate("a", 17))

    citations =
      for n <- 0..16,
          do: %{
            "source_id" => source["id"],
            "revision_id" => source["latest_revision"]["id"],
            "start_byte" => n,
            "end_byte" => n + 1,
            "snippet" => "a"
          }

    findings =
      citations
      |> Enum.chunk_every(4)
      |> Enum.map(
        &%{"kind" => "discussion", "statement" => "Discussion only.", "citations" => &1}
      )

    report = %{ctx.report | "findings" => findings, "recommendation" => nil}
    assert {:error, :invalid_company_analysis_output} = validate(report, [source])
  end

  test "detailed rejection returns only finite tags while the existing wrapper keeps its contract",
       ctx do
    canary = "PRIVATE_REJECTED_RESPONSE_CANARY"

    mismatched =
      put_in(
        ctx.report,
        ["findings", Access.at(0), "citations", Access.at(0), "revision_id"],
        Ecto.UUID.generate()
      )

    for {bytes, reason} <- [
          {String.duplicate(canary, 1500), :size},
          {canary <> <<255>>, :utf8},
          {"{\"" <> canary <> "\":", :json_or_duplicate},
          {"{\"findings\":[],\"recommendation\":null,\"uncertainty\":\"" <>
             canary <> "\",\"uncertainty\":\"duplicate\"}", :json_or_duplicate},
          {String.duplicate("[", 13) <> Jason.encode!(canary) <> String.duplicate("]", 13),
           :depth},
          {Jason.encode!(Map.put(ctx.report, canary, canary)), :structure},
          {Jason.encode!(Map.put(mismatched, "uncertainty", canary)), :citation_mismatch},
          {Jason.encode!(%{"value" => 1.5, "private" => canary}), :structure},
          {nil, :structure}
        ] do
      result = CompanyAnalysis.validate_detailed(bytes, ctx.sources)
      assert result == {:error, {:invalid_company_analysis_output, reason}}
      assert is_atom(reason)
      refute inspect(result) =~ canary

      assert {:error, :invalid_company_analysis_output} =
               CompanyAnalysis.validate(bytes, ctx.sources)
    end
  end

  test "citation mismatch distinguishes foreign identities, wrong bytes, range and UTF-8 splits",
       ctx do
    [citation | rest] = ctx.citations

    for bad <- [
          Map.put(citation, "source_id", Ecto.UUID.generate()),
          Map.put(citation, "revision_id", Ecto.UUID.generate()),
          Map.put(citation, "snippet", String.duplicate("x", byte_size(citation["snippet"]))),
          Map.merge(citation, %{
            "start_byte" => 100_000,
            "end_byte" => 100_000 + byte_size(citation["snippet"])
          }),
          Map.merge(citation, %{"start_byte" => 3, "end_byte" => 4, "snippet" => "?"})
        ] do
      report = put_in(ctx.report, ["findings", Access.at(0), "citations"], [bad | rest])

      assert {:error, {:invalid_company_analysis_output, :citation_mismatch}} =
               CompanyAnalysis.validate_detailed(Jason.encode!(report), ctx.sources)

      assert {:error, :invalid_company_analysis_output} = validate(report, ctx.sources)
    end
  end

  test "passage validation retains generic refusal and accepts the same valid abstention" do
    abstention = %{
      "findings" => [],
      "recommendation" => nil,
      "uncertainty" => "Insufficient evidence."
    }

    assert {:ok, ^abstention} = CompanyAnalysis.validate_passages(Jason.encode!(abstention), [])

    for bytes <- [
          "{",
          "{\"x\":1,\"x\":2}",
          String.duplicate("[", 13) <> "null" <> String.duplicate("]", 13)
        ] do
      assert {:error, :invalid_company_analysis_output} =
               CompanyAnalysis.validate_passages(bytes, [])
    end
  end

  test "UI diagnostics use fixed copy and never interpolate an unknown rejection reason" do
    ui = HarnessForgeWeb.Company.Analysis
    reasons = [:size, :utf8, :json_or_duplicate, :depth, :structure, :citation_mismatch]
    messages = Enum.map(reasons, &ui.error_message({:invalid_company_analysis_output, &1}))
    assert length(Enum.uniq(messages)) == length(reasons)

    assert Enum.all?(
             messages,
             &(String.starts_with?(&1, "Analysis rejected:") && String.length(&1) <= 100)
           )

    canary = "PRIVATE_REJECTED_REASON_CANARY"
    refute ui.error_message({:invalid_company_analysis_output, canary}) =~ canary
  end

  defp validate(report, sources), do: CompanyAnalysis.validate(Jason.encode!(report), sources)
end
