defmodule HarnessForgeWeb.GoalClaimsTest do
  use HarnessForgeWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias HarnessForge.{Company, Evidence, Goals, Harnesses, Repo, Workspaces}
  alias HarnessForgeWeb.Plugs.OperatorSession

  setup %{conn: conn} do
    previous_root = Application.fetch_env!(:harness_forge, :workspace_root)
    previous_id = Workspaces.current_id()
    id = Ecto.UUID.generate()
    root = Path.join(File.cwd!(), "tmp/goal-web-#{id}")
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

  test "goal-only forms require exact rule and plan approvals, explicit goal selection, then build and export",
       %{conn: conn, root: root} do
    {:ok, view, _} = live(conn, "/?view=evidence")
    refute has_element?(view, "#propose-form")
    refute has_element?(view, "#propose-goal-form")
    view |> element("#goal-rule-save-goal") |> render_click()

    view
    |> form("#goal-form",
      goal: %{
        title: "Review releases",
        owner: "Platform",
        acceptance: "Every release records its checks"
      }
    )
    |> render_submit()

    assert {:ok, [goal]} = Goals.list_goals()
    assert {:ok, []} = Evidence.list_claims()
    view |> element("#nav-evidence") |> render_click()
    assert has_element?(view, "#propose-goal-form")
    refute has_element?(view, "#propose-form")
    assert has_element?(view, "select[id^=goal-claim-goal-] option[value=''][selected]")
    assert portal(view).goal_claim_draft == %{"goal_snapshot" => "", "text" => ""}
    refute render(view) =~ ~s(>Review releases</textarea>)

    captured = envelope(view, snapshot(goal), "Record a separate review before release.")
    propose(view, goal, "Record a separate review before release.")
    assert_push_event(view, "company-focus", %{id: "evidence-panel"})
    assert_cleared(view, captured)
    assert {:ok, [claim]} = Evidence.list_claims()
    assert claim["status"] == "proposed"
    assert claim["citations"] == []
    assert has_element?(view, "#claim-#{claim["id"]}", "Goal-based rule")
    assert has_element?(view, "#goal-origin-#{claim["id"]}", goal["title"])
    assert has_element?(view, "#goal-origin-#{claim["id"]}", goal["owner"])
    assert has_element?(view, "#goal-origin-#{claim["id"]}", goal["acceptance"])
    assert has_element?(view, "#goal-origin-details-#{claim["id"]}", Goals.content_hash(goal))
    assert has_element?(view, "#goal-origin-details-#{claim["id"]}", claim["revision_hash"])
    refute has_element?(view, "#claim-#{claim["id"]} details[id^=citation-]")

    render_click(view, "decide", %{
      "id" => claim["id"],
      "decision" => "approve",
      "revision" => String.duplicate("0", 64)
    })

    assert has_element?(view, "#error", "revision changed")
    assert {:ok, %{"status" => "proposed"}} = Evidence.get_claim(claim["id"])
    view |> element("#approve-#{claim["id"]}") |> render_click()
    assert {:ok, %{"status" => "approved"}} = Evidence.get_claim(claim["id"])

    view |> element("#nav-package") |> render_click()
    view |> form("#build-form") |> render_submit()
    assert has_element?(view, "#error", "Goal-based rules require an approved Company plan")
    assert {:ok, []} = Harnesses.list_artifacts()

    {repository, project} = company(goal)
    view |> element("#nav-company") |> render_click()
    view |> form("#company-plan-form", plan: %{project_id: project["id"]}) |> render_change()
    assert has_element?(view, "#company-plan-claims", "Goal-based rule")
    assert has_element?(view, "#company-plan-claims", goal["title"])
    assert has_element?(view, "#company-guide-next", "Propose a plan")
    refute has_element?(view, "#company-plan-goals input[checked]")
    input = plan_input(claim, repository, project)
    view |> form("#company-plan-form", plan: input) |> render_submit()
    assert has_element?(view, "#company-error", "Select the goal used by this approved claim")
    assert {:ok, []} = Company.list_plans()
    refute has_element?(view, "#company-plan-goals input[checked]")

    view
    |> form("#company-plan-form", plan: Map.put(input, "goal_ids", [goal["id"]]))
    |> render_submit()

    assert {:ok, [plan]} = Company.list_plans()
    assert plan["status"] == "proposed"
    assert has_element?(view, "#company-plan-review", "Goal-based rule")
    assert has_element?(view, "#company-plan-build[disabled]")
    view |> form("#company-plan-build-form") |> render_submit()
    assert has_element?(view, "#company-error", "Approve the exact displayed plan revision")
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
    view |> form("#company-plan-build-form") |> render_submit()
    assert has_element?(view, "#company-built-package", "goal-policy")
    assert {:ok, [artifact]} = Harnesses.list_artifacts()
    assert [%{"goal_id" => goal_id, "evidence" => []}] = artifact["spec"]["spec"]["rules"]
    assert goal_id == goal["id"]
    provenance = Jason.decode!(artifact["files"]["harnessforge.provenance.json"])
    assert [%{"goal_id" => ^goal_id, "evidence" => []}] = provenance["rules"]

    view |> element("#company-open-packages") |> render_click()
    target = Path.join(root, "exported-goal-policy")

    view
    |> form("[id^=package-export-form-][id$='#{artifact["digest"]}']", export: %{target: target})
    |> render_submit()

    assert has_element?(view, "[id^=package-export-result-][id$='#{artifact["digest"]}']", target)

    Enum.each(artifact["files"], fn {path, bytes} ->
      assert File.read!(Path.join(target, path)) == bytes
    end)
  end

  test "the sourced proposal stays separate with captured citation and no goal selection", %{
    conn: conn,
    root: root
  } do
    source = source(root)
    {:ok, view, _} = live(conn, "/?view=evidence")
    assert has_element?(view, "#propose-form")
    refute has_element?(view, "#propose-goal-form")

    view
    |> form("#propose-form",
      claim: %{
        source_snapshot: source["id"] <> ":" <> source["latest_revision"]["id"],
        text: "Keep the captured source rule."
      }
    )
    |> render_submit()

    assert {:ok, [claim]} = Evidence.list_claims()
    refute Map.has_key?(claim, "basis")
    assert [%{"revision_id" => revision}] = claim["citations"]
    assert revision == source["latest_revision"]["id"]
    assert has_element?(view, "#claim-#{claim["id"]}", "Sourced claim")
    assert has_element?(view, "#claim-#{claim["id"]} details[id^=citation-]", "Supporting source")
    refute has_element?(view, "#goal-origin-#{claim["id"]}")
  end

  test "forged goal versions and foreign goals refuse safely without proposing or leaking details",
       %{conn: conn} do
    goal = goal()
    {:ok, view, _} = live(conn, "/?view=evidence")
    previous_id = Workspaces.current_id()
    Application.put_env(:harness_forge, :workspace_id, Ecto.UUID.generate())
    foreign = goal("FOREIGN_GOAL_PRIVATE_CANARY")
    Application.put_env(:harness_forge, :workspace_id, previous_id)

    for snapshot <- [
          goal["id"] <> ":" <> String.duplicate("0", 64),
          foreign["id"] <> ":" <> Goals.content_hash(foreign),
          Ecto.UUID.generate() <> ":" <> String.duplicate("a", 64)
        ] do
      render_hook(view, "propose_goal", envelope(view, snapshot, "Must not be proposed"))
      assert has_element?(view, "#error", "saved goal is unavailable or has changed")
      assert {:ok, []} = Evidence.list_claims()
      refute render(view) =~ "FOREIGN_GOAL_PRIVATE_CANARY"
    end

    render_hook(view, "propose_goal", envelope(view, "", "Missing goal"))
    assert has_element?(view, "#error", "Choose a saved goal")
    assert {:ok, []} = Evidence.list_claims()
  end

  test "goal review escapes authored text and suppresses stale saved-goal details and approval",
       %{conn: conn} do
    goal = goal("<script>GOAL_CANARY</script>")
    {:ok, view, _} = live(conn, "/?view=evidence")
    propose(view, goal, "<script>RULE_CANARY</script>")
    assert {:ok, [claim]} = Evidence.list_claims()
    refute render(view) =~ "<script>GOAL_CANARY"
    refute render(view) =~ "<script>RULE_CANARY"
    assert has_element?(view, "#goal-origin-#{claim["id"]}", "GOAL_CANARY")

    # Adversarial database drift, not a supported goal-edit operation.
    Repo.query!("DROP TRIGGER immutable_workspace_goals_update")

    Repo.query!("UPDATE workspace_goals SET title = ? WHERE id = ?", [
      "CHANGED_GOAL_CANARY",
      goal["id"]
    ])

    send(view.pid, {:company_changed, "adversarial drift"})

    assert has_element?(
             view,
             "#goal-origin-#{claim["id"]}",
             "saved goal is unavailable or has changed"
           )

    refute has_element?(view, "#goal-origin-#{claim["id"]}", "CHANGED_GOAL_CANARY")
    assert has_element?(view, "#approve-#{claim["id"]}[disabled]")

    render_click(view, "decide", %{
      "id" => claim["id"],
      "decision" => "approve",
      "revision" => claim["revision_hash"]
    })

    assert has_element?(view, "#error", "saved goal is unavailable or has changed")
    assert {:ok, %{"status" => "proposed"}} = Evidence.get_claim(claim["id"])
  end

  test "rejected and superseded goal revisions are absent from approved Company choices", %{
    conn: conn
  } do
    goal = goal()
    {_, project} = company(goal)
    {:ok, view, _} = live(conn, "/?view=evidence")
    propose(view, goal, "Original goal rule")
    assert {:ok, [claim]} = Evidence.list_claims()
    view |> element("#approve-#{claim["id"]}") |> render_click()

    {:ok, successor} =
      Evidence.create_claim(%{
        "text" => "Replacement goal rule",
        "citations" => [],
        "basis" => claim["basis"],
        "supersedes_id" => claim["id"]
      })

    send(view.pid, {:company_changed, "new revision"})
    refute has_element?(view, "#approve-#{claim["id"]}")
    view |> element("#reject-#{successor["id"]}") |> render_click()
    view |> element("#nav-company") |> render_click()
    view |> form("#company-plan-form", plan: %{project_id: project["id"]}) |> render_change()
    refute has_element?(view, "#company-plan-claims", claim["text"])
    refute has_element?(view, "#company-plan-claims", successor["text"])
    assert has_element?(view, "#company-claims-empty")
  end

  test "source purge clears goal draft selection in both views and rejects captured change and submit envelopes",
       %{conn: conn, root: root} do
    goal = goal()
    source = source(root)
    {:ok, first, _} = live(conn, "/?view=evidence")
    {:ok, sibling, _} = live(conn, "/?view=evidence")
    assert has_element?(first, "#propose-form")
    assert has_element?(first, "#propose-goal-form")

    captured =
      Map.new([first, sibling], fn view ->
        input = envelope(view, snapshot(goal), "GOAL_DRAFT_PRIVATE_CANARY")
        render_hook(view, "goal_claim_change", input)
        assert portal(view).goal_claim_draft["goal_snapshot"] == snapshot(goal)
        {view.pid, input}
      end)

    first |> element("#nav-privacy") |> render_click()

    first
    |> form("#purge-source-form", privacy: %{id: source["id"], confirmation: source["id"]})
    |> render_submit()

    for view <- [first, sibling] do
      assert_cleared(view, captured[view.pid])

      for event <- ~w(goal_claim_change propose_goal) do
        render_hook(view, event, captured[view.pid])
        assert has_element?(view, "#error", "Use the refreshed controls")
        assert_cleared(view, captured[view.pid])
        assert {:ok, []} = Evidence.list_claims()
      end
    end

    assert {:ok, [^goal]} = Goals.list_goals()
  end

  test "workspace purge clears new goal state and old queued proposals cannot restore it", %{
    conn: conn
  } do
    goal = goal()
    {:ok, first, _} = live(conn, "/?view=evidence")
    {:ok, sibling, _} = live(conn, "/?view=evidence")

    captured =
      Map.new([first, sibling], fn view ->
        input = envelope(view, snapshot(goal), "GOAL_DRAFT_PRIVATE_CANARY")
        render_hook(view, "goal_claim_change", input)
        {view.pid, input}
      end)

    first |> element("#nav-privacy") |> render_click()

    first
    |> form("#purge-workspace-form", privacy: %{confirmation: Workspaces.current_id()})
    |> render_submit()

    for view <- [first, sibling] do
      assert_cleared(view, captured[view.pid])
      assert portal(view).goals == []
      assert portal(view).goal_claim_reviews == %{}
      render_hook(view, "propose_goal", captured[view.pid])
      assert has_element?(view, "#error", "Use the refreshed controls")
    end

    assert {:ok, []} = Goals.list_goals()
    assert {:ok, []} = Evidence.list_claims()
  end

  test "fresh remount forgets goal drafts and refuses the prior form generation", %{conn: conn} do
    goal = goal()
    {:ok, first, _} = live(conn, "/?view=evidence")
    captured = envelope(first, snapshot(goal), "GOAL_DRAFT_PRIVATE_CANARY")
    render_hook(first, "goal_claim_change", captured)
    {:ok, fresh, _} = live(conn, "/?view=evidence")
    assert_cleared(fresh, captured)
    assert has_element?(fresh, "#propose-goal-form[phx-auto-recover=ignore]")
    render_hook(fresh, "propose_goal", captured)
    assert has_element?(fresh, "#error", "Use the refreshed controls")
    assert {:ok, []} = Evidence.list_claims()
    view_snapshot = snapshot(goal)
    render_hook(fresh, "goal_claim_change", envelope(fresh, view_snapshot, "Fresh draft"))
    assert portal(fresh).goal_claim_draft["text"] == "Fresh draft"
  end

  test "lock revokes a queued goal proposal and newly unlocked view has no prior goal state", %{
    conn: conn
  } do
    goal = goal()
    {:ok, view, _} = live(conn, "/?view=evidence")
    captured = envelope(view, snapshot(goal), "GOAL_DRAFT_PRIVATE_CANARY")
    render_hook(view, "goal_claim_change", captured)
    response = conn |> put_req_header("origin", "http://localhost:4002") |> delete("/session")
    assert redirected_to(response) == "/login"
    assert_redirect(view, "/login")
    assert {:ok, []} = Evidence.list_claims()
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, "/?view=evidence")
    fresh_conn = init_test_session(conn, %{"operator_auth" => OperatorSession.new_auth()})
    {:ok, fresh, _} = live(fresh_conn, "/")
    assert_cleared(fresh, captured)
    render_hook(fresh, "propose_goal", captured)
    assert has_element?(fresh, "#error", "Use the refreshed controls")
    assert {:ok, []} = Evidence.list_claims()
  end

  test "event authentication terminates the private goal view before a stale session can submit",
       %{
         conn: conn
       } do
    goal = goal()
    {:ok, view, _} = live(conn, "/?view=evidence")
    captured = envelope(view, snapshot(goal), "GOAL_DRAFT_PRIVATE_CANARY")
    render_hook(view, "goal_claim_change", captured)
    previous = :sys.get_state(Workspaces)
    :sys.replace_state(Workspaces, &%{&1 | epoch: "revoked-goal-session"})
    on_exit(fn -> :sys.replace_state(Workspaces, fn _ -> previous end) end)
    assert {:error, {:redirect, %{to: "/login"}}} = render_hook(view, "propose_goal", captured)
    refute Process.alive?(view.pid)
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, "/?view=evidence")
    assert {:ok, []} = Evidence.list_claims()
  end

  defp portal(view) do
    render(view)
    :sys.get_state(view.pid).socket.assigns
  end

  defp assert_cleared(view, captured) do
    state = portal(view)
    assert state.goal_claim_draft == %{"goal_snapshot" => "", "text" => ""}
    refute state.goal_claim_generation == captured["goal_claim_generation"]
    refute render(view) =~ "GOAL_DRAFT_PRIVATE_CANARY"

    if state.tab == "evidence" && state.goals != [] do
      fresh = state.goal_claim_generation
      old = captured["goal_claim_generation"]
      assert has_element?(view, "#goal-claim-goal-#{fresh} option[value=''][selected]")
      assert has_element?(view, "#goal-claim-text-#{fresh}")
      assert has_element?(view, "label[for='goal-claim-goal-#{fresh}']", "Saved goal")
      assert has_element?(view, "label[for='goal-claim-text-#{fresh}']", "Rule to review")
      refute has_element?(view, "#goal-claim-goal-#{old}")
      refute has_element?(view, "#goal-claim-text-#{old}")
    end
  end

  defp envelope(view, selected, text),
    do: %{
      "goal_claim_generation" => portal(view).goal_claim_generation,
      "goal_claim" => %{"goal_snapshot" => selected, "text" => text}
    }

  defp snapshot(goal), do: goal["id"] <> ":" <> Goals.content_hash(goal)

  defp propose(view, goal, text),
    do:
      view
      |> form("#propose-goal-form", goal_claim: %{goal_snapshot: snapshot(goal), text: text})
      |> render_submit()

  defp goal(title \\ "Review releases") do
    {:ok, goal} =
      Goals.add_goal(%{
        "title" => title,
        "owner" => "Platform",
        "acceptance" => "Every release records its checks"
      })

    goal
  end

  defp source(root) do
    {:ok, connection} =
      Evidence.connect(%{
        "name" => "Synthetic local source",
        "provider" => "local",
        "directory" => root
      })

    {:ok, source} =
      Evidence.import_markdown(connection["id"], %{
        "external_id" => "guide.md",
        "title" => "Synthetic guide",
        "body" => "Review each captured source before approval."
      })

    source
  end

  defp company(goal) do
    {:ok, _} = Company.save_profile(%{"name" => "Synthetic company"})

    {:ok, repository} =
      Company.create_repository(%{
        "identity" => "synthetic/service",
        "name" => "Service",
        "purpose" => "Synthetic fixture",
        "owner" => "Platform"
      })

    {:ok, project} =
      Company.create_project(%{
        "name" => "Release project",
        "repository_ids" => [repository["id"]],
        "source_ids" => [],
        "goal_ids" => [goal["id"]]
      })

    {repository, project}
  end

  defp plan_input(claim, repository, project) do
    %{
      "name" => "goal-policy",
      "package_version" => "0.1.0",
      "project_id" => project["id"],
      "repository_ids" => [repository["id"]],
      "claim_refs" => [claim["id"] <> ":" <> claim["revision_hash"]],
      "goal_ids" => [],
      "template_ids" => ["reviewed-change-v1"],
      "runtime" => "opencode",
      "runtime_version" => "unqualified",
      "execution" => %{"max_turns" => "12", "timeout_seconds" => "600"}
    }
  end
end
