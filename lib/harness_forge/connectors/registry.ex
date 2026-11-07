defmodule HarnessForge.Connectors.Registry do
  @moduledoc "Compiled-in read-only providers and their selected-source import boundary."
  alias HarnessForge.Connectors.{GitHub, Jira, GitHubProjects, Slack, Confluence}

  def adapter("github"), do: {:ok, GitHub}
  def adapter("jira"), do: {:ok, Jira}
  def adapter("github_projects"), do: {:ok, GitHubProjects}
  def adapter("slack"), do: {:ok, Slack}
  def adapter("confluence"), do: {:ok, Confluence}
  def adapter("service_account"), do: {:ok, HarnessForge.Connectors.ServiceAccount}
  def adapter(_), do: {:error, :provider_unavailable}

  def defaults(provider, config) when provider in ~w(github github_projects),
    do: Map.put_new(config, "endpoint", "https://api.github.com")

  def defaults("slack", config), do: Map.put_new(config, "endpoint", "https://slack.com")
  def defaults(_, config), do: config

  def document_scope(%{provider: "local"}, _), do: :ok

  def document_scope(connection, attrs) do
    metadata = attrs["metadata"]
    prefix = "#{connection.provider}:#{connection.id}:"

    if is_map(metadata) and is_binary(attrs["external_id"]) and
         String.starts_with?(attrs["external_id"], prefix) and
         selected?(connection.provider, connection.config, attrs, metadata, prefix),
       do: :ok,
       else: {:error, :scope_violation}
  rescue
    _ -> {:error, :scope_violation}
  end

  defp selected?("github", config, attrs, metadata, prefix) do
    root = "/" <> String.downcase(config["repository"])

    metadata["repository"] == config["repository"] and
      case secure_url(attrs["source_url"], "github.com") do
        %URI{path: path, query: nil, fragment: fragment} when is_binary(path) ->
          path = String.downcase(path)

          if metadata["kind"] == "review" do
            review = String.replace_prefix(attrs["external_id"], prefix <> "review:", "")

            is_integer(metadata["pull_number"]) and
              path == root <> "/pull/" <> to_string(metadata["pull_number"]) and
              Regex.match?(~r/\A[1-9][0-9]*\z/, review) and
              fragment == "pullrequestreview-" <> review
          else
            is_nil(fragment) and (path == root or String.starts_with?(path, root <> "/"))
          end

        _ ->
          false
      end
  end

  defp selected?("jira", config, attrs, metadata, _) do
    metadata["project"] == config["project"] and
      case secure_url(attrs["source_url"], URI.parse(config["endpoint"]).host) do
        %URI{path: path, query: nil, fragment: nil} when is_binary(path) ->
          Regex.match?(
            ~r/\A#{Regex.escape("/browse/" <> config["project"] <> "-")}[1-9][0-9]*\z/,
            path
          )

        _ ->
          false
      end
  end

  defp selected?("github_projects", config, attrs, metadata, prefix) do
    case Regex.run(
           ~r/\Ahttps:\/\/github\.com\/(orgs|users)\/([A-Za-z0-9][A-Za-z0-9-]{0,38})\/projects\/([1-9][0-9]*)\z/,
           config["project_url"]
         ) do
      [_, kind, owner, number] ->
        attrs["source_url"] == config["project_url"] and
          metadata["project_url"] == config["project_url"] and
          metadata["owner_kind"] == if(kind == "orgs", do: "organization", else: "user") and
          metadata["owner"] == owner and metadata["number"] == String.to_integer(number) and
          is_binary(metadata["project_id"]) and metadata["project_id"] != "" and
          metadata["kind"] in ~w(project field view item) and
          String.replace_prefix(attrs["external_id"], prefix, "") != ""

      _ ->
        false
    end
  end

  defp selected?("slack", config, attrs, metadata, prefix) do
    domain = metadata["team_domain"]
    ts = metadata["message_ts"]

    is_binary(domain) and Regex.match?(~r/\A[a-z0-9][a-z0-9-]{0,62}\z/, domain) and
      is_binary(ts) and Regex.match?(~r/\A[0-9]{10,16}\.[0-9]{6}\z/, ts) and
      metadata["team_id"] == config["team_id"] and
      metadata["channel_id"] == config["channel_id"] and metadata["kind"] in ~w(message reply) and
      attrs["external_id"] == prefix <> config["channel_id"] <> ":" <> ts and
      attrs["source_url"] ==
        "https://" <>
          domain <>
          ".slack.com/archives/" <>
          config["channel_id"] <>
          "/p" <>
          String.replace(ts, ".", "")
  end

  defp selected?("confluence", config, attrs, metadata, prefix) do
    Confluence.valid_source_url?(attrs["source_url"], config, metadata) and
      attrs["external_id"] == prefix <> metadata["page_id"]
  end

  defp selected?(_, _, _, _, _), do: false

  defp secure_url(value, host) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: "https", host: ^host, port: 443, userinfo: nil} = uri -> uri
      _ -> nil
    end
  end

  defp secure_url(_, _), do: nil
end
