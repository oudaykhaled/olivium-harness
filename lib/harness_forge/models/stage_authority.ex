defmodule HarnessForge.Models.StageAuthority do
  @moduledoc "Server-owned stage pins, exact-revision grants and per-actual-send reservations."
  import Ecto.Query
  alias HarnessForge.{Contracts, Repo, Workspaces}
  alias HarnessForge.Evidence.{Store, OriginV2, SourceUseContext, LocalUsePolicies}
  alias HarnessForge.Company.AssessmentAttempts

  alias HarnessForge.Models.{
    Configuration,
    Ledger,
    StageConfig,
    StageConsent,
    StageAttempt,
    StageControl,
    Stages
  }

  @enforce_keys [
    :workspace_id,
    :operation_id,
    :scope_ref,
    :manifest_id,
    :manifest_digest,
    :stage_pins,
    :semantic_generation,
    :authorization_generation,
    :cancel_epoch,
    :deadline_at,
    :caller
  ]
  defstruct @enforce_keys ++
              [
                source_context: nil,
                allowed_payloads: %{},
                control_token: nil,
                launch_token: nil,
                partition_id: nil,
                lease_id: nil,
                worker_session_id: nil,
                corpus_id: nil,
                operation_type: "synthesis",
                partition_lock_version: nil,
                source_lock_digest: nil,
                backend_pin_digest: nil,
                authorization_id: nil,
                budget_id: nil,
                operation_binding_digest: nil
              ]

  # Explicit operator action. Snapshotting never changes the singleton v1 settings.
  def create_pin(pin, caller) do
    HarnessForge.Privacy.Purge.synchronize(fn ->
      Store.transaction(fn ->
        with :ok <- authorize(caller),
             {:ok, pin} <- Stages.validate_pin(pin),
             true <- Contracts.digest(Map.delete(pin, "config_digest")) == pin["config_digest"],
             true <- HarnessForge.Models.CompanyAnalysis.uuid?(pin["id"]),
             true <-
               pin["provider"] == "ollama" or (pin["input_rate"] > 0 and pin["output_rate"] > 0),
             true <-
               pin["provider"] != "ollama" or
                 not String.contains?(String.downcase(pin["model"]), "cloud"),
             {:ok, row} <-
               Repo.insert(%StageConfig{
                 id: pin["id"],
                 workspace_id: Store.workspace(),
                 stage: pin["stage"],
                 payload_json: Contracts.canonical_json(pin),
                 config_hash: pin["config_digest"],
                 inserted_at: Store.now()
               }) do
          {:ok, Store.dto(row) |> Map.delete("payload_json")}
        else
          false -> {:error, :invalid_input}
          e -> e
        end
      end)
    end)
  end

  @doc "Prepare an immutable synthesis pin and displayable consent scope; no inference is sent."
  def prepare_synthesis(run_id, run_digest, caller), do: prepare_synthesis(run_id, run_digest, caller, nil)

  def prepare_synthesis(run_id, run_digest, caller, source_context) do
    with {:ok, pack} <- OriginV2.seal_retrieval(run_id, run_digest, caller, nil, source_context),
         config = Configuration.get(),
         true <- is_binary(config["model"]),
         {:ok, endpoint} <- synthesis_endpoint(config),
         attrs = %{
           "id" => Ecto.UUID.generate(),
           "stage" => "synthesis",
           "provider" => config["provider"],
           "model" => config["model"],
           "endpoint" => endpoint,
           "route_id" => "company_synthesis_v2",
           "credential_ref" => config["credential_env"],
           "prompt_digest" => Store.hash(HarnessForge.Models.CompanyAnalysis.system()),
           "schema_digest" => Contracts.digest(HarnessForge.Models.CompanyAnalysis.schema()),
           "consent_revision" => 1,
           "input_rate" => config["input_microusd_per_million"],
           "output_rate" => config["output_microusd_per_million"],
           "max_output_tokens" => 4096,
           "timeout_ms" => 60000
         },
         pin = Map.put(attrs, "config_digest", Stages.fingerprint(attrs)),
         {:ok, _} <- create_pin(pin, caller) do
      {:ok,
       %{
         "stage_id" => pin["id"],
         "provider" => pin["provider"],
         "model" => pin["model"],
         "endpoint" => pin["endpoint"],
         "input_rate" => pin["input_rate"],
         "output_rate" => pin["output_rate"],
         "manifest_id" => pack["origin_context"]["manifest_id"],
         "manifest_digest" => pack["origin_context"]["manifest_digest"],
         "passage_count" => length(pack["passages"]),
         "source_count" =>
           pack["manifest"]["dependencies"] |> Enum.uniq_by(& &1["source_id"]) |> length()
       }}
    else
      false -> {:error, :stage_unavailable}
      e -> e
    end
  end

  def prepare_setup_synthesis(operation_ref, retrieval_ref, caller),
    do: prepare_setup_synthesis(operation_ref, retrieval_ref, caller, nil)

  def prepare_setup_synthesis(operation_ref, retrieval_ref, caller, source_context),
    do:
      HarnessForge.Models.RunAuthorization.prepare_setup_synthesis(
        operation_ref,
        retrieval_ref,
        caller, source_context
      )

  defp synthesis_endpoint(config) do
    with {:ok, base} <- Configuration.endpoint(config["provider"], config["endpoint"]) do
      path =
        case config["provider"] do
          "ollama" -> "/api/generate"
          "openai" -> "/chat/completions"
          "openai_responses" -> "/responses"
          "anthropic" -> "/messages"
        end

      {:ok, base <> path}
    end
  end

  # One explicit reviewed snapshot grants only the current immutable manifest.
  # This server action pages every source; no browser source array is accepted.
  def grant_consent(stage_id, manifest_id, manifest_digest, caller), do: grant_consent(stage_id, manifest_id, manifest_digest, caller, nil)

  def grant_consent(stage_id, manifest_id, manifest_digest, caller, source_context) do
    HarnessForge.Privacy.Purge.synchronize(fn ->
      Store.transaction(fn ->
        with :ok <- authorize(caller),
             :ok <- HarnessForge.Models.RunAuthorization.setup_consent_allowed(stage_id),
             {:ok, _} <- load_pin(stage_id),
             {:ok, m} <- OriginV2.manifest(manifest_id, manifest_digest, "analysis", source_context) do
          revision =
            (Repo.one(
               from c in Store.scoped(StageConsent),
                 where: c.stage_config_id == ^stage_id,
                 select: max(c.revision)
             ) || 0) + 1

          with {:ok, c} <-
                 Repo.insert(%StageConsent{
                   workspace_id: Store.workspace(),
                   stage_config_id: stage_id,
                   revision: revision,
                   state: "active",
                   inserted_at: Store.now()
                 }),
               :ok <- consent_pages(c.id, m["id"], -1) do
            {:ok, Store.dto(c)}
          end
        end
      end)
    end)
  end

  defp consent_pages(consent, manifest, after_n) do
    with {:ok, %{rows: rows}} <-
           Repo.query(
             "SELECT ordinal,source_id,revision_id,content_hash FROM origin_dependencies WHERE workspace_id=? AND manifest_id=? AND kind='source_revision' AND ordinal>? ORDER BY ordinal LIMIT 100",
             [Store.workspace(), manifest, after_n]
           ),
         :ok <-
           Enum.reduce_while(rows, :ok, fn [_, s, r, h], :ok ->
             result =
               Enum.reduce_while(~w(source_body company_context), :ok, fn cat, :ok ->
                 case Repo.query(
                        "INSERT INTO stage_consent_sources(workspace_id,consent_id,source_id,revision_id,body_hash,category) VALUES(?,?,?,?,?,?)",
                        [Store.workspace(), consent, s, r, h, cat]
                      ) do
                   {:ok, _} -> {:cont, :ok}
                   _ -> {:halt, {:error, :consent_required}}
                 end
               end)

             case result do
               :ok -> {:cont, :ok}
               e -> {:halt, e}
             end
           end) do
      case rows do
        [] -> :ok
        _ -> consent_pages(consent, manifest, rows |> List.last() |> hd())
      end
    end
  end

  def new(operation_id, manifest_id, digest, stage_ids, caller), do: new(operation_id, manifest_id, digest, stage_ids, caller, nil)

  def new(operation_id, manifest_id, digest, stage_ids, caller, source_context) do
    with :ok <- authorize(caller),
         :ok <- interactive_context(source_context, caller),
         :ok <- HarnessForge.Models.RunAuthorization.legacy_allowed(operation_id, stage_ids),
         true <- Ledger.identifier?(operation_id),
         true <- is_list(stage_ids) and length(stage_ids) in 1..7,
         {:ok, m} <- OriginV2.manifest(manifest_id, digest, "analysis", source_context),
         {:ok, pins} <- collect(stage_ids, &load_pin/1),
         {:ok, _} <- Stages.set_digest(pins),
         {:ok, _} <- Ledger.start_run(operation_id) do
      StageControl.open(%__MODULE__{
        workspace_id: Store.workspace(),
        operation_id: operation_id,
        scope_ref:
          "hf_" <>
            String.replace(Store.workspace(), "-", "") <>
            "_" <> String.replace(m["corpus_id"], "-", ""),
        manifest_id: manifest_id,
        manifest_digest: digest,
        corpus_id: m["corpus_id"],
        stage_pins: pins,
        semantic_generation: m["semantic_generation"],
        authorization_generation: m["authorization_generation"],
        cancel_epoch: 0,
        deadline_at: DateTime.add(Store.now(), 60, :second),
        caller: caller,
        source_context: source_context
      })
    else
      false -> {:error, :invalid_input}
      e -> e
    end
  end

  def new_for_run(operation_id, manifest_ref, stage_ids, authorization_ref, caller), do: new_for_run(operation_id, manifest_ref, stage_ids, authorization_ref, caller, nil)

  def new_for_run(operation_id, manifest_ref, stage_ids, authorization_ref, caller, source_context) do
    HarnessForge.Privacy.Purge.synchronize(fn ->
      Store.transaction(fn ->
        with :ok <- authorize(caller),
             {:ok, binding} <-
               HarnessForge.Company.SetupRuns.operation_binding(operation_id, caller),
             {:ok, source_context} <- bind_source_context(source_context, binding["operation_ref"], authorization_ref, caller),
             {:ok, run} <-
               HarnessForge.Models.RunAuthorization.current(
                 authorization_ref,
                 binding["operation_ref"],
                 caller, source_context
               ),
             true <- manifest_ref == run["manifest_ref"] and stage_ids == [run["stage_ref"]["id"]],
             {:ok, manifest} <- OriginV2.manifest(manifest_ref["id"], manifest_ref["digest"], "analysis", source_context),
             {:ok, pin} <- load_pin(hd(stage_ids)),
             true <- pin["config_digest"] == run["stage_ref"]["digest"],
             {:ok, deadline, _} <- DateTime.from_iso8601(run["expires_at"]) do
          StageControl.open(%__MODULE__{
            workspace_id: Store.workspace(),
            operation_id: operation_id,
            scope_ref:
              "hf_" <>
                String.replace(Store.workspace(), "-", "") <>
                "_" <> String.replace(manifest["corpus_id"], "-", ""),
            manifest_id: manifest_ref["id"],
            manifest_digest: manifest_ref["digest"],
            corpus_id: manifest["corpus_id"],
            stage_pins: [pin],
            semantic_generation: manifest["semantic_generation"],
            authorization_generation: manifest["authorization_generation"],
            cancel_epoch: 0,
            deadline_at: deadline,
            caller: caller,
            source_context: source_context,
            authorization_id: authorization_ref["id"],
            budget_id: run["budget_id"],
            operation_binding_digest: binding["operation_ref"]["digest"]
          })
        else
          false -> HarnessForge.Models.RunAuthorization.error("stale_preparation")
          failure -> HarnessForge.Models.RunAuthorization.normalize(failure)
        end
      end)
    end)
  end

  @doc false
  def new_graph(operation_id, type, partition_id, stage_ids, session_id, caller) do
    HarnessForge.Privacy.Purge.synchronize(fn ->
      Store.transaction(fn ->
        with :ok <- authorize(caller),
             :ok <- HarnessForge.Models.RunAuthorization.legacy_allowed(operation_id, stage_ids),
             true <-
               type in ~w(ingest search remove) and Ledger.identifier?(operation_id) and
                 Stages.identifier?(session_id) and
                 HarnessForge.Evidence.Corpora.uuid?(partition_id),
             true <- is_list(stage_ids) and length(stage_ids) in 1..7,
             {:ok, pins} <- collect(stage_ids, &load_pin/1),
             {:ok, _} <- Stages.set_digest(pins),
             {:ok, bundle} <- HarnessForge.Evidence.GraphSources.runtime_for(partition_id),
             {:ok,
              %{
                rows: [
                  [
                    corpus,
                    group,
                    sem,
                    access,
                    epoch,
                    state,
                    lock,
                    source,
                    backend,
                    manifest,
                    digest
                  ]
                ]
              }} <-
               Repo.query(
                 """
                 SELECT p.corpus_id,p.group_id,p.semantic_generation,p.authorization_generation,
                        p.cancel_epoch,p.state,p.lock_version,p.source_lock_digest,p.backend_pin_digest,
                        p.manifest_id,m.digest
                 FROM graph_partition_controls p LEFT JOIN dependency_manifests m
                   ON m.workspace_id=p.workspace_id AND m.id=p.manifest_id AND m.state='sealed'
                 JOIN graph_source_scans s ON s.workspace_id=p.workspace_id AND s.partition_id=p.id AND s.state='complete'
                 WHERE p.workspace_id=? AND p.id=? AND NOT EXISTS(
                   SELECT 1 FROM stage_operations o WHERE o.workspace_id=p.workspace_id AND o.partition_id=p.id AND o.state='active')
                 """,
                 [Store.workspace(), partition_id]
               ),
             true <- Stages.digest?(source) and backend == Contracts.digest(bundle),
             true <- state == "ready" or (state == "staging" and type != "search"),
             true <- is_nil(manifest) == is_nil(digest),
             :ok <- HarnessForge.Evidence.Corpora.assert_current(corpus, sem, access),
             {:ok, _} <- Ledger.start_run(operation_id) do
          lock = if state == "ready" and type != "search", do: lock + 1, else: lock

          if type != "search" do
            Repo.query!(
              "UPDATE graph_partition_controls SET state='staging',lock_version=?,updated_at=? WHERE workspace_id=? AND id=?",
              [lock, DateTime.to_iso8601(Store.now()), Store.workspace(), partition_id]
            )
          end

          with {:ok, auth} <-
                 StageControl.open(%__MODULE__{
                   workspace_id: Store.workspace(),
                   operation_id: operation_id,
                   scope_ref: group,
                   manifest_id: manifest,
                   manifest_digest: digest,
                   stage_pins: pins,
                   corpus_id: corpus,
                   semantic_generation: sem,
                   authorization_generation: access,
                   cancel_epoch: epoch,
                   deadline_at: DateTime.add(Store.now(), 60, :second),
                   caller: caller,
                   operation_type: type,
                   partition_id: partition_id,
                   lease_id: Ecto.UUID.generate(),
                   worker_session_id: session_id,
                   partition_lock_version: lock,
                   source_lock_digest: source,
                   backend_pin_digest: backend
                 }) do
            if is_nil(manifest) do
              {:ok, auth}
            else
              with {:ok, _} <-
                     HarnessForge.Evidence.GraphManifests.validate_scope_certificate(
                       manifest,
                       digest,
                       auth
                     ),
                   do: {:ok, auth}
            end
          end
        else
          {:error, _} = error -> error
          _ -> {:error, :graph_unavailable}
        end
      end)
    end)
  end

  def bind_graph_manifest(auth, id, digest),
    do: StageControl.bind_graph_manifest(auth, id, digest)

  @doc false
  def bind_synthesis_payload(%__MODULE__{} = auth, stage_id, body) when is_binary(body) do
    with :ok <- current(auth),
         {:ok, pin} <- load_pin(stage_id),
         true <- pin["stage"] == "synthesis" and Enum.any?(auth.stage_pins, &(&1 == pin)),
         :ok <- setup_payload(auth, stage_id, body),
         true <- byte_size(body) <= 98_304 do
      {:ok, %{auth | allowed_payloads: %{Store.hash(body) => stage_id}}}
    else
      _ -> {:error, :stage_unavailable}
    end
  end

  @doc false
  def retrieval_job(scope, plan, caller) when is_map(scope) and is_map(plan) do
    captured =
      HarnessForge.Evidence.Corpora.guard(caller, fn ->
        with :ok <- retrieval_scope_current(scope),
             query when is_binary(query) <- plan["question"],
             true <-
               String.valid?(query) and byte_size(query) in 1..1024 and
                 String.length(query) <= 256 and String.trim(query) != "",
             {:ok, %{rows: [[partition]]}} <-
               Repo.query(
                 "SELECT id FROM graph_partition_controls WHERE workspace_id=? AND corpus_id=? AND semantic_generation=? AND authorization_generation=? AND state='ready' AND inventory_revision>0 ORDER BY updated_at DESC,id DESC LIMIT 1",
                 [
                   Store.workspace(),
                   scope["corpus_id"],
                   scope["semantic_generation"],
                   scope["authorization_generation"]
                 ]
               ),
             {:ok, configuration} <-
               HarnessForge.Evidence.GraphManifests.inventory_configuration(partition, caller),
             do: {:ok, {partition, configuration}},
             else: (_ -> {:error, :graph_unavailable})
      end)

    with {:ok, {partition, configuration}} <- captured,
         {:ok, session} <-
           HarnessForge.Graphiti.Runtime.launch(partition, configuration["stage_pin_ids"], caller) do
      case new_graph(
             Ecto.UUID.generate(),
             "search",
             partition,
             configuration["stage_pin_ids"],
             session,
             caller
           ) do
        {:ok, unbound} ->
          outcome =
            with {:ok, auth} <- HarnessForge.Graphiti.Runtime.bind_operation(unbound),
                 {:ok, pins} <-
                   HarnessForge.Evidence.GraphManifests.inventory_stage_pins(
                     configuration["base_inventory"],
                     auth
                   ),
                 true <- pins == Map.delete(configuration, "base_inventory"),
                 {:ok, base} <- HarnessForge.Graphiti.Runtime.prepare_search(auth),
                 true <- base == configuration["base_inventory"],
                 :ok <-
                   HarnessForge.Evidence.Corpora.guard(caller, fn ->
                     with :ok <- retrieval_scope_current(scope), do: {:ok, :current}
                   end)
                   |> current_scope_result(),
                 remaining =
                   min(60_000, DateTime.diff(auth.deadline_at, Store.now(), :millisecond)),
                 true <- remaining > 0,
                 job = %{
                   "op" => "search",
                   "job_id" => auth.operation_id,
                   "idempotency_key" => auth.operation_id,
                   "scope_ref" => auth.scope_ref,
                   "semantic_generation" => auth.semantic_generation,
                   "authorization_generation" => auth.authorization_generation,
                   "cancel_epoch" => auth.cancel_epoch,
                   "closure_ref" => auth.manifest_id,
                   "closure_digest" => auth.manifest_digest,
                   "stage_set_digest" => stage_set_digest(auth),
                   "partition_id" => auth.partition_id,
                   "lease_id" => auth.lease_id,
                   "worker_session_id" => auth.worker_session_id,
                   "deadline_ms" => remaining,
                   "args" => %{
                     "query" => plan["question"],
                     "limit" => 10,
                     "recipe_id" => "edge_hybrid_rrf_v1"
                   }
                 },
                 :ok <- HarnessForge.Graphiti.Protocol.validate_payload("job", job),
                 {:ok, _} <- HarnessForge.Graphiti.SearchIntent.prepare(auth, job, scope),
                 do: {:ok, job, auth},
                 else: (_ -> {:error, :closure_incomplete})

          if not match?({:ok, _, _}, outcome) do
            StageControl.cancel(unbound)
            HarnessForge.Graphiti.Runtime.stop(partition, caller)
          end

          outcome

        error ->
          HarnessForge.Graphiti.Runtime.stop(partition, caller)
          error
      end
    end
  end

  def retrieval_job(_, _, _), do: {:error, :invalid_scope}

  defp current_scope_result({:ok, :current}), do: :ok
  defp current_scope_result(_), do: {:error, :stale_generation}

  defp retrieval_scope_current(scope) do
    alias HarnessForge.Evidence.Corpora

    with :ok <-
           Corpora.assert_current(
             scope["corpus_id"],
             scope["semantic_generation"],
             scope["authorization_generation"]
           ),
         {:ok, project} <- Store.get(HarnessForge.Company.Project, scope["project_id"]),
         %HarnessForge.Company.Profile{} = profile <-
           Repo.one(Store.scoped(HarnessForge.Company.Profile)),
         {:ok, goal} <- Store.get(HarnessForge.Evidence.Goal, scope["goal_id"]),
         true <- HarnessForge.Goals.content_hash(goal) == scope["goal_hash"],
         true <-
           Map.take(scope["project"], ~w(id content_hash)) == %{
             "id" => project.id,
             "content_hash" => project.content_hash
           },
         true <-
           Map.take(scope["profile"], ~w(id content_hash)) == %{
             "id" => profile.id,
             "content_hash" => profile.content_hash
           },
         true <- goal.id in Enum.uniq(profile.payload["goal_ids"] ++ project.payload["goal_ids"]),
         {:ok, %{rows: [[1]]}} <-
           Repo.query(
             "SELECT 1 FROM company_corpus_bindings WHERE workspace_id=? AND project_id=? AND profile_id=? AND corpus_id=?",
             [Store.workspace(), project.id, profile.id, scope["corpus_id"]]
           ),
         do: :ok,
         else: (_ -> {:error, :invalid_scope})
  rescue
    _ -> {:error, :invalid_scope}
  end

  @doc false
  def retrieval_job(scope, _query_plan) when is_map(scope) do
    with :ok <-
           HarnessForge.Evidence.Corpora.assert_current(
             scope["corpus_id"],
             scope["semantic_generation"],
             scope["authorization_generation"]
           ),
         {:ok, %{rows: rows}} <-
           Repo.query(
             "SELECT id,manifest_id FROM graph_partition_controls WHERE workspace_id=? AND corpus_id=? AND semantic_generation=? AND authorization_generation=? AND state='ready' LIMIT 1",
             [
               Store.workspace(),
               scope["corpus_id"],
               scope["semantic_generation"],
               scope["authorization_generation"]
             ]
           ) do
      # A backend partition is usable only after actual graph value/version inventory
      # qualification. No speculative ancestry or silent lexical fallback is admitted.
      case rows do
        [] -> {:error, :graph_unavailable}
        _ -> {:error, :closure_incomplete}
      end
    end
  end

  def retrieval_job(_, _), do: {:error, :invalid_scope}

  def load_pin(id) do
    with {:ok, row} <- Store.get(StageConfig, id),
         {:ok, pin} <- Jason.decode(row.payload_json),
         {:ok, pin} <- Stages.validate_pin(pin),
         true <- pin["id"] == row.id and pin["config_digest"] == row.config_hash,
         true <- Contracts.digest(Map.delete(pin, "config_digest")) == row.config_hash do
      {:ok, pin}
    else
      _ -> {:error, :stage_unavailable}
    end
  end

  def authorize_consent(pin, consent_id, manifest) do
    with {:ok, c} <- Store.get(StageConsent, consent_id),
         true <-
           c.stage_config_id == pin["id"] and c.state == "active" and
             c.revision == pin["consent_revision"],
         {:ok, %{rows: [[0]]}} <-
           Repo.query(
             """
             SELECT count(*) FROM origin_dependencies d
             WHERE d.workspace_id=? AND d.manifest_id=? AND d.kind='source_revision' AND (
               NOT EXISTS(SELECT 1 FROM stage_consent_sources c WHERE c.workspace_id=d.workspace_id AND c.consent_id=? AND c.source_id=d.source_id AND c.revision_id=d.revision_id AND c.body_hash=d.content_hash AND c.category='source_body') OR
               NOT EXISTS(SELECT 1 FROM stage_consent_sources c WHERE c.workspace_id=d.workspace_id AND c.consent_id=? AND c.source_id=d.source_id AND c.revision_id=d.revision_id AND c.body_hash=d.content_hash AND c.category='company_context'))
             """,
             [Store.workspace(), manifest["id"], consent_id, consent_id]
           ) do
      :ok
    else
      _ -> {:error, :consent_required}
    end
  end

  def admit_attempt(%{"attempt" => a, "authority" => %__MODULE__{} = auth, "grant" => nil}) do
    # The projection is taken before obtaining SQL/privacy locks. The durable
    # single-use binding is consumed only in the reservation transaction below.
    case measured_projection(auth, a) do
      {:ok, projection} -> admit(a, auth, projection)
      error -> error
    end
  end

  def admit_attempt(_), do: {:error, :scope_denied}

  defp admit(a, auth, projection) do
    HarnessForge.Privacy.Purge.synchronize(fn ->
      Store.transaction(fn ->
        with :ok <- current(auth),
             :ok <- valid_attempt(a, auth),
             {:ok, pin} <- load_pin(a["stage_id"]),
             true <- Enum.any?(auth.stage_pins, &(&1 == pin)),
             :ok <- payload_authority(auth, a, pin, projection),
             {:ok, consent} <- consent_for(pin),
             :ok <- attempt_consent(auth, pin, consent.id),
             :ok <- predecessor(a, auth),
             false <-
               Repo.exists?(
                 from s in Store.scoped(StageAttempt),
                   where: s.state in ["reserved", "dispatched"]
               ),
             {:ok, reservation} <- Ledger.reserve_stage_attempt(a, pin, auth.operation_id) do
          grant_id = Ecto.UUID.generate()

          expiry =
            DateTime.add(Store.now(), min(a["timeout_ms"], pin["timeout_ms"]), :millisecond)

          grant = %{
            "attempt_id" => a["attempt_id"],
            "grant_id" => grant_id,
            "payload_sha256" => a["payload_sha256"],
            "expires_at" => DateTime.to_iso8601(expiry),
            "cancel_epoch" => auth.cancel_epoch
          }

          row = %StageAttempt{
            id: a["attempt_id"],
            workspace_id: auth.workspace_id,
            operation_id: auth.operation_id,
            logical_call_id: a["logical_call_id"],
            ordinal: a["ordinal"],
            predecessor_attempt_id: a["predecessor_attempt_id"],
            stage_config_id: pin["id"],
            consent_id: consent.id,
            model_request_id: reservation["id"],
            worker_request_id: a["attempt_id"],
            payload_hash: a["payload_sha256"],
            manifest_id: a["context_manifest_ref"],
            semantic_generation: auth.semantic_generation,
            authorization_generation: auth.authorization_generation,
            cancel_epoch: auth.cancel_epoch,
            grant_hash: Contracts.digest(grant),
            deadline_at: expiry,
            state: "reserved",
            inserted_at: Store.now(),
            updated_at: Store.now()
          }

          with {:ok, _} <- Repo.insert(row),
               :ok <- consume_graph_binding(auth, a),
               do: {:ok, Map.merge(grant, %{"reservation" => reservation, "pin" => pin})}
        else
          true -> {:error, :budget_exhausted}
          false -> {:error, :stage_unavailable}
          {:error, %Ecto.Changeset{}} -> {:error, :invalid_dto}
          e -> e
        end
      end)
    end)
  rescue
    _ -> {:error, :invalid_dto}
  end

  def mark_dispatching(%{"attempt" => a, "authority" => %__MODULE__{} = auth, "grant" => g})
      when is_map(g) do
    HarnessForge.Privacy.Purge.synchronize(fn ->
      Store.transaction(fn ->
        with :ok <- current(auth),
             :ok <- valid_attempt(a, auth),
             {:ok, row} <- Store.get(StageAttempt, a["attempt_id"]),
             true <-
               row.state == "reserved" and valid_grant?(g, row) and
                 attempt_row_binding?(a, auth, row),
             {:ok, pin} <- load_pin(row.stage_config_id),
             :ok <- attempt_consent(auth, pin, row.consent_id),
             {:ok, credential} <-
               Configuration.credential(%{
                 "provider" => pin["provider"],
                 "credential_env" => pin["credential_ref"]
               }),
             {:ok, _} <-
               row
               |> Ecto.Changeset.change(state: "dispatched", updated_at: Store.now())
               |> Repo.update() do
          headers =
            case pin["provider"] do
              "ollama" ->
                [{"content-type", "application/json"}]

              "anthropic" ->
                [
                  {"content-type", "application/json"},
                  {"x-api-key", credential},
                  {"anthropic-version", "2023-06-01"}
                ]

              _ ->
                [{"content-type", "application/json"}, {"authorization", "Bearer " <> credential}]
            end

          {:ok,
           %{
             "url" => pin["endpoint"],
             "headers" => headers,
             "timeout_ms" => min(a["timeout_ms"], pin["timeout_ms"])
           }}
        else
          false -> {:error, :cancelled}
          e -> e
        end
      end)
    end)
  end

  def mark_dispatching(_), do: {:error, :scope_denied}

  def finish_attempt(
        %{"attempt" => a, "authority" => %__MODULE__{} = auth, "grant" => g},
        outcome
      )
      when is_map(g) do
    # Usage settlement survives stale/cancelled publication; it cannot send another call.
    Store.transaction(fn ->
      with true <- auth.workspace_id == Store.workspace(),
           {:ok, row} <- Store.get(StageAttempt, a["attempt_id"]),
           true <-
             row.state in ["reserved", "dispatched"] and valid_grant_identity?(g, row) and
               attempt_row_binding?(a, auth, row),
           {:ok, pin} <- load_pin(row.stage_config_id),
           {:ok, reservation} <- Store.get(HarnessForge.Models.Request, row.model_request_id) do
        {status, body, usage, error} = safe_outcome(outcome, pin)

        config = %{
          "provider" => pin["provider"],
          "input_microusd_per_million" => pin["input_rate"],
          "output_microusd_per_million" => pin["output_rate"]
        }

        known = is_map(usage)
        reconciled = if known, do: {:ok, usage}, else: {:error, :provider_error}

        with {:ok, _} <- Ledger.reconcile(Store.dto(reservation), reconciled, config),
             {:ok, _} <-
               row
               |> Ecto.Changeset.change(
                 state: if(known, do: "completed", else: "uncertain"),
                 result_hash: if(is_binary(body), do: Store.hash(body)),
                 response_status: status,
                 response_bytes: if(is_binary(body), do: byte_size(body)),
                 error_code: error,
                 updated_at: Store.now()
               )
               |> Repo.update() do
          {:ok,
           %{
             "attempt_id" => a["attempt_id"],
             "receipt_id" => row.id,
             "state" => if(is_nil(error), do: "completed", else: "uncertain"),
             "http_status" => status,
             "body" => body,
             "body_sha256" => if(is_binary(body), do: Store.hash(body)),
             "usage_status" => if(known, do: "reported", else: "unknown"),
             "billing_status" =>
               if(known,
                 do: if(pin["provider"] == "ollama", do: "local_unpriced", else: "estimated"),
                 else: "unknown"
               ),
             "input_tokens" => (known && usage.input_tokens) || nil,
             "output_tokens" => (known && usage.output_tokens) || nil,
             "error_code" => error
           }}
        end
      else
        _ -> {:error, :invalid_dto}
      end
    end)
  end

  def finish_attempt(_, _), do: {:error, :scope_denied}

  def revalidate_job(%{"authority" => %__MODULE__{} = auth, "job" => nil}), do: current(auth)

  def revalidate_job(%{"authority" => %__MODULE__{} = auth, "job" => job}) when is_map(job) do
    with :ok <- HarnessForge.Graphiti.Protocol.validate_payload("job", job),
         true <-
           job["op"] == auth.operation_type and job["job_id"] == auth.operation_id and
             job["scope_ref"] == auth.scope_ref and
             job["closure_ref"] == auth.manifest_id and
             job["closure_digest"] == auth.manifest_digest and
             job["cancel_epoch"] == auth.cancel_epoch and
             job["semantic_generation"] == auth.semantic_generation and
             job["authorization_generation"] == auth.authorization_generation and
             job["partition_id"] == auth.partition_id and job["lease_id"] == auth.lease_id and
             job["worker_session_id"] == auth.worker_session_id and
             job["stage_set_digest"] == stage_set_digest(auth),
         :ok <- current(auth) do
      :ok
    else
      _ -> {:error, :scope_denied}
    end
  end

  def revalidate_job(_), do: {:error, :scope_denied}

  def publish_result(%{
        "authority" => %__MODULE__{operation_type: "ingest"} = auth,
        "job" => job,
        "result" => result
      })
      when is_map(job),
      do: HarnessForge.Graphiti.Completion.publish(auth, job, result)

  def publish_result(%{
        "authority" => %__MODULE__{operation_type: "search"} = auth,
        "job" => job,
        "result" => result
      })
      when is_map(job),
      do: HarnessForge.Graphiti.SearchCompletion.publish(auth, job, result)

  def publish_result(%{"authority" => %__MODULE__{}, "job" => job}) when is_map(job),
    do: {:error, :closure_incomplete}

  def publish_result(%{"authority" => %__MODULE__{} = auth, "result" => result}) do
    with :ok <- current(auth), true <- is_map(result), do: StageControl.complete(auth, result)
  end

  def publish_result(_), do: {:error, :scope_denied}

  def observe_context(%{"authority" => %__MODULE__{} = auth, "job" => job}, page) do
    with :ok <- HarnessForge.Graphiti.Runtime.begin_observation(auth, job, page) do
      outcome =
        try do
          HarnessForge.Graphiti.RootObserver.observe(auth, job, page)
        rescue
          _ -> {:error, :closure_incomplete}
        catch
          _, _ -> {:error, :closure_incomplete}
        end

      case HarnessForge.Graphiti.Runtime.end_observation(auth, job, page, outcome) do
        :ok -> outcome
        _ -> {:error, :closure_incomplete}
      end
    else
      _ -> {:error, :closure_incomplete}
    end
  end

  def observe_context(_, _), do: {:error, :closure_incomplete}

  def stage_set_digest(%__MODULE__{} = auth) do
    {:ok, digest} = Stages.set_digest(auth.stage_pins)
    digest
  end

  def cancel(%__MODULE__{} = auth) do
    HarnessForge.Privacy.Purge.synchronize(fn ->
      # Cancellation grants no provider/graph access and must remain possible
      # after a privacy fence, generation change or operation deadline.
      with true <- auth.workspace_id == Store.workspace(),
           :ok <- AssessmentAttempts.options(auth.caller),
           :ok <- AssessmentAttempts.authorize(auth.caller),
           :ok <- Workspaces.ensure_writable() do
        result = StageControl.cancel(auth)

        if match?({:ok, _}, result) and not is_nil(auth.partition_id),
          do: HarnessForge.Graphiti.Runtime.forget_partition(auth.partition_id)

        result
      else
        _ -> {:error, :scope_denied}
      end
    end)
  end

  @doc false
  def bind_source_context(nil, _operation_ref, _authorization_ref, _caller), do: {:ok, nil}
  def bind_source_context(%SourceUseContext{kind: :interactive} = context, operation_ref, authorization_ref, caller) do
    with :ok <- SourceUseContext.match_caller(context, caller),
         do: SourceUseContext.setup_analysis(context, operation_ref, authorization_ref)
  end
  def bind_source_context(%SourceUseContext{kind: :setup_analysis} = context, operation_ref, authorization_ref, caller) do
    with true <- context.operation_ref == operation_ref and context.authorization_ref == authorization_ref,
         :ok <- SourceUseContext.match_caller(context, caller),
         {:ok, _} <- SourceUseContext.validate(context, "analysis"), do: {:ok, context},
         else: (_ -> {:error, :source_context_invalid})
  end
  def bind_source_context(_, _, _, _), do: {:error, :source_context_invalid}

  defp interactive_context(nil, _caller), do: :ok
  defp interactive_context(%SourceUseContext{kind: :interactive} = context, caller),
    do: SourceUseContext.match_caller(context, caller)
  defp interactive_context(_, _), do: {:error, :source_context_invalid}

  @doc "Check source authority from the live stage object; no credential is persisted."
  def assert_source_use(%__MODULE__{operation_type: type} = auth) when type in ~w(ingest search remove),
    do: LocalUsePolicies.assert_corpus_use(auth.corpus_id, "analysis", nil)
  def assert_source_use(%__MODULE__{operation_type: "synthesis"} = auth) do
    with :ok <- source_caller(auth),
         {:ok, manifest} <- OriginV2.manifest(auth.manifest_id, auth.manifest_digest, "analysis", auth.source_context),
         true <- manifest["corpus_id"] == auth.corpus_id and
                   manifest["semantic_generation"] == auth.semantic_generation and
                   manifest["authorization_generation"] == auth.authorization_generation,
         :ok <- exact_source_binding(auth), do: :ok,
         else: (_ -> {:error, :source_use_denied})
  end
  def assert_source_use(_), do: {:error, :source_context_invalid}

  defp source_caller(%{source_context: nil}), do: :ok
  defp source_caller(auth), do: SourceUseContext.match_caller(auth.source_context, auth.caller)

  defp exact_source_binding(%{authorization_id: nil, source_context: nil}), do: :ok
  defp exact_source_binding(%{authorization_id: nil} = auth), do: interactive_context(auth.source_context, auth.caller)
  defp exact_source_binding(%{source_context: nil}), do: :ok
  defp exact_source_binding(auth) do
    with %SourceUseContext{kind: :setup_analysis} = context <- auth.source_context,
         true <- context.operation_ref == %{"id" => auth.operation_id, "digest" => auth.operation_binding_digest},
         true <- context.authorization_ref["id"] == auth.authorization_id,
         {:ok, binding} <- HarnessForge.Models.RunAuthorization.source_use_binding(context.authorization_ref, context.operation_ref, auth.caller),
         true <- binding.manifest_ref == %{"id" => auth.manifest_id, "digest" => auth.manifest_digest} and
                   Enum.map(auth.stage_pins, &%{"id" => &1["id"], "digest" => &1["config_digest"]}) == [binding.stage_ref],
         do: :ok, else: (_ -> {:error, :source_context_invalid})
  end

  defp current(%__MODULE__{operation_type: type} = auth) when type in ~w(ingest search remove) do
    with :ok <- HarnessForge.Graphiti.Runtime.current(auth),
         {:ok, _} <- StageControl.graph_current(auth),
         {:ok, _} <-
           HarnessForge.Evidence.GraphManifests.validate_scope_certificate(
             auth.manifest_id,
             auth.manifest_digest,
             auth
           ),
         do: :ok
  end

  defp current(auth) do
    with true <-
           auth.workspace_id == Store.workspace() and is_binary(auth.scope_ref) and
             byte_size(auth.scope_ref) > 0,
         true <- DateTime.compare(Store.now(), auth.deadline_at) == :lt,
         :ok <- StageControl.current(auth),
         :ok <- authorize(auth.caller),
         :ok <- setup_current(auth),
         {:ok, m} <- OriginV2.manifest(auth.manifest_id, auth.manifest_digest, "analysis", auth.source_context),
         true <-
           m["semantic_generation"] == auth.semantic_generation and
             m["authorization_generation"] == auth.authorization_generation do
      :ok
    else
      _ -> {:error, :stale_generation}
    end
  end

  defp setup_current(%{authorization_id: nil} = auth),
    do:
      HarnessForge.Models.RunAuthorization.legacy_allowed(
        auth.operation_id,
        Enum.map(auth.stage_pins, & &1["id"])
      )

  defp setup_current(auth) do
    with {:ok, run} <-
           HarnessForge.Models.RunAuthorization.current(
             %{
               "id" => auth.authorization_id,
               "digest" => authorization_hash(auth.authorization_id)
             },
             %{"id" => auth.operation_id, "digest" => auth.operation_binding_digest},
             auth.caller, auth.source_context
           ),
         true <- run["budget_id"] == auth.budget_id,
         do: :ok,
         else: (_ -> {:error, :authorization_required})
  end

  defp authorization_hash(id) do
    case Store.get(HarnessForge.Models.RunAuthorizationRecord, id) do
      {:ok, row} -> row.digest
      _ -> nil
    end
  end

  defp valid_attempt(a, auth) do
    with true <- is_map(a) and is_binary(a["body"]) and byte_size(a["body"]) in 1..98_304,
         true <-
           a["payload_sha256"] == Store.hash(a["body"]) and a["job_id"] == auth.operation_id and
             a["cancel_epoch"] == auth.cancel_epoch,
         :ok <- attempt_context(auth, a),
         true <-
           is_integer(a["ordinal"]) and a["ordinal"] in 1..3 and is_integer(a["timeout_ms"]) and
             a["timeout_ms"] in 1..60_000,
         {:ok, pin} <- load_pin(a["stage_id"]),
         true <-
           a["stage_digest"] == pin["config_digest"] and a["route_id"] == pin["route_id"] and
             a["method"] == "POST" and a["max_output_tokens"] == pin["max_output_tokens"],
         {:ok, body} <- Jason.decode(a["body"]),
         true <- is_map(body) and body["model"] == pin["model"] do
      :ok
    else
      _ -> {:error, :invalid_dto}
    end
  end

  defp measured_projection(%__MODULE__{operation_type: type} = auth, attempt)
       when type in ~w(ingest search remove),
       do: HarnessForge.Graphiti.Runtime.take_projection(auth, attempt)

  defp measured_projection(_, _), do: {:ok, nil}

  # Query authority is the private registered intent, not corpus membership.
  # Enforce native newline normalization again before any provider admission.
  defp payload_authority(%__MODULE__{operation_type: "search"} = auth, attempt, pin, projection)
       when is_map(projection) do
    with query when is_binary(query) <- projection["search_query"],
         true <-
           byte_size(query) in 1..1024 and String.length(query) <= 256 and
             String.trim(query) != "",
         true <- pin["stage"] == "embedder" and projection["prompt_name"] == "embedder.create",
         true <- projection["values"] == [[String.replace(query, "\n", " ")]],
         true <- attempt["ordinal"] == 1 and is_nil(attempt["predecessor_attempt_id"]),
         {:ok, %{rows: [[0]]}} <-
           Repo.query(
             "SELECT count(*) FROM stage_attempts WHERE workspace_id=? AND operation_id=?",
             [Store.workspace(), auth.operation_id]
           ),
         :ok <-
           HarnessForge.Graphiti.SchemaPolicy.validate_body(
             pin,
             projection["prompt_name"],
             attempt["body"],
             projection["values"]
           ),
         do: :ok,
         else: (_ -> {:error, :scope_denied})
  end

  defp payload_authority(%__MODULE__{operation_type: type}, attempt, pin, projection)
       when type in ~w(ingest search remove) and is_map(projection) do
    HarnessForge.Graphiti.SchemaPolicy.validate_body(
      pin,
      projection["prompt_name"],
      attempt["body"],
      projection["values"]
    )
  end

  defp payload_authority(auth, attempt, pin, nil) do
    if auth.operation_type == "synthesis" and
         Map.get(auth.allowed_payloads, attempt["payload_sha256"]) == pin["id"],
       do: setup_payload(auth, pin["id"], attempt["body"]),
       else: {:error, :scope_denied}
  end

  defp payload_authority(_, _, _, _), do: {:error, :scope_denied}

  defp setup_payload(%{authorization_id: nil}, _, _), do: :ok

  defp setup_payload(auth, stage_id, body) do
    with {:ok, run} <-
           HarnessForge.Models.RunAuthorization.current(
             %{
               "id" => auth.authorization_id,
               "digest" => authorization_hash(auth.authorization_id)
             },
             %{"id" => auth.operation_id, "digest" => auth.operation_binding_digest},
             auth.caller, auth.source_context
           ),
         true <- run["stage_ref"]["id"] == stage_id,
         {:ok, prepared} <-
           HarnessForge.Models.RunAuthorization.preparation(run["prepared_ref"], auth.caller, auth.source_context),
         true <-
           body == prepared.request_body_bytes and
             Store.hash(body) == prepared.request_body_sha256,
         do: :ok,
         else: (_ -> {:error, :scope_denied})
  end

  defp attempt_context(%__MODULE__{operation_type: type} = auth, attempt)
       when type in ~w(ingest search remove) do
    with true <-
           attempt["closure_ref"] == auth.manifest_id and
             attempt["closure_digest"] == auth.manifest_digest,
         true <- attempt["context_manifest_ref"] != auth.manifest_id,
         {:ok, _} <-
           HarnessForge.Evidence.GraphManifests.validate_current(
             attempt["context_manifest_ref"],
             attempt["context_manifest_digest"],
             auth
           ),
         do: :ok,
         else: (_ -> {:error, :closure_incomplete})
  end

  defp attempt_context(auth, attempt) do
    if attempt["context_manifest_ref"] == auth.manifest_id and
         attempt["context_manifest_digest"] == auth.manifest_digest and
         attempt["closure_ref"] == auth.manifest_id and
         attempt["closure_digest"] == auth.manifest_digest, do: :ok, else: {:error, :scope_denied}
  end

  defp attempt_consent(%__MODULE__{operation_type: type} = auth, pin, consent_id)
       when type in ~w(ingest search remove) do
    with {:ok, _} <- HarnessForge.Models.GraphConsent.certificate_for(auth, pin, consent_id),
         do: :ok
  end

  defp attempt_consent(auth, pin, consent_id) do
    with {:ok, manifest} <- OriginV2.manifest(auth.manifest_id, auth.manifest_digest, "analysis", auth.source_context),
         do: Configuration.authorize_stage(pin, consent_id, manifest)
  end

  defp consume_graph_binding(%__MODULE__{operation_type: type} = auth, attempt)
       when type in ~w(ingest search remove),
       do: HarnessForge.Graphiti.ObservationLedger.consume_binding(auth, attempt)

  defp consume_graph_binding(_, _), do: :ok

  defp attempt_row_binding?(attempt, auth, row) do
    row.workspace_id == auth.workspace_id and row.operation_id == auth.operation_id and
      row.logical_call_id == attempt["logical_call_id"] and row.ordinal == attempt["ordinal"] and
      row.predecessor_attempt_id == attempt["predecessor_attempt_id"] and
      row.stage_config_id == attempt["stage_id"] and
      row.payload_hash == attempt["payload_sha256"] and
      row.manifest_id == attempt["context_manifest_ref"] and
      row.semantic_generation == auth.semantic_generation and
      row.authorization_generation == auth.authorization_generation and
      row.cancel_epoch == auth.cancel_epoch
  end

  defp consent_for(pin) do
    case Repo.one(
           from c in Store.scoped(StageConsent),
             where:
               c.stage_config_id == ^pin["id"] and c.revision == ^pin["consent_revision"] and
                 c.state == "active"
         ) do
      nil -> {:error, :consent_required}
      c -> {:ok, c}
    end
  end

  defp predecessor(%{"ordinal" => 1, "predecessor_attempt_id" => nil}, _auth), do: :ok

  defp predecessor(a, auth) do
    with {:ok, p} <- Store.get(StageAttempt, a["predecessor_attempt_id"]),
         true <-
           p.operation_id == auth.operation_id and p.logical_call_id == a["logical_call_id"] and
             p.ordinal + 1 == a["ordinal"] and p.state == "completed" do
      :ok
    else
      _ -> {:error, :reconcile_required}
    end
  end

  defp valid_grant?(g, row),
    do: valid_grant_identity?(g, row) and DateTime.compare(Store.now(), row.deadline_at) == :lt

  defp valid_grant_identity?(g, row),
    do:
      Contracts.digest(
        Map.take(g, ~w(attempt_id grant_id payload_sha256 expires_at cancel_epoch))
      ) == row.grant_hash and g["attempt_id"] == row.id and
        g["payload_sha256"] == row.payload_hash and g["cancel_epoch"] == row.cancel_epoch

  defp safe_outcome({:ok, %{"status" => status, "body" => body}}, pin)
       when is_integer(status) and is_binary(body) and byte_size(body) <= 98_304 do
    usage =
      case Jason.decode(body) do
        {:ok, %{"usage" => u}} ->
          reported_usage(u, pin)

        {:ok, %{"prompt_eval_count" => i, "eval_count" => o}} ->
          reported_usage(%{"input_tokens" => i, "output_tokens" => o}, pin)

        _ ->
          nil
      end

    {status, body, usage, nil}
  end

  defp safe_outcome(_, _), do: {nil, nil, nil, "provider_error"}

  @doc false
  def reported_usage(u, pin) when is_map(u) do
    i = u["input_tokens"] || u["prompt_tokens"]
    o = u["output_tokens"] || u["completion_tokens"]

    o =
      if is_nil(o) and pin["stage"] == "embedder" and
           String.ends_with?(pin["endpoint"] || "", "/embeddings") and
           u["total_tokens"] == i and is_integer(i), do: 0, else: o

    if is_integer(i) and i >= 0 and is_integer(o) and o >= 0,
      do: %{input_tokens: i, output_tokens: o},
      else: nil
  end

  def reported_usage(_, _), do: nil

  defp authorize(caller) do
    with :ok <- AssessmentAttempts.options(caller),
         :ok <- AssessmentAttempts.authorize(caller),
         :ok <- Workspaces.ensure_writable(),
         :ok <- HarnessForge.Privacy.Purge.ready(),
         do: :ok
  end

  defp collect(items, fun) do
    Enum.reduce_while(items, {:ok, []}, fn x, {:ok, acc} ->
      case fun.(x) do
        {:ok, v} -> {:cont, {:ok, acc ++ [v]}}
        e -> {:halt, e}
      end
    end)
  end
end
