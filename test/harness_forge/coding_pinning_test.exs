defmodule HarnessForge.CodingPinningTest.Health do
  import Plug.Conn
  def init(owner), do: owner

  def call(conn, owner) do
    if conn.request_path == "/api/tags" do
      send(owner, {:transport_health_barrier, self()})

      receive do
        :release_transport_health -> :ok
      after
        5_000 -> :ok
      end

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{"models" => [%{"name" => "synthetic:original"}]}))
    else
      send(owner, :unexpected_transport_inference)
      send_resp(conn, 404, "")
    end
  end
end

defmodule HarnessForge.CodingPinningTest do
  use HarnessForge.DataCase, async: false
  alias HarnessForge.{Repo, Workspaces}
  alias HarnessForge.CodingDockerFixture, as: Fixture
  alias HarnessForge.Evaluation.Run
  alias HarnessForge.Execution.{Coding, CodingSession, CodingTransport, Relay}

  defmodule CancellationHealth do
    import Plug.Conn
    def init(counter), do: counter

    def call(%{method: "GET", request_path: "/api/tags"} = conn, counter) do
      :atomics.add(counter, 1, 1)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{"models" => [%{"name" => "synthetic:cancellation"}]}))
    end

    def call(conn, counter) do
      :atomics.add(counter, 2, 1)
      send_resp(conn, 405, "")
    end
  end

  setup do
    fixture = Fixture.install!()
    # DataCase rolls back all fixture rows. This cleanup only restores the
    # synthetic executable and sockets; it never invokes a workspace purge.
    on_exit(fn -> Fixture.restore(fixture) end)
    %{fixture: fixture}
  end

  @tag :cancellation_origin_guard
  test "cancellation revokes the owned local relay even when original daemon verification fails",
       %{fixture: f} do
    counter = cancellation_model()

    for failure <- [
          %{"status" => 1},
          %{"info" => Map.put(Fixture.info(), "ID", "HF07:REPLACED")}
        ] do
      Fixture.put_daemon(f, f.endpoint, %{"status" => 0, "info" => Fixture.info()})
      {record, _} = owned_run(f, %{"outcome" => "running"})
      assert {:ok, relay} = Relay.start_run(record.id, max_turns: 2, lifetime_ms: 60_000)
      assert {:ok, session} = CodingSession.start(record.id, relay)

      on_exit(fn ->
        CodingSession.stop(record.id)
        Relay.stop(relay)
      end)

      assert :ok = Relay.authorize(relay.pid, relay.token)
      assert Process.alive?(session)
      assert :atomics.get(counter, 1) > 0
      Fixture.put_daemon(f, f.endpoint, failure)
      Fixture.select(f, f.decoy_endpoint)
      Fixture.clear_commands(f)
      before_state = File.read!(f.state)

      assert {:ok, cancelled} = HarnessForge.Evaluations.cancel(record.id)
      assert cancelled["outcome"] == "cancelled"
      assert cancelled["cleanup_status"] == "cleanup_failed"
      refute cancelled["runtime_qualified"]
      assert Repo.get!(Run, record.id).execution_context == record.execution_context
      assert File.read!(f.state) == before_state
      assert Fixture.commands(f) != []

      assert Enum.all?(
               Fixture.commands(f),
               &(&1["argv"] == ["--host", f.endpoint, "info", "--format", "{{json .ID}}"])
             )

      refute Process.alive?(session)
      refute Process.alive?(relay.pid)

      assert :undefined ==
               :global.whereis_name({CodingSession, Workspaces.current_id(), record.id})

      assert {:error, _} =
               Req.post("http://127.0.0.1:#{relay.port}/v1/chat/completions",
                 headers: [{"authorization", "Bearer " <> relay.token}],
                 json: %{
                   "model" => "harnessforge/synthetic:cancellation",
                   "messages" => [
                     %{"role" => "user", "content" => "Synthetic post-cancellation probe"}
                   ]
                 },
                 retry: false,
                 receive_timeout: 1_000,
                 connect_options: [timeout: 1_000]
               )

      assert :atomics.get(counter, 2) == 0
      assert {:ok, []} = HarnessForge.Models.list_requests(record.id)

      Fixture.put_daemon(f, f.endpoint, %{"status" => 0, "info" => Fixture.info()})
      assert :ok = HarnessForge.Evaluations.cleanup_runs({:ids, [record.id]})
      assert {:ok, retried} = HarnessForge.Evaluations.get(record.id)
      assert retried["outcome"] == "cancelled"
      assert retried["cleanup_status"] == "complete"
      refute retried["runtime_qualified"]
      assert Repo.get!(Run, record.id).execution_context == record.execution_context
    end
  end

  @tag :cancellation_origin_guard
  test "owned local capability is revoked before corrupt or missing context is rejected",
       %{fixture: f} do
    counter = cancellation_model()

    for operation <- [:cancel, :direct_cleanup],
        context <- [nil, %{}, %{"endpoint" => "tcp://invalid"}] do
      {record, _} = owned_run(f, %{"outcome" => "running"})
      assert {:ok, relay} = Relay.start_run(record.id, max_turns: 2, lifetime_ms: 60_000)
      assert {:ok, session} = CodingSession.start(record.id, relay)

      on_exit(fn ->
        CodingSession.stop(record.id)
        Relay.stop(relay)
      end)

      Repo.get!(Run, record.id)
      |> Ecto.Changeset.change(execution_context: context)
      |> Repo.update!()

      assert Repo.get!(Run, record.id).execution_context == context
      Fixture.clear_commands(f)

      if operation == :cancel do
        assert {:ok, cancelled} = HarnessForge.Evaluations.cancel(record.id)
        assert cancelled["outcome"] == "cancelled"
        assert cancelled["cleanup_status"] == "cleanup_failed"
        assert cancelled["reason"] == "coding_cleanup_context_invalid"
        refute cancelled["runtime_qualified"]
      else
        assert {:error, :coding_cleanup_context_invalid} = Coding.cleanup(record.id)
      end

      refute Process.alive?(session)
      refute Process.alive?(relay.pid)
      assert Repo.get!(Run, record.id).execution_context == context
      assert Fixture.commands(f) == []
      assert :atomics.get(counter, 2) == 0
    end
  end

  @tag :cancellation_origin_guard
  test "missing or foreign persisted ownership cannot revoke a local session", %{fixture: f} do
    counter = cancellation_model()

    for ownership <- [:missing, :foreign] do
      {record, _} = owned_run(f, %{"outcome" => "running"})
      assert {:ok, relay} = Relay.start_run(record.id, max_turns: 2, lifetime_ms: 60_000)
      assert {:ok, session} = CodingSession.start(record.id, relay)

      on_exit(fn ->
        CodingSession.stop(record.id)
        Relay.stop(relay)
      end)

      if ownership == :missing,
        do: Repo.delete!(record),
        else:
          record |> Ecto.Changeset.change(workspace_id: Ecto.UUID.generate()) |> Repo.update!()

      Fixture.clear_commands(f)
      assert {:error, :coding_cleanup_context_invalid} = Coding.stop_session(record.id)
      assert {:error, :coding_cleanup_context_invalid} = Coding.cleanup(record.id)
      assert {:error, :evaluation_not_found} = HarnessForge.Evaluations.cancel(record.id)
      assert Process.alive?(session)
      assert Process.alive?(relay.pid)
      assert :ok = Relay.authorize(relay.pid, relay.token)
      assert Fixture.commands(f) == []
      assert :atomics.get(counter, 2) == 0
    end
  end

  test "model selection changing during actual health refuses admission after pinned image checks",
       %{fixture: f} do
    server =
      start_supervised!(
        {Bandit,
         plug: {__MODULE__.Health, self()}, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    endpoint = "http://127.0.0.1:#{port}"

    assert {:ok, _} =
             HarnessForge.Models.configure(%{
               "model" => "synthetic:original",
               "endpoint" => endpoint
             })

    admission = Task.async(fn -> Coding.admit(nil) end)
    assert_receive {:transport_health_barrier, provider}, 2_000

    assert {:ok, _} =
             HarnessForge.Models.configure(%{
               "model" => "synthetic:changed",
               "endpoint" => endpoint
             })

    send(provider, :release_transport_health)
    assert {:error, :model_configuration_changed} = Task.await(admission, 10_000)
    commands = Fixture.commands(f)

    assert Enum.count(commands, fn c ->
             case c["argv"] do
               ["--host", _, "info", "--format", format] ->
                 String.contains?(format, "OperatingSystem")

               _ ->
                 false
             end
           end) == 1

    assert Enum.count(commands, &Enum.member?(&1["argv"], "image")) == 3
    refute Enum.any?(commands, &Enum.member?(&1["argv"], "create"))
    refute_received :unexpected_transport_inference
  end

  test "current endpoint drift never sends cleanup commands to a matching-label decoy", %{
    fixture: f
  } do
    {record, observation} = owned_run(f)
    name = "hf-code-#{record.id}-proxy"
    owned = %{"Config" => %{"Labels" => labels(record.id)}}
    Fixture.put_daemon(f, f.endpoint, %{"containers" => %{name => owned}})
    Fixture.put_daemon(f, f.decoy_endpoint, %{"containers" => %{name => owned}})
    Fixture.select(f, f.decoy_endpoint)
    assert :ok = Coding.cleanup(record.id)
    commands = Fixture.commands(f)
    assert commands != []

    assert Enum.all?(commands, fn %{"argv" => ["--host", endpoint | _]} ->
             endpoint == f.endpoint
           end)

    assert Enum.any?(commands, &(&1["argv"] == ["--host", f.endpoint, "rm", "--force", name]))
    assert Repo.get!(Run, record.id).execution_context == record.execution_context
    Fixture.put_daemon(f, f.endpoint, %{"info" => Map.put(Fixture.info(), "ID", "HF07:REPLACED")})
    assert {:error, :coding_transport_changed} = CodingTransport.verify(observation)
  end

  test "same-path daemon replacement refuses mutation, retains context and permits original retry",
       %{fixture: f} do
    {record, _} = owned_run(f)
    Fixture.put_daemon(f, f.endpoint, %{"info" => Map.put(Fixture.info(), "ID", "HF07:REPLACED")})
    assert {:error, :coding_transport_changed} = Coding.cleanup(record.id)

    assert Enum.all?(
             Fixture.commands(f),
             &(&1["argv"] == ["--host", f.endpoint, "info", "--format", "{{json .ID}}"])
           )

    assert Repo.get!(Run, record.id).execution_context == record.execution_context
    Fixture.put_daemon(f, f.endpoint, %{"info" => Fixture.info()})
    assert :ok = Coding.cleanup(record.id)
    assert Repo.get!(Run, record.id).result["outcome"] == "cancelled"
  end

  test "unavailable original daemon cannot prove absence even after prior clean completion", %{
    fixture: f
  } do
    {record, _} = owned_run(f, %{"outcome" => "passed", "cleanup_status" => "complete"})
    assert :ok = Coding.cleanup(record.id)
    Fixture.put_daemon(f, f.endpoint, %{"status" => 1})
    assert {:error, :coding_transport_changed} = Coding.cleanup(record.id)
    assert Repo.get!(Run, record.id).execution_context == record.execution_context
  end

  test "foreign container and network labels block deletion", %{fixture: f} do
    {record, _} = owned_run(f)
    name = "hf-code-#{record.id}-proxy"
    foreign = Map.put(labels(record.id), "dev.harnessforge.workspace", Ecto.UUID.generate())

    Fixture.put_daemon(f, f.endpoint, %{
      "containers" => %{name => %{"Config" => %{"Labels" => foreign}}}
    })

    assert {:error, :coding_container_not_owned} = Coding.cleanup(record.id)
    refute Enum.any?(Fixture.commands(f), &Enum.member?(&1["argv"], "rm"))
    Fixture.clear_commands(f)
    network = "hf-code-#{record.id}"

    Fixture.put_daemon(f, f.endpoint, %{
      "containers" => %{},
      "networks" => %{network => %{"Labels" => foreign}}
    })

    assert {:error, :isolated_network_unverified} = Coding.cleanup(record.id)
    refute Enum.any?(Fixture.commands(f), &Enum.member?(&1["argv"], "rm"))
  end

  test "missing, corrupt, foreign and digest-inconsistent context refuse without commands", %{
    fixture: f
  } do
    {record, _} = owned_run(f)

    for context <- [
          nil,
          %{},
          Map.put(record.execution_context, "run_id", Ecto.UUID.generate()),
          Map.put(record.execution_context, "workspace_id", Ecto.UUID.generate()),
          Map.put(record.execution_context, "endpoint", "tcp://127.0.0.1:2375")
        ] do
      record.id
      |> then(&Repo.get!(Run, &1))
      |> Ecto.Changeset.change(execution_context: context)
      |> Repo.update!()

      assert Repo.get!(Run, record.id).execution_context == context
      assert {:error, :coding_cleanup_context_invalid} = Coding.cleanup(record.id)
      assert Fixture.commands(f) == []
    end

    Repo.get!(Run, record.id)
    |> Ecto.Changeset.change(
      execution_context: record.execution_context,
      result: Map.put(record.result, "environment_profile_digest", "forged")
    )
    |> Repo.update!()

    assert Repo.get!(Run, record.id).execution_context == record.execution_context
    assert Repo.get!(Run, record.id).result["environment_profile_digest"] == "forged"

    assert {:error, :coding_cleanup_context_invalid} = Coding.cleanup(record.id)
    assert Fixture.commands(f) == []
  end

  test "no persisted pending authority means no relay, ledger, files or Docker contact", %{
    fixture: f
  } do
    id = Ecto.UUID.generate()
    {:ok, o} = Fixture.observation(f, Workspaces.current_id(), id)

    artifact = %{
      "digest" => "synthetic-missing",
      "spec" => %{"spec" => %{"execution" => %{"timeout_seconds" => 1}}}
    }

    result = Coding.run(id, artifact, o)
    assert result["reason"] == "coding_cleanup_context_invalid"
    refute result["runtime_qualified"]
    assert result["cleanup_status"] == "not_started"
    assert Fixture.commands(f) == []
    refute File.exists?(Path.join(Workspaces.paths()["runs"], "coding-" <> id))
    assert {:ok, []} = HarnessForge.Models.list_requests(id)

    assert :undefined ==
             :global.whereis_name(
               {HarnessForge.Execution.CodingSession, Workspaces.current_id(), id}
             )
  end

  test "explicit no-resource and restored quarantine branches do not contact Docker", %{
    fixture: f
  } do
    {record, _} = owned_run(f)

    for result <- [
          Map.merge(record.result, %{
            "outcome" => "blocked",
            "usage_status" => "not_dispatched",
            "cleanup_status" => "not_started"
          }),
          Map.merge(record.result, %{
            "outcome" => "cancelled",
            "usage_status" => "reported",
            "cleanup_status" => "not_dispatched",
            "reason" => "restored_requires_reevaluation"
          })
        ] do
      record |> Ecto.Changeset.change(execution_context: nil, result: result) |> Repo.update!()
      assert :ok = Coding.cleanup(record.id)
      assert Fixture.commands(f) == []
    end
  end

  defp cancellation_model do
    counter = :atomics.new(2, [])

    server =
      start_supervised!(
        {Bandit,
         plug: {CancellationHealth, counter}, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    assert {:ok, _} =
             HarnessForge.Models.configure(%{
               "provider" => "ollama",
               "model" => "synthetic:cancellation",
               "endpoint" => "http://127.0.0.1:#{port}"
             })

    counter
  end

  defp owned_run(f, changes \\ %{}) do
    id = Ecto.UUID.generate()
    workspace = Workspaces.current_id()
    {:ok, observation} = Fixture.observation(f, workspace, id)
    {:ok, context} = CodingTransport.context(observation, workspace, id)

    result =
      Map.merge(
        %{
          "id" => id,
          "workspace_id" => workspace,
          "artifact_digest" => "synthetic-artifact",
          "kind" => "task",
          "runtime_name" => "opencode",
          "execution_profile_id" => "docker-coding-isolated-v2",
          "environment_profile_digest" => Coding.profile_digest(observation),
          "outcome" => "cancelled",
          "cleanup_status" => "pending",
          "usage_status" => "unknown",
          "runtime_qualified" => false
        },
        changes
      )

    record =
      Repo.insert!(%Run{
        id: id,
        workspace_id: workspace,
        artifact_digest: "synthetic-artifact",
        result: result,
        execution_context: context
      })

    {record, observation}
  end

  defp labels(id),
    do: %{
      "dev.harnessforge.workspace" => Workspaces.current_id(),
      "dev.harnessforge.run" => id,
      "dev.harnessforge.profile" => "docker-coding-isolated-v2"
    }
end
