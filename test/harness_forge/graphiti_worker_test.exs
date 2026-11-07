defmodule HarnessForge.Graphiti.WorkerTest do
  use ExUnit.Case, async: true
  alias HarnessForge.Graphiti.Protocol

  test "missing worker/job is explicit unavailability rather than a caller crash" do
    assert {:error, :worker_lost} = HarnessForge.Graphiti.status("job:missing")
  end

  test "a worker boot has explicit dependencies and cannot discover credentials or arbitrary backend" do
    boot = %{
      "source_lock_digest" => String.duplicate("1", 64),
      "backend_pin_digest" => String.duplicate("2", 64),
      "backend_uri" => "bolt://127.0.0.1:7687",
      "backend_user" => "synthetic",
      "backend_password" => "synthetic",
      "database" => "neo4j",
      "stage_pins" => [],
      "stage_set_digest" => elem(HarnessForge.Models.Stages.set_digest([]), 1)
    }

    assert :ok = Protocol.validate_payload("boot", boot)

    assert {:error, :invalid_dto} =
             Protocol.validate_payload(
               "boot",
               Map.put(boot, "backend_uri", "bolt://foreign.invalid:7687")
             )

    assert {:error, :invalid_dto} =
             Protocol.validate_payload("boot", Map.put(boot, "discover_credentials", true))
  end

  test "a removal result never supplies a purge clearance or an approval" do
    result = %{
      "job_id" => "job:synthetic",
      "state" => "completed",
      "generation" => 1,
      "closure_digest" => String.duplicate("1", 64),
      "receipt_count" => 1,
      "receipt_digest" => String.duplicate("2", 64),
      "result" => %{
        "cleanup_status" => "verification_required",
        "version_manifest_digest" => String.duplicate("3", 64)
      }
    }

    assert :ok = Protocol.validate_payload("result", result)

    assert {:error, :invalid_dto} =
             Protocol.validate_payload("result", put_in(result, ["result", "purged"], true))

    assert {:error, :invalid_dto} =
             Protocol.validate_payload(
               "result",
               put_in(result, ["result", "cleanup_status"], "purged")
             )
  end
end
