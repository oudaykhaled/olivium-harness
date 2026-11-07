defmodule HarnessForge.Company.SetupRunConfig do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "setup_run_configs" do
    field :workspace_id, :string
    field :owner_id, :string
    field :session_id, :binary_id
    field :digest, :string
    field :schema_version, :integer, default: 1
    field :scope_json, :map
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end

defmodule HarnessForge.Company.SetupRun do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "setup_runs" do
    field :workspace_id, :string
    field :owner_id, :string
    field :session_id, :binary_id
    field :digest, :string
    field :config_id, :binary_id
    field :predecessor_id, :binary_id
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end

defmodule HarnessForge.Company.SetupRunState do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "setup_run_states" do
    field :workspace_id, :string
    field :owner_id, :string
    field :session_id, :binary_id
    field :run_id, :binary_id
    field :lock_version, :integer, default: 1
    field :phase, :string
    field :last_command_id, :binary_id
    field :capture_id, :binary_id
    field :retrieval_id, :binary_id
    field :preparation_id, :binary_id
    field :authorization_id, :binary_id
    field :result_ref, :map
    field :failure_code, :string
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule HarnessForge.Company.SetupRunPreparation do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "setup_run_preparations" do
    field :workspace_id, :string
    field :owner_id, :string
    field :session_id, :binary_id
    field :digest, :string
    field :run_id, :binary_id
    field :config_id, :binary_id
    field :operation_id, :binary_id
    field :retrieval_ref, :map
    field :stage_ref, :map
    field :manifest_ref, :map
    field :context_digest, :string
    field :context_json, :map
    field :checked_pack_json, :map
    field :prompt_bytes, :string
    field :prompt_sha256, :string
    field :request_body_bytes, :string
    field :request_body_sha256, :string
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end

defmodule HarnessForge.Company.SetupRunCommand do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "setup_run_commands" do
    field :workspace_id, :string
    field :owner_id, :string
    field :session_id, :binary_id
    field :run_id, :binary_id
    field :command_id, :binary_id
    field :request_digest, :string
    field :request_json, :map
    field :receipt_json, :map
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end

defmodule HarnessForge.Company.SetupRunOperation do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "setup_run_operations" do
    field :workspace_id, :string
    field :owner_id, :string
    field :session_id, :binary_id
    field :digest, :string
    field :run_id, :binary_id
    field :config_id, :binary_id
    field :command_id, :binary_id
    field :operation_id, :binary_id
    field :kind, :string
    field :preparation_id, :binary_id
    field :authorization_id, :binary_id
    field :expected_run_version, :integer
    field :generations_json, {:array, :map}, default: []
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
