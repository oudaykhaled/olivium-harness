defmodule HarnessForge.SetupRunRecoveryTest do
  use ExUnit.Case, async: false
  alias HarnessForge.{Repo, SetupRunModelsFixture}
  alias HarnessForge.Company.SetupRuns
  alias HarnessForge.Models.{Ledger, RunAuthorization}
  alias SetupRunModelsFixture, as: F
  @moduletag :committed
  setup do: F.setup!()

  test "closing an expired run preserves uncertain accounting and replays its one CAS transition",
       c do
    c = F.authorize!(c)
    owner = self()

    Application.put_env(:harness_forge, :model_test_plug, fn conn ->
      send(owner, :one_provider_attempt)
      # A protocol response without token counts creates genuine uncertain
      # accounting through the normal attempt gateway, not a seeded refund.
      Req.Test.json(conn, %{"done" => true, "response" => Jason.encode!(F.abstention())})
    end)

    assert {:ok, _} = F.command(c, "analyze", %{"prepared_ref" => c.prepared["prepared_ref"]})
    assert_received :one_provider_attempt
    assert {:ok, before} = SetupRuns.get(c.session_id, F.caller())
    assert before["run"]["usage"]["uncertain_requests"] == 1
    assert before["run"]["usage"]["tokens_accounted"] > 4096
    budget_id = before["run"]["usage"]["budget_id"]
    assert {:ok, budget} = Ledger.budget(budget_id)

    # Seed only the mutable persisted expired phase. The immutable authorization,
    # its 300-second window and the real reservation remain untouched. Actual
    # wall-clock expiry is separately observed in retained Chrome recovery proof.
    assert %{num_rows: 1} =
             Repo.query!(
               "UPDATE setup_run_states SET phase='expired',lock_version=lock_version+1 WHERE workspace_id=? AND run_id=?",
               [c.workspace, before["run"]["run_ref"]["id"]]
             )

    assert {:ok, expired} = SetupRuns.get(c.session_id, F.caller())
    assert expired["run"]["phase"] == "expired"
    assert expired["available_actions"] == ["new_run", "cancel"]
    assert expired["run"]["usage"] == before["run"]["usage"]
    before_rows = history_rows(c.workspace)
    envelope = F.envelope(c, "cancel", %{})
    assert {:ok, receipt} = SetupRuns.command(envelope, F.caller())
    assert {:ok, closed} = SetupRuns.get(c.session_id, F.caller())
    assert closed["run"]["phase"] == "cancelled"
    assert closed["available_actions"] == ["new_run"]
    assert closed["session_version"] == expired["session_version"] + 1
    assert closed["run"]["run_version"] == expired["run"]["run_version"] + 1
    assert closed["run"]["run_ref"] == expired["run"]["run_ref"]
    assert closed["run"]["config_ref"] == expired["run"]["config_ref"]
    assert closed["run"]["result_ref"] == nil
    assert {:ok, ^budget} = Ledger.budget(budget_id)
    assert history_rows(c.workspace) == before_rows

    assert [[revoked_at, "cancelled", 2]] =
             Repo.query!(
               "SELECT revoked_at,reason,lock_version FROM model_run_authorization_states WHERE workspace_id=?",
               [c.workspace]
             ).rows

    assert is_binary(revoked_at)

    assert {:error, %{"code" => "authorization_required"}} =
             RunAuthorization.ready_for_run(closed["run"]["run_ref"], F.caller())

    after_close = history_rows(c.workspace)
    assert {:ok, ^receipt} = SetupRuns.command(envelope, F.caller())
    assert {:ok, ^closed} = SetupRuns.get(c.session_id, F.caller())
    assert history_rows(c.workspace) == after_close
    assert {:ok, ^budget} = Ledger.budget(budget_id)

    assert [[^revoked_at, "cancelled", 2]] =
             Repo.query!(
               "SELECT revoked_at,reason,lock_version FROM model_run_authorization_states WHERE workspace_id=?",
               [c.workspace]
             ).rows

    assert {:error, %{"code" => "conflict"}} =
             SetupRuns.command(Map.put(envelope, "command_id", Ecto.UUID.generate()), F.caller())

    assert F.rows("model_requests") == 1
    assert F.rows("model_budgets") == 1
    assert F.rows("evidence_claims") == 0
    refute_received :one_provider_attempt
  end

  defp history_rows(workspace) do
    Map.new(~w(model_requests model_budgets stage_attempts), fn table ->
      {table,
       Repo.query!("SELECT * FROM " <> table <> " WHERE workspace_id=? ORDER BY id", [workspace]).rows}
    end)
  end
end
