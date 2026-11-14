defmodule HarnessForgeWeb.PortalTest do
  use HarnessForgeWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias HarnessForge.{Evidence, Decisions, Workspaces}
  alias HarnessForgeWeb.Plugs.OperatorSession

  setup %{conn: conn} do
    {:ok, conn: %{conn | host: "localhost", port: 4002}}
  end

  test "login shows the credential file location without exposing its contents", %{conn: conn} do
    conn = get(conn, "/login")
    html = html_response(conn, 200)
    assert html =~ "Unlock Olivium Harness"
    assert html =~ "access-token"
    assert html =~ ~s(name="_csrf_token")
    refute html =~ Workspaces.access_token()
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "valid access code renews the session and invalid credentials stay locked", %{conn: conn} do
    bad = login(conn, "incorrect-code")
    assert html_response(bad, 401) =~ "access code is incorrect"
    refute get_session(bad, "operator_auth")

    good = login(conn, Workspaces.access_token())
    assert redirected_to(good) == "/"
    assert OperatorSession.valid?(get_session(good, "operator_auth"))
    refute inspect(get_session(good)) =~ Workspaces.access_token()
    cookie = get_resp_header(good, "set-cookie") |> Enum.join()
    assert cookie =~ "HttpOnly"
    assert cookie =~ "SameSite=Strict"
  end

  test "login requires a CSRF token even with a correct access code", %{conn: conn} do
    conn =
      conn
      |> put_req_header("origin", "http://localhost:4002")
      |> put_private(:plug_skip_csrf_protection, false)

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      post(conn, "/login", %{"access_code" => Workspaces.access_token()})
    end
  end

  test "locking the workspace revokes every open tab and old session", %{conn: conn} do
    auth = OperatorSession.new_auth()
    session = init_test_session(conn, %{"operator_auth" => auth})
    {:ok, first, _} = live(session, "/")
    {:ok, second, _} = live(session, "/")

    response = session |> put_req_header("origin", "http://localhost:4002") |> delete("/session")
    assert redirected_to(response) == "/login"
    refute OperatorSession.valid?(auth)
    assert_redirect(first, "/login")
    assert_redirect(second, "/login")
    assert {:error, {:redirect, %{to: "/login"}}} = live(session, "/")
  end

  test "foreign or missing browser origins and DNS-rebinding hosts are rejected", %{conn: conn} do
    assert conn
           |> put_req_header("origin", "https://foreign.example")
           |> get("/login")
           |> response(403)

    assert %{conn | host: "rebound.example"} |> get("/login") |> response(403)
    assert %{conn | host: "rebound.example"} |> get("/live/websocket") |> response(403)
    assert conn |> post("/login", %{"access_code" => "x"}) |> response(403)

    assert conn
           |> put_req_header("origin", "http://localhost:4002.evil.example")
           |> get("/login")
           |> response(403)
  end

  test "unauthenticated and cross-workspace sessions cannot mount the portal", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, "/")

    invalid = OperatorSession.new_auth() |> Map.put("workspace_id", "another-workspace")
    invalid_conn = init_test_session(conn, %{"operator_auth" => invalid})
    assert {:error, {:redirect, %{to: "/login"}}} = live(invalid_conn, "/")

    old = OperatorSession.new_auth() |> Map.put("epoch", "previous-process-epoch")

    assert {:error, {:redirect, %{to: "/login"}}} =
             live(init_test_session(conn, %{"operator_auth" => old}), "/")
  end

  @tag :decision_focus
  test "portal offers working review flow and only approves the displayed revision", %{conn: conn} do
    claim = proposal()
    {:ok, view, _} = live(authenticated(conn), "/")
    html = view |> element("#nav-evidence") |> render_click()
    assert html =~ "Evidence, with a paper trail."
    assert html =~ claim["text"]

    render_click(view, "decide", %{
      "id" => claim["id"],
      "decision" => "approve",
      "revision" => "stale"
    })

    assert has_element?(view, "#error", "revision changed")
    assert {:ok, %{"status" => "proposed"}} = Evidence.get_claim(claim["id"])

    view |> element("#approve-#{claim["id"]}") |> render_click()
    assert_push_event(view, "company-focus", %{id: "evidence-panel"})
    assert has_element?(view, "#claim-#{claim["id"]} .approved", "APPROVED")
    assert {:ok, %{"status" => "approved"}} = Evidence.get_claim(claim["id"])
    refute has_element?(view, "#approve-#{claim["id"]}")

    assert {:error, :already_decided} =
             Decisions.decide(claim["id"], %{
               "actor" => "operator",
               "decision" => "reject",
               "expected_revision_hash" => claim["revision_hash"]
             })
  end

  @tag :decision_focus
  test "rejecting an exact claim keeps keyboard review focus", %{conn: conn} do
    claim = proposal()
    {:ok, view, _} = live(authenticated(conn), "/")
    view |> element("#nav-evidence") |> render_click()

    view |> element("#reject-#{claim["id"]}") |> render_click()

    assert {:ok, %{"status" => "rejected"}} = Evidence.get_claim(claim["id"])
    refute has_element?(view, "#reject-#{claim["id"]}")
    assert_push_event(view, "company-focus", %{id: "evidence-panel"})
  end

  test "event authentication is rechecked after the application session is invalidated", %{
    conn: conn
  } do
    {:ok, view, _} = live(authenticated(conn), "/")
    old_state = :sys.get_state(Workspaces)
    :sys.replace_state(Workspaces, &%{&1 | epoch: "revoked-session"})
    on_exit(fn -> :sys.replace_state(Workspaces, fn _ -> old_state end) end)

    assert {:error, {:redirect, %{to: "/login"}}} = render_click(view, "demo")
    assert {:ok, []} = Evidence.list_claims()
  end

  test "package qualification and evaluation modes are explicit", %{conn: conn} do
    {:ok, view, _} = live(authenticated(conn), "/")
    view |> element("#nav-package") |> render_click()
    assert has_element?(view, "#build-form")
    assert has_element?(view, "#runtime-version[value=unqualified]")
    view |> element("#nav-evaluations") |> render_click()
    assert has_element?(view, "#evaluation-form")
    assert has_element?(view, "#evaluation-kind option[value=task]", "model-backed tasks")
    assert render(view) =~ "Blocked runs remain visible and cannot approve a release"
    assert render(view) =~ "never executed on this host"
  end

  test "claim proposal binds the selected source snapshot and escapes source HTML", %{conn: conn} do
    claim = proposal()
    {:ok, sources} = Evidence.list_sources()
    source = hd(sources)
    {:ok, view, _} = live(authenticated(conn), "/")
    view |> element("#nav-evidence") |> render_click()

    view
    |> form("#propose-form",
      claim: %{
        source_snapshot: source["id"] <> ":" <> source["latest_revision"]["id"],
        text: "A second deliberate claim"
      }
    )
    |> render_submit()

    assert {:ok, claims} = Evidence.list_claims()
    assert length(claims) == 2
    assert Enum.all?(claims, &(&1["status"] == "proposed"))
    assert has_element?(view, "#claim-#{claim["id"]}")
    refute render(view) =~ "<script>alert"
  end

  test "active evaluation refresh and comparison use recorded context results", %{conn: conn} do
    claim = proposal()

    {:ok, _} =
      Decisions.decide(claim["id"], %{
        "actor" => Workspaces.operator(),
        "decision" => "approve",
        "expected_revision_hash" => claim["revision_hash"]
      })

    {:ok, artifact} = HarnessForge.Harnesses.build()
    {:ok, view, _} = live(authenticated(conn), "/")
    view |> element("#nav-evaluations") |> render_click()
    {:ok, baseline} = HarnessForge.Evaluations.run(artifact["digest"], kind: :static_integrity)
    {:ok, candidate} = HarnessForge.Evaluations.run(artifact["digest"], kind: :static_integrity)
    send(view.pid, :refresh_evaluations)
    assert has_element?(view, "#run-#{candidate["id"]}", "PASS")
    refute has_element?(view, "#run-#{candidate["id"]} button")
    refute has_element?(view, "#evaluation-comparison[open]")

    view
    |> form("#comparison-form", comparison: %{baseline: baseline["id"], candidate: ""})
    |> render_change()

    assert has_element?(view, "#comparison-candidate option[value='#{baseline["id"]}'][disabled]")

    render_submit(view, "compare_runs", %{
      "comparison" => %{"baseline" => baseline["id"], "candidate" => baseline["id"]}
    })

    assert has_element?(view, "#error", "Choose two different evaluation records")
    refute has_element?(view, "#comparison-result")

    view
    |> form("#comparison-form",
      comparison: %{baseline: baseline["id"], candidate: candidate["id"]}
    )
    |> render_submit()

    assert has_element?(view, "#comparison-result", "Qualified pair: false")
    assert has_element?(view, "#evaluation-comparison[open]")
    render_click(view, "cancel_run", %{"id" => baseline["id"]})
    assert {:ok, ^baseline} = HarnessForge.Evaluations.get(baseline["id"])
  end

  test "Checks leads with the recorded failure and exact evidence instead of generic completion",
       %{conn: conn} do
    claim = proposal()

    {:ok, _} =
      Decisions.decide(claim["id"], %{
        "actor" => Workspaces.operator(),
        "decision" => "approve",
        "expected_revision_hash" => claim["revision_hash"]
      })

    {:ok, artifact} = HarnessForge.Harnesses.build()
    {:ok, run} = HarnessForge.Evaluations.run(artifact["digest"], kind: :static_integrity)

    # Presentation fixture only: this failed record does not establish agent execution.
    failed =
      Map.merge(run, %{
        "outcome" => "failed",
        "reason" => nil,
        "completed_at" => "2026-11-04T15:30:00Z"
      })

    HarnessForge.Repo.query!("UPDATE evaluation_runs SET result=? WHERE id=?", [
      Jason.encode!(failed),
      run["id"]
    ])

    session = authenticated(conn)
    path = "/?" <> URI.encode_query(%{"view" => "evaluations", "artifact" => artifact["digest"]})
    {:ok, view, html} = live(session, path)
    assert has_element?(view, "#run-#{run["id"]}[data-outcome=failed]", "FAIL")
    assert has_element?(view, "#run-#{run["id"]} time", "04 Nov 2026, 15:30 UTC")
    assert has_element?(view, "#run-#{run["id"]}", "Inspect the recorded code and test output")
    assert has_element?(view, "#evaluation-inspect-#{run["id"]}.primary")
    refute has_element?(view, "#evaluation-new-check[open]")
    refute has_element?(view, "#load-demo")

    assert elem(:binary.match(html, "id=\"run-#{run["id"]}\""), 0) <
             elem(:binary.match(html, "id=\"evaluation-new-check\""), 0)

    evidence =
      "/harnesses/" <> artifact["digest"] <> "?check=" <> run["id"] <> "#harness-check-details"

    assert has_element?(view, "#evaluation-inspect-#{run["id"]}[href='#{evidence}']")

    {:ok, details, _} =
      live(session, String.replace_suffix(evidence, "#harness-check-details", ""))

    assert has_element?(details, "#harness-check-details", "FAIL")

    send(
      view.pid,
      {:operation_finished,
       "Operation completed. Inspect the recorded outcome before continuing."}
    )

    html = render(view)
    refute html =~ "Operation completed"
    assert has_element?(view, "#run-#{run["id"]}[data-outcome=failed]", "FAIL")
  end

  test "ambiguous protected-test failure records stay neutral even when output exists", %{
    conn: conn
  } do
    claim = proposal()

    {:ok, _} =
      Decisions.decide(claim["id"], %{
        "actor" => Workspaces.operator(),
        "decision" => "approve",
        "expected_revision_hash" => claim["revision_hash"]
      })

    {:ok, artifact} = HarnessForge.Harnesses.build()
    {:ok, run} = HarnessForge.Evaluations.run(artifact["digest"], kind: :static_integrity)
    session = authenticated(conn)

    # Presentation fixtures only. Empty or nonempty logs cannot establish grading phase.
    for {objective_checks, grader_output, precise} <- [
          {"unverified", "", false},
          {"unverified", "recorded grader initialization output", false},
          {"failed", "recorded protected-test failure", true}
        ] do
      record =
        Map.merge(run, %{
          "kind" => "task",
          "outcome" => "failed",
          "reason" => "protected_tests_failed",
          "checks" => [
            %{
              "id" => "synthetic-copy-fixture",
              "outcome" => "failed",
              "evidence" => %{
                "objective_checks" => objective_checks,
                "grader_output" => grader_output,
                "solver_stopped" => true
              }
            }
          ]
        })

      HarnessForge.Repo.query!("UPDATE evaluation_runs SET result=? WHERE id=?", [
        Jason.encode!(record),
        run["id"]
      ])

      {:ok, view, html} = live(session, "/?view=evaluations")
      assert has_element?(view, "#run-#{run["id"]}[data-outcome=failed]", "FAIL")
      refute html =~ "before protected grading"

      if precise do
        assert has_element?(
                 view,
                 "#run-#{run["id"]}",
                 "The coding task failed its protected tests."
               )
      else
        assert has_element?(
                 view,
                 "#run-#{run["id"]}",
                 "Task failed. Inspect the code, agent output and recorded checks."
               )

        refute html =~ "failed its protected tests"
      end
    end
  end

  defp authenticated(conn),
    do: init_test_session(conn, %{"operator_auth" => OperatorSession.new_auth()})

  defp login(conn, code) do
    login_page = get(conn, "/login")

    [_, token] =
      Regex.run(~r/name="_csrf_token"[^>]*value="([^"]+)"/, html_response(login_page, 200))

    login_page
    |> recycle()
    |> Map.put(:port, 4002)
    |> put_private(:plug_skip_csrf_protection, false)
    |> put_req_header("origin", "http://localhost:4002")
    |> post("/login", %{"access_code" => code, "_csrf_token" => token})
  end

  defp proposal do
    directory =
      Path.join(File.cwd!(), ".harnessforge-web-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    {:ok, connection} =
      Evidence.connect(%{
        "name" => "Synthetic public fixture",
        "provider" => "local",
        "directory" => directory
      })

    {:ok, source} =
      Evidence.import_markdown(connection["id"], %{
        "external_id" => "guide.md",
        "title" => "Synthetic guide",
        "body" => "Review each change. <script>alert('source data')</script>"
      })

    revision = source["latest_revision"]
    {:ok, citation} = Evidence.citation(revision["id"], 0, byte_size(revision["body"]))

    {:ok, claim} =
      Evidence.create_claim(%{
        "text" => "Review each change before release.",
        "citations" => [citation]
      })

    claim
  end
end
