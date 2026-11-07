defmodule HarnessForge.Company.HistoricalQuestionRegressionTest do
  use HarnessForge.DataCase, async: false

  alias HarnessForge.{Company, CompanyAnalysisFixture, Contracts, Evidence}
  alias HarnessForge.Company.Retrieval
  alias HarnessForge.Evidence.{Capture, Corpora, Passages}

  @long "How should emergency releases combine reviewer policy, exception scope and rollback rehearsal?"
  @focused "Which reviewer policy, emergency exception and rollback controls apply?"

  test "the retained public browser question includes the governing policy without rephrasing" do
    root = Path.join(System.tmp_dir!(), "hf15-historical-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    if Process.whereis(HarnessForge.Evidence.Capture.Scanner) == nil do
      start_supervised!({HarnessForge.Evidence.Capture.Scanner, []})
    end

    # This is the already-public iteration14 scripted protocol fixture. Its
    # response/report is unused; this check performs no synthesis/model call.
    fixture = CompanyAnalysisFixture.create!(root)
    {:ok, sources} = Evidence.list_sources()
    directory = Path.join(root, "synthetic-company-documents")

    for source <- sources do
      File.write!(Path.join(directory, source["external_id"]), source["latest_revision"]["body"])
    end

    {:ok, corpus} = Corpora.create(%{"name" => "Retained public browser regression"}, caller())

    members =
      Enum.map(sources, fn source ->
        %{
          "source_id" => source["id"],
          "revision_id" => source["latest_revision"]["id"],
          "action" => "include"
        }
      end)

    {:ok, current} = Corpora.apply_members(corpus["id"], 0, members, caller())

    {:ok, _} =
      Company.bind_corpus(
        fixture.project["id"],
        corpus["id"],
        fixture.profile["content_hash"],
        fixture.project["content_hash"],
        caller()
      )

    {:ok, capture} =
      Capture.start_capture(
        corpus["id"],
        fixture.connection["id"],
        current["semantic_generation"],
        caller()
      )

    {:ok, captured} = Capture.run(capture["run_id"])
    assert captured["capture"]["complete"]
    {:ok, sources} = Evidence.list_sources()

    for source <- sources do
      assert {:ok, _} = Passages.index_revision(source["latest_revision"]["id"])
    end

    {:ok, current} = Corpora.get(corpus["id"])
    names = Map.new(sources, &{&1["id"], &1["external_id"]})

    records =
      for {label, question} <- [{"long", @long}, {"focused", @focused}] do
        input = %{
          "corpus_id" => corpus["id"],
          "project_id" => fixture.project["id"],
          "goal_id" => fixture.goal["id"],
          "goal_hash" => fixture.input["goal_content_hash"],
          "expected_generation" => current.semantic_generation,
          "question" => question,
          "mode" => "fts"
        }

        {:ok, result} = Retrieval.retrieve(input, caller())
        {:ok, page} = Retrieval.read_run(result["run_id"], result["digest"], %{}, caller())

        %{
          "case" => label,
          "question" => question,
          "result" => result,
          "candidates" => Enum.map(page["rows"], &names[&1["source_id"]]) |> Enum.sort(),
          "selected" =>
            page["rows"]
            |> Enum.filter(&is_integer(&1["selected_order"]))
            |> Enum.map(&names[&1["source_id"]])
            |> Enum.sort()
        }
      end

    if path = System.get_env("HF15_HISTORICAL_REPORT") do
      assert Path.type(path) == :absolute
      File.mkdir_p!(Path.dirname(path))
      {:ok, file} = File.open(path, [:write, :exclusive])

      try do
        IO.binwrite(file, Jason.encode_to_iodata!(%{"records" => records}, pretty: true))
      after
        File.close(file)
      end
    end

    for record <- records do
      assert "policy.md" in record["selected"],
             "#{record["case"]} omitted governing policy: #{inspect(record["selected"])}"

      assert record["result"]["state"] == "ready"
    end
  end

  defp caller do
    [
      authorize: fn -> true end,
      session_fingerprint: Contracts.sha256("iteration15 historical public browser regression"),
      view_generation: String.duplicate("e", 32),
      reset_token: 0
    ]
  end
end
