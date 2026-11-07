defmodule HarnessForge.CompanyAssessmentsTest do
  use HarnessForge.DataCase, async: false
  alias HarnessForge.{Company, Contracts, Decisions, Evidence, Goals, Harnesses}
  alias HarnessForge.Company.{Assessment, Assessments, TaskRubric}
  alias HarnessForge.CompanyAssessmentFixture, as: Fixture
  alias HarnessForge.Evidence.{AuditEvent, Store}

  setup do
    previous =
      Map.new([:workspace_id, :workspace_root], &{&1, Application.get_env(:harness_forge, &1)})

    root = Path.join(File.cwd!(), "tmp/company-assessment-" <> Ecto.UUID.generate())
    File.mkdir_p!(root)
    Application.put_env(:harness_forge, :workspace_id, Ecto.UUID.generate())
    Application.put_env(:harness_forge, :workspace_root, root)
    fixture = Fixture.create!(root)

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> Application.put_env(:harness_forge, key, value) end)
      File.rm_rf!(root)
    end)

    %{f: fixture, opts: Fixture.server_opts(), root: root}
  end

  test "the fixed four-obligation oracle reaches immutable task, receipt and exact retry", c do
    assert {:ok, unselected} =
             Assessments.context(Map.drop(c.f.binding, ~w(goal_id goal_content_hash)))

    assert unselected["selected_goal"] == nil
    assert length(unselected["goals"]) == 2
    assert {:ok, context} = Assessments.context(c.f.binding)
    assert Enum.map(context["outside_goals"], & &1["id"]) == [c.f.outside_goal["id"]]
    assert context["milestones"] == []
    assert context["required_claim_refs"] == c.f.required_refs
    assert hd(context["recommendations"])["basis"]["report"] == c.f.report
    assert {:ok, rubric} = Assessments.freeze_rubric(c.f.freeze_attrs, c.opts)

    assert Enum.map(rubric["payload"]["obligations"], & &1["id"]) ==
             ~w(communication-owner goal-readiness named-review rollback-ready)

    assert rubric["payload"]["claim_contexts"] == [
             c.f.claim
             |> Map.take(~w(id revision_hash))
             |> Map.merge(Map.take(c.f.claim["basis"], ~w(context context_digest)))
           ]

    assert rubric["revision_hash"] ==
             Contracts.digest(%{
               "format" => "harnessforge-company-task-rubric-v1",
               "id" => rubric["id"],
               "family_id" => rubric["id"],
               "supersedes_id" => nil,
               "payload" => rubric["payload"]
             })

    attrs = Fixture.assessment_attrs(c.f, rubric)
    before_audit = audit_count()
    assert {:ok, receipt} = Assessments.record_assessment(attrs, c.opts)
    assert receipt["payload"]["operator"] == "local-operator"
    assert receipt["payload"]["judgment"] == "accepted"
    assert receipt["applicability"] == %{"status" => "current", "reason" => nil}

    assert receipt["assessment_hash"] ==
             Contracts.digest(%{
               "format" => "harnessforge-company-assessment-v1",
               "id" => receipt["id"],
               "rubric_id" => rubric["id"],
               "attempt_id" => attrs["attempt_id"],
               "request_digest" => receipt["request_digest"],
               "payload" => receipt["payload"]
             })

    assert {:ok, ^receipt} =
             Assessments.record_assessment(Map.update!(attrs, "results", &Enum.reverse/1), c.opts)

    assert {:ok, ^receipt} = Assessments.get_assessment(receipt["id"])
    assert {:ok, [^receipt]} = Assessments.list_assessments(rubric["id"])
    assert Repo.aggregate(Store.scoped(Assessment), :count) == 1
    assert audit_count() == before_audit + 1

    assert {:error, :conflicting_attempt_replay} =
             Assessments.record_assessment(Map.put(attrs, "judgment", "not_accepted"), c.opts)

    assert {:ok, ^receipt} = Assessments.get_assessment(receipt["id"])
    assert {:ok, [^rubric]} = Assessments.list_rubrics()
  end

  test "missing, extra and duplicate IDs refuse every judgment with no row or audit", c do
    {:ok, rubric} = Assessments.freeze_rubric(c.f.freeze_attrs, c.opts)
    attrs = Fixture.assessment_attrs(c.f, rubric)
    before = {assessment_count(), audit_count()}
    rows = attrs["results"]

    variants = [
      tl(rows),
      rows ++ [hd(rows)],
      [%{hd(rows) | "obligation_id" => "undeclared"} | tl(rows)]
    ]

    for judgment <- ~w(accepted not_accepted), results <- variants do
      assert {:error, :invalid_obligation_results} =
               Assessments.record_assessment(
                 Map.merge(attrs, %{"judgment" => judgment, "results" => results}),
                 c.opts
               )

      assert {assessment_count(), audit_count()} == before
    end
  end

  test "each negative outcome refuses accepted and a complete explicit unsuccessful attempt records",
       c do
    {:ok, rubric} = Assessments.freeze_rubric(c.f.freeze_attrs, c.opts)
    attrs = Fixture.assessment_attrs(c.f, rubric)

    bad_rows =
      for status <- ~w(unmet unobserved),
          do:
            Map.update!(attrs, "results", fn [row | rest] ->
              [Map.put(row, "status", status) | rest]
            end)

    blank =
      Map.update!(attrs, "results", fn [row | rest] ->
        [Map.put(row, "observation", " \n ") | rest]
      end)

    variants =
      bad_rows ++
        [
          blank,
          Map.put(attrs, "task_status", "interrupted"),
          Map.put(attrs, "critical_status", "present"),
          Map.put(attrs, "critical_status", "unobserved")
        ]

    before = {assessment_count(), audit_count()}

    for candidate <- variants do
      assert {:error, :acceptance_requirements_unmet} =
               Assessments.record_assessment(candidate, c.opts)

      assert {assessment_count(), audit_count()} == before
    end

    failed =
      attrs
      |> Map.merge(%{
        "task_status" => "interrupted",
        "critical_status" => "unobserved",
        "judgment" => "not_accepted"
      })
      |> Map.update!("results", fn rows ->
        Enum.map(rows, &Map.merge(&1, %{"status" => "unobserved", "observation" => ""}))
      end)

    assert {:ok, receipt} = Assessments.record_assessment(failed, c.opts)
    assert receipt["payload"]["judgment"] == "not_accepted"
    assert {:ok, ^receipt} = Assessments.get_assessment(receipt["id"])
  end

  test "strict allowlists reject actor, result and nested mapping injection", c do
    bad_ref = Map.put(hd(c.f.required_refs), "actor", "claimed-owner")

    obligation =
      Enum.find(c.f.freeze_attrs["obligations"], &(&1["kind"] == "approved_analysis_guidance"))

    variants = [
      Map.put(c.f.freeze_attrs, "operator", "claimed-owner"),
      Map.put(c.f.freeze_attrs, "results", []),
      Map.put(c.f.freeze_attrs, :task, "atom key"),
      Map.put(c.f.freeze_attrs, "obligations", [Map.put(obligation, "unknown", true)]),
      Map.put(c.f.freeze_attrs, "obligations", [Map.put(obligation, "claim_refs", [bad_ref])])
    ]

    for attrs <- variants,
        do: assert({:error, :invalid_input} = Assessments.freeze_rubric(attrs, c.opts))

    {:ok, rubric} = Assessments.freeze_rubric(c.f.freeze_attrs, c.opts)
    attrs = Fixture.assessment_attrs(c.f, rubric)

    for candidate <- [
          Map.put(attrs, "actor", "claimed-owner"),
          Map.put(attrs, "name", "claimed-owner"),
          Map.put(attrs, "results", [Map.put(hd(attrs["results"]), "verified", true)]),
          Map.delete(attrs, "critical_status")
        ] do
      assert {:error, :invalid_input} = Assessments.record_assessment(candidate, c.opts)
    end

    assert assessment_count() == 0
  end

  test "every required recommendation and the unique goal obligation must be mapped", c do
    original = c.f.freeze_attrs["obligations"]

    for rows <- [
          Enum.reject(original, &(&1["kind"] == "goal_acceptance")),
          Enum.reject(original, &(&1["kind"] == "approved_analysis_guidance")),
          Enum.map(original, &Map.put(&1, "claim_refs", [])),
          original ++
            [%{Enum.find(original, &(&1["kind"] == "goal_acceptance")) | "id" => "another-goal"}]
        ] do
      assert {:error, :incomplete_obligation_mapping} =
               Assessments.freeze_rubric(Map.put(c.f.freeze_attrs, "obligations", rows), c.opts)
    end

    forged =
      Enum.map(original, fn row ->
        if row["kind"] == "approved_analysis_guidance",
          do:
            Map.put(row, "claim_refs", [
              %{"id" => Ecto.UUID.generate(), "revision_hash" => String.duplicate("a", 64)}
            ]),
          else: row
      end)

    assert {:error, :incomplete_obligation_mapping} =
             Assessments.freeze_rubric(Map.put(c.f.freeze_attrs, "obligations", forged), c.opts)

    duplicate = [hd(original) | original]

    assert {:error, :invalid_input} =
             Assessments.freeze_rubric(
               Map.put(c.f.freeze_attrs, "obligations", duplicate),
               c.opts
             )

    assert Repo.aggregate(Store.scoped(TaskRubric), :count) == 0
  end

  test "bounded UTF-8 preserves exact text and rejects excess without truncation", c do
    for task <- [<<255>>, "nul" <> <<0>>, " \n "] do
      assert {:error, :invalid_input} =
               Assessments.freeze_rubric(Map.put(c.f.freeze_attrs, "task", task), c.opts)
    end

    for task <- [String.duplicate("a", 1001), String.duplicate("á́", 1000)] do
      assert {:error, :input_too_large} =
               Assessments.freeze_rubric(Map.put(c.f.freeze_attrs, "task", task), c.opts)
    end

    task = " " <> String.duplicate("é", 998) <> " "

    assert {:ok, rubric} =
             Assessments.freeze_rubric(Map.put(c.f.freeze_attrs, "task", task), c.opts)

    assert rubric["payload"]["task"] == task
    attrs = Fixture.assessment_attrs(c.f, rubric)

    oversized =
      Map.update!(attrs, "results", fn [row | rest] ->
        [Map.put(row, "observation", String.duplicate("x", 1001)) | rest]
      end)

    assert {:error, :input_too_large} = Assessments.record_assessment(oversized, c.opts)
    assert assessment_count() == 0
  end

  test "all selected-goal recommendations are required and other-goal examined context remains captured",
       c do
    second =
      additional_claim(
        c.f,
        c.f.goal,
        "Record the release evidence review in a second explicit recommendation."
      )

    outside =
      additional_claim(
        c.f,
        c.f.outside_goal,
        "Record the separately scoped documentation review."
      )

    refs = [c.f.claim, second, outside] |> Enum.map(&Map.take(&1, ~w(id revision_hash)))
    {:ok, plan} = Company.create_plan(Map.put(c.f.plan_attrs, "claim_refs", refs))
    {:ok, _} = Company.decide_plan(plan["id"], Fixture.decision(plan))
    {:ok, artifact} = Harnesses.build_plan(plan["id"], plan["revision_hash"])

    binding =
      Map.merge(c.f.binding, %{
        "plan_id" => plan["id"],
        "expected_plan_revision_hash" => plan["revision_hash"],
        "artifact_digest" => artifact["digest"]
      })

    expected =
      [c.f.claim, second]
      |> Enum.map(&Map.take(&1, ~w(id revision_hash)))
      |> Enum.sort_by(& &1["id"])

    assert {:ok, context} = Assessments.context(binding)
    assert context["required_claim_refs"] == expected

    assert {:error, :incomplete_obligation_mapping} =
             Assessments.freeze_rubric(Map.merge(c.f.freeze_attrs, binding), c.opts)

    rows =
      Enum.map(c.f.freeze_attrs["obligations"], fn row ->
        if row["kind"] == "approved_analysis_guidance",
          do: Map.put(row, "claim_refs", expected),
          else: row
      end)

    assert {:ok, rubric} =
             Assessments.freeze_rubric(
               Map.merge(binding, %{"task" => c.f.oracle["task"], "obligations" => rows}),
               c.opts
             )

    assert Enum.map(rubric["payload"]["claim_contexts"], & &1["id"]) ==
             Enum.sort([c.f.claim["id"], second["id"], outside["id"]])

    assert Enum.all?(rubric["payload"]["claim_contexts"], fn row ->
             Enum.any?(row["context"]["sources"], &(&1["source_id"] == c.f.uncited_source["id"]))
           end)
  end

  test "structurally valid false testimony is stored only as explicit owner reporting", c do
    {:ok, rubric} = Assessments.freeze_rubric(c.f.freeze_attrs, c.opts)

    attrs =
      Fixture.assessment_attrs(c.f, rubric)
      |> Map.update!("results", fn rows ->
        Enum.map(
          rows,
          &Map.put(
            &1,
            "observation",
            "Synthetic deliberate false testimony: a fictional dragon reviewed this task."
          )
        )
      end)

    assert {:ok, receipt} = Assessments.record_assessment(attrs, c.opts)
    assert receipt["payload"]["operator"] == "local-operator"

    assert Enum.all?(
             receipt["payload"]["results"],
             &String.contains?(&1["observation"], "deliberate false testimony")
           )

    assert {:error, :evaluation_not_found} = HarnessForge.Evaluations.get(receipt["id"])
  end

  test "successors preserve immutable meaning for reused IDs and never inherit observations", c do
    {:ok, previous} = Assessments.freeze_rubric(c.f.freeze_attrs, c.opts)

    {:ok, receipt} =
      Assessments.record_assessment(Fixture.assessment_attrs(c.f, previous), c.opts)

    successor =
      Map.merge(c.f.freeze_attrs, %{
        "supersedes_id" => previous["id"],
        "expected_predecessor_hash" => previous["revision_hash"],
        "task" => "Prepare a second independently assessed release record."
      })

    altered =
      Map.update!(successor, "obligations", fn [row | rest] ->
        [Map.put(row, "text", "Changed meaning using an existing ID") | rest]
      end)

    assert {:error, :invalid_input} = Assessments.freeze_rubric(altered, c.opts)
    assert {:ok, next} = Assessments.freeze_rubric(successor, c.opts)
    assert next["family_id"] == previous["family_id"]
    assert next["supersedes_id"] == previous["id"]
    assert next["payload"]["task"] == successor["task"]
    assert {:ok, []} = Assessments.list_assessments(next["id"])
    assert {:error, :already_superseded} = Assessments.freeze_rubric(successor, c.opts)
    assert {:ok, historical} = Assessments.get_assessment(receipt["id"])
    assert Map.drop(historical, ["applicability"]) == Map.drop(receipt, ["applicability"])
    assert historical["applicability"] == %{"status" => "stale", "reason" => "stale_rubric"}
    assert {:ok, old} = Assessments.get_rubric(previous["id"])
    assert old["payload"] == previous["payload"]
    assert old["revision_hash"] == previous["revision_hash"]
    assert old["successor_id"] == next["id"]
    attrs = Fixture.assessment_attrs(c.f, previous)
    assert {:error, :stale_rubric} = Assessments.record_assessment(attrs, c.opts)

    assert {:ok, failed} =
             Assessments.record_assessment(Map.put(attrs, "judgment", "not_accepted"), c.opts)

    assert failed["payload"]["authority_reason"] == "stale_rubric"
  end

  test "uncited drift permits only stale unsuccessful history inside the write transaction", c do
    {:ok, rubric} = Assessments.freeze_rubric(c.f.freeze_attrs, c.opts)
    attrs = Fixture.assessment_attrs(c.f, rubric)
    {:ok, original} = Assessments.record_assessment(attrs, c.opts)
    new_attrs = Fixture.assessment_attrs(c.f, rubric)
    source = c.f.uncited_source

    {:ok, _} =
      Evidence.import_markdown(c.f.connection["id"], %{
        "external_id" => source["external_id"],
        "title" => source["title"],
        "body" => "Synthetic uncited discussion changed after freeze."
      })

    before = {assessment_count(), audit_count()}
    assert {:error, :stale_authority} = Assessments.record_assessment(new_attrs, c.opts)
    assert {assessment_count(), audit_count()} == before

    assert {:ok, stale} =
             Assessments.record_assessment(Map.put(new_attrs, "judgment", "not_accepted"), c.opts)

    assert stale["payload"]["authority_at_record"] == "stale"
    assert stale["payload"]["authority_reason"] == "stale_authority"
    assert {:ok, %{rows: [[1]]}} = Repo.query("SELECT 1")
    assert {:ok, historical} = Assessments.record_assessment(attrs, c.opts)
    assert historical["id"] == original["id"]
    assert historical["payload"] == original["payload"]
    assert historical["assessment_hash"] == original["assessment_hash"]
    assert historical["applicability"]["status"] == "stale"
    assert {:ok, ^historical} = Assessments.get_assessment(original["id"])
  end

  test "a dropped obligation ID cannot acquire changed meaning later in its family", c do
    lineage = dropped_owner_obligation(c)
    changed = Map.put(lineage.owner, "text", "Record a different emergency escalation decision.")
    attrs = Map.update!(lineage.successor, "obligations", &(&1 ++ [changed]))
    before = {Repo.aggregate(Store.scoped(TaskRubric), :count), audit_count()}

    assert {:error, :invalid_input} = Assessments.freeze_rubric(attrs, c.opts)
    assert {Repo.aggregate(Store.scoped(TaskRubric), :count), audit_count()} == before
    assert raw_receipt(lineage.receipt["id"]) == lineage.raw_receipt
    assert {:ok, historical} = Assessments.get_assessment(lineage.receipt["id"])
    assert historical["payload"] == lineage.receipt["payload"]
    assert historical["assessment_hash"] == lineage.receipt["assessment_hash"]
  end

  test "a dropped obligation ID may return with its exact original family meaning", c do
    lineage = dropped_owner_obligation(c)
    attrs = Map.update!(lineage.successor, "obligations", &(&1 ++ [lineage.owner]))

    assert {:ok, restored} = Assessments.freeze_rubric(attrs, c.opts)
    assert restored["family_id"] == lineage.current["family_id"]
    assert restored["supersedes_id"] == lineage.current["id"]

    assert Enum.find(restored["payload"]["obligations"], &(&1["id"] == lineage.owner["id"])) ==
             lineage.owner

    assert raw_receipt(lineage.receipt["id"]) == lineage.raw_receipt
  end

  test "changed obligation meaning after a dropped revision may use a new obligation ID", c do
    lineage = dropped_owner_obligation(c)

    changed =
      Map.merge(lineage.owner, %{
        "id" => "owner-escalation-decision",
        "text" => "Record a different emergency escalation decision."
      })

    attrs = Map.update!(lineage.successor, "obligations", &(&1 ++ [changed]))
    assert {:ok, next} = Assessments.freeze_rubric(attrs, c.opts)
    assert next["family_id"] == lineage.current["family_id"]
    assert Enum.find(next["payload"]["obligations"], &(&1["id"] == changed["id"])) == changed
    refute Enum.any?(next["payload"]["obligations"], &(&1["id"] == lineage.owner["id"]))
    assert raw_receipt(lineage.receipt["id"]) == lineage.raw_receipt
  end

  test "stored hash-valid lineage refuses changed meaning for a previously dropped ID", c do
    lineage = dropped_owner_obligation(c)
    changed = Map.put(lineage.owner, "text", "Record a different emergency escalation decision.")

    payload =
      Map.update!(lineage.current["payload"], "obligations", fn rows ->
        Enum.sort_by(rows ++ [changed], & &1["id"])
      end)

    id = Ecto.UUID.generate()

    hash =
      Contracts.digest(%{
        "format" => "harnessforge-company-task-rubric-v1",
        "id" => id,
        "family_id" => lineage.current["family_id"],
        "supersedes_id" => lineage.current["id"],
        "payload" => payload
      })

    # An inserted adversarial row has a valid canonical hash; no trigger is disabled.
    Repo.insert!(%TaskRubric{
      id: id,
      workspace_id: Store.workspace(),
      family_id: lineage.current["family_id"],
      supersedes_id: lineage.current["id"],
      payload: payload,
      revision_hash: hash,
      inserted_at: Store.now()
    })

    before = {Repo.aggregate(Store.scoped(TaskRubric), :count), assessment_count(), audit_count()}
    assert {:error, :invalid_record_hash} = Assessments.get_rubric(id)
    assert {:error, :invalid_record_hash} = Assessments.get_rubric(lineage.current["id"])
    assert {:error, :invalid_record_hash} = Assessments.new_attempt(id, hash, c.opts)
    assert {:error, :invalid_record_hash} = Assessments.list_rubrics()

    assert {Repo.aggregate(Store.scoped(TaskRubric), :count), assessment_count(), audit_count()} ==
             before

    assert raw_receipt(lineage.receipt["id"]) == lineage.raw_receipt
  end

  test "immutable database triggers reject ordinary task and receipt edits", c do
    {:ok, rubric} = Assessments.freeze_rubric(c.f.freeze_attrs, c.opts)
    {:ok, receipt} = Assessments.record_assessment(Fixture.assessment_attrs(c.f, rubric), c.opts)

    for {table, id} <- [
          {"company_task_rubrics", rubric["id"]},
          {"company_assessments", receipt["id"]}
        ] do
      assert {:error, _} =
               Repo.query("UPDATE #{table} SET workspace_id = ? WHERE id = ?", ["forbidden", id])

      assert {:error, _} = Repo.query("DELETE FROM #{table} WHERE id = ?", [id])
    end

    assert {:ok, ^rubric} = Assessments.get_rubric(rubric["id"])
    assert {:ok, ^receipt} = Assessments.get_assessment(receipt["id"])
  end

  test "transaction audit failure leaves no partial receipt and the same token remains usable",
       c do
    {:ok, rubric} = Assessments.freeze_rubric(c.f.freeze_attrs, c.opts)
    attrs = Fixture.assessment_attrs(c.f, rubric)
    before = audit_count()

    Repo.query!(
      "CREATE TRIGGER assessment_test_audit_failure BEFORE INSERT ON audit_events WHEN NEW.action = 'company.assessment_recorded' BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END"
    )

    assert {:error, reason} = Assessments.record_assessment(attrs, c.opts)
    assert reason in [:audit_failed, :assessment_storage_failed]
    assert assessment_count() == 0
    assert audit_count() == before
    Repo.query!("DROP TRIGGER assessment_test_audit_failure")
    assert {:ok, _} = Assessments.record_assessment(attrs, c.opts)
    assert assessment_count() == 1
    assert audit_count() == before + 1
  end

  test "concurrent identical requests converge on one immutable receipt and audit", c do
    {:ok, rubric} = Assessments.freeze_rubric(c.f.freeze_attrs, c.opts)
    attrs = Fixture.assessment_attrs(c.f, rubric)
    before = audit_count()

    outcomes =
      1..6
      |> Enum.map(fn _ -> Task.async(fn -> Assessments.record_assessment(attrs, c.opts) end) end)
      |> Enum.map(&Task.await(&1, 30_000))

    assert Enum.all?(outcomes, &match?({:ok, _}, &1))

    assert outcomes |> Enum.map(fn {:ok, receipt} -> receipt["id"] end) |> Enum.uniq() |> length() ==
             1

    assert assessment_count() == 1
    assert audit_count() == before + 1
  end

  test "workspace rubric cap counts history and does not evict", c do
    {:ok, rubric} = Assessments.freeze_rubric(c.f.freeze_attrs, c.opts)
    stored = Repo.get!(TaskRubric, rubric["id"])

    for _ <- 1..99 do
      id = Ecto.UUID.generate()

      hash =
        Contracts.digest(%{
          "format" => "harnessforge-company-task-rubric-v1",
          "id" => id,
          "family_id" => id,
          "supersedes_id" => nil,
          "payload" => stored.payload
        })

      Repo.insert!(%TaskRubric{
        id: id,
        workspace_id: stored.workspace_id,
        family_id: id,
        supersedes_id: nil,
        payload: stored.payload,
        revision_hash: hash,
        inserted_at: Store.now()
      })
    end

    assert {:error, :rubric_limit} = Assessments.freeze_rubric(c.f.freeze_attrs, c.opts)
    assert Repo.aggregate(Store.scoped(TaskRubric), :count) == 100
  end

  defp assessment_count, do: Repo.aggregate(Store.scoped(Assessment), :count)
  defp audit_count, do: Repo.aggregate(Store.scoped(AuditEvent), :count)

  defp dropped_owner_obligation(c) do
    owner = %{
      "id" => "owner-acknowledgement",
      "kind" => "owner_authored",
      "text" => "Record the owner's acknowledgement of the emergency review.",
      "mandatory" => true,
      "claim_refs" => []
    }

    attrs = Map.update!(c.f.freeze_attrs, "obligations", &(&1 ++ [owner]))
    {:ok, first} = Assessments.freeze_rubric(attrs, c.opts)

    results =
      Fixture.assessment_attrs(c.f, first)
      |> Map.put("judgment", "not_accepted")
      |> Map.update!("results", fn rows ->
        rows ++ [%{"obligation_id" => owner["id"], "status" => "unobserved", "observation" => ""}]
      end)

    {:ok, receipt} = Assessments.record_assessment(results, c.opts)
    raw = raw_receipt(receipt["id"])
    assert [[payload_bytes | _]] = raw
    assert is_binary(payload_bytes)

    {:ok, current} =
      Assessments.freeze_rubric(
        Map.merge(c.f.freeze_attrs, %{
          "supersedes_id" => first["id"],
          "expected_predecessor_hash" => first["revision_hash"]
        }),
        c.opts
      )

    successor =
      Map.merge(c.f.freeze_attrs, %{
        "supersedes_id" => current["id"],
        "expected_predecessor_hash" => current["revision_hash"]
      })

    %{owner: owner, current: current, successor: successor, receipt: receipt, raw_receipt: raw}
  end

  defp raw_receipt(id) do
    Repo.query!(
      "SELECT CAST(payload AS BLOB), * FROM company_assessments WHERE id = ? AND workspace_id = ?",
      [id, Store.workspace()]
    ).rows
  end

  defp additional_claim(fixture, goal, rule) do
    basis = fixture.claim["basis"]
    report = put_in(basis["report"], ["recommendation", "rule"], rule)
    guidance = Map.take(report["recommendation"], ~w(rule workflow check evaluation_criterion))

    basis =
      Map.merge(basis, %{
        "goal_id" => goal["id"],
        "goal_content_hash" => Goals.content_hash(goal),
        "report" => report,
        "guidance" => guidance,
        "review_resolution" => nil,
        "run_id" => Ecto.UUID.generate(),
        "request_id" => Ecto.UUID.generate()
      })

    {:ok, claim} =
      Evidence.create_claim(%{
        "text" => HarnessForge.Company.Analysis.render_guidance(guidance),
        "basis" => basis,
        "citations" => fixture.claim["citations"]
      })

    {:ok, approved} = Decisions.decide(claim["id"], Fixture.decision(claim))
    approved
  end
end
