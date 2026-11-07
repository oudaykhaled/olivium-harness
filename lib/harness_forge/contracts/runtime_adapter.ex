defmodule HarnessForge.Contracts.RuntimeAdapter do
  @moduledoc "Deterministic compilation only. Adapters must never execute repository tools."
  alias HarnessForge.Contracts.Error

  @typedoc "String keys: files (relative path to bytes), capabilities (list), diagnostics (list)."
  @type compilation :: %{required(String.t()) => term()}

  @callback probe(map()) :: {:ok, map()} | {:error, Error.t()}
  @callback capabilities(map(), map()) :: {:ok, [map()]} | {:error, Error.t()}
  @callback validate_intent(map(), map()) :: {:ok, map()} | {:error, Error.t()}
  @callback compile(map(), map()) :: {:ok, compilation()} | {:error, Error.t()}
end
