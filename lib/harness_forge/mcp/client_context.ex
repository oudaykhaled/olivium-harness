defmodule HarnessForge.MCP.ClientContext do
  import Kernel, except: [binding: 1]

  @moduledoc "Server-resolved machine authority, separate from an operator session. Never accepted as JSON input."
  alias HarnessForge.{Contracts}
  alias HarnessForge.MCP.{Clients, DisclosureGrants}

  @enforce_keys [
    :client_id,
    :client_generation,
    :token_hash,
    :grant_id,
    :grant_generation,
    :grant_digest,
    :scope,
    :profile
  ]
  defstruct @enforce_keys

  def authorize(%__MODULE__{} = context) do
    with :ok <- Clients.current?(context), do: DisclosureGrants.validate(context)
  rescue
    _ -> {:error, :client_grant_unavailable}
  end

  def authorize(_), do: {:error, :client_grant_unavailable}

  def binding(%__MODULE__{} = context),
    do: %{
      "version" => "ClientInspectionContext.v1",
      "client_id" => context.client_id,
      "client_generation" => context.client_generation,
      "grant_id" => context.grant_id,
      "grant_generation" => context.grant_generation,
      "grant_digest" => context.grant_digest,
      "scope" => context.scope,
      "profile" => context.profile
    }

  def digest(%__MODULE__{} = context), do: Contracts.digest(binding(context))

  def assert_scope(%__MODULE__{} = context, attrs) do
    expected = Map.take(context.scope, ~w(corpus_id project_id goal_id goal_hash))

    if Map.take(attrs, Map.keys(expected)) == expected and
         Map.get(attrs, "expected_generation", context.scope["semantic_generation"]) ==
           context.scope["semantic_generation"],
       do: :ok,
       else: {:error, :client_grant_unavailable}
  end
end
