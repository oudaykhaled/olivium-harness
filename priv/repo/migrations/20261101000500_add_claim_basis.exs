defmodule HarnessForge.Repo.Migrations.AddClaimBasis do
  use Ecto.Migration

  @claim_triggers ~w(immutable_evidence_claims_delete immutable_evidence_claims_update)

  def up do
    alter table(:evidence_claims) do
      add :basis, :map, null: true
    end
  end

  def down do
    %{rows: [[count]]} =
      Ecto.Adapters.SQL.query!(
        repo(),
        "SELECT count(*) FROM evidence_claims WHERE basis IS NOT NULL",
        [],
        log: false
      )

    if count != 0 do
      raise "Cannot remove claim basis while goal-origin claim data remains"
    end

    triggers = claim_triggers()

    if Enum.map(triggers, &hd/1) != @claim_triggers do
      raise "Cannot remove claim basis without both immutable claim triggers"
    end

    alter table(:evidence_claims) do
      remove :basis, :map
    end

    flush()

    if claim_triggers() != triggers do
      raise "Removing claim basis changed immutable claim triggers"
    end
  end

  defp claim_triggers do
    Ecto.Adapters.SQL.query!(
      repo(),
      "SELECT name, sql FROM sqlite_master WHERE type = 'trigger' AND name IN (?, ?) ORDER BY name",
      @claim_triggers,
      log: false
    ).rows
  end
end
