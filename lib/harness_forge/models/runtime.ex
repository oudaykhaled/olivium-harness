defmodule HarnessForge.Models.Runtime do
  @moduledoc """
  Bounded coding chat for a snapshotted, explicitly selected Ollama model.

  This boundary shares authoring's durable Ledger; it never runs tools. Source
  scope and data categories are fixed by the trusted caller, never by chat JSON.
  A loopback endpoint is an operator trust assumption, not proof that a service
  computes locally. Remote model metadata is rejected and cloud has no fallback.
  """
  alias HarnessForge.{Audit, Contracts, Evidence, Workspaces}
  alias HarnessForge.Evidence.{RevisionUseHolds, LocalUsePolicies}

  alias HarnessForge.Models.{
    CodexProtocol,
    Configuration,
    HTTP,
    Ledger,
    LocalModelIdentity,
    Ollama,
    RuntimeProtocol
  }

  @categories ~w(harness_artifact task_prompt repository_content tool_result)
  @attempt_ceiling_ms 60_000
  @settlement_headroom_ms 2_000

  def prepare(run_id, opts \\ []), do: prepare(run_id, opts, nil)

  def prepare(run_id, opts, source_context) do
    config = Configuration.get()
    sources = Keyword.get(opts, :source_ids, [])
    categories = Keyword.get(opts, :data_categories, @categories)
    output = Keyword.get(opts, :max_output_tokens, 4096)
    timeout = Keyword.get(opts, :timeout, 30_000)
    protocol = Keyword.get(opts, :protocol, :chat)
    native_commands = Keyword.get(opts, :native_commands, false)
    authorize = Keyword.get(opts, :authorize, fn -> :ok end)
    relay_deadline = Keyword.get(opts, :deadline_ms)

    with :ok <- Workspaces.ensure_writable(),
         true <-
           Keyword.keys(opts) --
             [
               :source_ids,
               :data_categories,
               :max_output_tokens,
               :timeout,
               :budget,
               :protocol,
               :codex_tools,
               :native_commands,
               :authorize,
               :deadline_ms
             ] == [],
         true <- protocol in [:chat, :codex_responses] and is_function(authorize, 0),
         true <-
           is_boolean(native_commands) and (not native_commands or protocol == :codex_responses),
         true <- is_nil(relay_deadline) or is_integer(relay_deadline),
         true <- protocol == :codex_responses or not Keyword.has_key?(opts, :codex_tools),
         true <- Ledger.identifier?(run_id) and Configuration.strings?(sources),
         true <-
           is_list(categories) and categories != [] and
             Enum.all?(categories, &(&1 in @categories)),
         true <- is_integer(output) and output in 1..4096,
         true <- is_integer(timeout) and timeout in 1..60_000,
         :ok <- HarnessForge.Models.RunAuthorization.legacy_budget_allowed(run_id),
         :ok <- local_config(config),
         :ok <- authorize_sources(sources, source_context),
         :ok <- authorize.(),
         :ok <- availability(protocol, config),
         {:ok, tools, identity} <- prepare_protocol(protocol, config, opts),
         true <- not native_commands or command_tools?(tools),
         {:ok, limits} <- runtime_budget_limits(run_id, opts),
         {:ok, _} <- Ledger.start_run(run_id, limits) do
      {:ok,
       %{
         run_id: run_id,
         config: config,
         config_fingerprint: Configuration.fingerprint(config),
         protocol: protocol,
         native_commands: native_commands,
         authorize: authorize,
         deadline_ms: relay_deadline,
         codex_tools: tools,
         model_identity: identity,
         source_ids: Enum.uniq(sources),
          source_context: source_context,
         data_categories: Enum.uniq(categories),
         max_output_tokens: output,
         timeout: timeout
       }}
    else
      false -> {:error, :invalid_runtime_configuration}
      error -> error
    end
  end

  # Reopening a legacy runtime preserves an already allocated budget. Explicit
  # limits still pass through Ledger's exact-cap check and cannot enlarge it.
  defp runtime_budget_limits(run_id, opts) do
    case Keyword.fetch(opts, :budget) do
      {:ok, limits} ->
        {:ok, limits}

      :error ->
        case Ledger.budget(run_id) do
          {:ok, budget} ->
            {:ok, Map.take(budget, ["max_requests", "max_tokens", "max_estimated_microusd"])}

          {:error, :budget_not_found} ->
            {:ok, Ledger.defaults()}

          error ->
            error
        end
    end
  end

  @doc "Dispatch one chat attempt; every HTTP retry obtains a new durable reservation."
  def chat(scope, body) do
    with true <- Map.get(scope, :protocol, :chat) == :chat,
         :ok <- Workspaces.ensure_writable(),
         :ok <- local_config(scope.config),
         :ok <- authorize_sources(scope.source_ids, Map.get(scope, :source_context)),
         {:ok, payload, stream?} <- RuntimeProtocol.request(body, scope),
         prompt = Contracts.canonical_json(payload),
         request = %{
           "run_id" => scope.run_id,
           "request_id" => Ecto.UUID.generate(),
           "prompt" => prompt,
           "source_ids" => scope.source_ids,
           "data_categories" => scope.data_categories,
           "max_output_tokens" => payload["options"]["num_predict"]
         },
         :ok <- Configuration.authorize(scope.config, request),
         {:ok, reservation} <- Ledger.reserve(request, scope.config, byte_size(prompt) + 1024) do
      dispatch_opts = [timeout: scope.timeout, dispatch_guard: fn -> current_sources(scope) end]

      result =
        with :ok <- Ollama.available(scope.config, dispatch_opts),
             {:ok, response} <-
               HTTP.request(
                 :post,
                 scope.config["endpoint"] <> "/api/chat",
                 payload,
                 [],
                 dispatch_opts
               ),
             {:ok, output} <- RuntimeProtocol.response(response, payload) do
          {:ok, output}
        end

      with {:ok, _} <- Ledger.reconcile(reservation, result, scope.config),
           {:ok, _} <-
             Audit.append("model.runtime_request", %{
               "status" => if(match?({:ok, _}, result), do: "completed", else: "uncertain")
             }) do
        case result do
          {:ok, output} ->
            with :ok <- current_sources(scope),
                 do: {:ok, RuntimeProtocol.completion(output, scope.config["model"], stream?)}

          error ->
            error
        end
      end
    end
  end

  @doc "One metered native Responses attempt; original SSE is published only after complete verification."
  def responses(%{protocol: :codex_responses} = scope, body) do
    scope = attempt_scope(scope)

    with :ok <- current_sources(scope),
         {:ok, payload} <- CodexProtocol.request(body, scope),
         prompt = Contracts.canonical_json(payload),
         request = %{
           "run_id" => scope.run_id,
           "request_id" => Ecto.UUID.generate(),
           "protocol" => "ollama-native-responses-v1",
           "model_identity" => scope.model_identity,
           "prompt" => prompt,
           "source_ids" => scope.source_ids,
           "data_categories" => scope.data_categories,
           "max_output_tokens" => payload["max_output_tokens"]
         },
         :ok <- Configuration.authorize(scope.config, request),
         {:ok, reservation} <- Ledger.reserve(request, scope.config, byte_size(prompt) + 1024) do
      result = dispatch_responses(scope, prompt, payload)

      with {:ok, _} <- Ledger.reconcile(reservation, result, scope.config),
           {:ok, _} <-
             Audit.append("model.runtime_request", %{
               "status" => if(match?({:ok, _}, result), do: "completed", else: "uncertain")
             }) do
        case result do
          {:ok, output} ->
            with :ok <- current_identity(scope, scope.attempt_deadline_ms),
                 do: publish_responses(scope, output, payload)

          error ->
            error
        end
      end
    end
  end

  def responses(_, _), do: {:error, :invalid_runtime_request}

  @doc false
  def authorize(scope), do: current_sources(scope)

  defp publish_responses(%{native_commands: true}, output, payload) do
    with {:ok, calls} <- HarnessForge.Execution.CodexCommandPolicy.response_calls(output, payload),
         do: {:ok, {:sse, output.bytes}, calls}
  end

  defp publish_responses(_, output, _payload), do: {:ok, {:sse, output.bytes}}

  defp command_tools?([%{"type" => "function", "name" => "exec_command"}]), do: true
  defp command_tools?(_), do: false

  defp dispatch_responses(scope, bytes, payload) do
    with :ok <- before_deadline(scope.io_deadline_ms),
         {:ok, raw} <-
           HTTP.request_responses(scope.config["endpoint"] <> "/v1/responses", bytes,
             timeout: scope.timeout,
             deadline_ms: scope.io_deadline_ms,
             dispatch_guard: fn -> current_identity(scope, scope.io_deadline_ms) end
           ),
         {:ok, result} <- CodexProtocol.response(raw, payload),
         do: {:ok, result}
  rescue
    _ -> {:error, :invalid_runtime_response}
  end

  defp prepare_protocol(:chat, _, _), do: {:ok, [], nil}

  defp prepare_protocol(:codex_responses, config, opts) do
    deadline =
      min_deadline(now_ms() + 2_000, Keyword.get(opts, :deadline_ms), @settlement_headroom_ms)

    with {:ok, tools} <- CodexProtocol.tool_scope(Keyword.get(opts, :codex_tools, [])),
         {:ok, identity} <-
           LocalModelIdentity.observe(config,
             deadline_ms: deadline,
             dispatch_guard: Keyword.get(opts, :authorize, fn -> :ok end)
           ),
         do: {:ok, tools, identity}
  end

  defp availability(:chat, config), do: Ollama.available(config)
  defp availability(:codex_responses, _), do: :ok

  defp current_identity(scope, deadline) do
    with :ok <- current_sources(scope),
         :ok <- before_deadline(deadline),
         :ok <-
           LocalModelIdentity.revalidate(scope.config, scope.model_identity,
             deadline_ms: deadline,
             dispatch_guard: fn -> current_sources(scope) end
           ),
         :ok <- before_deadline(deadline),
         do: current_sources(scope)
  end

  defp attempt_scope(scope) do
    # Both metadata and inference consume this one transport budget. Leave a
    # fixed two seconds for durable settlement and final identity publication
    # checks, and at least five seconds below the outer 65-second call at max.
    desired = now_ms() + min(scope.timeout + @settlement_headroom_ms, @attempt_ceiling_ms)
    deadline = min_deadline(desired, Map.get(scope, :deadline_ms), @settlement_headroom_ms)

    Map.merge(scope, %{
      attempt_deadline_ms: deadline,
      io_deadline_ms: deadline - @settlement_headroom_ms
    })
  end

  defp min_deadline(desired, nil, _), do: desired
  defp min_deadline(desired, outer, headroom), do: min(desired, outer - headroom)
  defp now_ms, do: System.monotonic_time(:millisecond)

  defp before_deadline(deadline) when is_integer(deadline) do
    if now_ms() < deadline, do: :ok, else: {:error, :model_deadline_exceeded}
  end

  defp local_config(%{"provider" => "ollama", "model" => model} = config) when is_binary(model) do
    with {:ok, endpoint} <- Configuration.endpoint("ollama", config["endpoint"]),
         true <- endpoint == config["endpoint"],
         :ok <- Configuration.authorize(config, %{}) do
      :ok
    else
      false -> {:error, :unsafe_model_endpoint}
      error -> error
    end
  end

  defp local_config(%{"provider" => "ollama"}), do: {:error, :model_not_selected}
  defp local_config(_), do: {:error, :runtime_cloud_disabled}

  # Final send admission and post-settlement publication share the existing
  # source authority. Never hold a database/privacy fence through provider I/O.
  defp current_sources(scope) do
    with :ok <- current_deadline(scope),
         :ok <- Workspaces.ensure_writable(),
         :ok <- local_config(scope.config),
         :ok <- Configuration.expect_fingerprint(scope.config_fingerprint),
         :ok <- authorize_sources(scope.source_ids),
         :ok <- scope.authorize.(),
         do: current_deadline(scope)
  rescue
    _ -> {:error, :runtime_authority_unavailable}
  end

  defp current_deadline(%{attempt_deadline_ms: deadline}), do: before_deadline(deadline)
  defp current_deadline(_), do: :ok

  defp authorize_sources(ids, source_context) do
    with {:ok, {policy_sql, policy_params}} <- LocalUsePolicies.not_denied_sql("r", "analysis", source_context),
         {:ok, connections} <- Evidence.list_connections() do
      Enum.reduce_while(ids, :ok, fn id, :ok ->
        result = with :ok <- RevisionUseHolds.assert_source_unheld(id),
          {:ok, %{rows: [[revision, hash]]}} <- HarnessForge.Repo.query(
            "SELECT r.id,r.body_hash FROM evidence_sources s JOIN evidence_revisions r ON r.id=s.latest_revision_id AND r.source_id=s.id AND r.workspace_id=s.workspace_id WHERE s.workspace_id=? AND s.id=? AND (#{policy_sql})",
            [HarnessForge.Evidence.Store.workspace(), id] ++ policy_params, log: false),
          allowed when allowed in [:ok, :legacy_unknown] <- LocalUsePolicies.assert_use(
            %{"source_id" => id, "revision_id" => revision, "body_hash" => hash}, "analysis", source_context),
          do: Evidence.get_source(id, source_context)

        case result do
          {:ok, %{"status" => "active", "latest_revision" => revision, "connection_id" => cid}} when is_map(revision) ->
            if Enum.any?(connections, &(&1["id"] == cid and &1["status"] == "active")),
              do: {:cont, :ok}, else: {:halt, {:error, :source_unavailable}}
          {:error, reason} when reason in [:revision_use_denied, :revision_use_state_unavailable] -> {:halt, {:error, reason}}
          _ -> {:halt, {:error, :source_unavailable}}
        end
      end)
    end
  end
end
