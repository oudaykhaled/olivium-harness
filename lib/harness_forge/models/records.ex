defmodule HarnessForge.Models.Settings do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:workspace_id, :string, autogenerate: false}
  schema "model_settings" do
    field :settings, :map
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule HarnessForge.Models.Budget do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "model_budgets" do
    field :workspace_id, :string
    field :run_id, :string
    field :max_requests, :integer
    field :max_tokens, :integer
    field :max_estimated_microusd, :integer
    field :reserved_requests, :integer, default: 0
    field :reserved_tokens, :integer, default: 0
    field :reserved_estimated_microusd, :integer, default: 0
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule HarnessForge.Models.Request do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "model_requests" do
    field :workspace_id, :string
    field :run_id, :string
    field :request_id, :string
    field :provider, :string
    field :model, :string
    field :fingerprint, :string
    field :state, :string, default: "dispatched"
    field :reserved_tokens, :integer
    field :reserved_estimated_microusd, :integer
    field :input_tokens, :integer
    field :output_tokens, :integer
    field :usage_status, :string, default: "unknown"
    field :billing_status, :string, default: "unknown"
    timestamps(type: :utc_datetime_usec)
  end
end
