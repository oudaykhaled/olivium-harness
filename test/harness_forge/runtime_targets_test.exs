defmodule HarnessForge.RuntimeTargetsTest do
  use HarnessForge.DataCase, async: false

  alias HarnessForge.{
    Artifacts,
    CLI,
    Compiler,
    Decisions,
    Demo,
    Evaluations,
    Evidence,
    Harnesses,
    Releases,
    Workspaces
  }

  setup do
    {:ok, _} = Demo.load()
    {:ok, claims} = Evidence.list_claims()
    claim = Enum.find(claims, &(not String.starts_with?(&1["text"], "IGNORE")))

    {:ok, _} =
      Decisions.decide(claim["id"], %{
        "actor" => Workspaces.operator(),
        "decision" => "approve",
        "expected_revision_hash" => claim["revision_hash"]
      })

    {:ok, claim: claim}
  end

  test "all targets use their registered adapter and preserve default OpenCode artifact bytes", %{
    claim: claim
  } do
    {:ok, default} = Harnesses.build(%{"name" => "default-target"})
    {:ok, explicit} = Harnesses.build(%{"name" => "default-target", "runtime" => "opencode"})
    assert default == explicit
    assert default["manifest"]["adapter"] == HarnessForge.Adapters.OpenCode.identity()

    for {target, config, guidance} <- [
          {"codex", ".codex/config.toml", "AGENTS.md"},
          {"claude_code", ".claude/settings.json", "CLAUDE.md"}
        ] do
      assert {:ok, artifact} = Harnesses.build(%{"name" => "target-harness", "runtime" => target})
      assert artifact["manifest"]["adapter"]["name"] == target
      assert Map.has_key?(artifact["files"], config)
      assert artifact["files"][guidance] =~ claim["text"]
      refute Map.has_key?(artifact["files"], "opencode.json")
      assert :ok = Compiler.verify(artifact)

      assert {:error, _} =
               Compiler.verify(put_in(artifact, ["manifest", "adapter", "name"], "opencode"))

      {:ok, reread} = Artifacts.read(artifact["digest"])
      assert reread == artifact
      target_dir = Path.join(Workspaces.root(), "target-export-#{Ecto.UUID.generate()}")
      on_exit(fn -> File.rm_rf!(target_dir) end)
      assert {:ok, _} = Harnesses.export(artifact["digest"], target_dir)
      assert File.read!(Path.join(target_dir, config)) == artifact["files"][config]
    end
  end

  test "new targets have static integrity but cannot inherit OpenCode backend or release authority" do
    assert {:ok, _} = HarnessForge.Models.configure(%{"model" => nil})

    for target <- ~w(codex claude_code) do
      {:ok, artifact} = Harnesses.build(%{"name" => "blocked-target", "runtime" => target})
      assert {:ok, static} = Evaluations.run(artifact["digest"], kind: :static_integrity)
      assert static["outcome"] == "passed"
      assert static["runtime_image"] == "unavailable:" <> target
      assert static["runtime_version"] == "unqualified"
      refute static["runtime_qualified"]
      assert :ok = Evaluations.applicability(artifact, static)

      for kind <- [:runtime_smoke, :task] do
        assert {:ok, run} = Evaluations.run(artifact["digest"], kind: kind)
        assert run["outcome"] == "blocked"

        assert run["reason"] ==
                 if(target == "codex" and kind == :task,
                   do: "model_not_selected",
                   else: "runtime_backend_unavailable"
                 )

        assert run["usage_status"] == "not_dispatched"
        assert run["runtime_image"] == "unavailable:" <> target
        refute run["runtime_qualified"]
      end

      assert {:error, :qualified_task_evaluation_required} =
               Releases.approve(%{
                 "artifact_digest" => artifact["digest"],
                 "evaluation_id" => static["id"],
                 "scope" => artifact["spec"]["spec"]["scope"],
                 "actor" => Workspaces.operator()
               })
    end
  end

  test "CLI builds each target and lists available export profiles without executing agents" do
    assert {:ok, targets} = CLI.run(["runtimes"])
    assert Enum.map(targets, & &1["name"]) == ~w(opencode codex claude_code)

    for {target, version} <- [{"codex", "0.156.0"}, {"claude_code", "2.1.311"}] do
      assert {:ok, result} = CLI.run(["build", "cli-target", "0.1.0", target, version])
      assert result["manifest"]["adapter"]["name"] == target
      assert result["manifest"]["qualification"] == "unverified"
    end

    assert {:error, %HarnessForge.Contracts.Error{code: "unsupported_runtime"}} =
             CLI.run(["build", "unknown-target", "0.1.0", "unknown"])
  end
end
