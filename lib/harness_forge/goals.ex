defmodule HarnessForge.Goals do
  @moduledoc "Workspace-owned goals with an explicit owner and verifiable acceptance statement."
  import Ecto.Query
  alias HarnessForge.{Repo, Audit, Evidence.Store, Evidence.Goal}

  @doc "The canonical content identity pinned by claims and company plan snapshots."
  @spec content_hash(map()) :: String.t()
  def content_hash(%Goal{} = goal), do: goal |> Store.dto() |> content_hash()

  def content_hash(goal) when is_map(goal),
    do: goal |> Map.take(~w(id title owner acceptance)) |> HarnessForge.Contracts.digest()

  def list_goals do
    {:ok,
     Repo.all(from g in Store.scoped(Goal), order_by: g.inserted_at) |> Enum.map(&Store.dto/1)}
  end

  def add_goal(attrs) do
    with :ok <- HarnessForge.Workspaces.ensure_writable(),
         :ok <- Store.required(attrs, ~w(title owner acceptance)) do
      Store.transaction(fn ->
        with {:ok, goal} <-
               Repo.insert(%Goal{
                 workspace_id: Store.workspace(),
                 title: String.trim(attrs["title"]),
                 owner: String.trim(attrs["owner"]),
                 acceptance: String.trim(attrs["acceptance"]),
                 inserted_at: Store.now()
               }),
             {:ok, _} <- Audit.append("goal.created", %{"goal_id" => goal.id}) do
          {:ok, Store.dto(goal)}
        end
      end)
    end
  end
end
