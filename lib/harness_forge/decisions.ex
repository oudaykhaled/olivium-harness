defmodule HarnessForge.Decisions do
  @moduledoc "Explicit, append-only decisions tied to the exact immutable claim revision hash."
  import Ecto.Query
  alias HarnessForge.{Repo, Audit, Evidence}
  alias HarnessForge.Evidence.{Store, Claim, Decision}

  def decide(claim_id, attrs), do: decide(claim_id, attrs, nil)

  def decide(claim_id, attrs, source_context) do
    HarnessForge.Privacy.Purge.synchronize(fn ->
      Store.transaction(fn ->
        with :ok <- HarnessForge.Workspaces.ensure_writable(),
             :ok <- Store.required(attrs, ~w(actor decision expected_revision_hash)),
             true <- attrs["decision"] in ~w(approve reject) do
          with :ok <- Evidence.assert_claim_use(claim_id, "inspection", source_context),
               {:ok, claim} <- Store.get(Claim, claim_id),
               true <- claim.revision_hash == attrs["expected_revision_hash"],
               false <-
                 Repo.exists?(from c in Store.scoped(Claim), where: c.supersedes_id == ^claim_id),
               {:ok, _} <- Evidence.validate_claim(claim, source_context, "inspection"),
               :ok <- approval_resolution(claim, attrs["decision"]),
               {:ok, decision} <-
                 %Decision{
                   workspace_id: Store.workspace(),
                   claim_id: claim.id,
                   actor: String.trim(attrs["actor"]),
                   decision: attrs["decision"],
                   revision_hash: claim.revision_hash,
                   inserted_at: Store.now()
                 }
                 |> Ecto.Changeset.change()
                 |> Ecto.Changeset.unique_constraint(:claim_id)
                 |> Repo.insert(),
               {:ok, _} <-
                 Audit.append("claim.decided", %{
                   "claim_id" => claim.id,
                   "actor" => decision.actor,
                   "decision" => decision.decision
                 }) do
            Evidence.get_claim(claim.id, source_context)
          else
            false -> {:error, :stale_revision}
            true -> {:error, :superseded_revision}
            {:error, %Ecto.Changeset{}} -> {:error, :already_decided}
            error -> error
          end
        else
          false -> {:error, :invalid_decision}
          error -> error
        end
      end)
    end)
  end

  defp approval_resolution(claim, "approve") do
    if Evidence.approval_ready?(Store.dto(claim)),
      do: :ok,
      else: {:error, :analysis_resolution_required}
  end

  defp approval_resolution(_, "reject"), do: :ok
end
