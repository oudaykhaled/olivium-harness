defmodule HarnessForge.Evidence do
  @moduledoc """
  Workspace-scoped source snapshots, exact byte citations and proposed claim revisions.

  Source bodies and search-index writes commit in the same SQLite transaction. Imported
  content is evidence data and is never interpreted as executable agent instructions.
  """
  import Ecto.Query
  alias HarnessForge.{Repo, Audit, Contracts, Goals, Workspaces}
  alias HarnessForge.Privacy.Purge
  alias HarnessForge.Company.Analysis

  alias HarnessForge.Evidence.{
    Store,
    Origin,
    LocalImport,
    Connection,
    Source,
    Revision,
    RevisionUseHolds,
    LocalUsePolicies,
    Citation,
    Claim,
    Decision
  }

  defdelegate restrict_revision(attrs, caller), to: RevisionUseHolds, as: :restrict
  defdelegate revision_restriction_status(event_id, caller), to: RevisionUseHolds, as: :status

  defdelegate resume_revision_cleanup(event_id, expected_version, caller),
    to: RevisionUseHolds,
    as: :resume

  def list_connections do
    {:ok,
     Repo.all(from c in Store.scoped(Connection), order_by: c.inserted_at)
     |> Enum.map(&Store.dto/1)}
  end

  def connect(attrs) do
    with :ok <- HarnessForge.Workspaces.ensure_writable(),
         :ok <- Store.required(attrs, ~w(name provider)),
         {:ok, provider_attrs} <- connection_attrs(attrs) do
      Store.transaction(fn ->
        with {:ok, connection} <-
               Repo.insert(%Connection{
                 workspace_id: Store.workspace(),
                 provider: attrs["provider"],
                 name: String.trim(attrs["name"]),
                 directory: provider_attrs["directory"],
                 config: provider_attrs["config"] || %{}
               }),
             {:ok, _} <- Audit.append("connection.created", %{"connection_id" => connection.id}) do
          {:ok, Store.dto(connection)}
        end
      end)
    end
  end

  def list_sources, do: list_sources(nil)

  def list_sources(context) do
    ids = Repo.all(from s in Store.scoped(Source), order_by: [asc: s.title, asc: s.id], select: s.id)

    result =
      Enum.flat_map(ids, fn id ->
        case get_source(id, context) do
          {:ok, source} -> [source]
          _ -> []
        end
      end)

    {:ok, result}
  end

  def get_source(id), do: get_source(id, nil)

  def get_source(id, context) do
    with :ok <- source_policy_current(id, "inspection", context),
         {:ok, source} <- Store.get(Source, id),
         result = source_dto(source, context),
         :ok <- source_policy_current(id, "inspection", context) do
      {:ok, result}
    end
  end

  @doc "Authorized metadata-only source browsing for bounded interactive views."
  def source_page(attrs, caller), do: source_page(attrs, caller, nil)
  def source_page(attrs, caller, context),
    do: HarnessForge.Company.CorpusReview.source_page(attrs, caller, context)

  @doc "Metadata for separately bounded, server-owned saved source selections."
  def source_summaries(refs, caller), do: source_summaries(refs, caller, nil)
  def source_summaries(refs, caller, context),
    do: HarnessForge.Company.CorpusReview.summary_refs(refs, caller, context)

  @doc "An exact bounded UTF-8 window using a current authorized inspection handle."
  def source_passage(token, attrs, caller), do: source_passage(token, attrs, caller, nil)
  def source_passage(token, attrs, caller, context),
    do: HarnessForge.Company.CorpusReview.passage(token, attrs, caller, context)

  def import_directory(connection_id) do
    with :ok <- HarnessForge.Workspaces.ensure_writable(),
         {:ok, connection} <- active_connection(connection_id),
         true <- connection.provider == "local" or {:error, :provider_unavailable},
         {:ok, documents} <- LocalImport.read_all(connection.directory) do
      Store.transaction(fn ->
        result =
          Enum.reduce_while(
            documents,
            {:ok, %{"imported" => 0, "unchanged" => 0, "source_ids" => []}},
            fn document, {:ok, result} ->
              case persist_document(connection, document) do
                {:ok, {source, changed?}} ->
                  key = if changed?, do: "imported", else: "unchanged"

                  next =
                    result
                    |> Map.update!(key, &(&1 + 1))
                    |> Map.update!("source_ids", &[source.id | &1])

                  {:cont, {:ok, next}}

                error ->
                  {:halt, error}
              end
            end
          )

        with {:ok, result} <- result,
             {:ok, count} <- mark_missing_sources(connection, documents) do
          {:ok, Map.put(result, "deleted", count)}
        end
      end)
    end
  end

  @doc "Imports a normalized text document using a previously approved source connection."
  def capture_document(connection_id, attrs), do: import_markdown(connection_id, attrs)

  @doc false
  def capture_document(connection_id, attrs, staging) do
    with :ok <- Workspaces.ensure_writable(),
         true <- Repo.in_transaction?() or {:error, :invalid_input},
         {:ok, connection} <- active_connection(connection_id),
         :ok <- validate_document(attrs),
         :ok <- document_scope(connection, attrs),
         {:ok, {source, changed?}} <- persist_document(connection, attrs, staging),
         {:ok, ref} <- revision_reference(source.latest_revision_id) do
      {:ok, %{"id" => source.id, "changed" => changed?,
        "latest_revision" => %{"id" => source.latest_revision_id, "body_hash" => ref.body_hash}}}
    end
  end

  def import_markdown(connection_id, attrs) do
    with :ok <- HarnessForge.Workspaces.ensure_writable(),
         {:ok, connection} <- active_connection(connection_id),
         :ok <- validate_document(attrs),
         :ok <- document_scope(connection, attrs) do
      Store.transaction(fn ->
        with {:ok, {source, changed?}} <- persist_document(connection, attrs),
             :ok <- source_policy_current(source.id, "inspection", nil) do
          {:ok, source_dto(source) |> Map.put("changed", changed?)}
        end
      end)
    end
  end

  @doc "Sync one bounded page. A false complete flag requires another explicit sync."
  def sync(connection_id, opts \\ []) do
    with :ok <- HarnessForge.Workspaces.ensure_writable(),
         {:ok, connection} <- active_connection(connection_id) do
      if connection.provider == "local",
        do: import_directory(connection_id),
        else: sync_remote(connection, opts)
    end
  end

  defp sync_remote(connection, opts) do
    with {:ok, adapter} <- connector(connection.provider) do
      context = %{
        "connection_id" => connection.id,
        "request_options" => Keyword.take(opts, [:plug])
      }

      case adapter.fetch_page(connection.config, connection.cursor, context) do
        {:ok, page} ->
          case commit_page(connection, page) do
            {:ok, _} = result ->
              result

            {:error, _} = result ->
              record_sync_error(connection, %HarnessForge.Contracts.Error{
                code: "source_page_rejected",
                message: "Source page was not committed"
              })

              result
          end

        {:error, %HarnessForge.Contracts.Error{} = error} ->
          record_sync_error(connection, error)
          {:error, error}
      end
    end
  end

  defp commit_page(before, page) do
    Store.transaction(fn ->
      with {:ok, connection} <- active_connection(before.id),
           true <- connection.cursor == before.cursor and connection.config == before.config,
           {:ok, counts} <- import_page(connection, page["items"]),
           {:ok, _} <-
             connection
             |> Ecto.Changeset.change(
               cursor: page["next_cursor"],
               sync_complete: page["complete"],
               sync_state: if(page["complete"], do: "complete", else: "incomplete"),
               last_synced_at: Store.now()
             )
             |> Repo.update(),
           {:ok, _} <-
             Audit.append("connection.page_imported", %{
               "connection_id" => connection.id,
               "count" => length(page["items"])
             }) do
        {:ok, Map.merge(counts, Map.take(page, ["next_cursor", "complete"]))}
      else
        false -> {:error, :stale_cursor}
        error -> error
      end
    end)
  end

  defp import_page(connection, documents) do
    Enum.reduce_while(documents, {:ok, %{"imported" => 0, "unchanged" => 0}}, fn attrs,
                                                                                 {:ok, counts} ->
      case import_markdown(connection.id, attrs) do
        {:ok, source} ->
          key = if source["changed"], do: "imported", else: "unchanged"
          {:cont, {:ok, Map.update!(counts, key, &(&1 + 1))}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp record_sync_error(before, error) do
    Store.transaction(fn ->
      with {:ok, connection} <- active_connection(before.id),
           true <- connection.cursor == before.cursor do
        changes = [sync_state: error.code, sync_complete: false]

        changes =
          if error.code == "source_access_denied",
            do: Keyword.put(changes, :status, "revoked"),
            else: changes

        with {:ok, _} <- connection |> Ecto.Changeset.change(changes) |> Repo.update(),
             {:ok, _} <-
               Audit.append("connection.sync_failed", %{"connection_id" => connection.id}),
             :ok <-
               if(changes[:status] == "revoked",
                 do: invalidate_connection_sources(connection.id),
                 else: :ok
               ) do
          {:ok, :recorded}
        end
      else
        false -> {:error, :stale_cursor}
        other -> other
      end
    end)
  end

  def revoke_connection(id) do
    Store.transaction(fn ->
      with {:ok, connection} <- Store.get(Connection, id),
           {:ok, connection} <-
             connection |> Ecto.Changeset.change(status: "revoked") |> Repo.update(),
           {:ok, _} <- Audit.append("connection.revoked", %{"connection_id" => id}),
           :ok <- invalidate_connection_sources(id) do
        {:ok, Store.dto(connection)}
      end
    end)
  end

  def revoke_source(id) do
    Store.transaction(fn ->
      with {:ok, source} <- Store.get(Source, id),
           {:ok, source} <- source |> Ecto.Changeset.change(status: "revoked") |> Repo.update(),
           {:ok, _} <- Audit.append("source.revoked", %{"source_id" => id}),
           :ok <- HarnessForge.Evidence.Corpora.invalidate_source(id, :source_revoked) do
        {:ok, source_dto(source)}
      end
    end)
  end

  @doc "FTS5 search with literal tokens, restricted to active sources and current revisions."
  def search(query), do: search(query, nil)

  def search(query, context) when is_binary(query) do
    tokens =
      Regex.scan(~r/[\p{L}\p{N}_]+/u, String.slice(query, 0, 500))
      |> List.flatten()
      |> Enum.take(20)

    if tokens == [] do
      {:ok, []}
    else
      expression = Enum.map_join(tokens, " AND ", fn token -> "\"" <> token <> "\"" end)

      with {:ok, {policy_sql, policy_params}} <- LocalUsePolicies.not_denied_sql("r", "inspection", context) do
      sql = """
      SELECT s.id FROM evidence_search f
      JOIN evidence_revisions r ON r.id = f.revision_id
      JOIN evidence_sources s ON s.latest_revision_id = r.id
      JOIN source_connections c ON c.id = s.connection_id
      WHERE evidence_search MATCH ? AND f.workspace_id = ? AND s.workspace_id = ?
        AND s.status = 'active' AND c.status = 'active'
        AND #{RevisionUseHolds.not_held_sql("r")} AND #{policy_sql}
      ORDER BY rank LIMIT 50
      """

      case Repo.query(sql, [expression, Store.workspace(), Store.workspace()] ++ policy_params) do
        {:ok, %{rows: rows}} ->
          {:ok,
           Enum.map(rows, fn [id] ->
             {:ok, source} = get_source(id, context)
             source
           end)}

        {:error, _} ->
          {:error, :search_failed}
      end
      end
    end
  end

  def search(_, _), do: {:error, :invalid_input}

  @doc "Creates an immutable citation with an exclusive UTF-8 byte end offset."
  def citation(revision_id, start_byte, end_byte), do: citation(revision_id, start_byte, end_byte, nil, "inspection")
  def citation(revision_id, start_byte, end_byte, context), do: citation(revision_id, start_byte, end_byte, context, "inspection")

  def citation(revision_id, start_byte, end_byte, context, purpose) do
    Purge.synchronize(fn -> create_citation(revision_id, start_byte, end_byte, context, purpose) end)
  end

  defp create_citation(revision_id, start_byte, end_byte, context, purpose) do
    with :ok <- HarnessForge.Workspaces.ensure_writable(),
         {:ok, revision} <- eligible_revision(revision_id, context, purpose),
         {:ok, snippet} <- snippet(revision.body, start_byte, end_byte),
         {:ok, citation} <-
           Repo.insert(%Citation{
             workspace_id: Store.workspace(),
             revision_id: revision.id,
             start_byte: start_byte,
             end_byte: end_byte,
             snippet: snippet,
             snippet_hash: Store.hash(snippet)
           }) do
      {:ok, Store.dto(citation)}
    end
  end

  def create_claim(attrs), do: create_claim(attrs, nil)

  def create_claim(attrs, context) do
    Purge.synchronize(fn ->
      Store.transaction(fn ->
        with :ok <- Workspaces.ensure_writable(),
             :ok <- Store.required(attrs, ["text"]),
             {:ok, citations} <- validate_origin(attrs["basis"], attrs["citations"], context, creation_purpose(context)),
             :ok <- analysis_text(attrs["text"], attrs["basis"]),
             {:ok, previous} <- previous_claim(attrs["supersedes_id"], context),
             :ok <- same_origin(previous, attrs) do
          id = Ecto.UUID.generate()
          text = String.trim(attrs["text"])

          claim = %Claim{
            id: id,
            workspace_id: Store.workspace(),
            family_id: if(previous, do: previous.family_id, else: id),
            supersedes_id: previous && previous.id,
            text: text,
            citations: citations,
            basis: attrs["basis"],
            revision_hash: claim_hash(text, citations, attrs["basis"]),
            inserted_at: Store.now()
          }

          with {:ok, claim} <-
                 claim
                 |> Ecto.Changeset.change()
                 |> Ecto.Changeset.unique_constraint(:supersedes_id)
                 |> Repo.insert(),
               {:ok, _} <- Audit.append("claim.proposed", %{"claim_id" => claim.id}) do
            {:ok, claim_dto(claim, context, creation_purpose(context))}
          else
            {:error, %Ecto.Changeset{}} -> {:error, :already_superseded}
            error -> error
          end
        end
      end)
    end)
  end

  def list_claims, do: list_claims(nil)

  def list_claims(context) do
    ids = Repo.all(from c in Store.scoped(Claim), order_by: [desc: c.inserted_at], select: c.id)
    {:ok, Enum.flat_map(ids, fn id ->
      case get_claim(id, context) do
        {:ok, claim} -> [claim]
        _ -> []
      end
    end)}
  end

  def get_claim(id), do: get_claim(id, nil)
  def get_claim(id, context), do: get_claim(id, context, "inspection")

  def get_claim(id, context, purpose) do
    with :ok <- assert_claim_use(id, purpose, context),
         {:ok, claim} <- Store.get(Claim, id),
         result = claim_dto(claim, context, purpose),
         :ok <- assert_claim_use(id, purpose, context) do
      {:ok, result}
    end
  end

  def approved_claims, do: approved_claims(nil)

  def approved_claims(context) do
    claims =
      Repo.all(
        from c in Store.scoped(Claim),
          join: d in Decision,
          on:
            d.claim_id == c.id and d.workspace_id == c.workspace_id and
              d.decision == "approve" and d.revision_hash == c.revision_hash,
          left_join: newer in Claim,
          on: newer.supersedes_id == c.id,
          where: is_nil(newer.id),
          order_by: c.id,
          select: c.id
      )

    eligible =
      Enum.flat_map(claims, fn id ->
        with :ok <- assert_claim_use(id, "compile", context),
             {:ok, claim} <- Store.get(Claim, id),
             {:ok, _} <- validate_claim(claim, context, "compile"),
             true <- approval_ready?(Store.dto(claim)) do
          [claim_dto(claim, context)]
        else
          _ -> []
        end
      end)

    {:ok, eligible}
  end

  @doc "Validates current scoped origin and the exact immutable claim revision hash."
  @spec validate_claim(map()) :: {:ok, map()} | {:error, atom()}
  def validate_claim(claim), do: validate_claim(claim, nil, "compile")
  def validate_claim(claim, context), do: validate_claim(claim, context, "compile")
  def validate_claim(%Claim{} = claim, context, purpose) do
    with {:ok, _} <- validate_claim(Store.dto(claim), context, purpose), do: {:ok, claim}
  end

  def validate_claim(claim, context, purpose) when is_map(claim) and purpose in ~w(inspection retrieval analysis compile) do
    with :ok <- Store.required(claim, ~w(text revision_hash)),
         :ok <- claim_use_current(claim, context, purpose),
         {:ok, citations} <- validate_origin(claim["basis"], claim["citations"], context, purpose),
         {:ok, _} <- Origin.references(claim),
         :ok <- analysis_text(claim["text"], claim["basis"]),
         true <-
           claim["revision_hash"] == claim_hash(claim["text"], citations, claim["basis"]) do
      {:ok, claim}
    else
      false -> {:error, :invalid_claim_basis}
      error -> error
    end
  end

  def validate_claim(_, _, _), do: {:error, :invalid_claim_basis}

  @doc "Whether a validated claim has the human resolution needed for approval."
  def approval_ready?(%{"basis" => %{"kind" => "company_analysis"}} = claim),
    do: Analysis.approval_ready?(claim)

  def approval_ready?(_), do: true

  defp validate_origin(nil, citations, context, purpose), do: validate_citations(citations, context, purpose)

  defp validate_origin(%{"kind" => "company_analysis"} = basis, citations, context, purpose),
    do: Analysis.validate_origin(basis, citations, context, purpose)

  defp validate_origin(basis, [], _context, _purpose) when is_map(basis) do
    with true <- Enum.sort(Map.keys(basis)) == ~w(goal_content_hash goal_id kind version),
         true <- basis["version"] === 1 and basis["kind"] == "goal",
         {:ok, _} <- Ecto.UUID.cast(basis["goal_id"]),
         hash when is_binary(hash) <- basis["goal_content_hash"],
         true <- Regex.match?(~r/\A[0-9a-f]{64}\z/, hash) do
      case Store.get(HarnessForge.Evidence.Goal, basis["goal_id"]) do
        {:ok, goal} ->
          if Goals.content_hash(goal) == hash,
            do: {:ok, []},
            else: {:error, :stale_goal_basis}

        _ ->
          {:error, :stale_goal_basis}
      end
    else
      _ -> {:error, :invalid_claim_basis}
    end
  end

  defp validate_origin(_, _, _, _), do: {:error, :invalid_claim_basis}

  defp claim_hash(text, citations, nil) do
    canonical = %{
      "text" => text,
      "citations" =>
        Enum.map(citations, &Map.take(&1, ~w(id revision_id start_byte end_byte snippet_hash)))
    }

    Store.hash(Jason.encode!(canonical, maps: :strict))
  end

  defp claim_hash(text, citations, %{"kind" => "company_analysis"} = basis) do
    canonical =
      citations
      |> Enum.map(&Map.take(&1, ~w(id revision_id start_byte end_byte snippet_hash)))
      |> Enum.sort_by(&{&1["revision_id"], &1["start_byte"], &1["end_byte"], &1["id"]})

    Contracts.digest(%{
      "kind" => "company-analysis-claim",
      "version" => 1,
      "text" => text,
      "citations" => canonical,
      "basis" => basis
    })
  end

  defp claim_hash(text, [], basis),
    do:
      Contracts.digest(%{
        "kind" => "goal-origin-claim",
        "version" => 1,
        "text" => text,
        "basis" => basis
      })

  defp same_origin(previous, attrs) do
    previous = if previous, do: Store.dto(previous)

    if analysis_origin?(previous && previous["basis"]) or analysis_origin?(attrs["basis"]) do
      Analysis.validate_successor(previous, attrs)
    else
      if is_nil(previous) or is_nil(previous["basis"]) == is_nil(attrs["basis"]),
        do: :ok,
        else: {:error, :claim_origin_change}
    end
  end

  defp analysis_origin?(%{"kind" => "company_analysis"}), do: true
  defp analysis_origin?(_), do: false

  defp analysis_text(text, %{"kind" => "company_analysis", "guidance" => guidance}) do
    if String.trim(text) == Analysis.render_guidance(guidance),
      do: :ok,
      else: {:error, :invalid_claim_basis}
  end

  defp analysis_text(_, _), do: :ok

  @doc false
  def validate_citations(citations), do: validate_citations(citations, nil, "inspection")
  def validate_citations(citations, context), do: validate_citations(citations, context, "inspection")
  def validate_citations(citations, context, purpose) when is_list(citations) and length(citations) in 1..100 do
    Enum.reduce_while(citations, {:ok, []}, fn attrs, {:ok, result} ->
      with true <- is_map(attrs),
           {:ok, revision_id} <- citation_revision_id(attrs["id"]),
           {:ok, revision} <- eligible_revision(revision_id, context, purpose),
           {:ok, stored} <- Store.get(Citation, attrs["id"]),
           {:ok, actual} <- snippet(revision.body, stored.start_byte, stored.end_byte),
           true <- Store.hash(actual) == stored.snippet_hash,
           true <-
             Enum.all?(~w(revision_id start_byte end_byte snippet snippet_hash), fn key ->
               not Map.has_key?(attrs, key) or attrs[key] == Store.dto(stored)[key]
             end) do
        {:cont, {:ok, [Store.dto(stored) | result]}}
      else
        _ -> {:halt, {:error, :invalid_citation}}
      end
    end)
    |> case do
      {:ok, validated} -> {:ok, Enum.reverse(validated)}
      error -> error
    end
  end

  def validate_citations(_, _, _), do: {:error, :invalid_citation}

  defp persist_document(connection, attrs, staging \\ nil) do
    with :ok <- validate_document(attrs) do
      source =
        Repo.one(
          from s in Store.scoped(Source),
            where:
              s.connection_id == ^connection.id and s.provider == ^connection.provider and
                s.external_id == ^attrs["external_id"]
        )

      with :ok <- source_unheld(source) do
        hash = Store.hash(attrs["body"])

        latest =
          source && source.latest_revision_id &&
            Repo.one(from r in Store.scoped(Revision), where: r.id == ^source.latest_revision_id,
              select: struct(r, [:id, :source_id, :body_hash, :revision, :source_url, :source_updated_at, :metadata]))

        unchanged? = latest && source.status == "active" && source.title == attrs["title"] &&
          latest.body_hash == hash && latest.source_url == attrs["source_url"] &&
          latest.source_updated_at == attrs["source_updated_at"] && latest.metadata == (attrs["metadata"] || %{})

        identity = %{"workspace_id" => Store.workspace(), "connection_id" => connection.id,
          "provider" => connection.provider, "external_id" => attrs["external_id"],
          "source_id" => source && source.id, "revision_id" => latest && latest.id,
          "body_hash" => latest && latest.body_hash}

        with :ok <- LocalUsePolicies.assert_storage_transition(identity, if(unchanged?, do: :unchanged, else: :upsert), staging) do
        cond do
          source && source.status == "revoked" ->
            {:error, :source_revoked}

          latest && source.status == "active" && source.title == attrs["title"] &&
            latest.body_hash == hash && latest.source_url == attrs["source_url"] &&
            latest.source_updated_at == attrs["source_updated_at"] &&
              latest.metadata == (attrs["metadata"] || %{}) ->
            with {:ok, source} <-
                   source |> Ecto.Changeset.change(status: "active") |> Repo.update() do
              {:ok, {source, false}}
            end

          true ->
            with {:ok, source} <- ensure_source(source, connection, attrs),
                 {:ok, revision} <-
                   Repo.insert(%Revision{
                     workspace_id: Store.workspace(),
                     source_id: source.id,
                     body: attrs["body"],
                     body_hash: hash,
                     revision: if(latest, do: latest.revision + 1, else: 1),
                     captured_at: Store.now(),
                     source_url: attrs["source_url"],
                     source_updated_at: attrs["source_updated_at"],
                     metadata: attrs["metadata"] || %{}
                   }),
                 {:ok, source} <-
                   source
                   |> Ecto.Changeset.change(
                     latest_revision_id: revision.id,
                     title: attrs["title"],
                     status: "active"
                   )
                   |> Repo.update(),
                 {:ok, _} <-
                   Repo.query(
                     "INSERT INTO evidence_search (revision_id,workspace_id,title,body) VALUES (?,?,?,?)",
                     [revision.id, Store.workspace(), attrs["title"], attrs["body"]]
                   ),
                 {:ok, _} <-
                   Audit.append("source.revision_imported", %{
                     "source_id" => source.id,
                     "revision_id" => revision.id
                   }),
                 :ok <-
                   HarnessForge.Evidence.Corpora.invalidate_source(source.id, :revision_changed) do
              {:ok, {source, true}}
            end
        end
        end
      end
    end
  end

  defp ensure_source(nil, connection, attrs) do
    Repo.insert(%Source{
      workspace_id: Store.workspace(),
      connection_id: connection.id,
      provider: connection.provider,
      external_id: attrs["external_id"],
      title: attrs["title"]
    })
  end

  defp ensure_source(source, _, _), do: {:ok, source}

  defp mark_missing_sources(connection, documents) do
    identities = Enum.map(documents, & &1["external_id"])

    missing =
      Repo.all(
        from s in Store.scoped(Source),
          where:
            s.connection_id == ^connection.id and s.status == "active" and
              s.external_id not in ^identities
      )

    Enum.reduce_while(missing, {:ok, 0}, fn source, {:ok, count} ->
      with {:ok, _} <- source |> Ecto.Changeset.change(status: "deleted") |> Repo.update(),
           {:ok, _} <- Audit.append("source.deleted", %{"source_id" => source.id}),
           :ok <- HarnessForge.Evidence.Corpora.invalidate_source(source.id, :source_deleted),
           :ok <- HarnessForge.Evidence.LocalUseLifecycle.record_delete(source.id) do
        {:cont, {:ok, count + 1}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp invalidate_connection_sources(connection_id, after_id \\ "") do
    ids =
      Repo.all(
        from s in Store.scoped(Source),
          where: s.connection_id == ^connection_id and s.id > ^after_id,
          order_by: s.id,
          limit: 100,
          select: s.id
      )

    result =
      Enum.reduce_while(ids, :ok, fn id, :ok ->
        case HarnessForge.Evidence.Corpora.invalidate_source(id, :connection_revoked) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)

    case {result, ids} do
      {:ok, [_ | _]} -> invalidate_connection_sources(connection_id, List.last(ids))
      _ -> result
    end
  end

  defp active_connection(id) do
    with {:ok, connection} <- Store.get(Connection, id),
         true <- connection.status == "active" do
      {:ok, connection}
    else
      false -> {:error, :connection_revoked}
      error -> error
    end
  end

  defp eligible_revision(id, context, purpose) do
    with {:ok, _} <- Ecto.UUID.cast(id),
         {:ok, {policy_sql, policy_params}} <- LocalUsePolicies.not_denied_sql("r", purpose, context),
         {:ok, %{columns: columns, rows: [row]}} <- Repo.query(
           """
           SELECT r.* FROM evidence_revisions r
           JOIN evidence_sources s ON s.id=r.source_id AND s.workspace_id=r.workspace_id
           JOIN source_connections c ON c.id=s.connection_id AND c.workspace_id=s.workspace_id
           WHERE r.id=? AND r.workspace_id=? AND s.latest_revision_id=r.id
             AND s.status='active' AND c.status='active'
             AND #{RevisionUseHolds.not_held_sql("r")} AND #{policy_sql}
           """, [id, Store.workspace()] ++ policy_params),
         revision = Repo.load(Revision, {columns, row}),
         allowed when allowed in [:ok, :legacy_unknown] <-
           LocalUsePolicies.assert_use(%{"source_id" => revision.source_id, "revision_id" => id, "body_hash" => revision.body_hash}, purpose, context),
         :ok <- RevisionUseHolds.assert_use(revision.source_id, id, revision.body_hash, purpose) do
      {:ok, revision}
    else
      _ -> {:error, :source_unavailable}
    end
  end

  defp source_policy_current(id, purpose, context) do
    with {:ok, _} <- Ecto.UUID.cast(id),
         {:ok, {policy_sql, params}} <- LocalUsePolicies.not_denied_sql("r", purpose, context),
         {:ok, %{rows: [[1]]}} <- Repo.query(
           """
           SELECT 1 FROM evidence_sources s JOIN evidence_revisions r
             ON r.id=s.latest_revision_id AND r.source_id=s.id AND r.workspace_id=s.workspace_id
           WHERE s.workspace_id=? AND s.id=? AND #{policy_sql}
           """, [Store.workspace(), id] ++ params) do
      :ok
    else
      _ -> {:error, :source_unavailable}
    end
  end

  defp citation_revision_id(id) do
    with {:ok, _} <- Ecto.UUID.cast(id),
         revision_id when is_binary(revision_id) <-
           Repo.one(from c in Store.scoped(Citation), where: c.id == ^id, select: c.revision_id) do
      {:ok, revision_id}
    else
      _ -> {:error, :invalid_citation}
    end
  end

  @doc false
  def assert_claim_use(id, purpose, context) when purpose in ~w(inspection retrieval analysis compile) do
    with {:ok, _} <- Ecto.UUID.cast(id),
         {:ok, %{rows: [[kind, version, manifest_id]]}} <- Repo.query(
           "SELECT json_extract(basis,'$.kind'),json_extract(basis,'$.version'),json_extract(basis,'$.context.manifest_id') FROM evidence_claims WHERE workspace_id=? AND id=?",
           [Store.workspace(), id]),
         :ok <- claim_manifest_present(kind, version, manifest_id),
         :ok <- claim_revision_page(id, purpose, context, "") do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :source_unavailable}
    end
  end

  def assert_claim_use(_, _, _), do: {:error, :source_unavailable}

  defp claim_manifest_present("company_analysis", 2, id) do
    with {:ok, _} <- Ecto.UUID.cast(id),
         {:ok, %{rows: [[1]]}} <- Repo.query(
           "SELECT 1 FROM origin_dependencies WHERE workspace_id=? AND manifest_id=? AND kind='source_revision' LIMIT 1",
           [Store.workspace(), id]) do
      :ok
    else
      _ -> {:error, :invalid_claim_basis}
    end
  end
  defp claim_manifest_present(_, _, _), do: :ok

  defp claim_revision_page(id, purpose, context, after_id) do
    sql = """
    SELECT revision_id FROM (
      SELECT json_extract(j.value,'$.revision_id') AS revision_id
      FROM evidence_claims c, json_each(c.citations) j WHERE c.workspace_id=? AND c.id=?
      UNION
      SELECT json_extract(j.value,'$.revision_id') AS revision_id
      FROM evidence_claims c, json_each(c.basis,'$.context.sources') j WHERE c.workspace_id=? AND c.id=?
      UNION
      SELECT d.revision_id FROM evidence_claims c JOIN origin_dependencies d
        ON d.workspace_id=c.workspace_id AND d.manifest_id=json_extract(c.basis,'$.context.manifest_id')
      WHERE c.workspace_id=? AND c.id=? AND d.kind='source_revision'
    ) WHERE revision_id>? ORDER BY revision_id LIMIT 100
    """
    args = List.duplicate([Store.workspace(), id], 3) |> List.flatten()
    with {:ok, %{rows: rows}} <- Repo.query(sql, args ++ [after_id]),
         :ok <- Enum.reduce_while(rows, :ok, fn [revision_id], :ok ->
           with {:ok, ref} <- revision_reference(revision_id),
                :ok <- RevisionUseHolds.assert_use(ref.source_id, revision_id, ref.body_hash, purpose),
                allowed when allowed in [:ok, :legacy_unknown] <-
                  LocalUsePolicies.assert_use(%{"source_id" => ref.source_id, "revision_id" => revision_id, "body_hash" => ref.body_hash}, purpose, context) do
             {:cont, :ok}
           else
             _ -> {:halt, {:error, :source_unavailable}}
           end
         end) do
      if length(rows) == 100,
        do: claim_revision_page(id, purpose, context, rows |> List.last() |> hd()),
        else: :ok
    end
  end

  defp creation_purpose(%HarnessForge.Evidence.SourceUseContext{kind: :setup_analysis}), do: "analysis"
  defp creation_purpose(_), do: "inspection"

  defp revision_reference(id) do
    with {:ok, normalized} <- Ecto.UUID.cast(id),
         reference when is_map(reference) <-
           Repo.one(
             from r in Store.scoped(Revision),
               where: r.id == ^normalized,
               select: %{source_id: r.source_id, body_hash: r.body_hash}
           ) do
      {:ok, reference}
    else
      _ -> {:error, :source_unavailable}
    end
  end

  defp source_unheld(nil), do: :ok
  defp source_unheld(source), do: RevisionUseHolds.assert_source_unheld(source.id)

  defp claim_use_current(claim, context, purpose) do
    with {:ok, refs} <- Origin.references(claim) do
      Enum.reduce_while(refs["revision_ids"], :ok, fn id, :ok ->
        with {:ok, ref} <- revision_reference(id),
             :ok <- RevisionUseHolds.assert_use(ref.source_id, id, ref.body_hash, purpose),
             allowed when allowed in [:ok, :legacy_unknown] <-
               LocalUsePolicies.assert_use(%{"source_id" => ref.source_id, "revision_id" => id, "body_hash" => ref.body_hash}, purpose, context) do
          {:cont, :ok}
        else
          error -> {:halt, error}
        end
      end)
    end
  end

  defp validate_document(attrs) do
    with :ok <- Store.required(attrs, ~w(external_id title)),
         :ok <- LocalImport.validate_body(attrs["body"]),
         false <-
           Path.type(attrs["external_id"]) == :absolute or
             ".." in Path.split(attrs["external_id"]) do
      :ok
    else
      true -> {:error, :path_escape}
      error -> error
    end
  end

  defp snippet(body, start_byte, end_byte)
       when is_integer(start_byte) and is_integer(end_byte) and start_byte >= 0 and
              end_byte > start_byte do
    if end_byte <= byte_size(body) do
      prefix = binary_part(body, 0, start_byte)
      selected = binary_part(body, start_byte, end_byte - start_byte)

      if String.valid?(prefix) and String.valid?(selected),
        do: {:ok, selected},
        else: {:error, :invalid_offsets}
    else
      {:error, :invalid_offsets}
    end
  end

  defp snippet(_, _, _), do: {:error, :invalid_offsets}

  defp previous_claim(nil, _context), do: {:ok, nil}

  defp previous_claim(id, context) do
    with :ok <- assert_claim_use(id, creation_purpose(context), context),
         {:ok, claim} <- Store.get(Claim, id),
         false <- Repo.exists?(from c in Store.scoped(Claim), where: c.supersedes_id == ^id) do
      {:ok, claim}
    else
      true -> {:error, :already_superseded}
      error -> error
    end
  end

  defp connection_attrs(%{"provider" => "local"} = attrs) do
    with {:ok, directory} <- LocalImport.approved_directory(attrs["directory"]),
         do: {:ok, %{"directory" => directory}}
  end

  defp connection_attrs(%{"provider" => provider, "config" => config}) when is_map(config) do
    config = HarnessForge.Connectors.Registry.defaults(provider, config)

    with {:ok, adapter} <- connector(provider),
         {:ok, config} <- adapter.validate_config(config),
         do: {:ok, %{"config" => config}}
  end

  defp connection_attrs(_), do: {:error, :provider_unavailable}

  defp connector(provider), do: HarnessForge.Connectors.Registry.adapter(provider)

  defp document_scope(connection, attrs),
    do: HarnessForge.Connectors.Registry.document_scope(connection, attrs)

  defp source_dto(source, context \\ nil) do
    available? =
      source.status == "active" and match?({:ok, _}, active_connection(source.connection_id))

    revision =
      if available? and source.latest_revision_id do
        case eligible_revision(source.latest_revision_id, context, "inspection") do
          {:ok, revision} -> revision
          _ -> nil
        end
      end

    Store.dto(source) |> Map.put("latest_revision", revision && Store.dto(revision))
  end

  defp claim_dto(claim, context, purpose \\ "inspection") do
    decision = Repo.one(from d in Store.scoped(Decision), where: d.claim_id == ^claim.id)
    superseded? = Repo.exists?(from c in Store.scoped(Claim), where: c.supersedes_id == ^claim.id)

    status =
      case decision do
        %{decision: "approve", revision_hash: hash} ->
          if(
            hash == claim.revision_hash and match?({:ok, _}, validate_claim(claim, context, "compile")) and
              approval_ready?(Store.dto(claim)),
            do: "approved",
            else: "stale"
          )

        %{decision: "reject"} ->
          "rejected"

        nil ->
          "proposed"
      end

    dto = Store.dto(claim)
    dto = if is_nil(claim.basis), do: Map.delete(dto, "basis"), else: dto

    dto =
      if claim_use_current(Store.dto(claim), context, purpose) == :ok do
        dto
      else
        dto
        |> Map.put("text", "Source content unavailable")
        |> Map.put("citations", [])
        |> Map.delete("basis")
      end

    dto |> Map.put("status", status) |> Map.put("superseded", superseded?)
  end
end
