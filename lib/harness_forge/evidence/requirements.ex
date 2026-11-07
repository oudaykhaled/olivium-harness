defmodule HarnessForge.Evidence.Requirements do
  @moduledoc "Immutable operator declarations of required connection scope; never evidence admission."
  alias HarnessForge.{Audit, Company, Contracts, Goals, Repo, Workspaces}
  alias HarnessForge.Company.{CorpusReview, Profile, Project}
  alias HarnessForge.Connectors.Registry
  alias HarnessForge.Evidence.{Capture, CaptureRun, Connection, Corpora, Goal, LocalImport, Store}
  alias HarnessForge.Privacy.Purge

  @expected ~w(semantic_generation authorization_generation profile_hash project_hash goal_hash revision)
  @entry ~w(connection_id requirement capture_run_id capture_revision)
  @version "corpus-requirements.v1"

  def context(corpus_id, project_id, goal_id, goal_hash, caller) do
    Corpora.guard(caller, fn ->
      with {:ok, current} <- current_context(corpus_id, project_id, goal_id, goal_hash) do
        {:ok, Map.take(current, ~w(scope expected))}
      end
    end)
  end

  def declare(corpus_id, expected, attrs, caller) do
    Corpora.guard(caller, fn ->
      with :ok <- declaration_input(expected, attrs),
           {:ok, current} <-
             current_context(
               corpus_id,
               attrs["project_id"],
               attrs["goal_id"],
               expected["goal_hash"]
             ),
           :ok <- check(current["expected"] == expected, :stale_declaration),
           {:ok, entries} <- resolve_entries(attrs["entries"], corpus_id),
           payload = %{
             "version" => @version,
             "scope" => current["scope"],
             "primary_connection_id" => attrs["primary_connection_id"],
             "entries" => entries
           },
           {:ok, record} <- insert(payload, expected["revision"] + 1),
           {:ok, _} <-
             Audit.append("corpus.requirements_declared", %{
               "declaration_id" => record["id"],
               "corpus_id" => corpus_id,
               "revision" => record["revision"]
             }) do
        summarize(record, payload, current, caller)
      end
    end)
  end

  def summary(id, digest, caller) do
    Corpora.guard(caller, fn -> current_summary(id, digest) end)
  end

  @doc "Metadata for an explicitly chosen current saved coverage revision, never a selection."
  def saved_choice(corpus_id, project_id, goal_id, goal_hash, caller) do
    Corpora.guard(caller, fn ->
      with {:ok, current} <- current_context(corpus_id, project_id, goal_id, goal_hash) do
        case Corpora.rows(
               "SELECT id,digest,revision,inserted_at FROM corpus_requirements WHERE workspace_id=? AND corpus_id=? AND project_id=? AND goal_id=? AND revision=? LIMIT 1",
               [
                 Store.workspace(),
                 corpus_id,
                 project_id,
                 goal_id,
                 current["expected"]["revision"]
               ]
             ) do
          [] ->
            {:ok, []}

          [metadata] ->
            with {:ok, _} <- checked_summary(metadata["id"], metadata["digest"]),
                 do: {:ok, [metadata]}
        end
      end
    end)
  rescue
    _ -> {:error, :unavailable}
  end

  @doc false
  # Trusted backend currentness checks also need the identical receipt validator.
  # This grants no operator session, inference permission or dispatch authority.
  def current_summary(id, digest) do
    Purge.synchronize(fn ->
      read = fn ->
        with :ok <- Workspaces.ensure_writable(),
             :ok <- Purge.ready(),
             {:ok, summary} <- checked_summary(id, digest),
             :ok <- Purge.ready(),
             do: {:ok, summary}
      end

      # An expected stale read must not roll back the transaction owned by its
      # caller. The validator performs no writes and retains the same checks.
      if Repo.in_transaction?(), do: read.(), else: Store.transaction(read)
    end)
  end

  defp checked_summary(id, digest) do
    with :ok <- check(Corpora.uuid?(id) and Corpora.digest?(digest), :invalid_input),
         {:ok, record} <- load(id),
         {:ok, payload} <- decode(record, digest),
         scope = payload["scope"],
         {:ok, current} <-
           current_context(
             scope["corpus_id"],
             scope["project_id"],
             scope["goal_id"],
             scope["goal_hash"]
           ),
         :ok <- check(scope == current["scope"], :stale_declaration),
         :ok <- check(record["revision"] == current["expected"]["revision"], :stale_declaration) do
      summarize(record, payload, current, nil)
    end
  end

  def capture_choices(corpus_id, connection_id, attrs, caller) do
    Corpora.guard(caller, fn ->
      with :ok <- Corpora.keys(attrs, [], ["cursor"]),
           {:ok, corpus} <- Corpora.get(corpus_id),
           :ok <- check(corpus.state == "active", :invalid_scope),
           {:ok, _} <- active_connection(connection_id),
           binding = %{
             "kind" => "requirement_captures",
             "corpus_id" => corpus_id,
             "connection_id" => connection_id,
             "generation" => corpus.semantic_generation,
             "authorization_generation" => corpus.authorization_generation
           },
           {:ok, after_id} <- Corpora.cursor(attrs["cursor"], binding, caller) do
        found =
          Corpora.rows(
            "SELECT id,id AS run_id,lock_version AS revision,state,error_code,inserted_at FROM capture_runs WHERE workspace_id=? AND corpus_id=? AND connection_id=? AND id>? ORDER BY id LIMIT 26",
            [Store.workspace(), corpus_id, connection_id, after_id]
          )

        {:ok, Corpora.paged(found, binding, caller)}
      end
    end)
  end

  defp current_context(corpus_id, project_id, goal_id, goal_hash) do
    with :ok <-
           check(
             Enum.all?([corpus_id, project_id, goal_id], &Corpora.uuid?/1) and
               Corpora.digest?(goal_hash),
             :invalid_input
           ),
         {:ok, corpus} <- Corpora.get(corpus_id),
         :ok <- check(corpus.state == "active", :stale_declaration),
         {:ok, %{"id" => ^corpus_id}} <- Company.bound_corpus(project_id),
         %Profile{} = profile <- Repo.one(Store.scoped(Profile)),
         {:ok, project} <- Store.get(Project, project_id),
         {:ok, goal} <- Store.get(Goal, goal_id),
         :ok <-
           check(
             profile.content_hash == Contracts.digest(profile.payload) and
               project.content_hash == Contracts.digest(project.payload),
             :stale_declaration
           ),
         :ok <-
           check(
             Goals.content_hash(goal) == goal_hash and
               goal.id in Enum.uniq(
                 List.wrap(profile.payload["goal_ids"]) ++ List.wrap(project.payload["goal_ids"])
               ),
             :stale_declaration
           ),
         [_] <-
           Corpora.rows(
             "SELECT corpus_id FROM company_corpus_bindings WHERE workspace_id=? AND project_id=? AND profile_id=? AND corpus_id=?",
             [Store.workspace(), project_id, profile.id, corpus_id]
           ) do
      scope = %{
        "workspace_id" => Store.workspace(),
        "corpus_id" => corpus_id,
        "semantic_generation" => corpus.semantic_generation,
        "authorization_generation" => corpus.authorization_generation,
        "profile_id" => profile.id,
        "profile_hash" => profile.content_hash,
        "project_id" => project_id,
        "project_hash" => project.content_hash,
        "goal_id" => goal_id,
        "goal_hash" => goal_hash
      }

      expected = Map.take(scope, @expected) |> Map.put("revision", revision(scope))
      {:ok, %{"scope" => scope, "expected" => expected, "project" => project, "goal" => goal}}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_scope}
    end
  end

  defp revision(scope) do
    [%{"revision" => revision}] =
      Corpora.rows(
        "SELECT coalesce(max(revision),0) AS revision FROM corpus_requirements WHERE workspace_id=? AND corpus_id=? AND project_id=? AND goal_id=?",
        [Store.workspace(), scope["corpus_id"], scope["project_id"], scope["goal_id"]]
      )

    revision
  end

  defp declaration_input(expected, attrs) do
    valid =
      Corpora.keys(expected, @expected) == :ok and
        Enum.all?(~w(profile_hash project_hash goal_hash), &Corpora.digest?(expected[&1])) and
        Enum.all?(
          ~w(semantic_generation authorization_generation revision),
          &(is_integer(expected[&1]) and expected[&1] >= 0)
        ) and
        Corpora.keys(attrs, ~w(project_id goal_id primary_connection_id entries)) == :ok and
        Enum.all?(~w(project_id goal_id primary_connection_id), &Corpora.uuid?(attrs[&1])) and
        valid_entries?(attrs["entries"]) and
        Enum.any?(
          attrs["entries"],
          &(&1["connection_id"] == attrs["primary_connection_id"] and
              &1["requirement"] == "required")
        )

    check(valid, :invalid_input)
  end

  defp valid_entries?(entries) do
    is_list(entries) and length(entries) in 1..16 and
      Enum.all?(entries, fn entry ->
        Corpora.keys(entry, @entry) == :ok and Corpora.uuid?(entry["connection_id"]) and
          entry["requirement"] in ~w(required optional) and
          ((is_nil(entry["capture_run_id"]) and is_nil(entry["capture_revision"])) or
             (Corpora.uuid?(entry["capture_run_id"]) and is_integer(entry["capture_revision"]) and
                entry["capture_revision"] > 0))
      end) and length(Enum.uniq_by(entries, & &1["connection_id"])) == length(entries)
  end

  defp resolve_entries(entries, corpus_id) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      with {:ok, connection} <- active_connection(entry["connection_id"]),
           {:ok, run} <- selected_run(entry, corpus_id),
           :ok <- root_unchanged(connection, run) do
        saved =
          Map.merge(entry, %{
            "name" => display_name(connection.name),
            "connection_pin" => connection_pin(connection),
            "capture_root_fingerprint" => if(run, do: run.root_fingerprint)
          })

        {:cont, {:ok, [saved | acc]}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp active_connection(id) do
    with {:ok, connection} <- Store.get(Connection, id),
         :ok <- check(connection.status == "active", :connection_unavailable),
         :ok <- supported(connection.provider) do
      {:ok, connection}
    end
  end

  defp supported("local"), do: :ok

  defp supported(provider) do
    case Registry.adapter(provider) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp connection_pin(connection),
    do: %{
      "provider" => connection.provider,
      "status" => connection.status,
      "config_digest" =>
        Contracts.digest(%{"config" => connection.config, "directory" => connection.directory})
    }

  defp selected_run(%{"capture_run_id" => nil}, _), do: {:ok, nil}

  defp selected_run(entry, corpus_id) do
    with {:ok, run} <- Store.get(CaptureRun, entry["capture_run_id"]),
         :ok <-
           check(
             run.corpus_id == corpus_id and run.connection_id == entry["connection_id"],
             :invalid_scope
           ),
         :ok <- check(run.lock_version == entry["capture_revision"], :stale_receipt),
         :ok <- check(Corpora.digest?(run.root_fingerprint), :invalid_scope) do
      {:ok, run}
    end
  end

  defp root_unchanged(_, nil), do: :ok

  defp root_unchanged(%{provider: "local"} = connection, run) do
    case current_root(connection) do
      {:ok, hash} -> check(hash == run.root_fingerprint, :stale_receipt)
      :unsafe -> {:error, :stale_receipt}
      _ -> :ok
    end
  end

  defp root_unchanged(_, _), do: :ok

  defp current_root(connection) do
    with {:ok, root} <- LocalImport.approved_directory(connection.directory),
         {:ok, stat} <- File.lstat(root) do
      {:ok,
       Contracts.digest(%{
         "connection_id" => connection.id,
         "root" => root,
         "device" => stat.major_device,
         "inode" => stat.inode,
         "config" => connection.config
       })}
    else
      _ ->
        case File.lstat(connection.directory || "") do
          {:error, :enoent} -> :missing
          {:ok, _} -> :unsafe
          _ -> :unavailable
        end
    end
  end

  defp insert(payload, revision) do
    id = Ecto.UUID.generate()
    digest = Contracts.digest(payload)
    json = Contracts.canonical_json(payload)
    scope = payload["scope"]

    with :ok <- check(byte_size(json) <= 32_768, :invalid_input) do
      case Repo.query(
             "INSERT INTO corpus_requirements(id,workspace_id,corpus_id,project_id,goal_id,revision,digest,payload,inserted_at) VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(workspace_id,corpus_id,project_id,goal_id,revision) DO NOTHING",
             [
               id,
               Store.workspace(),
               scope["corpus_id"],
               scope["project_id"],
               scope["goal_id"],
               revision,
               digest,
               json,
               Corpora.now()
             ],
             log: false
           ) do
        {:ok, %{num_rows: 1}} -> {:ok, %{"id" => id, "revision" => revision, "digest" => digest}}
        {:ok, _} -> {:error, :stale_declaration}
        {:error, _} -> {:error, :declaration_unavailable}
      end
    end
  end

  defp load(id) do
    case Corpora.rows(
           "SELECT id,corpus_id,project_id,goal_id,revision,digest,payload FROM corpus_requirements WHERE workspace_id=? AND id=?",
           [Store.workspace(), id]
         ) do
      [record] -> {:ok, record}
      [] -> {:error, :not_found}
    end
  end

  defp decode(record, digest) do
    with :ok <- check(record["digest"] == digest, :invalid_scope),
         {:ok, payload} <- Contracts.decode_json(record["payload"]),
         :ok <- Corpora.keys(payload, ~w(version scope primary_connection_id entries)),
         scope when is_map(scope) <- payload["scope"],
         :ok <-
           check(
             payload["version"] == @version and Contracts.digest(payload) == digest and
               scope["workspace_id"] == Store.workspace() and
               Enum.all?(~w(corpus_id project_id goal_id), &(scope[&1] == record[&1])) and
               valid_saved_entries?(payload),
             :invalid_scope
           ) do
      {:ok, payload}
    else
      _ -> {:error, :invalid_scope}
    end
  end

  defp valid_saved_entries?(payload) do
    entries = payload["entries"]

    is_list(entries) and length(entries) in 1..16 and
      Enum.all?(
        entries,
        &(Corpora.keys(&1, @entry ++ ~w(name connection_pin capture_root_fingerprint)) == :ok)
      ) and
      valid_entries?(Enum.map(entries, &Map.take(&1, @entry))) and
      Enum.any?(
        entries,
        &(&1["connection_id"] == payload["primary_connection_id"] and
            &1["requirement"] == "required")
      )
  end

  defp summarize(record, payload, current, caller) do
    entries = payload["entries"]
    members = membership(payload["scope"]["corpus_id"], Enum.map(entries, & &1["connection_id"]))

    with {:ok, observed} <-
           observe_entries(entries, payload["scope"]["corpus_id"], members, caller) do
      primary = Enum.find(observed, &(&1["connection_id"] == payload["primary_connection_id"]))
      scope = current["scope"]

      {:ok,
       %{
         "id" => record["id"],
         "revision" => record["revision"],
         "digest" => record["digest"],
         "scope" => scope,
         "primary_connection_id" => payload["primary_connection_id"],
         "entries" => observed,
         "required_status" => required_status(observed, members),
         "omissions" => omissions(observed, record),
         "undeclared_members" => members["undeclared"],
         "member_count" => members["total"],
         "selection" => %{
           "connection_id" => primary["connection_id"],
           "project_id" => scope["project_id"],
           "goal_id" => scope["goal_id"],
           "goal_content_hash" => scope["goal_hash"]
         },
         "selection_display" => %{
           "connection" =>
             Map.take(primary, ~w(connection_id name provider))
             |> Map.put("id", primary["connection_id"]),
           "project" => %{
             "id" => scope["project_id"],
             "title" => display_name(current["project"].payload["name"]),
             "content_hash" => scope["project_hash"]
           },
           "goal" => %{
             "id" => scope["goal_id"],
             "title" => display_name(current["goal"].title),
             "content_hash" => scope["goal_hash"]
           }
         }
       }}
    end
  end

  defp membership(corpus_id, ids) do
    placeholders = Enum.map_join(ids, ",", fn _ -> "?" end)

    rows =
      Corpora.rows(
        """
        SELECT CASE WHEN s.connection_id IN(#{placeholders}) THEN s.connection_id ELSE '' END AS connection_id,
          count(*) AS member_count, coalesce(sum(CASE WHEN s.status='active' AND c.status='active'
            AND s.provider=c.provider AND m.revision_id=s.latest_revision_id AND r.id IS NOT NULL
            AND (#{CorpusReview.document_scope_sql()}) THEN 1 ELSE 0 END),0) AS eligible_count
        FROM corpus_members m
        LEFT JOIN evidence_sources s ON s.workspace_id=m.workspace_id AND s.id=m.source_id
        LEFT JOIN source_connections c ON c.workspace_id=s.workspace_id AND c.id=s.connection_id
        LEFT JOIN evidence_revisions r ON r.workspace_id=s.workspace_id AND r.source_id=s.id AND r.id=m.revision_id
        WHERE m.workspace_id=? AND m.corpus_id=? AND m.status='active'
        GROUP BY CASE WHEN s.connection_id IN(#{placeholders}) THEN s.connection_id ELSE '' END
        """,
        ids ++ [Store.workspace(), corpus_id] ++ ids
      )

    %{
      "connections" => Map.new(rows, &{&1["connection_id"], &1}),
      "total" => Enum.sum(Enum.map(rows, & &1["member_count"])),
      "undeclared" =>
        rows
        |> Enum.filter(&(&1["connection_id"] == ""))
        |> Enum.map(& &1["member_count"])
        |> Enum.sum()
    }
  end

  defp observe_entries(entries, corpus_id, members, caller) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      with {:ok, connection} <- active_connection(entry["connection_id"]),
           :ok <- check(connection_pin(connection) == entry["connection_pin"], :stale_declaration),
           {:ok, run} <- selected_run(entry, corpus_id),
           :ok <-
             check(
               if(run, do: run.root_fingerprint) == entry["capture_root_fingerprint"],
               :invalid_scope
             ),
           :ok <- root_unchanged(connection, run),
           {:ok, capture} <- capture_summary(run, caller) do
        member =
          members["connections"][connection.id] || %{"member_count" => 0, "eligible_count" => 0}

        {state, reason} = entry_state(connection, capture, run, member, entry["requirement"])

        observed =
          Map.take(entry, @entry)
          |> Map.merge(%{
            "name" => display_name(connection.name),
            "provider" => connection.provider,
            "capture_state" => if(run, do: run.state),
            "state" => state,
            "reason_code" => reason,
            "member_count" => member["member_count"]
          })

        {:cont, {:ok, [observed | acc]}}
      else
        {:error, reason} when reason in [:connection_unavailable, :not_found] ->
          {:halt, {:error, :stale_declaration}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, observed} -> {:ok, Enum.reverse(observed)}
      error -> error
    end
  end

  defp capture_summary(nil, _), do: {:ok, nil}
  defp capture_summary(run, nil), do: Capture.current_summary(run.id)
  defp capture_summary(run, caller), do: Capture.read_summary(run.id, caller)

  defp entry_state(_, nil, _, _, _), do: {"unknown", "capture_not_selected"}

  defp entry_state(%{provider: provider}, _, _, _, _) when provider != "local",
    do: {"unknown", "capture_provider_unsupported"}

  defp entry_state(connection, capture, run, member, requirement) do
    cond do
      member["member_count"] != member["eligible_count"] ->
        {"blocked", "ineligible_members"}

      run.state in ~w(queued running) ->
        {"unknown", "capture_running"}

      failed_capture?(run) and member["member_count"] == 0 and requirement == "optional" and
          current_root(connection) != :unavailable ->
        {"omitted", "optional_source_unavailable"}

      failed_capture?(run) ->
        {"blocked",
         if(member["member_count"] > 0,
           do: "capture_partial",
           else: "required_source_unavailable"
         )}

      capture["scope_current"] == "stale" ->
        {"stale", "stale_receipt"}

      current_root(connection) in [:missing, :unavailable] ->
        {"unknown", "directory_unavailable"}

      capture["scope_current"] == "current" and capture["capture"]["complete"] == true and
          member["member_count"] > 0 ->
        {"complete", "capture_verified"}

      member["member_count"] == 0 ->
        {"unknown", "required_evidence_missing"}

      true ->
        {"unknown", "capture_scope_unknown"}
    end
  end

  defp failed_capture?(run), do: run.state in ~w(paused failed cancelled) or run.incomplete

  defp required_status(entries, members) do
    required = Enum.filter(entries, &(&1["requirement"] == "required"))

    cond do
      members["undeclared"] > 0 ->
        "unknown"

      Enum.any?(entries, &(&1["member_count"] > 0 and &1["state"] == "blocked")) ->
        "blocked"

      Enum.any?(entries, &(&1["member_count"] > 0 and &1["state"] == "stale")) ->
        "stale"

      Enum.any?(required, &(&1["state"] == "blocked")) ->
        "blocked"

      Enum.any?(required, &(&1["state"] == "stale")) ->
        "stale"

      required != [] and Enum.all?(required, &(&1["state"] == "complete")) and
          Enum.all?(entries, &(&1["member_count"] == 0 or &1["state"] == "complete")) ->
        "complete"

      true ->
        "unknown"
    end
  end

  defp omissions(entries, record) do
    entries
    |> Enum.filter(&(&1["state"] == "omitted"))
    |> Enum.map(fn entry ->
      %{
        "connector_id" => entry["connection_id"],
        "connector_name" => entry["name"],
        "scope_id" => entry["connection_id"],
        "requirement" => "optional",
        "reason_code" => "optional_source_unavailable",
        "declaration_id" => record["id"],
        "declaration_revision" => record["revision"],
        "declaration_digest" => record["digest"],
        "capture_run_id" => entry["capture_run_id"],
        "capture_revision" => entry["capture_revision"]
      }
    end)
  end

  defp display_name(value) when is_binary(value), do: String.slice(value, 0, 200)
  defp display_name(_), do: "Unavailable"
  defp check(true, _), do: :ok
  defp check(_, reason), do: {:error, reason}
end
