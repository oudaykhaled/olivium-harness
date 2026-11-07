import Config

workspace_root =
  System.get_env("HARNESSFORGE_WORKSPACE") ||
    if config_env() == :test do
      Path.join(File.cwd!(), "tmp/workspaces/test-#{System.pid()}")
    else
      Path.join(System.user_home!(), ".local/share/harnessforge/default")
    end

workspace_root = Path.expand(workspace_root)
File.mkdir_p!(workspace_root)
File.chmod!(workspace_root, 0o700)
port = if config_env() == :test, do: 4002, else: String.to_integer(System.get_env("PORT", "8865"))
origins = ["http://localhost:#{port}", "http://127.0.0.1:#{port}"]

config :harness_forge,
  workspace_root: workspace_root,
  allowed_origins: origins,
  mcp_enabled: System.get_env("HARNESSFORGE_MCP_ENABLED") == "true",
  mcp_token_env: System.get_env("HARNESSFORGE_MCP_TOKEN_ENV"),
  startup_recovery: config_env() != :test,
  recovery_modules: [HarnessForge.Evaluations, HarnessForge.Privacy]

config :harness_forge, HarnessForge.Repo,
  database: Path.join(workspace_root, "data.sqlite3"),
  pool_size: 1,
  synchronous: :full,
  log: false,
  show_sensitive_data_on_connection_error: false

config :harness_forge, HarnessForgeWeb.Endpoint,
  url: [host: "localhost", port: port, scheme: "http"],
  http: [ip: {127, 0, 0, 1}, port: port],
  check_origin: origins,
  server: config_env() != :test and System.get_env("PHX_SERVER") in ["true", "1"]

config :phoenix, :filter_parameters, [
  "password",
  "token",
  "access_code",
  "secret",
  "authorization",
  "credential",
  "api_key",
  "text",
  "body",
  "content",
  "prompt",
  "messages",
  "chat",
  "question",
  "instructions",
  "statement",
  "claim",
  "goal",
  "analysis",
  "analysis_edit"
]
