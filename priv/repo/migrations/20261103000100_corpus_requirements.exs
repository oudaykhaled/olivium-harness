defmodule HarnessForge.Repo.Migrations.CorpusRequirements do
  use Ecto.Migration

  def up do
    execute(~S"""
    CREATE TABLE corpus_requirements (
     id TEXT PRIMARY KEY NOT NULL, workspace_id TEXT NOT NULL,
     corpus_id TEXT NOT NULL, project_id TEXT NOT NULL, goal_id TEXT NOT NULL,
     revision INTEGER NOT NULL CHECK(revision>0), digest TEXT NOT NULL CHECK(length(digest)=64),
     payload TEXT NOT NULL CHECK(json_valid(payload) AND length(CAST(payload AS BLOB))<=32768),
     inserted_at TEXT NOT NULL, UNIQUE(workspace_id,id),
     UNIQUE(workspace_id,corpus_id,project_id,goal_id,revision),
     FOREIGN KEY(workspace_id,corpus_id) REFERENCES corpora(workspace_id,id) ON DELETE RESTRICT,
     FOREIGN KEY(workspace_id,project_id) REFERENCES company_projects(workspace_id,id) ON DELETE RESTRICT,
     FOREIGN KEY(workspace_id,goal_id) REFERENCES workspace_goals(workspace_id,id) ON DELETE RESTRICT)
    """)

    execute(~S"""
    CREATE INDEX corpus_requirements_context ON corpus_requirements(workspace_id,corpus_id,project_id,goal_id,revision)
    """)

    execute(~S"""
    CREATE TRIGGER immutable_corpus_requirements_update BEFORE UPDATE ON corpus_requirements
    BEGIN SELECT RAISE(ABORT, 'immutable corpus declaration'); END
    """)

    execute(~S"""
    CREATE TRIGGER immutable_corpus_requirements_delete BEFORE DELETE ON corpus_requirements
    BEGIN SELECT RAISE(ABORT, 'immutable corpus declaration'); END
    """)
  end

  def down do
    execute("DROP TABLE corpus_requirements")
  end
end
