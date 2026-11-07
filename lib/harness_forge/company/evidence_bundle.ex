defmodule HarnessForge.Company.EvidenceBundle do
  @moduledoc """
  Pure current-FTS inspection request and EvidenceBundle projections.

  This module never searches, hydrates passages or grants authority. Retrieval
  supplies the checked immutable snapshot, current scope and operator binding.
  Inspection describes that existing operation, not a positive purpose grant.
  """
  alias HarnessForge.Contracts
  alias HarnessForge.Evidence.Corpora

  @required ~w(corpus_id project_id goal_id goal_hash expected_generation question)
  @defaults %{
    "version" => "RetrievalRequest.v1",
    "mode" => "fts",
    "time_mode" => "current",
    "purpose" => "inspection"
  }
  @identity ~w(passage_id source_id revision_id body_hash start_byte end_byte snippet_hash parent_start_byte parent_end_byte parent_hash)

  @spec normalize_request(term()) :: {:ok, map()} | {:error, atom()}
  def normalize_request(attrs) do
    with :ok <- Corpora.keys(attrs, @required, Map.keys(@defaults) ++ ["declaration_ref"]),
         true <- valid_fields?(attrs),
         request = Map.merge(@defaults, attrs),
         :ok <-
           supported(request, "version", "RetrievalRequest.v1", :unsupported_contract_version),
         :ok <- supported(request, "mode", "fts", :unsupported_mode),
         :ok <- supported(request, "time_mode", "current", :unsupported_time_mode),
         :ok <- supported(request, "purpose", "inspection", :unsupported_purpose) do
      {:ok, request}
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  defp valid_fields?(attrs) do
    Enum.all?(~w(corpus_id project_id goal_id), &Corpora.uuid?(attrs[&1])) and
      Corpora.digest?(attrs["goal_hash"]) and is_integer(attrs["expected_generation"]) and
      attrs["expected_generation"] >= 0 and Corpora.text?(attrs["question"], 1024) and
      String.length(attrs["question"]) <= 256 and
      Enum.all?(Map.keys(@defaults), fn key ->
        not Map.has_key?(attrs, key) or is_binary(attrs[key])
      end) and valid_declaration?(attrs)
  end

  defp valid_declaration?(attrs) do
    case Map.fetch(attrs, "declaration_ref") do
      :error ->
        true

      {:ok, ref} ->
        Corpora.keys(ref, ~w(id digest)) == :ok and Corpora.uuid?(ref["id"]) and
          Corpora.digest?(ref["digest"])
    end
  end

  defp supported(request, key, value, reason),
    do: if(request[key] == value, do: :ok, else: {:error, reason})

  @doc "Readiness is a snapshot gate, never truth confidence or approval."
  @spec status(term(), non_neg_integer()) :: String.t()
  def status("ready", _selected_count), do: "ready"

  def status("abstained", selected_count) when is_integer(selected_count) and selected_count > 0,
    do: "partial"

  def status(_, _), do: "abstained"

  @doc false
  @spec binding(map(), map()) :: map()
  def binding(scope, %{"client_binding" => client} = evidence) do
    %{
      "version" => "ClientEvidenceBinding.v1",
      "request_digest" => evidence["request_digest"],
      "caller_digest" => evidence["caller_digest"],
      "scope" => scope,
      "time_mode" => "current",
      "purpose" => "inspection",
      "admission_basis" => "owner_issued_synthetic_local_inspection",
      "positive_purpose_policy" => "unknown",
      "client_disclosure" => client
    }
  end

  def binding(scope, evidence) do
    %{
      "version" => "EvidenceBinding.v1",
      "request_digest" => evidence["request_digest"],
      "caller_digest" => evidence["caller_digest"],
      "scope" => scope,
      "time_mode" => "current",
      "purpose" => "inspection",
      "admission_basis" => "legacy_operator_current_inspection",
      "positive_purpose_policy" => "unknown"
    }
  end

  @doc false
  @spec citation(map(), String.t()) :: map()
  def citation(passage, workspace_id) do
    identity = Map.take(passage, @identity)

    digest =
      Contracts.digest(
        Map.merge(identity, %{
          "version" => "EvidenceCitation.v1",
          "workspace_id" => workspace_id
        })
      )

    Map.put(identity, "citation_digest", digest)
  end

  @doc false
  @spec project(map(), map(), map()) :: map()
  def project(run, checked_scope, checked_binding) do
    selected = run.envelope["passages"]

    core = %{
      "version" => "EvidenceBundle.v1",
      "request_digest" => checked_binding["request_digest"],
      "binding_digest" => Contracts.digest(checked_binding),
      "snapshot_digest" => run.digest,
      "scope" => checked_scope,
      "time_mode" => "current",
      "purpose" => "inspection",
      "admission_basis" => checked_binding["admission_basis"],
      "positive_purpose_policy" => "unknown",
      "generations" => %{
        "semantic" => run.semantic_generation,
        "authorization" => run.authorization_generation,
        "index" => nil,
        "purpose_policy" => nil
      },
      "index_versions" => run.envelope["versions"],
      "status" => status(run.state, length(selected)),
      "analysis_ready" => run.state == "ready",
      "coverage" => run.coverage,
      "history" => %{
        "status" => "unknown",
        "acquisition_by_kind" => nil,
        "exact_version_basis" => nil,
        "unavailable_ranges" => nil,
        "historical_eligibility" => "unavailable",
        "reason" => "historical_provider_unavailable"
      },
      "unavailable_capabilities" => [
        "graph",
        "historical_materialization",
        "positive_purpose_policy"
      ],
      "reasons" => reasons(run.coverage, selected),
      "citations" => Enum.map(selected, &citation(&1, checked_scope["workspace_id"]))
    }

    core =
      if checked_binding["client_disclosure"],
        do: Map.put(core, "client_disclosure", checked_binding["client_disclosure"]),
        else: core

    Map.merge(core, %{
      "bundle_digest" => Contracts.digest(core),
      "legacy" => %{"run_id" => run.id, "digest" => run.digest, "state" => run.state}
    })
  end

  defp reasons(coverage, selected) do
    capture = fact(coverage, "capture", "scan_complete")
    expected = fact(coverage, "index", "expected")
    indexed = fact(coverage, "index", "indexed")
    omitted = fact(coverage, "search", "omitted")
    parent = fact(coverage, "search", "parent_incomplete")
    index_known = count?(expected) and count?(indexed)

    unknown =
      not is_boolean(capture) or not index_known or not count?(omitted) or not count?(parent)

    ["historical_provider_unavailable", "positive_purpose_policy_unknown"]
    |> append_reason(capture === false, "capture_incomplete")
    |> append_reason(index_known and expected != indexed, "index_incomplete")
    |> append_reason(selected == [], "selection_empty")
    |> append_reason(
      (count?(omitted) and omitted > 0) or
        fact(coverage, "search", "truncated") === true,
      "selection_truncated"
    )
    |> append_reason(count?(parent) and parent > 0, "parent_incomplete")
    |> append_reason(unknown, "coverage_unknown")
    |> Enum.map(&%{"code" => &1})
  end

  defp fact(coverage, section, key) when is_map(coverage) do
    case coverage[section] do
      value when is_map(value) -> value[key]
      _ -> nil
    end
  end

  defp fact(_, _, _), do: nil
  defp count?(value), do: is_integer(value) and value >= 0
  defp append_reason(reasons, true, code), do: reasons ++ [code]
  defp append_reason(reasons, false, _code), do: reasons
end
