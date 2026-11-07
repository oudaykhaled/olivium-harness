defmodule HarnessForge.RevisionUseHoldsTest do
  use HarnessForge.DataCase, async: false

  alias HarnessForge.{Contracts, Evidence, Repo, Workspaces}
  alias HarnessForge.Evidence.{Corpora, RevisionUseHolds, Store}

  @purposes ~w(inspection retrieval analysis compile)

  setup do
    directory = Path.join(System.tmp_dir!(), "revision-holds-#{Ecto.UUID.generate()}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    connection = connect(directory, "Synthetic public records")
    source = import(connection, "record.md", "Synthetic hold canary: plants need clean water.")
    %{directory: directory, connection: connection, source: source, caller: caller()}
  end

  test "one atomic restriction denies all purposes immediately without changing or erasing bytes",
       c do
    corpus = corpus([c.source], c.caller)
    before = generations([corpus["id"]])
    revision = c.source["latest_revision"]

    assert {:ok, receipt} = Evidence.restrict_revision(request(c.source), c.caller)

    assert Map.keys(receipt) |> Enum.sort() ==
             Enum.sort(
               ~w(version event_id source_id revision_id body_hash policy_generation denied_purposes cleanup_state cleanup_version)
             )

    assert receipt["version"] === 1
    assert receipt["policy_generation"] === 1
    assert receipt["cleanup_state"] == "pending"
    assert receipt["cleanup_version"] === 0
    assert receipt["denied_purposes"] == @purposes
    assert receipt["source_id"] == c.source["id"]
    assert receipt["revision_id"] == revision["id"]
    assert receipt["body_hash"] == revision["body_hash"]

    for purpose <- @purposes do
      assert {:error, :revision_use_denied} = use_revision(c.source, purpose)
    end

    assert {:error, :revision_use_denied} = RevisionUseHolds.assert_source_unheld(c.source["id"])
    assert {:error, :revision_use_denied} = RevisionUseHolds.assert_corpus_unheld(corpus["id"])
    assert {:error, _} = Corpora.assert_current(corpus["id"], 1, 0)
    assert generations([corpus["id"]]) == before

    assert [[revision["body"], revision["body_hash"]]] ==
             Repo.query!("SELECT body,body_hash FROM evidence_revisions WHERE id=?", [
               revision["id"]
             ]).rows

    assert hold_counts() == {1, 1}

    assert [[Workspaces.operator()]] ==
             Repo.query!("SELECT actor FROM revision_use_holds WHERE id=?", [receipt["event_id"]]).rows

    refute Jason.encode!(receipt) =~ revision["body"]

    for key <- ~w(body metadata permission retention grant availability historical_eligibility),
        do: refute(Map.has_key?(receipt, key))
  end

  test "the request is strictly string-keyed, versioned, typed, and deny-only", c do
    attrs = request(c.source)

    invalid = [
      nil,
      [],
      Map.put(attrs, :version, 1),
      Map.delete(attrs, "command_id"),
      Map.put(attrs, "workspace_id", Store.workspace()),
      Map.put(attrs, "actor", "claimed-operator"),
      Map.put(attrs, "connection_id", c.connection["id"]),
      Map.put(attrs, "denied_purposes", ["retrieval"]),
      Map.put(attrs, "allowed_purposes", @purposes),
      Map.put(attrs, "cleanup_state", "completed"),
      Map.put(attrs, "version", "1"),
      Map.put(attrs, "version", 1.0),
      Map.put(attrs, "version", 2),
      Map.put(attrs, "expected_generation", "0"),
      Map.put(attrs, "expected_generation", 0.0),
      Map.put(attrs, "expected_generation", -1),
      Map.put(attrs, "expected_generation", 1),
      Map.put(attrs, "reason_code", "restore"),
      Map.put(attrs, "reason_code", :operator_restriction),
      Map.put(attrs, "source_id", <<0::128>>),
      Map.put(attrs, "revision_id", "not-a-uuid"),
      Map.put(attrs, "command_id", 7),
      Map.put(attrs, "body_hash", String.upcase(attrs["body_hash"])),
      Map.put(attrs, "body_hash", String.duplicate("z", 64))
    ]

    for bad <- invalid,
        do: assert({:error, :invalid_input} = RevisionUseHolds.restrict(bad, c.caller))

    assert hold_counts() == {0, 0}
    assert :ok = use_revision(c.source, "retrieval")
  end

  test "stale, mismatched, missing, and foreign exact references cannot create a hold", c do
    other = import(c.connection, "other.md", "A distinct synthetic source.")
    attrs = request(c.source)

    assert {:error, :not_found} =
             RevisionUseHolds.restrict(
               Map.put(attrs, "revision_id", other["latest_revision"]["id"]),
               c.caller
             )

    assert {:error, :not_found} =
             RevisionUseHolds.restrict(
               Map.put(attrs, "body_hash", Contracts.sha256("wrong bytes")),
               c.caller
             )

    assert {:error, :not_found} =
             RevisionUseHolds.restrict(
               Map.put(attrs, "source_id", Ecto.UUID.generate()),
               c.caller
             )

    _current = import(c.connection, "record.md", "A newer synthetic revision.")
    assert {:error, :stale_revision} = RevisionUseHolds.restrict(attrs, c.caller)

    in_workspace(Ecto.UUID.generate(), fn ->
      assert {:error, :not_found} = RevisionUseHolds.restrict(attrs, c.caller)
    end)

    assert hold_counts() == {0, 0}
  end

  test "authorization is mandatory on create, replay, status, and resume", c do
    attrs = request(c.source)
    revoked = Keyword.put(c.caller, :authorize, fn -> false end)
    assert {:error, :operator_session_revoked} = RevisionUseHolds.restrict(attrs, revoked)

    assert {:error, :invalid_input} =
             RevisionUseHolds.restrict(attrs, Keyword.put(c.caller, :policy, :allow))

    assert hold_counts() == {0, 0}
    assert {:ok, held} = RevisionUseHolds.restrict(attrs, c.caller)

    assert {:error, :operator_session_revoked} = RevisionUseHolds.restrict(attrs, revoked)

    assert {:error, :operator_session_revoked} =
             RevisionUseHolds.status(held["event_id"], revoked)

    assert {:error, :operator_session_revoked} =
             RevisionUseHolds.resume(held["event_id"], 0, revoked)

    assert {:ok, ^held} = RevisionUseHolds.status(held["event_id"], c.caller)
  end

  test "authorization changing at the write fence or before commit rolls back every row", c do
    for fail_at <- [2, 3] do
      Process.put(:hold_authorization_checks, 0)

      changing =
        Keyword.put(c.caller, :authorize, fn ->
          count = Process.get(:hold_authorization_checks, 0) + 1
          Process.put(:hold_authorization_checks, count)
          count < fail_at
        end)

      assert {:error, :operator_session_revoked} =
               RevisionUseHolds.restrict(request(c.source), changing)

      assert hold_counts() == {0, 0}
      assert :ok = use_revision(c.source, "analysis")
    end
  end

  test "same command and canonical server identity replays across fresh session pins", c do
    attrs = request(c.source)
    assert {:ok, original} = RevisionUseHolds.restrict(attrs, c.caller)
    fresh = caller("a refreshed local operator session")
    assert {:ok, ^original} = RevisionUseHolds.restrict(attrs, fresh)
    other = import(c.connection, "other.md", "An independent synthetic revision.")
    conflict = Map.put(request(other), "command_id", attrs["command_id"])
    assert {:error, :command_conflict} = RevisionUseHolds.restrict(conflict, fresh)
    assert {:error, :stale_generation} = RevisionUseHolds.restrict(request(c.source), fresh)
    assert hold_counts() == {1, 1}

    assert {:ok, complete} = RevisionUseHolds.resume(original["event_id"], 0, fresh)
    assert complete["cleanup_state"] == "completed"
    assert complete["cleanup_version"] == 1
    assert {:ok, ^complete} = RevisionUseHolds.restrict(attrs, fresh)
    assert {:ok, ^complete} = Evidence.revision_restriction_status(original["event_id"], fresh)
  end

  test "unknown and foreign event IDs reveal no restriction receipt", c do
    assert {:ok, held} = RevisionUseHolds.restrict(request(c.source), c.caller)
    missing = Ecto.UUID.generate()
    assert {:error, :not_found} = RevisionUseHolds.status(missing, c.caller)
    assert {:error, :not_found} = RevisionUseHolds.resume(missing, 0, c.caller)

    in_workspace(Ecto.UUID.generate(), fn ->
      assert {:error, :not_found} = RevisionUseHolds.status(held["event_id"], c.caller)
      assert {:error, :not_found} = RevisionUseHolds.resume(held["event_id"], 0, c.caller)
    end)

    assert {:ok, ^held} = RevisionUseHolds.status(held["event_id"], c.caller)
  end

  test "identical bytes in another connection or workspace keep independent existing authority",
       c do
    other_connection = connect(c.directory, "Independent connection")
    twin = import(other_connection, c.source["external_id"], c.source["latest_revision"]["body"])
    assert twin["latest_revision"]["body_hash"] == c.source["latest_revision"]["body_hash"]
    assert {:ok, held} = RevisionUseHolds.restrict(request(c.source), c.caller)
    assert {:error, :revision_use_denied} = use_revision(c.source, "inspection")
    assert :ok = use_revision(twin, "inspection")
    assert :ok = RevisionUseHolds.assert_source_unheld(twin["id"])
    assert {:ok, _} = Evidence.import_markdown(other_connection["id"], document(twin))

    in_workspace(Ecto.UUID.generate(), fn ->
      connection = connect(c.directory, "Independent tenant")

      tenant_twin =
        import(connection, c.source["external_id"], c.source["latest_revision"]["body"])

      assert tenant_twin["latest_revision"]["body_hash"] ==
               c.source["latest_revision"]["body_hash"]

      assert :ok = use_revision(tenant_twin, "compile")
      assert {:error, :not_found} = RevisionUseHolds.status(held["event_id"], c.caller)
      assert {:ok, tenant_hold} = RevisionUseHolds.restrict(request(tenant_twin), c.caller)
      refute tenant_hold["event_id"] == held["event_id"]
    end)

    assert :ok = use_revision(twin, "retrieval")
    assert {:error, :revision_use_denied} = use_revision(c.source, "retrieval")
  end

  test "held source recapture cannot replace bytes, revise metadata, or clear the hold", c do
    assert {:ok, held} = RevisionUseHolds.restrict(request(c.source), c.caller)
    before = source_rows(c.source["id"])
    unchanged = document(c.source)

    for attrs <- [
          unchanged,
          Map.put(unchanged, "body", "New synthetic bytes cannot bypass a source hold."),
          Map.put(unchanged, "title", "A renamed source"),
          Map.put(unchanged, "metadata", %{"use_permission" => "allow", "policy_generation" => 0})
        ] do
      assert {:error, _} = Evidence.import_markdown(c.connection["id"], attrs)
    end

    assert {:error, _} = Evidence.capture_document(c.connection["id"], unchanged)
    assert source_rows(c.source["id"]) == before
    assert {:ok, completed} = Evidence.resume_revision_cleanup(held["event_id"], 0, c.caller)
    assert completed["cleanup_state"] == "completed"
    assert {:error, :revision_use_denied} = use_revision(c.source, "compile")
    assert {:error, _} = Evidence.import_markdown(c.connection["id"], unchanged)
  end

  test "malformed references and unknown purposes fail closed; absence grants no operator access",
       c do
    assert :ok = use_revision(c.source, "retrieval")

    for purpose <- [nil, :retrieval, "extraction", "storage", "grant", "restore"],
        do: assert({:error, :invalid_input} = use_revision(c.source, purpose))

    assert {:error, :source_unavailable} =
             RevisionUseHolds.assert_use(
               c.source["id"],
               c.source["latest_revision"]["id"],
               Contracts.sha256("wrong"),
               "retrieval"
             )

    assert {:error, :invalid_input} = RevisionUseHolds.assert_source_unheld("not-a-source")
    assert {:error, :invalid_input} = RevisionUseHolds.assert_corpus_unheld(nil)

    assert {:error, :source_unavailable} =
             RevisionUseHolds.assert_source_unheld(Ecto.UUID.generate())

    assert {:error, :invalid_scope} = RevisionUseHolds.assert_corpus_unheld(Ecto.UUID.generate())
    revoked = Keyword.put(c.caller, :authorize, fn -> false end)

    assert {:error, :operator_session_revoked} =
             Corpora.create(%{"name" => "No positive grant"}, revoked)

    assert hold_counts() == {0, 0}
  end

  test "the trusted SQL predicate excludes the same revision while retaining an identical-byte identity",
       c do
    twin =
      import(
        connect(c.directory, "Other identity"),
        "record.md",
        c.source["latest_revision"]["body"]
      )

    assert {:ok, _} = RevisionUseHolds.restrict(request(c.source), c.caller)
    predicate = RevisionUseHolds.not_held_sql("r")

    assert [[twin["latest_revision"]["id"]]] ==
             Repo.query!(
               "SELECT r.id FROM evidence_revisions r WHERE r.workspace_id=? AND r.body_hash=? AND #{predicate}",
               [Store.workspace(), c.source["latest_revision"]["body_hash"]]
             ).rows

    predicate = RevisionUseHolds.not_held_sql("evidence_revisions")

    assert [[1]] ==
             Repo.query!(
               "SELECT count(*) FROM evidence_revisions WHERE workspace_id=? AND #{predicate}",
               [Store.workspace()]
             ).rows

    for alias_name <- [nil, :r, "unapproved", "r; SELECT 1", "r.body", "r WHERE 1=1"],
        do: assert_raise(ArgumentError, fn -> RevisionUseHolds.not_held_sql(alias_name) end)
  end

  test "read guards return denial inside the owning transaction without poisoning unrelated work",
       c do
    corpus = corpus([c.source], c.caller)
    assert {:ok, _} = RevisionUseHolds.restrict(request(c.source), c.caller)

    assert {:ok, :committed} =
             Store.transaction(fn ->
               assert {:error, :revision_use_denied} = use_revision(c.source, "analysis")

               assert {:error, :revision_use_denied} =
                        RevisionUseHolds.assert_source_unheld(c.source["id"])

               assert {:error, :revision_use_denied} =
                        RevisionUseHolds.assert_corpus_unheld(corpus["id"])

               Repo.query!("UPDATE corpora SET name=? WHERE id=?", [
                 "An unrelated metadata update",
                 corpus["id"]
               ])

               {:ok, :committed}
             end)

    assert [["An unrelated metadata update"]] ==
             Repo.query!("SELECT name FROM corpora WHERE id=?", [corpus["id"]]).rows
  end

  test "mutations reject caller-owned transactions before acquiring the privacy fence", c do
    attrs = request(c.source)

    assert {:ok, :checked} =
             Repo.transaction(fn ->
               assert {:error, :revision_use_requires_outermost_transaction} =
                        RevisionUseHolds.restrict(attrs, c.caller)

               :checked
             end)

    assert hold_counts() == {0, 0}
    assert {:ok, held} = RevisionUseHolds.restrict(attrs, c.caller)

    assert {:ok, :checked} =
             Repo.transaction(fn ->
               assert {:error, :revision_use_requires_outermost_transaction} =
                        RevisionUseHolds.resume(held["event_id"], 0, c.caller)

               :checked
             end)

    assert {:ok, ^held} = RevisionUseHolds.status(held["event_id"], c.caller)
  end

  test "checkpoint insert failure rolls back the restriction and leaves prior authority unchanged",
       c do
    Repo.query!(
      "CREATE TEMP TRIGGER fail_hold_checkpoint BEFORE INSERT ON revision_use_cleanup BEGIN SELECT RAISE(ABORT,'synthetic checkpoint failure'); END"
    )

    try do
      assert {:error, :revision_use_state_unavailable} =
               RevisionUseHolds.restrict(request(c.source), c.caller)

      assert hold_counts() == {0, 0}
      assert :ok = use_revision(c.source, "retrieval")
    after
      Repo.query!("DROP TRIGGER fail_hold_checkpoint")
    end
  end

  test "failed cleanup rolls back the page, version claim, and all generation changes", c do
    corpora = Enum.map(1..3, fn _ -> corpus([c.source], c.caller) end)
    ids = Enum.map(corpora, & &1["id"]) |> Enum.sort()
    before = generations(ids)
    assert {:ok, held} = RevisionUseHolds.restrict(request(c.source), c.caller)
    last_id = List.last(ids)

    Repo.query!(
      "CREATE TEMP TRIGGER fail_hold_cleanup BEFORE UPDATE ON corpora WHEN OLD.id='#{last_id}' BEGIN SELECT RAISE(ABORT,'synthetic page failure'); END"
    )

    try do
      assert {:error, :revision_use_state_unavailable} =
               RevisionUseHolds.resume(held["event_id"], 0, c.caller)

      assert {:ok, ^held} = RevisionUseHolds.status(held["event_id"], c.caller)
      assert generations(ids) == before

      assert member_statuses(c.source["id"]) |> Enum.map(& &1["status"]) == [
               "active",
               "active",
               "active"
             ]
    after
      Repo.query!("DROP TRIGGER fail_hold_cleanup")
    end

    assert {:ok, complete} = RevisionUseHolds.resume(held["event_id"], 0, c.caller)
    assert complete["cleanup_version"] == 1
    assert complete["cleanup_state"] == "completed"
    assert_page_advanced(before, generations(ids), ids)
  end

  test "authorization loss after cleanup effects also rolls back the checkpoint and generations",
       c do
    corpus = corpus([c.source], c.caller)
    before = generations([corpus["id"]])
    assert {:ok, held} = RevisionUseHolds.restrict(request(c.source), c.caller)
    Process.put(:hold_resume_authorization_checks, 0)

    changing =
      Keyword.put(c.caller, :authorize, fn ->
        n = Process.get(:hold_resume_authorization_checks, 0) + 1
        Process.put(:hold_resume_authorization_checks, n)
        n < 3
      end)

    assert {:error, :operator_session_revoked} =
             RevisionUseHolds.resume(held["event_id"], 0, changing)

    assert {:ok, ^held} = RevisionUseHolds.status(held["event_id"], c.caller)
    assert generations([corpus["id"]]) == before
    assert {:error, :revision_use_denied} = use_revision(c.source, "retrieval")
  end

  test "100-corpus pages persist across fresh callers, fence once, and preserve removal between pages",
       c do
    safe = import(c.connection, "safe.md", "Unrelated current evidence remains usable.")
    corpora = Enum.map(1..101, fn _ -> corpus([c.source, safe], c.caller) end)
    ids = Enum.map(corpora, & &1["id"]) |> Enum.sort()
    before = generations(ids)
    attrs = request(c.source)
    assert {:ok, held} = RevisionUseHolds.restrict(attrs, c.caller)
    assert {:ok, page_one} = RevisionUseHolds.resume(held["event_id"], 0, c.caller)
    assert page_one["cleanup_state"] == "pending"
    assert page_one["cleanup_version"] == 1
    first_page_ids = Enum.take(ids, 100)
    after_one = generations(ids)
    assert_page_advanced(before, after_one, first_page_ids)
    last_id = List.last(ids)
    assert after_one[last_id] == before[last_id]

    assert {:ok, ^page_one} =
             RevisionUseHolds.resume(held["event_id"], 0, caller("retry after reconnect"))

    assert {:error, :version_conflict} = RevisionUseHolds.resume(held["event_id"], 2, c.caller)
    assert generations(ids) == after_one

    assert {:ok, removed} =
             Corpora.apply_members(
               last_id,
               before[last_id].semantic,
               [member_change(c.source, "remove")],
               c.caller
             )

    before_two = generations(ids)
    assert removed["semantic_generation"] == before[last_id].semantic + 1
    assert :ok = RevisionUseHolds.assert_corpus_unheld(last_id)
    assert :ok = use_revision(safe, "retrieval")

    # There is no process-local progress: another caller/process reads the
    # persisted checkpoint and resumes the remaining corpus after reconnect.
    assert {:ok, ^page_one} =
             Task.async(fn ->
               RevisionUseHolds.status(held["event_id"], caller("fresh reader"))
             end)
             |> Task.await()

    assert {:ok, completed} = RevisionUseHolds.resume(held["event_id"], 1, caller("fresh writer"))
    assert completed["cleanup_state"] == "completed"
    assert completed["cleanup_version"] == 2
    after_two = generations(ids)
    assert_page_advanced(before_two, after_two, [last_id])
    for id <- first_page_ids, do: assert(after_two[id] == after_one[id])

    assert [last_member] =
             Enum.filter(member_statuses(c.source["id"]), &(&1["corpus_id"] == last_id))

    assert last_member["status"] == "removed"
    assert last_member["revision_id"] == c.source["latest_revision"]["id"]
    assert last_member["passage_set_id"] == nil

    assert :ok =
             Corpora.assert_current(
               last_id,
               after_two[last_id].semantic,
               after_two[last_id].authorization
             )

    assert {:error, _} =
             Corpora.assert_current(
               last_id,
               before[last_id].semantic,
               before[last_id].authorization
             )

    assert {:error, _} =
             Corpora.apply_members(
               last_id,
               after_two[last_id].semantic,
               [member_change(c.source, "include")],
               c.caller
             )

    assert {:ok, ^completed} = RevisionUseHolds.resume(held["event_id"], 2, c.caller)
    assert {:ok, ^completed} = RevisionUseHolds.resume(held["event_id"], 0, c.caller)
    assert {:ok, ^completed} = RevisionUseHolds.restrict(attrs, c.caller)
    assert generations(ids) == after_two
    assert {:error, :revision_use_denied} = use_revision(c.source, "compile")
  end

  test "a removed member stays excluded with its original revision after hold cleanup", c do
    safe = import(c.connection, "safe.md", "Current unrelated synthetic source.")
    corpus = corpus([c.source, safe], c.caller)

    assert {:ok, removed} =
             Corpora.apply_members(corpus["id"], 1, [member_change(c.source, "remove")], c.caller)

    before = generations([corpus["id"]])
    assert {:ok, held} = RevisionUseHolds.restrict(request(c.source), c.caller)
    assert :ok = RevisionUseHolds.assert_corpus_unheld(corpus["id"])

    assert :ok =
             Corpora.assert_current(
               corpus["id"],
               removed["semantic_generation"],
               removed["authorization_generation"]
             )

    assert {:ok, complete} = RevisionUseHolds.resume(held["event_id"], 0, c.caller)
    assert complete["cleanup_state"] == "completed"
    after_page = generations([corpus["id"]])
    assert_page_advanced(before, after_page, [corpus["id"]])

    assert [%{"status" => "removed", "revision_id" => revision_id, "passage_set_id" => nil}] =
             Enum.map(
               member_statuses(c.source["id"]),
               &Map.take(&1, ~w(status revision_id passage_set_id))
             )

    assert revision_id == c.source["latest_revision"]["id"]
    assert :ok = use_revision(safe, "analysis")

    assert :ok =
             Corpora.assert_current(
               corpus["id"],
               after_page[corpus["id"]].semantic,
               after_page[corpus["id"]].authorization
             )

    assert {:error, _} =
             Corpora.assert_current(
               corpus["id"],
               removed["semantic_generation"],
               removed["authorization_generation"]
             )
  end

  test "the no-hold source invalidation keeps its existing generation behavior", c do
    corpus = corpus([c.source], c.caller)
    before = generations([corpus["id"]])
    assert :ok = Corpora.invalidate_source(c.source["id"], :metadata_changed)
    after_page = generations([corpus["id"]])
    assert after_page[corpus["id"]].semantic == before[corpus["id"]].semantic + 1
    assert after_page[corpus["id"]].lock == before[corpus["id"]].lock + 1
    assert after_page[corpus["id"]].authorization == before[corpus["id"]].authorization
    assert :ok = use_revision(c.source, "retrieval")
    assert :ok = RevisionUseHolds.assert_corpus_unheld(corpus["id"])
  end

  test "resume versions are nonnegative typed integers and completed replays are inert", c do
    assert {:ok, held} = RevisionUseHolds.restrict(request(c.source), c.caller)

    for bad <- [nil, "0", 0.0, -1, true],
        do:
          assert(
            {:error, :invalid_input} = RevisionUseHolds.resume(held["event_id"], bad, c.caller)
          )

    assert {:error, :version_conflict} = RevisionUseHolds.resume(held["event_id"], 1, c.caller)
    assert {:ok, ^held} = RevisionUseHolds.status(held["event_id"], c.caller)
    assert {:ok, completed} = RevisionUseHolds.resume(held["event_id"], 0, c.caller)
    assert completed["cleanup_state"] == "completed"
    assert {:ok, ^completed} = RevisionUseHolds.resume(held["event_id"], 0, c.caller)
    assert {:ok, ^completed} = RevisionUseHolds.resume(held["event_id"], 1, c.caller)
    assert {:error, :version_conflict} = RevisionUseHolds.resume(held["event_id"], 2, c.caller)
    assert {:error, :revision_use_denied} = use_revision(c.source, "inspection")
  end

  test "database read failure denies instead of reporting an empty restriction set", c do
    corpus = corpus([c.source], c.caller)
    assert {:ok, held} = RevisionUseHolds.restrict(request(c.source), c.caller)
    Repo.query!("ALTER TABLE revision_use_holds RENAME TO revision_use_holds_unavailable")

    try do
      assert {:error, :revision_use_state_unavailable} = use_revision(c.source, "retrieval")

      assert {:error, :revision_use_state_unavailable} =
               RevisionUseHolds.assert_source_unheld(c.source["id"])

      assert {:error, :revision_use_state_unavailable} =
               RevisionUseHolds.assert_corpus_unheld(corpus["id"])

      assert {:error, :revision_use_state_unavailable} =
               RevisionUseHolds.status(held["event_id"], c.caller)

      assert {:error, :revision_use_state_unavailable} =
               RevisionUseHolds.restrict(request(c.source), c.caller)
    after
      Repo.query!("ALTER TABLE revision_use_holds_unavailable RENAME TO revision_use_holds")
    end

    assert {:ok, ^held} = RevisionUseHolds.status(held["event_id"], c.caller)
    assert {:error, :revision_use_denied} = use_revision(c.source, "retrieval")
  end

  test "restriction, receipt reads, replay, and cleanup never hydrate source bodies", c do
    handler = {__MODULE__, Ecto.UUID.generate()}

    :ok =
      :telemetry.attach(
        handler,
        [:harness_forge, :repo, :query],
        &__MODULE__.record_query/4,
        self()
      )

    try do
      attrs = request(c.source)
      assert {:ok, held} = RevisionUseHolds.restrict(attrs, c.caller)
      assert {:ok, ^held} = RevisionUseHolds.status(held["event_id"], c.caller)
      assert {:ok, ^held} = RevisionUseHolds.restrict(attrs, c.caller)
      assert {:ok, _} = RevisionUseHolds.resume(held["event_id"], 0, c.caller)
      queries = drain_queries([])
      refute queries == []

      for result <- queries do
        refute inspect(result) =~ c.source["latest_revision"]["body"]

        case result do
          {:ok, %{columns: columns}} when is_list(columns) ->
            refute Enum.any?(columns, &(&1 in ~w(body snippet parent_window)))

          _ ->
            :ok
        end
      end
    after
      :telemetry.detach(handler)
    end
  end

  def record_query(_event, _measurements, metadata, owner),
    do: send(owner, {:hold_query, metadata.result})

  defp drain_queries(acc) do
    receive do
      {:hold_query, result} -> drain_queries([result | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp connect(directory, name) do
    {:ok, connection} =
      Evidence.connect(%{"name" => name, "provider" => "local", "directory" => directory})

    connection
  end

  defp import(connection, external_id, body) do
    {:ok, source} =
      Evidence.import_markdown(connection["id"], %{
        "external_id" => external_id,
        "title" => external_id,
        "body" => body
      })

    source
  end

  defp document(source),
    do: %{
      "external_id" => source["external_id"],
      "title" => source["title"],
      "body" => source["latest_revision"]["body"]
    }

  defp request(source) do
    %{
      "version" => 1,
      "source_id" => source["id"],
      "revision_id" => source["latest_revision"]["id"],
      "body_hash" => source["latest_revision"]["body_hash"],
      "expected_generation" => 0,
      "command_id" => Ecto.UUID.generate(),
      "reason_code" => "operator_restriction"
    }
  end

  defp use_revision(source, purpose),
    do:
      RevisionUseHolds.assert_use(
        source["id"],
        source["latest_revision"]["id"],
        source["latest_revision"]["body_hash"],
        purpose
      )

  defp member_change(source, action),
    do: %{
      "source_id" => source["id"],
      "revision_id" => source["latest_revision"]["id"],
      "action" => action
    }

  defp corpus(sources, caller) do
    {:ok, corpus} = Corpora.create(%{"name" => "Synthetic cleanup corpus"}, caller)

    {:ok, current} =
      Corpora.apply_members(
        corpus["id"],
        0,
        Enum.map(sources, &member_change(&1, "include")),
        caller
      )

    current
  end

  defp hold_counts do
    [[holds]] =
      Repo.query!("SELECT count(*) FROM revision_use_holds WHERE workspace_id=?", [
        Store.workspace()
      ]).rows

    [[cleanup]] =
      Repo.query!("SELECT count(*) FROM revision_use_cleanup WHERE workspace_id=?", [
        Store.workspace()
      ]).rows

    {holds, cleanup}
  end

  defp source_rows(source_id),
    do:
      Repo.query!(
        "SELECT s.title,s.status,s.latest_revision_id,r.id,r.body_hash,r.metadata FROM evidence_sources s JOIN evidence_revisions r ON r.source_id=s.id AND r.workspace_id=s.workspace_id WHERE s.workspace_id=? AND s.id=? ORDER BY r.revision",
        [Store.workspace(), source_id]
      ).rows

  defp generations(ids) do
    Map.new(ids, fn id ->
      [[semantic, authorization, lock]] =
        Repo.query!(
          "SELECT semantic_generation,authorization_generation,lock_version FROM corpora WHERE workspace_id=? AND id=?",
          [Store.workspace(), id]
        ).rows

      {id, %{semantic: semantic, authorization: authorization, lock: lock}}
    end)
  end

  defp assert_page_advanced(before, after_page, ids) do
    for id <- ids do
      assert after_page[id].semantic == before[id].semantic + 1
      assert after_page[id].authorization == before[id].authorization + 1
      assert after_page[id].lock == before[id].lock + 1
    end
  end

  defp member_statuses(source_id) do
    %{columns: columns, rows: rows} =
      Repo.query!(
        "SELECT corpus_id,revision_id,status,passage_set_id FROM corpus_members WHERE workspace_id=? AND source_id=? ORDER BY corpus_id",
        [Store.workspace(), source_id]
      )

    Enum.map(rows, &Map.new(Enum.zip(columns, &1)))
  end

  defp in_workspace(id, fun) do
    previous = Store.workspace()
    Application.put_env(:harness_forge, :workspace_id, id)

    try do
      fun.()
    after
      Application.put_env(:harness_forge, :workspace_id, previous)
    end
  end

  defp caller(session \\ "synthetic local operator"),
    do: [
      authorize: fn -> true end,
      session_fingerprint: Contracts.sha256(session),
      view_generation: String.duplicate("a", 32),
      reset_token: 0
    ]
end
