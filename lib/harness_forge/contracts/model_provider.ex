defmodule HarnessForge.Contracts.ModelProvider do
  @moduledoc "A bounded model call with explicit destination and no implicit fallback."
  alias HarnessForge.Contracts.Error

  @typedoc "String keys: request_id, model, messages, max_output_tokens, timeout_seconds."
  @type request :: %{required(String.t()) => term()}

  @callback capabilities() :: map()
  @callback generate(request(), map()) :: {:ok, map()} | {:error, Error.t()}
  @callback cancel(String.t(), map()) :: :ok | {:error, Error.t()}
end
