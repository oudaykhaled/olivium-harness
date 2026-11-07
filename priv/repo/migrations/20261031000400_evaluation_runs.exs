defmodule HarnessForge.Repo.Migrations.EvaluationRuns do
  use Ecto.Migration

  def change do
    create table(:evaluation_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workspace_id, :string, null: false
      add :artifact_digest, :string, null: false
      add :result, :map, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create index(:evaluation_runs, [:workspace_id, :artifact_digest])
  end
end
