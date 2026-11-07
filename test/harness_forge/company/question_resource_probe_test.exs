defmodule HarnessForge.Company.QuestionResourceProbeTest do
  use HarnessForge.DataCase, async: false

  alias HarnessForge.{Contracts, Evidence, Iteration15PublicCases, Repo}
  alias HarnessForge.Company.{Retrieval, RetrievalRun}
  alias HarnessForge.Evidence.{Capture, Corpora, Passages, Store}

  @tag timeout: 120_000
  test "dense public evidence and maximal term fanout retain the bounded publication fence" do
    root = Path.join(System.tmp_dir!(), "hf15-resource-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    if Process.whereis(HarnessForge.Evidence.Capture.Scanner) == nil do
      start_supervised!({HarnessForge.Evidence.Capture.Scanner, []})
    end

    fixture = Iteration15PublicCases.create!(root, caller())
    terms = Enum.map(0..127, fn index -> <<0x4E00 + index::utf8>> end)
    question = Enum.join(terms, " ")
    assert String.length(question) == 255
    assert byte_size(question) <= 1024

    additions =
      for ordinal <- 0..23 do
        lane_word = Enum.at(~w(exception incident ordinary), rem(ordinal, 3))
        name = "resource-#{ordinal}.md"
        body = question <> "\nFuture visitor queue orientation #{lane_word} record #{ordinal}."
        File.write!(Path.join([root, "public-archive-documents", name]), body)

        {:ok, source} =
          Evidence.import_markdown(fixture.connection["id"], %{
            "external_id" => name,
            "title" => "Synthetic resource probe #{ordinal}",
            "body" => body,
            "metadata" => %{"synthetic" => true}
          })

        %{
          "source_id" => source["id"],
          "revision_id" => source["latest_revision"]["id"],
          "action" => "include"
        }
      end

    {:ok, current} = Corpora.get(fixture.corpus.id)

    {:ok, current} =
      Corpora.apply_members(fixture.corpus.id, current.semantic_generation, additions, caller())

    {:ok, capture} =
      Capture.start_capture(
        fixture.corpus.id,
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

    {:ok, current} = Corpora.get(fixture.corpus.id)

    input =
      Map.merge(fixture.input, %{
        "question" => question,
        "expected_generation" => current.semantic_generation
      })

    before_count = Repo.aggregate(RetrievalRun, :count)
    parent = self()
    tracer = spawn(fn -> watch_serialization(parent) end)
    on_exit(fn -> if Process.alive?(tracer), do: Process.exit(tracer, :kill) end)
    :erlang.trace_pattern({Contracts, :canonical_json, 1}, true, [:local])
    :erlang.trace(self(), true, [:call, {:tracer, tracer}])

    outcome =
      try do
        Retrieval.retrieve(input, caller())
      after
        :erlang.trace(self(), false, [:call])
        :erlang.trace_pattern({Contracts, :canonical_json, 1}, false, [:local])
      end

    attempted_envelope =
      receive do
        {:attempted_envelope, envelope} -> envelope
      after
        5000 -> nil
      end

    Process.exit(tracer, :kill)

    observation =
      case outcome do
        {:ok, result} ->
          {:ok, run} = Store.get(RetrievalRun, result["run_id"])
          {:ok, expanded_plan} = Retrieval.decode_query_plan(run.envelope["query_plan"])
          expected_plan = Retrieval.query_plan(question, fixture.goal)

          %{
            "outcome" => "ok",
            "selected_count" => result["selected_count"],
            "state" => result["state"],
            "envelope_bytes" => byte_size(Contracts.canonical_json(run.envelope)),
            "effective_query_roundtrip_exact" => expanded_plan == expected_plan,
            "expanded_query_plan" => expanded_plan,
            "stored_query_plan" => run.envelope["query_plan"],
            "coverage" => run.coverage
          }

        {:error, reason} ->
          %{"outcome" => "error", "reason" => inspect(reason)}
      end

    observation =
      Map.merge(observation, %{
        "format" => "iteration15-public-dense-resource-probe-v1",
        "source_count" => length(sources),
        "additional_dense_sources" => 24,
        "question_characters" => String.length(question),
        "question_bytes" => byte_size(question),
        "question_terms" => length(terms),
        "attempted_envelope" => attempted_envelope,
        "actual_attempted_envelope_bytes" =>
          if(attempted_envelope, do: byte_size(Contracts.canonical_json(attempted_envelope))),
        "attempted_selected_count" =>
          if(attempted_envelope, do: length(attempted_envelope["passages"])),
        "run_count_before" => before_count,
        "run_count_after" => Repo.aggregate(RetrievalRun, :count),
        "model_dispatch" => "none",
        "limit" =>
          "Synthetic resource boundary, not semantic retrieval quality or physical-scale qualification"
      })

    if path = System.get_env("HF15_RESOURCE_REPORT") do
      assert Path.type(path) == :absolute
      File.mkdir_p!(Path.dirname(path))
      {:ok, file} = File.open(path, [:write, :exclusive])

      try do
        IO.binwrite(file, Jason.encode_to_iodata!(observation, pretty: true))
      after
        File.close(file)
      end
    end

    assert {:ok, _} = outcome, inspect(observation)
    assert observation["envelope_bytes"] <= 16384
    assert observation["selected_count"] == 24
    assert observation["effective_query_roundtrip_exact"]
  end

  defp watch_serialization(parent) do
    receive do
      {:trace, _pid, :call,
       {Contracts, :canonical_json, [%{"query_plan" => _, "passages" => _} = envelope]}} ->
        send(parent, {:attempted_envelope, envelope})
        watch_serialization(parent)

      _ ->
        watch_serialization(parent)
    end
  end

  defp caller do
    [
      authorize: fn -> true end,
      session_fingerprint: Contracts.sha256("iteration15 public resource probe"),
      view_generation: String.duplicate("c", 32),
      reset_token: 0
    ]
  end
end
