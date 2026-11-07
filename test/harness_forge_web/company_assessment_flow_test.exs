defmodule HarnessForgeWeb.CompanyAssessmentFlowTest do
  use HarnessForgeWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias HarnessForge.{Company, Contracts, Goals, Repo, Workspaces}
  alias HarnessForge.Company.{Assessment, Assessments, TaskRubric}
  alias HarnessForge.CompanyAssessmentFixture, as: Fixture
  alias HarnessForge.Evidence.Store
  alias HarnessForgeWeb.Plugs.OperatorSession

  setup %{conn: conn} do
    previous =
      Map.new([:workspace_root, :workspace_id], &{&1, Application.get_env(:harness_forge, &1)})

    root = Path.join(File.cwd!(), "tmp/assessment-flow-" <> Ecto.UUID.generate())
    File.mkdir_p!(root)
    Application.put_env(:harness_forge, :workspace_root, root)
    Application.put_env(:harness_forge, :workspace_id, Ecto.UUID.generate())
    fixture = Fixture.create!(root)

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> Application.put_env(:harness_forge, key, value) end)
      File.rm_rf!(root)
    end)

    conn = %{conn | host: "localhost", port: 4002}

    %{
      conn: init_test_session(conn, %{"operator_auth" => OperatorSession.new_auth()}),
      f: fixture,
      root: root
    }
  end

  test "actual built continuation, explicit goal, four frozen obligations and one exact receipt",
       c do
    view = scoped(c)
    refute has_element?(view, "#company-assessment-results-form")
    assert has_element?(view, "#company-assessment-context", c.f.goal["acceptance"])
    assert has_element?(view, "#company-assessment-context", c.f.outside_goal["title"])

    assert has_element?(
             view,
             "#company-assessment-context",
             c.f.oracle["edited_guidance_expected_in_export"]
           )

    before = artifact_bytes(c.root)
    freeze(view, c.f)
    assert {:ok, [rubric]} = Assessments.list_rubrics()

    assert Enum.map(rubric["payload"]["obligations"], & &1["id"]) ==
             ~w(communication-owner goal-readiness named-review rollback-ready)

    refute has_element?(view, "#company-assessment-results-form")
    view |> element("#company-assessment-another-attempt") |> render_click(%{"value" => ""})
    assert attr(view, "#company-assessment-judgment option[selected]", "value") == ""
    assert attr(view, "#company-assessment-critical-status option[selected]", "value") == ""
    payload = record_payload(view, c.f)
    render_submit(view, "assessment_record", payload)
    assert has_element?(view, "#company-assessment-receipt", "Owner-reported assessment")
    assert {:ok, [receipt]} = Assessments.list_assessments(rubric["id"])
    assert receipt["payload"]["judgment"] == "accepted"
    assert receipt["applicability"]["status"] == "current"

    assert Enum.map(receipt["payload"]["results"], & &1["obligation_id"]) ==
             ~w(communication-owner goal-readiness named-review rollback-ready)

    assert Repo.aggregate(Store.scoped(Assessment), :count) == 1
    render_submit(view, "assessment_record", payload)
    assert {:ok, [^receipt]} = Assessments.list_assessments(rubric["id"])
    assert artifact_bytes(c.root) == before
    assert has_element?(view, "#company-assessment-receipt", "not independently verified")
  end

  test "browser button metadata preserves strict form and unexpected-field refusal", c do
    view = scoped(c)

    binding =
      Map.take(c.f.freeze_attrs, ~w(plan_id expected_plan_revision_hash artifact_digest))

    for value <- ["unexpected", nil, 0, [], %{}] do
      render_click(
        view,
        "company_assessment_open",
        envelope(view, Map.put(binding, "value", value))
      )

      assert has_element?(view, "#company-assessment-error")
      refute has_element?(view, "#company-assessment-scope-form")
    end

    render_click(
      view,
      "company_assessment_open",
      envelope(view, Map.merge(binding, %{"value" => "", "extra" => "unexpected"}))
    )

    assert has_element?(view, "#company-assessment-error")
    refute has_element?(view, "#company-assessment-scope-form")

    render_click(
      view,
      "company_assessment_open",
      envelope(view, Map.put(binding, "value", ""))
    )

    assert has_element?(view, "#company-assessment-scope-form")
    refute has_element?(view, "#company-assessment-error")

    scope =
      Map.put(binding, "goal_snapshot", c.f.goal["id"] <> ":" <> Goals.content_hash(c.f.goal))

    render_submit(
      view,
      "assessment_goal_change",
      envelope(view, %{"scope" => scope, "value" => ""})
    )

    assert has_element?(view, "#company-assessment-error")
    refute has_element?(view, "#company-assessment-rubric-form")
    assert {:ok, []} = Assessments.list_rubrics()
    assert Repo.aggregate(Store.scoped(Assessment), :count) == 0
  end

  test "first oversized paste participates in immediate departure and cannot be frozen", c do
    view = scoped(c)
    huge = String.duplicate("x", 16_385)
    attrs = Map.put(c.f.freeze_attrs, "task", huge)

    render_change(
      view,
      "assessment_rubric_change",
      envelope(view, %{"rubric" => rubric_form(attrs)})
    )

    view |> element("#nav-evidence") |> render_click(%{"value" => ""})
    assert has_element?(view, "#company-assessment-departure")
    assert text(view, "#company-assessment-task") == huge
    view |> element("#company-assessment-freeze-leave") |> render_click(%{"value" => ""})
    assert has_element?(view, "#company-assessment-error", "Reduce the entered text")
    assert text(view, "#company-assessment-task") == huge
    assert {:ok, []} = Assessments.list_rubrics()
    view |> element("#company-assessment-keep-editing") |> render_click(%{"value" => ""})
    assert_push_event(view, "company-focus", %{id: "company-assessment-task"})
    refute has_element?(view, "#company-assessment-departure")
  end

  test "transport-limit refusal stays dirty and cannot save an earlier captured draft", c do
    view = scoped(c)
    huge = Map.put(c.f.freeze_attrs, "task", String.duplicate("x", 262_145))

    render_change(
      view,
      "assessment_rubric_change",
      envelope(view, %{"rubric" => rubric_form(huge)})
    )

    view |> element("#nav-evidence") |> render_click(%{"value" => ""})
    assert has_element?(view, "#company-assessment-departure")
    view |> element("#company-assessment-freeze-leave") |> render_click(%{"value" => ""})
    assert has_element?(view, "#company-assessment-error")
    assert {:ok, []} = Assessments.list_rubrics()

    render_change(
      view,
      "assessment_rubric_change",
      envelope(view, %{"rubric" => rubric_form(c.f.freeze_attrs)})
    )

    view |> element("#company-assessment-freeze-leave") |> render_click(%{"value" => ""})
    assert has_element?(view, "#evidence-panel")
    assert {:ok, [rubric]} = Assessments.list_rubrics()
    assert rubric["payload"]["task"] == c.f.oracle["task"]
  end

  test "keep and discard are deliberate and old queued parent events cannot restore discarded work",
       c do
    view = scoped(c)
    payload = envelope(view, %{"rubric" => rubric_form(c.f.freeze_attrs)})
    render_change(view, "assessment_rubric_change", payload)
    view |> element("#nav-evidence") |> render_click(%{"value" => ""})
    assert has_element?(view, "#company-panel:not([hidden])")
    view |> element("#company-assessment-keep-editing") |> render_click(%{"value" => ""})
    assert text(view, "#company-assessment-task") == c.f.oracle["task"]
    view |> element("#nav-evidence") |> render_click(%{"value" => ""})
    view |> element("#company-assessment-discard-leave") |> render_click(%{"value" => ""})
    assert has_element?(view, "#evidence-panel")
    render_submit(view, "assessment_rubric_freeze", payload)
    assert {:ok, []} = Assessments.list_rubrics()
    view |> element("#nav-company") |> render_click(%{"value" => ""})
    refute has_element?(view, "#company-assessment-rubric-form")
    refute render(view) =~ c.f.oracle["task"]
  end

  test "freeze and leave commits only a rubric and remount reloads committed history", c do
    view = scoped(c)

    render_change(
      view,
      "assessment_rubric_change",
      envelope(view, %{"rubric" => rubric_form(c.f.freeze_attrs)})
    )

    view |> element("#nav-evidence") |> render_click(%{"value" => ""})
    view |> element("#company-assessment-freeze-leave") |> render_click(%{"value" => ""})
    assert has_element?(view, "#evidence-panel")
    assert {:ok, [rubric]} = Assessments.list_rubrics()
    assert Repo.aggregate(Store.scoped(Assessment), :count) == 0
    {:ok, remounted, _} = live(c.conn, "/")
    remounted |> element("#nav-company") |> render_click(%{"value" => ""})

    remounted
    |> element("#company-assessment-open-rubric-#{rubric["id"]}")
    |> render_click(%{"value" => ""})

    assert has_element?(remounted, "#company-assessment-frozen", c.f.oracle["task"])
    refute has_element?(remounted, "#company-assessment-results-form")
    assert has_element?(remounted, "#company-assessment-start", "Unassessed")
  end

  test "record not accepted and leave refuses incomplete statuses, then records explicit unsuccessful observations",
       c do
    view = scoped(c)
    freeze(view, c.f)
    view |> element("#company-assessment-another-attempt") |> render_click(%{"value" => ""})
    partial = record_payload(view, c.f)
    partial = put_in(partial, ["assessment", "task_status"], "")
    render_change(view, "assessment_result_change", partial)
    view |> element("#nav-evidence") |> render_click(%{"value" => ""})
    view |> element("#company-assessment-record-leave") |> render_click(%{"value" => ""})
    assert has_element?(view, "#company-assessment-departure")
    assert Repo.aggregate(Store.scoped(Assessment), :count) == 0

    attrs =
      partial["assessment"]
      |> Map.put("task_status", "interrupted")
      |> Map.put("critical_status", "unobserved")

    attrs =
      Map.update!(attrs, "results", fn rows ->
        Map.new(rows, fn {key, row} ->
          {key, row |> Map.put("status", "unobserved") |> Map.put("observation", "")}
        end)
      end)

    render_change(view, "assessment_result_change", Map.put(partial, "assessment", attrs))
    view |> element("#company-assessment-record-leave") |> render_click(%{"value" => ""})
    assert has_element?(view, "#evidence-panel")
    assert {:ok, [rubric]} = Assessments.list_rubrics()
    assert {:ok, [receipt]} = Assessments.list_assessments(rubric["id"])
    assert receipt["payload"]["judgment"] == "not_accepted"
    assert receipt["payload"]["task_status"] == "interrupted"

    assert Enum.all?(
             receipt["payload"]["results"],
             &(&1["status"] == "unobserved" and &1["observation"] == "")
           )
  end

  test "supported reload refreshes open receipt applicability while retaining its captured judgment",
       c do
    view = scoped(c)
    freeze(view, c.f)
    view |> element("#company-assessment-another-attempt") |> render_click(%{"value" => ""})
    render_submit(view, "assessment_record", record_payload(view, c.f))
    assert {:ok, [rubric]} = Assessments.list_rubrics()
    assert {:ok, [before]} = Assessments.list_assessments(rubric["id"])
    assert text(view, "#company-assessment-receipt") =~ "Current — exact inputs"

    assert {:ok, _} =
             Company.save_profile(
               c.f.profile["payload"]
               |> Map.put("description", "Changed current input")
               |> Map.put("expected_content_hash", c.f.profile["content_hash"])
             )

    send(view.pid, {:company_changed, "Synthetic catalogue edit"})
    assert text(view, "#company-assessment-receipt") =~ "Stale"
    assert text(view, "#company-assessment-receipt") =~ "Accepted"
    refute text(view, "#company-assessment-receipt") =~ "Current — exact inputs"
    assert {:ok, [after_change]} = Assessments.list_assessments(rubric["id"])
    assert after_change["payload"] == before["payload"]
    assert after_change["assessment_hash"] == before["assessment_hash"]
    assert after_change["applicability"]["status"] == "stale"
  end

  test "portal purge clears two mounted drafts and refuses their old tokens and generations", c do
    first = scoped(c)
    freeze(first, c.f)
    first |> element("#company-assessment-another-attempt") |> render_click(%{"value" => ""})
    late_record = record_payload(first, c.f)
    render_change(first, "assessment_result_change", late_record)
    second = scoped(c)
    late_freeze = envelope(second, %{"rubric" => rubric_form(c.f.freeze_attrs)})
    render_change(second, "assessment_rubric_change", late_freeze)

    render_click(first, "purge_source", %{
      "privacy" => %{"id" => c.f.uncited_source["id"], "confirmation" => c.f.uncited_source["id"]}
    })

    refute has_element?(first, "#company-assessment-results-form")
    refute has_element?(second, "#company-assessment-rubric-form")
    refute render(first) =~ c.f.oracle["task"]
    refute render(second) =~ c.f.oracle["task"]
    render_submit(first, "assessment_record", late_record)
    render_submit(second, "assessment_rubric_freeze", late_freeze)
    assert Repo.aggregate(Store.scoped(TaskRubric), :count) == 0
    assert Repo.aggregate(Store.scoped(Assessment), :count) == 0
    assert {:ok, []} = Assessments.list_rubrics()
  end

  test "stale original history admits explicit unsuccessful work and refuses renewed acceptance",
       c do
    view = scoped(c)
    freeze(view, c.f)
    {:ok, rubric} = Assessments.list_rubrics() |> then(fn {:ok, [rubric]} -> {:ok, rubric} end)

    assert {:ok, _} =
             Company.save_profile(
               c.f.profile["payload"]
               |> Map.put("description", "New current intent")
               |> Map.put("expected_content_hash", c.f.profile["content_hash"])
             )

    send(view.pid, {:company_changed, "Synthetic supported refresh"})
    assert has_element?(view, "#company-assessment-another-attempt")
    view |> element("#company-assessment-another-attempt") |> render_click(%{"value" => ""})
    payload = record_payload(view, c.f)
    render_submit(view, "assessment_record", payload)
    assert has_element?(view, "#company-assessment-error", "Inputs changed")
    assert Repo.aggregate(Store.scoped(Assessment), :count) == 0
    payload = put_in(payload, ["assessment", "judgment"], "not_accepted")
    render_submit(view, "assessment_record", payload)
    assert {:ok, [receipt]} = Assessments.list_assessments(rubric["id"])
    assert receipt["payload"]["judgment"] == "not_accepted"
    assert receipt["payload"]["authority_at_record"] == "stale"
    assert has_element?(view, "#company-assessment-receipt", "Stale")
  end

  test "superseded plan history deliberately rebinds a successor to a newly eligible built package",
       c do
    view = scoped(c)
    freeze(view, c.f)
    assert {:ok, [previous]} = Assessments.list_rubrics()

    {:ok, plan} =
      Company.create_plan(
        c.f.plan_attrs
        |> Map.put("supersedes_id", c.f.plan["id"])
        |> Map.put("package_version", "1.2.0")
      )

    {:ok, plan} = Company.decide_plan(plan["id"], Fixture.decision(plan))
    send(view.pid, {:company_changed, "Synthetic plan replacement"})
    view |> element("#company-assessment-successor") |> render_click(%{"value" => ""})

    assert has_element?(
             view,
             "#company-assessment-notice",
             "Choose an eligible current built package"
           )

    refute has_element?(view, "#company-assessment-results-form")
    view |> element("#company-plan-select-#{plan["id"]}") |> render_click(%{"value" => ""})
    view |> form("#company-plan-build-form") |> render_submit()
    view |> element("#company-guide-assess") |> render_click(%{"value" => ""})

    view
    |> form("#company-assessment-scope-form", %{
      "scope" => %{"goal_snapshot" => c.f.goal["id"] <> ":" <> Goals.content_hash(c.f.goal)}
    })
    |> render_submit()

    assert attr(view, "input[name='rubric[supersedes_id]']", "value") == previous["id"]

    assert attr(view, "input[name='rubric[expected_plan_revision_hash]']", "value") ==
             plan["revision_hash"]

    assert text(view, "#company-assessment-task") == ""
    refute has_element?(view, "#company-assessment-results-form")

    view
    |> form("#company-assessment-rubric-form", %{
      "rubric" => %{"task" => "New package, newly reviewed representative task."}
    })
    |> render_submit()

    assert {:ok, rubrics} = Assessments.list_rubrics()
    successor = Enum.find(rubrics, &(&1["supersedes_id"] == previous["id"]))
    assert successor["payload"]["binding"]["plan_id"] == plan["id"]
    assert successor["family_id"] == previous["family_id"]
    assert {:ok, []} = Assessments.list_assessments(successor["id"])
    assert {:ok, preserved} = Assessments.get_rubric(previous["id"])
    assert preserved["payload"] == previous["payload"]
    assert preserved["revision_hash"] == previous["revision_hash"]
  end

  test "real parent session hook refuses a queued freeze after operator epoch revocation", c do
    view = scoped(c)
    late = envelope(view, %{"rubric" => rubric_form(c.f.freeze_attrs)})
    previous = :sys.get_state(Workspaces)
    :sys.replace_state(Workspaces, &%{&1 | epoch: "revoked-assessment-flow-session"})
    on_exit(fn -> :sys.replace_state(Workspaces, fn _ -> previous end) end)

    assert {:error, {:redirect, %{to: "/login"}}} =
             render_submit(view, "assessment_rubric_freeze", late)

    assert Repo.aggregate(Store.scoped(TaskRubric), :count) == 0
    assert Repo.aggregate(Store.scoped(Assessment), :count) == 0
  end

  defp scoped(c) do
    {:ok, view, _} = live(c.conn, "/")
    view |> element("#nav-company") |> render_click(%{"value" => ""})
    view |> element("#company-plan-select-#{c.f.plan["id"]}") |> render_click(%{"value" => ""})
    refute has_element?(view, "#company-guide-assess")
    view |> form("#company-plan-build-form") |> render_submit()
    assert has_element?(view, "#company-built-assess")
    assert has_element?(view, "#company-guide-assess")
    view |> element("#company-guide-assess") |> render_click(%{"value" => ""})
    assert attr(view, "#company-assessment-goal option[selected]", "value") == ""

    view
    |> form("#company-assessment-scope-form", %{
      "scope" => %{"goal_snapshot" => c.f.goal["id"] <> ":" <> Goals.content_hash(c.f.goal)}
    })
    |> render_submit()

    assert has_element?(view, "#company-assessment-rubric-form")
    view
  end

  defp freeze(view, f) do
    payload = envelope(view, %{"rubric" => rubric_form(f.freeze_attrs)})
    render_change(view, "assessment_rubric_change", payload)
    assert has_element?(view, "#company-assessment-obligation-3")
    view |> form("#company-assessment-rubric-form") |> render_submit()
    assert has_element?(view, "#company-assessment-frozen")
  end

  defp rubric_form(attrs) do
    Map.update!(attrs, "obligations", fn rows ->
      rows
      |> Enum.with_index()
      |> Map.new(fn {row, index} ->
        refs = Enum.map(row["claim_refs"], &(&1["id"] <> ":" <> &1["revision_hash"]))

        {Integer.to_string(index),
         row |> Map.put("mandatory", "true") |> Map.put("claim_refs", refs)}
      end)
    end)
  end

  defp record_payload(view, f) do
    attrs =
      Map.new(~w(rubric_id expected_rubric_hash attempt_id attempt_token), fn key ->
        {key,
         attr(view, "#company-assessment-results-form input[name='assessment[#{key}]']", "value")}
      end)

    rows =
      f.oracle["obligations"]
      |> Enum.sort_by(& &1["id"])
      |> Enum.with_index()
      |> Map.new(fn {row, index} ->
        {Integer.to_string(index),
         %{
           "obligation_id" => row["id"],
           "status" => "met",
           "observation" => row["met_observation"]
         }}
      end)

    attrs =
      Map.merge(attrs, %{
        "task_status" => "completed",
        "critical_status" => "none",
        "judgment" => "accepted",
        "results" => rows
      })

    envelope(view, %{"assessment" => attrs})
  end

  defp envelope(view, attrs),
    do:
      Map.put(
        attrs,
        "assessment_event_generation",
        attr(view, "input[name='assessment_event_generation']", "value")
      )

  defp attr(view, selector, name),
    do:
      render(view)
      |> LazyHTML.from_document()
      |> LazyHTML.query(selector)
      |> LazyHTML.attribute(name)
      |> List.first()

  defp text(view, selector),
    do: render(view) |> LazyHTML.from_document() |> LazyHTML.query(selector) |> LazyHTML.text()

  defp artifact_bytes(root),
    do:
      Path.wildcard(Path.join(root, "artifacts/**/*"))
      |> Enum.filter(&File.regular?/1)
      |> Map.new(&{Path.relative_to(&1, root), Contracts.digest(File.read!(&1))})
end
