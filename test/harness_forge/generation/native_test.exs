defmodule HarnessForge.Generation.NativeTest do
  @moduledoc """
  The deterministic layer of history-derived Claude Code skills and subagents
  (`HarnessForge.Generation.Native`), and what `Spec` makes of it: gates, templates,
  caps, the learned merge, candidate checks, the context profile and the cost.
  All inputs are synthetic.
  """
  use ExUnit.Case, async: true

  alias HarnessForge.Generation
  alias HarnessForge.Generation.{Blueprint, Native, Profile, Spec}
  alias HarnessForge.Contracts.Error

  @marker "ZZSUBJECTMARK"
  @h11 "src/acme_widgets/http/h11.py"
  @tools "src/acme_widgets/http/tools.py"

  defp fixture do
    {:ok, profile} =
      Path.expand("../../../examples/profiles/python_package_native.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()
      |> Profile.validate()

    profile
  end

  defp blueprint(profile \\ fixture()), do: Blueprint.select(profile)

  defp build(profile, opts \\ %{}),
    do: Native.build(profile, blueprint(profile), Map.merge(%{"select" => "all"}, opts))

  defp names(native), do: Enum.map(native["items"], & &1["name"])

  defp reasons(native),
    do: Map.new(native["dropped"], &{&1["name"] || &1["template"], &1["reason"]})

  defp sha(n), do: n |> Integer.to_string() |> String.pad_leading(40, "a")

  defp put_evidence(profile, path, value), do: put_in(profile, ["native_evidence" | path], value)

  defp spec!(profile, opts) do
    assert {:ok, %{"spec" => spec} = built} =
             Spec.build(profile, Blueprint.select(profile), "solo", opts)

    {spec["spec"], built}
  end

  describe "the native fixture" do
    test "gives 2 area skills, the locator and the test runner" do
      native = build(fixture())

      assert names(native) == ~w(olivium-area-acme-widgets-http olivium-area-acme-widgets
               olivium-locator olivium-test-runner)

      assert native["dropped"] == []
      assert native["test_runner_commands"] == ["uv run pytest"]
      assert Enum.map(native["agents"], & &1["tools"]) == [~w(Read Grep Glob), ~w(Bash Read)]
      assert native["listing_bytes"] == Native.listing_bytes(native["skills"], native["agents"])

      [area | _] = native["skills"]

      assert area["description"] ==
               "Before changing #{@h11}, #{@tools}: files that change together, their tests and past fixes."

      assert area["instructions"] =~ "These files changed together in 8 commits (history up to "

      assert area["instructions"] =~
               "- `tests/test_http.py` (6 joint changes); run: `uv run pytest tests/test_http.py`"

      assert area["instructions"] =~
               "Reverted or fixed again before: `#{@h11}` (reverts: 1, follow-up fixes within 7 days: 2)"

      assert String.ends_with?(
               area["instructions"],
               "When you change one of them, check the others and run the paired tests."
             )
    end

    test "is deterministic and copies no repository prose" do
      profile =
        fixture()
        |> Map.update!("conventions", &["#{@marker} convention" | &1])
        |> Map.update!("rule_candidates", fn rules ->
          [
            %{
              "text" => "#{@marker} rule",
              "confidence" => 90,
              "bucket" => "auto",
              "citations" => [
                %{
                  "detector" => "x",
                  "signal" => "history.commit_style",
                  "path" => nil,
                  "line" => nil
                }
              ]
            }
            | rules
          ]
        end)

      first = build(profile)
      assert first == build(profile)
      assert Jason.encode!(first) == Jason.encode!(build(profile))
      refute Jason.encode!(first) =~ @marker
    end
  end

  describe "gates (each at and just below its threshold)" do
    test "area: support 4 is kept, 3 is dropped" do
      at = fixture() |> put_evidence(["clusters"], [cluster(4)])
      below = fixture() |> put_evidence(["clusters"], [cluster(3)])

      assert "olivium-area-acme-widgets-http" in names(build(at))
      refute Enum.any?(names(build(below)), &String.starts_with?(&1, "olivium-area-"))
      assert reasons(build(below))["olivium-area-acme-widgets-http"] == "gate_failed"
    end

    test "locator: 40 source files and a cluster strong enough for a skill; layout alone is not" do
      assert "olivium-locator" in names(build(put_evidence(fixture(), ["source_files"], 40)))

      below = build(put_evidence(fixture(), ["source_files"], 39))
      refute "olivium-locator" in names(below)
      assert reasons(below)["olivium-locator"] == "gate_failed"

      # Layout rows alone do not pay for Task (and the built-in subagents it lists).
      no_clusters = put_evidence(fixture(), ["clusters"], [])
      assert reasons(build(no_clusters))["olivium-locator"] == "gate_failed"

      weak = put_evidence(fixture(), ["clusters"], [cluster(3)])
      assert reasons(build(weak))["olivium-locator"] == "gate_failed"

      assert "olivium-locator" in names(
               build(put_evidence(fixture(), ["clusters"], [cluster(4)]))
             )

      no_history = Map.delete(fixture(), "native_evidence")
      assert reasons(build(no_history))["olivium-locator"] == "history_unavailable"
      assert reasons(build(no_history))["area"] == "history_unavailable"
    end

    test "test runner: 3 test pairs and a test command; 2 pairs or no command are not enough" do
      three = Map.update!(fixture(), "test_pairs", &Enum.take(&1, 3))
      two = Map.update!(fixture(), "test_pairs", &Enum.take(&1, 2))
      no_command = put_in(fixture(), ["commands", "test"], nil)

      assert "olivium-test-runner" in names(build(three))
      assert reasons(build(two))["olivium-test-runner"] == "gate_failed"
      assert reasons(build(no_command))["olivium-test-runner"] == "gate_failed"
      assert build(two)["test_runner_commands"] == []
    end

    test "a package script is no runner command: it cannot run one test file" do
      profile =
        fixture()
        |> put_in(["commands", "test"], "npm run test-browser")
        |> put_in(["commands", "test_single"], nil)

      native = build(profile)
      assert reasons(native)["olivium-test-runner"] == "runner_command_unsuitable"
      assert native["test_runner_commands"] == []

      # The suite is offered only when it is the test tool itself; the file form of a
      # direct `test_single` is enough for the runner.
      mixed =
        fixture()
        |> put_in(["commands", "test"], "npm run test-browser")
        |> put_in(["commands", "test_single"], "npx vitest run")

      assert build(mixed)["test_runner_commands"] == ["npx vitest run"]
    end

    test "a package script the analyzer found to be one plain test-tool call runs one file" do
      # `commands.test_single` is then the script's file form (`npm run <script> --`), and
      # the runner, the area skills and CLAUDE.md all use the same script.
      profile =
        fixture()
        |> put_in(["commands", "test"], "npm run test:unit")
        |> put_in(["commands", "test_single"], "npm run test:unit --")

      native = build(profile)
      assert native["test_runner_commands"] == ["npm run test:unit", "npm run test:unit --"]
      runner = Enum.find(native["agents"], &(&1["name"] == "olivium-test-runner"))
      assert runner["instructions"] =~ "- `npm run test:unit` (whole suite)"
      assert runner["instructions"] =~ "- `npm run test:unit -- <file>` (one file)"

      [skill | _] = native["skills"]
      assert skill["instructions"] =~ "run: `npm run test:unit -- tests/"

      pnpm =
        fixture()
        |> put_in(["commands", "test"], "pnpm test")
        |> put_in(["commands", "test_single"], "pnpm run test:unit")

      assert build(pnpm)["test_runner_commands"] == ["pnpm test", "pnpm run test:unit"]

      # A test_single that is not a package file form leaves the script alone.
      other =
        fixture()
        |> put_in(["commands", "test"], "npm run test:unit")
        |> put_in(["commands", "test_single"], "npm run test:browser")

      assert reasons(build(other))["olivium-test-runner"] == "runner_command_unsuitable"
    end

    test "a denied test command never reaches the runner" do
      profile = put_in(fixture(), ["commands"], %{fixture()["commands"] | "test" => "curl x"})
      assert reasons(build(profile))["olivium-test-runner"] == "gate_failed"
    end
  end

  defp cluster(support, files \\ [@h11, @tools]) do
    %{
      "files" => files,
      "support" => support,
      "commits" => [sha(1)],
      "fix_commits" => [],
      "tests" => [],
      "risk" => []
    }
  end

  describe "templates and caps" do
    test "slug: last two telling segments of the common directory, else the first two stems" do
      assert Native.slug([@h11, @tools]) == "acme-widgets-http"
      assert Native.slug(["a.py", "b/c.py"]) == "a-c"
      assert Native.slug(["src/Foo Bar/x.py", "src/Foo Bar/y.py"]) == "foo-bar"
      # `lib` and `src` say nothing; every extension goes (`index.d.ts` is `index`).
      assert Native.slug(["lib/runner.js", "lib/runnable.js"]) == "runner-runnable"
      assert Native.slug(["index.d.ts", "index.js"]) == "index"

      assert byte_size(
               Native.slug([
                 "a/#{String.duplicate("x", 40)}/f.py",
                 "a/#{String.duplicate("x", 40)}/g.py"
               ])
             ) <= 24

      assert Native.slug(["src/__/x.py", "src/__/y.py"]) == "area"
      assert Native.slug(["__.py", "z/y.py"]) == "y"
      assert Native.slug(["__.py", "z/__.py"]) == "area"
    end

    test "past fixes say what they changed; no fixes, no promise of them" do
      fixed = %{
        cluster(9)
        | "fix_commits" => [sha(7)],
          "tests" => [%{"path" => "tests/test_http.py", "support" => 5}]
      }

      with_files =
        Map.put(fixed, "fixes", [%{"sha" => sha(7), "files" => [@h11, "tests/test_http.py"]}])

      [skill | _] = build(put_evidence(fixture(), ["clusters"], [with_files]))["skills"]

      assert skill["instructions"] =~
               "Past fixes touching them (commit: what it changed; `git show <commit>` for the diff):\n" <>
                 "- aaaaaaaaaa: `#{@h11}`, `tests/test_http.py`"

      assert skill["description"] =~ "their tests and past fixes."

      # Without a fix or a test, the description promises neither.
      [plain | _] = build(put_evidence(fixture(), ["clusters"], [cluster(9)]))["skills"]
      assert plain["description"] =~ "files that change together."
      refute plain["description"] =~ "tests"
      refute plain["instructions"] =~ "Past fixes"
      refute plain["instructions"] =~ "Tests"
      assert plain["instructions"] =~ ~r/check the others\.\z/

      tested = %{cluster(9) | "tests" => [%{"path" => "tests/test_http.py", "support" => 5}]}
      [with_tests | _] = build(put_evidence(fixture(), ["clusters"], [tested]))["skills"]
      assert with_tests["description"] =~ "files that change together and their tests."
      assert with_tests["instructions"] =~ "check the others and run the paired tests."

      fixes_only = %{cluster(9) | "fix_commits" => [sha(7)]}
      [only | _] = build(put_evidence(fixture(), ["clusters"], [fixes_only]))["skills"]
      assert only["description"] =~ "files that change together and their past fixes."
    end

    test "history-paired and linked tests go under their own headings; a cut list loses its heading" do
      mixed = %{
        cluster(9)
        | "tests" => [
            %{"path" => "tests/test_http.py", "support" => 5},
            %{"path" => "tests/test_tools.py", "support" => 0}
          ]
      }

      [skill | _] = build(put_evidence(fixture(), ["clusters"], [mixed]))["skills"]
      body = skill["instructions"]

      assert body =~
               "Tests that history pairs with them:\n- `tests/test_http.py` (5 joint changes)"

      assert body =~ "Tests linked to them:\n- `tests/test_tools.py`; run:"
      refute body =~ "(0 joint changes)"
      assert body =~ "run the paired tests."

      linked_only = %{
        cluster(9)
        | "tests" => [%{"path" => "tests/test_tools.py", "support" => 0}]
      }

      [linked | _] = build(put_evidence(fixture(), ["clusters"], [linked_only]))["skills"]
      refute linked["instructions"] =~ "history pairs"
      assert linked["instructions"] =~ "run the linked tests."

      # Rows cut to fit the body take their heading with them, and the description and the
      # closing line follow what is left.
      long = String.duplicate("x", 200)

      crowded =
        cluster(9)
        |> Map.merge(%{
          "tests" => [%{"path" => "tests/#{long}.py", "support" => 5}],
          "fix_commits" => Enum.map(1..5, &sha/1),
          "fixes" =>
            Enum.map(1..5, &%{"sha" => sha(&1), "files" => [@h11, "tests/#{long}#{&1}.py"]})
        })

      native = build(put_evidence(fixture(), ["clusters"], [crowded]))
      [cut | _] = native["skills"]
      assert byte_size(cut["instructions"]) <= 2048

      for {heading, row} <- [
            {"Tests that history pairs with them:", "joint changes"},
            {"Past fixes touching them (commit", "- aaaa"}
          ] do
        assert String.contains?(cut["instructions"], heading) ==
                 String.contains?(cut["instructions"], row)
      end

      assert String.contains?(cut["description"], "tests") ==
               String.contains?(cut["instructions"], "joint changes")
    end

    test "a repository rule that names an area file goes into that skill" do
      rule = fn text, signal ->
        %{
          "text" => text,
          "confidence" => 90,
          "bucket" => "auto",
          "citations" => [
            %{"detector" => "x", "signal" => signal, "path" => "AGENTS.md", "line" => 3}
          ]
        }
      end

      profile =
        fixture()
        |> put_evidence(["clusters"], [cluster(9)])
        |> Map.put("rule_candidates", [
          rule.("Keep `h11.py` free of I/O; parsing only.", "instructions.rule_candidates"),
          rule.("Never call tools.py from tests directly.", "history.commit_style"),
          rule.("Use the shared logger everywhere.", "instructions.rule_candidates")
        ])

      [skill | _] = build(profile)["skills"]
      assert skill["instructions"] =~ "Project rule: Keep `h11.py` free of I/O; parsing only."
      refute skill["instructions"] =~ "Never call tools.py"
      refute skill["instructions"] =~ "shared logger"
    end

    test "duplicate slugs get -2" do
      profile =
        put_evidence(fixture(), ["clusters"], [
          cluster(9, ["src/a/x/one.py", "src/a/x/two.py"]),
          cluster(8, ["src/b/a/x/three.py", "src/b/a/x/four.py"])
        ])

      assert Enum.take(names(build(profile)), 2) == ~w(olivium-area-a-x olivium-area-a-x-2)
    end

    test "descriptions stay within 200 bytes and say how many files they leave out" do
      long = for n <- 1..6, do: "src/#{String.duplicate("deep", 12)}/module_#{n}.py"
      tested = %{cluster(9, long) | "tests" => [%{"path" => "tests/test_a.py", "support" => 4}]}
      native = build(put_evidence(fixture(), ["clusters"], [tested]))
      [skill | _] = native["skills"]

      assert byte_size(skill["description"]) <= 200
      assert skill["description"] =~ "(+5 more)"
    end

    test "bodies stay within 2,048 bytes by cutting list rows from the end, never a fixed line" do
      long = fn prefix, n -> "src/#{String.duplicate(prefix, 45)}/f#{n}.py" end
      files = for n <- 1..6, do: long.("a", n)

      big = %{
        cluster(9, files)
        | "tests" =>
            for(
              n <- 1..4,
              do: %{"path" => "tests/#{String.duplicate("t", 150)}#{n}.py", "support" => 9}
            ),
          "risk" =>
            for(n <- 1..4, do: %{"path" => long.("a", n), "reverts" => 1, "followups" => 2})
      }

      [skill | _] = build(put_evidence(fixture(), ["clusters"], [big]))["skills"]

      assert byte_size(skill["instructions"]) <= 2048
      assert skill["instructions"] =~ "When you change one of them"
      assert skill["instructions"] =~ "# Area "
      assert length(Regex.scan(~r/^- `src\//m, skill["instructions"])) >= 2
    end

    test "the listing cap drops the lowest-ranked skill first" do
      # 941 bytes in all; the second skill's line is 185.
      bp = blueprint() |> put_in(["native", "limits", "listing_bytes"], 800)
      native = Native.build(fixture(), bp, %{"select" => "all"})

      assert names(native) ==
               ~w(olivium-area-acme-widgets-http olivium-locator olivium-test-runner)

      assert reasons(native)["olivium-area-acme-widgets"] == "over_limit"
      assert native["listing_bytes"] == 756
    end

    test "at most 3 skills" do
      clusters = for n <- 1..5, do: cluster(10 - n, ["src/m#{n}/a.py", "src/m#{n}/b.py"])
      native = build(put_evidence(fixture(), ["clusters"], clusters))

      assert Enum.count(native["skills"]) == 3
      assert reasons(native)["olivium-area-m4"] == "over_limit"
      assert reasons(native)["olivium-area-m5"] == "over_limit"
    end

    test "select keeps one kind or none, and says what it removed" do
      skills = build(fixture(), %{"select" => "skills"})
      assert Enum.all?(skills["items"], &(&1["kind"] == "skill"))
      assert reasons(skills)["olivium-locator"] == "not_selected"
      assert skills["test_runner_commands"] == []

      agents = build(fixture(), %{"select" => "agents"})
      assert names(agents) == ~w(olivium-locator olivium-test-runner)
      assert reasons(agents)["olivium-area-acme-widgets-http"] == "not_selected"

      none = build(fixture(), %{"select" => "none"})
      assert none["items"] == [] and none["skills"] == [] and none["agents"] == []
      assert none["listing_bytes"] == 0
      assert length(none["dropped"]) == 4
    end

    test "a name the repository already uses is left to it" do
      profile =
        put_in(fixture(), ["existing_harness", "files"], [
          ".claude/skills/olivium-area-acme-widgets-http/SKILL.md",
          ".claude/agents/olivium-test-runner.md"
        ])

      native = build(profile)
      assert reasons(native)["olivium-area-acme-widgets-http"] == "name_taken"
      assert reasons(native)["olivium-test-runner"] == "name_taken"
      assert names(native) == ~w(olivium-area-acme-widgets olivium-locator)
    end
  end

  describe "learned candidates" do
    defp learned_area(files, extra \\ %{}) do
      Map.merge(
        %{
          "template" => "area",
          "origin" => "learned",
          "slug" => "http-protocol",
          "files" => files,
          "terms" => ["keep alive", "chunked"],
          "symbols" => [%{"name" => "H11Protocol", "path" => @h11, "start" => 10, "end" => 80}],
          "notes" => ["Close the connection after a protocol error in `h11.py`."],
          "evidence" => %{
            "signals" => ["learning.skill"],
            "commits" => [sha(7), sha(8)],
            "learned_id" => "s01"
          }
        },
        extra
      )
    end

    test "an overlapping learned area replaces the history one and keeps its commits and tests" do
      native =
        build(fixture(), %{
          "candidates" => [learned_area([@h11, "src/acme_widgets/http/conn.py"])]
        })

      assert ["olivium-area-http-protocol", "olivium-area-acme-widgets" | _] = names(native)
      [skill | _] = native["skills"]
      [item | _] = native["items"]

      assert item["origin"] == "learned"
      assert item["evidence"]["learned_id"] == "s01"
      assert item["evidence"]["files"] == [@h11, "src/acme_widgets/http/conn.py", @tools]
      assert sha(7) in item["evidence"]["commits"]

      assert hd(fixture()["native_evidence"]["clusters"])["commits"] --
               item["evidence"]["commits"] == []

      assert skill["instructions"] =~ "These files changed together in 8 commits"

      assert skill["instructions"] =~
               "Terms: keep alive, chunked. Symbols: `H11Protocol` in `#{@h11}`:10-80"

      assert skill["instructions"] =~
               "Note: Close the connection after a protocol error in `h11.py`."

      assert skill["instructions"] =~ "`tests/test_http.py` (6 joint changes)"
    end

    test "a learned area with no overlap is added, ranked first" do
      native =
        build(fixture(), %{
          "candidates" => [learned_area(["src/acme_widgets/cli.py", "src/acme_widgets/main.py"])]
        })

      assert Enum.take(names(native), 3) ==
               ~w(olivium-area-http-protocol olivium-area-acme-widgets-http olivium-area-acme-widgets)

      assert hd(native["skills"])["instructions"] =~
               "These files change together (2 evidence commits):"
    end

    test "a learned locator adds scope; it never opens a closed gate" do
      locator = %{
        "template" => "locator",
        "origin" => "learned",
        "scope" => ["src/acme_widgets/cli.py"],
        "evidence" => %{
          "signals" => ["learning.agent"],
          "commits" => [sha(3)],
          "learned_id" => "a01"
        }
      }

      native = build(fixture(), %{"candidates" => [locator]})
      agent = Enum.find(native["agents"], &(&1["name"] == "olivium-locator"))
      assert agent["instructions"] =~ "Also look at: `src/acme_widgets/cli.py`"
      assert Enum.find(native["items"], &(&1["name"] == "olivium-locator"))["origin"] == "learned"

      closed = build(put_evidence(fixture(), ["source_files"], 10), %{"candidates" => [locator]})
      refute "olivium-locator" in names(closed)

      # The history and the learned locator fail the same gate: one row, not two.
      assert Enum.filter(closed["dropped"], &(&1["template"] == "locator")) == [
               %{"name" => "olivium-locator", "template" => "locator", "reason" => "gate_failed"}
             ]
    end

    test "a learned test runner adds verified commands and may open the gate" do
      runner = %{
        "template" => "test_runner",
        "origin" => "learned",
        "commands" => [
          %{
            "role" => "test_file",
            "argv" => "uv run --no-sync pytest -q {file}",
            "id" => "cmd-test-file"
          }
        ],
        "evidence" => %{"signals" => ["learning.agent"], "commits" => [], "learned_id" => "a02"}
      }

      native = build(fixture(), %{"candidates" => [runner]})
      assert native["test_runner_commands"] == ["uv run pytest", "uv run --no-sync pytest -q"]

      few_pairs = Map.update!(fixture(), "test_pairs", &Enum.take(&1, 1))
      opened = build(few_pairs, %{"candidates" => [runner]})
      assert "olivium-test-runner" in names(opened)
    end

    test "invalid candidates are refused with a reason, never repaired" do
      ok = learned_area([@h11, @tools])
      assert {:ok, _} = Native.validate_candidate(ok)

      for {candidate, reason} <- [
            {%{ok | "files" => ["../etc/passwd", @tools]}, "schema_invalid"},
            {%{ok | "files" => for(n <- 1..7, do: "src/f#{n}.py")}, "schema_invalid"},
            {%{ok | "notes" => ["Mention @README.md for the details of this."]}, "text_unsafe"},
            {%{ok | "notes" => ["Run !`rm -rf .` before every single change."]}, "text_unsafe"},
            {put_in(ok, ["evidence", "commits"], ["XYZ"]), "schema_invalid"},
            {%{ok | "slug" => "Bad Slug"}, "schema_invalid"},
            {%{ok | "template" => "shell"}, "schema_invalid"},
            {Map.put(ok, "origin", "history"), "schema_invalid"},
            {"not a map", "schema_invalid"}
          ] do
        assert {:error, ^reason} = Native.validate_candidate(candidate), inspect(candidate)
      end

      native = build(fixture(), %{"candidates" => [%{ok | "notes" => ["@x"]}]})
      assert %{"template" => "area", "reason" => "text_unsafe"} in native["dropped"]
    end
  end

  describe "the spec: context profile and cost" do
    test "lean keeps Skill and Task for the generated items, denies Workflow, and prices them" do
      {spec, built} = spec!(fixture(), %{})
      context = spec["context"]
      listing = spec["native"]["listing_bytes"]
      listing_tokens = div(listing * 1000 + 2459, 2460)

      assert context["kept_tools"] == ["Skill", "Task"]
      assert "Workflow" in context["deny_tools"]
      refute "Skill" in context["deny_tools"] or "Task" in context["deny_tools"]
      assert length(context["deny_tools"]) == 13
      assert context["disable_bundled_skills"] == true
      # Task is kept, so the built-in subagents are denied by name: their measured listing
      # (971 B, 395 tokens at 2.46 B/token, 278 at 3.5) comes off the cost.
      assert context["disable_builtin_agents"] == true
      assert context["est_tokens_saved_per_request"] == 8776 + 395 - listing_tokens

      assert spec["native"]["cost"]["config"] == "skills_agents"
      assert spec["native"]["cost"]["builtin_agents_denied_tokens"] == 395
      assert spec["native"]["cost"]["fixed_tokens"] == 3326 - 395
      assert spec["native"]["cost"]["listing_tokens"] == listing_tokens
      assert spec["native"]["cost"]["est_tokens_per_request"] == 3326 - 395 + listing_tokens

      assert spec["native"]["cost"]["est_tokens_per_request_low"] ==
               2575 - 278 + div(listing * 1000 + 3499, 3500)

      assert Enum.any?(spec["policies"], &(&1["id"] == "allow-skill"))
      assert length(spec["skills"]) == 2 and length(spec["agents"]) == 2
      assert built["native"]["items"] == spec["native"]["items"]
    end

    test "native none, skills and agents" do
      {none, _} = spec!(fixture(), %{"native" => "none"})
      assert length(none["context"]["deny_tools"]) == 15
      assert none["context"]["est_tokens_saved_per_request"] == 11_700
      refute Map.has_key?(none["context"], "kept_tools")
      refute Map.has_key?(none, "native")
      refute Enum.any?(none["policies"], &(&1["id"] == "allow-skill"))

      {skills, _} = spec!(fixture(), %{"native" => "skills"})
      assert skills["context"]["kept_tools"] == ["Skill"]
      assert "Task" in skills["context"]["deny_tools"]
      assert skills["context"]["disable_bundled_skills"] == true
      assert skills["context"]["disable_builtin_agents"] == false

      assert skills["context"]["est_tokens_saved_per_request"] ==
               11_252 - div(skills["native"]["listing_bytes"] * 1000 + 2459, 2460)

      assert skills["native"]["cost"]["fixed_tokens"] == 850
      assert skills["native"]["cost"]["builtin_agents_denied_tokens"] == 0

      {agents, _} = spec!(fixture(), %{"native" => "agents"})
      assert agents["context"]["kept_tools"] == ["Task"]

      assert "Skill" in agents["context"]["deny_tools"] and
               "Workflow" in agents["context"]["deny_tools"]

      assert agents["context"]["disable_bundled_skills"] == false
      assert agents["context"]["disable_builtin_agents"] == true
      assert agents["native"]["cost"]["fixed_tokens"] == 2477 - 395
    end

    test "standard keeps every tool and sets no switch; lean-x has none by default" do
      {standard, _} = spec!(fixture(), %{"context" => "standard"})
      assert standard["context"]["deny_tools"] == []
      assert standard["context"]["kept_tools"] == []
      assert standard["context"]["disable_bundled_skills"] == false
      assert standard["context"]["disable_builtin_agents"] == false
      assert standard["context"]["est_tokens_saved_per_request"] == 0
      assert standard["native"]["cost"]["fixed_tokens"] == 0

      assert standard["native"]["cost"]["est_tokens_per_request"] ==
               standard["native"]["cost"]["listing_tokens"]

      {lean_x, _} = spec!(fixture(), %{"context" => "lean-x"})
      refute Map.has_key?(lean_x, "native")
      assert length(lean_x["context"]["deny_tools"]) == 15

      {lean_x_all, _} = spec!(fixture(), %{"context" => "lean-x", "native" => "all"})
      {lean, _} = spec!(fixture(), %{})

      assert Map.delete(lean_x_all["context"], "profile") ==
               Map.delete(lean["context"], "profile")
    end

    test "the repository's own skills keep Skill and Workflow; bundled skills stay" do
      profile =
        put_in(fixture(), ["existing_harness", "files"], [".claude/skills/release/SKILL.md"])

      {spec, _} = spec!(profile, %{})

      refute "Skill" in spec["context"]["deny_tools"] or
               "Workflow" in spec["context"]["deny_tools"]

      assert spec["context"]["kept_tools"] == ["Task"]
      assert spec["context"]["disable_bundled_skills"] == false
      assert spec["context"]["est_tokens_saved_per_request"] == 0
    end

    test "a native value outside the list is refused" do
      for value <- ["some", "", 1, nil] do
        assert {:error, %Error{code: "invalid_generation_request"}} =
                 Spec.build(fixture(), blueprint(), "solo", %{"native" => value})
      end
    end

    test "team mode generates no native item" do
      assert {:ok, %{"spec" => spec, "native" => native}} =
               Spec.build(fixture(), blueprint(), "team", %{})

      refute Map.has_key?(spec["spec"], "native")
      assert native["items"] == []
      assert Enum.map(spec["spec"]["agents"], & &1["name"]) == ["olivium-implementer"]
    end
  end

  describe "the generation summary" do
    test "carries the native contract the CLI and the portal read" do
      assert {:ok, summary} = Generation.plan(%{"profile" => fixture()})
      native = summary["native"]

      assert native["select"] == "all"
      assert native["measured_on"] == "claude-code 2.1.311"
      assert native["dropped"] == []
      assert length(native["items"]) == 4
      assert summary["counts"]["skills"] == 2 and summary["counts"]["agents"] == 2

      for item <- native["items"] do
        file = summary["artifact"]["files"][item["path"]]
        assert is_binary(file), item["path"]
        assert byte_size(item["description"]) == item["description_bytes"]
        assert length(item["evidence"]) <= 5
        assert Map.has_key?(item, "tools") == (item["kind"] == "agent")
      end

      assert native["est_tokens_per_request"] ==
               summary["artifact"]["spec"]["spec"]["native"]["cost"]["est_tokens_per_request"]

      assert summary["context"]["kept_tools"] == ["Skill", "Task"]

      {:ok, none} = Generation.plan(%{"profile" => fixture(), "native" => "none"})
      assert none["native"]["items"] == []
      assert none["context"]["est_tokens_saved_per_request"] == 11_700
      assert none["context"]["kept_tools"] == []
      assert none["context"]["disable_bundled_skills"] == false

      assert {:error, %Error{code: "invalid_generation_request"}} =
               Generation.plan(%{"profile" => fixture(), "native" => "most"})
    end

    test "a co-change rule a generated skill covers is reported as in_skill" do
      {:ok, summary} = Generation.plan(%{"profile" => fixture()})
      report = summary["guidance"]

      assert %{"reason" => "in_skill", "section" => "rules"} =
               Enum.find(report["withheld"], &(&1["text"] =~ "h11.py"))

      assert report["withheld_counts"]["in_skill"] == 1

      {:ok, none} = Generation.plan(%{"profile" => fixture(), "native" => "none"})

      assert Enum.find(none["guidance"]["withheld"], &(&1["text"] =~ "h11.py"))["reason"] ==
               "scoped"

      refute Map.has_key?(none["guidance"]["withheld_counts"], "in_skill")
    end

    test "old profiles without history evidence say why nothing was generated" do
      for name <- ~w(elixir_project node_package python_package minimal) do
        profile =
          Path.expand("../../../examples/profiles/#{name}.json", __DIR__)
          |> File.read!()
          |> Jason.decode!()

        assert {:ok, summary} = Generation.plan(%{"profile" => profile})
        assert summary["native"]["items"] == []
        assert summary["native"]["dropped"] != []
        assert Enum.any?(summary["diagnostics"], &(&1["code"] == "native_none_generated"))
        refute Map.has_key?(summary["artifact"]["files"], ".olivium/native-provenance.json")
      end
    end
  end
end
