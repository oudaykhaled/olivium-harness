defmodule HarnessForge.HoldoutSuiteTest do
  use ExUnit.Case, async: true
  alias HarnessForge.Contracts
  alias HarnessForge.Evaluation.{HoldoutSuite, TaskSuite}
  alias HarnessForge.Execution.Coding

  @suites ~w(holdout-go-family-01-v1 holdout-go-family-02-v1)

  test "two fixed single-family selectors keep solver and protected material separate" do
    assert HoldoutSuite.ids() == @suites
    assert Enum.map(@suites, &TaskSuite.tasks/1) == [["h01"], ["h02"]]
    refute TaskSuite.supported?("holdout-go-family-03-v1")
    refute TaskSuite.supported?("../holdout-go-family-01-v1")

    for suite <- @suites do
      [task] = TaskSuite.tasks(suite)
      fixture = TaskSuite.fixture(suite, task)
      assert Enum.sort(Map.keys(fixture["candidate"])) == ~w(go.mod utility.go)

      assert Enum.sort(Map.keys(fixture["protected"])) ==
               ~w(ast_guard.go base_utility.go go.mod main.go utility_test.go verify_events.go)

      assert Contracts.sha256(fixture["candidate"]["utility.go"]) ==
               Contracts.sha256(fixture["protected"]["base_utility.go"])

      refute Map.has_key?(fixture["candidate"], "controls")
      assert TaskSuite.candidate_filename(suite, task) == "utility.go"
      assert TaskSuite.grader_script(suite) == HoldoutSuite.grader_script(suite)
      assert TaskSuite.diagnostic?(suite)
      refute TaskSuite.metadata(suite)["release_eligible"]
      refute TaskSuite.metadata(suite)["historical_cutoff_verified"]
      assert TaskSuite.metadata(suite)["qualification"] == HoldoutSuite.qualification()
      assert TaskSuite.diagnostic_reason(suite) == "finite_prospective_holdout_observations"
      assert Enum.all?(Map.values(fixture["authoring"]["exposure_attestation"]), &(&1 == false))
    end
  end

  test "identities bind the exact rendered prompt and sealed provenance" do
    for suite <- @suites do
      [task] = TaskSuite.tasks(suite)
      fixture = TaskSuite.fixture(suite, task)
      rendered = Map.put(fixture, "solver_prompt", TaskSuite.prompt(suite, task))
      identity = TaskSuite.identities(suite)

      assert identity["task_fixture_digest"] ==
               Contracts.digest(
                 Map.take(
                   rendered,
                   ~w(id candidate prompt solver_prompt qualification authoring sealed_fixture_manifest_digest)
                 )
               )

      refute identity["task_fixture_digest"] ==
               Contracts.digest(Map.take(fixture, ~w(id candidate prompt qualification)))

      assert {:ok, ["opencode", "run", "--format", "json", "--model", "fixture-model", prompt]} =
               Coding.task_argv(suite, task, %{"model" => "fixture-model"}, nil)

      assert Contracts.sha256(prompt) == Contracts.sha256(TaskSuite.prompt(suite, task))
      assert prompt =~ "Read /candidate/utility.go before editing"
      assert prompt =~ "If an edit fails to match, reread the file and correct the edit"
    end

    [first, second] = Enum.map(@suites, &TaskSuite.identities/1)
    refute first["suite_digest"] == second["suite_digest"]
    refute first["task_fixture_digest"] == second["task_fixture_digest"]
  end

  test "persisted family bindings reject switched selectors and every changed identity field" do
    for suite <- @suites do
      identity = TaskSuite.identities(suite)
      context = TaskSuite.bind_context(suite, %{"test-only-runtime-context" => true})
      context = context |> Jason.encode!() |> Jason.decode!()
      assert TaskSuite.validate_binding(identity, context) == :ok
      assert TaskSuite.context_suite(%{}, context) == {:ok, suite}

      assert TaskSuite.validate_binding(identity, %{"test-only-runtime-context" => true}) ==
               {:error, :task_suite_identity_changed}

      for field <- Map.keys(identity) do
        assert TaskSuite.validate_identity(Map.put(identity, field, "changed")) ==
                 {:error, :task_suite_identity_changed}
      end

      for other <- @suites -- [suite] do
        assert TaskSuite.validate_binding(identity, TaskSuite.bind_context(other, %{})) ==
                 {:error, :task_suite_identity_changed}
      end
    end
  end

  test "external checks require exact probes, bounded retained events and actual run/pass identities" do
    # These are validator inputs only. This test does not execute Go or qualify controls.
    for suite <- @suites do
      [task] = TaskSuite.tasks(suite)
      expected = TaskSuite.fixture(suite, task)["expected"]
      events = validator_events(expected)

      valid =
        Map.merge(expected, %{
          "test_events" => events,
          "test_events_sha256" => Contracts.sha256(events)
        })

      assert TaskSuite.check(suite, task, Jason.encode!(valid)) == :ok

      for invalid <- [
            Map.put(valid, "values", []),
            Map.put(valid, "tests_run", []),
            Map.put(valid, "test_events_sha256", String.duplicate("a", 64)),
            Map.put(valid, "extra", true),
            Map.delete(valid, "test_events"),
            with_events(valid, ""),
            with_events(valid, String.duplicate(" ", 49_153)),
            with_events(valid, validator_events(expected, "skip")),
            with_events(valid, validator_events(Map.put(expected, "tests_run", []))),
            with_events(valid, validator_events(Map.put(expected, "package", "other"))),
            with_events(valid, events <> events)
          ] do
        assert TaskSuite.check(suite, task, Jason.encode!(invalid)) ==
                 {:error, :objective_checks_failed}
      end

      duplicate = "{\"format\":\"duplicate\"," <> String.trim_leading(Jason.encode!(valid), "{")
      assert TaskSuite.check(suite, task, duplicate) == {:error, :objective_checks_failed}

      assert TaskSuite.check(suite, task, String.duplicate(" ", 65_537)) ==
               {:error, :objective_checks_failed}

      assert TaskSuite.check(suite, "unknown", Jason.encode!(valid)) ==
               {:error, :objective_checks_failed}
    end
  end

  test "candidate validation preserves the fixed module and rejects extra files and links" do
    for suite <- @suites do
      [task] = TaskSuite.tasks(suite)

      root =
        Path.join(System.tmp_dir!(), "hf-holdout-files-#{System.unique_integer([:positive])}")

      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      candidate = TaskSuite.fixture(suite, task)["candidate"]
      for {name, bytes} <- candidate, do: File.write!(Path.join(root, name), bytes)
      assert Coding.validate_candidate(root, suite, task, nil) == :ok

      File.write!(Path.join(root, "go.mod"), "changed")

      assert Coding.validate_candidate(root, suite, task, nil) ==
               {:error, :candidate_subset_rejected}

      File.write!(Path.join(root, "go.mod"), candidate["go.mod"])
      File.write!(Path.join(root, "extra.go"), "package utility")

      assert Coding.validate_candidate(root, suite, task, nil) ==
               {:error, :candidate_subset_rejected}

      File.rm!(Path.join(root, "extra.go"))
      File.rename!(Path.join(root, "utility.go"), Path.join(root, "target"))
      File.ln_s!("target", Path.join(root, "utility.go"))

      assert Coding.validate_candidate(root, suite, task, nil) ==
               {:error, :candidate_subset_rejected}
    end
  end

  defp validator_events(expected, test_action \\ "pass") do
    tests =
      Enum.flat_map(expected["tests_run"], fn test ->
        [
          %{"Action" => "run", "Package" => expected["package"], "Test" => test},
          %{
            "Action" => test_action,
            "Package" => expected["package"],
            "Test" => test,
            "Elapsed" => 0.001
          }
        ]
      end)

    (tests ++ [%{"Action" => "pass", "Package" => expected["package"]}])
    |> Enum.map_join("\n", &Jason.encode!/1)
    |> Kernel.<>("\n")
  end

  defp with_events(valid, events),
    do:
      Map.merge(valid, %{
        "test_events" => events,
        "test_events_sha256" => Contracts.sha256(events)
      })
