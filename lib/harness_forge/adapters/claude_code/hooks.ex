defmodule HarnessForge.Adapters.ClaudeCode.Hooks do
  @moduledoc """
  Renders the Claude Code hook scripts of a `harnessforge.dev/v1alpha2` spec, their
  `settings.json` entries and the plain-text data files they read.

  - `session_start` with `builtin: env_check` becomes `#{".claude/hooks/olivium-env-check.sh"}`
    on `SessionStart`. It runs only `command -v` and `test -x` and prints one fixed line
    per declared tool role that does not resolve, nothing when all do. A role run through
    a runner that sets up the project's environment (`uv run`, `poetry run`, `npm`, `npx`,
    ...) is reported only once that environment exists: before, the check cannot tell
    whether setting it up would bring the tool, so it says nothing. The `interpreter`
    role (no command of its own) follows the project's Python runner. Claude Code 2.1.311
    adds SessionStart stdout to the first request in `-p` mode as well (measured; see
    the context profile section of `docs/claude-code-connector.md`). In a `lean-ai`
    export a tool with a verified `missing_tool` rewrite is not checked here: the
    rewrite hook answers an attempt to run it with the same news at no prefix cost,
    while a session-start line is re-read on every request.
  - `before_stop` entries become one `Stop` script. Entries with a `selector` format and
    lint the changed files and run the changed test files, at most 3, under a 60 s test
    budget. Tests that history pairs with a changed source file
    (`.olivium/test-pairs.tsv`, still written as data) are not run: on the v2 gold
    patches the single strongest pair added 2 to 30 s to a passing stop.
    The script prints nothing unless a check fails, then at most 1,200 characters ending
    with a fixed sentence, and exits 2 once. A tool that is not installed is named in one
    line and never blocks. Entries without a selector (hand-written specs) run their
    command as written under the same output rules.
  - `after_edit` (no longer generated) still renders the PostToolUse `Edit|Write`
    formatter for hand-written specs.
  - `lean_x/1` gives the `lean-x` profile its only hooks, both PreToolUse: the guard
    (`Guard`), then the Bash output shaper (`Shaper`). It renders no SessionStart,
    UserPromptSubmit, Stop or PostToolUse hook and no data file.

  Everything a script prints is a fixed template, names that passed a fixed character
  check, or the bounded output of a failing project command. No script evaluates file,
  prompt or tool text: file names from `git status` pass the contract's path rule
  (`[A-Za-z0-9_./-]`, at most 200 bytes, no leading `/` or `-`, no `..` or `//`) before
  they become arguments, and the commands are the spec's, which contain no shell
  metacharacters. Every project command runs under a time bound that stops the command
  and every process it started.
  """

  alias HarnessForge.Adapters.ClaudeCode
  alias HarnessForge.Adapters.ClaudeCode.{Guard, Shaper}
  alias HarnessForge.Contracts.Error

  # The guard's settings entry, as every other profile renders it (ClaudeCode).
  @guard_matcher "Bash|Read|Edit|Write|MultiEdit|NotebookEdit|Grep|Glob"
  @guard_timeout 10

  @env_script ".claude/hooks/olivium-env-check.sh"
  @stop_script ".claude/hooks/olivium-before-stop.sh"
  @format_script ".claude/hooks/olivium-format.sh"
  @test_pairs ".olivium/test-pairs.tsv"
  @cochange ".olivium/cochange.tsv"
  @max_hook_timeout 600
  # git status, the fingerprint and cleanup around the bounded steps.
  @stop_overhead 15
  # Grace between the TERM and the KILL a timed-out step gets.
  @kill_grace 5
  @test_budget 60
  @output_limit 1_200
  @max_changed_files 50
  # Changed test files only. Measured on the 8 v2 gold patches in Docker: every paired
  # test (up to 5 files per source) added 5 to 25 s to a passing session, the single
  # strongest pair still 2 to 30 s; changed tests alone stay under 3 s.
  @max_related_tests 3
  @last_line "If these failures are not caused by your change, stop again."

  @events ~w(after_edit before_stop session_start prompt_submit)
  @stop_roles %{"format" => 0, "lint" => 1, "test" => 2}
  @selectors %{"format" => "changed_files", "lint" => "changed_files", "test" => "related_tests"}
  @tool_roles %{"test" => 0, "lint" => 1, "typecheck" => 2, "format" => 3, "interpreter" => 4}
  @tool_labels %{
    "test" => "Testing",
    "lint" => "Linting",
    "typecheck" => "Type checking",
    "format" => "Formatting"
  }
  @tool_sources ~w(runner_prefix package_script manifest_tool requires_python)

  # The same patterns as the v1alpha2 schema and the stage 1 contract, checked again
  # here because every one of these strings is written into a shell script.
  @command_pattern ~r/\A[A-Za-z0-9_.\/][A-Za-z0-9_.\/:=@+,-]*( [A-Za-z0-9_.\/:=@+,-]+)*\z/
  @id_pattern ~r/\A[a-z][a-z0-9_-]{0,63}\z/
  @probe_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._+-]{0,63}\z/
  @extension_pattern ~r/\A\.[a-z0-9]{1,8}\z/
  @path_pattern ~r/\A[A-Za-z0-9_.\/-]{1,200}\z/

  # Code files, as `HarnessForge.Analyzers.Paths` counts them: what a format, lint or
  # test step is given when the spec names no extensions for its role.
  @code_extensions ~w(.c .cc .cjs .cpp .cs .erl .ex .exs .go .h .hpp .java .js .jsx .kt .lua .mjs .php .py .pyi .rb .rs .scala .sh .swift .ts .tsx)

  # Which files a formatter that takes a path can actually format.
  @formatter_extensions [
    {"mix format", ~w(ex exs heex)},
    {"prettier", ~w(js jsx mjs cjs ts tsx json css scss less html vue yaml yml md mdx)},
    {"ruff format", ~w(py pyi)},
    {"black", ~w(py pyi)},
    {"isort", ~w(py pyi)},
    {"gofmt", ~w(go)},
    {"rustfmt", ~w(rs)},
    {"biome format", ~w(js jsx ts tsx json jsonc css)},
    {"biome check", ~w(js jsx ts tsx json jsonc css)},
    {"shfmt", ~w(sh bash)},
    {"clang-format", ~w(c h cc cpp hpp)},
    {"dart format", ~w(dart)},
    {"stylua", ~w(lua)}
  ]

  # uv prints these when it cannot prepare the environment, before the tool starts.
  @uv_environment_failures [
    "Failed to download",
    "Failed to fetch",
    "dns error",
    "failed to lookup address",
    "error sending request",
    "Could not connect"
  ]

  @spec env_script_path() :: String.t()
  def env_script_path, do: @env_script
  @spec stop_script_path() :: String.t()
  def stop_script_path, do: @stop_script
  @spec format_script_path() :: String.t()
  def format_script_path, do: @format_script
  @spec test_pairs_path() :: String.t()
  def test_pairs_path, do: @test_pairs
  @spec cochange_path() :: String.t()
  def cochange_path, do: @cochange
  @spec last_line() :: String.t()
  def last_line, do: @last_line

  @doc """
  Checks every hook, tool, test-pair and co-change value that reaches a script or a
  data file. A value outside the contract is refused, never repaired or dropped.
  """
  @spec validate(map()) :: :ok | {:error, Error.t()}
  def validate(spec) do
    project = spec["project"] || %{}

    with :ok <- each(spec["hooks"] || [], &hook/1),
         :ok <- list(project["tools"], 5, "project.tools", &tool/1),
         :ok <- list(project["test_pairs"], 200, "project.test_pairs", &test_pair/1),
         :ok <- list(project["cochange"], 200, "project.cochange", &cochange/1) do
      :ok
    end
  end

  @doc "The `settings.json` hook entries, by Claude Code event."
  @spec events(map()) :: map()
  def events(spec) do
    hooks = spec["hooks"] || []

    %{}
    |> put_event(
      "SessionStart",
      by_event(hooks, "session_start"),
      @env_script,
      %{},
      &env_timeout/1
    )
    |> put_event("Stop", stop_hooks(hooks), @stop_script, %{}, &stop_timeout/1)
    |> put_event(
      "PostToolUse",
      by_event(hooks, "after_edit"),
      @format_script,
      %{"matcher" => "Edit|Write"},
      &sum_timeout/1
    )
  end

  @doc "The hook scripts, by exported path."
  @spec scripts(map()) :: map()
  def scripts(spec) do
    hooks = spec["hooks"] || []
    tools = tools_by_role(spec)

    %{}
    |> put_script(@env_script, by_event(hooks, "session_start"), fn _ -> env_script(spec) end)
    |> put_script(@stop_script, stop_hooks(hooks), &stop_script(&1, tools))
    |> put_script(@format_script, by_event(hooks, "after_edit"), &format_script/1)
  end

  @doc """
  `.olivium/test-pairs.tsv` and `.olivium/cochange.tsv`: one tab-separated row per spec
  row, in spec order, each line ending in a newline, no header. Both are written even
  when empty, so a reader never has to tell a missing file from an empty one. No
  generated hook reads them at present: the Stop script runs changed test files only.
  """
  @spec data_files(map()) :: map()
  def data_files(spec) do
    project = spec["project"] || %{}

    %{
      @test_pairs =>
        Enum.map_join(
          project["test_pairs"] || [],
          &"#{&1["source"]}\t#{&1["test"]}\t#{&1["support"]}\n"
        ),
      @cochange =>
        Enum.map_join(
          project["cochange"] || [],
          &"#{&1["path"]}\t#{&1["partner"]}\t#{&1["support"]}\t#{&1["percent"]}\n"
        )
    }
  end

  @doc """
  The settings command for a hook script. A missing file prints one line and exits 0
  instead of failing every event. The script runs with /bin/sh, not an `sh` found on
  the session's PATH, which a program the agent runs can write to; the script itself
  keeps that PATH, since it runs the project's tools.
  """
  @spec script_command(String.t()) :: String.t()
  def script_command(script) do
    ~s(f="$CLAUDE_PROJECT_DIR/#{script}"; if [ -f "$f" ]; then /bin/sh "$f"; else echo "Olivium: #{script} is missing; this hook did not run." >&2; fi)
  end

  @doc "What a hook asks for, as reported in the capability list."
  @spec requested(map()) :: String.t()
  def requested(%{"builtin" => builtin}), do: "builtin:" <> builtin
  def requested(hook), do: hook["command"]

  @doc """
  The `lean-x` hooks: the `settings.json` hook entries and the files they run.

  `PreToolUse` holds the guard entry first (the same matcher, command and timeout as
  every other profile renders), then the shaper entry (matcher `Bash`). Claude Code
  runs both on the call as the model sent it, and a guard refusal wins over the
  shaper's new input; the shaper never refuses. A spec that denies nothing has no
  guard, as in the other profiles, and gets the shaper alone. Both files are written
  with mode 0o755. All keys are strings.
  """
  @spec lean_x(map()) :: {:ok, map()} | {:error, map()}
  def lean_x(%{"permissions" => %{"commands" => commands, "paths" => paths}} = spec)
      when is_list(commands) and is_list(paths) do
    shaper_entry = %{
      "matcher" => "Bash",
      "hooks" => [
        %{
          "type" => "command",
          "command" => Shaper.command(),
          "timeout" => Shaper.timeout_seconds()
        }
      ]
    }

    shaper_file = %{"path" => Shaper.path(), "content" => Shaper.script(), "mode" => 0o755}

    {entries, files} =
      case Guard.render(spec) do
        nil ->
          {[shaper_entry], [shaper_file]}

        guard ->
          guard_entry = %{
            "matcher" => @guard_matcher,
            "hooks" => [
              %{
                "type" => "command",
                "command" => ClaudeCode.guard_command(guard),
                "timeout" => @guard_timeout
              }
            ]
          }

          {[guard_entry, shaper_entry],
           [%{"path" => Guard.path(), "content" => guard, "mode" => 0o755}, shaper_file]}
      end

    {:ok, %{"settings_hooks" => %{"PreToolUse" => entries}, "files" => files}}
  end

  def lean_x(_spec) do
    {:error,
     %{
       "code" => "invalid_runtime_intent",
       "message" => "The lean-x hooks need spec.permissions with commands and paths lists"
     }}
  end

  # -- validation -------------------------------------------------------------

  defp hook(%{"id" => id, "event" => event} = hook) when is_binary(id) and is_binary(event) do
    cond do
      not Regex.match?(@id_pattern, id) ->
        invalid("A hook id must be lowercase letters, digits, - or _")

      event not in @events ->
        invalid("Unknown hook event #{inspect(event)}")

      event == "prompt_submit" ->
        if hook["builtin"] == "locator" and timeout?(hook),
          do: :ok,
          else: invalid("A prompt_submit hook must be the builtin locator with a timeout")

      event == "session_start" ->
        if hook["builtin"] == "env_check" and timeout?(hook),
          do: :ok,
          else: invalid("A session_start hook must be the builtin env_check with a timeout")

      true ->
        command_hook(hook)
    end
  end

  defp hook(_), do: invalid("A hook needs an id and an event")

  defp command_hook(hook) do
    role = hook["role"]
    selector = hook["selector"]

    cond do
      not (is_binary(hook["command"]) and Regex.match?(@command_pattern, hook["command"])) ->
        invalid("Hook #{hook["id"]} needs a command without shell metacharacters")

      not timeout?(hook) ->
        invalid("Hook #{hook["id"]} needs a timeout of 1 to 600 seconds")

      hook["event"] == "after_edit" and (role != nil or selector != nil) ->
        invalid("An after_edit hook takes no role or selector")

      role != nil and not Map.has_key?(@stop_roles, role) ->
        invalid("A before_stop role must be format, lint or test")

      selector != nil and selector != @selectors[role] ->
        invalid(
          "Hook #{hook["id"]}: format and lint select changed_files, test selects related_tests"
        )

      Map.has_key?(hook, "file_argument") and not is_boolean(hook["file_argument"]) ->
        invalid("Hook #{hook["id"]}: file_argument must be true or false")

      true ->
        :ok
    end
  end

  defp timeout?(%{"timeout_seconds" => seconds}) when is_integer(seconds),
    do: seconds >= 1 and seconds <= @max_hook_timeout

  defp timeout?(_), do: false

  defp tool(%{"role" => role, "probe" => probe, "extensions" => extensions} = tool)
       when is_list(probe) and is_list(extensions) do
    cond do
      not Map.has_key?(@tool_roles, role) ->
        invalid("A project tool role must be test, lint, typecheck, format or interpreter")

      probe == [] or length(probe) > 3 or not Enum.all?(probe, &string_match?(@probe_pattern, &1)) ->
        invalid("A project tool needs 1 to 3 probe names of letters, digits, . _ + -")

      length(extensions) > 8 or not Enum.all?(extensions, &string_match?(@extension_pattern, &1)) ->
        invalid("A project tool takes at most 8 extensions such as .py")

      Map.has_key?(tool, "source") and tool["source"] not in @tool_sources ->
        invalid("Unknown project tool source #{inspect(tool["source"])}")

      not (is_nil(tool["command"]) or is_binary(tool["command"])) ->
        invalid("A project tool command must be a string or null")

      true ->
        :ok
    end
  end

  defp tool(_), do: invalid("A project tool needs a role, probe names and extensions")

  defp test_pair(%{"source" => source, "test" => test, "support" => support}) do
    if path?(source) and path?(test) and count?(support),
      do: :ok,
      else: invalid("A test pair needs two plain repository paths and an integer support")
  end

  defp test_pair(_), do: invalid("A test pair needs source, test and support")

  defp cochange(%{
         "path" => path,
         "partner" => partner,
         "support" => support,
         "percent" => percent
       }) do
    if path?(path) and path?(partner) and count?(support) and count?(percent) and percent <= 100,
      do: :ok,
      else: invalid("A co-change row needs two plain repository paths and integer counts")
  end

  defp cochange(_), do: invalid("A co-change row needs path, partner, support and percent")

  # The contract's path rule: a value that fails it is refused here, never repaired.
  defp path?(path) when is_binary(path) do
    Regex.match?(@path_pattern, path) and not String.starts_with?(path, ["/", "-"]) and
      not String.contains?(path, ["..", "//"])
  end

  defp path?(_), do: false

  defp count?(value), do: is_integer(value) and value >= 0

  defp string_match?(pattern, value), do: is_binary(value) and Regex.match?(pattern, value)

  defp list(nil, _max, _name, _check), do: :ok

  defp list(rows, max, name, check) when is_list(rows) do
    if length(rows) > max,
      do: invalid("#{name} holds at most #{max} rows"),
      else: each(rows, check)
  end

  defp list(_rows, _max, name, _check), do: invalid("#{name} must be a list")

  defp each(items, check) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case check.(item) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp invalid(message),
    do: {:error, %Error{code: "invalid_runtime_intent", message: message, details: []}}

  # -- settings ---------------------------------------------------------------

  defp by_event(hooks, event), do: Enum.filter(hooks, &(&1["event"] == event))

  # Role order format, lint, test; entries without a role keep their spec order after them.
  defp stop_hooks(hooks) do
    hooks
    |> by_event("before_stop")
    |> Enum.with_index()
    |> Enum.sort_by(fn {hook, index} -> {Map.get(@stop_roles, hook["role"], 3), index} end)
    |> Enum.map(&elem(&1, 0))
  end

  defp put_event(settings, _event, [], _script, _extra, _timeout), do: settings

  # Claude Code runs an event's hooks in parallel. One script per event keeps lint and
  # tests from racing for the build directory and gives the agent one failure at a time.
  # Exported files are not executable, so the command names the interpreter.
  defp put_event(settings, event, hooks, script, extra, timeout) do
    entry =
      Map.put(extra, "hooks", [
        %{"type" => "command", "command" => script_command(script), "timeout" => timeout.(hooks)}
      ])

    Map.put(settings, event, [entry])
  end

  defp env_timeout(hooks), do: hooks |> Enum.map(& &1["timeout_seconds"]) |> Enum.max()

  defp sum_timeout(hooks),
    do: hooks |> Enum.map(& &1["timeout_seconds"]) |> Enum.sum() |> min(@max_hook_timeout)

  # Longer than every bounded step together, so the script's own bounds fire first and
  # say what was not checked.
  defp stop_timeout(hooks) do
    hooks
    |> Enum.map(&(limit(&1) + @kill_grace))
    |> Enum.sum()
    |> Kernel.+(@stop_overhead)
    |> min(@max_hook_timeout)
  end

  defp limit(%{"selector" => "related_tests"} = hook),
    do: min(hook["timeout_seconds"], @test_budget)

  defp limit(hook), do: hook["timeout_seconds"]

  defp put_script(scripts, _path, [], _render), do: scripts
  defp put_script(scripts, path, hooks, render), do: Map.put(scripts, path, render.(hooks))

  defp tools_by_role(spec) do
    for tool <- get_in(spec, ["project", "tools"]) || [], into: %{}, do: {tool["role"], tool}
  end

  # -- SessionStart: environment facts ---------------------------------------

  @env_header ~S"""
  #!/bin/sh
  # Generated by Olivium Harness. Tells the agent at session start which of the
  # project's tools are not installed here, so it does not go looking for them or try
  # to install them. It only asks the shell whether a name resolves (command -v),
  # whether .venv/bin or node_modules/.bin holds an executable of that name (test -x)
  # and whether the project's environment directory exists (test -d); it runs nothing
  # else and reads no file. Silent when every tool resolves, and for a tool whose
  # runner first sets up an environment that does not exist yet: setting it up may
  # bring the tool, so the check cannot tell.
  d=${CLAUDE_PROJECT_DIR:-.}
  resolves() {
    for n in "$@"; do
      command -v "$n" >/dev/null 2>&1 && return 0
      [ -x "$d/.venv/bin/$n" ] && return 0
      [ -x "$d/node_modules/.bin/$n" ] && return 0
    done
    return 1
  }
  """

  # The environment a runner sets up before it starts the tool, by the program that
  # starts the role's command. A role run any other way is reported whenever its tool
  # does not resolve.
  @env_runners %{
    "uv" => "uv_env",
    "poetry" => "python_env",
    "pdm" => "python_env",
    "hatch" => "python_env",
    "pipenv" => "python_env",
    "npm" => "node_env",
    "npx" => "node_env",
    "pnpm" => "node_env",
    "yarn" => "node_env",
    "bun" => "node_env",
    "bunx" => "node_env"
  }
  @python_runners ~w(uv_env python_env)

  @env_functions [
    {"uv_env",
     ~S"""
     # uv run uses $UV_PROJECT_ENVIRONMENT, or .venv, and creates it when it is missing.
     uv_env() {
       e=${UV_PROJECT_ENVIRONMENT:-.venv}
       case $e in /*) ;; *) e=$d/$e ;; esac
       [ -d "$e" ]
     }
     """},
    {"python_env",
     ~S"""
     # poetry, pdm, hatch and pipenv run use an active virtualenv or .venv, or make one.
     python_env() { [ -d "$d/.venv" ] || [ -n "${VIRTUAL_ENV:-}" ]; }
     """},
    {"node_env",
     ~S"""
     # npm, npx, pnpm, yarn and bun need node_modules, which an install creates.
     node_env() { [ -d "$d/node_modules" ]; }
     """}
  ]

  defp env_script(spec) do
    tools =
      (get_in(spec, ["project", "tools"]) || [])
      |> Enum.with_index()
      |> Enum.sort_by(fn {tool, index} -> {Map.fetch!(@tool_roles, tool["role"]), index} end)
      |> Enum.take(5)
      |> Enum.map(&elem(&1, 0))
      |> Enum.reject(&(hd(&1["probe"]) in rewritten_missing_tools(spec)))

    # The interpreter entry has no command of its own: the project's Python runner (uv,
    # poetry, ...) provides it, and uv run fetches a missing Python when it sets up the
    # environment. So it is reported under the same condition as the tools that runner
    # starts, the first one in role order.
    python_runner =
      tools
      |> Enum.map(&env_runner(&1["command"]))
      |> Enum.find(&(&1 in @python_runners))

    tools =
      Enum.map(tools, fn tool ->
        runner =
          env_runner(tool["command"]) || if(tool["role"] == "interpreter", do: python_runner)

        {tool, runner}
      end)

    used = MapSet.new(tools, &elem(&1, 1))

    functions =
      for {name, text} <- @env_functions, MapSet.member?(used, name), into: "", do: text

    checks =
      Enum.map_join(tools, fn {tool, runner} ->
        [first | _] = tool["probe"]

        line =
          "#{tool_label(tool["role"], first)} is not available here: #{first} is not installed. Skip it. Do not install it."

        unset = if runner, do: "! #{runner} || ", else: ""
        "resolves #{words(tool["probe"])} || #{unset}printf '%s\\n' #{sq(line)}\n"
      end)

    @env_header <> functions <> checks <> "exit 0\n"
  end

  # Tools a lean-ai export's verified missing_tool rewrites already answer.
  defp rewritten_missing_tools(spec) do
    for %{"kind" => "missing_tool", "tool" => tool} when is_binary(tool) <-
          get_in(spec, ["rewrites", "items"]) || [],
        do: tool
  end

  defp env_runner(command) when is_binary(command) do
    {program, _run_words} = program(command)
    Map.get(@env_runners, program)
  end

  defp env_runner(_command), do: nil

  defp tool_label("interpreter", probe) do
    case Regex.run(~r/\Apython(\d+(?:\.\d+)*)\z/, probe) do
      [_, version] -> "Python " <> version
      nil -> "The interpreter " <> probe
    end
  end

  defp tool_label(role, _probe), do: Map.fetch!(@tool_labels, role)

  # -- Stop: quiet, narrow checks ---------------------------------------------

  # Exit 2 blocks the stop once. On the retry Claude Code sets stop_hook_active, and the
  # script lets it stop, so a check the agent cannot fix cannot loop. Whitespace is
  # removed from the JSON first; quotes inside its string values stay escaped, so
  # message text cannot fake the flag.
  @stop_prelude ~S"""
  #!/bin/sh
  # Generated by Olivium Harness. Before the agent stops, this formats and lints the
  # files it changed and runs the test files it changed, at most 3. It prints
  # nothing unless a check fails; then it blocks the stop once (exit 2) with at most
  # 1200 characters. A tool that is not installed is named in one line and never
  # blocks. File names come from git status and must pass a fixed character check;
  # no file, prompt or tool text is ever evaluated.
  input=$(cat)
  case $(printf '%s' "$input" | tr -d ' \t\r\n') in
    *'"stop_hook_active":true'*) exit 0 ;;
  esac
  cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0
  set -f
  export GIT_OPTIONAL_LOCKS=0
  last='If these failures are not caused by your change, stop again.'

  # Untracked files count by name, size and time, and by content only when they are
  # regular files under 1 MiB: reading every one would follow a link to /dev/zero for
  # ever, and read a large untracked tree at every stop. The ./ keeps a name that
  # starts with - from reading as an option of find.
  fingerprint() {
    {
      git status --porcelain 2>/dev/null
      git diff --no-ext-diff --no-textconv HEAD 2>/dev/null
      git ls-files -o --exclude-standard -z 2>/dev/null | xargs -0 -r ls -lnd -- 2>/dev/null
      git ls-files -o --exclude-standard -z 2>/dev/null |
        xargs -0 -r /bin/sh -c 'for f do set -- "$@" "./$f"; shift; done; find "$@" -prune -type f -size -2048 -exec cksum {} +' sh 2>/dev/null
    } | cksum
  }

  # A clean tree, or one unchanged since the last check, costs nothing: a turn that
  # changed nothing must not pay for the checks or be blocked by failures it did not
  # cause. The fingerprint lives in the git directory, so writing it does not dirty
  # the tree.
  state=
  if changes=$(git status --porcelain 2>/dev/null); then
    [ -n "$changes" ] || exit 0
    state=$(git rev-parse --git-path olivium-last-check 2>/dev/null)
    current=$(fingerprint)
    [ "$current" = "$(cat "$state" 2>/dev/null)" ] && exit 0
    [ -n "$state" ] && printf '%s\n' "$current" 2>/dev/null >"$state"
  fi

  save_state() {
    [ -n "$state" ] && fingerprint 2>/dev/null >"$state"
    return 0
  }

  tmp=$(mktemp -d 2>/dev/null) || {
    echo 'Olivium: checks not run: no temporary directory could be made.' >&2
    exit 0
  }
  out=$tmp/out
  trap 'rm -f "$tmp/out" "$tmp/changed" "$tmp/timed-out"; rmdir "$tmp" 2>/dev/null' EXIT
  trap 'exit 143' HUP INT TERM

  # Changed and new files whose names pass the character check, bytewise sorted. The
  # harness's own files and dependency directories are left out.
  git status --porcelain --untracked-files=all 2>/dev/null |
    sed -e 's/^...//' -e 's/^.* -> //' |
    awk '
      $0 == "" { next }
      length($0) > 200 || $0 !~ "^[A-Za-z0-9_./-]+$" || substr($0, 1, 1) == "-" || substr($0, 1, 1) == "/" || index($0, "..") || index($0, "//") { odd++; next }
      $0 == "CLAUDE.md" || $0 ~ "^[.](claude|olivium)/" || $0 ~ "(^|/)([.]git|[.]venv|venv|node_modules|[.]tox|[.]nox|__pycache__|site-packages)/" { next }
      { print }
      END { if (odd) printf "Olivium: %d changed files were not checked: their names use characters other than A-Z a-z 0-9 _ . / -\n", odd > "/dev/stderr" }
    ' | LC_ALL=C sort -u >"$tmp/changed"

  # Regular files only, not links.
  existing() {
    while IFS= read -r f; do
      if [ -f "$f" ] && [ ! -L "$f" ]; then printf '%s\n' "$f"; fi
    done
  }

  # The changed files that end in one of the extensions in $1.
  changed_with() {
    awk -v ext="$1" '
      BEGIN { n = split(ext, e, " ") }
      { for (i = 1; i <= n; i++) if (length($0) > length(e[i]) && substr($0, length($0) - length(e[i]) + 1) == e[i]) { print; next } }
    ' "$tmp/changed" | existing
  }

  # related_tests EXTENSIONS MAX: the first MAX changed test files ending in one of
  # EXTENSIONS, bytewise sorted. A test file is what the generator calls one. A Python
  # file runs only when pytest would collect it by name (test_*.py or *_test.py): a
  # helper or a type-checking sample in a tests directory is never handed to the
  # runner, which would import it as a test. Nor is a JavaScript or TypeScript file
  # under fixtures, support, helpers or __mocks__. Tests that history pairs with a
  # changed source file are not run: one paired module can take longer than the
  # whole session's other checks.
  related_tests() {
    awk -v ext="$1" '
      function is_test(p,    n, part, i, d, name) {
        n = split(p, part, "/"); name = part[n]
        for (i = 1; i < n; i++) { d = tolower(part[i]); if (d == "tests" || d == "test" || d == "__tests__" || d == "spec") return 1 }
        return name ~ /^test_.+[.]py$/ || name ~ /^.+_test[.](py|go|exs|rb)$/ || name == "conftest.py" || name ~ /^.+[.](test|spec)[.][a-z]+$/ || name ~ /^.+_spec[.]rb$/
      }
      function runnable(p,    n, part, name, k, m, e) {
        if (length(p) > 200 || p !~ "^[A-Za-z0-9_./-]+$" || substr(p, 1, 1) == "-" || substr(p, 1, 1) == "/" || index(p, "..") || index(p, "//")) return 0
        n = split(p, part, "/"); name = part[n]
        if (!is_test(p) || name == "conftest.py" || name == "__init__.py") return 0
        if (name ~ /[.]py$/ && name !~ /^test_.+[.]py$/ && name !~ /^.+_test[.]py$/) return 0
        if (name ~ "[.]([cm]?js|jsx|[cm]?ts|tsx)$" && p ~ "(^|/)(fixtures?|support|helpers?|__fixtures__|__mocks__)/") return 0
        m = split(ext, e, " ")
        for (k = 1; k <= m; k++) if (length(p) > length(e[k]) && substr(p, length(p) - length(e[k]) + 1) == e[k]) return 1
        return 0
      }
      runnable($0) { print }
    ' "$tmp/changed" | existing | head -n "$2"
  }

  # Whether a name resolves on PATH or in the project's .venv/bin or node_modules/.bin.
  resolves() {
    for n in "$@"; do
      command -v "$n" >/dev/null 2>&1 && return 0
      [ -x ".venv/bin/$n" ] && return 0
      [ -x "node_modules/.bin/$n" ] && return 0
    done
    return 1
  }

  # need ROLE PROGRAM [PROBE...]: whether the step can run; one line when it cannot.
  need() {
    role=$1
    program=$2
    shift 2
    if ! resolves "$program"; then
      printf 'Olivium: %s not checked: %s is not installed here.\n' "$role" "$program" >&2
      return 1
    fi
    if [ $# -gt 0 ] && ! resolves "$@"; then
      printf 'Olivium: %s not checked: %s is not installed here.\n' "$role" "$1" >&2
      return 1
    fi
    return 0
  }

  # GNU timeout stops the command's whole process group. Any other timeout (busybox,
  # or none at all, as on macOS) is not used: a watcher stops the command instead.
  gnu_timeout=
  case $(timeout --version 2>/dev/null | head -n 1) in
    *'GNU coreutils'*) gnu_timeout=1 ;;
  esac

  # children PID: the processes PID started.
  if command -v pgrep >/dev/null 2>&1; then
    children() { pgrep -P "$1" 2>/dev/null; }
  else
    children() { ps -A -o pid= -o ppid= 2>/dev/null | awk -v p="$1" '$2 == p { print $1 }'; }
  fi

  # tree PID: PID and every process it started, children first. The runner (uv, npx,
  # python) is rarely the process that runs the tests.
  tree() {
    for c in $(children "$1"); do tree "$c"; done
    printf '%s\n' "$1"
  }

  # alive PID...: whether any of them still runs.
  alive() {
    for p in "$@"; do kill -0 "$p" 2>/dev/null && return 0; done
    return 1
  }

  # run SECONDS COMMAND...: runs the command with no input, its output in $out and its
  # exit status in $status, 124 when it did not finish in time. When time is up, the
  # command and everything it started get TERM, and KILL 5 s later, so no test process
  # outlives the hook.
  run() {
    limit=$1
    shift
    rm -f "$tmp/timed-out"
    if [ -n "$gnu_timeout" ]; then
      timeout -k 5 "$limit" "$@" >"$out" 2>&1 </dev/null
      status=$?
      [ "$status" -eq 137 ] && status=124
      return 0
    fi
    "$@" >"$out" 2>&1 </dev/null &
    pid=$!
    (
      n=0
      while [ "$n" -lt "$limit" ]; do
        sleep 1
        kill -0 "$pid" 2>/dev/null || exit 0
        n=$((n + 1))
      done
      : >"$tmp/timed-out"
      pids=$(tree "$pid")
      kill -TERM $pids 2>/dev/null
      n=0
      while [ "$n" -lt 5 ] && alive $pids; do
        sleep 1
        n=$((n + 1))
      done
      kill -KILL $pids 2>/dev/null
    ) >/dev/null 2>&1 &
    watch=$!
    # dash reports a job a signal stopped ("Terminated") on wait's stderr.
    wait "$pid" 2>/dev/null
    status=$?
    if [ -f "$tmp/timed-out" ]; then
      status=124
      wait "$watch" 2>/dev/null
    else
      kill "$watch" 2>/dev/null
      wait "$watch" 2>/dev/null
    fi
    return 0
  }

  # At most 1200 characters on stderr, ending with the fixed sentence; blocks once.
  # The tree is fingerprinted again first, so what the checks themselves leave behind
  # (__pycache__, .pytest_cache) does not count as a change at the next stop.
  fail() {
    save_state
    head="Olivium: $1 failed: $2"
    room=$((1200 - ${#head} - ${#last} - 3))
    body=$(tail -n 40 "$out" | tail -c "$room")
    if [ -n "$body" ]; then
      printf '%s\n%s\n%s\n' "$head" "$body" "$last" >&2
    else
      printf '%s\n%s\n' "$head" "$last" >&2
    fi
    exit 2
  }

  # verdict ROLE COMMAND SECONDS [PROBE...]: what the step's exit status means. A tool
  # that is missing, a step that ran out of time and an environment uv could not
  # prepare are each named in one line and do not block. Only a real failure blocks.
  verdict() {
    role=$1
    shown=$2
    seconds=$3
    shift 3
    [ "$status" -eq 0 ] && return 0
    if [ "$status" -eq 124 ]; then
      if [ "$role" = test ]; then
        printf 'Olivium: related tests did not finish in %s s; not checked.\n' "$seconds" >&2
      else
        printf 'Olivium: %s did not finish in %s s; not checked.\n' "$role" "$seconds" >&2
      fi
      return 0
    fi
    if [ "$status" -eq 126 ] || [ "$status" -eq 127 ]; then
      printf 'Olivium: %s not checked: %s is not installed here.\n' "$role" "$program" >&2
      return 0
    fi
    for n in "$@"; do
      if head -n 5 "$out" | awk -v s=": No module named $n" '{ if (length($0) >= length(s) && substr($0, length($0) - length(s) + 1) == s) f = 1 } END { exit !f }'; then
        printf 'Olivium: %s not checked: %s is not installed here.\n' "$role" "$n" >&2
        return 0
      fi
    done
  """

  @stop_verdict_end ~S"""
    case " $shown " in
      *' pytest '*|*' py.test '*) [ "$status" -eq 5 ] && return 0 ;;
    esac
    if [ "$role" = test ] && [ "$status" -eq 1 ] && grep -q -F -e 'No tests found' -e 'No test files found' "$out"; then
      return 0
    fi
    fail "$role" "$shown"
  }

  """

  # mocha adds the spec files its own configuration names to the files it is given, so
  # with such a configuration a narrow test step would run the whole suite.
  @mocha_spec ~S"""
  # mocha_spec: whether mocha's own configuration names spec files, which mocha would
  # run along with the related tests. Said in one line; the step is then not run.
  mocha_spec() {
    for f in .mocharc.js .mocharc.cjs .mocharc.mjs .mocharc.yaml .mocharc.yml .mocharc.json .mocharc.jsonc; do
      if [ -f "$f" ] && grep -E -q '(^|[^A-Za-z0-9_$-])spec[^A-Za-z0-9_$-]?[[:space:]]*:' "$f"; then
        printf 'Olivium: test not checked: %s names spec files, which mocha would run as well.\n' "$f" >&2
        return 0
      fi
    done
    if [ -f package.json ] && grep -E -q '"mocha"[[:space:]]*:[[:space:]]*[{]' package.json; then
      echo 'Olivium: test not checked: package.json configures mocha, which may add spec files to every run.' >&2
      return 0
    fi
    return 1
  }

  """

  # `uv run` syncs the environment first and can rewrite a stale uv.lock after the
  # agent's last turn. UV_FROZEN keeps the lock as it is; it is set only when there is a
  # uv.lock and the session sets no uv lock or sync option of its own, since UV_LOCKED
  # or a `--locked` is refused together with it (measured on uv 0.11.3).
  @uv_frozen ~S"""
  # uv run syncs the environment first; with a uv.lock, the checks keep it as it is.
  uv_frozen=
  if [ -f uv.lock ] && [ -z "${UV_FROZEN:-}${UV_LOCKED:-}${UV_NO_SYNC:-}" ]; then
    uv_frozen=UV_FROZEN=1
  fi

  """

  defp stop_script(hooks, tools) do
    uv_failures = Enum.map_join(@uv_environment_failures, "|", &"*'#{&1}'*")

    uv =
      "  case $shown in\n" <>
        "    'uv '*)\n" <>
        "      case $(head -n 12 \"$out\") in\n" <>
        "        #{uv_failures})\n" <>
        "          printf 'Olivium: %s not checked: uv could not prepare the environment here.\\n' \"$role\" >&2\n" <>
        "          return 0\n" <>
        "          ;;\n" <>
        "      esac\n" <>
        "      ;;\n" <>
        "  esac\n"

    {formats, others} = Enum.split_with(hooks, &(&1["role"] == "format"))

    after_format = if formats == [], do: "", else: "save_state\n"
    mocha = if Enum.any?(hooks, &mocha_step?/1), do: @mocha_spec, else: ""
    uv_frozen = if Enum.any?(hooks, &frozen_step?(&1["command"])), do: @uv_frozen, else: ""

    @stop_prelude <>
      uv <>
      @stop_verdict_end <>
      mocha <>
      uv_frozen <>
      Enum.map_join(formats, &stop_step(&1, tools)) <>
      after_format <> Enum.map_join(others, &stop_step(&1, tools)) <> "save_state\nexit 0\n"
  end

  # A related-tests step that runs mocha.
  defp mocha_step?(hook),
    do: hook["selector"] == "related_tests" and "mocha" in String.split(hook["command"], " ")

  # A `uv run` step that sets no lock or sync option of its own.
  defp frozen_step?(command) do
    words = String.split(command, " ")
    {program, _run_words} = program(command)

    program == "uv" and Enum.at(Enum.drop_while(words, &(&1 != "uv")), 1) == "run" and
      not Enum.any?(words, &(&1 in ~w(--locked --frozen --no-sync)))
  end

  defp stop_step(hook, tools) do
    label = hook["role"] || hook["id"]
    command = hook["command"]
    {program, run_words} = program(command)
    run_words = if frozen_step?(command), do: "env $uv_frozen " <> command, else: run_words
    tool = tools[hook["role"]]
    probes = if tool, do: tool["probe"], else: []
    probe_args = Enum.map_join(probes, &(" " <> sq(&1)))
    seconds = limit(hook)
    shown = String.slice(command, 0, 200)

    {select, condition, arguments} =
      case hook["selector"] do
        nil ->
          {"", "", ""}

        selector ->
          extensions = sq(Enum.join(extensions(hook, tool), " "))

          select =
            case selector do
              "changed_files" ->
                "files=$(changed_with #{extensions} | head -n #{@max_changed_files})\n"

              "related_tests" ->
                "files=$(related_tests #{extensions} #{@max_related_tests})\n"
            end

          arguments = if hook["file_argument"] == false, do: "", else: " $files"
          mocha = if mocha_step?(hook), do: "! mocha_spec && ", else: ""
          {select, ~s([ -n "$files" ] && #{mocha}), arguments}
      end

    "# #{label}: #{command}\n" <>
      select <>
      "if #{condition}need #{sq(label)} #{sq(program)}#{probe_args}; then\n" <>
      "  run #{seconds} #{run_words}#{arguments}\n" <>
      "  verdict #{sq(label)} #{sq(shown)} #{seconds}#{probe_args}\n" <>
      "fi\n"
  end

  # The program a command starts, past leading NAME=value assignments, which `env`
  # applies when the step runs.
  defp program(command) do
    words = String.split(command, " ")

    {assignments, rest} =
      Enum.split_while(words, &Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*=/, &1))

    case {assignments, rest} do
      {[], [program | _]} -> {program, command}
      {_, [program | _]} -> {program, "env " <> command}
      {_, []} -> {"env", "env " <> command}
    end
  end

  defp extensions(hook, tool) do
    case tool && tool["extensions"] do
      [_ | _] = extensions ->
        extensions

      _ ->
        if hook["role"] == "format",
          do: formatter_extensions(hook["command"], @code_extensions),
          else: @code_extensions
    end
  end

  defp formatter_extensions(command, default) do
    padded = " " <> command <> " "

    Enum.find_value(@formatter_extensions, default, fn {formatter, extensions} ->
      if String.contains?(padded, " " <> formatter <> " "), do: Enum.map(extensions, &("." <> &1))
    end)
  end

  # -- PostToolUse Edit|Write formatter (hand-written specs only) --------------

  # The path comes from the hook's JSON input and is only ever a single quoted
  # argument. A path with JSON escapes does not match and is skipped.
  defp format_script(hooks) do
    runs =
      Enum.map_join(hooks, "", fn hook ->
        format_run(hook, formatter_extensions(hook["command"], []))
      end)

    """
    #!/bin/sh
    # Generated by Olivium Harness. Formats the edited file and never blocks the agent.
    [ -n "$CLAUDE_PROJECT_DIR" ] || exit 0
    file=$(sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\\([^"\\\\]*\\)".*/\\1/p' | head -n 1)
    case "$file" in
      */../*) exit 0 ;;
      "$CLAUDE_PROJECT_DIR"/*) ;;
      *) exit 0 ;;
    esac
    cd "$CLAUDE_PROJECT_DIR" || exit 0
    #{runs}exit 0
    """
  end

  defp format_run(%{"file_argument" => true} = hook, extensions) when extensions != [] do
    patterns = Enum.map_join(extensions, "|", &"*#{&1}")
    ~s(case "$file" in\n  #{patterns}\) #{hook["command"]} "$file" >/dev/null 2>&1 ;;\nesac\n)
  end

  defp format_run(%{"file_argument" => true} = hook, _extensions),
    do: ~s(#{hook["command"]} "$file" >/dev/null 2>&1\n)

  defp format_run(hook, _extensions), do: "#{hook["command"]} >/dev/null 2>&1\n"

  # -- shell text ---------------------------------------------------------------

  # Only strings that passed a pattern without a single quote reach this.
  defp sq(text), do: "'" <> text <> "'"
  defp words(list), do: Enum.map_join(list, " ", &sq/1)

  @doc false
  def output_limit, do: @output_limit
end
