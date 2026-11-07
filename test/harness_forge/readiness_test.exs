defmodule HarnessForge.ReadinessTest do
  use HarnessForge.DataCase, async: false

  alias HarnessForge.{Company, Contracts, Decisions, Evaluations, Evidence, Goals, Harnesses}
  alias HarnessForge.{Privacy, Readiness, Releases, Workspaces}
  alias HarnessForge.Evaluation.Run
  alias HarnessForge.Execution.Docker
  alias HarnessForge.Evaluation.TaskSuite
  alias HarnessForge.Execution.Command
  alias HarnessForge.Harnesses.ArtifactBinding
  alias HarnessForge.Models.Configuration
  alias HarnessForge.Releases.Validation

  @sentinel "PRIVATE_READINESS_SENTINEL_DO_NOT_PROJECT"
  @stages ~w(integrity eligibility managed_runtime evaluation applicability cleanup release_admission)
  @tables ~w(evaluation_runs claim_decisions company_plans company_plan_decisions company_artifact_bindings release_approvals release_channels release_history audit_events model_requests model_settings)
  @prohibited_mfas [
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
    {HarnessForge.Execution.Coding, :availability, 0},
    {HarnessForge.Execution.Coding, :profile, 1},
    {HarnessForge.Execution.Coding, :profile_digest, 1},
    {HarnessForge.Execution.Coding, :admit, 1},
    {HarnessForge.Execution.Coding, :run, 3},
    {HarnessForge.Execution.Coding, :stop_session, 1},
    {HarnessForge.Execution.Coding, :cleanup, 1},
    {HarnessForge.Execution.Coding, :coding_command, 2},
    {HarnessForge.Execution.Coding, :coding_command, 4},
    {HarnessForge.Execution.CodingTransport, :observe, 0},
    {HarnessForge.Execution.CodingTransport, :verify, 1}
  ]
  @trace_observers [
    {Readiness, :for_artifact, 2},
    {HarnessForge.MCP.Tools, :call, 2},
    {__MODULE__, :trace_marker, 0}
  ]

  setup do
    previous_root = Application.fetch_env!(:harness_forge, :workspace_root)
    previous_id = Workspaces.current_id()
    root = Path.join(File.cwd!(), "tmp/readiness-#{Ecto.UUID.generate()}")
    for directory <- ~w(artifacts runs tmp input), do: File.mkdir_p!(Path.join(root, directory))
    Application.put_env(:harness_forge, :workspace_root, root)
    Application.put_env(:harness_forge, :workspace_id, Ecto.UUID.generate())

    on_exit(fn ->
      Application.put_env(:harness_forge, :workspace_root, previous_root)
      Application.put_env(:harness_forge, :workspace_id, previous_id)
      File.rm_rf!(root)
    end)

    {:ok, connection} =
      Evidence.connect(%{
        "provider" => "local",
        "name" => "Synthetic",
        "directory" => Path.join(root, "input")
      })

    {:ok, source} =
      Evidence.import_markdown(connection["id"], %{
        "external_id" => "policy.md",
        "title" => "Synthetic",
        "body" => @sentinel
      })

    {:ok, citation} = Evidence.citation(source["latest_revision"]["id"], 0, byte_size(@sentinel))
    {:ok, claim} = Evidence.create_claim(%{"text" => @sentinel, "citations" => [citation]})
    {:ok, claim} = Decisions.decide(claim["id"], decision(claim))

    {:ok, goal} =
      Goals.add_goal(%{
        "title" => @sentinel,
        "owner" => "Synthetic",
        "acceptance" => "Checks pass"
      })

    {:ok, profile} =
      Company.save_profile(%{"name" => "Synthetic", "source_ids" => [source["id"]]})

    {:ok, repository} =
      Company.create_repository(%{
        "identity" => "synthetic/service",
        "name" => "Synthetic",
        "purpose" => @sentinel,
        "owner" => "Synthetic"
      })

    {:ok, project} =
      Company.create_project(%{
        "name" => "Synthetic",
        "repository_ids" => [repository["id"]],
        "goal_ids" => [goal["id"]]
      })

    attrs = %{
      "name" => "synthetic-readiness",
      "package_version" => "0.1.0",
      "project_id" => project["id"],
      "repository_ids" => [repository["id"]],
      "claim_refs" => [Map.take(claim, ~w(id revision_hash))],
      "goal_ids" => [goal["id"]],
      "template_ids" => ["reviewed-change-v1"],
      "runtime" => "opencode",
      "runtime_version" => Docker.version(),
      "execution" => %{"max_turns" => 10, "timeout_seconds" => 120}
    }

    plan = approved_plan(attrs)
    {:ok, artifact} = Harnesses.build_plan(plan["id"], plan["revision_hash"])

    %{
      root: root,
      artifact: artifact,
      plan: plan,
      attrs: attrs,
      source: source,
      claim: claim,
      goal: goal,
      profile: profile,
      project: project
    }
  end

  test "no selection inspects exact authority without task identities or implicit evidence",
       ctx do
    _ = trusted_fixture(ctx.artifact)
    assert {:ok, report} = Readiness.for_artifact(ctx.artifact["digest"])
    assert Enum.map(report["stages"], & &1["name"]) == @stages
    assert stage(report, "integrity")["status"] == "passed"
    assert stage(report, "eligibility")["status"] == "passed"
    assert stage(report, "evaluation")["reason_code"] == "no_evaluation_selected"
    assert stage(report, "release_admission")["status"] == "blocked"
    assert report["evaluation_id"] == nil
    assert report["evaluation_identities"] == %{}
    assert report["current_identities"] == %{}

    assert report["current_identity_assessment"] == %{
             "kind" => "task",
             "status" => "not_assessed",
             "reason_code" => "runtime_identity_check_required"
           }

    assert report["next_action"] == %{
             "code" => "select_evaluation",
             "destination" => "evaluations"
           }

    assert report["plan_bindings"] == [
             Map.take(ctx.plan, ~w(id revision_hash)) |> rename_binding()
           ]

    refute Jason.encode!(report) =~ @sentinel
  end

  test "inert potential-positive OpenCode task abstains without writes or saved current identity",
       ctx do
    run = trusted_fixture(ctx.artifact)
    before = snapshot(ctx.root)
    assert {:ok, report} = Readiness.for_artifact(ctx.artifact["digest"], run["id"])
    assert_abstention(report)
    assert stage(report, "evaluation")["status"] == "passed"
    assert stage(report, "cleanup")["status"] == "passed"
    assert report["current_identities"] == %{}

    assert report["evaluation_identities"]["environment_profile_digest"] ==
             run["environment_profile_digest"]

    assert report["next_action"] == %{
             "code" => "review_runtime_identity",
             "destination" => "releases"
           }

    assert snapshot(ctx.root) == before
    assert report["evaluation_id"] == run["id"]
    refute Jason.encode!(report) =~ @sentinel
  end

  test "non-OpenCode pure synthetic fixture retains exact final-gate parity and no-write hashes",
       ctx do
    artifact = pure_artifact(ctx)
    run = trusted_fixture(artifact)
    before = snapshot(ctx.root)
    assert :ok = Validation.check(artifact, run, scope(artifact))
    assert {:ok, report} = Readiness.for_artifact(artifact["digest"], run["id"])
    assert stage(report, "release_admission")["status"] == "passed"
    assert stage(report, "release_admission")["reason_code"] == "ready_for_release_review"
    assert stage(report, "managed_runtime")["status"] == "unavailable"

    assert report["current_identity_assessment"]["reason_code"] ==
             "current_task_identities_observed"

    assert report["current_identities"] == report["evaluation_identities"]
    assert report["current_identities"]["scope_digest"] == Contracts.digest(scope(artifact))
    refute Map.has_key?(report["current_identities"], "scope")
    assert snapshot(ctx.root) == before
    refute Jason.encode!(report) =~ @sentinel
  end

  test "static and smoke passes are observed independently and never qualify release", ctx do
    assert {:ok, static} = Evaluations.run(ctx.artifact["digest"], kind: :static_integrity)

    smoke =
      trusted_fixture(ctx.artifact, %{"kind" => "runtime_smoke", "runtime_qualified" => false})

    for run <- [static, smoke] do
      assert {:ok, report} = Readiness.for_artifact(ctx.artifact["digest"], run["id"])
      assert stage(report, "evaluation")["status"] == "passed"
      assert stage(report, "evaluation")["kind"] == run["kind"]

      assert stage(report, "release_admission")["reason_code"] ==
               "qualified_task_evaluation_required"

      refute stage(report, "release_admission")["status"] == "passed"
    end

    assert {:ok, report} = Readiness.for_artifact(ctx.artifact["digest"], static["id"])
    assert stage(report, "cleanup")["cleanup_status"] == "not_started"
    assert stage(report, "cleanup")["status"] == "blocked"
  end

  test "explicit failed selection cannot fall back to an older or newer passing run", ctx do
    _ = trusted_fixture(ctx.artifact)
    failed = trusted_fixture(ctx.artifact, %{"outcome" => "failed", "runtime_qualified" => false})
    _ = trusted_fixture(ctx.artifact)
    assert {:ok, report} = Readiness.for_artifact(ctx.artifact["digest"], failed["id"])
    assert report["evaluation_id"] == failed["id"]
    assert stage(report, "evaluation")["outcome"] == "failed"
    assert_abstention(report)
  end

  test "each persisted lifecycle and cleanup observation remains distinguishable", ctx do
    for outcome <- ~w(pending running blocked failed cancelled interrupted inconclusive timed_out) do
      run = trusted_fixture(ctx.artifact, %{"outcome" => outcome, "runtime_qualified" => false})
      assert {:ok, report} = Readiness.for_artifact(ctx.artifact["digest"], run["id"])
      assert stage(report, "evaluation")["outcome"] == outcome
      assert stage(report, "evaluation")["reason_code"] == "evaluation_" <> outcome
      assert_abstention(report)
    end

    for cleanup <- ~w(not_started not_dispatched pending cleanup_failed) do
      run = trusted_fixture(ctx.artifact, %{"cleanup_status" => cleanup})
      assert {:ok, report} = Readiness.for_artifact(ctx.artifact["digest"], run["id"])
      assert stage(report, "cleanup")["cleanup_status"] == cleanup
      assert stage(report, "cleanup")["status"] == "blocked"
      assert_abstention(report)

      assert report["next_action"] == %{
               "code" => "review_evaluation",
               "destination" => "evaluations"
             }
    end
  end

  test "malformed inputs never accept caller outcome or authority", ctx do
    for digest <- [
          nil,
          %{},
          "../package",
          String.duplicate("A", 64),
          String.duplicate("0", 65),
          String.duplicate("a", 64) <> "\n",
          1
        ],
        do: assert(Readiness.for_artifact(digest) == {:error, :invalid_readiness_reference})

    for id <- [%{"outcome" => "passed"}, [], 1, "", "not-a-uuid", String.duplicate("a", 1000)],
        do:
          assert(
            Readiness.for_artifact(ctx.artifact["digest"], id) ==
              {:error, :invalid_readiness_reference}
          )
  end

  test "missing and tampered packages return only fixed integrity failure metadata", ctx do
    assert {:ok, missing} = Readiness.for_artifact(String.duplicate("0", 64))
    assert stage(missing, "integrity")["reason_code"] == "artifact_integrity_unavailable"
    assert Enum.all?(tl(missing["stages"]), &(&1["status"] == "not_assessed"))
    assert missing["current_identities"] == %{}
    assert missing["current_identity_assessment"]["reason_code"] == "artifact_integrity_required"
    assert missing["next_action"] == %{"code" => "review_package", "destination" => "package"}
    [path | _] = Map.keys(ctx.artifact["files"])

    File.write!(
      Path.join([ctx.root, "artifacts", ctx.artifact["digest"], "payload", path]),
      @sentinel <> "tamper"
    )

    assert {:ok, tampered} = Readiness.for_artifact(ctx.artifact["digest"])
    assert stage(tampered, "integrity")["status"] == "blocked"
    assert tampered["plan_bindings"] == []
    refute Jason.encode!(tampered) =~ @sentinel
  end

  test "missing artifact store stays absent during a read", ctx do
    absent = Path.join(ctx.root, "absent")
    Application.put_env(:harness_forge, :workspace_root, absent)
    assert {:ok, report} = Readiness.for_artifact(ctx.artifact["digest"])
    assert stage(report, "integrity")["status"] == "blocked"
    refute File.exists?(absent)
  end

  test "foreign and missing runs are indistinguishable; another artifact reveals no metadata",
       ctx do
    foreign = trusted_fixture(ctx.artifact, %{"reason" => @sentinel})

    Repo.get!(Run, foreign["id"])
    |> Ecto.Changeset.change(workspace_id: "foreign-workspace")
    |> Repo.update!()

    assert {:ok, missing} = Readiness.for_artifact(ctx.artifact["digest"], Ecto.UUID.generate())
    assert {:ok, hidden} = Readiness.for_artifact(ctx.artifact["digest"], foreign["id"])
    assert missing["stages"] == hidden["stages"]
    assert hidden["evaluation_identities"] == %{}

    other =
      trusted_fixture(ctx.artifact, %{
        "artifact_digest" => String.duplicate("0", 64),
        "model_id" => @sentinel
      })

    assert {:ok, mismatch} = Readiness.for_artifact(ctx.artifact["digest"], other["id"])
    assert stage(mismatch, "evaluation")["reason_code"] == "evaluation_artifact_mismatch"
    refute Map.has_key?(stage(mismatch, "evaluation"), "outcome")
    assert mismatch["evaluation_identities"] == %{}
    refute Jason.encode!(mismatch) =~ @sentinel
  end

  test "every material identity mismatch on the pure non-OpenCode branch agrees with the gate",
       ctx do
    artifact = pure_artifact(ctx)

    for {key, value} <- identity_changes() do
      run = trusted_fixture(artifact, %{key => value})
      assert {:error, :evaluation_inapplicable} = Validation.check(artifact, run, scope(artifact))
      assert {:ok, report} = Readiness.for_artifact(artifact["digest"], run["id"])
      assert stage(report, "applicability")["status"] == "blocked", key
      assert stage(report, "release_admission")["reason_code"] == "evaluation_inapplicable", key
    end
  end

  test "OpenCode static and smoke applicability compares the actual pure identities", ctx do
    for kind <- ~w(static_integrity runtime_smoke) do
      run = trusted_fixture(ctx.artifact, %{"kind" => kind, "runtime_qualified" => false})
      assert :ok = Evaluations.applicability(ctx.artifact, run)
      assert {:ok, report} = Readiness.for_artifact(ctx.artifact["digest"], run["id"])
      assert stage(report, "applicability")["status"] == "passed"

      assert stage(report, "release_admission")["reason_code"] ==
               "qualified_task_evaluation_required"

      assert report["current_identities"] == %{}

      for {key, value} <- identity_changes() do
        changed =
          trusted_fixture(ctx.artifact, %{
            "kind" => kind,
            "runtime_qualified" => false,
            key => value
          })

        assert {:error, :evaluation_inapplicable} =
                 Evaluations.applicability(ctx.artifact, changed)

        assert {:ok, mismatch} = Readiness.for_artifact(ctx.artifact["digest"], changed["id"])
        assert stage(mismatch, "applicability")["status"] == "blocked", key

        assert stage(mismatch, "release_admission")["reason_code"] ==
                 "qualified_task_evaluation_required"
      end
    end
  end

  test "malformed OpenCode task evidence cannot turn missing current identity into admission",
       ctx do
    for changes <- [
          %{"completed_at" => nil},
          %{"checks" => []},
          %{"checks" => [%{"outcome" => "failed"}]},
          %{"checks" => [@sentinel]},
          %{"outcome" => @sentinel},
          %{"cleanup_status" => @sentinel},
          %{"suite_digest" => %{"private" => @sentinel}}
        ] do
      run = trusted_fixture(ctx.artifact, changes)
      assert {:ok, report} = Readiness.for_artifact(ctx.artifact["digest"], run["id"])
      assert_abstention(report)
      refute Jason.encode!(report) =~ @sentinel
    end

    run = trusted_fixture(ctx.artifact, %{"kind" => @sentinel})
    assert {:ok, report} = Readiness.for_artifact(ctx.artifact["digest"], run["id"])
    assert stage(report, "evaluation")["reason_code"] == "invalid_evaluation_record"
    assert stage(report, "applicability")["status"] == "not_assessed"
    assert stage(report, "applicability")["reason_code"] == "invalid_evaluation_record"
    assert stage(report, "release_admission")["reason_code"] == "invalid_evaluation_record"
    assert stage(report, "release_admission")["status"] == "blocked"
    refute Jason.encode!(report) =~ @sentinel
  end

  test "raw run prose, checks, configuration, actor and reason never enter the projection", ctx do
    run =
      trusted_fixture(
        ctx.artifact,
        Map.new(
          ~w(reason checks configuration actor task source rule goal endpoint credential_env),
          &{&1, @sentinel}
        )
      )

    assert {:ok, report} = Readiness.for_artifact(ctx.artifact["digest"], run["id"])
    refute Jason.encode!(report) =~ @sentinel

    run =
      trusted_fixture(ctx.artifact, %{
        "reason" => "relay_socket_unavailable",
        "outcome" => "blocked"
      })

    assert {:ok, report} = Readiness.for_artifact(ctx.artifact["digest"], run["id"])
    assert stage(report, "evaluation")["recorded_reason_code"] == "relay_socket_unavailable"
    assert stage(report, "managed_runtime")["reason_code"] == "model_not_selected"
  end

  test "model configuration changes do not replace missing current task identity with history",
       ctx do
    run = trusted_fixture(ctx.artifact)
    assert {:ok, before} = Readiness.for_artifact(ctx.artifact["digest"], run["id"])
    assert_abstention(before)
    assert {:ok, _} = Configuration.configure(%{"model" => "synthetic-model"})
    assert {:ok, after_change} = Readiness.for_artifact(ctx.artifact["digest"], run["id"])
    assert_abstention(after_change)
    assert stage(after_change, "managed_runtime")["status"] == "not_assessed"
    assert after_change["current_identities"] == %{}
    assert before["evaluation_identities"] == after_change["evaluation_identities"]
  end

  test "unsupported Claude managed backend remains unavailable with the safe rebuild action",
       ctx do
    for runtime <- ~w(claude_code) do
      plan =
        approved_plan(
          Map.merge(ctx.attrs, %{"runtime" => runtime, "runtime_version" => "unqualified"})
        )

      assert {:ok, artifact} = Harnesses.build_plan(plan["id"], plan["revision_hash"])
      assert {:ok, report} = Readiness.for_artifact(artifact["digest"])
      assert stage(report, "managed_runtime")["status"] == "unavailable"
      assert stage(report, "managed_runtime")["reason_code"] == "runtime_backend_unavailable"

      assert report["next_action"] == %{
               "code" => "review_supported_runtime",
               "destination" => "company"
             }
    end
  end

  test "managed Codex cannot inherit an inert task fixture without its original context", ctx do
    assert {:ok, _} = Configuration.configure(%{"model" => nil})

    plan =
      approved_plan(Map.merge(ctx.attrs, %{"runtime" => "codex", "runtime_version" => "0.156.0"}))

    assert {:ok, artifact} = Harnesses.build_plan(plan["id"], plan["revision_hash"])

    # Privileged inert rows do not supply the original managed driver/model context.
    run =
      trusted_fixture(artifact, %{
        "runtime_name" => "codex",
        "execution_profile_id" => "docker-codex-isolated-v1",
        "environment_profile_digest" => String.duplicate("b", 64)
      })

    assert Repo.get!(Run, run["id"]).execution_context == nil
    before = snapshot(ctx.root)

    report =
      assert_no_commands(
        fn ->
          assert {:error, :evaluation_inapplicable} =
                   Validation.check(artifact, run, scope(artifact))

          assert {:ok, report} = Readiness.for_artifact(artifact["digest"], run["id"])
          report
        end,
        1
      )

    assert stage(report, "managed_runtime")["reason_code"] == "model_not_selected"
    assert stage(report, "managed_runtime")["status"] == "unavailable"
    assert_abstention(report)

    assert Enum.find(report["blockers"], &(&1["stage"] == "managed_runtime"))["action"] ==
             "configure_model"

    assert snapshot(ctx.root) == before
    refute Jason.encode!(report) =~ @sentinel
  end

  test "stale evidence is rechecked and a formerly positive observation does not authorize release",
       ctx do
    artifact = pure_artifact(ctx)
    run = trusted_fixture(artifact)
    assert {:ok, before} = Readiness.for_artifact(artifact["digest"], run["id"])
    assert stage(before, "release_admission")["status"] == "passed"
    assert {:ok, _} = Evidence.revoke_source(ctx.source["id"])
    assert {:ok, after_change} = Readiness.for_artifact(artifact["digest"], run["id"])
    assert stage(after_change, "eligibility")["reason_code"] == "stale_or_revoked_evidence"
    assert after_change["next_action"]["destination"] == "company"

    assert {:error, :stale_or_revoked_evidence} =
             Releases.approve(%{
               "artifact_digest" => artifact["digest"],
               "evaluation_id" => run["id"],
               "scope" => scope(artifact),
               "actor" => "Synthetic"
             })
  end

  test "company snapshot drift blocks eligibility even with retained passing evidence", ctx do
    run = trusted_fixture(ctx.artifact)

    assert {:ok, _} =
             Company.update_project(
               ctx.project["id"],
               replacement(ctx.project, %{"description" => "Changed"})
             )

    assert {:ok, report} = Readiness.for_artifact(ctx.artifact["digest"], run["id"])
    assert stage(report, "eligibility")["reason_code"] == "stale_or_revoked_plan"
    assert_abstention(report)
  end

  test "multiple bindings are sorted provenance and preserve any-valid-binding authority", ctx do
    duplicate = approved_plan(ctx.attrs)
    assert {:ok, artifact} = Harnesses.build_plan(duplicate["id"], duplicate["revision_hash"])
    assert artifact == ctx.artifact
    invalid_plan = approved_plan(Map.put(ctx.attrs, "package_version", "0.2.0"))
    # Privileged synthetic provenance fixture: retained invalid binding must not
    # override the existing any-valid-binding semantics or be called approved.
    Repo.insert!(%ArtifactBinding{
      workspace_id: Workspaces.current_id(),
      plan_id: invalid_plan["id"],
      plan_revision_hash: invalid_plan["revision_hash"],
      artifact_digest: artifact["digest"],
      inserted_at: DateTime.utc_now()
    })

    assert {:ok, report} = Readiness.for_artifact(artifact["digest"])

    assert report["plan_bindings"] ==
             Enum.sort_by(report["plan_bindings"], &{&1["plan_id"], &1["plan_revision_hash"]})

    assert length(report["plan_bindings"]) == 3
    assert stage(report, "eligibility")["status"] == "passed"
    assert :ok = Harnesses.eligible(artifact)
  end

  test "a proposed successor leaves the approved predecessor eligible", ctx do
    assert {:ok, _} =
             Company.create_plan(
               Map.merge(ctx.attrs, %{
                 "supersedes_id" => ctx.plan["id"],
                 "package_version" => "0.2.0"
               })
             )

    assert {:ok, report} = Readiness.for_artifact(ctx.artifact["digest"])
    assert stage(report, "eligibility")["status"] == "passed"
  end

  test "readiness shares the purge fence and refuses an incomplete operation", ctx do
    parent = self()

    task =
      HarnessForge.Privacy.Purge.synchronize(fn ->
        task =
          Task.async(fn ->
            send(parent, :readiness_waiting)
            Readiness.for_artifact(ctx.artifact["digest"])
          end)

        assert_receive :readiness_waiting
        assert Task.yield(task, 30) == nil
        task
      end)

    assert {:ok, _} = Task.await(task, 5_000)

    now = DateTime.to_iso8601(DateTime.utc_now())

    Repo.query!(
      "INSERT INTO privacy_operations (id,workspace_id,kind,target_id,state,plan,inserted_at,updated_at) VALUES (?,?,?,?,?,?,?,?)",
      [
        Ecto.UUID.generate(),
        Workspaces.current_id(),
        "source",
        ctx.source["id"],
        "prepared",
        "{}",
        now,
        now
      ]
    )

    assert {:error, :privacy_operation_incomplete} =
             Readiness.for_artifact(ctx.artifact["digest"])
  end

  test "source purge removes the saved package and leaves no retained report authority", ctx do
    assert {:ok, _} = Readiness.for_artifact(ctx.artifact["digest"])
    assert {:ok, _} = Privacy.purge_source(ctx.source["id"], ctx.source["id"])
    assert {:ok, report} = Readiness.for_artifact(ctx.artifact["digest"])
    assert stage(report, "integrity")["status"] == "blocked"
    assert report["plan_bindings"] == []
    assert report["current_identities"] == %{}
    refute Jason.encode!(report) =~ @sentinel
  end

  test "actual synchronous inspection makes no low-level commands across all OpenCode branches",
       ctx do
    static =
      trusted_fixture(ctx.artifact, %{"kind" => "static_integrity", "runtime_qualified" => false})

    smoke =
      trusted_fixture(ctx.artifact, %{"kind" => "runtime_smoke", "runtime_qualified" => false})

    potential = trusted_fixture(ctx.artifact)
    failed = trusted_fixture(ctx.artifact, %{"outcome" => "failed"})
    cancelled = trusted_fixture(ctx.artifact, %{"outcome" => "cancelled"})
    incomplete = trusted_fixture(ctx.artifact, %{"cleanup_status" => "cleanup_failed"})
    unknown = trusted_fixture(ctx.artifact, %{"kind" => "unknown"})
    other = trusted_fixture(ctx.artifact, %{"artifact_digest" => String.duplicate("0", 64)})
    foreign = trusted_fixture(ctx.artifact)

    Repo.get!(Run, foreign["id"])
    |> Ecto.Changeset.change(workspace_id: "foreign-workspace")
    |> Repo.update!()

    mutations =
      for {key, value} <- identity_changes(), do: trusted_fixture(ctx.artifact, %{key => value})

    ids =
      [
        nil,
        Ecto.UUID.generate(),
        static["id"],
        smoke["id"],
        potential["id"],
        failed["id"],
        cancelled["id"],
        incomplete["id"],
        unknown["id"],
        other["id"],
        foreign["id"]
      ] ++ Enum.map(mutations, & &1["id"])

    before = snapshot(ctx.root)

    reports =
      assert_no_commands(
        fn ->
          for id <- ids do
            assert {:ok, report} = Readiness.for_artifact(ctx.artifact["digest"], id)
            report
          end
        end,
        length(ids)
      )

    assert snapshot(ctx.root) == before
    for report <- Enum.drop(reports, 11), do: assert_abstention(report)
    assert_abstention(Enum.at(reports, 4))
    assert Enum.at(reports, 4)["next_action"]["code"] == "review_runtime_identity"
    assert Enum.at(reports, 5)["next_action"]["code"] == "review_evaluation"
    assert Enum.at(reports, 7)["next_action"]["code"] == "review_evaluation"
    refute Jason.encode!(reports) =~ @sentinel
  end

  defp approved_plan(attrs) do
    {:ok, plan} = Company.create_plan(attrs)
    {:ok, plan} = Company.decide_plan(plan["id"], decision(plan))
    plan
  end

  test "all three actual MCP read tools remain command-free with private attempt context", ctx do
    public = trusted_fixture(ctx.artifact)

    private = %{
      "version" => "coding-transport-v2",
      "route" => "desktop_loopback_proxy",
      "endpoint" => "unix:///private/MCP_CONTEXT_ENDPOINT.sock",
      "daemon_id" => "MCP:PRIVATE:DAEMON",
      "workspace_id" => Workspaces.current_id(),
      "run_id" => public["id"]
    }

    Repo.get!(Run, public["id"])
    |> Ecto.Changeset.change(execution_context: private)
    |> Repo.update!()

    before = snapshot(ctx.root)

    assert_no_commands(
      fn ->
        assert {:ok, repositories} =
                 HarnessForge.MCP.Tools.call("harnessforge_search_repositories", %{
                   "query" => "synthetic"
                 })

        assert {:ok, plans} = HarnessForge.MCP.Tools.call("harnessforge_company_plans", %{})

        assert {:ok, plan} =
                 HarnessForge.MCP.Tools.call("harnessforge_company_plans", %{
                   "plan_id" => ctx.plan["id"]
                 })

        assert {:ok, package} =
                 HarnessForge.MCP.Tools.call("harnessforge_inspect_package", %{
                   "digest" => ctx.artifact["digest"]
                 })

        assert package["qualification"] == "not_assessed_by_this_tool"

        for result <- [repositories, plans, plan, package] do
          refute Jason.encode!(result) =~ "MCP_CONTEXT_ENDPOINT"
          refute Jason.encode!(result) =~ "MCP:PRIVATE:DAEMON"
        end
      end,
      0,
      4
    )

    assert snapshot(ctx.root) == before
  end

  defp decision(dto),
    do: %{
      "actor" => "Synthetic",
      "decision" => "approve",
      "expected_revision_hash" => dto["revision_hash"]
    }

  defp replacement(dto, changes),
    do:
      dto["payload"]
      |> Map.merge(changes)
      |> Map.put("expected_content_hash", dto["content_hash"])

  defp rename_binding(dto),
    do: %{"plan_id" => dto["id"], "plan_revision_hash" => dto["revision_hash"]}

  defp stage(report, name), do: Enum.find(report["stages"], &(&1["name"] == name))
  defp scope(artifact), do: artifact["spec"]["spec"]["scope"]

  defp assert_abstention(report) do
    for name <- ~w(applicability release_admission) do
      assert stage(report, name)["status"] == "not_assessed"
      assert stage(report, name)["reason_code"] == "runtime_identity_check_required"
    end

    assert report["current_identities"] == %{}
    assert report["current_identity_assessment"]["status"] == "not_assessed"
  end

  defp pure_artifact(ctx) do
    plan =
      approved_plan(
        Map.merge(ctx.attrs, %{"runtime" => "claude_code", "runtime_version" => "2.1.311"})
      )

    {:ok, artifact} = Harnesses.build_plan(plan["id"], plan["revision_hash"])
    artifact
  end

  defp identity_changes do
    Enum.map(
      ~w(suite_digest grader_digest task_fixture_digest model_context_digest environment_profile_digest effective_config_digest capability_report_digest policy_digest),
      &{&1, String.duplicate("0", 64)}
    ) ++
      [
        {"suite_id", "different-suite"},
        {"runtime_image", "untrusted:latest"},
        {"runtime_version", "0.0.1"},
        {"model_id", "different/model"},
        {"scope", %{"repositories" => ["different/service"]}}
      ]
  end

  defp fixture_identities(artifact, kind) do
    if artifact["spec"]["spec"]["runtime"]["name"] == "opencode" do
      opencode_fixture_identities(artifact, kind)
    else
      # The non-OpenCode /1 branch is audited pure and never enters Coding.profile.
      Evaluations.applicability(artifact)
    end
  end

  defp opencode_fixture_identities(artifact, kind) do
    task? = kind not in ~w(static_integrity runtime_smoke)
    historical_digest = String.duplicate("b", 64)

    TaskSuite.identities()
    |> Map.merge(%{
      "artifact_digest" => artifact["digest"],
      "runtime_image" => Docker.image(),
      "runtime_version" => Docker.version(),
      "environment_profile_digest" =>
        if(task?, do: historical_digest, else: Docker.profile_digest()),
      "effective_config_digest" =>
        if(task?,
          do: historical_digest,
          else: Contracts.sha256(artifact["files"]["opencode.json"])
        ),
      "capability_report_digest" => Contracts.digest(artifact["capabilities"]),
      "policy_digest" => Contracts.digest(artifact["spec"]["spec"]["policies"]),
      "scope" => scope(artifact),
      "model_id" => if(task?, do: "historical/inert-model", else: "unavailable"),
      "model_context_digest" => if(task?, do: historical_digest, else: Contracts.digest(%{}))
    })
  end

  # Patterns are global, so this module is async:false. A separate collector
  # traces the actual context caller and inherited descendants using arities only.
  # Setup is outside the measured synchronous operation. Every real MFA must match;
  # unsupported instrumentation is a test failure, never an empty-mailbox pass.
  def trace_marker, do: :readiness_trace_marker

  defp assert_no_commands(fun, expected_calls, expected_tool_calls \\ 0) do
    patterns = @prohibited_mfas ++ @trace_observers
    for {module, _, _} <- patterns, do: Code.ensure_loaded!(module)
    assert Enum.filter(Command.module_info(:exports), fn {name, _} -> name == :run end) == []
    collector = spawn_link(fn -> trace_collector([], MapSet.new()) end)
    caller = self()
    send(collector, {:caller, caller})

    try do
      for mfa <- patterns do
        matches = :erlang.trace_pattern(mfa, true, [:local])
        IO.puts("READINESS_TRACE #{inspect(mfa)} matches=#{matches}")
        assert matches > 0, "Unsupported trace instrumentation: #{inspect(mfa)}"
      end

      assert :erlang.trace(caller, true, [
               :call,
               :arity,
               :procs,
               :set_on_spawn,
               {:tracer, collector}
             ]) == 1

      trace_marker()

      child =
        spawn(fn ->
          trace_marker()
          send(caller, {:marker_complete, self()})
        end)

      assert_receive {:marker_complete, ^child}, 5_000
      {calibration, descendants} = drain_trace(collector)
      assert Enum.count(calibration, &(&1 == {__MODULE__, :trace_marker, 0})) == 2
      assert child in descendants
      result = fun.()
      {calls, _tracees} = drain_trace(collector)
      assert Enum.count(calls, &(&1 == {Readiness, :for_artifact, 2})) == expected_calls
      assert Enum.count(calls, &(&1 == {HarnessForge.MCP.Tools, :call, 2})) == expected_tool_calls
      prohibited = Enum.filter(calls, &(&1 in @prohibited_mfas))
      assert prohibited == [], "Prohibited inspector call arities: #{inspect(prohibited)}"
      result
    after
      :erlang.trace(caller, false, [:all])
      {_calls, tracees} = drain_trace(collector)

      for pid <- tracees,
          pid != caller and Process.alive?(pid),
          do: :erlang.trace(pid, false, [:all])

      for mfa <- patterns, do: :erlang.trace_pattern(mfa, false, [:local])
      send(collector, :stop)
    end
  end

  defp drain_trace(collector) do
    tag = make_ref()
    send(collector, {:drain, self(), tag})
    assert_receive {^tag, calls, tracees}, 5_000
    {calls, tracees}
  end

  defp trace_collector(calls, tracees) do
    receive do
      {:caller, pid} ->
        trace_collector(calls, MapSet.put(tracees, pid))

      {:trace, _pid, :call, mfa} ->
        trace_collector([mfa | calls], tracees)

      {:trace, _pid, :spawn, child, _mfa} ->
        trace_collector(calls, MapSet.put(tracees, child))

      {:trace, pid, :spawned, _parent, _mfa} ->
        trace_collector(calls, MapSet.put(tracees, pid))

      {:drain, owner, tag} ->
        barrier = :erlang.trace_delivered(:all)
        {drained, pids} = trace_barrier(calls, tracees, barrier)
        send(owner, {tag, Enum.reverse(drained), MapSet.to_list(pids)})
        trace_collector(drained, pids)

      :stop ->
        :ok

      _ ->
        trace_collector(calls, tracees)
    end
  end

  defp trace_barrier(calls, tracees, barrier) do
    receive do
      {:trace_delivered, :all, ^barrier} ->
        {calls, tracees}

      {:trace, _pid, :call, mfa} ->
        trace_barrier([mfa | calls], tracees, barrier)

      {:trace, _pid, :spawn, child, _mfa} ->
        trace_barrier(calls, MapSet.put(tracees, child), barrier)

      {:trace, pid, :spawned, _parent, _mfa} ->
        trace_barrier(calls, MapSet.put(tracees, pid), barrier)

      _ ->
        trace_barrier(calls, tracees, barrier)
    end
  end

  # Privileged direct-DB observations test projection only. OpenCode task fields
  # are inert historical values, never a computed current live-bearing profile.
  # Pure non-task/non-OpenCode fixtures establish only existing gate comparison.
  defp trusted_fixture(artifact, overrides \\ %{}) do
    id = Ecto.UUID.generate()
    now = DateTime.to_iso8601(DateTime.utc_now())

    result =
      fixture_identities(artifact, overrides["kind"] || "task")
      |> Map.merge(%{
        "id" => id,
        "workspace_id" => Workspaces.current_id(),
        "kind" => "task",
        "outcome" => "passed",
        "runtime_qualified" => true,
        "cleanup_status" => "complete",
        "reason" => "fixture_only_state_machine_proof",
        "checks" => [%{"outcome" => "passed"}],
        "completed_at" => now,
        "inserted_at" => now
      })
      |> Map.merge(overrides)

    Repo.insert!(%Run{
      id: id,
      workspace_id: Workspaces.current_id(),
      artifact_digest: artifact["digest"],
      result: result
    })

    result
  end

  defp snapshot(root) do
    tables =
      Map.new(@tables, fn table ->
        rows = Repo.query!("SELECT * FROM " <> table).rows |> Enum.sort()
        {table, :crypto.hash(:sha256, :erlang.term_to_binary(rows))}
      end)

    files =
      Path.wildcard(Path.join(root, "**/*"), match_dot: true)
      |> Enum.filter(&File.regular?/1)
      |> Map.new(&{Path.relative_to(&1, root), Contracts.sha256(File.read!(&1))})

    %{tables: tables, files: files}
  end
end
