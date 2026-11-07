defmodule HarnessForge.RevisionUseHoldsPrivacyTest do
  use ExUnit.Case, async: false
  alias HarnessForge.{Contracts, Evidence, Privacy, Repo, Workspaces}
  alias HarnessForge.Evidence.RevisionUseHolds

  setup tags do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: tags[:committed] != true)
    previous = {Workspaces.current_id(), Application.fetch_env!(:harness_forge, :workspace_root)}
    id = Ecto.UUID.generate()
    base = Path.join(File.cwd!(), "tmp/revision-use-privacy-#{id}")
    root = Path.join(base, "workspace")
    Enum.each(["", "artifacts", "runs", "tmp", "documents"], &File.mkdir_p!(Path.join(root, &1)))
    Application.put_env(:harness_forge, :workspace_id, id)
    Application.put_env(:harness_forge, :workspace_root, root)

    on_exit(fn ->
      if tags[:committed] do
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          Application.put_env(:harness_forge, :workspace_id, id)
          Application.put_env(:harness_forge, :workspace_root, root)
          assert {:ok, _} = Privacy.purge_workspace(id)
        end)
      end

      {old_id, old_root} = previous
      Application.put_env(:harness_forge, :workspace_id, old_id)
      Application.put_env(:harness_forge, :workspace_root, old_root)
      File.rm_rf!(base)
    end)

    {:ok, connection} =
      Evidence.connect(%{
        "name" => "Synthetic privacy records",
        "provider" => "local",
        "directory" => Path.join(root, "documents")
      })

    source = capture(connection, "held.md", "Synthetic exact privacy canary.")
    other = capture(connection, "other.md", "An independent public synthetic record.")
    {:ok, hold} = Evidence.restrict_revision(request(source), caller())
    %{id: id, base: base, root: root, source: source, other: other, hold: hold}
  end

  test "typed inventory and source purge remove both negative authority rows before their parents",
       c do
    assert {:ok, inventory} = Privacy.inventory()
    assert inventory["records"]["revision_use_holds"] == 1
    assert inventory["records"]["revision_use_cleanup"] == 1
    assert {:ok, receipt} = Privacy.purge_source(c.source["id"], c.source["id"])
    refute receipt["physical_erasure"]
    assert :ok = Privacy.ready()

    assert {:error, :not_found} =
             Evidence.revision_restriction_status(c.hold["event_id"], caller())

    assert [[0]] =
             Repo.query!("SELECT count(*) FROM revision_use_cleanup WHERE workspace_id=?", [c.id]).rows

    assert [[0]] =
             Repo.query!("SELECT count(*) FROM revision_use_holds WHERE workspace_id=?", [c.id]).rows

    assert {:ok, %{"latest_revision" => nil}} = Evidence.get_source(c.other["id"])
    assert Repo.query!("PRAGMA foreign_key_check").rows == []
  end

  test "workspace purge removes pending holds and checkpoints without leaving a usable event",
       c do
    assert {:ok, _} = Privacy.purge_workspace(c.id)
    assert {:ok, inventory} = Privacy.inventory()
    assert inventory["records"]["revision_use_holds"] == 0
    assert inventory["records"]["revision_use_cleanup"] == 0

    assert {:error, :not_found} =
             Evidence.revision_restriction_status(c.hold["event_id"], caller())

    assert Repo.query!("PRAGMA foreign_key_check").rows == []
  end

  @tag :committed
  test "a real backup and quarantined restore preserve pending negative authority and immutable identities",
       c do
    backup = Path.join(c.base, "backup")
    restored = Path.join(c.base, "restored")
    assert {:ok, _} = Privacy.backup(backup)
    assert {:ok, result} = Privacy.restore(backup, restored)
    new_id = result["workspace_id"]
    refute new_id == c.id
    refute result["approvals_restored"]

    {:ok, restored_repo} =
      Repo.start_link(
        name: nil,
        database: Path.join(restored, "data.sqlite3"),
        pool: DBConnection.ConnectionPool,
        pool_size: 1
      )

    old_repo = Repo.put_dynamic_repo(restored_repo)
    Application.put_env(:harness_forge, :workspace_id, new_id)
    Application.put_env(:harness_forge, :workspace_root, restored)

    try do
      event_id = c.hold["event_id"]

      assert [[^event_id, ^new_id, "pending", 0]] =
               Repo.query!(
                 "SELECT event_id,workspace_id,state,lock_version FROM revision_use_cleanup WHERE event_id=?",
                 [event_id]
               ).rows

      assert [[^new_id]] =
               Repo.query!("SELECT workspace_id FROM revision_use_holds WHERE id=?", [event_id]).rows

      assert {:error, :revision_use_denied} =
               RevisionUseHolds.assert_use(
                 c.source["id"],
                 c.source["latest_revision"]["id"],
                 c.source["latest_revision"]["body_hash"],
                 "retrieval"
               )

      assert {:ok, receipt} = Evidence.revision_restriction_status(event_id, caller())
      assert receipt == c.hold
      assert {:ok, %{"latest_revision" => nil}} = Evidence.get_source(c.source["id"])

      assert {:error, _} =
               Repo.query("UPDATE revision_use_holds SET actor='other' WHERE id=?", [event_id])

      assert {:error, _} = Repo.query("DELETE FROM revision_use_holds WHERE id=?", [event_id])

      assert {:error, _} =
               Repo.query("UPDATE revision_use_cleanup SET workspace_id=? WHERE event_id=?", [
                 c.id,
                 event_id
               ])

      assert Repo.query!("PRAGMA foreign_key_check").rows == []
      assert {:ok, done} = Evidence.resume_revision_cleanup(event_id, 0, caller())
      assert done["cleanup_state"] == "completed"

      assert {:error, :revision_use_denied} =
               RevisionUseHolds.assert_source_unheld(c.source["id"])
    after
      Repo.put_dynamic_repo(old_repo)
      Supervisor.stop(restored_repo)
      Application.put_env(:harness_forge, :workspace_id, c.id)
      Application.put_env(:harness_forge, :workspace_root, c.root)
    end
  end

  defp capture(connection, external_id, body) do
    {:ok, source} =
      Evidence.import_markdown(connection["id"], %{
        "external_id" => external_id,
        "title" => external_id,
        "body" => body
      })

    source
  end

  defp request(source),
    do: %{
      "version" => 1,
      "source_id" => source["id"],
      "revision_id" => source["latest_revision"]["id"],
      "body_hash" => source["latest_revision"]["body_hash"],
      "expected_generation" => 0,
      "command_id" => Ecto.UUID.generate(),
      "reason_code" => "operator_restriction"
    }

  defp caller,
    do: [
      authorize: fn -> true end,
      session_fingerprint: Contracts.sha256("synthetic privacy operator"),
      view_generation: String.duplicate("a", 32),
      reset_token: 0
    ]
end
