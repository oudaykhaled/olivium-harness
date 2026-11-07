defmodule HarnessForge.GraderDiagnosticsIdentityTest do
  use ExUnit.Case, async: true
  alias HarnessForge.Evaluation.TaskSuite

  test "pre-diagnostic grader identities cannot be reused as current results" do
    for {suite, old_grader} <- [
          {"synthetic-go-v1", "c7f8cde3687346fab0c4dd9e58e548e87f5047d2b1c5bd8e945485bc97dcd28e"},
          {"public-humanize-ftoa-158-v1",
           "12fc297b99bae619d5fd19a2655c221972192fd5f291f050121523e9f521cfda"}
        ] do
      current = TaskSuite.identities(suite)
      refute current["grader_digest"] == old_grader

      assert TaskSuite.validate_identity(Map.put(current, "grader_digest", old_grader)) ==
               {:error, :task_suite_identity_changed}
    end

    refute TaskSuite.metadata("public-humanize-ftoa-158-v1")["release_eligible"]
  end
end

defmodule HarnessForge.GraderDiagnosticsDockerTest do
  use ExUnit.Case, async: false
  alias HarnessForge.Evaluation.TaskSuite
  alias HarnessForge.Execution.{Coding, Command}

  @moduletag :docker
  @moduletag timeout: 180_000
  @moduletag skip: System.get_env("HARNESSFORGE_DOCKER_TESTS") != "1"
  @historical "public-humanize-ftoa-158-v1"

  for {suite, task} <- [{"synthetic-go-v1", "clamp"}, {@historical, "humanize-ftoa158"}] do
    @suite suite
    @task task

    test "#{suite} retains compilation failure without inventing executed tests" do
      fixture = TaskSuite.fixture(@suite, @task)
      candidate = compilation_failure(@suite, fixture)
      assert %{exit_status: 41, output: output} = grade(@suite, @task, candidate)
      assert output =~ "[grader_failure stage=protected_tests exit=41]"
      assert output =~ "cannot use"
      assert String.valid?(output)
      refute Enum.any?(events(output), &(&1["Action"] == "run" and is_binary(&1["Test"])))
    end

    test "#{suite} retains actual assertion-failure events from the protected test command" do
      candidate = TaskSuite.fixture(@suite, @task)["candidate"]
      assert %{exit_status: 41, output: output} = grade(@suite, @task, candidate)
      assert output =~ "[grader_failure stage=protected_tests exit=41]"
      assert Enum.any?(events(output), &(&1["Action"] == "run" and is_binary(&1["Test"])))
      assert Enum.any?(events(output), &(&1["Action"] == "fail" and is_binary(&1["Test"])))
      assert {:ok, ^output} = Coding.sanitize_evidence(output, [])
    end

    test "#{suite} success emits only the existing objective probe output" do
      candidate = successful_candidate(@suite, TaskSuite.fixture(@suite, @task))
      assert %{exit_status: 0, output: output} = grade(@suite, @task, candidate)
      assert TaskSuite.check(@suite, @task, output) == :ok
      refute output =~ "[grader_"

      if @suite == "synthetic-go-v1", do: assert(output == "[3,1,5,4,-5]\n")
    end

    test "#{suite} failure logs remain bounded at complete UTF-8 lines" do
      # Execute the exact script's failure helper in the same isolated grader
      # image. This is a formatter fixture, not a candidate or test-pass claim.
      script = formatter_script(@suite, "bounded_fixture", "/protected/failure.log")
      log = "valid UTF-8 follows\n" <> String.duplicate("界🙂\n", 10_000) <> "omitted-tail\n"
      fixture = TaskSuite.fixture(@suite, @task)

      assert %{exit_status: 41, output: output} =
               grade(@suite, @task, fixture["candidate"], script, %{"failure.log" => log})

      assert output =~ "[grader_failure stage=bounded_fixture exit=41]"
      assert output =~ "界🙂\n"
      assert output =~ "[grader_log_truncated: 60000-byte complete-line limit]"
      assert String.ends_with?(output, "[grader_log_end]\n")
      refute output =~ "omitted-tail"
      assert byte_size(output) < 61_000
      assert {:ok, ^output} = Coding.sanitize_evidence(output, [])
    end

    test "#{suite} reports missing failure-log input and preserves its grading exit" do
      fixture = TaskSuite.fixture(@suite, @task)
      script = formatter_script(@suite, "missing_fixture", "/protected/missing.log")

      assert %{exit_status: 41, output: output} = grade(@suite, @task, fixture["candidate"], script)
      assert output =~ "[grader_failure stage=missing_fixture exit=41]"
      assert output =~ "[grader_log_unavailable]"
      assert String.ends_with?(output, "[grader_log_end]\n")
      assert {:ok, ^output} = Coding.sanitize_evidence(output, [])
    end

    test "#{suite} invalid and incomplete UTF-8 logs never discard the entire failure evidence" do
      fixture = TaskSuite.fixture(@suite, @task)
      script = formatter_script(@suite, "encoding_fixture", "/protected/failure.log")

      for log <- [
            "retained-prefix\n" <> <<255>> <> "\nretained-suffix\n",
            "retained-prefix\n" <> <<0xE7, 0x95>>
          ] do
        assert %{exit_status: 41, output: output} =
                 grade(@suite, @task, fixture["candidate"], script, %{"failure.log" => log})

        assert output =~ "[grader_failure stage=encoding_fixture exit=41]"
        assert output =~ "retained-prefix\n"
        assert String.ends_with?(output, "[grader_log_end]\n")
        assert byte_size(output) < 61_000
        assert {:ok, ^output} = Coding.sanitize_evidence(output, [])
      end
    end
  end

  defp formatter_script(suite, stage, logfile) do
    [prefix, _] = String.split(TaskSuite.grader_script(suite), "\ncd /tmp\n", parts: 2)
    prefix <> "\nfail 41 #{stage} #{logfile}\n"
  end

  defp compilation_failure("synthetic-go-v1", fixture),
    do:
      Map.put(
        fixture["candidate"],
        "utility.go",
        "package utility\nfunc Clamp(value, lo, hi int) int { return \"wrong type\" }\n"
      )

  defp compilation_failure(@historical, fixture),
    do:
      Map.update!(fixture["candidate"], "ftoa.go", fn bytes ->
        String.replace(bytes, "return s[:i+digits]", "return 7")
      end)

  defp successful_candidate("synthetic-go-v1", fixture),
    do:
      Map.put(
        fixture["candidate"],
        "utility.go",
        "package utility\nfunc Clamp(value, lo, hi int) int { if value < lo { return lo }; if value > hi { return hi }; return value }\n"
      )

  defp successful_candidate(@historical, fixture),
    do:
      Map.update!(fixture["candidate"], "ftoa.go", fn bytes ->
        String.replace(bytes, "if i+digits >= len(s) {", "if digits >= len(s)-i {")
      end)

  defp events(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, %{"Action" => _} = event} -> [event]
        _ -> []
      end
    end)
  end

  defp grade(suite, task, candidate, script \\ nil, extra_protected \\ %{}) do
    root = Path.join(File.cwd!(), "tmp/hf-grader-diagnostics-#{Ecto.UUID.generate()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    protected = Map.merge(TaskSuite.fixture(suite, task)["protected"], extra_protected)

    for {directory, files} <- [{"candidate", candidate}, {"protected", protected}],
        {name, bytes} <- files do
      path = Path.join([root, directory, name])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, bytes)
    end

    name = "hf-grader-diagnostics-" <> Ecto.UUID.generate()
    on_exit(fn -> Command.docker(["rm", "--force", name]) end)

    assert {:ok, result} =
             Command.docker(
               [
                 "run", "--rm", "--name", name,
                 "--network", "none", "--user", "65534:65534", "--read-only",
                 "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
                 "--pids-limit", "128", "--memory", "1g", "--memory-swap", "1g",
                 "--cpus", "1", "--tmpfs", "/tmp:rw,exec,nosuid,nodev,size=512m,mode=1777",
                 "--env", "HOME=/tmp", "--env", "GOCACHE=/tmp/cache",
                 "--env", "GOPROXY=off", "--env", "GOSUMDB=off",
                 "--env", "GOTOOLCHAIN=local", "--env", "GOFLAGS=-p=1",
                 "--env", "HARNESSFORGE_TASK=#{task}",
                 "--mount", "type=bind,source=#{root}/candidate,target=/candidate,readonly",
                 "--mount", "type=bind,source=#{root}/protected,target=/protected,readonly",
                 "--entrypoint", "/bin/sh", Coding.grader_image(), "-ec",
                 script || TaskSuite.grader_script(suite)
               ],
               90_000,
               65_536
             )

    result
  end
end
