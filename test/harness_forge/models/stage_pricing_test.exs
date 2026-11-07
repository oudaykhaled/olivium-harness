defmodule HarnessForge.Models.StagePricingTest do
  use HarnessForge.DataCase, async: false
  alias HarnessForge.{Contracts, Models}
  alias HarnessForge.Models.{Ledger, StageAuthority, Stages}

  test "Jev zero output price persists without treating unpriced cloud as free" do
    pin = pin(42_000, 0)
    assert {:ok, _} = StageAuthority.create_pin(pin, owner())
    assert {:ok, ^pin} = StageAuthority.load_pin(pin["id"])

    for {input, output} <- [{0, 0}, {-1, 0}, {42_000, -1}] do
      assert {:error, _} = StageAuthority.create_pin(pin(input, output), owner())
    end

    assert {:error, _} =
             StageAuthority.create_pin(Map.put(pin(42_000, 0), "output_rate", 0.5), owner())

    local =
      pin(0, 0)
      |> Map.merge(%{
        "provider" => "ollama",
        "model" => "synthetic-fixture",
        "endpoint" => "http://127.0.0.1:11434/v1/chat/completions"
      })

    local = Map.put(local, "config_digest", Stages.fingerprint(local))
    assert {:ok, _} = StageAuthority.create_pin(local, owner())
  end

  test "zero output rate preserves ceiling costs, caps and unknown usage" do
    config = %{
      "provider" => "jev",
      "model" => "jev-pricing-fixture",
      "input_microusd_per_million" => 42_000,
      "output_microusd_per_million" => 0
    }

    assert Ledger.estimate(config, 1_000_000, 500_000) == 42_000
    assert Ledger.estimate(config, 1, 500_000) == 1
    assert {:ok, _} = Ledger.start_run("jev-no-spend", %{"max_estimated_microusd" => 0})
    assert {:error, :budget_exhausted} = Ledger.reserve(request("jev-no-spend", "1"), config, 1)
    assert {:ok, _} = Ledger.start_run("jev-price", %{"max_estimated_microusd" => 1})
    assert {:ok, reserved} = Ledger.reserve(request("jev-price", "1"), config, 1)

    assert {:ok, :reconciled} =
             Ledger.reconcile(reserved, {:ok, %{input_tokens: 1, output_tokens: 7}}, config)

    assert {:ok, [%{"billing_status" => "estimated"}]} = Models.list_requests("jev-price")
    assert {:error, :budget_exhausted} = Ledger.reserve(request("jev-price", "2"), config, 1)
    assert {:ok, _} = Ledger.start_run("jev-unknown", %{"max_estimated_microusd" => 1})
    assert {:ok, reserved} = Ledger.reserve(request("jev-unknown", "1"), config, 1)
    assert {:ok, before} = Ledger.budget("jev-unknown")

    assert {:ok, :uncertain} =
             Ledger.reconcile(reserved, {:ok, %{input_tokens: nil, output_tokens: nil}}, config)

    assert {:ok, after_budget} = Ledger.budget("jev-unknown")
    assert after_budget["reserved_tokens"] == before["reserved_tokens"]
    assert after_budget["reserved_estimated_microusd"] == before["reserved_estimated_microusd"]
  end

  defp request(run, id),
    do: %{
      "run_id" => run,
      "request_id" => id,
      "prompt" => "Synthetic pricing #{id}",
      "source_ids" => [],
      "data_categories" => [],
      "max_output_tokens" => 8
    }

  defp pin(input, output) do
    attrs = %{
      "id" => Ecto.UUID.generate(),
      "stage" => "node_dedupe",
      "provider" => "jev",
      "model" => "jev-pricing-fixture",
      "endpoint" => "https://api.typesafe.ai/v1/systemone",
      "route_id" => "jev-pricing",
      "credential_ref" => "HARNESSFORGE_TEST_JEV",
      "prompt_digest" => String.duplicate("1", 64),
      "schema_digest" => String.duplicate("2", 64),
      "consent_revision" => 1,
      "input_rate" => input,
      "output_rate" => output,
      "max_output_tokens" => 32,
      "timeout_ms" => 1000
    }

    Map.put(attrs, "config_digest", Stages.fingerprint(attrs))
  end

  defp owner,
    do: [
      authorize: fn -> true end,
      session_fingerprint: Contracts.sha256("synthetic price owner"),
      view_generation: String.duplicate("e", 32),
      reset_token: 0
    ]
end
