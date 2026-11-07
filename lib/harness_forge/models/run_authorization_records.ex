defmodule HarnessForge.Models.RunAuthorizationRecord do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "model_run_authorizations" do
    field :workspace_id, :string
    field :owner_id, :string
    field :session_id, :binary_id
    field :digest, :string
    field :run_id, :binary_id
    field :config_id, :binary_id
    field :preparation_id, :binary_id
    field :scope_digest, :string
    field :descriptor_json, :map
    field :budget_id, :binary_id
    field :max_requests, :integer
    field :max_tokens, :integer
    field :max_cost_microusd, :integer
    field :authorized_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :command_id, :binary_id
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end

defmodule HarnessForge.Models.RunAuthorizationState do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "model_run_authorization_states" do
    field :workspace_id, :string
    field :owner_id, :string
    field :session_id, :binary_id
    field :authorization_id, :binary_id
    field :lock_version, :integer, default: 1
    field :revoked_at, :utc_datetime_usec
    field :reason, :string
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end

defmodule HarnessForge.Models.RunDisclosure do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "model_run_disclosures" do
    field :workspace_id, :string
    field :owner_id, :string
    field :session_id, :binary_id
    field :run_id, :binary_id
    field :config_id, :binary_id
    field :preparation_id, :binary_id
    field :stage_ref, :map
    field :manifest_ref, :map
    field :consent_id, :binary_id
    field :consent_revision, :integer
    field :context_digest, :string
    field :command_id, :binary_id
    field :digest, :string
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
