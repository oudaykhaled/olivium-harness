defmodule HarnessForge.Jobs.Capture do
  @moduledoc "One bounded capture lease; interruption requires explicit durable resume."
  use Oban.Worker, queue: :default, max_attempts: 1
  @impl true
  def perform(%Oban.Job{args: %{"workspace_id" => workspace, "run_id" => id} = args})
      when map_size(args) == 2 do
    if workspace == HarnessForge.Evidence.Store.workspace() do
      case HarnessForge.Evidence.Capture.run(id) do
        {:ok, _} -> :ok
        {:error, reason} -> {:cancel, reason}
      end
    else
      {:cancel, :workspace_mismatch}
    end
  end

  def perform(_), do: {:cancel, :invalid_job}
end
