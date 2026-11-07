defmodule HarnessForge.Company.Retrieval do
  @moduledoc """
  Bounded passage retrieval snapshots, independent of human claim and plan approval.

  `read_run/4` pages expose `lane_memberships` (a list from the fixed
  search lanes), `context_readiness` (`complete`, `incomplete`, or historical
  `unknown`), per-lane lexical ordinals in `lane_ranks`, and `packing_version`.
  Historical lane ranks are nil rather than reconstructed. Readiness describes verified parent bytes,
  never semantic truth or approval. Compact immutable diagnostics align with
  each candidate_order; old envelopes remain unknown rather than reinterpreted.
  Displayed candidates also include checked source metadata, exact byte pins and
  bounded snippets, without parent text. Only the <=25 visible rows read the
  existing <=4096-byte parent window: <=102400 parent-window bytes per page,
  not a measurement of total memory. Names describe the current display identity.

  New runs store query-plan version, searched question terms and question-lane
  candidate/selected counts in digest-bound `coverage.search.question`. These
  counts describe lexical matching, never semantic sufficiency. Graph counts
  and missing historical diagnostics remain unknown.

  New stored plans use the lossless `query-plan-terms-v1` encoding. Runtime
  queries stay expanded. `decode_query_plan/1` provides a separate inspection
  value; stored envelope bytes are always hashed before any decoding.
  """
  import Ecto.Query
  require Bitwise
  alias HarnessForge.{Contracts, Goals, Repo}
  alias HarnessForge.Company.{EvidenceBundle, Profile, Project, RetrievalItem, RetrievalRun}
  alias HarnessForge.Evidence.{Corpora, Goal, Passages, Requirements, RevisionUseHolds, Store, LocalUsePolicies, SourceUseContext}
  alias HarnessForge.Graphiti.SearchCompletion

  @stopwords ~w(a an the and or to of in on for from with by at as is are was were be been being do does did can could would should may might will shall what which who whom whose why how when where you your we our they their it its this that these those please explain describe about according)
  @packing "context-diverse-v2"
  @lane_bits [
    {"support", 1},
    {"contrary", 2},
    {"chronology", 4},
    {"obligations", 8},
    {"followup", 16}
  ]
  @input ~w(corpus_id project_id goal_id goal_hash expected_generation question mode)
  @identity ~w(passage_id source_id revision_id body_hash start_byte end_byte snippet_hash parent_start_byte parent_end_byte parent_hash)
  @limits %{
    "searches" => 5,
    "candidates" => 100,
    "passages" => 24,
    "evidence_bytes" => 32768,
    "prompt_bytes" => 49152
  }

  def retrieve(attrs, caller), do: retrieve(attrs, caller, nil)

  def retrieve(attrs, caller, context) do
    with :ok <- input(attrs), do: retrieve_current(attrs, caller, nil, context)
  end

  @doc "Current-FTS inspection with an immutable request and checked operator binding."
  @spec retrieve_evidence(term(), keyword()) :: {:ok, map()} | {:error, term()}
  def retrieve_evidence(attrs, caller), do: retrieve_evidence(attrs, caller, nil)

  def retrieve_evidence(attrs, caller, context) do
    with {:ok, request} <- EvidenceBundle.normalize_request(attrs),
         do: retrieve_current(request, caller, Contracts.digest(request), context)
  end

  defp retrieve_current(attrs, caller, request_digest, context) do
    with {:ok, scope} <- context_guard(caller, context, fn -> declared_capture(attrs, caller, context) end),
         evidence = stored_evidence(request_digest, caller),
         plan = query_plan(attrs["question"], scope["goal"]),
         {:ok, candidates, graph} <- search(scope, plan, attrs["mode"], caller, context),
         {:ok, candidates, selected, omitted} <- pack(candidates, context),
         {:ok, result} <-
           context_guard(caller, context, fn ->
             publish(scope, plan, attrs["mode"], candidates, selected, omitted, graph, evidence, context)
           end, "retrieval") do
      {:ok, result}
    end
  end

  defp stored_evidence(nil, _caller), do: nil

  defp stored_evidence(request_digest, caller),
    do: %{"request_digest" => request_digest, "caller_digest" => evidence_caller_digest(caller)}

  defp evidence_caller_digest(caller),
    do:
      Contracts.digest(%{
        "workspace_id" => Store.workspace(),
        "session_fingerprint" => caller[:session_fingerprint],
        "view_generation" => caller[:view_generation],
        "reset_token" => caller[:reset_token]
      })

  defp input(attrs) do
    valid =
      Corpora.keys(attrs, @input, ["declaration_ref"]) == :ok and
        valid_declaration_ref?(attrs) and
        Enum.all?(~w(corpus_id project_id goal_id), &Corpora.uuid?(attrs[&1])) and
        Corpora.digest?(attrs["goal_hash"]) and
        is_integer(attrs["expected_generation"]) and attrs["expected_generation"] >= 0 and
        Corpora.text?(attrs["question"], 1024) and String.length(attrs["question"]) <= 256 and
        attrs["mode"] in ~w(fts graphiti_hybrid)

    if valid, do: :ok, else: {:error, :invalid_input}
  end

  defp valid_declaration_ref?(attrs) do
    case Map.fetch(attrs, "declaration_ref") do
      :error ->
        true

      {:ok, ref} ->
        Corpora.keys(ref, ~w(id digest)) == :ok and
          Corpora.uuid?(ref["id"]) and Corpora.digest?(ref["digest"])
    end
  end

  defp declared_capture(attrs, caller, context) do
    with {:ok, scope} <- capture(attrs, context, "retrieval") do
      case Map.fetch(attrs, "declaration_ref") do
        :error ->
          {:ok, scope}

        {:ok, ref} ->
          with {:ok, summary} <- Requirements.summary(ref["id"], ref["digest"], caller),
               :ok <- declaration_scope(summary, scope),
               do: {:ok, Map.put(scope, "declaration", declaration_basis(summary))}
      end
    end
  end

  defp declaration_scope(summary, scope) do
    expected = %{
      "workspace_id" => Store.workspace(),
      "corpus_id" => scope["corpus_id"],
      "project_id" => scope["project_id"],
      "goal_id" => scope["goal_id"],
      "goal_hash" => scope["goal_hash"],
      "semantic_generation" => scope["semantic_generation"],
      "authorization_generation" => scope["authorization_generation"],
      "profile_id" => scope["profile"]["id"],
      "profile_hash" => scope["profile"]["content_hash"],
      "project_hash" => scope["project"]["content_hash"]
    }

    if summary["scope"] == expected, do: :ok, else: {:error, :stale_declaration}
  end

  defp declaration_basis(summary) do
    summary
    |> Map.take(~w(id revision digest required_status omissions))
    |> Map.put("version", "declared-capture.v1")
    |> Map.put(
      "entries",
      Enum.map(
        summary["entries"],
        &Map.take(
          &1,
          ~w(connection_id requirement capture_run_id capture_revision state reason_code member_count)
        )
      )
    )
  end

  defp declaration_current(nil, _), do: :ok

  defp declaration_current(basis, scope) when is_map(basis) do
    with {:ok, summary} <- Requirements.current_summary(basis["id"], basis["digest"]),
         :ok <- declaration_scope(summary, scope),
         true <- declaration_basis(summary) == basis do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :stale_declaration}
    end
  end

  defp declaration_current(_, _), do: {:error, :stale_declaration}

  defp capture(attrs, context, purpose, admission \\ :corpus) do
    with {:ok, corpus} <- Corpora.get(attrs["corpus_id"]),
         :ok <-
           capture_current(corpus, attrs["expected_generation"], context, purpose, admission),
         {:ok, project} <- Store.get(Project, attrs["project_id"]),
         %Profile{} = profile <- Repo.one(Store.scoped(Profile)),
         {:ok, goal} <- Store.get(Goal, attrs["goal_id"]),
         true <- Goals.content_hash(goal) == attrs["goal_hash"],
         true <-
           profile.content_hash == Contracts.digest(profile.payload) and
             project.content_hash == Contracts.digest(project.payload),
         true <- goal.id in Enum.uniq(profile.payload["goal_ids"] ++ project.payload["goal_ids"]),
         [%{}] <-
           Corpora.rows(
             "SELECT corpus_id FROM company_corpus_bindings WHERE workspace_id=? AND project_id=? AND profile_id=? AND corpus_id=?",
             [Store.workspace(), project.id, profile.id, corpus.id]
           ),
         [%{"n" => count}] when count > 0 <-
           Corpora.rows(
             "SELECT count(*) AS n FROM corpus_members WHERE workspace_id=? AND corpus_id=? AND status='active'",
             [Store.workspace(), corpus.id]
           ) do
      {:ok,
       %{
         "corpus_id" => corpus.id,
         "project_id" => project.id,
         "goal_id" => goal.id,
         "goal_hash" => attrs["goal_hash"],
         "semantic_generation" => corpus.semantic_generation,
         "authorization_generation" => corpus.authorization_generation,
         "profile" => Store.dto(profile),
         "project" => Store.dto(project),
         "goal" => Map.put(Store.dto(goal), "content_hash", Goals.content_hash(goal))
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_scope}
    end
  end

  @doc "Fixed lexical lanes with complete question terms and bounded goal terms."
  @spec query_plan(String.t(), map()) :: map()
  def query_plan(question, goal) do
    question_terms = tokens(question)
    goal_terms = goal_tokens(goal["title"] <> " " <> goal["acceptance"])
    base = if question_terms == [], do: goal_terms, else: question_terms
    generic_contrary = ~w(not except exception superseded deprecated changed)
    generic_history = ~w(decision incident postmortem historical)

    lanes = [
      %{"lane" => "support", "expression" => expression(base), "limit" => 20},
      %{"lane" => "contrary", "expression" => combine(base, generic_contrary), "limit" => 20},
      %{"lane" => "chronology", "expression" => combine(base, generic_history), "limit" => 20},
      %{"lane" => "obligations", "expression" => expression(goal_terms), "limit" => 20},
      %{"lane" => "followup", "expression" => expression(generic_contrary), "limit" => 20}
    ]

    %{
      "version" => "query_plan_v3",
      "question" => question,
      "question_terms" => question_terms,
      "base_source" => if(question_terms == [], do: "goal", else: "question"),
      "lanes" => lanes,
      "limits" => @limits
    }
  end

  @doc false
  @spec decode_query_plan(map()) :: {:ok, map()} | {:error, :invalid_query_plan}
  def decode_query_plan(
        %{
          "storage_encoding" => "query-plan-terms-v1",
          "lane_recipe" => "five-lane-lexical-v1",
          "version" => "query_plan_v3"
        } = stored
      ) do
    keys =
      ~w(version question question_terms base_source limits storage_encoding lane_recipe goal_terms)

    if Enum.sort(Map.keys(stored)) == Enum.sort(keys) and
         valid_plan_question?(stored["question"]) and
         valid_plan_terms?(stored["question_terms"], 1024, 4096) and
         valid_plan_terms?(stored["goal_terms"], 8, 16384) and
         valid_base_source?(stored["base_source"], stored["question_terms"]) and
         stored["limits"] == recipe_limits_v1() do
      expanded =
        stored
        |> Map.drop(~w(storage_encoding lane_recipe goal_terms))
        |> Map.put(
          "lanes",
          recipe_lanes_v1(stored["question_terms"], stored["goal_terms"], stored["base_source"])
        )

      {:ok, expanded}
    else
      {:error, :invalid_query_plan}
    end
  end

  def decode_query_plan(%{"version" => version, "lanes" => lanes} = plain)
      when version in ["query_plan_v2", "query_plan_v3"] do
    unmixed =
      not Enum.any?(~w(storage_encoding lane_recipe goal_terms), &Map.has_key?(plain, &1))

    question_terms_valid =
      version == "query_plan_v2" or
        (valid_plan_terms?(plain["question_terms"], 1024, 4096) and
           valid_base_source?(plain["base_source"], plain["question_terms"]))

    if unmixed and valid_plan_question?(plain["question"]) and question_terms_valid and
         plain["limits"] == recipe_limits_v1() and valid_plain_lanes?(lanes) do
      {:ok, plain}
    else
      {:error, :invalid_query_plan}
    end
  end

  def decode_query_plan(_), do: {:error, :invalid_query_plan}

  defp compact_query_plan(plan) do
    with lanes when is_list(lanes) <- plan["lanes"],
         %{"expression" => rendered_goal} <-
           Enum.find(lanes, &(&1["lane"] == "obligations")),
         {:ok, goal_terms} <- selected_goal_terms(rendered_goal),
         stored =
           plan
           |> Map.delete("lanes")
           |> Map.merge(%{
             "storage_encoding" => "query-plan-terms-v1",
             "lane_recipe" => "five-lane-lexical-v1",
             "goal_terms" => goal_terms
           }),
         {:ok, ^plan} <- decode_query_plan(stored) do
      {:ok, stored}
    else
      _ -> {:error, :invalid_query_plan}
    end
  end

  defp selected_goal_terms(rendered) when is_binary(rendered) and byte_size(rendered) <= 32768 do
    if String.valid?(rendered) do
      terms = Regex.scan(~r/"([^"]+)"/u, rendered, capture: :all_but_first) |> List.flatten()

      if valid_plan_terms?(terms, 8, 16384) and recipe_expression_v1(terms) == rendered,
        do: {:ok, terms},
        else: {:error, :invalid_query_plan}
    else
      {:error, :invalid_query_plan}
    end
  end

  defp selected_goal_terms(_), do: {:error, :invalid_query_plan}

  defp valid_plan_question?(question),
    do:
      is_binary(question) and String.valid?(question) and byte_size(question) <= 1024 and
        String.length(question) <= 256

  defp valid_plan_terms?(terms, max_terms, max_bytes) when is_list(terms) do
    length(terms) <= max_terms and terms == Enum.uniq(terms) and
      Enum.all?(terms, fn term ->
        is_binary(term) and String.valid?(term) and byte_size(term) in 1..max_bytes and
          not Regex.match?(~r/[\s\p{Z}\p{C}"]/u, term)
      end) and Enum.reduce(terms, 0, &(byte_size(&1) + &2)) <= max_bytes
  end

  defp valid_plan_terms?(_, _, _), do: false

  defp valid_base_source?("goal", []), do: true
  defp valid_base_source?("question", [_ | _]), do: true
  defp valid_base_source?(_, _), do: false

  defp valid_plain_lanes?(lanes) when is_list(lanes) and length(lanes) == 5 do
    Enum.all?(lanes, fn
      %{"lane" => name, "expression" => expression, "limit" => 20} when is_binary(name) ->
        is_binary(expression) and String.valid?(expression) and byte_size(expression) <= 32768

      _ ->
        false
    end) and
      Enum.map(lanes, & &1["lane"]) == ~w(support contrary chronology obligations followup)
  end

  defp valid_plain_lanes?(_), do: false

  # Recipe v1 is immutable historical serialization, independent of the runtime
  # normalizer, expression helpers, generic word lists and future query limits.
  defp recipe_limits_v1,
    do: %{
      "searches" => 5,
      "candidates" => 100,
      "passages" => 24,
      "evidence_bytes" => 32768,
      "prompt_bytes" => 49152
    }

  defp recipe_lanes_v1(question_terms, goal_terms, source) do
    base = if source == "question", do: question_terms, else: goal_terms

    contrary =
      "\"not\" OR \"except\" OR \"exception\" OR \"superseded\" OR \"deprecated\" OR \"changed\""

    history = "\"decision\" OR \"incident\" OR \"postmortem\" OR \"historical\""

    [
      %{"lane" => "support", "expression" => recipe_expression_v1(base), "limit" => 20},
      %{"lane" => "contrary", "expression" => recipe_combine_v1(base, contrary), "limit" => 20},
      %{"lane" => "chronology", "expression" => recipe_combine_v1(base, history), "limit" => 20},
      %{"lane" => "obligations", "expression" => recipe_expression_v1(goal_terms), "limit" => 20},
      %{"lane" => "followup", "expression" => contrary, "limit" => 20}
    ]
  end

  defp recipe_expression_v1(terms), do: Enum.map_join(terms, " OR ", &("\"" <> &1 <> "\""))
  defp recipe_combine_v1([], _), do: ""

  defp recipe_combine_v1(terms, right),
    do: "(" <> recipe_expression_v1(terms) <> ") AND (" <> right <> ")"

  defp tokens(text) do
    terms =
      Regex.scan(~r/[\p{L}\p{N}_]+/u, text) |> List.flatten() |> Enum.map(&String.downcase/1)

    content = terms |> Enum.reject(&(&1 in @stopwords)) |> Enum.uniq()
    if content == [], do: Enum.uniq(terms), else: content
  end

  defp goal_tokens(text) do
    selected = tokens(text)

    if length(selected) <= 8,
      do: selected,
      else: Enum.take(selected, 4) ++ Enum.take(selected, -4)
  end

  defp expression([]), do: ""
  defp expression(terms), do: Enum.map_join(terms, " OR ", &("\"" <> &1 <> "\""))
  defp combine([], _), do: ""
  defp combine(left, right), do: "(" <> expression(left) <> ") AND (" <> expression(right) <> ")"

  defp search(scope, plan, "fts", _caller, context) do
    Enum.reduce_while(plan["lanes"], {:ok, []}, fn lane, {:ok, acc} ->
      case lexical(scope, lane, context) do
        {:ok, found} ->
          {:cont, {:ok, merge_candidates(acc, found)}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, found} -> {:ok, found, nil}
      error -> error
    end
  end

  defp search(scope, plan, "graphiti_hybrid", caller, _context) do
    with :ok <- LocalUsePolicies.assert_corpus_use(scope["corpus_id"], "retrieval", nil),
         {:ok, job, authority} <-
           HarnessForge.Models.StageAuthority.retrieval_job(scope, plan, caller),
         {:ok, result} <- HarnessForge.Graphiti.search(job, authority),
         true <-
           result["state"] == "completed" and result["generation"] == scope["semantic_generation"] and
             result["closure_digest"] == job["closure_digest"],
         candidates when is_list(candidates) and length(candidates) <= 100 <-
           get_in(result, ["result", "candidates"]),
         {:ok, certificate} <- SearchCompletion.certificate(job, result, scope, caller),
         {:ok, passages} <- graph_candidates(scope, certificate, candidates) do
      {:ok, passages, certificate}
    else
      false -> {:error, :closure_incomplete}
      {:error, _} = error -> error
      _ -> {:error, :graph_unavailable}
    end
  end

  defp graph_candidates(scope, certificate, candidates) do
    Enum.reduce_while(candidates, {:ok, []}, fn candidate, {:ok, acc} ->
      ids = candidate["episode_ids"]

      if is_list(ids) and length(ids) in 1..24 and ids == Enum.uniq(ids) and
           Enum.all?(ids, &Corpora.uuid?/1) do
        found =
          Enum.flat_map(ids, fn id ->
            Corpora.rows(
              "SELECT b.passage_id FROM graph_episode_bindings b JOIN graph_partition_controls g ON g.id=b.partition_id AND g.workspace_id=b.workspace_id WHERE b.workspace_id=? AND g.corpus_id=? AND g.id=? AND g.state='ready' AND g.inventory_revision=? AND g.inventory_manifest_id=? AND g.inventory_manifest_digest=? AND g.semantic_generation=? AND g.authorization_generation=? AND b.state='ready' AND b.publication_generation BETWEEN 1 AND ? AND b.episode_uuid=? AND EXISTS(SELECT 1 FROM origin_dependencies d JOIN graph_derivative_versions v ON v.workspace_id=d.workspace_id AND v.id=d.derivative_version_id JOIN origin_dependencies support ON support.workspace_id=v.workspace_id AND support.manifest_id=v.manifest_id AND support.kind='episode' AND support.episode_binding_id=b.id AND support.content_hash=b.payload_hash WHERE d.workspace_id=b.workspace_id AND d.manifest_id=? AND d.kind='deterministic_output' AND d.content_hash=v.value_hash AND v.state='published' AND v.object_id LIKE 'root_search:%' AND v.partition_id=g.id)",
              [
                Store.workspace(),
                scope["corpus_id"],
                certificate["partition_id"],
                certificate["base_inventory"]["inventory_revision"],
                certificate["base_inventory"]["inventory_manifest_id"],
                certificate["base_inventory"]["inventory_manifest_digest"],
                scope["semantic_generation"],
                scope["authorization_generation"],
                certificate["base_inventory"]["inventory_revision"],
                id,
                certificate["search_ref"]
              ]
            )
          end)

        if length(found) != length(ids) do
          {:halt, {:error, :closure_incomplete}}
        else
          rows =
            Enum.map(
              found,
              &%{
                "passage_id" => &1["passage_id"],
                "lane" => "support",
                "relation" => "unknown",
                "reason_code" => "graph_candidate"
              }
            )

          next = merge_candidates(acc, rows)

          if length(next) <= 100,
            do: {:cont, {:ok, next}},
            else: {:halt, {:error, :closure_incomplete}}
        end
      else
        {:halt, {:error, :closure_incomplete}}
      end
    end)
  end

  defp lexical(_scope, %{"expression" => ""}, _context), do: {:ok, []}

  defp lexical(scope, lane, context) do
    with {:ok, {policy_sql, policy_params}} <- LocalUsePolicies.not_denied_sql("r", "retrieval", context) do
    sql = """
    WITH allowed AS MATERIALIZED (
      SELECT p.rowid,p.id FROM corpus_members m
      JOIN corpora corpus ON corpus.id=m.corpus_id AND corpus.workspace_id=m.workspace_id
      JOIN evidence_sources s ON s.id=m.source_id AND s.workspace_id=m.workspace_id
      JOIN source_connections c ON c.id=s.connection_id AND c.workspace_id=s.workspace_id
      JOIN evidence_revisions r ON r.id=m.revision_id AND r.source_id=s.id AND r.workspace_id=s.workspace_id
      JOIN passage_sets sets ON sets.id=m.passage_set_id AND sets.revision_id=r.id AND sets.workspace_id=m.workspace_id
      JOIN passages p ON p.passage_set_id=sets.id AND p.workspace_id=m.workspace_id
      WHERE m.workspace_id=? AND m.corpus_id=? AND m.status='active' AND corpus.state='active'
      AND corpus.semantic_generation=? AND corpus.authorization_generation=?
      AND s.status='active' AND c.status='active' AND s.latest_revision_id=r.id AND sets.state='ready'
      AND (#{RevisionUseHolds.not_held_sql("r")})
      AND (#{policy_sql})
      AND (#{HarnessForge.Company.CorpusReview.document_scope_sql()})
    ) SELECT allowed.id AS passage_id FROM passage_search JOIN allowed ON allowed.rowid=passage_search.rowid
      WHERE passage_search MATCH ? ORDER BY bm25(passage_search),allowed.id LIMIT ?
    """

    case Repo.query(
           sql,
           [
             Store.workspace(),
             scope["corpus_id"],
             scope["semantic_generation"],
             scope["authorization_generation"]
            ] ++ policy_params ++ [
             lane["expression"],
             lane["limit"]
           ],
           log: false,
           timeout: 30_000
         ) do
      {:ok, %{rows: rows}} ->
        {:ok,
         Enum.with_index(rows)
         |> Enum.map(fn {[id], rank} ->
           %{
             "passage_id" => id,
             "lane" => lane["lane"],
             "lane_rank" => rank,
             "relation" => relation(lane["lane"]),
             "reason_code" => "lexical_provisional"
           }
         end)}

      _ ->
        {:error, :search_failed}
    end
  end

  end

  defp relation("support"), do: "support"
  defp relation(lane) when lane in ["contrary", "followup"], do: "contrary"
  defp relation(_), do: "unknown"

  defp merge_candidates(acc, incoming) do
    Enum.with_index(incoming)
    |> Enum.reduce(acc, fn {candidate, ordinal}, found ->
      lane = candidate["lane"]
      rank = Map.get(candidate, "lane_rank", length(acc) + ordinal)

      case Enum.find_index(found, &(&1["passage_id"] == candidate["passage_id"])) do
        nil ->
          found ++ [Map.merge(candidate, %{"lanes" => [lane], "lane_ranks" => %{lane => rank}})]

        index ->
          List.update_at(found, index, fn previous ->
            previous
            |> Map.put("lanes", Enum.uniq(previous["lanes"] ++ [lane]))
            |> Map.update!(
              "lane_ranks",
              &Map.update(&1, lane, rank, fn old -> min(old, rank) end)
            )
          end)
      end
    end)
  end

  defp pack(candidates, context) do
    # Validate one bounded original window at a time. Retain only identity and
    # readiness metadata for the <=100 candidates, never their source bodies.
    summaries =
      Enum.with_index(candidates)
      |> Enum.reduce_while({:ok, []}, fn {candidate, index}, {:ok, acc} ->
        case Passages.envelope(candidate["passage_id"], "retrieval", context) do
          {:ok, passage} ->
            summary =
              Map.merge(candidate, Map.take(passage, @identity))
              |> Map.put("candidate_order", index)
              |> Map.put("context_complete", not passage["parent_incomplete"])

            {:cont, {:ok, acc ++ [summary]}}

          error ->
            {:halt, error}
        end
      end)

    with {:ok, checked} <- summaries do
      planned = packing_plan(checked)

      Enum.reduce_while(planned, {:ok, [], 0, 0}, fn candidate, {:ok, acc, bytes, omitted} ->
        case Passages.envelope(candidate["passage_id"], "retrieval", context) do
          {:ok, passage} ->
            size = byte_size(passage["snippet"]) + byte_size(passage["parent_text"])

            cond do
              Map.take(passage, @identity) != Map.take(candidate, @identity) ->
                {:halt, {:error, :invalid_passage}}

              bytes + size > 32768 ->
                {:cont, {:ok, acc, bytes, omitted + 1}}

              true ->
                item = Map.merge(passage, Map.take(candidate, ~w(lane relation reason_code)))
                {:cont, {:ok, acc ++ [item], bytes + size, omitted}}
            end

          error ->
            {:halt, error}
        end
      end)
      |> case do
        {:ok, selected, _, omitted} -> {:ok, checked, selected, omitted}
        error -> error
      end
    end
  end

  @doc false
  def packing_plan(candidates) when is_list(candidates) and length(candidates) <= 100 do
    # Interleave fixed reservations so each lane's leading relevance is considered
    # before another lane fills its entire reservation. Context readiness remains
    # an abstention condition; it cannot promote an unrelated complete paragraph.
    budgets = [{"contrary", 6}, {"chronology", 6}, {"obligations", 4}, {"support", 8}]

    Enum.reduce(1..8, [], fn round, selected ->
      Enum.reduce(budgets, selected, fn {lane, limit}, acc ->
        if round <= limit, do: pick_lane(candidates, lane, 1, acc), else: acc
      end)
    end)
  end

  defp pick_lane(_, _, 0, selected), do: selected

  defp pick_lane(candidates, lane, remaining, selected) do
    available =
      Enum.filter(candidates, fn candidate ->
        memberships = Map.get(candidate, "lanes", [candidate["lane"]])
        matches = lane in memberships or (lane == "contrary" and "followup" in memberships)

        matches and
          not Enum.any?(selected, fn previous ->
            previous["passage_id"] == candidate["passage_id"] or
              parent_identity(previous) == parent_identity(candidate)
          end)
      end)

    case Enum.sort_by(available, &packing_rank(&1, selected, lane)) do
      [] ->
        selected

      [candidate | _] ->
        relation =
          if candidate["reason_code"] == "graph_candidate", do: "unknown", else: relation(lane)

        chosen = Map.merge(candidate, %{"lane" => lane, "relation" => relation})
        pick_lane(candidates, lane, remaining - 1, selected ++ [chosen])
    end
  end

  defp packing_rank(candidate, selected, lane) do
    # A chronology selection must not suppress a different, better support
    # paragraph from that source. Diversity is measured inside the active lane.
    same_source =
      Enum.filter(selected, &(&1["lane"] == lane and &1["source_id"] == candidate["source_id"]))

    overlap =
      Enum.reduce(same_source, 0, fn previous, sum ->
        sum +
          max(
            0,
            min(previous["parent_end_byte"], candidate["parent_end_byte"]) -
              max(previous["parent_start_byte"], candidate["parent_start_byte"])
          )
      end)

    bytes =
      candidate["parent_end_byte"] - candidate["parent_start_byte"] + candidate["end_byte"] -
        candidate["start_byte"]

    {length(same_source), lane_rank(candidate, lane), candidate["candidate_order"], overlap,
     bytes}
  end

  defp lane_rank(candidate, lane) do
    ranks = Map.get(candidate, "lane_ranks", %{})

    cond do
      Map.has_key?(ranks, lane) -> ranks[lane]
      lane == "contrary" and Map.has_key?(ranks, "followup") -> 20 + ranks["followup"]
      true -> candidate["candidate_order"]
    end
  end

  defp parent_identity(candidate),
    do:
      Map.take(candidate, ~w(source_id revision_id parent_start_byte parent_end_byte parent_hash))

  defp lane_mask(candidate),
    do:
      Enum.reduce(@lane_bits, 0, fn {lane, bit}, mask ->
        if lane in Map.get(candidate, "lanes", [candidate["lane"]]), do: mask + bit, else: mask
      end)

  defp publish(scope, plan, mode, candidates, selected, omitted, graph, evidence, context) do
    with :ok <- scope_current(scope, context),
         :ok <- graph_current(graph, scope),
         true <- Enum.all?(selected, &member?(scope["corpus_id"], &1)),
         {:ok, stored_plan} <- compact_query_plan(plan),
         coverage = coverage(scope, plan, mode, candidates, selected, omitted),
         state = if(complete?(coverage) and selected != [], do: "ready", else: "abstained"),
         envelope = %{
           "version" => 2,
           "scope" => pins(scope),
           "query_plan" => stored_plan,
           "versions" => Passages.versions(),
           "packing_version" => @packing,
           "candidate_lanes" => Enum.map(candidates, &lane_mask/1),
           "candidate_lane_ranks" =>
             Enum.map(candidates, fn candidate ->
               Enum.flat_map(@lane_bits, fn {lane, _} ->
                 if lane in candidate["lanes"], do: [lane_rank(candidate, lane)], else: []
               end)
             end),
           "candidate_readiness" =>
             Enum.map(candidates, fn candidate ->
               if candidate["context_complete"], do: 1, else: 2
             end),
           "passages" =>
             Enum.map(selected, &Map.take(&1, @identity ++ ~w(lane relation reason_code))),
           "graph" => graph
         },
         envelope = evidence_envelope(envelope, evidence),
         true <- byte_size(Contracts.canonical_json(envelope)) <= 16384,
         digest = Contracts.digest(%{"envelope" => envelope, "coverage" => coverage}),
         {:ok, run} <-
           Repo.insert(%RetrievalRun{
             workspace_id: Store.workspace(),
             corpus_id: scope["corpus_id"],
             project_id: scope["project_id"],
             goal_id: scope["goal_id"],
             goal_hash: scope["goal_hash"],
             semantic_generation: scope["semantic_generation"],
             authorization_generation: scope["authorization_generation"],
             mode: mode,
             state: "preparing",
             envelope: envelope,
             coverage: coverage,
             inserted_at: Store.now()
           }) do
      Enum.with_index(candidates)
      |> Enum.each(fn {candidate, index} ->
        selection = Enum.find_index(selected, &(&1["passage_id"] == candidate["passage_id"]))
        chosen = if is_integer(selection), do: Enum.at(selected, selection), else: candidate

        {:ok, _} =
          Repo.insert(%RetrievalItem{
            run_id: run.id,
            passage_id: candidate["passage_id"],
            candidate_order: index,
            selected_order: selection,
            relation: chosen["relation"],
            lane: chosen["lane"],
            reason_code: chosen["reason_code"]
          })
      end)

      with {:ok, final} <-
             run
             |> Ecto.Changeset.change(state: state, digest: digest, completed_at: Store.now())
             |> Repo.update() do
        projected =
          if is_nil(evidence),
            do: result(final),
            else:
              Map.put(
                result(final),
                "evidence_bundle",
                EvidenceBundle.project(
                  final,
                  pins(scope),
                  EvidenceBundle.binding(pins(scope), evidence)
                )
              )

        {:ok, projected}
      end
    else
      false -> {:error, :invalid_passage}
      error -> error
    end
  end

  defp evidence_envelope(envelope, nil), do: envelope

  defp evidence_envelope(envelope, evidence),
    do: envelope |> Map.put("version", 3) |> Map.put("evidence", evidence)

  defp coverage(scope, plan, mode, candidates, selected, omitted) do
    [counts] =
      Corpora.rows(
        "SELECT count(*) AS expected,coalesce(sum(CASE WHEN passage_set_id IS NOT NULL THEN 1 ELSE 0 END),0) AS indexed FROM corpus_members WHERE workspace_id=? AND corpus_id=? AND status='active'",
        [Store.workspace(), scope["corpus_id"]]
      )

    latest =
      Corpora.rows(
        "SELECT state,scan_verified,incomplete,checkpoint_seq FROM capture_runs WHERE workspace_id=? AND corpus_id=? ORDER BY inserted_at DESC,id DESC LIMIT 1",
        [Store.workspace(), scope["corpus_id"]]
      )

    capture =
      case latest do
        [run] ->
          %{
            "scan_complete" =>
              run["state"] == "scan_complete" and run["scan_verified"] in [1, true] and
                run["incomplete"] in [0, false],
            "checkpoint" => run["checkpoint_seq"]
          }

        [] ->
          %{"scan_complete" => false, "checkpoint" => nil}
      end

    capture =
      if scope["declaration"],
        do: %{
          "scan_complete" => scope["declaration"]["required_status"] == "complete",
          "checkpoint" => nil
        },
        else: capture

    coverage = %{
      "capture" => capture,
      "index" => Map.put(counts, "version", Passages.versions()),
      "search" => %{
        "packing_version" => @packing,
        "question" => question_coverage(plan, mode, candidates, selected),
        "lanes" => Enum.map(plan["lanes"], & &1["lane"]),
        "selected" => length(selected),
        "omitted" => omitted,
        "parent_incomplete" => Enum.count(selected, & &1["parent_incomplete"]),
        "truncated" => omitted > 0,
        "missing_fields" =>
          Enum.filter(~w(document_status event_at effective_at), fn key ->
            Enum.any?(selected, &is_nil(&1[key]))
          end),
        "unsearched" =>
          "Finite lexical/hybrid candidates do not establish company-wide completeness.",
        "semantic_coverage" => "unknown"
      },
      "control" => %{
        "closure_state" =>
          if(scope["mode"] == "graphiti_hybrid", do: "graph_required", else: "source_complete"),
        "consent_state" => "not_inference_authority"
      }
    }

    if scope["declaration"],
      do: Map.put(coverage, "declaration", scope["declaration"]),
      else: coverage
  end

  defp question_coverage(plan, "fts", candidates, selected) do
    question_ids =
      candidates
      |> Enum.filter(fn candidate ->
        plan["base_source"] == "question" and
          Enum.any?(candidate["lanes"], &(&1 in ~w(support contrary chronology)))
      end)
      |> MapSet.new(& &1["passage_id"])

    %{
      "status" => "lexical",
      "searched_terms" => plan["question_terms"],
      "query_plan_version" => plan["version"],
      "candidates" => MapSet.size(question_ids),
      "selected" => Enum.count(selected, &MapSet.member?(question_ids, &1["passage_id"]))
    }
  end

  defp question_coverage(plan, _mode, _candidates, _selected) do
    %{
      "status" => "unknown",
      "searched_terms" => nil,
      "query_plan_version" => plan["version"],
      "candidates" => nil,
      "selected" => nil
    }
  end

  defp complete?(coverage),
    do:
      coverage["capture"]["scan_complete"] and
        coverage["index"]["expected"] == coverage["index"]["indexed"] and
        coverage["search"]["omitted"] == 0 and coverage["search"]["parent_incomplete"] == 0

  @doc "Checked metadata for one explicitly selected immutable run; never hydrates passages."
  def read_summary(id, digest, caller), do: read_summary(id, digest, caller, nil)

  def read_summary(id, digest, caller, context) do
    context_guard(caller, context, fn ->
      with {:ok, run} <- checked_run(id, digest, context, "inspection"),
           {:ok, scope} <- scope_from_run(run, context, "inspection") do
        {:ok, Map.put(result(run), "scope", pins(scope))}
      end
    end)
  end

  @doc "Checked current EvidenceBundle metadata without passage hydration."
  @spec read_evidence_summary(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def read_evidence_summary(id, digest, caller), do: read_evidence_summary(id, digest, caller, nil)

  def read_evidence_summary(id, digest, caller, context) do
    context_guard(caller, context, fn ->
      with {:ok, run} <- checked_run(id, digest, context, "inspection"),
           {:ok, bundle} <- checked_evidence(run, caller) do
        {:ok,
         result(run)
         |> Map.put("scope", bundle["scope"])
         |> Map.put("evidence_bundle", bundle)}
      end
    end)
  end

  @doc "Page checked current candidates using the immutable bundle cursor binding."
  @spec read_evidence(String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def read_evidence(id, digest, attrs, caller), do: read_evidence(id, digest, attrs, caller, nil)

  def read_evidence(id, digest, attrs, caller, context) do
    context_guard(caller, context, fn ->
      with :ok <- Corpora.keys(attrs, [], ["cursor"]),
           {:ok, run} <- checked_run(id, digest, context, "inspection"),
           {:ok, bundle} <- checked_evidence(run, caller),
           binding = evidence_cursor(run, bundle),
           {:ok, after_key} <- Corpora.cursor(attrs["cursor"], binding, caller) do
        found =
          Corpora.rows(
            "SELECT passage_id AS id,passage_id,candidate_order,selected_order,relation,lane,reason_code FROM retrieval_items WHERE run_id=? AND passage_id>? ORDER BY passage_id LIMIT 26",
            [id, after_key]
          )

        page = Corpora.paged(found, binding, caller)

        with {:ok, rows} <- presented_candidates(page["rows"], run, context),
             true <- Enum.all?(rows, &selected_identity?(run, &1)) do
          {:ok,
           result(run)
           |> Map.merge(Map.put(page, "rows", rows))
           |> Map.put("evidence_bundle", bundle)}
        else
          false -> {:error, :invalid_passage}
          error -> error
        end
      end
    end)
  end

  defp evidence_cursor(run, bundle),
    do: %{
      "kind" => "evidence_bundle.v1",
      "run_id" => run.id,
      "digest" => run.digest,
      "request_digest" => bundle["request_digest"],
      "binding_digest" => bundle["binding_digest"],
      "snapshot_digest" => bundle["snapshot_digest"],
      "purpose" => "inspection",
      "time_mode" => "current"
    }

  def read_run(id, digest, attrs, caller), do: read_run(id, digest, attrs, caller, nil)

  def read_run(id, digest, attrs, caller, context) do
    context_guard(caller, context, fn ->
      with :ok <- Corpora.keys(attrs, [], ["cursor"]),
           {:ok, run} <- checked_run(id, digest, context, "inspection"),
           binding = %{"kind" => "retrieval", "run_id" => id, "digest" => digest},
           {:ok, after_key} <- Corpora.cursor(attrs["cursor"], binding, caller) do
        found =
          Corpora.rows(
            "SELECT passage_id AS id,passage_id,candidate_order,selected_order,relation,lane,reason_code FROM retrieval_items WHERE run_id=? AND passage_id>? ORDER BY passage_id LIMIT 26",
            [id, after_key]
          )

        page = Corpora.paged(found, binding, caller)

        with {:ok, rows} <- presented_candidates(page["rows"], run, context) do
          {:ok, Map.merge(result(run), Map.put(page, "rows", rows))}
        end
      end
    end)
  end

  defp presented_candidates(rows, run, context) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
      with {:ok, passage} <- Passages.envelope(row["passage_id"], "inspection", context),
           true <- member?(run.corpus_id, passage) do
        display =
          Map.take(
            passage,
            @identity ++
              ~w(title source_url document_status event_at effective_at captured_at snippet parent_incomplete)
          )

        item = Map.merge(candidate_diagnostics(row, run.envelope), display)
        {:cont, {:ok, [item | acc]}}
      else
        false -> {:halt, {:error, :invalid_scope}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, presented} -> {:ok, Enum.reverse(presented)}
      error -> error
    end
  end

  defp candidate_diagnostics(row, envelope) do
    index = row["candidate_order"]
    masks = envelope["candidate_lanes"]
    readiness = envelope["candidate_readiness"]

    if is_list(masks) and is_list(readiness) do
      mask = Enum.at(masks, index, 0)

      lanes =
        Enum.flat_map(@lane_bits, fn {lane, bit} ->
          if Bitwise.band(mask, bit) != 0, do: [lane], else: []
        end)

      state =
        case Enum.at(readiness, index) do
          1 -> "complete"
          2 -> "incomplete"
          _ -> "unknown"
        end

      stored_ranks =
        if is_list(envelope["candidate_lane_ranks"]),
          do: Enum.at(envelope["candidate_lane_ranks"], index)

      ranks =
        if is_list(stored_ranks) and length(stored_ranks) == length(lanes),
          do: Map.new(Enum.zip(lanes, stored_ranks))

      Map.merge(row, %{
        "lane_memberships" => lanes,
        "lane_ranks" => ranks,
        "context_readiness" => state,
        "packing_version" => envelope["packing_version"]
      })
    else
      # Historical run envelopes keep their original semantics.
      Map.merge(row, %{
        "lane_memberships" => [row["lane"]],
        "lane_ranks" => nil,
        "context_readiness" => "unknown",
        "packing_version" => nil
      })
    end
  end

  def open_passage(id, digest, passage_id, caller), do: open_passage(id, digest, passage_id, caller, nil)

  def open_passage(id, digest, passage_id, caller, context) do
    context_guard(caller, context, fn ->
      with {:ok, run} <- checked_run(id, digest, context, "inspection"),
           item when not is_nil(item) <-
             Repo.one(
               from i in RetrievalItem, where: i.run_id == ^id and i.passage_id == ^passage_id
             ),
           {:ok, passage} <- Passages.envelope(passage_id, "inspection", context),
           true <- member?(run.corpus_id, passage) do
        {:ok,
         Map.merge(passage, %{
           "relation" => item.relation,
           "lane" => item.lane,
           "reason_code" => item.reason_code
         })}
      else
        false -> {:error, :invalid_scope}
        nil -> {:error, :invalid_passage}
        error -> error
      end
    end)
  end

  @doc "Open exact current passage bytes under the checked bundle and membership."
  @spec open_evidence_passage(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def open_evidence_passage(id, digest, passage_id, caller), do: open_evidence_passage(id, digest, passage_id, caller, nil)

  def open_evidence_passage(id, digest, passage_id, caller, context) do
    context_guard(caller, context, fn ->
      with {:ok, run} <- checked_run(id, digest, context, "inspection"),
           {:ok, bundle} <- checked_evidence(run, caller),
           true <- Corpora.uuid?(passage_id),
           item when not is_nil(item) <-
             Repo.one(
               from i in RetrievalItem, where: i.run_id == ^id and i.passage_id == ^passage_id
             ),
           {:ok, passage} <- Passages.envelope(passage_id, "inspection", context),
           true <- member?(run.corpus_id, passage),
           true <- selected_identity?(run, passage) do
        citation = EvidenceBundle.citation(passage, bundle["scope"]["workspace_id"])

        {:ok,
         Map.merge(passage, %{
           "relation" => item.relation,
           "lane" => item.lane,
           "reason_code" => item.reason_code,
           "citation_digest" => citation["citation_digest"],
           "bundle_digest" => bundle["bundle_digest"]
         })}
      else
        false -> {:error, :invalid_passage}
        nil -> {:error, :invalid_passage}
        error -> error
      end
    end)
  end

  defp selected_identity?(run, passage) do
    case Enum.find(run.envelope["passages"], &(&1["passage_id"] == passage["passage_id"])) do
      nil -> true
      expected -> Map.take(expected, @identity) == Map.take(passage, @identity)
    end
  end

  def validate_current(id, digest), do: validate_current(id, digest, "inspection", nil)

  def validate_current(id, digest, purpose, context) do
    with {:ok, _} <- checked_run(id, digest, context, purpose, :selected), do: :ok
  end

  def resolve_for_analysis(id, digest, caller), do: resolve_for_analysis(id, digest, caller, nil)

  def resolve_for_analysis(id, digest, caller, context) do
    context_guard(caller, context, fn ->
      with {:ok, run} <- checked_run(id, digest, context, "analysis"),
           {:ok, analysis_ready} <- analysis_readiness(run, caller),
           true <- run.state == "ready" and analysis_ready,
           {:ok, scope} <- scope_from_run(run, context, "analysis"),
           {:ok, passages} <- hydrated(run, context),
           true <-
             byte_size(
               Contracts.canonical_json(%{"scope" => pins(scope), "passages" => passages})
             ) <= 49152 do
        refs = Enum.map(passages, &Map.take(&1, @identity))

        manifest = %{
          "version" => 2,
          "kind" => "retrieval",
          "run_id" => id,
          "run_digest" => digest,
          "corpus_id" => run.corpus_id,
          "semantic_generation" => run.semantic_generation,
          "authorization_generation" => run.authorization_generation,
          "dependencies" => refs,
          "graph" => run.envelope["graph"]
        }

        {:ok,
         Map.merge(scope, %{
           "run_id" => id,
           "digest" => digest,
           "passages" => passages,
           "coverage" => run.coverage,
           "manifest" => manifest
         })}
      else
        false -> {:error, :capture_incomplete}
        error -> error
      end
    end, "analysis")
  end

  defp analysis_readiness(%{envelope: %{"version" => 3}} = run, caller) do
    with {:ok, bundle} <- checked_evidence(run, caller), do: {:ok, bundle["analysis_ready"]}
  end

  defp analysis_readiness(run, _caller), do: {:ok, run.state == "ready"}

  defp checked_evidence(run, caller) do
    case run.envelope["version"] do
      legacy when legacy in [1, 2] ->
        {:error, :legacy_contract_unavailable}

      3 ->
        evidence = run.envelope["evidence"]

        with true <- valid_evidence_envelope?(run, evidence),
             :ok <- evidence_caller_matches(evidence, caller),
             :ok <- evidence_selected_items(run) do
          scope = run.envelope["scope"]
          {:ok, EvidenceBundle.project(run, scope, EvidenceBundle.binding(scope, evidence))}
        else
          false -> {:error, :invalid_input}
          error -> error
        end

      _ ->
        {:error, :invalid_input}
    end
  end

  defp evidence_caller_matches(evidence, caller),
    do:
      if(evidence["caller_digest"] == evidence_caller_digest(caller),
        do: :ok,
        else: {:error, :operator_session_revoked}
      )

  defp evidence_selected_items(run) do
    selected =
      Corpora.rows(
        "SELECT passage_id FROM retrieval_items WHERE run_id=? AND selected_order IS NOT NULL ORDER BY selected_order LIMIT 25",
        [run.id]
      )

    if Enum.map(selected, & &1["passage_id"]) ==
         Enum.map(run.envelope["passages"], & &1["passage_id"]),
       do: :ok,
       else: {:error, :invalid_passage}
  end

  defp valid_evidence_envelope?(run, evidence) do
    Corpora.keys(evidence, ~w(request_digest caller_digest)) == :ok and
      Corpora.digest?(evidence["request_digest"]) and Corpora.digest?(evidence["caller_digest"]) and
      run.mode == "fts" and is_nil(run.envelope["graph"]) and
      is_list(run.envelope["passages"]) and length(run.envelope["passages"]) <= 24 and
      Enum.all?(run.envelope["passages"], &valid_evidence_identity?/1) and
      byte_size(Contracts.canonical_json(run.envelope)) <= 16384
  end

  defp valid_evidence_identity?(passage) do
    is_map(passage) and not is_struct(passage) and
      Enum.all?(~w(passage_id source_id revision_id), &Corpora.uuid?(passage[&1])) and
      Enum.all?(~w(body_hash snippet_hash parent_hash), &Corpora.digest?(passage[&1])) and
      Enum.all?(
        ~w(start_byte end_byte parent_start_byte parent_end_byte),
        &(is_integer(passage[&1]) and passage[&1] >= 0)
      ) and
      passage["start_byte"] < passage["end_byte"] and
      passage["parent_start_byte"] <= passage["start_byte"] and
      passage["parent_end_byte"] >= passage["end_byte"] and
      (passage["parent_end_byte"] - passage["parent_start_byte"]) in 1..4096
  end

  defp hydrated(run, context) do
    Enum.reduce_while(run.envelope["passages"], {:ok, []}, fn expected, {:ok, acc} ->
      case Passages.envelope(expected["passage_id"], "analysis", context) do
        {:ok, actual} ->
          if Map.take(actual, @identity) == Map.take(expected, @identity) and
               member?(run.corpus_id, actual),
             do:
               {:cont,
                {:ok,
                 acc ++ [Map.merge(actual, Map.take(expected, ~w(lane relation reason_code)))]}},
             else: {:halt, {:error, :invalid_passage}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp checked_run(id, digest, context, purpose, admission \\ :corpus) do
    with :ok <- source_context_current(context, purpose),
         true <- Corpora.uuid?(id) and Corpora.digest?(digest),
         {:ok, run} <- Store.get(RetrievalRun, id),
         true <- run.state in ["ready", "abstained"] and run.digest == digest,
         true <-
           Contracts.digest(%{"envelope" => run.envelope, "coverage" => run.coverage}) == digest,
         :ok <-
           Corpora.assert_generation(run.corpus_id, run.semantic_generation, run.authorization_generation),
         :ok <- run_use_current(run, context, purpose, admission),
         {:ok, scope} <- scope_from_run(run, context, purpose, admission),
         true <- pins(scope) == run.envelope["scope"],
         :ok <- declaration_current(run.coverage["declaration"], scope),
         :ok <- graph_current(run.envelope["graph"], scope) do
      {:ok, run}
    else
      {:error, _} = error -> error
      _ -> {:error, :stale_generation}
    end
  end

  defp capture_current(corpus, expected, _context, _purpose, :selected),
    do: Corpora.assert_generation(corpus.id, expected, corpus.authorization_generation)
  defp capture_current(corpus, expected, %SourceUseContext{kind: :setup_analysis}, "analysis", _admission),
    do: Corpora.assert_generation(corpus.id, expected, corpus.authorization_generation)
  defp capture_current(corpus, expected, context, purpose, _admission),
    do: Corpora.assert_current(corpus.id, expected, corpus.authorization_generation, context, purpose)

  defp run_use_current(run, context, purpose, :selected), do: selected_use_current(run, context, purpose)
  defp run_use_current(run, %SourceUseContext{kind: :setup_analysis} = context, "analysis", _),
    do: selected_use_current(run, context, "analysis")
  defp run_use_current(run, context, purpose, _),
    do: LocalUsePolicies.assert_corpus_use(run.corpus_id, purpose, context)

  defp selected_use_current(run, context, purpose) do
    with refs when is_list(refs) and length(refs) <= 24 <- run.envelope["passages"] do
      Enum.reduce_while(refs, :ok, fn ref, :ok ->
        case LocalUsePolicies.assert_use(Map.take(ref, ~w(source_id revision_id body_hash)), purpose, context) do
          allowed when allowed in [:ok, :legacy_unknown] -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    else
      _ -> {:error, :source_use_denied}
    end
  end

  defp scope_from_run(run, context, purpose, admission \\ :corpus),
    do:
      capture(%{
        "corpus_id" => run.corpus_id,
        "project_id" => run.project_id,
        "goal_id" => run.goal_id,
        "goal_hash" => run.goal_hash,
        "expected_generation" => run.semantic_generation
      }, context, purpose, admission)

  defp scope_current(scope, context) do
    with {:ok, fresh} <-
           capture(%{
             "corpus_id" => scope["corpus_id"],
             "project_id" => scope["project_id"],
             "goal_id" => scope["goal_id"],
             "goal_hash" => scope["goal_hash"],
             "expected_generation" => scope["semantic_generation"]
           }, context, "retrieval"),
         true <- pins(fresh) == pins(scope),
         :ok <- declaration_current(scope["declaration"], fresh),
         do: :ok,
         else: (_ -> {:error, :stale_generation})
  end

  defp graph_current(nil, _scope), do: :ok
  defp graph_current(graph, scope), do: SearchCompletion.validate_stored_certificate(graph, scope)

  defp pins(scope),
    do:
      Map.take(
        scope,
        ~w(corpus_id project_id goal_id goal_hash semantic_generation authorization_generation)
      )
      |> Map.put("workspace_id", Store.workspace())
      |> Map.merge(%{
        "profile" => Map.take(scope["profile"], ~w(id content_hash)),
        "project" => Map.take(scope["project"], ~w(id content_hash))
      })

  defp member?(corpus, passage),
    do:
      Corpora.rows(
        "SELECT 1 AS present FROM corpus_members WHERE workspace_id=? AND corpus_id=? AND source_id=? AND revision_id=? AND status='active' AND passage_set_id IS NOT NULL",
        [Store.workspace(), corpus, passage["source_id"], passage["revision_id"]]
      ) == [%{"present" => 1}]

  defp context_guard(caller, context, fun, purpose \\ "inspection") do
    Corpora.guard(caller, fn ->
      with :ok <- context_caller(context, caller),
           {:ok, result} <- fun.(),
           :ok <- context_caller(context, caller),
           {:ok, checked} <- final_current(result, context, purpose) do
        {:ok, checked}
      end
    end)
  end

  defp final_current(%{"run_id" => id, "digest" => digest} = result, nil, purpose) do
    with :ok <- validate_current(id, digest, purpose, nil), do: {:ok, result}
  end
  defp final_current(%{"run_id" => id, "digest" => digest} = result, context, purpose) do
    with {:ok, decision} <- LocalUsePolicies.decision_for_run(id, digest, purpose, context),
      do: {:ok, Map.put(result, "current_use_decision", decision)}
  end
  defp final_current(result, _context, _purpose), do: {:ok, result}

  defp source_context_current(nil, _purpose), do: :ok
  defp source_context_current(context, purpose) do
    with {:ok, _} <- SourceUseContext.validate(context, purpose), do: :ok
  end

  defp context_caller(nil, _caller), do: :ok
  defp context_caller(context, caller), do: SourceUseContext.match_caller(context, caller)

  defp result(run),
    do: %{
      "run_id" => run.id,
      "digest" => run.digest,
      "state" => run.state,
      "mode" => run.mode,
      "semantic_generation" => run.semantic_generation,
      "authorization_generation" => run.authorization_generation,
      "coverage" => run.coverage,
      "selected_count" => length(run.envelope["passages"]),
      "next_cursor" => nil
    }
end
