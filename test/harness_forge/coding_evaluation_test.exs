defmodule HarnessForge.CodingEvaluationTest.Upstream do
  import Plug.Conn
  def init(opts), do: opts

  def call(conn, options) do
    {owner, mode} = if is_tuple(options), do: options, else: {options, :success}

    case conn.request_path do
      "/api/tags" ->
        if mode == :pause_tags do
          send(owner, {:coding_tags_barrier, self()})

          receive do
            :release_fixture -> :ok
          after
            10_000 -> :ok
          end
        end

        json(conn, %{"models" => [%{"name" => "synthetic:fixture"}]})

      "/api/chat" ->
        {:ok, bytes, conn} = read_body(conn, length: 131_072)
        body = Jason.decode!(bytes)

        if mode == :pause_chat do
          send(owner, {:coding_chat_barrier, self()})

          receive do
            :release_fixture -> :ok
          after
            10_000 -> :ok
          end
        end

        send(owner, {:coding_fixture_request, body})
        history = body["messages"]
        count = Enum.count(history, &(&1["role"] == "tool"))
        clamp? = Enum.any?(history, &String.contains?(&1["content"] || "", "Implement Clamp"))

        source =
          if clamp?,
            do:
              "package utility\nfunc Clamp(value,lo,hi int) int { if value<lo {return lo}; if value>hi {return hi}; return value }\n",
            else:
              "package utility\nimport \"strings\"\nfunc ReverseWords(input string) string { words:=strings.Fields(input); for i,j:=0,len(words)-1;i<j;i,j=i+1,j-1 {words[i],words[j]=words[j],words[i]};return strings.Join(words,\" \") }\n"

        source =
          if mode == :forgery,
            do:
              "package utility\nimport \"os\"\nfunc init(){ os.Stdout.WriteString(\"[3,1,5,4,-5]\"); os.Exit(0) }\nfunc Clamp(value,lo,hi int) int {return value}\n",
            else: source

        message =
          if mode == :no_edit do
            %{
              "role" => "assistant",
              "content" => "Controlled no-edit fixture at http://127.0.0.1:#{conn.port}."
            }
          else
            case if((body["tools"] || []) == [], do: 99, else: count) do
              0 -> tool("read", %{"filePath" => "/candidate/utility.go"})
              1 -> tool("write", %{"filePath" => "/candidate/utility.go", "content" => source})
              _ -> %{"role" => "assistant", "content" => "Controlled protocol fixture completed."}
            end
          end

        json(conn, %{
          "done" => true,
          "done_reason" => "stop",
          "message" => message,
          "prompt_eval_count" => 10,
          "eval_count" => 10
        })

      _ ->
        send_resp(conn, 404, "")
    end
  end

  defp tool(name, args),
    do: %{
      "role" => "assistant",
      "content" => "",
      "tool_calls" => [%{"function" => %{"name" => name, "arguments" => args}}]
    }

  defp json(conn, value),
    do: conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(value))
end

