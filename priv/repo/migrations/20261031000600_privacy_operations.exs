defmodule HarnessForge.Repo.Migrations.PrivacyOperations do
  use Ecto.Migration

  def change do
    create table(:privacy_operations, primary_key: false) do
      add :id, :string, primary_key: true
      add :workspace_id, :string, null: false
      add :kind, :string, null: false
      add :target_id, :string, null: false
      add :state, :string, null: false
      add :plan, :map, null: false
      add :error, :string
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create index(:privacy_operations, [:workspace_id, :kind, :target_id])
  end
end
