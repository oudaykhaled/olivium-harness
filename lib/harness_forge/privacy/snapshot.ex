defmodule HarnessForge.Privacy.Snapshot do
  @moduledoc false
  alias HarnessForge.{Artifacts, Contracts, Repo, Workspaces}
  alias HarnessForge.Privacy.{Files, Purge, SetupHistory}
  alias Exqlite.Sqlite3

  @workspace_tables ~w(source_connections evidence_sources evidence_revisions revision_use_holds revision_use_cleanup evidence_citations evidence_claims workspace_goals company_profiles company_repositories company_projects company_plans company_artifact_bindings company_task_rubrics company_assessments setup_sessions audit_events privacy_operations evaluation_runs)
  @corpus_workspace_tables ~w(corpora passage_sets corpus_members capture_runs passages retrieval_runs company_corpus_bindings dependency_manifests origin_dependencies stage_configs stage_consent_revisions stage_consent_sources graph_partition_controls graph_source_scans graph_runtime_backends graph_worker_sessions graph_episode_bindings graph_derivative_versions graph_manifest_builds graph_manifest_pages graph_consent_certificates graph_observation_events graph_observation_calls stage_operations stage_attempts corpus_requirements)
  @corpus_trigger_tables ~w(revision_use_cleanup passage_sets passages retrieval_runs retrieval_items dependency_manifests origin_dependencies stage_configs stage_consent_sources graph_derivative_versions graph_episode_bindings graph_manifest_builds graph_manifest_pages graph_consent_certificates graph_observation_events graph_observation_calls corpus_requirements)
  @immutable ~w(revision_use_holds evidence_revisions evidence_citations evidence_claims claim_decisions workspace_goals company_plans company_plan_decisions company_artifact_bindings company_task_rubrics company_assessments audit_events release_approvals release_history)

  def backup(target) do
    Purge.synchronize(fn ->
      with :ok <- Purge.ready(),
           :ok <- outside_workspace(target),
           :ok <- Files.fresh(target),
           {:ok, artifacts} <- Artifacts.list() do
        Files.stage(target, fn stage ->
          database = Path.join(stage, "data.sqlite3")

          with :ok <- snapshot_database(database),
               :ok <- File.chmod(database, 0o600),
               {:ok, included} <- write_artifacts(stage, database, artifacts),
               :ok <-
                 Files.write(
                   Path.join(stage, "workspace.json"),
                   Jason.encode!(%{"id" => Workspaces.current_id(), "version" => 1})
                 ),
               {:ok, files} <- file_manifest(stage),
               manifest = %{
                 "format" => "harnessforge-backup-v1",
                 "workspace_id" => Workspaces.current_id(),
                 "created_at" => DateTime.to_iso8601(DateTime.utc_now()),
                 "artifact_digests" => included,
                 "files" => files
               },
               :ok <-
                 Files.write(
                   Path.join(stage, "manifest.json"),
                   Contracts.canonical_json(manifest)
                 ) do
            {:ok,
             %{
               "path" => target,
               "workspace_id" => Workspaces.current_id(),
               "file_count" => length(files),
               "encrypted" => false
             }}
          end
        end)
      end
    end)
  rescue
    _ -> {:error, :backup_failed}
  end

  def restore(backup, target) do
    with :ok <- Files.directory(backup),
         :ok <- outside_workspace(target),
         :ok <- Files.fresh(target),
         {:ok, manifest} <- verify(backup) do
      Files.stage(target, fn stage ->
        with :ok <- copy_manifest(backup, stage, manifest["files"]),
             {:ok, id} <- quarantine(Path.join(stage, "data.sqlite3"), manifest["workspace_id"]),
             :ok <- replace_identity(stage, id),
             :ok <-
               Files.write(
                 Path.join(stage, "restore.json"),
                 Jason.encode!(%{
                   "state" => "quarantined",
                   "new_workspace_id" => id,
                   "source_workspace_id" => manifest["workspace_id"],
                   "requires" => [
                     "reconnect_sources",
                     "review_claims",
                     "configure_models",
                     "reevaluate_releases",
                     "review_task_rubrics",
                     "record_new_assessments"
                   ]
                 })
               ) do
          {:ok,
           %{
             "path" => target,
             "workspace_id" => id,
             "state" => "quarantined",
             "source_revalidation_required" => true,
             "approvals_restored" => false
           }}
        end
      end)
    end
  rescue
    _ -> {:error, :restore_failed}
  end

  def verify(backup) do
    with :ok <- Files.directory(backup),
         {:ok, names} <- Files.tree(backup),
         true <- "manifest.json" in names,
         {:ok, bytes} <- File.read(Path.join(backup, "manifest.json")),
         true <- byte_size(bytes) <= 8_000_000,
         {:ok,
          %{"format" => "harnessforge-backup-v1", "files" => files, "workspace_id" => workspace} =
            manifest} <- Jason.decode(bytes),
         {:ok, _} <- Ecto.UUID.cast(workspace),
         true <- is_list(files) and length(files) <= 20_000,
         true <- Enum.sort(Enum.map(files, & &1["path"])) == names -- ["manifest.json"],
         true <- Enum.any?(files, &(&1["path"] == "data.sqlite3")),
         true <- Enum.any?(files, &(&1["path"] == "workspace.json")),
         :ok <- verify_entries(backup, files),
         :ok <- database_integrity(Path.join(backup, "data.sqlite3")) do
      {:ok, manifest}
    else
      _ -> {:error, :invalid_backup}
    end
  rescue
    _ -> {:error, :invalid_backup}
  end

  defp snapshot_database(target) do
    if Repo.in_transaction?() do
      {:error, :backup_requires_committed_database}
    else
      with_connection(Workspaces.database_path(), fn connection ->
        with :ok <-
               Sqlite3.execute(connection, "PRAGMA busy_timeout=5000; PRAGMA synchronous=FULL;"),
             {:ok, _} <- sql(connection, "VACUUM INTO ?", [target]),
             :ok <- scrub_mcp_backup(target),
             do: database_integrity(target)
      end)
    end
  end

  defp scrub_mcp_backup(path) do
    with_connection(path, fn conn ->
      with :ok <- Sqlite3.execute(conn, "PRAGMA foreign_keys=ON; BEGIN IMMEDIATE;"),
           :ok <- scrub_mcp_authority(conn),
           :ok <- Sqlite3.execute(conn, "COMMIT;") do
        :ok
      else
        _ ->
          Sqlite3.execute(conn, "ROLLBACK;")
          {:error, :backup_failed}
      end
    end)
  end

  # Independent client verifiers and exact disclosure decisions never migrate
  # into another workspace, including from backups made before this scrub.
  defp scrub_mcp_authority(conn) do
    execute!(conn, "PRAGMA secure_delete=ON")

    Enum.each(
      ~w(mcp_disclosure_grant_items mcp_disclosure_grants mcp_clients),
      fn table ->
        if table_exists?(conn, table), do: execute!(conn, "DELETE FROM #{table}")
      end
    )

    :ok
  end

  defp write_artifacts(stage, database, artifacts) do
    with_connection(database, fn conn ->
      with {:ok, rows} <-
             sql(
               conn,
               "SELECT id, revision_hash, citations, basis FROM evidence_claims WHERE workspace_id = ?",
               [
                 Workspaces.current_id()
               ]
             ),
           {:ok, claims} <- copied_claims(conn, rows),
           {:ok, goal_rows} <-
             sql(conn, "SELECT id FROM workspace_goals WHERE workspace_id = ?", [
               Workspaces.current_id()
             ]) do
        goals = List.flatten(goal_rows)

        included =
          Enum.filter(artifacts, fn artifact ->
            spec = get_in(artifact, ["spec", "spec"])

            Enum.all?(spec["rules"], &(claims[&1["id"]] == &1["revision_hash"])) and
              Enum.all?(spec["goals"], &(&1["id"] in goals))
          end)

        Enum.reduce_while(included, {:ok, []}, fn artifact, {:ok, digests} ->
          base = Path.join([stage, "artifacts", artifact["digest"]])

          with :ok <-
                 Files.write(Path.join(base, "artifact.json"), Contracts.canonical_json(artifact)),
               :ok <-
                 Enum.reduce_while(artifact["files"], :ok, fn {path, bytes}, :ok ->
                   case Files.write(Path.join([base, "payload", path]), bytes) do
                     :ok -> {:cont, :ok}
                     error -> {:halt, error}
                   end
                 end) do
            {:cont, {:ok, [artifact["digest"] | digests]}}
          else
            error -> {:halt, error}
          end
        end)
      end
    end)
  end

  # Resolve dependencies from the copied database. Historical provider availability is
  # irrelevant to a backup; every retained origin must refer to copied evidence.
  defp copied_claims(conn, rows) do
    tables = %{
      "revision_ids" => "evidence_revisions",
      "source_ids" => "evidence_sources",
      "goal_ids" => "workspace_goals",
      "project_ids" => "company_projects",
      "profile_ids" => "company_profiles"
    }

    with {:ok, ids} <- copied_ids(conn, tables) do
      claims =
        Enum.reduce(rows, %{}, fn [id, hash, citations, basis], acc ->
          {:ok, citations} = Ecto.Type.adapter_load(Repo.__adapter__(), {:array, :map}, citations)
          {:ok, basis} = Ecto.Type.adapter_load(Repo.__adapter__(), :map, basis)

          dto = %{
            "citations" => citations,
            "basis" => basis
          }

          case HarnessForge.Evidence.Origin.references(dto) do
            {:ok, refs} ->
              if Enum.all?(refs, fn
                   {"manifest_refs", values} ->
                     Enum.all?(values, &copied_manifest?(conn, &1))

                   {key, values} ->
                     is_struct(ids[key], MapSet) and
                       Enum.all?(values, &MapSet.member?(ids[key], &1))
                 end), do: Map.put(acc, id, hash), else: acc

            _ ->
              acc
          end
        end)

      {:ok, claims}
    end
  end

  defp copied_manifest?(conn, %{"id" => id, "digest" => digest}) do
    with true <- table_exists?(conn, "dependency_manifests"),
         {:ok, [[count]]} <-
           sql(
             conn,
             "SELECT source_count FROM dependency_manifests WHERE workspace_id=? AND id=? AND digest=? AND state='sealed'",
             [Workspaces.current_id(), id, digest]
           ),
         {:ok, [[^count, 0]]} <-
           sql(
             conn,
             """
             SELECT count(*),coalesce(sum(CASE WHEN r.id IS NULL OR r.body_hash!=d.content_hash THEN 1 ELSE 0 END),0)
             FROM origin_dependencies d LEFT JOIN evidence_revisions r ON r.workspace_id=d.workspace_id AND r.source_id=d.source_id AND r.id=d.revision_id
             WHERE d.workspace_id=? AND d.manifest_id=? AND d.kind='source_revision'
             """,
             [Workspaces.current_id(), id]
           ) do
      count > 0
    else
      _ -> false
    end
  end

  defp copied_manifest?(_, _), do: false

  defp copied_ids(conn, tables) do
    Enum.reduce_while(tables, {:ok, %{}}, fn {key, table}, {:ok, acc} ->
      case sql(conn, "SELECT id FROM #{table} WHERE workspace_id = ?", [Workspaces.current_id()]) do
        {:ok, rows} -> {:cont, {:ok, Map.put(acc, key, MapSet.new(List.flatten(rows)))}}
        error -> {:halt, error}
      end
    end)
  end

  defp file_manifest(base) do
    with {:ok, files} <- Files.tree(base) do
      {:ok,
       Enum.map(files, fn relative ->
         bytes = File.read!(Path.join(base, relative))
         %{"path" => relative, "sha256" => Contracts.sha256(bytes), "bytes" => byte_size(bytes)}
       end)}
    end
  end

  defp verify_entries(base, entries) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      with true <- is_map(entry) and allowed_file?(entry["path"]),
           :ok <- Files.relative(entry["path"]),
           {:ok, bytes} <- File.read(Path.join(base, entry["path"])),
           true <-
             byte_size(bytes) == entry["bytes"] and Contracts.sha256(bytes) == entry["sha256"] do
        {:cont, :ok}
      else
        _ -> {:halt, {:error, :invalid_backup}}
      end
    end)
  end

  defp allowed_file?(path) when path in ["data.sqlite3", "workspace.json"], do: true

  defp allowed_file?(path) when is_binary(path),
    do:
      Regex.match?(
        ~r/\Aartifacts\/[a-f0-9]{64}\/(artifact\.json|payload\/[A-Za-z0-9_.\/-]+)\z/,
        path
      )

  defp allowed_file?(_), do: false

  defp copy_manifest(source, stage, files) do
    Enum.reduce_while(files, :ok, fn entry, :ok ->
      with {:ok, bytes} <- File.read(Path.join(source, entry["path"])),
           true <- Contracts.sha256(bytes) == entry["sha256"],
           :ok <- Files.write(Path.join(stage, entry["path"]), bytes) do
        {:cont, :ok}
      else
        _ -> {:halt, {:error, :backup_changed}}
      end
    end)
  end

  defp quarantine(path, old_id) do
    with_connection(path, fn conn ->
      id = Ecto.UUID.generate()

      with :ok <- Sqlite3.execute(conn, "PRAGMA foreign_keys=ON; BEGIN IMMEDIATE;"),
           :ok <- alter_quarantine(conn, old_id, id),
           :ok <- Sqlite3.execute(conn, "COMMIT;") do
        {:ok, id}
      else
        _ ->
          Sqlite3.execute(conn, "ROLLBACK;")
          {:error, :restore_quarantine_failed}
      end
    end)
  end

  defp alter_quarantine(conn, old_id, new_id) do
    immutable = Enum.filter(@immutable, &table_exists?(conn, &1))
    execute!(conn, "PRAGMA defer_foreign_keys=ON")
    scrub_mcp_authority(conn)

    corpus_triggers =
      Enum.flat_map(
        @corpus_trigger_tables ++ SetupHistory.tables() ++ ["stage_operations"],
        fn table ->
          {:ok, rows} =
            sql(
              conn,
              "SELECT name,sql FROM sqlite_master WHERE type='trigger' AND tbl_name=? ORDER BY name",
              [table]
            )

          Enum.filter(rows, fn [name, _] ->
            cond do
              table in SetupHistory.tables() ->
                Regex.match?(~r/\A[a-z][a-z0-9_]{0,127}\z/, name)

              table == "stage_operations" ->
                name in ~w(setup_stage_binding_insert setup_stage_binding_update)

              true ->
                Regex.match?(
                  ~r/\A(?:immutable|sealed)_[a-z_]+_(?:insert|update|delete|identity|header)\z/,
                  name
                )
            end
          end)
        end
      )

    Enum.each(corpus_triggers, fn [name, _] -> execute!(conn, "DROP TRIGGER " <> name) end)

    if table_exists?(conn, "stage_attempts"),
      do:
        execute!(
          conn,
          "UPDATE stage_attempts SET model_request_id=NULL,grant_hash=NULL,state='uncertain'"
        )

    if table_exists?(conn, "stage_operations"),
      do:
        execute!(
          conn,
          "UPDATE stage_operations SET state='cancelled',cancel_epoch=cancel_epoch+1,control_token=lower(hex(randomblob(32)))"
        )

    if table_exists?(conn, "graph_observation_events"),
      do:
        execute!(
          conn,
          "UPDATE graph_observation_events SET binding_state='denied' WHERE binding_state='unused'"
        )

    if table_exists?(conn, "graph_observation_calls"),
      do:
        execute!(
          conn,
          "UPDATE graph_observation_calls SET state='denied',call_version=call_version+1 WHERE state='active'"
        )

    if table_exists?(conn, "graph_worker_sessions"),
      do: execute!(conn, "DELETE FROM graph_worker_sessions")

    # Docker resources are not copied. A restored workspace inherits neither
    # credentials nor authority to adopt or delete original resource IDs.
    if table_exists?(conn, "graph_runtime_backends"),
      do:
        execute!(
          conn,
          "DELETE FROM graph_runtime_backends"
        )

    if table_exists?(conn, "stage_consent_revisions"),
      do: execute!(conn, "UPDATE stage_consent_revisions SET state='revoked'")

    if table_exists?(conn, "graph_consent_certificates"),
      do: execute!(conn, "UPDATE graph_consent_certificates SET state='denied'")

    if table_exists?(conn, "corpora"),
      do:
        execute!(
          conn,
          "UPDATE corpora SET state='denied',authorization_generation=authorization_generation+1"
        )

    if table_exists?(conn, "dependency_manifests"),
      do: execute!(conn, "UPDATE dependency_manifests SET state='denied'")

    if table_exists?(conn, "graph_partition_controls"),
      do:
        execute!(
          conn,
          "UPDATE graph_partition_controls SET state='denied',cancel_epoch=cancel_epoch+1"
        )

    if table_exists?(conn, "graph_episode_bindings"),
      do: execute!(conn, "UPDATE graph_episode_bindings SET state='denied'")

    if table_exists?(conn, "graph_derivative_versions"),
      do: execute!(conn, "UPDATE graph_derivative_versions SET state='denied'")

    if table_exists?(conn, "capture_runs"),
      do:
        execute!(
          conn,
          "UPDATE capture_runs SET state='cancelled',lease_token=NULL,lease_until=NULL WHERE state IN('queued','running','paused')"
        )

    Enum.each(immutable, fn table ->
      execute!(conn, "DROP TRIGGER IF EXISTS immutable_#{table}_delete")
      execute!(conn, "DROP TRIGGER IF EXISTS immutable_#{table}_update")
    end)

    Enum.each(
      ~w(command_approvals company_plan_decisions release_history release_channels release_approvals claim_decisions model_settings oban_jobs)
      |> Enum.filter(&table_exists?(conn, &1)),
      fn table ->
        execute!(conn, "DELETE FROM #{table}")
      end
    )

    # Preserve the exact usage history of saved setup runs, while retaining the
    # established removal of unrelated legacy model requests on restore.
    Enum.each(~w(model_requests model_budgets), fn table ->
      if table_exists?(conn, table) do
        live =
          if table_exists?(conn, "model_run_authorizations"),
            do:
              "EXISTS(SELECT 1 FROM model_run_authorizations a WHERE a.workspace_id=#{table}.workspace_id AND a.budget_id=#{table}.run_id)",
            else: "0"

        retired =
          "EXISTS(SELECT 1 FROM audit_events e WHERE e.workspace_id=#{table}.workspace_id AND e.action='setup_budget_retired' AND json_extract(e.details,'$.status')='retired' AND json_extract(e.details,'$.run_id')=#{table}.run_id)"

        execute!(conn, "DELETE FROM #{table} WHERE NOT (#{live} OR #{retired})")
      end
    end)

    execute!(
      conn,
      "UPDATE source_connections SET status = 'revoked', directory = NULL, config = '{}', cursor = NULL, sync_complete = 0, sync_state = 'restored_requires_revalidation'"
    )

    Enum.each(
      Enum.filter(
        @workspace_tables ++
          @corpus_workspace_tables ++ SetupHistory.tables() ++ ~w(model_requests model_budgets),
        &table_exists?(conn, &1)
      ),
      fn table ->
        {:ok, _} =
          sql(conn, "UPDATE #{table} SET workspace_id = ? WHERE workspace_id = ?", [
            new_id,
            old_id
          ])
      end
    )

    if table_exists?(conn, "setup_runs") do
      :ok =
        SetupHistory.quarantine(
          fn statement, parameters -> sql(conn, statement, parameters) end,
          old_id,
          new_id
        )
    end

    {:ok, _} =
      sql(conn, "UPDATE evidence_search SET workspace_id = ? WHERE workspace_id = ?", [
        new_id,
        old_id
      ])

    if table_exists?(conn, "passage_search") do
      {:ok, _} =
        sql(conn, "UPDATE passage_search SET workspace_id=? WHERE workspace_id=?", [
          new_id,
          old_id
        ])
    end

    {:ok, results} = sql(conn, "SELECT id, result FROM evaluation_runs", [])

    # A restored workspace has a new identity and cannot act on the original
    # daemon. Pre-context backups remain restorable before startup migrations.
    if column_exists?(conn, "evaluation_runs", "execution_context") do
      execute!(conn, "UPDATE evaluation_runs SET execution_context = NULL")
    end

    Enum.each(results, fn [id, result] ->
      value =
        Jason.decode!(result)
        |> Map.merge(%{
          "workspace_id" => new_id,
          "outcome" => "interrupted",
          "reason" => "restored_requires_reevaluation",
          "runtime_qualified" => false,
          "cleanup_status" => "not_dispatched"
        })

      {:ok, _} =
        sql(conn, "UPDATE evaluation_runs SET result = ? WHERE id = ?", [Jason.encode!(value), id])
    end)

    Enum.each(corpus_triggers, fn [_, ddl] -> execute!(conn, ddl) end)

    Enum.each(immutable, fn table ->
      Enum.each(~w(UPDATE DELETE), fn operation ->
        execute!(
          conn,
          "CREATE TRIGGER immutable_#{table}_#{String.downcase(operation)} BEFORE #{operation} ON #{table} BEGIN SELECT RAISE(ABORT, 'immutable record'); END"
        )
      end)
    end)

    :ok
  end

  defp replace_identity(stage, id) do
    with :ok <- File.rm(Path.join(stage, "workspace.json")),
         do:
           Files.write(
             Path.join(stage, "workspace.json"),
             Jason.encode!(%{"id" => id, "version" => 1})
           )
  end

  defp database_integrity(path) do
    with_connection(path, fn conn ->
      with {:ok, [["ok"]]} <- sql(conn, "PRAGMA integrity_check", []),
           {:ok, []} <- sql(conn, "PRAGMA foreign_key_check", []),
           do: :ok
    end)
  end

  defp table_exists?(conn, table) do
    case sql(conn, "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [table]) do
      {:ok, [[^table]]} -> true
      _ -> false
    end
  end

  defp column_exists?(conn, table, column) do
    case sql(conn, "PRAGMA table_info(#{table})", []) do
      {:ok, columns} -> Enum.any?(columns, &(Enum.at(&1, 1) == column))
      _ -> raise "backup schema inspection failed"
    end
  end

  defp with_connection(path, fun) do
    with {:ok, conn} <- Sqlite3.open(path) do
      try do
        fun.(conn)
      after
        Sqlite3.close(conn)
      end
    end
  end

  defp execute!(conn, sql) do
    case Sqlite3.execute(conn, sql) do
      :ok -> :ok
      _ -> raise "backup database operation failed"
    end
  end

  defp sql(conn, query, params) do
    with {:ok, statement} <- Sqlite3.prepare(conn, query) do
      try do
        with :ok <- Sqlite3.bind(statement, params), do: Sqlite3.fetch_all(conn, statement)
      after
        Sqlite3.release(conn, statement)
      end
    end
  end

  defp outside_workspace(target) do
    with :ok <- Files.absolute(target) do
      if target == Workspaces.root() or String.starts_with?(target, Workspaces.root() <> "/"),
        do: {:error, :target_inside_workspace},
        else: :ok
    end
  end
end
