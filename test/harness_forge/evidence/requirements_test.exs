defmodule HarnessForge.Evidence.RequirementsTest do
  use HarnessForge.DataCase, async: false

  alias HarnessForge.{CompanyAnalysisFixture, Contracts, Evidence, Repo, Workspaces}
  alias HarnessForge.Company.{Readiness, Retrieval}
  alias HarnessForge.Evidence.{Capture, Corpora, Passages, Store}

  setup do
    root = Path.join(System.tmp_dir!(), "requirements-#{Ecto.UUID.generate()}")
    f = CompanyAnalysisFixture.create!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    if Process.whereis(Capture.Scanner) == nil, do: start_supervised!({Capture.Scanner, []})
    {:ok, corpus} = Corpora.create(%{"name" => "Synthetic declared coverage"}, caller())

    {:ok, _} =
      Corpora.apply_members(
        corpus["id"],
        0,
        Enum.map(f.sources, fn source ->
          %{
            "source_id" => source["id"],
            "revision_id" => source["latest_revision"]["id"],
            "action" => "include"
          }
        end),
        caller()
      )

    for source <- f.sources do
      File.write!(
        Path.join(f.connection["directory"], source["external_id"]),
        source["latest_revision"]["body"]
      )

      assert {:ok, _} = Passages.index_revision(source["latest_revision"]["id"])
    end

    now = Corpora.now()

    Repo.query!(
      "INSERT INTO company_corpus_bindings(workspace_id,project_id,profile_id,corpus_id,inserted_at,updated_at) VALUES(?,?,?,?,?,?)",
      [Store.workspace(), f.project["id"], f.profile["id"], corpus["id"], now, now]
    )

    %{fixture: f, corpus_id: corpus["id"], root: root}
  end

  test "real required capture and failed optional receipt survive reload with exact named provenance and usable retrieval",
       c do
    {optional, failed} = optional_capture(c, "optional-failed", false)
    capture(c, c.fixture.connection)

    for [id] <-
          Repo.query!(
            "SELECT latest_revision_id FROM evidence_sources WHERE workspace_id=? AND connection_id=?",
            [Store.workspace(), c.fixture.connection["id"]]
          ).rows,
        do: assert({:ok, _} = Passages.index_revision(id))

    primary = capture(c, c.fixture.connection)
    assert primary["revision"] > 1

    {:ok, declaration} =
      declare(c, [entry(c.fixture.connection, primary), entry(optional, failed, "optional")])

    assert declaration["required_status"] == "complete"
    assert declaration["member_count"] == 4
    assert [omission] = declaration["omissions"]
    assert omission["connector_name"] == optional["name"]
    assert omission["capture_run_id"] == failed["run_id"]
    assert omission["capture_revision"] == failed["revision"]
    assert omission["declaration_id"] == declaration["id"]
    assert omission["declaration_digest"] == declaration["digest"]
    before = counts()

    assert {:ok, ^declaration} =
             Corpora.requirements_summary(declaration["id"], declaration["digest"], caller())

    projected = Readiness.for_corpus(selection(c), %{declaration_ref: declaration}, caller())
    assert projected["facts"]["capture"]["status"] == "complete_for_selected_scope"

    assert projected["facts"]["capture"]["pins"]["declaration_revision"] ==
             declaration["revision"]

    assert projected["omissions"] == [omission]
    assert projected["facts"]["understanding"]["status"] == "unknown"
    assert counts() == before
    {:ok, corpus} = Corpora.get(c.corpus_id)

    assert {:ok, run} =
             Retrieval.retrieve(
               %{
                 "corpus_id" => c.corpus_id,
                 "project_id" => c.fixture.project["id"],
                 "goal_id" => c.fixture.goal["id"],
                 "goal_hash" => c.fixture.input["goal_content_hash"],
                 "expected_generation" => corpus.semantic_generation,
                 "question" => "Which review and rollback practices apply?",
                 "mode" => "fts"
               },
               caller()
             )

    assert run["state"] == "ready"
    refute Jason.encode!(declaration) =~ hd(c.fixture.sources)["latest_revision"]["body"]
    for key <- ~w(rows source_ids passages revisions), do: refute(Map.has_key?(declaration, key))
  end

  test "an absent receipt or an optional missing directory does not fabricate an outage", c do
    primary = capture(c, c.fixture.connection)
    dir = Path.join(c.root, "missing-optional")
    File.mkdir_p!(dir)

    {:ok, optional} =
      Evidence.connect(%{
        "name" => "Optional never captured",
        "provider" => "local",
        "directory" => dir
      })

    File.rmdir!(dir)

    {:ok, declaration} =
      declare(c, [entry(c.fixture.connection, primary), entry(optional, nil, "optional")])

    assert declaration["required_status"] == "complete"
    assert declaration["omissions"] == []
    assert List.last(declaration["entries"])["state"] == "unknown"
    {:ok, unknown} = declare(c, [entry(c.fixture.connection, nil)])
    assert unknown["required_status"] == "unknown"
    assert unknown["omissions"] == []
  end

  test "required failure blocks and an optional partial capture cannot hide active corpus members",
       c do
    {optional, failed} = optional_capture(c, "optional-partial", true)
    primary = capture(c, c.fixture.connection)

    {:ok, partial} =
      declare(c, [entry(c.fixture.connection, primary), entry(optional, failed, "optional")])

    assert partial["required_status"] == "blocked"
    assert partial["omissions"] == []
    assert List.last(partial["entries"])["reason_code"] == "capture_partial"
    {:ok, required} = declare(c, [entry(c.fixture.connection, primary), entry(optional, failed)])
    assert required["required_status"] == "blocked"
  end

  test "one directory receipt cannot complete undeclared corpus membership", c do
    {_optional, _failed} = optional_capture(c, "undeclared", true)
    primary = capture(c, c.fixture.connection)
    {:ok, declared} = declare(c, [entry(c.fixture.connection, primary)])
    assert declared["required_status"] == "unknown"
    assert declared["undeclared_members"] == 1

    projected =
      Readiness.for_corpus(selection(c), %{declaration_ref: declared, capture: primary}, caller())

    assert projected["facts"]["capture"]["status"] == "unknown"
    assert projected["facts"]["capture"]["reason_code"] == "undeclared_members"
  end

  test "exact revision, declaration version, digest and caller scope reject stale or forged selection",
       c do
    primary = capture(c, c.fixture.connection)
    expected = context(c)["expected"]
    attrs = attrs(c, [entry(c.fixture.connection, primary)])
    {:ok, first} = Corpora.declare_requirements(c.corpus_id, expected, attrs, caller())

    assert {:error, :stale_declaration} =
             Corpora.declare_requirements(c.corpus_id, expected, attrs, caller())

    {:ok, next} = declare(c, attrs["entries"])
    assert next["revision"] == first["revision"] + 1

    assert {:error, :stale_declaration} =
             Corpora.requirements_summary(first["id"], first["digest"], caller())

    assert {:error, _} =
             Corpora.requirements_summary(next["id"], String.duplicate("0", 64), caller())

    assert {:error, _} =
             Corpora.requirements_summary(
               next["id"],
               next["digest"],
               Keyword.put(caller(), :authorize, fn -> false end)
             )

    old = Workspaces.current_id()

    try do
      Application.put_env(:harness_forge, :workspace_id, Ecto.UUID.generate())
      assert {:error, _} = Corpora.requirements_summary(next["id"], next["digest"], caller())
    after
      Application.put_env(:harness_forge, :workspace_id, old)
    end

    Repo.query!("UPDATE capture_runs SET lock_version=lock_version+1 WHERE id=?", [
      primary["run_id"]
    ])

    assert {:error, :stale_receipt} =
             Corpora.requirements_summary(next["id"], next["digest"], caller())

    assert {:error, :stale_receipt} = declare(c, attrs["entries"])
  end

  test "generations, revocation and configuration changes withhold selected completion", c do
    primary = capture(c, c.fixture.connection)
    {:ok, declared} = declare(c, [entry(c.fixture.connection, primary)])

    Repo.query!("UPDATE source_connections SET config='{" <> "\"changed\":true}' WHERE id=?", [
      c.fixture.connection["id"]
    ])

    assert {:error, :stale_declaration} =
             Corpora.requirements_summary(declared["id"], declared["digest"], caller())

    projected =
      Readiness.for_corpus(selection(c), %{declaration_ref: declared, capture: primary}, caller())

    assert projected["facts"]["capture"]["status"] == "stale"
    assert projected["omissions"] == []

    Repo.query!("UPDATE source_connections SET status='revoked' WHERE id=?", [
      c.fixture.connection["id"]
    ])

    assert {:error, :stale_declaration} =
             Corpora.requirements_summary(declared["id"], declared["digest"], caller())

    Repo.query!(
      "UPDATE corpora SET authorization_generation=authorization_generation+1 WHERE id=?",
      [c.corpus_id]
    )

    assert {:error, :stale_declaration} =
             Corpora.requirements_summary(declared["id"], declared["digest"], caller())
  end

  test "a queued receipt cannot silently become a completed declaration after scan", c do
    capture(c, c.fixture.connection)
    {:ok, corpus} = Corpora.get(c.corpus_id)

    {:ok, queued} =
      Capture.start_capture(
        c.corpus_id,
        c.fixture.connection["id"],
        corpus.semantic_generation,
        caller()
      )

    {:ok, saved} = declare(c, [entry(c.fixture.connection, queued)])
    assert saved["required_status"] == "unknown"
    assert {:ok, completed} = Capture.run(queued["run_id"])
    # Acquiring the running lease is one receipt transition; publishing its
    # final outcome must also invalidate the in-flight revision.
    assert completed["revision"] > queued["revision"] + 1

    assert {:error, :stale_receipt} =
             Corpora.requirements_summary(saved["id"], saved["digest"], caller())
  end

  test "capture choices paginate metadata and bind caller, connection and generation", c do
    for _ <- 1..27 do
      {:ok, corpus} = Corpora.get(c.corpus_id)

      assert {:ok, queued} =
               Capture.start_capture(
                 c.corpus_id,
                 c.fixture.connection["id"],
                 corpus.semantic_generation,
                 caller()
               )

      assert {:ok, _} = Capture.cancel(queued["run_id"], queued["revision"], caller())
    end

    {:ok, page} =
      Corpora.requirement_capture_choices(c.corpus_id, c.fixture.connection["id"], %{}, caller())

    assert length(page["rows"]) == 25
    assert is_binary(page["next_cursor"])

    {:ok, next} =
      Corpora.requirement_capture_choices(
        c.corpus_id,
        c.fixture.connection["id"],
        %{"cursor" => page["next_cursor"]},
        caller()
      )

    assert length(next["rows"]) == 2
    refute Enum.any?(next["rows"], &(&1 in page["rows"]))

    assert {:error, _} =
             Corpora.requirement_capture_choices(
               c.corpus_id,
               c.fixture.connection["id"],
               %{"cursor" => page["next_cursor"]},
               Keyword.put(caller(), :session_fingerprint, Contracts.sha256("other"))
             )

    Repo.query!("UPDATE corpora SET semantic_generation=semantic_generation+1 WHERE id=?", [
      c.corpus_id
    ])

    assert {:error, _} =
             Corpora.requirement_capture_choices(
               c.corpus_id,
               c.fixture.connection["id"],
               %{"cursor" => page["next_cursor"]},
               caller()
             )
  end

  test "unknown fields, duplicate roles, optional-only and foreign receipts cannot become saved authority",
       c do
    primary = capture(c, c.fixture.connection)
    valid = attrs(c, [entry(c.fixture.connection, primary)])

    for input <- [
          Map.put(valid, "complete", true),
          Map.put(valid, "entries", []),
          Map.put(valid, "entries", [entry(c.fixture.connection, primary, "optional")]),
          Map.put(valid, "entries", [
            entry(c.fixture.connection, primary),
            entry(c.fixture.connection, primary, "optional")
          ])
        ] do
      assert {:error, :invalid_input} =
               Corpora.declare_requirements(c.corpus_id, context(c)["expected"], input, caller())
    end

    {optional, failed} = optional_capture(c, "foreign", false)

    forged =
      attrs(c, [
        Map.put(entry(c.fixture.connection, failed), "connection_id", c.fixture.connection["id"])
      ])

    assert {:error, :invalid_scope} =
             Corpora.declare_requirements(c.corpus_id, context(c)["expected"], forged, caller())

    refute optional["id"] == c.fixture.connection["id"]

    assert Repo.query!("SELECT count(*) FROM corpus_requirements WHERE workspace_id=?", [
             Store.workspace()
           ]).rows == [[0]]
  end

  defp context(c) do
    {:ok, result} =
      Corpora.requirements_context(
        c.corpus_id,
        c.fixture.project["id"],
        c.fixture.goal["id"],
        c.fixture.input["goal_content_hash"],
        caller()
      )

    result
  end

  defp declare(c, entries),
    do:
      Corpora.declare_requirements(
        c.corpus_id,
        context(c)["expected"],
        attrs(c, entries),
        caller()
      )

  defp attrs(c, entries),
    do: %{
      "project_id" => c.fixture.project["id"],
      "goal_id" => c.fixture.goal["id"],
      "primary_connection_id" => c.fixture.connection["id"],
      "entries" => entries
    }

  defp entry(connection, run, role \\ "required"),
    do: %{
      "connection_id" => connection["id"],
      "requirement" => role,
      "capture_run_id" => run && run["run_id"],
      "capture_revision" => run && run["revision"]
    }

  defp selection(c),
    do: %{
      "connection_id" => c.fixture.connection["id"],
      "project_id" => c.fixture.project["id"],
      "goal_id" => c.fixture.goal["id"],
      "goal_content_hash" => c.fixture.input["goal_content_hash"]
    }

  defp capture(c, connection) do
    {:ok, corpus} = Corpora.get(c.corpus_id)

    {:ok, run} =
      Capture.start_capture(c.corpus_id, connection["id"], corpus.semantic_generation, caller())

    assert {:ok, _} = Capture.run(run["run_id"])
    {:ok, current} = Capture.capture_status(run["run_id"], %{}, caller())
    current
  end

  defp optional_capture(c, suffix, with_member) do
    dir = Path.join(c.root, suffix)
    File.mkdir_p!(dir)

    {:ok, connection} =
      Evidence.connect(%{
        "name" => "Synthetic optional <#{suffix}>",
        "provider" => "local",
        "directory" => dir
      })

    if with_member do
      {:ok, source} =
        Evidence.import_markdown(connection["id"], %{
          "external_id" => "retained.md",
          "title" => "Retained",
          "body" => "Retain this captured policy despite an incomplete scan."
        })

      {:ok, corpus} = Corpora.get(c.corpus_id)

      {:ok, _} =
        Corpora.apply_members(
          c.corpus_id,
          corpus.semantic_generation,
          [
            %{
              "source_id" => source["id"],
              "revision_id" => source["latest_revision"]["id"],
              "action" => "include"
            }
          ],
          caller()
        )
    end

    File.ln_s!(dir, Path.join(dir, "unsafe-link"))
    run = capture(c, connection)
    refute run["capture"]["complete"]
    {connection, run}
  end

  defp counts,
    do:
      Map.new(~w(model_requests stage_attempts evidence_claims corpus_requirements), fn table ->
        {table, Repo.query!("SELECT count(*) FROM #{table}", []).rows}
      end)

  defp caller,
    do: [
      authorize: fn -> true end,
      session_fingerprint: Contracts.sha256("requirements caller"),
      view_generation: String.duplicate("e", 32),
      reset_token: 0
    ]
end
