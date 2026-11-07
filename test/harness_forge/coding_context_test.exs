defmodule HarnessForge.CodingContextTest.Health do
  import Plug.Conn
  def init(owner), do: owner

  def call(conn, {owner, pause?}) do
    if conn.method == "GET" and conn.request_path == "/api/tags" do
      if pause? do
        send(owner, {:context_health_barrier, self()})

        receive do
          :release_fixture -> :ok
        after
          10_000 -> :ok
        end
      end

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{
          "models" => [%{"name" => "synthetic:context"}, %{"name" => "synthetic:changed"}]
        })
      )
    else
      send(owner, :unexpected_model_request)
      send_resp(conn, 405, "")
    end
  end
end

defmodule HarnessForge.CodingContextTest do
  use HarnessForge.DataCase, async: false
  alias HarnessForge.{Decisions, Demo, Evaluations, Evidence, Harnesses, Models, Workspaces}
  alias HarnessForge.Evaluation.Run
  alias HarnessForge.Execution.{Coding, CodingTransport, Docker}
  alias HarnessForge.Models.Configuration
  alias HarnessForge.CodingDockerFixture, as: Fixture

  setup tags do
    previous = Application.fetch_env!(:harness_forge, :workspace_root)
    temporary = if :os.type() == {:unix, :darwin}, do: "/private/tmp", else: "/tmp"
    root = Path.join(temporary, "hf-context-#{Ecto.UUID.generate()}")
    Application.put_env(:harness_forge, :workspace_root, root)
    fixture = Fixture.install!()

    on_exit(fn ->
      Repo.delete_all(
        from r in Run,
          where:
            fragment("json_extract(?, '$.endpoint')", r.execution_context) == ^fixture.endpoint
      )

      Fixture.restore(fixture)
      Application.put_env(:harness_forge, :workspace_root, previous)
      File.rm_rf!(root)
    end)

    {:ok, _} = Demo.load()
    {:ok, claims} = Evidence.list_claims()
    claim = Enum.find(claims, &(not String.starts_with?(&1["text"], "IGNORE")))

    {:ok, _} =
      Decisions.decide(claim["id"], %{
        "actor" => Workspaces.operator(),
        "decision" => "approve",
        "expected_revision_hash" => claim["revision_hash"]
      })

    {:ok, artifact} = Harnesses.build(%{"runtime_version" => Docker.version()})

    upstream =
      start_supervised!(
        {Bandit,
         [
           plug: {__MODULE__.Health, {self(), tags[:pause_model_health] == true}},
           ip: {127, 0, 0, 1},
           port: 0,
           startup_log: false
         ]}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(upstream)

    {:ok, _} =
      Models.configure(%{
        "model" => "synthetic:context",
        "endpoint" => "http://127.0.0.1:#{port}"
      })

    {:ok, artifact: artifact, fixture: fixture}
  end

  test "only the actual owned result and matching stored private context confer applicability", %{
    artifact: artifact,
    fixture: fixture
  } do
    record = owned_run(artifact, fixture)
    assert :ok = Evaluations.applicability(artifact, record.result)
    Fixture.clear_commands(fixture)

    assert {:error, :evaluation_inapplicable} =
             Evaluations.applicability(
               artifact,
               Map.put(record.result, "runtime_qualified", false)
             )

    foreign_workspace = Ecto.UUID.generate()
    update_record(record, workspace_id: foreign_workspace)
    assert Repo.get!(Run, record.id).workspace_id == foreign_workspace
    assert {:error, :evaluation_inapplicable} = Evaluations.applicability(artifact, record.result)
    update_record(record, workspace_id: Workspaces.current_id())
    assert Repo.get!(Run, record.id).workspace_id == Workspaces.current_id()

    for context <- [
          nil,
          Map.put(record.execution_context, "extra", "untrusted"),
          Map.put(record.execution_context, "workspace_id", Ecto.UUID.generate()),
          Map.put(record.execution_context, "run_id", Ecto.UUID.generate()),
          Map.put(record.execution_context, "daemon_id", "different-daemon")
        ] do
      update_record(record, execution_context: context)
      assert Repo.get!(Run, record.id).execution_context == context

      assert {:error, :evaluation_inapplicable} =
               Evaluations.applicability(artifact, record.result)
    end

    update_record(record,
      execution_context: record.execution_context,
      result: Map.put(record.result, "execution_profile_id", "docker-coding-unix-isolated-v1")
    )

    {:ok, legacy} = Evaluations.get(record.id)
    assert Repo.get!(Run, record.id).execution_context == record.execution_context
    assert legacy["execution_profile_id"] == "docker-coding-unix-isolated-v1"
    assert {:error, :evaluation_inapplicable} = Evaluations.applicability(artifact, legacy)
    assert Fixture.commands(fixture) == []
    refute_received :unexpected_model_request
  end

  test "public DTOs contain no context or transport identifiers", %{
    artifact: artifact,
    fixture: fixture
  } do
    record = owned_run(artifact, fixture)
    assert {:ok, public} = Evaluations.get(record.id)
    assert {:ok, [^public]} = Evaluations.list_runs()
    encoded = Jason.encode!(public)
    refute encoded =~ record.execution_context["endpoint"]
    refute encoded =~ record.execution_context["daemon_id"]
    refute Map.has_key?(public, "execution_context")
  end

  test "fresh endpoint, daemon and model changes invalidate saved authority", %{
    artifact: artifact,
    fixture: fixture
  } do
    record = owned_run(artifact, fixture)
    Fixture.select(fixture, fixture.decoy_endpoint)
    assert {:error, :evaluation_inapplicable} = Evaluations.applicability(artifact, record.result)
    Fixture.select(fixture, fixture.endpoint)

    Fixture.put_daemon(fixture, fixture.endpoint, %{
      "info" => Map.put(Fixture.info(), "ID", "HF07:CHANGED")
    })

    assert {:error, :evaluation_inapplicable} = Evaluations.applicability(artifact, record.result)
    Fixture.put_daemon(fixture, fixture.endpoint, %{"info" => Fixture.info()})
    {:ok, _} = Models.configure(Map.put(Configuration.get(), "model", "synthetic:changed"))
    assert :ok = HarnessForge.Models.Ollama.available(Configuration.get())
    assert {:error, :evaluation_inapplicable} = Evaluations.applicability(artifact, record.result)
    refute_received :unexpected_model_request
  end

  test "original-daemon failure retains completed context and terminal outcome for retry", %{
    artifact: artifact,
    fixture: fixture
  } do
    record = owned_run(artifact, fixture)

    Fixture.put_daemon(fixture, fixture.endpoint, %{
      "info" => Map.put(Fixture.info(), "ID", "HF07:CHANGED")
    })

    assert {:error, :cleanup_failed} = Evaluations.cleanup_runs({:ids, [record.id]})
    assert {:ok, failed} = Evaluations.get(record.id)
    assert failed["outcome"] == "passed"
    assert failed["reason"] == "coding_transport_changed"
    refute failed["runtime_qualified"]
    assert Repo.get!(Run, record.id).execution_context == record.execution_context

    Fixture.put_daemon(fixture, fixture.endpoint, %{"info" => Fixture.info()})
    assert :ok = Evaluations.cleanup_runs({:ids, [record.id]})
    assert {:ok, retried} = Evaluations.get(record.id)
    assert retried["outcome"] == "passed"
    assert retried["completed_at"] == record.result["completed_at"]
    assert retried["cleanup_status"] == "complete"
    refute retried["runtime_qualified"]
    assert Repo.get!(Run, record.id).execution_context == record.execution_context
  end

  test "a healthy model followed by failed transport persists the precise predispatch refusal", %{
    artifact: artifact,
    fixture: fixture
  } do
    Fixture.put_daemon(fixture, fixture.endpoint, %{"status" => 1})
    assert {:ok, result} = Evaluations.run(artifact["digest"])
    assert result["outcome"] == "blocked"
    assert result["reason"] == "coding_transport_unavailable"
    assert result["execution_profile_id"] == "docker-coding-isolated-v2"
    assert result["environment_profile_digest"] == nil
    assert result["cleanup_status"] == "not_started"
    assert result["usage_status"] == "not_dispatched"
    assert result["checks"] == []
    refute result["runtime_qualified"]
    assert Repo.get!(Run, result["id"]).execution_context == nil
    assert Repo.aggregate(HarnessForge.Models.Request, :count) == 0
    assert Repo.aggregate(HarnessForge.Models.Budget, :count) == 0
    refute File.exists?(Path.join(Workspaces.paths()["runs"], "coding-" <> result["id"]))
    refute_received :unexpected_model_request
  end

  test "failed atomic persistence returns a fixed error before runtime effects without private logs",
       %{artifact: artifact, fixture: fixture} do
    assert Repo.config()[:log] == false
    before_runs = Repo.aggregate(Run, :count)
    before_files = File.ls(Workspaces.paths()["runs"])

    Repo.query!(
      "CREATE TEMP TRIGGER hf07_refuse_run BEFORE INSERT ON evaluation_runs BEGIN SELECT RAISE(ABORT, 'synthetic persistence refusal'); END"
    )

    Fixture.clear_commands(fixture)

    try do
      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          assert {:error, :evaluation_persistence_failed} = Evaluations.run(artifact["digest"])
        end)

      refute String.contains?(log, fixture.endpoint)
      refute String.contains?(log, "HF07:ORIGINAL")
      refute String.contains?(log, "execution_context")
      assert Repo.aggregate(Run, :count) == before_runs
      assert Repo.aggregate(HarnessForge.Models.Request, :count) == 0
      assert Repo.aggregate(HarnessForge.Models.Budget, :count) == 0
      assert File.ls(Workspaces.paths()["runs"]) == before_files
      commands = Fixture.commands(fixture)
      assert Enum.count(commands, &Enum.member?(&1["argv"], "image")) == 3

      refute Enum.any?(commands, fn c ->
               Enum.any?(c["argv"], &(&1 in ~w(create run start rm)))
             end)

      refute_received :unexpected_model_request
    after
      Repo.query!("DROP TRIGGER hf07_refuse_run")
    end
  end

  @tag pause_model_health: true
  test "model selection changing during admission persists a refusal without context or resources",
       %{artifact: artifact} do
    task = Task.async(fn -> Evaluations.run(artifact["digest"]) end)
    assert_receive {:context_health_barrier, provider}, 10_000
    assert {:ok, []} = Evaluations.list_runs()
    {:ok, _} = Models.configure(Map.put(Configuration.get(), "model", "synthetic:replacement"))
    send(provider, :release_fixture)
    assert {:ok, result} = Task.await(task, 15_000)
    assert result["outcome"] == "blocked"
    assert result["reason"] == "model_configuration_changed"
    assert result["environment_profile_digest"] == nil
    assert result["cleanup_status"] == "not_started"
    assert result["usage_status"] == "not_dispatched"
    assert Repo.get!(Run, result["id"]).execution_context == nil
    assert Repo.aggregate(HarnessForge.Models.Budget, :count) == 0
    refute_received :unexpected_model_request
  end

  test "scoped cleanup rechecks retained clean contexts without changing terminal observations",
       %{artifact: artifact, fixture: fixture} do
    target = owned_run(artifact, fixture)
    decoy = owned_run(artifact, fixture)
    foreign = owned_run(artifact, fixture)
    foreign_workspace = Ecto.UUID.generate()
    update_record(foreign, workspace_id: foreign_workspace)
    assert Repo.get!(Run, foreign.id).workspace_id == foreign_workspace
    Fixture.clear_commands(fixture)

    assert :ok = Evaluations.cleanup_runs({:ids, [target.id, foreign.id]})
    assert {:ok, result} = Evaluations.get(target.id)
    assert result == target.result
    assert Repo.get!(Run, target.id).execution_context == target.execution_context
    assert Repo.get!(Run, decoy.id).result == decoy.result
    log = Jason.encode!(Fixture.commands(fixture))
    assert log =~ target.id
    refute log =~ decoy.id
    refute log =~ foreign.id
  end

  test "restart discovers persisted coding context despite an unusable current selection", %{
    artifact: artifact,
    fixture: fixture
  } do
    record =
      owned_run(artifact, fixture, %{
        "outcome" => "cancelled",
        "cleanup_status" => "pending",
        "runtime_qualified" => false
      })

    Fixture.select(fixture, "tcp://127.0.0.1:1")
    Fixture.clear_commands(fixture)
    assert :ok = Evaluations.reconcile()
    assert {:ok, result} = Evaluations.get(record.id)
    assert result["outcome"] == "cancelled"
    assert result["cleanup_status"] == "complete"
    refute result["runtime_qualified"]
    assert Repo.get!(Run, record.id).execution_context == record.execution_context
    assert Fixture.commands(fixture) != []
    refute Jason.encode!(Fixture.commands(fixture)) =~ "tcp://127.0.0.1:1"
  end

  test "missing v2 cleanup authority fails closed and preserves cancellation", %{
    artifact: artifact,
    fixture: fixture
  } do
    record =
      owned_run(artifact, fixture, %{
        "outcome" => "cancelled",
        "cleanup_status" => "pending",
        "runtime_qualified" => false
      })

    update_record(record, execution_context: nil)
    assert Repo.get!(Run, record.id).execution_context == nil
    Fixture.clear_commands(fixture)
    assert {:error, :cleanup_failed} = Evaluations.reconcile()
    assert {:ok, failed} = Evaluations.get(record.id)
    assert failed["outcome"] == "cancelled"
    assert failed["reason"] == "coding_cleanup_context_invalid"
    assert failed["cleanup_status"] == "cleanup_failed"
    assert Fixture.commands(fixture) == []

    update_record(Repo.get!(Run, record.id), execution_context: record.execution_context)
    assert Repo.get!(Run, record.id).execution_context == record.execution_context
    assert :ok = Evaluations.reconcile()
    assert {:ok, retried} = Evaluations.get(record.id)
    assert retried["outcome"] == "cancelled"
    assert retried["cleanup_status"] == "complete"
    refute retried["runtime_qualified"]
  end

  test "static, managed, terminal legacy and restored rows never contact a daemon", %{
    artifact: artifact,
    fixture: fixture
  } do
    {:ok, static} = Evaluations.run(artifact["digest"], kind: :static_integrity)
    base = Repo.get!(Run, static["id"])

    for overrides <- [
          %{"kind" => "static_integrity", "outcome" => "running"},
          %{"kind" => "task", "runtime_name" => "codex", "outcome" => "running"},
          %{"kind" => "task", "outcome" => "passed", "cleanup_status" => "complete"},
          %{
            "kind" => "task",
            "execution_profile_id" => "docker-coding-isolated-v2",
            "outcome" => "interrupted",
            "reason" => "restored_requires_reevaluation",
            "cleanup_status" => "not_dispatched",
            "usage_status" => "reported"
          }
        ] do
      update_record(base, result: Map.merge(static, overrides))
      Fixture.clear_commands(fixture)
      assert :ok = Evaluations.cleanup_runs({:ids, [base.id]})
      assert Fixture.commands(fixture) == []
    end
  end

  test "unfinished legacy origin remains unresolved without guessed cleanup", %{
    artifact: artifact,
    fixture: fixture
  } do
    {:ok, static} = Evaluations.run(artifact["digest"], kind: :static_integrity)
    record = Repo.get!(Run, static["id"])

    update_record(record,
      result:
        Map.merge(static, %{
          "kind" => "task",
          "outcome" => "running",
          "cleanup_status" => "pending"
        })
    )

    Fixture.clear_commands(fixture)
    assert {:error, :cleanup_failed} = Evaluations.reconcile()
    assert {:ok, failed} = Evaluations.get(record.id)
    assert failed["reason"] == "coding_cleanup_origin_unknown"
    assert failed["outcome"] == "interrupted"
    assert Fixture.commands(fixture) == []
  end

  defp owned_run(artifact, fixture, overrides \\ %{}) do
    id = Ecto.UUID.generate()
    {:ok, observation} = Fixture.observation(fixture, Workspaces.current_id(), id)
    {:ok, context} = CodingTransport.context(observation, Workspaces.current_id(), id)
    now = DateTime.to_iso8601(DateTime.utc_now())

    result =
      Evaluations.applicability(artifact)
      |> Map.merge(%{
        "id" => id,
        "workspace_id" => Workspaces.current_id(),
        "kind" => "task",
        "runtime_name" => "opencode",
        "outcome" => "passed",
        "runtime_qualified" => true,
        "reason" => "fixture_only_authority_boundary",
        "checks" => [],
        "duration_ms" => 0,
        "cleanup_status" => "complete",
        "usage_status" => "reported",
        "inserted_at" => now,
        "completed_at" => now,
        "environment_profile_digest" => Coding.profile_digest(observation)
      })
      |> Map.merge(overrides)

    Repo.insert!(%Run{
      id: id,
      workspace_id: Workspaces.current_id(),
      artifact_digest: artifact["digest"],
      result: result,
      execution_context: context
    })
  end

  defp update_record(record, changes),
    do: Repo.update!(Ecto.Changeset.change(Repo.get!(Run, record.id), changes))
end
