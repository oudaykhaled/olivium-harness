defmodule HarnessForge.Privacy.Company do
  @moduledoc false
  alias HarnessForge.{Contracts, Repo, Workspaces}

  @catalog ~w(company_profiles company_repositories company_projects)

  def dependencies(source_id, claim_ids) do
    catalog =
      Enum.flat_map(@catalog, fn table ->
        Enum.map(rows("SELECT id, payload FROM #{table} WHERE workspace_id = ?"), fn [id, data] ->
          {table, id, decode(data)}
        end)
      end)

    affected = MapSet.new([source_id | claim_ids])

    plans =
      rows("SELECT id, family_id, payload, snapshot FROM company_plans WHERE workspace_id = ?")

    families =
      plans
      |> Enum.filter(fn [_, _, payload, snapshot] ->
        dependent_plan?(decode(payload), decode(snapshot), affected)
      end)
      |> Enum.map(&Enum.at(&1, 1))

    plan_ids = for [id, family, _, _] <- plans, family in families, do: id

    digests =
      rows(
        "SELECT plan_id, artifact_digest FROM company_artifact_bindings WHERE workspace_id = ?"
      )
      |> Enum.filter(fn [id, _] -> id in plan_ids end)
      |> Enum.map(&List.last/1)
      |> Enum.uniq()

    assessments = assessment_dependencies(source_id, claim_ids, plan_ids)

    %{
      "plan_ids" => plan_ids,
      "artifact_digests" => digests,
      "rubric_ids" => assessments["rubric_ids"],
      "assessment_ids" => assessments["assessment_ids"],
      "catalog" =>
        Map.new(@catalog, fn table ->
          {table,
           for(
             {^table, id, payload} <- catalog,
             source_id in (payload["source_ids"] || []),
             do: id
           )}
        end)
    }
  end

  def purge(plan, source_id, claim_ids \\ []) do
    # Recompute even for an older durable operation whose plan predates these
    # tables. The privacy fence prevents new writes while removal is pending.
    current = assessment_dependencies(source_id, claim_ids, plan["plan_ids"] || [])
    rubric_ids = Enum.uniq((plan["rubric_ids"] || []) ++ current["rubric_ids"])
    assessment_ids = Enum.uniq((plan["assessment_ids"] || []) ++ current["assessment_ids"])

    for id <- assessment_ids, do: delete("company_assessments", "id", id)
    for id <- rubric_ids, do: delete("company_assessments", "rubric_id", id)
    delete_rubrics(rubric_ids)

    for id <- plan["plan_ids"] || [] do
      delete("company_plan_decisions", "plan_id", id)
      delete("company_plans", "id", id)
    end

    for table <- @catalog, id <- get_in(plan, ["catalog", table]) || [] do
      case Repo.query!("SELECT payload FROM #{table} WHERE workspace_id = ? AND id = ?", [
             Workspaces.current_id(),
             id
           ]).rows do
        [[data]] ->
          payload = decode(data) |> Map.update!("source_ids", &List.delete(&1, source_id))

          Repo.query!(
            "UPDATE #{table} SET payload = ?, content_hash = ?, updated_at = ? WHERE workspace_id = ? AND id = ?",
            [
              Jason.encode!(payload),
              Contracts.digest(payload),
              DateTime.to_iso8601(DateTime.utc_now()),
              Workspaces.current_id(),
              id
            ]
          )

        [] ->
          :ok
      end
    end

    :ok
  end

  def purge_assessments do
    Repo.query!("DELETE FROM company_assessments WHERE workspace_id = ?", [
      Workspaces.current_id()
    ])

    delete_rubrics(
      rows("SELECT id FROM company_task_rubrics WHERE workspace_id = ?")
      |> List.flatten()
    )
  end

  defp assessment_dependencies(source_id, claim_ids, plan_ids) do
    rubrics = rubric_nodes()
    validate_rubric_graph!(rubrics)

    families =
      for rubric <- rubrics,
          dependent_rubric?(rubric.payload, source_id, claim_ids, plan_ids),
          do: rubric.family_id

    ids = rubrics |> Enum.filter(&(&1.family_id in families)) |> Enum.map(& &1.id)
    ids = rubric_descendants(rubrics, ids)

    assessment_ids =
      for [id, rubric_id] <-
            rows("SELECT id, rubric_id FROM company_assessments WHERE workspace_id = ?"),
          rubric_id in ids,
          do: id

    %{"rubric_ids" => Enum.sort(ids), "assessment_ids" => Enum.sort(assessment_ids)}
  end

  defp rubric_nodes do
    Enum.map(
      rows(
        "SELECT id, family_id, supersedes_id, payload, revision_hash FROM company_task_rubrics WHERE workspace_id = ?"
      ),
      fn [id, family_id, parent, data, hash] ->
        payload = decode(data)

        object = %{
          "format" => "harnessforge-company-task-rubric-v1",
          "id" => id,
          "family_id" => family_id,
          "supersedes_id" => parent,
          "payload" => payload
        }

        unless is_map(payload) and is_map(payload["binding"]) and
                 is_map(payload["plan_snapshot"]) and is_list(payload["required_claim_refs"]) and
                 is_list(payload["claim_contexts"]) and hash == Contracts.digest(object),
               do: raise("invalid assessment dependency identity")

        %{id: id, family_id: family_id, parent: parent, payload: payload}
      end
    )
  end

  defp validate_rubric_graph!(rubrics) do
    by_id = Map.new(rubrics, &{&1.id, &1})

    valid =
      Enum.all?(rubrics, fn rubric ->
        if is_nil(rubric.parent),
          do: rubric.family_id == rubric.id,
          else: match?(%{family_id: family} when family == rubric.family_id, by_id[rubric.parent])
      end)

    graph = Map.new(rubrics, &{&1.id, if(&1.parent, do: [&1.parent], else: [])})

    unless valid and HarnessForge.Company.Validation.acyclic?(graph),
      do: raise("invalid assessment dependency graph")
  end

  defp dependent_rubric?(payload, source_id, claim_ids, plan_ids) do
    snapshot = payload["plan_snapshot"]
    references = payload["required_claim_refs"] ++ Map.get(snapshot, "claims", [])
    sources = Map.get(snapshot, "sources", [])

    contexts =
      Enum.flat_map(payload["claim_contexts"], fn context ->
        get_in(context, ["context", "sources"]) || []
      end)

    payload["binding"]["plan_id"] in plan_ids or
      Enum.any?(references, &(&1["id"] in claim_ids)) or
      Enum.any?(sources, &(&1["id"] == source_id)) or
      Enum.any?(contexts, &(&1["source_id"] == source_id))
  end

  defp rubric_descendants(rubrics, ids) do
    expanded = Enum.uniq(ids ++ for(r <- rubrics, r.parent in ids, do: r.id))
    if length(expanded) == length(ids), do: expanded, else: rubric_descendants(rubrics, expanded)
  end

  defp delete_rubrics(ids) do
    children = rows("SELECT id, supersedes_id FROM company_task_rubrics WHERE workspace_id = ?")
    existing = for [id, _] <- children, id in ids, do: id

    if existing != [] do
      leaves =
        Enum.reject(existing, fn id -> Enum.any?(children, fn [_, parent] -> parent == id end) end)

      if leaves == [], do: raise("invalid assessment deletion graph")
      Enum.each(leaves, &delete("company_task_rubrics", "id", &1))
      delete_rubrics(existing -- leaves)
    else
      :ok
    end
  end

  defp dependent_plan?(payload, snapshot, ids) do
    references =
      (snapshot["sources"] || []) ++
        (snapshot["claims"] || []) ++ (payload["claim_refs"] || [])

    Enum.any?(references, &(is_map(&1) and MapSet.member?(ids, &1["id"])))
  end

  defp rows(sql), do: Repo.query!(sql, [Workspaces.current_id()]).rows
  defp decode(value) when is_map(value), do: value
  defp decode(value), do: Jason.decode!(value)

  defp delete(table, column, value) do
    Repo.query!("DELETE FROM #{table} WHERE workspace_id = ? AND #{column} = ?", [
      Workspaces.current_id(),
      value
    ])
  end
end
