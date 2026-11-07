defmodule HarnessForge.Jobs.Operation do
  @moduledoc "Bounded UI operations persist in Oban; source text and credentials never enter arguments."
  use Oban.Worker, queue: :default, max_attempts: 1
  alias HarnessForge.Workspaces

  @impl true
  def perform(%Oban.Job{args: %{"workspace_id" => workspace} = args}) do
    if workspace == Workspaces.current_id() do
      result = with :ok <- Workspaces.ensure_writable(), do: dispatch(args)

      summary =
        case result do
          {:ok, _} -> "Operation completed. Inspect the recorded outcome before continuing."
          {:error, reason} when is_atom(reason) -> "Operation stopped: #{reason}."
          _ -> "Operation failed; no success has been recorded."
        end

      Phoenix.PubSub.broadcast(
        HarnessForge.PubSub,
        "workspace:" <> workspace,
        {:operation_finished, summary}
      )

      case result do
        {:ok, _} -> :ok
        {:error, reason} -> {:cancel, reason}
        _ -> {:cancel, :operation_failed}
      end
    else
      {:cancel, :workspace_mismatch}
    end
  end

  def perform(_), do: {:cancel, :invalid_operation}

  defp dispatch(%{"action" => "sync", "id" => id}), do: HarnessForge.Evidence.sync(id)
  defp dispatch(%{"action" => "propose", "id" => id}), do: HarnessForge.Models.propose(id)

  defp dispatch(%{"action" => "evaluate", "id" => id, "kind" => kind})
       when kind in ["static_integrity", "runtime_smoke", "task"],
       do: HarnessForge.Evaluations.run(id, kind: kind)

  defp dispatch(_), do: {:error, :invalid_operation}
end
