defmodule HarnessForge.Evidence.Capture.Scanner do
  @moduledoc "Root-supervised, one-request/ACK-at-a-time framed stdlib directory enumerator."
  use GenServer
  alias HarnessForge.Contracts

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def open_directory(run, root, relative, owner \\ nil),
    do:
      request(
        %{"v" => 1, "op" => "open", "run_id" => run, "root" => root, "relative_path" => relative},
        owner
      )

  def ack(run, seq, owner \\ nil),
    do: request(%{"v" => 1, "op" => "ack", "run_id" => run, "seq" => seq}, owner)

  def cancel(owner \\ nil), do: request(%{"v" => 1, "op" => "cancel"}, owner)

  def reset(owner) do
    GenServer.call(__MODULE__, {:reset, owner})
  catch
    :exit, _ -> {:error, :scanner_unavailable}
  end

  defp request(value, owner) do
    GenServer.call(__MODULE__, {:request, value, owner}, 65_000)
  catch
    :exit, _ -> {:error, :scanner_unavailable}
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{port: nil, pending: nil, opts: opts, owner: nil}}
  end

  defp open_port(opts) do
    executable = Keyword.get(opts, :python) || System.find_executable("python3")

    script =
      Keyword.get(opts, :script) ||
        Application.app_dir(:harness_forge, "priv/corpus_capture/scan.py")

    if is_binary(executable) do
      cleared = System.get_env() |> Map.keys() |> Enum.map(&{String.to_charlist(&1), false})
      env = cleared ++ [{~c"LANG", ~c"C.UTF-8"}, {~c"LC_ALL", ~c"C.UTF-8"}]

      {:ok,
       Port.open({:spawn_executable, executable}, [
         :binary,
         {:packet, 4},
         :exit_status,
         :use_stdio,
         {:env, env},
         args: ["-I", "-S", "-X", "utf8", script]
       ])}
    else
      {:error, :scanner_unavailable}
    end
  rescue
    _ -> {:error, :scanner_unavailable}
  end

  @impl true
  def handle_call({:reset, owner}, _from, state) when is_binary(owner) do
    if state.pending do
      {from, timer, _} = state.pending
      Process.cancel_timer(timer)
      GenServer.reply(from, {:error, :cancelled})
    end

    if state.port && Port.info(state.port), do: Port.close(state.port)
    {:reply, :ok, %{state | port: nil, pending: nil, owner: owner}}
  end

  def handle_call({:request, _, owner}, _from, %{owner: current} = state)
      when current != nil and owner != current,
      do: {:reply, {:error, :cancelled}, state}

  def handle_call(
        {:request, %{"op" => "cancel"}, _owner},
        _from,
        %{port: nil, pending: nil} = state
      ),
      do: {:reply, {:ok, %{"v" => 1, "cancelled" => true}}, state}

  def handle_call({:request, value, _owner}, from, %{pending: nil} = state) do
    bytes = Contracts.canonical_json(value)
    opened = if state.port, do: {:ok, state.port}, else: open_port(state.opts)

    with true <- byte_size(bytes) <= 131_072,
         {:ok, port} <- opened,
         true <- Port.command(port, bytes) do
      reference = make_ref()
      timer = Process.send_after(self(), {:request_timeout, reference}, 60_000)
      {:noreply, %{state | port: port, pending: {from, timer, reference}}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      _ -> {:reply, {:error, :invalid_input}, state}
    end
  end

  def handle_call(_, _, state), do: {:reply, {:error, :queue_full}, state}

  @impl true
  def handle_info(
        {port, {:data, bytes}},
        %{port: port, pending: {from, timer, _reference}} = state
      ) do
    Process.cancel_timer(timer)

    result =
      with true <- byte_size(bytes) <= 65_536,
           {:ok, value} <- Contracts.decode_json(bytes),
           true <- is_map(value) and value["v"] === 1 do
        case value["error_code"] do
          nil -> {:ok, value}
          "symlink_not_allowed" -> {:error, :symlink_not_allowed}
          "path_escape" -> {:error, :path_escape}
          _ -> {:error, :unreadable_directory}
        end
      else
        _ -> {:error, :invalid_input}
      end

    GenServer.reply(from, result)
    {:noreply, %{state | pending: nil}}
  end

  def handle_info({:request_timeout, reference}, %{pending: {_, _, reference}} = state),
    do: {:stop, :scanner_timeout, state}

  def handle_info({port, {:exit_status, _}}, %{port: port} = state),
    do: {:stop, :scanner_exit, state}

  def handle_info({:EXIT, port, _}, %{port: port} = state), do: {:stop, :scanner_exit, state}
  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state) do
    if state.pending do
      {from, timer, _reference} = state.pending
      Process.cancel_timer(timer)
      GenServer.reply(from, {:error, :scanner_unavailable})
    end

    if state.port && Port.info(state.port), do: Port.close(state.port)
    :ok
  end
end
