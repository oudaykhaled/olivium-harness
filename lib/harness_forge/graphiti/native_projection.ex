defmodule HarnessForge.Graphiti.NativeProjection do
  @moduledoc "Closed native loader views; this pure module grants no method or scope authority."
  alias HarnessForge.Contracts
  alias HarnessForge.Evidence.Corpora
  @error {:error, :closure_incomplete}

  def project(value, "identity_v1"), do: bounded(value)

  def project(value, "native_loader_no_vector_v1") do
    with true <-
           is_map(value) and
             Enum.sort(Map.keys(value)) == ~w(fields object_type vector_commitments),
         true <- value["object_type"] in ~w(EntityNode EntityEdge),
         true <- is_map(value["fields"]) and is_map(value["vector_commitments"]),
         true <- Corpora.uuid?(value["fields"]["uuid"]) and value["fields"]["attributes"] == %{},
         allowed =
           if(value["object_type"] == "EntityNode", do: "name_embedding", else: "fact_embedding"),
         true <- Enum.all?(Map.keys(value["vector_commitments"]), &(&1 == allowed)),
         do: bounded(Map.put(value, "vector_commitments", %{})),
         else: (_ -> @error)
  rescue
    _ -> @error
  end

  def project(_, _), do: @error

  def projection_hash(json, policy) when is_binary(json) and byte_size(json) <= 98_304 do
    with {:ok, value} <- Contracts.decode_json(json),
         true <- Contracts.canonical_json(value) == json,
         {:ok, view} <- project(value, policy),
         do: {:ok, Contracts.digest(view)},
         else: (_ -> @error)
  end

  def projection_hash(_, _), do: @error

  def compare(full, view, policy) do
    with {:ok, projected} <- project(full, policy),
         true <- projected == view,
         do: :ok,
         else: (_ -> @error)
  end

  def view_identity(value, object) do
    with {:ok, ^value} <- project(value, "native_loader_no_vector_v1"),
         expected = "loader_view:" <> value["object_type"] <> ":" <> value["fields"]["uuid"],
         true <- object == expected,
         do: {:ok, {"deterministic_output", expected, true}},
         else: (_ -> @error)
  rescue
    _ -> @error
  end

  defp bounded(value) do
    if byte_size(Contracts.canonical_json(value)) <= 98_304, do: {:ok, value}, else: @error
  rescue
    _ -> @error
  end
end
