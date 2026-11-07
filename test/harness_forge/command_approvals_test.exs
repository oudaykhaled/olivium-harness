defmodule HarnessForge.CommandApprovalsTest do
  use HarnessForge.DataCase, async: false
  alias HarnessForge.{Audit, Company, Contracts, Evidence, Harnesses, Models, Workspaces}
  alias HarnessForge.CommandApprovalsFixture, as: ApprovalFixture
  alias HarnessForge.CompanyAssessmentFixture
  alias HarnessForge.CodingDockerFixture, as: DockerFixture
  alias HarnessForge.Execution.{CommandApproval, CommandApprovals}

  setup do
    previous =
      Map.new([:workspace_id, :workspace_root], &{&1, Application.get_env(:harness_forge, &1)})

    fixture = DockerFixture.install!()
    root = Path.join(fixture.root, "workspace")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    Application.put_env(:harness_forge, :workspace_id, Ecto.UUID.generate())
    Application.put_env(:harness_forge, :workspace_root, root)
    approval = ApprovalFixture.create!(root, transport_fixture: fixture)

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> Application.put_env(:harness_forge, key, value) end)
      DockerFixture.restore(fixture)
    end)

    Map.merge(approval, %{fixture: fixture, root: root})
  end

  test "a request is pending exact data and never implies native acceptance", c do
    attrs = payload(1)
    assert {:ok, dto} = request(c, attrs)

    assert Enum.sort(Map.keys(dto)) ==
             Enum.sort(
               ~w(id run_id artifact_digest profile_digest request_digest payload state expires_at decided_at consumed_at)
             )

    assert dto["run_id"] == c.run.id
    assert dto["artifact_digest"] == c.artifact["digest"]
    assert dto["profile_digest"] == c.run.result["environment_profile_digest"]
    assert dto["payload"] == attrs
    assert dto["state"] == "pending"
    assert is_nil(dto["decided_at"])
    assert is_nil(dto["consumed_at"])
    assert {:ok, polled} = CommandApprovals.poll(c.run.id, dto["id"], c.caller)
    assert polled["state"] == "pending"
    assert is_nil(polled["decision"])
    assert {:ok, [^dto]} = CommandApprovals.list(c.run.id, c.caller)
    assert DockerFixture.commands(c.fixture) == []
    assert {:ok, []} = Models.list_requests(c.run.id)
    refute inspect(Repo.get!(CommandApproval, dto["id"])) =~ attrs["command"]
  end

  test "payload validation is exact, bounded and does not accept authority fields", c do
    attrs = payload(1)

    invalid = [
      nil,
      [],
      Map.delete(attrs, "driver_nonce"),
      Map.put(attrs, :command, "x"),
      Map.put(attrs, "run_id", c.run.id),
      Map.put(attrs, "artifact_digest", c.artifact["digest"]),
      Map.put(attrs, "profile_digest", hash("other")),
      Map.put(attrs, "deadline", "later"),
      Map.put(attrs, "decision", "accept"),
      Map.put(attrs, "argv", ["sh"]),
      Map.put(attrs, "env", %{}),
      Map.put(attrs, "json_rpc_id", nil),
      Map.put(attrs, "json_rpc_id", true),
      Map.put(attrs, "json_rpc_id", 1.0),
      Map.put(attrs, "json_rpc_id", 9_007_199_254_740_992),
      Map.put(attrs, "json_rpc_id", String.duplicate("x", 129)),
      Map.put(attrs, "thread_id", ""),
      Map.put(attrs, "approval_id", false),
      Map.put(attrs, "environment_id", []),
      Map.put(attrs, "cwd", "/candidate/.."),
      Map.put(attrs, "command", "a\x00b"),
      Map.put(attrs, "command", "a\tb"),
      Map.put(attrs, "command", "a\rb"),
      Map.put(attrs, "command", String.duplicate("a", 4097)),
      Map.put(attrs, "command", <<255>>),
      Map.put(attrs, "driver_nonce", String.duplicate("A", 32)),
      Map.put(attrs, "driver_nonce", "short"),
      Map.put(attrs, "provider_response_id", ""),
      Map.put(attrs, "native_context_digest", "bad"),
      Map.put(attrs, "original_arguments_digest", hash("wrong")),
      original(attrs, "[]"),
      original(attrs, "null"),
      original(attrs, "{\"a\":1,\"a\":2}"),
      original(attrs, "{" <> String.duplicate(" ", 8192) <> "}")
    ]

    for value <- invalid, do: assert({:error, :invalid_command_approval} = request(c, value))
    assert Repo.aggregate(CommandApproval, :count) == 0
    assert {:ok, dto} = request(c, Map.put(attrs, "command", "printf first\nprintf second"))
    assert dto["payload"]["command"] == "printf first\nprintf second"
  end

  test "server expiry is bounded and replay cannot extend the first deadline", c do
    for expires <- [
          nil,
          "later",
          DateTime.add(DateTime.utc_now(), -1, :second),
          DateTime.add(DateTime.utc_now(), 121, :second)
        ] do
      assert {:error, :invalid_command_approval} =
               CommandApprovals.request(c.run.id, payload(1), expires, c.caller)
    end

    expires = DateTime.add(DateTime.utc_now(), 30, :second)
    assert {:ok, first} = CommandApprovals.request(c.run.id, payload(1), expires, c.caller)

    assert {:ok, ^first} =
             CommandApprovals.request(
               c.run.id,
               payload(1),
               DateTime.add(expires, 30, :second),
               c.caller
             )

    assert Repo.aggregate(CommandApproval, :count) == 1
  end

  test "combined native payload allows up to 16 KiB but bounds escaped original arguments", c do
    command = String.duplicate("a", 4096)

    attrs =
      payload(1) |> Map.put("command", command) |> original(Jason.encode!(%{"cmd" => command}))

    assert byte_size(Contracts.canonical_json(attrs)) > 8192
    assert byte_size(Contracts.canonical_json(attrs)) <= 16384
    assert {:ok, stored} = request(c, attrs)
    assert stored["payload"] == attrs
    expanded = payload(2) |> original(Jason.encode!(%{"cmd" => String.duplicate("\\", 4000)}))
    assert byte_size(expanded["original_arguments"]) <= 8192
    assert byte_size(Contracts.canonical_json(expanded)) > 16384
    assert {:error, :invalid_command_approval} = request(c, expanded)
  end

  test "native identity replay binds every raw argument and native correlation field", c do
    attrs = payload(1)
    assert {:ok, first} = request(c, attrs)
    assert {:ok, ^first} = request(c, attrs)

    changed = [
      Map.put(attrs, "command", "printf changed"),
      Map.put(attrs, "item_id", "other-call"),
      Map.put(attrs, "provider_response_id", "other-response"),
      Map.put(attrs, "native_context_digest", hash("changed native callback")),
      original(attrs, "{ \"cmd\": \"printf synthetic\" }")
    ]

    for value <- changed, do: assert({:error, :command_approval_conflict} = request(c, value))
    assert Repo.aggregate(CommandApproval, :count) == 1
    assert {:ok, string_id} = request(c, payload("1"))
    refute string_id["id"] == first["id"]
    assert {:ok, repeated_command} = request(c, payload(2))
    assert repeated_command["state"] == "pending"
    refute repeated_command["id"] == first["id"]
  end

  test "fresh driver nonce isolates restarted native RPC IDs and never resumes an old acceptance",
       c do
    attrs = payload(42)
    assert {:ok, first} = request(c, attrs)
    assert {:ok, _} = CommandApprovals.decide(envelope(first, "accept_once"), c.caller)
    fresh = Map.put(attrs, "driver_nonce", String.duplicate("b", 32))
    assert {:ok, second} = request(c, fresh)
    refute second["id"] == first["id"]
    assert second["state"] == "pending"
    assert {:ok, %{"decision" => nil}} = CommandApprovals.poll(c.run.id, second["id"], c.caller)
    assert {:ok, ^second} = request(c, fresh)

    assert {:error, :command_approval_conflict} =
             request(c, Map.put(fresh, "command", "printf changed"))

    assert Repo.get!(CommandApproval, first["id"]).state == "accepted"
    assert Repo.get!(CommandApproval, second["id"]).state == "pending"
  end

  test "per-run bound counts terminal requests and permits only exact replay at capacity", c do
    rows =
      for id <- 1..32 do
        assert {:ok, dto} = request(c, payload(id))
        dto
      end

    assert {:error, :command_approval_limit} = request(c, payload(33))
    first = hd(rows)
    assert {:ok, _} = CommandApprovals.decide(envelope(first, "decline"), c.caller)
    assert {:error, :command_approval_limit} = request(c, payload(33))
    assert {:ok, replay} = request(c, payload(1))
    assert replay["id"] == first["id"]
    assert replay["state"] == "declined"
    assert {:ok, listed} = CommandApprovals.list(c.run.id, c.caller)
    assert length(listed) == 32
  end

  test "only strict true current operator authorization can view or mutate approval data", c do
    for caller <- [
          nil,
          [],
          [authorize: fn -> false end],
          [authorize: fn -> :ok end],
          [authorize: fn -> true end, actor: "claimed-owner"],
          [authorize: fn -> true end, authorize: fn -> true end],
          [authorize: fn -> raise "private callback detail" end],
          [authorize: fn -> throw(:private) end]
        ] do
      assert {:error, :command_approval_unauthorized} =
               CommandApprovals.request(c.run.id, payload(1), expiry(), caller)
    end

    assert Repo.aggregate(CommandApproval, :count) == 0
    assert {:ok, dto} = request(c, payload(1))
    no = [authorize: fn -> false end]
    assert {:error, :command_approval_unauthorized} = CommandApprovals.list(c.run.id, no)

    assert {:error, :command_approval_unauthorized} =
             CommandApprovals.poll(c.run.id, dto["id"], no)

    assert {:error, :command_approval_unauthorized} =
             CommandApprovals.decide(envelope(dto, "accept_once"), no)

    assert Repo.get!(CommandApproval, dto["id"]).state == "pending"
  end

  test "workspace, run, artifact and profile identity are server-owned", c do
    assert {:ok, dto} = request(c, payload(1))
    original_workspace = Workspaces.current_id()
    Application.put_env(:harness_forge, :workspace_id, Ecto.UUID.generate())

    assert {:error, :command_approval_run_unavailable} =
             CommandApprovals.poll(c.run.id, dto["id"], c.caller)

    Application.put_env(:harness_forge, :workspace_id, original_workspace)
    other = run(c.fixture, c.artifact)

    assert {:error, :command_approval_not_found} =
             CommandApprovals.poll(other.id, dto["id"], c.caller)

    for changes <- [
          %{"environment_profile_digest" => hash("forged")},
          %{"artifact_digest" => hash("other")},
          %{"execution_profile_id" => "docker-coding-isolated-v2"},
          %{"runtime_name" => "opencode"},
          %{"outcome" => "cancelled"}
        ] do
      Repo.update!(Ecto.Changeset.change(c.run, result: Map.merge(c.run.result, changes)))

      assert {:error, :command_approval_run_unavailable} =
               CommandApprovals.poll(c.run.id, dto["id"], c.caller)
    end

    Repo.update!(Ecto.Changeset.change(c.run, result: c.run.result))
    assert Repo.get!(CommandApproval, dto["id"]).state == "pending"
  end

  test "decision digest and envelope are exact, with no session acceptance or policy amendment",
       c do
    assert {:ok, dto} = request(c, payload(1))
    wanted = envelope(dto, "accept_once")

    for invalid <- [
          nil,
          [],
          Map.put(wanted, "actor", "claimed-owner"),
          Map.put(wanted, "session", true),
          Map.put(wanted, "decision", "acceptForSession"),
          Map.put(wanted, "decision", "acceptWithExecpolicyAmendment"),
          Map.put(wanted, "decision", true),
          Map.delete(wanted, "request_digest")
        ] do
      assert {:error, :invalid_command_approval} = CommandApprovals.decide(invalid, c.caller)
    end

    assert {:error, :command_approval_conflict} =
             CommandApprovals.decide(Map.put(wanted, "request_digest", hash("wrong")), c.caller)

    assert Repo.get!(CommandApproval, dto["id"]).state == "pending"
  end

  test "accept once is consumed before handoff and cannot be replayed", c do
    assert {:ok, dto} = request(c, payload(1))
    assert {:ok, accepted} = CommandApprovals.decide(envelope(dto, "accept_once"), c.caller)
    assert accepted["state"] == "accepted"
    assert Repo.get!(CommandApproval, dto["id"]).decision_owner == Workspaces.operator()
    assert {:ok, ^accepted} = CommandApprovals.decide(envelope(dto, "accept_once"), c.caller)

    assert {:error, :command_approval_already_decided} =
             CommandApprovals.decide(envelope(dto, "decline"), c.caller)

    assert {:ok, handoff} = CommandApprovals.poll(c.run.id, dto["id"], c.caller)
    assert handoff["state"] == "consumed"
    assert handoff["decision"] == "accept"

    assert %CommandApproval{state: "consumed", consumed_at: %DateTime{}} =
             Repo.get!(CommandApproval, dto["id"])

    assert {:ok, again} = CommandApprovals.poll(c.run.id, dto["id"], c.caller)
    assert again["decision"] == "decline"
    assert {:ok, _} = CommandApprovals.decide(envelope(dto, "accept_once"), c.caller)
    assert {:ok, still_consumed} = CommandApprovals.poll(c.run.id, dto["id"], c.caller)
    assert still_consumed["decision"] == "decline"
  end

  test "conflicting decisions and simultaneous polls have one CAS winner", c do
    assert {:ok, dto} = request(c, payload(1))

    outcomes =
      ["accept_once", "decline"]
      |> Enum.map(fn decision ->
        Task.async(fn -> CommandApprovals.decide(envelope(dto, decision), c.caller) end)
      end)
      |> Enum.map(&Task.await(&1, 10_000))

    assert Enum.count(outcomes, &match?({:ok, _}, &1)) == 1
    assert Enum.count(outcomes, &match?({:error, :command_approval_already_decided}, &1)) == 1
    assert {:ok, second} = request(c, payload(2))
    assert {:ok, _} = CommandApprovals.decide(envelope(second, "accept_once"), c.caller)

    polls =
      for _ <- 1..4,
          do: Task.async(fn -> CommandApprovals.poll(c.run.id, second["id"], c.caller) end)

    replies = Enum.map(polls, &Task.await(&1, 10_000))
    assert Enum.count(replies, &match?({:ok, %{"decision" => "accept"}}, &1)) == 1
    assert Enum.count(replies, &match?({:ok, %{"decision" => "decline"}}, &1)) == 3
  end

  test "decline is terminal and accepts no later replacement", c do
    assert {:ok, dto} = request(c, payload(1))
    assert {:ok, declined} = CommandApprovals.decide(envelope(dto, "decline"), c.caller)
    assert {:ok, ^declined} = CommandApprovals.decide(envelope(dto, "decline"), c.caller)

    assert {:error, :command_approval_already_decided} =
             CommandApprovals.decide(envelope(dto, "accept_once"), c.caller)

    assert {:ok, %{"decision" => "decline"}} =
             CommandApprovals.poll(c.run.id, dto["id"], c.caller)
  end

  test "expired pending and accepted requests decline without extending their deadline", c do
    for {id, accept?} <- [{1, false}, {2, true}] do
      assert {:ok, dto} =
               CommandApprovals.request(
                 c.run.id,
                 payload(id),
                 DateTime.add(DateTime.utc_now(), 1, :second),
                 c.caller
               )

      decided =
        if accept?,
          do: elem(CommandApprovals.decide(envelope(dto, "accept_once"), c.caller), 1),
          else: nil

      wait_until_expired(dto)

      assert {:error, :command_approval_expired} =
               CommandApprovals.decide(envelope(dto, "accept_once"), c.caller)

      assert {:ok, expired} = CommandApprovals.poll(c.run.id, dto["id"], c.caller)
      assert expired["state"] == "declined"
      assert expired["decision"] == "decline"
      assert expired["expires_at"] == dto["expires_at"]
      if accept?, do: assert(expired["decided_at"] == decided["decided_at"])
      assert {:ok, replay} = request(c, payload(id))
      assert replay["id"] == dto["id"]
      assert replay["state"] == "declined"
    end
  end

  test "a foreign recorded decision owner never produces acceptance", c do
    assert {:ok, dto} = request(c, payload(1))
    now = DateTime.utc_now()

    Repo.update_all(from(a in CommandApproval, where: a.id == ^dto["id"]),
      set: [
        state: "accepted",
        decided_at: now,
        decision_owner: "foreign-operator",
        updated_at: now
      ]
    )

    assert {:error, :command_approval_unavailable} =
             CommandApprovals.poll(c.run.id, dto["id"], c.caller)

    assert Repo.get!(CommandApproval, dto["id"]).state == "accepted"
  end

  test "source revocation withdraws accepted command and hides its command bytes", c do
    assert {:ok, dto} = request(c, payload(1))
    assert {:ok, _} = CommandApprovals.decide(envelope(dto, "accept_once"), c.caller)
    assert {:ok, _} = Evidence.revoke_source(c.source["id"])

    assert {:error, :command_approval_run_unavailable} =
             CommandApprovals.poll(c.run.id, dto["id"], c.caller)

    assert {:error, :command_approval_run_unavailable} = CommandApprovals.list(c.run.id, c.caller)
    assert Repo.get!(CommandApproval, dto["id"]).state == "accepted"
  end

  test "real company catalogue drift denies accepted command inside SQL without consuming it",
       c do
    f = CompanyAssessmentFixture.create!(c.root)

    attrs =
      Map.merge(f.plan_attrs, %{
        "name" => "approval-codex",
        "runtime" => "codex",
        "runtime_version" => "0.156.0"
      })

    assert {:ok, plan} = Company.create_plan(attrs)
    assert {:ok, plan} = Company.decide_plan(plan["id"], CompanyAssessmentFixture.decision(plan))
    assert {:ok, artifact} = Harnesses.build_plan(plan["id"], plan["revision_hash"])
    own = run(c.fixture, artifact)
    scope = %{c | run: own, artifact: artifact}
    assert {:ok, dto} = request(scope, payload(1))
    assert {:ok, _} = CommandApprovals.decide(envelope(dto, "accept_once"), c.caller)

    assert {:ok, _} =
             Company.update_repository(
               f.repository["id"],
               Map.merge(f.repository["payload"], %{
                 "name" => "Stale catalogue",
                 "expected_content_hash" => f.repository["content_hash"]
               })
             )

    assert {:error, :command_approval_run_unavailable} =
             CommandApprovals.poll(own.id, dto["id"], c.caller)

    assert Repo.get!(CommandApproval, dto["id"]).state == "accepted"
  end

  test "authorization loss inside the decision transaction rolls back its state and audit", c do
    assert {:ok, dto} = request(c, payload(1))

    caller = [
      authorize: fn ->
        not (Repo.in_transaction?() and Repo.get!(CommandApproval, dto["id"]).state == "accepted")
      end
    ]

    assert {:error, :command_approval_unauthorized} =
             CommandApprovals.decide(envelope(dto, "accept_once"), caller)

    assert Repo.get!(CommandApproval, dto["id"]).state == "pending"
    assert {:ok, events} = Audit.list_events()
    refute Enum.any?(events, &(&1["action"] == "command_approval.accepted"))
  end

  test "authorization loss after committed consumption returns no accept and cannot be retried",
       c do
    assert {:ok, dto} = request(c, payload(1))
    assert {:ok, _} = CommandApprovals.decide(envelope(dto, "accept_once"), c.caller)

    caller = [
      authorize: fn ->
        Repo.in_transaction?() or Repo.get!(CommandApproval, dto["id"]).state != "consumed"
      end
    ]

    assert {:error, :command_approval_unauthorized} =
             CommandApprovals.poll(c.run.id, dto["id"], caller)

    assert Repo.get!(CommandApproval, dto["id"]).state == "consumed"

    assert {:ok, %{"decision" => "decline"}} =
             CommandApprovals.poll(c.run.id, dto["id"], c.caller)
  end

  test "a deadline crossed after consumption commits never publishes an expired acceptance", c do
    assert {:ok, dto} =
             CommandApprovals.request(
               c.run.id,
               payload(1),
               DateTime.add(DateTime.utc_now(), 1, :second),
               c.caller
             )

    assert {:ok, _} = CommandApprovals.decide(envelope(dto, "accept_once"), c.caller)

    caller = [
      authorize: fn ->
        if not Repo.in_transaction?() and
             Repo.get!(CommandApproval, dto["id"]).state == "consumed",
           do: wait_until_expired(dto)

        true
      end
    ]

    assert {:error, :command_approval_expired} =
             CommandApprovals.poll(c.run.id, dto["id"], caller)

    assert Repo.get!(CommandApproval, dto["id"]).state == "consumed"

    assert {:ok, %{"decision" => "decline"}} =
             CommandApprovals.poll(c.run.id, dto["id"], c.caller)
  end

  test "audit is atomic metadata only, and the service never invokes the fake CLI or model", c do
    attrs = payload(1)
    assert {:ok, dto} = request(c, attrs)
    assert {:ok, _} = CommandApprovals.decide(envelope(dto, "accept_once"), c.caller)
    assert {:ok, %{"decision" => "accept"}} = CommandApprovals.poll(c.run.id, dto["id"], c.caller)
    assert {:ok, events} = Audit.list_events()
    events = Enum.filter(events, &String.starts_with?(&1["action"], "command_approval."))
    assert length(events) == 3

    for event <- events do
      assert Enum.sort(Map.keys(event["details"])) ==
               Enum.sort(
                 ~w(run_id approval_id artifact_digest profile_digest request_digest status)
               )

      refute Jason.encode!(event) =~ attrs["command"]
      refute Jason.encode!(event) =~ attrs["original_arguments"]
    end

    assert DockerFixture.commands(c.fixture) == []
    assert {:ok, []} = Models.list_requests(c.run.id)
  end

  test "audit insertion failure rolls back request creation", c do
    Repo.query!(
      "CREATE TEMP TRIGGER approval_audit_failure BEFORE INSERT ON audit_events WHEN NEW.action LIKE 'command_approval.%' BEGIN SELECT RAISE(ABORT,'fixture audit failure'); END"
    )

    try do
      assert {:error, :command_approval_unavailable} = request(c, payload(1))
      assert Repo.aggregate(CommandApproval, :count) == 0
    after
      Repo.query!("DROP TRIGGER approval_audit_failure")
    end
  end

  test "caller-owned SQL transaction cannot publish an uncommitted accepted handoff", c do
    assert {:ok, dto} = request(c, payload(1))

    assert {:ok, {:error, :command_approval_requires_outermost_transaction}} =
             Repo.transaction(fn ->
               CommandApprovals.decide(envelope(dto, "accept_once"), c.caller)
             end)

    assert {:ok, {:error, :command_approval_requires_outermost_transaction}} =
             Repo.transaction(fn -> CommandApprovals.poll(c.run.id, dto["id"], c.caller) end)

    assert Repo.get!(CommandApproval, dto["id"]).state == "pending"
  end

  defp payload(id) do
    ApprovalFixture.payload(%{"json_rpc_id" => id})
  end

  defp original(payload, args),
    do:
      payload
      |> Map.put("original_arguments", args)
      |> Map.put("original_arguments_digest", hash(args))

  defp request(c, payload), do: CommandApprovals.request(c.run.id, payload, expiry(), c.caller)
  defp expiry, do: DateTime.add(DateTime.utc_now(), 60, :second)

  defp envelope(dto, decision),
    do: Map.take(dto, ~w(run_id id request_digest)) |> Map.put("decision", decision)

  defp hash(bytes), do: Contracts.sha256(bytes)

  defp wait_until_expired(dto) do
    {:ok, time, _} = DateTime.from_iso8601(dto["expires_at"])
    Process.sleep(max(1, DateTime.diff(time, DateTime.utc_now(), :millisecond) + 20))
  end

  defp run(fixture, artifact), do: ApprovalFixture.create_run!(fixture, artifact)
end
