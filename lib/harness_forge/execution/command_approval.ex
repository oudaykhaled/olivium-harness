defmodule HarnessForge.Execution.CommandApproval do
  @moduledoc "Durable exact native-command decision; an accepted row is not an execution receipt."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "command_approvals" do
    field :workspace_id, :string
    field :run_id, :binary_id
    field :artifact_digest, :string
    field :profile_digest, :string
    field :native_request_key, :string
    field :request_digest, :string
    field :payload, :map, redact: true
    field :state, :string, default: "pending"
    field :expires_at, :utc_datetime_usec
    field :decided_at, :utc_datetime_usec
    field :consumed_at, :utc_datetime_usec
    field :decision_owner, :string
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc false
  def changeset(attrs) do
    %__MODULE__{}
    |> cast(
      attrs,
      ~w(workspace_id run_id artifact_digest profile_digest native_request_key request_digest payload expires_at)a
    )
    |> validate_required(
      ~w(workspace_id run_id artifact_digest profile_digest native_request_key request_digest payload expires_at)a
    )
    |> foreign_key_constraint(:run_id)
    |> unique_constraint([:workspace_id, :run_id, :native_request_key])
  end
end
