defmodule HarnessForge.SetupRunsTest do
  use HarnessForge.DataCase, async: false
  alias HarnessForge.{Company, CompanyAnalysisFixture, Goals, Repo, Workspaces}
  alias HarnessForge.Company.{SetupSession, SetupSessions, SetupRuns}
  alias HarnessForge.Evidence.{Capture, Corpora, Store}
  alias HarnessForge.Models.Configuration
  alias HarnessForge.Privacy.Purge

  setup do
    previous = {Workspaces.root(), Workspaces.current_id()}
    id = Ecto.UUID.generate()
    root = Path.join(File.cwd!(), "tmp/setup-runs-#{id}")
    Enum.each(~w(artifacts runs tmp), &File.mkdir_p!(Path.join(root, &1)))
    Application.put_env(:harness_forge, :workspace_root, root)
    Application.put_env(:harness_forge, :workspace_id, id)

    on_exit(fn ->
      Application.put_env(:harness_forge, :workspace_root, elem(previous, 0))
      Application.put_env(:harness_forge, :workspace_id, elem(previous, 1))
      File.rm_rf!(root)
    end)

    {:ok, _} =
      Configuration.configure(%{
        "provider" => "ollama",
        "endpoint" => "http://127.0.0.1:11434",
        "model" => "synthetic-config-only"
      })

    %{root: root}
  end

  test "prepare explicitly upgrades v1, pins a local proposal and creates no capture, consent or budget",
       c do
    {session, fixture, _} = saved_scope(c.root)
    assert Repo.get!(SetupSession, session["id"]).schema_version == 1
    before = authority_counts()

    assert {:ok, receipt} =
             SetupRuns.command(command(session, nil, "prepare", prepare(fixture)), caller())

    assert receipt["session_version"] == session["version"] + 1
    assert receipt["run_version"] == 1
    assert receipt["operation_ref"] == nil
    assert {:ok, view} = SetupRuns.get(session["id"], caller())
    assert view["run"]["phase"] == "proposed"
    assert view["run"]["config"]["history"] == "current_snapshot_only"
    assert view["run"]["config"]["query_text"] == fixture.goal["title"]

    assert view["run"]["config"]["model_limits"] == %{
             "max_requests" => 2,
             "max_tokens" => 100_000,
             "max_cost_microusd" => 0,
             "deadline_seconds" => 300
           }

    assert view["run"]["usage"]["budget_id"] == nil
    assert Repo.get!(SetupSession, session["id"]).schema_version == 2
    assert authority_counts() == before
    refute Jason.encode!(view) =~ "Every production change requires two reviewers."
    assert {:ok, saved} = SetupSessions.get(%{"id" => session["id"]}, caller())
    assert saved["next_action"]["reason"] == "run_authorization_required"

    assert {:error, %{"code" => "authorization_required"}} =
             SetupSessions.command(
               %{
                 "id" => saved["id"],
                 "expected_version" => saved["version"],
                 "command" => "continue",
                 "payload" => %{}
               },
               caller()
             )
  end

  test "matching command replay returns the original receipt before stale versions without work",
       c do
    {session, f, _} = saved_scope(c.root)
    envelope = command(session, nil, "prepare", prepare(f))
    assert {:ok, receipt} = SetupRuns.command(envelope, caller())
    before = counts()
    assert {:ok, ^receipt} = SetupRuns.command(envelope, caller())
    assert counts() == before

    assert {:error, %{"code" => "command_conflict", "current" => nil}} =
             SetupRuns.command(
               put_in(envelope, ["payload", "connection_id"], Ecto.UUID.generate()),
               caller()
             )

    assert counts() == before
  end

  test "identical active prepare is a no-op receipt and cannot stale an in-flight capture", c do
    {session, f, _} = saved_scope(c.root)
    assert {:ok, _} = SetupRuns.command(command(session, nil, "prepare", prepare(f)), caller())
    view = view(session)
    assert {:ok, acquired} = SetupRuns.command(from_view(view, "acquire", %{}), caller())
    acquiring = view(session)

    assert {:ok, repeated} =
             SetupRuns.command(from_view(acquiring, "prepare", prepare(f)), caller())

    assert repeated["session_version"] == acquiring["session_version"]
    assert repeated["run_version"] == acquiring["run"]["run_version"]
    assert {:ok, binding} = SetupRuns.operation_binding(acquired["operation_ref"]["id"], caller())
    assert binding["expected_run_version"] == acquired["run_version"]
    assert view(session)["run"]["phase"] == "acquiring"
  end

  test "capture registration, receipt and dual CAS roll back when another capture occupies the queue",
       c do
    {session, f, corpus} = saved_scope(c.root)
    assert {:ok, _} = SetupRuns.command(command(session, nil, "prepare", prepare(f)), caller())

    assert {:ok, _} =
             Capture.start_capture(
               corpus["id"],
               f.connection["id"],
               corpus["semantic_generation"],
               caller()
             )

    prepared = view(session)
    before = counts()
    assert {:error, _} = SetupRuns.command(from_view(prepared, "acquire", %{}), caller())
    assert view(session) == prepared
    assert counts() == before
  end

  test "both versions and exact current run identity fence stale commands", c do
    {session, f, _} = saved_scope(c.root)
    assert {:ok, _} = SetupRuns.command(command(session, nil, "prepare", prepare(f)), caller())
    old = view(session)
    assert {:ok, _} = SetupRuns.command(from_view(old, "cancel", %{}), caller())

    assert {:error, %{"code" => "conflict", "current" => current}} =
             SetupRuns.command(from_view(old, "acquire", %{}), caller())

    assert current["run_version"] > old["run"]["run_version"]

    assert {:error, %{"code" => "conflict"}} =
             SetupRuns.command(
               put_in(
                 from_view(view(session), "new_run", %{
                   "predecessor_run_ref" => old["run"]["run_ref"]
                 }),
                 ["run_ref", "digest"],
                 String.duplicate("0", 64)
               ),
               caller()
             )
  end

  test "cancel and explicit replacement retain predecessor usage and create no grant or budget",
       c do
    {session, f, _} = saved_scope(c.root)
    assert {:ok, _} = SetupRuns.command(command(session, nil, "prepare", prepare(f)), caller())
    first = view(session)

    assert {:error, %{"code" => "phase_conflict"}} =
             SetupRuns.command(
               from_view(first, "new_run", %{"predecessor_run_ref" => first["run"]["run_ref"]}),
               caller()
             )

    assert {:ok, _} = SetupRuns.command(from_view(first, "cancel", %{}), caller())
    cancelled = view(session)
    before = authority_counts()

    assert {:ok, _} =
             SetupRuns.command(
               from_view(cancelled, "new_run", %{"predecessor_run_ref" => first["run"]["run_ref"]}),
               caller()
             )

    replacement = view(session)
    refute replacement["run"]["run_ref"] == first["run"]["run_ref"]
    assert replacement["run"]["predecessor_run_ref"] == first["run"]["run_ref"]
    assert replacement["run"]["config_ref"] == first["run"]["config_ref"]
    assert replacement["run"]["usage"]["budget_id"] == nil
    assert [%{"run_ref" => ref, "usage" => usage}] = replacement["predecessor_usage"]
    assert ref == first["run"]["run_ref"]
    assert usage["uncertain_requests"] == 0
    assert authority_counts() == before

    assert {:ok, %{"predecessor_usage" => [_], "history_cursor" => nil}} =
             SetupRuns.history(session["id"], nil, caller())

    assert {:error, %{"code" => "invalid_input"}} =
             SetupRuns.history(session["id"], "forged-cursor", caller())
  end

  test "changed saved outcome cancels admission without erasing historical intent or usage", c do
    {session, f, _} = saved_scope(c.root)
    assert {:ok, _} = SetupRuns.command(command(session, nil, "prepare", prepare(f)), caller())
    before = view(session)
    assert {:ok, saved} = SetupSessions.get(%{"id" => session["id"]}, caller())

    assert {:ok, _} =
             SetupSessions.command(
               %{
                 "id" => saved["id"],
                 "expected_version" => saved["version"],
                 "command" => "save",
                 "payload" => %{"draft" => %{"outcome_note" => "New explicit outcome"}}
               },
               caller()
             )

    current = view(session)
    assert current["run"]["phase"] == "cancelled"
    assert current["run"]["config"] == before["run"]["config"]
    assert current["run"]["usage"] == before["run"]["usage"]

    assert {:error, %{"code" => "conflict"}} =
             SetupRuns.command(from_view(before, "acquire", %{}), caller())
  end

  test "GET and history never create commands, operations, captures or model admissions", c do
    {session, f, _} = saved_scope(c.root)
    assert {:ok, _} = SetupRuns.command(command(session, nil, "prepare", prepare(f)), caller())
    before = counts()
    # A read must not re-observe the physical source or start acquisition.
    File.rename!(f.connection["directory"], f.connection["directory"] <> "-not-present")

    Enum.each(1..3, fn _ ->
      assert {:ok, _} = SetupRuns.get(session["id"], caller())
      assert {:ok, _} = SetupRuns.history(session["id"], nil, caller())
    end)

    assert counts() == before

    assert {:error, %{"code" => "unauthorized", "current" => nil}} =
             SetupRuns.get(session["id"], Keyword.put(caller(), :authorize, fn -> false end))

    foreign = Store.workspace()
    Application.put_env(:harness_forge, :workspace_id, Ecto.UUID.generate())

    try do
      assert {:error, %{"code" => "not_found", "current" => nil}} =
               SetupRuns.get(session["id"], caller())
    after
      Application.put_env(:harness_forge, :workspace_id, foreign)
    end
  end

  test "foreign publication and invalid phase cannot advance the accepted operation", c do
    {session, f, _} = saved_scope(c.root)
    assert {:ok, _} = SetupRuns.command(command(session, nil, "prepare", prepare(f)), caller())
    prepared = view(session)

    assert {:error, %{"code" => "phase_conflict"}} =
             SetupRuns.command(
               from_view(prepared, "analyze", %{
                 "prepared_ref" => %{
                   "id" => Ecto.UUID.generate(),
                   "digest" => String.duplicate("a", 64)
                 }
               }),
               caller()
             )

    assert {:ok, receipt} = SetupRuns.command(from_view(prepared, "acquire", %{}), caller())
    before = view(session)

    assert {:error, _} =
             Purge.synchronize(fn ->
               Store.transaction(fn ->
                 SetupRuns.publish_operation(
                   receipt["operation_ref"],
                   receipt["run_version"],
                   %{"id" => Ecto.UUID.generate(), "digest" => String.duplicate("a", 64)},
                   caller()
                 )
               end)
             end)

    assert view(session) == before
    assert {:ok, _} = SetupRuns.command(from_view(before, "cancel", %{}), caller())

    assert {:error, %{"code" => "cancelled"}} =
             SetupRuns.operation_binding(receipt["operation_ref"]["id"], caller())
  end

  test "oversized outcome and missing model are recoverable without partial run state", c do
    {session, f, _} = saved_scope(c.root)

    assert {:ok, _} =
             SetupSessions.command(
               %{
                 "id" => session["id"],
                 "expected_version" => session["version"],
                 "command" => "save",
                 "payload" => %{"draft" => %{"outcome_note" => String.duplicate("x", 257)}}
               },
               caller()
             )

    assert {:ok, saved} = SetupSessions.get(%{"id" => session["id"]}, caller())

    assert {:error, %{"code" => "invalid_input"}} =
             SetupRuns.command(command(saved, nil, "prepare", prepare(f)), caller())

    assert view(saved)["run"] == nil

    assert {:ok, _} =
             SetupSessions.command(
               %{
                 "id" => saved["id"],
                 "expected_version" => saved["version"],
                 "command" => "save",
                 "payload" => %{"draft" => %{"outcome_note" => "Short outcome"}}
               },
               caller()
             )

    assert {:ok, _} = Configuration.configure(%{"provider" => "ollama", "model" => nil})
    assert {:ok, saved} = SetupSessions.get(%{"id" => saved["id"]}, caller())

    assert {:error, %{"code" => "model_unavailable"}} =
             SetupRuns.command(command(saved, nil, "prepare", prepare(f)), caller())

    assert view(saved)["run"] == nil
  end

  defp saved_scope(root) do
    f = CompanyAnalysisFixture.create!(root)
    {:ok, corpus} = Corpora.create(%{"name" => "Synthetic setup run corpus"}, caller())

    {:ok, _} =
      Company.bind_corpus(
        f.project["id"],
        corpus["id"],
        f.profile["content_hash"],
        f.project["content_hash"],
        caller()
      )

    selection =
      Map.new(
        [{"profile", f.profile}, {"project", f.project}, {"repository", f.repository}],
        fn {key, row} -> {key, Map.take(row, ~w(id content_hash))} end
      )
      |> Map.put("goal", %{"id" => f.goal["id"], "content_hash" => Goals.content_hash(f.goal)})
      |> Map.put("corpus_id", corpus["id"])

    {:ok, session} = SetupSessions.create(%{}, caller())

    {:ok, session} =
      SetupSessions.command(
        %{
          "id" => session["id"],
          "expected_version" => session["version"],
          "command" => "change",
          "payload" => %{"selection" => selection}
        },
        caller()
      )

    {:ok, session} =
      SetupSessions.command(
        %{
          "id" => session["id"],
          "expected_version" => session["version"],
          "command" => "continue",
          "payload" => %{}
        },
        caller()
      )

    {session, f, corpus}
  end

  defp view(session) do
    assert {:ok, current} = SetupRuns.get(session["id"], caller())
    current
  end

  defp prepare(f),
    do: %{"profile_version" => "setup-local-synthesis.v1", "connection_id" => f.connection["id"]}

  defp command(session, run, action, payload),
    do: %{
      "version" => 1,
      "id" => session["id"],
      "expected_session_version" => session["version"],
      "expected_run_version" => if(run, do: run["run_version"]),
      "run_ref" => if(run, do: run["run_ref"]),
      "command_id" => Ecto.UUID.generate(),
      "action" => action,
      "payload" => payload
    }

  defp from_view(view, action, payload),
    do:
      command(
        %{"id" => view["id"], "version" => view["session_version"]},
        view["run"],
        action,
        payload
      )

  defp caller,
    do: [
      authorize: fn -> true end,
      session_fingerprint: String.duplicate("a", 64),
      view_generation: String.duplicate("b", 32),
      reset_token: 0
    ]

  defp authority_counts,
    do:
      table_counts(
        ~w(model_requests model_budgets model_run_authorizations model_run_disclosures stage_consent_revisions capture_runs)
      )

  defp counts,
    do:
      table_counts(
        ~w(setup_sessions setup_runs setup_run_commands setup_run_operations capture_runs model_requests model_budgets model_run_authorizations model_run_disclosures stage_consent_revisions)
      )

  defp table_counts(tables),
    do:
      Map.new(tables, fn table ->
        {table,
         Repo.query!("SELECT count(*) FROM " <> table <> " WHERE workspace_id=?", [
           Store.workspace()
         ]).rows}
      end)
end
