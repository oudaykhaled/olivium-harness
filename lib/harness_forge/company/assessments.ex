defmodule HarnessForge.Company.Assessments do
  @moduledoc """
  Immutable, owner-reported assessments of one goal in one exact Company package.

  A rubric freezes the representative task and declared obligation mapping before
  outcomes exist. A separate receipt preserves testimony and its captured authority;
  current applicability is always recalculated. These records confer no trusted
  evaluation, runtime, release, corporate identity or semantic-quality authority.
  """
  import Ecto.Query
  alias HarnessForge.{Audit, Contracts, Goals, Harnesses, Repo, Workspaces}
  alias HarnessForge.Evidence.Store
  alias HarnessForge.Company.{Assessment, TaskRubric}
  alias HarnessForge.Company.AssessmentAttempts, as: Attempts
  alias HarnessForge.Company.AssessmentValidation, as: Validation
  alias HarnessForge.Privacy.Purge

  @type result :: {:ok, map() | [map()]} | {:error, atom()}
  @privacy_errors [:privacy_operation_incomplete, :privacy_state_unavailable]
  @context_errors [
    :not_found,
    :stale_plan_revision,
    :superseded_plan,
    :plan_not_approved,
    :package_not_bound,
    :invalid_package,
    :goal_not_selected,
    :stale_goal,
    :analysis_recommendation_required,
    :stale_authority,
    :assessment_storage_failed
  ]

  @spec context(map()) :: result()
  def context(binding) do
    with {:ok, binding} <- Validation.context(binding) do
      fenced(fn -> resolve_context(binding) end)
    end
  end

  @spec freeze_rubric(map(), keyword()) :: result()
  def freeze_rubric(attrs, opts) do
    with {:ok, attrs} <- Validation.freeze(attrs), :ok <- Attempts.options(opts) do
      mutate(opts, fn ->
        with {:ok, context} <-
               resolve_context(
                 Map.take(
                   attrs,
                   ~w(plan_id expected_plan_revision_hash artifact_digest goal_id goal_content_hash)
                 )
               ),
             :ok <- Validation.mapping(attrs["obligations"], context["required_claim_refs"]),
             {:ok, previous} <- predecessor(attrs),
             :ok <- enforce_cap(TaskRubric, 100, :rubric_limit) do
          id = Ecto.UUID.generate()

          rubric = %TaskRubric{
            id: id,
            workspace_id: Store.workspace(),
            family_id: if(previous, do: previous.family_id, else: id),
            supersedes_id: previous && previous.id,
            payload: rubric_payload(context, attrs),
            inserted_at: Store.now()
          }

          with :ok <- Validation.canonical_size(rubric_object(rubric)),
               true <- Validation.rubric_payload?(rubric.payload),
               rubric = %{rubric | revision_hash: Contracts.digest(rubric_object(rubric))},
               :ok <- Attempts.authorize(opts),
               {:ok, rubric} <- insert_rubric(rubric),
               {:ok, _} <-
                 append_audit("company.task_rubric_frozen", %{
                   "rubric_id" => rubric.id,
                   "plan_id" => rubric.payload["binding"]["plan_id"],
                   "revision_hash" => rubric.revision_hash
                 }) do
            rubric_dto(rubric)
          else
            false -> {:error, :invalid_input}
            error -> error
          end
        end
      end)
    end
  end

  @spec get_rubric(String.t()) :: result()
  def get_rubric(id) do
    with :ok <- check(Validation.uuid?(id), :invalid_input),
         do: fenced(fn -> with {:ok, rubric} <- fetch_rubric(id), do: rubric_dto(rubric) end)
  end

  @spec list_rubrics() :: result()
  def list_rubrics do
    fenced(fn ->
      Repo.all(from r in Store.scoped(TaskRubric), order_by: [asc: r.inserted_at, asc: r.id])
      |> collect(fn rubric ->
        with {:ok, rubric} <- fetch_rubric(rubric.id), do: rubric_dto(rubric)
      end)
    end)
  end

  @spec new_attempt(String.t(), String.t(), keyword()) :: result()
  def new_attempt(id, expected, opts) do
    with true <- Validation.uuid?(id) and Validation.digest?(expected),
         :ok <- Attempts.options(opts) do
      mutate(opts, fn ->
        with {:ok, rubric} <- fetch_rubric(id),
             :ok <- check(rubric.revision_hash == expected, :stale_rubric),
             :ok <- original_workspace(rubric),
             :ok <- Attempts.authorize(opts) do
          Attempts.mint(rubric, opts)
        end
      end)
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  @spec record_assessment(map(), keyword()) :: result()
  def record_assessment(attrs, opts) do
    with {:ok, attrs} <- Validation.record(attrs), :ok <- Attempts.options(opts) do
      mutate(opts, fn ->
        with {:ok, rubric} <- fetch_rubric(attrs["rubric_id"]),
             :ok <- check(rubric.revision_hash == attrs["expected_rubric_hash"], :stale_rubric),
             :ok <- original_workspace(rubric),
             :ok <- Attempts.verify(attrs["attempt_token"], rubric, attrs["attempt_id"], opts),
             request = Validation.request(attrs),
             :ok <- Validation.canonical_size(request),
             digest = Contracts.digest(request) do
          case existing_attempt(attrs["attempt_id"]) do
            nil -> record_new(rubric, attrs, digest, opts)
            existing -> replay(existing, rubric, digest)
          end
        end
      end)
    end
  end

  @spec get_assessment(String.t()) :: result()
  def get_assessment(id) do
    with :ok <- check(Validation.uuid?(id), :invalid_input) do
      fenced(fn ->
        with {:ok, assessment} <- Store.get(Assessment, id),
             {:ok, rubric} <- fetch_rubric(assessment.rubric_id),
             :ok <- valid_assessment(assessment, rubric) do
          assessment_dto(assessment, rubric)
        end
      end)
    end
  end

  @spec list_assessments(String.t()) :: result()
  def list_assessments(id) do
    with :ok <- check(Validation.uuid?(id), :invalid_input) do
      fenced(fn ->
        with {:ok, rubric} <- fetch_rubric(id) do
          Repo.all(
            from a in Store.scoped(Assessment),
              where: a.rubric_id == ^id,
              order_by: [asc: a.inserted_at, asc: a.id]
          )
          |> collect(fn assessment ->
            with :ok <- valid_assessment(assessment, rubric),
                 do: assessment_dto(assessment, rubric)
          end)
        end
      end)
    end
  end

  defp resolve_context(binding) do
    with {:ok, resolved} <-
           Harnesses.assessment_inputs(
             binding["plan_id"],
             binding["expected_plan_revision_hash"],
             binding["artifact_digest"]
           ),
         goals = Enum.map(resolved["inputs"]["goals"], &goal_dto/1) |> Enum.sort_by(& &1["id"]),
         {:ok, goal} <- select_goal(goals, binding),
         claims = resolved["inputs"]["claims"],
         recommendations =
           Enum.filter(
             claims,
             &(analysis?(&1) and not is_nil(goal) and &1["basis"]["goal_id"] == goal["id"])
           )
           |> Enum.sort_by(& &1["id"]),
         :ok <- check(is_nil(goal) or recommendations != [], :analysis_recommendation_required) do
      {:ok,
       %{
         "binding" => %{
           "plan_id" => binding["plan_id"],
           "plan_revision_hash" => binding["expected_plan_revision_hash"],
           "artifact_digest" => binding["artifact_digest"]
         },
         "goals" => goals,
         "selected_goal" => goal,
         "required_claim_refs" => Enum.map(recommendations, &Map.take(&1, ~w(id revision_hash))),
         "recommendations" => recommendations,
         "milestones" =>
           if(is_nil(goal),
             do: [],
             else:
               Enum.filter(
                 resolved["plan"]["payload"]["milestones"],
                 &(goal["id"] in &1["goal_ids"])
               )
           ),
         "outside_goals" =>
           if(is_nil(goal), do: [], else: Enum.reject(goals, &(&1["id"] == goal["id"]))),
         "plan_snapshot" => resolved["plan"]["snapshot"],
         "applicability" => current()
       }}
    else
      {:error, reason} when reason in @context_errors or reason in @privacy_errors ->
        {:error, reason}

      _ ->
        {:error, :stale_authority}
    end
  end

  defp select_goal(_, %{"goal_id" => nil}), do: {:ok, nil}

  defp select_goal(goals, binding) do
    if is_nil(binding["goal_id"]) do
      {:ok, nil}
    else
      case Enum.find(goals, &(&1["id"] == binding["goal_id"])) do
        nil ->
          {:error, :goal_not_selected}

        goal ->
          if goal["content_hash"] == binding["goal_content_hash"],
            do: {:ok, goal},
            else: {:error, :stale_goal}
      end
    end
  end

  defp goal_dto(goal),
    do:
      goal
      |> Map.take(~w(id title owner acceptance))
      |> Map.put("content_hash", Goals.content_hash(goal))

  defp analysis?(%{"basis" => %{"kind" => "company_analysis"}}), do: true
  defp analysis?(_), do: false

  defp rubric_payload(context, attrs) do
    # The exact helper returns all selected claims; reread that same scoped input
    # to retain examined contexts for other package goals as well.
    {:ok, resolved} =
      Harnesses.assessment_inputs(
        attrs["plan_id"],
        attrs["expected_plan_revision_hash"],
        attrs["artifact_digest"]
      )

    contexts =
      resolved["inputs"]["claims"]
      |> Enum.filter(&analysis?/1)
      |> Enum.map(fn claim ->
        Map.take(claim, ~w(id revision_hash))
        |> Map.merge(Map.take(claim["basis"], ~w(context_digest context)))
      end)
      |> Enum.sort_by(& &1["id"])

    %{
      "version" => 1,
      "origin_workspace_id" => Store.workspace(),
      "binding" => context["binding"],
      "goal" => context["selected_goal"],
      "task" => attrs["task"],
      "obligations" => attrs["obligations"],
      "required_claim_refs" => context["required_claim_refs"],
      "plan_snapshot" => context["plan_snapshot"],
      "claim_contexts" => contexts
    }
  end

  defp predecessor(%{"supersedes_id" => id} = attrs) when not is_nil(id) do
    with {:ok, previous, meanings} <- fetch_rubric_lineage(id, []),
         :ok <- check(previous.revision_hash == attrs["expected_predecessor_hash"], :stale_rubric),
         :ok <- check(is_nil(successor(previous)), :already_superseded),
         :ok <- Validation.stable_ids(attrs["obligations"], Map.values(meanings)) do
      {:ok, previous}
    end
  end

  defp predecessor(_), do: {:ok, nil}

  defp fetch_rubric(id) do
    with {:ok, rubric, _meanings} <- fetch_rubric_lineage(id, []), do: {:ok, rubric}
  end

  defp fetch_rubric_lineage(id, seen) do
    with {:ok, rubric} <- Store.get(TaskRubric, id),
         :ok <- check(rubric.id not in seen and length(seen) < 100, :invalid_record_hash),
         :ok <- valid_rubric(rubric),
         {:ok, meanings} <- valid_lineage(rubric, [rubric.id | seen]) do
      {:ok, rubric, meanings}
    end
  end

  defp valid_lineage(%{supersedes_id: nil} = rubric, _) do
    with :ok <- check(rubric.family_id == rubric.id, :invalid_record_hash) do
      {:ok, Map.new(rubric.payload["obligations"], &{&1["id"], &1})}
    end
  end

  defp valid_lineage(rubric, seen) do
    with {:ok, previous, meanings} <- fetch_rubric_lineage(rubric.supersedes_id, seen),
         :ok <- check(previous.family_id == rubric.family_id, :invalid_record_hash),
         :ok <-
           check(
             Validation.stable_ids(rubric.payload["obligations"], Map.values(meanings)) == :ok,
             :invalid_record_hash
           ) do
      # Retain omitted definitions while unwinding the single bounded traversal.
      {:ok, Map.merge(meanings, Map.new(rubric.payload["obligations"], &{&1["id"], &1}))}
    else
      _ -> {:error, :invalid_record_hash}
    end
  end

  defp valid_rubric(rubric) do
    check(
      Validation.uuid?(rubric.id) and Validation.uuid?(rubric.family_id) and
        (is_nil(rubric.supersedes_id) or Validation.uuid?(rubric.supersedes_id)) and
        Validation.digest?(rubric.revision_hash) and Validation.json?(rubric.payload) and
        Validation.rubric_payload?(rubric.payload) and
        Validation.canonical_size(rubric_object(rubric)) == :ok and
        Contracts.digest(rubric_object(rubric)) == rubric.revision_hash,
      :invalid_record_hash
    )
  rescue
    _ -> {:error, :invalid_record_hash}
  end

  defp valid_assessment(assessment, rubric) do
    check(
      Validation.uuid?(assessment.id) and Validation.uuid?(assessment.attempt_id) and
        Validation.digest?(assessment.request_digest) and
        Validation.digest?(assessment.assessment_hash) and
        assessment.rubric_id == rubric.id and assessment.workspace_id == rubric.workspace_id and
        Validation.json?(assessment.payload) and
        Validation.assessment_payload?(assessment.payload) and
        assessment.payload["rubric_revision_hash"] == rubric.revision_hash and
        assessment.payload["origin_workspace_id"] == rubric.payload["origin_workspace_id"] and
        Validation.result_accounting(assessment.payload["results"], rubric.payload["obligations"]) ==
          :ok and
        Validation.canonical_size(assessment_object(assessment)) == :ok and
        Contracts.digest(assessment_object(assessment)) == assessment.assessment_hash and
        Contracts.digest(Validation.request_from_record(assessment)) == assessment.request_digest,
      :invalid_record_hash
    )
  rescue
    _ -> {:error, :invalid_record_hash}
  end

  defp record_new(rubric, attrs, digest, opts) do
    with :ok <- enforce_cap(Assessment, 1000, :assessment_limit),
         {:ok, applicability} <- applicability(rubric),
         :ok <- accepted_authority(attrs, applicability),
         :ok <- Validation.result_accounting(attrs["results"], rubric.payload["obligations"]),
         :ok <- Validation.acceptance(attrs) do
      record = %Assessment{
        id: Ecto.UUID.generate(),
        workspace_id: Store.workspace(),
        rubric_id: rubric.id,
        attempt_id: attrs["attempt_id"],
        request_digest: digest,
        payload:
          Map.take(attrs, ~w(task_status critical_status judgment results))
          |> Map.merge(%{
            "version" => 1,
            "origin_workspace_id" => Store.workspace(),
            "rubric_revision_hash" => rubric.revision_hash,
            "operator" => Workspaces.operator(),
            "authority_at_record" => applicability["status"],
            "authority_reason" => applicability["reason"]
          }),
        inserted_at: Store.now()
      }

      with :ok <- Validation.canonical_size(assessment_object(record)),
           record = %{record | assessment_hash: Contracts.digest(assessment_object(record))},
           :ok <- Attempts.authorize(opts),
           {:ok, saved} <- insert_assessment(record) do
        if saved.id == record.id do
          with {:ok, _} <-
                 append_audit("company.assessment_recorded", %{
                   "assessment_id" => saved.id,
                   "rubric_id" => rubric.id,
                   "attempt_id" => saved.attempt_id,
                   "assessment_hash" => saved.assessment_hash,
                   "status" => saved.payload["judgment"],
                   "actor" => Workspaces.operator()
                 }) do
            {:ok, Store.dto(saved) |> Map.put("applicability", applicability)}
          end
        else
          replay(saved, rubric, digest)
        end
      end
    end
  end

  defp accepted_authority(%{"judgment" => "not_accepted"}, _), do: :ok
  defp accepted_authority(_, %{"status" => "current"}), do: :ok
  defp accepted_authority(_, %{"reason" => "stale_rubric"}), do: {:error, :stale_rubric}
  defp accepted_authority(_, _), do: {:error, :stale_authority}

  defp replay(existing, rubric, digest) do
    with :ok <-
           check(
             existing.rubric_id == rubric.id and existing.request_digest == digest,
             :conflicting_attempt_replay
           ),
         :ok <- valid_assessment(existing, rubric) do
      assessment_dto(existing, rubric)
    end
  end

  defp existing_attempt(id),
    do: Repo.one(from a in Store.scoped(Assessment), where: a.attempt_id == ^id)

  defp successor(rubric),
    do: Repo.one(from r in Store.scoped(TaskRubric), where: r.supersedes_id == ^rubric.id)

  defp applicability(rubric) do
    with {:ok, next} <- validated_successor(rubric) do
      cond do
        rubric.payload["origin_workspace_id"] != Store.workspace() ->
          {:ok, %{"status" => "restored_historical", "reason" => "restored_historical"}}

        not is_nil(next) ->
          {:ok, %{"status" => "stale", "reason" => "stale_rubric"}}

        true ->
          current_authority(rubric)
      end
    end
  end

  defp validated_successor(rubric) do
    case successor(rubric) do
      nil -> {:ok, nil}
      next -> fetch_rubric(next.id)
    end
  end

  defp current_authority(rubric) do
    binding =
      rubric.payload["binding"]
      |> Map.delete("plan_revision_hash")
      |> Map.put("expected_plan_revision_hash", rubric.payload["binding"]["plan_revision_hash"])

    attrs =
      Map.merge(binding, %{
        "goal_id" => rubric.payload["goal"]["id"],
        "goal_content_hash" => rubric.payload["goal"]["content_hash"]
      })

    case resolve_context(attrs) do
      {:ok, context} ->
        captured =
          rubric_payload(
            context,
            Map.merge(attrs, Map.take(rubric.payload, ~w(task obligations)))
          )

        if captured == rubric.payload,
          do: {:ok, current()},
          else: {:ok, %{"status" => "stale", "reason" => "stale_authority"}}

      {:error, reason} when reason in @privacy_errors ->
        {:error, reason}

      {:error, :assessment_storage_failed} ->
        {:error, :assessment_storage_failed}

      {:error, reason} ->
        {:ok,
         %{
           "status" => "stale",
           "reason" =>
             if(reason == :not_found, do: "stale_authority", else: Atom.to_string(reason))
         }}
    end
  end

  defp rubric_dto(rubric) do
    with {:ok, next} <- validated_successor(rubric),
         {:ok, applicability} <- applicability(rubric) do
      {:ok,
       Store.dto(rubric)
       |> Map.merge(%{
         "superseded" => not is_nil(next),
         "successor_id" => next && next.id,
         "applicability" => applicability
       })}
    end
  end

  defp assessment_dto(assessment, rubric) do
    with {:ok, applicability} <- applicability(rubric) do
      applicability =
        if assessment.payload["origin_workspace_id"] != Store.workspace(),
          do: %{"status" => "restored_historical", "reason" => "restored_historical"},
          else: applicability

      {:ok, Store.dto(assessment) |> Map.put("applicability", applicability)}
    end
  end

  defp original_workspace(rubric),
    do:
      check(
        rubric.payload["origin_workspace_id"] == rubric.workspace_id and
          rubric.workspace_id == Store.workspace(),
        :restored_historical
      )

  defp current, do: %{"status" => "current", "reason" => nil}

  defp rubric_object(r),
    do: %{
      "format" => "harnessforge-company-task-rubric-v1",
      "id" => r.id,
      "family_id" => r.family_id,
      "supersedes_id" => r.supersedes_id,
      "payload" => r.payload
    }

  defp assessment_object(a),
    do: %{
      "format" => "harnessforge-company-assessment-v1",
      "id" => a.id,
      "rubric_id" => a.rubric_id,
      "attempt_id" => a.attempt_id,
      "request_digest" => a.request_digest,
      "payload" => a.payload
    }

  defp enforce_cap(schema, max, reason),
    do: check(Repo.aggregate(Store.scoped(schema), :count) < max, reason)

  defp insert_rubric(rubric) do
    rubric
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.unique_constraint([:workspace_id, :supersedes_id])
    |> Repo.insert()
    |> case do
      {:ok, saved} -> {:ok, saved}
      {:error, %Ecto.Changeset{}} -> {:error, :already_superseded}
      _ -> {:error, :assessment_storage_failed}
    end
  end

  defp insert_assessment(record) do
    case Repo.insert(record, on_conflict: :nothing, conflict_target: [:workspace_id, :attempt_id]) do
      {:ok, _} ->
        case existing_attempt(record.attempt_id) do
          nil -> {:error, :assessment_storage_failed}
          saved -> {:ok, saved}
        end

      _ ->
        {:error, :assessment_storage_failed}
    end
  end

  defp append_audit(action, details) do
    Audit.append(action, details)
  rescue
    _ -> {:error, :audit_failed}
  end

  defp mutate(opts, fun), do: fenced(fn -> with :ok <- Attempts.authorize(opts), do: fun.() end)

  defp fenced(fun) do
    Purge.synchronize(fn ->
      with :ok <- Workspaces.ensure_writable(), do: Store.transaction(fun)
    end)
  rescue
    _ -> {:error, :assessment_storage_failed}
  catch
    _, _ -> {:error, :assessment_storage_failed}
  end

  defp collect(values, fun) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case fun.(value) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  defp check(true, _), do: :ok
  defp check(false, reason), do: {:error, reason}
end
