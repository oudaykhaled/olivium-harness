defmodule HarnessForge.Company do
  @moduledoc """
  Workspace catalogue and immutable, explicitly approved composition plans.

  Catalogue descriptions and milestones are data, never policy authority. A plan
  selects exact approved claims and pins its catalogue and evidence snapshots.
  Every mutation shares the privacy fence and commits its audit event atomically.
  """
  import Ecto.Query
  alias HarnessForge.{Audit, Contracts, Evidence, Goals, Repo, Workspaces}
  alias HarnessForge.Evidence.{Store, Goal, Revision, Source, Connection}
  alias HarnessForge.Company.{Profile, Repository, Project, Plan, PlanDecision, Validation}
  alias HarnessForge.Privacy.Purge

  @type result :: {:ok, map() | list() | nil} | {:error, atom()}

  @doc "Select a relational corpus without altering legacy source selections or approvals."
  def bind_corpus(project_id, corpus_id, expected_profile, expected_project, caller) do
    mutate(fn ->
      with :ok <- HarnessForge.Company.AssessmentAttempts.options(caller),
           :ok <- HarnessForge.Company.AssessmentAttempts.authorize(caller),
           {:ok, profile} when not is_nil(profile) <- get_profile(),
           {:ok, project} <- Store.get(Project, project_id),
           :ok <-
             check(
               profile["content_hash"] == expected_profile and
                 project.content_hash == expected_project,
               :stale_content
             ),
           {:ok, %{rows: [[^corpus_id]]}} <-
             Repo.query(
               "SELECT id FROM corpora WHERE workspace_id=? AND id=? AND state='active'",
               [Store.workspace(), corpus_id]
             ),
           now = DateTime.to_iso8601(Store.now()),
           {:ok, _} <-
             Repo.query(
               "INSERT INTO company_corpus_bindings(workspace_id,project_id,profile_id,corpus_id,inserted_at,updated_at) VALUES(?,?,?,?,?,?) ON CONFLICT(workspace_id,project_id) DO UPDATE SET corpus_id=excluded.corpus_id,profile_id=excluded.profile_id,legacy_context_digest=NULL,updated_at=excluded.updated_at",
               [Store.workspace(), project_id, profile["id"], corpus_id, now, now]
             ) do
        {:ok, %{"project_id" => project_id, "corpus_id" => corpus_id}}
      else
        {:error, _} = e -> e
        _ -> {:error, :invalid_scope}
      end
    end)
  end

  def bound_corpus(project_id) do
    case Repo.query(
           "SELECT c.id,c.name,c.semantic_generation,c.authorization_generation,c.state FROM company_corpus_bindings b JOIN corpora c ON c.id=b.corpus_id AND c.workspace_id=b.workspace_id WHERE b.workspace_id=? AND b.project_id=?",
           [Store.workspace(), project_id]
         ) do
      {:ok, %{rows: [[id, name, sem, auth, state]]}} ->
        {:ok,
         %{
           "id" => id,
           "name" => name,
           "semantic_generation" => sem,
           "authorization_generation" => auth,
           "state" => state
         }}

      {:ok, %{rows: []}} ->
        {:ok, nil}

      _ ->
        {:error, :invalid_scope}
    end
  end

  @spec get_profile() :: result()
  def get_profile do
    case Repo.one(Store.scoped(Profile)) do
      nil -> {:ok, nil}
      profile -> {:ok, Store.dto(profile)}
    end
  end

  @spec save_profile(map()) :: result()
  def save_profile(attrs) do
    mutate(fn ->
      current = Repo.one(Store.scoped(Profile))
      save_catalog(Profile, current, attrs)
    end)
  end

  @spec list_repositories() :: result()
  def list_repositories, do: list_catalog(Repository)
  @spec list_projects() :: result()
  def list_projects, do: list_catalog(Project)
  @spec create_repository(map()) :: result()
  def create_repository(attrs), do: mutate(fn -> save_catalog(Repository, nil, attrs) end)
  @spec create_project(map()) :: result()
  def create_project(attrs), do: mutate(fn -> save_catalog(Project, nil, attrs) end)
  @spec update_repository(String.t(), map()) :: result()
  def update_repository(id, attrs), do: update_catalog(Repository, id, attrs)
  @spec update_project(String.t(), map()) :: result()
  def update_project(id, attrs), do: update_catalog(Project, id, attrs)

  @spec search_capabilities(String.t()) :: result()
  def search_capabilities(query) when is_binary(query) and byte_size(query) <= 2000 do
    if String.valid?(query) and String.length(query) <= 500 do
      tokens = query |> String.downcase() |> String.split() |> Enum.take(20)
      {:ok, repositories} = list_repositories()

      {:ok,
       Enum.filter(repositories, fn repository ->
         text = repository["payload"]["capabilities"] |> Enum.join(" ") |> String.downcase()
         tokens != [] and Enum.all?(tokens, &String.contains?(text, &1))
       end)}
    else
      {:error, :invalid_input}
    end
  end

  def search_capabilities(_), do: {:error, :invalid_input}

  @spec consumers(String.t()) :: result()
  def consumers(id) do
    with {:ok, _} <- Store.get(Repository, id), {:ok, repositories} <- list_repositories() do
      {:ok, Enum.filter(repositories, &(id in &1["payload"]["dependency_ids"]))}
    end
  end

  @spec create_plan(map()) :: result()
  def create_plan(attrs), do: create_plan(attrs, nil)

  def create_plan(attrs, source_context) do
    mutate(fn ->
      with {:ok, payload, supersedes_id} <- Validation.plan(attrs),
           {:ok, previous} <- previous_plan(supersedes_id, source_context),
           {:ok, snapshot, _claims, _goals} <- resolve(payload, source_context) do
        id = Ecto.UUID.generate()

        plan = %Plan{
          id: id,
          workspace_id: Store.workspace(),
          family_id: if(previous, do: previous.family_id, else: id),
          supersedes_id: supersedes_id,
          payload: payload,
          snapshot: snapshot,
          revision_hash: plan_hash(payload, snapshot),
          inserted_at: Store.now()
        }

        with {:ok, plan} <- Repo.insert(plan),
             {:ok, _} <- Audit.append("company.plan_proposed", %{"plan_id" => plan.id}),
             :ok <- assert_plan_use(plan.id, "compile", source_context) do
          {:ok, plan_dto(plan)}
        end
      end
    end)
  end

  @spec get_plan(String.t()) :: result()
  def get_plan(id), do: get_plan(id, nil)

  def get_plan(id, source_context) do
    with :ok <- assert_plan_use(id, "inspection", source_context),
         {:ok, plan} <- Store.get(Plan, id),
         :ok <- assert_plan_use(id, "inspection", source_context), do: {:ok, plan_dto(plan)}
  end

  @spec list_plans() :: result()
  def list_plans, do: list_plans(nil)

  def list_plans(source_context) do
    ids = Repo.all(from p in Store.scoped(Plan), order_by: [asc: p.inserted_at, asc: p.id], select: p.id)
    collect(ids, &get_plan(&1, source_context))
  end

  @spec decide_plan(String.t(), map()) :: result()
  def decide_plan(id, attrs), do: decide_plan(id, attrs, nil)

  def decide_plan(id, attrs, source_context) do
    mutate(fn ->
      with :ok <- Validation.decision(attrs),
           :ok <- assert_plan_use(id, "inspection", source_context),
           {:ok, plan} <- Store.get(Plan, id),
           :ok <- check(plan.revision_hash == attrs["expected_revision_hash"], :stale_revision),
           :ok <- check(is_nil(decision(plan)), :already_decided),
           :ok <- approval_eligible(plan, attrs["decision"], source_context),
           {:ok, _} <-
             Repo.insert(%PlanDecision{
               workspace_id: Store.workspace(),
               plan_id: id,
               actor: String.trim(attrs["actor"]),
               decision: attrs["decision"],
               revision_hash: plan.revision_hash,
               inserted_at: Store.now()
             }),
           {:ok, _} <-
             Audit.append("company.plan_decided", %{
               "plan_id" => id,
               "actor" => attrs["actor"],
               "decision" => attrs["decision"]
             }),
           :ok <- assert_plan_use(id, "inspection", source_context) do
        {:ok, plan_dto(plan)}
      end
    end)
  end

  @spec build_inputs(String.t()) :: result()
  def build_inputs(id), do: build_inputs(id, nil)

  def build_inputs(id, source_context) do
    with :ok <- Workspaces.ensure_writable() do
      Store.transaction(fn -> resolve_build_inputs(id, source_context) end)
    end
  end

  @doc false
  def assessment_build_inputs(id), do: assessment_build_inputs(id, nil)

  def assessment_build_inputs(id, source_context) do
    # Expected stale authority is data for a not-accepted assessment. Rolling
    # back a nested Ecto transaction would poison that caller's write transaction.
    with :ok <- Workspaces.ensure_writable(),
         :ok <- assert_plan_use(id, "compile", source_context),
         {:ok, plan} <- Store.get(Plan, id),
         {:ok, project} <- Store.get(Project, plan.payload["project_id"]),
         {:ok, repositories} <- fetch_all(Repository, plan.payload["repository_ids"]),
         records = [Repo.one(Store.scoped(Profile)), project | repositories],
         :ok <- check(Enum.all?(records, &assessment_catalog_hash?/1), :stale_authority) do
      resolve_build_inputs(id, source_context)
    end
  end

  defp assessment_catalog_hash?(%{payload: payload, content_hash: hash}) when is_map(payload) do
    Contracts.digest(payload) == hash
  rescue
    _ -> false
  end

  defp assessment_catalog_hash?(_), do: false

  defp resolve_build_inputs(id, source_context) do
    with :ok <- assert_plan_use(id, "compile", source_context),
         {:ok, plan} <- Store.get(Plan, id),
         :ok <-
           check(
             match?(
               %{decision: "approve", revision_hash: hash} when hash == plan.revision_hash,
               decision(plan)
             ),
             :plan_not_approved
           ),
         {:ok, claims, goals} <- eligible(plan, source_context) do
      {:ok,
       %{
         "plan_id" => plan.id,
         "plan_revision_hash" => plan.revision_hash,
         "name" => plan.payload["name"],
         "version" => plan.payload["package_version"],
         "runtime" => plan.payload["runtime"],
         "runtime_version" => plan.payload["runtime_version"],
         "repositories" => Enum.sort(Enum.map(plan.snapshot["repositories"], & &1["identity"])),
         "claims" => claims,
         "goals" => goals,
         "template_ids" => plan.payload["template_ids"],
         "execution" => plan.payload["execution"],
         "snapshot" => plan.snapshot
       }}
    end
  end

  @doc "Metadata-only source-use admission before plan payload projection."
  def assert_plan_use(id, purpose, source_context) do
    case Repo.one(from p in Store.scoped(Plan), where: p.id == ^id,
           select: fragment("json_extract(?, '$.claim_refs')", p.payload)) do
      json when is_binary(json) ->
        with {:ok, refs} when is_list(refs) <- Jason.decode(json) do
          Enum.reduce_while(refs, :ok, fn ref, :ok ->
            case Evidence.assert_claim_use(ref["id"], purpose, source_context) do
              :ok -> {:cont, :ok}
              error -> {:halt, error}
            end
          end)
        else
          _ -> {:error, :invalid_plan_hash}
        end
      nil -> {:error, :not_found}
      _ -> {:error, :invalid_plan_hash}
    end
  end

  defp list_catalog(schema),
    do: {:ok, Repo.all(from r in Store.scoped(schema), order_by: r.id) |> Enum.map(&Store.dto/1)}

  defp update_catalog(schema, id, attrs) do
    mutate(fn ->
      with {:ok, current} <- Store.get(schema, id), do: save_catalog(schema, current, attrs)
    end)
  end

  defp save_catalog(schema, current, attrs) do
    with {:ok, payload, expected} <- Validation.catalog(schema, attrs),
         :ok <- expected_hash(current, expected),
         :ok <- catalog_limit(schema, current),
         :ok <- catalog_references(schema, payload, current),
         changes = [payload: payload, content_hash: Contracts.digest(payload)],
         record = current || struct(schema, workspace_id: Store.workspace()),
         {:ok, saved} <- Repo.insert_or_update(Ecto.Changeset.change(record, changes)),
         {:ok, _} <- Audit.append("company.catalog_saved", %{"catalog_id" => saved.id}) do
      {:ok, Store.dto(saved)}
    end
  end

  defp expected_hash(nil, nil), do: :ok
  defp expected_hash(%{content_hash: hash}, hash), do: :ok
  defp expected_hash(_, _), do: {:error, :stale_content}
  defp catalog_limit(Profile, _), do: :ok
  defp catalog_limit(_, current) when not is_nil(current), do: :ok

  defp catalog_limit(schema, nil),
    do: check(Repo.aggregate(Store.scoped(schema), :count) < 100, :catalog_limit)

  defp catalog_references(Repository, payload, current) do
    repositories = Repo.all(Store.scoped(Repository))
    id = if current, do: current.id, else: Ecto.UUID.generate()

    with :ok <-
           check(
             not Enum.any?(
               repositories,
               &(&1.id != id and &1.payload["identity"] == payload["identity"])
             ),
             :duplicate_identity
           ),
         {:ok, _} <- fetch_all(Repository, payload["dependency_ids"]),
         :ok <- check(id not in payload["dependency_ids"], :self_dependency) do
      :ok
    end
  end

  defp catalog_references(schema, payload, _) do
    with {:ok, _} <- fetch_all(Goal, payload["goal_ids"]),
         {:ok, _} <- collect(payload["source_ids"], &active_source/1),
         {:ok, _} <-
           if(schema == Project,
             do: fetch_all(Repository, payload["repository_ids"]),
             else: {:ok, []}
           ) do
      :ok
    end
  end

  defp resolve(payload, source_context) do
    with profile when not is_nil(profile) <- Repo.one(Store.scoped(Profile)),
         {:ok, project} <- Store.get(Project, payload["project_id"]),
         :ok <-
           check(
             subset?(payload["repository_ids"], project.payload["repository_ids"]),
             :repository_out_of_scope
           ),
         {:ok, repositories} <- fetch_all(Repository, payload["repository_ids"]),
         allowed_sources =
           Enum.uniq(profile.payload["source_ids"] ++ project.payload["source_ids"]),
         allowed_goals = Enum.uniq(profile.payload["goal_ids"] ++ project.payload["goal_ids"]),
         :ok <- check(subset?(payload["goal_ids"], allowed_goals), :goal_out_of_scope),
         {:ok, goals} <- fetch_all(Goal, payload["goal_ids"]),
         {:ok, claims} <- collect(payload["claim_refs"], &approved_claim(&1, source_context)),
         :ok <- analysis_plan_context(claims, profile, project),
         :ok <- selected_claim_goals(claims, payload["goal_ids"]),
         {:ok, sources} <- claim_sources(claims, allowed_sources, source_context) do
      snapshot = %{
        "profile" => pin(profile),
        "project" => pin(project),
        "repositories" =>
          Enum.map(repositories, &(pin(&1) |> Map.put("identity", &1.payload["identity"]))),
        "sources" => sources,
        "claims" => payload["claim_refs"],
        "goals" => Enum.map(goals, &%{"id" => &1.id, "content_hash" => Goals.content_hash(&1)})
      }

      manifests =
        for %{"basis" => %{"version" => 2, "kind" => "company_analysis", "context" => context}} <-
              claims,
            do:
              Map.take(
                context,
                ~w(corpus_id semantic_generation authorization_generation retrieval_run_id retrieval_digest manifest_id manifest_digest)
              )

      snapshot =
        if manifests == [],
          do: snapshot,
          else: Map.put(snapshot, "manifests", Enum.sort(Enum.uniq(manifests)))

      {:ok, snapshot, claims, Enum.map(goals, &Store.dto/1)}
    else
      nil -> {:error, :profile_required}
      error -> error
    end
  end

  defp approved_claim(ref, source_context) do
    with :ok <- Evidence.assert_claim_use(ref["id"], "compile", source_context),
         {:ok, claim} <- Evidence.get_claim(ref["id"], source_context),
         :ok <- check(claim["revision_hash"] == ref["revision_hash"], :stale_claim),
         :ok <-
           check(claim["status"] == "approved" and not claim["superseded"], :claim_not_approved),
         {:ok, _} <- Evidence.validate_claim(claim, source_context, "compile") do
      {:ok, claim}
    end
  end

  defp selected_claim_goals(claims, selected) do
    check(
      Enum.all?(claims, fn claim ->
        is_nil(claim["basis"]) or claim["basis"]["goal_id"] in selected
      end),
      :goal_not_selected
    )
  end

  defp claim_sources(claims, allowed, source_context) do
    # v2 manifests are revalidated by approved_claim/1 and pinned separately;
    # never flatten a relational corpus back into the legacy source array.
    legacy =
      Enum.reject(
        claims,
        &match?(%{"basis" => %{"kind" => "company_analysis", "version" => 2}}, &1)
      )

    with {:ok, references} <- collect(legacy, &HarnessForge.Evidence.Origin.references/1) do
      references
      |> Enum.flat_map(& &1["revision_ids"])
      |> Enum.uniq()
      |> Enum.sort()
      |> collect(fn id ->
        with reference when not is_nil(reference) <- Repo.one(from r in Store.scoped(Revision), where: r.id == ^id, select: %{source_id: r.source_id, body_hash: r.body_hash}),
              {:ok, checked} <- HarnessForge.Evidence.Corpora.current_source(reference.source_id, id, "compile", source_context),
              revision = checked.revision,
             :ok <- check(revision.source_id in allowed, :source_out_of_scope),
             {:ok, source} <- active_source(revision.source_id),
             :ok <- check(source.latest_revision_id == revision.id, :stale_source),
             {:ok, connection} <- Store.get(Connection, source.connection_id),
             :ok <-
               HarnessForge.Connectors.Registry.document_scope(connection, %{
                 "external_id" => source.external_id,
                 "source_url" => revision.source_url,
                 "metadata" => revision.metadata
               }) do
          {:ok,
           %{"id" => source.id, "revision_id" => revision.id, "body_hash" => revision.body_hash}}
        end
      end)
      |> case do
        {:ok, sources} -> {:ok, Enum.sort_by(sources, & &1["id"])}
        error -> error
      end
    end
  end

  defp analysis_plan_context(claims, profile, project) do
    check(
      Enum.all?(claims, fn
        %{"basis" => %{"kind" => "company_analysis"} = basis} ->
          basis["project_id"] == project.id and
            basis["context"]["profile"] == pin(profile) and
            basis["context"]["project"] == pin(project)

        _ ->
          true
      end),
      :stale_company_analysis_context
    )
  end

  defp active_source(id) do
    with {:ok, source} <- Store.get(Source, id),
         {:ok, connection} <- Store.get(Connection, source.connection_id),
         :ok <-
           check(
             source.status == "active" and connection.status == "active" and
               not is_nil(source.latest_revision_id),
             :source_unavailable
           ) do
      {:ok, source}
    end
  end

  defp eligible(plan, source_context) do
    with :ok <-
           check(
             plan.revision_hash == plan_hash(plan.payload, plan.snapshot),
             :invalid_plan_hash
           ),
         {:ok, snapshot, claims, goals} <- resolve(plan.payload, source_context),
         :ok <- check(snapshot == plan.snapshot, :stale_plan) do
      {:ok, claims, goals}
    end
  end

  defp approval_eligible(plan, "approve", source_context) do
    with :ok <- check(not superseded?(plan), :superseded_revision),
         {:ok, _, _} <- eligible(plan, source_context),
         do: :ok
  end

  defp approval_eligible(_, "reject", _source_context), do: :ok

  defp previous_plan(nil, _source_context), do: {:ok, nil}

  defp previous_plan(id, source_context) do
    with :ok <- assert_plan_use(id, "inspection", source_context),
         {:ok, plan} <- Store.get(Plan, id),
         :ok <- check(not superseded?(plan), :already_superseded),
         do: {:ok, plan}
  end

  defp superseded?(plan),
    do: Repo.exists?(from p in Store.scoped(Plan), where: p.supersedes_id == ^plan.id)

  defp decision(plan),
    do: Repo.one(from d in Store.scoped(PlanDecision), where: d.plan_id == ^plan.id)

  defp plan_dto(plan) do
    status =
      case decision(plan) do
        %{decision: "approve"} -> "approved"
        %{decision: "reject"} -> "rejected"
        nil -> "proposed"
      end

    Store.dto(plan) |> Map.merge(%{"status" => status, "superseded" => superseded?(plan)})
  end

  defp plan_hash(payload, snapshot),
    do:
      Contracts.digest(%{
        "payload" => payload,
        "snapshot" => snapshot
      })

  defp pin(record), do: %{"id" => record.id, "content_hash" => record.content_hash}
  defp subset?(selected, allowed), do: Enum.all?(selected, &(&1 in allowed))
  defp fetch_all(schema, ids), do: collect(Enum.sort(ids), &Store.get(schema, &1))

  defp collect(values, fun) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, results} ->
      case fun.(value) do
        {:ok, result} -> {:cont, {:ok, [result | results]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  defp check(true, _), do: :ok
  defp check(false, reason), do: {:error, reason}

  defp mutate(fun) do
    Purge.synchronize(fn ->
      with :ok <- Workspaces.ensure_writable(), do: Store.transaction(fun)
    end)
  end
end
