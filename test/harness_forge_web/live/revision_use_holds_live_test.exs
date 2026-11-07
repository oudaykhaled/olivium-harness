defmodule HarnessForgeWeb.RevisionUseHoldsLiveTest do
  use HarnessForgeWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias HarnessForge.{CompanyAnalysisFixture, Evidence, Repo, Workspaces}
  alias HarnessForge.Evidence.{Corpora, RevisionUseHolds}
  alias HarnessForgeWeb.Plugs.OperatorSession

  @canary "PUBLIC_SYNTHETIC_HOLD_BODY_CANARY"

  setup %{conn: conn} do
    previous = {Application.fetch_env!(:harness_forge, :workspace_root), Workspaces.current_id()}
    id = Ecto.UUID.generate()
    root = Path.join(File.cwd!(), "tmp/revision-use-holds-web-#{id}")
    Enum.each(~w(artifacts runs tmp), &File.mkdir_p!(Path.join(root, &1)))
    Application.put_env(:harness_forge, :workspace_root, root)
    Application.put_env(:harness_forge, :workspace_id, id)
    fixture = CompanyAnalysisFixture.create!(root)

    {:ok, source} =
      Evidence.import_markdown(fixture.connection["id"], %{
        "external_id" => "restriction-review.md",
        "title" => "Public synthetic restriction example",
        "body" => @canary <> " A public synthetic example about release review.",
        "metadata" => %{"synthetic" => true}
      })

    on_exit(fn ->
      {old_root, old_id} = previous
      Application.put_env(:harness_forge, :workspace_root, old_root)
      Application.put_env(:harness_forge, :workspace_id, old_id)
      File.rm_rf!(root)
    end)

    {:ok,
     fixture: fixture,
     source: source,
     conn:
       conn
       |> Map.merge(%{host: "localhost", port: 4002})
       |> init_test_session(%{"operator_auth" => OperatorSession.new_auth()})}
  end

  test "blocking is an explicit exact opened-revision action and clears every source-bearing view",
       c do
    before = decision_counts()
    view = inspect_source(c)
    operation = assigns(view).restriction_commands["supplementary"]
    revision = c.source["latest_revision"]
    assert operation["source_id"] == c.source["id"]
    assert operation["revision_id"] == revision["id"]
    assert operation["body_hash"] == revision["body_hash"]
    assert operation["expected_generation"] === 0
    assert has_element?(view, "#corpus-revision-block-confirm-supplementary:not([disabled])")
    refute render(view) =~ operation["command_id"]
    assert hold_count() == 0

    view |> element("#corpus-revision-block-confirm-supplementary") |> render_click()
    receipt = assigns(view).restriction.receipt
    assert receipt["source_id"] == operation["source_id"]
    assert receipt["revision_id"] == operation["revision_id"]
    assert receipt["body_hash"] == operation["body_hash"]
    assert receipt["cleanup_state"] == "pending"
    assert receipt["cleanup_version"] === 0
    assert_patch(view, "/company/corpus?restriction_event=" <> receipt["event_id"])

    assert has_element?(
             view,
             "#corpus-restriction-pending",
             "Cleanup pending; stored bytes may remain."
           )

    assert has_element?(view, "#corpus-restriction-cleanup")
    assert_source_views_cleared(view)
    assert hold_count() == 1

    assert [[operation["command_id"]]] ==
             Repo.query!("SELECT command_id FROM revision_use_holds WHERE id=?", [
               receipt["event_id"]
             ]).rows

    assert decision_counts() == before
  end

  test "refresh and reconnect restore only the durable receipt and never resume cleanup", c do
    view = inspect_source(c)
    view |> element("#corpus-revision-block-confirm-supplementary") |> render_click()
    receipt = assigns(view).restriction.receipt
    url = "/company/corpus?restriction_event=" <> receipt["event_id"]
    before = checkpoint(receipt["event_id"])

    disconnected = get(c.conn, url) |> html_response(200)
    refute disconnected =~ @canary
    assert disconnected =~ "Cleanup pending; stored bytes may remain."

    assert disconnected
           |> LazyHTML.from_document()
           |> LazyHTML.query("#corpus-restriction-cleanup[disabled]")
           |> Enum.count() == 1

    assert disconnected
           |> LazyHTML.from_document()
           |> LazyHTML.query("#corpus-restriction-status[disabled]")
           |> Enum.count() == 1

    {:ok, reopened, html} = live(c.conn, url)
    refute html =~ @canary
    assert assigns(reopened).restriction.receipt == receipt
    assert_source_views_cleared(reopened)
    assert checkpoint(receipt["event_id"]) == before
    send(reopened.pid, :corpus_cache_reset)
    assert render(reopened) =~ "Cleanup pending; stored bytes may remain."
    assert assigns(reopened).restriction.receipt == receipt
    assert checkpoint(receipt["event_id"]) == before
  end

  test "explicit cleanup completes a bounded saved operation without restoring inspection", c do
    {:ok, corpus} = Corpora.create(%{"name" => "Public restriction cleanup corpus"}, caller())

    assert {:ok, _} =
             Corpora.apply_members(
               corpus["id"],
               corpus["semantic_generation"],
               [
                 %{
                   "source_id" => c.source["id"],
                   "revision_id" => c.source["latest_revision"]["id"],
                   "action" => "include"
                 }
               ],
               caller()
             )

    view = inspect_source(c)
    view |> element("#corpus-revision-block-confirm-supplementary") |> render_click()
    initial = assigns(view).restriction.receipt
    assert checkpoint(initial["event_id"]) == ["pending", "", 0]

    view |> element("#corpus-restriction-cleanup") |> render_click()
    completed = assigns(view).restriction.receipt
    assert completed["event_id"] == initial["event_id"]
    assert completed["cleanup_state"] == "completed"
    assert completed["cleanup_version"] === 1
    assert has_element?(view, "#corpus-restriction-completed", "Use remains blocked")
    refute has_element?(view, "#corpus-restriction-cleanup")
    assert_source_views_cleared(view)

    assert {:error, :revision_use_denied} =
             RevisionUseHolds.assert_use(
               c.source["id"],
               initial["revision_id"],
               initial["body_hash"],
               "inspection"
             )

    assert [[c.source["latest_revision"]["body"]]] ==
             Repo.query!("SELECT body FROM evidence_revisions WHERE id=?", [
               initial["revision_id"]
             ]).rows

    saved = checkpoint(initial["event_id"])
    view |> element("#corpus-restriction-status") |> render_click()
    assert checkpoint(initial["event_id"]) == saved
    assert {:ok, ^completed} = Evidence.resume_revision_cleanup(initial["event_id"], 0, caller())
    assert checkpoint(initial["event_id"]) == saved
  end

  test "a failed acknowledgement retries the original command even when its event already committed",
       c do
    view = inspect_source(c)
    operation = assigns(view).restriction_commands["supplementary"]

    Repo.query!(
      "CREATE TRIGGER web_restriction_failure BEFORE INSERT ON revision_use_holds BEGIN SELECT RAISE(ABORT,'synthetic test insertion failure'); END"
    )

    try do
      view |> element("#corpus-revision-block-confirm-supplementary") |> render_click()
      assert assigns(view).restriction.operation == operation
      assert assigns(view).restriction.receipt == nil
      assert has_element?(view, "#corpus-restriction-retry")
      assert_source_views_cleared(view)
      assert hold_count() == 0
    after
      Repo.query!("DROP TRIGGER IF EXISTS web_restriction_failure")
    end

    # Model an acknowledgement lost after durable commit using the real command API.
    # The UI still holds its failed acknowledgement, never a fabricated success receipt.
    assert {:ok, committed} = Evidence.restrict_revision(operation, caller())
    view |> element("#corpus-restriction-retry") |> render_click()
    receipt = assigns(view).restriction.receipt
    assert receipt == committed
    assert receipt["cleanup_state"] == "pending"

    assert [[operation["command_id"]]] ==
             Repo.query!("SELECT command_id FROM revision_use_holds WHERE id=?", [
               receipt["event_id"]
             ]).rows

    assert hold_count() == 1
    assert_source_views_cleared(view)
  end

  test "cleanup failure clears the view and permits metadata status recovery without another mutation",
       c do
    view = inspect_source(c)
    view |> element("#corpus-revision-block-confirm-supplementary") |> render_click()
    receipt = assigns(view).restriction.receipt
    before = checkpoint(receipt["event_id"])

    Repo.query!(
      "CREATE TRIGGER web_cleanup_failure BEFORE UPDATE ON revision_use_cleanup BEGIN SELECT RAISE(ABORT,'synthetic test checkpoint failure'); END"
    )

    try do
      view |> element("#corpus-restriction-cleanup") |> render_click()
      assert has_element?(view, "#corpus-restriction-error")
      assert has_element?(view, "#corpus-restriction-status")
      assert_source_views_cleared(view)
      assert checkpoint(receipt["event_id"]) == before
    after
      Repo.query!("DROP TRIGGER IF EXISTS web_cleanup_failure")
    end

    view |> element("#corpus-restriction-status") |> render_click()
    assert assigns(view).restriction.receipt == receipt
    assert checkpoint(receipt["event_id"]) == before
    refute render(view) =~ @canary
  end

  test "stale, forged, unopened and closed-window block events cannot select another revision",
       c do
    for extra <- [
          %{"source_id" => c.fixture.uncited_source["id"]},
          %{"command_id" => Ecto.UUID.generate()},
          %{"expected_generation" => 1},
          %{"denied_purposes" => ["inspection"]},
          %{"inspection" => "other"}
        ] do
      view = inspect_source(c)

      render_click(
        view,
        "corpus_revision_block",
        Map.merge(
          %{
            "corpus_generation" => assigns(view).generation,
            "inspection" => "supplementary"
          },
          extra
        )
      )

      assert has_element?(view, "#corpus-restriction-error")
      assert_source_views_cleared(view)
      assert hold_count() == 0
    end

    view = inspect_source(c)
    generation = assigns(view).generation
    view |> element("#corpus-passage-close") |> render_click()

    render_click(view, "corpus_revision_block", %{
      "corpus_generation" => generation,
      "inspection" => "supplementary"
    })

    assert has_element?(view, "#corpus-restriction-error")
    assert hold_count() == 0

    {:ok, fresh, _} = live(c.conn, "/company/corpus")

    render_click(fresh, "corpus_revision_block", %{
      "corpus_generation" => generation,
      "inspection" => "supplementary"
    })

    assert has_element?(fresh, "#corpus-restriction-error")
    assert hold_count() == 0
  end

  test "forged cleanup event, cursor, version or policy fields cannot advance the checkpoint",
       c do
    view = inspect_source(c)
    view |> element("#corpus-revision-block-confirm-supplementary") |> render_click()
    receipt = assigns(view).restriction.receipt
    before = checkpoint(receipt["event_id"])

    for extra <- [
          %{"event_id" => Ecto.UUID.generate()},
          %{"cursor" => "client-cursor"},
          %{"cleanup_version" => 999},
          %{"cleanup_state" => "completed"},
          %{"policy_generation" => 0}
        ] do
      {:ok, reopened, _} =
        live(c.conn, "/company/corpus?restriction_event=" <> receipt["event_id"])

      render_click(
        reopened,
        "corpus_revision_cleanup",
        Map.put(extra, "corpus_generation", assigns(reopened).generation)
      )

      assert has_element?(reopened, "#corpus-restriction-error")
      assert checkpoint(receipt["event_id"]) == before
      assert_source_views_cleared(reopened)
    end
  end

  test "an external pending restriction clears cached opened text on the next authenticated action",
       c do
    view = inspect_source(c)
    operation = assigns(view).restriction_commands["supplementary"]
    assert {:ok, receipt} = Evidence.restrict_revision(operation, caller())
    assert receipt["cleanup_state"] == "pending"
    view |> element("#corpus-search-form") |> render_submit(%{"search" => %{"query" => "review"}})
    assert_source_views_cleared(view)
    assert checkpoint(receipt["event_id"]) == ["pending", "", 0]

    {:ok, current, _} = live(c.conn, "/company/corpus")
    open_scope(current, c.fixture)
    refute has_element?(current, "#corpus-source-" <> c.source["id"])
    assert has_element?(current, "#corpus-source-" <> c.fixture.uncited_source["id"])
    refute render(current) =~ @canary
  end

  test "unknown, malformed, foreign and extra-key receipt URLs disclose no prior evidence", c do
    view = inspect_source(c)
    view |> element("#corpus-revision-block-confirm-supplementary") |> render_click()
    receipt = assigns(view).restriction.receipt

    for query <- [
          "restriction_event=" <> Ecto.UUID.generate(),
          "restriction_event=not-an-event",
          "restriction_event=" <> receipt["event_id"] <> "&cleanup_state=completed",
          "restriction_event=" <> receipt["event_id"] <> "&declaration=" <> Ecto.UUID.generate()
        ] do
      {:ok, denied, html} = live(c.conn, "/company/corpus?" <> query)
      assert has_element?(denied, "#corpus-restriction-error")
      refute html =~ @canary
      assert assigns(denied).restriction.receipt == nil
    end

    old = Workspaces.current_id()
    Application.put_env(:harness_forge, :workspace_id, Ecto.UUID.generate())

    try do
      assert {:error, {:redirect, %{to: "/login"}}} =
               live(c.conn, "/company/corpus?restriction_event=" <> receipt["event_id"])

      foreign_conn = init_test_session(c.conn, %{"operator_auth" => OperatorSession.new_auth()})

      {:ok, foreign, html} =
        live(foreign_conn, "/company/corpus?restriction_event=" <> receipt["event_id"])

      assert has_element?(
               foreign,
               "#corpus-restriction-error",
               "unavailable in the current workspace"
             )

      refute html =~ receipt["revision_id"]
      refute html =~ @canary
    after
      Application.put_env(:harness_forge, :workspace_id, old)
    end
  end

  test "normal authentication protects receipts and a revoked session cannot perform cleanup",
       c do
    view = inspect_source(c)
    view |> element("#corpus-revision-block-confirm-supplementary") |> render_click()
    receipt = assigns(view).restriction.receipt
    before = checkpoint(receipt["event_id"])
    unauthenticated = build_conn() |> Map.merge(%{host: "localhost", port: 4002})

    assert {:error, {:redirect, %{to: "/login"}}} =
             live(unauthenticated, "/company/corpus?restriction_event=" <> receipt["event_id"])

    send(view.pid, :operator_session_revoked)
    assert_redirect(view, "/login")
    assert checkpoint(receipt["event_id"]) == before
  end

  test "selected analysis passage controls use their own server-owned exact revision", c do
    view = inspect_source(c)

    for source <- [c.source | c.fixture.sources] do
      File.write!(
        Path.join(c.fixture.connection["directory"], source["external_id"]),
        source["latest_revision"]["body"]
      )
    end

    view |> element("button[phx-click=corpus_capture_start]") |> render_click()
    capture = assigns(view).large.capture
    assert {:ok, _} = Evidence.Capture.run(capture["run_id"])

    ids =
      Repo.query!(
        "SELECT latest_revision_id FROM evidence_sources WHERE workspace_id=? AND connection_id=?",
        [Workspaces.current_id(), c.fixture.connection["id"]]
      ).rows
      |> List.flatten()

    for id <- ids, do: assert({:ok, _} = Evidence.Passages.index_revision(id))
    view |> element("button[phx-click=corpus_capture_status]") |> render_click()

    view
    |> form("#company-corpus-question",
      retrieval: %{question: "Which release review applies?", mode: "fts"}
    )
    |> render_submit()

    render_async(view)
    [selected | _] = assigns(view).large.page["rows"]

    render_click(view, "corpus_run_passage", %{
      "corpus_generation" => assigns(view).generation,
      "passage_id" => selected["passage_id"]
    })

    command = assigns(view).restriction_commands["selected"]
    assert command["source_id"] == selected["source_id"]
    assert command["revision_id"] == selected["revision_id"]
    assert has_element?(view, "#corpus-revision-block-confirm-selected:not([disabled])")
    view |> element("#corpus-revision-block-confirm-selected") |> render_click()
    receipt = assigns(view).restriction.receipt
    assert receipt["source_id"] == selected["source_id"]
    assert receipt["revision_id"] == selected["revision_id"]
    assert_source_views_cleared(view)
  end

  defp inspect_source(c) do
    {:ok, view, _} = live(c.conn, "/company/corpus")
    open_scope(view, c.fixture)
    view |> element("#corpus-source-open-" <> c.source["id"]) |> render_click()
    assert has_element?(view, "#corpus-passage-text", @canary)
    view
  end

  defp open_scope(view, fixture) do
    selection = %{
      connection_id: fixture.connection["id"],
      project_id: fixture.project["id"],
      goal_id: "",
      goal_content_hash: ""
    }

    view |> form("#corpus-scope-form", scope: selection) |> render_change()

    view
    |> form("#corpus-scope-form", scope: Map.put(selection, :goal_id, fixture.goal["id"]))
    |> render_change()

    view |> form("#corpus-scope-form") |> render_submit()
  end

  defp assert_source_views_cleared(view) do
    state = assigns(view)
    for key <- [:scope, :page, :passage, :recommendation], do: assert(state.state[key] == nil)

    for key <- [
          :corpus,
          :capture,
          :run,
          :page,
          :passage,
          :stage,
          :claim,
          :analysis_observation,
          :declaration
        ],
        do: assert(state.large[key] == nil)

    assert Enum.all?(state.state.choices, fn {_kind, page} -> page["rows"] == [] end)
    assert state.state.query == ""
    assert state.large.question == ""
    assert state.scope_token == nil
    assert state.restriction_commands == %{}
    refute render(view) =~ @canary
    refute has_element?(view, "#corpus-passage, #company-corpus-results, #corpus-original-report")
  end

  defp caller do
    [
      authorize: fn -> true end,
      session_fingerprint: String.duplicate("f", 64),
      view_generation: String.duplicate("e", 32),
      reset_token: 0
    ]
  end

  defp checkpoint(event_id) do
    Repo.query!(
      "SELECT state,cursor,lock_version FROM revision_use_cleanup WHERE workspace_id=? AND event_id=?",
      [Workspaces.current_id(), event_id]
    ).rows
    |> hd()
  end

  defp hold_count do
    [[count]] =
      Repo.query!("SELECT count(*) FROM revision_use_holds WHERE workspace_id=?", [
        Workspaces.current_id()
      ]).rows

    count
  end

  defp decision_counts do
    for table <-
          ~w(evidence_citations evidence_claims claim_decisions company_plans company_plan_decisions model_requests),
        into: %{} do
      [[count]] =
        Repo.query!("SELECT count(*) FROM #{table} WHERE workspace_id=?", [
          Workspaces.current_id()
        ]).rows

      {table, count}
    end
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns
end
