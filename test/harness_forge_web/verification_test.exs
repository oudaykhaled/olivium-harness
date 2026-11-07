defmodule HarnessForgeWeb.VerificationTest do
  use HarnessForgeWeb.ConnCase, async: false
  alias HarnessForgeWeb.Plugs.OperatorSession

  test "evidence page and report require the normal workspace session", %{conn: conn} do
    conn = %{conn | host: "localhost", port: 4002}
    assert redirected_to(get(conn, "/verification")) == "/login"
    assert redirected_to(get(conn, "/verification/report")) == "/login"
    assert redirected_to(get(conn, "/verification/media/real-harness")) == "/login"
    assert redirected_to(get(conn, "/verification/media/company-generation")) == "/login"
    assert redirected_to(get(conn, "/verification/media/task04-partial")) == "/login"
    assert redirected_to(get(conn, "/verification/media/source-change-recovery")) == "/login"
    assert redirected_to(get(conn, "/verification/media/task05-code-rejected")) == "/login"
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
    assert body =~ "WEB20 / WEB21 / WEB22 / WEB23 / WEB25"
    assert body =~ "Screenshots — unavailable"
    assert body =~ "Benefit not proven"
    assert body =~ "Task failed"
    assert body =~ "Qwen2.5:7b-instruct-q4_K_M"
    assert body =~ "<video"
    refute body =~ "<img"
    assert get_resp_header(page, "cache-control") == ["no-store"]
    report = get(conn, "/verification/report")
    data = json_response(report, 200)
    assert data["screenshots"]["available"] == false
    assert length(data["browser_checks"]) == 9
    assert data["recorded_release"] == "WEB20 / WEB21 / WEB22 / WEB23 / WEB25"
    assert length(data["recordings"]) == 12

    assert data["recordings"] |> Enum.take(3) |> Enum.map(& &1["id"]) == [
             "company-generation",
             "source-change-recovery",
             "github-sync"
           ]

    assert data["harness_digest"] ==
             "4025ce80fa4c24ae70aed92061f4efb455d38cdc99b2f4ddde58108175edcc3e"

    assert data["generation_route"] == "Normal Company UI build and browser ZIP download verified"
    assert data["benefit"] == "Not demonstrated"
    assert data["paired_comparison"] == "Both failed · one public-PR diagnostic pair"
    assert data["paired_results"]["comparable"]
    refute data["paired_results"]["qualified"]
    assert data["paired_results"]["sample_count"] == 1

    assert Enum.all?(
             data["recordings"],
             &(&1["human_only"] == true && &1["model_visual_review"] == false)
           )

    assert data["download_payloads_verified"] == 8
    assert data["mcp_sdk_checks"] == 14
    assert data["mcp_positive_metadata_checks"] == 7
    assert data["source_recovery"]["stale_delivery"] == "denied"
    assert data["source_recovery"]["model_requests"] == 0
    assert data["source_recovery"]["successor_payloads_verified"] == 8
    assert data["github_live"]["records"] == 21
    assert data["github_live"]["unchanged_resync"]
    assert body =~ "verification-more-runs"
    tree = LazyHTML.from_document(body)

    assert LazyHTML.query(tree, "#verification-featured-company-generation source")
           |> LazyHTML.attribute("src") == ["/verification/media/company-generation"]

    refute LazyHTML.query(tree, "#verification-more-runs[open]") |> Enum.any?()

    for id <- ~w(real-harness task04-partial task05-code-rejected) do
      assert LazyHTML.query(tree, "#verification-more-runs #verification-earlier-#{id}")
             |> Enum.count() == 1

      assert LazyHTML.query(tree, "#verification-featured-#{id}") |> Enum.empty?()
    end

    assert body =~ "Clamp passed · ReverseWords failed"
    assert body =~ "Invalid Go rejected · task failed"
    refute Map.has_key?(data, "operator_auth")
    refute Map.has_key?(data, "workspace_id")

    assert get_resp_header(report, "content-disposition") ==
             [~s(attachment; filename="harnessforge-web-evidence.json")]

    for video <- data["recordings"] do
      response = get(conn, "/verification/media/#{video["id"]}")
      assert response.status == 200
      assert byte_size(response.resp_body) == video["bytes"]
      assert HarnessForge.Contracts.sha256(response.resp_body) == video["sha256"]
      assert get_resp_header(response, "cache-control") == ["no-store"]
      assert get_resp_header(response, "content-type") == ["video/webm; charset=utf-8"]
    end

    assert response(get(conn, "/verification/media/unknown"), 404) == "Recording unavailable"
  end
end
