defmodule HarnessForge.Adapters.ClaudeCodeHooksTest do
  @moduledoc """
  The stage 1 adapter contract (context profile, environment check, quiet narrow Stop
  hook, data files) on the contract's own example spec. The adapter is called directly,
  so these tests do not depend on when the generator and schema start emitting the
  same shape. Every script runs with `sh` against stub programs that only record their
  arguments; no project code runs.
  """
  use ExUnit.Case, async: true

  alias HarnessForge.Adapters.ClaudeCode
  alias HarnessForge.Adapters.ClaudeCode.Hooks
  alias HarnessForge.Contracts.Error
  alias HarnessForge.Generation.{Blueprint, Profile, Spec}

  @env ".claude/hooks/olivium-env-check.sh"
  @stop ".claude/hooks/olivium-before-stop.sh"
  @format ".claude/hooks/olivium-format.sh"
  @pairs ".olivium/test-pairs.tsv"
  @cochange ".olivium/cochange.tsv"
  @last "If these failures are not caused by your change, stop again."

  @lean ~w(CronCreate CronDelete CronList EnterWorktree ExitWorktree ListAgents Monitor NotebookEdit ReportFindings ScheduleWakeup SendMessage Skill Task TaskStop Workflow)

  # The stage 1 contract's example spec (section 9), verbatim; the plan it belongs to is
  # docs/plans/harness-enhancement-plan.md.
  @contract ~S"""
  {
    "apiVersion": "harnessforge.dev/v1alpha2",
    "kind": "Harness",
    "metadata": {"name": "samplepkg", "version": "0.1.0"},
    "spec": {
      "agents": [],
      "skills": [],
      "context": {
        "profile": "lean",
        "include_git_instructions": false,
        "auto_memory": true,
        "deny_tools": [
          "CronCreate", "CronDelete", "CronList", "EnterWorktree", "ExitWorktree",
          "ListAgents", "Monitor", "NotebookEdit", "ReportFindings", "ScheduleWakeup",
          "SendMessage", "Skill", "Task", "TaskStop", "Workflow"
        ],
        "measured_on": "claude-code 2.1.311",
        "est_tokens_saved_per_request": 11700
      },
      "guidance": [
        {"id": "conventions", "title": "Conventions", "lines": [
          "Add an entry to `CHANGES.rst` for every user-visible change."
        ]}
      ],
      "hooks": [
        {"id": "env-check", "event": "session_start", "builtin": "env_check", "timeout_seconds": 5},
        {"id": "format-before-stop", "event": "before_stop", "role": "format",
         "command": "ruff format", "file_argument": true, "selector": "changed_files", "timeout_seconds": 30},
        {"id": "lint-before-stop", "event": "before_stop", "role": "lint",
         "command": "ruff check", "file_argument": true, "selector": "changed_files", "timeout_seconds": 60},
        {"id": "test-before-stop", "event": "before_stop", "role": "test",
         "command": "python -m pytest -q", "file_argument": true, "selector": "related_tests", "timeout_seconds": 60}
      ],
      "project": {
        "name": "samplepkg",
        "languages": ["python"],
        "package_managers": ["pip"],
        "ci": ["github-actions"],
        "commands": {
          "build": null, "format": "ruff format", "install": null, "lint": "ruff check",
          "run": null, "test": "python -m pytest -q", "test_single": null, "typecheck": "mypy"
        },
        "conventions": [],
        "frameworks": [],
        "layout": [],
        "tools": [
          {"role": "test", "command": "python -m pytest -q", "probe": ["pytest"], "extensions": [".py"], "source": "runner_prefix"},
          {"role": "lint", "command": "ruff check", "probe": ["ruff"], "extensions": [".py", ".pyi"], "source": "manifest_tool"},
          {"role": "typecheck", "command": "mypy", "probe": ["mypy"], "extensions": [".py", ".pyi"], "source": "manifest_tool"},
          {"role": "format", "command": "ruff format", "probe": ["ruff"], "extensions": [".py", ".pyi"], "source": "manifest_tool"},
          {"role": "interpreter", "command": null, "probe": ["python3.13"], "extensions": [], "source": "requires_python"}
        ],
        "test_pairs": [
          {"source": "src/samplepkg/core.py", "test": "tests/test_core.py", "support": 12, "kind": "named_after"},
          {"source": "src/samplepkg/core.py", "test": "tests/test_options.py", "support": 7, "kind": "cochange"},
          {"source": "src/samplepkg/io.py", "test": "tests/test_io.py", "support": 4, "kind": "cochange"}
        ],
        "cochange": [
          {"path": "src/samplepkg/core.py", "partner": "src/samplepkg/types.py", "support": 6, "percent": 41},
          {"path": "src/samplepkg/types.py", "partner": "src/samplepkg/core.py", "support": 6, "percent": 55}
        ]
      },
      "rules": []
    }
  }
  """

  # The contract fragment over a generated spec, so permissions, policies and scope keep
  # their current shape, as the contract says.
  defp fixture do
    contract = Jason.decode!(@contract)

    {:ok, profile} =
      Path.expand("../../../examples/profiles/python_package.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()
      |> Profile.validate()

    base = Spec.build(profile, Blueprint.select(profile), "solo")["spec"]

    base
    |> Map.put("metadata", contract["metadata"])
    |> Map.update!("spec", fn spec ->
      spec
      |> Map.merge(Map.take(contract["spec"], ~w(agents skills context guidance hooks rules)))
      |> Map.update!("project", &Map.merge(&1, contract["spec"]["project"]))
    end)
  end

  # The contract fixture with every Python role run through `uv run`, as uv projects are.
  defp uv_fixture do
    roles = [
      {"test", "uv run pytest", "pytest", [".py"]},
      {"lint", "uv run ruff check", "ruff", [".py", ".pyi"]},
      {"typecheck", "uv run mypy", "mypy", [".py", ".pyi"]},
      {"format", "uv run ruff format", "ruff", [".py", ".pyi"]}
    ]

    tools =
      for {role, command, probe, extensions} <- roles,
          do: %{
            "role" => role,
            "command" => command,
            "probe" => [probe],
            "extensions" => extensions,
            "source" => "runner_prefix"
          }

    hooks =
      for {role, command, _probe, _extensions} <- roles, role != "typecheck" do
        %{
          "id" => role <> "-before-stop",
          "event" => "before_stop",
          "role" => role,
          "command" => command,
          "file_argument" => true,
          "selector" => if(role == "test", do: "related_tests", else: "changed_files"),
          "timeout_seconds" => if(role == "format", do: 30, else: 60)
        }
      end

    fixture()
    |> update_in(
      ["spec", "project", "commands"],
      &Map.merge(&1, Map.new(roles, fn {role, command, _, _} -> {role, command} end))
    )
    |> put_spec(["project", "tools"], tools)
    |> put_spec(["hooks"], [
      %{
        "id" => "env-check",
        "event" => "session_start",
        "builtin" => "env_check",
        "timeout_seconds" => 5
      }
      | Enum.sort_by(hooks, &Map.fetch!(%{"format" => 0, "lint" => 1, "test" => 2}, &1["role"]))
    ])
  end

  @mocha "npx mocha --require test/support/env"

  # A mocha project like express: no format or lint step, tests through npx.
  defp mocha_fixture do
    fixture()
    |> update_in(
      ["spec", "project", "commands"],
      &Map.merge(&1, %{"test" => @mocha, "format" => nil, "lint" => nil, "typecheck" => nil})
    )
    |> put_spec(["project", "languages"], ["javascript"])
    |> put_spec(["project", "tools"], [
      %{
        "role" => "test",
        "command" => @mocha,
        "probe" => ["mocha"],
        "extensions" => [".cjs", ".js", ".mjs"],
        "source" => "runner_prefix"
      }
    ])
    |> put_spec(["project", "test_pairs"], [
      %{
        "source" => "lib/request.js",
        "test" => "test/req.query.js",
        "support" => 4,
        "kind" => "cochange"
      }
    ])
    |> put_spec(["project", "cochange"], [])
    |> put_spec(["hooks"], [
      %{
        "id" => "env-check",
        "event" => "session_start",
        "builtin" => "env_check",
        "timeout_seconds" => 5
      },
      %{
        "id" => "test-before-stop",
        "event" => "before_stop",
        "role" => "test",
        "command" => @mocha,
        "file_argument" => true,
        "selector" => "related_tests",
        "timeout_seconds" => 60
      }
    ])
  end

  @node_paths ~w(lib/request.js lib/response.js test/req.query.js test/res.send.js test/support/env.js test/support/utils.js test/fixtures/broken.js test/acceptance/auth.js package.json)

  defp compile(spec), do: ClaudeCode.compile_v2(spec, %{"mode" => "preview"})

  defp files(spec) do
    {:ok, output} = compile(spec)
    output["files"]
  end

  defp settings(files), do: Jason.decode!(files[".claude/settings.json"])

  defp put_spec(harness, path, value), do: put_in(harness, ["spec" | path], value)

  defp project_dir do
    dir = Path.join(System.tmp_dir!(), "hf-hooks-#{Ecto.UUID.generate()}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  # Executables that record their name and arguments in $STUB_LOG, print $STUB_OUT_<name>
  # if set, and exit with $STUB_EXIT_<name> (default 0). They run nothing else.
  defp stubs(dir, names, behaviour \\ %{}) do
    bin = Path.join(dir, "stub-bin")
    File.mkdir_p!(bin)

    for name <- names do
      path = Path.join(bin, name)

      File.write!(path, """
      #!/bin/sh
      printf '%s\\n' "#{name} $*" >>"$STUB_LOG"
      #{Map.get(behaviour, name, "")}
      exit 0
      """)

      File.chmod!(path, 0o755)
    end

    bin
  end

  defp sh(script, dir, input, env) do
    path = Path.join(dir, ".script-under-test.sh")
    File.write!(path, script)

    System.cmd("sh", ["-c", ~s(printf '%s' "$HOOK_INPUT" | /bin/sh "$HOOK_SCRIPT")],
      env: [{"HOOK_INPUT", input}, {"HOOK_SCRIPT", path}, {"CLAUDE_PROJECT_DIR", dir}] ++ env,
      stderr_to_stdout: true
    )
  end

  defp git!(dir, args) do
    {_, 0} =
      System.cmd("git", ["-c", "user.name=a", "-c", "user.email=a@example.invalid" | args],
        cd: dir,
        stderr_to_stdout: true
      )
  end

  # A synthetic package at its base commit, with the export's files untracked as they
  # are in a real checkout.
  @python_paths ~w(src/samplepkg/__init__.py src/samplepkg/core.py src/samplepkg/io.py src/samplepkg/types.py src/samplepkg/extra.py tests/test_core.py tests/test_options.py tests/test_io.py tests/conftest.py README.md)

  defp sample_repo(files, paths \\ @python_paths) do
    dir = project_dir()

    for path <- paths do
      File.mkdir_p!(Path.dirname(Path.join(dir, path)))
      File.write!(Path.join(dir, path), "# synthetic\n")
    end

    git!(dir, ["init", "-q"])
    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "-q", "-m", "start"])
    # The test's own scaffolding is not part of the agent's change.
    File.write!(
      Path.join(dir, ".git/info/exclude"),
      ".script-under-test.sh\n.stub-log\nstub-bin/\n"
    )

    for {path, bytes} <- files,
        String.starts_with?(path, [".claude/", ".olivium/", "CLAUDE.md"]) do
      File.mkdir_p!(Path.dirname(Path.join(dir, path)))
      File.write!(Path.join(dir, path), bytes)
    end

    dir
  end

  # Session variables the scripts read. Unset unless a test sets them, so the shell the
  # suite runs in cannot change a result.
  @session_env ~w(UV_FROZEN UV_LOCKED UV_NO_SYNC UV_PROJECT_ENVIRONMENT VIRTUAL_ENV)

  defp session_env(extra_env) do
    @session_env
    |> Map.new(&{&1, nil})
    |> Map.merge(Map.new(extra_env))
    |> Enum.sort()
  end

  defp stop(files, dir, bin, extra_env \\ []) do
    log = Path.join(dir, ".stub-log")
    File.write!(log, "")

    result =
      sh(
        files[@stop],
        dir,
        ~s({"stop_hook_active":false}),
        session_env([{"PATH", bin <> ":/usr/bin:/bin"}, {"STUB_LOG", log} | extra_env])
      )

    {result, File.read!(log)}
  end

  describe "settings.json from the context profile" do
    test "lean renders the measured keys only, merged into the deny list" do
      settings = settings(files(fixture()))
      deny = settings["permissions"]["deny"]

      assert settings["includeGitInstructions"] == false
      assert @lean -- deny == []
      assert deny == Enum.sort(deny)
      assert deny == Enum.uniq(deny)
      # The existing deny rules stay.
      assert "Bash(git push:*)" in deny
      assert "Edit(.env)" in deny

      # Measured to raise the request (disableBundledSkills +4,007, skillOverrides) or to
      # take away the user's own memory (owner decision O1): never rendered here.
      for key <- ~w(disableBundledSkills skillOverrides autoMemoryEnabled env) do
        refute Map.has_key?(settings, key), key
      end

      refute "ToolSearch" in deny
      refute "Bash" in deny
    end

    test "hooks are registered for SessionStart and Stop (plus the guard), never PostToolUse" do
      hooks = settings(files(fixture()))["hooks"]

      assert Map.keys(hooks) == ["PreToolUse", "SessionStart", "Stop"]

      assert [%{"hooks" => [%{"type" => "command", "timeout" => 5, "command" => env}]} = entry] =
               hooks["SessionStart"]

      refute Map.has_key?(entry, "matcher")
      assert env =~ ~s(f="$CLAUDE_PROJECT_DIR/#{@env}"; if [ -f "$f" ]; then /bin/sh "$f";)

      # (30 + 5) + (60 + 5) + (60 + 5) + 15: longer than every bounded step together.
      assert [%{"hooks" => [%{"timeout" => 180, "command" => stop}]}] = hooks["Stop"]
      assert stop =~ ~s(f="$CLAUDE_PROJECT_DIR/#{@stop}"; if [ -f "$f" ]; then /bin/sh "$f";)
    end

    test "standard renders no trim; auto_memory false is the only way to switch memory off" do
      standard =
        fixture()
        |> put_spec(["context"], %{
          "profile" => "standard",
          "include_git_instructions" => true,
          "auto_memory" => true,
          "deny_tools" => [],
          "measured_on" => "claude-code 2.1.311",
          "est_tokens_saved_per_request" => 0
        })

      settings = settings(files(standard))
      refute Map.has_key?(settings, "includeGitInstructions")
      refute Map.has_key?(settings, "autoMemoryEnabled")
      assert Enum.filter(settings["permissions"]["deny"], &(&1 in @lean)) == []

      memory_off = put_spec(standard, ["context", "auto_memory"], false)
      assert settings(files(memory_off))["autoMemoryEnabled"] == false

      # A spec without a context profile renders exactly as before the profile existed.
      legacy = update_in(fixture(), ["spec"], &Map.delete(&1, "context"))
      assert settings(files(legacy)) |> Map.drop(["hooks"]) == Map.drop(settings, ["hooks"])
    end

    test "a profile outside the contract is refused, never repaired" do
      for {change, code} <- [
            {&put_spec(&1, ["context", "deny_tools"], @lean -- ["Workflow"]),
             "invalid_runtime_intent"},
            {&put_spec(&1, ["context", "deny_tools"], ["ToolSearch" | @lean]),
             "invalid_runtime_intent"},
            {&put_spec(&1, ["context", "deny_tools"], ["Task", "Task"]),
             "invalid_runtime_intent"},
            {&put_spec(&1, ["context", "profile"], "tiny"), "invalid_runtime_intent"},
            {&put_spec(&1, ["context", "include_git_instructions"], "no"),
             "invalid_runtime_intent"},
            {&put_spec(&1, ["agents"], [
               %{"name" => "helper", "description" => "Helps", "instructions" => "Help."}
             ]), "lean_profile_unavailable"},
            {&put_spec(&1, ["skills"], [
               %{"name" => "checks", "description" => "Checks", "instructions" => "Check."}
             ]), "lean_profile_unavailable"}
          ] do
        assert {:error, %Error{code: ^code}} = compile(change.(fixture()))
      end

      # The generator keeps NotebookEdit when notebooks are tracked; the adapter renders
      # whatever closed-enum subset the spec holds.
      kept = put_spec(fixture(), ["context", "deny_tools"], @lean -- ["NotebookEdit"])
      refute "NotebookEdit" in settings(files(kept))["permissions"]["deny"]
    end
  end

  describe "data files" do
    test "test pairs and co-change partners are plain tab-separated rows in spec order" do
      files = files(fixture())

      assert files[@pairs] ==
               "src/samplepkg/core.py\ttests/test_core.py\t12\n" <>
                 "src/samplepkg/core.py\ttests/test_options.py\t7\n" <>
                 "src/samplepkg/io.py\ttests/test_io.py\t4\n"

      assert files[@cochange] ==
               "src/samplepkg/core.py\tsrc/samplepkg/types.py\t6\t41\n" <>
                 "src/samplepkg/types.py\tsrc/samplepkg/core.py\t6\t55\n"

      empty =
        fixture()
        |> put_spec(["project", "test_pairs"], [])
        |> put_spec(["project", "cochange"], [])
        |> files()

      assert empty[@pairs] == ""
      assert empty[@cochange] == ""
    end

    test "a row or name that would reach a script outside the contract is refused" do
      bad = [
        {["project", "test_pairs"],
         [
           %{
             "source" => "src/a.py",
             "test" => "../etc/passwd",
             "support" => 2,
             "kind" => "cochange"
           }
         ]},
        {["project", "test_pairs"],
         [
           %{
             "source" => "src/a b.py",
             "test" => "tests/t.py",
             "support" => 2,
             "kind" => "cochange"
           }
         ]},
        {["project", "test_pairs"],
         [%{"source" => "/abs.py", "test" => "tests/t.py", "support" => 2, "kind" => "cochange"}]},
        {["project", "cochange"],
         [%{"path" => "src/a.py", "partner" => "src/$(x).py", "support" => 4, "percent" => 40}]},
        {["project", "tools"],
         [%{"role" => "test", "command" => "x", "probe" => ["py;test"], "extensions" => []}]},
        {["project", "tools"],
         [%{"role" => "lint", "command" => "x", "probe" => ["ruff"], "extensions" => ["py"]}]},
        {["project", "tools"],
         [%{"role" => "deploy", "command" => "x", "probe" => ["ruff"], "extensions" => []}]},
        {["hooks"],
         [
           %{
             "id" => "lint-before-stop",
             "event" => "before_stop",
             "role" => "lint",
             "command" => "ruff check; touch x",
             "file_argument" => true,
             "selector" => "changed_files",
             "timeout_seconds" => 60
           }
         ]},
        {["hooks"],
         [
           %{
             "id" => "lint-before-stop",
             "event" => "before_stop",
             "role" => "lint",
             "command" => "ruff check",
             "file_argument" => true,
             "selector" => "related_tests",
             "timeout_seconds" => 60
           }
         ]},
        {["hooks"],
         [
           %{
             "id" => "locator",
             "event" => "prompt_submit",
             "builtin" => "locator",
             "timeout_seconds" => 3
           }
         ]},
        {["hooks"],
         [
           %{
             "id" => "env-check",
             "event" => "session_start",
             "builtin" => "locator",
             "timeout_seconds" => 5
           }
         ]}
      ]

      for {path, value} <- bad do
        assert {:error, %Error{code: "invalid_runtime_intent"}} =
                 compile(put_spec(fixture(), path, value)),
               inspect(value)
      end
    end

    test "two compilations give the same bytes" do
      assert files(fixture()) == files(fixture())
    end
  end

  describe "SessionStart environment check" do
    defp env_run(files, dir, bin, extra_env \\ []) do
      sh(
        files[@env],
        dir,
        ~s({"hook_event_name":"SessionStart","source":"startup"}),
        session_env([
          {"PATH", bin <> ":/usr/bin:/bin"},
          {"STUB_LOG", Path.join(dir, ".stub-log")} | extra_env
        ])
      )
    end

    test "one fixed line for a missing role; nothing at all when every tool resolves" do
      files = files(fixture())
      dir = project_dir()

      for name <- ~w(pytest ruff mypy python3.13) do
        refute File.exists?("/usr/bin/" <> name) or File.exists?("/bin/" <> name), name
      end

      bin = stubs(dir, ~w(pytest ruff python3.13))

      assert env_run(files, dir, bin) ==
               {"Type checking is not available here: mypy is not installed. Skip it. Do not install it.\n",
                0}

      stubs(dir, ~w(mypy))
      assert env_run(files, dir, bin) == {"", 0}
      # Nothing was run: the stubs never logged a call.
      refute File.exists?(Path.join(dir, ".stub-log"))
    end

    test "every role in contract order, at most five lines, when nothing is installed" do
      dir = project_dir()
      bin = stubs(dir, [])

      assert {output, 0} = env_run(files(fixture()), dir, bin)

      assert String.split(output, "\n", trim: true) == [
               "Testing is not available here: pytest is not installed. Skip it. Do not install it.",
               "Linting is not available here: ruff is not installed. Skip it. Do not install it.",
               "Type checking is not available here: mypy is not installed. Skip it. Do not install it.",
               "Formatting is not available here: ruff is not installed. Skip it. Do not install it.",
               "Python 3.13 is not available here: python3.13 is not installed. Skip it. Do not install it."
             ]
    end

    test "a tool in .venv/bin or node_modules/.bin counts as installed" do
      dir = project_dir()
      bin = stubs(dir, ~w(pytest ruff python3.13))

      for {place, name} <- [{".venv/bin", "mypy"}] do
        File.mkdir_p!(Path.join(dir, place))
        File.write!(Path.join([dir, place, name]), "#!/bin/sh\nexit 0\n")
        File.chmod!(Path.join([dir, place, name]), 0o755)
      end

      assert env_run(files(fixture()), dir, bin) == {"", 0}

      File.rm!(Path.join(dir, ".venv/bin/mypy"))
      File.mkdir_p!(Path.join(dir, "node_modules/.bin"))
      File.write!(Path.join(dir, "node_modules/.bin/mypy"), "#!/bin/sh\nexit 0\n")
      File.chmod!(Path.join(dir, "node_modules/.bin/mypy"), 0o755)
      assert env_run(files(fixture()), dir, bin) == {"", 0}

      # Present but not executable does not count.
      File.chmod!(Path.join(dir, "node_modules/.bin/mypy"), 0o644)
      assert {"Type checking" <> _, 0} = env_run(files(fixture()), dir, bin)
    end

    test "the script only asks whether names resolve and environments exist" do
      for spec <- [fixture(), uv_fixture(), mocha_fixture()] do
        script = files(spec)[@env]

        body =
          script
          |> String.split("\n")
          |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))

        for line <- body do
          assert line =~
                   ~r/^(d=\$\{CLAUDE_PROJECT_DIR:-\.\}|resolves\(\) \{|  for n in "\$@"; do|    command -v "\$n" >\/dev\/null 2>&1 && return 0|    \[ -x "\$d\/(\.venv\/bin|node_modules\/\.bin)\/\$n" \] && return 0|  done|  return 1|\}|uv_env\(\) \{|  e=\$\{UV_PROJECT_ENVIRONMENT:-\.venv\}|  case \$e in \/\*\) ;; \*\) e=\$d\/\$e ;; esac|  \[ -d "\$e" \]|python_env\(\) \{ \[ -d "\$d\/\.venv" \] \|\| \[ -n "\$\{VIRTUAL_ENV:-\}" \]; \}|node_env\(\) \{ \[ -d "\$d\/node_modules" \]; \}|resolves '[A-Za-z0-9._+-]+'( '[A-Za-z0-9._+-]+')* \|\| (! (uv|python|node)_env \|\| )?printf '%s\\n' '[A-Za-z0-9 .:]+'|exit 0)$/,
                 line
        end

        refute script =~ ~r/(^|[;&|({]|then|do)\s*eval\s/m
        assert {_, 0} = System.cmd("sh", ["-n", "-c", script])
      end

      assert files(uv_fixture())[@env] =~ "resolves 'mypy' || ! uv_env || printf"
      assert files(mocha_fixture())[@env] =~ "resolves 'mocha' || ! node_env || printf"
      refute files(fixture())[@env] =~ "_env"
    end

    # Review 1, issue 3: on a fresh clone the runner sets the environment up first, so a
    # tool that is not there yet may come with it; the check cannot tell and is silent.
    test "a tool behind a runner is reported only once the runner's environment exists" do
      dir = project_dir()
      bin = stubs(dir, ~w(uv))
      files = files(uv_fixture())

      # Fresh clone: no .venv, no UV_PROJECT_ENVIRONMENT. uv run would set it up.
      assert env_run(files, dir, bin) == {"", 0}

      missing = [
        "Testing is not available here: pytest is not installed. Skip it. Do not install it.",
        "Linting is not available here: ruff is not installed. Skip it. Do not install it.",
        "Type checking is not available here: mypy is not installed. Skip it. Do not install it.",
        "Formatting is not available here: ruff is not installed. Skip it. Do not install it."
      ]

      # The environment exists elsewhere, as in the benchmark images (/opt/venv).
      elsewhere = Path.join(project_dir(), "opt-venv")
      File.mkdir_p!(elsewhere)
      assert {output, 0} = env_run(files, dir, bin, [{"UV_PROJECT_ENVIRONMENT", elsewhere}])
      assert String.split(output, "\n", trim: true) == missing

      # Tools that resolve are not reported; a relative setting is read from the project.
      stubs(dir, ~w(pytest ruff))

      assert env_run(files, dir, bin, [{"UV_PROJECT_ENVIRONMENT", elsewhere}]) ==
               {Enum.at(missing, 2) <> "\n", 0}

      assert env_run(files, dir, bin, [{"UV_PROJECT_ENVIRONMENT", "missing-env"}]) == {"", 0}
      File.mkdir_p!(Path.join(dir, ".venv"))
      assert env_run(files, dir, bin) == {Enum.at(missing, 2) <> "\n", 0}

      # npm and npx need node_modules.
      node = files(mocha_fixture())
      node_dir = project_dir()
      node_bin = stubs(node_dir, ~w(npx))
      assert env_run(node, node_dir, node_bin) == {"", 0}
      File.mkdir_p!(Path.join(node_dir, "node_modules"))

      assert env_run(node, node_dir, node_bin) ==
               {"Testing is not available here: mocha is not installed. Skip it. Do not install it.\n",
                0}
    end

    # Round 2, item 3 interpreter entry (contract section 3: command null, probe python3.N,
    # source requires_python). uv run fetches a missing Python when it sets up the
    # environment, so the line follows the project's Python runner like its tools do.
    test "the interpreter entry follows the project's Python runner" do
      interpreter = %{
        "role" => "interpreter",
        "command" => nil,
        "probe" => ["python3.14"],
        "extensions" => [],
        "source" => "requires_python"
      }

      line =
        "Python 3.14 is not available here: python3.14 is not installed. Skip it. Do not install it.\n"

      uv = uv_fixture() |> update_in(["spec", "project", "tools"], &(&1 ++ [interpreter]))
      files = files(uv)
      assert files[@env] =~ "resolves 'python3.14' || ! uv_env || printf"

      dir = project_dir()
      bin = stubs(dir, ~w(uv pytest ruff mypy))
      # Fresh clone: uv run would set up the environment, Python included.
      assert env_run(files, dir, bin) == {"", 0}
      # The environment exists and has no Python 3.14.
      File.mkdir_p!(Path.join(dir, ".venv/bin"))
      assert env_run(files, dir, bin) == {line, 0}
      # A virtualenv names its interpreter python3.N.
      File.write!(Path.join(dir, ".venv/bin/python3.14"), "#!/bin/sh\n")
      File.chmod!(Path.join(dir, ".venv/bin/python3.14"), 0o755)
      assert env_run(files, dir, bin) == {"", 0}

      # Without a runner, the interpreter is reported whenever it does not resolve.
      plain = fixture() |> put_spec(["project", "tools", Access.at(4)], interpreter) |> files()
      assert plain[@env] =~ "resolves 'python3.14' || printf"
      plain_dir = project_dir()
      plain_bin = stubs(plain_dir, ~w(pytest ruff mypy))
      assert env_run(plain, plain_dir, plain_bin) == {line, 0}
      stubs(plain_dir, ~w(python3.14))
      assert env_run(plain, plain_dir, plain_bin) == {"", 0}

      # A pin file may name several versions: any one of them is enough, and the line
      # names the first.
      several = put_in(interpreter["probe"], ["python3.13", "python3.12"])

      pinned =
        uv_fixture() |> update_in(["spec", "project", "tools"], &(&1 ++ [several])) |> files()

      assert pinned[@env] =~ "resolves 'python3.13' 'python3.12' || ! uv_env || printf"
      pinned_dir = project_dir()
      pinned_bin = stubs(pinned_dir, ~w(uv pytest ruff mypy))
      File.mkdir_p!(Path.join(pinned_dir, ".venv/bin"))

      assert env_run(pinned, pinned_dir, pinned_bin) ==
               {"Python 3.13 is not available here: python3.13 is not installed. Skip it. Do not install it.\n",
                0}

      stubs(pinned_dir, ~w(python3.12))
      assert env_run(pinned, pinned_dir, pinned_bin) == {"", 0}
    end
  end

  describe "Stop hook on the contract fixture" do
    # Integration point 2 (Gate 0 row 6): the one test history pairs most often with a
    # changed source still added 2 to 30 s to a passing stop on the v2 gold patches.
    test "a changed source: format and lint that file; no test runs, not even its history pair" do
      files = files(fixture())
      dir = sample_repo(files)
      bin = stubs(dir, ~w(ruff python pytest))
      File.write!(Path.join(dir, "src/samplepkg/core.py"), "# changed\n")

      assert {{"", 0}, log} = stop(files, dir, bin)

      # core.py pairs with test_core.py (12 commits) and test_options.py (7): neither runs.
      assert log ==
               "ruff format src/samplepkg/core.py\n" <>
                 "ruff check src/samplepkg/core.py\n"
    end

    test "at most 3 test files, the changed ones by name; history pairs never run" do
      pairs = [
        {"src/samplepkg/core.py", "tests/test_core.py", 12},
        {"src/samplepkg/core.py", "tests/test_options.py", 7},
        {"src/samplepkg/io.py", "tests/test_io.py", 4},
        {"src/samplepkg/types.py", "tests/test_core.py", 3},
        {"src/samplepkg/types.py", "tests/test_types.py", 9}
      ]

      spec =
        put_spec(
          fixture(),
          ["project", "test_pairs"],
          for(
            {source, test, support} <- pairs,
            do: %{"source" => source, "test" => test, "support" => support, "kind" => "cochange"}
          )
        )

      files = files(spec)
      bin_names = ~w(ruff python pytest)

      run = fn changed ->
        dir = sample_repo(files, @python_paths ++ ~w(tests/test_types.py))
        bin = stubs(dir, bin_names)
        for path <- changed, do: File.write!(Path.join(dir, path), "# changed\n")
        assert {{"", 0}, log} = stop(files, dir, bin)
        log |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "python "))
      end

      sources = ~w(src/samplepkg/core.py src/samplepkg/io.py src/samplepkg/types.py)

      # Changed sources alone run no test, however strong their pairs.
      assert run.(sources) == nil

      # Only the changed tests run beside changed sources.
      assert run.(sources ++ ~w(tests/test_zeta.py tests/test_new.py)) ==
               "python -m pytest -q tests/test_new.py tests/test_zeta.py"

      # More than 3 changed tests: the first 3 by name.
      assert run.(~w(tests/test_e.py tests/test_d.py tests/test_c.py tests/test_b.py)) ==
               "python -m pytest -q tests/test_b.py tests/test_c.py tests/test_d.py"

      # A changed test that is also a source's strongest pair runs, once.
      assert run.(~w(src/samplepkg/core.py tests/test_core.py)) ==
               "python -m pytest -q tests/test_core.py"
    end

    test "test-pairs.tsv is still written as data, and the Stop script never reads it" do
      files = files(fixture())
      assert files[@pairs] =~ "src/samplepkg/core.py\ttests/test_core.py\t12\n"
      refute files[@stop] =~ "test-pairs"

      dir = sample_repo(files)
      bin = stubs(dir, ~w(ruff python pytest))
      File.write!(Path.join(dir, "src/samplepkg/core.py"), "# changed\n")
      File.write!(Path.join(dir, "src/samplepkg/io.py"), "# changed\n")

      assert {{"", 0}, log} = stop(files, dir, bin)
      refute log =~ "pytest"
    end

    test "changed tests, new files and a changed .pyi are selected; data and conftest are not" do
      files = files(fixture())
      dir = sample_repo(files)
      bin = stubs(dir, ~w(ruff python pytest))
      File.write!(Path.join(dir, "tests/test_io.py"), "# changed\n")
      File.write!(Path.join(dir, "tests/conftest.py"), "# changed\n")
      File.write!(Path.join(dir, "tests/test_new.py"), "# new\n")
      File.write!(Path.join(dir, "src/samplepkg/core.pyi"), "# new stub\n")
      File.write!(Path.join(dir, "README.md"), "# changed\n")
      File.mkdir_p!(Path.join(dir, "tests/data"))
      File.write!(Path.join(dir, "tests/data/case.json"), "{}\n")

      assert {{"", 0}, log} = stop(files, dir, bin)

      lint_files =
        "src/samplepkg/core.pyi tests/conftest.py tests/test_io.py tests/test_new.py"

      assert log ==
               "ruff format #{lint_files}\n" <>
                 "ruff check #{lint_files}\n" <>
                 "python -m pytest -q tests/test_io.py tests/test_new.py\n"
    end

    test "a helper or typing sample in a tests directory is linted but never handed to pytest" do
      files = files(fixture())
      dir = sample_repo(files)
      bin = stubs(dir, ~w(ruff python pytest))
      File.mkdir_p!(Path.join(dir, "tests/typing"))
      # A type-checking sample (checked by a type checker, never collected by pytest):
      # passing it to pytest by name would import it as a test.
      File.write!(Path.join(dir, "tests/typing/typing_path.py"), "# new\n")
      File.write!(Path.join(dir, "tests/helpers.py"), "# new\n")
      File.write!(Path.join(dir, "tests/io_test.py"), "# new\n")

      assert {{"", 0}, log} = stop(files, dir, bin)

      lint_files = "tests/helpers.py tests/io_test.py tests/typing/typing_path.py"

      assert log ==
               "ruff format #{lint_files}\n" <>
                 "ruff check #{lint_files}\n" <>
                 "python -m pytest -q tests/io_test.py\n"
    end

    test "a changed source file runs no test, so an unrelated failing test cannot block" do
      files = files(fixture())
      dir = sample_repo(files)
      # The whole suite would fail here; nothing runs it.
      bin =
        stubs(dir, ~w(ruff python pytest), %{"python" => "echo 'FAILED tests/test_io.py'; exit 1"})

      File.write!(Path.join(dir, "src/samplepkg/extra.py"), "# changed\n")

      assert {{"", 0}, log} = stop(files, dir, bin)
      assert log == "ruff format src/samplepkg/extra.py\nruff check src/samplepkg/extra.py\n"
    end

    test "a failing changed test blocks once with at most 1200 characters and the fixed last line" do
      files = files(fixture())
      dir = sample_repo(files)
      noise = String.duplicate("E   assert 1 == 2 (synthetic failure line)\n", 120)

      bin =
        stubs(dir, ~w(ruff python pytest), %{
          "python" => "printf '%s' '#{noise}'; echo 'FAILED tests/test_core.py::test_x'; exit 1"
        })

      File.write!(Path.join(dir, "tests/test_core.py"), "# changed\n")

      assert {{output, 2}, _log} = stop(files, dir, bin)
      assert byte_size(output) <= 1200
      assert String.starts_with?(output, "Olivium: test failed: python -m pytest -q\n")
      assert String.ends_with?(output, "FAILED tests/test_core.py::test_x\n" <> @last <> "\n")
      assert @last == Hooks.last_line()

      # The retry is let through, and the same tree is not checked again.
      assert {"", 0} = sh_active(files, dir, bin)
      assert {{"", 0}, ""} = stop(files, dir, bin)
    end

    test "a lint failure stops before the tests and reports only itself" do
      files = files(fixture())
      dir = sample_repo(files)

      bin =
        stubs(dir, ~w(ruff python pytest), %{
          "ruff" =>
            ~s(case "$1" in check\) echo 'src/samplepkg/core.py:1:1: F401 unused'; exit 1 ;; esac)
        })

      File.write!(Path.join(dir, "src/samplepkg/core.py"), "# changed\n")

      assert {{output, 2}, log} = stop(files, dir, bin)

      assert output ==
               "Olivium: lint failed: ruff check\nsrc/samplepkg/core.py:1:1: F401 unused\n#{@last}\n"

      refute log =~ "pytest"
    end

    test "a tool that is not installed is named once per role and never blocks" do
      files = files(fixture())
      dir = sample_repo(files)
      bin = stubs(dir, ~w(python pytest))
      File.write!(Path.join(dir, "tests/test_core.py"), "# changed\n")

      assert {{output, 0}, log} = stop(files, dir, bin)

      assert output ==
               "Olivium: format not checked: ruff is not installed here.\n" <>
                 "Olivium: lint not checked: ruff is not installed here.\n"

      assert log == "python -m pytest -q tests/test_core.py\n"

      # python -m with the module missing is a missing tool too, not a test failure.
      dir = sample_repo(files)

      bin =
        stubs(dir, ~w(ruff python pytest), %{
          "python" => "echo '/usr/bin/python3: No module named pytest' >&2; exit 1"
        })

      File.write!(Path.join(dir, "tests/test_core.py"), "# changed\n")

      assert {{"Olivium: test not checked: pytest is not installed here.\n", 0}, _} =
               stop(files, dir, bin)
    end

    test "pytest collecting nothing is not a failure" do
      files = files(fixture())
      dir = sample_repo(files)
      bin = stubs(dir, ~w(ruff python pytest), %{"python" => "echo 'no tests ran'; exit 5"})
      File.write!(Path.join(dir, "tests/test_core.py"), "# changed\n")

      assert {{"", 0}, log} = stop(files, dir, bin)
      assert log =~ "python -m pytest -q tests/test_core.py\n"
    end

    test "tests that do not finish in their budget are named in one line and do not block" do
      files =
        fixture()
        |> put_spec(["hooks", Access.at(3), "timeout_seconds"], 1)
        |> files()

      dir = sample_repo(files)
      bin = stubs(dir, ~w(ruff python pytest), %{"python" => "sleep 8"})
      File.write!(Path.join(dir, "tests/test_core.py"), "# changed\n")

      started = System.monotonic_time(:millisecond)

      assert {{"Olivium: related tests did not finish in 1 s; not checked.\n", 0}, _} =
               stop(files, dir, bin)

      assert System.monotonic_time(:millisecond) - started < 7_000
    end

    test "file names never become shell text" do
      files = files(fixture())
      dir = sample_repo(files)
      bin = stubs(dir, ~w(ruff python pytest))

      for name <- [
            "src/samplepkg/$(touch PWNED).py",
            "src/$(touch${IFS}PWNED2).py",
            "src/a b.py",
            "-n.py"
          ] do
        File.write!(Path.join(dir, name), "x\n")
      end

      # A pairs file edited by hand is never read.
      File.write!(
        Path.join(dir, @pairs),
        "src/samplepkg/core.py\t../../outside_test.py\t9\nsrc/samplepkg/core.py\ttests/$(touch PWNED3).py\t9\nsrc/samplepkg/core.py\ttests/test_core.py\t12\n"
      )

      File.write!(Path.join(dir, "src/samplepkg/core.py"), "# changed\n")
      File.write!(Path.join(dir, "tests/test_core.py"), "# changed\n")

      assert {{output, 0}, log} = stop(files, dir, bin)

      assert output ==
               "Olivium: 4 changed files were not checked: their names use characters other than A-Z a-z 0-9 _ . / -\n"

      assert log ==
               "ruff format src/samplepkg/core.py tests/test_core.py\n" <>
                 "ruff check src/samplepkg/core.py tests/test_core.py\n" <>
                 "python -m pytest -q tests/test_core.py\n"

      for canary <- ~w(PWNED PWNED2 PWNED3) do
        refute File.exists?(Path.join(dir, canary))
        refute File.exists?(Path.join(dir, "src/" <> canary))
      end
    end

    test "a formatter's own changes do not make the next stop check again" do
      files = files(fixture())
      dir = sample_repo(files)

      bin =
        stubs(dir, ~w(ruff python pytest), %{
          "ruff" =>
            ~s(case "$1" in format\) shift; for f; do echo '# formatted' >>"$f"; done ;; esac)
        })

      File.write!(Path.join(dir, "src/samplepkg/core.py"), "# changed\n")
      File.write!(Path.join(dir, "tests/test_core.py"), "# changed\n")

      assert {{"", 0}, log} = stop(files, dir, bin)
      assert log =~ "python -m pytest -q tests/test_core.py\n"
      assert File.read!(Path.join(dir, "src/samplepkg/core.py")) == "# changed\n# formatted\n"
      assert {{"", 0}, ""} = stop(files, dir, bin)
    end

    test "what the tests leave behind does not count as a change at the next stop" do
      files = files(fixture())
      dir = sample_repo(files)

      # A test run that writes caches the project does not ignore, and fails.
      bin =
        stubs(dir, ~w(ruff python pytest), %{
          "python" =>
            "mkdir -p tests/__pycache__ .pytest_cache/v; echo x >tests/__pycache__/test_core.pyc; date >.pytest_cache/v/run; exit 1"
        })

      File.write!(Path.join(dir, "tests/test_core.py"), "# changed\n")

      assert {{output, 2}, _} = stop(files, dir, bin)
      assert String.ends_with?(output, @last <> "\n")
      assert File.exists?(Path.join(dir, ".pytest_cache/v/run"))

      # The next turn changes nothing: no checks run and nothing blocks.
      assert {{"", 0}, ""} = stop(files, dir, bin)

      # A real change is checked again.
      File.write!(Path.join(dir, "tests/test_core.py"), "# changed again\n")
      assert {{_, 2}, log} = stop(files, dir, bin)
      assert log =~ "python -m pytest -q tests/test_core.py\n"
    end

    test "the harness's own files are never formatted or linted" do
      files =
        fixture()
        |> put_spec(["project", "tools", Access.at(3), "extensions"], [
          ".json",
          ".md",
          ".py",
          ".sh"
        ])
        |> files()

      dir = sample_repo(files)
      bin = stubs(dir, ~w(ruff python pytest))
      File.write!(Path.join(dir, "src/samplepkg/core.py"), "# changed\n")

      assert {{"", 0}, log} = stop(files, dir, bin)
      assert log =~ "ruff format src/samplepkg/core.py\n"
      refute log =~ ".claude"
      refute log =~ ".olivium"
      refute log =~ "CLAUDE.md"
    end

    test "every script parses as POSIX sh and evaluates nothing" do
      for {path, script} <- files(fixture()), String.ends_with?(path, ".sh") do
        assert {_, 0} = System.cmd("sh", ["-n", "-c", script]), path
      end

      # No eval command anywhere (the word appears only in a comment).
      for path <- [@env, @stop] do
        refute files(fixture())[path] =~ ~r/(^|[;&|({]|then|do)\s*eval\s/m, path
      end

      refute Map.has_key?(files(fixture()), @format)
    end

    defp sh_active(files, dir, bin) do
      sh(files[@stop], dir, ~s({"stop_hook_active":true}), [
        {"PATH", bin <> ":/usr/bin:/bin"},
        {"STUB_LOG", Path.join(dir, ".stub-log")}
      ])
    end
  end

  describe "Stop hook, review 1 repairs" do
    # Whether a process still runs: kill -0 also succeeds for a zombie nobody reaped yet.
    defp running?(pid) do
      case System.cmd("ps", ["-o", "stat=", "-p", pid], stderr_to_stdout: true) do
        {stat, 0} -> not String.starts_with?(String.trim(stat), "Z")
        _ -> false
      end
    end

    # Issue 1: without GNU timeout (macOS has none; a stub that is not GNU stands in for
    # busybox here), the watcher must stop the test process the runner started, not
    # only the runner.
    test "a timed-out step stops the runner and every process it started" do
      files =
        fixture()
        |> put_spec(["hooks", Access.at(3), "timeout_seconds"], 1)
        |> files()

      dir = sample_repo(files)
      pid_file = Path.join(project_dir(), "child.pid")

      bin =
        stubs(dir, ~w(ruff python pytest timeout), %{
          "python" => ~s(sleep 30 & echo $! >"$CHILD_PID"; wait),
          "timeout" => "exit 125"
        })

      File.write!(Path.join(dir, "tests/test_core.py"), "# changed\n")
      started = System.monotonic_time(:millisecond)

      assert {{"Olivium: related tests did not finish in 1 s; not checked.\n", 0}, log} =
               stop(files, dir, bin, [{"CHILD_PID", pid_file}])

      assert System.monotonic_time(:millisecond) - started < 10_000
      # The script asked whether timeout is GNU's and then did not use it.
      assert log =~ "timeout --version\n"
      refute log =~ "timeout -k"

      child = pid_file |> File.read!() |> String.trim()
      assert child =~ ~r/\A\d+\z/
      Process.sleep(300)
      refute running?(child), "the runner's child #{child} outlived the Stop hook"
    end

    # Issue 2: the fingerprint reads no untracked file's content.
    test "an untracked link to /dev/zero does not hold the stop" do
      files = files(fixture())
      dir = sample_repo(files)
      bin = stubs(dir, ~w(ruff python pytest))
      link = "zero-#{System.unique_integer([:positive])}.bin"
      File.ln_s!("/dev/zero", Path.join(dir, link))
      File.write!(Path.join(dir, "tests/test_core.py"), "# changed\n")

      task = Task.async(fn -> stop(files, dir, bin) end)

      result =
        Task.yield(task, 20_000) ||
          (System.cmd("pkill", ["-f", link]) && Task.shutdown(task, :brutal_kill))

      assert {:ok, {{"", 0}, log}} = result
      assert log =~ "python -m pytest -q tests/test_core.py\n"
      # Unchanged, the next stop checks nothing.
      assert {{"", 0}, ""} = stop(files, dir, bin)
      refute files[@stop] =~ "xargs -0 cksum"
    end

    test "an untracked file changed in content is a change, even at the same size" do
      files = files(fixture())
      dir = sample_repo(files)
      bin = stubs(dir, ~w(ruff python pytest))
      File.write!(Path.join(dir, "tests/test_new.py"), "# new\n")

      assert {{"", 0}, log} = stop(files, dir, bin)
      assert log =~ "python -m pytest -q tests/test_new.py"
      assert {{"", 0}, ""} = stop(files, dir, bin)

      File.write!(Path.join(dir, "tests/test_new.py"), "# new, and longer\n")
      assert {{"", 0}, log} = stop(files, dir, bin)
      assert log =~ "python -m pytest -q tests/test_new.py"

      # Same size, same minute: only the content tells.
      File.write!(Path.join(dir, "tests/test_new.py"), "# new, and LONGER\n")
      assert {{"", 0}, log} = stop(files, dir, bin)
      assert log =~ "python -m pytest -q tests/test_new.py"
      assert {{"", 0}, ""} = stop(files, dir, bin)
    end

    # Issue 5: fixtures and helpers are not tests, and mocha's own spec list would turn
    # the narrow step into the whole suite.
    test "JavaScript fixtures and support files are never handed to mocha" do
      files = files(mocha_fixture())
      dir = sample_repo(files, @node_paths)
      bin = stubs(dir, ~w(npx mocha))

      for path <- ~w(test/fixtures/broken.js test/support/utils.js lib/request.js) do
        File.write!(Path.join(dir, path), "// changed\n")
      end

      # Neither a fixture nor a helper is a test, and lib/request.js's history pair
      # (test/req.query.js) is not run.
      assert {{"", 0}, ""} = stop(files, dir, bin)

      # A real test under test/ still runs, also beside a fixture.
      File.write!(Path.join(dir, "test/acceptance/auth.js"), "// changed\n")
      assert {{"", 0}, log} = stop(files, dir, bin)

      assert log == "npx mocha --require test/support/env test/acceptance/auth.js\n"
    end

    test "a mocha configuration that names spec files skips the test step with one line" do
      files = files(mocha_fixture())
      bin_names = ~w(npx mocha)

      for {path, text, expected} <- [
            {".mocharc.yml", "require: test/support/env\nspec: test/**/*.js\n",
             "Olivium: test not checked: .mocharc.yml names spec files, which mocha would run as well.\n"},
            {".mocharc.json", ~s({"spec": ["test/*.js"], "timeout": 2000}\n),
             "Olivium: test not checked: .mocharc.json names spec files, which mocha would run as well.\n"},
            {".mocharc.js", "module.exports = {\n  'spec': ['test/'],\n};\n",
             "Olivium: test not checked: .mocharc.js names spec files, which mocha would run as well.\n"},
            {"package.json", ~s({"name": "x", "mocha": {"spec": "test"}}\n),
             "Olivium: test not checked: package.json configures mocha, which may add spec files to every run.\n"}
          ] do
        dir = sample_repo(files, @node_paths)
        bin = stubs(dir, bin_names)
        File.write!(Path.join(dir, path), text)
        File.write!(Path.join(dir, "test/req.query.js"), "// changed\n")

        assert {{^expected, 0}, ""} = stop(files, dir, bin), path
      end

      # A configuration without a spec list, and mocha as a dependency only, still run.
      for {path, text} <- [
            {".mocharc.yml", "require: test/support/env\nreporter: spec\n"},
            {"package.json", ~s({"name": "x", "devDependencies": {"mocha": "^11.7.5"}}\n)}
          ] do
        dir = sample_repo(files, @node_paths)
        bin = stubs(dir, bin_names)
        File.write!(Path.join(dir, path), text)
        File.write!(Path.join(dir, "test/req.query.js"), "// changed\n")

        assert {{"", 0}, "npx mocha --require test/support/env test/req.query.js\n"} =
                 stop(files, dir, bin),
               path
      end

      refute files(fixture())[@stop] =~ "mocha_spec"
    end

    # Issue 7: a check never rewrites uv.lock after the agent's last turn; UV_FROZEN is
    # set only where uv accepts it (a lock file, no lock or sync setting of the session).
    test "uv steps keep uv.lock as it is unless the session says otherwise" do
      files = files(uv_fixture())
      record = ~s(echo "UV_FROZEN=${UV_FROZEN:-}" >>"$STUB_LOG")

      run = fn lock?, env ->
        dir = sample_repo(files)
        bin = stubs(dir, ~w(uv ruff pytest), %{"uv" => record})
        if lock?, do: File.write!(Path.join(dir, "uv.lock"), "version = 1\n")
        File.write!(Path.join(dir, "tests/test_core.py"), "# changed\n")
        assert {{"", 0}, log} = stop(files, dir, bin, env)
        log
      end

      frozen = run.(true, [])

      assert frozen ==
               "uv run ruff format tests/test_core.py\nUV_FROZEN=1\n" <>
                 "uv run ruff check tests/test_core.py\nUV_FROZEN=1\n" <>
                 "uv run pytest tests/test_core.py\nUV_FROZEN=1\n"

      # The session's own setting wins; UV_LOCKED would be refused together with it.
      for env <- [[{"UV_LOCKED", "1"}], [{"UV_NO_SYNC", "1"}]] do
        log = run.(true, env)
        assert log =~ "uv run pytest tests/test_core.py\nUV_FROZEN=\n"
        refute log =~ "UV_FROZEN=1", inspect(env)
      end

      refute run.(false, []) =~ "UV_FROZEN=1"

      # A command that pins the lock itself is left alone.
      locked =
        uv_fixture()
        |> update_in(
          ["spec", "project", "commands"],
          &Map.put(&1, "test", "uv run --locked pytest")
        )
        |> put_spec(["project", "tools", Access.at(0), "command"], "uv run --locked pytest")
        |> put_spec(["hooks", Access.at(3), "command"], "uv run --locked pytest")
        |> files()

      assert locked[@stop] =~ "  run 60 uv run --locked pytest $files\n"
      assert locked[@stop] =~ "  run 60 env $uv_frozen uv run ruff check $files\n"
      refute files(fixture())[@stop] =~ "uv_frozen"
    end
  end

  # Lane-x hooks (Hooks.lean_x/1) and the guard's npx rule: a package the project's own
  # package.json provides as a bin counts as installed. The guard runs here as Claude Code
  # runs it, through the settings command, on synthetic package.json files; it reads
  # package.json as data and runs nothing from it.
  describe "lean-x hooks and the guard's npx rule" do
    @x_guard ".claude/hooks/olivium-guard.sh"
    @mocha_deny "Olivium guard: this call would download mocha from the package registry. mocha is not installed here; continue without it. Do not install or download tools."

    defp guard_entry(files) do
      [entry] =
        Enum.filter(settings(files)["hooks"]["PreToolUse"], fn %{"hooks" => [hook]} ->
          hook["command"] =~ "olivium-guard.sh"
        end)

      entry
    end

    defp guard_hook(files, dir, command) do
      File.mkdir_p!(Path.join(dir, ".claude/hooks"))
      File.write!(Path.join(dir, @x_guard), files[@x_guard])
      %{"hooks" => [%{"command" => hook}]} = guard_entry(files)

      input =
        Jason.encode!(%{
          "cwd" => dir,
          "hook_event_name" => "PreToolUse",
          "tool_name" => "Bash",
          "tool_input" => %{"command" => command}
        })

      System.cmd("/bin/sh", ["-c", ~s(printf '%s' "$HOOK_INPUT" | /bin/sh -c "$HOOK_COMMAND")],
        env: [
          {"HOOK_INPUT", input},
          {"HOOK_COMMAND", hook},
          {"CLAUDE_PROJECT_DIR", dir},
          {"PATH", "/usr/bin:/bin"}
        ],
        stderr_to_stdout: true
      )
    end

    defp refusal({"", 0}), do: nil

    defp refusal({output, 0}) do
      %{
        "hookSpecificOutput" => %{
          "permissionDecision" => "deny",
          "permissionDecisionReason" => why
        }
      } =
        Jason.decode!(output)

      why
    end

    test "lean_x/1 puts the lean export's guard first, then the shaper" do
      spec = fixture()
      files = files(spec)
      shaper = HarnessForge.Adapters.ClaudeCode.Shaper
      assert {:ok, %{"settings_hooks" => hooks, "files" => x_files}} = Hooks.lean_x(spec["spec"])
      assert Hooks.lean_x(spec["spec"]) == {:ok, %{"settings_hooks" => hooks, "files" => x_files}}
      assert Map.keys(hooks) == ["PreToolUse"]

      assert hooks["PreToolUse"] == [
               guard_entry(files),
               %{
                 "matcher" => "Bash",
                 "hooks" => [
                   %{"type" => "command", "command" => shaper.command(), "timeout" => 10}
                 ]
               }
             ]

      assert x_files == [
               %{"path" => @x_guard, "content" => files[@x_guard], "mode" => 0o755},
               %{"path" => shaper.path(), "content" => shaper.script(), "mode" => 0o755}
             ]
    end

    test "lean_x/1 without a deny rule renders the shaper alone, and refuses a spec without permissions" do
      spec =
        fixture()["spec"]
        |> update_in(
          ["permissions", "commands"],
          &Enum.reject(&1, fn r -> r["action"] == "deny" end)
        )
        |> update_in(
          ["permissions", "paths"],
          &Enum.reject(&1, fn r -> r["action"] == "deny" end)
        )

      assert {:ok,
              %{
                "settings_hooks" => %{"PreToolUse" => [%{"matcher" => "Bash"}]},
                "files" => [shaper]
              }} =
               Hooks.lean_x(spec)

      assert shaper["path"] == ".claude/hooks/olivium-shape.sh"

      assert {:error, %{"code" => "invalid_runtime_intent", "message" => message}} =
               Hooks.lean_x(%{})

      assert message =~ "permissions"
    end

    test "npx, bunx and npm exec of a bin the project's package.json provides are allowed" do
      files = files(fixture())

      for {package, commands} <- [
            {~s({\n  "name": "x",\n  "bin": {\n    "mocha": "./bin/mocha.js",\n    "_mocha": "./bin/_mocha"\n  }\n}\n),
             [
               "npx mocha",
               "npx mocha test/a.spec.js --reporter dot",
               "bunx mocha",
               "npm exec -- mocha"
             ]},
            {~s({"name": "mocha", "version": "1.0.0", "bin": "./bin/mocha"}), ["npx mocha"]}
          ],
          command <- commands do
        dir = project_dir()
        File.write!(Path.join(dir, "package.json"), package)
        assert refusal(guard_hook(files, dir, command)) == nil, command
      end
    end

    test "without such a bin and without node_modules, npx mocha is refused as before" do
      files = files(fixture())
      link_target = ~s({"name": "x", "bin": {"mocha": "b"}})

      for {name, package} <- [
            {"no package.json", nil},
            {"no bin", ~s({"name": "x", "version": "1.0.0"})},
            {"string bin, other name", ~s({"name": "y", "bin": "./bin/mocha"})},
            {"other bin names", ~s({"name": "x", "bin": {"mochax": "a", "moch": "b"}})},
            {"bin nested deeper", ~s({"name": "x", "config": {"bin": {"mocha": "1"}}})},
            {"bin inside a string",
             ~s({"name": "x", "description": "\\"bin\\": {\\"mocha\\": 1}"})},
            {"not JSON", ~s({"name": "x", "bin": {"mocha")},
            {"a link", :link}
          ] do
        dir = project_dir()

        case package do
          nil ->
            :ok

          :link ->
            File.write!(Path.join(dir, "real.json"), link_target)
            File.ln_s!("real.json", Path.join(dir, "package.json"))

          text ->
            File.write!(Path.join(dir, "package.json"), text)
        end

        assert refusal(guard_hook(files, dir, "npx mocha")) == @mocha_deny, name
      end

      # The bin does not change what else is refused.
      dir = project_dir()
      File.write!(Path.join(dir, "package.json"), link_target)
      assert refusal(guard_hook(files, dir, "npx -y mocha")) =~ "downloads and runs mocha"
      assert refusal(guard_hook(files, dir, "npx cowsay hi")) =~ "would download cowsay"
      assert refusal(guard_hook(files, dir, "git push origin main")) =~ "git push"

      # An installed package is allowed as before.
      File.rm!(Path.join(dir, "package.json"))
      File.mkdir_p!(Path.join(dir, "node_modules/.bin"))
      File.write!(Path.join(dir, "node_modules/.bin/mocha"), "")
      assert refusal(guard_hook(files, dir, "npx mocha")) == nil
    end
  end
end
