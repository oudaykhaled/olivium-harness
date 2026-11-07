defmodule HarnessForge.Chat do
  @moduledoc """
  Ephemeral, read-only conversation over live account metadata and captured evidence.

  Local evidence lookup never dispatches inference. Model answers use the shared
  metered inference boundary and exact source consent. The default assistant routes
  supported inventory questions to compiled account reads. Chat never synchronizes
  sources, creates claims, writes to providers, or grants execution authority.
  """
  alias HarnessForge.{Contracts, Models, Workspaces}
  alias HarnessForge.Chat.{Intent, Output, Retrieval, Snapshot}
  alias HarnessForge.Models.Configuration

  @spec catalog() :: {:ok, map()} | {:error, atom()}
  def catalog do
    with {:ok, catalog} <- Snapshot.catalog(),
         {:ok, accounts} <- HarnessForge.Accounts.catalog() do
      {:ok, Map.put(catalog, "accounts", accounts)}
    end
  end

  @spec ask(String.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def ask(question, opts \\ []) do
    with :ok <- validate_question(question),
         :ok <- validate_options(opts),
         :ok <- Workspaces.ensure_writable() do
      mode = Keyword.get(opts, :mode, :assistant)

      case {mode, Intent.parse(question)} do
        {:assistant, {:live, operation, args}} ->
          HarnessForge.Accounts.query(operation, args)

        {:assistant, {:error, reason}} ->
          {:error, reason}

        {:evidence, {:live, _, _}} ->
          {:error, :live_request_requires_assistant}

        {:model, {:live, _, _}} ->
          {:error, :live_request_requires_assistant}

        _ ->
          captured_answer(
            question,
            Keyword.put(opts, :mode, if(mode == :assistant, do: :evidence, else: mode))
          )
      end
    end
  end

  defp captured_answer(question, opts) do
    with mode = Keyword.fetch!(opts, :mode),
         {:ok, allowed_ids, fingerprint} <- allowed_sources(mode),
         history = Keyword.get(opts, :history, []),
         {:ok, citations, prompt} <- Retrieval.retrieve(question, history, allowed_ids),
         scope = Snapshot.scope(citations, fingerprint),
         true <- Snapshot.current?(scope),
         {:ok, reply} <- answer(mode, citations, prompt, scope, opts),
         true <- valid?(reply) do
      {:ok, reply}
    else
      false -> {:error, :stale_chat_context}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :chat_unavailable}
    end
  end

  @doc "Revalidate an in-memory answer before display, including uncited model context."
  @spec valid?(term()) :: boolean()
  def valid?(reply), do: valid_many?([reply])

  @doc "Validate up to ten in-memory replies using one current snapshot per unique source."
  @spec valid_many?(term()) :: boolean()
  def valid_many?([]), do: true

  def valid_many?(replies) when is_list(replies) and length(replies) <= 10 do
    {live, captured} = Enum.split_with(replies, &(is_map(&1) && &1["mode"] == "live"))
    Enum.all?(live, &HarnessForge.Accounts.valid?/1) and valid_captured?(captured)
  rescue
    _ -> false
  end

  def valid_many?(_), do: false

  defp valid_captured?([]), do: true

  defp valid_captured?(replies) do
    with true <- Enum.all?(replies, &sealed_reply?/1),
         refs =
           Enum.flat_map(
             replies,
             &(&1["_scope"]["context"] ++
                 Enum.map(&1["citations"], fn c -> Snapshot.context_ref(c) end))
           ),
         {:ok, snapshot} <- Snapshot.capture(refs) do
      Enum.all?(replies, fn reply ->
        Snapshot.current?(reply["_scope"], snapshot) and
          Enum.all?(reply["citations"], &Snapshot.citation_current?(&1, snapshot))
      end)
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  defp sealed_reply?(reply) when is_map(reply) do
    scope = reply["_scope"]
    payload = Map.delete(reply, "_scope")

    is_map(scope) and is_list(scope["context"]) and length(scope["context"]) <= 12 and
      Enum.all?(scope["context"], &is_map/1) and is_list(reply["citations"]) and
      length(reply["citations"]) <= 12 and Enum.all?(reply["citations"], &is_map/1) and
      scope["reply_digest"] ==
        Contracts.digest(%{"reply" => payload, "scope" => Map.delete(scope, "reply_digest")})
  end

  defp sealed_reply?(_), do: false

  defp allowed_sources(:evidence), do: {:ok, :all, nil}

  defp allowed_sources(:model) do
    config = Configuration.get()

    cond do
      not is_binary(config["model"]) -> {:error, :model_not_selected}
      config["provider"] == "ollama" -> {:ok, :all, Snapshot.fingerprint()}
      not Snapshot.chat_consent?(config) -> {:error, :chat_context_consent_required}
      true -> {:ok, config["cloud_consent"]["source_ids"], Snapshot.fingerprint()}
    end
  end

  defp answer(_, [], _prompt, scope, opts) do
    {:ok,
     seal(
       %{
         "mode" => "evidence",
         "answer" =>
           "No matching captured evidence was found in the selected scope. Connect or explicitly sync a source, then ask again. This local lookup made no model request.",
         "citations" => [],
         "reason" => "no_matching_evidence",
         "run_id" => Keyword.get(opts, :run_id),
         "request_id" => Keyword.get(opts, :request_id),
         "provider" => nil,
         "model" => nil,
         "limits" => limits()
       },
       scope
     )}
  end

  defp answer(:evidence, citations, _prompt, scope, opts) do
    text =
      Enum.map_join(citations, "\n\n", fn citation ->
        "[#{citation["id"]}] #{citation["title"]}\n#{citation["snippet"]}"
      end)

    {:ok,
     seal(
       %{
         "mode" => "evidence",
         "answer" => "Captured excerpts matching your question (local lookup):\n\n" <> text,
         "citations" => citations,
         "run_id" => Keyword.get(opts, :run_id),
         "request_id" => Keyword.get(opts, :request_id),
         "provider" => nil,
         "model" => nil,
         "limits" => limits()
       },
       scope
     )}
  end

  defp answer(:model, citations, prompt, scope, opts) do
    run = Keyword.get(opts, :run_id) || Ecto.UUID.generate()
    request_id = Keyword.get(opts, :request_id) || Ecto.UUID.generate()
    config = Configuration.get()

    request = %{
      "purpose" => "chat",
      "run_id" => run,
      "request_id" => request_id,
      "prompt" => prompt,
      "source_ids" => Enum.map(citations, & &1["source_id"]),
      "data_categories" => ~w(source_body chat_context),
      "max_output_tokens" => 2048
    }

    with true <- Snapshot.current?(scope),
         {:ok, _} <- Models.reopen_run(run),
         true <- Snapshot.current?(scope),
         {:ok, output} <- Models.infer(request),
         true <- Snapshot.current?(scope),
         {:ok, answer, selected} <- Output.validate(output["text"], citations) do
      reply = %{
        "mode" => "model",
        "answer" => answer,
        "citations" => selected,
        "run_id" => run,
        "request_id" => request_id,
        "provider" => config["provider"],
        "model" => config["model"],
        "usage_status" => output["usage_status"],
        "billing_status" => output["billing_status"],
        "limits" => limits()
      }

      {:ok, seal(reply, scope)}
    else
      false ->
        {:error, :stale_chat_context}

      {:error, reason} = error when reason in [:source_unavailable, :revision_use_denied] ->
        if Snapshot.current?(scope), do: error, else: {:error, :stale_chat_context}

      error ->
        error
    end
  end

  defp seal(reply, scope) do
    digest = Contracts.digest(%{"reply" => reply, "scope" => scope})
    Map.put(reply, "_scope", Map.put(scope, "reply_digest", digest))
  end

  defp limits do
    %{
      "max_excerpts" => 12,
      "max_context_bytes" => 24_576,
      "remote_acl_checked" => false,
      "automatic_sync" => false,
      "tool_execution" => false,
      "claim_authority" => false
    }
  end

  defp validate_question(question) when is_binary(question) and byte_size(question) in 1..4000 do
    if String.valid?(question) and String.trim(question) != "" and
         not String.contains?(question, <<0>>),
       do: :ok,
       else: {:error, :invalid_question}
  end

  defp validate_question(_), do: {:error, :invalid_question}

  defp validate_options(opts) when is_list(opts) do
    valid =
      Keyword.keyword?(opts) and
        Keyword.keys(opts) -- [:mode, :history, :run_id, :request_id] == [] and
        Keyword.get(opts, :mode, :assistant) in [:assistant, :evidence, :model] and
        valid_history?(opts) and
        Enum.all?([:run_id, :request_id], &valid_uuid?(Keyword.get(opts, &1)))

    if valid, do: :ok, else: {:error, :invalid_chat_options}
  end

  defp validate_options(_), do: {:error, :invalid_chat_options}

  defp valid_history?(opts) do
    history = Keyword.get(opts, :history, [])

    is_list(history) and length(history) <= 4 and
      Enum.all?(history, &(validate_question(&1) == :ok))
  end

  defp valid_uuid?(nil), do: true
  defp valid_uuid?(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
end
