defmodule HarnessForgeWeb.LiveAccountsTest do
  use HarnessForgeWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias HarnessForge.{Accounts, Demo, Evidence}
  alias HarnessForgeWeb.Plugs.OperatorSession

  @ref "HARNESSFORGE_LIVE_UI_KEY"
  @question "List for me the top 10 repositories on my github"

  setup %{conn: conn} do
    old_key = System.get_env(@ref)
    old_plug = Application.get_env(:harness_forge, :account_test_plug)
    System.put_env(@ref, "synthetic-live-ui-key")
    Application.put_env(:harness_forge, :account_test_plug, {Req.Test, __MODULE__})

    on_exit(fn ->
      if old_key, do: System.put_env(@ref, old_key), else: System.delete_env(@ref)

      if old_plug,
        do: Application.put_env(:harness_forge, :account_test_plug, old_plug),
        else: Application.delete_env(:harness_forge, :account_test_plug)
    end)

    {:ok, _} = Demo.load()
    conn = %{conn | host: "localhost", port: 4002}

    {:ok, view, _} =
      live(init_test_session(conn, %{"operator_auth" => OperatorSession.new_auth()}), "/")

    Req.Test.allow(__MODULE__, self(), view.pid)
    {:ok, view: view}
  end

  test "default assistant routes the exact request to live GitHub and explains missing account",
       %{view: view} do
    view |> element("#nav-chat") |> render_click()
    assert has_element?(view, "#chat-mode option[value=assistant][selected]")
    view |> form("#chat-form", %{"chat" => %{"question" => @question}}) |> render_submit()
    render_async(view)
    assert has_element?(view, "#chat-error", "Connect your GitHub account")
    refute has_element?(view, "#chat-transcript", "LOCAL EVIDENCE SEARCH")
    assert_push_event(view, "chat-restore-composer", %{question: @question})
  end

  test "verified account answers the exact top10 request using live metadata, without source imports",
       %{view: view} do
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(owner, {:live_request, conn.request_path})

      case conn.request_path do
        "/user" ->
          Req.Test.json(conn, identity())

        "/user/repos" ->
          conn = Plug.Conn.fetch_query_params(conn)
          assert conn.query_params["per_page"] == "10"
          assert conn.query_params["sort"] == "updated"
          assert conn.query_params["affiliation"] == "owner"
          Req.Test.json(conn, repositories())
      end
    end)

    {:ok, sources} = Evidence.list_sources()
    view |> element("#nav-connections") |> render_click()

    view
    |> form("#account-form", %{"account" => %{"service" => "github", "credential_ref" => @ref}})
    |> render_submit()

    render_async(view)
    assert has_element?(view, "#notice", "Live account verified")
    assert has_element?(view, "#account-status-github", "Configured")
    assert_receive {:live_request, "/user"}

    view |> element("#nav-chat") |> render_click()
    view |> form("#chat-form", %{"chat" => %{"question" => @question}}) |> render_submit()
    render_async(view)
    assert has_element?(view, "#chat-transcript", "LIVE CONNECTOR RESULT")
    assert has_element?(view, "#chat-transcript", "10 most recently updated owned repositories")
    assert has_element?(view, "#chat-transcript .chat-live-results li:nth-child(10)")
    refute has_element?(view, "#chat-transcript .chat-live-results li:nth-child(11)")
    assert has_element?(view, "#chat-transcript a[href='https://github.com/synthetic/repo-1']")
    refute render(view) =~ "synthetic-live-ui-key"
    assert {:ok, ^sources} = Evidence.list_sources()
    assert_receive {:live_request, "/user"}
    assert_receive {:live_request, "/user/repos"}
    send(view.pid, :refresh_evaluations)
    render(view)
    refute_receive {:live_request, _}, 50

    view |> element("#nav-connections") |> render_click()

    view
    |> element("#account-status-github button[phx-click=account_disconnect]")
    |> render_click()

    view |> element("#nav-chat") |> render_click()
    refute has_element?(view, "#chat-transcript .chat-live-results")
  end

  test "explicit local mode offers live assistant instead of a false account-search answer", %{
    view: view
  } do
    view |> element("#nav-chat") |> render_click()

    view
    |> form("#chat-form", %{"chat" => %{"question" => @question, "mode" => "evidence"}})
    |> render_submit()

    render_async(view)
    assert has_element?(view, "#chat-error", "needs live account access")
    assert has_element?(view, "#chat-use-assistant")
    view |> element("#chat-use-assistant") |> render_click()
    assert has_element?(view, "#chat-mode option[value=assistant][selected]")
  end

  test "each missing service has actionable setup and failed verification never marks it connected",
       %{view: view} do
    view |> element("#nav-chat") |> render_click()

    for service <- ~w(github_projects jira slack confluence) do
      assert has_element?(view, "#chat-connector-#{service} button[phx-click=account_setup]")
    end

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/graphql"

      Req.Test.json(conn, %{
        "errors" => [%{"type" => "INSUFFICIENT_SCOPES", "message" => "DO_NOT_DISPLAY_RAW_CANARY"}]
      })
    end)

    view
    |> element("#chat-connector-github_projects button[phx-click=account_setup]")
    |> render_click()

    assert has_element?(view, "#account-service option[value=github_projects][selected]")
    assert has_element?(view, "#live-accounts-panel", "read:project")

    view
    |> form("#account-form", %{
      "account" => %{"service" => "github_projects", "credential_ref" => @ref}
    })
    |> render_submit()

    render_async(view)
    assert has_element?(view, "#error")
    refute render(view) =~ "DO_NOT_DISPLAY_RAW_CANARY"
    {:ok, accounts} = Accounts.catalog()
    assert Enum.all?(accounts, &(&1["state"] == "not_configured"))
  end

  defp identity,
    do: %{"id" => 101, "login" => "synthetic", "html_url" => "https://github.com/synthetic"}

  defp repositories do
    for index <- 1..10 do
      %{
        "id" => 1000 + index,
        "name" => "repo-#{index}",
        "full_name" => "synthetic/repo-#{index}",
        "html_url" => "https://github.com/synthetic/repo-#{index}",
        "private" => false,
        "stargazers_count" => 10 - index,
        "updated_at" =>
          DateTime.add(~U[2026-10-31 12:00:00Z], -index, :second) |> DateTime.to_iso8601(),
        "owner" => identity()
      }
    end
  end
end
