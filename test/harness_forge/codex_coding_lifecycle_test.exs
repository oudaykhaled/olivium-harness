defmodule HarnessForge.CodexCodingLifecycleTest.Upstream do
  import Plug.Conn
  def init(options), do: options

  def call(conn, %{owner: owner, mode: mode}) do
    current = Agent.get(mode, & &1)
    send(owner, {:lifecycle_metadata_or_dispatch, conn.request_path})

    cond do
      current == :drip and conn.request_path in ["/api/version", "/api/tags"] ->
        conn = conn |> put_resp_content_type("application/json") |> send_chunked(200)
        drip(conn, System.monotonic_time(:millisecond) + 8_000)

      conn.request_path == "/api/tags" ->
        json(conn, %{"models" => [%{"name" => "synthetic:fixture"}]})

      conn.request_path == "/api/chat" ->
        {:ok, _body, conn} = read_body(conn)
        send(owner, {:lifecycle_inflight_dispatch, self()})

        receive do
          :release_lifecycle_response -> :ok
        after
          5_000 -> :ok
        end

        output = %{
          "done" => true,
          "done_reason" => "stop",
          "message" => %{
            "role" => "assistant",
            "content" => "Synthetic response after cancellation"
          }
        }

        output =
          if current == :unknown,
            do: output,
            else: Map.merge(output, %{"prompt_eval_count" => 11, "eval_count" => 7})

        json(conn, output)

      true ->
        send_resp(conn, 404, "")
    end
  end

  defp drip(conn, deadline) do
    if System.monotonic_time(:millisecond) < deadline do
      case chunk(conn, " ") do
        {:ok, conn} ->
          Process.sleep(25)
          drip(conn, deadline)

        {:error, _} ->
          conn
      end
    else
      conn
    end
  end

  defp json(conn, value),
    do: conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(value))
end

