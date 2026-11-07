defmodule HarnessForge.Models.StageConfig do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "stage_configs" do
    field :workspace_id, :string
    field :stage, :string
    field :payload_json, :string
    field :config_hash, :string
    field :inserted_at, :utc_datetime_usec
  end
end

defmodule HarnessForge.Models.StageConsent do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "stage_consent_revisions" do
    field :workspace_id, :string
    field :stage_config_id, :binary_id
    field :revision, :integer
    field :state, :string
    field :inserted_at, :utc_datetime_usec
  end
end

defmodule HarnessForge.Models.StageAttempt do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: false}
  schema "stage_attempts" do
    field :workspace_id, :string
    field :operation_id, :string
    field :logical_call_id, :string
    field :ordinal, :integer
    field :predecessor_attempt_id, :binary_id
    field :stage_config_id, :binary_id
    field :consent_id, :binary_id
    field :model_request_id, :binary_id
    field :worker_request_id, :string
    field :payload_hash, :string
    field :manifest_id, :binary_id
    field :semantic_generation, :integer
    field :authorization_generation, :integer
    field :cancel_epoch, :integer
    field :grant_hash, :string
    field :deadline_at, :utc_datetime_usec
    field :state, :string
    field :result_hash, :string
    field :response_status, :integer
    field :response_bytes, :integer
    field :error_code, :string
    field :inserted_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end
end
