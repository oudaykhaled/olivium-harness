defmodule HarnessForge.Evidence.SetupCaptureBounds do
  @moduledoc false
  import Ecto.Query
  alias HarnessForge.{Contracts, Repo}

  alias HarnessForge.Evidence.{
    Capture,
    Corpora,
    LocalImport,
    SetupCapture,
    SetupCaptureCharge,
    SetupCaptureCounter,
    SetupCapturePage,
    Store
  }

  alias HarnessForge.Privacy.Purge

  def check(run) do
    case SetupCapture.binding(run.id) do
      {:error, :not_found} ->
        if setup_run?(run), do: {:error, :cancelled}, else: :ok

      {:ok, binding} ->
        current =
          Corpora.rows(
            """
            SELECT s.id FROM setup_sessions s
            JOIN setup_run_states r ON r.workspace_id=s.workspace_id AND r.session_id=s.id AND r.owner_id=s.owner
            JOIN source_connections c ON c.id=? AND c.workspace_id=s.workspace_id
            WHERE s.workspace_id=? AND s.id=? AND s.owner=? AND s.schema_version=2
              AND json_extract(s.payload,'$.refs.run_ref.id')=? AND r.run_id=? AND r.phase='acquiring'
              AND c.status='active' AND c.provider='local'
            """,
            [
              binding.connection_id,
              Store.workspace(),
              binding.session_id,
              binding.owner_id,
              binding.run_id,
              binding.run_id
            ]
          )

        with true <- current != [] and DateTime.compare(binding.deadline, Store.now()) == :gt,
             true <-
               binding.limits_json == SetupCapture.limits() and
                 binding.root_fingerprint == run.root_fingerprint,
             [%{"directory" => directory, "config" => config}] <-
               Corpora.rows(
                 "SELECT directory,config FROM source_connections WHERE workspace_id=? AND id=?",
                 [Store.workspace(), binding.connection_id]
               ),
             {:ok, config} <- Jason.decode(config),
             true <-
               run.counts["setup_connection_digest"] ==
                 Contracts.digest(%{"directory" => directory, "config" => config}) do
          :ok
        else
          _ -> {:error, :cancelled}
        end
    end
  end

  # Runs inside Capture's page transaction, before frontier/item publication.
  def admit_page(run, lease, directory, batch) do
    case SetupCapture.binding(run.id) do
      {:error, :not_found} ->
        if setup_run?(run), do: {:error, :cancelled}, else: {:ok, :legacy}

      {:ok, binding} ->
        digest = Contracts.digest(batch)

        existing =
          Repo.one(
            from p in Store.scoped(SetupCapturePage),
              where:
                p.capture_id == ^run.id and p.scan_epoch == ^run.scan_epoch and
                  p.directory == ^directory and p.sequence == ^batch["seq"]
          )

        cond do
          existing && existing.payload_digest == digest ->
            {:ok, :replay}

          existing ->
            {:error, :acquisition_incomplete}

          true ->
            with :ok <- check(run),
                 {:ok, counter} <- counter(run.id),
                 {:ok, entries} <- new_entries(run, batch["entries"]),
                 true <-
                   counter.entries_admitted + length(entries) <=
                     binding.limits_json["max_admitted_entries"] do
              Enum.each(entries, fn entry ->
                Repo.insert!(
                  struct(
                    SetupCaptureCharge,
                    Map.merge(scope(binding), %{
                      capture_id: run.id,
                      kind: "entry",
                      relative_path: entry["relative_path"],
                      fingerprint_json: entry_identity(entry),
                      allowance_bytes: 0,
                      lease_generation: run.scan_epoch,
                      lease_token: lease,
                      state: "committed",
                      actual_bytes: 0
                    })
                  )
                )
              end)

              Repo.insert!(
                struct(
                  SetupCapturePage,
                  Map.merge(scope(binding), %{
                    capture_id: run.id,
                    scan_epoch: run.scan_epoch,
                    directory: directory,
                    sequence: batch["seq"],
                    payload_digest: digest,
                    admitted_count: length(entries)
                  })
                )
              )

              update_counter(counter,
                entries_admitted: counter.entries_admitted + length(entries)
              )

              {:ok, :bounded}
            else
              false -> {:error, :acquisition_incomplete}
              error -> error
            end
        end
    end
  end

  defp new_entries(run, entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, added} ->
      case charge(run.id, "entry", entry["relative_path"]) do
        nil ->
          {:cont, {:ok, [entry | added]}}

        %{fingerprint_json: identity} ->
          if identity == entry_identity(entry),
            do: {:cont, {:ok, added}},
            else: {:halt, {:error, :acquisition_incomplete}}
      end
    end)
  end

  defp entry_identity(entry), do: Map.take(entry, ~w(kind error_code))

  # The claimed run carries its server-persisted setup marker across a purge.
  # Removing a binding can withdraw authority, never select the legacy reader.
  def bounded?(%{id: id} = run), do: setup_run?(run) or match?({:ok, _}, SetupCapture.binding(id))

  defp setup_run?(%{counts: counts}) when is_map(counts),
    do: Corpora.digest?(counts["setup_connection_digest"])

  defp setup_run?(_), do: false

  # Only metadata inspection and body reading occur outside the short fence.
  def read(run, lease, root, %{"kind" => "file", "relative_path" => relative}) do
    path = Path.join(root, relative)

    if Path.extname(path) in ~w(.md .markdown .txt) do
      with {:ok, observed} <- LocalImport.inspect_document(root, path),
           {:ok, reservation} <- fenced(fn -> reserve_body(run, lease, relative, observed) end) do
        case reservation do
          :cached -> :skip
          bounds -> LocalImport.read_document(root, path, bounds)
        end
      end
    else
      {:excluded, :unsupported_extension}
    end
  end

  def read(_, _, _, %{"error_code" => "symlink_not_allowed"}), do: {:error, :symlink_not_allowed}
  def read(_, _, _, _), do: {:error, :unsupported_file}

  defp reserve_body(run, lease, path, observed) do
    with :ok <- Capture.check_lease(run.id, lease),
         {:ok, binding} <- SetupCapture.binding(run.id),
         true <- not is_nil(charge(run.id, "entry", path)) do
      case charge(run.id, "body", path) do
        nil ->
          with {:ok, count} <- counter(run.id),
               true <- count.files_reserved < binding.limits_json["max_files"],
               true <- observed["size"] <= binding.limits_json["max_file_bytes"],
               true <-
                 count.bytes_reserved + observed["size"] <= binding.limits_json["max_body_bytes"] do
            Repo.insert!(
              struct(
                SetupCaptureCharge,
                Map.merge(scope(binding), %{
                  capture_id: run.id,
                  kind: "body",
                  relative_path: path,
                  fingerprint_json: observed["fingerprint"],
                  allowance_bytes: observed["size"],
                  lease_generation: run.scan_epoch,
                  lease_token: lease,
                  state: "reserved"
                })
              )
            )

            update_counter(count,
              files_reserved: count.files_reserved + 1,
              bytes_reserved: count.bytes_reserved + observed["size"]
            )

            {:ok,
             %{"allowance_bytes" => observed["size"], "fingerprint" => observed["fingerprint"]}}
          else
            false -> {:error, :acquisition_incomplete}
            error -> error
          end

        %{state: "committed"} = saved ->
          if saved.fingerprint_json == observed["fingerprint"] and current_evidence?(saved),
            do: {:ok, :cached},
            else: {:error, :acquisition_incomplete}

        _ ->
          {:error, :acquisition_outcome_unknown}
      end
    else
      false -> {:error, :acquisition_incomplete}
      error -> error
    end
  end

  defp current_evidence?(saved) do
    case {saved.source_ref, saved.revision_ref} do
      {%{"id" => source}, %{"id" => revision, "digest" => digest}} ->
        Corpora.rows(
          """
          SELECT s.id FROM evidence_sources s JOIN evidence_revisions r ON r.id=s.latest_revision_id AND r.workspace_id=s.workspace_id
          WHERE s.workspace_id=? AND s.id=? AND s.status='active' AND r.id=? AND r.body_hash=?
            AND NOT EXISTS(SELECT 1 FROM revision_use_holds h WHERE h.workspace_id=s.workspace_id AND h.revision_id=r.id)
          """,
          [Store.workspace(), source, revision, digest]
        ) != []

      _ ->
        false
    end
  end

  def authorize_documents(run, lease, documents) do
    if bounded?(run) do
      with :ok <- check(run) do
        Enum.reduce_while(documents, :ok, fn {path, result}, :ok ->
          case {charge(run.id, "body", path), result} do
            {%{
               state: "reserved",
               lease_token: ^lease,
               lease_generation: epoch,
               allowance_bytes: size
             }, {:ok, %{"body" => body, "external_id" => ^path}}}
            when epoch == run.scan_epoch and byte_size(body) == size ->
              {:cont, :ok}

            {_, {:ok, _}} ->
              {:halt, {:error, :acquisition_incomplete}}

            {_, _} ->
              {:cont, :ok}
          end
        end)
      end
    else
      :ok
    end
  end

  # Joins Writer's source/charge/counter transaction. Unknown reads retain space.
  def settle(run, lease, path, result) do
    if bounded?(run) do
      case {charge(run.id, "body", path), result} do
        {%{state: "reserved", lease_token: ^lease} = charged, {:ok, %{"body" => body}}} ->
          [
            %{
              "source_id" => source,
              "revision_id" => revision,
              "body_hash" => hash,
              "body_bytes" => size
            }
          ] =
            Corpora.rows(
              "SELECT source_id,revision_id,body_hash,body_bytes FROM capture_items WHERE run_id=? AND relative_path=?",
              [run.id, path]
            )

          if size != byte_size(body) or
               hash != Base.encode16(:crypto.hash(:sha256, body), case: :lower),
             do: Repo.rollback(:acquisition_incomplete)

          {:ok, count} = counter(run.id)

          Repo.update!(
            Ecto.Changeset.change(charged,
              state: "committed",
              actual_bytes: size,
              source_ref: %{"id" => source, "digest" => hash},
              revision_ref: %{"id" => revision, "digest" => hash},
              content_hash: hash,
              lock_version: charged.lock_version + 1
            )
          )

          update_counter(count, bytes_committed: count.bytes_committed + size)

        {%{state: "reserved", lease_token: ^lease} = charged, _} ->
          Repo.update!(
            Ecto.Changeset.change(charged,
              state: "uncertain",
              lock_version: charged.lock_version + 1
            )
          )

        {_, {:ok, _}} ->
          Repo.rollback(:acquisition_incomplete)

        _ ->
          :ok
      end
    end

    :ok
  end

  defp update_counter(counter, fields) do
    counter
    |> Ecto.Changeset.change(fields)
    |> Ecto.Changeset.optimistic_lock(:lock_version)
    |> Repo.update!()
  end

  defp counter(id) do
    case Repo.one(from c in Store.scoped(SetupCaptureCounter), where: c.capture_id == ^id) do
      nil -> {:error, :acquisition_incomplete}
      value -> {:ok, value}
    end
  end

  defp charge(id, kind, path),
    do:
      Repo.one(
        from c in Store.scoped(SetupCaptureCharge),
          where: c.capture_id == ^id and c.kind == ^kind and c.relative_path == ^path
      )

  defp scope(b),
    do: %{workspace_id: b.workspace_id, owner_id: b.owner_id, session_id: b.session_id}

  defp fenced(fun), do: Purge.synchronize(fn -> Store.transaction(fun) end)
end
