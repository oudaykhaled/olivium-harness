defmodule HarnessForge.Company.WholeQuestionPlanTest do
  use ExUnit.Case, async: true

  alias HarnessForge.Company.Retrieval

  @goal %{"title" => "Garden", "acceptance" => "Preserve watering schedule"}
  @terms ~w(alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu)

  test "every distinct question content term reaches each question-bearing lane" do
    question = Enum.join(@terms, " ")
    plan = Retrieval.query_plan(question, @goal)

    assert plan["version"] == "query_plan_v3"
    assert plan["question"] == question
    assert plan["question_terms"] == @terms
    assert plan["base_source"] == "question"

    for name <- ~w(support contrary chronology), term <- @terms do
      assert String.contains?(lane(plan, name)["expression"], "\"#{term}\"")
    end
  end

  test "reordering retains the same terms and repetitions preserve first occurrence" do
    forward = Retrieval.query_plan(Enum.join(@terms, " "), @goal)
    reverse = Retrieval.query_plan(Enum.join(Enum.reverse(@terms), " "), @goal)
    repeated = Retrieval.query_plan("Alpha beta ALPHA gamma beta DELTA", @goal)

    assert reverse["question_terms"] == Enum.reverse(@terms)
    assert MapSet.new(forward["question_terms"]) == MapSet.new(reverse["question_terms"])
    assert repeated["question_terms"] == ~w(alpha beta gamma delta)

    assert lane(repeated, "support")["expression"] ==
             "\"alpha\" OR \"beta\" OR \"gamma\" OR \"delta\""
  end

  test "existing stopword, Unicode and operator normalization remains unchanged" do
    plan = Retrieval.query_plan("Could you please explain CAFÉ café 植物 _tag NEAR(*) ２０２６", @goal)

    assert plan["question_terms"] == ["café", "cafe", "植物", "_tag", "near", "２０２６"]
    refute String.contains?(lane(plan, "support")["expression"], "(*)")
    refute "please" in plan["question_terms"]
    assert plan == Retrieval.query_plan(plan["question"], @goal)
  end

  test "all-stopword question keeps the existing lexical fallback" do
    plan = Retrieval.query_plan("THE and THE", @goal)

    assert plan["question_terms"] == ~w(the and)
    assert plan["base_source"] == "question"
    assert lane(plan, "support")["expression"] == "\"the\" OR \"and\""
  end

  test "goal selection alone keeps the first-four last-four eight-term budget" do
    goal = %{"title" => Enum.join(@terms, " "), "acceptance" => ""}
    plan = Retrieval.query_plan("nadir", goal)

    assert lane(plan, "obligations")["expression"] ==
             "\"alpha\" OR \"beta\" OR \"gamma\" OR \"delta\" OR " <>
               "\"iota\" OR \"kappa\" OR \"lambda\" OR \"mu\""

    assert plan["question_terms"] == ["nadir"]
    assert lane(plan, "support")["expression"] == "\"nadir\""
  end

  test "a question without normalized terms uses the same bounded goal fallback" do
    goal = %{"title" => Enum.join(@terms, " "), "acceptance" => ""}
    fallback = Retrieval.query_plan("!!! 🌱", goal)
    explicit = Retrieval.query_plan("nadir", goal)

    assert fallback["question_terms"] == []
    assert fallback["base_source"] == "goal"
    assert lane(fallback, "support")["expression"] == lane(explicit, "obligations")["expression"]

    assert lane(fallback, "contrary")["expression"] ==
             "(" <>
               lane(fallback, "support")["expression"] <>
               ") AND (\"not\" OR \"except\" OR \"exception\" OR \"superseded\" OR " <>
               "\"deprecated\" OR \"changed\")"
  end

  test "maximal admitted question dimensions and high term count lose no question term" do
    maximal = String.duplicate("𐐨", 256)
    assert String.length(maximal) == 256
    assert byte_size(maximal) == 1024
    maximal_plan = Retrieval.query_plan(maximal, @goal)
    assert maximal_plan["question_terms"] == [maximal]
    assert lane(maximal_plan, "support")["expression"] == "\"#{maximal}\""

    terms = Enum.map(0..127, fn index -> <<0x4E00 + index::utf8>> end)
    question = Enum.join(terms, " ")
    assert String.length(question) == 255
    assert byte_size(question) <= 1024
    plan = Retrieval.query_plan(question, @goal)
    assert plan["question_terms"] == terms
    assert length(Regex.scan(~r/"[^"]+"/u, lane(plan, "support")["expression"])) == 128
  end

  test "five lane expressions and declared retrieval limits stay fixed" do
    plan = Retrieval.query_plan("nadir", @goal)

    assert Enum.map(plan["lanes"], & &1["lane"]) ==
             ~w(support contrary chronology obligations followup)

    assert Enum.all?(plan["lanes"], &(&1["limit"] == 20))

    assert plan["limits"] == %{
             "searches" => 5,
             "candidates" => 100,
             "passages" => 24,
             "evidence_bytes" => 32768,
             "prompt_bytes" => 49152
           }

    assert lane(plan, "chronology")["expression"] ==
             "(\"nadir\") AND (\"decision\" OR \"incident\" OR \"postmortem\" OR \"historical\")"

    assert lane(plan, "obligations")["expression"] ==
             "\"garden\" OR \"preserve\" OR \"watering\" OR \"schedule\""

    assert lane(plan, "followup")["expression"] ==
             "\"not\" OR \"except\" OR \"exception\" OR \"superseded\" OR \"deprecated\" OR \"changed\""
  end

  test "compact recipe reconstructs complete ordinary and boundary runtime plans" do
    dense = Enum.map_join(0..127, " ", fn index -> <<0x4E00 + index::utf8>> end)

    questions = [
      "Garden watering",
      Enum.join(@terms, " "),
      Enum.join(Enum.reverse(@terms), " "),
      "Garden garden WATERING",
      "THE and THE",
      "!!! 🌱",
      "İ CAFÉ café 植物 _tag",
      String.duplicate("𐐨", 256),
      dense
    ]

    for question <- questions do
      plan = Retrieval.query_plan(question, @goal)
      stored = compact(plan, ~w(garden preserve watering schedule))
      refute Map.has_key?(stored, "lanes")
      assert {:ok, ^plan} = Retrieval.decode_query_plan(stored)
    end

    dotted = Retrieval.query_plan("İ", @goal)
    assert dotted["question_terms"] == ["i̇"]

    assert {:ok, ^dotted} =
             Retrieval.decode_query_plan(compact(dotted, ~w(garden preserve watering schedule)))
  end

  test "compact fallback preserves the exact previously selected eight goal terms" do
    goal = %{"title" => Enum.join(@terms, " "), "acceptance" => ""}
    plan = Retrieval.query_plan("!!! 🌱", goal)
    selected_goal_terms = ~w(alpha beta gamma delta iota kappa lambda mu)
    stored = compact(plan, selected_goal_terms)

    assert stored["goal_terms"] == selected_goal_terms
    assert {:ok, ^plan} = Retrieval.decode_query_plan(stored)
    refute String.contains?(lane(plan, "obligations")["expression"], "epsilon")

    empty_goal_plan = Retrieval.query_plan("!!!", %{"title" => "!!!", "acceptance" => "?"})
    assert {:ok, ^empty_goal_plan} = Retrieval.decode_query_plan(compact(empty_goal_plan, []))

    for name <- ~w(support contrary chronology obligations) do
      assert lane(empty_goal_plan, name)["expression"] == ""
    end
  end

  test "recipe v1 pins literal lanes and preserves opaque stored terms without normalization" do
    stored = %{
      "version" => "query_plan_v3",
      "question" => "Original question is retained independently",
      "question_terms" => ["Saved_TERM", "i̇"],
      "base_source" => "question",
      "limits" => %{
        "searches" => 5,
        "candidates" => 100,
        "passages" => 24,
        "evidence_bytes" => 32768,
        "prompt_bytes" => 49152
      },
      "storage_encoding" => "query-plan-terms-v1",
      "lane_recipe" => "five-lane-lexical-v1",
      "goal_terms" => ["Goal_TERM"]
    }

    assert {:ok, expanded} = Retrieval.decode_query_plan(stored)
    assert expanded["question"] == stored["question"]
    assert expanded["question_terms"] == ["Saved_TERM", "i̇"]

    assert expanded["lanes"] == [
             %{"lane" => "support", "expression" => "\"Saved_TERM\" OR \"i̇\"", "limit" => 20},
             %{
               "lane" => "contrary",
               "expression" =>
                 "(\"Saved_TERM\" OR \"i̇\") AND (\"not\" OR \"except\" OR \"exception\" OR \"superseded\" OR \"deprecated\" OR \"changed\")",
               "limit" => 20
             },
             %{
               "lane" => "chronology",
               "expression" =>
                 "(\"Saved_TERM\" OR \"i̇\") AND (\"decision\" OR \"incident\" OR \"postmortem\" OR \"historical\")",
               "limit" => 20
             },
             %{"lane" => "obligations", "expression" => "\"Goal_TERM\"", "limit" => 20},
             %{
               "lane" => "followup",
               "expression" =>
                 "\"not\" OR \"except\" OR \"exception\" OR \"superseded\" OR \"deprecated\" OR \"changed\"",
               "limit" => 20
             }
           ]
  end

  test "unknown mixed and malformed stored representations fail closed" do
    plan = Retrieval.query_plan("nadir", @goal)
    stored = compact(plan, ~w(garden preserve watering schedule))

    invalid = [
      nil,
      %{},
      Map.put(stored, "storage_encoding", "query-plan-terms-v2"),
      Map.put(stored, "lane_recipe", "five-lane-lexical-v2"),
      Map.put(stored, "version", "query_plan_v2"),
      Map.put(stored, "lanes", plan["lanes"]),
      Map.put(stored, "unexpected", true),
      Map.put(plan, "storage_encoding", "unknown"),
      Map.put(plan, "lane_recipe", "five-lane-lexical-v1"),
      Map.put(plan, "goal_terms", []),
      Map.delete(stored, "question"),
      Map.put(stored, "question", <<255>>),
      Map.put(stored, "question", String.duplicate("a", 257)),
      Map.put(stored, "question", String.duplicate("𐐨", 257)),
      Map.put(stored, "question_terms", nil),
      Map.put(stored, "question_terms", [1]),
      Map.put(stored, "question_terms", [""]),
      Map.put(stored, "question_terms", ["same", "same"]),
      Map.put(stored, "question_terms", ["unsafe\"term"]),
      Map.put(stored, "question_terms", ["two terms"]),
      Map.put(stored, "question_terms", ["term\0"]),
      Map.put(stored, "question_terms", [String.duplicate("x", 4097)]),
      Map.put(stored, "goal_terms", Enum.map(1..9, &"term#{&1}")),
      Map.put(stored, "goal_terms", [String.duplicate("x", 16385)]),
      Map.put(stored, "base_source", "goal"),
      put_in(stored, ["limits", "searches"], 6)
    ]

    for value <- invalid do
      assert {:error, :invalid_query_plan} = Retrieval.decode_query_plan(value)
    end

    assert {:error, :invalid_query_plan} =
             Retrieval.decode_query_plan(Map.put(stored, "question_terms", []))
  end

  test "known plain v2 and v3 plans remain exact read values with their original lane bytes" do
    v3 = Retrieval.query_plan(Enum.join(@terms, " "), @goal)

    v2 =
      v3
      |> Map.put("version", "query_plan_v2")
      |> Map.drop(~w(question_terms base_source))
      |> Map.update!("lanes", fn lanes ->
        List.update_at(lanes, 0, &Map.put(&1, "expression", "\"historical_selected_terms\""))
      end)

    assert {:ok, ^v3} = Retrieval.decode_query_plan(v3)
    assert {:ok, ^v2} = Retrieval.decode_query_plan(v2)
    assert lane(v2, "support")["expression"] == "\"historical_selected_terms\""
  end

  defp compact(plan, goal_terms) do
    plan
    |> Map.delete("lanes")
    |> Map.merge(%{
      "storage_encoding" => "query-plan-terms-v1",
      "lane_recipe" => "five-lane-lexical-v1",
      "goal_terms" => goal_terms
    })
  end

  defp lane(plan, name), do: Enum.find(plan["lanes"], &(&1["lane"] == name))
end
