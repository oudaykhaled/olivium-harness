defmodule HarnessForge.Repo.Migrations.LocalUsePolicies do
  use Ecto.Migration

  @tables ~w(local_use_sets local_use_items local_use_enrollments local_use_events local_use_checkpoints)

  def up do
    execute(~S"""
    CREATE TABLE local_use_sets (
      id TEXT PRIMARY KEY NOT NULL,
      workspace_id TEXT NOT NULL, origin_workspace_id TEXT NOT NULL, owner_id TEXT NOT NULL,
      quarantined INTEGER NOT NULL DEFAULT 0 CHECK(quarantined IN (0,1)),
      capture_id TEXT NOT NULL, binding_digest TEXT NOT NULL,
      config_id TEXT NOT NULL, config_digest TEXT NOT NULL,
      acquire_command_id TEXT NOT NULL, connection_id TEXT NOT NULL,
      connection_digest TEXT NOT NULL, root_fingerprint TEXT NOT NULL,
      preparation_digest TEXT NOT NULL, manifest_digest TEXT NOT NULL,
      item_count INTEGER NOT NULL CHECK(item_count BETWEEN 1 AND 500),
      basis_json TEXT NOT NULL,
      predecessor_set_id TEXT, predecessor_generation INTEGER,
      state TEXT NOT NULL DEFAULT 'prepared' CHECK(state IN ('prepared','active','withdrawn','superseded')),
      policy_generation INTEGER NOT NULL DEFAULT 0 CHECK(policy_generation>=0),
      purposes_json TEXT NOT NULL DEFAULT '[]',
      retain_local INTEGER NOT NULL DEFAULT 0 CHECK(retain_local IN (0,1)),
      policy_digest TEXT,
      prepared_at TEXT NOT NULL, activated_at TEXT, withdrawn_at TEXT,
      lock_version INTEGER NOT NULL DEFAULT 0 CHECK(lock_version>=0),
      UNIQUE(workspace_id,id), UNIQUE(workspace_id,preparation_digest),
      FOREIGN KEY(workspace_id,connection_id) REFERENCES source_connections(workspace_id,id) ON DELETE RESTRICT,
      FOREIGN KEY(workspace_id,predecessor_set_id) REFERENCES local_use_sets(workspace_id,id) ON DELETE RESTRICT,
      CHECK(length(owner_id) BETWEEN 1 AND 128),
      CHECK(length(binding_digest)=64 AND binding_digest NOT GLOB '*[^0-9a-f]*'),
      CHECK(length(config_digest)=64 AND config_digest NOT GLOB '*[^0-9a-f]*'),
      CHECK(length(connection_digest)=64 AND connection_digest NOT GLOB '*[^0-9a-f]*'),
      CHECK(length(root_fingerprint)=64 AND root_fingerprint NOT GLOB '*[^0-9a-f]*'),
      CHECK(length(preparation_digest)=64 AND preparation_digest NOT GLOB '*[^0-9a-f]*'),
      CHECK(length(manifest_digest)=64 AND manifest_digest NOT GLOB '*[^0-9a-f]*'),
      CHECK(policy_digest IS NULL OR (length(policy_digest)=64 AND policy_digest NOT GLOB '*[^0-9a-f]*')),
      CHECK(json_valid(basis_json) AND json_type(basis_json)='object' AND length(CAST(basis_json AS BLOB))<=16384),
      CHECK(json_valid(purposes_json) AND json_type(purposes_json)='array' AND length(CAST(purposes_json AS BLOB))<=128),
      CHECK((predecessor_set_id IS NULL AND predecessor_generation IS NULL) OR
            (predecessor_set_id IS NOT NULL AND predecessor_generation>0)),
      CHECK((state='prepared' AND policy_generation=0 AND policy_digest IS NULL AND retain_local=0 AND activated_at IS NULL AND withdrawn_at IS NULL) OR
            (state IN ('active','superseded') AND policy_generation>0 AND policy_digest IS NOT NULL AND retain_local=1 AND activated_at IS NOT NULL AND withdrawn_at IS NULL) OR
            (state='withdrawn' AND policy_generation>1 AND policy_digest IS NOT NULL AND retain_local=1 AND activated_at IS NOT NULL AND withdrawn_at IS NOT NULL))
    )
    """)

    execute(~S"""
    CREATE TABLE local_use_items (
      set_id TEXT NOT NULL, workspace_id TEXT NOT NULL, source_id TEXT NOT NULL,
      revision_id TEXT NOT NULL, body_hash TEXT NOT NULL, capture_item_key TEXT NOT NULL,
      PRIMARY KEY(set_id,source_id),
      FOREIGN KEY(workspace_id,set_id) REFERENCES local_use_sets(workspace_id,id) ON DELETE RESTRICT,
      CHECK(length(body_hash)=64 AND body_hash NOT GLOB '*[^0-9a-f]*'),
      CHECK(length(CAST(capture_item_key AS BLOB)) BETWEEN 1 AND 4096)
    )
    """)

    execute(~S"""
    CREATE TABLE local_use_enrollments (
      id TEXT PRIMARY KEY NOT NULL, workspace_id TEXT NOT NULL,
      source_id TEXT, set_id TEXT, original_source_id TEXT NOT NULL,
      connection_id TEXT NOT NULL, provider TEXT NOT NULL, external_id TEXT NOT NULL,
      namespace_digest TEXT NOT NULL,
      state TEXT NOT NULL DEFAULT 'bound' CHECK(state IN ('bound','purged_denied')),
      grant_generation INTEGER NOT NULL CHECK(grant_generation>0),
      UNIQUE(workspace_id,source_id), UNIQUE(workspace_id,original_source_id),
      UNIQUE(workspace_id,connection_id,provider,external_id),
      FOREIGN KEY(source_id) REFERENCES evidence_sources(id) ON DELETE SET NULL,
      FOREIGN KEY(set_id) REFERENCES local_use_sets(id) ON DELETE SET NULL,
      CHECK(length(namespace_digest)=64 AND namespace_digest NOT GLOB '*[^0-9a-f]*'),
      CHECK(length(provider) BETWEEN 1 AND 128),
      CHECK(length(CAST(external_id AS BLOB)) BETWEEN 1 AND 4096),
      CHECK((state='bound' AND source_id IS NOT NULL AND set_id IS NOT NULL) OR
            (state='purged_denied' AND source_id IS NULL AND set_id IS NULL))
    )
    """)

    execute(~S"""
    CREATE TABLE local_use_events (
      id TEXT PRIMARY KEY NOT NULL, workspace_id TEXT NOT NULL,
      set_id TEXT, source_id TEXT, stream_key TEXT NOT NULL,
      sequence INTEGER NOT NULL CHECK(sequence>0),
      kind TEXT NOT NULL CHECK(kind IN ('activate','withdraw','upsert','delete','refresh_prepared','refresh_bound','refresh_activated','privacy_barrier','connection_revalidated')),
      command_key TEXT NOT NULL, request_digest TEXT NOT NULL,
      payload_json TEXT NOT NULL, inserted_at TEXT NOT NULL,
      UNIQUE(workspace_id,id), UNIQUE(workspace_id,command_key),
      UNIQUE(workspace_id,stream_key,sequence),
      FOREIGN KEY(workspace_id,set_id) REFERENCES local_use_sets(workspace_id,id) ON DELETE RESTRICT,
      CHECK(length(request_digest)=64 AND request_digest NOT GLOB '*[^0-9a-f]*'),
      CHECK(length(CAST(stream_key AS BLOB)) BETWEEN 1 AND 256),
      CHECK(length(CAST(command_key AS BLOB)) BETWEEN 1 AND 512),
      CHECK(json_valid(payload_json) AND json_type(payload_json)='object' AND length(CAST(payload_json AS BLOB))<=16384)
    )
    """)

    execute(~S"""
    CREATE TABLE local_use_checkpoints (
      event_id TEXT NOT NULL, consumer TEXT NOT NULL DEFAULT 'corpus_invalidation',
      workspace_id TEXT NOT NULL,
      state TEXT NOT NULL DEFAULT 'pending' CHECK(state IN ('pending','completed')),
      cursor_source_id TEXT NOT NULL DEFAULT '', cursor_corpus_id TEXT NOT NULL DEFAULT '',
      lock_version INTEGER NOT NULL DEFAULT 0 CHECK(lock_version>=0), updated_at TEXT NOT NULL,
      PRIMARY KEY(event_id,consumer),
      FOREIGN KEY(workspace_id,event_id) REFERENCES local_use_events(workspace_id,id) ON DELETE RESTRICT,
      CHECK(consumer='corpus_invalidation')
    )
    """)

    for {name, table, columns} <- [
          {"local_use_items_source", "local_use_items", "workspace_id,source_id,revision_id"},
          {"local_use_items_namespace", "local_use_items", "workspace_id,capture_item_key,set_id"},
          {"local_use_enrollments_set", "local_use_enrollments", "workspace_id,set_id,source_id"},
          {"local_use_events_source", "local_use_events", "workspace_id,source_id,sequence"},
          {"local_use_events_set", "local_use_events", "workspace_id,set_id,sequence"},
          {"local_use_checkpoints_pending", "local_use_checkpoints", "workspace_id,state,event_id"}
        ] do
      execute("CREATE INDEX #{name} ON #{table}(#{columns})")
    end

    execute(~S"""
    CREATE TRIGGER local_use_set_owned BEFORE INSERT ON local_use_sets
    WHEN NEW.state!='prepared' OR NEW.origin_workspace_id IS NOT NEW.workspace_id OR NEW.quarantined!=0 OR NOT EXISTS (
      SELECT 1 FROM setup_capture_bindings b JOIN setup_run_configs c ON c.id=b.config_id
      JOIN capture_runs r ON r.id=b.capture_id
      WHERE b.workspace_id=NEW.workspace_id AND b.owner_id=NEW.owner_id AND b.capture_id=NEW.capture_id
        AND b.digest=NEW.binding_digest AND b.config_id=NEW.config_id AND c.digest=NEW.config_digest
        AND c.workspace_id=NEW.workspace_id AND c.owner_id=NEW.owner_id
        AND b.command_id=NEW.acquire_command_id AND b.connection_id=NEW.connection_id
        AND r.workspace_id=NEW.workspace_id AND r.connection_id=NEW.connection_id
        AND b.root_fingerprint=NEW.root_fingerprint AND r.root_fingerprint=NEW.root_fingerprint
    ) BEGIN SELECT RAISE(ABORT,'local use capture ownership required'); END
    """)

    execute(~S"""
    CREATE TRIGGER local_use_set_transition BEFORE UPDATE ON local_use_sets
    WHEN OLD.id IS NOT NEW.id OR OLD.workspace_id IS NOT NEW.workspace_id OR OLD.owner_id IS NOT NEW.owner_id
      OR OLD.origin_workspace_id IS NOT NEW.origin_workspace_id OR OLD.quarantined IS NOT NEW.quarantined
      OR OLD.capture_id IS NOT NEW.capture_id OR OLD.binding_digest IS NOT NEW.binding_digest
      OR OLD.config_id IS NOT NEW.config_id OR OLD.config_digest IS NOT NEW.config_digest
      OR OLD.acquire_command_id IS NOT NEW.acquire_command_id OR OLD.connection_id IS NOT NEW.connection_id
      OR OLD.connection_digest IS NOT NEW.connection_digest OR OLD.root_fingerprint IS NOT NEW.root_fingerprint
      OR OLD.preparation_digest IS NOT NEW.preparation_digest OR OLD.manifest_digest IS NOT NEW.manifest_digest
      OR OLD.item_count IS NOT NEW.item_count OR OLD.basis_json IS NOT NEW.basis_json
      OR OLD.predecessor_set_id IS NOT NEW.predecessor_set_id OR OLD.predecessor_generation IS NOT NEW.predecessor_generation
      OR OLD.prepared_at IS NOT NEW.prepared_at OR NEW.lock_version!=OLD.lock_version+1
      OR NOT (
        (OLD.state='prepared' AND NEW.state='active' AND NEW.policy_generation=COALESCE(OLD.predecessor_generation,0)+1)
        OR (OLD.state='active' AND NEW.state='withdrawn' AND NEW.policy_generation=OLD.policy_generation+1
          AND NEW.purposes_json=OLD.purposes_json AND NEW.policy_digest=OLD.policy_digest
          AND NEW.retain_local=OLD.retain_local AND NEW.activated_at=OLD.activated_at)
        OR (OLD.state='active' AND NEW.state='superseded' AND NEW.policy_generation=OLD.policy_generation
          AND NEW.purposes_json=OLD.purposes_json AND NEW.policy_digest=OLD.policy_digest
          AND NEW.retain_local=OLD.retain_local AND NEW.activated_at=OLD.activated_at)
      )
    BEGIN SELECT RAISE(ABORT,'local use policy cannot rewind'); END
    """)

    execute(~S"""
    CREATE TRIGGER local_use_item_owned BEFORE INSERT ON local_use_items
    WHEN NOT EXISTS (
      SELECT 1 FROM local_use_sets p JOIN capture_items i ON i.run_id=p.capture_id AND i.relative_path=NEW.capture_item_key
      JOIN evidence_sources s ON s.id=NEW.source_id AND s.workspace_id=NEW.workspace_id
      JOIN evidence_revisions r ON r.id=NEW.revision_id AND r.source_id=s.id AND r.workspace_id=s.workspace_id
      WHERE p.id=NEW.set_id AND p.workspace_id=NEW.workspace_id AND p.state='prepared'
        AND s.connection_id=p.connection_id AND i.source_id=s.id AND i.revision_id=r.id
        AND i.body_hash=NEW.body_hash AND r.body_hash=NEW.body_hash AND i.state IN ('captured','unchanged')
    ) BEGIN SELECT RAISE(ABORT,'local use item ownership required'); END
    """)

    execute("CREATE TRIGGER local_use_item_immutable BEFORE UPDATE ON local_use_items BEGIN SELECT RAISE(ABORT,'immutable local use item'); END")
    execute("CREATE TRIGGER local_use_event_immutable BEFORE UPDATE ON local_use_events BEGIN SELECT RAISE(ABORT,'immutable local use event'); END")

    execute(~S"""
    CREATE TRIGGER local_use_enrollment_owned BEFORE INSERT ON local_use_enrollments
    WHEN NEW.state!='bound' OR NEW.original_source_id IS NOT NEW.source_id OR NOT EXISTS (
      SELECT 1 FROM local_use_sets p JOIN local_use_items i ON i.set_id=p.id AND i.workspace_id=p.workspace_id
      JOIN evidence_sources s ON s.id=i.source_id AND s.workspace_id=i.workspace_id
      WHERE p.id=NEW.set_id AND p.workspace_id=NEW.workspace_id AND p.state='active'
        AND p.policy_generation=NEW.grant_generation AND i.source_id=NEW.source_id
        AND s.connection_id=NEW.connection_id AND s.provider=NEW.provider AND s.external_id=NEW.external_id
    ) BEGIN SELECT RAISE(ABORT,'local use enrollment ownership required'); END
    """)

    execute(~S"""
    CREATE TRIGGER local_use_enrollment_monotone BEFORE UPDATE ON local_use_enrollments
    WHEN OLD.id IS NOT NEW.id OR OLD.workspace_id IS NOT NEW.workspace_id
      OR OLD.original_source_id IS NOT NEW.original_source_id
      OR OLD.connection_id IS NOT NEW.connection_id OR OLD.provider IS NOT NEW.provider
      OR OLD.external_id IS NOT NEW.external_id OR OLD.namespace_digest IS NOT NEW.namespace_digest
      OR OLD.state='purged_denied'
      OR NOT (
        (NEW.state='purged_denied' AND NEW.source_id IS NULL AND NEW.set_id IS NULL AND NEW.grant_generation=OLD.grant_generation)
        OR (NEW.state='bound' AND NEW.source_id=OLD.source_id AND NEW.grant_generation=OLD.grant_generation+1
          AND EXISTS(SELECT 1 FROM local_use_sets p JOIN local_use_items i ON i.set_id=p.id
            WHERE p.id=NEW.set_id AND p.workspace_id=NEW.workspace_id AND p.state='active'
              AND p.predecessor_set_id=OLD.set_id AND p.predecessor_generation=OLD.grant_generation
              AND p.policy_generation=NEW.grant_generation AND i.workspace_id=NEW.workspace_id AND i.source_id=NEW.source_id))
      )
    BEGIN SELECT RAISE(ABORT,'local use namespace cannot regain fallback'); END
    """)

    execute(~S"""
    CREATE TRIGGER local_use_checkpoint_monotone BEFORE UPDATE ON local_use_checkpoints
    WHEN OLD.event_id IS NOT NEW.event_id OR OLD.consumer IS NOT NEW.consumer OR OLD.workspace_id IS NOT NEW.workspace_id
      OR OLD.state='completed' OR NEW.lock_version!=OLD.lock_version+1
      OR NEW.cursor_source_id<OLD.cursor_source_id
      OR (NEW.cursor_source_id=OLD.cursor_source_id AND NEW.cursor_corpus_id<OLD.cursor_corpus_id)
    BEGIN SELECT RAISE(ABORT,'local use checkpoint cannot rewind'); END
    """)
  end

  def down do
    if Enum.any?(@tables, fn table ->
         %{rows: [[count]]} = repo().query!("SELECT count(*) FROM #{table}")
         count != 0
       end), do: raise(Ecto.MigrationError, "cannot remove retained source-use restrictions or lifecycle state")

    Enum.each(Enum.reverse(@tables), &execute("DROP TABLE #{&1}"))
  end
end
