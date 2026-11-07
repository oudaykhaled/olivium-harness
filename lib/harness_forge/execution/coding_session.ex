defmodule HarnessForge.Execution.CodingSession do
  @moduledoc false
  use GenServer
  alias HarnessForge.{Workspaces, Execution.Relay}

  def start(id, relay), do: GenServer.start_link(__MODULE__, relay, name: name(id))

  def stop(id) do
    case :global.whereis_name(key(id)) do
      :undefined -> :ok
      pid -> GenServer.call(pid, :stop, 65_000)
    end
  catch
    :exit, {:noproc, _} -> :ok
    :exit, {:normal, _} -> :ok
    :exit, _ -> {:error, :relay_cleanup_failed}
  end

  @impl true
  def init(relay), do: {:ok, relay}
  @impl true
  def handle_call(:stop, _, relay) do
    case Relay.stop(relay) do
      :ok -> {:stop, :normal, :ok, relay}
      error -> {:reply, error, relay}
    end
  end

  @impl true
  def terminate(_, relay), do: Relay.stop(relay)
  defp key(id), do: {__MODULE__, Workspaces.current_id(), id}
  defp name(id), do: {:global, key(id)}
end
