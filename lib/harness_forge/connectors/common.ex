defmodule HarnessForge.Connectors.Common do
  @moduledoc false
  alias HarnessForge.Contracts.Error
  @max_bytes 4_194_304

  def error(code, retryable \\ false, details \\ []) do
    {:error,
     %Error{
       code: code,
       message: "Source connector could not complete this page",
       retryable: retryable,
       correlation_id: Ecto.UUID.generate(),
       details: details
     }}
  end

  def keys(config, allowed) when is_map(config), do: Enum.all?(Map.keys(config), &(&1 in allowed))
  def keys(_, _), do: false

  def reference?(nil), do: true

  def reference?(value) when is_binary(value),
    do: Regex.match?(~r/^[A-Z][A-Z0-9_]{1,127}$/, value)

  def reference?(_), do: false

  def credential(nil, false), do: {:ok, nil}

  def credential(ref, _) when is_binary(ref) do
    case System.get_env(ref) do
      value when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= 16_384 ->
        if String.contains?(value, ["\r", "\n"]),
          do: error("credential_unavailable"),
          else: {:ok, value}

      _ ->
        error("credential_unavailable")
    end
  end

  def credential(_, _), do: error("credential_unavailable")

  def origin?(value, host_check) when is_binary(value) do
    case URI.parse(value) do
      %URI{
        scheme: "https",
        host: host,
        port: 443,
        path: path,
        userinfo: nil,
        query: nil,
        fragment: nil
      }
      when path in [nil, ""] and is_binary(host) ->
        host_check.(host)

      _ ->
        false
    end
  end

  def origin?(_, _), do: false

  def timestamp?(value) when is_binary(value) do
    match?(
      {:ok, _, _},
      DateTime.from_iso8601(Regex.replace(~r/([+-][0-9]{2})([0-9]{2})$/, value, "\\1:\\2"))
    )
  end

  def timestamp?(_), do: false

  def cursor(nil, initial), do: {:ok, initial}

  def cursor(bytes, _) when is_binary(bytes) and byte_size(bytes) <= 16_384 do
    case Jason.decode(bytes) do
      {:ok, %{} = cursor} -> {:ok, cursor}
      _ -> error("invalid_cursor")
    end
  end

  def cursor(_, _), do: error("invalid_cursor")
  def encode_cursor(state), do: Jason.encode!(state)

  def context_id(%{"connection_id" => id}) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, _} -> {:ok, id}
      _ -> error("invalid_connection")
    end
  end

  def context_id(_), do: error("invalid_connection")

  # Only an explicitly supplied trusted test transport is configurable. Config maps
  # cannot override URL, auth, TLS, redirects, timeouts or retry behaviour.
  def get(url, params, headers, context) do
    request(:get, url, [params: params], headers, context)
  end

  @doc false
  def graphql(query, variables, headers, context) when is_binary(query) and is_map(variables) do
    if String.starts_with?(String.trim_leading(query), "query ") and
         not Regex.match?(~r/\bmutation\b/, query) and byte_size(query) <= 65_536 do
      request(
        :post,
        "https://api.github.com/graphql",
        [json: %{query: query, variables: variables}],
        headers,
        context
      )
    else
      error("invalid_graphql_operation")
    end
  end

  def graphql(_, _, _, _), do: error("invalid_graphql_operation")

  defp request(method, url, payload, headers, context) do
    options = [
      method: method,
      url: url,
      headers: [{"accept-encoding", "identity"} | headers],
      retry: false,
      redirect: false,
      raw: true,
      compressed: false,
      receive_timeout: 15_000,
      connect_options: [timeout: 5_000],
      into: &collect/2
    ]

    test_options = Keyword.take(context["request_options"] || [], [:plug])

    case Req.request(options ++ payload ++ test_options) do
      {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
        if byte_size(response.body) <= @max_bytes do
          case Jason.decode(response.body) do
            {:ok, body} -> {:ok, body, response}
            _ -> error("invalid_provider_response")
          end
        else
          error("provider_response_too_large")
        end

      {:ok, response} ->
        status_error(response)

      {:error, _} ->
        error("provider_unavailable", true)
    end
  rescue
    # Never propagate a provider exception, request, URL-with-auth, or raw body.
    _ -> error("provider_unavailable", true)
  end

  defp collect({:data, data}, {request, response}) do
    body = response.body <> data

    if byte_size(body) <= @max_bytes do
      {:cont, {request, %{response | body: body}}}
    else
      {:halt, {request, %{response | body: String.duplicate(" ", @max_bytes + 1)}}}
    end
  end

  defp status_error(response) do
    rate? =
      response.status == 429 or
        (response.status == 403 and
           (Req.Response.get_header(response, "x-ratelimit-remaining") == ["0"] or
              Req.Response.get_header(response, "retry-after") != []))

    cond do
      rate? -> error("rate_limited", true, retry_after(response))
      response.status in [401, 403, 404] -> error("source_access_denied")
      response.status in 300..399 -> error("redirect_rejected")
      response.status in 500..599 -> error("provider_unavailable", true)
      true -> error("provider_request_rejected")
    end
  end

  defp retry_after(response) do
    case Req.Response.get_header(response, "retry-after") do
      [value] ->
        case Integer.parse(value) do
          {seconds, ""} when seconds >= 0 -> ["retry_after_seconds:#{min(seconds, 86_400)}"]
          _ -> []
        end

      _ ->
        []
    end
  end

  def next_github(response, url, params, page),
    do: github_next(response, url, params, page, nil)

  def next_github_issues(response, url, params, page, repository_id),
    do: github_next(response, url, params, page, repository_id)

  def github_after?(nil), do: true

  def github_after?(value) when is_binary(value),
    do: byte_size(value) <= 2_048 and Regex.match?(~r/^[\x21-\x7E]+$/, value)

  def github_after?(_), do: false

  defp github_next(response, url, params, page, repository_id) do
    link = response |> Req.Response.get_header("link") |> Enum.join(",")

    case Regex.scan(~r/<([^>]+)>;\s*rel="next"/, link) do
      [] ->
        if String.contains?(link, ~s(rel="next")),
          do: error("scope_violation"),
          else: {:ok, nil}

      [[_, target]] ->
        expected = URI.parse(url)
        actual = URI.parse(target)
        pairs = URI.query_decoder(actual.query || "") |> Enum.to_list()
        query = Map.new(pairs)
        after_cursor = query["after"]
        issue_cursor? = database_id?(repository_id)

        expected_query =
          params
          |> Map.new(fn {k, v} -> {to_string(k), to_string(v)} end)
          |> Map.delete("after")
          |> Map.put("page", to_string(page + 1))

        path? =
          actual.path == expected.path or
            (issue_cursor? and actual.path == "/repositories/#{repository_id}/issues")

        after? =
          if issue_cursor?,
            do:
              github_after?(after_cursor) and
                (is_nil(params[:after]) or
                   (is_binary(after_cursor) and after_cursor != params[:after])),
            else: is_nil(after_cursor)

        if actual.scheme == expected.scheme and actual.host == expected.host and
             actual.port == expected.port and path? and
             is_nil(actual.userinfo) and is_nil(actual.fragment) and after? and
             length(pairs) == map_size(query) and Map.delete(query, "after") == expected_query and
             page < 100_000 do
          if issue_cursor?,
            do: {:ok, %{"page" => page + 1, "after" => after_cursor}},
            else: {:ok, page + 1}
        else
          error("scope_violation")
        end

      _ ->
        error("scope_violation")
    end
  rescue
    _ -> error("scope_violation")
  end

  def database_id?(n), do: is_integer(n) and n > 0 and n <= 9_223_372_036_854_775_807

  def sequence?(n), do: is_integer(n) and n > 0 and n <= 100_000_000
  def page?(n), do: is_integer(n) and n > 0 and n <= 100_000

  def reduce_items(items, maximum, fun) when is_list(items) and length(items) <= maximum do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, document} -> {:cont, {:ok, [document | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  def reduce_items(_, _, _), do: error("invalid_provider_response")
end
