defmodule HarnessForge.InterruptedCodingRecoveryTest do
  use HarnessForge.DataCase, async: false

  alias HarnessForge.{Audit, Contracts, Evaluations, Repo, Workspaces}
  alias HarnessForge.CodingDockerFixture, as: Fixture
  alias HarnessForge.Evaluation.Run
  alias HarnessForge.Execution.{Coding, Docker}
  alias HarnessForge.Models.{Configuration, Ledger}

  # These calls reserve and settle synthetic ledger records only. No provider
  # transport, runtime image, candidate code or model service is started.
  @config %{
    "provider" => "synthetic-fixture",
    "model" => "synthetic-recovery",
    "input_microusd_per_million" => 1_000_000,
    "output_microusd_per_million" => 2_000_000
  }

  setup do
    previous =
      Map.new(
        [:workspace_id, :workspace_root, :model_test_plug],
        &{&1, Application.get_env(:harness_forge, &1)}
      )

    fixture = Fixture.install!()
    root = Path.join(fixture.root, "workspace")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    Application.put_env(:harness_forge, :workspace_id, Ecto.UUID.generate())
    Application.put_env(:harness_forge, :workspace_root, root)

    Application.put_env(:harness_forge, :model_test_plug, fn _ ->
      flunk("recovery dispatched a model")
    end)

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        if is_nil(value),
          do: Application.delete_env(:harness_forge, key),
          else: Application.put_env(:harness_forge, key, value)
      end)

      Fixture.restore(fixture)
    end)

    %{fixture: fixture}
  end

  for runtime <- ~w(opencode codex) do
    @runtime runtime

    test "#{runtime} restart settles only the interrupted dispatch and retains every reservation",
         c do
      record = owned_run(c.fixture, @runtime)
      for index <- 1..3, do: request(record.id, index, :completed)
      dispatched = request(record.id, 4, :dispatched)
      {:ok, before_requests} = Ledger.list_requests(record.id)
      completed = Enum.filter(before_requests, &(&1["state"] == "completed"))
      {:ok, budget} = Ledger.budget(record.id)
      configuration = Configuration.get()

      # Cleanup uses saved daemon authority even when the current selection is unusable.
      Fixture.select(c.fixture, "tcp://127.0.0.1:1")
      assert :ok = Evaluations.reconcile()
      assert {:ok, result} = Evaluations.get(record.id)
      assert result["outcome"] == "interrupted"
      assert result["reason"] == "application_restarted"
      assert result["cleanup_status"] == "complete"
      assert result["runtime_qualified"] == false
      assert result["runtime_observed"] == false
      assert result["usage_status"] == "unknown"
      assert result["model_requests"] == 4
      assert result["input_tokens"] == nil
      assert result["output_tokens"] == nil
      assert {:ok, ^budget} = Ledger.budget(record.id)
      assert Configuration.get() == configuration
      assert Repo.get!(Run, record.id).execution_context == record.execution_context

      assert {:ok, recovered} = Ledger.list_requests(record.id)
      assert Enum.filter(recovered, &(&1["state"] == "completed")) == completed
      uncertain = Enum.find(recovered, &(&1["id"] == dispatched["id"]))
      assert uncertain["state"] == "uncertain"
      assert uncertain["usage_status"] == "unknown"
      assert uncertain["billing_status"] == "unknown"

      assert Map.take(uncertain, ~w(reserved_tokens reserved_estimated_microusd)) ==
               Map.take(dispatched, ~w(reserved_tokens reserved_estimated_microusd))

      commands = Fixture.commands(c.fixture)
      assert commands != []
      refute Jason.encode!(commands) =~ "tcp://127.0.0.1:1"
      refute Enum.any?(commands, &(Enum.at(&1["argv"], 2) in ~w(create run start exec)))
      Fixture.clear_commands(c.fixture)
      assert :ok = Evaluations.reconcile()
      assert {:ok, ^result} = Evaluations.get(record.id)
      assert {:ok, ^recovered} = Ledger.list_requests(record.id)
      assert {:ok, ^budget} = Ledger.budget(record.id)
      assert Fixture.commands(c.fixture) == []
    end
  end

  test "completed, already uncertain and zero-request runs get their actual settled summary", c do
    for {state, expected, input, output} <- [
          {:completed, "reported", 11, 7},
          {:uncertain, "unknown", nil, nil},
          {:none, "not_dispatched", nil, nil}
        ] do
      record = owned_run(c.fixture, "opencode")
      if state != :none, do: request(record.id, 1, state)
      {:ok, before_requests} = Ledger.list_requests(record.id)
      before_budget = Ledger.budget(record.id)
      assert :ok = Evaluations.reconcile()
      assert {:ok, result} = Evaluations.get(record.id)
      assert result["usage_status"] == expected
      assert result["model_requests"] == if(state == :none, do: 0, else: 1)
      assert result["input_tokens"] == input
      assert result["output_tokens"] == output
      assert {:ok, ^before_requests} = Ledger.list_requests(record.id)
      assert Ledger.budget(record.id) == before_budget
    end
  end

  test "an interrupted cleanup failure retries accounting only after successful cleanup", c do
    record = owned_run(c.fixture, "codex")
    request(record.id, 1, :dispatched)
    {:ok, before_requests} = Ledger.list_requests(record.id)
    {:ok, budget} = Ledger.budget(record.id)
    assert :ok = Fixture.put_daemon(c.fixture, c.fixture.endpoint, %{"status" => 1})

    assert {:error, :cleanup_failed} = Evaluations.reconcile()
    assert {:ok, failed} = Evaluations.get(record.id)
    assert failed["outcome"] == "interrupted"
    assert failed["cleanup_status"] == "cleanup_failed"
    assert {:ok, ^before_requests} = Ledger.list_requests(record.id)
    assert {:ok, ^budget} = Ledger.budget(record.id)

    assert :ok = Fixture.put_daemon(c.fixture, c.fixture.endpoint, %{"status" => 0})
    assert :ok = Evaluations.reconcile()
    assert {:ok, recovered} = Evaluations.get(record.id)
    assert recovered["cleanup_status"] == "complete"
    assert recovered["usage_status"] == "unknown"
    assert recovered["model_requests"] == 1
    assert {:ok, [%{"state" => "uncertain"}]} = Ledger.list_requests(record.id)
    assert {:ok, ^budget} = Ledger.budget(record.id)
  end

  test "corrupt context and replaced daemon never settle a dispatch", c do
    for failure <- [:context, :daemon] do
      record = owned_run(c.fixture, "opencode")
      request(record.id, 1, :dispatched)
      {:ok, before_requests} = Ledger.list_requests(record.id)
      {:ok, budget} = Ledger.budget(record.id)

      case failure do
        :context ->
          Repo.update!(
            change(record, execution_context: Map.put(record.execution_context, "extra", true))
          )

        :daemon ->
          Fixture.put_daemon(c.fixture, c.fixture.endpoint, %{
            "info" => Map.put(Fixture.info(), "ID", "HF07:REPLACED")
          })
      end

      Fixture.clear_commands(c.fixture)
      assert {:error, :cleanup_failed} = Evaluations.reconcile()
      assert {:ok, ^before_requests} = Ledger.list_requests(record.id)
      assert {:ok, ^budget} = Ledger.budget(record.id)
      if failure == :context, do: assert(Fixture.commands(c.fixture) == [])

      # Keep each failed row out of the next matrix iteration.
      Repo.delete!(Repo.get!(Run, record.id))
    end
  end

  test "foreign containers prevent accounting settlement", c do
    record = owned_run(c.fixture, "opencode")
    request(record.id, 1, :dispatched)
    {:ok, before_requests} = Ledger.list_requests(record.id)
    {:ok, budget} = Ledger.budget(record.id)
    name = "hf-code-" <> record.id <> "-clamp-agent"

    Fixture.put_daemon(c.fixture, c.fixture.endpoint, %{
      "containers" => %{name => %{"Config" => %{"Labels" => %{}}}}
    })

    assert {:error, :cleanup_failed} = Evaluations.reconcile()
    assert {:ok, ^before_requests} = Ledger.list_requests(record.id)
    assert {:ok, ^budget} = Ledger.budget(record.id)
    refute Enum.any?(Fixture.commands(c.fixture), &(Enum.at(&1["argv"], 2) == "rm"))
  end

  for table <- ~w(evaluation_runs model_requests) do
    @table table

    test "a #{@table} persistence failure rolls ledger and evaluation back together", c do
      record = owned_run(c.fixture, "opencode")
      request(record.id, 1, :dispatched)
      {:ok, before_requests} = Ledger.list_requests(record.id)
      {:ok, budget} = Ledger.budget(record.id)
      trigger = "recovery_refuse_" <> @table

      Repo.query!("""
      CREATE TEMP TRIGGER #{trigger} BEFORE UPDATE ON #{@table}
      BEGIN SELECT RAISE(ABORT, 'synthetic recovery refusal'); END
      """)

      try do
        assert {:error, :evaluation_persistence_failed} = Evaluations.reconcile()
        assert {:ok, ^before_requests} = Ledger.list_requests(record.id)
        assert {:ok, ^budget} = Ledger.budget(record.id)
        assert Repo.get!(Run, record.id).result == record.result
      after
        Repo.query!("DROP TRIGGER IF EXISTS #{trigger}")
      end

      assert :ok = Evaluations.reconcile()
      assert {:ok, [%{"state" => "uncertain"}]} = Ledger.list_requests(record.id)
    end
  end

  test "unrelated requests, static runs, completed history and foreign workspaces stay untouched",
       c do
    authoring = Ecto.UUID.generate()
    request(authoring, 1, :dispatched)
    historical = owned_run(c.fixture, "opencode")
    request(historical.id, 1, :dispatched)

    historical =
      Repo.update!(
        change(historical,
          result:
            Map.merge(historical.result, %{
              "outcome" => "interrupted",
              "cleanup_status" => "complete"
            })
        )
      )

    completed = owned_run(c.fixture, "opencode")
    request(completed.id, 1, :dispatched)

    completed =
      Repo.update!(
        change(completed,
          result:
            Map.merge(completed.result, %{
              "outcome" => "passed",
              "cleanup_status" => "complete"
            })
        )
      )

    static = owned_run(c.fixture, "opencode")
    request(static.id, 1, :dispatched)

    static =
      Repo.update!(
        change(static,
          execution_context: nil,
          result:
            Map.merge(static.result, %{
              "kind" => "static_integrity",
              "outcome" => "passed",
              "cleanup_status" => "complete"
            })
        )
      )

    foreign = owned_run(c.fixture, "codex")
    request(foreign.id, 1, :dispatched)
    foreign = Repo.update!(change(foreign, workspace_id: Ecto.UUID.generate()))
    before_rows = accounting_rows()
    Fixture.clear_commands(c.fixture)

    assert :ok = Evaluations.reconcile()
    assert accounting_rows() == before_rows

    for record <- [historical, completed, static, foreign],
        do: assert(Repo.get!(Run, record.id) == record)

    assert Fixture.commands(c.fixture) == []
  end

  test "retired setup budgets are rejected without adopting their accounting", c do
    record = owned_run(c.fixture, "opencode")
    request(record.id, 1, :dispatched)

    {:ok, _} =
      Audit.append("setup_budget_retired", %{"run_id" => record.id, "status" => "retired"})

    before_rows = accounting_rows()

    assert {:error, :authorization_required} = Evaluations.reconcile()
    assert accounting_rows() == before_rows
    assert Repo.get!(Run, record.id).result == record.result
  end

  test "a stage-linked request is rejected even when its run ID passes the legacy budget guard",
       c do
    record = owned_run(c.fixture, "opencode")
    reservation = request(record.id, 1, :dispatched)
    stage_link(reservation)
    before_rows = accounting_rows()

    assert :ok = HarnessForge.Models.RunAuthorization.legacy_budget_allowed(record.id)
    assert {:error, :cleanup_failed} = Evaluations.reconcile()
    assert accounting_rows() == before_rows
    assert Repo.get!(Run, record.id).result == record.result
  end

  defp owned_run(fixture, runtime) do
    id = Ecto.UUID.generate()
    {:ok, observation} = Fixture.observation(fixture, Workspaces.current_id(), id)
    admission = if runtime == "codex", do: codex_admission(observation), else: observation
    {:ok, context} = Coding.context(admission, Workspaces.current_id(), id)
    digest = Contracts.sha256("synthetic recovery artifact")

    result =
      Map.merge(
        %{
          "id" => id,
          "workspace_id" => Workspaces.current_id(),
          "artifact_digest" => digest,
          "kind" => "task",
          "runtime_name" => runtime,
          "runtime_image" => Coding.runtime_image(admission),
          "runtime_version" => if(runtime == "codex", do: "0.156.0", else: Docker.version()),
          "execution_profile_id" =>
            if(runtime == "codex",
              do: "docker-codex-isolated-v1",
              else: "docker-coding-isolated-v2"
            ),
          "environment_profile_digest" => Coding.profile_digest(admission),
          "outcome" => "running",
          "cleanup_status" => "pending",
          "usage_status" => "not_dispatched",
          "model_requests" => 0,
          "input_tokens" => 999,
          "output_tokens" => 999,
          "runtime_qualified" => false,
          "runtime_observed" => true
        },
        Coding.identity(admission)
      )

    Repo.insert!(%Run{
      id: id,
      workspace_id: Workspaces.current_id(),
      artifact_digest: digest,
      result: result,
      execution_context: context
    })
  end

  defp codex_admission(observation) do
    %{
      observation: observation,
      driver: %{
        "image_id" => "sha256:" <> Contracts.sha256("synthetic image"),
        "descriptor_digest" => Contracts.sha256("synthetic driver"),
        "receipt_digest" => Contracts.sha256("synthetic receipt"),
        "cli_version" => "0.156.0",
        "platform" => "linux/arm64"
      },
      model_identity: %{
        "version" => "0.40.14",
        "model" => "synthetic:recovery",
        "digest" => Contracts.sha256("synthetic model"),
        "endpoint" => "http://127.0.0.1:12345",
        "capabilities" => ["completion", "tools"]
      },
      codex_tools: [],
      tools_profile_digest: Contracts.sha256("synthetic tools")
    }
  end

  defp request(run_id, index, state) do
    {:ok, _} = Ledger.start_run(run_id)

    {:ok, reservation} =
      Ledger.reserve(
        %{
          "run_id" => run_id,
          "request_id" => Ecto.UUID.generate(),
          "max_output_tokens" => 100,
          "prompt" => "synthetic recovery request #{index}"
        },
        @config,
        20
      )

    case state do
      :completed ->
        Ledger.reconcile(reservation, {:ok, %{input_tokens: 11, output_tokens: 7}}, @config)

      :uncertain ->
        Ledger.reconcile(reservation, {:error, :synthetic_unknown}, %{})

      :dispatched ->
        :ok
    end

    reservation
  end

  defp accounting_rows do
    Map.new(~w(model_budgets model_requests stage_attempts), fn table ->
      {table, Repo.query!("SELECT * FROM " <> table <> " ORDER BY id").rows}
    end)
  end

  # Minimal persisted stage ancestry exercises the production linkage fence.
  # No stage authority is granted and no attempt gateway is invoked.
  defp stage_link(reservation) do
    workspace = Workspaces.current_id()
    now = DateTime.to_iso8601(DateTime.utc_now())
    hash = Contracts.sha256("synthetic stage ancestry")

    corpus =
      Repo.insert!(%HarnessForge.Evidence.Corpus{
        workspace_id: workspace,
        name: "Recovery fixture"
      })

    [manifest, config, consent, operation] = Enum.map(1..4, fn _ -> Ecto.UUID.generate() end)

    Repo.query!(
      """
      INSERT INTO dependency_manifests
        (id,workspace_id,corpus_id,semantic_generation,authorization_generation,purpose,state,digest,source_count,context_json,inserted_at)
      VALUES (?,?,?,0,0,'retrieval','sealed',?,0,'{}',?)
      """,
      [manifest, workspace, corpus.id, hash, now]
    )

    Repo.query!(
      "INSERT INTO stage_configs (id,workspace_id,stage,payload_json,config_hash,inserted_at) VALUES (?,?,'synthesis','{}',?,?)",
      [config, workspace, hash, now]
    )

    Repo.query!(
      "INSERT INTO stage_consent_revisions (id,workspace_id,stage_config_id,revision,state,inserted_at) VALUES (?,?,?,1,'active',?)",
      [consent, workspace, config, now]
    )

    Repo.query!(
      """
      INSERT INTO stage_operations
        (workspace_id,id,corpus_id,scope_ref,manifest_id,manifest_digest,stage_set_digest,caller_digest,control_token,operation_type,semantic_generation,authorization_generation,cancel_epoch,state,deadline_at,inserted_at,updated_at)
      VALUES (?,?,?,'synthetic recovery',?,?,?,?,?,'synthesis',0,0,0,'active',?,?,?)
      """,
      [workspace, operation, corpus.id, manifest, hash, hash, hash, hash, now, now, now]
    )

    Repo.query!(
      """
      INSERT INTO stage_attempts
        (id,workspace_id,operation_id,logical_call_id,ordinal,stage_config_id,consent_id,model_request_id,worker_request_id,payload_hash,manifest_id,semantic_generation,authorization_generation,cancel_epoch,deadline_at,state,inserted_at,updated_at)
      VALUES (?,?,?,'synthetic recovery',1,?,?,?,?,?,?,0,0,0,?,'dispatched',?,?)
      """,
      [
        reservation["request_id"],
        workspace,
        operation,
        config,
        consent,
        reservation["id"],
        Ecto.UUID.generate(),
        hash,
        manifest,
        now,
        now,
        now
      ]
    )
  end
end
