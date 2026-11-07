defmodule HarnessForgeWeb.IntegrationSurfacesTest do
  use HarnessForgeWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias HarnessForge.{CLI, Evidence, Repo}
  alias HarnessForgeWeb.Plugs.OperatorSession

  @selections [
    {"github", %{"repository" => "synthetic/selected"}, "#remote-repository"},
    {"github_projects",
     %{
       "project_url" => "https://github.com/orgs/synthetic/projects/1",
       "credential_ref" => "HARNESSFORGE_TEST_PROJECTS_TOKEN"
     }, "#remote-project-url"},
    {"jira",
     %{
       "endpoint" => "https://synthetic.atlassian.net",
       "project" => "DEMO",
       "username_ref" => "HARNESSFORGE_TEST_EMAIL",
       "credential_ref" => "HARNESSFORGE_TEST_JIRA_TOKEN"
     }, "#remote-project"},
    {"slack",
     %{
       "team_id" => "T123456",
       "channel_id" => "C123456",
       "credential_ref" => "HARNESSFORGE_TEST_SLACK_TOKEN"
     }, "#remote-channel"},
    {"confluence",
     %{
       "endpoint" => "https://synthetic.atlassian.net",
       "space_id" => "12345",
       "username_ref" => "HARNESSFORGE_TEST_EMAIL",
       "credential_ref" => "HARNESSFORGE_TEST_CONFLUENCE_TOKEN"
     }, "#remote-space"}
  ]

  test "all five portal selections save exactly their scope and queue credential-free jobs", %{
    conn: conn
  } do
    conn = %{conn | host: "localhost", port: 4002}
    conn = init_test_session(conn, %{"operator_auth" => OperatorSession.new_auth()})
    {:ok, view, _} = live(conn, "/")
    view |> element("#nav-connections") |> render_click()

    for {provider, config, selector} <- @selections do
      render_change(view, "remote_changed", %{"remote" => %{"provider" => provider}})
      assert has_element?(view, selector)
      assert has_element?(view, "#remote-provider option[selected][value='#{provider}']")
      values = Map.merge(config, %{"provider" => provider, "name" => "Portal #{provider}"})
      view |> form("#remote-form", %{"remote" => values}) |> render_submit()
      assert has_element?(view, "#notice", "Read-only connection saved")
      {:ok, connections} = Evidence.list_connections()
      connection = Enum.find(connections, &(&1["name"] == "Portal #{provider}"))
      assert connection["provider"] == provider
      assert Map.take(connection["config"], Map.keys(config)) == config
      view |> element("#import-#{connection["id"]}") |> render_click()

      job =
        Repo.get_by!(Oban.Job,
          worker: "HarnessForge.Jobs.Operation",
          args: %{
            "action" => "sync",
            "id" => connection["id"],
            "workspace_id" => HarnessForge.Workspaces.current_id()
          }
        )

      assert Map.keys(job.args) |> Enum.sort() == ~w(action id workspace_id)
    end
  end

  test "portal rejects a raw token with an actionable safe message", %{conn: conn} do
    conn = %{conn | host: "localhost", port: 4002}

    {:ok, view, _} =
      live(init_test_session(conn, %{"operator_auth" => OperatorSession.new_auth()}), "/")

    view |> element("#nav-connections") |> render_click()

    render_click(view, "connect_remote", %{
      "remote" => %{
        "name" => "Rejected",
        "provider" => "slack",
        "team_id" => "T123456",
        "channel_id" => "C123456",
        "credential_ref" => "xoxb-never-store-this"
      }
    })

    assert has_element?(view, "#error", "environment reference names")
    refute render(view) =~ "xoxb-never-store-this"
    assert {:ok, []} = Evidence.list_connections()
  end

  test "CLI configures all five real adapters using only selected scope and environment references" do
    commands = [
      ["connect", "github", "CLI repo", "synthetic/selected"],
      [
        "connect",
        "github_projects",
        "CLI board",
        "https://github.com/users/synthetic/projects/1",
        "HARNESSFORGE_TEST_PROJECTS_TOKEN"
      ],
      [
        "connect",
        "jira",
        "CLI issues",
        "https://synthetic.atlassian.net",
        "DEMO",
        "HARNESSFORGE_TEST_EMAIL",
        "HARNESSFORGE_TEST_JIRA_TOKEN"
      ],
      ["connect", "slack", "CLI channel", "T123456", "C123456", "HARNESSFORGE_TEST_SLACK_TOKEN"],
      [
        "connect",
        "confluence",
        "CLI pages",
        "https://synthetic.atlassian.net",
        "12345",
        "HARNESSFORGE_TEST_EMAIL",
        "HARNESSFORGE_TEST_CONFLUENCE_TOKEN"
      ]
    ]

    for command <- commands do
      assert {:ok, connection} = CLI.run(command)
      assert connection["provider"] == Enum.at(command, 1)
      assert connection["status"] == "active"
    end

    assert {:ok, %{"commands" => help}} = CLI.run(["help"])

    for provider <- ~w(github github_projects jira slack confluence),
        do: assert(Enum.any?(help, &String.starts_with?(&1, "connect #{provider} ")))
  end
end
