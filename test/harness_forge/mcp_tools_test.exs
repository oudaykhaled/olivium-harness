defmodule HarnessForge.MCP.ToolsTest do
  use HarnessForge.DataCase, async: false

  alias HarnessForge.{Company, Decisions, Evidence, Harnesses, Privacy, Workspaces}
  alias HarnessForge.Company.{Plan, PlanDecision, Repository}
  alias HarnessForge.Evidence.{Connection, Store}
  alias HarnessForge.Harnesses.ArtifactBinding
  alias HarnessForge.MCP.Tools

  @search "harnessforge_search_repositories"
  @plans "harnessforge_company_plans"
  @package "harnessforge_inspect_package"
  @run "harnessforge_company_run_readiness"
  @private_text "MCP_PRIVATE_SENTINEL: report synthetic checks before delivery."

  setup do
    previous_root = Application.fetch_env!(:harness_forge, :workspace_root)
    previous_id = Workspaces.current_id()
    id = Ecto.UUID.generate()
    root = Path.join(File.cwd!(), "tmp/mcp-tools-#{id}")
    for directory <- ~w(artifacts runs tmp input), do: File.mkdir_p!(Path.join(root, directory))
    Application.put_env(:harness_forge, :workspace_root, root)
    Application.put_env(:harness_forge, :workspace_id, id)

    on_exit(fn ->
      Application.put_env(:harness_forge, :workspace_root, previous_root)
      Application.put_env(:harness_forge, :workspace_id, previous_id)
      File.rm_rf!(root)
    end)

    {:ok, connection} =
      Evidence.connect(%{
        "provider" => "local",
        "name" => "Public synthetic MCP fixture",
        "directory" => Path.join(root, "input")
      })

    {:ok, source} =
      Evidence.import_markdown(connection["id"], %{
        "external_id" => "policy.md",
        "title" => "Synthetic policy",
        "body" => @private_text
      })

    {:ok, citation} =
      Evidence.citation(source["latest_revision"]["id"], 0, byte_size(@private_text))

    {:ok, claim} = Evidence.create_claim(%{"text" => @private_text, "citations" => [citation]})
    {:ok, _} = Decisions.decide(claim["id"], decision(claim, "approve"))
    {:ok, _} = Company.save_profile(%{"name" => "Example Works"})
    identity = repository("identity", %{"capabilities" => ["Authentication identity"]})

    orders =
      repository("orders", %{
        "capabilities" => ["Commerce ordering"],
        "dependency_ids" => [identity["id"]]
      })

    {:ok, project} =
      Company.create_project(%{
        "name" => "Commerce",
        "repository_ids" => [identity["id"], orders["id"]],
        "source_ids" => [source["id"]]
      })

    attrs = %{
      "name" => "example-commerce",
      "package_version" => "0.1.0",
      "project_id" => project["id"],
      "repository_ids" => [identity["id"], orders["id"]],
      "claim_refs" => [Map.take(claim, ~w(id revision_hash))],
      "goal_ids" => [],
      "template_ids" => ["reviewed-change-v1", "reuse-before-build-v1"],
      "runtime" => "codex",
      "runtime_version" => "0.156.0",
      "execution" => %{"max_turns" => 12, "timeout_seconds" => 600}
    }

    %{root: root, attrs: attrs, identity: identity, source: source, claim: claim}
  end

  test "discovery advertises exactly four fixed read-only tools" do
    assert Enum.map(Tools.list(), & &1["name"]) == [@run, @search, @plans, @package]

    for tool <- Tools.list() do
      assert tool["annotations"] == %{
               "readOnlyHint" => true,
               "destructiveHint" => false,
               "idempotentHint" => true,
               "openWorldHint" => false
             }

      assert tool["inputSchema"]["type"] == "object"
      refute Jason.encode!(tool) =~ @private_text
    end

    for unknown <- ~w(harnessforge_build_plan harnessforge_export harnessforge_approve run eval),
        do: assert({:error, :unknown_tool} = Tools.call(unknown, %{}))
  end

  test "capability search preserves all-token matching and exposes only catalogue identities",
       ctx do
    assert {:ok, result} = Tools.call(@search, %{"query" => "AUTHENTICATION identity"})
    assert result["returned_count"] == 1
    assert result["truncated"] == false
    assert result["authority"] == "operator_authored_catalogue"
    assert [row] = result["repositories"]
    assert row["id"] == ctx.identity["id"]
    assert Enum.sort(Map.keys(row)) == ~w(content_hash id identity name owner)
    assert {:ok, %{"repositories" => []}} = Tools.call(@search, %{"query" => "auth commerce"})
    assert {:ok, %{"repositories" => []}} = Tools.call(@search, %{"query" => "  \t\n"})
  end

  test "search validates exact arguments and bounded Unicode query tokens" do
    invalid = [
      %{},
      %{query: "authentication"},
      %{"query" => false},
      %{"query" => <<255>>},
      %{"query" => String.duplicate("a", 257)},
      %{"query" => String.duplicate("😀", 257)},
      %{"query" => Enum.join(1..21, " ")},
      %{"query" => "authentication", "workspace_id" => "foreign"},
      %{"query" => "authentication", "limit" => 0},
      %{"query" => "authentication", "limit" => 21},
      %{"query" => "authentication", "limit" => 1.0},
      %{"query" => "authentication", "limit" => nil},
      nil,
      []
    ]

    for arguments <- invalid,
        do: assert({:error, :invalid_arguments} = Tools.call(@search, arguments))

    assert {:ok, _} = Tools.call(@search, %{"query" => String.duplicate("😀", 256)})
    assert {:ok, _} = Tools.call(@search, %{"query" => Enum.join(1..20, " ")})
  end

  test "100-row maximum catalogue remains scoped and returned entries stay bounded" do
    for index <- 3..100 do
      repository("service#{index}", %{
        "capabilities" => ["Authentication"],
        "name" => String.duplicate("界", 256),
        "owner" => String.duplicate("😀", 256)
      })
    end

    foreign_repository()
    assert {:ok, %{"repositories" => rows} = result} = Tools.call(@search, %{"query" => "auth"})
    assert length(rows) == 10
    assert result["truncated"]
    assert result["returned_count"] == 10
    assert Enum.all?(rows, &(&1["identity"] != "foreign/identity"))

    assert {:ok, %{"returned_count" => 20, "truncated" => true}} =
             Tools.call(@search, %{"query" => "auth", "limit" => 20})

    assert Repo.aggregate(Store.scoped(Repository), :count) == 100
  end

  test "plan summaries use stable SQL-limited projections without reading snapshots", ctx do
    timestamp = Store.now()

    ids =
      for number <- 1..25 do
        id = "00000000-0000-0000-0000-" <> String.pad_leading(Integer.to_string(number), 12, "0")

        Repo.insert!(%Plan{
          id: id,
          family_id: id,
          workspace_id: Store.workspace(),
          payload: Map.put(ctx.attrs, "name", "summary-#{number}"),
          snapshot: %{"private" => @private_text},
          revision_hash: String.duplicate("a", 64),
          inserted_at: timestamp
        })

        id
      end

    [first_id | _] = ids

    Repo.insert!(%PlanDecision{
      workspace_id: Store.workspace(),
      plan_id: first_id,
      actor: "synthetic-test",
      decision: "approve",
      revision_hash: String.duplicate("a", 64),
      inserted_at: timestamp
    })

    foreign_plan(ctx.attrs)
    handler = "mcp-plan-query-#{Ecto.UUID.generate()}"
    owner = self()

    :ok =
      :telemetry.attach(
        handler,
        [:harness_forge, :repo, :query],
        fn _, _, metadata, pid -> send(pid, {:mcp_query, metadata.query}) end,
        owner
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    assert {:ok, result} = Tools.call(@plans, %{"limit" => 20})
    assert result["returned_count"] == 20
    assert result["truncated"]
    assert Enum.map(result["plans"], & &1["id"]) == Enum.take(ids, 20)
    assert hd(result["plans"])["status"] == "approved"
    assert_receive {:mcp_query, query}
    assert query =~ "json_extract"
    assert query =~ "LIMIT"
    refute query =~ "snapshot"
    refute Jason.encode!(result) =~ @private_text

    for plan <- result["plans"] do
      assert Enum.sort(Map.keys(plan)) == ~w(id name revision_hash status superseded)
    end
  end

  test "plan readiness distinguishes review, exact approval, and existing package", ctx do
    plan = plan(ctx.attrs)
    assert {:ok, proposed} = Tools.call(@plans, %{"plan_id" => plan["id"]})
    assert proposed["status"] == "proposed"
    refute proposed["buildable"]
    assert proposed["blocker_code"] == "plan_not_approved"
    assert proposed["next_action"] == "review_plan"
    approve(plan)
    assert {:ok, approved} = Tools.call(@plans, %{"plan_id" => plan["id"]})
    assert approved["status"] == "approved"
    assert approved["buildable"]
    assert approved["blocker_code"] == nil
    assert approved["next_action"] == "build_in_portal"
    artifact = build(plan)
    assert {:ok, built} = Tools.call(@plans, %{"plan_id" => plan["id"]})
    assert built["artifact_digests"] == [artifact["digest"]]
    assert built["artifacts_truncated"] == false
    assert built["next_action"] == "inspect_package"
    refute Jason.encode!(built) =~ @private_text
    refute Map.has_key?(built, "snapshot")
    refute Map.has_key?(built, "payload")
  end

  test "rejected and proposed successors do not withdraw an eligible approved ancestor", ctx do
    first = plan(ctx.attrs)
    approve(first)
    artifact = build(first)

    next =
      plan(Map.merge(ctx.attrs, %{"supersedes_id" => first["id"], "package_version" => "0.2.0"}))

    assert {:ok, result} = Tools.call(@plans, %{"plan_id" => first["id"]})
    assert result["superseded"]
    assert result["buildable"]
    assert {:ok, %{"eligible" => true}} = Tools.call(@package, %{"digest" => artifact["digest"]})
    assert {:ok, _} = Company.decide_plan(next["id"], decision(next, "reject"))
    assert {:ok, rejected} = Tools.call(@plans, %{"plan_id" => next["id"]})
    assert rejected["status"] == "rejected"
    refute rejected["buildable"]
    assert rejected["next_action"] == "review_plan"
    assert {:ok, %{"buildable" => true}} = Tools.call(@plans, %{"plan_id" => first["id"]})
  end

  test "catalogue drift keeps decision visible but suppresses stale package details", ctx do
    plan = plan(ctx.attrs)
    approve(plan)
    artifact = build(plan)

    assert {:ok, _} =
             Company.update_repository(
               ctx.identity["id"],
               ctx.identity["payload"]
               |> Map.put("name", "Changed identity catalogue")
               |> Map.put("expected_content_hash", ctx.identity["content_hash"])
             )

    assert {:ok, result} = Tools.call(@plans, %{"plan_id" => plan["id"]})
    assert result["status"] == "approved"
    refute result["buildable"]
    assert result["blocker_code"] == "stale_plan"
    assert result["next_action"] == "review_current_inputs"
    assert_redacted_package(artifact, "stale_or_revoked_plan")
  end

  test "source withdrawal and superseded claims cannot retain package eligibility", ctx do
    plan = plan(ctx.attrs)
    approve(plan)
    artifact = build(plan)

    assert {:ok, _} =
             Evidence.create_claim(%{
               "text" => "A new synthetic observation needing review",
               "citations" => ctx.claim["citations"],
               "supersedes_id" => ctx.claim["id"]
             })

    assert {:ok, %{"buildable" => false, "blocker_code" => "claim_not_approved"}} =
             Tools.call(@plans, %{"plan_id" => plan["id"]})

    assert_redacted_package(artifact, "stale_or_revoked_evidence")
    assert {:ok, _} = Evidence.revoke_source(ctx.source["id"])
    assert {:ok, %{"buildable" => false}} = Tools.call(@plans, %{"plan_id" => plan["id"]})
    assert_redacted_package(artifact, "stale_or_revoked_evidence")
  end

  test "withdrawn plan and claim authority matches restored-quarantine admission", ctx do
    plan = plan(ctx.attrs)
    approve(plan)
    artifact = build(plan)

    # Reproduce the authority withdrawal performed by Snapshot's quarantine.
    # The sandbox rolls these trigger changes back with the synthetic records.
    Repo.query!("DROP TRIGGER immutable_company_plan_decisions_delete")
    Repo.query!("DROP TRIGGER immutable_claim_decisions_delete")
    Repo.delete_all(Store.scoped(PlanDecision))
    Repo.query!("DELETE FROM claim_decisions WHERE workspace_id = ?", [Store.workspace()])

    Repo.update_all(Store.scoped(Connection),
      set: [
        status: "revoked",
        config: %{},
        directory: nil,
        sync_state: "restored_requires_revalidation"
      ]
    )

    assert {:ok, %{"status" => "proposed", "buildable" => false}} =
             Tools.call(@plans, %{"plan_id" => plan["id"]})

    assert_redacted_package(artifact, "stale_or_revoked_evidence")
  end

  test "verified package reports local bindings and never claims runtime qualification", ctx do
    plan = plan(ctx.attrs)
    approve(plan)
    artifact = build(plan)
    assert {:ok, result} = Tools.call(@package, %{"digest" => artifact["digest"]})
    assert result["integrity"] == "verified"
    assert result["eligible"]
    assert result["name"] == "example-commerce"
    assert result["version"] == "0.1.0"
    assert result["runtime"] == "codex"
    assert result["runtime_version"] == "0.156.0"
    assert result["rule_count"] == 1
    assert result["file_count"] == map_size(artifact["files"])
    assert result["provenance_scope"] == "local_workspace"
    assert result["qualification"] == "not_assessed_by_this_tool"
    assert result["portable_approval_verification"] == "unavailable"
    assert result["plan_bindings"] == [binding_projection(plan)]
    refute result["bindings_truncated"]
    refute Jason.encode!(result) =~ @private_text
    refute Map.has_key?(result, "files")
    refute Map.has_key?(result, "spec")
    refute Map.has_key?(result, "rules")
  end

  test "legacy eligibility is explicitly unbound and cannot imply company-plan approval" do
    assert {:ok, artifact} = Harnesses.build()
    assert {:ok, result} = Tools.call(@package, %{"digest" => artifact["digest"]})
    assert result["eligible"]
    assert result["provenance_scope"] == "unbound_legacy"
    assert result["plan_bindings"] == []
  end

  test "plan digests and package bindings are both capped at 20", ctx do
    first = plan(ctx.attrs)
    approve(first)
    artifact = build(first)

    for _ <- 1..20 do
      other = plan(ctx.attrs)
      insert_binding(other, artifact["digest"])
    end

    for index <- 1..20,
        do: insert_binding(first, Integer.to_string(index, 16) |> String.pad_leading(64, "0"))

    assert {:ok, package} = Tools.call(@package, %{"digest" => artifact["digest"]})
    assert length(package["plan_bindings"]) == 20
    assert package["bindings_truncated"]
    assert {:ok, plan} = Tools.call(@plans, %{"plan_id" => first["id"]})
    assert length(plan["artifact_digests"]) == 20
    assert plan["artifacts_truncated"]
  end

  test "foreign IDs, malformed references and extra arguments fail without reflecting input",
       ctx do
    foreign = foreign_plan(ctx.attrs)
    assert {:error, :not_found} = Tools.call(@plans, %{"plan_id" => foreign.id})
    assert {:error, :not_found} = Tools.call(@plans, %{"plan_id" => Ecto.UUID.generate()})

    for arguments <- [
          %{"plan_id" => "not-a-uuid"},
          %{"plan_id" => Ecto.UUID.generate(), "limit" => 1},
          %{"limit" => 21},
          %{"limit" => false},
          %{"workspace_id" => "foreign"},
          [],
          nil
        ],
        do: assert({:error, :invalid_arguments} = Tools.call(@plans, arguments))

    for arguments <- [
          %{},
          %{"digest" => String.duplicate("A", 64)},
          %{"digest" => String.duplicate("0", 63)},
          %{"digest" => "../../access-token"},
          %{"digest" => String.duplicate("0", 64), "root" => ctx.root},
          %{"digest" => false},
          nil
        ],
        do: assert({:error, :invalid_arguments} = Tools.call(@package, arguments))

    assert {:error, :package_unavailable} =
             Tools.call(@package, %{"digest" => String.duplicate("0", 64)})
  end

  test "missing and tampered package payloads produce the same safe tool failure", ctx do
    plan = plan(ctx.attrs)
    approve(plan)
    artifact = build(plan)

    File.write!(
      Path.join([ctx.root, "artifacts", artifact["digest"], "payload", "AGENTS.md"]),
      "TAMPERED_PRIVATE_SENTINEL"
    )

    assert {:error, :package_unavailable} =
             Tools.call(@package, %{"digest" => artifact["digest"]})
  end

  test "successful and failed tools do not mutate company, evidence, audit or artifact state",
       ctx do
    plan = plan(ctx.attrs)
    approve(plan)
    artifact = build(plan)
    assert {:ok, before} = Privacy.inventory()
    bytes = artifact_files(ctx.root)
    assert {:ok, _} = Tools.call(@search, %{"query" => "authentication"})
    assert {:ok, _} = Tools.call(@plans, %{})
    assert {:ok, _} = Tools.call(@plans, %{"plan_id" => plan["id"]})
    assert {:ok, _} = Tools.call(@package, %{"digest" => artifact["digest"]})
    assert {:error, :not_found} = Tools.call(@plans, %{"plan_id" => Ecto.UUID.generate()})
    assert {:error, :unknown_tool} = Tools.call("harnessforge_approve", %{})
    assert {:ok, ^before} = Privacy.inventory()
    assert artifact_files(ctx.root) == bytes
  end

  defp repository(name, extra) do
    assert {:ok, repository} =
             Company.create_repository(
               Map.merge(
                 %{
                   "identity" => "example/#{name}",
                   "name" => name,
                   "purpose" => @private_text,
                   "owner" => "Synthetic platform team"
                 },
                 extra
               )
             )

    repository
  end

  defp plan(attrs) do
    assert {:ok, plan} = Company.create_plan(attrs)
    plan
  end

  defp decision(dto, action),
    do: %{
      "actor" => "synthetic-mcp-test",
      "decision" => action,
      "expected_revision_hash" => dto["revision_hash"]
    }

  defp approve(plan),
    do: assert({:ok, _} = Company.decide_plan(plan["id"], decision(plan, "approve")))

  defp build(plan) do
    assert {:ok, artifact} = Harnesses.build_plan(plan["id"], plan["revision_hash"])
    artifact
  end

  defp binding_projection(plan),
    do: %{"plan_id" => plan["id"], "plan_revision_hash" => plan["revision_hash"]}

  defp insert_binding(plan, digest) do
    Repo.insert!(%ArtifactBinding{
      workspace_id: Store.workspace(),
      plan_id: plan["id"],
      plan_revision_hash: plan["revision_hash"],
      artifact_digest: digest,
      inserted_at: Store.now()
    })
  end

  defp foreign_repository do
    Repo.insert!(%Repository{
      workspace_id: Ecto.UUID.generate(),
      payload: %{
        "identity" => "foreign/identity",
        "name" => "FOREIGN_CATALOGUE_SENTINEL",
        "owner" => "Foreign workspace",
        "capabilities" => ["Authentication"]
      },
      content_hash: String.duplicate("f", 64)
    })
  end

  defp foreign_plan(attrs) do
    id = Ecto.UUID.generate()

    Repo.insert!(%Plan{
      id: id,
      workspace_id: Ecto.UUID.generate(),
      family_id: id,
      payload: attrs,
      snapshot: %{"private" => "FOREIGN_PLAN_SENTINEL"},
      revision_hash: String.duplicate("f", 64),
      inserted_at: Store.now()
    })
  end

  defp assert_redacted_package(artifact, code) do
    assert {:ok, result} = Tools.call(@package, %{"digest" => artifact["digest"]})

    assert result == %{
             "digest" => artifact["digest"],
             "integrity" => "verified",
             "eligible" => false,
             "blocker_code" => code,
             "next_action" => "review_current_inputs",
             "qualification" => "not_assessed_by_this_tool",
             "portable_approval_verification" => "unavailable"
           }
  end

  defp artifact_files(root) do
    Path.wildcard(Path.join([root, "artifacts", "**", "*"]))
    |> Enum.filter(&File.regular?/1)
    |> Map.new(&{Path.relative_to(&1, root), File.read!(&1)})
  end
end
