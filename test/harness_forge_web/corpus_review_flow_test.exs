defmodule HarnessForgeWeb.CorpusReviewFlowTest do
  use HarnessForgeWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias HarnessForge.{Company, CompanyAnalysisFixture, Evidence, Goals, Models, Repo, Workspaces}
  alias HarnessForgeWeb.Plugs.OperatorSession

  setup %{conn: conn} = context do
    previous = {Application.fetch_env!(:harness_forge, :workspace_root), Workspaces.current_id()}
    id = Ecto.UUID.generate()
    root = Path.join(File.cwd!(), "tmp/corpus-review-flow-#{id}")
    Enum.each(~w(artifacts runs tmp), &File.mkdir_p!(Path.join(root, &1)))
    Application.put_env(:harness_forge, :workspace_root, root)
    Application.put_env(:harness_forge, :workspace_id, id)
    fixture = CompanyAnalysisFixture.create!(root)

    extras =
      for number <- 1..Map.get(context, :extra_source_count, 38) do
        {:ok, source} =
          Evidence.import_markdown(fixture.connection["id"], %{
            "external_id" => "extra-#{number}.md",
            "title" => "Synthetic additional capture #{number}",
            "body" =>
              "UNOPENED_BODY_CANARY_#{number} " <>
                String.duplicate("café 東京 ", 600) <> " latelexicalneedle scopedcontext"
          })

        source
      end

    on_exit(fn ->
      {old_root, old_id} = previous
      Application.put_env(:harness_forge, :workspace_root, old_root)
      Application.put_env(:harness_forge, :workspace_id, old_id)
      File.rm_rf!(root)
    end)

    {:ok,
     fixture: fixture,
     extras: extras,
     conn:
       conn
       |> Map.merge(%{host: "localhost", port: 4002})
       |> init_test_session(%{"operator_auth" => OperatorSession.new_auth()})}
  end

  test "capture and asynchronous passage journey keeps report selection separate and clears on privacy reset",
       c do
    for source <- c.fixture.sources do
      File.write!(
        Path.join(c.fixture.connection["directory"], source["external_id"]),
        source["latest_revision"]["body"]
      )
    end

    {:ok, view, _} = live(c.conn, "/company/corpus")
    open_scope(view, c.fixture)
    assert_push_event(view, "company-focus", %{id: "company-corpus-pipeline-title"})
    assert has_element?(view, "#company-corpus-pipeline")
    view |> element("button[phx-click=corpus_capture_start]") |> render_click()
    capture = socket(view).large.capture
    assert is_map(capture)
    assert {:ok, _} = HarnessForge.Evidence.Capture.run(capture["run_id"])

    ids =
      Repo.query!(
        "SELECT latest_revision_id FROM evidence_sources WHERE workspace_id=? AND connection_id=?",
        [Workspaces.current_id(), c.fixture.connection["id"]]
      ).rows
      |> List.flatten()

    for id <- ids, do: assert({:ok, _} = HarnessForge.Evidence.Passages.index_revision(id))
    view |> element("button[phx-click=corpus_capture_status]") |> render_click()

    view
    |> form("#company-corpus-question",
      retrieval: %{question: "Which release review and rollback controls apply?", mode: "fts"}
    )
    |> render_submit()

    render_async(view)
    run = socket(view).large.run
    assert run["state"] == "ready"
    assert run["evidence_bundle"]["version"] == "EvidenceBundle.v1"
    assert run["evidence_bundle"]["status"] == "ready"
    assert run["evidence_bundle"]["analysis_ready"]
    assert socket(view).large.page["evidence_bundle"] == run["evidence_bundle"]
    assert socket(view).large.page["rows"] != []
    [row | _] = socket(view).large.page["rows"]

    render_click(view, "corpus_run_passage", %{
      "corpus_generation" => socket(view).generation,
      "passage_id" => row["passage_id"]
    })

    assert socket(view).large.passage["parent_text"] != ""
    assert socket(view).large.passage["bundle_digest"] == run["evidence_bundle"]["bundle_digest"]
    assert byte_size(socket(view).large.passage["parent_text"]) <= 4096
    assert_push_event(view, "company-focus", %{id: "company-corpus-exact-passage"})
    view |> element("button[phx-click=corpus_run_passage_close]") |> render_click()
    assert socket(view).large.passage == nil
    assert_push_event(view, "company-focus", %{id: "company-corpus-results"})
    # Browsing the old inspector does not replace this selected evidence run.
    view |> form("#corpus-search-form", search: %{query: "latelexicalneedle"}) |> render_submit()
    assert socket(view).large.run == run

    # A durable update must invalidate opened content even before a cache-reset
    # broadcast reaches this view.
    Repo.query!(
      "UPDATE corpora SET authorization_generation=authorization_generation+1 WHERE id=?",
      [socket(view).large.corpus["id"]]
    )

    view |> element("button[phx-click=corpus_capture_status]") |> render_click()
    assert socket(view).large.run == nil
    assert socket(view).large.page == nil
    assert socket(view).large.passage == nil
    assert socket(view).large.stage == nil
    assert socket(view).large.claim == nil
    assert socket(view).large.question == ""
    assert socket(view).large.mode == "fts"
    send(view.pid, :corpus_cache_reset)
    render(view)
    assert socket(view).large.run == nil
    assert socket(view).large.passage == nil
    assert socket(view).large.claim == nil
  end

  test "normal Portal mount, Company navigation and reload never enumerate full source DTOs", c do
    :erlang.trace_pattern({Evidence, :list_sources, 0}, true, [:local])
    :erlang.trace(:new, true, [:call, {:tracer, self()}])

    try do
      {:ok, view, html} = live(c.conn, "/")
      refute html =~ "UNOPENED_BODY_CANARY"
      assert length(socket(view).sources) == 25
      assert socket(view).source_total == 42
      assert Enum.all?(socket(view).sources, &(not Map.has_key?(&1["latest_revision"], "body")))
      view |> element("button[phx-click=tab][phx-value-tab=company]") |> render_click()
      assert has_element?(view, "#company-corpus-review")
      send(view.pid, {:company_changed, "read-only test refresh"})
      refute render(view) =~ "UNOPENED_BODY_CANARY"
      refute_receive {:trace, _, :call, {Evidence, :list_sources, []}}, 50
    after
      :erlang.trace(:new, false, [:call])
      :erlang.trace(:all, false, [:call])
      :erlang.trace_pattern({Evidence, :list_sources, 0}, false, [:local])
    end
  end

  @tag extra_source_count: 22
  test "direct evidence entry pages all 26 captured sources and returns to the first page", c do
    sources = Enum.sort_by(c.fixture.sources ++ c.extras, & &1["id"])
    assert length(sources) == 26
    {first_page, [last]} = Enum.split(sources, 25)
    first_ids = Enum.map(first_page, & &1["id"])

    {:ok, view, _} = live(c.conn, "/?view=evidence")
    assert Enum.map(socket(view).sources, & &1["id"]) == first_ids

    view |> element("#evidence-source-pages button[phx-click=source_page_next]") |> render_click()
    assert Enum.map(socket(view).sources, & &1["id"]) == [last["id"]]
    assert has_element?(view, "#source-#{last["id"]} h3", last["title"])
    assert has_element?(view, "#evidence-source-pages", "Page 2 ·")

    view
    |> element("#evidence-source-pages button[phx-click=source_page_previous]")
    |> render_click()

    assert Enum.map(socket(view).sources, & &1["id"]) == first_ids
    assert has_element?(view, "#evidence-source-pages", "Page 1 ·")
  end

  test "normal source search opens only an exact bounded late-match window and refuses its stale pin",
       c do
    {:ok, view, _} = live(c.conn, "/")
    view |> element("#nav-evidence") |> render_click()
    view |> form("#search-form", query: "latelexicalneedle") |> render_submit()
    [source | _] = socket(view).sources
    refute render(view) =~ "UNOPENED_BODY_CANARY"
    view |> element("#source-open-" <> source["id"]) |> render_click()
    passage = socket(view).source_passage
    assert passage["text"] =~ "latelexicalneedle"
    assert passage["start_byte"] > 4096
    assert byte_size(passage["text"]) <= 4096
    assert String.valid?(passage["text"])
    view |> element("#source-passage-first") |> render_click()
    first = socket(view).source_passage
    assert first["start_byte"] == 0
    assert first["text"] =~ "UNOPENED_BODY_CANARY_"
    assert byte_size(first["text"]) <= 4096
    refute has_element?(view, "#source-passage-first")
    original = Enum.find(c.extras, &(&1["id"] == source["id"]))

    {:ok, _} =
      Evidence.import_markdown(c.fixture.connection["id"], %{
        "external_id" => original["external_id"],
        "title" => original["title"],
        "body" => "A changed captured revision."
      })

    view |> element("#source-open-" <> source["id"]) |> render_click()
    assert socket(view).source_passage == nil
    assert has_element?(view, "#error", "preview was cleared")
  end

  test "dedicated inspector explicitly selects assigned goal, pages, and serves no body before open",
       c do
    before = counts()
    {:ok, view, html} = live(c.conn, "/company/corpus")
    assert has_element?(view, "#corpus-scope-form")
    refute html =~ "UNOPENED_BODY_CANARY"
    open_scope(view, c.fixture)
    assert has_element?(view, "#corpus-scope-summary", c.fixture.project["payload"]["name"])
    assert has_element?(view, "#corpus-scope-summary", c.fixture.goal["title"])
    assert socket(view).state.selection["goal_content_hash"] == Goals.content_hash(c.fixture.goal)
    view |> form("#corpus-search-form", search: %{query: ""}) |> render_submit()
    first_ids = Enum.map(socket(view).state.page["rows"], & &1["id"])
    assert length(first_ids) == 25
    view |> element("#corpus-page-next") |> render_click()
    second_ids = Enum.map(socket(view).state.page["rows"], & &1["id"])
    assert length(second_ids) == 17
    assert MapSet.disjoint?(MapSet.new(first_ids), MapSet.new(second_ids))
    assert socket(view).state.previous?
    refute render(view) =~ "UNOPENED_BODY_CANARY"
    assert counts() == before
  end

  test "a valid punctuation-heavy goal opens a browse page without an implicit invalid query",
       c do
    {:ok, goal} =
      Goals.add_goal(%{
        "title" => "release/rollback/incident/exception/approval/review/owner/testing/monitoring",
        "owner" => "Synthetic owner",
        "acceptance" => "Inspect captured context before making a decision."
      })

    {:ok, profile} = Company.get_profile()

    {:ok, _} =
      Company.save_profile(
        Map.merge(profile["payload"], %{
          "goal_ids" => [goal["id"]],
          "expected_content_hash" => profile["content_hash"]
        })
      )

    before = counts()
    {:ok, view, _} = live(c.conn, "/company/corpus")
    open_scope(view, %{c.fixture | goal: goal})
    assert socket(view).state.query == ""
    assert socket(view).state.scope["goal"]["title"] == goal["title"]
    assert length(socket(view).state.page["rows"]) == 25
    refute has_element?(view, "#corpus-error")
    assert counts() == before
  end

  test "scope generation refuses late body events, reset clears an opened passage, and failed privacy stays fenced",
       c do
    {:ok, view, _} = live(c.conn, "/company/corpus")
    open_scope(view, c.fixture)
    view |> form("#corpus-search-form", search: %{query: "latelexicalneedle"}) |> render_submit()
    [source | _] = socket(view).state.page["rows"]
    generation = socket(view).generation

    params = %{
      "corpus_generation" => generation,
      "source_id" => source["id"],
      "revision_id" => source["latest_revision"]["id"],
      "body_hash" => source["latest_revision"]["body_hash"],
      "start_byte" => "0"
    }

    render_click(view, "corpus_passage_open", params)
    assert socket(view).state.passage != nil
    send(view.pid, :company_cache_reset)
    render(view)
    assert socket(view).state.passage == nil
    assert socket(view).state.recommendation == nil
    assert socket(view).generation != generation
    render_click(view, "corpus_passage_open", params)
    assert socket(view).state.passage == nil
    assert has_element?(view, "#corpus-error")

    Repo.query!(
      "INSERT INTO privacy_operations (id, workspace_id, kind, target_id, state, plan, inserted_at, updated_at) VALUES (?, ?, 'source', ?, 'failed', '{}', ?, ?)",
      [
        Ecto.UUID.generate(),
        Workspaces.current_id(),
        source["id"],
        DateTime.utc_now(),
        DateTime.utc_now()
      ]
    )

    {:ok, portal, html} = live(c.conn, "/")
    refute html =~ "UNOPENED_BODY_CANARY"
    assert socket(portal).sources == []
    assert has_element?(portal, "#data-unavailable", "privacy")
    assert Models.list_requests("never-dispatched") == {:ok, []}
  end

  test "off-page profile/project assignments survive unrelated catalog saves and support explicit removal",
       c do
    source = Enum.max_by(c.extras, & &1["id"])
    profile = c.fixture.profile

    {:ok, _} =
      Company.save_profile(%{
        "name" => profile["payload"]["name"],
        "source_ids" => [source["id"]],
        "goal_ids" => [c.fixture.goal["id"]],
        "expected_content_hash" => profile["content_hash"]
      })

    project = c.fixture.project

    {:ok, _} =
      Company.update_project(
        project["id"],
        Map.merge(project["payload"], %{
          "source_ids" => [source["id"]],
          "expected_content_hash" => project["content_hash"]
        })
      )

    {:ok, view, _} = live(c.conn, "/")
    refute source["id"] in Enum.map(socket(view).sources, & &1["id"])
    view |> element("button[phx-click=tab][phx-value-tab=company]") |> render_click()

    view
    |> form("#company-profile-form", profile: %{name: "Updated synthetic name"})
    |> render_change()

    view |> form("#company-profile-form") |> render_submit()
    assert {:ok, saved} = Company.get_profile()
    assert saved["payload"]["source_ids"] == [source["id"]]
    assert saved["payload"]["name"] == "Updated synthetic name"

    view |> element("#company-project-edit-" <> project["id"]) |> render_click()

    view
    |> form("#company-project-form", project: %{name: "Renamed scoped project"})
    |> render_change()

    view |> form("#company-project-form") |> render_submit()
    assert {:ok, projects} = Company.list_projects()
    saved_project = Enum.find(projects, &(&1["id"] == project["id"]))
    assert saved_project["payload"]["source_ids"] == [source["id"]]
    assert saved_project["payload"]["name"] == "Renamed scoped project"
    view |> element("#company-project-edit-" <> project["id"]) |> render_click()
    view |> form("#company-project-form", project: %{source_ids: []}) |> render_change()
    view |> form("#company-project-form") |> render_submit()
    assert {:ok, projects} = Company.list_projects()
    assert Enum.find(projects, &(&1["id"] == project["id"]))["payload"]["source_ids"] == []
    assert {:ok, saved_profile} = Company.get_profile()
    assert saved_profile["payload"]["source_ids"] == [source["id"]]
  end

  test "existing findings continue to exact current guidance review without admitting inspected evidence or dispatching again",
       c do
    previous_plug = Application.get_env(:harness_forge, :model_test_plug)
    Application.put_env(:harness_forge, :model_test_plug, {Req.Test, __MODULE__})

    on_exit(fn ->
      if previous_plug,
        do: Application.put_env(:harness_forge, :model_test_plug, previous_plug),
        else: Application.delete_env(:harness_forge, :model_test_plug)
    end)

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/api/tags" -> Req.Test.json(conn, %{"models" => [%{"name" => "synthetic:fixture"}]})
        "/api/generate" -> Req.Test.json(conn, CompanyAnalysisFixture.response(c.fixture.report))
      end
    end)

    {:ok, _} = Models.configure(%{"provider" => "ollama", "model" => "synthetic:fixture"})
    {:ok, %{"claim" => original}} = HarnessForge.Company.Analysis.analyze(c.fixture.input)
    {:ok, %{"claim" => other}} = HarnessForge.Company.Analysis.analyze(c.fixture.input)
    before = counts()
    {:ok, view, _} = live(c.conn, "/company/corpus")
    open_scope(view, c.fixture)
    view |> element("#corpus-recommendation-open-" <> original["id"]) |> render_click()

    assert has_element?(
             view,
             "#corpus-original-report",
             "General policy and emergency exception differ"
           )

    assert has_element?(view, "#corpus-original-report", "4")
    result = view |> element("#corpus-continue-review") |> render_click()
    assert {:ok, %Plug.Conn{} = destination} = follow_redirect(result, c.conn)
    assert {:ok, portal, _} = live(destination)
    assert has_element?(portal, "#company-analysis-original")
    assert has_element?(portal, "#company-analysis-review", original["basis"]["guidance"]["rule"])
    assert {:ok, ^original} = Evidence.get_claim(original["id"])
    assert counts() == before

    portal |> element("#company-analysis-evidence") |> render_click()
    assert has_element?(portal, "#evidence-panel")
    portal |> form("#search-form", query: "latelexicalneedle") |> render_submit()

    refute Enum.any?(
             socket(portal).sources,
             &(&1["id"] in Enum.map(c.fixture.sources, fn s -> s["id"] end))
           )

    assert length(socket(portal).sources) == 25
    active = socket(portal).evidence_review
    assert active["id"] == original["id"]
    assert active["revision_hash"] == original["revision_hash"]
    assert length(active["sources"]) == 4
    assert Enum.all?(active["sources"], &(not Map.has_key?(&1["latest_revision"], "body")))
    assert has_element?(portal, "#analysis-origin-#{original["id"]}", "Current source name")
    refute has_element?(portal, "#analysis-origin-#{other["id"]}", "Current source name")
    assert counts() == before

    assert {:ok, _} = Evidence.revoke_source(hd(c.fixture.sources)["id"])
    send(portal.pid, {:company_changed, "Synthetic revoked capture refresh"})
    render(portal)
    assert socket(portal).evidence_review == nil
    refute has_element?(portal, "#analysis-origin-#{original["id"]}", "Current source name")
  end

  @tag :retrieval_replacement
  test "obsolete async exits cannot overwrite current recovery or release its busy state", c do
    assigns = %{
      __changed__: %{},
      generation: "current-generation",
      workspace_id: Workspaces.current_id(),
      operator_auth: OperatorSession.new_auth(),
      large: %{busy: true, error: "Current question recovery", run: nil, claim: nil}
    }

    socket = %Phoenix.LiveView.Socket{assigns: assigns}

    for kind <- [:corpus_retrieval, :corpus_synthesis],
        outcome <- [{:exit, :killed}, {:ok, {:error, :graph_unavailable}}] do
      assert {:noreply, ^socket} =
               HarnessForgeWeb.CorpusReviewLive.handle_async(
                 {kind, "obsolete-generation"},
                 outcome,
                 socket
               )
    end

    for changed <- [
          %{assigns | operator_auth: nil},
          %{assigns | workspace_id: c.fixture.project["id"]}
        ] do
      current = %{socket | assigns: changed}

      assert {:noreply, ^current} =
               HarnessForgeWeb.CorpusReviewLive.handle_async(
                 {:corpus_retrieval, assigns.generation},
                 {:exit, :killed},
                 current
               )
    end
  end

  @tag :retrieval_replacement
  test "a failed replacement question clears the previous evidence and synthesis handles", c do
    {fixture, _claim} = passage_claim(c.fixture)
    {:ok, view, _} = live(c.conn, "/company/corpus")
    open_scope(view, fixture)

    view
    |> form("#company-corpus-question",
      retrieval: %{
        question: "Which emergency release review and rollback controls apply?",
        mode: "fts"
      }
    )
    |> render_submit()

    render_async(view)
    assert socket(view).large.run["state"] == "ready"
    [row | _] = socket(view).large.page["rows"]

    render_click(view, "corpus_run_passage", %{
      "corpus_generation" => socket(view).generation,
      "passage_id" => row["passage_id"]
    })

    assert socket(view).large.passage != nil
    before = counts()

    view
    |> form("#company-corpus-question",
      retrieval: %{
        question: "Which emergency release review and rollback controls apply?",
        mode: "graphiti_hybrid"
      }
    )
    |> render_submit()

    render_async(view)
    assert socket(view).large.error != nil

    assert socket(view).large.question ==
             "Which emergency release review and rollback controls apply?"

    assert socket(view).large.mode == "graphiti_hybrid"
    assert has_element?(view, "#company-corpus-error", "Graph search is unavailable")
    for key <- [:run, :page, :passage, :stage, :claim], do: assert(socket(view).large[key] == nil)
    refute has_element?(view, "#company-corpus-run-title")
    refute has_element?(view, "button[phx-click=corpus_stage_prepare]")
    assert counts() == before

    # Ordinary inspector rerenders retain only this same-socket draft.
    view |> form("#corpus-search-form", search: %{query: "rollback"}) |> render_submit()
    assert socket(view).large.mode == "graphiti_hybrid"

    view
    |> form("#company-corpus-question", retrieval: %{question: "Café 東京 rollback?", mode: "fts"})
    |> render_change()

    assert socket(view).large.question == "Café 東京 rollback?"
    assert socket(view).large.run == nil
    assert counts() == before
    view |> form("#corpus-scope-form") |> render_submit()
    assert socket(view).large.question == "Café 東京 rollback?"
    view |> form("#company-corpus-question") |> render_submit()
    render_async(view)
    assert socket(view).large.run["mode"] == "fts"

    # Reject oversized grapheme and byte payloads without storing them or retaining authority.
    for question <- [
          String.duplicate("a", 257),
          String.duplicate("a" <> String.duplicate("\u0301", 5), 256)
        ] do
      render_click(view, "corpus_retrieve", %{
        "corpus_generation" => socket(view).generation,
        "retrieval" => %{"question" => question, "mode" => "fts"}
      })

      assert socket(view).large.question == "Café 東京 rollback?"

      for key <- [:run, :page, :passage, :stage, :claim],
          do: assert(socket(view).large[key] == nil)

      assert has_element?(view, "#company-corpus-error", "at most 256 characters")
    end

    view |> form("#corpus-scope-form", scope: %{project_id: ""}) |> render_change()
    assert socket(view).large.question == ""
    assert socket(view).large.mode == "fts"
    assert socket(view).state.selection["goal_id"] == ""
    send(view.pid, :corpus_cache_reset)
    render(view)
    assert socket(view).large.question == ""
    assert socket(view).large.claim == nil
  end

  @tag :draft_authority_invalidation
  test "authorization changes clear a draft before any UI retrieval and explicit refresh cannot restore it",
       c do
    {:ok, view, _} = live(c.conn, "/company/corpus")
    open_scope(view, c.fixture)
    ready_capture(view, c.fixture)
    before = counts()

    view
    |> form("#company-corpus-question",
      retrieval: %{question: "Café 東京 release rollback?", mode: "graphiti_hybrid"}
    )
    |> render_change()

    assert socket(view).large.question == "Café 東京 release rollback?"
    assert socket(view).large.mode == "graphiti_hybrid"
    assert socket(view).large.run == nil
    assert socket(view).large.submitted_question == nil

    advance_corpus_authorization(view)
    view |> element("button[phx-click=corpus_capture_status]") |> render_click()
    assert_draft_authority_cleared(view)
    view |> element("#corpus-refresh") |> render_click()
    assert_draft_authority_cleared(view)
    assert counts() == before
  end

  @tag :draft_authority_invalidation
  test "authorization changes clear a retained failed-graph draft on an ordinary event before PubSub",
       c do
    {:ok, view, _} = live(c.conn, "/company/corpus")
    open_scope(view, c.fixture)
    ready_capture(view, c.fixture)
    question = "Which release review and rollback controls apply?"

    view
    |> form("#company-corpus-question", retrieval: %{question: question, mode: "fts"})
    |> render_submit()

    render_async(view)
    assert socket(view).large.run["state"] == "ready"
    [row | _] = socket(view).large.page["rows"]

    render_click(view, "corpus_run_passage", %{
      "corpus_generation" => socket(view).generation,
      "passage_id" => row["passage_id"]
    })

    assert socket(view).large.passage != nil
    before = counts()

    view
    |> form("#company-corpus-question", retrieval: %{question: question, mode: "graphiti_hybrid"})
    |> render_submit()

    render_async(view)
    assert has_element?(view, "#company-corpus-error", "Graph search is unavailable")
    assert socket(view).large.question == question
    assert socket(view).large.mode == "graphiti_hybrid"
    assert socket(view).large.submitted_question == question
    for key <- [:run, :page, :passage, :stage, :claim], do: assert(socket(view).large[key] == nil)

    advance_corpus_authorization(view)
    view |> form("#corpus-search-form", search: %{query: "rollback"}) |> render_submit()
    assert_draft_authority_cleared(view)
    view |> element("#corpus-refresh") |> render_click()
    assert_draft_authority_cleared(view)
    assert counts() == before
  end

  @tag :v2_handoff
  test "manifest-backed findings reopen original review and exact current source metadata", c do
    {fixture, claim} = passage_claim(c.fixture)
    refute Map.has_key?(claim["basis"]["context"], "sources")
    before = counts()
    {:ok, view, _} = live(c.conn, "/company/corpus")
    open_scope(view, fixture)
    view |> element("#corpus-recommendation-open-" <> claim["id"]) |> render_click()

    assert has_element?(
             view,
             "#corpus-original-report",
             "General policy and emergency exception differ"
           )

    result = view |> element("#corpus-continue-review") |> render_click()
    assert {:ok, %Plug.Conn{} = destination} = follow_redirect(result, c.conn)
    assert {:ok, portal, _} = live(destination)
    assert has_element?(portal, "#company-analysis-review", claim["basis"]["guidance"]["rule"])
    portal |> element("#company-analysis-evidence") |> render_click()
    active = socket(portal).evidence_review
    assert active["id"] == claim["id"]
    assert length(active["sources"]) == 4
    assert Enum.all?(active["sources"], &(not Map.has_key?(&1["latest_revision"], "body")))
    assert has_element?(portal, "#analysis-origin-#{claim["id"]}", "Current source name")
    assert counts() == before

    caller = [
      authorize: fn -> true end,
      session_fingerprint: String.duplicate("a", 64),
      view_generation: String.duplicate("b", 32),
      reset_token: 0
    ]

    ref = %{"claim_id" => claim["id"], "revision_hash" => claim["revision_hash"]}

    assert {:error, _} =
             HarnessForge.Company.CorpusReview.recommendation_sources(
               Map.put(ref, "revision_hash", String.duplicate("0", 64)),
               caller
             )

    assert {:error, _} =
             HarnessForge.Company.CorpusReview.recommendation_sources(
               ref,
               Keyword.put(caller, :authorize, fn -> false end)
             )

    assert {:ok, _} = Evidence.revoke_source(fixture.uncited_source["id"])
    assert {:error, _} = HarnessForge.Company.CorpusReview.recommendation_sources(ref, caller)
    send(portal.pid, {:company_changed, "Synthetic manifest input revoked"})
    render(portal)
    assert socket(portal).evidence_review == nil
  end

  @tag :v2_handoff
  test "approved manifest-backed claim is selectable in a separate plan without manual source assignments",
       c do
    {fixture, original} = passage_claim(c.fixture)

    {:ok, claim} =
      HarnessForge.Company.Analysis.revise(
        original["id"],
        original["revision_hash"],
        Map.put(
          original["basis"]["guidance"],
          "review_resolution",
          "Apply the documented emergency exception only to its scope; preserve the general policy elsewhere."
        )
      )

    assert {:ok, _} =
             HarnessForge.Decisions.decide(claim["id"], CompanyAnalysisFixture.decision(claim))

    assert fixture.profile["payload"]["source_ids"] == []
    assert fixture.project["payload"]["source_ids"] == []
    {:ok, view, _} = live(c.conn, "/")
    view |> element("#nav-company") |> render_click()
    assert has_element?(view, "#company-guide-details", "1 eligible approved claims")

    view
    |> form("#company-plan-form", plan: %{project_id: fixture.project["id"]})
    |> render_change()

    assert has_element?(view, "#company-plan-claims", claim["revision_hash"])

    attrs =
      CompanyAnalysisFixture.plan_attrs(fixture, claim)
      |> Map.put("claim_refs", [claim["id"] <> ":" <> claim["revision_hash"]])
      |> Map.delete("milestones")

    view |> form("#company-plan-form", plan: attrs) |> render_submit()
    assert {:ok, [plan]} = Company.list_plans()
    assert plan["status"] == "proposed"
    assert plan["payload"]["claim_refs"] == [Map.take(claim, ~w(id revision_hash))]
    assert {:error, :plan_not_approved} = Company.build_inputs(plan["id"])
    assert {:ok, _} = Evidence.revoke_source(fixture.uncited_source["id"])
    send(view.pid, {:company_changed, "Synthetic uncited source revoked"})
    render(view)
    refute has_element?(view, "#company-plan-claims", claim["revision_hash"])
  end

  test "all corpus entry routes require the normal operator session", _c do
    unauthenticated = build_conn() |> Map.merge(%{host: "localhost", port: 4002})
    assert {:error, {:redirect, %{to: "/login"}}} = live(unauthenticated, "/company/corpus")
  end

  test "saved off-page cloud consent survives paging and unrelated save; explicit deselection removes only one source",
       c do
    selected = c.extras |> Enum.sort_by(& &1["id"], :desc) |> Enum.take(2) |> Enum.map(& &1["id"])

    {:ok, _} =
      Models.configure(%{
        "provider" => "anthropic",
        "endpoint" => "https://api.anthropic.com/v1",
        "model" => "synthetic-metadata-only",
        "credential_env" => "HARNESSFORGE_CORPUS_REVIEW_FIXTURE_ONLY",
        "input_microusd_per_million" => 1,
        "output_microusd_per_million" => 1,
        "cloud_consent" => %{
          "provider" => "anthropic",
          "endpoint" => "https://api.anthropic.com/v1",
          "source_ids" => selected,
          "data_categories" => ["source_body"]
        }
      })

    {:ok, view, _} = live(c.conn, "/")
    refute Enum.any?(socket(view).sources, &(&1["id"] in selected))
    view |> element("#nav-connections") |> render_click()

    for id <- selected,
        do:
          assert(has_element?(view, "input[name='model[source_ids][]'][value='#{id}'][checked]"))

    view |> element("#model-source-pages button[phx-click=source_page_next]") |> render_click()

    view
    |> element("#model-source-pages button[phx-click=source_page_previous]")
    |> render_click()

    attrs = %{
      model: "synthetic-renamed",
      credential_env: "HARNESSFORGE_CORPUS_REVIEW_FIXTURE_ONLY",
      input_price: "1",
      output_price: "1"
    }

    view |> form("#model-form", model: attrs) |> render_submit()
    assert Enum.sort(Models.status()["cloud_consent"]["source_ids"]) == Enum.sort(selected)

    view
    |> form("#model-form", model: Map.put(attrs, :source_ids, [List.last(selected)]))
    |> render_submit()

    assert Models.status()["cloud_consent"]["source_ids"] == [List.last(selected)]

    assert Repo.query!("SELECT count(*) FROM model_requests WHERE workspace_id = ?", [
             Workspaces.current_id()
           ]).rows == [[0]]
  end

  # Exercise the actual capture/retrieval/manifest/synthesis APIs, with an
  # explicitly scripted provider. This proves UI correspondence, not model quality.
  defp passage_claim(fixture) do
    previous = Application.get_env(:harness_forge, :model_test_plug)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:harness_forge, :model_test_plug, previous),
        else: Application.delete_env(:harness_forge, :model_test_plug)
    end)

    {:ok, profile} =
      Company.save_profile(
        Map.merge(fixture.profile["payload"], %{
          "source_ids" => [],
          "expected_content_hash" => fixture.profile["content_hash"]
        })
      )

    {:ok, project} =
      Company.update_project(
        fixture.project["id"],
        Map.merge(fixture.project["payload"], %{
          "source_ids" => [],
          "expected_content_hash" => fixture.project["content_hash"]
        })
      )

    fixture = %{fixture | profile: profile, project: project}

    for source <- fixture.sources do
      File.write!(
        Path.join(fixture.connection["directory"], source["external_id"]),
        source["latest_revision"]["body"]
      )
    end

    caller = [
      authorize: fn -> true end,
      session_fingerprint: String.duplicate("c", 64),
      view_generation: String.duplicate("d", 32),
      reset_token: 0
    ]

    {:ok, corpus} =
      HarnessForge.Evidence.Corpora.create(%{"name" => "Synthetic UI handoff"}, caller)

    {:ok, _} =
      Company.bind_corpus(
        project["id"],
        corpus["id"],
        profile["content_hash"],
        project["content_hash"],
        caller
      )

    {:ok, capture} =
      HarnessForge.Evidence.Capture.start_capture(
        corpus["id"],
        fixture.connection["id"],
        0,
        caller
      )

    {:ok, _} = HarnessForge.Evidence.Capture.run(capture["run_id"])
    {:ok, sources} = Evidence.list_sources()

    for s <- sources,
        do:
          assert(
            {:ok, _} = HarnessForge.Evidence.Passages.index_revision(s["latest_revision"]["id"])
          )

    {:ok, current} = HarnessForge.Evidence.Corpora.get(corpus["id"])

    {:ok, run} =
      HarnessForge.Company.Retrieval.retrieve(
        %{
          "corpus_id" => corpus["id"],
          "project_id" => project["id"],
          "goal_id" => fixture.goal["id"],
          "goal_hash" => Goals.content_hash(fixture.goal),
          "expected_generation" => current.semantic_generation,
          "question" => "Which emergency release review and rollback controls apply?",
          "mode" => "fts"
        },
        caller
      )

    assert run["state"] == "ready"
    by_id = Map.new(sources, &{&1["id"], &1})

    report =
      update_in(fixture.report, ["findings"], fn fs ->
        Enum.map(fs, fn f ->
          Map.update!(f, "citations", fn cs ->
            Enum.map(cs, fn c ->
              Map.put(c, "revision_id", by_id[c["source_id"]]["latest_revision"]["id"])
            end)
          end)
        end)
      end)

    {:ok, _} = Models.configure(%{"provider" => "ollama", "model" => "synthetic:fixture"})

    {:ok, review} =
      HarnessForge.Models.StageAuthority.prepare_synthesis(run["run_id"], run["digest"], caller)

    {:ok, _} =
      HarnessForge.Models.StageAuthority.grant_consent(
        review["stage_id"],
        review["manifest_id"],
        review["manifest_digest"],
        caller
      )

    Application.put_env(:harness_forge, :model_test_plug, fn conn ->
      assert conn.request_path == "/api/generate"
      Req.Test.json(conn, CompanyAnalysisFixture.response(report))
    end)

    {:ok, %{"claim" => claim}} =
      HarnessForge.Company.Analysis.analyze_retrieval(run["run_id"], run["digest"],
        caller: caller,
        stage_id: review["stage_id"]
      )

    {fixture, claim}
  end

  defp open_scope(view, fixture) do
    selection = %{
      connection_id: fixture.connection["id"],
      project_id: fixture.project["id"],
      goal_id: "",
      goal_content_hash: ""
    }

    view |> form("#corpus-scope-form", scope: selection) |> render_change()

    selection = Map.put(selection, :goal_id, fixture.goal["id"])

    view |> form("#corpus-scope-form", scope: selection) |> render_change()
    view |> form("#corpus-scope-form") |> render_submit()
  end

  defp ready_capture(view, fixture) do
    for source <- fixture.sources do
      File.write!(
        Path.join(fixture.connection["directory"], source["external_id"]),
        source["latest_revision"]["body"]
      )
    end

    view |> element("button[phx-click=corpus_capture_start]") |> render_click()
    capture = socket(view).large.capture
    assert {:ok, _} = HarnessForge.Evidence.Capture.run(capture["run_id"])

    ids =
      Repo.query!(
        "SELECT latest_revision_id FROM evidence_sources WHERE workspace_id=? AND connection_id=?",
        [Workspaces.current_id(), fixture.connection["id"]]
      ).rows
      |> List.flatten()

    for id <- ids, do: assert({:ok, _} = HarnessForge.Evidence.Passages.index_revision(id))
    view |> element("button[phx-click=corpus_capture_status]") |> render_click()
    assert socket(view).large.capture["capture"]["complete"]
  end

  defp advance_corpus_authorization(view) do
    Repo.query!(
      "UPDATE corpora SET authorization_generation=authorization_generation+1 WHERE id=?",
      [socket(view).large.corpus["id"]]
    )
  end

  defp assert_draft_authority_cleared(view) do
    assert socket(view).large.question == ""
    assert socket(view).large.mode == "fts"
    assert socket(view).large.submitted_question == nil
    for key <- [:run, :page, :passage, :stage, :claim], do: assert(socket(view).large[key] == nil)
  end

  defp counts do
    for table <-
          ~w(evidence_citations evidence_claims claim_decisions company_plans company_plan_decisions model_requests),
        into: %{} do
      %{rows: [[count]]} =
        Repo.query!("SELECT count(*) FROM #{table} WHERE workspace_id = ?", [
          Workspaces.current_id()
        ])

      {table, count}
    end
  end

  defp socket(view), do: :sys.get_state(view.pid).socket.assigns
end
