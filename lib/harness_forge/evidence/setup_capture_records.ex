defmodule HarnessForge.Evidence.SetupCaptureBinding do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "setup_capture_bindings" do
    field :workspace_id, :string
    field :owner_id, :string
    field :session_id, :binary_id
    field :run_id, :binary_id
    field :config_id, :binary_id
    field :capture_id, :binary_id
    field :command_id, :binary_id
    field :connection_id, :binary_id
    field :root_fingerprint, :string
    field :limits_json, :map
    field :accepted_at, :utc_datetime_usec
    field :deadline, :utc_datetime_usec
    field :digest, :string
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end

defmodule HarnessForge.Evidence.SetupCaptureCounter do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "setup_capture_counters" do
    field :workspace_id, :string
    field :owner_id, :string
    field :session_id, :binary_id
    field :capture_id, :binary_id
    field :lock_version, :integer, default: 1
    field :entries_admitted, :integer, default: 0
    field :files_reserved, :integer, default: 0
    field :bytes_reserved, :integer, default: 0
    field :bytes_committed, :integer, default: 0
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end

defmodule HarnessForge.Evidence.SetupCaptureCharge do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "setup_capture_charges" do
    field :workspace_id, :string
    field :owner_id, :string
    field :session_id, :binary_id
    field :capture_id, :binary_id
    field :kind, :string
    field :relative_path, :string
    field :fingerprint_json, :map
    field :allowance_bytes, :integer
    field :lease_generation, :integer
    field :lease_token, :string
    field :state, :string
    field :actual_bytes, :integer
    field :source_ref, :map
    field :revision_ref, :map
    field :content_hash, :string
    field :lock_version, :integer, default: 1
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end

defmodule HarnessForge.Evidence.SetupCapturePage do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "setup_capture_pages" do
    field :workspace_id, :string
    field :owner_id, :string
    field :session_id, :binary_id
    field :capture_id, :binary_id
    field :scan_epoch, :integer
    field :directory, :string
    field :sequence, :integer
    field :payload_digest, :string
    field :admitted_count, :integer
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
