# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :harness_forge,
  ecto_repos: [HarnessForge.Repo],
  generators: [timestamp_type: :utc_datetime]

# Serialize SQLite writers and use its durable Lite queue engine.
config :harness_forge, HarnessForge.Repo,
  journal_mode: :wal,
  foreign_keys: :on,
  busy_timeout: 5_000

config :harness_forge, Oban,
  repo: HarnessForge.Repo,
  engine: Oban.Engines.Lite,
  queues: [default: 1],
  plugins: []

# Configure the endpoint
config :harness_forge, HarnessForgeWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: HarnessForgeWeb.ErrorHTML, json: HarnessForgeWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: HarnessForge.PubSub,
  live_view: [signing_salt: "EDRYVh0z"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  harness_forge: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.3",
  harness_forge: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
