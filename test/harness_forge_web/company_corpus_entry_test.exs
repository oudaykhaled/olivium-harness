defmodule HarnessForgeWeb.CompanyCorpusEntryTest do
  use HarnessForgeWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias HarnessForge.Workspaces
  alias HarnessForgeWeb.Plugs.OperatorSession

  setup %{conn: conn} do
    previous = Application.fetch_env!(:harness_forge, :workspace_root)
    previous_id = Workspaces.current_id()
    id = Ecto.UUID.generate()
    root = Path.join(File.cwd!(), "tmp/company-corpus-entry-#{id}")
    Enum.each(~w(artifacts runs tmp), &File.mkdir_p!(Path.join(root, &1)))
    Application.put_env(:harness_forge, :workspace_root, root)
    Application.put_env(:harness_forge, :workspace_id, id)

    on_exit(fn ->
      Application.put_env(:harness_forge, :workspace_root, previous)
      Application.put_env(:harness_forge, :workspace_id, previous_id)
      File.rm_rf!(root)
    end)

    conn = %{conn | host: "localhost", port: 4002}
    {:ok, conn: init_test_session(conn, %{"operator_auth" => OperatorSession.new_auth()})}
  end

  test "the secondary corpus action reaches the route without assigning documents", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, "/?setup=company")
    assert has_element?(view, "#company-panel:not([hidden])")

    assert has_element?(
             view,
             "#company-corpus-review.button.secondary",
             "Select corpus and goal"
           )

    assert has_element?(view, ".company-corpus-steps", "separate plan")
    view |> element("#company-corpus-review") |> render_click()
    assert_redirect(view, "/company/corpus")
    assert {:ok, []} = HarnessForge.Company.list_projects()
    assert {:ok, []} = HarnessForge.Company.list_plans()
  end

  test "the primary action preserves an unsaved company draft until save or discard", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, "/?setup=company")
    view |> element("#company-guide-task-profile") |> render_click()

    view
    |> form("#company-profile-form", profile: %{name: "Unsaved company context"})
    |> render_change()

    view |> element("#company-corpus-review") |> render_click()
    assert has_element?(view, "#company-error", "Save or discard")
    assert has_element?(view, "#company-profile-name[value='Unsaved company context']")
    assert {:ok, nil} = HarnessForge.Company.get_profile()
  end

  test "contextual setup URLs select only the existing supported surfaces", %{conn: conn} do
    for {tab, panel} <- [{"connections", "connections-panel"}, {"goals", "goals-panel"}] do
      {:ok, view, _} = live(conn, "/?setup=" <> tab)
      assert has_element?(view, "##{panel}:not([hidden])")
    end

    {:ok, view, _} = live(conn, "/?setup=privacy")
    assert has_element?(view, "#company-panel:not([hidden])")
    refute has_element?(view, "#privacy-panel:not([hidden])")
  end
end
