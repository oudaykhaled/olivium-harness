defmodule HarnessForgeWeb.CompanyAnalysisTest do
  use HarnessForgeWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias HarnessForge.{
    Company,
    CompanyAnalysisFixture,
    Evidence,
    Harnesses,
    Models,
    Repo,
    Workspaces
  }

  alias HarnessForge.Models.Configuration
  alias HarnessForgeWeb.Plugs.OperatorSession

  setup %{conn: conn} do
    previous_root = Application.fetch_env!(:harness_forge, :workspace_root)
    previous_id = Workspaces.current_id()
    previous_plug = Application.get_env(:harness_forge, :model_test_plug)
    id = Ecto.UUID.generate()
    root = Path.join(File.cwd!(), "tmp/company-analysis-web-#{id}")
    Enum.each(~w(artifacts runs tmp), &File.mkdir_p!(Path.join(root, &1)))
    Application.put_env(:harness_forge, :workspace_root, root)
    Application.put_env(:harness_forge, :workspace_id, id)
    Application.put_env(:harness_forge, :model_test_plug, {Req.Test, __MODULE__})
    fixture = CompanyAnalysisFixture.create!(root)
    {:ok, _} = Models.configure(%{"provider" => "ollama", "model" => "synthetic:fixture"})
    stub(fixture.report)

    on_exit(fn ->
      Application.put_env(:harness_forge, :workspace_root, previous_root)
      Application.put_env(:harness_forge, :workspace_id, previous_id)

      if previous_plug,
        do: Application.put_env(:harness_forge, :model_test_plug, previous_plug),
        else: Application.delete_env(:harness_forge, :model_test_plug)

      File.rm_rf!(root)
    end)

    conn = %{conn | host: "localhost", port: 4002}

    {:ok,
     conn: init_test_session(conn, %{"operator_auth" => OperatorSession.new_auth()}),
     fixture: fixture,
     root: root}
  end

  test "scope starts unchecked and shows saved union assignments, captured revisions and unknown coverage",
       %{conn: conn, fixture: f} do
    view = company(conn)
    refute has_element?(view, "#company-analysis-sources input[checked]")

    assert component(view).analysis_draft == %{
             "project_id" => "",
             "source_ids" => [],
             "goal_id" => ""
           }

    view
    |> form("#company-analysis-form", analysis: %{project_id: f.project["id"]})
    |> render_change()

    for source <- f.sources do
      assert has_element?(view, "#company-analysis-source-#{source["id"]}")
      assert has_element?(view, "#company-analysis-sources", source["latest_revision"]["id"])
    end

    assert has_element?(
             view,
             "#company-analysis-coverage",
             "completeness and current policy are unknown"
           )

    assert has_element?(view, "#company-analysis-goal option[value='#{f.goal["id"]}']")
    view |> form("#company-analysis-form") |> render_submit()
    assert has_element?(view, "#company-analysis-error", "2–4 distinct current sources")
    assert {:ok, []} = Evidence.list_claims()
  end

  test "supported status with a declared conflict requires saved resolution; edited exact successor reaches deliberate plan and export",
       %{conn: conn, fixture: f, root: root} do
    report = put_in(f.report, ["recommendation", "status"], "supported")
    owner = self()

    stub(report, fn request ->
      assert request["prompt"] =~ f.uncited_source["latest_revision"]["body"]
      send(owner, :analysis_generated)
    end)

    view = company(conn)
    select(view, f)
    assert component(view).analysis_pins.goal_hash == f.input["goal_content_hash"]
    submit(view)
    assert_receive :analysis_generated
    assert {:ok, [original]} = Evidence.list_claims()
    assert original["basis"]["report"] == report

    assert has_element?(
             view,
             "#company-analysis-original",
             "Structural citation coverage: 3 distinct sources"
           )

    assert has_element?(view, "#company-analysis-original", report["uncertainty"])

    assert has_element?(
             view,
             "#company-analysis-original",
             "Current source name (may have changed)"
           )

    assert has_element?(view, "#company-analysis-original", hd(f.sources)["title"])
    assert has_element?(view, "#company-analysis-resolution[required]")
    refute has_element?(view, "#company-plan-claims input[checked]")
    view |> element("#company-analysis-evidence") |> render_click()

    assert has_element?(
             view,
             "#analysis-origin-#{original["id"]}",
             "Original recommendation status: supported"
           )

    refute has_element?(view, "#goal-origin-#{original["id"]}")
    assert has_element?(view, "#analysis-origin-#{original["id"]}", hd(f.sources)["title"])
    assert has_element?(view, "#approve-#{original["id"]}[disabled]")

    render_click(view, "decide", %{
      "id" => original["id"],
      "revision" => original["revision_hash"],
      "decision" => "approve"
    })

    assert has_element?(view, "#error", "Save a human resolution")
    view |> element("#analysis-edit-#{original["id"]}") |> render_click()

    assert has_element?(
             view,
             "#company-analysis-review",
             report["findings"] |> hd() |> Map.fetch!("statement")
           )

    edited =
      "Reviewed emergency guidance: retain the named reviewer and record the scoped exception."

    view
    |> form("#company-analysis-edit-form",
      analysis_edit: %{
        rule: edited,
        review_resolution:
          "Use the explicitly approved emergency exception only for emergency patches; retain ordinary two-reviewer policy."
      }
    )
    |> render_change()

    assert has_element?(view, "#company-analysis-dirty")
    assert has_element?(view, "#company-analysis-evidence[disabled]")
    event(view, "company_navigate", %{"tab" => "evidence"})
    assert has_element?(view, "#company-analysis-error", "Save or discard")
    view |> form("#company-analysis-edit-form") |> render_submit()
    successor = component(view).analysis_selected
    assert successor["id"] != original["id"]
    assert successor["status"] == "proposed"
    assert successor["basis"]["report"] == report
    assert successor["basis"]["guidance"]["rule"] == edited
    view |> element("#company-analysis-evidence") |> render_click()
    refute has_element?(view, "#approve-#{original["id"]}")

    render_click(view, "decide", %{
      "id" => successor["id"],
      "revision" => original["revision_hash"],
      "decision" => "approve"
    })

    assert has_element?(view, "#error", "revision changed")
    view |> element("#approve-#{successor["id"]}") |> render_click()
    assert {:ok, %{"status" => "approved"}} = Evidence.get_claim(successor["id"])
    view |> element("#nav-company") |> render_click()
    view |> form("#company-plan-form", plan: %{project_id: f.project["id"]}) |> render_change()
    assert has_element?(view, "#company-plan-claims", "Company analysis")
    refute has_element?(view, "#company-plan-claims input[checked]")

    input =
      CompanyAnalysisFixture.plan_attrs(f, successor)
      |> Map.put("claim_refs", [successor["id"] <> ":" <> successor["revision_hash"]])
      |> Map.put("execution", %{"max_turns" => "10", "timeout_seconds" => "120"})
      |> Map.delete("milestones")

    view |> form("#company-plan-form", plan: input) |> render_submit()
    assert {:ok, [plan]} = Company.list_plans()
    assert has_element?(view, "#company-plan-review", "Company analysis")
    assert has_element?(view, "#company-plan-build[disabled]")
    view |> form("#company-plan-decision-form") |> render_submit()
    assert {:ok, %{"status" => "approved"}} = Company.get_plan(plan["id"])
    view |> form("#company-plan-build-form") |> render_submit()
    assert {:ok, [artifact]} = Harnesses.list_artifacts()
    view |> element("#company-open-packages") |> render_click()
    target = Path.join(root, "reviewed-company-export")

    view
    |> form("[id^=package-export-form-][id$='#{artifact["digest"]}']", export: %{target: target})
    |> render_submit()

    assert File.read!(Path.join(target, "AGENTS.md")) =~ edited
    refute File.read!(Path.join(target, "AGENTS.md")) =~ report["recommendation"]["rule"]
    {:ok, fresh, _} = live(conn, "/")
    fresh |> element("#nav-evidence") |> render_click()
    fresh |> element("#analysis-edit-#{successor["id"]}") |> render_click()
    assert component(fresh).analysis_selected["basis"]["report"] == report
    assert component(fresh).analysis_edit["rule"] == edited
  end

  test "authenticated loaded metadata stays scoped and read only with no selected model, recapture and revocation",
       %{conn: conn, fixture: f, root: root} do
    foreign = foreign_records(root)
    assert {:ok, %{"claim" => original}} = HarnessForge.Company.Analysis.analyze(f.input)
    source = hd(f.sources)
    renamed = "CURRENT NAME ONLY <literal markup>"

    source_row = Repo.get!(Evidence.Source, source["id"])
    {:ok, _} = source_row |> Ecto.Changeset.change(title: renamed) |> Repo.update()
    assert {:ok, _} = Models.configure(%{"model" => nil})
    assert {:ok, current} = Evidence.get_source(source["id"])
    assert current["latest_revision"] == source["latest_revision"]
    before_view = table_projections()

    view = company(conn)
    view |> element("#company-analysis-open-#{original["id"]}") |> render_click()
    assert has_element?(view, "#company-analysis-availability", "None selected")
    assert has_element?(view, "#company-analysis-original", renamed)

    assert has_element?(
             view,
             "#company-analysis-original",
             "Current source name (may have changed)"
           )

    assert has_element?(
             view,
             "#company-analysis-original",
             source["latest_revision"]["captured_at"]
           )

    assert has_element?(view, "#company-analysis-original", source["latest_revision"]["id"])
    assert component(view).analysis_selected["basis"] == original["basis"]
    assert_loaded_scope(view, foreign)
    view |> element("#company-analysis-evidence") |> render_click()
    assert has_element?(view, "#analysis-origin-#{original["id"]}", renamed)
    assert has_element?(view, "#approve-#{original["id"]}[disabled]")
    assert_loaded_scope(view, foreign)
    assert table_projections() == before_view
    assert {:ok, ^original} = Evidence.get_claim(original["id"])

    # Deliberate fixture mutation is outside the view-only comparison window.
    newer_name = "NEWER CAPTURE NAME MUST NOT LABEL THE ORIGINAL PIN"

    assert {:ok, newer} =
             Evidence.import_markdown(f.connection["id"], %{
               "external_id" => source["external_id"],
               "title" => newer_name,
               "body" => source["latest_revision"]["body"] <> " Later synthetic capture."
             })

    assert newer["latest_revision"]["id"] != source["latest_revision"]["id"]
    # The Sandbox keeps this deliberate FTS5 recapture inside an outer
    # transaction. A savepoint flushes its deferred shadow-table index before
    # freezing a raw physical baseline; no logical or shadow table is excluded.
    assert {:ok, :ok} = Repo.transaction(fn -> :ok end)
    after_recapture = table_projections()
    refreshed = company(conn)
    refreshed |> element("#company-analysis-open-#{original["id"]}") |> render_click()

    # Current guidance review now refuses stale authority before rendering the
    # original report. Read-only immutable history remains separate in Evidence.
    refute has_element?(refreshed, "#company-analysis-original")
    assert has_element?(refreshed, "#company-analysis-error", "changed")

    refute has_element?(refreshed, "#company-analysis-original", newer_name)
    refute has_element?(refreshed, "#company-analysis-original", renamed)
    refreshed |> element("#nav-evidence") |> render_click()
    selector = "#analysis-origin-#{original["id"]}"

    assert has_element?(
             refreshed,
             selector,
             "Current capture details are not shown from the loaded metadata"
           )

    assert has_element?(refreshed, selector, source["latest_revision"]["id"])
    refute has_element?(refreshed, selector, newer_name)
    refute has_element?(refreshed, selector, renamed)
    actual_recapture = table_projections()

    differences =
      Map.new(
        Enum.filter(actual_recapture, fn {key, value} -> value != after_recapture[key] end),
        fn {key, value} ->
          {key, %{added: value -- after_recapture[key], removed: after_recapture[key] -- value}}
        end
      )

    assert actual_recapture == after_recapture,
           inspect(differences, limit: :infinity, printable_limit: :infinity)

    assert {:ok, after_change} = Evidence.get_claim(original["id"])
    assert after_change["basis"] == original["basis"]
    assert after_change["citations"] == original["citations"]

    assert {:ok, _} = Evidence.revoke_connection(f.connection["id"])
    after_revoke = table_projections()
    revoked = company(conn)
    revoked |> element("#company-analysis-open-#{original["id"]}") |> render_click()

    refute has_element?(revoked, "#company-analysis-original")
    assert has_element?(revoked, "#company-analysis-error", "changed")

    refute has_element?(
             revoked,
             "#company-analysis-original",
             "Current source name (may have changed)"
           )

    refute has_element?(revoked, "#company-analysis-original a")
    revoked |> element("#nav-evidence") |> render_click()

    assert has_element?(
             revoked,
             selector,
             "Current capture details are not shown from the loaded metadata"
           )

    refute has_element?(revoked, selector, "Current source name (may have changed)")
    refute has_element?(revoked, selector <> " a")
    assert_loaded_scope(revoked, foreign)
    assert table_projections() == after_revoke
  end

  test "chosen captures are pinned and stale revisions refuse rather than silently repinning", %{
    conn: conn,
    fixture: f
  } do
    view = company(conn)
    select(view, f)
    old = component(view).analysis_pins
    source = hd(f.sources)

    {:ok, _} =
      Evidence.import_markdown(f.connection["id"], %{
        "external_id" => source["external_id"],
        "title" => source["title"],
        "body" => source["latest_revision"]["body"] <> " Updated capture."
      })

    send(view.pid, {:company_changed, "updated capture"})
    assert component(view).analysis_pins == old
    assert has_element?(view, "#company-analysis-sources", "Selected capture changed")
    submit(view)
    assert has_element?(view, "#company-analysis-error", "context changed")
    assert {:ok, []} = Evidence.list_claims()
  end

  for outcome <- [:proposed, :abstained] do
    @outcome outcome
    test "duplicate submit and tab departure ignore late #{@outcome} callbacks", %{
      conn: conn,
      fixture: f
    } do
      report =
        if @outcome == :abstained, do: Map.put(f.report, "recommendation", nil), else: f.report

      owner = self()

      stub(report, fn _ ->
        send(owner, {:generation_started, self()})

        receive do
          :finish_analysis -> :ok
        after
          5_000 -> raise "Synthetic request was not released"
        end
      end)

      view = company(conn)
      select(view, f)
      view |> form("#company-analysis-form") |> render_submit()
      assert_receive {:generation_started, worker}, 2_000
      token = component(view).analysis_pending
      event(view, "company_analysis_start", %{"analysis" => selection(f)})
      assert component(view).analysis_pending == token
      refute_receive {:generation_started, _}, 50
      view |> element("#nav-evidence") |> render_click()
      send(worker, :finish_analysis)
      render_async(view)
      view |> element("#nav-company") |> render_click()
      assert component(view).analysis_selected == nil
      assert component(view).analysis_pending == nil
      assert component(view).analysis_draft == HarnessForgeWeb.Company.Analysis.empty()
      refute has_element?(view, "#company-analysis-result")
      assert {:ok, claims} = Evidence.list_claims()
      assert length(claims) == if(@outcome == :proposed, do: 1, else: 0)
    end
  end

  test "privacy reset and remount forget unsaved analysis and refuse captured generation", %{
    conn: conn,
    fixture: f
  } do
    view = company(conn)
    select(view, f)
    captured = envelope(view, %{"analysis" => selection(f)})
    send(view.pid, :company_cache_reset)
    assert component(view).analysis_pending == nil
    assert component(view).analysis_selected == nil
    assert component(view).analysis_draft == HarnessForgeWeb.Company.Analysis.empty()
    view |> with_target("#company-panel") |> render_hook("company_analysis_start", captured)
    assert has_element?(view, "#company-notice", "Use the refreshed controls")
    assert {:ok, []} = Evidence.list_claims()
    {:ok, fresh, _} = live(conn, "/")
    fresh |> element("#nav-company") |> render_click()
    fresh |> with_target("#company-panel") |> render_hook("company_analysis_start", captured)
    assert component(fresh).analysis_pending == nil
    assert {:ok, []} = Evidence.list_claims()
  end

  test "a queued start from before Company departure cannot dispatch after returning", %{
    conn: conn,
    fixture: f
  } do
    view = company(conn)
    select(view, f)
    state = component(view)

    late = %{
      generation: state.company_event_generation,
      request_id: Ecto.UUID.generate(),
      run_id: Ecto.UUID.generate(),
      input: f.input,
      reset_token: state.company_reset_token
    }

    view |> element("#nav-evidence") |> render_click()
    view |> element("#nav-company") |> render_click()
    send(view.pid, {:company_analysis_start, late})
    render(view)
    assert :sys.get_state(view.pid).socket.assigns.company_analysis_pending == nil
    assert component(view).analysis_pending == nil
    assert {:ok, []} = Evidence.list_claims()
  end

  test "operator revocation refuses targeted analysis before dispatch", %{conn: conn, fixture: f} do
    view = company(conn)
    select(view, f)
    captured = envelope(view, %{"analysis" => selection(f)})
    previous = :sys.get_state(Workspaces)
    :sys.replace_state(Workspaces, &%{&1 | epoch: "revoked-company-analysis-session"})
    on_exit(fn -> :sys.replace_state(Workspaces, fn _ -> previous end) end)

    assert {:error, {:redirect, %{to: "/login"}}} =
             view
             |> with_target("#company-panel")
             |> render_hook("company_analysis_start", captured)

    assert {:ok, []} = Evidence.list_claims()
  end

  test "cloud company context has its own explicit checkbox in actual configuration form", %{
    conn: conn,
    fixture: f
  } do
    view = company(conn)
    view |> element("#nav-connections") |> render_click()
    view |> form("#model-form", model: %{provider: "openai_responses"}) |> render_change()
    assert has_element?(view, "#model-company-context-consent:not([checked])")

    input = %{
      provider: "openai_responses",
      model: "synthetic-fixture",
      credential_env: "HARNESSFORGE_SYNTHETIC_UI_KEY",
      input_price: "1",
      output_price: "1",
      source_ids: Enum.map(f.sources, & &1["id"]),
      cloud_consent_ack: "true"
    }

    view |> form("#model-form", model: input) |> render_submit()
    assert Configuration.get()["cloud_consent"]["data_categories"] == ["source_body"]

    view
    |> form("#model-form", model: Map.put(input, :company_context_consent_ack, "true"))
    |> render_submit()

    assert Configuration.get()["cloud_consent"]["data_categories"] == [
             "source_body",
             "company_context"
           ]

    assert {:ok, []} = Evidence.list_claims()
  end

  defp foreign_records(root) do
    previous_id = Workspaces.current_id()

    try do
      Application.put_env(:harness_forge, :workspace_id, Ecto.UUID.generate())
      directory = Path.join(root, "foreign-synthetic-documents")
      File.mkdir_p!(directory)

      {:ok, connection} =
        Evidence.connect(%{
          "name" => "FOREIGN WORKSPACE CANARY",
          "provider" => "local",
          "directory" => directory
        })

      {:ok, source} =
        Evidence.import_markdown(connection["id"], %{
          "external_id" => "foreign.md",
          "title" => "FOREIGN WORKSPACE CANARY",
          "body" =>
            "Foreign synthetic evidence must stay outside the authenticated loaded workspace."
        })

      {:ok, citation} = Evidence.citation(source["latest_revision"]["id"], 0, 7)

      {:ok, claim} =
        Evidence.create_claim(%{"text" => "FOREIGN WORKSPACE CANARY", "citations" => [citation]})

      %{source: source, claim: claim}
    after
      Application.put_env(:harness_forge, :workspace_id, previous_id)
    end
  end

  defp assert_loaded_scope(view, foreign) do
    socket = :sys.get_state(view.pid).socket
    refute Enum.any?(socket.assigns.sources, &(&1["id"] == foreign.source["id"]))
    refute Enum.any?(socket.assigns.claims, &(&1["id"] == foreign.claim["id"]))
    refute render(view) =~ "FOREIGN WORKSPACE CANARY"
  end

  defp table_projections do
    {:ok, %{rows: tables}} =
      Repo.query(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
      )

    Map.new(tables, fn [name] ->
      quoted = "\"" <> String.replace(name, "\"", "\"\"") <> "\""
      {:ok, %{rows: rows}} = Repo.query("SELECT * FROM " <> quoted)
      {name, Enum.sort(rows)}
    end)
  end

  defp company(conn) do
    {:ok, view, _} = live(conn, "/")
    Req.Test.allow(__MODULE__, self(), view.pid)
    view |> element("#nav-company") |> render_click()
    view |> element("#company-toggle-analysis") |> render_click()
    view
  end

  defp select(view, f) do
    view
    |> form("#company-analysis-form", analysis: %{project_id: f.project["id"]})
    |> render_change()

    view |> form("#company-analysis-form", analysis: selection(f)) |> render_change()
  end

  defp selection(f),
    do: %{
      "project_id" => f.project["id"],
      "source_ids" => Enum.map(f.sources, & &1["id"]),
      "goal_id" => f.goal["id"]
    }

  defp submit(view) do
    view |> form("#company-analysis-form") |> render_submit()
    render_async(view)
  end

  defp event(view, name, attrs),
    do: view |> with_target("#company-panel") |> render_hook(name, envelope(view, attrs))

  defp envelope(view, attrs),
    do: Map.put(attrs, "company_event_generation", component(view).company_event_generation)

  defp component(view) do
    render(view)
    %{components: {components, _, _}} = :sys.get_state(view.pid)

    {_, "company-builder", assigns, _, _} =
      Enum.find_value(components, fn {_cid, entry} ->
        if elem(entry, 0) == HarnessForgeWeb.CompanyPanel, do: entry
      end)

    assigns
  end

  defp stub(report, callback \\ fn _ -> :ok end) do
    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/api/tags" ->
          Req.Test.json(conn, %{"models" => [%{"name" => "synthetic:fixture"}]})

        "/api/generate" ->
          {:ok, bytes, conn} = Plug.Conn.read_body(conn)
          callback.(Jason.decode!(bytes))
          Req.Test.json(conn, CompanyAnalysisFixture.response(report))
      end
    end)
  end
end
