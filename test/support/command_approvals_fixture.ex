defmodule HarnessForge.CommandApprovalsFixture do
  @moduledoc """
  Synthetic approved-artifact and owned-run fixtures for approval service/WEB tests.

  No coding process, Docker command, model observation or command execution runs.
  The persisted run is test data and cannot establish native runtime qualification.
  Tests own their unique workspace ID/root and SQL sandbox.
  """
  alias HarnessForge.{Contracts, Decisions, Demo, Evidence, Harnesses, Repo, Workspaces}
  alias HarnessForge.CodingDockerFixture
  alias HarnessForge.Evaluation.Run
  alias HarnessForge.Execution.Coding

  def create!(root, opts \\ []) do
    if Workspaces.root() != root,
      do:
        raise(
          ArgumentError,
          "test must select its workspace root before creating approval fixtures"
        )

    fixture =
      case Keyword.fetch(opts, :transport_fixture) do
        {:ok, fixture} ->
          fixture

        :error ->
          fixture = CodingDockerFixture.install!()
          ExUnit.Callbacks.on_exit(fn -> CodingDockerFixture.restore(fixture) end)
          fixture
      end

    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    {:ok, _} = Demo.load()
    {:ok, claims} = Evidence.list_claims()
    claim = Enum.find(claims, &(not String.starts_with?(&1["text"], "IGNORE")))

    {:ok, _} =
      Decisions.decide(claim["id"], %{
        "actor" => Workspaces.operator(),
        "decision" => "approve",
        "expected_revision_hash" => claim["revision_hash"]
      })

    {:ok, artifact} = Harnesses.build(%{"runtime" => "codex", "runtime_version" => "0.156.0"})
    {:ok, sources} = Evidence.list_sources()

    %{
      run: create_run!(fixture, artifact),
      artifact: artifact,
      source: hd(sources),
      transport_fixture: fixture,
      caller: caller()
    }
  end

  def caller, do: [authorize: fn -> true end]

  def payload(overrides \\ %{}) do
    arguments =
      ~s({"cmd":"printf synthetic-approval-canary","workdir":"/candidate","login":false})

    payload =
      %{
        "json_rpc_id" => 1,
        "thread_id" => "thread-public",
        "turn_id" => "turn-public",
        "item_id" => "call-public",
        "approval_id" => nil,
        "environment_id" => "environment-public",
        "command" => "printf synthetic-approval-canary",
        "cwd" => "/candidate",
        "driver_nonce" => String.duplicate("a", 32),
        "provider_response_id" => "response-public",
        "original_arguments" => arguments,
        "original_arguments_digest" => Contracts.sha256(arguments),
        "native_context_digest" => Contracts.sha256("exact native callback bytes")
      }
      |> Map.merge(overrides)

    if Map.has_key?(overrides, "original_arguments") and
         not Map.has_key?(overrides, "original_arguments_digest"),
       do:
         Map.put(
           payload,
           "original_arguments_digest",
           Contracts.sha256(payload["original_arguments"])
         ),
       else: payload
  end

  def create_run!(fixture, artifact) do
    id = Ecto.UUID.generate()
    {:ok, observation} = CodingDockerFixture.observation(fixture, Workspaces.current_id(), id)

    admission = %{
      observation: observation,
      driver: %{
        "image_id" => "sha256:" <> hash("synthetic image"),
        "descriptor_digest" => hash("descriptor"),
        "receipt_digest" => hash("receipt"),
        "cli_version" => "0.156.0",
        "platform" => "linux/arm64"
      },
      model_identity: %{
        "version" => "0.40.14",
        "model" => "synthetic:unobserved",
        "digest" => hash("model"),
        "endpoint" => "http://127.0.0.1:1",
        "capabilities" => ["completion", "tools"]
      },
      codex_tools: [],
      tools_profile_digest: hash("tool profile")
    }

    {:ok, context} = Coding.context(admission, Workspaces.current_id(), id)

    result =
      %{
        "id" => id,
        "workspace_id" => Workspaces.current_id(),
        "artifact_digest" => artifact["digest"],
        "kind" => "task",
        "outcome" => "running",
        "runtime_name" => "codex",
        "runtime_version" => "0.156.0",
        "runtime_image" => Coding.runtime_image(admission),
        "execution_profile_id" => "docker-codex-isolated-v1",
        "environment_profile_digest" => Coding.profile_digest(admission),
        "runtime_qualified" => false,
        "checks" => [],
        "duration_ms" => 0,
        "usage_status" => "not_dispatched",
        "cleanup_status" => "pending",
        "reason" => nil,
        "inserted_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "completed_at" => nil
      }
      |> Map.merge(Coding.identity(admission))

    Repo.insert!(%Run{
      id: id,
      workspace_id: Workspaces.current_id(),
      artifact_digest: artifact["digest"],
      result: result,
      execution_context: context
    })
  end

  defp hash(bytes), do: Contracts.sha256(bytes)
end
