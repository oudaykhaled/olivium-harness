Code.require_file("../../fixtures/learning/learning_case.exs", __DIR__)

defmodule HarnessForge.LearningTest do
  use ExUnit.Case, async: true

  alias HarnessForge.CLI.Learn, as: CLI
  alias HarnessForge.Learning
  alias HarnessForge.Learning.{Bundle, Verify}
  alias HarnessForge.LearningCase

  @image "olivium-bench-deps-synthetic:v1"

  setup do
    root = Path.join(System.tmp_dir!(), "hf-learn-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {repo, side} = LearningCase.repository(Path.join(root, "widgets"))
    raw = Jason.encode!(LearningCase.raw(repo, side))
    {:ok, root: root, repo: repo, raw: raw}
  end

  defp mock(raw) do
    [
      verify_image: @image,
      mock_plan: ~s({"steps": []}),
      launcher: LearningCase.launcher(raw),
      verify_runner: LearningCase.runner()
    ]
  end

  test "a mock run keeps checked and verified items and drops the rest with reasons",
       %{root: root, repo: repo, raw: raw} do
    out = Path.join(root, "out-1")
    assert {:ok, summary} = Learning.learn(repo, out, mock(raw))
    assert_received {:launcher_spec, %{mode: :mock, plan: ~s({"steps": []})}}

    assert {:ok, doc} = Bundle.read(out)
    assert doc["sha256"] == summary["sha256"]
    assert doc["learner"]["status"] == "mock"
    assert doc["learner"]["model"] == "mock"
    assert doc["learner"]["wall_ms"] == 0
    assert doc["learner"]["prompt_sha256"] == Learning.prompt_sha256()
    assert doc["verification"]["status"] == "ok"
    assert doc["verification"]["network"] == "none"

    assert [%{"id" => "c01", "paths" => ["src/acme_widgets/parser.py"]}] = doc["concepts"]
    assert Enum.map(doc["pitfalls"], & &1["id"]) == ["p01", "p02"]
    assert Enum.find(doc["pitfalls"], &(&1["scope"] == "concept"))["concept"] == "c01"

    # mypy is missing in the stub image: a deterministic missing_tool rewrite with the
    # fixed message; the learned duplicate of it is dropped.
    mypy =
      Enum.find(
        doc["rewrites"],
        &(&1["kind"] == "missing_tool" and &1["match"]["argv_prefix"] == ["uv", "run", "mypy"])
      )

    assert mypy["source"] == "deterministic"
    assert mypy["replace"] == %{"message_id" => "tool_missing", "tool" => "mypy"}
    assert mypy["verify"]["bytes_after"] == Bundle.bucket_bytes(byte_size(Verify.message("mypy")))

    quiet = Enum.find(doc["rewrites"], &(&1["kind"] == "quiet_flags"))
    assert quiet["source"] == "learned"

    roles = Map.new(doc["commands"], &{&1["role"], &1})
    assert roles["test_file"]["argv"] == ["uv", "run", "pytest", "-q", "{file}"]
    assert roles["test_file"]["source"] == "learned"
    assert roles["test_file"]["verify"]["sample_arg"] =~ ~r/^tests\/test_/
    # Timings vary between runs; the bundle keeps 0 and the report keeps the exact value.
    assert Enum.all?(doc["commands"] ++ doc["rewrites"], &(&1["verify"]["ms"] == 0))
    refute Map.has_key?(roles, "typecheck")

    dropped = Map.new(doc["dropped"], &{{&1["kind"], &1["id"]}, &1["reason"]})
    assert dropped[{"concept", "c02"}] == "path_missing_at_base"
    assert dropped[{"concept", "c03"}] == "evidence_after_base"
    assert dropped[{"pitfall", "p03"}] == "text_unsafe"
    assert dropped[{"pitfall", "p06"}] == "pattern_too_common"
    assert dropped[{"pitfall", "p07"}] == "example_copy"
    # It names mypy, which the stub image proved missing.
    assert dropped[{"pitfall", "p08"}] == "tool_missing"
    refute Enum.any?(doc["pitfalls"], &(&1["text"] =~ "mypy"))
    assert dropped[{"command", "cmd-test-l2"}] == "unsafe_argv"
    assert dropped[{"command", "cmd-typecheck-l4"}] == "network_required"
    assert dropped[{"rewrite", "rw-l2"}] == "duplicate"
    assert dropped[{"rewrite", "rw-l3"}] == "unsafe_argv"

    assert Enum.any?(
             doc["dropped"],
             &(&1["kind"] == "command" and &1["reason"] == "tool_missing")
           )

    # Files beside the bundle: the exact report, the extract, the raw learner output and
    # the learner's transcript (for audit).
    for name <-
          ~w(learned.json learned.sha256 learn-report.json learn-input.json learner-raw.json learner-transcript.jsonl) do
      assert File.regular?(Path.join(out, name))
    end

    report = out |> Path.join("learn-report.json") |> File.read!() |> Jason.decode!()
    assert report["learner"]["wall_ms_exact"] == 1234
    assert report["bundle_sha256"] == doc["sha256"]
  end

  describe "skills and agents (learner prompt v2)" do
    defp native_raw(repo) do
      # The side-branch commit is not reachable from HEAD; find it the way the case does.
      side =
        repo
        |> HarnessForge.SyntheticRepositories.git!(["rev-parse", "side"])
        |> String.trim()

      Jason.encode!(LearningCase.native_raw(repo, side))
    end

    test "a mock run keeps checked skills and agents with fixed ids and drops the rest",
         %{root: root, repo: repo} do
      out = Path.join(root, "out-native")
      assert {:ok, summary} = Learning.learn(repo, out, mock(native_raw(repo)))
      assert {:ok, doc} = Bundle.read(out)
      assert doc["learner"]["prompt_id"] == "learner-prompt/v2"

      assert [skill] = doc["skills"]

      assert skill == %{
               "id" => "s01",
               "kind" => "area",
               "concept" => "c01",
               "slug" => "parser",
               "paths" => ["src/acme_widgets/parser.py", "src/acme_widgets/client.py"],
               "tests" => ["tests/test_parser.py"],
               "symbols" => [],
               "pitfalls" => [Enum.find(doc["pitfalls"], &(&1["scope"] == "concept"))["id"]],
               "evidence" => skill["evidence"]
             }

      assert Enum.map(doc["agents"], &{&1["id"], &1["kind"], &1["commands"]}) == [
               {"a01", "locator", []},
               {"a02", "test_runner", ["cmd-test", "cmd-test-file"]}
             ]

      ids = MapSet.new(doc["commands"], & &1["id"])
      assert MapSet.member?(ids, "cmd-test") and MapSet.member?(ids, "cmd-test-file")

      dropped =
        doc["dropped"]
        |> Enum.filter(&(&1["kind"] in ["skill", "agent"]))
        |> Map.new(&{&1["id"], &1["reason"]})

      assert dropped == %{
               "s02" => "path_missing_at_base",
               "s03" => "evidence_after_base",
               "s04" => "evidence_missing",
               "s05" => "evidence_mismatch",
               "s06" => "schema_invalid",
               "s07" => "over_limit",
               "a02" => "not_verified",
               "a04" => "over_limit"
             }

      assert summary["kept"]["skills"] == 1
      assert summary["kept"]["agents"] == 2
      assert summary["dropped_kinds"]["skill"] == 6
      assert summary["dropped_kinds"]["agent"] == 2
      text = CLI.summary(summary)
      assert text =~ "skills 1 kept, agents 2 kept"
      assert text =~ "skills 6, agents 2)"
      assert {:ok, ^doc} = Bundle.validate(doc)
    end

    test "two native runs give byte-identical bundles", %{root: root, repo: repo} do
      raw = native_raw(repo)
      {:ok, a} = Learning.learn(repo, Path.join(root, "native-a"), mock(raw))
      {:ok, b} = Learning.learn(repo, Path.join(root, "native-b"), mock(raw))
      assert a["sha256"] == b["sha256"]

      assert File.read!(Path.join(root, "native-a/learned.json")) ==
               File.read!(Path.join(root, "native-b/learned.json"))
    end

    test "without verification every test_runner is not_verified; the locator stays",
         %{root: root, repo: repo} do
      out = Path.join(root, "native-nodocker")

      opts =
        Keyword.put(
          mock(native_raw(repo)),
          :verify_runner,
          LearningCase.runner({:unavailable, "no_docker"})
        )

      {:ok, _} = Learning.learn(repo, out, opts)
      {:ok, doc} = Bundle.read(out)
      assert Enum.map(doc["agents"], & &1["kind"]) == ["locator"]

      assert doc["dropped"]
             |> Enum.filter(&(&1["kind"] == "agent" and &1["reason"] == "not_verified"))
             |> length() == 2
    end

    test "a learner that did not run writes empty skills and agents", %{root: root, repo: repo} do
      out = Path.join(root, "native-none")

      {:ok, summary} =
        Learning.learn(repo, out,
          verify_image: @image,
          launcher: fn _ -> flunk("the learner must not start") end,
          verify_runner: LearningCase.runner()
        )

      {:ok, doc} = Bundle.read(out)
      assert doc["skills"] == [] and doc["agents"] == []
      assert CLI.summary(summary) =~ "skills 0 kept, agents 0 kept"

      # A skill on a learner that did not run is inconsistent.
      skill = %{
        "id" => "s01",
        "kind" => "area",
        "concept" => "c01",
        "slug" => "x",
        "paths" => ["a.py", "b.py"],
        "tests" => [],
        "symbols" => [],
        "pitfalls" => [],
        "evidence" => [String.duplicate("a", 40), String.duplicate("b", 40)]
      }

      tampered = Map.put(doc, "skills", [skill])

      tampered =
        Map.put(tampered, "sha256", HarnessForge.Contracts.digest(Map.delete(tampered, "sha256")))

      assert {:error, %{code: "learned_invalid"}} = Bundle.validate(tampered)
    end

    test "validation rejects skills and agents that reference what the bundle does not hold",
         %{root: root, repo: repo} do
      out = Path.join(root, "native-v")
      {:ok, _} = Learning.learn(repo, out, mock(native_raw(repo)))
      {:ok, doc} = Bundle.read(out)
      resign = &Map.put(&1, "sha256", HarnessForge.Contracts.digest(Map.delete(&1, "sha256")))

      [skill] = doc["skills"]
      [locator, runner] = doc["agents"]

      for bad <- [
            %{doc | "skills" => [%{skill | "concept" => "c09"}]},
            %{doc | "skills" => [%{skill | "pitfalls" => ["p09"]}]},
            %{doc | "skills" => [Map.put(skill, "text", "free text")]},
            %{doc | "agents" => [locator, %{runner | "commands" => ["cmd-nope"]}]},
            %{doc | "agents" => [locator, %{runner | "commands" => ["cmd-lint"]}]},
            %{doc | "agents" => [%{locator | "commands" => ["cmd-test"]}, runner]},
            %{doc | "agents" => [locator, %{runner | "kind" => "locator", "commands" => []}]}
          ] do
        assert {:error, %{code: "learned_invalid"}} = Bundle.validate(resign.(bad)),
               inspect(bad["agents"])
      end
    end
  end

  test "a test command that runs no test is not verified", %{repo: repo} do
    {:ok, extract} = HarnessForge.Learning.Extract.build(repo)

    result =
      Verify.run(%{
        ctx: nil,
        image: @image,
        extract: extract,
        commands: [
          %{
            key: "cmd-test-l1",
            source: "learned",
            role: "test",
            argv: ~w(uv run pytest --collect-nothing)
          },
          %{
            key: "cmd-test-file-l2",
            source: "learned",
            role: "test_file",
            argv: ~w(uv run pytest -q {file})
          },
          %{
            key: "cmd-lint-l3",
            source: "learned",
            role: "lint",
            argv: ~w(uv run ruff --collect-nothing)
          }
        ],
        rewrites: [],
        tools: [],
        runner: LearningCase.runner()
      })

    assert Enum.map(result.commands, & &1.key) |> Enum.sort() == [
             "cmd-lint-l3",
             "cmd-test-file-l2"
           ]

    assert %{"reason" => "verify_failed"} =
             Enum.find(result.dropped, &(&1["id"] == "cmd-test-l1"))

    assert %{"zero_tests" => 1} =
             Enum.find(result.report["commands"], &(&1["id"] == "cmd-test-l1"))
  end

  test "the learner sees tracked files and .git only", %{root: root, repo: repo} do
    {:ok, extract} = HarnessForge.Learning.Extract.build(repo)
    File.write!(Path.join(repo, ".env"), "SECRET=1\n")
    File.mkdir_p!(Path.join(repo, "node_modules/pkg"))
    File.write!(Path.join(repo, "node_modules/pkg/index.js"), "x\n")
    outside = Path.join(root, "outside")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "secret.txt"), "outside\n")

    dest = Path.join(root, "staged")
    assert :ok = HarnessForge.Learning.Launcher.stage_repository(extract, dest)

    assert File.read!(Path.join(dest, "src/acme_widgets/parser.py")) ==
             File.read!(Path.join(repo, "src/acme_widgets/parser.py"))

    assert File.dir?(Path.join(dest, ".git"))
    refute File.exists?(Path.join(dest, ".env"))
    refute File.exists?(Path.join(dest, "node_modules"))
    refute File.exists?(Path.join(dest, "outside"))
    assert {:error, :exists} = HarnessForge.Learning.Launcher.stage_repository(extract, dest)
  end

  test "two runs give byte-identical bundles; an existing --out is refused",
       %{root: root, repo: repo, raw: raw} do
    first = Path.join(root, "out-a")
    second = Path.join(root, "out-b")
    assert {:ok, a} = Learning.learn(repo, first, mock(raw))
    assert {:ok, b} = Learning.learn(repo, second, mock(raw))
    assert a["sha256"] == b["sha256"]

    assert File.read!(Path.join(first, "learned.json")) ==
             File.read!(Path.join(second, "learned.json"))

    assert File.read!(Path.join(first, "learned.sha256")) ==
             File.read!(Path.join(second, "learned.sha256"))

    before = File.read!(Path.join(first, "learned.json"))
    assert {:error, %{code: "out_not_fresh"}} = Learning.learn(repo, first, mock(raw))
    assert File.read!(Path.join(first, "learned.json")) == before
  end

  test "without --allow-cloud no model runs and the status says so", %{root: root, repo: repo} do
    out = Path.join(root, "out-none")

    opts = [
      verify_image: @image,
      launcher: fn _ -> flunk("the learner must not start") end,
      verify_runner: LearningCase.runner()
    ]

    assert {:ok, summary} = Learning.learn(repo, out, opts)
    {:ok, doc} = Bundle.read(out)
    assert doc["learner"]["status"] == "unavailable"
    assert doc["learner"]["status_reason"] == "cloud_not_allowed"
    assert doc["learner"]["engine"] == "none"
    assert doc["learner"]["model"] == "none"
    assert doc["learner"]["requests"] == 0
    assert doc["concepts"] == [] and doc["pitfalls"] == []
    assert Enum.all?(doc["commands"], &(&1["source"] == "deterministic"))
    assert Enum.all?(doc["rewrites"], &(&1["source"] == "deterministic"))
    refute File.exists?(Path.join(out, "learner-raw.json"))
    assert CLI.summary(summary) =~ "AI learning: unavailable (cloud_not_allowed)"
  end

  test "without Docker every command is not_verified and verification is unavailable",
       %{root: root, repo: repo, raw: raw} do
    out = Path.join(root, "out-nodocker")

    opts =
      Keyword.put(mock(raw), :verify_runner, LearningCase.runner({:unavailable, "no_docker"}))

    assert {:ok, summary} = Learning.learn(repo, out, opts)
    {:ok, doc} = Bundle.read(out)
    assert doc["verification"]["status"] == "unavailable"
    assert doc["verification"]["status_reason"] == "no_docker"
    assert doc["commands"] == [] and doc["rewrites"] == []

    command_reasons =
      doc["dropped"]
      |> Enum.filter(&(&1["kind"] == "command"))
      |> Enum.map(& &1["reason"])
      |> Enum.uniq()

    assert "not_verified" in command_reasons
    assert CLI.summary(summary) =~ "verification unavailable: no_docker"
  end

  test "learner output that is not a JSON object fails visibly", %{root: root, repo: repo} do
    out = Path.join(root, "out-invalid")
    assert {:ok, _} = Learning.learn(repo, out, mock("not json"))
    {:ok, doc} = Bundle.read(out)
    assert doc["learner"]["status"] == "failed"
    assert doc["learner"]["status_reason"] == "invalid_output"
    assert doc["concepts"] == [] and doc["pitfalls"] == []
  end

  test "validation rejects tampered bundles", %{root: root, repo: repo, raw: raw} do
    out = Path.join(root, "out-v")
    {:ok, _} = Learning.learn(repo, out, mock(raw))
    {:ok, doc} = Bundle.read(out)
    assert {:ok, ^doc} = Bundle.validate(doc)

    [command | rest] = doc["commands"]
    unsafe = %{doc | "commands" => [%{command | "argv" => ["sh", "-c", "true"]} | rest]}
    assert {:error, %{code: "learned_invalid"}} = Bundle.validate(unsafe)

    [pitfall | others] = doc["pitfalls"]

    texty = %{
      doc
      | "pitfalls" => [
          %{pitfall | "text" => "See https://example.invalid for details now."} | others
        ]
    }

    assert {:error, %{code: "learned_invalid"}} = Bundle.validate(texty)

    assert {:error, %{code: "learned_invalid"}} =
             Bundle.validate(%{doc | "sha256" => String.duplicate("0", 64)})

    assert {:error, %{code: "learned_invalid"}} = Bundle.validate(Map.put(doc, "note", "x"))

    # A concept on an unavailable learner is inconsistent.
    status = put_in(doc, ["learner", "status"], "unavailable")
    assert {:error, %{code: "learned_invalid"}} = Bundle.validate(status)

    File.write!(Path.join(out, "learned.json"), Jason.encode!(doc) <> " ")
    assert {:error, %{code: "learned_invalid"}} = Bundle.read(out)
  end

  describe "CLI usage" do
    test "refusals are usage errors (exit 2)", %{root: root, repo: repo} do
      out = Path.join(root, "cli-out")
      base = [repo, "--out", out, "--verify-image", @image]

      for args <- [
            base ++ ["--allow-cloud"],
            base ++ ["--key-file", "/nonexistent/key"],
            base ++ ["--allow-cloud", "--key-file", "relative/key"],
            base ++ ["--allow-cloud", "--key-file", "/k", "--mock-plan", "/p.json"],
            base ++ ["--model", "gpt-4"],
            base ++ ["--cap-usd", "9.00"],
            base ++ ["--cap-usd", "0"],
            base ++ ["--max-turns", "0"],
            base ++ ["--meter-url", "http://meter:8080/run/x"],
            base ++ ["--meter-url", "https://meter/run/x", "--network", "n"],
            [repo, "--verify-image", @image],
            [repo, "--out", out],
            ["relative", "--out", out, "--verify-image", @image],
            base ++ ["--json", "--json"]
          ] do
        assert {:error, %{code: "invalid_arguments"}} = CLI.run(args), inspect(args)
      end

      refute File.exists?(out)
    end

    test "an invalid repository and an existing --out are exit-1 errors", %{
      root: root,
      repo: repo
    } do
      plain = Path.join(root, "plain")
      File.mkdir_p!(plain)
      out = Path.join(root, "cli-out")

      assert {:error, %{code: "not_a_git_repository"}} =
               CLI.run([plain, "--out", out, "--verify-image", @image])

      File.mkdir_p!(out)

      assert {:error, %{code: "out_not_fresh"}} =
               CLI.run([repo, "--out", out, "--verify-image", @image])
    end

    test "a mock plan must be a JSON object with a steps list", %{root: root, repo: repo} do
      plan = Path.join(root, "plan.json")
      File.write!(plan, ~s({"no_steps": true}))
      out = Path.join(root, "cli-plan")

      assert {:error, %{code: "invalid_mock_plan"}} =
               CLI.run([repo, "--out", out, "--verify-image", @image, "--mock-plan", plan])
    end
  end
end
