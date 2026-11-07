defmodule HarnessForge.Execution.Relay do
  @moduledoc """
  Short-lived, capability-protected coding chat listener on numeric loopback.

  This is a trusted host model boundary, not a sandbox or an execution profile.
  Container callers need a separately verified confined network path. Starting
  this listener never changes Docker's offline confinement profile.
  """
  use GenServer
  import Ecto.Query
  alias HarnessForge.{Contracts, Repo, Workspaces}
  alias HarnessForge.Evaluation.Run
  alias HarnessForge.Models.Runtime
  alias HarnessForge.Execution.{CodexCommandPolicy, CommandApprovals}
  @approval_route "/v1/command-approvals"

  defmodule Handle do
    @moduledoc "Ephemeral owned handle. Do not persist its capability or provider configuration."
    @derive {Inspect, except: [:token, :provider_config, :control_table]}
    defstruct [
      :pid,
      :run_id,
      :port,
      :token,
      :provider_config,
      :socket_path,
      :protocol,
      :model_identity,
      :control_table
    ]
  end

  @doc "Start one bounded run; opts add max_turns (1..100), lifetime_ms (1..600_000) to Runtime.prepare options."
  def start_run(run_id, opts \\ []) do
    turns = Keyword.get(opts, :max_turns, 20)
    lifetime = Keyword.get(opts, :lifetime_ms, 300_000)
    unix? = Keyword.get(opts, :unix_socket, false)
    owner = self()
    control = :atomics.new(1, signed: false)

    deadline =
      System.monotonic_time(:millisecond) + if(is_integer(lifetime), do: lifetime, else: 0)

    caller_authorize = Keyword.get(opts, :authorize, fn -> :ok end)

    authorize = fn ->
      if :atomics.get(control, 1) == 0 and System.monotonic_time(:millisecond) < deadline and
           Process.alive?(owner), do: caller_authorize.(), else: {:error, :relay_revoked}
    end

    with true <-
           is_integer(turns) and turns in 1..100 and is_integer(lifetime) and
             lifetime in 1..600_000 and is_boolean(unix?) and is_function(caller_authorize, 0),
         {:ok, scope} <-
           Runtime.prepare(
             run_id,
             opts
             |> Keyword.drop([:max_turns, :lifetime_ms, :unix_socket])
             |> Keyword.put(:authorize, authorize)
             |> Keyword.put(:deadline_ms, deadline)
           ),
         {:ok, pid} <-
           GenServer.start(__MODULE__, %{
             scope: scope,
             max_turns: turns,
             lifetime: lifetime,
             unix?: unix?,
             owner: owner,
             control: control,
             deadline: deadline
           }) do
      GenServer.call(pid, :handle)
    else
      false -> {:error, :invalid_relay_limits}
      error -> error
    end
  end

  @doc "Revoke capability, stop listener and verify that the owned process exited."
  def stop(%Handle{pid: pid, token: token} = handle) when is_pid(pid) do
    if Process.alive?(pid) do
      with :ok <- revoke_control(handle) do
        case GenServer.call(pid, {:stop, token}, 65_000) do
          :ok -> verify_stopped(handle)
          error -> error
        end
      end
    else
      verify_stopped(handle)
    end
  catch
    :exit, {:noproc, _} -> :ok
    :exit, _ -> {:error, :relay_cleanup_failed}
  end

  def stop(_), do: {:error, :invalid_relay_handle}

  def authorize(pid, token), do: GenServer.call(pid, {:authorize, token})
  def route(pid), do: GenServer.call(pid, :route)
  def routes(pid), do: GenServer.call(pid, :routes)
  def chat(pid, token, body), do: GenServer.call(pid, {:chat, token, body}, 65_000)
  def responses(pid, token, body), do: GenServer.call(pid, {:responses, token, body}, 65_000)

  def command_approvals(pid, token, body),
    do: GenServer.call(pid, {:command_approvals, token, body}, 10_000)

  @impl true
  def init(state) do
    Process.flag(:trap_exit, true)
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    owner = Process.monitor(state.owner)
    control_table = :ets.new(:relay_control, [:set, :protected])
    :ets.insert(control_table, {:control, :crypto.hash(:sha256, token), state.control})

    case Bandit.start_link(
           plug: {HarnessForge.Execution.RelayPlug, %{relay: self()}},
           ip: {127, 0, 0, 1},
           port: 0,
           startup_log: false,
           thousand_island_options: [num_acceptors: 1, num_connections: 4, read_timeout: 5_000],
           http_1_options: [
             max_header_count: 20,
             max_header_length: 2048,
             max_request_line_length: 2048
           ],
           http_2_options: [enabled: false]
         ) do
      {:ok, listener} ->
        {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(listener)

        case socket_listener(state.unix?) do
          {:ok, socket} ->
            timer = Process.send_after(self(), :expired, state.lifetime)

            {:ok,
             Map.merge(state, %{
               token: token,
               owner_monitor: owner,
               listener: listener,
               port: port,
               turns: 0,
               timer: timer,
               native_driver: nil,
               native_drivers: MapSet.new(),
               native_calls: %{},
               native_pending_call: nil,
               approval_bindings: %{},
               control_table: control_table
             })
             |> Map.merge(socket)}

          error ->
            Supervisor.stop(listener, :normal, 5_000)
            {:stop, elem(error, 1)}
        end

      _ ->
        {:stop, :relay_listener_unavailable}
    end
  end

  @impl true
  def handle_call(:handle, _from, state) do
    model = state.scope.config["model"]

    config = %{
      "enabled_providers" => ["harnessforge"],
      "model" => "harnessforge/" <> model,
      "small_model" => "harnessforge/" <> model,
      "provider" => %{
        "harnessforge" => %{
          "npm" => "@ai-sdk/openai-compatible",
          "name" => "HarnessForge metered Ollama",
          "options" => %{
            "baseURL" => "http://127.0.0.1:#{state.port}/v1",
            "apiKey" => state.token
          },
          "models" => %{
            model => %{
              "name" => model,
              "limit" => %{"context" => 16_384, "output" => state.scope.max_output_tokens}
            }
          }
        }
      }
    }

    handle = %Handle{
      pid: self(),
      run_id: state.scope.run_id,
      port: state.port,
      token: state.token,
      provider_config: config,
      socket_path: state.socket_path,
      protocol: state.scope.protocol,
      model_identity: state.scope.model_identity,
      control_table: state.control_table
    }

    {:reply, {:ok, handle}, state}
  end

  def handle_call({:authorize, token}, _from, state),
    do: {:reply, authorized(token, state), state}

  def handle_call(:route, _from, state) do
    {:reply, model_route(state), state}
  end

  def handle_call(:routes, _from, state),
    do:
      {:reply,
       [model_route(state)] ++ if(native_commands?(state), do: [@approval_route], else: []),
       state}

  def handle_call({:chat, token, body}, _from, state) do
    cond do
      authorized(token, state) != :ok -> {:reply, {:error, :invalid_relay_capability}, state}
      state.scope.protocol != :chat -> {:reply, {:error, :route_unavailable}, state}
      state.turns >= state.max_turns -> {:reply, {:error, :relay_turn_limit}, state}
      true -> {:reply, Runtime.chat(state.scope, body), %{state | turns: state.turns + 1}}
    end
  end

  def handle_call({:responses, token, body}, _from, state) do
    cond do
      authorized(token, state) != :ok -> {:reply, {:error, :invalid_relay_capability}, state}
      state.scope.protocol != :codex_responses -> {:reply, {:error, :route_unavailable}, state}
      state.turns >= state.max_turns -> {:reply, {:error, :relay_turn_limit}, state}
      true -> native_response(token, body, state)
    end
  end

  def handle_call({:command_approvals, token, body}, _from, state) do
    cond do
      authorized(token, state) != :ok ->
        {:reply, {:error, :invalid_relay_capability}, state}

      not native_commands?(state) ->
        {:reply, {:error, :route_unavailable}, state}

      true ->
        case approval_action(body, token, state) do
          {:ok, response, next} -> {:reply, {:ok, {:json, response}}, next}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:stop, token}, _from, state) do
    case token_authorized(token, state) do
      :ok -> {:stop, :normal, :ok, state}
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_info(:expired, state), do: {:stop, :normal, state}

  def handle_info({:DOWN, monitor, :process, _, _}, %{owner_monitor: monitor} = state),
    do: {:stop, :normal, state}

  def handle_info({:EXIT, _, _}, state), do: {:stop, :normal, state}

  @impl true
  def format_status(status),
    do: Map.merge(status, %{state: :redacted, message: :redacted, reason: :redacted})

  @impl true
  def terminate(_, state) do
    :atomics.put(state.control, 1, 1)
    Process.cancel_timer(state.timer)
    if Process.alive?(state.listener), do: Supervisor.stop(state.listener, :normal, 5_000)

    if is_pid(state.socket_listener) and Process.alive?(state.socket_listener),
      do: Supervisor.stop(state.socket_listener, :normal, 5_000)

    if state.socket_path do
      case File.lstat(state.socket_path) do
        {:ok, %{inode: inode}} when inode == state.socket_inode -> File.rm(state.socket_path)
        _ -> :ok
      end

      File.rmdir(Path.dirname(state.socket_path))
    end

    :ok
  end

  defp authorized(token, state) do
    if :atomics.get(state.control, 1) == 0 and
         System.monotonic_time(:millisecond) < state.deadline and Process.alive?(state.owner),
       do: token_authorized(token, state),
       else: {:error, :invalid_relay_capability}
  end

  defp model_route(state),
    do:
      if(state.scope.protocol == :codex_responses,
        do: "/v1/responses",
        else: "/v1/chat/completions"
      )

  defp native_commands?(state), do: Map.get(state.scope, :native_commands, false) == true

  defp native_response(_token, body, %{scope: %{native_commands: false}} = state),
    do: {:reply, Runtime.responses(state.scope, body), %{state | turns: state.turns + 1}}

  defp native_response(token, body, state) do
    with true <- current_approval_caller(token, state).(),
         {:ok, context} <- CodexCommandPolicy.metadata(body),
         %{closed: false} = driver <- state.native_driver,
         true <- context["thread_id"] == driver.thread_id,
         true <- is_nil(driver.turn_id) or context["turn_id"] == driver.turn_id,
         :ok <- recorded_approvals_settled(token, state),
         :ok <-
           CodexCommandPolicy.continuation(state.native_calls[state.native_pending_call], body) do
      driver = %{driver | turn_id: context["turn_id"]}
      next = %{state | native_driver: driver, turns: state.turns + 1}

      case Runtime.responses(state.scope, body) do
        {:ok, response, calls} ->
          with true <- current_approval_caller(token, state).(),
               true <- map_size(next.native_calls) + length(calls) <= 32,
               true <- Enum.all?(calls, &(not Map.has_key?(next.native_calls, &1["call_id"]))) do
            stored =
              Enum.reduce(
                calls,
                next.native_calls,
                &Map.put(&2, &1["call_id"], Map.put(&1, "driver_nonce", driver.nonce))
              )

            pending =
              case calls do
                [call] -> call["call_id"]
                [] -> nil
              end

            {:reply, {:ok, response},
             %{next | native_calls: stored, native_pending_call: pending}}
          else
            _ -> {:reply, {:error, :codex_command_context_rejected}, next}
          end

        error ->
          {:reply, error, next}
      end
    else
      _ -> {:reply, {:error, :codex_command_context_rejected}, state}
    end
  end

  defp approval_action(%{"version" => 1, "action" => "register"} = body, token, state) do
    nonce = body["driver_nonce"]

    with true <- exact?(body, ~w(version action driver_nonce thread_id environment_id)),
         true <-
           nonce?(nonce) and native_id?(body["thread_id"]) and native_id?(body["environment_id"]),
         true <- is_nil(state.native_driver) or state.native_driver.closed,
         true <-
           MapSet.size(state.native_drivers) < 4 and
             not MapSet.member?(state.native_drivers, nonce),
         true <- current_approval_caller(token, state).() do
      driver = %{
        nonce: nonce,
        thread_id: body["thread_id"],
        environment_id: body["environment_id"],
        turn_id: nil,
        closed: false
      }

      {:ok, %{"registered" => true},
       %{
         state
         | native_driver: driver,
           native_drivers: MapSet.put(state.native_drivers, nonce),
           native_pending_call: nil
       }}
    else
      _ -> {:error, :codex_command_context_rejected}
    end
  end

  defp approval_action(%{"version" => 1, "action" => "request"} = body, token, state) do
    with true <- exact?(body, ~w(version action driver_nonce native_request)),
         {:ok, driver} <- current_driver(body, state),
         frame when is_binary(frame) and byte_size(frame) <= 16_384 <- body["native_request"],
         {:ok, %{"params" => %{"itemId" => item}}} <- Jason.decode(frame),
         true <- state.native_pending_call == item,
         call when is_map(call) <- state.native_calls[item],
         true <- call["driver_nonce"] == driver.nonce,
         {:ok, payload} <-
           CodexCommandPolicy.approval(
             frame,
             %{
               "driver_nonce" => driver.nonce,
               "thread_id" => driver.thread_id,
               "environment_id" => driver.environment_id
             },
             call
           ),
         remaining = min(120_000, state.deadline - System.monotonic_time(:millisecond)),
         true <- remaining > 0,
         deadline = DateTime.add(DateTime.utc_now(), remaining, :millisecond),
         {:ok, record} <-
           CommandApprovals.request(state.scope.run_id, payload, deadline,
             authorize: current_approval_caller(token, state)
           ) do
      binding = %{nonce: driver.nonce, request_digest: record["request_digest"], call_id: item}
      next = %{state | approval_bindings: Map.put(state.approval_bindings, record["id"], binding)}

      Phoenix.PubSub.broadcast(
        HarnessForge.PubSub,
        "workspace:" <> HarnessForge.Workspaces.current_id(),
        {:command_approval_requested, state.scope.run_id}
      )

      {:ok, approval_reply(record, nil), next}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :codex_command_approval_rejected}
    end
  end

  defp approval_action(%{"version" => 1, "action" => "poll"} = body, token, state) do
    with true <- exact?(body, ~w(version action driver_nonce id request_digest)),
         {:ok, driver} <- current_driver(body, state),
         %{nonce: nonce, request_digest: digest, call_id: call_id} <-
           state.approval_bindings[body["id"]],
         true <- nonce == driver.nonce and digest == body["request_digest"],
         true <- call_id == state.native_pending_call,
         {:ok, record} <-
           CommandApprovals.poll(state.scope.run_id, body["id"],
             authorize: current_approval_caller(token, state)
           ),
         true <- current_approval_caller(token, state).() do
      {:ok, approval_reply(record, record["decision"]), state}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :codex_command_approval_rejected}
    end
  end

  defp approval_action(%{"version" => 1, "action" => "finish"} = body, token, state) do
    with true <- exact?(body, ~w(version action driver_nonce thread_id turn_id)),
         {:ok, driver} <- current_driver(body, state),
         true <- body["thread_id"] == driver.thread_id and body["turn_id"] == driver.turn_id,
         true <- is_nil(state.native_pending_call),
         true <- current_approval_caller(token, state).() do
      {:ok, %{"closed" => true}, %{state | native_driver: %{driver | closed: true}}}
    else
      _ -> {:error, :codex_command_context_rejected}
    end
  end

  defp approval_action(_, _, _), do: {:error, :invalid_command_approval}

  defp recorded_approvals_settled(token, state) do
    ids =
      for {id, binding} <- state.approval_bindings,
          binding.call_id == state.native_pending_call,
          binding.nonce == state.native_driver.nonce,
          do: id

    # Native errors and commands without an approval callback have no record.
    # A recorded decision must be terminal before its tool result can advance.
    if ids == [] do
      :ok
    else
      with {:ok, records} <-
             CommandApprovals.list(state.scope.run_id,
               authorize: current_approval_caller(token, state)
             ),
           true <-
             Enum.all?(ids, fn id ->
               Enum.any?(records, &(&1["id"] == id and &1["state"] in ["consumed", "declined"]))
             end) do
        :ok
      else
        _ -> {:error, :codex_command_approval_unsettled}
      end
    end
  end

  defp current_driver(body, %{native_driver: %{closed: false} = driver}) do
    if body["driver_nonce"] == driver.nonce,
      do: {:ok, driver},
      else: {:error, :codex_command_context_rejected}
  end

  defp current_driver(_, _), do: {:error, :codex_command_context_rejected}

  defp current_approval_caller(token, state) do
    fn ->
      authorized(token, state) == :ok and Runtime.authorize(state.scope) == :ok and
        native_run_scope?(state.scope)
    end
  end

  defp native_run_scope?(scope) do
    model_digest = Contracts.digest(scope.model_identity)
    tools_digest = Contracts.digest(scope.codex_tools)

    Repo.exists?(
      from r in Run,
        where:
          r.workspace_id == ^Workspaces.current_id() and r.id == ^scope.run_id and
            fragment("json_extract(?, '$.outcome')", r.result) == "running" and
            fragment("json_extract(?, '$.runtime_name')", r.result) == "codex" and
            fragment("json_extract(?, '$.model_identity_digest')", r.result) == ^model_digest and
            fragment("json_extract(?, '$.codex_tools_digest')", r.result) == ^tools_digest
    )
  rescue
    _ -> false
  end

  defp approval_reply(record, decision),
    do:
      record |> Map.take(~w(id request_digest state expires_at)) |> Map.put("decision", decision)

  defp exact?(body, fields), do: is_map(body) and Enum.sort(Map.keys(body)) == Enum.sort(fields)
  defp nonce?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{32}\z/, value)

  defp native_id?(value),
    do: is_binary(value) and Regex.match?(~r/\A[A-Za-z0-9_.:-]{1,128}\z/, value)

  defp token_authorized(token, state) when is_binary(token) do
    if byte_size(token) == byte_size(state.token) and
         Plug.Crypto.secure_compare(token, state.token),
       do: :ok,
       else: {:error, :invalid_relay_capability}
  end

  defp token_authorized(_, _), do: {:error, :invalid_relay_capability}

  defp revoke_control(%Handle{pid: pid, token: token, control_table: table})
       when is_binary(token) do
    with ^pid <- :ets.info(table, :owner),
         [{:control, digest, control}] <- :ets.lookup(table, :control),
         true <- Plug.Crypto.secure_compare(digest, :crypto.hash(:sha256, token)) do
      # Revoke immediately, even while the GenServer is waiting for provider
      # I/O. That attempt still settles before its response is denied.
      :atomics.put(control, 1, 1)
      :ok
    else
      _ -> {:error, :invalid_relay_capability}
    end
  rescue
    _ -> {:error, :invalid_relay_capability}
  end

  defp socket_listener(false),
    do: {:ok, %{socket_listener: nil, socket_path: nil, socket_inode: nil}}

  defp socket_listener(true) do
    directory =
      Path.join([
        HarnessForge.Workspaces.root(),
        "tmp",
        "r-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      ])

    socket = Path.join(directory, "s")

    with true <- byte_size(socket) < 104,
         :ok <- File.mkdir_p(Path.dirname(directory)),
         :ok <- File.mkdir(directory),
         :ok <- File.chmod(directory, 0o700),
         {:ok, listener} <-
           Bandit.start_link(
             plug: {HarnessForge.Execution.RelayPlug, %{relay: self()}},
             ip: {:local, socket},
             port: 0,
             startup_log: false,
             thousand_island_options: [num_acceptors: 1, num_connections: 4, read_timeout: 5_000],
             http_2_options: [enabled: false]
           ) do
      case File.chmod(socket, 0o600) do
        :ok ->
          {:ok, stat} = File.lstat(socket)
          {:ok, %{socket_listener: listener, socket_path: socket, socket_inode: stat.inode}}

        _ ->
          Supervisor.stop(listener, :normal, 5_000)
          File.rm(socket)
          File.rmdir(directory)
          {:error, :relay_socket_unavailable}
      end
    else
      _ ->
        File.rmdir(directory)
        {:error, :relay_socket_unavailable}
    end
  end

  defp verify_stopped(handle) do
    if not Process.alive?(handle.pid) and
         (is_nil(handle.socket_path) or File.lstat(handle.socket_path) == {:error, :enoent}),
       do: :ok,
       else: {:error, :relay_cleanup_failed}
  end
end
