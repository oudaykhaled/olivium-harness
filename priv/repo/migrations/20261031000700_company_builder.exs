defmodule HarnessForge.Repo.Migrations.CompanyBuilder do
  use Ecto.Migration

  def up do
    for name <- [:company_profiles, :company_repositories, :company_projects] do
      create table(name, primary_key: false) do
        add :id, :binary_id, primary_key: true
        add :workspace_id, :string, null: false
        add :payload, :map, null: false
        add :content_hash, :string, null: false
        timestamps(type: :utc_datetime_usec)
      end

      if name != :company_profiles, do: create(index(name, [:workspace_id]))
    end

    create unique_index(:company_profiles, [:workspace_id])

    create table(:company_plans, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workspace_id, :string, null: false
      add :family_id, :binary_id, null: false
      add :supersedes_id, :binary_id
      add :payload, :map, null: false
      add :snapshot, :map, null: false
      add :revision_hash, :string, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:company_plans, [:workspace_id, :family_id])
    create unique_index(:company_plans, [:workspace_id, :supersedes_id])

    create table(:company_plan_decisions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workspace_id, :string, null: false
      add :plan_id, :binary_id, null: false
      add :actor, :string, null: false
      add :decision, :string, null: false
      add :revision_hash, :string, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:company_plan_decisions, [:workspace_id, :plan_id])

    create table(:company_artifact_bindings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workspace_id, :string, null: false
      add :plan_id, :binary_id, null: false
      add :plan_revision_hash, :string, null: false
      add :artifact_digest, :string, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:company_artifact_bindings, [:workspace_id, :plan_id, :artifact_digest],
             name: :company_artifact_plan_digest
           )

    create index(:company_artifact_bindings, [:workspace_id, :artifact_digest])

    for name <- ~w(company_plans company_plan_decisions company_artifact_bindings),
        operation <- ~w(UPDATE DELETE) do
      execute(
        "CREATE TRIGGER immutable_#{name}_#{String.downcase(operation)} BEFORE #{operation} ON #{name} BEGIN SELECT RAISE(ABORT, 'immutable company record'); END"
      )
    end
  end

  def down do
    for name <- [
          :company_artifact_bindings,
          :company_plan_decisions,
          :company_plans,
          :company_projects,
          :company_repositories,
          :company_profiles
        ],
        do: drop(table(name))
  end
end
