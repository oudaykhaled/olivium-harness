defmodule HarnessForge.Models.LocalModelIdentity do
  @moduledoc """
  Metadata-only pinning for the qualified native Ollama Responses service.

  A loopback service remains a trusted operator dependency. These observations
  detect service/model drift; they do not prove model quality or local execution.
  No generation, model pull, credentials, redirects or cloud fallback occur here.
  """
  alias HarnessForge.Models.{Configuration, HTTP}
  @service_version "0.40.14"

  def observe(config, opts \\ []) do
    deadline = min(Keyword.get(opts, :deadline_ms, now_ms() + 2_000), now_ms() + 2_000)
    opts = Keyword.put(opts, :deadline_ms, deadline)

    with :ok <- current(opts),
         %{"provider" => "ollama", "model" => model, "endpoint" => endpoint} <- config,
         true <- is_binary(model) and not String.contains?(String.downcase(model), "cloud"),
         {:ok, ^endpoint} <- Configuration.endpoint("ollama", endpoint),
         {:ok, %{"version" => @service_version}} <-
           HTTP.request_metadata(:get, endpoint <> "/api/version", nil, opts),
         :ok <- current(opts),
         {:ok, %{"models" => models}} when is_list(models) and length(models) <= 1024 <-
           HTTP.request_metadata(:get, endpoint <> "/api/tags", nil, opts),
         :ok <- current(opts),
         [selected] <- Enum.filter(models, &(&1["name"] == model or &1["model"] == model)),
         true <- local_metadata?(selected),
         digest when is_binary(digest) <- selected["digest"],
         true <- Regex.match?(~r/\A[0-9a-f]{64}\z/, digest),
         {:ok, shown} <-
           HTTP.request_metadata(
             :post,
             endpoint <> "/api/show",
             %{"model" => model},
             opts
           ),
         :ok <- current(opts),
         true <- local_metadata?(shown),
         capabilities when is_list(capabilities) <- shown["capabilities"],
         true <- "tools" in capabilities and Enum.all?(capabilities, &is_binary/1) do
      {:ok,
       %{
         "version" => @service_version,
         "model" => model,
         "digest" => digest,
         "endpoint" => endpoint,
         "capabilities" => Enum.sort(Enum.uniq(capabilities))
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :local_model_identity_unavailable}
    end
  rescue
    _ -> {:error, :local_model_identity_unavailable}
  end

  def revalidate(config, expected, opts \\ []) when is_map(expected) do
    case observe(config, opts) do
      {:ok, ^expected} -> :ok
      {:ok, _} -> {:error, :local_model_identity_changed}
      error -> error
    end
  end

  defp current(opts) do
    with true <- now_ms() < Keyword.fetch!(opts, :deadline_ms),
         :ok <- guard(opts),
         true <- now_ms() < Keyword.fetch!(opts, :deadline_ms) do
      :ok
    else
      false -> {:error, :model_deadline_exceeded}
      error -> error
    end
  end

  defp guard(opts) do
    case Keyword.get(opts, :dispatch_guard) do
      nil -> :ok
      function when is_function(function, 0) -> function.()
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  # Remote identity can be reported in nested details/model metadata as well as
  # at the top level. Reject its presence, including an empty remote marker.
  defp local_metadata?(map) when is_map(map) do
    Enum.all?(map, fn {key, value} ->
      key not in ["remote_host", "remote_model", "remote_url", "cloud"] and
        local_metadata?(value)
    end)
  end

  defp local_metadata?(list) when is_list(list), do: Enum.all?(list, &local_metadata?/1)
  defp local_metadata?(_), do: true
end
