defmodule HarnessForge.Repo.Migrations.RevisionUseHolds do
  use Ecto.Migration

  def up do
    execute(~S"""
    CREATE TABLE revision_use_holds (
      id TEXT PRIMARY KEY NOT NULL,
      workspace_id TEXT NOT NULL,
      connection_id TEXT NOT NULL REFERENCES source_connections(id),
      provider TEXT NOT NULL,
      external_id TEXT NOT NULL,
      source_id TEXT NOT NULL REFERENCES evidence_sources(id),
      revision_id TEXT NOT NULL REFERENCES evidence_revisions(id),
      body_hash TEXT NOT NULL CHECK(length(body_hash)=64 AND body_hash NOT GLOB '*[^0-9a-f]*'),
      command_id TEXT NOT NULL,
      request_digest TEXT NOT NULL CHECK(length(request_digest)=64 AND request_digest NOT GLOB '*[^0-9a-f]*'),
      schema_version INTEGER NOT NULL DEFAULT 1 CHECK(schema_version=1),
      policy_generation INTEGER NOT NULL DEFAULT 1 CHECK(policy_generation=1),
      denied_purposes TEXT NOT NULL CHECK(denied_purposes='["inspection","retrieval","analysis","compile"]'),
      reason_code TEXT NOT NULL CHECK(reason_code='operator_restriction'),
      actor TEXT NOT NULL CHECK(length(actor) BETWEEN 1 AND 128),
      inserted_at TEXT NOT NULL,
      UNIQUE(workspace_id,revision_id),
      UNIQUE(workspace_id,command_id)
    )
    """)

    execute(
      "CREATE INDEX revision_use_holds_source ON revision_use_holds(workspace_id,source_id)"
    )

    execute(~S"""
    CREATE TRIGGER revision_use_holds_scope_insert BEFORE INSERT ON revision_use_holds
    WHEN NOT EXISTS (
      SELECT 1 FROM evidence_revisions r
      JOIN evidence_sources s ON s.id=r.source_id AND s.workspace_id=r.workspace_id
      JOIN source_connections c ON c.id=s.connection_id AND c.workspace_id=s.workspace_id
      WHERE r.id=NEW.revision_id AND r.workspace_id=NEW.workspace_id
        AND r.source_id=NEW.source_id AND r.body_hash=NEW.body_hash
        AND s.connection_id=NEW.connection_id AND s.provider=NEW.provider
        AND s.external_id=NEW.external_id AND c.provider=NEW.provider
    ) BEGIN SELECT RAISE(ABORT,'restriction identity mismatch'); END
    """)

    for operation <- ~w(update delete) do
      execute(
        "CREATE TRIGGER immutable_revision_use_holds_#{operation} BEFORE #{String.upcase(operation)} ON revision_use_holds BEGIN SELECT RAISE(ABORT,'immutable record'); END"
      )
    end

    execute(~S"""
    CREATE TABLE revision_use_cleanup (
      event_id TEXT PRIMARY KEY NOT NULL REFERENCES revision_use_holds(id),
      workspace_id TEXT NOT NULL,
      state TEXT NOT NULL DEFAULT 'pending' CHECK(state IN ('pending','completed')),
      cursor TEXT NOT NULL DEFAULT '',
      lock_version INTEGER NOT NULL DEFAULT 0 CHECK(lock_version>=0),
      updated_at TEXT NOT NULL
    )
    """)

    execute(~S"""
    CREATE TRIGGER revision_use_cleanup_scope_insert BEFORE INSERT ON revision_use_cleanup
    WHEN NOT EXISTS (SELECT 1 FROM revision_use_holds h WHERE h.id=NEW.event_id AND h.workspace_id=NEW.workspace_id)
    BEGIN SELECT RAISE(ABORT,'restriction checkpoint identity mismatch'); END
    """)

    execute(~S"""
    CREATE TRIGGER immutable_revision_use_cleanup_identity BEFORE UPDATE ON revision_use_cleanup
    WHEN OLD.event_id!=NEW.event_id OR OLD.workspace_id!=NEW.workspace_id
    BEGIN SELECT RAISE(ABORT,'immutable checkpoint identity'); END
    """)
  end

  def down do
    # Dropping populated negative authority would silently revive content use.
    %{rows: [[count]]} =
      repo().query!(
        "SELECT (SELECT count(*) FROM revision_use_holds)+(SELECT count(*) FROM revision_use_cleanup)"
      )

    if count != 0,
      do: raise(Ecto.MigrationError, "cannot remove persisted revision-use restrictions")

    execute("DROP TABLE revision_use_cleanup")
    execute("DROP TABLE revision_use_holds")
  end
end
