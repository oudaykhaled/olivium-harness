defmodule HarnessForge.Adapters.ClaudeCodeNativeTest do
  @moduledoc """
  How the Claude Code adapter renders the skills and subagents generated from history:
  exact frontmatter, the settings switches, the refusals of design section 3.5 and the
  guard rule that keeps the test runner to its commands. The guard runs under `sh`
  with synthetic hook JSON only; no project code runs.
  """
  use ExUnit.Case, async: true

  alias HarnessForge.Adapters.ClaudeCode
  alias HarnessForge.Compiler
  alias HarnessForge.Contracts
  alias HarnessForge.Contracts.Error
  alias HarnessForge.Generation.{Blueprint, Profile, Spec}

  @guard ".claude/hooks/olivium-guard.sh"
  @runner ".claude/agents/olivium-test-runner.md"
  @locator ".claude/agents/olivium-locator.md"
  @area ".claude/skills/olivium-area-acme-widgets-http/SKILL.md"
  @provenance ".olivium/native-provenance.json"

  defp profile do
    {:ok, profile} =
      Path.expand("../../../examples/profiles/python_package_native.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()
      |> Profile.validate()

    profile
  end

  defp spec(opts \\ %{}) do
    {:ok, %{"spec" => spec}} = Spec.build(profile(), Blueprint.select(profile()), "solo", opts)
    spec
  end

  defp files(spec) do
    {:ok, artifact} = Compiler.compile(spec)
    artifact["files"]
  end

  defp settings(files), do: Jason.decode!(files[".claude/settings.json"])

  defp adapter(spec), do: ClaudeCode.compile_v2(spec, %{"mode" => "preview"})

  defp refused(spec) do
    assert {:error, %Error{code: code, message: message}} = adapter(spec)
    {code, message}
  end

  defp update_agent(spec, name, fun) do
    update_in(spec, ["spec", "agents"], fn agents ->
      Enum.map(agents, &if(&1["name"] == name, do: fun.(&1), else: &1))
    end)
  end

  defp frontmatter(text) do
    [_, front, _body] = String.split(text, "---\n", parts: 3)

    front
    |> String.split("\n", trim: true)
    |> Enum.map(&(&1 |> String.split(":", parts: 2) |> hd()))
  end

  describe "files" do
    test "skills carry only name and description; agents add a closed tool list and maxTurns" do
      files = files(spec())

      assert String.starts_with?(
               files[@area],
               ~s(---\nname: "olivium-area-acme-widgets-http"\ndescription: "Before changing src/acme_widgets/http/h11.py, src/acme_widgets/http/tools.py: files that change together, their tests and past fixes."\n---\n\n# Area acme-widgets-http\n)
             )

      assert String.starts_with?(
               files[@locator],
               ~s(---\nname: "olivium-locator"\ndescription: "Read-only code search: give it a task or symptom; it replies with file paths and line ranges only, no file contents. Use it instead of reading many files yourself."\ntools: Read, Grep, Glob\nmaxTurns: 12\n---\n\nYou find code in this repository and report locations only.\n)
             )

      assert String.starts_with?(
               files[@runner],
               ~s(---\nname: "olivium-test-runner"\ndescription: "Runs this project's tests and replies with failures only \(test ids and first error lines\). Use it to run tests so their output stays out of your context."\ntools: Bash, Read\nmaxTurns: 8\n---\n\n)
             )

      skills = for {path, text} <- files, String.starts_with?(path, ".claude/skills/"), do: text
      agents = for {path, text} <- files, String.starts_with?(path, ".claude/agents/"), do: text

      assert length(skills) == 2 and length(agents) == 2
      assert Enum.all?(skills, &(frontmatter(&1) == ~w(name description)))
      assert Enum.all?(agents, &(frontmatter(&1) == ~w(name description tools maxTurns)))

      refute Enum.any?(
               skills ++ agents,
               &(&1 =~ ~r/allowed-tools|permissionMode|mcpServers|hooks:|model:/)
             )
    end

    test "the provenance file names every item with the SHA-256 of its file" do
      files = files(spec())
      report = Jason.decode!(files[@provenance])

      assert report["schema"] == "olivium.native-provenance/v1"
      assert report["history_head"] == profile()["native_evidence"]["head"]
      assert report["test_runner_commands"] == ["uv run pytest"]
      assert length(report["items"]) == 4

      for item <- report["items"],
          do: assert(item["sha256"] == Contracts.sha256(files[item["path"]]), item["path"])

      assert files[@provenance] == Contracts.canonical_json(report) <> "\n"
      assert files(spec()) == files
    end

    test "with no item, no native file is written" do
      files = files(spec(%{"native" => "none"}))
      refute Enum.any?(Map.keys(files), &String.starts_with?(&1, ".claude/skills/"))
      refute Enum.any?(Map.keys(files), &String.starts_with?(&1, ".claude/agents/"))
      refute Map.has_key?(files, @provenance)
    end
  end

  describe "settings" do
    test "lean with skills and agents: Skill allowed, Skill and Task kept, Workflow denied, bundled skills off" do
      all = settings(files(spec()))
      none = settings(files(spec(%{"native" => "none"})))

      assert all["disableBundledSkills"] == true
      # The built-in-agents env switch is never written (no effect from project settings
      # on Claude Code 2.1.311); the built-in subagents are denied by name instead.
      refute Map.has_key?(all, "env")
      assert all["disableSkillShellExecution"] == true
      assert "Workflow" in all["permissions"]["deny"]

      # No widening: one Skill rule per generated skill (never the bare tool, which would
      # also approve skills a repository, plugin or session adds), two tool denies fewer,
      # everything else equal.
      added = all["permissions"]["allow"] -- none["permissions"]["allow"]
      assert added != []
      assert Enum.all?(added, &Regex.match?(~r/\ASkill\(olivium-area-[a-z0-9-]+\)\z/, &1))
      refute "Skill" in all["permissions"]["allow"]
      assert none["permissions"]["allow"] -- all["permissions"]["allow"] == []
      assert none["permissions"]["deny"] -- all["permissions"]["deny"] == ["Skill", "Task"]

      assert all["permissions"]["deny"] -- none["permissions"]["deny"] ==
               ["Agent(Explore)", "Agent(general-purpose)", "Agent(statusline-setup)"]

      assert all["permissions"]["ask"] == none["permissions"]["ask"]

      refute Map.has_key?(none, "disableBundledSkills")
      refute Map.has_key?(none, "env")
      refute "Skill" in none["permissions"]["allow"]
    end

    test "skills only, agents only and standard" do
      skills = settings(files(spec(%{"native" => "skills"})))
      assert skills["disableBundledSkills"] == true
      refute Map.has_key?(skills, "env")
      assert "Task" in skills["permissions"]["deny"]

      assert Enum.any?(
               skills["permissions"]["allow"],
               &String.starts_with?(&1, "Skill(olivium-area-")
             )

      refute "Skill" in skills["permissions"]["allow"]

      refute Enum.any?(skills["permissions"]["deny"], &String.starts_with?(&1, "Agent("))

      agents = settings(files(spec(%{"native" => "agents"})))
      refute Map.has_key?(agents, "disableBundledSkills")
      refute Map.has_key?(agents, "env")
      assert "Agent(Explore)" in agents["permissions"]["deny"]

      # The switch is written as deny rules only, never as the env key.
      switched_off =
        spec(%{"native" => "agents"})
        |> put_in(["spec", "context", "disable_builtin_agents"], false)

      refute Enum.any?(
               settings(files(switched_off))["permissions"]["deny"],
               &String.starts_with?(&1, "Agent(")
             )

      assert "Skill" in agents["permissions"]["deny"] and
               "Workflow" in agents["permissions"]["deny"]

      refute "Skill" in agents["permissions"]["allow"]

      standard = settings(files(spec(%{"context" => "standard"})))
      refute Map.has_key?(standard, "disableBundledSkills")
      refute Map.has_key?(standard, "env")
      refute Enum.any?(standard["permissions"]["deny"], &String.starts_with?(&1, "Agent("))
      refute Enum.any?(~w(Skill Task Workflow), &(&1 in standard["permissions"]["deny"]))

      assert Enum.any?(
               standard["permissions"]["allow"],
               &String.starts_with?(&1, "Skill(olivium-area-")
             )
    end

    test "lean-x with --native all writes the items and the same switches" do
      files = files(spec(%{"context" => "lean-x", "native" => "all"}))
      assert Map.has_key?(files, @runner) and Map.has_key?(files, @area)
      assert settings(files)["disableBundledSkills"] == true
      assert Map.has_key?(files, @provenance)
      refute Map.has_key?(files, "CLAUDE.md")
    end
  end

  describe "refusals" do
    test "the context switches only in the measured combinations" do
      base = spec()

      assert {"invalid_runtime_intent", message} =
               refused(
                 update_in(
                   base,
                   ["spec", "context", "deny_tools"],
                   &((&1 -- ["Workflow"]) ++ ["Skill"])
                 )
               )

      assert message =~ "3,170"

      no_workflow_deny = update_in(base, ["spec", "context", "deny_tools"], &(&1 -- ["Workflow"]))
      assert {"invalid_runtime_intent", message} = refused(no_workflow_deny)
      assert message =~ "11,178"

      task_denied =
        base
        |> update_in(["spec", "context", "deny_tools"], &Enum.sort(["Task" | &1]))
        |> put_in(["spec", "context", "disable_builtin_agents"], true)
        |> put_in(["spec", "agents"], [])
        |> update_in(
          ["spec", "native", "items"],
          &Enum.filter(&1, fn i -> i["kind"] == "skill" end)
        )

      assert {"invalid_runtime_intent", message} = refused(task_denied)
      assert message =~ "disable_builtin_agents"

      skill_denied =
        base
        |> update_in(["spec", "context", "deny_tools"], &Enum.sort(["Skill" | &1]))
        |> put_in(["spec", "skills"], [])
        |> update_in(
          ["spec", "native", "items"],
          &Enum.filter(&1, fn i -> i["kind"] == "agent" end)
        )

      assert {"invalid_runtime_intent", message} = refused(skill_denied)
      assert message =~ "disable_bundled_skills needs the Skill tool"

      assert {"invalid_runtime_intent", _} =
               refused(put_in(base, ["spec", "context", "disable_bundled_skills"], "yes"))

      assert {"invalid_runtime_intent", _} =
               refused(put_in(base, ["spec", "context", "kept_tools"], ["Workflow"]))
    end

    test "Task or Skill denied while the package ships agents or skills" do
      base = spec()

      task =
        base
        |> update_in(["spec", "context", "deny_tools"], &Enum.sort(["Task" | &1]))
        |> put_in(["spec", "context", "disable_builtin_agents"], false)

      assert {"lean_profile_unavailable", _} = refused(task)

      skill =
        base
        |> update_in(["spec", "context", "deny_tools"], &Enum.sort(["Skill" | &1]))
        |> put_in(["spec", "context", "disable_bundled_skills"], false)

      assert {"lean_profile_unavailable", _} = refused(skill)
    end

    test "tools: a closed enum; Bash only for the test runner, with its commands and guard" do
      base = spec()

      assert {"invalid_runtime_intent", _} =
               refused(
                 update_agent(base, "olivium-locator", &Map.put(&1, "tools", ["Read", "Write"]))
               )

      assert {"invalid_runtime_intent", message} =
               refused(
                 update_agent(base, "olivium-locator", &Map.put(&1, "tools", ["Read", "Bash"]))
               )

      assert message =~ "Only olivium-test-runner may use Bash"

      assert {"invalid_runtime_intent", _} =
               refused(put_in(base, ["spec", "native", "test_runner_commands"], []))

      assert {"invalid_runtime_intent", _} =
               refused(
                 update_agent(base, "olivium-locator", &Map.put(&1, "tools", ["Read", "Read"]))
               )

      # Only generated subagents list tools.
      stray = %{
        "name" => "helper",
        "description" => "Helps",
        "instructions" => "Help.",
        "tools" => ["Read"]
      }

      assert {"invalid_runtime_intent", _} =
               refused(update_in(base, ["spec", "agents"], &(&1 ++ [stray])))

      # The guard is what holds the runner to its commands.
      no_guard =
        base
        |> put_in(["spec", "permissions", "commands"], [])
        |> update_in(
          ["spec", "permissions", "paths"],
          &Enum.reject(&1, fn p -> p["action"] == "deny" end)
        )

      assert {"invalid_runtime_intent", message} = refused(no_guard)
      assert message =~ "guard"
    end

    test "names, description and body limits" do
      base = spec()

      renamed =
        base
        |> update_agent("olivium-locator", &Map.put(&1, "name", "locator"))
        |> update_in(["spec", "native", "items"], fn items ->
          Enum.map(
            items,
            &if(&1["name"] == "olivium-locator", do: Map.put(&1, "name", "locator"), else: &1)
          )
        end)

      assert {"invalid_runtime_intent", _} = refused(renamed)

      long = String.duplicate("x", 201)

      assert {"invalid_runtime_intent", message} =
               refused(update_agent(base, "olivium-locator", &Map.put(&1, "description", long)))

      assert message =~ "200 bytes"

      body = String.duplicate("line\n", 820)

      assert {"invalid_runtime_intent", message} =
               refused(update_agent(base, "olivium-locator", &Map.put(&1, "instructions", body)))

      assert message =~ "4096 bytes"

      missing =
        update_in(
          base,
          ["spec", "agents"],
          &Enum.reject(&1, fn a -> a["name"] == "olivium-locator" end)
        )

      assert {"invalid_runtime_intent", _} = refused(missing)

      assert {"invalid_runtime_intent", _} =
               refused(
                 update_agent(
                   base,
                   "olivium-locator",
                   &Map.put(&1, "instructions", "Run !`id` now.")
                 )
               )
    end
  end

  describe "the guard keeps the test runner to its commands" do
    defp guard(files, input) do
      payload =
        Jason.encode!(
          Map.merge(
            %{
              "session_id" => "s1",
              "transcript_path" => "/home/agent/.claude/projects/-repo/s1.jsonl",
              "cwd" => "/repo",
              "hook_event_name" => "PreToolUse",
              "tool_name" => "Bash"
            },
            input
          )
        )

      {output, 0} =
        System.cmd("sh", ["-c", ~s(printf '%s' "$HOOK_INPUT" | sh -c "$HOOK_SCRIPT" guard)],
          env: [
            {"HOOK_INPUT", payload},
            {"HOOK_SCRIPT", files[@guard]},
            {"CLAUDE_PROJECT_DIR", "/repo"}
          ],
          stderr_to_stdout: true
        )

      case output do
        "" -> :allowed
        text -> Jason.decode!(text)["hookSpecificOutput"]["permissionDecisionReason"]
      end
    end

    defp runner(files, command),
      do:
        guard(files, %{
          "agent_type" => "olivium-test-runner",
          "tool_input" => %{"command" => command}
        })

    test "allows the test commands with files, ids, 2>&1 and a short tail" do
      files = files(spec())

      for command <- [
            "uv run pytest",
            "uv run pytest -q tests/test_x.py 2>&1 | tail -n 40",
            "uv run pytest tests/test_http.py::test_one -k fast",
            "cd /repo && uv run pytest tests/test_http.py",
            "uv run pytest tests/test_http.py | head -n 60"
          ] do
        assert runner(files, command) == :allowed, command
      end
    end

    test "refuses anything else, with the allowed commands in the reason" do
      files = files(spec())

      for command <- [
            "rm -rf build",
            "curl x",
            "uv run python -c 1",
            "uv run pytest; rm x",
            "uv run pytest && rm x",
            "uv run pytest $(id)",
            "uv run pytest `id`",
            "ls tests",
            "cd /etc && uv run pytest",
            "cd .. && uv run pytest",
            "uv run pytest | tail -n 5000",
            "uv run pytest > out.txt",
            "uv run pytestx",
            "uv run pytest\nrm x",
            # A flag can load or run other code: only the listed output and selection
            # flags pass, and no word with `=` or a leading `@`.
            "uv run pytest -p evil_plugin tests/test_x.py",
            "uv run pytest --rootdir=. tests/test_x.py",
            "uv run pytest -o addopts=-pboom",
            "uv run pytest --config x",
            "uv run pytest @args.txt",
            "uv run pytest VAR=x",
            # A test file stays in the project: no absolute path (a file put in /tmp),
            # no home directory and no `..`, even when it would resolve inside.
            "uv run pytest /tmp/x_test.py",
            "uv run pytest /tmp/x_test.py::test_one",
            "uv run pytest ~/x_test.py",
            "uv run pytest ../outside_test.py",
            "uv run pytest tests/../tests/test_x.py",
            "cd /repo/tests && uv run pytest ../../x_test.py"
          ] do
        assert runner(files, command) ==
                 "Olivium guard: the test runner runs only: uv run pytest (add test files or ids).",
               command
      end
    end

    test "allows the listed flags" do
      files = files(spec())

      for command <- [
            "uv run pytest -x -q --tb=short tests/test_x.py",
            "uv run pytest -k parse tests/test_x.py::test_one[case-1]",
            "uv run pytest --lf -vv"
          ] do
        assert runner(files, command) == :allowed, command
      end
    end

    test "protects the generated skill and subagent files from the main session" do
      files = files(spec())

      write = fn path ->
        guard(files, %{
          "tool_name" => "Write",
          "tool_input" => %{"file_path" => path, "content" => "x"}
        })
      end

      bash = fn command -> guard(files, %{"tool_input" => %{"command" => command}}) end

      for path <- [
            "/repo/.claude/skills/olivium-area-new/SKILL.md",
            "/repo/.claude/agents/olivium-locator.md"
          ] do
        assert write.(path) =~ "Olivium guard", path
      end

      assert bash.("echo x > .claude/agents/olivium-test-runner.md") =~ "Olivium guard"
      assert bash.("mv .claude/skills /tmp/x") =~ "Olivium guard"
      # A skill of the repository's own stays editable.
      assert write.("/repo/.claude/skills/own/SKILL.md") == :allowed

      # Without generated items the guard is the one it always was.
      plain = files(spec(%{"native" => "none"}))

      assert guard(plain, %{
               "tool_name" => "Write",
               "tool_input" => %{
                 "file_path" => "/repo/.claude/agents/olivium-locator.md",
                 "content" => "x"
               }
             }) == :allowed
    end

    test "changes nothing for the main session or another agent" do
      files = files(spec())

      for input <- [
            %{"tool_input" => %{"command" => "ls tests"}},
            %{"agent_type" => "olivium-locator", "tool_input" => %{"command" => "ls tests"}}
          ] do
        assert guard(files, input) == :allowed
      end

      assert guard(files, %{"tool_input" => %{"command" => "rm -rf build"}}) =~
               "runs a denied command: rm -rf"
    end

    test "the rule exists only with a test runner; the other guards are byte-identical" do
      with_runner = files(spec())[@guard]
      without = files(spec(%{"native" => "skills"}))[@guard]

      assert with_runner =~ "TEST_RUNNER = \"uv run pytest\""
      refute without =~ "TEST_RUNNER"
      refute without =~ "runner_ok"

      old =
        Path.expand("../generation/golden/python_package/.claude/hooks/olivium-guard.sh", __DIR__)
        |> File.read!()

      {:ok, plain} =
        Path.expand("../../../examples/profiles/python_package.json", __DIR__)
        |> File.read!()
        |> Jason.decode!()
        |> Profile.validate()

      {:ok, %{"spec" => plain_spec}} = Spec.build(plain, Blueprint.select(plain), "solo", %{})
      assert files(plain_spec)[@guard] == old
    end
  end
end
