defmodule HarnessForge.Jobs.PassageIndex do
  @moduledoc "Idempotent revision-pinned passage indexing, without source text in job arguments."
  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [
      period: 60,
      keys: [:workspace_id, :revision_id],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  @impl true
  def perform(%Oban.Job{args: %{"workspace_id" => workspace, "revision_id" => id} = args})
      when map_size(args) == 2 do
    if workspace == HarnessForge.Evidence.Store.workspace() do
      case HarnessForge.Evidence.Passages.index_revision(id) do
        {:ok, _} -> :ok
        {:error, reason} -> {:cancel, reason}
      end
    else
      {:cancel, :workspace_mismatch}
    end
  end

  def perform(_), do: {:cancel, :invalid_job}
end
