defmodule HarnessForge.ContractsTest do
  use ExUnit.Case, async: true
  alias HarnessForge.Contracts

  defp fixture do
    Path.expand("../../examples/synthetic_company/harness.json", __DIR__)
    |> File.read!()
    |> Jason.decode!()
  end

  test "synthetic harness validates and its citation matches exact UTF-8 bytes" do
    value = fixture()
    assert {:ok, ^value} = Contracts.validate_harness(value)
    citation = hd(hd(value["spec"]["rules"])["evidence"])
    bytes = File.read!(Path.expand("../../examples/synthetic_company/handbook.md", __DIR__))

    snippet =
      binary_part(bytes, citation["start_byte"], citation["end_byte"] - citation["start_byte"])

    assert Contracts.sha256(snippet) == citation["snippet_hash"]
  end

  test "unknown fields, zero budgets, fabricated goal links and empty ranges fail" do
    value = fixture()

    bad_values = [
      Map.put(value, "approve", true),
      put_in(value, ["spec", "execution", "max_turns"], 0),
      update_in(value, ["spec", "rules"], fn [rule] ->
        [Map.put(rule, "goal_id", Ecto.UUID.generate())]
      end),
      update_in(value, ["spec", "rules"], fn [rule] ->
        [update_in(rule, ["evidence"], fn [c] -> [Map.put(c, "end_byte", c["start_byte"])] end)]
      end)
    ]

    for bad <- bad_values,
        do:
          assert(
            {:error, %Contracts.Error{code: "invalid_harness"}} = Contracts.validate_harness(bad)
          )
  end

  test "canonical hashing sorts keys and rejects non-interchange values" do
    assert Contracts.canonical_json(%{"b" => 1, "a" => [true, nil, "世界"]}) ==
             ~s({"a":[true,null,"世界"],"b":1})

    assert Contracts.digest(%{"a" => 1, "b" => 2}) == Contracts.digest(%{"b" => 2, "a" => 1})
    assert_raise ArgumentError, fn -> Contracts.canonical_json(%{atom: 1}) end
    assert_raise ArgumentError, fn -> Contracts.canonical_json(%{"float" => 1.2}) end
  end

  test "decoding rejects duplicate keys, oversized and deeply nested inputs" do
    assert {:ok, _} = fixture() |> Jason.encode!() |> Contracts.decode_harness()
    assert {:error, _} = Contracts.decode_harness(~s({"kind":"Harness","kind":"Harness"}))

    assert {:error, _} =
             Contracts.decode_harness(String.duplicate("[", 17) <> String.duplicate("]", 17))

    assert {:error, _} = Contracts.decode_harness(String.duplicate(" ", 2_000_001))
    assert {:error, _} = Contracts.validate_harness(%{untrusted_atom: true})
  end

  test "goals require owner and acceptance, and duplicate rule identities fail" do
    value = fixture()

    assert {:error, _} =
             Contracts.validate_harness(
               put_in(value, ["spec", "goals"], [%{"id" => Ecto.UUID.generate()}])
             )

    assert {:error, _} =
             Contracts.validate_harness(update_in(value, ["spec", "rules"], &(&1 ++ &1)))
  end
end
