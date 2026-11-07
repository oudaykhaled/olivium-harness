defmodule HarnessForge.Accounts.Provider do
  @moduledoc false
  alias HarnessForge.Connectors.{GitHubAccount, ServiceAccount}
  alias HarnessForge.Connectors.Common, as: C

  @projects """
  query HarnessForgeAccountProjects($limit: Int!) {
    viewer {
      databaseId login
      projectsV2(first: $limit, orderBy: {field: UPDATED_AT, direction: DESC}) {
        nodes { id number title url updatedAt public }
        pageInfo { hasNextPage }
      }
    }
  }
  """
  @slack_denied ~w(access_denied account_inactive invalid_auth missing_scope no_permission not_authed org_login_required team_access_not_granted token_expired token_revoked)

  def verify(%{"service" => "github"} = config, context) do
    GitHubAccount.verify(Map.take(config, ["credential_ref"]), context)
  end

  def verify(%{"service" => "github_projects"} = config, context) do
    with {:ok, result} <- query(config, 1, context), do: {:ok, result}
  end

  def verify(%{"service" => service} = config, context)
      when service in ~w(slack jira confluence) do
    with {:ok, headers} <- headers(config),
         {:ok, identity} <- identity(config, headers, context),
         {:ok, _} <- metadata(config, 1, identity, headers, context) do
      {:ok, %{"identity" => identity}}
    end
  end

  def query(%{"service" => "github"} = config, limit, context) do
    with {:ok, result} <-
           GitHubAccount.repositories(
             Map.take(config, ["credential_ref"]),
             %{"limit" => limit},
             context
           ) do
      {:ok,
       %{
         "identity" => result["identity"],
         "rows" => result["repositories"],
         "ordering" => result["ordering"],
         "coverage" => Map.take(result, ~w(scope visibility requested returned has_more complete))
       }}
    end
  end

  def query(%{"service" => "github_projects"} = config, limit, context) do
    with {:ok, headers} <- headers(config),
         {:ok, body, _} <- C.graphql(@projects, %{"limit" => limit}, headers, context),
         :ok <- graphql_status(body),
         %{"databaseId" => id, "login" => login, "projectsV2" => projects} <-
           get_in(body, ["data", "viewer"]),
         true <- C.database_id?(id) and login?(login),
         true <- is_map(projects) and is_map(projects["pageInfo"]),
         more when is_boolean(more) <- projects["pageInfo"]["hasNextPage"],
         {:ok, rows} <- C.reduce_items(projects["nodes"], limit, &project(&1, login)),
         true <- unique?(rows) do
      result(%{"id" => id, "login" => login}, rows, "updated_desc", limit, more, "viewer_owned")
    else
      false -> C.error("invalid_provider_response")
      {:error, _} = error -> error
      _ -> C.error("invalid_provider_response")
    end
  end

  def query(%{"service" => service} = config, limit, context)
      when service in ~w(slack jira confluence) do
    with {:ok, headers} <- headers(config),
         {:ok, identity} <- identity(config, headers, context) do
      metadata(config, limit, identity, headers, context)
    end
  end

  defp identity(%{"service" => "slack"} = config, headers, context) do
    with {:ok, body, _} <- C.get(config["endpoint"] <> "/api/auth.test", %{}, headers, context),
         :ok <- slack_status(body),
         true <- slack_id?(body["user_id"], ~w(U W)) and slack_id?(body["team_id"], ["T"]),
         true <- ServiceAccount.text?(body["user"], 100) do
      {:ok, %{"id" => body["user_id"], "login" => body["user"], "team_id" => body["team_id"]}}
    else
      false -> C.error("invalid_provider_response")
      error -> error
    end
  end

  defp identity(%{"service" => service} = config, headers, context) do
    path = if service == "jira", do: "/rest/api/3/myself", else: "/wiki/rest/api/user/current"

    with {:ok, body, _} <- C.get(config["endpoint"] <> path, %{}, headers, context),
         true <- is_map(body) and ServiceAccount.text?(body["accountId"], 256),
         true <- body["active"] != false and body["type"] != "anonymous" do
      {:ok, %{"id" => body["accountId"], "login" => body["accountId"]}}
    else
      false -> C.error("invalid_provider_response")
      error -> error
    end
  end

  defp metadata(%{"service" => "slack"} = config, limit, identity, headers, context) do
    params = %{types: "public_channel,private_channel", exclude_archived: true, limit: limit}

    with {:ok, body, _} <-
           C.get(config["endpoint"] <> "/api/conversations.list", params, headers, context),
         :ok <- slack_status(body),
         {:ok, rows} <- C.reduce_items(body["channels"], limit, &channel(&1, identity)),
         true <- unique?(rows),
         metadata when is_map(metadata) <- body["response_metadata"],
         cursor when is_binary(cursor) and byte_size(cursor) <= 4096 <- metadata["next_cursor"] do
      result(identity, rows, "provider_order", limit, cursor != "", "token_visible_channels")
    else
      false -> C.error("invalid_provider_response")
      {:error, _} = error -> error
      _ -> C.error("invalid_provider_response")
    end
  end

  defp metadata(%{"service" => "jira"} = config, limit, identity, headers, context) do
    params = %{startAt: 0, maxResults: limit, orderBy: "key"}

    with {:ok, body, _} <-
           C.get(config["endpoint"] <> "/rest/api/3/project/search", params, headers, context),
         true <- is_map(body) and is_boolean(body["isLast"]),
         {:ok, rows} <- C.reduce_items(body["values"], limit, &jira_project(&1, config)),
         true <- unique?(rows) do
      result(identity, rows, "key_asc", limit, not body["isLast"], "token_visible_projects")
    else
      false -> C.error("invalid_provider_response")
      error -> error
    end
  end

  defp metadata(%{"service" => "confluence"} = config, limit, identity, headers, context) do
    with {:ok, body, response} <-
           C.get(config["endpoint"] <> "/wiki/api/v2/spaces", %{limit: limit}, headers, context),
         true <- is_map(body),
         {:ok, rows} <- C.reduce_items(body["results"], limit, &space(&1, config)),
         true <- unique?(rows),
         links when is_map(links) <- Map.get(body, "_links", %{}),
         next = Map.get(links, "next"),
         true <- is_nil(next) or (is_binary(next) and byte_size(next) <= 4096) do
      more = not is_nil(next) or Req.Response.get_header(response, "link") != []
      result(identity, rows, "id_asc", limit, more, "token_visible_spaces")
    else
      false -> C.error("invalid_provider_response")
      {:error, _} = error -> error
      _ -> C.error("invalid_provider_response")
    end
  end

  defp project(item, login) when is_map(item) do
    if ServiceAccount.text?(item["id"], 256) and C.sequence?(item["number"]) and
         ServiceAccount.text?(item["title"], 512) and
         item["url"] == "https://github.com/users/#{login}/projects/#{item["number"]}" and
         C.timestamp?(item["updatedAt"]) and is_boolean(item["public"]),
       do: {:ok, Map.take(item, ~w(id number title url updatedAt public))},
       else: C.error("scope_violation")
  end

  defp project(_, _), do: C.error("invalid_provider_response")

  defp channel(item, identity) when is_map(item) do
    if slack_id?(item["id"], ~w(C G)) and ServiceAccount.text?(item["name"], 100) and
         is_boolean(item["is_private"]) and item["is_im"] != true and
         item["is_mpim"] != true and item["is_archived"] != true and
         (is_nil(item["context_team_id"]) or item["context_team_id"] == identity["team_id"]),
       do:
         {:ok,
          item
          |> Map.take(~w(id name is_private))
          |> Map.put("url", "https://app.slack.com/client/#{identity["team_id"]}/#{item["id"]}")},
       else: C.error("scope_violation")
  end

  defp channel(_, _), do: C.error("invalid_provider_response")

  defp jira_project(item, config) when is_map(item) do
    if decimal_id?(item["id"]) and is_binary(item["key"]) and
         Regex.match?(~r/^[A-Z][A-Z0-9_]{1,30}$/, item["key"]) and
         ServiceAccount.text?(item["name"], 512),
       do:
         {:ok,
          item
          |> Map.take(~w(id key name))
          |> Map.put(
            "url",
            config["endpoint"] <> "/plugins/servlet/project-config/" <> item["key"]
          )},
       else: C.error("invalid_provider_response")
  end

  defp jira_project(_, _), do: C.error("invalid_provider_response")

  defp space(item, config) when is_map(item) do
    if decimal_id?(item["id"]) and ServiceAccount.text?(item["key"], 128) and
         Regex.match?(~r/^[A-Za-z0-9_~-]+$/, item["key"]) and
         ServiceAccount.text?(item["name"], 512),
       do:
         {:ok,
          item
          |> Map.take(~w(id key name))
          |> Map.put("url", config["endpoint"] <> "/wiki/spaces/" <> item["key"])},
       else: C.error("invalid_provider_response")
  end

  defp space(_, _), do: C.error("invalid_provider_response")

  defp result(identity, rows, ordering, limit, more, scope) do
    {:ok,
     %{
       "identity" => identity,
       "rows" => rows,
       "ordering" => ordering,
       "coverage" => %{
         "scope" => scope,
         "visibility" => "token_visible",
         "requested" => limit,
         "returned" => length(rows),
         "has_more" => more,
         "complete" => not more
       }
     }}
  end

  defp headers(config) do
    with {:ok, token} <- C.credential(config["credential_ref"], true) do
      case config["service"] do
        service when service in ~w(jira confluence) ->
          with {:ok, username} <- C.credential(config["username_ref"], true) do
            {:ok,
             [
               {"accept", "application/json"},
               {"authorization", "Basic " <> Base.encode64(username <> ":" <> token)}
             ]}
          end

        service when service in ~w(github github_projects) ->
          {:ok,
           [
             {"accept", "application/vnd.github+json"},
             {"x-github-api-version", "2026-03-10"},
             {"authorization", "Bearer " <> token}
           ]}

        "slack" ->
          {:ok, [{"accept", "application/json"}, {"authorization", "Bearer " <> token}]}
      end
    end
  end

  defp graphql_status(%{"errors" => [_ | _] = errors}) do
    types = Enum.map(errors, &if(is_map(&1), do: &1["type"]))

    if "RATE_LIMITED" in types,
      do: C.error("rate_limited", true),
      else: C.error("source_access_denied")
  end

  defp graphql_status(%{"data" => %{}, "errors" => []}), do: :ok
  defp graphql_status(%{"data" => %{}} = body) when not is_map_key(body, "errors"), do: :ok
  defp graphql_status(_), do: C.error("invalid_provider_response")

  defp slack_status(%{"ok" => true}), do: :ok
  defp slack_status(%{"ok" => false, "error" => "ratelimited"}), do: C.error("rate_limited", true)

  defp slack_status(%{"ok" => false, "error" => error}) when error in @slack_denied,
    do: C.error("source_access_denied")

  defp slack_status(_), do: C.error("invalid_provider_response")

  defp login?(value),
    do: is_binary(value) and Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9-]{0,99}$/, value)

  defp slack_id?(value, prefixes),
    do:
      is_binary(value) and byte_size(value) in 2..64 and String.first(value) in prefixes and
        Regex.match?(~r/^[A-Z0-9]+$/, value)

  defp decimal_id?(value),
    do: is_binary(value) and byte_size(value) <= 20 and Regex.match?(~r/^[1-9][0-9]*$/, value)

  defp unique?(rows), do: length(Enum.uniq_by(rows, & &1["id"])) == length(rows)
end
