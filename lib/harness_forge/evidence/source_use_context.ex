defmodule HarnessForge.Evidence.SourceUseContext do
  @moduledoc """
  Explicit in-memory source-use admission context. Neither this struct nor a
  reference is authority: every validation checks the genuine operator session,
  original caller and, for setup analysis, its persisted operation binding.
  Never serialize this context into jobs, commands, receipts or logs.
  """
  alias HarnessForge.{Contracts, Workspaces}
  alias HarnessForge.Company.AssessmentAttempts
  alias HarnessForge.Evidence.Corpora
  alias HarnessForge.Models.RunAuthorization

  @enforce_keys [:kind, :operator_auth, :caller]
  defstruct [:kind, :operator_auth, :caller, :operation_ref, :authorization_ref]
  @fields [:__struct__, :kind, :operator_auth, :caller, :operation_ref, :authorization_ref]
  @purposes ~w(inspection retrieval analysis compile)

  @type t :: %__MODULE__{kind: :interactive | :setup_analysis, operator_auth: map(),
    caller: keyword(), operation_ref: map() | nil, authorization_ref: map() | nil}

  @spec interactive(term(), term()) :: {:ok, t()} | {:error, atom()}
  def interactive(auth, caller) do
    context = %__MODULE__{kind: :interactive, operator_auth: auth, caller: caller}
    with {:ok, _} <- validate(context, "inspection"), do: {:ok, context}
  end

  @spec setup_analysis(t(), map(), map()) :: {:ok, t()} | {:error, atom()}
  def setup_analysis(%__MODULE__{kind: :interactive} = context, operation, authorization) do
    with {:ok, _} <- validate(context, "inspection"),
         true <- ref?(operation) and ref?(authorization),
         bound = %{context | kind: :setup_analysis, operation_ref: operation,
           authorization_ref: authorization},
         {:ok, _} <- validate(bound, "analysis") do
      {:ok, bound}
    else
      false -> {:error, :source_context_invalid}
      error -> error
    end
  end
  def setup_analysis(_, _, _), do: {:error, :source_context_invalid}

  @spec validate(term(), term()) :: {:ok, map()} | {:error, atom()}
  def validate(nil, _), do: {:error, :source_context_required}
  def validate(%__MODULE__{} = context, purpose) do
    with true <- Enum.sort(Map.keys(context)) == Enum.sort(@fields) and purpose in @purposes,
         :ok <- Corpora.keys(context.operator_auth, ~w(workspace_id epoch issued_at)),
         {:ok, identity} <- Workspaces.authenticate_operator(context.operator_auth),
         :ok <- AssessmentAttempts.options(context.caller),
         true <- context.caller[:session_fingerprint] == Contracts.digest(context.operator_auth),
         :ok <- AssessmentAttempts.authorize(context.caller),
         true <- identity.workspace_id == Workspaces.current_id() and
           identity.owner_id == Workspaces.operator(),
         {:ok, bound} <- bound(context, purpose),
         :ok <- AssessmentAttempts.authorize(context.caller),
         {:ok, ^identity} <- Workspaces.authenticate_operator(context.operator_auth) do
      {:ok, Map.merge(identity, bound)}
    else
      _ -> {:error, :source_context_invalid}
    end
  rescue
    _ -> {:error, :source_context_invalid}
  catch
    _, _ -> {:error, :source_context_invalid}
  end
  def validate(_, _), do: {:error, :source_context_invalid}

  @spec match_caller(term(), term()) :: :ok | {:error, atom()}
  def match_caller(nil, caller) do
    with :ok <- AssessmentAttempts.options(caller),
         :ok <- AssessmentAttempts.authorize(caller), do: :ok
  end
  def match_caller(%__MODULE__{} = context, caller) do
    purpose = if context.kind == :setup_analysis, do: "analysis", else: "inspection"
    with true <- context.caller === caller,
         {:ok, _} <- validate(context, purpose), do: :ok,
      else: (_ -> {:error, :source_context_invalid})
  end
  def match_caller(_, _), do: {:error, :source_context_invalid}

  defp bound(%{kind: :interactive, operation_ref: nil, authorization_ref: nil}, _purpose),
    do: {:ok, %{kind: :interactive, manifest_ref: nil, operation_ref: nil, authorization_ref: nil}}
  defp bound(%{kind: :setup_analysis} = context, "analysis") do
    with true <- ref?(context.operation_ref) and ref?(context.authorization_ref),
         {:ok, result} <- RunAuthorization.source_use_binding(
           context.authorization_ref, context.operation_ref, context.caller),
         true <- result.workspace_id == Workspaces.current_id() and
           result.owner_id == Workspaces.operator() and ref?(result.manifest_ref) and
           result.operation_ref == context.operation_ref and
           result.authorization_ref == context.authorization_ref do
      {:ok, Map.put(result, :kind, :setup_analysis)}
    else
      _ -> {:error, :source_context_invalid}
    end
  end
  defp bound(_, _), do: {:error, :source_context_invalid}
  defp ref?(ref), do: Corpora.keys(ref, ~w(id digest)) == :ok and
    Corpora.uuid?(ref["id"]) and Corpora.digest?(ref["digest"])
end
