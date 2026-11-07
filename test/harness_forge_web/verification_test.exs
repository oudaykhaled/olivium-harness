defmodule HarnessForgeWeb.VerificationTest do
  use HarnessForgeWeb.ConnCase, async: false
  alias HarnessForgeWeb.Plugs.OperatorSession

  test "evidence page and report require the normal workspace session", %{conn: conn} do
    conn = %{conn | host: "localhost", port: 4002}
    assert redirected_to(get(conn, "/verification")) == "/login"
    assert redirected_to(get(conn, "/verification/report")) == "/login"
  end

  test "recorded results distinguish browser proof, missing images and unproved task benefit", %{
    conn: conn
  } do
    conn =
      conn
      |> Map.merge(%{host: "localhost", port: 4002})
      |> init_test_session(%{"operator_auth" => OperatorSession.new_auth()})

    page = get(conn, "/verification")
    body = html_response(page, 200)
    assert body =~ "WEB16"
    assert body =~ "Screenshots — unavailable"
    assert body =~ "No current screenshots or videos"
    assert body =~ "not demonstrated"
    assert body =~ "scripted provider"
    refute body =~ "<img"
    assert get_resp_header(page, "cache-control") == ["no-store"]
    report = get(conn, "/verification/report")
    data = json_response(report, 200)
    assert data["screenshots"]["available"] == false
    assert length(data["browser_checks"]) == 4
    assert data["recorded_release"] == "WEB16"
    refute Map.has_key?(data, "operator_auth")
    refute Map.has_key?(data, "workspace_id")

    assert get_resp_header(report, "content-disposition") ==
             [~s(attachment; filename="harnessforge-web-evidence.json")]
  end
end
