defmodule HarnessForge.Graphiti.CompletionCommitment do
  @moduledoc "Canonical graph completion commitment; no publication or execution authority."
  alias HarnessForge.Contracts
  alias HarnessForge.Evidence.Corpora
  alias HarnessForge.Graphiti.Protocol
  @error {:error, :closure_incomplete}

  def projection(payload) do
    with :ok <- Protocol.validate_payload("result", payload),
         true <- payload["state"] == "completed",
         {:ok, result} <- result_projection(payload["result"]),
         projected = %{
           "format" => "graph-completion-v1",
           "envelope" => Map.put(payload, "result", result)
         },
         _ <- Contracts.canonical_json(projected),
         do: {:ok, projected},
         else: (_ -> @error)
  rescue
    _ -> @error
  end

  def digest(payload) do
    with {:ok, projected} <- projection(payload), do: {:ok, Contracts.digest(projected)}
  end

  defp result_projection(%{"candidates" => candidates} = result) when map_size(result) == 1 do
    Enum.reduce_while(candidates, {:ok, []}, fn candidate, {:ok, accumulated} ->
      with true <-
             Corpora.uuid?(candidate["edge_id"]) and
               Enum.all?(candidate["episode_ids"], &Corpora.uuid?/1),
           {:ok, score} <- score(candidate["score"]) do
        {:cont, {:ok, [Map.put(candidate, "score", score) | accumulated]}}
      else
        _ -> {:halt, @error}
      end
    end)
    |> case do
      {:ok, projected} -> {:ok, %{"candidates" => Enum.reverse(projected)}}
      error -> error
    end
  end

  defp result_projection(%{"binding_id" => binding, "episode_uuid" => episode} = result)
       when map_size(result) == 2 do
    if Corpora.uuid?(binding) and Corpora.uuid?(episode), do: {:ok, result}, else: @error
  end

  defp result_projection(_), do: @error

  # The qualified adapter emits Python floats. Commit exact received binary64
  # bits, including negative zero. Integer/absent/nonfinite substitutes deny.
  defp score(value) when is_float(value) do
    bytes = <<value::float-big-64>>
    <<_sign::1, exponent::11, _fraction::52>> = bytes

    if exponent != 2047,
      do: {:ok, %{"format" => "ieee754-be-f64-v1", "bits" => Base.encode16(bytes, case: :lower)}},
      else: @error
  end

  defp score(_), do: @error
end
