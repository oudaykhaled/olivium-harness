defmodule HarnessForge.Evaluation.TaskSuite do
  @moduledoc "Versioned synthetic Go fixtures with independent, evaluator-owned objective expectations."
  alias HarnessForge.Contracts

  @id "synthetic-go-v1"
  @tasks ["clamp", "reverse_words"]
  @grader_script """
  set -eu
  cd /tmp
  go build -o /tmp/ast-guard /protected/ast_guard.go >/tmp/guard-build-log 2>&1 || exit 43
  /tmp/ast-guard /candidate/utility.go "$HARNESSFORGE_TASK"
  mkdir -p /tmp/task/cmd/probe
  cp /candidate/utility.go /tmp/task/utility.go
  cp /protected/go.mod /tmp/task/go.mod
  cp /protected/utility_test.go /tmp/task/utility_test.go
  cp /protected/main.go /tmp/task/cmd/probe/main.go
  cd /tmp/task
  go test -count=1 ./... >/tmp/test-log 2>&1 || exit 41
  go build -o /tmp/probe ./cmd/probe >/tmp/build-log 2>&1 || exit 42
  exec /tmp/probe
  """

  def id, do: @id
  def tasks, do: @tasks
  def grader_script, do: @grader_script
  def root, do: Application.app_dir(:harness_forge, "priv/task_suites/" <> @id)
  def proxy_config, do: File.read!(Path.join(root(), "proxy.conf"))

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
    fixtures = Enum.map(@tasks, &fixture/1)

    %{
      "suite_id" => @id,
      "suite_digest" => Contracts.digest(%{"id" => @id, "version" => 1, "tasks" => fixtures}),
      "grader_digest" =>
        Contracts.digest(%{
          "script" => @grader_script,
          "protected" => Enum.map(fixtures, &Map.take(&1, ~w(id protected expected)))
        }),
      "task_fixture_digest" =>
        Contracts.digest(Enum.map(fixtures, &Map.take(&1, ~w(id candidate prompt))))
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
