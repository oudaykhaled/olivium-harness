defmodule HarnessForge.Repo.Migrations.RemoteConnections do
  use Ecto.Migration

  def change do
    alter table(:source_connections) do
      add :config, :map, null: false, default: %{}
      add :cursor, :text
      add :sync_state, :string, null: false, default: "not_synced"
      add :sync_complete, :boolean, null: false, default: false
      add :last_synced_at, :utc_datetime_usec
    end

    alter table(:evidence_revisions) do
      add :source_url, :text
      add :source_updated_at, :string
      add :metadata, :map, null: false, default: %{}
    end
  end
end
