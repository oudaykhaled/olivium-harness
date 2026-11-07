defmodule HarnessForge.Models.OpenAIResponses do
  @moduledoc "Optional stateless OpenAI Responses adapter; tools and automatic retries are disabled."
  @behaviour HarnessForge.Models.Provider
  alias HarnessForge.Models.{HTTP, Profile}

  @impl true
  def generate(config, request, credential, opts) do
    body = %{
      "model" => config["model"],
      "store" => false,
      "stream" => false,
      "tools" => [],
      "tool_choice" => "none",
      "max_output_tokens" => request["max_output_tokens"],
      "instructions" => Profile.system(request),
      "input" => [%{"role" => "user", "content" => request["prompt"]}],
      "text" => %{
        "format" => %{
          "type" => "json_schema",
          "name" => Profile.name(request),
          "strict" => true,
          "schema" => Profile.wire_schema(request, "openai_responses")
        }
      }
    }

    with {:ok, value} <-
           HTTP.request(
             :post,
             config["endpoint"] <> "/responses",
             body,
             [{"authorization", "Bearer " <> credential}],
             opts
           ),
         true <- value["status"] == "completed" and is_nil(value["incomplete_details"]),
         {:ok, text} <- output_text(value["output"]) do
      usage = if is_map(value["usage"]), do: value["usage"], else: %{}

      # output_tokens includes reasoning tokens; adding its details would double count.
      {:ok,
       %{text: text, input_tokens: usage["input_tokens"], output_tokens: usage["output_tokens"]}}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_provider_response}
    end
  end

  defp output_text(items) when is_list(items) and length(items) in 1..16 do
    Enum.reduce_while(items, {:ok, []}, fn
      %{"type" => "reasoning"}, acc ->
        {:cont, acc}

      %{"type" => "message", "role" => "assistant", "status" => "completed", "content" => content},
      {:ok, acc}
      when is_list(content) and length(content) in 1..16 ->
        case text_blocks(content) do
          {:ok, text} -> {:cont, {:ok, [text | acc]}}
          error -> {:halt, error}
        end

      _, _ ->
        {:halt, {:error, :invalid_provider_response}}
    end)
    |> case do
      {:ok, [_ | _] = texts} -> {:ok, texts |> Enum.reverse() |> Enum.join("")}
      _ -> {:error, :invalid_provider_response}
    end
  end

  defp output_text(_), do: {:error, :invalid_provider_response}

  defp text_blocks(blocks) do
    if Enum.all?(
         blocks,
         &match?(%{"type" => "output_text", "text" => text} when is_binary(text), &1)
       ) do
      {:ok, Enum.map_join(blocks, "", & &1["text"])}
    else
      {:error, :invalid_provider_response}
    end
  end
end
