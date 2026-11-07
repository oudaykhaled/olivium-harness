defmodule HarnessForgeWeb.PackageReadinessTest do
  use HarnessForgeWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias HarnessForge.{
    Decisions,
    Evidence,
    Evaluations,
    Harnesses,
    Privacy,
    Readiness,
    Repo,
    Workspaces
  }

  alias HarnessForge.Evaluation.Run
  alias HarnessForge.Execution.{Coding, Command, Docker}
  alias HarnessForge.Models.Configuration
  alias HarnessForgeWeb.Plugs.OperatorSession

  @static_explanation "This static evaluation checked package integrity only. " <>
                        "No model-backed task or runtime cleanup was attempted. " <>
                        "Release review still requires a qualified model-backed task evaluation."

  setup %{conn: conn} = context do
    previous_root = Application.fetch_env!(:harness_forge, :workspace_root)
    previous_id = Workspaces.current_id()
    id = Ecto.UUID.generate()
    root = Path.join(File.cwd!(), "tmp/readiness-web-#{id}")
    Enum.each(~w(artifacts runs tmp evidence), &File.mkdir_p!(Path.join(root, &1)))
    Application.put_env(:harness_forge, :workspace_root, root)
    Application.put_env(:harness_forge, :workspace_id, id)

    if context[:committed] do
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

      Application.put_env(:harness_forge, :workspace_root, previous_root)
      Application.put_env(:harness_forge, :workspace_id, previous_id)
      File.rm_rf!(root)
      File.rm_rf!(root <> "-backup")
      File.rm_rf!(root <> "-restored")
    end)

    conn = %{conn | host: "localhost", port: 4002}

    {:ok,
     conn: init_test_session(conn, %{"operator_auth" => OperatorSession.new_auth()}), root: root}
  end

  test "empty Packages explains that there is no saved package to inspect", %{conn: conn} do
    view = packages(conn)
    assert has_element?(view, "#readiness-empty", "No saved packages to inspect")
    refute has_element?(view, "#package-readiness-form")
    refute has_element?(view, "#readiness-report")
  end

  test "inspection uses an explicit pair and static success remains release blocked", %{
    conn: conn
  } do
    %{artifact: artifact} = fixture()
    {:ok, run} = Evaluations.run(artifact["digest"], kind: :static_integrity)
    view = packages(conn)
    select_package(view, artifact)

    assert has_element?(
             view,
             "[data-readiness-field=evaluation] option[selected][value='']",
             "No evaluation selected"
           )

    refute has_element?(view, "#readiness-report")
    inspect_pair(view)
    assert has_element?(view, "#readiness-report", artifact["digest"])
    assert has_element?(view, "#readiness-stage-evaluation", "No evaluation selected")
    refute render(view) =~ @static_explanation
    assert has_element?(view, "#readiness-stage-release_admission [data-status=blocked]")

    assert Enum.count(
             view
             |> element("#readiness-stages")
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("li")
           ) == 7

    assert has_element?(view, "#readiness-identities summary", "Identities")

    assert has_element?(
             view,
             "#readiness-limitations",
             "Live runtime and model availability were not checked"
           )

    assert has_element?(view, "#inspect-readiness", "Refresh readiness")

    select_run(view, artifact, run)
    refute has_element?(view, "#readiness-report")
    assert {:ok, domain_report} = Readiness.for_artifact(artifact["digest"], run["id"])

    for _ <- 1..2 do
      inspect_pair(view)
      actual = :sys.get_state(view.pid).socket.assigns.readiness_report
      assert Map.delete(actual, "observed_at") == Map.delete(domain_report, "observed_at")
      html = render(view)

      for selector <- ["#readiness-summary", "#readiness-selection-status"] do
        assert text_at(html, selector) == "Release review is blocked. " <> @static_explanation
      end

      assert text_at(html, "#readiness-stage-cleanup > p:first-of-type") == @static_explanation
      assert has_element?(view, "#readiness-stage-cleanup [data-status=blocked]", "Blocked")
      assert has_element?(view, "#readiness-stage-cleanup", "Recorded cleanup: Not started")
      assert has_element?(view, "#readiness-next-action", "Review evaluations")
    end

    assert {:error, :qualified_task_evaluation_required} =
             HarnessForge.Releases.Validation.check(
               artifact,
               run,
               artifact["spec"]["spec"]["scope"]
             )

    assert has_element?(view, "#readiness-report", run["id"])
    assert has_element?(view, "#readiness-stage-evaluation", "Static package integrity")
    assert has_element?(view, "#readiness-stage-evaluation", "Outcome: Passed")
    assert has_element?(view, "#readiness-stage-evaluation [data-status=passed]")
    assert has_element?(view, "#readiness-stage-release_admission [data-status=blocked]")
    refute has_element?(view, "#readiness-summary", "Ready for release review")
    assert has_element?(view, "#readiness-selection-status[role=status][aria-live=polite]")
  end

  test "package and run switches clear the entire report and filter saved runs", %{conn: conn} do
    %{artifact: first} = fixture()
    {:ok, second} = Harnesses.build(%{"name" => "second-synthetic", "version" => "0.2.0"})
    {:ok, first_run} = Evaluations.run(first["digest"], kind: :static_integrity)
    {:ok, other_run} = Evaluations.run(second["digest"], kind: :static_integrity)
    foreign_id = Ecto.UUID.generate()

    Repo.insert!(%Run{
      id: foreign_id,
      workspace_id: "another-workspace",
      artifact_digest: first["digest"],
      result: Map.put(first_run, "id", foreign_id)
    })

    view = packages(conn)
    select_package(view, first)

    assert has_element?(
             view,
             "[data-readiness-field=evaluation] option[value='#{first_run["id"]}']"
           )

    refute has_element?(
             view,
             "[data-readiness-field=evaluation] option[value='#{other_run["id"]}']"
           )

    refute render(view) =~ foreign_id
    select_run(view, first, first_run)
    inspect_pair(view)
    assert has_element?(view, "#readiness-next-action")
    assert render(view) =~ @static_explanation
    select_package(view, second)
    refute render(view) =~ @static_explanation
    refute has_element?(view, "#readiness-report")
    refute has_element?(view, "#readiness-next-action")
    refute has_element?(view, "#readiness-identities")
    assert has_element?(view, "[data-readiness-field=evaluation] option[selected][value='']")

    assert has_element?(
             view,
             "[data-readiness-field=evaluation] option[value='#{other_run["id"]}']"
           )

    refute has_element?(
             view,
             "[data-readiness-field=evaluation] option[value='#{first_run["id"]}']"
           )

    assert has_element?(view, "#readiness-selection-status", "Selection changed")
  end

  test "navigation opens the allowlisted panel without starting or approving anything", %{
    conn: conn
  } do
    %{artifact: artifact} = fixture()
    view = packages(conn)
    select_package(view, artifact)
    inspect_pair(view)
    view |> element("#readiness-next-action") |> render_click()
    assert has_element?(view, "#evaluations-panel")
    assert_push_event(view, "company-focus", %{id: "evaluations-panel"})
    assert {:ok, []} = Evaluations.list_runs()
    assert {:ok, []} = HarnessForge.Releases.list()
  end

  test "real Inspect and Refresh events abstain without command, port or profile probes", %{
    conn: conn
  } do
    %{artifact: artifact} = fixture(%{"runtime_version" => Docker.version()})
    {:ok, static} = Evaluations.run(artifact["digest"], kind: :static_integrity)
    smoke = inert_run(static, %{"kind" => "runtime_smoke", "cleanup_status" => "complete"})

    task =
      inert_run(static, %{
        "kind" => "task",
        "runtime_qualified" => true,
        "outcome" => "passed",
        "cleanup_status" => "complete"
      })

    failed = inert_run(task, %{"outcome" => "failed"})
    blocked = inert_run(task, %{"outcome" => "blocked"})
    cancelled = inert_run(task, %{"outcome" => "cancelled"})
    incomplete = inert_run(task, %{"cleanup_status" => "cleanup_failed"})
    pending = inert_run(task, %{"outcome" => "pending", "completed_at" => nil})
    unknown = inert_run(task, %{"kind" => "unknown_kind"})
    failed_static = inert_run(static, %{"outcome" => "failed"})
    incomplete_static = inert_run(static, %{"completed_at" => nil})
    unknown_outcome = inert_run(static, %{"outcome" => "unknown"})
    unknown_cleanup = inert_run(static, %{"cleanup_status" => "unknown"})
    {:ok, other} = Harnesses.build(%{"name" => "other-inert-package"})
    cross = inert_run(static, %{"artifact_digest" => other["digest"]})
    foreign = inert_run(static, %{"workspace_id" => "foreign-workspace"})
    view = packages(conn)
    # This pure configuration write occurs after mount so the existing unrelated
    # model-status mount read is excluded. No task profile builds these records.
    {:ok, _} = Configuration.configure(%{"model" => "synthetic-readiness-model"})

    runs = [
      static,
      smoke,
      task,
      failed,
      blocked,
      cancelled,
      incomplete,
      pending,
      unknown,
      failed_static,
      incomplete_static,
      unknown_outcome,
      unknown_cleanup
    ]

    with_inspector_trace(view, 2 * (length(runs) + 1), fn ->
      select_package(view, artifact)
      inspect_pair(view)
      inspect_pair(view)
      assert has_element?(view, "#readiness-stage-evaluation", "No evaluation selected")
      refute render(view) =~ @static_explanation
      assert has_element?(view, "#readiness-current-identity-assessment", "Not assessed")

      for run <- runs do
        select_run(view, artifact, run)
        inspect_pair(view)
        inspect_pair(view)
        assert has_element?(view, "#readiness-report", run["id"])

        if run["id"] == static["id"],
          do: assert(render(view) =~ @static_explanation),
          else: refute(render(view) =~ @static_explanation)

        if run["id"] == incomplete["id"] do
          assert has_element?(
                   view,
                   "#readiness-stage-cleanup",
                   "Recorded cleanup: Cleanup failed"
                 )

          assert has_element?(
                   view,
                   "#readiness-summary",
                   "Recorded evaluation cleanup is incomplete"
                 )
        end

        if run["kind"] == "task" do
          assert has_element?(view, "#readiness-stage-applicability [data-status=not_assessed]")

          assert has_element?(
                   view,
                   "#readiness-stage-release_admission [data-status=not_assessed]"
                 )

          assert has_element?(
                   view,
                   "#readiness-stage-release_admission",
                   "This inspector did not run that check"
                 )

          assert has_element?(
                   view,
                   "#readiness-identities",
                   "Current OpenCode task identities were not checked"
                 )

          refute has_element?(view, "#readiness-summary", "Ready for release review")
        end

        cond do
          run["id"] == task["id"] ->
            assert has_element?(view, "#readiness-summary", "Release admission was not assessed")
            refute has_element?(view, "#readiness-summary", "blocked")

            assert has_element?(
                     view,
                     "#readiness-next-action",
                     "Open release review — runtime check required"
                   )

            assert has_element?(view, "#readiness-runtime-action-help", "may check the runtime")

          run["id"] in [
            failed["id"],
            blocked["id"],
            cancelled["id"],
            incomplete["id"],
            pending["id"]
          ] ->
            assert has_element?(view, "#readiness-summary", "Release review is blocked")
            assert has_element?(view, "#readiness-next-action", "Review evaluations")

          true ->
            assert has_element?(view, "#readiness-stage-release_admission [data-status=blocked]")
        end
      end

      # These forged browser submissions are rejected by exact-pair selection,
      # before the domain read. Context tests separately inspect unavailable IDs.
      for id <- [Ecto.UUID.generate(), cross["id"], foreign["id"]] do
        captured = put_in(envelope(view), ["readiness", "evaluation_id"], id)
        render_submit(view, "inspect_readiness", captured)
        refute has_element?(view, "#readiness-report")
        refute render(view) =~ @static_explanation
      end
    end)
  end

  test "missing model metadata does not hide known task failures or turn abstention into refusal",
       %{conn: conn} do
    %{artifact: artifact} = fixture()
    {:ok, static} = Evaluations.run(artifact["digest"], kind: :static_integrity)

    passed =
      inert_run(static, %{
        "kind" => "task",
        "runtime_qualified" => true,
        "outcome" => "passed",
        "cleanup_status" => "complete"
      })

    failed = inert_run(passed, %{"outcome" => "failed"})
    cleanup = inert_run(passed, %{"cleanup_status" => "cleanup_failed"})
    view = packages(conn)

    with_inspector_trace(view, 6, fn ->
      select_package(view, artifact)

      for run <- [passed, failed, cleanup] do
        select_run(view, artifact, run)
        inspect_pair(view)
        inspect_pair(view)
        assert has_element?(view, "#readiness-stage-managed_runtime", "No selected model")

        cond do
          run["id"] == passed["id"] ->
            assert has_element?(view, "#readiness-summary", "Release admission was not assessed")
            refute has_element?(view, "#readiness-summary", "blocked")
            assert has_element?(view, "#readiness-next-action", "runtime check required")

          run["id"] == failed["id"] ->
            assert has_element?(
                     view,
                     "#readiness-summary",
                     "selected evaluation recorded a failed outcome"
                   )

            assert has_element?(view, "#readiness-next-action", "Review evaluations")

          true ->
            assert has_element?(
                     view,
                     "#readiness-summary",
                     "Recorded evaluation cleanup is incomplete"
                   )

            assert has_element?(view, "#readiness-next-action", "Review evaluations")
        end
      end
    end)
  end

  test "relevant reload and evaluation changes invalidate the report and captured events", %{
    conn: conn
  } do
    %{artifact: artifact} = fixture()
    {:ok, run} = Evaluations.run(artifact["digest"], kind: :static_integrity)
    view = packages(conn)
    select_package(view, artifact)
    select_run(view, artifact, run)
    inspect_pair(view)
    assert render(view) =~ @static_explanation
    old = envelope(view)
    send(view.pid, {:company_changed, %{}})
    refute has_element?(view, "#readiness-report")
    refute render(view) =~ @static_explanation
    render_submit(view, "inspect_readiness", old)
    refute has_element?(view, "#readiness-report")
    inspect_pair(view)
    assert has_element?(view, "#readiness-report")
    record = Repo.get!(Run, run["id"])

    Repo.update!(
      Ecto.Changeset.change(record, result: Map.put(record.result, "outcome", "interrupted"))
    )

    send(view.pid, :refresh_evaluations)
    refute has_element?(view, "#readiness-report")
    inspect_pair(view)
    refute render(view) =~ @static_explanation
    assert has_element?(view, "#readiness-stage-evaluation", "Interrupted")
    assert has_element?(view, "#readiness-stage-release_admission [data-status=blocked]")
  end

  test "privacy refusal clears a previously displayed report without exposing errors", %{
    conn: conn
  } do
    %{artifact: artifact, source: source} = fixture()
    view = packages(conn)
    select_package(view, artifact)
    inspect_pair(view)
    assert has_element?(view, "#readiness-report")
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    Repo.query!(
      "INSERT INTO privacy_operations (id,workspace_id,kind,target_id,state,plan,inserted_at,updated_at) VALUES (?,?,?,?,?,?,?,?)",
      [
        Ecto.UUID.generate(),
        Workspaces.current_id(),
        "source",
        source["id"],
        "prepared",
        "{}",
        now,
        now
      ]
    )

    inspect_pair(view)
    refute has_element?(view, "#readiness-report")
    refute has_element?(view, "#readiness-next-action")
    assert has_element?(view, "#readiness-selection-status", "workspace privacy state")
    refute render(view) =~ "privacy_operation_incomplete"
  end

  test "source purge resets both mounted inspectors and rejects captured pre-reset forms", %{
    conn: conn
  } do
    %{artifact: artifact, source: source} = fixture()
    {:ok, run} = Evaluations.run(artifact["digest"], kind: :static_integrity)
    first = packages(conn)
    sibling = packages(conn)

    for view <- [first, sibling] do
      select_package(view, artifact)
      select_run(view, artifact, run)
      inspect_pair(view)
      assert has_element?(view, "#readiness-report")
      assert render(view) =~ @static_explanation
    end

    captured = Map.new([first, sibling], &{&1.pid, envelope(&1)})
    first |> element("#nav-privacy") |> render_click()

    first
    |> form("#purge-source-form", privacy: %{id: source["id"], confirmation: source["id"]})
    |> render_submit()

    for view <- [first, sibling] do
      view |> element("#nav-package") |> render_click()
      refute has_element?(view, "#readiness-report")
      refute has_element?(view, "#readiness-next-action")
      refute has_element?(view, "#readiness-selected-digest")
      render_change(view, "readiness_select", captured[view.pid])
      render_submit(view, "inspect_readiness", captured[view.pid])
      render_click(view, "readiness_next", captured[view.pid]["readiness"])
      refute has_element?(view, "#readiness-report")
      refute render(view) =~ @static_explanation
      assert has_element?(view, "#package-panel")
    end
  end

  @tag :committed
  test "quarantined restore clears both inspectors without switching the active workspace", %{
    conn: conn,
    root: root
  } do
    %{artifact: artifact} = fixture()
    {:ok, _} = Privacy.backup(root <> "-backup")
    first = packages(conn)
    sibling = packages(conn)

    for view <- [first, sibling] do
      select_package(view, artifact)
      inspect_pair(view)
      assert has_element?(view, "#readiness-report")
    end

    captured = Map.new([first, sibling], &{&1.pid, envelope(&1)})
    controls = Map.new([first, sibling], &{&1.pid, controls_id(&1)})
    active_workspace = Workspaces.current_id()
    first |> element("#nav-privacy") |> render_click()

    first
    |> form("#restore-form", privacy: %{backup: root <> "-backup", target: root <> "-restored"})
    |> render_submit()

    assert has_element?(first, "#privacy-result", "quarantined")
    assert Workspaces.current_id() == active_workspace

    for view <- [first, sibling] do
      view |> element("#nav-package") |> render_click()
      refute has_element?(view, "#readiness-report")
      refute has_element?(view, "#readiness-next-action")
      assert has_element?(view, "[data-readiness-field=package] option[selected][value='']")
      refute controls_id(view) == controls[view.pid]
      render_change(view, "readiness_select", captured[view.pid])
      render_submit(view, "inspect_readiness", captured[view.pid])
      refute has_element?(view, "#readiness-report")
      refute has_element?(view, "#readiness-selected-digest")
    end

    assert {:ok, _} = Harnesses.get(artifact["digest"])
    metadata = (root <> "-restored/restore.json") |> File.read!() |> Jason.decode!()
    assert metadata["state"] == "quarantined"
    refute metadata["new_workspace_id"] == active_workspace
  end

  test "remounted inspectors reject a previous mount's serialized selection and inspection", %{
    conn: conn
  } do
    %{artifact: artifact} = fixture()
    first = packages(conn)
    select_package(first, artifact)
    inspect_pair(first)
    captured = envelope(first)
    second = packages(conn)
    render_change(second, "readiness_select", captured)
    render_submit(second, "inspect_readiness", captured)
    refute has_element?(second, "#readiness-report")
    refute has_element?(second, "#readiness-selected-digest")
    assert has_element?(second, "[data-readiness-field=package] option[selected][value='']")
  end

  test "all-event authentication clears cached readiness before redirecting a revoked session", %{
    conn: conn
  } do
    %{artifact: artifact} = fixture()
    view = packages(conn)
    select_package(view, artifact)
    inspect_pair(view)
    old_generation = envelope(view)["readiness"]["generation"]
    trace = {HarnessForgeWeb.PortalLive, :revoke_operator, 1}
    :erlang.trace_pattern(trace, [{:_, [], [{:return_trace}]}], [:local])
    :erlang.trace(view.pid, true, [:call, {:tracer, self()}])
    on_exit(fn -> :erlang.trace_pattern(trace, false, [:local]) end)
    previous = :sys.get_state(Workspaces)
    :sys.replace_state(Workspaces, &%{&1 | epoch: "revoked-readiness-session"})
    on_exit(fn -> :sys.replace_state(Workspaces, fn _ -> previous end) end)

    assert {:error, {:redirect, %{to: "/login"}}} =
             render_click(view, "tab", %{"tab" => "company"})

    assert_receive {:trace, _, :return_from, ^trace, revoked_socket}
    assert revoked_socket.assigns.readiness_report == nil
    assert revoked_socket.assigns.readiness_digest == nil
    assert revoked_socket.assigns.readiness_evaluation_id == nil
    refute revoked_socket.assigns.readiness_generation == old_generation
    assert {:ok, []} = Evaluations.list_runs()
    assert {:ok, []} = HarnessForge.Releases.list()
  end

  test "presentation allowlists reasons, identity keys, actions and limitations" do
    sentinel = "PRIVATE_RAW_PAYLOAD_SENTINEL"
    digest = String.duplicate("a", 64)

    report = %{
      "artifact_digest" => digest,
      "evaluation_id" => nil,
      "observed_at" => "2026-11-01T00:00:00Z",
      "plan_bindings" => [],
      "current_identities" => %{"artifact_digest" => digest, "source_body" => sentinel},
      "current_identity_assessment" => %{
        "kind" => sentinel,
        "status" => "passed",
        "reason_code" => sentinel
      },
      "evaluation_identities" => %{"configuration" => sentinel},
      "stages" => [%{"name" => "integrity", "status" => "blocked", "reason_code" => sentinel}],
      "next_action" => %{"code" => sentinel, "destination" => "https://foreign.example"},
      "limitations" => [sentinel]
    }

    html = readiness_html(report)

    refute html =~ sentinel
    refute html =~ "https://foreign.example"
    refute html =~ "readiness-next-action"
    assert html =~ "This stage could not be established"
    assert html =~ "No retained local plan binding"
  end

  test "static explanation requires every exact predicate field, including absent metadata" do
    %{artifact: artifact} = fixture()
    {:ok, run} = Evaluations.run(artifact["digest"], kind: :static_integrity)
    {:ok, report} = Readiness.for_artifact(artifact["digest"], run["id"])
    assert readiness_html(report) =~ @static_explanation

    mutations = [
      {"evaluation", "kind", ~w(runtime_smoke task unknown)},
      {"evaluation", "outcome", ~w(failed blocked pending unknown)},
      {"evaluation", "status", ~w(blocked not_assessed unknown)},
      {"cleanup", "status", ~w(passed not_assessed unknown)},
      {"cleanup", "reason_code", ~w(cleanup_complete unknown)},
      {"cleanup", "cleanup_status", ~w(complete cleanup_failed not_dispatched pending unknown)},
      {"release_admission", "status", ~w(passed not_assessed unknown)},
      {"release_admission", "reason_code",
       ~w(runtime_identity_check_required invalid_evaluation_record unknown)}
    ]

    for {name, key, values} <- mutations, value <- values ++ [nil, :missing] do
      changed =
        change_stage(report, name, fn stage ->
          if value == :missing, do: Map.delete(stage, key), else: Map.put(stage, key, value)
        end)

      refute readiness_html(changed) =~ @static_explanation, inspect({name, key, value})
    end
  end

  test "static explanation preserves earlier blocker priority in summary and polite status" do
    %{artifact: artifact} = fixture()
    {:ok, run} = Evaluations.run(artifact["digest"], kind: :static_integrity)
    {:ok, report} = Readiness.for_artifact(artifact["digest"], run["id"])

    for {name, reason, explanation} <- [
          {"integrity", "artifact_integrity_unavailable",
           "The saved package is unavailable or could not be verified."},
          {"eligibility", "stale_or_revoked_evidence",
           "Current evidence or plan admission changed. Review and rebuild the package."},
          {"managed_runtime", "runtime_backend_unavailable",
           "This target has no managed execution backend. Review a supported target."},
          {"evaluation", "evaluation_failed",
           "The selected evaluation recorded a failed outcome."}
        ] do
      changed =
        change_stage(
          report,
          name,
          &Map.merge(&1, %{"status" => "blocked", "reason_code" => reason})
        )

      html = readiness_html(changed)

      for selector <- ["#readiness-summary", "#readiness-selection-status"] do
        assert text_at(html, selector) == "Release review is blocked. " <> explanation
      end

      if name == "evaluation",
        do: refute(html =~ @static_explanation),
        else:
          assert(
            text_at(html, "#readiness-stage-cleanup > p:first-of-type") == @static_explanation
          )
    end
  end

  test "transport refusals stay plain and private in real run cards and historical readiness", %{
    conn: conn
  } do
    %{artifact: artifact} = fixture()
    {:ok, base} = Evaluations.run(artifact["digest"], kind: :static_integrity)
    endpoint = "unix:///private/TRANSPORT_ENDPOINT_MUST_STAY_PRIVATE.sock"
    daemon = "DAEMON:IDENTITY:MUST:STAY:PRIVATE"

    examples = [
      {"coding_transport_unavailable",
       "This run could not verify a local Docker connection. Check Docker, then queue a new task evaluation."},
      {"coding_transport_unsupported",
       "This run could not use a supported local Docker setup. Review the setup before queuing another task evaluation."},
      {"local_docker_required",
       "This run requires a supported local Docker connection. Review the setup before queuing another task evaluation."},
      {"coding_transport_changed",
       "This run could not verify the same local Docker setup throughout the attempt. It cannot qualify a release."},
      {"coding_cleanup_context_invalid",
       "This run could not verify its cleanup information. Cleanup remains unresolved."},
      {"coding_cleanup_origin_unknown",
       "This older run could not verify its original local Docker setup. Cleanup remains unresolved."}
    ]

    runs =
      for {reason, message} <- examples do
        run =
          inert_run(base, %{
            "kind" => "task",
            "outcome" => "blocked",
            "reason" => reason,
            "runtime_qualified" => false,
            "cleanup_status" => "not_started"
          })

        context = %{
          "version" => "coding-transport-v2",
          "route" => "desktop_loopback_proxy",
          "endpoint" => endpoint,
          "daemon_id" => daemon,
          "workspace_id" => Workspaces.current_id(),
          "run_id" => run["id"]
        }

        record = Repo.get!(Run, run["id"])
        changeset = Ecto.Changeset.change(record, execution_context: context)
        saved = Repo.update!(changeset)

        for inspected <- [inspect(changeset), inspect(saved)] do
          refute inspected =~ endpoint
          refute inspected =~ daemon
        end

        assert {:ok, public} = Evaluations.get(run["id"])
        refute Jason.encode!(public) =~ endpoint
        refute Jason.encode!(public) =~ daemon
        {run, message}
      end

    {:ok, public_runs} = Evaluations.list_runs()
    refute Jason.encode!(public_runs) =~ endpoint
    refute Jason.encode!(public_runs) =~ daemon
    view = packages(conn)
    view |> element("#nav-evaluations") |> render_click()

    for {run, message} <- runs do
      assert has_element?(view, "#run-#{run["id"]}", message)
      refute has_element?(view, "#run-#{run["id"]} button")
    end

    refute render(view) =~ endpoint
    refute render(view) =~ daemon
    view |> element("#nav-package") |> render_click()
    select_package(view, artifact)

    for {run, message} <- runs do
      select_run(view, artifact, run)
      inspect_pair(view)
      assert has_element?(view, "#readiness-stage-evaluation", message)
      assert has_element?(view, "#readiness-stage-evaluation", "historical observation")
      assert has_element?(view, "#readiness-report", "Not assessed")
      refute render(view) =~ endpoint
      refute render(view) =~ daemon
    end
  end

  test "unknown reason data is never echoed by run cards or readiness", %{conn: conn} do
    %{artifact: artifact} = fixture()
    {:ok, base} = Evaluations.run(artifact["digest"], kind: :static_integrity)
    canary = "unix:///private/UNKNOWN_REASON_ENDPOINT.sock DAEMON:PRIVATE <script>bad</script>"
    run = inert_run(base, %{"kind" => "task", "outcome" => "blocked", "reason" => canary})
    view = packages(conn)
    view |> element("#nav-evaluations") |> render_click()

    assert has_element?(
             view,
             "#run-#{run["id"]}",
             "This run could not establish a verified result. Review its outcome and cleanup status."
           )

    refute render(view) =~ "UNKNOWN_REASON_ENDPOINT"
    refute render(view) =~ "DAEMON:PRIVATE"
    view |> element("#nav-package") |> render_click()
    select_package(view, artifact)
    select_run(view, artifact, run)
    inspect_pair(view)
    refute render(view) =~ "UNKNOWN_REASON_ENDPOINT"
    refute render(view) =~ "DAEMON:PRIVATE"
    assert has_element?(view, "#readiness-stage-evaluation", "Blocked")
    refute has_element?(view, "#readiness-stage-evaluation", "Selected run observation:")
  end

  defp change_stage(report, name, fun),
    do:
      Map.update!(
        report,
        "stages",
        &Enum.map(&1, fn stage -> if stage["name"] == name, do: fun.(stage), else: stage end)
      )

  defp text_at(html, selector),
    do:
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(selector)
      |> LazyHTML.text()
      |> String.trim()

  defp readiness_html(report) do
    render_component(&HarnessForgeWeb.PackageReadiness.inspector/1,
      artifacts: [],
      runs: [],
      digest: report["artifact_digest"],
      evaluation_id: report["evaluation_id"],
      report: report,
      message: nil,
      generation: Ecto.UUID.generate(),
      controls_generation: Ecto.UUID.generate()
    )
  end

  # Privileged inert persisted records test projection only. Historical task
  # digests are arbitrary and never supply current identities or admission.
  defp inert_run(base, overrides) do
    id = Ecto.UUID.generate()

    historical = %{
      "id" => id,
      "environment_profile_digest" => String.duplicate("a", 64),
      "model_id" => "inert-historical-model",
      "completed_at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    # Keep real static/smoke identities for their pure comparison; task values are
    # deliberately historical, not computed through the live-bearing profile.
    defaults =
      if (overrides["kind"] || base["kind"]) == "task",
        do: historical,
        else: Map.drop(historical, ~w(environment_profile_digest model_id))

    result = base |> Map.merge(defaults) |> Map.merge(overrides) |> Map.put("id", id)

    Repo.insert!(%Run{
      id: id,
      workspace_id: result["workspace_id"],
      artifact_digest: result["artifact_digest"],
      result: result
    })

    result
  end

  def trace_marker, do: :ok

  defp with_inspector_trace(view, expected_inspections, fun) do
    probes = [
      {Command, :docker, 1},
      {Command, :docker, 2},
      {Command, :docker, 3},
      {Command, :local_endpoint, 0},
      {Command, :resolve_context, 1},
      {Command, :docker_at, 2},
      {Command, :docker_at, 3},
      {Command, :docker_at, 4},
      {Command, :invoke, 4},
      {Port, :open, 2},
      {:erlang, :open_port, 2},
      {System, :cmd, 2},
      {System, :cmd, 3},
      {HarnessForge.Models, :status, 0},
      {Evaluations, :capabilities, 0},
      {HarnessForge.Execution, :probe, 0},
      {Coding, :availability, 0},
      {Coding, :profile, 1},
      {Coding, :profile_digest, 1},
      {Coding, :admit, 1},
      {Coding, :run, 3},
      {Coding, :stop_session, 1},
      {Coding, :cleanup, 1},
      {Coding, :coding_command, 2},
      {Coding, :coding_command, 4},
      {HarnessForge.Execution.CodingTransport, :observe, 0},
      {HarnessForge.Execution.CodingTransport, :verify, 1}
    ]

    marker = {__MODULE__, :trace_marker, 0}
    event = {HarnessForgeWeb.PortalLive, :handle_event, 3}
    inspection = {HarnessForge.Readiness, :for_artifact, 2}
    patterns = probes ++ [marker, event, inspection]
    for {module, _, _} <- patterns, do: Code.ensure_loaded!(module)
    refute Enum.any?(Command.__info__(:functions), fn {name, _} -> name == :run end)
    collector = spawn_link(fn -> trace_collector(%{calls: %{}, spawned: MapSet.new()}) end)

    try do
      matches = for mfa <- patterns, do: {mfa, :erlang.trace_pattern(mfa, true, [:local])}

      assert Enum.all?(matches, fn {_, count} -> count == 1 end),
             "Unsupported trace instrumentation: #{inspect(matches)}"

      IO.puts("Readiness event trace: Command.run/* absent; matched #{inspect(matches)}")
      :erlang.trace(view.pid, true, [:call, :arity, :procs, :set_on_spawn, {:tracer, collector}])
      test_pid = self()

      # Calibrate delivery on the actual LiveView and its spawned child without
      # changing socket state. No command/profile is invoked by calibration.
      :sys.replace_state(view.pid, fn state ->
        apply(__MODULE__, :trace_marker, [])

        child =
          spawn(fn ->
            apply(__MODULE__, :trace_marker, [])
            send(test_pid, {:trace_child_done, self()})
          end)

        send(test_pid, {:trace_calibrated, self(), child})
        state
      end)

      assert_receive {:trace_calibrated, live_pid, child}
      assert live_pid == view.pid
      assert_receive {:trace_child_done, ^child}
      calibrated = trace_snapshot(collector)
      assert calibrated.calls[{view.pid, marker}] == 1
      assert calibrated.calls[{child, marker}] == 1
      assert MapSet.member?(calibrated.spawned, child)
      clear = make_ref()
      send(collector, {:clear, self(), clear})
      assert_receive {:trace_cleared, ^clear}

      fun.()
      measured = trace_snapshot(collector)
      assert measured.calls[{view.pid, inspection}] == expected_inspections
      assert measured.calls[{view.pid, event}] >= expected_inspections

      assert MapSet.equal?(measured.spawned, calibrated.spawned),
             "Inspector introduced a worker; extend provenance before claiming coverage"

      prohibited = for {{pid, mfa}, count} <- measured.calls, mfa in probes, do: {pid, mfa, count}
      assert prohibited == [], "Prohibited inspector calls: #{inspect(prohibited)}"
    after
      snapshot = trace_snapshot(collector)

      for pid <- [view.pid | MapSet.to_list(snapshot.spawned)],
          Process.alive?(pid),
          do: :erlang.trace(pid, false, [:all])

      for mfa <- patterns, do: :erlang.trace_pattern(mfa, false, [:local])
      send(collector, :stop)
    end
  end

  defp trace_snapshot(collector) do
    delivery = :erlang.trace_delivered(:all)
    assert_receive {:trace_delivered, :all, ^delivery}, 1_000
    ref = make_ref()
    send(collector, {:snapshot, self(), ref})
    assert_receive {:trace_snapshot, ^ref, snapshot}, 1_000
    snapshot
  end

  defp trace_collector(state) do
    receive do
      {:trace, pid, :call, {module, function, arity}} when is_integer(arity) ->
        key = {pid, {module, function, arity}}
        trace_collector(%{state | calls: Map.update(state.calls, key, 1, &(&1 + 1))})

      {:trace, _, :spawn, child, _} ->
        trace_collector(%{state | spawned: MapSet.put(state.spawned, child)})

      {:snapshot, caller, ref} ->
        send(caller, {:trace_snapshot, ref, state})
        trace_collector(state)

      {:clear, caller, ref} ->
        send(caller, {:trace_cleared, ref})
        trace_collector(%{state | calls: %{}})

      :stop ->
        :ok

      _ ->
        trace_collector(state)
    end
  end

  defp packages(conn) do
    {:ok, view, _} = live(conn, "/")
    view |> element("#nav-package") |> render_click()
    view
  end

  defp select_package(view, artifact),
    do:
      view
      |> form("#package-readiness-form",
        readiness: %{digest: artifact["digest"]}
      )
      |> render_change()

  defp select_run(view, artifact, run),
    do:
      view
      |> form("#package-readiness-form",
        readiness: %{digest: artifact["digest"], evaluation_id: run["id"]}
      )
      |> render_change()

  defp inspect_pair(view), do: view |> form("#package-readiness-form") |> render_submit()

  defp controls_id(view),
    do:
      view
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("[data-readiness-field=package]")
      |> LazyHTML.attribute("id")
      |> List.first()

  defp envelope(view) do
    doc = view |> render() |> LazyHTML.from_document()
    field = fn name -> doc |> LazyHTML.query(~s([name="readiness[#{name}]"])) end

    selected = fn name ->
      field.(name)
      |> LazyHTML.query("option[selected]")
      |> LazyHTML.attribute("value")
      |> List.first()
    end

    %{
      "readiness" => %{
        "generation" => field.("generation") |> LazyHTML.attribute("value") |> List.first(),
        "digest" => selected.("digest") || "",
        "evaluation_id" => selected.("evaluation_id") || ""
      }
    }
  end

  defp fixture(attrs \\ %{}) do
    {:ok, connection} =
      Evidence.connect(%{
        "name" => "Synthetic readiness fixture",
        "provider" => "local",
        "directory" => Path.join(Workspaces.root(), "evidence")
      })

    {:ok, source} =
      Evidence.import_markdown(connection["id"], %{
        "external_id" => "guide.md",
        "title" => "Synthetic guide",
        "body" => "Review each change before release."
      })

    revision = source["latest_revision"]
    {:ok, citation} = Evidence.citation(revision["id"], 0, byte_size(revision["body"]))

    {:ok, claim} =
      Evidence.create_claim(%{
        "text" => "Review changes deliberately.",
        "citations" => [citation]
      })

    {:ok, _} =
      Decisions.decide(claim["id"], %{
        "actor" => Workspaces.operator(),
        "decision" => "approve",
        "expected_revision_hash" => claim["revision_hash"]
      })

    {:ok, artifact} = Harnesses.build(Map.merge(%{"name" => "readiness-synthetic"}, attrs))
    %{artifact: artifact, source: source}
  end
end
