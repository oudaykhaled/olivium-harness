defmodule HarnessForge.Contracts.Connector do
  @moduledoc "Trusted, compiled-in read-only connectors. Imported text is data, never authority."
  alias HarnessForge.Contracts.Error

  @type context :: %{required(String.t()) => term()}
  @typedoc "String-key page: items (bounded list), next_cursor (string or nil), complete (boolean)."
  @type page :: %{required(String.t()) => term()}

  @callback validate_config(map()) :: {:ok, map()} | {:error, Error.t()}
  @callback capabilities() :: map()
  @callback fetch_page(map(), String.t() | nil, context()) :: {:ok, page()} | {:error, Error.t()}
end
