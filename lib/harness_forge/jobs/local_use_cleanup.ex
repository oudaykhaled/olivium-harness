defmodule HarnessForge.Jobs.LocalUseCleanup do
  @moduledoc "A bounded corpus invalidation wake-up; no source authority or text in job arguments."
  use Oban.Worker, queue: :default, max_attempts: 3,
    unique: [period: 60, keys: [:workspace_id, :event_id],
      states: [:available, :scheduled, :executing, :retryable]]

  @impl true
  def perform(%Oban.Job{args: %{"workspace_id" => workspace, "event_id" => id} = args})
      when map_size(args) == 2 do
    if workspace == HarnessForge.Evidence.Store.workspace() do
      case HarnessForge.Evidence.LocalUseLifecycle.resume_pending(id) do
        {:ok, %{"state" => "completed"}} -> HarnessForge.Evidence.LocalUseLifecycle.wake_pending()
        {:ok, %{"state" => "pending"}} -> {:snooze, 1}
        {:error, reason} -> {:error, reason}
      end
    else
      {:cancel, :workspace_mismatch}
    end
  end
  def perform(_), do: {:cancel, :invalid_job}
end
