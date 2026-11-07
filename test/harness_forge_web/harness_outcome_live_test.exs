defmodule HarnessForgeWeb.HarnessOutcomeLiveTest do
  use HarnessForgeWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias HarnessForge.{
    Company,
    CompanyAnalysisFixture,
    Decisions,
    Evidence,
    Evaluations,
    Harnesses,
    Repo,
    Workspaces
  }

  alias HarnessForgeWeb.Plugs.OperatorSession

  setup %{conn: conn} do
    previous = {Workspaces.root(), Workspaces.current_id()}
    id = Ecto.UUID.generate()
    root = Path.join(File.cwd!(), "tmp/harness-outcome-web-#{id}")
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

  test "Company home leads through exact plan approval, generated files and a byte-exact browser ZIP",
       c do
    {_, claim, plan} = proposed_plan(c.root)
    {:ok, view, _} = live(c.conn, "/")
    assert has_element?(view, "#company-panel")
    assert has_element?(view, "#nav-company[aria-current=page]", "Home")

    for {tab, label} <- [
          {"connections", "Sources"},
          {"evidence", "Review"},
          {"package", "Your harness"},
          {"evaluations", "Checks"}
        ],
        do:
          assert(
            has_element?(view, "nav[aria-label='Company harness journey'] #nav-#{tab}", label)
          )

    refute has_element?(view, "nav[aria-label='Company harness journey'] #nav-chat")
    assert has_element?(view, "#workspace-tools #nav-chat")

    view |> element("#company-plan-select-#{plan["id"]}") |> render_click()
    assert has_element?(view, "#company-plan-build[disabled]")
    assert {:error, :plan_not_approved} = Company.build_inputs(plan["id"])
    view |> form("#company-plan-decision-form") |> render_submit()
    assert {:ok, %{"status" => "approved"}} = Company.get_plan(plan["id"])
    assert {:ok, %{"status" => "approved"}} = Evidence.get_claim(claim["id"])
    view |> form("#company-plan-build-form") |> render_submit()
    assert {:ok, [artifact]} = Harnesses.list_artifacts()
    path = "/harnesses/" <> artifact["digest"]
    assert has_element?(view, "#company-built-open[href='#{path}']")
    assert has_element?(view, "#company-built-download[href='#{path}/download']")

    view |> element("#nav-package") |> render_click()
    assert has_element?(view, "#artifact-preview-#{artifact["digest"]}[href='#{path}']")
    assert has_element?(view, "#package-export-options-#{artifact["digest"]} summary", "Advanced")

    {:ok, preview, html} = live(c.conn, path)
    assert has_element?(preview, "#harness-name", plan["payload"]["name"])
    assert has_element?(preview, "#harness-download[href='#{path}/download']")

    for filename <- Map.keys(artifact["files"]),
        do: assert(has_element?(preview, "#harness-file-tree code", filename))

    assert position(html, "harness-download") < position(html, "harness-journey")
    assert position(html, "harness-files") < position(html, "harness-proof")
    assert position(html, "harness-files") < position(html, "harness-recorded-checks")
    assert has_element?(preview, "#harness-journey[aria-label='Harness evidence and next steps']")
    assert has_element?(preview, "#harness-journey li[data-state=unknown]", "Task outcome")
    assert has_element?(preview, "#harness-journey li[data-state=unknown]", "Unobserved here")

    assert has_element?(
             preview,
             "#harness-files details[open] pre[tabindex='0'][aria-label='Generated text: AGENTS.md']"
           )

    refute has_element?(preview, "#harness-proof[open]")
    assert has_element?(preview, "#harness-proof", "Representative-task outcome")
    assert has_element?(preview, "#harness-proof", "Unobserved here")
    assert has_element?(preview, "#harness-recorded-empty", "No matching recorded checks")
    assert html =~ "&lt;script&gt;"
    refute html =~ "<script>alert('synthetic-preview')</script>"
    refute has_element?(preview, "form input[name='export[target]']")

    downloaded = get(c.conn, path <> "/download")
    assert byte_size(response(downloaded, 200)) > 0
    assert get_resp_header(downloaded, "cache-control") == ["no-store"]
    {:ok, entries} = :zip.extract(downloaded.resp_body, [:memory])

    assert Map.new(entries, fn {name, bytes} -> {List.to_string(name), bytes} end) ==
             artifact["files"]

    assert {:ok, []} = HarnessForge.Evaluations.list_runs()
    assert {:ok, []} = HarnessForge.Releases.list()
  end

  test "preview rejects missing or foreign sessions and unavailable digests without file payload",
       c do
    artifact = built(c.root)
    path = "/harnesses/" <> artifact["digest"]
    anonymous = %{build_conn() | host: "localhost", port: 4002}
    assert {:error, {:redirect, %{to: "/login"}}} = live(anonymous, path)

    foreign =
      init_test_session(anonymous, %{
        "operator_auth" =>
          OperatorSession.new_auth()
          |> Map.put("workspace_id", Ecto.UUID.generate())
      })

    assert {:error, {:redirect, %{to: "/login"}}} = live(foreign, path)
    {:ok, view, html} = live(c.conn, "/harnesses/" <> String.duplicate("0", 64))
    assert has_element?(view, "#harness-recovery-title", "Needs a refresh")
    assert has_element?(view, "#harness-unavailable[role=alert]")
    assert has_element?(view, "#harness-review-inputs", "Review inputs")
    refute has_element?(view, "#harness-preview")
    refute has_element?(view, "#harness-files")
    refute has_element?(view, "#harness-download")
    refute html =~ "synthetic-preview"
  end

  test "actual Codex checks show historical static PASS and runtime/task BLOCKED beside current unobserved qualification",
       c do
    # Real checks stop before dispatch: offline smoke is unavailable for Codex,
    # and a managed task needs an explicitly selected local model.
    artifact = built(c.root, %{"runtime" => "codex", "runtime_version" => "0.156.0"})
    assert get_in(artifact, ["spec", "spec", "runtime", "name"]) == "codex"

    run_ids =
      for kind <- [:static_integrity, :runtime_smoke, :task] do
        {:ok, run} = Evaluations.run(artifact["digest"], kind: kind)
        run["id"]
      end

    {:ok, view, _} = live(c.conn, "/harnesses/" <> artifact["digest"])

    assert has_element?(
             view,
             "#harness-recorded-checks-title",
             "Previously recorded checks for this exact harness"
           )

    assert has_element?(
             view,
             "#harness-recorded-checks [data-kind=static_integrity][data-outcome=passed]",
             "PASS"
           )

    for kind <- ~w(runtime_smoke task) do
      assert has_element?(
               view,
               "#harness-recorded-checks [data-kind=#{kind}][data-outcome=blocked]",
               "BLOCKED"
             )

      assert has_element?(
               view,
               "#harness-recorded-checks [data-kind=#{kind}]",
               if(kind == "task", do: "No selected model", else: "no managed execution backend")
             )
    end

    for id <- run_ids, do: assert(has_element?(view, "#harness-recorded-identities code", id))
    assert has_element?(view, "#harness-recorded-checks time[datetime]")
    assert has_element?(view, "#harness-journey li[data-state=unknown]", "Unobserved here")
    assert has_element?(view, "#harness-last-recorded-task[data-outcome=blocked]", "BLOCKED")

    assert has_element?(
             view,
             "#harness-recorded-checks",
             "do not establish current applicability"
           )

    assert has_element?(
             view,
             "#harness-proof",
             "Unobserved here. Generated files do not establish task success."
           )

    assert has_element?(
             view,
             "#harness-proof",
             "Unobserved here. Review the separate checks and release gates."
           )

    assert has_element?(view, "#harness-download")
    assert {:ok, []} = HarnessForge.Releases.list()
  end

  test "historical task outcomes never upgrade the current task stage or hide an older blocked check",
       c do
    artifact = built(c.root)
    {:ok, preview} = HarnessForgeWeb.HarnessDelivery.preview(artifact["digest"])

    # Presentation fixtures only. No passing agent execution is established or
    # persisted by these historical rows.
    for outcome <- ~w(passed blocked) do
      rows =
        for {kind, result} <- [
              {"task", outcome},
              {"static_integrity", "passed"},
              {"runtime_smoke", "passed"},
              {"task", "blocked"}
            ] do
          %{
            "id" => Ecto.UUID.generate(),
            "kind" => kind,
            "outcome" => result,
            "inserted_at" => "2026-11-04T12:00:00Z",
            "reason" => nil
          }
        end

      html = history_html(preview, %{"status" => "available", "rows" => rows})
      document = LazyHTML.from_document(html)
      current_task = LazyHTML.query(document, "#harness-journey li[data-state=unknown]")
      assert Enum.count(current_task) == 1
      assert LazyHTML.text(current_task) =~ "Task outcome"
      assert LazyHTML.text(current_task) =~ "Unobserved here"

      last_task = LazyHTML.query(document, "#harness-last-recorded-task")
      assert LazyHTML.attribute(last_task, "data-outcome") == [outcome]
      assert LazyHTML.text(last_task) =~ "Last recorded task:"
      assert LazyHTML.text(last_task) =~ if(outcome == "passed", do: "PASS", else: "BLOCKED")

      older_blocked =
        LazyHTML.query(
          document,
          "#harness-recorded-more[open] [data-kind=task][data-outcome=blocked]"
        )

      assert Enum.count(older_blocked) == 1

      assert position(html, "harness-files") < position(html, "harness-recorded-checks")
    end

    assert {:ok, []} = Evaluations.list_runs()
  end

  test "history presentation distinguishes empty, unavailable and unknown without displaying arbitrary stored values",
       c do
    artifact = built(c.root)
    {:ok, preview} = HarnessForgeWeb.HarnessDelivery.preview(artifact["digest"])
    # Presentation-only contract cases. These maps never enter load_current/1
    # or supply artifact authority; real history selection is tested separately.
    html = history_html(preview, %{"status" => "unavailable", "rows" => []})
    assert html =~ "Recorded check history is unavailable"
    refute html =~ "No matching recorded checks"
    html = history_html(preview, %{"status" => "available", "rows" => []})
    assert html =~ "No matching recorded checks"
    html = history_html(preview, %{"status" => "invalid", "rows" => []})
    assert html =~ "Recorded check history is unknown"
    canary = "<script>PRIVATE_UNKNOWN_REASON_CANARY</script>"

    malformed = %{
      "id" => canary,
      "kind" => canary,
      "outcome" => canary,
      "inserted_at" => canary,
      "reason" => canary
    }

    html = history_html(preview, %{"status" => "available", "rows" => [malformed, nil]})
    assert html =~ "Unknown check"
    assert html =~ "Unknown date"
    assert html =~ "Unknown reason"
    refute html =~ "PRIVATE_UNKNOWN_REASON_CANARY"
  end

  test "privacy invalidation clears rendered files and a pending purge refuses a fresh read", c do
    artifact = built(c.root)
    {:ok, view, _} = live(c.conn, "/harnesses/" <> artifact["digest"])
    assert has_element?(view, "#harness-preview")
    send(view.pid, :corpus_cache_reset)
    render(view)
    refute has_element?(view, "#harness-preview")
    refute has_element?(view, "#harness-download")
    view |> element("#harness-refresh") |> render_click()
    assert has_element?(view, "#harness-preview")

    now = DateTime.utc_now() |> DateTime.to_iso8601()

    Repo.query!(
      "INSERT INTO privacy_operations (id,workspace_id,kind,target_id,state,plan,inserted_at,updated_at) VALUES (?,?,?,?,?,?,?,?)",
      [
        Ecto.UUID.generate(),
        Workspaces.current_id(),
        "workspace",
        Workspaces.current_id(),
        "prepared",
        "{}",
        now,
        now
      ]
    )

    view |> element("#harness-refresh") |> render_click()
    assert has_element?(view, "#harness-unavailable")
    refute has_element?(view, "#harness-preview")
    refute has_element?(view, "#harness-file-tree")
    refute has_element?(view, "#harness-download")
    refute render(view) =~ "synthetic-preview"
  end

  test "task evidence is escaped, exact-artifact scoped and cleared on privacy invalidation", c do
    artifact = built(c.root)
    {:ok, run} = Evaluations.run(artifact["digest"], kind: :static_integrity)
    # Presentation fixture only: this does not assert real agent execution.
    record =
      Map.put(run, "checks", [
        %{
          "name" => "Presentation fixture",
          "outcome" => "failed",
          "evidence" => %{
            "version" => 1,
            "solver_stopped" => true,
            "candidate_before" => "before-code",
            "candidate_after" => "<script>untrusted-output</script>",
            "grader_output" => "protected-test-output",
            "agent_output" => "\e[31magent-output\e[0m"
          }
        }
      ])

    Repo.query!("UPDATE evaluation_runs SET result=? WHERE id=?", [
      Jason.encode!(record),
      run["id"]
    ])

    {:ok, view, _} = live(c.conn, "/harnesses/" <> artifact["digest"])
    html = view |> element("button[phx-click=inspect_check]") |> render_click()

    assert has_element?(
             view,
             "#harness-check-details",
             "Company task benefit and release qualification require separate checks"
           )

    assert has_element?(view, "#harness-check-details pre", "protected-test-output")
    assert html =~ "&lt;script&gt;untrusted-output&lt;/script&gt;"
    refute html =~ "<script>untrusted-output</script>"
    refute html =~ "\e[31m"

    assert {:error, :harness_unavailable} =
             HarnessForgeWeb.HarnessDelivery.check_details(
               artifact["digest"],
               Ecto.UUID.generate()
             )

    send(view.pid, :corpus_cache_reset)
    render(view)
    refute has_element?(view, "#harness-check-details")
    refute render(view) =~ "protected-test-output"

    {:ok, other} =
      Harnesses.build(%{
        "name" => "other-evidence-harness",
        "runtime" => "codex",
        "runtime_version" => "0.156.0"
      })

    assert {:error, :harness_unavailable} =
             HarnessForgeWeb.HarnessDelivery.check_details(other["digest"], run["id"])

    now = DateTime.utc_now() |> DateTime.to_iso8601()

    Repo.query!(
      "INSERT INTO privacy_operations (id,workspace_id,kind,target_id,state,plan,inserted_at,updated_at) VALUES (?,?,?,?,?,?,?,?)",
      [
        Ecto.UUID.generate(),
        Workspaces.current_id(),
        "workspace",
        Workspaces.current_id(),
        "prepared",
        "{}",
        now,
        now
      ]
    )

    assert {:error, :harness_unavailable} =
             HarnessForgeWeb.HarnessDelivery.check_details(artifact["digest"], run["id"])
  end

  test "revoked source cannot reuse preview bytes and session invalidation redirects", c do
    {fixture, _, plan} = proposed_plan(c.root)
    {:ok, _} = Company.decide_plan(plan["id"], CompanyAnalysisFixture.decision(plan))
    {:ok, artifact} = Harnesses.build_plan(plan["id"], plan["revision_hash"])
    {:ok, view, _} = live(c.conn, "/harnesses/" <> artifact["digest"])
    {:ok, _} = Evidence.revoke_source(hd(fixture.sources)["id"])
    view |> element("#harness-refresh") |> render_click()
    refute has_element?(view, "#harness-preview")
    assert has_element?(view, "#harness-unavailable")
    send(view.pid, :operator_session_revoked)
    assert_redirect(view, "/login")
  end

  defp history_html(preview, history) do
    render_component(&HarnessForgeWeb.HarnessLive.render/1,
      harness: put_in(preview, ["verification", "recorded_checks"], history),
      message: nil
    )
  end

  defp position(html, id), do: :binary.match(html, "id=\"#{id}\"") |> elem(0)

  defp proposed_plan(root, overrides \\ %{}) do
    fixture = CompanyAnalysisFixture.create!(root)
    source = hd(fixture.sources)
    revision = source["latest_revision"]
    {:ok, citation} = Evidence.citation(revision["id"], 0, byte_size(revision["body"]))

    {:ok, claim} =
      Evidence.create_claim(%{
        "text" => "Review <script>alert('synthetic-preview')</script> as literal text.",
        "citations" => [citation]
      })

    {:ok, claim} = Decisions.decide(claim["id"], CompanyAnalysisFixture.decision(claim))

    {:ok, plan} =
      Company.create_plan(Map.merge(CompanyAnalysisFixture.plan_attrs(fixture, claim), overrides))

    {fixture, claim, plan}
  end

  defp built(root, overrides \\ %{}) do
    {_, _, plan} = proposed_plan(root, overrides)
    {:ok, _} = Company.decide_plan(plan["id"], CompanyAnalysisFixture.decision(plan))
    {:ok, artifact} = Harnesses.build_plan(plan["id"], plan["revision_hash"])
    artifact
  end
end
