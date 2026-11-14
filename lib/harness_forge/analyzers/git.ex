defmodule HarnessForge.Analyzers.Git do
  @moduledoc """
  The only path from the application to the `git` binary, and the safe boundary
  for reading files of an analyzed repository.

  An analyzed repository is hostile input. Its `.git/config` can name programs
  (`core.fsmonitor`, `diff.external`, textconv and filter drivers, `gpg.program`,
  promisor remotes), so this module:

    * runs `log`, `ls-files`, `rev-parse` and `show` only, checking every flag and
      revision against an allow-list rather than a block-list;
    * never uses a shell: argv goes straight to the executable;
    * clears the environment, points `GIT_CONFIG_GLOBAL` and `GIT_CONFIG_SYSTEM`
      at the null device, and passes `-c` overrides, which outrank every file;
    * forces `--no-ext-diff --no-textconv --no-show-signature` where they apply,
      because diff drivers are named by the repository and cannot be overridden by
      a fixed `-c` key;
    * denies every transport, so a lazy fetch from a promisor remote cannot run;
    * enforces a deadline and an output cap, killing the process on either.

  `.git` must be a real directory at the root. A `.git` file or symlink (worktrees,
  submodules) can point anywhere, so it is reported as `git_unavailable`.

  Results are bytes from the repository: treat them as data. Paths in `.git` are
  refused. `ls_files/2` omits paths that are not valid UTF-8 because they cannot
  be represented in the JSON contracts. stderr is inherited, since a port cannot
  capture it separately from stdout without a shell. Only the root check and the
  symlink walk guard the file helpers; they do not close a race with a process
  that swaps files mid-read.
  """

  alias HarnessForge.Contracts
  alias HarnessForge.Contracts.Error

  @enforce_keys [:root, :executable]
  defstruct [:root, :executable]

  @type t :: %__MODULE__{root: String.t(), executable: String.t()}

  @null_device "/dev/null"
  @timeout_ms 60_000
  @max_timeout_ms 300_000
  @output_limit 16 * 1024 * 1024
  @max_output_limit 64 * 1024 * 1024
  @file_limit 1024 * 1024
  @default_commits 5_000
  @max_commits 100_000
  @symlink_depth 40

  # `-c` outranks system, global, local and included config files.
  @config_overrides [
    "core.fsmonitor=false",
    "core.pager=cat",
    "core.sshCommand=false",
    "core.askPass=false",
    "core.hooksPath=" <> @null_device,
    "core.attributesFile=" <> @null_device,
    "core.excludesFile=" <> @null_device,
    "core.quotePath=false",
    "diff.external=true",
    "gpg.program=false",
    "gpg.ssh.program=false",
    "gpg.x509.program=false",
    "log.showSignature=false",
    "log.mailmap=false",
    "log.showRoot=true",
    "log.diffMerges=first-parent",
    "diff.orderFile=" <> @null_device,
    "diff.relative=false",
    "mailmap.file=" <> @null_device,
    "credential.helper=",
    "protocol.allow=never",
    "submodule.recurse=false"
  ]

  @log_forced ~w(--no-ext-diff --no-textconv --no-show-signature --no-notes --no-color --no-decorate)
  @show_forced @log_forced ++ ["--format="]

  @log_flags ~w(--numstat --shortstat --name-only --name-status --no-merges --merges --first-parent --topo-order --date-order --reverse --no-renames -M --diff-filter=R -z --all)
  @log_dates ~w(iso-strict iso short unix raw)
  @ls_files_flags ~w(--cached --others --exclude-standard --full-name -z)
  @rev_parse_flags ~w(--verify --quiet -q --is-inside-work-tree --is-shallow-repository --is-bare-repository)

  @doc "Open a repository for analysis, or explain why git cannot be used on it."
  @spec open(Path.t()) :: {:ok, t()} | {:error, Error.t()}
  def open(path) when is_binary(path) do
    with {:ok, root} <- real_directory(path),
         :ok <- git_directory(root),
         {:ok, executable} <- executable(),
         repo = %__MODULE__{root: root, executable: executable},
         :ok <- probe(repo) do
      {:ok, repo}
    end
  end

  def open(_), do: error("invalid_repository_path", "Expected a repository directory path")

  @doc "A display result with string keys `status` (`available` or `git_unavailable`) and `reason`."
  @spec availability(Path.t()) :: %{required(String.t()) => String.t() | nil}
  def availability(path) do
    case open(path) do
      {:ok, _} ->
        %{"status" => "available", "reason" => nil}

      {:error, %Error{code: "git_unavailable", details: [reason | _]}} ->
        %{"status" => "git_unavailable", "reason" => reason}

      {:error, _} ->
        %{"status" => "git_unavailable", "reason" => "repository_unreadable"}
    end
  end

  @doc "The commit at HEAD, or `nil` for a repository with no commits."
  @spec head(t()) :: {:ok, String.t() | nil} | {:error, Error.t()}
  def head(%__MODULE__{} = repo) do
    case rev_parse(repo, ["--verify", "--quiet", "HEAD"]) do
      {:ok, output} -> {:ok, String.trim(output)}
      {:error, %Error{code: "git_failed", details: ["exit_status:1"]}} -> {:ok, nil}
      {:error, _} = failure -> failure
    end
  end

  @doc """
  Run `git log` with allow-listed arguments. `--max-count` defaults to #{@default_commits}.
  `--since` and `--until` are refused: time windows relative to now are not deterministic.
  """
  @spec log(t(), [String.t()], keyword()) :: {:ok, binary()} | {:error, Error.t()}
  def log(%__MODULE__{} = repo, args, opts \\ []), do: run(repo, "log", args, opts)

  @doc "Tracked files as NUL-parsed relative paths. Pass `others: true` to add untracked files."
  @spec ls_files(t(), keyword()) :: {:ok, [String.t()]} | {:error, Error.t()}
  def ls_files(%__MODULE__{} = repo, opts \\ []) do
    others =
      if Keyword.get(opts, :others, false), do: ["--others", "--exclude-standard"], else: []

    with {:ok, output} <- run(repo, "ls-files", ["--cached", "-z"] ++ others, opts) do
      {:ok,
       output
       |> String.split(<<0>>, trim: true)
       |> Enum.filter(&String.valid?/1)
       |> Enum.uniq()
       |> Enum.sort()}
    end
  end

  @spec rev_parse(t(), [String.t()], keyword()) :: {:ok, binary()} | {:error, Error.t()}
  def rev_parse(%__MODULE__{} = repo, args, opts \\ []), do: run(repo, "rev-parse", args, opts)

  @doc "Bytes of `path` as stored in `rev`. A symlink yields its target text, as data."
  @spec show_path(t(), String.t(), String.t(), keyword()) :: {:ok, binary()} | {:error, Error.t()}
  def show_path(%__MODULE__{} = repo, rev, path, opts \\ [])
      when is_binary(rev) and is_binary(path),
      do: run(repo, "show", [rev <> ":" <> path], opts)

  @doc """
  Run an allow-listed subcommand. Anything outside the allow-list returns
  `git_command_rejected` without starting a process.
  """
  @spec run(t(), String.t(), [String.t()], keyword()) :: {:ok, binary()} | {:error, Error.t()}
  def run(%__MODULE__{} = repo, subcommand, args, opts \\ [])
      when is_binary(subcommand) and is_list(args) do
    with {:ok, checked} <- check_arguments(subcommand, args) do
      exec(repo, global_arguments(repo) ++ [subcommand | checked], opts)
    end
  end

  @doc """
  Resolve `relative` inside `root` following symlinks, refusing any that leave the
  root and anything inside `.git`. Works on directories that are not repositories.
  """
  @spec safe_path(Path.t(), String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def safe_path(root, relative) when is_binary(root) and is_binary(relative) do
    if Contracts.relative_path?(relative) do
      with {:ok, real_root} <- real_directory(root) do
        walk(real_root, Path.split(relative), real_root, 0)
      end
    else
      outside()
    end
  end

  def safe_path(_, _), do: outside()

  @doc "Read a contained regular file of at most `:max_bytes` (default #{@file_limit})."
  @spec read_file(Path.t(), String.t(), keyword()) :: {:ok, binary()} | {:error, Error.t()}
  def read_file(root, relative, opts \\ []) do
    limit = bounded(opts[:max_bytes], @file_limit, @max_output_limit)

    with {:ok, path} <- safe_path(root, relative),
         {:ok, %File.Stat{type: :regular, size: size}} <- File.lstat(path),
         true <- size <= limit,
         {:ok, bytes} <- File.read(path) do
      {:ok, bytes}
    else
      {:error, %Error{} = failure} -> {:error, failure}
      false -> error("file_too_large", "File exceeds the read limit")
      _ -> error("unreadable_file", "Path is not a readable regular file")
    end
  end

  @doc "The real path of an existing directory, with every symlink resolved."
  @spec real_directory(Path.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def real_directory(path) when is_binary(path) do
    with false <- String.contains?(path, <<0>>),
         {:ok, real} <- canonical(Path.split(Path.expand(path)), "/", 0),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(real) do
      {:ok, real}
    else
      _ -> error("invalid_repository_path", "Path is not an existing directory")
    end
  end

  # Arguments

  defp check_arguments("log", args) do
    with {:ok, options, paths} <- split_pathspecs(args),
         true <- Enum.all?(options, &log_argument?/1) do
      {:ok, @log_forced ++ with_commit_limit(options) ++ paths}
    else
      _ -> rejected()
    end
  end

  defp check_arguments("ls-files", args) do
    with {:ok, options, paths} <- split_pathspecs(args),
         true <- Enum.all?(options, &(&1 in @ls_files_flags)) do
      {:ok, options ++ paths}
    else
      _ -> rejected()
    end
  end

  defp check_arguments("rev-parse", args) do
    if args != [] and Enum.all?(args, &(&1 in @rev_parse_flags or revision_name?(&1))) do
      {:ok, args}
    else
      rejected()
    end
  end

  defp check_arguments("show", [object]) when is_binary(object) do
    with [rev, path] <- String.split(object, ":", parts: 2),
         true <- revision?(rev),
         true <- repository_path?(path) do
      {:ok, @show_forced ++ [object]}
    else
      _ -> rejected()
    end
  end

  defp check_arguments(_, _), do: rejected()

  defp split_pathspecs(args) do
    if Enum.all?(args, &is_binary/1) do
      case Enum.split_while(args, &(&1 != "--")) do
        {options, []} ->
          {:ok, options, []}

        {options, ["--" | paths]} ->
          if Enum.all?(paths, &repository_path?/1),
            do: {:ok, options, ["--" | paths]},
            else: :error
      end
    else
      :error
    end
  end

  defp log_argument?("--format=" <> format), do: safe_format?(format)
  defp log_argument?("--date=" <> date), do: date in @log_dates
  defp log_argument?("--max-count=" <> count), do: integer_within?(count, 1, @max_commits)
  defp log_argument?("--skip=" <> count), do: integer_within?(count, 0, 10_000_000)
  defp log_argument?("-" <> _ = flag), do: flag in @log_flags
  defp log_argument?(revision), do: revision_range?(revision)

  # %G placeholders verify signatures, and %(describe) walks tags.
  defp safe_format?(format) do
    String.valid?(format) and byte_size(format) <= 1024 and
      not String.contains?(format, ["%G", "%(describe"])
  end

  defp with_commit_limit(options) do
    if Enum.any?(options, &String.starts_with?(&1, "--max-count=")),
      do: options,
      else: ["--max-count=#{@default_commits}" | options]
  end

  defp integer_within?(text, low, high) do
    case Integer.parse(text) do
      {value, ""} -> value >= low and value <= high
      _ -> false
    end
  end

  defp revision_range?(text) do
    case String.split(text, "..", parts: 2) do
      [first, second] -> revision?(first) and revision?(second)
      [single] -> revision?(single)
    end
  end

  defp revision?(text), do: Regex.match?(~r/\A(?:HEAD(?:~[0-9]{1,6})?|[0-9a-f]{7,64})\z/, text)

  defp revision_name?(text) do
    revision?(text) or
      (byte_size(text) <= 256 and not String.contains?(text, "..") and
         Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._\/-]*\z/, text))
  end

  defp repository_path?(path) do
    Contracts.relative_path?(path) and String.valid?(path) and
      not Enum.any?(String.split(path, "/"), &git_segment?/1)
  end

  defp git_segment?(segment), do: String.downcase(segment) == ".git"

  # Process

  defp global_arguments(%__MODULE__{root: root}) do
    overrides = Enum.flat_map(@config_overrides, &["-c", &1])

    ["--no-pager", "--no-optional-locks", "--literal-pathspecs"] ++
      overrides ++ ["--git-dir=" <> Path.join(root, ".git"), "--work-tree=" <> root]
  end

  defp environment do
    cleared = for {name, _} <- System.get_env(), do: {String.to_charlist(name), false}

    fixed =
      for {name, value} <- [
            {"PATH", "/usr/bin:/bin"},
            {"HOME", @null_device},
            {"LC_ALL", "C"},
            {"TZ", "UTC"},
            {"GIT_CONFIG_GLOBAL", @null_device},
            {"GIT_CONFIG_SYSTEM", @null_device},
            {"GIT_CONFIG_NOSYSTEM", "1"},
            {"GIT_ATTR_NOSYSTEM", "1"},
            {"GIT_TERMINAL_PROMPT", "0"},
            {"GIT_OPTIONAL_LOCKS", "0"},
            {"GIT_NO_LAZY_FETCH", "1"},
            {"GIT_NO_REPLACE_OBJECTS", "1"},
            {"GIT_ALLOW_PROTOCOL", ""},
            {"GIT_PAGER", "cat"},
            {"PAGER", "cat"}
          ],
          do: {String.to_charlist(name), String.to_charlist(value)}

    cleared ++ fixed
  end

  defp exec(%__MODULE__{} = repo, argv, opts) do
    deadline = now() + bounded(opts[:timeout_ms], @timeout_ms, @max_timeout_ms)
    limit = bounded(opts[:max_bytes], @output_limit, @max_output_limit)

    options = [
      :binary,
      :exit_status,
      :hide,
      {:args, argv},
      {:env, environment()},
      {:cd, repo.root}
    ]

    try do
      {:spawn_executable, String.to_charlist(repo.executable)}
      |> Port.open(options)
      |> collect([], 0, limit, deadline)
    rescue
      _ in [ErlangError, ArgumentError] -> unavailable("spawn_failed")
    end
  end

  defp collect(port, output, size, limit, deadline) do
    receive do
      {^port, {:data, data}} ->
        size = size + byte_size(data)

        if size > limit do
          stop(port)
          error("git_output_limit", "git output exceeded the configured limit")
        else
          collect(port, [output, data], size, limit, deadline)
        end

      {^port, {:exit_status, 0}} ->
        {:ok, IO.iodata_to_binary(output)}

      {^port, {:exit_status, status}} ->
        {:error,
         %Error{
           code: "git_failed",
           message: "git exited with an error",
           details: ["exit_status:#{status}"]
         }}
    after
      max(deadline - now(), 0) ->
        stop(port)
        error("git_timeout", "git did not finish within the time limit")
    end
  end

  # Port.close/1 only closes the pipes, so an unresponsive git must be killed.
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

  defp bounded(value, _default, maximum) when is_integer(value) and value > 0,
    do: min(value, maximum)

  defp bounded(_, default, _), do: default

  # Availability

  defp git_directory(root) do
    case File.lstat(Path.join(root, ".git")) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:error, :enoent} -> unavailable("not_a_repository")
      {:ok, _} -> unavailable("git_dir_refused")
      {:error, _} -> unavailable("repository_unreadable")
    end
  end

  defp executable do
    case System.find_executable("git") do
      path when is_binary(path) ->
        if Path.type(path) == :absolute and developer_tools?(path),
          do: {:ok, path},
          else: unavailable("git_not_found")

      nil ->
        unavailable("git_not_found")
    end
  end

  # On macOS the /usr/bin/git shim opens an install dialog when the tools are absent.
  defp developer_tools?("/usr/bin/git") do
    case :os.type() do
      {:unix, :darwin} ->
        match?({_, 0}, System.cmd("/usr/bin/xcode-select", ["-p"], stderr_to_stdout: true))

      _ ->
        true
    end
  end

  defp developer_tools?(_), do: true

  defp probe(repo) do
    case exec(repo, ["--version"], timeout_ms: 10_000) do
      {:ok, "git version " <> _} -> :ok
      _ -> unavailable("git_not_runnable")
    end
  end

  # Paths

  defp canonical([], current, _depth), do: {:ok, current}
  defp canonical(_, _, depth) when depth > @symlink_depth, do: :error
  defp canonical(["/" | rest], _current, depth), do: canonical(rest, "/", depth)

  defp canonical([segment | rest], current, depth) do
    candidate = Path.join(current, segment)

    case File.lstat(candidate) do
      {:ok, %File.Stat{type: :symlink}} ->
        with {:ok, target} <- File.read_link(candidate) do
          canonical(Path.split(Path.expand(target, current)) ++ rest, "/", depth + 1)
        end

      {:ok, _} ->
        canonical(rest, candidate, depth)

      _ ->
        :error
    end
  end

  defp walk(_root, [], current, _depth), do: {:ok, current}
  defp walk(_root, _segments, _current, depth) when depth > @symlink_depth, do: outside()
  defp walk(root, ["." | rest], current, depth), do: walk(root, rest, current, depth)

  defp walk(root, [segment | rest], current, depth) do
    candidate = Path.join(current, segment)

    if git_segment?(segment) do
      outside()
    else
      case File.lstat(candidate) do
        {:ok, %File.Stat{type: :symlink}} -> follow(root, candidate, current, rest, depth)
        {:ok, _} -> walk(root, rest, candidate, depth)
        {:error, _} -> error("path_not_found", "Path does not exist in the repository")
      end
    end
  end

  defp follow(root, link, current, rest, depth) do
    with {:ok, target} <- File.read_link(link),
         resolved = Path.expand(target, current),
         true <- resolved == root or String.starts_with?(resolved, root <> "/") do
      remaining = Path.relative_to(resolved, root)
      segments = if resolved == root, do: rest, else: Path.split(remaining) ++ rest
      walk(root, segments, root, depth + 1)
    else
      _ -> outside()
    end
  end

  # Errors

  defp rejected, do: error("git_command_rejected", "git command is outside the allow-list")

  defp outside,
    do: error("path_outside_repository", "Path is outside the repository or not permitted")

  defp unavailable(reason) do
    {:error,
     %Error{
       code: "git_unavailable",
       message: "git cannot be used for this repository",
       details: [reason]
     }}
  end

  defp error(code, message), do: {:error, %Error{code: code, message: message}}
end
