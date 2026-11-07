defmodule HarnessForge.HistoricalFtoaEvaluationTest do
  use HarnessForge.DataCase, async: false

  alias HarnessForge.{
    Contracts,
    Decisions,
    Demo,
    Evaluations,
    Evidence,
    Harnesses,
    Releases,
    Workspaces
  }

  alias HarnessForge.Evaluation.{Run, TaskSuite}
  alias HarnessForge.Releases.Validation

  @suite "public-humanize-ftoa-158-v1"

  setup do
    previous = Application.fetch_env!(:harness_forge, :workspace_root)
    root = Path.join(File.cwd!(), "tmp/hf-historical-eval-#{Ecto.UUID.generate()}")
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

  test "trusted selection persists exact diagnostic identities without model dispatch", %{
    artifact: artifact
  } do
    assert {:ok, result} = Evaluations.run(artifact["digest"], suite: @suite)
    assert result["kind"] == "task"
    assert result["outcome"] == "blocked"
    assert result["reason"] == "model_not_selected"
    assert result["usage_status"] == "not_dispatched"
    refute result["runtime_qualified"]
    assert result["runtime_observed"] == false

    assert Map.take(result, Map.keys(TaskSuite.identities(@suite))) ==
             TaskSuite.identities(@suite)

    assert Repo.get!(Run, result["id"]).result == result
    assert Repo.get!(Run, result["id"]).execution_context == nil
    assert {:ok, ^result} = Evaluations.get(result["id"])
    assert :ok = Evaluations.reconcile()
  end

  test "the finite selector is task-only and duplicate/unknown options fail before persistence",
       %{artifact: artifact} do
    for opts <- [
          [suite: "unknown"],
          [suite: nil],
          [suite: @suite, kind: :static_integrity],
          [suite: @suite, kind: "runtime_smoke"],
          [suite: @suite, suite: "synthetic-go-v1"],
          [suite: @suite, runtime_qualified: true],
          [kind: :task, kind: :task]
        ] do
      assert Evaluations.run(artifact["digest"], opts) == {:error, :invalid_evaluation_options}
    end

    assert {:ok, []} = Evaluations.list_runs()
  end

  test "paired diagnostic observations compare only to the same fixed suite", %{
    artifact: artifact
  } do
    {:ok, first} = Evaluations.run(artifact["digest"], suite: @suite)
    {:ok, second} = Evaluations.run(artifact["digest"], suite: @suite)
    {:ok, synthetic} = Evaluations.run(artifact["digest"])
    assert synthetic["suite_id"] == "synthetic-go-v1"

    assert {:ok, %{"qualified" => false, "sample_count" => 1, "comparable" => true}} =
             Evaluations.compare(first["id"], second["id"])

    assert Evaluations.compare(first["id"], synthetic["id"]) ==
             {:error, :evaluation_identities_differ}
  end

  test "a passed diagnostic cannot approve a release", %{artifact: artifact} do
    {:ok, blocked} = Evaluations.run(artifact["digest"], suite: @suite)
    # Privileged DB mutation tests release denial only. No runtime success is claimed.
    passed =
      Map.merge(blocked, %{
        "outcome" => "passed",
        "cleanup_status" => "complete",
        "runtime_observed" => true,
        "checks" => [%{"id" => "humanize-ftoa158", "outcome" => "passed"}]
      })

    record = Repo.get!(Run, passed["id"])
    Repo.update!(Ecto.Changeset.change(record, result: passed))

    assert Releases.approve(%{
             "artifact_digest" => artifact["digest"],
             "evaluation_id" => passed["id"],
             "scope" => artifact["spec"]["spec"]["scope"],
             "actor" => Workspaces.operator()
           }) == {:error, :qualified_task_evaluation_required}

    assert passed["suite_id"] != artifact["spec"]["spec"]["evaluation"]["suite"]

    assert {:error, _} =
             Validation.check(
               artifact,
               Map.put(passed, "runtime_qualified", true),
               passed["scope"]
             )

    assert {:ok, []} = Releases.list()
  end

  test "task.md-only historical and synthetic identities cannot compare with current prompt-bound runs",
       %{artifact: artifact} do
    for suite <- [TaskSuite.id(), @suite] do
      {:ok, current} = Evaluations.run(artifact["digest"], suite: suite)
      {:ok, previous} = Evaluations.run(artifact["digest"], suite: suite)
      fixtures = Enum.map(TaskSuite.tasks(suite), &TaskSuite.fixture(suite, &1))

      previous_digest =
        if suite == TaskSuite.id(),
          do: Contracts.digest(Enum.map(fixtures, &Map.take(&1, ~w(id candidate prompt)))),
          else: Contracts.digest(Map.take(hd(fixtures), ~w(id candidate prompt qualification)))

      # Reconstruct the old digest in a privileged stored fixture. This proves
      # comparison/current identity denial and makes no runtime-success claim.
      previous = Map.put(previous, "task_fixture_digest", previous_digest)
      record = Repo.get!(Run, previous["id"])
      Repo.update!(Ecto.Changeset.change(record, result: previous))

      assert TaskSuite.validate_identity(previous) == {:error, :task_suite_identity_changed}

      assert Evaluations.compare(current["id"], previous["id"]) ==
               {:error, :evaluation_identities_differ}

      assert Evaluations.applicability(artifact, previous) == {:error, :evaluation_inapplicable}
    end
  end
end
