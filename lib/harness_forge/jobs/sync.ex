defmodule HarnessForge.Jobs.Sync do
  @moduledoc "Durable, bounded source imports. Malformed or unsafe sources are terminal failures."
  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: 60, keys: [:connection_id, :workspace_id]]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"connection_id" => id, "workspace_id" => workspace}}) do
    if workspace == HarnessForge.Evidence.Store.workspace() do
      case HarnessForge.Evidence.sync(id) do
        {:ok, _} ->
          :ok

        {:error, %HarnessForge.Contracts.Error{code: code}} ->
          # Rate limits and remote failures require an explicit new sync request.
          # Do not loop, sleep, or hide provider Retry-After behind automatic retries.
          {:cancel, code}

        {:error, reason} when reason in [:unreadable_directory, :unreadable_file] ->
          {:error, reason}

        {:error, reason} ->
          {:cancel, reason}
      end
    else
      {:cancel, :workspace_mismatch}
    end
  end

  def perform(_), do: {:cancel, :invalid_job}
end
