defmodule HarnessForge.Execution.RelayPlug do
  @moduledoc false
  import Plug.Conn
  alias HarnessForge.Execution.Relay
  alias HarnessForge.Models.{CodexProtocol, RuntimeProtocol}

  def init(opts), do: opts

  def call(conn, %{relay: relay}) do
    token =
      case get_req_header(conn, "authorization") do
        ["Bearer " <> value] -> value
        _ -> nil
      end

    cond do
      conn.method != "POST" or conn.request_path not in Relay.routes(relay) or
          conn.query_string != "" ->
        error(conn, 404, :route_unavailable)

      get_req_header(conn, "origin") != [] ->
        error(conn, 403, :browser_origin_denied)

      Relay.authorize(relay, token) != :ok ->
        error(conn, 401, :invalid_relay_capability)

      not json?(conn) ->
        error(conn, 415, :json_required)

      true ->
        with {:ok, bytes, conn} <-
               read_body(conn,
                 length: body_limit(conn.request_path),
                 read_length: 8192,
                 read_timeout: 5_000
               ),
             {:ok, body} <- Jason.decode(bytes),
             {:ok, response} <- dispatch(conn.request_path, relay, token, body) do
          reply(conn, response)
        else
          {:more, _, conn} -> error(conn, 413, :runtime_body_limit)
          {:error, reason} when is_atom(reason) -> error(conn, status(reason), reason)
          _ -> error(conn, 400, :invalid_runtime_request)
        end
    end
  catch
    :exit, _ -> error(conn, 503, :relay_unavailable)
  end

  defp body_limit("/v1/responses"), do: CodexProtocol.body_limit()
  defp body_limit("/v1/command-approvals"), do: 32_768
  defp body_limit(_), do: RuntimeProtocol.body_limit()
  defp dispatch("/v1/responses", relay, token, body), do: Relay.responses(relay, token, body)
  defp dispatch("/v1/chat/completions", relay, token, body), do: Relay.chat(relay, token, body)

  defp dispatch("/v1/command-approvals", relay, token, body),
    do: Relay.command_approvals(relay, token, body)

  defp json?(conn) do
    case get_req_header(conn, "content-type") do
      [value] -> hd(String.split(value, ";")) == "application/json"
      _ -> false
    end
  end

  defp reply(conn, {:json, body}),
    do:
      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(200, Jason.encode!(body))

  defp reply(conn, {:sse, body}),
    do:
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(200, body)

  defp error(conn, code, reason),
    do:
      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(
        code,
        Jason.encode!(%{
          "error" => %{
            "type" => "harnessforge_relay_error",
            "code" => Atom.to_string(reason),
            "message" => Atom.to_string(reason)
          }
        })
      )

  defp status(reason) when reason in [:budget_exhausted, :relay_turn_limit], do: 429

  defp status(:invalid_runtime_request), do: 400
  defp status(:invalid_runtime_response), do: 502

  defp status(:source_unavailable), do: 403
  defp status(:revision_use_denied), do: 403
  defp status(_), do: 503
end
