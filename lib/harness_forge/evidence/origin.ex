defmodule HarnessForge.Evidence.Origin do
  @moduledoc "Pure origin dependency extraction, including examined but uncited company context."
  alias HarnessForge.{Contracts, Evidence.Store}
  alias HarnessForge.Models.CompanyAnalysis, as: Output

  @basis ~w(kind version project_id goal_id goal_content_hash context context_digest report guidance provider model config_fingerprint run_id request_id review_resolution)
  @guidance ~w(rule workflow check evaluation_criterion)

  @spec references(map()) :: {:ok, map()} | {:error, :invalid_claim_basis}
  def references(claim) when is_map(claim) and not is_map_key(claim, "basis"),
    do: references(Map.put(claim, "basis", nil))

  def references(%{"basis" => nil, "citations" => citations}) do
    if citation_records?(citations), do: result(citations, [], [], [], []), else: invalid()
  end

  def references(%{"basis" => %{"kind" => "goal"} = basis, "citations" => []}) do
    if Output.keys?(basis, ~w(kind version goal_id goal_content_hash)) and basis["version"] === 1 and
         Output.uuid?(basis["goal_id"]) and Output.digest?(basis["goal_content_hash"]),
       do: result([], [], [basis["goal_id"]], [], []),
       else: invalid()
  end

  def references(%{"basis" => %{"kind" => "company_analysis", "version" => 2}} = claim),
    do: HarnessForge.Evidence.OriginV2.references(claim)

  def references(%{"basis" => %{"kind" => "company_analysis"} = basis, "citations" => citations}) do
    if valid_basis?(basis) and citation_records?(citations) and
         length(Enum.uniq_by(citations, & &1["id"])) == length(citations) and
         report_records?(basis, citations) do
      refs = basis["context"]["sources"]

      {:ok, values} =
        result(
          citations,
          Enum.map(refs, & &1["source_id"]),
          [basis["goal_id"]],
          [basis["project_id"]],
          [basis["context"]["profile"]["id"]]
        )

      {:ok,
       Map.update!(
         values,
         "revision_ids",
         &Enum.sort(Enum.uniq(&1 ++ Enum.map(refs, fn ref -> ref["revision_id"] end)))
       )}
    else
      invalid()
    end
  end

  def references(_), do: invalid()

  @doc false
  def valid_basis?(%{"version" => 2} = basis),
    do: HarnessForge.Evidence.OriginV2.valid_basis?(basis)

  def valid_basis?(basis) do
    Output.keys?(basis, @basis) and basis["kind"] == "company_analysis" and basis["version"] === 1 and
      Output.uuid?(basis["project_id"]) and Output.uuid?(basis["goal_id"]) and
      Output.digest?(basis["goal_content_hash"]) and valid_context?(basis["context"]) and
      basis["context"]["project"]["id"] == basis["project_id"] and
      Output.digest?(basis["context_digest"]) and
      Contracts.digest(basis["context"]) == basis["context_digest"] and
      Output.valid_structure?(basis["report"]) and not is_nil(basis["report"]["recommendation"]) and
      byte_size(Contracts.canonical_json(basis["report"])) <= 32_768 and
      Output.keys?(basis["guidance"], @guidance) and
      Enum.all?(
        @guidance,
        &(Output.text?(basis["guidance"][&1]) and
            basis["guidance"][&1] == String.trim(basis["guidance"][&1]))
      ) and
      basis["provider"] in ~w(ollama openai openai_responses anthropic) and
      is_binary(basis["model"]) and
      Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._:\/-]{0,199}\z/, basis["model"]) and
      Output.digest?(basis["config_fingerprint"]) and Output.uuid?(basis["run_id"]) and
      Output.uuid?(basis["request_id"]) and
      (is_nil(basis["review_resolution"]) or Output.text?(basis["review_resolution"])) and
      Enum.all?(Output.citations(basis["report"]), fn citation ->
        Enum.any?(
          basis["context"]["sources"],
          &(&1["source_id"] == citation["source_id"] and
              &1["revision_id"] == citation["revision_id"])
        )
      end)
  end

  @doc false
  def valid_context?(context) do
    Output.keys?(context, ~w(profile project sources)) and pin?(context["profile"]) and
      pin?(context["project"]) and
      is_list(context["sources"]) and length(context["sources"]) in 2..4 and
      Enum.all?(context["sources"], &source_ref?/1) and
      context["sources"] == Enum.sort_by(context["sources"], & &1["source_id"]) and
      length(Enum.uniq_by(context["sources"], & &1["source_id"])) == length(context["sources"])
  end

  @doc false
  def source_ref?(ref),
    do:
      Output.keys?(ref, ~w(source_id revision_id body_hash)) and
        Output.uuid?(ref["source_id"]) and Output.uuid?(ref["revision_id"]) and
        Output.digest?(ref["body_hash"])

  @doc false
  def canonical(citations),
    do: Enum.sort_by(citations, &{&1["revision_id"], &1["start_byte"], &1["end_byte"], &1["id"]})

  @doc false
  def identity(citations),
    do:
      canonical(citations)
      |> Enum.map(&Map.take(&1, ~w(id revision_id start_byte end_byte snippet_hash)))

  defp report_records?(basis, citations) do
    expected =
      Output.citations(basis["report"])
      |> Enum.map(&Map.take(&1, ~w(revision_id start_byte end_byte snippet)))
      |> Enum.uniq()
      |> Enum.sort()

    actual =
      citations
      |> Enum.map(&Map.take(&1, ~w(revision_id start_byte end_byte snippet)))
      |> Enum.sort()

    expected == actual
  end

  defp citation_records?(citations) do
    is_list(citations) and length(citations) in 1..100 and
      Enum.all?(citations, fn citation ->
        is_map(citation) and Output.uuid?(citation["id"]) and
          Output.uuid?(citation["revision_id"]) and
          is_integer(citation["start_byte"]) and is_integer(citation["end_byte"]) and
          citation["start_byte"] >= 0 and citation["end_byte"] > citation["start_byte"] and
          is_binary(citation["snippet"]) and String.valid?(citation["snippet"]) and
          byte_size(citation["snippet"]) == citation["end_byte"] - citation["start_byte"] and
          Output.digest?(citation["snippet_hash"]) and
          Store.hash(citation["snippet"]) == citation["snippet_hash"]
      end)
  end

  defp pin?(pin),
    do:
      Output.keys?(pin, ~w(id content_hash)) and Output.uuid?(pin["id"]) and
        Output.digest?(pin["content_hash"])

  defp result(citations, sources, goals, projects, profiles),
    do:
      {:ok,
       %{
         "revision_ids" =>
           citations |> Enum.map(& &1["revision_id"]) |> Enum.uniq() |> Enum.sort(),
         "source_ids" => Enum.sort(Enum.uniq(sources)),
         "goal_ids" => Enum.sort(Enum.uniq(goals)),
         "project_ids" => Enum.sort(Enum.uniq(projects)),
         "profile_ids" => Enum.sort(Enum.uniq(profiles))
       }}

  defp invalid, do: {:error, :invalid_claim_basis}
end
