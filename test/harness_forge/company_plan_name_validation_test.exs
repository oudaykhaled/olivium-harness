defmodule HarnessForge.CompanyPlanNameValidationTest do
  use ExUnit.Case, async: true

  alias HarnessForge.Company.Validation

  test "package names accept the exact 64-character lowercase slug boundary" do
    for name <- ["a", "checkout-harness_9", String.duplicate("a", 64)] do
      assert Validation.plan_name_valid?(name)
      assert {:ok, %{"name" => ^name}, nil} = Validation.plan(plan(name))
    end
  end

  test "invalid names fail without trimming, case-folding, or punctuation replacement" do
    for name <- [
          String.duplicate("a", 65),
          "checkout harness",
          "Checkout-harness",
          "checkout.harness",
          " checkout-harness",
          "checkout-harness ",
          "",
          " ",
          nil,
          false,
          42,
          []
        ] do
      refute Validation.plan_name_valid?(name)
      assert {:error, :invalid_input} = Validation.plan(plan(name))
    end
  end

  test "plan validation retains its existing error and payload contract for other fields" do
    assert {:ok, payload, nil} = Validation.plan(plan("checkout-harness"))
    assert payload["name"] == "checkout-harness"
    assert payload["execution"] == %{"max_turns" => 12, "timeout_seconds" => 600}

    assert {:error, :invalid_input} =
             plan("checkout-harness")
             |> Map.put("package_version", "release")
             |> Validation.plan()
  end

  defp plan(name) do
    %{
      "name" => name,
      "package_version" => "0.1.0",
      "project_id" => "10000000-0000-4000-8000-000000000001",
      "repository_ids" => ["20000000-0000-4000-8000-000000000002"],
      "claim_refs" => [
        %{
          "id" => "30000000-0000-4000-8000-000000000003",
          "revision_hash" => String.duplicate("a", 64)
        }
      ],
      "goal_ids" => ["40000000-0000-4000-8000-000000000004"],
      "template_ids" => ["reviewed-change-v1"],
      "runtime" => "opencode",
      "runtime_version" => "unqualified",
      "execution" => %{"max_turns" => 12, "timeout_seconds" => 600},
      "milestones" => []
    }
  end
end
