defmodule HarnessForge.EvaluationsTest do
  use HarnessForge.DataCase, async: false
  alias HarnessForge.{Contracts, Decisions, Demo, Evaluations, Evidence, Harnesses, Workspaces}
  alias HarnessForge.Evaluation.Run

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
    assert result["execution_limits_digest"] == Contracts.digest(a["spec"]["spec"]["execution"])
    assert Repo.get!(Run, result["id"]).execution_context == nil
    assert {:error, :evaluation_inapplicable} = Evaluations.applicability(a, result)
  end

  test "static integrity passes only its explicitly named check", %{artifact: a} do
    assert {:ok, result} = Evaluations.run(a["digest"], kind: "static_integrity")
    assert result["outcome"] == "passed"
    assert result["kind"] == "static_integrity"
    refute Map.has_key?(result, "execution_limits_digest")
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

  test "matching task limits allow treatment artifact and effective configuration differences", %{
    artifact: a
  } do
    {:ok, baseline} = Evaluations.run(a["digest"])

    candidate =
      comparison_record(baseline, %{
        "artifact_digest" => Contracts.sha256("synthetic treatment artifact"),
        "effective_config_digest" => Contracts.sha256("synthetic treatment configuration")
      })

    assert {:ok, %{"comparable" => true, "qualified" => false}} =
             Evaluations.compare(baseline["id"], candidate["id"])
  end

  test "task comparison rejects a change to only timeout or turns", %{artifact: a} do
    {:ok, baseline} = Evaluations.run(a["digest"])
    execution = a["spec"]["spec"]["execution"]

    for key <- ~w(timeout_seconds max_turns) do
      candidate =
        comparison_record(baseline, %{
          "execution_limits_digest" => Contracts.digest(Map.update!(execution, key, &(&1 + 1)))
        })

      before = comparison_records(baseline, candidate)

      assert {:error, :evaluation_identities_differ} =
               Evaluations.compare(baseline["id"], candidate["id"])

      assert comparison_records(baseline, candidate) == before
    end
  end

  test "task comparison refuses missing null or malformed limits on either or both records", %{
    artifact: a
  } do
    {:ok, valid} = Evaluations.run(a["digest"])

    for invalid <- [
          :missing,
          nil,
          "",
          String.duplicate("a", 63),
          String.duplicate("a", 65),
          String.duplicate("g", 64),
          String.duplicate("A", 64),
          64,
          [],
          %{}
        ],
        side <- [:baseline, :candidate, :both] do
      baseline =
        valid
        |> limits_fixture(
          if(side in [:baseline, :both], do: invalid, else: valid["execution_limits_digest"])
        )
        |> comparison_record()

      candidate =
        valid
        |> limits_fixture(
          if(side in [:candidate, :both], do: invalid, else: valid["execution_limits_digest"])
        )
        |> comparison_record()

      before = comparison_records(baseline, candidate)
      counts = comparison_effect_counts()

      assert {:error, :evaluation_identities_differ} =
               Evaluations.compare(baseline["id"], candidate["id"])

      assert comparison_records(baseline, candidate) == before
      assert comparison_effect_counts() == counts
    end
  end

  test "offline Codex task retains its canonical execution limits identity" do
    {:ok, artifact} = Harnesses.build(%{"runtime" => "codex", "runtime_version" => "0.156.0"})
    {:ok, result} = Evaluations.run(artifact["digest"])

    assert result["runtime_name"] == "codex"
    assert result["reason"] == "model_not_selected"
    assert result["usage_status"] == "not_dispatched"

    assert result["execution_limits_digest"] ==
             Contracts.digest(artifact["spec"]["spec"]["execution"])

    candidate = comparison_record(result)

    assert {:ok, %{"comparable" => true, "qualified" => false}} =
             Evaluations.compare(result["id"], candidate["id"])
  end

  test "offline runtime smoke comparison does not require task limits", %{artifact: a} do
    {:ok, static} = Evaluations.run(a["digest"], kind: :static_integrity)
    baseline = comparison_record(static, %{"kind" => "runtime_smoke"})
    candidate = comparison_record(static, %{"kind" => "runtime_smoke"})

    refute Map.has_key?(baseline, "execution_limits_digest")

    assert {:ok, %{"comparable" => true, "qualified" => false}} =
             Evaluations.compare(baseline["id"], candidate["id"])
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

  # Synthetic persisted comparison records exercise identity checks without
  # starting a runtime, dispatching inference or claiming an observed task pass.
  defp comparison_record(result, changes \\ %{}) do
    result = result |> Map.merge(changes) |> Map.put("id", Ecto.UUID.generate())

    Repo.insert!(%Run{
      id: result["id"],
      workspace_id: Workspaces.current_id(),
      artifact_digest: result["artifact_digest"],
      result: result
    })

    result
  end

  defp limits_fixture(result, :missing), do: Map.delete(result, "execution_limits_digest")
  defp limits_fixture(result, digest), do: Map.put(result, "execution_limits_digest", digest)

  defp comparison_records(baseline, candidate),
    do: Enum.map([baseline, candidate], &Repo.get!(Run, &1["id"]))

  defp comparison_effect_counts do
    for table <- ~w(model_requests model_budgets oban_jobs audit_events), into: %{} do
      {table, Repo.query!("SELECT count(*) FROM " <> table).rows}
    end
  end
end
