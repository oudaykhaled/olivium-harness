defmodule HarnessForge.Evidence.Passages do
  @moduledoc "Versioned contiguous UTF-8 passage indexes; all serving revalidates original bytes."
  import Ecto.Query
  alias HarnessForge.{Contracts, Repo, Workspaces}
  alias HarnessForge.Evidence.{Corpora, Passage, PassageSet, Revision, RevisionUseHolds, Store}
  alias HarnessForge.Privacy.Purge
  @chunker "utf8-parent-v2"
  @parser "captured-metadata-v2"

  def versions, do: %{"chunker" => @chunker, "parser" => @parser, "fts" => "unicode61-v1"}

  def index_revision(id, opts \\ []) do
    with true <- Keyword.keyword?(opts) and Keyword.keys(opts) == [],
         :ok <- Workspaces.ensure_writable(),
         :ok <- Purge.ready(),
         {:ok, checked} <- checked_revision(id),
         {:ok, chunks} <- chunks(checked.revision.body),
         {:ok, set} <- prepare(checked, chunks),
         :ok <- insert_chunks(set, checked.source.title, checked.revision.body, chunks),
         {:ok, result} <- finish(set, chunks) do
      {:ok, result}
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  defp checked_revision(id) do
    Purge.synchronize(fn ->
      Store.transaction(fn ->
        with :ok <- Purge.ready(),
             {:ok, reference} <- revision_reference(id),
             :ok <-
               RevisionUseHolds.assert_use(
                 reference.source_id,
                 id,
                 reference.body_hash,
                 "retrieval"
               ),
             {:ok, checked} <- Corpora.current_source(reference.source_id, id) do
          {:ok, checked}
        end
      end)
    end)
  end

  # Admission reads only identity metadata. The body is hydrated only after
  # the authoritative hold check and the existing current-source checks.
  defp revision_reference(id) do
    if Corpora.uuid?(id) do
      case Repo.one(
             from r in Store.scoped(Revision),
               where: r.id == ^id,
               select: %{source_id: r.source_id, body_hash: r.body_hash}
           ) do
        nil -> {:error, :not_found}
        reference -> {:ok, reference}
      end
    else
      {:error, :not_found}
    end
  end

  @doc "Pure chunker: original, contiguous half-open UTF-8 spans, without normalization."
  def chunks(body) when is_binary(body) and byte_size(body) <= 1_048_576 do
    if String.valid?(body) and not String.contains?(body, <<0>>) do
      {:ok, chunk(body, 0, 0, [])}
    else
      {:error, :binary_file}
    end
  end

  def chunks(_), do: {:error, :file_too_large}

  defp chunk(body, start, _, acc) when start == byte_size(body), do: Enum.reverse(acc)

  defp chunk(body, start, ordinal, acc) do
    maximum = boundary_before(body, min(start + 2048, byte_size(body)))
    # Prefer a complete paragraph over an arbitrary byte limit. A short final
    # paragraph must not inherit the incomplete status of a preceding long one.
    breaks = break_ends(binary_part(body, start, maximum - start))
    finish = if breaks == [], do: maximum, else: start + List.last(breaks)
    {parent_start, parent_end} = parent_bounds(body, start, finish)

    item = %{
      "ordinal" => ordinal,
      "start_byte" => start,
      "end_byte" => finish,
      "snippet_hash" => Store.hash(binary_part(body, start, finish - start)),
      "parent_start_byte" => parent_start,
      "parent_end_byte" => parent_end,
      "parent_hash" => Store.hash(binary_part(body, parent_start, parent_end - parent_start))
    }

    chunk(body, finish, ordinal + 1, [item | acc])
  end

  defp parent_bounds(body, start, finish) do
    left = paragraph_start(body, start)
    right = paragraph_end(body, finish)

    if is_integer(left) and is_integer(right) and right - left <= 4096 do
      previous = if left > 0, do: paragraph_start(body, left - 1), else: 0
      following = if right < byte_size(body), do: paragraph_end(body, right + 1), else: right
      context_left = if is_integer(previous) and left - previous <= 512, do: previous, else: left

      context_right =
        if is_integer(following) and following - right <= 512, do: following, else: right

      if context_right - context_left <= 4096,
        do: {context_left, context_right},
        else: {left, right}
    else
      {boundary_after(body, max(0, start - 512)),
       boundary_before(body, min(byte_size(body), finish + 512))}
    end
  end

  # LF/CRLF blank-line boundaries are parser-versioned. An overlong paragraph
  # is never declared complete merely because a byte window ends at a newline.
  defp break_ends(bytes),
    do:
      :binary.matches(bytes, ["\n\n", "\r\n\r\n"])
      |> Enum.map(fn {offset, size} -> offset + size end)

  defp paragraph_boundary?(body, offset) do
    offset == 0 or offset == byte_size(body) or
      (offset >= 2 and binary_part(body, offset - 2, 2) == "\n\n") or
      (offset >= 4 and binary_part(body, offset - 4, 4) == "\r\n\r\n")
  end

  defp paragraph_start(body, offset) do
    left = boundary_after(body, max(0, offset - 4096))

    case break_ends(binary_part(body, left, offset - left)) do
      [] -> if left == 0, do: 0
      ends -> left + List.last(ends)
    end
  end

  defp paragraph_end(body, offset) do
    if paragraph_boundary?(body, offset) do
      offset
    else
      right = boundary_before(body, min(byte_size(body), offset + 4096))

      case break_ends(binary_part(body, offset, right - offset)) do
        [] -> if right == byte_size(body), do: right
        [first | _] -> offset + first
      end
    end
  end

  defp boundary_before(body, position) when position == byte_size(body), do: position
  defp boundary_before(_body, 0), do: 0

  defp boundary_before(body, position) do
    if continuation?(:binary.at(body, position)),
      do: boundary_before(body, position - 1),
      else: position
  end

  defp boundary_after(body, position) when position == byte_size(body), do: position

  defp boundary_after(body, position) do
    if continuation?(:binary.at(body, position)),
      do: boundary_after(body, position + 1),
      else: position
  end

  defp continuation?(byte), do: byte >= 128 and byte < 192

  defp prepare(checked, chunks) do
    Purge.synchronize(fn ->
      Store.transaction(fn ->
        with :ok <- Purge.ready(),
             {:ok, _} <- Corpora.current_source(checked.source.id, checked.revision.id) do
          existing =
            Repo.one(
              from s in Store.scoped(PassageSet),
                where:
                  s.revision_id == ^checked.revision.id and s.chunker_version == @chunker and
                    s.parser_version == @parser
            )

          if existing do
            {:ok, existing}
          else
            Repo.insert(%PassageSet{
              workspace_id: Store.workspace(),
              source_id: checked.source.id,
              revision_id: checked.revision.id,
              body_hash: checked.revision.body_hash,
              body_bytes: byte_size(checked.revision.body),
              chunker_version: @chunker,
              parser_version: @parser,
              state: "indexing",
              passage_count: length(chunks),
              indexed_count: 0
            })
          end
        end
      end)
    end)
  end

  defp insert_chunks(%{state: "ready"}, _, _, _), do: :ok

  defp insert_chunks(%{state: state}, _, _, _) when state in ["denied", "failed"],
    do: {:error, :index_incomplete}

  defp insert_chunks(set, title, body, chunks) do
    chunks
    |> Enum.chunk_every(100)
    |> Enum.reduce_while(:ok, fn batch, :ok ->
      result =
        Purge.synchronize(fn ->
          Store.transaction(fn ->
            with :ok <- Purge.ready(),
                 {:ok, _} <- Corpora.current_source(set.source_id, set.revision_id) do
              Enum.each(batch, fn span ->
                case Repo.one(
                       from p in Passage,
                         where: p.passage_set_id == ^set.id and p.ordinal == ^span["ordinal"]
                     ) do
                  nil ->
                    attrs =
                      Map.new(span, fn {key, value} -> {String.to_existing_atom(key), value} end)

                    passage =
                      struct(
                        Passage,
                        Map.merge(attrs, %{
                          id: Ecto.UUID.generate(),
                          workspace_id: Store.workspace(),
                          passage_set_id: set.id
                        })
                      )

                    {:ok, passage} = Repo.insert(passage)

                    text =
                      binary_part(body, span["start_byte"], span["end_byte"] - span["start_byte"])

                    Corpora.query!(
                      "INSERT INTO passage_search(rowid,passage_id,workspace_id,title,body) VALUES(?,?,?,?,?)",
                      [passage.rowid, passage.id, Store.workspace(), title, text]
                    )

                  stored ->
                    if Map.take(Store.dto(stored), Map.keys(span)) != span,
                      do: Repo.rollback(:invalid_passage)
                end
              end)

              count =
                Repo.aggregate(from(p in Passage, where: p.passage_set_id == ^set.id), :count)

              Repo.update_all(
                from(s in PassageSet, where: s.id == ^set.id and s.state == "indexing"),
                set: [indexed_count: count, updated_at: Store.now()]
              )

              {:ok, :indexed}
            end
          end)
        end)

      case result do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp finish(set, chunks) do
    Purge.synchronize(fn ->
      Store.transaction(fn ->
        with :ok <- Purge.ready(),
             {:ok, _} <- Corpora.current_source(set.source_id, set.revision_id) do
          current = Repo.get!(PassageSet, set.id)
          count = Repo.aggregate(from(p in Passage, where: p.passage_set_id == ^set.id), :count)

          indexed =
            Corpora.rows(
              "SELECT count(*) AS n FROM passage_search f JOIN passages p ON p.rowid=f.rowid WHERE p.passage_set_id=? AND p.workspace_id=?",
              [set.id, Store.workspace()]
            )

          if count != length(chunks) or indexed != [%{"n" => count}],
            do: Repo.rollback(:index_incomplete)

          if current.state != "ready" do
            {:ok, _} =
              current
              |> Ecto.Changeset.change(
                state: "ready",
                indexed_count: count,
                manifest_digest: Contracts.digest(chunks)
              )
              |> Repo.update()
          end

          {:ok, Store.dto(Repo.get!(PassageSet, set.id))}
        end
      end)
    end)
    |> case do
      {:ok, result} ->
        case publish(set, "") do
          :ok -> {:ok, result}
          error -> error
        end

      error ->
        error
    end
  end

  defp publish(set, after_id) do
    found =
      Corpora.rows(
        "SELECT corpus_id FROM corpus_members WHERE workspace_id=? AND source_id=? AND revision_id=? AND status='active' AND (passage_set_id IS NULL OR passage_set_id!=?) AND corpus_id>? ORDER BY corpus_id LIMIT 100",
        [Store.workspace(), set.source_id, set.revision_id, set.id, after_id]
      )

    result =
      Purge.synchronize(fn ->
        Store.transaction(fn ->
          with :ok <- Purge.ready(),
               {:ok, _} <- Corpora.current_source(set.source_id, set.revision_id) do
            Enum.each(found, fn row ->
              %{num_rows: count} =
                Corpora.query!(
                  "UPDATE corpus_members SET passage_set_id=?,updated_at=? WHERE workspace_id=? AND corpus_id=? AND source_id=? AND revision_id=? AND status='active' AND (passage_set_id IS NULL OR passage_set_id!=?)",
                  [
                    set.id,
                    Corpora.now(),
                    Store.workspace(),
                    row["corpus_id"],
                    set.source_id,
                    set.revision_id,
                    set.id
                  ]
                )

              if count > 0, do: Corpora.advance(row["corpus_id"])
            end)

            {:ok, :published}
          end
        end)
      end)

    case result do
      {:ok, _} when length(found) == 100 -> publish(set, List.last(found)["corpus_id"])
      {:ok, _} -> :ok
      error -> error
    end
  end

  def read(id, expected, caller) do
    Corpora.guard(caller, fn ->
      with {:ok, actual} <- envelope(id),
           true <- is_map(expected) and expected == Map.take(actual, Map.keys(expected)),
           true <-
             Enum.all?(
               ~w(passage_id source_id revision_id body_hash start_byte end_byte snippet_hash parent_start_byte parent_end_byte parent_hash),
               &Map.has_key?(expected, &1)
             ) do
        {:ok, actual}
      else
        false -> {:error, :invalid_passage}
        error -> error
      end
    end)
  end

  @doc false
  def envelope(id) do
    with true <- Corpora.uuid?(id),
         [row] <- Corpora.rows(window_sql(), [Store.workspace(), id]),
         {:ok, connection} <- Store.get(HarnessForge.Evidence.Connection, row["connection_id"]),
         :ok <-
           HarnessForge.Connectors.Registry.document_scope(connection, %{
             "external_id" => row["external_id"],
             "source_url" => row["source_url"],
             "metadata" => Corpora.decode(row["scope_metadata"])
           }),
         {:ok, snippet, parent} <- checked_window(row) do
      {:ok,
       Map.take(
         row,
         ~w(passage_id source_id revision_id body_hash start_byte end_byte snippet_hash parent_start_byte parent_end_byte parent_hash)
       )
       |> Map.merge(%{
         "title" => bounded_text(row["title"], 2000),
         "source_url" => safe_url(row["source_url"]),
         "document_status" => safe_status(row["document_status"]),
         "event_at" => date(row["event_at"]),
         "effective_at" => date(row["effective_at"]),
         "captured_at" => captured_at(row["captured_at"]),
         "snippet" => snippet,
         "parent_text" => parent,
         "parent_incomplete" => row["start_boundary"] != 1 or row["end_boundary"] != 1
       })}
    else
      _ -> {:error, :invalid_passage}
    end
  end

  # The SELECT never materializes r.body, full metadata or an unbounded title in
  # the BEAM. One original parent window plus SQL boundary proofs is sufficient
  # to prove both hashes and UTF-8 boundaries against the immutable revision.
  defp window_sql do
    scope_fields =
      ~w(repository kind pull_number project project_url owner_kind owner number project_id team_domain message_ts team_id channel_id space_id page_id)

    metadata =
      Enum.map_join(scope_fields, ",", fn key ->
        "'#{key}',CASE WHEN json_type(r.metadata,'$.#{key}') IN ('text','integer') AND length(CAST(json_extract(r.metadata,'$.#{key}') AS BLOB))<=2048 THEN json_extract(r.metadata,'$.#{key}') ELSE NULL END"
      end)

    """
    SELECT p.id AS passage_id, sets.source_id,sets.revision_id,sets.body_hash,
      p.start_byte,p.end_byte,p.snippet_hash,p.parent_start_byte,p.parent_end_byte,p.parent_hash,
      s.connection_id,
      CASE WHEN length(CAST(s.external_id AS BLOB))<=4096 THEN s.external_id ELSE NULL END AS external_id,
      CASE WHEN length(CAST(s.title AS BLOB))<=2000 THEN s.title ELSE NULL END AS title,
      CASE WHEN length(CAST(r.source_url AS BLOB))<=2048 THEN r.source_url ELSE NULL END AS source_url,
      r.captured_at,length(CAST(r.body AS BLOB)) AS body_bytes,
      CASE WHEN json_type(r.metadata,'$.document_status')='text'
        AND length(CAST(json_extract(r.metadata,'$.document_status') AS BLOB))<=200
        THEN json_extract(r.metadata,'$.document_status') ELSE NULL END AS document_status,
      CASE WHEN json_type(r.metadata,'$.event_at')='text'
        AND length(CAST(json_extract(r.metadata,'$.event_at') AS BLOB))<=64
        THEN json_extract(r.metadata,'$.event_at') ELSE NULL END AS event_at,
      CASE WHEN json_type(r.metadata,'$.effective_at')='text'
        AND length(CAST(json_extract(r.metadata,'$.effective_at') AS BLOB))<=64
        THEN json_extract(r.metadata,'$.effective_at') ELSE NULL END AS effective_at,
      json_object(#{metadata}) AS scope_metadata,
      substr(CAST(r.body AS BLOB),p.parent_start_byte+1,p.parent_end_byte-p.parent_start_byte) AS parent_window,
      CASE WHEN p.parent_start_byte=0
        OR (p.parent_start_byte>=2 AND substr(CAST(r.body AS BLOB),p.parent_start_byte-1,2)=X'0A0A')
        OR (p.parent_start_byte>=4 AND substr(CAST(r.body AS BLOB),p.parent_start_byte-3,4)=X'0D0A0D0A')
        THEN 1 ELSE 0 END AS start_boundary,
      CASE WHEN p.parent_end_byte=length(CAST(r.body AS BLOB))
        OR (p.parent_end_byte>=2 AND substr(CAST(r.body AS BLOB),p.parent_end_byte-1,2)=X'0A0A')
        OR (p.parent_end_byte>=4 AND substr(CAST(r.body AS BLOB),p.parent_end_byte-3,4)=X'0D0A0D0A')
        THEN 1 ELSE 0 END AS end_boundary
    FROM passages p
    JOIN passage_sets sets ON sets.id=p.passage_set_id AND sets.workspace_id=p.workspace_id
    JOIN evidence_sources s ON s.id=sets.source_id AND s.workspace_id=p.workspace_id
    JOIN source_connections c ON c.id=s.connection_id AND c.workspace_id=s.workspace_id
    JOIN evidence_revisions r ON r.id=sets.revision_id AND r.source_id=s.id AND r.workspace_id=s.workspace_id
    WHERE p.workspace_id=? AND p.id=? AND sets.state='ready'
      AND s.status='active' AND c.status='active' AND s.latest_revision_id=r.id AND r.body_hash=sets.body_hash
      AND (#{RevisionUseHolds.not_held_sql("r")})
      AND p.parent_start_byte>=0 AND p.start_byte>=p.parent_start_byte AND p.end_byte>p.start_byte
      AND p.parent_end_byte>=p.end_byte AND p.parent_end_byte-p.parent_start_byte BETWEEN 1 AND 4096
      AND p.parent_end_byte<=length(CAST(r.body AS BLOB))
      AND (#{HarnessForge.Company.CorpusReview.document_scope_sql()})
    LIMIT 1
    """
  end

  defp checked_window(row) do
    parent = row["parent_window"]
    start = row["start_byte"] - row["parent_start_byte"]
    size = row["end_byte"] - row["start_byte"]

    if is_binary(parent) and byte_size(parent) <= 4096 and String.valid?(parent) and
         Store.hash(parent) == row["parent_hash"] and start >= 0 and
         start + size <= byte_size(parent) do
      snippet = binary_part(parent, start, size)

      if String.valid?(binary_part(parent, 0, start)) and String.valid?(snippet) and
           Store.hash(snippet) == row["snippet_hash"],
         do: {:ok, snippet, parent},
         else: {:error, :invalid_offsets}
    else
      {:error, :invalid_offsets}
    end
  end

  defp captured_at(value) when is_binary(value) do
    case NaiveDateTime.from_iso8601(String.replace(value, " ", "T")) do
      {:ok, time} -> time |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()
      _ -> value
    end
  end

  defp bounded_text(value, limit), do: if(Corpora.text?(value, limit), do: value)

  defp safe_url(value) when is_binary(value) and byte_size(value) <= 2048 do
    uri = URI.parse(value)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
         is_nil(uri.userinfo),
       do: value
  end

  defp safe_url(_), do: nil
  defp safe_status(value), do: if(Corpora.text?(value, 200), do: value)

  defp date(value) when is_binary(value),
    do: if(match?({:ok, _, _}, DateTime.from_iso8601(value)), do: value)

  defp date(_), do: nil
end
