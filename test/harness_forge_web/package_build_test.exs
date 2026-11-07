defmodule HarnessForgeWeb.PackageBuildTest do
  use HarnessForgeWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias HarnessForge.{
    Audit,
    Compiler,
    Contracts,
    Decisions,
    Evidence,
    Evaluations,
    Harnesses,
    Privacy,
    Repo,
    Workspaces
  }

  alias HarnessForge.Contracts.Error
  alias HarnessForgeWeb.PackageBuild
  alias HarnessForgeWeb.Plugs.OperatorSession

  @help "Use 1–64 characters. Start with a lowercase letter; then use lowercase letters, numbers, underscores or hyphens."
  @generic "Check the package values and approved inputs, then try building again."
  @draft %{
    "name" => "Bad Name",
    "version" => "1.2.3",
    "runtime" => "codex",
    "runtime_version" => "0.156.0"
  }
  @name_details [
    "$.metadata.name: invalid format",
    "$.metadata.name: outside permitted bounds",
    "$.metadata.name: invalid string",
    "$.metadata.name: required"
  ]

  setup %{conn: conn} = tags do
    previous = {Workspaces.root(), Workspaces.current_id()}
    id = Ecto.UUID.generate()
    root = Path.join(File.cwd!(), "tmp/build-web-#{id}")

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

      Application.put_env(:harness_forge, :workspace_root, elem(previous, 0))
      Application.put_env(:harness_forge, :workspace_id, elem(previous, 1))
      for path <- [root, root <> "-backup", root <> "-restored"], do: File.rm_rf!(path)
    end)

    conn = %{conn | host: "localhost", port: 4002}

    {:ok,
     conn: init_test_session(conn, %{"operator_auth" => OperatorSession.new_auth()}), root: root}
  end

  test "real name refusal retains all four values, replaces failures and explicitly retries once",
       ctx do
    approved_source()
    view = packages(ctx.conn)
    before = publication_snapshot(ctx.root)
    {:ok, audit_before} = Audit.list_events()
    previous = generation(view)
    assert build_calls(view, fn -> submit(view, @draft) end) == 1
    assert_name_error(view, @draft)
    current = generation(view)
    refute current == previous
    assert_push_event(view, "package-build-focus", %{kind: "name", generation: ^current})
    assert publication_snapshot(ctx.root) == before
    assert {:ok, ^audit_before} = Audit.list_events()

    send(view.pid, {:company_changed, "harmless reload"})
    send(view.pid, :refresh_evaluations)
    assert_name_error(view, @draft)
    assert generation(view) == current
    assert build_calls(view, fn -> submit(view, @draft) end) == 1
    assert_name_error(view, @draft)
    assert Enum.count(LazyHTML.query(document(view), "#package-name-error")) == 1
    assert publication_snapshot(ctx.root) == before
    assert {:ok, ^audit_before} = Audit.list_events()

    corrected = Map.put(@draft, "name", "good-name")
    assert build_calls(view, fn -> submit(view, corrected) end) == 1
    assert {:ok, [artifact]} = Harnesses.list_artifacts()
    assert :ok = Compiler.verify(artifact)
    assert get_in(artifact, ["spec", "metadata"]) == Map.take(corrected, ~w(name version))

    assert get_in(artifact, ["spec", "spec", "runtime"]) == %{
             "name" => "codex",
             "version" => "0.156.0"
           }

    assert has_element?(view, "#artifact-#{artifact["digest"]} code", artifact["digest"])
    assert has_element?(view, "#notice", "Immutable harness package built")
    refute has_element?(view, "#package-name-error")
    refute has_element?(view, "#package-name[aria-invalid]")
    refute has_element?(view, "#error")
    assert state(view).build_outcome == nil
    assert draft_values(view) == corrected
    assert built_count() == 1
    assert {:ok, []} = Evaluations.list_runs()
    assert {:ok, []} = HarnessForge.Releases.list()
  end

  test "classification binds the unchanged validator vocabulary and exact name boundaries" do
    spec = specification()

    for name <- ["a", String.duplicate("a", 64)] do
      assert {:ok, _} = Contracts.validate_harness(put_in(spec, ["metadata", "name"], name))
    end

    for name <- ["Upper", "1leading", "has space", "", String.duplicate("a", 65), 1] do
      assert {:error, %Error{} = error} =
               Contracts.validate_harness(put_in(spec, ["metadata", "name"], name))

      assert error.details != []
      assert Enum.all?(error.details, &(&1 in @name_details))
      assert PackageBuild.classify(error) == :name
    end

    assert {:error, missing} =
             Contracts.validate_harness(update_in(spec, ["metadata"], &Map.delete(&1, "name")))

    assert "$.metadata.name: required" in missing.details
    assert PackageBuild.classify(missing) == :name

    for bad <- [
          put_in(spec, ["metadata", "version"], "bad-version"),
          spec
          |> put_in(["metadata", "name"], "Bad Name")
          |> put_in(["metadata", "version"], "bad-version")
        ] do
      assert {:error, error} = Contracts.validate_harness(bad)
      assert PackageBuild.classify(error) == :generic
    end
  end

  test "hostile and malformed classifier terms default safely while fixed reasons retain remedies" do
    sentinel = "PRIVATE_HOSTILE_MESSAGE <script>bad</script>"
    name = hd(@name_details)
    error = %Error{code: "invalid_harness", message: sentinel, details: [name]}
    assert PackageBuild.classify(error) == :name
    assert PackageBuild.classify(%{error | details: List.duplicate(name, 100)}) == :name

    for details <- [
          [],
          nil,
          name,
          %{},
          [name, "$.metadata.version: invalid format"],
          [name <> sentinel],
          [sentinel <> name],
          [name | sentinel],
          [name, %{}],
          List.duplicate(name, 101)
        ] do
      assert PackageBuild.classify(%{error | details: details}) == :generic
    end

    for reason <- [
          %{code: "invalid_harness", details: [name]},
          %{"code" => "invalid_harness", "details" => [name]},
          %{error | code: sentinel},
          sentinel,
          :unknown,
          {:error, error}
        ] do
      assert PackageBuild.classify(reason) == :generic
    end

    remedies = [
      {"unsupported_runtime",
       "Use a supported coding agent target and runtime version listed below."},
      {"invalid_runtime_intent",
       "Review approved inputs for the selected coding agent target, then build again."},
      {"unsupported_required_control",
       "The selected coding agent cannot represent a required control. Review approved inputs or choose a compatible target."},
      {"runtime_unqualified",
       "Use a supported runtime profile. Managed execution requires a separately qualified runtime and backend."}
    ]

    for {code, message} <- remedies do
      assert PackageBuild.classify(%{error | code: code}) == {:runtime, code}
      assert PackageBuild.message({:runtime, code}) == message
      refute message =~ sentinel
    end

    for reason <-
          ~w(no_approved_claims goal_claim_requires_plan privacy_operation_incomplete cleanup_failed jobs_still_executing evaluations_still_running runtime_unqualified source_unavailable stale_or_revoked_evidence service_unavailable)a,
        do: assert(PackageBuild.classify(reason) == {:known, reason})

    assert PackageBuild.message(:name_help) == @help
    assert PackageBuild.message(:name) == "Check Package name."
    assert PackageBuild.message(:generic) == @generic
  end

  test "pure input retains bytes exactly, bounds UTF-8 bytes and gives stale generations priority" do
    generation = Ecto.UUID.generate()
    input = %{"package" => Map.put(@draft, "generation", generation)}

    assert {:ok, @draft} =
             PackageBuild.input(Map.put(input, "_csrf_token", "ignored"), generation)

    for value <- [
          "",
          "  literal <escaped>  ",
          String.duplicate("a", 4096),
          String.duplicate("é", 2048)
        ],
        field <- ~w(name version runtime_version) do
      attrs = Map.put(@draft, field, value)

      assert {:ok, ^attrs} =
               PackageBuild.input(
                 %{"package" => Map.put(attrs, "generation", generation)},
                 generation
               )
    end

    for value <- [
          nil,
          1,
          [],
          %{},
          <<255>>,
          String.duplicate("a", 4097),
          String.duplicate("é", 2049),
          "PRIVATE_\0",
          "0.1.\r\n0",
          "PRIVATE_\r",
          "PRIVATE_\n"
        ],
        field <- ~w(name version runtime_version) do
      bad = put_in(input, ["package", field], value)
      assert PackageBuild.input(bad, generation) == :invalid

      assert PackageBuild.input(put_in(bad, ["package", "generation"], "stale"), generation) ==
               :stale
    end

    for runtime <- ["unknown", "Codex", "", [], <<255>>, "codex\n"],
        do:
          assert(
            PackageBuild.input(put_in(input, ["package", "runtime"], runtime), generation) ==
              :invalid
          )

    for key <- ["extra", "_unused_name", "_unused_generation"],
        do:
          assert(PackageBuild.input(put_in(input, ["package", key], ""), generation) == :invalid)

    for field <- ~w(name version runtime runtime_version),
        do:
          assert(
            PackageBuild.input(Map.update!(input, "package", &Map.delete(&1, field)), generation) ==
              :invalid
          )

    struct_shaped = Map.update!(input, "package", &Map.put(&1, :__struct__, __MODULE__))
    assert PackageBuild.input(struct_shaped, generation) == :invalid

    assert PackageBuild.input(
             Map.update!(struct_shaped, "package", &Map.put(&1, "generation", "stale")),
             generation
           ) == :stale

    for value <- [
          %{},
          %{"package" => nil},
          %{"package" => []},
          %{"package" => @draft},
          put_in(input, ["package", "generation"], []),
          put_in(input, ["package", "generation"], nil)
        ],
        do: assert(PackageBuild.input(value, generation) == :stale)
  end

  test "unsafe current submissions clear defaults and never invoke or publish replacement values",
       ctx do
    approved_source()
    view = packages(ctx.conn)
    assert build_calls(view, fn -> submit(view, Map.put(@draft, "name", "calibration")) end) == 1
    before = publication_snapshot(ctx.root)
    {:ok, audit_before} = Audit.list_events()

    assert build_calls(view, fn ->
             for value <- [
                   nil,
                   1,
                   [],
                   %{},
                   <<255>>,
                   String.duplicate("a", 4097),
                   String.duplicate("é", 2049),
                   "PRIVATE_\0",
                   "0.1.\r\n0",
                   "PRIVATE_\r",
                   "PRIVATE_\n"
                 ],
                 field <- ~w(name version runtime_version) do
               input = put_in(envelope(view, @draft), ["package", field], value)
               old = generation(view)
               render_hook(view, "build", input)
               assert state(view).build_draft == PackageBuild.defaults()
               assert draft_values(view) == PackageBuild.defaults()
               assert generation(view) != old
               assert_generic_error(view)
               refute render(view) =~ "PRIVATE_"
             end

             for change <- [
                   %{"extra" => "PRIVATE_EXTRA"},
                   %{"runtime" => "invalid-runtime"},
                   %{"_unused_generation" => ""},
                   %{"_unused_name" => "PRIVATE_MARKER"},
                   %{"_unused_other" => ""},
                   %{__struct__: __MODULE__}
                 ] do
               render_hook(
                 view,
                 "build",
                 Map.update!(envelope(view, @draft), "package", &Map.merge(&1, change))
               )

               assert draft_values(view) == PackageBuild.defaults()
               assert_generic_error(view)
               refute render(view) =~ "PRIVATE_"
             end
           end) == 0

    assert publication_snapshot(ctx.root) == before
    assert {:ok, ^audit_before} = Audit.list_events()
  end

  test "current ordinary 4096-byte drafts reach validation without truncation and empty direct names refuse",
       ctx do
    approved_source()
    view = packages(ctx.conn)

    for name <- [
          String.duplicate("a", 4096),
          String.duplicate("é", 2048),
          "",
          "<script data-build-canary>private</script>"
        ] do
      attrs = Map.put(@draft, "name", name)
      assert build_calls(view, fn -> render_hook(view, "build", envelope(view, attrs)) end) == 1
      assert_name_error(view, attrs)
    end

    refute has_element?(view, "script[data-build-canary]")
    assert has_element?(view, "#package-name[required]")
    assert publication_snapshot(ctx.root) == {[], 0, []}
  end

  test "actual version and runtime refusals stay generic or specific without connector advice",
       ctx do
    approved_source()
    view = packages(ctx.conn)

    for attrs <- [
          Map.merge(@draft, %{"name" => "valid-name", "version" => "bad-version"}),
          Map.put(@draft, "version", "bad-version")
        ] do
      submit(view, attrs)
      assert_generic_error(view)
      assert draft_values(view) == attrs
    end

    submit(
      view,
      Map.merge(@draft, %{"name" => "valid-name", "runtime_version" => "unknown-profile"})
    )

    assert has_element?(
             view,
             "#error",
             "Package build: Use a supported coding agent target and runtime version listed below."
           )

    refute has_element?(view, "#package-name-error")
    refute render(view) =~ "provider page could not be imported"
    assert publication_snapshot(ctx.root) == {[], 0, []}
  end

  test "missing approval and real connector configuration errors keep their own remedies", ctx do
    view = packages(ctx.conn)
    submit(view, Map.put(@draft, "name", "valid-name"))

    assert has_element?(
             view,
             "#error",
             "Package build: Approve at least one eligible claim before building a package."
           )

    refute has_element?(view, "#package-name-error")

    render_submit(view, "connect_remote", %{
      "remote" => %{"name" => "Synthetic GitHub", "provider" => "github"}
    })

    assert has_element?(
             view,
             "#error",
             "Check the selected scope, site origin and environment reference names."
           )

    refute has_element?(view, "#error", "Package build:")
    assert publication_snapshot(ctx.root) == {[], 0, []}
  end

  test "stale and missing generations preserve a newer error and hidden Packages is a total no-op",
       ctx do
    approved_source()
    view = packages(ctx.conn)
    captured = envelope(view, @draft)
    assert build_calls(view, fn -> submit(view, @draft) end) == 1
    newer = Map.merge(@draft, %{"name" => "valid-name", "version" => "bad-version"})
    submit(view, newer)
    assert_generic_error(view)
    expected = build_state(view)

    assert build_calls(view, fn ->
             for input <- [
                   captured,
                   %{},
                   %{"package" => @draft},
                   put_in(envelope(view, @draft), ["package", "generation"], [])
                 ] do
               render_hook(view, "build", input)
               assert build_state(view) == expected
             end

             view |> element("#nav-evidence") |> render_click()
             assert_reset(view, expected.build_generation)
             hidden = build_state(view)
             render_hook(view, "build", envelope_from_state(view, @draft))
             assert build_state(view) == hidden
             render_hook(view, "build", captured)
             assert build_state(view) == hidden
           end) == 0

    view |> element("#nav-package") |> render_click()
    assert_reset(view, expected.build_generation)
    assert publication_snapshot(ctx.root) == {[], 0, []}
  end

  test "Phoenix empty visible-field markers are accepted but arbitrary nested markers remain invalid",
       ctx do
    approved_source()
    view = packages(ctx.conn)
    markers = Map.new(~w(name version runtime runtime_version), &{"_unused_" <> &1, ""})
    input = Map.update!(envelope(view, @draft), "package", &Map.merge(&1, markers))
    assert build_calls(view, fn -> render_hook(view, "build", input) end) == 1
    assert_name_error(view, @draft)

    assert build_calls(view, fn ->
             attrs =
               envelope(view, @draft)["package"]
               |> Map.delete("version")
               |> Map.put("_unused_version", "")

             render_hook(view, "build", %{"package" => attrs})
             assert_generic_error(view)
             assert draft_values(view) == PackageBuild.defaults()
           end) == 0
  end

  test "purge and cache-reset broadcasts erase sibling drafts and reject captured submissions",
       ctx do
    approved_source()
    unrelated = source("unrelated.md")
    views = [packages(ctx.conn), packages(ctx.conn)]
    private = Map.put(@draft, "name", "PRIVATE_BUILD_DRAFT")
    for view <- views, do: assert(build_calls(view, fn -> submit(view, private) end) == 1)
    captured = Map.new(views, &{&1.pid, envelope(&1, private)})
    [first, sibling] = views
    first |> element("#nav-privacy") |> render_click()

    first
    |> form("#purge-source-form", privacy: %{id: unrelated["id"], confirmation: unrelated["id"]})
    |> render_submit()

    assert has_element?(first, "#privacy-result", "completed")

    for view <- views do
      assert_reset(view, captured[view.pid]["package"]["generation"])
      expected = build_state(view)
      assert build_calls(view, fn -> render_hook(view, "build", captured[view.pid]) end) == 0
      assert build_state(view) == expected
    end

    submit(sibling, private)
    previous = generation(sibling)
    send(sibling.pid, :company_cache_reset)
    assert_reset(sibling, previous)
    assert publication_snapshot(ctx.root) == {[], 0, []}
  end

  @tag :committed
  test "real quarantined restore resets both mounted drafts without changing the active workspace",
       ctx do
    approved_source()
    {:ok, _} = Privacy.backup(ctx.root <> "-backup")
    views = [packages(ctx.conn), packages(ctx.conn)]
    for view <- views, do: submit(view, @draft)
    captured = Map.new(views, &{&1.pid, envelope(&1, @draft)})
    [first | _] = views
    active = Workspaces.current_id()
    first |> element("#nav-privacy") |> render_click()

    first
    |> form("#restore-form",
      privacy: %{backup: ctx.root <> "-backup", target: ctx.root <> "-restored"}
    )
    |> render_submit()

    assert has_element?(first, "#privacy-result", "quarantined")
    assert Workspaces.current_id() == active

    for view <- views do
      assert_reset(view, captured[view.pid]["package"]["generation"])
      expected = build_state(view)
      render_hook(view, "build", captured[view.pid])
      assert build_state(view) == expected
    end

    assert publication_snapshot(ctx.root) == {[], 0, []}
  end

  test "remount and operator revocation erase private drafts before redirect", ctx do
    approved_source()
    view = packages(ctx.conn)
    submit(view, Map.put(@draft, "name", "PRIVATE_BUILD_DRAFT"))
    captured = envelope(view, @draft)
    fresh = packages(ctx.conn)
    assert_reset(fresh, captured["package"]["generation"])
    expected = build_state(fresh)
    render_hook(fresh, "build", captured)
    assert build_state(fresh) == expected
    trace = {HarnessForgeWeb.PortalLive, :revoke_operator, 1}
    assert :erlang.trace_pattern(trace, [{:_, [], [{:return_trace}]}], [:local]) == 1
    :erlang.trace(view.pid, true, [:call, {:tracer, self()}])
    previous = :sys.get_state(Workspaces)
    :sys.replace_state(Workspaces, &%{&1 | epoch: "revoked-build-session"})

    try do
      assert {:error, {:redirect, %{to: "/login"}}} = render_hook(view, "build", captured)
      assert_receive {:trace, _, :return_from, ^trace, socket}
      assert socket.assigns.build_draft == PackageBuild.defaults()
      assert socket.assigns.build_outcome == nil
      refute socket.assigns.build_generation == captured["package"]["generation"]
    after
      :erlang.trace_pattern(trace, false, [:local])
      :sys.replace_state(Workspaces, fn _ -> previous end)
    end

    assert publication_snapshot(ctx.root) == {[], 0, []}
  end

  test "privacy admission refuses the current real build without publishing", ctx do
    source = approved_source()
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

    view = packages(ctx.conn)
    submit(view, Map.put(@draft, "name", "valid-name"))
    assert has_element?(view, "#error", "Package build: Content removal is incomplete.")
    refute has_element?(view, "#package-name-error")
    assert publication_snapshot(ctx.root) == {[], 0, []}
  end

  test "build recovery preserves immutable package files, export outcome and readiness identity",
       ctx do
    approved_source()
    {:ok, artifact} = Harnesses.build(%{"name" => "historical-package"})
    historical_files = elem(publication_snapshot(ctx.root), 0)
    view = packages(ctx.conn)

    view
    |> form("#package-readiness-form", readiness: %{digest: artifact["digest"]})
    |> render_change()

    view |> form("#package-readiness-form") |> render_submit()
    assert has_element?(view, "#readiness-report")
    target = Path.join(ctx.root, "occupied")
    File.mkdir!(target)
    initial_export_generation = state(view).export_generation

    view
    |> form("#package-export-form-#{initial_export_generation}-#{artifact["digest"]}",
      export: %{target: target}
    )
    |> render_submit()

    before = state(view)
    export_generation = before.export_generation
    refute export_generation == initial_export_generation
    assert before.export_outcome.status == :error
    assert before.export_outcome.invalid_target
    assert before.export_outcome.digest == artifact["digest"]
    assert before.export_outcome.target == target

    assert has_element?(
             view,
             "#package-export-error-#{export_generation}-#{artifact["digest"]}",
             "already exists"
           )

    submit(view, @draft)
    assert_name_error(view, @draft)
    after_refusal = state(view)
    assert after_refusal.export_generation == before.export_generation
    assert after_refusal.export_outcome == before.export_outcome
    assert after_refusal.readiness_digest == artifact["digest"]
    assert after_refusal.readiness_evaluation_id == before.readiness_evaluation_id
    assert after_refusal.readiness_controls_generation == before.readiness_controls_generation
    refute after_refusal.readiness_generation == before.readiness_generation
    assert after_refusal.readiness_report == nil

    assert has_element?(
             view,
             "#package-readiness-form input[name='readiness[generation]'][value='#{after_refusal.readiness_generation}']"
           )

    assert elem(publication_snapshot(ctx.root), 0) == historical_files

    submit(view, Map.put(@draft, "name", "new-package"))
    assert {:ok, ^artifact} = Harnesses.get(artifact["digest"])
    assert {:ok, ^artifact} = Compiler.compile(artifact["spec"])
    current_files = Map.new(elem(publication_snapshot(ctx.root), 0))
    for {path, hash} <- historical_files, do: assert(current_files[path] == hash)
    assert state(view).export_generation == export_generation
    assert state(view).export_outcome == before.export_outcome
    assert state(view).readiness_digest == artifact["digest"]
    assert state(view).readiness_controls_generation == before.readiness_controls_generation
    assert {:ok, []} = Evaluations.list_runs()
  end

  defp packages(conn) do
    {:ok, view, _} = live(conn, "/")
    view |> element("#nav-package") |> render_click()
    view
  end

  defp submit(view, attrs), do: view |> form("#build-form", package: attrs) |> render_submit()
  defp document(view), do: view |> render() |> LazyHTML.from_document()

  defp generation(view),
    do:
      document(view)
      |> LazyHTML.query("#build-form input[name='package[generation]']")
      |> LazyHTML.attribute("value")
      |> hd()

  defp envelope(view, attrs), do: %{"package" => Map.put(attrs, "generation", generation(view))}

  defp envelope_from_state(view, attrs),
    do: %{"package" => Map.put(attrs, "generation", state(view).build_generation)}

  defp state(view) do
    render(view)
    :sys.get_state(view.pid).socket.assigns
  end

  defp build_state(view),
    do: Map.take(state(view), [:build_draft, :build_generation, :build_outcome, :flash])

  defp draft_values(view) do
    doc = document(view)

    Map.new(~w(name version runtime runtime_version), fn field ->
      node = LazyHTML.query(doc, "#build-form [name='package[#{field}]']")

      values =
        if field == "runtime",
          do: node |> LazyHTML.query("option[selected]") |> LazyHTML.attribute("value"),
          else: LazyHTML.attribute(node, "value")

      {field, hd(values)}
    end)
  end

  defp assert_name_error(view, attrs) do
    assert has_element?(
             view,
             "#build-form[phx-auto-recover=ignore][data-build-outcome=name][data-build-generation='#{generation(view)}'][data-company-reset-token]"
           )

    assert has_element?(view, "#package-name-help", @help)

    assert has_element?(
             view,
             "#package-name-error:not([role]):not([aria-live]):not([tabindex])",
             "Check Package name."
           )

    assert has_element?(
             view,
             "#package-name[aria-invalid=true][aria-describedby='package-name-help package-name-error']"
           )

    assert has_element?(view, "#error", "Package build: Check Package name.")
    assert draft_values(view) == attrs
    assert state(view).build_draft == attrs
    refute render(view) =~ "provider page could not be imported"
  end

  defp assert_generic_error(view) do
    assert has_element?(view, "#error", "Package build: " <> @generic)
    refute has_element?(view, "#package-name-error")
    refute has_element?(view, "#package-name[aria-invalid]")
    assert has_element?(view, "#package-name[aria-describedby=package-name-help]")
    refute render(view) =~ "provider page could not be imported"
  end

  defp assert_reset(view, previous) do
    assigns = state(view)
    assert assigns.build_draft == PackageBuild.defaults()
    assert assigns.build_outcome == nil
    refute assigns.build_generation == previous
    refute render(view) =~ "PRIVATE_BUILD_DRAFT"
    refute has_element?(view, "#package-name-error")
    if assigns.tab == "package", do: assert(draft_values(view) == PackageBuild.defaults())
  end

  defp source(external_id \\ "guide.md") do
    {:ok, connection} =
      Evidence.connect(%{
        "name" => "Synthetic build fixture",
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

  defp approved_source do
    source = source()
    revision = source["latest_revision"]
    {:ok, citation} = Evidence.citation(revision["id"], 0, byte_size(revision["body"]))

    {:ok, claim} =
      Evidence.create_claim(%{
        "text" => "Review changes deliberately.",
        "citations" => [citation]
      })

    {:ok, _} =
      Decisions.decide(claim["id"], %{
        "actor" => Workspaces.operator(),
        "decision" => "approve",
        "expected_revision_hash" => claim["revision_hash"]
      })

    assert {:ok, [current]} = Evidence.approved_claims()
    assert current["id"] == claim["id"]
    source
  end

  defp specification,
    do:
      Path.expand("../../examples/synthetic_company/harness.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()

  defp built_count do
    {:ok, events} = Audit.list_events()
    Enum.count(events, &(&1["action"] == "harness.built"))
  end

  defp publication_snapshot(root) do
    files =
      Path.wildcard(Path.join(root, "artifacts/**/*"), match_dot: true)
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&{Path.relative_to(&1, root), Contracts.sha256(File.read!(&1))})

    {:ok, runs} = Evaluations.list_runs()
    {files, built_count(), runs}
  end

  # This traces the real installed arity. Every zero-call episode above first
  # calibrates the same instrumentation with an actual admitted form submission.
  defp build_calls(view, fun) do
    Code.ensure_loaded!(Harnesses)
    mfa = {Harnesses, :build, 1}
    assert :erlang.trace_pattern(mfa, true, [:local]) == 1
    :erlang.trace(view.pid, true, [:call, :arity, {:tracer, self()}])

    try do
      fun.()
      delivery = :erlang.trace_delivered(view.pid)
      assert_receive {:trace_delivered, _, ^delivery}, 1_000
      count_build_calls(view.pid, 0)
    after
      if Process.alive?(view.pid), do: :erlang.trace(view.pid, false, [:all])
      :erlang.trace_pattern(mfa, false, [:local])
    end
  end

  defp count_build_calls(pid, count) do
    receive do
      {:trace, ^pid, :call, {Harnesses, :build, 1}} -> count_build_calls(pid, count + 1)
    after
      0 -> count
    end
  end
end
