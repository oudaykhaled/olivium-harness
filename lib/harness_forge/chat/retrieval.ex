defmodule HarnessForge.Chat.Retrieval do
  @moduledoc false
  alias HarnessForge.Evidence
  alias HarnessForge.Chat.Snapshot

  @context_bytes 24_576
  @stopwords ~w(a an and are as at be by can could do does for from had has have how i in is it its me my of on or please should show tell that the their them there these they this to us was we were what when where which who why will with would you your)
  @broadwords ~w(all available captured connected connectors connection evidence overview sources summarize summary)

  def retrieve(question, history, allowed_ids) do
    tokens = tokens(question)

    with :ok <- context_size(question, history),
         {:ok, candidates} <- candidates(tokens, allowed_ids),
         sources =
           candidates
           |> Enum.filter(&(Snapshot.eligible?(&1) and allowed?(&1, allowed_ids)))
           |> Enum.uniq_by(& &1["id"])
           |> Enum.sort_by(&{-score(&1, tokens), &1["provider"], &1["id"]}),
         {:ok, citations} <- excerpts(sources, question, history, tokens) do
      {:ok, citations, prompt(question, history, citations)}
    end
  end

  defp context_size(question, history) do
    if byte_size(prompt(question, history, [])) <= @context_bytes - 2048,
      do: :ok,
      else: {:error, :chat_context_too_large}
  end

  # Cloud retrieval reads only explicitly consented source IDs, even before the
  # prompt is assembled. Consent is never broadened by a search match.
  defp candidates(tokens, ids) when is_list(ids) do
    sources =
      Enum.flat_map(ids, fn id ->
        case Evidence.get_source(id) do
          {:ok, source} -> if matches?(source, tokens), do: [source], else: []
          _ -> []
        end
      end)

    {:ok, sources}
  end

  defp candidates([], :all), do: Evidence.list_sources()

  defp candidates(tokens, :all) do
    Enum.reduce_while(tokens, {:ok, []}, fn token, {:ok, acc} ->
      case Evidence.search(token) do
        {:ok, sources} -> {:cont, {:ok, acc ++ sources}}
        error -> {:halt, error}
      end
    end)
  end

  defp matches?(source, tokens) do
    Snapshot.eligible?(source) and (tokens == [] or score(source, tokens) > 0)
  end

  defp tokens(question) do
    question
    |> String.downcase()
    |> then(&Regex.scan(~r/[\p{L}\p{N}_]{2,}/u, &1))
    |> List.flatten()
    |> Enum.reject(&(&1 in @stopwords or &1 in @broadwords))
    |> Enum.uniq()
    |> Enum.take(8)
    |> Enum.flat_map(&alternatives/1)
    |> Enum.uniq()
    |> Enum.take(16)
  end

  # Literal FTS alternatives make ordinary "testing rules" questions find
  # "tests"/"rule" without pretending this is semantic/vector retrieval.
  defp alternatives(token) do
    cond do
      String.ends_with?(token, "ing") and String.length(token) > 5 ->
        base = String.replace_suffix(token, "ing", "")
        [token, base, base <> "s"]

      String.ends_with?(token, "s") and not String.ends_with?(token, "ss") and
          String.length(token) > 3 ->
        [token, String.replace_suffix(token, "s", "")]

      String.ends_with?(token, "ed") and String.length(token) > 5 ->
        base = String.replace_suffix(token, "ed", "")
        [token, base, base <> "e"]

      true ->
        [token, token <> "s"]
    end
  end

  defp score(source, tokens) do
    title = String.downcase(source["title"])
    body = String.downcase(source["latest_revision"]["body"])

    Enum.reduce(tokens, 0, fn token, total ->
      total + if(String.contains?(title, token), do: 4, else: 0) +
        if(String.contains?(body, token), do: 1, else: 0)
    end)
  end

  defp allowed?(_, :all), do: true
  defp allowed?(source, ids), do: source["id"] in ids

  defp excerpts(sources, question, history, tokens) do
    result =
      Enum.reduce_while(sources, [], fn source, acc ->
        citation = excerpt(source, length(acc) + 1, tokens)
        next = acc ++ [citation]

        cond do
          length(acc) == 12 -> {:halt, acc}
          citation["snippet"] == "" -> {:cont, acc}
          byte_size(prompt(question, history, next)) > @context_bytes -> {:halt, acc}
          true -> {:cont, next}
        end
      end)

    {:ok, result}
  end

  defp excerpt(source, index, tokens) do
    body = source["latest_revision"]["body"]
    start = max(first_match(body, tokens) - 256, 0) |> start_boundary(body)
    snippet = body |> binary_part(start, byte_size(body) - start) |> Snapshot.truncate(1536)

    source
    |> Snapshot.source_ref()
    |> Map.merge(%{
      "id" => "E#{index}",
      "start_byte" => start,
      "end_byte" => start + byte_size(snippet),
      "snippet" => snippet
    })
  end

  defp first_match(_, []), do: 0

  defp first_match(body, tokens) do
    expression = Enum.map_join(tokens, "|", &Regex.escape/1) |> Regex.compile!("iu")

    case Regex.run(expression, body, return: :index) do
      [{offset, _} | _] -> offset
      _ -> 0
    end
  end

  defp start_boundary(0, _), do: 0

  defp start_boundary(start, body) do
    if String.valid?(binary_part(body, 0, start)),
      do: start,
      else: start_boundary(start - 1, body)
  end

  defp prompt(question, history, citations) do
    Jason.encode!(%{
      "question" => question,
      "previous_user_questions" => history,
      "captured_evidence" =>
        Enum.map(citations, fn citation ->
          Map.take(citation, ~w(id provider title snippet))
        end)
    })
  end
end
