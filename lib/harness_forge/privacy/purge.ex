defmodule HarnessForge.Privacy.Purge do
  @moduledoc false
  alias HarnessForge.{Artifacts, Evaluations, Repo, Workspaces}
  alias HarnessForge.Evidence.{Claim, Source, Store}
  alias HarnessForge.Privacy.Files

  @immutable ~w(revision_use_holds evidence_revisions evidence_citations evidence_claims claim_decisions workspace_goals company_plans company_plan_decisions company_artifact_bindings company_task_rubrics company_assessments audit_events release_approvals release_history passage_sets passages retrieval_runs retrieval_items dependency_manifests origin_dependencies stage_configs stage_consent_sources graph_derivative_versions graph_manifest_builds graph_manifest_pages graph_consent_certificates graph_observation_events graph_observation_calls corpus_requirements)
  @content_tables ~w(revision_use_cleanup revision_use_holds command_approvals setup_sessions company_assessments company_task_rubrics company_artifact_bindings company_plan_decisions company_plans company_projects company_repositories company_profiles release_history release_channels release_approvals evaluation_runs model_requests model_budgets model_settings claim_decisions evidence_claims evidence_citations evidence_revisions evidence_sources source_connections workspace_goals audit_events)

  def ready do
    case Repo.query(
           "SELECT count(*) FROM privacy_operations WHERE workspace_id = ? AND state != 'completed'",
           [Workspaces.current_id()]
         ) do
      {:ok, %{rows: [[0]]}} -> :ok
      {:ok, _} -> {:error, :privacy_operation_incomplete}
      _ -> {:error, :privacy_state_unavailable}
    end
  end

  def source(id, confirmation) when is_binary(id) and confirmation == id do
    synchronize(fn ->
      with :ok <- no_active_evaluations(),
           {:ok, operation} <- prepare("source", id),
           do: resume(operation)
    end)
  end

  def source(_, _), do: {:error, :confirmation_mismatch}

  def workspace(confirmation) do
    if confirmation == Workspaces.current_id() do
      synchronize(fn ->
        with :ok <- no_active_evaluations(),
             {:ok, operation} <- prepare("workspace", confirmation),
             do: resume(operation)
      end)
    else
      {:error, :confirmation_mismatch}
    end
  end

  def reconcile do
    synchronize(fn ->
      operations =
        rows(
          "SELECT id, kind, target_id, state, plan FROM privacy_operations WHERE workspace_id = ? AND state != 'completed' ORDER BY inserted_at",
          [Workspaces.current_id()]
        )

      Enum.reduce_while(operations, :ok, fn row, :ok ->
        case resume(operation(row)) do
          {:ok, _} -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end)
  rescue
    _ -> {:error, :privacy_recovery_failed}
  end

  defp prepare(kind, target) do
    completed = if kind == "workspace", do: " AND state != 'completed'", else: ""

    case rows(
           "SELECT id, kind, target_id, state, plan FROM privacy_operations WHERE workspace_id = ? AND kind = ? AND target_id = ?" <>
             completed <> " ORDER BY inserted_at DESC LIMIT 1",
           [Workspaces.current_id(), kind, target]
         ) do
      [row] ->
        {:ok, operation(row)}

      [] ->
        with :ok <- ready(),
             {:ok, plan} <- plan(kind, target) do
          Store.transaction(fn ->
            # Fence source import before committing the durable purge intent.
            if kind == "source" do
              query!(
                "UPDATE source_connections SET status = 'revoked', directory = NULL, config = '{}', cursor = NULL WHERE workspace_id = ? AND id = ?",
                [Workspaces.current_id(), plan["connection_id"]]
              )
            else
              query!(
                "UPDATE source_connections SET status = 'revoked', directory = NULL, config = '{}', cursor = NULL WHERE workspace_id = ?",
                [Workspaces.current_id()]
              )
            end

            # A build can publish between the preflight and this write fence.
            # Recompute lineage only after source revocation has serialized
            # against its in-transaction freshness check.
            with {:ok, checked_plan} <- plan(kind, target) do
              id = Ecto.UUID.generate()
              now = DateTime.to_iso8601(DateTime.utc_now())

              operation = %{
                id: id,
                kind: kind,
                target: target,
                state: "prepared",
                plan: checked_plan
              }

              cancel_queued(operation)

              query!(
                "INSERT INTO privacy_operations (id, workspace_id, kind, target_id, state, plan, inserted_at, updated_at) VALUES (?, ?, ?, ?, 'prepared', ?, ?, ?)",
                [id, Workspaces.current_id(), kind, target, Jason.encode!(checked_plan), now, now]
              )

              {:ok, operation}
            end
          end)
        end
    end
  rescue
    _ -> {:error, :purge_preparation_failed}
  end

  defp plan("workspace", _) do
    with :ok <- Files.directory(Workspaces.root()),
         :ok <- validate_trees(~w(artifacts runs tmp)) do
      {:ok, %{"files" => ~w(artifacts runs tmp)}}
    end
  end

  defp plan("source", id) do
    with {:ok, source} <- Store.get(Source, id),
         :ok <- no_unattributed_stages(),
         {:ok, artifacts} <- Artifacts.list() do
      revisions =
        rows("SELECT id FROM evidence_revisions WHERE workspace_id = ? AND source_id = ?", [
          Workspaces.current_id(),
          id
        ])
        |> List.flatten()

      claims = Repo.all(Store.scoped(Claim))

      with {:ok, families} <- affected_families(claims, id, revisions) do
        affected_claims = claims |> Enum.filter(&(&1.family_id in families)) |> Enum.map(& &1.id)
        company = HarnessForge.Privacy.Company.dependencies(id, affected_claims)

        digests =
          artifacts
          |> Enum.filter(&dependent?(&1, revisions, affected_claims))
          |> Enum.map(& &1["digest"])
          |> Kernel.++(company["artifact_digests"])
          |> Enum.uniq()

        runs =
          rows("SELECT id, artifact_digest FROM evaluation_runs WHERE workspace_id = ?", [
            Workspaces.current_id()
          ])
          |> Enum.filter(fn [_, digest] -> digest in digests end)
          |> Enum.map(&hd/1)

        with {:ok, run_files} <- run_files(runs),
             files = Enum.map(digests, &Path.join("artifacts", &1)) ++ run_files,
             :ok <- validate_trees(files) do
          {:ok,
           %{
             "connection_id" => source.connection_id,
             "revision_ids" => revisions,
             "claim_ids" => affected_claims,
             "artifact_digests" => digests,
             "run_ids" => runs,
             "company" => company,
             "files" => files
           }}
        end
      end
    end
  end

  defp affected_families(claims, source_id, revisions) do
    Enum.reduce_while(claims, {:ok, []}, fn claim, {:ok, families} ->
      case HarnessForge.Evidence.Origin.references(Store.dto(claim)) do
        {:ok, refs} ->
          affected? =
            source_id in refs["source_ids"] or
              Enum.any?(refs["revision_ids"], &(&1 in revisions)) or
              Enum.any?(
                Map.get(refs, "manifest_refs", []),
                &HarnessForge.Evidence.OriginV2.contains_source?(&1["id"], source_id)
              )

          {:cont, {:ok, if(affected?, do: [claim.family_id | families], else: families)}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  defp run_files(ids) do
    if Enum.all?(ids, &(is_binary(&1) and match?({:ok, _}, Ecto.UUID.cast(&1)))) do
      {:ok, Enum.flat_map(ids, &[Path.join("runs", &1), Path.join("runs", "coding-" <> &1)])}
    else
      {:error, :invalid_run_identity}
    end
  end

  defp no_unattributed_stages do
    case File.ls(Path.join(Workspaces.root(), "artifacts")) do
      {:ok, entries} ->
        if Enum.any?(entries, &String.starts_with?(&1, ".stage-")),
          do: {:error, :unattributed_artifact_stage},
          else: :ok

      {:error, :enoent} ->
        :ok

      _ ->
        {:error, :unsafe_path}
    end
  end

  defp dependent?(artifact, revisions, claims) do
    artifact
    |> get_in(["spec", "spec", "rules"])
    |> Enum.any?(fn rule ->
      rule["id"] in claims or Enum.any?(rule["evidence"], &(&1["revision_id"] in revisions))
    end)
  end

  defp validate_trees(paths) do
    Enum.reduce_while(paths, :ok, fn relative, :ok ->
      path = Path.join(Workspaces.root(), relative)

      case File.lstat(path) do
        {:error, :enoent} ->
          {:cont, :ok}

        {:ok, %{type: :directory}} ->
          case Files.tree(path) do
            {:ok, _} -> {:cont, :ok}
            error -> {:halt, error}
          end

        _ ->
          {:halt, {:error, :unsafe_path}}
      end
    end)
  end

  defp resume(%{state: "completed"} = op), do: {:ok, result(op)}

  defp resume(op) do
    with :ok <- cleanup(op),
         {:ok, op} <- database(op),
         :ok <- remove_files(op),
         {:ok, :completed} <- complete(op) do
      {:ok, result(%{op | state: "completed"})}
    else
      {:error, reason} = error ->
        query!(
          "UPDATE privacy_operations SET error = ?, updated_at = ? WHERE id = ? AND workspace_id = ?",
          [
            safe_reason(reason),
            DateTime.to_iso8601(DateTime.utc_now()),
            op.id,
            Workspaces.current_id()
          ]
        )

        error
    end
  rescue
    _ ->
      state_error(op.id, "purge_failed")
      {:error, :purge_failed}
  end

  defp cleanup(op) do
    with :ok <- no_active_evaluations(),
         :ok <- no_executing_jobs(op) do
      # Stored authority outlives the database/file phases. Never sweep today's
      # default daemon or unrelated runs to prove this operation's cleanup.
      scope = if op.kind == "workspace", do: :all, else: {:ids, op.plan["run_ids"]}
      Evaluations.cleanup_runs(scope)
    end
  end

  defp no_executing_jobs(op) do
    jobs = rows("SELECT args FROM oban_jobs WHERE state = 'executing'", [])

    if Enum.any?(jobs, fn [args] ->
         args = decode(args)

         related_job?(args, op)
       end), do: {:error, :jobs_still_executing}, else: :ok
  end

  # A selective purge must not reconcile away an unrelated active evaluation.
  defp no_active_evaluations do
    case Repo.query(
           "SELECT count(*) FROM evaluation_runs WHERE workspace_id = ? AND json_extract(result, '$.outcome') IN ('running', 'pending')",
           [Workspaces.current_id()]
         ) do
      {:ok, %{rows: [[0]]}} -> :ok
      {:ok, _} -> {:error, :evaluations_still_running}
      _ -> {:error, :evaluation_state_unavailable}
    end
  end

  defp database(%{state: "database_purged"} = op), do: {:ok, op}

  defp database(op) do
    Store.transaction(fn ->
      delete_triggers =
        Enum.flat_map(@immutable, fn table ->
          rows("SELECT name,sql FROM sqlite_master WHERE type='trigger' AND name=?", [
            "immutable_#{table}_delete"
          ])
        end)

      Enum.each(delete_triggers, fn [name, _] -> query!("DROP TRIGGER " <> name, []) end)
      query!("PRAGMA secure_delete = ON", [])
      query!("PRAGMA defer_foreign_keys = ON", [])
      :ok = HarnessForge.Privacy.SetupHistory.purge(op.kind)
      purge_corpus_rows(op)

      if op.kind == "workspace" do
        query!("DELETE FROM evidence_search WHERE workspace_id = ?", [Workspaces.current_id()])
        # Delete self-referencing claims in leaf-first order.
        Enum.each(@content_tables, fn
          "company_assessments" ->
            :ok = HarnessForge.Privacy.Company.purge_assessments()

          "company_task_rubrics" ->
            :ok

          "company_artifact_bindings" ->
            :ok

          "evaluation_runs" ->
            :ok

          "evidence_claims" ->
            delete_claims(all_claim_ids())

          table ->
            query!("DELETE FROM #{table} WHERE workspace_id = ?", [Workspaces.current_id()])
        end)

        query!("DELETE FROM oban_jobs WHERE json_extract(args, '$.workspace_id') = ?", [
          Workspaces.current_id()
        ])
      else
        purge_source_rows(op)
      end

      Enum.each(delete_triggers, fn [_, ddl] -> query!(ddl, []) end)
      :ok = state(op.id, "database_purged")
      {:ok, %{op | state: "database_purged"}}
    end)
  end

  defp purge_corpus_rows(op) do
    ws = Workspaces.current_id()

    {scope, args} =
      if op.kind == "workspace" do
        {"SELECT id FROM corpora WHERE workspace_id=?", [ws]}
      else
        {"SELECT corpus_id FROM corpus_members WHERE workspace_id=? AND source_id=? UNION SELECT m.corpus_id FROM dependency_manifests m JOIN origin_dependencies d ON d.manifest_id=m.id AND d.workspace_id=m.workspace_id WHERE d.workspace_id=? AND d.source_id=?",
         [ws, op.target, ws, op.target]}
      end

    query!(
      "CREATE TEMP TABLE IF NOT EXISTS hf_purge_corpus_scope(corpus_id TEXT PRIMARY KEY)",
      []
    )

    query!("DELETE FROM hf_purge_corpus_scope", [])
    query!("INSERT INTO hf_purge_corpus_scope(corpus_id) " <> scope, args)
    scope = "SELECT corpus_id FROM hf_purge_corpus_scope"
    args = []
    manifests = "SELECT id FROM dependency_manifests WHERE corpus_id IN (" <> scope <> ")"
    partitions = "SELECT id FROM graph_partition_controls WHERE corpus_id IN (" <> scope <> ")"

    if op.kind == "workspace" do
      query!("DELETE FROM corpus_requirements WHERE workspace_id=?", [ws])
    else
      query!(
        "DELETE FROM corpus_requirements WHERE workspace_id=? AND (corpus_id IN(" <>
          scope <>
          ") OR EXISTS(SELECT 1 FROM json_each(corpus_requirements.payload,'$.entries') e WHERE json_extract(e.value,'$.connection_id')=?))",
        [ws, op.plan["connection_id"]]
      )
    end

    if rows(
         "SELECT partition_id FROM graph_runtime_backends WHERE partition_id IN (" <>
           partitions <> ") AND state!='stopped' LIMIT 1",
         args
       ) != [], do: raise("graph runtime cleanup required")

    # An unavailable backend cannot be silently declared purged. The outer
    # durable privacy operation remains fenced until real cleanup is verified.
    if rows(
         "SELECT id FROM graph_episode_bindings WHERE partition_id IN (" <>
           partitions <> ") AND state!='removed' LIMIT 1",
         args
       ) != [], do: raise("graph cleanup required")

    # Wire ACKs and call capsules contain no source bodies, but still reference
    # the operation, consuming manifests and physical receipts being purged.
    query!(
      "DELETE FROM graph_observation_events WHERE operation_id IN(SELECT id FROM stage_operations WHERE corpus_id IN (" <>
        scope <> "))",
      args
    )

    query!(
      "DELETE FROM graph_observation_calls WHERE operation_id IN(SELECT id FROM stage_operations WHERE corpus_id IN (" <>
        scope <> "))",
      args
    )

    delete_leaves(
      "stage_attempts",
      "predecessor_attempt_id",
      "manifest_id IN (" <> manifests <> ")",
      args
    )

    # Remove certificate pages/builds and referencing typed rows before their
    # immutable graph inputs. All work remains inside the durable privacy fence.
    query!(
      "DELETE FROM graph_consent_certificates WHERE source_manifest_id IN (" <> manifests <> ")",
      args
    )

    query!("DELETE FROM graph_manifest_pages WHERE manifest_id IN (" <> manifests <> ")", args)
    query!("DELETE FROM graph_manifest_builds WHERE manifest_id IN (" <> manifests <> ")", args)
    query!("DELETE FROM origin_dependencies WHERE manifest_id IN (" <> manifests <> ")", args)

    query!("DELETE FROM graph_worker_sessions WHERE partition_id IN (" <> partitions <> ")", args)
    query!("DELETE FROM stage_operations WHERE corpus_id IN (" <> scope <> ")", args)

    delete_leaves(
      "graph_derivative_versions",
      "predecessor_id",
      "partition_id IN (" <> partitions <> ")",
      args
    )

    query!(
      "DELETE FROM graph_episode_bindings WHERE partition_id IN (" <> partitions <> ")",
      args
    )

    query!("DELETE FROM graph_source_scans WHERE partition_id IN (" <> partitions <> ")", args)

    query!(
      "DELETE FROM graph_runtime_backends WHERE partition_id IN (" <> partitions <> ")",
      args
    )

    query!("DELETE FROM graph_partition_controls WHERE id IN (" <> partitions <> ")", args)

    query!(
      "DELETE FROM retrieval_items WHERE run_id IN (SELECT id FROM retrieval_runs WHERE corpus_id IN (" <>
        scope <> "))",
      args
    )

    query!("DELETE FROM retrieval_runs WHERE corpus_id IN (" <> scope <> ")", args)
    query!("DELETE FROM dependency_manifests WHERE id IN (" <> manifests <> ")", args)

    if op.kind == "workspace" do
      query!("DELETE FROM stage_consent_sources WHERE workspace_id=?", [ws])
      query!("DELETE FROM stage_consent_revisions WHERE workspace_id=?", [ws])
      query!("DELETE FROM stage_configs WHERE workspace_id=?", [ws])
      query!("DELETE FROM corpus_members WHERE workspace_id=?", [ws])

      query!(
        "DELETE FROM capture_items WHERE run_id IN(SELECT id FROM capture_runs WHERE workspace_id=?)",
        [ws]
      )

      query!(
        "DELETE FROM capture_frontier WHERE run_id IN(SELECT id FROM capture_runs WHERE workspace_id=?)",
        [ws]
      )

      query!("DELETE FROM capture_runs WHERE workspace_id=?", [ws])
      query!("DELETE FROM passage_search WHERE workspace_id=?", [ws])
      query!("DELETE FROM passages WHERE workspace_id=?", [ws])
      query!("DELETE FROM passage_sets WHERE workspace_id=?", [ws])
      query!("DELETE FROM company_corpus_bindings WHERE workspace_id=?", [ws])
      query!("DELETE FROM corpora WHERE workspace_id=?", [ws])
    else
      query!(
        "UPDATE stage_consent_revisions SET state='revoked' WHERE id IN(SELECT consent_id FROM stage_consent_sources WHERE workspace_id=? AND source_id=?)",
        [ws, op.target]
      )

      query!("DELETE FROM stage_consent_sources WHERE workspace_id=? AND source_id=?", [
        ws,
        op.target
      ])

      query!("DELETE FROM corpus_members WHERE workspace_id=? AND source_id=?", [ws, op.target])
      runs = "SELECT id FROM capture_runs WHERE workspace_id=? AND connection_id=?"
      run_args = [ws, op.plan["connection_id"]]

      query!(
        "UPDATE corpus_members SET last_seen_run_id=NULL WHERE last_seen_run_id IN(" <>
          runs <> ")",
        run_args
      )

      query!("DELETE FROM capture_items WHERE run_id IN(" <> runs <> ")", run_args)
      query!("DELETE FROM capture_frontier WHERE run_id IN(" <> runs <> ")", run_args)
      query!("DELETE FROM capture_runs WHERE id IN(" <> runs <> ")", run_args)

      query!(
        "DELETE FROM passage_search WHERE rowid IN(SELECT p.rowid FROM passages p JOIN passage_sets sets ON sets.id=p.passage_set_id WHERE sets.workspace_id=? AND sets.source_id=?)",
        [ws, op.target]
      )

      query!(
        "DELETE FROM passages WHERE passage_set_id IN(SELECT id FROM passage_sets WHERE workspace_id=? AND source_id=?)",
        [ws, op.target]
      )

      query!("DELETE FROM passage_sets WHERE workspace_id=? AND source_id=?", [ws, op.target])
    end

    query!("DELETE FROM hf_purge_corpus_scope", [])
    :ok
  end

  defp delete_leaves(table, parent, scope, args) do
    result =
      query!(
        "DELETE FROM " <>
          table <>
          " WHERE id IN(SELECT p.id FROM " <>
          table <>
          " p WHERE " <>
          scope <>
          " AND NOT EXISTS(SELECT 1 FROM " <>
          table <> " child WHERE child." <> parent <> "=p.id) LIMIT 100)",
        args
      )

    if result.num_rows > 0 do
      delete_leaves(table, parent, scope, args)
    else
      if rows("SELECT id FROM " <> table <> " WHERE " <> scope <> " LIMIT 1", args) != [],
        do: raise("invalid dependency cycle")

      :ok
    end
  end

  defp purge_source_rows(op) do
    plan = op.plan
    digests = plan["artifact_digests"]
    :ok = HarnessForge.Privacy.Company.purge(plan["company"] || %{}, op.target, plan["claim_ids"])

    approvals =
      rows("SELECT id, artifact_digest FROM release_approvals WHERE workspace_id = ?", [
        Workspaces.current_id()
      ])
      |> Enum.filter(fn [_, digest] -> digest in digests end)
      |> Enum.map(&hd/1)

    Enum.each(approvals, fn id ->
      query!(
        "DELETE FROM release_history WHERE workspace_id = ? AND (release_id = ? OR previous_release_id = ?)",
        [Workspaces.current_id(), id, id]
      )

      query!("DELETE FROM release_channels WHERE workspace_id = ? AND release_id = ?", [
        Workspaces.current_id(),
        id
      ])

      query!("DELETE FROM release_approvals WHERE workspace_id = ? AND id = ?", [
        Workspaces.current_id(),
        id
      ])
    end)

    Enum.each(
      plan["claim_ids"],
      &query!("DELETE FROM claim_decisions WHERE workspace_id = ? AND claim_id = ?", [
        Workspaces.current_id(),
        &1
      ])
    )

    delete_claims(plan["claim_ids"])

    Enum.each(plan["revision_ids"], fn revision ->
      query!("DELETE FROM evidence_citations WHERE workspace_id = ? AND revision_id = ?", [
        Workspaces.current_id(),
        revision
      ])

      query!("DELETE FROM evidence_search WHERE workspace_id = ? AND revision_id = ?", [
        Workspaces.current_id(),
        revision
      ])
    end)

    query!(
      "DELETE FROM revision_use_cleanup WHERE workspace_id=? AND event_id IN (SELECT id FROM revision_use_holds WHERE workspace_id=? AND source_id=?)",
      [Workspaces.current_id(), Workspaces.current_id(), op.target]
    )

    query!("DELETE FROM revision_use_holds WHERE workspace_id=? AND source_id=?", [
      Workspaces.current_id(),
      op.target
    ])

    query!("DELETE FROM evidence_revisions WHERE workspace_id = ? AND source_id = ?", [
      Workspaces.current_id(),
      op.target
    ])

    query!("DELETE FROM evidence_sources WHERE workspace_id = ? AND id = ?", [
      Workspaces.current_id(),
      op.target
    ])

    # All cloud consent is deliberately withdrawn: a consent list can include
    # the deleted source. Reconfiguration is an explicit operator action.
    query!("DELETE FROM model_settings WHERE workspace_id = ?", [Workspaces.current_id()])

    rows("SELECT id, args FROM oban_jobs", [])
    |> Enum.each(fn [id, args] ->
      if related_job?(decode(args), op), do: query!("DELETE FROM oban_jobs WHERE id = ?", [id])
    end)
  end

  defp all_claim_ids,
    do:
      rows("SELECT id FROM evidence_claims WHERE workspace_id = ?", [Workspaces.current_id()])
      |> List.flatten()

  defp delete_claims([]), do: :ok

  defp delete_claims(ids) do
    # Superseding claims form an acyclic chain by construction. A corrupted
    # graph fails closed; it never disables foreign-key enforcement.
    children =
      rows("SELECT id, supersedes_id FROM evidence_claims WHERE workspace_id = ?", [
        Workspaces.current_id()
      ])

    leaves =
      Enum.reject(ids, fn id ->
        Enum.any?(children, fn [child, parent] -> parent == id and child in ids end)
      end)

    if leaves == [], do: raise("invalid claim dependency graph")

    Enum.each(
      leaves,
      &query!("DELETE FROM evidence_claims WHERE workspace_id = ? AND id = ?", [
        Workspaces.current_id(),
        &1
      ])
    )

    delete_claims(ids -- leaves)
  end

  defp remove_files(op) do
    Enum.reduce_while(op.plan["files"], :ok, fn relative, :ok ->
      valid =
        (relative in ~w(artifacts runs tmp) and op.kind == "workspace") or
          Regex.match?(~r/\Aartifacts\/[a-f0-9]{64}\z/, relative) or
          Regex.match?(~r/\Aruns\/(?:coding-)?[a-f0-9-]{36}\z/, relative)

      case if(valid,
             do: Files.remove_owned(Workspaces.root(), relative),
             else: {:error, :unsafe_plan}
           ) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp complete(op) do
    Store.transaction(fn ->
      # Keep original execution authority through backend or file failures.
      # Only verified removal permits forgetting the context-bearing row.
      if op.kind == "workspace" do
        query!("DELETE FROM command_approvals WHERE workspace_id = ?", [Workspaces.current_id()])
        query!("DELETE FROM evaluation_runs WHERE workspace_id = ?", [Workspaces.current_id()])
      else
        for id <- op.plan["run_ids"] do
          query!("DELETE FROM command_approvals WHERE workspace_id = ? AND run_id = ?", [
            Workspaces.current_id(),
            id
          ])

          query!("DELETE FROM evaluation_runs WHERE workspace_id = ? AND id = ?", [
            Workspaces.current_id(),
            id
          ])
        end
      end

      # Keep binding history until file removal succeeds. A failed removal
      # remains fenced and retryable, without turning an artifact into an
      # apparently unbound legacy package.
      drop_delete_trigger("company_artifact_bindings")

      if op.kind == "workspace" do
        query!("DELETE FROM company_artifact_bindings WHERE workspace_id = ?", [
          Workspaces.current_id()
        ])
      else
        for id <- get_in(op.plan, ["company", "plan_ids"]) || [] do
          query!(
            "DELETE FROM company_artifact_bindings WHERE workspace_id = ? AND plan_id = ?",
            [Workspaces.current_id(), id]
          )
        end
      end

      create_delete_trigger("company_artifact_bindings")
      :ok = state(op.id, "completed")
      {:ok, :completed}
    end)
  end

  defp cancel_queued(op) do
    rows(
      "SELECT id, args FROM oban_jobs WHERE state IN ('available','scheduled','retryable')",
      []
    )
    |> Enum.each(fn [id, args] ->
      if related_job?(decode(args), op) do
        query!(
          "UPDATE oban_jobs SET state = 'cancelled', cancelled_at = ? WHERE id = ? AND state IN ('available','scheduled','retryable')",
          [DateTime.to_iso8601(DateTime.utc_now()), id]
        )
      end
    end)
  end

  defp related_job?(args, op) do
    args["workspace_id"] == Workspaces.current_id() and
      (op.kind == "workspace" or
         args["connection_id"] == op.plan["connection_id"] or
         (args["action"] == "sync" and args["id"] == op.plan["connection_id"]) or
         (args["action"] == "propose" and args["id"] == op.target) or
         (args["action"] == "evaluate" and args["id"] in op.plan["artifact_digests"]) or
         corpus_job_related?(args, op))
  end

  defp corpus_job_related?(args, op) do
    cond do
      is_binary(args["run_id"]) ->
        rows("SELECT id FROM capture_runs WHERE workspace_id=? AND id=? AND connection_id=?", [
          Workspaces.current_id(),
          args["run_id"],
          op.plan["connection_id"]
        ]) != []

      is_binary(args["revision_id"]) ->
        args["revision_id"] in op.plan["revision_ids"]

      true ->
        false
    end
  end

  defp drop_delete_trigger(table),
    do: query!("DROP TRIGGER IF EXISTS immutable_#{table}_delete", [])

  defp create_delete_trigger(table),
    do:
      query!(
        "CREATE TRIGGER immutable_#{table}_delete BEFORE DELETE ON #{table} BEGIN SELECT RAISE(ABORT, 'immutable record'); END",
        []
      )

  defp state(id, state) do
    query!(
      "UPDATE privacy_operations SET state = ?, error = NULL, updated_at = ? WHERE workspace_id = ? AND id = ?",
      [state, DateTime.to_iso8601(DateTime.utc_now()), Workspaces.current_id(), id]
    )

    :ok
  end

  defp state_error(id, error),
    do:
      query!("UPDATE privacy_operations SET error = ? WHERE workspace_id = ? AND id = ?", [
        error,
        Workspaces.current_id(),
        id
      ])

  defp rows(sql, params), do: query!(sql, params).rows
  defp query!(sql, params), do: Repo.query!(sql, params)

  defp operation([id, kind, target, state, plan]),
    do: %{id: id, kind: kind, target: target, state: state, plan: decode(plan)}

  defp decode(map) when is_map(map), do: map
  defp decode(json), do: Jason.decode!(json)

  defp result(op),
    do: %{
      "operation_id" => op.id,
      "kind" => op.kind,
      "target_id" => op.target,
      "state" => op.state,
      "physical_erasure" => false,
      "connection_revalidation_required" => op.kind == "source"
    }

  defp safe_reason(reason) when reason in [:cleanup_failed, :jobs_still_executing, :unsafe_path],
    do: Atom.to_string(reason)

  defp safe_reason(_), do: "purge_failed"

  # Global locks are not reference counted: only the outer call may release this fence.
  def synchronize(fun) do
    workspace = Workspaces.current_id()
    owner = {__MODULE__, :synchronize, workspace}

    if Process.get(owner) == true do
      fun.()
    else
      :global.trans({{__MODULE__, workspace}, self()}, fn ->
        Process.put(owner, true)

        try do
          fun.()
        after
          Process.delete(owner)
        end
      end)
    end
  end
end
