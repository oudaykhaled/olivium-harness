defmodule HarnessForge.Repo.Migrations.CreateModelRequests do
  use Ecto.Migration

  def change do
    create table(:model_settings, primary_key: false) do
      add :workspace_id, :string, primary_key: true
      add :settings, :map, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create table(:model_budgets, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workspace_id, :string, null: false
      add :run_id, :string, null: false
      add :max_requests, :integer, null: false
      add :max_tokens, :integer, null: false
      add :max_estimated_microusd, :integer, null: false
      add :reserved_requests, :integer, null: false, default: 0
      add :reserved_tokens, :integer, null: false, default: 0
      add :reserved_estimated_microusd, :integer, null: false, default: 0
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:model_budgets, [:workspace_id, :run_id])

    create table(:model_requests, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workspace_id, :string, null: false
      add :run_id, :string, null: false
      add :request_id, :string, null: false
      add :provider, :string, null: false
      add :model, :string, null: false
      add :fingerprint, :string, null: false
      add :state, :string, null: false, default: "dispatched"
      add :reserved_tokens, :integer, null: false
      add :reserved_estimated_microusd, :integer, null: false
      add :input_tokens, :integer
      add :output_tokens, :integer
      add :usage_status, :string, null: false, default: "unknown"
      add :billing_status, :string, null: false, default: "unknown"
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:model_requests, [:workspace_id, :run_id, :request_id])
  end
end
