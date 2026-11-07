defmodule HarnessForge.Evidence.Corpus do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "corpora" do
    field :workspace_id, :string
    field :name, :string
    field :semantic_generation, :integer, default: 0
    field :authorization_generation, :integer, default: 0
    field :state, :string, default: "active"
    field :lock_version, :integer, default: 1
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule HarnessForge.Evidence.CorpusMember do
  @moduledoc false
  use Ecto.Schema
  @primary_key false
  schema "corpus_members" do
    field :workspace_id, :string
    field :corpus_id, :binary_id, primary_key: true
    field :source_id, :binary_id, primary_key: true
    field :revision_id, :binary_id
    field :passage_set_id, :binary_id
    field :status, :string
    field :last_seen_run_id, :binary_id
    timestamps(type: :utc_datetime_usec)
  end
end
