defmodule HarnessForgeWeb.CompanyJourneyHandoffTest do
  use HarnessForgeWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias HarnessForge.{Company, Decisions, Evidence, Goals, Workspaces}
  alias HarnessForgeWeb.Company.Guide
  alias HarnessForgeWeb.Plugs.OperatorSession

  setup %{conn: conn} do
    previous_root = Application.fetch_env!(:harness_forge, :workspace_root)
    previous_id = Workspaces.current_id()
    id = Ecto.UUID.generate()
    root = Path.join(File.cwd!(), "tmp/company-handoff-#{id}")
    Enum.each(~w(artifacts runs tmp), &File.mkdir_p!(Path.join(root, &1)))
    Application.put_env(:harness_forge, :workspace_root, root)
    Application.put_env(:harness_forge, :workspace_id, id)

    on_exit(fn ->
      Application.put_env(:harness_forge, :workspace_root, previous_root)
      Application.put_env(:harness_forge, :workspace_id, previous_id)
      File.rm_rf!(root)
    end)

    conn = %{conn | host: "localhost", port: 4002}

    {:ok,
     conn: init_test_session(conn, %{"operator_auth" => OperatorSession.new_auth()}), root: root}
  end

  test "pure guide projection offers a v2 corpus claim with zero manual assignments" do
    # Projection fixture only: Evidence.approved_claims/0 remains the real authority,
    # and the Root-owned connected browser check covers real v2 corpus provenance.
    profile = %{
      "id" => "profile",
      "content_hash" => "profile-hash",
      "payload" => %{"name" => "Example"}
    }

    project = %{
      "id" => "project",
      "content_hash" => "project-hash",
      "payload" => %{
        "name" => "Checkout",
        "repository_ids" => ["repository"],
        "source_ids" => [],
        "goal_ids" => ["goal"]
      }
    }

    claim = %{
      "status" => "approved",
      "basis" => %{
        "kind" => "company_analysis",
        "version" => 2,
        "goal_id" => "goal",
        "context" => %{
          "project" => Map.take(project, ~w(id content_hash)),
          "profile" => Map.take(profile, ~w(id content_hash))
        }
      }
    }

    input = %{
      profile: profile,
      repositories: [%{"id" => "repository"}],
      projects: [project],
      guide_project_id: "project",
      sources: [],
      approved: [claim],
      company_load_error: false,
      data_errors: [],
      selected_plan: nil,
      plans: [],
      company_reset_token: 0,
      claim_review_count: 0,
      plan_preflight: :none,
      built_artifact: nil
    }

    projected = Guide.project(input)
    assert projected.source_count == 0
    assert projected.claim_count == 1
    assert projected.next.section == "plan"

    stale_claim = put_in(claim, ["basis", "context", "project", "content_hash"], "old-hash")
    stale = Guide.project(%{input | approved: [stale_claim]})
    assert stale.claim_count == 0
    assert stale.next.corpus
  end

  test "the saved guide keeps corpus next action ahead of optional steps and labels manual analysis",
       %{conn: conn, root: root} do
    fixture = saved_context(root, false)
    {:ok, view, _} = live(conn, "/?setup=company")

    html = render(view)
    {next_position, _} = :binary.match(html, "id=\"company-guide-next\"")
    {details_position, _} = :binary.match(html, "id=\"company-guide-details\"")
    assert next_position < details_position
    assert has_element?(view, "#company-guide-details summary#company-guide-details-toggle")
    assert has_element?(view, "#company-analysis-step", "Manual selected-source alternative")
    assert has_element?(view, "#company-guide-next[phx-click=company_corpus_open]")
    assert has_element?(view, "#company-guide-scope", fixture.project["payload"]["name"])
    assert has_element?(view, "#company-guide-details", fixture.project["id"])
    assert has_element?(view, "#company-guide-next", "Select corpus and goal")
  end

  test "a rejected name retains exact reviewed choices and correction creates a separately decided plan",
       %{conn: conn, root: root} do
    fixture = saved_context(root)
    {:ok, view, _} = live(conn, "/?setup=company")
    input = plan_form(fixture, "Checkout Harness")

    view
    |> form("#company-plan-form", plan: %{project_id: fixture.project["id"]})
    |> render_change()

    assert has_element?(view, "#company-plan-claims-#{fixture.claim["id"]}")
    assert has_element?(view, "#company-plan-name[maxlength='64']")
    assert has_element?(view, "#company-plan-name-help", "lowercase")

    view |> form("#company-plan-form", plan: Map.delete(input, "milestones")) |> render_change()
    view |> element("#company-milestone-add") |> render_click()
    view |> form("#company-plan-form", plan: input) |> render_change()
    view |> form("#company-plan-form", plan: input) |> render_submit()

    assert has_element?(view, "#company-plan-name-error[role=alert]", "lowercase")

    assert has_element?(
             view,
             "#company-plan-name[aria-invalid=true][aria-describedby='company-plan-name-help company-plan-name-error']"
           )

    assert_push_event(view, "company-focus", %{id: "company-plan-name"})
    refute has_element?(view, "#company-plan-error")
    assert {:ok, []} = Company.list_plans()

    retained = company_assigns(view).plan_draft

    retained_fields =
      ~w(name package_version project_id repository_ids claim_refs goal_ids template_ids runtime runtime_version execution)

    assert Map.take(retained, retained_fields) == Map.take(input, retained_fields)
    assert retained["milestones"] == [input["milestones"]["0"]]

    corrected = Map.put(input, "name", "checkout-harness")
    view |> form("#company-plan-form", plan: corrected) |> render_change()
    refute has_element?(view, "#company-plan-name-error")
    view |> form("#company-plan-form", plan: corrected) |> render_submit()

    assert {:ok, [plan]} = Company.list_plans()
    assert plan["status"] == "proposed"
    assert plan["payload"]["name"] == "checkout-harness"
    assert plan["payload"]["project_id"] == fixture.project["id"]
    assert plan["payload"]["repository_ids"] == [fixture.repository["id"]]
    assert plan["payload"]["claim_refs"] == [Map.take(fixture.claim, ~w(id revision_hash))]
    assert plan["payload"]["goal_ids"] == [fixture.goal["id"]]
    assert plan["payload"]["template_ids"] == ["reviewed-change-v1"]
    assert plan["payload"]["runtime"] == "opencode"
    assert plan["payload"]["runtime_version"] == "unqualified"
    assert plan["payload"]["execution"] == %{"max_turns" => 12, "timeout_seconds" => 600}
    assert plan["payload"]["milestones"] == [input["milestones"]["0"]]
    assert {:error, :plan_not_approved} = Company.build_inputs(plan["id"])
    assert has_element?(view, "#company-plan-decision-form")

    view |> form("#company-plan-decision-form") |> render_submit()
    assert {:ok, %{"status" => "approved"}} = Company.get_plan(plan["id"])
    assert {:ok, %{"status" => "approved"}} = Evidence.get_claim(fixture.claim["id"])
  end

  test "project switching clears dependent choices and an old generation cannot restore them",
       %{conn: conn, root: root} do
    fixture = saved_context(root)

    {:ok, other} =
      Company.create_project(%{
        "name" => "Other project",
        "repository_ids" => [fixture.repository["id"]],
        "goal_ids" => [fixture.goal["id"]],
        "source_ids" => []
      })

    {:ok, view, _} = live(conn, "/?setup=company")
    input = plan_form(fixture, "Checkout Harness")

    view
    |> form("#company-plan-form", plan: %{project_id: fixture.project["id"]})
    |> render_change()

    view |> form("#company-plan-form", plan: Map.delete(input, "milestones")) |> render_change()
    view |> element("#company-milestone-add") |> render_click()
    view |> form("#company-plan-form", plan: input) |> render_change()
    old_generation = company_assigns(view).company_event_generation

    view |> form("#company-plan-form", plan: %{project_id: other["id"]}) |> render_change()
    switched = company_assigns(view).plan_draft
    assert switched["project_id"] == other["id"]
    assert switched["repository_ids"] == []
    assert switched["claim_refs"] == []
    assert switched["goal_ids"] == []

    send(view.pid, :company_cache_reset)
    render(view)
    refute company_assigns(view).company_event_generation == old_generation
    current_draft = company_assigns(view).plan_draft

    view
    |> with_target("#company-panel")
    |> render_hook("company_plan_create", %{
      "company_event_generation" => old_generation,
      "plan" => input
    })

    assert company_assigns(view).plan_draft == current_draft
    assert {:ok, []} = Company.list_plans()
  end

  defp saved_context(root, approve_claim? \\ true) do
    directory = Path.join(root, "fixture")
    File.mkdir_p!(directory)

    {:ok, connection} =
      Evidence.connect(%{
        "name" => "Public checkout fixture",
        "provider" => "local",
        "directory" => directory
      })

    {:ok, source} =
      Evidence.import_markdown(connection["id"], %{
        "external_id" => "review.md",
        "title" => "Review policy",
        "body" => "Review every checkout change and record acceptance checks."
      })

    {:ok, citation} =
      Evidence.citation(
        source["latest_revision"]["id"],
        0,
        byte_size(source["latest_revision"]["body"])
      )

    {:ok, claim} =
      Evidence.create_claim(%{
        "text" => "Review changes before release.",
        "citations" => [citation]
      })

    if approve_claim? do
      {:ok, _} =
        Decisions.decide(claim["id"], %{
          "actor" => Workspaces.operator(),
          "decision" => "approve",
          "expected_revision_hash" => claim["revision_hash"]
        })
    end

    {:ok, goal} =
      Goals.add_goal(%{
        "title" => "Deliver reviewed checkout changes",
        "owner" => "Maintainer",
        "acceptance" => "Recorded review checks pass"
      })

    {:ok, profile} = Company.save_profile(%{"name" => "Synthetic company"})

    {:ok, repository} =
      Company.create_repository(%{
        "identity" => "example/checkout",
        "name" => "Checkout",
        "purpose" => "Synthetic checkout service",
        "owner" => "Maintainer",
        "capabilities" => ["Checkout"],
        "interfaces" => [],
        "examples" => [],
        "dependency_ids" => [],
        "version_strategy" => "Semantic versions"
      })

    {:ok, project} =
      Company.create_project(%{
        "name" => "Checkout project",
        "repository_ids" => [repository["id"]],
        "source_ids" => [source["id"]],
        "goal_ids" => [goal["id"]]
      })

    %{profile: profile, repository: repository, project: project, claim: claim, goal: goal}
  end

  defp plan_form(fixture, name) do
    %{
      "name" => name,
      "package_version" => "0.1.0",
      "project_id" => fixture.project["id"],
      "repository_ids" => [fixture.repository["id"]],
      "claim_refs" => [fixture.claim["id"] <> ":" <> fixture.claim["revision_hash"]],
      "goal_ids" => [fixture.goal["id"]],
      "template_ids" => ["reviewed-change-v1"],
      "runtime" => "opencode",
      "runtime_version" => "unqualified",
      "execution" => %{"max_turns" => "12", "timeout_seconds" => "600"},
      "milestones" => %{
        "0" => %{
          "id" => "review",
          "title" => "Review the checkout change",
          "goal_ids" => [fixture.goal["id"]],
          "depends_on" => [],
          "acceptance" => "Recorded checks pass",
          "evaluation_method" => "Review test evidence",
          "target_version" => "0.2.0"
        }
      }
    }
  end

  defp company_assigns(view) do
    render(view)
    %{components: {components, _, _}} = :sys.get_state(view.pid)

    {_, "company-builder", assigns, _, _} =
      Enum.find_value(components, fn {_cid, entry} ->
        if elem(entry, 0) == HarnessForgeWeb.CompanyPanel, do: entry
      end)

    assigns
  end
end
