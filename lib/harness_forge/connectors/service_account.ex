defmodule HarnessForge.Connectors.ServiceAccount do
  @moduledoc "Verified account metadata authority, separate from selected source imports."
  @behaviour HarnessForge.Contracts.Connector
  alias HarnessForge.Connectors.Common, as: C

  @services ~w(github github_projects slack jira confluence)

  @impl true
  def validate_config(config) do
    if C.keys(config, ~w(service endpoint credential_ref username_ref identity last_verified_at)) and
         config["service"] in @services and required_reference?(config["credential_ref"]) and
         endpoint?(config) and username?(config) and
         identity?(config["identity"], config["service"]) and
         C.timestamp?(config["last_verified_at"]),
       do: {:ok, config},
       else: C.error("invalid_connector_config")
  end

  @doc false
  def input(attrs) do
    if C.keys(attrs, ~w(service endpoint credential_ref username_ref)) and
         attrs["service"] in @services and required_reference?(attrs["credential_ref"]) do
      config = default_endpoint(attrs)

      if endpoint?(config) and username?(config),
        do: {:ok, config},
        else: C.error("invalid_connector_config")
    else
      C.error("invalid_connector_config")
    end
  end

  @impl true
  def capabilities,
    do: %{"read_only" => true, "account_metadata" => true, "source_import" => false}

  @impl true
  def fetch_page(_, _, _), do: C.error("account_source_import_unsupported")

  defp default_endpoint(%{"service" => service} = attrs)
       when service in ~w(github github_projects),
       do: Map.put_new(attrs, "endpoint", "https://api.github.com")

  defp default_endpoint(%{"service" => "slack"} = attrs),
    do: Map.put_new(attrs, "endpoint", "https://slack.com")

  defp default_endpoint(attrs), do: attrs

  defp endpoint?(%{"service" => service, "endpoint" => endpoint})
       when service in ~w(github github_projects),
       do: endpoint == "https://api.github.com"

  defp endpoint?(%{"service" => "slack", "endpoint" => endpoint}),
    do: endpoint == "https://slack.com"

  defp endpoint?(%{"service" => service, "endpoint" => endpoint})
       when service in ~w(jira confluence),
       do: C.origin?(endpoint, &Regex.match?(~r/^[a-z0-9][a-z0-9-]{0,62}\.atlassian\.net$/, &1))

  defp endpoint?(_), do: false

  defp username?(%{"service" => service} = config) when service in ~w(jira confluence),
    do: required_reference?(config["username_ref"])

  defp username?(config), do: not Map.has_key?(config, "username_ref")
  defp required_reference?(value), do: is_binary(value) and C.reference?(value)

  defp identity?(%{"id" => id, "login" => login} = identity, service)
       when service in ~w(github github_projects),
       do:
         C.keys(identity, ~w(id login)) and C.database_id?(id) and
           text?(login, 100)

  defp identity?(%{"id" => id, "login" => login, "team_id" => team} = identity, "slack"),
    do:
      C.keys(identity, ~w(id login team_id)) and text?(id, 100) and text?(login, 100) and
        is_binary(team) and Regex.match?(~r/^T[A-Z0-9]{1,63}$/, team)

  defp identity?(%{"id" => id, "login" => login} = identity, service)
       when service in ~w(jira confluence),
       do: C.keys(identity, ~w(id login)) and text?(id, 256) and login == id

  defp identity?(_, _), do: false

  @doc false
  def text?(value, bound) when is_binary(value),
    do:
      byte_size(value) in 1..bound and String.valid?(value) and
        not Regex.match?(~r/[\x00-\x1f\x7f]/, value)

  def text?(_, _), do: false
end
