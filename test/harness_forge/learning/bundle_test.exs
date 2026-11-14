Code.require_file("../../fixtures/learning/learning_case.exs", __DIR__)

defmodule HarnessForge.Learning.BundleTest do
  use ExUnit.Case, async: true

  alias HarnessForge.Contracts
  alias HarnessForge.Learning.{Bundle, Extract}
  alias HarnessForge.LearningCase

  @shared_fixture Path.expand("../../fixtures/learned/learned-v1.synthetic.json", __DIR__)

  setup_all do
    root = Path.join(System.tmp_dir!(), "hf-learn-bundle-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {repo, side} = LearningCase.repository(Path.join(root, "widgets"))
    {:ok, extract} = Extract.build(repo)
    {:ok, root: root, repo: repo, side: side, extract: extract}
  end

  defp check(raw, extract), do: Bundle.check_raw(Jason.encode!(raw), extract)

  # Only what the skill and agent checks need: concept c1 and its pitfall p2 (the other
  # items make each check run many git calls).
  defp slim(raw) do
    %{
      "concepts" => Enum.take(raw["concepts"], 1),
      "pitfalls" => [Enum.at(raw["pitfalls"], 1)],
      "skills" => raw["skills"],
      "agents" => raw["agents"]
    }
  end

  defp reasons(checked, kind) do
    checked.dropped
    |> Enum.filter(&(&1["kind"] == kind))
    |> Map.new(&{&1["id"], &1["reason"]})
  end

  test "concept checks: paths at the base, evidence before the base, evidence that matches",
       %{repo: repo, side: side, extract: extract} do
    assert {:ok, checked} = check(LearningCase.raw(repo, side), extract)

    assert [concept] = checked.concepts
    assert concept["paths"] == ["src/acme_widgets/parser.py"]
    assert concept["symbols"] == ["VALUE"]
    assert concept["support"] >= 3
    assert checked.report["symbols_removed"] == 1

    assert reasons(checked, "concept") == %{
             "c02" => "path_missing_at_base",
             "c03" => "evidence_after_base",
             "c04" => "evidence_mismatch",
             "c05" => "duplicate",
             "c06" => "evidence_missing"
           }
  end

  test "pitfall checks: safe text, enough evidence, the pattern in the cited diffs",
       %{repo: repo, side: side, extract: extract} do
    {:ok, checked} = check(LearningCase.raw(repo, side), extract)

    {global, scoped} = Enum.split_with(checked.pitfalls, &(&1["scope"] == "global"))

    assert [%{"kind" => "changelog", "evidence" => [_, _, _]}, %{"kind" => "typing"}] =
             Enum.sort_by(global, & &1["kind"])

    assert [%{"kind" => "test_location", "trigger_terms" => ["parser"]} = pitfall] = scoped
    assert pitfall.concept_ref == 0

    # "def test_case" is in 3 of the 12 fix commits (kept); "assert" is in all 12; p7 is
    # the learner prompt's own example text.
    assert reasons(checked, "pitfall") == %{
             "p03" => "text_unsafe",
             "p04" => "evidence_missing",
             "p05" => "evidence_mismatch",
             "p06" => "pattern_too_common",
             "p07" => "example_copy"
           }
  end

  test "a pitfall naming a tool that verification proved missing is dropped",
       %{repo: repo, side: side, extract: extract} do
    {:ok, checked} = check(LearningCase.raw(repo, side), extract)
    missing = [%{kind: "missing_tool", match: ["uv", "run", "mypy"], replace: {:message, "mypy"}}]

    {kept, drops} = Bundle.drop_missing_tool_pitfalls(checked.pitfalls, missing)
    assert drops == [%{"kind" => "pitfall", "id" => "p08", "reason" => "tool_missing"}]
    refute Enum.any?(kept, &(&1["text"] =~ "mypy"))

    assert {^kept, []} = Bundle.drop_missing_tool_pitfalls(kept, missing)
    assert {all, []} = Bundle.drop_missing_tool_pitfalls(checked.pitfalls, [])
    assert length(all) == length(checked.pitfalls)
  end

  test "quiet_flags rewrites may only add output flags" do
    assert Bundle.quiet_flags?(~w(uv run pytest), ~w(uv run pytest -q))
    assert Bundle.quiet_flags?(~w(uv run pytest), ~w(uv run pytest -q --no-header --tb=short))
    assert Bundle.quiet_flags?(~w(npx mocha), ~w(npx mocha --reporter dot))
    assert Bundle.quiet_flags?(~w(npm run), ~w(npm run -s))
    assert Bundle.quiet_flags?(~w(npm test), ~w(npm test -- --reporter dot))

    # -p no:cacheprovider also removes --lf, --ff, --sw and --cache-clear (review R3).
    refute Bundle.quiet_flags?(~w(uv run pytest), ~w(uv run pytest -q -p no:cacheprovider))
    refute Bundle.quiet_flags?(~w(uv run pytest), ~w(uv run pytest -s))
    refute Bundle.quiet_flags?(~w(uv run pytest), ~w(uv run pytest -x))
    refute Bundle.quiet_flags?(~w(npx mocha), ~w(npx mocha --reporter spec))
    refute Bundle.quiet_flags?(~w(uv run pytest), ~w(uv run pytest))
    refute Bundle.quiet_flags?(~w(uv run pytest), ~w(uv run python -m pytest -q))
  end

  test "sample test files include test trees without test_ or .spec names" do
    extract = %{
      doc: %{"facts" => %{"analyzer" => %{}}},
      files: MapSet.new(~w(lib/app.js test/support/env.js test/fixtures/x.js test/res.send.js))
    }

    assert Bundle.samples(extract) == %{test: "test/res.send.js", source: "lib/app.js"}
  end

  test "unsafe argv in commands and rewrites is dropped before verification",
       %{repo: repo, side: side, extract: extract} do
    {:ok, checked} = check(LearningCase.raw(repo, side), extract)

    assert Enum.map(checked.commands, & &1.argv) == [
             ["uv", "run", "pytest", "-q", "{file}"],
             ["uv", "run", "pyright", "{file}"]
           ]

    command_reasons = reasons(checked, "command")
    assert command_reasons["cmd-test-l2"] == "unsafe_argv"
    assert command_reasons["cmd-lint-l3"] == "unsafe_argv"

    assert reasons(checked, "rewrite") == %{"rw-l3" => "unsafe_argv"}
    assert length(checked.rewrites) == 2

    refute Bundle.safe_argv?(["bash", "-c", "true"])
    refute Bundle.safe_argv?(["python", "-c", "print(1)"])
    refute Bundle.safe_argv?(["uv", "run", "pytest;rm"])
    refute Bundle.safe_argv?(["git", "status"])
    assert Bundle.safe_argv?(["uv", "run", "pytest", "-q"])
  end

  test "oversize, non-JSON and wrong-shape learner output is invalid_output", %{extract: extract} do
    assert {:error, "invalid_output"} =
             Bundle.check_raw(String.duplicate(" ", 300 * 1024), extract)

    assert {:error, "invalid_output"} = Bundle.check_raw("not json", extract)
    assert {:error, "invalid_output"} = Bundle.check_raw("[]", extract)
    assert {:error, "invalid_output"} = Bundle.check_raw(~s({"concepts": {}}), extract)
    assert {:ok, %{concepts: []}} = Bundle.check_raw(~s({"concepts": []}), extract)
  end

  test "items over the limit are dropped as over_limit", %{
    repo: repo,
    side: side,
    extract: extract
  } do
    [good | _] = LearningCase.raw(repo, side)["concepts"]
    many = for _ <- 1..101, do: good
    {:ok, checked} = check(%{"concepts" => many}, extract)
    assert length(checked.concepts) == 1
    reasons = reasons(checked, "concept")
    assert reasons["c101"] == "over_limit"
    assert Enum.count(reasons, fn {_, r} -> r == "duplicate" end) == 99
  end

  describe "skills and agents (learner prompt v2)" do
    test "a skill needs a kept concept, paths at the base and evidence that touches them",
         %{repo: repo, side: side, extract: extract} do
      assert {:ok, checked} = check(LearningCase.native_raw(repo, side), extract)

      assert [skill] = checked.skills
      assert skill["slug"] == "parser"
      assert skill["paths"] == ["src/acme_widgets/parser.py", "src/acme_widgets/client.py"]
      assert skill["tests"] == ["tests/test_parser.py"]
      # Neither name is a definition the extract lists in those paths.
      assert skill["symbols"] == []
      assert checked.report["skill_symbols_removed"] == 2
      assert skill.concept_ref == 0
      assert skill.pitfall_refs == ["p02"]
      assert checked.report["raw_counts"]["skills"] == 7

      assert reasons(checked, "skill") == %{
               "s02" => "path_missing_at_base",
               "s03" => "evidence_after_base",
               "s04" => "evidence_missing",
               "s05" => "evidence_mismatch",
               "s06" => "schema_invalid",
               "s07" => "over_limit"
             }
    end

    test "skill symbols are kept only when the extract lists them in the skill's paths",
         %{repo: repo, side: side, extract: extract} do
      symbols = [
        %{
          "name" => "parse_widget",
          "path" => "src/acme_widgets/parser.py",
          "start" => 1,
          "end" => 2
        },
        %{"name" => "Cache", "path" => "src/acme_widgets/cache.py", "start" => 1, "end" => 2}
      ]

      extract = put_in(extract, [:doc, "facts", "symbols"], symbols)
      raw = LearningCase.native_raw(repo, side)
      [first | _] = raw["skills"]
      first = Map.put(first, "symbols", ["parse_widget", "Cache", "NoSuchSymbol"])

      {:ok, checked} = check(%{slim(raw) | "skills" => [first]}, extract)
      assert [%{"symbols" => ["parse_widget"]}] = checked.skills
      assert checked.report["skill_symbols_removed"] == 2
    end

    test "malformed skills are schema_invalid and a repeated slug or path set is a duplicate",
         %{repo: repo, side: side, extract: extract} do
      raw = LearningCase.native_raw(repo, side)
      [good | _] = raw["skills"]

      bad = [
        Map.put(good, "kind", "pitfalls"),
        Map.put(good, "slug", "Bad Slug"),
        Map.put(good, "slug", String.duplicate("a", 25)),
        Map.put(good, "paths", ["src/acme_widgets/parser.py"]),
        Map.put(good, "paths", ["../outside.py", "src/acme_widgets/parser.py"]),
        Map.put(good, "pitfalls", ["p9"]),
        Map.put(good, "concept", nil),
        Map.put(good, "description", "free text is not a field") |> Map.delete("evidence"),
        "not a map"
      ]

      for item <- bad do
        {:ok, checked} = check(%{slim(raw) | "skills" => [item], "agents" => []}, extract)
        assert checked.skills == [], inspect(item)
        assert reasons(checked, "skill") == %{"s01" => "schema_invalid"}, inspect(item)
      end

      again = Map.put(good, "paths", Enum.reverse(good["paths"])) |> Map.put("slug", "other")
      {:ok, checked} = check(%{slim(raw) | "skills" => [good, again], "agents" => []}, extract)
      assert length(checked.skills) == 1
      assert reasons(checked, "skill") == %{"s02" => "duplicate"}
    end

    test "agents: paths at the base, evidence, a locator runs nothing, command ids well formed",
         %{repo: repo, side: side, extract: extract} do
      raw = LearningCase.native_raw(repo, side)
      {:ok, checked} = check(raw, extract)

      # Command ids are resolved only after verification.
      assert Enum.map(checked.agents, &{&1["kind"], &1["commands"]}) == [
               {"test_runner", ["cmd-test", "cmd-test-file"]},
               {"test_runner", ["cmd-typecheck"]},
               {"locator", []},
               {"locator", []}
             ]

      [runner, _, locator, _] = raw["agents"]

      bad = [
        Map.put(locator, "commands", ["cmd-test"]),
        Map.put(runner, "commands", []),
        Map.put(runner, "commands", ["sh -c pytest"]),
        Map.put(runner, "commands", ~w(cmd-a cmd-b cmd-c cmd-d cmd-e)),
        Map.put(runner, "kind", "general-purpose"),
        Map.put(runner, "paths", []),
        Map.put(runner, "evidence", [hd(runner["evidence"])])
      ]

      for item <- bad do
        {:ok, checked} = check(%{slim(raw) | "skills" => [], "agents" => [item]}, extract)
        assert reasons(checked, "agent") == %{"a01" => "schema_invalid"}, inspect(item)
      end

      {:ok, checked} =
        check(
          %{
            slim(raw)
            | "skills" => [],
              "agents" => [Map.put(locator, "paths", ["src/acme_widgets/gone.py"])]
          },
          extract
        )

      assert reasons(checked, "agent") == %{"a01" => "path_missing_at_base"}

      {:ok, checked} =
        check(
          %{
            slim(raw)
            | "skills" => [],
              "agents" => [locator, locator, locator, locator, locator]
          },
          extract
        )

      assert reasons(checked, "agent") == %{
               "a02" => "duplicate",
               "a03" => "duplicate",
               "a04" => "duplicate",
               "a05" => "over_limit"
             }
    end

    test "after verification an agent keeps only verified command ids and one per kind",
         %{repo: repo, side: side, extract: extract} do
      {:ok, checked} = check(LearningCase.native_raw(repo, side), extract)
      verified = [%{role: "test"}, %{role: "test_file"}, %{role: "lint"}]

      {kept, drops} = Bundle.resolve_agents(checked.agents, verified)
      assert Enum.map(kept, & &1["kind"]) == ["test_runner", "locator"]

      assert drops == [
               %{"kind" => "agent", "id" => "a02", "reason" => "not_verified"},
               %{"kind" => "agent", "id" => "a04", "reason" => "over_limit"}
             ]

      # A test runner may not run the linter even when it is verified.
      lint = Enum.map(checked.agents, &Map.put(&1, "commands", ["cmd-lint"]))
      {[], lint_drops} = Bundle.resolve_agents(Enum.take(lint, 1), verified)
      assert [%{"reason" => "schema_invalid"}] = lint_drops

      # Without verification nothing is verified.
      {kept, drops} = Bundle.resolve_agents(checked.agents, [])
      assert Enum.map(kept, & &1["kind"]) == ["locator"]
      assert Enum.count(drops, &(&1["reason"] == "not_verified")) == 2
    end

    test "a bundle written by learner prompt v1 (no skills, no agents) still validates" do
      {:ok, doc} = @shared_fixture |> File.read!() |> Contracts.decode_json()
      refute Map.has_key?(doc, "skills") or Map.has_key?(doc, "agents")
      assert doc["learner"]["prompt_id"] == "learner-prompt/v1"
      assert {:ok, ^doc} = Bundle.validate(doc)
    end

    test "the v2 prompt's JSON example parses and lists skills and agents" do
      prompt = HarnessForge.Learning.prompt()
      assert prompt =~ "learner prompt v2"
      [_, json] = Regex.run(~r/```json\n(.*?)\n```/s, prompt)
      example = Jason.decode!(json)
      assert [%{"kind" => "area"}] = example["skills"]
      assert Enum.map(example["agents"], & &1["kind"]) == ["test_runner", "locator"]
    end
  end

  test "pitfall text and pattern rules" do
    assert Bundle.safe_text?("Every fix adds a line to CHANGES.md describing the change.")
    refute Bundle.safe_text?("short")
    refute Bundle.safe_text?("See https://example.invalid for the full rules here.")
    refute Bundle.safe_text?("Ask @someone before you merge anything into this repository.")
    refute Bundle.safe_text?("Run !`date` before you merge anything into this repository.")
    refute Bundle.safe_text?("Line one of the rule\nline two of the rule here.")
    assert Bundle.safe_pattern?("- change [0-9]+")
    assert Bundle.safe_pattern?("\\{(issue|pr)\\}")
    refute Bundle.safe_pattern?("(a+)+")
    refute Bundle.safe_pattern?("(?=x)y")
    refute Bundle.safe_pattern?("(a)\\1")
    refute Bundle.safe_pattern?(String.duplicate("a", 81))
  end

  test "the schema is closed and the shared synthetic fixture passes when present" do
    schema = Bundle.schema()
    assert schema["additionalProperties"] == false

    if File.exists?(@shared_fixture) do
      {:ok, doc} = @shared_fixture |> File.read!() |> Contracts.decode_json()
      assert {:ok, ^doc} = Bundle.validate(doc)
      assert {:error, %{code: "learned_invalid"}} = Bundle.validate(Map.put(doc, "extra", 1))
    end
  end
end
