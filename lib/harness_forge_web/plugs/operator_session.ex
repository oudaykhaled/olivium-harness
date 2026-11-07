defmodule HarnessForgeWeb.Plugs.OperatorSession do
  @moduledoc "Workspace- and process-bound local operator authentication."
  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]
  import Phoenix.LiveView, only: [attach_hook: 4]
  alias HarnessForge.Workspaces

  @max_age 43_200

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

  def valid?(%{"workspace_id" => id, "epoch" => epoch, "issued_at" => issued})
      when is_binary(epoch) and is_integer(issued) do
    age = System.system_time(:second) - issued

    id == Workspaces.current_id() and age >= 0 and age < @max_age and
      Plug.Crypto.secure_compare(epoch, Workspaces.session_epoch())
  end

  def valid?(_), do: false

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
