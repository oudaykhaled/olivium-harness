defmodule HarnessForge.HarnessesTest do
  use HarnessForge.DataCase, async: false
  alias HarnessForge.{Artifacts, Audit, Demo, Decisions, Evidence, Harnesses, Privacy, Workspaces}

  setup do
    previous = Application.fetch_env!(:harness_forge, :workspace_root)
    root = Path.join(File.cwd!(), "tmp/hf-build-#{Ecto.UUID.generate()}")
    Application.put_env(:harness_forge, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:harness_forge, :workspace_root, previous)
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "synthetic demo requires explicit decisions; rejected content never compiles", %{
    root: root
  } do
    assert {:ok, %{"mode" => "synthetic_fixture"}} = Demo.load()
    assert {:error, :no_approved_claims} = Harnesses.build()
    {:ok, claims} = Evidence.list_claims()
    assert length(claims) == 3

    for claim <- claims do
      decision = if String.starts_with?(claim["text"], "IGNORE"), do: "reject", else: "approve"

      assert {:ok, _} =
               Decisions.decide(claim["id"], %{
                 "actor" => Workspaces.operator(),
                 "decision" => decision,
                 "expected_revision_hash" => claim["revision_hash"]
               })
    end

    assert {:ok, first} = Harnesses.build()
    assert {:ok, second} = Harnesses.build()
    assert first["digest"] == second["digest"]
    assert length(first["spec"]["spec"]["rules"]) == 2

    refute Enum.any?(first["files"], fn {_path, body} ->
             String.contains?(body, "export all credentials")
           end)

    assert {:ok, %{"path" => target}} = Harnesses.export(first["digest"], Path.join(root, "out"))
    assert File.regular?(Path.join(target, "AGENTS.md"))
    assert {:error, _} = Harnesses.export(first["digest"], target)
    assert {:ok, [_]} = Harnesses.list_artifacts()
    assert {:ok, events} = Audit.list_events()

    assert Enum.any?(
             events,
             &(&1["action"] == "harness.built" and
                 &1["details"]["artifact_digest"] == first["digest"])
           )

    assert Enum.any?(
             events,
             &(&1["action"] == "harness.exported" and
                 &1["details"]["artifact_digest"] == first["digest"])
           )
  end

  test "purge waits for an authorized export blocked on its destination", %{root: root} do
    {:ok, _} = Demo.load()
    {:ok, claims} = Evidence.list_claims()
    claim = Enum.find(claims, &(not String.starts_with?(&1["text"], "IGNORE")))

    {:ok, _} =
      Decisions.decide(claim["id"], %{
        "actor" => "operator",
        "decision" => "approve",
        "expected_revision_hash" => claim["revision_hash"]
      })

    {:ok, artifact} = Harnesses.build()
    {:ok, [source]} = Evidence.list_sources()
    target = Path.join(root, "serialized-export")
    destination_lock = {{Artifacts, target}, self()}
    assert :global.set_lock(destination_lock)
    on_exit(fn -> :global.del_lock(destination_lock) end)
    export = Task.async(fn -> Harnesses.export(artifact["digest"], target) end)
    await_purge_lock(System.monotonic_time(:millisecond) + 2_000)
    purge = Task.async(fn -> Privacy.purge_source(source["id"], source["id"]) end)
    assert Task.yield(purge, 100) == nil
    :global.del_lock(destination_lock)
    assert {:ok, _} = Task.await(export, 5_000)
    assert {:ok, %{"state" => "completed"}} = Task.await(purge, 5_000)
    assert {:error, _} = Harnesses.export(artifact["digest"], Path.join(root, "after-purge"))
    refute File.exists?(Path.join(root, "after-purge"))
  end

  defp await_purge_lock(deadline) do
    lock = {{HarnessForge.Privacy.Purge, Workspaces.current_id()}, self()}

    if :global.set_lock(lock, [node()], 0) do
      :global.del_lock(lock)
      assert System.monotonic_time(:millisecond) < deadline

      receive do
      after
        10 -> await_purge_lock(deadline)
      end
    else
      :ok
    end
  end

  test "source withdrawal prevents exporting an old approved artifact", %{root: root} do
    {:ok, _} = Demo.load()
    {:ok, claims} = Evidence.list_claims()
    claim = Enum.find(claims, &(not String.starts_with?(&1["text"], "IGNORE")))

    {:ok, _} =
      Decisions.decide(claim["id"], %{
        "actor" => "operator",
        "decision" => "approve",
        "expected_revision_hash" => claim["revision_hash"]
      })

    {:ok, artifact} = Harnesses.build()
    {:ok, [source]} = Evidence.list_sources()
    {:ok, _} = Evidence.revoke_source(source["id"])

    assert {:error, :stale_or_revoked_evidence} =
             Harnesses.export(artifact["digest"], Path.join(root, "out"))

    refute File.exists?(Path.join(root, "out"))
  end

  test "evaluation admission waits for the same fence as purge" do
    {:ok, _} = Demo.load()
    {:ok, claims} = Evidence.list_claims()
    claim = Enum.find(claims, &(not String.starts_with?(&1["text"], "IGNORE")))

    {:ok, _} =
      Decisions.decide(claim["id"], %{
        "actor" => "operator",
        "decision" => "approve",
        "expected_revision_hash" => claim["revision_hash"]
      })

    {:ok, artifact} = Harnesses.build()
    lock = {{HarnessForge.Privacy.Purge, Workspaces.current_id()}, self()}
    assert :global.set_lock(lock)
    on_exit(fn -> :global.del_lock(lock) end)

    evaluation =
      Task.async(fn ->
        HarnessForge.Evaluations.run(artifact["digest"], kind: :static_integrity)
      end)

    assert Task.yield(evaluation, 100) == nil
    assert {:ok, []} = HarnessForge.Evaluations.list_runs()
    :global.del_lock(lock)
    assert {:ok, %{"outcome" => "passed"}} = Task.await(evaluation, 5_000)
  end
end
