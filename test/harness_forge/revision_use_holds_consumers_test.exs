defmodule HarnessForge.RevisionUseHoldsConsumersTest do
  use ExUnit.Case, async: false

  alias HarnessForge.{
    Company,
    CompanyAnalysisFixture,
    Contracts,
    Decisions,
    Evidence,
    Harnesses,
    Models,
    Privacy,
    Repo
  }

  alias HarnessForge.Company.{Analysis, CorpusReview, Retrieval}

  alias HarnessForge.Evidence.{
    Capture,
    Corpora,
    GraphManifests,
    GraphSources,
    OriginV2,
    Passages,
    Store
  }

  alias HarnessForge.Graphiti.SchemaPolicy
  alias HarnessForge.MCP.Tools
  alias HarnessForge.Models.{AttemptGateway, HTTP, Runtime, StageAuthority, Stages}

  @moduletag :committed
  @rule "R01_HELD_ARTIFACT_RULE: Record the applicable reviewer and rollback rehearsal."

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

    previous =
      Map.new(
        [:workspace_id, :workspace_root, :model_test_plug, :graph_runtime_authority],
        fn key ->
          {key, Application.get_env(:harness_forge, key)}
        end
      )

    id = Ecto.UUID.generate()
    root = Path.join([File.cwd!(), "tmp", "revision-use-consumers-" <> id])
    for directory <- ~w(artifacts runs tmp), do: File.mkdir_p!(Path.join(root, directory))
    Application.put_env(:harness_forge, :workspace_id, id)
    Application.put_env(:harness_forge, :workspace_root, root)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Application.put_env(:harness_forge, :workspace_id, id)
        Application.put_env(:harness_forge, :workspace_root, root)
        assert {:ok, _} = Privacy.purge_workspace(id)
      end)

      Enum.each(previous, fn {key, value} ->
        if is_nil(value),
          do: Application.delete_env(:harness_forge, key),
          else: Application.put_env(:harness_forge, key, value)
      end)

      File.rm_rf!(root)
    end)

    fixture = CompanyAnalysisFixture.create!(root)

    for source <- fixture.sources do
      File.write!(
        Path.join(fixture.connection["directory"], source["external_id"]),
        source["latest_revision"]["body"]
      )
    end

    {:ok, corpus} = Corpora.create(%{"name" => "R01 persisted consumer fixture"}, caller())

    {:ok, _} =
      Company.bind_corpus(
        fixture.project["id"],
        corpus["id"],
        fixture.profile["content_hash"],
        fixture.project["content_hash"],
        caller()
      )

    {:ok, capture} = Capture.start_capture(corpus["id"], fixture.connection["id"], 0, caller())
    {:ok, captured} = Capture.run(capture["run_id"])
    assert captured["capture"]["complete"]
    {:ok, sources} = Evidence.list_sources()

    for source <- sources,
        do: assert({:ok, _} = Passages.index_revision(source["latest_revision"]["id"]))

    {:ok, current} = Corpora.get(corpus["id"])
    by_id = Map.new(sources, &{&1["id"], &1})

    report =
      update_in(fixture.report, ["findings"], fn findings ->
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

    legacy_input =
      Map.put(
        fixture.input,
        "source_refs",
        sources
        |> Enum.map(fn s ->
          %{
            "source_id" => s["id"],
            "revision_id" => s["latest_revision"]["id"],
            "body_hash" => s["latest_revision"]["body_hash"]
          }
        end)
        |> Enum.sort_by(& &1["source_id"])
      )

    input = %{
      "corpus_id" => corpus["id"],
      "project_id" => fixture.project["id"],
      "goal_id" => fixture.goal["id"],
      "goal_hash" => fixture.input["goal_content_hash"],
      "expected_generation" => current.semantic_generation,
      "question" =>
        "Which approved policy and emergency release review and rollback controls apply?",
      "mode" => "fts"
    }

    {:ok, run} = Retrieval.retrieve(input, caller())
    assert run["state"] == "ready"
    {:ok, pack} = OriginV2.seal_retrieval(run["run_id"], run["digest"], caller())
    source = Enum.find(sources, &(&1["external_id"] == "policy.md"))
    passage = Enum.find(pack["passages"], &(&1["source_id"] == source["id"]))
    assert is_map(passage)
    {:ok, page} = CorpusReview.source_page(%{}, caller())
    preview = Enum.find(page["rows"], &(&1["id"] == source["id"]))
    assert is_map(preview)

    {:ok, citation} =
      Evidence.citation(
        source["latest_revision"]["id"],
        0,
        byte_size(source["latest_revision"]["body"])
      )

    {:ok, claim} = Evidence.create_claim(%{"text" => @rule, "citations" => [citation]})
    {:ok, _} = Decisions.decide(claim["id"], CompanyAnalysisFixture.decision(claim))
    {:ok, plan} = Company.create_plan(CompanyAnalysisFixture.plan_attrs(fixture, claim))
    {:ok, _} = Company.decide_plan(plan["id"], CompanyAnalysisFixture.decision(plan))
    {:ok, artifact} = Harnesses.build_plan(plan["id"], plan["revision_hash"])
    assert :ok = Harnesses.eligible(artifact)

    {:ok, _} =
      Models.configure(%{
        "provider" => "ollama",
        "endpoint" => "http://127.0.0.1:11434",
        "model" => "synthetic-r01-fixture"
      })

    %{
      root: root,
      fixture: fixture,
      corpus: current,
      input: input,
      legacy_input: legacy_input,
      report: report,
      run: run,
      pack: pack,
      source: source,
      passage: passage,
      preview: preview,
      claim: claim,
      plan: plan,
      artifact: artifact
    }
  end

  test "a committed pending hold fences persisted inspection, retrieval, analysis, compilation and MCP",
       ctx do
    {:ok, evidence_run} = Retrieval.retrieve_evidence(ctx.input, caller())
    {auth, attempt} = controlled_attempt(ctx)
    test_process = self()

    Application.put_env(:harness_forge, :model_test_plug, fn conn ->
      send(test_process, :unauthorized_provider_send)
      Req.Test.json(conn, %{})
    end)

    receipt = restrict!(ctx.source)
    assert_pending(receipt)

    # Prove denial precedes cleanup: current rows, indexes and artifact remain;
    # neither corpus generation nor membership has been invalidated yet.
    assert [["active", ctx.source["latest_revision"]["id"]]] ==
             Repo.query!(
               "SELECT status,revision_id FROM corpus_members WHERE workspace_id=? AND corpus_id=? AND source_id=?",
               [Store.workspace(), ctx.corpus.id, ctx.source["id"]]
             ).rows

    assert {:ok, current} = Corpora.get(ctx.corpus.id)
    assert current.semantic_generation == ctx.corpus.semantic_generation
    assert current.authorization_generation == ctx.corpus.authorization_generation

    assert [[1]] ==
             Repo.query!(
               "SELECT count(*) FROM evidence_revisions WHERE workspace_id=? AND id=? AND body_hash=?",
               [
                 Store.workspace(),
                 ctx.source["latest_revision"]["id"],
                 ctx.source["latest_revision"]["body_hash"]
               ]
             ).rows

    assert [[1]] ==
             Repo.query!(
               "SELECT count(*) FROM passage_sets WHERE workspace_id=? AND revision_id=? AND state='ready'",
               [Store.workspace(), ctx.source["latest_revision"]["id"]]
             ).rows

    assert {:error, _} =
             CorpusReview.passage(
               ctx.preview["passage_token"],
               passage_attrs(ctx.source),
               caller()
             )

    assert {:ok, searched} = CorpusReview.source_page(%{"query" => "policy"}, caller())
    refute Enum.any?(searched["rows"], &(&1["id"] == ctx.source["id"]))
    refute Jason.encode!(searched) =~ ctx.source["latest_revision"]["body"]
    assert {:ok, hits} = Evidence.search("policy")
    refute Enum.any?(hits, &(&1["id"] == ctx.source["id"]))
    assert {:error, _} = Passages.read(ctx.passage["passage_id"], identity(ctx.passage), caller())
    assert {:error, _} = Passages.index_revision(ctx.source["latest_revision"]["id"])
    assert {:error, _} = Retrieval.retrieve(ctx.input, caller())
    assert {:error, _} = Retrieval.retrieve_evidence(ctx.input, caller())

    assert {:error, _} =
             Retrieval.read_evidence_summary(
               evidence_run["run_id"],
               evidence_run["digest"],
               caller()
             )

    assert {:error, _} =
             Retrieval.read_evidence(
               evidence_run["run_id"],
               evidence_run["digest"],
               %{},
               caller()
             )

    assert {:error, _} =
             Retrieval.open_evidence_passage(
               evidence_run["run_id"],
               evidence_run["digest"],
               ctx.passage["passage_id"],
               caller()
             )

    assert {:error, _} =
             Retrieval.resolve_for_analysis(
               evidence_run["run_id"],
               evidence_run["digest"],
               caller()
             )

    assert {:error, _} = Retrieval.read_run(ctx.run["run_id"], ctx.run["digest"], %{}, caller())

    assert {:error, _} =
             Retrieval.open_passage(
               ctx.run["run_id"],
               ctx.run["digest"],
               ctx.passage["passage_id"],
               caller()
             )

    assert {:error, _} =
             Retrieval.resolve_for_analysis(ctx.run["run_id"], ctx.run["digest"], caller())

    assert {:error, _} = OriginV2.validate_context(ctx.pack["origin_context"])

    assert {:error, _} =
             Analysis.analyze_retrieval(ctx.run["run_id"], ctx.run["digest"],
               caller: caller(),
               stage_id: hd(auth.stage_pins)["id"]
             )

    assert {:error, _} = Models.propose(ctx.source["id"])
    assert {:error, _} = AttemptGateway.dispatch(attempt, auth)

    assert {:error, _} =
             StageAuthority.publish_result(%{
               "authority" => auth,
               "result" => %{"status" => "proposed", "claim" => ctx.claim}
             })

    refute_received :unauthorized_provider_send

    assert {:error, _} = Evidence.validate_claim(ctx.claim)
    assert {:ok, approved} = Evidence.approved_claims()
    refute Enum.any?(approved, &(&1["id"] == ctx.claim["id"]))
    assert {:error, _} = Harnesses.build_plan(ctx.plan["id"], ctx.plan["revision_hash"])
    assert {:error, _} = Harnesses.eligible(ctx.artifact)
    target = Path.join(ctx.root, "held-export")
    assert {:error, _} = Harnesses.export(ctx.artifact["digest"], target)
    refute File.exists?(target)

    assert {:ok, package} =
             Tools.call("harnessforge_inspect_package", %{"digest" => ctx.artifact["digest"]})

    refute package["eligible"]
    refute Map.has_key?(package, "name")
    refute Map.has_key?(package, "files")
    refute Jason.encode!(package) =~ @rule
    for bytes <- Map.values(ctx.artifact["files"]), do: refute(Jason.encode!(package) =~ bytes)

    assert {:ok, readiness} =
             Tools.call(
               "harnessforge_company_run_readiness",
               %{"run_id" => ctx.run["run_id"], "run_digest" => ctx.run["digest"]}
             )

    refute readiness["current"]
    refute readiness["analysis_ready"]

    # A held corpus does not revoke unrelated inspection authority.
    unrelated = Enum.find(ctx.fixture.sources, &(&1["external_id"] == "incidents.md"))
    assert {:ok, page} = CorpusReview.source_page(%{"query" => "incident"}, caller())
    row = Enum.find(page["rows"], &(&1["id"] == unrelated["id"]))
    assert is_map(row)

    attrs = %{
      "source_id" => row["id"],
      "revision_id" => row["latest_revision"]["id"],
      "body_hash" => row["latest_revision"]["body_hash"],
      "start_byte" => 0
    }

    assert {:ok, window} = CorpusReview.passage(row["passage_token"], attrs, caller())
    assert window["text"] =~ "incident"
    denied = Keyword.put(caller(), :authorize, fn -> false end)

    assert {:error, :operator_session_revoked} =
             CorpusReview.passage(row["passage_token"], attrs, denied)

    assert_same_bytes_other_tenant(ctx, receipt)
    assert_pending(receipt)
  end

  test "a hold after reservation and before dispatch admission produces zero sends", ctx do
    {auth, attempt} = controlled_attempt(ctx)
    test_process = self()

    Application.put_env(:harness_forge, :model_test_plug, fn conn ->
      send(test_process, :unauthorized_provider_send)
      Req.Test.json(conn, %{})
    end)

    assert {:ok, result} =
             AttemptGateway.dispatch(attempt, auth, nil, fn _grant ->
               receipt = restrict!(ctx.source)
               assert_pending(receipt)
               :ok
             end)

    assert result["state"] == "uncertain"
    assert result["usage_status"] == "unknown"
    refute_received :unauthorized_provider_send

    assert {:error, _} =
             StageAuthority.publish_result(%{
               "authority" => auth,
               "result" => %{"status" => "abstained"}
             })
  end

  test "the final HTTP guard denies a new hold even after the dispatch reservation was marked",
       ctx do
    {auth, attempt} = controlled_attempt(ctx)
    context = %{"authority" => auth, "attempt" => attempt, "grant" => nil}
    assert {:ok, grant} = StageAuthority.admit_attempt(context)
    context = Map.put(context, "grant", grant)
    assert {:ok, dispatch} = StageAuthority.mark_dispatching(context)
    assert :ok = StageAuthority.revalidate_job(%{"authority" => auth, "job" => nil})
    test_process = self()

    Application.put_env(:harness_forge, :model_test_plug, fn conn ->
      send(test_process, :unauthorized_provider_send)
      Req.Test.json(conn, %{})
    end)

    receipt = restrict!(ctx.source)

    # This is the production HTTP seam used by AttemptGateway: the guard runs
    # immediately before Req.request. Marking a reservation is not a send.
    assert {:error, _} =
             HTTP.request_raw(:post, dispatch["url"], attempt["body"], dispatch["headers"],
               timeout: dispatch["timeout_ms"],
               dispatch_guard: fn ->
                 StageAuthority.revalidate_job(%{"authority" => auth, "job" => nil})
               end
             )

    refute_received :unauthorized_provider_send
    assert {:ok, settled} = StageAuthority.finish_attempt(context, {:error, :revision_use_denied})
    assert settled["usage_status"] == "unknown"

    assert {:error, _} =
             StageAuthority.publish_result(%{
               "authority" => auth,
               "result" => %{"status" => "abstained"}
             })

    assert_pending(receipt)
  end

  test "a hold after an admitted send settles usage but refuses result publication", ctx do
    {auth, attempt} = controlled_attempt(ctx)
    test_process = self()

    Application.put_env(:harness_forge, :model_test_plug, fn conn ->
      # The bytes have already crossed admission at this point. The hold cannot
      # recall them; it must still fence publication and every later use.
      send(test_process, :authorized_provider_send)
      receipt = restrict!(ctx.source)
      send(test_process, {:restriction, receipt})
      Req.Test.json(conn, CompanyAnalysisFixture.response(ctx.fixture.report))
    end)

    assert {:ok, result} = AttemptGateway.dispatch(attempt, auth)
    assert result["usage_status"] == "reported"
    assert_received :authorized_provider_send
    assert_received {:restriction, receipt}
    refute_received :authorized_provider_send

    assert {:error, _} =
             StageAuthority.publish_result(%{
               "authority" => auth,
               "result" => %{"status" => "proposed", "claim" => ctx.claim}
             })

    assert_pending(receipt)
  end

  test "a sealed graph source certificate rechecks the held-member fence before cleanup", ctx do
    # This reuses the metadata-only registry seam from GraphManifests tests.
    # It creates no worker, backend or runtime qualification evidence.
    {:ok, bundle} =
      GraphSources.runtime_bundle(%{
        "worker_image" => "sha256:" <> String.duplicate("1", 64),
        "backend_image" => "sha256:" <> String.duplicate("2", 64),
        "backend_instance" => "r01-metadata-only",
        "database" => "neo4j",
        "index_identity" => "r01-metadata-only-index"
      })

    Application.put_env(:harness_forge, :graph_runtime_authority, %{
      "qualified" => true,
      "bundle" => bundle,
      "qualification_ref" => "r01-metadata-only-test"
    })

    {:ok, partition} = GraphSources.start(ctx.corpus.id, caller())

    scanned =
      Enum.reduce_while(1..4, nil, fn _, _ ->
        assert {:ok, status} = GraphSources.advance(partition["partition_id"], caller())
        if status["state"] == "complete", do: {:halt, status}, else: {:cont, status}
      end)

    assert scanned["state"] == "complete"

    pin = %{
      "id" => Ecto.UUID.generate(),
      "stage" => "extraction",
      "provider" => "ollama",
      "model" => "r01-public-synthetic-metadata-only",
      "endpoint" => "http://127.0.0.1:11434/v1/chat/completions",
      "route_id" => "graphiti_extraction",
      "credential_ref" => nil,
      "prompt_digest" => SchemaPolicy.prompt_policy_digest("extraction"),
      "schema_digest" => SchemaPolicy.digest(),
      "consent_revision" => 1,
      "input_rate" => 0,
      "output_rate" => 0,
      "max_output_tokens" => 100,
      "timeout_ms" => 1000
    }

    pin = Map.put(pin, "config_digest", Stages.fingerprint(pin))
    {:ok, _} = StageAuthority.create_pin(pin, caller())

    {:ok, auth} =
      StageAuthority.new_graph(
        Ecto.UUID.generate(),
        "ingest",
        partition["partition_id"],
        [pin["id"]],
        "r01-metadata-only-session",
        caller()
      )

    certificate =
      Enum.reduce_while(1..8, nil, fn _, _ ->
        assert {:ok, status} = GraphSources.certificate_step(auth)
        if status["phase"] == "sealed", do: {:halt, status}, else: {:cont, status}
      end)

    assert certificate["phase"] == "sealed"

    {:ok, auth} =
      StageAuthority.bind_graph_manifest(auth, certificate["manifest_id"], certificate["digest"])

    assert {:ok, _} =
             GraphManifests.validate_scope_certificate(
               auth.manifest_id,
               auth.manifest_digest,
               auth
             )

    receipt = restrict!(ctx.source)

    # The cached certificate itself is still sealed. Currentness must reject
    # its corpus before cleanup modifies the certificate or member rows.
    assert [["sealed"]] ==
             Repo.query!(
               "SELECT state FROM dependency_manifests WHERE workspace_id=? AND id=?",
               [Store.workspace(), auth.manifest_id]
             ).rows

    assert {:error, _} =
             GraphManifests.validate_scope_certificate(
               auth.manifest_id,
               auth.manifest_digest,
               auth
             )

    assert {:error, _} = StageAuthority.revalidate_job(%{"authority" => auth, "job" => nil})
    assert_pending(receipt)
  end

  for path <- ~w(generic_chat runtime_chat legacy_analysis) do
    @tag model_path: path
    test "#{path} rechecks the hold at the source-bearing HTTP admission", ctx do
      {operation, run_id, send_path} = model_operation(ctx, ctx.model_path)
      test_process = self()

      Application.put_env(:harness_forge, :model_test_plug, fn conn ->
        case conn.request_path do
          "/api/tags" ->
            receipt = restrict!(ctx.source)
            send(test_process, {:restriction, receipt})
            tags_response(conn)

          ^send_path ->
            send(test_process, :unauthorized_provider_send)
            model_response(conn, ctx)
        end
      end)

      assert {:error, _} = operation.()
      refute_received :unauthorized_provider_send
      assert_received {:restriction, receipt}
      assert_pending(receipt)

      assert [["uncertain", "unknown"]] ==
               Repo.query!(
                 "SELECT state,usage_status FROM model_requests WHERE workspace_id=? AND run_id=?",
                 [Store.workspace(), run_id]
               ).rows
    end

    @tag model_path: path
    test "#{path} settles an admitted response but refuses publication after a hold", ctx do
      {operation, run_id, send_path} = model_operation(ctx, ctx.model_path)
      test_process = self()

      Application.put_env(:harness_forge, :model_test_plug, fn conn ->
        case conn.request_path do
          "/api/tags" ->
            tags_response(conn)

          ^send_path ->
            send(test_process, :authorized_provider_send)
            receipt = restrict!(ctx.source)
            send(test_process, {:restriction, receipt})
            model_response(conn, ctx)
        end
      end)

      assert {:error, _} = operation.()
      assert_received :authorized_provider_send
      refute_received :authorized_provider_send
      assert_received {:restriction, receipt}
      assert_pending(receipt)

      assert [["completed", "reported"]] ==
               Repo.query!(
                 "SELECT state,usage_status FROM model_requests WHERE workspace_id=? AND run_id=?",
                 [Store.workspace(), run_id]
               ).rows

      # Only the explicitly seeded claim exists; held provider output is not admitted.
      assert [[1]] ==
               Repo.query!(
                 "SELECT count(*) FROM evidence_claims WHERE workspace_id=?",
                 [Store.workspace()]
               ).rows
    end
  end

  defp model_operation(ctx, "runtime_chat") do
    Application.put_env(:harness_forge, :model_test_plug, &tags_response/1)
    run = Ecto.UUID.generate()
    {:ok, scope} = Runtime.prepare(run, source_ids: [ctx.source["id"]])

    body = %{
      "model" => scope.config["model"],
      "messages" => [
        %{"role" => "user", "content" => ctx.passage["snippet"]}
      ]
    }

    {fn -> Runtime.chat(scope, body) end, run, "/api/chat"}
  end

  defp model_operation(ctx, "generic_chat") do
    run = Ecto.UUID.generate()
    {:ok, _} = Models.start_run(run)

    request = %{
      "purpose" => "chat",
      "run_id" => run,
      "request_id" => Ecto.UUID.generate(),
      "prompt" => ctx.passage["snippet"],
      "source_ids" => [ctx.source["id"]],
      "data_categories" => ~w(source_body chat_context),
      "max_output_tokens" => 1024
    }

    {fn -> Models.infer(request) end, run, "/api/generate"}
  end

  defp model_operation(ctx, "legacy_analysis") do
    run = Ecto.UUID.generate()
    {fn -> Analysis.analyze(ctx.legacy_input, run_id: run) end, run, "/api/generate"}
  end

  defp tags_response(conn),
    do:
      Req.Test.json(
        conn,
        %{"models" => [%{"name" => "synthetic-r01-fixture"}]}
      )

  defp model_response(%{request_path: "/api/chat"} = conn, _ctx),
    do:
      Req.Test.json(conn, %{
        "done" => true,
        "message" => %{
          "role" => "assistant",
          "content" => "R01_PROVIDER_OUTPUT_MUST_STAY_PRIVATE"
        },
        "prompt_eval_count" => 20,
        "eval_count" => 20
      })

  defp model_response(conn, ctx),
    do: Req.Test.json(conn, CompanyAnalysisFixture.response(ctx.report))

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
        "prompt" => "Synthetic R01 source-bearing dispatch: " <> ctx.passage["snippet"],
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

  defp restrict!(source) do
    assert {:ok, receipt} =
             Evidence.restrict_revision(
               %{
                 "version" => 1,
                 "source_id" => source["id"],
                 "revision_id" => source["latest_revision"]["id"],
                 "body_hash" => source["latest_revision"]["body_hash"],
                 "expected_generation" => 0,
                 "command_id" => Ecto.UUID.generate(),
                 "reason_code" => "operator_restriction"
               },
               caller()
             )

    receipt
  end

  defp assert_pending(receipt) do
    assert receipt["cleanup_state"] == "pending"
    assert receipt["cleanup_version"] == 0
    assert receipt["denied_purposes"] == ~w(inspection retrieval analysis compile)
    assert {:ok, ^receipt} = Evidence.revision_restriction_status(receipt["event_id"], caller())

    assert [["pending", "", 0]] ==
             Repo.query!(
               "SELECT state,cursor,lock_version FROM revision_use_cleanup WHERE workspace_id=? AND event_id=?",
               [Store.workspace(), receipt["event_id"]]
             ).rows
  end

  defp assert_same_bytes_other_tenant(ctx, receipt) do
    workspace = Store.workspace()
    other = Ecto.UUID.generate()
    root = Path.join(ctx.root, "other-tenant")
    File.mkdir_p!(root)
    Application.put_env(:harness_forge, :workspace_id, other)
    Application.put_env(:harness_forge, :workspace_root, root)

    try do
      {:ok, connection} =
        Evidence.connect(%{
          "provider" => "local",
          "name" => "Independent identity",
          "directory" => root
        })

      {:ok, source} =
        Evidence.import_markdown(connection["id"], %{
          "external_id" => ctx.source["external_id"],
          "title" => "Same bytes, independent tenant",
          "body" => ctx.source["latest_revision"]["body"]
        })

      assert source["latest_revision"]["body_hash"] == ctx.source["latest_revision"]["body_hash"]
      assert source["id"] != ctx.source["id"]
      assert {:ok, page} = CorpusReview.source_page(%{"query" => "policy"}, caller())
      assert [row] = page["rows"]

      assert {:ok, window} =
               CorpusReview.passage(row["passage_token"], passage_attrs(source), caller())

      assert window["text"] == source["latest_revision"]["body"]

      assert {:error, :not_found} =
               Evidence.revision_restriction_status(receipt["event_id"], caller())
    after
      assert {:ok, _} = Privacy.purge_workspace(other)
      Application.put_env(:harness_forge, :workspace_id, workspace)
      Application.put_env(:harness_forge, :workspace_root, ctx.root)
    end
  end

  defp identity(passage),
    do:
      Map.take(
        passage,
        ~w(passage_id source_id revision_id body_hash start_byte end_byte snippet_hash parent_start_byte parent_end_byte parent_hash)
      )

  defp passage_attrs(source),
    do: %{
      "source_id" => source["id"],
      "revision_id" => source["latest_revision"]["id"],
      "body_hash" => source["latest_revision"]["body_hash"],
      "start_byte" => 0
    }

  defp caller,
    do: [
      authorize: fn -> true end,
      session_fingerprint: Contracts.sha256("R01 persisted consumers"),
      view_generation: String.duplicate("a", 32),
      reset_token: 0
    ]
end
