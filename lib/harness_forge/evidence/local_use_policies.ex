defmodule HarnessForge.Evidence.LocalUsePolicies do
  @moduledoc """
  Exact captured-local revision permissions beside immutable evidence identities.
  Enrollment is sticky by source and namespace. No hold absence, capture, caller
  callback or model consent grants a source purpose. Legacy admission is always
  reported as unknown, never as a positive policy decision.
  """
  import Ecto.Query
  alias HarnessForge.{Contracts, Repo, Workspaces}
  alias HarnessForge.Company.{SetupRunCommand, SetupRunConfig}
  alias HarnessForge.Evidence.{Capture, CaptureRun, Connection, Corpora, LocalImport,
    LocalUseEnrollment, LocalUseItem, LocalUseLifecycle, LocalUseSet, RevisionUseHolds,
    SetupCapture, SourceUseContext, Store}
  alias HarnessForge.Privacy.Purge
  @purposes ~w(inspection retrieval analysis compile)
  @namespace "e.workspace_id=r.workspace_id AND (e.source_id=r.source_id OR (e.connection_id=s.connection_id AND e.provider=s.provider AND e.external_id=s.external_id))"
  @historical_namespace "history.workspace_id=r.workspace_id AND grantset.state IN('active','withdrawn','superseded') AND grantset.policy_generation>0 AND (history.source_id=r.source_id OR (grantset.connection_id=s.connection_id AND s.provider='local' AND history.capture_item_key=s.external_id))"

  def prepare_capture(attrs, caller, auth) do
    with :ok <- input(attrs, ~w(version capture_ref), "LocalUsePreparation.v1"),
         true <- ref?(attrs["capture_ref"]),
         {:ok, context} <- SourceUseContext.interactive(auth, caller),
         {:ok, observed} <- observe_capture(attrs["capture_ref"], caller),
         {:ok, fingerprint} <- physical_fingerprint(observed.connection),
         true <- fingerprint == observed.basis["root_fingerprint"] do
      guarded(context, fn ->
        with {:ok, fresh} <- capture_basis(attrs["capture_ref"]),
             true <- fresh == observed,
             :ok <- capture_enrollment_scope(fresh),
             {:ok, prepared} <- freeze_preparation(fresh) do
          {:ok, preparation_dto(prepared)}
        else
          false -> {:error, :preparation_stale}
          error -> error
        end
      end)
    else
      false -> {:error, :preparation_stale}
      error -> error
    end
  end

  def read_preparation(id, attrs, context) do
    guarded(context, fn ->
      with :ok <- Corpora.keys(attrs, [], ["cursor"]),
           {:ok, set} <- owned_set(id),
           :ok <- frozen_integrity(set),
           binding = %{"kind" => "local-use-preparation.v1", "id" => set.id,
             "digest" => set.preparation_digest},
           {:ok, after_id} <- Corpora.cursor(attrs["cursor"], binding, context.caller) do
        rows = Corpora.rows("SELECT source_id AS id,source_id,revision_id,body_hash,capture_item_key FROM local_use_items WHERE workspace_id=? AND set_id=? AND source_id>? ORDER BY source_id LIMIT 26",
          [Store.workspace(), set.id, after_id])
        {:ok, Map.merge(preparation_dto(set), Corpora.paged(rows, binding, context.caller))}
      end
    end)
  end

  def authorize(attrs, caller, auth) do
    with :ok <- input(attrs, ~w(version preparation_ref expected_version command_id purposes retain_local), "LocalUseAuthorization.v1"),
         true <- ref?(attrs["preparation_ref"]) and attrs["expected_version"] === 0 and
           Corpora.uuid?(attrs["command_id"]) and attrs["retain_local"] === true and
           valid_purposes?(attrs["purposes"]),
         {:ok, context} <- SourceUseContext.interactive(auth, caller) do
      case guarded(context, fn -> LocalUseLifecycle.replay("policy:" <> attrs["command_id"], Contracts.digest(attrs)) end) do
        {:ok, nil} -> authorize_fresh(attrs, context)
        {:ok, event} -> guarded(context, fn -> replay_policy_receipt(event) end)
        error -> error
      end
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  defp authorize_fresh(attrs, context) do
    with {:ok, observed} <- guarded(context, fn ->
           with {:ok, set} <- preparation(attrs["preparation_ref"]),
                {:ok, fresh} <- capture_basis(capture_ref(set)), do: {:ok, {set, fresh}}
         end),
         {set, basis} = observed,
         {:ok, fingerprint} <- physical_fingerprint(basis.connection),
         true <- fingerprint == set.root_fingerprint do
      guarded(context, fn -> activate(attrs, observed) end)
    else
      false -> {:error, :preparation_stale}
      error -> error
    end
  end

  def withdraw(attrs, caller, auth) do
    with :ok <- input(attrs, ~w(version policy_ref expected_generation command_id reason_code), "LocalUseWithdrawal.v1"),
         true <- ref?(attrs["policy_ref"]) and positive?(attrs["expected_generation"]) and
           Corpora.uuid?(attrs["command_id"]) and attrs["reason_code"] == "operator_withdrawal",
         {:ok, context} <- SourceUseContext.interactive(auth, caller) do
      guarded(context, fn ->
        digest = Contracts.digest(attrs)
        with {:ok, replay} <- LocalUseLifecycle.replay("policy:" <> attrs["command_id"], digest) do
          if replay do
            receipt_for_event(replay)
          else
            with {:ok, set} <- policy(attrs["policy_ref"]),
                 true <- set.state == "active" and set.policy_generation == attrs["expected_generation"],
                 changed = Corpora.query!("UPDATE local_use_sets SET state='withdrawn',policy_generation=policy_generation+1,withdrawn_at=?,lock_version=lock_version+1 WHERE workspace_id=? AND id=? AND state='active' AND policy_generation=?",
                   [Corpora.now(), Store.workspace(), set.id, set.policy_generation]),
                 true <- changed.num_rows == 1,
                 {:ok, event} <- LocalUseLifecycle.policy_event("withdraw", set.id,
                   "policy:" <> attrs["command_id"], digest,
                   %{"previous_generation" => set.policy_generation, "policy_generation" => set.policy_generation + 1}) do
              receipt_for_event(event)
            else
              false -> {:error, :policy_generation_conflict}
              error -> error
            end
          end
        end
      end)
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  def status(id, attrs, context) do
    guarded(context, fn ->
      with :ok <- Corpora.keys(attrs, []), {:ok, set} <- owned_set(id), do: receipt(set)
    end)
  end

  def resume_cleanup(event_id, expected, context) do
    guarded(context, fn ->
      with true <- Corpora.uuid?(event_id) and nonnegative?(expected),
           {:ok, event} <- LocalUseLifecycle.event(event_id),
           {:ok, _} <- owned_set(event["set_id"]),
           {:ok, _} <- LocalUseLifecycle.resume_in_transaction(event_id, expected),
           do: receipt_for_event(event), else: (false -> {:error, :invalid_input}; error -> error)
    end)
  end

  def prepare_refresh(attrs, caller, auth) do
    with :ok <- input(attrs, ~w(version policy_ref expected_generation command_id retain_updates_for_review), "LocalUseRefresh.v1"),
         true <- ref?(attrs["policy_ref"]) and positive?(attrs["expected_generation"]) and
           Corpora.uuid?(attrs["command_id"]) and attrs["retain_updates_for_review"] === true,
         {:ok, context} <- SourceUseContext.interactive(auth, caller) do
      case guarded(context, fn -> LocalUseLifecycle.replay("refresh:" <> attrs["command_id"], Contracts.digest(attrs)) end) do
        {:ok, nil} -> prepare_refresh_fresh(attrs, context)
        {:ok, event} -> guarded(context, fn ->
          with :ok <- refresh_barrier(event["payload"]),
               {:ok, set} <- policy(event["payload"]["policy_ref"]),
               {:ok, _} <- effective_enrollments(set, event["payload"]["policy_generation"]),
               do: {:ok, %{"refresh_ref" => %{"id" => event["id"], "digest" => event["request_digest"]},
                 "expires_at" => event["payload"]["expires_at"], "use_grant" => false}}
        end)
        error -> error
      end
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  defp prepare_refresh_fresh(attrs, context) do
    with {:ok, observed} <- guarded(context, fn ->
           with {:ok, set} <- policy(attrs["policy_ref"]),
                {:ok, survivors} <- effective_enrollments(set, attrs["expected_generation"]),
                true <- survivors != [],
                :ok <- unheld_survivors(survivors),
                {:ok, connection} <- local_connection(set.connection_id),
                true <- connection_digest(connection) == set.connection_digest,
                do: {:ok, {set, connection}}, else: (false -> {:error, :preparation_stale}; error -> error)
         end),
         {set, connection} = observed,
         {:ok, fingerprint} <- physical_fingerprint(connection),
         true <- fingerprint == set.root_fingerprint do
      guarded(context, fn ->
        with {:ok, current} <- policy(attrs["policy_ref"]),
             true <- current == set,
             {:ok, survivors} <- effective_enrollments(current, attrs["expected_generation"]),
             true <- survivors != [],
             :ok <- unheld_survivors(survivors),
             {:ok, source_digest} <- refresh_source_set_digest(current),
             {:ok, fresh_connection} <- local_connection(set.connection_id),
             true <- fresh_connection == connection do
          payload = %{"version" => "LocalUseRefresh.v1", "policy_ref" => attrs["policy_ref"],
            "policy_generation" => set.policy_generation, "source_set_digest" => source_digest,
            "privacy_barrier" => LocalUseLifecycle.privacy_barrier(),
            "owner_id" => set.owner_id, "connection_id" => set.connection_id,
            "connection_digest" => set.connection_digest, "root_fingerprint" => set.root_fingerprint,
            "limits" => SetupCapture.limits(), "retention_disclosure" => "bounded-updates-for-review.v1",
            "expires_at" => DateTime.to_iso8601(DateTime.add(Store.now(), 600, :second))}
          with {:ok, event} <- LocalUseLifecycle.append_in_transaction("refresh_prepared",
            %{"set_id" => set.id}, %{"command_key" => "refresh:" <> attrs["command_id"],
              "request_digest" => Contracts.digest(attrs), "payload" => payload}) do
            {:ok, %{"refresh_ref" => %{"id" => event["id"], "digest" => event["request_digest"]},
              "expires_at" => event["payload"]["expires_at"], "use_grant" => false}}
          end
        else
          false -> {:error, :preparation_stale}
          error -> error
        end
      end)
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  @doc "Parameterized pre-selection policy predicate; revision r and joined source s are static aliases."
  def not_denied_sql("r", purpose, context) when purpose in @purposes do
    with {:ok, checked} <- checked_context(context, purpose) do
      absent = "(NOT EXISTS(SELECT 1 FROM local_use_enrollments e WHERE #{@namespace}) AND NOT EXISTS(SELECT 1 FROM local_use_items history JOIN local_use_sets grantset ON grantset.id=history.set_id AND grantset.workspace_id=history.workspace_id WHERE #{@historical_namespace}))"
      if is_nil(checked) do
        {:ok, {absent, []}}
      else
        purposes = required_purposes(purpose)
        selected = Enum.map_join(purposes, " AND ", fn _ ->
          "EXISTS(SELECT 1 FROM json_each(p.purposes_json) permitted WHERE permitted.value=?)"
        end)
        {manifest, params} = manifest_sql(checked)
        classification = "(SELECT count(*) FROM local_use_items original WHERE original.workspace_id=p.workspace_id AND original.set_id=p.id)=p.item_count AND NOT EXISTS(SELECT 1 FROM local_use_items original LEFT JOIN local_use_enrollments assigned ON assigned.workspace_id=original.workspace_id AND assigned.original_source_id=original.source_id WHERE original.workspace_id=p.workspace_id AND original.set_id=p.id AND coalesce(assigned.original_source_id=original.source_id AND assigned.connection_id=p.connection_id AND assigned.provider='local' AND assigned.external_id=original.capture_item_key AND assigned.grant_generation=p.policy_generation AND ((assigned.state='bound' AND assigned.source_id=original.source_id AND assigned.set_id=p.id) OR (assigned.state='purged_denied' AND assigned.source_id IS NULL AND assigned.set_id IS NULL)),0)=0)"
        sql = "(#{absent} OR EXISTS(SELECT 1 FROM local_use_enrollments e JOIN local_use_sets p ON p.id=e.set_id AND p.workspace_id=e.workspace_id JOIN local_use_items i ON i.set_id=p.id AND i.workspace_id=p.workspace_id AND i.source_id=e.source_id WHERE #{@namespace} AND e.state='bound' AND e.source_id=r.source_id AND e.original_source_id=r.source_id AND e.connection_id=s.connection_id AND e.provider=s.provider AND e.external_id=s.external_id AND p.workspace_id=? AND p.owner_id=? AND p.state='active' AND p.quarantined=0 AND p.retain_local=1 AND p.policy_generation>0 AND e.grant_generation=p.policy_generation AND i.revision_id=r.id AND i.body_hash=r.body_hash AND #{classification} AND #{selected} #{manifest}))"
        {:ok, {sql, [checked.workspace_id, checked.owner_id] ++ purposes ++ params}}
      end
    end
  rescue
    _ -> {:error, :source_use_denied}
  end
  def not_denied_sql(_, purpose, _) when purpose not in @purposes, do: {:error, :unsupported_purpose}
  def not_denied_sql(_, _, _), do: {:error, :invalid_input}

  def assert_use(ref, purpose, context) do
    with true <- exact_ref?(ref),
         {:ok, checked} <- checked_context(context, purpose),
         :ok <- Purge.ready(),
         {:ok, identity} <- current_identity(ref),
         :ok <- RevisionUseHolds.assert_use(ref["source_id"], ref["revision_id"], ref["body_hash"], purpose),
         :ok <- manifest_member(checked, ref) do
      case enrollments(identity) do
        [] ->
          if frozen_namespace?(identity), do: {:error, :source_use_denied},
            else: (with :ok <- revalidate_context(context, purpose), do: :legacy_unknown)
        [enrollment] ->
          with {:ok, set} <- owned_set(enrollment["set_id"]),
               :ok <- active_enrollments(set, enrollment["grant_generation"]),
               {:ok, {sql, params}} <- not_denied_sql("r", purpose, context),
               [_] <- Corpora.rows("SELECT r.id FROM evidence_revisions r JOIN evidence_sources s ON s.id=r.source_id AND s.workspace_id=r.workspace_id WHERE r.workspace_id=? AND r.id=? AND (#{sql})",
                 [Store.workspace(), ref["revision_id"]] ++ params),
               :ok <- revalidate_context(context, purpose), do: :ok,
            else: (_ -> {:error, :source_use_denied})
        _ -> {:error, :source_use_denied}
      end
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  rescue
    _ -> {:error, :source_use_denied}
  end

  def assert_corpus_use(corpus_id, purpose, context) do
    with true <- Corpora.uuid?(corpus_id),
         {:ok, {sql, params}} <- not_denied_sql("r", purpose, context),
         :ok <- RevisionUseHolds.assert_corpus_unheld(corpus_id),
         [] <- Corpora.rows("SELECT m.source_id FROM corpus_members m JOIN evidence_sources s ON s.id=m.source_id AND s.workspace_id=m.workspace_id JOIN evidence_revisions r ON r.id=m.revision_id AND r.source_id=s.id AND r.workspace_id=s.workspace_id JOIN source_connections c ON c.id=s.connection_id AND c.workspace_id=s.workspace_id WHERE m.workspace_id=? AND m.corpus_id=? AND m.status='active' AND (s.status!='active' OR c.status!='active' OR s.latest_revision_id!=r.id OR NOT(#{sql})) LIMIT 1",
           [Store.workspace(), corpus_id] ++ params),
         :ok <- revalidate_context(context, purpose), do: :ok,
      else: (false -> {:error, :invalid_input}; {:error, _} = error -> error; _ -> {:error, :source_use_denied})
  rescue
    _ -> {:error, :source_use_denied}
  end

  def decision_for_run(id, digest, purpose, context) do
    with {:ok, checked} <- checked_context(context, purpose),
         true <- Corpora.uuid?(id) and Corpora.digest?(digest),
         [run] <- Corpora.rows("SELECT corpus_id,envelope,coverage,digest FROM retrieval_runs WHERE workspace_id=? AND id=? AND state IN('ready','abstained')", [Store.workspace(), id]),
         true <- run["digest"] == digest,
         envelope = decode(run["envelope"]), coverage = decode(run["coverage"]),
         true <- Contracts.digest(%{"envelope" => envelope, "coverage" => coverage}) == digest,
         true <- envelope["scope"]["workspace_id"] == Store.workspace() and
           envelope["scope"]["corpus_id"] == run["corpus_id"],
         :ok <- Corpora.assert_generation(run["corpus_id"], envelope["scope"]["semantic_generation"],
           envelope["scope"]["authorization_generation"]),
         {:ok, facts} <- decision_facts(run["corpus_id"], purpose, context, checked),
         :ok <- revalidate_context(context, purpose) do
      status = cond do
        facts.managed == 0 -> "legacy_unknown"
        facts.managed == facts.total -> "all_managed_allowed"
        true -> "mixed_unknown"
      end
      core = %{"version" => "CurrentUseDecision.v1", "snapshot_digest" => digest,
        "workspace_id" => Store.workspace(), "principal" => if(checked, do: checked.owner_id, else: nil),
        "purpose" => purpose, "status" => status, "policies" => Contracts.digest(facts.policies)}
      {:ok, Map.put(core, "decision_digest", Contracts.digest(core))}
    else
      {:error, _} = error -> error
      _ -> {:error, :source_use_denied}
    end
  rescue
    _ -> {:error, :source_use_denied}
  end

  def source_revision_v2(ref, purpose, context) do
    with result when result in [:ok, :legacy_unknown] <- assert_use(ref, purpose, context),
         {:ok, row} <- current_identity(ref) do
      identity = Map.take(row, ~w(workspace_id connection_id provider external_id source_id revision_id body_hash))
      base = %{"version" => "SourceRevision.v2", "identity" => identity,
        "provider_acl" => "unknown", "effective_time" => nil,
        "history" => %{"acquisition_kind" => if(row["provider"] == "local", do: "local_file", else: "unknown"),
          "exact_version_history_basis" => nil, "unavailable_ranges" => nil, "eligibility" => "unavailable"}}
      if result == :legacy_unknown do
        {:ok, Map.merge(base, %{"availability" => %{"status" => "unknown"},
          "policy" => %{"current_use" => "legacy_unknown"}, "retention" => "unknown"})}
      else
        [enrollment] = enrollments(row)
        {:ok, set} = owned_set(enrollment["set_id"])
        [item] = Corpora.rows("SELECT capture_item_key FROM local_use_items WHERE workspace_id=? AND set_id=? AND source_id=?", [Store.workspace(), set.id, ref["source_id"]])
        projection = Map.merge(base, %{
          "availability" => %{"status" => "captured_local_revision", "live_filesystem_equality" => "unknown",
            "basis" => %{"capture_id" => set.capture_id, "binding_digest" => set.binding_digest,
              "config_ref" => %{"id" => set.config_id, "digest" => set.config_digest},
              "accepted_acquire_command" => set.acquire_command_id, "capture_item_identity" => item["capture_item_key"],
              "captured_at" => row["captured_at"], "provenance_status" => "historical_capture_attestation"}},
          "policy" => %{"basis" => "explicit_local_operator_exact_capture", "principal" => set.owner_id,
            "policy_ref" => %{"id" => set.id, "digest" => set.policy_digest}, "policy_generation" => set.policy_generation,
            "permitted_purposes" => set.purposes_json, "current_use" => purpose},
          "retention" => "explicit_local_operator_permission"})
        with :ok <- assert_use(ref, purpose, context), do: {:ok, projection}
      end
    end
  rescue
    _ -> {:error, :source_use_denied}
  end

  def assert_storage_transition(identity, change_kind),
    do: assert_storage_transition(identity, change_kind, nil)

  def assert_storage_transition(identity, change_kind, staging) when is_map(identity) do
    with true <- Corpora.keys(identity, ~w(workspace_id connection_id provider external_id source_id revision_id body_hash)) == :ok and
           identity["workspace_id"] == Store.workspace() and
           Corpora.uuid?(identity["connection_id"]) and is_binary(identity["provider"]) and
           Corpora.text?(identity["external_id"], 4096) and
           (is_nil(identity["source_id"]) or Corpora.uuid?(identity["source_id"])) and
           (is_nil(identity["revision_id"]) or Corpora.uuid?(identity["revision_id"])) and
           (is_nil(identity["body_hash"]) or Corpora.digest?(identity["body_hash"])) and
           change_kind in [:unchanged, :upsert, :delete] and
           (is_nil(staging) or valid_staging?(staging)) do
      case enrollments(identity) do
        [] -> if(frozen_namespace?(identity), do: {:error, :source_use_denied}, else: unmanaged_capture_write(staging))
        [enrollment] ->
          if change_kind == :delete and enrollment["source_id"] == identity["source_id"] do
            :ok
          else
          if change_kind == :unchanged and enrollment["state"] == "bound" and
             enrollment["source_id"] == identity["source_id"] do
            with {:ok, set} <- owned_set(enrollment["set_id"]),
                 :ok <- frozen_header_integrity(set),
                 true <- set.state == "active" and set.quarantined === false and
                   set.policy_generation == enrollment["grant_generation"],
                 [_] <- Corpora.rows("SELECT source_id FROM local_use_items WHERE workspace_id=? AND set_id=? AND source_id=? AND revision_id=? AND body_hash=?", [Store.workspace(), set.id, identity["source_id"], identity["revision_id"], identity["body_hash"]]),
                 :ok <- RevisionUseHolds.assert_source_unheld(identity["source_id"]), do: :ok,
              else: (_ -> checked_staging_write(staging, identity))
          else
            checked_staging_write(staging, identity)
          end
          end
        _ -> {:error, :source_use_denied}
      end
    else
      _ -> {:error, :invalid_input}
    end
  rescue
    _ -> {:error, :source_use_denied}
  end
  def assert_storage_transition(_, _, _), do: {:error, :invalid_input}

  @doc false
  def namespace_digest(identity), do: Contracts.digest(Map.merge(Map.take(identity,
    ~w(connection_id provider external_id)), %{"version" => "LocalUseNamespace.v1", "workspace_id" => Store.workspace()}))

  @doc false
  def active_enrollments(set, generation) do
    with true <- set.quarantined === false and set.state == "active" and set.policy_generation == generation,
         :ok <- frozen_header_integrity(set),
         [%{"total" => total, "invalid" => 0}] <- Corpora.rows("SELECT count(*) AS total,coalesce(sum(CASE WHEN e.original_source_id=i.source_id AND e.connection_id=? AND e.provider='local' AND e.external_id=i.capture_item_key AND e.grant_generation=? AND ((e.state='bound' AND e.source_id=i.source_id AND e.set_id=i.set_id) OR (e.state='purged_denied' AND e.source_id IS NULL AND e.set_id IS NULL)) THEN 0 ELSE 1 END),0) AS invalid FROM local_use_items i LEFT JOIN local_use_enrollments e ON e.workspace_id=i.workspace_id AND e.original_source_id=i.source_id WHERE i.workspace_id=? AND i.set_id=?", [set.connection_id, generation, set.workspace_id, set.id]),
         true <- total == set.item_count, do: :ok,
      else: (_ -> {:error, :source_use_denied})
  end

  @doc "Validate retained immutable provenance without consulting deleted acquisition records."
  def frozen_integrity(%LocalUseSet{} = set) do
    frozen_integrity(set, frozen_items(set), Store.workspace(), Workspaces.operator())
  rescue
    _ -> {:error, :source_use_denied}
  end
  def frozen_integrity(_), do: {:error, :source_use_denied}

  @doc "Pure copied-database integrity check; items must be the exact ordered original manifest."
  def frozen_integrity(%LocalUseSet{} = set, items, expected_workspace, expected_owner)
      when is_list(items) do
    with :ok <- frozen_header_integrity(set, expected_workspace, expected_owner),
         true <- length(items) == set.item_count and set.item_count in 1..500 and
           Enum.all?(items, &valid_frozen_item?/1),
         source_ids = Enum.map(items, & &1["source_id"]),
         true <- source_ids == Enum.sort(Enum.uniq(source_ids)),
         manifest = Contracts.digest(%{"version" => "LocalUseManifest.v1", "basis" => set.basis_json, "items" => items}),
         true <- manifest == set.manifest_digest do
      :ok
    else
      _ -> {:error, :source_use_denied}
    end
  rescue
    _ -> {:error, :source_use_denied}
  end
  def frozen_integrity(_, _, _, _), do: {:error, :source_use_denied}

  @doc "Classify every original item as an exact bound enrollment or an explained namespace tombstone."
  def effective_enrollments(set, generation) do
    with true <- set.state == "active" and set.policy_generation == generation and positive?(generation),
         :ok <- frozen_integrity(set) do
      rows = Corpora.rows("SELECT i.source_id AS item_source_id,i.revision_id,i.body_hash,i.capture_item_key,e.id,e.workspace_id,e.original_source_id,e.source_id,e.set_id,e.connection_id,e.provider,e.external_id,e.namespace_digest,e.state,e.grant_generation FROM local_use_items i LEFT JOIN local_use_enrollments e ON e.workspace_id=i.workspace_id AND e.original_source_id=i.source_id WHERE i.workspace_id=? AND i.set_id=? ORDER BY i.source_id LIMIT 501", [set.workspace_id, set.id])
      Enum.reduce_while(rows, {:ok, []}, fn enrollment, {:ok, survivors} ->
            namespace_ok = enrollment["id"] != nil and enrollment["original_source_id"] == enrollment["item_source_id"] and
              enrollment["connection_id"] == set.connection_id and enrollment["provider"] == "local" and
              enrollment["external_id"] == enrollment["capture_item_key"] and
              enrollment["namespace_digest"] == namespace_digest(enrollment) and
              enrollment["grant_generation"] == generation
            cond do
              not namespace_ok -> {:halt, {:error, :source_use_denied}}
              enrollment["state"] == "purged_denied" and is_nil(enrollment["source_id"]) and is_nil(enrollment["set_id"]) -> {:cont, {:ok, survivors}}
              enrollment["state"] == "bound" and enrollment["source_id"] == enrollment["item_source_id"] and enrollment["set_id"] == set.id ->
                {:cont, {:ok, survivors ++ [Map.delete(enrollment, "item_source_id")]}}
              true -> {:halt, {:error, :source_use_denied}}
            end
      end)
    else
      _ -> {:error, :source_use_denied}
    end
  rescue
    _ -> {:error, :source_use_denied}
  end

  def refresh_source_set_digest(set) do
    with {:ok, survivors} <- effective_enrollments(set, set.policy_generation),
         true <- survivors != [], do: {:ok, Contracts.digest(source_ids(survivors))},
      else: (_ -> {:error, :source_use_denied})
  end

  @doc "Provenance-only recovery basis. It may inspect an active quarantined predecessor; it grants no use."
  def revalidation_basis(connection_id, policy_ref, context) do
    guarded(context, fn ->
      with true <- Corpora.uuid?(connection_id),
           {:ok, set} <- policy(policy_ref),
           true <- set.connection_id == connection_id,
           {:ok, survivors} <- effective_enrollments(set, set.policy_generation),
           true <- survivors != [],
           :ok <- unheld_survivors(survivors),
           :ok <- surviving_identity_provenance(set, length(survivors)),
           {:ok, connection} <- Store.get(Connection, connection_id),
           true <- connection.provider == "local",
           {:ok, digest} <- refresh_source_set_digest(set) do
        {:ok, {set, %{"policy_ref" => policy_ref, "policy_generation" => set.policy_generation,
          "source_set_digest" => digest, "effective_count" => length(survivors),
          "original_item_count" => set.item_count, "privacy_barrier" => LocalUseLifecycle.privacy_barrier()}}}
      else
        _ -> {:error, :source_use_denied}
      end
    end)
  end

  defp activate(attrs, {observed, observed_basis}) do
    with {:ok, replay} <- LocalUseLifecycle.replay("policy:" <> attrs["command_id"], Contracts.digest(attrs)) do
      if replay do
        replay_policy_receipt(replay)
      else
        with {:ok, set} <- preparation(attrs["preparation_ref"]),
             true <- set == observed and set.state == "prepared" and set.lock_version == 0,
             {:ok, fresh} <- capture_basis(capture_ref(set)),
             true <- fresh == observed_basis and fresh.basis == set.basis_json and
               manifest_digest(fresh) == set.manifest_digest,
             :ok <- capture_enrollment_scope(fresh),
             purposes = Enum.filter(@purposes, &(&1 in attrs["purposes"])),
             generation = if(set.predecessor_set_id, do: set.predecessor_generation + 1, else: 1),
             digest = policy_digest(set, purposes),
             changed = Corpora.query!("UPDATE local_use_sets SET state='active',policy_generation=?,purposes_json=?,retain_local=1,policy_digest=?,activated_at=?,lock_version=lock_version+1 WHERE workspace_id=? AND id=? AND state='prepared' AND lock_version=0", [generation, Jason.encode!(purposes), digest, Corpora.now(), Store.workspace(), set.id]),
             true <- changed.num_rows == 1,
             :ok <- enroll(set, fresh.items, generation),
             {:ok, event} <- LocalUseLifecycle.policy_event(if(set.predecessor_set_id, do: "refresh_activated", else: "activate"), set.id, "policy:" <> attrs["command_id"], Contracts.digest(attrs),
               %{"policy_generation" => generation, "predecessor_set_id" => set.predecessor_set_id,
                 "predecessor_generation" => set.predecessor_generation}) do
          receipt_for_event(event)
        else
          false -> {:error, :preparation_stale}
          error -> error
        end
      end
    end
  end

  defp enroll(%{predecessor_set_id: nil} = set, items, generation) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      identity = Map.merge(item, %{"connection_id" => set.connection_id, "provider" => "local"})
      if enrollments(identity) == [] do
        Repo.insert!(%LocalUseEnrollment{workspace_id: Store.workspace(), source_id: item["source_id"], original_source_id: item["source_id"],
          set_id: set.id, connection_id: set.connection_id, provider: "local", external_id: item["external_id"],
          namespace_digest: namespace_digest(identity), grant_generation: generation})
        {:cont, :ok}
      else
        {:halt, {:error, :source_policy_conflict}}
      end
    end)
  end
  defp enroll(set, _items, generation) do
    with {:ok, predecessor} <- owned_set(set.predecessor_set_id),
         {:ok, survivors} <- effective_enrollments(predecessor, set.predecessor_generation),
         true <- source_ids(frozen_items(set)) == source_ids(survivors),
         changed = Corpora.query!("UPDATE local_use_enrollments SET set_id=?,grant_generation=? WHERE workspace_id=? AND set_id=? AND grant_generation=? AND state='bound'", [set.id, generation, Store.workspace(), predecessor.id, predecessor.policy_generation]),
         true <- changed.num_rows == set.item_count,
         prior = Corpora.query!("UPDATE local_use_sets SET state='superseded',lock_version=lock_version+1 WHERE workspace_id=? AND id=? AND state='active' AND policy_generation=?", [Store.workspace(), predecessor.id, predecessor.policy_generation]),
         true <- prior.num_rows == 1, do: :ok,
      else: (_ -> {:error, :policy_generation_conflict})
  end

  defp observe_capture(ref, caller), do: Corpora.guard(caller, fn -> capture_basis(ref) end)

  defp capture_basis(ref) do
    with {:ok, binding} <- SetupCapture.binding(ref["id"]),
         true <- binding.owner_id == Workspaces.operator() and binding.digest == ref["digest"],
         {:ok, run} <- Store.get(CaptureRun, binding.capture_id),
         true <- run.state in ~w(scan_complete cancelled failed) and run.connection_id == binding.connection_id,
         {:ok, config} <- Store.get(SetupRunConfig, binding.config_id),
         true <- config.owner_id == binding.owner_id and config.session_id == binding.session_id and
           config.digest == Contracts.digest(config.scope_json),
         [command] <- Repo.all(from c in Store.scoped(SetupRunCommand), where:
           c.owner_id == ^binding.owner_id and c.session_id == ^binding.session_id and
           c.command_id == ^binding.command_id),
         true <- command.request_digest == Contracts.digest(command.request_json) and
           command.request_json["action"] == "acquire" and command.run_id == binding.run_id,
         true <- valid_binding?(binding, config),
         {:ok, connection} <- local_connection(binding.connection_id),
         true <- config.scope_json["connection_id"] == connection.id and
           config.scope_json["root_fingerprint"] == binding.root_fingerprint and
           run.root_fingerprint == binding.root_fingerprint and
           run.counts["setup_connection_digest"] == connection_digest(connection),
         items = captured_items(run),
         true <- length(items) in 1..500,
         :ok <- exact_items(items, connection.id),
         {:ok, refresh} <- LocalUseLifecycle.refresh_for_capture(run.id) do
      basis = %{"origin_workspace_id" => Store.workspace(), "capture_id" => run.id, "binding_digest" => binding.digest,
        "config_ref" => %{"id" => config.id, "digest" => config.digest},
        "acquire_command_ref" => %{"id" => command.id, "digest" => command.request_digest},
        "acquire_command_id" => binding.command_id, "connection_id" => connection.id,
        "connection_digest" => connection_digest(connection), "root_fingerprint" => binding.root_fingerprint,
        "capture_version" => run.lock_version, "checkpoint_seq" => run.checkpoint_seq,
        "scan_epoch" => run.scan_epoch, "capture_state" => run.state,
        "capture_complete" => run.state == "scan_complete" and run.scan_verified and not run.incomplete,
        "refresh" => refresh}
      {:ok, %{basis: basis, items: items, connection: connection}}
    else
      false -> {:error, :preparation_stale}
      {:error, _} = error -> error
      _ -> {:error, :preparation_stale}
    end
  end

  defp valid_binding?(binding, config) do
    immutable = %{"run_id" => binding.run_id, "config_ref" => %{"id" => config.id, "digest" => config.digest},
      "capture_id" => binding.capture_id, "command_id" => binding.command_id,
      "connection_id" => binding.connection_id, "root_fingerprint" => binding.root_fingerprint,
      "limits" => binding.limits_json, "accepted_at" => DateTime.to_iso8601(binding.accepted_at),
      "deadline" => DateTime.to_iso8601(binding.deadline)}
    binding.digest == Contracts.digest(immutable) and binding.limits_json == SetupCapture.limits() and
      config.scope_json["capture_limits"] == binding.limits_json
  end

  defp captured_items(run), do: Corpora.rows("SELECT ci.source_id,ci.revision_id,ci.body_hash,ci.relative_path AS capture_item_key,s.external_id FROM capture_items ci JOIN evidence_sources s ON s.id=ci.source_id AND s.workspace_id=? WHERE ci.run_id=? AND ci.scan_epoch=? AND ci.state IN('captured','unchanged') ORDER BY ci.source_id LIMIT 501", [Store.workspace(), run.id, run.scan_epoch])

  defp exact_items(items, connection_id) do
    with true <- length(Enum.uniq_by(items, & &1["source_id"])) == length(items) do
      Enum.reduce_while(items, :ok, fn item, :ok ->
        case current_identity(Map.take(item, ~w(source_id revision_id body_hash))) do
          {:ok, identity} ->
            case RevisionUseHolds.assert_source_unheld(item["source_id"]) do
              :ok ->
                if identity["connection_id"] == connection_id and identity["provider"] == "local",
                  do: {:cont, :ok}, else: {:halt, {:error, :preparation_stale}}
              _ -> {:halt, {:error, :source_use_denied}}
            end
          _ -> {:halt, {:error, :preparation_stale}}
        end
      end)
    else
      _ -> {:error, :preparation_stale}
    end
  end

  defp capture_enrollment_scope(%{basis: %{"refresh" => nil}} = fresh) do
    if Enum.all?(fresh.items, fn item ->
      enrollments(Map.merge(item, %{"connection_id" => fresh.connection.id, "provider" => "local"})) == []
    end), do: :ok, else: {:error, :source_policy_conflict}
  end
  defp capture_enrollment_scope(fresh) do
    refresh = fresh.basis["refresh"]
    with {:ok, prior} <- policy(refresh["policy_ref"]),
         {:ok, survivors} <- effective_enrollments(prior, refresh["policy_generation"]),
         :ok <- unheld_survivors(survivors),
         :ok <- refresh_barrier(refresh),
         {:ok, source_digest} <- refresh_source_set_digest(prior),
         true <- prior.connection_id == fresh.connection.id and prior.root_fingerprint == fresh.basis["root_fingerprint"],
         true <- source_ids(fresh.items) == source_ids(survivors) and
           source_digest == refresh["source_set_digest"], do: :ok,
      else: (_ -> {:error, :refresh_scope_incomplete})
  end

  defp freeze_preparation(fresh) do
    manifest = manifest_digest(fresh)
    digest = Contracts.digest(%{"version" => "LocalUsePreparation.v1", "workspace_id" => Store.workspace(),
      "owner_id" => Workspaces.operator(), "basis" => fresh.basis, "manifest_digest" => manifest})
    existing = Repo.one(from s in Store.scoped(LocalUseSet), where: s.owner_id == ^Workspaces.operator() and s.preparation_digest == ^digest)
    if existing do
      {:ok, existing}
    else
      refresh = fresh.basis["refresh"]
      {:ok, set} = Repo.insert(%LocalUseSet{workspace_id: Store.workspace(), origin_workspace_id: Store.workspace(), owner_id: Workspaces.operator(),
        capture_id: fresh.basis["capture_id"], binding_digest: fresh.basis["binding_digest"],
        config_id: fresh.basis["config_ref"]["id"], config_digest: fresh.basis["config_ref"]["digest"],
        acquire_command_id: fresh.basis["acquire_command_id"], connection_id: fresh.connection.id,
        connection_digest: fresh.basis["connection_digest"], root_fingerprint: fresh.basis["root_fingerprint"],
        preparation_digest: digest, manifest_digest: manifest, item_count: length(fresh.items),
        basis_json: fresh.basis, predecessor_set_id: if(refresh, do: refresh["policy_ref"]["id"]),
        predecessor_generation: if(refresh, do: refresh["policy_generation"]), prepared_at: Store.now()})
      Enum.each(fresh.items, fn item -> Repo.insert!(%LocalUseItem{set_id: set.id, workspace_id: Store.workspace(),
        source_id: item["source_id"], revision_id: item["revision_id"], body_hash: item["body_hash"],
        capture_item_key: item["capture_item_key"]}) end)
      {:ok, set}
    end
  end

  defp manifest_digest(fresh), do: Contracts.digest(%{"version" => "LocalUseManifest.v1", "basis" => fresh.basis,
    "items" => Enum.map(fresh.items, &Map.take(&1, ~w(source_id revision_id body_hash capture_item_key)))})
  defp policy_digest(set, purposes), do: Contracts.digest(%{"version" => "LocalUsePolicy.v1",
    "workspace_id" => set.workspace_id, "owner_id" => set.owner_id, "preparation_digest" => set.preparation_digest,
    "manifest_digest" => set.manifest_digest, "basis" => set.basis_json, "purposes" => purposes, "retain_local" => true})

  defp preparation_digest(set, manifest), do: Contracts.digest(%{"version" => "LocalUsePreparation.v1",
    "workspace_id" => set.workspace_id, "owner_id" => set.owner_id,
    "basis" => set.basis_json, "manifest_digest" => manifest})

  defp frozen_items(set), do: Corpora.rows("SELECT source_id,revision_id,body_hash,capture_item_key FROM local_use_items WHERE workspace_id=? AND set_id=? ORDER BY source_id LIMIT 501", [set.workspace_id, set.id])

  defp frozen_header_integrity(set) do
    frozen_header_integrity(set, Store.workspace(), Workspaces.operator())
  rescue
    _ -> {:error, :source_use_denied}
  end

  defp frozen_header_integrity(%LocalUseSet{} = set, expected_workspace, expected_owner) do
    basis = set.basis_json
    with true <- Corpora.uuid?(expected_workspace) and Corpora.text?(expected_owner, 128) and
           set.workspace_id == expected_workspace and set.owner_id == expected_owner and
           Corpora.uuid?(set.id) and Corpora.uuid?(set.origin_workspace_id) and
           is_boolean(set.quarantined) and set.item_count in 1..500 and
           valid_basis?(basis) and basis["origin_workspace_id"] == set.origin_workspace_id and
           basis["capture_id"] == set.capture_id and basis["binding_digest"] == set.binding_digest and
           basis["config_ref"] == %{"id" => set.config_id, "digest" => set.config_digest} and
           basis["acquire_command_id"] == set.acquire_command_id and basis["connection_id"] == set.connection_id and
           basis["connection_digest"] == set.connection_digest and basis["root_fingerprint"] == set.root_fingerprint and
           Corpora.digest?(set.manifest_digest) and
           set.preparation_digest == preparation_digest(set, set.manifest_digest) and
           predecessor_basis?(set) and frozen_state?(set), do: :ok,
      else: (_ -> {:error, :source_use_denied})
  rescue
    _ -> {:error, :source_use_denied}
  end
  defp frozen_header_integrity(_, _, _), do: {:error, :source_use_denied}

  defp valid_basis?(basis) do
    Corpora.keys(basis, ~w(origin_workspace_id capture_id binding_digest config_ref acquire_command_ref acquire_command_id connection_id connection_digest root_fingerprint capture_version checkpoint_seq scan_epoch capture_state capture_complete refresh)) == :ok and
      Enum.all?(~w(origin_workspace_id capture_id acquire_command_id connection_id), &Corpora.uuid?(basis[&1])) and
      Enum.all?(~w(binding_digest connection_digest root_fingerprint), &Corpora.digest?(basis[&1])) and
      ref?(basis["config_ref"]) and ref?(basis["acquire_command_ref"]) and
      positive?(basis["capture_version"]) and nonnegative?(basis["checkpoint_seq"]) and
      positive?(basis["scan_epoch"]) and basis["capture_state"] in ~w(scan_complete cancelled failed) and
      is_boolean(basis["capture_complete"]) and
      (not basis["capture_complete"] or basis["capture_state"] == "scan_complete") and
      valid_refresh_basis?(basis["refresh"], basis)
  end

  defp valid_refresh_basis?(nil, _), do: true
  defp valid_refresh_basis?(refresh, basis) do
    Corpora.keys(refresh, ~w(refresh_ref policy_ref policy_generation source_set_digest capture_id binding_digest privacy_barrier)) == :ok and
      ref?(refresh["refresh_ref"]) and ref?(refresh["policy_ref"]) and
      positive?(refresh["policy_generation"]) and Corpora.digest?(refresh["source_set_digest"]) and
      refresh["capture_id"] == basis["capture_id"] and refresh["binding_digest"] == basis["binding_digest"] and
      valid_privacy_barrier?(refresh["privacy_barrier"])
  end

  defp valid_privacy_barrier?(nil), do: true
  defp valid_privacy_barrier?(barrier), do: Corpora.keys(barrier, ~w(id sequence)) == :ok and
    Corpora.uuid?(barrier["id"]) and positive?(barrier["sequence"])

  defp valid_frozen_item?(item), do: Corpora.keys(item, ~w(source_id revision_id body_hash capture_item_key)) == :ok and
    Corpora.uuid?(item["source_id"]) and Corpora.uuid?(item["revision_id"]) and Corpora.digest?(item["body_hash"]) and
    Corpora.text?(item["capture_item_key"], 4096) and Path.type(item["capture_item_key"]) == :relative and
    ".." not in Path.split(item["capture_item_key"])

  defp predecessor_basis?(%{predecessor_set_id: nil, predecessor_generation: nil, basis_json: %{"refresh" => nil}}), do: true
  defp predecessor_basis?(set) do
    refresh = set.basis_json["refresh"]
    is_map(refresh) and set.predecessor_set_id == refresh["policy_ref"]["id"] and
      set.predecessor_generation == refresh["policy_generation"]
  end

  defp frozen_state?(%{state: "prepared"} = set), do: set.policy_generation == 0 and set.lock_version == 0 and
    set.purposes_json == [] and set.retain_local === false and is_nil(set.policy_digest) and
    is_nil(set.activated_at) and is_nil(set.withdrawn_at) and set.quarantined === false
  defp frozen_state?(%{state: state} = set) when state in ~w(active withdrawn superseded) do
    activation_generation = (set.predecessor_generation || 0) + 1
    expected = if state == "withdrawn", do: activation_generation + 1, else: activation_generation
    set.policy_generation == expected and set.lock_version >= 1 and set.retain_local === true and
      valid_purposes?(set.purposes_json) and set.purposes_json == Enum.filter(@purposes, &(&1 in set.purposes_json)) and
      not is_nil(set.activated_at) and (state != "withdrawn" or not is_nil(set.withdrawn_at)) and
      set.policy_digest == policy_digest(set, set.purposes_json)
  end
  defp frozen_state?(_), do: false

  defp refresh_barrier(refresh) when is_map(refresh) do
    if Map.has_key?(refresh, "privacy_barrier") and valid_privacy_barrier?(refresh["privacy_barrier"]) and
      refresh["privacy_barrier"] == LocalUseLifecycle.privacy_barrier(), do: :ok,
      else: {:error, :preparation_stale}
  end
  defp refresh_barrier(_), do: {:error, :preparation_stale}

  defp unheld_survivors(survivors) do
    Enum.reduce_while(survivors, :ok, fn item, :ok ->
      case RevisionUseHolds.assert_source_unheld(item["source_id"]) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp surviving_identity_provenance(set, expected) do
    case Corpora.rows("SELECT count(*) AS n FROM local_use_enrollments e JOIN local_use_items i ON i.workspace_id=e.workspace_id AND i.set_id=e.set_id AND i.source_id=e.original_source_id JOIN evidence_sources s ON s.workspace_id=e.workspace_id AND s.id=e.source_id AND s.connection_id=e.connection_id AND s.provider=e.provider AND s.external_id=e.external_id JOIN evidence_revisions r ON r.workspace_id=s.workspace_id AND r.source_id=s.id AND r.id=i.revision_id AND r.body_hash=i.body_hash WHERE e.workspace_id=? AND e.set_id=? AND e.state='bound' AND e.grant_generation=?", [set.workspace_id, set.id, set.policy_generation]) do
      [%{"n" => ^expected}] -> :ok
      _ -> {:error, :source_use_denied}
    end
  end

  defp replay_policy_receipt(event) do
    with {:ok, set} <- owned_set(event["set_id"]),
         :ok <- frozen_integrity(set),
         :ok <- replay_refresh_barrier(set), do: receipt(set, event)
  end
  defp replay_refresh_barrier(%{predecessor_set_id: nil}), do: :ok
  defp replay_refresh_barrier(set), do: refresh_barrier(set.basis_json["refresh"])

  defp preparation_dto(set), do: %{"version" => "LocalUsePreparation.v1", "id" => set.id,
    "digest" => set.preparation_digest, "state" => set.state, "version_number" => set.lock_version,
    "capture_ref" => capture_ref(set), "item_count" => set.item_count,
    "capture_completeness" => Map.take(set.basis_json, ~w(capture_state capture_complete)),
    "purpose_choices" => @purposes, "selected_purposes" => [], "retention_acknowledged" => false,
    "quarantined" => set.quarantined, "provenance_status" => "historical_capture_attestation"}

  defp receipt_for_event(event) do
    with {:ok, set} <- owned_set(event["set_id"]), do: receipt(set, event)
  end
  defp receipt(set) do
    with :ok <- frozen_integrity(set), do: existing_receipt(set)
  end
  defp existing_receipt(set) do
    case Corpora.rows("SELECT id FROM local_use_events WHERE workspace_id=? AND set_id=? AND kind IN('activate','refresh_activated','withdraw') ORDER BY sequence DESC LIMIT 1", [Store.workspace(), set.id]) do
      [%{"id" => id}] -> with {:ok, event} <- LocalUseLifecycle.event(id), do: receipt(set, event)
      [] -> {:ok, preparation_dto(set)}
    end
  end
  defp receipt(set, event) do
    with :ok <- frozen_integrity(set),
         {:ok, effective_count} <- receipt_effective_count(set),
         {:ok, checkpoint} <- LocalUseLifecycle.checkpoint(event["id"]) do
      {:ok, %{"version" => "LocalUsePolicy.v1", "id" => set.id, "digest" => set.policy_digest,
        "state" => set.state, "policy_generation" => set.policy_generation, "event_id" => event["id"],
        "cleanup_state" => checkpoint["state"], "cleanup_version" => checkpoint["lock_version"],
        "purposes" => set.purposes_json, "item_count" => set.item_count, "effective_count" => effective_count,
        "quarantined" => set.quarantined, "provenance_status" => "historical_capture_attestation",
        "retention" => if(set.state == "active", do: "explicit_local_operator_permission", else: "permission_withdrawn_use_blocked"),
        "historical_eligibility" => "unavailable"}}
    end
  end

  defp receipt_effective_count(%{state: "active"} = set) do
    with {:ok, survivors} <- effective_enrollments(set, set.policy_generation), do: {:ok, length(survivors)}
  end
  defp receipt_effective_count(_), do: {:ok, nil}

  defp guarded(%SourceUseContext{} = context, fun) do
    with {:ok, %{kind: :interactive}} <- SourceUseContext.validate(context, "inspection") do
      Corpora.guard(context.caller, fn ->
        with {:ok, _} <- SourceUseContext.validate(context, "inspection"),
             {:ok, result} <- fun.(), {:ok, _} <- SourceUseContext.validate(context, "inspection"), do: {:ok, result}
      end)
    end
  rescue
    _ -> {:error, :source_use_denied}
  end
  defp guarded(_, _), do: {:error, :source_context_invalid}
  defp owned_set(id) do
    with {:ok, set} <- Store.get(LocalUseSet, id),
         true <- set.owner_id == Workspaces.operator(), do: {:ok, set},
      else: (_ -> {:error, :source_use_denied})
  end
  defp preparation(ref) do
    with true <- ref?(ref), {:ok, set} <- owned_set(ref["id"]),
         :ok <- frozen_integrity(set),
         true <- set.preparation_digest == ref["digest"], do: {:ok, set},
      else: (_ -> {:error, :preparation_stale})
  end
  defp policy(ref) do
    with true <- ref?(ref), {:ok, set} <- owned_set(ref["id"]),
         :ok <- frozen_integrity(set),
         true <- set.policy_digest == ref["digest"], do: {:ok, set},
      else: (_ -> {:error, :source_use_denied})
  end

  defp current_identity(ref) do
    case Corpora.rows("SELECT s.workspace_id,s.id AS source_id,s.connection_id,s.provider,s.external_id,s.latest_revision_id,s.status AS source_status,r.id AS revision_id,r.body_hash,r.captured_at,r.source_url,r.metadata,c.provider AS connection_provider,c.status AS connection_status,c.config FROM evidence_sources s JOIN evidence_revisions r ON r.source_id=s.id AND r.workspace_id=s.workspace_id JOIN source_connections c ON c.id=s.connection_id AND c.workspace_id=s.workspace_id WHERE s.workspace_id=? AND s.id=? AND r.id=? AND r.body_hash=?", [Store.workspace(), ref["source_id"], ref["revision_id"], ref["body_hash"]]) do
      [row] ->
        with true <- row["source_status"] == "active" and row["connection_status"] == "active" and
               row["latest_revision_id"] == row["revision_id"] and row["provider"] == row["connection_provider"],
             :ok <- HarnessForge.Connectors.Registry.document_scope(%{id: row["connection_id"], provider: row["provider"], config: decode(row["config"])}, %{"external_id" => row["external_id"], "source_url" => row["source_url"], "metadata" => decode(row["metadata"])}), do: {:ok, row},
          else: (_ -> {:error, :source_unavailable})
      _ -> {:error, :source_unavailable}
    end
  end
  defp enrollments(identity), do: Corpora.rows("SELECT id,source_id,set_id,state,grant_generation,namespace_digest FROM local_use_enrollments WHERE workspace_id=? AND (source_id=? OR (connection_id=? AND provider=? AND external_id=?)) LIMIT 2", [Store.workspace(), identity["source_id"], identity["connection_id"], identity["provider"], identity["external_id"]])

  defp frozen_namespace?(identity), do: Corpora.rows("SELECT history.source_id FROM local_use_items history JOIN local_use_sets grantset ON grantset.id=history.set_id AND grantset.workspace_id=history.workspace_id WHERE history.workspace_id=? AND grantset.state IN('active','withdrawn','superseded') AND grantset.policy_generation>0 AND (history.source_id=? OR (grantset.connection_id=? AND ?='local' AND history.capture_item_key=?)) LIMIT 1", [Store.workspace(), identity["source_id"], identity["connection_id"], identity["provider"], identity["external_id"]]) != []

  defp decision_facts(_corpus, purpose, context, %{kind: :setup_analysis, manifest_ref: manifest}) do
    refs = Corpora.rows("SELECT DISTINCT source_id,revision_id,content_hash AS body_hash FROM origin_dependencies WHERE workspace_id=? AND manifest_id=? AND kind='source_revision' ORDER BY source_id,revision_id LIMIT 501", [Store.workspace(), manifest["id"]])
    if length(refs) in 1..500 do
      admitted = Enum.reduce_while(refs, :ok, fn ref, :ok ->
        case assert_use(ref, purpose, context) do
          result when result in [:ok, :legacy_unknown] -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
      with :ok <- admitted do
        [count] = Corpora.rows("SELECT count(DISTINCT d.source_id) AS total,count(DISTINCT CASE WHEN EXISTS(SELECT 1 FROM local_use_enrollments e WHERE e.workspace_id=d.workspace_id AND (e.source_id=d.source_id OR (e.connection_id=s.connection_id AND e.provider=s.provider AND e.external_id=s.external_id))) THEN d.source_id ELSE NULL END) AS managed FROM origin_dependencies d JOIN evidence_sources s ON s.id=d.source_id AND s.workspace_id=d.workspace_id WHERE d.workspace_id=? AND d.manifest_id=? AND d.kind='source_revision'", [Store.workspace(), manifest["id"]])
        with {:ok, policies} <- policy_pages(:manifest, manifest["id"], "", []),
          do: {:ok, %{total: count["total"], managed: count["managed"], policies: policies}}
      end
    else
      {:error, :policy_manifest_limit}
    end
  end
  defp decision_facts(corpus, purpose, context, _) do
    with :ok <- assert_corpus_use(corpus, purpose, context), do: corpus_policy_facts(corpus)
  end

  defp corpus_policy_facts(corpus) do
    [count] = Corpora.rows("SELECT count(*) AS total,coalesce(sum(CASE WHEN EXISTS(SELECT 1 FROM local_use_enrollments e WHERE e.workspace_id=m.workspace_id AND (e.source_id=m.source_id OR (e.connection_id=s.connection_id AND e.provider=s.provider AND e.external_id=s.external_id))) THEN 1 ELSE 0 END),0) AS managed FROM corpus_members m JOIN evidence_sources s ON s.id=m.source_id AND s.workspace_id=m.workspace_id WHERE m.workspace_id=? AND m.corpus_id=? AND m.status='active'", [Store.workspace(), corpus])
    if count["managed"] > 0 and count["total"] > 500 do
      {:error, :policy_manifest_limit}
    else
      with {:ok, policies} <- policy_pages(:corpus, corpus, "", []) do
        {:ok, %{total: count["total"], managed: count["managed"], policies: policies}}
      end
    end
  end

  defp policy_pages(kind, scope, after_id, collected) do
    {join, where} = case kind do
      :corpus -> {"JOIN corpus_members m ON m.source_id=e.source_id AND m.workspace_id=e.workspace_id", "m.workspace_id=? AND m.corpus_id=? AND m.status='active'"}
      :manifest -> {"JOIN origin_dependencies m ON m.source_id=e.source_id AND m.workspace_id=e.workspace_id", "m.workspace_id=? AND m.manifest_id=? AND m.kind='source_revision'"}
    end
    page = Corpora.rows("SELECT DISTINCT p.id,p.policy_digest AS digest,p.policy_generation AS generation FROM local_use_enrollments e JOIN local_use_sets p ON p.id=e.set_id AND p.workspace_id=e.workspace_id #{join} WHERE #{where} AND p.id>? ORDER BY p.id LIMIT 101", [Store.workspace(), scope, after_id])
    visible = Enum.take(page, 100)
    checked = Enum.all?(visible, fn row ->
      case owned_set(row["id"]) do
        {:ok, set} -> set.state == "active" and set.policy_digest == row["digest"] and
          set.policy_digest == policy_digest(set, set.purposes_json) and
          set.policy_generation == row["generation"]
        _ -> false
      end
    end)
    cond do
      not checked -> {:error, :source_use_denied}
      length(collected) + length(visible) > 500 -> {:error, :policy_manifest_limit}
      length(page) > 100 -> policy_pages(kind, scope, List.last(visible)["id"], collected ++ visible)
      true -> {:ok, collected ++ visible}
    end
  end

  defp checked_context(nil, purpose) when purpose in @purposes, do: {:ok, nil}
  defp checked_context(_, purpose) when purpose not in @purposes, do: {:error, :unsupported_purpose}
  defp checked_context(context, purpose), do: SourceUseContext.validate(context, purpose)
  defp revalidate_context(nil, purpose) when purpose in @purposes, do: :ok
  defp revalidate_context(context, purpose), do: with {:ok, _} <- checked_context(context, purpose), do: :ok
  defp required_purposes("inspection"), do: ["inspection"]
  defp required_purposes("retrieval"), do: ~w(inspection retrieval)
  defp required_purposes("analysis"), do: ~w(inspection retrieval analysis)
  defp required_purposes("compile"), do: ~w(inspection compile)
  defp valid_staging?(staging), do: Corpora.keys(staging, ~w(capture_id lease_token relative_path)) == :ok and
    Corpora.uuid?(staging["capture_id"]) and Corpora.text?(staging["lease_token"], 256) and
    Corpora.text?(staging["relative_path"], 4096)
  defp checked_staging_write(staging, identity) do
    if valid_staging?(staging) do
      LocalUseLifecycle.assert_refresh_write(staging["capture_id"], staging["lease_token"],
        staging["relative_path"], identity)
    else
      {:error, :unsupported_revision_update}
    end
  end
  defp unmanaged_capture_write(nil), do: :ok
  defp unmanaged_capture_write(staging) do
    case SetupCapture.binding(staging["capture_id"]) do
      {:error, :not_found} -> :ok
      {:ok, _} ->
        case LocalUseLifecycle.refresh_for_capture(staging["capture_id"]) do
          {:ok, nil} -> :ok
          _ -> {:error, :source_use_denied}
        end
      _ -> {:error, :source_use_denied}
    end
  end
  defp manifest_sql(%{kind: :setup_analysis, manifest_ref: ref}), do: {"AND EXISTS(SELECT 1 FROM origin_dependencies d WHERE d.workspace_id=r.workspace_id AND d.manifest_id=? AND d.kind='source_revision' AND d.source_id=r.source_id AND d.revision_id=r.id AND d.content_hash=r.body_hash)", [ref["id"]]}
  defp manifest_sql(_), do: {"", []}
  defp manifest_member(nil, _), do: :ok
  defp manifest_member(%{kind: :interactive}, _), do: :ok
  defp manifest_member(%{kind: :setup_analysis, manifest_ref: manifest}, ref) do
    if Corpora.rows("SELECT 1 AS present FROM origin_dependencies WHERE workspace_id=? AND manifest_id=? AND kind='source_revision' AND source_id=? AND revision_id=? AND content_hash=? LIMIT 1", [Store.workspace(), manifest["id"], ref["source_id"], ref["revision_id"], ref["body_hash"]]) == [%{"present" => 1}], do: :ok, else: {:error, :source_use_denied}
  end
  defp valid_purposes?(values), do: is_list(values) and values != [] and length(Enum.uniq(values)) == length(values) and Enum.all?(values, &(&1 in @purposes)) and "inspection" in values and ("analysis" not in values or "retrieval" in values)
  defp input(attrs, keys, version), do: if(Corpora.keys(attrs, keys) == :ok and attrs["version"] == version, do: :ok, else: {:error, :invalid_input})
  defp exact_ref?(ref), do: Corpora.keys(ref, ~w(source_id revision_id body_hash)) == :ok and Corpora.uuid?(ref["source_id"]) and Corpora.uuid?(ref["revision_id"]) and Corpora.digest?(ref["body_hash"])
  defp ref?(ref), do: Corpora.keys(ref, ~w(id digest)) == :ok and Corpora.uuid?(ref["id"]) and Corpora.digest?(ref["digest"])
  defp nonnegative?(value), do: is_integer(value) and value >= 0
  defp positive?(value), do: is_integer(value) and value > 0
  defp capture_ref(set), do: %{"id" => set.capture_id, "digest" => set.binding_digest}
  defp connection_digest(connection), do: Contracts.digest(%{"directory" => connection.directory, "config" => connection.config})
  defp local_connection(id) do
    with {:ok, connection} <- Store.get(Connection, id), true <- connection.provider == "local" and connection.status == "active", do: {:ok, connection}, else: (_ -> {:error, :unsupported_provider})
  end
  defp physical_fingerprint(connection) do
    with false <- Repo.in_transaction?(), {:ok, root} <- LocalImport.approved_directory(connection.directory), do: Capture.fingerprint_for_setup(connection, root), else: (_ -> {:error, :preparation_stale})
  end
  defp source_ids(items), do: items |> Enum.map(& &1["source_id"]) |> Enum.sort()
  defp decode(value) when is_map(value), do: value
  defp decode(value), do: Jason.decode!(value)
end
