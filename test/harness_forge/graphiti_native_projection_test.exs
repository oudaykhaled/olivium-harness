defmodule HarnessForge.Graphiti.NativeProjectionTest do
  use ExUnit.Case, async: true
  alias HarnessForge.Contracts
  alias HarnessForge.Graphiti.NativeProjection

  test "closed loader projection removes only commitments and preserves every native field" do
    for type <- ~w(EntityNode EntityEdge) do
      full = snapshot(type)
      view = Map.put(full, "vector_commitments", %{})
      assert {:ok, ^view} = NativeProjection.project(full, "native_loader_no_vector_v1")
      assert :ok = NativeProjection.compare(full, view, "native_loader_no_vector_v1")

      assert {:ok, hash} =
               NativeProjection.projection_hash(
                 Contracts.canonical_json(full),
                 "native_loader_no_vector_v1"
               )

      assert hash == Contracts.digest(view)
      refute hash == Contracts.digest(full)
      assert {:ok, ^full} = NativeProjection.project(full, "identity_v1")

      for changed <- [
            put_in(view, ["fields", "name"], "changed"),
            put_in(view, ["fields", "created_at"], "changed"),
            Map.put(view, "fields", Map.delete(view["fields"], "name")),
            full
          ] do
        assert {:error, :closure_incomplete} =
                 NativeProjection.compare(full, changed, "native_loader_no_vector_v1")
      end
    end
  end

  test "unknown classes policies attributes vectors and noncanonical input deny" do
    full = snapshot("EntityNode")

    for value <- [
          nil,
          %{},
          Map.put(full, "object_type", "EpisodicNode"),
          put_in(full, ["fields", "attributes"], %{"unknown" => true}),
          Map.put(full, "vector_commitments", %{"unqualified_vector" => %{}}),
          Map.put(full, "extra", true)
        ] do
      assert {:error, :closure_incomplete} =
               NativeProjection.project(value, "native_loader_no_vector_v1")
    end

    assert {:error, :closure_incomplete} = NativeProjection.project(full, "arbitrary-selector")

    assert {:error, :closure_incomplete} =
             NativeProjection.projection_hash(
               " " <> Contracts.canonical_json(full),
               "native_loader_no_vector_v1"
             )
  end

  test "changed loader snapshots have a distinct validated wire identity" do
    value = snapshot("EntityNode") |> Map.put("vector_commitments", %{})
    object = "loader_view:EntityNode:" <> value["fields"]["uuid"]

    assert {:ok, {"deterministic_output", ^object, true}} =
             NativeProjection.view_identity(value, object)

    assert {:error, :closure_incomplete} =
             NativeProjection.view_identity(value, "EntityNode:" <> value["fields"]["uuid"])

    assert {:error, :closure_incomplete} =
             NativeProjection.view_identity(snapshot("EntityNode"), object)
  end

  defp snapshot(type) do
    key = if type == "EntityNode", do: "name_embedding", else: "fact_embedding"

    %{
      "object_type" => type,
      "fields" => %{
        "uuid" => Ecto.UUID.generate(),
        "group_id" => "public_garden",
        "name" => "Garden",
        "created_at" => "2026-01-01T00:00:00+00:00",
        "attributes" => %{}
      },
      "vector_commitments" => %{
        key => %{"dimension" => 2, "sha256" => Contracts.sha256("public vector")}
      }
    }
  end
end
