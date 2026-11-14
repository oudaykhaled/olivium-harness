defmodule HarnessForge.Generation.GuidanceTest do
  use ExUnit.Case, async: true

  alias HarnessForge.Generation.{Blueprint, Economy, Guidance, Profile, Spec}

  @header "<!-- Olivium Harness. Lines left out of this file, and why: .olivium/guidance-provenance.json -->\n"
  @fixed "Lint and format run automatically when you finish. Do not install or download tools."

  defp candidate(text, signal \\ "instructions.rule", opts \\ []) do
    %{
      "text" => text,
      "confidence" => Keyword.get(opts, :confidence, 90),
      "bucket" => "auto",
      "citations" => [
        %{
          "detector" => "instructions",
          "signal" => signal,
          "path" => Keyword.get(opts, :path, "CONTRIBUTING.md"),
          "line" => 1
        }
      ]
    }
  end

  defp filler(index, confidence) do
    candidate(
      "Rule #{String.pad_leading(to_string(index), 3, "0")} " <> String.duplicate("x", 60),
      "instructions.rule",
      confidence: confidence
    )
  end

  defp commands(overrides), do: Map.merge(Profile.empty("x")["commands"], overrides)

  defp python(overrides) do
    "acme"
    |> Profile.empty()
    |> Map.merge(%{"languages" => ["python"], "package_managers" => ["uv"]})
    |> Map.merge(overrides)
  end

  defp oversized do
    python(%{
      "commands" => commands(%{"test" => "tox -e py312", "lint" => "ruff check ."}),
      "layout" =>
        for(i <- 1..40, do: %{"path" => "pkg/m#{i}", "purpose" => String.duplicate("p", 80)}),
      "conventions" => for(i <- 1..30, do: "Convention #{i} " <> String.duplicate("k", 90)),
      "rule_candidates" => for(i <- 1..60, do: filler(i, 100 - rem(i, 30)))
    })
  end

  defp spec(profile) do
    {:ok, profile} = Profile.validate(profile)
    Spec.build(profile, Blueprint.select(profile), "solo")["spec"]
  end

  defp render(profile), do: profile |> spec() |> Guidance.render()

  defp reason(report, text) do
    Enum.find_value(report["withheld"], &(&1["text"] == text && &1["reason"]))
  end

  test "the whole file stays within 600 bytes and every left-out line is reported with a reason" do
    harness = spec(oversized())
    {markdown, report} = Guidance.render(harness)

    assert Guidance.budget_bytes() == 600
    assert byte_size(markdown) <= 600
    assert report["budget_bytes"] == 600
    assert report["rendered_bytes"] == byte_size(markdown) - byte_size(@header)
    assert report["est_tokens_per_request"] == Economy.price(report["rendered_bytes"])
    assert report["kept_lines"] == length(Regex.scan(~r/^- /m, markdown))

    assert report["withheld_counts"] |> Map.keys() |> Enum.sort() == Economy.reasons()
    assert report["withheld_counts"]["over_budget"] > 0
    assert Enum.sum(Map.values(report["withheld_counts"])) == length(report["withheld"])

    for row <- report["withheld"] do
      assert row["reason"] in Economy.reasons()
      assert row["bytes"] == byte_size(row["text"])
      refute markdown =~ "- " <> row["text"] <> "\n"
    end

    assert report["withheld"] ==
             Enum.sort_by(report["withheld"], &{&1["section"], &1["reason"], &1["text"]})

    assert {^markdown, ^report} = Guidance.render(harness)
  end

  test "no title, headings, layout, process lines or provenance outside the comment" do
    {markdown, _report} = render(oversized())

    refute markdown =~ ~r/^#/m
    refute markdown =~ "Layout"
    refute markdown =~ ~r/^- (Lint|Format|Typecheck|Build|Install|Run):/m
    refute markdown =~ "pkg/m1"
    refute Regex.match?(~r/[0-9a-f]{32}/, markdown)

    model_visible = Regex.replace(~r/<!--.*?-->\n?/s, markdown, "")
    refute model_visible =~ "provenance"
    refute model_visible =~ "Olivium"
  end

  test "a non-default test command is kept first; the ecosystem default is withheld" do
    {markdown, _report} = render(oversized())
    assert markdown =~ "- Test: `tox -e py312`\n"

    for default <- ["pytest", "uv run pytest", "python -m pytest -q"] do
      {markdown, report} = render(python(%{"commands" => commands(%{"test" => default})}))
      refute markdown =~ "Test:"
      assert reason(report, "Test: `#{default}`") == "default_guessable"
    end
  end

  test "the four inclusion tests name the first test a withheld line fails" do
    profile =
      python(%{
        "commands" =>
          commands(%{
            "test" => "pytest",
            "lint" => "ruff check .",
            "format" => "ruff format",
            "typecheck" => "mypy src",
            "build" => "uv build",
            "install" => "uv sync"
          }),
        "layout" => [
          %{"path" => "src/acme", "purpose" => "package source"},
          %{"path" => "tests", "purpose" => "pytest suite"},
          %{"path" => "tools/gen", "purpose" => "code generators"}
        ],
        "conventions" => ["Tests live under tests/ as test_*.py files"],
        "rule_candidates" => [
          candidate("Run the type checker before finishing"),
          candidate("Open pull requests against the main branch"),
          candidate("Never push to a feature branch you do not own"),
          candidate("Avoid ternary expressions: coverage cannot measure both branches."),
          candidate("Check types with mypy before finishing"),
          candidate("Keep `docs/api.rst` in sync with the public API"),
          candidate("Public functions return frozen dataclasses, never dicts"),
          candidate("Add a regression test with every bug fix", "history.fix_tests"),
          candidate("Write a clear commit summary", "history.commit_style"),
          candidate("Make sure the issue is labeled with `status: accepting prs`"),
          candidate(
            "Add an entry to `CHANGES.rst` for every user-visible change.",
            "history.fix_changelog"
          )
        ]
      })

    {markdown, report} = render(profile)

    assert reason(report, "Test: `pytest`") == "default_guessable"
    assert reason(report, "`src/acme`: package source") == "default_guessable"
    assert reason(report, "`tests`: pytest suite") == "default_guessable"
    assert reason(report, "`tools/gen`: code generators") == "scoped"
    assert reason(report, "Tests live under tests/ as test_*.py files") == "default_guessable"
    assert reason(report, "Add a regression test with every bug fix") == "default_guessable"

    for line <- [
          "Lint: `ruff check .`",
          "Format: `ruff format`",
          "Typecheck: `mypy src`",
          "Build: `uv build`",
          "Install: `uv sync`",
          "Run the type checker before finishing",
          "Open pull requests against the main branch",
          "Never push to a feature branch you do not own",
          "Write a clear commit summary",
          "Make sure the issue is labeled with `status: accepting prs`"
        ],
        do: assert(reason(report, line) == "process_only", line)

    assert reason(report, "Check types with mypy before finishing") == "tool_unverified"
    assert reason(report, "Keep `docs/api.rst` in sync with the public API") == "scoped"

    assert markdown ==
             @header <>
               "- Add an entry to `CHANGES.rst` for every user-visible change.\n" <>
               "- Avoid ternary expressions: coverage cannot measure both branches.\n" <>
               "- Public functions return frozen dataclasses, never dicts\n" <>
               "- #{@fixed}\n"
  end

  test "the fixed stop-hook sentence is the last line, only when lint or format runs at stop" do
    with_hooks =
      python(%{
        "commands" =>
          commands(%{"test" => "pytest", "lint" => "ruff check .", "format" => "ruff format"}),
        "rule_candidates" => [
          candidate("Public functions return frozen dataclasses, never dicts")
        ]
      })

    {markdown, report} = render(with_hooks)

    assert markdown ==
             @header <>
               "- Public functions return frozen dataclasses, never dicts\n" <>
               "- #{@fixed}\n"

    assert report["kept_lines"] == 2

    lint_only = put_in(with_hooks, ["commands", "format"], nil)
    {markdown, _} = render(lint_only)

    assert markdown =~
             "- Lint runs automatically when you finish. Do not install or download tools.\n"

    refute markdown =~ "format"

    {markdown, _} = render(put_in(lint_only, ["commands", "lint"], nil))
    refute markdown =~ "automatically"
  end

  test "a repository with nothing to say gets a comment-only file that costs nothing" do
    {markdown, report} = render(Profile.empty("empty"))

    assert markdown == @header
    assert report["rendered_bytes"] == 0
    assert report["est_tokens_per_request"] == 0
    assert report["kept_lines"] == 0
    assert report["withheld"] == []
  end

  test "an AI policy is withheld from the model and pointed to in a comment for people" do
    profile =
      python(%{
        "rule_candidates" => [
          candidate(
            "Read `AI_POLICY.md` before contributing with AI tools",
            "instructions.ai_policy",
            path: "AI_POLICY.md"
          ),
          candidate("Read the policy first", "instructions.ai_policy", path: "bad --> path.md"),
          candidate("Read `.github/AI_POLICY.md` first", "instructions.ai_policy",
            path: ".github/AI_POLICY.md"
          )
        ]
      })

    {markdown, report} = render(profile)

    assert markdown ==
             @header <>
               "<!-- This project has an AI policy for people to read: .github/AI_POLICY.md -->\n" <>
               "<!-- This project has an AI policy for people to read: AI_POLICY.md -->\n"

    refute markdown =~ "bad"
    assert report["withheld_counts"]["process_only"] == 3
    assert report["rendered_bytes"] == 0

    for path <- ["../x.md", "a//b.md", "-x.md", "/etc/x.md", "a--b.md", "a b.md", nil],
        do: refute(Economy.comment_path?(path), inspect(path))
  end

  test "one long line does not crowd out shorter lower-ranked lines" do
    profile =
      python(%{
        "rule_candidates" => [
          candidate(String.duplicate("long ", 200) <> "first", "instructions.rule",
            confidence: 99
          ),
          candidate(String.duplicate("long ", 200) <> "second", "instructions.rule",
            confidence: 98
          ),
          candidate("Keep migrations reversible", "instructions.rule", confidence: 80)
        ]
      })

    {markdown, report} = render(profile)

    assert markdown =~ "- Keep migrations reversible\n"
    assert report["withheld_counts"]["over_budget"] == 2
    assert Enum.all?(report["withheld"], &(&1["section"] == "rules"))
  end

  test "rules are considered by confidence and the kept ones keep spec order" do
    harness = spec(python(%{"rule_candidates" => for(i <- 1..20, do: filler(i, 100 - i))}))
    {markdown, _report} = Guidance.render(harness)

    statements = Enum.map(harness["spec"]["rules"], & &1["statement"])
    kept = Enum.filter(statements, &(markdown =~ &1))
    assert kept != [] and kept != statements
    assert kept == Enum.take(statements, length(kept))
  end

  test "an @ outside a code span is withheld because it would import a file" do
    profile =
      python(%{
        "conventions" => ["Mention @team/ops on outages"],
        "rule_candidates" => [
          candidate("Imports use the `@acme/web` alias, never relative paths")
        ]
      })

    {markdown, report} = render(profile)

    assert markdown =~ "`@acme/web`"
    refute markdown =~ "@team/ops"
    assert reason(report, "Mention @team/ops on outages") == "import_marker"
  end

  test "a line repeating a kept line, and a code example with no subject, are withheld" do
    profile =
      python(%{
        "rule_candidates" => [
          candidate("Do not edit `bundle.js` or `bundle.js.map` by hand.", "instructions.rule",
            confidence: 95
          ),
          candidate(
            "Follow `AGENTS.md` in the repo root as the primary onboarding source.",
            "instructions.rule",
            confidence: 94
          ),
          candidate(
            "Never edit generated bundle artifacts (`bundle.js`, `bundle.js.map`) directly.",
            "instructions.rule",
            confidence: 93
          ),
          candidate(
            "Use `AGENTS.md` as the primary repository playbook for agent work.",
            "instructions.rule",
            confidence: 92
          ),
          candidate("Use `const { SomeName } = require(\"./file.mjs\");`", "instructions.rule",
            confidence: 91
          ),
          candidate(
            "Do not modify the root `bundle.js` file directly; it is generated.",
            "instructions.rule",
            confidence: 90
          ),
          candidate("Add an entry to `CHANGES.md` for each fix.", "instructions.rule",
            confidence: 90
          ),
          candidate("Keep `CHANGES.md` sorted by release.", "instructions.rule", confidence: 89)
        ]
      })

    {markdown, report} = render(profile)

    assert markdown =~ "Do not edit `bundle.js` or `bundle.js.map` by hand."
    assert markdown =~ "Follow `AGENTS.md` in the repo root"
    # Same code spans but no shared word: two different rules, both kept.
    assert markdown =~ "Add an entry to `CHANGES.md` for each fix."
    assert markdown =~ "Keep `CHANGES.md` sorted by release."

    assert reason(
             report,
             "Never edit generated bundle artifacts (`bundle.js`, `bundle.js.map`) directly."
           ) ==
             "duplicate"

    assert reason(report, "Use `AGENTS.md` as the primary repository playbook for agent work.") ==
             "duplicate"

    assert reason(report, "Do not modify the root `bundle.js` file directly; it is generated.") ==
             "duplicate"

    assert reason(report, "Use `const { SomeName } = require(\"./file.mjs\");`") == "no_subject"
    assert report["withheld_counts"]["duplicate"] == 3
    assert report["withheld_counts"]["no_subject"] == 1
  end

  test "unbalanced or escaped backticks cannot smuggle a file import" do
    profile =
      python(%{
        "rule_candidates" => [
          candidate("Always follow ``` @/etc/hosts ` when editing a.py files."),
          candidate("Never open ` @.env `` when changing a.py files."),
          candidate("Read \\` @/etc/passwd \\` before a.py changes."),
          candidate("Imports use the `@acme/web` alias")
        ]
      })

    {markdown, report} = render(profile)

    assert report["withheld"] |> Enum.map(& &1["reason"]) |> Enum.uniq() == ["import_marker"]
    assert report["withheld_counts"]["import_marker"] == 3
    refute markdown =~ "@/etc"
    refute markdown =~ "@.env"
    assert markdown =~ "`@acme/web`"
  end

  test "co-change rules are scoped to their files and stay out of the root file" do
    rule =
      candidate("Change `a.py` and `docs/a.rst` together", "history.cochange")
      |> Map.put("citations", [%{"detector" => "git.history", "signal" => "history.cochange"}])

    {markdown, report} = render(Map.put(Profile.empty("x"), "rule_candidates", [rule]))

    assert markdown == @header
    assert reason(report, "Change `a.py` and `docs/a.rst` together") == "scoped"
  end

  test "commit rules are kept now that the package no longer denies git commit" do
    commit = candidate("Write commit subjects as Conventional Commits")
    keep = candidate("Add an entry to `CHANGES.md` with every bug fix")
    profile = Map.put(Profile.empty("x"), "rule_candidates", [commit, keep])

    built = Spec.build(profile, Blueprint.select(profile), "solo")
    statements = Enum.map(built["spec"]["spec"]["rules"], & &1["statement"])
    assert Enum.any?(statements, &String.starts_with?(&1, "Write commit subjects"))
    assert Enum.any?(statements, &String.starts_with?(&1, "Add an entry"))
    refute Map.has_key?(built["excluded_candidates"] || %{}, "commit_denied")
  end

  # Integration point 2: lines that slipped through on development repositories, here in
  # synthetic form.
  test "session runners, lint tools, virtual environments and template checklists are process" do
    profile =
      python(%{
        "rule_candidates" => [
          candidate("For tox to find every interpreter, put each one on the PATH first."),
          candidate("Make sure `make style` passes, so flake8 is happy."),
          candidate("You need not activate the virtual environment for quick checks."),
          candidate("The checklist above was followed", "instructions.rule_candidates",
            path: ".github/PULL_REQUEST_TEMPLATE.md"
          ),
          candidate("Steps to reproduce are included", "instructions.rule_candidates",
            path: ".github/ISSUE_TEMPLATE/bug.md"
          ),
          candidate(
            "Public functions return frozen dataclasses, never dicts",
            "instructions.rule_candidates",
            path: "docs/pull_request_templates.md"
          )
        ]
      })

    {markdown, report} = render(profile)

    for line <- [
          "For tox to find every interpreter, put each one on the PATH first.",
          "Make sure `make style` passes, so flake8 is happy.",
          "You need not activate the virtual environment for quick checks.",
          "The checklist above was followed",
          "Steps to reproduce are included"
        ],
        do: assert(reason(report, line) == "process_only", line)

    # A document that only resembles a template name is read as before; "toxic" is not tox.
    assert markdown =~ "- Public functions return frozen dataclasses, never dicts\n"

    assert {_, %{"withheld" => []}} =
             render(
               python(%{"rule_candidates" => [candidate("Never log toxic payloads in full")]})
             )
  end

  test "a non-default single-test command keeps the argument it needs" do
    profile =
      Map.put(Profile.empty("x"), "commands", commands(%{"test_single" => "hatch test -k"}))

    {markdown, _report} = render(profile)

    assert markdown =~ "- Test one: `hatch test -k <expr>`\n"

    {markdown, report} =
      render(python(%{"commands" => commands(%{"test_single" => "uv run pytest -k"})}))

    refute markdown =~ "Test one"
    assert reason(report, "Test one: `uv run pytest -k <expr>`") == "default_guessable"
  end

  test "practice rules come before the changelog rule and are cut first by budget, never silently" do
    rules = Blueprint.select(%{"languages" => ["python"]})["practices"]["rules"]
    deprecation = rules["deprecation"]
    warnings = rules["warnings_as_errors"]
    changelog = "Add an entry to `CHANGES.rst` for every user-visible change."

    practices = %{
      "deprecation_sites" => 12,
      "deprecation_files" => 4,
      "removal_phrases" => 6,
      "policy_sentences" => 0,
      "warnings_as_errors" => true
    }

    base =
      python(%{
        "practices" => practices,
        "rule_candidates" => [
          candidate(changelog, "history.fix_changelog"),
          candidate("Public functions return frozen dataclasses, never dicts")
        ]
      })

    {markdown, _report} = render(base)

    assert markdown ==
             @header <>
               "- #{deprecation}\n" <>
               "- #{warnings}\n" <>
               "- #{changelog}\n" <>
               "- Public functions return frozen dataclasses, never dicts\n"

    # A test command (tier 1) long enough to leave room for the deprecation rule and
    # nothing else: the warnings and changelog rules are reported as over_budget.
    room = byte_size("- #{deprecation}\n") + 20
    command_bytes = Guidance.budget_bytes() - byte_size(@header) - room
    padding = command_bytes - byte_size("- Test: `tox -e `\n")
    command = "tox -e " <> String.duplicate("a", padding)

    {markdown, report} =
      render(Map.put(base, "commands", commands(%{"test" => command})))

    assert markdown == @header <> "- Test: `#{command}`\n" <> "- #{deprecation}\n"
    assert reason(report, warnings) == "over_budget"
    assert reason(report, changelog) == "over_budget"
    assert byte_size(markdown) <= Guidance.budget_bytes()
  end

  test "lean-ai leaves out the fixed lint and format sentences and gives their bytes to no other line" do
    fixed_lines = Blueprint.select(%{"languages" => ["python"]})["guidance"]["fixed_lines"]

    for {key, roles} <- [
          {"lint_format", %{"lint" => "ruff check .", "format" => "ruff format ."}},
          {"lint", %{"lint" => "ruff check ."}},
          {"format", %{"format" => "ruff format ."}}
        ] do
      harness =
        spec(Map.put(oversized(), "commands", commands(Map.put(roles, "test", "tox -e py312"))))

      {markdown, report} = Guidance.render(harness)

      {ai, ai_report} =
        Guidance.render(put_in(harness, ["spec", "context"], %{"profile" => "lean-ai"}))

      line = "- #{fixed_lines[key]}\n"

      assert markdown =~ line, key
      assert report["budget_bytes"] == 600
      assert report["withheld_counts"]["over_budget"] > 0

      # The lean-ai file is the file with the sentence, minus that line: nothing that was
      # over budget takes its place.
      assert ai == String.replace(markdown, line, ""), key
      assert reason(ai_report, fixed_lines[key]) == "process_only"
      assert ai_report["budget_bytes"] == 600 - byte_size(line)
      assert ai_report["rendered_bytes"] == report["rendered_bytes"] - byte_size(line)

      assert ai_report["withheld_counts"]["over_budget"] ==
               report["withheld_counts"]["over_budget"]
    end
  end

  test "price is the measured wrapper plus 2.8 bytes per token, in integers" do
    assert Economy.price(0) == 0
    assert Economy.price(1) == 111
    assert Economy.price(187) == 177
    assert Economy.price(600) == 110 + 215
  end
end
