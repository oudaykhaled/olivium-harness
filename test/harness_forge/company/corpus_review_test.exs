defmodule HarnessForge.Company.CorpusReviewTest do
  use HarnessForge.DataCase, async: false
  alias HarnessForge.{Company, CompanyAnalysisFixture, Contracts, Evidence, Goals, Models}
  alias HarnessForge.Company.{Analysis, CorpusReview}
  alias HarnessForge.Evidence.{Connection, Source, Store}

  setup do
    root = Path.join([File.cwd!(), "tmp", "corpus-review-#{System.unique_integer([:positive])}"])
    fixture = CompanyAnalysisFixture.create!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{fixture: fixture, caller: caller()}
  end

  test "reads require actual server authorization and strict string-keyed attrs", %{
    fixture: f,
    caller: c
  } do
    denied = Keyword.put(c, :authorize, fn -> false end)
    assert {:error, :operator_session_revoked} = CorpusReview.source_page(%{}, denied)
    assert {:error, :invalid_input} = CorpusReview.source_page(%{}, authorized: true)

    assert {:error, :invalid_input} =
             CorpusReview.source_page(%{"workspace_id" => Store.workspace()}, c)

    assert {:error, :invalid_input} = CorpusReview.source_page(%{query: "policy"}, c)

    assert {:error, :invalid_input} =
             CorpusReview.open_scope(Map.put(scope_attrs(f), "authorized", true), c)

    assert {:error, :invalid_input} = CorpusReview.choices(%{"kind" => "all"}, c)
    assert {:error, :invalid_input} = CorpusReview.source_page(%{"connection_id" => :all}, c)
  end

  test "scope pins assigned goal and exact current profile, project and connection", %{
    fixture: f,
    caller: c
  } do
    assert {:ok, opened} = CorpusReview.open_scope(scope_attrs(f), c)
    assert opened["scope"]["project"]["id"] == f.project["id"]
    assert opened["scope"]["goal"]["content_hash"] == f.input["goal_content_hash"]
    refute Map.has_key?(opened["scope"]["connection"], "directory")
    refute Map.has_key?(opened["scope"]["connection"], "config")

    {:ok, unassigned} =
      Goals.add_goal(%{
        "title" => "Unassigned",
        "owner" => "Synthetic",
        "acceptance" => "Unused intent"
      })

    attrs =
      Map.merge(scope_attrs(f), %{
        "goal_id" => unassigned["id"],
        "goal_content_hash" => Goals.content_hash(unassigned)
      })

    assert {:error, :stale_scope} = CorpusReview.open_scope(attrs, c)

    assert {:error, :connection_unavailable} =
             CorpusReview.open_scope(
               Map.put(scope_attrs(f), "connection_id", Ecto.UUID.generate()),
               c
             )

    {:ok, _} =
      Company.update_project(
        f.project["id"],
        Map.merge(f.project["payload"], %{
          "name" => "Changed project",
          "expected_content_hash" => f.project["content_hash"]
        })
      )

    assert {:error, :stale_scope} = CorpusReview.page(opened["token"], %{"query" => ""}, c)
    assert {:ok, _} = CorpusReview.open_scope(scope_attrs(f), c)
  end

  test "inspection does not assign another captured connection to the project", %{
    fixture: f,
    caller: c
  } do
    {:ok, other} =
      Evidence.connect(%{
        "name" => "Other captured corpus",
        "provider" => "local",
        "directory" => f.connection["directory"]
      })

    source =
      import!(other["id"], "unassigned.md", "Inspection canary unrelated to assigned analysis")

    before = db_projection()

    {:ok, opened} =
      CorpusReview.open_scope(Map.put(scope_attrs(f), "connection_id", other["id"]), c)

    assert {:ok, %{"rows" => [row]}} =
             CorpusReview.page(opened["token"], %{"query" => "canary"}, c)

    assert row["id"] == source["id"]
    assert {:ok, _} = CorpusReview.passage(opened["token"], passage_attrs(source), c)
    assert db_projection() == before

    input =
      Map.put(
        f.input,
        "source_refs",
        [pin(source), pin(hd(f.sources))] |> Enum.sort_by(& &1["source_id"])
      )

    assert {:error, :company_analysis_out_of_scope} = Analysis.analyze(input)
    assert {:ok, project} = Company.list_projects()

    refute source["id"] in Enum.find(project, &(&1["id"] == f.project["id"]))["payload"][
             "source_ids"
           ]
  end

  test "bounded stable metadata pages return actual counts and query-bound cursors", %{
    fixture: f,
    caller: c
  } do
    extra =
      for n <- 1..53,
          do: import!(f.connection["id"], "page-#{n}.md", "Synthetic paging body canary #{n}")

    {:ok, opened} = CorpusReview.open_scope(scope_attrs(f), c)
    assert {:ok, first} = CorpusReview.page(opened["token"], %{"query" => ""}, c)
    assert length(first["rows"]) == 25

    assert first["counts"] == %{
             "captured" => 57,
             "current" => 57,
             "unavailable" => 0,
             "matches" => nil,
             "discovery_total" => nil,
             "semantic_coverage" => "unknown"
           }

    assert {:ok, second} =
             CorpusReview.page(
               opened["token"],
               %{"query" => "", "cursor" => first["next_cursor"]},
               c
             )

    assert length(second["rows"]) == 25

    assert {:ok, third} =
             CorpusReview.page(
               opened["token"],
               %{"query" => "", "cursor" => second["next_cursor"]},
               c
             )

    assert length(third["rows"]) == 7
    assert is_nil(third["next_cursor"])
    ids = Enum.map(first["rows"] ++ second["rows"] ++ third["rows"], & &1["id"])
    assert ids == Enum.sort(Enum.map(f.sources ++ extra, & &1["id"]))

    assert {:error, :invalid_cursor} =
             CorpusReview.page(
               opened["token"],
               %{"query" => "policy", "cursor" => first["next_cursor"]},
               c
             )

    assert {:error, :invalid_cursor} =
             CorpusReview.page(
               opened["token"],
               %{"query" => "", "cursor" => first["next_cursor"] <> "tamper"},
               c
             )

    assert Enum.all?(first["rows"], &(not Map.has_key?(&1["latest_revision"], "body")))
    assert Enum.all?(first["rows"], &is_integer(&1["latest_revision"]["body_bytes"]))
  end

  test "literal search is scope-filtered, bounded and can locate a late UTF-8 hit", %{
    fixture: f,
    caller: c
  } do
    body =
      String.duplicate("Café • irrelevant context\n", 300) <> "late_needle rollback rehearsal"

    source = import!(f.connection["id"], "long.md", body)
    expected = elem(:binary.match(body, "late_needle"), 0)
    {:ok, opened} = CorpusReview.open_scope(scope_attrs(f), c)

    assert {:ok, %{"rows" => [row], "counts" => %{"matches" => 1}}} =
             CorpusReview.page(opened["token"], %{"query" => "late_needle"}, c)

    assert row["match_start_byte"] == expected
    assert expected > 4096

    assert {:ok, passage} =
             CorpusReview.passage(
               opened["token"],
               Map.put(passage_attrs(source), "start_byte", row["match_start_byte"]),
               c
             )

    assert passage["text"] == "late_needle rollback rehearsal"

    assert {:ok, %{"rows" => [], "counts" => %{"matches" => 0}}} =
             CorpusReview.page(opened["token"], %{"query" => "unknown_literal_canary"}, c)

    assert {:ok, %{"rows" => []}} =
             CorpusReview.page(opened["token"], %{"query" => "late_needle OR *"}, c)

    assert {:error, :invalid_query} =
             CorpusReview.page(opened["token"], %{"query" => String.duplicate("x", 257)}, c)

    assert {:error, :invalid_query} =
             CorpusReview.page(opened["token"], %{"query" => "a b c d e f g h i"}, c)

    assert {:error, :invalid_query} = CorpusReview.page(opened["token"], %{"query" => <<255>>}, c)

    {:ok, _} = Evidence.revoke_source(source["id"])

    assert {:ok, %{"rows" => [], "counts" => %{"unavailable" => 1}}} =
             CorpusReview.page(opened["token"], %{"query" => "late_needle"}, c)

    assert {:error, :source_unavailable} =
             CorpusReview.passage(opened["token"], passage_attrs(source), c)
  end

  test "passages are exact <=4096-byte windows with deliberate UTF-8 boundaries", %{
    fixture: f,
    caller: c
  } do
    body = String.duplicate("é🙂界", 1000)
    source = import!(f.connection["id"], "unicode.md", body)
    {:ok, opened} = CorpusReview.open_scope(scope_attrs(f), c)
    assert {:ok, first} = CorpusReview.passage(opened["token"], passage_attrs(source), c)
    assert String.valid?(first["text"])
    assert byte_size(first["text"]) <= 4096
    assert first["text"] == binary_part(body, 0, first["end_byte"])
    assert first["truncated_after"]
    assert first["next_start_byte"] == first["end_byte"]

    assert {:ok, next} =
             CorpusReview.passage(
               opened["token"],
               Map.put(passage_attrs(source), "start_byte", first["next_start_byte"]),
               c
             )

    assert next["text"] ==
             binary_part(body, next["start_byte"], next["end_byte"] - next["start_byte"])

    assert {:error, :invalid_offsets} =
             CorpusReview.passage(
               opened["token"],
               Map.put(passage_attrs(source), "start_byte", 1),
               c
             )

    assert {:error, :invalid_offsets} =
             CorpusReview.passage(
               opened["token"],
               Map.put(passage_attrs(source), "start_byte", byte_size(body) + 1),
               c
             )

    assert {:error, :source_unavailable} =
             CorpusReview.passage(
               opened["token"],
               Map.put(passage_attrs(source), "body_hash", String.duplicate("0", 64)),
               c
             )

    assert {:error, :invalid_input} =
             CorpusReview.passage(
               opened["token"],
               Map.put(passage_attrs(source), "start_byte", "0"),
               c
             )
  end

  test "scope and preview handles bind session, generation, reset and exact source", %{
    fixture: f,
    caller: c
  } do
    {:ok, opened} = CorpusReview.open_scope(scope_attrs(f), c)
    source = hd(f.sources)

    for changed <- [
          Keyword.put(c, :session_fingerprint, Contracts.digest("another session")),
          Keyword.put(c, :view_generation, String.duplicate("b", 32)),
          Keyword.put(c, :reset_token, 1)
        ] do
      assert {:error, :invalid_scope} =
               CorpusReview.passage(opened["token"], passage_attrs(source), changed)
    end

    assert {:error, :invalid_scope} =
             CorpusReview.page(opened["token"] <> "tamper", %{"query" => ""}, c)

    assert {:error, :invalid_scope} = CorpusReview.page("", %{"query" => ""}, c)
    assert {:ok, %{"rows" => rows}} = Evidence.source_page(%{}, c)
    row = Enum.find(rows, &(&1["id"] == source["id"]))
    assert {:ok, _} = Evidence.source_passage(row["passage_token"], passage_attrs(source), c)
    assert {:error, :invalid_scope} = CorpusReview.page(row["passage_token"], %{"query" => ""}, c)

    assert {:error, :stale_scope} =
             CorpusReview.passage(row["passage_token"], passage_attrs(Enum.at(f.sources, 1)), c)
  end

  test "expired signed scope and cursor cannot be replayed", %{fixture: f, caller: c} do
    {:ok, opened} = CorpusReview.open_scope(scope_attrs(f), c)
    endpoint = Application.fetch_env!(:harness_forge, HarnessForgeWeb.Endpoint)
    secret = Keyword.fetch!(endpoint, :secret_key_base)

    {:ok, payload} =
      Phoenix.Token.verify(secret, "company-corpus-review-scope-v1", opened["token"],
        max_age: 600
      )

    expired =
      Phoenix.Token.sign(secret, "company-corpus-review-scope-v1", payload,
        signed_at: System.system_time(:second) - 601
      )

    assert {:error, :invalid_scope} = CorpusReview.page(expired, %{"query" => ""}, c)

    cursor_payload = %{
      "caller" => payload["caller"],
      "binding" => %{},
      "after" => Ecto.UUID.generate()
    }

    expired_cursor =
      Phoenix.Token.sign(secret, "company-corpus-review-cursor-v1", cursor_payload,
        signed_at: System.system_time(:second) - 601
      )

    assert {:error, :invalid_cursor} =
             CorpusReview.page(opened["token"], %{"query" => "", "cursor" => expired_cursor}, c)
  end

  test "recapture invalidates old exact pins and explicit fresh open recovers", %{
    fixture: f,
    caller: c
  } do
    old = hd(f.sources)
    {:ok, opened} = CorpusReview.open_scope(scope_attrs(f), c)
    assert {:ok, _} = CorpusReview.passage(opened["token"], passage_attrs(old), c)

    fresh =
      import!(
        f.connection["id"],
        old["external_id"],
        "Explicitly recaptured public synthetic policy"
      )

    assert {:error, :source_unavailable} =
             CorpusReview.passage(opened["token"], passage_attrs(old), c)

    {:ok, reopened} = CorpusReview.open_scope(scope_attrs(f), c)

    assert {:ok, %{"text" => "Explicitly recaptured public synthetic policy"}} =
             CorpusReview.passage(reopened["token"], passage_attrs(fresh), c)
  end

  test "connector scope changes, connection revocation and pending privacy fence refuse", %{
    fixture: f,
    caller: c
  } do
    {:ok, opened} = CorpusReview.open_scope(scope_attrs(f), c)
    {:ok, connection} = Store.get(Connection, f.connection["id"])
    Repo.update!(Ecto.Changeset.change(connection, config: %{"changed_scope" => true}))
    assert {:error, :stale_scope} = CorpusReview.page(opened["token"], %{"query" => ""}, c)
    {:ok, fresh} = CorpusReview.open_scope(scope_attrs(f), c)
    {:ok, _} = Evidence.revoke_connection(f.connection["id"])

    assert {:error, :connection_unavailable} =
             CorpusReview.page(fresh["token"], %{"query" => ""}, c)

    assert {:error, :connection_unavailable} =
             CorpusReview.passage(fresh["token"], passage_attrs(hd(f.sources)), c)

    now = DateTime.to_iso8601(DateTime.utc_now())

    Repo.query!(
      "INSERT INTO privacy_operations (id, workspace_id, kind, target_id, state, plan, inserted_at, updated_at) VALUES (?, ?, 'source', ?, 'prepared', '{}', ?, ?)",
      [Ecto.UUID.generate(), Store.workspace(), hd(f.sources)["id"], now, now]
    )

    assert {:error, :privacy_operation_incomplete} = CorpusReview.source_page(%{}, c)

    assert {:error, :privacy_operation_incomplete} =
             CorpusReview.choices(%{"kind" => "connection"}, c)

    assert {:error, :privacy_operation_incomplete} = CorpusReview.summary_refs(%{}, c)
  end

  test "metadata summaries keep independent saved-set bounds and unavailable selections", %{
    fixture: f,
    caller: c
  } do
    sources =
      for n <- 1..101, do: import!(f.connection["id"], "saved-#{n}.md", "Saved selection #{n}")

    [off_page | _] = Enum.sort_by(sources, & &1["id"], :desc)
    missing = Ecto.UUID.generate()

    refs = %{
      "profile_ids" => Enum.take(sources, 100) |> Enum.map(& &1["id"]),
      "project_ids" => [off_page["id"], missing],
      "analysis_refs" => f.input["source_refs"],
      "consent_ids" => [off_page["id"]]
    }

    assert {:ok, result} = Evidence.source_summaries(refs, c)
    assert off_page["id"] in Enum.map(result["sources"], & &1["id"])
    assert result["unavailable_ids"] == [missing]
    assert length(result["sources"]) >= 104
    refute Enum.any?(result["sources"], &Map.has_key?(&1["latest_revision"], "body"))

    assert {:error, :invalid_input} =
             CorpusReview.summary_refs(%{"profile_ids" => Enum.map(sources, & &1["id"])}, c)

    assert {:error, :invalid_input} =
             CorpusReview.summary_refs(
               %{"analysis_refs" => List.duplicate(hd(f.input["source_refs"]), 5)},
               c
             )

    {:ok, _} = Evidence.revoke_source(off_page["id"])
    assert {:ok, unavailable} = CorpusReview.summary_refs(%{"project_ids" => [off_page["id"]]}, c)
    assert unavailable == %{"sources" => [], "unavailable_ids" => [off_page["id"]]}
  end

  test "only explicit historical semantics and safe original links enter metadata", %{
    fixture: f,
    caller: c
  } do
    {:ok, source} =
      Evidence.import_markdown(f.connection["id"], %{
        "external_id" => "metadata.md",
        "title" => "Captured historical semantics",
        "body" => "Metadata body canary",
        "source_url" => "javascript:alert(1)",
        "source_updated_at" => "2026-10-02T00:00:00Z",
        "metadata" => %{
          "document_status" => "draft",
          "effective_at" => "2026-10-01T00:00:00Z",
          "event_at" => "not a date",
          "created_at" => "2026-01-01T00:00:00Z",
          "private_key" => "DO_NOT_RETURN",
          "status" => "approved"
        }
      })

    {:ok, %{"sources" => [row]}} =
      CorpusReview.summary_refs(%{"profile_ids" => [source["id"]]}, c)

    revision = row["latest_revision"]

    assert revision["metadata"] == %{
             "document_status" => "draft",
             "effective_at" => "2026-10-01T00:00:00Z"
           }

    assert revision["source_url"] == nil
    assert revision["source_updated_at"] == "2026-10-02T00:00:00Z"
    refute Jason.encode!(row) =~ "DO_NOT_RETURN"
    refute Map.has_key?(revision, "body")
  end

  test "foreign workspace captures never enter metadata, search, or passage", %{
    fixture: f,
    caller: c
  } do
    foreign = Ecto.UUID.generate()

    connection =
      Repo.insert!(%Connection{workspace_id: foreign, provider: "local", name: "Foreign canary"})

    source =
      Repo.insert!(%Source{
        workspace_id: foreign,
        connection_id: connection.id,
        provider: "local",
        external_id: "foreign.md",
        title: "Forbidden canary"
      })

    {:ok, opened} = CorpusReview.open_scope(scope_attrs(f), c)

    assert {:error, :connection_unavailable} =
             CorpusReview.open_scope(Map.put(scope_attrs(f), "connection_id", connection.id), c)

    assert {:ok, %{"rows" => []}} =
             CorpusReview.page(opened["token"], %{"query" => "Forbidden canary"}, c)

    assert {:ok, %{"sources" => [], "unavailable_ids" => [id]}} =
             CorpusReview.summary_refs(%{"profile_ids" => [source.id]}, c)

    assert id == source.id

    assert {:error, :not_found} =
             CorpusReview.passage(
               opened["token"],
               Map.put(passage_attrs(hd(f.sources)), "source_id", source.id),
               c
             )
  end

  test "existing original report retains findings and rejects changed uncited dependencies", %{
    fixture: f,
    caller: c
  } do
    previous = Application.get_env(:harness_forge, :model_test_plug)
    Application.put_env(:harness_forge, :model_test_plug, {Req.Test, __MODULE__})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:harness_forge, :model_test_plug, previous),
        else: Application.delete_env(:harness_forge, :model_test_plug)
    end)

    {:ok, _} = Models.configure(%{"model" => "synthetic:fixture"})

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/api/tags" -> Req.Test.json(conn, %{"models" => [%{"name" => "synthetic:fixture"}]})
        "/api/generate" -> Req.Test.json(conn, CompanyAnalysisFixture.response(f.report))
      end
    end)

    {:ok, %{"claim" => claim}} = Analysis.analyze(f.input)
    {:ok, opened} = CorpusReview.open_scope(scope_attrs(f), c)
    before = db_projection()

    assert {:ok, report} =
             CorpusReview.recommendation(
               opened["token"],
               %{"claim_id" => claim["id"], "revision_hash" => claim["revision_hash"]},
               c
             )

    assert report["report"] == f.report
    assert report["guidance"] == claim["basis"]["guidance"]
    assert length(report["analyzed_sources"]) == 4
    refute report["outside_inspection_connection"]
    assert db_projection() == before

    assert {:error, :stale_revision} =
             CorpusReview.recommendation(
               opened["token"],
               %{"claim_id" => claim["id"], "revision_hash" => String.duplicate("0", 64)},
               c
             )

    uncited = f.uncited_source
    import!(f.connection["id"], uncited["external_id"], "Changed examined but uncited context")

    assert {:error, :stale_company_analysis_context} =
             CorpusReview.recommendation(
               opened["token"],
               %{"claim_id" => claim["id"], "revision_hash" => claim["revision_hash"]},
               c
             )
  end

  test "metadata chooser pages remain bounded and recommendation choices require assigned goal",
       %{fixture: f, caller: c} do
    for n <- 1..27 do
      {:ok, _} =
        Company.create_project(%{
          "name" => "Synthetic project #{n}",
          "repository_ids" => [f.repository["id"]]
        })
    end

    assert {:ok, first} = CorpusReview.choices(%{"kind" => "project"}, c)
    assert length(first["rows"]) == 25

    assert {:ok, %{"rows" => rest, "next_cursor" => nil}} =
             CorpusReview.choices(%{"kind" => "project", "cursor" => first["next_cursor"]}, c)

    assert length(rest) == 3

    assert {:ok, %{"rows" => [%{"id" => goal_id}]}} =
             CorpusReview.choices(%{"kind" => "goal", "project_id" => f.project["id"]}, c)

    assert goal_id == f.goal["id"]

    assert {:error, :invalid_scope} =
             CorpusReview.choices(
               %{
                 "kind" => "recommendation",
                 "project_id" => f.project["id"],
                 "goal_id" => Ecto.UUID.generate()
               },
               c
             )

    assert {:error, :invalid_cursor} =
             CorpusReview.choices(%{"kind" => "connection", "cursor" => first["next_cursor"]}, c)
  end

  test "legacy metadata reads batch connection checks and never select full revision rows", %{
    fixture: f,
    caller: c
  } do
    for n <- 1..30,
        do:
          import!(
            f.connection["id"],
            "bounded-#{n}.md",
            String.duplicate("unrendered synthetic body canary ", 300)
          )

    handler = "corpus-review-query-#{Ecto.UUID.generate()}"

    :ok =
      :telemetry.attach(
        handler,
        [:harness_forge, :repo, :query],
        &__MODULE__.record_query/4,
        self()
      )

    try do
      assert {:ok, result} = CorpusReview.source_page(%{}, c)
      queries = recorded_queries([])
      assert length(result["rows"]) == 25
      # Two privacy reads, three page/count reads, one batch of connections and
      # transaction bookkeeping. No source-count-proportional read path.
      assert length(queries) <= 10
      assert Enum.count(queries, &String.contains?(&1, "FROM \"source_connections\"")) == 1

      refute Enum.any?(
               queries,
               &String.contains?(
                 &1,
                 "SELECT e0.\"id\", e0.\"workspace_id\", e0.\"source_id\", e0.\"body\""
               )
             )

      refute Jason.encode!(result) =~ "unrendered synthetic body canary"
      assert Enum.any?(queries, &String.contains?(&1, "wanted AS MATERIALIZED"))
    after
      :telemetry.detach(handler)
    end
  end

  def record_query(_event, _measurements, metadata, owner),
    do: send(owner, {:corpus_query, metadata.query})

  defp recorded_queries(acc) do
    receive do
      {:corpus_query, query} -> recorded_queries([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp caller do
    [
      authorize: fn -> true end,
      session_fingerprint: Contracts.digest("synthetic operator session"),
      view_generation: String.duplicate("a", 32),
      reset_token: 0
    ]
  end

  defp scope_attrs(f),
    do:
      Map.put(
        Map.take(f.input, ~w(project_id goal_id goal_content_hash)),
        "connection_id",
        f.connection["id"]
      )

  defp passage_attrs(source), do: pin(source) |> Map.put("start_byte", 0)

  defp pin(source),
    do: %{
      "source_id" => source["id"],
      "revision_id" => source["latest_revision"]["id"],
      "body_hash" => source["latest_revision"]["body_hash"]
    }

  defp import!(connection_id, external_id, body) do
    {:ok, source} =
      Evidence.import_markdown(connection_id, %{
        "external_id" => external_id,
        "title" => "Synthetic #{external_id}",
        "body" => body
      })

    source
  end

  defp db_projection do
    for table <-
          ~w(model_requests model_budgets evidence_citations evidence_claims claim_decisions company_profiles company_projects company_plans company_plan_decisions company_assessments audit_events),
        into: %{} do
      result = Repo.query!("SELECT * FROM #{table} ORDER BY id", [])
      {table, result.rows}
    end
  end
end
