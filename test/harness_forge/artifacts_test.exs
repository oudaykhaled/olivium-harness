defmodule HarnessForge.ArtifactsTest do
  use ExUnit.Case, async: true
  alias HarnessForge.{Artifacts, Compiler, Contracts}

  setup do
    root = Path.join(File.cwd!(), "tmp/artifact-test-" <> Ecto.UUID.generate())
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    fixture =
      Path.expand("../../examples/synthetic_company/harness.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()

    spec = put_in(fixture, ["spec", "policies", Access.at(0), "required"], false)
    {:ok, artifact} = Compiler.compile(spec)
    %{root: root, artifact: artifact, opts: [root: root]}
  end

  # The check is concurrency safety, not speed: under a loaded host (load above 8) the 8
  # publishes took longer than the former 10 s stream timeout.
  @tag timeout: 120_000
  test "publish is repeatable, verified and safe under concurrent writers", %{
    artifact: artifact,
    opts: opts,
    root: root
  } do
    results =
      1..8
      |> Task.async_stream(fn _ -> Artifacts.publish(artifact, opts) end,
        max_concurrency: 8,
        timeout: 60_000
      )
      |> Enum.to_list()

    for result <- results do
      assert {:ok, {:ok, %{"digest" => digest}}} = result
      assert digest == artifact["digest"]
    end

    assert {:ok, ^artifact} = Artifacts.read(artifact["digest"], opts)
    assert {:ok, [^artifact]} = Artifacts.list(opts)
    assert File.ls!(Path.join(root, "artifacts")) == [artifact["digest"]]

    assert File.stat!(Path.join([root, "artifacts", artifact["digest"], "artifact.json"])).mode
           |> Bitwise.band(0o777) == 0o600
  end

  test "native export is complete, identical and does not include store metadata", %{
    artifact: artifact,
    root: root,
    opts: opts
  } do
    assert {:ok, _} = Artifacts.publish(artifact, opts)
    target = Path.join(root, "export-one")
    assert {:ok, %{"path" => ^target}} = Artifacts.export(artifact["digest"], target, opts)

    for {relative, bytes} <- artifact["files"],
        do: assert(File.read!(Path.join(target, relative)) == bytes)

    refute File.exists?(Path.join(target, "artifact.json"))
    second = Path.join(root, "export-two")
    assert {:ok, _} = Artifacts.export(artifact, second, opts)

    for {relative, _} <- artifact["files"],
        do:
          assert(
            File.read!(Path.join(target, relative)) == File.read!(Path.join(second, relative))
          )
  end

  test "existing directories/files and simultaneous target requests never overwrite", %{
    artifact: artifact,
    root: root,
    opts: opts
  } do
    target = Path.join(root, "existing")
    File.mkdir!(target)
    File.write!(Path.join(target, "important.txt"), "keep")

    assert {:error, %Contracts.Error{code: "export_conflict"}} =
             Artifacts.export(artifact, target, opts)

    assert File.read!(Path.join(target, "important.txt")) == "keep"
    file_target = Path.join(root, "existing.txt")
    File.write!(file_target, "unchanged")
    assert {:error, _} = Artifacts.export(artifact, file_target, opts)
    assert File.read!(file_target) == "unchanged"
    concurrent = Path.join(root, "race")

    results =
      1..4
      |> Task.async_stream(fn _ -> Artifacts.export(artifact, concurrent, opts) end,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1

    assert Enum.count(results, &match?({:error, %Contracts.Error{code: "export_conflict"}}, &1)) ==
             3
  end

  test "symlink parents, symlink destination and traversal paths fail closed", %{
    artifact: artifact,
    root: root,
    opts: opts
  } do
    outside = Path.join(root, "outside")
    File.mkdir!(outside)
    link = Path.join(root, "link")
    File.ln_s!(outside, link)
    assert {:error, _} = Artifacts.export(artifact, Path.join(link, "escaped"), opts)
    assert {:error, _} = Artifacts.export(artifact, link, opts)
    assert {:error, _} = Artifacts.publish(artifact, root: link)
    assert {:error, _} = Artifacts.export(artifact, root <> "/../escape", opts)
    assert {:error, _} = Artifacts.export(artifact, "relative-target", opts)
    assert {:error, _} = Artifacts.read("../escape", opts)
    assert File.ls!(outside) == []
    refute File.exists?(Path.join(root, "escape"))
  end

  test "tampered, injected and symlink payloads are rejected without replacement", %{
    artifact: artifact,
    root: root,
    opts: opts
  } do
    assert {:ok, %{"path" => store}} = Artifacts.publish(artifact, opts)
    agents = Path.join(store, "payload/AGENTS.md")
    File.write!(agents, "tampered")
    assert {:error, _} = Artifacts.read(artifact["digest"], opts)

    assert {:error, %Contracts.Error{code: "artifact_conflict"}} =
             Artifacts.publish(artifact, opts)

    assert File.read!(agents) == "tampered"
    File.write!(agents, artifact["files"]["AGENTS.md"])
    File.write!(Path.join(store, "payload/extra.txt"), "injected")
    assert {:error, _} = Artifacts.read(artifact["digest"], opts)
    File.rm!(Path.join(store, "payload/extra.txt"))
    File.rm!(agents)
    external = Path.join(root, "external.txt")
    File.write!(external, artifact["files"]["AGENTS.md"])
    File.ln_s!(external, agents)
    assert {:error, _} = Artifacts.read(artifact["digest"], opts)
    assert {:error, _} = Artifacts.list(opts)

    assert {:error, _} =
             Artifacts.export(artifact["digest"], Path.join(root, "must-not-exist"), opts)

    refute File.exists?(Path.join(root, "must-not-exist"))
    bad = put_in(artifact, ["files", "../escape"], "bad")
    assert {:error, _} = Artifacts.export(bad, Path.join(root, "bad-export"), opts)
  end
end
