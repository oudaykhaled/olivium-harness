defmodule HarnessForgeWeb.SetupJourneyContextTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias HarnessForge.{Company, Evidence, Goals, Repo, Workspaces}
  alias HarnessForge.Company.{SetupRunPreparation, SetupRuns, SetupSessions}
  alias HarnessForge.Evidence.Corpora
  alias HarnessForge.SetupRunModelsFixture, as: F
  alias HarnessForgeWeb.Plugs.OperatorSession

  @endpoint HarnessForgeWeb.Endpoint
  @moduletag :committed

  setup do
    context = F.setup!()

    conn =
      build_conn()
      |> Map.merge(%{host: "localhost", port: 4002})
      |> init_test_session(%{"operator_auth" => OperatorSession.new_auth()})

    {:ok, Map.put(context, :conn, conn)}
  end

  test "sources return to the exact owned saved setup without changing scope or dispatching", c do
    {:ok, saved} = SetupSessions.get(%{"id" => c.session_id}, F.caller())
    setup_path = "/setup/#{saved["id"]}/#{saved["step"]}"

    sources_path =
      "/?" <> URI.encode_query(%{"view" => "connections", "setup_return" => saved["id"]})

    before = F.rows("model_requests")
    {:ok, setup, _} = live(c.conn, setup_path)
    assert has_element?(setup, "#setup-analysis-connections[href='#{sources_path}']")
    {:ok, sources, _} = live(c.conn, sources_path)
    assert has_element?(sources, "#connections-panel")
    assert has_element?(sources, "#journey-return-setup[href='#{setup_path}']")
    {:ok, again} = SetupSessions.get(%{"id" => c.session_id}, F.caller())
    assert again["selection"] == saved["selection"]
    assert again["version"] == saved["version"]
    assert F.rows("model_requests") == before

    {:ok, unavailable, _} =
      live(c.conn, "/?view=connections&setup_return=" <> Ecto.UUID.generate())

    refute has_element?(unavailable, "#journey-return-setup")
    assert has_element?(unavailable, "#error", "saved setup is unavailable")
  end

  test "corpus GET preselects only current project and goal and retains explicit return without dispatch",
       c do
    {:ok, saved} = SetupSessions.get(%{"id" => c.session_id}, F.caller())
    url = corpus_url(saved)
    before = navigation_counts()
    sources = "/?" <> URI.encode_query(%{"view" => "connections", "setup_return" => saved["id"]})

    for _ <- 1..2 do
      {:ok, view, _} = live(c.conn, url)

      assert has_element?(
               view,
               "#corpus-return-setup[href='/setup/#{saved["id"]}/#{saved["step"]}']"
             )

      assert has_element?(view, "#corpus-manage-connections[href='#{sources}']")

      assert socket(view).state.selection == %{
               "connection_id" => "",
               "project_id" => c.fixture.project["id"],
               "goal_id" => c.fixture.goal["id"],
               "goal_content_hash" => Goals.content_hash(c.fixture.goal)
             }

      assert socket(view).state.scope == nil
      assert socket(view).scope_token == nil
      assert socket(view).large.capture == nil
      assert socket(view).large.stage == nil
    end

    assert {:ok, ^saved} = SetupSessions.get(%{"id" => c.session_id}, F.caller())
    assert navigation_counts() == before
  end

  test "invalid, foreign and stale setup context never supplies source selections", c do
    before = navigation_counts()

    for id <- ["not-a-uuid", Ecto.UUID.generate(), "https://example.test/setup"] do
      {:ok, view, _} =
        live(c.conn, "/company/corpus?" <> URI.encode_query(%{"setup_return" => id}))

      refute has_element?(view, "#corpus-return-setup")
      assert has_element?(view, "#corpus-error", "Saved setup is unavailable")
      assert socket(view).state.selection["project_id"] == ""
      assert socket(view).state.scope == nil
    end

    {:ok, foreign} = SetupSessions.create(%{}, F.caller())

    Repo.query!("UPDATE setup_sessions SET owner=? WHERE id=?", [
      "another-operator",
      foreign["id"]
    ])

    {:ok, denied, _} = live(c.conn, corpus_url(foreign))
    refute has_element?(denied, "#corpus-return-setup")
    assert has_element?(denied, "#corpus-error", "Saved setup is unavailable")

    Repo.query!("UPDATE setup_sessions SET owner=?,workspace_id=? WHERE id=?", [
      Workspaces.operator(),
      Ecto.UUID.generate(),
      foreign["id"]
    ])

    try do
      {:ok, denied, _} = live(c.conn, corpus_url(foreign))
      refute has_element?(denied, "#corpus-return-setup")
      assert socket(denied).state.selection["project_id"] == ""
    after
      Repo.query!("UPDATE setup_sessions SET workspace_id=? WHERE id=?", [
        c.workspace,
        foreign["id"]
      ])
    end

    # Only the explicit fixture setup creation above changed the count.
    assert navigation_counts() == Map.update!(before, "setup_sessions", &(&1 + 1))
    {:ok, saved} = SetupSessions.get(%{"id" => c.session_id}, F.caller())

    {:ok, _} =
      Company.update_project(
        c.fixture.project["id"],
        Map.merge(c.fixture.project["payload"], %{
          "name" => "Changed public synthetic project",
          "expected_content_hash" => c.fixture.project["content_hash"]
        })
      )

    {:ok, stale, _} = live(c.conn, corpus_url(saved))
    assert has_element?(stale, "#corpus-return-setup")
    assert has_element?(stale, "#corpus-setup-context-unavailable")
    assert socket(stale).state.selection["project_id"] == ""
    assert socket(stale).state.selection["connection_id"] == ""
    assert socket(stale).state.scope == nil

    send(stale.pid, :corpus_cache_reset)
    render(stale)
    refute has_element?(stale, "#corpus-return-setup")
    assert socket(stale).state.selection["project_id"] == ""
  end

  test "explicit coverage route retains setup return and exact declaration allowlist", c do
    {:ok, saved} = SetupSessions.get(%{"id" => c.session_id}, F.caller())

    {:ok, capture} =
      Evidence.Capture.capture_status(c.view["run"]["capture_ref"]["id"], %{}, F.caller())

    {:ok, context} =
      Corpora.requirements_context(
        c.corpus["id"],
        c.fixture.project["id"],
        c.fixture.goal["id"],
        Goals.content_hash(c.fixture.goal),
        F.caller()
      )

    {:ok, declaration} =
      Corpora.declare_requirements(
        c.corpus["id"],
        context["expected"],
        %{
          "project_id" => c.fixture.project["id"],
          "goal_id" => c.fixture.goal["id"],
          "primary_connection_id" => c.fixture.connection["id"],
          "entries" => [
            %{
              "connection_id" => c.fixture.connection["id"],
              "requirement" => "required",
              "capture_run_id" => capture["run_id"],
              "capture_revision" => capture["revision"]
            }
          ]
        },
        F.caller()
      )

    before = navigation_counts()

    params = %{
      "declaration" => declaration["id"],
      "declaration_digest" => declaration["digest"],
      "setup_return" => saved["id"]
    }

    {:ok, view, _} = live(c.conn, "/company/corpus?" <> URI.encode_query(params))
    assert has_element?(view, "#corpus-return-setup")
    assert socket(view).large.declaration["id"] == declaration["id"]
    assert socket(view).state.selection["connection_id"] == c.fixture.connection["id"]
    view |> form("#corpus-requirements-form") |> render_submit()
    patch = assert_patch(view)
    patched = patch |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert Map.keys(patched) |> Enum.sort() == ~w(declaration declaration_digest setup_return)
    assert patched["setup_return"] == saved["id"]
    assert has_element?(view, "#corpus-return-setup")

    {:ok, refused, _} =
      live(c.conn, "/company/corpus?" <> URI.encode_query(Map.put(params, "capture", "forged")))

    assert has_element?(refused, "#corpus-return-setup")
    assert socket(refused).large.declaration == nil
    assert socket(refused).state.scope == nil
    assert navigation_counts() == before
  end

  test "explicit restriction receipt preserves only validated navigation through its canonical patch",
       c do
    {:ok, saved} = SetupSessions.get(%{"id" => c.session_id}, F.caller())
    {:ok, view, _} = live(c.conn, corpus_url(saved))

    view
    |> form("#corpus-scope-form", scope: %{"connection_id" => c.fixture.connection["id"]})
    |> render_change()

    view |> form("#corpus-scope-form") |> render_submit()
    source = hd(c.fixture.sources)
    view |> element("#corpus-source-open-" <> source["id"]) |> render_click()
    view |> element("#corpus-revision-block-confirm-supplementary") |> render_click()
    patch = assert_patch(view)
    params = patch |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert Enum.sort(Map.keys(params)) == ~w(restriction_event setup_return)
    assert params["setup_return"] == saved["id"]
    before = navigation_counts()
    {:ok, reopened, _} = live(c.conn, patch)
    assert has_element?(reopened, "#corpus-return-setup")
    assert socket(reopened).restriction.receipt["event_id"] == params["restriction_event"]
    assert socket(reopened).state.scope == nil
    assert socket(reopened).state.selection["connection_id"] == ""
    assert socket(reopened).large.passage == nil
    assert navigation_counts() == before
  end

  test "completed scripted analysis opens its exact current claim and saved setup; altered result refuses",
       c do
    c = F.authorize!(c)
    preparation = Repo.get!(SetupRunPreparation, c.prepared["prepared_ref"]["id"])

    # This scripted provider checks UI correspondence only, never model quality.
    citations =
      preparation.checked_pack_json["passages"]
      |> Enum.uniq_by(& &1["source_id"])
      |> Enum.take(2)
      |> Enum.map(fn window ->
        [[snippet]] =
          Repo.query!(
            "SELECT substr(CAST(body AS BLOB),?,?) FROM evidence_revisions WHERE workspace_id=? AND id=?",
            [
              window["start_byte"] + 1,
              window["end_byte"] - window["start_byte"],
              c.workspace,
              window["revision_id"]
            ]
          ).rows

        window
        |> Map.take(~w(source_id revision_id start_byte end_byte))
        |> Map.put("snippet", snippet)
      end)

    assert length(citations) == 2

    report = %{
      "findings" => [
        %{
          "kind" => "practice",
          "statement" => "Synthetic review of the selected captured passages.",
          "citations" => citations
        }
      ],
      "recommendation" => Map.put(c.fixture.report["recommendation"], "status", "supported"),
      "uncertainty" => "Scripted protocol test; company usefulness is unmeasured."
    }

    Application.put_env(:harness_forge, :model_test_plug, fn conn ->
      Req.Test.json(conn, F.response(report))
    end)

    assert {:ok, _} = F.command(c, "analyze", %{"prepared_ref" => c.prepared["prepared_ref"]})

    assert {:ok, %{"run" => %{"phase" => "completed", "result_ref" => result}}} =
             SetupRuns.get(c.session_id, F.caller())

    assert {:ok, [claim]} = Evidence.list_claims()
    {:ok, saved} = SetupSessions.get(%{"id" => c.session_id}, F.caller())
    setup_path = "/setup/#{saved["id"]}/#{saved["step"]}"
    {:ok, setup, _} = live(c.conn, setup_path)

    [href] =
      setup
      |> element("#setup-analysis-review")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("a")
      |> LazyHTML.attribute("href")

    params = href |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert params["company_review"] == claim["id"]
    assert params["revision_hash"] == claim["revision_hash"]
    assert params["analysis_result"] == result["id"]
    assert params["result_digest"] == result["digest"]
    assert params["setup"] == saved["id"]
    before = F.rows("model_requests")

    for _ <- 1..2 do
      {:ok, review, _} = live(c.conn, href)
      assert has_element?(review, "#company-analysis-review", claim["basis"]["guidance"]["rule"])
      assert has_element?(review, "#journey-return-setup[href='#{setup_path}']")
    end

    altered =
      "/?" <> URI.encode_query(Map.put(params, "result_digest", String.duplicate("0", 64)))

    {:ok, refused, _} = live(c.conn, altered)
    refute has_element?(refused, "#journey-return-setup")
    refute has_element?(refused, "#company-analysis-review")
    assert has_element?(refused, "#error", "changed or is unavailable")
    assert F.rows("model_requests") == before
    assert {:ok, %{"status" => "proposed"}} = Evidence.get_claim(claim["id"])

    navigation_params = %{
      "company_review" => claim["id"],
      "revision_hash" => claim["revision_hash"],
      "setup_return" => saved["id"]
    }

    before = navigation_counts()
    {:ok, corpus, _} = live(c.conn, corpus_url(saved))

    corpus
    |> form("#corpus-scope-form", scope: %{"connection_id" => c.fixture.connection["id"]})
    |> render_change()

    corpus |> form("#corpus-scope-form") |> render_submit()
    corpus |> element("#corpus-recommendation-open-" <> claim["id"]) |> render_click()
    corpus |> element("#corpus-continue-review") |> render_click()
    assert_redirect(corpus, "/?" <> URI.encode_query(navigation_params))
    {:ok, review, _} = live(c.conn, "/?" <> URI.encode_query(navigation_params))
    assert has_element?(review, "#company-analysis-review")
    assert has_element?(review, "#journey-return-setup[href='#{setup_path}']")
    refute has_element?(review, "#error", "Saved setup scope is unavailable")
    assert navigation_counts() == before
    assert {:ok, ^saved} = SetupSessions.get(%{"id" => saved["id"]}, F.caller())

    {:ok, other} =
      Company.create_project(%{
        "name" => "Independent synthetic scope",
        "repository_ids" => [c.fixture.repository["id"]],
        "source_ids" => []
      })

    {:ok, different} = SetupSessions.create(%{}, F.caller())

    {:ok, different} =
      F.session_command(different, "change", %{
        "selection" =>
          saved["selection"]
          |> Map.put("project", Map.take(other, ~w(id content_hash)))
          |> Map.put("corpus_id", nil)
          |> Map.put("declaration", nil)
      })

    before = navigation_counts()

    {:ok, mismatch, _} =
      live(
        c.conn,
        "/?" <> URI.encode_query(Map.put(navigation_params, "setup_return", different["id"]))
      )

    assert has_element?(mismatch, "#company-analysis-review")

    assert has_element?(
             mismatch,
             "#journey-return-setup[href='/setup/#{different["id"]}/#{different["step"]}']"
           )

    assert has_element?(mismatch, "#error", "Saved setup scope is unavailable")
    assert {:ok, ^different} = SetupSessions.get(%{"id" => different["id"]}, F.caller())
    assert navigation_counts() == before
  end

  defp corpus_url(saved),
    do: "/company/corpus?" <> URI.encode_query(%{"setup_return" => saved["id"]})

  defp socket(view), do: :sys.get_state(view.pid).socket.assigns

  defp navigation_counts do
    Map.new(
      ~w(setup_sessions setup_runs setup_run_commands capture_runs retrieval_runs model_requests stage_consent_revisions evidence_claims claim_decisions company_plans company_plan_decisions),
      &{&1, F.rows(&1)}
    )
  end
end
