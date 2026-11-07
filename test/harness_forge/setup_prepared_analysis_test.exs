defmodule HarnessForge.SetupPreparedAnalysisTest do
  use ExUnit.Case, async: false
  alias HarnessForge.{Evidence, Repo}
  alias HarnessForge.Company.{SetupRuns, SetupRunPreparation}
  alias HarnessForge.SetupRunModelsFixture, as: F
  @moduletag :committed
  setup do: F.setup!()

  test "distinct explicit operations consume one budget and the same stored bytes; exhaustion cannot create a third",
       c do
    c = F.authorize!(c)
    owner = self()
    {:ok, replies} = Agent.start_link(fn -> 0 end)

    Application.put_env(:harness_forge, :model_test_plug, fn conn ->
      {:ok, bytes, conn} = Plug.Conn.read_body(conn)
      send(owner, {:prepared_send, bytes})
      n = Agent.get_and_update(replies, fn n -> {n, n + 1} end)
      # First output is known settled but structurally invalid. Explicit retry
      # can use the remaining reservation, without prompt/fingerprint padding.
      Req.Test.json(
        conn,
        if(n == 0,
          do: %{"done" => true, "response" => "{}", "prompt_eval_count" => 11, "eval_count" => 7},
          else: F.response(F.abstention())
        )
      )
    end)

    stored = Repo.get!(SetupRunPreparation, c.prepared["prepared_ref"]["id"])
    before_manifests = F.rows("dependency_manifests")
    assert {:ok, first} = F.command(c, "analyze", %{"prepared_ref" => c.prepared["prepared_ref"]})
    assert_received {:prepared_send, first_bytes}
    assert first_bytes == stored.request_body_bytes
    assert {:ok, first_view} = SetupRuns.get(c.session_id, F.caller())
    assert first_view["run"]["phase"] == "blocked"
    assert first_view["run"]["usage"]["requests_reserved"] == 1
    assert first_view["run"]["usage"]["uncertain_requests"] == 0
    assert {:ok, second} = F.command(c, "retry", %{"prepared_ref" => c.prepared["prepared_ref"]})
    refute first["operation_ref"] == second["operation_ref"]
    assert_received {:prepared_send, ^first_bytes}
    assert {:ok, second_view} = SetupRuns.get(c.session_id, F.caller())
    assert second_view["run"]["phase"] == "completed"
    assert second_view["run"]["usage"]["requests_reserved"] == 2
    assert second_view["run"]["usage"]["budget_id"] == first_view["run"]["usage"]["budget_id"]
    assert second_view["run"]["usage"]["tokens_accounted"] == 36
    assert F.rows("model_budgets") == 1
    assert F.rows("dependency_manifests") == before_manifests

    assert {:error, %{"code" => "budget_exhausted"}} =
             F.command(c, "retry", %{"prepared_ref" => c.prepared["prepared_ref"]})

    refute_received {:prepared_send, _}
    assert F.rows("model_requests") == 2
  end

  test "unknown usage remains charged and prevents explicit retry or reload from resending", c do
    c = F.authorize!(c)
    owner = self()

    Application.put_env(:harness_forge, :model_test_plug, fn conn ->
      send(owner, :uncertain_send)
      Req.Test.json(conn, %{"done" => true, "response" => Jason.encode!(F.abstention())})
    end)

    envelope = F.envelope(c, "analyze", %{"prepared_ref" => c.prepared["prepared_ref"]})
    assert {:ok, receipt} = SetupRuns.command(envelope, F.caller())
    assert_received :uncertain_send
    assert {:ok, ^receipt} = SetupRuns.command(envelope, F.caller())
    refute_received :uncertain_send
    assert {:ok, view} = SetupRuns.get(c.session_id, F.caller())
    assert view["run"]["usage"]["uncertain_requests"] == 1
    assert view["run"]["usage"]["tokens_accounted"] > 4096

    assert {:error, %{"code" => "request_outcome_unknown"}} =
             F.command(c, "retry", %{"prepared_ref" => c.prepared["prepared_ref"]})

    refute_received :uncertain_send
    assert F.rows("model_budgets") == 1
  end

  test "run cancellation during HTTP preserves reported usage and forbids claim and Setup publication",
       c do
    c = F.authorize!(c)
    owner = self()

    Application.put_env(:harness_forge, :model_test_plug, fn conn ->
      send(owner, :cancelled_provider_send)
      assert {:ok, _} = F.command(c, "cancel", %{})
      Req.Test.json(conn, F.response(F.abstention()))
    end)

    assert {:ok, _} = F.command(c, "analyze", %{"prepared_ref" => c.prepared["prepared_ref"]})
    assert_received :cancelled_provider_send
    assert {:ok, view} = SetupRuns.get(c.session_id, F.caller())
    assert view["run"]["phase"] == "cancelled"
    assert view["run"]["result_ref"] == nil
    assert view["run"]["usage"]["requests_reserved"] == 1
    assert view["run"]["usage"]["tokens_accounted"] == 18
    assert F.rows("evidence_claims") == 0

    assert [["completed", "reported"]] ==
             Repo.query!("SELECT state,usage_status FROM model_requests WHERE workspace_id=?", [
               c.workspace
             ]).rows
  end

  test "R01 withdrawal during HTTP retains usage but cannot publish the reviewed pack", c do
    c = F.authorize!(c)
    source = hd(c.fixture.sources)
    owner = self()

    Application.put_env(:harness_forge, :model_test_plug, fn conn ->
      assert {:ok, current_source} = Evidence.get_source(source["id"])
      rev = current_source["latest_revision"]

      assert {:ok, %{"cleanup_state" => "pending"}} =
               Evidence.restrict_revision(
                 %{
                   "version" => 1,
                   "source_id" => source["id"],
                   "revision_id" => rev["id"],
                   "body_hash" => rev["body_hash"],
                   "expected_generation" => 0,
                   "command_id" => Ecto.UUID.generate(),
                   "reason_code" => "operator_restriction"
                 },
                 F.caller()
               )

      send(owner, :held_provider_send)
      Req.Test.json(conn, F.response(F.abstention()))
    end)

    assert {:ok, _} = F.command(c, "analyze", %{"prepared_ref" => c.prepared["prepared_ref"]})
    assert_received :held_provider_send
    assert {:ok, view} = SetupRuns.get(c.session_id, F.caller())
    assert view["run"]["result_ref"] == nil
    assert view["run"]["usage"]["tokens_accounted"] == 18
    assert F.rows("evidence_claims") == 0

    assert [["completed", "reported"]] ==
             Repo.query!("SELECT state,usage_status FROM model_requests WHERE workspace_id=?", [
               c.workspace
             ]).rows
  end
end
