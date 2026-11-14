defmodule HarnessForge.Analyzers.HardeningTest do
  use ExUnit.Case, async: true

  alias HarnessForge.Analyzers.{Mapping, Privacy, Repository}
  alias HarnessForge.Contracts
  alias HarnessForge.Generation.{Blueprint, Spec}
  alias HarnessForge.SyntheticRepositories, as: Fixtures

  @moduletag :tmp_dir

  defp profile!(root) do
    {:ok, doc} = Repository.analyze(root)
    {:ok, profile} = Mapping.profile(doc)
    {doc, profile}
  end

  defp texts(profile), do: Enum.map(profile["rule_candidates"], & &1["text"])

  test "credentials the token patterns name are found" do
    for text <- [
          "uv sync --index https://deploy:hunter2hunter2@pypi.example/simple",
          "git clone https://0123456789abcdef0123@git.example/repo",
          "Publish with `pypi-AgEIcHlwaS5vcmcCJDAwMDAwMDAw`",
          "Use `glpat-abcdefghijklmnopqrst` for the mirror",
          "Set `sk_live_51HabcdefghijklmnopQR` for payments",
          "npm publish --token abc123",
          "Use `Ab1Cd2Ef3Gh4Ij5Kl6Mn7Op8Qr9St0UvWx` as the key"
        ] do
      assert Privacy.secret?(text), text
    end

    for text <- [
          "uv run pytest",
          "git clone https://github.example/repo",
          "See `0123456789abcdef0123456789abcdef01234567`",
          "`src/app/SomeVeryLongModuleNameThatIsOnlyWords.py`"
        ] do
      refute Privacy.secret?(text), text
    end
  end

  test "a credential in CI or a contributing document reaches nothing", %{tmp_dir: dir} do
    root = Fixtures.init!(Path.join(dir, "leak"))

    Fixtures.commit!(root, 0, "start", %{
      "pyproject.toml" => "[project]\nname = \"leak\"\n",
      "src/app.py" => "x = 1\n",
      "uv.lock" => "version = 1\n",
      "CONTRIBUTING.md" =>
        "Always publish with `glpat-abcdefghijklmnopqrst` from `src/app.py`.\n",
      ".github/workflows/ci.yml" => """
      jobs:
        test:
          steps:
            - run: uv sync --index https://deploy:hunter2hunter2@pypi.example/simple
            - run: uv run pytest
      """
    })

    {doc, profile} = profile!(root)
    encoded = Contracts.canonical_json(doc) <> Contracts.canonical_json(profile)

    refute encoded =~ "hunter2hunter2"
    refute encoded =~ "glpat-"
    assert profile["commands"]["test"] == "uv run pytest"
    refute String.contains?(profile["commands"]["install"] || "", "pypi.example")
  end

  test "a secret reached through a tracked symlink is not opened", %{tmp_dir: dir} do
    root = Fixtures.init!(Path.join(dir, "gitignored"))
    File.write!(Path.join(root, ".gitignore"), ".env\n")

    File.write!(
      Path.join(root, ".env"),
      "Always use `untracked-value` for `pyproject.toml` runs.\n"
    )

    File.ln_s!(".env", Path.join(root, "CONTRIBUTING.md"))
    Fixtures.commit!(root, 0, "start", %{"pyproject.toml" => "[project]\nname = \"x\"\n"})

    {doc, profile} = profile!(root)

    refute Contracts.canonical_json(doc) =~ "untracked-value"
    refute Enum.any?(texts(profile), &(&1 =~ "untracked-value"))
  end

  test "a symlink to an ordinary document still works", %{tmp_dir: dir} do
    root = Fixtures.init!(Path.join(dir, "linked"))
    File.mkdir_p!(Path.join(root, "docs"))
    File.write!(Path.join(root, "docs/guide.md"), "Always run `pyproject.toml` checks first.\n")
    File.ln_s!("docs/guide.md", Path.join(root, "CONTRIBUTING.md"))
    Fixtures.commit!(root, 0, "start", %{"pyproject.toml" => "[project]\nname = \"x\"\n"})

    {_doc, profile} = profile!(root)
    assert Enum.any?(texts(profile), &(&1 =~ "checks first"))
  end

  describe "paths from history" do
    defp churn(root, source, test, count \\ 12) do
      for day <- 0..(count - 1) do
        Fixtures.commit!(root, day, "Change #{day}", %{
          source => "x = #{day}\n",
          test => "y = #{day}\n"
        })
      end

      root
    end

    test "a person's address or a secret path never reaches a rule", %{tmp_dir: dir} do
      email =
        churn(
          Fixtures.init!(Path.join(dir, "emailpath")),
          "team/alice.smith@example.com/a.py",
          "tests/test_x.py"
        )

      secret =
        churn(
          Fixtures.init!(Path.join(dir, "secretpath")),
          "secrets/prod_keys.py",
          "tests/test_y.py"
        )

      {doc, profile} = profile!(email)
      refute Contracts.canonical_json(doc) =~ "alice.smith"
      refute Contracts.canonical_json(profile) =~ "alice.smith"

      {doc, profile} = profile!(secret)

      refute Enum.any?(
               doc["signals"],
               &(&1["key"] != "privacy.report" and Contracts.canonical_json(&1) =~ "prod_keys")
             )

      refute Contracts.canonical_json(profile) =~ "prod_keys"
    end

    test "an unusual path does not fail the whole analysis", %{tmp_dir: dir} do
      root = churn(Fixtures.init!(Path.join(dir, "backslash")), "src/a\\b.py", "tests/test_z.py")

      assert {:ok, doc} = Repository.analyze(root)
      refute Contracts.canonical_json(doc) =~ "a\\\\b.py"
    end

    test "a co-change rule is plain, and skipped when the test is named after the source", %{
      tmp_dir: dir
    } do
      root = churn(Fixtures.init!(Path.join(dir, "pairs")), "src/core.py", "tests/test_core.py")
      {_doc, named} = profile!(root)
      refute Enum.any?(texts(named), &(&1 =~ "together"))

      other = churn(Fixtures.init!(Path.join(dir, "other")), "src/core.py", "tests/test_api.py")
      {_doc, profile} = profile!(other)

      assert "Change `src/core.py` and `tests/test_api.py` together" in texts(profile)
    end

    test "local git configuration does not change a rule", %{tmp_dir: dir} do
      root = churn(Fixtures.init!(Path.join(dir, "normal")), "src/core.py", "tests/test_api.py")
      {_doc, before} = profile!(root)

      Fixtures.git!(root, ["config", "log.showRoot", "false"])
      {_doc, later} = profile!(root)

      assert before == later
    end
  end

  test "a CI-only absolute path never becomes a command", %{tmp_dir: dir} do
    root = Fixtures.init!(Path.join(dir, "abspath"))

    Fixtures.commit!(root, 0, "start", %{
      "go.mod" => "module x\n",
      "main.go" => "package main\n",
      ".github/workflows/ci.yml" => """
      jobs:
        test:
          steps:
            - run: go test -coverprofile=/home/runner/alice/cov.out ./...
      """
    })

    {_doc, profile} = profile!(root)

    refute Contracts.canonical_json(profile["commands"]) =~ "/home/runner"
  end

  test "an AI policy file reaches the guidance as a pointer", %{tmp_dir: dir} do
    root = Fixtures.init!(Path.join(dir, "policy"))

    Fixtures.commit!(root, 0, "start", %{
      "pyproject.toml" => "[project]\nname = \"x\"\n",
      ".github/AI_POLICY.md" => "No unsupervised tools.\n"
    })

    {_doc, profile} = profile!(root)
    spec = Spec.build(profile, Blueprint.select(profile), "solo")["spec"]

    assert Enum.any?(spec["spec"]["rules"], &(&1["statement"] =~ "`.github/AI_POLICY.md`"))
    refute Contracts.canonical_json(spec) =~ "unsupervised"
  end
end
