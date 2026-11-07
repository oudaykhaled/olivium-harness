defmodule HarnessForge.Privacy.SetupHistory do
  @moduledoc false
  alias HarnessForge.{Audit, Contracts, Repo, Workspaces}

  alias HarnessForge.Company.{
    SetupRuns,
    SetupRunConfig,
    SetupRun,
    SetupRunPreparation,
    SetupRunOperation
  }

  alias HarnessForge.Models.{RunAuthorization, RunAuthorizationRecord, RunDisclosure}

  @tables ~w(setup_run_configs setup_runs setup_run_states setup_run_preparations setup_run_commands setup_run_operations model_run_authorizations model_run_authorization_states model_run_disclosures setup_capture_bindings setup_capture_counters setup_capture_charges setup_capture_pages)
  @digested [
    {"config", SetupRunConfig},
    {"run", SetupRun},
    {"preparation", SetupRunPreparation},
    {"authorization", RunAuthorizationRecord},
    {"disclosure", RunDisclosure},
    {"operation", SetupRunOperation}
  ]
  def tables, do: @tables

  # A prepared request may contain any source in its exact manifest. Selective
  # source removal conservatively withdraws all saved run derivatives, rather
  # than retain a copied prompt whose closure was only partly removed.
  def purge(kind) do
    true = Repo.in_transaction?()
    ws = Workspaces.current_id()
    if kind == "source", do: retire_identities(ws)

    Repo.query!(
      """
      UPDATE capture_runs SET state='cancelled',lease_token=NULL,lease_until=NULL,
        lock_version=lock_version+1,updated_at=? WHERE workspace_id=?
        AND state IN('queued','running','paused') AND id IN(
          SELECT capture_id FROM setup_capture_bindings WHERE workspace_id=?)
      """,
      [HarnessForge.Evidence.Corpora.now(), ws, ws]
    )

    Enum.each(Enum.reverse(@tables), &Repo.query!("DELETE FROM #{&1} WHERE workspace_id=?", [ws]))

    Repo.query!(
      """
      UPDATE stage_operations SET authorization_id=NULL,budget_id=NULL,operation_binding_digest=NULL,
        state='cancelled',cancel_epoch=cancel_epoch+1
      WHERE workspace_id=? AND authorization_id IS NOT NULL
      """,
      [ws]
    )

    Repo.query!(
      """
      UPDATE setup_sessions SET payload=json_set(payload,'$.refs.run_ref',NULL),
        lock_version=lock_version+1,updated_at=? WHERE workspace_id=? AND schema_version=2
      """,
      [HarnessForge.Evidence.Corpora.now(), ws]
    )

    :ok
  end

  # Keep only non-content negative provenance when deleting prepared payloads.
  # These immutable markers grant nothing and prevent an absent setup row from
  # turning a former governed identity into a legacy identity after source purge.
  defp retire_identities(ws) do
    identities =
      Repo.query!(
        """
        SELECT 'setup_budget_retired',budget_id FROM model_run_authorizations WHERE workspace_id=?
        UNION SELECT 'setup_pin_retired',json_extract(stage_ref,'$.id') FROM setup_run_preparations WHERE workspace_id=?
        UNION SELECT 'setup_operation_retired',operation_id FROM setup_run_operations WHERE workspace_id=?
        """,
        [ws, ws, ws]
      ).rows

    Enum.each(identities, fn [action, id] ->
      {:ok, _} = Audit.append(action, %{"run_id" => id, "status" => "retired"})
    end)
  end

  # Called only against the fresh restore copy while its transaction is open and
  # immutable triggers are temporarily removed. Reuse Snapshot's SQL connection;
  # never open a live Repo or dispatch a provider during quarantine.
  def quarantine(query, old_ws, new_ws) do
    refs =
      Enum.reduce(@digested, %{}, fn {kind, schema}, refs ->
        Enum.reduce(records(query, schema, new_ws), refs, fn row, acc ->
          digest =
            case kind do
              value when value in ~w(config run operation) ->
                SetupRuns.restore_digest(value, row)

              value ->
                {:ok, digest} = RunAuthorization.restore_digest(value, row)
                digest
            end

          write(query, "UPDATE #{schema.__schema__(:source)} SET digest=? WHERE id=?", [
            digest,
            row.id
          ])

          Map.put(acc, {row.id, row.digest}, digest)
        end)
      end)

    Enum.each(
      rows(
        query,
        "SELECT id,payload FROM setup_sessions WHERE workspace_id=? AND schema_version=2",
        [new_ws]
      ),
      fn [id, payload] ->
        write(query, "UPDATE setup_sessions SET payload=? WHERE id=?", [
          rewrite_json(payload, refs),
          id
        ])
      end
    )

    Enum.each(
      rows(
        query,
        "SELECT id,request_json,receipt_json FROM setup_run_commands WHERE workspace_id=?",
        [new_ws]
      ),
      fn [id, request, receipt] ->
        request = request |> Jason.decode!() |> rewrite(refs)
        digest = Contracts.digest(request)

        receipt =
          receipt |> Jason.decode!() |> rewrite(refs) |> put_in(["command_ref", "digest"], digest)

        write(
          query,
          "UPDATE setup_run_commands SET request_json=?,request_digest=?,receipt_json=? WHERE id=?",
          [Contracts.canonical_json(request), digest, Contracts.canonical_json(receipt), id]
        )
      end
    )

    Enum.each(
      rows(
        query,
        "SELECT id,result_ref FROM setup_run_states WHERE workspace_id=? AND result_ref IS NOT NULL",
        [new_ws]
      ),
      fn [id, value] ->
        write(query, "UPDATE setup_run_states SET result_ref=? WHERE id=?", [
          rewrite_json(value, refs),
          id
        ])
      end
    )

    Enum.each(
      rows(
        query,
        "SELECT id,operation_binding_digest FROM stage_operations WHERE workspace_id=? AND operation_binding_digest IS NOT NULL",
        [new_ws]
      ),
      fn [id, digest] ->
        write(query, "UPDATE stage_operations SET operation_binding_digest=? WHERE id=?", [
          Map.fetch!(refs, {id, digest}),
          id
        ])
      end
    )

    now = DateTime.to_iso8601(DateTime.utc_now())

    write(
      query,
      "UPDATE setup_run_states SET phase='cancelled',failure_code='cancelled',lock_version=lock_version+1,updated_at=? WHERE workspace_id=?",
      [now, new_ws]
    )

    write(
      query,
      "UPDATE model_run_authorization_states SET revoked_at=?,reason='restored',lock_version=lock_version+1 WHERE workspace_id=? AND revoked_at IS NULL",
      [now, new_ws]
    )

    write(
      query,
      "UPDATE setup_capture_charges SET state='uncertain',lock_version=lock_version+1 WHERE workspace_id=? AND state='reserved'",
      [new_ws]
    )

    # Capture leases and all StageControls were already withdrawn by Snapshot.
    # Historical reservations stay charged; an unknown dispatch cannot be resent.
    write(
      query,
      "UPDATE model_requests SET state='uncertain',usage_status='unknown',billing_status='unknown' WHERE workspace_id=? AND state='dispatched'",
      [new_ws]
    )

    lineage =
      refs
      |> Enum.map(fn {{id, old}, digest} ->
        %{"id" => id, "old_digest" => old, "new_digest" => digest}
      end)
      |> Enum.sort_by(&{&1["id"], &1["old_digest"]})

    # Bounded audit metadata commits to the complete ref mapping without copying
    # evidence or an unbounded history array into the event.
    if map_size(refs) > 0 do
      details = %{
        "status" => "restored_history_only",
        "actor" => old_ws,
        "run_id" => new_ws,
        "count" => map_size(refs),
        "request_digest" => Contracts.digest(lineage)
      }

      write(
        query,
        "INSERT INTO audit_events(id,workspace_id,action,details,inserted_at) VALUES(?,?,?,?,?)",
        [
          Ecto.UUID.generate(),
          new_ws,
          "setup_history_quarantined",
          Contracts.canonical_json(details),
          now
        ]
      )
    end

    :ok
  end

  defp records(query, schema, workspace) do
    fields = schema.__schema__(:fields)
    columns = Enum.map_join(fields, ",", &Atom.to_string/1)

    Enum.map(
      rows(query, "SELECT #{columns} FROM #{schema.__schema__(:source)} WHERE workspace_id=?", [
        workspace
      ]),
      fn values ->
        attrs =
          Enum.zip(fields, values)
          |> Map.new(fn {field, value} ->
            type = schema.__schema__(:type, field)
            loaded = if is_nil(value), do: nil, else: load(type, value)
            {field, loaded}
          end)

        struct!(schema, attrs)
      end
    )
  end

  defp load(type, value) do
    {:ok, loaded} = Ecto.Type.adapter_load(Repo.__adapter__(), type, value)
    loaded
  end

  defp rewrite_json(value, refs),
    do: value |> Jason.decode!() |> rewrite(refs) |> Contracts.canonical_json()

  defp rewrite(%{"id" => id, "digest" => digest} = value, refs) when map_size(value) == 2,
    do: Map.put(value, "digest", Map.get(refs, {id, digest}, digest))

  defp rewrite(value, refs) when is_map(value),
    do: Map.new(value, fn {key, child} -> {key, rewrite(child, refs)} end)

  defp rewrite(value, refs) when is_list(value), do: Enum.map(value, &rewrite(&1, refs))
  defp rewrite(value, _), do: value

  defp rows(query, sql, params) do
    {:ok, rows} = query.(sql, params)
    rows
  end

  defp write(query, sql, params) do
    {:ok, _} = query.(sql, params)
    :ok
  end
end
