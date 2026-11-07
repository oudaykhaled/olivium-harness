defmodule HarnessForge.Models.Configuration do
  @moduledoc false
  alias HarnessForge.{Repo, Workspaces, Audit}
  alias HarnessForge.Models.Settings
  alias HarnessForge.Evidence.Store

  @default %{
    "provider" => "ollama",
    "endpoint" => "http://127.0.0.1:11434",
    "model" => nil,
    "cloud_consent" => nil,
    "credential_env" => nil,
    "input_microusd_per_million" => 0,
    "output_microusd_per_million" => 0
  }
  @keys Map.keys(@default)
  @cloud_providers ~w(openai openai_responses anthropic)

  def cloud_provider?(provider), do: provider in @cloud_providers

  @doc "Identity of normalized settings, including consent and credential reference, never a credential value."
  def fingerprint(config),
    do: HarnessForge.Contracts.digest(Map.merge(@default, Map.take(config, @keys)))

  def expect_fingerprint(expected) do
    if is_binary(expected) and fingerprint(get()) == expected,
      do: :ok,
      else: {:error, :model_configuration_changed}
  end

  def get do
    case Repo.get(Settings, Workspaces.current_id()) do
      nil -> @default
      record -> Map.merge(@default, record.settings)
    end
  end

  def configure(attrs) when is_map(attrs) do
    with :ok <- Workspaces.ensure_writable(),
         true <- Map.keys(attrs) -- @keys == [],
         config = Map.merge(@default, attrs),
         {:ok, endpoint} <- endpoint(config["provider"], config["endpoint"]),
         true <- valid_model?(config["model"]),
         true <- valid_credential?(config["credential_env"]),
         true <- valid_rate?(config["input_microusd_per_million"]),
         true <- valid_rate?(config["output_microusd_per_million"]),
         config = Map.put(config, "endpoint", endpoint),
         :ok <- consent(config) do
      Store.transaction(fn ->
        changeset =
          Ecto.Changeset.change(%Settings{workspace_id: Workspaces.current_id()},
            settings: config
          )

        with {:ok, _} <-
               Repo.insert(changeset,
                 on_conflict: {:replace, [:settings, :updated_at]},
                 conflict_target: :workspace_id
               ),
             {:ok, _} <- Audit.append("model.configured", %{"status" => config["provider"]}) do
          {:ok, config}
        end
      end)
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_model_configuration}
    end
  end

  def configure(_), do: {:error, :invalid_model_configuration}

  # Resolve localhost to a numeric loopback address, avoiding DNS/proxy ambiguity.
  def endpoint("ollama", value) when is_binary(value) do
    uri = URI.parse(value)

    if uri.scheme == "http" and uri.host in ["localhost", "127.0.0.1", "::1"] and
         is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) and
         uri.path in [nil, "", "/"] and uri.port in 1..65_535 do
      host = if uri.host == "::1", do: "[::1]", else: "127.0.0.1"
      {:ok, "http://#{host}:#{uri.port}"}
    else
      {:error, :unsafe_model_endpoint}
    end
  end

  def endpoint("openai", "https://api.openai.com/v1"), do: {:ok, "https://api.openai.com/v1"}

  def endpoint("openai_responses", "https://api.openai.com/v1"),
    do: {:ok, "https://api.openai.com/v1"}

  def endpoint("anthropic", "https://api.anthropic.com/v1"),
    do: {:ok, "https://api.anthropic.com/v1"}

  def endpoint(_, _), do: {:error, :unsafe_model_endpoint}

  def authorize(%{"provider" => "ollama"} = config, _request) do
    if String.contains?(String.downcase(config["model"] || ""), "cloud"),
      do: {:error, :cloud_model_denied},
      else: :ok
  end

  def authorize(%{"provider" => provider, "cloud_consent" => consent} = config, request)
      when provider in @cloud_providers and is_map(consent) do
    if consent(config) == :ok and
         endpoint(provider, config["endpoint"]) == {:ok, config["endpoint"]} and
         request["source_ids"] != [] and request["data_categories"] != [] and
         Enum.all?(request["source_ids"], &(&1 in consent["source_ids"])) and
         Enum.all?(request["data_categories"], &(&1 in consent["data_categories"])),
       do: :ok,
       else: {:error, :cloud_consent_required}
  end

  def authorize(_, _), do: {:error, :cloud_consent_required}

  @doc false
  def authorize_stage(pin, consent_id, manifest) do
    HarnessForge.Models.StageAuthority.authorize_consent(pin, consent_id, manifest)
  end

  def credential(%{"provider" => "ollama"}), do: {:ok, nil}

  def credential(%{"credential_env" => env}) when is_binary(env) do
    with true <- valid_credential?(env),
         value when is_binary(value) and byte_size(value) in 1..16_384 <- System.get_env(env),
         true <- String.valid?(value) and not String.contains?(value, ["\r", "\n", <<0>>]) do
      {:ok, value}
    else
      _ -> {:error, :credential_unavailable}
    end
  end

  def credential(_), do: {:error, :credential_unavailable}

  defp consent(%{"provider" => "ollama", "cloud_consent" => nil}), do: :ok

  defp consent(%{"provider" => provider, "cloud_consent" => nil})
       when provider in @cloud_providers,
       do: :ok

  defp consent(%{"provider" => provider, "endpoint" => endpoint, "cloud_consent" => c})
       when provider in @cloud_providers and is_map(c) do
    if Enum.sort(Map.keys(c)) == Enum.sort(~w(provider endpoint source_ids data_categories)) and
         c["provider"] == provider and c["endpoint"] == endpoint and
         strings?(c["source_ids"]) and c["source_ids"] != [] and
         strings?(c["data_categories"]) and c["data_categories"] != [],
       do: :ok,
       else: {:error, :invalid_cloud_consent}
  end

  defp consent(_), do: {:error, :invalid_cloud_consent}

  def strings?(values),
    do:
      is_list(values) and length(values) <= 100 and
        Enum.all?(values, &(is_binary(&1) and byte_size(&1) in 1..200))

  defp valid_model?(nil), do: true

  defp valid_model?(value),
    do: is_binary(value) and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._:\/-]{0,199}\z/, value)

  defp valid_credential?(nil), do: true

  defp valid_credential?(value),
    do: is_binary(value) and Regex.match?(~r/\AHARNESSFORGE_[A-Z0-9_]{1,100}\z/, value)

  defp valid_rate?(value), do: is_integer(value) and value in 0..1_000_000_000_000
end
