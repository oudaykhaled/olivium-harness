defmodule HarnessForge.Company.SetupSession do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "setup_sessions" do
    field :workspace_id, :string
    field :owner, :string
    field :schema_version, :integer, default: 1
    field :lock_version, :integer, default: 1
    field :step, :string, default: "outcome"
    field :payload, :map
    timestamps(type: :utc_datetime_usec)
  end
end
