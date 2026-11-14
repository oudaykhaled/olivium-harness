defmodule HarnessForge.Analyzers.PracticesTest do
  use ExUnit.Case, async: true

  alias HarnessForge.Analyzers.{Mapping, Practices, Repository}
  alias HarnessForge.Contracts
  alias HarnessForge.Contracts.Signals
  alias HarnessForge.Generation.{Blueprint, Guidance, Profile, Spec}
  alias HarnessForge.SyntheticRepositories, as: Fixtures

  @moduletag :tmp_dir

  @pyproject ~s([project]\nname = "demo"\nrequires-python = ">=3.10"\n)
  @package_json ~s({"name": "demo", "version": "1.0.0", "scripts": {"test": "mocha"}}\n)

  defp py_warning(name) do
    """
    def #{name}():
        warnings.warn(
            "#{name} is deprecated and will be removed in 3.0; use new_#{name}",
            DeprecationWarning,
            stacklevel=2,
        )
        return new_#{name}()

    """
  end

  defp py_module(names), do: "import warnings\n\n" <> Enum.map_join(names, &py_warning/1)

  defp repo(dir, name, files) do
    root = Fixtures.init!(Path.join(dir, name))
    Fixtures.commit!(root, 0, "Initial import", files)
    root
  end

  defp analyze!(root) do
    assert {:ok, doc} = Repository.analyze(root)
    assert {:ok, ^doc} = Signals.validate(doc)
    doc
  end

  defp profile!(doc) do
    assert {:ok, profile} = Mapping.profile(doc)
    assert {:ok, ^profile} = Profile.validate(profile)
    profile
  end

  defp spec!(profile), do: Spec.build(profile, Blueprint.select(profile), "solo")["spec"]

  defp fired(spec) do
    for rule <- spec["spec"]["rules"],
        signal = get_in(rule, ["source", "signal"]),
        String.starts_with?(signal, "practices."),
        do: signal
  end

  defp counts(doc),
    do: Enum.find(doc["signals"], &(&1["key"] == "practices.counts"))["value"]

  describe "deprecation sites in one source file" do
    test "a Python warn call counts when its line or the seven after it mention deprecation" do
      assert Practices.sites("src/a.py", py_module(~w(one two))) == 2

      # The window looks forward from the call, never back.
      assert Practices.sites("src/a.py", """
             warnings.warn("old", RemovedIn40Warning)
             warn(msg, stacklevel=2)
             """) == 1

      assert Practices.sites("src/a.py", ~s|warnings.warn("value out of range", UserWarning)\n|) ==
               0

      far = "warnings.warn(\n" <> String.duplicate("    x,\n", 8) <> "    DeprecationWarning)\n"
      assert Practices.sites("src/a.py", far) == 0
    end

    test "a @deprecated decorator counts, a mention in a comment or name does not" do
      assert Practices.sites("src/a.py", """
             from typing_extensions import deprecated

             @deprecated("Use new_name")
             def old_name(): ...

             @typing_extensions.deprecated("Use other")
             def other(): ...

             # this helper is deprecated
             def is_deprecated(value): ...
             """) == 2
    end

    test "a JavaScript helper call counts and its definition does not" do
      assert Practices.sites("lib/a.js", """
             const deprecate = require('depd')('demo')
             deprecate('res.json(status, obj): Use res.status(status).json(obj) instead')
             util.deprecate(fn, 'fn() is deprecated')
             function deprecate(message) {
               return message
             }
             class Legacy {
               deprecated(name) {
                 return name
               }
             }
             export function deprecatedMethod(name) {}
             """) == 2
    end

    test "a JavaScript warning about deprecation and a JSDoc tag count" do
      assert Practices.sites("src/a.ts", """
             /** @deprecated Use next() */
             export function previous() {
               console.warn(
                 'previous() is deprecated'
               )
             }
             // @deprecated since 2.0
             console.warn('retrying request')
             """) == 3
    end

    test "a line longer than 4 KiB is never matched" do
      long = "warnings.warn('deprecated', DeprecationWarning) " <> String.duplicate("x", 4100)
      assert Practices.sites("src/a.py", long) == 0
    end
  end

  describe "policy sentences in maintainer documents" do
    test "a sentence needs deprecation, a time word and a break word" do
      assert Practices.policy_sentences("""
             # Compatibility

             Public API is deprecated for at least one minor release before it is
             removed. Deprecated names raise a warning.

             We never drop a deprecated
             option without a deprecation period.
             """) == 2

      assert Practices.policy_sentences("Deprecated: `old_name`. Use `new_name`.\n") == 0
      assert Practices.policy_sentences("Remove the cache before running tests.\n") == 0
    end

    test "a sentence over 2 KiB is skipped" do
      text = "Deprecate before removing " <> String.duplicate("word ", 500) <> "."
      assert Practices.policy_sentences(text) == 0
    end
  end

  describe "warnings as errors" do
    test "pytest configurations in every supported file are read" do
      cases = [
        {"pyproject.toml",
         ~s([tool.pytest.ini_options]\nfilterwarnings = [\n  "error",\n  "ignore::ImportWarning",\n]\n)},
        {"pyproject.toml", ~s([tool.pytest.ini_options]\nfilterwarnings = "error"\n)},
        {"pyproject.toml", ~s([tool.pytest.ini_options]\naddopts = "-ra -W error"\n)},
        {"pyproject.toml", ~s([tool.pytest.ini_options]\naddopts = ["-ra", "-Werror"]\n)},
        {"pytest.ini", "[pytest]\nfilterwarnings =\n    error\n    ignore::UserWarning\n"},
        {"setup.cfg", "[metadata]\nname = demo\n\n[tool:pytest]\naddopts = -W error::Warning\n"},
        {"tox.ini", "[tox]\nenvlist = py312\n\n[pytest]\nfilterwarnings = error\n"}
      ]

      for {file, text} <- cases do
        assert Practices.warnings_as_errors(%{file => text}) == {true, file}, text
      end
    end

    test "a filter that does not start with error, or another section, does not count" do
      cases = [
        {"pyproject.toml", ~s([tool.pytest.ini_options]\nfilterwarnings = ["once::Warning"]\n)},
        {"pyproject.toml", ~s([tool.coverage.run]\nfilterwarnings = ["error"]\n)},
        {"setup.cfg", "[flake8]\nfilterwarnings = error\n"},
        {"pytest.ini", "[pytest]\n# filterwarnings = error\naddopts = -ra\n"}
      ]

      for {file, text} <- cases do
        assert Practices.warnings_as_errors(%{file => text}) == {false, nil}, text
      end
    end

    test "a long continuation in an INI file is read in linear time" do
      text =
        "[pytest]\nfilterwarnings =\n" <> String.duplicate("    ignore::UserWarning\n", 10_000)

      {elapsed, result} =
        :timer.tc(fn -> Practices.warnings_as_errors(%{"pytest.ini" => text}) end)

      assert result == {false, nil}
      assert elapsed < 2_000_000
    end
  end

  # Twelve synthetic repositories with the practice rules a person reading them would
  # expect. Gate 0 row 10 requires all twelve.
  defp fixtures do
    # Languages come from source files, so every Python fixture has a package module.
    py = fn files ->
      Map.merge(%{"pyproject.toml" => @pyproject, "src/demo/__init__.py" => ""}, files)
    end

    node = fn files -> Map.merge(%{"package.json" => @package_json}, files) end

    [
      {"py-three-warnings", py.(%{"src/demo/api.py" => py_module(~w(a b c))}),
       ["practices.deprecation"]},
      {"py-policy-only",
       py.(%{
         "CONTRIBUTING.md" =>
           "# Contributing\n\nA public name is deprecated for at least one minor release before it is removed.\n"
       }), ["practices.deprecation"]},
      {"py-warnings-error",
       py.(%{
         "pyproject.toml" =>
           @pyproject <> ~s(\n[tool.pytest.ini_options]\nfilterwarnings = ["error"]\n)
       }), ["practices.warnings_as_errors"]},
      {"py-both",
       py.(%{
         "src/demo/api.py" => py_module(~w(a b c d)),
         "setup.cfg" => "[tool:pytest]\nfilterwarnings =\n    error\n    ignore::ImportWarning\n"
       }), ["practices.deprecation", "practices.warnings_as_errors"]},
      {"py-decorators",
       py.(%{
         "src/demo/api.py" =>
           "from typing_extensions import deprecated\n\n" <>
             Enum.map_join(~w(a b c), &"@deprecated(\"Use new_#{&1}\")\ndef #{&1}(): ...\n\n")
       }), ["practices.deprecation"]},
      {"node-depd",
       node.(%{
         "lib/index.js" =>
           "const deprecate = require('depd')('demo')\n" <>
             Enum.map_join(
               ~w(json send jsonp),
               &"deprecate('res.#{&1}(status): use res.status()')\n"
             )
       }), ["practices.deprecation"]},
      {"node-jsdoc",
       node.(%{
         "src/index.ts" =>
           Enum.map_join(
             ~w(a b c),
             &"/** @deprecated Use next_#{&1}() */\nexport function #{&1}() {}\n"
           )
       }), ["practices.deprecation"]},
      {"py-two-warnings", py.(%{"src/demo/api.py" => py_module(~w(a b))}), []},
      {"py-tests-only", py.(%{"tests/test_api.py" => py_module(~w(a b c d e))}), []},
      {"py-vendor-only", py.(%{"src/demo/vendor/six.py" => py_module(~w(a b c d e))}), []},
      {"py-changelog-only",
       py.(%{
         "CHANGES.md" =>
           "# Changes\n\nThe old names were deprecated for at least one release before they were removed.\n",
         "docs/changelog.md" =>
           "Deprecated options are removed after a deprecation period of one release.\n"
       }), []},
      {"node-definitions-only",
       node.(%{
         "lib/util.js" =>
           "export function deprecated(name) {\n  return name\n}\n" <>
             "function deprecate(message) {\n  console.warn(message)\n}\n"
       }), []}
    ]
  end

  describe "synthetic classifier" do
    test "fires the expected practice rules on all twelve fixtures", %{tmp_dir: dir} do
      results =
        for {name, files, expected} <- fixtures() do
          spec = dir |> repo(name, files) |> analyze!() |> profile!() |> spec!()
          {name, fired(spec), expected}
        end

      mismatches =
        for {name, got, expected} <- results, got != expected, do: {name, got, expected}

      assert length(results) == 12
      assert mismatches == []
    end

    test "the rendered file carries the sentence only when the rule fires", %{tmp_dir: dir} do
      sentence =
        Blueprint.select(%{"languages" => ["python"]})["practices"]["rules"]["deprecation"]

      with_rule =
        repo(dir, "with", %{
          "pyproject.toml" => @pyproject,
          "src/demo/api.py" => py_module(~w(a b c))
        })

      without =
        repo(dir, "without", %{
          "pyproject.toml" => @pyproject,
          "src/demo/api.py" => py_module(~w(a b))
        })

      render = fn root ->
        {markdown, report} = root |> analyze!() |> profile!() |> spec!() |> Guidance.render()
        {markdown, report}
      end

      {first, report} = render.(with_rule)
      {second, ^report} = render.(with_rule)
      assert first == second
      assert first =~ "- " <> sentence <> "\n"
      refute Enum.any?(report["withheld"], &(&1["text"] == sentence))

      {plain, _report} = render.(without)
      refute plain =~ sentence
    end

    test "counts reach the spec and the evidence names files, never text", %{tmp_dir: dir} do
      root =
        repo(dir, "evidence", %{
          "pyproject.toml" => @pyproject,
          "src/demo/api.py" => py_module(~w(a b c)),
          "CONTRIBUTING.md" => "Deprecated APIs stay for at least one release before removal.\n"
        })

      doc = analyze!(root)
      signal = Enum.find(doc["signals"], &(&1["key"] == "practices.counts"))

      assert signal["value"]["deprecation_sites"] == 3
      assert signal["value"]["deprecation_files"] == 1
      assert signal["value"]["policy_sentences"] == 1
      assert signal["value"]["removal_phrases"] == 3
      assert Enum.map(signal["evidence"], & &1["path"]) == ["src/demo/api.py", "CONTRIBUTING.md"]
      refute Contracts.canonical_json(doc) =~ "will be removed"

      spec = doc |> profile!() |> spec!()

      assert spec["spec"]["project"]["practices"] == %{
               "deprecation_sites" => 3,
               "deprecation_files" => 1,
               "removal_phrases" => 3,
               "policy_sentences" => 1,
               "warnings_as_errors" => false
             }

      [rule] = spec["spec"]["rules"] |> Enum.filter(&(&1["source"]["detector"] == "practices"))
      assert rule["origin"] == "derived"

      assert rule["source"] == %{
               "detector" => "practices",
               "signal" => "practices.deprecation",
               "path" => nil,
               "line" => nil
             }
    end

    test "a stack without practice sentences emits none, whatever the counts" do
      counts = %{
        "deprecation_sites" => 50,
        "deprecation_files" => 10,
        "removal_phrases" => 10,
        "policy_sentences" => 3,
        "warnings_as_errors" => true
      }

      for languages <- [["elixir"], ["cobol"]] do
        profile =
          "demo"
          |> Profile.empty()
          |> Map.merge(%{"languages" => languages, "practices" => counts})

        assert {:ok, profile} = Profile.validate(profile)
        spec = spec!(profile)
        assert fired(spec) == []
        assert spec["spec"]["project"]["practices"] == counts
      end

      node =
        "demo"
        |> Profile.empty()
        |> Map.merge(%{"languages" => ["javascript"], "practices" => counts})

      assert node |> spec!() |> fired() == ["practices.deprecation"]
    end
  end

  describe "bounds" do
    test "at most 400 source files are read and the cut is reported", %{tmp_dir: dir} do
      root = Path.join(dir, "many")

      files =
        for i <- 1..401, into: %{"pyproject.toml" => @pyproject} do
          {"src/demo/m#{String.pad_leading(to_string(i), 3, "0")}.py", "VALUE = #{i}\n"}
        end

      Fixtures.write!(root, files)
      doc = analyze!(root)

      assert counts(doc)["sources_read"] == 400
      detector = Enum.find(doc["detectors"], &(&1["name"] == "practices"))
      assert detector["truncated"] == true
      assert detector["complete"] == false
    end

    test "a source file or document that links to a secret is not counted", %{tmp_dir: dir} do
      root = Fixtures.init!(Path.join(dir, "linked"))
      File.write!(Path.join(root, ".gitignore"), ".env\n")

      File.write!(
        Path.join(root, ".env"),
        py_module(~w(a b c d)) <>
          "Deprecated names stay for at least one release before removal.\n"
      )

      File.mkdir_p!(Path.join(root, "src/demo"))
      File.ln_s!("../../.env", Path.join(root, "src/demo/api.py"))
      File.ln_s!(".env", Path.join(root, "CONTRIBUTING.md"))

      Fixtures.commit!(root, 0, "start", %{
        "pyproject.toml" => @pyproject,
        "src/demo/__init__.py" => ""
      })

      doc = analyze!(root)
      assert counts(doc)["deprecation_sites"] == 0
      assert counts(doc)["policy_sentences"] == 0
      assert doc |> profile!() |> spec!() |> fired() == []
    end

    test "hostile text costs time proportional to its size" do
      line = String.duplicate("warn(depd(deprecate(", 200)
      many_calls = Enum.map_join(1..64, fn _ -> line <> "\n" end)
      spaces = "will" <> String.duplicate(" ", 250_000) <> "be"
      words = String.duplicate("deprecat before remov ", 12_000)

      {elapsed, _} =
        :timer.tc(fn ->
          Practices.sites("lib/a.js", many_calls)
          Practices.sites("src/a.py", many_calls)
          Practices.sites("src/a.py", spaces)
          Practices.policy_sentences(words)
          Practices.policy_sentences(spaces)
        end)

      assert elapsed < 3_000_000
    end
  end

  describe "interpreter pin" do
    defp interpreter(dir, name, files) do
      dir
      |> repo(name, Map.merge(%{"pyproject.toml" => @pyproject}, files))
      |> analyze!()
      |> profile!()
      |> Map.fetch!("tools")
      |> Enum.find(&(&1["role"] == "interpreter"))
    end

    test "a pinned Python version becomes the interpreter probe", %{tmp_dir: dir} do
      assert interpreter(dir, "pin", %{".python-version" => "3.14\n"}) == %{
               "role" => "interpreter",
               "command" => nil,
               "probe" => ["python3.14"],
               "extensions" => [],
               "source" => "requires_python"
             }

      assert interpreter(dir, "default", %{".python-version-default" => "3.13.1\n"})["probe"] ==
               ["python3.13"]

      assert interpreter(dir, "several", %{
               ".python-version" => "# pins\n3.12\n3.13\n3.12\n3.11\n3.10\n"
             })["probe"] == ["python3.12", "python3.13", "python3.11"]
    end

    test "a lower bound, another implementation or a version name is not a pin", %{tmp_dir: dir} do
      assert interpreter(dir, "bound", %{}) == nil
      assert interpreter(dir, "pypy", %{".python-version" => "pypy3.10\n"}) == nil
      assert interpreter(dir, "named", %{".python-version" => "system\n"}) == nil
      assert interpreter(dir, "python2", %{".python-version" => "2.7\n"}) == nil
    end
  end
end
