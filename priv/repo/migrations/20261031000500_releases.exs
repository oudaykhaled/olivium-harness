defmodule HarnessForge.Repo.Migrations.Releases do
  use Ecto.Migration

  def up do
    create table(:release_approvals, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workspace_id, :string, null: false
      add :artifact_digest, :string, null: false
      add :evaluation_id, :binary_id, null: false
      add :scope_digest, :string, null: false
      add :payload, :map, null: false
      add :approval_digest, :string, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:release_approvals, [:workspace_id, :inserted_at])

    create table(:release_channels, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workspace_id, :string, null: false
      add :scope_digest, :string, null: false
      add :channel, :string, null: false
      add :release_id, references(:release_approvals, type: :binary_id)
      add :event_digest, :string
      add :version, :integer, null: false, default: 0
      add :updated_at, :utc_datetime_usec, null: false
    end

    create unique_index(:release_channels, [:workspace_id, :scope_digest, :channel])

    create table(:release_history, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workspace_id, :string, null: false
      add :scope_digest, :string, null: false
      add :channel, :string, null: false
      add :release_id, references(:release_approvals, type: :binary_id), null: false
      add :previous_release_id, references(:release_approvals, type: :binary_id)
      add :action, :string, null: false
      add :version, :integer, null: false
      add :payload, :map, null: false
      add :event_digest, :string, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:release_history, [:workspace_id, :scope_digest, :channel, :version])

    for table <- ~w(release_approvals release_history), operation <- ~w(UPDATE DELETE) do
      execute(
        "CREATE TRIGGER immutable_#{table}_#{String.downcase(operation)} BEFORE #{operation} ON #{table} BEGIN SELECT RAISE(ABORT, 'immutable release record'); END"
      )
    end
  end

  def down do
    drop table(:release_history)
    drop table(:release_channels)
    drop table(:release_approvals)
  end
end
