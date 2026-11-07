defmodule HarnessForgeWeb.SetupAnalysisLiveTest do
  use HarnessForgeWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias HarnessForge.{Company, CompanyAnalysisFixture, Contracts, Goals, Repo, Workspaces}
  alias HarnessForge.Company.{SetupSessions, SetupRuns}
  alias HarnessForge.Evidence.{Corpora, Store}
  alias HarnessForge.Models.Configuration
  alias HarnessForgeWeb.Plugs.OperatorSession

  setup %{conn: conn} do
    previous = {Workspaces.root(), Workspaces.current_id()}
    id = Ecto.UUID.generate()
    root = Path.join(File.cwd!(), "tmp/setup-analysis-web-#{id}")
    Enum.each(~w(artifacts runs tmp), &File.mkdir_p!(Path.join(root, &1)))
    Application.put_env(:harness_forge, :workspace_root, root)
    Application.put_env(:harness_forge, :workspace_id, id)

    on_exit(fn ->
      Application.put_env(:harness_forge, :workspace_root, elem(previous, 0))
      Application.put_env(:harness_forge, :workspace_id, elem(previous, 1))
      File.rm_rf!(root)
    end)

    {:ok, _} =
      Configuration.configure(%{"provider" => "ollama", "model" => "synthetic-config-only"})

    %{
      root: root,
      conn:
        %{conn | host: "localhost", port: 4002}
        |> init_test_session(%{"operator_auth" => OperatorSession.new_auth()})
    }
  end

  test "reopening saved scope reads only; explicit proposal displays bounds with no inference",
       c do
    {saved, f} = saved_scope(c.root)
    before = admissions()
    html = c.conn |> get(path(saved)) |> html_response(200)
    assert html =~ "setup-analysis"
    assert html =~ "setup-connected-controls"
    assert {:ok, %{"run" => nil}} = SetupRuns.get(saved["id"], caller())
    {:ok, view, _} = live(c.conn, path(saved))
    assert has_element?(view, "#setup-analysis-next[disabled]", "Review local analysis proposal")

    view
    |> form("#setup-analysis-connection-form", %{"connection_id" => f.connection["id"]})
    |> render_change()

    view |> element("#setup-analysis-next") |> render_click()
    render_async(view)
    assert has_element?(view, "#setup-analysis-phase", "proposed")
    assert has_element?(view, "#setup-analysis-query", f.goal["title"])
    assert has_element?(view, "#setup-analysis-profile", "500 files")
    assert has_element?(view, "#setup-analysis-next", "Approve and capture")
    refute has_element?(view, "#setup-continue:not([disabled])")
    assert admissions() == before
    {:ok, current} = SetupSessions.get(%{"id" => saved["id"]}, caller())
    {:ok, reopened, _} = live(c.conn, path(current))
    assert has_element?(reopened, "#setup-analysis-phase", "proposed")
    assert admissions() == before
  end

  test "missing configured local model is visible and creates no run or fallback", c do
    {saved, f} = saved_scope(c.root)
    {:ok, _} = Configuration.configure(%{"provider" => "ollama", "model" => nil})
    {:ok, view, _} = live(c.conn, path(saved))
    before = admissions()

    view
    |> form("#setup-analysis-connection-form", %{"connection_id" => f.connection["id"]})
    |> render_change()

    view |> element("#setup-analysis-next") |> render_click()
    render_async(view)
    assert has_element?(view, "#setup-analysis-error", "configured local Ollama model")
    assert has_element?(view, "#setup-analysis-error", "No cloud fallback")
    assert {:ok, %{"run" => nil}} = SetupRuns.get(saved["id"], caller())
    assert admissions() == before
  end

  test "dirty input and forged displayed preparation cannot dispatch", c do
    {saved, f} = saved_scope(c.root)
    {:ok, view, _} = live(c.conn, path(saved))
    before = admissions()

    view
    |> form("#setup-step-form", %{"setup" => %{"scope_note" => "Keep this local draft"}})
    |> render_change()

    assert has_element?(view, "#setup-unsaved")
    attrs = run_attrs(view, "prepare")
    render_click(view, "setup_run", attrs)
    assert has_element?(view, "#setup-analysis-error", "Save local changes")
    assert has_element?(view, "#setup-scope-note", "Keep this local draft")
    view |> element("#setup-reload") |> render_click()

    view
    |> form("#setup-analysis-connection-form", %{"connection_id" => f.connection["id"]})
    |> render_change()

    render_click(
      view,
      "setup_run",
      Map.put(
        run_attrs(view, "prepare"),
        "prepared_ref",
        Ecto.UUID.generate() <> ":" <> String.duplicate("a", 64)
      )
    )

    assert {:ok, %{"run" => nil}} = SetupRuns.get(saved["id"], caller())

    render_click(
      view,
      "setup_run",
      Map.put(run_attrs(view, "prepare"), "setup_generation", "stale")
    )

    assert admissions() == before
  end

  test "stale run versions require explicit reload and preserve the local view", c do
    {saved, f} = saved_scope(c.root)
    {:ok, first, _} = live(c.conn, path(saved))
    {:ok, second, _} = live(c.conn, path(saved))

    for view <- [first, second],
        do:
          view
          |> form("#setup-analysis-connection-form", %{"connection_id" => f.connection["id"]})
          |> render_change()

    first |> element("#setup-analysis-next") |> render_click()
    render_async(first)
    before = admissions()
    second |> element("#setup-analysis-next") |> render_click()
    render_async(second)
    assert has_element?(second, "#setup-analysis-error", "changed")
    refute has_element?(second, "#setup-analysis-phase", "proposed")
    second |> element("#setup-reload") |> render_click()
    assert has_element?(second, "#setup-analysis-phase", "proposed")
    assert admissions() == before
  end

  test "privacy reset and reauthentication recheck saved state without repeating work", c do
    {saved, f} = saved_scope(c.root)
    {:ok, view, _} = live(c.conn, path(saved))

    view
    |> form("#setup-analysis-connection-form", %{"connection_id" => f.connection["id"]})
    |> render_change()

    view |> element("#setup-analysis-next") |> render_click()
    render_async(view)
    before = admissions()
    old_generation = socket(view).generation
    send(view.pid, :corpus_cache_reset)
    render(view)
    refute has_element?(view, "#setup-analysis-query")
    refute socket(view).generation == old_generation
    view |> element("#setup-reload") |> render_click()
    assert has_element?(view, "#setup-analysis-phase", "proposed")

    fresh_conn =
      %{build_conn() | host: "localhost", port: 4002}
      |> init_test_session(%{"operator_auth" => OperatorSession.new_auth()})

    {:ok, current} = SetupSessions.get(%{"id" => saved["id"]}, caller())
    {:ok, fresh, _} = live(fresh_conn, path(current))
    assert has_element?(fresh, "#setup-analysis-phase", "proposed")
    assert admissions() == before
    send(fresh.pid, :operator_session_revoked)
    assert_redirect(fresh, "/login")
  end

  test "superseded coverage stays a historical reference without changing the current run", c do
    {saved, f} = saved_scope(c.root, coverage: true)
    {:ok, view, _} = live(c.conn, path(saved))
    assert has_element?(view, "label[for=setup-declaration]", "saved coverage declaration")
    refute has_element?(view, "#setup-saved-coverage")
    propose(view, f)
    declare_coverage(saved["selection"]["corpus_id"], f)

    {:ok, before} = SetupRuns.get(saved["id"], caller())
    {:ok, saved_before} = SetupSessions.get(%{"id" => saved["id"]}, caller())
    counts = admissions()
    view |> element("#setup-reload") |> render_click()

    old = saved["selection"]["declaration"]
    token = old["id"] <> ":" <> old["digest"]
    assert has_element?(view, "#setup-saved-coverage code", token)
    assert has_element?(view, "label[for=setup-declaration]", "Previously saved coverage")
    assert has_element?(view, "#setup-declaration option[selected][value='#{token}']")
    assert has_element?(view, "#setup-reference-status", "Some saved records have changed")
    assert has_element?(view, "#setup-analysis-phase", "proposed")
    assert has_element?(view, "#setup-analysis-next:not([disabled])", "Approve and capture")
    assert {:ok, ^before} = SetupRuns.get(saved["id"], caller())
    assert {:ok, ^saved_before} = SetupSessions.get(%{"id" => saved["id"]}, caller())
    assert admissions() == counts

    {:ok, _} =
      Company.update_project(
        f.project["id"],
        f.project["payload"]
        |> Map.put("name", "Changed synthetic scope")
        |> Map.put("expected_content_hash", f.project["content_hash"])
      )

    view |> element("#setup-reload") |> render_click()
    assert has_element?(view, "#setup-reference-status", "Some saved records have changed")
    assert has_element?(view, "#setup-analysis-phase", "blocked")
    assert has_element?(view, "#setup-analysis [role=alert]", "run or its evidence changed")

    assert has_element?(
             view,
             "#setup-choices-error",
             "Saved source coverage is unavailable or stale"
           )

    refute has_element?(view, "#setup-continue:not([disabled])")
    assert {:ok, current} = SetupRuns.get(saved["id"], caller())
    assert current["run"]["run_ref"] == before["run"]["run_ref"]
    assert current["run"]["run_version"] == before["run"]["run_version"]
    assert current["run"]["config"] == before["run"]["config"]
    assert admissions() == counts
  end

  test "a synthetic expired phase renders Cancel and closes the same run through the saved command",
       c do
    {saved, f} = saved_scope(c.root)
    {:ok, view, _} = live(c.conn, path(saved))
    propose(view, f)
    {:ok, proposed} = SetupRuns.get(saved["id"], caller())

    # Seed only the mutable phase for UI wiring; this does not establish clock expiry.
    Repo.query!(
      "UPDATE setup_run_states SET phase='expired' WHERE workspace_id=? AND run_id=?",
      [Store.workspace(), proposed["run"]["run_ref"]["id"]]
    )

    view |> element("#setup-reload") |> render_click()
    {:ok, expired} = SetupRuns.get(saved["id"], caller())
    counts = admissions()
    assert has_element?(view, "#setup-analysis-phase", "expired")
    assert has_element?(view, "#setup-analysis-recovery", "Authorization expired")
    assert has_element?(view, "#setup-analysis-cancel:not([disabled])")
    assert has_element?(view, "#setup-analysis-next", "Prepare a replacement run")
    refute has_element?(view, "[phx-value-action=retry]")
    refute has_element?(view, "#setup-continue:not([disabled])")
    view |> element("#setup-analysis-cancel") |> render_click()
    render_async(view)

    assert {:ok, cancelled} = SetupRuns.get(saved["id"], caller())
    assert cancelled["session_version"] == expired["session_version"] + 1
    assert cancelled["run"]["run_version"] == expired["run"]["run_version"] + 1
    assert cancelled["run"]["phase"] == "cancelled"
    assert cancelled["run"]["run_ref"] == expired["run"]["run_ref"]
    assert cancelled["run"]["config"] == expired["run"]["config"]
    assert cancelled["run"]["usage"] == expired["run"]["usage"]
    assert cancelled["run"]["result_ref"] == nil
    assert cancelled["available_actions"] == ["new_run"]
    refute has_element?(view, "#setup-analysis-cancel")
    assert admissions() == counts
  end

  test "scope-note save preserves the run while a changed outcome note cancels it", c do
    {saved, f} = saved_scope(c.root)
    {:ok, view, _} = live(c.conn, path(saved))
    propose(view, f)
    {:ok, before} = SetupRuns.get(saved["id"], caller())
    counts = admissions()

    view
    |> form("#setup-step-form", %{"setup" => %{"scope_note" => "Review this scope"}})
    |> render_submit(%{"setup_command" => "save"})

    {:ok, noted} = SetupRuns.get(saved["id"], caller())
    assert noted["run"] == before["run"]
    assert has_element?(view, "#setup-choices-run-warning", "revokes its authorization")
    view |> element("#setup-back") |> render_click()
    assert_patch(view, "/setup/#{saved["id"]}/outcome")
    assert has_element?(view, "#setup-note-help", "Changing the outcome note cancels")

    view
    |> form("#setup-step-form", %{"setup" => %{"outcome_note" => "Changed desired outcome"}})
    |> render_submit(%{"setup_command" => "save"})

    assert {:ok, changed} = SetupRuns.get(saved["id"], caller())
    assert changed["run"]["phase"] == "cancelled"
    assert changed["run"]["run_version"] == before["run"]["run_version"] + 1
    assert changed["run"]["config"] == before["run"]["config"]
    assert changed["run"]["usage"] == before["run"]["usage"]
    assert admissions() == counts
  end

  defp saved_scope(root, opts \\ []) do
    f = CompanyAnalysisFixture.create!(root)
    {:ok, corpus} = Corpora.create(%{"name" => "Synthetic saved analysis corpus"}, caller())

    {:ok, _} =
      Company.bind_corpus(
        f.project["id"],
        corpus["id"],
        f.profile["content_hash"],
        f.project["content_hash"],
        caller()
      )

    selection =
      Map.new(
        [{"profile", f.profile}, {"project", f.project}, {"repository", f.repository}],
        fn {key, row} -> {key, Map.take(row, ~w(id content_hash))} end
      )
      |> Map.put("goal", %{"id" => f.goal["id"], "content_hash" => Goals.content_hash(f.goal)})
      |> Map.put("corpus_id", corpus["id"])

    selection =
      if opts[:coverage],
        do:
          Map.put(
            selection,
            "declaration",
            Map.take(declare_coverage(corpus["id"], f), ~w(id digest))
          ),
        else: selection

    {:ok, saved} = SetupSessions.create(%{}, caller())

    {:ok, saved} =
      SetupSessions.command(
        %{
          "id" => saved["id"],
          "expected_version" => saved["version"],
          "command" => "change",
          "payload" => %{"selection" => selection}
        },
        caller()
      )

    {:ok, saved} =
      SetupSessions.command(
        %{
          "id" => saved["id"],
          "expected_version" => saved["version"],
          "command" => "continue",
          "payload" => %{}
        },
        caller()
      )

    {saved, f}
  end

  defp declare_coverage(corpus_id, f) do
    {:ok, context} =
      Corpora.requirements_context(
        corpus_id,
        f.project["id"],
        f.goal["id"],
        Goals.content_hash(f.goal),
        caller()
      )

    {:ok, declaration} =
      Corpora.declare_requirements(
        corpus_id,
        context["expected"],
        %{
          "project_id" => f.project["id"],
          "goal_id" => f.goal["id"],
          "primary_connection_id" => f.connection["id"],
          "entries" => [
            %{
              "connection_id" => f.connection["id"],
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

  defp propose(view, f) do
    view
    |> form("#setup-analysis-connection-form", %{"connection_id" => f.connection["id"]})
    |> render_change()

    view |> element("#setup-analysis-next") |> render_click()
    render_async(view)
    assert has_element?(view, "#setup-analysis-phase", "proposed")
  end

  defp socket(view), do: :sys.get_state(view.pid).socket.assigns
  defp path(saved), do: "/setup/#{saved["id"]}/#{saved["step"]}"

  defp caller do
    auth = OperatorSession.new_auth()

    [
      authorize: fn -> OperatorSession.valid?(auth) end,
      session_fingerprint: Contracts.digest(auth),
      view_generation: String.duplicate("a", 32),
      reset_token: 0
    ]
  end

  defp run_attrs(view, action) do
    s = socket(view)
    run = s.analysis["run"]

    %{
      "action" => action,
      "command_id" => s.analysis_command_id,
      "expected_session_version" => to_string(s.analysis["session_version"]),
      "expected_run_version" => if(run, do: to_string(run["run_version"]), else: ""),
      "prepared_ref" => "",
      "setup_generation" => s.generation
    }
  end

  defp admissions,
    do:
      Map.new(
        ~w(capture_runs model_requests model_budgets model_run_authorizations stage_consent_revisions),
        fn table ->
          {table,
           Repo.query!("SELECT count(*) FROM " <> table <> " WHERE workspace_id=?", [
             Store.workspace()
           ]).rows}
        end
      )
end
