defmodule HarnessForgeWeb.SessionController do
  use HarnessForgeWeb, :controller
  alias HarnessForge.Workspaces
  alias HarnessForgeWeb.Plugs.OperatorSession

  def new(conn, _params) do
    if OperatorSession.valid?(get_session(conn, "operator_auth")) do
      redirect(conn, to: ~p"/")
    else
      render_login(conn, nil)
    end
  end

  def create(conn, %{"access_code" => code}) when is_binary(code) and byte_size(code) <= 256 do
    if Plug.Crypto.secure_compare(String.trim(code), Workspaces.access_token()) do
      Plug.CSRFProtection.delete_csrf_token()

      conn
      |> configure_session(renew: true)
      |> clear_session()
      |> put_session("operator_auth", OperatorSession.new_auth())
      |> redirect(to: ~p"/")
    else
      conn |> put_status(:unauthorized) |> render_login("The access code is incorrect.")
    end
  end

  def create(conn, _params),
    do: conn |> put_status(:unauthorized) |> render_login("Enter a valid access code.")

  def delete(conn, _params) do
    if OperatorSession.valid?(get_session(conn, "operator_auth")),
      do: Workspaces.rotate_session_epoch()

    conn |> configure_session(drop: true) |> redirect(to: ~p"/login")
  end

  defp render_login(conn, error) do
    render(conn, :new,
      error: error,
      access_path: Path.join(Workspaces.root(), "access-token"),
      page_title: "Unlock workspace"
    )
  end
end
