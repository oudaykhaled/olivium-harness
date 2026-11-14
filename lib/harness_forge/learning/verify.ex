defmodule HarnessForge.Learning.Verify do
  @moduledoc """
  Docker verification of commands and rewrites (design.md section 3.3, step 4).

  Every run is a fresh container from the verification image with `--network none`,
  1800 MB, all capabilities dropped, and a 120 s limit per command. Nothing runs on the
  host. When the image already holds the repository at the base commit with a clean
  tree at `/work/repo` (the bench's deps images), that checkout is used as is; otherwise
  the repository is copied into `/work/olivium-repo` of each container.

  The container prints one result line per run (exit status, output bytes, a signature
  and a network flag); the command's output itself never leaves the container.

    * `test`, `test_file`: exit 0 at the base (`{file}` is a sample test file), and
      at least one test ran: output that reports zero tests (mocha `0 passing`, pytest
      `no tests ran`, `No test files found`, `No tests found`, `Ran 0 tests`) with no
      positive `N passing` or `N passed` count is `verify_failed`;
    * `lint`, `format` (check form), `typecheck`: exit 0 or 1 without a missing-tool
      signature (`{file}` is a sample source file);
    * the environment probe runs `<tool> --version` in the forms the analyzer names; a
      form that fails with a missing-tool signature becomes a deterministic
      `missing_tool` rewrite;
    * learned `missing_tool` and `wrong_runner`: the wrong form fails with a missing-tool
      signature, and (for `wrong_runner`) the right form exits 0, both with `--version`;
    * learned `quiet_flags`: same exit on the sample, and at most half the output bytes.

  Without Docker or the image, verification is `unavailable` and every candidate is
  dropped with `not_verified`. There is no host fallback.
  """

  alias HarnessForge.Learning.{Bundle, Launcher}

  @timeout_ms 120_000
  @probe_timeout_s 60
  @deterministic_rewrites 6
  @learned_commands 8
  @learned_rewrites 12
  @rewrite_limit 12

  @spec timeout_ms() :: pos_integer()
  def timeout_ms, do: @timeout_ms

  @doc """
  Verify candidates. `input` keys: `:ctx`, `:image`, `:extract`, `:commands` (candidates
  from the analyzer and the learner), `:rewrites` (learned candidates), `:tools`
  (`Bundle.named_tools/1`), `:runner` (optional, a function used by tests in place of
  Docker: `fn kind, payload -> result end`).
  """
  @spec run(map()) :: map()
  def run(input) do
    runner = Map.get(input, :runner) || (&docker_runner(input, &1, &2))

    case runner.(:availability, input.image) do
      {:ok, image_id} ->
        verified(input, runner, image_id)

      {:unavailable, reason} ->
        drops =
          Enum.map(input.commands, &drop("command", &1.key, "not_verified")) ++
            Enum.map(input.rewrites, &drop("rewrite", &1.key, "not_verified"))

        %{
          verification: verification(input.image, "unavailable", reason, ""),
          commands: [],
          rewrites: [],
          dropped: drops,
          report: %{"status" => "unavailable", "reason" => reason}
        }
    end
  end

  defp verification(image, status, reason, image_id) do
    %{
      "status" => status,
      "status_reason" => reason,
      "image" => image,
      "image_id" => image_id,
      "network" => "none",
      "timeout_ms" => @timeout_ms
    }
  end

  defp drop(kind, id, reason), do: %{"kind" => kind, "id" => id, "reason" => reason}

  defp verified(input, runner, image_id) do
    samples = Bundle.samples(input.extract)
    mode = runner.(:repo_mode, nil)

    {det_rewrites, probe_report} = probe_tools(input.tools, runner, mode)

    {commands, command_drops, command_report} = commands(input.commands, samples, runner, mode)

    {rewrites, rewrite_drops, rewrite_report} =
      rewrites(det_rewrites, input.rewrites, samples, runner, mode)

    %{
      verification: verification(input.image, "ok", "none", image_id),
      commands: commands,
      rewrites: rewrites,
      dropped: command_drops ++ rewrite_drops,
      report: %{
        "status" => "ok",
        "repo_mode" => Atom.to_string(mode),
        "samples" => %{"test" => samples.test, "source" => samples.source},
        "probe" => probe_report,
        "commands" => command_report,
        "rewrites" => rewrite_report
      }
    }
  end

  # Environment probe -----------------------------------------------------------------------

  defp probe_tools(tools, runner, mode) do
    forms =
      tools
      |> Enum.flat_map(fn {tool, prefix} ->
        if prefix == [], do: [{tool, [tool]}], else: [{tool, prefix ++ [tool]}, {tool, [tool]}]
      end)
      |> Enum.uniq_by(&elem(&1, 1))

    if forms == [] do
      {[], []}
    else
      results =
        runner.(:probe, %{mode: mode, forms: Enum.map(forms, &(elem(&1, 1) ++ ["--version"]))})

      report =
        forms
        |> Enum.zip(results)
        |> Enum.map(fn {{tool, form}, result} ->
          %{
            "tool" => tool,
            "form" => Enum.join(form, " "),
            "exit" => result.exit,
            "signature" => result.signature,
            "network" => result.network,
            "bytes" => result.bytes
          }
        end)

      missing =
        forms
        |> Enum.zip(results)
        |> Enum.filter(fn {_, result} -> missing?(result) end)
        |> Enum.take(@deterministic_rewrites)
        |> Enum.with_index(1)
        |> Enum.map(fn {{{tool, form}, result}, index} ->
          %{
            key: "rw-d#{index}",
            source: "deterministic",
            kind: "missing_tool",
            match: form,
            replace: {:message, tool},
            verify: %{
              wrong_exit: result.exit,
              wrong_signature: result.signature,
              right_exit: 0,
              ms: result.ms,
              bytes_before: result.bytes,
              bytes_after: byte_size(message(tool))
            }
          }
        end)

      {missing, report}
    end
  end

  @doc "The exact text the rewrite hook prints for a missing tool (contract section 2.4)."
  @spec message(String.t()) :: String.t()
  def message(tool), do: "olivium: #{tool} is not installed here (checked at export); skip it.\n"

  defp missing?(result) do
    result.exit not in [0, 124, -1] and result.network == 0 and
      result.signature in ["exit_127", "module_not_found", "spawn_failed"]
  end

  # Commands --------------------------------------------------------------------------------

  defp commands(candidates, samples, runner, mode) do
    {deterministic, learned} = Enum.split_with(candidates, &(&1.source == "deterministic"))
    {learned, over} = Enum.split(learned, @learned_commands)
    over_drops = Enum.map(over, &drop("command", &1.key, "over_limit"))

    {runs, drops, _seen} =
      Enum.reduce(deterministic ++ learned, {[], [], MapSet.new()}, fn candidate,
                                                                       {runs, drops, seen} ->
        cond do
          MapSet.member?(seen, candidate.argv) ->
            {runs, [drop("command", candidate.key, "duplicate") | drops], seen}

          true ->
            sample =
              if candidate.role in ~w(test test_file), do: samples.test, else: samples.source

            needs_file = "{file}" in candidate.argv

            if needs_file and sample == "" do
              {runs, [drop("command", candidate.key, "not_verified") | drops],
               MapSet.put(seen, candidate.argv)}
            else
              argv = Enum.map(candidate.argv, &if(&1 == "{file}", do: sample, else: &1))
              result = runner.(:run, %{mode: mode, argv: argv})
              sample_arg = if needs_file, do: sample, else: ""

              {[{candidate, result, sample_arg} | runs], drops, MapSet.put(seen, candidate.argv)}
            end
        end
      end)

    runs = Enum.reverse(runs)

    {passed, failed} =
      Enum.reduce(runs, {[], []}, fn {candidate, result, sample_arg}, {passed, failed} ->
        case command_outcome(candidate.role, result) do
          :ok ->
            command =
              Map.put(candidate, :verify, %{
                exit: result.exit,
                ms: result.ms,
                output_bytes: result.bytes,
                sample_arg: sample_arg
              })

            {[command | passed], failed}

          reason ->
            {passed, [drop("command", candidate.key, reason) | failed]}
        end
      end)

    # One command per role: the quietest verified one, deterministic first on a tie.
    {kept, dupes} =
      passed
      |> Enum.reverse()
      |> Enum.group_by(& &1.role)
      |> Enum.flat_map(fn {_role, group} ->
        [best | rest] =
          Enum.sort_by(group, &{&1.verify.output_bytes, &1.source != "deterministic", &1.key})

        [{:keep, best} | Enum.map(rest, &{:dupe, &1})]
      end)
      |> Enum.split_with(&(elem(&1, 0) == :keep))

    report =
      Enum.map(runs, fn {candidate, result, sample_arg} ->
        %{
          "id" => candidate.key,
          "source" => candidate.source,
          "role" => candidate.role,
          "argv" => Enum.join(candidate.argv, " "),
          "sample_arg" => sample_arg,
          "exit" => result.exit,
          "ms" => result.ms,
          "bytes" => result.bytes,
          "signature" => result.signature,
          "network" => result.network,
          "zero_tests" => Map.get(result, :zero_tests, 0)
        }
      end)

    {Enum.map(kept, &elem(&1, 1)),
     Enum.reverse(drops) ++
       Enum.reverse(failed) ++
       Enum.map(dupes, &drop("command", elem(&1, 1).key, "duplicate")) ++ over_drops, report}
  end

  defp command_outcome(role, result) do
    cond do
      result.exit in [124, -1] -> "verify_timeout"
      result.exit != 0 and result.network == 1 -> "network_required"
      result.signature != "none" and result.exit != 0 -> "tool_missing"
      role in ~w(test test_file) and result.exit == 0 and zero_tests?(result) -> "verify_failed"
      role in ~w(test test_file) and result.exit == 0 -> :ok
      role in ~w(test test_file) -> "verify_failed"
      result.exit in [0, 1] -> :ok
      true -> "verify_failed"
    end
  end

  defp zero_tests?(result), do: Map.get(result, :zero_tests, 0) == 1

  # Rewrites --------------------------------------------------------------------------------

  defp rewrites(deterministic, learned, samples, runner, mode) do
    {learned, over} = Enum.split(learned, @learned_rewrites)
    over_drops = Enum.map(over, &drop("rewrite", &1.key, "over_limit"))
    seen = MapSet.new(deterministic, & &1.match)

    {kept, drops, report, _seen} =
      Enum.reduce(learned, {[], [], [], seen}, fn candidate, {kept, drops, report, seen} ->
        if MapSet.member?(seen, candidate.match) do
          {kept, [drop("rewrite", candidate.key, "duplicate") | drops], report, seen}
        else
          {outcome, entry} = rewrite_outcome(candidate, samples, runner, mode)
          seen = MapSet.put(seen, candidate.match)

          case outcome do
            {:ok, verify} ->
              {[Map.put(candidate, :verify, verify) | kept], drops, [entry | report], seen}

            reason ->
              {kept, [drop("rewrite", candidate.key, reason) | drops], [entry | report], seen}
          end
        end
      end)

    all = deterministic ++ Enum.reverse(kept)
    {kept, extra} = Enum.split(all, @rewrite_limit)

    {kept,
     Enum.reverse(drops) ++ Enum.map(extra, &drop("rewrite", &1.key, "over_limit")) ++ over_drops,
     Enum.reverse(report)}
  end

  defp rewrite_outcome(
         %{kind: "missing_tool", match: match, replace: {:message, tool}} = c,
         _s,
         runner,
         mode
       ) do
    wrong = runner.(:run, %{mode: mode, argv: match ++ ["--version"]})

    outcome =
      cond do
        wrong.exit in [124, -1] ->
          "verify_timeout"

        wrong.network == 1 ->
          "network_required"

        missing?(wrong) ->
          {:ok,
           %{
             wrong_exit: wrong.exit,
             wrong_signature: wrong.signature,
             right_exit: 0,
             ms: wrong.ms,
             bytes_before: wrong.bytes,
             bytes_after: byte_size(message(tool))
           }}

        true ->
          "verify_failed"
      end

    {outcome, entry(c, wrong, nil)}
  end

  defp rewrite_outcome(
         %{kind: "wrong_runner", match: match, replace: {:argv, replace}} = c,
         _s,
         runner,
         mode
       ) do
    wrong = runner.(:run, %{mode: mode, argv: match ++ ["--version"]})

    if missing?(wrong) do
      right = runner.(:run, %{mode: mode, argv: replace ++ ["--version"]})

      outcome =
        cond do
          right.exit in [124, -1] ->
            "verify_timeout"

          right.exit != 0 and right.network == 1 ->
            "network_required"

          right.exit == 0 ->
            {:ok,
             %{
               wrong_exit: wrong.exit,
               wrong_signature: wrong.signature,
               right_exit: 0,
               ms: wrong.ms + right.ms,
               bytes_before: wrong.bytes,
               bytes_after: right.bytes
             }}

          right.signature != "none" ->
            "tool_missing"

          true ->
            "verify_failed"
        end

      {outcome, entry(c, wrong, right)}
    else
      reason =
        cond do
          wrong.exit in [124, -1] -> "verify_timeout"
          wrong.network == 1 -> "network_required"
          true -> "verify_failed"
        end

      {reason, entry(c, wrong, nil)}
    end
  end

  defp rewrite_outcome(
         %{kind: "quiet_flags", match: match, replace: {:argv, replace}} = c,
         samples,
         runner,
         mode
       ) do
    sample = if Bundle.test_like?(match), do: samples.test, else: samples.source

    if sample == "" do
      {"not_verified", entry(c, nil, nil)}
    else
      before = runner.(:run, %{mode: mode, argv: match ++ [sample]})
      after_ = runner.(:run, %{mode: mode, argv: replace ++ [sample]})

      outcome =
        cond do
          before.exit in [124, -1] or after_.exit in [124, -1] ->
            "verify_timeout"

          before.network == 1 or after_.network == 1 ->
            "network_required"

          before.signature != "none" or after_.signature != "none" ->
            "tool_missing"

          before.exit != after_.exit ->
            "verify_failed"

          after_.bytes * 2 > before.bytes ->
            "output_not_smaller"

          true ->
            {:ok,
             %{
               wrong_exit: before.exit,
               wrong_signature: "none",
               right_exit: after_.exit,
               ms: before.ms + after_.ms,
               bytes_before: before.bytes,
               bytes_after: after_.bytes
             }}
        end

      {outcome, entry(c, before, after_)}
    end
  end

  defp entry(candidate, first, second) do
    %{
      "id" => candidate.key,
      "kind" => candidate.kind,
      "match" => Enum.join(candidate.match, " "),
      "first" => result_map(first),
      "second" => result_map(second)
    }
  end

  defp result_map(nil), do: nil

  defp result_map(result) do
    %{
      "exit" => result.exit,
      "ms" => result.ms,
      "bytes" => result.bytes,
      "signature" => result.signature,
      "network" => result.network
    }
  end

  # Docker runner ---------------------------------------------------------------------------

  @signatures """
  sig=none
  if grep -q -E 'No module named|ModuleNotFoundError|Cannot find module|ERR_MODULE_NOT_FOUND' /tmp/olivium-out; then sig=module_not_found; fi
  if grep -q -E 'Failed to spawn|failed to spawn|spawn [^ ]+ ENOENT' /tmp/olivium-out; then sig=spawn_failed; fi
  if [ "$code" = 127 ]; then sig=exit_127; fi
  net=0
  if grep -q -i -E 'Temporary failure in name resolution|Could not resolve host|getaddrinfo|ENOTFOUND|EAI_AGAIN|Network is unreachable|Name or service not known|Failed to establish a new connection|Failed to fetch|failed to download' /tmp/olivium-out; then net=1; fi
  zero=0
  if grep -q -E '(^|[^0-9])0 passing|no tests ran|No test files found|No tests found|Ran 0 tests' /tmp/olivium-out && ! grep -q -E '(^|[^0-9])[1-9][0-9]* (passing|passed)' /tmp/olivium-out; then zero=1; fi
  bytes=$(wc -c < /tmp/olivium-out | tr -d ' ')
  """

  @doc false
  def docker_runner(input, :availability, image) do
    ctx = input.ctx

    with :ok <- Launcher.available(ctx) |> or_unavailable("no_docker"),
         {:ok, id} <- Launcher.image_id(ctx, image) |> found_or("image_missing") do
      Process.put({__MODULE__, :counter}, 0)
      {:ok, id}
    end
  end

  def docker_runner(input, :repo_mode, _) do
    base = input.extract.doc["repository"]["base_commit"]

    script = """
    cd /work/repo 2>/dev/null || { echo OLIVIUM_MODE none; exit 0; }
    head=$(git -c safe.directory='*' rev-parse HEAD 2>/dev/null)
    dirty=$(git -c safe.directory='*' status --porcelain --untracked-files=no 2>/dev/null | head -1)
    echo "OLIVIUM_MODE $head ${dirty:+dirty}"
    """

    case container(input, script, :image, @timeout_ms) do
      {:ok, output, _ms} ->
        if Regex.match?(~r/^OLIVIUM_MODE #{base} ?$/m, output), do: :image, else: :copy

      _ ->
        :copy
    end
  end

  def docker_runner(input, :probe, %{mode: mode, forms: forms}) do
    lines =
      forms
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {argv, index} ->
        """
        $T #{quote_argv(argv)} > /tmp/olivium-out 2>&1 < /dev/null
        code=$?
        #{@signatures}
        echo "OLIVIUM_RESULT #{index} $code $bytes $sig $net $zero"
        """
      end)

    script = """
    cd #{repo_dir(mode)} || exit 0
    T=""
    if command -v timeout >/dev/null 2>&1; then T="timeout -k 5 #{@probe_timeout_s}"; fi
    #{lines}
    """

    deadline = length(forms) * (@probe_timeout_s + 10) * 1000 + 60_000

    {outcome, ms} =
      case container(input, script, mode, deadline) do
        {:ok, output, ms} -> {parse_results(output), ms}
        {:timeout, ms} -> {%{}, ms}
        {:error, _} -> {%{}, 0}
      end

    per = if forms == [], do: 0, else: div(ms, length(forms))

    forms
    |> Enum.with_index(1)
    |> Enum.map(fn {_argv, index} ->
      Map.get(outcome, index, %{exit: -1, bytes: 0, signature: "none", network: 0})
      |> Map.put(:ms, per)
    end)
  end

  def docker_runner(input, :run, %{mode: mode, argv: argv}) do
    script = """
    cd #{repo_dir(mode)} || { echo "OLIVIUM_RESULT 1 98 0 none 0 0"; exit 0; }
    T=""
    if command -v timeout >/dev/null 2>&1; then T="timeout -k 5 #{div(@timeout_ms, 1000)}"; fi
    $T #{quote_argv(argv)} > /tmp/olivium-out 2>&1 < /dev/null
    code=$?
    #{@signatures}
    echo "OLIVIUM_RESULT 1 $code $bytes $sig $net $zero"
    """

    case container(input, script, mode, @timeout_ms + 30_000) do
      {:ok, output, ms} ->
        output
        |> parse_results()
        |> Map.get(1, %{exit: -1, bytes: 0, signature: "none", network: 0})
        |> Map.put(:ms, ms)

      {:timeout, ms} ->
        %{exit: 124, bytes: 0, signature: "none", network: 0, ms: ms}

      {:error, _} ->
        %{exit: -1, bytes: 0, signature: "none", network: 0, ms: 0}
    end
  end

  defp or_unavailable(:ok, _), do: :ok
  defp or_unavailable(_, reason), do: {:unavailable, reason}

  defp found_or({:ok, id}, _), do: {:ok, id}
  defp found_or(:missing, reason), do: {:unavailable, reason}

  defp repo_dir(:image), do: "/work/repo"
  defp repo_dir(_), do: "/work/olivium-repo"

  # argv words passed the charset rule (no quote, space or shell character); quoting
  # them anyway keeps the script inert if that rule ever changes.
  defp quote_argv(argv),
    do: Enum.map_join(argv, " ", &("'" <> String.replace(&1, "'", "") <> "'"))

  defp parse_results(output) do
    ~r/^OLIVIUM_RESULT (\d+) (-?\d+) (\d+) (exit_127|module_not_found|spawn_failed|none) ([01]) ([01])$/m
    |> Regex.scan(output, capture: :all_but_first)
    |> Map.new(fn [index, code, bytes, sig, net, zero] ->
      {String.to_integer(index),
       %{
         exit: String.to_integer(code),
         bytes: String.to_integer(bytes),
         signature: sig,
         network: String.to_integer(net),
         zero_tests: String.to_integer(zero)
       }}
    end)
  end

  defp container(input, script, mode, deadline_ms) do
    ctx = input.ctx
    n = Process.get({__MODULE__, :counter}, 0) + 1
    Process.put({__MODULE__, :counter}, n)
    repo = input.extract.doc["repository"]
    # A random token per container: a concurrent run on the same commit has its own names.
    token = 3 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

    name =
      "olivium-bench-verify-#{repo["name"]}-#{String.slice(repo["base_commit"], 0, 12)}-#{n}-#{token}"

    args = [
      "create",
      "--name",
      name,
      "--label",
      "olivium-bench=1",
      "--network",
      "none",
      "--cap-drop=ALL",
      "--security-opt=no-new-privileges",
      "--memory",
      "1800m",
      "--memory-swap",
      "1800m",
      "--cpus",
      "2",
      "--pids-limit",
      "512",
      "--env",
      "UV_NO_SYNC=1",
      "--entrypoint",
      "/bin/sh",
      input.image,
      "-c",
      script
    ]

    started = System.monotonic_time(:millisecond)
    Launcher.remove(ctx, [name])

    try do
      with {:ok, _} <- Launcher.docker(ctx, args, timeout_ms: 120_000),
           :ok <- copy_repo(ctx, input.extract.root, name, mode) do
        case Launcher.docker(ctx, ["start", "-a", name],
               timeout_ms: deadline_ms,
               max_bytes: 256 * 1024
             ) do
          {:ok, output} ->
            {:ok, output, System.monotonic_time(:millisecond) - started}

          {:error, {:exit, _status, output}} ->
            {:ok, output, System.monotonic_time(:millisecond) - started}

          {:error, :timeout} ->
            Launcher.docker(ctx, ["kill", name], timeout_ms: 60_000)
            {:timeout, System.monotonic_time(:millisecond) - started}

          {:error, reason} ->
            {:error, reason}
        end
      end
    after
      Launcher.remove(ctx, [name])
    end
  end

  defp copy_repo(_ctx, _root, _name, :image), do: :ok
  defp copy_repo(ctx, root, name, _), do: Launcher.copy_in(ctx, root, name, "/work/olivium-repo")
end
