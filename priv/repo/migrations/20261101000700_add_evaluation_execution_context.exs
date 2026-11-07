defmodule HarnessForge.Repo.Migrations.AddEvaluationExecutionContext do
  use Ecto.Migration

  def up do
    alter table(:evaluation_runs) do
      add :execution_context, :map, null: true
    end
  end

  def down do
    %{rows: [[count]]} =
      Ecto.Adapters.SQL.query!(
        repo(),
        "SELECT count(*) FROM evaluation_runs WHERE execution_context IS NOT NULL",
        [],
        log: false
      )

    if count != 0 do
      raise "Cannot remove execution context while evaluation cleanup authority remains"
    end

    alter table(:evaluation_runs) do
      remove :execution_context, :map
    end
  end
end
