defmodule HarnessForge.Graphiti.ResponseProofTest do
  use ExUnit.Case, async: true
  alias HarnessForge.{Contracts, Graphiti.ResponseProof}

  test "offline value proof binds the nonce, entire ordered transcript and exact canonical value" do
    transcript = [
      %{"attempt_id" => "first", "receipt_id" => "one", "body" => "public response one"},
      %{"attempt_id" => "second", "receipt_id" => "two", "body" => "public response two"}
    ]

    request = %{"nonce" => Ecto.UUID.generate(), "transcript" => transcript}
    value = %{"extracted_nodes" => []}

    response = %{
      "v" => 1,
      "nonce" => request["nonce"],
      "state" => "ok",
      "transcript_sha256" => Contracts.digest(transcript),
      "consumed_receipts" => Enum.map(transcript, &Map.take(&1, ~w(attempt_id receipt_id))),
      "value" => value,
      "value_sha256" => Contracts.digest(value),
      "error_code" => nil
    }

    assert :ok = ResponseProof.validate_result(request, response)

    for invalid <- [
          Map.put(response, "nonce", Ecto.UUID.generate()),
          Map.put(response, "consumed_receipts", Enum.reverse(response["consumed_receipts"])),
          Map.put(response, "state", "denied"),
          Map.put(response, "value", %{"extracted_nodes" => [%{"name" => "changed"}]}),
          Map.put(response, "extra", "unqualified")
        ] do
      assert {:error, :closure_incomplete} = ResponseProof.validate_result(request, invalid)
    end

    assert {:error, :closure_incomplete} =
             ResponseProof.validate_result(
               %{request | "transcript" => Enum.reverse(transcript)},
               response
             )

    changed = put_in(request, ["transcript", Access.at(0), "body"], "substituted raw bytes")
    assert {:error, :closure_incomplete} = ResponseProof.validate_result(changed, response)
  end
end
