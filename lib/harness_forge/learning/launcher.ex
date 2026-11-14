defmodule HarnessForge.Learning.Launcher do
  @moduledoc """
  Runs the AI learner: Claude Code (headless, stream-json) in a learner container whose
  only network peer is a metering proxy. Also the Docker plumbing that verification uses.

  Two meter arrangements (contract-v4.md section 2.2):

    * `{:image, tag}`: this module starts `olivium-bench-meter-v4learn-<id>` from `tag` on
      a new internal network `olivium-bench-learn-net-<id>` (no host gateway), with
      `--run-cap-usd` and `--total-cap-usd` set to the cap and `--total-reserve-usd` set to
      a tenth of it (the meter's own live default, $1.00 per in-flight request, is above any
      learning cap and would refuse every request). In live mode the key file is
      bind-mounted read-only into the meter only, and the meter alone joins an egress
      network. This module never opens the key file.
    * `{:url, url, network}`: the bench runner's meter on the runner's network. The runner
      applies the caps and keeps the meter rows; usage is read from Claude Code's own
      result event.

  The learner container gets the repository at `/work/repo` (only its tracked files and
  `.git`: untracked and ignored files such as `.env` or `node_modules` are left out,
  because the model can read what it is given and send it to the API), the extract,
  its text views,
  the fixed prompt and the learner settings at `/work/in`, and writes
  `/work/out/learned.raw.json`. Its output is copied back through `docker cp ... -` (a tar
  stream read into memory with a size cap), so nothing the model wrote lands on the host
  as a file. Mock mode appends the scripted plan to the prompt; the meter replays it and
  no key exists anywhere.

  The status is `unavailable` when nothing could start (`no_docker`, `image_missing`,
  `meter_unavailable`) and `failed` when the session ran but its output is discarded
  (`cap_reached`, `turn_cap`, `timeout`, `model_error`, `invalid_output`).
  """

  alias HarnessForge.Analyzers.Git
  alias HarnessForge.Contracts

  @agent_uid 1001
  @dummy_key "olivium-learner-dummy-key"
  @meter_ready_ms 60_000
  @output_limit 1024 * 1024
  @raw_limit 256 * 1024
  @transcript_limit 16 * 1024 * 1024
  @meter_log_limit 32 * 1024 * 1024
  @name ~r/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\z/
  @image ~r/\A[A-Za-z0-9][A-Za-z0-9._\/:@-]{0,199}\z/

  @type ctx :: %{docker: String.t() | nil, env: [{String.t(), String.t()}]}

  # Docker plumbing ------------------------------------------------------------------------

  @doc "A Docker context: the CLI path and extra environment (for example DOCKER_HOST)."
  @spec context(keyword()) :: ctx()
  def context(opts \\ []) do
    %{docker: Keyword.get(opts, :docker, System.find_executable("docker")), env: opts[:env] || []}
  end

  @doc "`:ok` when the Docker daemon answers, else `{:error, \"no_docker\"}`."
  @spec available(ctx()) :: :ok | {:error, String.t()}
  def available(ctx) do
    case docker(ctx, ["version", "--format", "{{.Server.Version}}"], timeout_ms: 20_000) do
      {:ok, output} -> if String.trim(output) != "", do: :ok, else: {:error, "no_docker"}
      _ -> {:error, "no_docker"}
    end
  end

  @doc "The image id (`sha256:...`) of a local image, or `:missing`."
  @spec image_id(ctx(), String.t()) :: {:ok, String.t()} | :missing
  def image_id(ctx, image) do
    with true <- valid_image?(image),
         {:ok, output} <-
           docker(ctx, ["image", "inspect", "--format", "{{.Id}}", image], timeout_ms: 30_000),
         id = String.trim(output),
         true <- Regex.match?(~r/\Asha256:[0-9a-f]{64}\z/, id) do
      {:ok, id}
    else
      _ -> :missing
    end
  end

  @doc "A label of a local image, or `\"\"`."
  @spec image_label(ctx(), String.t(), String.t()) :: String.t()
  def image_label(ctx, image, label) do
    format = "{{index .Config.Labels \"#{label}\"}}"

    case docker(ctx, ["image", "inspect", "--format", format, image], timeout_ms: 30_000) do
      {:ok, output} ->
        value = String.trim(output)
        if Regex.match?(~r/\A[0-9A-Za-z.+-]{1,40}\z/, value), do: value, else: ""

      _ ->
        ""
    end
  end

  @spec valid_image?(term()) :: boolean()
  def valid_image?(image), do: is_binary(image) and Regex.match?(@image, image)

  @spec valid_name?(term()) :: boolean()
  def valid_name?(name), do: is_binary(name) and Regex.match?(@name, name)

  @doc """
  Run the docker CLI (no shell) with a deadline and an output cap (stdout and stderr
  together). Returns `{:ok, output}`, `{:error, {:exit, status, output}}`,
  `{:error, :timeout}`, `{:error, :output_limit}` or `{:error, :no_docker}`.
  """
  @spec docker(ctx(), [String.t()], keyword()) :: {:ok, binary()} | {:error, term()}
  def docker(%{docker: nil}, _args, _opts), do: {:error, :no_docker}

  def docker(%{docker: executable, env: env}, args, opts) do
    deadline = now() + Keyword.get(opts, :timeout_ms, 60_000)
    limit = Keyword.get(opts, :max_bytes, @output_limit)

    port_opts = [
      :binary,
      :exit_status,
      :hide,
      :stderr_to_stdout,
      {:args, args},
      {:env, Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)}
    ]

    try do
      {:spawn_executable, String.to_charlist(executable)}
      |> Port.open(port_opts)
      |> collect([], 0, limit, deadline)
    rescue
      _ in [ErlangError, ArgumentError] -> {:error, :no_docker}
    end
  end

  defp collect(port, acc, size, limit, deadline) do
    receive do
      {^port, {:data, data}} ->
        size = size + byte_size(data)

        if size > limit do
          stop(port)
          {:error, :output_limit}
        else
          collect(port, [acc, data], size, limit, deadline)
        end

      {^port, {:exit_status, 0}} ->
        {:ok, IO.iodata_to_binary(acc)}

      {^port, {:exit_status, status}} ->
        {:error, {:exit, status, IO.iodata_to_binary(acc)}}
    after
      max(deadline - now(), 0) ->
        stop(port)
        {:error, :timeout}
    end
  end

  defp stop(port) do
    with {:os_pid, pid} <- Port.info(port, :os_pid),
         kill when is_binary(kill) <- System.find_executable("kill") do
      System.cmd(kill, ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
    end

    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    flush(port)
  end

  defp flush(port) do
    receive do
      {^port, _} -> flush(port)
    after
      0 -> :ok
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  @doc "Remove containers by exact name; missing ones are fine."
  @spec remove(ctx(), [String.t()]) :: :ok
  def remove(ctx, names) do
    names = Enum.filter(names, &valid_name?/1)
    if names != [], do: docker(ctx, ["rm", "-f" | names], timeout_ms: 60_000)
    :ok
  end

  @doc "Copy a host directory's contents into a created container (`docker cp DIR/. NAME:DEST`)."
  @spec copy_in(ctx(), String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def copy_in(ctx, source_dir, name, dest) do
    case docker(ctx, ["cp", Path.join(source_dir, "."), "#{name}:#{dest}"], timeout_ms: 600_000) do
      {:ok, _} -> :ok
      failure -> failure
    end
  end

  @doc """
  Copy one file out of a container as a tar stream into memory, capped at `limit` bytes.
  Returns the file's bytes, or `nil` when it is missing, not a regular file or too large.
  """
  @spec copy_out_file(ctx(), String.t(), String.t(), pos_integer()) :: binary() | nil
  def copy_out_file(ctx, name, path, limit) do
    with {:ok, tar} <-
           docker(ctx, ["cp", "#{name}:#{path}", "-"],
             timeout_ms: 300_000,
             max_bytes: limit + 64 * 1024
           ),
         {:ok, [{_name, bytes}]} <- :erl_tar.extract({:binary, tar}, [:memory]),
         true <- byte_size(bytes) <= limit do
      bytes
    else
      _ -> nil
    end
  end

  # Learner --------------------------------------------------------------------------------

  @doc """
  Run the learner session. `spec` keys: `:extract`, `:prompt` (bytes), `:plan` (bytes or
  nil), `:mode` (`:mock` or `:live`), `:model`, `:max_turns`, `:cap_nanousd`,
  `:timeout_ms`, `:learner_image`, `:meter` (`{:image, tag}` or `{:url, url, network}`),
  `:key_file` (live image mode only), `:ctx`.
  """
  @spec run(map()) :: map()
  def run(spec) do
    started = now()
    ctx = spec.ctx

    result =
      with :ok <- available(ctx) |> unavailable_as("no_docker"),
           {:ok, _} <- image_id(ctx, spec.learner_image) |> found_or("image_missing"),
           :ok <- meter_image_present(ctx, spec.meter) do
        session(spec)
      else
        {:unavailable, reason} -> outcome("unavailable", reason)
      end

    Map.update!(result, :report, &Map.put(&1, "host_wall_ms", now() - started))
  end

  defp unavailable_as(:ok, _), do: :ok
  defp unavailable_as(_, reason), do: {:unavailable, reason}

  defp found_or({:ok, id}, _), do: {:ok, id}
  defp found_or(:missing, reason), do: {:unavailable, reason}

  defp meter_image_present(ctx, {:image, tag}) do
    case image_id(ctx, tag) do
      {:ok, _} -> :ok
      :missing -> {:unavailable, "meter_unavailable"}
    end
  end

  defp meter_image_present(_ctx, {:url, _url, _network}), do: :ok

  @doc """
  Names used for one learner run (`id` is `<repo>-<base12>`). With `run` (a random
  token per session), the container and network names end in `-<run>`, so two runs on
  the same repository and commit never remove each other's containers; the meter's
  `run_id` stays `learn-<id>`.
  """
  @spec names(map(), String.t() | nil) :: map()
  def names(extract_doc, run \\ nil) do
    repo = extract_doc["repository"]
    id = "#{repo["name"]}-#{String.slice(repo["base_commit"], 0, 12)}"
    unique = if run, do: id <> "-" <> run, else: id

    %{
      id: id,
      run_id: "learn-" <> id,
      learner: "olivium-bench-learn-" <> unique,
      meter: "olivium-bench-meter-v4learn-" <> unique,
      network: "olivium-bench-learn-net-" <> unique,
      egress: "olivium-bench-learn-egress-" <> unique
    }
  end

  defp session(spec) do
    names = names(spec.extract.doc, suffix())
    ctx = spec.ctx
    stage = Path.join(System.tmp_dir!(), "olivium-learn-" <> suffix())
    repo_stage = stage <> "-repo"

    try do
      cleanup(ctx, names, spec.meter)

      with :ok <- File.mkdir_p(stage) |> io_or("meter_unavailable"),
           :ok <- stage_inputs(stage, spec),
           :ok <- stage_repository(spec.extract, repo_stage) |> io_or("meter_unavailable"),
           {:ok, base_url, network} <- start_meter(spec, names),
           :ok <- create_learner(spec, names, base_url, network),
           :ok <-
             copy_in(ctx, repo_stage, names.learner, "/work/repo")
             |> io_or("meter_unavailable"),
           :ok <- copy_in(ctx, stage, names.learner, "/work/in") |> io_or("meter_unavailable") do
        started = now()
        waited = start_and_wait(ctx, names.learner, spec.timeout_ms)
        wall = now() - started
        collect_outcome(spec, names, waited, wall)
      else
        {:unavailable, reason} -> outcome("unavailable", reason)
      end
    after
      cleanup(ctx, names, spec.meter)
      File.rm_rf(stage)
      File.rm_rf(repo_stage)
    end
  end

  @doc """
  Stage what the learner may read of the repository into `dest` (which must not exist):
  `.git` and the tracked files as they are in the working tree. Untracked and ignored
  files are left out. A tracked symlink is copied as a link, never followed, and a file
  under a symlinked directory is skipped.
  """
  @spec stage_repository(%{root: String.t(), repo: Git.t()}, String.t()) :: :ok | {:error, term()}
  def stage_repository(%{root: root, repo: repo}, dest) do
    with {:ok, files} <- Git.ls_files(repo),
         {:error, :enoent} <- File.lstat(dest) |> absent(),
         :ok <- File.mkdir_p(dest),
         {:ok, _} <- File.cp_r(Path.join(root, ".git"), Path.join(dest, ".git")) do
      # Every parent must be a real directory inside the root, not a symlink out of it.
      real_parents =
        for parent <- files |> Enum.map(&Path.dirname/1) |> Enum.uniq(),
            parent == "." or Git.safe_path(root, parent) == {:ok, Path.join(root, parent)},
            into: MapSet.new(),
            do: parent

      Enum.reduce_while(files, :ok, fn path, :ok ->
        case stage_file(root, dest, path, real_parents) do
          :ok -> {:cont, :ok}
          failure -> {:halt, failure}
        end
      end)
    else
      {:error, reason, _file} -> {:error, reason}
      {:error, _} = failure -> failure
      _ -> {:error, :stage_failed}
    end
  end

  defp absent({:ok, _}), do: {:error, :exists}
  defp absent(other), do: other

  defp stage_file(root, dest, path, real_parents) do
    source = Path.join(root, path)
    target = Path.join(dest, path)

    case MapSet.member?(real_parents, Path.dirname(path)) && File.lstat(source) do
      {:ok, %File.Stat{type: :regular}} ->
        with :ok <- File.mkdir_p(Path.dirname(target)), do: File.cp(source, target)

      {:ok, %File.Stat{type: :symlink}} ->
        with :ok <- File.mkdir_p(Path.dirname(target)),
             {:ok, link} <- File.read_link(source),
             do: File.ln_s(link, target)

      # Missing in the working tree, a submodule directory, or under a symlinked parent.
      _ ->
        :ok
    end
  end

  defp io_or(:ok, _), do: :ok
  defp io_or(_, reason), do: {:unavailable, reason}

  defp stage_inputs(stage, spec) do
    prompt =
      case spec.plan do
        nil -> spec.prompt
        plan -> spec.prompt <> "\nOLIVIUM_MOCK_PLAN_B64=" <> Base.encode64(plan) <> "\n"
      end

    files =
      [
        {"prompt.txt", prompt},
        {"settings.json", spec.settings},
        {"learn-input.json", spec.extract.json}
      ] ++
        Enum.map(HarnessForge.Learning.Extract.views(spec.extract), fn {n, b} ->
          {"views/" <> n, b}
        end)

    Enum.reduce_while(files, :ok, fn {name, bytes}, :ok ->
      path = Path.join(stage, name)

      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(path, bytes),
           :ok <- File.chmod(path, 0o644) do
        {:cont, :ok}
      else
        _ -> {:halt, {:unavailable, "meter_unavailable"}}
      end
    end)
    |> case do
      :ok ->
        File.chmod(stage, 0o755)
        File.chmod(Path.join(stage, "views"), 0o755)
        :ok

      other ->
        other
    end
  end

  defp start_meter(%{meter: {:url, url, network}}, _names), do: {:ok, url, network}

  defp start_meter(%{meter: {:image, tag}} = spec, names) do
    ctx = spec.ctx
    live? = spec.mode == :live
    usd = usd(spec.cap_nanousd)

    network_args = [
      "network",
      "create",
      "--internal",
      "--label",
      "olivium-bench=1",
      "-o",
      "com.docker.network.bridge.gateway_mode_ipv4=isolated",
      names.network
    ]

    mount =
      if live?,
        do: ["--mount", "type=bind,source=#{spec.key_file},target=/run/secrets/key,readonly"],
        else: []

    meter_args =
      [
        "--mode",
        if(live?, do: "live", else: "mock"),
        "--run-cap-usd",
        usd,
        "--total-cap-usd",
        usd,
        "--total-reserve-usd",
        reserve_usd(spec.cap_nanousd)
      ] ++
        if(live?, do: ["--key-file", "/run/secrets/key"], else: [])

    create =
      [
        "create",
        "--name",
        names.meter,
        "--label",
        "olivium-bench=1",
        "--network",
        names.network,
        "--network-alias",
        "meter",
        "--cap-drop=ALL",
        "--security-opt=no-new-privileges",
        "--memory",
        "256m",
        "--pids-limit",
        "128"
      ] ++ mount ++ [tag | meter_args]

    with {:ok, _} <- docker(ctx, network_args, timeout_ms: 60_000),
         {:ok, _} <- ctx |> docker(create, timeout_ms: 120_000) |> key_mount(live?),
         :ok <- egress(ctx, names, live?),
         {:ok, _} <- docker(ctx, ["start", names.meter], timeout_ms: 120_000),
         :ok <- meter_ready(ctx, names.meter, now() + @meter_ready_ms) do
      {:ok, "http://meter:8080/run/" <> names.run_id, names.network}
    else
      :no_key_file -> {:unavailable, "no_key_file"}
      _ -> {:unavailable, "meter_unavailable"}
    end
  end

  # The key file is never opened or checked here: Docker mounts it, and a missing file is
  # reported by Docker when the meter container is created. Its output is not kept.
  defp key_mount({:error, {:exit, _status, output}}, true) do
    if String.contains?(output, "bind source path does not exist"), do: :no_key_file, else: :error
  end

  defp key_mount(result, _live?), do: result

  defp egress(_ctx, _names, false), do: :ok

  defp egress(ctx, names, true) do
    with {:ok, _} <-
           docker(ctx, ["network", "create", "--label", "olivium-bench=1", names.egress],
             timeout_ms: 60_000
           ),
         {:ok, _} <-
           docker(ctx, ["network", "connect", names.egress, names.meter], timeout_ms: 60_000) do
      :ok
    end
  end

  defp meter_ready(ctx, meter, deadline) do
    code = "import urllib.request as u; u.urlopen('http://127.0.0.1:8080/healthz', timeout=2)"

    case docker(ctx, ["exec", meter, "python3", "-I", "-c", code], timeout_ms: 20_000) do
      {:ok, _} ->
        :ok

      _ ->
        if now() < deadline do
          Process.sleep(1_000)
          meter_ready(ctx, meter, deadline)
        else
          :error
        end
    end
  end

  defp create_learner(spec, names, base_url, network) do
    env = [
      {"ANTHROPIC_BASE_URL", base_url},
      {"ANTHROPIC_API_KEY", @dummy_key},
      {"LEARN_MODEL", spec.model},
      {"LEARN_MAX_TURNS", Integer.to_string(spec.max_turns)},
      {"LEARN_TIMEOUT_S", Integer.to_string(div(spec.timeout_ms, 1000))}
    ]

    args =
      [
        "create",
        "--name",
        names.learner,
        "--label",
        "olivium-bench=1",
        "--network",
        network,
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
        "--user",
        "#{@agent_uid}:#{@agent_uid}"
      ] ++ Enum.flat_map(env, fn {k, v} -> ["--env", "#{k}=#{v}"] end) ++ [spec.learner_image]

    case docker(spec.ctx, args, timeout_ms: 120_000) do
      {:ok, _} -> :ok
      _ -> {:unavailable, "image_missing"}
    end
  end

  defp start_and_wait(ctx, name, timeout_ms) do
    with {:ok, _} <- docker(ctx, ["start", name], timeout_ms: 120_000) do
      case docker(ctx, ["wait", name], timeout_ms: timeout_ms + 60_000) do
        {:ok, output} ->
          case Integer.parse(String.trim(output)) do
            {code, ""} -> {:exited, code}
            _ -> {:exited, 255}
          end

        {:error, :timeout} ->
          docker(ctx, ["kill", name], timeout_ms: 60_000)
          :timeout

        _ ->
          {:exited, 255}
      end
    else
      _ -> :not_started
    end
  end

  defp collect_outcome(spec, names, waited, wall) do
    ctx = spec.ctx

    transcript =
      copy_out_file(ctx, names.learner, "/work/out/transcript.jsonl", @transcript_limit)

    raw = copy_out_file(ctx, names.learner, "/work/out/learned.raw.json", @raw_limit)
    result_event = result_event(transcript)

    rows =
      case spec.meter do
        {:image, _} ->
          (copy_out_file(ctx, names.meter, "/data/requests.jsonl", @meter_log_limit) || "")
          |> meter_rows(names.run_id)

        _ ->
          nil
      end

    usage = if rows, do: meter_usage(rows), else: transcript_usage(result_event)

    reason =
      cond do
        waited == :not_started -> "model_error"
        waited == :timeout -> "timeout"
        cap_reached?(rows, transcript) -> "cap_reached"
        result_event["subtype"] == "error_max_turns" -> "turn_cap"
        waited == {:exited, 124} -> "timeout"
        waited != {:exited, 0} or result_event["is_error"] == true -> "model_error"
        is_nil(raw) -> "invalid_output"
        true -> "none"
      end

    status =
      cond do
        reason != "none" -> "failed"
        spec.mode == :mock -> "mock"
        true -> "ok"
      end

    %{
      status: status,
      reason: reason,
      raw: if(status in ["ok", "mock"], do: raw),
      transcript: transcript,
      requests: usage.requests,
      tokens: usage.tokens,
      cost_nanousd: usage.cost_nanousd,
      wall_ms: wall,
      report: %{
        "exit" => exit_code(waited),
        "result_subtype" => result_event["subtype"],
        "num_turns" => result_event["num_turns"],
        "usage_source" => if(rows, do: "meter", else: "claude_code_result_event"),
        "meter_statuses" => if(rows, do: rows |> Enum.map(& &1["status"]) |> Enum.frequencies()),
        "raw_bytes" => if(raw, do: byte_size(raw), else: 0),
        "transcript_bytes" => if(transcript, do: byte_size(transcript), else: 0)
      }
    }
  end

  defp exit_code({:exited, code}), do: code
  defp exit_code(other), do: Atom.to_string(other)

  defp outcome(status, reason) do
    %{
      status: status,
      reason: reason,
      raw: nil,
      requests: 0,
      tokens: %{"input" => 0, "output" => 0, "cache_read" => 0, "cache_write" => 0},
      cost_nanousd: 0,
      wall_ms: 0,
      report: %{}
    }
  end

  defp result_event(nil), do: %{}

  defp result_event(transcript) do
    transcript
    |> String.split("\n", trim: true)
    |> Enum.reverse()
    |> Enum.find_value(%{}, fn line ->
      case Jason.decode(line) do
        {:ok, %{"type" => "result"} = event} -> event
        _ -> nil
      end
    end)
  end

  defp meter_rows(log, run_id) do
    log
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, %{"run_id" => ^run_id} = row} -> [row]
        _ -> []
      end
    end)
  end

  defp meter_usage(rows) do
    messages = Enum.filter(rows, &(&1["endpoint"] == "messages" and &1["status"] == "ok"))

    %{
      requests: length(messages),
      tokens: %{
        "input" => sum(messages, "input_tokens"),
        "output" => sum(messages, "output_tokens"),
        "cache_read" => sum(messages, "cache_read_input_tokens"),
        "cache_write" => sum(messages, "cache_creation_input_tokens")
      },
      cost_nanousd: sum(rows, "cost_nanousd")
    }
  end

  defp sum(rows, key) do
    Enum.reduce(rows, 0, fn row, acc ->
      case row[key] do
        n when is_integer(n) and n >= 0 -> acc + n
        _ -> acc
      end
    end)
  end

  defp transcript_usage(event) do
    usage = if is_map(event["usage"]), do: event["usage"], else: %{}
    cost = event["total_cost_usd"]

    %{
      requests: if(is_integer(event["num_turns"]), do: event["num_turns"], else: 0),
      tokens: %{
        "input" => int(usage["input_tokens"]),
        "output" => int(usage["output_tokens"]),
        "cache_read" => int(usage["cache_read_input_tokens"]),
        "cache_write" => int(usage["cache_creation_input_tokens"])
      },
      cost_nanousd: if(is_number(cost) and cost >= 0, do: round(cost * 1_000_000_000), else: 0)
    }
  end

  defp int(n) when is_integer(n) and n >= 0, do: n
  defp int(_), do: 0

  defp cap_reached?(rows, transcript) do
    (is_list(rows) and Enum.any?(rows, &(&1["status"] in ["cap_run", "cap_total"]))) or
      (is_binary(transcript) and String.contains?(transcript, "olivium-bench meter stop: cap"))
  end

  defp cleanup(ctx, names, meter) do
    remove(ctx, [names.learner])

    case meter do
      {:image, _} ->
        remove(ctx, [names.meter])
        docker(ctx, ["network", "rm", names.network], timeout_ms: 60_000)
        docker(ctx, ["network", "rm", names.egress], timeout_ms: 60_000)

      _ ->
        :ok
    end

    :ok
  end

  @doc """
  The meter's reserve per in-flight request against the total cap: a tenth of the cap.
  The meter refuses a request when `spent + (in_flight + 1) * reserve >= cap`, so the
  reserve must stay below the cap or nothing is admitted.
  """
  @spec reserve_usd(non_neg_integer()) :: String.t()
  def reserve_usd(cap_nanousd), do: usd(div(cap_nanousd, 10))

  @doc "Nanodollars as a decimal USD string for the meter (`500000000` → `0.5`)."
  @spec usd(non_neg_integer()) :: String.t()
  def usd(nanos) do
    whole = div(nanos, 1_000_000_000)
    frac = nanos |> rem(1_000_000_000) |> Integer.to_string() |> String.pad_leading(9, "0")

    case String.trim_trailing(frac, "0") do
      "" -> Integer.to_string(whole)
      digits -> "#{whole}.#{digits}"
    end
  end

  defp suffix, do: 6 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  @doc false
  def digest(bytes), do: Contracts.sha256(bytes)
end
