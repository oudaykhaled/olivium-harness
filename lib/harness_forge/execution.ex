defmodule HarnessForge.Execution do
  @moduledoc "Trusted fixed-command sandbox boundary. No imported code is run on the host."
  alias HarnessForge.Execution.Docker

  defdelegate probe(), to: Docker
  defdelegate start(run_id, kind, config \\ %{}), to: Docker
  defdelegate inspect_owned(run_id), to: Docker
  defdelegate await(handle), to: Docker
  defdelegate cancel(run_id), to: Docker, as: :cleanup
  defdelegate cleanup(run_id), to: Docker
  defdelegate reconcile(), to: Docker
end
