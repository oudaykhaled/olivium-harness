defmodule HarnessForge.Company.CorpusReview do
  @moduledoc """
  Authorized, read-only inspection of captured evidence. Pages contain metadata,
  not source bodies. A page is a live keyset view, never a corpus snapshot or a
  statement about semantic coverage. Browsing does not change analysis membership.
  """
  import Ecto.Query
  alias HarnessForge.{Contracts, Evidence, Goals, Repo}
  alias HarnessForge.Company.{AssessmentAttempts, Profile, Project}
  alias HarnessForge.Connectors.Registry

  alias HarnessForge.Evidence.{
    Claim,
    Connection,
    Decision,
    Goal,
    Origin,
    RevisionUseHolds,
    LocalUsePolicies,
    SourceUseContext,
    Source,
    Store
  }

  alias HarnessForge.Privacy.Purge

  @scope_salt "company-corpus-review-scope-v1"
  @cursor_salt "company-corpus-review-cursor-v1"
  @max_age 600
  @page_size 25
  @window_bytes 4096
  @type result :: {:ok, map()} | {:error, atom()}

  # These predicates conservatively admit the canonical URLs emitted by the
  # existing connectors, before MATCH or LIMIT. Passage reads additionally call
  # Registry.document_scope/2 against the exact current record. No provider call
  # or credential resolution occurs here.
  @document_scope """
  CASE c.provider
    WHEN 'local' THEN 1
    WHEN 'github' THEN
      json_extract(r.metadata, '$.repository') = json_extract(c.config, '$.repository')
      AND substr(replace(r.source_url, 'https://github.com:443/', 'https://github.com/'), 1,
        length('https://github.com/')) = 'https://github.com/'
      AND substr(s.external_id, 1, length('github:' || c.id || ':')) = 'github:' || c.id || ':'
      AND CASE WHEN json_extract(r.metadata, '$.kind') = 'review' THEN
        json_type(r.metadata, '$.pull_number') = 'integer'
        AND substr(s.external_id, 1, length('github:' || c.id || ':review:')) = 'github:' || c.id || ':review:'
        AND substr(s.external_id, length('github:' || c.id || ':review:') + 1, 1) GLOB '[1-9]'
        AND substr(s.external_id, length('github:' || c.id || ':review:') + 1) NOT GLOB '*[^0-9]*'
        AND replace(r.source_url, 'https://github.com:443/', 'https://github.com/') =
          'https://github.com/' || json_extract(c.config, '$.repository') || '/pull/' ||
          json_extract(r.metadata, '$.pull_number') || '#pullrequestreview-' ||
          substr(s.external_id, length('github:' || c.id || ':review:') + 1)
      ELSE
        instr(r.source_url, '?') = 0 AND instr(r.source_url, '#') = 0
        AND (lower(replace(r.source_url, 'https://github.com:443/', 'https://github.com/')) =
          'https://github.com/' || lower(json_extract(c.config, '$.repository'))
          OR substr(lower(replace(r.source_url, 'https://github.com:443/', 'https://github.com/')), 1,
            length('https://github.com/' || json_extract(c.config, '$.repository') || '/')) =
            'https://github.com/' || lower(json_extract(c.config, '$.repository')) || '/')
      END
    WHEN 'jira' THEN
      json_extract(r.metadata, '$.project') = json_extract(c.config, '$.project')
      AND substr(s.external_id, 1, length('jira:' || c.id || ':')) = 'jira:' || c.id || ':'
      AND substr(r.source_url, 1, length(json_extract(c.config, '$.endpoint') || '/browse/' ||
        json_extract(c.config, '$.project') || '-')) = json_extract(c.config, '$.endpoint') ||
        '/browse/' || json_extract(c.config, '$.project') || '-'
      AND substr(r.source_url, length(json_extract(c.config, '$.endpoint') || '/browse/' ||
        json_extract(c.config, '$.project') || '-') + 1, 1) GLOB '[1-9]'
      AND substr(r.source_url, length(json_extract(c.config, '$.endpoint') || '/browse/' ||
        json_extract(c.config, '$.project') || '-') + 1) NOT GLOB '*[^0-9]*'
    WHEN 'github_projects' THEN
      r.source_url = json_extract(c.config, '$.project_url')
      AND json_extract(r.metadata, '$.project_url') = r.source_url
      AND json_extract(r.metadata, '$.owner_kind') = CASE
        WHEN substr(r.source_url, 1, length('https://github.com/orgs/')) = 'https://github.com/orgs/' THEN 'organization' ELSE 'user' END
      AND r.source_url = 'https://github.com/' || CASE
        WHEN json_extract(r.metadata, '$.owner_kind') = 'organization' THEN 'orgs/' ELSE 'users/' END ||
        json_extract(r.metadata, '$.owner') || '/projects/' || json_extract(r.metadata, '$.number')
      AND json_type(r.metadata, '$.project_id') = 'text'
      AND json_type(r.metadata, '$.number') = 'integer'
      AND length(json_extract(r.metadata, '$.project_id')) > 0
      AND json_extract(r.metadata, '$.kind') IN ('project', 'field', 'view', 'item')
      AND substr(s.external_id, 1, length('github_projects:' || c.id || ':')) = 'github_projects:' || c.id || ':'
      AND length(s.external_id) > length('github_projects:' || c.id || ':')
    WHEN 'slack' THEN
      json_type(r.metadata, '$.team_domain') = 'text'
      AND json_type(r.metadata, '$.message_ts') = 'text'
      AND json_extract(r.metadata, '$.team_id') = json_extract(c.config, '$.team_id')
      AND json_extract(r.metadata, '$.channel_id') = json_extract(c.config, '$.channel_id')
      AND json_extract(r.metadata, '$.kind') IN ('message', 'reply')
      AND length(json_extract(r.metadata, '$.team_domain')) BETWEEN 1 AND 63
      AND substr(json_extract(r.metadata, '$.team_domain'), 1, 1) GLOB '[a-z0-9]'
      AND json_extract(r.metadata, '$.team_domain') NOT GLOB '*[^a-z0-9-]*'
      AND length(json_extract(r.metadata, '$.message_ts')) BETWEEN 17 AND 23
      AND substr(json_extract(r.metadata, '$.message_ts'), -7, 1) = '.'
      AND substr(json_extract(r.metadata, '$.message_ts'), 1,
        length(json_extract(r.metadata, '$.message_ts')) - 7) NOT GLOB '*[^0-9]*'
      AND substr(json_extract(r.metadata, '$.message_ts'), -6) NOT GLOB '*[^0-9]*'
      AND s.external_id = 'slack:' || c.id || ':' || json_extract(c.config, '$.channel_id') || ':' ||
        json_extract(r.metadata, '$.message_ts')
      AND r.source_url = 'https://' || json_extract(r.metadata, '$.team_domain') || '.slack.com/archives/' ||
        json_extract(c.config, '$.channel_id') || '/p' || replace(json_extract(r.metadata, '$.message_ts'), '.', '')
    WHEN 'confluence' THEN
      json_extract(r.metadata, '$.kind') = 'page'
      AND json_extract(r.metadata, '$.space_id') = json_extract(c.config, '$.space_id')
      AND json_type(r.metadata, '$.page_id') = 'text'
      AND length(json_extract(r.metadata, '$.page_id')) BETWEEN 1 AND 20
      AND substr(json_extract(r.metadata, '$.page_id'), 1, 1) GLOB '[1-9]'
      AND json_extract(r.metadata, '$.page_id') NOT GLOB '*[^0-9]*'
      AND r.source_url = json_extract(c.config, '$.endpoint') || '/wiki/pages/viewpage.action?pageId=' ||
        json_extract(r.metadata, '$.page_id')
      AND s.external_id = 'confluence:' || c.id || ':' || json_extract(r.metadata, '$.page_id')
    ELSE 0
  END
  """

  @projection """
  s.id, s.workspace_id, s.connection_id, s.provider, s.external_id, s.title, s.status,
  r.id AS revision_id, r.revision, r.body_hash, length(CAST(r.body AS BLOB)) AS body_bytes,
  r.captured_at, r.source_updated_at,
  CASE WHEN length(CAST(r.source_url AS BLOB)) <= 2048 THEN r.source_url ELSE NULL END AS source_url,
  json_object(
    'document_status', CASE WHEN json_type(r.metadata, '$.document_status') = 'text'
      AND length(CAST(json_extract(r.metadata, '$.document_status') AS BLOB)) <= 200
      THEN json_extract(r.metadata, '$.document_status') ELSE NULL END,
    'effective_at', CASE WHEN json_type(r.metadata, '$.effective_at') = 'text'
      AND length(json_extract(r.metadata, '$.effective_at')) <= 64
      THEN json_extract(r.metadata, '$.effective_at') ELSE NULL END,
    'event_at', CASE WHEN json_type(r.metadata, '$.event_at') = 'text'
      AND length(json_extract(r.metadata, '$.event_at')) <= 64
      THEN json_extract(r.metadata, '$.event_at') ELSE NULL END
  ) AS history
  """

  @joins """
  FROM evidence_sources s
  LEFT JOIN source_connections c ON c.id = s.connection_id AND c.workspace_id = s.workspace_id
  LEFT JOIN evidence_revisions r ON r.id = s.latest_revision_id
    AND r.source_id = s.id AND r.workspace_id = s.workspace_id
  """

  @eligible "s.status = 'active' AND c.status = 'active' AND r.id IS NOT NULL AND (#{@document_scope})"

  defp eligible_sql, do: @eligible <> " AND (" <> RevisionUseHolds.not_held_sql("r") <> ")"

  @spec choices(map(), keyword()) :: result()
  @doc false
  def document_scope_sql, do: @document_scope

  def choices(attrs, caller) do
    read(caller, fn ->
      with :ok <- keys(attrs, ~w(kind), ~w(project_id goal_id cursor)),
           true <- attrs["kind"] in ~w(connection project goal recommendation),
           :ok <- optional_id(attrs["project_id"]),
           :ok <- optional_id(attrs["goal_id"]),
           {:ok, after_id} <- cursor(attrs["cursor"], choice_binding(attrs), caller),
           {:ok, rows} <- choice_rows(attrs, after_id) do
        {:ok, paged(rows, choice_binding(attrs), caller)}
      else
        false -> {:error, :invalid_input}
        error -> error
      end
    end)
  end

  @spec open_scope(map(), keyword()) :: result()
  def open_scope(attrs, caller) do
    read(caller, fn ->
      with :ok <- keys(attrs, ~w(connection_id project_id goal_id goal_content_hash)),
           true <- Enum.all?(~w(connection_id project_id goal_id), &uuid?(attrs[&1])),
           true <- digest?(attrs["goal_content_hash"]),
           {:ok, context} <- context(attrs),
           {:ok, connection} <- active_connection(attrs["connection_id"]) do
        pins = Map.put(context.pins, "connection", connection_pin(connection))

        {:ok,
         %{
           "token" => sign(@scope_salt, %{"kind" => "company", "pins" => pins}, caller),
           "scope" => scope_summary(context, connection)
         }}
      else
        false -> {:error, :invalid_input}
        error -> error
      end
    end)
  end

  @spec page(String.t(), map(), keyword()) :: result()
  def page(token, attrs, caller) do
    read(caller, fn ->
      with :ok <- keys(attrs, ~w(query), ~w(cursor)),
           {:ok, query} <- query(attrs["query"]),
           {:ok, scope} <- company_scope(token, caller),
           binding = %{"kind" => "page", "scope" => scope.pins, "query" => query.text},
           {:ok, after_id} <- cursor(attrs["cursor"], binding, caller),
           {:ok, result} <- source_rows(scope.connection.id, query, after_id, binding, caller) do
        {:ok, Map.put(result, "scope", scope_summary(scope.context, scope.connection))}
      end
    end)
  end

  @spec source_page(map(), keyword()) :: result()
  def source_page(attrs, caller), do: source_page(attrs, caller, nil)

  def source_page(attrs, caller, source_context) do
    read(caller, source_context, fn ->
      with :ok <- keys(attrs, [], ~w(connection_id query cursor)),
           :ok <- optional_id(attrs["connection_id"]),
           {:ok, connection} <- optional_connection(attrs["connection_id"]),
           {:ok, query} <- query(Map.get(attrs, "query", "")),
           binding = %{
             "kind" => "sources",
             "connection" => if(connection, do: connection_pin(connection)),
             "query" => query.text
           },
           {:ok, after_id} <- cursor(attrs["cursor"], binding, caller),
           {:ok, result} <-
             source_rows(connection && connection.id, query, after_id, binding, caller, source_context) do
        {:ok, Map.update!(result, "rows", &preview_handles(&1, caller))}
      end
    end)
  end

  @spec passage(String.t(), map(), keyword()) :: result()
  def passage(token, attrs, caller), do: passage(token, attrs, caller, nil)

  def passage(token, attrs, caller, source_context) do
    read(caller, source_context, fn ->
      with :ok <- keys(attrs, ~w(source_id revision_id body_hash start_byte)),
           true <- uuid?(attrs["source_id"]) and uuid?(attrs["revision_id"]),
           true <- digest?(attrs["body_hash"]),
           true <- is_integer(attrs["start_byte"]) and attrs["start_byte"] >= 0,
           {:ok, payload} <- verify(@scope_salt, token, caller, :invalid_scope),
           {:ok, source} <- Store.get(Source, attrs["source_id"]),
           {:ok, connection} <- active_connection(source.connection_id),
           :ok <- passage_scope(payload, attrs, connection, caller),
           :ok <-
             RevisionUseHolds.assert_use(
               source.id,
               attrs["revision_id"],
               attrs["body_hash"],
               "inspection"
             ),
           {:ok, summary} <- current_summary(attrs, source_context),
           :ok <- document_scope(source, connection, attrs["revision_id"]),
           {:ok, window} <- slice(attrs, summary["latest_revision"]["body_bytes"], source_context) do
        {:ok,
         Map.merge(window, %{
           "source" => summary,
           "revision_id" => attrs["revision_id"],
           "body_hash" => attrs["body_hash"]
         })}
      else
        false -> {:error, :invalid_input}
        error -> error
      end
    end)
  end

  @spec recommendation(String.t(), map(), keyword()) :: result()
  def recommendation(token, attrs, caller) do
    read(caller, fn ->
      with :ok <- keys(attrs, ~w(claim_id revision_hash)),
           true <- uuid?(attrs["claim_id"]) and digest?(attrs["revision_hash"]),
           {:ok, scope} <- company_scope(token, caller),
           :ok <- Evidence.assert_claim_use(attrs["claim_id"], "inspection", nil),
           {:ok, claim} <- Store.get(Claim, attrs["claim_id"]),
           :ok <- check(claim.revision_hash == attrs["revision_hash"], :stale_revision),
           :ok <- matching_claim(claim, scope.context),
           false <-
             Repo.exists?(from c in Store.scoped(Claim), where: c.supersedes_id == ^claim.id),
           {:ok, metadata} <- claim_metadata(claim, nil),
           summaries = metadata["sources"] do
        decision = Repo.one(from d in Store.scoped(Decision), where: d.claim_id == ^claim.id)

        {:ok,
         %{
           "claim_id" => claim.id,
           "revision_hash" => claim.revision_hash,
           "status" => claim_status(claim, decision),
           "superseded" => false,
           "eligible" => true,
           "project_id" => claim.basis["project_id"],
           "goal_id" => claim.basis["goal_id"],
           "goal_content_hash" => claim.basis["goal_content_hash"],
           "report" => claim.basis["report"],
           "guidance" => claim.basis["guidance"],
           "review_resolution" => claim.basis["review_resolution"],
           "analyzed_sources" => summaries,
           "origin_version" => claim.basis["version"],
           "manifest" => metadata["manifest"],
           "outside_inspection_connection" =>
             Enum.any?(summaries, &(&1["connection_id"] != scope.connection.id))
         }}
      else
        true -> {:error, :already_superseded}
        false -> {:error, :source_unavailable}
        error -> error
      end
    end)
  end

  @doc "Current bounded selected-input metadata for an exact recommendation; never source bodies."
  @spec recommendation_sources(map(), keyword()) :: result()
  def recommendation_sources(attrs, caller), do: recommendation_sources(attrs, caller, nil)

  def recommendation_sources(attrs, caller, source_context) do
    read(caller, source_context, fn ->
      with :ok <- keys(attrs, ~w(claim_id revision_hash)),
           true <- uuid?(attrs["claim_id"]) and digest?(attrs["revision_hash"]),
           :ok <- Evidence.assert_claim_use(attrs["claim_id"], "inspection", source_context),
           {:ok, claim} <- Store.get(Claim, attrs["claim_id"]),
           :ok <- check(claim.revision_hash == attrs["revision_hash"], :stale_revision),
           false <-
             Repo.exists?(from c in Store.scoped(Claim), where: c.supersedes_id == ^claim.id),
           {:ok, metadata} <- claim_metadata(claim, source_context) do
        {:ok, metadata}
      else
        true -> {:error, :already_superseded}
        false -> {:error, :invalid_input}
        error -> error
      end
    end)
  end

  defp claim_metadata(claim, source_context) do
    # Keep full origin/report/citation validation as authority. Only direct,
    # selected input pins are projected; graph ancestry remains in its manifest.
    with {:ok, _} <- Evidence.validate_claim(claim, source_context, "inspection"),
         {:ok, refs} <- recommendation_pins(claim.basis, source_context),
         {:ok, rows} <- summaries(Enum.map(refs, & &1["source_id"]), source_context),
         true <- pins_current?(refs, rows) do
      {:ok,
       %{
         "sources" => rows,
         "source_refs" => refs,
         "manifest" =>
           if(claim.basis["version"] == 2,
             do: Map.take(claim.basis["context"], ~w(manifest_id manifest_digest)),
             else: nil
           )
       }}
    else
      false -> {:error, :source_unavailable}
      error -> error
    end
  end

  defp recommendation_pins(%{"version" => 2, "context" => context}, source_context) do
    with :ok <- HarnessForge.Evidence.OriginV2.validate_context(context, source_context, "inspection") do
      refs =
        query_rows(
          "SELECT source_id,revision_id,content_hash AS body_hash FROM origin_dependencies WHERE workspace_id=? AND manifest_id=? AND kind='source_revision' ORDER BY ordinal LIMIT 25",
          [Store.workspace(), context["manifest_id"]]
        )

      # seal_retrieval admits at most24 selected dependencies. Never flatten the
      # transitive corpus, accept browser pins or silently truncate a manifest.
      if length(refs) in 1..24, do: {:ok, refs}, else: {:error, :closure_incomplete}
    end
  end

  defp recommendation_pins(%{"version" => 1, "context" => %{"sources" => refs}}, _source_context)
       when is_list(refs), do: {:ok, refs}

  defp recommendation_pins(_, _), do: {:error, :invalid_claim_basis}

  @spec summary_refs(map(), keyword()) :: result()
  def summary_refs(refs, caller), do: summary_refs(refs, caller, nil)

  def summary_refs(refs, caller, source_context) do
    read(caller, source_context, fn ->
      with :ok <-
             keys(
               refs,
               [],
               ~w(profile_ids project_ids analysis_refs recommendation_refs consent_ids)
             ),
           :ok <- id_group(refs["profile_ids"]),
           :ok <- id_group(refs["project_ids"]),
           :ok <- id_group(refs["consent_ids"]),
           :ok <- ref_group(refs["analysis_refs"]),
           :ok <- ref_group(refs["recommendation_refs"]),
           pins = List.wrap(refs["analysis_refs"]) ++ List.wrap(refs["recommendation_refs"]),
           ids =
             Enum.uniq(
               List.wrap(refs["profile_ids"]) ++
                 List.wrap(refs["project_ids"]) ++
                 List.wrap(refs["consent_ids"]) ++ Enum.map(pins, & &1["source_id"])
             ),
           {:ok, rows} <- summaries(ids, source_context) do
        available = Enum.map(rows, & &1["id"])
        stale = pins |> Enum.reject(&pin_current?(&1, rows)) |> Enum.map(& &1["source_id"])

        {:ok, %{"sources" => rows, "unavailable_ids" => Enum.uniq((ids -- available) ++ stale)}}
      end
    end)
  end

  defp read(caller, fun), do: read(caller, nil, fun)

  defp read(caller, source_context, fun) do
    with :ok <- context_caller(source_context, caller),
         :ok <- AssessmentAttempts.options(caller),
         :ok <- AssessmentAttempts.authorize(caller) do
      Purge.synchronize(fn ->
        Store.transaction(fn ->
          with :ok <- Purge.ready(),
               :ok <- AssessmentAttempts.authorize(caller),
               {:ok, result} <- fun.(),
               :ok <- checked_result(result, source_context),
               :ok <- context_caller(source_context, caller),
               :ok <- Purge.ready(),
               :ok <- AssessmentAttempts.authorize(caller) do
            {:ok, result}
          end
        end)
      end)
    end
  rescue
    _ -> {:error, :corpus_unavailable}
  catch
    _, _ -> {:error, :corpus_unavailable}
  end

  defp context_caller(nil, _caller), do: :ok
  defp context_caller(source_context, caller), do: SourceUseContext.match_caller(source_context, caller)

  defp checked_result(result, source_context) do
    rows = List.wrap(result["rows"]) ++ List.wrap(result["sources"]) ++ List.wrap(result["source"])
    Enum.reduce_while(rows, :ok, fn row, :ok ->
      case row["latest_revision"] do
        %{"id" => id, "body_hash" => hash} ->
          case LocalUsePolicies.assert_use(%{"source_id" => row["id"], "revision_id" => id, "body_hash" => hash}, "inspection", source_context) do
            allowed when allowed in [:ok, :legacy_unknown] -> {:cont, :ok}
            error -> {:halt, error}
          end
        _ -> {:cont, :ok}
      end
    end)
  end

  defp context(attrs) do
    with profile when not is_nil(profile) <- Repo.one(Store.scoped(Profile)),
         {:ok, project} <- Store.get(Project, attrs["project_id"]),
         {:ok, goal} <- Store.get(Goal, attrs["goal_id"]),
         true <- profile.content_hash == Contracts.digest(profile.payload),
         true <- project.content_hash == Contracts.digest(project.payload),
         true <- goal.id in Enum.uniq(profile.payload["goal_ids"] ++ project.payload["goal_ids"]),
         true <- Goals.content_hash(goal) == attrs["goal_content_hash"] do
      {:ok,
       %{
         profile: profile,
         project: project,
         goal: goal,
         pins: %{
           "profile_id" => profile.id,
           "profile_content_hash" => profile.content_hash,
           "project_id" => project.id,
           "project_content_hash" => project.content_hash,
           "goal_id" => goal.id,
           "goal_content_hash" => Goals.content_hash(goal)
         }
       }}
    else
      _ -> {:error, :stale_scope}
    end
  end

  defp company_scope(token, caller) do
    with {:ok, payload} <- verify(@scope_salt, token, caller, :invalid_scope) do
      checked_company_scope(payload)
    end
  end

  defp checked_company_scope(%{"kind" => "company", "pins" => pins}) do
    with {:ok, context} <- context(pins),
         {:ok, connection} <- active_connection(pins["connection"]["id"]),
         true <- Map.put(context.pins, "connection", connection_pin(connection)) == pins do
      {:ok, %{pins: pins, context: context, connection: connection}}
    else
      {:error, _} = error -> error
      _ -> {:error, :stale_scope}
    end
  end

  defp checked_company_scope(_), do: {:error, :invalid_scope}

  defp passage_scope(%{"kind" => "company"} = payload, _, connection, _) do
    with {:ok, scope} <- checked_company_scope(payload),
         true <- scope.connection.id == connection.id do
      :ok
    else
      _ -> {:error, :source_out_of_scope}
    end
  end

  defp passage_scope(
         %{"kind" => "source_preview", "source" => pin, "connection" => saved},
         attrs,
         connection,
         _
       ) do
    check(
      pin == Map.take(attrs, ~w(source_id revision_id body_hash)) and
        saved == connection_pin(connection),
      :stale_scope
    )
  end

  defp passage_scope(_, _, _, _), do: {:error, :invalid_scope}

  defp active_connection(id) do
    with {:ok, connection} <- Store.get(Connection, id),
         true <- connection.status == "active" do
      {:ok, connection}
    else
      _ -> {:error, :connection_unavailable}
    end
  end

  defp optional_connection(id) when id in [nil, ""], do: {:ok, nil}
  defp optional_connection(id), do: active_connection(id)

  defp connection_pin(connection),
    do: %{
      "id" => connection.id,
      "provider" => connection.provider,
      "status" => connection.status,
      "config_digest" =>
        Contracts.digest(%{"config" => connection.config, "directory" => connection.directory})
    }

  defp scope_summary(context, connection) do
    profile = context.profile.payload
    project = context.project.payload

    %{
      "connection" =>
        connection
        |> Store.dto()
        |> Map.take(~w(id name provider sync_state sync_complete last_synced_at)),
      "project" => %{
        "id" => context.project.id,
        "name" => project["name"],
        "content_hash" => context.project.content_hash
      },
      "goal" =>
        context.goal
        |> Store.dto()
        |> Map.take(~w(id title owner acceptance))
        |> Map.put("content_hash", Goals.content_hash(context.goal)),
      "assignment_counts" => %{
        "profile_sources" => length(profile["source_ids"]),
        "project_sources" => length(project["source_ids"]),
        "distinct_sources" => length(Enum.uniq(profile["source_ids"] ++ project["source_ids"])),
        "profile_goals" => length(profile["goal_ids"]),
        "project_goals" => length(project["goal_ids"])
      }
    }
  end

  defp choice_rows(%{"kind" => "connection"}, after_id) do
    rows =
      Repo.all(
        from c in Store.scoped(Connection),
          where: c.status == "active" and fragment("? > ?", c.id, ^after_id),
          order_by: c.id,
          limit: 26
      )

    {:ok, Enum.map(rows, &%{"id" => &1.id, "title" => &1.name, "provider" => &1.provider})}
  end

  defp choice_rows(%{"kind" => "project"}, after_id) do
    rows =
      Repo.all(
        from p in Store.scoped(Project),
          where: fragment("? > ?", p.id, ^after_id),
          order_by: p.id,
          limit: 26
      )

    {:ok,
     Enum.map(
       rows,
       &%{"id" => &1.id, "title" => &1.payload["name"], "content_hash" => &1.content_hash}
     )}
  end

  defp choice_rows(%{"kind" => kind} = attrs, after_id) when kind in ~w(goal recommendation) do
    with true <- uuid?(attrs["project_id"]),
         profile when not is_nil(profile) <- Repo.one(Store.scoped(Profile)),
         {:ok, project} <- Store.get(Project, attrs["project_id"]) do
      allowed = Enum.uniq(profile.payload["goal_ids"] ++ project.payload["goal_ids"])
      assigned_choices(kind, attrs, after_id, allowed)
    else
      _ -> {:error, :invalid_scope}
    end
  end

  defp assigned_choices("goal", _, after_id, allowed) do
    rows =
      Repo.all(
        from g in Store.scoped(Goal),
          where: g.id in ^allowed and fragment("? > ?", g.id, ^after_id),
          order_by: g.id,
          limit: 26
      )

    {:ok,
     Enum.map(
       rows,
       &%{"id" => &1.id, "title" => &1.title, "content_hash" => Goals.content_hash(&1)}
     )}
  end

  defp assigned_choices("recommendation", attrs, after_id, allowed) do
    if uuid?(attrs["goal_id"]) and attrs["goal_id"] in allowed do
      sql = """
      SELECT c.id, c.revision_hash FROM evidence_claims c
      WHERE c.workspace_id = ? AND c.id > ?
        AND json_extract(c.basis, '$.kind') = 'company_analysis'
        AND json_extract(c.basis, '$.project_id') = ? AND json_extract(c.basis, '$.goal_id') = ?
        AND NOT EXISTS (SELECT 1 FROM evidence_claims newer WHERE newer.workspace_id = c.workspace_id AND newer.supersedes_id = c.id)
      ORDER BY c.id LIMIT 26
      """

      {:ok,
       query_rows(sql, [Store.workspace(), after_id, attrs["project_id"], attrs["goal_id"]])
       |> Enum.map(fn row ->
         %{
           "id" => row["id"],
           "title" => "Recommendation " <> String.slice(row["id"], 0, 8),
           "revision_hash" => row["revision_hash"],
           "project_id" => attrs["project_id"],
           "goal_id" => attrs["goal_id"]
         }
       end)}
    else
      {:error, :invalid_scope}
    end
  end

  defp source_rows(connection_id, query, after_id, binding, caller, source_context \\ nil) do
    with {:ok, {policy_sql, policy_params}} <- LocalUsePolicies.not_denied_sql("r", "inspection", source_context) do
    {filter, params} = connection_filter(connection_id)

    base = """
    WITH scoped AS MATERIALIZED (
      SELECT s.id, s.workspace_id, r.id AS revision_id
      #{@joins} WHERE s.workspace_id = ? #{filter} AND #{eligible_sql()} AND (#{policy_sql})
    )
    """

    scope_params = [Store.workspace() | params] ++ policy_params

    [counts] =
      query_rows(
        "SELECT count(*) AS captured, coalesce(sum(CASE WHEN #{eligible_sql()} AND (#{policy_sql}) THEN 1 ELSE 0 END), 0) AS current #{@joins} WHERE s.workspace_id = ? #{filter}",
        policy_params ++ [Store.workspace() | params]
      )

    {match_sql, match_params} = match_filter(query)

    [matches] =
      query_rows(
        base <> "SELECT count(*) AS matches FROM scoped WHERE 1 = 1 #{match_sql}",
        scope_params ++ match_params
      )

    {offset_sql, offset_params} = match_offset(query)

    # Materialize only eligible identities. The metadata/length/offset projection
    # is evaluated after the keyset LIMIT, so a large corpus never materializes
    # all metadata or bodies in the application or in a projection CTE.
    rows =
      query_rows(
        base <>
          ", wanted AS MATERIALIZED (SELECT id FROM scoped WHERE 1 = 1 #{match_sql} AND id > ? ORDER BY id LIMIT 26) SELECT #{@projection}, 1 AS eligible, #{offset_sql} AS match_start_byte #{@joins} JOIN wanted ON wanted.id = s.id ORDER BY s.id",
        scope_params ++ match_params ++ [after_id] ++ offset_params
      )
      |> Enum.map(&source_summary/1)

    {:ok,
     paged(rows, binding, caller)
     |> Map.put("counts", %{
       "captured" => counts["captured"],
       "current" => counts["current"],
       "unavailable" => counts["captured"] - counts["current"],
       "matches" => if(query.tokens == [], do: nil, else: matches["matches"]),
       "discovery_total" => nil,
       "semantic_coverage" => "unknown"
     })}
    end
  end

  defp connection_filter(nil), do: {"", []}
  defp connection_filter(id), do: {" AND s.connection_id = ?", [id]}
  defp match_filter(%{tokens: []}), do: {"", []}

  defp match_filter(query),
    do:
      {" AND revision_id IN (SELECT revision_id FROM evidence_search WHERE workspace_id = ? AND evidence_search MATCH ?)",
       [Store.workspace(), query.expression]}

  defp match_offset(%{tokens: []}), do: {"NULL", []}

  defp match_offset(%{tokens: [token | _]}) do
    # SQLite computes the prefix byte length; no prefix or body is returned.
    # Unicode folding/token normalization can prevent a literal location; nil
    # deliberately means that a first-window preview is all we can offer.
    {"CASE WHEN instr(lower(r.body), lower(?)) > 0 THEN length(CAST(substr(r.body, 1, instr(lower(r.body), lower(?)) - 1) AS BLOB)) ELSE NULL END",
     [token, token]}
  end

  defp source_summary(row) do
    revision =
      if row["revision_id"] do
        %{
          "id" => row["revision_id"],
          "workspace_id" => row["workspace_id"],
          "source_id" => row["id"],
          "revision" => row["revision"],
          "body_hash" => row["body_hash"],
          "body_bytes" => row["body_bytes"],
          "captured_at" => timestamp(row["captured_at"]),
          "source_updated_at" => row["source_updated_at"],
          "source_url" => safe_url(row["source_url"]),
          "metadata" => historical_metadata(row["history"])
        }
      end

    %{
      "id" => row["id"],
      "workspace_id" => row["workspace_id"],
      "connection_id" => row["connection_id"],
      "provider" => row["provider"],
      "external_id" => row["external_id"],
      "title" => row["title"],
      "status" => row["status"],
      "eligible" => row["eligible"] == 1,
      "latest_revision" => revision,
      "match_start_byte" => row["match_start_byte"]
    }
  end

  defp summaries(ids, source_context \\ nil)
  defp summaries([], _source_context), do: {:ok, []}

  defp summaries(ids, source_context) do
    with {:ok, {policy_sql, policy_params}} <- LocalUsePolicies.not_denied_sql("r", "inspection", source_context) do
    placeholders = Enum.map_join(ids, ",", fn _ -> "?" end)

    sql =
      "SELECT #{@projection}, 1 AS eligible #{@joins} WHERE s.workspace_id = ? AND s.id IN (#{placeholders}) AND #{eligible_sql()} AND (#{policy_sql}) ORDER BY s.id"

    {:ok, query_rows(sql, [Store.workspace() | ids] ++ policy_params) |> Enum.map(&source_summary/1)}
  end

    end

  defp current_summary(attrs, source_context) do
    with {:ok, [summary]} <- summaries([attrs["source_id"]], source_context),
         true <- pin_current?(attrs, [summary]) do
      {:ok, summary}
    else
      _ -> {:error, :source_unavailable}
    end
  end

  defp document_scope(source, connection, revision_id) do
    rows =
      query_rows(
        "SELECT source_url, metadata FROM evidence_revisions WHERE workspace_id = ? AND source_id = ? AND id = ?",
        [Store.workspace(), source.id, revision_id]
      )

    case rows do
      [row] ->
        Registry.document_scope(connection, %{
          "external_id" => source.external_id,
          "source_url" => row["source_url"],
          "metadata" => decode(row["metadata"])
        })

      _ ->
        {:error, :source_unavailable}
    end
  end

  defp slice(attrs, total, source_context) do
    with {:ok, {policy_sql, policy_params}} <- LocalUsePolicies.not_denied_sql("r", "inspection", source_context) do
    start = attrs["start_byte"]

    if start <= total do
      [row] =
        query_rows(
          "SELECT substr(CAST(r.body AS BLOB), ?, ?) AS window FROM evidence_revisions r JOIN evidence_sources s ON s.id=r.source_id AND s.workspace_id=r.workspace_id WHERE r.workspace_id = ? AND r.id = ? AND r.body_hash = ? AND (#{policy_sql})",
          [
            start + 1,
            @window_bytes + 3,
            Store.workspace(),
            attrs["revision_id"],
            attrs["body_hash"]
          ] ++ policy_params
        )

      bytes = row["window"]

      with true <- start == total or valid_start?(bytes),
           {:ok, text} <- window(bytes) do
        finish = start + byte_size(text)

        {:ok,
         %{
           "start_byte" => start,
           "end_byte" => finish,
           "text" => text,
           "body_bytes" => total,
           "truncated_before" => start > 0,
           "truncated_after" => finish < total,
           "next_start_byte" => if(finish < total, do: finish)
         }}
      else
        _ -> {:error, :invalid_offsets}
      end
    else
      {:error, :invalid_offsets}
    end
  end

    end

  defp valid_start?(<<first, _::binary>>), do: first < 128 or first >= 192
  defp valid_start?(_), do: false

  defp window(bytes) do
    candidate = binary_part(bytes, 0, min(byte_size(bytes), @window_bytes))
    trim_window(candidate, 0)
  end

  defp trim_window(bytes, dropped) when dropped <= 3 do
    cond do
      String.valid?(bytes) ->
        {:ok, bytes}

      byte_size(bytes) > 0 ->
        trim_window(binary_part(bytes, 0, byte_size(bytes) - 1), dropped + 1)

      true ->
        {:error, :invalid_offsets}
    end
  end

  defp trim_window(_, _), do: {:error, :invalid_offsets}

  defp preview_handles(summaries, caller) do
    ids = summaries |> Enum.map(& &1["connection_id"]) |> Enum.uniq()

    connections =
      Repo.all(from c in Store.scoped(Connection), where: c.id in ^ids) |> Map.new(&{&1.id, &1})

    Enum.map(summaries, fn summary ->
      connection = Map.fetch!(connections, summary["connection_id"])
      revision = summary["latest_revision"]

      pin = %{
        "source_id" => summary["id"],
        "revision_id" => revision["id"],
        "body_hash" => revision["body_hash"]
      }

      payload = %{
        "kind" => "source_preview",
        "source" => pin,
        "connection" => connection_pin(connection)
      }

      Map.put(summary, "passage_token", sign(@scope_salt, payload, caller))
    end)
  end

  defp matching_claim(%{basis: %{"kind" => "company_analysis"} = basis}, context),
    do:
      check(
        basis["project_id"] == context.project.id and basis["goal_id"] == context.goal.id and
          basis["goal_content_hash"] == Goals.content_hash(context.goal),
        :recommendation_out_of_scope
      )

  defp matching_claim(_, _), do: {:error, :recommendation_out_of_scope}
  defp claim_status(_, nil), do: "proposed"
  defp claim_status(_, %{decision: "reject"}), do: "rejected"

  defp claim_status(claim, %{decision: "approve", revision_hash: hash}),
    do:
      if(hash == claim.revision_hash and Evidence.approval_ready?(Store.dto(claim)),
        do: "approved",
        else: "stale"
      )

  defp pins_current?(pins, rows), do: Enum.all?(pins, &pin_current?(&1, rows))

  defp pin_current?(pin, rows),
    do:
      Enum.any?(rows, fn row ->
        row["id"] == pin["source_id"] and row["eligible"] and
          row["latest_revision"]["id"] == pin["revision_id"] and
          row["latest_revision"]["body_hash"] == pin["body_hash"]
      end)

  defp query(value) when is_binary(value) and byte_size(value) <= 1024 do
    if String.valid?(value) and String.length(value) <= 256 do
      text = String.trim(value)
      tokens = Regex.scan(~r/[\p{L}\p{N}_]+/u, text) |> List.flatten()

      if length(tokens) <= 8 and (text == "" or tokens != []),
        do:
          {:ok,
           %{
             text: text,
             tokens: tokens,
             expression: Enum.map_join(tokens, " AND ", &("\"" <> &1 <> "\""))
           }},
        else: {:error, :invalid_query}
    else
      {:error, :invalid_query}
    end
  end

  defp query(_), do: {:error, :invalid_query}

  defp paged(rows, binding, caller) do
    visible = Enum.take(rows, @page_size)

    next =
      if length(rows) > @page_size,
        do:
          sign(@cursor_salt, %{"binding" => binding, "after" => List.last(visible)["id"]}, caller)

    %{"rows" => visible, "next_cursor" => next}
  end

  defp cursor(value, _, _) when value in [nil, ""], do: {:ok, ""}

  defp cursor(token, expected, caller) do
    with {:ok, %{"binding" => ^expected, "after" => after_id}} <-
           verify(@cursor_salt, token, caller, :invalid_cursor),
         true <- uuid?(after_id) do
      {:ok, after_id}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  defp choice_binding(attrs),
    do: %{
      "kind" => "choices",
      "choice_kind" => attrs["kind"],
      "project_id" => attrs["project_id"] || "",
      "goal_id" => attrs["goal_id"] || ""
    }

  defp caller_binding(caller),
    do: %{
      "workspace_id" => Store.workspace(),
      "session_fingerprint" => caller[:session_fingerprint],
      "view_generation" => caller[:view_generation],
      "reset_token" => caller[:reset_token]
    }

  defp sign(salt, payload, caller),
    do: Phoenix.Token.sign(secret(), salt, Map.put(payload, "caller", caller_binding(caller)))

  defp verify(salt, token, caller, reason) when is_binary(token) and byte_size(token) <= 8192 do
    with {:ok, payload} <- Phoenix.Token.verify(secret(), salt, token, max_age: @max_age),
         true <- is_map(payload) and payload["caller"] == caller_binding(caller) do
      {:ok, Map.delete(payload, "caller")}
    else
      _ -> {:error, reason}
    end
  rescue
    _ -> {:error, reason}
  end

  defp verify(_, _, _, reason), do: {:error, reason}

  defp secret,
    do:
      Application.fetch_env!(:harness_forge, HarnessForgeWeb.Endpoint)
      |> Keyword.fetch!(:secret_key_base)

  defp query_rows(sql, params) do
    %{columns: columns, rows: rows} = Repo.query!(sql, params)
    Enum.map(rows, &Map.new(Enum.zip(columns, &1)))
  end

  defp keys(attrs, required, optional \\ [])

  defp keys(attrs, required, optional) when is_map(attrs) and not is_struct(attrs),
    do:
      check(
        Enum.all?(Map.keys(attrs), &is_binary/1) and
          Map.keys(attrs) -- (required ++ optional) == [] and
          Enum.all?(required, &Map.has_key?(attrs, &1)),
        :invalid_input
      )

  defp keys(_, _, _), do: {:error, :invalid_input}
  defp optional_id(id) when id in [nil, ""], do: :ok
  defp optional_id(id), do: check(uuid?(id), :invalid_input)
  defp uuid?(value), do: is_binary(value) and match?({:ok, _}, Ecto.UUID.cast(value))
  defp digest?(value), do: is_binary(value) and Regex.match?(~r/\A[a-f0-9]{64}\z/, value)
  defp check(true, _), do: :ok
  defp check(false, reason), do: {:error, reason}
  defp id_group(nil), do: :ok

  defp id_group(ids) when is_list(ids) and length(ids) <= 100,
    do: check(Enum.all?(ids, &uuid?/1), :invalid_input)

  defp id_group(_), do: {:error, :invalid_input}
  defp ref_group(nil), do: :ok

  defp ref_group(refs) when is_list(refs) and length(refs) <= 4,
    do: check(Enum.all?(refs, &Origin.source_ref?/1), :invalid_input)

  defp ref_group(_), do: {:error, :invalid_input}
  defp decode(value) when is_map(value), do: value
  defp decode(value), do: Jason.decode!(value)

  # The whitelist denotes explicitly captured historical semantics. General
  # connector kind/status/created_at fields do not imply documentary authority.
  defp historical_metadata(value) do
    value
    |> decode()
    |> Enum.filter(fn
      {"document_status", status} ->
        is_binary(status) and String.valid?(status) and String.trim(status) != ""

      {key, date} when key in ~w(effective_at event_at) ->
        is_binary(date) and match?({:ok, _, _}, DateTime.from_iso8601(date))

      _ ->
        false
    end)
    |> Map.new()
  end

  defp timestamp(nil), do: nil

  defp timestamp(value) when is_binary(value) do
    case NaiveDateTime.from_iso8601(String.replace(value, " ", "T")) do
      {:ok, time} -> time |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()
      _ -> value
    end
  end

  # Navigation hygiene mirrors the existing analysis metadata renderer. It
  # preserves admitted bytes, never repairs/fetches a stored URL.
  defp safe_url(url) when is_binary(url) and byte_size(url) in 1..2048 do
    with true <- String.valid?(url),
         false <- Regex.match?(~r/[\p{Z}\p{Cc}\p{Cf}\s\\<>"`{}|^]/u, url),
         false <- Regex.match?(~r/%(?![0-9a-f]{2})/i, url),
         false <- Regex.match?(~r/%(?:0[0-9a-f]|1[0-9a-f]|7f|5c)/i, url),
         [authority] <- Regex.run(~r/\Ahttps?:\/\/([^\/?#]+)/i, url, capture: :all_but_first),
         true <- valid_authority?(authority),
         %URI{scheme: scheme, host: host, userinfo: nil} <- URI.parse(url),
         true <- String.downcase(scheme) in ["http", "https"] and is_binary(host) and host != "" do
      url
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp safe_url(_), do: nil

  defp valid_authority?("[" <> rest) do
    case String.split(rest, "]", parts: 2) do
      [host, suffix] ->
        with true <- Regex.match?(~r/\A[0-9a-f:.]+\z/i, host),
             {:ok, address} <- :inet.parse_address(String.to_charlist(host)) do
          tuple_size(address) == 8 and valid_port_suffix?(suffix)
        else
          _ -> false
        end

      _ ->
        false
    end
  end

  defp valid_authority?(authority) do
    case String.split(authority, ":") do
      [host] -> valid_host?(host)
      [host, port] -> valid_host?(host) and valid_port?(port)
      _ -> false
    end
  end

  defp valid_port_suffix?(""), do: true
  defp valid_port_suffix?(":" <> port), do: valid_port?(port)
  defp valid_port_suffix?(_), do: false

  defp valid_port?(port),
    do: Regex.match?(~r/\A[0-9]+\z/, port) and String.to_integer(port) in 1..65535

  defp valid_host?(host) do
    if Regex.match?(~r/\A[0-9.]+\z/, host) do
      Regex.match?(~r/\A(?:0|[1-9][0-9]{0,2})(?:\.(?:0|[1-9][0-9]{0,2})){3}\z/, host) and
        Enum.all?(String.split(host, "."), &(String.to_integer(&1) <= 255))
    else
      dns =
        if String.ends_with?(host, "."), do: binary_part(host, 0, byte_size(host) - 1), else: host

      labels = String.split(dns, ".")

      byte_size(dns) in 1..253 and
        Enum.all?(labels, &Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/i, &1)) and
        not Regex.match?(~r/\A(?:[0-9]+|0x[0-9a-f]+)\z/i, List.last(labels))
    end
  end
end
