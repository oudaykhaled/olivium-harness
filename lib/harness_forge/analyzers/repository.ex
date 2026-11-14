defmodule HarnessForge.Analyzers.Repository do
  @moduledoc """
  Deterministic, model-free analysis of a local repository into a signals document.

  The analysis lists files through `git ls-files`, or a bounded walk for a plain
  directory, reads a capped allow-list of manifest, CI and instruction files as text,
  counts practices in a separate bounded read of source files and maintainer documents
  (`Practices`), and mines `git log`. Repository contents are data: nothing from the
  repository is executed, and no value in it changes what the analysis runs.
  """

  alias HarnessForge.Analyzers.{
    Commands,
    Git,
    History,
    Instructions,
    Inventory,
    Practices,
    Privacy,
    Signal,
    Stack
  }

  alias HarnessForge.Contracts.{Error, Signals}

  @version "1"

  @spec analyze(Path.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def analyze(path, opts \\ [])

  def analyze(path, opts) when is_binary(path) and is_list(opts) do
    with {:ok, root} <- Git.real_directory(path) do
      availability = Git.availability(root)
      repo = open(root, availability)

      inventory = Inventory.build(root, repo, Keyword.take(opts, [:max_files, :timeout_ms]))

      to_read =
        Stack.paths_to_read(inventory.files) ++
          Instructions.paths(inventory.files) ++ Commands.interpreter_paths(inventory.files)

      {contents, read_counters} = Inventory.load(inventory, to_read)
      {practices, practices_state} = Practices.analyze(inventory, contents)
      history_input = if repo, do: {:ok, repo}, else: {:unavailable, availability["reason"]}

      {history, history_state} =
        History.analyze(
          history_input,
          [files: inventory.files] ++ Keyword.take(opts, [:max_commits])
        )

      file_set = MapSet.new(inventory.files)
      documents = Instructions.documents(contents)

      signals =
        Stack.analyze(inventory.files, contents) ++
          Commands.detect(file_set, contents, documents) ++
          [ci_runs(contents)] ++
          Instructions.analyze(contents, inventory.files) ++
          practices ++
          history

      {signals, redactions} = Privacy.scrub(signals)

      privacy = privacy_signal(inventory, read_counters, redactions)

      Signals.validate(%{
        "version" => Signals.version(),
        "repository" => %{
          "identity" => identity(root),
          "head" => head(repo),
          "git" => availability["status"],
          "git_reason" => availability["reason"]
        },
        "detectors" => detectors(inventory, read_counters, history_state, practices_state),
        "signals" => signals ++ [privacy],
        "aggregates" => %{
          "listed_files" => length(inventory.files),
          "source" => inventory.source,
          "opened_files" => map_size(contents)
        }
      })
    end
  end

  def analyze(_, _),
    do:
      {:error,
       %Error{code: "invalid_repository_path", message: "Expected a repository directory path"}}

  defp open(root, %{"status" => "available"}) do
    case Git.open(root) do
      {:ok, repo} -> repo
      _ -> nil
    end
  end

  defp open(_root, _availability), do: nil

  defp head(nil), do: nil

  defp head(repo) do
    case Git.head(repo) do
      {:ok, value} -> value
      _ -> nil
    end
  end

  defp identity(root) do
    root
    |> Path.basename()
    |> String.replace(~r/[\x00-\x1f\x7f]/, "_")
    |> String.slice(0, 256)
    |> case do
      "" -> "repository"
      name -> name
    end
  end

  defp ci_runs(contents) do
    runs = Commands.ci_runs(contents)
    confidence = if runs == [], do: 0, else: 95
    Signal.new("ci.runs", %{"runs" => Enum.take(runs, 60)}, confidence, "stack.commands")
  end

  defp privacy_signal(inventory, counters, redactions) do
    value = %{
      "secret_paths_skipped" => length(inventory.secret_paths),
      "secret_paths" => inventory.secret_paths |> Enum.take(20),
      "oversize_files" => counters["oversize"],
      "binary_files" => counters["binary"],
      "unreadable_files" => counters["unreadable"],
      "redactions" => redactions
    }

    Signal.new("privacy.report", value, 100, "privacy")
  end

  defp detectors(inventory, counters, history_state, practices_state) do
    entries = [
      {"stack", counters["over_limit"] == 0 and not inventory.truncated, inventory.truncated},
      {"stack.commands", counters["over_limit"] == 0, counters["over_limit"] > 0},
      {"instructions", true, false},
      {"practices", practices_state.complete, practices_state.truncated},
      {"privacy", true, false},
      {"git.history", history_state.complete, history_state.truncated}
    ]

    for {name, complete, truncated} <- entries do
      %{"name" => name, "version" => @version, "complete" => complete, "truncated" => truncated}
    end
  end
end
