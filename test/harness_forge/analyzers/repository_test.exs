defmodule HarnessForge.Analyzers.RepositoryTest do
  use ExUnit.Case, async: true

  alias HarnessForge.Analyzers.{Git, Inventory, Mapping, Repository}
  alias HarnessForge.Contracts
  alias HarnessForge.Contracts.{Error, Signals}
  alias HarnessForge.Generation.Profile
  alias HarnessForge.SyntheticRepositories, as: Fixtures

  @moduletag :tmp_dir

  defp signal(doc, key), do: Enum.find(doc["signals"], &(&1["key"] == key))

  defp analyze!(path) do
    assert {:ok, doc} = Repository.analyze(path)
    assert {:ok, ^doc} = Signals.validate(doc)
    doc
  end

  defp profile!(doc) do
    assert {:ok, profile} = Mapping.profile(doc)
    assert {:ok, ^profile} = Profile.validate(profile)
    profile
  end

  describe "conventional Python project" do
    setup %{tmp_dir: dir} do
      root = Fixtures.python_project(Path.join(dir, "acme-widgets"))
      %{root: root, doc: analyze!(root)}
    end

    test "commands come from CI and contributor config, not guesses", %{doc: doc} do
      profile = profile!(doc)

      assert profile["commands"] == %{
               "install" => "uv sync",
               "build" => "uv build",
               "test" => "uv run pytest",
               "test_single" => "uv run pytest -k",
               "lint" => "uv run ruff check",
               "format" => "uv run ruff format",
               "typecheck" => "uv run mypy src",
               "run" => nil
             }

      test = signal(doc, "commands.test")
      assert test["bucket"] == "auto"
      assert "ci" in test["value"]["sources"]

      assert Enum.any?(
               test["evidence"],
               &(&1["path"] == ".github/workflows/tests.yml" and &1["line"] == 8)
             )

      assert Enum.any?(test["evidence"], &(&1["path"] == "tox.ini"))
    end

    test "every command has a confidence and a pointer to its evidence", %{doc: doc} do
      for key <-
            ~w(commands.test commands.lint commands.format commands.typecheck commands.build commands.install) do
        signal = signal(doc, key)
        assert signal["confidence"] >= 70, key
        assert [_ | _] = signal["evidence"]
        assert Enum.all?(signal["evidence"], &is_binary(&1["path"]))
      end
    end

    test "language, layout and package manager reflect the repository", %{doc: doc} do
      profile = profile!(doc)
      assert profile["languages"] == ["python"]
      assert profile["package_managers"] == ["uv"]
      assert profile["ci"] == ["github-actions"]
      paths = Enum.map(profile["layout"], & &1["path"])
      assert paths == ["src/acme_widgets"]
    end

    test "history produces measured, repository-specific rules", %{doc: doc} do
      assert signal(doc, "history.sample")["value"]["state"] == "complete"

      rules = profile!(doc)["rule_candidates"]
      texts = Enum.map(rules, & &1["text"])

      assert "Add an entry to `CHANGES.md` for every user-visible change." in texts

      # Measured alone it is generic, so it stays out of hands-free output.
      assert %{"bucket" => "suggested"} =
               Enum.find(rules, &(&1["text"] =~ "Include a test change under tests/"))

      refute Enum.any?(texts, &(&1 =~ "%"))

      fix_tests = signal(doc, "history.fix_tests")["value"]
      assert fix_tests["fix_changes"] == 12
      assert fix_tests["fix_matching"] == 12
      assert fix_tests["fix_percent"] == 100

      changelog = signal(doc, "history.fix_changelog")["value"]
      assert changelog["file"] == "CHANGES.md"
      assert changelog["fix_percent"] == 100
    end

    test "cochange pairs a source file with its test", %{doc: doc} do
      pairs = signal(doc, "history.cochange")["value"]["pairs"]

      assert Enum.any?(
               pairs,
               &(&1["source"] == "src/acme_widgets/parser.py" and
                   &1["test"] == "tests/test_parser.py")
             )
    end

    test "history pairs each source file with the tests that change with it", %{doc: doc} do
      assert %{"bucket" => "auto", "value" => %{"pairs" => pairs}} =
               signal(doc, "history.test_pairs")

      assert Enum.all?(pairs, &(&1["support"] >= 2 and &1["kind"] in ["cochange", "named_after"]))

      profile = profile!(doc)

      assert profile["test_pairs"] == [
               %{
                 "source" => "src/acme_widgets/cache.py",
                 "test" => "tests/test_cache.py",
                 "support" => 4,
                 "kind" => "named_after"
               },
               %{
                 "source" => "src/acme_widgets/client.py",
                 "test" => "tests/test_client.py",
                 "support" => 5,
                 "kind" => "named_after"
               },
               %{
                 "source" => "src/acme_widgets/parser.py",
                 "test" => "tests/test_parser.py",
                 "support" => 6,
                 "kind" => "named_after"
               }
             ]

      # No source pair reaches 4 shared changes and 40% of the file's changes here.
      assert signal(doc, "history.source_cochange")["value"]["pairs"] == []
      assert profile["cochange"] == []
      assert profile["paths_dropped_charset"] == 0
    end

    test "each check command names the executable the session-start check looks for", %{doc: doc} do
      assert signal(doc, "commands.tools")["value"]["unknown"] == []

      assert profile!(doc)["tools"] == [
               %{
                 "role" => "test",
                 "command" => "uv run pytest",
                 "probe" => ["pytest"],
                 "extensions" => [".py"],
                 "source" => "runner_prefix"
               },
               %{
                 "role" => "lint",
                 "command" => "uv run ruff check",
                 "probe" => ["ruff"],
                 "extensions" => [".py", ".pyi"],
                 "source" => "runner_prefix"
               },
               %{
                 "role" => "typecheck",
                 "command" => "uv run mypy src",
                 "probe" => ["mypy"],
                 "extensions" => [".py", ".pyi"],
                 "source" => "runner_prefix"
               },
               %{
                 "role" => "format",
                 "command" => "uv run ruff format",
                 "probe" => ["ruff"],
                 "extensions" => [".py", ".pyi"],
                 "source" => "runner_prefix"
               }
             ]
    end

    test "only actionable, repository-specific sentences are lifted", %{doc: doc} do
      lifted = signal(doc, "instructions.rule_candidates")["value"]["rules"]
      texts = Enum.map(lifted, & &1["text"])

      assert "Run `uv run pytest` before you open a pull request." in texts

      assert "If you changed a public API, update the stubs in `src/acme_widgets/client.py`." in texts

      refute Enum.any?(texts, &(&1 =~ "friendly library"))
      refute Enum.any?(texts, &(&1 =~ "We use GitHub Actions"))
      refute Enum.any?(texts, &(&1 =~ "stores widgets in memory"))
      refute Enum.any?(texts, &(&1 =~ "Always add a test"))
      refute Enum.any?(texts, &(&1 =~ "curl"))
      refute Enum.any?(texts, &(&1 =~ "maintainer"))
      refute Enum.any?(texts, &(&1 =~ "OLDNEWS.md"))
      refute Enum.any?(texts, &(&1 =~ "legacy_build"))
    end

    test "lifted citations are byte-exact", %{root: root, doc: doc} do
      lifted = signal(doc, "instructions.rule_candidates")["value"]["rules"]
      assert lifted != []

      for rule <- lifted do
        bytes = File.read!(Path.join(root, rule["path"]))
        assert binary_part(bytes, rule["byte_start"], rule["byte_length"]) == rule["source_text"]
        lines = String.split(bytes, "\n")

        assert String.contains?(
                 Enum.at(lines, rule["line"] - 1),
                 String.slice(rule["source_text"], 0, 8)
               )
      end
    end

    test "no author identity or absolute path reaches the output", %{root: root, doc: doc} do
      encoded = Contracts.canonical_json(doc)
      refute encoded =~ Fixtures.author_name()
      refute encoded =~ Fixtures.author_email()
      refute encoded =~ root
      refute encoded =~ "subject"
    end
  end

  describe "source co-change" do
    test "files that change together in most of their changes become partners", %{tmp_dir: dir} do
      root = Fixtures.init!(Path.join(dir, "pairs"))

      Fixtures.commit!(root, 0, "Initial", %{
        "pyproject.toml" => "[project]\nname = \"pairs\"\n",
        "src/pairs/models.py" => "a = 0\n",
        "src/pairs/views.py" => "b = 0\n",
        "src/pairs/util.py" => "c = 0\n",
        "tests/test_models.py" => "def test_a():\n    pass\n",
        "tests/conftest.py" => "\n"
      })

      for i <- 1..5 do
        Fixtures.commit!(root, i, "Change models #{i}", %{
          "src/pairs/models.py" => "a = #{i}\n",
          "src/pairs/views.py" => "b = #{i}\n",
          "tests/test_models.py" => "def test_a():\n    assert #{i}\n",
          "tests/conftest.py" => "# #{i}\n"
        })
      end

      Fixtures.commit!(root, 6, "Tweak models", %{
        "src/pairs/models.py" => "a = 6\n",
        "src/pairs/util.py" => "c = 6\n"
      })

      for i <- 7..9,
          do: Fixtures.commit!(root, i, "Notes #{i}", %{"README.md" => "# pairs #{i}\n"})

      profile = profile!(analyze!(root))

      assert profile["cochange"] == [
               %{
                 "path" => "src/pairs/models.py",
                 "partner" => "src/pairs/views.py",
                 "support" => 6,
                 "percent" => 86
               },
               %{
                 "path" => "src/pairs/views.py",
                 "partner" => "src/pairs/models.py",
                 "support" => 6,
                 "percent" => 100
               }
             ]

      # conftest.py changes with everything and is not a test module; util.py changed
      # with the test once, below the support of 2.
      assert profile["test_pairs"] == [
               %{
                 "source" => "src/pairs/models.py",
                 "test" => "tests/test_models.py",
                 "support" => 6,
                 "kind" => "named_after"
               },
               %{
                 "source" => "src/pairs/views.py",
                 "test" => "tests/test_models.py",
                 "support" => 6,
                 "kind" => "cochange"
               }
             ]
    end
  end

  describe "Node project" do
    setup %{tmp_dir: dir} do
      root = Fixtures.node_project(Path.join(dir, "acme-routes"))
      %{doc: analyze!(root)}
    end

    test "unwraps a coverage wrapper to the test script", %{doc: doc} do
      profile = profile!(doc)
      assert profile["commands"]["test"] == "npm test"
      assert profile["commands"]["install"] == "npm install"
      assert profile["commands"]["lint"] == "npm run lint"

      assert profile["commands"]["test_single"] ==
               "npx mocha --require test/support/env --check-leaks"

      assert profile["frameworks"] == ["koa"]
      assert profile["package_managers"] == ["npm"]
      assert Enum.any?(signal(doc, "commands.test")["evidence"], &(&1["path"] == "package.json"))
    end

    test "a package script is probed by the program it starts", %{doc: doc} do
      assert [
               %{"role" => "test", "probe" => ["mocha"], "source" => "package_script"},
               %{"role" => "lint", "probe" => ["eslint"], "source" => "package_script"}
             ] = profile!(doc)["tools"]
    end
  end

  describe "Elixir project" do
    setup %{tmp_dir: dir} do
      root = Fixtures.elixir_project(Path.join(dir, "acme_ledger"))
      %{doc: analyze!(root)}
    end

    test "reads mix.exs as text and normalises CI format checks", %{doc: doc} do
      profile = profile!(doc)
      assert profile["commands"]["format"] == "mix format"
      assert profile["commands"]["test"] == "mix test --warnings-as-errors"
      assert profile["commands"]["lint"] == "mix credo --strict"
      assert profile["commands"]["typecheck"] == "mix dialyzer"
      assert profile["commands"]["run"] == "mix phx.server"
      assert profile["frameworks"] == ["phoenix"]
      paths = Enum.map(profile["layout"], & &1["path"])
      assert "lib/acme_ledger_web" in paths

      assert Enum.map(profile["tools"], &{&1["role"], &1["probe"], &1["extensions"]}) == [
               {"test", ["mix"], [".exs"]},
               {"lint", ["mix"], [".ex", ".exs"]},
               {"typecheck", ["mix"], []},
               {"format", ["mix"], [".ex", ".exs", ".heex"]}
             ]
    end
  end

  describe "secrets trap" do
    test "secrets are never read or emitted", %{tmp_dir: dir} do
      root = Fixtures.secrets_trap(Path.join(dir, "trap"))
      doc = analyze!(root)
      encoded = Contracts.canonical_json(doc)

      refute encoded =~ Fixtures.env_secret()
      refute encoded =~ Fixtures.token()

      report = signal(doc, "privacy.report")["value"]
      assert report["secret_paths_skipped"] >= 4
      assert ".env" in report["secret_paths"]

      lifted = signal(doc, "instructions.rule_candidates")["value"]["rules"]
      refute Enum.any?(lifted, &(&1["text"] =~ "API_KEY"))
      refute Enum.any?(lifted, &(&1["text"] =~ "staging token"))
      assert Enum.any?(lifted, &(&1["text"] =~ "before you push"))

      files = signal(doc, "stack.manifests")["value"]["files"]
      assert "package.json" in files

      # A CI line holding a credential never becomes a command.
      runs = signal(doc, "ci.runs")["value"]["runs"]
      assert [%{"command" => "npm test"}] = runs
      assert profile!(doc)["commands"]["test"] == "npm test"
    end

    test "the inventory refuses secret paths even when asked for them", %{tmp_dir: dir} do
      root = Fixtures.secrets_trap(Path.join(dir, "trap"))
      {:ok, repo} = Git.open(root)
      inventory = Inventory.build(root, repo)

      assert ".env" in inventory.secret_paths
      assert ".npmrc" in inventory.secret_paths
      refute ".env" in inventory.files

      {contents, _} =
        Inventory.load(inventory, [".env", ".env.production", ".npmrc", "secrets/server.pem"])

      assert contents == %{}
    end
  end

  describe "bounds" do
    test "oversized files, symlinks and file counts are capped and reported", %{tmp_dir: dir} do
      outside = Path.join(dir, "outside.md")
      root = Fixtures.bounded_inputs(Path.join(dir, "bounded"), outside)

      doc = analyze!(root)
      encoded = Contracts.canonical_json(doc)
      refute encoded =~ "OUTSIDE-CONTENT"

      report = signal(doc, "privacy.report")["value"]
      assert report["oversize_files"] == 1
      assert report["unreadable_files"] == 1

      assert {:ok, capped} = Repository.analyze(root, max_files: 10)
      assert capped["aggregates"]["listed_files"] == 10
      assert Enum.find(capped["detectors"], &(&1["name"] == "stack"))["truncated"]
    end
  end

  describe "plain directory" do
    test "is analyzed without git and reports that visibly", %{tmp_dir: dir} do
      root = Fixtures.plain_directory(Path.join(dir, "plain"))
      doc = analyze!(root)

      assert doc["repository"]["git"] == "git_unavailable"
      assert doc["repository"]["git_reason"] == "not_a_repository"
      assert doc["repository"]["head"] == nil

      history = signal(doc, "history.sample")
      assert history["value"]["state"] == "git_unavailable"
      assert history["confidence"] == 0
      assert history["bucket"] == "observed"

      profile = profile!(doc)
      assert profile["commands"]["test"] == "go test ./..."
      assert "go" in profile["languages"]

      encoded = Contracts.canonical_json(doc)
      refute encoded =~ "left-pad"
      refute encoded =~ Fixtures.env_secret()
    end
  end

  describe "hostile .git/config" do
    test "no program named by the repository runs during analysis", %{tmp_dir: dir} do
      {root, marker} = Fixtures.hostile_git_config(Path.join(dir, "hostile"), dir)
      doc = analyze!(root)

      refute File.exists?(marker)
      assert doc["repository"]["git"] == "available"
      assert signal(doc, "history.sample")["value"]["state"] == "complete"
      assert profile!(doc)["commands"]["test"] == "uv run pytest"
    end
  end

  describe "reduced histories" do
    test "a repository with no commits is visibly empty", %{tmp_dir: dir} do
      root = Fixtures.empty_repository(Path.join(dir, "fresh"))
      doc = analyze!(root)

      assert doc["repository"]["git"] == "available"
      assert doc["repository"]["head"] == nil

      history = signal(doc, "history.sample")
      assert history["value"]["state"] == "empty"
      assert history["confidence"] == 0

      refute Enum.any?(doc["signals"], &(&1["key"] == "history.fix_tests"))
      assert profile!(doc)["commands"]["test"] == "npm test"
    end

    test "a shallow clone keeps history rules out of the auto bucket", %{tmp_dir: dir} do
      source = Fixtures.python_project(Path.join(dir, "source"))
      {clone, _} = Fixtures.shallow_clone(source, Path.join(dir, "clone"), 11)
      doc = analyze!(clone)

      sample = signal(doc, "history.sample")
      assert sample["value"]["state"] == "shallow"
      assert sample["confidence"] == 30

      rates = ~w(history.fix_tests history.fix_changelog history.cochange)

      for key <- rates do
        assert signal(doc, key)["confidence"] < 40, key
      end

      measured =
        profile!(doc)["rule_candidates"]
        |> Enum.filter(fn c ->
          Enum.all?(c["citations"], &String.starts_with?(&1["signal"], "history."))
        end)

      assert measured != []
      assert Enum.all?(measured, &(&1["bucket"] != "auto"))
    end
  end

  describe "determinism" do
    test "the same state yields identical bytes, wherever the checkout lives", %{tmp_dir: dir} do
      first = Fixtures.python_project(Path.join(dir, "acme-widgets"))
      moved = Path.join([dir, "elsewhere", "acme-widgets"])
      File.mkdir_p!(Path.dirname(moved))
      File.cp_r!(first, moved)

      a = analyze!(first)
      b = analyze!(first)
      c = analyze!(moved)

      assert Contracts.canonical_json(a) == Contracts.canonical_json(b)
      assert Contracts.canonical_json(a) == Contracts.canonical_json(c)
      assert Contracts.digest(a) == Contracts.digest(c)
      assert profile!(a) == profile!(c)
    end
  end

  describe "errors" do
    test "a non-directory path returns a contract error" do
      assert {:error, %Error{code: "invalid_repository_path"}} =
               Repository.analyze("/no/such/place/at/all")

      assert {:error, %Error{code: "invalid_repository_path"}} = Repository.analyze(:not_a_path)
    end
  end
end
