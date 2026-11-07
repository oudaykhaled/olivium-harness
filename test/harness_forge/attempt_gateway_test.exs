defmodule HarnessForge.Models.AttemptGatewayTest do
  use ExUnit.Case, async: true
  alias HarnessForge.{Contracts, Graphiti.Protocol}
  alias HarnessForge.Models.AttemptGateway

  defp attempt do
    body = "{\"model\":\"synthetic\"}"

    %{
      "job_id" => "job:synthetic",
      "logical_call_id" => "call:synthetic",
      "attempt_id" => "attempt:synthetic",
      "stage_id" => "stage:synthetic",
      "stage_digest" => String.duplicate("1", 64),
      "prompt_name" => "dedupe_nodes.nodes",
      "closure_ref" => "manifest:synthetic",
      "closure_digest" => String.duplicate("2", 64),
      "context_manifest_ref" => "context:synthetic",
      "context_manifest_digest" => String.duplicate("3", 64),
      "cancel_epoch" => 0,
      "payload_sha256" => Contracts.sha256(body),
      "method" => "POST",
      "route_id" => "route:synthetic",
      "body" => body,
      "timeout_ms" => 1000,
      "max_output_tokens" => 100,
      "context_changed" => false,
      "ordinal" => 1,
      "predecessor_attempt_id" => nil
    }
  end

  test "actual bytes and predecessor identity bind each physical send" do
    first = attempt()
    assert :ok = Protocol.validate_payload("attempt", first)

    assert {:error, :invalid_dto} =
             Protocol.validate_payload("attempt", Map.put(first, "body", "changed"))

    assert {:error, :invalid_dto} =
             Protocol.validate_payload("attempt", Map.put(first, "ordinal", 2))

    second =
      first |> Map.put("ordinal", 2) |> Map.put("predecessor_attempt_id", first["attempt_id"])

    assert :ok = Protocol.validate_payload("attempt", second)

    assert {:error, :invalid_dto} =
             Protocol.validate_payload("attempt", Map.put(second, "ordinal", 4))
  end

  test "unknown fields deny before any authority or HTTP access" do
    assert {:error, :invalid_dto} =
             AttemptGateway.dispatch(Map.put(attempt(), "permission", "allow"), nil)

    assert {:error, :invalid_dto} =
             AttemptGateway.dispatch(Map.put(attempt(), "method", "GET"), nil)
  end
end
