defmodule HarnessForge.Company.Profile do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "company_profiles" do
    field :workspace_id, :string
    field :payload, :map
    field :content_hash, :string
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule HarnessForge.Company.Repository do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "company_repositories" do
    field :workspace_id, :string
    field :payload, :map
    field :content_hash, :string
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule HarnessForge.Company.Project do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "company_projects" do
    field :workspace_id, :string
    field :payload, :map
    field :content_hash, :string
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule HarnessForge.Company.Plan do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "company_plans" do
    field :workspace_id, :string
    field :family_id, :binary_id
    field :supersedes_id, :binary_id
    field :payload, :map
    field :snapshot, :map
    field :revision_hash, :string
    field :inserted_at, :utc_datetime_usec
  end
end

defmodule HarnessForge.Company.PlanDecision do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "company_plan_decisions" do
    field :workspace_id, :string
    field :plan_id, :binary_id
    field :actor, :string
    field :decision, :string
    field :revision_hash, :string
    field :inserted_at, :utc_datetime_usec
  end
end
