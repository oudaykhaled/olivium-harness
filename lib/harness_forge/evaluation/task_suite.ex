defmodule HarnessForge.Evaluation.TaskSuite do
  @moduledoc "Finite versioned Go suites with independent, evaluator-owned objective expectations."
  alias HarnessForge.Contracts
  alias HarnessForge.Evaluation.{HistoricalFtoaSuite, HoldoutSuite}

  @id "synthetic-go-v1"
  @tasks ["clamp", "reverse_words"]
  @holdouts ~w(holdout-go-family-01-v1 holdout-go-family-02-v1)
  @fixed ["public-humanize-ftoa-158-v1" | @holdouts]
  @grader_script """
  set -eu
  fail() {
    printf '[grader_failure stage=%s exit=%s]\\n' "$2" "$1"
    printf '[grader_log_begin: UTF-8; invalid bytes omitted]\\n'
    if LC_ALL=C awk '
      BEGIN { remaining = 60000 }
      {
        size = length($0) + 1
        if (size > remaining) {
          print "[grader_log_truncated: 60000-byte complete-line limit]"
          exit
        }
        print
        remaining -= size
      }
    ' "$3" >/tmp/grader-failure-bounded.log 2>/dev/null &&
      iconv -f UTF-8 -t UTF-8 -c /tmp/grader-failure-bounded.log 2>/dev/null; then
      :
    else
      printf '\\n[grader_log_unavailable]\\n'
    fi
    printf '[grader_log_end]\\n'
    exit "$1"
  }
  cd /tmp
  go build -o /tmp/ast-guard /protected/ast_guard.go >/tmp/guard-build-log 2>&1 || fail 43 ast_guard_build /tmp/guard-build-log
  /tmp/ast-guard /candidate/utility.go "$HARNESSFORGE_TASK"
  mkdir -p /tmp/task/cmd/probe
  cp /candidate/utility.go /tmp/task/utility.go
  cp /protected/go.mod /tmp/task/go.mod
  cp /protected/utility_test.go /tmp/task/utility_test.go
  cp /protected/main.go /tmp/task/cmd/probe/main.go
  cd /tmp/task
  go test -json -count=1 ./... >/tmp/test-log 2>&1 || fail 41 protected_tests /tmp/test-log
  go build -o /tmp/probe ./cmd/probe >/tmp/build-log 2>&1 || fail 42 probe_build /tmp/build-log
  exec /tmp/probe
  """

  def id, do: @id
  def tasks, do: @tasks
  def grader_script, do: @grader_script
  def root, do: Application.app_dir(:harness_forge, "priv/task_suites/" <> @id)
  def proxy_config, do: File.read!(Path.join(root(), "proxy.conf"))

  # Compile-time finite dispatch only. A caller string never becomes a module,
  # path, task basename, image or executable.
  def supported?(suite), do: suite in [@id | @fixed]
  def tasks(@id), do: tasks()
  def tasks("public-humanize-ftoa-158-v1"), do: HistoricalFtoaSuite.tasks()
  def tasks(suite) when suite in @holdouts, do: HoldoutSuite.tasks(suite)
  def fixture(@id, task), do: fixture(task)
  def fixture("public-humanize-ftoa-158-v1", task), do: HistoricalFtoaSuite.fixture(task)
  def fixture(suite, task) when suite in @holdouts, do: HoldoutSuite.fixture(suite, task)
  def grader_script(@id), do: grader_script()
  def grader_script("public-humanize-ftoa-158-v1"), do: HistoricalFtoaSuite.grader_script()
  def grader_script(suite) when suite in @holdouts, do: HoldoutSuite.grader_script(suite)
  def candidate_filename(@id, task) when task in @tasks, do: "utility.go"

  def candidate_filename("public-humanize-ftoa-158-v1", task),
    do: HistoricalFtoaSuite.candidate_filename(task)

  def candidate_filename(suite, task) when suite in @holdouts,
    do: HoldoutSuite.candidate_filename(suite, task)

  def metadata(@id), do: %{}
  def metadata("public-humanize-ftoa-158-v1"), do: HistoricalFtoaSuite.metadata()
  def metadata(suite) when suite in @holdouts, do: HoldoutSuite.metadata(suite)
  def diagnostic?(suite), do: suite in @fixed

  def diagnostic_reason("public-humanize-ftoa-158-v1"),
    do: "finite_public_pr_diagnostic_observations"

  def diagnostic_reason(suite) when suite in @holdouts,
    do: "finite_prospective_holdout_observations"

  def diagnostic_reason(_), do: nil

  @doc "Exact solver prompt shared by dispatch and the frozen suite identities."
  def prompt(suite, task) do
    filename = candidate_filename(suite, task)

    fixture(suite, task)["prompt"] <>
      "\nRead /candidate/" <>
      filename <>
      " before editing. Edit only that file, using the exact observed text or full function. " <>
      "If an edit fails to match, reread the file and correct the edit. Protected tests are evaluator-owned. Report your change briefly."
  end

  def bind_context(@id, context), do: context

  def bind_context(suite, context) when suite in @fixed,
    do: %{
      "version" => "fixed-task-suite-context-v1",
      "suite_id" => suite,
      "runtime_context" => context
    }

  # Older synthetic records predate the selector. Only an absent/default ID
  # may use their existing context; every fixed diagnostic needs its explicit bind.
  def context_suite(
        _result,
        %{"version" => "fixed-task-suite-context-v1", "suite_id" => suite} =
          context
      )
      when suite in @fixed and map_size(context) == 3 do
    if Map.has_key?(context, "runtime_context"),
      do: {:ok, suite},
      else: {:error, :task_suite_identity_changed}
  end

  def context_suite(result, context) when is_map(context) do
    if not Map.has_key?(context, "runtime_context") and
         (not Map.has_key?(result, "suite_id") or result["suite_id"] == @id),
       do: {:ok, @id},
       else: {:error, :task_suite_identity_changed}
  end

  def context_suite(_, _), do: {:error, :task_suite_identity_changed}
  def identities(@id), do: identities()

  def identities("public-humanize-ftoa-158-v1"),
    do: Map.merge(HistoricalFtoaSuite.identities(), HistoricalFtoaSuite.metadata())

  def identities(suite) when suite in @holdouts,
    do: Map.merge(HoldoutSuite.identities(suite), HoldoutSuite.metadata(suite))

  @doc "Reject changed or unknown persisted suite identities before dispatch."
  def validate_identity(%{"suite_id" => suite} = result) do
    if supported?(suite) do
      expected = identities(suite)

      if Map.take(result, Map.keys(expected)) == expected,
        do: :ok,
        else: {:error, :task_suite_identity_changed}
    else
      {:error, :task_suite_identity_changed}
    end
  rescue
    _ -> {:error, :task_suite_identity_changed}
  end

  def validate_identity(_), do: {:error, :task_suite_identity_changed}

  def validate_binding(result, context) do
    with {:ok, suite} <- context_suite(result, context),
         true <- result["suite_id"] == suite,
         :ok <- validate_identity(result),
         do: :ok,
         else: (_ -> {:error, :task_suite_identity_changed})
  end

  def check(@id, task, output), do: check(task, output)

  def check("public-humanize-ftoa-158-v1", task, output),
    do: HistoricalFtoaSuite.check(task, output)

  def check(suite, task, output) when suite in @holdouts,
    do: HoldoutSuite.check(suite, task, output)

  def check(_, _, _), do: {:error, :objective_checks_failed}

  def fixture(task) when task in @tasks do
    %{
      "id" => task,
      "prompt" => read(task, "task.md"),
      "candidate" => %{
        "utility.go" => read(task, "candidate/utility.go"),
        "go.mod" => read(task, "candidate/go.mod")
      },
      "protected" => %{
        "utility_test.go" => read(task, "protected/utility_test.go"),
        "main.go" => read(task, "protected/main.go"),
        "ast_guard.go" => File.read!(Path.join(root(), "ast_guard.go")),
        "go.mod" => read(task, "candidate/go.mod")
      },
      "expected" => expected(task)
    }
  end

  def identities do
    fixtures = Enum.map(@tasks, &Map.put(fixture(&1), "solver_prompt", prompt(@id, &1)))

    %{
      "suite_id" => @id,
      "suite_digest" => Contracts.digest(%{"id" => @id, "version" => 1, "tasks" => fixtures}),
      "grader_digest" =>
        Contracts.digest(%{
          "script" => @grader_script,
          "protected" => Enum.map(fixtures, &Map.take(&1, ~w(id protected expected)))
        }),
      "task_fixture_digest" =>
        Contracts.digest(Enum.map(fixtures, &Map.take(&1, ~w(id candidate prompt solver_prompt))))
    }
  end

  @doc "The evaluator compares values outside the process executing candidate code. Exit zero alone never passes."
  def check(task, output) when task in @tasks and is_binary(output) do
    with {:ok, values} <- Jason.decode(output), true <- values == expected(task) do
      :ok
    else
      _ -> {:error, :objective_checks_failed}
    end
  end

  def check(_, _), do: {:error, :objective_checks_failed}
  defp expected("clamp"), do: [3, 1, 5, 4, -5]
  defp expected("reverse_words"), do: ["", "", "hello", "world hello", "c b a", "世界 مرحبا"]
  defp read(task, path), do: File.read!(Path.join([root(), task, path]))
end
