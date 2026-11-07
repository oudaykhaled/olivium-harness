defmodule HarnessForge.Company.RetrievalPresentationTest do
  use HarnessForge.DataCase, async: false
  alias HarnessForge.{CompanyAnalysisFixture, Contracts, Evidence, Repo}
  alias HarnessForge.Company.Retrieval
  alias HarnessForge.Evidence.{Connection, Corpora, Passages, Store}

  @pins ~w(passage_id source_id revision_id body_hash start_byte end_byte snippet_hash parent_start_byte parent_end_byte parent_hash)

  setup do
    root =
      Path.join(System.tmp_dir!(), "retrieval-presentation-#{System.unique_integer([:positive])}")

    fixture = CompanyAnalysisFixture.create!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{fixture: fixture}
  end

  test "named excerpts retain exact UTF-8 pins, diagnostics and separate exact context", %{
    fixture: f
  } do
    body = String.duplicate("Café 植物 🌱 orchids <script>public text</script>. ", 180)
    title = "Current display <script>alert('public fixture')</script> & Café"

    source =
      import!(f, "unicode.md", %{
        "title" => title,
        "body" => body,
        "source_url" => "https://example.com/public/policy?view=history",
        "metadata" => %{
          "document_status" => "draft <unapproved>",
          "event_at" => "2026-01-02T12:00:00Z",
          "effective_at" => "2026-02-03T12:00:00Z"
        }
      })

    {result, _input} = run!(f, [source])
    before = model_counts()
    assert {:ok, page} = read(result)
    rows = Enum.filter(page["rows"], &(&1["source_id"] == source["id"]))
    assert rows != []

    for row <- rows do
      assert row["title"] == title
      assert row["source_url"] == "https://example.com/public/policy?view=history"
      assert row["document_status"] == "draft <unapproved>"
      assert row["event_at"] == "2026-01-02T12:00:00Z"
      assert row["effective_at"] == "2026-02-03T12:00:00Z"
      assert {:ok, _, _} = DateTime.from_iso8601(row["captured_at"])
      assert row["revision_id"] == source["latest_revision"]["id"]
      assert row["body_hash"] == Store.hash(body)
      assert String.valid?(row["snippet"])
      assert byte_size(row["snippet"]) <= 2048
      assert row["snippet"] == binary_part(body, row["start_byte"], byte_size(row["snippet"]))
      assert row["end_byte"] - row["start_byte"] == byte_size(row["snippet"])
      assert row["snippet_hash"] == Store.hash(row["snippet"])
      assert row["parent_end_byte"] - row["parent_start_byte"] <= 4096
      assert is_boolean(row["parent_incomplete"])
      refute Map.has_key?(row, "parent_text")
      refute Map.has_key?(row, "body")
      assert row["id"] == row["passage_id"]
      assert is_integer(row["candidate_order"])
      assert Map.has_key?(row, "selected_order")
      assert row["relation"] in ~w(support contrary unknown)
      assert row["reason_code"] == "lexical_provisional"
      assert row["lane"] in row["lane_memberships"]
      assert is_map(row["lane_ranks"])
      assert row["context_readiness"] in ~w(complete incomplete)
      assert row["packing_version"] == "context-diverse-v2"

      assert {:ok, opened} =
               Retrieval.open_passage(result["run_id"], result["digest"], row["id"], caller())

      assert Map.take(opened, @pins) == Map.take(row, @pins)
      assert opened["snippet"] == row["snippet"]
      assert byte_size(opened["parent_text"]) <= 4096
    end

    assert model_counts() == before
  end

  test "missing or unsafe display metadata stays unknown without substituting capture dates", %{
    fixture: f
  } do
    unsafe =
      import!(f, "unsafe-metadata.md", %{
        "title" => String.duplicate("界", 700),
        "source_url" => "https://user:secret@example.com/public",
        "metadata" => %{
          "document_status" => String.duplicate("x", 201),
          "event_at" => "yesterday",
          "effective_at" => 2026
        }
      })

    absent = import!(f, "absent-metadata.md", %{})
    {result, _} = run!(f, [unsafe, absent])
    assert {:ok, page} = read(result)

    for source <- [unsafe, absent] do
      row = Enum.find(page["rows"], &(&1["source_id"] == source["id"]))
      assert row
      assert is_nil(row["source_url"])
      assert is_nil(row["document_status"])
      assert is_nil(row["event_at"])
      assert is_nil(row["effective_at"])
      assert is_binary(row["captured_at"])
    end

    assert is_nil(Enum.find(page["rows"], &(&1["source_id"] == unsafe["id"]))["title"])
  end

  test "pages check only 25 bounded windows and never hydrate the sentinel", %{fixture: f} do
    extras =
      for n <- 1..30 do
        text = if n <= 15, do: "orchids seasonal observations", else: "changed exception notes"
        import!(f, "page-#{n}.md", %{"body" => "Public #{text} #{n}."})
      end

    {result, input} = run!(f, extras)

    ids =
      Repo.query!("SELECT passage_id FROM retrieval_items WHERE run_id=? ORDER BY passage_id", [
        result["run_id"]
      ]).rows
      |> List.flatten()

    assert length(ids) > 25
    assert {:ok, initial} = read(result)
    assert {:ok, following} = read(result, %{"cursor" => initial["next_cursor"]})
    assert Enum.map(initial["rows"] ++ following["rows"], & &1["id"]) == ids
    assert is_nil(following["next_cursor"])

    # Deny the 26th candidate without changing the run generation. Its checked
    # window must fail when displayed, but cannot invalidate the preceding page.
    deny_passage_set(Enum.at(ids, 25))
    owner = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:harness_forge, :repo, :query],
        fn _, _, metadata, _ ->
          if String.contains?(metadata.query, "AS parent_window"),
            do: send(owner, {:presentation_window, metadata.result})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    before = model_counts()
    assert {:ok, first} = read(result)
    assert Enum.map(first["rows"], & &1["id"]) == Enum.take(ids, 25)
    assert is_binary(first["next_cursor"])
    windows = window_results()
    assert length(windows) == 25

    sizes =
      for {:ok, query} <- windows do
        refute "body" in query.columns
        index = Enum.find_index(query.columns, &(&1 == "parent_window"))
        [row] = query.rows
        bytes = byte_size(Enum.at(row, index))
        assert bytes <= 4096
        bytes
      end

    assert Enum.sum(sizes) <= 102_400
    assert model_counts() == before

    assert {:error, :invalid_passage} =
             read(result, %{"cursor" => first["next_cursor"]})

    # An invalid final displayed row fails the whole first page after earlier
    # valid rows have already been checked; no partial page escapes.
    deny_passage_set(Enum.at(ids, 24))
    assert {:error, :invalid_passage} = read(result)

    assert {:error, :invalid_cursor} = read(result, %{"cursor" => "forged"})
    changed_caller = Keyword.put(caller(), :view_generation, String.duplicate("f", 32))

    assert {:error, :invalid_cursor} =
             Retrieval.read_run(
               result["run_id"],
               result["digest"],
               %{"cursor" => first["next_cursor"]},
               changed_caller
             )

    assert {:ok, other} = Retrieval.retrieve(input, caller())
    assert {:error, :invalid_cursor} = read(other, %{"cursor" => first["next_cursor"]})
  end

  for invalidation <- [:revision, :source, :connection] do
    @tag invalidation: invalidation
    test "changed or revoked #{invalidation} refuses previously displayed evidence", %{
      fixture: f,
      invalidation: invalidation
    } do
      {result, _} = run!(f)
      assert {:ok, page} = read(result)
      row = hd(page["rows"])
      source = Enum.find(f.sources, &(&1["id"] == row["source_id"]))

      case invalidation do
        :revision -> import!(f, source["external_id"], %{"body" => "Changed public revision."})
        :source -> assert {:ok, _} = Evidence.revoke_source(source["id"])
        :connection -> assert {:ok, _} = Evidence.revoke_connection(f.connection["id"])
      end

      assert {:error, :stale_generation} = read(result)

      assert {:error, :stale_generation} =
               Retrieval.open_passage(result["run_id"], result["digest"], row["id"], caller())
    end
  end

  test "display rechecks corpus membership and current connector document scope", %{fixture: f} do
    {result, _} = run!(f)
    assert {:ok, page} = read(result)
    row = List.last(page["rows"])

    Repo.query!("UPDATE corpus_members SET status='removed' WHERE source_id=?", [
      row["source_id"]
    ])

    assert {:error, :invalid_scope} = read(result)
    Repo.query!("UPDATE corpus_members SET status='active' WHERE source_id=?", [row["source_id"]])

    {:ok, connection} = Store.get(Connection, f.connection["id"])

    connection
    |> Ecto.Changeset.change(provider: "github", config: %{"repository" => "other/public"})
    |> Repo.update!()

    assert {:error, :invalid_passage} = read(result)
  end

  test "session denial and an incomplete privacy operation prevent list serving", %{fixture: f} do
    {result, _} = run!(f)
    denied = Keyword.put(caller(), :authorize, fn -> false end)

    assert {:error, :operator_session_revoked} =
             Retrieval.read_run(result["run_id"], result["digest"], %{}, denied)

    Repo.query!(
      "INSERT INTO privacy_operations(id,workspace_id,kind,target_id,state,plan,inserted_at,updated_at) VALUES(?,?,?,?,?,?,?,?)",
      [
        Ecto.UUID.generate(),
        Store.workspace(),
        "source",
        hd(f.sources)["id"],
        "prepared",
        "{}",
        Corpora.now(),
        Corpora.now()
      ]
    )

    assert {:error, :privacy_operation_incomplete} = read(result)
  end

  defp import!(f, external_id, attrs) do
    {:ok, source} =
      Evidence.import_markdown(
        f.connection["id"],
        Map.merge(
          %{"external_id" => external_id, "title" => external_id, "body" => "Public orchids."},
          attrs
        )
      )

    source
  end

  defp run!(f, extras \\ []) do
    {:ok, corpus} = Corpora.create(%{"name" => "Public presentation mechanics"}, caller())
    sources = f.sources ++ extras

    changes =
      Enum.map(
        sources,
        &%{
          "source_id" => &1["id"],
          "revision_id" => &1["latest_revision"]["id"],
          "action" => "include"
        }
      )

    {:ok, _} = Corpora.apply_members(corpus["id"], 0, changes, caller())

    for source <- sources,
        do: assert({:ok, _} = Passages.index_revision(source["latest_revision"]["id"]))

    Repo.query!(
      "INSERT INTO company_corpus_bindings(workspace_id,project_id,profile_id,corpus_id,inserted_at,updated_at) VALUES(?,?,?,?,?,?)",
      [
        Store.workspace(),
        f.project["id"],
        f.profile["id"],
        corpus["id"],
        Corpora.now(),
        Corpora.now()
      ]
    )

    {:ok, current} = Corpora.get(corpus["id"])

    input = %{
      "corpus_id" => corpus["id"],
      "project_id" => f.project["id"],
      "goal_id" => f.goal["id"],
      "goal_hash" => f.input["goal_content_hash"],
      "expected_generation" => current.semantic_generation,
      "question" => "orchids",
      "mode" => "fts"
    }

    assert {:ok, result} = Retrieval.retrieve(input, caller())
    {result, input}
  end

  defp deny_passage_set(id) do
    Repo.query!(
      "UPDATE passage_sets SET state='denied' WHERE id=(SELECT passage_set_id FROM passages WHERE id=?)",
      [id]
    )
  end

  defp model_counts do
    for table <- ~w(model_requests model_budgets stage_attempts), into: %{} do
      {table, Repo.query!("SELECT count(*) FROM #{table}", []).rows}
    end
  end

  defp window_results(acc \\ []) do
    receive do
      {:presentation_window, result} -> window_results([result | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp read(result, attrs \\ %{}),
    do: Retrieval.read_run(result["run_id"], result["digest"], attrs, caller())

  defp caller,
    do: [
      authorize: fn -> true end,
      session_fingerprint: Contracts.sha256("presentation caller"),
      view_generation: String.duplicate("e", 32),
      reset_token: 0
    ]
end
