defmodule HarnessForge.Evidence.Store do
  @moduledoc false
  import Ecto.Query
  alias HarnessForge.Repo

  def workspace do
    if Code.ensure_loaded?(HarnessForge.Workspaces) and
         function_exported?(HarnessForge.Workspaces, :current_id, 0) do
      apply(HarnessForge.Workspaces, :current_id, [])
    else
      Application.get_env(:harness_forge, :workspace_id, "local-workspace")
    end
  end

  def scoped(schema), do: from(record in schema, where: record.workspace_id == ^workspace())

  def get(schema, id) when is_binary(id) do
    with {:ok, _} <- Ecto.UUID.cast(id),
         record when not is_nil(record) <- Repo.one(from r in scoped(schema), where: r.id == ^id) do
      {:ok, record}
    else
      _ -> {:error, :not_found}
    end
  end

  def get(_, _), do: {:error, :not_found}

  def dto(%{__struct__: _} = record) do
    record
    |> Map.from_struct()
    |> Map.drop([:__meta__])
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value_dto(value)} end)
  end

  defp value_dto(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp value_dto(value), do: value

  def now, do: DateTime.utc_now()
  def hash(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

  def required(attrs, fields) when is_map(attrs) do
    if Enum.all?(fields, fn field ->
         is_binary(attrs[field]) and String.trim(attrs[field]) != "" and
           String.length(attrs[field]) <= 10_000
       end),
       do: :ok,
       else: {:error, :invalid_input}
  end

  def required(_, _), do: {:error, :invalid_input}

  def transaction(fun) do
    Repo.transaction(fn ->
      case fun.() do
        {:ok, result} -> result
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end
end
