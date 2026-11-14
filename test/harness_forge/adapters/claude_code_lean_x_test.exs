defmodule HarnessForge.Adapters.ClaudeCodeLeanXTest do
  # The lean-x export: the lean settings, the guard and the Bash output shaper as
  # PreToolUse hooks, a fixed output style, and nothing else the model reads. Synthetic
  # profiles and repositories only; no hook script runs here (the shaper's own tests run
  # it in Docker).
  use HarnessForge.DataCase, async: false

  alias HarnessForge.Adapters.ClaudeCode
  alias HarnessForge.Adapters.ClaudeCode.{Guard, OutputStyle}
  alias HarnessForge.{CLI, Compiler, Generation}
  alias HarnessForge.Contracts.Error
  alias HarnessForge.SyntheticRepositories, as: Repositories

  @shaper ".claude/hooks/olivium-shape.sh"
  @style ".claude/output-styles/olivium.md"
  # contract.md, lane C, item 1: exactly this text with a trailing newline.
  @style_text """
  ---
  name: olivium
  description: Olivium Harness - fewer requests
  keep-coding-instructions: true
  ---
  Work in as few requests as you can.
  - Put independent searches and file reads in one Bash call, joined with `;`, and read exact line ranges.
  - After an edit, run the narrowest relevant test in the same Bash call.
  - Run tests in the foreground and wait for them; do not poll with sleep.
  """
  @metadata ~w(.olivium/capabilities.json .olivium/manifest.json .olivium/provenance.json .olivium/spec.json)

  defp profile(name) do
    Path.expand("../../../examples/profiles/#{name}.json", __DIR__)
    |> File.read!()
    |> Jason.decode!()
  end

  defp package(context, name \\ "python_package") do
    {:ok, result} = Generation.plan(%{"profile" => profile(name), "context" => context})
    result
  end

  defp settings(result), do: Jason.decode!(result["artifact"]["files"][".claude/settings.json"])

  describe "the lean-x export" do
    test "holds the settings, the guard, the shaper and the style, and no CLAUDE.md" do
      result = package("lean-x")
      files = result["artifact"]["files"]

      assert Enum.sort(Map.keys(files)) ==
               Enum.sort([".claude/settings.json", Guard.path(), @shaper, @style | @metadata])

      refute Map.has_key?(files, "CLAUDE.md")
      refute Map.has_key?(files, ".olivium/guidance-provenance.json")
      assert result["guidance"] == nil
      assert result["context"]["profile"] == "lean-x"
      assert result["counts"]["hooks"] == 0
      assert result["artifact"]["spec"]["spec"]["hooks"] == []
    end

    test "the style is the contract text, under the measured 495 bytes" do
      files = package("lean-x")["artifact"]["files"]

      assert files[@style] == @style_text
      assert OutputStyle.content() == @style_text
      assert OutputStyle.path() == @style
      assert byte_size(@style_text) == 385
      assert byte_size(@style_text) <= OutputStyle.max_bytes()
      assert OutputStyle.max_bytes() == 495
    end

    test "settings are lean's, with only the PreToolUse hooks and outputStyle changed" do
      for name <- ~w(python_package node_package elixir_project minimal) do
        lean = settings(package("lean", name))
        x = settings(package("lean-x", name))

        assert Enum.sort(Map.keys(x)) ==
                 Enum.sort(Enum.uniq(Map.keys(lean) ++ ~w(hooks outputStyle)))

        assert x["outputStyle"] == "olivium"
        assert Map.drop(x, ~w(hooks outputStyle)) == Map.drop(lean, ~w(hooks)), name
        assert x["includeGitInstructions"] == false
        assert x["permissions"]["deny"] == lean["permissions"]["deny"]
        refute Map.has_key?(x, "env")
        refute Map.has_key?(x, "autoMemoryEnabled")

        # The guard first, then the shaper; no other event.
        assert Map.keys(x["hooks"]) == ["PreToolUse"]
        [guard, shaper] = x["hooks"]["PreToolUse"]
        assert guard["matcher"] == lean["hooks"]["PreToolUse"] |> hd() |> Map.fetch!("matcher")
        assert shaper["matcher"] == "Bash"
        assert [%{"type" => "command", "command" => command}] = shaper["hooks"]
        assert command =~ @shaper
        assert [%{"command" => guard_command}] = guard["hooks"]
        assert guard_command =~ Guard.path()
      end
    end

    test "the trim keys are the lean profile's, byte for byte" do
      lean = package("lean")
      x = package("lean-x")

      assert Map.drop(x["context"], ["profile"]) == Map.drop(lean["context"], ["profile"])
      assert length(x["context"]["deny_tools"]) == 15

      for name <- x["context"]["deny_tools"],
          do: assert(name in settings(x)["permissions"]["deny"])
    end

    test "the capability report names the shaper and the diagnostics say what is not rendered" do
      result = package("lean-x")
      ids = Enum.map(result["artifact"]["capabilities"], & &1["id"])

      assert "hooks.olivium-shape" in ids
      assert "hooks.olivium-guard" in ids
      refute "hooks.olivium-rewrite" in ids
      refute Enum.any?(ids, &String.starts_with?(&1, "hooks.env-check"))

      codes = Enum.map(result["diagnostics"], & &1["code"])
      assert "claude_md_not_rendered" in codes
      assert "bash_output_shaped" in codes
      refute "guidance_withheld" in codes
    end

    test "other profiles get no style, no shaper and no outputStyle" do
      for context <- ~w(lean standard) do
        result = package(context)
        files = result["artifact"]["files"]

        refute Map.has_key?(files, @style), context
        refute Map.has_key?(files, @shaper), context
        refute Map.has_key?(settings(result), "outputStyle"), context
        assert Map.has_key?(files, "CLAUDE.md"), context
      end
    end

    test "is deterministic" do
      first = package("lean-x")["artifact"]
      second = package("lean-x")["artifact"]

      assert first["files"] == second["files"]
      assert first["digest"] == second["digest"]
    end
  end

  describe "a lean-x spec is rendered whole or refused" do
    setup do
      {:ok, spec: package("lean-x")["artifact"]["spec"]}
    end

    test "a hook in the spec is refused, not dropped", %{spec: spec} do
      hook = %{
        "id" => "lint",
        "event" => "before_stop",
        "command" => "ruff check",
        "timeout_seconds" => 30
      }

      spec = put_in(spec, ["spec", "hooks"], [hook])

      assert {:error, %Error{code: "invalid_runtime_intent", message: message}} =
               ClaudeCode.compile_v2(spec, %{"mode" => "preview"})

      assert message =~ "spec.hooks must be empty"
    end

    test "learned parts are refused", %{spec: spec} do
      spec = put_in(spec, ["spec", "rewrites"], %{"items" => [], "timeout_seconds" => 5})

      assert {:error, %Error{code: "invalid_runtime_intent", message: message}} =
               ClaudeCode.compile_v2(spec, %{"mode" => "preview"})

      assert message =~ "no learned parts"
    end

    test "an unknown profile is still refused", %{spec: spec} do
      spec = put_in(spec, ["spec", "context", "profile"], "lean-y")

      assert {:error, %Error{code: "invalid_runtime_intent", message: message}} =
               ClaudeCode.compile_v2(spec, %{"mode" => "preview"})

      assert message =~ "lean, standard, lean-ai or lean-x"
    end

    test "the compiler verifies the artifact it built", %{spec: spec} do
      assert {:ok, artifact} = Compiler.compile(spec)
      assert :ok = Compiler.verify(artifact)
    end
  end

  describe "bin/harnessforge generate --context lean-x" do
    setup do
      root = Path.join(System.tmp_dir!(), "hf-lean-x-#{Ecto.UUID.generate()}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      {:ok, root: root, repository: Repositories.python_project(Path.join(root, "widgets"))}
    end

    defp generate(repository, target) do
      CLI.run([
        "generate",
        repository,
        "--runtime",
        "claude_code",
        "--export",
        target,
        "--context",
        "lean-x",
        "--json"
      ])
    end

    defp tree(dir) do
      Path.wildcard(Path.join(dir, "**"), match_dot: true)
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&{Path.relative_to(&1, dir), File.read!(&1)})
      |> Enum.sort()
    end

    test "exports the same tree twice", %{root: root, repository: repository} do
      one = Path.join(root, "export-1")
      two = Path.join(root, "export-2")

      assert {:ok, first} = generate(repository, one)
      assert {:ok, second} = generate(repository, two)

      assert first["context"]["profile"] == "lean-x"
      assert first["digest"] == second["digest"]
      assert tree(one) == tree(two)

      paths = Enum.map(tree(one), &elem(&1, 0))
      assert @style in paths and @shaper in paths and Guard.path() in paths
      refute "CLAUDE.md" in paths
    end

    test "says what the profile does in text mode", %{root: root, repository: repository} do
      target = Path.join(root, "export-text")

      text =
        ExUnit.CaptureIO.capture_io(fn ->
          CLI.main([
            "generate",
            repository,
            "--runtime",
            "claude_code",
            "--export",
            target,
            "--context",
            "lean-x"
          ])
        end)

      assert text =~
               "Context profile: lean-x (the lean settings, removing git instructions and 15 tools"

      assert text =~ "no CLAUDE.md"
      refute text =~ "CLAUDE.md   "
    end

    test "--learned is still lean-ai only", %{root: root, repository: repository} do
      assert {:error, %Error{code: "invalid_arguments", message: message}} =
               CLI.run([
                 "generate",
                 repository,
                 "--runtime",
                 "claude_code",
                 "--export",
                 Path.join(root, "export-learned"),
                 "--context",
                 "lean-x",
                 "--learned",
                 root
               ])

      assert message =~ "--learned is used only with --context lean-ai"
    end
  end
end
