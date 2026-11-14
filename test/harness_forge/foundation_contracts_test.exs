defmodule HarnessForge.FoundationContractsTest do
  use ExUnit.Case, async: true

  alias HarnessForge.{Compiler, Contracts, Generation}
  alias HarnessForge.Analyzers.{Mapping, Repository}
  alias HarnessForge.Contracts.{Error, HarnessV2, Signals}
  alias HarnessForge.Generation.Profile

  @digest String.duplicate("a", 64)
  @rule_id "11111111-1111-4111-8111-111111111111"
  @other_id "22222222-2222-4222-8222-222222222222"
  @goal_id "33333333-3333-4333-8333-333333333333"

  defp derived(id \\ @rule_id) do
    %{
      "id" => id,
      "origin" => "derived",
      "statement" => "Run mix test before finishing a change",
      "fingerprint" => @digest,
      "source" => %{
        "detector" => "stack",
        "signal" => "commands.test",
        "path" => "mix.exs",
        "line" => 3
      }
    }
  end

  defp approved(id \\ @other_id) do
    %{
      "id" => id,
      "origin" => "approved_claim",
      "statement" => "A human approved this",
      "revision_hash" => @digest,
      "evidence" => [],
      "goal_id" => @goal_id
    }
  end

  defp spec do
    %{
      "apiVersion" => "harnessforge.dev/v1alpha2",
      "kind" => "Harness",
      "metadata" => %{"name" => "acme", "version" => "1.0.0"},
      "spec" => %{
        "runtime" => %{"name" => "claude_code", "version" => "unqualified"},
        "scope" => %{"repositories" => ["acme/widgets"]},
        "project" => %{
          "name" => "acme",
          "languages" => ["elixir"],
          "frameworks" => [],
          "package_managers" => ["hex"],
          "commands" => Map.put(Map.new(Profile.command_keys(), &{&1, nil}), "test", "mix test"),
          "layout" => [%{"path" => "lib", "purpose" => "source"}],
          "conventions" => [],
          "ci" => []
        },
        "guidance" => [%{"id" => "commands", "title" => "Commands", "lines" => ["`mix test`"]}],
        "rules" => [derived(), approved()],
        "goals" => [
          %{"id" => @goal_id, "owner" => "owner", "statement" => "goal", "acceptance" => ["done"]}
        ],
        "policies" => [],
        "agents" => [],
        "skills" => [],
        "hooks" => [
          %{
            "id" => "test-before-stop",
            "event" => "before_stop",
            "command" => "mix test",
            "timeout_seconds" => 120,
            "file_argument" => false
          }
        ],
        "permissions" => %{
          "commands" => [%{"id" => "test", "command" => "mix test", "action" => "allow"}],
          "paths" => [
            %{"id" => "env", "pattern" => ".env", "access" => "read", "action" => "deny"}
          ]
        },
        "execution" => %{"max_turns" => 10, "timeout_seconds" => 60},
        "evaluation" => %{"suite" => "default"},
        "generation" => %{
          "mode" => "solo",
          "profile_digest" => @digest,
          "overlay_digest" => nil,
          "blueprint_version" => "base-1"
        }
      }
    }
  end

  defp errors(value) do
    assert {:error, %Error{code: "invalid_harness", details: details}} =
             Contracts.validate_harness(value)

    details
  end

  defp put_rule(spec, rule), do: put_in(spec, ["spec", "rules"], [rule])

  describe "v1alpha2 spec" do
    test "a complete spec validates" do
      assert {:ok, _} = Contracts.validate_harness(spec())
    end

    test "origin decides what backs a rule" do
      assert errors(put_rule(spec(), Map.delete(derived(), "fingerprint")))
             |> Enum.any?(&(&1 =~ "fingerprint"))

      assert errors(put_rule(spec(), Map.delete(derived(), "source")))
             |> Enum.any?(&(&1 =~ "source"))

      assert errors(put_rule(spec(), Map.put(derived(), "revision_hash", @digest)))
             |> Enum.any?(&(&1 =~ "revision_hash: not allowed"))

      assert errors(put_rule(spec(), Map.put(approved(), "fingerprint", @digest)))
             |> Enum.any?(&(&1 =~ "fingerprint: not allowed"))

      assert errors(put_rule(spec(), Map.delete(approved(), "revision_hash")))
             |> Enum.any?(&(&1 =~ "revision_hash: required"))

      no_basis = approved() |> Map.put("goal_id", nil)

      assert errors(put_rule(spec(), no_basis))
             |> Enum.any?(&(&1 =~ "evidence or an explicit goal"))

      assert errors(put_rule(spec(), Map.put(derived(), "statement", "one\n## Injected")))
             |> Enum.any?(&(&1 =~ "single line"))

      assert errors(put_rule(spec(), Map.put(derived(), "origin", "model")))
             |> Enum.any?(&(&1 =~ "origin"))
    end

    test "commands carry no shell metacharacters" do
      for command <- [
            "mix test; rm -rf /",
            "a | b",
            "a && b",
            "echo $(id)",
            "echo `id`",
            "cat > out",
            "curl x\n",
            "-rf x"
          ] do
        bad =
          put_in(spec(), ["spec", "permissions", "commands"], [
            %{"id" => "bad", "command" => command, "action" => "allow"}
          ])

        assert {:error, %Error{code: "invalid_harness"}} = Contracts.validate_harness(bad),
               "accepted #{inspect(command)}"
      end
    end

    test "hooks may only run declared project commands" do
      undeclared = put_in(spec(), ["spec", "hooks", Access.at(0), "command"], "rm -rf build")
      assert errors(undeclared) |> Enum.any?(&(&1 =~ "declared project command"))

      file_argument = put_in(spec(), ["spec", "hooks", Access.at(0), "file_argument"], true)
      assert errors(file_argument) |> Enum.any?(&(&1 =~ "only after_edit"))
    end

    test "a before_stop role hook runs a declared command's prefix on the changed files" do
      staged = fn hook ->
        spec()
        |> put_in(["spec", "project", "commands", "lint"], "mix credo --strict lib")
        |> put_in(["spec", "hooks"], [hook])
      end

      lint = %{
        "id" => "lint-before-stop",
        "event" => "before_stop",
        "role" => "lint",
        "selector" => "changed_files",
        "command" => "mix credo --strict",
        "file_argument" => true,
        "timeout_seconds" => 60
      }

      assert {:ok, _} = Contracts.validate_harness(staged.(lint))

      assert {:ok, _} =
               Contracts.validate_harness(
                 staged.(%{lint | "command" => "mix credo --strict lib"})
               )

      assert errors(staged.(%{lint | "command" => "mix credo --strict lib x"}))
             |> Enum.any?(&(&1 =~ "declared project command"))

      assert errors(staged.(%{lint | "command" => "mix crash"}))
             |> Enum.any?(&(&1 =~ "declared project command"))

      assert errors(staged.(%{lint | "selector" => "related_tests"}))
             |> Enum.any?(&(&1 =~ "selector"))

      assert errors(staged.(%{lint | "event" => "after_edit"})) |> Enum.any?(&(&1 =~ "role"))
      assert {:error, _} = Contracts.validate_harness(staged.(%{lint | "role" => "deploy"}))
    end

    test "built-in hooks carry no command and run only on their own event" do
      env = %{
        "id" => "env-check",
        "event" => "session_start",
        "builtin" => "env_check",
        "timeout_seconds" => 5
      }

      with_hook = &put_in(spec(), ["spec", "hooks"], [&1])

      assert {:ok, _} = Contracts.validate_harness(with_hook.(env))

      assert errors(with_hook.(%{env | "builtin" => "locator"}))
             |> Enum.any?(&(&1 =~ "prompt_submit"))

      assert {:error, _} =
               Contracts.validate_harness(with_hook.(Map.put(env, "command", "mix test")))

      assert {:error, _} = Contracts.validate_harness(with_hook.(%{env | "builtin" => "shell"}))

      assert {:error, _} =
               Contracts.validate_harness(with_hook.(%{env | "event" => "before_stop"}))
    end

    test "the context profile is closed to the measured tool names" do
      context = %{
        "profile" => "lean",
        "include_git_instructions" => false,
        "auto_memory" => true,
        "deny_tools" => ~w(CronCreate Skill Task Workflow),
        "measured_on" => "claude-code 2.1.311",
        "est_tokens_saved_per_request" => 11_700
      }

      with_context = &put_in(spec(), ["spec", "context"], &1)

      assert {:ok, _} = Contracts.validate_harness(with_context.(context))
      assert {:ok, _} = Contracts.validate_harness(spec())

      # History-derived skills and agents keep Skill and Task; the switches are booleans.
      native_context =
        Map.merge(context, %{
          "deny_tools" => ~w(CronCreate Workflow),
          "kept_tools" => ~w(Skill Task),
          "disable_bundled_skills" => true,
          "disable_builtin_agents" => true
        })

      assert {:ok, _} = Contracts.validate_harness(with_context.(native_context))

      for bad <- [
            %{context | "deny_tools" => ["Bash"]},
            %{context | "deny_tools" => ["ToolSearch"]},
            %{context | "deny_tools" => ["Task", "Task"]},
            %{context | "profile" => "tiny"},
            %{context | "est_tokens_saved_per_request" => 1.5},
            Map.put(context, "disable_bundled_skills", "true"),
            Map.put(context, "kept_tools", ["Workflow"]),
            Map.put(context, "kept_tools", ["Task", "Task"]),
            Map.put(context, "keep_tools", ["Task"]),
            Map.delete(context, "measured_on")
          ] do
        assert {:error, %Error{code: "invalid_harness"}} =
                 Contracts.validate_harness(with_context.(bad)),
               inspect(bad)
      end
    end

    test "project tools, test pairs and co-change rows are bounded plain data" do
      project = fn key, value -> put_in(spec(), ["spec", "project", key], value) end

      tool = %{
        "role" => "test",
        "command" => "mix test",
        "probe" => ["mix"],
        "extensions" => [".exs"],
        "source" => "manifest_tool"
      }

      pair = %{
        "source" => "lib/a.ex",
        "test" => "test/a_test.exs",
        "support" => 2,
        "kind" => "named_after"
      }

      row = %{"path" => "lib/a.ex", "partner" => "lib/b.ex", "support" => 4, "percent" => 40}

      assert {:ok, _} = Contracts.validate_harness(project.("tools", [tool]))
      assert {:ok, _} = Contracts.validate_harness(project.("test_pairs", [pair]))
      assert {:ok, _} = Contracts.validate_harness(project.("cochange", [row]))

      for bad <- [
            project.("tools", [%{tool | "probe" => ["mix;rm"]}]),
            project.("tools", [%{tool | "probe" => []}]),
            project.("tools", [%{tool | "extensions" => ["exs"]}]),
            project.("tools", [%{tool | "role" => "deploy"}]),
            project.("tools", List.duplicate(tool, 6)),
            project.("test_pairs", [%{pair | "source" => "../a.ex"}]),
            project.("test_pairs", [%{pair | "source" => "lib/a b.ex"}]),
            project.("test_pairs", [%{pair | "test" => "-test/a_test.exs"}]),
            project.("test_pairs", [%{pair | "support" => 1}]),
            project.("test_pairs", List.duplicate(pair, 201)),
            project.("cochange", [%{row | "percent" => 39}]),
            project.("cochange", [%{row | "support" => 3}]),
            project.("cochange", [%{row | "partner" => "lib//b.ex"}])
          ] do
        assert {:error, %Error{code: "invalid_harness"}} = Contracts.validate_harness(bad),
               inspect(
                 get_in(bad, ["spec", "project"])
                 |> Map.take(~w(tools test_pairs cochange))
               )
      end
    end

    test "paths stay contained and identifiers stay unique" do
      for path <- ["/etc", "../up", "a/../b", "~/x"] do
        bad = put_in(spec(), ["spec", "project", "layout", Access.at(0), "path"], path)
        assert {:error, %Error{code: "invalid_harness"}} = Contracts.validate_harness(bad), path
      end

      duplicated = put_in(spec(), ["spec", "rules"], [derived(), derived()])
      assert errors(duplicated) |> Enum.any?(&(&1 =~ "duplicate identifiers"))

      assert {:error, _} = Contracts.validate_harness(Map.put(spec(), "approved", true))
    end

    test "eligibility inspects only approved_claim rules, and every v1alpha1 rule" do
      assert [%{"id" => @other_id}] = HarnessV2.approved_claim_rules(spec())
      assert HarnessV2.solo_generated?(spec())

      v1 = %{"apiVersion" => "harnessforge.dev/v1alpha1", "spec" => %{"rules" => [derived()]}}
      assert [_] = HarnessV2.approved_claim_rules(v1)
      refute HarnessV2.solo_generated?(v1)
    end

    test "targets without v1alpha2 support are visibly unsupported, never downgraded" do
      for target <- ["codex", "opencode"] do
        request = put_in(spec(), ["spec", "runtime", "name"], target)

        assert {:error, %Error{code: "unsupported_target", details: [^target]}} =
                 Compiler.compile(request)

        assert {:error, %Error{code: "unsupported_runtime"}} =
                 Generation.generate(%{"target" => target})
      end

      assert {:error, %Error{code: "runtime_unqualified"}} =
               Compiler.compile(spec(), mode: :managed)
    end

    test "assembly is deterministic and keeps compiler metadata under .olivium" do
      output = %{
        "files" => %{"CLAUDE.md" => "# acme\n"},
        "capabilities" => [],
        "diagnostics" => []
      }

      identity = %{"name" => "claude_code"}

      first = Compiler.assemble_v2(spec(), output, identity)
      assert first == Compiler.assemble_v2(spec(), output, identity)

      assert Enum.sort(Map.keys(first["files"])) == [
               ".olivium/capabilities.json",
               ".olivium/manifest.json",
               ".olivium/provenance.json",
               ".olivium/spec.json",
               "CLAUDE.md"
             ]

      provenance = Jason.decode!(first["files"][".olivium/provenance.json"])
      assert Enum.map(provenance["rules"], & &1["origin"]) == ["derived", "approved_claim"]
      assert hd(provenance["rules"])["source"]["path"] == "mix.exs"
      assert first["manifest"]["compiler"]["template_version"] == "v1alpha2.4"
    end

    test "a stored preview from an older template is refused with preview_regenerate" do
      {:ok, result} = Generation.plan(%{"profile" => profile("python_package")})
      artifact = result["artifact"]
      assert :ok = Compiler.verify(artifact)

      older = put_in(artifact, ["manifest", "compiler", "template_version"], "v1alpha2.2")

      assert {:error, %Error{code: "preview_regenerate", message: message}} =
               Compiler.verify(older)

      assert message =~ "Generate it again"

      # Any other mismatch keeps the generic refusal.
      tampered = put_in(artifact, ["files", "CLAUDE.md"], "tampered\n")
      assert {:error, %Error{code: "invalid_artifact"}} = Compiler.verify(tampered)
    end
  end

  describe "v1alpha1 stays on its own path" do
    test "the frozen schema is untouched and v2 fields are refused" do
      assert Contracts.schema()["$id"] =~ "harness-v1alpha1.json"

      v1 =
        "../../examples/synthetic_company/harness.json"
        |> Path.expand(__DIR__)
        |> File.read!()
        |> Jason.decode!()

      assert {:ok, _} = Contracts.validate_harness(v1)

      assert {:error, %Error{code: "invalid_harness"}} =
               Contracts.validate_harness(put_in(v1, ["spec", "hooks"], []))
    end
  end

  describe "RepoProfile" do
    defp profile(name) do
      "../../examples/profiles/#{name}.json"
      |> Path.expand(__DIR__)
      |> File.read!()
      |> Jason.decode!()
    end

    test "every committed fixture validates" do
      for name <- ~w(python_package node_package elixir_project minimal) do
        assert {:ok, loaded} = Profile.validate(profile(name)), name
        assert Profile.digest(loaded) =~ ~r/^[0-9a-f]{64}$/
      end
    end

    test "the empty profile validates" do
      assert {:ok, _} = Profile.validate(Profile.empty("plain-directory"))
    end

    test "commands, paths, buckets and unknown fields are enforced" do
      base = profile("elixir_project")

      for bad <- [
            put_in(base, ["commands", "test"], "mix test && curl x"),
            put_in(base, ["commands", "test"], "mix test\n"),
            Map.put(base, "extra", true),
            Map.delete(base, "existing_harness"),
            put_in(base, ["layout", Access.at(0), "path"], "/etc"),
            put_in(base, ["layout", Access.at(0), "path"], "../up"),
            put_in(base, ["existing_harness", "files"], ["../CLAUDE.md"]),
            put_in(base, ["rule_candidates", Access.at(0), "confidence"], 12),
            put_in(base, ["rule_candidates", Access.at(0), "citations"], []),
            put_in(base, ["rule_candidates", Access.at(0), "confidence"], 91.5)
          ] do
        assert {:error, %Error{code: "invalid_profile"}} = Profile.validate(bad), inspect(bad)
      end
    end

    test "tools, test pairs and co-change rows are optional, plain and consistent" do
      base = profile("elixir_project")
      bare = Map.drop(base, ~w(tools test_pairs cochange paths_dropped_charset))
      assert {:ok, _} = Profile.validate(bare)

      assert Profile.empty("x") |> Map.take(~w(tools test_pairs cochange paths_dropped_charset)) ==
               %{
                 "tools" => [],
                 "test_pairs" => [],
                 "cochange" => [],
                 "paths_dropped_charset" => 0
               }

      for bad <- [
            put_in(base, ["test_pairs", Access.at(0), "source"], "lib/a b.ex"),
            put_in(base, ["test_pairs", Access.at(0), "source"], "lib/é.ex"),
            put_in(base, ["test_pairs", Access.at(0), "test"], "test/../x_test.exs"),
            put_in(base, ["test_pairs", Access.at(0), "support"], 1),
            put_in(base, ["test_pairs", Access.at(0), "kind"], "guess"),
            put_in(base, ["cochange", Access.at(0), "percent"], 101),
            put_in(base, ["cochange", Access.at(0), "support"], 3),
            put_in(base, ["cochange", Access.at(0), "partner"], "lib/acme_ledger/billing.ex"),
            put_in(base, ["tools", Access.at(0), "command"], nil),
            put_in(base, ["tools", Access.at(0), "source"], "guess"),
            Map.put(base, "paths_dropped_charset", -1)
          ] do
        assert {:error, %Error{code: "invalid_profile"}} = Profile.validate(bad), inspect(bad)
      end
    end
  end

  describe "signals document" do
    defp signal(confidence, bucket) do
      %{
        "key" => "commands.test",
        "value" => "mix test",
        "confidence" => confidence,
        "bucket" => bucket,
        "detector" => "stack",
        "evidence" => [%{"kind" => "file", "path" => "mix.exs", "line" => 3}]
      }
    end

    defp document(signals) do
      %{
        "version" => Signals.version(),
        "repository" => %{
          "identity" => "acme",
          "head" => String.duplicate("b", 40),
          "git" => "available",
          "git_reason" => nil
        },
        "detectors" => [
          %{"name" => "stack", "version" => "1", "complete" => true, "truncated" => false}
        ],
        "signals" => signals,
        "aggregates" => %{}
      }
    end

    test "buckets split at 70 and 40" do
      assert Enum.map([100, 70, 69, 40, 39, 0], &Signals.bucket/1) ==
               ~w(auto auto suggested suggested observed observed)
    end

    test "a well-formed document validates" do
      assert {:ok, _} = Signals.validate(document([signal(70, "auto")]))
    end

    test "floats, wrong buckets, duplicate keys and uncontained paths are refused" do
      for bad <- [
            [signal(70, "suggested")],
            [signal(70, "auto"), signal(70, "auto")],
            [Map.put(signal(70, "auto"), "value", 1.5)],
            [put_in(signal(70, "auto"), ["evidence", Access.at(0), "path"], "/etc/passwd")],
            [put_in(signal(70, "auto"), ["evidence", Access.at(0), "kind"], "url")]
          ] do
        assert {:error, %Error{code: "invalid_signals"}} = Signals.validate(document(bad)),
               inspect(bad)
      end
    end
  end

  describe "pipeline stubs" do
    @describetag :tmp_dir

    test "a plain directory yields a valid document and a valid profile", %{tmp_dir: dir} do
      assert {:ok, document} = Repository.analyze(dir)
      assert {:ok, ^document} = Repository.analyze(dir)
      assert document["repository"]["git"] == "git_unavailable"
      assert document["repository"]["git_reason"] == "not_a_repository"
      refute inspect(document) =~ dir

      assert {:ok, profile} = Mapping.profile(document)
      assert {:ok, _} = Profile.validate(profile)
    end

    test "a missing path is an error rather than an empty result", %{tmp_dir: dir} do
      assert {:error, %Error{code: "invalid_repository_path"}} =
               Repository.analyze(Path.join(dir, "missing"))
    end
  end
end
