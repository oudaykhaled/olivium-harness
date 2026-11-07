defmodule HarnessForge.GoalClaimsTest do
  use HarnessForge.DataCase, async: false

  alias HarnessForge.{Audit, Contracts, Decisions, Evidence, Goals, Workspaces}
  alias HarnessForge.Evidence.{Claim, Store}
  alias HarnessForge.Privacy.Purge

  setup do
    {:ok, goal} =
      Goals.add_goal(%{
        "title" => "Synthetic goal",
        "owner" => "Synthetic owner",
        "acceptance" => "A reviewer records the result"
      })

    %{goal: goal, attrs: attrs(goal)}
  end

  test "goal selection alone grants no authority; the exact basis and text need a decision",
       ctx do
    assert {:ok, []} = Evidence.approved_claims()

    assert Goals.content_hash(ctx.goal) ==
             Contracts.digest(Map.take(ctx.goal, ~w(id title owner acceptance)))

    assert {:ok, claim} = Evidence.create_claim(ctx.attrs)
    assert claim["text"] == "Record a review result"
    assert claim["basis"] == ctx.attrs["basis"]
    assert claim["citations"] == []
    assert claim["status"] == "proposed"

    assert claim["revision_hash"] ==
             Contracts.digest(%{
               "kind" => "goal-origin-claim",
               "version" => 1,
               "text" => "Record a review result",
               "basis" => ctx.attrs["basis"]
             })

    assert {:ok, ^claim} = Evidence.validate_claim(claim)
    assert {:ok, []} = Evidence.approved_claims()

    assert {:error, :stale_revision} =
             Decisions.decide(claim["id"], decision(claim, "approve", "wrong"))

    assert {:ok, approved} = Decisions.decide(claim["id"], decision(claim))
    assert approved["status"] == "approved"
    assert {:ok, [^approved]} = Evidence.approved_claims()
    assert {:error, :already_decided} = Decisions.decide(claim["id"], decision(claim, "reject"))

    assert {:ok, events} = Audit.list_events()
    encoded = Jason.encode!(events)
    refute encoded =~ ctx.goal["title"]
    refute encoded =~ claim["text"]
  end

  test "only the exact four-key version-one goal basis with empty citations is accepted", ctx do
    basis = ctx.attrs["basis"]

    for invalid <- [
          %{},
          [],
          "goal",
          1,
          Map.delete(basis, "goal_id"),
          Map.put(basis, "extra", true),
          Map.put(basis, "version", 2),
          Map.put(basis, "version", 1.0),
          Map.put(basis, "kind", "source"),
          Map.put(basis, "goal_id", "invalid"),
          Map.put(basis, "goal_content_hash", String.duplicate("A", 64)),
          Map.put(basis, "goal_content_hash", String.duplicate("a", 63))
        ] do
      assert {:error, :invalid_claim_basis} =
               Evidence.create_claim(Map.put(ctx.attrs, "basis", invalid))
    end

    for mixed <- [nil, %{}, [%{"id" => Ecto.UUID.generate()}]] do
      assert {:error, :invalid_claim_basis} =
               Evidence.create_claim(Map.put(ctx.attrs, "citations", mixed))
    end

    assert {:error, :invalid_citation} = Evidence.create_claim(Map.delete(ctx.attrs, "basis"))
    assert {:error, :invalid_citation} = Evidence.create_claim(Map.put(ctx.attrs, "basis", nil))
    assert Repo.aggregate(Store.scoped(Claim), :count) == 0
  end

  test "missing, foreign and content-mismatched goals share a private safe refusal", ctx do
    for basis <- [
          Map.put(ctx.attrs["basis"], "goal_id", Ecto.UUID.generate()),
          Map.put(ctx.attrs["basis"], "goal_content_hash", String.duplicate("0", 64))
        ] do
      assert {:error, :stale_goal_basis} =
               Evidence.create_claim(Map.put(ctx.attrs, "basis", basis))
    end

    previous = Workspaces.current_id()
    Application.put_env(:harness_forge, :workspace_id, Ecto.UUID.generate())

    try do
      assert {:error, :stale_goal_basis} = Evidence.create_claim(ctx.attrs)
    after
      Application.put_env(:harness_forge, :workspace_id, previous)
    end
  end

  test "immutable claim integrity is rechecked on approval and current projections", ctx do
    {:ok, claim} = Evidence.create_claim(ctx.attrs)

    assert {:error, :invalid_claim_basis} =
             Evidence.validate_claim(Map.put(claim, "text", "Forged text"))

    assert {:error, :invalid_claim_basis} =
             Evidence.validate_claim(Map.put(claim, "revision_hash", String.duplicate("0", 64)))

    assert {:error, _} =
             Repo.query("UPDATE evidence_claims SET basis = NULL WHERE id = ?", [claim["id"]])

    assert {:error, _} = Repo.query("DELETE FROM evidence_claims WHERE id = ?", [claim["id"]])

    Repo.query!("DROP TRIGGER immutable_evidence_claims_update")

    Repo.query!("UPDATE evidence_claims SET revision_hash = ? WHERE id = ?", [
      String.duplicate("0", 64),
      claim["id"]
    ])

    assert {:ok, current} = Evidence.get_claim(claim["id"])
    assert {:error, :invalid_claim_basis} = Decisions.decide(current["id"], decision(current))
    assert {:ok, []} = Evidence.approved_claims()
  end

  test "origin-changing successors refuse in both directions and leave lineage intact", ctx do
    source = sourced_claim()
    {:ok, goal_claim} = Evidence.create_claim(ctx.attrs)

    assert {:error, :claim_origin_change} =
             Evidence.create_claim(Map.put(ctx.attrs, "supersedes_id", source["id"]))

    assert {:error, :claim_origin_change} =
             Evidence.create_claim(%{
               "text" => "Retyped",
               "citations" => source["citations"],
               "supersedes_id" => goal_claim["id"]
             })

    assert Repo.aggregate(Store.scoped(Claim), :count) == 2
    assert {:ok, %{"superseded" => false}} = Evidence.get_claim(source["id"])
    assert {:ok, %{"superseded" => false}} = Evidence.get_claim(goal_claim["id"])
  end

  test "goal successors need fresh exact approval and rejection never authorizes", ctx do
    {:ok, claim} = Evidence.create_claim(ctx.attrs)
    {:ok, _} = Decisions.decide(claim["id"], decision(claim))

    {:ok, successor} =
      Evidence.create_claim(
        Map.merge(ctx.attrs, %{"text" => "Revised rule", "supersedes_id" => claim["id"]})
      )

    assert successor["family_id"] == claim["family_id"]
    assert successor["revision_hash"] != claim["revision_hash"]
    assert {:ok, []} = Evidence.approved_claims()
    assert {:error, :superseded_revision} = Decisions.decide(claim["id"], decision(claim))

    assert {:ok, %{"status" => "rejected"}} =
             Decisions.decide(successor["id"], decision(successor, "reject"))

    assert {:ok, []} = Evidence.approved_claims()
  end

  test "proposal and decision resolve the goal only after acquiring the privacy fence", ctx do
    {:ok, claim} = Evidence.create_claim(ctx.attrs)
    parent = self()

    tasks =
      Purge.synchronize(fn ->
        tasks =
          for action <- [:propose, :approve] do
            Task.async(fn ->
              send(parent, {:attempting, action})

              case action do
                :propose -> Evidence.create_claim(ctx.attrs)
                :approve -> Decisions.decide(claim["id"], decision(claim))
              end
            end)
          end

        assert_receive {:attempting, :propose}
        assert_receive {:attempting, :approve}
        refute_receive {_, {:ok, _}}, 30
        Repo.query!("DROP TRIGGER immutable_workspace_goals_update")

        Repo.query!("UPDATE workspace_goals SET acceptance = 'Adversarial drift' WHERE id = ?", [
          ctx.goal["id"]
        ])

        tasks
      end)

    for task <- tasks, do: assert(Task.await(task) == {:error, :stale_goal_basis})
    assert {:ok, []} = Evidence.approved_claims()
  end

  test "legacy source hash calculation and omitted null DTO remain exact" do
    claim = sourced_claim()

    canonical = %{
      "text" => claim["text"],
      "citations" =>
        Enum.map(
          claim["citations"],
          &Map.take(&1, ~w(id revision_id start_byte end_byte snippet_hash))
        )
    }

    # This is the pre05 Evidence.create_claim/1 expression, including strict JSON encoding.
    assert claim["revision_hash"] == Store.hash(Jason.encode!(canonical, maps: :strict))
    refute Map.has_key?(claim, "basis")
    assert {:ok, approved} = Decisions.decide(claim["id"], decision(claim))
    refute Map.has_key?(approved, "basis")
    assert {:ok, [^approved]} = Evidence.approved_claims()
  end

  test "an incomplete privacy operation keeps priority over malformed proposal and decision",
       ctx do
    {:ok, claim} = Evidence.create_claim(ctx.attrs)
    now = DateTime.to_iso8601(Store.now())

    Repo.query!(
      "INSERT INTO privacy_operations (id, workspace_id, kind, target_id, state, plan, inserted_at, updated_at) VALUES (?, ?, 'workspace', ?, 'prepared', '{}', ?, ?)",
      [Ecto.UUID.generate(), Store.workspace(), Store.workspace(), now, now]
    )

    assert {:error, :privacy_operation_incomplete} = Evidence.create_claim(%{})
    assert {:error, :privacy_operation_incomplete} = Decisions.decide(claim["id"], %{})
  end

  defp attrs(goal),
    do: %{
      "text" => "  Record a review result  ",
      "citations" => [],
      "basis" => %{
        "version" => 1,
        "kind" => "goal",
        "goal_id" => goal["id"],
        "goal_content_hash" => Goals.content_hash(goal)
      }
    }

  defp decision(claim, kind \\ "approve", hash \\ nil),
    do: %{
      "actor" => "synthetic-reviewer",
      "decision" => kind,
      "expected_revision_hash" => hash || claim["revision_hash"]
    }

  defp sourced_claim do
    directory = Path.join(File.cwd!(), "tmp/goal-source-#{Ecto.UUID.generate()}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    {:ok, connection} =
      Evidence.connect(%{
        "name" => "Synthetic source",
        "provider" => "local",
        "directory" => directory
      })

    {:ok, source} =
      Evidence.import_markdown(connection["id"], %{
        "external_id" => "rule.md",
        "title" => "Synthetic",
        "body" => "Review changes"
      })

    {:ok, citation} = Evidence.citation(source["latest_revision"]["id"], 0, 14)
    {:ok, claim} = Evidence.create_claim(%{"text" => "Review changes", "citations" => [citation]})
    claim
  end
end
