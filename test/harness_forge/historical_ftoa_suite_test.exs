defmodule HarnessForge.HistoricalFtoaSuiteTest do
  use ExUnit.Case, async: true
  alias HarnessForge.Contracts
  alias HarnessForge.Evaluation.{HistoricalFtoaSuite, TaskSuite}
  alias HarnessForge.Execution.Coding

  @suite "public-humanize-ftoa-158-v1"
  @task "humanize-ftoa158"

  test "the original synthetic interface remains the default" do
    assert TaskSuite.id() == "synthetic-go-v1"
    assert TaskSuite.tasks() == ~w(clamp reverse_words)
    assert TaskSuite.tasks(TaskSuite.id()) == TaskSuite.tasks()
    assert TaskSuite.identities(TaskSuite.id()) == TaskSuite.identities()
    assert TaskSuite.grader_script(TaskSuite.id()) == TaskSuite.grader_script()
    assert TaskSuite.fixture(TaskSuite.id(), "clamp") == TaskSuite.fixture("clamp")
    assert TaskSuite.check("clamp", "[3,1,5,4,-5]") == :ok
    assert TaskSuite.check(TaskSuite.id(), "clamp", "[3,1,5,4,-5]") == :ok
    refute TaskSuite.supported?("../../some-repository")
  end

  test "the solver receives only pinned base source, module and licence" do
    fixture = TaskSuite.fixture(@suite, @task)
    assert TaskSuite.tasks(@suite) == [@task]
    assert Map.keys(fixture["candidate"]) |> Enum.sort() == ~w(LICENSE ftoa.go go.mod)

    assert Contracts.sha256(fixture["candidate"]["ftoa.go"]) ==
             "cdee6a24b70dba3b2a6f1600513960aa6ad1b7c8db15466950fb7c184a38e235"

    assert Contracts.sha256(fixture["candidate"]["LICENSE"]) ==
             "a973b4498c13eb74baa2a8e5c351426a6826f2fcdd909916dbe53ee2e755fd71"

    assert Contracts.sha256(fixture["protected"]["ast_guard.go"]) ==
             "d383eaf1030e129d718a32e12565c57bfa525909ceeb7b5ea20c92b0f0964a8e"

    assert fixture["protected"]["base_ftoa.go"] == fixture["candidate"]["ftoa.go"]

    assert Map.keys(fixture["protected"]) |> Enum.sort() ==
             ~w(ast_guard.go base_ftoa.go common_test.go ftoa_precision_test.go ftoa_test.go go.mod pilot_boundaries_test.go probe.go verify_events.go)

    assert TaskSuite.metadata(@suite)["historical_cutoff_verified"] == false
    assert TaskSuite.metadata(@suite)["release_eligible"] == false
    assert TaskSuite.metadata(@suite)["qualification"] == "current_knowledge_diagnostic_replay"
  end

  test "external comparison requires every fixed value, exact test names and a bounded receipt" do
    # This constructs validator inputs only; it is not evidence of executing Go.
    valid =
      Map.put(
        TaskSuite.fixture(@suite, @task)["expected"],
        "test_events_sha256",
        String.duplicate("a", 64)
      )

    assert length(valid["values"]) == 18
    assert TaskSuite.check(@suite, @task, Jason.encode!(valid)) == :ok

    for invalid <- [
          Map.put(valid, "values", List.replace_at(valid["values"], 0, "wrong")),
          Map.put(valid, "tests_run", tl(valid["tests_run"])),
          Map.put(valid, "tests_run", valid["tests_run"] ++ ["ForgedTest"]),
          Map.put(valid, "test_events_sha256", String.duplicate("A", 64)),
          Map.delete(valid, "test_events_sha256"),
          Map.put(valid, "extra", true),
          Map.put(valid, "int_bits", 32)
        ] do
      assert TaskSuite.check(@suite, @task, Jason.encode!(invalid)) ==
               {:error, :objective_checks_failed}
    end

    duplicate = "{\"int_bits\":64," <> String.trim_leading(Jason.encode!(valid), "{")
    assert TaskSuite.check(@suite, @task, duplicate) == {:error, :objective_checks_failed}

    assert TaskSuite.check(@suite, @task, String.duplicate(" ", 65_537)) ==
             {:error, :objective_checks_failed}

    assert TaskSuite.check(@suite, "clamp", Jason.encode!(valid)) ==
             {:error, :objective_checks_failed}
  end

  test "persisted suite bindings reject a switched selector or changed frozen identity" do
    identity = TaskSuite.identities(@suite)
    bound = TaskSuite.bind_context(@suite, %{"test-only-runtime-context" => true})
    # JSON round trip represents persistence; this is not a Docker context fixture.
    reloaded = Jason.decode!(Jason.encode!(bound))
    assert TaskSuite.validate_binding(identity, reloaded) == :ok
    assert TaskSuite.context_suite(TaskSuite.identities(), reloaded) == {:ok, @suite}

    assert TaskSuite.validate_binding(TaskSuite.identities(), reloaded) ==
             {:error, :task_suite_identity_changed}

    assert TaskSuite.validate_binding(identity, %{"test-only-runtime-context" => true}) ==
             {:error, :task_suite_identity_changed}

    assert TaskSuite.context_suite(%{}, %{"legacy-runtime-context" => true}) ==
             {:ok, TaskSuite.id()}

    for field <-
          ~w(suite_digest grader_digest task_fixture_digest qualification release_eligible historical_cutoff_verified) do
      assert TaskSuite.validate_identity(Map.put(identity, field, "changed")) ==
               {:error, :task_suite_identity_changed}
    end

    assert TaskSuite.validate_identity(Map.put(identity, "suite_id", "unknown")) ==
             {:error, :task_suite_identity_changed}
  end

  test "candidate validation rejects immutable changes, extra files and links" do
    root =
      Path.join(System.tmp_dir!(), "hf-historical-files-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    candidate = HistoricalFtoaSuite.fixture(@task)["candidate"]
    for {name, bytes} <- candidate, do: File.write!(Path.join(root, name), bytes)
    assert Coding.validate_candidate(root, @suite, @task, nil) == :ok

    for name <- ~w(go.mod LICENSE) do
      File.write!(Path.join(root, name), "changed")

      assert Coding.validate_candidate(root, @suite, @task, nil) ==
               {:error, :candidate_subset_rejected}

      File.write!(Path.join(root, name), candidate[name])
    end

    File.write!(Path.join(root, "extra.go"), "package humanize")

    assert Coding.validate_candidate(root, @suite, @task, nil) ==
             {:error, :candidate_subset_rejected}

    File.rm!(Path.join(root, "extra.go"))
    File.rename!(Path.join(root, "ftoa.go"), Path.join(root, "target"))
    File.ln_s!("target", Path.join(root, "ftoa.go"))

    assert Coding.validate_candidate(root, @suite, @task, nil) ==
             {:error, :candidate_subset_rejected}
  end

  test "both task prompts read the fixed candidate before exact-text edits and recover from mismatch" do
    for {suite, task, filename} <- [
          {TaskSuite.id(), "clamp", "utility.go"},
          {@suite, @task, "ftoa.go"}
        ] do
      assert {:ok, ["opencode", "run", "--format", "json", "--model", "fixture-model", prompt]} =
               Coding.task_argv(suite, task, %{"model" => "fixture-model"}, nil)

      assert prompt =~ "Read /candidate/#{filename} before editing"
      assert prompt == TaskSuite.prompt(suite, task)
      assert prompt =~ "exact observed text or full function"
      assert prompt =~ "If an edit fails to match, reread the file and correct the edit"
    end
  end

  test "both suite identities bind rendered solver prompts and reject previous task.md-only identities" do
    for suite <- [TaskSuite.id(), @suite] do
      fixtures = Enum.map(TaskSuite.tasks(suite), &TaskSuite.fixture(suite, &1))

      rendered =
        Enum.map(fixtures, &Map.put(&1, "solver_prompt", TaskSuite.prompt(suite, &1["id"])))

      {old_digest, expected_digest} =
        if suite == TaskSuite.id() do
          {Contracts.digest(Enum.map(fixtures, &Map.take(&1, ~w(id candidate prompt)))),
           Contracts.digest(
             Enum.map(rendered, &Map.take(&1, ~w(id candidate prompt solver_prompt)))
           )}
        else
          {Contracts.digest(Map.take(hd(fixtures), ~w(id candidate prompt qualification))),
           Contracts.digest(
             Map.take(hd(rendered), ~w(id candidate prompt qualification solver_prompt))
           )}
        end

      current = TaskSuite.identities(suite)
      assert current["task_fixture_digest"] == expected_digest
      refute current["task_fixture_digest"] == old_digest
      assert TaskSuite.validate_identity(current) == :ok

      assert TaskSuite.validate_identity(Map.put(current, "task_fixture_digest", old_digest)) ==
               {:error, :task_suite_identity_changed}
    end
  end
end
