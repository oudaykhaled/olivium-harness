defmodule HarnessForge.Evidence.OriginV2 do
  @moduledoc "Revision-pinned, paged dependency manifests for passage-based company analysis."
  import Ecto.Query
  alias HarnessForge.{Contracts, Evidence, Goals, Repo, Workspaces}
  alias HarnessForge.Evidence.{Store, Source, Revision, RevisionUseHolds, Connection, Goal}
  alias HarnessForge.Company.{Profile, Project, Retrieval}
  alias HarnessForge.Models.CompanyAnalysis, as: Output

  @basis ~w(kind version project_id goal_id goal_content_hash context context_digest report guidance provider model config_fingerprint run_id request_id review_resolution)
  @context ~w(workspace_id profile project corpus_id semantic_generation authorization_generation retrieval_run_id retrieval_digest manifest_id manifest_digest)

  # The checked pack is obtained on the server, never accepted as browser authority.
  def seal_retrieval(id, digest, caller), do: seal_retrieval(id, digest, caller, nil)

  def seal_retrieval(id, digest, caller, stage_id) do
    HarnessForge.Privacy.Purge.synchronize(fn ->
      Store.transaction(fn ->
        with :ok <- Workspaces.ensure_writable(),
             {:ok, pack} <- Retrieval.resolve_for_analysis(id, digest, caller),
             :ok <- validate_graph_pack(pack, caller),
             {:ok, pin} <- optional_stage(stage_id),
             {:ok, manifest} <- seal_pack(pack, pin) do
          context = %{
            "workspace_id" => Store.workspace(),
            "profile" => Map.take(pack["profile"], ~w(id content_hash)),
            "project" => Map.take(pack["project"], ~w(id content_hash)),
            "corpus_id" => pack["corpus_id"],
            "semantic_generation" => pack["semantic_generation"],
            "authorization_generation" => pack["authorization_generation"],
            "retrieval_run_id" => id,
            "retrieval_digest" => digest,
            "manifest_id" => manifest["id"],
            "manifest_digest" => manifest["digest"]
          }

          {:ok, Map.put(pack, "origin_context", context)}
        else
          false -> {:error, :closure_incomplete}
          error -> error
        end
      end)
    end)
  end

  defp validate_graph_pack(%{"manifest" => %{"graph" => nil}}, _caller), do: :ok

  defp validate_graph_pack(pack, caller),
    do:
      HarnessForge.Graphiti.SearchCompletion.validate_certificate(
        pack["manifest"]["graph"],
        pack,
        caller
      )

  defp optional_stage(nil), do: {:ok, nil}
  defp optional_stage(id), do: HarnessForge.Models.StageAuthority.load_pin(id)

  defp seal_pack(pack, pin) do
    refs = pack["manifest"]["dependencies"]

    if is_list(refs) and length(refs) in 1..24 do
      refs = refs |> Enum.uniq_by(& &1["source_id"]) |> Enum.sort_by(& &1["source_id"])

      context = %{
        "retrieval_run_id" => pack["run_id"],
        "retrieval_digest" => pack["digest"],
        "profile" => Map.take(pack["profile"], ~w(id content_hash)),
        "project" => Map.take(pack["project"], ~w(id content_hash)),
        "goal_id" => pack["goal_id"],
        "goal_hash" => pack["goal_hash"],
        "passages" =>
          Enum.map(
            pack["passages"],
            &Map.take(
              &1,
              ~w(passage_id source_id revision_id body_hash start_byte end_byte snippet_hash parent_start_byte parent_end_byte parent_hash)
            )
          )
      }

      source_deps =
        Enum.map(refs, fn ref ->
          %{
            "dependency_key" => ref["revision_id"],
            "kind" => "source_revision",
            "source_id" => ref["source_id"],
            "revision_id" => ref["revision_id"],
            "content_hash" => ref["body_hash"],
            "role" => "uncited"
          }
        end)

      pins = [
        {"goal", pack["goal_id"], pack["goal_hash"]},
        {"project", pack["project"]["id"], pack["project"]["content_hash"]},
        {"profile", pack["profile"]["id"], pack["profile"]["content_hash"]}
      ]

      deps =
        source_deps ++
          Enum.map(pins, fn {kind, id, hash} ->
            %{
              "dependency_key" => kind <> ":" <> id,
              "kind" => kind,
              "source_id" => nil,
              "revision_id" => nil,
              "content_hash" => hash,
              "role" => "transitive"
            }
          end)

      {context, deps} =
        if pin do
          {Map.put(context, "stage", Map.take(pin, ~w(id config_digest))),
           deps ++
             [
               %{
                 "dependency_key" => "stage:" <> pin["id"],
                 "kind" => "stage",
                 "source_id" => nil,
                 "revision_id" => nil,
                 "content_hash" => pin["config_digest"],
                 "role" => "transitive"
               }
             ]}
        else
          {context, deps}
        end

      {context, deps} =
        case pack["manifest"]["graph"] do
          nil ->
            {context, deps}

          cert ->
            {Map.put(context, "graph", cert),
             deps ++
               [
                 %{
                   "dependency_key" => "graph_search:" <> cert["search_ref"],
                   "kind" => "manifest",
                   "source_id" => nil,
                   "revision_id" => nil,
                   "content_hash" => cert["search_digest"],
                   "role" => "transitive",
                   "parent_manifest_id" => cert["search_ref"]
                 }
               ]}
        end

      create_manifest(pack, context, deps)
    else
      {:error, :closure_incomplete}
    end
  end

  @doc false
  def create_manifest(scope, context, deps) do
    id = Ecto.UUID.generate()

    envelope =
      Map.take(scope, ~w(corpus_id semantic_generation authorization_generation))
      |> Map.put("workspace_id", Store.workspace())

    digest =
      Contracts.digest(%{"scope" => envelope, "context" => context, "dependencies" => deps})

    now = DateTime.to_iso8601(Store.now())
    encoded = Contracts.canonical_json(context)

    if byte_size(encoded) <= 16_384 and length(deps) <= 100 do
      with {:ok, _} <-
             Repo.query(
               "INSERT INTO dependency_manifests(id,workspace_id,corpus_id,semantic_generation,authorization_generation,purpose,state,digest,source_count,context_json,inserted_at) VALUES(?,?,?,?,?,'retrieval','building',NULL,?,?,?)",
               [
                 id,
                 Store.workspace(),
                 scope["corpus_id"],
                 scope["semantic_generation"],
                 scope["authorization_generation"],
                 Enum.count(deps, &(&1["kind"] == "source_revision")),
                 encoded,
                 now
               ]
             ),
           :ok <- insert_dependencies(id, deps),
           {:ok, _} <-
             Repo.query(
               "UPDATE dependency_manifests SET state='sealed',digest=? WHERE id=? AND workspace_id=? AND state='building'",
               [digest, id, Store.workspace()]
             ) do
        {:ok, %{"id" => id, "digest" => digest}}
      end
    else
      {:error, :closure_incomplete}
    end
  end

  defp insert_dependencies(id, deps) do
    deps
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {d, n}, :ok ->
      case Repo.query(
             "INSERT INTO origin_dependencies(workspace_id,manifest_id,dependency_key,kind,source_id,revision_id,content_hash,role,ordinal,parent_manifest_id) VALUES(?,?,?,?,?,?,?,?,?,?)",
             [
               Store.workspace(),
               id,
               d["dependency_key"],
               d["kind"],
               d["source_id"],
               d["revision_id"],
               d["content_hash"],
               d["role"],
               n,
               d["parent_manifest_id"]
             ]
           ) do
        {:ok, _} -> {:cont, :ok}
        _ -> {:halt, {:error, :closure_incomplete}}
      end
    end)
  end

  def manifest(id, digest) do
    with true <- Output.uuid?(id) and Output.digest?(digest),
         {:ok, %{rows: [[corpus, sem, auth, "sealed", ^digest, context, count]]}} <-
           Repo.query(
             "SELECT corpus_id,semantic_generation,authorization_generation,state,digest,context_json,source_count FROM dependency_manifests WHERE workspace_id=? AND id=?",
             [Store.workspace(), id]
           ),
         {:ok, context} <- Jason.decode(context),
         :ok <- HarnessForge.Evidence.Corpora.assert_current(corpus, sem, auth),
         :ok <- validate_pins(context),
         :ok <- validate_dependency_pages(id, -1, 0, count) do
      {:ok,
       %{
         "id" => id,
         "digest" => digest,
         "corpus_id" => corpus,
         "semantic_generation" => sem,
         "authorization_generation" => auth,
         "context" => context,
         "source_count" => count
       }}
    else
      _ -> {:error, :stale_company_analysis_context}
    end
  end

  defp validate_pins(context) do
    with {:ok, p} <- Store.get(Profile, context["profile"]["id"]),
         true <- p.content_hash == context["profile"]["content_hash"],
         {:ok, project} <- Store.get(Project, context["project"]["id"]),
         true <- project.content_hash == context["project"]["content_hash"],
         {:ok, goal} <- Store.get(Goal, context["goal_id"]),
         true <- Goals.content_hash(goal) == context["goal_hash"],
         :ok <-
           Retrieval.validate_current(context["retrieval_run_id"], context["retrieval_digest"]),
         :ok <- validate_stage_pin(context["stage"]) do
      :ok
    else
      _ -> {:error, :stale_company_analysis_context}
    end
  end

  defp validate_stage_pin(nil), do: :ok

  defp validate_stage_pin(%{"id" => id, "config_digest" => hash}) do
    case HarnessForge.Models.StageAuthority.load_pin(id) do
      {:ok, %{"config_digest" => ^hash}} -> :ok
      _ -> {:error, :stage_unavailable}
    end
  end

  defp validate_stage_pin(_), do: {:error, :stage_unavailable}

  defp validate_dependency_pages(id, after_n, seen, expected) do
    with {:ok, %{rows: rows}} <-
           Repo.query(
             "SELECT ordinal,kind,source_id,revision_id,content_hash FROM origin_dependencies WHERE workspace_id=? AND manifest_id=? AND ordinal>? ORDER BY ordinal LIMIT 100",
             [Store.workspace(), id, after_n]
           ),
         :ok <-
           Enum.reduce_while(rows, :ok, fn row, :ok ->
             case validate_dependency(row, id) do
               :ok -> {:cont, :ok}
               e -> {:halt, e}
             end
           end) do
      count = seen + Enum.count(rows, fn [_, kind, _, _, _] -> kind == "source_revision" end)

      case rows do
        [] -> if count == expected and count > 0, do: :ok, else: {:error, :closure_incomplete}
        _ -> validate_dependency_pages(id, rows |> List.last() |> hd(), count, expected)
      end
    end
  end

  # Only the one typed search-result parent is admitted; never walk ancestry.
  defp validate_dependency([ordinal, "manifest", nil, nil, hash], id) do
    with {:ok, %{rows: [[parent, key, corpus, sem, access, json]]}} <-
           Repo.query(
             "SELECT d.parent_manifest_id,d.dependency_key,m.corpus_id,m.semantic_generation,m.authorization_generation,m.context_json FROM origin_dependencies d JOIN dependency_manifests m ON m.workspace_id=d.workspace_id AND m.id=d.manifest_id WHERE d.workspace_id=? AND d.manifest_id=? AND d.ordinal=? AND d.kind='manifest'",
             [Store.workspace(), id, ordinal]
           ),
         {:ok, context} <- Jason.decode(json),
         cert when is_map(cert) <- context["graph"],
         true <-
           parent == cert["search_ref"] and hash == cert["search_digest"] and
             key == "graph_search:" <> parent,
         scope = %{
           "workspace_id" => Store.workspace(),
           "corpus_id" => corpus,
           "semantic_generation" => sem,
           "authorization_generation" => access,
           "project_id" => context["project"]["id"],
           "project" => context["project"],
           "profile" => context["profile"],
           "goal_id" => context["goal_id"],
           "goal_hash" => context["goal_hash"]
         },
         :ok <- HarnessForge.Graphiti.SearchCompletion.validate_stored_certificate(cert, scope),
         do: :ok,
         else: (_ -> {:error, :closure_incomplete})
  end

  defp validate_dependency(row, _id), do: validate_dependency(row)

  defp validate_dependency([_, "source_revision", source_id, revision_id, hash]) do
    with :ok <- RevisionUseHolds.assert_use(source_id, revision_id, hash, "analysis"),
         {:ok, source} <- Store.get(Source, source_id),
         true <- source.status == "active" and source.latest_revision_id == revision_id,
         revision when not is_nil(revision) <-
           Repo.one(
             from r in Store.scoped(Revision),
               where: r.id == ^revision_id,
               select: %{
                 source_id: r.source_id,
                 body_hash: r.body_hash,
                 source_url: r.source_url,
                 metadata: r.metadata
               }
           ),
         true <- revision.source_id == source_id and revision.body_hash == hash,
         {:ok, conn} <- Store.get(Connection, source.connection_id),
         true <- conn.status == "active",
         :ok <-
           HarnessForge.Connectors.Registry.document_scope(conn, %{
             "external_id" => source.external_id,
             "source_url" => revision.source_url,
             "metadata" => revision.metadata
           }) do
      :ok
    else
      _ -> {:error, :source_unavailable}
    end
  end

  defp validate_dependency([_, kind, nil, nil, _]) when kind in ~w(goal project profile stage),
    do: :ok

  # Graph ancestry must be a validated version inventory. Unknown versions are never inferred clean.
  defp validate_dependency(_), do: {:error, :closure_incomplete}

  def validate_context(context) do
    with true <- Output.keys?(context, @context),
         true <- context["workspace_id"] == Store.workspace(),
         {:ok, m} <- manifest(context["manifest_id"], context["manifest_digest"]),
         true <-
           m["corpus_id"] == context["corpus_id"] and
             m["semantic_generation"] == context["semantic_generation"] and
             m["authorization_generation"] == context["authorization_generation"],
         true <-
           m["context"]["profile"] == context["profile"] and
             m["context"]["project"] == context["project"],
         true <-
           m["context"]["retrieval_run_id"] == context["retrieval_run_id"] and
             m["context"]["retrieval_digest"] == context["retrieval_digest"] do
      :ok
    else
      _ -> {:error, :stale_company_analysis_context}
    end
  end

  def valid_basis?(basis) do
    Output.keys?(basis, @basis) and basis["kind"] == "company_analysis" and basis["version"] === 2 and
      Output.keys?(basis["context"], @context) and Output.digest?(basis["context_digest"]) and
      Output.uuid?(basis["context"]["workspace_id"]) and
      Contracts.digest(basis["context"]) == basis["context_digest"] and
      Output.uuid?(basis["project_id"]) and Output.uuid?(basis["goal_id"]) and
      Output.digest?(basis["goal_content_hash"]) and
      basis["context"]["project"]["id"] == basis["project_id"] and
      Output.valid_structure?(basis["report"]) and
      not is_nil(basis["report"]["recommendation"]) and
      byte_size(Contracts.canonical_json(basis["report"])) <= 32_768 and
      Output.keys?(basis["guidance"], ~w(rule workflow check evaluation_criterion)) and
      Enum.all?(basis["guidance"], fn {_, v} -> Output.text?(v) and v == String.trim(v) end) and
      basis["provider"] in ~w(ollama openai openai_responses anthropic) and
      is_binary(basis["model"]) and byte_size(basis["model"]) in 1..200 and
      Output.digest?(basis["config_fingerprint"]) and Output.uuid?(basis["run_id"]) and
      Output.uuid?(basis["request_id"]) and
      (is_nil(basis["review_resolution"]) or Output.text?(basis["review_resolution"]))
  rescue
    _ -> false
  end

  def references(%{"basis" => basis, "citations" => citations}) do
    if valid_basis?(basis) and is_list(citations) and length(citations) in 1..16 and
         Enum.all?(citations, &valid_citation?/1) and report_citations_match?(basis, citations) do
      {:ok,
       %{
         "revision_ids" => Enum.sort(Enum.uniq(Enum.map(citations, & &1["revision_id"]))),
         "source_ids" => [],
         "goal_ids" => [basis["goal_id"]],
         "project_ids" => [basis["project_id"]],
         "profile_ids" => [basis["context"]["profile"]["id"]],
         "manifest_refs" => [
           %{
             "id" => basis["context"]["manifest_id"],
             "digest" => basis["context"]["manifest_digest"]
           }
         ]
       }}
    else
      {:error, :invalid_claim_basis}
    end
  end

  defp valid_citation?(c) do
    is_map(c) and Output.uuid?(c["id"]) and Output.uuid?(c["revision_id"]) and
      Output.digest?(c["snippet_hash"]) and
      is_binary(c["snippet"]) and String.valid?(c["snippet"]) and is_integer(c["start_byte"]) and
      is_integer(c["end_byte"]) and
      c["start_byte"] >= 0 and c["end_byte"] > c["start_byte"] and
      byte_size(c["snippet"]) == c["end_byte"] - c["start_byte"] and
      Store.hash(c["snippet"]) == c["snippet_hash"]
  end

  defp report_citations_match?(basis, citations) do
    expected =
      Output.citations(basis["report"])
      |> Enum.map(&Map.take(&1, ~w(revision_id start_byte end_byte snippet)))
      |> Enum.uniq()
      |> Enum.sort()

    actual =
      citations
      |> Enum.map(&Map.take(&1, ~w(revision_id start_byte end_byte snippet)))
      |> Enum.sort()

    expected == actual
  end

  def validate_origin(basis, citations) do
    with {:ok, _} <- references(%{"basis" => basis, "citations" => citations}),
         :ok <- validate_context(basis["context"]),
         {:ok, m} <-
           manifest(basis["context"]["manifest_id"], basis["context"]["manifest_digest"]),
         true <-
           m["context"]["goal_id"] == basis["goal_id"] and
             m["context"]["goal_hash"] == basis["goal_content_hash"],
         %{"id" => stage_id, "config_digest" => stage_digest} <- m["context"]["stage"],
         {:ok, pin} <- HarnessForge.Models.StageAuthority.load_pin(stage_id),
         true <-
           stage_digest == basis["config_fingerprint"] and pin["provider"] == basis["provider"] and
             pin["model"] == basis["model"],
         :ok <- validate_report_windows(basis["report"], m["context"]["passages"]),
         {:ok, actual} <- Evidence.validate_citations(citations),
         true <-
           HarnessForge.Evidence.Origin.identity(actual) ==
             HarnessForge.Evidence.Origin.identity(citations) do
      {:ok, HarnessForge.Evidence.Origin.canonical(actual)}
    else
      {:error, _} = e -> e
      _ -> {:error, :invalid_claim_basis}
    end
  end

  def validate_report_windows(report, windows) do
    if Output.valid_structure?(report) and
         Enum.all?(Output.citations(report), fn c ->
           Enum.any?(windows, fn w ->
             c["source_id"] == w["source_id"] and c["revision_id"] == w["revision_id"] and
               c["start_byte"] >= w["parent_start_byte"] and c["end_byte"] <= w["parent_end_byte"] and
               case Repo.query(
                      "SELECT substr(CAST(body AS BLOB),?,?) FROM evidence_revisions WHERE workspace_id=? AND id=? AND source_id=? AND body_hash=?",
                      [
                        c["start_byte"] + 1,
                        c["end_byte"] - c["start_byte"],
                        Store.workspace(),
                        c["revision_id"],
                        c["source_id"],
                        w["body_hash"]
                      ]
                    ) do
                 {:ok, %{rows: [[bytes]]}} -> bytes == c["snippet"] and String.valid?(bytes)
                 _ -> false
               end
           end)
         end), do: :ok, else: {:error, :invalid_company_analysis_output}
  rescue
    _ -> {:error, :invalid_company_analysis_output}
  end

  def contains_source?(id, source_id) do
    # Privacy uses conservative historical authority, including already denied
    # certificates. A local graph manifest inherits its source certificate by
    # handle; it does not contain a copied source list.
    case Repo.query(
           """
           SELECT 1 FROM origin_dependencies d WHERE d.workspace_id=? AND d.source_id=?
             AND (d.manifest_id=coalesce((SELECT coalesce(b.source_manifest_id,b.manifest_id)
               FROM graph_manifest_builds b WHERE b.workspace_id=? AND b.manifest_id=?),?)
               OR EXISTS(SELECT 1 FROM origin_dependencies p JOIN graph_manifest_builds b
                 ON b.workspace_id=p.workspace_id AND b.manifest_id=p.parent_manifest_id
                 WHERE p.workspace_id=d.workspace_id AND p.manifest_id=? AND p.kind='manifest'
                   AND p.dependency_key='graph_search:'||p.parent_manifest_id
                   AND d.manifest_id=b.source_manifest_id))
           LIMIT 1
           """,
           [Store.workspace(), source_id, Store.workspace(), id, id, id]
         ) do
      {:ok, %{rows: [[1]]}} -> true
      {:ok, %{rows: []}} -> false
      _ -> raise "source dependency state unavailable"
    end
  end
end
