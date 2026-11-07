defmodule HarnessForgeWeb.CompanyAssessmentState do
  @moduledoc false
  alias HarnessForge.Company.{Assessments, AssessmentValidation}

  @binding ~w(plan_id expected_plan_revision_hash artifact_digest)
  @freeze @binding ++ ~w(goal_id goal_content_hash task obligations)
  @record ~w(rubric_id expected_rubric_hash attempt_id attempt_token task_status critical_status judgment results)
  @replacing ~w(company_assessment_open assessment_history_open assessment_attempt_start)

  def empty do
    %{
      "stage" => "scope",
      "context" => nil,
      "scope_input" => %{},
      "rubric_draft" => %{},
      "frozen_rubric" => nil,
      "result_draft" => %{},
      "attempt" => nil,
      "receipt" => nil,
      "history" => [],
      "dirty" => false,
      "error" => nil,
      "notice" => nil,
      "pending_destination" => nil,
      "departure_origin" => nil
    }
  end

  def replacing?(event, attrs),
    do:
      event in @replacing or
        (event == "assessment_rubric_change" and attrs["action"] == "successor")

  def origin(%{"stage" => "rubric"}), do: "company-assessment-task"
  def origin(%{"stage" => "results"}), do: "company-assessment-results"
  def origin(_), do: "company-assessment-start"

  def pending(state, destination),
    do:
      state
      |> Map.put("pending_destination", destination)
      |> Map.put("departure_origin", origin(state))

  def clear_pending(state),
    do: state |> Map.put("pending_destination", nil) |> Map.put("departure_origin", nil)

  def refresh(state) do
    with {:ok, frozen} <- refresh_rubric(state["frozen_rubric"]),
         {:ok, receipt} <- refresh_receipt(state["receipt"]),
         {:ok, history} <- refresh_history(frozen),
         {:ok, context} <- refresh_context(state["context"]) do
      {:ok,
       state
       |> Map.put("frozen_rubric", frozen)
       |> Map.put("receipt", receipt)
       |> Map.put("history", history)
       |> Map.put("context", context)}
    else
      {:error, reason} -> {:reset, reason}
    end
  end

  def uncaptured(state),
    do:
      state
      |> Map.put("dirty", true)
      |> Map.put("uncaptured_input", true)
      |> Map.put("error", :input_too_large)

  def save_before_departure(%{"uncaptured_input" => true} = state, _action, _opts),
    do: {Map.put(state, "error", :input_too_large), "company-assessment-error"}

  def save_before_departure(state, "freeze", opts) do
    if state["stage"] == "rubric" do
      case Assessments.freeze_rubric(state["rubric_draft"], opts) do
        {:ok, rubric} -> {frozen(state, rubric, []), "company-assessment-frozen"}
        {:error, reason} -> {Map.put(state, "error", reason), "company-assessment-error"}
      end
    else
      {Map.put(state, "error", :invalid_input), "company-assessment-error"}
    end
  end

  def save_before_departure(state, "record_not_accepted", opts) do
    if state["stage"] == "results" do
      draft = Map.put(state["result_draft"], "judgment", "not_accepted")

      case Assessments.record_assessment(draft, opts) do
        {:ok, receipt} ->
          next = frozen(state, state["frozen_rubric"], state["history"] ++ [receipt])
          {Map.put(next, "receipt", receipt), "company-assessment-receipt"}

        {:error, reason} ->
          {state |> Map.put("result_draft", draft) |> Map.put("error", reason),
           "company-assessment-error"}
      end
    else
      {Map.put(state, "error", :invalid_input), "company-assessment-error"}
    end
  end

  # Only empty LiveView unused markers are transport metadata. Other unknown
  # fields survive normalization and are refused by the exact shape checks.
  def envelope(attrs, generation, event) when is_map(attrs) do
    with ^generation <- attrs["assessment_event_generation"],
         true <- valid_target?(attrs["_target"]),
         attrs = Map.drop(attrs, ~w(assessment_event_generation _target)),
         true <- AssessmentValidation.json?(attrs),
         true <- byte_size(Jason.encode!(attrs)) <= 262_144 do
      {:ok, attrs |> browser_button_metadata(event) |> unused()}
    else
      _ -> {:error, :invalid_input}
    end
  end

  def envelope(_, _, _), do: {:error, :invalid_input}

  # LiveView's browser serializer adds the default button value to clicks.
  # Only this empty outer field on known buttons is transport metadata.
  # Form values, unknown actions and nonempty values remain strict inputs.
  defp browser_button_metadata(attrs, event)
       when event in ~w(company_assessment_open assessment_history_open assessment_attempt_start),
       do: empty_button_value(attrs)

  defp browser_button_metadata(%{"action" => action} = attrs, "assessment_rubric_change")
       when action in ~w(add_owner add_guidance remove_row successor),
       do: empty_button_value(attrs)

  defp browser_button_metadata(%{"stage" => stage} = attrs, "assessment_discard")
       when stage in ~w(rubric results),
       do: empty_button_value(attrs)

  defp browser_button_metadata(%{"action" => action} = attrs, "assessment_departure_resolve")
       when action in ~w(keep discard freeze record_not_accepted),
       do: empty_button_value(attrs)

  defp browser_button_metadata(attrs, _), do: attrs
  defp empty_button_value(%{"value" => ""} = attrs), do: Map.delete(attrs, "value")
  defp empty_button_value(attrs), do: attrs

  def dispatch(event, attrs, state, opts) do
    case perform(event, attrs, state, opts) do
      {:ok, next, focus} -> {Map.put(next, "error", nil), focus}
      {:error, reason, next} -> {Map.put(next, "error", reason), "company-assessment-error"}
      {:error, reason} -> {Map.put(state, "error", reason), "company-assessment-error"}
    end
  end

  defp perform("company_assessment_open", attrs, state, _opts) do
    with :ok <- shape(attrs, @binding), {:ok, context} <- Assessments.context(attrs) do
      next = Map.put(empty(), "context", context)

      next =
        if state["predecessor"],
          do:
            next
            |> Map.put("predecessor", state["predecessor"])
            |> Map.put("notice", successor_notice()),
          else: next

      {:ok, next, "company-assessment-goal"}
    end
  end

  defp perform("assessment_goal_change", %{"scope" => attrs} = payload, state, _opts) do
    with :ok <- shape(payload, ["scope"]),
         :ok <- shape(attrs, @binding ++ ["goal_snapshot"]),
         true <- state["stage"] == "scope" and is_map(state["context"]),
         true <- Map.take(attrs, @binding) == context_binding(state),
         {:ok, {id, hash}} <- pair(attrs["goal_snapshot"]),
         {:ok, context} <-
           Assessments.context(
             Map.merge(context_binding(state), %{"goal_id" => id, "goal_content_hash" => hash})
           ) do
      next = state |> Map.put("context", context) |> Map.put("scope_input", attrs)

      {:ok,
       next
       |> Map.put("stage", "rubric")
       |> Map.put("rubric_draft", successor_draft(suggested(context), state["predecessor"])),
       "company-assessment-task"}
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  defp perform("assessment_rubric_change", %{"rubric" => _} = attrs, state, _opts),
    do: capture_rubric(attrs, state)

  defp perform("assessment_rubric_change", %{"action" => action} = attrs, state, _opts)
       when action in ~w(add_owner add_guidance) do
    with :ok <- shape(attrs, ["action"]),
         true <- state["stage"] == "rubric",
         rows = state["rubric_draft"]["obligations"],
         true <- is_list(rows) and length(rows) < 20 do
      kind = if action == "add_owner", do: "owner_authored", else: "approved_analysis_guidance"
      row = obligation("obligation-" <> random_id(), kind, "", [])

      {:ok,
       put_draft(
         state,
         "rubric_draft",
         Map.put(state["rubric_draft"], "obligations", rows ++ [row])
       ), nil}
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  defp perform(
         "assessment_rubric_change",
         %{"action" => "remove_row", "index" => index} = attrs,
         state,
         _opts
       ) do
    with :ok <- shape(attrs, ~w(action index)),
         true <- state["stage"] == "rubric",
         true <- is_binary(index),
         {index, ""} <- Integer.parse(index),
         rows = state["rubric_draft"]["obligations"],
         true <- index >= 0 and index < length(rows),
         true <- Enum.at(rows, index)["kind"] != "goal_acceptance",
         remaining = List.delete_at(rows, index),
         :ok <- AssessmentValidation.mapping(remaining, state["context"]["required_claim_refs"]) do
      {:ok,
       put_draft(state, "rubric_draft", Map.put(state["rubric_draft"], "obligations", remaining)),
       nil}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_input}
    end
  end

  defp perform("assessment_rubric_change", %{"action" => "successor"} = attrs, state, _opts) do
    with :ok <- shape(attrs, ~w(action rubric_id expected_rubric_hash)),
         {:ok, rubric} <- Assessments.get_rubric(attrs["rubric_id"]),
         true <- rubric["revision_hash"] == attrs["expected_rubric_hash"],
         false <- rubric["superseded"] do
      prepare_successor(rubric, state)
    else
      {:error, _} = error -> error
      _ -> {:error, :stale_rubric}
    end
  end

  defp perform("assessment_rubric_freeze", attrs, state, opts) do
    with {:ok, captured, _} <- capture_rubric(attrs, state) do
      case Assessments.freeze_rubric(captured["rubric_draft"], opts) do
        {:ok, rubric} -> {:ok, frozen(captured, rubric, []), "company-assessment-frozen"}
        {:error, reason} -> {:error, reason, captured}
      end
    end
  end

  defp perform("assessment_attempt_start", attrs, state, opts) do
    with :ok <- shape(attrs, ~w(rubric_id expected_rubric_hash)),
         {:ok, rubric} <- Assessments.get_rubric(attrs["rubric_id"]),
         true <- rubric["revision_hash"] == attrs["expected_rubric_hash"],
         true <-
           rubric["applicability"]["status"] != "restored_historical" and not rubric["superseded"],
         {:ok, attempt} <- Assessments.new_attempt(rubric["id"], rubric["revision_hash"], opts),
         {:ok, history} <- Assessments.list_assessments(rubric["id"]) do
      next =
        frozen(state, rubric, history)
        |> Map.put("stage", "results")
        |> Map.put("attempt", attempt)
        |> Map.put("result_draft", %{
          "task_status" => "",
          "critical_status" => "",
          "judgment" => "",
          "results" =>
            Enum.map(
              rubric["payload"]["obligations"],
              &%{"obligation_id" => &1["id"], "status" => "", "observation" => ""}
            )
        })

      {:ok, next, "company-assessment-results"}
    else
      {:error, _} = error -> error
      _ -> {:error, :stale_rubric}
    end
  end

  defp perform("assessment_result_change", attrs, state, _opts), do: capture_results(attrs, state)

  defp perform("assessment_record", attrs, state, opts) do
    with {:ok, captured, _} <- capture_results(attrs, state) do
      case Assessments.record_assessment(captured["result_draft"], opts) do
        {:ok, receipt} ->
          with {:ok, rubric} <- Assessments.get_rubric(receipt["rubric_id"]),
               {:ok, history} <- Assessments.list_assessments(rubric["id"]) do
            next =
              frozen(captured, rubric, history)
              |> Map.put("receipt", receipt)
              |> Map.put("attempt", captured["attempt"])
              |> Map.put("result_draft", captured["result_draft"])

            {:ok, next, "company-assessment-receipt"}
          end

        {:error, reason} ->
          {:error, reason, captured}
      end
    end
  end

  defp perform("assessment_history_open", %{"assessment_id" => id} = attrs, state, _opts) do
    with :ok <- shape(attrs, ["assessment_id"]),
         {:ok, receipt} <- Assessments.get_assessment(id),
         {:ok, rubric} <- Assessments.get_rubric(receipt["rubric_id"]),
         {:ok, history} <- Assessments.list_assessments(rubric["id"]) do
      {:ok,
       frozen(Map.put(state, "context", nil), rubric, history) |> Map.put("receipt", receipt),
       "company-assessment-receipt"}
    end
  end

  defp perform("assessment_history_open", %{"rubric_id" => id} = attrs, state, _opts) do
    with :ok <- shape(attrs, ["rubric_id"]),
         {:ok, rubric} <- Assessments.get_rubric(id),
         {:ok, history} <- Assessments.list_assessments(id) do
      {:ok, frozen(Map.put(state, "context", nil), rubric, history), "company-assessment-frozen"}
    end
  end

  defp perform("assessment_discard", %{"stage" => stage} = attrs, state, _opts) do
    with :ok <- shape(attrs, ["stage"]),
         true <- stage == state["stage"] and stage in ~w(rubric results) do
      next =
        if stage == "results",
          do: frozen(state, state["frozen_rubric"], state["history"]),
          else: empty()

      {:ok, next, "company-assessment-start"}
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  defp perform(_, _, _, _), do: {:error, :invalid_input}

  defp prepare_successor(rubric, state) do
    pins = rubric_binding(rubric)

    case Assessments.context(Map.merge(pins, goal_pins(rubric["payload"]["goal"]))) do
      {:ok, context} ->
        draft =
          rubric["payload"]
          |> Map.take(~w(task obligations))
          |> Map.merge(pins)
          |> Map.merge(goal_pins(rubric["payload"]["goal"]))
          |> Map.merge(%{
            "supersedes_id" => rubric["id"],
            "expected_predecessor_hash" => rubric["revision_hash"]
          })

        next =
          empty()
          |> Map.put("stage", "rubric")
          |> Map.put("context", context)
          |> Map.put("history", state["history"])
          |> Map.put("rubric_draft", draft)

        {:ok, next, "company-assessment-task"}

      {:error, reason}
      when reason in [
             :privacy_operation_incomplete,
             :privacy_state_unavailable,
             :assessment_storage_failed
           ] ->
        {:error, reason}

      {:error, _} ->
        next =
          empty()
          |> Map.put("predecessor", Map.take(rubric, ~w(id revision_hash)))
          |> Map.put("notice", successor_notice())

        {:ok, next, "company-assessment-start"}
    end
  end

  defp successor_draft(draft, nil), do: draft

  defp successor_draft(draft, predecessor) do
    draft
    |> Map.put("supersedes_id", predecessor["id"])
    |> Map.put("expected_predecessor_hash", predecessor["revision_hash"])
    |> Map.update!("obligations", fn rows ->
      Enum.map(rows, &Map.put(&1, "id", "obligation-" <> random_id()))
    end)
  end

  defp successor_notice,
    do:
      "Successor selected. Choose an eligible current built package using its Assess representative task button, then choose a goal and review the new rubric. Previous results do not carry forward."

  defp refresh_rubric(nil), do: {:ok, nil}
  defp refresh_rubric(rubric), do: Assessments.get_rubric(rubric["id"])
  defp refresh_receipt(nil), do: {:ok, nil}
  defp refresh_receipt(receipt), do: Assessments.get_assessment(receipt["id"])
  defp refresh_history(nil), do: {:ok, []}
  defp refresh_history(rubric), do: Assessments.list_assessments(rubric["id"])
  defp refresh_context(nil), do: {:ok, nil}

  defp refresh_context(context) do
    pins = context_binding(%{"context" => context})

    pins =
      if context["selected_goal"],
        do: Map.merge(pins, goal_pins(context["selected_goal"])),
        else: pins

    case Assessments.context(pins) do
      {:ok, current} ->
        {:ok, current}

      {:error, reason}
      when reason in [
             :not_found,
             :privacy_operation_incomplete,
             :privacy_state_unavailable,
             :invalid_record_hash,
             :assessment_storage_failed
           ] ->
        {:error, reason}

      {:error, reason} ->
        {:ok,
         Map.put(context, "applicability", %{
           "status" => "stale",
           "reason" => Atom.to_string(reason)
         })}
    end
  end

  defp capture_rubric(%{"rubric" => attrs} = payload, state) do
    with :ok <- shape(payload, ["rubric"]),
         true <- state["stage"] == "rubric" and is_map(state["context"]),
         :ok <- shape(attrs, @freeze, ~w(supersedes_id expected_predecessor_hash)),
         true <-
           Map.take(
             attrs,
             @binding ++ ~w(goal_id goal_content_hash supersedes_id expected_predecessor_hash)
           ) ==
             Map.take(
               state["rubric_draft"],
               @binding ++ ~w(goal_id goal_content_hash supersedes_id expected_predecessor_hash)
             ),
         true <- text?(attrs["task"]),
         {:ok, rows} <- indexed(attrs["obligations"]),
         {:ok, rows} <- collect(rows, &parse_obligation/1) do
      {:ok, put_draft(state, "rubric_draft", Map.put(attrs, "obligations", rows)), nil}
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  defp capture_rubric(_, _), do: {:error, :invalid_input}

  defp capture_results(%{"assessment" => attrs} = payload, state) do
    with :ok <- shape(payload, ["assessment"]),
         :ok <- shape(attrs, @record),
         true <- state["stage"] in ~w(results receipt) and is_map(state["attempt"]),
         rubric = state["frozen_rubric"],
         attempt = state["attempt"],
         true <-
           Map.take(attrs, ~w(rubric_id expected_rubric_hash attempt_id attempt_token)) ==
             %{
               "rubric_id" => rubric["id"],
               "expected_rubric_hash" => rubric["revision_hash"],
               "attempt_id" => attempt["attempt_id"],
               "attempt_token" => attempt["attempt_token"]
             },
         true <- Enum.all?(~w(task_status critical_status judgment), &text?(attrs[&1])),
         {:ok, rows} <- indexed(attrs["results"]),
         {:ok, rows} <- collect(rows, &parse_result/1) do
      {:ok, put_draft(state, "result_draft", Map.put(attrs, "results", rows)), nil}
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  defp capture_results(_, _), do: {:error, :invalid_input}

  defp parse_obligation(row) do
    with :ok <- shape(row, ~w(id kind text mandatory), ["claim_refs"]),
         true <- Enum.all?(~w(id kind text), &text?(row[&1])),
         true <- row["mandatory"] == "true",
         refs = Map.get(row, "claim_refs", []),
         true <- is_list(refs) and length(refs) <= 500,
         {:ok, refs} <-
           collect(refs, fn ref ->
             with {:ok, {id, hash}} <- pair(ref),
                  do: {:ok, %{"id" => id, "revision_hash" => hash}}
           end) do
      {:ok, row |> Map.put("mandatory", true) |> Map.put("claim_refs", refs)}
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  defp parse_result(row) do
    with :ok <- shape(row, ~w(obligation_id status observation)),
         true <- Enum.all?(~w(obligation_id status observation), &text?(row[&1])) do
      {:ok, row}
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  defp indexed(rows) when is_map(rows) and map_size(rows) in 1..20 do
    keys = Enum.map(0..(map_size(rows) - 1), &Integer.to_string/1)

    if Enum.sort(Map.keys(rows)) == Enum.sort(keys),
      do: {:ok, Enum.map(keys, &rows[&1])},
      else: {:error, :invalid_input}
  end

  defp indexed(_), do: {:error, :invalid_input}

  defp suggested(context) do
    goal = context["selected_goal"]

    guidance =
      if length(context["recommendations"]) <= 19 do
        Enum.map(context["recommendations"], fn claim ->
          obligation("guidance-" <> random_id(), "approved_analysis_guidance", claim["text"], [
            Map.take(claim, ~w(id revision_hash))
          ])
        end)
      else
        [
          obligation(
            "guidance-" <> random_id(),
            "approved_analysis_guidance",
            "Apply the selected approved guidance listed above; review and edit this obligation before freezing.",
            context["required_claim_refs"]
          )
        ]
      end

    rows =
      [obligation("goal-acceptance", "goal_acceptance", goal["acceptance"], [])] ++
        guidance

    context_binding(%{"context" => context})
    |> Map.merge(goal_pins(goal))
    |> Map.merge(%{"task" => "", "obligations" => rows})
  end

  defp frozen(state, rubric, history) do
    empty()
    |> Map.put("stage", "receipt")
    |> Map.put("context", state["context"])
    |> Map.put("frozen_rubric", rubric)
    |> Map.put("history", history)
  end

  defp context_binding(state) do
    pins = state["context"]["binding"]

    %{
      "plan_id" => pins["plan_id"],
      "expected_plan_revision_hash" => pins["plan_revision_hash"],
      "artifact_digest" => pins["artifact_digest"]
    }
  end

  defp rubric_binding(rubric) do
    pins = rubric["payload"]["binding"]

    %{
      "plan_id" => pins["plan_id"],
      "expected_plan_revision_hash" => pins["plan_revision_hash"],
      "artifact_digest" => pins["artifact_digest"]
    }
  end

  defp goal_pins(goal),
    do: %{"goal_id" => goal["id"], "goal_content_hash" => goal["content_hash"]}

  defp obligation(id, kind, text, refs),
    do: %{"id" => id, "kind" => kind, "text" => text, "mandatory" => true, "claim_refs" => refs}

  defp random_id, do: Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  defp put_draft(state, key, draft),
    do:
      state
      |> Map.put(key, draft)
      |> Map.put("dirty", true)
      |> Map.put("notice", nil)
      |> Map.delete("uncaptured_input")

  defp shape(attrs, required, optional \\ []),
    do: AssessmentValidation.shape(attrs, required, optional)

  # Retain oversize drafts for editing; domain validation keeps the 4,000-byte
  # persisted field bound. The complete transport envelope is capped above.
  defp text?(value), do: AssessmentValidation.string?(value) and byte_size(value) <= 262_144

  defp pair(value) when is_binary(value) do
    case String.split(value, ":") do
      [id, hash] ->
        if AssessmentValidation.uuid?(id) and AssessmentValidation.digest?(hash),
          do: {:ok, {id, hash}},
          else: {:error, :invalid_input}

      _ ->
        {:error, :invalid_input}
    end
  end

  defp pair(_), do: {:error, :invalid_input}

  defp collect(values, fun) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case fun.(value) do
        {:ok, item} -> {:cont, {:ok, acc ++ [item]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp valid_target?(nil), do: true

  defp valid_target?(target),
    do: is_list(target) and length(target) <= 8 and Enum.all?(target, &text?/1)

  defp unused(attrs) when is_map(attrs) do
    attrs
    |> Enum.reject(fn {key, value} ->
      String.starts_with?(key, "_unused_") and
        (value == "" or (is_list(value) and Enum.all?(value, &(&1 == ""))))
    end)
    |> Map.new(fn {key, value} -> {key, unused(value)} end)
  end

  defp unused(attrs) when is_list(attrs), do: Enum.map(attrs, &unused/1)
  defp unused(value), do: value
end
