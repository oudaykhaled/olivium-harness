defmodule HarnessForge.Repo.Migrations.CorpusRuns do
  use Ecto.Migration

  def up do
    execute(~S"""
    CREATE UNIQUE INDEX source_connections_workspace_identity ON source_connections(workspace_id,id)
    """)

    execute(~S"""
    CREATE UNIQUE INDEX evidence_sources_workspace_identity ON evidence_sources(workspace_id,id)
    """)

    execute(~S"""
    CREATE UNIQUE INDEX workspace_goals_workspace_identity ON workspace_goals(workspace_id,id)
    """)

    execute(~S"""
    CREATE UNIQUE INDEX company_profiles_workspace_identity ON company_profiles(workspace_id,id)
    """)

    execute(~S"""
    CREATE UNIQUE INDEX company_projects_workspace_identity ON company_projects(workspace_id,id)
    """)

    execute(~S"""
    CREATE UNIQUE INDEX model_requests_workspace_identity ON model_requests(workspace_id,id)
    """)

    execute(~S"""
    CREATE UNIQUE INDEX evidence_revisions_workspace_source_identity ON evidence_revisions(workspace_id,source_id,id)
    """)

    execute(~S"""
    CREATE TABLE corpora (
     id TEXT PRIMARY KEY NOT NULL, workspace_id TEXT NOT NULL, name TEXT NOT NULL,
     semantic_generation INTEGER NOT NULL DEFAULT 0 CHECK(semantic_generation>=0),
     authorization_generation INTEGER NOT NULL DEFAULT 0 CHECK(authorization_generation>=0),
     state TEXT NOT NULL DEFAULT 'active' CHECK(state IN('active','denied','retired')),
     lock_version INTEGER NOT NULL DEFAULT 1 CHECK(lock_version>0),
     inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL,
     UNIQUE(workspace_id,id))
    """)

    execute(~S"""
    CREATE INDEX corpora_page ON corpora(workspace_id,state,id)
    """)

    execute(~S"""
    CREATE TABLE passage_sets (
     id TEXT PRIMARY KEY NOT NULL, workspace_id TEXT NOT NULL, source_id TEXT NOT NULL,
     revision_id TEXT NOT NULL, body_hash TEXT NOT NULL CHECK(length(body_hash)=64),
     body_bytes INTEGER NOT NULL CHECK(body_bytes BETWEEN 0 AND 1048576),
     chunker_version TEXT NOT NULL, parser_version TEXT NOT NULL,
     state TEXT NOT NULL CHECK(state IN('pending','indexing','ready','failed','denied')),
     passage_count INTEGER NOT NULL DEFAULT 0 CHECK(passage_count>=0),
     indexed_count INTEGER NOT NULL DEFAULT 0 CHECK(indexed_count>=0 AND indexed_count<=passage_count),
     manifest_digest TEXT, error_code TEXT, inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL,
     UNIQUE(workspace_id,revision_id,chunker_version,parser_version),
     UNIQUE(workspace_id,source_id,revision_id,id), UNIQUE(workspace_id,id),
     FOREIGN KEY(workspace_id,source_id,revision_id)
     REFERENCES evidence_revisions(workspace_id,source_id,id) ON DELETE RESTRICT)
    """)

    execute(~S"""
    CREATE TABLE corpus_members (
     workspace_id TEXT NOT NULL, corpus_id TEXT NOT NULL, source_id TEXT NOT NULL,
     revision_id TEXT NOT NULL, passage_set_id TEXT,
     status TEXT NOT NULL CHECK(status IN('active','removed','denied')),
     last_seen_run_id TEXT, inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL,
     PRIMARY KEY(corpus_id,source_id),
     FOREIGN KEY(workspace_id,corpus_id) REFERENCES corpora(workspace_id,id) ON DELETE RESTRICT,
     FOREIGN KEY(workspace_id,source_id,revision_id)
     REFERENCES evidence_revisions(workspace_id,source_id,id) ON DELETE RESTRICT,
     FOREIGN KEY(workspace_id,source_id,revision_id,passage_set_id)
     REFERENCES passage_sets(workspace_id,source_id,revision_id,id) ON DELETE RESTRICT,
     FOREIGN KEY(last_seen_run_id) REFERENCES capture_runs(id) ON DELETE RESTRICT)
    """)

    execute(~S"""
    CREATE INDEX members_page ON corpus_members(workspace_id,corpus_id,status,source_id)
    """)

    execute(~S"""
    CREATE INDEX members_reverse ON corpus_members(workspace_id,source_id,corpus_id)
    """)

    execute(~S"""
    CREATE TABLE capture_runs (
     id TEXT PRIMARY KEY NOT NULL, workspace_id TEXT NOT NULL, corpus_id TEXT NOT NULL,
     connection_id TEXT NOT NULL, idempotency_key TEXT NOT NULL,
     root_fingerprint TEXT NOT NULL CHECK(length(root_fingerprint)=64),
     state TEXT NOT NULL CHECK(state IN('queued','running','paused','cancelled','failed','scan_complete')),
     lock_version INTEGER NOT NULL DEFAULT 1 CHECK(lock_version>0),
     checkpoint_seq INTEGER NOT NULL DEFAULT 0 CHECK(checkpoint_seq>=0),
     scan_epoch INTEGER NOT NULL DEFAULT 1 CHECK(scan_epoch>0),
     scan_verified INTEGER NOT NULL DEFAULT 0 CHECK(scan_verified IN(0,1)),
     incomplete INTEGER NOT NULL DEFAULT 0 CHECK(incomplete IN(0,1)),
     counts TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(counts) AND length(CAST(counts AS BLOB))<=4096),
     reconcile_after TEXT, error_code TEXT, lease_token TEXT, lease_until TEXT,
     inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL,
     UNIQUE(workspace_id,id), UNIQUE(workspace_id,corpus_id,idempotency_key),
     FOREIGN KEY(workspace_id,corpus_id) REFERENCES corpora(workspace_id,id) ON DELETE RESTRICT,
     FOREIGN KEY(workspace_id,connection_id) REFERENCES source_connections(workspace_id,id) ON DELETE RESTRICT)
    """)

    execute(~S"""
    CREATE UNIQUE INDEX capture_one_active ON capture_runs(workspace_id)
     WHERE state IN('queued','running','paused')
    """)

    execute(~S"""
    CREATE INDEX capture_runs_page ON capture_runs(workspace_id,corpus_id,id)
    """)

    execute(~S"""
    CREATE TABLE capture_frontier (
     run_id TEXT NOT NULL, relative_path TEXT NOT NULL CHECK(length(CAST(relative_path AS BLOB))<=4096),
     state TEXT NOT NULL CHECK(state IN('pending','enumerating','done','changed','failed')),
     scan_epoch INTEGER NOT NULL, directory_fingerprint TEXT, entry_count INTEGER NOT NULL DEFAULT 0,
     PRIMARY KEY(run_id,relative_path),
     FOREIGN KEY(run_id) REFERENCES capture_runs(id) ON DELETE RESTRICT)
    """)

    execute(~S"""
    CREATE INDEX frontier_work ON capture_frontier(run_id,state,relative_path)
    """)

    execute(~S"""
    CREATE TABLE capture_items (
     run_id TEXT NOT NULL, relative_path TEXT NOT NULL CHECK(length(CAST(relative_path AS BLOB))<=4096),
     kind TEXT NOT NULL CHECK(kind IN('file','directory','other')),
     state TEXT NOT NULL CHECK(state IN('pending','captured','unchanged','excluded','failed','stale')),
     scan_epoch INTEGER NOT NULL, source_id TEXT, revision_id TEXT,
     body_hash TEXT, body_bytes INTEGER CHECK(body_bytes BETWEEN 0 AND 1048576),
     error_code TEXT, attempts INTEGER NOT NULL DEFAULT 0 CHECK(attempts>=0),
     updated_at TEXT NOT NULL, PRIMARY KEY(run_id,relative_path),
     FOREIGN KEY(run_id) REFERENCES capture_runs(id) ON DELETE RESTRICT,
     FOREIGN KEY(source_id) REFERENCES evidence_sources(id) ON DELETE RESTRICT,
     FOREIGN KEY(revision_id) REFERENCES evidence_revisions(id) ON DELETE RESTRICT)
    """)

    execute(~S"""
    CREATE INDEX capture_outcomes ON capture_items(run_id,state,relative_path)
    """)

    execute(~S"""
    CREATE TABLE passages (
     rowid INTEGER PRIMARY KEY, id TEXT NOT NULL UNIQUE, workspace_id TEXT NOT NULL,
     passage_set_id TEXT NOT NULL, ordinal INTEGER NOT NULL CHECK(ordinal>=0),
     start_byte INTEGER NOT NULL CHECK(start_byte>=0), end_byte INTEGER NOT NULL,
     snippet_hash TEXT NOT NULL CHECK(length(snippet_hash)=64),
     parent_start_byte INTEGER NOT NULL CHECK(parent_start_byte>=0), parent_end_byte INTEGER NOT NULL,
     parent_hash TEXT NOT NULL CHECK(length(parent_hash)=64),
     CHECK(end_byte>start_byte AND end_byte-start_byte<=4096),
     CHECK(parent_start_byte<=start_byte AND parent_end_byte>=end_byte
           AND parent_end_byte-parent_start_byte<=4096),
     UNIQUE(passage_set_id,ordinal), UNIQUE(passage_set_id,start_byte,end_byte),
     FOREIGN KEY(workspace_id,passage_set_id) REFERENCES passage_sets(workspace_id,id) ON DELETE RESTRICT)
    """)

    execute(~S"""
    CREATE INDEX passages_scope ON passages(workspace_id,passage_set_id,id)
    """)

    execute(~S"""
    CREATE VIRTUAL TABLE passage_search USING fts5(
     passage_id UNINDEXED, workspace_id UNINDEXED, title, body,
     tokenize='unicode61 remove_diacritics 2')
    """)

    execute(~S"""
    CREATE TABLE retrieval_runs (
     id TEXT PRIMARY KEY NOT NULL, workspace_id TEXT NOT NULL, corpus_id TEXT NOT NULL,
     project_id TEXT NOT NULL, goal_id TEXT NOT NULL, goal_hash TEXT NOT NULL CHECK(length(goal_hash)=64),
     semantic_generation INTEGER NOT NULL, authorization_generation INTEGER NOT NULL,
     mode TEXT NOT NULL CHECK(mode IN('fts','graphiti_hybrid')),
     state TEXT NOT NULL CHECK(state IN('preparing','ready','abstained','refresh_required','failed','cancelled')),
     envelope TEXT NOT NULL CHECK(json_valid(envelope) AND length(CAST(envelope AS BLOB))<=16384),
     coverage TEXT NOT NULL CHECK(json_valid(coverage) AND length(CAST(coverage AS BLOB))<=8192),
     digest TEXT, error_code TEXT, inserted_at TEXT NOT NULL, completed_at TEXT,
     UNIQUE(workspace_id,id),
     FOREIGN KEY(workspace_id,corpus_id) REFERENCES corpora(workspace_id,id) ON DELETE RESTRICT,
     FOREIGN KEY(workspace_id,project_id) REFERENCES company_projects(workspace_id,id) ON DELETE RESTRICT,
     FOREIGN KEY(workspace_id,goal_id) REFERENCES workspace_goals(workspace_id,id) ON DELETE RESTRICT)
    """)

    execute(~S"""
    CREATE INDEX retrieval_page ON retrieval_runs(workspace_id,corpus_id,id)
    """)

    execute(~S"""
    CREATE TABLE retrieval_items (
     run_id TEXT NOT NULL, passage_id TEXT NOT NULL, candidate_order INTEGER NOT NULL CHECK(candidate_order BETWEEN 0 AND 99),
     selected_order INTEGER CHECK(selected_order BETWEEN 0 AND 23),
     relation TEXT NOT NULL CHECK(relation IN('support','contrary','unknown')),
     lane TEXT NOT NULL CHECK(lane IN('support','contrary','chronology','obligations','followup')),
     reason_code TEXT NOT NULL, PRIMARY KEY(run_id,passage_id),
     UNIQUE(run_id,candidate_order), UNIQUE(run_id,selected_order),
     FOREIGN KEY(run_id) REFERENCES retrieval_runs(id) ON DELETE RESTRICT,
     FOREIGN KEY(passage_id) REFERENCES passages(id) ON DELETE RESTRICT)
    """)

    execute(~S"""
    CREATE TABLE company_corpus_bindings (
     workspace_id TEXT NOT NULL, project_id TEXT NOT NULL, profile_id TEXT NOT NULL, corpus_id TEXT NOT NULL,
     legacy_context_digest TEXT, inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL,
     PRIMARY KEY(workspace_id,project_id),
     FOREIGN KEY(workspace_id,project_id) REFERENCES company_projects(workspace_id,id) ON DELETE RESTRICT,
     FOREIGN KEY(workspace_id,profile_id) REFERENCES company_profiles(workspace_id,id) ON DELETE RESTRICT,
     FOREIGN KEY(workspace_id,corpus_id) REFERENCES corpora(workspace_id,id) ON DELETE RESTRICT)
    """)

    execute(~S"""
    CREATE UNIQUE INDEX corpus_legacy_adoption ON company_corpus_bindings(workspace_id,project_id,legacy_context_digest) WHERE legacy_context_digest IS NOT NULL
    """)

    execute(~S"""
    CREATE TABLE dependency_manifests (
     id TEXT PRIMARY KEY NOT NULL, workspace_id TEXT NOT NULL, corpus_id TEXT NOT NULL,
     semantic_generation INTEGER NOT NULL CHECK(semantic_generation>=0), authorization_generation INTEGER NOT NULL CHECK(authorization_generation>=0),
     purpose TEXT NOT NULL CHECK(purpose IN('capture','graph_ingest','retrieval','partition','derivative','purge_rebuild')),
     state TEXT NOT NULL CHECK(state IN('building','sealed','denied')), digest TEXT CHECK(digest IS NULL OR length(digest)=64),
     source_count INTEGER NOT NULL CHECK(source_count>=0), context_json TEXT NOT NULL CHECK(json_valid(context_json) AND length(CAST(context_json AS BLOB))<=16384),
     inserted_at TEXT NOT NULL, UNIQUE(workspace_id,id),
     FOREIGN KEY(workspace_id,corpus_id) REFERENCES corpora(workspace_id,id) ON DELETE RESTRICT)
    """)

    execute(~S"""
    CREATE INDEX dependency_manifest_scope ON dependency_manifests(workspace_id,corpus_id,state,id)
    """)

    execute(~S"""
    CREATE TABLE origin_dependencies (
     workspace_id TEXT NOT NULL, manifest_id TEXT NOT NULL, dependency_key TEXT NOT NULL,
     kind TEXT NOT NULL CHECK(kind IN('source_revision','goal','project','profile','stage','episode','summary','attribute','edge','rendered_message','embed_input','deterministic_output','manifest')),
     source_id TEXT, revision_id TEXT, content_hash TEXT NOT NULL CHECK(length(content_hash)=64),
     role TEXT NOT NULL CHECK(role IN('cited','uncited','transitive')),
     ordinal INTEGER NOT NULL CHECK(ordinal BETWEEN 0 AND 9007199254740991),
     episode_binding_id TEXT, derivative_version_id TEXT, parent_manifest_id TEXT,
     projection_id TEXT, projection_hash TEXT,
     PRIMARY KEY(manifest_id,dependency_key),
     CHECK((projection_id IS NULL AND projection_hash IS NULL) OR
      (projection_id IS NOT NULL AND projection_hash IS NOT NULL AND length(CAST(projection_id AS BLOB)) BETWEEN 1 AND 200 AND length(projection_hash)=64)),
     CHECK((kind='source_revision' AND source_id IS NOT NULL AND revision_id IS NOT NULL AND episode_binding_id IS NULL AND derivative_version_id IS NULL AND parent_manifest_id IS NULL AND projection_id IS NULL) OR
      (kind='episode' AND source_id IS NULL AND revision_id IS NULL AND episode_binding_id IS NOT NULL AND derivative_version_id IS NULL AND parent_manifest_id IS NULL) OR
      (kind IN('summary','attribute','edge','rendered_message','embed_input','deterministic_output') AND source_id IS NULL AND revision_id IS NULL AND episode_binding_id IS NULL AND derivative_version_id IS NOT NULL AND parent_manifest_id IS NULL) OR
      (kind='manifest' AND source_id IS NULL AND revision_id IS NULL AND episode_binding_id IS NULL AND derivative_version_id IS NULL AND parent_manifest_id IS NOT NULL AND projection_id IS NULL AND role='transitive') OR
      (kind IN('goal','project','profile','stage') AND source_id IS NULL AND revision_id IS NULL AND episode_binding_id IS NULL AND derivative_version_id IS NULL AND parent_manifest_id IS NULL AND projection_id IS NULL)),
     FOREIGN KEY(workspace_id,manifest_id) REFERENCES dependency_manifests(workspace_id,id) ON DELETE RESTRICT,
     FOREIGN KEY(workspace_id,source_id,revision_id) REFERENCES evidence_revisions(workspace_id,source_id,id) ON DELETE RESTRICT,
     FOREIGN KEY(workspace_id,episode_binding_id) REFERENCES graph_episode_bindings(workspace_id,id) ON DELETE RESTRICT,
     FOREIGN KEY(workspace_id,derivative_version_id) REFERENCES graph_derivative_versions(workspace_id,id) ON DELETE RESTRICT,
     FOREIGN KEY(workspace_id,parent_manifest_id) REFERENCES dependency_manifests(workspace_id,id) ON DELETE RESTRICT
    )
    """)

    execute(~S"""
    CREATE INDEX origin_dependency_reverse ON origin_dependencies(workspace_id,source_id,manifest_id)
    """)

    execute(~S"""
    CREATE INDEX origin_dependency_page ON origin_dependencies(manifest_id,ordinal)
    """)

    execute(~S"""
    CREATE TABLE stage_configs (
     id TEXT PRIMARY KEY NOT NULL, workspace_id TEXT NOT NULL, stage TEXT NOT NULL,
     payload_json TEXT NOT NULL CHECK(json_valid(payload_json) AND length(CAST(payload_json AS BLOB))<=16384),
     config_hash TEXT NOT NULL CHECK(length(config_hash)=64), inserted_at TEXT NOT NULL,
     UNIQUE(workspace_id,id), UNIQUE(workspace_id,stage,config_hash))
    """)

    execute(~S"""
    CREATE TABLE stage_consent_revisions (
     id TEXT PRIMARY KEY NOT NULL, workspace_id TEXT NOT NULL, stage_config_id TEXT NOT NULL,
     revision INTEGER NOT NULL CHECK(revision>0), state TEXT NOT NULL CHECK(state IN('active','revoked')),
     inserted_at TEXT NOT NULL, UNIQUE(workspace_id,id), UNIQUE(workspace_id,stage_config_id,revision),
     FOREIGN KEY(workspace_id,stage_config_id) REFERENCES stage_configs(workspace_id,id) ON DELETE RESTRICT)
    """)

    execute(~S"""
    CREATE TABLE stage_consent_sources (
     workspace_id TEXT NOT NULL, consent_id TEXT NOT NULL, source_id TEXT NOT NULL, revision_id TEXT NOT NULL,
     body_hash TEXT NOT NULL CHECK(length(body_hash)=64), category TEXT NOT NULL,
     PRIMARY KEY(consent_id,source_id,revision_id,category),
     FOREIGN KEY(workspace_id,consent_id) REFERENCES stage_consent_revisions(workspace_id,id) ON DELETE RESTRICT,
     FOREIGN KEY(workspace_id,source_id,revision_id) REFERENCES evidence_revisions(workspace_id,source_id,id) ON DELETE RESTRICT)
    """)

    execute(~S"""
    CREATE INDEX stage_consent_reverse ON stage_consent_sources(workspace_id,source_id,consent_id)
    """)

    execute(~S"""
    CREATE TABLE graph_consent_certificates (
     id TEXT PRIMARY KEY NOT NULL, workspace_id TEXT NOT NULL,
     source_manifest_id TEXT NOT NULL, source_manifest_digest TEXT NOT NULL CHECK(length(source_manifest_digest)=64),
     stage_config_id TEXT NOT NULL, stage_config_hash TEXT NOT NULL CHECK(length(stage_config_hash)=64),
     consent_id TEXT NOT NULL, consent_revision INTEGER NOT NULL CHECK(consent_revision>0),
     category_policy_hash TEXT NOT NULL CHECK(length(category_policy_hash)=64),
     semantic_generation INTEGER NOT NULL, authorization_generation INTEGER NOT NULL,
     source_count INTEGER NOT NULL CHECK(source_count>0), next_ordinal INTEGER NOT NULL DEFAULT 0,
     mode TEXT NOT NULL CHECK(mode IN('grant','verify')),
     state TEXT NOT NULL CHECK(state IN('checking','sealed','denied')), digest TEXT,
     inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL,
     CHECK(next_ordinal BETWEEN 0 AND source_count),
     CHECK((state='sealed' AND next_ordinal=source_count AND digest IS NOT NULL AND length(digest)=64) OR state!='sealed'),
     UNIQUE(workspace_id,id), UNIQUE(source_manifest_id,stage_config_id,consent_id,category_policy_hash),
     FOREIGN KEY(workspace_id,source_manifest_id) REFERENCES dependency_manifests(workspace_id,id) ON DELETE RESTRICT,
     FOREIGN KEY(workspace_id,stage_config_id) REFERENCES stage_configs(workspace_id,id) ON DELETE RESTRICT,
     FOREIGN KEY(workspace_id,consent_id) REFERENCES stage_consent_revisions(workspace_id,id) ON DELETE RESTRICT)
    """)

    execute(~S"""
    CREATE TRIGGER immutable_graph_consent_certificates_identity BEFORE UPDATE ON graph_consent_certificates
    WHEN NEW.id IS NOT OLD.id OR NEW.workspace_id IS NOT OLD.workspace_id OR
     NEW.source_manifest_id IS NOT OLD.source_manifest_id OR NEW.source_manifest_digest IS NOT OLD.source_manifest_digest OR
     NEW.stage_config_id IS NOT OLD.stage_config_id OR NEW.stage_config_hash IS NOT OLD.stage_config_hash OR
     NEW.consent_id IS NOT OLD.consent_id OR NEW.consent_revision IS NOT OLD.consent_revision OR
     NEW.category_policy_hash IS NOT OLD.category_policy_hash OR NEW.semantic_generation IS NOT OLD.semantic_generation OR
     NEW.authorization_generation IS NOT OLD.authorization_generation OR NEW.source_count IS NOT OLD.source_count OR
     NEW.mode IS NOT OLD.mode OR NEW.inserted_at IS NOT OLD.inserted_at OR
     (OLD.state IN('sealed','denied') AND (NEW.state!='denied' OR NEW.next_ordinal IS NOT OLD.next_ordinal OR NEW.digest IS NOT OLD.digest))
    BEGIN SELECT RAISE(ABORT,'immutable graph consent certificate'); END
    """)

    execute(~S"""
    CREATE TRIGGER immutable_graph_consent_certificates_delete BEFORE DELETE ON graph_consent_certificates
    BEGIN SELECT RAISE(ABORT,'immutable graph consent certificate'); END
    """)

    execute(~S"""
    CREATE TABLE graph_partition_controls (
     id TEXT PRIMARY KEY NOT NULL, workspace_id TEXT NOT NULL, corpus_id TEXT NOT NULL,
     group_id TEXT NOT NULL UNIQUE CHECK(length(group_id)>0), semantic_generation INTEGER NOT NULL CHECK(semantic_generation>=0),
     authorization_generation INTEGER NOT NULL CHECK(authorization_generation>=0), cancel_epoch INTEGER NOT NULL CHECK(cancel_epoch>=0),
     state TEXT NOT NULL CHECK(state IN('staging','ready','stale','denied','reconcile_required')),
     manifest_id TEXT, lock_version INTEGER NOT NULL CHECK(lock_version>0), inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL,
     source_lock_digest TEXT CHECK(source_lock_digest IS NULL OR length(source_lock_digest)=64),
     backend_pin_digest TEXT CHECK(backend_pin_digest IS NULL OR length(backend_pin_digest)=64),
     authority_json TEXT CHECK(authority_json IS NULL OR (json_valid(authority_json) AND length(CAST(authority_json AS BLOB))<=32768)),
     inventory_revision INTEGER NOT NULL DEFAULT 0 CHECK(inventory_revision>=0),
     inventory_manifest_id TEXT,
     inventory_manifest_digest TEXT CHECK(inventory_manifest_digest IS NULL OR (length(inventory_manifest_digest)=64 AND inventory_manifest_digest NOT GLOB '*[^0-9a-f]*')),
     CHECK((inventory_manifest_id IS NULL AND inventory_manifest_digest IS NULL) OR (inventory_manifest_id IS NOT NULL AND inventory_manifest_digest IS NOT NULL)),
     FOREIGN KEY(workspace_id,inventory_manifest_id) REFERENCES dependency_manifests(workspace_id,id) ON DELETE RESTRICT,
     UNIQUE(workspace_id,id), FOREIGN KEY(workspace_id,corpus_id) REFERENCES corpora(workspace_id,id) ON DELETE RESTRICT,
     FOREIGN KEY(workspace_id,manifest_id) REFERENCES dependency_manifests(workspace_id,id) ON DELETE RESTRICT)
    """)

    execute(~S"""
    CREATE INDEX graph_partition_scope ON graph_partition_controls(workspace_id,corpus_id,state,id)
    """)

    execute(~S"""
    CREATE TABLE graph_runtime_backends (
     workspace_id TEXT NOT NULL, partition_id TEXT PRIMARY KEY NOT NULL,
     instance_id TEXT NOT NULL UNIQUE, state TEXT NOT NULL CHECK(state IN('provisioning','verified','reconcile_required','stopped')),
     resource_json TEXT CHECK(resource_json IS NULL OR (json_valid(resource_json) AND length(CAST(resource_json AS BLOB))<=32768)),
     bundle_json TEXT CHECK(bundle_json IS NULL OR (json_valid(bundle_json) AND length(CAST(bundle_json AS BLOB))<=32768)),
     bundle_digest TEXT CHECK(bundle_digest IS NULL OR length(bundle_digest)=64),
     credentials_cipher TEXT CHECK(credentials_cipher IS NULL OR length(credentials_cipher)<=32768),
     qualification_ref TEXT, inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL,
     UNIQUE(workspace_id,partition_id),
     FOREIGN KEY(workspace_id,partition_id) REFERENCES graph_partition_controls(workspace_id,id) ON DELETE RESTRICT)
    """)

    execute(~S"""
    CREATE TABLE graph_worker_sessions (
     id TEXT PRIMARY KEY NOT NULL, workspace_id TEXT NOT NULL, partition_id TEXT NOT NULL,
     container_id TEXT NOT NULL UNIQUE, image_id TEXT NOT NULL, source_digest TEXT NOT NULL CHECK(length(source_digest)=64),
     boot_digest TEXT NOT NULL CHECK(length(boot_digest)=64), stage_set_digest TEXT NOT NULL CHECK(length(stage_set_digest)=64),
     profile_digest TEXT NOT NULL CHECK(length(profile_digest)=64), network_id TEXT NOT NULL,
     operation_id TEXT, lease_id TEXT, launch_token_hash TEXT CHECK(launch_token_hash IS NULL OR length(launch_token_hash)=64),
     state TEXT NOT NULL CHECK(state IN('launching','ready','bound','uncertain','stopped')),
     inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL, UNIQUE(workspace_id,id),
     CHECK((operation_id IS NULL AND lease_id IS NULL AND launch_token_hash IS NULL) OR
       (operation_id IS NOT NULL AND lease_id IS NOT NULL AND launch_token_hash IS NOT NULL)),
     FOREIGN KEY(workspace_id,partition_id) REFERENCES graph_runtime_backends(workspace_id,partition_id) ON DELETE RESTRICT,
     FOREIGN KEY(workspace_id,operation_id) REFERENCES stage_operations(workspace_id,id) ON DELETE RESTRICT)
    """)

    execute(~S"""
    CREATE UNIQUE INDEX graph_worker_one_live ON graph_worker_sessions(workspace_id,partition_id)
    WHERE state IN('launching','ready','bound')
    """)

    execute(~S"""
    CREATE TABLE graph_source_scans (
     workspace_id TEXT NOT NULL, partition_id TEXT PRIMARY KEY NOT NULL,
     last_source_id TEXT NOT NULL DEFAULT '', source_count INTEGER NOT NULL DEFAULT 0 CHECK(source_count>=0),
     chain_hash TEXT NOT NULL CHECK(length(chain_hash)=64),
     state TEXT NOT NULL CHECK(state IN('scanning','complete','denied')),
     inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL,
     FOREIGN KEY(workspace_id,partition_id) REFERENCES graph_partition_controls(workspace_id,id) ON DELETE RESTRICT)
    """)

    execute(~S"""
    CREATE TABLE graph_episode_bindings (
     id TEXT PRIMARY KEY NOT NULL, workspace_id TEXT NOT NULL, partition_id TEXT NOT NULL, revision_id TEXT NOT NULL,
     passage_id TEXT NOT NULL, chunker_version TEXT NOT NULL, episode_uuid TEXT NOT NULL, payload_hash TEXT NOT NULL CHECK(length(payload_hash)=64),
     state TEXT NOT NULL CHECK(state IN('staging','indexing','ready','uncertain','stale','denied','removed')),
     publication_generation INTEGER, manifest_id TEXT, inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL,
     UNIQUE(workspace_id,id), UNIQUE(partition_id,revision_id,chunker_version,passage_id), UNIQUE(partition_id,episode_uuid),
     FOREIGN KEY(workspace_id,partition_id) REFERENCES graph_partition_controls(workspace_id,id) ON DELETE RESTRICT,
     FOREIGN KEY(revision_id) REFERENCES evidence_revisions(id) ON DELETE RESTRICT,
     FOREIGN KEY(passage_id) REFERENCES passages(id) ON DELETE RESTRICT,
     FOREIGN KEY(workspace_id,manifest_id) REFERENCES dependency_manifests(workspace_id,id) ON DELETE RESTRICT)
    """)

    execute(~S"""
    CREATE TABLE graph_derivative_versions (
     id TEXT PRIMARY KEY NOT NULL, workspace_id TEXT NOT NULL, partition_id TEXT NOT NULL,
     object_kind TEXT NOT NULL CHECK(object_kind IN('summary','attribute','edge','rendered_message','embed_input','deterministic_output')), object_id TEXT NOT NULL,
     version INTEGER NOT NULL CHECK(version>0), value_hash TEXT NOT NULL CHECK(length(value_hash)=64),
     value_json TEXT CHECK(value_json IS NULL OR (json_valid(value_json) AND length(CAST(value_json AS BLOB))<=98304)), manifest_id TEXT NOT NULL,
     predecessor_id TEXT, state TEXT NOT NULL CHECK(state IN('staging','published','denied')), inserted_at TEXT NOT NULL,
     UNIQUE(workspace_id,id), UNIQUE(partition_id,object_kind,object_id,version),
     FOREIGN KEY(workspace_id,partition_id) REFERENCES graph_partition_controls(workspace_id,id) ON DELETE RESTRICT,
     FOREIGN KEY(workspace_id,manifest_id) REFERENCES dependency_manifests(workspace_id,id) ON DELETE RESTRICT,
     FOREIGN KEY(workspace_id,predecessor_id) REFERENCES graph_derivative_versions(workspace_id,id) ON DELETE RESTRICT)
    """)

    execute(~S"""
    CREATE INDEX graph_derivative_page ON graph_derivative_versions(partition_id,object_kind,object_id,version)
    """)

    execute(~S"""
    CREATE TABLE stage_operations (
     workspace_id TEXT NOT NULL, id TEXT NOT NULL, corpus_id TEXT NOT NULL,
     scope_ref TEXT NOT NULL CHECK(length(scope_ref)>0), manifest_id TEXT,
     manifest_digest TEXT CHECK(manifest_digest IS NULL OR length(manifest_digest)=64),
     stage_set_digest TEXT NOT NULL CHECK(length(stage_set_digest)=64),
     caller_digest TEXT NOT NULL CHECK(length(caller_digest)=64),
     control_token TEXT NOT NULL CHECK(length(control_token)=64),
     operation_type TEXT NOT NULL CHECK(operation_type IN('synthesis','ingest','search','remove')),
     partition_id TEXT, lease_id TEXT, worker_session_id TEXT, partition_lock_version INTEGER,
     source_lock_digest TEXT, backend_pin_digest TEXT,
     semantic_generation INTEGER NOT NULL CHECK(semantic_generation>=0),
     authorization_generation INTEGER NOT NULL CHECK(authorization_generation>=0),
     cancel_epoch INTEGER NOT NULL CHECK(cancel_epoch>=0),
     state TEXT NOT NULL CHECK(state IN('active','completed','cancelled','uncertain')),
     deadline_at TEXT NOT NULL, result_digest TEXT, inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL,
     CHECK((manifest_id IS NULL AND manifest_digest IS NULL) OR (manifest_id IS NOT NULL AND manifest_digest IS NOT NULL)),
     CHECK((operation_type='synthesis' AND manifest_id IS NOT NULL AND partition_id IS NULL AND lease_id IS NULL AND worker_session_id IS NULL)
       OR (operation_type!='synthesis' AND partition_id IS NOT NULL AND lease_id IS NOT NULL AND worker_session_id IS NOT NULL
           AND partition_lock_version IS NOT NULL AND partition_lock_version>0
           AND source_lock_digest IS NOT NULL AND backend_pin_digest IS NOT NULL
           AND length(source_lock_digest)=64 AND length(backend_pin_digest)=64)),
     PRIMARY KEY(workspace_id,id),
     FOREIGN KEY(workspace_id,corpus_id) REFERENCES corpora(workspace_id,id) ON DELETE RESTRICT,
     FOREIGN KEY(workspace_id,partition_id) REFERENCES graph_partition_controls(workspace_id,id) ON DELETE RESTRICT,
     FOREIGN KEY(workspace_id,manifest_id) REFERENCES dependency_manifests(workspace_id,id) ON DELETE RESTRICT)
    """)

    execute(~S"""
    CREATE UNIQUE INDEX graph_operation_one_writer ON stage_operations(workspace_id,partition_id)
    WHERE partition_id IS NOT NULL AND state='active'
    """)

    execute(~S"""
    CREATE TABLE stage_attempts (
     id TEXT PRIMARY KEY NOT NULL, workspace_id TEXT NOT NULL, operation_id TEXT NOT NULL, logical_call_id TEXT NOT NULL,
     ordinal INTEGER NOT NULL CHECK(ordinal BETWEEN 1 AND 3), predecessor_attempt_id TEXT,
     stage_config_id TEXT NOT NULL, consent_id TEXT NOT NULL, model_request_id TEXT, worker_request_id TEXT NOT NULL,
     payload_hash TEXT NOT NULL CHECK(length(payload_hash)=64), manifest_id TEXT NOT NULL,
     semantic_generation INTEGER NOT NULL CHECK(semantic_generation>=0), authorization_generation INTEGER NOT NULL CHECK(authorization_generation>=0),
     cancel_epoch INTEGER NOT NULL CHECK(cancel_epoch>=0), grant_hash TEXT, deadline_at TEXT NOT NULL,
     state TEXT NOT NULL CHECK(state IN('reserved','dispatched','completed','denied','cancelled','uncertain','stale','invalid')),
     result_hash TEXT, response_status INTEGER CHECK(response_status IS NULL OR response_status BETWEEN 100 AND 599),
     response_bytes INTEGER CHECK(response_bytes IS NULL OR response_bytes BETWEEN 0 AND 98304),
     error_code TEXT, inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL,
     UNIQUE(workspace_id,id), UNIQUE(workspace_id,operation_id,logical_call_id,ordinal), UNIQUE(model_request_id),
     FOREIGN KEY(workspace_id,operation_id) REFERENCES stage_operations(workspace_id,id) ON DELETE RESTRICT,
     FOREIGN KEY(workspace_id,predecessor_attempt_id) REFERENCES stage_attempts(workspace_id,id) ON DELETE RESTRICT,
     FOREIGN KEY(workspace_id,stage_config_id) REFERENCES stage_configs(workspace_id,id) ON DELETE RESTRICT,
     FOREIGN KEY(workspace_id,consent_id) REFERENCES stage_consent_revisions(workspace_id,id) ON DELETE RESTRICT,
     FOREIGN KEY(workspace_id,model_request_id) REFERENCES model_requests(workspace_id,id) ON DELETE RESTRICT,
     FOREIGN KEY(workspace_id,manifest_id) REFERENCES dependency_manifests(workspace_id,id) ON DELETE RESTRICT)
    """)

    execute(~S"""
    CREATE INDEX stage_attempt_scope ON stage_attempts(workspace_id,operation_id,state,id)
    """)

    execute(~S"""
    CREATE TABLE graph_observation_calls (
     workspace_id TEXT NOT NULL, operation_id TEXT NOT NULL, logical_call_id TEXT NOT NULL,
     stage_config_id TEXT NOT NULL, config_digest TEXT NOT NULL CHECK(length(config_digest)=64),
     schema_digest TEXT NOT NULL CHECK(length(schema_digest)=64), prompt_name TEXT NOT NULL CHECK(length(prompt_name) BETWEEN 1 AND 200),
     call_version INTEGER NOT NULL CHECK(call_version>0), state TEXT NOT NULL CHECK(state IN('active','finished','denied')),
     state_json TEXT NOT NULL CHECK(json_valid(state_json) AND length(CAST(state_json AS BLOB))<=16384),
     inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL,
     PRIMARY KEY(workspace_id,operation_id,logical_call_id),
     FOREIGN KEY(workspace_id,operation_id) REFERENCES stage_operations(workspace_id,id) ON DELETE RESTRICT,
     FOREIGN KEY(workspace_id,stage_config_id) REFERENCES stage_configs(workspace_id,id) ON DELETE RESTRICT)
    """)

    execute(~S"""
    CREATE TABLE graph_observation_events (
     workspace_id TEXT NOT NULL, operation_id TEXT NOT NULL, context_id TEXT NOT NULL,
     logical_call_id TEXT NOT NULL, phase TEXT NOT NULL CHECK(phase IN('inputs','derived','attempt_bind')),
     wire_digest TEXT NOT NULL CHECK(length(wire_digest)=64), manifest_id TEXT NOT NULL,
     ack_json TEXT NOT NULL CHECK(json_valid(ack_json) AND length(CAST(ack_json AS BLOB))<=32768),
     binding_state TEXT NOT NULL CHECK(binding_state IN('none','unused','consumed','denied')),
     consumed_attempt_id TEXT, inserted_at TEXT NOT NULL,
     PRIMARY KEY(workspace_id,operation_id,context_id), UNIQUE(workspace_id,manifest_id), UNIQUE(workspace_id,consumed_attempt_id),
     CHECK((phase='attempt_bind' AND binding_state IN('unused','consumed','denied')) OR (phase!='attempt_bind' AND binding_state='none')),
     CHECK((binding_state='consumed' AND consumed_attempt_id IS NOT NULL) OR (binding_state!='consumed' AND consumed_attempt_id IS NULL)),
     FOREIGN KEY(workspace_id,operation_id,logical_call_id) REFERENCES graph_observation_calls(workspace_id,operation_id,logical_call_id) ON DELETE RESTRICT,
     FOREIGN KEY(workspace_id,manifest_id) REFERENCES dependency_manifests(workspace_id,id) ON DELETE RESTRICT,
     FOREIGN KEY(workspace_id,consumed_attempt_id) REFERENCES stage_attempts(workspace_id,id) ON DELETE RESTRICT)
    """)

    execute(~S"""
    CREATE INDEX graph_observation_binding ON graph_observation_events(workspace_id,operation_id,manifest_id,binding_state)
    """)

    execute(~S"""
    CREATE TRIGGER graph_observation_call_transition BEFORE UPDATE ON graph_observation_calls
    WHEN OLD.state!='active' OR NEW.call_version!=OLD.call_version+1 OR
     NEW.workspace_id IS NOT OLD.workspace_id OR NEW.operation_id IS NOT OLD.operation_id OR
     NEW.logical_call_id IS NOT OLD.logical_call_id OR NEW.stage_config_id IS NOT OLD.stage_config_id OR
     NEW.config_digest IS NOT OLD.config_digest OR NEW.schema_digest IS NOT OLD.schema_digest OR
     NEW.prompt_name IS NOT OLD.prompt_name OR NEW.inserted_at IS NOT OLD.inserted_at
    BEGIN SELECT RAISE(ABORT,'invalid graph observation call transition'); END
    """)

    execute(~S"""
    CREATE TRIGGER immutable_graph_observation_event_update BEFORE UPDATE ON graph_observation_events
    WHEN NEW.workspace_id IS NOT OLD.workspace_id OR NEW.operation_id IS NOT OLD.operation_id OR
     NEW.context_id IS NOT OLD.context_id OR NEW.logical_call_id IS NOT OLD.logical_call_id OR NEW.phase IS NOT OLD.phase OR
     NEW.wire_digest IS NOT OLD.wire_digest OR NEW.manifest_id IS NOT OLD.manifest_id OR NEW.ack_json IS NOT OLD.ack_json OR
     NEW.inserted_at IS NOT OLD.inserted_at OR OLD.binding_state!='unused' OR NEW.binding_state NOT IN('consumed','denied')
    BEGIN SELECT RAISE(ABORT,'immutable graph observation event'); END
    """)

    execute(~S"""
    CREATE TRIGGER immutable_graph_observation_event_delete BEFORE DELETE ON graph_observation_events
    BEGIN SELECT RAISE(ABORT,'immutable corpus record'); END
    """)

    execute(~S"""
    CREATE TRIGGER immutable_graph_observation_call_delete BEFORE DELETE ON graph_observation_calls
    BEGIN SELECT RAISE(ABORT,'immutable corpus record'); END
    """)

    execute(~S"""
    CREATE TRIGGER immutable_passage_sets_update BEFORE UPDATE ON passage_sets WHEN OLD.state = 'ready' AND (NEW.id IS NOT OLD.id OR NEW.workspace_id IS NOT OLD.workspace_id OR NEW.source_id IS NOT OLD.source_id OR NEW.revision_id IS NOT OLD.revision_id OR NEW.body_hash IS NOT OLD.body_hash OR NEW.body_bytes IS NOT OLD.body_bytes OR NEW.chunker_version IS NOT OLD.chunker_version OR NEW.parser_version IS NOT OLD.parser_version OR NEW.passage_count IS NOT OLD.passage_count OR NEW.indexed_count IS NOT OLD.indexed_count OR NEW.manifest_digest IS NOT OLD.manifest_digest OR NEW.state NOT IN ('ready','denied')) BEGIN SELECT RAISE(ABORT, 'immutable corpus record'); END
    """)

    execute(~S"""
    CREATE TRIGGER immutable_passage_sets_delete BEFORE DELETE ON passage_sets BEGIN SELECT RAISE(ABORT, 'immutable corpus record'); END
    """)

    execute(~S"""
    CREATE TRIGGER immutable_passages_update BEFORE UPDATE ON passages WHEN EXISTS(SELECT 1 FROM passage_sets WHERE id=OLD.passage_set_id AND state IN('ready','denied')) BEGIN SELECT RAISE(ABORT, 'immutable corpus record'); END
    """)

    execute(~S"""
    CREATE TRIGGER immutable_passages_delete BEFORE DELETE ON passages BEGIN SELECT RAISE(ABORT, 'immutable corpus record'); END
    """)

    execute(~S"""
    CREATE TRIGGER immutable_retrieval_runs_update BEFORE UPDATE ON retrieval_runs WHEN OLD.digest IS NOT NULL BEGIN SELECT RAISE(ABORT, 'immutable corpus record'); END
    """)

    execute(~S"""
    CREATE TRIGGER immutable_retrieval_runs_delete BEFORE DELETE ON retrieval_runs BEGIN SELECT RAISE(ABORT, 'immutable corpus record'); END
    """)

    execute(~S"""
    CREATE TRIGGER immutable_retrieval_items_update BEFORE UPDATE ON retrieval_items WHEN EXISTS(SELECT 1 FROM retrieval_runs WHERE id=OLD.run_id AND digest IS NOT NULL) BEGIN SELECT RAISE(ABORT, 'immutable corpus record'); END
    """)

    execute(~S"""
    CREATE TRIGGER immutable_retrieval_items_delete BEFORE DELETE ON retrieval_items BEGIN SELECT RAISE(ABORT, 'immutable corpus record'); END
    """)

    execute(~S"""
    CREATE TRIGGER immutable_dependency_manifests_update BEFORE UPDATE ON dependency_manifests WHEN OLD.state IN('sealed','denied') AND (NEW.id IS NOT OLD.id OR NEW.workspace_id IS NOT OLD.workspace_id OR NEW.corpus_id IS NOT OLD.corpus_id OR NEW.semantic_generation IS NOT OLD.semantic_generation OR NEW.authorization_generation IS NOT OLD.authorization_generation OR NEW.purpose IS NOT OLD.purpose OR NEW.digest IS NOT OLD.digest OR NEW.source_count IS NOT OLD.source_count OR NEW.context_json IS NOT OLD.context_json OR NEW.state NOT IN ('sealed','denied')) BEGIN SELECT RAISE(ABORT, 'immutable corpus record'); END
    """)

    execute(~S"""
    CREATE TRIGGER immutable_dependency_manifests_delete BEFORE DELETE ON dependency_manifests BEGIN SELECT RAISE(ABORT, 'immutable corpus record'); END
    """)

    execute(~S"""
    CREATE TRIGGER immutable_origin_dependencies_update BEFORE UPDATE ON origin_dependencies WHEN EXISTS(SELECT 1 FROM dependency_manifests WHERE id=OLD.manifest_id AND state IN('sealed','denied')) BEGIN SELECT RAISE(ABORT, 'immutable corpus record'); END
    """)

    execute(~S"""
    CREATE TRIGGER immutable_origin_dependencies_delete BEFORE DELETE ON origin_dependencies BEGIN SELECT RAISE(ABORT, 'immutable corpus record'); END
    """)

    execute(~S"""
    CREATE TRIGGER immutable_stage_configs_update BEFORE UPDATE ON stage_configs WHEN 1 BEGIN SELECT RAISE(ABORT, 'immutable corpus record'); END
    """)

    execute(~S"""
    CREATE TRIGGER immutable_stage_configs_delete BEFORE DELETE ON stage_configs BEGIN SELECT RAISE(ABORT, 'immutable corpus record'); END
    """)

    execute(~S"""
    CREATE TRIGGER immutable_stage_consent_sources_update BEFORE UPDATE ON stage_consent_sources WHEN 1 BEGIN SELECT RAISE(ABORT, 'immutable corpus record'); END
    """)

    execute(~S"""
    CREATE TRIGGER immutable_stage_consent_sources_delete BEFORE DELETE ON stage_consent_sources BEGIN SELECT RAISE(ABORT, 'immutable corpus record'); END
    """)

    execute(~S"""
    CREATE TRIGGER immutable_graph_derivative_versions_update BEFORE UPDATE ON graph_derivative_versions
    WHEN NEW.id IS NOT OLD.id OR NEW.workspace_id IS NOT OLD.workspace_id OR NEW.partition_id IS NOT OLD.partition_id OR
     NEW.object_kind IS NOT OLD.object_kind OR NEW.object_id IS NOT OLD.object_id OR NEW.version IS NOT OLD.version OR
     NEW.value_hash IS NOT OLD.value_hash OR NEW.value_json IS NOT OLD.value_json OR NEW.manifest_id IS NOT OLD.manifest_id OR NEW.predecessor_id IS NOT OLD.predecessor_id OR
     NEW.inserted_at IS NOT OLD.inserted_at OR (OLD.state='published' AND NEW.state NOT IN('published','denied')) OR
     (OLD.state='denied' AND NEW.state!='denied')
    BEGIN SELECT RAISE(ABORT,'immutable graph version'); END
    """)

    execute(~S"""
    CREATE TRIGGER immutable_graph_derivative_versions_delete BEFORE DELETE ON graph_derivative_versions BEGIN SELECT RAISE(ABORT, 'immutable corpus record'); END
    """)

    execute(~S"""
    CREATE TRIGGER sealed_passages_insert BEFORE INSERT ON passages WHEN EXISTS(SELECT 1 FROM passage_sets WHERE id=NEW.passage_set_id AND state IN('ready','denied')) BEGIN SELECT RAISE(ABORT, 'sealed corpus record'); END
    """)

    execute(~S"""
    CREATE TRIGGER sealed_retrieval_items_insert BEFORE INSERT ON retrieval_items WHEN EXISTS(SELECT 1 FROM retrieval_runs WHERE id=NEW.run_id AND digest IS NOT NULL) BEGIN SELECT RAISE(ABORT, 'sealed corpus record'); END
    """)

    execute(~S"""
    CREATE TRIGGER sealed_origin_dependencies_insert BEFORE INSERT ON origin_dependencies WHEN EXISTS(SELECT 1 FROM dependency_manifests WHERE id=NEW.manifest_id AND state IN('sealed','denied')) BEGIN SELECT RAISE(ABORT, 'sealed corpus record'); END
    """)

    execute(~S"""
    CREATE TABLE graph_manifest_builds (
     workspace_id TEXT NOT NULL, manifest_id TEXT PRIMARY KEY NOT NULL,
     format TEXT NOT NULL CHECK(format='graph-manifest-v2'), partition_id TEXT NOT NULL,
     builder_operation_id TEXT NOT NULL,
     graph_kind TEXT NOT NULL CHECK(graph_kind IN('operation','inputs','derived','attempt_bind')),
     context_id TEXT, source_manifest_id TEXT, source_manifest_digest TEXT,
     source_scope_json TEXT NOT NULL CHECK(json_valid(source_scope_json) AND length(CAST(source_scope_json AS BLOB))<=4096),
     source_scope_hash TEXT NOT NULL CHECK(length(source_scope_hash)=64),
     control_hash TEXT CHECK(control_hash IS NULL OR length(control_hash)=64),
     header_json TEXT NOT NULL CHECK(json_valid(header_json) AND length(CAST(header_json AS BLOB))<=32768),
     header_hash TEXT NOT NULL CHECK(length(header_hash)=64),
     row_chain_hash TEXT NOT NULL CHECK(length(row_chain_hash)=64),
     source_chain_hash TEXT CHECK(source_chain_hash IS NULL OR length(source_chain_hash)=64),
     last_source_id TEXT NOT NULL DEFAULT '',
     dependency_count INTEGER NOT NULL DEFAULT 0 CHECK(dependency_count BETWEEN 0 AND 9007199254740991),
     source_count INTEGER NOT NULL DEFAULT 0 CHECK(source_count BETWEEN 0 AND dependency_count),
     effective_source_count INTEGER NOT NULL CHECK(effective_source_count BETWEEN 0 AND 9007199254740991),
     next_page_index INTEGER NOT NULL DEFAULT 0 CHECK(next_page_index BETWEEN 0 AND 9007199254740991),
     final_received INTEGER NOT NULL DEFAULT 0 CHECK(final_received IN(0,1)),
     expected_dependency_count INTEGER CHECK(expected_dependency_count BETWEEN 0 AND 9007199254740991),
     expected_source_count INTEGER CHECK(expected_source_count BETWEEN 0 AND 9007199254740991),
     candidate_digest TEXT CHECK(candidate_digest IS NULL OR length(candidate_digest)=64),
     phase TEXT NOT NULL CHECK(phase IN('receiving','validating','sealed','denied')),
     validated_page_index INTEGER NOT NULL DEFAULT 0 CHECK(validated_page_index BETWEEN 0 AND 9007199254740991),
     validated_page_digest TEXT CHECK(validated_page_digest IS NULL OR length(validated_page_digest)=64),
     validated_count INTEGER NOT NULL DEFAULT 0 CHECK(validated_count BETWEEN 0 AND dependency_count),
     validation_row_chain_hash TEXT NOT NULL CHECK(length(validation_row_chain_hash)=64),
     validation_source_chain_hash TEXT CHECK(validation_source_chain_hash IS NULL OR length(validation_source_chain_hash)=64),
     validation_last_source_id TEXT NOT NULL DEFAULT '',
     validated_at TEXT, error_code TEXT, inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL,
     UNIQUE(workspace_id,manifest_id),
     CHECK((graph_kind='operation' AND context_id IS NULL AND source_manifest_id IS NULL AND source_manifest_digest IS NULL AND control_hash IS NULL AND source_chain_hash IS NOT NULL AND validation_source_chain_hash IS NOT NULL) OR
      (graph_kind!='operation' AND context_id IS NOT NULL AND source_manifest_id IS NOT NULL AND source_manifest_digest IS NOT NULL AND length(source_manifest_digest)=64 AND control_hash IS NOT NULL AND source_chain_hash IS NULL AND validation_source_chain_hash IS NULL)),
     CHECK((expected_dependency_count IS NULL AND expected_source_count IS NULL) OR
      (expected_dependency_count IS NOT NULL AND expected_source_count IS NOT NULL AND expected_source_count<=expected_dependency_count)),
     CHECK(phase NOT IN('validating','sealed') OR (final_received=1 AND expected_dependency_count IS NOT NULL AND expected_source_count IS NOT NULL AND expected_dependency_count=dependency_count AND expected_source_count=source_count AND candidate_digest IS NOT NULL)),
     CHECK(phase!='sealed' OR (validated_at IS NOT NULL AND validated_count=dependency_count AND validated_page_index=next_page_index AND effective_source_count>0)),
     CHECK(graph_kind!='operation' OR phase!='sealed' OR (dependency_count=source_count AND source_count=effective_source_count)),
     FOREIGN KEY(workspace_id,manifest_id) REFERENCES dependency_manifests(workspace_id,id) ON DELETE RESTRICT,
     FOREIGN KEY(workspace_id,partition_id) REFERENCES graph_partition_controls(workspace_id,id) ON DELETE RESTRICT,
     FOREIGN KEY(workspace_id,source_manifest_id) REFERENCES dependency_manifests(workspace_id,id) ON DELETE RESTRICT
    )
    """)

    execute(~S"""
    CREATE TABLE graph_manifest_pages (
     workspace_id TEXT NOT NULL, manifest_id TEXT NOT NULL,
     page_index INTEGER NOT NULL CHECK(page_index BETWEEN 0 AND 9007199254740991),
     first_ordinal INTEGER NOT NULL CHECK(first_ordinal BETWEEN 0 AND 9007199254740991),
     row_count INTEGER NOT NULL CHECK(row_count BETWEEN 0 AND 100),
     previous_page_digest TEXT CHECK(previous_page_digest IS NULL OR length(previous_page_digest)=64),
     page_digest TEXT NOT NULL CHECK(length(page_digest)=64),
     row_chain_hash TEXT NOT NULL CHECK(length(row_chain_hash)=64),
     final INTEGER NOT NULL CHECK(final IN(0,1)),
     ack_json TEXT NOT NULL CHECK(json_valid(ack_json) AND length(CAST(ack_json AS BLOB))<=4096),
     inserted_at TEXT NOT NULL,
     PRIMARY KEY(manifest_id,page_index), UNIQUE(manifest_id,first_ordinal),
     CHECK((page_index=0 AND previous_page_digest IS NULL) OR (page_index>0 AND previous_page_digest IS NOT NULL)),
     CHECK(row_count>0 OR final=1),
     FOREIGN KEY(workspace_id,manifest_id) REFERENCES graph_manifest_builds(workspace_id,manifest_id) ON DELETE RESTRICT
    )
    """)

    execute(~S"""
    CREATE INDEX origin_dependency_parent ON origin_dependencies(workspace_id,parent_manifest_id,manifest_id) WHERE parent_manifest_id IS NOT NULL
    """)

    execute(~S"""
    CREATE UNIQUE INDEX graph_source_certificate_identity ON graph_manifest_builds(workspace_id,partition_id,source_scope_hash) WHERE graph_kind='operation'
    """)

    execute(~S"""
    CREATE UNIQUE INDEX graph_manifest_context_identity ON graph_manifest_builds(workspace_id,builder_operation_id,graph_kind,context_id) WHERE graph_kind!='operation'
    """)

    execute(~S"""
    CREATE INDEX graph_manifest_build_resume ON graph_manifest_builds(workspace_id,phase,manifest_id)
    """)

    execute(~S"""
    CREATE INDEX graph_manifest_build_partition ON graph_manifest_builds(workspace_id,partition_id,phase,manifest_id)
    """)

    execute(~S"""
    CREATE INDEX graph_manifest_source_authority ON graph_manifest_builds(workspace_id,source_manifest_id,manifest_id)
    """)

    execute(~S"""
    CREATE TRIGGER immutable_graph_manifest_header BEFORE UPDATE ON dependency_manifests
    WHEN EXISTS(SELECT 1 FROM graph_manifest_builds b WHERE b.workspace_id=OLD.workspace_id AND b.manifest_id=OLD.id) AND
     (NEW.id IS NOT OLD.id OR NEW.workspace_id IS NOT OLD.workspace_id OR NEW.corpus_id IS NOT OLD.corpus_id OR
      NEW.semantic_generation IS NOT OLD.semantic_generation OR NEW.authorization_generation IS NOT OLD.authorization_generation OR
      NEW.purpose IS NOT OLD.purpose OR NEW.context_json IS NOT OLD.context_json OR NEW.inserted_at IS NOT OLD.inserted_at)
    BEGIN SELECT RAISE(ABORT,'immutable graph manifest header'); END
    """)

    execute(~S"""
    CREATE TRIGGER immutable_graph_dependencies_update BEFORE UPDATE ON origin_dependencies
    WHEN EXISTS(SELECT 1 FROM graph_manifest_builds b WHERE b.workspace_id=OLD.workspace_id AND b.manifest_id=OLD.manifest_id)
    BEGIN SELECT RAISE(ABORT,'immutable graph dependency'); END
    """)

    execute(~S"""
    CREATE TRIGGER immutable_graph_manifest_build_identity BEFORE UPDATE ON graph_manifest_builds
    WHEN NEW.workspace_id IS NOT OLD.workspace_id OR NEW.manifest_id IS NOT OLD.manifest_id OR NEW.format IS NOT OLD.format OR
     NEW.partition_id IS NOT OLD.partition_id OR NEW.builder_operation_id IS NOT OLD.builder_operation_id OR
     NEW.graph_kind IS NOT OLD.graph_kind OR NEW.context_id IS NOT OLD.context_id OR
     NEW.source_manifest_id IS NOT OLD.source_manifest_id OR NEW.source_manifest_digest IS NOT OLD.source_manifest_digest OR
     NEW.source_scope_json IS NOT OLD.source_scope_json OR NEW.source_scope_hash IS NOT OLD.source_scope_hash OR
     NEW.control_hash IS NOT OLD.control_hash OR NEW.header_json IS NOT OLD.header_json OR NEW.header_hash IS NOT OLD.header_hash OR
     NEW.inserted_at IS NOT OLD.inserted_at OR (OLD.graph_kind!='operation' AND NEW.effective_source_count IS NOT OLD.effective_source_count)
    BEGIN SELECT RAISE(ABORT,'immutable graph manifest identity'); END
    """)

    execute(~S"""
    CREATE TRIGGER immutable_graph_manifest_builds_update BEFORE UPDATE ON graph_manifest_builds
    WHEN OLD.phase IN('sealed','denied')
    BEGIN SELECT RAISE(ABORT,'immutable graph certificate'); END
    """)

    execute(~S"""
    CREATE TRIGGER immutable_graph_manifest_builds_delete BEFORE DELETE ON graph_manifest_builds
    BEGIN SELECT RAISE(ABORT,'immutable graph certificate'); END
    """)

    execute(~S"""
    CREATE TRIGGER graph_manifest_local_source_guard BEFORE INSERT ON graph_manifest_builds
    WHEN NEW.graph_kind!='operation' AND NOT EXISTS(
     SELECT 1 FROM dependency_manifests m JOIN graph_manifest_builds b ON b.workspace_id=m.workspace_id AND b.manifest_id=m.id
     WHERE m.workspace_id=NEW.workspace_id AND m.id=NEW.source_manifest_id AND m.digest=NEW.source_manifest_digest
     AND m.state='sealed' AND b.phase='sealed' AND b.graph_kind='operation' AND b.source_scope_hash=NEW.source_scope_hash
     AND b.partition_id=NEW.partition_id AND b.source_count=NEW.effective_source_count)
    BEGIN SELECT RAISE(ABORT,'uncertified graph source authority'); END
    """)

    execute(~S"""
    CREATE TRIGGER graph_manifest_base_parent_guard BEFORE INSERT ON graph_manifest_builds
    WHEN json_extract(NEW.header_json,'$.context.base_context_ref') IS NOT NULL AND NOT EXISTS(
     SELECT 1 FROM dependency_manifests m JOIN graph_manifest_builds b ON b.workspace_id=m.workspace_id AND b.manifest_id=m.id
     WHERE m.workspace_id=NEW.workspace_id AND m.id=json_extract(NEW.header_json,'$.context.base_context_ref')
     AND m.digest=json_extract(NEW.header_json,'$.context.base_context_digest') AND m.state='sealed' AND b.phase='sealed'
     AND b.source_scope_hash=NEW.source_scope_hash AND b.partition_id=NEW.partition_id
     AND (b.manifest_id=NEW.source_manifest_id OR b.source_manifest_id=NEW.source_manifest_id))
    BEGIN SELECT RAISE(ABORT,'uncertified graph context parent'); END
    """)

    execute(~S"""
    CREATE TRIGGER graph_dependency_build_admission BEFORE INSERT ON origin_dependencies
    WHEN EXISTS(SELECT 1 FROM graph_manifest_builds b WHERE b.workspace_id=NEW.workspace_id AND b.manifest_id=NEW.manifest_id)
     AND NOT EXISTS(SELECT 1 FROM graph_manifest_builds b JOIN graph_manifest_pages p
     ON p.workspace_id=b.workspace_id AND p.manifest_id=b.manifest_id AND p.page_index=b.next_page_index
     WHERE b.workspace_id=NEW.workspace_id AND b.manifest_id=NEW.manifest_id AND b.phase='receiving' AND b.final_received=0
     AND NEW.ordinal>=p.first_ordinal AND NEW.ordinal<p.first_ordinal+p.row_count
     AND (b.graph_kind!='operation' OR (NEW.kind='source_revision' AND NEW.role='uncited')))
    BEGIN SELECT RAISE(ABORT,'graph dependency outside admitted page'); END
    """)

    execute(~S"""
    CREATE TRIGGER graph_dependency_parent_guard BEFORE INSERT ON origin_dependencies
    WHEN NEW.kind='manifest' AND EXISTS(SELECT 1 FROM graph_manifest_builds WHERE manifest_id=NEW.manifest_id)
     AND NOT EXISTS(SELECT 1 FROM graph_manifest_builds child JOIN dependency_manifests parent
     ON parent.workspace_id=child.workspace_id AND parent.id=NEW.parent_manifest_id
     JOIN graph_manifest_builds pb ON pb.workspace_id=parent.workspace_id AND pb.manifest_id=parent.id
     WHERE child.workspace_id=NEW.workspace_id AND child.manifest_id=NEW.manifest_id
     AND parent.state='sealed' AND parent.digest=NEW.content_hash AND pb.phase='sealed'
     AND pb.source_scope_hash=child.source_scope_hash AND pb.partition_id=child.partition_id
     AND (pb.manifest_id=child.source_manifest_id OR pb.source_manifest_id=child.source_manifest_id))
    BEGIN SELECT RAISE(ABORT,'uncertified graph parent'); END
    """)

    execute(~S"""
    CREATE TRIGGER graph_version_input_guard BEFORE INSERT ON graph_derivative_versions
    WHEN NOT EXISTS(SELECT 1 FROM dependency_manifests m JOIN graph_manifest_builds b
     ON b.workspace_id=m.workspace_id AND b.manifest_id=m.id
     JOIN graph_partition_controls p ON p.workspace_id=b.workspace_id AND p.id=b.partition_id
     WHERE m.workspace_id=NEW.workspace_id AND m.id=NEW.manifest_id AND m.state='sealed' AND b.phase='sealed'
     AND b.partition_id=NEW.partition_id AND (b.manifest_id=p.manifest_id OR b.source_manifest_id=p.manifest_id))
     OR NOT ((NEW.version=1 AND NEW.predecessor_id IS NULL) OR
     (NEW.version>1 AND NEW.predecessor_id IS NOT NULL AND EXISTS(SELECT 1 FROM graph_derivative_versions v
     WHERE v.workspace_id=NEW.workspace_id AND v.id=NEW.predecessor_id AND v.partition_id=NEW.partition_id
     AND v.object_kind=NEW.object_kind AND v.object_id=NEW.object_id AND v.version=NEW.version-1 AND v.state!='denied')))
    BEGIN SELECT RAISE(ABORT,'uncertified graph version input'); END
    """)

    execute(~S"""
    CREATE TRIGGER graph_episode_input_guard BEFORE INSERT ON graph_episode_bindings
    WHEN NEW.manifest_id IS NULL OR NOT EXISTS(SELECT 1 FROM dependency_manifests m JOIN graph_manifest_builds b
     ON b.workspace_id=m.workspace_id AND b.manifest_id=m.id
     JOIN graph_partition_controls p ON p.workspace_id=b.workspace_id AND p.id=b.partition_id
     WHERE m.workspace_id=NEW.workspace_id AND m.id=NEW.manifest_id AND m.state='sealed' AND b.phase='sealed'
     AND b.partition_id=NEW.partition_id AND (b.manifest_id=p.manifest_id OR b.source_manifest_id=p.manifest_id))
    BEGIN SELECT RAISE(ABORT,'uncertified graph episode input'); END
    """)

    execute(~S"""
    CREATE TRIGGER graph_manifest_seal_guard BEFORE UPDATE OF state ON dependency_manifests
    WHEN NEW.state='sealed' AND EXISTS(SELECT 1 FROM graph_manifest_builds WHERE manifest_id=NEW.id)
     AND NOT EXISTS(SELECT 1 FROM graph_manifest_builds b WHERE b.workspace_id=NEW.workspace_id AND b.manifest_id=NEW.id
     AND b.phase='sealed' AND b.candidate_digest=NEW.digest AND b.source_count=NEW.source_count
     AND b.validated_count=b.dependency_count AND b.validated_page_index=b.next_page_index AND b.validated_at IS NOT NULL)
    BEGIN SELECT RAISE(ABORT,'unverified graph manifest'); END
    """)

    execute(~S"""
    CREATE UNIQUE INDEX origin_dependency_ordinal ON origin_dependencies(manifest_id,ordinal)
    """)

    execute(~S"""
    CREATE UNIQUE INDEX origin_dependency_source ON origin_dependencies(manifest_id,source_id) WHERE kind='source_revision'
    """)

    execute(~S"""
    CREATE INDEX origin_dependency_episode ON origin_dependencies(workspace_id,episode_binding_id,manifest_id) WHERE episode_binding_id IS NOT NULL
    """)

    execute(~S"""
    CREATE INDEX origin_dependency_version ON origin_dependencies(workspace_id,derivative_version_id,manifest_id) WHERE derivative_version_id IS NOT NULL
    """)

    execute(~S"""
    CREATE TRIGGER graph_manifest_denied_terminal BEFORE UPDATE OF state ON dependency_manifests
    WHEN OLD.state='denied' AND NEW.state!='denied'
    BEGIN SELECT RAISE(ABORT,'denied manifest is terminal'); END
    """)

    execute(~S"""
    CREATE TRIGGER graph_manifest_page_admission BEFORE INSERT ON graph_manifest_pages
    WHEN NOT EXISTS(SELECT 1 FROM graph_manifest_builds b JOIN dependency_manifests m
     ON m.workspace_id=b.workspace_id AND m.id=b.manifest_id
     WHERE b.workspace_id=NEW.workspace_id AND b.manifest_id=NEW.manifest_id
     AND b.phase='receiving' AND m.state='building' AND b.final_received=0
     AND b.next_page_index=NEW.page_index AND b.dependency_count=NEW.first_ordinal)
    BEGIN SELECT RAISE(ABORT,'graph page out of sequence'); END
    """)

    execute(~S"""
    CREATE TRIGGER immutable_graph_manifest_pages_update BEFORE UPDATE ON graph_manifest_pages
    BEGIN SELECT RAISE(ABORT,'immutable graph manifest page'); END
    """)

    execute(~S"""
    CREATE TRIGGER immutable_graph_manifest_pages_delete BEFORE DELETE ON graph_manifest_pages
    BEGIN SELECT RAISE(ABORT,'immutable graph manifest page'); END
    """)

    execute(~S"""
    CREATE TRIGGER immutable_graph_episode_binding_identity BEFORE UPDATE ON graph_episode_bindings
    WHEN NEW.id IS NOT OLD.id OR NEW.workspace_id IS NOT OLD.workspace_id OR NEW.partition_id IS NOT OLD.partition_id OR
     NEW.revision_id IS NOT OLD.revision_id OR NEW.passage_id IS NOT OLD.passage_id OR NEW.chunker_version IS NOT OLD.chunker_version OR
     NEW.episode_uuid IS NOT OLD.episode_uuid OR NEW.payload_hash IS NOT OLD.payload_hash OR NEW.manifest_id IS NOT OLD.manifest_id OR
     NEW.inserted_at IS NOT OLD.inserted_at OR
     (OLD.publication_generation IS NOT NULL AND NEW.publication_generation IS NOT OLD.publication_generation) OR
     (OLD.state IN('denied','removed') AND NEW.state NOT IN('denied','removed'))
    BEGIN SELECT RAISE(ABORT,'immutable graph episode identity'); END
    """)
  end

  def down do
    raise Ecto.MigrationError,
      message:
        "Retain authoritative corpus, origin and attempt history; roll back application entry points instead."
  end
end
