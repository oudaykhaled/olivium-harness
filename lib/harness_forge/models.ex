defmodule HarnessForge.Models do
  @moduledoc """
  Workspace-scoped inference with explicit egress consent and durable budgets.

  `start_run/2` creates immutable run limits. Authoring, runtime relay calls,
  subagent calls and retries must all use `infer/2` with the same run ID and
  a fresh request ID. Reusing a request ID never dispatches another call.
  An interrupted request retains its reservation and unknown billing state.

  Configuration is a trusted local operator action. Secrets are read from
  HARNESSFORGE_* environment references at dispatch and never stored here.
  Local models must be explicitly selected and already installed in Ollama.
  """
  alias HarnessForge.{Evidence, Contracts, Audit}
  alias HarnessForge.Evidence.RevisionUseHolds

  alias HarnessForge.Models.{
    Anthropic,
    Configuration,
    Ledger,
    Ollama,
    OpenAI,
    OpenAIResponses,
    Profile,
    Proposal
  }

  defdelegate configure(attrs), to: Configuration
  defdelegate start_run(run_id, attrs \\ Ledger.defaults()), to: Ledger
  @doc false
  defdelegate reopen_run(run_id, creation_limits \\ Ledger.defaults()), to: Ledger
  defdelegate budget(run_id), to: Ledger
  defdelegate list_requests(run_id), to: Ledger

  @spec status() :: map()
  def status do
    config = Configuration.get()

    available =
      cond do
        is_nil(config["model"]) ->
          {:error, :model_not_selected}

        config["provider"] == "ollama" ->
          Ollama.available(config)

        is_nil(config["cloud_consent"]) ->
          {:error, :cloud_consent_required}

        cloud_estimate_available(config) != :ok ->
          {:error, :cloud_cost_estimate_required}

        true ->
          Configuration.credential(config)
          |> case do
            {:ok, _} -> :ok
            error -> error
          end
      end

    %{
      "provider" => config["provider"],
      "endpoint" => config["endpoint"],
      "model" => config["model"],
      "credential_env" => config["credential_env"],
      "cloud_consent" => config["cloud_consent"],
      "input_microusd_per_million" => config["input_microusd_per_million"],
      "output_microusd_per_million" => config["output_microusd_per_million"],
      "local_only" => config["provider"] == "ollama",
      "availability" => if(available == :ok, do: "available", else: "unavailable"),
      "reason" =>
        case available do
          :ok -> nil
          {:error, reason} -> Atom.to_string(reason)
        end,
      "compatibility" =>
        if(Configuration.cloud_provider?(config["provider"]),
          do: "fixture_tested_live_unverified",
          else: "live_check_required"
        )
    }
  end

  @doc """
  Shared metered entry point returning generated text and reported/unknown usage.

  Optional `purpose` selects the server-owned `proposal` (default) or `chat`
  profile. Chat requires both `source_body` and `chat_context` data categories;
  cloud consent must explicitly cover them. Prompts are never persisted here.
  The caller validates the returned text against the selected canonical schema.
  """
  def infer(request, opts \\ []) do
    config = Configuration.get()

    with :ok <- HarnessForge.Workspaces.ensure_writable(),
         :ok <- validate_request(request, opts),
         request = canonical_request(request),
         :ok <- analysis_guard(config, request),
         true <- is_binary(config["model"]),
         :ok <- Configuration.authorize(config, request),
         :ok <- cloud_estimate_available(config),
         {:ok, credential} <- Configuration.credential(config),
         :ok <- authorize_sources(request["source_ids"]),
         input_bound =
           byte_size(request["prompt"]) + byte_size(Profile.system(request)) +
             byte_size(Contracts.canonical_json(Profile.schema(request))) + 1024,
         {:ok, reservation} <- Ledger.reserve(request, config, input_bound) do
      provider = provider(config["provider"])

      provider_opts = Keyword.put(opts, :dispatch_guard, fn -> request_guard(config, request) end)

      result =
        with :ok <- request_guard(config, request),
             do: provider.generate(config, request, credential, provider_opts)

      with {:ok, _} <- Ledger.reconcile(reservation, result, config),
           {:ok, _} <- Audit.append("model.request", %{"status" => request_state(result)}),
           :ok <- publication_guard(result, config, request) do
        case result do
          {:ok, output} ->
            known =
              is_integer(output.input_tokens) and output.input_tokens >= 0 and
                is_integer(output.output_tokens) and output.output_tokens >= 0

            if byte_size(output.text) > 131_072 or
                 (is_integer(output.output_tokens) and
                    output.output_tokens > request["max_output_tokens"]) do
              {:error, :model_output_limit_exceeded}
            else
              {:ok,
               %{
                 "text" => output.text,
                 "run_id" => request["run_id"],
                 "request_id" => request["request_id"],
                 "provider" => config["provider"],
                 "model" => config["model"],
                 "config_fingerprint" => Configuration.fingerprint(config),
                 "usage_status" => if(known, do: "reported", else: "unknown"),
                 "input_tokens" => if(known, do: output.input_tokens, else: nil),
                 "output_tokens" => if(known, do: output.output_tokens, else: nil),
                 "billing_status" =>
                   if(known,
                     do:
                       if(Configuration.cloud_provider?(config["provider"]),
                         do: "estimated",
                         else: "local_unpriced"
                       ),
                     else: "unknown"
                   )
               }}
            end

          error ->
            error
        end
      end
    else
      false -> {:error, :model_not_selected}
      error -> error
    end
  end

  @doc "Extract claims from one captured source revision and store them as proposed only."
  def propose(source_id, opts \\ []) do
    with {:ok, source} <- Evidence.get_source(source_id),
         :ok <- eligible_source(source),
         true <- byte_size(source["latest_revision"]["body"]) <= 65_536 do
      run_id = Keyword.get(opts, :run_id, "proposal-" <> Ecto.UUID.generate())
      request_id = Keyword.get(opts, :request_id, Ecto.UUID.generate())

      prompt =
        Contracts.canonical_json(%{
          "source_id" => source["id"],
          "revision_id" => source["latest_revision"]["id"],
          "body_byte_length" => byte_size(source["latest_revision"]["body"]),
          "available_citation_spans" => [
            %{"start_byte" => 0, "end_byte" => byte_size(source["latest_revision"]["body"])}
          ],
          "body" => source["latest_revision"]["body"]
        })

      budget =
        case Keyword.fetch(opts, :budget) do
          {:ok, limits} -> start_run(run_id, limits)
          :error -> reopen_run(run_id)
        end

      with {:ok, _} <- budget,
           {:ok, response} <-
             infer(
               %{
                 "run_id" => run_id,
                 "request_id" => request_id,
                 "prompt" => prompt,
                 "source_ids" => [source_id],
                 "data_categories" => ["source_body"],
                 "max_output_tokens" =>
                   Keyword.get(opts, :max_output_tokens, Proposal.default_output_tokens())
               },
               opts |> Keyword.take([:timeout]) |> Keyword.put_new(:timeout, 60_000)
             ),
           {:ok, validated} <- Proposal.validate(response["text"], source),
           {:ok, created} <- Proposal.persist(validated, source) do
        {:ok,
         response
         |> Map.delete("text")
         |> Map.put("claims", created)
         |> Map.put("rejected_claims", validated["rejected_count"])
         |> Map.put("status", "proposed")}
      end
    else
      false -> {:error, :model_input_too_large}
      error -> error
    end
  end

  defp validate_request(request, opts) when is_map(request) and is_list(opts) do
    extra =
      if request["purpose"] == "company_analysis",
        do: ~w(expected_config_fingerprint company_analysis_context),
        else: []

    valid =
      Enum.sort(Map.keys(Map.delete(request, "purpose"))) ==
        Enum.sort(
          ~w(run_id request_id prompt source_ids data_categories max_output_tokens) ++ extra
        ) and
        valid_purpose?(request) and
        Ledger.identifier?(request["run_id"]) and Ledger.identifier?(request["request_id"]) and
        is_binary(request["prompt"]) and byte_size(request["prompt"]) in 1..131_072 and
        String.valid?(request["prompt"]) and
        Configuration.strings?(request["source_ids"]) and
        Configuration.strings?(request["data_categories"]) and
        is_integer(request["max_output_tokens"]) and
        request["max_output_tokens"] in 1..output_token_limit(request) and
        Keyword.keys(opts) -- [:timeout] == [] and is_integer(Keyword.get(opts, :timeout, 30_000)) and
        Keyword.get(opts, :timeout, 30_000) in 1..60_000

    if valid, do: :ok, else: {:error, :invalid_model_request}
  end

  defp validate_request(_, _), do: {:error, :invalid_model_request}

  # Proposals alone need room for adaptive thinking; other purposes keep 4096.
  defp output_token_limit(request) do
    if Map.get(request, "purpose", "proposal") == "proposal",
      do: Proposal.max_output_tokens(),
      else: 4096
  end

  defp valid_purpose?(request) do
    case Map.get(request, "purpose", "proposal") do
      "proposal" ->
        true

      "chat" ->
        is_list(request["data_categories"]) and
          Enum.all?(~w(source_body chat_context), &(&1 in request["data_categories"]))

      "company_analysis" ->
        context = request["company_analysis_context"]

        is_map(context) and is_map(context["context"]) and
          HarnessForge.Evidence.Origin.valid_context?(context["context"]) and
          HarnessForge.Models.CompanyAnalysis.digest?(request["expected_config_fingerprint"]) and
          request["source_ids"] == Enum.map(context["context"]["sources"], & &1["source_id"]) and
          is_list(request["data_categories"]) and
          Enum.sort(request["data_categories"]) == Enum.sort(~w(source_body company_context))

      _ ->
        false
    end
  end

  # Explicit default and legacy requests share the same durable retry fence.
  defp canonical_request(%{"purpose" => "proposal"} = request), do: Map.delete(request, "purpose")
  defp canonical_request(request), do: request

  # This closure is installed internally only. It is never accepted from callers
  # or forwarded as a Req option. Every egress uses the captured verified config.
  defp analysis_guard(config, %{"purpose" => "company_analysis"} = request) do
    with true <- Configuration.fingerprint(config) == request["expected_config_fingerprint"],
         :ok <- Configuration.expect_fingerprint(request["expected_config_fingerprint"]),
         :ok <-
           HarnessForge.Company.Analysis.validate_context(request["company_analysis_context"]) do
      :ok
    else
      false -> {:error, :model_configuration_changed}
      error -> error
    end
  end

  defp analysis_guard(_, _), do: :ok

  # The HTTP adapter invokes this immediately before every actual request.
  # It adds no grant and holds no privacy/SQL lock across provider I/O.
  defp request_guard(config, request) do
    with :ok <- HarnessForge.Workspaces.ensure_writable(),
         :ok <- analysis_guard(config, request),
         :ok <- Configuration.authorize(config, request),
         :ok <- authorize_sources(request["source_ids"]),
         do: :ok
  end

  # Settle honest provider usage first, then refuse content that lost authority
  # while its already-admitted request was in flight.
  defp publication_guard({:ok, _}, config, request), do: request_guard(config, request)
  defp publication_guard(_, _, _), do: :ok

  defp authorize_sources(ids) do
    Enum.reduce_while(ids, :ok, fn id, :ok ->
      result =
        with :ok <- RevisionUseHolds.assert_source_unheld(id),
             do: Evidence.get_source(id)

      case result do
        {:ok, source} ->
          case eligible_source(source) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end

        error ->
          {:halt, error}
      end
    end)
  end

  defp eligible_source(%{
         "status" => "active",
         "latest_revision" => revision,
         "connection_id" => connection_id
       })
       when is_map(revision) do
    with {:ok, connections} <- Evidence.list_connections(),
         true <- Enum.any?(connections, &(&1["id"] == connection_id and &1["status"] == "active")) do
      :ok
    else
      _ -> {:error, :source_unavailable}
    end
  end

  defp eligible_source(_), do: {:error, :source_unavailable}
  defp cloud_estimate_available(%{"provider" => "ollama"}), do: :ok

  defp cloud_estimate_available(config) do
    if config["input_microusd_per_million"] > 0 and config["output_microusd_per_million"] > 0,
      do: :ok,
      else: {:error, :cloud_cost_estimate_required}
  end

  defp request_state({:ok, _}), do: "completed"
  defp request_state(_), do: "uncertain"

  defp provider("ollama"), do: Ollama
  defp provider("openai"), do: OpenAI
  defp provider("openai_responses"), do: OpenAIResponses
  defp provider("anthropic"), do: Anthropic
end
