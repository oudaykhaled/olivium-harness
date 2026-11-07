defmodule HarnessForge.Evaluation.HistoricalFtoaSuite do
  @moduledoc "One fixed public PR-derived diagnostic task; no historical-unseen or promotion qualification."
  alias HarnessForge.Contracts
  alias HarnessForge.Evaluation.TaskSuite

  @id "public-humanize-ftoa-158-v1"
  @task "humanize-ftoa158"
  @base "4d1d9082551ec085912e7d2253a33ae547fca000"
  @reference "3efc00fa9feb0465f8d84e0e70b01a497da9734c"

  def id, do: @id
  def tasks, do: [@task]
  def candidate_filename(@task), do: "ftoa.go"
  def root, do: Application.app_dir(:harness_forge, "priv/task_suites/" <> @id)
  def grader_script, do: read("grade.sh")
  def qualification, do: "current_knowledge_diagnostic_replay"

  def metadata do
    %{
      "qualification" => qualification(),
      "historical_cutoff_verified" => false,
      "release_eligible" => false,
      "candidate_files" => ~w(ftoa.go go.mod LICENSE),
      "upstream_repository" => "https://github.com/dustin/go-humanize",
      "upstream_pull_request" => "https://github.com/dustin/go-humanize/pull/158",
      "base_commit" => @base,
      "reference_commit" => @reference
    }
  end

  def fixture(@task) do
    %{
      "id" => @task,
      "prompt" => read("task.md"),
      "candidate" => Map.new(~w(ftoa.go go.mod LICENSE), &{&1, read("candidate/" <> &1)}),
      "protected" =>
        Map.new(
          ~w(ast_guard.go verify_events.go base_ftoa.go ftoa_test.go common_test.go ftoa_precision_test.go pilot_boundaries_test.go probe.go go.mod),
          &{&1, read("protected/" <> &1)}
        ),
      "expected" => expected(),
      "qualification" => qualification()
    }
  end

  def identities do
    task = Map.put(fixture(@task), "solver_prompt", TaskSuite.prompt(@id, @task))

    %{
      "suite_id" => @id,
      "suite_digest" =>
        Contracts.digest(%{
          "id" => @id,
          "version" => 1,
          "task" => task,
          "base_commit" => @base,
          "reference_commit" => @reference,
          "track" => qualification(),
          "historical_cutoff_verified" => false
        }),
      "grader_digest" =>
        Contracts.digest(%{
          "script" => grader_script(),
          "protected" => task["protected"],
          "expected" => task["expected"]
        }),
      "task_fixture_digest" =>
        Contracts.digest(Map.take(task, ~w(id candidate prompt qualification solver_prompt)))
    }
  end

  def check(@task, output) when is_binary(output) and byte_size(output) <= 65_536 do
    expected = expected()

    with {:ok, result} when is_map(result) <- Contracts.decode_json(output),
         true <-
           Enum.sort(Map.keys(result)) == Enum.sort(Map.keys(expected) ++ ["test_events_sha256"]),
         true <- Map.take(result, Map.keys(expected)) == expected,
         digest when is_binary(digest) <- result["test_events_sha256"],
         true <- Regex.match?(~r/\A[a-f0-9]{64}\z/, digest) do
      :ok
    else
      _ -> {:error, :objective_checks_failed}
    end
  end

  def check(_, _), do: {:error, :objective_checks_failed}
  defp expected, do: read("expected.json") |> Jason.decode!()
  defp read(path), do: File.read!(Path.join(root(), path))
end
