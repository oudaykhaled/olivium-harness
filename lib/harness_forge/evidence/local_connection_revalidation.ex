defmodule HarnessForge.Evidence.LocalConnectionRevalidation do
  @moduledoc """
  Explicit recovery of an existing local connection's availability at its original
  physical root. Policy provenance is checked without granting content use.
  Filesystem checks run outside SQL, including while holding the privacy fence.
  """
  import Ecto.Query
  alias HarnessForge.{Contracts, Repo, Workspaces}
  alias HarnessForge.Evidence.{Capture, Connection, Corpora, LocalImport,
    LocalUseLifecycle, LocalUsePolicies, LocalUseSet, SourceUseContext, Store}
  alias HarnessForge.Privacy.Purge

  @attrs ~w(version command_id policy_ref expected_generation expected_connection_state directory)

  @spec basis(term(), term(), term()) :: {:ok, map()} | {:error, atom()}
  def basis(connection_id, policy_ref, context) do
    with true <- Corpora.uuid?(connection_id) and ref?(policy_ref),
         false <- Repo.in_transaction?(),
         :ok <- interactive(context) do
      guarded(context, fn ->
        with {:ok, observed} <- observe(connection_id, policy_ref, context) do
          {:ok, %{"policy_ref" => policy_ref,
            "expected_generation" => observed.set.policy_generation,
            "expected_connection_state" => observed.state_digest}}
        end
      end)
    else
      value when is_boolean(value) -> {:error, :invalid_input}
      error -> error
    end
  rescue
    _ -> {:error, :source_use_denied}
  catch
    _, _ -> {:error, :source_use_denied}
  end

  @spec revalidate(term(), term(), term()) :: {:ok, map()} | {:error, atom()}
  def revalidate(connection_id, attrs, context) do
    with :ok <- input(connection_id, attrs),
         false <- Repo.in_transaction?(),
         :ok <- interactive(context),
         digest = Contracts.digest(%{"connection_id" => connection_id, "attrs" => attrs}),
         {:ok, command} <- guarded(context, fn ->
           with {:ok, event} <- LocalUseLifecycle.replay(command_key(attrs), digest) do
             if event do
               with {:ok, _} <- replay_owner(event, connection_id, attrs),
                 do: {:ok, {:replay, event}}
             else
               with {:ok, observed} <- observe(connection_id, attrs["policy_ref"], context),
                    :ok <- expected(observed, attrs), do: {:ok, {:fresh, observed}}
             end
           end
         end) do
      case command do
        {:replay, event} -> synchronize(fn -> replay_locked(event, connection_id, attrs, context) end)
        {:fresh, observed} -> recover(connection_id, attrs, digest, observed, context)
      end
    else
      true -> {:error, :invalid_input}
      error -> error
    end
  rescue
    _ -> {:error, :source_use_denied}
  catch
    _, _ -> {:error, :source_use_denied}
  end

  defp recover(connection_id, attrs, digest, observed, context) do
    with {:ok, proof} <- physical_root(attrs["directory"], observed) do
      synchronize(fn ->
        with :ok <- interactive(context),
             :ok <- readiness(),
             {:ok, checked_proof} <- physical_root(attrs["directory"], observed),
             true <- checked_proof == proof,
             {:ok, result} <- guarded(context, fn ->
               commit(connection_id, attrs, digest, observed, checked_proof, context)
             end) do
          case result do
            {:replay, event} -> replay_locked(event, connection_id, attrs, context)
            {:committed, event} -> replay_locked(event, connection_id, attrs, context)
          end
        else
          false -> {:error, :preparation_stale}
          error -> error
        end
      end)
    end
  end

  defp commit(connection_id, attrs, digest, observed, proof, context) do
    with {:ok, replay} <- LocalUseLifecycle.replay(command_key(attrs), digest) do
      if replay do
        with {:ok, _} <- replay_owner(replay, connection_id, attrs),
          do: {:ok, {:replay, replay}}
      else
        with {:ok, fresh} <- observe(connection_id, attrs["policy_ref"], context),
             :ok <- expected(fresh, attrs),
             true <- fresh == observed,
             :ok <- update_connection(fresh.connection, proof.directory),
             {:ok, event} <- LocalUseLifecycle.append_in_transaction(
               "connection_revalidated", %{"set_id" => fresh.set.id},
               %{"command_key" => command_key(attrs), "request_digest" => digest,
                 "payload" => %{"connection_id" => connection_id,
                   "policy_ref" => attrs["policy_ref"],
                   "policy_generation" => fresh.set.policy_generation,
                   "previous_connection_state" => fresh.state_digest,
                   "restored_connection_digest" => proof.connection_digest,
                   "root_fingerprint" => proof.root_fingerprint}}) do
          {:ok, {:committed, event}}
        else
          false -> {:error, :preparation_stale}
          error -> error
        end
      end
    end
  end

  # Include every persisted field in both the observation and write predicate.
  # There is deliberately no connection lock_version or new authority record.
  defp update_connection(connection, directory) do
    query = Enum.reduce(Connection.__schema__(:fields), Store.scoped(Connection), fn key, query ->
      case Map.fetch!(connection, key) do
        nil -> where(query, [row], is_nil(field(row, ^key)))
        value -> where(query, [row], field(row, ^key) == ^value)
      end
    end)

    case Repo.update_all(query, set: [directory: directory, config: %{}, status: "active",
      cursor: nil, sync_state: "not_synced", sync_complete: false,
      last_synced_at: nil, updated_at: Store.now()]) do
      {1, _} -> :ok
      _ -> {:error, :preparation_stale}
    end
  end

  defp observe(connection_id, policy_ref, context) do
    with {:ok, {set, survivor_basis}} <-
           LocalUsePolicies.revalidation_basis(connection_id, policy_ref, context),
         {:ok, connection} <- local_connection(connection_id),
         true <- connection.config == %{} do
      {:ok, %{set: set, survivor_basis: survivor_basis, connection: connection,
        state_digest: connection_state(connection, LocalUseLifecycle.privacy_barrier())}}
    else
      false -> {:error, :connection_unavailable}
      {:error, :not_found} -> {:error, :connection_unavailable}
      _ -> {:error, :source_use_denied}
    end
  end

  defp expected(observed, attrs) do
    if observed.set.policy_generation == attrs["expected_generation"] and
      observed.state_digest == attrs["expected_connection_state"], do: :ok,
      else: {:error, :preparation_stale}
  end

  defp connection_state(connection, barrier) do
    fields = Connection.__schema__(:fields) |> Enum.map(&Atom.to_string/1)
    Contracts.digest(%{"connection" => Map.take(Store.dto(connection), fields),
      "privacy_barrier" => barrier})
  end

  # A bounded directory/component stat only; never enumerate files or read bodies.
  defp physical_root(directory, observed) do
    with false <- Repo.in_transaction?(),
         true <- observed.connection.config == %{},
         {:ok, root} <- LocalImport.approved_directory(directory),
         candidate = %{observed.connection | directory: root, config: %{}},
         digest = Contracts.digest(%{"directory" => root, "config" => %{}}),
         true <- digest == observed.set.connection_digest,
         {:ok, fingerprint} <- Capture.fingerprint_for_setup(candidate, root),
         true <- fingerprint == observed.set.root_fingerprint do
      {:ok, %{directory: root, connection_digest: digest, root_fingerprint: fingerprint}}
    else
      _ -> {:error, :connection_unavailable}
    end
  rescue
    _ -> {:error, :connection_unavailable}
  end

  # Replays do not reuse historical CAS or perform an UPDATE. Recheck current
  # availability separately, with its own physical proof outside the transaction.
  defp replay_locked(event, connection_id, attrs, context) do
    with :ok <- interactive(context),
         :ok <- readiness(),
         {:ok, observed} <- guarded(context, fn ->
           with {:ok, _} <- replay_owner(event, connection_id, attrs),
             do: {:ok, availability_observation(connection_id, attrs["policy_ref"], context)}
         end) do
      proof = availability_proof(observed)
      guarded(context, fn ->
        with {:ok, _} <- replay_owner(event, connection_id, attrs) do
          fresh = availability_observation(connection_id, attrs["policy_ref"], context)
          available = not is_nil(proof) and not is_nil(observed) and fresh == observed
          {:ok, receipt(event, connection_id, available)}
        end
      end)
    end
  end

  defp availability_observation(connection_id, policy_ref, context) do
    case observe(connection_id, policy_ref, context) do
      {:ok, %{connection: %{status: "active"}} = observed} -> observed
      _ -> nil
    end
  end

  defp availability_proof(nil), do: nil
  defp availability_proof(observed) do
    case physical_root(observed.connection.directory, observed) do
      {:ok, proof} -> proof
      _ -> nil
    end
  end

  defp replay_owner(event, connection_id, attrs) do
    with true <- event["kind"] == "connection_revalidated" and
           event["set_id"] == attrs["policy_ref"]["id"] and
           event["payload"]["policy_ref"] == attrs["policy_ref"] and
           event["payload"]["connection_id"] == connection_id,
         {:ok, set} <- Store.get(LocalUseSet, event["set_id"]),
         true <- set.owner_id == Workspaces.operator() and set.connection_id == connection_id,
         :ok <- LocalUsePolicies.frozen_integrity(set) do
      {:ok, set}
    else
      _ -> {:error, :source_use_denied}
    end
  end

  defp receipt(event, connection_id, available) do
    %{"event_ref" => %{"id" => event["id"], "digest" => event["request_digest"]},
      "connection_id" => connection_id, "current_available" => available, "use_grant" => false}
  end

  defp local_connection(id) do
    with {:ok, connection} <- Store.get(Connection, id),
         true <- connection.provider == "local" and connection.status in ~w(active revoked),
         do: {:ok, connection}, else: (_ -> {:error, :connection_unavailable})
  end

  defp input(connection_id, attrs) do
    with :ok <- Corpora.keys(attrs, @attrs),
         true <- Corpora.uuid?(connection_id) and
           attrs["version"] == "LocalConnectionRevalidation.v1" and
           Corpora.uuid?(attrs["command_id"]) and ref?(attrs["policy_ref"]) and
           is_integer(attrs["expected_generation"]) and attrs["expected_generation"] >= 1 and
           Corpora.digest?(attrs["expected_connection_state"]) and
           Corpora.text?(attrs["directory"], 4096) and
           not String.contains?(attrs["directory"], <<0>>) and
           Path.type(attrs["directory"]) == :absolute do
      :ok
    else
      _ -> {:error, :invalid_input}
    end
  end

  defp ref?(ref), do: Corpora.keys(ref, ~w(id digest)) == :ok and
    Corpora.uuid?(ref["id"]) and Corpora.digest?(ref["digest"])
  defp command_key(attrs), do: "revalidate:" <> attrs["command_id"]

  defp interactive(%SourceUseContext{} = context) do
    case SourceUseContext.validate(context, "inspection") do
      {:ok, %{kind: :interactive}} -> :ok
      _ -> {:error, :source_use_denied}
    end
  end
  defp interactive(_), do: {:error, :source_use_denied}

  defp readiness do
    with :ok <- Workspaces.ensure_writable(), :ok <- Purge.ready(), do: :ok,
      else: (_ -> {:error, :source_use_denied})
  end

  defp guarded(context, fun) do
    with :ok <- interactive(context) do
      Corpora.guard(context.caller, fn ->
        with :ok <- interactive(context),
             {:ok, result} <- fun.(),
             :ok <- interactive(context), do: {:ok, result}
      end)
      |> normalize()
    end
  rescue
    _ -> {:error, :source_use_denied}
  catch
    _, _ -> {:error, :source_use_denied}
  end

  defp synchronize(fun), do: Purge.synchronize(fun) |> normalize()
  defp normalize({:ok, _} = result), do: result
  defp normalize({:error, reason} = result) when reason in
    [:invalid_input, :source_use_denied, :connection_unavailable, :preparation_stale,
      :idempotency_conflict], do: result
  defp normalize(_), do: {:error, :source_use_denied}
end
