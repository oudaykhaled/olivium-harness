defmodule HarnessForge.Repo.Migrations.McpDisclosureGrants do
  use Ecto.Migration

  def up do
    execute """
    CREATE TABLE mcp_clients (
      id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, name TEXT NOT NULL,
      token_hash TEXT NOT NULL, generation INTEGER NOT NULL DEFAULT 0,
      state TEXT NOT NULL CHECK(state IN ('active','revoked')),
      revoked_at TEXT, inserted_at TEXT NOT NULL,
      UNIQUE(workspace_id,token_hash)
    )
    """

    execute """
    CREATE TABLE mcp_disclosure_grants (
      id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, client_id TEXT NOT NULL,
      client_generation INTEGER NOT NULL, corpus_id TEXT NOT NULL,
      project_id TEXT NOT NULL, goal_id TEXT NOT NULL, goal_hash TEXT NOT NULL,
      semantic_generation INTEGER NOT NULL, authorization_generation INTEGER NOT NULL,
      profile_hash TEXT NOT NULL, project_hash TEXT NOT NULL, profile TEXT NOT NULL,
      generation INTEGER NOT NULL DEFAULT 0, revision_hash TEXT NOT NULL,
      expires_at INTEGER NOT NULL, state TEXT NOT NULL CHECK(state IN ('active','revoked')),
      revoked_at TEXT, inserted_at TEXT NOT NULL,
      FOREIGN KEY(client_id) REFERENCES mcp_clients(id) ON DELETE RESTRICT
    )
    """

    execute """
    CREATE TABLE mcp_disclosure_grant_items (
      grant_id TEXT NOT NULL, source_id TEXT NOT NULL, revision_id TEXT NOT NULL,
      body_hash TEXT NOT NULL, passage_set_id TEXT NOT NULL,
      PRIMARY KEY(grant_id,source_id),
      FOREIGN KEY(grant_id) REFERENCES mcp_disclosure_grants(id) ON DELETE RESTRICT
    )
    """

    execute "CREATE INDEX mcp_grants_client ON mcp_disclosure_grants(workspace_id,client_id,state)"
  end

  def down do
    drop table(:mcp_disclosure_grant_items)
    drop table(:mcp_disclosure_grants)
    drop table(:mcp_clients)
  end
end
