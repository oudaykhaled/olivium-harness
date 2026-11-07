defmodule HarnessForgeWeb.Plugs.LocalOrigin do
  @moduledoc "Exact local Host and browser-origin guard, including socket upgrades."
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    allowed = Application.fetch_env!(:harness_forge, :allowed_origins)

    request_origin = origin(to_string(conn.scheme), conn.host, conn.port)

    origins = get_req_header(conn, "origin")

    valid_host = request_origin in allowed
    valid_origin = origins == [] or (length(origins) == 1 and hd(origins) in allowed)

    valid_write =
      conn.method in ["GET", "HEAD", "OPTIONS"] or
        (length(origins) == 1 and hd(origins) in allowed) or
        (origins == [] and valid_referer?(get_req_header(conn, "referer"), allowed))

    if valid_host and valid_origin and valid_write do
      conn
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(403, "Local origin required")
      |> halt()
    end
  end

  defp valid_referer?([referer], allowed) do
    uri = URI.parse(referer)
    origin(uri.scheme, uri.host, uri.port) in allowed
  end

  defp valid_referer?(_, _), do: false

  defp origin(scheme, host, port)
       when scheme in ["http", "https"] and is_binary(host) and is_integer(port),
       do: scheme <> "://" <> host <> ":" <> Integer.to_string(port)

  defp origin(_, _, _), do: nil

  # Phoenix socket dispatch precedes endpoint plugs, so wrap the endpoint call.
  defmacro __before_compile__(_env) do
    quote do
      defoverridable call: 2

      def call(conn, opts) do
        if conn.request_path == "/mcp" do
          HarnessForgeWeb.Plugs.MCP.call(conn, [])
        else
          case HarnessForgeWeb.Plugs.LocalOrigin.call(conn, []) do
            %{halted: true} = rejected -> rejected
            allowed -> super(allowed, opts)
          end
        end
      end
    end
  end
end
