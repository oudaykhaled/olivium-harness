defmodule HarnessForge.SetupSessionPrivacyTest do
  use ExUnit.Case, async: false

  alias HarnessForge.{
    Company,
    CompanyAnalysisFixture,
    Contracts,
    Goals,
    Privacy,
    Repo,
    Workspaces
  }

  alias HarnessForge.Company.SetupSessions
  alias HarnessForge.Evidence.Corpora

  setup tags do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: tags[:committed] != true)
    previous = {Workspaces.current_id(), Application.fetch_env!(:harness_forge, :workspace_root)}
    id = Ecto.UUID.generate()
    base = Path.join(File.cwd!(), "tmp/setup-privacy-#{id}")
    root = Path.join(base, "workspace")
    Enum.each(["", "artifacts", "runs", "tmp"], &File.mkdir_p!(Path.join(root, &1)))
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

    %{id: id, root: root, base: base}
  end

  test "workspace inventory and content purge include saved setup drafts", c do
    {:ok, session} = SetupSessions.create(%{}, caller())

    assert {:ok, saved} =
             SetupSessions.command(
               envelope(session, "save", %{
                 "draft" => %{"outcome_note" => "Synthetic private intent"}
               }),
               caller()
             )

    assert {:ok, inventory} = Privacy.inventory()
    assert inventory["records"]["setup_sessions"] == 1
    assert {:ok, _} = Privacy.purge_workspace(c.id)

    assert {:error, %{"code" => "not_found"}} =
             SetupSessions.get(%{"id" => saved["id"]}, caller())

    assert {:ok, inventory} = Privacy.inventory()
    assert inventory["records"]["setup_sessions"] == 0
  end

  @tag :committed
  test "real backup and quarantined restore remap session ownership without granting capabilities",
       c do
    {:ok, session} = SetupSessions.create(%{}, caller())

    {:ok, saved} =
      SetupSessions.command(
        envelope(session, "save", %{"draft" => %{"outcome_note" => "Synthetic saved outcome"}}),
        caller()
      )

    selected = save_selected_scope(c)
    backup = Path.join(c.base, "backup")
    restored = Path.join(c.base, "restored")
    assert {:ok, _} = Privacy.backup(backup)
    assert {:ok, result} = Privacy.restore(backup, restored)
    assert result["state"] == "quarantined"
    refute result["approvals_restored"]
    new_id = result["workspace_id"]
    refute new_id == c.id

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
      assert [[^new_id, "local-operator"]] =
               Repo.query!("SELECT workspace_id,owner FROM setup_sessions WHERE id=?", [
                 saved["id"]
               ]).rows

      assert Repo.query!("PRAGMA foreign_key_check").rows == []
      assert {:ok, recovered} = SetupSessions.get(%{"id" => saved["id"]}, caller("fresh login"))
      assert recovered["draft"] == saved["draft"]
      assert recovered["version"] == saved["version"]
      assert recovered["reference_status"]["status"] == "needs_input"

      assert {:ok, historical} =
               SetupSessions.get(%{"id" => selected["id"]}, caller("fresh login"))

      assert historical["reference_status"]["status"] in ~w(stale unavailable)
      refute historical["reference_status"]["status"] == "current"

      assert Repo.query!("SELECT count(*) FROM model_requests WHERE workspace_id=?", [new_id]).rows ==
               [[0]]

      assert Repo.query!("SELECT count(*) FROM stage_operations WHERE workspace_id=?", [new_id]).rows ==
               [[0]]
    after
      Repo.put_dynamic_repo(old_repo)
      Supervisor.stop(restored_repo)
      Application.put_env(:harness_forge, :workspace_id, c.id)
      Application.put_env(:harness_forge, :workspace_root, c.root)
    end
  end

  defp save_selected_scope(c) do
    f = CompanyAnalysisFixture.create!(c.root)
    {:ok, corpus} = Corpora.create(%{"name" => "Synthetic setup restore scope"}, caller())

    {:ok, _} =
      Company.bind_corpus(
        f.project["id"],
        corpus["id"],
        f.profile["content_hash"],
        f.project["content_hash"],
        caller()
      )

    {:ok, context} =
      Corpora.requirements_context(
        corpus["id"],
        f.project["id"],
        f.goal["id"],
        Goals.content_hash(f.goal),
        caller()
      )

    {:ok, declaration} =
      Corpora.declare_requirements(
        corpus["id"],
        context["expected"],
        %{
          "project_id" => f.project["id"],
          "goal_id" => f.goal["id"],
          "primary_connection_id" => f.connection["id"],
          "entries" => [
            %{
              "connection_id" => f.connection["id"],
              "requirement" => "required",
              "capture_run_id" => nil,
              "capture_revision" => nil
            }
          ]
        },
        caller()
      )

    {:ok, session} = SetupSessions.create(%{}, caller())

    selection = %{
      "profile" => Map.take(f.profile, ~w(id content_hash)),
      "project" => Map.take(f.project, ~w(id content_hash)),
      "repository" => Map.take(f.repository, ~w(id content_hash)),
      "goal" => %{"id" => f.goal["id"], "content_hash" => Goals.content_hash(f.goal)},
      "corpus_id" => corpus["id"],
      "declaration" => Map.take(declaration, ~w(id digest))
    }

    {:ok, selected} =
      SetupSessions.command(envelope(session, "change", %{"selection" => selection}), caller())

    assert selected["reference_status"]["status"] == "current"
    selected
  end

  defp envelope(session, command, payload),
    do: %{
      "id" => session["id"],
      "expected_version" => session["version"],
      "command" => command,
      "payload" => payload
    }

  defp caller(identity \\ "setup privacy operator"),
    do: [
      authorize: fn -> true end,
      session_fingerprint: Contracts.sha256(identity),
      view_generation: String.duplicate("c", 32),
      reset_token: 0
    ]
end
