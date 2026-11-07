defmodule HarnessForgeWeb.CommandApprovalLiveTest do
  use HarnessForgeWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias HarnessForge.{CommandApprovalsFixture, Evidence, Models, Repo, Workspaces}
  alias HarnessForge.Execution.{CommandApproval, CommandApprovals}
  alias HarnessForgeWeb.Plugs.OperatorSession

  setup %{conn: conn} do
    previous = {Workspaces.root(), Workspaces.current_id()}
    root = Path.join(File.cwd!(), "tmp/command-approval-web-#{Ecto.UUID.generate()}")
    File.mkdir_p!(root)
    Application.put_env(:harness_forge, :workspace_root, root)
    Application.put_env(:harness_forge, :workspace_id, Ecto.UUID.generate())
    fixture = CommandApprovalsFixture.create!(root)

    on_exit(fn ->
      Application.put_env(:harness_forge, :workspace_root, elem(previous, 0))
      Application.put_env(:harness_forge, :workspace_id, elem(previous, 1))
      File.rm_rf!(root)
    end)

    conn =
      conn
      |> Map.merge(%{host: "localhost", port: 4002})
      |> init_test_session(%{"operator_auth" => OperatorSession.new_auth()})

    {:ok, Map.merge(fixture, %{conn: conn, root: root})}
  end

  test "explicit WEB allow-once records one decision and does not certify execution", c do
    request = request!(c)
    view = review!(c, request)
    assert Repo.get!(CommandApproval, request["id"]).state == "pending"
    assert has_element?(view, "#command-review", "Waiting for your decision")
    assert has_element?(view, "#command-review details code", request["request_digest"])
    assert {:ok, []} = Models.list_requests(c.run.id)

    view |> element("#command-request-#{request["id"]} button", "Allow once") |> render_click()
    assert Repo.get!(CommandApproval, request["id"]).state == "accepted"
    assert has_element?(view, "#command-review", "waiting for the agent")
    refute Repo.get!(HarnessForge.Evaluation.Run, c.run.id).result["runtime_qualified"]

    assert {:ok, %{"decision" => "accept"}} =
             CommandApprovals.poll(c.run.id, request["id"], c.caller)

    assert {:ok, %{"decision" => "decline"}} =
             CommandApprovals.poll(c.run.id, request["id"], c.caller)

    send(view.pid, :refresh_evaluations)
    assert render(view) =~ "Decision delivered once"
    assert {:ok, []} = Models.list_requests(c.run.id)
  end

  test "denial is terminal and a forged second decision grants no permission", c do
    request = request!(c)
    view = review!(c, request)
    view |> element("#command-request-#{request["id"]} button", "Deny") |> render_click()
    assert Repo.get!(CommandApproval, request["id"]).state == "declined"
    refute has_element?(view, "#command-review button", "Allow once")
    render_click(view, "command_approval_decide", envelope(c, request))
    assert Repo.get!(CommandApproval, request["id"]).state == "declined"

    assert {:ok, %{"decision" => "decline"}} =
             CommandApprovals.poll(c.run.id, request["id"], c.caller)
  end

  test "wrong exact scope and source revocation clear command content and deny decisions", c do
    request = request!(c)
    view = review!(c, request)

    render_click(
      view,
      "command_approval_decide",
      Map.put(envelope(c, request), "request_digest", String.duplicate("f", 64))
    )

    assert Repo.get!(CommandApproval, request["id"]).state == "pending"

    assert {:ok, _} = Evidence.revoke_source(c.source["id"])
    send(view.pid, :corpus_cache_reset)
    refute render(view) =~ request["payload"]["command"]
    render_click(view, "command_approval_decide", envelope(c, request))
    assert Repo.get!(CommandApproval, request["id"]).state == "pending"
    render_click(view, "command_review_open", %{"id" => c.run.id})
    refute has_element?(view, "#command-review button", "Allow once")
    refute render(view) =~ request["payload"]["command"]
  end

  test "operator session revocation redirects without accepting a pending request", c do
    request = request!(c)
    view = review!(c, request)
    send(view.pid, :operator_session_revoked)
    assert_redirect(view, "/login")
    assert Repo.get!(CommandApproval, request["id"]).state == "pending"
  end

  test "native command and original arguments are escaped text", c do
    canary = "</code><script>alert('command-preview')</script>"

    request =
      request!(c, %{
        "command" => canary,
        "original_arguments" => Jason.encode!(%{"cmd" => canary})
      })

    view = review!(c, request)
    html = render(view)
    assert html =~ "&lt;script&gt;"
    refute html =~ "<script>alert('command-preview')</script>"
    assert has_element?(view, "#command-request-#{request["id"]} pre code", canary)
  end

  test "initial and expired controls cannot emit a new decision", c do
    request = request!(c)

    html =
      render_component(&HarnessForgeWeb.CommandApproval.panel/1,
        rows: [request],
        run_id: c.run.id
      )

    assert html =~ "disabled"

    expired =
      Map.put(
        request,
        "expires_at",
        DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.to_iso8601()
      )

    html =
      render_component(&HarnessForgeWeb.CommandApproval.panel/1,
        rows: [expired],
        run_id: c.run.id,
        ready: true
      )

    assert html =~ "Expired; no permission is available"
    refute html =~ "Allow once"
  end

  defp request!(c, overrides \\ %{}) do
    {:ok, request} =
      CommandApprovals.request(
        c.run.id,
        CommandApprovalsFixture.payload(overrides),
        DateTime.add(DateTime.utc_now(), 120, :second),
        c.caller
      )

    request
  end

  defp review!(c, request) do
    {:ok, view, _} = live(c.conn, "/?view=evaluations")
    view |> element("#run-#{c.run.id} button", "Review commands") |> render_click()
    assert has_element?(view, "#command-request-#{request["id"]}")
    view
  end

  defp envelope(c, request),
    do: %{
      "run_id" => c.run.id,
      "id" => request["id"],
      "request_digest" => request["request_digest"],
      "decision" => "accept_once"
    }
end
