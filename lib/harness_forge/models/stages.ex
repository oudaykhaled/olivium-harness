defmodule HarnessForge.Models.Stages do
  @moduledoc "Immutable stage-pin validation. Persistence and consent belong to StageAuthority."
  alias HarnessForge.Contracts

  @keys ~w(id stage provider model endpoint route_id credential_ref config_digest prompt_digest schema_digest consent_revision input_rate output_rate max_output_tokens timeout_ms)
  @stages ~w(extraction summary node_dedupe edge_dedupe embedder reranker synthesis)
  @providers ~w(ollama openai openai_responses anthropic jev)

  def validate_pin(pin) when is_map(pin) and not is_struct(pin) do
    with true <- Enum.sort(Map.keys(pin)) == Enum.sort(@keys),
         true <- identifier?(pin["id"]) and identifier?(pin["route_id"]),
         true <- pin["stage"] in @stages and pin["provider"] in @providers,
         true <- model?(pin["model"]),
         true <- Enum.all?(~w(config_digest prompt_digest schema_digest), &digest?(pin[&1])),
         true <- Enum.all?(~w(consent_revision input_rate output_rate), &nonnegative?(pin[&1])),
         true <- integer_in?(pin["max_output_tokens"], 1, 4096),
         true <- integer_in?(pin["timeout_ms"], 1, 60_000),
         true <- credential_ref?(pin["credential_ref"]),
         :ok <- endpoint(pin),
         true <- pin["config_digest"] == fingerprint(pin) do
      {:ok, pin}
    else
      _ -> {:error, :invalid_stage_configuration}
    end
  rescue
    _ -> {:error, :invalid_stage_configuration}
  end

  def validate_pin(_), do: {:error, :invalid_stage_configuration}

  def fingerprint(pin), do: Contracts.digest(Map.delete(pin, "config_digest"))

  @doc "Identity of a complete immutable stage set; empty is diagnostic-only."
  def set_digest(pins) when is_list(pins) and length(pins) <= 7 do
    with true <- Enum.all?(pins, &match?({:ok, _}, validate_pin(&1))),
         true <- length(Enum.uniq_by(pins, & &1["id"])) == length(pins),
         true <- length(Enum.uniq_by(pins, & &1["stage"])) == length(pins) do
      {:ok, Contracts.digest(%{"v" => 1, "pins" => Enum.sort_by(pins, & &1["id"])})}
    else
      _ -> {:error, :invalid_stage_configuration}
    end
  end

  def set_digest(_), do: {:error, :invalid_stage_configuration}

  def identifier?(value),
    do: is_binary(value) and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,199}\z/, value)

  def digest?(value),
    do: is_binary(value) and Regex.match?(~r/\A[a-f0-9]{64}\z/, value)

  def integer_in?(value, lower, upper),
    do: is_integer(value) and value >= lower and value <= upper

  def nonnegative?(value), do: is_integer(value) and value >= 0

  defp model?(value),
    do:
      is_binary(value) and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._:\/-]{0,199}\z/, value) and
        not String.contains?(String.downcase(value), "latest")

  defp credential_ref?(nil), do: true

  defp credential_ref?(value),
    do: is_binary(value) and Regex.match?(~r/\AHARNESSFORGE_[A-Z0-9_]{1,100}\z/, value)

  defp endpoint(%{"endpoint" => endpoint, "provider" => provider}) when is_binary(endpoint) do
    uri = URI.parse(endpoint)
    clean = is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment)

    allowed =
      cond do
        provider == "ollama" ->
          uri.scheme == "http" and uri.host in ["127.0.0.1", "::1"] and
            uri.port in 1..65_535 and
            uri.path in ["/api/generate", "/v1/chat/completions", "/v1/embeddings"]

        provider == "jev" ->
          endpoint == "https://api.typesafe.ai/v1/systemone"

        provider in ["openai", "openai_responses"] ->
          uri.scheme == "https" and uri.host == "api.openai.com" and uri.port == 443 and
            uri.path in ["/v1/chat/completions", "/v1/embeddings", "/v1/responses"]

        provider == "anthropic" ->
          endpoint == "https://api.anthropic.com/v1/messages"

        true ->
          false
      end

    if clean and allowed, do: :ok, else: {:error, :unsafe_model_endpoint}
  end

  defp endpoint(_), do: {:error, :unsafe_model_endpoint}
end
