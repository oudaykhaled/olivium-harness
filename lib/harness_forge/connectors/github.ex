defmodule HarnessForge.Connectors.GitHub do
  @moduledoc "Read-only GitHub.com metadata, issues, pull-request bodies and reviews for one selected repository."
  @behaviour HarnessForge.Contracts.Connector
  alias HarnessForge.Connectors.Common, as: C
  @size 30

  @impl true
  def validate_config(config) do
    if C.keys(config, ~w(endpoint repository credential_ref)) and
         config["endpoint"] == "https://api.github.com" and is_binary(config["repository"]) and
         Regex.match?(~r/^[A-Za-z0-9_-]{1,100}\/[A-Za-z0-9_.-]{1,100}$/, config["repository"]) and
         not String.ends_with?(config["repository"], ["/.", "/.."]) and
         C.reference?(config["credential_ref"]),
       do: {:ok, config},
       else: C.error("invalid_connector_config")
  end

  @impl true
  def capabilities,
    do: %{
      "read_only" => true,
      "selected_repository" => true,
      "kinds" => ~w(repository issue pull_request review),
      "comments" => false,
      "deletion_detection" => false,
      "live_acl" => false,
      "pagination" => true
    }

  @impl true
  def fetch_page(config, cursor, context) do
    with {:ok, config} <- validate_config(config),
         {:ok, id} <- C.context_id(context),
         {:ok, credential} <- C.credential(config["credential_ref"], false),
         {:ok, state} <- C.cursor(cursor, %{"stage" => "repository"}),
         {:ok, result} <- fetch(config, state, id, headers(credential), context) do
      {:ok, result}
    end
  end

  defp fetch(config, %{"stage" => "repository"} = state, id, headers, context) do
    since = state["since"]

    with true <- is_nil(since) or C.timestamp?(since),
         {:ok, body, _} <- C.get(repo_url(config), %{}, headers, context),
         true <-
           is_map(body) and is_binary(body["full_name"]) and
             String.downcase(body["full_name"]) == String.downcase(config["repository"]),
         true <- same_url?(body["html_url"], web_url(config)),
         true <- C.database_id?(body["id"]),
         true <- C.timestamp?(body["updated_at"]),
         true <- is_nil(body["description"]) or is_binary(body["description"]) do
      document =
        document(
          id,
          "repository",
          body["full_name"],
          body["description"] || "",
          body["html_url"],
          body["updated_at"],
          %{"kind" => "repository", "repository" => config["repository"]}
        )

      next = %{
        "stage" => "issues",
        "repository_id" => body["id"],
        "page" => 1,
        "since" => since,
        "scan_started" => DateTime.utc_now() |> DateTime.add(-60) |> DateTime.to_iso8601()
      }

      page([document], next, false)
    else
      false -> C.error("scope_violation")
      error -> error
    end
  end

  defp fetch(
         config,
         %{"stage" => "issues", "page" => n, "scan_started" => started} = state,
         id,
         headers,
         context
       ) do
    if C.page?(n) and C.timestamp?(started) and
         (is_nil(state["since"]) or C.timestamp?(state["since"])) do
      url = repo_url(config) <> "/issues"
      params = %{state: "all", sort: "updated", direction: "asc", per_page: @size, page: n}
      params = if state["since"], do: Map.put(params, :since, state["since"]), else: params
      params = if state["after"], do: Map.put(params, :after, state["after"]), else: params

      with {:ok, state} <- issue_state(config, state, headers, context),
           {:ok, body, response} <- C.get(url, params, headers, context),
           {:ok, items} <- C.reduce_items(body, @size, &issue(&1, config, id)),
           {:ok, next_page} <-
             C.next_github_issues(response, url, params, n, state["repository_id"]) do
        pulls = body |> Enum.filter(&is_map(&1["pull_request"])) |> Enum.map(& &1["number"])

        continuation =
          if next_page,
            do: Map.merge(state, next_page),
            else: %{"stage" => "repository", "since" => started}

        if pulls == [] do
          page(items, continuation, is_nil(next_page))
        else
          page(
            items,
            %{
              "stage" => "reviews",
              "pulls" => pulls,
              "page" => 1,
              "continuation" => continuation,
              "last_issues" => is_nil(next_page)
            },
            false
          )
        end
      end
    else
      C.error("invalid_cursor")
    end
  end

  defp fetch(
         config,
         %{
           "stage" => "reviews",
           "pulls" => [number | remaining],
           "page" => n,
           "continuation" => continuation,
           "last_issues" => last
         } = state,
         id,
         headers,
         context
       ) do
    if C.page?(n) and length(remaining) < @size and
         Enum.all?([number | remaining], &C.sequence?/1) and is_map(continuation) and
         is_boolean(last) do
      url = repo_url(config) <> "/pulls/#{number}/reviews"
      params = %{per_page: @size, page: n}

      with {:ok, body, response} <- C.get(url, params, headers, context),
           {:ok, items} <- C.reduce_items(body, @size, &review(&1, number, config, id)),
           {:ok, next_page} <- C.next_github(response, url, params, n) do
        cond do
          next_page -> page(items, %{state | "page" => next_page}, false)
          remaining != [] -> page(items, %{state | "pulls" => remaining, "page" => 1}, false)
          true -> page(items, continuation, last)
        end
      end
    else
      C.error("invalid_cursor")
    end
  end

  defp fetch(_, _, _, _, _), do: C.error("invalid_cursor")

  # Older stored scans have no repository ID. Re-verify metadata without
  # discarding their page/since position before accepting numeric-path links.
  defp issue_state(config, state, headers, context) do
    cond do
      not C.github_after?(state["after"]) ->
        C.error("invalid_cursor")

      C.database_id?(state["repository_id"]) ->
        {:ok, state}

      not Map.has_key?(state, "repository_id") and is_nil(state["after"]) ->
        with {:ok, body, _} <- C.get(repo_url(config), %{}, headers, context),
             true <-
               is_map(body) and C.database_id?(body["id"]) and
                 is_binary(body["full_name"]) and
                 String.downcase(body["full_name"]) == String.downcase(config["repository"]) and
                 same_url?(body["html_url"], web_url(config)) do
          {:ok, Map.put(state, "repository_id", body["id"])}
        else
          false -> C.error("scope_violation")
          error -> error
        end

      true ->
        C.error("invalid_cursor")
    end
  end

  defp issue(item, config, id) when is_map(item) do
    number = item["number"]
    kind = if is_map(item["pull_request"]), do: "pull_request", else: "issue"
    web_kind = if kind == "pull_request", do: "pull", else: "issues"

    with true <- C.sequence?(number),
         true <- C.database_id?(item["id"]),
         true <- same_url?(item["url"], repo_url(config) <> "/issues/#{number}"),
         true <- same_url?(item["html_url"], web_url(config) <> "/#{web_kind}/#{number}"),
         true <- is_binary(item["title"]) and (is_nil(item["body"]) or is_binary(item["body"])),
         true <- C.timestamp?(item["updated_at"]),
         true <- item["state"] in ["open", "closed"] do
      text =
        "# " <> item["title"] <> "\n\nState: " <> item["state"] <> "\n\n" <> (item["body"] || "")

      {:ok,
       document(
         id,
         "issue:#{item["id"]}",
         item["title"],
         text,
         item["html_url"],
         item["updated_at"],
         %{"kind" => kind, "repository" => config["repository"], "number" => number}
       )}
    else
      _ -> C.error("scope_violation")
    end
  end

  defp issue(_, _, _), do: C.error("invalid_provider_response")

  defp review(item, number, config, id) when is_map(item) do
    with true <- C.database_id?(item["id"]),
         true <-
           same_url?(
             item["html_url"],
             web_url(config) <> "/pull/#{number}#pullrequestreview-#{item["id"]}"
           ),
         true <- is_nil(item["body"]) or is_binary(item["body"]),
         true <- is_binary(item["state"]),
         true <- is_nil(item["submitted_at"]) or C.timestamp?(item["submitted_at"]) do
      {:ok,
       document(
         id,
         "review:#{item["id"]}",
         "Review for ##{number}",
         "State: #{item["state"]}\n\n" <> (item["body"] || ""),
         item["html_url"],
         item["submitted_at"],
         %{"kind" => "review", "repository" => config["repository"], "pull_number" => number}
       )}
    else
      _ -> C.error("scope_violation")
    end
  end

  defp review(_, _, _, _), do: C.error("invalid_provider_response")

  defp document(id, key, title, text, url, updated, metadata),
    do: %{
      "external_id" => "github:#{id}:#{key}",
      "title" => title,
      "body" => text,
      "source_url" => url,
      "source_updated_at" => updated,
      "metadata" => Map.put(metadata, "normalizer_version", "github-v1")
    }

  defp page(items, cursor, complete),
    do:
      {:ok, %{"items" => items, "next_cursor" => C.encode_cursor(cursor), "complete" => complete}}

  defp repo_url(config), do: config["endpoint"] <> "/repos/" <> config["repository"]
  defp web_url(config), do: "https://github.com/" <> config["repository"]

  defp same_url?(actual, expected) when is_binary(actual),
    do: String.downcase(actual) == String.downcase(expected)

  defp same_url?(_, _), do: false

  defp headers(nil),
    do: [{"accept", "application/vnd.github+json"}, {"x-github-api-version", "2022-11-28"}]

  defp headers(value), do: [{"authorization", "Bearer " <> value} | headers(nil)]
end
