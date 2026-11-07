defmodule HarnessForgeWeb.PackageExportTest do
  use HarnessForgeWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias HarnessForge.{Audit, Company, Decisions, Evidence, Harnesses, Privacy, Repo, Workspaces}
  alias HarnessForge.Contracts.Error
  alias HarnessForgeWeb.PackageExport
  alias HarnessForgeWeb.Plugs.OperatorSession

  @unconfirmed "Export completion could not be confirmed. Inspect the destination before retrying with a new directory."

  setup %{conn: conn} = tags do
    previous_root = Workspaces.root()
    previous_id = Workspaces.current_id()
    id = Ecto.UUID.generate()
    root = Path.join(File.cwd!(), "tmp/export-web-#{id}")

    for directory <- ~w(artifacts runs tmp evidence),
        do: File.mkdir_p!(Path.join(root, directory))

    Application.put_env(:harness_forge, :workspace_root, root)
    Application.put_env(:harness_forge, :workspace_id, id)

    if tags[:committed] do
      :ok = Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
      :ok = Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    end

    on_exit(fn ->
      if tags[:committed] do
        :ok = Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)

        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          Application.put_env(:harness_forge, :workspace_root, root)
          Application.put_env(:harness_forge, :workspace_id, id)
          {:ok, _} = Privacy.purge_workspace(id)
        end)
      end

      Application.put_env(:harness_forge, :workspace_root, previous_root)
      Application.put_env(:harness_forge, :workspace_id, previous_id)
      for path <- [root, root <> "-backup", root <> "-restored"], do: File.rm_rf!(path)
    end)

    conn = %{conn | host: "localhost", port: 4002}
    {:ok, root: root, conn: authenticate(conn)}
  end

  test "occupied destination recovery preserves bytes, exact identity and a labeled prior build refusal",
       ctx do
    %{artifact: artifact} = fixture()
    view = packages(ctx.conn)

    view
    |> form("#build-form",
      package: %{
        name: "Bad Name",
        version: "0.1.0",
        runtime: "opencode",
        runtime_version: "unqualified"
      }
    )
    |> render_submit()

    assert has_element?(view, "#error", "Package build:")
    digest = artifact["digest"]
    build_flash = state(view).flash
    occupied = Path.join(ctx.root, "occupied")
    File.mkdir!(occupied)
    sentinel = Path.join(occupied, "sentinel")
    File.write!(sentinel, "EXISTING_PRIVATE_BYTES")
    before = bytes_hash(sentinel)
    previous = state(view).export_generation

    assert export_calls(view, fn -> submit(view, artifact, occupied) end) == 1
    assert_error(view, artifact, "Choose a new directory", true)
    refute state(view).export_generation == previous
    assert target_value(view, artifact) == occupied
    assert bytes_hash(sentinel) == before
    assert state(view).flash == build_flash
    generation = state(view).export_generation

    assert_push_event(view, "package-export-focus", %{
      kind: "target",
      digest: ^digest,
      generation: ^generation
    })

    assert has_element?(
             view,
             "#{selector(view, "target", artifact)}[aria-describedby='#{id(view, "help", artifact)} #{id(view, "error", artifact)}']"
           )

    target = Path.join(ctx.root, "fresh-<escaped>")
    submit(view, artifact, target)
    assert_success(view, artifact, target)
    assert target_value(view, artifact) == ""
    refute has_element?(view, "[id^=package-export-error-]")
    refute has_element?(view, "#export-result")
    assert bytes_hash(sentinel) == before
    assert state(view).flash == build_flash
    assert_payload(artifact, target)
    refute render(view) =~ "fresh-<escaped>"
    generation = state(view).export_generation

    assert_push_event(view, "package-export-focus", %{
      kind: "result",
      digest: ^digest,
      generation: ^generation
    })

    assert {:ok, []} = HarnessForge.Evaluations.list_runs()
    assert {:ok, []} = HarnessForge.Releases.list()
  end

  test "successful export appears immediately in the visible Audit tab", ctx do
    %{artifact: artifact} = fixture()
    view = packages(ctx.conn)
    target = Path.join(ctx.root, "audit-export")
    submit(view, artifact, target)
    assert_success(view, artifact, target)
    assert_payload(artifact, target)
    {:ok, events} = Audit.list_events()
    event = Enum.find(events, &(&1["action"] == "harness.exported"))
    assert event["details"]["artifact_digest"] == artifact["digest"]
    view |> element("#nav-audit") |> render_click()
    assert has_element?(view, "#audit-#{event["id"]}", "harness.exported")
    assert has_element?(view, "#audit-#{event["id"]}", artifact["digest"])
  end

  test "export preserves an unrelated actionable flash unchanged", ctx do
    %{artifact: artifact} = fixture()
    view = packages(ctx.conn)
    render_click(view, "unknown-action", %{})
    previous = state(view).flash
    assert has_element?(view, "#error", "This action is unavailable")
    target = Path.join(ctx.root, "notice-export")
    submit(view, artifact, target)
    assert_success(view, artifact, target)
    assert state(view).flash == previous
    assert_payload(artifact, target)
  end

  test "actual unsafe and occupied target refusals keep outside files unchanged", ctx do
    %{artifact: artifact} = fixture()
    view = packages(ctx.conn)
    outside = Path.join(ctx.root, "outside")
    File.mkdir!(outside)
    sentinel = Path.join(outside, "sentinel")
    File.write!(sentinel, "OUTSIDE_SENTINEL")
    symlink = Path.join(ctx.root, "linked-parent")
    File.ln_s!(outside, symlink)
    destination_link = Path.join(ctx.root, "linked-destination")
    File.ln_s!(outside, destination_link)
    existing_file = Path.join(ctx.root, "existing-file")
    File.write!(existing_file, "EXISTING_FILE")
    snapshot = {bytes_hash(sentinel), bytes_hash(existing_file)}

    for target <- [
          "relative/export",
          ctx.root <> "/../escaped-export",
          Path.join(ctx.root, "missing/export"),
          Path.join(symlink, "export")
        ] do
      submit(view, artifact, target)
      assert_error(view, artifact, "existing real parent", true)
      assert target_value(view, artifact) == target
      refute File.exists?(target)
    end

    for target <- [destination_link, existing_file] do
      submit(view, artifact, target)
      assert_error(view, artifact, "already exists", true)
      assert target_value(view, artifact) == target
    end

    assert {bytes_hash(sentinel), bytes_hash(existing_file)} == snapshot
    refute File.exists?(Path.join(outside, "export"))
    assert {:ok, audit} = Audit.list_events()
    refute Enum.any?(audit, &(&1["action"] == "harness.exported"))
  end

  test "same named A and B own exactly the latest outcome through reorder and readiness selection",
       ctx do
    %{artifact: first} = fixture()
    {:ok, second} = Harnesses.build(%{"name" => "same-name", "version" => "0.2.0"})
    refute first["digest"] == second["digest"]
    view = packages(ctx.conn)
    first_path = Path.join(ctx.root, "first-export")
    submit(view, first, first_path)
    assert_success(view, first, first_path)
    generation = state(view).export_generation
    outcome = state(view).export_outcome

    # Reorder actual loaded records only; export admission remains the real domain call.
    :sys.replace_state(view.pid, fn data ->
      %{
        data
        | socket:
            Phoenix.Component.assign(
              data.socket,
              :artifacts,
              Enum.reverse(data.socket.assigns.artifacts)
            )
      }
    end)

    view
    |> form("#package-readiness-form", readiness: %{digest: second["digest"]})
    |> render_change()

    assert state(view).export_generation == generation
    assert state(view).export_outcome == outcome
    assert_success(view, first, first_path)
    send(view.pid, {:company_changed, "ordinary record reload"})
    assert_success(view, first, first_path)
    assert state(view).export_generation == generation

    occupied = Path.join(ctx.root, "occupied")
    File.mkdir!(occupied)
    submit(view, second, occupied)
    assert_error(view, second, "already exists", true)
    refute has_element?(view, "[id^=package-export-result-]")
    assert target_value(view, first) == ""
    assert target_value(view, second) == occupied
    second_path = Path.join(ctx.root, "second-export")
    submit(view, second, second_path)
    assert_success(view, second, second_path)
    assert target_value(view, first) == ""
    assert target_value(view, second) == ""
    submit(view, first, occupied)
    assert_error(view, first, "already exists", true)
    assert target_value(view, second) == ""
    refute has_element?(view, "[id^=package-export-result-]")
    assert_payload(first, first_path)
    assert_payload(second, second_path)
    assert state(view).readiness_digest == second["digest"]
  end

  test "malformed unavailable foreign and stale envelopes never invoke export or echo targets",
       ctx do
    %{artifact: artifact} = fixture()
    original_id = Workspaces.current_id()
    Application.put_env(:harness_forge, :workspace_id, Ecto.UUID.generate())
    foreign_root = Path.join(ctx.root, "foreign-workspace")

    for directory <- ~w(artifacts runs tmp evidence),
        do: File.mkdir_p!(Path.join(foreign_root, directory))

    Application.put_env(:harness_forge, :workspace_root, foreign_root)
    %{artifact: foreign} = fixture(%{"name" => "foreign-package-private-canary"})
    Application.put_env(:harness_forge, :workspace_id, original_id)
    Application.put_env(:harness_forge, :workspace_root, ctx.root)
    view = packages(ctx.conn)
    occupied = Path.join(ctx.root, "calibration")
    File.mkdir!(occupied)
    assert export_calls(view, fn -> submit(view, artifact, occupied) end) == 1
    captured = envelope(view, artifact, Path.join(ctx.root, "PRIVATE_TARGET_CANARY"))
    send(view.pid, :company_cache_reset)
    assert_cleared(view, captured)
    assert :ok = Harnesses.eligible(artifact)
    {:ok, audit_before} = Audit.list_events()
    valid = envelope(view, artifact, captured["export"]["target"])
    attrs = valid["export"]

    malformed = [
      %{},
      %{"export" => nil},
      %{"export" => []},
      %{"export" => "PRIVATE_TARGET_CANARY"},
      %{"export" => Map.delete(attrs, "generation")},
      %{"export" => Map.put(attrs, "generation", %{})},
      %{"export" => Map.put(attrs, "digest", String.upcase(artifact["digest"]))},
      %{"export" => Map.put(attrs, "digest", String.duplicate("f", 64))},
      %{"export" => Map.put(attrs, "digest", foreign["digest"])},
      %{"export" => Map.put(attrs, "digest", [artifact["digest"]])},
      %{"export" => Map.put(attrs, "target", %{"private" => "PRIVATE_TARGET_CANARY"})},
      %{"export" => Map.put(attrs, "target", String.duplicate("x", 4097))},
      %{"export" => Map.put(attrs, "target", "")},
      %{"export" => Map.put(attrs, "target", "bad" <> <<0>>)},
      %{"export" => Map.put(attrs, "extra", "PRIVATE_TARGET_CANARY")},
      captured
    ]

    assert export_calls(view, fn ->
             for input <- malformed do
               render_hook(view, "export", input)

               assert has_element?(
                        view,
                        "#package-export-message",
                        "Use the refreshed Packages controls"
                      )

               refute render(view) =~ "PRIVATE_TARGET_CANARY"
               refute render(view) =~ "foreign-package-private-canary"
               assert state(view).export_outcome == nil
             end
           end) == 0

    assert {:ok, ^audit_before} = Audit.list_events()
    refute File.exists?(captured["export"]["target"])
    fresh = Path.join(ctx.root, "valid-after-refusals")
    assert export_calls(view, fn -> submit(view, artifact, fresh) end) == 1
    assert_success(view, artifact, fresh)
    assert_payload(artifact, fresh)
  end

  test "sibling source purge clears submitted targets while unrelated package stays eligible",
       ctx do
    %{artifact: artifact} = fixture()
    unrelated = source("unrelated.md")
    first = packages(ctx.conn)
    sibling = packages(ctx.conn)
    occupied = Path.join(ctx.root, "PRIVATE_DRAFT_CANARY")
    File.mkdir!(occupied)
    for view <- [first, sibling], do: submit(view, artifact, occupied)

    captured =
      Map.new(
        [first, sibling],
        &{&1.pid, envelope(&1, artifact, Path.join(ctx.root, "PRIVATE_QUEUED_CANARY"))}
      )

    first |> element("#nav-privacy") |> render_click()

    first
    |> form("#purge-source-form", privacy: %{id: unrelated["id"], confirmation: unrelated["id"]})
    |> render_submit()

    assert :ok = Harnesses.eligible(artifact)

    for view <- [first, sibling] do
      assert_cleared(view, captured[view.pid])
      assert export_calls(view, fn -> render_hook(view, "export", captured[view.pid]) end) == 0
      assert_cleared(view, captured[view.pid])
      refute File.exists?(captured[view.pid]["export"]["target"])
    end

    first |> element("#nav-package") |> render_click()
    submit(first, artifact, Path.join(ctx.root, "fresh-after-purge"))
    assert_success(first, artifact, Path.join(ctx.root, "fresh-after-purge"))
  end

  test "all Packages exit paths clear and rotate the form, while hidden Packages rejects submission",
       ctx do
    %{artifact: artifact} = fixture()
    view = packages(ctx.conn)
    occupied = Path.join(ctx.root, "PRIVATE_DRAFT_CANARY")
    File.mkdir!(occupied)

    exits = [
      fn -> render_click(view, "tab", %{"tab" => "evidence"}) end,
      fn -> render_click(view, "account_setup", %{"service" => "github"}) end,
      fn ->
        send(view.pid, {:company_navigate, "goals"})
        render(view)
      end,
      fn ->
        view
        |> form("#package-readiness-form", readiness: %{digest: artifact["digest"]})
        |> render_change()

        view |> form("#package-readiness-form") |> render_submit()
        assert has_element?(view, "#readiness-next-action")
        view |> element("#readiness-next-action") |> render_click()
      end
    ]

    for leave <- exits do
      view |> element("#nav-package") |> render_click()
      submit(view, artifact, occupied)
      captured = envelope(view, artifact, Path.join(ctx.root, "PRIVATE_HIDDEN_CANARY"))
      leave.()
      refute state(view).tab == "package"
      assert_cleared(view, captured)
      assert export_calls(view, fn -> render_hook(view, "export", captured) end) == 0
      view |> element("#nav-package") |> render_click()
      assert_cleared(view, captured)
      assert target_value(view, artifact) == ""
      refute File.exists?(captured["export"]["target"])
    end
  end

  test "remount and revoked event authentication erase export state before redirect", ctx do
    %{artifact: artifact} = fixture()
    first = packages(ctx.conn)
    occupied = Path.join(ctx.root, "PRIVATE_DRAFT_CANARY")
    File.mkdir!(occupied)
    submit(first, artifact, occupied)
    captured = envelope(first, artifact, Path.join(ctx.root, "PRIVATE_QUEUED_CANARY"))
    fresh = packages(ctx.conn)
    assert_cleared(fresh, captured)
    assert export_calls(fresh, fn -> render_hook(fresh, "export", captured) end) == 0
    submit(first, artifact, occupied)
    trace = {HarnessForgeWeb.PortalLive, :revoke_operator, 1}
    assert :erlang.trace_pattern(trace, [{:_, [], [{:return_trace}]}], [:local]) == 1
    :erlang.trace(first.pid, true, [:call, {:tracer, self()}])
    old_state = :sys.get_state(Workspaces)
    :sys.replace_state(Workspaces, &%{&1 | epoch: "revoked-export-session"})

    try do
      assert {:error, {:redirect, %{to: "/login"}}} = render_hook(first, "export", captured)
      assert_receive {:trace, _, :return_from, ^trace, socket}
      assert socket.assigns.export_outcome == nil
      assert socket.assigns.export_message == nil
      refute socket.assigns.export_generation == captured["export"]["generation"]
      refute File.exists?(captured["export"]["target"])
    after
      :erlang.trace_pattern(trace, false, [:local])
      :sys.replace_state(Workspaces, fn _ -> old_state end)
    end
  end

  test "lock broadcasts erase cached export state in every tab", ctx do
    %{artifact: artifact} = fixture()
    views = [packages(ctx.conn), packages(ctx.conn)]
    occupied = Path.join(ctx.root, "PRIVATE_LOCK_CANARY")
    File.mkdir!(occupied)
    for view <- views, do: submit(view, artifact, occupied)
    response = ctx.conn |> put_req_header("origin", "http://localhost:4002") |> delete("/session")
    assert redirected_to(response) == "/login"
    for view <- views, do: assert_redirect(view, "/login")
    assert {:error, {:redirect, %{to: "/login"}}} = live(ctx.conn, "/")
    fresh = ctx.conn |> authenticate() |> packages()
    assert state(fresh).export_outcome == nil
    assert target_value(fresh, artifact) == ""
    refute render(fresh) =~ "PRIVATE_LOCK_CANARY"
  end

  test "artifact removal and failed artifact loading invalidate the active export", ctx do
    %{artifact: first} = fixture()
    {:ok, second} = Harnesses.build(%{"name" => "same-name", "version" => "0.2.0"})
    view = packages(ctx.conn)
    occupied = Path.join(ctx.root, "PRIVATE_REMOVAL_CANARY")
    File.mkdir!(occupied)
    submit(view, first, occupied)
    captured = envelope(view, first, Path.join(ctx.root, "PRIVATE_QUEUED_CANARY"))
    File.rm_rf!(Path.join([ctx.root, "artifacts", first["digest"]]))
    send(view.pid, {:company_changed, "removed"})
    assert_cleared(view, captured)
    refute has_element?(view, "#artifact-#{first["digest"]}")
    assert export_calls(view, fn -> render_hook(view, "export", captured) end) == 0
    submit(view, second, occupied)
    captured = envelope(view, second, Path.join(ctx.root, "PRIVATE_QUEUED_CANARY"))

    File.write!(
      Path.join([ctx.root, "artifacts", second["digest"], "artifact.json"]),
      "invalid metadata"
    )

    send(view.pid, {:company_changed, "unavailable"})
    assert_cleared(view, captured)
    assert state(view).artifacts == []
    assert "artifacts" in state(view).data_errors
    assert export_calls(view, fn -> render_hook(view, "export", captured) end) == 0
  end

  test "corrupted immutable metadata refuses through the current integrity gate", ctx do
    %{artifact: artifact} = fixture()
    view = packages(ctx.conn)

    File.write!(
      Path.join([ctx.root, "artifacts", artifact["digest"], "artifact.json"]),
      "invalid metadata"
    )

    target = Path.join(ctx.root, "integrity-refusal")
    assert export_calls(view, fn -> submit(view, artifact, target) end) == 1
    assert_error(view, artifact, "Package integrity could not be verified", false)
    refute File.exists?(target)
    refute render(view) =~ "provider page could not be imported"
  end

  test "withdrawn and superseded claims refuse through real current export admission", ctx do
    %{artifact: artifact, claim: claim} = fixture()
    view = packages(ctx.conn)

    {:ok, successor} =
      Evidence.create_claim(%{
        "text" => "A successor needs its own review",
        "citations" => claim["citations"],
        "supersedes_id" => claim["id"]
      })

    target = Path.join(ctx.root, "superseded-refusal")
    assert export_calls(view, fn -> submit(view, artifact, target) end) == 1
    assert_error(view, artifact, "Review current claims in Evidence", false)
    refute File.exists?(target)
    {:ok, _} = Decisions.decide(successor["id"], decision(successor, "reject"))
    target = Path.join(ctx.root, "withdrawn-refusal")
    submit(view, artifact, target)
    assert_error(view, artifact, "withdrawn or changed evidence", false)
    refute File.exists?(target)
  end

  test "a stale approved Company plan gives Company review rather than directory advice", ctx do
    %{claim: claim, source: source} = fixture()
    {:ok, _} = Company.save_profile(%{"name" => "Synthetic company"})

    {:ok, repository} =
      Company.create_repository(%{
        "identity" => "synthetic/service",
        "name" => "Service",
        "purpose" => "Fixture",
        "owner" => "Platform"
      })

    {:ok, project} =
      Company.create_project(%{
        "name" => "Project",
        "repository_ids" => [repository["id"]],
        "source_ids" => [source["id"]],
        "goal_ids" => []
      })

    {:ok, plan} =
      Company.create_plan(%{
        "name" => "planned-package",
        "package_version" => "0.1.0",
        "project_id" => project["id"],
        "repository_ids" => [repository["id"]],
        "claim_refs" => [Map.take(claim, ~w(id revision_hash))],
        "goal_ids" => [],
        "template_ids" => ["reviewed-change-v1"],
        "runtime" => "opencode",
        "runtime_version" => "unqualified",
        "execution" => %{"max_turns" => 12, "timeout_seconds" => 600}
      })

    {:ok, _} = Company.decide_plan(plan["id"], decision(plan))
    {:ok, artifact} = Harnesses.build_plan(plan["id"], plan["revision_hash"])
    view = packages(ctx.conn)

    {:ok, _} =
      Company.update_repository(
        repository["id"],
        repository["payload"]
        |> Map.put("purpose", "Changed declared purpose")
        |> Map.put("expected_content_hash", repository["content_hash"])
      )

    target = Path.join(ctx.root, "stale-plan-refusal")
    submit(view, artifact, target)
    assert_error(view, artifact, "Review and approve the current exact plan", false)
    refute File.exists?(target)
  end

  test "a pending privacy operation refuses without claiming a path-only remedy", ctx do
    %{artifact: artifact, source: source} = fixture()
    view = packages(ctx.conn)
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    Repo.query!(
      "INSERT INTO privacy_operations (id,workspace_id,kind,target_id,state,plan,inserted_at,updated_at) VALUES (?,?,?,?,?,?,?,?)",
      [
        Ecto.UUID.generate(),
        Workspaces.current_id(),
        "source",
        source["id"],
        "prepared",
        "{}",
        now,
        now
      ]
    )

    target = Path.join(ctx.root, "privacy-refusal")
    submit(view, artifact, target)
    assert_error(view, artifact, "Resolve the pending privacy operation", false)
    refute File.exists?(target)
  end

  @tag :committed
  test "a real restored quarantined package is visible but remains ineligible for export", ctx do
    %{artifact: artifact} = fixture()
    {:ok, _} = Privacy.backup(ctx.root <> "-backup")

    {:ok, %{"workspace_id" => restored_id, "state" => "quarantined"}} =
      Privacy.restore(ctx.root <> "-backup", ctx.root <> "-restored")

    {:ok, restored_repo} =
      Repo.start_link(
        name: nil,
        database: Path.join(ctx.root <> "-restored", "data.sqlite3"),
        pool: DBConnection.ConnectionPool,
        pool_size: 1
      )

    original_repo = Repo.put_dynamic_repo(restored_repo)
    original_id = Workspaces.current_id()
    Application.put_env(:harness_forge, :workspace_id, restored_id)
    Application.put_env(:harness_forge, :workspace_root, ctx.root <> "-restored")

    try do
      view = ctx.conn |> authenticate() |> packages()
      # The connected LiveView must use the actual restored database, not synthetic approvals.
      :sys.replace_state(view.pid, fn data ->
        Repo.put_dynamic_repo(restored_repo)
        data
      end)

      send(view.pid, {:company_changed, "restored database"})
      assert has_element?(view, "#artifact-#{artifact["digest"]}")
      assert {:ok, []} = Evidence.approved_claims()
      target = Path.join(ctx.root <> "-restored", "quarantine-refusal")
      submit(view, artifact, target)
      assert_error(view, artifact, "Review current claims in Evidence", false)
      refute File.exists?(target)
      GenServer.stop(view.pid)
    after
      Repo.put_dynamic_repo(original_repo)
      Application.put_env(:harness_forge, :workspace_id, original_id)
      Application.put_env(:harness_forge, :workspace_root, ctx.root)
      GenServer.stop(restored_repo)
    end
  end

  test "pure presentation fixtures sanitize hostile failures and unconfirmed returned identities" do
    digest = String.duplicate("a", 64)
    target = "/tmp/submitted-export"
    sentinel = "PRIVATE_HOSTILE_PAYLOAD"

    assert %{status: :success, path: ^target} =
             PackageExport.present({:ok, %{"digest" => digest, "path" => target}}, digest, target)

    # Presentation fixtures only: these do not inject or prove an actual filesystem/audit failure.
    fixtures = [
      {:error, %Error{code: "artifact_io_error", message: sentinel, details: [sentinel]}},
      {:error, %Error{code: sentinel, message: sentinel}},
      {:error, :audit_failed},
      {:error, %{"message" => sentinel}},
      {:error, sentinel},
      {:ok, nil},
      :unknown,
      {:ok, %{"digest" => String.duplicate("b", 64), "path" => target}},
      {:ok, %{"digest" => digest, "path" => target <> "-other"}},
      {:ok, %{"digest" => digest, "path" => "/tmp/./submitted-export"}},
      {:ok, %{"digest" => digest, "path" => [sentinel]}},
      {:ok, %{"digest" => String.upcase(digest), "path" => target}},
      {:ok, %{"digest" => digest, "path" => "relative"}},
      {:ok, %{"digest" => digest <> "\n", "path" => target}}
    ]

    for result <- fixtures do
      assert %{status: :error, message: @unconfirmed, invalid_target: false} =
               PackageExport.present(result, digest, target)

      refute inspect(PackageExport.present(result, digest, target)) =~ sentinel
    end

    for code <- ~w(export_conflict unsafe_artifact_path invalid_artifact) do
      outcome =
        PackageExport.present(
          {:error, %Error{code: code, message: sentinel, details: [sentinel]}},
          digest,
          target
        )

      assert outcome.status == :error
      refute inspect(outcome) =~ sentinel
    end

    refute PackageExport.valid_target?(<<255>>)
    refute PackageExport.valid_digest?(<<255>> <> String.duplicate("a", 63))
  end

  defp authenticate(conn),
    do: init_test_session(conn, %{"operator_auth" => OperatorSession.new_auth()})

  defp packages(conn) do
    {:ok, view, _} = live(conn, "/")
    view |> element("#nav-package") |> render_click()
    view
  end

  defp state(view) do
    render(view)
    :sys.get_state(view.pid).socket.assigns
  end

  defp id(view, kind, artifact),
    do: "package-export-#{kind}-#{state(view).export_generation}-#{artifact["digest"]}"

  defp selector(view, kind, artifact), do: "#" <> id(view, kind, artifact)

  defp envelope(view, artifact, target),
    do: %{
      "export" => %{
        "generation" => state(view).export_generation,
        "digest" => artifact["digest"],
        "target" => target
      }
    }

  defp submit(view, artifact, target),
    do:
      view |> form(selector(view, "form", artifact), export: %{target: target}) |> render_submit()

  defp target_value(view, artifact),
    do:
      view
      |> element(selector(view, "target", artifact))
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("input")
      |> LazyHTML.attribute("value")
      |> hd()

  defp assert_error(view, artifact, message, invalid) do
    assert has_element?(view, selector(view, "error", artifact), message)

    assert has_element?(
             view,
             "#artifact-#{artifact["digest"]}[data-export-active=true][data-export-focus-kind=target]"
           )

    assert has_element?(
             view,
             selector(view, "target", artifact) <>
               if(invalid, do: "[aria-invalid=true]", else: ":not([aria-invalid])")
           )

    refute has_element?(view, "[id^=package-export-result-]")
  end

  defp assert_success(view, artifact, target) do
    assert has_element?(
             view,
             selector(view, "result", artifact) <>
               "[role=status][tabindex='-1'][aria-live=polite][aria-atomic=true]",
             "Export complete"
           )

    assert has_element?(view, selector(view, "result", artifact), target)
    assert has_element?(view, selector(view, "result", artifact), artifact["digest"])

    assert has_element?(
             view,
             "#artifact-#{artifact["digest"]}[data-export-active=true][data-export-focus-kind=result]"
           )

    assert Enum.count(
             LazyHTML.query(LazyHTML.from_fragment(render(view)), "[id^=package-export-result-]")
           ) == 1
  end

  defp assert_cleared(view, captured) do
    assigns = state(view)
    assert assigns.export_outcome == nil
    refute assigns.export_generation == captured["export"]["generation"]
    refute render(view) =~ "PRIVATE_"
    refute has_element?(view, "[id^=package-export-result-]")

    refute has_element?(
             view,
             "#package-export-target-#{captured["export"]["generation"]}-#{captured["export"]["digest"]}"
           )

    if assigns.tab == "package" do
      for artifact <- assigns.artifacts do
        assert target_value(view, artifact) == ""
        assert has_element?(view, selector(view, "form", artifact) <> "[phx-auto-recover=ignore]")
      end
    end
  end

  defp assert_payload(artifact, target),
    do:
      Enum.each(artifact["files"], fn {path, bytes} ->
        assert File.read!(Path.join(target, path)) == bytes
      end)

  defp bytes_hash(path), do: :crypto.hash(:sha256, File.read!(path))

  defp decision(record, choice \\ "approve"),
    do: %{
      "actor" => Workspaces.operator(),
      "decision" => choice,
      "expected_revision_hash" => record["revision_hash"]
    }

  defp source(external_id \\ "guide.md") do
    {:ok, connection} =
      Evidence.connect(%{
        "name" => "Synthetic export fixture",
        "provider" => "local",
        "directory" => Path.join(Workspaces.root(), "evidence")
      })

    {:ok, source} =
      Evidence.import_markdown(connection["id"], %{
        "external_id" => external_id,
        "title" => "Synthetic guide",
        "body" => "Review each change before release."
      })

    source
  end

  defp fixture(attrs \\ %{}) do
    source = source()
    revision = source["latest_revision"]
    {:ok, citation} = Evidence.citation(revision["id"], 0, byte_size(revision["body"]))

    {:ok, claim} =
      Evidence.create_claim(%{
        "text" => "Review changes deliberately.",
        "citations" => [citation]
      })

    {:ok, claim} = Decisions.decide(claim["id"], decision(claim))

    {:ok, artifact} =
      Harnesses.build(Map.merge(%{"name" => "same-name", "version" => "0.1.0"}, attrs))

    %{artifact: artifact, source: source, claim: claim}
  end

  # Calibrated by real admitted occupied/fresh submissions (one call), followed by
  # invalid-envelope episodes (zero calls). No domain result is replaced or mocked.
  defp export_calls(view, fun) do
    mfa = {Harnesses, :export, 2}
    assert :erlang.trace_pattern(mfa, true, [:local]) == 1
    :erlang.trace(view.pid, true, [:call, :arity, {:tracer, self()}])

    try do
      fun.()
      delivery = :erlang.trace_delivered(view.pid)
      assert_receive {:trace_delivered, _, ^delivery}, 1_000
      count_export_calls(view.pid, 0)
    after
      if Process.alive?(view.pid), do: :erlang.trace(view.pid, false, [:all])
      :erlang.trace_pattern(mfa, false, [:local])
    end
  end

  defp count_export_calls(pid, count) do
    receive do
      {:trace, ^pid, :call, {Harnesses, :export, 2}} -> count_export_calls(pid, count + 1)
    after
      0 -> count
    end
  end
end
