defmodule HarnessForgeWeb.CompanyBuilderTest do
  use HarnessForgeWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias HarnessForge.{Company, Decisions, Evidence, Goals, Harnesses, Privacy, Repo, Workspaces}
  alias HarnessForgeWeb.Plugs.OperatorSession

  setup %{conn: conn} = context do
    previous = Application.fetch_env!(:harness_forge, :workspace_root)
    previous_id = Workspaces.current_id()
    id = Ecto.UUID.generate()
    root = Path.join(File.cwd!(), "tmp/company-web-#{id}")
    Enum.each(~w(artifacts runs tmp), &File.mkdir_p!(Path.join(root, &1)))
    Application.put_env(:harness_forge, :workspace_root, root)
    Application.put_env(:harness_forge, :workspace_id, id)

    if context[:committed] do
      # Snapshot.backup/1 deliberately refuses sandbox transactions. Only this
      # synthetic, uniquely scoped fixture uses committed writes.
      :ok = Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
      :ok = Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    end

    on_exit(fn ->
      if context[:committed] do
        :ok = Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)

        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          {:ok, _} = Privacy.purge_workspace(id)
        end)
      end

      Application.put_env(:harness_forge, :workspace_root, previous)
      Application.put_env(:harness_forge, :workspace_id, previous_id)
      File.rm_rf!(root)
      File.rm_rf!(root <> "-backup")
      File.rm_rf!(root <> "-restored")
    end)

    conn = %{conn | host: "localhost", port: 4002}

    {:ok,
     conn: init_test_session(conn, %{"operator_auth" => OperatorSession.new_auth()}), root: root}
  end

  test "guided catalogue forms save explicit company and project membership and show bounded lookups",
       %{conn: conn} do
    fixture = evidence_fixture()
    {:ok, view, _} = live(conn, "/")
    view |> element("#nav-company") |> render_click()
    assert has_element?(view, "#company-repositories-empty")
    assert has_element?(view, "#company-plan-blocked")

    {profile, repository, project} = company_forms(view, fixture)
    assert profile["payload"]["name"] == "Synthetic company"
    assert profile["payload"]["source_ids"] == []
    assert project["payload"]["repository_ids"] == [repository["id"]]
    assert project["payload"]["source_ids"] == [fixture.source["id"]]
    assert project["payload"]["goal_ids"] == [fixture.goal["id"]]

    view
    |> form("#company-repository-form",
      repository: repository_form("example/checkout", "Checkout", [repository["id"]])
    )
    |> render_submit()

    {:ok, repositories} = Company.list_repositories()
    checkout = Enum.find(repositories, &(&1["payload"]["name"] == "Checkout"))
    assert checkout["payload"]["dependency_ids"] == [repository["id"]]

    view |> form("#company-capability-form", capability: %{query: "PAYMENTS"}) |> render_submit()
    assert has_element?(view, "#company-capability-results", "Payments authorization")
    view |> element("#company-consumers-#{repository["id"]}") |> render_click()
    assert has_element?(view, "#company-consumer-results", "Checkout")
    view |> element("#company-consumers-#{checkout["id"]}") |> render_click()
    assert has_element?(view, "#company-consumer-results", "No declared consumers")

    view |> element("#company-repository-edit-#{checkout["id"]}") |> render_click()

    view
    |> form("#company-repository-form",
      repository: %{purpose: "Checkout service updated deliberately"}
    )
    |> render_submit()

    assert {:ok, updated} = Company.list_repositories()

    assert Enum.find(updated, &(&1["id"] == checkout["id"]))["payload"]["purpose"] ==
             "Checkout service updated deliberately"

    # Catalogue changes and project assignments never decide evidence or plans.
    assert {:ok, %{"status" => "proposed"}} = Evidence.get_claim(fixture.proposed["id"])
    assert {:ok, []} = Company.list_plans()
  end

  for {decision, outcome} <- [{"approve", "approved"}, {"reject", "rejected"}] do
    @tag :decision_focus
    test "an exact #{decision} plan decision keeps keyboard review focus", %{conn: conn} do
      fixture = evidence_fixture()
      {_profile, repository, project} = saved_company(fixture)
      {:ok, plan} = Company.create_plan(domain_plan(fixture, repository, project))
      {:ok, view, _} = live(conn, "/")
      view |> element("#nav-company") |> render_click()
      select_plan(view, plan)
      assert_push_event(view, "company-focus", %{id: "company-plan-review-step"})

      view
      |> form("#company-plan-decision-form")
      |> render_submit(%{"plan_decision" => %{"decision" => unquote(decision)}})

      assert {:ok, %{"status" => unquote(outcome)}} = Company.get_plan(plan["id"])
      refute has_element?(view, "#company-plan-decision-form")
      assert_push_event(view, "company-focus", %{id: "company-plan-review-step"})
    end
  end

  test "forms pin selected revisions, require exact independent approval, build and compare successor packages",
       %{conn: conn} do
    fixture = evidence_fixture()
    {:ok, view, _} = live(conn, "/")
    view |> element("#nav-company") |> render_click()
    {_profile, repository, project} = company_forms(view, fixture)

    view |> form("#company-plan-form", plan: %{project_id: project["id"]}) |> render_change()
    assert has_element?(view, "#company-plan-claims", fixture.claim["revision_hash"])
    refute has_element?(view, "#company-plan-claims", fixture.proposed["text"])
    input = plan_form(fixture, repository, project)
    view |> form("#company-plan-form", plan: input) |> render_change()
    view |> element("#company-milestone-add") |> render_click()
    view |> element("#company-milestone-add") |> render_click()

    milestones = %{
      "0" => milestone("review", "Review the proposed change", fixture.goal["id"], []),
      "1" => milestone("deliver", "Evaluate the reviewed change", fixture.goal["id"], ["review"])
    }

    # Choose identifiers before checking a dependency on one of those identifiers.
    without_dependencies = Map.update!(milestones, "1", &Map.put(&1, "depends_on", []))

    view
    |> form("#company-plan-form", plan: Map.put(input, "milestones", without_dependencies))
    |> render_change()

    view
    |> form("#company-plan-form", plan: Map.put(input, "milestones", milestones))
    |> render_submit()

    assert has_element?(view, "#company-notice", "saved as proposed")
    assert {:ok, [plan]} = Company.list_plans()
    assert plan["status"] == "proposed"
    assert plan["payload"]["claim_refs"] == [Map.take(fixture.claim, ~w(id revision_hash))]
    assert plan["payload"]["goal_ids"] == [fixture.goal["id"]]
    assert plan["payload"]["template_ids"] == ["reviewed-change-v1"]
    assert plan["payload"]["repository_ids"] == [repository["id"]]

    assert Enum.find(plan["payload"]["milestones"], &(&1["id"] == "deliver"))["depends_on"] == [
             "review"
           ]

    assert has_element?(view, "#company-displayed-plan-hash", plan["revision_hash"])
    assert has_element?(view, "#company-plan-build[disabled]")
    assert {:error, :plan_not_approved} = Company.build_inputs(plan["id"])

    # A submitted form cannot bypass the disabled build control.
    view |> form("#company-plan-build-form") |> render_submit()
    assert has_element?(view, "#company-error", "Approve the exact displayed plan")
    assert {:ok, []} = Harnesses.list_artifacts()

    view
    |> form("#company-plan-decision-form")
    |> render_submit(%{
      "plan_decision" => %{"expected_revision_hash" => String.duplicate("0", 64)}
    })

    assert has_element?(view, "#company-error", "displayed revision")
    assert {:ok, %{"status" => "proposed"}} = Company.get_plan(plan["id"])
    view |> form("#company-plan-decision-form") |> render_submit()
    assert {:ok, %{"status" => "approved"}} = Company.get_plan(plan["id"])
    refute has_element?(view, "#company-plan-decision-form")

    view
    |> form("#company-plan-build-form")
    |> render_submit(%{"plan_build" => %{"expected_revision_hash" => String.duplicate("0", 64)}})

    assert has_element?(view, "#company-error", "displayed revision")
    view |> form("#company-plan-build-form") |> render_submit()
    assert has_element?(view, "#company-built-package", "0.1.0")
    assert {:ok, [v0]} = Harnesses.list_artifacts()
    assert get_in(v0, ["spec", "spec", "scope", "repositories"]) == ["example/payments"]
    assert Enum.map(get_in(v0, ["spec", "spec", "rules"]), & &1["id"]) == [fixture.claim["id"]]
    assert Enum.map(get_in(v0, ["spec", "spec", "goals"]), & &1["id"]) == [fixture.goal["id"]]

    view |> element("#company-plan-successor") |> render_click()
    assert has_element?(view, "#company-plan-successor-note", plan["id"])
    assert has_element?(view, "#company-plan-runtime-version[value=unqualified]")

    view
    |> form("#company-plan-form",
      plan: %{
        package_version: "0.2.0",
        template_ids: ["reviewed-change-v1", "reuse-before-build-v1"]
      }
    )
    |> render_submit()

    assert {:ok, plans} = Company.list_plans()
    successor = Enum.find(plans, &(&1["supersedes_id"] == plan["id"]))
    assert successor["status"] == "proposed"
    assert successor["family_id"] == plan["family_id"]
    assert {:ok, _} = Company.build_inputs(plan["id"])
    assert {:error, :plan_not_approved} = Company.build_inputs(successor["id"])
    view |> form("#company-plan-decision-form") |> render_submit()
    view |> form("#company-plan-build-form") |> render_submit()
    assert has_element?(view, "#company-built-package", "0.2.0")
    assert {:ok, artifacts} = Harnesses.list_artifacts()
    v1 = Enum.find(artifacts, &(&1["digest"] != v0["digest"]))

    view
    |> form("#company-diff-form", company_diff: %{left: v0["digest"], right: v1["digest"]})
    |> render_submit()

    assert has_element?(view, "#company-diff-result", v0["digest"])
    assert has_element?(view, "#company-diff-result", v1["digest"])
    assert has_element?(view, "#company-diff-result", "Changed:")

    assert has_element?(
             view,
             "#company-diff-result",
             ".opencode/skills/reuse-before-build-v1/SKILL.md"
           )

    view |> element("#company-open-packages") |> render_click()

    assert has_element?(
             view,
             "#artifact-#{v1["digest"]} [id^=package-export-form-][id$='#{v1["digest"]}']"
           )

    assert has_element?(view, "#build-form")
  end

  test "drafts survive navigation to existing review flows and every existing tab remains", %{
    conn: conn
  } do
    fixture = evidence_fixture()
    {:ok, view, _} = live(conn, "/")
    view |> element("#nav-company") |> render_click()
    view |> form("#company-plan-form", plan: %{name: "draft-kept"}) |> render_change()
    view |> element("#company-review-evidence") |> render_click()
    assert has_element?(view, "#evidence-panel")
    view |> element("#approve-#{fixture.proposed["id"]}") |> render_click()
    assert {:ok, %{"status" => "approved"}} = Evidence.get_claim(fixture.proposed["id"])
    view |> element("#nav-company") |> render_click()
    assert has_element?(view, "#company-plan-name[value=draft-kept]")

    for tab <- ~w(chat connections evidence goals package evaluations releases audit privacy) do
      view |> element("#nav-#{tab}") |> render_click()
      assert has_element?(view, "##{tab}-panel")
    end
  end

  test "browser unused-input metadata preserves project selection and scoped repository choices",
       %{conn: conn} do
    fixture = evidence_fixture()
    {:ok, view, _} = live(conn, "/")
    view |> element("#nav-company") |> render_click()
    {_profile, repository, project} = company_forms(view, fixture)

    # Phoenix's serializeForm/prependFormDataKey emits an empty marker for each
    # unused non-hidden field, preserving [] for arrays and nested field paths.
    pairs = [
      {"plan[_unused_name]", ""},
      {"plan[name]", ""},
      {"plan[_unused_package_version]", ""},
      {"plan[package_version]", "0.1.0"},
      {"plan[project_id]", project["id"]},
      {"plan[repository_ids][]", ""},
      {"plan[claim_refs][]", ""},
      {"plan[goal_ids][]", ""},
      {"plan[_unused_template_ids][]", ""},
      {"plan[template_ids][]", ""},
      {"plan[_unused_runtime]", ""},
      {"plan[runtime]", "opencode"},
      {"plan[_unused_runtime_version]", ""},
      {"plan[runtime_version]", "unqualified"},
      {"plan[execution][_unused_max_turns]", ""},
      {"plan[execution][max_turns]", "12"},
      {"plan[execution][_unused_timeout_seconds]", ""},
      {"plan[execution][timeout_seconds]", "600"},
      {"plan[supersedes_id]", ""}
    ]

    browser_params =
      pairs
      |> Enum.map_join("&", fn {key, value} ->
        URI.encode_www_form(key) <> "=" <> URI.encode_www_form(value)
      end)
      |> Plug.Conn.Query.decode()

    assert browser_params["plan"]["_unused_template_ids"] == [""]
    assert browser_params["plan"]["execution"]["_unused_max_turns"] == ""
    view |> form("#company-plan-form") |> render_change(browser_params)
    refute has_element?(view, "#company-error")
    assert has_element?(view, "#company-plan-project option[selected][value='#{project["id"]}']")
    assert has_element?(view, "#company-plan-repositories-#{repository["id"]}")

    input = plan_form(fixture, repository, project)
    view |> form("#company-plan-form", plan: input) |> render_change()
    view |> element("#company-milestone-add") |> render_click()

    row =
      milestone("review", "Browser milestone", fixture.goal["id"], [])
      |> Map.merge(%{"_unused_title" => "", "_unused_goal_ids" => ["", ""]})

    view
    |> form("#company-plan-form")
    |> render_change(%{"plan" => Map.put(input, "milestones", %{"0" => row})})

    refute has_element?(view, "#company-error")
    assert has_element?(view, "#company-milestone-0-title[value='Browser milestone']")
  end

  test "malformed targeted plan forms show an error and keep the component available", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, "/")
    view |> element("#nav-company") |> render_click()

    view
    |> form("#company-plan-form")
    |> render_change(%{
      "plan" => %{"milestones" => %{"not-a-number" => ["invalid"]}, "claim_refs" => [42]}
    })

    assert has_element?(view, "#company-error", "action was rejected")
    assert has_element?(view, "#company-profile-form")
    assert Process.alive?(view.pid)
    assert {:ok, []} = Company.list_plans()

    for value <- [false, nil, "invalid", [], 1] do
      view
      |> form("#company-plan-form")
      |> render_change(%{"plan" => %{"execution" => value, "_unused_execution" => ""}})

      assert has_element?(view, "#company-error", "action was rejected")
      assert Process.alive?(view.pid)
    end

    for rows <- [
          %{
            "0" =>
              milestone("review", "Review", Ecto.UUID.generate(), [])
              |> Map.merge(%{"id" => 1, "_unused_id" => ""}),
            "1" => milestone("deliver", "Deliver", Ecto.UUID.generate(), [])
          },
          %{"0" => %{}, "1" => %{}}
        ] do
      view |> form("#company-plan-form") |> render_change(%{"plan" => %{"milestones" => rows}})
      assert has_element?(view, "#company-error", "action was rejected")
      assert Process.alive?(view.pid)
    end
  end

  test "revoked operator sessions cannot submit component-targeted company writes", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    view |> element("#nav-company") |> render_click()
    profile_form = form(view, "#company-profile-form", profile: %{name: "Must not be saved"})
    previous = :sys.get_state(Workspaces)
    :sys.replace_state(Workspaces, &%{&1 | epoch: "revoked-company-session"})
    on_exit(fn -> :sys.replace_state(Workspaces, fn _ -> previous end) end)
    assert {:error, {:redirect, %{to: "/login"}}} = render_submit(profile_form)
    assert {:ok, nil} = Company.get_profile()
  end

  test "oversized targeted execution strings cannot enter drafts or plans and integers remain valid",
       %{
         conn: conn
       } do
    fixture = evidence_fixture()
    {_profile, repository, project} = saved_company(fixture)
    {:ok, view, _} = live(conn, "/")
    view |> element("#nav-company") |> render_click()
    view |> form("#company-plan-form", plan: %{project_id: project["id"]}) |> render_change()
    execution = %{"max_turns" => 12, "timeout_seconds" => 600}
    input = Map.put(plan_form(fixture, repository, project), "execution", execution)

    view
    |> with_target("#company-panel")
    |> render_hook("company_plan_change", current_company_envelope(view, %{"plan" => input}))

    draft = company_assigns(view).plan_draft
    assert draft["execution"] == execution
    oversized = String.duplicate("9", 16_385)

    for field <- ~w(max_turns timeout_seconds) do
      targeted = Map.put(input, "execution", Map.put(execution, field, oversized))

      view
      |> with_target("#company-panel")
      |> render_hook("company_plan_change", current_company_envelope(view, %{"plan" => targeted}))

      assert has_element?(view, "#company-plan-error", "action was rejected")
      assert company_assigns(view).plan_draft == draft
      refute render(view) =~ oversized

      view
      |> with_target("#company-panel")
      |> render_hook("company_plan_create", current_company_envelope(view, %{"plan" => targeted}))

      assert has_element?(view, "#company-plan-error", "action was rejected")
      assert company_assigns(view).plan_draft == draft
      assert {:ok, []} = Company.list_plans()
      refute render(view) =~ oversized
    end

    view
    |> with_target("#company-panel")
    |> render_hook("company_plan_create", current_company_envelope(view, %{"plan" => input}))

    assert {:ok, [plan]} = Company.list_plans()
    assert plan["payload"]["execution"] == execution
    assert plan["status"] == "proposed"
  end

  test "empty guide starts at saved profile and disclosure preserves mounted forms", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    view |> element("#nav-company") |> render_click()
    assert has_element?(view, "#company-guide")
    assert has_element?(view, "#company-claim-review-count", "0")
    assert has_element?(view, "#company-plan-review-count", "0")
    refute has_element?(view, ".metrics")
    refute has_element?(view, ".workflow")
    assert has_element?(view, "#company-section-profile[hidden] #company-profile-form")
    assert has_element?(view, "#company-section-repository[hidden] #company-repository-form")
    view |> element("#company-guide-next") |> render_click()
    assert_push_event(view, "company-focus", %{id: "company-profile-name"})
    view |> element("#company-toggle-profile") |> render_click()
    assert_push_event(view, "company-focus", %{id: "company-toggle-profile"})
    assert has_element?(view, "#company-section-profile[hidden] #company-profile-form")
    view |> element("#nav-evidence") |> render_click()
    assert has_element?(view, ".metrics")
    assert has_element?(view, "#company-panel[hidden] #company-profile-form")
  end

  test "all Company producers carry current metadata and malformed envelopes preserve legitimate drafts",
       %{conn: conn} do
    fixture = evidence_fixture()
    {_profile, repository, project} = saved_company(fixture)
    {:ok, plan} = Company.create_plan(domain_plan(fixture, repository, project))
    {:ok, _} = Harnesses.build(%{"name" => "synthetic-first"})
    {:ok, _} = Harnesses.build(%{"name" => "synthetic-second"})
    {:ok, view, _} = live(conn, "/")
    view |> element("#nav-company") |> render_click()
    select_plan(view, plan)
    generation = company_assigns(view).company_event_generation
    assert generation =~ ~r/\A[0-9a-f]{32}\z/

    for id <-
          ~w(company-guide-project-form company-profile-form company-repository-form company-project-form company-capability-form company-plan-form company-plan-decision-form company-plan-build-form company-diff-form) do
      assert has_element?(
               view,
               "##{id} input[name=company_event_generation][type=hidden][value='#{generation}']:not([disabled])"
             )
    end

    refute has_element?(
             view,
             "#company-panel [phx-click]:not([phx-value-company_event_generation='#{generation}'])"
           )

    view |> form("#company-profile-form", profile: %{name: "CURRENT_DRAFT"}) |> render_change()

    future =
      if String.first(generation) == "a",
        do: "b" <> String.slice(generation, 1, 31),
        else: "a" <> String.slice(generation, 1, 31)

    payload = %{"profile" => %{"name" => "REPLAY_CANARY"}}

    invalid =
      [
        payload,
        %{"profile" => %{"name" => "REPLAY_CANARY", "company_event_generation" => generation}},
        Map.put(payload, "company_event_generation", 0),
        Map.put(payload, "company_event_generation", nil),
        Map.put(payload, "company_event_generation", [generation]),
        Map.put(payload, "company_event_generation", String.duplicate("a", 31)),
        Map.put(payload, "company_event_generation", String.duplicate("G", 32)),
        Map.put(payload, "company_event_generation", String.duplicate("a", 16_385)),
        Map.put(payload, "company_event_generation", future)
      ] ++
        Enum.map([nil, [], [""], "tampered"], fn marker ->
          payload
          |> Map.put("company_event_generation", generation)
          |> Map.put("_unused_company_event_generation", marker)
        end)

    assert_old_envelopes_rejected(view, Enum.map(invalid, &{"company_profile_change", &1}))

    accepted =
      current_company_envelope(view, %{
        "profile" => %{"name" => "Current metadata accepted", "_unused_name" => ""}
      })
      |> Map.put("_unused_company_event_generation", "")

    replay_company_event(view, "company_profile_change", accepted)
    draft = company_assigns(view).profile_draft
    assert draft["name"] == "Current metadata accepted"
    refute Map.has_key?(draft, "company_event_generation")
    refute Map.has_key?(draft, "_unused_name")
    assert company_assigns(view).company_event_generation == generation
  end

  test "current lookup and comparison failures open their own section and focus its error summary",
       %{conn: conn} do
    fixture = evidence_fixture()
    saved_company(fixture)
    {:ok, left} = Harnesses.build(%{"name" => "synthetic-recovery-first"})
    {:ok, _} = Harnesses.build(%{"name" => "synthetic-recovery-second"})
    {:ok, view, _} = live(conn, "/")
    view |> element("#nav-company") |> render_click()

    view
    |> form("#company-profile-form", profile: %{name: "Preserved profile draft"})
    |> render_change()

    view |> form("#company-plan-form", plan: %{name: "preserved-plan-draft"}) |> render_change()
    before = company_assigns(view)

    for query <- [String.duplicate("x", 2_001), ["malformed scalar"]] do
      if has_element?(view, "#company-section-repository:not([hidden])"),
        do: view |> element("#company-toggle-repository") |> render_click()

      payload = current_company_envelope(view, %{"capability" => %{"query" => query}})
      replay_company_event(view, "company_capability_search", payload)
      assert has_element?(view, "#company-section-repository:not([hidden])")
      assert has_element?(view, "#company-repository-error[tabindex='-1']")
      assert_push_event(view, "company-focus", %{id: "company-repository-error"})
    end

    assert has_element?(view, "#company-section-build[hidden]")

    payload =
      current_company_envelope(view, %{
        "company_diff" => %{"left" => left["digest"], "right" => String.duplicate("0", 64)}
      })

    replay_company_event(view, "company_package_diff", payload)
    assert has_element?(view, "#company-section-build:not([hidden])")
    assert has_element?(view, "#company-build-error[tabindex='-1']")
    assert_push_event(view, "company-focus", %{id: "company-build-error"})
    after_rejection = company_assigns(view)
    assert after_rejection.profile_draft == before.profile_draft
    assert after_rejection.plan_draft == before.plan_draft
    assert after_rejection.company_event_generation == before.company_event_generation
    assert after_rejection.package_diff == nil
  end

  test "unchanged pre-reset form and click envelopes cannot mutate a newer Company generation", %{
    conn: conn
  } do
    fixture = evidence_fixture()
    {_profile, repository, project} = saved_company(fixture)
    {:ok, approved} = Company.create_plan(domain_plan(fixture, repository, project))
    {:ok, approved} = Company.decide_plan(approved["id"], plan_decision(approved))

    {:ok, proposed} =
      Company.create_plan(
        Map.put(domain_plan(fixture, repository, project), "package_version", "0.2.0")
      )

    {:ok, view, _} = live(conn, "/")
    view |> element("#nav-company") |> render_click()

    captured =
      capture_company_forms(view, fixture, repository, project) ++
        capture_company_clicks(view, repository, project, approved, proposed)

    old_generation = company_assigns(view).company_event_generation
    send(view.pid, :company_cache_reset)
    render(view)
    assert company_assigns(view).company_reset_token == 1
    refute company_assigns(view).company_event_generation == old_generation
    view |> form("#company-profile-form", profile: %{name: "CURRENT_DRAFT"}) |> render_change()
    select_plan(view, approved)
    view |> form("#company-plan-form", plan: %{project_id: project["id"]}) |> render_change()

    view
    |> form("#company-plan-form", plan: plan_form(fixture, repository, project))
    |> render_change()

    view |> element("#company-milestone-add") |> render_click()
    assert_captured_generation_rotated(view, captured)
    assert_old_envelopes_rejected(view, captured)
    assert {:ok, %{"status" => "proposed"}} = Company.get_plan(proposed["id"])
    assert {:ok, []} = Harnesses.list_artifacts()
    view |> element("#company-profile-discard") |> render_click()

    view
    |> form("#company-profile-form", profile: %{name: "Current controls save"})
    |> render_submit()

    assert {:ok, %{"payload" => %{"name" => "Current controls save"}}} = Company.get_profile()
  end

  test "a remounted Company rejects captured envelopes when both DOM reset counters are zero", %{
    conn: conn
  } do
    fixture = evidence_fixture()
    {_profile, repository, project} = saved_company(fixture)
    {:ok, first, _} = live(conn, "/")
    first |> element("#nav-company") |> render_click()
    captured = capture_company_forms(first, fixture, repository, project)
    old = company_assigns(first)
    GenServer.stop(first.pid)
    {:ok, remounted, _} = live(conn, "/")
    remounted |> element("#nav-company") |> render_click()
    current = company_assigns(remounted)
    assert old.company_reset_token == 0
    assert current.company_reset_token == 0
    refute current.company_event_generation == old.company_event_generation
    assert_captured_generation_rotated(remounted, captured)
    assert_old_envelopes_rejected(remounted, captured)

    remounted
    |> form("#company-profile-form", profile: %{name: "New mount accepts current controls"})
    |> render_submit()

    assert {:ok, %{"payload" => %{"name" => "New mount accepts current controls"}}} =
             Company.get_profile()
  end

  test "guide counts actionable workspace queues and requires evidence assigned to saved scope",
       %{
         conn: conn
       } do
    fixture = evidence_fixture()
    {_profile, repository, project} = saved_company(fixture, source_ids: [])
    {:ok, citation} = Evidence.citation(fixture.source["latest_revision"]["id"], 0, 6)

    {:ok, _successor} =
      Evidence.create_claim(%{
        "text" => "The actionable successor proposal",
        "citations" => [citation],
        "supersedes_id" => fixture.proposed["id"]
      })

    {:ok, view, _} = live(conn, "/")
    view |> element("#nav-company") |> render_click()
    assert has_element?(view, "#company-claim-review-count", "1")
    assert has_element?(view, "#company-plan-review-count", "0")
    assert has_element?(view, "#company-guide-next[phx-click=company_corpus_open]")

    assert {:error, :source_out_of_scope} =
             Company.create_plan(domain_plan(fixture, repository, project))

    {:ok, _} =
      Company.update_project(
        project["id"],
        replacement(project, %{"source_ids" => [fixture.source["id"]]})
      )

    refresh_company(view, "Saved scope changed")
    assert has_element?(view, "#company-guide-next[phx-value-section=plan]")

    assert {:ok, _second} =
             Company.create_project(%{
               "name" => "Other saved project",
               "repository_ids" => [repository["id"]]
             })

    refresh_company(view, "More than one saved project")
    assert has_element?(view, "#company-guide-project")
    assert company_assigns(view).guide_project_id == nil
    view |> element("#company-guide-next") |> render_click()
    assert_push_event(view, "company-focus", %{id: "company-guide-project"})
  end

  test "guide follows exact proposed rejected approved and stale plans and retains eligible ancestors",
       %{
         conn: conn
       } do
    fixture = evidence_fixture()
    {_profile, repository, project} = saved_company(fixture)
    {:ok, plan} = Company.create_plan(domain_plan(fixture, repository, project))
    {:ok, view, _} = live(conn, "/")
    view |> element("#nav-company") |> render_click()
    select_plan(view, plan)
    assert has_element?(view, "#company-guide-next[phx-value-section=review]")
    assert has_element?(view, "#company-plan-review-count", "1")
    assert company_assigns(view).plan_preflight == :none

    {:ok, _} = Company.decide_plan(plan["id"], plan_decision(plan, "reject"))
    refresh_company(view, "Plan rejected")
    assert has_element?(view, "#company-guide-next", "Propose a new plan version")
    assert has_element?(view, "#company-plan-review-count", "0")
    refute has_element?(view, "#company-plan-decision-form")

    {:ok, approved} =
      Company.create_plan(
        Map.put(domain_plan(fixture, repository, project), "supersedes_id", plan["id"])
      )

    {:ok, approved} = Company.decide_plan(approved["id"], plan_decision(approved))

    {:ok, _successor} =
      Company.create_plan(
        Map.put(domain_plan(fixture, repository, project), "supersedes_id", approved["id"])
      )

    refresh_company(view, "Approved predecessor and proposed successor")
    select_plan(view, approved)
    assert company_assigns(view).plan_preflight == :eligible
    assert has_element?(view, "#company-guide-next[phx-value-section=build]")
    assert has_element?(view, "#company-plan-review-count", "1")
    refute has_element?(view, "#company-plan-build[disabled]")

    {:ok, _} =
      Company.update_repository(
        repository["id"],
        replacement(repository, %{"purpose" => "Changed saved context"})
      )

    refresh_company(view, "Catalogue changed")
    assert {:blocked, _} = company_assigns(view).plan_preflight
    assert has_element?(view, "#company-plan-build[disabled]")
    refute has_element?(view, "#company-guide-next[phx-value-section=build]")
    view |> form("#company-plan-build-form") |> render_submit()
    assert has_element?(view, "#company-error")
    assert {:ok, []} = Harnesses.list_artifacts()
    assert {:ok, %{"status" => "approved"}} = Company.get_plan(approved["id"])
  end

  test "loader failure clears previous preflight and shows unavailable instead of zero", %{
    conn: conn
  } do
    fixture = evidence_fixture()
    {_profile, repository, project} = saved_company(fixture)
    {:ok, plan} = Company.create_plan(domain_plan(fixture, repository, project))
    {:ok, plan} = Company.decide_plan(plan["id"], plan_decision(plan))
    {:ok, view, _} = live(conn, "/")
    view |> element("#nav-company") |> render_click()
    select_plan(view, plan)
    assert company_assigns(view).plan_preflight == :eligible

    Repo.query!("ALTER TABLE evidence_claims RENAME TO company_web_unavailable_claims")

    try do
      refresh_company(view, "Storage unavailable")
      assert has_element?(view, "#company-claim-review-count", "Unavailable")
      assert company_assigns(view).claim_review_count == nil
      assert company_assigns(view).plan_preflight == :none
      assert has_element?(view, "#company-plan-build[disabled]")
      refute has_element?(view, "#company-guide-next[phx-value-section=build]")
      assert Process.alive?(view.pid)
    after
      Repo.query!("ALTER TABLE company_web_unavailable_claims RENAME TO evidence_claims")
    end
  end

  test "catalogue text checkboxes and plan milestones survive disclosure tabs refresh and failure",
       %{conn: conn} do
    fixture = evidence_fixture()
    {_profile, repository, project} = saved_company(fixture)
    {:ok, view, _} = live(conn, "/")
    view |> element("#nav-company") |> render_click()

    view
    |> form("#company-profile-form",
      profile: %{name: "Unsaved company", source_ids: [fixture.source["id"]]}
    )
    |> render_change()

    view |> element("#company-repository-edit-#{repository["id"]}") |> render_click()

    view
    |> form("#company-repository-form", repository: %{purpose: "Unsaved purpose"})
    |> render_change()

    view |> element("#company-project-edit-#{project["id"]}") |> render_click()

    view
    |> form("#company-project-form",
      project: %{
        description: "Unsaved project",
        source_ids: [fixture.source["id"]],
        repository_ids: [repository["id"]]
      }
    )
    |> render_change()

    input = plan_form(fixture, repository, project)
    view |> form("#company-plan-form", plan: %{project_id: project["id"]}) |> render_change()
    view |> form("#company-plan-form", plan: input) |> render_change()
    view |> element("#company-milestone-add") |> render_click()

    view
    |> form("#company-plan-form",
      plan:
        Map.put(input, "milestones", %{
          "0" => milestone("review", "Unsaved milestone", fixture.goal["id"], [])
        })
    )
    |> render_change()

    before = company_assigns(view)
    view |> element("#company-toggle-project") |> render_click()
    view |> element("#nav-evidence") |> render_click()
    refresh_company(view, "Ordinary parent reload")
    view |> element("#nav-company") |> render_click()
    after_refresh = company_assigns(view)
    assert after_refresh.company_refresh_token > before.company_refresh_token
    assert after_refresh.company_reset_token == before.company_reset_token + 1
    refute after_refresh.company_event_generation == before.company_event_generation

    for key <-
          ~w(profile_draft repository_draft project_draft plan_draft repository_edit project_edit)a do
      assert after_refresh[key] == before[key]
    end

    assert has_element?(view, "#company-profile-name[value='Unsaved company']")
    assert has_element?(view, "#company-project-sources-#{fixture.source["id"]}[checked]")
    assert has_element?(view, "#company-plan-claims-#{fixture.claim["id"]}[checked]")
    assert has_element?(view, "#company-milestone-0-title[value='Unsaved milestone']")
    view |> form("#company-profile-form", profile: %{name: ""}) |> render_submit()
    assert has_element?(view, "#company-profile-error[tabindex='-1']")
    assert company_assigns(view).profile_draft["name"] == ""
    assert company_assigns(view).plan_draft == before.plan_draft
    assert_push_event(view, "company-focus", %{id: "company-profile-error"})
  end

  test "dirty record switching is refused and catalogue hashes stay pinned through tampered metadata",
       %{conn: conn} do
    fixture = evidence_fixture()
    {_profile, repository, _project} = saved_company(fixture)

    {:ok, other} =
      Company.create_repository(
        repository_form("example/other", "Other", [])
        |> Map.drop(~w(capabilities_text interfaces_text examples_text))
        |> Map.merge(%{"capabilities" => [], "interfaces" => [], "examples" => []})
      )

    {:ok, view, _} = live(conn, "/")
    view |> element("#nav-company") |> render_click()
    view |> element("#company-repository-edit-#{repository["id"]}") |> render_click()

    view
    |> form("#company-repository-form")
    |> render_change(%{
      "repository" => %{"purpose" => "Keep this draft", "_unused_dependency_ids" => [""]}
    })

    view |> element("#company-repository-edit-#{other["id"]}") |> render_click()
    assert has_element?(view, "#company-repository-error")
    assert company_assigns(view).repository_edit["id"] == repository["id"]
    assert company_assigns(view).repository_draft["purpose"] == "Keep this draft"
    view |> element("#company-repository-new") |> render_click()
    assert company_assigns(view).repository_edit["id"] == repository["id"]

    {:ok, changed} =
      Company.update_repository(
        repository["id"],
        replacement(repository, %{"purpose" => "Concurrent saved purpose"})
      )

    refresh_company(view, "Concurrent catalogue edit")
    assert has_element?(view, "#company-repository-hash[value='#{repository["content_hash"]}']")

    view
    |> form("#company-repository-form")
    |> render_submit(%{
      "repository" => %{
        "expected_content_hash" => changed["content_hash"],
        "_unused_expected_content_hash" => "",
        "purpose" => "Cannot overwrite concurrent context"
      }
    })

    assert has_element?(view, "#company-repository-error")
    assert {:ok, repositories} = Company.list_repositories()

    assert Enum.find(repositories, &(&1["id"] == repository["id"]))["payload"]["purpose"] ==
             "Concurrent saved purpose"

    view
    |> form("#company-repository-form")
    |> render_change(%{"repository" => %{"_unused_purpose" => ["tampered"]}})

    assert has_element?(view, "#company-repository-error")
    assert Process.alive?(view.pid)
    view |> element("#company-repository-discard") |> render_click()
    view |> element("#company-repository-edit-#{other["id"]}") |> render_click()
    assert company_assigns(view).repository_edit["id"] == other["id"]
  end

  test "source purge clears every private company cache and notifies a hidden sibling", %{
    conn: conn
  } do
    fixture = evidence_fixture()
    {_profile, repository, project} = saved_company(fixture)
    {:ok, plan} = Company.create_plan(domain_plan(fixture, repository, project))
    {:ok, plan} = Company.decide_plan(plan["id"], plan_decision(plan))
    {:ok, _comparison_artifact} = Harnesses.build(%{"name" => "synthetic-comparison"})
    {:ok, first, _} = live(conn, "/")
    {:ok, sibling, _} = live(conn, "/")
    populate_company_cache(first, fixture, repository, project, plan)
    populate_company_cache(sibling, fixture, repository, project, plan)

    captured =
      Map.new(
        [first, sibling],
        &{&1.pid, capture_company_forms(&1, fixture, repository, project)}
      )

    first |> element("#nav-privacy") |> render_click()
    sibling |> element("#nav-evidence") |> render_click()

    first
    |> form("#purge-source-form", privacy: %{id: fixture.source["id"], confirmation: "wrong"})
    |> render_submit()

    assert company_assigns(first).company_reset_token == 1
    assert company_assigns(first).plan_draft["name"] == "PRIVATE_DRAFT_CANARY"

    first
    |> form("#purge-source-form",
      privacy: %{id: fixture.source["id"], confirmation: fixture.source["id"]}
    )
    |> render_submit()

    for view <- [first, sibling] do
      assert has_element?(view, "#company-cache-2")
      assert_cache_cleared(company_assigns(view))
      refute render(view) =~ "PRIVATE_DRAFT_CANARY"
      assert_captured_generation_rotated(view, captured[view.pid])
      assert_old_envelopes_rejected(view, captured[view.pid])
    end

    assert {:error, :not_found} = Company.get_plan(plan["id"])
  end

  test "workspace purge clears mounted catalogue records in the initiating and sibling views", %{
    conn: conn
  } do
    fixture = evidence_fixture()
    {_profile, repository, project} = saved_company(fixture)
    {:ok, first, _} = live(conn, "/")
    {:ok, sibling, _} = live(conn, "/")
    first |> element("#nav-company") |> render_click()
    sibling |> element("#nav-company") |> render_click()

    for view <- [first, sibling] do
      view
      |> form("#company-profile-form", profile: %{name: "PRIVATE_DRAFT_CANARY"})
      |> render_change()
    end

    captured =
      Map.new(
        [first, sibling],
        &{&1.pid, capture_company_forms(&1, fixture, repository, project)}
      )

    first |> element("#nav-privacy") |> render_click()

    first
    |> form("#purge-workspace-form", privacy: %{confirmation: Workspaces.current_id()})
    |> render_submit()

    for view <- [first, sibling] do
      state = company_assigns(view)
      assert state.company_reset_token == if(view.pid == first.pid, do: 2, else: 1)
      assert state.profile == nil
      assert state.repositories == []
      assert state.projects == []
      assert_cache_cleared(state)
      refute render(view) =~ repository["id"]
      refute render(view) =~ project["id"]
      assert_captured_generation_rotated(view, captured[view.pid])
      assert_old_envelopes_rejected(view, captured[view.pid])
    end
  end

  @tag :committed
  test "backup preserves drafts while quarantined restore resets both tabs without switching authority",
       %{
         conn: conn,
         root: root
       } do
    fixture = evidence_fixture()
    {_profile, repository, project} = saved_company(fixture)
    {:ok, plan} = Company.create_plan(domain_plan(fixture, repository, project))
    {:ok, plan} = Company.decide_plan(plan["id"], plan_decision(plan))
    active_workspace = Workspaces.current_id()
    {:ok, first, _} = live(conn, "/")
    {:ok, sibling, _} = live(conn, "/")

    for view <- [first, sibling] do
      view |> element("#nav-company") |> render_click()
      select_plan(view, plan)

      view
      |> form("#company-profile-form", profile: %{name: "PRIVATE_DRAFT_CANARY"})
      |> render_change()
    end

    captured =
      Map.new(
        [first, sibling],
        &{&1.pid, capture_company_forms(&1, fixture, repository, project)}
      )

    first |> element("#nav-privacy") |> render_click()
    first |> form("#backup-form", privacy: %{target: root <> "-backup"}) |> render_submit()
    assert has_element?(first, "#privacy-result", root <> "-backup")

    for view <- [first, sibling] do
      assert company_assigns(view).company_reset_token ==
               if(view.pid == first.pid, do: 1, else: 0)

      assert company_assigns(view).profile_draft["name"] == "PRIVATE_DRAFT_CANARY"
    end

    first
    |> form("#restore-form", privacy: %{backup: root <> "-backup", target: root <> "-restored"})
    |> render_submit()

    assert has_element?(first, "#privacy-result", "quarantined")
    assert has_element?(first, "#privacy-result", "approvals_restored")

    for view <- [first, sibling] do
      state = company_assigns(view)
      assert state.company_reset_token == if(view.pid == first.pid, do: 2, else: 1)
      assert_cache_cleared(state)
      assert state.profile["payload"]["name"] == "Synthetic company"
      assert_captured_generation_rotated(view, captured[view.pid])
      assert_old_envelopes_rejected(view, captured[view.pid])
    end

    assert Workspaces.current_id() == active_workspace
    assert {:ok, %{"status" => "approved"}} = Company.get_plan(plan["id"])
    assert :sys.get_state(first.pid).socket.assigns.privacy_result["approvals_restored"] == false
    restored = root <> "-restored"
    restore_metadata = restored |> Path.join("restore.json") |> File.read!() |> Jason.decode!()
    assert restore_metadata["state"] == "quarantined"
    refute restore_metadata["new_workspace_id"] == active_workspace
  end

  # These assertions inspect private component assigns because hidden markup cannot
  # demonstrate that exact plan authority and lookup caches have been forgotten.
  defp company_assigns(view) do
    render(view)
    %{components: {components, _, _}} = :sys.get_state(view.pid)

    {_, "company-builder", assigns, _, _} =
      Enum.find_value(components, fn {_cid, entry} ->
        if elem(entry, 0) == HarnessForgeWeb.CompanyPanel, do: entry
      end)

    assigns
  end

  # Capture fresh metadata only when constructing a new event. The replay helper
  # below sends its stored envelope unchanged, including intentionally stale data.
  defp current_company_envelope(view, payload) do
    generation = company_assigns(view).company_event_generation

    assert has_element?(
             view,
             "#company-profile-form input[name=company_event_generation][value='#{generation}']"
           )

    Map.put(payload, "company_event_generation", generation)
  end

  defp replay_company_event(view, event, captured_envelope),
    do: view |> with_target("#company-panel") |> render_hook(event, captured_envelope)

  defp capture_company_forms(view, fixture, repository, project) do
    {:ok, profile} = Company.get_profile()

    profile_input = %{
      "name" => "REPLAY_CANARY",
      "expected_content_hash" => profile["content_hash"]
    }

    repository_input = repository_form("example/replayed", "REPLAY_CANARY", [])

    project_input = %{
      "name" => "REPLAY_CANARY",
      "repository_ids" => [repository["id"]],
      "source_ids" => [],
      "goal_ids" => []
    }

    plan_input = plan_form(fixture, repository, project) |> Map.put("name", "REPLAY_CANARY")

    for {event, payload} <- [
          {"company_profile_change", %{"profile" => profile_input}},
          {"company_profile_save", %{"profile" => profile_input}},
          {"company_repository_change", %{"repository" => repository_input}},
          {"company_repository_save", %{"repository" => repository_input}},
          {"company_project_change", %{"project" => project_input}},
          {"company_project_save", %{"project" => project_input}},
          {"company_plan_change", %{"plan" => plan_input}},
          {"company_plan_create", %{"plan" => plan_input}}
        ],
        do: {event, current_company_envelope(view, payload)}
  end

  defp capture_company_clicks(view, repository, project, approved, proposed) do
    for {event, payload} <- [
          {"company_section_toggle", %{"section" => "repository"}},
          {"company_guide_open", %{"section" => "plan"}},
          {"company_guide_project_change", %{"guide" => %{"project_id" => project["id"]}}},
          {"company_draft_discard", %{"form" => "profile"}},
          {"company_repository_new", %{}},
          {"company_repository_edit", %{"id" => repository["id"]}},
          {"company_project_new", %{}},
          {"company_project_edit", %{"id" => project["id"]}},
          {"company_plan_select", %{"id" => proposed["id"]}},
          {"company_plan_successor", %{"id" => approved["id"]}},
          {"company_milestone_add", %{}},
          {"company_milestone_remove", %{"index" => "0"}},
          {"company_plan_decide",
           %{"plan_decision" => Map.put(plan_decision(proposed), "id", proposed["id"])}},
          {"company_plan_build",
           %{
             "plan_build" => %{
               "id" => approved["id"],
               "expected_revision_hash" => approved["revision_hash"]
             }
           }},
          {"company_navigate", %{"tab" => "evidence"}},
          {"company_capability_search", %{"capability" => %{"query" => "REPLAY_CANARY"}}},
          {"company_consumers", %{"id" => repository["id"]}}
        ],
        do: {event, current_company_envelope(view, payload)}
  end

  defp company_record_snapshot do
    %{
      profile: Company.get_profile(),
      repositories: Company.list_repositories(),
      projects: Company.list_projects(),
      plans: Company.list_plans(),
      artifacts: Harnesses.list_artifacts(),
      audit: HarnessForge.Audit.list_events()
    }
  end

  defp assert_old_envelopes_rejected(view, captured) do
    state = company_assigns(view) |> Map.drop([:company_notice, :__changed__])
    records = company_record_snapshot()
    tab = :sys.get_state(view.pid).socket.assigns.tab

    for {event, unchanged_envelope} <- captured do
      replay_company_event(view, event, unchanged_envelope)

      assert company_assigns(view) |> Map.drop([:company_notice, :__changed__]) == state,
             "rejected #{event} changed private Company state"

      assert company_record_snapshot() == records, "rejected #{event} wrote workspace records"
      assert :sys.get_state(view.pid).socket.assigns.tab == tab

      assert has_element?(
               view,
               "#company-notice",
               "This Company view changed. Use the refreshed controls before retrying."
             )

      refute render(view) =~ "REPLAY_CANARY"
    end
  end

  defp assert_captured_generation_rotated(view, [{_, first} | _] = captured) do
    old = first["company_event_generation"]
    assert old =~ ~r/\A[0-9a-f]{32}\z/

    assert Enum.all?(captured, fn {_, envelope} -> envelope["company_event_generation"] == old end)

    refute company_assigns(view).company_event_generation == old
  end

  defp select_plan(view, plan),
    do: view |> element("#company-plan-select-#{plan["id"]}") |> render_click()

  defp refresh_company(view, summary) do
    send(view.pid, {:company_changed, summary})
    render(view)
  end

  defp saved_company(fixture, opts \\ []) do
    {:ok, profile} = Company.save_profile(%{"name" => "Synthetic company"})

    {:ok, repository} =
      Company.create_repository(%{
        "identity" => "example/payments",
        "name" => "Payments",
        "purpose" => "Synthetic service",
        "owner" => "Platform",
        "capabilities" => ["Payments authorization"],
        "interfaces" => [],
        "examples" => [],
        "dependency_ids" => [],
        "version_strategy" => "Semantic versions"
      })

    {:ok, project} =
      Company.create_project(%{
        "name" => "Checkout project",
        "repository_ids" => [repository["id"]],
        "source_ids" => Keyword.get(opts, :source_ids, [fixture.source["id"]]),
        "goal_ids" => [fixture.goal["id"]]
      })

    {profile, repository, project}
  end

  defp domain_plan(fixture, repository, project) do
    plan_form(fixture, repository, project)
    |> Map.put("claim_refs", [Map.take(fixture.claim, ~w(id revision_hash))])
    |> Map.put("execution", %{"max_turns" => 12, "timeout_seconds" => 600})
    |> Map.put("milestones", [])
  end

  defp plan_decision(plan, decision \\ "approve"),
    do: %{
      "decision" => decision,
      "actor" => Workspaces.operator(),
      "expected_revision_hash" => plan["revision_hash"]
    }

  defp replacement(record, changes),
    do:
      record["payload"]
      |> Map.merge(changes)
      |> Map.put("expected_content_hash", record["content_hash"])

  defp populate_company_cache(view, fixture, repository, project, plan) do
    view |> element("#nav-company") |> render_click()
    select_plan(view, plan)
    view |> form("#company-plan-build-form") |> render_submit()
    artifact = company_assigns(view).built_artifact

    view
    |> form("#company-diff-form",
      company_diff: %{left: artifact["digest"], right: artifact["digest"]}
    )
    |> render_submit()

    view |> form("#company-capability-form", capability: %{query: "Payments"}) |> render_submit()
    view |> element("#company-consumers-#{repository["id"]}") |> render_click()
    view |> element("#company-repository-edit-#{repository["id"]}") |> render_click()
    view |> element("#company-project-edit-#{project["id"]}") |> render_click()

    view
    |> form("#company-profile-form", profile: %{name: "PRIVATE_DRAFT_CANARY"})
    |> render_change()

    view
    |> form("#company-repository-form", repository: %{purpose: "PRIVATE_DRAFT_CANARY"})
    |> render_change()

    view
    |> form("#company-project-form", project: %{description: "PRIVATE_DRAFT_CANARY"})
    |> render_change()

    view |> form("#company-plan-form", plan: %{project_id: project["id"]}) |> render_change()

    view
    |> form("#company-plan-form",
      plan: Map.put(plan_form(fixture, repository, project), "name", "PRIVATE_DRAFT_CANARY")
    )
    |> render_change()

    state = company_assigns(view)
    assert state.built_artifact != nil
    assert state.package_diff != nil
    assert state.capability_results != nil
    assert state.consumer_results != nil
    assert state.selected_plan != nil
  end

  defp assert_cache_cleared(state) do
    for key <-
          ~w(profile_draft repository_draft project_draft repository_edit project_edit selected_plan built_artifact package_diff capability_results consumer_results consumer_repository guide_project_id form_error company_error company_notice)a do
      assert state[key] == nil, "cached #{key} survived privacy reset"
    end

    assert state.plan_draft["name"] == ""
    assert state.plan_preflight == :none
    assert state.plan_preflight_key == nil
    assert state.capability_query == ""
    assert state.open_sections == MapSet.new()
  end

  defp company_forms(view, fixture) do
    view
    |> form("#company-profile-form",
      profile: %{name: "Synthetic company", description: "Explicit local context"}
    )
    |> render_submit()

    {:ok, profile} = Company.get_profile()

    view
    |> form("#company-repository-form",
      repository: repository_form("example/payments", "Payments", [])
    )
    |> render_submit()

    {:ok, [repository]} = Company.list_repositories()

    view
    |> form("#company-project-form",
      project: %{
        name: "Checkout project",
        description: "Deliberate scope",
        repository_ids: [repository["id"]],
        source_ids: [fixture.source["id"]],
        goal_ids: [fixture.goal["id"]]
      }
    )
    |> render_submit()

    {:ok, [project]} = Company.list_projects()
    {profile, repository, project}
  end

  defp repository_form(identity, name, dependencies),
    do: %{
      "identity" => identity,
      "name" => name,
      "purpose" => "Synthetic payment service",
      "owner" => "Platform",
      "capabilities_text" => "Payments authorization\nRefund handling",
      "interfaces_text" => "HTTP API",
      "version_strategy" => "Semantic versions",
      "examples_text" => "Checkout calls this service",
      "dependency_ids" => dependencies
    }

  defp plan_form(fixture, repository, project),
    do: %{
      "name" => "company-harness",
      "package_version" => "0.1.0",
      "project_id" => project["id"],
      "repository_ids" => [repository["id"]],
      "claim_refs" => [fixture.claim["id"] <> ":" <> fixture.claim["revision_hash"]],
      "goal_ids" => [fixture.goal["id"]],
      "template_ids" => ["reviewed-change-v1"],
      "runtime" => "opencode",
      "runtime_version" => "unqualified",
      "execution" => %{"max_turns" => "12", "timeout_seconds" => "600"}
    }

  defp milestone(id, title, goal, dependencies),
    do: %{
      "id" => id,
      "title" => title,
      "goal_ids" => [goal],
      "depends_on" => dependencies,
      "acceptance" => "The recorded checks pass",
      "evaluation_method" => "Review test evidence",
      "target_version" => "0.2.0"
    }

  defp evidence_fixture do
    directory = Path.join(File.cwd!(), ".company-web-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    {:ok, connection} =
      Evidence.connect(%{
        "name" => "Synthetic public company fixture",
        "provider" => "local",
        "directory" => directory
      })

    {:ok, source} =
      Evidence.import_markdown(connection["id"], %{
        "external_id" => "review.md",
        "title" => "Synthetic review guide",
        "body" => "Review every change and record the acceptance checks."
      })

    {:ok, citation} =
      Evidence.citation(
        source["latest_revision"]["id"],
        0,
        byte_size(source["latest_revision"]["body"])
      )

    {:ok, claim} =
      Evidence.create_claim(%{
        "text" => "Review each change before release.",
        "citations" => [citation]
      })

    {:ok, _} =
      Decisions.decide(claim["id"], %{
        "actor" => Workspaces.operator(),
        "decision" => "approve",
        "expected_revision_hash" => claim["revision_hash"]
      })

    {:ok, other} =
      Evidence.create_claim(%{"text" => "Record acceptance evidence.", "citations" => [citation]})

    {:ok, _} =
      Decisions.decide(other["id"], %{
        "actor" => Workspaces.operator(),
        "decision" => "approve",
        "expected_revision_hash" => other["revision_hash"]
      })

    {:ok, proposed} =
      Evidence.create_claim(%{
        "text" => "An undecided proposal stays proposed.",
        "citations" => [citation]
      })

    {:ok, goal} =
      Goals.add_goal(%{
        "title" => "Deliver a reviewed checkout",
        "owner" => "Maintainer",
        "acceptance" => "Recorded checks pass"
      })

    %{source: source, claim: claim, other: other, proposed: proposed, goal: goal}
  end
end
