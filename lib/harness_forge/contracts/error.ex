defmodule HarnessForge.Contracts.Error do
  @moduledoc "A safe boundary error. Details must never contain credentials or raw provider bodies."
  @enforce_keys [:code, :message]
  defstruct [:code, :message, :correlation_id, retryable: false, details: []]

  @type t :: %__MODULE__{
          code: String.t(),
          message: String.t(),
          correlation_id: String.t() | nil,
          retryable: boolean(),
          details: [String.t()]
        }
end
