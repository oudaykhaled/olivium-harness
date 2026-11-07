defmodule HarnessForge.Company.TaskRubric do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "company_task_rubrics" do
    field :workspace_id, :string
    field :family_id, :binary_id
    field :supersedes_id, :binary_id
    field :payload, :map
    field :revision_hash, :string
    field :inserted_at, :utc_datetime_usec
  end
end

defmodule HarnessForge.Company.Assessment do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "company_assessments" do
    field :workspace_id, :string
    field :rubric_id, :binary_id
    field :attempt_id, :binary_id
    field :request_digest, :string
    field :payload, :map
    field :assessment_hash, :string
    field :inserted_at, :utc_datetime_usec
  end
end
