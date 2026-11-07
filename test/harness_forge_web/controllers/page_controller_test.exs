defmodule HarnessForgeWeb.PageControllerTest do
  use HarnessForgeWeb.ConnCase

  test "GET / requires an operator session", %{conn: conn} do
    conn = %{conn | host: "localhost", port: 4002} |> get(~p"/")
    assert redirected_to(conn) == "/login"
  end
end