defmodule HarnessForge.CodingEvaluationTest do
  use HarnessForge.DataCase, async: false
  alias HarnessForge.{Decisions, Demo, Evaluations, Evidence, Harnesses, Models, Workspaces}
  alias HarnessForge.Evaluation.TaskSuite
  alias HarnessForge.Execution.{Coding, CodingTransport, Docker}

  setup do
    previous = Application.fetch_env!(:harness_forge, :workspace_root)
    temporary = if :os.type() == {:unix, :darwin}, do: "/private/tmp", else: "/tmp"
    root = Path.join(temporary, "hf-coding-#{Ecto.UUID.generate()}")
    Application.put_env(:harness_forge, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:harness_forge, :workspace_root, previous)
      File.rm_rf!(root)
    end)

    {:ok, _} = Demo.load()
    {:ok, claims} = Evidence.list_claims()
    claim = Enum.find(claims, &(not String.starts_with?(&1["text"], "IGNORE")))

    {:ok, _} =
      Decisions.decide(claim["id"], %{
        "actor" => Workspaces.operator(),
        "decision" => "approve",
        "expected_revision_hash" => claim["revision_hash"]
      })

    {:ok, artifact} = Harnesses.build(%{"runtime_version" => Docker.version()})
    {:ok, artifact: artifact}
  end

  test "suite hashes include real fixtures and protected expectations" do
    assert TaskSuite.tasks() == ["clamp", "reverse_words"]
    identities = TaskSuite.identities()
    assert identities["suite_id"] == "synthetic-go-v1"
    assert identities["task_fixture_digest"] != identities["grader_digest"]
    assert :ok = TaskSuite.check("clamp", "[3,1,5,4,-5]\n")
    assert {:error, :objective_checks_failed} = TaskSuite.check("clamp", "[3,-2,8,9,-9]")
    assert {:error, :objective_checks_failed} = TaskSuite.check("clamp", "")
    assert {:error, :objective_checks_failed} = TaskSuite.check("clamp", "passed")

    assert {:error, :objective_checks_failed} =
             TaskSuite.check(
               "reverse_words",
               "[\"\",\"\",\"hello\",\"hello world\",\"a b c\",\"مرحبا 世界\"]"
             )

    assert {:ok, observation} =
             CodingTransport.decode_context(
               %{
                 "version" => "coding-transport-v2",
                 "route" => "desktop_loopback_proxy",
                 "endpoint" => "unix:///tmp/hf-profile-fixture.sock",
                 "daemon_id" => "synthetic-profile-daemon",
                 "workspace_id" => Workspaces.current_id(),
                 "run_id" => "11111111-1111-4111-8111-111111111111"
               },
               %{
                 workspace_id: Workspaces.current_id(),
                 run_id: "11111111-1111-4111-8111-111111111111"
               }
             )

    assert Coding.profile(observation)["proxy_config_digest"] != nil
    assert Coding.profile(observation)["network"]["gateway_mode_ipv4"] == "isolated"
  end

  test "missing model is an actual persisted external prerequisite", %{artifact: artifact} do
    assert {:ok, run} = Evaluations.run(artifact["digest"])
    assert run["outcome"] == "blocked"
    assert run["reason"] == "model_not_selected"
    refute run["runtime_qualified"]
    assert run["task_fixture_digest"] == TaskSuite.identities()["task_fixture_digest"]
    assert {:error, :evaluation_inapplicable} = Evaluations.applicability(artifact, run)
    assert {:ok, ^run} = Evaluations.get(run["id"])
  end

  test "model configuration and environment changes invalidate applicability", %{
    artifact: artifact
  } do
    {:ok, run} = Evaluations.run(artifact["digest"])
    {:ok, _} = Models.configure(%{"model" => "synthetic:fixture"})
    assert {:error, :evaluation_inapplicable} = Evaluations.applicability(artifact, run)
    assert {:ok, static} = Evaluations.run(artifact["digest"], kind: :static_integrity)
    assert :ok = Evaluations.applicability(artifact, static)
    assert {:error, :evaluation_identities_differ} = Evaluations.compare(run["id"], static["id"])
  end

  test "completed historical runtime rows allow authoring without Docker", %{artifact: artifact} do
    {:ok, run} = Evaluations.run(artifact["digest"], kind: :static_integrity)
    record = Repo.get!(HarnessForge.Evaluation.Run, run["id"])

    record
    |> Ecto.Changeset.change(
      result: Map.merge(run, %{"kind" => "runtime_smoke", "cleanup_status" => "complete"})
    )
    |> Repo.update!()

    unavailable_docker()
    assert :ok = Evaluations.reconcile()
  end

  test "unresolved runtime cleanup still fails closed without Docker", %{artifact: artifact} do
    {:ok, run} = Evaluations.run(artifact["digest"], kind: :static_integrity)
    record = Repo.get!(HarnessForge.Evaluation.Run, run["id"])

    record
    |> Ecto.Changeset.change(
      result:
        Map.merge(run, %{
          "kind" => "runtime_smoke",
          "outcome" => "running",
          "cleanup_status" => "pending"
        })
    )
    |> Repo.update!()

    unavailable_docker()
    assert {:error, :cleanup_failed} = Evaluations.reconcile()
    assert {:ok, observed} = Evaluations.get(run["id"])
    assert observed["cleanup_status"] == "cleanup_failed"
  end

  @tag :docker
  @tag timeout: 240_000
  @tag skip: System.get_env("HARNESSFORGE_DOCKER_TESTS") != "1"
  test "real pinned OpenCode edits fixtures through metered local protocol and protected isolated grading",
       %{artifact: artifact} do
    upstream =
      start_supervised!(
        {Bandit,
         [plug: {__MODULE__.Upstream, self()}, ip: {127, 0, 0, 1}, port: 0, startup_log: false]}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(upstream)

    {:ok, _} =
      Models.configure(%{
        "model" => "synthetic:fixture",
        "endpoint" => "http://127.0.0.1:#{port}"
      })

    assert {:ok, run} = Evaluations.run(artifact["digest"])
    assert run["outcome"] == "passed", inspect(run, pretty: true)
    assert run["runtime_qualified"]
    assert run["usage_status"] == "reported"
    assert run["model_requests"] >= 4
    assert run["cleanup_status"] == "complete"
    assert Enum.map(run["checks"], & &1["id"]) == TaskSuite.tasks()
    assert :ok = Evaluations.applicability(artifact, run)
    assert :ok = Coding.cleanup(run["id"])
    assert_received {:coding_fixture_request, _}
    # This establishes local protocol/container integration, never model quality.
  end

  @tag :docker
  @tag timeout: 240_000
  @tag skip: System.get_env("HARNESSFORGE_DOCKER_TESTS") != "1"
  test "current connection drift at completion cannot qualify the original pinned attempt", %{
    artifact: artifact
  } do
    configure_fixture(:pause_chat)
    task = Task.async(fn -> Evaluations.run(artifact["digest"]) end)
    assert_receive {:coding_chat_barrier, provider}, 45_000
    unavailable_docker()
    send(provider, :release_fixture)
    assert {:ok, run} = await_releasing_chat(task, 180_000)
    assert run["outcome"] == "inconclusive", inspect(run)
    assert run["reason"] == "coding_transport_changed"
    assert run["cleanup_status"] == "complete"
    refute run["runtime_qualified"]
    assert Repo.get!(HarnessForge.Evaluation.Run, run["id"]).execution_context != nil
    assert :ok = Coding.cleanup(run["id"])
  end

  @tag :docker
  @tag timeout: 180_000
  @tag skip: System.get_env("HARNESSFORGE_DOCKER_TESTS") != "1"
  test "forged success in candidate init is rejected before candidate execution", %{
    artifact: artifact
  } do
    configure_fixture(:forgery)
    assert {:ok, run} = Evaluations.run(artifact["digest"])
    assert run["outcome"] == "failed", inspect(run)
    assert run["reason"] == "candidate_subset_rejected"
    refute run["runtime_qualified"]
    assert run["cleanup_status"] == "complete"
  end

  @tag :docker
  @tag timeout: 180_000
  @tag skip: System.get_env("HARNESSFORGE_DOCKER_TESTS") != "1"
  test "failed protected grading preserves sanitized agent output without qualifying an unchanged candidate",
       %{artifact: artifact} do
    {:ok, config} = configure_fixture(:no_edit)

    assert {:ok, run} = Evaluations.run(artifact["digest"])
    assert run["outcome"] == "failed", inspect(run)
    assert run["reason"] == "protected_tests_failed"
    refute run["runtime_qualified"]
    assert run["cleanup_status"] == "complete"
    assert run["usage_status"] == "reported"
    assert run["model_requests"] > 0
    assert [%{"id" => "clamp", "outcome" => "failed", "evidence" => evidence}] = run["checks"]
    assert evidence["solver_stopped"]
    assert evidence["objective_checks"] == "unverified"
    assert evidence["candidate_after"] == evidence["candidate_before"]
    assert evidence["agent_output"] =~ "Controlled no-edit fixture at [REDACTED]"
    refute evidence["agent_output"] =~ config["endpoint"]
    assert byte_size(evidence["agent_output"]) <= 131_072
    assert evidence["grader_output"] =~ "[grader_failure stage=protected_tests exit=41]"
    assert evidence["grader_output"] =~ ~s("Action":"fail")
    assert String.valid?(evidence["grader_output"])
    assert byte_size(evidence["grader_output"]) < 65_536
  end

  @tag :docker
  @tag timeout: 180_000
  @tag skip: System.get_env("HARNESSFORGE_DOCKER_TESTS") != "1"
  test "trusted AST parser rejects effects and directives in actual isolated Go image" do
    alias HarnessForge.Execution.Command
    root = Path.join(Workspaces.root(), "attacks")
    File.mkdir_p!(root)

    sources = [
      "package utility\nimport \"os\"\nfunc init(){os.Stdout.WriteString(\"[3,1,5,4,-5]\");os.Exit(0)}\nfunc Clamp(v,l,h int)int{return v}",
      "package utility\nvar x=func()int{println(1);return 1}()\nfunc Clamp(v,l,h int)int{return v}",
      "package utility\n//go:linkname Clamp runtime.exit\nfunc Clamp(v,l,h int)int{return v}",
      "package utility\nfunc Clamp(v,l,h int)int{println(\"[3,1,5,4,-5]\");return v}",
      "package utility\nimport . \"strings\"\nfunc ReverseWords(s string)string{return TrimSpace(s)}",
      "package utility\nfunc Clamp(v,l,h int)int{go func(){}();return v}",
      "package utility\nfunc Clamp(v,l,h int)string{return \"forged\"}"
    ]

    Enum.with_index(sources, fn source, index ->
      File.write!(Path.join(root, "#{index}.go"), source)
    end)

    name = "hf-ast-" <> Ecto.UUID.generate()
    on_exit(fn -> Command.docker(["rm", "--force", name]) end)

    script =
      "cd /tmp; go build -o /tmp/guard /protected/ast_guard.go; /tmp/guard /protected/clamp/candidate/utility.go clamp; /tmp/guard /protected/reverse_words/candidate/utility.go reverse_words; for path in /attacks/*.go; do if /tmp/guard \"$path\" clamp; then exit 90; fi; done; printf 'trusted_ast_attacks_denied\\n'"

    assert {:ok, %{exit_status: 0, output: output}} =
             Command.docker(
               [
                 "run",
                 "--rm",
                 "--name",
                 name,
                 "--network",
                 "none",
                 "--user",
                 "65534:65534",
                 "--read-only",
                 "--cap-drop",
                 "ALL",
                 "--security-opt",
                 "no-new-privileges",
                 "--pids-limit",
                 "128",
                 "--memory",
                 "1g",
                 "--memory-swap",
                 "1g",
                 "--cpus",
                 "1",
                 "--tmpfs",
                 "/tmp:rw,exec,nosuid,nodev,size=512m,mode=1777",
                 "--env",
                 "HOME=/tmp",
                 "--env",
                 "GOCACHE=/tmp/cache",
                 "--env",
                 "GOPROXY=off",
                 "--env",
                 "GOTOOLCHAIN=local",
                 "--env",
                 "GOFLAGS=-p=1",
                 "--mount",
                 "type=bind,source=#{TaskSuite.root()},target=/protected,readonly",
                 "--mount",
                 "type=bind,source=#{root},target=/attacks,readonly",
                 "--entrypoint",
                 "/bin/sh",
                 Coding.grader_image(),
                 "-ec",
                 script
               ],
               90_000,
               65_536
             )

    assert output =~ "trusted_ast_attacks_denied"
    assert length(Regex.scan(~r/candidate_subset_rejected/, output)) == length(sources)
  end

  @tag timeout: 60_000
  test "provider availability completes before an attempt or resources are persisted", %{
    artifact: artifact
  } do
    configure_fixture(:pause_tags)
    unavailable_docker()
    task = Task.async(fn -> Evaluations.run(artifact["digest"]) end)
    assert_receive {:coding_tags_barrier, provider}, 10_000
    assert {:ok, []} = Evaluations.list_runs()
    assert Repo.aggregate(HarnessForge.Models.Request, :count) == 0
    send(provider, :release_fixture)
    assert {:ok, final} = Task.await(task, 15_000)
    assert final["execution_profile_id"] == "docker-coding-isolated-v2"
    assert final["reason"] == "local_docker_required"
    assert final["cleanup_status"] == "not_started"
    assert final["environment_profile_digest"] == nil
    assert {:ok, ^final} = Evaluations.get(final["id"])
  end

  @tag :docker
  @tag timeout: 120_000
  @tag skip: System.get_env("HARNESSFORGE_DOCKER_TESTS") != "1"
  test "cancel with an in-flight model request revokes relay and tears down before completion", %{
    artifact: artifact
  } do
    configure_fixture(:pause_chat)
    task = Task.async(fn -> Evaluations.run(artifact["digest"]) end)
    assert_receive {:coding_chat_barrier, provider}, 45_000
    {:ok, [running]} = Evaluations.list_runs()
    cancel = Task.async(fn -> Evaluations.cancel(running["id"]) end)
    assert Task.yield(cancel, 100) == nil
    send(provider, :release_fixture)
    assert {:ok, cancelled} = Task.await(cancel, 30_000)
    assert cancelled["outcome"] == "cancelled"
    assert cancelled["cleanup_status"] == "complete", inspect(cancelled)
    refute cancelled["runtime_qualified"]
    assert cancelled["usage_status"] == "reported"
    assert cancelled["model_requests"] == 1
    assert cancelled["input_tokens"] == 10
    assert cancelled["output_tokens"] == 10
    assert {:ok, final} = Task.await(task, 30_000)
    assert final["outcome"] == "cancelled"
    assert final["reason"] == cancelled["reason"]
    assert final["completed_at"] == cancelled["completed_at"]
    refute final["runtime_qualified"]
    assert final["usage_status"] == "reported"
    assert final["model_requests"] == 1
    assert {:ok, [request]} = Models.list_requests(running["id"])
    assert request["state"] == "completed"
    assert final["input_tokens"] == request["input_tokens"]
    assert final["output_tokens"] == request["output_tokens"]
    assert :ok = Coding.cleanup(running["id"])

    assert :undefined =
             :global.whereis_name(
               {HarnessForge.Execution.CodingSession, Workspaces.current_id(), running["id"]}
             )

    refute_receive {:coding_chat_barrier, _}, 100
  end

  @tag :docker
  @tag timeout: 120_000
  @tag skip: System.get_env("HARNESSFORGE_DOCKER_TESTS") != "1"
  test "declared one-second execution timeout tears down and never qualifies", %{
    artifact: artifact
  } do
    configure_fixture(:success)
    artifact = bounded_artifact(artifact, "timeout_seconds", 1)
    assert {:ok, run} = Evaluations.run(artifact["digest"])
    refute run["runtime_qualified"]
    assert run["outcome"] in ["failed", "blocked", "timed_out"]
    assert run["cleanup_status"] == "complete", inspect(run)
    assert {:ok, []} = Models.list_requests(run["id"])
    assert :ok = Coding.cleanup(run["id"])
  end

  @tag :docker
  @tag timeout: 120_000
  @tag skip: System.get_env("HARNESSFORGE_DOCKER_TESTS") != "1"
  test "declared one-turn budget limits actual shared runtime requests", %{artifact: artifact} do
    configure_fixture(:success)
    artifact = bounded_artifact(artifact, "max_turns", 1)
    assert {:ok, run} = Evaluations.run(artifact["digest"])
    assert {:ok, requests} = Models.list_requests(run["id"])
    assert length(requests) <= 1
    refute run["runtime_qualified"]
    refute run["outcome"] == "passed"
    assert run["cleanup_status"] == "complete", inspect(run)
  end

  @tag :docker
  @tag skip: System.get_env("HARNESSFORGE_DOCKER_TESTS") != "1"
  test "startup retries cancelled pending cleanup and preserves cancellation", %{
    artifact: artifact
  } do
    alias HarnessForge.Evaluation.Run
    configure_fixture(:success)
    {:ok, run} = Evaluations.run(artifact["digest"])
    record = Repo.get!(Run, run["id"])

    record
    |> Ecto.Changeset.change(
      result: Map.merge(run, %{"outcome" => "cancelled", "cleanup_status" => "pending"})
    )
    |> Repo.update!()

    assert :ok = Evaluations.reconcile()
    assert {:ok, result} = Evaluations.get(run["id"])
    assert result["outcome"] == "cancelled"
    assert result["cleanup_status"] == "complete"
    refute result["runtime_qualified"]
  end

  defp unavailable_docker do
    previous = Map.new(["DOCKER_HOST", "DOCKER_CONTEXT"], &{&1, System.get_env(&1)})
    System.put_env("DOCKER_HOST", "tcp://127.0.0.1:1")
    System.delete_env("DOCKER_CONTEXT")

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end)
    end)
  end

  defp await_releasing_chat(task, timeout) do
    receive do
      {:coding_chat_barrier, provider} ->
        send(provider, :release_fixture)
        await_releasing_chat(task, timeout)

      {ref, result} when ref == task.ref ->
        Process.demonitor(ref, [:flush])
        result
    after
      timeout -> flunk("coding attempt did not complete")
    end
  end

  defp configure_fixture(mode) do
    upstream =
      start_supervised!(
        {Bandit,
         [
           plug: {__MODULE__.Upstream, {self(), mode}},
           ip: {127, 0, 0, 1},
           port: 0,
           startup_log: false
         ]}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(upstream)

    {:ok, _} =
      Models.configure(%{
        "model" => "synthetic:fixture",
        "endpoint" => "http://127.0.0.1:#{port}"
      })
  end

  defp bounded_artifact(artifact, key, value) do
    spec = put_in(artifact["spec"], ["spec", "execution", key], value)
    {:ok, bounded} = HarnessForge.Compiler.compile(spec)
    {:ok, _} = HarnessForge.Artifacts.publish(bounded)
    bounded
  end
end
