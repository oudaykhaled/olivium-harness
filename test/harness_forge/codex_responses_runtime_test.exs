defmodule HarnessForge.CodexResponsesRuntimeFixture do
  def tool,
    do: %{
      "type" => "function",
      "name" => "read_file",
      "parameters" => %{"type" => "object", "properties" => %{}}
    }

  def request(tools \\ []),
    do: %{
      "model" => "synthetic:fixture",
      "input" => [
        %{
          "role" => "user",
          "content" => [%{"type" => "input_text", "text" => "Public synthetic coding task"}]
        }
      ],
      "stream" => true,
      "store" => false,
      "max_output_tokens" => 128,
      "tools" => tools
    }

  def events(payload) do
    base = %{
      "id" => "resp_synthetic",
      "object" => "response",
      "status" => "in_progress",
      "model" => payload["model"],
      "output" => [],
      "usage" => nil,
      "store" => false,
      "background" => false,
      "error" => nil,
      "incomplete_details" => nil,
      "previous_response_id" => nil,
      "max_output_tokens" => payload["max_output_tokens"],
      "tools" => payload["tools"] || []
    }

    part = %{
      "type" => "output_text",
      "text" => "Synthetic complete response",
      "annotations" => [],
      "logprobs" => []
    }

    item = %{
      "id" => "msg_synthetic",
      "type" => "message",
      "status" => "completed",
      "role" => "assistant",
      "content" => [part]
    }

    final =
      Map.merge(base, %{
        "status" => "completed",
        "output" => [item],
        "usage" => %{"input_tokens" => 11, "output_tokens" => 7, "total_tokens" => 18}
      })

    [
      %{"type" => "response.created", "response" => base},
      %{"type" => "response.in_progress", "response" => base},
      %{
        "type" => "response.output_item.added",
        "output_index" => 0,
        "item" => %{item | "status" => "in_progress", "content" => []}
      },
      %{
        "type" => "response.content_part.added",
        "output_index" => 0,
        "item_id" => item["id"],
        "content_index" => 0,
        "part" => %{part | "text" => ""}
      },
      %{
        "type" => "response.output_text.delta",
        "output_index" => 0,
        "item_id" => item["id"],
        "content_index" => 0,
        "delta" => part["text"],
        "logprobs" => []
      },
      %{
        "type" => "response.output_text.done",
        "output_index" => 0,
        "item_id" => item["id"],
        "content_index" => 0,
        "text" => part["text"],
        "logprobs" => []
      },
      %{
        "type" => "response.content_part.done",
        "output_index" => 0,
        "item_id" => item["id"],
        "content_index" => 0,
        "part" => part
      },
      %{"type" => "response.output_item.done", "output_index" => 0, "item" => item},
      %{"type" => "response.completed", "response" => final}
    ]
  end

  def encode(events),
    do:
      events
      |> Enum.with_index()
      |> Enum.map_join(fn {event, index} ->
        "event: " <>
          event["type"] <>
          "\ndata: " <> Jason.encode!(Map.put(event, "sequence_number", index)) <> "\n\n"
      end)

  def command_events(payload, arguments) do
    text_events = events(payload)
    base = hd(text_events)["response"]

    call = %{
      "id" => "fc_native_command",
      "type" => "function_call",
      "status" => "completed",
      "call_id" => "call_native_command",
      "name" => "exec_command",
      "arguments" => arguments
    }

    final =
      Map.merge(base, %{
        "status" => "completed",
        "output" => [call],
        "usage" => %{"input_tokens" => 11, "output_tokens" => 7, "total_tokens" => 18}
      })

    Enum.take(text_events, 2) ++
      [
        %{
          "type" => "response.output_item.added",
          "output_index" => 0,
          "item" => %{call | "status" => "in_progress", "arguments" => ""}
        },
        %{
          "type" => "response.function_call_arguments.delta",
          "output_index" => 0,
          "item_id" => call["id"],
          "delta" => arguments
        },
        %{
          "type" => "response.function_call_arguments.done",
          "output_index" => 0,
          "item_id" => call["id"],
          "arguments" => arguments
        },
        %{"type" => "response.output_item.done", "output_index" => 0, "item" => call},
        %{"type" => "response.completed", "response" => final}
      ]
  end
end

