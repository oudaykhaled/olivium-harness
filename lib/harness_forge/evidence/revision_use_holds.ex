defmodule HarnessForge.Evidence.RevisionUseHolds do
  @moduledoc """
  Evidence-owned, deny-only restrictions for one exact source revision.

  Restrictions and cleanup checkpoints are durable. Cleanup never grants access,
  removes a restriction, or claims that stored bytes have been erased. The read
  predicates add a denial to the caller's existing authorization; `:ok` supplies
  no positive permission. They deliberately open no transaction or privacy fence
  so an owning operation can use them without nested rollback side effects.
  """

  alias HarnessForge.{Contracts, Repo, Workspaces}
  alias HarnessForge.Company.AssessmentAttempts
  alias HarnessForge.Connectors.Registry
  alias HarnessForge.Evidence.{Corpora, Store}
  alias HarnessForge.Privacy.Purge

  @purposes ~w(inspection retrieval analysis compile)
  @fields ~w(version source_id revision_id body_hash expected_generation command_id reason_code)
  @unavailable {:error, :revision_use_state_unavailable}
  @hold_columns "h.*, k.workspace_id AS cleanup_workspace_id, k.state AS cleanup_state, k.cursor AS cleanup_cursor, k.lock_version AS cleanup_version"
  @hold_join " LEFT JOIN revision_use_cleanup k ON k.event_id=h.id AND k.workspace_id=h.workspace_id "

  @type result :: {:ok, map()} | {:error, atom()}

  @doc "Restrict all four content-use purposes; the server resolves identity and actor."
  @spec restrict(map(), keyword()) :: result()
  def restrict(attrs, caller) do
    with :ok <- validate_request(attrs) do
      guarded(caller, true, fn -> restrict_in_transaction(normalize_ids(attrs)) end)
    end
  end

  @doc "Read the current metadata-only receipt for an authenticated workspace event."
  @spec status(String.t(), keyword()) :: result()
  def status(event_id, caller) do
    with :ok <- valid_event(event_id) do
      guarded(caller, false, fn ->
        with {:ok, hold} <- event(normalize_id(event_id)), do: receipt(hold)
      end)
    end
  end

  @doc "Commit at most 100 corpus invalidations and their checkpoint in one transaction."
  @spec resume(String.t(), non_neg_integer(), keyword()) :: result()
  def resume(event_id, expected_version, caller) do
    with :ok <- valid_event(event_id),
         true <- is_integer(expected_version) and expected_version >= 0 do
      guarded(caller, true, fn ->
        with {:ok, hold} <- event(normalize_id(event_id)),
             {:ok, _} <- receipt(hold) do
          resume_in_transaction(hold, expected_version)
        end
      end)
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  @doc "Additional denial for an exact revision; does not establish underlying permission."
  @spec assert_use(String.t(), String.t(), String.t(), String.t()) :: :ok | {:error, atom()}
  def assert_use(source_id, revision_id, body_hash, purpose) do
    with true <- uuid?(source_id) and uuid?(revision_id) and digest?(body_hash),
         true <- purpose in @purposes,
         [reference] <-
           rows(
             "SELECT r.id, r.body_hash FROM evidence_revisions r JOIN evidence_sources s ON s.id=r.source_id AND s.workspace_id=r.workspace_id WHERE r.workspace_id=? AND r.source_id=? AND r.id=? AND r.body_hash=?",
             [Store.workspace(), normalize_id(source_id), normalize_id(revision_id), body_hash]
           ),
         found =
           rows(
             "SELECT h.* FROM revision_use_holds h WHERE h.workspace_id=? AND h.source_id=? AND h.revision_id=?",
             [Store.workspace(), normalize_id(source_id), reference["id"]]
           ) do
      deny_found(found, body_hash)
    else
      false -> {:error, :invalid_input}
      [] -> {:error, :source_unavailable}
      _ -> @unavailable
    end
  rescue
    _ -> @unavailable
  catch
    _, _ -> @unavailable
  end

  @doc "Any hold for this existing source blocks recapture, including unchanged bytes."
  @spec assert_source_unheld(String.t()) :: :ok | {:error, atom()}
  def assert_source_unheld(source_id) do
    if uuid?(source_id) do
      case rows(
             "SELECT s.id AS reference_source_id,h.* FROM evidence_sources s LEFT JOIN revision_use_holds h ON h.workspace_id=s.workspace_id AND h.source_id=s.id WHERE s.workspace_id=? AND s.id=? LIMIT 1",
             [Store.workspace(), normalize_id(source_id)]
           ) do
        [%{"id" => nil}] -> :ok
        [hold] -> deny_found([hold])
        [] -> {:error, :source_unavailable}
        _ -> @unavailable
      end
    else
      {:error, :invalid_input}
    end
  rescue
    _ -> @unavailable
  catch
    _, _ -> @unavailable
  end

  @doc "Fence active or denied held members before asynchronous cleanup; removed stays excluded."
  @spec assert_corpus_unheld(String.t()) :: :ok | {:error, atom()}
  def assert_corpus_unheld(corpus_id) do
    with true <- uuid?(corpus_id),
         [_] <-
           rows("SELECT id FROM corpora WHERE workspace_id=? AND id=?", [
             Store.workspace(),
             normalize_id(corpus_id)
           ]) do
      found =
        rows(
          "SELECT h.*, r.body_hash AS member_body_hash FROM corpus_members m JOIN evidence_revisions r ON r.workspace_id=m.workspace_id AND r.source_id=m.source_id AND r.id=m.revision_id JOIN revision_use_holds h ON h.workspace_id=m.workspace_id AND h.source_id=m.source_id AND h.revision_id=m.revision_id WHERE m.workspace_id=? AND m.corpus_id=? AND m.status IN ('active','denied') LIMIT 1",
          [Store.workspace(), normalize_id(corpus_id)]
        )

      cond do
        found == [] ->
          :ok

        Enum.all?(found, &(valid_hold?(&1) and &1["body_hash"] == &1["member_body_hash"])) ->
          {:error, :revision_use_denied}

        true ->
          @unavailable
      end
    else
      false -> {:error, :invalid_input}
      [] -> {:error, :invalid_scope}
      _ -> @unavailable
    end
  rescue
    _ -> @unavailable
  catch
    _, _ -> @unavailable
  end

  @doc "Internal SQL revision predicate; callers must still enforce all existing authorization."
  @spec not_held_sql(String.t()) :: String.t()
  def not_held_sql(revision_alias) do
    if revision_alias in ["r", "evidence_revisions"] do
      "NOT EXISTS (SELECT 1 FROM revision_use_holds revision_hold WHERE " <>
        "revision_hold.workspace_id=#{revision_alias}.workspace_id AND " <>
        "revision_hold.source_id=#{revision_alias}.source_id AND " <>
        "revision_hold.revision_id=#{revision_alias}.id)"
    else
      raise ArgumentError, "expected a trusted internal revision alias"
    end
  end

  defp restrict_in_transaction(attrs) do
    with {:ok, identity} <- identity(attrs),
         digest = request_digest(attrs, identity) do
      case rows(
             "SELECT #{@hold_columns} FROM revision_use_holds h #{@hold_join} WHERE h.workspace_id=? AND h.command_id=?",
             [Store.workspace(), attrs["command_id"]]
           ) do
        [hold] ->
          if hold["request_digest"] == digest,
            do: receipt(hold),
            else: {:error, :command_conflict}

        [] ->
          create_hold(attrs, identity, digest)

        _ ->
          @unavailable
      end
    end
  end

  defp create_hold(attrs, identity, digest) do
    with true <- identity["current"],
         :ok <- assert_source_unheld(identity["source_id"]) do
      event_id = Ecto.UUID.generate()
      now = Corpora.now()

      query!(
        "INSERT INTO revision_use_holds(id,workspace_id,connection_id,provider,external_id,source_id,revision_id,body_hash,command_id,request_digest,schema_version,policy_generation,denied_purposes,reason_code,actor,inserted_at) VALUES(?,?,?,?,?,?,?,?,?,?,1,1,?,'operator_restriction',?,?)",
        [
          event_id,
          Store.workspace(),
          identity["connection_id"],
          identity["provider"],
          identity["external_id"],
          identity["source_id"],
          identity["revision_id"],
          identity["body_hash"],
          attrs["command_id"],
          digest,
          Jason.encode!(@purposes),
          Workspaces.operator(),
          now
        ]
      )

      query!(
        "INSERT INTO revision_use_cleanup(event_id,workspace_id,state,cursor,lock_version,updated_at) VALUES(?,?,'pending','',0,?)",
        [event_id, Store.workspace(), now]
      )

      with {:ok, hold} <- event(event_id), do: receipt(hold)
    else
      false -> {:error, :stale_revision}
      {:error, :revision_use_denied} -> {:error, :stale_generation}
      error -> error
    end
  end

  # This is intentionally a private metadata projection. Store.get(Revision, ...)
  # would hydrate body bytes and a public content getter must honor this hold.
  defp identity(attrs) do
    case rows(
           "SELECT s.id AS source_id,s.connection_id,s.provider,s.external_id,s.latest_revision_id,s.status AS source_status,r.id AS revision_id,r.body_hash,r.source_url,r.metadata,c.provider AS connection_provider,c.status AS connection_status,c.config FROM evidence_sources s JOIN evidence_revisions r ON r.source_id=s.id AND r.workspace_id=s.workspace_id JOIN source_connections c ON c.id=s.connection_id AND c.workspace_id=s.workspace_id WHERE s.workspace_id=? AND s.id=? AND r.id=? AND r.body_hash=?",
           [Store.workspace(), attrs["source_id"], attrs["revision_id"], attrs["body_hash"]]
         ) do
      [row] ->
        with true <- row["provider"] == row["connection_provider"],
             {:ok, metadata} <- decode_map(row["metadata"]),
             {:ok, config} <- decode_map(row["config"]),
             :ok <-
               Registry.document_scope(
                 %{id: row["connection_id"], provider: row["provider"], config: config},
                 %{
                   "external_id" => row["external_id"],
                   "source_url" => row["source_url"],
                   "metadata" => metadata
                 }
               ) do
          {:ok,
           Map.put(
             row,
             "current",
             row["latest_revision_id"] == row["revision_id"] and
               row["source_status"] == "active" and row["connection_status"] == "active"
           )}
        else
          _ -> {:error, :source_unavailable}
        end

      [] ->
        {:error, :not_found}

      _ ->
        @unavailable
    end
  end

  defp request_digest(attrs, identity) do
    attrs
    |> Map.merge(
      Map.take(identity, ~w(connection_id provider external_id source_id revision_id body_hash))
    )
    |> Map.put("workspace_id", Store.workspace())
    |> Map.put("actor", Workspaces.operator())
    |> Contracts.digest()
  end

  defp resume_in_transaction(hold, expected) do
    cond do
      expected > hold["cleanup_version"] ->
        {:error, :version_conflict}

      expected < hold["cleanup_version"] or hold["cleanup_state"] == "completed" ->
        receipt(hold)

      true ->
        # The conditional first write serializes a page before its effects.
        # Any page/checkpoint/auth failure rolls this version claim back too.
        claimed =
          query!(
            "UPDATE revision_use_cleanup SET lock_version=lock_version+1,updated_at=? WHERE workspace_id=? AND event_id=? AND state='pending' AND lock_version=?",
            [Corpora.now(), Store.workspace(), hold["id"], expected]
          )

        if claimed.num_rows == 1 do
          with {:ok, page} <-
                 Corpora.invalidate_source_page(
                   hold["source_id"],
                   :scope_changed,
                   hold["cleanup_cursor"]
                 ),
               :ok <- checkpoint(hold["id"], expected + 1, page),
               {:ok, current} <- event(hold["id"]) do
            receipt(current)
          end
        else
          {:error, :version_conflict}
        end
    end
  end

  defp checkpoint(event_id, version, %{"next_cursor" => cursor, "done" => done})
       when is_binary(cursor) and is_boolean(done) do
    if cursor == "" or uuid?(cursor) do
      changed =
        query!(
          "UPDATE revision_use_cleanup SET state=?,cursor=?,updated_at=? WHERE workspace_id=? AND event_id=? AND lock_version=?",
          [
            if(done, do: "completed", else: "pending"),
            cursor,
            Corpora.now(),
            Store.workspace(),
            event_id,
            version
          ]
        )

      if changed.num_rows == 1, do: :ok, else: {:error, :version_conflict}
    else
      @unavailable
    end
  end

  defp checkpoint(_, _, _), do: @unavailable

  defp event(event_id) do
    case rows(
           "SELECT #{@hold_columns} FROM revision_use_holds h #{@hold_join} WHERE h.workspace_id=? AND h.id=?",
           [Store.workspace(), event_id]
         ) do
      [hold] -> {:ok, hold}
      [] -> {:error, :not_found}
      _ -> @unavailable
    end
  end

  defp receipt(hold) do
    if valid_hold?(hold) and hold["cleanup_workspace_id"] == Store.workspace() and
         hold["cleanup_state"] in ~w(pending completed) and
         is_integer(hold["cleanup_version"]) and hold["cleanup_version"] >= 0 and
         is_binary(hold["cleanup_cursor"]) and
         (hold["cleanup_cursor"] == "" or uuid?(hold["cleanup_cursor"])) do
      {:ok,
       %{
         "version" => 1,
         "event_id" => hold["id"],
         "source_id" => hold["source_id"],
         "revision_id" => hold["revision_id"],
         "body_hash" => hold["body_hash"],
         "policy_generation" => 1,
         "denied_purposes" => @purposes,
         "cleanup_state" => hold["cleanup_state"],
         "cleanup_version" => hold["cleanup_version"]
       }}
    else
      @unavailable
    end
  end

  defp deny_found(found, body_hash \\ nil)
  defp deny_found([], _), do: :ok

  defp deny_found(found, body_hash) do
    if Enum.all?(
         found,
         &(valid_hold?(&1) and (is_nil(body_hash) or &1["body_hash"] == body_hash))
       ),
       do: {:error, :revision_use_denied},
       else: @unavailable
  end

  defp valid_hold?(hold) do
    hold["workspace_id"] == Store.workspace() and
      Enum.all?(~w(id connection_id source_id revision_id command_id), &uuid?(hold[&1])) and
      digest?(hold["body_hash"]) and digest?(hold["request_digest"]) and
      hold["schema_version"] === 1 and hold["policy_generation"] === 1 and
      hold["reason_code"] == "operator_restriction" and
      is_binary(hold["actor"]) and hold["actor"] != "" and
      is_binary(hold["provider"]) and hold["provider"] != "" and
      is_binary(hold["external_id"]) and hold["external_id"] != "" and
      decode_purposes(hold["denied_purposes"]) == {:ok, @purposes}
  end

  defp guarded(caller, write?, fun) do
    with :ok <- AssessmentAttempts.options(caller),
         :ok <- AssessmentAttempts.authorize(caller),
         false <- Repo.in_transaction?() do
      Purge.synchronize(fn ->
        Store.transaction(fn ->
          with :ok <- writable(write?),
               :ok <- Purge.ready(),
               :ok <- AssessmentAttempts.authorize(caller),
               {:ok, result} <- fun.(),
               :ok <- AssessmentAttempts.authorize(caller),
               :ok <- Purge.ready() do
            {:ok, result}
          end
        end)
      end)
    else
      true -> {:error, :revision_use_requires_outermost_transaction}
      error -> error
    end
  rescue
    _ -> @unavailable
  catch
    _, _ -> @unavailable
  end

  defp writable(true), do: Workspaces.ensure_writable()
  defp writable(false), do: :ok

  defp validate_request(attrs) do
    with :ok <- Corpora.keys(attrs, @fields),
         true <- attrs["version"] === 1 and attrs["expected_generation"] === 0,
         true <- Enum.all?(~w(source_id revision_id command_id), &uuid?(attrs[&1])),
         true <- digest?(attrs["body_hash"]),
         true <- attrs["reason_code"] == "operator_restriction" do
      :ok
    else
      _ -> {:error, :invalid_input}
    end
  end

  defp valid_event(id), do: if(uuid?(id), do: :ok, else: {:error, :invalid_input})

  defp uuid?(value),
    do:
      is_binary(value) and byte_size(value) == 36 and
        Regex.match?(
          ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/,
          value
        ) and
        match?({:ok, _}, Ecto.UUID.cast(value))

  defp digest?(value), do: Corpora.digest?(value)
  defp normalize_id(id), do: id |> Ecto.UUID.cast() |> elem(1)

  defp normalize_ids(attrs),
    do:
      Enum.reduce(
        ~w(source_id revision_id command_id),
        attrs,
        &Map.update!(&2, &1, fn id -> normalize_id(id) end)
      )

  defp decode_map(value) when is_map(value) and not is_struct(value), do: {:ok, value}

  defp decode_map(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _ -> @unavailable
    end
  end

  defp decode_map(_), do: @unavailable

  defp decode_purposes(value) when is_list(value), do: {:ok, value}
  defp decode_purposes(value) when is_binary(value), do: Jason.decode(value)
  defp decode_purposes(_), do: @unavailable

  defp rows(sql, params) do
    %{columns: columns, rows: rows} = query!(sql, params)
    Enum.map(rows, &Map.new(Enum.zip(columns, &1)))
  end

  defp query!(sql, params), do: Repo.query!(sql, params, log: false)
end
