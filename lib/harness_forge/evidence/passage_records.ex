defmodule HarnessForge.Evidence.PassageSet do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "passage_sets" do
    field :workspace_id, :string
    field :source_id, :binary_id
    field :revision_id, :binary_id
    field :body_hash, :string
    field :body_bytes, :integer
    field :chunker_version, :string
    field :parser_version, :string
    field :state, :string
    field :passage_count, :integer
    field :indexed_count, :integer
    field :manifest_digest, :string
    field :error_code, :string
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule HarnessForge.Evidence.Passage do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:rowid, :id, autogenerate: true}
  schema "passages" do
    field :id, :binary_id
    field :workspace_id, :string
    field :passage_set_id, :binary_id
    field :ordinal, :integer
    field :start_byte, :integer
    field :end_byte, :integer
    field :snippet_hash, :string
    field :parent_start_byte, :integer
    field :parent_end_byte, :integer
    field :parent_hash, :string
  end
end
