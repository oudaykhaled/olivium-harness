defmodule HarnessForge.Company.ReadinessSummaryTest do
  use HarnessForge.DataCase, async: false

  alias HarnessForge.{CompanyAnalysisFixture, Contracts, Evidence, Repo, Workspaces}
  alias HarnessForge.Company.Retrieval
  alias HarnessForge.Evidence.{Capture, Corpora, Passages, Store}

  setup do
    root = Path.join(System.tmp_dir!(), "readiness-summary-#{Ecto.UUID.generate()}")
    fixture = CompanyAnalysisFixture.create!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, corpus} = Corpora.create(%{"name" => "Synthetic readiness mechanics"}, caller())

    changes =
      Enum.map(fixture.sources, fn source ->
        %{
          "source_id" => source["id"],
          "revision_id" => source["latest_revision"]["id"],
          "action" => "include"
        }
      end)

    {:ok, _} = Corpora.apply_members(corpus["id"], 0, changes, caller())
    for source <- fixture.sources, do: Passages.index_revision(source["latest_revision"]["id"])
    now = Corpora.now()

    Repo.query!(
      "INSERT INTO company_corpus_bindings(workspace_id,project_id,profile_id,corpus_id,inserted_at,updated_at) VALUES(?,?,?,?,?,?)",
      [Store.workspace(), fixture.project["id"], fixture.profile["id"], corpus["id"], now, now]
    )

    {:ok, current} = Corpora.get(corpus["id"])

    input = %{
      "corpus_id" => corpus["id"],
      "project_id" => fixture.project["id"],
      "goal_id" => fixture.goal["id"],
      "goal_hash" => fixture.input["goal_content_hash"],
      "expected_generation" => current.semantic_generation,
      "question" => "Which release review and rollback records apply?",
      "mode" => "fts"
    }

    %{fixture: fixture, corpus: current, input: input}
  end

  test "checked retrieval summary contains exact scope metadata without passage bodies or writes",
       c do
    {:ok, run} = Retrieval.retrieve(c.input, caller())
    before = counts()
    assert {:ok, summary} = Retrieval.read_summary(run["run_id"], run["digest"], caller())

    assert Enum.sort(Map.keys(summary)) ==
             Enum.sort(
               ~w(run_id digest state mode semantic_generation authorization_generation coverage selected_count next_cursor scope)
             )

    assert Map.drop(summary, ["scope"]) == run
    assert summary["scope"]["workspace_id"] == Store.workspace()
    assert summary["scope"]["corpus_id"] == c.corpus.id
    assert summary["scope"]["project"] == Map.take(c.fixture.project, ~w(id content_hash))
    assert summary["scope"]["goal_hash"] == c.input["goal_hash"]
    refute Jason.encode!(summary) =~ hd(c.fixture.sources)["latest_revision"]["body"]
    for key <- ~w(rows snippet parent_text passages), do: refute(Map.has_key?(summary, key))
    assert counts() == before
  end

  test "retrieval summary preserves digest, authorization, workspace and generation fences", c do
    {:ok, run} = Retrieval.retrieve(c.input, caller())

    assert {:error, _} =
             Retrieval.read_summary(run["run_id"], String.duplicate("0", 64), caller())

    denied = Keyword.put(caller(), :authorize, fn -> false end)
    assert {:error, _} = Retrieval.read_summary(run["run_id"], run["digest"], denied)
    original_workspace = Workspaces.current_id()

    try do
      Application.put_env(:harness_forge, :workspace_id, Ecto.UUID.generate())
      assert {:error, _} = Retrieval.read_summary(run["run_id"], run["digest"], caller())
    after
      Application.put_env(:harness_forge, :workspace_id, original_workspace)
    end

    Repo.query!(
      "UPDATE corpora SET authorization_generation=authorization_generation+1 WHERE id=?",
      [c.corpus.id]
    )

    assert {:error, :stale_generation} =
             Retrieval.read_summary(run["run_id"], run["digest"], caller())
  end

  test "verified physical capture pins its completion scope and later source change stays stale",
       c do
    if Process.whereis(Capture.Scanner) == nil, do: start_supervised!({Capture.Scanner, []})

    for source <- c.fixture.sources do
      File.write!(
        Path.join(c.fixture.connection["directory"], source["external_id"]),
        source["latest_revision"]["body"]
      )
    end

    {:ok, run} =
      Capture.start_capture(
        c.corpus.id,
        c.fixture.connection["id"],
        c.corpus.semantic_generation,
        caller()
      )

    assert {:ok, result} = Capture.run(run["run_id"])
    assert result["capture"]["complete"]
    before = counts()
    assert {:ok, summary} = Capture.read_summary(run["run_id"], caller())
    assert summary["scope_current"] == "current"
    assert summary["corpus_id"] == c.corpus.id
    assert summary["connection_id"] == c.fixture.connection["id"]
    assert summary["scope"]["workspace_id"] == Store.workspace()
    assert summary["scope"]["corpus_id"] == c.corpus.id
    assert summary["scope"]["connection_id"] == c.fixture.connection["id"]
    refute Map.has_key?(summary, "rows")
    refute Jason.encode!(summary) =~ "policy.md"
    assert counts() == before

    source = hd(c.fixture.sources)

    assert {:ok, _} =
             Evidence.import_markdown(c.fixture.connection["id"], %{
               "external_id" => source["external_id"],
               "title" => source["title"],
               "body" => "Changed synthetic guidance requires fresh capture."
             })

    assert {:ok, stale} = Capture.read_summary(run["run_id"], caller())
    assert stale["scope_current"] == "stale"
    assert stale["scope"] == summary["scope"]
    assert stale["capture"]["complete"]
  end

  test "legacy capture completion without stored generation pins remains unknown", c do
    {:ok, run} =
      Capture.start_capture(
        c.corpus.id,
        c.fixture.connection["id"],
        c.corpus.semantic_generation,
        caller()
      )

    Repo.query!(
      "UPDATE capture_runs SET state='scan_complete',scan_verified=1,incomplete=0,counts='{}' WHERE id=?",
      [run["run_id"]]
    )

    assert {:ok, summary} = Capture.read_summary(run["run_id"], caller())
    assert summary["capture"]["complete"]
    assert summary["scope_current"] == "unknown"
    assert is_nil(summary["scope"])

    assert {:error, _} =
             Capture.read_summary(
               run["run_id"],
               Keyword.put(caller(), :authorize, fn -> false end)
             )

    assert {:error, _} = Capture.read_summary(Ecto.UUID.generate(), caller())
  end

  defp counts do
    for table <-
          ~w(retrieval_runs retrieval_items capture_runs model_requests evidence_claims company_plans),
        into: %{} do
      {table, Repo.query!("SELECT count(*) FROM #{table}", []).rows}
    end
  end

  defp caller,
    do: [
      authorize: fn -> true end,
      session_fingerprint: Contracts.sha256("readiness caller"),
      view_generation: String.duplicate("d", 32),
      reset_token: 0
    ]
end
