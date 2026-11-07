defmodule HarnessForge.CompanySetupSessionsTest do
  use HarnessForge.DataCase, async: false
  alias HarnessForge.{Audit, Company, Evidence, Goals, Repo, Workspaces}
  alias HarnessForge.Company.{SetupSession, SetupSessions}
  alias HarnessForge.Evidence.{Corpora, Store}

  setup do
    previous = {Workspaces.root(), Workspaces.current_id()}
    root = Path.join(File.cwd!(), "tmp/setup-sessions-#{Ecto.UUID.generate()}")
    File.mkdir_p!(Path.join(root, "evidence"))
    Application.put_env(:harness_forge, :workspace_root, root)
    Application.put_env(:harness_forge, :workspace_id, Ecto.UUID.generate())

    on_exit(fn ->
      Application.put_env(:harness_forge, :workspace_root, elem(previous, 0))
      Application.put_env(:harness_forge, :workspace_id, elem(previous, 1))
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "create is explicit and saved records reopen across fresh authorization contexts" do
    assert {:ok, []} = SetupSessions.list(%{}, caller())

    assert {:error, %{"code" => "not_found"}} =
             SetupSessions.get(%{"id" => Ecto.UUID.generate()}, caller())

    assert {:ok, created} = SetupSessions.create(%{}, caller())
    assert created["version"] == 1
    assert created["step"] == "outcome"
    assert created["reference_status"]["fields"]["measurement"] == "unknown"
    assert created["next_action"]["focus"] == "setup-profile"

    assert Enum.sort(Map.keys(created)) ==
             ~w(draft id next_action reference_status selection step steps updated_at version)

    assert {:ok, ^created} = SetupSessions.get(%{"id" => created["id"]}, caller("c", "d"))
    record = Repo.get!(SetupSession, created["id"])
    assert record.workspace_id == Store.workspace()
    assert record.owner == "local-operator"
    assert record.schema_version == 1
    assert record.payload["operation_refs"] == []
    assert record.payload["decision_refs"] == []
    assert {:ok, [metadata]} = SetupSessions.list(%{}, caller())
    assert Enum.sort(Map.keys(metadata)) == ~w(id step updated_at version)
    refute Map.has_key?(metadata, "draft")
  end

  test "draft saves enforce UTF-8 byte bounds and preserve other acknowledged notes" do
    session = create()

    assert {:ok, first} =
             command(session, "save", %{"draft" => %{"scope_note" => "Preserve scope"}})

    assert {:ok, second} =
             command(first, "save", %{"draft" => %{"outcome_note" => String.duplicate("é", 1024)}})

    assert second["draft"]["scope_note"] == "Preserve scope"
    assert byte_size(second["draft"]["outcome_note"]) == 2048

    for draft <- [
          %{"outcome_note" => String.duplicate("é", 1025)},
          %{"outcome_note" => <<255>>},
          %{"outcome_note" => 3},
          %{"token" => "secret"},
          %{"completed" => true}
        ] do
      assert {:error, %{"code" => "invalid_input"}} = command(second, "save", %{"draft" => draft})
    end

    assert {:ok, ^second} = SetupSessions.get(%{"id" => second["id"]}, caller())
  end

  test "latest-session listing is bounded ordered metadata without draft hydration" do
    sessions = Enum.map(1..22, fn _ -> create() end)

    Repo.query!(
      "UPDATE setup_sessions SET updated_at='2026-01-01T00:00:00.000000Z' WHERE workspace_id=?",
      [Store.workspace()]
    )

    assert {:ok, rows} = SetupSessions.list(%{}, caller())
    expected = sessions |> Enum.map(& &1["id"]) |> Enum.sort(:desc) |> Enum.take(20)
    assert Enum.map(rows, & &1["id"]) == expected
    assert Enum.all?(rows, &(Enum.sort(Map.keys(&1)) == ~w(id step updated_at version)))
  end

  test "current outcome selections persist as exact pins without source bodies or inferred measurements",
       ctx do
    f = fixture(ctx.root)
    session = create()
    assert {:ok, selected} = command(session, "change", %{"selection" => f.selection})
    assert Map.take(selected["selection"], ~w(profile project repository goal)) == f.selection
    assert selected["next_action"]["code"] == "continue"
    assert selected["reference_status"]["fields"]["measurement"] == "unknown"
    assert {:ok, ^selected} = SetupSessions.get(%{"id" => selected["id"]}, caller("e", "f"))
    assert {:ok, scope} = command(selected, "continue", %{})
    assert scope["step"] == "scope"
    assert scope["next_action"]["focus"] == "setup-corpus"
    refute Jason.encode!(scope) =~ "SYNTHETIC_SOURCE_BODY_CANARY"
    refute Map.has_key?(scope, "scope_pin")
    assert {:ok, cleared} = command(scope, "change", %{"selection" => %{"goal" => nil}})
    assert Enum.all?(cleared["selection"], fn {_, value} -> is_nil(value) end)
    assert {:error, %{"code" => "stale_reference"}} = command(cleared, "continue", %{})
  end

  test "two tabs cannot overwrite a newer draft and stale navigation cannot advance twice", ctx do
    f = fixture(ctx.root)
    session = create()
    assert {:ok, saved} = command(session, "save", %{"draft" => %{"outcome_note" => "Tab one"}})

    assert {:error, %{"code" => "conflict", "current" => ^saved}} =
             command(session, "save", %{"draft" => %{"outcome_note" => "Tab two unsaved"}})

    assert {:ok, selected} = command(saved, "change", %{"selection" => f.selection})
    assert {:ok, scope} = command(selected, "continue", %{})

    assert {:error, %{"code" => "conflict", "current" => ^scope}} =
             command(selected, "continue", %{})

    assert scope["step"] == "scope"
    assert scope["draft"]["outcome_note"] == "Tab one"
  end

  test "concurrent exact-version commands produce one saved result and one authorized conflict" do
    session = create()

    tasks =
      for note <- ["Concurrent A", "Concurrent B"],
          do:
            Task.async(fn ->
              command(session, "save", %{"draft" => %{"outcome_note" => note}})
            end)

    results = Enum.map(tasks, &Task.await(&1, 5_000))
    assert [{:ok, saved}] = Enum.filter(results, &match?({:ok, _}, &1))

    assert [{:error, %{"code" => "conflict", "current" => ^saved}}] =
             Enum.filter(results, &match?({:error, _}, &1))

    assert saved["version"] == 2
    assert {:ok, ^saved} = SetupSessions.get(%{"id" => session["id"]}, caller())
  end

  test "caller shape, authorization, workspace and owner are checked without foreign existence disclosure" do
    session = create()
    denied = Keyword.put(caller(), :authorize, fn -> false end)

    assert {:error, %{"code" => "unauthorized"}} =
             SetupSessions.get(%{"id" => session["id"]}, denied)

    assert {:error, %{"code" => "unauthorized"}} =
             SetupSessions.list(%{}, Keyword.put(caller(), :owner, "forged"))

    assert {:error, %{"code" => "unauthorized"}} =
             SetupSessions.create(%{}, %{"authorize" => true})

    previous = Store.workspace()
    Application.put_env(:harness_forge, :workspace_id, Ecto.UUID.generate())

    try do
      assert {:error, %{"code" => "not_found"}} =
               SetupSessions.get(%{"id" => session["id"]}, caller())

      assert {:ok, []} = SetupSessions.list(%{}, caller())
    after
      Application.put_env(:harness_forge, :workspace_id, previous)
    end

    Repo.query!("UPDATE setup_sessions SET owner='another-local-principal' WHERE id=?", [
      session["id"]
    ])

    assert {:error, %{"code" => "not_found"}} =
             SetupSessions.get(%{"id" => session["id"]}, caller())
  end

  test "forged authority, owner and unknown command fields are rejected before persistence" do
    session = create()

    for attrs <- [
          %{"owner" => "someone"},
          %{"workspace_id" => Store.workspace()},
          %{"step" => "release"}
        ] do
      assert {:error, %{"code" => "invalid_input"}} = SetupSessions.create(attrs, caller())
    end

    for selection <- [
          %{"operation_refs" => []},
          %{
            "goal" => %{
              "id" => Ecto.UUID.generate(),
              "content_hash" => String.duplicate("a", 64),
              "approved" => true
            }
          },
          %{"scope_pin" => %{}},
          %{profile: nil}
        ] do
      assert {:error, %{"code" => "invalid_input"}} =
               command(session, "change", %{"selection" => selection})
    end

    envelope = %{
      "id" => session["id"],
      "expected_version" => 1,
      "command" => "continue",
      "payload" => %{}
    }

    assert {:error, %{"code" => "invalid_input"}} =
             SetupSessions.command(Map.put(envelope, "owner", "forged"), caller())

    assert {:error, %{"code" => "invalid_input"}} =
             SetupSessions.command(Map.put(envelope, "command", "approve"), caller())

    assert {:error, %{"code" => "invalid_input"}} =
             SetupSessions.command(Map.put(envelope, "expected_version", "1"), caller())

    assert {:ok, ^session} = SetupSessions.get(%{"id" => session["id"]}, caller())
  end

  test "repository membership and goal assignment reject otherwise current forged reference combinations",
       ctx do
    f = fixture(ctx.root)

    {:ok, other} =
      Company.create_repository(%{
        "identity" => "synthetic/other",
        "name" => "Other",
        "purpose" => "Fixture",
        "owner" => "Synthetic"
      })

    {:ok, other_goal} =
      Goals.add_goal(%{
        "title" => "Unassigned",
        "owner" => "Synthetic",
        "acceptance" => "Unassigned fixture"
      })

    for selection <- [
          Map.put(f.selection, "repository", pin(other)),
          Map.put(f.selection, "goal", goal_pin(other_goal)),
          put_in(f.selection, ["project", "content_hash"], String.duplicate("0", 64)),
          Map.put(f.selection, "profile", %{
            "id" => Ecto.UUID.generate(),
            "content_hash" => f.profile["content_hash"]
          })
        ] do
      session = create()

      assert {:error, %{"code" => "stale_reference"}} =
               command(session, "change", %{"selection" => selection})

      assert {:ok, ^session} = SetupSessions.get(%{"id" => session["id"]}, caller())
    end
  end

  test "catalogue drift retains historical pins and permits draft save/back/explicit repair",
       ctx do
    f = fixture(ctx.root)
    {:ok, selected} = command(create(), "change", %{"selection" => f.selection})
    {:ok, scope} = command(selected, "continue", %{})

    assert {:ok, updated} =
             Company.update_project(
               f.project["id"],
               Map.merge(f.project["payload"], %{
                 "name" => "Changed project",
                 "expected_content_hash" => f.project["content_hash"]
               })
             )

    assert {:ok, stale} = SetupSessions.get(%{"id" => scope["id"]}, caller())
    assert stale["reference_status"]["fields"]["project"] == "stale"
    assert stale["selection"]["project"] == f.selection["project"]
    assert {:error, %{"code" => "stale_reference"}} = command(stale, "continue", %{})

    assert {:ok, saved} =
             command(stale, "save", %{"draft" => %{"outcome_note" => "Repair later"}})

    assert {:ok, back} = command(saved, "back", %{})
    assert back["step"] == "outcome"

    assert {:ok, repaired} =
             command(back, "change", %{
               "selection" => Map.put(f.selection, "project", pin(updated))
             })

    assert repaired["reference_status"]["fields"]["project"] == "current"
    assert repaired["draft"]["outcome_note"] == "Repair later"
  end

  test "source revocation redacts affected references and explicit clearing remains possible",
       ctx do
    f = fixture(ctx.root)
    {:ok, selected} = command(create(), "change", %{"selection" => f.selection})
    assert {:ok, _} = Evidence.revoke_source(f.source["id"])
    assert {:ok, revoked} = SetupSessions.get(%{"id" => selected["id"]}, caller())
    assert revoked["reference_status"]["fields"]["profile"] == "unavailable"
    assert revoked["selection"]["profile"] == nil
    assert revoked["selection"]["project"] == nil
    refute Jason.encode!(revoked) =~ "SYNTHETIC_SOURCE_BODY_CANARY"
    assert {:error, %{"code" => "stale_reference"}} = command(revoked, "continue", %{})
    assert {:ok, cleared} = command(revoked, "change", %{"selection" => %{}})
    assert Enum.all?(cleared["selection"], fn {_, value} -> is_nil(value) end)
  end

  test "current corpus declarations open only an unavailable later shell without dispatch or decisions",
       ctx do
    f = scope_fixture(fixture(ctx.root))
    before = domain_counts()
    {:ok, selected} = command(create(), "change", %{"selection" => f.selection})

    assert Repo.get!(SetupSession, selected["id"]).payload["scope_pin"]["scope"]["corpus_id"] ==
             f.corpus["id"]

    {:ok, scope} = command(selected, "continue", %{})
    assert scope["reference_status"]["status"] == "current"
    assert {:ok, shell} = command(scope, "continue", %{})
    assert shell["step"] == "understanding"
    assert shell["next_action"]["code"] == "capability_unavailable"
    assert Enum.all?(Enum.drop(shell["steps"], 2), &(&1["state"] == "capability_unavailable"))
    assert {:error, %{"code" => "capability_unavailable"}} = command(shell, "continue", %{})
    assert domain_counts() == before
    assert {:ok, back} = command(shell, "back", %{})
    assert back["step"] == "scope"
  end

  test "changed generations stay stale without poisoning repair transactions", ctx do
    f = scope_fixture(fixture(ctx.root))
    {:ok, selected} = command(create(), "change", %{"selection" => f.selection})
    {:ok, scope} = command(selected, "continue", %{})
    {:ok, shell} = command(scope, "continue", %{})
    assert :ok = Corpora.advance(f.corpus["id"])
    assert {:ok, stale} = SetupSessions.get(%{"id" => shell["id"]}, caller())
    assert stale["reference_status"]["fields"]["corpus_id"] == "stale"
    assert stale["reference_status"]["fields"]["declaration"] == "stale"
    assert stale["selection"]["declaration"] == f.selection["declaration"]
    assert {:ok, back} = command(stale, "back", %{})

    assert {:ok, draft} =
             command(back, "save", %{"draft" => %{"scope_note" => "Acknowledge changed capture"}})

    assert {:error, %{"code" => "stale_reference"}} = command(draft, "continue", %{})

    assert {:ok, repaired} =
             command(draft, "change", %{"selection" => Map.put(f.selection, "declaration", nil)})

    assert repaired["reference_status"]["fields"]["corpus_id"] == "current"
    assert repaired["reference_status"]["fields"]["declaration"] == "missing"
  end

  test "corpus-only selection stays incomplete and forged declarations never become current",
       ctx do
    f = scope_fixture(fixture(ctx.root))

    assert {:ok, partial} =
             command(create(), "change", %{"selection" => %{"corpus_id" => f.corpus["id"]}})

    assert partial["reference_status"]["fields"]["corpus_id"] == "missing"
    assert Repo.get!(SetupSession, partial["id"]).payload["scope_pin"] == nil
    forged = put_in(f.selection, ["declaration", "digest"], String.duplicate("0", 64))

    assert {:error, %{"code" => "stale_reference"}} =
             command(partial, "change", %{"selection" => forged})

    assert {:ok, ^partial} = SetupSessions.get(%{"id" => partial["id"]}, caller())
  end

  test "a successor declaration never silently rebinds the acknowledged declaration", ctx do
    f = scope_fixture(fixture(ctx.root))
    {:ok, selected} = command(create(), "change", %{"selection" => f.selection})

    {:ok, context} =
      Corpora.requirements_context(
        f.corpus["id"],
        f.project["id"],
        f.goal["id"],
        Goals.content_hash(f.goal),
        caller()
      )

    assert {:ok, successor} =
             Corpora.declare_requirements(
               f.corpus["id"],
               context["expected"],
               %{
                 "project_id" => f.project["id"],
                 "goal_id" => f.goal["id"],
                 "primary_connection_id" => f.connection["id"],
                 "entries" => [
                   %{
                     "connection_id" => f.connection["id"],
                     "requirement" => "required",
                     "capture_run_id" => nil,
                     "capture_revision" => nil
                   }
                 ]
               },
               caller()
             )

    assert {:ok, stale} = SetupSessions.get(%{"id" => selected["id"]}, caller())
    assert stale["selection"]["declaration"] == f.selection["declaration"]
    assert stale["reference_status"]["fields"]["declaration"] == "stale"

    assert {:ok, repaired} =
             command(stale, "change", %{
               "selection" =>
                 Map.put(f.selection, "declaration", Map.take(successor, ~w(id digest)))
             })

    assert repaired["reference_status"]["fields"]["declaration"] == "current"
  end

  test "a guarded reference error after corpus rebinding does not poison later draft repairs",
       ctx do
    f = scope_fixture(fixture(ctx.root))
    {:ok, selected} = command(create(), "change", %{"selection" => f.selection})
    {:ok, scope} = command(selected, "continue", %{})
    {:ok, replacement} = Corpora.create(%{"name" => "Explicit replacement corpus"}, caller())

    assert {:ok, _} =
             Company.bind_corpus(
               f.project["id"],
               replacement["id"],
               f.profile["content_hash"],
               f.project["content_hash"],
               caller()
             )

    assert {:ok, stale} = SetupSessions.get(%{"id" => scope["id"]}, caller())
    assert stale["selection"]["corpus_id"] == f.corpus["id"]
    assert stale["reference_status"]["fields"]["corpus_id"] == "stale"

    assert {:ok, saved} =
             command(stale, "save", %{"draft" => %{"scope_note" => "Repair explicit binding"}})

    assert {:ok, back} = command(saved, "back", %{})
    assert back["step"] == "outcome"
    assert back["draft"]["scope_note"] == "Repair explicit binding"
  end

  test "authorization loss after an update rolls the mutation and audit back" do
    session = create()
    {:ok, events_before} = Audit.list_events()

    caller =
      Keyword.put(caller(), :authorize, fn ->
        case Repo.query(
               "SELECT count(*) FROM setup_sessions WHERE id=? AND json_extract(payload,'$.draft.outcome_note')='REVOKE_INSIDE_TRANSACTION'",
               [session["id"]],
               log: false
             ) do
          {:ok, %{rows: [[0]]}} -> true
          _ -> false
        end
      end)

    envelope = %{
      "id" => session["id"],
      "expected_version" => 1,
      "command" => "save",
      "payload" => %{"draft" => %{"outcome_note" => "REVOKE_INSIDE_TRANSACTION"}}
    }

    assert {:error, %{"code" => "unauthorized"}} = SetupSessions.command(envelope, caller)
    assert {:ok, ^session} = SetupSessions.get(%{"id" => session["id"]}, caller())
    assert {:ok, ^events_before} = Audit.list_events()
  end

  test "database write and read failures are unavailable and preserve acknowledged state" do
    session = create()

    Repo.query!(
      "CREATE TRIGGER setup_test_refusal BEFORE UPDATE ON setup_sessions BEGIN SELECT RAISE(ABORT,'SYNTHETIC_PRIVATE_ERROR'); END"
    )

    try do
      assert {:error, %{"code" => "unavailable", "fields" => %{}}} =
               command(session, "save", %{"draft" => %{"scope_note" => "Unacknowledged"}})

      assert {:ok, ^session} = SetupSessions.get(%{"id" => session["id"]}, caller())
    after
      Repo.query!("DROP TRIGGER setup_test_refusal")
    end

    Repo.query!("ALTER TABLE setup_sessions RENAME TO unavailable_setup_sessions")

    try do
      assert {:error, %{"code" => "unavailable"}} = SetupSessions.list(%{}, caller())

      assert {:error, %{"code" => "unavailable"}} =
               SetupSessions.get(%{"id" => session["id"]}, caller())
    after
      Repo.query!("ALTER TABLE unavailable_setup_sessions RENAME TO setup_sessions")
    end
  end

  test "a workspace change inside authorization cannot redirect a request to another workspace" do
    session = create()
    previous = Store.workspace()

    caller =
      Keyword.put(caller(), :authorize, fn ->
        Application.put_env(:harness_forge, :workspace_id, "changed-workspace")
        true
      end)

    try do
      assert {:error, %{"code" => "unauthorized"}} =
               SetupSessions.get(%{"id" => session["id"]}, caller)
    after
      Application.put_env(:harness_forge, :workspace_id, previous)
    end

    assert {:ok, ^session} = SetupSessions.get(%{"id" => session["id"]}, caller())
  end

  defp create do
    assert {:ok, session} = SetupSessions.create(%{}, caller())
    session
  end

  defp command(session, command, payload),
    do:
      SetupSessions.command(
        %{
          "id" => session["id"],
          "expected_version" => session["version"],
          "command" => command,
          "payload" => payload
        },
        caller()
      )

  defp caller(fingerprint \\ "a", generation \\ "b"),
    do: [
      authorize: fn -> true end,
      session_fingerprint: String.duplicate(fingerprint, 64),
      view_generation: String.duplicate(generation, 32),
      reset_token: 0
    ]

  defp pin(record), do: Map.take(record, ~w(id content_hash))
  defp goal_pin(goal), do: %{"id" => goal["id"], "content_hash" => Goals.content_hash(goal)}

  defp fixture(root) do
    {:ok, connection} =
      Evidence.connect(%{
        "name" => "Synthetic handbook",
        "provider" => "local",
        "directory" => Path.join(root, "evidence")
      })

    {:ok, source} =
      Evidence.import_markdown(connection["id"], %{
        "external_id" => "handbook.md",
        "title" => "Synthetic handbook",
        "body" => "SYNTHETIC_SOURCE_BODY_CANARY"
      })

    {:ok, goal} =
      Goals.add_goal(%{
        "title" => "Review changes",
        "owner" => "Synthetic",
        "acceptance" => "A review is recorded"
      })

    {:ok, profile} =
      Company.save_profile(%{
        "name" => "Synthetic company",
        "source_ids" => [source["id"]],
        "goal_ids" => [goal["id"]]
      })

    {:ok, repository} =
      Company.create_repository(%{
        "identity" => "synthetic/service",
        "name" => "Synthetic service",
        "purpose" => "Fixture",
        "owner" => "Synthetic"
      })

    {:ok, project} =
      Company.create_project(%{
        "name" => "Synthetic project",
        "repository_ids" => [repository["id"]],
        "source_ids" => [source["id"]]
      })

    %{
      profile: profile,
      repository: repository,
      project: project,
      goal: goal,
      source: source,
      connection: connection,
      selection: %{
        "profile" => pin(profile),
        "project" => pin(project),
        "repository" => pin(repository),
        "goal" => goal_pin(goal)
      }
    }
  end

  defp scope_fixture(f) do
    {:ok, corpus} = Corpora.create(%{"name" => "Synthetic scoped setup"}, caller())

    {:ok, _} =
      Company.bind_corpus(
        f.project["id"],
        corpus["id"],
        f.profile["content_hash"],
        f.project["content_hash"],
        caller()
      )

    {:ok, context} =
      Corpora.requirements_context(
        corpus["id"],
        f.project["id"],
        f.goal["id"],
        Goals.content_hash(f.goal),
        caller()
      )

    {:ok, declaration} =
      Corpora.declare_requirements(
        corpus["id"],
        context["expected"],
        %{
          "project_id" => f.project["id"],
          "goal_id" => f.goal["id"],
          "primary_connection_id" => f.connection["id"],
          "entries" => [
            %{
              "connection_id" => f.connection["id"],
              "requirement" => "required",
              "capture_run_id" => nil,
              "capture_revision" => nil
            }
          ]
        },
        caller()
      )

    Map.merge(f, %{
      corpus: corpus,
      declaration: declaration,
      selection:
        Map.merge(f.selection, %{
          "corpus_id" => corpus["id"],
          "declaration" => Map.take(declaration, ~w(id digest))
        })
    })
  end

  defp domain_counts do
    Map.new(
      ~w(model_requests oban_jobs evidence_claims claim_decisions company_plans company_plan_decisions evaluation_runs release_approvals release_history),
      fn table ->
        %{rows: [[count]]} = Repo.query!("SELECT count(*) FROM " <> table)
        {table, count}
      end
    )
  end
end
