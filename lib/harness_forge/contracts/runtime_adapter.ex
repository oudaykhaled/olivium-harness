defmodule HarnessForge.Contracts.RuntimeAdapter do
  @moduledoc "Deterministic compilation only. Adapters must never execute repository tools."
  alias HarnessForge.Contracts.Error

  @typedoc "String keys: files (relative path to bytes), capabilities (list), diagnostics (list)."
  @type compilation :: %{required(String.t()) => term()}

  @callback probe(map()) :: {:ok, map()} | {:error, Error.t()}
  @callback capabilities(map(), map()) :: {:ok, [map()]} | {:error, Error.t()}
  @callback validate_intent(map(), map()) :: {:ok, map()} | {:error, Error.t()}
  @callback compile(map(), map()) :: {:ok, compilation()} | {:error, Error.t()}

  @doc """
  Render a validated `harnessforge.dev/v1alpha2` spec. Same return shape as `compile/2`.
  An adapter without this callback is an `unsupported_target` for v1alpha2.
  """
  @callback compile_v2(map(), map()) :: {:ok, compilation()} | {:error, Error.t()}

  @doc "Adapter identity recorded for v1alpha2. Defaults to `identity/0` when absent."
  @callback identity_v2() :: map()

  @optional_callbacks compile_v2: 2, identity_v2: 0
end
