defmodule HarnessForge.Privacy do
  @moduledoc """
  Explicit logical content removal and credential-free consistent local backups.

  Source purge requires the exact source ID; workspace content purge requires
  the exact active workspace ID. Neither operation promises physical erasure,
  deletes provider copies, or removes exports/backups outside the workspace.
  Purges are durable and retryable; incomplete operations fence workflows.
  Backups contain sensitive evidence and are unencrypted. Restore only writes
  to a fresh directory, creates a new workspace identity, and withdraws prior
  source/model/release authority before the directory can be opened.
  """
  alias HarnessForge.{Repo, Workspaces}
  alias HarnessForge.Privacy.{Files, Purge, Snapshot}

  defdelegate purge_source(source_id, confirmation), to: Purge, as: :source
  defdelegate purge_workspace(confirmation), to: Purge, as: :workspace
  defdelegate backup(fresh_target), to: Snapshot
  defdelegate restore(backup_dir, fresh_target), to: Snapshot
  defdelegate verify_backup(backup_dir), to: Snapshot, as: :verify
  defdelegate ready(), to: Purge
  defdelegate reconcile(), to: Purge

  def inventory do
    with :ok <- Files.directory(Workspaces.root()),
         {:ok, counts} <- counts(),
         {:ok, artifacts} <- file_count("artifacts"),
         {:ok, runs} <- file_count("runs"),
         {:ok, tmp} <- file_count("tmp") do
      {:ok,
       %{
         "workspace_id" => Workspaces.current_id(),
         "records" => counts,
         "files" => %{"artifacts" => artifacts, "runs" => runs, "tmp" => tmp},
         "retention" => "until_explicit_purge",
         "physical_erasure" => false,
         "external_copies_included" => false,
         "backup_encryption" => "operator_managed"
       }}
    end
  rescue
    _ -> {:error, :inventory_failed}
  end

  defp counts do
    tables =
      ~w(source_connections evidence_sources evidence_revisions revision_use_holds revision_use_cleanup evidence_citations evidence_claims claim_decisions workspace_goals company_profiles company_repositories company_projects company_plans company_plan_decisions company_artifact_bindings company_task_rubrics company_assessments setup_sessions audit_events model_settings model_requests model_budgets evaluation_runs command_approvals release_approvals release_channels release_history privacy_operations)

    Enum.reduce_while(tables ++ HarnessForge.Privacy.SetupHistory.tables(), {:ok, %{}}, fn table,
                                                                                           {:ok,
                                                                                            result} ->
      case Repo.query("SELECT count(*) FROM #{table} WHERE workspace_id = ?", [
             Workspaces.current_id()
           ]) do
        {:ok, %{rows: [[count]]}} -> {:cont, {:ok, Map.put(result, table, count)}}
        _ -> {:halt, {:error, :inventory_failed}}
      end
    end)
  end

  defp file_count(name) do
    path = Path.join(Workspaces.root(), name)

    case File.lstat(path) do
      {:error, :enoent} ->
        {:ok, 0}

      {:ok, %{type: :directory}} ->
        with {:ok, files} <- Files.tree(path), do: {:ok, length(files)}

      _ ->
        {:error, :unsafe_path}
    end
  end
end
