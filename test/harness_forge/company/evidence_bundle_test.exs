defmodule HarnessForge.Company.EvidenceBundleTest do
  use HarnessForge.DataCase, async: false
  alias HarnessForge.{CompanyAnalysisFixture, Contracts, Evidence, Repo}
  alias HarnessForge.Company.{EvidenceBundle, Retrieval}
  alias HarnessForge.Evidence.{Corpora, Passages, Store}

  @identity ~w(passage_id source_id revision_id body_hash start_byte end_byte snippet_hash parent_start_byte parent_end_byte parent_hash)

  setup do
    root = Path.join(System.tmp_dir!(), "evidence-bundle-#{System.unique_integer([:positive])}")
    f = CompanyAnalysisFixture.create!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, corpus} = Corpora.create(%{"name" => "Public contract mechanics"}, caller())
    include!(corpus["id"], 0, f.sources)
    now = Corpora.now()

    Repo.query!(
      "INSERT INTO company_corpus_bindings(workspace_id,project_id,profile_id,corpus_id,inserted_at,updated_at) VALUES(?,?,?,?,?,?)",
      [Store.workspace(), f.project["id"], f.profile["id"], corpus["id"], now, now]
    )

    {:ok, current} = Corpora.get(corpus["id"])

    input = %{
      "corpus_id" => corpus["id"],
      "project_id" => f.project["id"],
      "goal_id" => f.goal["id"],
      "goal_hash" => f.input["goal_content_hash"],
      "expected_generation" => current.semantic_generation,
      "question" => "Which release records require review?"
    }

    %{fixture: f, input: input}
  end

  test "equivalent explicit defaults preserve request identity without Unicode normalization", %{
    input: input
  } do
    assert {:ok, normalized} = EvidenceBundle.normalize_request(input)

    explicit =
      Map.merge(input, %{
        "version" => "RetrievalRequest.v1",
        "mode" => "fts",
        "time_mode" => "current",
        "purpose" => "inspection"
      })

    assert {:ok, ^normalized} = EvidenceBundle.normalize_request(explicit)
    assert normalized["question"] == input["question"]

    assert {:ok, different} =
             EvidenceBundle.normalize_request(Map.put(input, "question", "Café release review?"))

    refute Contracts.digest(normalized) == Contracts.digest(different)
  end

  test "forged authority and unsupported contracts reject before FTS or writes", %{input: input} do
    watch_queries!()
    before = protected_counts()

    for {key, value} <- [
          {"principal", %{}},
          {"scope", []},
          {"acl", true},
          {"authorization_generation", 0},
          {"semantic_generation", 0},
          {"index_generation", 1},
          {"snapshot", "current"},
          {"materialization", Ecto.UUID.generate()},
          {"history_handle", "unissued"},
          {"as_of", "2026-01-01T00:00:00Z"},
          {"purpose", "inference"},
          {"time_mode", "historical"},
          {"mode", "graphiti_hybrid"},
          {"version", "future"},
          {"question", " "},
          {"question", String.duplicate("x", 257)},
          {"declaration_ref", nil}
        ] do
      assert {:error, _} = Retrieval.retrieve_evidence(Map.put(input, key, value), caller())
    end

    for invalid <- [nil, [], %{question: "public"}, Map.put(input, "purpose", nil)] do
      assert {:error, _} = Retrieval.retrieve_evidence(invalid, caller())
    end

    assert protected_counts() == before
    refute_received :fts_search
  end

  test "empty and foreign resolved scope and machine-shaped caller fail before search", %{
    input: input
  } do
    {:ok, empty} = Corpora.create(%{"name" => "Empty public scope"}, caller())
    watch_queries!()
    before = protected_counts()

    assert {:error, _} =
             Retrieval.retrieve_evidence(Map.put(input, "corpus_id", empty["id"]), caller())

    assert {:error, _} =
             Retrieval.retrieve_evidence(
               Map.put(input, "corpus_id", Ecto.UUID.generate()),
               caller()
             )

    assert {:error, _} =
             Retrieval.retrieve_evidence(input, %{machine_token: "public-invalid-shape"})

    assert {:error, :operator_session_revoked} =
             Retrieval.retrieve_evidence(
               input,
               Keyword.put(caller(), :authorize, fn -> false end)
             )

    assert protected_counts() == before
    refute_received :fts_search
  end

  test "one immutable snapshot has identical bundle and exact citation identities across adapter fixtures",
       %{input: input} do
    before = protected_counts()
    assert {:ok, result} = Retrieval.retrieve_evidence(input, caller())
    bundle = result["evidence_bundle"]
    assert bundle["version"] == "EvidenceBundle.v1"
    assert bundle["snapshot_digest"] == result["digest"]
    assert {:ok, normalized} = EvidenceBundle.normalize_request(input)
    assert bundle["request_digest"] == Contracts.digest(normalized)
    assert bundle["status"] == "partial"
    refute bundle["analysis_ready"]

    # These named fixture consumers share genuine operator authority. They are
    # not MCP machine authentication or transport qualification.
    for _adapter <- [:web, :internal, :future_mcp_contract_fixture] do
      assert {:ok, page} =
               Retrieval.read_evidence(result["run_id"], result["digest"], %{}, caller())

      assert page["evidence_bundle"] == bundle
      assert page["rows"] != []
      refute Map.has_key?(bundle, "rows")
      refute Map.has_key?(bundle, "next_cursor")
    end

    assert bundle["bundle_digest"] ==
             Contracts.digest(Map.drop(bundle, ["bundle_digest", "legacy"]))

    for citation <- bundle["citations"] do
      core =
        Map.merge(Map.take(citation, @identity), %{
          "version" => "EvidenceCitation.v1",
          "workspace_id" => Store.workspace()
        })

      assert citation["citation_digest"] == Contracts.digest(core)
    end

    assert result["state"] == "abstained"

    assert {:error, :capture_incomplete} =
             Retrieval.resolve_for_analysis(result["run_id"], result["digest"], caller())

    after_counts = protected_counts()
    assert after_counts["retrieval_runs"] == before["retrieval_runs"] + 1
    assert Map.drop(after_counts, ["retrieval_runs"]) == Map.drop(before, ["retrieval_runs"])
  end

  test "new binding is exactly 180 canonical bytes and legacy envelopes stay unchanged", %{
    input: input
  } do
    assert {:ok, old} = Retrieval.retrieve(Map.put(input, "mode", "fts"), caller())
    before = stored(old)
    assert before.envelope["version"] == 2
    refute Map.has_key?(before.envelope, "evidence")

    assert {:error, :legacy_contract_unavailable} =
             Retrieval.read_evidence(old["run_id"], old["digest"], %{}, caller())

    assert {:ok, _} = Retrieval.read_run(old["run_id"], old["digest"], %{}, caller())
    assert {:ok, new} = Retrieval.retrieve_evidence(input, caller())
    current = stored(new)
    assert current.envelope["version"] == 3
    base = current.envelope |> Map.delete("evidence") |> Map.put("version", 2)

    assert byte_size(Contracts.canonical_json(current.envelope)) -
             byte_size(Contracts.canonical_json(base)) == 180

    assert byte_size(Contracts.canonical_json(current.envelope)) <= 16384

    assert Contracts.digest(%{"envelope" => current.envelope, "coverage" => current.coverage}) ==
             new["digest"]

    assert {:ok, _} = Retrieval.read_run(new["run_id"], new["digest"], %{}, caller())
    assert {:ok, _} = Retrieval.read_summary(new["run_id"], new["digest"], caller())
    assert stored(old) == before
  end

  test "summary does not hydrate text and history or index versions never become authority", %{
    input: input
  } do
    {:ok, result} = Retrieval.retrieve_evidence(input, caller())
    watch_queries!()

    assert {:ok, summary} =
             Retrieval.read_evidence_summary(result["run_id"], result["digest"], caller())

    bundle = summary["evidence_bundle"]
    assert bundle["history"]["status"] == "unknown"
    assert is_nil(bundle["history"]["acquisition_by_kind"])
    assert is_nil(bundle["history"]["exact_version_basis"])
    assert is_nil(bundle["history"]["unavailable_ranges"])
    assert bundle["history"]["historical_eligibility"] == "unavailable"
    assert is_nil(bundle["generations"]["index"])
    assert is_nil(bundle["generations"]["purpose_policy"])
    assert bundle["positive_purpose_policy"] == "unknown"
    assert bundle["index_versions"] == stored(result).envelope["versions"]
    refute Jason.encode!(bundle) =~ "Café release notes"
    refute_received :parent_window
  end

  test "current pages and opens preserve exact multibyte slices and reject invalid current evidence",
       %{fixture: f, input: input} do
    {:ok, result} = Retrieval.retrieve_evidence(input, caller())
    {:ok, page} = Retrieval.read_evidence(result["run_id"], result["digest"], %{}, caller())
    policy = Enum.find(f.sources, &(&1["external_id"] == "policy.md"))
    row = Enum.find(page["rows"], &(&1["source_id"] == policy["id"]))
    assert row

    assert {:ok, opened} =
             Retrieval.open_evidence_passage(
               result["run_id"],
               result["digest"],
               row["passage_id"],
               caller()
             )

    body = policy["latest_revision"]["body"]
    assert String.valid?(opened["snippet"])

    assert opened["snippet"] ==
             binary_part(body, row["start_byte"], row["end_byte"] - row["start_byte"])

    assert Map.take(opened, @identity) == Map.take(row, @identity)
    assert opened["bundle_digest"] == result["evidence_bundle"]["bundle_digest"]

    expected =
      Enum.find(result["evidence_bundle"]["citations"], &(&1["passage_id"] == row["passage_id"]))

    assert opened["citation_digest"] == expected["citation_digest"]
    assert byte_size(opened["parent_text"]) <= 4096

    Repo.query!(
      "UPDATE passage_sets SET state='denied' WHERE id=(SELECT passage_set_id FROM passages WHERE id=?)",
      [row["passage_id"]]
    )

    assert {:error, :invalid_passage} =
             Retrieval.open_evidence_passage(
               result["run_id"],
               result["digest"],
               row["passage_id"],
               caller()
             )

    assert {:error, :invalid_passage} =
             Retrieval.read_evidence(result["run_id"], result["digest"], %{}, caller())
  end

  test "live caller binding and final publication authorization cannot be bypassed", %{
    input: input
  } do
    {:ok, result} = Retrieval.retrieve_evidence(input, caller())

    for {key, value} <- [
          session_fingerprint: Contracts.sha256("different operator"),
          view_generation: String.duplicate("c", 32),
          reset_token: 1
        ] do
      changed = Keyword.put(caller(), key, value)

      assert {:error, _} =
               Retrieval.read_evidence_summary(result["run_id"], result["digest"], changed)

      assert {:error, _} =
               Retrieval.read_evidence(result["run_id"], result["digest"], %{}, changed)

      passage = hd(result["evidence_bundle"]["citations"])["passage_id"]

      assert {:error, _} =
               Retrieval.open_evidence_passage(
                 result["run_id"],
                 result["digest"],
                 passage,
                 changed
               )

      assert {:error, _} =
               Retrieval.resolve_for_analysis(result["run_id"], result["digest"], changed)
    end

    {:ok, flag} = Agent.start_link(fn -> true end)
    on_exit(fn -> if Process.alive?(flag), do: Agent.stop(flag) end)
    owner = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:harness_forge, :repo, :query],
        fn _, _, metadata, _ ->
          if String.contains?(metadata.query, " MATCH "),
            do: Agent.update(flag, fn _ -> false end)

          if String.contains?(metadata.query, " MATCH "), do: send(owner, :observed_public_search)
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    before = protected_counts()
    revoked = Keyword.put(caller(), :authorize, fn -> Agent.get(flag, & &1) end)
    assert {:error, :operator_session_revoked} = Retrieval.retrieve_evidence(input, revoked)
    assert_received :observed_public_search
    assert protected_counts() == before
  end

  test "current source revocation denies old bundle pages and opens", %{fixture: f, input: input} do
    {:ok, result} = Retrieval.retrieve_evidence(input, caller())
    passage = hd(result["evidence_bundle"]["citations"])["passage_id"]
    assert {:ok, _} = Evidence.revoke_source(hd(f.sources)["id"])

    assert {:error, _} =
             Retrieval.read_evidence_summary(result["run_id"], result["digest"], caller())

    assert {:error, _} =
             Retrieval.read_evidence(result["run_id"], result["digest"], %{}, caller())

    assert {:error, _} =
             Retrieval.open_evidence_passage(
               result["run_id"],
               result["digest"],
               passage,
               caller()
             )
  end

  test "a restored v3 digest cannot substitute citation hashes or byte spans", %{input: input} do
    {:ok, result} = Retrieval.retrieve_evidence(input, caller())
    run = stored(result)
    [first | rest] = run.envelope["passages"]

    for changed <- [
          Map.put(first, "snippet_hash", String.duplicate("0", 64)),
          Map.put(first, "body_hash", String.duplicate("0", 64)),
          Map.put(first, "start_byte", first["start_byte"] + 1),
          Map.put(first, "parent_hash", String.duplicate("0", 64))
        ] do
      envelope = Map.put(run.envelope, "passages", [changed | rest])
      restored = restore!(run, envelope)

      assert {:error, :invalid_passage} =
               Retrieval.read_evidence(restored.id, restored.digest, %{}, caller())

      assert {:error, :invalid_passage} =
               Retrieval.open_evidence_passage(
                 restored.id,
                 restored.digest,
                 first["passage_id"],
                 caller()
               )
    end
  end

  test "malformed stored v3 binding is never reinterpreted as an unbound legacy run", %{
    input: input
  } do
    {:ok, result} = Retrieval.retrieve_evidence(input, caller())
    run = stored(result)

    for binding <- [
          nil,
          %{},
          %{"request_digest" => "bad", "caller_digest" => String.duplicate("0", 64)},
          Map.put(run.envelope["evidence"], "purpose", "inference")
        ] do
      restored = restore!(run, Map.put(run.envelope, "evidence", binding))
      assert {:error, _} = Retrieval.read_evidence_summary(restored.id, restored.digest, caller())
      assert {:error, _} = Retrieval.read_evidence(restored.id, restored.digest, %{}, caller())
      assert {:error, _} = Retrieval.resolve_for_analysis(restored.id, restored.digest, caller())
    end
  end

  test "real pages bind cursor to snapshot and principal without legacy fallback", %{
    fixture: f,
    input: input
  } do
    extras =
      for n <- 1..30 do
        text = if n <= 15, do: "orchids seasonal observations", else: "changed exception notes"

        {:ok, s} =
          Evidence.import_markdown(f.connection["id"], %{
            "external_id" => "bundle-page-#{n}.md",
            "title" => "Public page #{n}",
            "body" => "Public #{text} #{n}."
          })

        s
      end

    {:ok, c} = Corpora.get(input["corpus_id"])
    include!(c.id, c.semantic_generation, extras)
    {:ok, c} = Corpora.get(c.id)

    input =
      Map.merge(input, %{"expected_generation" => c.semantic_generation, "question" => "orchids"})

    {:ok, result} = Retrieval.retrieve_evidence(input, caller())

    assert {:ok, first} =
             Retrieval.read_evidence(result["run_id"], result["digest"], %{}, caller())

    assert length(first["rows"]) == 25
    assert is_binary(first["next_cursor"])

    assert {:ok, following} =
             Retrieval.read_evidence(
               result["run_id"],
               result["digest"],
               %{"cursor" => first["next_cursor"]},
               caller()
             )

    refute Enum.any?(following["rows"], fn row ->
             Enum.any?(first["rows"], &(&1["id"] == row["id"]))
           end)

    assert first["evidence_bundle"] == following["evidence_bundle"]
    {:ok, other} = Retrieval.retrieve_evidence(Map.put(input, "question", "changed"), caller())

    assert {:error, :invalid_cursor} =
             Retrieval.read_evidence(
               other["run_id"],
               other["digest"],
               %{"cursor" => first["next_cursor"]},
               caller()
             )

    assert {:ok, legacy} = Retrieval.read_run(result["run_id"], result["digest"], %{}, caller())

    assert {:error, :invalid_cursor} =
             Retrieval.read_evidence(
               result["run_id"],
               result["digest"],
               %{"cursor" => legacy["next_cursor"]},
               caller()
             )

    for attrs <- [
          %{"cursor" => "forged"},
          %{"cursor" => first["next_cursor"], "purpose" => "inference"},
          %{"snapshot_digest" => other["digest"]}
        ] do
      assert {:error, _} =
               Retrieval.read_evidence(result["run_id"], result["digest"], attrs, caller())
    end
  end

  test "partial and abstained projections do not become ready" do
    assert EvidenceBundle.status("ready", 1) == "ready"
    assert EvidenceBundle.status("abstained", 1) == "partial"
    assert EvidenceBundle.status("abstained", 0) == "abstained"
  end

  defp include!(id, generation, sources) do
    changes =
      Enum.map(
        sources,
        &%{
          "source_id" => &1["id"],
          "revision_id" => &1["latest_revision"]["id"],
          "action" => "include"
        }
      )

    assert {:ok, _} = Corpora.apply_members(id, generation, changes, caller())

    for source <- sources,
        do: assert({:ok, _} = Passages.index_revision(source["latest_revision"]["id"]))
  end

  defp stored(result), do: Repo.get!(HarnessForge.Company.RetrievalRun, result["run_id"])

  defp restore!(run, envelope) do
    attrs = run |> Map.from_struct() |> Map.drop([:__meta__, :id, :digest, :completed_at])

    staged =
      Repo.insert!(
        struct(
          HarnessForge.Company.RetrievalRun,
          Map.merge(attrs, %{id: Ecto.UUID.generate(), state: "preparing", envelope: envelope})
        )
      )

    items =
      Repo.all(from item in HarnessForge.Company.RetrievalItem, where: item.run_id == ^run.id)

    for item <- items do
      copied = item |> Map.from_struct() |> Map.drop([:__meta__]) |> Map.put(:run_id, staged.id)
      Repo.insert!(struct(HarnessForge.Company.RetrievalItem, copied))
    end

    digest = Contracts.digest(%{"envelope" => envelope, "coverage" => run.coverage})

    staged
    |> Ecto.Changeset.change(state: run.state, digest: digest, completed_at: Store.now())
    |> Repo.update!()
  end

  defp protected_counts do
    for table <- ~w(retrieval_runs model_requests model_budgets stage_attempts), into: %{} do
      {table, Repo.query!("SELECT count(*) FROM #{table}", []).rows |> hd() |> hd()}
    end
  end

  defp watch_queries! do
    owner = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:harness_forge, :repo, :query],
        fn _, _, metadata, _ ->
          if String.contains?(metadata.query, " MATCH "), do: send(owner, :fts_search)
          if String.contains?(metadata.query, "AS parent_window"), do: send(owner, :parent_window)
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp caller,
    do: [
      authorize: fn -> true end,
      session_fingerprint: Contracts.sha256("public bundle operator"),
      view_generation: String.duplicate("b", 32),
      reset_token: 0
    ]
end
