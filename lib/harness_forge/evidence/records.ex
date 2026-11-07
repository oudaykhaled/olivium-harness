defmodule HarnessForge.Evidence.Connection do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "source_connections" do
    field :workspace_id, :string
    field :provider, :string
    field :name, :string
    field :directory, :string
    field :config, :map, default: %{}
    field :cursor, :string
    field :sync_state, :string, default: "not_synced"
    field :sync_complete, :boolean, default: false
    field :last_synced_at, :utc_datetime_usec
    field :status, :string, default: "active"
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule HarnessForge.Evidence.Source do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "evidence_sources" do
    field :workspace_id, :string
    field :connection_id, :binary_id
    field :provider, :string
    field :external_id, :string
    field :title, :string
    field :latest_revision_id, :binary_id
    field :status, :string, default: "active"
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule HarnessForge.Evidence.Revision do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "evidence_revisions" do
    field :workspace_id, :string
    field :source_id, :binary_id
    field :body, :string
    field :body_hash, :string
    field :revision, :integer
    field :captured_at, :utc_datetime_usec
    field :source_url, :string
    field :source_updated_at, :string
    field :metadata, :map, default: %{}
  end
end

defmodule HarnessForge.Evidence.Citation do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "evidence_citations" do
    field :workspace_id, :string
    field :revision_id, :binary_id
    field :start_byte, :integer
    field :end_byte, :integer
    field :snippet, :string
    field :snippet_hash, :string
  end
end

defmodule HarnessForge.Evidence.Claim do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "evidence_claims" do
    field :workspace_id, :string
    field :family_id, :binary_id
    field :supersedes_id, :binary_id
    field :text, :string
    field :citations, {:array, :map}
    field :basis, :map
    field :revision_hash, :string
    field :inserted_at, :utc_datetime_usec
  end
end

defmodule HarnessForge.Evidence.Decision do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "claim_decisions" do
    field :workspace_id, :string
    field :claim_id, :binary_id
    field :actor, :string
    field :decision, :string
    field :revision_hash, :string
    field :inserted_at, :utc_datetime_usec
  end
end

defmodule HarnessForge.Evidence.Goal do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "workspace_goals" do
    field :workspace_id, :string
    field :title, :string
    field :owner, :string
    field :acceptance, :string
    field :inserted_at, :utc_datetime_usec
  end
end

defmodule HarnessForge.Evidence.AuditEvent do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "audit_events" do
    field :workspace_id, :string
    field :action, :string
    field :details, :map
    field :inserted_at, :utc_datetime_usec
  end
end
