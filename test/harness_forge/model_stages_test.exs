defmodule HarnessForge.Models.StagesTest do
  use ExUnit.Case, async: true
  alias HarnessForge.Models.Stages

  defp pin do
    attrs = %{
      "id" => "stage:synthetic",
      "stage" => "synthesis",
      "provider" => "ollama",
      "model" => "synthetic-fixture-v1",
      "endpoint" => "http://127.0.0.1:11434/api/generate",
      "route_id" => "route:synthetic",
      "credential_ref" => nil,
      "prompt_digest" => String.duplicate("1", 64),
      "schema_digest" => String.duplicate("2", 64),
      "consent_revision" => 1,
      "input_rate" => 0,
      "output_rate" => 0,
      "max_output_tokens" => 4096,
      "timeout_ms" => 60000
    }

    Map.put(attrs, "config_digest", Stages.fingerprint(attrs))
  end

  test "exact immutable stage fingerprint validates without singleton mutation" do
    selected = pin()
    assert {:ok, ^selected} = Stages.validate_pin(selected)

    assert {:error, :invalid_stage_configuration} =
             Stages.validate_pin(Map.put(selected, "model", "different"))

    assert {:error, :invalid_stage_configuration} =
             Stages.validate_pin(Map.put(selected, "credential", "not-permitted"))
  end

  test "stage-set identity is sorted and rejects duplicate stage identity" do
    a = pin()
    b = a |> Map.put("id", "stage:other") |> Map.put("stage", "summary")
    b = Map.put(b, "config_digest", Stages.fingerprint(b))
    assert {:ok, first} = Stages.set_digest([a, b])
    assert {:ok, ^first} = Stages.set_digest([b, a])
    assert {:error, :invalid_stage_configuration} = Stages.set_digest([a, a])
    duplicate_stage = Map.put(a, "id", "stage:third")

    duplicate_stage =
      Map.put(duplicate_stage, "config_digest", Stages.fingerprint(duplicate_stage))

    assert {:error, :invalid_stage_configuration} = Stages.set_digest([a, duplicate_stage])
    assert {:ok, _} = Stages.set_digest([])
  end

  test "stage routes, aliases and token/timeout ceilings fail closed" do
    for {key, bad} <- [
          {"endpoint", "http://example.com/api/generate"},
          {"endpoint", "http://localhost:11434/api/generate"},
          {"model", "jev-latest"},
          {"timeout_ms", 60001},
          {"max_output_tokens", 4097},
          {"input_rate", true}
        ] do
      changed = pin() |> Map.put(key, bad)
      changed = Map.put(changed, "config_digest", Stages.fingerprint(changed))
      assert {:error, :invalid_stage_configuration} = Stages.validate_pin(changed)
    end
  end
end
