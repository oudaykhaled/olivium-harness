defmodule HarnessForge.Repo.Migrations.CreateEvidence do
  use Ecto.Migration

  def up do
    create table(:source_connections, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workspace_id, :string, null: false
      add :provider, :string, null: false
      add :name, :string, null: false
      add :directory, :text
      add :status, :string, null: false, default: "active"
      timestamps(type: :utc_datetime_usec)
    end

    create table(:evidence_sources, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workspace_id, :string, null: false
      add :connection_id, references(:source_connections, type: :binary_id), null: false
      add :provider, :string, null: false
      add :external_id, :text, null: false
      add :title, :text, null: false
      add :latest_revision_id, :binary_id
      add :status, :string, null: false, default: "active"
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:evidence_sources, [
             :workspace_id,
             :connection_id,
             :provider,
             :external_id
           ])

    create table(:evidence_revisions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :source_id, references(:evidence_sources, type: :binary_id), null: false
      add :workspace_id, :string, null: false
      add :body, :text, null: false
      add :body_hash, :string, null: false
      add :revision, :integer, null: false
      add :captured_at, :utc_datetime_usec, null: false
    end

    create unique_index(:evidence_revisions, [:source_id, :revision])

    create table(:evidence_citations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :revision_id, references(:evidence_revisions, type: :binary_id), null: false
      add :workspace_id, :string, null: false
      add :start_byte, :integer, null: false
      add :end_byte, :integer, null: false
      add :snippet, :text, null: false
      add :snippet_hash, :string, null: false
    end

    create table(:evidence_claims, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workspace_id, :string, null: false
      add :family_id, :binary_id, null: false
      add :supersedes_id, references(:evidence_claims, type: :binary_id)
      add :text, :text, null: false
      add :citations, :map, null: false
      add :revision_hash, :string, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:evidence_claims, [:supersedes_id])

    create table(:claim_decisions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workspace_id, :string, null: false
      add :claim_id, references(:evidence_claims, type: :binary_id), null: false
      add :actor, :string, null: false
      add :decision, :string, null: false
      add :revision_hash, :string, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:claim_decisions, [:claim_id])

    create table(:workspace_goals, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workspace_id, :string, null: false
      add :title, :text, null: false
      add :owner, :string, null: false
      add :acceptance, :text, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create table(:audit_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workspace_id, :string, null: false
      add :action, :string, null: false
      add :details, :map, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    execute(
      "CREATE VIRTUAL TABLE evidence_search USING fts5(revision_id UNINDEXED, workspace_id UNINDEXED, title, body)"
    )

    for table <-
          ~w(evidence_revisions evidence_citations evidence_claims claim_decisions workspace_goals audit_events),
        operation <- ~w(UPDATE DELETE) do
      execute(
        "CREATE TRIGGER immutable_#{table}_#{String.downcase(operation)} BEFORE #{operation} ON #{table} BEGIN SELECT RAISE(ABORT, 'immutable record'); END"
      )
    end
  end

  def down do
    execute("DROP TABLE evidence_search")
    drop table(:audit_events)
    drop table(:workspace_goals)
    drop table(:claim_decisions)
    drop table(:evidence_claims)
    drop table(:evidence_citations)
    drop table(:evidence_revisions)
    drop table(:evidence_sources)
    drop table(:source_connections)
  end
end
