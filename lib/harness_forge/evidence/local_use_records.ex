defmodule HarnessForge.Evidence.LocalUseSet do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "local_use_sets" do
    field :workspace_id, :string
    field :origin_workspace_id, :string
    field :quarantined, :boolean, default: false
    field :owner_id, :string
    field :capture_id, :binary_id
    field :binding_digest, :string
    field :config_id, :binary_id
    field :config_digest, :string
    field :acquire_command_id, :binary_id
    field :connection_id, :binary_id
    field :connection_digest, :string
    field :root_fingerprint, :string
    field :preparation_digest, :string
    field :manifest_digest, :string
    field :item_count, :integer
    field :basis_json, :map
    field :predecessor_set_id, :binary_id
    field :predecessor_generation, :integer
    field :state, :string, default: "prepared"
    field :policy_generation, :integer, default: 0
    field :purposes_json, {:array, :string}, default: []
    field :retain_local, :boolean, default: false
    field :policy_digest, :string
    field :prepared_at, :utc_datetime_usec
    field :activated_at, :utc_datetime_usec
    field :withdrawn_at, :utc_datetime_usec
    field :lock_version, :integer, default: 0
  end
end

defmodule HarnessForge.Evidence.LocalUseItem do
  @moduledoc false
  use Ecto.Schema
  @primary_key false
  schema "local_use_items" do
    field :set_id, :binary_id, primary_key: true
    field :workspace_id, :string
    field :source_id, :binary_id, primary_key: true
    field :revision_id, :binary_id
    field :body_hash, :string
    field :capture_item_key, :string
  end
end

defmodule HarnessForge.Evidence.LocalUseEnrollment do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "local_use_enrollments" do
    field :workspace_id, :string
    field :source_id, :binary_id
    field :original_source_id, :binary_id
    field :set_id, :binary_id
    field :connection_id, :binary_id
    field :provider, :string
    field :external_id, :string
    field :namespace_digest, :string
    field :state, :string, default: "bound"
    field :grant_generation, :integer
  end
end

defmodule HarnessForge.Evidence.LocalUseEvent do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "local_use_events" do
    field :workspace_id, :string
    field :set_id, :binary_id
    field :source_id, :binary_id
    field :stream_key, :string
    field :sequence, :integer
    field :kind, :string
    field :command_key, :string
    field :request_digest, :string
    field :payload_json, :map
    field :inserted_at, :utc_datetime_usec
  end
end

defmodule HarnessForge.Evidence.LocalUseCheckpoint do
  @moduledoc false
  use Ecto.Schema
  @primary_key false
  schema "local_use_checkpoints" do
    field :event_id, :binary_id, primary_key: true
    field :consumer, :string, primary_key: true, default: "corpus_invalidation"
    field :workspace_id, :string
    field :state, :string, default: "pending"
    field :cursor_source_id, :string, default: ""
    field :cursor_corpus_id, :string, default: ""
    field :lock_version, :integer, default: 0
    field :updated_at, :utc_datetime_usec
  end
end
