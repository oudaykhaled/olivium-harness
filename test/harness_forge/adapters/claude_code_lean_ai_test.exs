defmodule HarnessForge.Adapters.ClaudeCodeLeanAiTest do
  # The lean-ai hooks run here with /bin/sh on synthetic data only: the generated
  # scripts, a synthetic index and fixed prompts and commands.
  use HarnessForge.DataCase, async: false

  alias HarnessForge.Adapters.ClaudeCode.{Locator, Rewrite}
  alias HarnessForge.{Contracts, Generation}
  alias HarnessForge.Generation.Index
  alias HarnessForge.Test.LeanAiFixture

  defp profile do
    Path.expand("../../../examples/profiles/python_package.json", __DIR__)
    |> File.read!()
    |> Jason.decode!()
  end

  defp package(prepared \\ LeanAiFixture.prepared()) do
    {:ok, result} =
      Generation.plan(%{
        "profile" => profile(),
        "context" => %{"profile" => "lean-ai", "learned" => prepared}
      })

    result["artifact"]
  end

  defp install(files) do
    dir = Path.join(System.tmp_dir!(), "hf-lean-ai-#{Ecto.UUID.generate()}")

    for {path, bytes} <- files do
      target = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(target))
      File.write!(target, bytes)
    end

    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp hook(settings, event, matcher \\ nil) do
    settings["hooks"][event]
    |> Enum.find(&(Map.get(&1, "matcher") == matcher))
    |> get_in(["hooks", Access.at(0), "command"])
  end

  defp run(command, dir, input) do
    System.cmd("/bin/sh", ["-c", ~s(printf '%s' "$HOOK_INPUT" | /bin/sh -c "$HOOK_COMMAND")],
      env: [{"HOOK_INPUT", input}, {"HOOK_COMMAND", command}, {"CLAUDE_PROJECT_DIR", dir}],
      stderr_to_stdout: false
    )
  end

  describe "locator hook" do
    setup do
      artifact = package()
      dir = install(artifact["files"])
      settings = Jason.decode!(artifact["files"][".claude/settings.json"])
      {:ok, artifact: artifact, dir: dir, command: hook(settings, "UserPromptSubmit")}
    end

    test "prints exactly the reference card, or nothing", ctx do
      files = ctx.artifact["files"]
      locator = ctx.artifact["spec"]["spec"]["locator"]
      rows = fn path -> String.split(files[path], "\n", trim: true) end

      prepared =
        Index.prepare(rows.(".olivium/index/symbols.tsv"), rows.(".olivium/index/terms.tsv"))

      constants = Map.put(locator["constants"], "stem_stopwords", locator["stem_stopwords"])

      extras = %{
        "tests" => rows.(".olivium/index/tests.tsv"),
        "cochange" => rows.(".olivium/cochange.tsv"),
        "test_command" => locator["test_command"],
        "pitfalls" => locator["pitfalls"]
      }

      prompts = [
        "RetryPolicy gives up too early when backoff_delay overflows",
        "Widget.resize ignores the minimum dimensions",
        "fix the retry jitter; it should use backoff",
        "Look at src/acme/layout.py and layout.py",
        "nothing relevant here at all",
        "",
        "create_widget breaks with é and \"quotes\" and 'single' and \\ and\ttabs",
        String.duplicate("widget resize ", 300)
      ]

      printed =
        for prompt <- prompts do
          {expected, _} = Index.card(prompt, prepared, extras, constants)
          input = Jason.encode!(%{"hook_event_name" => "UserPromptSubmit", "prompt" => prompt})
          assert {out, 0} = run(ctx.command, ctx.dir, input)
          assert out == (expected || ""), "prompt: #{inspect(prompt)}"

          if out != "",
            do: assert(byte_size(out) <= 600 and String.starts_with?(out, Index.header()))

          out
        end

      assert Enum.count(printed, &(&1 != "")) >= 3
      assert Enum.any?(printed, &(&1 =~ "Pitfall: Retry timing tests use the fake_clock fixture"))

      assert Enum.any?(
               printed,
               &(&1 =~ "Run: uv run pytest -q -p no:cacheprovider --tb=short tests/test_retry.py")
             )
    end

    test "a changed index or script prints no card", ctx do
      input = Jason.encode!(%{"prompt" => "RetryPolicy gives up too early in backoff_delay"})
      assert {card, 0} = run(ctx.command, ctx.dir, input)
      assert card =~ "src/acme/retry.py"

      File.write!(
        Path.join(ctx.dir, ".olivium/index/terms.tsv"),
        "evil\tsrc/acme/retry.py\t1000\thistory\n",
        [:append]
      )

      assert {"", 0} = run(ctx.command, ctx.dir, input)

      File.write!(Path.join(ctx.dir, Locator.path()), "\necho injected\n", [:append])
      assert {"", 0} = run(ctx.command, ctx.dir, input)

      File.rm!(Path.join(ctx.dir, Locator.path()))
      assert {"", 0} = run(ctx.command, ctx.dir, input)
    end

    test "the settings command pins the script's SHA-256", ctx do
      script = ctx.artifact["files"][Locator.path()]
      assert String.ends_with?(script, "\n") and not String.ends_with?(script, "\n\n")
      assert ctx.command =~ Contracts.sha256(script) <> "  -"
      assert {_, 0} = System.cmd("sh", ["-n", "-c", script])
    end
  end

  describe "rewrite hook" do
    setup do
      artifact = package()
      dir = install(artifact["files"])
      settings = Jason.decode!(artifact["files"][".claude/settings.json"])

      {:ok,
       dir: dir,
       command: hook(settings, "PreToolUse", "Bash"),
       script: artifact["files"][Rewrite.path()]}
    end

    defp rewrite(ctx, command, extra \\ %{}) do
      input =
        Jason.encode!(%{
          "tool_name" => "Bash",
          "tool_input" => Map.put(extra, "command", command)
        })

      {out, 0} = run(ctx.command, ctx.dir, input)

      case out do
        "" ->
          nil

        line ->
          assert line =~ ~r/#{Rewrite.output_line()}/
          decoded = Jason.decode!(line)
          refute Map.has_key?(decoded["hookSpecificOutput"], "permissionDecision")
          decoded["hookSpecificOutput"]["updatedInput"]
      end
    end

    test "rewrites only verified prefixes and keeps the rest byte for byte", ctx do
      assert %{"command" => command} = rewrite(ctx, "pytest tests/test_retry.py -x")

      assert command ==
               "printf 'olivium: ran uv run pytest (verified at export)\\n'; uv run pytest tests/test_retry.py -x"

      assert %{"command" => command} = rewrite(ctx, "uv run pytest tests | tail -5")

      assert command ==
               "printf 'olivium: ran uv run pytest -q (verified at export)\\n'; uv run pytest -q tests | tail -5"

      assert %{"command" => command} = rewrite(ctx, "cd src && pytest -k \"a and b\"")

      assert command ==
               "printf 'olivium: ran uv run pytest (verified at export)\\n'; cd src && uv run pytest -k \"a and b\""

      assert %{
               "command" =>
                 "printf 'olivium: mypy is not installed here (checked at export); skip it.\\n'"
             } =
               rewrite(ctx, "uv run mypy src")

      assert %{"command" => command} = rewrite(ctx, "uv run mypy src && uv run pytest -q")

      assert command ==
               "printf 'olivium: mypy is not installed here (checked at export); skip it.\\n'; true&& uv run pytest -q"

      # A redirection is not a separator: the cut is at the pipe, and the rest is kept byte for byte.
      assert %{"command" => command} =
               rewrite(ctx, "uv run mypy 2>&1 | tail -5; cd src && uv run mypy &>log")

      assert command ==
               "printf 'olivium: mypy is not installed here (checked at export); skip it.\\n'; true| tail -5; cd src && uv run mypy &>log"

      # A backslash-newline continues the skipped command; an escaped `;` is not a separator.
      assert %{"command" => command} =
               rewrite(ctx, "uv run mypy \\\n  src && uv run pytest -q")

      assert command ==
               "printf 'olivium: mypy is not installed here (checked at export); skip it.\\n'; true&& uv run pytest -q"

      assert %{
               "command" =>
                 "printf 'olivium: mypy is not installed here (checked at export); skip it.\\n'"
             } = rewrite(ctx, "uv run mypy src \\; echo x")

      assert %{"command" => command} = rewrite(ctx, "cd src && uv run mypy")

      assert command ==
               "printf 'olivium: mypy is not installed here (checked at export); skip it.\\n'; cd src && true"

      assert %{
               "command" => _,
               "description" => "run \"it\"",
               "timeout" => 600_000,
               "run_in_background" => true
             } =
               rewrite(ctx, "pytest", %{
                 "description" => "run \"it\"",
                 "timeout" => 600_000,
                 "run_in_background" => true
               })
    end

    test "leaves every other command alone", ctx do
      for command <- [
            "uv run pytest -q tests",
            "uv run pytest -q -p no:cacheprovider tests",
            "pytests",
            "pytest-xdist",
            "echo pytest",
            "PYTHONPATH=. pytest",
            "pytest $(git ls-files tests)",
            "pytest `ls`",
            "pytest <<EOF\nx\nEOF",
            "diff <(pytest) x",
            "uv run mypy 'a;b'",
            "(uv run mypy src || true)",
            "ls -la"
          ] do
        assert rewrite(ctx, command) == nil, command
      end
    end

    test "a changed script never runs", ctx do
      File.write!(Path.join(ctx.dir, Rewrite.path()), "\necho '{}'\n", [:append])
      assert rewrite(ctx, "pytest") == nil
      assert ctx.command =~ Contracts.sha256(ctx.script) <> "  -"
    end
  end

  describe "learned skills and agents" do
    # The shared bundle plus a learned area skill and a learned test runner naming the
    # verified one-file command (learner prompt v2 shape).
    defp native_bundle do
      LeanAiFixture.fixture_doc()
      |> Map.merge(%{
        "skills" => [
          %{
            "id" => "s01",
            "kind" => "area",
            "concept" => "c01",
            "slug" => "retry",
            "paths" => ["src/acme/retry.py", "src/acme/widgets.py"],
            "tests" => ["tests/test_retry.py"],
            "symbols" => ["RetryPolicy"],
            "pitfalls" => ["p02"],
            "evidence" => [String.duplicate("b", 40), String.duplicate("c", 40)]
          }
        ],
        "agents" => [
          %{
            "id" => "a01",
            "kind" => "test_runner",
            "paths" => ["tests/test_retry.py"],
            "commands" => ["cmd-test-file"],
            "evidence" => [String.duplicate("b", 40), String.duplicate("c", 40)]
          }
        ]
      })
      |> LeanAiFixture.resign()
    end

    setup do
      artifact = package(LeanAiFixture.prepared(%{"bundle" => native_bundle()}))
      dir = install(artifact["files"])
      settings = Jason.decode!(artifact["files"][".claude/settings.json"])

      guard =
        settings["hooks"]["PreToolUse"]
        |> Enum.find(&String.contains?(&1["matcher"] || "", "Bash"))
        |> get_in(["hooks", Access.at(0), "command"])

      {:ok, artifact: artifact, dir: dir, settings: settings, guard: guard}
    end

    test "render with origin learned, with provenance and no widened permission", ctx do
      files = ctx.artifact["files"]
      provenance = Jason.decode!(files[".olivium/native-provenance.json"])
      items = Map.new(provenance["items"], &{&1["name"], &1})

      assert items["olivium-area-retry"]["origin"] == "learned"
      assert items["olivium-area-retry"]["evidence"]["learned_id"] == "s01"
      assert items["olivium-test-runner"]["origin"] == "learned"
      assert items["olivium-test-runner"]["evidence"]["learned_id"] == "a01"

      for {path, bytes} <- files, String.starts_with?(path, ".claude/skills/") do
        assert bytes =~ ~r/\A---\nname: "[a-z0-9-]+"\ndescription: "[ -~]+"\n---\n/
        refute bytes =~ "allowed-tools"
      end

      assert files[".claude/agents/olivium-test-runner.md"] =~ "\ntools: Bash, Read\n"
      assert ctx.settings["disableSkillShellExecution"] == true
      assert "Bash(git push:*)" in ctx.settings["permissions"]["deny"]
      # One rule per generated skill, never the bare Skill tool.
      assert "Skill(olivium-area-retry)" in ctx.settings["permissions"]["allow"]
      refute "Skill" in ctx.settings["permissions"]["allow"]
    end

    test "the guard lets the learned test runner run only the verified test commands", ctx do
      runner = fn command ->
        input =
          Jason.encode!(%{
            "hook_event_name" => "PreToolUse",
            "tool_name" => "Bash",
            "agent_id" => "agent-1",
            "agent_type" => "olivium-test-runner",
            "tool_input" => %{"command" => command}
          })

        {out, 0} = run(ctx.guard, ctx.dir, input)
        out
      end

      assert runner.("uv run pytest -q -p no:cacheprovider --tb=short tests/test_retry.py") == ""
      assert runner.("uv run pytest tests/test_retry.py 2>&1 | tail -n 40") == ""

      for command <- ["ls tests", "uv run python -c 1", "uv run pytest; rm x", "curl x"] do
        assert runner.(command) =~
                 "the test runner runs only: uv run pytest; uv run pytest -q -p no:cacheprovider --tb=short",
               command
      end

      # The main session is not limited by the runner rule.
      main =
        Jason.encode!(%{
          "hook_event_name" => "PreToolUse",
          "tool_name" => "Bash",
          "tool_input" => %{"command" => "ls tests"}
        })

      assert {"", 0} = run(ctx.guard, ctx.dir, main)
    end
  end

  test "no rewrite and a failed gate render neither hook" do
    doc = LeanAiFixture.prepared()["bundle"] |> Map.put("rewrites", [])
    doc = Map.put(doc, "sha256", Contracts.digest(Map.delete(doc, "sha256")))

    gate = %{
      "status" => "failed",
      "replay_n" => 30,
      "top3_hits" => 10,
      "wrong" => 9,
      "max_card_bytes" => 300
    }

    artifact = package(LeanAiFixture.prepared(%{"bundle" => doc, "gate" => gate}))
    settings = Jason.decode!(artifact["files"][".claude/settings.json"])

    refute Map.has_key?(artifact["files"], Rewrite.path())
    refute Map.has_key?(artifact["files"], Locator.path())
    assert artifact["files"][Rewrite.data_path()] == ""
    assert length(settings["hooks"]["PreToolUse"]) == 1
    refute Map.has_key?(settings["hooks"], "UserPromptSubmit")
  end
end
