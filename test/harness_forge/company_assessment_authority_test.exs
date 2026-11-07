defmodule HarnessForge.CompanyAssessmentAuthorityTest do
  use HarnessForge.DataCase, async: false
  alias HarnessForge.{Company, Contracts, Harnesses}
  alias HarnessForge.Company.{Assessment, Assessments, Profile, Project, Repository, TaskRubric}
  alias HarnessForge.CompanyAssessmentFixture, as: Fixture
  alias HarnessForge.Evidence.{AuditEvent, Goal, Store}

  setup do
    previous =
      Map.new([:workspace_id, :workspace_root], &{&1, Application.get_env(:harness_forge, &1)})

    root = Path.join(File.cwd!(), "tmp/company-assessment-authority-" <> Ecto.UUID.generate())
    File.mkdir_p!(root)
    Application.put_env(:harness_forge, :workspace_id, Ecto.UUID.generate())
    Application.put_env(:harness_forge, :workspace_root, root)
    f = Fixture.create!(root)
    opts = Fixture.server_opts()
    {:ok, rubric} = Assessments.freeze_rubric(f.freeze_attrs, opts)
    attrs = Fixture.assessment_attrs(f, rubric)

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> Application.put_env(:harness_forge, key, value) end)
      File.rm_rf!(root)
    end)

    %{f: f, opts: opts, rubric: rubric, attrs: attrs}
  end

  test "server options are complete, unique and never a client actor assertion", c do
    invalid = [
      [],
      Keyword.delete(c.opts, :authorize),
      c.opts ++ [authorize: fn -> true end],
      Keyword.put(c.opts, :actor, "owner"),
      Keyword.put(c.opts, :session_fingerprint, "forged"),
      Keyword.put(c.opts, :reset_token, -1)
    ]

    for opts <- invalid do
      assert {:error, :invalid_input} = Assessments.record_assessment(c.attrs, opts)
      assert {:error, :invalid_input} = Assessments.freeze_rubric(c.f.freeze_attrs, opts)

      assert {:error, :invalid_input} =
               Assessments.new_attempt(c.rubric["id"], c.rubric["revision_hash"], opts)
    end

    before = counts()

    for callback <- [fn -> false end, fn -> :ok end, fn -> raise "synthetic callback failure" end] do
      opts = Keyword.put(c.opts, :authorize, callback)
      assert {:error, :operator_session_revoked} = Assessments.record_assessment(c.attrs, opts)

      assert {:error, :operator_session_revoked} =
               Assessments.freeze_rubric(c.f.freeze_attrs, opts)

      assert {:error, :operator_session_revoked} =
               Assessments.new_attempt(c.rubric["id"], c.rubric["revision_hash"], opts)
    end

    assert counts() == before
  end

  test "authorization is rechecked immediately before writes and failures do not consume attempts",
       c do
    key = {__MODULE__, make_ref()}
    Process.put(key, 0)

    opts =
      Keyword.put(c.opts, :authorize, fn ->
        count = Process.get(key)
        Process.put(key, count + 1)
        count == 0
      end)

    before = counts()
    assert {:error, :operator_session_revoked} = Assessments.record_assessment(c.attrs, opts)
    assert counts() == before
    assert {:ok, _} = Assessments.record_assessment(c.attrs, c.opts)
    Process.delete(key)
  end

  test "forged, expired, session-swapped and queued pre-reset tokens refuse even after commit",
       c do
    for opts <- [
          Keyword.put(c.opts, :session_fingerprint, String.duplicate("b", 64)),
          Keyword.put(c.opts, :view_generation, String.duplicate("b", 32)),
          Keyword.put(c.opts, :reset_token, 1)
        ] do
      assert {:error, :invalid_attempt_token} = Assessments.record_assessment(c.attrs, opts)
    end

    assert {:error, :invalid_attempt_token} =
             Assessments.record_assessment(Map.put(c.attrs, "attempt_token", "forged"), c.opts)

    assert {:error, :invalid_attempt_token} =
             Assessments.record_assessment(
               Map.put(c.attrs, "attempt_id", Ecto.UUID.generate()),
               c.opts
             )

    secret =
      Application.fetch_env!(:harness_forge, HarnessForgeWeb.Endpoint)
      |> Keyword.fetch!(:secret_key_base)

    {:ok, payload} =
      Phoenix.Token.verify(secret, "company-assessment-attempt-v1", c.attrs["attempt_token"],
        max_age: 43_200
      )

    expired =
      Phoenix.Token.sign(secret, "company-assessment-attempt-v1", payload,
        signed_at: System.system_time(:second) - 43_201,
        max_age: 43_200
      )

    assert {:error, :invalid_attempt_token} =
             Assessments.record_assessment(Map.put(c.attrs, "attempt_token", expired), c.opts)

    assert {:ok, receipt} = Assessments.record_assessment(c.attrs, c.opts)

    assert {:error, :invalid_attempt_token} =
             Assessments.record_assessment(c.attrs, Keyword.put(c.opts, :reset_token, 1))

    assert {:error, :operator_session_revoked} =
             Assessments.record_assessment(
               c.attrs,
               Keyword.put(c.opts, :authorize, fn -> false end)
             )

    assert {:ok, ^receipt} = Assessments.get_assessment(receipt["id"])
  end

  test "each chosen-package and goal pin is independently enforced", c do
    cases = [
      {"plan_id", Ecto.UUID.generate(), :not_found},
      {"expected_plan_revision_hash", String.duplicate("0", 64), :stale_plan_revision},
      {"artifact_digest", String.duplicate("0", 64), :package_not_bound},
      {"goal_id", Ecto.UUID.generate(), :goal_not_selected},
      {"goal_content_hash", String.duplicate("0", 64), :stale_goal}
    ]

    before = counts()

    for {field, value, reason} <- cases do
      assert {:error, ^reason} = Assessments.context(Map.put(c.f.binding, field, value))

      assert {:error, ^reason} =
               Assessments.freeze_rubric(Map.put(c.f.freeze_attrs, field, value), c.opts)
    end

    assert {:error, :stale_rubric} =
             Assessments.record_assessment(
               Map.put(c.attrs, "expected_rubric_hash", String.duplicate("0", 64)),
               c.opts
             )

    assert {:error, :not_found} =
             Assessments.record_assessment(
               Map.put(c.attrs, "rubric_id", Ecto.UUID.generate()),
               c.opts
             )

    assert counts() == before
  end

  test "foreign workspace IDs reveal no scoped body and cannot replay", c do
    {:ok, receipt} = Assessments.record_assessment(c.attrs, c.opts)
    own = Store.workspace()
    Application.put_env(:harness_forge, :workspace_id, Ecto.UUID.generate())
    assert {:error, :not_found} = Assessments.context(c.f.binding)
    assert {:error, :not_found} = Assessments.get_rubric(c.rubric["id"])
    assert {:error, :not_found} = Assessments.get_assessment(receipt["id"])
    assert {:error, :not_found} = Assessments.list_assessments(c.rubric["id"])
    assert {:error, :not_found} = Assessments.record_assessment(c.attrs, c.opts)
    assert {:ok, []} = Assessments.list_rubrics()
    Application.put_env(:harness_forge, :workspace_id, own)
    assert {:ok, ^receipt} = Assessments.get_assessment(receipt["id"])
  end

  test "direct saved-goal text mutation invalidates frozen acceptance without remapping", c do
    saved = Repo.get!(Goal, c.f.goal["id"])

    assert_raise Exqlite.Error, ~r/immutable record/, fn ->
      Repo.update!(Ecto.Changeset.change(saved, acceptance: "Directly changed goal acceptance."))
    end

    assert Repo.get!(Goal, saved.id).acceptance == saved.acceptance

    trigger_query =
      "SELECT sql FROM sqlite_master WHERE type = 'trigger' AND name = 'immutable_workspace_goals_update'"

    [[trigger_sql]] = Repo.query!(trigger_query).rows
    # Simulate adversarial external storage corruption only in this sandbox.
    Repo.query!("DROP TRIGGER immutable_workspace_goals_update")

    try do
      Repo.update!(Ecto.Changeset.change(saved, acceptance: "Directly changed goal acceptance."))
    after
      Repo.query!(trigger_sql)
    end

    assert Repo.query!(trigger_query).rows == [[trigger_sql]]
    before = counts()
    assert {:error, :stale_authority} = Assessments.record_assessment(c.attrs, c.opts)
    assert counts() == before
    assert {:ok, historical} = Assessments.get_rubric(c.rubric["id"])
    assert historical["payload"] == c.rubric["payload"]
    assert historical["applicability"]["status"] == "stale"
  end

  test "direct payload-only profile mutation cannot retain authority using its old stored hash",
       c do
    saved = Repo.get!(Profile, c.f.profile["id"])

    Repo.update!(
      Ecto.Changeset.change(saved,
        payload:
          Map.put(saved.payload, "description", "Direct mutation without content hash update")
      )
    )

    assert {:error, :stale_authority} = Assessments.record_assessment(c.attrs, c.opts)
    assert Repo.aggregate(Store.scoped(Assessment), :count) == 0
  end

  test "direct payload-only project mutation cannot retain authority using its old stored hash",
       c do
    saved = Repo.get!(Project, c.f.project["id"])

    Repo.update!(
      Ecto.Changeset.change(saved,
        payload:
          Map.put(saved.payload, "description", "Direct mutation without content hash update")
      )
    )

    assert {:error, :stale_authority} = Assessments.record_assessment(c.attrs, c.opts)
    assert Repo.aggregate(Store.scoped(Assessment), :count) == 0
  end

  test "direct payload-only selected repository mutation cannot borrow its old stored hash", c do
    saved = Repo.get!(Repository, c.f.repository["id"])

    Repo.update!(
      Ecto.Changeset.change(saved,
        payload: Map.put(saved.payload, "purpose", "Direct mutation without content hash update")
      )
    )

    assert {:error, :stale_authority} = Assessments.record_assessment(c.attrs, c.opts)
    assert Repo.aggregate(Store.scoped(Assessment), :count) == 0
  end

  test "a superseded approved plan cannot borrow its historically eligible package", c do
    attrs = Map.put(c.f.plan_attrs, "supersedes_id", c.f.plan["id"])
    {:ok, _} = Company.create_plan(attrs)
    # Existing build/export semantics remain independently unchanged.
    assert {:ok, _} = Company.build_inputs(c.f.plan["id"])
    assert {:error, :superseded_plan} = Assessments.context(c.f.binding)
    assert {:error, :stale_authority} = Assessments.record_assessment(c.attrs, c.opts)

    assert {:ok, receipt} =
             Assessments.record_assessment(Map.put(c.attrs, "judgment", "not_accepted"), c.opts)

    assert receipt["payload"]["authority_reason"] == "superseded_plan"
  end

  test "claim supersession makes authority stale and preserves frozen original refs", c do
    claim = c.f.claim
    edits = Map.put(claim["basis"]["guidance"], "rule", "Explicit synthetic successor guidance.")

    assert {:ok, _} =
             HarnessForge.Company.Analysis.revise(claim["id"], claim["revision_hash"], edits)

    assert {:error, :stale_authority} = Assessments.record_assessment(c.attrs, c.opts)
    assert {:ok, rubric} = Assessments.get_rubric(c.rubric["id"])
    assert rubric["payload"]["required_claim_refs"] == c.f.required_refs
  end

  test "canonical stored hash corruption refuses reads and submissions", c do
    Repo.query!("DROP TRIGGER immutable_company_task_rubrics_update")

    Repo.query!("UPDATE company_task_rubrics SET revision_hash = ? WHERE id = ?", [
      String.duplicate("0", 64),
      c.rubric["id"]
    ])

    Repo.query!(
      "CREATE TRIGGER immutable_company_task_rubrics_update BEFORE UPDATE ON company_task_rubrics BEGIN SELECT RAISE(ABORT, 'immutable company assessment'); END"
    )

    assert {:error, :invalid_record_hash} = Assessments.get_rubric(c.rubric["id"])
    assert {:error, :invalid_record_hash} = Assessments.record_assessment(c.attrs, c.opts)
    assert Repo.aggregate(Store.scoped(Assessment), :count) == 0
  end

  test "restored outer ownership preserves exact historical bytes and refuses attempts before replay",
       c do
    {:ok, receipt} = Assessments.record_assessment(c.attrs, c.opts)
    fresh_workspace = Ecto.UUID.generate()

    for table <- ~w(company_task_rubrics company_assessments) do
      Repo.query!("DROP TRIGGER immutable_#{table}_update")

      Repo.query!("UPDATE #{table} SET workspace_id = ? WHERE workspace_id = ?", [
        fresh_workspace,
        Store.workspace()
      ])

      Repo.query!(
        "CREATE TRIGGER immutable_#{table}_update BEFORE UPDATE ON #{table} BEGIN SELECT RAISE(ABORT, 'immutable company assessment'); END"
      )
    end

    Application.put_env(:harness_forge, :workspace_id, fresh_workspace)
    assert {:ok, history} = Assessments.get_assessment(receipt["id"])
    assert history["payload"] == receipt["payload"]
    assert history["assessment_hash"] == receipt["assessment_hash"]
    assert history["request_digest"] == receipt["request_digest"]

    assert history["applicability"] == %{
             "status" => "restored_historical",
             "reason" => "restored_historical"
           }

    assert {:ok, restored_rubric} = Assessments.get_rubric(c.rubric["id"])
    assert restored_rubric["payload"] == c.rubric["payload"]
    assert restored_rubric["revision_hash"] == c.rubric["revision_hash"]

    assert {:error, :restored_historical} =
             Assessments.new_attempt(c.rubric["id"], c.rubric["revision_hash"], c.opts)

    assert {:error, :restored_historical} = Assessments.record_assessment(c.attrs, c.opts)
  end

  test "the 1000 assessment cap includes history but identical replay remains available", c do
    {:ok, receipt} = Assessments.record_assessment(c.attrs, c.opts)
    record = Repo.get!(Assessment, receipt["id"])

    for _ <- 1..999 do
      id = Ecto.UUID.generate()
      attempt_id = Ecto.UUID.generate()

      request =
        %{
          "rubric_id" => record.rubric_id,
          "expected_rubric_hash" => record.payload["rubric_revision_hash"],
          "attempt_id" => attempt_id
        }
        |> Map.merge(Map.take(record.payload, ~w(task_status critical_status judgment results)))

      digest = Contracts.digest(request)

      hash =
        Contracts.digest(%{
          "format" => "harnessforge-company-assessment-v1",
          "id" => id,
          "rubric_id" => record.rubric_id,
          "attempt_id" => attempt_id,
          "request_digest" => digest,
          "payload" => record.payload
        })

      Repo.insert!(%Assessment{
        id: id,
        workspace_id: record.workspace_id,
        rubric_id: record.rubric_id,
        attempt_id: attempt_id,
        request_digest: digest,
        payload: record.payload,
        assessment_hash: hash,
        inserted_at: Store.now()
      })
    end

    assert {:ok, ^receipt} = Assessments.record_assessment(c.attrs, c.opts)
    fresh = Fixture.assessment_attrs(c.f, c.rubric)
    assert {:error, :assessment_limit} = Assessments.record_assessment(fresh, c.opts)
    assert Repo.aggregate(Store.scoped(Assessment), :count) == 1000
  end

  test "assessment writes preserve authority tables, package bytes and safe audit payloads", c do
    tables =
      ~w(evidence_claims claim_decisions company_plans company_plan_decisions company_artifact_bindings model_requests model_budgets evaluation_runs release_approvals release_channels release_history)

    before =
      Map.new(tables, fn table ->
        {table,
         Repo.query!("SELECT * FROM #{table} WHERE workspace_id = ? ORDER BY id", [
           Store.workspace()
         ]).rows}
      end)

    {:ok, receipt} = Assessments.record_assessment(c.attrs, c.opts)
    assert {:ok, artifact} = Harnesses.get(c.f.artifact["digest"])
    assert artifact == c.f.artifact

    for table <- tables,
        do:
          assert(
            Repo.query!("SELECT * FROM #{table} WHERE workspace_id = ? ORDER BY id", [
              Store.workspace()
            ]).rows == before[table]
          )

    event =
      Repo.one!(
        from a in Store.scoped(AuditEvent), where: a.action == "company.assessment_recorded"
      )

    assert Enum.sort(Map.keys(event.details)) ==
             ~w(actor assessment_hash assessment_id attempt_id rubric_id status)

    refute Contracts.canonical_json(event.details) =~ hd(c.attrs["results"])["observation"]
    refute Contracts.canonical_json(event.details) =~ c.attrs["attempt_token"]
    assert event.details["assessment_id"] == receipt["id"]
    assert {:error, :evaluation_not_found} = HarnessForge.Evaluations.get(receipt["id"])

    release_attrs = %{
      "artifact_digest" => c.f.artifact["digest"],
      "evaluation_id" => receipt["id"],
      "actor" => "synthetic",
      "scope" => c.f.artifact["spec"]["spec"]["scope"]
    }

    assert {:error, :evaluation_not_found} = HarnessForge.Releases.approve(release_attrs)

    assert {:error, :invalid_release_input} =
             HarnessForge.Releases.approve(Map.put(release_attrs, "evaluation_id", receipt))

    for table <- tables,
        do:
          assert(
            Repo.query!("SELECT * FROM #{table} WHERE workspace_id = ? ORDER BY id", [
              Store.workspace()
            ]).rows == before[table]
          )
  end

  defp counts,
    do:
      {Repo.aggregate(Store.scoped(TaskRubric), :count),
       Repo.aggregate(Store.scoped(Assessment), :count),
       Repo.aggregate(Store.scoped(AuditEvent), :count)}
end