defmodule HarnessForge.CodexCodingLifecycleTest do
  use HarnessForge.DataCase, async: false

  alias HarnessForge.{
    Company,
    Contracts,
    Decisions,
    Demo,
    Evaluations,
    Evidence,
    Harnesses,
    Models,
    Workspaces
  }

  alias HarnessForge.CodingDockerFixture, as: Fixture
  alias HarnessForge.Evaluation.Run
  alias HarnessForge.Execution.{Codex, Coding, CodingSession, CodingTransport, Docker, Relay}

  setup do
    previous =
      Map.new(
        [:workspace_id, :workspace_root, :model_test_plug],
        &{&1, Application.get_env(:harness_forge, &1)}
      )

    Application.delete_env(:harness_forge, :model_test_plug)

    fixture = Fixture.install!()
    root = Path.join(fixture.root, "workspace")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    Application.put_env(:harness_forge, :workspace_root, root)
    Application.put_env(:harness_forge, :workspace_id, Ecto.UUID.generate())
    {:ok, observation} = CodingTransport.observe()

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        if is_nil(value),
          do: Application.delete_env(:harness_forge, key),
          else: Application.put_env(:harness_forge, key, value)
      end)

      Fixture.restore(fixture)
    end)

    %{fixture: fixture, observation: observation, admission: admission(observation)}
  end

  test "Codex gets a distinct immutable-image profile while the OpenCode profile is unchanged",
       ctx do
    open = Coding.profile(ctx.observation)
    codex = Coding.profile(ctx.observation, ctx.admission)
    assert open["id"] == "docker-coding-isolated-v2"
    assert open["runtime_image"] == Docker.image()
    assert codex["id"] == "docker-codex-isolated-v1"
    assert codex["runtime_image"] == ctx.admission.driver["image_id"]
    assert codex["protocol"] == "ollama-native-responses-v1"
    assert codex["protected_grader"] == open["protected_grader"]
    assert codex["network"] == open["network"]
    assert codex["rule_tmpfs"] == Codex.rule_tmpfs()
    refute Coding.profile_digest(ctx.admission) == Coding.profile_digest(ctx.observation)
  end

  test "Codex container admission rejects missing, writable, altered and extra tmpfs mounts" do
    home = "rw,noexec,nosuid,nodev,size=64m,mode=0700,uid=65534,gid=65534"

    expected =
      Map.merge(Codex.rule_tmpfs(), %{
        "/tmp" => "rw,noexec,nosuid,nodev,size=512m,mode=1777",
        "/home/harnessforge" => home,
        "/home/harnessforge/.codex" => home
      })

    inspection = %{
      "Config" => %{
        "Env" => [
          "HOME=/home/harnessforge",
          "CODEX_HOME=/home/harnessforge/.codex",
          "HARNESSFORGE_RELAY_TOKEN=synthetic-only"
        ]
      },
      "HostConfig" => %{"Tmpfs" => expected}
    }

    assert Coding.validate_codex_container_config(inspection)

    for path <- Map.keys(expected) do
      for changed <- [Map.delete(expected, path), Map.put(expected, path, "rw,size=64k")] do
        refute Coding.validate_codex_container_config(
                 put_in(inspection, ["HostConfig", "Tmpfs"], changed)
               )
      end
    end

    refute Coding.validate_codex_container_config(
             put_in(inspection, ["HostConfig", "Tmpfs"], Map.put(expected, "/extra", home))
           )

    for variable <- [
          "OPENAI_API_KEY=synthetic",
          "ANTHROPIC_API_KEY=synthetic",
          "HARNESSFORGE_RELAY_TOKEN=duplicate"
        ] do
      refute Coding.validate_codex_container_config(
               update_in(inspection, ["Config", "Env"], &[variable | &1])
             )
    end

    refute Coding.validate_codex_container_config(%{})
    refute Coding.validate_codex_container_config(nil)
  end

  test "persisted context binds target, exact image, model, tools, workspace and run", ctx do
    record = owned_run(ctx.admission)

    assert {:ok, actual} =
             Coding.decode_context(
               record.execution_context,
               record.result,
               record.workspace_id,
               record.id
             )

    assert actual == ctx.admission

    for context <- [
          Map.put(record.execution_context, "unknown", "ignored"),
          put_in(record.execution_context, ["transport", "workspace_id"], Ecto.UUID.generate()),
          put_in(record.execution_context, ["transport", "run_id"], Ecto.UUID.generate()),
          put_in(record.execution_context, ["driver", "image_id"], "codex:latest"),
          put_in(record.execution_context, ["driver", "receipt_digest"], hash("other receipt")),
          put_in(record.execution_context, ["model_identity", "digest"], hash("other model")),
          put_in(record.execution_context, ["codex_tools"], [%{"type" => "web_search"}]),
          put_in(record.execution_context, ["profile", "id"], "docker-coding-isolated-v2")
        ] do
      assert {:error, :coding_cleanup_context_invalid} =
               Coding.decode_context(context, record.result, record.workspace_id, record.id)
    end

    for changes <- [
          %{"runtime_name" => "opencode"},
          %{"runtime_image" => "codex:latest"},
          %{"codex_tools_digest" => hash("different tools")},
          %{"model_identity_digest" => hash("different model")}
        ] do
      assert {:error, :coding_cleanup_context_invalid} =
               Coding.decode_context(
                 record.execution_context,
                 Map.merge(record.result, changes),
                 record.workspace_id,
                 record.id
               )
    end
  end

  test "cleanup needs the original daemon and ownership, not current image/model receipts", ctx do
    record = owned_run(ctx.admission)
    refute File.exists?(Path.join(Workspaces.root(), "runtime/codex-image-receipt.json"))
    Fixture.select(ctx.fixture, ctx.fixture.decoy_endpoint)
    Fixture.clear_commands(ctx.fixture)
    assert :ok = Coding.cleanup(record.id)
    commands = Fixture.commands(ctx.fixture)
    assert commands != []

    assert Enum.all?(commands, fn command ->
             Enum.take(command["argv"], 2) == ["--host", ctx.fixture.endpoint]
           end)

    refute Enum.any?(commands, fn command -> "image" in command["argv"] end)
    assert Repo.get!(Run, record.id).execution_context == record.execution_context
  end

  test "daemon substitution fails closed and retains original context for cleanup retry", ctx do
    record = owned_run(ctx.admission)

    Fixture.put_daemon(ctx.fixture, ctx.fixture.endpoint, %{
      "identity_raw" => Jason.encode!("substituted")
    })

    assert {:error, :coding_transport_changed} = Coding.cleanup(record.id)
    assert Repo.get!(Run, record.id).execution_context == record.execution_context

    Fixture.put_daemon(ctx.fixture, ctx.fixture.endpoint, %{
      "identity_raw" => Jason.encode!(ctx.observation.daemon_id)
    })

    assert :ok = Coding.cleanup(record.id)
  end

  test "Codex cleanup cannot remove a similarly named OpenCode container", ctx do
    record = owned_run(ctx.admission)
    name = "hf-code-#{record.id}-clamp-agent"

    container = %{
      "Config" => %{
        "Labels" => %{
          "dev.harnessforge.workspace" => Workspaces.current_id(),
          "dev.harnessforge.run" => record.id,
          "dev.harnessforge.profile" => "docker-coding-isolated-v2"
        }
      }
    }

    Fixture.put_daemon(ctx.fixture, ctx.fixture.endpoint, %{"containers" => %{name => container}})
    assert {:error, :coding_container_not_owned} = Coding.cleanup(record.id)
    refute Enum.any?(Fixture.commands(ctx.fixture), &(Enum.at(&1["argv"], 2) == "rm"))

    container =
      put_in(
        container,
        ["Config", "Labels", "dev.harnessforge.profile"],
        "docker-codex-isolated-v1"
      )

    Fixture.put_daemon(ctx.fixture, ctx.fixture.endpoint, %{"containers" => %{name => container}})
    assert :ok = Coding.cleanup(record.id)
  end

  test "cancellation of an owned Codex run cleans its original resources and never qualifies",
       ctx do
    record = owned_run(ctx.admission)
    assert {:ok, result} = Evaluations.cancel(record.id)
    assert result["outcome"] == "cancelled"
    assert result["cleanup_status"] == "complete"
    refute result["runtime_qualified"]
    assert :ok = Coding.cleanup(record.id)
  end

  @tag timeout: 30_000
  test "in-flight cancellation drains reported and unknown Ledger usage without a late success",
       ctx do
    {mode, _port} = upstream(:reported)
    artifact = approved_artifact()

    for response_mode <- [:reported, :unknown] do
      Agent.update(mode, fn _ -> response_mode end)
      record = owned_run(ctx.admission, artifact["digest"])

      assert {:ok, relay} =
               Relay.start_run(record.id,
                 authorize: fn -> Coding.authorize_run(record.id, artifact) end
               )

      assert {:ok, session} = CodingSession.start(record.id, relay)

      on_exit(fn ->
        CodingSession.stop(record.id)
        Relay.stop(relay)
      end)

      request = Task.async(fn -> send_chat(relay) end)
      assert_receive {:lifecycle_inflight_dispatch, provider}, 5_000
      assert {:ok, [%{"state" => "dispatched"}]} = Models.list_requests(record.id)
      cancellation = Task.async(fn -> Evaluations.cancel(record.id) end)
      assert Task.yield(cancellation, 100) == nil
      assert {:ok, pending} = Evaluations.get(record.id)
      assert pending["outcome"] == "cancelled"
      assert pending["cleanup_status"] == "pending"
      assert pending["model_requests"] == 1
      assert pending["usage_status"] == "unknown"
      completed_at = pending["completed_at"]
      send(provider, :release_lifecycle_response)
      assert {:ok, cancelled} = Task.await(cancellation, 10_000)
      assert {:ok, response} = Task.await(request, 10_000)
      assert response.status in 400..599
      assert cancelled["outcome"] == "cancelled"
      assert cancelled["cleanup_status"] == "complete"
      assert cancelled["reason"] == "operator_cancelled"
      assert cancelled["completed_at"] == completed_at
      refute cancelled["runtime_qualified"]
      assert cancelled["model_requests"] == 1
      assert Repo.get!(Run, record.id).execution_context == record.execution_context
      assert {:ok, [ledger]} = Models.list_requests(record.id)
      assert cancelled["usage_status"] == ledger["usage_status"]

      if response_mode == :reported do
        assert ledger["state"] == "completed"
        assert cancelled["input_tokens"] == ledger["input_tokens"]
        assert cancelled["output_tokens"] == ledger["output_tokens"]
        assert cancelled["input_tokens"] == 11
        assert cancelled["output_tokens"] == 7
      else
        assert ledger["state"] == "uncertain"
        assert cancelled["usage_status"] == "unknown"
        assert is_nil(cancelled["input_tokens"])
        assert is_nil(cancelled["output_tokens"])
      end

      assert {:ok, ^cancelled} = Evaluations.cancel(record.id)
      refute Process.alive?(session)
      refute Process.alive?(relay.pid)
    end
  end

  test "cancellation before dispatch records no request rather than inventing token usage", ctx do
    upstream(:reported)
    record = owned_run(ctx.admission)
    assert {:ok, relay} = Relay.start_run(record.id)
    assert {:ok, _session} = CodingSession.start(record.id, relay)

    on_exit(fn ->
      CodingSession.stop(record.id)
      Relay.stop(relay)
    end)

    assert {:ok, cancelled} = Evaluations.cancel(record.id)
    assert cancelled["outcome"] == "cancelled"
    refute cancelled["runtime_qualified"]
    assert cancelled["usage_status"] == "not_dispatched"
    assert cancelled["model_requests"] == 0
    assert {:ok, []} = Models.list_requests(record.id)
    refute_receive {:lifecycle_inflight_dispatch, _}, 50
    assert Repo.get!(Run, record.id).execution_context == record.execution_context
  end

  @tag timeout: 20_000
  test "stale real company plans cannot block cancelled Ledger settlement or publish new transcript bytes",
       ctx do
    upstream(:reported)
    fixture = HarnessForge.CompanyAssessmentFixture.create!(Workspaces.root())

    attrs =
      Map.merge(fixture.plan_attrs, %{
        "name" => "cancelled-company-codex",
        "runtime" => "codex",
        "runtime_version" => "0.156.0",
        "package_version" => "1.0.1"
      })

    assert {:ok, plan} = Company.create_plan(attrs)

    assert {:ok, plan} =
             Company.decide_plan(plan["id"], HarnessForge.CompanyAssessmentFixture.decision(plan))

    assert {:ok, artifact} = Harnesses.build_plan(plan["id"], plan["revision_hash"])
    assert :ok = Harnesses.eligible(artifact)
    record = owned_run(ctx.admission, artifact["digest"])
    existing_checks = [%{"id" => "prior-metadata-only-check", "outcome" => "failed"}]

    record =
      Repo.update!(
        Ecto.Changeset.change(record, result: Map.put(record.result, "checks", existing_checks))
      )

    assert {:ok, relay} =
             Relay.start_run(record.id,
               authorize: fn -> Coding.authorize_run(record.id, artifact) end
             )

    assert {:ok, _session} = CodingSession.start(record.id, relay)

    on_exit(fn ->
      CodingSession.stop(record.id)
      Relay.stop(relay)
    end)

    request = Task.async(fn -> send_chat(relay) end)
    assert_receive {:lifecycle_inflight_dispatch, provider}, 5_000
    assert {:ok, [%{"state" => "dispatched"}]} = Models.list_requests(record.id)
    cancellation = Task.async(fn -> Evaluations.cancel(record.id) end)
    assert Task.yield(cancellation, 100) == nil
    assert {:ok, pending} = Evaluations.get(record.id)
    assert pending["outcome"] == "cancelled"

    assert {:ok, _} =
             Company.update_repository(
               fixture.repository["id"],
               Map.merge(fixture.repository["payload"], %{
                 "name" => "Changed after cancellation",
                 "expected_content_hash" => fixture.repository["content_hash"]
               })
             )

    assert {:error, :stale_or_revoked_plan} = Harnesses.eligible(artifact)
    assert {:error, :stale_or_revoked_plan} = Evaluations.run(artifact["digest"])

    source_bytes = hd(fixture.sources)["latest_revision"]["body"]

    late_checks = [
      %{
        "id" => "clamp",
        "outcome" => "passed",
        "duration_ms" => 1,
        "evidence" => %{"version" => 1, "solver_stopped" => true, "agent_output" => source_bytes}
      }
    ]

    # Public caller-supplied results remain rejected. The separate optional
    # Docker integration is the actual executor late-return coverage; this
    # deterministic test exercises real plan denial and in-flight accounting.
    assert {:error, :invalid_evaluation_options} =
             Evaluations.run(artifact["digest"], checks: late_checks)

    send(provider, :release_lifecycle_response)
    assert {:ok, cancelled} = Task.await(cancellation, 10_000)
    assert {:ok, response} = Task.await(request, 10_000)
    assert response.status in 400..599
    assert cancelled["outcome"] == "cancelled"
    refute cancelled["runtime_qualified"]
    assert cancelled["reason"] == pending["reason"]
    assert cancelled["completed_at"] == pending["completed_at"]
    assert cancelled["cleanup_status"] == "complete"
    assert cancelled["usage_status"] == "reported"
    assert cancelled["model_requests"] == 1
    assert {:ok, [ledger]} = Models.list_requests(record.id)
    assert cancelled["input_tokens"] == ledger["input_tokens"]
    assert cancelled["output_tokens"] == ledger["output_tokens"]
    assert cancelled["checks"] == existing_checks
    refute Jason.encode!(cancelled) =~ source_bytes
    assert Repo.get!(Run, record.id).execution_context == record.execution_context
    assert {:ok, ^cancelled} = Evaluations.cancel(record.id)

    assert {:error, :harness_unavailable} =
             HarnessForgeWeb.HarnessDelivery.check_details(artifact["digest"], record.id)
  end

  @tag timeout: 10_000
  test "actual Codex admission reaches only bounded metadata while a peer continuously drips",
       ctx do
    upstream(:drip)
    artifact = approved_artifact()
    install_image_metadata(ctx)
    Fixture.clear_commands(ctx.fixture)
    started = System.monotonic_time(:millisecond)
    admission = Task.async(fn -> Coding.admit(artifact) end)
    result = Task.yield(admission, 4_500)
    if is_nil(result), do: Task.shutdown(admission, :brutal_kill)
    assert {:ok, {:error, _}} = result
    assert System.monotonic_time(:millisecond) - started < 4_500
    assert_receive {:lifecycle_metadata_or_dispatch, "/api/version"}
    refute_receive {:lifecycle_metadata_or_dispatch, "/api/tags"}, 50
    refute_receive {:lifecycle_metadata_or_dispatch, "/api/chat"}, 50
    assert {:ok, []} = Models.list_requests("admission-does-not-dispatch")

    refute Enum.any?(Fixture.commands(ctx.fixture), fn command ->
             Enum.at(command["argv"], 2) in ["create", "run", "start", "exec", "network"]
           end)
  end

  test "restart reconciliation recognizes the Codex profile without checking a current model",
       ctx do
    record = owned_run(ctx.admission)
    assert :ok = Evaluations.reconcile()
    assert {:ok, result} = Evaluations.get(record.id)
    assert result["outcome"] == "interrupted"
    assert result["reason"] == "application_restarted"
    assert result["cleanup_status"] == "complete"
    refute result["runtime_qualified"]
  end

  test "corrupt owned context blocks cleanup before Docker commands", ctx do
    record = owned_run(ctx.admission)

    Repo.update!(
      Ecto.Changeset.change(record,
        execution_context: Map.put(record.execution_context, "extra", true)
      )
    )

    Fixture.clear_commands(ctx.fixture)
    assert {:error, :cleanup_failed} = Evaluations.cleanup_runs({:ids, [record.id]})
    assert Fixture.commands(ctx.fixture) == []
    assert {:ok, result} = Evaluations.get(record.id)
    assert result["cleanup_status"] == "cleanup_failed"
    refute result["runtime_qualified"]
  end

  test "legacy blocked Codex rows without owned resources remain inert", ctx do
    record = owned_run(ctx.admission)

    result =
      record.result
      |> Map.delete("execution_profile_id")
      |> Map.merge(%{
        "outcome" => "blocked",
        "cleanup_status" => "not_started",
        "usage_status" => "not_dispatched"
      })

    Repo.update!(Ecto.Changeset.change(record, result: result, execution_context: nil))
    Fixture.clear_commands(ctx.fixture)
    assert :ok = Evaluations.cleanup_runs({:ids, [record.id]})
    assert Fixture.commands(ctx.fixture) == []
  end

  test "stored evidence strips capability, local endpoint, terminal controls and invalid bytes" do
    secret = "synthetic-relay-capability"
    endpoint = "http://127.0.0.1:12345"

    assert {:ok, text} =
             Coding.sanitize_evidence(
               "\e[31m#{secret}\e[0m\r\n#{endpoint}\x00<script>data</script>",
               [secret, endpoint]
             )

    refute text =~ secret
    refute text =~ endpoint
    refute text =~ "\e"
    refute text =~ "\x00"
    assert text =~ "[REDACTED]"
    assert text =~ "<script>data</script>"
    assert {:error, :task_output_invalid} = Coding.sanitize_evidence(<<255>>, [])

    assert {:error, :task_output_invalid} =
             Coding.sanitize_evidence(String.duplicate("x", 131_073), [])
  end

  test "historical summaries expose only the fixed Codex recovery reasons", ctx do
    reasons =
      ~w(codex_image_receipt_missing codex_image_receipt_untrusted codex_image_receipt_mismatch codex_image_unverified codex_tools_unverified codex_preflight_rejected codex_events_rejected codex_runtime_config_invalid local_model_identity_unavailable local_model_identity_changed)

    for reason <- reasons ++ ["untrusted-provider-detail"] do
      record = owned_run(ctx.admission, hash(reason))

      Repo.update!(
        Ecto.Changeset.change(record,
          result: Map.merge(record.result, %{"outcome" => "blocked", "reason" => reason})
        )
      )

      assert {:ok, [summary]} = Evaluations.recent_summaries(record.artifact_digest)
      assert summary["reason"] == if(reason in reasons, do: reason, else: "unknown")
    end
  end

  test "Codex metadata admission is refused before I/O in a caller-owned SQL transaction", ctx do
    artifact = %{
      "spec" => %{"spec" => %{"runtime" => %{"name" => "codex", "version" => "0.156.0"}}}
    }

    Fixture.clear_commands(ctx.fixture)

    assert {:ok, {:error, :codex_admission_requires_outermost_transaction}} =
             Repo.transaction(fn -> Coding.admit(artifact) end)

    assert Fixture.commands(ctx.fixture) == []
  end

  test "the dispatch/publication gate rejects cancellation and an immediate revision hold", ctx do
    artifact = approved_artifact()
    record = owned_run(ctx.admission, artifact["digest"])
    assert :ok = Coding.authorize_run(record.id, artifact)

    Repo.update!(
      Ecto.Changeset.change(record, result: Map.put(record.result, "outcome", "cancelled"))
    )

    assert {:error, :evaluation_authority_withdrawn} = Coding.authorize_run(record.id, artifact)
    Repo.update!(Ecto.Changeset.change(record, result: record.result))

    revision_id =
      artifact["spec"]["spec"]["rules"]
      |> hd()
      |> Map.fetch!("evidence")
      |> hd()
      |> Map.fetch!("revision_id")

    hold_id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO revision_use_holds(id,workspace_id,connection_id,provider,external_id,source_id,revision_id,body_hash,command_id,request_digest,denied_purposes,reason_code,actor,inserted_at)
      SELECT ?,r.workspace_id,s.connection_id,s.provider,s.external_id,s.id,r.id,r.body_hash,?,?,
        '["inspection","retrieval","analysis","compile"]','operator_restriction','test-author',?
      FROM evidence_revisions r JOIN evidence_sources s ON s.id=r.source_id AND s.workspace_id=r.workspace_id
      WHERE r.workspace_id=? AND r.id=?
      """,
      [
        hold_id,
        Ecto.UUID.generate(),
        hash("hold-fixture"),
        DateTime.to_iso8601(DateTime.utc_now()),
        Workspaces.current_id(),
        revision_id
      ]
    )

    Repo.query!(
      "INSERT INTO revision_use_cleanup(event_id,workspace_id,updated_at) VALUES(?,?,?)",
      [hold_id, Workspaces.current_id(), DateTime.to_iso8601(DateTime.utc_now())]
    )

    assert {:error, :evaluation_authority_withdrawn} = Coding.authorize_run(record.id, artifact)

    assert %{rows: [["pending", ""]]} =
             Repo.query!("SELECT state,cursor FROM revision_use_cleanup WHERE event_id=?", [
               hold_id
             ])
  end

  defp admission(observation) do
    %{
      observation: observation,
      driver: %{
        "image_id" => "sha256:" <> hash("codex image"),
        "descriptor_digest" => hash("driver"),
        "receipt_digest" => hash("receipt"),
        "cli_version" => "0.156.0",
        "platform" => "linux/arm64"
      },
      model_identity: %{
        "version" => "0.40.14",
        "model" => "synthetic:codex",
        "digest" => hash("model"),
        "endpoint" => "http://127.0.0.1:12345",
        "capabilities" => ["completion", "tools"]
      },
      codex_tools: [],
      tools_profile_digest: hash("tools profile")
    }
  end

  defp owned_run(admission, digest \\ nil) do
    id = Ecto.UUID.generate()
    digest = digest || hash("synthetic artifact")
    {:ok, context} = Coding.context(admission, Workspaces.current_id(), id)

    result =
      %{
        "id" => id,
        "workspace_id" => Workspaces.current_id(),
        "artifact_digest" => digest,
        "kind" => "task",
        "runtime_name" => "codex",
        "runtime_image" => Coding.runtime_image(admission),
        "runtime_version" => Coding.runtime_version(admission),
        "execution_profile_id" => "docker-codex-isolated-v1",
        "environment_profile_digest" => Coding.profile_digest(admission),
        "outcome" => "running",
        "cleanup_status" => "pending",
        "runtime_qualified" => false,
        "usage_status" => "not_dispatched"
      }
      |> Map.merge(Coding.identity(admission))

    Repo.insert!(%Run{
      id: id,
      workspace_id: Workspaces.current_id(),
      artifact_digest: digest,
      execution_context: context,
      result: result
    })
  end

  defp approved_artifact do
    {:ok, _} = Demo.load()
    {:ok, claims} = Evidence.list_claims()
    claim = Enum.find(claims, &(not String.starts_with?(&1["text"], "IGNORE")))

    {:ok, _} =
      Decisions.decide(claim["id"], %{
        "actor" => Workspaces.operator(),
        "decision" => "approve",
        "expected_revision_hash" => claim["revision_hash"]
      })

    {:ok, artifact} = Harnesses.build(%{"runtime" => "codex", "runtime_version" => "0.156.0"})
    artifact
  end

  defp upstream(initial_mode) do
    {:ok, mode} = Agent.start_link(fn -> initial_mode end)

    upstream =
      start_supervised!(
        {Bandit,
         [
           plug: {__MODULE__.Upstream, %{owner: self(), mode: mode}},
           ip: {127, 0, 0, 1},
           port: 0,
           startup_log: false
         ]}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(upstream)

    assert {:ok, _} =
             Models.configure(%{
               "model" => "synthetic:fixture",
               "endpoint" => "http://127.0.0.1:#{port}"
             })

    {mode, port}
  end

  defp send_chat(relay) do
    Req.post("http://127.0.0.1:#{relay.port}/v1/chat/completions",
      headers: [{"authorization", "Bearer " <> relay.token}],
      retry: false,
      receive_timeout: 10_000,
      connect_options: [timeout: 1_000],
      json: %{
        "model" => "synthetic:fixture",
        "max_tokens" => 128,
        "messages" => [
          %{"role" => "user", "content" => "Public synthetic cancellation accounting fixture"}
        ]
      }
    )
  end

  defp install_image_metadata(ctx) do
    image_id = "sha256:" <> hash("fixed admission image")
    image = %{"Id" => image_id, "Os" => "linux", "Architecture" => "arm64"}
    executable = Path.join(ctx.fixture.root, "docker")
    source = File.read!(executable)
    assert source =~ "print('sha256:synthetic-fixture')"

    File.write!(
      executable,
      String.replace(
        source,
        "print('sha256:synthetic-fixture')",
        "print(" <> Jason.encode!(Jason.encode!(image)) <> ")"
      )
    )

    descriptor = Codex.descriptor()

    receipt = %{
      "version" => 1,
      "driver_id" => descriptor["id"],
      "descriptor_digest" => Codex.descriptor_digest(),
      "input_hashes" => descriptor["input_hashes"],
      "base_image" => descriptor["base_image"],
      "platform" => "linux/arm64",
      "image_id" => image_id,
      "cli_version" => "0.156.0",
      "transport_identity_digest" => CodingTransport.identity_digest(ctx.observation),
      "cli_version_output_sha256" => hash("codex-cli 0.156.0\n")
    }

    directory = Path.join(Workspaces.root(), "runtime")
    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)
    File.write!(Codex.receipt_path(), Jason.encode!(receipt))
    File.chmod!(Codex.receipt_path(), 0o600)
  end

  defp hash(bytes), do: Contracts.sha256(bytes)
end
