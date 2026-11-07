defmodule HarnessForgeWeb.CompanyReadinessTest do
  use HarnessForgeWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias HarnessForge.{
    Company,
    CompanyAnalysisFixture,
    Decisions,
    Evidence,
    Models,
    Repo,
    Workspaces
  }

  alias HarnessForge.Evidence.{Capture, Corpora, Passages}
  alias HarnessForgeWeb.Plugs.OperatorSession

  setup %{conn: conn} do
    previous =
      {Application.fetch_env!(:harness_forge, :workspace_root), Workspaces.current_id(),
       Application.get_env(:harness_forge, :model_test_plug)}

    id = Ecto.UUID.generate()
    root = Path.join(File.cwd!(), "tmp/company-readiness-#{id}")
    Enum.each(~w(artifacts runs tmp), &File.mkdir_p!(Path.join(root, &1)))
    Application.put_env(:harness_forge, :workspace_root, root)
    Application.put_env(:harness_forge, :workspace_id, id)
    fixture = CompanyAnalysisFixture.create!(root)

    on_exit(fn ->
      {old_root, old_id, old_plug} = previous
      Application.put_env(:harness_forge, :workspace_root, old_root)
      Application.put_env(:harness_forge, :workspace_id, old_id)

      if old_plug,
        do: Application.put_env(:harness_forge, :model_test_plug, old_plug),
        else: Application.delete_env(:harness_forge, :model_test_plug)

      File.rm_rf!(root)
    end)

    conn =
      conn
      |> Map.merge(%{host: "localhost", port: 4002})
      |> init_test_session(%{"operator_auth" => OperatorSession.new_auth()})

    {:ok, conn: conn, fixture: fixture}
  end

  test "company and selected-corpus screens expose six separate unknown states before observations",
       c do
    {:ok, company, _} = live(c.conn, "/?setup=company")
    assert has_element?(company, "#company-readiness")

    for name <- ~w(capture understanding review candidate evaluation release) do
      assert has_element?(company, "#company-readiness-#{name}[data-status=unknown]")
    end

    {:ok, corpus, _} = live(c.conn, "/company/corpus")
    open_scope(corpus, c.fixture)
    assert has_element?(corpus, "#corpus-readiness")

    for name <- ~w(capture understanding review candidate evaluation release) do
      assert has_element?(corpus, "#corpus-readiness-#{name}[data-status=unknown]")
    end

    assert socket(corpus).large.run == nil
    assert socket(corpus).large.analysis_observation == nil
  end

  test "real scoped capture stays complete after scripted synthesis failure and remount forgets session outcome",
       c do
    # This exercises local producer/WEB mechanics with a deliberately invalid
    # scripted response; it makes no model-quality or real-provider claim.
    Application.put_env(:harness_forge, :model_test_plug, fn conn ->
      case conn.request_path do
        "/api/tags" ->
          Req.Test.json(conn, %{"models" => [%{"name" => "synthetic:fixture"}]})

        "/api/generate" ->
          Req.Test.json(conn, %{"response" => "invalid synthetic report", "done" => true})
      end
    end)

    {:ok, _} = Models.configure(%{"provider" => "ollama", "model" => "synthetic:fixture"})
    {:ok, view, _} = live(c.conn, "/company/corpus")
    open_scope(view, c.fixture)
    ready_capture(view, c.fixture)

    assert has_element?(
             view,
             "#corpus-readiness-capture[data-status=complete_for_selected_scope]"
           ),
           inspect(socket(view).readiness["facts"]["capture"])

    view
    |> form("#company-corpus-question",
      retrieval: %{question: "Which release review and rollback controls apply?", mode: "fts"}
    )
    |> render_submit()

    render_async(view)
    assert socket(view).large.run["state"] == "ready"
    assert has_element?(view, "#corpus-readiness-understanding[data-status=unknown]")
    view |> element("button[phx-click=corpus_stage_prepare]") |> render_click()
    view |> element("button[phx-click=corpus_synthesize]") |> render_click()
    render_async(view, 1_000)
    assert socket(view).large.analysis_observation["status"] == "failed"
    assert has_element?(view, "#corpus-readiness-understanding[data-status=blocked]")

    assert has_element?(
             view,
             "#corpus-readiness-capture[data-status=complete_for_selected_scope]"
           )

    assert has_element?(view, "#corpus-readiness-release[data-status=unknown]")
    assert socket(view).large.claim == nil

    {:ok, remounted, _} = live(c.conn, "/company/corpus")
    open_scope(remounted, c.fixture)
    assert socket(remounted).large.analysis_observation == nil
    assert has_element?(remounted, "#corpus-readiness-understanding[data-status=unknown]")

    previous = :sys.get_state(view.pid).socket
    observation = previous.assigns.large.analysis_observation

    view
    |> form("#company-corpus-question",
      retrieval: %{question: "Which controls changed?", mode: "fts"}
    )
    |> render_change()

    changed = :sys.get_state(view.pid).socket

    for key <- [:run, :page, :passage, :stage, :claim, :analysis_observation, :submitted_question],
        do: assert(changed.assigns.large[key] == nil)

    assert {:noreply, late} =
             HarnessForgeWeb.CorpusReviewLive.handle_async(
               {:corpus_synthesis, previous.assigns.generation, observation["analysis_id"]},
               {:ok, {:ok, %{"status" => "abstained"}}},
               changed
             )

    assert late.assigns.large.analysis_observation == nil
    assert late.assigns.large.run == nil

    # Disabled controls are also fenced server-side: forged busy edits cannot
    # alter the question which the in-flight retrieval/synthesis belongs to.
    busy = %{previous | assigns: put_in(previous.assigns, [:large, :busy], true)}

    for event <- ~w(corpus_question_change corpus_retrieve) do
      assert {:noreply, rejected} =
               HarnessForgeWeb.CorpusReviewLive.handle_event(
                 event,
                 %{
                   "corpus_generation" => busy.assigns.generation,
                   "retrieval" => %{
                     "question" => "Forged replacement",
                     "mode" => "graphiti_hybrid"
                   }
                 },
                 busy
               )

      assert rejected.assigns.large.busy
      assert rejected.assigns.large.question == previous.assigns.large.question
      assert rejected.assigns.large.run == previous.assigns.large.run
      assert rejected.assigns.large.analysis_observation == observation
    end

    Repo.query!(
      "UPDATE corpora SET authorization_generation=authorization_generation+1 WHERE id=?",
      [socket(view).large.corpus["id"]]
    )

    # A callback may arrive before the cache-reset broadcast. Exercise that
    # callback directly with the real selected run, after authority changed.
    assert {:noreply, ignored} =
             HarnessForgeWeb.CorpusReviewLive.handle_async(
               {:corpus_synthesis, previous.assigns.generation, observation["analysis_id"]},
               {:ok, {:ok, %{"status" => "abstained"}}},
               previous
             )

    assert ignored.assigns.large.analysis_observation == nil
    assert ignored.assigns.large.claim == nil
    view |> element("button[phx-click=corpus_capture_status]") |> render_click()
    assert socket(view).large.run == nil
    assert socket(view).large.analysis_observation == nil

    refute has_element?(
             view,
             "#corpus-readiness-capture[data-status=complete_for_selected_scope]"
           )

    send(view.pid, :corpus_cache_reset)
    render(view)
    assert socket(view).large.analysis_observation == nil
    assert has_element?(view, "#corpus-readiness-understanding[data-status=unknown]")
  end

  test "a real separately approved plan builds a visible candidate without release qualification",
       c do
    source = hd(c.fixture.sources)

    {:ok, citation} =
      Evidence.citation(
        source["latest_revision"]["id"],
        0,
        byte_size(source["latest_revision"]["body"])
      )

    {:ok, claim} =
      Evidence.create_claim(%{
        "text" => "Record review before a production change.",
        "citations" => [citation]
      })

    {:ok, claim} = Decisions.decide(claim["id"], CompanyAnalysisFixture.decision(claim))
    {:ok, plan} = Company.create_plan(CompanyAnalysisFixture.plan_attrs(c.fixture, claim))
    {:ok, before_approval, _} = live(c.conn, "/?setup=company")
    before_approval |> element("#company-plan-select-#{plan["id"]}") |> render_click()
    assert has_element?(before_approval, "#company-readiness-review[data-status=needs_input]")

    refute has_element?(
             before_approval,
             "#company-readiness-release[data-status=complete_for_selected_scope]"
           )

    {:ok, _} = Company.decide_plan(plan["id"], CompanyAnalysisFixture.decision(plan))
    {:ok, view, _} = live(c.conn, "/?setup=company")
    view |> element("#company-plan-select-#{plan["id"]}") |> render_click()
    view |> form("#company-plan-build-form") |> render_submit()

    assert has_element?(
             view,
             "#company-readiness-review[data-status=complete_for_selected_scope]"
           )

    assert has_element?(
             view,
             "#company-readiness-candidate[data-status=complete_for_selected_scope]"
           )

    assert has_element?(view, "#company-readiness-evaluation[data-status=unknown]")

    assert has_element?(
             view,
             "#company-readiness-release[data-status=blocked]",
             "Required qualification is missing"
           )

    refute has_element?(
             view,
             "#company-readiness-release[data-status=complete_for_selected_scope]"
           )

    assert has_element?(view, "#company-readiness-details code", plan["revision_hash"])
    assert Repo.query!("SELECT count(*) FROM release_channels", []).rows == [[0]]

    # Simulate a backing authority change before its normal cache broadcast.
    # A valid subsequent WEB event must recheck rather than refresh the time on
    # an old eligible observation.
    Repo.query!("UPDATE evidence_sources SET status='revoked' WHERE id=?", [source["id"]])
    view |> element("#company-toggle-build") |> render_click()
    assert has_element?(view, "#company-readiness-review[data-status=unknown]")
    assert has_element?(view, "#company-readiness-candidate[data-status=unknown]")

    refute has_element?(
             view,
             "#company-readiness-release[data-status=complete_for_selected_scope]"
           )
  end

  @tag :superseded_readiness
  test "an approved superseded plan cannot retain current exact-review completion", c do
    source = hd(c.fixture.sources)

    {:ok, citation} =
      Evidence.citation(
        source["latest_revision"]["id"],
        0,
        byte_size(source["latest_revision"]["body"])
      )

    {:ok, claim} =
      Evidence.create_claim(%{
        "text" => "Check review records before release.",
        "citations" => [citation]
      })

    {:ok, claim} = Decisions.decide(claim["id"], CompanyAnalysisFixture.decision(claim))
    attrs = CompanyAnalysisFixture.plan_attrs(c.fixture, claim)
    {:ok, plan} = Company.create_plan(attrs)
    {:ok, _} = Company.decide_plan(plan["id"], CompanyAnalysisFixture.decision(plan))

    {:ok, _} =
      Company.create_plan(
        Map.merge(attrs, %{"package_version" => "1.0.1", "supersedes_id" => plan["id"]})
      )

    assert {:ok, %{"superseded" => true, "status" => "approved"} = old} =
             Company.get_plan(plan["id"])

    projected =
      HarnessForge.Company.Readiness.for_plan(c.fixture.project, old, nil, nil, :eligible)

    assert projected["facts"]["review"]["references"] == []
    {:ok, view, _} = live(c.conn, "/?setup=company")
    view |> element("#company-plan-select-#{plan["id"]}") |> render_click()

    refute has_element?(
             view,
             "#company-readiness-review[data-status=complete_for_selected_scope]"
           )

    assert has_element?(view, "#company-readiness-review[data-status=stale]")

    refute has_element?(
             view,
             "#company-readiness-release[data-status=complete_for_selected_scope]"
           )
  end

  test "WEB saves and reopens actual required coverage with a named optional omission", c do
    optional_dir =
      Path.join(c.fixture.connection["directory"], "../optional-web") |> Path.expand()

    File.mkdir_p!(optional_dir)

    {:ok, optional} =
      Evidence.connect(%{
        "name" => "Optional <history>",
        "provider" => "local",
        "directory" => optional_dir
      })

    File.ln_s!(optional_dir, Path.join(optional_dir, "unsafe-link"))
    {:ok, view, _} = live(c.conn, "/company/corpus")
    open_scope(view, c.fixture)
    ready_capture(view, c.fixture)
    corpus = socket(view).large.corpus

    {:ok, failed} =
      Capture.start_capture(
        corpus["id"],
        optional["id"],
        corpus["semantic_generation"],
        requirements_caller()
      )

    assert {:ok, outcome} = Capture.run(failed["run_id"])
    refute outcome["capture"]["complete"]
    view |> element("#corpus-requirements-begin") |> render_click()

    view
    |> form("#corpus-requirements-form",
      requirements: %{optional_connection_id: optional["id"], capture_run_id: ""}
    )
    |> render_change()

    view
    |> form("#corpus-requirements-form",
      requirements: %{optional_connection_id: optional["id"], capture_run_id: failed["run_id"]}
    )
    |> render_change()

    view |> form("#corpus-requirements-form") |> render_submit()
    url = assert_patch(view)
    assert url =~ "declaration_digest="
    assert has_element?(view, "#corpus-requirements-saved", "Optional <history>")

    assert has_element?(
             view,
             "#corpus-readiness-capture[data-status=complete_for_selected_scope]"
           )

    assert has_element?(view, "#corpus-readiness [data-optional-omission]", "Optional <history>")
    assert length(socket(view).readiness["omissions"]) == 1
    refute has_element?(view, "history")
    {:ok, reopened, _} = live(c.conn, url)
    assert socket(reopened).large.declaration["id"] == socket(view).large.declaration["id"]

    assert has_element?(
             reopened,
             "#corpus-readiness [data-optional-omission]",
             "Optional <history>"
           )

    assert socket(reopened).large.run == nil
    assert socket(reopened).large.analysis_observation == nil

    saved = socket(reopened).large.declaration
    reference = socket(reopened).large.declaration_ref

    for mode <- ~w(fts graphiti_hybrid) do
      reopened
      |> form("#company-corpus-question", retrieval: %{question: "Review rollback?", mode: mode})
      |> render_change()

      assert socket(reopened).large.declaration == saved
      assert socket(reopened).large.declaration_ref == reference

      assert has_element?(
               reopened,
               "#corpus-readiness [data-optional-omission]",
               "Optional <history>"
             )
    end

    reopened |> form("#corpus-search-form", search: %{query: "rollback"}) |> render_submit()
    assert socket(reopened).large.declaration == saved

    reopened
    |> form("#company-corpus-question",
      retrieval: %{question: "Which release review and rollback controls apply?", mode: "fts"}
    )
    |> render_submit()

    render_async(reopened)
    assert socket(reopened).large.run["state"] == "ready"
    assert socket(reopened).large.declaration == saved
    assert socket(reopened).large.declaration_ref == reference

    assert has_element?(
             reopened,
             "#corpus-readiness [data-optional-omission]",
             "Optional <history>"
           )

    run = socket(reopened).large.run
    assert run["coverage"]["declaration"]["id"] == saved["id"]
    assert run["coverage"]["declaration"]["digest"] == saved["digest"]
    assert run["coverage"]["declaration"]["required_status"] == "complete"
    assert run["coverage"]["declaration"]["omissions"] != []
    assert :ok == HarnessForge.Company.Retrieval.validate_current(run["run_id"], run["digest"])

    # An exact receipt can change without changing corpus generations.
    Repo.query!("UPDATE capture_runs SET lock_version=lock_version+1 WHERE id=?", [
      failed["run_id"]
    ])

    assert {:error, :stale_receipt} =
             HarnessForge.Company.Retrieval.validate_current(run["run_id"], run["digest"])

    assert {:error, :stale_receipt} =
             HarnessForge.Company.Retrieval.resolve_for_analysis(
               run["run_id"],
               run["digest"],
               requirements_caller()
             )

    render_patch(
      reopened,
      String.replace(
        url,
        ~r/declaration_digest=[^&]+/,
        "declaration_digest=" <> String.duplicate("0", 64)
      )
    )

    assert socket(reopened).large.declaration == nil
    assert socket(reopened).large.declaration_ref != nil
    assert socket(reopened).readiness["omissions"] == []

    refute has_element?(
             reopened,
             "#corpus-readiness-capture[data-status=complete_for_selected_scope]"
           )

    assert has_element?(reopened, "#company-corpus-error", "Coverage context changed")
  end

  test "WEB retains server edit pins and rejects a concurrent saved declaration", c do
    {:ok, view, _} = live(c.conn, "/company/corpus")
    open_scope(view, c.fixture)
    ready_capture(view, c.fixture)
    view |> element("#corpus-requirements-begin") |> render_click()
    large = socket(view).large
    expected = large.requirements_context["expected"]

    {:ok, saved} =
      Corpora.declare_requirements(
        large.corpus["id"],
        expected,
        %{
          "project_id" => c.fixture.project["id"],
          "goal_id" => c.fixture.goal["id"],
          "primary_connection_id" => c.fixture.connection["id"],
          "entries" => [
            %{
              "connection_id" => c.fixture.connection["id"],
              "requirement" => "required",
              "capture_run_id" => large.capture["run_id"],
              "capture_revision" => large.capture["revision"]
            }
          ]
        },
        requirements_caller()
      )

    assert saved["revision"] == expected["revision"] + 1
    view |> form("#corpus-requirements-form") |> render_submit()
    assert has_element?(view, "#company-corpus-error", "Load current coverage choices")
    refute has_element?(view, "#corpus-requirements-saved")

    assert Repo.query!("SELECT count(*) FROM corpus_requirements WHERE workspace_id=?", [
             Workspaces.current_id()
           ]).rows == [[1]]
  end

  test "saved coverage survives question edits and its address still needs current authority",
       c do
    {:ok, view, _} = live(c.conn, "/company/corpus")
    open_scope(view, c.fixture)
    ready_capture(view, c.fixture)
    view |> element("#corpus-requirements-begin") |> render_click()
    view |> form("#corpus-requirements-form") |> render_submit()
    url = assert_patch(view)
    saved = socket(view).large.declaration
    reference = socket(view).large.declaration_ref
    assert saved != nil

    view
    |> form("#company-corpus-question",
      retrieval: %{question: "Changed review question", mode: "fts"}
    )
    |> render_change()

    assert socket(view).large.declaration == saved
    assert socket(view).large.declaration_ref == reference

    Repo.query!(
      "UPDATE corpora SET authorization_generation=authorization_generation+1 WHERE id=?",
      [socket(view).large.corpus["id"]]
    )

    {:ok, stale, _} = live(c.conn, url)
    assert socket(stale).large.declaration == nil
    assert socket(stale).readiness["omissions"] == []
    assert has_element?(stale, "#corpus-error", "Coverage context changed")

    assert {:error, {:redirect, %{to: "/login"}}} =
             live(
               init_test_session(
                 build_conn() |> Map.merge(%{host: "localhost", port: 4002}),
                 %{}
               ),
               url
             )
  end

  test "larger saved declarations are read-only and forged edit events cannot drop required scope",
       c do
    extra =
      Enum.map(~w(required optional), fn role ->
        dir = Path.expand("../extra-#{role}", c.fixture.connection["directory"])
        File.mkdir_p!(dir)

        {:ok, connection} =
          Evidence.connect(%{
            "name" => "Extra #{role} scope",
            "provider" => "local",
            "directory" => dir
          })

        {role, connection}
      end)

    {:ok, view, _} = live(c.conn, "/company/corpus")
    open_scope(view, c.fixture)
    ready_capture(view, c.fixture)
    l = socket(view).large

    entries =
      Enum.map(extra, fn {role, connection} ->
        {:ok, queued} =
          Capture.start_capture(
            l.corpus["id"],
            connection["id"],
            l.corpus["semantic_generation"],
            requirements_caller()
          )

        {:ok, cancelled} =
          Capture.cancel(queued["run_id"], queued["revision"], requirements_caller())

        %{
          "connection_id" => connection["id"],
          "requirement" => role,
          "capture_run_id" => cancelled["run_id"],
          "capture_revision" => cancelled["revision"]
        }
      end)

    {:ok, context} =
      Corpora.requirements_context(
        l.corpus["id"],
        c.fixture.project["id"],
        c.fixture.goal["id"],
        c.fixture.input["goal_content_hash"],
        requirements_caller()
      )

    {:ok, declared} =
      Corpora.declare_requirements(
        l.corpus["id"],
        context["expected"],
        %{
          "project_id" => c.fixture.project["id"],
          "goal_id" => c.fixture.goal["id"],
          "primary_connection_id" => c.fixture.connection["id"],
          "entries" => [
            %{
              "connection_id" => c.fixture.connection["id"],
              "requirement" => "required",
              "capture_run_id" => l.capture["run_id"],
              "capture_revision" => l.capture["revision"]
            }
            | entries
          ]
        },
        requirements_caller()
      )

    assert declared["required_status"] == "blocked"

    url =
      "/company/corpus?" <>
        URI.encode_query(%{
          "declaration" => declared["id"],
          "declaration_digest" => declared["digest"]
        })

    {:ok, reopened, _} = live(c.conn, url)

    assert has_element?(
             reopened,
             "#corpus-requirements-read-only",
             "All declared scopes remain included"
           )

    assert has_element?(reopened, "#corpus-requirements-begin[disabled]")
    refute has_element?(reopened, "#corpus-requirements-form")

    reopened
    |> form("#company-corpus-question", retrieval: %{question: "Changed question", mode: "fts"})
    |> render_change()

    assert socket(reopened).large.declaration["id"] == declared["id"]
    assert has_element?(reopened, "#corpus-readiness-capture[data-status=blocked]")
    assert has_element?(reopened, "#corpus-requirements-read-only")

    reopened |> form("#company-corpus-question") |> render_submit()
    render_async(reopened, 1_000)
    assert socket(reopened).large.run["state"] == "abstained"
    assert socket(reopened).large.run["coverage"]["declaration"]["required_status"] == "blocked"

    for event <- ~w(corpus_requirements_begin corpus_requirements_save) do
      render_click(reopened, event, %{
        "corpus_generation" => socket(reopened).generation,
        "requirements" => %{"optional_connection_id" => "", "capture_run_id" => ""}
      })

      assert has_element?(reopened, "#corpus-requirements-saved", "Extra required scope")
      assert has_element?(reopened, "#corpus-readiness-capture[data-status=blocked]")
      assert socket(reopened).large.declaration["id"] == declared["id"]
    end

    assert Repo.query!("SELECT count(*) FROM corpus_requirements WHERE workspace_id=?", [
             Workspaces.current_id()
           ]).rows == [[1]]
  end

  test "ordinary refresh withholds the saved card when another tab supersedes its declaration",
       c do
    {:ok, view, _} = live(c.conn, "/company/corpus")
    open_scope(view, c.fixture)
    ready_capture(view, c.fixture)
    view |> element("#corpus-requirements-begin") |> render_click()
    view |> form("#corpus-requirements-form") |> render_submit()
    assert_patch(view)
    large = socket(view).large
    assert has_element?(view, "#corpus-requirements-saved", "Required captured scope: complete")

    view
    |> form("#company-corpus-question",
      retrieval: %{question: "Which release review and rollback controls apply?", mode: "fts"}
    )
    |> render_submit()

    render_async(view, 1_000)
    run = socket(view).large.run
    assert run["state"] == "ready"
    assert :ok == HarnessForge.Company.Retrieval.validate_current(run["run_id"], run["digest"])

    {:ok, context} =
      Corpora.requirements_context(
        large.corpus["id"],
        c.fixture.project["id"],
        c.fixture.goal["id"],
        c.fixture.input["goal_content_hash"],
        requirements_caller()
      )

    {:ok, _} =
      Corpora.declare_requirements(
        large.corpus["id"],
        context["expected"],
        %{
          "project_id" => c.fixture.project["id"],
          "goal_id" => c.fixture.goal["id"],
          "primary_connection_id" => c.fixture.connection["id"],
          "entries" => [
            %{
              "connection_id" => c.fixture.connection["id"],
              "requirement" => "required",
              "capture_run_id" => nil,
              "capture_revision" => nil
            }
          ]
        },
        requirements_caller()
      )

    view |> element("button[phx-click=corpus_capture_status]") |> render_click()

    assert {:error, :stale_declaration} =
             HarnessForge.Company.Retrieval.validate_current(run["run_id"], run["digest"])

    refute has_element?(view, "#corpus-requirements-saved")
    assert socket(view).large.declaration == nil
    assert socket(view).large.declaration_ref["id"] == large.declaration["id"]
    assert socket(view).readiness["omissions"] == []
    assert has_element?(view, "#corpus-readiness-capture[data-status=stale]")
  end

  defp requirements_caller,
    do: [
      authorize: fn -> true end,
      session_fingerprint: HarnessForge.Contracts.sha256("WEB requirements fixture"),
      view_generation: String.duplicate("f", 32),
      reset_token: 0
    ]

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

  defp ready_capture(view, fixture) do
    if Process.whereis(Capture.Scanner) == nil, do: start_supervised!({Capture.Scanner, []})

    for source <- fixture.sources,
        do:
          File.write!(
            Path.join(fixture.connection["directory"], source["external_id"]),
            source["latest_revision"]["body"]
          )

    view |> element("button[phx-click=corpus_capture_start]") |> render_click()
    assert {:ok, captured} = Capture.run(socket(view).large.capture["run_id"])
    assert captured["capture"]["complete"]

    for [id] <-
          Repo.query!(
            "SELECT latest_revision_id FROM evidence_sources WHERE workspace_id=? AND connection_id=?",
            [Workspaces.current_id(), fixture.connection["id"]]
          ).rows,
        do: assert({:ok, _} = Passages.index_revision(id))

    view |> element("button[phx-click=corpus_capture_status]") |> render_click()

    # The existing corpus generation also advances when its index changes.
    # Do not relabel an old scan as current: show the stale boundary, then
    # exercise an explicit physical verification against the indexed scope.
    assert has_element?(view, "#corpus-readiness-capture[data-status=stale]")
    view |> element("button[phx-click=corpus_capture_start]") |> render_click()
    assert {:ok, verified} = Capture.run(socket(view).large.capture["run_id"])
    assert verified["capture"]["complete"]
    view |> element("button[phx-click=corpus_capture_status]") |> render_click()
  end

  defp socket(view), do: :sys.get_state(view.pid).socket.assigns
end
