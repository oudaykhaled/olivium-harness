defmodule HarnessForge.Learning.Extract do
  @moduledoc """
  `history-extract/v1`: a deterministic, bounded summary of a repository's history at
  its HEAD, the base commit. It is the only history the AI learner sees, and the bundle's
  evidence checks are made against it.

  Host side and model free: `git` through `Analyzers.Git` (log, show and ls-files only)
  and the existing analyzer. Nothing from the repository is executed. Only HEAD and its
  ancestors are read, so nothing after the base can enter. No author name or e-mail is
  read; e-mail addresses, @-handles and `*-by:` trailers in commit messages are removed,
  and the existing secret patterns are redacted.

  The document is canonical JSON (`Contracts.canonical_json`) of at most #{409_600} bytes.
  The same repository state gives the same bytes. It is never exported.

  Contents (design.md section 3.1):

    * `commits`: up to 400 first-parent commits from HEAD, newest first, after dropping
      merge noise, dependency bumps and reverts (the `Analyzers.History` rules). Each has
      hash, commit time, subject (120 characters or fewer), the first 3 non-empty body
      lines (300 characters or fewer), up to 15 files (sorted), the file count, added and
      deleted lines, and `fix` (the History fix rule).
    * `fix_diffs`: up to 80 fix commits with code or test changes, `-U1` style hunks
      computed here from the blobs (`git show rev:path`, a Myers diff), at most 60 lines
      per commit and 160 KB in all.
    * `facts`: top-two-level tree with file counts, test directories, CI `run:` lines,
      `package.json` scripts, `pyproject.toml` tool sections, tox and nox environments,
      Makefile targets, the analyzer's commands, test pairs, co-change, practice counts
      and hot files, and the 300 most-changed symbols with path and line range at HEAD.
      A symbol's score is the change count of its file plus the fix-diff lines that name
      it, so it is a proxy, not a line-accurate blame.
  """

  alias HarnessForge.Analyzers.{Git, Mapping, Paths, Privacy, Repository}
  alias HarnessForge.Contracts
  alias HarnessForge.Contracts.Error

  @version "history-extract/v1"
  @max_bytes 409_600
  @scan_commits 1_000
  @max_commits 400
  @max_fix_diffs 80
  @diff_lines_per_commit 60
  @diff_bytes_total 160 * 1024
  @diff_files_per_commit 4
  @files_per_commit 15
  @all_files_per_commit 200
  @subject_chars 120
  @body_chars 300
  @line_chars 160
  @max_symbols 300
  @symbol_files 60
  @blob_limit 512 * 1024
  @diff_blob_limit 200 * 1024
  @diff_change_limit 400
  @evidence_change_limit 2_000

  # The Analyzers.History rules, which that module keeps private. Kept in step by hand.
  @fix ~r/(?i)\b(?:fix|fixes|fixed|fixing|bugfix|hotfix|regression)\b/
  @not_a_code_fix ~r/(?i)\b(?:typo|typos|typing|docs?|documentation|readme|lint|linting|changelog|style|ci|deps?|dependency|dependencies|flaky)\b/
  @merge_noise ~r/\AMerge (?:branch|remote|tag|commit)\b|\AMerge .* into /
  @dependency_bump ~r/(?i)\A(?:build\(deps|chore\(deps|bump |\[pre-commit\.ci\])/
  @revert ~r/(?i)\Arevert\b/
  @merge_pull ~r/\AMerge pull request (#[0-9]+) from \S+/
  @trailer ~r/\A[A-Za-z][A-Za-z-]*-by:/i
  @email ~r/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/
  @mention ~r/(^|[\s(])@[A-Za-z][A-Za-z0-9-]*/
  @plain_path ~r/\A[A-Za-z0-9_.\/-]{1,200}\z/
  @format "--format=%x01%H%x02%ct%x02%P%x02%s%x02%b%x03"

  @type t :: %{
          required(:doc) => map(),
          required(:json) => binary(),
          required(:sha256) => String.t(),
          required(:bytes) => non_neg_integer(),
          required(:repo) => Git.t(),
          required(:root) => String.t(),
          required(:files) => MapSet.t(String.t()),
          required(:commits) => %{String.t() => map()}
        }

  @spec version() :: String.t()
  def version, do: @version

  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc "The SHA-256 of the extract of the repository at `path`. Raises on failure."
  @spec digest!(Path.t()) :: String.t()
  def digest!(path) do
    case build(path) do
      {:ok, extract} -> extract.sha256
      {:error, %Error{code: code}} -> raise ArgumentError, "extract failed: #{code}"
    end
  end

  @doc """
  Build the extract of the repository at `path` (HEAD is the base). Returns the document,
  its canonical bytes and digest, and the internal commit index used by evidence checks.
  """
  @spec build(Path.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def build(path, _opts \\ []) when is_binary(path) do
    with {:ok, root} <- Git.real_directory(path),
         {:ok, repo} <- Git.open(root),
         {:ok, head} <- head(repo),
         {:ok, files} <- Git.ls_files(repo),
         {:ok, scanned} <- read_commits(repo) do
      files = files |> Enum.filter(&String.valid?/1) |> MapSet.new()
      kept = scanned |> Enum.reject(&noise?/1) |> Enum.take(@max_commits)
      head_time = head_time(scanned, head, repo)
      fix_diffs = fix_diffs(repo, kept)
      facts = facts(root, repo, files, kept, fix_diffs)

      doc =
        %{
          "version" => @version,
          "repository" => %{
            "name" => name(root),
            "base_commit" => head,
            "base_commit_time" => head_time,
            "history_commits_used" => length(kept),
            "history_first_commit_time" =>
              case List.last(kept) do
                nil -> head_time
                commit -> commit.time
              end
          },
          "commits" => Enum.map(kept, &public_commit/1),
          "fix_diffs" => fix_diffs,
          "facts" => facts
        }
        |> bounded()

      json = Contracts.canonical_json(doc)

      {:ok,
       %{
         doc: doc,
         json: json,
         sha256: Contracts.sha256(json),
         bytes: byte_size(json),
         repo: repo,
         root: root,
         files: files,
         commits: kept |> Enum.take(length(doc["commits"])) |> Map.new(&{&1.hash, &1})
       }}
    end
  end

  @doc "A sanitized repository name from the directory name: `^[A-Za-z0-9._-]{1,100}$`."
  @spec name(String.t()) :: String.t()
  def name(root) do
    root
    |> Path.basename()
    |> String.replace(~r/[^A-Za-z0-9._-]/, "-")
    |> String.slice(0, 100)
    |> case do
      "" -> "repository"
      "." <> _ = dotted -> "r" <> String.slice(dotted, 0, 99)
      other -> other
    end
  end

  @doc """
  The added and removed lines (without the `+`/`-` marker) of `hash` against its first
  parent, over every text file the commit changed (at most #{@all_files_per_commit} files
  of #{@diff_blob_limit} bytes or fewer). Used by the pitfall evidence check.
  """
  @spec changed_lines(t(), String.t()) :: [String.t()]
  def changed_lines(%{repo: repo, commits: commits}, hash) do
    case Map.fetch(commits, hash) do
      {:ok, %{parents: [parent | _]} = commit} ->
        commit.files
        |> Enum.filter(fn path ->
          {added, deleted} = Map.get(commit.numstat, path, {0, 0})
          added + deleted <= @evidence_change_limit
        end)
        |> Enum.flat_map(fn path ->
          case blob_pair(repo, parent, commit, path) do
            {:ok, old, new} ->
              old
              |> diff_ops(new)
              |> Enum.flat_map(fn
                {:del, lines} -> lines
                {:ins, lines} -> lines
                {:eq, _} -> []
              end)

            :skip ->
              []
          end
        end)

      _ ->
        []
    end
  end

  @doc """
  Every commit reachable from HEAD (all parents), as a set of hashes. Evidence that names
  a commit in the repository outside this set is after the base.
  """
  @spec ancestors(t()) :: MapSet.t(String.t())
  def ancestors(%{repo: repo}) do
    case Git.log(repo, ["--format=%H", "--max-count=100000"], max_bytes: 8 * 1024 * 1024) do
      {:ok, output} -> output |> String.split("\n", trim: true) |> MapSet.new()
      _ -> MapSet.new()
    end
  end

  @doc """
  Every commit reachable from any ref (branches, tags, HEAD), as a set of hashes. A cited
  commit in this set but not in `ancestors/1` is after the base. Listing refs instead of
  asking git about each hash keeps git's "bad object" errors off stderr.
  """
  @spec all_commits(t()) :: MapSet.t(String.t())
  def all_commits(%{repo: repo}) do
    case Git.log(repo, ["--all", "--format=%H", "--max-count=100000"], max_bytes: 8 * 1024 * 1024) do
      {:ok, output} -> output |> String.split("\n", trim: true) |> MapSet.new()
      _ -> MapSet.new()
    end
  end

  @doc "True when a ref of the repository reaches the commit `hash`."
  @spec commit_exists?(t(), String.t()) :: boolean()
  def commit_exists?(extract, hash), do: MapSet.member?(all_commits(extract), hash)

  @doc """
  Plain-text views of the extract for the learner (`commits.txt`, `fixes.txt`,
  `facts.json`): the same content, cheaper to read than one line of JSON.
  """
  @spec views(t()) :: [{String.t(), binary()}]
  def views(%{doc: doc}) do
    commits =
      Enum.map(doc["commits"], fn commit ->
        flag = if commit["fix"], do: "F", else: "-"
        files = Enum.join(commit["files"], ",")
        more = if commit["files_total"] > length(commit["files"]), do: ",...", else: ""

        body =
          case commit["body"] do
            [] -> ""
            lines -> "\n    " <> Enum.join(lines, " / ")
          end

        "#{commit["hash"]} #{day(commit["time"])} #{flag} +#{commit["added"]} -#{commit["deleted"]} " <>
          "#{commit["subject"]}\n    files: #{files}#{more}#{body}\n"
      end)

    fixes =
      Enum.map(doc["fix_diffs"], fn diff ->
        "=== #{diff["hash"]}\n" <> Enum.map_join(diff["lines"], "", &(&1 <> "\n"))
      end)

    [
      {"commits.txt", IO.iodata_to_binary(commits)},
      {"fixes.txt", IO.iodata_to_binary(fixes)},
      {"facts.json", Jason.Formatter.pretty_print(Contracts.canonical_json(doc["facts"])) <> "\n"}
    ]
  end

  # Commits ----------------------------------------------------------------------------

  defp head(repo) do
    case Git.head(repo) do
      {:ok, head} when is_binary(head) and byte_size(head) == 40 ->
        {:ok, head}

      {:ok, _} ->
        {:error, %Error{code: "repository_without_commits", message: "HEAD has no commit"}}

      {:error, _} = failure ->
        failure
    end
  end

  defp head_time([%{hash: hash, time: time} | _], hash, _repo), do: time

  defp head_time(_scanned, head, repo) do
    case Git.log(repo, ["--format=%ct", "--max-count=1", head]) do
      {:ok, output} ->
        case Integer.parse(String.trim(output)) do
          {time, ""} -> time
          _ -> 0
        end

      _ ->
        0
    end
  end

  defp read_commits(repo) do
    args = [
      "--first-parent",
      "--numstat",
      "--no-renames",
      "-z",
      @format,
      "--max-count=#{@scan_commits}"
    ]

    with {:ok, output} <- log_or_empty(repo, args),
         {:ok, statuses} <- read_statuses(repo) do
      commits =
        output
        |> parse()
        |> Enum.map(&Map.put(&1, :status, Map.get(statuses, &1.hash, %{})))

      {:ok, commits}
    end
  end

  # `--name-status` replaces `--numstat` when both are given, so the added/deleted state of
  # each file comes from a second log. It lets the diff code skip the missing side of an
  # added or deleted file instead of asking git for a blob that does not exist.
  defp read_statuses(repo) do
    args = [
      "--first-parent",
      "--name-status",
      "--no-renames",
      "-z",
      "--format=%x01%H%x03",
      "--max-count=#{@scan_commits}"
    ]

    with {:ok, output} <- log_or_empty(repo, args) do
      {:ok,
       output |> :binary.split(<<1>>, [:global]) |> Enum.flat_map(&parse_statuses/1) |> Map.new()}
    end
  end

  defp parse_statuses(record) do
    with [hash, rest] <- :binary.split(record, <<3>>),
         true <- Regex.match?(~r/\A[0-9a-f]{40}\z/, hash) do
      statuses =
        rest
        |> String.trim_leading(<<0>>)
        |> String.trim_leading("\n")
        |> :binary.split(<<0>>, [:global])
        |> Enum.chunk_every(2, 2, :discard)
        |> Enum.flat_map(fn
          [status, path] when status in ["A", "D"] -> [{path, status}]
          _ -> []
        end)
        |> Map.new()

      [{hash, statuses}]
    else
      _ -> []
    end
  end

  defp log_or_empty(repo, args) do
    case Git.log(repo, args, max_bytes: 64 * 1024 * 1024, timeout_ms: 120_000) do
      {:ok, output} -> {:ok, output}
      {:error, %Error{code: "git_failed"}} -> {:ok, ""}
      {:error, _} = failure -> failure
    end
  end

  @doc false
  def parse(output) do
    output
    |> String.replace_invalid("?")
    |> :binary.split(<<1>>, [:global])
    |> Enum.flat_map(&parse_record/1)
  end

  defp parse_record(record) do
    with [header, rest] <- :binary.split(record, <<3>>),
         [hash, stamp, parents, subject | body] <- String.split(header, <<2>>),
         true <- Regex.match?(~r/\A[0-9a-f]{40}\z/, hash),
         {time, ""} <- Integer.parse(stamp) do
      numstat = parse_numstat(rest)
      files = numstat |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()
      {added, deleted} = Enum.reduce(numstat, {0, 0}, fn {_, a, d}, {x, y} -> {x + a, y + d} end)
      raw_body = Enum.join(body, " ")

      [
        %{
          hash: hash,
          time: time,
          parents: String.split(parents),
          raw_subject: subject,
          subject: clean_subject(subject),
          body: clean_body(raw_body),
          files: Enum.take(files, @all_files_per_commit),
          files_total: length(files),
          numstat: Map.new(numstat, fn {path, a, d} -> {path, {a, d}} end),
          added: added,
          deleted: deleted,
          fix?: fix?(subject, files)
        }
      ]
    else
      _ -> []
    end
  end

  defp parse_numstat(rest) do
    rest
    |> :binary.split(<<0>>, [:global])
    |> Enum.map(&String.trim(&1, "\n"))
    |> Enum.flat_map(fn entry ->
      case String.split(entry, "\t", parts: 3) do
        [added, deleted, path] ->
          if reportable?(path), do: [{path, count(added), count(deleted)}], else: []

        _ ->
          []
      end
    end)
  end

  defp count(text) do
    case Integer.parse(text) do
      {value, ""} when value >= 0 -> value
      _ -> 0
    end
  end

  defp reportable?(path) do
    path != "" and String.valid?(path) and Regex.match?(@plain_path, path) and
      not String.starts_with?(path, ["/", "-"]) and not String.contains?(path, ["..", "//"]) and
      not Privacy.secret_path?(path)
  end

  defp noise?(commit) do
    Regex.match?(@merge_noise, commit.raw_subject) or
      Regex.match?(@dependency_bump, commit.raw_subject) or
      Regex.match?(@revert, commit.raw_subject)
  end

  defp fix?(subject, files) do
    Regex.match?(@fix, subject) and not Regex.match?(@not_a_code_fix, subject) and
      Enum.any?(files, &Paths.code_path?/1)
  end

  defp clean_subject(subject) do
    subject
    |> then(&Regex.replace(@merge_pull, &1, "Merge pull request \\1"))
    |> clean_text()
    |> String.slice(0, @subject_chars)
  end

  defp clean_body(body) do
    body
    |> String.split(["\r\n", "\n"])
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or Regex.match?(@trailer, &1)))
    |> Enum.map(&clean_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(40)
  end

  defp clean_text(text) do
    {scrubbed, _} = Privacy.scrub(text)

    scrubbed
    |> then(&Regex.replace(@email, &1, "<email>"))
    |> then(&Regex.replace(@mention, &1, "\\1@user"))
    |> String.replace(~r/[\x00-\x1f\x7f]/u, " ")
    |> String.trim()
  end

  defp public_commit(commit) do
    %{
      "hash" => commit.hash,
      "time" => commit.time,
      "subject" => commit.subject,
      "body" => first_body_lines(commit.body),
      "files" => Enum.take(commit.files, @files_per_commit),
      "files_total" => commit.files_total,
      "added" => commit.added,
      "deleted" => commit.deleted,
      "fix" => commit.fix?
    }
  end

  defp first_body_lines(lines) do
    {kept, _} =
      lines
      |> Enum.take(3)
      |> Enum.map_reduce(@body_chars, fn line, left ->
        piece = String.slice(line, 0, max(left, 0))
        {piece, left - String.length(piece)}
      end)

    Enum.reject(kept, &(&1 == ""))
  end

  # Fix diffs --------------------------------------------------------------------------

  defp fix_diffs(repo, commits) do
    commits
    |> Enum.filter(&(&1.fix? and &1.parents != []))
    |> Enum.reduce_while({[], 0}, fn commit, {acc, total} ->
      if length(acc) >= @max_fix_diffs or total >= @diff_bytes_total do
        {:halt, {acc, total}}
      else
        case commit_hunks(repo, commit) do
          [] ->
            {:cont, {acc, total}}

          lines ->
            size = Enum.reduce(lines, 0, &(byte_size(&1) + 1 + &2))

            if total + size > @diff_bytes_total,
              do: {:halt, {acc, total}},
              else: {:cont, {[%{"hash" => commit.hash, "lines" => lines} | acc], total + size}}
        end
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp commit_hunks(repo, %{parents: [parent | _]} = commit) do
    commit.files
    |> Enum.filter(&Paths.code_path?/1)
    |> Enum.filter(fn path ->
      {added, deleted} = Map.get(commit.numstat, path, {0, 0})
      (added + deleted) in 1..@diff_change_limit
    end)
    |> Enum.take(@diff_files_per_commit)
    |> Enum.reduce_while([], fn path, acc ->
      if length(acc) >= @diff_lines_per_commit do
        {:halt, acc}
      else
        case blob_pair(repo, parent, commit, path) do
          {:ok, old, new} ->
            hunk = ["--- " <> path | hunks(diff_ops(old, new))]
            {:cont, acc ++ Enum.take(hunk, @diff_lines_per_commit - length(acc))}

          :skip ->
            {:cont, acc}
        end
      end
    end)
    |> case do
      [_single_header] -> []
      lines -> lines
    end
  end

  defp blob_pair(repo, parent, commit, path) do
    status = Map.get(Map.get(commit, :status, %{}), path)

    with {:ok, old} <- if(status == "A", do: {:ok, []}, else: blob(repo, parent, path)),
         {:ok, new} <- if(status == "D", do: {:ok, []}, else: blob(repo, commit.hash, path)) do
      {:ok, old, new}
    else
      _ -> :skip
    end
  end

  defp blob(repo, rev, path) do
    case Git.show_path(repo, rev, path, max_bytes: @diff_blob_limit + 1) do
      {:ok, bytes} when byte_size(bytes) <= @diff_blob_limit ->
        if String.valid?(bytes) and not String.contains?(bytes, <<0>>),
          do: {:ok, split_lines(bytes)},
          else: :skip

      {:ok, _} ->
        :skip

      # Added or deleted on this side.
      {:error, %Error{code: "git_failed"}} ->
        {:ok, []}

      _ ->
        :skip
    end
  end

  defp split_lines(""), do: []

  defp split_lines(bytes) do
    bytes
    |> String.split("\n")
    |> then(fn lines -> if List.last(lines) == "", do: Enum.drop(lines, -1), else: lines end)
    |> Enum.map(&String.trim_trailing(&1, "\r"))
  end

  defp clean_line(line) do
    {scrubbed, _} = Privacy.scrub(line)

    scrubbed
    |> then(&Regex.replace(@email, &1, "<email>"))
    |> String.replace(~r/[\x00-\x08\x0b-\x1f\x7f]/u, " ")
    |> String.slice(0, @line_chars)
  end

  defp diff_ops(old, new), do: List.myers_difference(old, new)

  # One line of context around each change; each hunk starts with `@@ -old +new @@`, the
  # line numbers of its first line on each side.
  defp hunks([]), do: []

  defp hunks(ops) do
    {records, _, _} =
      Enum.reduce(ops, {[], 1, 1}, fn {kind, items}, {acc, old, new} ->
        records =
          items
          |> Enum.with_index()
          |> Enum.map(fn {text, i} ->
            case kind do
              :eq -> {:eq, text, old + i, new + i}
              :del -> {:del, text, old + i, new}
              :ins -> {:ins, text, old, new + i}
            end
          end)

        case kind do
          :eq -> {[records | acc], old + length(items), new + length(items)}
          :del -> {[records | acc], old + length(items), new}
          :ins -> {[records | acc], old, new + length(items)}
        end
      end)

    records = records |> Enum.reverse() |> Enum.concat() |> List.to_tuple()
    size = tuple_size(records)

    keep =
      0..(size - 1)//1
      |> Enum.filter(&(elem(elem(records, &1), 0) != :eq))
      |> Enum.flat_map(&[&1 - 1, &1, &1 + 1])
      |> MapSet.new()

    0..(size - 1)//1
    |> Enum.filter(&MapSet.member?(keep, &1))
    |> Enum.reduce({[], -2}, fn index, {acc, previous} ->
      {kind, text, old, new} = elem(records, index)
      mark = %{eq: " ", del: "-", ins: "+"}[kind]
      line = mark <> clean_line(text)

      acc =
        if previous == index - 1,
          do: [line | acc],
          else: [line, "@@ -#{old} +#{new} @@" | acc]

      {acc, index}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  # Facts ------------------------------------------------------------------------------

  defp facts(root, repo, files, commits, fix_diffs) do
    sorted = Enum.sort(files)
    analysis = analyzer(root)

    %{
      "tree" => tree(sorted),
      "test_dirs" => test_dirs(sorted),
      "ci_runs" => analysis["ci_runs"],
      "package_scripts" => package_scripts(repo, files),
      "pyproject_tools" => pyproject_tools(repo, files),
      "tox_envs" => tox_envs(repo, files),
      "nox_sessions" => nox_sessions(repo, files),
      "make_targets" => make_targets(repo, files),
      "analyzer" => Map.delete(analysis, "ci_runs"),
      "symbols" => symbols(repo, files, commits, fix_diffs)
    }
  end

  defp tree(files) do
    counts =
      Enum.reduce(files, %{}, fn path, acc ->
        parts = String.split(path, "/")

        keys =
          case parts do
            [_file] -> ["."]
            [a, _file] -> [a]
            [a, b | _] -> [a, a <> "/" <> b]
          end

        Enum.reduce(keys, acc, &Map.update(&2, &1, 1, fn n -> n + 1 end))
      end)

    counts
    |> Enum.sort()
    |> Enum.take(160)
    |> Enum.map(fn {path, n} -> %{"path" => path, "files" => n} end)
  end

  defp test_dirs(files) do
    files
    |> Enum.filter(&Paths.test_path?/1)
    |> Enum.map(fn path ->
      case String.split(path, "/") do
        [_file] -> "."
        [a, _file] -> a
        [a, b | _] -> a <> "/" <> b
      end
    end)
    |> Enum.frequencies()
    |> Enum.sort()
    |> Enum.take(40)
    |> Enum.map(fn {path, n} -> %{"path" => path, "files" => n} end)
  end

  defp analyzer(root) do
    with {:ok, signals} <- Repository.analyze(root),
         {:ok, profile} <- Mapping.profile(signals) do
      by_key = Map.new(signals["signals"], &{&1["key"], &1})
      hot = get_in(by_key, ["history.hot_files", "value", "files"]) || []
      fixes = get_in(by_key, ["history.fix_hotspots", "value", "files"]) || []
      runs = get_in(by_key, ["ci.runs", "value", "runs"]) || []

      %{
        "status" => "ok",
        "languages" => profile["languages"] || [],
        "package_managers" => profile["package_managers"] || [],
        "commands" =>
          for(
            {key, command} <- Enum.sort(profile["commands"] || %{}),
            is_binary(command),
            into: %{},
            do: {key, command}
          ),
        "tools" => profile["tools"] || %{},
        "test_pairs" => Enum.take(profile["test_pairs"] || [], 150),
        "cochange" => Enum.take(profile["cochange"] || [], 60),
        "practices" => profile["practices"] || %{},
        "hot_files" => hot,
        "fix_hotspots" => fixes,
        "ci_runs" =>
          runs
          |> Enum.filter(&(is_map(&1) and is_binary(&1["command"]) and is_binary(&1["path"])))
          |> Enum.take(40)
          |> Enum.map(&%{"path" => &1["path"], "command" => clip(&1["command"])})
      }
    else
      _ -> %{"status" => "failed", "ci_runs" => []}
    end
  end

  defp clip(text), do: text |> clean_text() |> String.slice(0, 200)

  defp at_head(repo, files, path, limit \\ 256 * 1024) do
    if MapSet.member?(files, path) do
      case Git.show_path(repo, "HEAD", path, max_bytes: limit + 1) do
        {:ok, bytes} when byte_size(bytes) <= limit ->
          if String.valid?(bytes), do: bytes, else: nil

        _ ->
          nil
      end
    end
  end

  defp package_scripts(repo, files) do
    with bytes when is_binary(bytes) <- at_head(repo, files, "package.json"),
         {:ok, %{"scripts" => scripts}} when is_map(scripts) <- Contracts.decode_json(bytes) do
      scripts
      |> Enum.filter(fn {name, command} -> is_binary(command) and byte_size(name) <= 80 end)
      |> Enum.sort()
      |> Enum.take(40)
      |> Enum.map(fn {name, command} -> %{"name" => clip(name), "command" => clip(command)} end)
    else
      _ -> []
    end
  end

  defp pyproject_tools(repo, files) do
    case at_head(repo, files, "pyproject.toml") do
      nil ->
        []

      text ->
        ~r/^\[tool\.([A-Za-z0-9_-]{1,40})[\].]/m
        |> Regex.scan(text, capture: :all_but_first)
        |> List.flatten()
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.take(40)
    end
  end

  # tox.ini sections and env lists, and the same in pyproject.toml's [tool.tox] tables.
  defp tox_envs(repo, files) do
    ini =
      case at_head(repo, files, "tox.ini") do
        nil ->
          []

        text ->
          sections =
            ~r/^\[testenv:([A-Za-z0-9_.,{}-]{1,60})\]/m
            |> Regex.scan(text, capture: :all_but_first)
            |> List.flatten()

          listed =
            ~r/^\s*env_?list\s*=\s*(.*(?:\n[ \t]+.*)*)/m
            |> Regex.scan(text, capture: :all_but_first)
            |> List.flatten()
            |> Enum.flat_map(&String.split(&1, [",", "\n", " ", "\t"], trim: true))

          sections ++ listed
      end

    toml =
      case at_head(repo, files, "pyproject.toml") do
        nil ->
          []

        text ->
          tables =
            ~r/^\[tool\.tox\.env\.([A-Za-z0-9_.-]{1,60})\]/m
            |> Regex.scan(text, capture: :all_but_first)
            |> List.flatten()

          listed =
            ~r/^env_list\s*=\s*\[([^\]]*)\]/m
            |> Regex.scan(text, capture: :all_but_first)
            |> List.flatten()
            |> Enum.flat_map(&Regex.scan(~r/"([^"]{1,60})"/, &1, capture: :all_but_first))
            |> List.flatten()

          tables ++ listed
      end

    (ini ++ toml)
    |> Enum.filter(&Regex.match?(~r/\A[A-Za-z0-9_.{},-]{1,60}\z/, &1))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.take(40)
  end

  defp nox_sessions(repo, files) do
    case at_head(repo, files, "noxfile.py") do
      nil ->
        []

      text ->
        ~r/@nox\.session[^\n]*\n(?:\s*@[^\n]*\n)*\s*def\s+([A-Za-z_][A-Za-z0-9_]{0,60})/
        |> Regex.scan(text, capture: :all_but_first)
        |> List.flatten()
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.take(40)
    end
  end

  defp make_targets(repo, files) do
    case at_head(repo, files, "Makefile") do
      nil ->
        []

      text ->
        ~r/^([A-Za-z0-9][A-Za-z0-9_.-]{0,60}):(?!=)/m
        |> Regex.scan(text, capture: :all_but_first)
        |> List.flatten()
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.take(40)
    end
  end

  # Symbols ----------------------------------------------------------------------------

  @symbol_name ~r/\A[A-Za-z_][A-Za-z0-9_.]{0,79}\z/

  defp symbols(repo, files, commits, fix_diffs) do
    changes =
      commits
      |> Enum.flat_map(&Enum.filter(&1.files, fn path -> Paths.source_path?(path) end))
      |> Enum.filter(&MapSet.member?(files, &1))
      |> Enum.frequencies()

    words =
      fix_diffs
      |> Enum.flat_map(& &1["lines"])
      |> Enum.filter(&String.starts_with?(&1, ["+", "-"]))
      |> Enum.reject(&String.starts_with?(&1, ["+++", "---"]))
      |> Enum.flat_map(&Regex.scan(~r/[A-Za-z_][A-Za-z0-9_]*/, &1))
      |> List.flatten()
      |> Enum.frequencies()

    changes
    |> Enum.sort_by(fn {path, n} -> {-n, path} end)
    |> Enum.take(@symbol_files)
    |> Enum.flat_map(fn {path, n} ->
      case at_head(repo, files, path, @blob_limit) do
        nil ->
          []

        text ->
          text
          |> definitions(language(path))
          |> Enum.map(fn {name, kind, start, stop} ->
            last = name |> String.split(".") |> List.last()

            %{
              "name" => name,
              "path" => path,
              "start" => start,
              "end" => stop,
              "kind" => kind,
              "score" => n + Map.get(words, last, 0)
            }
          end)
      end
    end)
    |> Enum.filter(&Regex.match?(@symbol_name, &1["name"]))
    |> Enum.sort_by(&{-&1["score"], &1["path"], &1["start"]})
    |> Enum.take(@max_symbols)
  end

  defp language(path) do
    case Path.extname(path) do
      ext when ext in ~w(.py .pyi) -> :python
      ext when ext in ~w(.js .jsx .mjs .cjs .ts .tsx) -> :js
      ext when ext in ~w(.ex .exs) -> :elixir
      ".go" -> :go
      ".rb" -> :ruby
      _ -> :other
    end
  end

  @patterns %{
    python: [
      {~r/\A(\s*)(?:async\s+)?def\s+([A-Za-z_][A-Za-z0-9_]*)/, "function"},
      {~r/\A(\s*)class\s+([A-Za-z_][A-Za-z0-9_]*)/, "class"}
    ],
    js: [
      {~r/\A(\s*)(?:export\s+)?(?:default\s+)?(?:async\s+)?function\s*\*?\s*([A-Za-z_$][A-Za-z0-9_$]*)/,
       "function"},
      {~r/\A(\s*)(?:export\s+)?(?:default\s+)?(?:abstract\s+)?class\s+([A-Za-z_$][A-Za-z0-9_$]*)/,
       "class"},
      {~r/\A(\s*)(?:export\s+)?(?:const|let|var)\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*=\s*(?:async\s+)?(?:function\b|\([^)]*\)\s*=>|[A-Za-z_$][A-Za-z0-9_$]*\s*=>)/,
       "function"},
      {~r/\A(\s+)(?:static\s+)?(?:async\s+)?(?!if\b|for\b|while\b|switch\b|catch\b|return\b)([A-Za-z_$][A-Za-z0-9_$]*)\s*\([^)]*\)\s*\{\s*\z/,
       "method"}
    ],
    elixir: [
      {~r/\A(\s*)defmodule\s+([A-Za-z_][A-Za-z0-9_.]*)/, "module"},
      {~r/\A(\s*)defp?\s+([a-z_][A-Za-z0-9_]*)/, "function"}
    ],
    go: [
      {~r/\A()func\s+(?:\([^)]*\)\s*)?([A-Za-z_][A-Za-z0-9_]*)/, "function"},
      {~r/\A()type\s+([A-Za-z_][A-Za-z0-9_]*)/, "type"}
    ],
    ruby: [
      {~r/\A(\s*)def\s+(?:self\.)?([A-Za-z_][A-Za-z0-9_]*)/, "function"},
      {~r/\A(\s*)(?:class|module)\s+([A-Za-z_][A-Za-z0-9_]*)/, "class"}
    ],
    other: []
  }

  # Definitions with line ranges: a definition ends before the next one at the same or a
  # lower indent (trailing blank lines dropped). Methods inside a class are `Class.name`.
  defp definitions(text, language) do
    patterns = Map.fetch!(@patterns, language)
    lines = String.split(text, "\n")
    total = length(lines)

    found =
      lines
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, number} ->
        Enum.find_value(patterns, [], fn {regex, kind} ->
          case Regex.run(regex, line, capture: :all_but_first) do
            [indent, name] -> [{number, String.length(indent), name, kind}]
            _ -> nil
          end
        end)
      end)

    blank =
      lines |> Enum.with_index(1) |> Map.new(fn {line, n} -> {n, String.trim(line) == ""} end)

    found
    |> Enum.with_index()
    |> Enum.map_reduce([], fn {{number, indent, name, kind}, index}, stack ->
      stack = Enum.drop_while(stack, fn {depth, _} -> depth >= indent end)

      qualified =
        case stack do
          [{_, parent} | _] when kind in ["function", "method"] -> parent <> "." <> name
          _ -> name
        end

      stop =
        found
        |> Enum.drop(index + 1)
        |> Enum.find_value(total, fn {next, depth, _, _} -> if depth <= indent, do: next - 1 end)
        |> trim_blank(number, blank)

      kind = if kind == "function" and stack != [], do: "method", else: kind

      stack =
        if kind in ["class", "module", "type"], do: [{indent, qualified} | stack], else: stack

      {{qualified, kind, number, stop}, stack}
    end)
    |> elem(0)
  end

  defp trim_blank(stop, start, blank) do
    if stop > start and Map.get(blank, stop, false),
      do: trim_blank(stop - 1, start, blank),
      else: stop
  end

  # Bounds -----------------------------------------------------------------------------

  # Over the limit, the oldest fix diffs go first, then the oldest commits.
  defp bounded(doc) do
    size = byte_size(Contracts.canonical_json(doc))

    cond do
      size <= @max_bytes ->
        doc

      doc["fix_diffs"] != [] ->
        keep = max(length(doc["fix_diffs"]) - max(div(length(doc["fix_diffs"]), 10), 1), 0)
        bounded(%{doc | "fix_diffs" => Enum.take(doc["fix_diffs"], keep)})

      doc["commits"] != [] ->
        keep = max(length(doc["commits"]) - max(div(length(doc["commits"]), 10), 1), 0)
        commits = Enum.take(doc["commits"], keep)

        repository =
          doc["repository"]
          |> Map.put("history_commits_used", length(commits))
          |> Map.put(
            "history_first_commit_time",
            case List.last(commits) do
              nil -> doc["repository"]["base_commit_time"]
              commit -> commit["time"]
            end
          )

        bounded(%{doc | "commits" => commits, "repository" => repository})

      true ->
        doc
    end
  end

  defp day(time) do
    time |> DateTime.from_unix!() |> DateTime.to_date() |> Date.to_iso8601()
  end
end
