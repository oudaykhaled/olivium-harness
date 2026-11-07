defmodule HarnessForge.Evidence.GraphSources do
  @moduledoc "Checkpointed metadata-only source eligibility for a server-qualified graph runtime."
  alias HarnessForge.{Contracts, Repo, Workspaces}
  alias HarnessForge.Evidence.{Corpora, Store}
  alias HarnessForge.Company.{AssessmentAttempts, CorpusReview}
  alias HarnessForge.Models.Stages

  @runtime_keys ~w(worker_image backend_image backend_instance database index_identity)
  @worker_files ~w(runtime.py inventory.py response_proof.py schema_export.py schema-catalogue.json observations.py lineage.py ipc_transport.py protocol.py worker.py __main__.py source.lock.json dependencies.lock.json uv.lock pyproject.toml Dockerfile vendor/graphiti_core-0.31.2-py3-none-any.whl)

  # Called by the root runtime qualifier, never by browser input. A bundle is an
  # identity, not a qualification verdict or proof that a backend is clean.
  def runtime_bundle(identity) when is_map(identity) do
    with true <- Enum.sort(Map.keys(identity)) == Enum.sort(@runtime_keys),
         true <- Enum.all?(~w(worker_image backend_image), &image?(identity[&1])),
         true <-
           Enum.all?(
             ~w(backend_instance database index_identity),
             &Stages.identifier?(identity[&1])
           ),
         {:ok, files} <- file_pins() do
      {:ok,
       Map.merge(identity, %{
         "format" => "graph-runtime-authority-v1",
         "graphiti_commit" => "d72407dcedac911e1be9fc15b55e8c05a3efcc36",
         "files" => files,
         "chunker_version" => "utf8-parent-v2",
         "parser_version" => "captured-metadata-v2",
         "source_policy" => Store.hash(CorpusReview.document_scope_sql()),
         "inventory_schema" => "root-verified-graph-values-v1",
         "inventory_policy" => "empty_custom_attributes_only",
         "schema_catalogue" => HarnessForge.Graphiti.SchemaPolicy.digest()
       })}
    else
      _ -> {:error, :stage_unavailable}
    end
  end

  def runtime_bundle(_), do: {:error, :stage_unavailable}

  @doc "Reserve durable scope before provisioning; null pins confer no source-scan or worker authority."
  def reserve(corpus_id, caller) do
    guard(caller, fn ->
      with {:ok, corpus} <- Corpora.get(corpus_id),
           :ok <-
             Corpora.assert_current(
               corpus_id,
               corpus.semantic_generation,
               corpus.authorization_generation
             ) do
        id = Ecto.UUID.generate()

        group =
          "hf_" <>
            String.replace(Store.workspace(), "-", "") <> "_" <> String.replace(id, "-", "")

        now = DateTime.to_iso8601(Store.now())

        with {:ok, _} <-
               Repo.query(
                 "INSERT INTO graph_partition_controls(id,workspace_id,corpus_id,group_id,semantic_generation,authorization_generation,cancel_epoch,state,lock_version,inserted_at,updated_at) VALUES(?,?,?,?,?,?,0,'staging',1,?,?)",
                 [
                   id,
                   Store.workspace(),
                   corpus_id,
                   group,
                   corpus.semantic_generation,
                   corpus.authorization_generation,
                   now,
                   now
                 ]
               ),
             {:ok, _} <-
               Repo.query(
                 "INSERT INTO graph_source_scans(workspace_id,partition_id,chain_hash,state,inserted_at,updated_at) VALUES(?,?,?,'scanning',?,?)",
                 [Store.workspace(), id, Store.hash("HF-GRAPH-SOURCE-ROWS-v1\n"), now, now]
               ) do
          {:ok,
           %{
             "partition_id" => id,
             "group_id" => group,
             "state" => "awaiting_runtime",
             "source_count" => 0
           }}
        end
      end
    end)
  end

  @doc "CAS-bind only the private root launch owner's actual verified runtime identity."
  def bind_runtime(partition_id, caller) do
    with {:ok, bundle} <- HarnessForge.Graphiti.Runtime.binding(partition_id) do
      guard(caller, fn ->
        with {:ok, %{num_rows: 1}} <-
               Repo.query(
                 "UPDATE graph_partition_controls SET backend_pin_digest=?,authority_json=?,updated_at=? WHERE workspace_id=? AND id=? AND state='staging' AND backend_pin_digest IS NULL AND authority_json IS NULL AND EXISTS(SELECT 1 FROM graph_runtime_backends b WHERE b.workspace_id=graph_partition_controls.workspace_id AND b.partition_id=graph_partition_controls.id AND b.state='verified' AND b.bundle_digest=?)",
                 [
                   Contracts.digest(bundle),
                   Contracts.canonical_json(bundle),
                   DateTime.to_iso8601(Store.now()),
                   Store.workspace(),
                   partition_id,
                   Contracts.digest(bundle)
                 ]
               ) do
          {:ok,
           %{"partition_id" => partition_id, "backend_pin_digest" => Contracts.digest(bundle)}}
        else
          _ -> {:error, :reconcile_required}
        end
      end)
    end
  end

  # Legacy configured identities support metadata/certificate tests. A live
  # backend row can NEVER fall back to such configuration after losing authority.
  def runtime_for(partition_id) do
    case Repo.query(
           "SELECT state,bundle_digest,bundle_json FROM graph_runtime_backends WHERE workspace_id=? AND partition_id=?",
           [Store.workspace(), partition_id]
         ) do
      {:ok, %{rows: []}} ->
        qualified_runtime()

      {:ok, %{rows: [["verified", digest, json]]}} ->
        with {:ok, bundle} <- HarnessForge.Graphiti.Runtime.binding(partition_id),
             true <-
               Contracts.digest(bundle) == digest and Contracts.canonical_json(bundle) == json,
             do: {:ok, bundle},
             else: (_ -> {:error, :graph_unavailable})

      _ ->
        {:error, :graph_unavailable}
    end
  end

  def start(corpus_id, caller) do
    guard(caller, fn ->
      with {:ok, corpus} <- Corpora.get(corpus_id),
           :ok <-
             Corpora.assert_current(
               corpus_id,
               corpus.semantic_generation,
               corpus.authorization_generation
             ),
           {:ok, bundle} <- qualified_runtime() do
        id = Ecto.UUID.generate()

        group =
          "hf_" <>
            String.replace(Store.workspace(), "-", "") <> "_" <> String.replace(id, "-", "")

        now = DateTime.to_iso8601(Store.now())

        with {:ok, _} <-
               Repo.query(
                 """
                 INSERT INTO graph_partition_controls
                  (id,workspace_id,corpus_id,group_id,semantic_generation,authorization_generation,
                   cancel_epoch,state,manifest_id,lock_version,backend_pin_digest,authority_json,inserted_at,updated_at)
                 VALUES(?,?,?,?,?,?,0,'staging',NULL,1,?,?,?,?)
                 """,
                 [
                   id,
                   Store.workspace(),
                   corpus_id,
                   group,
                   corpus.semantic_generation,
                   corpus.authorization_generation,
                   Contracts.digest(bundle),
                   Contracts.canonical_json(bundle),
                   now,
                   now
                 ]
               ),
             {:ok, _} <-
               Repo.query(
                 "INSERT INTO graph_source_scans(workspace_id,partition_id,chain_hash,state,inserted_at,updated_at) VALUES(?,?,?,'scanning',?,?)",
                 [Store.workspace(), id, Store.hash("HF-GRAPH-SOURCE-ROWS-v1\n"), now, now]
               ) do
          {:ok,
           %{
             "partition_id" => id,
             "group_id" => group,
             "state" => "scanning",
             "source_count" => 0
           }}
        end
      end
    end)
  end

  @doc "Advance at most 100 source triples; an independently observed empty page seals exhaustion."
  def advance(partition_id, caller) do
    guard(caller, fn ->
      with {:ok,
            %{
              rows: [
                [corpus, sem, access, "staging", nil, backend, json, last, count, chain, state]
              ]
            }} <-
             Repo.query(
               """
               SELECT p.corpus_id,p.semantic_generation,p.authorization_generation,p.state,p.manifest_id,
                      p.backend_pin_digest,p.authority_json,s.last_source_id,s.source_count,s.chain_hash,s.state
               FROM graph_partition_controls p JOIN graph_source_scans s
                ON s.workspace_id=p.workspace_id AND s.partition_id=p.id
               WHERE p.workspace_id=? AND p.id=?
               """,
               [Store.workspace(), partition_id]
             ),
           true <- state in ~w(scanning complete),
           :ok <- Corpora.assert_current(corpus, sem, access),
           {:ok, bundle} <- runtime_for(partition_id),
           true <-
             Contracts.canonical_json(bundle) == json and Contracts.digest(bundle) == backend do
        if state == "complete" do
          {:ok, %{"partition_id" => partition_id, "state" => "complete", "source_count" => count}}
        else
          advance_page(partition_id, corpus, last, count, chain)
        end
      else
        _ -> {:error, :stale_generation}
      end
    end)
  end

  defp advance_page(partition, corpus, last, count, chain) do
    with {:ok, %{rows: rows}} <-
           Repo.query(
             """
             SELECT m.source_id,m.revision_id,r.body_hash,
               CASE WHEN s.status='active' AND s.latest_revision_id=m.revision_id AND c.status='active'
                 AND (#{CorpusReview.document_scope_sql()}) THEN 1 ELSE 0 END
             FROM corpus_members m LEFT JOIN evidence_sources s ON s.workspace_id=m.workspace_id AND s.id=m.source_id
             LEFT JOIN evidence_revisions r ON r.workspace_id=m.workspace_id AND r.source_id=m.source_id AND r.id=m.revision_id
             LEFT JOIN source_connections c ON c.workspace_id=s.workspace_id AND c.id=s.connection_id
             WHERE m.workspace_id=? AND m.corpus_id=? AND m.status='active' AND m.source_id>?
             ORDER BY m.source_id LIMIT 100
             """,
             [Store.workspace(), corpus, last]
           ),
         true <-
           Enum.all?(rows, fn [s, r, h, valid] ->
             valid == 1 and Corpora.uuid?(s) and Corpora.uuid?(r) and Stages.digest?(h)
           end) do
      if rows == [] do
        if count > 0 do
          digest =
            Contracts.digest(%{
              "format" => "graph-source-set-v1",
              "rows_hash" => chain,
              "source_count" => count
            })

          Repo.query!(
            "UPDATE graph_partition_controls SET source_lock_digest=?,updated_at=? WHERE workspace_id=? AND id=? AND source_lock_digest IS NULL",
            [digest, DateTime.to_iso8601(Store.now()), Store.workspace(), partition]
          )

          Repo.query!(
            "UPDATE graph_source_scans SET state='complete',updated_at=? WHERE workspace_id=? AND partition_id=?",
            [DateTime.to_iso8601(Store.now()), Store.workspace(), partition]
          )

          {:ok,
           %{
             "partition_id" => partition,
             "state" => "complete",
             "source_count" => count,
             "source_lock_digest" => digest
           }}
        else
          {:error, :source_unavailable}
        end
      else
        {next, n} =
          Enum.reduce(rows, {chain, count}, fn [s, r, h, 1], {old, i} ->
            bytes =
              Contracts.canonical_json(%{"source_id" => s, "revision_id" => r, "body_hash" => h})

            {Store.hash(
               Base.decode16!(old, case: :lower) <>
                 <<i::unsigned-big-64, byte_size(bytes)::unsigned-big-64>> <> bytes
             ), i + 1}
          end)

        Repo.query!(
          "UPDATE graph_source_scans SET last_source_id=?,source_count=?,chain_hash=?,updated_at=? WHERE workspace_id=? AND partition_id=? AND state='scanning'",
          [
            rows |> List.last() |> hd(),
            n,
            next,
            DateTime.to_iso8601(Store.now()),
            Store.workspace(),
            partition
          ]
        )

        {:ok, %{"partition_id" => partition, "state" => "scanning", "source_count" => n}}
      end
    else
      _ -> {:error, :source_unavailable}
    end
  end

  @doc "Append or validate one source-certificate page. Never drains a corpus in one call."
  def certificate_step(auth) do
    alias HarnessForge.Evidence.GraphManifests

    with {:ok, _} <- HarnessForge.Models.StageControl.graph_current(auth),
         {:ok, %{rows: [[count]]}} <-
           Repo.query(
             "SELECT source_count FROM graph_source_scans WHERE workspace_id=? AND partition_id=? AND state='complete'",
             [Store.workspace(), auth.partition_id]
           ),
         context =
           Map.new(
             ~w(operation_manifest_ref operation_manifest_digest base_context_ref base_context_digest context_id logical_call_id seam_id stage_id prompt_name config_digest schema_digest raw_body_sha256 rendered_projection_digest transform_id receipt_ref receipt_digest),
             &{&1, nil}
           )
           |> Map.put("graph_kind", "operation"),
         {:ok, status} <- GraphManifests.begin_manifest(auth, "partition", context) do
      case status["phase"] do
        "sealed" -> {:ok, status}
        "validating" -> GraphManifests.advance_validation(status["manifest_id"], auth)
        "receiving" -> source_certificate_page(status, count, auth)
        _ -> {:error, :closure_incomplete}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :closure_incomplete}
    end
  end

  defp source_certificate_page(status, count, auth) do
    alias HarnessForge.Evidence.GraphManifests
    id = status["manifest_id"]

    if status["final_received"] do
      GraphManifests.finish_manifest(
        id,
        %{"dependency_count" => count, "source_count" => count},
        auth
      )
    else
      after_id =
        case Repo.query!(
               "SELECT source_id FROM origin_dependencies WHERE manifest_id=? AND ordinal=?",
               [id, status["next_ordinal"] - 1]
             ).rows do
          [] -> ""
          [[last]] -> last
        end

      previous =
        case Repo.query!(
               "SELECT page_digest FROM graph_manifest_pages WHERE manifest_id=? AND page_index=?",
               [id, status["next_page_index"] - 1]
             ).rows do
          [] -> nil
          [[hash]] -> hash
        end

      rows =
        Repo.query!(
          """
          SELECT m.source_id,m.revision_id,r.body_hash FROM corpus_members m
          JOIN evidence_revisions r ON r.workspace_id=m.workspace_id AND r.source_id=m.source_id AND r.id=m.revision_id
          WHERE m.workspace_id=? AND m.corpus_id=? AND m.status='active' AND m.source_id>?
          ORDER BY m.source_id LIMIT 100
          """,
          [Store.workspace(), auth.corpus_id, after_id]
        ).rows

      deps =
        Enum.map(rows, fn [s, r, h] ->
          %{
            "dependency_key" => "source_revision:" <> r,
            "kind" => "source_revision",
            "source_id" => s,
            "revision_id" => r,
            "content_hash" => h,
            "role" => "uncited",
            "episode_binding_id" => nil,
            "derivative_version_id" => nil,
            "parent_manifest_id" => nil,
            "projection_id" => nil,
            "projection_hash" => nil
          }
        end)

      if rows != [] and status["next_ordinal"] + length(rows) <= count do
        GraphManifests.append_page(
          id,
          %{
            "page_index" => status["next_page_index"],
            "first_ordinal" => status["next_ordinal"],
            "previous_page_digest" => previous,
            "final" => status["next_ordinal"] + length(rows) == count,
            "rows" => deps
          },
          auth
        )
      else
        {:error, :closure_incomplete}
      end
    end
  end

  def qualified_runtime do
    with %{"qualified" => true, "bundle" => stored, "qualification_ref" => ref} <-
           Application.get_env(:harness_forge, :graph_runtime_authority),
         true <- Stages.identifier?(ref),
         {:ok, actual} <- runtime_bundle(Map.take(stored, @runtime_keys)),
         true <- stored == actual do
      {:ok, actual}
    else
      _ -> {:error, :graph_unavailable}
    end
  end

  defp file_pins do
    Enum.reduce_while(@worker_files, {:ok, %{}}, fn name, {:ok, acc} ->
      case File.read(Application.app_dir(:harness_forge, "priv/graphiti_worker/" <> name)) do
        {:ok, bytes} -> {:cont, {:ok, Map.put(acc, name, Store.hash(bytes))}}
        _ -> {:halt, {:error, :stage_unavailable}}
      end
    end)
  end

  defp image?("sha256:" <> hash), do: Stages.digest?(hash)
  defp image?(_), do: false

  defp guard(caller, fun) do
    HarnessForge.Privacy.Purge.synchronize(fn ->
      Store.transaction(fn ->
        with :ok <- AssessmentAttempts.options(caller),
             :ok <- AssessmentAttempts.authorize(caller),
             :ok <- Workspaces.ensure_writable(),
             :ok <- HarnessForge.Privacy.Purge.ready(),
             do: fun.()
      end)
    end)
  end
end
