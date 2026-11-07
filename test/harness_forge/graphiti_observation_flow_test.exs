defmodule HarnessForge.Graphiti.ObservationFlowTest do
  use ExUnit.Case, async: true

  alias HarnessForge.Contracts
  alias HarnessForge.Graphiti.ObservationFlow

  @call "call:public-garden"
  @native %{
    "graphiti.extract_nodes.v1" => "graphiti_extract_nodes_v1",
    "graphiti.resolve_nodes.v1" => "graphiti_resolve_nodes_v1",
    "graphiti.extract_edges.v1" => "graphiti_extract_edges_v1",
    "graphiti.attributes.v1" => "graphiti_attribute_overlay_v1",
    "graphiti.summary_flight.v1" => "graphiti_summary_flight_v1",
    "graphiti.summary_batch.v1" => "graphiti_fact_append_v1",
    "graphiti.temporal.v1" => "graphiti_temporal_v1",
    "graphiti.save.v1" => "graphiti_save_v1"
  }

  test "bootstrap is a one-shot finished read with no bind or native continuation" do
    packet =
      page(
        1,
        "graphiti.bootstrap.v1",
        "inputs",
        nil,
        [entry("episode", %{"public" => "snapshot"}, "identity_v1")],
        "root_inventory_bootstrap_v1"
      )

    assert :ok = ObservationFlow.check(nil, packet)
    state = accept(nil, packet, 1)
    assert state["family"] == "bootstrap" and state["finished"]

    assert {:error, :closure_incomplete} =
             ObservationFlow.check(state, Map.put(packet, "context_id", Ecto.UUID.generate()))

    for changed <- [
          Map.put(packet, "parent_contexts", [handle(90)]),
          Map.put(packet, "raw_body_sha256", hash("request")),
          Map.put(packet, "phase", "derived"),
          Map.put(packet, "transform_id", "identity_v1")
        ] do
      assert {:error, :closure_incomplete} = ObservationFlow.check(nil, changed)
    end
  end

  test "search outer call finishes after its own input base with exact closed transforms" do
    input =
      page(
        1,
        "graphiti.search.v1",
        "inputs",
        nil,
        [
          entry("deterministic_output", %{
            "query" => "Public garden",
            "limit" => 1,
            "recipe_id" => "edge_hybrid_rrf_v1",
            "group_id" => "public"
          })
        ],
        "root_search_intent_v1",
        %{"prompt_name" => "graphiti.search.v1"}
      )

    state = accept(nil, input, 1)
    assert state["family"] == "search"

    final =
      page(
        2,
        "graphiti.search.v1",
        "derived",
        state["base"],
        [entry("deterministic_output", %{"candidates" => []})],
        "native_search_rrf_v1",
        %{"prompt_name" => "graphiti.search.v1", "parent_contexts" => [handle(90)]}
      )

    finished = accept(state, final, 2)
    assert finished["finished"]
    assert {:error, :closure_incomplete} = ObservationFlow.check(nil, final)

    assert {:error, :closure_incomplete} =
             ObservationFlow.check(finished, Map.put(final, "context_id", "context:3"))

    for changed <- [
          Map.put(final, "transform_id", "root_search_intent_v1"),
          Map.put(final, "logical_call_id", "call:other"),
          with_base(final, handle(91)),
          Map.put(final, "seam_id", "graphiti.save.v1")
        ] do
      assert {:error, :closure_incomplete} = ObservationFlow.check(state, changed)
    end
  end

  test "model input messages bind physical receipt and logical response have distinct bases" do
    enclosing = handle(90)
    inputs = model_inputs(1, [enclosing])
    assert :ok = ObservationFlow.check(nil, inputs)
    state = accept(nil, inputs, 1)
    messages = messages(2, state, [enclosing])
    state = accept(state, messages, 2)
    request = bind(3, state)
    bound = accept(state, request, 3)
    assert bound["base"] == handle(2)
    assert bound["pending_bind"] == handle(3)

    response = physical(4, bound)
    assert response["base_context_ref"] == handle(2)["manifest_ref"]
    state = accept(bound, response, 4)
    assert state["base"] == handle(4)
    assert is_nil(state["pending_bind"])
    assert state["responses"] == [handle(4)]

    completed = accept(state, logical(5, state), 5)
    assert completed["finished"] and completed["step"] == "finished"
    assert completed["base"] == handle(5)
    assert completed["responses"] == [handle(4)]
    assert {:error, :closure_incomplete} = ObservationFlow.check(completed, logical(6, completed))
    assert {:error, :closure_incomplete} = ObservationFlow.record(completed, inputs, handle(6))
  end

  test "three physical attempts retain every response parent and a fourth bind is denied" do
    state = model_ready()

    state =
      Enum.reduce(0..2, state, fn attempt, state ->
        n = 10 + attempt * 3
        bound = accept(state, bind(n, state), n)
        assert bound["base"] == state["base"]
        response = physical(n + 1, bound)
        assert response["parent_contexts"] == [handle(n) | state["responses"]]

        # Parent contexts are an exact set; transport ordering carries no authority.
        response = Map.update!(response, "parent_contexts", &Enum.reverse/1)
        accept(bound, response, n + 1)
      end)

    assert length(state["responses"]) == 3
    assert {:error, :closure_incomplete} = ObservationFlow.check(state, bind(20, state))
    assert {:error, :closure_incomplete} = ObservationFlow.check(state, physical(21, state))
    assert accept(state, logical(22, state), 22)["finished"]
  end

  test "embedder skips rendered messages and permits only embedding binds" do
    inputs =
      page(
        1,
        "embedder.input.v1",
        "inputs",
        nil,
        [entry("embed_input", ["Public garden"], "embed_text_v1")],
        "identity_v1"
      )

    state = accept(nil, inputs, 1)
    assert state["family"] == "embed"
    assert {:error, :closure_incomplete} = ObservationFlow.check(state, messages(2, state))
    assert {:error, :closure_incomplete} = ObservationFlow.check(state, bind(3, state, "model"))
    bound = accept(state, bind(4, state), 4)
    state = accept(bound, physical(5, bound), 5)
    completed = accept(state, logical(6, state), 6)
    assert completed["finished"]
  end

  test "Jev uses the model family with one native rendered bind projection" do
    ready = model_ready()

    request =
      bind(3, ready)
      |> Map.put("transform_id", "native_jev_fit_v1")
      |> Map.put("entries", [
        entry(
          "rendered_message",
          %{"state" => %{}, "questions" => ["Public garden?"]},
          "native_jev_fit_v1"
        )
      ])

    assert :ok = ObservationFlow.check(ready, request)

    assert {:error, :closure_incomplete} =
             ObservationFlow.check(ready, Map.update!(request, "entries", &(&1 ++ &1)))

    bound = accept(ready, request, 3)
    state = accept(bound, physical(4, bound), 4)
    assert accept(state, logical(5, state), 5)["finished"]
  end

  test "model skips extra binds unreceipted physical output and repeated messages are denied" do
    inputs = model_inputs(1)
    state = accept(nil, inputs, 1)
    assert {:error, :closure_incomplete} = ObservationFlow.check(nil, messages(2, state))
    assert {:error, :closure_incomplete} = ObservationFlow.check(state, bind(3, state))
    assert {:error, :closure_incomplete} = ObservationFlow.check(state, logical(4, state))
    ready = accept(state, messages(5, state), 5)
    assert {:error, :closure_incomplete} = ObservationFlow.check(ready, messages(6, ready))
    assert {:error, :closure_incomplete} = ObservationFlow.check(ready, physical(7, ready))
    bound = accept(ready, bind(8, ready), 8)
    assert {:error, :closure_incomplete} = ObservationFlow.check(bound, bind(9, bound))
    assert {:error, :closure_incomplete} = ObservationFlow.check(bound, logical(10, bound))
  end

  test "physical and logical response parents reject omissions extras duplicates and digest substitutions" do
    ready = model_ready()
    bound = accept(ready, bind(3, ready), 3)
    response = physical(4, bound)

    for parents <- [
          [],
          [handle(3), handle(90)],
          [handle(3), handle(3)],
          [Map.put(handle(3), "manifest_digest", hash("forged"))]
        ] do
      assert {:error, :closure_incomplete} =
               ObservationFlow.check(bound, Map.put(response, "parent_contexts", parents))
    end

    first = accept(bound, response, 4)
    second_bound = accept(first, bind(5, first), 5)
    second = physical(6, second_bound)

    assert {:error, :closure_incomplete} =
             ObservationFlow.check(second_bound, Map.put(second, "parent_contexts", [handle(5)]))

    state = accept(second_bound, second, 6)
    logical = logical(7, state)

    for parents <- [[handle(6)], [handle(4)], [handle(4), handle(6), handle(5)]] do
      assert {:error, :closure_incomplete} =
               ObservationFlow.check(state, Map.put(logical, "parent_contexts", parents))
    end

    assert :ok = ObservationFlow.check(state, logical)
  end

  test "call identity is immutable at messages bind physical logical and native transitions" do
    inputs = model_inputs(1)
    input_state = accept(nil, inputs, 1)
    ready = accept(input_state, messages(2, input_state), 2)
    bound = accept(ready, bind(3, ready), 3)
    response = accept(bound, physical(4, bound), 4)
    native_input = native(10, "graphiti.extract_nodes.v1", "inputs", nil, %{"arguments" => %{}})
    native_state = accept(nil, native_input, 10)

    for {state, next} <- [
          {input_state, messages(2, input_state)},
          {ready, bind(3, ready)},
          {bound, physical(4, bound)},
          {response, logical(5, response)},
          {native_state,
           native(11, "graphiti.extract_nodes.v1", "derived", native_state, %{
             "before" => %{},
             "after" => %{},
             "result" => []
           })}
        ],
        {field, value} <- [
          {"stage_id", "stage:changed"},
          {"config_digest", hash("config changed")},
          {"schema_digest", hash("schema changed")},
          {"prompt_name", "unknown.changed_prompt"},
          {"logical_call_id", "call:changed"}
        ] do
      assert {:error, :closure_incomplete} =
               ObservationFlow.check(state, Map.put(next, field, value))
    end
  end

  test "every transition requires its own exact previous base and a fresh context identity" do
    inputs = model_inputs(1)

    assert {:error, :closure_incomplete} =
             ObservationFlow.check(nil, with_base(inputs, handle(90)))

    state = accept(nil, inputs, 1)
    ready = accept(state, messages(2, state), 2)
    bound = accept(ready, bind(3, ready), 3)
    response = accept(bound, physical(4, bound), 4)

    for {prior, next} <- [
          {state, messages(2, state)},
          {ready, bind(3, ready)},
          {bound, physical(4, bound)},
          {response, logical(5, response)}
        ] do
      assert {:error, :closure_incomplete} =
               ObservationFlow.check(prior, with_base(next, handle(90)))

      assert {:error, :closure_incomplete} =
               ObservationFlow.check(prior, Map.put(next, "context_id", prior["last_context_id"]))
    end
  end

  test "ordinary native seams require inputs then final result with fixed seam and transform" do
    for {seam, _transform} <- @native do
      initial = native(1, seam, "inputs", nil, %{"arguments" => %{}})
      state = accept(nil, initial, 1)
      assert state["family"] == "native"

      final =
        native(2, seam, "derived", state, %{"before" => %{}, "after" => %{}, "result" => []}, [
          handle(90)
        ])

      assert {:error, :closure_incomplete} = ObservationFlow.check(nil, final)

      assert {:error, :closure_incomplete} =
               ObservationFlow.check(state, Map.put(final, "transform_id", "identity_v1"))

      assert {:error, :closure_incomplete} =
               ObservationFlow.check(state, with_base(final, handle(90)))

      completed = accept(state, final, 2)
      assert completed["finished"]
      assert {:error, :closure_incomplete} = ObservationFlow.check(completed, final)
    end
  end

  test "summary batch checkpoints advance only the batch base before its final result" do
    seam = "graphiti.summary_batch.v1"
    state = accept(nil, native(1, seam, "inputs", nil, %{"arguments" => %{}}), 1)

    checkpoint =
      native(2, seam, "derived", state, %{
        "before" => %{},
        "after" => %{"summary" => "Appended public fact"}
      })

    assert checkpoint["transform_id"] == "graphiti_fact_append_v1"
    state = accept(state, checkpoint, 2)
    assert state["step"] == "native" and not state["finished"]

    next = native(3, seam, "derived", state, %{"before" => %{}, "after" => %{}})
    state = accept(state, next, 3)

    assert accept(
             state,
             native(4, seam, "derived", state, %{"before" => %{}, "after" => %{}, "result" => []}),
             4
           )["finished"]

    other_seam = "graphiti.summary_flight.v1"
    other = accept(nil, native(10, other_seam, "inputs", nil, %{"arguments" => %{}}), 10)

    assert {:error, :closure_incomplete} =
             ObservationFlow.check(
               other,
               native(11, other_seam, "derived", other, %{"before" => %{}, "after" => %{}})
             )

    assert {:error, :closure_incomplete} =
             ObservationFlow.check(
               other,
               native(12, seam, "derived", other, %{
                 "before" => %{},
                 "after" => %{},
                 "result" => []
               })
             )
  end

  test "fresh temporal mutation requires certified parents then exact temporal-context linkage" do
    seam = "graphiti.temporal.v1"
    first = native(1, seam, "derived", nil, %{"before" => [], "after" => []}, [handle(90)])

    assert {:error, :closure_incomplete} =
             ObservationFlow.check(nil, Map.put(first, "parent_contexts", []))

    assert {:error, :closure_incomplete} =
             ObservationFlow.check(nil, with_base(first, handle(90)))

    state = accept(nil, first, 1)
    assert state["step"] == "temporal"

    second =
      native(2, seam, "derived", state, %{"temporal_context" => handle(1)["manifest_ref"]}, [
        handle(1),
        handle(90)
      ])

    assert :ok = ObservationFlow.check(state, second)

    assert {:error, :closure_incomplete} =
             ObservationFlow.check(state, Map.put(second, "parent_contexts", [handle(90)]))

    assert {:error, :closure_incomplete} =
             ObservationFlow.check(state, with_base(second, handle(90)))

    assert {:error, :closure_incomplete} =
             ObservationFlow.check(
               state,
               native(
                 3,
                 seam,
                 "derived",
                 state,
                 %{"temporal_context" => handle(90)["manifest_ref"]},
                 [handle(1)]
               )
             )

    completed = accept(state, second, 2)
    assert completed["finished"]
    assert {:error, :closure_incomplete} = ObservationFlow.check(completed, second)
    assert {:error, :closure_incomplete} = ObservationFlow.check(nil, second)
  end

  test "native detail is selected by logical call and cannot be replaced by an object projection" do
    initial = native(1, "graphiti.extract_nodes.v1", "inputs", nil, %{"arguments" => %{}})

    object =
      entry(
        "deterministic_output",
        %{"object_type" => "EntityNode"},
        "identity_v1",
        nil,
        "node:public-garden"
      )

    assert :ok = ObservationFlow.check(nil, Map.update!(initial, "entries", &[object | &1]))

    assert {:error, :closure_incomplete} =
             ObservationFlow.check(nil, Map.put(initial, "entries", [object]))

    assert {:error, :closure_incomplete} =
             ObservationFlow.check(nil, Map.update!(initial, "entries", &(&1 ++ &1)))
  end

  test "state is fixed-key JSON and contains no input message native or response values" do
    sentinel = "PUBLIC_FIXTURE_BODY_MUST_NOT_BE_RETAINED"

    inputs =
      Map.put(model_inputs(1), "entries", [
        entry("deterministic_output", String.duplicate(sentinel, 200), "graphiti_context_v1")
      ])

    state = accept(nil, inputs, 1)
    assert {:ok, encoded} = Jason.encode(state)
    refute String.contains?(encoded, sentinel)
    assert byte_size(encoded) < 2_500
    assert {:ok, restored} = Jason.decode(encoded)
    assert restored == state
    assert :ok = ObservationFlow.check(restored, messages(2, restored))

    assert {:error, :closure_incomplete} =
             ObservationFlow.check(Map.put(state, "body", sentinel), messages(2, state))
  end

  test "malformed state pages unsealed handles and retained-handle reuse fail closed" do
    inputs = model_inputs(1)

    for handle <- [
          nil,
          %{},
          %{"manifest_ref" => "not-a-uuid", "manifest_digest" => hash("x")},
          Map.put(handle(1), "permission", "allow"),
          Map.put(handle(1), "manifest_digest", "bad")
        ] do
      assert {:error, :closure_incomplete} = ObservationFlow.record(nil, inputs, handle)
    end

    state = accept(nil, inputs, 1)

    assert {:error, :closure_incomplete} =
             ObservationFlow.record(state, messages(2, state), handle(1))

    for malformed <- [
          nil,
          %{},
          [],
          Map.delete(inputs, "base_context_ref"),
          Map.put(inputs, "page_index", 1),
          Map.put(inputs, "final", false),
          Map.put(inputs, "entries", []),
          Map.put(inputs, "entries", List.duplicate(hd(inputs["entries"]), 101)),
          Map.put(inputs, "parent_contexts", List.duplicate(handle(90), 101)),
          Map.put(inputs, "base_context_digest", hash("unpaired"))
        ] do
      assert {:error, :closure_incomplete} = ObservationFlow.check(nil, malformed)
    end

    for malformed <- [
          %{},
          [],
          %{state | "responses" => List.duplicate(handle(90), 4)},
          %{state | "finished" => true},
          %{state | "family" => "unknown"}
        ] do
      assert {:error, :closure_incomplete} = ObservationFlow.check(malformed, messages(2, state))
    end
  end

  defp model_ready do
    state = accept(nil, model_inputs(1), 1)
    accept(state, messages(2, state), 2)
  end

  defp accept(state, page, ordinal) do
    assert :ok = ObservationFlow.check(state, page)
    assert {:ok, result} = ObservationFlow.record(state, page, handle(ordinal))
    result
  end

  defp model_inputs(n, parents \\ []),
    do:
      page(
        n,
        "llm.context.v1",
        "inputs",
        nil,
        [entry("deterministic_output", %{"query" => "Public garden"}, "graphiti_context_v1")],
        "graphiti_builder_v1",
        %{"parent_contexts" => parents}
      )

  defp messages(n, state, parents \\ []),
    do:
      page(
        n,
        "llm.messages.v1",
        "inputs",
        state["base"],
        [
          entry(
            "rendered_message",
            %{"role" => "user", "content" => "Public garden"},
            "messages_v1"
          )
        ],
        "graphiti_builder_v1",
        %{"parent_contexts" => parents}
      )

  defp bind(n, state, family \\ nil) do
    family = family || state["family"]

    {entries, transform} =
      if family == "embed",
        do:
          {[entry("embed_input", ["Public garden"], "embed_text_v1")], "official_openai_embed_v1"},
        else:
          {[
             entry(
               "rendered_message",
               %{"role" => "user", "content" => "Public garden"},
               "messages_v1"
             )
           ], "official_openai_chat_v1"}

    page(n, "http.serialized.v1", "attempt_bind", state["base"], entries, transform)
  end

  defp physical(n, state),
    do:
      page(
        n,
        "llm.response.v1",
        "derived",
        state["base"],
        [
          entry(
            "deterministic_output",
            %{
              "attempt_id" => "attempt:#{n}",
              "http_status" => 200,
              "body_bytes" => 2,
              "body_sha256" => hash("{}")
            },
            "identity_v1",
            "receipt:#{n}"
          )
        ],
        "model_response_v1",
        %{
          "parent_contexts" =>
            Enum.reject([state["pending_bind"] | state["responses"]], &is_nil/1)
        }
      )

  defp logical(n, state),
    do:
      page(
        n,
        "llm.response.v1",
        "derived",
        state["base"],
        [entry("deterministic_output", %{"result" => "Public garden"})],
        "model_response_v1",
        %{"parent_contexts" => state["responses"]}
      )

  defp native(n, seam, phase, state, detail, parents \\ []) do
    page(
      n,
      seam,
      phase,
      if(is_nil(state), do: nil, else: state["base"]),
      [entry("deterministic_output", detail)],
      Map.fetch!(@native, seam),
      %{"prompt_name" => seam, "parent_contexts" => parents}
    )
  end

  defp page(n, seam, phase, base, entries, transform, changes \\ %{}) do
    %{
      "job_id" => "job:public-garden",
      "partition_id" => uuid(900),
      "lease_id" => uuid(901),
      "cancel_epoch" => 0,
      "semantic_generation" => 1,
      "authorization_generation" => 1,
      "operation_manifest_ref" => uuid(902),
      "operation_manifest_digest" => hash("source certificate"),
      "context_id" => "context:#{n}",
      "logical_call_id" => @call,
      "stage_id" => "stage:public-garden",
      "config_digest" => hash("qualified config"),
      "schema_digest" => hash("actual schema"),
      "prompt_name" => "extract_nodes.extract_text",
      "phase" => phase,
      "seam_id" => seam,
      "page_index" => 0,
      "previous_page_digest" => nil,
      "final" => true,
      "entries" => entries,
      "base_context_ref" => if(base, do: base["manifest_ref"]),
      "base_context_digest" => if(base, do: base["manifest_digest"]),
      "parent_contexts" => [],
      "raw_body_sha256" => if(phase == "attempt_bind", do: hash("request:#{n}")),
      "rendered_projection_digest" => Contracts.digest(entries),
      "transform_id" => transform
    }
    |> Map.merge(changes)
  end

  defp with_base(page, handle),
    do:
      Map.merge(page, %{
        "base_context_ref" => handle["manifest_ref"],
        "base_context_digest" => handle["manifest_digest"]
      })

  defp entry(kind, value, projection \\ "identity_v1", receipt \\ nil, object \\ @call) do
    digest = Contracts.digest(value)

    %{
      "entry_id" =>
        "entry:" <>
          String.slice(
            Contracts.digest(%{"kind" => kind, "hash" => digest, "object" => object}),
            0,
            24
          ),
      "kind" => kind,
      "object_id" => object,
      "version_ref" => nil,
      "predecessor_version_ref" => nil,
      "value_hash" => digest,
      "value" => value,
      "projection_id" => projection,
      "projection_hash" => digest,
      "parent_manifest_ref" => uuid(902),
      "parent_manifest_digest" => hash("source certificate"),
      "receipt_ref" => receipt
    }
  end

  defp handle(n), do: %{"manifest_ref" => uuid(n), "manifest_digest" => hash("sealed:#{n}")}

  defp uuid(n),
    do: "00000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(n, 16), 12, "0")

  defp hash(value), do: Contracts.sha256(value)
end
