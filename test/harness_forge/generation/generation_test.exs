defmodule HarnessForge.GenerationTest do
  use HarnessForge.DataCase, async: false

  alias HarnessForge.{Artifacts, Audit, Compiler, Generation}
  alias HarnessForge.Contracts.Error

  @profiles ~w(elixir_project node_package python_package minimal)
  # The four profiles above have no history evidence and fewer than 3 test pairs, so
  # they generate no skill or subagent and their goldens are unchanged by that code;
  # python_package_native (synthetic) generates 2 area skills and 2 subagents.
  @golden_profiles @profiles ++ ["python_package_native"]
  @golden Path.expand("golden", __DIR__)

  setup do
    root = Path.join(System.tmp_dir!(), "hf-generation-#{Ecto.UUID.generate()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  defp profile(name) do
    Path.expand("../../../examples/profiles/#{name}.json", __DIR__)
    |> File.read!()
    |> Jason.decode!()
  end

  defp native(files),
    do: Map.reject(files, fn {path, _} -> String.starts_with?(path, ".olivium/") end)

  defp settings_for(name) do
    {:ok, result} = Generation.plan(%{"profile" => profile(name)})
    result["artifact"]["files"][".claude/settings.json"]
  end

  defp golden_files(name) do
    base = Path.join(@golden, name)

    Path.wildcard(Path.join(base, "**/*"), match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Map.new(&{Path.relative_to(&1, base), File.read!(&1)})
  end

  for name <- @golden_profiles do
    test "golden files for #{name}" do
      assert {:ok, result} = Generation.plan(%{"profile" => profile(unquote(name))})
      files = native(result["artifact"]["files"])

      if System.get_env("UPDATE_GOLDEN") == "1" do
        for {path, bytes} <- files do
          target = Path.join([@golden, unquote(name), path])
          File.mkdir_p!(Path.dirname(target))
          File.write!(target, bytes)
        end
      end

      assert files == golden_files(unquote(name))
    end
  end

  test "the same profile always yields identical bytes and digest" do
    for name <- @golden_profiles do
      assert {:ok, first} = Generation.plan(%{"profile" => profile(name)})
      assert {:ok, second} = Generation.plan(%{"profile" => profile(name)})
      assert first["digest"] == second["digest"]
      assert first["artifact"] == second["artifact"]
      assert :ok = Compiler.verify(first["artifact"])
    end
  end

  test "generate publishes, audits and exports only to a fresh directory", %{root: root} do
    request = %{
      "profile" => profile("elixir_project"),
      "target" => "claude_code",
      "mode" => "solo"
    }

    assert {:ok, first} = Generation.generate(request, artifact_root: root)
    assert {:ok, second} = Generation.generate(request, artifact_root: root)
    assert first["digest"] == second["digest"]
    assert {:ok, stored} = Artifacts.read(first["digest"], root: root)
    assert stored == first["artifact"]

    assert {:ok, events} = Audit.list_events()

    generated = Enum.filter(events, &(&1["action"] == "harness.generated"))
    assert length(generated) == 2
    assert hd(generated)["details"]["artifact_digest"] == first["digest"]

    target = Path.join(root, "export")
    assert {:ok, _} = Artifacts.export(first["digest"], target, root: root)
    assert File.read!(Path.join(target, "CLAUDE.md")) == first["artifact"]["files"]["CLAUDE.md"]
    assert File.regular?(Path.join(target, ".claude/hooks/olivium-before-stop.sh"))
    assert {:error, %Error{}} = Artifacts.export(first["digest"], target, root: root)
  end

  test "plan writes nothing" do
    assert {:ok, result} = Generation.plan(%{"profile" => profile("node_package")})
    assert result["counts"]["hooks"] == 3
    assert {:ok, events} = Audit.list_events()
    refute Enum.any?(events, &(&1["action"] == "harness.generated"))
  end

  test "other runtimes are explicitly unsupported, never substituted" do
    for target <- ["codex", "opencode"] do
      request = %{"profile" => profile("minimal"), "target" => target}

      assert {:error, %Error{code: "unsupported_runtime", details: [^target]}} =
               Generation.plan(request)

      assert {:error, %Error{code: "unsupported_runtime"}} = Generation.generate(request)
    end
  end

  test "team mode and malformed requests fail visibly" do
    assert {:error, %Error{code: "unsupported_mode"}} =
             Generation.plan(%{"profile" => profile("minimal"), "mode" => "team"})

    assert {:error, %Error{code: "invalid_generation_request"}} = Generation.plan(%{})

    assert {:error, %Error{code: "invalid_generation_request"}} =
             Generation.plan(%{"profile" => profile("minimal"), "root" => "/tmp/x"})

    assert {:error, %Error{code: "invalid_generation_request"}} =
             Generation.plan(%{"profile" => profile("minimal"), "target" => 1})

    assert {:error, %Error{code: "invalid_profile"}} =
             Generation.plan(%{"profile" => Map.delete(profile("minimal"), "commands")})
  end

  test "only auto candidates become derived rules, ordered by confidence" do
    base = profile("python_package")

    candidates =
      base["rule_candidates"] ++
        [
          %{
            "text" => "Use the retry helper for outbound calls",
            "confidence" => 95,
            "bucket" => "auto",
            "citations" => [%{"detector" => "instructions", "signal" => "instructions.rule"}]
          }
        ]

    assert {:ok, result} =
             Generation.plan(%{"profile" => Map.put(base, "rule_candidates", candidates)})

    rules = result["artifact"]["spec"]["spec"]["rules"]

    assert Enum.map(rules, & &1["statement"]) == [
             "Use the retry helper for outbound calls",
             "Add a test under tests/ with every behaviour change"
           ]

    assert Enum.all?(rules, &(&1["origin"] == "derived"))
    assert result["excluded_candidates"] == %{"suggested" => 1}
  end

  test "a project command matching a deny rule is removed everywhere" do
    base = profile("elixir_project")

    commands =
      Map.merge(base["commands"], %{"lint" => "rm -rf _build", "run" => "FOO=1 /usr/bin/curl x"})

    assert {:ok, result} = Generation.plan(%{"profile" => Map.put(base, "commands", commands)})
    assert result["skipped_commands"] == ["lint", "run"]

    files = result["artifact"]["files"]
    refute files["CLAUDE.md"] =~ "_build"
    refute files[".claude/hooks/olivium-before-stop.sh"] =~ "rm -rf"
    refute files[".claude/settings.json"] =~ "Bash(rm -rf _build"
    refute files[".claude/settings.json"] =~ "curl x"

    assert Enum.map(result["artifact"]["spec"]["spec"]["hooks"], & &1["id"]) ==
             ["env-check", "format-before-stop", "test-before-stop"]

    refute Enum.any?(
             result["artifact"]["spec"]["spec"]["project"]["tools"],
             &(&1["role"] == "lint")
           )
  end

  test "checks run before stop on the changed files, and missing tools are named at session start" do
    assert {:ok, result} = Generation.plan(%{"profile" => profile("python_package")})
    hooks = result["artifact"]["spec"]["spec"]["hooks"]

    assert [
             %{"id" => "env-check", "event" => "session_start", "builtin" => "env_check"},
             %{
               "id" => "format-before-stop",
               "command" => "uv run ruff format",
               "selector" => "changed_files"
             },
             %{
               "id" => "lint-before-stop",
               "command" => "uv run ruff check",
               "selector" => "changed_files"
             },
             %{
               "id" => "test-before-stop",
               "command" => "uv run pytest",
               "selector" => "related_tests"
             }
           ] = hooks

    refute Enum.any?(hooks, &(&1["event"] == "after_edit"))
    assert Enum.all?(tl(hooks), &(&1["file_argument"] == true))

    settings = Jason.decode!(result["artifact"]["files"][".claude/settings.json"])
    assert Map.keys(settings["hooks"]) |> Enum.sort() == ["PreToolUse", "SessionStart", "Stop"]
    refute Map.has_key?(settings["hooks"], "PostToolUse")
  end

  test "solo packages use the lean context profile and say what it saves" do
    for name <- @profiles do
      assert {:ok, result} = Generation.plan(%{"profile" => profile(name)})
      context = result["artifact"]["spec"]["spec"]["context"]
      settings = Jason.decode!(result["artifact"]["files"][".claude/settings.json"])

      assert context["profile"] == "lean"
      assert context["measured_on"] == "claude-code 2.1.311"
      assert context["est_tokens_saved_per_request"] == 11_700
      assert settings["includeGitInstructions"] == false
      assert Enum.all?(context["deny_tools"], &(&1 in settings["permissions"]["deny"]))
      refute Map.has_key?(settings, "disableBundledSkills")
      refute "ToolSearch" in settings["permissions"]["deny"]
    end
  end

  test "lean is refused, never swapped, for a package with agents or skills" do
    alias HarnessForge.Generation.{Blueprint, Profile, Spec}

    {:ok, p} = Profile.validate(profile("python_package"))
    blueprint = Blueprint.select(p)

    assert {:error, %Error{code: "lean_profile_unavailable"}} =
             Spec.build(p, blueprint, "team", %{"context" => "lean"})

    assert {:ok, %{"spec" => team}} = Spec.build(p, blueprint, "team", %{})
    assert team["spec"]["context"]["profile"] == "standard"
    assert team["spec"]["context"]["deny_tools"] == []

    assert {:ok, %{"spec" => standard}} =
             Spec.build(p, blueprint, "solo", %{"context" => "standard"})

    assert standard["spec"]["context"]["include_git_instructions"] == true

    assert {:error, %Error{code: "invalid_generation_request"}} =
             Spec.build(p, blueprint, "solo", %{"context" => "minimal"})

    notebooks = Map.update!(p, "languages", &(&1 ++ ["jupyter"]))
    assert {:ok, %{"spec" => kept}} = Spec.build(notebooks, blueprint, "solo", %{})
    refute "NotebookEdit" in kept["spec"]["context"]["deny_tools"]
    assert length(kept["spec"]["context"]["deny_tools"]) == 14
  end

  test "the lean profile keeps the tools a repository's own subagents and skills need" do
    alias HarnessForge.Generation.{Blueprint, Profile, Spec}

    {:ok, p} = Profile.validate(profile("python_package"))
    blueprint = Blueprint.select(p)
    with_files = &put_in(p, ["existing_harness", "files"], &1)

    {:ok, %{"spec" => full}} = Spec.build(p, blueprint, "solo", %{})
    assert full["spec"]["context"]["est_tokens_saved_per_request"] > 0
    assert "Task" in full["spec"]["context"]["deny_tools"]

    {:ok, %{"spec" => agents}} =
      Spec.build(with_files.([".claude/agents/reviewer.md"]), blueprint, "solo", %{})

    context = agents["spec"]["context"]
    refute "Task" in context["deny_tools"]
    assert "Skill" in context["deny_tools"] and "Workflow" in context["deny_tools"]
    assert context["est_tokens_saved_per_request"] == 0

    {:ok, %{"spec" => skills}} =
      Spec.build(with_files.([".claude/skills/release/SKILL.md"]), blueprint, "solo", %{})

    context = skills["spec"]["context"]
    assert "Task" in context["deny_tools"]
    refute "Skill" in context["deny_tools"] or "Workflow" in context["deny_tools"]
    assert context["est_tokens_saved_per_request"] == 0

    # Instruction files alone change nothing.
    {:ok, %{"spec" => plain}} = Spec.build(with_files.(["CLAUDE.md"]), blueprint, "solo", %{})
    assert plain["spec"]["context"] == full["spec"]["context"]
  end

  test "test pairs and co-change rows reach the package capped, sorted and in plain paths" do
    base = profile("python_package")

    pair =
      &%{
        "source" => "src/m#{&1}.py",
        "test" => "tests/test_m#{&1}.py",
        "support" => 2,
        "kind" => "cochange"
      }

    assert {:error, %Error{code: "invalid_profile"}} =
             Generation.plan(%{
               "profile" => Map.put(base, "test_pairs", Enum.map(201..1//-1, pair))
             })

    odd = %{
      "source" => "src/a b.py",
      "test" => "tests/test_a.py",
      "support" => 2,
      "kind" => "cochange"
    }

    assert {:error, %Error{code: "invalid_profile"}} =
             Generation.plan(%{"profile" => Map.put(base, "test_pairs", [odd])})

    assert {:ok, result} =
             Generation.plan(%{
               "profile" => Map.put(base, "test_pairs", Enum.map(200..1//-1, pair))
             })

    rows = result["artifact"]["spec"]["spec"]["project"]["test_pairs"]

    assert length(rows) == 200
    assert rows == Enum.sort_by(rows, &{&1["source"], &1["test"]})

    tsv = result["artifact"]["files"][".olivium/test-pairs.tsv"]
    assert tsv =~ "src/m1.py\ttests/test_m1.py"
  end

  test "an analysis that runs past its limit is a visible error" do
    Application.put_env(:harness_forge, :analysis_timeout_ms, 0)
    on_exit(fn -> Application.delete_env(:harness_forge, :analysis_timeout_ms) end)

    assert {:error, %Error{code: "analysis_timeout"}} =
             Generation.plan(%{"root" => Path.expand("../../..", __DIR__)})
  end

  test "an AI policy is reported to the person generating the package" do
    assert {:ok, result} =
             Generation.plan(%{
               "profile" =>
                 profile("minimal")
                 |> Map.put("rule_candidates", [
                   %{
                     "text" => "Read `.github/AI_POLICY.md` first",
                     "confidence" => 100,
                     "bucket" => "auto",
                     "citations" => [
                       %{
                         "detector" => "instructions",
                         "signal" => "instructions.ai_policy",
                         "path" => ".github/AI_POLICY.md"
                       }
                     ]
                   }
                 ])
             })

    assert %{"severity" => "warning", "message" => message} =
             Enum.find(result["diagnostics"], &(&1["code"] == "ai_policy_detected"))

    assert message =~ ".github/AI_POLICY.md"
  end

  test "a repository with no commands gets only the guard, no check hooks, agents or skills" do
    assert {:ok, result} = Generation.plan(%{"profile" => profile("minimal")})
    files = result["artifact"]["files"]

    assert files["CLAUDE.md"] ==
             "<!-- Olivium Harness. Lines left out of this file, and why: .olivium/guidance-provenance.json -->\n"

    assert result["guidance"]["est_tokens_per_request"] == 0

    assert Enum.sort(Map.keys(native(files))) ==
             [".claude/hooks/olivium-guard.sh", ".claude/settings.json", "CLAUDE.md"]

    settings = Jason.decode!(files[".claude/settings.json"])
    assert Map.keys(settings["hooks"]) == ["PreToolUse"]
    refute "Skill" in settings["permissions"]["allow"]
  end

  test "the allow list follows the detected toolchain" do
    python = Jason.decode!(settings_for("python_package"))["permissions"]
    node = Jason.decode!(settings_for("node_package"))["permissions"]
    minimal = Jason.decode!(settings_for("minimal"))["permissions"]

    # uv was detected: any `uv run` form is allowed, and the tools its commands name
    # are allowed bare, as an activated environment runs them.
    for rule <- [
          "Bash(uv run:*)",
          "Bash(pytest:*)",
          "Bash(ruff:*)",
          "Bash(mypy:*)",
          "Bash(python:*)"
        ] do
      assert rule in python["allow"]
    end

    refute Enum.any?(python["allow"], &String.starts_with?(&1, "Bash(uv run pytest"))
    refute Enum.any?(python["allow"] ++ minimal["allow"], &(&1 =~ ~r/Bash\((npm|npx|node)/))
    assert "Bash(node:*)" in node["allow"]
    refute Enum.any?(node["allow"], &(&1 =~ ~r/Bash\((uv|pytest|python:)/))
    refute "Bash(pytest:*)" in minimal["allow"]

    # The same utilities and denials everywhere, and no Read deny rule anywhere.
    for permissions <- [python, node, minimal] do
      assert "Bash(grep:*)" in permissions["allow"]
      assert "Edit(./**)" in permissions["allow"]
      assert "Bash(git push:*)" in permissions["deny"]
      assert "Bash(curl:*)" in permissions["deny"]
      assert "Edit(.env)" in permissions["deny"]
      refute Enum.any?(permissions["deny"], &String.starts_with?(&1, "Read("))
    end
  end

  test "output has no absolute paths and names the repository only by its identity" do
    assert {:ok, result} = Generation.plan(%{"profile" => profile("elixir_project")})

    for {path, bytes} <- result["artifact"]["files"] do
      refute bytes =~ System.tmp_dir!(), "#{path} contains a temporary path"
      refute bytes =~ File.cwd!(), "#{path} contains the working directory"
    end
  end
end
