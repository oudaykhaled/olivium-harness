defmodule HarnessForge.MCP.Auth do
  @moduledoc "Independent, opt-in machine authentication for the local MCP endpoint."

  import Plug.Conn, only: [get_peer_data: 1, get_req_header: 2]

  @reference ~r/\A[A-Z_][A-Z0-9_]{0,127}\z/
  @token ~r/\A[A-Za-z0-9_-]{43,256}\z/

  @spec authorize(Plug.Conn.t()) :: :ok | {:error, :disabled | :unauthorized | :forbidden}
  def authorize(conn) do
    cond do
      Application.get_env(:harness_forge, :mcp_enabled) != true -> {:error, :disabled}
      not local_request?(conn) -> {:error, :forbidden}
      valid_credential?(conn) -> :ok
      true -> {:error, :unauthorized}
    end
  rescue
    _ -> {:error, :unauthorized}
  end

  defp local_request?(conn) do
    allowed = Application.get_env(:harness_forge, :allowed_origins, [])
    origin = "#{conn.scheme}://#{conn.host}:#{conn.port}"

    loopback?(get_peer_data(conn).address) and is_list(allowed) and origin in allowed and
      valid_host_header?(conn) and valid_origin?(get_req_header(conn, "origin"), allowed)
  end

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_), do: false

  defp valid_host_header?(conn) do
    explicit = "#{conn.host}:#{conn.port}"
    implicit = if conn.port == default_port(conn.scheme), do: conn.host, else: explicit

    case get_req_header(conn, "host") do
      [] -> true
      [host] -> host in [explicit, implicit]
      _ -> false
    end
  end

  defp default_port(:http), do: 80
  defp default_port(:https), do: 443

  defp valid_origin?([], _allowed), do: true
  defp valid_origin?([origin], allowed), do: origin in allowed
  defp valid_origin?(_, _allowed), do: false

  defp valid_credential?(conn) do
    with reference when is_binary(reference) <-
           Application.get_env(:harness_forge, :mcp_token_env),
         true <- byte_size(reference) <= 128 and Regex.match?(@reference, reference),
         expected when is_binary(expected) <- System.get_env(reference),
         true <- valid_token?(expected),
         ["Bearer " <> supplied] <- get_req_header(conn, "authorization"),
         true <- valid_token?(supplied) do
      Plug.Crypto.secure_compare(:crypto.hash(:sha256, expected), :crypto.hash(:sha256, supplied))
    else
      _ -> false
    end
  end

  defp valid_token?(token),
    do: byte_size(token) in 43..256 and Regex.match?(@token, token)
end
