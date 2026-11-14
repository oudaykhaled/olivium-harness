defmodule HarnessForge.Analyzers.Signal do
  @moduledoc """
  Builds entries of the repository signals document. Confidence is clamped to
  0..100 and the bucket follows from it, so a detector cannot mislabel a signal.
  """

  alias HarnessForge.Contracts.Signals

  @spec new(String.t(), term(), integer(), String.t(), [map()]) :: map()
  def new(key, value, confidence, detector, evidence \\ []) do
    confidence = confidence |> max(0) |> min(100)

    %{
      "key" => key,
      "value" => value,
      "confidence" => confidence,
      "bucket" => Signals.bucket(confidence),
      "detector" => detector,
      "evidence" => Enum.take(evidence, 32)
    }
  end

  @doc "Evidence pointing to a file, and optionally a line, in the repository."
  @spec file(String.t(), pos_integer() | nil) :: map()
  def file(path, line \\ nil)
  def file(path, nil), do: %{"kind" => "file", "path" => path}
  def file(path, line), do: %{"kind" => "file", "path" => path, "line" => line}

  @doc "Evidence naming up to ten commits."
  @spec commits([String.t()]) :: map()
  def commits(hashes), do: %{"kind" => "commit", "commits" => Enum.take(hashes, 10)}

  @doc "A rate as a whole percentage. Canonical JSON refuses floats."
  @spec percent(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def percent(_part, 0), do: 0
  def percent(part, whole), do: div(part * 100 + div(whole, 2), whole)
end
