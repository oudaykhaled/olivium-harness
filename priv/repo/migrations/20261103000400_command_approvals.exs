defmodule HarnessForge.Repo.Migrations.CommandApprovals do
  use Ecto.Migration

  def up do
    execute(~S"""
    CREATE TABLE command_approvals (
      id TEXT PRIMARY KEY NOT NULL,
      workspace_id TEXT NOT NULL,
      run_id TEXT NOT NULL REFERENCES evaluation_runs(id),
      artifact_digest TEXT NOT NULL CHECK(length(artifact_digest)=64 AND artifact_digest NOT GLOB '*[^0-9a-f]*'),
      profile_digest TEXT NOT NULL CHECK(length(profile_digest)=64 AND profile_digest NOT GLOB '*[^0-9a-f]*'),
      native_request_key TEXT NOT NULL CHECK(length(native_request_key)=64 AND native_request_key NOT GLOB '*[^0-9a-f]*'),
      request_digest TEXT NOT NULL CHECK(length(request_digest)=64 AND request_digest NOT GLOB '*[^0-9a-f]*'),
      payload TEXT NOT NULL CHECK(json_valid(payload) AND length(CAST(payload AS BLOB))<=16384),
      state TEXT NOT NULL DEFAULT 'pending' CHECK(state IN ('pending','accepted','declined','consumed')),
      expires_at TEXT NOT NULL,
      decided_at TEXT,
      consumed_at TEXT,
      decision_owner TEXT,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)

    create unique_index(:command_approvals, [:workspace_id, :run_id, :native_request_key])
    create index(:command_approvals, [:workspace_id, :run_id, :state])

    execute(~S"""
    CREATE TRIGGER command_approvals_scope_insert BEFORE INSERT ON command_approvals
    WHEN NOT EXISTS (
      SELECT 1 FROM evaluation_runs r
      WHERE r.id=NEW.run_id AND r.workspace_id=NEW.workspace_id
        AND r.artifact_digest=NEW.artifact_digest
        AND json_extract(r.result,'$.environment_profile_digest')=NEW.profile_digest
        AND json_extract(r.result,'$.runtime_name')='codex'
        AND json_extract(r.result,'$.execution_profile_id')='docker-codex-isolated-v1'
        AND json_extract(r.result,'$.outcome')='running'
    ) BEGIN SELECT RAISE(ABORT,'command approval scope mismatch'); END
    """)

    execute(~S"""
    CREATE TRIGGER immutable_command_approval_request BEFORE UPDATE ON command_approvals
    WHEN OLD.id!=NEW.id OR OLD.workspace_id!=NEW.workspace_id OR OLD.run_id!=NEW.run_id
      OR OLD.artifact_digest!=NEW.artifact_digest OR OLD.profile_digest!=NEW.profile_digest
      OR OLD.native_request_key!=NEW.native_request_key OR OLD.request_digest!=NEW.request_digest
      OR OLD.payload!=NEW.payload OR OLD.expires_at!=NEW.expires_at OR OLD.inserted_at!=NEW.inserted_at
    BEGIN SELECT RAISE(ABORT,'immutable command approval request'); END
    """)

    execute(~S"""
    CREATE TRIGGER command_approval_transition BEFORE UPDATE ON command_approvals
    WHEN NOT (
      (OLD.state='pending' AND NEW.state IN ('accepted','declined')) OR
      (OLD.state='accepted' AND NEW.state='consumed') OR
      (OLD.state='accepted' AND NEW.state='declined' AND julianday(NEW.updated_at)>=julianday(OLD.expires_at))
    ) BEGIN SELECT RAISE(ABORT,'command approval already decided'); END
    """)
  end

  def down do
    %{rows: [[count]]} = repo().query!("SELECT count(*) FROM command_approvals")

    if count != 0,
      do: raise(Ecto.MigrationError, "cannot remove recorded command approvals")

    drop table(:command_approvals)
  end
end
