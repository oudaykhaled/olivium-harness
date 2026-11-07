defmodule HarnessForge.PrivacyTest do
  use ExUnit.Case, async: false

  alias HarnessForge.{
    Artifacts,
    Decisions,
    Evaluations,
    Evidence,
    Goals,
    Harnesses,
    Models,
    Privacy,
    Repo,
    Workspaces
  }

  alias Exqlite.Sqlite3
  alias HarnessForge.CodingDockerFixture
  alias HarnessForge.Execution.{Coding, CodingTransport}

  setup tags do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: tags[:committed] != true)
    old_root = Application.get_env(:harness_forge, :workspace_root)
    old_id = Application.get_env(:harness_forge, :workspace_id)
    id = Ecto.UUID.generate()
    base = Path.join(File.cwd!(), ".privacy-test-" <> id)
    root = Path.join(base, "workspace")
    File.mkdir_p!(root)
    Enum.each(~w(artifacts runs tmp), &File.mkdir_p!(Path.join(root, &1)))
    Application.put_env(:harness_forge, :workspace_root, root)
    Application.put_env(:harness_forge, :workspace_id, id)

    on_exit(fn ->
      if tags[:committed] do
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          Application.put_env(:harness_forge, :workspace_root, root)
          Application.put_env(:harness_forge, :workspace_id, id)
          {:ok, _} = Privacy.purge_workspace(id)
        end)
      end

      Application.put_env(:harness_forge, :workspace_root, old_root)
      Application.put_env(:harness_forge, :workspace_id, old_id)
      File.rm_rf!(base)
    end)

    %{base: base, root: root, id: id}
  end

  test "inventory is scoped and typed confirmation rejects before mutation", context do
    {source, _claim, _connection} = evidence(context, "private-canary")
    assert {:ok, inventory} = Privacy.inventory()
    assert inventory["records"]["evidence_revisions"] == 1
    assert {:error, :confirmation_mismatch} = Privacy.purge_source(source["id"], "yes")
    assert {:error, :confirmation_mismatch} = Privacy.purge_workspace("yes")
    assert {:ok, [_]} = Evidence.search("canary")
    assert :ok = Privacy.ready()
  end

  test "selective purge removes command content only for dependent evaluation runs", context do
    {source, _, _} = evidence(context, "COMMAND_APPROVAL_SOURCE")
    {:ok, artifact} = Harnesses.build()
    {:ok, dependent} = Evaluations.run(artifact["digest"], kind: :static_integrity)
    command_approval_record(dependent["id"], "DEPENDENT_COMMAND_CANARY")

    unrelated = runtime_record()

    Repo.update!(
      Ecto.Changeset.change(unrelated,
        result: %{"kind" => "static_integrity", "outcome" => "passed"}
      )
    )

    command_approval_record(unrelated.id, "UNRELATED_COMMAND_CANARY")

    assert {:ok, inventory} = Privacy.inventory()
    assert inventory["records"]["command_approvals"] == 2
    assert {:ok, %{"state" => "completed"}} = Privacy.purge_source(source["id"], source["id"])

    assert Repo.query!("SELECT payload FROM command_approvals WHERE workspace_id=?", [context.id]).rows ==
             [[Jason.encode!(%{"fixture" => "UNRELATED_COMMAND_CANARY"})]]

    refute Repo.get(HarnessForge.Evaluation.Run, dependent["id"])
    assert Repo.get(HarnessForge.Evaluation.Run, unrelated.id)
  end

  test "workspace purge clears pending command content before its run", context do
    run = runtime_record()

    Repo.update!(
      Ecto.Changeset.change(run,
        result: %{"kind" => "static_integrity", "outcome" => "passed"}
      )
    )

    command_approval_record(run.id, "WORKSPACE_COMMAND_CANARY")
    assert {:ok, %{"state" => "completed"}} = Privacy.purge_workspace(context.id)

    assert Repo.query!("SELECT count(*) FROM command_approvals WHERE workspace_id=?", [context.id]).rows ==
             [[0]]

    refute Repo.get(HarnessForge.Evaluation.Run, run.id)
  end

  @tag :committed
  test "restore preserves the backup but withdraws all native command approvals", context do
    {_, _, _} = evidence(context, "COMMAND_RESTORE_SOURCE")
    {:ok, artifact} = Harnesses.build()
    {:ok, run} = Evaluations.run(artifact["digest"], kind: :static_integrity)
    command_approval_record(run["id"], "RESTORE_COMMAND_CANARY")
    backup = Path.join(context.base, "command-backup")
    restored = Path.join(context.base, "command-restored")

    assert {:ok, _} = Privacy.backup(backup)
    assert {:ok, %{"approvals_restored" => false}} = Privacy.restore(backup, restored)
    assert db_rows(restored, "SELECT count(*) FROM command_approvals") == [[0]]

    assert db_rows(
             restored,
             "SELECT outcome FROM (SELECT json_extract(result,'$.outcome') AS outcome FROM evaluation_runs)"
           ) == [["interrupted"]]

    assert Repo.query!("SELECT count(*) FROM command_approvals WHERE workspace_id=?", [context.id]).rows ==
             [[1]]
  end

  test "selective purge leaves an unrelated active evaluation and its connection untouched",
       context do
    {source, _, connection} = evidence(context, "Wait for the unrelated evaluation")
    run = runtime_record()

    Repo.update!(
      Ecto.Changeset.change(run,
        result: %{
          "kind" => "task",
          "outcome" => "running",
          "cleanup_status" => "not_started"
        }
      )
    )

    assert {:error, :evaluations_still_running} = Privacy.purge_source(source["id"], source["id"])
    assert :ok = Privacy.ready()
    assert {:ok, _} = Evidence.get_source(source["id"])
    assert {:ok, connections} = Evidence.list_connections()
    assert Enum.find(connections, &(&1["id"] == connection["id"]))["status"] == "active"
    assert Repo.get!(HarnessForge.Evaluation.Run, run.id).result["outcome"] == "running"
  end

  test "boot interruption of stale jobs lets durable privacy recovery finish", context do
    {source, _, _} = evidence(context, "Recover after a worker crash")

    job =
      %{"workspace_id" => context.id, "action" => "propose", "id" => source["id"]}
      |> HarnessForge.Jobs.Operation.new()
      |> Ecto.Changeset.put_change(:state, "executing")
      |> Repo.insert!()

    queued =
      %{"workspace_id" => context.id, "action" => "propose", "id" => "unrelated-source"}
      |> HarnessForge.Jobs.Operation.new()
      |> Repo.insert!()

    assert {:error, :jobs_still_executing} = Privacy.purge_source(source["id"], source["id"])
    assert {:error, :privacy_operation_incomplete} = Privacy.ready()
    assert :ok = HarnessForge.StartupGate.interrupt_stale_jobs()
    assert Repo.get!(Oban.Job, job.id).state == "cancelled"
    assert Repo.get!(Oban.Job, queued.id).state == "available"
    assert :ok = Privacy.reconcile()
    assert :ok = Privacy.ready()
    assert {:error, :not_found} = Evidence.get_source(source["id"])
  end

  test "source purge removes dependent artifacts and claim families, retains unrelated content",
       context do
    {_safe_source, safe_claim, _} = evidence(context, "Independent approved rule")
    assert {:ok, safe_artifact} = Harnesses.build()
    {safe_run, safe_release} = release_fixture(safe_artifact, "independent")
    {source, claim, connection} = evidence(context, "SOURCE_CANARY_REMOVE_ME")
    assert {:ok, dependent} = Harnesses.build()
    {dependent_run, dependent_release} = release_fixture(dependent, "SOURCE_CANARY_REMOVE_ME")

    assert {:ok, _goal} =
             Goals.add_goal(%{
               "title" => "Independent goal",
               "owner" => "Maintainer",
               "acceptance" => "Keep this"
             })

    assert {:ok, citation} = Evidence.citation(source["latest_revision"]["id"], 0, 6)

    assert {:ok, edited} =
             Evidence.create_claim(%{
               "text" => "SOURCE_CANARY_REMOVE_ME revised",
               "citations" => [citation],
               "supersedes_id" => claim["id"]
             })

    assert {:ok, %{"state" => "completed", "physical_erasure" => false}} =
             Privacy.purge_source(source["id"], source["id"])

    assert {:ok, []} = Evidence.search("SOURCE_CANARY_REMOVE_ME")
    assert {:error, :not_found} = Evidence.get_source(source["id"])
    assert {:error, :not_found} = Evidence.get_claim(claim["id"])
    assert {:error, :not_found} = Evidence.get_claim(edited["id"])
    assert {:ok, _} = Evidence.get_claim(safe_claim["id"])
    assert {:ok, [_]} = Goals.list_goals()
    assert {:ok, _} = Artifacts.read(safe_artifact["digest"])
    assert {:error, _} = Artifacts.read(dependent["digest"])
    assert Repo.get(HarnessForge.Evaluation.Run, safe_run.id)
    assert Repo.get(HarnessForge.Releases.Approval, safe_release.id)
    refute Repo.get(HarnessForge.Evaluation.Run, dependent_run.id)
    refute Repo.get(HarnessForge.Releases.Approval, dependent_release.id)

    assert Repo.query!(
             "SELECT count(*) FROM release_history WHERE payload LIKE '%SOURCE_CANARY_REMOVE_ME%'"
           ).rows == [[0]]

    assert {:error, :connection_revoked} = Evidence.import_directory(connection["id"])

    assert Repo.query!(
             "SELECT count(*) FROM evidence_search WHERE body LIKE '%SOURCE_CANARY_REMOVE_ME%'"
           ).rows == [[0]]

    assert Repo.query!(
             "SELECT count(*) FROM evidence_claims WHERE text LIKE '%SOURCE_CANARY_REMOVE_ME%'"
           ).rows == [[0]]

    assert {:error, _} = Repo.query("DELETE FROM evidence_revisions")
    assert {:ok, %{"state" => "completed"}} = Privacy.purge_source(source["id"], source["id"])
  end

  test "unavailable cleanup fences a durable purge and retry resumes", context do
    {source, _claim, _} = evidence(context, "Keep until teardown is verified")
    assert {:ok, artifact} = Harnesses.build()
    run = runtime_record(artifact["digest"])
    previous = System.get_env("DOCKER_HOST")
    System.put_env("DOCKER_HOST", "tcp://untrusted.invalid:2375")

    on_exit(fn ->
      if previous,
        do: System.put_env("DOCKER_HOST", previous),
        else: System.delete_env("DOCKER_HOST")
    end)

    assert {:error, :cleanup_failed} = Privacy.purge_source(source["id"], source["id"])
    assert {:error, :privacy_operation_incomplete} = Privacy.ready()

    assert Repo.query!("SELECT count(*) FROM evidence_revisions WHERE source_id = ?", [
             source["id"]
           ]).rows == [[1]]

    assert Repo.query!("SELECT state, error FROM privacy_operations WHERE workspace_id = ?", [
             context.id
           ]).rows == [["prepared", "cleanup_failed"]]

    Repo.delete!(run)
    assert :ok = Privacy.reconcile()
    assert :ok = Privacy.ready()
    assert {:error, :not_found} = Evidence.get_source(source["id"])
  end

  test "a post-prepare filesystem failure remains resumable without following a link", context do
    {source, _, _} = evidence(context, "Sensitive retry rule")
    assert {:ok, artifact} = Harnesses.build()
    run = runtime_record(artifact["digest"])
    previous = System.get_env("DOCKER_HOST")
    System.put_env("DOCKER_HOST", "tcp://untrusted.invalid:2375")

    on_exit(fn ->
      if previous,
        do: System.put_env("DOCKER_HOST", previous),
        else: System.delete_env("DOCKER_HOST")
    end)

    assert {:error, :cleanup_failed} = Privacy.purge_source(source["id"], source["id"])
    Repo.delete!(run)
    owned = Path.join([context.root, "artifacts", artifact["digest"]])
    saved = Path.join(context.base, "saved-artifact")
    File.rename!(owned, saved)
    outside = Path.join(context.base, "outside")
    File.mkdir!(outside)
    File.write!(Path.join(outside, "keep.txt"), "untouched")
    File.ln_s!(outside, owned)
    assert {:error, :unsafe_path} = Privacy.purge_source(source["id"], source["id"])
    assert File.read!(Path.join(outside, "keep.txt")) == "untouched"

    assert Repo.query!("SELECT state FROM privacy_operations WHERE workspace_id = ?", [context.id]).rows ==
             [["database_purged"]]

    assert {:error, :privacy_operation_incomplete} = Privacy.ready()
    File.rm!(owned)
    File.rename!(saved, owned)
    assert :ok = Privacy.reconcile()
    refute File.exists?(owned)
    assert File.read!(Path.join(outside, "keep.txt")) == "untouched"
  end

  test "corrupt artifact and symlink inventory fail before deleting source content", context do
    {source, _, _} = evidence(context, "Do not remove on failed preflight")
    outside = Path.join(context.base, "outside.txt")
    File.write!(outside, "keep me")
    File.ln_s!(outside, Path.join(context.root, "artifacts/unsafe"))
    assert {:error, _} = Privacy.inventory()
    assert {:error, _} = Privacy.purge_source(source["id"], source["id"])
    assert {:ok, _} = Evidence.get_source(source["id"])
    assert File.read!(outside) == "keep me"
    assert :ok = Privacy.ready()
  end

  test "workspace content purge preserves root/session files and supports a later fresh purge",
       context do
    evidence(context, "Erase active workspace content")
    File.write!(Path.join(context.root, "access-token"), "session-canary")
    File.write!(Path.join(context.root, "tmp/private.txt"), "temporary source body")

    assert {:ok, %{"kind" => "workspace", "state" => "completed"}} =
             Privacy.purge_workspace(context.id)

    assert {:ok, []} = Evidence.list_sources()
    assert File.read!(Path.join(context.root, "access-token")) == "session-canary"
    refute File.exists?(Path.join(context.root, "tmp/private.txt"))

    assert {:ok, _} =
             Goals.add_goal(%{
               "title" => "New goal",
               "owner" => "Maintainer",
               "acceptance" => "New acceptance"
             })

    assert {:ok, _} = Privacy.purge_workspace(context.id)
    assert {:ok, []} = Goals.list_goals()

    assert Repo.query!("SELECT count(*) FROM privacy_operations WHERE workspace_id = ?", [
             context.id
           ]).rows == [[2]]
  end

  @tag :committed
  test "consistent committed backup restores evidence and quarantines authority without secrets",
       context do
    {source, _claim, _} = evidence(context, "BACKUP_EVIDENCE_CANARY")
    assert {:ok, artifact} = Harnesses.build()
    File.write!(Path.join(context.root, "access-token"), "NEVER_BACK_UP_ACCESS_SECRET")
    File.write!(Path.join(context.root, "session-secret"), "NEVER_BACK_UP_SESSION_SECRET")

    assert {:ok, _} =
             Models.configure(%{
               "provider" => "openai",
               "endpoint" => "https://api.openai.com/v1",
               "model" => "test-model",
               "credential_env" => "HARNESSFORGE_PRIVATE_KEY",
               "cloud_consent" => %{
                 "provider" => "openai",
                 "endpoint" => "https://api.openai.com/v1",
                 "source_ids" => [source["id"]],
                 "data_categories" => ["evidence"]
               }
             })

    backup = Path.join(context.base, "backup")
    restored = Path.join(context.base, "restored")
    assert {:ok, %{"encrypted" => false}} = Privacy.backup(backup)
    assert {:ok, manifest} = Privacy.verify_backup(backup)
    assert artifact["digest"] in manifest["artifact_digests"]
    refute File.exists?(Path.join(backup, "access-token"))
    refute File.exists?(Path.join(backup, "session-secret"))

    assert {:ok,
            %{"state" => "quarantined", "workspace_id" => new_id, "approvals_restored" => false}} =
             Privacy.restore(backup, restored)

    assert new_id != context.id
    refute File.exists?(Path.join(restored, "access-token"))

    assert db_rows(restored, "SELECT body FROM evidence_revisions") == [
             ["BACKUP_EVIDENCE_CANARY"]
           ]

    assert db_rows(
             restored,
             "SELECT workspace_id, status, config, directory FROM source_connections"
           ) == [[new_id, "revoked", "{}", nil]]

    assert db_rows(restored, "SELECT count(*) FROM claim_decisions") == [[0]]
    assert db_rows(restored, "SELECT count(*) FROM release_approvals") == [[0]]
    assert db_rows(restored, "SELECT count(*) FROM model_settings") == [[0]]
    assert db_rows(restored, "SELECT count(*) FROM oban_jobs") == [[0]]
    assert File.exists?(Path.join([restored, "artifacts", artifact["digest"], "artifact.json"]))
    assert {:error, :target_exists} = Privacy.restore(backup, restored)
    assert {:error, :target_exists} = Privacy.backup(backup)
    File.write!(Path.join(backup, "data.sqlite3"), "corrupted")

    assert {:error, :invalid_backup} =
             Privacy.restore(backup, Path.join(context.base, "invalid-restore"))
  end

  test "backup and restore reject traversal and symlink targets", context do
    assert {:error, :unsafe_path} = Privacy.backup(Path.join(context.base, "../escape"))

    assert {:error, :target_inside_workspace} =
             Privacy.backup(Path.join(context.root, "recursive"))

    outside = Path.join(context.base, "outside")
    File.mkdir!(outside)
    File.ln_s!(outside, Path.join(context.base, "linked"))
    assert {:error, :unsafe_path} = Privacy.backup(Path.join(context.base, "linked/backup"))

    assert {:error, :unsafe_path} =
             Privacy.restore(
               Path.join(context.base, "linked"),
               Path.join(context.base, "restore")
             )

    assert File.ls!(outside) == []
  end

  defp evidence(context, text) do
    input = Path.join(context.base, "input-" <> Ecto.UUID.generate())
    File.mkdir!(input)

    {:ok, connection} =
      Evidence.connect(%{"provider" => "local", "name" => "Synthetic", "directory" => input})

    {:ok, source} =
      Evidence.import_markdown(connection["id"], %{
        "external_id" => "note.md",
        "title" => "Synthetic",
        "body" => text
      })

    {:ok, citation} = Evidence.citation(source["latest_revision"]["id"], 0, byte_size(text))
    {:ok, claim} = Evidence.create_claim(%{"text" => text, "citations" => [citation]})

    {:ok, _} =
      Decisions.decide(claim["id"], %{
        "actor" => "maintainer",
        "decision" => "approve",
        "expected_revision_hash" => claim["revision_hash"]
      })

    {source, claim, connection}
  end

  test "scoped coding purge retries the original daemon and leaves unrelated contexts untouched",
       context do
    fixture = CodingDockerFixture.install!()
    on_exit(fn -> CodingDockerFixture.restore(fixture) end)
    {_safe_source, _claim, _} = evidence(context, "Independent pinned cleanup history")
    assert {:ok, safe_artifact} = Harnesses.build()
    safe_run = pinned_record(safe_artifact, fixture)
    {source, _claim, _} = evidence(context, "Targeted pinned cleanup history")
    assert {:ok, artifact} = Harnesses.build()
    run = pinned_record(artifact, fixture)
    original_context = run.execution_context
    owned = Path.join([context.root, "runs", "coding-" <> run.id])
    File.mkdir_p!(owned)
    File.write!(Path.join(owned, "candidate-canary.txt"), "remove only after owned cleanup")
    CodingDockerFixture.select(fixture, fixture.decoy_endpoint)
    changed_info = Map.put(CodingDockerFixture.info(), "ID", "HF07:REPLACEMENT")
    CodingDockerFixture.put_daemon(fixture, fixture.endpoint, %{"info" => changed_info})
    CodingDockerFixture.clear_commands(fixture)

    assert {:error, :cleanup_failed} = Privacy.purge_source(source["id"], source["id"])
    assert {:error, :privacy_operation_incomplete} = Privacy.ready()
    assert Repo.get!(HarnessForge.Evaluation.Run, run.id).execution_context == original_context
    assert File.exists?(Path.join(owned, "candidate-canary.txt"))

    assert Repo.get!(HarnessForge.Evaluation.Run, safe_run.id).execution_context ==
             safe_run.execution_context

    assert_only_original_commands(fixture, safe_run.id)

    CodingDockerFixture.put_daemon(fixture, fixture.endpoint, %{
      "info" => CodingDockerFixture.info()
    })

    CodingDockerFixture.clear_commands(fixture)
    assert :ok = Privacy.reconcile()
    assert :ok = Privacy.ready()
    refute Repo.get(HarnessForge.Evaluation.Run, run.id)
    refute File.exists?(owned)
    assert {:ok, _} = Harnesses.get(safe_artifact["digest"])

    assert Repo.get!(HarnessForge.Evaluation.Run, safe_run.id).execution_context ==
             safe_run.execution_context

    assert_only_original_commands(fixture, safe_run.id)
  end

  test "workspace coding purge retains original authority on failure and leaves foreign workspace untouched",
       context do
    fixture = CodingDockerFixture.install!()
    on_exit(fn -> CodingDockerFixture.restore(fixture) end)
    evidence(context, "Workspace original-daemon recovery")
    assert {:ok, artifact} = Harnesses.build()
    run = pinned_record(artifact, fixture)
    foreign = pinned_record(artifact, fixture)
    foreign_id = Ecto.UUID.generate()
    foreign_context = Map.put(foreign.execution_context, "workspace_id", foreign_id)
    foreign_result = Map.put(foreign.result, "workspace_id", foreign_id)

    foreign =
      Repo.update!(
        Ecto.Changeset.change(foreign,
          workspace_id: foreign_id,
          result: foreign_result,
          execution_context: foreign_context
        )
      )

    owned = Path.join([context.root, "runs", "coding-" <> run.id])
    File.mkdir_p!(owned)
    File.write!(Path.join(owned, "candidate.txt"), "owned candidate")
    outside = Path.join(context.base, "foreign-candidate.txt")
    File.write!(outside, "foreign candidate must survive")
    CodingDockerFixture.select(fixture, fixture.decoy_endpoint)
    CodingDockerFixture.put_daemon(fixture, fixture.endpoint, %{"status" => 1})
    CodingDockerFixture.clear_commands(fixture)

    assert {:error, :cleanup_failed} = Privacy.purge_workspace(context.id)
    assert {:error, :privacy_operation_incomplete} = Privacy.ready()

    assert Repo.get!(HarnessForge.Evaluation.Run, run.id).execution_context ==
             run.execution_context

    assert Repo.get!(HarnessForge.Evaluation.Run, foreign.id) == foreign
    assert File.read!(Path.join(owned, "candidate.txt")) == "owned candidate"
    assert File.read!(outside) == "foreign candidate must survive"
    assert_only_original_commands(fixture, foreign.id)

    CodingDockerFixture.put_daemon(fixture, fixture.endpoint, %{"status" => 0})
    CodingDockerFixture.clear_commands(fixture)
    assert :ok = Privacy.reconcile()
    assert :ok = Privacy.ready()
    refute Repo.get(HarnessForge.Evaluation.Run, run.id)
    refute File.exists?(owned)
    assert Repo.get!(HarnessForge.Evaluation.Run, foreign.id) == foreign
    assert File.read!(outside) == "foreign candidate must survive"
    assert_only_original_commands(fixture, foreign.id)
  end

  test "coding context survives database-purged file failure and retry needs no deleted content",
       context do
    fixture = CodingDockerFixture.install!()
    on_exit(fn -> CodingDockerFixture.restore(fixture) end)
    {source, _claim, _} = evidence(context, "Retain original authority through a file failure")
    assert {:ok, artifact} = Harnesses.build()
    run = pinned_record(artifact, fixture)
    owned = Path.join([context.root, "runs", "coding-" <> run.id])
    File.mkdir_p!(owned)
    File.write!(Path.join(owned, "candidate.txt"), "synthetic")
    CodingDockerFixture.put_daemon(fixture, fixture.endpoint, %{"status" => 1})
    assert {:error, :cleanup_failed} = Privacy.purge_source(source["id"], source["id"])

    saved = Path.join(context.base, "retained-coding-root")
    File.rename!(owned, saved)
    outside = Path.join(context.base, "outside-coding-root")
    File.mkdir!(outside)
    File.write!(Path.join(outside, "keep.txt"), "untouched")
    File.ln_s!(outside, owned)
    CodingDockerFixture.put_daemon(fixture, fixture.endpoint, %{"status" => 0})

    assert {:error, :unsafe_path} = Privacy.purge_source(source["id"], source["id"])

    assert Repo.query!(
             "SELECT state FROM privacy_operations WHERE workspace_id = ?",
             [context.id]
           ).rows == [["database_purged"]]

    assert Repo.get!(HarnessForge.Evaluation.Run, run.id).execution_context ==
             run.execution_context

    assert File.read!(Path.join(outside, "keep.txt")) == "untouched"
    assert {:error, :privacy_operation_incomplete} = Privacy.ready()

    assert Repo.query!("SELECT count(*) FROM evidence_sources WHERE id = ?", [source["id"]]).rows ==
             [[0]]

    assert Repo.query!("SELECT count(*) FROM model_settings WHERE workspace_id = ?", [context.id]).rows ==
             [[0]]

    File.rm!(owned)
    File.rename!(saved, owned)
    assert :ok = Privacy.reconcile()
    assert :ok = Privacy.ready()
    refute Repo.get(HarnessForge.Evaluation.Run, run.id)
    refute File.exists?(owned)
    assert File.read!(Path.join(outside, "keep.txt")) == "untouched"
    assert_only_original_commands(fixture)
  end

  @tag :committed
  test "actual new backup retains private context but restored recovery and purge never contact it",
       context do
    fixture = CodingDockerFixture.install!()
    on_exit(fn -> CodingDockerFixture.restore(fixture) end)
    evidence(context, "Quarantine must not inherit Docker authority")
    assert {:ok, artifact} = Harnesses.build()
    run = pinned_record(artifact, fixture)
    backup = Path.join(context.base, "context-backup")
    restored = Path.join(context.base, "context-restored")
    assert {:ok, _} = Privacy.backup(backup)

    [[raw_context]] =
      db_rows(backup, "SELECT execution_context FROM evaluation_runs WHERE id = '#{run.id}'")

    assert Jason.decode!(raw_context) == run.execution_context
    CodingDockerFixture.clear_commands(fixture)
    assert {:ok, %{"workspace_id" => restored_id}} = Privacy.restore(backup, restored)

    assert db_rows(
             restored,
             "SELECT execution_context FROM evaluation_runs WHERE id = '#{run.id}'"
           ) == [[nil]]

    assert CodingDockerFixture.commands(fixture) == []

    {:ok, restored_repo} =
      Repo.start_link(
        name: nil,
        database: Path.join(restored, "data.sqlite3"),
        pool: DBConnection.ConnectionPool,
        pool_size: 1
      )

    previous_repo = Repo.put_dynamic_repo(restored_repo)
    Application.put_env(:harness_forge, :workspace_id, restored_id)
    Application.put_env(:harness_forge, :workspace_root, restored)

    try do
      assert :ok = Evaluations.reconcile()
      assert {:ok, _} = Privacy.purge_workspace(restored_id)
      assert CodingDockerFixture.commands(fixture) == []
    after
      Repo.put_dynamic_repo(previous_repo)
      Application.put_env(:harness_forge, :workspace_id, context.id)
      Application.put_env(:harness_forge, :workspace_root, context.root)
      GenServer.stop(restored_repo)
      # Committed test teardown may now purge only the original synthetic row
      # under its still-installed fixture, without affecting a real daemon.
      Repo.delete!(Repo.get!(HarnessForge.Evaluation.Run, run.id))
    end
  end

  defp pinned_record(artifact, fixture) do
    {:ok, public} = Evaluations.run(artifact["digest"], kind: :static_integrity)

    {:ok, observation} =
      CodingDockerFixture.observation(fixture, Workspaces.current_id(), public["id"])

    {:ok, private} = CodingTransport.context(observation, Workspaces.current_id(), public["id"])
    record = Repo.get!(HarnessForge.Evaluation.Run, public["id"])

    result =
      Map.merge(public, %{
        "kind" => "task",
        "runtime_name" => "opencode",
        "execution_profile_id" => "docker-coding-isolated-v2",
        "environment_profile_digest" => Coding.profile_digest(observation),
        "outcome" => "failed",
        "reason" => "synthetic_privacy_fixture",
        "cleanup_status" => "complete",
        "runtime_qualified" => false
      })

    Repo.update!(Ecto.Changeset.change(record, result: result, execution_context: private))
  end

  defp assert_only_original_commands(fixture, unrelated_id \\ nil) do
    commands = CodingDockerFixture.commands(fixture)
    assert commands != []

    for command <- commands do
      assert Enum.take(command["argv"], 2) == ["--host", fixture.endpoint]
      assert Enum.all?(Map.values(command["env"]), &is_nil/1)
      if unrelated_id, do: refute(Enum.any?(command["argv"], &String.contains?(&1, unrelated_id)))
    end
  end

  defp runtime_record(digest \\ String.duplicate("a", 64)) do
    Repo.insert!(%HarnessForge.Evaluation.Run{
      id: Ecto.UUID.generate(),
      workspace_id: Workspaces.current_id(),
      artifact_digest: digest,
      result: %{
        "kind" => "runtime_smoke",
        "outcome" => "interrupted",
        "cleanup_status" => "cleanup_failed"
      }
    })
  end

  # A deliberately seeded persistence fixture for privacy tests. It neither
  # supplies a valid native execution context nor grants command authority.
  defp command_approval_record(run_id, marker) do
    record = Repo.get!(HarnessForge.Evaluation.Run, run_id)
    profile = String.duplicate("b", 64)
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    running =
      Map.merge(record.result, %{
        "runtime_name" => "codex",
        "execution_profile_id" => "docker-codex-isolated-v1",
        "environment_profile_digest" => profile,
        "outcome" => "running"
      })

    active = Repo.update!(Ecto.Changeset.change(record, result: running))

    Repo.query!(
      "INSERT INTO command_approvals (id,workspace_id,run_id,artifact_digest,profile_digest,native_request_key,request_digest,payload,state,expires_at,inserted_at,updated_at) VALUES (?,?,?,?,?,?,?,?,'pending',?,?,?)",
      [
        Ecto.UUID.generate(),
        record.workspace_id,
        record.id,
        record.artifact_digest,
        profile,
        HarnessForge.Contracts.sha256(marker),
        HarnessForge.Contracts.sha256(marker),
        Jason.encode!(%{"fixture" => marker}),
        now,
        now,
        now
      ]
    )

    Repo.update!(Ecto.Changeset.change(active, result: record.result))
  end

  defp release_fixture(artifact, marker) do
    workspace = Workspaces.current_id()
    now = DateTime.utc_now()

    run =
      Repo.insert!(%HarnessForge.Evaluation.Run{
        id: Ecto.UUID.generate(),
        workspace_id: workspace,
        artifact_digest: artifact["digest"],
        result: %{
          "kind" => "static_integrity",
          "outcome" => "passed",
          "cleanup_status" => "not_started"
        }
      })

    release =
      Repo.insert!(%HarnessForge.Releases.Approval{
        workspace_id: workspace,
        artifact_digest: artifact["digest"],
        evaluation_id: run.id,
        scope_digest: marker,
        payload: %{"fixture" => marker},
        approval_digest: marker,
        inserted_at: now
      })

    Repo.insert!(%HarnessForge.Releases.Channel{
      workspace_id: workspace,
      scope_digest: marker,
      channel: "active",
      release_id: release.id,
      event_digest: marker,
      version: 1,
      updated_at: now
    })

    Repo.insert!(%HarnessForge.Releases.Event{
      workspace_id: workspace,
      scope_digest: marker,
      channel: "active",
      release_id: release.id,
      action: "activate",
      version: 1,
      payload: %{"fixture" => marker},
      event_digest: marker,
      inserted_at: now
    })

    {run, release}
  end

  defp db_rows(root, query) do
    {:ok, conn} = Sqlite3.open(Path.join(root, "data.sqlite3"))

    try do
      {:ok, stmt} = Sqlite3.prepare(conn, query)

      try do
        {:ok, rows} = Sqlite3.fetch_all(conn, stmt)
        rows
      after
        Sqlite3.release(conn, stmt)
      end
    after
      Sqlite3.close(conn)
    end
  end
end
