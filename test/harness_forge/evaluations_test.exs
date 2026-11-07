defmodule HarnessForge.EvaluationsTest do
  use HarnessForge.DataCase, async: false
  alias HarnessForge.{Decisions, Demo, Evaluations, Evidence, Harnesses, Workspaces}

  setup do
    previous = Application.fetch_env!(:harness_forge, :workspace_root)
    root = Path.join(File.cwd!(), "tmp/hf-eval-#{Ecto.UUID.generate()}")
    Application.put_env(:harness_forge, :workspace_root, root)

    on_exit(fn ->
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

    {:ok, artifact} = Harnesses.build()
    {:ok, artifact: artifact}
  end

  test "task execution is durably blocked instead of returning fixture success", %{artifact: a} do
    assert {:ok, result} = Evaluations.run(a["digest"])
    assert result["outcome"] == "blocked"
    assert result["reason"] == "model_not_selected"
    refute result["runtime_qualified"]
    assert result["usage_status"] == "not_dispatched"
    assert {:ok, [^result]} = Evaluations.list_runs()
    assert result["execution_profile_id"] == "docker-coding-isolated-v2"
    assert result["environment_profile_digest"] == nil
    assert result["runtime_name"] == "opencode"
    assert Repo.get!(HarnessForge.Evaluation.Run, result["id"]).execution_context == nil
    assert {:error, :evaluation_inapplicable} = Evaluations.applicability(a, result)
  end

  test "static integrity passes only its explicitly named check", %{artifact: a} do
    assert {:ok, result} = Evaluations.run(a["digest"], kind: "static_integrity")
    assert result["outcome"] == "passed"
    assert result["kind"] == "static_integrity"
    refute result["runtime_qualified"]
    assert result["checks"] == [%{"id" => "artifact_digest_and_manifest", "outcome" => "passed"}]
    assert {:ok, ^result} = Evaluations.cancel(result["id"])
  end

  test "no caller can submit outcomes, qualification, runtime or arbitrary suite", %{artifact: a} do
    for opts <- [
          [passed: true],
          [runtime_qualified: true],
          [outcome: "passed"],
          [exit_status: 0],
          [suite: "attacker"],
          [kind: :shell],
          %{"kind" => "task"}
        ] do
      assert {:error, :invalid_evaluation_options} = Evaluations.run(a["digest"], opts)
    end

    assert {:ok, []} = Evaluations.list_runs()
  end

  test "comparison requires matching observation kind and frozen identities", %{artifact: a} do
    {:ok, baseline} = Evaluations.run(a["digest"], kind: :static_integrity)
    {:ok, candidate} = Evaluations.run(a["digest"], kind: :static_integrity)
    {:ok, task} = Evaluations.run(a["digest"])

    assert {:ok, %{"qualified" => false, "sample_count" => 1}} =
             Evaluations.compare(baseline["id"], candidate["id"])

    assert {:error, :evaluation_identities_differ} =
             Evaluations.compare(baseline["id"], task["id"])

    assert {:error, :evaluation_not_found} = Evaluations.cancel(Ecto.UUID.generate())

    assert {:error, :evaluation_inapplicable} =
             Evaluations.applicability(a, Map.put(task, "runtime_image", "mutable:latest"))
  end

  test "withdrawn source prevents recording a new run", %{artifact: a} do
    {:ok, [source]} = Evidence.list_sources()
    {:ok, _} = Evidence.revoke_source(source["id"])
    assert {:error, :stale_or_revoked_evidence} = Evaluations.run(a["digest"])
    assert {:ok, []} = Evaluations.list_runs()
  end

  @tag :docker
  @tag skip: System.get_env("HARNESSFORGE_DOCKER_TESTS") != "1"
  test "actual runtime smoke is durable but cannot qualify task promotion", %{artifact: a} do
    assert {:ok, result} = Evaluations.run(a["digest"], kind: :runtime_smoke)
    assert result["outcome"] == "passed", inspect(result)
    assert result["kind"] == "runtime_smoke"
    refute result["runtime_qualified"]
    assert result["cleanup_status"] == "complete"
    assert Enum.map(result["checks"], & &1["id"]) == ~w(containment version config)
    assert {:ok, ^result} = Evaluations.get(result["id"])
  end

  @tag :docker
  @tag skip: System.get_env("HARNESSFORGE_DOCKER_TESTS") != "1"
  test "recovery persists cleanup failure and refuses to remove a foreign container", %{
    artifact: a
  } do
    alias HarnessForge.Evaluation.Run
    alias HarnessForge.Execution.{Command, Docker}
    {:ok, run} = Evaluations.run(a["digest"], kind: :static_integrity)
    record = Repo.get!(Run, run["id"])

    record
    |> Ecto.Changeset.change(
      result:
        Map.merge(run, %{
          "kind" => "runtime_smoke",
          "outcome" => "running",
          "cleanup_status" => "cleanup_failed"
        })
    )
    |> Repo.update!()

    name = Docker.name(run["id"])
    on_exit(fn -> Command.docker(["rm", "--force", name]) end)

    assert {:ok, %{exit_status: 0}} =
             Command.docker([
               "create",
               "--name",
               name,
               "--label",
               "dev.harnessforge.workspace=foreign-synthetic-test",
               "--label",
               "dev.harnessforge.run=#{run["id"]}",
               Docker.image(),
               "--version"
             ])

    assert {:error, :cleanup_failed} = Evaluations.reconcile()
    assert {:ok, failed} = Evaluations.get(run["id"])
    assert failed["cleanup_status"] == "cleanup_failed"
    assert failed["outcome"] == "interrupted"
    assert {:ok, %{exit_status: 0}} = Command.docker(["inspect", name, "--format", "{{.Name}}"])
    assert {:ok, %{exit_status: 0}} = Command.docker(["rm", "--force", name])
    assert :ok = Evaluations.reconcile()
    assert {:ok, recovered} = Evaluations.get(run["id"])
    assert recovered["cleanup_status"] == "complete"
    assert recovered["outcome"] == "interrupted"
  end
end
