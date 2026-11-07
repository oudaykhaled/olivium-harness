defmodule HarnessForge.Graphiti.BootTest do
  use ExUnit.Case, async: true
  alias HarnessForge.{Contracts, Graphiti.Worker, Models.Stages}

  defp boot do
    %{
      "source_lock_digest" => String.duplicate("1", 64),
      "backend_pin_digest" => String.duplicate("2", 64),
      "backend_uri" => "bolt://127.0.0.1:7687",
      "backend_user" => "synthetic-user",
      "backend_password" => "synthetic-password",
      "database" => "neo4j",
      "stage_pins" => [],
      "stage_set_digest" => elem(Stages.set_digest([]), 1)
    }
  end

  defp expected do
    value = boot()

    %{
      "session_id" => "session:synthetic",
      "boot_digest" => Contracts.digest(value),
      "source_lock_digest" => value["source_lock_digest"],
      "backend_pin_digest" => value["backend_pin_digest"],
      "stage_set_digest" => value["stage_set_digest"]
    }
  end

  defp result(request \\ "boot:synthetic") do
    meta = expected()

    %{
      "job_id" => request,
      "state" => "completed",
      "generation" => 0,
      "closure_digest" => meta["stage_set_digest"],
      "receipt_count" => 0,
      "receipt_digest" => Contracts.digest([]),
      "result" => %{
        "version" => "0.31.2",
        "source_lock_digest" => meta["source_lock_digest"],
        "backend_pin_digest" => meta["backend_pin_digest"],
        "readiness" => "configured"
      }
    }
  end

  test "only the exact boot metadata and completed empty-receipt acknowledgement validate" do
    assert :ok = Worker.validate_boot_result(expected(), "boot:synthetic", result())

    for changed <- [
          Map.put(result(), "state", "unavailable"),
          Map.put(result(), "generation", 1),
          Map.put(result(), "generation", 0.0),
          Map.put(result(), "receipt_count", 1),
          Map.put(result(), "receipt_digest", Contracts.digest(["receipt:foreign"])),
          Map.put(result(), "closure_digest", String.duplicate("9", 64)),
          put_in(result(), ["result", "version"], "0.31.1"),
          put_in(result(), ["result", "source_lock_digest"], String.duplicate("8", 64)),
          put_in(result(), ["result", "backend_pin_digest"], String.duplicate("7", 64)),
          put_in(result(), ["result", "readiness"], "stage_unavailable"),
          put_in(result(), ["result", "backend_password"], "forged"),
          Map.put(result(), "extra", true)
        ] do
      assert {:error, :stage_unavailable} =
               Worker.validate_boot_result(expected(), "boot:synthetic", changed)
    end
  end

  test "a previous boot nonce cannot acknowledge a fresh pending boot" do
    assert {:error, :stage_unavailable} =
             Worker.validate_boot_result(expected(), "boot:new", result("boot:old"))

    assert {:error, :stage_unavailable} =
             Worker.validate_boot_result(
               expected(),
               "boot:synthetic",
               Map.put(result(), "job_id", "job:foreign")
             )

    assert {:error, :stage_unavailable} = Worker.validate_boot_result(expected(), "", result())
  end

  test "body-free identity is available only after ready and contains the complete expected boot digest" do
    meta = expected()

    state = %{
      ready: true,
      boot_identity: meta,
      jobs: %{body: "synthetic-sensitive-job"},
      contexts: %{body: "synthetic-sensitive-context"},
      authority: "synthetic-private-authority"
    }

    assert {:reply, {:ok, ^meta}, ^state} = Worker.handle_call(:identity, nil, state)

    assert Enum.sort(Map.keys(meta)) ==
             Enum.sort(
               ~w(session_id boot_digest source_lock_digest backend_pin_digest stage_set_digest)
             )

    assert meta["boot_digest"] == Contracts.digest(boot())
    assert meta["boot_digest"] != Contracts.digest(Map.delete(boot(), "backend_password"))
    refute inspect(meta) =~ "synthetic-password"

    pending = %{state | ready: false}

    assert {:reply, {:error, :stage_unavailable}, ^pending} =
             Worker.handle_call(:identity, nil, pending)

    malformed = %{state | boot_identity: Map.put(meta, "backend_password", "synthetic-password")}

    assert {:reply, {:error, :stage_unavailable}, ^malformed} =
             Worker.handle_call(:identity, nil, malformed)
  end

  test "malformed expected metadata and arbitrary result shapes fail closed" do
    for meta <- [
          nil,
          %{},
          Map.delete(expected(), "boot_digest"),
          Map.put(expected(), "stage_set_digest", "invalid"),
          Map.put(expected(), "session_id", "invalid session")
        ] do
      assert {:error, :stage_unavailable} =
               Worker.validate_boot_result(meta, "boot:synthetic", result())
    end

    for value <- [nil, [], %{}, %{"state" => "completed"}] do
      assert {:error, :stage_unavailable} =
               Worker.validate_boot_result(expected(), "boot:synthetic", value)
    end
  end

  test "GenServer status and crash formatting redact state messages reasons and debug logs" do
    secret = "synthetic-sensitive-body-and-authority"

    formatted =
      Worker.format_status(%{
        state: %{jobs: secret, contexts: secret, tasks: secret},
        message: {:submit, secret, secret},
        reason: {:error, secret},
        log: [{:in, secret}]
      })

    assert formatted == %{state: :redacted, message: :redacted, reason: :redacted, log: []}
    refute inspect(formatted) =~ secret
  end
end
