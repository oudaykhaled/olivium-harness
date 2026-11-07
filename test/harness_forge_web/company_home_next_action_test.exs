defmodule HarnessForgeWeb.CompanyHomeNextActionTest do
  use HarnessForgeWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias HarnessForge.{Company, CompanyAnalysisFixture, Goals, Repo, Workspaces}
  alias HarnessForgeWeb.Company.Guide
  alias HarnessForgeWeb.CompanyPanel
  alias HarnessForgeWeb.Plugs.OperatorSession

  @generation String.duplicate("d", 32)
  @hash String.duplicate("a", 64)

  setup %{conn: conn} do
    previous = {Application.fetch_env!(:harness_forge, :workspace_root), Workspaces.current_id()}
    id = Ecto.UUID.generate()
    root = Path.join(File.cwd!(), "tmp/company-home-#{id}")
    Enum.each(~w(artifacts runs tmp), &File.mkdir_p!(Path.join(root, &1)))
    Application.put_env(:harness_forge, :workspace_root, root)
    Application.put_env(:harness_forge, :workspace_id, id)

    on_exit(fn ->
      {old_root, old_id} = previous
      Application.put_env(:harness_forge, :workspace_root, old_root)
      Application.put_env(:harness_forge, :workspace_id, old_id)
      File.rm_rf!(root)
    end)

    conn =
      conn
      |> Map.merge(%{host: "localhost", port: 4002})
      |> init_test_session(%{"operator_auth" => OperatorSession.new_auth()})

    {:ok, conn: conn, root: root}
  end

  test "saved harnesses remain directly accessible on a fresh Home without selected plan", c do
    directory = Path.join(c.root, "catalog-evidence")
    File.mkdir_p!(directory)

    assert {:ok, connection} =
             HarnessForge.Evidence.connect(%{
               "provider" => "local",
               "name" => "Public catalog fixture",
               "directory" => directory
             })

    assert {:ok, source} =
             HarnessForge.Evidence.import_markdown(connection["id"], %{
               "external_id" => "catalog.md",
               "title" => "Public catalog fixture",
               "body" => "Review the synthetic change deliberately."
             })

    revision = source["latest_revision"]

    assert {:ok, citation} =
             HarnessForge.Evidence.citation(revision["id"], 0, byte_size(revision["body"]))

    assert {:ok, claim} =
             HarnessForge.Evidence.create_claim(%{
               "text" => "CATALOG_GUIDANCE_BODY_CANARY",
               "citations" => [citation]
             })

    assert {:ok, _} =
             HarnessForge.Decisions.decide(claim["id"], %{
               "actor" => Workspaces.operator(),
               "decision" => "approve",
               "expected_revision_hash" => claim["revision_hash"]
             })

    assert {:ok, artifact} =
             HarnessForge.Harnesses.build(%{
               "name" => "saved-company-harness",
               "runtime" => "codex"
             })

    digest = artifact["digest"]
    before = dispatch_counts()

    for _ <- 1..2 do
      {:ok, view, _} = live(c.conn, "/")
      html = render(view)
      assert_home_structure(html)

      assert has_element?(
               view,
               "#company-home-harness-open-#{digest}[href='/harnesses/#{digest}']"
             )

      assert has_element?(
               view,
               "#company-home-harness-download-#{digest}[href='/harnesses/#{digest}/download']"
             )

      assert has_element?(view, "#company-home-harnesses", "saved-company-harness")
      refute text(html, "#company-home-harnesses") =~ "CATALOG_GUIDANCE_BODY_CANARY"
      assert has_element?(view, "#company-guide-context:not([open])")
      assert has_element?(view, "#company-test-evidence[href='/verification']")
      refute has_element?(view, "#company-guide-selected-plan")
      GenServer.stop(view.pid)
    end

    assert dispatch_counts() == before
  end

  test "catalog projection allowlists metadata and shows unavailable instead of cached rows" do
    artifact = %{
      "digest" => @hash,
      "files" => %{"secret.md" => "SOURCE_PAYLOAD_CANARY"},
      "spec" => %{
        "metadata" => %{"name" => "saved-harness", "version" => "1.0.0"},
        "spec" => %{"rules" => ["RULE_PAYLOAD_CANARY"]}
      }
    }

    data = saved_state() |> Map.put(:artifacts, [artifact]) |> Map.put(:selected_plan, nil)
    projected = Guide.project(data)

    assert projected.saved_harnesses == [
             %{"digest" => @hash, "name" => "saved-harness", "version" => "1.0.0"}
           ]

    refute inspect(projected.saved_harnesses) =~ "PAYLOAD_CANARY"

    unavailable = data |> Map.put(:data_errors, ["artifacts"]) |> Guide.project() |> guide_html()
    assert text(unavailable, "#company-home-harnesses-unavailable") =~ "unavailable"
    assert query(unavailable, "#company-home-harness-open-#{@hash}") == []
  end

  test "catalog is bounded and name ordered, and privacy denial cannot masquerade as empty" do
    artifacts =
      for {name, n} <- Enum.with_index(~w(zeta delta beta alpha gamma), 1),
          do: %{
            "digest" => String.pad_leading(Integer.to_string(n), 64, "0"),
            "spec" => %{"metadata" => %{"name" => name, "version" => "1"}}
          }

    data = saved_state() |> Map.put(:artifacts, artifacts) |> Map.put(:selected_plan, nil)
    html = data |> Guide.project() |> guide_html()
    assert length(query(html, "#company-home-harnesses article")) == 3

    assert Enum.map(query(html, "#company-home-harnesses article strong"), &LazyHTML.text/1) == [
             "alpha · 1",
             "beta · 1",
             "delta · 1"
           ]

    assert length(query(html, "#company-home-harnesses details:not([open])")) == 3
    assert query(html, "#company-home-harnesses-all[href='/?view=package']") != []

    denied =
      data
      |> Map.put(:artifacts, [])
      |> Map.put(:data_errors, ["privacy"])
      |> Guide.project()
      |> guide_html()

    assert query(denied, "#company-home-harnesses-unavailable") != []
    assert query(denied, "#company-home-harnesses-empty") == []
    assert query(denied, "#company-home-harnesses article") == []
  end

  test "empty Home has one continuation before task forms and folded help, with explicit Save retained",
       c do
    before = dispatch_counts()
    {:ok, view, _} = live(c.conn, "/?setup=company")
    html = render(view)
    assert_home_structure(html)

    for section <- ~w(profile repository project analysis evidence plan review build),
        do: assert(has_element?(view, "#company-section-#{section}[hidden]"))

    assert has_element?(view, "#nav-company", "Home")
    assert length(query(html, "#load-demo")) == 1
    assert query(html, "#company-home-about:not([open]) #load-demo") != []
    assert text(html, "#company-home-about-toggle") == "About this workspace and demo"
    assert query(html, "#main-content[aria-label='Company home']") != []

    assert query(
             html,
             "#company-home-about #company-guide-next, #company-home-about [role=alert]"
           ) == []

    assert has_element?(
             view,
             "#company-guide-next[phx-click=company_guide_open][phx-value-section=profile]"
           )

    view |> element("#company-guide-next") |> render_click()
    assert_push_event(view, "company-focus", %{id: "company-profile-name"})
    assert has_element?(view, "#company-section-profile:not([hidden]) #company-profile-form")
    assert has_element?(view, "#company-profile-form button[type=submit]")
    view |> element("#nav-connections") |> render_click()
    sources_html = render(view)
    assert query(sources_html, "#company-home-about") == []
    assert length(query(sources_html, ".page-heading #load-demo")) == 1
    assert text(sources_html, ".page-heading h1") == "Bring your context together."
    assert dispatch_counts() == before
  end

  test "ambiguous saved projects require selection and assigned goals never imply an analysis goal",
       c do
    fixture = CompanyAnalysisFixture.create!(c.root)

    {:ok, other_goal} =
      Goals.add_goal(%{
        "title" => "Synthetic second assigned goal",
        "owner" => "Synthetic owner",
        "acceptance" => "Retain separate future intent."
      })

    {:ok, _} =
      Company.save_profile(
        Map.merge(fixture.profile["payload"], %{
          "goal_ids" => [fixture.goal["id"], other_goal["id"]],
          "expected_content_hash" => fixture.profile["content_hash"]
        })
      )

    {:ok, _} =
      Company.create_project(%{
        "name" => "Synthetic other project",
        "repository_ids" => [fixture.repository["id"]],
        "source_ids" => []
      })

    before = dispatch_counts()
    {:ok, view, _} = live(c.conn, "/?setup=company")
    assert_home_structure(render(view))
    assert has_element?(view, "#company-guide-project option[value=''][selected]")

    assert has_element?(
             view,
             "#company-guide-next[phx-click=company_guide_open][phx-value-section=project]"
           )

    view |> element("#company-guide-next") |> render_click()
    assert_push_event(view, "company-focus", %{id: "company-guide-project"})
    assert has_element?(view, "#company-section-project[hidden] #company-project-form")

    view
    |> form("#company-guide-project-form", guide: %{project_id: fixture.project["id"]})
    |> render_change()

    assert has_element?(view, "#company-guide-scope", fixture.project["payload"]["name"])

    assert has_element?(
             view,
             "#company-guide-project option[value='#{fixture.project["id"]}'][selected]"
           )

    assert has_element?(view, "#company-guide-assigned-goals", fixture.goal["title"])
    assert has_element?(view, "#company-guide-assigned-goals", other_goal["title"])
    assert has_element?(view, "#company-guide-analysis-goal-note")

    assert has_element?(
             view,
             "#company-guide-next[phx-click=company_corpus_open]",
             "Select corpus and goal"
           )

    refute text(render(view), "#company-guide-next") =~ "Resume"
    assert dispatch_counts() == before
    view |> element("#company-guide-next") |> render_click()
    assert_redirect(view, "/company/corpus")
    assert dispatch_counts() == before
  end

  test "saved single-project entry scopes honestly without implicitly selecting its assigned goal",
       c do
    fixture = CompanyAnalysisFixture.create!(c.root)
    before = dispatch_counts()
    {:ok, view, _} = live(c.conn, "/?setup=company")
    assert_home_structure(render(view))
    assert has_element?(view, "#company-guide-saved-summary", fixture.profile["payload"]["name"])
    assert has_element?(view, "#company-guide-scope", fixture.project["payload"]["name"])

    assert has_element?(
             view,
             "#company-guide-project option[value='#{fixture.project["id"]}'][selected]"
           )

    assert has_element?(view, "#company-guide-assigned-goals", fixture.goal["title"])
    assert has_element?(view, "#company-guide-analysis-goal-note")
    assert has_element?(view, "#company-guide-next[phx-click=company_corpus_open]")
    assert dispatch_counts() == before
  end

  test "blocked, stale and unavailable observations keep their recovery beside the sole continuation" do
    for message <- ["Required evidence is blocked.", "Reviewed source revision is stale."] do
      state = %{saved_state() | plan_preflight: {:blocked, message}}
      data = Guide.project(state)
      html = guide_html(data)
      assert data.next.section == "review"
      assert length(query(html, "#company-guide .button.primary")) == 1
      assert text(html, "#company-guide-next-message") == message
      assert query(html, "details #company-guide-next-message") == []
      assert query(html, "#company-guide-next[phx-value-section=review]") != []
      assert query(html, "#company-guide-next[phx-value-section=build]") == []
    end

    unavailable = Guide.project(%{saved_state() | company_load_error: true})
    html = guide_html(unavailable)
    assert unavailable.unavailable
    assert length(query(html, "#company-guide .button.primary")) == 1
    assert query(html, "#company-guide-unavailable[role=status]") != []
    assert query(html, "details #company-guide-unavailable") == []
    assert query(html, "#company-guide-next[phx-value-section=review]") != []
    refute text(html, "#company-guide-next-message") == ""
  end

  test "an already built exact approved candidate opens its generated files" do
    data =
      Guide.project(%{
        saved_state()
        | plan_preflight: :eligible,
          built_artifact: %{"digest" => @hash}
      })

    html = guide_html(data)
    assert data.next.href == "/harnesses/" <> @hash

    assert query(html, "a#company-guide-next[href='/harnesses/#{@hash}']") != []

    assert query(html, "#company-guide-next[phx-value-section=build]") == []
    assert text(html, "#company-guide-selected-plan") =~ @hash
  end

  test "record refresh preserves dirty work and stale navigation cannot replace it or dispatch commands",
       c do
    before = dispatch_counts()
    {:ok, view, _} = live(c.conn, "/?setup=company")
    view |> element("#company-guide-next") |> render_click()

    view
    |> form("#company-profile-form", profile: %{name: "Unsaved Home draft"})
    |> render_change()

    send(view.pid, {:company_changed, "synthetic read-only refresh"})
    render(view)

    assert has_element?(
             view,
             "#company-section-profile:not([hidden]) #company-profile-name[value='Unsaved Home draft']"
           )

    view |> element("#company-corpus-review") |> render_click()
    assert has_element?(view, "#company-error", "Save or discard")

    view
    |> with_target("#company-panel")
    |> render_hook("company_guide_open", %{
      "company_event_generation" => String.duplicate("0", 32),
      "section" => "build"
    })

    assert has_element?(view, "#company-notice", "refreshed controls")
    assert has_element?(view, "#company-profile-name[value='Unsaved Home draft']")
    assert has_element?(view, "#company-section-profile:not([hidden])")
    assert has_element?(view, "#company-section-build[hidden]")
    assert {:ok, nil} = Company.get_profile()
    assert dispatch_counts() == before
  end

  test "Home resume projection strips private content and keeps unknown and partial accounting honest" do
    id = Ecto.UUID.generate()

    setup = %{
      "id" => id,
      "version" => 20,
      "step" => "scope",
      "updated_at" => "2026-11-04T08:00:00Z",
      "reference_status" => %{"status" => "stale", "fields" => %{"private" => "SECRET FIELD"}},
      "draft" => %{"outcome_note" => "SECRET OUTCOME"},
      "selection" => %{"profile" => "SECRET PROFILE"}
    }

    view = %{
      "id" => id,
      "session_version" => 20,
      "run" => %{
        "run_ref" => %{"id" => Ecto.UUID.generate(), "digest" => "SECRET DIGEST"},
        "run_version" => 7,
        "phase" => "cancelled",
        "failure_code" => "cancelled",
        "config" => %{"query_text" => "SECRET QUERY"},
        "prepared" => %{"body" => "SECRET PROMPT"},
        "usage" => %{
          "requests_reserved" => 1,
          "pending_requests" => 0,
          "uncertain_requests" => 1,
          "tokens_accounted" => 15298,
          "cost_microusd_accounted" => nil,
          "private" => "SECRET USAGE"
        }
      },
      "predecessor_usage" => [%{"usage" => %{"uncertain_requests" => nil}}],
      "history_cursor" => "SECRET CURSOR"
    }

    assert {:ok, summary} = CompanyPanel.project_home_resume(setup, view, "explicit")
    assert summary["state"] == "selected"
    assert summary["reference_status"] == "stale"
    assert summary["run_phase"] == "cancelled"
    assert summary["tokens_accounted"] == 15298
    assert summary["cost_microusd_accounted"] == nil
    assert summary["predecessor_uncertain_requests"] == nil
    assert summary["history_partial"] == true

    assert Enum.all?(summary, fn {key, value} ->
             is_binary(key) and
               (is_nil(value) or is_binary(value) or is_number(value) or is_boolean(value))
           end)

    refute Jason.encode!(summary) =~ "SECRET"

    assert {:ok, no_run} =
             CompanyPanel.project_home_resume(
               setup,
               %{view | "run" => nil, "predecessor_usage" => [], "history_cursor" => nil},
               "sole"
             )

    assert no_run["run_id"] == nil and no_run["run_phase"] == nil
    assert no_run["tokens_accounted"] == nil and no_run["requests_reserved"] == nil
    assert no_run["predecessor_uncertain_requests"] == 0
    assert no_run["history_partial"] == false
  end

  test "separate setup and run observations cannot be combined across identities or versions" do
    id = Ecto.UUID.generate()

    setup = %{
      "id" => id,
      "version" => 4,
      "step" => "scope",
      "reference_status" => %{"status" => "current"}
    }

    view = %{
      "id" => id,
      "session_version" => 5,
      "run" => nil,
      "predecessor_usage" => [],
      "history_cursor" => nil
    }

    assert {:error, "conflict"} = CompanyPanel.project_home_resume(setup, view, "explicit")

    assert {:error, "conflict"} =
             CompanyPanel.project_home_resume(
               setup,
               %{view | "id" => Ecto.UUID.generate(), "session_version" => 4},
               "explicit"
             )

    assert {:error, "unavailable"} = CompanyPanel.project_home_resume(nil, view, "explicit")
    assert {:error, "unavailable"} = CompanyPanel.project_home_resume(setup, view, "newest")
  end

  test "saved setup continuation has one recovery action and does not promote readiness or plan authority" do
    base = Map.put(saved_state(), :selected_plan, nil)
    unchanged = Guide.project(base) |> Map.take([:tasks, :readiness])

    for {state, phase, event, label} <- [
          {"choose", nil, "company_setup_open", "Choose saved setup"},
          {"invalid", nil, "company_setup_refresh", "Refresh saved setup"},
          {"unavailable", nil, "company_setup_refresh", "Refresh saved setup"},
          {"selected", nil, "company_setup_resume", "Resume saved setup"},
          {"selected", "cancelled", "company_setup_resume", "Review saved setup recovery"},
          {"selected", "expired", "company_setup_resume", "Review saved setup recovery"}
        ] do
      data = Guide.project(Map.put(base, :home_resume, resume_metadata(state, phase)))
      html = guide_html(data)
      assert length(query(html, "#company-guide .button.primary")) == 1
      assert query(html, "#company-guide-next[phx-click=#{event}]") != []
      assert text(html, "#company-guide-next") == label
      assert Map.take(data, [:tasks, :readiness]) == unchanged
    end
  end

  test "global record unavailability and an explicitly selected plan keep existing recovery precedence" do
    summary = resume_metadata("selected", "cancelled")

    for state <- [
          saved_state(),
          %{saved_state() | plan_preflight: {:blocked, "Exact plan evidence changed."}},
          %{saved_state() | company_load_error: true}
        ] do
      original = Guide.project(state)
      continued = Guide.project(Map.put(state, :home_resume, summary))
      assert continued.next == original.next
      assert length(query(guide_html(continued), "#company-guide .button.primary")) == 1
    end
  end

  test "compact recovery and the primary precede long context and closed audit details" do
    base = Map.put(saved_state(), :selected_plan, nil)

    for phase <- [nil, "blocked", "cancelled", "expired"] do
      summary =
        resume_metadata("selected", phase)
        |> Map.put("reference_status", "stale")
        |> Map.put("updated_at", "2026-11-04T08:29:57.858010Z")

      data =
        base
        |> Map.put(:home_resume, summary)
        |> Guide.project()
        |> Map.put(:profile_name, String.duplicate("Long company context ", 40))

      html = guide_html(data)
      assert length(query(html, "#company-guide .button.primary")) == 1
      assert query(html, "details #company-guide-next") == []
      assert query(html, "details #company-home-resume-compact") == []
      assert text(html, "#company-home-resume-compact") =~ "20"
      refute text(html, "#company-home-resume-compact") =~ summary["id"]
      refute text(html, "#company-home-resume-compact") =~ summary["updated_at"]

      assert query(
               html,
               "details#company-home-resume-details:not([open]) summary#company-home-resume-details-toggle"
             ) != []

      assert text(html, "#company-home-resume-details-toggle") == "Saved setup details and usage"

      for id <-
            ~w(company-home-resume-identity company-home-resume-reference company-home-resume-run company-home-resume-history company-home-resume-refresh) do
        assert length(query(html, "#company-home-resume-details ##{id}")) == 1
        assert position(html, "company-guide-next") < position(html, id)
      end

      for id <- ~w(company-guide-saved-summary company-guide-scope company-guide-assigned-goals) do
        assert position(html, "company-guide-next") < position(html, id)
      end

      if phase in ~w(cancelled expired) do
        assert text(html, "#company-home-resume-compact") =~ phase
        assert text(html, "#company-home-resume-recovery") =~ "Explicit recovery required"
        assert query(html, "details #company-home-resume-recovery") == []
      end
    end
  end

  defp resume_metadata(state, phase) do
    %{
      "state" => state,
      "origin" => "explicit",
      "id" => if(state == "selected", do: Ecto.UUID.generate()),
      "version" => 20,
      "step" => "scope",
      "updated_at" => nil,
      "reference_status" => "current",
      "run_id" => if(phase, do: Ecto.UUID.generate()),
      "run_version" => if(phase, do: 7),
      "run_phase" => phase,
      "failure_code" => nil,
      "requests_reserved" => if(phase, do: 1),
      "pending_requests" => if(phase, do: 0),
      "uncertain_requests" => if(phase, do: 1),
      "tokens_accounted" => if(phase, do: 15298),
      "cost_microusd_accounted" => nil,
      "predecessor_uncertain_requests" => 1,
      "history_partial" => true,
      "error_code" => nil
    }
  end

  defp assert_home_structure(html) do
    assert length(query(html, "#company-guide-next")) == 1
    assert length(query(html, "#company-guide .button.primary")) == 1
    assert query(html, "#company-corpus-review.button.secondary") != []

    assert query(html, "#company-corpus-review.button.primary, details #company-corpus-review") ==
             []

    assert query(
             html,
             "details#company-corpus-entry:not([open]) summary#company-corpus-entry-title"
           ) != []

    assert text(html, "#company-corpus-entry-title") == "How this works"
    assert query(html, "#company-guide-details[open]") == []

    for id <- ["company-corpus-entry", "company-profile-form", "company-plan-form"] do
      assert position(html, "company-guide-next") < position(html, id)
    end

    if query(html, "#company-guide-project-form") != [],
      do:
        assert(
          position(html, "company-guide-next") < position(html, "company-guide-project-form")
        )
  end

  # Projection fixtures describe server observations only; they grant no claim,
  # plan, build or release authority and do not establish durable resume.
  defp saved_state do
    project = %{
      "id" => "project",
      "content_hash" => @hash,
      "payload" => %{
        "name" => "Synthetic project",
        "repository_ids" => ["repository"],
        "source_ids" => [],
        "goal_ids" => ["goal"]
      }
    }

    plan = %{
      "id" => "plan",
      "revision_hash" => @hash,
      "status" => "approved",
      "superseded" => false,
      "payload" => %{
        "name" => "synthetic-plan",
        "package_version" => "1.0.0",
        "project_id" => "project"
      }
    }

    %{
      profile: %{
        "id" => "profile",
        "content_hash" => @hash,
        "payload" => %{"name" => "Synthetic company", "source_ids" => [], "goal_ids" => ["goal"]}
      },
      repositories: [%{"id" => "repository"}],
      projects: [project],
      guide_project_id: "project",
      sources: [],
      goals: [%{"id" => "goal", "title" => "Synthetic saved goal"}],
      approved: [%{"status" => "approved", "basis" => %{"kind" => "goal", "goal_id" => "goal"}}],
      company_load_error: false,
      data_errors: [],
      selected_plan: plan,
      plans: [plan],
      company_reset_token: 0,
      claim_review_count: 0,
      plan_preflight: :eligible,
      built_artifact: nil
    }
  end

  defp guide_html(data),
    do:
      render_component(&Guide.workflow/1,
        data: data,
        target: nil,
        company_event_generation: @generation
      )

  defp query(html, selector),
    do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> Enum.to_list()

  defp text(html, selector),
    do: query(html, selector) |> Enum.map_join(&LazyHTML.text/1) |> String.trim()

  defp position(html, id), do: :binary.match(html, "id=\"#{id}\"") |> elem(0)

  defp dispatch_counts do
    for table <-
          ~w(model_requests evidence_claims claim_decisions company_plans company_plan_decisions retrieval_runs capture_runs),
        into: %{} do
      {table,
       Repo.query!("SELECT count(*) FROM #{table} WHERE workspace_id=?", [Workspaces.current_id()]).rows}
    end
  end
end
