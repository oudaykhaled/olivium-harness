defmodule HarnessForge.CLIRepositoryTest do
  use HarnessForge.DataCase, async: false

  alias HarnessForge.CLI
  alias HarnessForge.Contracts.Error
  alias HarnessForge.SyntheticRepositories, as: Repositories

  setup do
    root = Path.join(System.tmp_dir!(), "hf-cli-repository-#{Ecto.UUID.generate()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  defp repository(root), do: Repositories.python_project(Path.join(root, "widgets"))

  test "analyze reports the commands found in a repository", %{root: root} do
    assert {:ok, result} = CLI.run(["analyze", repository(root)])
    assert result["repository"]["git"] == "available"
    assert result["profile"]["commands"]["test"] == "uv run pytest"
  end

  test "generate writes a verifiable package to a fresh directory", %{root: root} do
    target = Path.join(root, "export")

    assert {:ok, result} =
             CLI.run([
               "generate",
               repository(root),
               "--runtime",
               "claude_code",
               "--export",
               target,
               "--json"
             ])

    assert result["export"] == target
    assert File.regular?(Path.join(target, "CLAUDE.md"))
    assert File.regular?(Path.join(target, ".claude/settings.json"))
    refute Map.has_key?(result, "artifact")
  end

  test "generate prints the CLAUDE.md price and the context profile it chose", %{root: root} do
    target = Path.join(root, "export-text")
    repository = repository(root)

    text =
      ExUnit.CaptureIO.capture_io(fn ->
        CLI.main(["generate", repository, "--runtime", "claude_code", "--export", target])
      end)

    report = Jason.decode!(File.read!(Path.join(target, ".olivium/guidance-provenance.json")))
    settings = Jason.decode!(File.read!(Path.join(target, ".claude/settings.json")))

    assert text =~ "CLAUDE.md   #{report["rendered_bytes"]} bytes the model reads"
    assert text =~ "about #{report["est_tokens_per_request"]} tokens on every request"
    assert text =~ "#{length(report["withheld"])} lines withheld"

    assert text =~
             "Context profile: lean (removes git instructions and 14 tools no recorded benchmark run used, " <>
               "including skills (Skill, Workflow): CronCreate, CronDelete,"

    refute text =~ "unused tools"

    # The kept tool changes the saving: the measured table for that tool set less the listing,
    # never the 11,700 of the full deny list.
    assert text =~
             "keeps Task for the generated subagents; about 9,865 fewer tokens on every model request " <>
               "than no settings, estimated from measurements on Claude Code 2.1.311 for this tool set and listing"

    refute text =~ "11,700"
    assert text =~ "Use --context standard to keep them."
    assert settings["includeGitInstructions"] == false
    # The history-derived test runner (the fixture pairs tests with sources) keeps Task.
    assert File.regular?(Path.join(target, ".claude/agents/olivium-test-runner.md"))
    refute "Task" in settings["permissions"]["deny"]
    assert "Skill" in settings["permissions"]["deny"]
  end

  test "generate --json reports the generated skills and subagents and the tools they keep", %{
    root: root
  } do
    target = Path.join(root, "export-native-json")

    assert {:ok, result} =
             CLI.run([
               "generate",
               repository(root),
               "--runtime",
               "claude_code",
               "--export",
               target,
               "--json"
             ])

    native = result["native"]
    assert native["select"] == "all"

    assert [
             %{"name" => "olivium-test-runner", "kind" => "agent", "tools" => ["Bash", "Read"]} =
               item
           ] =
             native["items"]

    assert item["path"] == ".claude/agents/olivium-test-runner.md"
    assert File.regular?(Path.join(target, item["path"]))
    assert native["measured_on"] == "claude-code 2.1.311"
    assert is_integer(native["est_tokens_per_request"]) and native["est_tokens_per_request"] > 0
    assert result["context"]["kept_tools"] == ["Task"]
    # Task is kept for the runner, so the built-in subagents are denied by name.
    assert result["context"]["disable_builtin_agents"] == true
    assert native["builtin_agents_denied"] == ~w(Explore general-purpose statusline-setup)
    assert native["builtin_agents_denied_tokens"] == 395
    assert result["context"]["disable_bundled_skills"] == false
  end

  test "generate prints each generated subagent and what they cost together", %{root: root} do
    repository = repository(root)

    {:ok, json} =
      CLI.run([
        "generate",
        repository,
        "--runtime",
        "claude_code",
        "--export",
        Path.join(root, "export-native-a"),
        "--json"
      ])

    text =
      ExUnit.CaptureIO.capture_io(fn ->
        CLI.main([
          "generate",
          repository,
          "--runtime",
          "claude_code",
          "--export",
          Path.join(root, "export-native-b")
        ])
      end)

    lines = String.split(text, "\n")
    assert "agents      1: olivium-test-runner (Bash, Read)" in lines

    tokens =
      json["native"]["est_tokens_per_request"]
      |> Integer.to_string()
      |> String.reverse()
      |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
      |> String.reverse()

    assert ("native      about #{tokens} tokens on every model request for these " <>
              "(measured on Claude Code 2.1.311); --native none removes them") in lines

    refute Enum.any?(lines, &String.starts_with?(&1, "skills      "))
  end

  test "--native none generates no skill or subagent and keeps the full lean trim", %{root: root} do
    target = Path.join(root, "export-native-none")
    repository = repository(root)

    text =
      ExUnit.CaptureIO.capture_io(fn ->
        CLI.main([
          "generate",
          repository,
          "--runtime",
          "claude_code",
          "--export",
          target,
          "--native",
          "none"
        ])
      end)

    # Every reason an item was left out, not_selected among them (the area gate fails here too).
    assert [line] = Enum.filter(String.split(text, "\n"), &String.starts_with?(&1, "native "))
    assert line =~ ~r/^native      none generated \(([a-z_]+, )*not_selected(, [a-z_]+)*\)$/

    assert text =~
             "about 11,700 fewer tokens on every model request, measured on Claude Code 2.1.311"

    refute File.exists?(Path.join(target, ".claude/agents"))
    settings = Jason.decode!(File.read!(Path.join(target, ".claude/settings.json")))
    assert "Task" in settings["permissions"]["deny"]
    refute Map.has_key?(settings, "env")
  end

  test "an unknown --native is a usage error and writes nothing", %{root: root} do
    target = Path.join(root, "export-bad-native")

    assert {:error, %Error{code: "invalid_arguments", message: message}} =
             CLI.run([
               "generate",
               repository(root),
               "--runtime",
               "claude_code",
               "--export",
               target,
               "--native",
               "some"
             ])

    assert message =~ "--native must be all, skills, agents or none"
    refute File.exists?(target)
  end

  test "--context standard keeps git instructions and every tool", %{root: root} do
    target = Path.join(root, "export-standard")

    assert {:ok, result} =
             CLI.run([
               "generate",
               repository(root),
               "--runtime",
               "claude_code",
               "--export",
               target,
               "--context",
               "standard",
               "--json"
             ])

    assert result["context"]["profile"] == "standard"
    assert result["context"]["deny_tools"] == []
    settings = Jason.decode!(File.read!(Path.join(target, ".claude/settings.json")))
    refute Map.has_key?(settings, "includeGitInstructions")
    refute "Task" in settings["permissions"]["deny"]
  end

  test "an unknown --context is a usage error and writes nothing", %{root: root} do
    target = Path.join(root, "export-bad-context")

    assert {:error, %Error{code: "invalid_arguments", message: message}} =
             CLI.run([
               "generate",
               repository(root),
               "--runtime",
               "claude_code",
               "--export",
               target,
               "--context",
               "tiny"
             ])

    assert message =~ "--context must be lean or standard"
    refute File.exists?(target)
  end

  test "a runtime without generated packages is refused", %{root: root} do
    assert {:error, %Error{code: "unsupported_runtime", details: ["codex"]}} =
             CLI.run([
               "generate",
               repository(root),
               "--runtime",
               "codex",
               "--export",
               Path.join(root, "export")
             ])

    refute File.exists?(Path.join(root, "export"))
  end

  test "a directory that is not a git repository is refused", %{root: root} do
    plain = Repositories.plain_directory(Path.join(root, "plain"))
    assert {:error, %Error{code: "not_a_git_repository"}} = CLI.run(["analyze", plain])
  end

  test "usage errors name the command", %{root: root} do
    for args <- [
          ["analyze", "relative/path"],
          ["analyze", root, "--runtime", "claude_code"],
          ["generate", root, "--export", Path.join(root, "export")],
          ["generate", root, "--runtime", "claude_code"]
        ] do
      assert {:error, %Error{code: "invalid_arguments", message: message}} = CLI.run(args)
      assert message =~ "Usage:"
    end
  end
end
