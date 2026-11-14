defmodule HarnessForge.Generation.BlueprintTest do
  use ExUnit.Case, async: true

  alias HarnessForge.Generation.{Blueprint, Economy, Profile}

  defp profile(languages, commands) do
    "demo"
    |> Profile.empty()
    |> Map.merge(%{"languages" => languages})
    |> update_in(["commands"], &Map.merge(&1, commands))
  end

  test "every placeholder in every blueprint is a known command or project field" do
    known = MapSet.new(["project.name" | Enum.map(Profile.command_keys(), &("commands." <> &1))])

    for {name, blueprint} <- Blueprint.all(),
        entry <- [blueprint["agent"], blueprint["skill"]],
        entry do
      for text <- [entry["description"] | entry["instructions"]],
          key <- Blueprint.placeholders(text) do
        assert MapSet.member?(known, key), "#{name} uses unknown placeholder #{key}"
      end
    end
  end

  test "the first language with a stack blueprint selects it" do
    assert Blueprint.version(Blueprint.select(profile(["go", "python"], %{}))) == "python@4"
    assert Blueprint.version(Blueprint.select(profile(["TypeScript"], %{}))) == "node@4"
    assert Blueprint.version(Blueprint.select(profile(["elixir"], %{}))) == "elixir@3"
    assert Blueprint.version(Blueprint.select(profile(["cobol"], %{}))) == "base@3"
  end

  test "lines with a missing command are left out and commands are filled in" do
    p = profile(["python"], %{"test" => "uv run pytest"})
    agent = Blueprint.render(Blueprint.select(p)["agent"], p)

    assert agent["instructions"] =~ "`uv run pytest`"
    refute agent["instructions"] =~ "{{"
    refute agent["instructions"] =~ "Lint"
  end

  test "an entry whose required command is missing is left out" do
    p = profile(["python"], %{"lint" => "ruff check ."})
    assert Blueprint.render(Blueprint.select(p)["agent"], p) == nil
    assert Blueprint.render(Blueprint.select(p)["skill"], p) == nil
  end

  test "the lean context profile is measured, closed and keeps Skill with Workflow" do
    profiles = Blueprint.select(profile([], %{}))["context_profiles"]

    assert profiles["measured_on"] == "claude-code 2.1.311"
    assert profiles["solo_default"] == "lean"
    assert Map.keys(profiles) |> Enum.sort() == ~w(lean lean-ai measured_on solo_default standard)
    # lean-ai trims exactly as lean; everything it adds is learned content, not settings.
    assert profiles["lean-ai"] == profiles["lean"]

    lean = profiles["lean"]
    assert lean["include_git_instructions"] == false
    assert lean["est_tokens_saved_per_request"] == 11_700
    assert lean["notebook_tools"] == ["NotebookEdit"]
    assert lean["deny_tools"] == Enum.sort(Enum.uniq(lean["deny_tools"]))
    assert length(lean["deny_tools"]) == 15
    assert "Skill" in lean["deny_tools"] and "Workflow" in lean["deny_tools"]

    for name <- ~w(ToolSearch Agent Bash Read Edit Write Grep Glob WebFetch WebSearch),
        do: refute(name in lean["deny_tools"], name)

    refute Map.has_key?(lean, "disable_bundled_skills")
    assert profiles["standard"]["deny_tools"] == []
    assert profiles["standard"]["include_git_instructions"] == true
  end

  test "every stack overlays guidance defaults the inclusion test reads" do
    for language <- ~w(python typescript elixir) do
      defaults = Blueprint.select(profile([language], %{}))["guidance_defaults"]

      assert defaults["test_commands"] != []
      assert defaults["single_test_commands"] != []
      assert Enum.all?(defaults["test_locations"], &String.contains?(&1, "|"))
    end

    base = Blueprint.select(profile(["cobol"], %{}))
    assert base["guidance_defaults"] in [nil, %{}]

    fixed = base["guidance"]["fixed_lines"]

    assert fixed["lint_format"] ==
             "Lint and format run automatically when you finish. Do not install or download tools."

    for {_key, line} <- fixed,
        do: assert(String.ends_with?(line, "Do not install or download tools."))
  end

  test "practice rules are short, kept by the inclusion test and fire on positive thresholds" do
    expected = %{
      "python" => ~w(deprecation warnings_as_errors),
      "typescript" => ~w(deprecation),
      "elixir" => [],
      "cobol" => []
    }

    for {language, ids} <- expected do
      practices = Blueprint.select(profile([language], %{}))["practices"] || %{}
      tables = Economy.tables(%{"languages" => [language]})
      rules = practices["rules"] || %{}

      assert Enum.sort(Map.keys(rules)) == ids, language

      for {_id, text} <- rules do
        assert byte_size(text) <= 200
        refute String.contains?(text, "@")

        assert Economy.classify(%{section: "rules", text: text, signal: "practices.x"}, tables) ==
                 :keep
      end

      for {_key, threshold} <- practices["thresholds"] || %{},
          do: assert(is_integer(threshold) and threshold > 0)
    end
  end

  test "agent and skill bodies stay short" do
    for {_name, blueprint} <- Blueprint.all(),
        entry <- [blueprint["agent"], blueprint["skill"]] do
      assert length(entry["instructions"]) <= 12
      assert String.length(entry["description"]) <= 140
    end
  end
end
