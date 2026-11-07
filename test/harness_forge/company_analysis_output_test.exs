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

  defp validate(report, sources), do: CompanyAnalysis.validate(Jason.encode!(report), sources)
end
