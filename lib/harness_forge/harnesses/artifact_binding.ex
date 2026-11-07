defmodule HarnessForge.Harnesses.ArtifactBinding do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "company_artifact_bindings" do
    field :workspace_id, :string
    field :plan_id, :binary_id
    field :plan_revision_hash, :string
    field :artifact_digest, :string
    field :inserted_at, :utc_datetime_usec
  end
end
