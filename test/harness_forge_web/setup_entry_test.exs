defmodule HarnessForgeWeb.SetupEntryTest do
  use HarnessForgeWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias HarnessForge.{Repo, Workspaces}
  alias HarnessForge.Company.SetupSessions
  alias HarnessForgeWeb.Plugs.OperatorSession

  setup %{conn: conn} do
    workspace = Workspaces.current_id()
    Application.put_env(:harness_forge, :workspace_id, Ecto.UUID.generate())
    on_exit(fn -> Application.put_env(:harness_forge, :workspace_id, workspace) end)

    conn =
      conn
      |> Map.merge(%{host: "localhost", port: 4002})
      |> init_test_session(%{"operator_auth" => OperatorSession.new_auth()})

    %{conn: conn}
  end

  test "Home has one guarded keyboard setup entry without dispatch or a mount write", c do
    before = counts()
    {:ok, view, _} = live(c.conn, "/")
    assert has_element?(view, "#company-setup-open", "Saved setup")
    assert counts() == before
    view |> element("#company-setup-open") |> render_click()
    assert_redirect(view, "/setup")
    assert counts() == before
  end

  test "an unsaved Company draft prevents setup departure", c do
    {:ok, view, _} = live(c.conn, "/")

    view
    |> form("#company-profile-form", %{"profile" => %{"name" => "Unsaved synthetic profile"}})
    |> render_change()

    view |> element("#company-setup-open") |> render_click()
    assert has_element?(view, "#company-error", "Save or discard your Company draft")
    assert has_element?(view, "#company-profile-form")
  end

  test "initial disconnected HTML disables the new setup action", c do
    html = c.conn |> get("/") |> html_response(200)
    doc = LazyHTML.from_document(html)
    assert doc |> LazyHTML.query("#company-setup-open[disabled]") |> Enum.count() == 1
  end

  test "one saved setup offers its exact authoritative step with no navigation writes", c do
    saved = create_setup()
    before = counts()
    {:ok, view, _} = live(c.conn, "/")

    assert has_element?(
             view,
             "#company-guide-next[phx-click=company_setup_resume]",
             "Resume saved setup"
           )

    assert has_element?(view, "#company-home-resume-identity", saved["id"])

    assert length(
             LazyHTML.from_document(render(view))
             |> LazyHTML.query("#company-guide .button.primary")
             |> Enum.to_list()
           ) == 1

    view |> element("#company-guide-next") |> render_click(%{"value" => ""})
    assert_redirect(view, "/setup/#{saved["id"]}/outcome")
    assert counts() == before
  end

  test "multiple saved setups require a choice rather than selecting the most recent", c do
    create_setup()
    create_setup()
    before = counts()
    {:ok, view, _} = live(c.conn, "/")

    assert has_element?(
             view,
             "#company-guide-next[phx-click=company_setup_open]",
             "Choose saved setup"
           )

    refute has_element?(view, "#company-home-resume-identity")
    view |> element("#company-guide-next") |> render_click(%{"value" => ""})
    assert_redirect(view, "/setup")
    assert counts() == before
  end

  test "resume reloads the authoritative saved step after the Home observation", c do
    saved = create_setup()

    # Seed only this test's initial later-step navigation state; use the domain command to go back.
    Repo.query!("UPDATE setup_sessions SET step='scope' WHERE id=?", [saved["id"]])
    {:ok, view, _} = live(c.conn, "/?setup=#{saved["id"]}")
    assert has_element?(view, "#company-home-resume-identity", "scope")

    assert {:ok, current} =
             SetupSessions.command(
               %{
                 "id" => saved["id"],
                 "expected_version" => saved["version"],
                 "command" => "back",
                 "payload" => %{}
               },
               caller()
             )

    assert current["step"] == "outcome"
    before = counts()
    view |> element("#company-guide-next") |> render_click()
    assert_redirect(view, "/setup/#{saved["id"]}/outcome")
    assert counts() == before
  end

  test "resume rejects client identity fields and refresh preserves an unsaved Company draft",
       c do
    saved = create_setup()
    {:ok, view, _} = live(c.conn, "/?setup=#{saved["id"]}")

    generation =
      render(view)
      |> LazyHTML.from_document()
      |> LazyHTML.query("#company-guide-next")
      |> LazyHTML.attribute("phx-value-company_event_generation")
      |> hd()

    before = counts()

    view |> element("#company-home-resume-refresh") |> render_click(%{"value" => ""})
    refute has_element?(view, "#company-error")

    view
    |> with_target("#company-panel")
    |> render_hook("company_setup_resume", %{
      "company_event_generation" => generation,
      "id" => Ecto.UUID.generate(),
      "step" => "release"
    })

    assert has_element?(view, "#company-error")

    view
    |> form("#company-profile-form", %{"profile" => %{"name" => "Retain draft on refresh"}})
    |> render_change()

    view |> element("#company-home-resume-refresh") |> render_click()
    assert has_element?(view, "#company-error", "before refreshing saved setup")
    assert has_element?(view, "#company-profile-name[value='Retain draft on refresh']")
    assert has_element?(view, "#company-home-resume-identity", saved["id"])
    assert counts() == before
  end

  test "navigation refuses nonempty transport values for every saved setup event", c do
    saved = create_setup()
    before = counts()

    for event <- ~w(company_setup_open company_setup_resume company_setup_refresh) do
      {:ok, view, _} = live(c.conn, "/?setup=#{saved["id"]}")

      generation =
        render(view)
        |> LazyHTML.from_document()
        |> LazyHTML.query("#company-guide-next")
        |> LazyHTML.attribute("phx-value-company_event_generation")
        |> hd()

      view
      |> with_target("#company-panel")
      |> render_hook(event, %{"company_event_generation" => generation, "value" => "release"})

      assert has_element?(view, "#company-error")
      assert has_element?(view, "#company-home-resume-identity", saved["id"])
      assert counts() == before
    end
  end

  test "pending privacy fences clear cached exact metadata until an authorized reread", c do
    saved = create_setup()
    {:ok, view, _} = live(c.conn, "/?setup=#{saved["id"]}")
    assert has_element?(view, "#company-home-resume-identity", saved["id"])
    operation = Ecto.UUID.generate()
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    Repo.query!(
      "INSERT INTO privacy_operations (id,workspace_id,kind,target_id,state,plan,inserted_at,updated_at) VALUES (?,?,?,?,'prepared','{}',?,?)",
      [operation, Workspaces.current_id(), "source", Ecto.UUID.generate(), now, now]
    )

    assert {:error, :privacy_operation_incomplete} = HarnessForge.Privacy.ready()
    before = counts()
    send(view.pid, :company_cache_reset)
    render(view)
    refute has_element?(view, "#company-home-resume-identity")
    assert has_element?(view, "#company-home-resume-status", "metadata is unavailable")
    assert has_element?(view, "#company-guide-next[phx-click=company_setup_refresh]")
    assert counts() == before

    Repo.query!("DELETE FROM privacy_operations WHERE id=? AND workspace_id=?", [
      operation,
      Workspaces.current_id()
    ])

    send(view.pid, :company_cache_reset)
    render(view)
    assert has_element?(view, "#company-home-resume-identity", saved["id"])
    assert counts() == before
  end

  test "an exact nonrecent setup outside the list page survives remount without exposing its note",
       c do
    saved = create_setup()

    {:ok, noted} =
      SetupSessions.command(
        %{
          "id" => saved["id"],
          "expected_version" => saved["version"],
          "command" => "save",
          "payload" => %{"draft" => %{"outcome_note" => "PRIVATE HOME NOTE MUST STAY IN SETUP"}}
        },
        caller()
      )

    Enum.each(1..21, fn _ -> create_setup() end)
    {:ok, page} = SetupSessions.list(%{}, caller())
    refute Enum.any?(page, &(&1["id"] == saved["id"]))
    before = counts()

    for _ <- 1..2 do
      {:ok, view, _} = live(c.conn, "/?setup=#{saved["id"]}")
      assert has_element?(view, "#company-home-resume-identity", saved["id"])
      assert has_element?(view, "#company-home-resume-identity", to_string(noted["version"]))
      refute render(view) =~ "PRIVATE HOME NOTE MUST STAY IN SETUP"
      view |> element("#company-guide-next") |> render_click()
      assert_redirect(view, "/setup/#{saved["id"]}/outcome")
      assert counts() == before
    end
  end

  test "invalid, deleted and foreign exact addresses do not fall back to an owned setup", c do
    create_setup()
    current = Workspaces.current_id()

    foreign =
      try do
        Application.put_env(:harness_forge, :workspace_id, Ecto.UUID.generate())
        create_setup()
      after
        Application.put_env(:harness_forge, :workspace_id, current)
      end

    before = counts()

    for selector <- ["bad-selector", Ecto.UUID.generate(), foreign["id"]] do
      {:ok, view, _} = live(c.conn, "/?setup=#{selector}")
      assert has_element?(view, "#company-guide-next[phx-click=company_setup_refresh]")
      refute has_element?(view, "#company-home-resume-identity")
      refute has_element?(view, "#company-guide-next[phx-click=company_setup_resume]")
      view |> element("#company-guide-next") |> render_click()
      refute has_element?(view, "#company-home-resume-identity")
      assert counts() == before
    end
  end

  test "selector changes reject stale events and Company drafts block exact departure", c do
    first = create_setup()
    second = create_setup()
    before = counts()
    {:ok, view, _} = live(c.conn, "/?setup=#{first["id"]}")

    old_generation =
      render(view)
      |> LazyHTML.from_document()
      |> LazyHTML.query("#company-guide-next")
      |> LazyHTML.attribute("phx-value-company_event_generation")
      |> hd()

    render_patch(view, "/?setup=#{second["id"]}")
    assert has_element?(view, "#company-home-resume-identity", second["id"])

    view
    |> with_target("#company-panel")
    |> render_hook("company_setup_resume", %{"company_event_generation" => old_generation})

    assert has_element?(view, "#company-notice", "refreshed controls")

    view
    |> form("#company-profile-form", %{"profile" => %{"name" => "Unsaved exact setup draft"}})
    |> render_change()

    render_patch(view, "/?setup=#{first["id"]}")
    assert has_element?(view, "#company-profile-name[value='Unsaved exact setup draft']")
    view |> element("#company-guide-next") |> render_click()
    assert has_element?(view, "#company-error", "Save or discard your Company draft")
    assert has_element?(view, "#company-profile-name[value='Unsaved exact setup draft']")
    assert counts() == before
  end

  test "Return to Home carries only a successfully loaded exact address", c do
    saved = create_setup()
    {:ok, view, _} = live(c.conn, "/setup/#{saved["id"]}/outcome")
    assert has_element?(view, "#setup-return-home[href='/?setup=#{saved["id"]}']")
    {:ok, missing, _} = live(c.conn, "/setup/#{Ecto.UUID.generate()}/outcome")
    assert has_element?(missing, "#setup-return-home[href='/']")
  end

  test "cache reset clears removed exact metadata and retains its unavailable address", c do
    saved = create_setup()
    {:ok, view, _} = live(c.conn, "/?setup=#{saved["id"]}")
    assert has_element?(view, "#company-home-resume-identity", saved["id"])

    old_generation =
      render(view)
      |> LazyHTML.from_document()
      |> LazyHTML.query("#company-guide-next")
      |> LazyHTML.attribute("phx-value-company_event_generation")
      |> hd()

    # Remove only this isolated fixture, before the ordinary privacy-reset notification.
    Repo.query!("DELETE FROM setup_sessions WHERE id=? AND workspace_id=?", [
      saved["id"],
      Workspaces.current_id()
    ])

    before = counts()
    send(view.pid, :company_cache_reset)
    render(view)
    refute has_element?(view, "#company-home-resume-identity")
    assert has_element?(view, "#company-guide-next[phx-click=company_setup_refresh]")

    view
    |> with_target("#company-panel")
    |> render_hook("company_setup_resume", %{"company_event_generation" => old_generation})

    assert has_element?(view, "#company-notice", "refreshed controls")
    view |> element("#company-guide-next") |> render_click()
    refute has_element?(view, "#company-home-resume-identity")
    assert counts() == before
  end

  test "Portal independently refuses exact setup departure with an assessment draft", c do
    saved = create_setup()
    before = counts()
    {:ok, view, _} = live(c.conn, "/?setup=#{saved["id"]}")
    socket = :sys.get_state(view.pid).socket

    dirty =
      Phoenix.Component.assign(
        socket,
        :assessment_state,
        Map.put(socket.assigns.assessment_state, "dirty", true)
      )

    assert {:noreply, refused} =
             HarnessForgeWeb.PortalLive.handle_info({:company_inspect_setup, saved["id"]}, dirty)

    assert refused.redirected == nil
    assert refused.assigns.flash["error"] =~ "Record or discard your assessment draft"
    assert counts() == before
  end

  test "legacy setup links and disconnected exact Home keep their previous routing", c do
    for {selector, heading} <- [
          {"company", "Build your company harness"},
          {"connections", "Bring your context together."},
          {"goals", "Goals"}
        ] do
      {:ok, view, _} = live(c.conn, "/?setup=#{selector}")
      assert render(view) =~ heading
      refute has_element?(view, "#company-guide-next[phx-click=company_setup_refresh]")
    end

    saved = create_setup()
    html = c.conn |> get("/?setup=#{saved["id"]}") |> html_response(200)
    doc = LazyHTML.from_document(html)

    assert length(
             Enum.to_list(
               LazyHTML.query(
                 doc,
                 "#company-guide-next[disabled], fieldset[disabled] #company-guide-next"
               )
             )
           ) == 1
  end

  test "empty saved context offers create links only while connected and clean", c do
    saved = create_setup()
    route = "/setup/#{saved["id"]}/outcome"
    before = counts()
    disconnected = c.conn |> get(route) |> html_response(200)

    assert Enum.empty?(
             LazyHTML.query(LazyHTML.from_document(disconnected), "[id^=setup-create-]")
           )

    {:ok, view, _} = live(c.conn, route)

    for field <- ~w(profile project repository goal) do
      href = creation_url(saved, field)
      assert has_element?(view, "#setup-create-#{field}[href='#{href}']")
    end

    view
    |> form("#setup-step-form", setup: %{"outcome_note" => "Keep this unsaved note"})
    |> render_change()

    refute has_element?(view, "#setup-create-profile")
    assert has_element?(view, "#setup-empty-profile", "Save your note and choices")
    assert counts() == before
  end

  test "each requested creation form returns to the authoritative saved step without selection",
       c do
    saved = create_setup()
    Repo.query!("UPDATE setup_sessions SET step='scope' WHERE id=?", [saved["id"]])
    before = counts()

    for section <- ~w(profile repository project goal) do
      {:ok, view, _} = live(c.conn, creation_url(saved, section))

      return_id =
        if section == "goal",
          do: "setup-create-goal-return-link",
          else: "setup-create-company-return-link"

      assert has_element?(view, "##{return_id}[href='/setup/#{saved["id"]}/scope']")

      if section == "goal" do
        assert has_element?(view, "#goal-form")
        assert has_element?(view, "#setup-create-goal-assign")
      else
        assert has_element?(
                 view,
                 "#company-section-#{section}:not([hidden]) #company-#{section}-form"
               )

        if section == "repository",
          do: assert(has_element?(view, "#setup-create-repository-assign"))
      end

      GenServer.stop(view.pid)
    end

    assert {:ok, same} = SetupSessions.get(%{"id" => saved["id"]}, caller())
    assert same["version"] == saved["version"]
    assert Enum.all?(Map.values(same["selection"]), &is_nil/1)
    assert counts() == before
  end

  test "creation uses explicit existing saves and return reloads choices without auto-assignment",
       c do
    saved = create_setup()
    before = counts()

    for {section, attrs} <- [
          {"profile", %{"name" => "Public create-return company"}},
          {"repository",
           %{
             "identity" => "public-create-return",
             "name" => "Public repository",
             "purpose" => "Synthetic test",
             "owner" => "Synthetic owner"
           }},
          {"project",
           %{"name" => "Public create-return project", "description" => "Synthetic context"}},
          {"goal",
           %{
             "title" => "Public create-return goal",
             "owner" => "Synthetic owner",
             "acceptance" => "Keep setup choices explicit"
           }}
        ] do
      {:ok, view, _} = live(c.conn, creation_url(saved, section))
      form_id = if section == "goal", do: "goal-form", else: "company-#{section}-form"

      return_id =
        if section == "goal",
          do: "setup-create-goal-return-link",
          else: "setup-create-company-return-link"

      view |> form("##{form_id}", %{section => attrs}) |> render_change()
      refute has_element?(view, "##{return_id}")
      view |> form("##{form_id}", %{section => attrs}) |> render_submit()
      assert has_element?(view, "##{return_id}[href='/setup/#{saved["id"]}/outcome']")
      GenServer.stop(view.pid)
    end

    {:ok, reopened, _} = live(c.conn, "/setup/#{saved["id"]}/outcome")
    assert has_element?(reopened, "#setup-profile", "Public create-return company")
    assert has_element?(reopened, "#setup-project", "Public create-return project")
    # Repository and goal membership must be assigned explicitly in existing company forms.
    assert has_element?(reopened, "#setup-empty-repository")
    assert has_element?(reopened, "#setup-empty-goal")
    assert {:ok, same} = SetupSessions.get(%{"id" => saved["id"]}, caller())
    assert same["version"] == saved["version"]
    assert Enum.all?(Map.values(same["selection"]), &is_nil/1)
    assert counts() == before
  end

  test "malformed foreign and extended create links never disclose a return or write", c do
    saved = create_setup()
    before = counts()

    for route <- [
          creation_url(saved, "profile") <> "&redirect=https%3A%2F%2Fexample.com",
          creation_url(saved, "unknown"),
          creation_url(%{"id" => Ecto.UUID.generate(), "step" => "outcome"}, "profile"),
          "/?create=profile&return_setup=bad&return_step=outcome",
          "/?create=profile&return_setup=#{saved["id"]}&return_step=release"
        ] do
      {:ok, view, _} = live(c.conn, route)
      refute has_element?(view, "#setup-create-company-return")
      refute has_element?(view, "#setup-create-goal-return")
      GenServer.stop(view.pid)
    end

    Repo.query!("UPDATE setup_sessions SET owner='foreign-owner' WHERE id=?", [saved["id"]])
    {:ok, denied, _} = live(c.conn, creation_url(saved, "profile"))
    refute has_element?(denied, "#setup-create-company-return")
    assert counts() == before
  end

  test "privacy reset removes creation return context rather than retaining a stale address", c do
    saved = create_setup()
    {:ok, view, _} = live(c.conn, creation_url(saved, "profile"))
    assert has_element?(view, "#setup-create-company-return-link")
    before = counts()
    send(view.pid, :company_cache_reset)
    render(view)
    refute has_element?(view, "#setup-create-company-return")
    assert counts() == before
  end

  defp creation_url(saved, section),
    do:
      "/?" <>
        URI.encode_query(%{
          "create" => section,
          "return_setup" => saved["id"],
          "return_step" => saved["step"]
        })

  defp create_setup do
    assert {:ok, setup} = SetupSessions.create(%{}, caller())
    setup
  end

  defp caller do
    auth = OperatorSession.new_auth()

    [
      authorize: fn -> OperatorSession.valid?(auth) end,
      session_fingerprint: HarnessForge.Contracts.digest(auth),
      view_generation: String.duplicate("a", 32),
      reset_token: 0
    ]
  end

  defp counts do
    for table <-
          ~w(setup_sessions setup_run_commands model_requests model_budgets stage_operations evaluation_runs capture_runs claim_decisions company_plan_decisions),
        into: %{} do
      [[count]] =
        Repo.query!("SELECT count(*) FROM #{table} WHERE workspace_id=?", [
          Workspaces.current_id()
        ]).rows

      {table, count}
    end
  end
end
