defmodule HarnessForge.Company.ReadinessProjection do
  @moduledoc "Pure, non-authoritative projection of scoped server observations."
  @facts ~w(capture understanding review candidate evaluation release)
  @statuses ~w(unknown not_started running needs_input complete_for_selected_scope blocked cancelled stale)
  @scope_keys ~w(workspace_id profile_id profile_hash project_id project_hash goal_id goal_hash corpus_id semantic_generation authorization_generation)
  @corpus ~w(workspace_id corpus_id semantic_generation authorization_generation)
  @plan ~w(workspace_id project_id project_hash plan_id plan_revision_hash)
  @declaration ~w(declaration_id declaration_revision declaration_digest)
  @pins @scope_keys ++
          @declaration ++
          ~w(capture_run_id capture_revision run_id run_digest claim_id claim_revision_hash plan_id plan_revision_hash artifact_digest evaluation_id release_receipt_id)
  @kinds ~w(unknown current_content current_session historical_reconstruction diagnostic_replay static protected prospective actual_release)
  @reasons ~w(not_observed backing_record_unavailable scope_selection_required scope_binding_unavailable stale_generation stale_declaration superseded_revision scope_mismatch invalid_metadata missing_required_pins capture_verified capture_incomplete capture_running capture_cancelled declared_scope_verified required_scope_incomplete declared_scope_unknown undeclared_members analysis_running analysis_proposed analysis_abstained analysis_failed analysis_unavailable exact_review_required exact_review_verified artifact_verified artifact_binding_unavailable qualification_missing evaluation_not_selected evaluation_recorded release_not_observed release_verified optional_source_unavailable graph_unavailable fts_available)
  @complete_reasons %{
    "capture" => "capture_verified",
    "understanding" => "analysis_proposed",
    "review" => "exact_review_verified",
    "candidate" => "artifact_verified",
    "evaluation" => "evaluation_recorded",
    "release" => "release_verified"
  }
  @required %{
    "capture" => @corpus ++ ~w(capture_run_id capture_revision),
    "understanding" =>
      @corpus ++
        ~w(project_id project_hash goal_id goal_hash run_id run_digest claim_id claim_revision_hash),
    "review" => @plan ++ ~w(claim_id claim_revision_hash),
    "candidate" => @plan ++ ~w(artifact_digest),
    "evaluation" => @plan ++ ~w(artifact_digest evaluation_id),
    "release" => @plan ++ ~w(artifact_digest evaluation_id release_receipt_id)
  }

  @doc "Projects bounded metadata only; never reads records or grants an action."
  @spec project(term()) :: map()
  def project(input) when is_map(input) do
    raw_scope = Map.get(input, "scope", %{})
    {scope, valid_scope?} = bounded_pins(raw_scope, @scope_keys)
    observations = Map.get(input, "facts", %{})

    facts =
      Map.new(@facts, fn name ->
        raw = if is_map(observations), do: Map.get(observations, name), else: nil
        fact = project_fact(name, raw, scope, valid_scope?)
        {name, fact}
      end)

    %{
      "version" => "company-readiness.v1",
      "scope" => scope,
      "observed_at" => timestamp(input["observed_at"]),
      "facts" => facts,
      "capabilities" => capabilities(input["capabilities"]),
      "omissions" => omissions(input["omissions"], facts["capture"]),
      "blockers" => blockers(facts),
      "next_action" => nil
    }
  end

  def project(_), do: project(%{})

  defp project_fact(_name, _raw, _scope, false), do: empty("invalid_metadata")

  defp project_fact(_name, _raw, scope, _) when not is_map_key(scope, "workspace_id"),
    do: empty("scope_selection_required")

  defp project_fact(_name, nil, _scope, _), do: empty("not_observed")

  defp project_fact(name, raw, scope, _) when is_map(raw) do
    {pins, valid_pins?} = bounded_pins(Map.get(raw, "pins", %{}), @pins)
    refs = references(Map.get(raw, "references", []))
    status = raw["status"]
    reason = raw["reason_code"]
    kind = Map.get(raw, "evidence_kind", "unknown")

    cond do
      !valid_pins? or refs == :error or status not in @statuses or reason not in @reasons or
          kind not in @kinds ->
        empty("invalid_metadata")

      mismatch = mismatch(scope, pins) ->
        %{
          "status" => "stale",
          "reason_code" => mismatch,
          "pins" => pins,
          "references" => [],
          "evidence_kind" => kind
        }

      status == "complete_for_selected_scope" ->
        complete(name, reason, kind, pins, refs)

      true ->
        %{
          "status" => status,
          "reason_code" => reason,
          "pins" => pins,
          "references" => refs,
          "evidence_kind" => kind
        }
    end
  end

  defp project_fact(_, _, _, _), do: empty("invalid_metadata")

  defp complete(name, reason, kind, pins, refs) do
    declared_capture = name == "capture" and reason == "declared_scope_verified"
    required = if declared_capture, do: @corpus ++ @declaration, else: @required[name]

    cond do
      !Enum.all?(required, &Map.has_key?(pins, &1)) ->
        empty("missing_required_pins")

      kind == "unknown" or (reason != @complete_reasons[name] and not declared_capture) ->
        empty("invalid_metadata")

      name == "release" and kind != "actual_release" ->
        empty("qualification_missing")

      !completion_refs?(name, refs, pins) ->
        empty("scope_binding_unavailable")

      true ->
        %{
          "status" => "complete_for_selected_scope",
          "reason_code" => reason,
          "pins" => pins,
          "references" => refs,
          "evidence_kind" => kind
        }
    end
  end

  defp completion_refs?(name, refs, pins) do
    kinds =
      case name do
        "capture" ->
          if(Map.has_key?(pins, "declaration_id"), do: ~w(declaration), else: ~w(capture))

        "understanding" ->
          ~w(retrieval claim)

        "review" ->
          ~w(claim plan)

        "candidate" ->
          ~w(plan artifact)

        "evaluation" ->
          ~w(plan artifact evaluation)

        "release" ->
          ~w(plan artifact evaluation release)

        _ ->
          []
      end

    Enum.all?(kinds, fn kind ->
      {id, digest} = reference_pin(kind, pins)

      Enum.any?(
        refs,
        &(&1["kind"] == kind and &1["id"] == id and &1["digest"] == digest and
            (kind != "capture" or &1["revision"] == pins["capture_revision"]) and
            (kind != "declaration" or &1["revision"] == pins["declaration_revision"]))
      )
    end)
  end

  defp reference_pin("capture", pins), do: {pins["capture_run_id"], nil}

  defp reference_pin("declaration", pins),
    do: {pins["declaration_id"], pins["declaration_digest"]}

  defp reference_pin("retrieval", pins), do: {pins["run_id"], pins["run_digest"]}

  defp reference_pin("claim", pins), do: {pins["claim_id"], pins["claim_revision_hash"]}
  defp reference_pin("plan", pins), do: {pins["plan_id"], pins["plan_revision_hash"]}
  defp reference_pin("artifact", pins), do: {pins["artifact_digest"], pins["artifact_digest"]}
  defp reference_pin("evaluation", pins), do: {pins["evaluation_id"], nil}
  defp reference_pin("release", pins), do: {pins["release_receipt_id"], nil}

  defp mismatch(scope, pins) do
    Enum.find_value(@scope_keys, fn key ->
      if Map.has_key?(scope, key) and Map.has_key?(pins, key) and scope[key] != pins[key],
        do:
          if(key in ~w(semantic_generation authorization_generation),
            do: "stale_generation",
            else: "scope_mismatch"
          )
    end)
  end

  defp bounded_pins(value, keys) when is_map(value) do
    selected = Map.take(value, keys) |> Map.reject(fn {_key, value} -> is_nil(value) end)

    {selected, Enum.all?(selected, fn {key, value} -> pin?(key, value) end)}
    |> then(fn {selected, valid?} -> {if(valid?, do: selected, else: %{}), valid?} end)
  end

  defp bounded_pins(_, _), do: {%{}, false}

  defp pin?(key, value)
       when key in ~w(semantic_generation authorization_generation capture_revision declaration_revision),
       do: is_integer(value) and scalar?(value)

  defp pin?(_, value), do: is_binary(value) and scalar?(value)

  defp scalar?(value) when is_integer(value), do: value >= 0 and value <= 9_007_199_254_740_991

  defp scalar?(value) when is_binary(value),
    do:
      byte_size(value) in 1..256 and String.valid?(value) and
        Regex.match?(~r/\A[A-Za-z0-9_.:-]+\z/, value)

  defp scalar?(_), do: false

  defp references(refs) when is_list(refs) and length(refs) <= 8 do
    if Enum.all?(refs, &valid_reference?/1),
      do: Enum.map(refs, &Map.take(&1, ~w(kind id digest revision destination_code))),
      else: :error
  end

  defp references(_), do: :error

  defp valid_reference?(ref) when is_map(ref) do
    ref["kind"] in ~w(capture retrieval claim plan artifact evaluation release declaration) and
      ref["destination_code"] in ~w(corpus company packages) and scalar?(ref["id"]) and
      (is_nil(ref["digest"]) or scalar?(ref["digest"])) and
      (is_nil(ref["revision"]) or scalar?(ref["revision"]))
  end

  defp valid_reference?(_), do: false

  defp capabilities(raw) do
    Map.new(~w(fts graph), fn key ->
      value = if is_map(raw), do: raw[key], else: nil

      fact =
        if is_map(value) and value["status"] in ~w(available unavailable unknown) and
             value["reason_code"] in @reasons,
           do: Map.take(value, ~w(status reason_code)),
           else: %{"status" => "unknown", "reason_code" => "not_observed"}

      {key, fact}
    end)
  end

  defp omissions(raw, capture) when is_list(raw) and length(raw) <= 32 do
    pins = capture["pins"]

    raw
    |> Enum.filter(fn item ->
      is_map(item) and item["requirement"] == "optional" and
        item["reason_code"] == "optional_source_unavailable" and
        scalar?(item["connector_id"]) and scalar?(item["scope_id"]) and
        capture["status"] != "stale" and
        Enum.all?(@declaration, &(not is_nil(pins[&1]) and item[&1] == pins[&1])) and
        is_binary(item["capture_run_id"]) and scalar?(item["capture_run_id"]) and
        is_integer(item["capture_revision"]) and item["capture_revision"] > 0
    end)
    |> Enum.map(fn item ->
      result =
        Map.take(
          item,
          @declaration ++
            ~w(connector_id scope_id requirement reason_code capture_run_id capture_revision)
        )

      case item["connector_name"] do
        name when is_binary(name) and byte_size(name) <= 800 ->
          if String.valid?(name),
            do: Map.put(result, "connector_name", String.slice(name, 0, 200)),
            else: result

        _ ->
          result
      end
    end)
  end

  defp omissions(_, _), do: []

  defp blockers(facts) do
    Enum.flat_map(@facts, fn name ->
      fact = facts[name]

      if fact["status"] in ~w(blocked cancelled stale needs_input),
        do: [Map.merge(Map.take(fact, ~w(status reason_code)), %{"fact" => name})],
        else: []
    end)
  end

  defp timestamp(value) when is_binary(value) and byte_size(value) <= 40 do
    case DateTime.from_iso8601(value) do
      {:ok, time, _} -> DateTime.to_iso8601(time)
      _ -> nil
    end
  end

  defp timestamp(_), do: nil

  defp empty(reason),
    do: %{
      "status" => "unknown",
      "reason_code" => reason,
      "pins" => %{},
      "references" => [],
      "evidence_kind" => "unknown"
    }
end
