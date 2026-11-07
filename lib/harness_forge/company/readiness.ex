defmodule HarnessForge.Company.Readiness do
  @moduledoc "Bounded WEB observations of explicitly selected evidence; never command authority."
  alias HarnessForge.{Company, Evidence, Workspaces}
  alias HarnessForge.Company.{CorpusReview, ReadinessProjection, Retrieval}
  alias HarnessForge.Evidence.{Capture, Corpora}

  @doc "Observe selected records only. Analysis outcomes are explicitly current-session metadata."
  def for_corpus(selection, large, caller) do
    with {:ok, %{"scope" => selected}} <- CorpusReview.open_scope(selection, caller),
         {:ok, corpus} when is_map(corpus) <- Company.bound_corpus(selection["project_id"]),
         :ok <-
           Corpora.assert_current(
             corpus["id"],
             corpus["semantic_generation"],
             corpus["authorization_generation"]
           ) do
      scope = %{
        "workspace_id" => Workspaces.current_id(),
        "project_id" => selected["project"]["id"],
        "project_hash" => selected["project"]["content_hash"],
        "goal_id" => selected["goal"]["id"],
        "goal_hash" => selected["goal"]["content_hash"],
        "corpus_id" => corpus["id"],
        "semantic_generation" => corpus["semantic_generation"],
        "authorization_generation" => corpus["authorization_generation"]
      }

      {capture, omissions} =
        case large[:declaration_ref] || large[:declaration] do
          nil -> {selected_capture(large[:capture], selection, scope, caller), []}
          declaration -> declared_capture(declaration, selection, scope, caller)
        end

      analysis = selected_analysis(large, scope, caller)

      project(
        scope,
        %{"capture" => capture, "understanding" => analysis},
        capabilities(large, caller),
        DateTime.to_iso8601(DateTime.utc_now()),
        omissions
      )
    else
      _ -> project(%{}, %{})
    end
  rescue
    _ -> project(%{}, %{})
  end

  @doc "Project already checked selected plan metadata; no evaluation or release is inferred."
  def for_plan(project_record, plan, artifact, binding, preflight, checked_at \\ nil) do
    scope =
      if project_record,
        do: %{
          "workspace_id" => Workspaces.current_id(),
          "project_id" => project_record["id"],
          "project_hash" => project_record["content_hash"]
        },
        else: %{}

    if plan && plan["payload"]["project_id"] == scope["project_id"] do
      pins =
        Map.merge(scope, %{"plan_id" => plan["id"], "plan_revision_hash" => plan["revision_hash"]})

      refs = [ref("plan", plan["id"], plan["revision_hash"], "company")]
      claims = plan["payload"]["claim_refs"] || []
      claim = List.first(claims)

      pins =
        if claim,
          do:
            Map.merge(pins, %{
              "claim_id" => claim["id"],
              "claim_revision_hash" => claim["revision_hash"]
            }),
          else: pins

      # The immutable plan revision binds the complete claim set. Show a bounded
      # sample of exact references; preflight checked the full set separately.
      refs =
        refs ++
          Enum.map(Enum.take(claims, 6), &ref("claim", &1["id"], &1["revision_hash"], "company"))

      review =
        cond do
          plan["superseded"] == true ->
            fact("stale", "superseded_revision", pins)

          preflight == :eligible ->
            fact("complete_for_selected_scope", "exact_review_verified", pins, refs)

          match?({:blocked, _}, preflight) ->
            fact("unknown", "backing_record_unavailable", pins, refs)

          true ->
            fact("needs_input", "exact_review_required", pins, refs)
        end

      {candidate, release} =
        if is_map(artifact) and is_binary(artifact["digest"]) do
          pins = Map.put(pins, "artifact_digest", artifact["digest"])
          refs = refs ++ [ref("artifact", artifact["digest"], artifact["digest"], "packages")]

          checked =
            preflight == :eligible and is_map(binding) and
              binding["plan_id"] == plan["id"] and
              binding["expected_plan_revision_hash"] == plan["revision_hash"] and
              binding["artifact_digest"] == artifact["digest"]

          candidate =
            if checked,
              do: fact("complete_for_selected_scope", "artifact_verified", pins, refs, "static"),
              else: fact("unknown", "artifact_binding_unavailable", pins, refs, "static")

          {candidate, fact("blocked", "qualification_missing", pins, refs)}
        else
          {fact("unknown", "not_observed", pins), fact("unknown", "release_not_observed", pins)}
        end

      project(
        scope,
        %{"review" => review, "candidate" => candidate, "release" => release},
        %{},
        checked_at
      )
    else
      project(scope, %{}, %{}, checked_at)
    end
  end

  defp capabilities(large, caller) do
    unknown = %{"status" => "unknown", "reason_code" => "not_observed"}

    fts =
      with %{"run_id" => id, "digest" => digest} <- large[:run],
           {:ok, %{"mode" => "fts"}} <- Retrieval.read_summary(id, digest, caller) do
        %{"status" => "available", "reason_code" => "fts_available"}
      else
        _ -> unknown
      end

    %{"fts" => fts, "graph" => unknown}
  end

  defp declared_capture(declaration, selection, scope, caller) do
    with {:ok, summary} <-
           Corpora.requirements_summary(declaration["id"], declaration["digest"], caller),
         true <- summary["primary_connection_id"] == selection["connection_id"],
         true <- Enum.all?(scope, fn {key, value} -> summary["scope"][key] == value end) do
      pins =
        Map.merge(summary["scope"], %{
          "declaration_id" => summary["id"],
          "declaration_revision" => summary["revision"],
          "declaration_digest" => summary["digest"]
        })

      references = [
        Map.put(
          ref("declaration", summary["id"], summary["digest"], "corpus"),
          "revision",
          summary["revision"]
        )
      ]

      {status, reason} =
        case summary["required_status"] do
          "complete" ->
            {"complete_for_selected_scope", "declared_scope_verified"}

          "blocked" ->
            {"blocked", "required_scope_incomplete"}

          "stale" ->
            {"stale", "stale_declaration"}

          _ ->
            {"unknown",
             if(summary["undeclared_members"] > 0,
               do: "undeclared_members",
               else: "declared_scope_unknown"
             )}
        end

      {fact(status, reason, pins, references), summary["omissions"]}
    else
      {:error, reason} when reason in [:stale_declaration, :stale_receipt, :stale_generation] ->
        {fact("stale", "stale_declaration", scope), []}

      _ ->
        {fact("unknown", "backing_record_unavailable", scope), []}
    end
  end

  defp selected_capture(nil, _, scope, _), do: fact("unknown", "not_observed", scope)

  defp selected_capture(selected, selection, scope, caller) do
    case Capture.read_summary(selected["run_id"], caller) do
      {:ok, capture} ->
        pins =
          Map.merge(scope, capture["scope"] || %{})
          |> Map.merge(%{
            "capture_run_id" => capture["run_id"],
            "capture_revision" => capture["revision"]
          })

        refs = [
          Map.put(
            ref("capture", capture["run_id"], nil, "corpus"),
            "revision",
            capture["revision"]
          )
        ]

        cond do
          capture["corpus_id"] != scope["corpus_id"] or
              capture["connection_id"] != selection["connection_id"] ->
            fact("stale", "scope_mismatch", pins)

          capture["scope_current"] == "stale" ->
            fact("stale", "stale_generation", pins)

          capture["capture"]["complete"] && capture["scope_current"] == "current" ->
            fact("complete_for_selected_scope", "capture_verified", pins, refs)

          capture["capture"]["complete"] ->
            fact("unknown", "missing_required_pins", pins, refs, "historical_reconstruction")

          capture["state"] in ~w(queued running) ->
            fact("running", "capture_running", pins, refs)

          capture["state"] == "cancelled" ->
            fact("cancelled", "capture_cancelled", pins, refs)

          true ->
            fact("needs_input", "capture_incomplete", pins, refs)
        end

      _ ->
        fact("unknown", "backing_record_unavailable", scope)
    end
  end

  defp selected_analysis(large, scope, caller) do
    run = large[:run]
    observation = large[:analysis_observation]

    if is_map(run) do
      case Retrieval.read_summary(run["run_id"], run["digest"], caller) do
        {:ok, checked} ->
          run_scope = checked["scope"]

          pins =
            Map.merge(run_scope, %{
              "project_hash" => run_scope["project"]["content_hash"],
              "run_id" => checked["run_id"],
              "run_digest" => checked["digest"]
            })

          if Enum.all?(scope, fn {key, value} -> pins[key] == value end) do
            observed_analysis(observation, large[:claim], pins)
          else
            fact("stale", "scope_mismatch", pins)
          end

        {:error, reason} when reason in [:stale_generation, :stale_revision, :invalid_scope] ->
          fact("stale", "stale_generation", scope)

        _ ->
          fact("unknown", "backing_record_unavailable", scope)
      end
    else
      fact("unknown", "not_observed", scope)
    end
  end

  defp observed_analysis(observation, claim, pins) when is_map(observation) do
    if observation["run_id"] == pins["run_id"] and observation["run_digest"] == pins["run_digest"] do
      refs = [ref("retrieval", pins["run_id"], pins["run_digest"], "corpus")]

      case observation["status"] do
        "running" -> fact("running", "analysis_running", pins, refs, "current_session")
        "abstained" -> fact("needs_input", "analysis_abstained", pins, refs, "current_session")
        "failed" -> fact("blocked", "analysis_failed", pins, refs, "current_session")
        "proposed" -> proposed_observation(observation, claim, pins, refs)
        _ -> fact("unknown", "analysis_unavailable", pins, refs, "current_session")
      end
    else
      fact("stale", "scope_mismatch", pins)
    end
  end

  defp observed_analysis(_, _, pins), do: fact("unknown", "not_observed", pins)

  defp proposed_observation(observation, claim, pins, refs) do
    with %{"id" => id, "revision_hash" => hash} <- claim,
         ^id <- observation["claim_id"],
         ^hash <- observation["claim_revision_hash"],
         {:ok, %{"revision_hash" => ^hash, "superseded" => false} = current} <-
           Evidence.get_claim(id),
         {:ok, _} <- Evidence.validate_claim(current) do
      pins = Map.merge(pins, %{"claim_id" => id, "claim_revision_hash" => hash})

      fact(
        "complete_for_selected_scope",
        "analysis_proposed",
        pins,
        refs ++ [ref("claim", id, hash, "company")],
        "current_session"
      )
    else
      _ -> fact("unknown", "backing_record_unavailable", pins)
    end
  end

  defp fact(status, reason, pins, references \\ [], kind \\ "current_content"),
    do: %{
      "status" => status,
      "reason_code" => reason,
      "pins" => pins,
      "references" => references,
      "evidence_kind" => kind
    }

  defp ref(kind, id, digest, destination),
    do: %{"kind" => kind, "id" => id, "digest" => digest, "destination_code" => destination}

  defp project(
         scope,
         facts,
         capabilities \\ %{},
         observed_at \\ DateTime.to_iso8601(DateTime.utc_now()),
         omissions \\ []
       ) do
    ReadinessProjection.project(%{
      "scope" => scope,
      "observed_at" => observed_at,
      "facts" => facts,
      "capabilities" => capabilities,
      "omissions" => omissions,
      "next_action" => nil
    })
  end
end
