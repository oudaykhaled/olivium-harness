defmodule HarnessForgeWeb.VerificationTest do
  use HarnessForgeWeb.ConnCase, async: false
  alias HarnessForge.Contracts
  alias HarnessForgeWeb.Plugs.OperatorSession

  @manifest Path.expand("../../priv/showcase/recordings.json", __DIR__)
            |> File.read!()
            |> Jason.decode!()

  setup do
    # Always a private directory, so results do not depend on whether this
    # machine happens to have the separately distributed recordings.
    media = Path.join(System.tmp_dir!(), "verification-media-#{Ecto.UUID.generate()}")
    File.mkdir_p!(media)
    Application.put_env(:harness_forge, :verification_media_dir, media)

    on_exit(fn ->
      Application.delete_env(:harness_forge, :verification_media_dir)
      Application.delete_env(:harness_forge, :verification_recordings)
      File.rm_rf!(media)
    end)

    {:ok, media: media}
  end

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
    conn = operator(conn)
    page = get(conn, "/verification")
    body = html_response(page, 200)
    assert body =~ "WEB20 / WEB21 / WEB22 / WEB23 / WEB25"
    assert body =~ "Screenshots — unavailable"
    assert body =~ "Benefit not proven"
    assert body =~ "Task failed"
    assert body =~ "Qwen2.5:7b-instruct-q4_K_M"
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
    assert body =~ "Clamp passed · ReverseWords failed"
    assert body =~ "Invalid Go rejected · task failed"
    refute Map.has_key?(data, "operator_auth")
    refute Map.has_key?(data, "workspace_id")

    assert get_resp_header(report, "content-disposition") ==
             [~s(attachment; filename="harnessforge-web-evidence.json")]
  end

  test "a checkout without the recordings shows them as unavailable, offers no player and serves nothing",
       %{conn: conn} do
    conn = operator(conn)
    body = html_response(get(conn, "/verification"), 200)
    tree = LazyHTML.from_document(body)

    refute body =~ "<video"

    for %{"id" => id} <- @manifest do
      assert LazyHTML.query(tree, "#verification-unavailable-#{id}") |> Enum.count() == 1
      assert response(get(conn, "/verification/media/#{id}"), 404) == "Recording unavailable"
    end
  end

  test "present recordings get a player and are served after their digest is checked", %{
    conn: conn,
    media: media
  } do
    conn = operator(conn)
    recordings = install_synthetic(media)
    body = html_response(get(conn, "/verification"), 200)
    tree = LazyHTML.from_document(body)

    assert body =~ "<video"

    assert LazyHTML.query(tree, "#verification-featured-company-generation source")
           |> LazyHTML.attribute("src") == ["/verification/media/company-generation"]

    refute LazyHTML.query(tree, "#verification-more-runs[open]") |> Enum.any?()

    for id <- ~w(real-harness task04-partial task05-code-rejected) do
      assert LazyHTML.query(tree, "#verification-more-runs #verification-earlier-#{id}")
             |> Enum.count() == 1

      assert LazyHTML.query(tree, "#verification-featured-#{id}") |> Enum.empty?()
    end

    for %{"id" => id} = video <- recordings do
      assert LazyHTML.query(tree, "#verification-unavailable-#{id}") |> Enum.empty?()
      response = get(conn, "/verification/media/#{id}")
      assert response.status == 200
      assert response.resp_body == File.read!(Path.join(media, id <> ".webm"))
      assert byte_size(response.resp_body) == video["bytes"]
      assert Contracts.sha256(response.resp_body) == video["sha256"]
      assert get_resp_header(response, "cache-control") == ["no-store"]
      assert get_resp_header(response, "content-type") == ["video/webm; charset=utf-8"]
      assert get_resp_header(response, "x-content-type-options") == ["nosniff"]
    end

    assert response(get(conn, "/verification/media/unknown"), 404) == "Recording unavailable"
  end

  test "a tampered, resized or missing recording is refused and only a matching size gets a player",
       %{conn: conn, media: media} do
    conn = operator(conn)
    [tampered, resized, missing | _] = install_synthetic(media)

    path = &Path.join(media, &1["id"] <> ".webm")
    # Same length, different bytes: only the digest can catch this.
    File.write!(path.(tampered), String.duplicate("x", tampered["bytes"]))
    File.write!(path.(resized), "short")
    File.rm!(path.(missing))

    tree = conn |> get("/verification") |> html_response(200) |> LazyHTML.from_document()

    assert LazyHTML.query(tree, "#verification-unavailable-#{tampered["id"]}") |> Enum.empty?()

    for video <- [resized, missing] do
      assert LazyHTML.query(tree, "#verification-unavailable-#{video["id"]}") |> Enum.count() == 1
    end

    for video <- [tampered, resized, missing] do
      assert response(get(conn, "/verification/media/#{video["id"]}"), 404) ==
               "Recording unavailable"
    end
  end

  test "the request path cannot name a file outside the manifest", %{conn: conn, media: media} do
    conn = operator(conn)
    install_synthetic(media)
    File.write!(Path.join(media, "unlisted.webm"), "not in the manifest")

    for id <- ["unlisted", "..%2Funlisted", "..%2F..%2Fmix"] do
      assert response(get(conn, "/verification/media/#{id}"), 404) == "Recording unavailable"
    end
  end

  defp operator(conn) do
    conn
    |> Map.merge(%{host: "localhost", port: 4002})
    |> init_test_session(%{"operator_auth" => OperatorSession.new_auth()})
  end

  # Synthetic bytes under the published ids, with a manifest that matches them.
  defp install_synthetic(media) do
    recordings =
      Enum.map(@manifest, fn entry ->
        bytes = "synthetic recording for " <> entry["id"]
        File.write!(Path.join(media, entry["id"] <> ".webm"), bytes)
        %{entry | "bytes" => byte_size(bytes), "sha256" => Contracts.sha256(bytes)}
      end)

    Application.put_env(:harness_forge, :verification_recordings, recordings)
    recordings
  end
end
