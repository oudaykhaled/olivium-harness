defmodule HarnessForge.MCP.SourceTools do
  @moduledoc "Thin, grant-bound current local FTS inspection tools. No inference or provider dispatch."
  alias HarnessForge.Company.Retrieval
  alias HarnessForge.Evidence.{Corpora, Store}
  alias HarnessForge.MCP.ClientContext

  @names ~w(harnessforge_browse_sources harnessforge_retrieve_evidence harnessforge_evidence_page harnessforge_read_citation harnessforge_connection_coverage)
  @uuid %{"type" => "string", "pattern" => "^[0-9a-f-]{36}$"}
  @digest %{"type" => "string", "pattern" => "^[0-9a-f]{64}$"}
  @run %{"run_id" => @uuid, "run_digest" => @digest}

  def list do
    [
      definition(
        Enum.at(@names, 0),
        "Browse at most 25 exact source revisions in the granted synthetic local corpus.",
        %{"cursor" => %{"type" => "string", "maxLength" => 8192}},
        []
      ),
      definition(
        Enum.at(@names, 1),
        "Retrieve current FTS evidence only within the owner-issued disclosure grant. Historical and graph capabilities are unavailable.",
        %{"question" => %{"type" => "string", "minLength" => 1, "maxLength" => 256}},
        ["question"]
      ),
      definition(
        Enum.at(@names, 2),
        "Page one exact evidence snapshot created under this same client grant.",
        Map.put(@run, "cursor", %{"type" => "string", "maxLength" => 8192}),
        ~w(run_id run_digest)
      ),
      definition(
        Enum.at(@names, 3),
        "Read exact citation bytes under the same current client grant and immutable evidence snapshot.",
        Map.merge(@run, %{"passage_id" => @uuid, "citation_digest" => @digest}),
        ~w(run_id run_digest passage_id citation_digest)
      ),
      definition(
        Enum.at(@names, 4),
        "Observe bounded current granted-corpus coverage; no company-wide or historical completeness claim.",
        %{},
        []
      )
    ]
  end

  defp definition(name, description, properties, required),
    do: %{
      "name" => name,
      "description" => description,
      "inputSchema" => %{
        "type" => "object",
        "properties" => properties,
        "required" => required,
        "additionalProperties" => false
      },
      "annotations" => %{
        "readOnlyHint" => true,
        "destructiveHint" => false,
        "idempotentHint" => true,
        "openWorldHint" => false
      }
    }

  def call(name, args, %ClientContext{} = caller) when name in @names do
    with :ok <- ClientContext.authorize(caller), do: dispatch(name, args, caller)
  end

  def call(_, _, _), do: {:error, :unknown_tool}

  @doc false
  def bound_page(name, %{"rows" => rows} = result, args, caller, fits?)
      when name in ~w(harnessforge_browse_sources harnessforge_evidence_page) do
    if fits?.(result) do
      {:ok, result}
    else
      case Enum.drop(rows, -1) do
        [] ->
          {:error, :response_too_large}

        emitted ->
          with {:ok, cursor} <- next_after(name, List.last(emitted), args, caller) do
            bound_page(
              name,
              %{result | "rows" => emitted, "next_cursor" => cursor},
              args,
              caller,
              fits?
            )
          end
      end
    end
  end

  def bound_page(_, result, _, _, _), do: {:ok, result}

  defp next_after("harnessforge_browse_sources", row, _, caller),
    do:
      {:ok,
       Corpora.continuation(
         row["id"],
         %{"kind" => "mcp-granted-sources.v1", "grant_digest" => caller.grant_digest},
         caller
       )}

  defp next_after("harnessforge_evidence_page", row, args, caller),
    do:
      Retrieval.evidence_page_cursor(
        args["run_id"],
        args["run_digest"],
        row["passage_id"],
        caller
      )

  defp dispatch("harnessforge_retrieve_evidence", args, caller) do
    with :ok <- arguments(args, ["question"]),
         attrs =
           caller.scope
           |> Map.take(~w(corpus_id project_id goal_id goal_hash))
           |> Map.put("expected_generation", caller.scope["semantic_generation"])
           |> Map.put("question", args["question"]),
         {:ok, result} <- Retrieval.retrieve_evidence(attrs, caller),
         do: {:ok, result}
  end

  defp dispatch("harnessforge_evidence_page", args, caller) do
    with :ok <- arguments(args, ~w(run_id run_digest), ["cursor"]),
         :ok <- run_args(args),
         do:
           Retrieval.read_evidence(
             args["run_id"],
             args["run_digest"],
             Map.take(args, ["cursor"]),
             caller
           )
  end

  defp dispatch("harnessforge_read_citation", args, caller) do
    with :ok <- arguments(args, ~w(run_id run_digest passage_id citation_digest)),
         :ok <- run_args(args),
         true <- Corpora.uuid?(args["passage_id"]) and Corpora.digest?(args["citation_digest"]),
         {:ok, passage} <-
           Retrieval.open_evidence_passage(
             args["run_id"],
             args["run_digest"],
             args["passage_id"],
             caller
           ),
         true <- passage["citation_digest"] == args["citation_digest"] do
      {:ok, passage}
    else
      false -> {:error, :invalid_arguments}
      error -> error
    end
  end

  defp dispatch("harnessforge_browse_sources", args, caller) do
    Corpora.inspection_guard(caller, fn ->
      binding = %{"kind" => "mcp-granted-sources.v1", "grant_digest" => caller.grant_digest}

      with :ok <- arguments(args, [], ["cursor"]),
           {:ok, after_id} <- Corpora.cursor(args["cursor"], binding, caller) do
        rows =
          Corpora.rows(
            "SELECT s.id,s.id AS source_id,r.id AS revision_id,s.title,r.source_url,r.body_hash,m.passage_set_id FROM corpus_members m JOIN evidence_sources s ON s.id=m.source_id AND s.workspace_id=m.workspace_id JOIN evidence_revisions r ON r.id=m.revision_id AND r.workspace_id=m.workspace_id WHERE m.workspace_id=? AND m.corpus_id=? AND m.status='active' AND s.id>? ORDER BY s.id LIMIT 26",
            [Store.workspace(), caller.scope["corpus_id"], after_id]
          )

        {:ok, Corpora.paged(rows, binding, caller)}
      end
    end)
  end

  defp dispatch("harnessforge_connection_coverage", args, caller) do
    Corpora.inspection_guard(caller, fn ->
      with :ok <- arguments(args, [], []) do
        [counts] =
          Corpora.rows(
            "SELECT count(*) AS active_members,coalesce(sum(CASE WHEN passage_set_id IS NOT NULL THEN 1 ELSE 0 END),0) AS indexed_members FROM corpus_members WHERE workspace_id=? AND corpus_id=? AND status='active'",
            [Store.workspace(), caller.scope["corpus_id"]]
          )

        {:ok,
         Map.merge(counts, %{
           "scope" => caller.scope,
           "history" => "unknown",
           "graph" => "unavailable",
           "semantic_coverage" => "unknown",
           "positive_purpose_policy" => "unknown",
           "disclosure" => "owner_issued_synthetic_local_inspection"
         })}
      end
    end)
  end

  defp arguments(args, required, optional \\ []) do
    case Corpora.keys(args, required, optional) do
      :ok -> :ok
      _ -> {:error, :invalid_arguments}
    end
  end

  defp run_args(args) do
    if Corpora.uuid?(args["run_id"]) and Corpora.digest?(args["run_digest"]),
      do: :ok,
      else: {:error, :invalid_arguments}
  end
end
