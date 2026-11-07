defmodule HarnessForge.Models.Anthropic do
  @moduledoc "Optional Claude Messages adapter with constrained JSON output and no tools."
  @behaviour HarnessForge.Models.Provider
  alias HarnessForge.Models.{HTTP, Profile}

  @api_version "2026-10-21"

  @impl true
  def generate(config, request, credential, opts) do
    body = %{
      "model" => config["model"],
      "max_tokens" => request["max_output_tokens"],
      "stream" => false,
      "system" => Profile.system(request),
      "messages" => [%{"role" => "user", "content" => request["prompt"]}],
      "output_config" => %{
        "format" => %{
          "type" => "json_schema",
          "schema" => Profile.wire_schema(request, "anthropic")
        }
      }
    }

    with {:ok, value} <-
           HTTP.request(
             :post,
             config["endpoint"] <> "/messages",
             body,
             [{"x-api-key", credential}, {"anthropic-version", @api_version}],
             opts
           ),
         true <-
           value["type"] == "message" and value["role"] == "assistant" and
             value["stop_reason"] == "end_turn",
         {:ok, text} <- output_text(value["content"]) do
      usage = if is_map(value["usage"]), do: value["usage"], else: %{}

      {:ok,
       %{text: text, input_tokens: input_tokens(usage), output_tokens: usage["output_tokens"]}}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_provider_response}
    end
  end

  defp output_text(blocks) when is_list(blocks) and length(blocks) in 1..16 do
    if Enum.all?(blocks, &match?(%{"type" => "text", "text" => text} when is_binary(text), &1)) do
      {:ok, Enum.map_join(blocks, "", & &1["text"])}
    else
      {:error, :invalid_provider_response}
    end
  end

  defp output_text(_), do: {:error, :invalid_provider_response}

  defp input_tokens(usage) do
    counts = [
      usage["input_tokens"],
      Map.get(usage, "cache_read_input_tokens", 0),
      Map.get(usage, "cache_creation_input_tokens", 0)
    ]

    if Enum.all?(counts, &(is_integer(&1) and &1 >= 0)), do: Enum.sum(counts), else: nil
  end
end
