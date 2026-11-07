defmodule HarnessForge.StartupGate do
  @moduledoc "Synchronous recovery barrier before Oban services or the endpoint start."
  use GenServer
  import Ecto.Query
  alias HarnessForge.{Audit, Repo, Workspaces}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    if Application.get_env(:harness_forge, :startup_recovery, true) do
      Ecto.Migrator.run(HarnessForge.Repo, :up, all: true, log: false)
      interrupt_stale_jobs()
      :ok = HarnessForge.Models.StageControl.reconcile()
      reconcile()
    end

    {:ok, %{ready: true}}
  end

  defp reconcile do
    # Modules register recovery functions as they are implemented. They run
    # synchronously, before any job can issue effects. A failure aborts boot.
    Enum.each(Application.get_env(:harness_forge, :recovery_modules, []), fn module ->
      case module.reconcile() do
        :ok -> :ok
        {:error, reason} -> raise "Workspace recovery failed: #{inspect(reason)}"
      end
    end)
  end

  @doc false
  def interrupt_stale_jobs do
    # The exclusive owner has started, but Oban has not. Executing rows belong
    # to the old process: don't replay uncertain inference or deadlock privacy
    # recovery waiting for a job rescuer that cannot start before this barrier.
    query =
      from job in Oban.Job,
        where:
          job.state == "executing" and
            fragment("json_extract(?, '$.workspace_id')", job.args) == ^Workspaces.current_id()

    {count, _} =
      Repo.update_all(query, set: [state: "cancelled", cancelled_at: DateTime.utc_now()])

    if count > 0 do
      {:ok, _} = Audit.append("jobs.interrupted", %{"count" => count, "status" => "cancelled"})
    end

    :ok
  end
end
