defmodule HarnessForge.Releases do
  @moduledoc """
  Local pilot approvals and append-only channel history.

  Approvals bind verified artifact bytes to an applicable, trusted, qualified task
  evaluation. An outcome supplied by the caller is never accepted. Every channel
  move revalidates that binding and current evidence. `expected_current_id` is the
  previous release ID; `nil` requires an empty channel. Rollback moves a pointer
  and preserves history; exporting bytes is the separate `Harnesses.export/2`.

  Workspace ownership excludes competing application processes. In-VM commands
  serialize metadata transactions, and the SQL update also compares pointer and
  version so concurrent or stale callers cannot both replace the same assignment.
  """
  import Ecto.Query
  alias Ecto.Multi
  alias HarnessForge.{Audit, Contracts, Evaluations, Harnesses, Repo, Workspaces}
  alias HarnessForge.Evidence.Store
  alias HarnessForge.Releases.{Approval, Channel, Event, Validation}

  @channel "pilot"
  @approval_inputs ~w(artifact_digest evaluation_id scope actor)

  @spec list() :: {:ok, [map()]} | {:error, term()}
  def list do
    releases =
      Repo.all(from r in Store.scoped(Approval), order_by: [desc: r.inserted_at, asc: r.id])

    releases
    |> Enum.reduce_while({:ok, []}, fn release, {:ok, acc} ->
      case approval_integrity(release) do
        :ok -> {:cont, {:ok, [dto(release) | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  @spec approve(map()) :: {:ok, map()} | {:error, term()}
  def approve(attrs) do
    with :ok <- Workspaces.ensure_writable(),
         :ok <- valid_inputs(attrs) do
      synchronized(fn ->
        Multi.new()
        |> Multi.run(:validate, fn _repo, _ -> validate_inputs(attrs) end)
        |> Multi.run(:approval, fn _repo, %{validate: {artifact, run}} ->
          insert_approval(artifact, run, attrs["actor"])
        end)
        |> Multi.run(:audit, fn _repo, %{approval: approval} ->
          Audit.append("release.approved", %{
            "release_id" => approval.id,
            "artifact_digest" => approval.payload["artifact_digest"],
            "evaluation_id" => approval.payload["evaluation_id"],
            "actor" => approval.payload["actor"],
            "status" => "approved"
          })
        end)
        |> transact(:approval, &dto/1)
      end)
    end
  end

  @spec promote(String.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def promote(release_id, expected_current_id \\ nil),
    do: assign(release_id, expected_current_id, "promote")

  @spec rollback(String.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def rollback(release_id, expected_current_id \\ nil),
    do: assign(release_id, expected_current_id, "rollback")

  @spec current(map(), String.t()) :: {:ok, map() | nil} | {:error, term()}
  def current(scope, channel \\ @channel) do
    with :ok <- valid_scope_channel(scope, channel) do
      case Repo.one(channel_query(Contracts.digest(scope), channel)) do
        nil -> {:ok, nil}
        record -> with :ok <- pointer_integrity(record), do: {:ok, Store.dto(record)}
      end
    end
  end

  @spec history(map(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def history(scope, channel \\ @channel) do
    with :ok <- valid_scope_channel(scope, channel) do
      scope_digest = Contracts.digest(scope)

      records =
        Repo.all(
          from e in Store.scoped(Event),
            where: e.scope_digest == ^scope_digest and e.channel == ^channel,
            order_by: [asc: e.version]
        )

      if history_integrity?(records),
        do: {:ok, Enum.map(records, &Map.put(&1.payload, "event_digest", &1.event_digest))},
        else: {:error, :release_history_integrity_failed}
    end
  end

  @doc "Compare verified artifact files and rule revisions without changing either package."
  @spec diff(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def diff(left_digest, right_digest) do
    with {:ok, left} <- Harnesses.get(left_digest),
         {:ok, right} <- Harnesses.get(right_digest) do
      {:ok,
       %{
         "left_digest" => left_digest,
         "right_digest" => right_digest,
         "files" => differences(left["files"], right["files"]),
         "rules" => differences(rule_map(left), rule_map(right))
       }}
    end
  end

  defp assign(release_id, expected, action) do
    with :ok <- Workspaces.ensure_writable(),
         :ok <- valid_expected(expected) do
      synchronized(fn ->
        Multi.new()
        |> Multi.run(:release, fn _repo, _ -> validate_release(release_id) end)
        |> Multi.run(:channel, fn _repo, %{release: release} -> load_channel(release) end)
        |> Multi.run(:pointer, fn _repo, %{release: release, channel: channel} ->
          move_pointer(release, channel, expected, action)
        end)
        |> Multi.run(:event, fn _repo, %{pointer: {_, event}} -> Repo.insert(event) end)
        |> Multi.run(:audit, fn _repo, %{release: release} ->
          Audit.append("release." <> action, %{
            "release_id" => release.id,
            "artifact_digest" => release.payload["artifact_digest"],
            "evaluation_id" => release.payload["evaluation_id"],
            "actor" => Workspaces.operator(),
            "status" => action
          })
        end)
        |> transact(:pointer, fn {channel, event} ->
          Store.dto(channel) |> Map.put("action", action) |> Map.put("event_id", event.id)
        end)
      end)
    end
  end

  defp validate_inputs(attrs) do
    with {:ok, artifact} <- Harnesses.get(attrs["artifact_digest"]),
         {:ok, run} <- Evaluations.get(attrs["evaluation_id"]),
         true <- run["id"] == attrs["evaluation_id"],
         :ok <- Validation.check(artifact, run, attrs["scope"]) do
      {:ok, {artifact, run}}
    else
      false -> {:error, :evaluation_identity_mismatch}
      error -> error
    end
  end

  defp insert_approval(artifact, run, actor) do
    id = Ecto.UUID.generate()
    now = Store.now()

    payload =
      Validation.bindings(artifact, run)
      |> Map.merge(%{
        "id" => id,
        "workspace_id" => Store.workspace(),
        "actor" => String.trim(actor),
        "inserted_at" => DateTime.to_iso8601(now)
      })

    Repo.insert(%Approval{
      id: id,
      workspace_id: Store.workspace(),
      artifact_digest: artifact["digest"],
      evaluation_id: run["id"],
      scope_digest: payload["scope_digest"],
      payload: payload,
      approval_digest: Contracts.digest(payload),
      inserted_at: now
    })
  end

  defp validate_release(id) do
    with {:ok, approval} <- Store.get(Approval, id),
         :ok <- approval_integrity(approval),
         {:ok, artifact} <- Harnesses.get(approval.artifact_digest),
         {:ok, run} <- Evaluations.get(approval.evaluation_id),
         :ok <- Validation.check(artifact, run, approval.payload["scope"]),
         true <-
           Map.take(approval.payload, Map.keys(Validation.bindings(artifact, run))) ==
             Validation.bindings(artifact, run) do
      {:ok, approval}
    else
      false -> {:error, :release_approval_inapplicable}
      error -> error
    end
  end

  defp approval_integrity(approval) do
    if approval.payload["id"] == approval.id and
         approval.payload["workspace_id"] == approval.workspace_id and
         approval.payload["artifact_digest"] == approval.artifact_digest and
         approval.payload["evaluation_id"] == approval.evaluation_id and
         approval.payload["scope_digest"] == approval.scope_digest and
         approval.payload["inserted_at"] == DateTime.to_iso8601(approval.inserted_at) and
         Contracts.digest(approval.payload) == approval.approval_digest,
       do: :ok,
       else: {:error, :release_approval_integrity_failed}
  end

  defp load_channel(release) do
    record = %Channel{
      workspace_id: Store.workspace(),
      scope_digest: release.scope_digest,
      channel: @channel,
      updated_at: Store.now()
    }

    with {:ok, _} <-
           Repo.insert(record,
             on_conflict: :nothing,
             conflict_target: [:workspace_id, :scope_digest, :channel]
           ) do
      record = Repo.one!(channel_query(release.scope_digest, @channel))
      with :ok <- pointer_integrity(record), do: {:ok, record}
    end
  end

  defp move_pointer(release, channel, expected, action) do
    cond do
      channel.release_id != expected ->
        {:error, :stale_channel}

      channel.release_id == release.id ->
        {:error, :already_current}

      action == "rollback" and not previously_assigned?(release, channel) ->
        {:error, :rollback_target_not_previously_assigned}

      true ->
        update_pointer(release, channel, action)
    end
  end

  defp update_pointer(release, channel, action) do
    now = Store.now()
    id = Ecto.UUID.generate()

    payload = %{
      "id" => id,
      "workspace_id" => Store.workspace(),
      "scope_digest" => release.scope_digest,
      "channel" => @channel,
      "release_id" => release.id,
      "artifact_digest" => release.artifact_digest,
      "approval_digest" => release.approval_digest,
      "previous_release_id" => channel.release_id,
      "previous_event_digest" => channel.event_digest,
      "version" => channel.version + 1,
      "action" => action,
      "actor" => Workspaces.operator(),
      "inserted_at" => DateTime.to_iso8601(now)
    }

    event = %Event{
      id: id,
      workspace_id: Store.workspace(),
      scope_digest: release.scope_digest,
      channel: @channel,
      release_id: release.id,
      previous_release_id: channel.release_id,
      action: action,
      version: channel.version + 1,
      payload: payload,
      event_digest: Contracts.digest(payload),
      inserted_at: now
    }

    query =
      from c in Store.scoped(Channel),
        where: c.id == ^channel.id and c.version == ^channel.version

    query =
      if is_nil(channel.release_id),
        do: from(c in query, where: is_nil(c.release_id)),
        else: from(c in query, where: c.release_id == ^channel.release_id)

    case Repo.update_all(query,
           set: [
             release_id: release.id,
             event_digest: event.event_digest,
             version: event.version,
             updated_at: now
           ]
         ) do
      {1, _} ->
        {:ok,
         {%{
            channel
            | release_id: release.id,
              event_digest: event.event_digest,
              version: event.version,
              updated_at: now
          }, event}}

      _ ->
        {:error, :stale_channel}
    end
  end

  defp pointer_integrity(%Channel{version: 0, release_id: nil, event_digest: nil}), do: :ok

  defp pointer_integrity(channel) do
    case Repo.one(
           from e in Store.scoped(Event),
             where:
               e.scope_digest == ^channel.scope_digest and e.channel == ^channel.channel and
                 e.version == ^channel.version
         ) do
      %Event{} = event ->
        if event.release_id == channel.release_id and event.event_digest == channel.event_digest and
             event_integrity?(event), do: :ok, else: {:error, :release_history_integrity_failed}

      _ ->
        {:error, :release_history_integrity_failed}
    end
  end

  defp previously_assigned?(release, channel),
    do:
      Repo.exists?(
        from e in Store.scoped(Event),
          where:
            e.scope_digest == ^channel.scope_digest and e.channel == ^channel.channel and
              e.release_id == ^release.id and e.version < ^channel.version
      )

  defp history_integrity?(records) do
    Enum.reduce_while(records, {true, nil, nil, 0}, fn event,
                                                       {true, previous_digest, previous_id,
                                                        version} ->
      if event_integrity?(event) and event.version == version + 1 and
           event.payload["previous_event_digest"] == previous_digest and
           event.previous_release_id == previous_id,
         do: {:cont, {true, event.event_digest, event.release_id, event.version}},
         else: {:halt, false}
    end) != false
  end

  defp event_integrity?(event) do
    event.payload["id"] == event.id and event.payload["workspace_id"] == event.workspace_id and
      event.payload["scope_digest"] == event.scope_digest and
      event.payload["channel"] == event.channel and
      event.payload["release_id"] == event.release_id and
      event.payload["previous_release_id"] == event.previous_release_id and
      event.payload["version"] == event.version and event.payload["action"] == event.action and
      event.payload["inserted_at"] == DateTime.to_iso8601(event.inserted_at) and
      Contracts.digest(event.payload) == event.event_digest
  end

  defp valid_inputs(attrs) when is_map(attrs) do
    with :ok <- Store.required(attrs, ~w(artifact_digest evaluation_id actor)),
         true <- Enum.sort(Map.keys(attrs)) == Enum.sort(@approval_inputs),
         true <- String.length(attrs["actor"]) <= 200,
         true <- Validation.digest?(attrs["artifact_digest"]),
         {:ok, _} <- Ecto.UUID.cast(attrs["evaluation_id"]),
         :ok <- valid_scope_channel(attrs["scope"], @channel) do
      :ok
    else
      _ -> {:error, :invalid_release_input}
    end
  end

  defp valid_inputs(_), do: {:error, :invalid_release_input}

  defp valid_scope_channel(%{"repositories" => repositories} = scope, @channel)
       when map_size(scope) == 1 and is_list(repositories) and repositories != [] do
    if Enum.all?(repositories, &(is_binary(&1) and byte_size(&1) in 1..500)),
      do: :ok,
      else: {:error, :invalid_release_scope}
  end

  defp valid_scope_channel(_, _), do: {:error, :invalid_release_scope}
  defp valid_expected(nil), do: :ok

  defp valid_expected(id) do
    case Ecto.UUID.cast(id) do
      {:ok, _} -> :ok
      _ -> {:error, :invalid_expected_release}
    end
  end

  defp channel_query(scope_digest, channel),
    do:
      from(c in Store.scoped(Channel),
        where: c.scope_digest == ^scope_digest and c.channel == ^channel
      )

  defp dto(approval), do: Map.put(approval.payload, "approval_digest", approval.approval_digest)
  defp rule_map(artifact), do: Map.new(artifact["spec"]["spec"]["rules"], &{&1["id"], &1})

  defp differences(left, right) do
    left_keys = Map.keys(left)
    right_keys = Map.keys(right)

    %{
      "added" => Enum.sort(right_keys -- left_keys),
      "removed" => Enum.sort(left_keys -- right_keys),
      "changed" =>
        Enum.filter(left_keys -- (left_keys -- right_keys), &(left[&1] != right[&1]))
        |> Enum.sort()
    }
  end

  defp synchronized(fun), do: :global.trans({{__MODULE__, Store.workspace()}, self()}, fun)

  defp transact(multi, key, map_fun) do
    case Repo.transaction(multi) do
      {:ok, result} -> {:ok, map_fun.(result[key])}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end
end
