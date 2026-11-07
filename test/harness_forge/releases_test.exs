defmodule HarnessForge.ReleasesTest do
  use HarnessForge.DataCase, async: false

  alias HarnessForge.{
    Contracts,
    Decisions,
    Demo,
    Evaluations,
    Evidence,
    Harnesses,
    Models,
    Releases,
    Workspaces
  }

  alias HarnessForge.Evaluation.Run
  alias HarnessForge.CodingDockerFixture
  alias HarnessForge.Execution.{CodingTransport, Docker}
  alias HarnessForge.Releases.Approval

  defmodule Health do
    import Plug.Conn
    def init(counter), do: counter

    def call(%{method: "GET", request_path: "/api/tags"} = conn, _counter) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{"models" => [%{"name" => "synthetic:release-fixture"}]}))
    end

    def call(conn, counter) do
      :atomics.add(counter, 1, 1)
      send_resp(conn, 404, "No inference is provided by this fixture")
    end
  end

  # These privileged direct-DB fixtures prove the release state machine only.
  # They do not establish a live model route, objective grader or qualified task.
  # Production Evaluations.run/2 never authors a qualified task under this profile.
  setup do
    previous = Application.fetch_env!(:harness_forge, :workspace_root)
    root = Path.join(File.cwd!(), "tmp/hf-release-#{Ecto.UUID.generate()}")
    Application.put_env(:harness_forge, :workspace_root, root)
    fixture = CodingDockerFixture.install!()
    counter = :atomics.new(1, [])

    upstream =
      start_supervised!(
        {Bandit, plug: {Health, counter}, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(upstream)

    {:ok, _} =
      Models.configure(%{
        "provider" => "ollama",
        "model" => "synthetic:release-fixture",
        "endpoint" => "http://127.0.0.1:#{port}",
        "cloud_consent" => nil,
        "credential_env" => nil
      })

    on_exit(fn ->
      Application.put_env(:harness_forge, :workspace_root, previous)
      File.rm_rf!(root)
      CodingDockerFixture.restore(fixture)
      assert :atomics.get(counter, 1) == 0
    end)

    {:ok, _} = Demo.load()
    {:ok, claims} = Evidence.list_claims()

    for claim <- claims, not String.starts_with?(claim["text"], "IGNORE") do
      {:ok, _} =
        Decisions.decide(claim["id"], %{
          "actor" => Workspaces.operator(),
          "decision" => "approve",
          "expected_revision_hash" => claim["revision_hash"]
        })
    end

    {:ok, artifact} = build("0.1.0")
    {:ok, root: root, artifact: artifact, fixture: fixture}
  end

  test "real task evaluation is blocked; passed static and smoke runs cannot approve", %{
    artifact: artifact
  } do
    {:ok, _} = Models.configure(%{"model" => nil})
    assert {:ok, task} = Evaluations.run(artifact["digest"])
    assert task["kind"] == "task"
    assert task["outcome"] == "blocked"

    assert {:error, :qualified_task_evaluation_required} =
             Releases.approve(inputs(artifact, task))

    assert {:ok, static} = Evaluations.run(artifact["digest"], kind: :static_integrity)
    assert static["outcome"] == "passed"

    assert {:error, :qualified_task_evaluation_required} =
             Releases.approve(inputs(artifact, static))

    smoke =
      evaluation_fixture(artifact, %{"kind" => "runtime_smoke", "runtime_qualified" => false})

    assert {:error, :qualified_task_evaluation_required} =
             Releases.approve(inputs(artifact, smoke))

    assert {:error, :invalid_release_input} =
             Releases.approve(Map.put(inputs(artifact, task), "outcome", "passed"))

    assert {:ok, []} = Releases.list()
  end

  test "fixture-only approval, promotion and rollback preserve hashes, bytes and history", %{
    artifact: first,
    root: root
  } do
    run = evaluation_fixture(first)
    assert {:ok, approval} = Releases.approve(inputs(first, run))
    assert approval["artifact_digest"] == first["digest"]
    assert approval["spec_digest"] == first["manifest"]["spec_digest"]
    assert approval["manifest_digest"] == Contracts.digest(first["manifest"])
    assert approval["evaluation_digest"] == Contracts.digest(run)

    assert approval["approval_digest"] ==
             Contracts.digest(Map.delete(approval, "approval_digest"))

    assert {:ok, nil} = Releases.current(scope(first))
    assert {:ok, initial} = Releases.promote(approval["id"])
    assert initial["version"] == 1

    {:ok, second} = build("0.2.0")
    {:ok, next} = Releases.approve(inputs(second, evaluation_fixture(second)))
    assert {:ok, %{"version" => 2}} = Releases.promote(next["id"], approval["id"])

    assert {:ok, %{"version" => 3, "release_id" => restored_id}} =
             Releases.rollback(approval["id"], next["id"])

    assert restored_id == approval["id"]
    assert {:ok, history} = Releases.history(scope(first))
    assert Enum.map(history, & &1["action"]) == ["promote", "promote", "rollback"]
    assert Enum.map(history, & &1["previous_release_id"]) == [nil, approval["id"], next["id"]]
    assert {:ok, approvals} = Releases.list()
    assert length(approvals) == 2
    assert {:ok, %{"release_id" => ^restored_id}} = Releases.current(scope(first))

    assert {:ok, %{"path" => target}} =
             Harnesses.export(first["digest"], Path.join(root, "rollback-export"))

    for {path, bytes} <- first["files"], do: assert(File.read!(Path.join(target, path)) == bytes)
    assert {:ok, diff} = Releases.diff(first["digest"], second["digest"])
    assert "harnessforge.spec.json" in diff["files"]["changed"]
    assert diff["rules"] == %{"added" => [], "removed" => [], "changed" => []}
  end

  test "every material applicability mismatch blocks approval", %{artifact: artifact} do
    for field <-
          ~w(suite_digest grader_digest task_fixture_digest environment_profile_digest effective_config_digest capability_report_digest policy_digest) do
      run = evaluation_fixture(artifact, %{field => String.duplicate("0", 64)})

      assert {:error, :evaluation_inapplicable} = Releases.approve(inputs(artifact, run)),
             "accepted mismatched #{field}"
    end

    for {field, value} <- [
          {"runtime_version", "1.0.0"},
          {"runtime_image", "untrusted:latest"},
          {"suite_id", "different-suite"},
          {"scope", %{"repositories" => ["other"]}}
        ] do
      run = evaluation_fixture(artifact, %{field => value})
      assert {:error, :evaluation_inapplicable} = Releases.approve(inputs(artifact, run))
    end

    run = evaluation_fixture(artifact, %{"artifact_digest" => String.duplicate("0", 64)})
    assert {:error, :evaluation_artifact_mismatch} = Releases.approve(inputs(artifact, run))
    run = evaluation_fixture(artifact, %{"workspace_id" => "other-workspace"})
    assert {:error, :evaluation_workspace_mismatch} = Releases.approve(inputs(artifact, run))
    run = evaluation_fixture(artifact, %{"cleanup_status" => "cleanup_failed"})
    assert {:error, :evaluation_cleanup_incomplete} = Releases.approve(inputs(artifact, run))
    run = evaluation_fixture(artifact, %{"checks" => [%{"outcome" => "failed"}]})
    assert {:error, :evaluation_checks_incomplete} = Releases.approve(inputs(artifact, run))
    run = evaluation_fixture(artifact)

    assert {:error, :release_scope_mismatch} =
             Releases.approve(
               put_in(inputs(artifact, run), ["scope"], %{"repositories" => ["other"]})
             )

    assert {:ok, []} = Releases.list()
  end

  test "source revocation blocks both new approval and restoration", %{artifact: first} do
    run = evaluation_fixture(first)
    {:ok, approval} = Releases.approve(inputs(first, run))
    {:ok, _} = Releases.promote(approval["id"])
    {:ok, second} = build("0.2.0")
    {:ok, next} = Releases.approve(inputs(second, evaluation_fixture(second)))
    {:ok, _} = Releases.promote(next["id"], approval["id"])
    {:ok, [source]} = Evidence.list_sources()
    {:ok, _} = Evidence.revoke_source(source["id"])

    assert {:error, :stale_or_revoked_evidence} = Releases.rollback(approval["id"], next["id"])

    assert {:error, :stale_or_revoked_evidence} =
             Releases.approve(inputs(first, run))

    assert {:ok, history} = Releases.history(scope(first))
    assert length(history) == 2
    assert {:ok, %{"release_id" => current_id}} = Releases.current(scope(first))
    assert current_id == next["id"]
  end

  test "stale callers and concurrent promotions have a single winner", %{artifact: first} do
    {:ok, initial} = Releases.approve(inputs(first, evaluation_fixture(first)))
    {:ok, _} = Releases.promote(initial["id"])
    {:ok, second} = build("0.2.0")
    {:ok, third} = build("0.3.0")
    {:ok, next} = Releases.approve(inputs(second, evaluation_fixture(second)))
    {:ok, other} = Releases.approve(inputs(third, evaluation_fixture(third)))

    assert {:error, :stale_channel} = Releases.promote(next["id"])

    tasks =
      for candidate <- [next, other],
          do: Task.async(fn -> Releases.promote(candidate["id"], initial["id"]) end)

    results = Enum.map(tasks, &Task.await(&1, 10_000))
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :stale_channel})) == 1
    assert {:ok, history} = Releases.history(scope(first))
    assert length(history) == 2
  end

  test "rollback requires a prior assignment and complete approval binding", %{artifact: first} do
    {:ok, initial} = Releases.approve(inputs(first, evaluation_fixture(first)))
    assert {:error, :rollback_target_not_previously_assigned} = Releases.rollback(initial["id"])
    {:ok, second} = build("0.2.0")
    {:ok, next} = Releases.approve(inputs(second, evaluation_fixture(second)))
    {:ok, _} = Releases.promote(next["id"])

    assert {:error, :rollback_target_not_previously_assigned} =
             Releases.rollback(initial["id"], next["id"])

    assert {:ok, %{"version" => 1}} = Releases.current(scope(first))
  end

  test "approval records are immutable and hash tampering blocks activation", %{
    artifact: artifact
  } do
    {:ok, approval} = Releases.approve(inputs(artifact, evaluation_fixture(artifact)))

    assert {:error, _} =
             Ecto.Adapters.SQL.query(
               Repo,
               "UPDATE release_approvals SET approval_digest = ? WHERE id = ?",
               [String.duplicate("0", 64), approval["id"]]
             )

    Ecto.Adapters.SQL.query!(Repo, "DROP TRIGGER immutable_release_approvals_update")

    Repo.update_all(from(a in Approval, where: a.id == ^approval["id"]),
      set: [approval_digest: String.duplicate("0", 64)]
    )

    assert {:error, :release_approval_integrity_failed} = Releases.promote(approval["id"])
    assert {:error, :release_approval_integrity_failed} = Releases.list()
    assert {:ok, nil} = Releases.current(scope(artifact))
  end

  test "evaluation modification after approval invalidates the frozen approval", %{
    artifact: artifact
  } do
    run = evaluation_fixture(artifact)
    {:ok, approval} = Releases.approve(inputs(artifact, run))
    # Privileged DB mutation models corrupted stored observations, not a supported command.
    record = Repo.get!(Run, run["id"])
    changed = Map.put(record.result, "reason", "modified-after-approval")
    Repo.update!(Ecto.Changeset.change(record, result: changed))
    assert {:error, :release_approval_inapplicable} = Releases.promote(approval["id"])
    assert {:ok, nil} = Releases.current(scope(artifact))
  end

  test "unqualified artifact runtime and cross-workspace IDs cannot activate", %{
    artifact: artifact
  } do
    {:ok, preview} = Harnesses.build()

    assert {:error, :runtime_unqualified} =
             Releases.approve(inputs(preview, evaluation_fixture(preview)))

    run = evaluation_fixture(artifact)
    record = Repo.get!(Run, run["id"])
    Repo.update!(Ecto.Changeset.change(record, workspace_id: "different-workspace"))
    assert {:error, :evaluation_not_found} = Releases.approve(inputs(artifact, run))
  end

  defp build(version),
    do: Harnesses.build(%{"version" => version, "runtime_version" => Docker.version()})

  defp scope(artifact), do: artifact["spec"]["spec"]["scope"]

  defp inputs(artifact, run),
    do: %{
      "artifact_digest" => artifact["digest"],
      "evaluation_id" => run["id"],
      "scope" => scope(artifact),
      "actor" => Workspaces.operator()
    }

  defp evaluation_fixture(artifact, overrides \\ %{}) do
    id = Ecto.UUID.generate()
    now = DateTime.to_iso8601(DateTime.utc_now())
    assert {:ok, observation} = CodingTransport.observe()
    assert {:ok, private} = CodingTransport.context(observation, Workspaces.current_id(), id)

    result =
      Evaluations.applicability(artifact)
      |> Map.merge(%{
        "id" => id,
        "workspace_id" => Workspaces.current_id(),
        "kind" => "task",
        "runtime_name" => "opencode",
        "execution_profile_id" => "docker-coding-isolated-v2",
        "outcome" => "passed",
        "runtime_qualified" => true,
        "reason" => "fixture_only_state_machine_proof",
        "checks" => [%{"id" => "fixture_only_protected_check", "outcome" => "passed"}],
        "cleanup_status" => "complete",
        "duration_ms" => 1,
        "usage_status" => "fixture_not_dispatched",
        "inserted_at" => now,
        "completed_at" => now
      })
      |> Map.merge(overrides)

    Repo.insert!(%Run{
      id: id,
      workspace_id: Workspaces.current_id(),
      artifact_digest: artifact["digest"],
      result: result,
      execution_context: private
    })

    result
  end
end
