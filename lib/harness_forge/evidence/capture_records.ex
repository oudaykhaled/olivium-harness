defmodule HarnessForge.Evidence.CaptureRun do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "capture_runs" do
    field :workspace_id, :string
    field :corpus_id, :binary_id
    field :connection_id, :binary_id
    field :idempotency_key, :string
    field :root_fingerprint, :string
    field :state, :string, default: "queued"
    field :lock_version, :integer, default: 1
    field :checkpoint_seq, :integer, default: 0
    field :scan_epoch, :integer, default: 1
    field :scan_verified, :boolean, default: false
    field :incomplete, :boolean, default: false
    field :counts, :map, default: %{}
    field :reconcile_after, :string
    field :error_code, :string
    field :lease_token, :string
    field :lease_until, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule HarnessForge.Evidence.CaptureFrontier do
  @moduledoc false
  use Ecto.Schema
  @primary_key false
  schema "capture_frontier" do
    field :run_id, :binary_id, primary_key: true
    field :relative_path, :string, primary_key: true
    field :state, :string
    field :scan_epoch, :integer
    field :directory_fingerprint, :string
    field :entry_count, :integer
  end
end

defmodule HarnessForge.Evidence.CaptureItem do
  @moduledoc false
  use Ecto.Schema
  @primary_key false
  schema "capture_items" do
    field :run_id, :binary_id, primary_key: true
    field :relative_path, :string, primary_key: true
    field :kind, :string
    field :state, :string
    field :scan_epoch, :integer
    field :source_id, :binary_id
    field :revision_id, :binary_id
    field :body_hash, :string
    field :body_bytes, :integer
    field :error_code, :string
    field :attempts, :integer
    field :updated_at, :utc_datetime_usec
  end
end
