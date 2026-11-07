defmodule HarnessForge.Company.AssessmentValidation do
  @moduledoc false
  alias HarnessForge.{Contracts, Goals}
  alias HarnessForge.Evidence.Origin

  @binding ~w(plan_id expected_plan_revision_hash artifact_digest)
  @goal_pin ~w(goal_id goal_content_hash)
  @freeze @binding ++ @goal_pin ++ ~w(task obligations)
  @record ~w(rubric_id expected_rubric_hash attempt_id attempt_token task_status critical_status judgment results)
  @rubric_payload ~w(version origin_workspace_id binding goal task obligations required_claim_refs plan_snapshot claim_contexts)
  @assessment_payload ~w(version origin_workspace_id rubric_revision_hash operator task_status critical_status judgment results authority_at_record authority_reason)
  @authority_reasons ~w(stale_plan_revision superseded_plan plan_not_approved package_not_bound invalid_package goal_not_selected stale_goal analysis_recommendation_required stale_authority stale_rubric)

  def context(attrs) do
    with :ok <- shape(attrs, @binding, @goal_pin),
         true <- binding?(attrs),
         true <- paired?(attrs, "goal_id", "goal_content_hash"),
         true <-
           is_nil(attrs["goal_id"]) or
             (uuid?(attrs["goal_id"]) and digest?(attrs["goal_content_hash"])) do
      {:ok, attrs}
    else
      _ -> {:error, :invalid_input}
    end
  end

  def freeze(attrs) do
    with :ok <- shape(attrs, @freeze, ~w(supersedes_id expected_predecessor_hash)),
         true <-
           binding?(attrs) and uuid?(attrs["goal_id"]) and digest?(attrs["goal_content_hash"]),
         true <- paired?(attrs, "supersedes_id", "expected_predecessor_hash"),
         true <-
           is_nil(attrs["supersedes_id"]) or
             (uuid?(attrs["supersedes_id"]) and digest?(attrs["expected_predecessor_hash"])),
         :ok <- text(attrs["task"], true),
         {:ok, obligations} <- obligations(attrs["obligations"]) do
      {:ok, Map.put(attrs, "obligations", obligations)}
    else
      false -> {:error, :invalid_input}
      {:error, _} = error -> error
    end
  end

  def record(attrs) do
    with :ok <- shape(attrs, @record),
         true <-
           uuid?(attrs["rubric_id"]) and digest?(attrs["expected_rubric_hash"]) and
             uuid?(attrs["attempt_id"]),
         true <- string?(attrs["attempt_token"]) and byte_size(attrs["attempt_token"]) in 1..2048,
         true <- statuses?(attrs),
         {:ok, results} <- results(attrs["results"]) do
      {:ok, Map.put(attrs, "results", results)}
    else
      false -> {:error, :invalid_input}
      {:error, _} = error -> error
    end
  end

  def mapping(obligations, refs) do
    goal = Enum.filter(obligations, &(&1["kind"] == "goal_acceptance"))
    guidance = Enum.filter(obligations, &(&1["kind"] == "approved_analysis_guidance"))
    mapped = Enum.flat_map(guidance, & &1["claim_refs"])

    check(
      length(goal) == 1 and refs != [] and guidance != [] and
        Enum.all?(obligations, fn row ->
          case row["kind"] do
            "approved_analysis_guidance" ->
              row["claim_refs"] != [] and Enum.all?(row["claim_refs"], &(&1 in refs))

            _ ->
              row["claim_refs"] == []
          end
        end) and Enum.all?(refs, &(&1 in mapped)),
      :incomplete_obligation_mapping
    )
  end

  def stable_ids(obligations, previous) do
    old = Map.new(previous, &{&1["id"], &1})

    check(
      Enum.all?(obligations, &(not Map.has_key?(old, &1["id"]) or old[&1["id"]] == &1)),
      :invalid_input
    )
  end

  def result_accounting(results, obligations) do
    check(
      Enum.map(results, & &1["obligation_id"]) == Enum.map(obligations, & &1["id"]),
      :invalid_obligation_results
    )
  end

  def acceptance(%{"judgment" => "not_accepted"}), do: :ok

  def acceptance(attrs) do
    check(
      attrs["task_status"] == "completed" and attrs["critical_status"] == "none" and
        Enum.all?(
          attrs["results"],
          &(&1["status"] == "met" and String.trim(&1["observation"]) != "")
        ),
      :acceptance_requirements_unmet
    )
  end

  def canonical_size(object) do
    with true <- json?(object),
         bytes = Contracts.canonical_json(object),
         true <- byte_size(bytes) <= 131_072 do
      :ok
    else
      false -> {:error, :input_too_large}
    end
  end

  def rubric_payload?(payload) do
    exact?(payload, @rubric_payload) and payload["version"] === 1 and
      string?(payload["origin_workspace_id"]) and payload["origin_workspace_id"] != "" and
      exact?(payload["binding"], ~w(plan_id plan_revision_hash artifact_digest)) and
      uuid?(payload["binding"]["plan_id"]) and digest?(payload["binding"]["plan_revision_hash"]) and
      digest?(payload["binding"]["artifact_digest"]) and goal?(payload["goal"]) and
      text(payload["task"], true) == :ok and
      obligations(payload["obligations"]) == {:ok, payload["obligations"]} and
      sorted?(payload["obligations"], "id") and refs?(payload["required_claim_refs"]) and
      mapping(payload["obligations"], payload["required_claim_refs"]) == :ok and
      snapshot?(payload["plan_snapshot"]) and contexts?(payload["claim_contexts"]) and
      Enum.all?(payload["required_claim_refs"], fn ref ->
        ref in payload["plan_snapshot"]["claims"] and
          Enum.any?(payload["claim_contexts"], &(Map.take(&1, ~w(id revision_hash)) == ref))
      end) and
      Enum.any?(
        payload["plan_snapshot"]["goals"],
        &(Map.take(payload["goal"], ~w(id content_hash)) == &1)
      )
  end

  def assessment_payload?(payload) do
    exact?(payload, @assessment_payload) and payload["version"] === 1 and
      string?(payload["origin_workspace_id"]) and payload["origin_workspace_id"] != "" and
      digest?(payload["rubric_revision_hash"]) and payload["operator"] == "local-operator" and
      statuses?(payload) and match?({:ok, _}, results(payload["results"])) and
      sorted?(payload["results"], "obligation_id") and
      ((payload["authority_at_record"] == "current" and is_nil(payload["authority_reason"])) or
         (payload["authority_at_record"] == "stale" and
            payload["authority_reason"] in @authority_reasons)) and
      acceptance(payload) == :ok and
      (payload["judgment"] != "accepted" or payload["authority_at_record"] == "current")
  end

  def request(attrs), do: Map.delete(attrs, "attempt_token")

  def request_from_record(record) do
    record.payload
    |> Map.take(~w(task_status critical_status judgment results))
    |> Map.merge(%{
      "rubric_id" => record.rubric_id,
      "expected_rubric_hash" => record.payload["rubric_revision_hash"],
      "attempt_id" => record.attempt_id
    })
  end

  def shape(value, required, optional \\ []) do
    check(
      is_map(value) and not is_struct(value) and
        Enum.all?(required, &Map.has_key?(value, &1)) and
        Enum.all?(Map.keys(value), &(&1 in (required ++ optional))),
      :invalid_input
    )
  end

  def uuid?(value),
    do:
      string?(value) and byte_size(value) == 36 and
        Regex.match?(~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/, value)

  def digest?(value), do: hex?(value, 64)

  def hex?(value, size),
    do: string?(value) and byte_size(value) == size and Regex.match?(~r/\A[0-9a-f]+\z/, value)

  def string?(value),
    do: is_binary(value) and String.valid?(value) and not String.contains?(value, <<0>>)

  def json?(value, depth \\ 0)
  def json?(_, depth) when depth > 32, do: false

  def json?(value, depth) when is_map(value) and not is_struct(value),
    do: Enum.all?(value, fn {key, item} -> string?(key) and json?(item, depth + 1) end)

  def json?(value, depth) when is_list(value), do: Enum.all?(value, &json?(&1, depth + 1))
  def json?(value, _) when is_binary(value), do: string?(value)

  def json?(value, _) when is_integer(value),
    do: value in -9_007_199_254_740_991..9_007_199_254_740_991

  def json?(value, _), do: is_boolean(value) or is_nil(value)

  defp obligations(values) when is_list(values) and length(values) > 20,
    do: {:error, :input_too_large}

  defp obligations(values) when is_list(values) do
    with true <- length(values) in 1..20,
         :ok <- each(values, &obligation/1),
         true <- unique?(Enum.map(values, & &1["id"])) do
      {:ok,
       values
       |> Enum.map(
         &Map.update!(&1, "claim_refs", fn refs -> Enum.sort_by(refs, fn ref -> ref["id"] end) end)
       )
       |> Enum.sort_by(& &1["id"])}
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  defp obligations(_), do: {:error, :invalid_input}

  defp obligation(row) do
    with :ok <- shape(row, ~w(id kind text mandatory claim_refs)),
         true <-
           string?(row["id"]) and byte_size(row["id"]) <= 64 and
             Regex.match?(~r/\A[a-z][a-z0-9_-]{0,63}\z/, row["id"]),
         true <-
           row["kind"] in ~w(goal_acceptance approved_analysis_guidance owner_authored) and
             row["mandatory"] === true,
         true <- refs?(row["claim_refs"], false),
         :ok <- text(row["text"], true) do
      :ok
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  defp results(values) when is_list(values) and length(values) <= 20 do
    with :ok <- each(values, &result/1) do
      if unique?(Enum.map(values, & &1["obligation_id"])),
        do: {:ok, Enum.sort_by(values, & &1["obligation_id"])},
        else: {:error, :invalid_obligation_results}
    end
  end

  defp results(_), do: {:error, :invalid_input}

  defp result(row) do
    with :ok <- shape(row, ~w(obligation_id status observation)),
         true <-
           string?(row["obligation_id"]) and byte_size(row["obligation_id"]) <= 64 and
             Regex.match?(~r/\A[a-z][a-z0-9_-]{0,63}\z/, row["obligation_id"]),
         true <- row["status"] in ~w(met unmet unobserved),
         :ok <- text(row["observation"], false) do
      :ok
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  defp text(value, required) do
    cond do
      not string?(value) -> {:error, :invalid_input}
      byte_size(value) > 4000 or String.length(value) > 1000 -> {:error, :input_too_large}
      required and String.trim(value) == "" -> {:error, :invalid_input}
      true -> :ok
    end
  end

  defp binding?(attrs),
    do:
      uuid?(attrs["plan_id"]) and digest?(attrs["expected_plan_revision_hash"]) and
        digest?(attrs["artifact_digest"])

  defp paired?(attrs, left, right),
    do:
      (is_nil(attrs[left]) and is_nil(attrs[right])) or
        (not is_nil(attrs[left]) and not is_nil(attrs[right]))

  defp statuses?(attrs),
    do:
      attrs["task_status"] in ~w(completed interrupted) and
        attrs["critical_status"] in ~w(none present unobserved) and
        attrs["judgment"] in ~w(accepted not_accepted)

  defp exact?(value, keys), do: shape(value, keys) == :ok
  defp unique?(values), do: length(Enum.uniq(values)) == length(values)
  defp sorted?(values, key), do: values == Enum.sort_by(values, & &1[key])

  defp refs?(refs, sorted \\ true),
    do:
      is_list(refs) and length(refs) <= 500 and
        Enum.all?(
          refs,
          &(exact?(&1, ~w(id revision_hash)) and uuid?(&1["id"]) and digest?(&1["revision_hash"]))
        ) and
        unique?(Enum.map(refs, & &1["id"])) and (not sorted or sorted?(refs, "id"))

  defp goal?(goal),
    do:
      exact?(goal, ~w(id content_hash title owner acceptance)) and uuid?(goal["id"]) and
        digest?(goal["content_hash"]) and
        Enum.all?(
          ~w(title owner acceptance),
          &(string?(goal[&1]) and String.trim(goal[&1]) != "")
        ) and
        goal["content_hash"] == Goals.content_hash(goal)

  defp pin?(pin),
    do: exact?(pin, ~w(id content_hash)) and uuid?(pin["id"]) and digest?(pin["content_hash"])

  defp snapshot?(snapshot),
    do:
      exact?(snapshot, ~w(profile project repositories sources claims goals)) and
        pin?(snapshot["profile"]) and pin?(snapshot["project"]) and
        is_list(snapshot["repositories"]) and length(snapshot["repositories"]) <= 100 and
        Enum.all?(
          snapshot["repositories"],
          &(exact?(&1, ~w(id content_hash identity)) and pin?(Map.take(&1, ~w(id content_hash))) and
              string?(&1["identity"]))
        ) and
        is_list(snapshot["sources"]) and length(snapshot["sources"]) <= 2000 and
        Enum.all?(
          snapshot["sources"],
          &(exact?(&1, ~w(id revision_id body_hash)) and uuid?(&1["id"]) and
              uuid?(&1["revision_id"]) and digest?(&1["body_hash"]))
        ) and
        refs?(snapshot["claims"]) and is_list(snapshot["goals"]) and
        length(snapshot["goals"]) <= 100 and Enum.all?(snapshot["goals"], &pin?/1)

  defp contexts?(contexts),
    do:
      is_list(contexts) and length(contexts) in 1..500 and sorted?(contexts, "id") and
        unique?(Enum.map(contexts, & &1["id"])) and
        Enum.all?(contexts, fn row ->
          exact?(row, ~w(id revision_hash context_digest context)) and uuid?(row["id"]) and
            digest?(row["revision_hash"]) and
            digest?(row["context_digest"]) and json?(row["context"]) and
            Origin.valid_context?(row["context"]) and
            Contracts.digest(row["context"]) == row["context_digest"]
        end)

  defp each(values, fun),
    do:
      Enum.reduce_while(values, :ok, fn value, :ok ->
        case fun.(value) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)

  defp check(true, _), do: :ok
  defp check(false, reason), do: {:error, reason}
end
