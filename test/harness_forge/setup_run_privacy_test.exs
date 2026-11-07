defmodule HarnessForge.SetupRunPrivacyTest do
  use ExUnit.Case, async: false

  alias HarnessForge.{Contracts, Evidence, Privacy, Repo}

  alias HarnessForge.Company.{
    SetupRun,
    SetupRunCommand,
    SetupRunConfig,
    SetupRunOperation,
    SetupRunPreparation,
    SetupRuns,
    SetupSession,
    SetupSessions
  }

  alias HarnessForge.Evidence.{SetupCaptureBinding, SetupCaptureCharge, Store}

  alias HarnessForge.Models.{
    Ledger,
    RunAuthorization,
    RunAuthorizationRecord,
    RunAuthorizationState,
    RunDisclosure
  }

  alias HarnessForge.SetupRunModelsFixture, as: F

  @moduletag :committed
  @tables ~w(setup_run_configs setup_runs setup_run_states setup_run_preparations setup_run_commands setup_run_operations model_run_authorizations model_run_authorization_states model_run_disclosures setup_capture_bindings setup_capture_counters setup_capture_charges setup_capture_pages)
  @digested [
    {"config", SetupRunConfig},
    {"run", SetupRun},
    {"preparation", SetupRunPreparation},
    {"authorization", RunAuthorizationRecord},
    {"disclosure", RunDisclosure},
    {"operation", SetupRunOperation}
  ]
  @budget_fields ~w(run_id max_requests max_tokens max_estimated_microusd reserved_requests reserved_tokens reserved_estimated_microusd)
  @request_fields ~w(id run_id request_id provider model fingerprint reserved_tokens reserved_estimated_microusd input_tokens output_tokens)

  setup do
    context = F.setup!()
    external = context.root <> "-privacy"
    File.mkdir_p!(external)
    on_exit(fn -> File.rm_rf!(external) end)
    Map.put(context, :external, external)
  end

  test "inventory covers all thirteen persisted setup record types and workspace purge removes their copied evidence",
       c do
    c = F.authorize!(c)
    assert length(@tables) == 13
    assert {:ok, inventory} = Privacy.inventory()

    for table <- @tables do
      count = F.rows(table)
      assert count > 0, "The public setup journey did not exercise #{table}"
      assert inventory["records"][table] == count
    end

    assert {:ok, _} = Privacy.purge_workspace(c.workspace)
    for table <- @tables, do: assert(F.rows(table) == 0)
    assert Repo.query!("PRAGMA foreign_key_check").rows == []
    assert {:error, _} = RunAuthorization.prepared_view(c.prepared["prepared_ref"], F.caller())
    assert {:error, _} = SetupRuns.get(c.session_id, F.caller())
  end

  test "source purge conservatively removes every setup derivative rather than retain copied prompts from a partial closure",
       c do
    c = F.authorize!(c)
    source = c.fixture.uncited_source
    retained = hd(c.fixture.sources)
    prepared = Repo.get!(SetupRunPreparation, c.prepared["prepared_ref"]["id"])
    assert byte_size(prepared.prompt_bytes) > 0
    assert byte_size(prepared.request_body_bytes) > 0

    assert {:ok, _} = Evidence.revoke_source(source["id"])
    assert {:ok, _} = Privacy.purge_source(source["id"], source["id"])
    for table <- @tables, do: assert(F.rows(table) == 0)
    assert Repo.get(SetupRunPreparation, prepared.id) == nil
    assert Repo.query!("PRAGMA foreign_key_check").rows == []
    assert {:error, _} = RunAuthorization.prepared_view(c.prepared["prepared_ref"], F.caller())
    assert {:ok, _} = Evidence.get_source(retained["id"])
  end

  test "real backup preserves exact settled predecessor usage and quarantined restore rehashes history without reissuing authority",
       c do
    c = F.authorize!(c)
    owner = self()

    Application.put_env(:harness_forge, :model_test_plug, fn conn ->
      send(owner, :original_provider_dispatch)
      Req.Test.json(conn, F.response(F.abstention()))
    end)

    assert {:ok, analysis} =
             F.command(c, "analyze", %{"prepared_ref" => c.prepared["prepared_ref"]})

    assert_received :original_provider_dispatch
    assert {:ok, prior_usage} = RunAuthorization.usage(c.view["run"]["run_ref"], F.caller())
    assert prior_usage["tokens_accounted"] == 18
    assert {:ok, _} = F.command(c, "cancel", %{})

    assert {:ok, successor} =
             F.command(c, "new_run", %{"predecessor_run_ref" => c.view["run"]["run_ref"]})

    assert {:ok, after_replacement} = RunAuthorization.usage(c.view["run"]["run_ref"], F.caller())
    assert after_replacement == prior_usage
    assert {:ok, proposed} = SetupRuns.get(c.session_id, F.caller())
    assert proposed["run"]["phase"] == "proposed"
    assert proposed["run"]["usage"]["budget_id"] == nil
    assert F.rows("model_budgets") == 1

    history = history_snapshot(c)
    {:ok, old_budget} = Ledger.budget(prior_usage["budget_id"])
    {:ok, [old_request]} = Ledger.list_requests(prior_usage["budget_id"])
    old_authorization_state = Repo.get_by!(RunAuthorizationState, workspace_id: c.workspace)
    backup = Path.join(c.external, "settled-backup")
    restored = Path.join(c.external, "settled-restored")
    assert {:ok, _} = Privacy.backup(backup)
    assert {:ok, _} = Privacy.verify_backup(backup)
    assert {:ok, result} = Privacy.restore(backup, restored)
    assert result["state"] == "quarantined"
    assert result["approvals_restored"] == false
    new_workspace = result["workspace_id"]
    refute new_workspace == c.workspace

    with_restored_repo(c, restored, new_workspace, fn ->
      assert_quarantined_history(c, history, new_workspace, restored)
      {:ok, restored_budget} = Ledger.budget(old_budget["run_id"])
      assert Map.take(restored_budget, @budget_fields) == Map.take(old_budget, @budget_fields)
      assert {:ok, [request]} = Ledger.list_requests(old_budget["run_id"])
      assert Map.take(request, @request_fields) == Map.take(old_request, @request_fields)
      assert request["state"] == "completed"
      assert request["usage_status"] == "reported"

      state = Repo.get!(RunAuthorizationState, old_authorization_state.id)
      assert state.revoked_at == old_authorization_state.revoked_at
      assert state.reason == old_authorization_state.reason
      current_run = Repo.get!(SetupRun, successor["run_ref"]["id"])

      assert {:error, _} =
               RunAuthorization.ready_for_run(RunAuthorization.ref(current_run), F.caller())

      assert {:error, _} = RunAuthorization.prepared_view(c.prepared["prepared_ref"], F.caller())

      assert {:error, _} =
               HarnessForge.Company.AnalysisV2.analyze_prepared(
                 analysis["operation_ref"],
                 F.caller()
               )

      refute_received :original_provider_dispatch
    end)
  end

  test "backup taken during actual dispatch preserves its reservation as uncertain and invalidates pending capture leases",
       c do
    c = F.authorize!(c)
    capture = interrupted_capture_fixture(c)
    backup = Path.join(c.external, "pending-backup")
    restored = Path.join(c.external, "pending-restored")
    history = history_snapshot(c)
    owner = self()
    {:ok, authorization} = RunAuthorization.ready_for_run(c.view["run"]["run_ref"], F.caller())

    Application.put_env(:harness_forge, :model_test_plug, fn conn ->
      {:ok, budget} = Ledger.budget(authorization["budget_id"])
      {:ok, [request]} = Ledger.list_requests(authorization["budget_id"])
      assert request["state"] == "dispatched"
      assert budget["reserved_requests"] == 1
      assert {:ok, _} = Privacy.backup(backup)
      send(owner, {:pending_backup, budget, request, history_snapshot(c)})
      Req.Test.json(conn, F.response(F.abstention()))
    end)

    assert {:ok, _} = F.command(c, "analyze", %{"prepared_ref" => c.prepared["prepared_ref"]})
    assert_received {:pending_backup, old_budget, old_request, dispatched_history}
    assert length(dispatched_history.rows) > length(history.rows)
    assert {:ok, result} = Privacy.restore(backup, restored)
    new_workspace = result["workspace_id"]

    with_restored_repo(c, restored, new_workspace, fn ->
      assert_quarantined_history(c, dispatched_history, new_workspace, restored)
      {:ok, budget} = Ledger.budget(authorization["budget_id"])
      assert Map.take(budget, @budget_fields) == Map.take(old_budget, @budget_fields)
      assert {:ok, [request]} = Ledger.list_requests(authorization["budget_id"])
      assert Map.take(request, @request_fields) == Map.take(old_request, @request_fields)
      assert request["state"] == "uncertain"
      assert request["usage_status"] == "unknown"
      assert request["billing_status"] == "unknown"
      state = Repo.get_by!(RunAuthorizationState, workspace_id: new_workspace)
      assert state.reason == "restored"
      assert not is_nil(state.revoked_at)

      assert [["cancelled", nil, nil]] =
               Repo.query!(
                 "SELECT state,lease_token,lease_until FROM capture_runs WHERE workspace_id=? AND id=?",
                 [new_workspace, capture.id]
               ).rows

      charge = Repo.get!(SetupCaptureCharge, capture.charge_id)
      assert charge.state == "uncertain"
      assert charge.allowance_bytes == capture.allowance
      assert {:error, _} = HarnessForge.Evidence.Capture.check_lease(capture.id, capture.lease)

      operation =
        Enum.find(dispatched_history.rows, fn {kind, row} ->
          kind == "operation" and row.kind == "analysis"
        end)
        |> elem(1)

      assert {:error, _} =
               HarnessForge.Company.AnalysisV2.analyze_prepared(
                 RunAuthorization.ref(operation),
                 F.caller()
               )

      refute_received {:pending_backup, _, _, _}
    end)
  end

  defp history_snapshot(c) do
    rows =
      Enum.flat_map(@digested, fn {kind, schema} ->
        for row <- Repo.all(schema), row.workspace_id == c.workspace, do: {kind, row}
      end)

    %{
      rows: rows,
      counts: Map.new(@tables, &{&1, F.rows(&1)}),
      prepared: Repo.get!(SetupRunPreparation, c.prepared["prepared_ref"]["id"])
    }
  end

  defp assert_quarantined_history(c, history, new_workspace, restored) do
    assert Repo.query!("PRAGMA foreign_key_check").rows == []

    for table <- @tables do
      assert F.rows(table) == history.counts[table]

      assert [[0]] =
               Repo.query!("SELECT count(*) FROM #{table} WHERE workspace_id=?", [c.workspace]).rows
    end

    assert [[0]] =
             Repo.query!(
               "SELECT count(*) FROM setup_run_states WHERE workspace_id=? AND phase!='cancelled'",
               [new_workspace]
             ).rows

    assert [[0]] =
             Repo.query!(
               "SELECT count(*) FROM model_run_authorization_states WHERE workspace_id=? AND revoked_at IS NULL",
               [new_workspace]
             ).rows

    assert [[0]] =
             Repo.query!(
               "SELECT count(*) FROM stage_operations WHERE workspace_id=? AND state!='cancelled'",
               [new_workspace]
             ).rows

    assert [[0]] =
             Repo.query!(
               "SELECT count(*) FROM stage_consent_revisions WHERE workspace_id=? AND state!='revoked'",
               [new_workspace]
             ).rows

    assert [[0]] =
             Repo.query!(
               "SELECT count(*) FROM source_connections WHERE workspace_id=? AND status!='revoked'",
               [new_workspace]
             ).rows

    assert [[0]] =
             Repo.query!("SELECT count(*) FROM model_settings WHERE workspace_id=?", [
               new_workspace
             ]).rows

    prepared = Repo.get!(SetupRunPreparation, history.prepared.id)

    for field <- [
          :checked_pack_json,
          :context_json,
          :prompt_bytes,
          :prompt_sha256,
          :request_body_bytes,
          :request_body_sha256
        ],
        do: assert(Map.fetch!(prepared, field) == Map.fetch!(history.prepared, field))

    mapping =
      Enum.map(history.rows, fn {kind, old} ->
        current = Repo.get!(old.__struct__, old.id)
        assert current.workspace_id == new_workspace

        expected =
          if kind in ~w(config run operation),
            do: SetupRuns.restore_digest(kind, current),
            else: elem(RunAuthorization.restore_digest(kind, current), 1)

        assert current.digest == expected
        if kind != "config", do: refute(current.digest == old.digest)
        %{"id" => old.id, "old_digest" => old.digest, "new_digest" => current.digest}
      end)
      |> Enum.sort_by(&{&1["id"], &1["old_digest"]})

    new_refs = Map.new(mapping, &{&1["id"], &1["new_digest"]})
    session = Repo.get!(SetupSession, c.session_id)
    assert_rewritten_refs(session.payload, new_refs)

    assert session.payload["refs"]["run_ref"]["digest"] ==
             new_refs[session.payload["refs"]["run_ref"]["id"]]

    for command <- Repo.all(SetupRunCommand), command.workspace_id == new_workspace do
      assert command.request_digest == Contracts.digest(command.request_json)

      assert command.receipt_json["command_ref"] == %{
               "id" => command.id,
               "digest" => command.request_digest
             }

      assert_rewritten_refs(command.request_json, new_refs)
      assert_rewritten_refs(command.receipt_json, new_refs)
    end

    [[encoded]] =
      Repo.query!(
        "SELECT details FROM audit_events WHERE workspace_id=? AND action='setup_history_quarantined'",
        [new_workspace]
      ).rows

    details = Jason.decode!(encoded)

    assert details == %{
             "status" => "restored_history_only",
             "actor" => c.workspace,
             "run_id" => new_workspace,
             "count" => length(mapping),
             "request_digest" => Contracts.digest(mapping)
           }

    assert details["count"] > 0
    assert String.match?(details["request_digest"], ~r/\A[0-9a-f]{64}\z/)
    restore = File.read!(Path.join(restored, "restore.json")) |> Jason.decode!()
    assert restore["source_workspace_id"] == c.workspace
    assert restore["new_workspace_id"] == new_workspace
    assert restore["state"] == "quarantined"
  end

  defp assert_rewritten_refs(%{"id" => id, "digest" => digest} = ref, refs)
       when map_size(ref) == 2 do
    if Map.has_key?(refs, id), do: assert(digest == refs[id])
  end

  defp assert_rewritten_refs(value, refs) when is_map(value),
    do: Enum.each(value, fn {_, child} -> assert_rewritten_refs(child, refs) end)

  defp assert_rewritten_refs(value, refs) when is_list(value),
    do: Enum.each(value, &assert_rewritten_refs(&1, refs))

  defp assert_rewritten_refs(_, _), do: :ok

  test "unrelated source purge keeps retired setup identities denied and unknown usage survives restore",
       c do
    c = F.authorize!(c)
    owner = self()

    Application.put_env(:harness_forge, :model_test_plug, fn conn ->
      send(owner, :retired_test_send)
      Req.Test.json(conn, %{"done" => true, "response" => Jason.encode!(F.abstention())})
    end)

    assert {:ok, receipt} =
             F.command(c, "analyze", %{"prepared_ref" => c.prepared["prepared_ref"]})

    assert_received :retired_test_send
    {:ok, usage} = RunAuthorization.usage(c.view["run"]["run_ref"], F.caller())
    assert usage["uncertain_requests"] == 1
    {:ok, budget} = Ledger.budget(usage["budget_id"])
    {:ok, [request]} = Ledger.list_requests(usage["budget_id"])
    {:ok, pin} = HarnessForge.Models.StageAuthority.load_pin(c.prepared["stage_ref"]["id"])
    unrelated = Path.join(c.root, "unrelated-public-evidence")
    File.mkdir_p!(unrelated)

    {:ok, connection} =
      Evidence.connect(%{
        "name" => "Unrelated public source",
        "provider" => "local",
        "directory" => unrelated
      })

    {:ok, source} =
      Evidence.import_markdown(connection["id"], %{
        "external_id" => "unrelated.md",
        "title" => "Unrelated",
        "body" => "Unrelated synthetic document."
      })

    assert {:ok, _} = Privacy.purge_source(source["id"], source["id"])
    for table <- @tables, do: assert(F.rows(table) == 0)
    # The unrelated source purge leaves this pin and consent in their owning
    # tables. Their erased setup records must not classify them as legacy.
    assert {:ok, ^pin} = HarnessForge.Models.StageAuthority.load_pin(pin["id"])

    assert Repo.query!("SELECT state FROM stage_consent_revisions WHERE workspace_id=?", [
             c.workspace
           ]).rows == [["active"]]

    assert_retired_denials(pin, receipt["operation_ref"]["id"], budget["run_id"])
    assert {:ok, ^budget} = Ledger.budget(budget["run_id"])
    assert {:ok, [^request]} = Ledger.list_requests(budget["run_id"])
    refute_received :retired_test_send

    backup = Path.join(c.external, "retired-backup")
    restored = Path.join(c.external, "retired-restored")
    assert {:ok, _} = Privacy.backup(backup)
    assert {:ok, result} = Privacy.restore(backup, restored)

    with_restored_repo(c, restored, result["workspace_id"], fn ->
      assert Repo.query!("PRAGMA foreign_key_check").rows == []
      assert_retired_denials(pin, receipt["operation_ref"]["id"], budget["run_id"])
      {:ok, copied} = Ledger.budget(budget["run_id"])
      assert Map.take(copied, @budget_fields) == Map.take(budget, @budget_fields)
      {:ok, [copied_request]} = Ledger.list_requests(budget["run_id"])
      assert Map.take(copied_request, @request_fields) == Map.take(request, @request_fields)
      assert copied_request["state"] == "uncertain"
      assert copied_request["usage_status"] == "unknown"
      assert Repo.query!("SELECT count(*) FROM model_settings").rows == [[0]]
    end)

    refute_received :retired_test_send
  end

  test "retirement append failure rolls back deletion and cannot leave a half-retired identity",
       c do
    c = F.authorize!(c)
    before = Map.new(@tables, &{&1, F.rows(&1)})

    Repo.query!("""
    CREATE TEMP TRIGGER setup_test_retirement_failure BEFORE INSERT ON audit_events
    WHEN NEW.workspace_id='#{c.workspace}' AND NEW.action='setup_pin_retired'
    BEGIN SELECT RAISE(ABORT,'synthetic retirement append failure'); END
    """)

    try do
      HarnessForge.Privacy.Purge.synchronize(fn ->
        Store.transaction(fn ->
          :ok = HarnessForge.Privacy.SetupHistory.purge("source")
          {:ok, :deleted}
        end)
      end)

      flunk("retirement append failure must abort the transaction")
    rescue
      error -> assert Exception.message(error) =~ "synthetic retirement append failure"
    after
      Repo.query!("DROP TRIGGER setup_test_retirement_failure")
    end

    assert Map.new(@tables, &{&1, F.rows(&1)}) == before

    assert Repo.query!(
             "SELECT count(*) FROM audit_events WHERE workspace_id=? AND action IN ('setup_budget_retired','setup_pin_retired','setup_operation_retired')",
             [c.workspace]
           ).rows == [[0]]

    assert {:ok, _} = RunAuthorization.ready_for_run(c.view["run"]["run_ref"], F.caller())
  end

  defp assert_retired_denials(pin, operation, budget) do
    assert RunAuthorization.setup_pin?(pin["id"])
    assert {:error, :authorization_required} = RunAuthorization.setup_consent_allowed(pin["id"])

    assert {:error, :authorization_required} =
             RunAuthorization.legacy_allowed(Ecto.UUID.generate(), [pin["id"]])

    for id <- [operation, budget] do
      assert {:error, :authorization_required} = RunAuthorization.legacy_budget_allowed(id)
      assert {:error, :authorization_required} = Ledger.start_run(id)
      assert {:error, :authorization_required} = Ledger.reopen_run(id)

      assert {:error, :authorization_required} =
               RunAuthorization.budget_for_operation(id, %{"id" => Ecto.UUID.generate()})
    end
  end

  defp with_restored_repo(c, directory, workspace, fun) do
    {:ok, restored_repo} =
      Repo.start_link(
        name: nil,
        database: Path.join(directory, "data.sqlite3"),
        pool: DBConnection.ConnectionPool,
        pool_size: 1
      )

    previous_repo = Repo.put_dynamic_repo(restored_repo)
    Application.put_env(:harness_forge, :workspace_id, workspace)
    Application.put_env(:harness_forge, :workspace_root, directory)

    try do
      fun.()
    after
      Repo.put_dynamic_repo(previous_repo)
      Application.put_env(:harness_forge, :workspace_id, c.workspace)
      Application.put_env(:harness_forge, :workspace_root, c.root)
      Supervisor.stop(restored_repo)
    end
  end

  defp interrupted_capture_fixture(c) do
    # A genuine accepted second acquisition supplies the owned capture binding.
    # Mutable lease and charge rows model a crash between reservation and read;
    # this fixture makes no scanner or physical interruption qualification claim.
    {:ok, original} = SetupSessions.get(%{"id" => c.session_id}, F.caller())
    {:ok, session} = SetupSessions.create(%{}, F.caller())

    {:ok, session} =
      F.session_command(session, "change", %{
        "selection" =>
          Map.take(original["selection"], ~w(profile project repository goal corpus_id))
      })

    {:ok, session} = F.session_command(session, "continue", %{})
    context = %{c | session_id: session["id"]}

    assert {:ok, _} =
             F.command(context, "prepare", %{
               "profile_version" => "setup-local-synthesis.v1",
               "connection_id" => c.fixture.connection["id"]
             })

    assert {:ok, acquisition} = F.command(context, "acquire", %{})
    capture_id = acquisition["operation_ref"]["id"]
    binding = Repo.get_by!(SetupCaptureBinding, workspace_id: c.workspace, capture_id: capture_id)
    lease = Ecto.UUID.generate()
    allowance = 17

    {:ok, charge} =
      Store.transaction(fn ->
        Repo.query!(
          "UPDATE capture_runs SET state='running',lease_token=?,lease_until=?,lock_version=lock_version+1 WHERE workspace_id=? AND id=?",
          [
            lease,
            DateTime.to_iso8601(DateTime.add(Store.now(), 120, :second)),
            c.workspace,
            capture_id
          ]
        )

        Repo.query!(
          "UPDATE setup_capture_counters SET files_reserved=1,bytes_reserved=?,lock_version=lock_version+1 WHERE workspace_id=? AND capture_id=?",
          [allowance, c.workspace, capture_id]
        )

        Repo.insert(%SetupCaptureCharge{
          workspace_id: c.workspace,
          owner_id: binding.owner_id,
          session_id: binding.session_id,
          capture_id: capture_id,
          kind: "body",
          relative_path: "interrupted.md",
          fingerprint_json: %{"synthetic" => "interrupted-metadata-fixture"},
          allowance_bytes: allowance,
          lease_generation: 1,
          lease_token: lease,
          state: "reserved"
        })
      end)

    %{id: capture_id, charge_id: charge.id, lease: lease, allowance: allowance}
  end
end
