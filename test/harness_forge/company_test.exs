defmodule HarnessForge.CompanyTest do
  use HarnessForge.DataCase, async: false
  alias HarnessForge.{Company, Contracts, Decisions, Evidence, Goals}

  setup do
    previous = Application.get_env(:harness_forge, :workspace_id)
    Application.put_env(:harness_forge, :workspace_id, "company-test")
    directory = Path.join(File.cwd!(), ".company-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)

    on_exit(fn ->
      Application.put_env(:harness_forge, :workspace_id, previous)
      File.rm_rf!(directory)
    end)

    {:ok, connection} =
      Evidence.connect(%{"provider" => "local", "name" => "Synthetic", "directory" => directory})

    {:ok, source} = document(connection, "note.md", "Review every change")
    {:ok, citation} = Evidence.citation(source["latest_revision"]["id"], 0, 19)
    {:ok, claim} = Evidence.create_claim(%{"text" => "Review changes", "citations" => [citation]})
    {:ok, claim} = Decisions.decide(claim["id"], decision(claim))

    {:ok, goal} =
      Goals.add_goal(%{"title" => "Ship", "owner" => "Maintainer", "acceptance" => "Checks pass"})

    {:ok, profile} =
      Company.save_profile(%{
        "name" => "Synthetic company",
        "source_ids" => [source["id"]],
        "goal_ids" => [goal["id"]]
      })

    {:ok, repository} = Company.create_repository(repository_attrs("example/service"))

    {:ok, project} =
      Company.create_project(%{"name" => "Project", "repository_ids" => [repository["id"]]})

    attrs = %{
      "name" => "reviewed-change",
      "package_version" => "1.0.0",
      "project_id" => project["id"],
      "repository_ids" => [repository["id"]],
      "claim_refs" => [Map.take(claim, ~w(id revision_hash))],
      "goal_ids" => [goal["id"]],
      "template_ids" => ["reviewed-change-v1"],
      "runtime" => "opencode",
      "runtime_version" => "unqualified",
      "execution" => %{"max_turns" => 10, "timeout_seconds" => 120},
      "milestones" => []
    }

    %{
      connection: connection,
      source: source,
      citation: citation,
      claim: claim,
      goal: goal,
      profile: profile,
      repository: repository,
      project: project,
      attrs: attrs
    }
  end

  test "catalogue hashes, optimistic replacement, lexical search and consumers", context do
    repository = context.repository
    assert repository["content_hash"] == Contracts.digest(repository["payload"])

    assert {:error, :stale_content} =
             Company.update_repository(repository["id"], repository["payload"])

    assert {:ok, updated} =
             Company.update_repository(
               repository["id"],
               replacement(repository, %{"capabilities" => ["Payments authorization"]})
             )

    assert {:ok, [^updated]} = Company.search_capabilities("PAYMENTS auth")
    assert {:ok, []} = Company.search_capabilities("")

    assert {:error, :duplicate_identity} =
             Company.create_repository(repository_attrs("example/service"))

    {:ok, consumer} =
      Company.create_repository(
        Map.put(repository_attrs("example/consumer"), "dependency_ids", [repository["id"]])
      )

    assert {:ok, [^consumer]} = Company.consumers(repository["id"])

    assert {:error, :self_dependency} =
             Company.update_repository(
               updated["id"],
               replacement(updated, %{"dependency_ids" => [updated["id"]]})
             )

    assert {:ok, _} =
             Company.update_repository(
               updated["id"],
               replacement(updated, %{"dependency_ids" => [consumer["id"]]})
             )

    assert {:ok, [updated_consumer]} = Company.consumers(consumer["id"])
    assert updated_consumer["id"] == repository["id"]
  end

  test "plan approval is independent, immutable and exact", context do
    {:ok, plan} = Company.create_plan(context.attrs)
    assert plan["status"] == "proposed"
    assert {:error, :plan_not_approved} = Company.build_inputs(plan["id"])

    assert {:error, :stale_revision} =
             Company.decide_plan(plan["id"], %{
               decision(plan)
               | "expected_revision_hash" => String.duplicate("0", 64)
             })

    assert {:ok, %{"status" => "approved"}} = Company.decide_plan(plan["id"], decision(plan))
    assert {:error, :already_decided} = Company.decide_plan(plan["id"], decision(plan))
    assert {:ok, inputs} = Company.build_inputs(plan["id"])
    assert inputs["claims"] == [context.claim]
    assert inputs["goals"] == [context.goal]
    assert inputs["repositories"] == ["example/service"]

    assert inputs["snapshot"]["goals"] == [
             %{
               "id" => context.goal["id"],
               "content_hash" =>
                 Contracts.digest(Map.take(context.goal, ~w(id title owner acceptance)))
             }
           ]

    assert {:error, _} =
             Repo.query("UPDATE company_plans SET revision_hash = 'tampered' WHERE id = ?", [
               plan["id"]
             ])

    assert {:error, _} =
             Repo.query("DELETE FROM company_plan_decisions WHERE plan_id = ?", [plan["id"]])
  end

  test "proposed superseded plans cannot gain approval; approved ancestors stay buildable",
       context do
    {:ok, ancestor} = Company.create_plan(context.attrs)
    {:ok, _} = Company.decide_plan(ancestor["id"], decision(ancestor))
    {:ok, initial} = Company.build_inputs(ancestor["id"])
    {:ok, child} = Company.create_plan(Map.put(context.attrs, "supersedes_id", ancestor["id"]))
    {:ok, _grandchild} = Company.create_plan(Map.put(context.attrs, "supersedes_id", child["id"]))
    assert {:error, :superseded_revision} = Company.decide_plan(child["id"], decision(child))
    assert {:ok, ^initial} = Company.build_inputs(ancestor["id"])

    assert {:ok, %{"status" => "approved", "superseded" => true}} =
             Company.get_plan(ancestor["id"])

    assert {:error, :already_superseded} =
             Company.create_plan(Map.put(context.attrs, "supersedes_id", ancestor["id"]))
  end

  test "unrelated approval and unused source revision changes leave build inputs exact",
       context do
    {:ok, unused} = document(context.connection, "unused.md", "Unused evidence")

    {:ok, _} =
      Company.save_profile(
        replacement(context.profile, %{"source_ids" => [context.source["id"], unused["id"]]})
      )

    {:ok, plan} = Company.create_plan(context.attrs)
    {:ok, _} = Company.decide_plan(plan["id"], decision(plan))
    {:ok, before} = Company.build_inputs(plan["id"])
    assert length(before["snapshot"]["sources"]) == 1
    {:ok, citation} = Evidence.citation(unused["latest_revision"]["id"], 0, 6)
    {:ok, other} = Evidence.create_claim(%{"text" => "Unrelated", "citations" => [citation]})
    {:ok, _} = Decisions.decide(other["id"], decision(other))
    {:ok, _} = document(context.connection, "unused.md", "Changed unused evidence")
    {:ok, _} = Company.create_plan(context.attrs)
    assert {:ok, ^before} = Company.build_inputs(plan["id"])
  end

  test "every citation must belong to an explicitly applicable active source", context do
    {:ok, other} = document(context.connection, "other.md", "Other source")
    {:ok, citation} = Evidence.citation(other["latest_revision"]["id"], 0, 5)

    {:ok, mixed} =
      Evidence.create_claim(%{"text" => "Mixed", "citations" => [context.citation, citation]})

    {:ok, mixed} = Decisions.decide(mixed["id"], decision(mixed))
    attrs = Map.put(context.attrs, "claim_refs", [Map.take(mixed, ~w(id revision_hash))])
    assert {:error, :source_out_of_scope} = Company.create_plan(attrs)

    {:ok, _} =
      Company.update_project(
        context.project["id"],
        replacement(context.project, %{"source_ids" => [other["id"]]})
      )

    assert {:ok, plan} = Company.create_plan(attrs)
    assert length(plan["snapshot"]["sources"]) == 2
  end

  test "stale revisions, revocation and superseded claims invalidate approved plans", context do
    {:ok, plan} = Company.create_plan(context.attrs)
    {:ok, _} = Company.decide_plan(plan["id"], decision(plan))

    {:ok, _} =
      Evidence.create_claim(%{
        "text" => "New revision",
        "citations" => [context.citation],
        "supersedes_id" => context.claim["id"]
      })

    assert {:error, :claim_not_approved} = Company.build_inputs(plan["id"])
    assert {:error, :claim_not_approved} = Company.create_plan(context.attrs)
  end

  test "changed source and revoked connections invalidate build", context do
    {:ok, plan} = Company.create_plan(context.attrs)
    {:ok, _} = Company.decide_plan(plan["id"], decision(plan))
    {:ok, _} = document(context.connection, "note.md", "Review changed evidence")
    assert {:error, :claim_not_approved} = Company.build_inputs(plan["id"])
    {:ok, _} = Evidence.revoke_connection(context.connection["id"])
    assert {:error, :claim_not_approved} = Company.build_inputs(plan["id"])
  end

  test "selected catalogue edits and withdrawn scope invalidate exact snapshots", context do
    {:ok, plan} = Company.create_plan(context.attrs)
    {:ok, _} = Company.decide_plan(plan["id"], decision(plan))

    {:ok, _} =
      Company.update_repository(
        context.repository["id"],
        replacement(context.repository, %{"purpose" => "Renamed purpose"})
      )

    assert {:error, :stale_plan} = Company.build_inputs(plan["id"])
    {:ok, _} = Company.save_profile(replacement(context.profile, %{"source_ids" => []}))
    assert {:error, :source_out_of_scope} = Company.build_inputs(plan["id"])
  end

  test "plan approval cannot authorize proposed claims or goal-only policy", context do
    {:ok, proposed} =
      Evidence.create_claim(%{"text" => "Proposed policy", "citations" => [context.citation]})

    assert {:error, :claim_not_approved} =
             Company.create_plan(
               Map.put(context.attrs, "claim_refs", [Map.take(proposed, ~w(id revision_hash))])
             )

    assert {:error, :invalid_input} =
             Company.create_plan(Map.put(context.attrs, "claim_refs", []))

    assert {:ok, %{"status" => "proposed"}} = Evidence.get_claim(proposed["id"])
  end

  test "milestone DAG accepts dependencies and rejects cycles, unknown IDs and unauthorized goals",
       context do
    first = milestone("first", context.goal["id"])
    second = Map.put(milestone("second", context.goal["id"]), "depends_on", ["first"])
    assert {:ok, _} = Company.create_plan(Map.put(context.attrs, "milestones", [second, first]))

    for invalid <- [
          [Map.put(first, "depends_on", ["first"])],
          [Map.put(first, "depends_on", ["missing"])],
          [Map.put(first, "depends_on", ["second"]), second],
          [Map.put(first, "goal_ids", [Ecto.UUID.generate()])],
          [first, first]
        ] do
      assert {:error, :invalid_input} =
               Company.create_plan(Map.put(context.attrs, "milestones", invalid))
    end
  end

  test "malformed, duplicate, unknown and excessive inputs fail closed", context do
    for invalid <- [nil, [], "x", 1, %{name: "Atom"}, %{"name" => <<255>>}] do
      assert {:error, _} = Company.save_profile(invalid)
      assert {:error, _} = Company.create_repository(invalid)
      assert {:error, _} = Company.create_project(invalid)
      assert {:error, _} = Company.create_plan(invalid)
      assert {:error, _} = Company.decide_plan(Ecto.UUID.generate(), invalid)
    end

    for {key, value} <- [
          {"template_ids", ["arbitrary"]},
          {"instructions", "Run commands"},
          {"repository_ids", [context.repository["id"], context.repository["id"]]},
          {"execution", %{"max_turns" => 0, "timeout_seconds" => 2}},
          {"milestones", [nil]},
          {"runtime", "unknown"},
          {"claim_refs", [nil]}
        ] do
      assert {:error, :invalid_input} = Company.create_plan(Map.put(context.attrs, key, value))
    end

    assert {:error, :not_found} =
             Company.create_project(%{
               "name" => "Unknown",
               "repository_ids" => [Ecto.UUID.generate()]
             })

    assert {:error, :invalid_input} =
             Company.create_repository(
               Map.put(repository_attrs("example/x"), "interfaces", [%{"command" => "anything"}])
             )

    assert {:error, :invalid_input} = Company.create_repository(repository_attrs("/private/path"))

    assert {:error, :invalid_input} =
             Company.save_profile(%{
               "name" => "Too many",
               "source_ids" => Enum.map(1..101, fn _ -> Ecto.UUID.generate() end)
             })
  end

  test "workspace isolation applies to reads, mutations and plan admission", context do
    {:ok, plan} = Company.create_plan(context.attrs)
    Application.put_env(:harness_forge, :workspace_id, "company-other")
    assert {:ok, nil} = Company.get_profile()
    assert {:ok, []} = Company.list_repositories()
    assert {:ok, []} = Company.list_projects()
    assert {:ok, []} = Company.list_plans()
    assert {:error, :not_found} = Company.get_plan(plan["id"])
    assert {:error, :not_found} = Company.build_inputs(plan["id"])

    assert {:error, :not_found} =
             Company.update_repository(
               context.repository["id"],
               replacement(context.repository, %{})
             )

    assert {:error, :not_found} =
             Company.save_profile(%{"name" => "Foreign", "source_ids" => [context.source["id"]]})

    assert {:ok, nil} = Company.get_profile()
  end

  test "current remote connection selection is rechecked without a network fetch", context do
    {:ok, remote} =
      Evidence.connect(%{
        "provider" => "github",
        "name" => "Synthetic remote",
        "config" => %{
          "repository" => "synthetic/selected",
          "endpoint" => "https://api.github.com"
        }
      })

    {:ok, source} =
      Evidence.import_markdown(remote["id"], %{
        "external_id" => "github:" <> remote["id"] <> ":repository:1",
        "title" => "Synthetic repository",
        "body" => "Review remote changes",
        "source_url" => "https://github.com/synthetic/selected",
        "metadata" => %{"repository" => "synthetic/selected", "kind" => "repository"}
      })

    {:ok, citation} = Evidence.citation(source["latest_revision"]["id"], 0, 6)
    {:ok, claim} = Evidence.create_claim(%{"text" => "Review", "citations" => [citation]})
    {:ok, claim} = Decisions.decide(claim["id"], decision(claim))

    {:ok, _} =
      Company.save_profile(replacement(context.profile, %{"source_ids" => [source["id"]]}))

    {:ok, plan} =
      Company.create_plan(
        Map.put(context.attrs, "claim_refs", [Map.take(claim, ~w(id revision_hash))])
      )

    {:ok, _} = Company.decide_plan(plan["id"], decision(plan))
    assert {:ok, _} = Company.build_inputs(plan["id"])

    Repo.get!(HarnessForge.Evidence.Connection, remote["id"])
    |> Ecto.Changeset.change(
      config: %{"repository" => "synthetic/other", "endpoint" => "https://api.github.com"}
    )
    |> Repo.update!()

    assert {:error, :scope_violation} = Company.build_inputs(plan["id"])
  end

  test "company writes wait for the shared privacy fence" do
    parent = self()

    task =
      HarnessForge.Privacy.Purge.synchronize(fn ->
        task =
          Task.async(fn ->
            send(parent, :attempting_catalog_write)
            Company.create_repository(repository_attrs("example/fenced"))
          end)

        assert_receive :attempting_catalog_write
        refute_receive {_, {:ok, _}}, 30
        task
      end)

    assert {:ok, _} = Task.await(task)
  end

  test "optional milestones default empty and removed project membership invalidates a plan",
       context do
    {:ok, plan} = Company.create_plan(Map.delete(context.attrs, "milestones"))
    assert plan["payload"]["milestones"] == []
    assert plan["revision_hash"] == Contracts.digest(Map.take(plan, ~w(payload snapshot)))
    {:ok, _} = Company.decide_plan(plan["id"], decision(plan))

    {:ok, _} =
      Company.update_project(
        context.project["id"],
        replacement(context.project, %{"repository_ids" => []})
      )

    assert {:error, :repository_out_of_scope} = Company.build_inputs(plan["id"])

    assert {:error, :invalid_input} =
             Company.create_plan(Map.put(context.attrs, "template_ids", []))
  end

  defp document(connection, external_id, body),
    do:
      Evidence.import_markdown(connection["id"], %{
        "external_id" => external_id,
        "title" => "Synthetic",
        "body" => body
      })

  defp repository_attrs(identity),
    do: %{
      "identity" => identity,
      "name" => "Service",
      "purpose" => "Synthetic",
      "owner" => "Maintainer"
    }

  defp replacement(dto, changes),
    do:
      dto["payload"]
      |> Map.merge(changes)
      |> Map.put("expected_content_hash", dto["content_hash"])

  defp decision(dto),
    do: %{
      "actor" => "Maintainer",
      "decision" => "approve",
      "expected_revision_hash" => dto["revision_hash"]
    }

  defp milestone(id, goal),
    do: %{
      "id" => id,
      "title" => "Verify",
      "goal_ids" => [goal],
      "depends_on" => [],
      "acceptance" => "Checks pass",
      "evaluation_method" => "Run test suite",
      "target_version" => "1.0.0"
    }
end
