defmodule HarnessForge.Evidence.Capture.Writer do
  @moduledoc false
  alias HarnessForge.{Audit, Evidence, Repo}
  alias HarnessForge.Evidence.{Capture, Corpora, Store}
  alias HarnessForge.Evidence.SetupCaptureBounds
  alias HarnessForge.Privacy.Purge

  def commit(run, lease, documents) when is_list(documents) and length(documents) <= 100 do
    bytes = Enum.reduce(documents, 0, fn {_, result}, count -> count + document_bytes(result) end)

    if bytes <= 8_388_608 do
      Purge.synchronize(fn ->
        Store.transaction(fn ->
          with :ok <- Purge.ready(),
               :ok <- Capture.check_lease(run.id, lease),
               :ok <- SetupCaptureBounds.authorize_documents(run, lease, documents) do
            Enum.each(documents, fn {path, result} ->
              persist(run, path, result)
              SetupCaptureBounds.settle(run, lease, path, result)
            end)

            Corpora.query!(
              "UPDATE capture_runs SET checkpoint_seq=checkpoint_seq+1,lock_version=lock_version+1,lease_until=?,updated_at=? WHERE workspace_id=? AND id=? AND lease_token=? AND state='running'",
              [lease_until(), Corpora.now(), Store.workspace(), run.id, lease]
            )

            {:ok, _} =
              Audit.append("corpus.capture_batch", %{
                "run_id" => run.id,
                "files" => length(documents),
                "bytes" => bytes
              })

            {:ok, :committed}
          end
        end)
      end)
    else
      {:error, :file_too_large}
    end
  end

  def commit(_, _, _), do: {:error, :invalid_input}

  defp persist(run, path, {:ok, document}) do
    case Evidence.capture_document(run.connection_id, document) do
      {:ok, source} ->
        revision = source["latest_revision"]

        {:ok, changed} =
          Corpora.put_member(run.corpus_id, %{
            "source_id" => source["id"],
            "revision_id" => revision["id"],
            "action" => "include"
          })

        if changed, do: Corpora.advance(run.corpus_id)

        Corpora.query!(
          "UPDATE corpus_members SET last_seen_run_id=?,updated_at=? WHERE workspace_id=? AND corpus_id=? AND source_id=?",
          [run.id, Corpora.now(), Store.workspace(), run.corpus_id, source["id"]]
        )

        state = if source["changed"], do: "captured", else: "unchanged"

        Corpora.query!(
          "UPDATE capture_items SET state=?,source_id=?,revision_id=?,body_hash=?,body_bytes=?,error_code=NULL,attempts=attempts+1,updated_at=? WHERE run_id=? AND relative_path=?",
          [
            state,
            source["id"],
            revision["id"],
            revision["body_hash"],
            byte_size(document["body"]),
            Corpora.now(),
            run.id,
            path
          ]
        )

        {:ok, _} =
          HarnessForge.Jobs.PassageIndex.new(%{
            "workspace_id" => Store.workspace(),
            "revision_id" => revision["id"]
          })
          |> Oban.insert()

      {:error, _} ->
        Repo.rollback(:source_unavailable)
    end
  end

  defp persist(run, path, {:excluded, reason}), do: outcome(run, path, "excluded", reason)

  defp persist(run, path, {:error, reason}) do
    outcome(run, path, "failed", reason)

    Corpora.query!(
      "UPDATE capture_runs SET incomplete=1,error_code=?,updated_at=? WHERE workspace_id=? AND id=?",
      [safe_reason(reason), Corpora.now(), Store.workspace(), run.id]
    )
  end

  defp outcome(run, path, state, reason),
    do:
      Corpora.query!(
        "UPDATE capture_items SET state=?,error_code=?,attempts=attempts+1,updated_at=? WHERE run_id=? AND relative_path=?",
        [state, safe_reason(reason), Corpora.now(), run.id, path]
      )

  defp safe_reason(value)
       when value in [
              :file_too_large,
              :binary_file,
              :symlink_not_allowed,
              :unreadable_file,
              :unsupported_extension,
              :unsupported_file,
              :path_escape
            ],
       do: Atom.to_string(value)

  defp safe_reason(_), do: "unreadable_file"
  defp document_bytes({:ok, %{"body" => body}}), do: byte_size(body)
  defp document_bytes(_), do: 0
  defp lease_until, do: DateTime.utc_now() |> DateTime.add(120, :second) |> DateTime.to_iso8601()
end
