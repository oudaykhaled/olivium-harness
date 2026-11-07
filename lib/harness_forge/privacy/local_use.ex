defmodule HarnessForge.Privacy.LocalUse do
  @moduledoc """
  Restricted local-use metadata cleanup inside the owning Purge transaction.

  Purge must hold its existing privacy fence and propagate every error from the
  before-purge hooks, so setup/body deletion and policy changes commit together.
  Snapshot must call quarantine/3 on its copied connection, inside its deferred-FK
  transaction, after saving/dropping the registered triggers and before remapping
  these tables. It must restore those exact triggers and check FKs before commit.
  These hooks neither read source bodies nor grant source use or claim erasure.
  """
  alias HarnessForge.{Contracts, Repo, Workspaces}
  alias HarnessForge.Evidence.{Corpora, LocalUseEnrollment, LocalUseItem,
    LocalUseLifecycle, LocalUsePolicies, LocalUseSet, Store}

  @tables ~w(local_use_sets local_use_items local_use_enrollments local_use_events local_use_checkpoints)
  @trigger_names ~w(local_use_set_owned local_use_set_transition local_use_item_owned local_use_item_immutable local_use_event_immutable local_use_enrollment_owned local_use_enrollment_monotone local_use_checkpoint_monotone)
  @preparation_events ~w(refresh_prepared refresh_bound)

  def tables, do: @tables
  def trigger_names, do: @trigger_names

  @doc "Tombstone only the target namespace before existing global setup cleanup."
  def before_source_purge(source_id, purge_id) do
    before_purge("source", source_id, purge_id)
  end

  @doc "Retain namespace denials while deleting workspace policy detail in leaf order."
  def before_workspace_purge(purge_id) do
    before_purge("workspace", Store.workspace(), purge_id)
  rescue
    _ -> {:error, :source_use_denied}
  end

  defp before_purge(kind, target, purge_id) do
    with :ok <- owning_operation(kind, target, purge_id),
         payload = barrier_payload(kind, target, purge_id, Store.workspace()),
         {:ok, replay} <- replay_barrier(purge_id, payload) do
      if replay do
        :ok
      else
        query = &live_query/2
        workspace = Store.workspace()
        sets = Repo.all(Store.scoped(LocalUseSet))
        items = Repo.all(Store.scoped(LocalUseItem))
        enrollments = Repo.all(Store.scoped(LocalUseEnrollment))

        with :ok <- validate_authority(sets, items, enrollments, workspace),
             :ok <- validate_preparation_events(query, workspace),
             {:ok, _order} <- predecessor_order(sets) do
          if kind == "workspace" do
            write!(query, "UPDATE local_use_enrollments SET state='purged_denied',source_id=NULL,set_id=NULL WHERE workspace_id=? AND state='bound'", [workspace])
            Enum.each(~w(local_use_checkpoints local_use_events local_use_items), fn table ->
              write!(query, "DELETE FROM #{table} WHERE workspace_id=?", [workspace])
            end)
            delete_set_leaves!(query, workspace, false)
          else
            write!(query, "UPDATE local_use_enrollments SET state='purged_denied',source_id=NULL,set_id=NULL WHERE workspace_id=? AND source_id=? AND original_source_id=? AND state='bound'", [workspace, target, target])
            delete_preparations!(query, workspace)
          end

          with {:ok, _} <- LocalUseLifecycle.append_in_transaction("privacy_barrier", %{},
                 %{"command_key" => "privacy:" <> purge_id,
                   "request_digest" => Contracts.digest(payload), "payload" => payload}), do: :ok
        end
      end
    end
  rescue
    _ -> {:error, :source_use_denied}
  end

  defp owning_operation(kind, target, purge_id) do
    with true <- Repo.in_transaction?() and Corpora.uuid?(target) and Corpora.uuid?(purge_id),
         %{rows: [[^kind, ^target, "prepared"]]} <- Repo.query!(
           "SELECT kind,target_id,state FROM privacy_operations WHERE workspace_id=? AND id=?",
           [Store.workspace(), purge_id]), do: :ok,
      else: (_ -> {:error, :source_use_denied})
  end

  defp replay_barrier(purge_id, payload) do
    with {:ok, event} <- LocalUseLifecycle.replay("privacy:" <> purge_id, Contracts.digest(payload)) do
      cond do
        is_nil(event) -> {:ok, nil}
        event["kind"] == "privacy_barrier" and is_nil(event["set_id"]) and
          is_nil(event["source_id"]) and event["payload"] == payload -> {:ok, event}
        true -> {:error, :source_use_denied}
      end
    end
  end

  defp barrier_payload(kind, target, purge_id, workspace), do: %{
    "version" => "LocalUsePrivacyBarrier.v1", "kind" => kind,
    "target_id" => target, "purge_id" => purge_id, "workspace_id" => workspace}

  @doc """
  Validate old frozen provenance, then quarantine only the supplied copied SQL DB.
  Returns old-policy-reference to new-wrapper-digest mappings. Original manifests,
  basis, origin identity, generations, restrictions and event inputs stay intact.
  Missing pre-policy tables are inert; a partial policy schema fails closed.
  """
  def quarantine(query, old_workspace, new_workspace) when is_function(query, 2) do
    with true <- Corpora.uuid?(old_workspace) and Corpora.uuid?(new_workspace) and
           old_workspace != new_workspace do
      case copied_tables(query) do
        [] -> {:ok, %{}}
        present when present == @tables -> quarantine_tables(query, old_workspace, new_workspace)
        _ -> {:error, :source_use_denied}
      end
    else
      _ -> {:error, :source_use_denied}
    end
  rescue
    _ -> {:error, :source_use_denied}
  end
  def quarantine(_, _, _), do: {:error, :source_use_denied}

  defp quarantine_tables(query, old_workspace, new_workspace) do
    with :ok <- copied_workspace(query, old_workspace),
         sets = records(query, LocalUseSet, old_workspace),
         items = records(query, LocalUseItem, old_workspace),
         enrollments = records(query, LocalUseEnrollment, old_workspace),
         :ok <- validate_authority(sets, items, enrollments, old_workspace),
         :ok <- validate_preparation_events(query, old_workspace),
         {:ok, ordered} <- predecessor_order(sets) do
      delete_preparations!(query, old_workspace)

      Enum.each(@tables, fn table ->
        write!(query, "UPDATE #{table} SET workspace_id=? WHERE workspace_id=?", [new_workspace, old_workspace])
      end)

      refs = Enum.reduce(ordered, %{}, fn set, acc ->
        if set.state == "prepared" do
          acc
        else
          preparation = Contracts.digest(%{"version" => "LocalUsePreparation.v1",
            "workspace_id" => new_workspace, "owner_id" => set.owner_id,
            "basis" => set.basis_json, "manifest_digest" => set.manifest_digest})
          policy = Contracts.digest(%{"version" => "LocalUsePolicy.v1",
            "workspace_id" => new_workspace, "owner_id" => set.owner_id,
            "preparation_digest" => preparation, "manifest_digest" => set.manifest_digest,
            "basis" => set.basis_json, "purposes" => set.purposes_json, "retain_local" => true})
          write!(query, "UPDATE local_use_sets SET preparation_digest=?,policy_digest=?,quarantined=1 WHERE workspace_id=? AND id=?", [preparation, policy, new_workspace, set.id])
          Map.put(acc, {set.id, set.policy_digest}, policy)
        end
      end)

      Enum.each(enrollments, fn enrollment ->
        write!(query, "UPDATE local_use_enrollments SET namespace_digest=? WHERE workspace_id=? AND id=?",
          [namespace_digest(new_workspace, enrollment), new_workspace, enrollment.id])
      end)
      with :ok <- validate_authority(records(query, LocalUseSet, new_workspace),
             records(query, LocalUseItem, new_workspace),
             records(query, LocalUseEnrollment, new_workspace), new_workspace) do
        append_quarantine_barrier!(query, old_workspace, new_workspace)
        {:ok, refs}
      end
    end
  end

  defp copied_tables(query) do
    present = rows!(query, "SELECT name FROM sqlite_master WHERE type='table' AND name IN (?,?,?,?,?)", @tables)
      |> List.flatten() |> MapSet.new()
    Enum.filter(@tables, &MapSet.member?(present, &1))
  end

  defp copied_workspace(query, workspace) do
    if Enum.all?(@tables, fn table ->
         rows!(query, "SELECT DISTINCT workspace_id FROM #{table}", []) in [[], [[workspace]]]
       end), do: :ok, else: {:error, :source_use_denied}
  end

  defp validate_authority(sets, items, enrollments, workspace) do
    by_set = Map.new(sets, &{&1.id, &1})
    by_source = Map.new(enrollments, &{&1.original_source_id, &1})
    grouped = Enum.group_by(items, & &1.set_id)

    with true <- map_size(by_set) == length(sets) and map_size(by_source) == length(enrollments) and
           length(Enum.uniq_by(enrollments, & &1.id)) == length(enrollments) and
           length(Enum.uniq_by(enrollments, &{&1.connection_id, &1.provider, &1.external_id})) == length(enrollments),
         true <- Enum.all?(items, &(&1.workspace_id == workspace and Map.has_key?(by_set, &1.set_id))),
         :ok <- validate_sets(sets, grouped, workspace),
         true <- Enum.all?(enrollments, &valid_enrollment?(&1, by_set, grouped, workspace)),
         true <- Enum.all?(sets, fn set ->
           set.state != "active" or Enum.all?(Map.get(grouped, set.id, []), fn item ->
             classified_item?(Map.get(by_source, item.source_id), item, set)
           end)
         end), do: :ok,
      else: (_ -> {:error, :source_use_denied})
  end

  defp validate_sets(sets, grouped, workspace) do
    Enum.reduce_while(sets, :ok, fn set, :ok ->
      original = Map.get(grouped, set.id, []) |> Enum.sort_by(& &1.source_id)
        |> Enum.map(&Map.new([{"source_id", &1.source_id}, {"revision_id", &1.revision_id},
          {"body_hash", &1.body_hash}, {"capture_item_key", &1.capture_item_key}]))
      case LocalUsePolicies.frozen_integrity(set, original, workspace, Workspaces.operator()) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp valid_enrollment?(enrollment, sets, grouped, workspace) do
    identity_ok = enrollment.workspace_id == workspace and Corpora.uuid?(enrollment.id) and
      Corpora.uuid?(enrollment.original_source_id) and Corpora.uuid?(enrollment.connection_id) and
      enrollment.provider == "local" and safe_path?(enrollment.external_id) and
      enrollment.namespace_digest == namespace_digest(workspace, enrollment) and
      is_integer(enrollment.grant_generation) and enrollment.grant_generation > 0

    identity_ok and case enrollment.state do
      "purged_denied" -> is_nil(enrollment.source_id) and is_nil(enrollment.set_id)
      "bound" ->
        case Map.get(sets, enrollment.set_id) do
          %LocalUseSet{state: state} = set when state in ~w(active withdrawn) ->
            enrollment.source_id == enrollment.original_source_id and enrollment.connection_id == set.connection_id and
              enrollment.grant_generation == (set.predecessor_generation || 0) + 1 and
              Enum.any?(Map.get(grouped, set.id, []), fn item ->
                item.source_id == enrollment.original_source_id and item.capture_item_key == enrollment.external_id
              end)
          _ -> false
        end
      _ -> false
    end
  end

  defp classified_item?(%LocalUseEnrollment{} = enrollment, item, set) do
    enrollment.original_source_id == item.source_id and enrollment.connection_id == set.connection_id and
      enrollment.external_id == item.capture_item_key and enrollment.grant_generation == set.policy_generation and
      ((enrollment.state == "bound" and enrollment.source_id == item.source_id and enrollment.set_id == set.id) or
        (enrollment.state == "purged_denied" and is_nil(enrollment.source_id) and is_nil(enrollment.set_id)))
  end
  defp classified_item?(_, _, _), do: false

  defp namespace_digest(workspace, enrollment), do: Contracts.digest(%{
    "version" => "LocalUseNamespace.v1", "workspace_id" => workspace,
    "connection_id" => enrollment.connection_id, "provider" => enrollment.provider,
    "external_id" => enrollment.external_id})

  defp safe_path?(path), do: Corpora.text?(path, 4096) and Path.type(path) == :relative and
    ".." not in Path.split(path)

  defp validate_preparation_events(query, workspace) do
    kinds = rows!(query, "SELECT e.kind FROM local_use_events e JOIN local_use_sets p ON p.workspace_id=e.workspace_id AND p.id=e.set_id WHERE p.workspace_id=? AND p.state='prepared'", [workspace])
    if Enum.all?(kinds, fn [kind] -> kind in @preparation_events; _ -> false end),
      do: :ok, else: {:error, :source_use_denied}
  end

  defp delete_preparations!(query, workspace) do
    prepared = "SELECT id FROM local_use_sets WHERE workspace_id=? AND state='prepared'"
    write!(query, "DELETE FROM local_use_checkpoints WHERE workspace_id=? AND event_id IN(SELECT id FROM local_use_events WHERE workspace_id=? AND set_id IN(#{prepared}))", [workspace, workspace, workspace])
    write!(query, "DELETE FROM local_use_events WHERE workspace_id=? AND set_id IN(#{prepared})", [workspace, workspace])
    write!(query, "DELETE FROM local_use_items WHERE workspace_id=? AND set_id IN(#{prepared})", [workspace, workspace])
    delete_set_leaves!(query, workspace, true)
  end

  defp delete_set_leaves!(query, workspace, prepared_only) do
    scope = if prepared_only, do: " AND p.state='prepared'", else: ""
    ids = rows!(query, "SELECT p.id FROM local_use_sets p WHERE p.workspace_id=?#{scope} AND NOT EXISTS(SELECT 1 FROM local_use_sets child WHERE child.predecessor_set_id=p.id) ORDER BY p.id LIMIT 100", [workspace]) |> List.flatten()

    if ids == [] do
      if rows!(query, "SELECT p.id FROM local_use_sets p WHERE p.workspace_id=?#{scope} LIMIT 1", [workspace]) != [],
        do: raise(ArgumentError, "invalid local-use predecessor closure")
      :ok
    else
      placeholders = Enum.map_join(ids, ",", fn _ -> "?" end)
      write!(query, "DELETE FROM local_use_sets WHERE workspace_id=? AND id IN(#{placeholders})", [workspace | ids])
      delete_set_leaves!(query, workspace, prepared_only)
    end
  end

  defp predecessor_order(sets), do: predecessor_order(sets, MapSet.new(), [])
  defp predecessor_order([], _, ordered), do: {:ok, ordered}
  defp predecessor_order(remaining, seen, ordered) do
    {ready, waiting} = Enum.split_with(remaining, fn set ->
      is_nil(set.predecessor_set_id) or MapSet.member?(seen, set.predecessor_set_id)
    end)
    if ready == [] do
      {:error, :source_use_denied}
    else
      ready = Enum.sort_by(ready, & &1.id)
      predecessor_order(waiting, Enum.reduce(ready, seen, &MapSet.put(&2, &1.id)), ordered ++ ready)
    end
  end

  defp append_quarantine_barrier!(query, old_workspace, workspace) do
    command_id = Ecto.UUID.generate()
    payload = %{"version" => "LocalUsePrivacyBarrier.v1", "kind" => "quarantine",
      "origin_workspace_id" => old_workspace, "workspace_id" => workspace, "command_id" => command_id}
    [[sequence]] = rows!(query, "SELECT coalesce(max(sequence),0)+1 FROM local_use_events WHERE workspace_id=? AND stream_key='privacy'", [workspace])
    write!(query, "INSERT INTO local_use_events(id,workspace_id,set_id,source_id,stream_key,sequence,kind,command_key,request_digest,payload_json,inserted_at) VALUES(?,?,NULL,NULL,'privacy',?,'privacy_barrier',?,?,?,?)",
      [Ecto.UUID.generate(), workspace, sequence, "privacy:" <> command_id,
        Contracts.digest(payload), Contracts.canonical_json(payload), DateTime.to_iso8601(DateTime.utc_now())])
  end

  defp records(query, schema, workspace) do
    fields = schema.__schema__(:fields)
    columns = Enum.map_join(fields, ",", &Atom.to_string/1)
    Enum.map(rows!(query, "SELECT #{columns} FROM #{schema.__schema__(:source)} WHERE workspace_id=?", [workspace]), fn values ->
      attrs = Enum.zip(fields, values) |> Map.new(fn {field, value} ->
        type = schema.__schema__(:type, field)
        loaded = if is_nil(value), do: nil, else: load!(type, value)
        {field, loaded}
      end)
      struct!(schema, attrs)
    end)
  end

  defp load!(type, value) do
    {:ok, loaded} = Ecto.Type.adapter_load(Ecto.Adapters.SQLite3, type, value)
    loaded
  end

  defp live_query(sql, parameters) do
    result = Repo.query!(sql, parameters)
    {:ok, result.rows || []}
  end

  defp rows!(query, sql, parameters) do
    {:ok, rows} = query.(sql, parameters)
    rows
  end

  defp write!(query, sql, parameters) do
    {:ok, _} = query.(sql, parameters)
    :ok
  end
end
