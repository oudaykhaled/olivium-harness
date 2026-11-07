defmodule HarnessForge.Company.RetrievalRun do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "retrieval_runs" do
    field :workspace_id, :string
    field :corpus_id, :binary_id
    field :project_id, :binary_id
    field :goal_id, :binary_id
    field :goal_hash, :string
    field :semantic_generation, :integer
    field :authorization_generation, :integer
    field :mode, :string
    field :state, :string
    field :envelope, :map
    field :coverage, :map
    field :digest, :string
    field :error_code, :string
    field :inserted_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
  end
end

defmodule HarnessForge.Company.RetrievalItem do
  @moduledoc false
  use Ecto.Schema
  @primary_key false
  schema "retrieval_items" do
    field :run_id, :binary_id, primary_key: true
    field :passage_id, :binary_id, primary_key: true
    field :candidate_order, :integer
    field :selected_order, :integer
    field :relation, :string
    field :lane, :string
    field :reason_code, :string
  end
end
