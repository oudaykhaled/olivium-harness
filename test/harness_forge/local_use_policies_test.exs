defmodule HarnessForge.LocalUsePoliciesTest do
  use ExUnit.Case, async: false
  alias HarnessForge.{Contracts, Evidence, Goals, Repo, SetupRunModelsFixture}
  alias HarnessForge.Company.Retrieval
  alias HarnessForge.Evidence.{Corpora, LocalUsePolicies, SourceUseContext, Store}
  alias HarnessForgeWeb.Plugs.OperatorSession

  setup do
    fixture = SetupRunModelsFixture.setup!()
    auth = OperatorSession.new_auth()
    {:ok, caller} = OperatorSession.source_caller(auth, String.duplicate("e", 32), 0)
    {:ok, context} = SourceUseContext.interactive(auth, caller)
    source_id = hd(fixture.fixture.sources)["id"]
    {:ok, source} = Evidence.get_source(source_id)
    ref = %{"source_id" => source_id, "revision_id" => source["latest_revision"]["id"],
      "body_hash" => source["latest_revision"]["body_hash"]}
    {:ok, Map.merge(fixture, %{auth: auth, caller: caller, context: context, source: source, ref: ref})}
  end

  test "capture and preparation grant nothing; explicit selected uses admit exact UTF-8 evidence", c do
    assert :legacy_unknown = LocalUsePolicies.assert_use(c.ref, "inspection", nil)
    preparation = prepare!(c)
    assert preparation["item_count"] == 4
    assert preparation["selected_purposes"] == []
    refute preparation["retention_acknowledged"]
    assert :legacy_unknown = LocalUsePolicies.assert_use(c.ref, "inspection", c.context)
    assert {:ok, again} = LocalUsePolicies.prepare_capture(preparation_attrs(c), c.caller, c.auth)
    assert again["id"] == preparation["id"]
    assert again["digest"] == preparation["digest"]

    before = accounting()
    attrs = authorization(preparation, ~w(inspection retrieval analysis compile))
    assert {:ok, receipt} = LocalUsePolicies.authorize(attrs, c.caller, c.auth)
    assert receipt["state"] == "active"
    assert receipt["policy_generation"] == 1
    assert :ok = LocalUsePolicies.assert_use(c.ref, "inspection", c.context)
    assert {:error, _} = Evidence.get_source(c.source["id"])
    assert {:ok, visible} = Evidence.get_source(c.source["id"], c.context)
    assert visible["latest_revision"]["body"] == c.source["latest_revision"]["body"]
    {start, size} = :binary.match(visible["latest_revision"]["body"], "Café")
    assert {:ok, citation} = Evidence.citation(c.ref["revision_id"], start, start + size, c.context)
    assert citation["snippet"] == "Café"
    assert {:error, _} = Evidence.citation(c.ref["revision_id"], start, start + size)
    assert {:ok, replay} = LocalUsePolicies.authorize(attrs, c.caller, c.auth)
    assert replay["id"] == receipt["id"]
    assert replay["event_id"] == receipt["event_id"]
    assert replay["policy_generation"] == 1
    assert accounting() == before
  end

  test "inspection permission does not authorize retrieval, analysis, compile or a model", c do
    preparation = prepare!(c)
    assert {:ok, _} = LocalUsePolicies.authorize(authorization(preparation, ["inspection"]), c.caller, c.auth)
    assert :ok = LocalUsePolicies.assert_use(c.ref, "inspection", c.context)
    before = accounting()
    runs = rows("retrieval_runs")
    for purpose <- ~w(retrieval analysis compile) do
      assert {:error, _} = LocalUsePolicies.assert_use(c.ref, purpose, c.context)
    end
    assert {:error, _} = Retrieval.retrieve_evidence(request(c), c.caller, c.context)
    assert rows("retrieval_runs") == runs
    assert accounting() == before
  end

  test "forged input, callback-only authority and missing retention cannot activate", c do
    preparation = prepare!(c)
    attrs = authorization(preparation, ~w(inspection retrieval))
    for invalid <- [Map.delete(attrs, "retain_local"), Map.put(attrs, "retain_local", false),
      Map.put(attrs, "purposes", []), Map.put(attrs, "purposes", ["retrieval"]),
      Map.put(attrs, "purposes", ["inspection", "inspection"]),
      Map.put(attrs, "purposes", ["inspection", "all"]), Map.put(attrs, "owner_id", "local-operator")] do
      assert {:error, _} = LocalUsePolicies.authorize(invalid, c.caller, c.auth)
    end
    assert {:error, _} = LocalUsePolicies.authorize(attrs, c.caller, %{})
    assert :legacy_unknown = LocalUsePolicies.assert_use(c.ref, "inspection", c.context)
    assert [[0]] = Repo.query!("SELECT count(*) FROM local_use_enrollments WHERE workspace_id=?", [Store.workspace()]).rows
  end

  test "withdrawal blocks old and contextual reads before pending cleanup and never refunds model usage", c do
    assert {:ok, policy} = LocalUsePolicies.authorize(authorization(prepare!(c), ~w(inspection retrieval analysis compile)), c.caller, c.auth)
    before = accounting()
    withdrawal = %{"version" => "LocalUseWithdrawal.v1", "policy_ref" => Map.take(policy, ~w(id digest)),
      "expected_generation" => 1, "command_id" => Ecto.UUID.generate(), "reason_code" => "operator_withdrawal"}
    assert {:ok, withdrawn} = LocalUsePolicies.withdraw(withdrawal, c.caller, c.auth)
    assert withdrawn["state"] == "withdrawn"
    assert withdrawn["policy_generation"] == 2
    assert withdrawn["cleanup_state"] == "pending"
    for context <- [nil, c.context] do
      assert {:error, _} = LocalUsePolicies.assert_use(c.ref, "inspection", context)
      assert {:error, _} = Evidence.get_source(c.source["id"], context)
      assert {:ok, []} = Evidence.search("Café", context)
    end
    assert {:ok, repeated} = LocalUsePolicies.withdraw(withdrawal, c.caller, c.auth)
    assert repeated["event_id"] == withdrawn["event_id"]
    assert repeated["policy_generation"] == 2
    assert {:error, _} = LocalUsePolicies.withdraw(Map.put(withdrawal, "command_id", Ecto.UUID.generate()), c.caller, c.auth)
    assert accounting() == before
  end

  test "generic overwrite is rejected without changing bytes, revision or active policy", c do
    assert {:ok, policy} = LocalUsePolicies.authorize(authorization(prepare!(c), ~w(inspection retrieval)), c.caller, c.auth)
    body = c.source["latest_revision"]["body"]
    attrs = %{"external_id" => c.source["external_id"], "title" => c.source["title"], "body" => body <> " changed"}
    assert {:error, _} = Evidence.import_markdown(c.fixture.connection["id"], attrs)
    assert {:ok, current} = Evidence.get_source(c.source["id"], c.context)
    assert current["latest_revision"]["id"] == c.ref["revision_id"]
    assert current["latest_revision"]["body"] == body
    assert {:ok, same} = LocalUsePolicies.status(policy["id"], %{}, c.context)
    assert same["digest"] == policy["digest"]
    assert same["policy_generation"] == 1
  end

  test "SQL predicate rejects arbitrary aliases, purposes and forged contexts", c do
    assert {:ok, {_sql, []}} = LocalUsePolicies.not_denied_sql("r", "inspection", nil)
    for {alias_name, purpose, context} <- [{"r; DROP TABLE evidence_sources", "inspection", nil},
      {"s", "inspection", c.context}, {"r", "all", c.context}, {"r", "inspection", %{}},
      {"r", :inspection, c.context}] do
      assert {:error, _} = LocalUsePolicies.not_denied_sql(alias_name, purpose, context)
    end
  end

  defp preparation_attrs(c), do: %{"version" => "LocalUsePreparation.v1", "capture_ref" => c.view["run"]["capture_ref"]}
  defp prepare!(c) do
    assert {:ok, preparation} = LocalUsePolicies.prepare_capture(preparation_attrs(c), c.caller, c.auth)
    preparation
  end
  defp authorization(preparation, purposes), do: %{"version" => "LocalUseAuthorization.v1",
    "preparation_ref" => Map.take(preparation, ~w(id digest)), "expected_version" => 0,
    "command_id" => Ecto.UUID.generate(), "purposes" => purposes, "retain_local" => true}
  defp request(c) do
    {:ok, corpus} = Corpora.get(c.corpus["id"])
    %{"corpus_id" => corpus.id, "project_id" => c.fixture.project["id"],
      "goal_id" => c.fixture.goal["id"], "goal_hash" => Goals.content_hash(c.fixture.goal),
      "expected_generation" => corpus.semantic_generation,
      "question" => "Which emergency review and rollback controls apply?"}
  end
  defp rows(table), do: Repo.query!("SELECT count(*) FROM " <> table <> " WHERE workspace_id=?", [Store.workspace()]).rows
  defp accounting, do: Map.new(~w(model_requests model_budgets model_run_authorizations claim_decisions company_plan_decisions), &{&1, rows(&1)})
end
