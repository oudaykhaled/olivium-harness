defmodule HarnessForge.Repo.Migrations.SetupAnalysisRuns do
  use Ecto.Migration

  @tables ~w(setup_run_configs setup_runs setup_run_states setup_run_preparations setup_run_commands setup_run_operations model_run_authorizations model_run_authorization_states model_run_disclosures setup_capture_bindings setup_capture_counters setup_capture_charges setup_capture_pages)

  def up do
    execute("ALTER TABLE setup_sessions RENAME TO setup_sessions_v1")

    execute(~S"""
    CREATE TABLE setup_sessions (
      id TEXT PRIMARY KEY NOT NULL,
      workspace_id TEXT NOT NULL,
      owner TEXT NOT NULL CHECK(length(owner) BETWEEN 1 AND 128),
      schema_version INTEGER NOT NULL DEFAULT 1 CHECK(schema_version IN (1,2)),
      lock_version INTEGER NOT NULL DEFAULT 1 CHECK(lock_version>0),
      step TEXT NOT NULL CHECK(step IN ('outcome','scope','understanding','review','candidate','evaluation','release')),
      payload TEXT NOT NULL CHECK(json_valid(payload) AND length(CAST(payload AS BLOB))<=16384),
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      UNIQUE(workspace_id,owner,id)
    )
    """)

    execute("INSERT INTO setup_sessions SELECT * FROM setup_sessions_v1")
    execute("DROP TABLE setup_sessions_v1")

    execute(
      "CREATE INDEX setup_sessions_owner_updated ON setup_sessions(workspace_id,owner,updated_at DESC,id DESC)"
    )

    execute(~S"""
    CREATE TABLE setup_run_configs (
      id TEXT PRIMARY KEY NOT NULL,
      workspace_id TEXT NOT NULL,
      owner_id TEXT NOT NULL CHECK(length(owner_id) BETWEEN 1 AND 128),
      session_id TEXT NOT NULL,
      inserted_at TEXT NOT NULL,
      digest TEXT NOT NULL,
      schema_version INTEGER NOT NULL DEFAULT 1,
      scope_json TEXT NOT NULL,
      UNIQUE(workspace_id,owner_id,session_id,id),
      FOREIGN KEY(workspace_id,owner_id,session_id) REFERENCES setup_sessions(workspace_id,owner,id) DEFERRABLE INITIALLY DEFERRED,
      CHECK((length(digest)=64 AND digest NOT GLOB '*[^0-9a-f]*')),
      CHECK(schema_version=1),
      CHECK((json_valid(scope_json) AND json_type(scope_json)='object' AND length(CAST(scope_json AS BLOB))<=16384)),
      UNIQUE(workspace_id,owner_id,session_id,digest)
    )
    """)

    execute(
      "CREATE TRIGGER immutable_setup_run_configs_update BEFORE UPDATE ON setup_run_configs BEGIN SELECT RAISE(ABORT,'immutable setup record'); END"
    )

    execute(
      "CREATE TRIGGER setup_run_configs_session_v2 BEFORE INSERT ON setup_run_configs WHEN NOT EXISTS(SELECT 1 FROM setup_sessions s WHERE s.id=NEW.session_id AND s.workspace_id=NEW.workspace_id AND s.owner=NEW.owner_id AND s.schema_version=2) BEGIN SELECT RAISE(ABORT,'setup v2 ownership required'); END"
    )

    execute(~S"""
    CREATE TABLE setup_runs (
      id TEXT PRIMARY KEY NOT NULL,
      workspace_id TEXT NOT NULL,
      owner_id TEXT NOT NULL CHECK(length(owner_id) BETWEEN 1 AND 128),
      session_id TEXT NOT NULL,
      inserted_at TEXT NOT NULL,
      digest TEXT NOT NULL,
      config_id TEXT NOT NULL,
      predecessor_id TEXT,
      UNIQUE(workspace_id,owner_id,session_id,id),
      FOREIGN KEY(workspace_id,owner_id,session_id) REFERENCES setup_sessions(workspace_id,owner,id) DEFERRABLE INITIALLY DEFERRED,
      FOREIGN KEY(workspace_id,owner_id,session_id,config_id) REFERENCES setup_run_configs(workspace_id,owner_id,session_id,id) DEFERRABLE INITIALLY DEFERRED,
      FOREIGN KEY(workspace_id,owner_id,session_id,predecessor_id) REFERENCES setup_runs(workspace_id,owner_id,session_id,id) DEFERRABLE INITIALLY DEFERRED,
      CHECK((length(digest)=64 AND digest NOT GLOB '*[^0-9a-f]*')),
      UNIQUE(workspace_id,id)
    )
    """)

    execute(
      "CREATE TRIGGER immutable_setup_runs_update BEFORE UPDATE ON setup_runs BEGIN SELECT RAISE(ABORT,'immutable setup record'); END"
    )

    execute(
      "CREATE TRIGGER setup_runs_session_v2 BEFORE INSERT ON setup_runs WHEN NOT EXISTS(SELECT 1 FROM setup_sessions s WHERE s.id=NEW.session_id AND s.workspace_id=NEW.workspace_id AND s.owner=NEW.owner_id AND s.schema_version=2) BEGIN SELECT RAISE(ABORT,'setup v2 ownership required'); END"
    )

    execute(~S"""
    CREATE TABLE setup_run_states (
      id TEXT PRIMARY KEY NOT NULL,
      workspace_id TEXT NOT NULL,
      owner_id TEXT NOT NULL CHECK(length(owner_id) BETWEEN 1 AND 128),
      session_id TEXT NOT NULL,
      inserted_at TEXT NOT NULL,
      run_id TEXT NOT NULL,
      lock_version INTEGER NOT NULL DEFAULT 1,
      phase TEXT NOT NULL,
      last_command_id TEXT NOT NULL,
      capture_id TEXT,
      retrieval_id TEXT,
      preparation_id TEXT,
      authorization_id TEXT,
      result_ref TEXT,
      failure_code TEXT,
      updated_at TEXT NOT NULL,
      UNIQUE(workspace_id,owner_id,session_id,id),
      FOREIGN KEY(workspace_id,owner_id,session_id) REFERENCES setup_sessions(workspace_id,owner,id) DEFERRABLE INITIALLY DEFERRED,
      UNIQUE(workspace_id,owner_id,session_id,run_id,id),
      FOREIGN KEY(workspace_id,owner_id,session_id,run_id) REFERENCES setup_runs(workspace_id,owner_id,session_id,id) DEFERRABLE INITIALLY DEFERRED,
      FOREIGN KEY(workspace_id,owner_id,session_id,last_command_id) REFERENCES setup_run_commands(workspace_id,owner_id,session_id,command_id) DEFERRABLE INITIALLY DEFERRED,
      FOREIGN KEY(workspace_id,owner_id,session_id,run_id,preparation_id) REFERENCES setup_run_preparations(workspace_id,owner_id,session_id,run_id,id) DEFERRABLE INITIALLY DEFERRED,
      FOREIGN KEY(workspace_id,owner_id,session_id,run_id,authorization_id) REFERENCES model_run_authorizations(workspace_id,owner_id,session_id,run_id,id) DEFERRABLE INITIALLY DEFERRED,
      CHECK(lock_version>0),
      CHECK((result_ref IS NULL OR (json_valid(result_ref) AND json_type(result_ref)='object' AND length(CAST(result_ref AS BLOB))<=16384))),
      CHECK(phase IN ('proposed','acquiring','captured','retrieving','needs_input','ready','running','completed','blocked','cancelled','expired')),
      CHECK((failure_code IS NULL OR failure_code IN ('invalid_input','unauthorized','not_found','conflict','command_conflict','phase_conflict','stale_preparation','stale_scope','consent_required','authorization_required','authorization_expired','run_replacement_required','model_unavailable','unsupported_configuration','acquisition_incomplete','acquisition_outcome_unknown','budget_exhausted','request_outcome_unknown','cancelled','unavailable'))),
      UNIQUE(workspace_id,run_id)
    )
    """)

    execute(
      "CREATE TRIGGER immutable_setup_run_states_identity BEFORE UPDATE ON setup_run_states WHEN OLD.id IS NOT NEW.id OR OLD.workspace_id IS NOT NEW.workspace_id OR OLD.owner_id IS NOT NEW.owner_id OR OLD.session_id IS NOT NEW.session_id OR OLD.inserted_at IS NOT NEW.inserted_at OR OLD.run_id IS NOT NEW.run_id OR (OLD.capture_id IS NOT NULL AND OLD.capture_id IS NOT NEW.capture_id) OR (OLD.authorization_id IS NOT NULL AND OLD.authorization_id IS NOT NEW.authorization_id) OR (OLD.preparation_id IS NOT NULL AND OLD.preparation_id IS NOT NEW.preparation_id) OR (OLD.retrieval_id IS NOT NULL AND OLD.retrieval_id IS NOT NEW.retrieval_id) BEGIN SELECT RAISE(ABORT,'immutable setup identity'); END"
    )

    execute(
      "CREATE TRIGGER setup_run_states_session_v2 BEFORE INSERT ON setup_run_states WHEN NOT EXISTS(SELECT 1 FROM setup_sessions s WHERE s.id=NEW.session_id AND s.workspace_id=NEW.workspace_id AND s.owner=NEW.owner_id AND s.schema_version=2) BEGIN SELECT RAISE(ABORT,'setup v2 ownership required'); END"
    )

    execute(~S"""
    CREATE TABLE setup_run_preparations (
      id TEXT PRIMARY KEY NOT NULL,
      workspace_id TEXT NOT NULL,
      owner_id TEXT NOT NULL CHECK(length(owner_id) BETWEEN 1 AND 128),
      session_id TEXT NOT NULL,
      inserted_at TEXT NOT NULL,
      digest TEXT NOT NULL,
      run_id TEXT NOT NULL,
      config_id TEXT NOT NULL,
      operation_id TEXT NOT NULL,
      retrieval_ref TEXT NOT NULL,
      stage_ref TEXT NOT NULL,
      manifest_ref TEXT NOT NULL,
      context_digest TEXT NOT NULL,
      context_json TEXT NOT NULL,
      checked_pack_json TEXT NOT NULL,
      prompt_bytes TEXT NOT NULL,
      prompt_sha256 TEXT NOT NULL,
      request_body_bytes TEXT NOT NULL,
      request_body_sha256 TEXT NOT NULL,
      UNIQUE(workspace_id,owner_id,session_id,id),
      FOREIGN KEY(workspace_id,owner_id,session_id) REFERENCES setup_sessions(workspace_id,owner,id) DEFERRABLE INITIALLY DEFERRED,
      UNIQUE(workspace_id,owner_id,session_id,run_id,id),
      FOREIGN KEY(workspace_id,owner_id,session_id,run_id) REFERENCES setup_runs(workspace_id,owner_id,session_id,id) DEFERRABLE INITIALLY DEFERRED,
      FOREIGN KEY(workspace_id,owner_id,session_id,config_id) REFERENCES setup_run_configs(workspace_id,owner_id,session_id,id) DEFERRABLE INITIALLY DEFERRED,
      CHECK((length(digest)=64 AND digest NOT GLOB '*[^0-9a-f]*')),
      CHECK((json_valid(retrieval_ref) AND json_type(retrieval_ref)='object' AND length(CAST(retrieval_ref AS BLOB))<=131072)),
      CHECK((json_valid(stage_ref) AND json_type(stage_ref)='object' AND length(CAST(stage_ref AS BLOB))<=131072)),
      CHECK((json_valid(manifest_ref) AND json_type(manifest_ref)='object' AND length(CAST(manifest_ref AS BLOB))<=131072)),
      CHECK((length(context_digest)=64 AND context_digest NOT GLOB '*[^0-9a-f]*')),
      CHECK((json_valid(context_json) AND json_type(context_json)='object' AND length(CAST(context_json AS BLOB))<=131072)),
      CHECK((json_valid(checked_pack_json) AND json_type(checked_pack_json)='object' AND length(CAST(checked_pack_json AS BLOB))<=131072)),
      CHECK((length(prompt_sha256)=64 AND prompt_sha256 NOT GLOB '*[^0-9a-f]*')),
      CHECK((length(request_body_sha256)=64 AND request_body_sha256 NOT GLOB '*[^0-9a-f]*')),
      CHECK(length(CAST(checked_pack_json AS BLOB))+length(CAST(prompt_bytes AS BLOB))+length(CAST(request_body_bytes AS BLOB))<=262144),
      UNIQUE(workspace_id,run_id),
      UNIQUE(workspace_id,operation_id)
    )
    """)

    execute(
      "CREATE TRIGGER immutable_setup_run_preparations_update BEFORE UPDATE ON setup_run_preparations BEGIN SELECT RAISE(ABORT,'immutable setup record'); END"
    )

    execute(
      "CREATE TRIGGER setup_run_preparations_session_v2 BEFORE INSERT ON setup_run_preparations WHEN NOT EXISTS(SELECT 1 FROM setup_sessions s WHERE s.id=NEW.session_id AND s.workspace_id=NEW.workspace_id AND s.owner=NEW.owner_id AND s.schema_version=2) BEGIN SELECT RAISE(ABORT,'setup v2 ownership required'); END"
    )

    execute(~S"""
    CREATE TABLE setup_run_commands (
      id TEXT PRIMARY KEY NOT NULL,
      workspace_id TEXT NOT NULL,
      owner_id TEXT NOT NULL CHECK(length(owner_id) BETWEEN 1 AND 128),
      session_id TEXT NOT NULL,
      inserted_at TEXT NOT NULL,
      run_id TEXT NOT NULL,
      command_id TEXT NOT NULL,
      request_digest TEXT NOT NULL,
      request_json TEXT NOT NULL,
      receipt_json TEXT NOT NULL,
      UNIQUE(workspace_id,owner_id,session_id,id),
      FOREIGN KEY(workspace_id,owner_id,session_id) REFERENCES setup_sessions(workspace_id,owner,id) DEFERRABLE INITIALLY DEFERRED,
      UNIQUE(workspace_id,owner_id,session_id,run_id,id),
      FOREIGN KEY(workspace_id,owner_id,session_id,run_id) REFERENCES setup_runs(workspace_id,owner_id,session_id,id) DEFERRABLE INITIALLY DEFERRED,
      CHECK((length(request_digest)=64 AND request_digest NOT GLOB '*[^0-9a-f]*')),
      CHECK((json_valid(request_json) AND json_type(request_json)='object' AND length(CAST(request_json AS BLOB))<=16384)),
      CHECK((json_valid(receipt_json) AND json_type(receipt_json)='object' AND length(CAST(receipt_json AS BLOB))<=16384)),
      UNIQUE(workspace_id,owner_id,session_id,command_id)
    )
    """)

    execute(
      "CREATE TRIGGER immutable_setup_run_commands_update BEFORE UPDATE ON setup_run_commands BEGIN SELECT RAISE(ABORT,'immutable setup record'); END"
    )

    execute(
      "CREATE TRIGGER setup_run_commands_session_v2 BEFORE INSERT ON setup_run_commands WHEN NOT EXISTS(SELECT 1 FROM setup_sessions s WHERE s.id=NEW.session_id AND s.workspace_id=NEW.workspace_id AND s.owner=NEW.owner_id AND s.schema_version=2) BEGIN SELECT RAISE(ABORT,'setup v2 ownership required'); END"
    )

    execute(~S"""
    CREATE TABLE setup_run_operations (
      id TEXT PRIMARY KEY NOT NULL,
      workspace_id TEXT NOT NULL,
      owner_id TEXT NOT NULL CHECK(length(owner_id) BETWEEN 1 AND 128),
      session_id TEXT NOT NULL,
      inserted_at TEXT NOT NULL,
      digest TEXT NOT NULL,
      run_id TEXT NOT NULL,
      config_id TEXT NOT NULL,
      command_id TEXT NOT NULL,
      operation_id TEXT NOT NULL,
      kind TEXT NOT NULL,
      preparation_id TEXT,
      authorization_id TEXT,
      expected_run_version INTEGER NOT NULL,
      generations_json TEXT NOT NULL DEFAULT '[]',
      UNIQUE(workspace_id,owner_id,session_id,id),
      FOREIGN KEY(workspace_id,owner_id,session_id) REFERENCES setup_sessions(workspace_id,owner,id) DEFERRABLE INITIALLY DEFERRED,
      UNIQUE(workspace_id,owner_id,session_id,run_id,id),
      FOREIGN KEY(workspace_id,owner_id,session_id,run_id) REFERENCES setup_runs(workspace_id,owner_id,session_id,id) DEFERRABLE INITIALLY DEFERRED,
      FOREIGN KEY(workspace_id,owner_id,session_id,config_id) REFERENCES setup_run_configs(workspace_id,owner_id,session_id,id) DEFERRABLE INITIALLY DEFERRED,
      FOREIGN KEY(workspace_id,owner_id,session_id,command_id) REFERENCES setup_run_commands(workspace_id,owner_id,session_id,command_id) DEFERRABLE INITIALLY DEFERRED,
      FOREIGN KEY(workspace_id,owner_id,session_id,run_id,preparation_id) REFERENCES setup_run_preparations(workspace_id,owner_id,session_id,run_id,id) DEFERRABLE INITIALLY DEFERRED,
      FOREIGN KEY(workspace_id,owner_id,session_id,run_id,authorization_id) REFERENCES model_run_authorizations(workspace_id,owner_id,session_id,run_id,id) DEFERRABLE INITIALLY DEFERRED,
      CHECK((length(digest)=64 AND digest NOT GLOB '*[^0-9a-f]*')),
      CHECK(expected_run_version>0),
      CHECK((json_valid(generations_json) AND json_type(generations_json)='array' AND length(CAST(generations_json AS BLOB))<=16384)),
      CHECK(id=operation_id),
      CHECK(kind IN ('capture','retrieval','analysis')),
      CHECK(((kind='analysis' AND preparation_id IS NOT NULL AND authorization_id IS NOT NULL) OR (kind IN ('capture','retrieval') AND preparation_id IS NULL AND authorization_id IS NULL))),
      UNIQUE(workspace_id,operation_id),
      UNIQUE(workspace_id,command_id)
    )
    """)

    execute(
      "CREATE TRIGGER immutable_setup_run_operations_update BEFORE UPDATE ON setup_run_operations BEGIN SELECT RAISE(ABORT,'immutable setup record'); END"
    )

    execute(
      "CREATE TRIGGER setup_run_operations_session_v2 BEFORE INSERT ON setup_run_operations WHEN NOT EXISTS(SELECT 1 FROM setup_sessions s WHERE s.id=NEW.session_id AND s.workspace_id=NEW.workspace_id AND s.owner=NEW.owner_id AND s.schema_version=2) BEGIN SELECT RAISE(ABORT,'setup v2 ownership required'); END"
    )

    execute(~S"""
    CREATE TABLE model_run_authorizations (
      id TEXT PRIMARY KEY NOT NULL,
      workspace_id TEXT NOT NULL,
      owner_id TEXT NOT NULL CHECK(length(owner_id) BETWEEN 1 AND 128),
      session_id TEXT NOT NULL,
      inserted_at TEXT NOT NULL,
      digest TEXT NOT NULL,
      run_id TEXT NOT NULL,
      config_id TEXT NOT NULL,
      preparation_id TEXT NOT NULL,
      scope_digest TEXT NOT NULL,
      descriptor_json TEXT NOT NULL,
      budget_id TEXT NOT NULL,
      max_requests INTEGER NOT NULL,
      max_tokens INTEGER NOT NULL,
      max_cost_microusd INTEGER NOT NULL,
      authorized_at TEXT NOT NULL,
      expires_at TEXT NOT NULL,
      command_id TEXT NOT NULL,
      UNIQUE(workspace_id,owner_id,session_id,id),
      FOREIGN KEY(workspace_id,owner_id,session_id) REFERENCES setup_sessions(workspace_id,owner,id) DEFERRABLE INITIALLY DEFERRED,
      UNIQUE(workspace_id,owner_id,session_id,run_id,id),
      FOREIGN KEY(workspace_id,owner_id,session_id,run_id) REFERENCES setup_runs(workspace_id,owner_id,session_id,id) DEFERRABLE INITIALLY DEFERRED,
      FOREIGN KEY(workspace_id,owner_id,session_id,config_id) REFERENCES setup_run_configs(workspace_id,owner_id,session_id,id) DEFERRABLE INITIALLY DEFERRED,
      FOREIGN KEY(workspace_id,owner_id,session_id,command_id) REFERENCES setup_run_commands(workspace_id,owner_id,session_id,command_id) DEFERRABLE INITIALLY DEFERRED,
      FOREIGN KEY(workspace_id,owner_id,session_id,run_id,preparation_id) REFERENCES setup_run_preparations(workspace_id,owner_id,session_id,run_id,id) DEFERRABLE INITIALLY DEFERRED,
      CHECK((length(digest)=64 AND digest NOT GLOB '*[^0-9a-f]*')),
      CHECK((length(scope_digest)=64 AND scope_digest NOT GLOB '*[^0-9a-f]*')),
      CHECK((json_valid(descriptor_json) AND json_type(descriptor_json)='object' AND length(CAST(descriptor_json AS BLOB))<=16384)),
      CHECK(max_requests>=0),
      CHECK(max_tokens>=0),
      CHECK(max_cost_microusd>=0),
      CHECK(max_requests=2),
      CHECK(max_tokens=100000),
      CHECK(max_cost_microusd=0),
      CHECK(julianday(expires_at)>julianday(authorized_at)),
      CHECK(abs((julianday(expires_at)-julianday(authorized_at))*86400-300)<0.01),
      UNIQUE(workspace_id,run_id),
      UNIQUE(workspace_id,budget_id)
    )
    """)

    execute(
      "CREATE TRIGGER immutable_model_run_authorizations_update BEFORE UPDATE ON model_run_authorizations BEGIN SELECT RAISE(ABORT,'immutable setup record'); END"
    )

    execute(
      "CREATE TRIGGER model_run_authorizations_session_v2 BEFORE INSERT ON model_run_authorizations WHEN NOT EXISTS(SELECT 1 FROM setup_sessions s WHERE s.id=NEW.session_id AND s.workspace_id=NEW.workspace_id AND s.owner=NEW.owner_id AND s.schema_version=2) BEGIN SELECT RAISE(ABORT,'setup v2 ownership required'); END"
    )

    execute(~S"""
    CREATE TABLE model_run_authorization_states (
      id TEXT PRIMARY KEY NOT NULL,
      workspace_id TEXT NOT NULL,
      owner_id TEXT NOT NULL CHECK(length(owner_id) BETWEEN 1 AND 128),
      session_id TEXT NOT NULL,
      inserted_at TEXT NOT NULL,
      authorization_id TEXT NOT NULL,
      lock_version INTEGER NOT NULL DEFAULT 1,
      revoked_at TEXT,
      reason TEXT,
      UNIQUE(workspace_id,owner_id,session_id,id),
      FOREIGN KEY(workspace_id,owner_id,session_id) REFERENCES setup_sessions(workspace_id,owner,id) DEFERRABLE INITIALLY DEFERRED,
      FOREIGN KEY(workspace_id,owner_id,session_id,authorization_id) REFERENCES model_run_authorizations(workspace_id,owner_id,session_id,id) DEFERRABLE INITIALLY DEFERRED,
      CHECK(lock_version>0),
      CHECK(((revoked_at IS NULL AND reason IS NULL) OR (revoked_at IS NOT NULL AND reason IN ('cancelled','scope_changed','restored')))),
      UNIQUE(workspace_id,authorization_id)
    )
    """)

    execute(
      "CREATE TRIGGER immutable_model_run_authorization_states_identity BEFORE UPDATE ON model_run_authorization_states WHEN OLD.id IS NOT NEW.id OR OLD.workspace_id IS NOT NEW.workspace_id OR OLD.owner_id IS NOT NEW.owner_id OR OLD.session_id IS NOT NEW.session_id OR OLD.inserted_at IS NOT NEW.inserted_at OR OLD.authorization_id IS NOT NEW.authorization_id BEGIN SELECT RAISE(ABORT,'immutable setup identity'); END"
    )

    execute(
      "CREATE TRIGGER model_run_authorization_states_session_v2 BEFORE INSERT ON model_run_authorization_states WHEN NOT EXISTS(SELECT 1 FROM setup_sessions s WHERE s.id=NEW.session_id AND s.workspace_id=NEW.workspace_id AND s.owner=NEW.owner_id AND s.schema_version=2) BEGIN SELECT RAISE(ABORT,'setup v2 ownership required'); END"
    )

    execute(~S"""
    CREATE TABLE model_run_disclosures (
      id TEXT PRIMARY KEY NOT NULL,
      workspace_id TEXT NOT NULL,
      owner_id TEXT NOT NULL CHECK(length(owner_id) BETWEEN 1 AND 128),
      session_id TEXT NOT NULL,
      inserted_at TEXT NOT NULL,
      run_id TEXT NOT NULL,
      config_id TEXT NOT NULL,
      preparation_id TEXT NOT NULL,
      stage_ref TEXT NOT NULL,
      manifest_ref TEXT NOT NULL,
      consent_id TEXT NOT NULL,
      consent_revision INTEGER NOT NULL,
      context_digest TEXT NOT NULL,
      command_id TEXT NOT NULL,
      digest TEXT NOT NULL,
      UNIQUE(workspace_id,owner_id,session_id,id),
      FOREIGN KEY(workspace_id,owner_id,session_id) REFERENCES setup_sessions(workspace_id,owner,id) DEFERRABLE INITIALLY DEFERRED,
      UNIQUE(workspace_id,owner_id,session_id,run_id,id),
      FOREIGN KEY(workspace_id,owner_id,session_id,run_id) REFERENCES setup_runs(workspace_id,owner_id,session_id,id) DEFERRABLE INITIALLY DEFERRED,
      FOREIGN KEY(workspace_id,owner_id,session_id,config_id) REFERENCES setup_run_configs(workspace_id,owner_id,session_id,id) DEFERRABLE INITIALLY DEFERRED,
      FOREIGN KEY(workspace_id,owner_id,session_id,command_id) REFERENCES setup_run_commands(workspace_id,owner_id,session_id,command_id) DEFERRABLE INITIALLY DEFERRED,
      FOREIGN KEY(workspace_id,owner_id,session_id,run_id,preparation_id) REFERENCES setup_run_preparations(workspace_id,owner_id,session_id,run_id,id) DEFERRABLE INITIALLY DEFERRED,
      CHECK((json_valid(stage_ref) AND json_type(stage_ref)='object' AND length(CAST(stage_ref AS BLOB))<=16384)),
      CHECK((json_valid(manifest_ref) AND json_type(manifest_ref)='object' AND length(CAST(manifest_ref AS BLOB))<=16384)),
      CHECK(consent_revision>0),
      CHECK((length(context_digest)=64 AND context_digest NOT GLOB '*[^0-9a-f]*')),
      CHECK((length(digest)=64 AND digest NOT GLOB '*[^0-9a-f]*')),
      UNIQUE(workspace_id,run_id),
      UNIQUE(workspace_id,preparation_id)
    )
    """)

    execute(
      "CREATE TRIGGER immutable_model_run_disclosures_update BEFORE UPDATE ON model_run_disclosures BEGIN SELECT RAISE(ABORT,'immutable setup record'); END"
    )

    execute(
      "CREATE TRIGGER model_run_disclosures_session_v2 BEFORE INSERT ON model_run_disclosures WHEN NOT EXISTS(SELECT 1 FROM setup_sessions s WHERE s.id=NEW.session_id AND s.workspace_id=NEW.workspace_id AND s.owner=NEW.owner_id AND s.schema_version=2) BEGIN SELECT RAISE(ABORT,'setup v2 ownership required'); END"
    )

    execute(~S"""
    CREATE TABLE setup_capture_bindings (
      id TEXT PRIMARY KEY NOT NULL,
      workspace_id TEXT NOT NULL,
      owner_id TEXT NOT NULL CHECK(length(owner_id) BETWEEN 1 AND 128),
      session_id TEXT NOT NULL,
      inserted_at TEXT NOT NULL,
      run_id TEXT NOT NULL,
      config_id TEXT NOT NULL,
      capture_id TEXT NOT NULL,
      command_id TEXT NOT NULL,
      connection_id TEXT NOT NULL,
      root_fingerprint TEXT NOT NULL,
      limits_json TEXT NOT NULL,
      accepted_at TEXT NOT NULL,
      deadline TEXT NOT NULL,
      digest TEXT NOT NULL,
      UNIQUE(workspace_id,owner_id,session_id,id),
      FOREIGN KEY(workspace_id,owner_id,session_id) REFERENCES setup_sessions(workspace_id,owner,id) DEFERRABLE INITIALLY DEFERRED,
      UNIQUE(workspace_id,owner_id,session_id,run_id,id),
      FOREIGN KEY(workspace_id,owner_id,session_id,run_id) REFERENCES setup_runs(workspace_id,owner_id,session_id,id) DEFERRABLE INITIALLY DEFERRED,
      FOREIGN KEY(workspace_id,owner_id,session_id,config_id) REFERENCES setup_run_configs(workspace_id,owner_id,session_id,id) DEFERRABLE INITIALLY DEFERRED,
      FOREIGN KEY(workspace_id,owner_id,session_id,command_id) REFERENCES setup_run_commands(workspace_id,owner_id,session_id,command_id) DEFERRABLE INITIALLY DEFERRED,
      FOREIGN KEY(capture_id) REFERENCES capture_runs(id) DEFERRABLE INITIALLY DEFERRED,
      CHECK((length(root_fingerprint)=64 AND root_fingerprint NOT GLOB '*[^0-9a-f]*')),
      CHECK((json_valid(limits_json) AND json_type(limits_json)='object' AND length(CAST(limits_json AS BLOB))<=16384)),
      CHECK((length(digest)=64 AND digest NOT GLOB '*[^0-9a-f]*')),
      CHECK(julianday(deadline)>julianday(accepted_at)),
      CHECK(abs((julianday(deadline)-julianday(accepted_at))*86400-600)<0.01),
      UNIQUE(workspace_id,run_id),
      UNIQUE(workspace_id,capture_id)
    )
    """)

    execute(
      "CREATE TRIGGER immutable_setup_capture_bindings_update BEFORE UPDATE ON setup_capture_bindings BEGIN SELECT RAISE(ABORT,'immutable setup record'); END"
    )

    execute(
      "CREATE TRIGGER setup_capture_bindings_session_v2 BEFORE INSERT ON setup_capture_bindings WHEN NOT EXISTS(SELECT 1 FROM setup_sessions s WHERE s.id=NEW.session_id AND s.workspace_id=NEW.workspace_id AND s.owner=NEW.owner_id AND s.schema_version=2) BEGIN SELECT RAISE(ABORT,'setup v2 ownership required'); END"
    )

    execute(~S"""
    CREATE TABLE setup_capture_counters (
      id TEXT PRIMARY KEY NOT NULL,
      workspace_id TEXT NOT NULL,
      owner_id TEXT NOT NULL CHECK(length(owner_id) BETWEEN 1 AND 128),
      session_id TEXT NOT NULL,
      inserted_at TEXT NOT NULL,
      capture_id TEXT NOT NULL,
      lock_version INTEGER NOT NULL DEFAULT 1,
      entries_admitted INTEGER NOT NULL DEFAULT 0,
      files_reserved INTEGER NOT NULL DEFAULT 0,
      bytes_reserved INTEGER NOT NULL DEFAULT 0,
      bytes_committed INTEGER NOT NULL DEFAULT 0,
      UNIQUE(workspace_id,owner_id,session_id,id),
      FOREIGN KEY(workspace_id,owner_id,session_id) REFERENCES setup_sessions(workspace_id,owner,id) DEFERRABLE INITIALLY DEFERRED,
      FOREIGN KEY(workspace_id,owner_id,session_id,capture_id) REFERENCES setup_capture_bindings(workspace_id,owner_id,session_id,capture_id) DEFERRABLE INITIALLY DEFERRED,
      CHECK(lock_version>0),
      CHECK(entries_admitted>=0),
      CHECK(files_reserved>=0),
      CHECK(bytes_reserved>=0),
      CHECK(bytes_committed>=0),
      CHECK(entries_admitted<=10000),
      CHECK(files_reserved<=500),
      CHECK(bytes_reserved<=16777216),
      CHECK(bytes_committed<=bytes_reserved),
      UNIQUE(workspace_id,capture_id)
    )
    """)

    execute(
      "CREATE TRIGGER immutable_setup_capture_counters_identity BEFORE UPDATE ON setup_capture_counters WHEN OLD.id IS NOT NEW.id OR OLD.workspace_id IS NOT NEW.workspace_id OR OLD.owner_id IS NOT NEW.owner_id OR OLD.session_id IS NOT NEW.session_id OR OLD.inserted_at IS NOT NEW.inserted_at OR OLD.capture_id IS NOT NEW.capture_id BEGIN SELECT RAISE(ABORT,'immutable setup identity'); END"
    )

    execute(
      "CREATE TRIGGER setup_capture_counters_session_v2 BEFORE INSERT ON setup_capture_counters WHEN NOT EXISTS(SELECT 1 FROM setup_sessions s WHERE s.id=NEW.session_id AND s.workspace_id=NEW.workspace_id AND s.owner=NEW.owner_id AND s.schema_version=2) BEGIN SELECT RAISE(ABORT,'setup v2 ownership required'); END"
    )

    execute(~S"""
    CREATE TABLE setup_capture_charges (
      id TEXT PRIMARY KEY NOT NULL,
      workspace_id TEXT NOT NULL,
      owner_id TEXT NOT NULL CHECK(length(owner_id) BETWEEN 1 AND 128),
      session_id TEXT NOT NULL,
      inserted_at TEXT NOT NULL,
      capture_id TEXT NOT NULL,
      kind TEXT NOT NULL,
      relative_path TEXT NOT NULL,
      fingerprint_json TEXT NOT NULL,
      allowance_bytes INTEGER NOT NULL,
      lease_generation INTEGER NOT NULL,
      lease_token TEXT NOT NULL,
      state TEXT NOT NULL,
      actual_bytes INTEGER,
      source_ref TEXT,
      revision_ref TEXT,
      content_hash TEXT,
      lock_version INTEGER NOT NULL DEFAULT 1,
      UNIQUE(workspace_id,owner_id,session_id,id),
      FOREIGN KEY(workspace_id,owner_id,session_id) REFERENCES setup_sessions(workspace_id,owner,id) DEFERRABLE INITIALLY DEFERRED,
      FOREIGN KEY(workspace_id,owner_id,session_id,capture_id) REFERENCES setup_capture_bindings(workspace_id,owner_id,session_id,capture_id) DEFERRABLE INITIALLY DEFERRED,
      CHECK((json_valid(fingerprint_json) AND json_type(fingerprint_json)='object' AND length(CAST(fingerprint_json AS BLOB))<=16384)),
      CHECK(allowance_bytes>=0),
      CHECK(lease_generation>=0),
      CHECK((actual_bytes IS NULL OR actual_bytes>=0)),
      CHECK((source_ref IS NULL OR (json_valid(source_ref) AND json_type(source_ref)='object' AND length(CAST(source_ref AS BLOB))<=16384))),
      CHECK((revision_ref IS NULL OR (json_valid(revision_ref) AND json_type(revision_ref)='object' AND length(CAST(revision_ref AS BLOB))<=16384))),
      CHECK((content_hash IS NULL OR (length(content_hash)=64 AND content_hash NOT GLOB '*[^0-9a-f]*'))),
      CHECK(lock_version>0),
      CHECK(kind IN ('entry','body')),
      CHECK(state IN ('reserved','committed','uncertain')),
      CHECK(allowance_bytes<=1048576),
      CHECK((kind!='entry' OR allowance_bytes=0)),
      CHECK((actual_bytes IS NULL OR actual_bytes<=allowance_bytes)),
      CHECK((state!='committed' OR actual_bytes IS NOT NULL)),
      CHECK(length(CAST(relative_path AS BLOB)) BETWEEN 1 AND 4096),
      UNIQUE(workspace_id,capture_id,kind,relative_path)
    )
    """)

    execute(
      "CREATE TRIGGER immutable_setup_capture_charges_identity BEFORE UPDATE ON setup_capture_charges WHEN OLD.id IS NOT NEW.id OR OLD.workspace_id IS NOT NEW.workspace_id OR OLD.owner_id IS NOT NEW.owner_id OR OLD.session_id IS NOT NEW.session_id OR OLD.inserted_at IS NOT NEW.inserted_at OR OLD.capture_id IS NOT NEW.capture_id OR OLD.kind IS NOT NEW.kind OR OLD.relative_path IS NOT NEW.relative_path OR OLD.fingerprint_json IS NOT NEW.fingerprint_json OR OLD.allowance_bytes IS NOT NEW.allowance_bytes OR OLD.lease_generation IS NOT NEW.lease_generation OR OLD.lease_token IS NOT NEW.lease_token BEGIN SELECT RAISE(ABORT,'immutable setup identity'); END"
    )

    execute(
      "CREATE TRIGGER setup_capture_charges_session_v2 BEFORE INSERT ON setup_capture_charges WHEN NOT EXISTS(SELECT 1 FROM setup_sessions s WHERE s.id=NEW.session_id AND s.workspace_id=NEW.workspace_id AND s.owner=NEW.owner_id AND s.schema_version=2) BEGIN SELECT RAISE(ABORT,'setup v2 ownership required'); END"
    )

    execute(~S"""
    CREATE TABLE setup_capture_pages (
      id TEXT PRIMARY KEY NOT NULL,
      workspace_id TEXT NOT NULL,
      owner_id TEXT NOT NULL CHECK(length(owner_id) BETWEEN 1 AND 128),
      session_id TEXT NOT NULL,
      inserted_at TEXT NOT NULL,
      capture_id TEXT NOT NULL,
      scan_epoch INTEGER NOT NULL,
      directory TEXT NOT NULL,
      sequence INTEGER NOT NULL,
      payload_digest TEXT NOT NULL,
      admitted_count INTEGER NOT NULL,
      UNIQUE(workspace_id,owner_id,session_id,id),
      FOREIGN KEY(workspace_id,owner_id,session_id) REFERENCES setup_sessions(workspace_id,owner,id) DEFERRABLE INITIALLY DEFERRED,
      FOREIGN KEY(workspace_id,owner_id,session_id,capture_id) REFERENCES setup_capture_bindings(workspace_id,owner_id,session_id,capture_id) DEFERRABLE INITIALLY DEFERRED,
      CHECK(scan_epoch>=0),
      CHECK(sequence>=0),
      CHECK((length(payload_digest)=64 AND payload_digest NOT GLOB '*[^0-9a-f]*')),
      CHECK(admitted_count>=0),
      CHECK(admitted_count<=100),
      CHECK(length(CAST(directory AS BLOB))<=4096),
      UNIQUE(workspace_id,capture_id,scan_epoch,directory,sequence)
    )
    """)

    execute(
      "CREATE TRIGGER immutable_setup_capture_pages_update BEFORE UPDATE ON setup_capture_pages BEGIN SELECT RAISE(ABORT,'immutable setup record'); END"
    )

    execute(
      "CREATE TRIGGER setup_capture_pages_session_v2 BEFORE INSERT ON setup_capture_pages WHEN NOT EXISTS(SELECT 1 FROM setup_sessions s WHERE s.id=NEW.session_id AND s.workspace_id=NEW.workspace_id AND s.owner=NEW.owner_id AND s.schema_version=2) BEGIN SELECT RAISE(ABORT,'setup v2 ownership required'); END"
    )

    execute(
      "CREATE UNIQUE INDEX setup_capture_owned_id ON setup_capture_bindings(workspace_id,owner_id,session_id,capture_id)"
    )

    execute(
      "CREATE UNIQUE INDEX setup_run_one_capture ON setup_run_operations(workspace_id,run_id) WHERE kind='capture'"
    )

    execute(
      "CREATE UNIQUE INDEX setup_run_one_retrieval ON setup_run_operations(workspace_id,run_id) WHERE kind='retrieval'"
    )

    execute(
      "CREATE INDEX setup_preparation_stage ON setup_run_preparations(workspace_id,json_extract(stage_ref,'$.id'))"
    )

    execute("ALTER TABLE stage_operations ADD COLUMN authorization_id TEXT")
    execute("ALTER TABLE stage_operations ADD COLUMN budget_id TEXT")
    execute("ALTER TABLE stage_operations ADD COLUMN operation_binding_digest TEXT")

    for operation <- ~w(INSERT UPDATE) do
      execute("""
      CREATE TRIGGER setup_stage_binding_#{String.downcase(operation)} BEFORE #{operation} ON stage_operations
      WHEN NOT (
        (NEW.authorization_id IS NULL AND NEW.budget_id IS NULL AND NEW.operation_binding_digest IS NULL
          AND NOT EXISTS(SELECT 1 FROM setup_run_operations o WHERE o.workspace_id=NEW.workspace_id AND o.operation_id=NEW.id))
        OR
        (NEW.authorization_id IS NOT NULL AND NEW.budget_id IS NOT NULL
          AND length(NEW.operation_binding_digest)=64 AND NEW.operation_binding_digest NOT GLOB '*[^0-9a-f]*'
          AND EXISTS(SELECT 1 FROM setup_run_operations o JOIN model_run_authorizations a
            ON a.id=o.authorization_id AND a.workspace_id=o.workspace_id AND a.run_id=o.run_id
            WHERE o.workspace_id=NEW.workspace_id AND o.operation_id=NEW.id AND o.kind='analysis'
              AND o.authorization_id=NEW.authorization_id AND a.budget_id=NEW.budget_id
              AND o.digest=NEW.operation_binding_digest))
      ) BEGIN SELECT RAISE(ABORT,'setup operation binding required'); END
      """)
    end

    execute("""
    CREATE TRIGGER setup_capture_charge_terminal BEFORE UPDATE ON setup_capture_charges
    WHEN OLD.state!='reserved' OR NEW.state NOT IN ('committed','uncertain') OR NEW.lock_version!=OLD.lock_version+1
    BEGIN SELECT RAISE(ABORT,'capture charge already settled'); END
    """)

    execute("""
    CREATE TRIGGER setup_capture_counter_monotone BEFORE UPDATE ON setup_capture_counters
    WHEN NEW.entries_admitted<OLD.entries_admitted OR NEW.files_reserved<OLD.files_reserved
      OR NEW.bytes_reserved<OLD.bytes_reserved OR NEW.bytes_committed<OLD.bytes_committed
      OR NEW.lock_version!=OLD.lock_version+1
    BEGIN SELECT RAISE(ABORT,'capture allowance cannot reset'); END
    """)

    execute("""
    CREATE TRIGGER setup_authorization_revoke_once BEFORE UPDATE ON model_run_authorization_states
    WHEN OLD.revoked_at IS NOT NULL OR NEW.revoked_at IS NULL OR NEW.lock_version!=OLD.lock_version+1
    BEGIN SELECT RAISE(ABORT,'authorization withdrawal is terminal'); END
    """)
  end

  def down do
    populated =
      Enum.any?(@tables, fn table ->
        %{rows: [[count]]} = repo().query!("SELECT count(*) FROM #{table}")
        count != 0
      end)

    %{rows: [[v2]]} = repo().query!("SELECT count(*) FROM setup_sessions WHERE schema_version=2")

    if populated or v2 != 0,
      do: raise(Ecto.MigrationError, "cannot remove retained setup authority or usage")

    execute("DROP TRIGGER setup_stage_binding_insert")
    execute("DROP TRIGGER setup_stage_binding_update")
    execute("ALTER TABLE stage_operations DROP COLUMN operation_binding_digest")
    execute("ALTER TABLE stage_operations DROP COLUMN budget_id")
    execute("ALTER TABLE stage_operations DROP COLUMN authorization_id")
    Enum.each(Enum.reverse(@tables), fn table -> execute("DROP TABLE #{table}") end)
    execute("ALTER TABLE setup_sessions RENAME TO setup_sessions_v2")

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

    execute("INSERT INTO setup_sessions SELECT * FROM setup_sessions_v2")
    execute("DROP TABLE setup_sessions_v2")

    execute(
      "CREATE INDEX setup_sessions_owner_updated ON setup_sessions(workspace_id,owner,updated_at DESC,id DESC)"
    )
  end
end
