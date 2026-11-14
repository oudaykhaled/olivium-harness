defmodule HarnessForge.Contracts.Signals do
  @moduledoc """
  The repository signals document (`priv/schemas/repository-signals-v1.json`).

  A signals document is a pure function of repository state. It holds no
  wall-clock time, absolute path, author name or email. Each signal's bucket is
  fixed by its confidence: `auto` >= 70, `suggested` 40 to 69, `observed` < 40.
  """

  alias HarnessForge.Contracts
  alias HarnessForge.Contracts.Error

  @schema_path Path.expand("../../../priv/schemas/repository-signals-v1.json", __DIR__)
  @external_resource @schema_path
  @schema @schema_path |> File.read!() |> Jason.decode!()
  @version "repository-signals-v1"

  @spec schema() :: map()
  def schema, do: @schema

  @spec version() :: String.t()
  def version, do: @version

  @doc "The bucket a confidence from 0 to 100 belongs to."
  @spec bucket(0..100) :: String.t()
  def bucket(confidence) when confidence in 70..100, do: "auto"
  def bucket(confidence) when confidence in 40..69, do: "suggested"
  def bucket(confidence) when confidence in 0..39, do: "observed"

  @spec validate(term()) :: {:ok, map()} | {:error, Error.t()}
  def validate(document) do
    with {:ok, document} <- Contracts.validate_document(document, @schema, "invalid_signals") do
      case semantic_errors(document["signals"]) do
        [] ->
          {:ok, document}

        errors ->
          {:error,
           %Error{
             code: "invalid_signals",
             message: "Document failed contract validation",
             details: Enum.take(Enum.sort(errors), 100)
           }}
      end
    end
  end

  defp semantic_errors(signals) do
    keys = Enum.map(signals, & &1["key"])

    duplicates =
      if length(Enum.uniq(keys)) == length(keys), do: [], else: ["$.signals: duplicate keys"]

    duplicates ++
      (signals
       |> Enum.with_index()
       |> Enum.flat_map(fn {signal, index} ->
         bucket =
           if signal["bucket"] == bucket(signal["confidence"]),
             do: [],
             else: ["$.signals[#{index}].bucket: does not match confidence"]

         paths =
           for item <- signal["evidence"],
               Map.has_key?(item, "path"),
               not Contracts.relative_path?(item["path"]),
               do: "$.signals[#{index}].evidence: path must be a contained relative path"

         bucket ++ paths
       end))
  end
end
