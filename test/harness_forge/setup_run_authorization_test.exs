defmodule HarnessForge.SetupRunAuthorizationTest do
  use ExUnit.Case, async: false
  alias HarnessForge.{Contracts, Repo}
  alias HarnessForge.Company.SetupRuns
  alias HarnessForge.Models.{Ledger, RunAuthorization, StageAuthority}
  alias HarnessForge.SetupRunModelsFixture, as: F
  @moduletag :committed
  setup do: F.setup!()

  test "prepared disclosure counts exact source closure bytes and immutable digest remapping creates no authority",
       c do
    manifest = c.prepared["manifest_ref"]

    source_ids =
      Repo.query!(
        "SELECT DISTINCT source_id FROM origin_dependencies WHERE workspace_id=? AND manifest_id=? AND kind='source_revision'",
        [c.workspace, manifest["id"]]
      ).rows
      |> List.flatten()

    expected_bytes =
      Enum.reduce(source_ids, 0, fn id, total ->
        source = Enum.find(c.fixture.sources, &(&1["id"] == id))
        total + byte_size(source["latest_revision"]["body"])
      end)

    assert c.prepared["bytes"] == expected_bytes
    assert c.prepared["source_count"] == length(source_ids)

    prepared =
      Repo.get!(HarnessForge.Company.SetupRunPreparation, c.prepared["prepared_ref"]["id"])

    assert {:ok, digest} = RunAuthorization.restore_digest("preparation", prepared)
    assert digest == prepared.digest

    assert {:ok, remapped} =
             RunAuthorization.restore_digest("preparation", %{
               prepared
               | workspace_id: Ecto.UUID.generate()
             })

    refute remapped == prepared.digest
    assert {:error, :invalid_input} = RunAuthorization.restore_digest("authorization", prepared)
    assert F.rows("model_run_authorizations") == 0
    assert F.rows("model_budgets") == 0
  end

  test "positive caps admit zero local cost and exact reopen never changes existing caps" do
    id = Ecto.UUID.generate()
    limits = %{"max_requests" => 2, "max_tokens" => 100_000, "max_estimated_microusd" => 0}
    assert {:ok, budget} = Ledger.start_run(id, limits)
    assert budget["max_estimated_microusd"] == 0
    assert {:ok, ^budget} = Ledger.start_run(id, limits)
    assert {:error, :invalid_budget} = Ledger.start_run(id, %{limits | "max_requests" => 3})

    for invalid <- [
          %{limits | "max_requests" => 0},
          %{limits | "max_tokens" => 0},
          %{limits | "max_estimated_microusd" => -1}
        ] do
      assert {:error, :invalid_budget} = Ledger.start_run(Ecto.UUID.generate(), invalid)
    end

    assert {:ok, ^budget} = Ledger.budget(id)
  end

  test "only the accepted exact preparation and dual CAS can atomically authorize; replay never replenishes",
       c do
    assert F.rows("model_run_authorizations") == 0
    assert F.rows("stage_consent_revisions") == 0

    assert {:error, %{"code" => "authorization_required"}} =
             RunAuthorization.authorize(
               c.view["run"]["config_ref"],
               c.prepared["prepared_ref"],
               F.caller()
             )

    forged = put_in(c.prepared["prepared_ref"], ["digest"], String.duplicate("0", 64))

    assert {:error, %{"code" => "stale_preparation"}} =
             F.command(c, "authorize", %{"prepared_ref" => forged})

    assert F.rows("model_run_authorizations") == 0
    assert F.rows("model_budgets") == 0
    assert F.rows("stage_consent_revisions") == 0

    envelope = F.envelope(c, "authorize", %{"prepared_ref" => c.prepared["prepared_ref"]})
    assert {:ok, receipt} = SetupRuns.command(envelope, F.caller())
    assert {:ok, ^receipt} = SetupRuns.command(envelope, F.caller())
    assert F.rows("model_run_authorizations") == 1
    assert F.rows("model_budgets") == 1
    assert F.rows("model_run_disclosures") == 1
    assert F.rows("stage_consent_revisions") == 1
    assert {:ok, authorized} = RunAuthorization.ready_for_run(receipt["run_ref"], F.caller())
    assert {:ok, budget} = Ledger.budget(authorized["budget_id"])

    assert Map.take(budget, ~w(max_requests max_tokens max_estimated_microusd reserved_requests)) ==
             %{
               "max_requests" => 2,
               "max_tokens" => 100_000,
               "max_estimated_microusd" => 0,
               "reserved_requests" => 0
             }

    assert {:error, :authorization_required} = Ledger.start_run(authorized["budget_id"])

    assert {:error, :authorization_required} =
             Ledger.reserve(%{"run_id" => authorized["budget_id"]}, %{}, 0)

    assert {:error, %{"code" => "command_conflict"}} =
             SetupRuns.command(
               Map.put(
                 envelope,
                 "expected_session_version",
                 envelope["expected_session_version"] + 1
               ),
               F.caller()
             )

    assert {:ok, current} = RunAuthorization.ready_for_run(receipt["run_ref"], F.caller())
    assert current["expires_at"] == authorized["expires_at"]
  end

  test "failure at budget insertion rolls accepted command, consent, disclosure and authorization back together",
       c do
    envelope = F.envelope(c, "authorize", %{"prepared_ref" => c.prepared["prepared_ref"]})

    # Fail inside the real accepted authorize transaction, after consent and
    # disclosure work. Public commands intentionally reject caller transactions.
    Repo.query!("""
    CREATE TEMP TRIGGER setup_test_budget_failure BEFORE INSERT ON model_budgets
    WHEN NEW.workspace_id='#{c.workspace}'
    BEGIN SELECT RAISE(ABORT,'synthetic budget insertion failure'); END
    """)

    try do
      assert {:error, %{"code" => "unavailable"}} = SetupRuns.command(envelope, F.caller())
    after
      Repo.query!("DROP TRIGGER setup_test_budget_failure")
    end

    for table <-
          ~w(stage_consent_revisions model_run_disclosures model_run_authorizations model_run_authorization_states model_budgets),
        do: assert(F.rows(table) == 0)

    assert {:ok, view} = SetupRuns.get(c.session_id, F.caller())
    assert view["session_version"] == c.view["session_version"]
    assert view["run"]["run_version"] == c.view["run"]["run_version"]
    assert view["run"]["phase"] == "needs_input"
  end

  test "setup owned pins and registered IDs reject fresh legacy execution before sealing or budget creation",
       c do
    stage_id = c.prepared["stage_ref"]["id"]
    manifest = c.prepared["manifest_ref"]
    before_manifests = F.rows("dependency_manifests")
    before_budgets = F.rows("model_budgets")

    assert {:error, :authorization_required} =
             StageAuthority.new(
               Ecto.UUID.generate(),
               manifest["id"],
               manifest["digest"],
               [stage_id],
               F.caller()
             )

    assert {:error, :authorization_required} =
             Ledger.start_run(
               c.prepared["prepared_ref"]["id"]
               |> then(fn id ->
                 %{rows: [[operation]]} =
                   Repo.query!("SELECT operation_id FROM setup_run_preparations WHERE id=?", [id])

                 operation
               end)
             )

    assert {:error, :authorization_required} =
             HarnessForge.Company.AnalysisV2.analyze(
               c.prepared["retrieval_ref"]["id"],
               c.prepared["retrieval_ref"]["digest"],
               caller: F.caller(),
               stage_id: stage_id,
               run_id: Ecto.UUID.generate()
             )

    assert {:error, :authorization_required} =
             StageAuthority.grant_consent(
               stage_id,
               manifest["id"],
               manifest["digest"],
               F.caller()
             )

    assert F.rows("dependency_manifests") == before_manifests
    assert F.rows("model_budgets") == before_budgets
    assert F.rows("stage_consent_revisions") == 0
  end

  test "withdrawn consent and cancelled run deny readiness without erasing exact usage", c do
    c = F.authorize!(c)
    assert {:ok, receipt} = RunAuthorization.ready_for_run(c.view["run"]["run_ref"], F.caller())

    Repo.query!("UPDATE stage_consent_revisions SET state='revoked' WHERE workspace_id=?", [
      c.workspace
    ])

    assert {:error, %{"code" => "consent_required"}} =
             RunAuthorization.ready_for_run(c.view["run"]["run_ref"], F.caller())

    assert {:error, _} = F.command(c, "analyze", %{"prepared_ref" => c.prepared["prepared_ref"]})
    assert {:ok, budget} = Ledger.budget(receipt["budget_id"])
    assert budget["reserved_requests"] == 0
    assert {:ok, _} = F.command(c, "cancel", %{})
    assert {:error, _} = RunAuthorization.ready_for_run(c.view["run"]["run_ref"], F.caller())
    assert {:ok, usage} = RunAuthorization.usage(c.view["run"]["run_ref"], F.caller())
    assert usage["budget_id"] == receipt["budget_id"]
    assert usage["requests_reserved"] == 0
  end

  test "explicit replacement preserves prior usage, creates no budget, and reuses compatible owned consent only after fresh confirmation",
       c do
    c = F.authorize!(c)
    prior = c.view["run"]
    assert {:ok, _} = F.command(c, "cancel", %{})

    assert {:ok, replacement} =
             F.command(c, "new_run", %{"predecessor_run_ref" => prior["run_ref"]})

    refute replacement["run_ref"] == prior["run_ref"]
    assert {:ok, proposed} = SetupRuns.get(c.session_id, F.caller())
    assert proposed["run"]["phase"] == "proposed"
    assert proposed["run"]["usage"]["budget_id"] == nil
    assert F.rows("model_budgets") == 1
    assert F.rows("stage_consent_revisions") == 1
    successor = F.prepare_capture!(c)
    assert successor.prepared["context_digest"] == c.prepared["context_digest"]
    assert successor.prepared["stage_ref"] == c.prepared["stage_ref"]
    assert successor.prepared["manifest_ref"] != c.prepared["manifest_ref"]
    assert successor.prepared["consent_status"] == "reusable"
    assert F.rows("model_budgets") == 1
    successor = F.authorize!(successor)
    assert F.rows("model_budgets") == 2
    assert F.rows("stage_consent_revisions") == 1
    assert F.rows("model_run_disclosures") == 2
    assert successor.view["run"]["predecessor_run_ref"] == prior["run_ref"]
    assert length(successor.view["predecessor_usage"]) == 1
  end

  test "changed model destination and foreign preparation references create no disclosure or budget",
       c do
    foreign = %{"id" => Ecto.UUID.generate(), "digest" => Contracts.sha256("foreign")}
    assert {:error, _} = RunAuthorization.prepared_view(foreign, F.caller())

    assert {:error, %{"code" => "unauthorized"}} =
             RunAuthorization.prepared_view(
               c.prepared["prepared_ref"],
               Keyword.put(F.caller(), :authorize, fn -> false end)
             )

    assert {:ok, _} =
             HarnessForge.Models.configure(%{
               "model" => "different-synthetic-fixture",
               "endpoint" => "http://127.0.0.1:11434"
             })

    assert {:error, _} =
             F.command(c, "authorize", %{"prepared_ref" => c.prepared["prepared_ref"]})

    for table <-
          ~w(stage_consent_revisions model_run_disclosures model_run_authorizations model_budgets),
        do: assert(F.rows(table) == 0)
  end
end
