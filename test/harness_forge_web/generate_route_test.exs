defmodule HarnessForgeWeb.GenerateRouteTest do
  use HarnessForgeWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias HarnessForgeWeb.Plugs.OperatorSession

  setup %{conn: conn}, do: %{conn: Map.merge(conn, %{host: "localhost", port: 4002})}

  test "an unauthenticated visit is sent to login", %{conn: conn} do
    assert redirected_to(get(conn, "/generate")) == "/login"
  end

  test "an operator session mounts the screen", %{conn: conn} do
    conn = init_test_session(conn, %{"operator_auth" => OperatorSession.new_auth()})
    assert {:ok, _view, html} = live(conn, "/generate")
    assert html =~ "Generate"
  end
end
