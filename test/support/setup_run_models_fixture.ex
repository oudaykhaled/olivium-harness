defmodule HarnessForge.SetupRunModelsFixture do
  @moduledoc "Persisted public synthetic setup journey; provider protocol doubles exist only in tests."
  import ExUnit.Assertions

  alias HarnessForge.{
    Company,
    CompanyAnalysisFixture,
    Contracts,
    Evidence,
    Goals,
    Models,
    Privacy,
    Repo
  }

  alias HarnessForge.Company.{SetupRuns, SetupSessions}
  alias HarnessForge.Evidence.{Corpora, Capture, Passages, Store}

  def caller,
    do: [
      authorize: fn -> true end,
      session_fingerprint: Contracts.sha256("setup-run-models-fixture"),
      view_generation: String.duplicate("a", 32),
      reset_token: 0
    ]

  def setup! do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
    :ok = Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    previous =
      Map.new(
        [:workspace_id, :workspace_root, :model_test_plug],
        &{&1, Application.get_env(:harness_forge, &1)}
      )

    workspace = Ecto.UUID.generate()
    root = Path.join([File.cwd!(), "tmp", "setup-models-" <> workspace])
    File.mkdir_p!(root)
    Application.put_env(:harness_forge, :workspace_id, workspace)
    Application.put_env(:harness_forge, :workspace_root, root)
    Application.delete_env(:harness_forge, :model_test_plug)

    ExUnit.Callbacks.on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Application.put_env(:harness_forge, :workspace_id, workspace)
        Application.put_env(:harness_forge, :workspace_root, root)
        assert {:ok, _} = Privacy.purge_workspace(workspace)
      end)

      Enum.each(previous, fn {key, value} ->
        if is_nil(value),
          do: Application.delete_env(:harness_forge, key),
          else: Application.put_env(:harness_forge, key, value)
      end)

      File.rm_rf!(root)
    end)

    {:ok, _} =
      Models.configure(%{
        "provider" => "ollama",
        "model" => "synthetic-setup-fixture",
        "endpoint" => "http://127.0.0.1:11434"
      })

    fixture = CompanyAnalysisFixture.create!(root)

    for source <- fixture.sources,
        do:
          File.write!(
            Path.join(fixture.connection["directory"], source["external_id"]),
            source["latest_revision"]["body"]
          )

    {:ok, corpus} = Corpora.create(%{"name" => "Synthetic setup authorization corpus"}, caller())

    {:ok, _} =
      Company.bind_corpus(
        fixture.project["id"],
        corpus["id"],
        fixture.profile["content_hash"],
        fixture.project["content_hash"],
        caller()
      )

    {:ok, session} = SetupSessions.create(%{}, caller())

    selection = %{
      "profile" => Map.take(fixture.profile, ~w(id content_hash)),
      "project" => Map.take(fixture.project, ~w(id content_hash)),
      "repository" => Map.take(fixture.repository, ~w(id content_hash)),
      "goal" => %{"id" => fixture.goal["id"], "content_hash" => Goals.content_hash(fixture.goal)},
      "corpus_id" => corpus["id"]
    }

    {:ok, session} = session_command(session, "change", %{"selection" => selection})

    {:ok, session} =
      session_command(session, "save", %{
        "draft" => %{"outcome_note" => "Which emergency review and rollback controls apply?"}
      })

    {:ok, session} = session_command(session, "continue", %{})

    context = %{
      root: root,
      workspace: workspace,
      fixture: fixture,
      session_id: session["id"],
      corpus: corpus
    }

    {:ok, _} =
      command(context, "prepare", %{
        "profile_version" => "setup-local-synthesis.v1",
        "connection_id" => fixture.connection["id"]
      })

    prepare_capture!(context)
  end

  def prepare_capture!(context) do
    assert {:ok, acquisition} = command(context, "acquire", %{})
    assert {:ok, _} = Capture.run(acquisition["operation_ref"]["id"])
    assert {:ok, sources} = Evidence.list_sources()

    for source <- sources,
        do: assert({:ok, _} = Passages.index_revision(source["latest_revision"]["id"]))

    assert {:ok, _} = command(context, "retrieve", %{})
    assert {:ok, view} = SetupRuns.get(context.session_id, caller())
    assert view["run"]["phase"] == "needs_input"
    assert is_map(view["run"]["prepared"])
    Map.merge(context, %{view: view, prepared: view["run"]["prepared"]})
  end

  def envelope(context, action, payload) do
    assert {:ok, view} = SetupRuns.get(context.session_id, caller())

    %{
      "version" => 1,
      "id" => context.session_id,
      "expected_session_version" => view["session_version"],
      "expected_run_version" => view["run"] && view["run"]["run_version"],
      "run_ref" => view["run"] && view["run"]["run_ref"],
      "command_id" => Ecto.UUID.generate(),
      "action" => action,
      "payload" => payload
    }
  end

  def command(context, action, payload),
    do: SetupRuns.command(envelope(context, action, payload), caller())

  def authorize!(context) do
    assert {:ok, receipt} =
             command(context, "authorize", %{"prepared_ref" => context.prepared["prepared_ref"]})

    assert {:ok, view} = SetupRuns.get(context.session_id, caller())
    assert view["run"]["phase"] == "ready"
    Map.merge(context, %{view: view, authorization_receipt: receipt})
  end

  def session_command(session, action, payload),
    do:
      SetupSessions.command(
        %{
          "id" => session["id"],
          "expected_version" => session["version"],
          "command" => action,
          "payload" => payload
        },
        caller()
      )

  def abstention,
    do: %{
      "findings" => [],
      "recommendation" => nil,
      "uncertainty" => "Synthetic protocol fixture; real company usefulness is unqualified."
    }

  def response(report),
    do: %{
      "done" => true,
      "response" => Jason.encode!(report),
      "prompt_eval_count" => 11,
      "eval_count" => 7
    }

  def rows(table),
    do:
      Repo.query!("SELECT count(*) FROM " <> table <> " WHERE workspace_id=?", [Store.workspace()]).rows
      |> hd()
      |> hd()
end
