defmodule HarnessForge.Repo.Migrations.CompanyAssessments do
  use Ecto.Migration

  def up do
    create table(:company_task_rubrics, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workspace_id, :string, null: false
      add :family_id, :binary_id, null: false

      add :supersedes_id,
          references(:company_task_rubrics, type: :binary_id, on_delete: :restrict)

      add :payload, :map, null: false
      add :revision_hash, :string, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:company_task_rubrics, [:workspace_id, :family_id])
    create unique_index(:company_task_rubrics, [:workspace_id, :supersedes_id])

    create table(:company_assessments, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workspace_id, :string, null: false

      add :rubric_id, references(:company_task_rubrics, type: :binary_id, on_delete: :restrict),
        null: false

      add :attempt_id, :binary_id, null: false
      add :request_digest, :string, null: false
      add :payload, :map, null: false
      add :assessment_hash, :string, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:company_assessments, [:workspace_id, :rubric_id])
    create unique_index(:company_assessments, [:workspace_id, :attempt_id])

    for name <- ~w(company_task_rubrics company_assessments), operation <- ~w(UPDATE DELETE) do
      execute(
        "CREATE TRIGGER immutable_#{name}_#{String.downcase(operation)} BEFORE #{operation} ON #{name} BEGIN SELECT RAISE(ABORT, 'immutable company assessment'); END"
      )
    end
  end

  def down do
    raise Ecto.MigrationError,
      message: "Retain immutable assessment history; roll back application entry points instead."
  end
end