defmodule HarnessForge.CodexResponsesRuntimeTest.Upstream do
  import Plug.Conn
  alias HarnessForge.CodexResponsesRuntimeFixture, as: F
  def init(opts), do: opts

  def call(conn, %{owner: owner, state: state}) do
    current = Agent.get(state, & &1)

    case conn.request_path do
      "/api/version" ->
        metadata(conn, %{"version" => current.version}, current, owner)

      "/api/tags" ->
        model = %{"name" => "synthetic:fixture", "digest" => current.digest}

        model =
          if current.mode == :remote,
            do: Map.put(model, "remote_host", "https://invalid.example"),
            else: model

        metadata(conn, %{"models" => [model]}, current, owner)

      "/api/show" ->
        metadata(
          conn,
          %{
            "capabilities" => ["completion", "tools"],
            "details" => %{"family" => "synthetic"}
          },
          current,
          owner
        )

      "/v1/responses" ->
        {:ok, body, conn} = read_body(conn)
        payload = Jason.decode!(body)
        send(owner, {:native_responses, payload, get_req_header(conn, "authorization"), self()})
        if current.inference_delay_ms > 0, do: Process.sleep(current.inference_delay_ms)

        if current.mode == :gate do
          receive do
            :release_response -> :ok
          after
            5_000 -> raise "test response gate was not released"
          end
        end

        events =
          if is_binary(current.command_arguments),
            do: F.command_events(payload, current.command_arguments),
            else: F.events(payload)

        events =
          case current.mode do
            :unknown ->
              List.update_at(events, -1, &put_in(&1, ["response", "usage"], nil))

            :failed ->
              List.update_at(events, -1, &Map.put(&1, "type", "response.failed"))

            :exhausted ->
              List.update_at(
                events,
                -1,
                &put_in(&1, ["response", "usage", "output_tokens"], payload["max_output_tokens"])
              )

            _ ->
              events
          end

        bytes = F.encode(events)
        bytes = if current.mode == :truncated, do: String.trim_trailing(bytes), else: bytes

        if current.mode == :final_metadata_drip,
          do: Agent.update(state, &%{&1 | metadata_mode: :drip})

        if current.mode == :redirect do
          conn |> put_resp_header("location", "https://invalid.example") |> send_resp(307, "")
        else
          conn |> put_resp_content_type("text/event-stream") |> send_resp(200, bytes)
        end

      _ ->
        send_resp(conn, 404, "")
    end
  end

  defp json(conn, body),
    do: conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(body))

  defp metadata(conn, body, current, owner) do
    case current.metadata_mode do
      :drip ->
        send(owner, {:metadata_started, conn.request_path, self()})
        conn = conn |> put_resp_content_type("application/json") |> send_chunked(200)
        # Bytes arrive more frequently than any test inactivity timeout. Only
        # the absolute deadline can stop this continuously progressing reader.
        conn =
          Enum.reduce_while(1..150, conn, fn _, conn ->
            case chunk(conn, " ") do
              {:ok, conn} ->
                Process.sleep(20)
                {:cont, conn}

              {:error, _} ->
                {:halt, conn}
            end
          end)

        case chunk(conn, Jason.encode!(body)) do
          {:ok, conn} -> conn
          {:error, _} -> conn
        end

      :gate ->
        send(owner, {:metadata_started, conn.request_path, self()})

        receive do
          :release_metadata -> json(conn, body)
        after
          5_000 -> raise "test metadata gate was not released"
        end

      _ ->
        if current.metadata_delay_ms > 0, do: Process.sleep(current.metadata_delay_ms)
        json(conn, body)
    end
  end
end

