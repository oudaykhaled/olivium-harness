defmodule HarnessForge.Graphiti.CompletionCommitmentTest do
  use ExUnit.Case, async: true
  alias HarnessForge.{Contracts, Graphiti.CompletionCommitment}

  defp payload(candidates) do
    %{
      "job_id" => Ecto.UUID.generate(),
      "state" => "completed",
      "generation" => 3,
      "closure_digest" => String.duplicate("a", 64),
      "receipt_count" => 1,
      "receipt_digest" => String.duplicate("b", 64),
      "result" => %{"candidates" => candidates}
    }
  end

  defp candidate(score),
    do: %{
      "edge_id" => Ecto.UUID.generate(),
      "episode_ids" => [Ecto.UUID.generate()],
      "score" => score
    }

  test "canonical projection preserves native order and every other envelope field" do
    first = candidate(0.125)
    second = candidate(-2.0)
    original = payload([first, second])
    assert {:ok, projection} = CompletionCommitment.projection(original)
    assert projection["format"] == "graph-completion-v1"
    assert Map.delete(projection["envelope"], "result") == Map.delete(original, "result")
    projected = projection["envelope"]["result"]["candidates"]

    assert Enum.map(projected, &Map.delete(&1, "score")) ==
             Enum.map([first, second], &Map.delete(&1, "score"))

    assert Enum.map(projected, & &1["score"]["bits"]) == ["3fc0000000000000", "c000000000000000"]
    assert {:ok, digest} = CompletionCommitment.digest(original)
    assert digest == Contracts.digest(projection)
    assert_raise ArgumentError, fn -> Contracts.digest(original) end
  end

  test "signed zero and a changed score or envelope have distinct commitments" do
    original = payload([candidate(0.0)])
    negative_zero = put_in(original, ["result", "candidates", Access.at(0), "score"], -0.0)
    {:ok, positive} = CompletionCommitment.projection(original)
    {:ok, negative} = CompletionCommitment.projection(negative_zero)
    assert hd(positive["envelope"]["result"]["candidates"])["score"]["bits"] == "0000000000000000"
    assert hd(negative["envelope"]["result"]["candidates"])["score"]["bits"] == "8000000000000000"
    refute CompletionCommitment.digest(original) == CompletionCommitment.digest(negative_zero)

    refute CompletionCommitment.digest(original) ==
             CompletionCommitment.digest(Map.put(original, "generation", 4))

    refute CompletionCommitment.digest(original) ==
             CompletionCommitment.digest(
               put_in(original, ["result", "candidates", Access.at(0), "score"], 1.0)
             )
  end

  test "unsupported result states missing scores integer substitutes and unknown fields deny" do
    original = payload([candidate(1.0)])

    for invalid <- [
          Map.put(original, "state", "uncertain"),
          put_in(original, ["result", "candidates", Access.at(0), "score"], 1),
          update_in(original, ["result", "candidates", Access.at(0)], &Map.delete(&1, "score")),
          put_in(original, ["result", "candidates", Access.at(0), "extra"], "unqualified"),
          Map.put(original, "result", %{"readiness" => "configured"})
        ] do
      assert {:error, :closure_incomplete} = CompletionCommitment.digest(invalid)
    end
  end

  test "ingest result commitment is separately domain bound with no source body duplication" do
    ingest =
      payload([])
      |> Map.put("result", %{
        "binding_id" => Ecto.UUID.generate(),
        "episode_uuid" => Ecto.UUID.generate()
      })

    assert {:ok, projection} = CompletionCommitment.projection(ingest)
    assert projection == %{"format" => "graph-completion-v1", "envelope" => ingest}
    assert {:ok, digest} = CompletionCommitment.digest(ingest)
    refute digest == Contracts.digest(ingest)
  end
end
