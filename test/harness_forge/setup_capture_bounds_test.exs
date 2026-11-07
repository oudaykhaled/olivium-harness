defmodule HarnessForge.SetupCaptureBoundsTest do
  use HarnessForge.DataCase, async: false
  alias HarnessForge.{Company, CompanyAnalysisFixture, Contracts, Goals, Repo, Workspaces}
  alias HarnessForge.Company.{SetupSessions, SetupRuns}

  alias HarnessForge.Evidence.{
    Capture,
    CaptureRun,
    Corpora,
    SetupCaptureBinding,
    SetupCaptureCharge,
    SetupCaptureCounter,
    SetupCapturePage,
    SetupCaptureBounds,
    Store
  }

  alias HarnessForge.Evidence.Capture.{Scanner, Writer}
  alias HarnessForge.Models.Configuration
  alias HarnessForge.Privacy.Purge

  setup do
    previous = {Workspaces.root(), Workspaces.current_id()}
    workspace = Ecto.UUID.generate()
    root = Path.join(File.cwd!(), "tmp/setup-capture-bounds-#{workspace}")
    Enum.each(~w(artifacts runs tmp), &File.mkdir_p!(Path.join(root, &1)))
    Application.put_env(:harness_forge, :workspace_root, root)
    Application.put_env(:harness_forge, :workspace_id, workspace)

    on_exit(fn ->
      Application.put_env(:harness_forge, :workspace_root, elem(previous, 0))
      Application.put_env(:harness_forge, :workspace_id, elem(previous, 1))
      File.rm_rf!(root)
    end)

    {:ok, _} =
      Configuration.configure(%{"provider" => "ollama", "model" => "synthetic-config-only"})

    %{root: root}
  end

  test "cancelling an actual setup capture frees the queue for explicit replacement acquisition",
       c do
    {session, f, first} = acquire!(c.root)
    first_ref = current!(session)["run"]["run_ref"]
    assert Repo.get!(CaptureRun, first["operation_ref"]["id"]).state == "queued"
    assert {:ok, _} = SetupRuns.command(envelope(current!(session), "cancel", %{}), caller())
    cancelled = Repo.get!(CaptureRun, first["operation_ref"]["id"])
    assert cancelled.state == "cancelled"
    assert cancelled.lease_token == nil
    assert cancelled.lease_until == nil

    assert {:error, %{"code" => "cancelled"}} =
             SetupRuns.operation_binding(first["operation_ref"]["id"], caller())

    assert {:ok, replacement} =
             SetupRuns.command(
               envelope(current!(session), "new_run", %{"predecessor_run_ref" => first_ref}),
               caller()
             )

    assert replacement["run_ref"] != first_ref
    assert current!(session)["run"]["usage"]["budget_id"] == nil

    assert {:ok, second} =
             SetupRuns.command(envelope(current!(session), "acquire", %{}), caller())

    refute second["operation_ref"] == first["operation_ref"]
    second_capture = Repo.get!(CaptureRun, second["operation_ref"]["id"])
    assert second_capture.state == "queued"
    assert second_capture.connection_id == f.connection["id"]
    assert capture_count() == 2
    assert no_model_admission?()
  end

  test "an identical directory page replay and a rejected changed replay do not recharge entries",
       c do
    {_session, _f, receipt} = acquire!(c.root)
    {run, lease} = install_worker_lease!(receipt)
    batch = page(run, [entry("policy.md"), entry("incidents.md")])
    assert {:ok, :bounded} = admit(run, lease, batch)
    before = accounting(run.id)
    assert before.counter.entries_admitted == 2
    assert length(before.entries) == 2
    assert length(before.pages) == 1
    assert {:ok, :replay} = admit(run, lease, batch)
    assert accounting(run.id) == before
    changed = Map.put(batch, "entries", [entry("policy.md"), entry("decision.md")])
    assert {:error, :acquisition_incomplete} = admit(run, lease, changed)
    assert accounting(run.id) == before
  end

  test "a claimed setup run cannot select the legacy reader after purge removes its binding", c do
    {_session, f, receipt} = acquire!(c.root)
    {claimed, lease} = install_worker_lease!(receipt)
    assert :ok = Capture.check_lease(claimed.id, lease)
    assert SetupCaptureBounds.bounded?(claimed)
    File.write!(Path.join(f.connection["directory"], "pending.md"), "UNREAD_PURGED_SETUP_CANARY")
    unrelated = Path.join(c.root, "unrelated")
    File.mkdir_p!(unrelated)

    {:ok, connection} =
      HarnessForge.Evidence.connect(%{
        "provider" => "local",
        "name" => "Unrelated public fixture",
        "directory" => unrelated
      })

    {:ok, source} =
      HarnessForge.Evidence.import_markdown(connection["id"], %{
        "external_id" => "unrelated.md",
        "title" => "Unrelated",
        "body" => "Synthetic unrelated evidence."
      })

    assert {:ok, _} = HarnessForge.Privacy.purge_source(source["id"], source["id"])
    assert Repo.get_by(SetupCaptureBinding, capture_id: claimed.id) == nil
    # This is the original in-memory run after a successful prior lease check.
    # Its server marker remains bounded even though mutable provenance is gone.
    assert SetupCaptureBounds.bounded?(claimed)
    assert {:error, :cancelled} = SetupCaptureBounds.check(claimed)

    assert {:error, :cancelled} =
             SetupCaptureBounds.admit_page(
               claimed,
               lease,
               "",
               page(claimed, [entry("pending.md")])
             )

    assert {:error, :cancelled} =
             SetupCaptureBounds.read(
               claimed,
               lease,
               f.connection["directory"],
               entry("pending.md")
             )

    assert Repo.get!(CaptureRun, claimed.id).state == "cancelled"

    assert Repo.query!(
             "SELECT count(*) FROM evidence_sources WHERE workspace_id=? AND external_id='pending.md'",
             [Store.workspace()]
           ).rows == [[0]]

    assert no_model_admission?()
  end

  test "a body read rejection retains its prior allowance and publishes no evidence", c do
    {_session, f, receipt} = acquire!(c.root)
    directory = f.connection["directory"]
    File.write!(Path.join(directory, "invalid.md"), <<255, 0, 255>>)
    {run, lease} = install_worker_lease!(receipt)
    item = entry("invalid.md")
    assert {:ok, :bounded} = admit(run, lease, page(run, [item]))
    checkpoint_item!(run, "invalid.md")
    before_sources = source_count()
    assert {:error, :binary_file} = failure = SetupCaptureBounds.read(run, lease, directory, item)
    reserved = accounting(run.id)
    assert reserved.counter.files_reserved == 1
    assert reserved.counter.bytes_reserved == 3
    assert reserved.counter.bytes_committed == 0
    assert [%{state: "reserved", allowance_bytes: 3, actual_bytes: nil}] = reserved.bodies
    assert source_count() == before_sources

    assert {:ok, :committed} = Writer.commit(run, lease, [{"invalid.md", failure}])
    after_failure = accounting(run.id)
    assert after_failure.counter.files_reserved == 1
    assert after_failure.counter.bytes_reserved == 3
    assert after_failure.counter.bytes_committed == 0
    assert [%{state: "uncertain", allowance_bytes: 3}] = after_failure.bodies
    assert source_count() == before_sources

    assert {:error, :acquisition_outcome_unknown} =
             SetupCaptureBounds.read(run, lease, directory, item)

    assert accounting(run.id) == after_failure
    assert Repo.get!(CaptureRun, run.id).incomplete
    assert no_model_admission?()
  end

  test "an unresolved prior-lease read cannot be reread or refunded by a new lease", c do
    {_session, f, receipt} = acquire!(c.root)
    directory = f.connection["directory"]
    body = "Synthetic emergency release evidence.\n"
    File.write!(Path.join(directory, "pending.md"), body)
    {run, lease} = install_worker_lease!(receipt)
    item = entry("pending.md")
    assert {:ok, :bounded} = admit(run, lease, page(run, [item]))
    assert {:ok, %{"body" => ^body}} = SetupCaptureBounds.read(run, lease, directory, item)
    before = accounting(run.id)
    assert before.counter.files_reserved == 1
    assert before.counter.bytes_reserved == byte_size(body)
    assert before.counter.bytes_committed == 0
    assert [%{state: "reserved", lease_token: ^lease}] = before.bodies
    deadline = Repo.get_by!(SetupCaptureBinding, capture_id: run.id).deadline
    before_sources = source_count()

    # Simulate process death after the bounded read, before Writer's atomic commit.
    # A replacement worker owns a new lease/epoch, but the old allowance survives.
    new_lease = Ecto.UUID.generate()

    Repo.update!(
      Ecto.Changeset.change(Repo.get!(CaptureRun, run.id),
        lease_token: new_lease,
        scan_epoch: run.scan_epoch + 1,
        lease_until: DateTime.add(Store.now(), 120, :second)
      )
    )

    recovered = Repo.get!(CaptureRun, run.id)
    assert {:error, :cancelled} = Capture.check_lease(run.id, lease)
    assert :ok = Capture.check_lease(run.id, new_lease)

    assert {:error, :acquisition_outcome_unknown} =
             SetupCaptureBounds.read(recovered, new_lease, directory, item)

    assert {:error, :acquisition_outcome_unknown} =
             SetupCaptureBounds.read(recovered, new_lease, directory, item)

    assert accounting(run.id) == before
    assert Repo.get_by!(SetupCaptureBinding, capture_id: run.id).deadline == deadline
    assert source_count() == before_sources
    assert no_model_admission?()
  end

  test "real completed setup capture is indexed and current before exact FTS preparation", c do
    {session, f, receipt} = acquire!(c.root)
    if Process.whereis(Scanner) == nil, do: start_supervised!({Scanner, []})

    Enum.each(f.sources, fn source ->
      File.write!(
        Path.join(f.connection["directory"], source["external_id"]),
        source["latest_revision"]["body"]
      )
    end)

    assert {:ok, complete} = Capture.run(receipt["operation_ref"]["id"])
    assert complete["capture"]["complete"]
    assert complete["scope_current"] == "current"
    assert complete["fts"]["state"] == "ready"
    assert complete["fts"]["expected"] == length(f.sources)
    assert complete["fts"]["indexed"] == length(f.sources)
    view = current!(session)
    assert {:ok, status} = Capture.setup_status(view["run"]["capture_ref"], caller())
    assert status["scan_complete"]
    assert status["scan_verified"]
    assert status["index_ready"]
    refute status["incomplete"]
    counter = accounting(receipt["operation_ref"]["id"]).counter
    assert counter.files_reserved == length(f.sources)

    assert counter.bytes_reserved ==
             Enum.reduce(f.sources, 0, &(byte_size(&1["latest_revision"]["body"]) + &2))

    assert counter.bytes_committed == counter.bytes_reserved
    assert {:ok, retrieval_receipt} = SetupRuns.command(envelope(view, "retrieve", %{}), caller())
    prepared = current!(session)["run"]
    assert prepared["phase"] == "needs_input"
    assert prepared["prepared"]["prepared_ref"] != nil
    assert prepared["prepared"]["source_count"] > 0
    assert prepared["prepared"]["run_ref"] == retrieval_receipt["run_ref"]
    assert prepared["prepared"]["descriptor"]["provider"] == "ollama"
    assert prepared["authorization_ref"] == nil
    assert prepared["usage"]["budget_id"] == nil
    assert no_model_admission?()
  end

  defp acquire!(root) do
    f = CompanyAnalysisFixture.create!(root)
    {:ok, corpus} = Corpora.create(%{"name" => "Synthetic setup capture bounds"}, caller())

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

    assert {:ok, _} =
             SetupRuns.command(
               envelope(current!(session), "prepare", %{
                 "profile_version" => "setup-local-synthesis.v1",
                 "connection_id" => f.connection["id"]
               }),
               caller()
             )

    assert {:ok, receipt} =
             SetupRuns.command(envelope(current!(session), "acquire", %{}), caller())

    {session, f, receipt}
  end

  defp current!(session) do
    assert {:ok, view} = SetupRuns.get(session["id"], caller())
    view
  end

  defp envelope(view, action, payload) do
    run = view["run"]

    %{
      "version" => 1,
      "id" => view["id"],
      "expected_session_version" => view["session_version"],
      "expected_run_version" => if(run, do: run["run_version"]),
      "run_ref" => if(run, do: run["run_ref"]),
      "command_id" => Ecto.UUID.generate(),
      "action" => action,
      "payload" => payload
    }
  end

  defp caller,
    do: [
      authorize: fn -> true end,
      session_fingerprint: Contracts.sha256("setup capture bounds public fixture"),
      view_generation: String.duplicate("c", 32),
      reset_token: 0
    ]

  # These two helpers install only the persisted worker/checkpoint states that
  # Capture's private claim/checkpoint functions normally write. No provider,
  # scanner or body reader is replaced. The final test uses real Capture.run/1.
  defp install_worker_lease!(receipt) do
    lease = Ecto.UUID.generate()
    run = Repo.get!(CaptureRun, receipt["operation_ref"]["id"])

    saved =
      Repo.update!(
        Ecto.Changeset.change(run,
          state: "running",
          lease_token: lease,
          lease_until: DateTime.add(Store.now(), 120, :second),
          lock_version: run.lock_version + 1
        )
      )

    assert :ok = Capture.check_lease(saved.id, lease)
    {saved, lease}
  end

  defp checkpoint_item!(run, path) do
    Repo.query!(
      "INSERT INTO capture_items(run_id,relative_path,kind,state,scan_epoch,attempts,updated_at) VALUES(?,?,'file','pending',?,0,?)",
      [run.id, path, run.scan_epoch, Corpora.now()]
    )
  end

  defp admit(run, lease, batch) do
    Purge.synchronize(fn ->
      Store.transaction(fn ->
        with :ok <- Capture.check_lease(run.id, lease),
             do: SetupCaptureBounds.admit_page(run, lease, "", batch)
      end)
    end)
  end

  defp entry(path), do: %{"relative_path" => path, "kind" => "file", "error_code" => nil}

  defp page(run, entries),
    do: %{
      "v" => 1,
      "run_id" => run.id,
      "seq" => 0,
      "entries" => entries,
      "done" => true,
      "stable" => true,
      "directory_fingerprint" => Contracts.sha256("public synthetic page"),
      "error_code" => nil
    }

  defp accounting(id) do
    %{
      counter: Repo.get_by!(SetupCaptureCounter, capture_id: id),
      entries:
        Repo.all(
          from c in SetupCaptureCharge,
            where: c.capture_id == ^id and c.kind == "entry",
            order_by: c.relative_path
        ),
      bodies:
        Repo.all(
          from c in SetupCaptureCharge,
            where: c.capture_id == ^id and c.kind == "body",
            order_by: c.relative_path
        ),
      pages:
        Repo.all(from p in SetupCapturePage, where: p.capture_id == ^id, order_by: p.sequence)
    }
  end

  defp source_count,
    do:
      Repo.query!("SELECT count(*) FROM evidence_sources WHERE workspace_id=?", [
        Store.workspace()
      ]).rows

  defp capture_count,
    do:
      Repo.query!("SELECT count(*) FROM capture_runs WHERE workspace_id=?", [Store.workspace()]).rows
      |> List.first()
      |> List.first()

  defp no_model_admission? do
    Enum.all?(
      ~w(model_requests model_budgets model_run_authorizations stage_consent_revisions),
      fn table ->
        Repo.query!("SELECT count(*) FROM " <> table <> " WHERE workspace_id=?", [
          Store.workspace()
        ]).rows == [[0]]
      end
    )
  end
end