defmodule HarnessForge.CodexResponsesRuntimeTest do
  use ExUnit.Case, async: false
  alias HarnessForge.{Contracts, Evidence, Models, Privacy, Repo}
  alias HarnessForge.Execution.Relay
  alias HarnessForge.Models.{LocalModelIdentity, Runtime}
  alias HarnessForge.CodexResponsesRuntimeFixture, as: F
  @moduletag :committed

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
    :ok = Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    previous =
      Map.new(
        [:workspace_id, :workspace_root, :model_test_plug],
        &{&1, Application.get_env(:harness_forge, &1)}
      )

    workspace = Ecto.UUID.generate()
    root = Path.join([File.cwd!(), "tmp", "codex-native-responses-" <> workspace])
    File.mkdir_p!(root)
    Application.put_env(:harness_forge, :workspace_id, workspace)
    Application.put_env(:harness_forge, :workspace_root, root)
    Application.delete_env(:harness_forge, :model_test_plug)

    {:ok, state} =
      Agent.start_link(fn ->
        %{
          mode: :text,
          version: "0.40.14",
          digest: String.duplicate("a", 64),
          metadata_mode: nil,
          metadata_delay_ms: 0,
          inference_delay_ms: 0,
          command_arguments: nil
        }
      end)

    upstream =
      start_supervised!(
        {Bandit,
         [
           plug: {__MODULE__.Upstream, %{owner: self(), state: state}},
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

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Application.put_env(:harness_forge, :workspace_id, workspace)
        Application.put_env(:harness_forge, :workspace_root, root)
        assert {:ok, _} = Privacy.purge_workspace(workspace)
      end)

      Enum.each(previous, fn {key, value} ->
        if is_nil(value),
          do: Application.delete_env(:harness_forge, key),
          else: Application.put_env(:harness_forge, key, value)
      end)

      File.rm_rf!(root)
    end)

    %{state: state, root: root}
  end

  test "native route returns original SSE and retains metered usage; Chat cannot select Responses" do
    assert {:ok, handle} =
             Relay.start_run("codex-native-route",
               protocol: :codex_responses,
               max_output_tokens: 128,
               budget: %{"max_requests" => 1}
             )

    assert handle.protocol == :codex_responses
    assert handle.model_identity["digest"] == String.duplicate("a", 64)
    assert handle.model_identity["version"] == "0.40.14"
    refute inspect(handle) =~ handle.token
    on_exit(fn -> Relay.stop(handle) end)

    assert {:ok, %{status: 404}} =
             Req.post(url(handle, "/v1/chat/completions"),
               json: F.request(),
               headers: auth(handle),
               retry: false
             )

    assert {:ok, %{status: 200, body: bytes}} = send_response(handle, F.request())
    assert bytes == F.encode(F.events(F.request()))
    assert_receive {:native_responses, payload, [], _}
    assert payload == F.request()

    assert {:ok, [%{"state" => "completed", "input_tokens" => 11, "output_tokens" => 7}]} =
             Models.list_requests("codex-native-route")

    assert {:ok, %{"reserved_tokens" => 18}} = Models.budget("codex-native-route")
    assert {:ok, %{status: 429}} = send_response(handle, F.request())
    refute_receive {:native_responses, _, _, _}, 30
    assert :ok = Relay.stop(handle)
    assert {:ok, chat} = Relay.start_run("chat-native-denial")
    on_exit(fn -> Relay.stop(chat) end)
    assert {:ok, %{status: 404}} = send_response(chat, F.request())
    assert :ok = Relay.stop(chat)
  end

  test "HTTP-200 errors, missing usage, truncation, ambiguous limit and redirect retain uncertain reservations with no retry",
       %{state: state} do
    for mode <- [:failed, :unknown, :truncated, :exhausted, :redirect] do
      Agent.update(state, &%{&1 | mode: mode})
      run = "codex-uncertain-" <> Atom.to_string(mode)

      assert {:ok, scope} =
               Runtime.prepare(run, protocol: :codex_responses, max_output_tokens: 128)

      assert {:error, _} = Runtime.responses(scope, F.request())
      assert_receive {:native_responses, _, [], _}

      assert {:ok,
              [%{"state" => "uncertain", "usage_status" => "unknown", "input_tokens" => nil}]} =
               Models.list_requests(run)

      assert {:ok, budget} = Models.budget(run)
      assert budget["reserved_tokens"] > 128
      assert {:error, :request_outcome_unknown} = Runtime.responses(scope, F.request())
      refute_receive {:native_responses, _, _, _}, 30
    end
  end

  test "metadata pin rejects local model/service drift and remote model markers before inference",
       %{state: state} do
    config = HarnessForge.Models.Configuration.get()
    assert {:ok, identity} = LocalModelIdentity.observe(config)
    assert :ok = LocalModelIdentity.revalidate(config, identity)
    Agent.update(state, &%{&1 | digest: String.duplicate("b", 64)})

    assert {:error, :local_model_identity_changed} =
             LocalModelIdentity.revalidate(config, identity)

    Agent.update(state, &%{&1 | version: "other"})
    assert {:error, :local_model_identity_unavailable} = LocalModelIdentity.observe(config)
    Agent.update(state, &%{&1 | version: "0.40.14", mode: :remote})
    assert {:error, _} = Runtime.prepare("codex-remote-denied", protocol: :codex_responses)
    refute_receive {:native_responses, _, _, _}, 30
  end

  test "unknown schema and protocol settings cannot dispatch or consume a reservation" do
    assert {:ok, scope} = Runtime.prepare("codex-schema-denied", protocol: :codex_responses)
    assert {:error, :invalid_runtime_request} = Runtime.responses(scope, F.request([F.tool()]))

    assert {:error, :invalid_runtime_request} =
             Runtime.responses(scope, Map.put(F.request(), "previous_response_id", "remote"))

    assert {:ok, []} = Models.list_requests("codex-schema-denied")
    refute_receive {:native_responses, _, _, _}, 30
  end

  test "held revision denies before inference; hold committed during I/O retains usage but denies publication",
       %{root: root, state: state} do
    source = source!(root, "before")

    assert {:ok, scope} =
             Runtime.prepare("codex-held-before",
               protocol: :codex_responses,
               source_ids: [source["id"]],
               max_output_tokens: 128
             )

    restrict!(source)
    assert {:error, :revision_use_denied} = Runtime.responses(scope, F.request())
    assert {:ok, []} = Models.list_requests("codex-held-before")
    refute_receive {:native_responses, _, _, _}, 30

    source = source!(root, "during")

    assert {:ok, scope} =
             Runtime.prepare("codex-held-during",
               protocol: :codex_responses,
               source_ids: [source["id"]],
               max_output_tokens: 128
             )

    Agent.update(state, &%{&1 | mode: :gate})
    task = Task.async(fn -> Runtime.responses(scope, F.request()) end)
    assert_receive {:native_responses, _, [], upstream}, 2_000
    restrict!(source)
    send(upstream, :release_response)
    assert {:error, :revision_use_denied} = Task.await(task, 5_000)

    assert {:ok, [%{"state" => "completed", "input_tokens" => 11, "output_tokens" => 7}]} =
             Models.list_requests("codex-held-during")

    assert {:ok, %{"reserved_tokens" => 18}} = Models.budget("codex-held-during")
  end

  test "current trusted authority callback cancels publication after reported usage without locking through I/O",
       %{state: state} do
    {:ok, allowed} = Agent.start_link(fn -> true end)
    authorize = fn -> if Agent.get(allowed, & &1), do: :ok, else: {:error, :runtime_cancelled} end

    assert {:ok, scope} =
             Runtime.prepare("codex-authority-cancel",
               protocol: :codex_responses,
               authorize: authorize,
               max_output_tokens: 128
             )

    Agent.update(state, &%{&1 | mode: :gate})
    task = Task.async(fn -> Runtime.responses(scope, F.request()) end)
    assert_receive {:native_responses, _, [], upstream}, 2_000
    Agent.update(allowed, fn _ -> false end)
    send(upstream, :release_response)
    assert {:error, :runtime_cancelled} = Task.await(task, 5_000)

    assert {:ok, [%{"state" => "completed", "output_tokens" => 7}]} =
             Models.list_requests("codex-authority-cancel")

    assert {:error, :runtime_cancelled} = Runtime.responses(scope, F.request())
  end

  test "relay revocation becomes effective during provider I/O and preserves its settlement", %{
    state: state
  } do
    Agent.update(state, &%{&1 | mode: :gate})

    assert {:ok, handle} =
             Relay.start_run("codex-relay-cancel",
               protocol: :codex_responses,
               max_output_tokens: 128
             )

    request = Task.async(fn -> send_response(handle, F.request()) end)
    assert_receive {:native_responses, _, [], upstream}, 2_000
    stop = Task.async(fn -> Relay.stop(handle) end)
    # The shared cancellation latch is observable without waiting for the busy
    # listener. Synchronize through the public handle's protected control table.
    [{:control, _, control}] = :ets.lookup(handle.control_table, :control)
    await_revocation(control, 100)
    send(upstream, :release_response)

    case Task.await(request, 5_000) do
      {:ok, response} -> assert response.status == 503
      {:error, %Req.TransportError{}} -> :ok
    end

    assert :ok = Task.await(stop, 5_000)

    assert {:ok, [%{"state" => "completed", "output_tokens" => 7}]} =
             Models.list_requests("codex-relay-cancel")
  end

  test "continuously dripping metadata has an absolute observation and preparation deadline", %{
    state: state
  } do
    Agent.update(state, &%{&1 | metadata_mode: :drip})
    config = HarnessForge.Models.Configuration.get()
    started = now_ms()

    assert {:error, :model_deadline_exceeded} =
             LocalModelIdentity.observe(config, deadline_ms: started + 150)

    assert now_ms() - started < 900
    assert_receive {:metadata_started, "/api/version", _}

    started = now_ms()

    assert {:error, :model_deadline_exceeded} =
             Relay.start_run("codex-prepare-deadline",
               protocol: :codex_responses,
               lifetime_ms: 2_400
             )

    assert now_ms() - started < 1_100
    assert_receive {:metadata_started, "/api/version", _}
    assert {:ok, []} = Models.list_requests("codex-prepare-deadline")
    refute_receive {:native_responses, _, _, _}, 30
  end

  test "metadata and near-limit inference consume one budget, not sequential fresh timeouts", %{
    state: state
  } do
    assert {:ok, scope} =
             Runtime.prepare("codex-common-deadline",
               protocol: :codex_responses,
               max_output_tokens: 128,
               timeout: 500
             )

    Agent.update(state, &%{&1 | metadata_delay_ms: 120, inference_delay_ms: 350})
    started = now_ms()
    assert {:error, :model_deadline_exceeded} = Runtime.responses(scope, F.request())
    assert now_ms() - started < 900
    assert_receive {:native_responses, _, [], _}

    assert {:ok, [%{"state" => "uncertain", "usage_status" => "unknown"}]} =
             Models.list_requests("codex-common-deadline")

    assert {:ok, budget} = Models.budget("codex-common-deadline")
    assert budget["reserved_tokens"] > 128
  end

  test "SQL admission spanning the transport cutoff stays in the settlement owner and sends no HTTP",
       %{state: state} do
    alias HarnessForge.Models.{Configuration, HTTP, Ledger}
    config = Configuration.get()
    owner = self()
    Agent.update(state, &%{&1 | metadata_mode: :gate, mode: :gate})

    for route <- [:metadata, :responses] do
      run = "codex-sql-deadline-" <> Atom.to_string(route)
      assert {:ok, _} = Ledger.start_run(run)

      request = %{
        "run_id" => run,
        "request_id" => Ecto.UUID.generate(),
        "prompt" => "Public synthetic deadline regression",
        "max_output_tokens" => 128
      }

      assert {:ok, reservation} = Ledger.reserve(request, config, 256)

      # Deliberately keep a real SQL transaction checked out across the old
      # timer cutoff. This is guard work, not an HTTP delay or a timing retry.
      # Killing this client can invalidate the shared Sandbox holder before
      # the original caller reconciles its durable reservation.
      gate =
        Task.async(fn ->
          receive do
            {:guard_has_sql, pid} ->
              Process.sleep(100)
              send(pid, :finish_guard_sql)
          after
            2_000 -> flunk("SQL admission guard never reached its controlled gate")
          end
        end)

      guard = fn ->
        assert {:ok, :guard_finished} =
                 Repo.transaction(fn ->
                   assert [[1]] == Repo.query!("SELECT 1").rows
                   send(owner, {:sql_admission_owner, self()})
                   send(gate.pid, {:guard_has_sql, self()})

                   receive do
                     :finish_guard_sql -> :ok
                   after
                     1_000 -> flunk("SQL admission gate was not released")
                   end

                   assert [[2]] == Repo.query!("SELECT 2").rows
                   :guard_finished
                 end)

        :ok
      end

      cutoff = now_ms() + 50

      result =
        case route do
          :metadata ->
            HTTP.request_metadata(:get, config["endpoint"] <> "/api/version", nil,
              deadline_ms: cutoff,
              dispatch_guard: guard
            )

          :responses ->
            HTTP.request_responses(
              config["endpoint"] <> "/v1/responses",
              Jason.encode!(F.request()),
              timeout: 50,
              deadline_ms: cutoff,
              dispatch_guard: guard
            )
        end

      assert {:error, :model_deadline_exceeded} = result
      assert :finish_guard_sql = Task.await(gate, 2_000)
      refute_receive {:metadata_started, _, _}, 30
      refute_receive {:native_responses, _, _, _}, 30
      assert {:ok, :uncertain} = Ledger.reconcile(reservation, result, config)
      assert [[3]] == Repo.query!("SELECT 3").rows

      assert {:ok, [%{"state" => "uncertain", "usage_status" => "unknown"}]} =
               Ledger.list_requests(run)

      assert {:ok, %{"reserved_tokens" => 384}} = Ledger.budget(run)
      assert_receive {:sql_admission_owner, ^owner}
    end
  end

  test "remaining relay lifetime caps a late attempt while leaving settlement and cleanup headroom",
       %{state: state} do
    assert {:ok, scope} =
             Runtime.prepare("codex-lifetime-deadline",
               protocol: :codex_responses,
               max_output_tokens: 128,
               timeout: 60_000
             )

    # A trusted relay passes the monotonic lifetime cutoff. Four seconds are
    # allocated to publication/settlement plus teardown, not fresh inference.
    scope = %{scope | deadline_ms: now_ms() + 4_300}
    Agent.update(state, &%{&1 | metadata_delay_ms: 40, inference_delay_ms: 500})
    started = now_ms()
    assert {:error, :model_deadline_exceeded} = Runtime.responses(scope, F.request())
    assert now_ms() - started < 850
    assert_receive {:native_responses, _, [], _}
    assert {:ok, [%{"state" => "uncertain"}]} = Models.list_requests("codex-lifetime-deadline")
  end

  test "revocation during identity metadata denies inference and stop remains bounded", %{
    state: state
  } do
    assert {:ok, handle} =
             Relay.start_run("codex-metadata-revoke",
               protocol: :codex_responses,
               max_output_tokens: 128
             )

    Agent.update(state, &%{&1 | metadata_mode: :gate})
    request = Task.async(fn -> send_response(handle, F.request()) end)
    assert_receive {:metadata_started, "/api/version", upstream}, 2_000
    stop_started = now_ms()
    stop = Task.async(fn -> Relay.stop(handle) end)
    [{:control, _, control}] = :ets.lookup(handle.control_table, :control)
    await_revocation(control, 100)
    send(upstream, :release_metadata)

    case Task.await(request, 5_000) do
      {:ok, response} -> assert response.status == 503
      {:error, %Req.TransportError{}} -> :ok
    end

    assert :ok = Task.await(stop, 5_000)
    assert now_ms() - stop_started < 1_500
    refute_receive {:native_responses, _, _, _}, 30
    refute_receive {:metadata_started, "/api/tags", _}, 30
    assert {:ok, [%{"state" => "uncertain"}]} = Models.list_requests("codex-metadata-revoke")
  end

  test "a slow final identity check cannot publish late or erase already reported usage", %{
    state: state
  } do
    assert {:ok, scope} =
             Runtime.prepare("codex-final-deadline",
               protocol: :codex_responses,
               max_output_tokens: 128,
               timeout: 300
             )

    Agent.update(state, &%{&1 | mode: :final_metadata_drip})
    started = now_ms()
    assert {:error, :model_deadline_exceeded} = Runtime.responses(scope, F.request())
    assert now_ms() - started < 3_000
    assert_receive {:native_responses, _, [], _}
    assert_receive {:metadata_started, "/api/version", _}

    assert {:ok, [%{"state" => "completed", "input_tokens" => 11, "output_tokens" => 7}]} =
             Models.list_requests("codex-final-deadline")

    assert {:ok, %{"reserved_tokens" => 18}} = Models.budget("codex-final-deadline")
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  test "native command calls preserve original SSE and bind call IDs after metered admission", %{
    state: state
  } do
    original = ~s({ "cmd": "cat utility.go", "login": false })
    Agent.update(state, &%{&1 | command_arguments: original})
    body = command_request()

    assert {:ok, scope} =
             Runtime.prepare("native-command-admitted",
               protocol: :codex_responses,
               native_commands: true,
               codex_tools: body["tools"],
               max_output_tokens: 128
             )

    assert {:ok, {:sse, bytes}, [call]} = Runtime.responses(scope, body)
    assert_receive {:native_responses, payload, [], _}
    assert bytes == F.encode(F.command_events(payload, original))
    assert call["call_id"] == "call_native_command"
    assert call["arguments"] == original
    assert call["arguments_digest"] == Contracts.sha256(original)
    assert call["thread_id"] == "thread-command"
    assert call["turn_id"] == "turn-command"

    assert {:ok, [%{"state" => "completed", "input_tokens" => 11, "output_tokens" => 7}]} =
             Models.list_requests("native-command-admitted")
  end

  test "invalid native command permission withholds SSE while preserving valid provider usage", %{
    state: state
  } do
    Agent.update(
      state,
      &%{
        &1
        | command_arguments:
            ~s({"cmd":"cat utility.go","sandbox_permissions":"require_escalated"})
      }
    )

    body = command_request()

    assert {:ok, scope} =
             Runtime.prepare("native-command-rejected",
               protocol: :codex_responses,
               native_commands: true,
               codex_tools: body["tools"],
               max_output_tokens: 128
             )

    assert {:error, :codex_command_arguments_rejected} = Runtime.responses(scope, body)
    assert_receive {:native_responses, _, [], _}

    assert {:ok, [%{"state" => "completed", "input_tokens" => 11, "output_tokens" => 7}]} =
             Models.list_requests("native-command-rejected")

    assert {:ok, %{"reserved_tokens" => 18}} = Models.budget("native-command-rejected")
  end

  test "command context is required before inference, with no implicit tool enablement" do
    body = command_request()

    assert {:ok, scope} =
             Runtime.prepare("native-command-no-context",
               protocol: :codex_responses,
               native_commands: true,
               codex_tools: body["tools"],
               max_output_tokens: 128
             )

    assert {:error, :invalid_runtime_request} =
             Runtime.responses(scope, Map.delete(body, "client_metadata"))

    refute_received {:native_responses, _, _, _}
    assert {:ok, []} = Models.list_requests("native-command-no-context")

    assert {:error, :invalid_runtime_configuration} =
             Runtime.prepare("native-command-wrong-tools",
               protocol: :codex_responses,
               native_commands: true,
               codex_tools: [F.tool()],
               max_output_tokens: 128
             )
  end

  defp command_request do
    tool = %{
      "type" => "function",
      "name" => "exec_command",
      "parameters" => %{"type" => "object", "properties" => %{"cmd" => %{"type" => "string"}}}
    }

    F.request([tool])
    |> Map.merge(%{
      "include" => ["reasoning.encrypted_content"],
      "prompt_cache_key" => "thread-command",
      "client_metadata" => %{"thread_id" => "thread-command", "turn_id" => "turn-command"}
    })
  end

  test "private native approval route binds admitted calls and delivers exactly one explicit WEB decision",
       c do
    {fixture, relay, body} = command_relay!(c)
    alias HarnessForge.Execution.CommandApprovals
    register = driver_registration()

    assert {:ok, %{status: 503}} = send_response(relay, body)
    assert {:ok, []} = Models.list_requests(fixture.run.id)
    assert {:ok, %{status: 200, body: %{"registered" => true}}} = approval_post(relay, register)

    assert {:ok, %{status: 503}} =
             approval_post(relay, Map.put(register, "driver_nonce", String.duplicate("b", 32)))

    original = ~s({"cmd":"cat utility.go","login":false})
    Agent.update(c.state, &%{&1 | command_arguments: original})
    assert {:ok, %{status: 200}} = send_response(relay, body)
    assert_receive {:native_responses, _, [], _}
    assert {:ok, %{status: 503}} = send_response(relay, body)

    callback = approval_frame()

    request = %{
      "version" => 1,
      "action" => "request",
      "driver_nonce" => register["driver_nonce"],
      "native_request" => callback
    }

    assert {:ok, %{status: 200, body: record}} = approval_post(relay, request)
    assert record["state"] == "pending" and is_nil(record["decision"])
    assert {:ok, [saved]} = CommandApprovals.list(fixture.run.id, fixture.caller)
    assert saved["payload"]["original_arguments"] == original
    assert saved["payload"]["provider_response_id"] == "resp_synthetic"
    assert saved["payload"]["native_context_digest"] == Contracts.sha256(callback)

    polling = %{
      "version" => 1,
      "action" => "poll",
      "driver_nonce" => register["driver_nonce"],
      "id" => record["id"],
      "request_digest" => record["request_digest"]
    }

    continued =
      Map.update!(
        body,
        "input",
        &(&1 ++
            [
              %{
                "type" => "function_call",
                "call_id" => "call_native_command",
                "name" => "exec_command",
                "arguments" => original
              },
              %{
                "type" => "function_call_output",
                "call_id" => "call_native_command",
                "output" => "Synthetic command completed"
              }
            ])
      )

    assert {:ok, %{status: 200, body: %{"decision" => nil}}} = approval_post(relay, polling)

    assert {:ok, %{status: 503}} =
             approval_post(relay, Map.put(polling, "request_digest", String.duplicate("f", 64)))

    decision = %{
      "run_id" => fixture.run.id,
      "id" => record["id"],
      "request_digest" => record["request_digest"],
      "decision" => "accept_once"
    }

    assert {:ok, %{status: 503}} = send_response(relay, continued)
    assert {:ok, [_]} = Models.list_requests(fixture.run.id)

    assert {:ok, [%{"state" => "pending"}]} =
             CommandApprovals.list(fixture.run.id, fixture.caller)

    assert {:ok, _} = CommandApprovals.decide(decision, fixture.caller)

    assert {:ok, %{status: 503}} = send_response(relay, continued)
    assert {:ok, [_]} = Models.list_requests(fixture.run.id)

    assert {:ok, [%{"state" => "accepted"}]} =
             CommandApprovals.list(fixture.run.id, fixture.caller)

    assert {:ok, %{status: 200, body: %{"decision" => "accept", "state" => "consumed"}}} =
             approval_post(relay, polling)

    assert {:ok, %{status: 200, body: %{"decision" => "decline"}}} = approval_post(relay, polling)
    assert {:ok, [_only_model_attempt]} = Models.list_requests(fixture.run.id)

    assert {:ok, %{status: 403}} =
             Req.post(url(relay, "/v1/command-approvals"),
               json: polling,
               headers: auth(relay) ++ [{"origin", "http://localhost"}],
               retry: false
             )

    Agent.update(c.state, &%{&1 | command_arguments: nil})

    assert {:ok, %{status: 200}} = send_response(relay, continued)
    assert {:ok, [_, _]} = Models.list_requests(fixture.run.id)
    # Even before finish, an old decision cannot be polled after advancement.
    assert {:ok, %{status: 503}} = approval_post(relay, polling)

    finish = %{
      "version" => 1,
      "action" => "finish",
      "driver_nonce" => register["driver_nonce"],
      "thread_id" => "thread-command",
      "turn_id" => "turn-command"
    }

    assert {:ok, %{status: 200, body: %{"closed" => true}}} = approval_post(relay, finish)
    assert {:ok, %{status: 503}} = approval_post(relay, polling)
    assert :ok = Relay.stop(relay)
  end

  test "a native tool error without an approval record can continue without granting a decision",
       c do
    {fixture, relay, body} = command_relay!(c)
    original = ~s({"cmd":"cat utility.go","login":false})
    assert {:ok, %{status: 200}} = approval_post(relay, driver_registration())
    Agent.update(c.state, &%{&1 | command_arguments: original})
    assert {:ok, %{status: 200}} = send_response(relay, body)

    assert {:ok, []} =
             HarnessForge.Execution.CommandApprovals.list(fixture.run.id, fixture.caller)

    Agent.update(c.state, &%{&1 | command_arguments: nil})

    continued =
      Map.update!(body, "input", fn input ->
        input ++
          [
            %{
              "type" => "function_call",
              "call_id" => "call_native_command",
              "name" => "exec_command",
              "arguments" => original
            },
            %{
              "type" => "function_call_output",
              "call_id" => "call_native_command",
              "output" => "Synthetic native tool error before any approval callback"
            }
          ]
      end)

    assert {:ok, %{status: 200}} = send_response(relay, continued)
    assert {:ok, [_, _]} = Models.list_requests(fixture.run.id)

    assert {:ok, []} =
             HarnessForge.Execution.CommandApprovals.list(fixture.run.id, fixture.caller)

    assert :ok = Relay.stop(relay)
  end

  test "model configuration drift withdraws a recorded approval before native consumption", c do
    {fixture, relay, body} = command_relay!(c)
    alias HarnessForge.Execution.{CommandApproval, CommandApprovals}
    assert {:ok, %{status: 200}} = approval_post(relay, driver_registration())
    Agent.update(c.state, &%{&1 | command_arguments: ~s({"cmd":"cat utility.go","login":false})})
    assert {:ok, %{status: 200}} = send_response(relay, body)

    request = %{
      "version" => 1,
      "action" => "request",
      "driver_nonce" => String.duplicate("a", 32),
      "native_request" => approval_frame()
    }

    assert {:ok, %{status: 200, body: record}} = approval_post(relay, request)

    assert {:ok, _} =
             CommandApprovals.decide(
               %{
                 "run_id" => fixture.run.id,
                 "id" => record["id"],
                 "request_digest" => record["request_digest"],
                 "decision" => "accept_once"
               },
               fixture.caller
             )

    configuration = HarnessForge.Models.Configuration.get()

    assert {:ok, _} =
             Models.configure(%{
               "endpoint" => configuration["endpoint"],
               "model" => "changed:fixture"
             })

    polling = %{
      "version" => 1,
      "action" => "poll",
      "driver_nonce" => String.duplicate("a", 32),
      "id" => record["id"],
      "request_digest" => record["request_digest"]
    }

    assert {:ok, %{status: 503}} = approval_post(relay, polling)
    assert Repo.get!(CommandApproval, record["id"]).state == "accepted"
    assert {:ok, [_]} = Models.list_requests(fixture.run.id)
    assert :ok = Relay.stop(relay)
  end

  defp command_relay!(c) do
    alias HarnessForge.Execution.Coding
    fixture = HarnessForge.CommandApprovalsFixture.create!(c.root)
    body = command_request()
    {:ok, identity} = LocalModelIdentity.observe(HarnessForge.Models.Configuration.get())

    {:ok, admission} =
      Coding.decode_context(
        fixture.run.execution_context,
        fixture.run.result,
        fixture.run.workspace_id,
        fixture.run.id
      )

    admission = %{
      admission
      | model_identity: identity,
        codex_tools: body["tools"],
        tools_profile_digest: Contracts.digest(body["tools"])
    }

    {:ok, context} = Coding.context(admission, fixture.run.workspace_id, fixture.run.id)
    result = Map.merge(fixture.run.result, Coding.identity(admission))

    run =
      Repo.update!(Ecto.Changeset.change(fixture.run, result: result, execution_context: context))

    fixture = %{fixture | run: run}

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        if record = Repo.get(HarnessForge.Evaluation.Run, run.id) do
          result =
            Map.merge(record.result, %{
              "kind" => "static_integrity",
              "outcome" => "failed",
              "cleanup_status" => "not_dispatched"
            })

          Repo.update!(Ecto.Changeset.change(record, result: result, execution_context: nil))
        end
      end)
    end)

    {:ok, relay} =
      Relay.start_run(run.id,
        protocol: :codex_responses,
        native_commands: true,
        codex_tools: body["tools"],
        max_output_tokens: 128,
        authorize: fn -> Coding.authorize_run(run.id, fixture.artifact) end
      )

    {fixture, relay, body}
  end

  defp driver_registration,
    do: %{
      "version" => 1,
      "action" => "register",
      "driver_nonce" => String.duplicate("a", 32),
      "thread_id" => "thread-command",
      "environment_id" => "env-command"
    }

  defp approval_frame do
    Jason.encode!(%{
      "id" => 42,
      "method" => "item/commandExecution/requestApproval",
      "params" => %{
        "kind" => "command",
        "threadId" => "thread-command",
        "turnId" => "turn-command",
        "itemId" => "call_native_command",
        "environmentId" => "env-command",
        "command" => "/bin/bash -c 'cat utility.go'",
        "cwd" => "/candidate",
        "availableDecisions" => ["accept", "acceptForSession", "decline", "cancel"]
      }
    })
  end

  defp approval_post(relay, body),
    do:
      Req.post(url(relay, "/v1/command-approvals"),
        json: body,
        headers: auth(relay),
        retry: false,
        receive_timeout: 10_000
      )

  defp await_revocation(_, 0), do: flunk("relay did not revoke its in-flight capability")

  defp await_revocation(control, remaining) do
    if :atomics.get(control, 1) == 1,
      do: :ok,
      else:
        (
          Process.sleep(1)
          await_revocation(control, remaining - 1)
        )
  end

  defp source!(root, name) do
    directory = Path.join(root, name)
    File.mkdir_p!(directory)

    {:ok, connection} =
      Evidence.connect(%{
        "name" => "Synthetic " <> name,
        "provider" => "local",
        "directory" => directory
      })

    {:ok, source} =
      Evidence.import_markdown(connection["id"], %{
        "external_id" => name <> ".md",
        "title" => name,
        "body" => "Public synthetic native Responses source"
      })

    source
  end

  defp restrict!(source) do
    assert {:ok, %{"cleanup_state" => "pending"}} =
             Evidence.restrict_revision(
               %{
                 "version" => 1,
                 "source_id" => source["id"],
                 "revision_id" => source["latest_revision"]["id"],
                 "body_hash" => source["latest_revision"]["body_hash"],
                 "expected_generation" => 0,
                 "command_id" => Ecto.UUID.generate(),
                 "reason_code" => "operator_restriction"
               },
               authorize: fn -> true end,
               session_fingerprint: Contracts.sha256("native Responses test"),
               view_generation: String.duplicate("a", 32),
               reset_token: 0
             )
  end

  defp url(handle, path \\ "/v1/responses"), do: "http://127.0.0.1:#{handle.port}" <> path
  defp auth(handle), do: [{"authorization", "Bearer " <> handle.token}]

  defp send_response(handle, body),
    do:
      Req.post(url(handle),
        json: body,
        headers: auth(handle),
        retry: false,
        decode_body: false,
        receive_timeout: 10_000
      )
end
