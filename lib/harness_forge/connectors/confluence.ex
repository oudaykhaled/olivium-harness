defmodule HarnessForge.Connectors.Confluence do
  @moduledoc "Read-only Confluence Cloud REST v2 current pages within one explicitly selected space."
  @behaviour HarnessForge.Contracts.Connector
  alias HarnessForge.Connectors.Common, as: C

  @size 20
  @body_bytes 1_048_576
  @container_nodes ~w(doc paragraph heading blockquote bulletList orderedList listItem codeBlock table tableRow tableCell tableHeader panel expand nestedExpand)
  @block_nodes ~w(paragraph heading blockquote listItem codeBlock tableRow panel expand nestedExpand)

  @impl true
  def validate_config(config) do
    if C.keys(config, ~w(endpoint space_id credential_ref username_ref)) and
         C.origin?(
           config["endpoint"],
           &Regex.match?(~r/^[a-z0-9][a-z0-9-]{0,62}\.atlassian\.net$/, &1)
         ) and numeric_id?(config["space_id"]) and
         is_binary(config["credential_ref"]) and is_binary(config["username_ref"]) and
         C.reference?(config["credential_ref"]) and C.reference?(config["username_ref"]),
       do: {:ok, config},
       else: C.error("invalid_connector_config")
  end

  @impl true
  def capabilities do
    %{
      "read_only" => true,
      "selected_space" => true,
      "kinds" => ["page"],
      "pagination" => true,
      "body_representation" => "atlas_doc_format_text_only",
      "macros_or_attachments" => false,
      "deletion_detection" => false,
      "live_acl" => false,
      "version_history" => false
    }
  end

  @impl true
  def fetch_page(config, cursor, context) do
    with {:ok, config} <- validate_config(config),
         {:ok, id} <- C.context_id(context),
         {:ok, token} <- C.credential(config["credential_ref"], true),
         {:ok, username} <- C.credential(config["username_ref"], true),
         {:ok, state} <- C.cursor(cursor, %{"stage" => "space"}) do
      headers = [
        {"accept", "application/json"},
        {"authorization", "Basic " <> Base.encode64(username <> ":" <> token)}
      ]

      fetch(config, state, id, headers, context)
    end
  end

  @doc "Checks the canonical page URL and selected-space provenance used at the import boundary."
  def valid_source_url?(url, config, metadata) when is_map(config) and is_map(metadata) do
    is_binary(config["endpoint"]) and
      metadata["kind"] == "page" and metadata["space_id"] == config["space_id"] and
      numeric_id?(metadata["page_id"]) and
      url == config["endpoint"] <> "/wiki/pages/viewpage.action?pageId=" <> metadata["page_id"]
  end

  def valid_source_url?(_, _, _), do: false

  defp fetch(config, %{"stage" => "space"} = state, _id, headers, context)
       when map_size(state) == 1 do
    with {:ok, space, _} <-
           C.get(
             config["endpoint"] <> "/wiki/api/v2/spaces/" <> config["space_id"],
             %{},
             headers,
             context
           ),
         true <- is_map(space) and space["id"] == config["space_id"],
         true <- space["status"] == "current" and bounded_text?(space["key"], 256),
         true <- bounded_text?(space["name"], 10_000) do
      page(
        [],
        %{
          "stage" => "pages",
          "space_id" => config["space_id"],
          "space_key" => space["key"],
          "page" => 1,
          "token" => nil
        },
        false
      )
    else
      false -> C.error("scope_violation")
      error -> error
    end
  end

  defp fetch(config, %{"stage" => "pages"} = state, id, headers, context) do
    if map_size(state) == 5 and C.keys(state, ~w(stage space_id space_key page token)) and
         state["space_id"] == config["space_id"] and bounded_text?(state["space_key"], 256) and
         C.page?(state["page"]) and token?(state["token"]) do
      params = %{"status" => "current", "body-format" => "atlas_doc_format", "limit" => @size}
      params = if state["token"], do: Map.put(params, "cursor", state["token"]), else: params
      path = "/wiki/api/v2/spaces/" <> config["space_id"] <> "/pages"

      with {:ok, body, response} <- C.get(config["endpoint"] <> path, params, headers, context),
           true <- is_map(body),
           {:ok, documents} <-
             C.reduce_items(body["results"], @size, &document(&1, config, state, id)),
           true <- length(Enum.uniq_by(documents, & &1["external_id"])) == length(documents),
           {:ok, next} <- next_token(body, response, config, path),
           true <-
             is_nil(next) or
               (next != state["token"] and documents != [] and state["page"] < 100_000) do
        if is_nil(next),
          do: page(documents, %{"stage" => "space"}, true),
          else: page(documents, %{state | "page" => state["page"] + 1, "token" => next}, false)
      else
        false -> C.error("invalid_provider_response")
        error -> error
      end
    else
      C.error("invalid_cursor")
    end
  end

  defp fetch(_, _, _, _, _), do: C.error("invalid_cursor")

  defp document(item, config, state, id) when is_map(item) do
    with true <- item["spaceId"] == config["space_id"] and item["status"] == "current",
         true <- numeric_id?(item["id"]) and bounded_text?(item["title"], 10_000),
         true <- C.timestamp?(item["createdAt"]) and bounded_text?(item["authorId"], 256),
         version when is_map(version) <- item["version"],
         true <- C.sequence?(version["number"]) and C.timestamp?(version["createdAt"]),
         true <- bounded_text?(version["authorId"], 256),
         {:ok, text, omitted} <- body_text(item["body"]) do
      {:ok,
       %{
         "external_id" => "confluence:#{id}:#{item["id"]}",
         "title" => item["title"],
         "body" => "# " <> item["title"] <> "\n\n" <> text,
         "source_url" =>
           config["endpoint"] <> "/wiki/pages/viewpage.action?pageId=" <> item["id"],
         "source_updated_at" => version["createdAt"],
         "metadata" => %{
           "kind" => "page",
           "space_id" => config["space_id"],
           "space_key" => state["space_key"],
           "page_id" => item["id"],
           "version" => version["number"],
           "author_id" => item["authorId"],
           "created_at" => item["createdAt"],
           "version_author_id" => version["authorId"],
           "body_representation" => "atlas_doc_format_text_only",
           "omitted_nodes" => omitted,
           "normalizer_version" => "confluence-v1"
         }
       }}
    else
      {:error, _} = error -> error
      _ -> C.error("scope_violation")
    end
  end

  defp document(_, _, _, _), do: C.error("invalid_provider_response")

  defp body_text(%{"atlas_doc_format" => %{"value" => value} = body})
       when is_binary(value) and byte_size(value) <= @body_bytes do
    with true <- body["representation"] in [nil, "atlas_doc_format"],
         {:ok, %{"type" => "doc", "version" => 1} = document} <- Jason.decode(value),
         {:ok, parts, _nodes, omitted} <- adf(document, 0, 0),
         text = IO.iodata_to_binary(parts),
         true <- byte_size(text) <= @body_bytes - 10_004 do
      {:ok, text, omitted}
    else
      _ -> C.error("invalid_provider_response")
    end
  end

  defp body_text(_), do: C.error("invalid_provider_response")

  defp adf(_, depth, nodes) when depth > 16 or nodes >= 10_000,
    do: C.error("invalid_provider_response")

  defp adf(%{"type" => "text", "text" => text}, _depth, nodes) when is_binary(text) do
    if String.valid?(text) and not String.contains?(text, <<0>>),
      do: {:ok, text, nodes + 1, 0},
      else: C.error("invalid_provider_response")
  end

  defp adf(%{"type" => "hardBreak"}, _depth, nodes), do: {:ok, "\n", nodes + 1, 0}
  defp adf(%{"type" => "rule"}, _depth, nodes), do: {:ok, "\n---\n", nodes + 1, 0}

  defp adf(%{"type" => type} = node, depth, nodes) when type in @container_nodes do
    content = Map.get(node, "content", [])

    if is_list(content) and length(content) <= 10_000 do
      Enum.reduce_while(content, {:ok, [], nodes + 1, 0}, fn child,
                                                             {:ok, parts, count, omitted} ->
        case adf(child, depth + 1, count) do
          {:ok, text, count, missing} -> {:cont, {:ok, [text | parts], count, omitted + missing}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, parts, count, omitted} ->
          {:ok, [Enum.reverse(parts), if(type in @block_nodes, do: "\n", else: "")], count,
           omitted}

        error ->
          error
      end
    else
      C.error("invalid_provider_response")
    end
  end

  # Macros, media, smart cards and unsupported extensions are inert markers.
  # Their attributes, URLs and nested content are never fetched or executed.
  defp adf(%{"type" => type}, _depth, nodes) when is_binary(type),
    do: {:ok, "[unsupported Confluence content]", nodes + 1, 1}

  defp adf(_, _, _), do: C.error("invalid_provider_response")

  defp next_token(body, response, config, path) do
    links = Map.get(body, "_links", %{})
    header = response |> Req.Response.get_header("link") |> Enum.join(",")
    next_headers = Regex.scan(~r/<([^>]*)>\s*;\s*rel="?next"?(?=\s|;|,|$)/i, header)

    cond do
      not is_map(links) ->
        C.error("invalid_provider_response")

      length(next_headers) > 1 ->
        C.error("scope_violation")

      next_headers == [] and Regex.match?(~r/rel\s*=\s*"?next/i, header) ->
        C.error("scope_violation")

      true ->
        targets = [links["next"] | Enum.map(next_headers, fn [_, target] -> target end)]
        targets = Enum.reject(targets, &is_nil/1)

        with {:ok, tokens} <- C.reduce_items(targets, 2, &pagination_token(&1, config, path)),
             true <- length(Enum.uniq(tokens)) <= 1 do
          {:ok, List.first(tokens)}
        else
          false -> C.error("scope_violation")
          error -> error
        end
    end
  end

  defp pagination_token(target, config, path)
       when is_binary(target) and byte_size(target) <= 8192 do
    actual = URI.parse(target)
    expected = URI.parse(config["endpoint"])

    origin =
      (is_nil(actual.scheme) and is_nil(actual.host) and is_nil(actual.port)) or
        (actual.scheme == "https" and actual.host == expected.host and actual.port == 443)

    pairs = URI.query_decoder(actual.query || "") |> Enum.to_list()
    query = Map.new(pairs)

    valid_filters =
      Enum.all?(query, fn
        {"cursor", value} -> token?(value) and not is_nil(value)
        {"limit", value} -> value == Integer.to_string(@size)
        {"status", value} -> value == "current"
        {"body-format", value} -> value == "atlas_doc_format"
        _ -> false
      end)

    if origin and actual.path == path and is_nil(actual.userinfo) and is_nil(actual.fragment) and
         map_size(query) == length(pairs) and valid_filters and token?(query["cursor"]) and
         is_binary(query["cursor"]),
       do: {:ok, query["cursor"]},
       else: C.error("scope_violation")
  rescue
    _ -> C.error("scope_violation")
  end

  defp pagination_token(_, _, _), do: C.error("scope_violation")

  defp numeric_id?(id), do: is_binary(id) and Regex.match?(~r/^[1-9][0-9]{0,19}$/, id)

  defp bounded_text?(value, maximum),
    do:
      is_binary(value) and byte_size(value) in 1..maximum and String.valid?(value) and
        not Regex.match?(~r/[\x00-\x1f\x7f]/u, value)

  defp token?(nil), do: true
  defp token?(value), do: bounded_text?(value, 4096)

  defp page(items, state, complete),
    do:
      {:ok, %{"items" => items, "next_cursor" => C.encode_cursor(state), "complete" => complete}}
end
