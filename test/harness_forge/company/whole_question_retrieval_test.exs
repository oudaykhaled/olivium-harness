defmodule HarnessForge.Company.WholeQuestionRetrievalTest do
  use HarnessForge.DataCase, async: false

  alias HarnessForge.{Contracts, Iteration15PublicCases}
  alias HarnessForge.Company.{Retrieval, RetrievalItem, RetrievalRun}
  alias HarnessForge.Evidence.Store

  @identity ~w(passage_id source_id revision_id body_hash start_byte end_byte snippet_hash parent_start_byte parent_end_byte parent_hash)
  @repetitions 2

  @tag timeout: 120_000
  test "current evidence contract preserves admitted public questions and the dense envelope bound" do
    fixture = public_fixture!()

    # Only reuse the existing public questions, not expected semantic answers.
    # Compare mechanics with the unchanged legacy producer in the same scope.
    observations =
      for question <- Iteration15PublicCases.cases() |> Enum.map(& &1["question"]) |> Enum.uniq() do
        input = Map.put(fixture.input, "question", question)

        case Retrieval.retrieve(input, caller()) do
          {:ok, legacy} ->
            assert {:ok, evidence} = Retrieval.retrieve_evidence(input, caller())
            {:ok, old} = Store.get(RetrievalRun, legacy["run_id"])
            {:ok, new} = Store.get(RetrievalRun, evidence["run_id"])
            base = new.envelope |> Map.delete("evidence") |> Map.put("version", 2)
            assert base == old.envelope
            assert new.coverage == old.coverage
            bytes = byte_size(Contracts.canonical_json(new.envelope))
            assert bytes <= 16_384
            assert bytes - byte_size(Contracts.canonical_json(base)) == 180
            assert evidence["state"] == legacy["state"]

            assert {:ok, _} =
                     Retrieval.read_evidence_summary(
                       evidence["run_id"],
                       evidence["digest"],
                       caller()
                     )

            bytes

          {:error, :invalid_input} ->
            assert {:error, :invalid_input} = Retrieval.retrieve_evidence(input, caller())
            nil
        end
      end

    bytes = Enum.reject(observations, &is_nil/1)
    assert bytes != []

    IO.puts(
      "EvidenceBundle public-question compatibility: #{length(bytes)} admitted, max envelope #{Enum.max(bytes)} bytes, unchanged cap 16384, exact overhead 180"
    )
  end

  @tag timeout: 120_000
  test "frozen independent public obligations survive bounded retrieval" do
    fixture = public_fixture!()

    records =
      for {development_case, ordinal} <- Enum.with_index(Iteration15PublicCases.cases()),
          repetition <- 1..@repetitions do
        measure_case(development_case, ordinal, repetition, fixture)
      end

    report = %{
      "format" => "iteration15-public-retrieval-observations-v1",
      "specification_hash" => Iteration15PublicCases.frozen_specification_hash(),
      "specification" => Iteration15PublicCases.specification(),
      "runtime" => %{
        "elixir" => System.version(),
        "otp" => System.otp_release(),
        "architecture" => to_string(:erlang.system_info(:system_architecture)),
        "schedulers_online" => :erlang.system_info(:schedulers_online)
      },
      "scope" => %{
        "workspace_id" => Store.workspace(),
        "corpus_id" => fixture.corpus.id,
        "project_id" => fixture.project["id"],
        "goal_id" => fixture.goal["id"],
        "goal_content_hash" => fixture.input["goal_hash"],
        "frozen_goal_payload_hash" => fixture.frozen_goal_payload_hash,
        "capture" => fixture.capture,
        "source_count" => map_size(fixture.sources),
        "source_pins" => source_pins(fixture)
      },
      "comparison_disclosure" =>
        "All cases/repetitions in this invocation share the same physically captured revisions. Separate mix test invocations reconstitute sandbox scopes with different UUIDs; compare logical source body hashes and frozen goal payload hash, never claim identical UUIDs.",
      "measurement_disclosure" =>
        "Two sequential repetitions per case in one already-started test process. First-for-case is not a process/OS-cache cold run. retrieve_us includes search, checked packing and publication; private packing time is not separately instrumented. No model, synthesis or semantic answer classification is executed.",
      "noise_disclosure" =>
        "Outside-predeclared-relevance counts/bytes are a frozen logical-ID proxy, not certified semantic irrelevance.",
      "query_plan_disclosure" =>
        "stored_query_plan is the raw digest-bound representation; query_plan is its separate decoded inspection view for lane metrics. Envelope bytes and digest checks always use the raw stored envelope. Decoding does not dispatch or rerun searches.",
      "records" => records
    }

    write_report!(report)
    failures = Enum.filter(records, &(&1["failures"] != []))

    assert failures == [],
           "Frozen public source/citation/cap failures (all records emitted before assertion):\n" <>
             Jason.encode!(Enum.map(failures, &Map.take(&1, ~w(case_id repetition failures))))
  end

  @tag timeout: 120_000
  test "question diagnostics count unique passage attribution independently of chosen packing lane" do
    fixture = public_fixture!()

    observations =
      for case_id <- ~w(linked-middle guidance-status max-admitted-utf8-bytes) do
        development_case = Iteration15PublicCases.fetch_case!(case_id)

        {:ok, result} =
          Retrieval.retrieve(
            Map.put(fixture.input, "question", development_case["question"]),
            caller()
          )

        {:ok, run} = Store.get(RetrievalRun, result["run_id"])
        rows = read_pages(result, %{}, [])
        stored_plan = run.envelope["query_plan"]
        diagnostic = get_in(run.coverage, ["search", "question"])
        selected_ids = rows |> Enum.filter(&is_integer(&1["selected_order"])) |> passage_ids()

        assert Contracts.digest(%{"envelope" => run.envelope, "coverage" => run.coverage}) ==
                 result["digest"],
               case_id

        assert {:ok, plan} = Retrieval.decode_query_plan(stored_plan)
        assert stored_plan["storage_encoding"] == "query-plan-terms-v1", case_id
        assert stored_plan["lane_recipe"] == "five-lane-lexical-v1", case_id
        refute Map.has_key?(stored_plan, "lanes"), case_id

        assert plan["version"] == "query_plan_v3", case_id
        assert is_map(diagnostic), case_id
        assert diagnostic["status"] == "lexical", case_id
        assert diagnostic["query_plan_version"] == "query_plan_v3", case_id
        assert diagnostic["searched_terms"] == plan["question_terms"], case_id
        assert is_integer(diagnostic["candidates"]), case_id
        assert is_integer(diagnostic["selected"]), case_id
        assert diagnostic["candidates"] <= length(rows), case_id
        assert diagnostic["selected"] <= MapSet.size(selected_ids), case_id
        assert diagnostic["selected"] <= diagnostic["candidates"], case_id
        assert result["coverage"] == run.coverage, case_id

        question_rows =
          case plan["base_source"] do
            "question" ->
              assert plan["question_terms"] != [], case_id
              Enum.filter(rows, &question_lane_member?/1)

            "goal" ->
              assert case_id == "max-admitted-utf8-bytes"
              assert plan["question_terms"] == []
              assert diagnostic["searched_terms"] == []
              assert rows != []
              assert Enum.any?(rows, &("obligations" in &1["lane_memberships"]))
              []
          end

        question_ids = passage_ids(question_rows)
        assert diagnostic["candidates"] == MapSet.size(question_ids), case_id

        assert diagnostic["selected"] ==
                 MapSet.size(MapSet.intersection(question_ids, selected_ids)),
               case_id

        %{
          multiple_question_lane_memberships?:
            Enum.any?(question_rows, fn row ->
              Enum.count(row["lane_memberships"], &(&1 in ~w(support contrary chronology))) > 1
            end),
          selected_with_other_chosen_lane?:
            Enum.any?(question_rows, fn row ->
              is_integer(row["selected_order"]) and
                row["lane"] not in ~w(support contrary chronology)
            end)
        }
      end

    assert Enum.any?(observations, & &1.multiple_question_lane_memberships?)
    assert Enum.any?(observations, & &1.selected_with_other_chosen_lane?)
  end

  @tag timeout: 120_000
  test "constructed plain v2 and v3 fixtures preserve raw digests and diagnostic availability" do
    fixture = public_fixture!()
    question = "custody ledger"
    assert length(String.split(question)) <= 8

    {:ok, result} = Retrieval.retrieve(Map.put(fixture.input, "question", question), caller())
    {:ok, current} = Store.get(RetrievalRun, result["run_id"])
    assert current.state == "ready"

    assert Contracts.digest(%{"envelope" => current.envelope, "coverage" => current.coverage}) ==
             current.digest

    assert {:ok, expanded} = Retrieval.decode_query_plan(current.envelope["query_plan"])

    for version <- ~w(query_plan_v2 query_plan_v3) do
      {plain_plan, coverage} =
        case version do
          "query_plan_v2" ->
            plan =
              expanded
              |> Map.take(~w(version question lanes limits))
              |> Map.put("version", version)

            {plan, Map.update!(current.coverage, "search", &Map.delete(&1, "question"))}

          "query_plan_v3" ->
            {expanded, current.coverage}
        end

      assert plain_plan["lanes"] == expanded["lanes"]
      refute Map.has_key?(plain_plan, "storage_encoding")
      refute Map.has_key?(plain_plan, "lane_recipe")
      assert {:ok, ^plain_plan} = Retrieval.decode_query_plan(plain_plan)

      envelope = Map.put(current.envelope, "query_plan", plain_plan)
      digest = Contracts.digest(%{"envelope" => envelope, "coverage" => coverage})
      refute digest == current.digest
      historical = store_constructed_plain_run!(current, envelope, coverage, digest)

      assert :ok = Retrieval.validate_current(historical.id, digest)
      assert {:ok, read} = Retrieval.read_run(historical.id, digest, %{}, caller())
      assert read["digest"] == digest
      assert read["coverage"] == coverage
      assert read["rows"] != []

      assert {:ok, pack} = Retrieval.resolve_for_analysis(historical.id, digest, caller())
      assert pack["digest"] == digest
      assert pack["manifest"]["run_digest"] == digest
      assert pack["coverage"] == coverage
      assert pack["passages"] != []

      if version == "query_plan_v2" do
        refute Map.has_key?(read["coverage"]["search"], "question")
        refute Map.has_key?(pack["coverage"]["search"], "question")
        refute Map.has_key?(plain_plan, "question_terms")
        refute Map.has_key?(plain_plan, "base_source")
      else
        assert get_in(read, ["coverage", "search", "question"]) ==
                 get_in(current.coverage, ["search", "question"])
      end

      {:ok, unchanged} = Store.get(RetrievalRun, historical.id)
      assert unchanged.digest == digest
      assert unchanged.envelope == envelope
      assert unchanged.coverage == coverage
      assert unchanged.envelope["query_plan"]["version"] == version
    end
  end

  defp measure_case(development_case, ordinal, repetition, fixture) do
    input = Map.put(fixture.input, "question", development_case["question"])
    {retrieve_us, outcome} = timed(fn -> Retrieval.retrieve(input, caller()) end)

    base = %{
      "case_id" => development_case["id"],
      "ordinal" => ordinal,
      "repetition" => repetition,
      "condition" => if(repetition == 1, do: "first_for_case", else: "warm_same_case"),
      "acceptance" => development_case["acceptance"],
      "question" => development_case["question"],
      "question_characters" => String.length(development_case["question"]),
      "question_bytes" => byte_size(development_case["question"]),
      "retrieve_us" => retrieve_us,
      "packing_us" => nil,
      "answer_support" => "not_assessed_no_synthesis"
    }

    case outcome do
      {:ok, result} ->
        observe_result(base, development_case, result, fixture)

      {:error, reason} ->
        failure =
          if development_case["acceptance"] == "invalid_input" and reason == :invalid_input,
            do: [],
            else: ["retrieval_error:" <> inspect(reason)]

        Map.merge(base, %{
          "outcome" => if(is_atom(reason), do: Atom.to_string(reason), else: inspect(reason)),
          "failures" => failure
        })
    end
  rescue
    error ->
      %{
        "case_id" => development_case["id"],
        "ordinal" => ordinal,
        "repetition" => repetition,
        "outcome" => "exception",
        "error" => Exception.message(error),
        "failures" => ["observation_exception:" <> inspect(error.__struct__)]
      }
  end

  defp observe_result(base, development_case, result, fixture) do
    {read_us, rows} = timed(fn -> read_pages(result, %{}, []) end)
    {:ok, run} = Store.get(RetrievalRun, result["run_id"])
    selected_rows = Enum.filter(rows, &is_integer(&1["selected_order"]))

    {open_selected_us, selected} =
      timed(fn ->
        selected_rows
        |> Enum.sort_by(& &1["selected_order"])
        |> Enum.map(fn row ->
          {:ok, passage} =
            Retrieval.open_passage(
              result["run_id"],
              result["digest"],
              row["passage_id"],
              caller()
            )

          passage
        end)
      end)

    source_ids =
      Map.new(fixture.sources, fn {logical_id, source} -> {source["id"], logical_id} end)

    candidates = Enum.map(rows, &source_ids[&1["source_id"]]) |> Enum.uniq() |> Enum.sort()
    selected_ids = Enum.map(selected, &source_ids[&1["source_id"]]) |> Enum.uniq() |> Enum.sort()
    missing_candidates = development_case["indispensable"] -- candidates
    missing_selected = development_case["indispensable"] -- selected_ids
    contrary_missing_candidates = development_case["contrary"] -- candidates
    contrary_missing_selected = development_case["contrary"] -- selected_ids
    citation_failures = Enum.flat_map(selected, &citation_failures(&1, fixture, source_ids))

    evidence_bytes =
      Enum.sum(Enum.map(selected, &(byte_size(&1["snippet"]) + byte_size(&1["parent_text"]))))

    envelope_bytes = byte_size(Contracts.canonical_json(run.envelope))

    prompt_bytes =
      byte_size(
        Contracts.canonical_json(%{"scope" => run.envelope["scope"], "passages" => selected})
      )

    stored_plan = run.envelope["query_plan"]

    raw_digest_valid =
      Contracts.digest(%{"envelope" => run.envelope, "coverage" => run.coverage}) ==
        result["digest"]

    decoded =
      if raw_digest_valid,
        do: Retrieval.decode_query_plan(stored_plan),
        else: {:error, :invalid_raw_digest}

    {plan, decoding_failures} =
      case decoded do
        {:ok, expanded} -> {expanded, []}
        {:error, reason} -> {nil, ["stored_query_plan_decode:" <> inspect(reason)]}
      end

    lanes = if is_map(plan), do: Map.get(plan, "lanes", []), else: []

    outside =
      Enum.filter(selected, &(source_ids[&1["source_id"]] not in development_case["relevant"]))

    caps = %{
      "candidate_count" => length(rows) <= 100,
      "selected_count" => length(selected) <= 24,
      "evidence_bytes" => evidence_bytes <= 32_768,
      "prompt_bytes" => prompt_bytes <= 49_152,
      "envelope_bytes" => envelope_bytes <= 16_384,
      "search_lanes" => length(lanes) == 5
    }

    source_failures =
      if development_case["acceptance"] == "source_obligations" do
        Enum.map(missing_candidates, &("indispensable_not_candidate:" <> &1)) ++
          Enum.map(missing_selected, &("indispensable_not_selected:" <> &1)) ++
          Enum.map(contrary_missing_candidates, &("contrary_not_candidate:" <> &1)) ++
          Enum.map(contrary_missing_selected, &("contrary_not_selected:" <> &1))
      else
        []
      end

    failures =
      source_failures ++
        decoding_failures ++
        citation_failures ++
        Enum.flat_map(caps, fn {name, passed} -> if passed, do: [], else: ["cap:" <> name] end) ++
        if(development_case["acceptance"] == "source_obligations" and result["state"] != "ready",
          do: ["answerable_case_not_structurally_ready"],
          else: []
        ) ++
        if(get_in(run.coverage, ["search", "omitted"]) != 0, do: ["context_omission"], else: []) ++
        if(Enum.any?(selected, & &1["parent_incomplete"]),
          do: ["incomplete_selected_parent"],
          else: []
        ) ++
        if(development_case["acceptance"] == "invalid_input",
          do: ["invalid_input_was_accepted"],
          else: []
        )

    Map.merge(base, %{
      "outcome" => "ok",
      "result" => result,
      "read_run_us" => read_us,
      "open_selected_us" => open_selected_us,
      "stored_query_plan" => stored_plan,
      "query_plan" => plan,
      "raw_stored_digest_valid" => raw_digest_valid,
      "candidate_logical_source_ids" => candidates,
      "selected_logical_source_ids" => selected_ids,
      "critical_missing_candidates" => missing_candidates,
      "critical_missing_selected" => missing_selected,
      "contrary_missing_candidates" => contrary_missing_candidates,
      "contrary_missing_selected" => contrary_missing_selected,
      "candidate_rows" => rows,
      "selected_passages" => selected,
      "coverage" => run.coverage,
      "context_omissions" => get_in(run.coverage, ["search", "omitted"]),
      "selected_parent_incomplete" => Enum.count(selected, & &1["parent_incomplete"]),
      "outside_predeclared_relevance_selected_count" => length(outside),
      "outside_predeclared_relevance_selected_bytes" =>
        Enum.sum(Enum.map(outside, &(byte_size(&1["snippet"]) + byte_size(&1["parent_text"])))),
      "candidate_count" => length(rows),
      "selected_count" => length(selected),
      "evidence_bytes" => evidence_bytes,
      "prompt_bytes" => prompt_bytes,
      "envelope_bytes" => envelope_bytes,
      "planned_search_lanes" => length(lanes),
      "planned_nonempty_fts_searches" => Enum.count(lanes, &(&1["expression"] != "")),
      "observed_sql_searches" => nil,
      "caps" => caps,
      "citation_failures" => citation_failures,
      "digest_bound_query_diagnostics" => get_in(run.coverage, ["search", "question"]),
      "failures" => failures
    })
  end

  defp citation_failures(passage, fixture, source_ids) do
    logical_id = source_ids[passage["source_id"]]
    source = fixture.sources[logical_id]
    revision = source["latest_revision"]
    body = revision["body"]

    snippet =
      binary_part(body, passage["start_byte"], passage["end_byte"] - passage["start_byte"])

    parent =
      binary_part(
        body,
        passage["parent_start_byte"],
        passage["parent_end_byte"] - passage["parent_start_byte"]
      )

    checks = [
      passage["revision_id"] == revision["id"],
      passage["body_hash"] == Store.hash(body),
      passage["snippet"] == snippet,
      passage["parent_text"] == parent,
      passage["snippet_hash"] == Store.hash(snippet),
      passage["parent_hash"] == Store.hash(parent),
      String.valid?(snippet) and String.valid?(parent),
      Enum.all?(@identity, &Map.has_key?(passage, &1))
    ]

    if Enum.all?(checks), do: [], else: ["citation_bytes_or_identity:" <> logical_id]
  end

  defp read_pages(result, attrs, acc) do
    {:ok, page} = Retrieval.read_run(result["run_id"], result["digest"], attrs, caller())
    rows = acc ++ page["rows"]

    if page["next_cursor"],
      do: read_pages(result, %{"cursor" => page["next_cursor"]}, rows),
      else: rows
  end

  defp source_pins(fixture) do
    fixture.sources
    |> Enum.map(fn {logical_id, source} ->
      %{
        "logical_id" => logical_id,
        "source_id" => source["id"],
        "revision_id" => source["latest_revision"]["id"],
        "body_hash" => Store.hash(source["latest_revision"]["body"])
      }
    end)
    |> Enum.sort_by(& &1["logical_id"])
  end

  defp store_constructed_plain_run!(current, envelope, coverage, digest) do
    # Constructed compatibility mechanics, never a retained historical DB observation.
    attrs =
      current
      |> Map.from_struct()
      |> Map.drop([:__meta__, :id, :digest, :completed_at])
      |> Map.merge(%{
        id: Ecto.UUID.generate(),
        state: "preparing",
        envelope: envelope,
        coverage: coverage
      })

    {:ok, staged} = Repo.insert(struct(RetrievalRun, attrs))

    for item <- Repo.all(from item in RetrievalItem, where: item.run_id == ^current.id) do
      copied = item |> Map.from_struct() |> Map.drop([:__meta__]) |> Map.put(:run_id, staged.id)
      Repo.insert!(struct(RetrievalItem, copied))
    end

    {:ok, historical} =
      staged
      |> Ecto.Changeset.change(state: "ready", digest: digest, completed_at: DateTime.utc_now())
      |> Repo.update()

    historical
  end

  defp public_fixture! do
    root = Path.join(System.tmp_dir!(), "hf15-public-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    if Process.whereis(HarnessForge.Evidence.Capture.Scanner) == nil do
      start_supervised!({HarnessForge.Evidence.Capture.Scanner, []})
    end

    Iteration15PublicCases.create!(root, caller())
  end

  defp question_lane_member?(row),
    do: Enum.any?(row["lane_memberships"], &(&1 in ~w(support contrary chronology)))

  defp passage_ids(rows), do: MapSet.new(rows, & &1["passage_id"])

  defp write_report!(report) do
    case System.get_env("HF15_REPORT") do
      nil ->
        :ok

      path ->
        true = Path.type(path) == :absolute
        File.mkdir_p!(Path.dirname(path))
        {:ok, file} = File.open(path, [:write, :exclusive])

        try do
          IO.binwrite(file, Jason.encode_to_iodata!(report, pretty: true))
          IO.binwrite(file, "\n")
        after
          File.close(file)
        end
    end
  end

  defp timed(fun) do
    started = System.monotonic_time()
    result = fun.()
    elapsed = System.monotonic_time() - started
    {System.convert_time_unit(elapsed, :native, :microsecond), result}
  end

  defp caller do
    [
      authorize: fn -> true end,
      session_fingerprint: Contracts.sha256("iteration15 public development caller"),
      view_generation: String.duplicate("f", 32),
      reset_token: 0
    ]
  end
end
