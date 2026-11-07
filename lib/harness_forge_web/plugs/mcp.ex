defmodule HarnessForgeWeb.Plugs.MCP do
  @moduledoc "Bounded raw HTTP transport; sends all data while holding the workspace purge fence."
  @behaviour Plug

  import Plug.Conn

  alias HarnessForge.{Contracts, Privacy}
  alias HarnessForge.MCP.{Auth, Protocol}
  alias HarnessForge.Privacy.Purge

  @max_bytes 65_536

  @impl true
  def init(options), do: options

  @impl true
  def call(conn, _options) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    with :ok <- Auth.authorize(conn),
         :ok <- post_method(conn),
         :ok <- content_type(conn),
         :ok <- accepts_json_and_stream(conn),
         :ok <- content_length(conn),
         {:ok, body, conn} <- bounded_body(conn, ""),
         {:ok, request} <- decode(body),
         :ok <- protocol_version(conn, request) do
      fenced_dispatch(conn, request)
    else
      {:error, :disabled} -> failure(conn, 404, -32000, "MCP is disabled")
      {:error, :unauthorized} -> unauthorized(conn)
      {:error, :forbidden} -> failure(conn, 403, -32000, "Local request required")
      {:error, status, code, message} -> failure(conn, status, code, message)
      {:body_error, status, read_conn} -> failure(read_conn, status, -32700, "Invalid JSON body")
    end
  rescue
    _ -> failure(conn, 500, -32603, "Internal error")
  catch
    _, _ -> failure(conn, 500, -32603, "Internal error")
  end

  defp post_method(%{method: "POST"}), do: :ok

  defp post_method(_),
    do: {:error, 405, -32000, "Method not allowed"}

  defp content_type(conn) do
    with [type] <- get_req_header(conn, "content-type"),
         true <- byte_size(type) <= 256,
         {:ok, "application", "json", params} <- Plug.Conn.Utils.media_type(type),
         true <- valid_json_params?(params),
         encoding <- get_req_header(conn, "content-encoding"),
         true <- encoding in [[], ["identity"]] do
      :ok
    else
      _ -> {:error, 415, -32000, "JSON content type required"}
    end
  end

  defp valid_json_params?(params),
    do: params == %{} or params in [%{"charset" => "utf-8"}, %{"charset" => "UTF-8"}]

  defp accepts_json_and_stream(conn) do
    with [accept] <- get_req_header(conn, "accept"),
         true <- byte_size(accept) <= 1_024 do
      types =
        accept
        |> String.split(",")
        |> Enum.flat_map(&accepted_media_type/1)

      if {"application", "json"} in types and {"text", "event-stream"} in types,
        do: :ok,
        else: {:error, 406, -32000, "JSON and event-stream acceptance required"}
    else
      _ -> {:error, 406, -32000, "JSON and event-stream acceptance required"}
    end
  end

  defp accepted_media_type(value) do
    case Plug.Conn.Utils.media_type(String.trim(value)) do
      {:ok, type, subtype, params} ->
        quality = Map.get(params, "q", "1")

        if Regex.match?(~r/\A(?:0(?:\.\d{0,3})?|1(?:\.0{0,3})?)\z/, quality) and
             not Regex.match?(~r/\A0(?:\.0*)?\z/, quality),
           do: [{type, subtype}],
           else: []

      _ ->
        []
    end
  end

  defp content_length(conn) do
    case get_req_header(conn, "content-length") do
      [] -> :ok
      [length] -> declared_length(length)
      _ -> {:error, 400, -32600, "Invalid request length"}
    end
  end

  defp declared_length(length) when byte_size(length) <= 16 do
    if Regex.match?(~r/\A(?:0|[1-9][0-9]*)\z/, length) do
      case Integer.parse(length) do
        {value, ""} when value <= @max_bytes -> :ok
        _ -> {:error, 413, -32000, "Request is too large"}
      end
    else
      {:error, 400, -32600, "Invalid request length"}
    end
  end

  defp declared_length(_), do: {:error, 400, -32600, "Invalid request length"}

  defp bounded_body(conn, accumulated) do
    case read_body(conn, length: @max_bytes - byte_size(accumulated) + 1, read_timeout: 5_000) do
      {state, chunk, next_conn} when state in [:ok, :more] ->
        bytes = accumulated <> chunk

        cond do
          byte_size(bytes) > @max_bytes -> {:body_error, 413, next_conn}
          state == :more -> bounded_body(next_conn, bytes)
          true -> {:ok, bytes, next_conn}
        end

      {:error, _} ->
        {:body_error, 400, conn}
    end
  end

  defp decode(bytes) do
    case Contracts.decode_json(bytes) do
      {:ok, request} -> {:ok, request}
      _ -> {:error, 400, -32700, "Invalid JSON body"}
    end
  end

  defp protocol_version(conn, request) do
    case get_req_header(conn, "mcp-protocol-version") do
      [version] when version == "2025-11-25" -> :ok
      [] -> initialization_without_version(request)
      _ -> {:error, 400, -32000, "Unsupported protocol version"}
    end
  end

  defp initialization_without_version(%{"method" => "initialize"}), do: :ok

  defp initialization_without_version(_),
    do: {:error, 400, -32000, "Protocol version header required"}

  defp fenced_dispatch(conn, request) do
    case Purge.synchronize(fn -> dispatch_authorized(conn, request) end) do
      %Plug.Conn{} = sent -> sent
      _ -> failure(conn, 503, -32000, "Workspace is temporarily unavailable")
    end
  end

  defp dispatch_authorized(conn, request) do
    with :ok <- Auth.authorize(conn),
         :ok <- Privacy.ready() do
      case Protocol.handle(request) do
        {:reply, response} -> send_json(conn, 200, response)
        :accepted_notification -> conn |> send_resp(202, "") |> halt()
        {:reject, status, response} -> send_json(conn, status, response)
      end
    else
      {:error, :disabled} -> failure(conn, 404, -32000, "MCP is disabled")
      {:error, :unauthorized} -> unauthorized(conn)
      {:error, :forbidden} -> failure(conn, 403, -32000, "Local request required")
      _ -> failure(conn, 503, -32000, "Workspace is temporarily unavailable")
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_resp_header("www-authenticate", "Bearer")
    |> failure(401, -32000, "Machine authorization required")
  end

  defp send_json(conn, status, response) do
    encoded = Jason.encode!(response)

    if byte_size(encoded) <= @max_bytes do
      conn |> put_resp_content_type("application/json") |> send_resp(status, encoded) |> halt()
    else
      failure(conn, 500, -32000, "Response exceeds the permitted size", response["id"])
    end
  end

  defp failure(conn, status, code, message, id \\ nil) do
    response = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => code, "message" => message}
    }

    conn = if status == 405, do: put_resp_header(conn, "allow", "POST"), else: conn

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(response))
    |> halt()
  end
end
