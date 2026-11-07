defmodule HarnessForge.Repo.Migrations.SetupSessions do
  use Ecto.Migration

  def up do
    execute(~S"""
    CREATE TABLE setup_sessions (
      id TEXT PRIMARY KEY NOT NULL,
      workspace_id TEXT NOT NULL,
      owner TEXT NOT NULL CHECK(length(owner) BETWEEN 1 AND 128),
      schema_version INTEGER NOT NULL DEFAULT 1 CHECK(schema_version=1),
      lock_version INTEGER NOT NULL DEFAULT 1 CHECK(lock_version>0),
      step TEXT NOT NULL CHECK(step IN ('outcome','scope','understanding','review','candidate','evaluation','release')),
      payload TEXT NOT NULL CHECK(json_valid(payload) AND length(CAST(payload AS BLOB))<=16384),
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      UNIQUE(workspace_id,owner,id)
    )
    """)

    execute(~S"""
    CREATE INDEX setup_sessions_owner_updated
    ON setup_sessions(workspace_id,owner,updated_at DESC,id DESC)
    """)
  end

  def down do
    execute("DROP TABLE setup_sessions")
  end
end
