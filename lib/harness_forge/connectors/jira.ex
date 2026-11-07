defmodule HarnessForge.Connectors.Jira do
  @moduledoc "Read-only Jira Cloud enhanced search and paginated issue changelogs within one selected project."
  @behaviour HarnessForge.Contracts.Connector
  alias HarnessForge.Connectors.Common, as: C
  @size 20

  @impl true
  def validate_config(config) do
    if C.keys(config, ~w(endpoint project credential_ref username_ref)) and
         C.origin?(
           config["endpoint"],
           &Regex.match?(~r/^[a-z0-9][a-z0-9-]{0,62}\.atlassian\.net$/, &1)
         ) and is_binary(config["project"]) and
         Regex.match?(~r/^[A-Z][A-Z0-9_]{1,30}$/, config["project"]) and
         is_binary(config["credential_ref"]) and is_binary(config["username_ref"]) and
         C.reference?(config["credential_ref"]) and C.reference?(config["username_ref"]),
       do: {:ok, config},
       else: C.error("invalid_connector_config")
  end

  @impl true
  def capabilities,
    do: %{
      "read_only" => true,
      "selected_project" => true,
      "kinds" => ~w(issue changelog),
      "pagination" => true,
      "deletion_detection" => false,
      "live_acl" => false,
      "issue_pr_link_inference" => false
    }

  @impl true
  def fetch_page(config, cursor, context) do
    with {:ok, config} <- validate_config(config),
         {:ok, id} <- C.context_id(context),
         {:ok, token} <- C.credential(config["credential_ref"], true),
         {:ok, username} <- C.credential(config["username_ref"], true),
         {:ok, state} <- C.cursor(cursor, %{"stage" => "issues"}) do
      headers = [
        {"accept", "application/json"},
        {"authorization", "Basic " <> Base.encode64(username <> ":" <> token)}
      ]

      fetch(config, state, id, headers, context)
    end
  end

  defp fetch(config, %{"stage" => "issues"} = state, id, headers, context) do
    if token?(state["token"]) do
      params = %{
        jql: "project = \"#{config["project"]}\" ORDER BY key ASC",
        maxResults: @size,
        fields: "summary,description,updated,project,status"
      }

      params =
        if state["token"], do: Map.put(params, :nextPageToken, state["token"]), else: params

      with {:ok, body, _} <-
             C.get(config["endpoint"] <> "/rest/api/3/search/jql", params, headers, context),
           true <- is_map(body) and is_boolean(body["isLast"]),
           {:ok, items} <- C.reduce_items(body["issues"], @size, &issue(&1, config, id)),
           true <-
             token?(body["nextPageToken"]) and
               (body["isLast"] or is_binary(body["nextPageToken"])),
           true <- body["isLast"] or body["nextPageToken"] != state["token"] do
        continuation =
          if body["isLast"],
            do: %{"stage" => "issues"},
            else: %{"stage" => "issues", "token" => body["nextPageToken"]}

        issues = Enum.map(body["issues"], &Map.take(&1, ["key", "id"]))

        if issues == [] do
          page(items, continuation, body["isLast"])
        else
          page(
            items,
            %{
              "stage" => "changelog",
              "issues" => issues,
              "offset" => 0,
              "continuation" => continuation,
              "last_issues" => body["isLast"]
            },
            false
          )
        end
      else
        false -> C.error("invalid_provider_response")
        error -> error
      end
    else
      C.error("invalid_cursor")
    end
  end

  defp fetch(
         config,
         %{
           "stage" => "changelog",
           "issues" => [issue | remaining],
           "offset" => offset,
           "continuation" => continuation,
           "last_issues" => last
         } = state,
         id,
         headers,
         context
       ) do
    if valid_issue_identity?(issue, config) and length(remaining) < @size and
         Enum.all?(remaining, &valid_issue_identity?(&1, config)) and is_integer(offset) and
         offset >= 0 and offset <= 2_000_000 and is_map(continuation) and is_boolean(last) do
      url = config["endpoint"] <> "/rest/api/3/issue/" <> issue["key"] <> "/changelog"

      with {:ok, body, _} <- C.get(url, %{startAt: offset, maxResults: @size}, headers, context),
           true <-
             is_map(body) and body["startAt"] == offset and is_boolean(body["isLast"]) and
               is_integer(body["total"]) and body["total"] >= 0,
           {:ok, items} <-
             C.reduce_items(
               body["values"],
               @size,
               &history(&1, issue, config, id, offset, body["isLast"])
             ),
           true <- body["isLast"] or items != [],
           true <- offset + length(items) <= body["total"],
           true <- not body["isLast"] or offset + length(items) == body["total"] do
        cond do
          not body["isLast"] -> page(items, %{state | "offset" => offset + length(items)}, false)
          remaining != [] -> page(items, %{state | "issues" => remaining, "offset" => 0}, false)
          true -> page(items, continuation, last)
        end
      else
        false -> C.error("incomplete_history")
        error -> error
      end
    else
      C.error("invalid_cursor")
    end
  end

  defp fetch(_, _, _, _, _), do: C.error("invalid_cursor")

  defp issue(item, config, id) when is_map(item) do
    fields = item["fields"]

    with true <- valid_issue_identity?(item, config),
         true <-
           is_map(fields) and is_map(fields["project"]) and
             fields["project"]["key"] == config["project"],
         true <- item["self"] == config["endpoint"] <> "/rest/api/3/issue/" <> item["id"],
         true <- is_binary(fields["summary"]) and C.timestamp?(fields["updated"]),
         {:ok, text} <- adf(fields["description"], 0) do
      metadata = %{
        "kind" => "issue",
        "project" => config["project"],
        "issue_key" => item["key"],
        "changelog" => "separate_paginated_sources",
        "description_format" => "adf_text_only",
        "normalizer_version" => "jira-v1"
      }

      {:ok,
       %{
         "external_id" => "jira:#{id}:issue:#{item["id"]}",
         "title" => item["key"] <> ": " <> fields["summary"],
         "body" => "# " <> fields["summary"] <> "\n\n" <> text,
         "source_url" => config["endpoint"] <> "/browse/" <> item["key"],
         "source_updated_at" => fields["updated"],
         "metadata" => metadata
       }}
    else
      false -> C.error("scope_violation")
      error -> error
    end
  end

  defp issue(_, _, _), do: C.error("invalid_provider_response")

  defp history(row, issue, config, id, offset, last) when is_map(row) do
    with true <- numeric_id?(row["id"]) and C.timestamp?(row["created"]),
         {:ok, transitions} <- C.reduce_items(row["items"], 100, &transition/1) do
      {:ok,
       %{
         "external_id" => "jira:#{id}:changelog:#{issue["id"]}:#{row["id"]}",
         "title" => "#{issue["key"]} changelog #{row["id"]}",
         "body" => Enum.join(transitions, "\n"),
         "source_url" => config["endpoint"] <> "/browse/" <> issue["key"],
         "source_updated_at" => row["created"],
         "metadata" => %{
           "kind" => "changelog",
           "issue_key" => issue["key"],
           "project" => config["project"],
           "page_offset" => offset,
           "page_is_last" => last,
           "normalizer_version" => "jira-v1"
         }
       }}
    else
      false -> C.error("invalid_provider_response")
      error -> error
    end
  end

  defp history(_, _, _, _, _, _), do: C.error("invalid_provider_response")

  defp transition(%{"field" => field} = row) when is_binary(field) do
    if Enum.all?([row["fromString"], row["toString"]], &(is_nil(&1) or is_binary(&1))),
      do:
        {:ok,
         Jason.encode!(%{"field" => field, "from" => row["fromString"], "to" => row["toString"]})},
      else: C.error("invalid_provider_response")
  end

  defp transition(_), do: C.error("invalid_provider_response")

  defp valid_issue_identity?(item, config) when is_map(item),
    do:
      numeric_id?(item["id"]) and is_binary(item["key"]) and
        Regex.match?(
          Regex.compile!("^" <> Regex.escape(config["project"]) <> "-[1-9][0-9]{0,14}$"),
          item["key"]
        )

  defp valid_issue_identity?(_, _), do: false
  defp numeric_id?(id), do: is_binary(id) and Regex.match?(~r/^[1-9][0-9]{0,19}$/, id)
  defp token?(nil), do: true

  defp token?(token),
    do: is_binary(token) and byte_size(token) in 1..4096 and String.valid?(token)

  defp adf(_, depth) when depth > 16, do: C.error("invalid_provider_response")
  defp adf(nil, _), do: {:ok, ""}
  defp adf(text, _) when is_binary(text), do: {:ok, text}
  defp adf(%{"type" => "text", "text" => text}, _) when is_binary(text), do: {:ok, text}
  defp adf(%{"type" => "hardBreak"}, _), do: {:ok, "\n"}

  defp adf(%{"type" => kind} = node, depth) when is_binary(kind) do
    with {:ok, parts} <- C.reduce_items(node["content"] || [], 10_000, &adf(&1, depth + 1)) do
      {:ok,
       Enum.join(parts) <> if(kind in ["paragraph", "heading", "listItem"], do: "\n", else: "")}
    end
  end

  defp adf(_, _), do: C.error("invalid_provider_response")

  defp page(items, state, complete),
    do:
      {:ok, %{"items" => items, "next_cursor" => C.encode_cursor(state), "complete" => complete}}
end
