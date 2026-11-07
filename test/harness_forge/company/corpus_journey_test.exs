defmodule HarnessForge.Company.CorpusJourneyTest do
  use ExUnit.Case, async: false

  alias HarnessForge.{
    Company,
    CompanyAnalysisFixture,
    Contracts,
    Decisions,
    Evidence,
    Harnesses,
    Models,
    Repo
  }

  alias HarnessForge.Company.{Analysis, Retrieval}
  alias HarnessForge.Evidence.{Capture, Corpora, OriginV2, Passages}
  alias HarnessForge.Models.StageAuthority

  setup tags do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: tags[:committed] != true)
    keys = [:workspace_id, :workspace_root, :model_test_plug]
    previous = Map.new(keys, &{&1, Application.get_env(:harness_forge, &1)})
    id = Ecto.UUID.generate()
    base = Path.join(File.cwd!(), "tmp/corpus-journey-" <> id)
    root = Path.join(base, "workspace")
    for directory <- ~w(artifacts runs tmp), do: File.mkdir_p!(Path.join(root, directory))
    Application.put_env(:harness_forge, :workspace_id, id)
    Application.put_env(:harness_forge, :workspace_root, root)
    f = CompanyAnalysisFixture.create!(root)

    {:ok, uncited} =
      Evidence.import_markdown(f.connection["id"], %{
        "external_id" => "uncited-review-inventory.md",
        "title" => "Uncited release review inventory",
        "body" =>
          "Release review inventory: named reviewer, emergency release records and rollback owner belong to the synthetic Platform team. This contextual observation grants no new policy."
      })

    f = Map.update!(f, :sources, &(&1 ++ [uncited]))

    on_exit(fn ->
      if tags[:committed] do
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          Application.put_env(:harness_forge, :workspace_id, id)
          Application.put_env(:harness_forge, :workspace_root, root)
          assert {:ok, _} = HarnessForge.Privacy.purge_workspace(id)
        end)
      end

      Enum.each(previous, fn {key, value} ->
        if is_nil(value),
          do: Application.delete_env(:harness_forge, key),
          else: Application.put_env(:harness_forge, key, value)
      end)

      File.rm_rf!(base)
    end)

    for s <- f.sources,
        do:
          File.write!(
            Path.join(f.connection["directory"], s["external_id"]),
            s["latest_revision"]["body"]
          )

    {:ok, c} = Corpora.create(%{"name" => "Public journey"}, caller())

    {:ok, _} =
      Company.bind_corpus(
        f.project["id"],
        c["id"],
        f.profile["content_hash"],
        f.project["content_hash"],
        caller()
      )

    {:ok, run} = Capture.start_capture(c["id"], f.connection["id"], 0, caller())
    {:ok, captured} = Capture.run(run["run_id"])
    assert captured["capture"]["complete"]
    {:ok, sources} = Evidence.list_sources()
    for s <- sources, do: assert({:ok, _} = Passages.index_revision(s["latest_revision"]["id"]))
    {:ok, current} = Corpora.get(c["id"])

    {:ok, retrieval} =
      Retrieval.retrieve(
        %{
          "corpus_id" => c["id"],
          "project_id" => f.project["id"],
          "goal_id" => f.goal["id"],
          "goal_hash" => f.input["goal_content_hash"],
          "expected_generation" => current.semantic_generation,
          "question" => "Which emergency release review and rollback controls apply?",
          "mode" => "fts"
        },
        caller()
      )

    assert retrieval["state"] == "ready"

    {:ok, _} =
      Models.configure(%{
        "provider" => "ollama",
        "endpoint" => "http://127.0.0.1:11434",
        "model" => "synthetic-fixture-v1"
      })

    by_id = Map.new(sources, &{&1["id"], &1})

    report =
      update_in(f.report, ["findings"], fn findings ->
        Enum.map(findings, fn finding ->
          Map.update!(finding, "citations", fn citations ->
            Enum.map(citations, fn citation ->
              Map.put(
                citation,
                "revision_id",
                by_id[citation["source_id"]]["latest_revision"]["id"]
              )
            end)
          end)
        end)
      end)

    %{
      fixture: f,
      run: retrieval,
      report: report,
      corpus: c,
      root: root,
      base: base,
      uncited: uncited
    }
  end

  test "actual passage inference, exact successor approval and separate plan produce a current export",
       ctx do
    {:ok, review} =
      StageAuthority.prepare_synthesis(ctx.run["run_id"], ctx.run["digest"], caller())

    assert {:ok, _} =
             StageAuthority.grant_consent(
               review["stage_id"],
               review["manifest_id"],
               review["manifest_digest"],
               caller()
             )

    Application.put_env(:harness_forge, :model_test_plug, fn conn ->
      assert conn.request_path == "/api/generate"
      Req.Test.json(conn, CompanyAnalysisFixture.response(ctx.report))
    end)

    assert {:ok, %{"status" => "proposed", "claim" => claim}} =
             Analysis.analyze_retrieval(ctx.run["run_id"], ctx.run["digest"],
               caller: caller(),
               stage_id: review["stage_id"]
             )

    assert claim["basis"]["version"] == 2

    assert {:error, :analysis_resolution_required} =
             Decisions.decide(claim["id"], CompanyAnalysisFixture.decision(claim))

    edit =
      Map.merge(claim["basis"]["guidance"], %{
        "rule" =>
          "Record the emergency exception and applicable named reviewer; rehearse rollback.",
        "review_resolution" =>
          "Apply the approved emergency exception only to its documented scope; preserve the general policy elsewhere."
      })

    assert {:ok, corrected} = Analysis.revise(claim["id"], claim["revision_hash"], edit)
    assert corrected["basis"]["context"] == claim["basis"]["context"]

    assert {:ok, _} =
             Decisions.decide(corrected["id"], CompanyAnalysisFixture.decision(corrected))

    assert {:ok, plan} =
             Company.create_plan(CompanyAnalysisFixture.plan_attrs(ctx.fixture, corrected))

    assert {:error, _} = Harnesses.build_plan(plan["id"], plan["revision_hash"])
    assert {:ok, _} = Company.decide_plan(plan["id"], CompanyAnalysisFixture.decision(plan))
    assert {:ok, artifact} = Harnesses.build_plan(plan["id"], plan["revision_hash"])
    target = Path.join(ctx.root, "fresh-export")
    assert {:ok, _} = Harnesses.export(artifact["digest"], target)
    assert map_size(artifact["files"]) > 0

    for {path, bytes} <- artifact["files"],
        do: assert(File.read!(Path.join(target, path)) == bytes)

    {:ok, new} =
      Evidence.import_markdown(ctx.fixture.connection["id"], %{
        "external_id" => "later-policy.md",
        "title" => "Later public decision",
        "body" => "A newly approved public policy requires a second emergency reviewer."
      })

    {:ok, c} = Corpora.get(ctx.corpus["id"])

    assert {:ok, _} =
             Corpora.apply_members(
               c.id,
               c.semantic_generation,
               [
                 %{
                   "source_id" => new["id"],
                   "revision_id" => new["latest_revision"]["id"],
                   "action" => "include"
                 }
               ],
               caller()
             )

    assert {:error, _} = Evidence.validate_claim(corrected)
    assert {:error, _} = Harnesses.export(artifact["digest"], Path.join(ctx.root, "stale-export"))
  end

  test "a granted attempt cannot substitute its logical call or reservation identity", ctx do
    {auth, attempt} = controlled_attempt(ctx)
    context = %{"authority" => auth, "attempt" => attempt, "grant" => nil}
    assert {:ok, grant} = StageAuthority.admit_attempt(context)

    for changed <- [
          Map.put(attempt, "logical_call_id", Ecto.UUID.generate()),
          attempt
          |> Map.put("ordinal", 2)
          |> Map.put("predecessor_attempt_id", Ecto.UUID.generate())
        ] do
      assert {:error, _} =
               StageAuthority.mark_dispatching(%{
                 context
                 | "attempt" => changed,
                   "grant" => grant
               })

      assert [["reserved"]] =
               Repo.query!("SELECT state FROM stage_attempts WHERE id=?", [attempt["attempt_id"]]).rows
    end

    assert {:ok, _} = StageAuthority.mark_dispatching(%{context | "grant" => grant})

    assert {:error, _} =
             StageAuthority.finish_attempt(
               %{
                 context
                 | "attempt" => Map.put(attempt, "logical_call_id", Ecto.UUID.generate()),
                   "grant" => grant
               },
               {:error, :cancelled}
             )

    assert [["dispatched"]] =
             Repo.query!("SELECT state FROM stage_attempts WHERE id=?", [attempt["attempt_id"]]).rows

    assert {:ok, _} = StageAuthority.cancel(auth)
  end

  test "durable cancel before dispatch sends no HTTP and preserves uncertain billing", ctx do
    {auth, attempt} = controlled_attempt(ctx)

    Application.put_env(:harness_forge, :model_test_plug, fn _ ->
      flunk("cancelled send reached HTTP")
    end)

    assert {:ok, receipt} =
             HarnessForge.Models.AttemptGateway.dispatch(attempt, auth, nil, fn _ ->
               assert {:ok, 1} = StageAuthority.cancel(auth)
               :ok
             end)

    assert receipt["state"] == "uncertain"

    assert [["cancelled", 1]] =
             Repo.query!("SELECT state,cancel_epoch FROM stage_operations WHERE id=?", [
               auth.operation_id
             ]).rows

    assert [["uncertain", "unknown"]] =
             Repo.query!("SELECT state,usage_status FROM model_requests WHERE run_id=?", [
               auth.operation_id
             ]).rows

    assert {:error, _} =
             StageAuthority.publish_result(%{
               "authority" => auth,
               "result" => %{"status" => "proposed"}
             })

    assert {:error, _} = HarnessForge.Models.AttemptGateway.dispatch(attempt, auth)
  end

  test "late response settles usage but cancelled operation cannot publish", ctx do
    {auth, attempt} = controlled_attempt(ctx)

    Application.put_env(:harness_forge, :model_test_plug, fn conn ->
      assert {:ok, 1} = StageAuthority.cancel(auth)
      Req.Test.json(conn, CompanyAnalysisFixture.response(ctx.report))
    end)

    assert {:ok, receipt} = HarnessForge.Models.AttemptGateway.dispatch(attempt, auth)
    assert receipt["usage_status"] == "reported"

    assert [[200, bytes, hash]] =
             Repo.query!(
               "SELECT response_status,response_bytes,result_hash FROM stage_attempts WHERE id=?",
               [receipt["attempt_id"]]
             ).rows

    assert bytes == byte_size(receipt["body"])
    assert hash == Contracts.sha256(receipt["body"])

    assert [["completed", "reported"]] =
             Repo.query!("SELECT state,usage_status FROM model_requests WHERE run_id=?", [
               auth.operation_id
             ]).rows

    assert {:error, _} =
             StageAuthority.publish_result(%{
               "authority" => auth,
               "result" => %{"status" => "proposed"}
             })

    assert [[0]] = Repo.query!("SELECT count(*) FROM evidence_claims", []).rows
  end

  test "publication is single use; startup recovery fences unfinished authorities", ctx do
    {auth, attempt} = controlled_attempt(ctx)

    Application.put_env(:harness_forge, :model_test_plug, fn conn ->
      Req.Test.json(conn, CompanyAnalysisFixture.response(ctx.report))
    end)

    assert {:ok, _} = HarnessForge.Models.AttemptGateway.dispatch(attempt, auth)
    result = %{"status" => "abstained", "uncertainty" => "Synthetic control-only check"}

    assert {:ok, ^result} =
             StageAuthority.publish_result(%{"authority" => auth, "result" => result})

    assert {:error, _} = StageAuthority.publish_result(%{"authority" => auth, "result" => result})

    assert {:error, :operation_already_started} =
             StageAuthority.new(
               auth.operation_id,
               auth.manifest_id,
               auth.manifest_digest,
               Enum.map(auth.stage_pins, & &1["id"]),
               caller()
             )

    {unfinished, pending} = controlled_attempt(ctx)

    assert {:ok, _} =
             StageAuthority.admit_attempt(%{
               "authority" => unfinished,
               "attempt" => pending,
               "grant" => nil
             })

    assert :ok = HarnessForge.Models.StageControl.reconcile()
    assert {:error, _} = StageAuthority.revalidate_job(%{"authority" => unfinished, "job" => nil})

    assert [["uncertain", "unknown"]] =
             Repo.query!("SELECT state,usage_status FROM model_requests WHERE run_id=?", [
               unfinished.operation_id
             ]).rows

    assert [["uncertain", 1]] =
             Repo.query!("SELECT state,cancel_epoch FROM stage_operations WHERE id=?", [
               unfinished.operation_id
             ]).rows

    assert [["completed", 0]] =
             Repo.query!("SELECT state,cancel_epoch FROM stage_operations WHERE id=?", [
               auth.operation_id
             ]).rows
  end

  defp controlled_attempt(ctx) do
    {:ok, review} =
      StageAuthority.prepare_synthesis(ctx.run["run_id"], ctx.run["digest"], caller())

    {:ok, _} =
      StageAuthority.grant_consent(
        review["stage_id"],
        review["manifest_id"],
        review["manifest_digest"],
        caller()
      )

    {:ok, pin} = StageAuthority.load_pin(review["stage_id"])

    {:ok, auth} =
      StageAuthority.new(
        Ecto.UUID.generate(),
        review["manifest_id"],
        review["manifest_digest"],
        [pin["id"]],
        caller()
      )

    body =
      Contracts.canonical_json(%{
        "model" => pin["model"],
        "prompt" => "Explicitly synthetic lifecycle check",
        "stream" => false
      })

    {:ok, auth} = StageAuthority.bind_synthesis_payload(auth, pin["id"], body)
    id = Ecto.UUID.generate()

    attempt = %{
      "job_id" => auth.operation_id,
      "logical_call_id" => id,
      "attempt_id" => id,
      "stage_id" => pin["id"],
      "stage_digest" => pin["config_digest"],
      "prompt_name" => "company_analysis_v2",
      "closure_ref" => auth.manifest_id,
      "closure_digest" => auth.manifest_digest,
      "context_manifest_ref" => auth.manifest_id,
      "context_manifest_digest" => auth.manifest_digest,
      "cancel_epoch" => auth.cancel_epoch,
      "payload_sha256" => Contracts.sha256(body),
      "method" => "POST",
      "route_id" => pin["route_id"],
      "body" => body,
      "timeout_ms" => pin["timeout_ms"],
      "max_output_tokens" => pin["max_output_tokens"],
      "context_changed" => false,
      "ordinal" => 1,
      "predecessor_attempt_id" => nil
    }

    {auth, attempt}
  end

  test "manifest and MCP readiness are exact and metadata-only; forged or stale handles refuse",
       ctx do
    {:ok, pack} = OriginV2.seal_retrieval(ctx.run["run_id"], ctx.run["digest"], caller())
    context = pack["origin_context"]
    assert :ok = OriginV2.validate_context(context)

    assert {:error, _} =
             OriginV2.validate_context(
               Map.put(context, "manifest_digest", String.duplicate("0", 64))
             )

    assert {:ok, dto} =
             HarnessForge.MCP.Tools.call("harnessforge_company_run_readiness", %{
               "run_id" => ctx.run["run_id"],
               "run_digest" => ctx.run["digest"]
             })

    refute String.contains?(Jason.encode!(dto), "Synthetic Reviewer")
    refute Map.has_key?(dto, "question")
    assert dto["analysis_ready"]

    assert {:error, _} =
             HarnessForge.MCP.Tools.call("harnessforge_company_run_readiness", %{
               "run_id" => ctx.run["run_id"],
               "run_digest" => String.duplicate("0", 64)
             })

    assert %{rows: []} = Repo.query!("PRAGMA foreign_key_check", [])

    assert {:error, _} =
             Repo.query("UPDATE dependency_manifests SET context_json='{}' WHERE id=?", [
               context["manifest_id"]
             ])

    assert :ok = OriginV2.validate_context(context)
  end

  @tag :committed
  test "committed corpus backup preserves manifests, restore denies authority and uncited-source purge removes derived state",
       ctx do
    {:ok, review} =
      StageAuthority.prepare_synthesis(ctx.run["run_id"], ctx.run["digest"], caller())

    {:ok, _} =
      StageAuthority.grant_consent(
        review["stage_id"],
        review["manifest_id"],
        review["manifest_digest"],
        caller()
      )

    Application.put_env(:harness_forge, :model_test_plug, fn conn ->
      Req.Test.json(conn, CompanyAnalysisFixture.response(ctx.report))
    end)

    {:ok, %{"claim" => claim}} =
      Analysis.analyze_retrieval(ctx.run["run_id"], ctx.run["digest"],
        caller: caller(),
        stage_id: review["stage_id"]
      )

    {:ok, corrected} =
      Analysis.revise(
        claim["id"],
        claim["revision_hash"],
        Map.put(
          claim["basis"]["guidance"],
          "review_resolution",
          "Preserve the general rule; apply the emergency exception only to its documented scope."
        )
      )

    {:ok, _} = Decisions.decide(corrected["id"], CompanyAnalysisFixture.decision(corrected))
    {:ok, plan} = Company.create_plan(CompanyAnalysisFixture.plan_attrs(ctx.fixture, corrected))
    {:ok, _} = Company.decide_plan(plan["id"], CompanyAnalysisFixture.decision(plan))
    {:ok, artifact} = Harnesses.build_plan(plan["id"], plan["revision_hash"])

    assert OriginV2.contains_source?(
             corrected["basis"]["context"]["manifest_id"],
             ctx.uncited["id"]
           )

    refute Enum.any?(ctx.report["findings"], fn f ->
             Enum.any?(f["citations"], &(&1["source_id"] == ctx.uncited["id"]))
           end)

    backup = Path.join(ctx.base, "backup")
    restore = Path.join(ctx.base, "restored")
    assert {:ok, _} = HarnessForge.Privacy.backup(backup)
    assert {:ok, manifest} = HarnessForge.Privacy.verify_backup(backup)
    assert artifact["digest"] in manifest["artifact_digests"]

    assert {:ok, %{"workspace_id" => new_ws, "approvals_restored" => false}} =
             HarnessForge.Privacy.restore(backup, restore)

    {:ok, conn} = Exqlite.Sqlite3.open(Path.join(restore, "data.sqlite3"))

    try do
      assert [] == copied_rows(conn, "PRAGMA foreign_key_check")
      assert [[0]] == copied_rows(conn, "SELECT count(*) FROM corpora WHERE state!='denied'")

      assert [[0]] ==
               copied_rows(
                 conn,
                 "SELECT count(*) FROM stage_consent_revisions WHERE state!='revoked'"
               )

      assert [[0]] ==
               copied_rows(
                 conn,
                 "SELECT count(*) FROM dependency_manifests WHERE state!='denied'"
               )

      assert [[0]] ==
               copied_rows(
                 conn,
                 "SELECT count(*) FROM stage_attempts WHERE model_request_id IS NOT NULL OR grant_hash IS NOT NULL"
               )

      assert [[new_ws]] == copied_rows(conn, "SELECT DISTINCT workspace_id FROM corpora")
      assert [[0]] == copied_rows(conn, "SELECT count(*) FROM claim_decisions")
    after
      Exqlite.Sqlite3.close(conn)
    end

    assert {:ok, _} = HarnessForge.Privacy.purge_source(ctx.uncited["id"], ctx.uncited["id"])
    assert {:error, :not_found} = Evidence.get_claim(corrected["id"])
    assert {:error, _} = Harnesses.get(artifact["digest"])

    assert [[0]] ==
             Repo.query!("SELECT count(*) FROM origin_dependencies WHERE source_id=?", [
               ctx.uncited["id"]
             ]).rows

    assert [] == Repo.query!("PRAGMA foreign_key_check", []).rows
  end

  defp copied_rows(conn, query) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, query)

    try do
      :ok = Exqlite.Sqlite3.bind(stmt, [])
      {:ok, rows} = Exqlite.Sqlite3.fetch_all(conn, stmt)
      rows
    after
      Exqlite.Sqlite3.release(conn, stmt)
    end
  end

  defp caller,
    do: [
      authorize: fn -> true end,
      session_fingerprint: Contracts.sha256("public journey"),
      view_generation: String.duplicate("e", 32),
      reset_token: 0
    ]
end
