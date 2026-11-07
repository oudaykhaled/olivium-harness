defmodule HarnessForge.Graphiti.SearchCompletionTest do
  use ExUnit.Case, async: true
  alias HarnessForge.Contracts
  alias HarnessForge.Graphiti.{CompletionCommitment, SearchCompletion}

  @moduledoc "Pure score/DTO and malformed refusal tests. Root alone qualifies live publication."

  test "exact binary64 projection preserves order and negative-zero bits" do
    first = candidate("8000000000000000")
    second = candidate("3ff0000000000000")
    assert SearchCompletion.valid_projection?(%{"candidates" => [first, second]}, 2)

    result = %{
      "job_id" => Ecto.UUID.generate(),
      "state" => "completed",
      "generation" => 1,
      "closure_digest" => Contracts.sha256("public S"),
      "receipt_count" => 1,
      "receipt_digest" => Contracts.digest([Ecto.UUID.generate()]),
      "result" => %{
        "candidates" => [Map.put(first, "score", -0.0), Map.put(second, "score", 1.0)]
      }
    }

    assert {:ok, projection} = CompletionCommitment.projection(result)
    assert projection["envelope"]["result"] == %{"candidates" => [first, second]}
    assert SearchCompletion.valid_projection?(%{"candidates" => []}, 10)
  end

  test "unknown score representations and nonfinite bits deny" do
    good = candidate("3ff0000000000000")

    for score <- [
          0,
          0.0,
          nil,
          %{"format" => "decimal", "bits" => "3ff0000000000000"},
          %{"format" => "ieee754-be-f64-v1", "bits" => "7ff0000000000000"},
          %{"format" => "ieee754-be-f64-v1", "bits" => "7ff8000000000001"},
          %{"format" => "ieee754-be-f64-v1", "bits" => "3FF0000000000000"},
          Map.put(good["score"], "extra", true)
        ] do
      refute SearchCompletion.valid_projection?(
               %{"candidates" => [Map.put(good, "score", score)]},
               1
             )
    end
  end

  test "candidate and support caps cannot truncate duplicate foreign or oversized values" do
    good = candidate("0000000000000000")

    for value <- [
          %{"candidates" => [good, good]},
          %{"candidates" => [Map.put(good, "edge_id", "foreign")]},
          %{"candidates" => [Map.put(good, "episode_ids", [])]},
          %{
            "candidates" => [
              Map.put(good, "episode_ids", List.duplicate(hd(good["episode_ids"]), 2))
            ]
          },
          %{
            "candidates" => [
              Map.put(good, "episode_ids", for(_ <- 1..25, do: Ecto.UUID.generate()))
            ]
          },
          %{"candidates" => [Map.put(good, "extra", true)]},
          %{"candidates" => [], "nodes" => []}
        ] do
      refute SearchCompletion.valid_projection?(value, 10)
    end

    refute SearchCompletion.valid_projection?(%{"candidates" => [good]}, 0)
    refute SearchCompletion.valid_projection?(%{"candidates" => [good]}, 11)
  end

  test "certificate requires positive exact base and all seven keys without granting authority" do
    cert = %{
      "format" => "graph-search-certificate-v1",
      "search_ref" => Ecto.UUID.generate(),
      "search_digest" => Contracts.sha256("public C"),
      "partition_id" => Ecto.UUID.generate(),
      "base_inventory" => %{
        "inventory_revision" => 1,
        "inventory_manifest_id" => Ecto.UUID.generate(),
        "inventory_manifest_digest" => Contracts.sha256("public base")
      },
      "query_digest" => Contracts.sha256("public query"),
      "result_digest" => Contracts.sha256("public result")
    }

    assert SearchCompletion.valid_certificate?(cert)

    for invalid <- [
          Map.delete(cert, "query_digest"),
          Map.put(cert, "extra", true),
          put_in(cert, ["base_inventory", "inventory_revision"], 0),
          put_in(cert, ["base_inventory", "inventory_manifest_id"], nil),
          Map.put(cert, "format", "legacy")
        ] do
      refute SearchCompletion.valid_certificate?(invalid)
    end

    assert {:error, :closure_incomplete} = SearchCompletion.validate_request(nil, %{}, %{})
    assert {:error, :closure_incomplete} = SearchCompletion.publish(nil, %{}, %{})
    assert {:error, :closure_incomplete} = SearchCompletion.validate_stored_certificate(%{}, %{})
  end

  defp candidate(bits),
    do: %{
      "edge_id" => Ecto.UUID.generate(),
      "episode_ids" => [Ecto.UUID.generate()],
      "score" => %{"format" => "ieee754-be-f64-v1", "bits" => bits}
    }
end
