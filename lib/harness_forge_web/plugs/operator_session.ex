defmodule HarnessForgeWeb.Plugs.OperatorSession do
  @moduledoc "Workspace- and process-bound local operator authentication."
  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]
  import Phoenix.LiveView, only: [attach_hook: 4]
  alias HarnessForge.{Contracts, Workspaces}

  def init(opts), do: opts

  def call(conn, _opts) do
    if valid?(get_session(conn, "operator_auth")) do
      conn
    else
      conn |> clear_session() |> redirect(to: "/login") |> halt()
    end
  end

  def new_auth do
    %{
      "workspace_id" => Workspaces.current_id(),
      "epoch" => Workspaces.session_epoch(),
      "issued_at" => System.system_time(:second)
    }
  end

  def valid?(auth), do: match?({:ok, _}, Workspaces.authenticate_operator(auth))

  @doc "Builds a caller from trusted session state and server-owned view identity."
  def source_caller(auth, view_generation, reset_token)
      when is_binary(view_generation) and byte_size(view_generation) == 32 and
             is_integer(reset_token) and reset_token >= 0 do
    with {:ok, _} <- Workspaces.authenticate_operator(auth),
         true <- String.match?(view_generation, ~r/\A[0-9a-f]{32}\z/) do
      {:ok,
       [
         authorize: fn -> valid?(auth) end,
         session_fingerprint: Contracts.digest(auth),
         view_generation: view_generation,
         reset_token: reset_token
       ]}
    else
      _ -> {:error, :operator_session_revoked}
    end
  end

  def source_caller(_, _, _), do: {:error, :operator_session_revoked}

  def on_mount(:operator, _params, session, socket) do
    auth = session["operator_auth"]

    if valid?(auth) do
      socket =
        socket
        |> Phoenix.Component.assign(:operator_auth, auth)
        |> attach_hook(:authenticate_event, :handle_event, &authenticate_event/3)

      {:cont, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: "/login")}
    end
  end

  defp authenticate_event(_event, _params, socket) do
    if valid?(socket.assigns.operator_auth) do
      {:cont, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: "/login")}
    end
  end
end
