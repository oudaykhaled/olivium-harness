defmodule HarnessForge.Models.RunAuthorization do
  @moduledoc "Exact, explicitly confirmed local setup synthesis authority over one durable run budget."
  import Ecto.Query
  alias HarnessForge.{Contracts, Repo, Workspaces}

  alias HarnessForge.Company.{
    AssessmentAttempts,
    SetupSession,
    SetupRun,
    SetupRunState,
    SetupRunConfig,
    SetupRunCommand,
    SetupRunOperation,
    SetupRunPreparation,
    SetupRuns
  }

  alias HarnessForge.Evidence.{Store, OriginV2, SourceUseContext}

  alias HarnessForge.Models.{
    Configuration,
    CompanyAnalysis,
    StageAuthority,
    Stages,
    StageConsent,
    Ledger,
    RunAuthorizationRecord,
    RunAuthorizationState,
    RunDisclosure
  }

  @limits %{
    "max_requests" => 2,
    "max_tokens" => 100_000,
    "max_cost_microusd" => 0,
    "deadline_seconds" => 300
  }
  @descriptor ~w(stage provider model endpoint route_id credential_ref prompt_digest schema_digest input_rate output_rate max_output_tokens timeout_ms)
  @scope ~w(profile_ref project_ref repository_ref goal_ref outcome_hash connection_id root_fingerprint history)
  @config_fields ~w(version profile_version profile_ref project_ref repository_ref goal_ref outcome_hash connection_id root_fingerprint history query_text descriptor capture_limits model_limits)

  def limits, do: @limits
  def error(code), do: {:error, %{"code" => code, "current" => nil}}
  def ref(record), do: %{"id" => record.id, "digest" => record.digest}

  def valid_ref?(value),
    do:
      is_map(value) and Enum.sort(Map.keys(value)) == ~w(digest id) and
        CompanyAnalysis.uuid?(value["id"]) and Stages.digest?(value["digest"])

  def descriptor do
    config = Configuration.get()

    with true <- config["provider"] == "ollama" and is_binary(config["model"]),
         true <- not String.contains?(String.downcase(config["model"]), "cloud"),
         true <-
           config["input_microusd_per_million"] == 0 and
             config["output_microusd_per_million"] == 0,
         {:ok, endpoint} <- Configuration.endpoint("ollama", config["endpoint"]) do
      {:ok,
       %{
         "stage" => "synthesis",
         "provider" => "ollama",
         "model" => config["model"],
         "endpoint" => endpoint <> "/api/generate",
         "route_id" => "company_synthesis_v2",
         "credential_ref" => config["credential_env"],
         "prompt_digest" => Store.hash(CompanyAnalysis.system()),
         "schema_digest" => Contracts.digest(CompanyAnalysis.schema()),
         "input_rate" => 0,
         "output_rate" => 0,
         "max_output_tokens" => 4096,
         "timeout_ms" => 60_000
       }}
    else
      _ ->
        error(
          if(is_nil(config["model"]), do: "model_unavailable", else: "unsupported_configuration")
        )
    end
  end

  def prepare_setup_synthesis(operation_ref, retrieval_ref, caller), do: prepare_setup_synthesis(operation_ref, retrieval_ref, caller, nil)

  def prepare_setup_synthesis(operation_ref, retrieval_ref, caller, source_context) do
    guarded(caller, fn ->
      with :ok <- context_caller(source_context, caller),
           true <- valid_ref?(operation_ref) and valid_ref?(retrieval_ref),
           {:ok, binding} <- SetupRuns.operation_binding(operation_ref["id"], caller),
           true <- binding["operation_ref"] == operation_ref and binding["kind"] == "retrieval",
           {:ok, config} <- owned(SetupRunConfig, binding["config_ref"], caller),
           {:ok, scope} <- config_scope(config),
           {:ok, pack} <-
             HarnessForge.Company.Retrieval.resolve_for_analysis(
               retrieval_ref["id"],
               retrieval_ref["digest"],
               caller, source_context
             ),
           :ok <- pack_scope(pack, scope),
           {:ok, current_descriptor} <- descriptor(),
           true <- current_descriptor == scope["descriptor"],
           context = %{
             "version" => 1,
             "scope" => Map.take(scope, @scope),
             "purpose" => "company_synthesis_v2",
             "descriptor" => current_descriptor
           },
           context_digest = Contracts.digest(context),
           {:ok, existing} <- existing_preparation(binding),
           {:ok, result} <-
             prepare_once(
               existing,
               binding,
               retrieval_ref,
               config,
               pack,
               context,
               context_digest,
               caller, source_context
             ) do
        {:ok, result}
      else
        false -> error("stale_preparation")
        failure -> normalize(failure)
      end
    end)
  end

  defp prepare_once(%SetupRunPreparation{} = row, binding, retrieval_ref, _, _, _, _, caller, source_context) do
    if row.operation_id == binding["operation_ref"]["id"] and row.retrieval_ref == retrieval_ref,
      do: prepared_view(ref(row), caller, source_context),
      else: error("stale_preparation")
  end

  defp prepare_once(nil, binding, retrieval_ref, config, pack, context, context_digest, caller, source_context) do
    with {:ok, pin} <- reusable_or_new_pin(config, context_digest, pack, caller),
         {:ok, final_pack} <-
           OriginV2.seal_retrieval(
             retrieval_ref["id"],
             retrieval_ref["digest"],
             caller,
             pin["id"], source_context
           ),
         {:ok, bytes} <- HarnessForge.Company.AnalysisV2.prepare_payload(final_pack, pin, source_context),
         row = %SetupRunPreparation{
           id: Ecto.UUID.generate(),
           workspace_id: Store.workspace(),
           owner_id: Workspaces.operator(),
           session_id: config.session_id,
           run_id: binding["run_ref"]["id"],
           config_id: config.id,
           operation_id: binding["operation_ref"]["id"],
           retrieval_ref: retrieval_ref,
           stage_ref: %{"id" => pin["id"], "digest" => pin["config_digest"]},
           manifest_ref: %{
             "id" => final_pack["origin_context"]["manifest_id"],
             "digest" => final_pack["origin_context"]["manifest_digest"]
           },
           context_digest: context_digest,
           context_json: context,
           checked_pack_json: final_pack,
           prompt_bytes: bytes["prompt_bytes"],
           prompt_sha256: bytes["prompt_sha256"],
           request_body_bytes: bytes["request_body_bytes"],
           request_body_sha256: bytes["request_body_sha256"]
         },
         row = %{row | digest: preparation_digest(row)},
         true <-
           byte_size(Contracts.canonical_json(final_pack)) + byte_size(row.prompt_bytes) +
             byte_size(row.request_body_bytes) <= 262_144,
         {:ok, stored} <- Repo.insert(row),
         {:ok, _} <- SetupRuns.operation_binding(binding["operation_ref"]["id"], caller),
         {:ok, view} <- prepared_view(ref(stored), caller, source_context) do
      {:ok, view}
    else
      false -> error("invalid_input")
      failure -> normalize(failure)
    end
  end

  defp reusable_or_new_pin(config, context_digest, pack, caller) do
    rows =
      Repo.all(
        from p in SetupRunPreparation,
          where:
            p.workspace_id == ^Store.workspace() and p.owner_id == ^Workspaces.operator() and
              p.session_id == ^config.session_id and p.context_digest == ^context_digest,
          order_by: [desc: p.inserted_at],
          select: p.stage_ref
      )

    prior =
      Enum.find_value(rows, fn stage_ref ->
        with {:ok, pin} <- StageAuthority.load_pin(stage_ref["id"]),
             true <- pin["config_digest"] == stage_ref["digest"],
             {:ok, consent} <- consent_for(pin),
             true <- owned_consent?(pin, consent, context_digest, config.session_id),
             true <- covered_pack?(consent.id, pack),
             do: pin,
             else: (_ -> nil)
      end)

    if prior do
      {:ok, prior}
    else
      attrs =
        config.scope_json["descriptor"]
        |> Map.put("id", Ecto.UUID.generate())
        |> Map.put("consent_revision", 1)

      pin = Map.put(attrs, "config_digest", Stages.fingerprint(attrs))
      with {:ok, _} <- StageAuthority.create_pin(pin, caller), do: {:ok, pin}
    end
  end

  defp covered_pack?(consent_id, pack) do
    Enum.all?(pack["manifest"]["dependencies"], fn dep ->
      Enum.all?(~w(source_body company_context), fn category ->
        match?(
          {:ok, %{rows: [[1]]}},
          Repo.query(
            "SELECT count(*) FROM stage_consent_sources WHERE workspace_id=? AND consent_id=? AND source_id=? AND revision_id=? AND body_hash=? AND category=?",
            [
              Store.workspace(),
              consent_id,
              dep["source_id"],
              dep["revision_id"],
              dep["body_hash"],
              category
            ]
          )
        )
      end)
    end)
  end

  def authorize(config_ref, prepared_ref, caller), do: authorize(config_ref, prepared_ref, caller, nil)

  def authorize(config_ref, prepared_ref, caller, source_context) do
    if Repo.in_transaction?() do
      with :ok <- authenticate(caller),
           {:ok, config} <- owned(SetupRunConfig, config_ref, caller),
           {:ok, prepared} <- preparation(prepared_ref, caller, source_context),
           true <- prepared.config_id == config.id,
           {:ok, run, state, command} <- accepted_authorize(config, prepared, caller),
           :ok <- validate_prepared(prepared, config, source_context),
           {:ok, existing} <- authorization_for(run.id),
           {:ok, result} <-
             authorize_once(existing, run, state, command, config, prepared, caller, source_context) do
        {:ok, result}
      else
        false -> error("stale_preparation")
        failure -> normalize(failure)
      end
    else
      error("authorization_required")
    end
  end

  defp authorize_once(%RunAuthorizationRecord{} = row, run, _, _, config, prepared, _caller, source_context) do
    with true <-
           row.run_id == run.id and row.config_id == config.id and
             row.preparation_id == prepared.id,
         {:ok, _} <- authorization_state(row),
         :ok <- authorization_current(row),
         {:ok, disclosure} <- disclosure_for(row),
         :ok <- disclosure_current(disclosure, prepared, source_context),
         {:ok, _} <- Ledger.start_authorized_run(row.budget_id, budget_limits()),
         do: {:ok, authorization_receipt(row, disclosure)},
         else: (
           false -> error("stale_preparation")
           failure -> normalize(failure)
         )
  end

  defp authorize_once(nil, run, _, command, config, prepared, caller, source_context) do
    with {:ok, pin} <- StageAuthority.load_pin(prepared.stage_ref["id"]),
         {:ok, manifest} <-
           OriginV2.manifest(prepared.manifest_ref["id"], prepared.manifest_ref["digest"], "analysis", source_context),
         {:ok, consent} <- existing_or_grant(pin, manifest, prepared, caller, source_context),
         :ok <- StageAuthority.authorize_consent(pin, consent.id, manifest),
         now = Store.now(),
         row = %RunAuthorizationRecord{
           id: Ecto.UUID.generate(),
           workspace_id: Store.workspace(),
           owner_id: Workspaces.operator(),
           session_id: run.session_id,
           run_id: run.id,
           config_id: config.id,
           preparation_id: prepared.id,
           scope_digest: prepared.context_digest,
           descriptor_json: config.scope_json["descriptor"],
           budget_id: Ecto.UUID.generate(),
           max_requests: 2,
           max_tokens: 100_000,
           max_cost_microusd: 0,
           authorized_at: now,
           expires_at: DateTime.add(now, 300, :second),
           command_id: command.command_id
         },
         row = %{row | digest: authorization_digest(row)},
         disclosure = %RunDisclosure{
           id: Ecto.UUID.generate(),
           workspace_id: Store.workspace(),
           owner_id: Workspaces.operator(),
           session_id: run.session_id,
           run_id: run.id,
           config_id: config.id,
           preparation_id: prepared.id,
           stage_ref: prepared.stage_ref,
           manifest_ref: prepared.manifest_ref,
           consent_id: consent.id,
           consent_revision: consent.revision,
           context_digest: prepared.context_digest,
           command_id: command.command_id
         },
         disclosure = %{disclosure | digest: disclosure_digest(disclosure)},
         {:ok, _} <- Repo.insert(disclosure),
         {:ok, row} <- Repo.insert(row),
         {:ok, _} <-
           Repo.insert(%RunAuthorizationState{
             workspace_id: Store.workspace(),
             owner_id: Workspaces.operator(),
             session_id: run.session_id,
             authorization_id: row.id
           }),
         {:ok, _} <- Ledger.start_authorized_run(row.budget_id, budget_limits()) do
      {:ok, authorization_receipt(row, disclosure)}
    else
      failure -> normalize(failure)
    end
  end

  defp existing_or_grant(pin, manifest, prepared, caller, source_context) do
    case consent_for(pin) do
      {:ok, consent} ->
        with true <- owned_consent?(pin, consent, prepared.context_digest, prepared.session_id),
             :ok <- StageAuthority.authorize_consent(pin, consent.id, manifest),
             do: {:ok, consent},
             else: (_ -> error("consent_required"))

      _ ->
        with {:ok, dto} <-
               StageAuthority.grant_consent(pin["id"], manifest["id"], manifest["digest"], caller, source_context),
             {:ok, consent} <- Store.get(StageConsent, dto["id"]),
             do: {:ok, consent}
    end
  end

  @doc "Reload exact setup authority metadata without hydrating prepared source text."
  def source_use_binding(authorization_ref, operation_ref, caller) do
    with :ok <- authenticate(caller),
         true <- valid_ref?(authorization_ref) and valid_ref?(operation_ref),
         {:ok, binding} <- SetupRuns.operation_binding(operation_ref["id"], caller),
         true <- binding["operation_ref"] == operation_ref and binding["kind"] == "analysis" and
                   binding["authorization_ref"] == authorization_ref,
         {:ok, row} <- owned(RunAuthorizationRecord, authorization_ref, caller),
         true <- row.run_id == binding["run_ref"]["id"] and row.config_id == binding["config_ref"]["id"] and
                   row.preparation_id == binding["prepared_ref"]["id"],
         {:ok, _} <- authorization_state(row),
         :ok <- authorization_current(row),
         {:ok, config} <- owned(SetupRunConfig, binding["config_ref"], caller),
         {:ok, prepared} <- preparation_metadata(binding["prepared_ref"], caller),
         true <- row.session_id == prepared.session_id and row.owner_id == prepared.owner_id and
                   row.scope_digest == prepared.context_digest and row.descriptor_json == config.scope_json["descriptor"],
         :ok <- prepared_metadata_current(prepared, config),
         :ok <- accepted_analysis_command(binding, prepared),
         {:ok, manifest} <- manifest_metadata(prepared),
         {:ok, disclosure} <- disclosure_for(row),
         :ok <- disclosure_metadata_current(disclosure, prepared),
         {:ok, budget} <- Ledger.budget(row.budget_id),
         true <- exact_budget?(budget) do
      {:ok, %{
        workspace_id: row.workspace_id, owner_id: row.owner_id, session_id: row.session_id,
        run_ref: binding["run_ref"], operation_ref: operation_ref, authorization_ref: ref(row),
        config_ref: ref(config), prepared_ref: ref(prepared), manifest_ref: prepared.manifest_ref,
        stage_ref: prepared.stage_ref, expires_at: DateTime.to_iso8601(row.expires_at),
        semantic_generation: manifest["semantic_generation"],
        authorization_generation: manifest["authorization_generation"]
      }}
    else
      false -> error("authorization_required")
      failure -> normalize(failure)
    end
  end

  defp preparation_metadata(reference, caller) do
    with :ok <- authenticate(caller), true <- valid_ref?(reference),
         {:ok, row} <- preparation_metadata_by_id(reference["id"]),
         true <- row.digest == reference["digest"], do: {:ok, row},
         else: (_ -> error("stale_preparation"))
  end

  defp preparation_metadata_by_id(id) do
    case Repo.one(from p in Store.scoped(SetupRunPreparation),
      where: p.id == ^id and p.owner_id == ^Workspaces.operator(),
      select: map(p, [:id, :digest, :workspace_id, :owner_id, :session_id, :run_id, :config_id,
        :operation_id, :retrieval_ref, :stage_ref, :manifest_ref, :context_digest, :context_json])) do
      nil -> error("stale_preparation")
      row -> {:ok, row}
    end
  end

  defp accepted_analysis_command(binding, prepared) do
    with command when not is_nil(command) <- Repo.one(from c in Store.scoped(SetupRunCommand),
           where: c.id == ^binding["command_ref"]["id"] and c.owner_id == ^Workspaces.operator()),
         true <- command.request_digest == binding["command_ref"]["digest"] and
                   command.request_digest == Contracts.digest(command.request_json),
         request = command.request_json, receipt = command.receipt_json,
         true <- request["action"] in ~w(analyze retry) and request["payload"] == %{"prepared_ref" => ref(prepared)},
         true <- command.run_id == prepared.run_id and command.session_id == prepared.session_id,
         true <- receipt["command_ref"] == binding["command_ref"] and receipt["run_ref"] == binding["run_ref"] and
                   receipt["operation_ref"] == binding["operation_ref"] and receipt["prepared_ref"] == ref(prepared) and
                   receipt["action"] == request["action"] and receipt["run_version"] == binding["expected_run_version"],
         true <- is_integer(request["expected_session_version"]) and is_integer(request["expected_run_version"]),
         true <- request["expected_session_version"] + 1 == receipt["session_version"] and
                   request["expected_run_version"] + 1 == receipt["run_version"],
         do: :ok, else: (_ -> error("authorization_required"))
  end

  defp prepared_metadata_current(row, config) do
    with true <- row.config_id == config.id and row.session_id == config.session_id and row.owner_id == config.owner_id,
         {:ok, scope} <- config_scope(config), {:ok, current_descriptor} <- descriptor(),
         true <- scope["descriptor"] == current_descriptor and row.context_digest == Contracts.digest(row.context_json),
         true <- row.context_json == %{"version" => 1, "scope" => Map.take(scope, @scope),
                     "purpose" => "company_synthesis_v2", "descriptor" => current_descriptor},
         {:ok, pin} <- StageAuthority.load_pin(row.stage_ref["id"]),
         true <- pin["config_digest"] == row.stage_ref["digest"] and Map.take(pin, @descriptor) == current_descriptor,
         do: :ok, else: (_ -> error("stale_preparation"))
  end

  defp manifest_metadata(prepared) do
    with true <- valid_ref?(prepared.manifest_ref),
         {:ok, %{rows: [[corpus, sem, access, json, count]]}} <- Repo.query(
           "SELECT m.corpus_id,m.semantic_generation,m.authorization_generation,m.context_json,m.source_count FROM dependency_manifests m JOIN corpora c ON c.id=m.corpus_id AND c.workspace_id=m.workspace_id WHERE m.workspace_id=? AND m.id=? AND m.digest=? AND m.state='sealed' AND c.state='active' AND c.semantic_generation=m.semantic_generation AND c.authorization_generation=m.authorization_generation",
           [Store.workspace(), prepared.manifest_ref["id"], prepared.manifest_ref["digest"]]),
         {:ok, context} <- Jason.decode(json),
         true <- count in 1..24 and context["retrieval_run_id"] == prepared.retrieval_ref["id"] and
                   context["retrieval_digest"] == prepared.retrieval_ref["digest"] and
                   context["stage"] == %{"id" => prepared.stage_ref["id"], "config_digest" => prepared.stage_ref["digest"]} do
      {:ok, %{"id" => prepared.manifest_ref["id"], "digest" => prepared.manifest_ref["digest"],
        "corpus_id" => corpus, "semantic_generation" => sem, "authorization_generation" => access}}
    else
      _ -> error("stale_preparation")
    end
  end

  defp disclosure_metadata_current(disclosure, prepared) do
    with true <- disclosure.preparation_id == prepared.id and disclosure.stage_ref == prepared.stage_ref and
                   disclosure.manifest_ref == prepared.manifest_ref and disclosure.context_digest == prepared.context_digest,
         {:ok, pin} <- StageAuthority.load_pin(prepared.stage_ref["id"]),
         true <- disclosure.consent_revision == pin["consent_revision"],
         {:ok, manifest} <- manifest_metadata(prepared),
         :ok <- StageAuthority.authorize_consent(pin, disclosure.consent_id, manifest),
         do: :ok, else: (_ -> error("consent_required"))
  end

  def current(authorization_ref, operation_ref, caller), do: current(authorization_ref, operation_ref, caller, nil)

  def current(authorization_ref, operation_ref, caller, source_context) do
    with :ok <- authenticate(caller),
         true <- valid_ref?(operation_ref),
         {:ok, binding} <- SetupRuns.operation_binding(operation_ref["id"], caller),
         true <-
           binding["operation_ref"] == operation_ref and binding["kind"] == "analysis" and
             binding["authorization_ref"] == authorization_ref,
         {:ok, row} <- owned(RunAuthorizationRecord, authorization_ref, caller),
         true <-
           row.run_id == binding["run_ref"]["id"] and row.config_id == binding["config_ref"]["id"] and
             row.preparation_id == binding["prepared_ref"]["id"],
         {:ok, _} <- authorization_state(row),
         :ok <- authorization_current(row),
         {:ok, config} <- owned(SetupRunConfig, binding["config_ref"], caller),
         {:ok, prepared} <- preparation(binding["prepared_ref"], caller, source_context),
         true <-
           row.scope_digest == prepared.context_digest and
             row.descriptor_json == config.scope_json["descriptor"],
         :ok <- validate_prepared(prepared, config, source_context),
         {:ok, disclosure} <- disclosure_for(row),
         :ok <- disclosure_current(disclosure, prepared, source_context),
         {:ok, budget} <- Ledger.budget(row.budget_id),
         true <- exact_budget?(budget) do
      {:ok,
       %{
         "authorization_ref" => ref(row),
         "operation_ref" => operation_ref,
         "budget_id" => row.budget_id,
         "descriptor" => row.descriptor_json,
         "limits" => @limits,
         "expires_at" => DateTime.to_iso8601(row.expires_at),
         "prepared_ref" => ref(prepared),
         "stage_ref" => prepared.stage_ref,
         "manifest_ref" => prepared.manifest_ref,
         "disclosure_ref" => ref(disclosure)
       }}
    else
      false -> error("authorization_required")
      failure -> normalize(failure)
    end
  end

  def ready_for_run(run_ref, caller), do: ready_for_run(run_ref, caller, nil)

  def ready_for_run(run_ref, caller, source_context) do
    with :ok <- authenticate(caller),
         {:ok, run} <- owned(SetupRun, run_ref, caller),
         {:ok, state} <- state_for(run.id),
         true <- state.phase not in ~w(cancelled expired proposed acquiring captured retrieving),
         {:ok, session} <- Store.get(SetupSession, run.session_id),
         true <-
           session.owner == Workspaces.operator() and
             get_in(session.payload, ["refs", "run_ref"]) == ref(run),
         {:ok, row} when not is_nil(row) <- authorization_for(run.id),
         true <- state.authorization_id == row.id and state.preparation_id == row.preparation_id,
         {:ok, _} <- authorization_state(row),
         :ok <- authorization_current(row),
         {:ok, config} <- owned_by_id(SetupRunConfig, run.config_id),
         {:ok, prepared} <-
           preparation(
             %{"id" => row.preparation_id, "digest" => preparation_hash(row.preparation_id)},
             caller, source_context
           ),
         true <-
           row.config_id == config.id and row.scope_digest == prepared.context_digest and
             row.descriptor_json == config.scope_json["descriptor"],
         :ok <- validate_prepared(prepared, config, source_context),
         {:ok, disclosure} <- disclosure_for(row),
         :ok <- disclosure_current(disclosure, prepared, source_context),
         {:ok, budget} <- Ledger.budget(row.budget_id),
         true <- exact_budget?(budget),
         do: {:ok, authorization_receipt(row, disclosure)},
         else: (
           false -> error("authorization_required")
           failure -> normalize(failure)
         )
  end

  defp preparation_hash(id) do
    case Repo.one(from p in Store.scoped(SetupRunPreparation), where: p.id == ^id and p.owner_id == ^Workspaces.operator(), select: p.digest) do
      digest when is_binary(digest) -> digest
      _ -> nil
    end
  end

  def prepared_view(prepared_ref, caller), do: prepared_view(prepared_ref, caller, nil)

  def prepared_view(prepared_ref, caller, source_context) do
    with :ok <- authenticate(caller),
         {:ok, row} <- preparation(prepared_ref, caller, source_context),
         {:ok, config} <- owned_by_id(SetupRunConfig, row.config_id),
         :ok <- validate_prepared(row, config, source_context),
         {:ok, pin} <- StageAuthority.load_pin(row.stage_ref["id"]),
         {:ok, manifest} <- OriginV2.manifest(row.manifest_ref["id"], row.manifest_ref["digest"], "analysis", source_context),
         {:ok, manifest_bytes} <- manifest_bytes(manifest),
         {:ok, run} <- owned_by_id(SetupRun, row.run_id) do
      reusable =
        with {:ok, consent} <- consent_for(pin),
             true <- owned_consent?(pin, consent, row.context_digest, row.session_id),
             :ok <- StageAuthority.authorize_consent(pin, consent.id, manifest),
             do: true

      {:ok,
       %{
         "prepared_ref" => ref(row),
         "config_ref" => ref(config),
         "run_ref" => ref(run),
         "retrieval_ref" => row.retrieval_ref,
         "stage_ref" => row.stage_ref,
         "manifest_ref" => row.manifest_ref,
         "context_digest" => row.context_digest,
         "descriptor" => config.scope_json["descriptor"],
         "source_count" => manifest["source_count"],
         "categories" => ~w(company_context source_body),
         "bytes" => manifest_bytes,
         "consent_status" =>
           if(reusable == true, do: "reusable", else: "explicit_grant_required"),
         "model_limits" => @limits
       }}
    else
      failure -> normalize(failure)
    end
  end

  defp manifest_bytes(manifest) do
    # Aggregate only exact indexed revision metadata. Repeated passage windows
    # never inflate the disclosed closure, and a missing revision fails closed.
    with {:ok, %{rows: [[count, indexed, bytes]]}} <-
           Repo.query(
             "SELECT count(*),count(body_bytes),coalesce(sum(body_bytes),0) FROM (SELECT d.source_id,d.revision_id,d.content_hash,(SELECT max(p.body_bytes) FROM passage_sets p WHERE p.workspace_id=d.workspace_id AND p.source_id=d.source_id AND p.revision_id=d.revision_id AND p.body_hash=d.content_hash AND p.state='ready') AS body_bytes FROM origin_dependencies d WHERE d.workspace_id=? AND d.manifest_id=? AND d.kind='source_revision' GROUP BY d.source_id,d.revision_id,d.content_hash)",
             [Store.workspace(), manifest["id"]]
           ),
         true <-
           count == manifest["source_count"] and indexed == count and is_integer(bytes) and
             bytes >= 0,
         do: {:ok, bytes},
         else: (_ -> error("stale_preparation"))
  end

  @doc false
  def preparation(prepared_ref, caller), do: preparation(prepared_ref, caller, nil)

  def preparation(prepared_ref, caller, source_context) do
    with :ok <- context_caller(source_context, caller),
         {:ok, metadata} <- preparation_metadata(prepared_ref, caller),
         {:ok, _} <- OriginV2.manifest(metadata.manifest_ref["id"], metadata.manifest_ref["digest"], "analysis", source_context),
         {:ok, row} <- owned(SetupRunPreparation, prepared_ref, caller),
         true <- row.digest == preparation_digest(row),
         true <-
           row.prompt_sha256 == Store.hash(row.prompt_bytes) and
             row.request_body_sha256 == Store.hash(row.request_body_bytes),
         do: {:ok, row},
         else: (_ -> error("stale_preparation"))
  end

  def validate_prepared(row, config), do: validate_prepared(row, config, nil)

  def validate_prepared(row, config, source_context) do
    with true <-
           row.config_id == config.id and row.session_id == config.session_id and
             row.owner_id == config.owner_id,
         {:ok, scope} <- config_scope(config),
         {:ok, current_descriptor} <- descriptor(),
         true <- scope["descriptor"] == current_descriptor,
         true <- row.context_digest == Contracts.digest(row.context_json),
         true <-
           row.context_json == %{
             "version" => 1,
             "scope" => Map.take(scope, @scope),
             "purpose" => "company_synthesis_v2",
             "descriptor" => current_descriptor
           },
         {:ok, pin} <- StageAuthority.load_pin(row.stage_ref["id"]),
         true <-
           pin["config_digest"] == row.stage_ref["digest"] and
             Map.take(pin, @descriptor) == current_descriptor,
         {:ok, expected_bytes} <-
           HarnessForge.Company.AnalysisV2.prepare_payload(row.checked_pack_json, pin, source_context),
         true <-
           expected_bytes == %{
             "prompt_bytes" => row.prompt_bytes,
             "prompt_sha256" => row.prompt_sha256,
             "request_body_bytes" => row.request_body_bytes,
             "request_body_sha256" => row.request_body_sha256
           },
         true <-
           row.digest == preparation_digest(row) and
             row.prompt_sha256 == Store.hash(row.prompt_bytes) and
             row.request_body_sha256 == Store.hash(row.request_body_bytes),
         true <-
           row.checked_pack_json["origin_context"]["manifest_id"] == row.manifest_ref["id"] and
             row.checked_pack_json["origin_context"]["manifest_digest"] ==
               row.manifest_ref["digest"],
         :ok <- OriginV2.validate_context(row.checked_pack_json["origin_context"], source_context),
         :ok <- pack_scope(row.checked_pack_json, scope) do
      :ok
    else
      failure -> normalize(failure, "stale_preparation")
    end
  end

  def usage(run_ref, caller) do
    with :ok <- authenticate(caller),
         {:ok, run} <- owned(SetupRun, run_ref, caller),
         {:ok, auth} <- authorization_for(run.id) do
      if is_nil(auth), do: {:ok, empty_usage()}, else: usage_for(auth)
    else
      failure -> normalize(failure)
    end
  end

  defp usage_for(auth) do
    with {:ok, budget} <- Ledger.budget(auth.budget_id),
         {:ok, rows} <- Ledger.list_requests(auth.budget_id) do
      requests = budget["reserved_requests"]
      tokens = budget["reserved_tokens"]
      cost = budget["reserved_estimated_microusd"]

      {:ok,
       %{
         "budget_id" => auth.budget_id,
         "requests_reserved" => requests,
         "tokens_accounted" => tokens,
         "cost_microusd_accounted" => cost,
         "pending_requests" => Enum.count(rows, &(&1["state"] == "dispatched")),
         "uncertain_requests" => Enum.count(rows, &(&1["state"] == "uncertain")),
         "remaining_requests" => max(0, auth.max_requests - requests),
         "remaining_tokens" => max(0, auth.max_tokens - tokens),
         "remaining_cost_microusd" => max(0, auth.max_cost_microusd - cost),
         "overrun" =>
           requests > auth.max_requests or tokens > auth.max_tokens or
             cost > auth.max_cost_microusd,
         "expires_at" => DateTime.to_iso8601(auth.expires_at),
         "pricing" => "local_zero"
       }}
    end
  end

  defp empty_usage,
    do: %{
      "budget_id" => nil,
      "requests_reserved" => 0,
      "tokens_accounted" => 0,
      "cost_microusd_accounted" => 0,
      "pending_requests" => 0,
      "uncertain_requests" => 0,
      "remaining_requests" => 2,
      "remaining_tokens" => 100_000,
      "remaining_cost_microusd" => 0,
      "overrun" => false,
      "expires_at" => nil,
      "pricing" => "local_zero"
    }

  # Private trusted resolution for Ledger. A registered operation can never
  # fall back to its operation ID, even with a missing/stale StageControl row.
  def budget_for_operation(operation_id, pin) do
    with {:ok, %{rows: rows}} <-
           Repo.query(
             "SELECT id FROM setup_run_operations WHERE workspace_id=? AND operation_id=?",
             [Store.workspace(), operation_id]
           ) do
      case rows do
        [] ->
          with :ok <- legacy_budget_allowed(operation_id),
               false <- setup_pin?(pin["id"]),
               do: {:ok, operation_id},
               else: (_ -> {:error, :authorization_required})

        [_] ->
          with {:ok, %{rows: [[authorization, budget, digest]]}} <-
                 Repo.query(
                   "SELECT authorization_id,budget_id,operation_binding_digest FROM stage_operations WHERE workspace_id=? AND id=?",
                   [Store.workspace(), operation_id]
                 ),
               true <- is_binary(authorization) and is_binary(budget) and Stages.digest?(digest),
               {:ok, operation} <- operation(operation_id),
               true <- operation.digest == digest and operation.authorization_id == authorization,
               {:ok, row} <- Store.get(RunAuthorizationRecord, authorization),
               true <-
                 row.budget_id == budget and row.run_id == operation.run_id and
                   row.preparation_id == operation.preparation_id,
               :ok <- authorization_current(row),
               {:ok, _} <- authorization_state(row),
               {:ok, preparation} <- preparation_metadata_by_id(row.preparation_id),
               true <-
                 preparation.stage_ref == %{"id" => pin["id"], "digest" => pin["config_digest"]},
               :ok <- budget_scope_current(operation, row, preparation),
               do: {:ok, budget},
               else: (_ -> {:error, :authorization_required})
      end
    else
      _ -> {:error, :authorization_required}
    end
  end

  defp budget_scope_current(operation, auth, prepared) do
    with {:ok, state} <- state_for(operation.run_id),
         true <-
           state.lock_version == operation.expected_run_version and state.phase == "running" and
             state.authorization_id == auth.id and state.preparation_id == prepared.id,
         {:ok, run} <- owned_by_id(SetupRun, operation.run_id),
         {:ok, session} <- Store.get(SetupSession, operation.session_id),
         true <-
           session.owner == Workspaces.operator() and
             get_in(session.payload, ["refs", "run_ref"]) == ref(run),
         {:ok, config} <- owned_by_id(SetupRunConfig, operation.config_id),
         :ok <- prepared_metadata_current(prepared, config),
         {:ok, disclosure} <- disclosure_for(auth),
         :ok <- disclosure_metadata_current(disclosure, prepared),
         do: :ok,
         else: (_ -> {:error, :authorization_required})
  end

  def legacy_allowed(operation_id, stage_ids) do
    with true <- is_list(stage_ids),
         :ok <- legacy_budget_allowed(operation_id),
         {:ok, %{rows: []}} <-
           Repo.query(
             "SELECT id FROM setup_run_operations WHERE workspace_id=? AND operation_id=?",
             [Store.workspace(), operation_id]
           ),
         true <- not Enum.any?(stage_ids, &setup_pin?/1),
         do: :ok,
         else: (_ -> {:error, :authorization_required})
  end

  def setup_consent_allowed(stage_id) do
    if setup_pin?(stage_id) do
      rows =
        Repo.all(
          from p in SetupRunPreparation,
            join: s in SetupRunState,
            on:
              s.workspace_id == p.workspace_id and s.owner_id == p.owner_id and
                s.session_id == p.session_id and s.run_id == p.run_id and s.preparation_id == p.id,
            where:
              p.workspace_id == ^Store.workspace() and p.owner_id == ^Workspaces.operator() and
                s.phase in ["needs_input", "ready"] and
                fragment("json_extract(?, '$.id') = ?", p.stage_ref, ^stage_id),
            select: map(p, [:id, :digest, :workspace_id, :owner_id, :session_id, :run_id, :config_id, :operation_id, :retrieval_ref, :stage_ref, :manifest_ref, :context_digest, :context_json])
        )

      allowed =
        Repo.in_transaction?() and
          Enum.any?(rows, fn prepared ->
            with true <- prepared.stage_ref["id"] == stage_id,
                 {:ok, config} <- owned_by_id(SetupRunConfig, prepared.config_id),
                 {:ok, _, _, _} <- accepted_authorize_state(config, prepared),
                 do: true,
                 else: (_ -> false)
          end)

      if allowed, do: :ok, else: {:error, :authorization_required}
    else
      :ok
    end
  end

  defp owned_consent?(pin, consent, context_digest, session_id) do
    stage = %{"id" => pin["id"], "digest" => pin["config_digest"]}

    Repo.exists?(
      from d in RunDisclosure,
        where:
          d.workspace_id == ^Store.workspace() and d.owner_id == ^Workspaces.operator() and
            d.session_id == ^session_id and d.context_digest == ^context_digest and
            d.stage_ref == ^stage and d.consent_id == ^consent.id and
            d.consent_revision == ^consent.revision
    )
  end

  def legacy_budget_allowed(id) do
    with false <- retired?("setup_budget_retired", id) or retired?("setup_operation_retired", id),
         {:ok, %{rows: [[0]]}} <-
           Repo.query(
             "SELECT (SELECT count(*) FROM setup_run_operations WHERE workspace_id=? AND operation_id=?) + (SELECT count(*) FROM model_run_authorizations WHERE workspace_id=? AND budget_id=?)",
             [Store.workspace(), id, Store.workspace(), id]
           ),
         do: :ok,
         else: (_ -> {:error, :authorization_required})
  end

  def budget_creation_allowed(budget_id) do
    with true <- Repo.in_transaction?(),
         row when not is_nil(row) <-
           Repo.one(
             from a in RunAuthorizationRecord,
               where:
                 a.workspace_id == ^Store.workspace() and a.owner_id == ^Workspaces.operator() and
                   a.budget_id == ^budget_id
           ),
         {:ok, config} <- owned_by_id(SetupRunConfig, row.config_id),
         {:ok, prepared} <- preparation_metadata_by_id(row.preparation_id),
         {:ok, _, _, _} <- accepted_authorize_state(config, prepared),
         :ok <- authorization_current(row),
         do: :ok,
         else: (_ -> {:error, :authorization_required})
  end

  def setup_pin?(id) do
    retired?("setup_pin_retired", id) or
      case Repo.query(
             "SELECT 1 FROM setup_run_preparations WHERE workspace_id=? AND json_extract(stage_ref,'$.id')=? LIMIT 1",
             [Store.workspace(), id]
           ) do
        {:ok, %{rows: []}} -> false
        _ -> true
      end
  end

  defp retired?(action, id) do
    case Repo.query(
           "SELECT 1 FROM audit_events WHERE workspace_id=? AND action=? AND json_extract(details,'$.status')='retired' AND json_extract(details,'$.run_id')=? LIMIT 1",
           [Store.workspace(), action, id]
         ) do
      {:ok, %{rows: []}} -> false
      _ -> true
    end
  end

  defp accepted_authorize(config, prepared, caller) do
    with :ok <- authenticate(caller), do: accepted_authorize_state(config, prepared)
  end

  defp accepted_authorize_state(config, prepared) do
    with {:ok, run} <- owned_by_id(SetupRun, prepared.run_id),
         {:ok, state} <- state_for(run.id),
         {:ok, session} <- Store.get(SetupSession, run.session_id),
         true <- session.owner == Workspaces.operator() and session.schema_version == 2,
         true <- get_in(session.payload, ["refs", "run_ref"]) == ref(run),
         true <- state.preparation_id == prepared.id and state.phase in ~w(needs_input ready),
         command when not is_nil(command) <-
           Repo.one(
             from c in SetupRunCommand,
               where:
                 c.workspace_id == ^Store.workspace() and c.owner_id == ^Workspaces.operator() and
                   c.session_id == ^run.session_id and c.command_id == ^state.last_command_id
           ),
         request = command.request_json,
         receipt = command.receipt_json,
         true <-
           command.run_id == run.id and request["action"] == "authorize" and
             request["payload"] == %{"prepared_ref" => ref(prepared)},
         true <- command.request_digest == Contracts.digest(request),
         true <-
           is_integer(request["expected_session_version"]) and
             is_integer(request["expected_run_version"]),
         true <-
           request["expected_session_version"] + 1 == session.lock_version and
             request["expected_run_version"] + 1 == state.lock_version,
         true <-
           receipt["session_version"] == session.lock_version and
             receipt["run_version"] == state.lock_version and receipt["run_ref"] == ref(run),
         true <-
           receipt["command_ref"] == %{"id" => command.id, "digest" => command.request_digest} and
             receipt["action"] == "authorize" and receipt["prepared_ref"] == ref(prepared),
         true <- run.config_id == config.id and config.session_id == run.session_id,
         do: {:ok, run, state, command},
         else: (_ -> error("authorization_required"))
  end

  defp disclosure_current(disclosure, prepared, source_context) do
    with true <-
           disclosure.preparation_id == prepared.id and disclosure.stage_ref == prepared.stage_ref and
             disclosure.manifest_ref == prepared.manifest_ref and
             disclosure.context_digest == prepared.context_digest,
         {:ok, pin} <- StageAuthority.load_pin(prepared.stage_ref["id"]),
         true <- disclosure.consent_revision == pin["consent_revision"],
         {:ok, manifest} <-
           OriginV2.manifest(prepared.manifest_ref["id"], prepared.manifest_ref["digest"], "analysis", source_context),
         :ok <- StageAuthority.authorize_consent(pin, disclosure.consent_id, manifest),
         do: :ok,
         else: (_ -> error("consent_required"))
  end

  defp authorization_current(row) do
    now = Store.now()

    if row.digest == authorization_digest(row) and row.max_requests == 2 and
         row.max_tokens == 100_000 and row.max_cost_microusd == 0 and
         DateTime.diff(row.expires_at, row.authorized_at, :second) == 300 and
         DateTime.compare(row.authorized_at, now) != :gt and
         DateTime.compare(now, row.expires_at) == :lt,
       do: :ok,
       else: error("authorization_expired")
  end

  defp authorization_state(row) do
    case Repo.one(
           from s in RunAuthorizationState,
             where:
               s.workspace_id == ^Store.workspace() and s.authorization_id == ^row.id and
                 s.owner_id == ^Workspaces.operator() and s.session_id == ^row.session_id and
                 is_nil(s.revoked_at)
         ) do
      nil -> error("cancelled")
      state -> {:ok, state}
    end
  end

  defp consent_for(pin) do
    case Repo.one(
           from c in Store.scoped(StageConsent),
             where:
               c.stage_config_id == ^pin["id"] and c.revision == ^pin["consent_revision"] and
                 c.state == "active"
         ) do
      nil -> {:error, :consent_required}
      row -> {:ok, row}
    end
  end

  defp authorization_for(id),
    do:
      {:ok,
       Repo.one(
         from a in RunAuthorizationRecord,
           where:
             a.workspace_id == ^Store.workspace() and a.owner_id == ^Workspaces.operator() and
               a.run_id == ^id
       )}

  defp disclosure_for(auth) do
    case Repo.one(
           from d in RunDisclosure,
             where:
               d.workspace_id == ^Store.workspace() and d.owner_id == ^Workspaces.operator() and
                 d.run_id == ^auth.run_id and d.preparation_id == ^auth.preparation_id
         ) do
      nil ->
        error("authorization_required")

      row ->
        if row.digest == disclosure_digest(row),
          do: {:ok, row},
          else: error("authorization_required")
    end
  end

  defp state_for(id) do
    case Repo.one(
           from s in SetupRunState,
             where:
               s.workspace_id == ^Store.workspace() and s.owner_id == ^Workspaces.operator() and
                 s.run_id == ^id
         ) do
      nil -> error("not_found")
      row -> {:ok, row}
    end
  end

  defp operation(id) do
    case Repo.one(
           from o in SetupRunOperation,
             where:
               o.workspace_id == ^Store.workspace() and o.owner_id == ^Workspaces.operator() and
                 o.operation_id == ^id
         ) do
      nil -> error("not_found")
      row -> {:ok, row}
    end
  end

  defp existing_preparation(binding),
    do:
      {:ok,
       Repo.one(
         from p in SetupRunPreparation,
           where:
             p.workspace_id == ^Store.workspace() and p.owner_id == ^Workspaces.operator() and
               p.run_id == ^binding["run_ref"]["id"]
       )}

  defp owned(module, reference, caller) do
    with :ok <- authenticate(caller),
         true <- valid_ref?(reference),
         {:ok, row} <- owned_by_id(module, reference["id"]),
         true <- row.digest == reference["digest"],
         do: {:ok, row},
         else: (_ -> error("not_found"))
  end

  defp owned_by_id(module, id) do
    with {:ok, row} <- Store.get(module, id),
         true <- row.owner_id == Workspaces.operator(),
         do: {:ok, row},
         else: (_ -> error("not_found"))
  end

  defp context_caller(nil, _caller), do: :ok
  defp context_caller(source_context, caller), do: SourceUseContext.match_caller(source_context, caller)

  defp config_scope(config) do
    with scope when is_map(scope) <- config.scope_json,
         true <-
           Enum.sort(Map.keys(scope)) == Enum.sort(@config_fields) and
             config.digest == Contracts.digest(scope),
         true <-
           scope["version"] == 1 and scope["profile_version"] == "setup-local-synthesis.v1" and
             scope["model_limits"] == @limits,
         true <-
           Enum.all?(~w(profile_ref project_ref repository_ref goal_ref), &valid_ref?(scope[&1])),
         true <-
           Stages.digest?(scope["outcome_hash"]) and CompanyAnalysis.uuid?(scope["connection_id"]),
         true <-
           is_binary(scope["query_text"]) and byte_size(scope["query_text"]) in 1..1024 and
             String.length(scope["query_text"]) <= 256,
         true <-
           scope["capture_limits"] == %{
             "max_files" => 500,
             "max_body_bytes" => 16_777_216,
             "max_file_bytes" => 1_048_576,
             "max_admitted_entries" => 10_000,
             "deadline_seconds" => 600
           },
         true <-
           scope["history"] == "current_snapshot_only" and
             Stages.digest?(scope["root_fingerprint"]),
         do: {:ok, scope},
         else: (_ -> error("unsupported_configuration"))
  end

  defp pack_scope(pack, scope) do
    if %{"id" => pack["profile"]["id"], "digest" => pack["profile"]["content_hash"]} ==
         scope["profile_ref"] and
         %{"id" => pack["project"]["id"], "digest" => pack["project"]["content_hash"]} ==
           scope["project_ref"] and
         %{"id" => pack["goal_id"], "digest" => pack["goal_hash"]} == scope["goal_ref"],
       do: :ok,
       else: error("stale_scope")
  end

  defp authenticate(caller) do
    with :ok <- Workspaces.ensure_writable(),
         :ok <- AssessmentAttempts.options(caller),
         :ok <- AssessmentAttempts.authorize(caller),
         do: :ok,
         else: (_ -> error("unauthorized"))
  end

  defp guarded(caller, fun) do
    HarnessForge.Privacy.Purge.synchronize(fn ->
      Store.transaction(fn -> with :ok <- authenticate(caller), do: fun.() end)
    end)
  end

  def normalize(result, fallback \\ "unavailable")
  def normalize({:error, %{"code" => _, "current" => _}} = error, _), do: error

  def normalize({:error, code}, _)
      when code in [
             :budget_exhausted,
             :request_outcome_unknown,
             :cancelled,
             :consent_required,
             :authorization_required
           ],
      do: error(Atom.to_string(code))

  def normalize(_, fallback), do: error(fallback)

  defp budget_limits,
    do: %{"max_requests" => 2, "max_tokens" => 100_000, "max_estimated_microusd" => 0}

  defp exact_budget?(budget),
    do: Map.take(budget, ~w(max_requests max_tokens max_estimated_microusd)) == budget_limits()

  defp authorization_receipt(row, disclosure),
    do: %{
      "authorization_ref" => ref(row),
      "disclosure_ref" => ref(disclosure),
      "budget_id" => row.budget_id,
      "expires_at" => DateTime.to_iso8601(row.expires_at)
    }

  def preparation_digest(row),
    do:
      digest_fields(
        row,
        ~w(id workspace_id owner_id session_id run_id config_id operation_id retrieval_ref stage_ref manifest_ref context_digest context_json checked_pack_json prompt_bytes prompt_sha256 request_body_bytes request_body_sha256)
      )

  def authorization_digest(row),
    do:
      digest_fields(
        row,
        ~w(id workspace_id owner_id session_id run_id config_id preparation_id scope_digest descriptor_json budget_id max_requests max_tokens max_cost_microusd authorized_at expires_at command_id)
      )

  def disclosure_digest(row),
    do:
      digest_fields(
        row,
        ~w(id workspace_id owner_id session_id run_id config_id preparation_id stage_ref manifest_ref consent_id consent_revision context_digest command_id)
      )

  @doc false
  def restore_digest("preparation", %SetupRunPreparation{} = row),
    do: {:ok, preparation_digest(row)}

  def restore_digest("authorization", %RunAuthorizationRecord{} = row),
    do: {:ok, authorization_digest(row)}

  def restore_digest("disclosure", %RunDisclosure{} = row), do: {:ok, disclosure_digest(row)}
  def restore_digest(_, _), do: {:error, :invalid_input}

  defp digest_fields(record, fields),
    do:
      Contracts.digest(
        Map.new(fields, fn field ->
          value = Map.fetch!(record, String.to_existing_atom(field))
          {field, if(match?(%DateTime{}, value), do: DateTime.to_iso8601(value), else: value)}
        end)
      )
end
