defmodule HarnessForge.Execution.CodexCommandPolicy do
  @moduledoc """
  Bounded admission of original native one-shot command arguments and context.

  This module neither executes nor translates tools. An admitted call still
  requires a correlated native approval, an exact operator decision, current
  run authority and verified native/container confinement.
  """
  alias HarnessForge.Contracts

  @argument_keys ~w(cmd workdir shell login timeout_ms max_output_tokens sandbox_permissions justification)
  @metadata_keys ~w(session_id x-codex-installation-id thread_id x-codex-window-id turn_id root_turn_id x-codex-turn-metadata)
  @nested_keys ~w(installation_id session_id thread_id agent_name turn_id window_id window_number context_window_id request_kind root_turn_id thread_source turn_trigger sandbox sandbox_mode auto_review_enabled node_repl_auto_review_required node_repl_disabled turn_started_at_unix_ms analytics_enabled model)
  @approval_keys ~w(kind threadId turnId itemId approvalId environmentId startedAtMs reason networkApprovalContext command cwd commandActions additionalPermissions proposedExecpolicyAmendment proposedNetworkPolicyAmendments availableDecisions)

  def arguments(bytes) when is_binary(bytes) and byte_size(bytes) in 1..8192 do
    with true <- String.valid?(bytes),
         {:ok, args} <- Contracts.decode_json(bytes),
         true <- exact_subset?(args, @argument_keys),
         true <- text?(args["cmd"], 4096),
         true <- optional(args, "workdir", &(&1 == "/candidate")),
         true <- optional(args, "shell", &(&1 == "/bin/bash")),
         true <- optional(args, "login", &(&1 == false)),
         true <- optional(args, "sandbox_permissions", &(&1 == "use_default")),
         true <- optional(args, "timeout_ms", &(is_integer(&1) and &1 in 1..10_000)),
         true <- optional(args, "max_output_tokens", &(is_integer(&1) and &1 in 1..2000)),
         true <- optional(args, "justification", &text?(&1, 512)) do
      {:ok, %{"arguments" => bytes, "arguments_digest" => Contracts.sha256(bytes)}}
    else
      _ -> {:error, :codex_command_arguments_rejected}
    end
  rescue
    _ -> {:error, :codex_command_arguments_rejected}
  end

  def arguments(_), do: {:error, :codex_command_arguments_rejected}

  @doc "Inert native request metadata is bounded and forwarded without semantic rewriting."
  def metadata(body) when is_map(body) do
    metadata = body["client_metadata"]

    with true <- exact_subset?(metadata, @metadata_keys),
         true <- byte_size(Jason.encode!(metadata)) <= 4096,
         true <- Enum.all?(metadata, fn {_, value} -> text?(value, 2048) end),
         true <- identifier?(metadata["thread_id"]) and identifier?(metadata["turn_id"]),
         true <- optional(metadata, "session_id", &(&1 == metadata["thread_id"])),
         true <- optional(metadata, "root_turn_id", &(&1 == metadata["turn_id"])),
         true <- optional(body, "prompt_cache_key", &identifier?/1),
         :ok <- nested_metadata(metadata, body["model"]) do
      {:ok, Map.take(metadata, ~w(thread_id turn_id))}
    else
      _ -> {:error, :codex_command_context_rejected}
    end
  rescue
    _ -> {:error, :codex_command_context_rejected}
  end

  def metadata(_), do: {:error, :codex_command_context_rejected}

  @doc "At most one original exec_command call may be published per native response."
  def response_calls(%{response_id: response_id, function_calls: calls}, body)
      when is_list(calls) and length(calls) <= 1 do
    with true <- identifier?(response_id),
         {:ok, context} <- metadata(body) do
      Enum.reduce_while(calls, {:ok, []}, fn call, {:ok, accepted} ->
        with true <- is_map(call) and call["type"] == "function_call",
             true <- call["name"] == "exec_command" and is_nil(call["namespace"]),
             true <- identifier?(call["call_id"]),
             {:ok, original} <- arguments(call["arguments"]) do
          record =
            context
            |> Map.merge(original)
            |> Map.merge(%{
              "call_id" => call["call_id"],
              "provider_response_id" => response_id
            })

          {:cont, {:ok, accepted ++ [record]}}
        else
          _ -> {:halt, {:error, :codex_command_arguments_rejected}}
        end
      end)
    else
      _ -> {:error, :codex_command_context_rejected}
    end
  end

  def response_calls(_, _), do: {:error, :codex_command_arguments_rejected}

  @doc "A new provider response cannot run alongside an unresolved earlier native command."
  def continuation(nil, _body), do: :ok

  def continuation(call, %{"input" => items}) when is_map(call) and is_list(items) do
    original? =
      Enum.any?(items, fn item ->
        is_map(item) and item["type"] == "function_call" and item["name"] == "exec_command" and
          item["call_id"] == call["call_id"] and item["arguments"] == call["arguments"] and
          is_nil(item["namespace"])
      end)

    result? =
      Enum.any?(items, fn item ->
        is_map(item) and item["type"] == "function_call_output" and
          item["call_id"] == call["call_id"]
      end)

    if original? and result?, do: :ok, else: {:error, :codex_command_context_rejected}
  end

  def continuation(_, _), do: {:error, :codex_command_context_rejected}

  @doc "Bind an original native callback to one server-admitted call; never infer authority from its display text."
  def approval(frame, context, call)
      when is_binary(frame) and byte_size(frame) in 1..16_384 and is_map(context) and is_map(call) do
    with {:ok, rpc} <- Contracts.decode_json(frame),
         true <- identifier?(context["thread_id"]) and identifier?(context["environment_id"]),
         true <- nonce?(context["driver_nonce"]),
         true <- identifier?(call["turn_id"]) and identifier?(call["provider_response_id"]),
         {:ok, original} <- arguments(call["arguments"]),
         true <- original["arguments_digest"] == call["arguments_digest"],
         true <- exact_subset?(rpc, ~w(id method params)),
         true <-
           Map.has_key?(rpc, "id") and rpc["method"] == "item/commandExecution/requestApproval",
         params = rpc["params"],
         true <- exact_subset?(params, @approval_keys),
         true <- params["kind"] == "command",
         true <-
           params["threadId"] == context["thread_id"] and params["threadId"] == call["thread_id"],
         true <- params["turnId"] == call["turn_id"],
         true <- params["itemId"] == call["call_id"],
         true <- params["environmentId"] == context["environment_id"],
         true <- is_nil(params["approvalId"]) and params["cwd"] == "/candidate",
         true <- text?(params["command"], 4096),
         true <-
           is_nil(params["additionalPermissions"]) and is_nil(params["networkApprovalContext"]),
         true <- params["proposedNetworkPolicyAmendments"] in [nil, []],
         true <- optional_advisory?(params),
         true <- is_nil(params["availableDecisions"]) or decisions?(params["availableDecisions"]),
         true <- is_nil(params["availableDecisions"]) or "accept" in params["availableDecisions"] do
      {:ok,
       %{
         "json_rpc_id" => rpc["id"],
         "thread_id" => params["threadId"],
         "turn_id" => params["turnId"],
         "item_id" => params["itemId"],
         "approval_id" => params["approvalId"],
         "environment_id" => params["environmentId"],
         "command" => params["command"],
         "cwd" => params["cwd"],
         "driver_nonce" => context["driver_nonce"],
         "provider_response_id" => call["provider_response_id"],
         "original_arguments" => call["arguments"],
         "original_arguments_digest" => call["arguments_digest"],
         "native_context_digest" => Contracts.sha256(frame)
       }}
    else
      _ -> {:error, :codex_command_approval_rejected}
    end
  rescue
    _ -> {:error, :codex_command_approval_rejected}
  end

  def approval(_, _, _), do: {:error, :codex_command_approval_rejected}

  defp optional_advisory?(params) do
    optional(params, "startedAtMs", &(is_integer(&1) and &1 in 0..9_007_199_254_740_991)) and
      (is_nil(params["reason"]) or text?(params["reason"], 1024)) and
      (is_nil(params["proposedExecpolicyAmendment"]) or
         (is_list(params["proposedExecpolicyAmendment"]) and
            length(params["proposedExecpolicyAmendment"]) <= 32 and
            Enum.all?(params["proposedExecpolicyAmendment"], &text?(&1, 256)))) and
      (is_nil(params["commandActions"]) or
         (is_list(params["commandActions"]) and length(params["commandActions"]) <= 32 and
            byte_size(Jason.encode!(params["commandActions"])) <= 4096))
  end

  defp decisions?(values),
    do:
      is_list(values) and values != [] and length(values) <= 4 and
        length(Enum.uniq(values)) == length(values) and
        Enum.all?(values, &(&1 in ~w(accept acceptForSession decline cancel)))

  defp nested_metadata(metadata, model) do
    case Map.fetch(metadata, "x-codex-turn-metadata") do
      :error ->
        :ok

      {:ok, bytes} ->
        with {:ok, nested} <- Contracts.decode_json(bytes),
             true <- exact_subset?(nested, @nested_keys),
             true <-
               Enum.all?(nested, fn {_, value} ->
                 is_boolean(value) or
                   (is_integer(value) and value in 0..9_007_199_254_740_991) or
                   text?(value, 512)
               end),
             true <- optional(nested, "thread_id", &(&1 == metadata["thread_id"])),
             true <- optional(nested, "session_id", &(&1 == metadata["thread_id"])),
             true <- optional(nested, "turn_id", &(&1 == metadata["turn_id"])),
             true <- optional(nested, "model", &(&1 == model)) do
          :ok
        else
          _ -> {:error, :codex_command_context_rejected}
        end
    end
  end

  defp optional(map, key, valid) do
    case Map.fetch(map, key) do
      :error -> true
      {:ok, value} -> valid.(value)
    end
  end

  defp exact_subset?(value, keys), do: is_map(value) and Map.keys(value) -- keys == []

  defp identifier?(value),
    do:
      is_binary(value) and byte_size(value) in 1..128 and
        Regex.match?(~r/\A[A-Za-z0-9_.:-]+\z/, value)

  defp nonce?(value),
    do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{32}\z/, value)

  defp text?(value, limit),
    do:
      is_binary(value) and byte_size(value) in 1..limit and String.valid?(value) and
        not Regex.match?(~r/[\x00-\x08\x0B-\x1F\x7F]/u, value)
end
