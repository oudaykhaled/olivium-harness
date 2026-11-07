defmodule HarnessForge.Execution.CommandApprovals do
  @moduledoc """
  Workspace-owned, exact native-command decisions with one accepted handoff.

  Imported/native payloads are data. Only the server-owned running Codex run and
  its current artifact/profile supply authority. Poll commits consumption before
  returning accept; a lost or withdrawn response is never retried as acceptance.
  This establishes at most one accepted response, not exactly-once execution.
  """
  import Ecto.Query
  alias HarnessForge.{Audit, Contracts, Harnesses, Repo, Workspaces}
  alias HarnessForge.Evaluation.Run
  alias HarnessForge.Evidence.Store
  alias HarnessForge.Execution.{Coding, CommandApproval}
  alias HarnessForge.Privacy.Purge

  @payload_keys ~w(json_rpc_id thread_id turn_id item_id approval_id environment_id command cwd driver_nonce provider_response_id original_arguments original_arguments_digest native_context_digest)
  @envelope_keys ~w(run_id id request_digest decision)
  @max_requests 32
  @safe_integer 9_007_199_254_740_991
  @profile "docker-codex-isolated-v1"
  @type caller :: [authorize: (-> boolean())]
  @type result :: {:ok, map() | [map()]} | {:error, atom()}

  @spec request(String.t(), map(), DateTime.t(), caller()) :: result()
  def request(run_id, payload, expires_at, caller) do
    with :ok <- valid_uuid(run_id),
         :ok <- valid_payload(payload),
         true <- match?(%DateTime{time_zone: "Etc/UTC"}, expires_at) do
      guarded(run_id, caller, fn authority ->
        key = native_request_key(payload)
        digest = fingerprint(authority, payload)

        case by_native_key(authority.run_id, key) do
          nil ->
            create(authority, payload, key, digest, expires_at)

          record ->
            with :ok <- valid_record(record, authority),
                 true <- record.request_digest == digest do
              {:ok, dto(record)}
            else
              false -> {:error, :command_approval_conflict}
              error -> error
            end
        end
      end)
    else
      _ -> {:error, :invalid_command_approval}
    end
  end

  @spec list(String.t(), caller()) :: result()
  def list(run_id, caller) do
    with :ok <- valid_uuid(run_id) do
      guarded(run_id, caller, fn authority ->
        records =
          Repo.all(
            from a in CommandApproval,
              where: a.workspace_id == ^authority.workspace_id and a.run_id == ^authority.run_id,
              order_by: [asc: a.inserted_at, asc: a.id],
              limit: @max_requests
          )

        with true <- Enum.all?(records, &(valid_record(&1, authority) == :ok)),
             do: {:ok, Enum.map(records, &dto/1)},
             else: (_ -> {:error, :command_approval_unavailable})
      end)
    end
  end

  @spec decide(map(), caller()) :: result()
  def decide(envelope, caller) do
    with :ok <- valid_envelope(envelope) do
      guarded(envelope["run_id"], caller, fn authority ->
        with {:ok, record} <- owned(envelope["id"], authority),
             true <- record.request_digest == envelope["request_digest"],
             true <- live?(record) do
          apply_decision(record, envelope["decision"], authority)
        else
          false -> decision_failure(envelope, authority)
          error -> error
        end
      end)
    end
  end

  @spec poll(String.t(), String.t(), caller()) :: result()
  def poll(run_id, id, caller) do
    with :ok <- valid_uuid(run_id), :ok <- valid_uuid(id) do
      guarded(run_id, caller, fn authority ->
        with {:ok, record} <- owned(id, authority) do
          cond do
            record.state in ["pending", "accepted"] and not live?(record) ->
              expire(record, authority)

            record.state == "accepted" ->
              consume(record, authority)

            record.state == "pending" ->
              {:ok, Map.put(dto(record), "decision", nil)}

            true ->
              {:ok, Map.put(dto(record), "decision", "decline")}
          end
        end
      end)
    end
  end

  # All entry points own their transaction: accepting an enclosing caller's SQL
  # transaction could expose an accept before its consumption actually commits.
  defp guarded(run_id, caller, action) do
    workspace = Workspaces.current_id()

    with :ok <- valid_caller(caller),
         :ok <- authorized(caller, workspace),
         false <- Repo.in_transaction?() do
      Purge.synchronize(fn ->
        with :ok <- authorized(caller, workspace),
             :ok <- ready(),
             {:ok, {result, committed_authority}} <-
               Store.transaction(fn ->
                 with :ok <- authorized(caller, workspace),
                      :ok <- ready(),
                      {:ok, authority} <- current_run(run_id, workspace),
                      {:ok, value} <- action.(authority),
                      :ok <- authorized(caller, workspace),
                      :ok <- ready(),
                      do: {:ok, {value, authority}}
               end),
             :ok <- authorized(caller, workspace),
             :ok <- ready(),
             {:ok, _} <-
               Store.transaction(fn ->
                 with :ok <- authorized(caller, workspace),
                      {:ok, authority} <- current_run(run_id, workspace),
                      :ok <- same_authority(authority, committed_authority),
                      :ok <- authorized(caller, workspace),
                      :ok <- ready(),
                      do: {:ok, authority}
               end),
             :ok <- authorized(caller, workspace),
             :ok <- publishable(result),
             do: {:ok, result}
      end)
    else
      true -> {:error, :command_approval_requires_outermost_transaction}
      error -> error
    end
  rescue
    _ -> {:error, :command_approval_unavailable}
  catch
    _, _ -> {:error, :command_approval_unavailable}
  end

  defp current_run(run_id, workspace) do
    with %Run{} = run <-
           Repo.one(
             from r in Run, where: r.workspace_id == ^workspace and r.id == ^normalize_id(run_id)
           ),
         true <- run.result["id"] == run.id and run.result["workspace_id"] == workspace,
         true <-
           run.result["artifact_digest"] == run.artifact_digest and digest?(run.artifact_digest),
         true <-
           run.result["outcome"] == "running" and run.result["kind"] == "task" and
             run.result["runtime_name"] == "codex",
         true <- run.result["execution_profile_id"] == @profile,
         true <- digest?(run.result["environment_profile_digest"]),
         {:ok, observation} <-
           Coding.decode_context(run.execution_context, run.result, workspace, run.id),
         true <- Coding.profile_digest(observation) == run.result["environment_profile_digest"],
         {:ok, artifact} <- Harnesses.get(run.artifact_digest),
         true <- artifact["digest"] == run.artifact_digest,
         true <- get_in(artifact, ["spec", "spec", "runtime", "name"]) == "codex",
         :ok <- Harnesses.eligible(artifact) do
      {:ok,
       %{
         workspace_id: workspace,
         run_id: run.id,
         artifact_digest: run.artifact_digest,
         profile_digest: run.result["environment_profile_digest"]
       }}
    else
      _ -> {:error, :command_approval_run_unavailable}
    end
  end

  defp same_authority(authority, expected) when authority === expected, do: :ok
  defp same_authority(_, _), do: {:error, :command_approval_run_unavailable}

  # Authorization/currentness may take time after consumption commits. A lost
  # deadline keeps the row consumed but cannot publish an expired acceptance.
  defp publishable(%{"decision" => "accept", "expires_at" => expires_at}) do
    with {:ok, expires, 0} <- DateTime.from_iso8601(expires_at),
         true <- DateTime.compare(expires, DateTime.utc_now()) == :gt,
         do: :ok,
         else: (_ -> {:error, :command_approval_expired})
  end

  defp publishable(_), do: :ok

  defp create(authority, payload, key, digest, expires_at) do
    now = DateTime.utc_now()

    count =
      Repo.aggregate(
        from(a in CommandApproval,
          where: a.workspace_id == ^authority.workspace_id and a.run_id == ^authority.run_id
        ),
        :count
      )

    cond do
      DateTime.compare(expires_at, now) != :gt or
          DateTime.diff(expires_at, now, :microsecond) > 120_000_000 ->
        {:error, :invalid_command_approval}

      count >= @max_requests ->
        {:error, :command_approval_limit}

      true ->
        attrs =
          Map.merge(
            Map.take(authority, ~w(workspace_id run_id artifact_digest profile_digest)a),
            %{
              native_request_key: key,
              request_digest: digest,
              payload: payload,
              expires_at: expires_at
            }
          )

        with {:ok, record} <- Repo.insert(CommandApproval.changeset(attrs)),
             :ok <- audit("requested", record),
             do: {:ok, dto(record)},
             else: (_ -> {:error, :command_approval_unavailable})
    end
  end

  defp apply_decision(%{state: "pending"} = record, decision, authority) do
    now = DateTime.utc_now()
    state = if decision == "accept_once", do: "accepted", else: "declined"

    query =
      from a in CommandApproval,
        where:
          a.workspace_id == ^authority.workspace_id and a.id == ^record.id and
            a.run_id == ^authority.run_id and
            a.request_digest == ^record.request_digest and a.state == "pending" and
            a.expires_at > ^now

    with {1, _} <-
           Repo.update_all(query,
             set: [
               state: state,
               decided_at: now,
               decision_owner: Workspaces.operator(),
               updated_at: now
             ]
           ),
         {:ok, saved} <- owned(record.id, authority),
         :ok <- audit(state, saved),
         do: {:ok, dto(saved)},
         else: (_ -> {:error, :command_approval_conflict})
  end

  defp apply_decision(record, decision, _authority) do
    same? =
      record.decision_owner == Workspaces.operator() and
        ((decision == "accept_once" and record.state in ["accepted", "consumed"]) or
           (decision == "decline" and record.state == "declined"))

    if same?, do: {:ok, dto(record)}, else: {:error, :command_approval_already_decided}
  end

  defp decision_failure(envelope, authority) do
    case owned(envelope["id"], authority) do
      {:ok, record} ->
        if record.request_digest != envelope["request_digest"],
          do: {:error, :command_approval_conflict},
          else: {:error, :command_approval_expired}

      error ->
        error
    end
  end

  defp consume(record, authority) do
    now = DateTime.utc_now()

    query =
      from a in CommandApproval,
        where:
          a.workspace_id == ^authority.workspace_id and a.run_id == ^authority.run_id and
            a.id == ^record.id and
            a.request_digest == ^record.request_digest and a.state == "accepted" and
            a.decision_owner == ^Workspaces.operator() and a.expires_at > ^now

    with {1, _} <-
           Repo.update_all(query, set: [state: "consumed", consumed_at: now, updated_at: now]),
         {:ok, saved} <- owned(record.id, authority),
         :ok <- audit("consumed", saved),
         do: {:ok, Map.put(dto(saved), "decision", "accept")},
         else: (_ -> {:error, :command_approval_unavailable})
  end

  defp expire(record, authority) do
    now = DateTime.utc_now()

    query =
      from a in CommandApproval,
        where:
          a.workspace_id == ^authority.workspace_id and a.run_id == ^authority.run_id and
            a.id == ^record.id and
            a.request_digest == ^record.request_digest and a.state in ["pending", "accepted"] and
            a.expires_at <= ^now

    with {1, _} <-
           Repo.update_all(query,
             set: [state: "declined", decided_at: record.decided_at || now, updated_at: now]
           ),
         {:ok, saved} <- owned(record.id, authority),
         :ok <- audit("expired", saved),
         do: {:ok, Map.put(dto(saved), "decision", "decline")},
         else: (_ -> {:error, :command_approval_unavailable})
  end

  defp owned(id, authority) do
    case Repo.one(
           from a in CommandApproval,
             where:
               a.workspace_id == ^authority.workspace_id and
                 a.run_id == ^authority.run_id and a.id == ^normalize_id(id)
         ) do
      nil -> {:error, :command_approval_not_found}
      record -> with :ok <- valid_record(record, authority), do: {:ok, record}
    end
  end

  defp by_native_key(run_id, key),
    do:
      Repo.one(
        from a in CommandApproval,
          where:
            a.workspace_id == ^Workspaces.current_id() and a.run_id == ^run_id and
              a.native_request_key == ^key
      )

  defp valid_record(record, authority) do
    with :ok <- valid_uuid(record.id),
         true <-
           record.workspace_id == authority.workspace_id and record.run_id == authority.run_id and
             record.artifact_digest == authority.artifact_digest and
             record.profile_digest == authority.profile_digest,
         :ok <- valid_payload(record.payload),
         true <-
           record.native_request_key == native_request_key(record.payload) and
             record.request_digest == fingerprint(authority, record.payload),
         true <-
           match?(%DateTime{}, record.expires_at) and match?(%DateTime{}, record.inserted_at),
         delta = DateTime.diff(record.expires_at, record.inserted_at, :microsecond),
         true <- delta > 0 and delta <= 120_000_000,
         true <- valid_state?(record),
         do: :ok,
         else: (_ -> {:error, :command_approval_unavailable})
  end

  defp valid_state?(%{state: "pending", decided_at: nil, consumed_at: nil, decision_owner: nil}),
    do: true

  defp valid_state?(%{
         state: "accepted",
         decided_at: %DateTime{},
         consumed_at: nil,
         decision_owner: owner
       }),
       do: owner == Workspaces.operator()

  defp valid_state?(%{
         state: "declined",
         decided_at: %DateTime{},
         consumed_at: nil,
         decision_owner: owner
       }),
       do: owner in [nil, Workspaces.operator()]

  defp valid_state?(%{
         state: "consumed",
         decided_at: %DateTime{},
         consumed_at: %DateTime{},
         decision_owner: owner
       }),
       do: owner == Workspaces.operator()

  defp valid_state?(_), do: false

  defp fingerprint(authority, payload),
    do:
      Contracts.digest(%{
        "run_id" => authority.run_id,
        "artifact_digest" => authority.artifact_digest,
        "profile_digest" => authority.profile_digest,
        "payload" => payload
      })

  defp native_request_key(payload),
    do:
      Contracts.digest(%{
        "driver_nonce" => payload["driver_nonce"],
        "json_rpc_id" => payload["json_rpc_id"]
      })

  defp live?(record), do: DateTime.compare(record.expires_at, DateTime.utc_now()) == :gt

  defp dto(record),
    do: %{
      "id" => record.id,
      "run_id" => record.run_id,
      "artifact_digest" => record.artifact_digest,
      "profile_digest" => record.profile_digest,
      "request_digest" => record.request_digest,
      "payload" => record.payload,
      "state" => record.state,
      "expires_at" => DateTime.to_iso8601(record.expires_at),
      "decided_at" => timestamp(record.decided_at),
      "consumed_at" => timestamp(record.consumed_at)
    }

  defp timestamp(nil), do: nil
  defp timestamp(%DateTime{} = time), do: DateTime.to_iso8601(time)

  defp audit(status, record) do
    case Audit.append("command_approval." <> status, %{
           "run_id" => record.run_id,
           "approval_id" => record.id,
           "artifact_digest" => record.artifact_digest,
           "profile_digest" => record.profile_digest,
           "request_digest" => record.request_digest,
           "status" => status
         }) do
      {:ok, _} -> :ok
      _ -> {:error, :command_approval_unavailable}
    end
  end

  defp valid_envelope(value) do
    with true <- exact_keys?(value, @envelope_keys),
         :ok <- valid_uuid(value["id"]),
         :ok <- valid_uuid(value["run_id"]),
         true <- digest?(value["request_digest"]),
         true <- value["decision"] in ["accept_once", "decline"],
         do: :ok,
         else: (_ -> {:error, :invalid_command_approval})
  end

  defp valid_payload(value) do
    with true <- exact_keys?(value, @payload_keys),
         true <- rpc_id?(value["json_rpc_id"]),
         true <- Enum.all?(~w(thread_id turn_id item_id), &id_text?(value[&1])),
         true <-
           Enum.all?(~w(approval_id environment_id), &(is_nil(value[&1]) or id_text?(value[&1]))),
         true <-
           is_binary(value["command"]) and byte_size(value["command"]) in 1..4096 and
             String.valid?(value["command"]),
         false <- Regex.match?(~r/[\x00-\x09\x0B-\x1F\x7F-\x{9F}]/u, value["command"]),
         true <- value["cwd"] == "/candidate",
         true <- nonce?(value["driver_nonce"]) and id_text?(value["provider_response_id"]),
         true <-
           digest?(value["original_arguments_digest"]) and digest?(value["native_context_digest"]),
         true <-
           is_binary(value["original_arguments"]) and
             byte_size(value["original_arguments"]) in 1..8192 and
             String.valid?(value["original_arguments"]),
         {:ok, arguments} <- Contracts.decode_json(value["original_arguments"]),
         true <- is_map(arguments) and not is_struct(arguments),
         true <-
           Contracts.sha256(value["original_arguments"]) == value["original_arguments_digest"],
         true <- byte_size(Contracts.canonical_json(value)) <= 16384,
         do: :ok,
         else: (_ -> {:error, :invalid_command_approval})
  rescue
    _ -> {:error, :invalid_command_approval}
  end

  defp rpc_id?(id) when is_integer(id), do: id in -@safe_integer..@safe_integer
  defp rpc_id?(id) when is_binary(id), do: byte_size(id) <= 128 and String.valid?(id)
  defp rpc_id?(_), do: false

  defp id_text?(value),
    do: is_binary(value) and byte_size(value) in 1..128 and String.valid?(value)

  defp exact_keys?(map, keys),
    do: is_map(map) and not is_struct(map) and Enum.sort(Map.keys(map)) == Enum.sort(keys)

  defp valid_uuid(id),
    do:
      if(is_binary(id) and byte_size(id) == 36 and match?({:ok, _}, Ecto.UUID.cast(id)),
        do: :ok,
        else: {:error, :invalid_command_approval}
      )

  defp normalize_id(id), do: id |> Ecto.UUID.cast() |> elem(1)
  defp digest?(value), do: is_binary(value) and Regex.match?(~r/\A[a-f0-9]{64}\z/, value)
  defp nonce?(value), do: is_binary(value) and Regex.match?(~r/\A[a-f0-9]{32}\z/, value)

  defp valid_caller(caller),
    do:
      if(
        is_list(caller) and Keyword.keyword?(caller) and Keyword.keys(caller) == [:authorize] and
          is_function(caller[:authorize], 0),
        do: :ok,
        else: {:error, :command_approval_unauthorized}
      )

  defp authorized(caller, workspace) do
    if Workspaces.current_id() == workspace and caller[:authorize].() === true and
         Workspaces.current_id() == workspace,
       do: :ok,
       else: {:error, :command_approval_unauthorized}
  rescue
    _ -> {:error, :command_approval_unauthorized}
  catch
    _, _ -> {:error, :command_approval_unauthorized}
  end

  defp ready,
    do:
      if(Workspaces.ensure_writable() == :ok and Purge.ready() == :ok,
        do: :ok,
        else: {:error, :command_approval_unavailable}
      )
end