end

defmodule HarnessForge.HoldoutEvaluationTest do
  use HarnessForge.DataCase, async: false
  alias HarnessForge.{Decisions, Demo, Evaluations, Evidence, Harnesses, Releases, Workspaces}
  alias HarnessForge.Evaluation.{Run, TaskSuite}
  alias HarnessForge.Releases.Validation

  @suites ~w(holdout-go-family-01-v1 holdout-go-family-02-v1)

  setup do
    previous = Application.fetch_env!(:harness_forge, :workspace_root)
    root = Path.join(File.cwd!(), "tmp/hf-holdout-eval-#{Ecto.UUID.generate()}")
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

  test "both finite families persist independent native identities without inference", %{
    artifact: artifact
  } do
    results =
      Enum.map(@suites, fn suite ->
        assert {:ok, result} = Evaluations.run(artifact["digest"], suite: suite)
        assert result["suite_id"] == suite
        assert result["kind"] == "task"
        assert result["outcome"] == "blocked"
        assert result["reason"] == "model_not_selected"
        assert result["usage_status"] == "not_dispatched"
        refute result["runtime_qualified"]
        refute result["runtime_observed"]

        assert Map.take(result, Map.keys(TaskSuite.identities(suite))) ==
                 TaskSuite.identities(suite)

        assert Repo.get!(Run, result["id"]).execution_context == nil
        result
      end)

    [first, second] = results
    refute first["id"] == second["id"]

    assert Evaluations.compare(first["id"], second["id"]) ==
             {:error, :evaluation_identities_differ}
  end

  test "a privileged diagnostic success fixture cannot qualify either family for release", %{
    artifact: artifact
  } do
    for suite <- @suites do
      {:ok, blocked} = Evaluations.run(artifact["digest"], suite: suite)
      [task] = TaskSuite.tasks(suite)

      passed =
        Map.merge(blocked, %{
          "outcome" => "passed",
          "cleanup_status" => "complete",
          "runtime_observed" => true,
          "checks" => [%{"id" => task, "outcome" => "passed"}]
        })

      record = Repo.get!(Run, passed["id"])
      Repo.update!(Ecto.Changeset.change(record, result: passed))

      assert Releases.approve(%{
               "artifact_digest" => artifact["digest"],
               "evaluation_id" => passed["id"],
               "scope" => artifact["spec"]["spec"]["scope"],
               "actor" => Workspaces.operator()
             }) == {:error, :qualified_task_evaluation_required}

      assert {:error, _} =
               Validation.check(
                 artifact,
                 Map.put(passed, "runtime_qualified", true),
                 passed["scope"]
               )
    end

    assert {:ok, []} = Releases.list()
  end
end
