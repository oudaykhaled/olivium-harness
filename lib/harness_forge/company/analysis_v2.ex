defmodule HarnessForge.Company.AnalysisV2 do
  @moduledoc "Company synthesis over checked passage windows and immutable server manifests."
  alias HarnessForge.{Audit, Contracts, Evidence, Workspaces}
  alias HarnessForge.Evidence.{Origin, OriginV2, Store}
  alias HarnessForge.Models.{AttemptGateway, CompanyAnalysis, StageAuthority}
  @fields ~w(rule workflow check evaluation_criterion)

  def analyze(id, digest, opts) do
    with true <-
           Keyword.keyword?(opts) and
             Keyword.keys(opts) -- [:caller, :stage_id, :run_id, :request_id, :source_context] == [],
         :ok <- Workspaces.ensure_writable(),
         :ok <-
           HarnessForge.Models.RunAuthorization.legacy_allowed(opts[:run_id], [opts[:stage_id]]),
         {:ok, pack} <- OriginV2.seal_retrieval(id, digest, opts[:caller], opts[:stage_id], opts[:source_context]),
         {:ok, pin} <- StageAuthority.load_pin(opts[:stage_id]),
         true <-
           pin["stage"] == "synthesis" and
             pin["prompt_digest"] == Store.hash(CompanyAnalysis.system()) and
             pin["schema_digest"] == Contracts.digest(CompanyAnalysis.schema()),
         run = Keyword.get(opts, :run_id, Ecto.UUID.generate()),
         request = Keyword.get(opts, :request_id, Ecto.UUID.generate()),
         {:ok, auth} <-
           StageAuthority.new(
             run,
             pack["origin_context"]["manifest_id"],
             pack["origin_context"]["manifest_digest"],
             [pin["id"]],
             opts[:caller], opts[:source_context]
           ),
         prompt = prompt(pack),
         true <- byte_size(prompt) <= 49_152,
         {:ok, body} <- request_body(pin, prompt),
         {:ok, auth} <- StageAuthority.bind_synthesis_payload(auth, pin["id"], body),
         attempt = attempt(auth, pin, request, body),
         {:ok, receipt} <- AttemptGateway.dispatch(attempt, auth),
         {:ok, text} <- response_text(pin, receipt),
         {:ok, report} <- CompanyAnalysis.validate_passages(text, pack["passages"]) do
      persist(pack, pin, run, request, report, opts[:caller], auth)
    else
      false -> {:error, :invalid_company_analysis_input}
      error -> error
    end
  end

  @doc false
  def prepare_payload(pack, pin), do: prepare_payload(pack, pin, nil)

  def prepare_payload(pack, pin, source_context) do
    with :ok <- OriginV2.validate_context(pack["origin_context"], source_context),
         prompt = prompt(pack),
         true <- byte_size(prompt) <= 49_152,
         {:ok, body} <- request_body(pin, prompt),
         true <- byte_size(body) <= 98_304 do
      {:ok,
       %{
         "prompt_bytes" => prompt,
         "prompt_sha256" => Store.hash(prompt),
         "request_body_bytes" => body,
         "request_body_sha256" => Store.hash(body)
       }}
    else
      _ -> HarnessForge.Models.RunAuthorization.error("invalid_input")
    end
  end

  def analyze_prepared(operation_ref, caller), do: analyze_prepared(operation_ref, caller, nil)

  def analyze_prepared(operation_ref, caller, source_context) do
    alias HarnessForge.Models.RunAuthorization

    with true <- RunAuthorization.valid_ref?(operation_ref),
         {:ok, binding} <-
           HarnessForge.Company.SetupRuns.operation_binding(operation_ref["id"], caller),
         true <- binding["operation_ref"] == operation_ref and binding["kind"] == "analysis",
         {:ok, source_context} <- StageAuthority.bind_source_context(source_context, operation_ref, binding["authorization_ref"], caller),
         {:ok, current} <-
           RunAuthorization.current(binding["authorization_ref"], operation_ref, caller, source_context),
         {:ok, prepared} <- RunAuthorization.preparation(current["prepared_ref"], caller, source_context),
         {:ok, pin} <- StageAuthority.load_pin(current["stage_ref"]["id"]),
         {:ok, auth} <-
           StageAuthority.new_for_run(
             operation_ref["id"],
             current["manifest_ref"],
             [pin["id"]],
             current["authorization_ref"],
             caller, source_context
           ) do
      execute_prepared(operation_ref, binding, current, prepared, pin, auth, caller)
    else
      false -> RunAuthorization.error("invalid_input")
      failure -> RunAuthorization.normalize(failure)
    end
  end

  defp execute_prepared(operation_ref, binding, current, prepared, pin, authority, caller) do
    alias HarnessForge.Models.RunAuthorization

    result =
      with auth = authority,
           {:ok, auth} <-
             StageAuthority.bind_synthesis_payload(auth, pin["id"], prepared.request_body_bytes),
           request = Ecto.UUID.generate(),
           {:ok, receipt} <-
             AttemptGateway.dispatch(
               attempt(auth, pin, request, prepared.request_body_bytes),
               auth
             ),
           {:ok, text} <- response_text(pin, receipt),
           {:ok, report} <-
             CompanyAnalysis.validate_passages(text, prepared.checked_pack_json["passages"]) do
        HarnessForge.Privacy.Purge.synchronize(fn ->
          Store.transaction(fn ->
            with {:ok, _} <-
                   RunAuthorization.current(current["authorization_ref"], operation_ref, caller, auth.source_context),
                 {:ok, result} <-
                   persist(
                     prepared.checked_pack_json,
                     pin,
                     operation_ref["id"],
                     request,
                     report,
                     caller,
                     auth
                   ),
                 result_ref = %{"id" => operation_ref["id"], "digest" => Contracts.digest(result)},
                 {:ok, _} <-
                   HarnessForge.Company.SetupRuns.publish_operation(
                     operation_ref,
                     binding["expected_run_version"],
                     result_ref,
                     caller, auth.source_context
                   ) do
              {:ok,
               %{
                 "operation_ref" => operation_ref,
                 "result_ref" => result_ref,
                 "status" => "completed"
               }}
            else
              failure -> RunAuthorization.normalize(failure)
            end
          end)
        end)
      else
        failure -> RunAuthorization.normalize(failure)
      end

    if match?({:error, _}, result),
      do: HarnessForge.Models.StageControl.close_without_result(authority)

    result
  end

  defp prompt(pack) do
    Contracts.canonical_json(%{
      "origin" => pack["origin_context"],
      "coverage" => pack["coverage"],
      "goal" => Map.take(pack["goal"], ~w(id title owner acceptance content_hash)),
      "profile" => Map.take(pack["profile"]["payload"], ~w(name description)),
      "project" => Map.take(pack["project"]["payload"], ~w(name description)),
      "passages" => pack["passages"],
      "instruction" =>
        "Passage offsets are absolute UTF-8 offsets in captured revisions. Cite only supplied exact parent windows. Retrieval relations are provisional. Missing or omitted evidence is unknown. Future goals do not override existing controls."
    })
  end

  defp request_body(pin, prompt) do
    common = %{"model" => pin["model"], "stream" => false}

    body =
      case {pin["provider"], URI.parse(pin["endpoint"]).path} do
        {"ollama", "/api/generate"} ->
          Map.merge(common, %{
            "prompt" => prompt,
            "system" => CompanyAnalysis.system(),
            "format" => CompanyAnalysis.schema(),
            "options" => %{"num_predict" => pin["max_output_tokens"], "temperature" => 0}
          })

        {provider, "/v1/chat/completions"} when provider in ~w(openai ollama) ->
          Map.merge(common, %{
            "messages" => [
              %{"role" => "system", "content" => CompanyAnalysis.system()},
              %{"role" => "user", "content" => prompt}
            ],
            "max_completion_tokens" => pin["max_output_tokens"],
            "response_format" => %{
              "type" => "json_schema",
              "json_schema" => %{
                "name" => "company_analysis",
                "strict" => true,
                "schema" => CompanyAnalysis.schema()
              }
            }
          })

        {"openai_responses", "/v1/responses"} ->
          Map.merge(common, %{
            "store" => false,
            "instructions" => CompanyAnalysis.system(),
            "input" => prompt,
            "max_output_tokens" => pin["max_output_tokens"],
            "text" => %{
              "format" => %{
                "type" => "json_schema",
                "name" => "company_analysis",
                "strict" => true,
                "schema" => CompanyAnalysis.schema()
              }
            }
          })

        {"anthropic", "/v1/messages"} ->
          Map.merge(common, %{
            "system" => CompanyAnalysis.system(),
            "messages" => [%{"role" => "user", "content" => prompt}],
            "max_tokens" => pin["max_output_tokens"]
          })

        _ ->
          nil
      end

    if is_map(body), do: {:ok, Contracts.canonical_json(body)}, else: {:error, :stage_unavailable}
  end

  defp attempt(auth, pin, id, body) do
    %{
      "job_id" => auth.operation_id,
      "logical_call_id" => id,
      "attempt_id" => id,
      "stage_id" => pin["id"],
      "stage_digest" => pin["config_digest"],
      "prompt_name" => "company_analysis_v2",
      "closure_ref" => auth.manifest_id,
      "closure_digest" => auth.manifest_digest,
      "context_manifest_ref" => auth.manifest_id,
      "context_manifest_digest" => auth.manifest_digest,
      "cancel_epoch" => auth.cancel_epoch,
      "payload_sha256" => Store.hash(body),
      "method" => "POST",
      "route_id" => pin["route_id"],
      "body" => body,
      "timeout_ms" => pin["timeout_ms"],
      "max_output_tokens" => pin["max_output_tokens"],
      "context_changed" => false,
      "ordinal" => 1,
      "predecessor_attempt_id" => nil
    }
  end

  defp response_text(pin, %{"http_status" => 200, "body" => body}) when is_binary(body) do
    with {:ok, value} <- Jason.decode(body) do
      case {pin["provider"], value} do
        {"ollama", %{"done" => true, "response" => text}} when is_binary(text) ->
          {:ok, text}

        {p, %{"choices" => [%{"message" => %{"content" => text}, "finish_reason" => "stop"}]}}
        when p in ~w(openai ollama) and is_binary(text) ->
          {:ok, text}

        {"anthropic",
         %{"stop_reason" => "end_turn", "content" => [%{"type" => "text", "text" => text}]}}
        when is_binary(text) ->
          {:ok, text}

        {"openai_responses",
         %{
           "status" => "completed",
           "output" => [
             %{"type" => "message", "content" => [%{"type" => "output_text", "text" => text}]}
           ]
         }}
        when is_binary(text) ->
          {:ok, text}

        _ ->
          {:error, :invalid_company_analysis_output}
      end
    end
  end

  defp response_text(_, _), do: {:error, :provider_error}

  defp persist(pack, pin, run, request, report, caller, auth) do
    HarnessForge.Privacy.Purge.synchronize(fn ->
      Store.transaction(fn ->
        with :ok <- HarnessForge.Company.AssessmentAttempts.authorize(caller),
             :ok <- OriginV2.validate_context(pack["origin_context"], auth.source_context),
             :ok <- StageAuthority.revalidate_job(%{"authority" => auth, "job" => nil}) do
          if is_nil(report["recommendation"]) do
            StageAuthority.publish_result(%{
              "authority" => auth,
              "result" => %{"status" => "abstained", "uncertainty" => report["uncertainty"]}
            })
          else
            with {:ok, citations} <- citations(report, auth.source_context),
                 guidance = Map.new(@fields, &{&1, String.trim(report["recommendation"][&1])}),
                 basis = %{
                   "kind" => "company_analysis",
                   "version" => 2,
                   "project_id" => pack["project_id"],
                   "goal_id" => pack["goal_id"],
                   "goal_content_hash" => pack["goal_hash"],
                   "context" => pack["origin_context"],
                   "context_digest" => Contracts.digest(pack["origin_context"]),
                   "report" => report,
                   "guidance" => guidance,
                   "provider" => pin["provider"],
                   "model" => pin["model"],
                   "config_fingerprint" => pin["config_digest"],
                   "run_id" => run,
                   "request_id" => request,
                   "review_resolution" => nil
                 },
                 {:ok, claim} <-
                   Evidence.create_claim(%{
                     "text" => HarnessForge.Company.Analysis.render_guidance(guidance),
                     "citations" => Origin.canonical(citations),
                     "basis" => basis
                   }, auth.source_context),
                 {:ok, _} <-
                   Audit.append("model.proposed", %{
                     "claim_id" => claim["id"],
                     "run_id" => run,
                     "count" => 1
                   }) do
              StageAuthority.publish_result(%{
                "authority" => auth,
                "result" => %{
                  "status" => "proposed",
                  "claim" => claim,
                  "run_id" => run,
                  "request_id" => request
                }
              })
            end
          end
        end
      end)
    end)
  end

  defp citations(report, source_context) do
    CompanyAnalysis.citations(report)
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn c, {:ok, acc} ->
      case Evidence.citation(c["revision_id"], c["start_byte"], c["end_byte"], source_context, "analysis") do
        {:ok, c} -> {:cont, {:ok, acc ++ [c]}}
        e -> {:halt, e}
      end
    end)
  end
end
