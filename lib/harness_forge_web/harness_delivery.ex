defmodule HarnessForgeWeb.HarnessDelivery do
  @moduledoc "Checked, bounded delivery of generated harness files to an authenticated WEB caller."
  alias HarnessForge.{Contracts, Evaluations, Evidence, Harnesses, Repo, Workspaces}
  alias HarnessForge.Company.Retrieval
  alias HarnessForge.Evidence.{Corpora, OriginV2, Store}
  alias HarnessForge.Privacy.Purge

  @max_entries 128
  @max_bytes 16_000_000
  @file_preview_bytes 32_768
  @total_preview_bytes 262_144
  @unavailable {:error, :harness_unavailable}

  @doc "Read current eligible bytes. The caller must first authenticate its operator session."
  def preview(digest) do
    checked(digest, fn artifact ->
      {files, _remaining} =
        artifact["files"]
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map_reduce(@total_preview_bytes, fn {path, bytes}, remaining ->
          content = utf8_prefix(bytes, min(@file_preview_bytes, remaining))

          {%{
             "path" => path,
             "content" => content,
             "bytes" => byte_size(bytes),
             "sha256" => Contracts.sha256(bytes),
             "truncated" => byte_size(content) < byte_size(bytes)
           }, remaining - byte_size(content)}
        end)

      {:ok,
       %{
         "digest" => artifact["digest"],
         "name" => artifact["spec"]["metadata"]["name"],
         "version" => artifact["spec"]["metadata"]["version"],
         "target" => artifact["spec"]["spec"]["runtime"]["name"],
         "files" => files,
         "verification" => %{
           "generated" => true,
           "integrity" => "verified",
           "current_decisions" => "eligible",
           "representative_task" => "unobserved",
           "release_qualification" => "unobserved",
           "recorded_checks" => recorded_checks(artifact["digest"]),
           "summary" =>
             "Generated files match the stored artifact and its current exact decisions. Representative-task results and release qualification were not checked here."
         }
       }}
    end)
  end

  defp recorded_checks(digest) do
    case Evaluations.recent_summaries(digest) do
      {:ok, rows} -> %{"status" => "available", "rows" => rows}
      _ -> %{"status" => "unavailable", "rows" => []}
    end
  end

  @doc "Read one bounded historical task record under the same current artifact access check."
  def check_details(digest, run_id) do
    checked(digest, fn artifact ->
      with {:ok, ^run_id} <- Ecto.UUID.cast(run_id),
           {:ok, %{rows: [[bytes]]}} <-
             Repo.query(
               """
               SELECT result FROM evaluation_runs
               WHERE workspace_id=? AND artifact_digest=? AND id=?
                 AND length(CAST(result AS BLOB)) BETWEEN 1 AND 1048576
               """,
               [Workspaces.current_id(), artifact["digest"], run_id],
               log: false
             ),
           {:ok, run} <- Contracts.decode_json(bytes),
           true <- run["id"] == run_id and run["workspace_id"] == Workspaces.current_id(),
           true <- run["artifact_digest"] == artifact["digest"],
           true <- run["kind"] in ~w(static_integrity runtime_smoke task),
           true <-
             run["outcome"] in ~w(pending running passed failed blocked cancelled interrupted),
           checks when is_list(checks) <- run["checks"] do
        {:ok,
         Map.take(run, ~w(id kind outcome runtime_name))
         |> Map.put("checks", checks |> Enum.take(4) |> Enum.map(&task_detail/1))}
      else
        _ -> @unavailable
      end
    end)
  end

  defp task_detail(check) when is_map(check) do
    evidence = if is_map(check["evidence"]), do: check["evidence"], else: %{}

    %{
      "name" => safe_text(check["name"], 128),
      "outcome" =>
        if(check["outcome"] in ~w(passed failed blocked), do: check["outcome"], else: "unknown"),
      "solver_stopped" => evidence["solver_stopped"] == true,
      "candidate_before" => safe_text(evidence["candidate_before"], 65_536),
      "candidate_after" => safe_text(evidence["candidate_after"], 65_536),
      "grader_output" => safe_text(evidence["grader_output"], 65_536),
      "agent_output" => safe_text(evidence["agent_output"], 65_536)
    }
  end

  defp task_detail(_), do: task_detail(%{})

  defp safe_text(value, limit) when is_binary(value) do
    if String.valid?(value) do
      value
      |> String.replace(~r/\e\[[0-?]*[ -\/]*[@-~]/u, "")
      |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/u, "")
      |> utf8_prefix(limit)
    else
      ""
    end
  end

  defp safe_text(_, _), do: ""

  @doc "Create an in-memory ZIP from exact checked runtime file bytes, without metadata or export paths."
  def download(digest) do
    checked(digest, fn artifact ->
      filename = "harness-" <> artifact["digest"] <> ".zip"

      entries =
        artifact["files"]
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(fn {path, bytes} -> {String.to_charlist(path), bytes} end)

      case :zip.create(String.to_charlist(filename), entries, [:memory]) do
        {:ok, {_name, bytes}} ->
          {:ok, %{"filename" => filename, "bytes" => bytes, "digest" => artifact["digest"]}}

        _ ->
          @unavailable
      end
    end)
  end

  @doc "Offer checked current coverage metadata when only an older coverage selection became stale."
  @spec recovery(term(), keyword()) :: {:ok, map()} | {:error, :harness_unavailable}
  def recovery(digest, caller) do
    result =
      Corpora.guard(caller, fn ->
        with true <- Corpora.digest?(digest),
             {:ok, artifact} <- Harnesses.get(digest),
             {:ok, scope} <- recovery_scope(artifact),
             :ok <-
               Corpora.assert_current(
                 scope["corpus_id"],
                 scope["semantic_generation"],
                 scope["authorization_generation"]
               ),
             {:ok, [current]} <-
               Corpora.requirements_saved_choice(
                 scope["corpus_id"],
                 scope["project_id"],
                 scope["goal_id"],
                 scope["goal_hash"],
                 caller
               ),
             {:ok, summary} <-
               Corpora.requirements_summary(current["id"], current["digest"], caller),
             true <- summary["scope"] == scope and summary["required_status"] == "complete" do
          {:ok,
           %{
             "reason" => "coverage_changed",
             "declaration_id" => current["id"],
             "declaration_digest" => current["digest"],
             "declaration_revision" => current["revision"],
             "href" =>
               "/company/corpus?" <>
                 URI.encode_query(%{
                   "declaration" => current["id"],
                   "declaration_digest" => current["digest"]
                 })
           }}
        else
          _ -> @unavailable
        end
      end)

    case result do
      {:ok, _} = target -> target
      _ -> @unavailable
    end
  rescue
    _ -> @unavailable
  catch
    _, _ -> @unavailable
  end

  defp recovery_scope(artifact) do
    rules = get_in(artifact, ["spec", "spec", "rules"])

    if is_list(rules) and length(rules) in 1..128 do
      Enum.reduce_while(rules, {:ok, nil}, fn rule, {:ok, previous} ->
        with {:ok, claim} <- Evidence.get_claim(rule["id"]),
             true <- claim["revision_hash"] == rule["revision_hash"],
             true <- claim["status"] == "stale" and claim["superseded"] == false,
             %{"kind" => "company_analysis", "version" => 2} = basis <- claim["basis"],
             true <- OriginV2.valid_basis?(basis),
             true <- rule["goal_id"] == basis["goal_id"],
             true <-
               rule["evidence"] ==
                 Enum.map(
                   claim["citations"],
                   &Map.take(&1, ~w(revision_id start_byte end_byte snippet_hash))
                 ),
             context = basis["context"],
             true <- context["workspace_id"] == Store.workspace(),
             {:error, :stale_declaration} <-
               Retrieval.validate_current(
                 context["retrieval_run_id"],
                 context["retrieval_digest"]
               ),
             scope = %{
               "workspace_id" => context["workspace_id"],
               "corpus_id" => context["corpus_id"],
               "semantic_generation" => context["semantic_generation"],
               "authorization_generation" => context["authorization_generation"],
               "profile_id" => context["profile"]["id"],
               "profile_hash" => context["profile"]["content_hash"],
               "project_id" => basis["project_id"],
               "project_hash" => context["project"]["content_hash"],
               "goal_id" => basis["goal_id"],
               "goal_hash" => basis["goal_content_hash"]
             },
             true <- is_nil(previous) or previous == scope do
          {:cont, {:ok, scope}}
        else
          _ -> {:halt, @unavailable}
        end
      end)
    else
      @unavailable
    end
  end

  defp checked(digest, deliver) do
    Purge.synchronize(fn ->
      Store.transaction(fn ->
        with :ok <- Purge.ready(),
             {:ok, artifact} <- Harnesses.get(digest),
             :ok <- Harnesses.eligible(artifact),
             true <- bounded_files?(artifact["files"]),
             :ok <- Purge.ready() do
          deliver.(artifact)
        else
          _ -> @unavailable
        end
      end)
    end)
  rescue
    _ -> @unavailable
  catch
    _, _ -> @unavailable
  end

  # Harnesses.get already verifies compiler output and safe stored payload paths.
  # These additional delivery limits apply before allocating the ZIP or preview.
  defp bounded_files?(files) when is_map(files) and map_size(files) in 1..@max_entries do
    Enum.reduce_while(files, 0, fn {path, bytes}, total ->
      if safe_path?(path) and is_binary(bytes) and String.valid?(bytes) and
           total + byte_size(bytes) <= @max_bytes do
        {:cont, total + byte_size(bytes)}
      else
        {:halt, false}
      end
    end) != false
  end

  defp bounded_files?(_), do: false

  defp safe_path?(path) when is_binary(path) and byte_size(path) in 1..1024 do
    Path.type(path) == :relative and not String.contains?(path, ["\\", <<0>>]) and
      Enum.all?(String.split(path, "/"), fn part ->
        part not in ["", ".", ".."] and Regex.match?(~r/\A[a-zA-Z0-9_.-]+\z/, part)
      end)
  end

  defp safe_path?(_), do: false

  defp utf8_prefix(bytes, limit) when byte_size(bytes) <= limit, do: bytes

  defp utf8_prefix(bytes, limit) do
    prefix = binary_part(bytes, 0, limit)
    if String.valid?(prefix), do: prefix, else: utf8_prefix(bytes, limit - 1)
  end
end
