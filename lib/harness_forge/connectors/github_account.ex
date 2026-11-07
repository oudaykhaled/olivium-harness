defmodule HarnessForge.Connectors.GitHubAccount do
  @moduledoc """
  Live, read-only GitHub.com account and owned-repository metadata.

  This client does not import source content or invoke a model. Credentials are
  resolved from an environment reference only when an explicit request runs.
  """
  alias HarnessForge.Connectors.Common, as: C

  @endpoint "https://api.github.com"
  @version "2026-03-10"
  @repository_keys ~w(id full_name name html_url private stargazers_count updated_at)

  @spec validate_config(term()) :: {:ok, map()} | {:error, HarnessForge.Contracts.Error.t()}
  def validate_config(config) do
    if C.keys(config, ["credential_ref"]) and is_binary(config["credential_ref"]) and
         C.reference?(config["credential_ref"]),
       do: {:ok, config},
       else: C.error("invalid_connector_config")
  end

  @spec verify(term(), map()) :: {:ok, map()} | {:error, HarnessForge.Contracts.Error.t()}
  def verify(config, context \\ %{}) do
    with {:ok, config} <- validate_config(config),
         {:ok, credential} <- C.credential(config["credential_ref"], true),
         {:ok, identity} <- identity(headers(credential), context) do
      {:ok, %{"provider" => "github", "identity" => identity, "verified" => true}}
    end
  end

  @spec repositories(term(), map(), map()) ::
          {:ok, map()} | {:error, HarnessForge.Contracts.Error.t()}
  def repositories(config, opts \\ %{}, context \\ %{}) do
    with {:ok, config} <- validate_config(config),
         {:ok, limit} <- limit(opts),
         {:ok, credential} <- C.credential(config["credential_ref"], true),
         {:ok, identity} <- identity(headers(credential), context) do
      repositories_page(identity, limit, headers(credential), context)
    end
  end

  defp limit(opts) do
    value = if is_map(opts), do: Map.get(opts, "limit", 10)

    if C.keys(opts, ["limit"]) and is_integer(value) and value in 1..20,
      do: {:ok, value},
      else: C.error("invalid_account_query")
  end

  defp identity(headers, context) do
    with {:ok, body, _response} <- C.get(@endpoint <> "/user", %{}, headers, context),
         true <- is_map(body) and C.database_id?(body["id"]) and login?(body["login"]),
         true <- body["html_url"] == "https://github.com/" <> body["login"] do
      {:ok, Map.take(body, ["id", "login"])}
    else
      false -> C.error("invalid_provider_response")
      error -> error
    end
  end

  defp repositories_page(identity, limit, headers, context) do
    url = @endpoint <> "/user/repos"

    params = %{
      affiliation: "owner",
      visibility: "all",
      sort: "updated",
      direction: "desc",
      page: 1,
      per_page: limit
    }

    with {:ok, body, response} <- C.get(url, params, headers, context),
         {:ok, repositories} <- C.reduce_items(body, limit, &repository(&1, identity)),
         true <- ordered_unique?(repositories),
         {:ok, next_page} <- C.next_github(response, url, params, 1) do
      {:ok,
       %{
         "provider" => "github",
         "identity" => identity,
         "repositories" => repositories,
         "ordering" => "updated_desc",
         "scope" => "owner",
         "visibility" => "token_visible",
         "requested" => limit,
         "returned" => length(repositories),
         "has_more" => not is_nil(next_page),
         "complete" => is_nil(next_page)
       }}
    else
      false -> C.error("invalid_provider_response")
      error -> error
    end
  end

  defp repository(item, identity) when is_map(item) do
    with true <- C.database_id?(item["id"]) and repository_name?(item["name"]),
         %{"login" => owner_login, "id" => owner_id} <- item["owner"],
         true <-
           C.database_id?(owner_id) and owner_id == identity["id"] and
             same_login?(owner_login, identity["login"]),
         true <- is_binary(item["full_name"]),
         true <-
           String.downcase(item["full_name"]) ==
             String.downcase(owner_login <> "/" <> item["name"]),
         true <- item["html_url"] == "https://github.com/" <> item["full_name"],
         true <- is_boolean(item["private"]),
         true <-
           is_integer(item["stargazers_count"]) and item["stargazers_count"] >= 0 and
             item["stargazers_count"] <= 9_223_372_036_854_775_807,
         true <- timestamp?(item["updated_at"]) do
      {:ok, Map.take(item, @repository_keys)}
    else
      _ -> C.error("scope_violation")
    end
  end

  defp repository(_, _), do: C.error("invalid_provider_response")

  defp ordered_unique?(repositories) do
    ids = Enum.map(repositories, & &1["id"])

    length(Enum.uniq(ids)) == length(ids) and
      repositories
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.all?(fn [first, second] ->
        {:ok, first_at, _} = DateTime.from_iso8601(first["updated_at"])
        {:ok, second_at, _} = DateTime.from_iso8601(second["updated_at"])
        DateTime.compare(first_at, second_at) != :lt
      end)
  end

  defp login?(value) when is_binary(value),
    do: Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9-]{0,99}$/, value)

  defp login?(_), do: false

  defp same_login?(value, expected),
    do: login?(value) and String.downcase(value) == String.downcase(expected)

  defp repository_name?(value) when is_binary(value),
    do: value not in [".", ".."] and Regex.match?(~r/^[A-Za-z0-9_.-]{1,100}$/, value)

  defp repository_name?(_), do: false

  defp timestamp?(value) when is_binary(value),
    do: match?({:ok, _, _}, DateTime.from_iso8601(value))

  defp timestamp?(_), do: false

  defp headers(credential) do
    [
      {"accept", "application/vnd.github+json"},
      {"x-github-api-version", @version},
      {"authorization", "Bearer " <> credential}
    ]
  end
end
