defmodule HarnessForge.Audit do
  @moduledoc "Append-only structured audit events. Payloads contain identifiers and decisions, never evidence bodies or credentials."
  import Ecto.Query
  alias HarnessForge.{Repo, Evidence.Store, Evidence.AuditEvent}

  @allowed ~w(source_id connection_id revision_id claim_id goal_id catalog_id plan_id artifact_digest release_id evaluation_id run_id decision actor status count rubric_id assessment_id attempt_id revision_hash assessment_hash approval_id request_digest profile_digest)

  def append(action, details \\ %{}) when is_binary(action) and is_map(details) do
    redacted =
      details
      |> Map.take(@allowed)
      |> Map.new(fn {key, value} -> {key, redact(value)} end)

    %AuditEvent{
      workspace_id: Store.workspace(),
      action: action,
      details: redacted,
      inserted_at: Store.now()
    }
    |> Repo.insert()
    |> case do
      {:ok, event} -> {:ok, Store.dto(event)}
      {:error, _} -> {:error, :audit_failed}
    end
  end

  def list_events do
    events =
      Repo.all(from e in Store.scoped(AuditEvent), order_by: [desc: e.inserted_at], limit: 200)

    {:ok, Enum.map(events, &Store.dto/1)}
  end

  defp redact(value) when is_binary(value) do
    value
    |> String.slice(0, 200)
    |> String.replace(
      ~r/(?:sk-[A-Za-z0-9_-]+|gh[pousr]_[A-Za-z0-9]+|Bearer\s+\S+)/i,
      "[REDACTED]"
    )
  end

  defp redact(value) when is_number(value) or is_boolean(value) or is_nil(value), do: value
  defp redact(_), do: "[REDACTED]"
end
