defmodule HarnessForge.Chat.Output do
  @moduledoc false

  def validate(bytes, citations) when is_binary(bytes) and byte_size(bytes) <= 32_768 do
    with {:ok, %Jason.OrderedObject{values: pairs}} <-
           Jason.decode(bytes, objects: :ordered_objects),
         true <- Enum.sort(Enum.map(pairs, &elem(&1, 0))) == ~w(answer citation_ids),
         value = Map.new(pairs),
         answer when is_binary(answer) <- value["answer"],
         true <- String.valid?(answer) and String.length(answer) in 1..8000,
         true <- String.trim(answer) != "",
         false <- String.contains?(answer, <<0>>),
         ids when is_list(ids) and length(ids) in 1..12 <- value["citation_ids"],
         true <- Enum.uniq(ids) == ids,
         available = Map.new(citations, &{&1["id"], &1}),
         true <- Enum.all?(ids, &valid_id?(&1, available)),
         true <- answer_references_valid?(answer, ids) do
      {:ok, answer, Enum.map(ids, &Map.fetch!(available, &1))}
    else
      _ -> {:error, :invalid_chat_output}
    end
  end

  def validate(_, _), do: {:error, :invalid_chat_output}

  defp valid_id?(id, available),
    do: is_binary(id) and byte_size(id) in 1..20 and Map.has_key?(available, id)

  defp answer_references_valid?(answer, ids),
    do: Regex.scan(~r/\bE[0-9]+\b/u, answer) |> List.flatten() |> Enum.all?(&(&1 in ids))
end
