defmodule HarnessForge.Evidence.Capture do
  @moduledoc "Durable resumable physical capture with per-file outcomes and independent index readiness."
  import Ecto.Query
  alias HarnessForge.{Audit, Contracts, Repo, Workspaces}
  alias HarnessForge.Evidence.{CaptureRun, Connection, Corpora, LocalImport, Store}
  alias HarnessForge.Evidence.Capture.{Scanner, Writer}
  alias HarnessForge.Evidence.SetupCaptureBounds
  alias HarnessForge.Privacy.Purge

  defdelegate preflight_for_setup(session_id, connection_id, caller),
    to: HarnessForge.Evidence.SetupCapture,
    as: :preflight

  defdelegate start_for_setup(config_ref, command_ref, caller),
    to: HarnessForge.Evidence.SetupCapture,
    as: :start

  defdelegate setup_status(capture_ref, caller),
    to: HarnessForge.Evidence.SetupCapture,
    as: :status

  @doc false
  def fingerprint_for_setup(connection, root), do: fingerprint(connection, root)
  @doc false
  def snapshot_for_setup(run), do: status(run)

  def start_capture(corpus_id, connection_id, generation, caller) do
    Corpora.guard(caller, fn ->
      with {:ok, corpus} <- Corpora.get(corpus_id),
           true <- is_integer(generation) and generation >= 0 and corpus.state == "active",
           {:ok, connection} <- connection(connection_id),
           {:ok, root} <- LocalImport.approved_directory(connection.directory),
           {:ok, fingerprint} <- fingerprint(connection, root) do
        existing =
          Repo.one(
            from r in Store.scoped(CaptureRun), where: r.state in ["queued", "running", "paused"]
          )

        cond do
          existing && existing.corpus_id == corpus_id && existing.connection_id == connection_id &&
            existing.root_fingerprint == fingerprint &&
              generation in [corpus.semantic_generation, existing.counts["start_generation"]] ->
            {:ok, status(existing)}

          existing ->
            {:error, :queue_full}

          corpus.semantic_generation != generation ->
            {:error, :stale_generation}

          true ->
            run = %CaptureRun{
              workspace_id: Store.workspace(),
              corpus_id: corpus_id,
              connection_id: connection_id,
              root_fingerprint: fingerprint,
              counts: %{"start_generation" => generation},
              idempotency_key:
                Contracts.digest(%{
                  "corpus" => corpus_id,
                  "connection" => connection_id,
                  "generation" => generation,
                  "nonce" => Ecto.UUID.generate()
                })
            }

            with {:ok, run} <- Repo.insert(run),
                 {:ok, _} <-
                   HarnessForge.Jobs.Capture.new(%{
                     "workspace_id" => Store.workspace(),
                     "run_id" => run.id
                   })
                   |> Oban.insert(),
                 {:ok, _} <-
                   Audit.append("corpus.capture_started", %{
                     "run_id" => run.id,
                     "corpus_id" => corpus_id
                   }) do
              Corpora.query!(
                "INSERT INTO capture_frontier(run_id,relative_path,state,scan_epoch,entry_count) VALUES(?,'','pending',1,0)",
                [run.id]
              )

              {:ok, status(run)}
            end
        end
      else
        false -> {:error, :stale_generation}
        error -> error
      end
    end)
  end

  @doc "Metadata for the exact selected capture, without file rows or document bodies."
  def read_summary(id, caller) do
    Corpora.guard(caller, fn -> current_summary(id) end)
  end

  @doc false
  # Internal currentness composition, never a user-facing authorization boundary.
  def current_summary(id) do
    Purge.synchronize(fn ->
      Store.transaction(fn ->
        with :ok <- Workspaces.ensure_writable(),
             :ok <- Purge.ready(),
             {:ok, run} <- Store.get(CaptureRun, id),
             summary = status(run),
             :ok <- Purge.ready(),
             do: {:ok, summary}
      end)
    end)
  end

  def capture_status(id, attrs, caller) do
    Corpora.guard(caller, fn ->
      with :ok <- Corpora.keys(attrs, [], ["cursor"]),
           {:ok, run} <- Store.get(CaptureRun, id),
           binding = %{"kind" => "capture", "run_id" => id, "revision" => run.lock_version},
           {:ok, after_path} <- Corpora.cursor(attrs["cursor"], binding, caller) do
        found =
          Corpora.rows(
            "SELECT relative_path AS id,relative_path,kind,state,error_code,body_bytes FROM capture_items WHERE run_id=? AND relative_path>? ORDER BY relative_path LIMIT 26",
            [id, after_path]
          )

        {:ok, Map.merge(status(run), Corpora.paged(found, binding, caller))}
      end
    end)
  end

  def resume(id, version, caller) do
    Corpora.guard(caller, fn ->
      with {:ok, run} <- Store.get(CaptureRun, id),
           true <- is_integer(version) and version == run.lock_version,
           true <- run.state in ["paused", "failed"] or expired?(run) do
        epoch = run.scan_epoch + 1

        Corpora.query!(
          "UPDATE capture_runs SET state='queued',lock_version=lock_version+1,scan_epoch=?,incomplete=0,scan_verified=0,error_code=NULL,lease_token=NULL,lease_until=NULL,updated_at=? WHERE workspace_id=? AND id=?",
          [epoch, Corpora.now(), Store.workspace(), id]
        )

        Corpora.query!(
          "UPDATE capture_frontier SET state='pending',scan_epoch=?,entry_count=0 WHERE run_id=?",
          [epoch, id]
        )

        {:ok, _} =
          HarnessForge.Jobs.Capture.new(%{"workspace_id" => Store.workspace(), "run_id" => id})
          |> Oban.insert()

        {:ok, status(Repo.get!(CaptureRun, id))}
      else
        false -> {:error, :stale_revision}
        error -> error
      end
    end)
  end

  def cancel(id, version, caller), do: transition(id, version, "cancelled", caller)
  def pause(id, version, caller), do: transition(id, version, "paused", caller)

  defp transition(id, version, state, caller) do
    Corpora.guard(caller, fn ->
      with {:ok, run} <- Store.get(CaptureRun, id) do
        cond do
          run.state == state ->
            {:ok, status(run)}

          not is_integer(version) or version != run.lock_version ->
            {:error, :stale_revision}

          run.state not in ["queued", "running", "paused"] ->
            {:error, :stale_revision}

          true ->
            Corpora.query!(
              "UPDATE capture_runs SET state=?,lock_version=lock_version+1,lease_token=NULL,lease_until=NULL,updated_at=? WHERE workspace_id=? AND id=?",
              [state, Corpora.now(), Store.workspace(), id]
            )

            {:ok, status(Repo.get!(CaptureRun, id))}
        end
      end
    end)
  end

  @doc false
  def run(id) do
    with :ok <- Workspaces.ensure_writable(),
         :ok <- Purge.ready(),
         {:ok, run} <- claim(id),
         {:ok, connection} <- connection(run.connection_id),
         {:ok, root} <- LocalImport.approved_directory(connection.directory),
         {:ok, actual} <- fingerprint(connection, root),
         true <- actual == run.root_fingerprint do
      try do
        result = with :ok <- Scanner.reset(run.lease_token), do: walk(run, run.lease_token, root)

        case result do
          :ok ->
            complete(run, run.lease_token)

          {:error, reason} = error ->
            fail(run, reason)
            error
        end
      after
        Scanner.cancel(run.lease_token)
      end
    else
      false ->
        case Store.get(CaptureRun, id) do
          {:ok, claimed} -> fail(claimed, :unsafe_directory)
          _ -> :ok
        end

        {:error, :unsafe_directory}

      error ->
        error
    end
  rescue
    _ ->
      case Store.get(CaptureRun, id) do
        {:ok, run} -> fail(run, :capture_incomplete)
        _ -> :ok
      end

      {:error, :capture_incomplete}
  end

  defp claim(id) do
    Purge.synchronize(fn ->
      Store.transaction(fn ->
        with :ok <- Purge.ready(),
             {:ok, run} <- Store.get(CaptureRun, id),
             true <- run.state == "queued" or expired?(run) do
          lease = Ecto.UUID.generate()
          # A directory batch can commit its frontier before file outcomes/ACK.
          # Reclaim by a fresh observed traversal, never by an opaque native cursor.
          epoch = if expired?(run), do: run.scan_epoch + 1, else: run.scan_epoch

          if expired?(run) do
            Corpora.query!(
              "UPDATE capture_frontier SET state='pending',scan_epoch=?,entry_count=0 WHERE run_id=?",
              [epoch, run.id]
            )
          end

          {:ok, saved} =
            run
            |> Ecto.Changeset.change(
              state: "running",
              lease_token: lease,
              lease_until: DateTime.add(Store.now(), 120, :second),
              scan_epoch: epoch,
              incomplete: false,
              lock_version: run.lock_version + 1
            )
            |> Repo.update()

          {:ok, saved}
        else
          false -> {:error, :stale_revision}
          error -> error
        end
      end)
    end)
  end

  @doc false
  def check_lease(id, token) do
    with :ok <- Purge.ready(),
         {:ok, run} <- Store.get(CaptureRun, id),
         true <- run.state == "running" and run.lease_token == token and not expired?(run),
         {:ok, _} <- connection(run.connection_id),
         {:ok, corpus} <- Corpora.get(run.corpus_id),
         true <- corpus.state == "active",
         :ok <- SetupCaptureBounds.check(run) do
      :ok
    else
      _ -> {:error, :cancelled}
    end
  end

  defp walk(run, token, root) do
    with :ok <- check_lease(run.id, token) do
      case Corpora.rows(
             "SELECT relative_path FROM capture_frontier WHERE run_id=? AND scan_epoch=? AND state='pending' ORDER BY relative_path LIMIT 1",
             [run.id, run.scan_epoch]
           ) do
        [] ->
          :ok

        [%{"relative_path" => path}] ->
          with {:ok, batch} <- Scanner.open_directory(run.id, root, path, token),
               :ok <- batches(run, token, root, path, batch) do
            walk(run, token, root)
          end
      end
    end
  end

  defp batches(run, token, root, directory, batch) do
    with :ok <- validate_batch(batch, run.id),
         {:ok, _} <- checkpoint(run, token, directory, batch),
         :ok <- files(run, token, root, batch["entries"]),
         {:ok, next} <- Scanner.ack(run.id, batch["seq"], token) do
      if batch["done"] do
        if batch["stable"], do: :ok, else: {:error, :capture_incomplete}
      else
        batches(run, token, root, directory, next)
      end
    end
  end

  defp validate_batch(batch, id) do
    valid =
      Corpora.keys(batch, ~w(v run_id seq entries done stable directory_fingerprint error_code)) ==
        :ok and batch["v"] === 1 and batch["run_id"] == id and
        is_integer(batch["seq"]) and batch["seq"] >= 0 and is_boolean(batch["done"]) and
        is_boolean(batch["stable"]) and Corpora.digest?(batch["directory_fingerprint"]) and
        is_list(batch["entries"]) and length(batch["entries"]) <= 100 and
        Enum.all?(batch["entries"], fn entry ->
          Corpora.keys(entry, ~w(relative_path kind error_code)) == :ok and
            safe_relative?(entry["relative_path"]) and
            entry["kind"] in ["file", "directory", "other"] and
            entry["error_code"] in [nil, "symlink_not_allowed", "unsupported_file"]
        end)

    if valid, do: :ok, else: {:error, :invalid_input}
  end

  defp checkpoint(run, token, directory, batch) do
    Purge.synchronize(fn ->
      Store.transaction(fn ->
        with :ok <- check_lease(run.id, token),
             {:ok, mode} <- SetupCaptureBounds.admit_page(run, token, directory, batch) do
          if mode == :replay do
            {:ok, :checkpointed}
          else
            Enum.each(batch["entries"], fn entry ->
              path = entry["relative_path"]
              # The helper must only enumerate direct children of the requested directory.
              parent = if directory == "", do: ".", else: directory
              if Path.dirname(path) != parent, do: Repo.rollback(:path_escape)

              if entry["kind"] == "directory" do
                Corpora.query!(
                  "INSERT INTO capture_frontier(run_id,relative_path,state,scan_epoch,entry_count) VALUES(?,?,'pending',?,0) ON CONFLICT(run_id,relative_path) DO UPDATE SET scan_epoch=excluded.scan_epoch",
                  [run.id, path, run.scan_epoch]
                )
              end

              state = if entry["kind"] == "directory", do: "excluded", else: "pending"

              state_update =
                if mode == :legacy,
                  do: "state=excluded.state",
                  else:
                    "state=CASE WHEN capture_items.state IN ('captured','unchanged') THEN capture_items.state ELSE excluded.state END"

              Corpora.query!(
                "INSERT INTO capture_items(run_id,relative_path,kind,state,scan_epoch,attempts,updated_at) VALUES(?,?,?,?,?,0,?) ON CONFLICT(run_id,relative_path) DO UPDATE SET #{state_update},scan_epoch=excluded.scan_epoch,updated_at=excluded.updated_at",
                [run.id, path, entry["kind"], state, run.scan_epoch, Corpora.now()]
              )
            end)

            state = if batch["done"] and batch["stable"], do: "done", else: "enumerating"

            Corpora.query!(
              "UPDATE capture_frontier SET state=?,directory_fingerprint=?,entry_count=entry_count+? WHERE run_id=? AND relative_path=?",
              [state, batch["directory_fingerprint"], length(batch["entries"]), run.id, directory]
            )

            {:ok, :checkpointed}
          end
        end
      end)
    end)
  end

  defp files(run, token, root, entries) do
    entries
    |> Enum.reject(&(&1["kind"] == "directory"))
    |> Enum.reduce_while({:ok, [], 0}, fn entry, {:ok, batch, bytes} ->
      with :ok <- check_lease(run.id, token) do
        result =
          if SetupCaptureBounds.bounded?(run),
            do: SetupCaptureBounds.read(run, token, root, entry),
            else: read_entry(root, entry)

        if result == :skip do
          {:cont, {:ok, batch, bytes}}
        else
          size =
            case result do
              {:ok, doc} -> byte_size(doc["body"])
              _ -> 0
            end

          if bytes + size > 8_388_608 and batch != [] do
            case commit_documents(run, token, Enum.reverse(batch)) do
              {:ok, _} -> {:cont, {:ok, [{entry["relative_path"], result}], size}}
              error -> {:halt, error}
            end
          else
            {:cont, {:ok, [{entry["relative_path"], result} | batch], bytes + size}}
          end
        end
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, [], _} ->
        :ok

      {:ok, batch, _} ->
        case commit_documents(run, token, Enum.reverse(batch)) do
          {:ok, _} -> :ok
          error -> error
        end

      error ->
        error
    end
  end

  defp commit_documents(run, token, documents) do
    with {:ok, _} <- Writer.commit(run, token, documents),
         :ok <- index_setup_documents(run, token, documents),
         do: {:ok, :committed}
  end

  # The acquisition includes local indexing. Finish the physical scope only
  # after these idempotent indexes; later queued copies cannot advance it again.
  defp index_setup_documents(run, token, documents) do
    if SetupCaptureBounds.bounded?(run) do
      Enum.reduce_while(documents, :ok, fn
        {path, {:ok, _}}, :ok ->
          result =
            with :ok <- check_lease(run.id, token),
                 [%{"revision_id" => id}] <-
                   Corpora.rows(
                     "SELECT revision_id FROM capture_items WHERE run_id=? AND relative_path=?",
                     [run.id, path]
                   ),
                 {:ok, _} <- HarnessForge.Evidence.Passages.index_revision(id),
                 :ok <- check_lease(run.id, token),
                 do: :ok

          case result do
            :ok -> {:cont, :ok}
            {:error, _} = error -> {:halt, error}
            _ -> {:halt, {:error, :capture_incomplete}}
          end

        _, :ok ->
          {:cont, :ok}
      end)
    else
      :ok
    end
  end

  defp read_entry(root, %{"kind" => "file", "relative_path" => path}) do
    if Path.extname(path) in ~w(.md .markdown .txt),
      do: LocalImport.read_document(root, Path.join(root, path)),
      else: {:excluded, :unsupported_extension}
  end

  defp read_entry(_, %{"error_code" => "symlink_not_allowed"}), do: {:error, :symlink_not_allowed}
  defp read_entry(_, _), do: {:error, :unsupported_file}

  defp complete(run, token) do
    with :ok <- check_lease(run.id, token), {:ok, current} <- Store.get(CaptureRun, run.id) do
      pending =
        Corpora.rows(
          "SELECT count(*) AS n FROM capture_items WHERE run_id=? AND scan_epoch=? AND state IN('pending','failed','stale')",
          [run.id, run.scan_epoch]
        )

      frontier =
        Corpora.rows(
          "SELECT count(*) AS n FROM capture_frontier WHERE run_id=? AND scan_epoch=? AND state!='done'",
          [run.id, run.scan_epoch]
        )

      verified = not current.incomplete and pending == [%{"n" => 0}] and frontier == [%{"n" => 0}]

      with :ok <- if(verified, do: reconcile(run, token, ""), else: :ok) do
        Purge.synchronize(fn ->
          Store.transaction(fn ->
            with :ok <- check_lease(run.id, token),
                 {:ok, latest} <- Store.get(CaptureRun, run.id),
                 {:ok, corpus} <- Corpora.get(run.corpus_id),
                 {:ok, saved} <-
                   latest
                   |> Ecto.Changeset.change(
                     state: "scan_complete",
                     lock_version: latest.lock_version + 1,
                     scan_verified: verified,
                     incomplete: not verified,
                     lease_token: nil,
                     lease_until: nil,
                     counts:
                       Map.put(
                         latest.counts,
                         "completion_scope",
                         if(verified,
                           do: %{
                             "workspace_id" => Store.workspace(),
                             "corpus_id" => corpus.id,
                             "connection_id" => run.connection_id,
                             "semantic_generation" => corpus.semantic_generation,
                             "authorization_generation" => corpus.authorization_generation
                           }
                         )
                       )
                   )
                   |> Repo.update() do
              {:ok, status(saved)}
            end
          end)
        end)
      end
    end
  end

  defp reconcile(run, token, after_id) do
    # Every publication page commits separately; no corpus-sized transaction.
    result =
      Purge.synchronize(fn ->
        Store.transaction(fn ->
          with :ok <- check_lease(run.id, token) do
            missing =
              Corpora.rows(
                "SELECT m.source_id FROM corpus_members m JOIN evidence_sources s ON s.id=m.source_id AND s.workspace_id=m.workspace_id WHERE m.workspace_id=? AND m.corpus_id=? AND s.connection_id=? AND m.status='active' AND m.source_id>? AND NOT EXISTS(SELECT 1 FROM capture_items i WHERE i.run_id=? AND i.scan_epoch=? AND i.source_id=m.source_id AND i.state IN('captured','unchanged')) ORDER BY m.source_id LIMIT 100",
                [
                  Store.workspace(),
                  run.corpus_id,
                  run.connection_id,
                  after_id,
                  run.id,
                  run.scan_epoch
                ]
              )

            Enum.each(missing, fn row ->
              Corpora.query!(
                "UPDATE corpus_members SET status='removed',passage_set_id=NULL,updated_at=? WHERE workspace_id=? AND corpus_id=? AND source_id=?",
                [Corpora.now(), Store.workspace(), run.corpus_id, row["source_id"]]
              )
            end)

            if missing != [], do: Corpora.advance(run.corpus_id)
            next = if missing == [], do: after_id, else: List.last(missing)["source_id"]

            Corpora.query!(
              "UPDATE capture_runs SET reconcile_after=?,updated_at=? WHERE workspace_id=? AND id=? AND lease_token=?",
              [next, Corpora.now(), Store.workspace(), run.id, token]
            )

            {:ok, %{"next" => next, "done" => length(missing) < 100}}
          end
        end)
      end)

    case result do
      {:ok, %{"done" => true}} -> :ok
      {:ok, %{"next" => next}} -> reconcile(run, token, next)
      error -> error
    end
  end

  defp fail(run, reason) do
    Corpora.query!(
      "UPDATE capture_runs SET state='paused',incomplete=1,error_code=?,lease_token=NULL,lease_until=NULL,lock_version=lock_version+1,updated_at=? WHERE workspace_id=? AND id=? AND lease_token=? AND state='running'",
      [
        if(is_atom(reason), do: Atom.to_string(reason), else: "capture_incomplete"),
        Corpora.now(),
        Store.workspace(),
        run.id,
        run.lease_token
      ]
    )

    :ok
  end

  defp connection(id) do
    with {:ok, connection} <- Store.get(Connection, id),
         true <- connection.provider == "local" and connection.status == "active",
         do: {:ok, connection},
         else: (_ -> {:error, :connection_unavailable})
  end

  defp fingerprint(connection, root) do
    with {:ok, stat} <- File.lstat(root) do
      {:ok,
       Contracts.digest(%{
         "connection_id" => connection.id,
         "root" => root,
         "device" => stat.major_device,
         "inode" => stat.inode,
         "config" => connection.config
       })}
    end
  end

  defp expired?(%{state: "running", lease_until: %DateTime{} = until}),
    do: DateTime.compare(until, Store.now()) != :gt

  defp expired?(%{state: "running", lease_until: nil}), do: true
  defp expired?(_), do: false

  defp safe_relative?(path),
    do:
      Corpora.text?(path, 4096) and Path.type(path) != :absolute and ".." not in Path.split(path)

  defp status(run) do
    counts =
      Corpora.rows(
        "SELECT state,count(*) AS count FROM capture_items WHERE run_id=? AND scan_epoch=? GROUP BY state",
        [run.id, run.scan_epoch]
      )
      |> Map.new(&{&1["state"], &1["count"]})

    [index] =
      Corpora.rows(
        "SELECT count(*) AS expected,coalesce(sum(CASE WHEN passage_set_id IS NOT NULL THEN 1 ELSE 0 END),0) AS indexed FROM corpus_members WHERE workspace_id=? AND corpus_id=? AND status='active'",
        [Store.workspace(), run.corpus_id]
      )

    %{
      "run_id" => run.id,
      "revision" => run.lock_version,
      "corpus_id" => run.corpus_id,
      "connection_id" => run.connection_id,
      "scope" => run.counts["completion_scope"],
      "scope_current" => completion_current(run),
      "state" => run.state,
      "capture" => %{
        "state" => run.state,
        "complete" => run.scan_verified and not run.incomplete,
        "checkpoint" => run.checkpoint_seq,
        "counts" => counts
      },
      "fts" => %{
        "state" => if(index["expected"] == index["indexed"], do: "ready", else: "partial"),
        "expected" => index["expected"],
        "indexed" => index["indexed"]
      },
      "graph" => %{"state" => "unavailable"},
      "error_code" => run.error_code
    }
  end

  # Old captures retain their historical outcome. Missing completion pins cannot
  # establish that a later observed generation was captured by that old scan.
  defp completion_current(run) do
    case run.counts["completion_scope"] do
      %{
        "workspace_id" => workspace,
        "corpus_id" => corpus,
        "connection_id" => connection,
        "semantic_generation" => semantic,
        "authorization_generation" => authorization
      } ->
        if workspace == Store.workspace() and corpus == run.corpus_id and
             connection == run.connection_id and
             Corpora.assert_current(corpus, semantic, authorization) == :ok,
           do: "current",
           else: "stale"

      _ ->
        "unknown"
    end
  end
end
