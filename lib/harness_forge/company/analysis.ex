defmodule HarnessForge.Company.Analysis do
  @moduledoc "One explicitly scoped, model-proposed recommendation with immutable all-input provenance."
  alias HarnessForge.{Audit, Company, Contracts, Evidence, Goals, Models, Workspaces}
  alias HarnessForge.Company.Project
  alias HarnessForge.Evidence.{Connection, Goal, Origin, Source, Store}
  alias HarnessForge.Models.{CompanyAnalysis, Configuration}
  alias HarnessForge.Privacy.Purge
  @fields ~w(rule workflow check evaluation_criterion)
  @snapshot ~w(project_id goal_id goal_content_hash context context_digest)
  @input ~w(project_id goal_id goal_content_hash source_refs)

  def analyze_retrieval(id, digest, opts \\ []),
    do: HarnessForge.Company.AnalysisV2.analyze(id, digest, opts)

  @spec analyze(map(), keyword()) ::
          {:ok, map()}
          | {:error,
             atom() | {:invalid_company_analysis_output, CompanyAnalysis.validation_reason()}}
  def analyze(attrs, opts \\ []) do
    with :ok <- valid_input(attrs, opts),
         :ok <- Workspaces.ensure_writable(),
         {:ok, captured} <- capture(attrs),
         config = Configuration.get(),
         fingerprint = Configuration.fingerprint(config),
         prompt = prompt(captured),
         true <- byte_size(prompt) <= 49_152,
         run = Keyword.get(opts, :run_id, Ecto.UUID.generate()),
         request = Keyword.get(opts, :request_id, Ecto.UUID.generate()),
         {:ok, _} <- Models.reopen_run(run, %{"max_requests" => 1}),
         {:ok, response} <-
           Models.infer(
             %{
               "purpose" => "company_analysis",
               "run_id" => run,
               "request_id" => request,
               "prompt" => prompt,
               "source_ids" => Enum.map(captured.sources, & &1["id"]),
               "data_categories" => ~w(source_body company_context),
               "max_output_tokens" => 4096,
               "expected_config_fingerprint" => fingerprint,
               "company_analysis_context" => captured.snapshot
             },
             Keyword.take(opts, [:timeout])
           ),
         {:ok, report} <- CompanyAnalysis.validate_detailed(response["text"], captured.sources) do
      admit(captured.snapshot, config, fingerprint, response, report)
    else
      false -> {:error, :company_analysis_input_too_large}
      error -> error
    end
  end

  @spec revise(String.t(), String.t(), map()) :: {:ok, map()} | {:error, atom()}
  def revise(id, expected, attrs) do
    Purge.synchronize(fn ->
      Store.transaction(fn ->
        with :ok <- Workspaces.ensure_writable(),
             {:ok, claim} <- Evidence.get_claim(id),
             :ok <- check(claim["revision_hash"] == expected, :stale_revision),
             :ok <- check(not claim["superseded"], :already_superseded),
             :ok <-
               check(
                 match?(%{"kind" => "company_analysis"}, claim["basis"]),
                 :claim_origin_change
               ),
             {:ok, _} <- validate_origin(claim["basis"], claim["citations"]),
             {:ok, guidance, resolution} <- edited(attrs, claim["basis"]["review_resolution"]),
             basis =
               Map.merge(claim["basis"], %{
                 "guidance" => guidance,
                 "review_resolution" => resolution
               }) do
          Evidence.create_claim(%{
            "text" => render_guidance(guidance),
            "basis" => basis,
            "citations" => claim["citations"],
            "supersedes_id" => id
          })
        end
      end)
    end)
  end

  @doc "Validate continuing data authority without consulting provider availability or inference consent."
  @spec validate_context(map()) :: :ok | {:error, :stale_company_analysis_context}
  def validate_context(snapshot) do
    with true <- CompanyAnalysis.keys?(snapshot, @snapshot),
         true <- Origin.valid_context?(snapshot["context"]),
         true <-
           CompanyAnalysis.uuid?(snapshot["project_id"]) and
             CompanyAnalysis.uuid?(snapshot["goal_id"]),
         true <-
           CompanyAnalysis.digest?(snapshot["goal_content_hash"]) and
             CompanyAnalysis.digest?(snapshot["context_digest"]),
         attrs =
           snapshot
           |> Map.take(~w(project_id goal_id goal_content_hash))
           |> Map.put("source_refs", snapshot["context"]["sources"]),
         {:ok, current} <- capture(attrs),
         true <- current.snapshot == snapshot do
      :ok
    else
      _ -> {:error, :stale_company_analysis_context}
    end
  end

  @spec validate_origin(map(), list()) :: {:ok, list()} | {:error, atom()}
  def validate_origin(%{"version" => 2} = basis, citations),
    do: HarnessForge.Evidence.OriginV2.validate_origin(basis, citations)

  def validate_origin(basis, citations) do
    with {:ok, _} <- Origin.references(%{"basis" => basis, "citations" => citations}),
         true <- is_map(basis) and basis["kind"] == "company_analysis",
         :ok <- validate_context(Map.take(basis, @snapshot)),
         {:ok, sources} <-
           collect(basis["context"]["sources"], &Evidence.get_source(&1["source_id"])),
         {:ok, _} <- CompanyAnalysis.validate(Contracts.canonical_json(basis["report"]), sources),
         {:ok, actual} <- Evidence.validate_citations(citations),
         true <- Origin.identity(actual) == Origin.identity(citations) do
      {:ok, Origin.canonical(actual)}
    else
      {:error, :stale_company_analysis_context} = error -> error
      _ -> {:error, :invalid_claim_basis}
    end
  end

  @spec render_guidance(map()) :: String.t()
  def render_guidance(guidance) do
    "Rule: #{guidance["rule"]}\nWorkflow: #{guidance["workflow"]}\nCheck: #{guidance["check"]}\nEvaluation criterion: #{guidance["evaluation_criterion"]}"
  end

  @spec validate_successor(map() | nil, map()) :: :ok | {:error, :claim_origin_change}
  def validate_successor(previous, attrs) do
    old = previous && previous["basis"]
    new = attrs["basis"]

    case {analysis?(old), analysis?(new)} do
      {false, false} ->
        :ok

      {false, true} when is_nil(previous) ->
        check(
          Origin.valid_basis?(new) and is_nil(new["review_resolution"]) and
            new["guidance"] ==
              Map.new(@fields, &{&1, String.trim(new["report"]["recommendation"][&1])}),
          :claim_origin_change
        )

      {true, true} ->
        check(
          Origin.valid_basis?(old) and Origin.valid_basis?(new) and
            match?({:ok, _}, Origin.references(previous)) and
            match?(
              {:ok, _},
              Origin.references(%{"basis" => new, "citations" => attrs["citations"]})
            ) and
            Map.drop(old, ~w(guidance review_resolution)) ==
              Map.drop(new, ~w(guidance review_resolution)) and
            Origin.identity(previous["citations"]) == Origin.identity(attrs["citations"]) and
            (is_nil(old["review_resolution"]) or not is_nil(new["review_resolution"])),
          :claim_origin_change
        )

      _ ->
        {:error, :claim_origin_change}
    end
  end

  @spec approval_ready?(map()) :: boolean()
  def approval_ready?(%{"basis" => %{"kind" => "company_analysis"} = basis} = claim) do
    match?({:ok, _}, Origin.references(claim)) and
      (not resolution_required?(basis["report"]) or
         CompanyAnalysis.text?(basis["review_resolution"]))
  end

  def approval_ready?(_), do: false

  defp valid_input(attrs, opts) do
    valid =
      CompanyAnalysis.keys?(attrs, @input) and CompanyAnalysis.uuid?(attrs["project_id"]) and
        CompanyAnalysis.uuid?(attrs["goal_id"]) and
        CompanyAnalysis.digest?(attrs["goal_content_hash"]) and
        is_list(attrs["source_refs"]) and length(attrs["source_refs"]) in 2..4 and
        Enum.all?(attrs["source_refs"], &Origin.source_ref?/1) and
        length(Enum.uniq_by(attrs["source_refs"], & &1["source_id"])) ==
          length(attrs["source_refs"]) and
        Keyword.keyword?(opts) and Keyword.keys(opts) -- [:run_id, :request_id, :timeout] == [] and
        Enum.all?(Keyword.take(opts, [:run_id, :request_id]), fn {_, id} ->
          CompanyAnalysis.uuid?(id)
        end) and
        is_integer(Keyword.get(opts, :timeout, 30_000)) and
        Keyword.get(opts, :timeout, 30_000) in 1..60_000

    check(valid, :invalid_company_analysis_input)
  end

  defp capture(attrs) do
    with {:ok, profile} <- Company.get_profile(),
         :ok <- check(not is_nil(profile), :company_analysis_out_of_scope),
         {:ok, project} <- Store.get(Project, attrs["project_id"]),
         {:ok, goal} <- Store.get(Goal, attrs["goal_id"]),
         allowed_sources =
           Enum.uniq(profile["payload"]["source_ids"] ++ project.payload["source_ids"]),
         allowed_goals = Enum.uniq(profile["payload"]["goal_ids"] ++ project.payload["goal_ids"]),
         :ok <-
           check(
             attrs["goal_id"] in allowed_goals and
               Enum.all?(attrs["source_refs"], &(&1["source_id"] in allowed_sources)),
             :company_analysis_out_of_scope
           ),
         :ok <-
           check(
             Goals.content_hash(goal) == attrs["goal_content_hash"],
             :stale_company_analysis_context
           ),
         refs = Enum.sort_by(attrs["source_refs"], & &1["source_id"]),
         {:ok, sources} <- collect(refs, &current_source/1),
         :ok <-
           check(
             Enum.reduce(sources, 0, &(byte_size(&1["latest_revision"]["body"]) + &2)) <= 32_768,
             :company_analysis_input_too_large
           ),
         context = %{
           "profile" => Map.take(profile, ~w(id content_hash)),
           "project" => %{"id" => project.id, "content_hash" => project.content_hash},
           "sources" => refs
         },
         snapshot =
           attrs
           |> Map.take(~w(project_id goal_id goal_content_hash))
           |> Map.merge(%{"context" => context, "context_digest" => Contracts.digest(context)}) do
      {:ok,
       %{
         snapshot: snapshot,
         sources: sources,
         goal: Store.dto(goal),
         profile: profile,
         project: Store.dto(project)
       }}
    else
      {:error, :not_found} -> {:error, :invalid_company_analysis_input}
      error -> error
    end
  end

  defp current_source(ref) do
    with {:ok, source} <- Store.get(Source, ref["source_id"]),
         {:ok, connection} <- Store.get(Connection, source.connection_id),
         {:ok, dto} <- Evidence.get_source(source.id),
         revision when is_map(revision) <- dto["latest_revision"],
         true <-
           source.status == "active" and connection.status == "active" and
             revision["id"] == ref["revision_id"] and revision["body_hash"] == ref["body_hash"],
         :ok <-
           HarnessForge.Connectors.Registry.document_scope(connection, %{
             "external_id" => source.external_id,
             "source_url" => revision["source_url"],
             "metadata" => revision["metadata"]
           }) do
      {:ok, dto}
    else
      _ -> {:error, :stale_company_analysis_context}
    end
  end

  defp prompt(captured),
    do:
      Contracts.canonical_json(%{
        "context" => captured.snapshot,
        "profile" => captured.profile["payload"],
        "project" => captured.project["payload"],
        "goal" => Map.take(captured.goal, ~w(id title owner acceptance)),
        "sources" =>
          Enum.map(captured.sources, fn source ->
            %{
              "source_id" => source["id"],
              "title" => source["title"],
              "revision_id" => source["latest_revision"]["id"],
              "body_hash" => source["latest_revision"]["body_hash"],
              "body_byte_length" => byte_size(source["latest_revision"]["body"]),
              "available_citation_spans" => [
                %{"start_byte" => 0, "end_byte" => byte_size(source["latest_revision"]["body"])}
              ],
              "body" => source["latest_revision"]["body"]
            }
          end)
      })

  defp admit(snapshot, config, fingerprint, response, report) do
    Purge.synchronize(fn ->
      Store.transaction(fn ->
        with :ok <- Workspaces.ensure_writable(),
             :ok <- validate_context(snapshot),
             :ok <- Configuration.expect_fingerprint(fingerprint),
             :ok <-
               check(
                 response["provider"] == config["provider"] and
                   response["model"] == config["model"] and
                   response["config_fingerprint"] == fingerprint,
                 :model_configuration_changed
               ) do
          if is_nil(report["recommendation"]) do
            {:ok, %{"status" => "abstained", "uncertainty" => report["uncertainty"]}}
          else
            persist(snapshot, fingerprint, response, report)
          end
        end
      end)
    end)
  end

  defp persist(snapshot, fingerprint, response, report) do
    with {:ok, citations} <-
           collect(Enum.uniq(CompanyAnalysis.citations(report)), fn citation ->
             Evidence.citation(
               citation["revision_id"],
               citation["start_byte"],
               citation["end_byte"]
             )
           end),
         guidance = Map.new(@fields, &{&1, String.trim(report["recommendation"][&1])}),
         basis =
           Map.merge(snapshot, %{
             "kind" => "company_analysis",
             "version" => 1,
             "report" => report,
             "guidance" => guidance,
             "provider" => response["provider"],
             "model" => response["model"],
             "config_fingerprint" => fingerprint,
             "run_id" => response["run_id"],
             "request_id" => response["request_id"],
             "review_resolution" => nil
           }),
         {:ok, claim} <-
           Evidence.create_claim(%{
             "text" => render_guidance(guidance),
             "citations" => Origin.canonical(citations),
             "basis" => basis
           }),
         {:ok, _} <-
           Audit.append("model.proposed", %{
             "claim_id" => claim["id"],
             "run_id" => response["run_id"],
             "count" => 1
           }) do
      {:ok,
       %{
         "status" => "proposed",
         "claim" => claim,
         "run_id" => response["run_id"],
         "request_id" => response["request_id"]
       }}
    end
  end

  defp edited(attrs, previous) do
    if is_map(attrs) and Map.keys(attrs) -- (@fields ++ ["review_resolution"]) == [] and
         Enum.all?(@fields, &CompanyAnalysis.text?(attrs[&1])) and
         (not Map.has_key?(attrs, "review_resolution") or
            CompanyAnalysis.text?(attrs["review_resolution"])) do
      {:ok, Map.new(@fields, &{&1, String.trim(attrs[&1])}),
       Map.get(attrs, "review_resolution", previous)}
    else
      {:error, :invalid_company_analysis_input}
    end
  end

  defp resolution_required?(report),
    do:
      report["recommendation"]["status"] in ~w(uncertain conflicted) or
        Enum.any?(report["findings"], &(&1["kind"] == "conflict"))

  defp analysis?(%{"kind" => "company_analysis"}), do: true
  defp analysis?(_), do: false

  defp collect(values, fun) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case fun.(value) do
        {:ok, item} -> {:cont, {:ok, [item | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp check(true, _), do: :ok
  defp check(false, reason), do: {:error, reason}
end
