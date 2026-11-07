defmodule HarnessForge.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      HarnessForge.Workspaces,
      HarnessForgeWeb.Telemetry,
      HarnessForge.Repo,
      HarnessForge.StartupGate,
      {Phoenix.PubSub, name: HarnessForge.PubSub},
      {Task.Supervisor, name: HarnessForge.Tasks},
      {HarnessForge.Evidence.Capture.Scanner, []},
      {HarnessForge.Graphiti.Runtime, []},
      {Oban, Application.fetch_env!(:harness_forge, Oban)},
      # Start to serve requests, typically the last entry
      HarnessForgeWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :rest_for_one, name: HarnessForge.Supervisor]
    case Supervisor.start_link(children, opts) do
      {:ok, supervisor} = started ->
        case HarnessForge.Evidence.LocalUseLifecycle.wake_pending() do
          :ok -> started
          {:error, reason} ->
            Supervisor.stop(supervisor)
            {:error, {:local_use_cleanup_unavailable, reason}}
        end

      error -> error
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    HarnessForgeWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
