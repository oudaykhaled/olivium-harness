defmodule HarnessForgeWeb.SetupLiveTest do
  use HarnessForgeWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias HarnessForge.{Company, CompanyAnalysisFixture, Contracts, Goals, Repo, Workspaces}
  alias HarnessForge.Company.SetupSessions
  alias HarnessForge.Evidence.Corpora
  alias HarnessForgeWeb.Plugs.OperatorSession

  setup %{conn: conn} do
    previous = {Workspaces.root(), Workspaces.current_id()}
    id = Ecto.UUID.generate()
    root = Path.join(File.cwd!(), "tmp/setup-web-#{id}")
    Enum.each(~w(artifacts runs tmp), &File.mkdir_p!(Path.join(root, &1)))
    Application.put_env(:harness_forge, :workspace_root, root)
    Application.put_env(:harness_forge, :workspace_id, id)

    on_exit(fn ->
      Application.put_env(:harness_forge, :workspace_root, elem(previous, 0))
      Application.put_env(:harness_forge, :workspace_id, elem(previous, 1))
      File.rm_rf!(root)
    end)

    conn = %{conn | host: "localhost", port: 4002} |> authenticate()
    {:ok, conn: conn, root: root}
  end

  test "initial HTML visibly connects with mutations disabled and GET creates no session", c do
    html = c.conn |> get("/setup") |> html_response(200)
    tree = LazyHTML.from_fragment(html)
    assert LazyHTML.query(tree, "#setup-create[disabled]") |> Enum.count() == 1
    assert LazyHTML.query(tree, "#setup-connected-controls[disabled]") |> Enum.count() == 1
    assert html =~ "Connecting. Saved actions"
    assert html =~ "phx-connected"
    assert html =~ "phx-disconnected"
    assert {:ok, []} = SetupSessions.list(%{}, caller())
    {:ok, view, _} = live(c.conn, "/setup")
    assert has_element?(view, "#setup-create:not([disabled])")
    assert {:ok, []} = SetupSessions.list(%{}, caller())
    view |> element("#setup-create") |> render_click()
    assert {:ok, [saved]} = SetupSessions.list(%{}, caller())
    assert_redirect(view, path(saved))
    {:ok, reopened, _} = live(c.conn, path(saved))
    assert has_element?(reopened, "#setup-saved-version", "Saved version 1")
    assert {:ok, same} = SetupSessions.get(%{"id" => saved["id"]}, caller())
    assert same["version"] == 1
  end

  test "draft save and selection acknowledgement survive refresh and reauthentication, then exact scope opens only an unavailable shell",
       c do
    fixture = CompanyAnalysisFixture.create!(c.root)
    declaration = saved_coverage(fixture)
    {:ok, saved} = SetupSessions.create(%{}, caller())
    before = dispatch_counts()
    {:ok, view, _} = live(c.conn, path(saved))

    inputs =
      outcome(fixture)
      |> Map.put("outcome_note", "A saved synthetic outcome, with measurement still unknown.")

    submit(view, inputs, "save")
    assert has_element?(view, "#setup-unsaved")
    assert {:ok, draft} = SetupSessions.get(%{"id" => saved["id"]}, caller())
    assert draft["draft"]["outcome_note"] == inputs["outcome_note"]
    assert draft["selection"]["profile"] == nil
    assert has_element?(view, "#setup-profile option[selected][value='#{inputs["profile"]}']")
    refute has_element?(view, "#setup-continue:not([disabled])")
    assert has_element?(view, "#setup-acknowledge.primary:not([disabled])", "Save choices")
    refute has_element?(view, "#setup-continue.primary")

    reauthenticated =
      OperatorSession.new_auth()
      |> Map.put("issued_at", get_session(c.conn, "operator_auth")["issued_at"] - 1)

    refute Contracts.digest(reauthenticated) ==
             Contracts.digest(get_session(c.conn, "operator_auth"))

    fresh_auth =
      %{build_conn() | host: "localhost", port: 4002}
      |> init_test_session(%{"operator_auth" => reauthenticated})

    {:ok, view, _} = live(fresh_auth, path(draft))
    assert has_element?(view, "#setup-outcome-note", inputs["outcome_note"])
    assert has_element?(view, "#setup-profile option[selected][value='']")
    assert has_element?(view, "#setup-measurement", "Measurement status: unknown")
    submit(view, inputs, "change")
    refute has_element?(view, "#setup-unsaved")
    assert has_element?(view, "#setup-continue:not([disabled])")
    assert has_element?(view, "#setup-continue.primary")
    view |> element("#setup-continue") |> render_click()
    assert_patch(view, "/setup/#{saved["id"]}/scope")
    assert has_element?(view, "#setup-corpus option[selected][value='']")
    assert has_element?(view, "#setup-declaration option[selected][value='']")

    view
    |> form("#setup-step-form", setup: %{"corpus_id" => declaration["scope"]["corpus_id"]})
    |> render_change()

    assert has_element?(view, "#setup-declaration option[selected][value='']")
    assert has_element?(view, "#setup-declaration", "Saved coverage revision")

    scope = %{
      "corpus_id" => declaration["scope"]["corpus_id"],
      "declaration" => token(declaration),
      "scope_note" => "Only this explicitly acknowledged corpus."
    }

    submit(view, scope, "save")
    assert has_element?(view, "#setup-unsaved")
    submit(view, scope, "change")
    refute has_element?(view, "#setup-unsaved")
    view |> element("#setup-continue") |> render_click()
    assert_patch(view, "/setup/#{saved["id"]}/understanding")

    assert has_element?(
             view,
             "#setup-capability-unavailable",
             "Continue in a separate workflow"
           )

    refute has_element?(view, "#setup-continue:not([disabled])")

    corpus_path =
      "/company/corpus?" <>
        URI.encode_query(%{
          "declaration" => declaration["id"],
          "declaration_digest" => declaration["digest"]
        })

    assert has_element?(view, "#setup-open-corpus[href='#{corpus_path}']")
    assert dispatch_counts() == before
    {:ok, durable} = SetupSessions.get(%{"id" => saved["id"]}, caller())
    {:ok, again, _} = live(fresh_auth, path(durable))
    assert has_element?(again, "#setup-capability-unavailable")
    assert durable["draft"]["scope_note"] == scope["scope_note"]
    assert durable["selection"]["declaration"] == Map.take(declaration, ~w(id digest))
    assert dispatch_counts() == before
  end

  test "a stale tab retains its note and expected version until an explicit reload", c do
    {:ok, saved} = SetupSessions.create(%{}, caller())
    {:ok, first, _} = live(c.conn, path(saved))
    {:ok, second, _} = live(c.conn, path(saved))
    before = dispatch_counts()
    first_input = blank_outcome("First committed draft")
    second_input = blank_outcome("Second tab local draft")
    submit(first, first_input, "save")
    second |> form("#setup-step-form", setup: second_input) |> render_change()
    assert has_element?(second, "#setup-save.primary:not([disabled])", "Save note")
    refute has_element?(second, "#setup-continue.primary")
    submit(second, second_input, "save")
    assert has_element?(second, "#setup-conflict", "Current saved version: 2")
    assert has_element?(second, "#setup-reload.primary:not([disabled])")
    refute has_element?(second, "#setup-save.primary")
    assert has_element?(second, "#setup-outcome-note", second_input["outcome_note"])
    assert has_element?(second, "input[name=expected_version][value='1']")
    assert {:ok, current} = SetupSessions.get(%{"id" => saved["id"]}, caller())
    assert current["draft"]["outcome_note"] == first_input["outcome_note"]
    second |> element("#setup-reload") |> render_click()
    refute has_element?(second, "#setup-conflict")
    assert has_element?(second, "#setup-outcome-note", first_input["outcome_note"])
    assert has_element?(second, "input[name=expected_version][value='2']")
    assert dispatch_counts() == before
  end

  test "forged routes cannot advance navigation and malformed versions or ownership fields cannot save",
       c do
    {:ok, saved} = SetupSessions.create(%{}, caller())

    assert {:error, {:live_redirect, %{to: destination}}} =
             live(c.conn, "/setup/#{saved["id"]}/candidate")

    assert destination == path(saved)
    {:ok, view, _} = live(c.conn, destination)
    assert has_element?(view, "#setup-step-title", "Company context")
    version = saved["version"]
    inputs = blank_outcome("Local input")
    generation = socket(view).generation

    render_submit(view, "setup_submit", %{
      "setup_generation" => generation,
      "expected_version" => "01",
      "setup_command" => "save",
      "setup" => inputs
    })

    assert has_element?(view, "#setup-error")

    render_submit(view, "setup_submit", %{
      "setup_generation" => generation,
      "expected_version" => "1",
      "setup_command" => "save",
      "setup" => inputs,
      "owner" => "forged"
    })

    assert {:ok, unchanged} = SetupSessions.get(%{"id" => saved["id"]}, caller())
    assert unchanged["version"] == version
    assert unchanged["step"] == "outcome"
    assert unchanged["draft"] == %{}
    Repo.query!("UPDATE setup_sessions SET owner=? WHERE id=?", ["foreign-owner", saved["id"]])
    {:ok, denied, _} = live(c.conn, path(saved))
    assert has_element?(denied, "#setup-error", "unavailable for the current workspace")
    refute has_element?(denied, "#setup-step-form")
  end

  test "reopen and reload withhold revoked catalogue choices while unrelated choices remain usable",
       c do
    fixture = CompanyAnalysisFixture.create!(c.root)

    {:ok, independent} =
      Company.create_project(%{
        "name" => "Independent setup project",
        "repository_ids" => [fixture.repository["id"]],
        "source_ids" => []
      })

    {:ok, saved} = SetupSessions.create(%{}, caller())
    {:ok, view, _} = live(c.conn, path(saved))
    submit(view, outcome(fixture), "change")
    before = dispatch_counts()

    Repo.query!("UPDATE source_connections SET status='revoked' WHERE workspace_id=? AND id=?", [
      Workspaces.current_id(),
      fixture.connection["id"]
    ])

    assert {:ok, redacted} = SetupSessions.get(%{"id" => saved["id"]}, caller())
    assert redacted["selection"]["profile"] == nil
    assert redacted["selection"]["project"] == nil
    {:ok, reopened, _} = live(c.conn, path(saved))

    for reload? <- [false, true] do
      if reload?, do: reopened |> element("#setup-reload") |> render_click()
      refute has_element?(reopened, "#setup-profile option[value='#{token(fixture.profile)}']")
      refute has_element?(reopened, "#setup-project option[value='#{token(fixture.project)}']")
      refute render(reopened) =~ fixture.profile["payload"]["name"]
      refute render(reopened) =~ fixture.project["payload"]["name"]
      assert has_element?(reopened, "#setup-choices-warning")
      assert has_element?(reopened, "#setup-project option[value='#{token(independent)}']")
    end

    partial =
      blank_outcome("")
      |> Map.put("project", token(independent))
      |> Map.put("repository", token(fixture.repository))

    submit(reopened, partial, "change")
    assert {:ok, updated} = SetupSessions.get(%{"id" => saved["id"]}, caller())
    assert updated["selection"]["project"] == Map.take(independent, ~w(id content_hash))
    assert updated["reference_status"]["fields"]["project"] == "current"
    refute has_element?(reopened, "#setup-continue:not([disabled])")
    assert dispatch_counts() == before
  end

  test "changed catalog pins remain historical and failed acknowledgement retains local input",
       c do
    fixture = CompanyAnalysisFixture.create!(c.root)
    {:ok, saved} = SetupSessions.create(%{}, caller())
    {:ok, view, _} = live(c.conn, path(saved))
    inputs = outcome(fixture) |> Map.put("outcome_note", "Keep this unsaved local note")
    submit(view, inputs, "change")
    assert has_element?(view, "#setup-unsaved")

    {:ok, _} =
      Company.update_project(
        fixture.project["id"],
        fixture.project["payload"]
        |> Map.put("name", "Changed synthetic project")
        |> Map.put("expected_content_hash", fixture.project["content_hash"])
      )

    submit(view, inputs, "change")
    assert has_element?(view, "#setup-error", "saved reference changed")
    assert has_element?(view, "#setup-outcome-note", inputs["outcome_note"])
    view |> element("#setup-reload") |> render_click()
    assert has_element?(view, "#setup-reference-status", "Some saved records have changed")
    assert has_element?(view, "#setup-project option[selected][value='#{inputs["project"]}']")
    refute has_element?(view, "#setup-continue:not([disabled])")
    {:ok, same} = SetupSessions.get(%{"id" => saved["id"]}, caller())
    assert same["selection"]["project"]["content_hash"] == fixture.project["content_hash"]
  end

  test "privacy and session invalidation clear setup previews, and unsent navigation dispatches nothing",
       c do
    {:ok, saved} = SetupSessions.create(%{}, caller())
    {:ok, view, _} = live(c.conn, path(saved))
    before = dispatch_counts()
    view |> form("#setup-step-form", setup: blank_outcome("Unsaved")) |> render_change()

    render_click(view, "setup_continue", %{
      "setup_generation" => socket(view).generation,
      "expected_version" => "1"
    })

    assert has_element?(view, "#setup-error", "Back and Continue do not save changes")
    assert {:ok, same} = SetupSessions.get(%{"id" => saved["id"]}, caller())
    assert same["version"] == 1
    send(view.pid, :corpus_cache_reset)
    render(view)
    refute has_element?(view, "#setup-step-form")
    assert has_element?(view, "#setup-error", "privacy changed")
    assert dispatch_counts() == before
    send(view.pid, :operator_session_revoked)
    assert_redirect(view, "/login")
  end

  defp submit(view, inputs, command) do
    for field <- ~w(profile project repository goal corpus_id declaration),
        Map.has_key?(inputs, field) do
      view
      |> form("#setup-step-form", setup: Map.take(inputs, [field, "outcome_note", "scope_note"]))
      |> render_change()
    end

    view
    |> form("#setup-step-form", setup: inputs)
    |> render_submit(%{"setup_command" => command})
  end

  defp blank_outcome(note),
    do: %{
      "profile" => "",
      "project" => "",
      "repository" => "",
      "goal" => "",
      "outcome_note" => note
    }

  defp outcome(f),
    do: %{
      "profile" => token(f.profile),
      "project" => token(f.project),
      "repository" => token(f.repository),
      "goal" => token(%{"id" => f.goal["id"], "content_hash" => Goals.content_hash(f.goal)}),
      "outcome_note" => ""
    }

  defp token(%{"id" => id, "digest" => digest}), do: id <> ":" <> digest
  defp token(%{"id" => id, "content_hash" => hash}), do: id <> ":" <> hash
  defp path(saved), do: "/setup/#{saved["id"]}/#{saved["step"]}"
  defp socket(view), do: :sys.get_state(view.pid).socket.assigns

  defp authenticate(conn),
    do: init_test_session(conn, %{"operator_auth" => OperatorSession.new_auth()})

  defp caller do
    auth = OperatorSession.new_auth()

    [
      authorize: fn -> OperatorSession.valid?(auth) end,
      session_fingerprint: Contracts.digest(auth),
      view_generation: String.duplicate("a", 32),
      reset_token: 0
    ]
  end

  defp dispatch_counts do
    Map.new(~w(model_requests evaluation_runs evidence_claims), fn table ->
      {table,
       Repo.query!("SELECT count(*) FROM " <> table <> " WHERE workspace_id=?", [
         Workspaces.current_id()
       ]).rows}
    end)
  end

  defp saved_coverage(fixture) do
    {:ok, corpus} = Corpora.create(%{"name" => "Synthetic setup source scope"}, caller())

    {:ok, _} =
      Company.bind_corpus(
        fixture.project["id"],
        corpus["id"],
        fixture.profile["content_hash"],
        fixture.project["content_hash"],
        caller()
      )

    goal_hash = Goals.content_hash(fixture.goal)

    {:ok, context} =
      Corpora.requirements_context(
        corpus["id"],
        fixture.project["id"],
        fixture.goal["id"],
        goal_hash,
        caller()
      )

    {:ok, declaration} =
      Corpora.declare_requirements(
        corpus["id"],
        context["expected"],
        %{
          "project_id" => fixture.project["id"],
          "goal_id" => fixture.goal["id"],
          "primary_connection_id" => fixture.connection["id"],
          "entries" => [
            %{
              "connection_id" => fixture.connection["id"],
              "requirement" => "required",
              "capture_run_id" => nil,
              "capture_revision" => nil
            }
          ]
        },
        caller()
      )

    declaration
  end
end
