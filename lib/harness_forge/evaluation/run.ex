defmodule HarnessForge.Evaluation.Run do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: false}
  schema "evaluation_runs" do
    field :workspace_id, :string
    field :artifact_digest, :string
    field :result, :map
    field :execution_context, :map, redact: true
    timestamps(type: :utc_datetime_usec)
  end
end
