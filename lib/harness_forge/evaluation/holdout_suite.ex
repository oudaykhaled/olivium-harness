defmodule HarnessForge.Evaluation.HoldoutSuite do
  @moduledoc "Two fixed single-task prospective synthetic diagnostics, without release qualification."
  alias HarnessForge.Contracts
  alias HarnessForge.Evaluation.TaskSuite

  @ids ~w(holdout-go-family-01-v1 holdout-go-family-02-v1)
  @candidate_files ~w(utility.go go.mod)
  @protected_files ~w(ast_guard.go base_utility.go go.mod main.go utility_test.go verify_events.go)
  @controls ~w(alternate compile_failure extra_entrypoint forbidden_effect output_spoof protected_access reference)
  @sealed_paths Enum.sort(
                  ~w(authoring.json task.md grade.sh expected.json) ++
                    Enum.map(@candidate_files, &("candidate/" <> &1)) ++
                    Enum.map(@protected_files, &("protected/" <> &1)) ++
                    Enum.map(@controls, &("controls/" <> &1 <> ".go"))
                )

  def ids, do: @ids
  def tasks("holdout-go-family-01-v1"), do: ["h01"]
  def tasks("holdout-go-family-02-v1"), do: ["h02"]
  def candidate_filename("holdout-go-family-01-v1", "h01"), do: "utility.go"
  def candidate_filename("holdout-go-family-02-v1", "h02"), do: "utility.go"

  def root(suite) when suite in @ids,
    do: Application.app_dir(:harness_forge, "priv/task_suites/" <> suite)

  def grader_script(suite) when suite in @ids, do: read(suite, "grade.sh")
  def qualification, do: "prospective_synthetic_untouched_family_pilot"

  def metadata(suite) when suite in @ids do
    suite
    |> authoring()
    |> Map.take(
      ~w(family_slot family_key authored_at fixture_revision origin protocol_freeze_receipt_sha256 slot_binding_sha256 solver_package_digest protected_grader_digest controls_digest exposure_attestation)
    )
    |> Map.merge(%{
      "qualification" => qualification(),
      "historical_cutoff_verified" => false,
      "release_eligible" => false,
      "candidate_files" => @candidate_files
    })
  end

  def fixture("holdout-go-family-01-v1" = suite, "h01" = task), do: load_fixture(suite, task)
  def fixture("holdout-go-family-02-v1" = suite, "h02" = task), do: load_fixture(suite, task)

  def identities(suite) when suite in @ids do
    [task_id] = tasks(suite)
    task = Map.put(fixture(suite, task_id), "solver_prompt", TaskSuite.prompt(suite, task_id))

    %{
      "suite_id" => suite,
      "suite_digest" => Contracts.digest(%{"id" => suite, "version" => 1, "task" => task}),
      "grader_digest" =>
        Contracts.digest(%{
          "script" => grader_script(suite),
          "protected" => task["protected"],
          "expected" => task["expected"],
          "authoring" => task["authoring"],
          "sealed_fixture_manifest_digest" => task["sealed_fixture_manifest_digest"]
        }),
      "task_fixture_digest" =>
        Contracts.digest(
          Map.take(
            task,
            ~w(id candidate prompt solver_prompt qualification authoring sealed_fixture_manifest_digest)
          )
        )
    }
  end

  def check("holdout-go-family-01-v1" = suite, "h01", output), do: check_output(suite, output)
  def check("holdout-go-family-02-v1" = suite, "h02", output), do: check_output(suite, output)
  def check(_, _, _), do: {:error, :objective_checks_failed}

  defp load_fixture(suite, task) do
    :ok = validate_seal(suite)

    %{
      "id" => task,
      "prompt" => read(suite, "task.md"),
      "candidate" => Map.new(@candidate_files, &{&1, read(suite, "candidate/" <> &1)}),
      "protected" => Map.new(@protected_files, &{&1, read(suite, "protected/" <> &1)}),
      "expected" => expected(suite),
      "qualification" => qualification(),
      "authoring" => authoring(suite),
      "sealed_fixture_manifest_digest" => Contracts.sha256(read(suite, "sealed-manifest.json"))
    }
  end

  defp validate_seal(suite) do
    manifest = read(suite, "sealed-manifest.json") |> Jason.decode!()
    actual = Map.new(@sealed_paths, &{&1, Contracts.sha256(read(suite, &1))})

    if manifest == %{
         "schema_version" => 1,
         "suite_id" => suite,
         "revision" => 1,
         "files" => actual
       } and
         read(suite, "candidate/utility.go") == read(suite, "protected/base_utility.go") and
         read(suite, "candidate/go.mod") == read(suite, "protected/go.mod"),
       do: :ok,
       else: raise(ArgumentError, "holdout fixture seal changed")
  end

  defp check_output(suite, output) when is_binary(output) and byte_size(output) <= 65_536 do
    expected = expected(suite)

    with {:ok, result} when is_map(result) <- Contracts.decode_json(output),
         true <-
           Enum.sort(Map.keys(result)) ==
             Enum.sort(Map.keys(expected) ++ ~w(test_events_sha256 test_events)),
         true <- Map.take(result, Map.keys(expected)) == expected,
         events when is_binary(events) and byte_size(events) in 1..49_152 <- result["test_events"],
         true <- result["test_events_sha256"] == Contracts.sha256(events),
         :ok <- verify_events(events, expected) do
      :ok
    else
      _ -> {:error, :objective_checks_failed}
    end
  end

  defp check_output(_, _), do: {:error, :objective_checks_failed}

  defp verify_events(bytes, expected) do
    lines = String.split(bytes, "\n", trim: true)

    with true <- length(lines) in 1..128,
         {:ok, events} <- decode_events(lines),
         true <- Enum.all?(events, &allowed_event?(&1, expected)),
         true <- Enum.count(events, &(&1["Test"] in [nil, ""] and &1["Action"] == "pass")) == 1,
         true <-
           Enum.all?(expected["tests_run"], fn test ->
             Enum.count(events, &(&1["Test"] == test and &1["Action"] == "run")) == 1 and
               Enum.count(events, &(&1["Test"] == test and &1["Action"] == "pass")) == 1
           end) do
      :ok
    else
      _ -> {:error, :objective_checks_failed}
    end
  end

  defp decode_events(lines) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
      case Jason.decode(line, objects: :ordered_objects) do
        {:ok, %Jason.OrderedObject{values: pairs}} ->
          keys = Enum.map(pairs, &elem(&1, 0))

          if length(keys) == length(Enum.uniq(keys)) and
               keys -- ~w(Time Action Package Test Elapsed Output) == [],
             do: {:cont, {:ok, [Map.new(pairs) | acc]}},
             else: {:halt, :error}

        _ ->
          {:halt, :error}
      end
    end)
  end

  defp allowed_event?(event, expected) do
    event["Package"] == expected["package"] and
      if event["Test"] in [nil, ""],
        do: event["Action"] in ~w(start output pass),
        else: event["Test"] in expected["tests_run"] and event["Action"] in ~w(run output pass)
  end

  defp authoring(suite), do: read(suite, "authoring.json") |> Jason.decode!()
  defp expected(suite), do: read(suite, "expected.json") |> Jason.decode!()
  defp read(suite, path), do: File.read!(Path.join(root(suite), path))
end
