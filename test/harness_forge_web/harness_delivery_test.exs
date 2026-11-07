defmodule HarnessForgeWeb.HarnessDeliveryTest do
  use HarnessForgeWeb.ConnCase, async: false

  alias HarnessForge.{
    Artifacts,
    Company,
    Compiler,
    Contracts,
    Decisions,
    Evidence,
    Evaluations,
    Goals,
    Harnesses,
    Privacy,
    Repo,
    Workspaces
  }

  alias HarnessForge.Privacy.Purge
  alias HarnessForge.Company.{Analysis, Retrieval}
  alias HarnessForge.CompanyAnalysisFixture
  alias HarnessForge.Evidence.{Capture, Corpora, Passages, RevisionUseHolds}
  alias HarnessForge.Models.StageAuthority
  alias HarnessForgeWeb.HarnessDelivery
  alias HarnessForgeWeb.Plugs.OperatorSession

  setup %{conn: conn} do
    previous = {Workspaces.root(), Workspaces.current_id()}
    id = Ecto.UUID.generate()
    root = Path.join(File.cwd!(), "tmp/harness-delivery-#{id}")

    for directory <- ~w(artifacts runs tmp evidence),
        do: File.mkdir_p!(Path.join(root, directory))

    Application.put_env(:harness_forge, :workspace_root, root)
    Application.put_env(:harness_forge, :workspace_id, id)

    on_exit(fn ->
      Application.put_env(:harness_forge, :workspace_root, elem(previous, 0))
      Application.put_env(:harness_forge, :workspace_id, elem(previous, 1))
      File.rm_rf!(root)
    end)

    conn = %{conn | host: "localhost", port: 4002}
    {:ok, conn: authenticate(conn), root: root}
  end

  test "an actual approved build delivers exact runtime files without workspace metadata", ctx do
    %{artifact: artifact} = source_build(ctx.root)
    digest = artifact["digest"]
    assert {:ok, preview} = HarnessDelivery.preview(digest)
    assert preview["digest"] == digest
    assert preview["name"] == "company-delivery"
    assert preview["version"] == "0.1.0"
    assert preview["target"] == "claude_code"
    assert Enum.map(preview["files"], & &1["path"]) == Enum.sort(Map.keys(artifact["files"]))

    for file <- preview["files"] do
      assert file["content"] == artifact["files"][file["path"]]
      assert file["bytes"] == byte_size(file["content"])
      assert file["sha256"] == Contracts.sha256(file["content"])
      refute file["truncated"]
    end

    assert Enum.any?(
             preview["files"],
             &String.contains?(&1["content"], "<script>synthetic</script>")
           )

    assert preview["verification"]["generated"] == true
    assert preview["verification"]["integrity"] == "verified"
    assert preview["verification"]["current_decisions"] == "eligible"
    assert preview["verification"]["representative_task"] == "unobserved"
    assert preview["verification"]["release_qualification"] == "unobserved"
    refute Jason.encode!(preview) =~ ctx.root
    assert {:ok, download} = HarnessDelivery.download(digest)
    assert download["filename"] == "harness-#{digest}.zip"
    assert_zip(download["bytes"], artifact)
    assert {:ok, []} = HarnessForge.Evaluations.list_runs()
    assert {:ok, []} = HarnessForge.Releases.list()
  end

  test "large multibyte generated guidance is visibly truncated while ZIP keeps every byte",
       ctx do
    %{source: source} = source_build(ctx.root)
    citation = citation(source)

    for index <- 1..6 do
      approve_source_claim(citation, String.duplicate("é", 4_000) <> to_string(index))
    end

    assert {:ok, artifact} =
             Harnesses.build(%{"name" => "large-delivery", "runtime" => "claude_code"})

    assert {:ok, preview} = HarnessDelivery.preview(artifact["digest"])
    assert Enum.any?(preview["files"], & &1["truncated"])
    assert Enum.sum(Enum.map(preview["files"], &byte_size(&1["content"]))) <= 262_144

    for file <- preview["files"] do
      assert String.valid?(file["content"])
      assert byte_size(file["content"]) <= 32_768
      assert String.starts_with?(artifact["files"][file["path"]], file["content"])
      assert file["bytes"] == byte_size(artifact["files"][file["path"]])
      assert file["sha256"] == Contracts.sha256(artifact["files"][file["path"]])
    end

    assert {:ok, download} = HarnessDelivery.download(artifact["digest"])
    assert_zip(download["bytes"], artifact)
  end

  test "goal-origin delivery requires a real separate exact approved company plan", ctx do
    %{artifact: artifact, repository: repository} = plan_build()
    assert {:ok, preview} = HarnessDelivery.preview(artifact["digest"])
    assert preview["verification"]["current_decisions"] == "eligible"
    assert {:ok, download} = HarnessDelivery.download(artifact["digest"])
    assert_zip(download["bytes"], artifact)

    assert {:ok, _} =
             Company.update_repository(
               repository["id"],
               Map.merge(repository["payload"], %{
                 "purpose" => "Changed purpose",
                 "expected_content_hash" => repository["content_hash"]
               })
             )

    assert {:ok, ^artifact} = Harnesses.get(artifact["digest"])
    assert_unavailable(ctx.conn, artifact["digest"])
  end

  test "an integrity-valid package above the delivery entry limit is refused before ZIP allocation",
       ctx do
    %{artifact: original} = source_build(ctx.root)

    spec =
      original["spec"]
      |> put_in(
        ["spec", "agents"],
        Enum.map(1..32, fn i ->
          %{
            "name" => "agent-#{i}",
            "description" => "Synthetic agent",
            "instructions" => "Review changes."
          }
        end)
      )
      |> put_in(
        ["spec", "skills"],
        Enum.map(1..100, fn i ->
          %{
            "name" => "skill-#{i}",
            "description" => "Synthetic skill",
            "instructions" => "Review changes."
          }
        end)
      )

    assert {:ok, artifact} = Compiler.compile(spec)
    assert map_size(artifact["files"]) > 128
    assert {:ok, _} = Artifacts.publish(artifact)
    assert {:ok, ^artifact} = Harnesses.get(artifact["digest"])
    assert :ok = Harnesses.eligible(artifact)
    assert_unavailable(ctx.conn, artifact["digest"])
  end

  test "source revocation withdraws previously delivered files on every new read", ctx do
    %{artifact: artifact, source: source} = source_build(ctx.root)
    assert {:ok, _} = HarnessDelivery.preview(artifact["digest"])
    assert {:ok, _} = HarnessDelivery.download(artifact["digest"])
    assert {:ok, _} = Evidence.revoke_source(source["id"])
    assert_unavailable(ctx.conn, artifact["digest"])
  end

  test "superseding an approved claim refuses stored bytes without approving its successor",
       ctx do
    %{artifact: artifact, claim: claim} = source_build(ctx.root)

    assert {:ok, _} =
             Evidence.create_claim(%{
               "text" => "Changed synthetic guidance",
               "citations" => claim["citations"],
               "supersedes_id" => claim["id"]
             })

    assert_unavailable(ctx.conn, artifact["digest"])
  end

  test "a real source purge removes delivery and its stored artifact", ctx do
    %{artifact: artifact, source: source} = source_build(ctx.root)
    assert {:ok, %{"state" => "completed"}} = Privacy.purge_source(source["id"], source["id"])
    assert_unavailable(ctx.conn, artifact["digest"])
    refute File.exists?(Path.join([ctx.root, "artifacts", artifact["digest"]]))
  end

  test "pending purge blocks a previously checked artifact without returning private error details",
       ctx do
    %{artifact: artifact, source: source} = source_build(ctx.root)
    assert {:ok, _} = HarnessDelivery.preview(artifact["digest"])
    now = DateTime.to_iso8601(DateTime.utc_now())

    Repo.query!(
      "INSERT INTO privacy_operations(id,workspace_id,kind,target_id,state,plan,inserted_at,updated_at) VALUES(?,?,?,?,?,?,?,?)",
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

    assert {:error, :privacy_operation_incomplete} = Purge.ready()
    assert_unavailable(ctx.conn, artifact["digest"])
  end

  test "tampered payload bytes fail verification before either delivery method", ctx do
    %{artifact: artifact} = source_build(ctx.root)

    File.write!(
      Path.join([ctx.root, "artifacts", artifact["digest"], "payload", "CLAUDE.md"]),
      "PRIVATE_TAMPER_CANARY"
    )

    assert_unavailable(ctx.conn, artifact["digest"])
  end

  test "tampered artifact metadata cannot select different files or disclose its error", ctx do
    %{artifact: artifact} = source_build(ctx.root)
    metadata = Path.join([ctx.root, "artifacts", artifact["digest"], "artifact.json"])

    File.write!(
      metadata,
      Jason.encode!(put_in(artifact, ["files", "../../secret"], "PRIVATE_METADATA_CANARY"))
    )

    assert_unavailable(ctx.conn, artifact["digest"])
  end

  test "server workspace identity prevents delivery even when the other workspace knows the digest",
       ctx do
    %{artifact: artifact} = source_build(ctx.root)
    previous = Workspaces.current_id()
    Application.put_env(:harness_forge, :workspace_id, Ecto.UUID.generate())

    try do
      # Keep the old store physically present: current eligibility must still deny it.
      assert {:ok, ^artifact} = Harnesses.get(artifact["digest"])
      assert_unavailable(authenticate(ctx.conn), artifact["digest"])
    after
      Application.put_env(:harness_forge, :workspace_id, previous)
    end
  end

  test "authenticated ZIP requests accept application/zip and set private attachment headers",
       ctx do
    %{artifact: artifact} = source_build(ctx.root)

    conn =
      ctx.conn
      |> put_req_header("accept", "application/zip")
      |> get(download_path(artifact["digest"]))

    assert byte_size(response(conn, 200)) > 0
    assert get_resp_header(conn, "content-type") == ["application/zip"]
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "attachment"
    assert disposition =~ "harness-#{artifact["digest"]}.zip"
    assert_zip(conn.resp_body, artifact)
  end

  test "unauthenticated downloads redirect before any artifact bytes", ctx do
    %{artifact: artifact} = source_build(ctx.root)

    conn =
      build_conn()
      |> Map.put(:host, "localhost")
      |> Map.put(:port, 4002)
      |> put_req_header("accept", "application/zip")
      |> get(download_path(artifact["digest"]))

    assert redirected_to(conn) == "/login"
    refute conn.resp_body =~ "<script>synthetic</script>"
    refute conn.resp_body =~ artifact["digest"]
  end

  test "invalid, nonexistent and hostile references share a body-free service refusal", ctx do
    for digest <- [
          nil,
          %{},
          "../access-token",
          String.duplicate("A", 64),
          String.duplicate("a", 64)
        ] do
      assert {:error, :harness_unavailable} = HarnessDelivery.preview(digest)
      assert {:error, :harness_unavailable} = HarnessDelivery.download(digest)
    end

    assert_unavailable(ctx.conn, String.duplicate("a", 64))
  end

  test "delivery waits for the existing privacy fence before checking artifact bytes", ctx do
    %{artifact: artifact} = source_build(ctx.root)
    lock = {{Purge, Workspaces.current_id()}, self()}
    assert :global.set_lock(lock)
    task = Task.async(fn -> HarnessDelivery.download(artifact["digest"]) end)

    try do
      assert Task.yield(task, 30) == nil
    after
      :global.del_lock(lock)
    end

    assert {:ok, download} = Task.await(task, 5_000)
    assert_zip(download["bytes"], artifact)
  end

  test "real recorded static and blocked backend checks remain historical observations", ctx do
    %{artifact: artifact} = source_build(ctx.root)
    assert {:ok, static} = Evaluations.run(artifact["digest"], kind: :static_integrity)
    assert {:ok, runtime} = Evaluations.run(artifact["digest"], kind: :runtime_smoke)
    assert {:ok, task} = Evaluations.run(artifact["digest"], kind: :task)
    assert static["outcome"] == "passed"
    assert runtime["outcome"] == "blocked"
    assert task["outcome"] == "blocked"
    assert {:ok, preview} = HarnessDelivery.preview(artifact["digest"])
    checks = preview["verification"]["recorded_checks"]
    assert checks["status"] == "available"

    assert MapSet.new(Enum.map(checks["rows"], & &1["id"])) ==
             MapSet.new([static["id"], runtime["id"], task["id"]])

    assert Enum.any?(
             checks["rows"],
             &(&1["kind"] == "static_integrity" and &1["outcome"] == "passed" and
                 &1["reason"] == "integrity_only")
           )

    assert Enum.count(
             checks["rows"],
             &(&1["outcome"] == "blocked" and &1["reason"] == "runtime_backend_unavailable")
           ) == 2

    assert preview["verification"]["representative_task"] == "unobserved"
    assert preview["verification"]["release_qualification"] == "unobserved"

    for row <- checks["rows"] do
      assert Enum.sort(Map.keys(row)) == ~w(id inserted_at kind outcome reason)
      assert {:ok, _, _} = DateTime.from_iso8601(row["inserted_at"])
    end
  end

  test "history selects only the latest ten exact workspace and artifact records with stable tie order",
       ctx do
    %{artifact: artifact} = source_build(ctx.root)

    ids =
      for i <- 1..15, do: "00000000-0000-4000-8000-" <> String.pad_leading(to_string(i), 12, "0")

    for id <- ids do
      insert_history(artifact["digest"], id, "2026-01-01T12:00:00.000000Z", %{
        "kind" => "static_integrity",
        "outcome" => "passed",
        "reason" => "integrity_only"
      })
    end

    insert_history(String.duplicate("0", 64), Ecto.UUID.generate(), "2027-01-01T12:00:00Z", %{
      "reason" => "OTHER_ARTIFACT_CANARY"
    })

    insert_history(
      artifact["digest"],
      Ecto.UUID.generate(),
      "2027-01-01T12:00:00Z",
      %{"reason" => "OTHER_WORKSPACE_CANARY"},
      Ecto.UUID.generate()
    )

    assert {:ok, rows} = Evaluations.recent_summaries(artifact["digest"])
    expected_ids = ids |> Enum.reverse() |> Enum.take(10)
    assert Enum.map(rows, & &1["id"]) == expected_ids
    assert {:ok, preview} = HarnessDelivery.preview(artifact["digest"])

    assert preview["verification"]["recorded_checks"] == %{
             "status" => "available",
             "rows" => rows
           }

    refute Jason.encode!(preview) =~ "OTHER_ARTIFACT_CANARY"
    refute Jason.encode!(preview) =~ "OTHER_WORKSPACE_CANARY"
  end

  test "malformed and large stored fields project fixed unknowns without result or context hydration",
       ctx do
    %{artifact: artifact} = source_build(ctx.root)
    canary = "SYNTHETIC_PROTECTED_FIELD_CANARY"

    insert_history(artifact["digest"], Ecto.UUID.generate(), "2026-01-01T12:00:00Z", %{
      "kind" => %{"nested" => canary},
      "outcome" => [canary],
      "reason" => String.duplicate(canary, 4_000),
      "logs" => canary,
      "grader" => %{"details" => canary},
      "prompt" => canary
    })

    insert_history(
      artifact["digest"],
      Ecto.UUID.generate(),
      "bad timestamp",
      "not-json-" <> canary
    )

    insert_history(artifact["digest"], Ecto.UUID.generate(), "2026-01-01T12:00:01Z", %{
      "kind" => "static_integrity",
      "outcome" => "passed",
      "reason" => nil
    })

    handler = "history-projection-" <> Ecto.UUID.generate()

    :ok =
      :telemetry.attach(
        handler,
        [:harness_forge, :repo, :query],
        fn _, _, metadata, pid ->
          if String.contains?(metadata.query, "FROM evaluation_runs"),
            do: send(pid, {:history_projection_sql, metadata.query})
        end,
        self()
      )

    try do
      assert {:ok, preview} = HarnessDelivery.preview(artifact["digest"])
      checks = preview["verification"]["recorded_checks"]
      assert checks["status"] == "available"
      assert length(checks["rows"]) == 3

      assert Enum.count(
               checks["rows"],
               &(&1["kind"] == "unknown" and &1["outcome"] == "unknown" and
                   &1["reason"] == "unknown")
             ) == 2

      assert Enum.any?(checks["rows"], &(&1["inserted_at"] == "unknown"))
      assert Enum.any?(checks["rows"], &is_nil(&1["reason"]))
      refute Jason.encode!(checks) =~ canary
      assert_receive {:history_projection_sql, sql}
      assert sql =~ "json_extract(result"
      assert sql =~ "LIMIT 10"
      refute sql =~ "execution_context"
      refute sql =~ "SELECT result"
    after
      :telemetry.detach(handler)
    end
  end

  test "empty history and unavailable history are distinct while eligible files and ZIP stay usable",
       ctx do
    %{artifact: artifact} = source_build(ctx.root)
    assert {:ok, preview} = HarnessDelivery.preview(artifact["digest"])
    assert preview["verification"]["recorded_checks"] == %{"status" => "available", "rows" => []}
    Repo.query!("ALTER TABLE evaluation_runs RENAME TO unavailable_evaluation_runs")

    try do
      assert {:error, :evaluation_history_unavailable} =
               Evaluations.recent_summaries(artifact["digest"])

      assert {:ok, unavailable} = HarnessDelivery.preview(artifact["digest"])

      assert unavailable["verification"]["recorded_checks"] == %{
               "status" => "unavailable",
               "rows" => []
             }

      assert unavailable["files"] == preview["files"]
      assert {:ok, download} = HarnessDelivery.download(artifact["digest"])
      assert_zip(download["bytes"], artifact)
    after
      Repo.query!("ALTER TABLE unavailable_evaluation_runs RENAME TO evaluation_runs")
    end
  end

  test "a historical pass cannot disclose a currently revoked artifact or its recorded checks",
       ctx do
    %{artifact: artifact, source: source} = source_build(ctx.root)

    assert {:ok, %{"outcome" => "passed"}} =
             Evaluations.run(artifact["digest"], kind: :static_integrity)

    assert {:ok, preview} = HarnessDelivery.preview(artifact["digest"])
    assert length(preview["verification"]["recorded_checks"]["rows"]) == 1
    assert {:ok, _} = Evidence.revoke_source(source["id"])
    assert_unavailable(ctx.conn, artifact["digest"])
  end

  test "invalid history references fail closed without broad history fallback" do
    for digest <- [nil, %{}, "../private", String.duplicate("A", 64)] do
      assert {:error, :evaluation_history_unavailable} = Evaluations.recent_summaries(digest)
    end
  end

  test "a coverage successor offers only its current review address while old harness bytes stay denied",
       ctx do
    recovery = recovery_build(ctx.root)
    digest = recovery.artifact["digest"]
    assert {:ok, _} = HarnessDelivery.preview(digest)
    assert {:error, :harness_unavailable} = HarnessDelivery.recovery(digest, recovery_caller())
    second = declare_recovery(recovery)
    current = declare_recovery(recovery)
    before = recovery_counts()

    assert {:ok, result} = HarnessDelivery.recovery(digest, recovery_caller())

    assert result == %{
             "reason" => "coverage_changed",
             "declaration_id" => current["id"],
             "declaration_digest" => current["digest"],
             "declaration_revision" => current["revision"],
             "href" =>
               "/company/corpus?" <>
                 URI.encode_query(%{
                   "declaration" => current["id"],
                   "declaration_digest" => current["digest"]
                 })
           }

    refute result["declaration_id"] == second["id"]
    assert_unavailable(ctx.conn, digest)
    assert recovery_counts() == before
  end

  test "recovery refuses malformed, denied, foreign-workspace and altered artifacts", ctx do
    recovery = recovery_build(ctx.root)
    declare_recovery(recovery)
    digest = recovery.artifact["digest"]
    assert {:ok, _} = HarnessDelivery.recovery(digest, recovery_caller())

    for invalid <- [nil, %{}, "../private", String.duplicate("A", 64)] do
      assert {:error, :harness_unavailable} =
               HarnessDelivery.recovery(invalid, recovery_caller())
    end

    assert {:error, :harness_unavailable} =
             HarnessDelivery.recovery(
               digest,
               Keyword.put(recovery_caller(), :authorize, fn -> false end)
             )

    previous = Workspaces.current_id()
    Application.put_env(:harness_forge, :workspace_id, Ecto.UUID.generate())

    try do
      assert {:error, :harness_unavailable} =
               HarnessDelivery.recovery(digest, recovery_caller())
    after
      Application.put_env(:harness_forge, :workspace_id, previous)
    end

    File.write!(Path.join([ctx.root, "artifacts", digest, "payload", "AGENTS.md"]), "tampered")
    assert {:error, :harness_unavailable} = HarnessDelivery.recovery(digest, recovery_caller())
  end

  test "a pending source hold prevents a current coverage recovery target before cleanup", ctx do
    recovery = recovery_build(ctx.root)
    declare_recovery(recovery)
    digest = recovery.artifact["digest"]
    assert {:ok, _} = HarnessDelivery.recovery(digest, recovery_caller())
    source = hd(recovery.sources)

    assert {:ok, %{"cleanup_state" => "pending"}} =
             RevisionUseHolds.restrict(
               %{
                 "version" => 1,
                 "source_id" => source["id"],
                 "revision_id" => source["latest_revision"]["id"],
                 "body_hash" => source["latest_revision"]["body_hash"],
                 "expected_generation" => 0,
                 "command_id" => Ecto.UUID.generate(),
                 "reason_code" => "operator_restriction"
               },
               recovery_caller()
             )

    assert {:error, :harness_unavailable} = HarnessDelivery.recovery(digest, recovery_caller())
    assert_unavailable(ctx.conn, digest)
  end

  test "source revocation prevents a previously available coverage recovery target", ctx do
    recovery = recovery_build(ctx.root)
    declare_recovery(recovery)
    digest = recovery.artifact["digest"]
    assert {:ok, _} = HarnessDelivery.recovery(digest, recovery_caller())
    assert {:ok, _} = Evidence.revoke_source(hd(recovery.sources)["id"])
    assert {:error, :harness_unavailable} = HarnessDelivery.recovery(digest, recovery_caller())
    assert_unavailable(ctx.conn, digest)
  end

  defp recovery_build(root) do
    fixture = CompanyAnalysisFixture.create!(root)

    for source <- fixture.sources,
        do:
          File.write!(
            Path.join(fixture.connection["directory"], source["external_id"]),
            source["latest_revision"]["body"]
          )

    {:ok, corpus} = Corpora.create(%{"name" => "Synthetic delivery recovery"}, recovery_caller())

    {:ok, _} =
      Company.bind_corpus(
        fixture.project["id"],
        corpus["id"],
        fixture.profile["content_hash"],
        fixture.project["content_hash"],
        recovery_caller()
      )

    {:ok, capture} =
      Capture.start_capture(corpus["id"], fixture.connection["id"], 0, recovery_caller())

    {:ok, captured} = Capture.run(capture["run_id"])
    assert captured["capture"]["complete"]
    {:ok, sources} = Evidence.list_sources()

    for source <- sources,
        do: assert({:ok, _} = Passages.index_revision(source["latest_revision"]["id"]))

    {:ok, current} = Corpora.get(corpus["id"])

    # Capture's exact receipt records passage readiness. The first capture
    # precedes indexing, so observe the same unchanged files after indexing.
    {:ok, capture} =
      Capture.start_capture(
        corpus["id"],
        fixture.connection["id"],
        current.semantic_generation,
        recovery_caller()
      )

    {:ok, captured} = Capture.run(capture["run_id"])
    assert captured["capture"]["complete"]
    {:ok, current} = Corpora.get(corpus["id"])
    recovery = %{fixture: fixture, corpus: corpus, capture: captured, sources: sources}
    declaration = declare_recovery(recovery)
    assert declaration["required_status"] == "complete"

    {:ok, retrieval} =
      Retrieval.retrieve(
        %{
          "corpus_id" => corpus["id"],
          "project_id" => fixture.project["id"],
          "goal_id" => fixture.goal["id"],
          "goal_hash" => Goals.content_hash(fixture.goal),
          "expected_generation" => current.semantic_generation,
          "question" => "Which emergency release review and rollback controls apply?",
          "mode" => "fts",
          "declaration_ref" => Map.take(declaration, ~w(id digest))
        },
        recovery_caller()
      )

    {:ok, _} =
      HarnessForge.Models.configure(%{
        "provider" => "ollama",
        "endpoint" => "http://127.0.0.1:11434",
        "model" => "synthetic-delivery-recovery"
      })

    {:ok, review} =
      StageAuthority.prepare_synthesis(
        retrieval["run_id"],
        retrieval["digest"],
        recovery_caller()
      )

    {:ok, _} =
      StageAuthority.grant_consent(
        review["stage_id"],
        review["manifest_id"],
        review["manifest_digest"],
        recovery_caller()
      )

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

    previous_plug = Application.get_env(:harness_forge, :model_test_plug)

    on_exit(fn ->
      if previous_plug,
        do: Application.put_env(:harness_forge, :model_test_plug, previous_plug),
        else: Application.delete_env(:harness_forge, :model_test_plug)
    end)

    Application.put_env(:harness_forge, :model_test_plug, fn conn ->
      Req.Test.json(conn, CompanyAnalysisFixture.response(report))
    end)

    {:ok, %{"claim" => claim}} =
      Analysis.analyze_retrieval(retrieval["run_id"], retrieval["digest"],
        caller: recovery_caller(),
        stage_id: review["stage_id"]
      )

    {:ok, claim} =
      Analysis.revise(
        claim["id"],
        claim["revision_hash"],
        Map.put(
          claim["basis"]["guidance"],
          "review_resolution",
          "Apply the documented emergency exception only within its recorded scope."
        )
      )

    {:ok, _} = Decisions.decide(claim["id"], CompanyAnalysisFixture.decision(claim))
    {:ok, plan} = Company.create_plan(CompanyAnalysisFixture.plan_attrs(fixture, claim))
    {:ok, _} = Company.decide_plan(plan["id"], CompanyAnalysisFixture.decision(plan))
    {:ok, artifact} = Harnesses.build_plan(plan["id"], plan["revision_hash"])
    Map.merge(recovery, %{artifact: artifact, declaration: declaration})
  end

  defp declare_recovery(recovery) do
    {:ok, context} =
      Corpora.requirements_context(
        recovery.corpus["id"],
        recovery.fixture.project["id"],
        recovery.fixture.goal["id"],
        Goals.content_hash(recovery.fixture.goal),
        recovery_caller()
      )

    {:ok, declaration} =
      Corpora.declare_requirements(
        recovery.corpus["id"],
        context["expected"],
        %{
          "project_id" => recovery.fixture.project["id"],
          "goal_id" => recovery.fixture.goal["id"],
          "primary_connection_id" => recovery.fixture.connection["id"],
          "entries" => [
            %{
              "connection_id" => recovery.fixture.connection["id"],
              "requirement" => "required",
              "capture_run_id" => recovery.capture["run_id"],
              "capture_revision" => recovery.capture["revision"]
            }
          ]
        },
        recovery_caller()
      )

    declaration
  end

  defp recovery_caller do
    [
      authorize: fn -> true end,
      session_fingerprint: Contracts.sha256("synthetic delivery recovery caller"),
      view_generation: String.duplicate("d", 32),
      reset_token: 0
    ]
  end

  defp recovery_counts do
    Map.new(
      ~w(model_requests evidence_claims claim_decisions company_plans company_plan_decisions corpus_requirements retrieval_runs),
      fn table ->
        [[count]] =
          Repo.query!("SELECT count(*) FROM #{table} WHERE workspace_id=?", [
            Workspaces.current_id()
          ]).rows

        {table, count}
      end
    )
  end

  defp insert_history(digest, id, timestamp, result, workspace_id \\ Workspaces.current_id()) do
    result = if is_binary(result), do: result, else: Jason.encode!(result)

    Repo.query!(
      "INSERT INTO evaluation_runs(id,workspace_id,artifact_digest,result,execution_context,inserted_at,updated_at) VALUES(?,?,?,?,?,?,?)",
      [
        id,
        workspace_id,
        digest,
        result,
        Jason.encode!(%{"protected" => "SYNTHETIC_PROTECTED_FIELD_CANARY"}),
        timestamp,
        timestamp
      ],
      log: false
    )
  end

  defp authenticate(conn),
    do: init_test_session(conn, %{"operator_auth" => OperatorSession.new_auth()})

  defp download_path(digest), do: "/harnesses/#{digest}/download"

  defp assert_unavailable(conn, digest) do
    assert {:error, :harness_unavailable} = HarnessDelivery.preview(digest)
    assert {:error, :harness_unavailable} = HarnessDelivery.download(digest)
    conn = conn |> put_req_header("accept", "application/zip") |> get(download_path(digest))
    assert response(conn, 404) == "Harness unavailable."
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    refute get_resp_header(conn, "content-type") == ["application/zip"]
  end

  defp assert_zip(bytes, artifact) do
    assert {:ok, entries} = :zip.extract(bytes, [:memory])
    extracted = Map.new(entries, fn {path, content} -> {List.to_string(path), content} end)
    assert map_size(extracted) == length(entries)
    assert extracted == artifact["files"]
    refute Map.has_key?(extracted, "artifact.json")
    refute Map.has_key?(extracted, "access-token")
  end

  defp source_build(root) do
    directory = Path.join(root, "evidence")

    assert {:ok, connection} =
             Evidence.connect(%{
               "name" => "Synthetic handbook",
               "provider" => "local",
               "directory" => directory
             })

    assert {:ok, source} =
             Evidence.import_markdown(connection["id"], %{
               "external_id" => "handbook.md",
               "title" => "Synthetic handbook",
               "body" => "Review changes before release.\n"
             })

    claim =
      approve_source_claim(
        citation(source),
        "Review <script>synthetic</script> changes deliberately."
      )

    assert {:ok, artifact} =
             Harnesses.build(%{"name" => "company-delivery", "runtime" => "claude_code"})

    %{artifact: artifact, source: source, claim: claim}
  end

  defp citation(source) do
    revision = source["latest_revision"]
    assert {:ok, citation} = Evidence.citation(revision["id"], 0, byte_size(revision["body"]))
    citation
  end

  defp approve_source_claim(citation, text) do
    assert {:ok, claim} = Evidence.create_claim(%{"text" => text, "citations" => [citation]})
    assert {:ok, approved} = Decisions.decide(claim["id"], decision(claim))
    approved
  end

  defp decision(record),
    do: %{
      "actor" => Workspaces.operator(),
      "decision" => "approve",
      "expected_revision_hash" => record["revision_hash"]
    }

  defp plan_build do
    assert {:ok, goal} =
             Goals.add_goal(%{
               "title" => "Record a review",
               "owner" => "Synthetic",
               "acceptance" => "A review is recorded"
             })

    assert {:ok, claim} =
             Evidence.create_claim(%{
               "text" => "Record a deliberate review.",
               "citations" => [],
               "basis" => %{
                 "kind" => "goal",
                 "version" => 1,
                 "goal_id" => goal["id"],
                 "goal_content_hash" => Goals.content_hash(goal)
               }
             })

    assert {:ok, claim} = Decisions.decide(claim["id"], decision(claim))
    assert {:error, :goal_claim_requires_plan} = Harnesses.build()

    assert {:ok, _} =
             Company.save_profile(%{"name" => "Synthetic Company", "goal_ids" => [goal["id"]]})

    assert {:ok, repository} =
             Company.create_repository(%{
               "identity" => "synthetic/service",
               "name" => "Service",
               "purpose" => "Public fixture",
               "owner" => "Synthetic"
             })

    assert {:ok, project} =
             Company.create_project(%{
               "name" => "Synthetic Project",
               "repository_ids" => [repository["id"]]
             })

    assert {:ok, plan} =
             Company.create_plan(%{
               "name" => "goal-delivery",
               "package_version" => "0.1.0",
               "project_id" => project["id"],
               "repository_ids" => [repository["id"]],
               "claim_refs" => [Map.take(claim, ~w(id revision_hash))],
               "goal_ids" => [goal["id"]],
               "template_ids" => ["reviewed-change-v1"],
               "runtime" => "codex",
               "runtime_version" => "unqualified",
               "execution" => %{"max_turns" => 20, "timeout_seconds" => 300}
             })

    assert {:error, :plan_not_approved} = Harnesses.build_plan(plan["id"], plan["revision_hash"])
    assert {:ok, _} = Company.decide_plan(plan["id"], decision(plan))
    assert {:ok, artifact} = Harnesses.build_plan(plan["id"], plan["revision_hash"])
    %{artifact: artifact, plan: plan, repository: repository}
  end
end
