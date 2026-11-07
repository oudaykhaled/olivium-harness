defmodule HarnessForge.Releases.Approval do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "release_approvals" do
    field :workspace_id, :string
    field :artifact_digest, :string
    field :evaluation_id, :binary_id
    field :scope_digest, :string
    field :payload, :map
    field :approval_digest, :string
    field :inserted_at, :utc_datetime_usec
  end
end

defmodule HarnessForge.Releases.Channel do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "release_channels" do
    field :workspace_id, :string
    field :scope_digest, :string
    field :channel, :string
    field :release_id, :binary_id
    field :event_digest, :string
    field :version, :integer, default: 0
    field :updated_at, :utc_datetime_usec
  end
end

defmodule HarnessForge.Releases.Event do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "release_history" do
    field :workspace_id, :string
    field :scope_digest, :string
    field :channel, :string
    field :release_id, :binary_id
    field :previous_release_id, :binary_id
    field :action, :string
    field :version, :integer
    field :payload, :map
    field :event_digest, :string
    field :inserted_at, :utc_datetime_usec
  end
end
