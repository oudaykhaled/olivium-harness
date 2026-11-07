defmodule HarnessForge.Adapters.Registry do
  @moduledoc "Compiled-in native harness targets; renderers confer no execution authority."
  alias HarnessForge.Adapters.{OpenCode, Codex, ClaudeCode}
  alias HarnessForge.Contracts.Error

  def fetch("opencode"), do: {:ok, OpenCode}
  def fetch("codex"), do: {:ok, Codex}
  def fetch("claude_code"), do: {:ok, ClaudeCode}

  def fetch(_),
    do:
      {:error,
       %Error{code: "unsupported_runtime", message: "No adapter is registered for this runtime"}}

  def list do
    for {name, label, version} <- [
          {"opencode", "OpenCode", "1.19.5"},
          {"codex", "Codex CLI", "0.156.0"},
          {"claude_code", "Claude Code", "2.1.311"}
        ] do
      %{
        "name" => name,
        "label" => label,
        "tested_cli_version" => version,
        "export_available" => true,
        "runtime_qualified" => false,
        "managed_backend" =>
          case name do
            "opencode" -> "opencode_docker"
            "codex" -> "codex_docker_unqualified"
            _ -> "unavailable"
          end
      }
    end
  end

  def config_paths("opencode"), do: ["opencode.json"]
  def config_paths("codex"), do: [".codex/config.toml"]
  def config_paths("claude_code"), do: [".claude/settings.json"]
  def config_paths(_), do: []
end
