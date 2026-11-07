defmodule HarnessForge.Connectors.Slack do
  @moduledoc "Read-only, explicitly selected Slack workspace/channel messages and threaded replies."
  @behaviour HarnessForge.Contracts.Connector
  alias HarnessForge.Connectors.Common, as: C

  @size 15
  @max_pages 100_000
  @seen_limit 96
  @denied ~w(access_denied account_inactive channel_not_found channel_is_limited_access invalid_auth missing_scope no_permission not_authed not_in_channel org_login_required team_access_not_granted token_expired token_revoked)

  @impl true
  def validate_config(config) do
    if C.keys(config, ~w(endpoint team_id channel_id credential_ref)) and
         config["endpoint"] == "https://slack.com" and team?(config["team_id"]) and
         channel?(config["channel_id"]) and is_binary(config["credential_ref"]) and
         C.reference?(config["credential_ref"]),
       do: {:ok, config},
       else: C.error("invalid_connector_config")
  end

  @impl true
  def capabilities,
    do: %{
      "read_only" => true,
      "selected_workspace" => true,
      "selected_channel" => true,
      "kinds" => ~w(message reply),
      "pagination" => true,
      "threaded_replies" => true,
      "page_size" => @size,
      "deletion_detection" => false,
      "live_acl" => false,
      "files" => false,
      "direct_messages" => false,
      "scan" => "full_rescan"
    }

  @impl true
  def fetch_page(config, cursor, context) do
    with {:ok, config} <- validate_config(config),
         {:ok, id} <- C.context_id(context),
         {:ok, token} <- C.credential(config["credential_ref"], true),
         {:ok, state} <- C.cursor(cursor, initial(config)),
         true <- valid_state?(state, config),
         headers = [{"accept", "application/json"}, {"authorization", "Bearer " <> token}],
         {:ok, team} <- get("team.info", %{}, headers, context),
         {:ok, domain} <- workspace(team, config),
         {:ok, channel} <-
           get("conversations.info", %{channel: config["channel_id"]}, headers, context),
         :ok <- selected_channel(channel, config) do
      fetch(state, config, id, domain, headers, context)
    else
      false -> C.error("invalid_cursor")
      error -> error
    end
  end

  defp fetch(%{"stage" => "history"} = state, config, id, domain, headers, context) do
    params = params(state, config)

    with {:ok, body} <- get("conversations.history", params, headers, context),
         {:ok, items} <-
           C.reduce_items(body["messages"], @size, &document(&1, config, id, domain, nil)),
         {:ok, next, seen, bound} <- pagination(body, state, :descending),
         {:ok, threads} <- threads(body["messages"]) do
      continuation =
        if next,
          do: %{
            state
            | "token" => next,
              "seen" => seen,
              "bound" => bound,
              "pages" => state["pages"] + 1
          }

      case threads do
        [] -> advance(items, continuation, config)
        _ -> page(items, reply_state(threads, continuation, config), false)
      end
    end
  end

  defp fetch(
         %{"stage" => "replies", "threads" => [thread | remaining]} = state,
         config,
         id,
         domain,
         headers,
         context
       ) do
    params = state |> params(config) |> Map.put(:ts, thread)

    with {:ok, body} <- get("conversations.replies", params, headers, context),
         {:ok, items} <-
           C.reduce_items(body["messages"], @size, &document(&1, config, id, domain, thread)),
         :ok <- nonempty_thread(items),
         {:ok, next, seen, bound} <- pagination(body, state, :ascending) do
      cond do
        next ->
          page(
            items,
            %{
              state
              | "token" => next,
                "seen" => seen,
                "bound" => bound,
                "pages" => state["pages"] + 1
            },
            false
          )

        remaining != [] ->
          page(items, reply_state(remaining, state["continuation"], config), false)

        true ->
          advance(items, state["continuation"], config)
      end
    end
  end

  defp initial(config),
    do: %{
      "version" => 1,
      "team_id" => config["team_id"],
      "channel_id" => config["channel_id"],
      "stage" => "history",
      "token" => nil,
      "seen" => [],
      "pages" => 0,
      "bound" => nil
    }

  defp reply_state(threads, continuation, config),
    do:
      initial(config)
      |> Map.merge(%{"stage" => "replies", "threads" => threads, "continuation" => continuation})

  defp valid_state?(state, config) when is_map(state) do
    base =
      state["version"] == 1 and state["team_id"] == config["team_id"] and
        state["channel_id"] == config["channel_id"] and token?(state["token"]) and
        is_list(state["seen"]) and length(state["seen"]) <= @seen_limit and
        Enum.all?(state["seen"], &digest?/1) and is_integer(state["pages"]) and
        state["pages"] >= 0 and state["pages"] < @max_pages and
        (is_nil(state["bound"]) or timestamp?(state["bound"]))

    base and
      case state["stage"] do
        "history" ->
          C.keys(state, ~w(version team_id channel_id stage token seen pages bound))

        "replies" ->
          C.keys(
            state,
            ~w(version team_id channel_id stage token seen pages bound threads continuation)
          ) and
            is_list(state["threads"]) and length(state["threads"]) in 1..@size and
            Enum.all?(state["threads"], &timestamp?/1) and
            (is_nil(state["continuation"]) or
               (is_map(state["continuation"]) and state["continuation"]["stage"] == "history" and
                  valid_state?(state["continuation"], config)))

        _ ->
          false
      end
  end

  defp valid_state?(_, _), do: false

  defp workspace(%{"team" => %{"id" => team, "domain" => domain}}, config) do
    if team == config["team_id"] and is_binary(domain) and
         Regex.match?(~r/^[a-z0-9][a-z0-9-]{0,62}$/, domain),
       do: {:ok, domain},
       else: C.error("scope_violation")
  end

  defp workspace(_, _), do: C.error("invalid_provider_response")

  defp selected_channel(%{"channel" => channel}, config) when is_map(channel) do
    if channel["id"] == config["channel_id"] and channel["is_im"] != true and
         channel["is_mpim"] != true and
         (channel["is_channel"] == true or channel["is_group"] == true) and
         (is_nil(channel["context_team_id"]) or channel["context_team_id"] == config["team_id"]),
       do: :ok,
       else: C.error("scope_violation")
  end

  defp selected_channel(_, _), do: C.error("invalid_provider_response")

  defp document(message, config, id, domain, expected_thread) when is_map(message) do
    ts = message["ts"]
    thread = message["thread_ts"] || ts
    edited = if is_map(message["edited"]), do: message["edited"]["ts"], else: nil

    with true <- message["type"] == "message" and is_binary(message["text"]) and timestamp?(ts),
         true <- timestamp?(thread) and (is_nil(expected_thread) or thread == expected_thread),
         true <- is_nil(message["channel"]) or message["channel"] == config["channel_id"],
         true <- is_nil(edited) or timestamp?(edited),
         {:ok, updated} <- iso_timestamp(edited || ts) do
      kind = if thread == ts, do: "message", else: "reply"

      metadata = %{
        "team_id" => config["team_id"],
        "team_domain" => domain,
        "channel_id" => config["channel_id"],
        "kind" => kind,
        "message_ts" => ts,
        "thread_ts" => thread,
        "edited_ts" => edited,
        "normalizer_version" => "slack-v1"
      }

      {:ok,
       %{
         "external_id" => "slack:#{id}:#{config["channel_id"]}:#{ts}",
         "title" => "Slack #{config["channel_id"]} #{kind} #{ts}",
         "body" => message["text"],
         "source_url" =>
           "https://#{domain}.slack.com/archives/#{config["channel_id"]}/p#{String.replace(ts, ".", "")}",
         "source_updated_at" => updated,
         "metadata" => metadata
       }}
    else
      _ -> C.error("scope_violation")
    end
  end

  defp document(_, _, _, _, _), do: C.error("invalid_provider_response")

  defp threads(messages) do
    Enum.reduce_while(messages, {:ok, []}, fn message, {:ok, acc} ->
      count = Map.get(message, "reply_count", 0)

      if is_integer(count) and count >= 0 and count <= 100_000_000 do
        if count > 0 and (is_nil(message["thread_ts"]) or message["thread_ts"] == message["ts"]),
          do: {:cont, {:ok, [message["ts"] | acc]}},
          else: {:cont, {:ok, acc}}
      else
        {:halt, C.error("invalid_provider_response")}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, values |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  defp pagination(body, state, direction) do
    metadata = Map.get(body, "response_metadata", %{})
    next = if is_map(metadata), do: Map.get(metadata, "next_cursor", ""), else: :invalid
    next = if next == "", do: nil, else: next
    messages = body["messages"]
    more = Map.get(body, "has_more", false)
    seen = if state["token"], do: [hash(state["token"]) | state["seen"]], else: state["seen"]

    cond do
      body["is_limited"] == true ->
        C.error("history_limited")

      not is_boolean(more) or not token?(next) ->
        C.error("invalid_provider_response")

      more and is_nil(next) ->
        C.error("incomplete_history")

      not is_nil(next) and (next == state["token"] or hash(next) in seen) ->
        C.error("invalid_cursor")

      not is_nil(next) and messages == [] ->
        C.error("incomplete_history")

      state["pages"] + 1 >= @max_pages and not is_nil(next) ->
        C.error("pagination_limit")

      not ordered?(messages, state["bound"], direction) ->
        C.error("invalid_provider_response")

      true ->
        {:ok, next, Enum.take(seen, @seen_limit), last_ts(messages) || state["bound"]}
    end
  end

  defp ordered?(messages, bound, direction) do
    timestamps = Enum.map(messages, & &1["ts"])
    points = if bound, do: [bound | timestamps], else: timestamps

    Enum.chunk_every(points, 2, 1, :discard)
    |> Enum.all?(fn [a, b] ->
      if direction == :ascending, do: a < b, else: a > b
    end)
  end

  defp last_ts([]), do: nil
  defp last_ts(messages), do: List.last(messages)["ts"]
  defp nonempty_thread([]), do: C.error("incomplete_history")
  defp nonempty_thread(_), do: :ok

  defp get(method, params, headers, context) do
    case C.get("https://slack.com/api/" <> method, params, headers, context) do
      {:ok, %{"ok" => true} = body, _} -> {:ok, body}
      {:ok, %{"ok" => false, "error" => error}, response} -> slack_error(error, response)
      {:ok, _, _} -> C.error("invalid_provider_response")
      error -> error
    end
  end

  defp slack_error(error, response) do
    cond do
      error in @denied ->
        C.error("source_access_denied")

      error in ~w(ratelimited rate_limited) ->
        C.error("rate_limited", true, retry_after(response))

      error in ~w(internal_error fatal_error service_unavailable request_timeout) ->
        C.error("provider_unavailable", true)

      error == "invalid_cursor" ->
        C.error("invalid_cursor")

      error == "thread_not_found" ->
        C.error("incomplete_history")

      true ->
        C.error("provider_request_rejected")
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

  defp params(state, config) do
    base = %{channel: config["channel_id"], limit: @size}
    if state["token"], do: Map.put(base, :cursor, state["token"]), else: base
  end

  defp advance(items, nil, config), do: page(items, initial(config), true)
  defp advance(items, continuation, _), do: page(items, continuation, false)

  defp page(items, state, complete),
    do:
      {:ok, %{"items" => items, "next_cursor" => C.encode_cursor(state), "complete" => complete}}

  defp team?(value), do: is_binary(value) and Regex.match?(~r/^T[A-Z0-9]{2,31}$/, value)
  defp channel?(value), do: is_binary(value) and Regex.match?(~r/^[CG][A-Z0-9]{2,31}$/, value)

  defp timestamp?(value),
    do: is_binary(value) and Regex.match?(~r/^[1-9][0-9]{9}\.[0-9]{6}$/, value)

  defp token?(nil), do: true

  defp token?(value),
    do:
      is_binary(value) and byte_size(value) in 1..2048 and
        Regex.match?(~r/^[A-Za-z0-9_+\/=:-]+$/, value)

  defp digest?(value), do: is_binary(value) and Regex.match?(~r/^[A-Za-z0-9_-]{43}$/, value)
  defp hash(value), do: :crypto.hash(:sha256, value) |> Base.url_encode64(padding: false)

  defp iso_timestamp(value) do
    [seconds, micros] = String.split(value, ".")

    case DateTime.from_unix(
           String.to_integer(seconds) * 1_000_000 + String.to_integer(micros),
           :microsecond
         ) do
      {:ok, time} -> {:ok, DateTime.to_iso8601(time)}
      _ -> C.error("invalid_provider_response")
    end
  end
end
