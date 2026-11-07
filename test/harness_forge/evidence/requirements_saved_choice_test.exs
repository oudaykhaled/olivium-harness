defmodule HarnessForge.Evidence.RequirementsSavedChoiceTest do
  use HarnessForge.DataCase, async: false

  alias HarnessForge.{Company, CompanyAnalysisFixture, Contracts, Goals, Repo, Workspaces}
  alias HarnessForge.Evidence.Corpora

  setup do
    root = Path.join(System.tmp_dir!(), "coverage-choice-#{Ecto.UUID.generate()}")
    fixture = CompanyAnalysisFixture.create!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, corpus} = Corpora.create(%{"name" => "Synthetic setup coverage"}, caller())

    {:ok, _} =
      Company.bind_corpus(
        fixture.project["id"],
        corpus["id"],
        fixture.profile["content_hash"],
        fixture.project["content_hash"],
        caller()
      )

    %{fixture: fixture, corpus: corpus}
  end

  test "valid scope without a saved declaration returns an explicit empty choice", c do
    before = dispatch_counts()
    assert {:ok, []} = choices(c)
    assert dispatch_counts() == before
  end

  test "only the exact current revision is offered as bounded metadata, with no dispatch", c do
    first = declare(c)
    before = dispatch_counts()
    assert {:ok, [metadata]} = choices(c)
    assert Enum.sort(Map.keys(metadata)) == ~w(digest id inserted_at revision)
    assert Map.take(metadata, ~w(id digest revision)) == Map.take(first, ~w(id digest revision))
    assert dispatch_counts() == before

    second = declare(c)
    assert {:ok, [next]} = choices(c)
    assert next["id"] == second["id"]
    refute next["id"] == first["id"]
    assert next["revision"] == first["revision"] + 1
  end

  test "a declaration with changed corpus generation is stale rather than an empty choice", c do
    declare(c)
    assert :ok = Corpora.advance(c.corpus["id"])
    assert {:error, :stale_declaration} = choices(c)
  end

  test "an expected stale declaration read preserves the caller's transaction", c do
    first = declare(c)
    current = declare(c)

    assert {:ok, :still_current} =
             Repo.transaction(fn ->
               assert {:error, :stale_declaration} =
                        HarnessForge.Evidence.Requirements.current_summary(
                          first["id"],
                          first["digest"]
                        )

               # An expected read denial must not prevent subsequent accounting
               # or recovery reads in the transaction that owns the operation.
               assert {:ok, %{rows: [[1]]}} = Repo.query("SELECT 1")

               assert {:ok, summary} =
                        HarnessForge.Evidence.Requirements.current_summary(
                          current["id"],
                          current["digest"]
                        )

               assert summary["id"] == current["id"]
               :still_current
             end)

    assert {:error, :stale_declaration} =
             HarnessForge.Evidence.Requirements.current_summary(first["id"], first["digest"])
  end

  test "revocation withholds the saved choice rather than returning its identity", c do
    declare(c)

    Repo.query!("UPDATE source_connections SET status='revoked' WHERE id=?", [
      c.fixture.connection["id"]
    ])

    assert {:error, _} = choices(c)
  end

  test "wrong scope, changed goal and denied caller cannot enumerate declarations", c do
    declare(c)
    assert {:error, _} = choices(c, Ecto.UUID.generate())

    assert {:error, _} =
             Corpora.requirements_saved_choice(
               c.corpus["id"],
               c.fixture.project["id"],
               c.fixture.goal["id"],
               String.duplicate("0", 64),
               caller()
             )

    assert {:error, _} =
             choices(
               c,
               c.fixture.project["id"],
               Keyword.put(caller(), :authorize, fn -> false end)
             )

    workspace = Workspaces.current_id()

    try do
      Application.put_env(:harness_forge, :workspace_id, Ecto.UUID.generate())
      assert {:error, _} = choices(c)
    after
      Application.put_env(:harness_forge, :workspace_id, workspace)
    end
  end

  test "a database lookup failure is unavailable, never an empty success", c do
    Repo.query!("ALTER TABLE corpus_requirements RENAME TO coverage_choice_unavailable")
    assert {:error, :unavailable} = choices(c)
  end

  defp choices(c, project_id \\ nil, opts \\ nil) do
    Corpora.requirements_saved_choice(
      c.corpus["id"],
      project_id || c.fixture.project["id"],
      c.fixture.goal["id"],
      Goals.content_hash(c.fixture.goal),
      opts || caller()
    )
  end

  defp declare(c) do
    {:ok, context} =
      Corpora.requirements_context(
        c.corpus["id"],
        c.fixture.project["id"],
        c.fixture.goal["id"],
        Goals.content_hash(c.fixture.goal),
        caller()
      )

    {:ok, declaration} =
      Corpora.declare_requirements(
        c.corpus["id"],
        context["expected"],
        %{
          "project_id" => c.fixture.project["id"],
          "goal_id" => c.fixture.goal["id"],
          "primary_connection_id" => c.fixture.connection["id"],
          "entries" => [
            %{
              "connection_id" => c.fixture.connection["id"],
              "requirement" => "required",
              "capture_run_id" => nil,
              "capture_revision" => nil
            }
          ]
        },
        caller()
      )

    declaration
  end

  defp caller do
    [
      authorize: fn -> true end,
      session_fingerprint: Contracts.sha256("synthetic saved coverage choice"),
      view_generation: String.duplicate("f", 32),
      reset_token: 0
    ]
  end

  defp dispatch_counts do
    for table <- ~w(model_requests stage_operations evaluation_runs), into: %{} do
      [[count]] =
        Repo.query!("SELECT count(*) FROM #{table} WHERE workspace_id=?", [
          Workspaces.current_id()
        ]).rows

      {table, count}
    end
  end
end
