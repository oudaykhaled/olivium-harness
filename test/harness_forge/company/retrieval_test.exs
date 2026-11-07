defmodule HarnessForge.Company.RetrievalTest do
  use HarnessForge.DataCase, async: false
  alias HarnessForge.{CompanyAnalysisFixture, Contracts, Evidence, Repo}
  alias HarnessForge.Company.Retrieval
  alias HarnessForge.Evidence.{Corpora, Passages, Store}

  setup do
    root = Path.join(System.tmp_dir!(), "retrieval-generic-#{System.unique_integer([:positive])}")
    f = CompanyAnalysisFixture.create!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, corpus} = Corpora.create(%{"name" => "Generic public mechanics"}, caller())
    {:ok, sources} = Evidence.list_sources()

    changes =
      Enum.map(
        sources,
        &%{
          "source_id" => &1["id"],
          "revision_id" => &1["latest_revision"]["id"],
          "action" => "include"
        }
      )

    {:ok, _} = Corpora.apply_members(corpus["id"], 0, changes, caller())
    for source <- sources, do: Passages.index_revision(source["latest_revision"]["id"])
    now = Corpora.now()

    Repo.query!(
      "INSERT INTO company_corpus_bindings(workspace_id,project_id,profile_id,corpus_id,inserted_at,updated_at) VALUES(?,?,?,?,?,?)",
      [Store.workspace(), f.project["id"], f.profile["id"], corpus["id"], now, now]
    )

    {:ok, current} = Corpora.get(corpus["id"])

    input = %{
      "corpus_id" => corpus["id"],
      "project_id" => f.project["id"],
      "goal_id" => f.goal["id"],
      "goal_hash" => f.input["goal_content_hash"],
      "expected_generation" => current.semantic_generation,
      "question" => "Which release records require review?",
      "mode" => "fts"
    }

    %{fixture: f, input: input, corpus: current}
  end

  test "strict question, forged scope and unavailable graph never dispatch a fallback", %{
    input: input
  } do
    assert {:error, :invalid_input} =
             Retrieval.retrieve(Map.put(input, "question", String.duplicate("a", 257)), caller())

    assert {:error, :invalid_input} =
             Retrieval.retrieve(Map.put(input, "source_ids", []), caller())

    assert {:error, :invalid_input} =
             Retrieval.retrieve(
               Map.put(input, "graph", %{
                 "format" => "graph-search-certificate-v1",
                 "search_ref" => Ecto.UUID.generate()
               }),
               caller()
             )

    assert {:error, _} =
             Retrieval.retrieve(Map.put(input, "corpus_id", Ecto.UUID.generate()), caller())

    assert {:error, :graph_unavailable} =
             Retrieval.retrieve(Map.put(input, "mode", "graphiti_hybrid"), caller())

    assert [[0]] = Repo.query!("SELECT count(*) FROM retrieval_runs", []).rows
  end

  test "incomplete capture stays inspectable but cannot resolve for analysis", %{input: input} do
    assert {:ok, result} = Retrieval.retrieve(input, caller())
    assert result["state"] == "abstained"
    assert {:ok, read} = Retrieval.read_run(result["run_id"], result["digest"], %{}, caller())
    assert length(read["rows"]) <= 25

    assert Enum.all?(read["rows"], fn row ->
             is_binary(row["snippet"]) and byte_size(row["snippet"]) <= 4096 and
               String.valid?(row["snippet"]) and not Map.has_key?(row, "parent_text")
           end)

    assert Enum.all?(read["rows"], &(&1["context_readiness"] in ["complete", "incomplete"]))

    assert Enum.all?(
             read["rows"],
             &(is_list(&1["lane_memberships"]) and &1["packing_version"] == "context-diverse-v2" and
                 is_map(&1["lane_ranks"]))
           )

    assert Enum.any?(read["rows"], &(length(&1["lane_memberships"]) > 1))

    assert {:error, :capture_incomplete} =
             Retrieval.resolve_for_analysis(result["run_id"], result["digest"], caller())
  end

  test "explicit invalid declaration references never fall back to legacy capture", %{
    input: input
  } do
    for ref <- [
          nil,
          %{},
          %{"id" => Ecto.UUID.generate()},
          %{
            "id" => Ecto.UUID.generate(),
            "digest" => String.duplicate("0", 64),
            "complete" => true
          }
        ] do
      assert {:error, :invalid_input} =
               Retrieval.retrieve(Map.put(input, "declaration_ref", ref), caller())
    end

    assert {:error, :not_found} =
             Retrieval.retrieve(
               Map.put(input, "declaration_ref", %{
                 "id" => Ecto.UUID.generate(),
                 "digest" => String.duplicate("0", 64)
               }),
               caller()
             )

    assert [[0]] = Repo.query!("SELECT count(*) FROM retrieval_runs", []).rows
  end

  test "new member invalidates an immutable run while existing cited bytes stay unchanged", %{
    input: input,
    fixture: f,
    corpus: corpus
  } do
    {:ok, result} = Retrieval.retrieve(input, caller())
    assert :ok = Retrieval.validate_current(result["run_id"], result["digest"])

    {:ok, source} =
      Evidence.import_markdown(f.connection["id"], %{
        "external_id" => "new-public-note.md",
        "title" => "New public note",
        "body" => "A newly captured public exception awaits review."
      })

    {:ok, _} =
      Corpora.apply_members(
        corpus.id,
        corpus.semantic_generation,
        [
          %{
            "source_id" => source["id"],
            "revision_id" => source["latest_revision"]["id"],
            "action" => "include"
          }
        ],
        caller()
      )

    assert {:error, :stale_generation} =
             Retrieval.validate_current(result["run_id"], result["digest"])

    assert {:error, :stale_generation} =
             Retrieval.read_run(result["run_id"], result["digest"], %{}, caller())
  end

  test "a completed physical scan resolves a bounded server-owned exact pack", %{
    input: input,
    fixture: f
  } do
    if Process.whereis(HarnessForge.Evidence.Capture.Scanner) == nil,
      do: start_supervised!({HarnessForge.Evidence.Capture.Scanner, []})

    {:ok, sources} = Evidence.list_sources()

    for source <- sources do
      File.write!(
        Path.join(f.connection["directory"], source["external_id"]),
        source["latest_revision"]["body"]
      )
    end

    {:ok, run} =
      HarnessForge.Evidence.Capture.start_capture(
        input["corpus_id"],
        f.connection["id"],
        input["expected_generation"],
        caller()
      )

    assert {:ok, captured} = HarnessForge.Evidence.Capture.run(run["run_id"])
    assert captured["capture"]["complete"]
    {:ok, current_sources} = Evidence.list_sources()

    for source <- current_sources,
        do: assert({:ok, _} = Passages.index_revision(source["latest_revision"]["id"]))

    {:ok, current} = Corpora.get(input["corpus_id"])

    assert {:ok, result} =
             Retrieval.retrieve(
               Map.put(input, "expected_generation", current.semantic_generation),
               caller()
             )

    assert result["state"] == "ready"

    assert {:ok, pack} =
             Retrieval.resolve_for_analysis(result["run_id"], result["digest"], caller())

    assert length(pack["passages"]) in 1..24
    assert is_nil(pack["manifest"]["graph"])

    assert Enum.reduce(
             pack["passages"],
             0,
             &(byte_size(&1["snippet"]) + byte_size(&1["parent_text"]) + &2)
           ) <= 32768

    for passage <- pack["passages"] do
      assert Store.hash(passage["snippet"]) == passage["snippet_hash"]
      assert passage["end_byte"] - passage["start_byte"] == byte_size(passage["snippet"])
    end

    # The shared inspection DTO uses the existing ready-only checked manifest;
    # completing acquisition still supplies no historical replay authority.
    assert {:ok, evidence} =
             Retrieval.retrieve_evidence(
               Map.put(input, "expected_generation", current.semantic_generation),
               caller()
             )

    assert evidence["state"] == "ready"
    assert evidence["evidence_bundle"]["status"] == "ready"
    assert evidence["evidence_bundle"]["analysis_ready"]
    assert evidence["evidence_bundle"]["history"]["status"] == "unknown"
    assert evidence["evidence_bundle"]["history"]["historical_eligibility"] == "unavailable"

    assert {:ok, evidence_pack} =
             Retrieval.resolve_for_analysis(evidence["run_id"], evidence["digest"], caller())

    assert evidence_pack["passages"] == pack["passages"]
    assert evidence_pack["manifest"]["run_id"] == evidence["run_id"]
    assert evidence_pack["manifest"]["run_digest"] == evidence["digest"]
    assert evidence_pack["manifest"]["version"] == 2
  end

  test "query plan is deterministic, bounded, and escapes FTS operator-looking input" do
    goal = %{"title" => "Garden", "acceptance" => "Preserve the watering schedule"}
    plan = Retrieval.query_plan("NEAR(*) watering OR schedule", goal)
    assert length(plan["lanes"]) == 5
    assert plan["limits"]["candidates"] == 100
    assert plan == Retrieval.query_plan("NEAR(*) watering OR schedule", goal)
    assert String.contains?(hd(plan["lanes"])["expression"], "\"near\"")
    refute String.contains?(hd(plan["lanes"])["expression"], "(*)")
  end

  test "question tokens preserve middle and late qualifiers without adding searches" do
    goal = %{"title" => "Public garden", "acceptance" => "Record the seasonal schedule"}

    question =
      "Could you please explain how the ordinary seasonal garden schedule changes for greenhouse orchids"

    plan = Retrieval.query_plan(question, goal)
    support = hd(plan["lanes"])["expression"]
    assert plan["version"] == "query_plan_v3"
    assert String.contains?(support, "\"greenhouse\"")
    assert String.contains?(support, "\"orchids\"")
    refute String.contains?(support, "\"please\"")

    assert plan["question_terms"] ==
             ~w(ordinary seasonal garden schedule changes greenhouse orchids)

    balanced =
      Retrieval.query_plan("alpha beta gamma delta epsilon zeta eta theta iota kappa", goal)

    assert String.contains?(hd(balanced["lanes"])["expression"], "\"alpha\"")
    assert String.contains?(hd(balanced["lanes"])["expression"], "\"epsilon\"")
    assert String.contains?(hd(balanced["lanes"])["expression"], "\"zeta\"")
    assert String.contains?(hd(balanced["lanes"])["expression"], "\"kappa\"")
    assert length(balanced["lanes"]) == 5
    assert balanced["limits"]["candidates"] == 100
    assert balanced["limits"]["searches"] == 5
  end

  test "packing retains lexical relevance and diverse sources without promoting completeness" do
    repeated =
      Enum.map(0..14, fn index ->
        packing_candidate(
          "window-#{index}",
          "public-garden",
          index * 300,
          true,
          ["support"],
          index
        )
      end)

    other = packing_candidate("other-record", "orchid-greenhouse", 0, true, ["support"], 19)
    selected = Retrieval.packing_plan(repeated ++ [other])
    assert length(selected) == 8
    assert Enum.any?(selected, &(&1["passage_id"] == "other-record"))
    incomplete = Enum.map(repeated, &Map.put(&1, "context_complete", false))
    assert hd(Retrieval.packing_plan(incomplete ++ [other]))["passage_id"] == "window-0"

    assert Enum.any?(
             Retrieval.packing_plan(incomplete ++ [other]),
             &(&1["passage_id"] == "other-record")
           )

    assert Enum.any?(Retrieval.packing_plan(incomplete), &(not &1["context_complete"]))
  end

  test "alternate contrary and unknown memberships survive broad support deduplication" do
    shared =
      packing_candidate(
        "shared-public-paragraph",
        "garden-one",
        0,
        true,
        ["support", "contrary"],
        0
      )

    unknown =
      packing_candidate(
        "chronology-public-paragraph",
        "garden-two",
        0,
        true,
        ["support", "chronology", "obligations"],
        1
      )

    support =
      packing_candidate("support-public-paragraph", "garden-three", 0, true, ["support"], 2)

    selected = Retrieval.packing_plan([shared, unknown, support])
    assert Enum.find(selected, &(&1["passage_id"] == shared["passage_id"]))["lane"] == "contrary"

    assert Enum.find(selected, &(&1["passage_id"] == unknown["passage_id"]))["relation"] ==
             "unknown"

    assert Enum.find(selected, &(&1["passage_id"] == support["passage_id"]))["lane"] == "support"
  end

  test "identical parent context consumes one slot and incomplete evidence stays incomplete" do
    first = packing_candidate("first-core", "same-public-record", 0, true, ["support"], 0)

    second =
      first
      |> Map.merge(%{
        "passage_id" => "second-core",
        "start_byte" => 100,
        "end_byte" => 200,
        "candidate_order" => 1
      })

    partial =
      packing_candidate("partial-public-record", "other-public-record", 0, false, ["contrary"], 2)

    selected = Retrieval.packing_plan([first, second, partial])
    assert length(selected) == 2
    assert Enum.count(selected, &(&1["source_id"] == "same-public-record")) == 1
    refute Enum.find(selected, &(&1["passage_id"] == partial["passage_id"]))["context_complete"]
  end

  test "interleaved lanes retain highly ranked partial context and other lane coverage" do
    partial =
      packing_candidate("incomplete-exception", "public-long-record", 0, false, ["contrary"], 0)

    complete =
      packing_candidate("complete-observation", "public-short-record", 0, true, ["support"], 1)

    selected = Retrieval.packing_plan([partial, complete])
    assert hd(selected)["passage_id"] == partial["passage_id"]
    assert List.last(selected)["passage_id"] == complete["passage_id"]
    refute hd(selected)["context_complete"]
    assert hd(selected)["lane"] == "contrary"
  end

  test "a short lower-relevance parent cannot displace the best lexical paragraph" do
    relevant =
      packing_candidate(
        "relevant-garden-paragraph",
        "one-garden-record",
        0,
        false,
        ["support"],
        0
      )
      |> Map.merge(%{"end_byte" => 2048, "parent_end_byte" => 4096})

    short =
      packing_candidate(
        "short-less-relevant-paragraph",
        "one-garden-record",
        5000,
        true,
        ["support"],
        1
      )

    selected = Retrieval.packing_plan([short, relevant])
    assert hd(selected)["passage_id"] == relevant["passage_id"]
    refute hd(selected)["context_complete"]
  end

  test "each lane uses its own lexical ordinal and source diversity" do
    chronology =
      packing_candidate("garden-history", "garden-record", 0, true, ["support", "chronology"], 0)
      |> Map.put("lane_ranks", %{"support" => 19, "chronology" => 0})

    less_relevant =
      packing_candidate("garden-short-note", "garden-record", 1000, true, ["support"], 1)
      |> Map.put("lane_ranks", %{"support" => 10})

    support =
      packing_candidate("garden-best-observation", "garden-record", 2000, true, ["support"], 2)
      |> Map.put("lane_ranks", %{"support" => 0})

    selected = Retrieval.packing_plan([chronology, less_relevant, support])
    assert hd(selected)["lane"] == "chronology"
    assert Enum.find(selected, &(&1["lane"] == "support"))["passage_id"] == support["passage_id"]
  end

  test "one lane cannot exhaust its reservation before another lane's leading relevance" do
    contrary =
      Enum.map(0..5, fn index ->
        packing_candidate(
          "garden-exception-#{index}",
          "public-garden-exceptions",
          index * 1000,
          false,
          ["contrary"],
          index
        )
      end)

    support =
      packing_candidate(
        "garden-leading-observation",
        "public-garden-observations",
        0,
        true,
        ["support"],
        0
      )

    selected = Retrieval.packing_plan(contrary ++ [support])
    assert Enum.find_index(selected, &(&1["passage_id"] == support["passage_id"])) == 1
    assert Enum.count(selected, &(&1["lane"] == "contrary")) == 6
    assert length(selected) <= 24
    assert Enum.any?(selected, &(not &1["context_complete"]))
  end

  test "workspace-bound envelope refuses a restored row whose storage scope was rebound", %{
    input: input
  } do
    {:ok, result} = Retrieval.retrieve(input, caller())
    {:ok, run} = Store.get(HarnessForge.Company.RetrievalRun, result["run_id"])
    assert run.envelope["scope"]["workspace_id"] == Store.workspace()
    assert :ok == Retrieval.validate_current(run.id, run.digest)
    # Model a restore retaining the immutable old origin while rebinding the
    # storage row to the current workspace. A valid hash cannot repair identity.
    foreign = put_in(run.envelope, ["scope", "workspace_id"], Ecto.UUID.generate())

    attrs =
      run
      |> Map.from_struct()
      |> Map.drop([:__meta__, :id, :digest, :completed_at])
      |> Map.merge(%{id: Ecto.UUID.generate(), state: "preparing", envelope: foreign})

    {:ok, staged} = Repo.insert(struct(HarnessForge.Company.RetrievalRun, attrs))

    items =
      Repo.all(from item in HarnessForge.Company.RetrievalItem, where: item.run_id == ^run.id)

    for item <- items do
      copied = item |> Map.from_struct() |> Map.drop([:__meta__]) |> Map.put(:run_id, staged.id)
      Repo.insert!(struct(HarnessForge.Company.RetrievalItem, copied))
    end

    digest = Contracts.digest(%{"envelope" => foreign, "coverage" => run.coverage})

    {:ok, restored} =
      staged
      |> Ecto.Changeset.change(
        state: "abstained",
        digest: digest,
        completed_at: DateTime.utc_now()
      )
      |> Repo.update()

    assert {:error, :stale_generation} = Retrieval.validate_current(restored.id, restored.digest)

    assert {:error, :stale_generation} =
             Retrieval.read_run(restored.id, restored.digest, %{}, caller())
  end

  defp packing_candidate(id, source, start, complete, lanes, order) do
    %{
      "passage_id" => id,
      "source_id" => source,
      "revision_id" => source <> "-revision",
      "start_byte" => start,
      "end_byte" => start + 100,
      "parent_start_byte" => start,
      "parent_end_byte" => start + 200,
      "parent_hash" => Contracts.sha256(source <> Integer.to_string(start)),
      "context_complete" => complete,
      "lane" => hd(lanes),
      "lanes" => lanes,
      "lane_ranks" => Map.new(lanes, &{&1, order}),
      "relation" => "support",
      "reason_code" => "lexical_provisional",
      "candidate_order" => order
    }
  end

  defp caller,
    do: [
      authorize: fn -> true end,
      session_fingerprint: Contracts.sha256("retrieval caller"),
      view_generation: String.duplicate("d", 32),
      reset_token: 0
    ]
end
