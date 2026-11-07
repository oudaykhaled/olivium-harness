defmodule HarnessForge.CLI do
  @moduledoc "Offline command entry point. The application must own the workspace lock."
  alias HarnessForge.{Demo, Decisions, Evidence, Goals, Harnesses, Workspaces}

  def main(args) do
    case run(args) do
      {:ok, value} ->
        IO.puts(Jason.encode!(%{"ok" => true, "result" => value}))

      {:error, reason} ->
        IO.puts(:stderr, Jason.encode!(%{"ok" => false, "error" => error_message(reason)}))
        System.halt(1)
    end
  end

  def run(["init"]),
    do: {:ok, %{"workspace_id" => Workspaces.current_id(), "root" => Workspaces.root()}}

  def run(["status"]) do
    {:ok,
     %{
       "workspace_id" => Workspaces.current_id(),
       "elixir" => System.version(),
       "otp" => System.otp_release(),
       "runtime_qualified" => false
     }}
  end

  def run(["demo"]), do: Demo.load()
  def run(["sources"]), do: Evidence.list_sources()
  def run(["claims"]), do: Evidence.list_claims()
  def run(["goals"]), do: Goals.list_goals()

  def run(["company", "profile"]), do: HarnessForge.Company.get_profile()
  def run(["company", "repositories"]), do: HarnessForge.Company.list_repositories()
  def run(["company", "projects"]), do: HarnessForge.Company.list_projects()
  def run(["company", "plans"]), do: HarnessForge.Company.list_plans()
  def run(["company", "search", query]), do: HarnessForge.Company.search_capabilities(query)
  def run(["company", "consumers", id]), do: HarnessForge.Company.consumers(id)

  def run(["company", kind, path]) when kind in ~w(profile repository project plan) do
    with {:ok, attrs} <- read_company_json(path) do
      case kind do
        "profile" -> HarnessForge.Company.save_profile(attrs)
        "repository" -> HarnessForge.Company.create_repository(attrs)
        "project" -> HarnessForge.Company.create_project(attrs)
        "plan" -> HarnessForge.Company.create_plan(attrs)
      end
    end
  end

  def run(["company", "decide", id, decision, hash]) when decision in ~w(approve reject) do
    HarnessForge.Company.decide_plan(id, %{
      "actor" => "local-operator",
      "decision" => decision,
      "expected_revision_hash" => hash
    })
  end

  def run(["company", "build", id, hash]) do
    with {:ok, artifact} <- Harnesses.build_plan(id, hash),
         do: {:ok, Map.take(artifact, ~w(digest manifest capabilities diagnostics))}
  end

  def run(["goal", path]) do
    with {:ok, attrs} <- read_company_json(path), do: Goals.add_goal(attrs)
  end

  def run(["connect", "local", name, directory]),
    do: Evidence.connect(%{"provider" => "local", "name" => name, "directory" => directory})

  def run(["connect", "github", name, repository]),
    do:
      Evidence.connect(%{
        "provider" => "github",
        "name" => name,
        "config" => %{"repository" => repository}
      })

  def run(["connect", "github", name, repository, reference]),
    do:
      Evidence.connect(%{
        "provider" => "github",
        "name" => name,
        "config" => %{"repository" => repository, "credential_ref" => reference}
      })

  def run(["connect", "jira", name, endpoint, project, username, credential]),
    do:
      Evidence.connect(%{
        "provider" => "jira",
        "name" => name,
        "config" => %{
          "endpoint" => endpoint,
          "project" => project,
          "username_ref" => username,
          "credential_ref" => credential
        }
      })

  def run(["connect", "github_projects", name, project_url, reference]),
    do:
      Evidence.connect(%{
        "provider" => "github_projects",
        "name" => name,
        "config" => %{"project_url" => project_url, "credential_ref" => reference}
      })

  def run(["connect", "slack", name, team, channel, reference]),
    do:
      Evidence.connect(%{
        "provider" => "slack",
        "name" => name,
        "config" => %{"team_id" => team, "channel_id" => channel, "credential_ref" => reference}
      })

  def run(["connect", "confluence", name, endpoint, space, username, credential]),
    do:
      Evidence.connect(%{
        "provider" => "confluence",
        "name" => name,
        "config" => %{
          "endpoint" => endpoint,
          "space_id" => space,
          "username_ref" => username,
          "credential_ref" => credential
        }
      })

  def run(["runtimes"]), do: {:ok, HarnessForge.Adapters.Registry.list()}
  def run(["chat-connectors"]), do: HarnessForge.Chat.catalog()
  def run(["chat", question]), do: HarnessForge.Chat.ask(question)

  def run(["chat", question, "assistant"]), do: HarnessForge.Chat.ask(question, mode: :assistant)

  def run(["chat", question, mode]) when mode in ~w(evidence model),
    do: HarnessForge.Chat.ask(question, mode: if(mode == "model", do: :model, else: :evidence))

  def run(["model", "status"]), do: {:ok, HarnessForge.Models.status()}

  def run(["model", "configure", path]) do
    with {:ok, stat} <- File.stat(path),
         true <- stat.type == :regular and stat.size <= 65_536,
         {:ok, bytes} <- File.read(path),
         true <- byte_size(bytes) <= 65_536,
         {:ok, config} when is_map(config) <- Jason.decode(bytes) do
      HarnessForge.Models.configure(config)
    else
      _ -> {:error, :invalid_model_configuration}
    end
  end

  def run(["model", name]),
    do:
      HarnessForge.Models.configure(%{
        "provider" => "ollama",
        "endpoint" => "http://127.0.0.1:11434",
        "model" => name
      })

  def run(["propose", id]), do: HarnessForge.Models.propose(id)
  def run(["sync", id]), do: Evidence.sync(id)

  def run(["decide", id, decision, hash]) do
    Decisions.decide(id, %{
      "actor" => Workspaces.operator(),
      "decision" => decision,
      "expected_revision_hash" => hash
    })
  end

  def run(["build", name, version]) do
    with {:ok, artifact} <- Harnesses.build(%{"name" => name, "version" => version}) do
      {:ok, Map.take(artifact, ["digest", "manifest", "capabilities", "diagnostics"])}
    end
  end

  def run(["build", name, version, runtime]),
    do: build_target(name, version, runtime, "unqualified")

  def run(["build", name, version, runtime, runtime_version]),
    do: build_target(name, version, runtime, runtime_version)

  def run(["export", digest, target]), do: Harnesses.export(digest, target)

  def run(["evaluate", digest, kind]) when kind in ~w(static_integrity runtime_smoke task),
    do: HarnessForge.Evaluations.run(digest, kind: kind)

  def run(["runs"]), do: HarnessForge.Evaluations.list_runs()

  def run(["compare", baseline, candidate]),
    do: HarnessForge.Evaluations.compare(baseline, candidate)

  def run(["cancel", id]), do: HarnessForge.Evaluations.cancel(id)
  def run(["releases"]), do: HarnessForge.Releases.list()

  def run(["approve-release", digest, evaluation]) do
    with {:ok, artifact} <- Harnesses.get(digest),
         do:
           HarnessForge.Releases.approve(%{
             "artifact_digest" => digest,
             "evaluation_id" => evaluation,
             "scope" => artifact["spec"]["spec"]["scope"],
             "actor" => Workspaces.operator()
           })
  end

  def run(["promote", id]), do: HarnessForge.Releases.promote(id)
  def run(["promote", id, expected]), do: HarnessForge.Releases.promote(id, expected)
  def run(["rollback", id, expected]), do: HarnessForge.Releases.rollback(id, expected)
  def run(["diff", left, right]), do: HarnessForge.Releases.diff(left, right)
  def run(["inventory"]), do: HarnessForge.Privacy.inventory()
  def run(["backup", target]), do: HarnessForge.Privacy.backup(target)
  def run(["restore", backup, target]), do: HarnessForge.Privacy.restore(backup, target)

  def run(["purge-source", id, confirmation]),
    do: HarnessForge.Privacy.purge_source(id, confirmation)

  def run(["purge", confirmation]), do: HarnessForge.Privacy.purge_workspace(confirmation)

  def run(["help"]) do
    {:ok,
     %{
       "commands" => [
         "init",
         "serve",
         "status",
         "demo",
         "sources",
         "claims",
         "goals",
         "goal CONFIG_JSON_FILE",
         "company profile|repositories|projects|plans",
         "company profile|repository|project|plan CONFIG_JSON_FILE",
         "company search QUERY",
         "company consumers REPOSITORY_ID",
         "company decide PLAN_ID approve|reject REVISION_HASH",
         "company build PLAN_ID REVISION_HASH",
         "sync CONNECTION_ID",
         "decide CLAIM_ID approve|reject REVISION_HASH",
         "build NAME VERSION [opencode|codex|claude_code [RUNTIME_VERSION]]",
         "runtimes",
         "chat-connectors",
         "chat QUESTION [assistant|evidence|model]",
         "model status",
         "model configure CONFIG_JSON_FILE",
         "export DIGEST FRESH_DIRECTORY",
         "connect local NAME DIRECTORY",
         "connect github NAME OWNER/REPO [TOKEN_ENV_REF]",
         "connect jira NAME ENDPOINT PROJECT EMAIL_ENV_REF TOKEN_ENV_REF",
         "connect github_projects NAME PROJECT_URL TOKEN_ENV_REF",
         "connect slack NAME TEAM_ID CHANNEL_ID TOKEN_ENV_REF",
         "connect confluence NAME ENDPOINT SPACE_ID EMAIL_ENV_REF TOKEN_ENV_REF",
         "model INSTALLED_OLLAMA_MODEL",
         "propose SOURCE_ID",
         "evaluate DIGEST static_integrity|runtime_smoke|task",
         "runs",
         "compare BASELINE_RUN_ID CANDIDATE_RUN_ID",
         "cancel RUN_ID",
         "releases",
         "approve-release DIGEST EVALUATION_ID",
         "promote RELEASE_ID [EXPECTED_CURRENT_ID]",
         "rollback RELEASE_ID EXPECTED_CURRENT_ID",
         "diff BASELINE_DIGEST CANDIDATE_DIGEST",
         "inventory",
         "backup FRESH_DIRECTORY",
         "restore BACKUP_DIRECTORY FRESH_WORKSPACE",
         "purge-source SOURCE_ID SOURCE_ID",
         "purge WORKSPACE_ID"
       ],
       "ownership" =>
         "Stop the portal before offline mutation commands; a second owner is rejected."
     }}
  end

  def run(_), do: {:error, :unknown_command}

  defp read_company_json(path) do
    with {:ok, %{type: :regular, size: size}} when size <= 262_144 <- File.stat(path),
         {:ok, bytes} <- File.read(path),
         {:ok, attrs} when is_map(attrs) <- HarnessForge.Contracts.decode_json(bytes) do
      {:ok, attrs}
    else
      _ -> {:error, :invalid_company_config}
    end
  end

  defp build_target(name, version, runtime, runtime_version) do
    with {:ok, artifact} <-
           Harnesses.build(%{
             "name" => name,
             "version" => version,
             "runtime" => runtime,
             "runtime_version" => runtime_version
           }),
         do: {:ok, Map.take(artifact, ["digest", "manifest", "capabilities", "diagnostics"])}
  end

  defp error_message(%HarnessForge.Contracts.Error{code: code}), do: code
  defp error_message(%{message: message}) when is_binary(message), do: message
  defp error_message(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_message(_), do: "operation_failed"
end
