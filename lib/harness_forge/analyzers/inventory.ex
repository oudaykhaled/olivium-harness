defmodule HarnessForge.Analyzers.Inventory do
  @moduledoc """
  The list of files an analysis may look at, and bounded reads of the few it opens.

  A git repository is listed through `Git.ls_files/2`, which honours `.gitignore`.
  A plain directory falls back to a walk that skips dependency and build directories,
  follows no symlink and applies the simple patterns of a root `.gitignore`. Secret-like
  paths never enter the list. File contents are data and are never executed.
  """

  alias HarnessForge.Analyzers.{Git, Privacy}
  alias HarnessForge.Contracts

  @max_files 20_000
  @max_reads 160
  @max_bytes 256 * 1024
  @max_depth 12
  @skipped_directories ~w(.git node_modules _build deps dist build target vendor .venv venv __pycache__ .tox .nox .mypy_cache .pytest_cache .ruff_cache .next coverage .terraform .idea .vscode)

  defstruct root: nil, repo: nil, source: "walk", files: [], secret_paths: [], truncated: false

  @type t :: %__MODULE__{}

  @spec build(String.t(), Git.t() | nil, keyword()) :: t()
  def build(root, repo, opts \\ []) do
    limit = bounded(opts[:max_files], @max_files)

    {source, listed} =
      case repo && list_git(repo, opts) do
        {:ok, paths} -> {"git", paths}
        _ -> {"walk", walk(root)}
      end

    paths = Enum.filter(listed, &representable?/1)
    {secret, visible} = Enum.split_with(paths, &Privacy.secret_path?/1)

    %__MODULE__{
      root: root,
      repo: repo,
      source: source,
      files: Enum.take(visible, limit),
      secret_paths: secret,
      truncated: length(visible) > limit
    }
  end

  @doc """
  Read `paths` as text and return `{contents_by_path, counters}`. Each file is capped
  in size, the number of files is capped, and binary or non-UTF-8 files are skipped.
  """
  @spec load(t(), [String.t()]) :: {%{String.t() => String.t()}, map()}
  def load(%__MODULE__{} = inventory, paths) do
    known = MapSet.new(inventory.files)
    wanted = paths |> Enum.uniq() |> Enum.filter(&MapSet.member?(known, &1)) |> Enum.sort()
    {selected, dropped} = Enum.split(wanted, @max_reads)

    initial =
      {%{}, %{"oversize" => 0, "binary" => 0, "unreadable" => 0, "over_limit" => length(dropped)}}

    Enum.reduce(selected, initial, fn path, {contents, counters} ->
      case read(inventory.root, path) do
        {:ok, text} -> {Map.put(contents, path, text), counters}
        {:skip, counter} -> {contents, Map.update!(counters, counter, &(&1 + 1))}
      end
    end)
  end

  @doc """
  Read one listed file as text with the same checks as `load/2` (secret paths, a
  regular file, at most `max_bytes`, UTF-8 without NUL bytes), for an analyzer with its
  own bounded read set. Returns `{:ok, text}` or `{:skip, counter}`, where the counter
  is one of `"oversize"`, `"binary"`, `"unreadable"`.
  """
  @spec read_text(t(), String.t(), pos_integer()) :: {:ok, String.t()} | {:skip, String.t()}
  def read_text(%__MODULE__{} = inventory, path, max_bytes)
      when is_binary(path) and is_integer(max_bytes) and max_bytes > 0 do
    read(inventory.root, path, min(max_bytes, @max_bytes))
  end

  defp read(root, path, max_bytes \\ @max_bytes) do
    if Privacy.secret_path?(path) or resolves_to_secret?(root, path) do
      {:skip, "unreadable"}
    else
      case Git.read_file(root, path, max_bytes: max_bytes) do
        {:ok, bytes} -> classify(bytes)
        {:error, %{code: "file_too_large"}} -> {:skip, "oversize"}
        {:error, _} -> {:skip, "unreadable"}
      end
    end
  end

  # A listed link can point at a file that was never listed, so the target is what counts.
  defp resolves_to_secret?(root, path) do
    case Git.safe_path(root, path) do
      {:ok, resolved} -> Privacy.secret_path?(Path.relative_to(resolved, root))
      {:error, _} -> false
    end
  end

  defp classify(bytes) do
    if String.contains?(bytes, <<0>>) or not String.valid?(bytes),
      do: {:skip, "binary"},
      else: {:ok, bytes}
  end

  # A repository with no commits has an empty index, so its working files are listed
  # with the ones .gitignore excludes left out. Otherwise only tracked files count,
  # which keeps the result a function of committed state plus its content.
  defp list_git(repo, opts) do
    others = match?({:ok, nil}, Git.head(repo))
    Git.ls_files(repo, Keyword.put(Keyword.take(opts, [:timeout_ms]), :others, others))
  end

  @doc "True when a path can appear in a signals document."
  @spec representable?(String.t()) :: boolean()
  def representable?(path) do
    Contracts.relative_path?(path) and byte_size(path) <= 1024 and
      not Regex.match?(~r/[\x00-\x1f\x7f\\]/, path)
  end

  defp walk(root) do
    ignored = ignore_patterns(root)
    root |> descend("", 0, ignored, []) |> Enum.sort()
  end

  defp descend(_root, _relative, depth, _ignored, acc) when depth > @max_depth, do: acc

  defp descend(root, relative, depth, ignored, acc) do
    case File.ls(Path.join(root, relative)) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.reduce(acc, fn name, found ->
          visit(root, join(relative, name), name, depth, ignored, found)
        end)

      _ ->
        acc
    end
  end

  defp visit(_root, _path, name, _depth, _ignored, found)
       when name in @skipped_directories,
       do: found

  defp visit(_root, _path, _name, _depth, _ignored, found) when length(found) > @max_files + 1,
    do: found

  defp visit(root, path, _name, depth, ignored, found) do
    if ignored?(path, ignored) do
      found
    else
      case File.lstat(Path.join(root, path)) do
        {:ok, %File.Stat{type: :directory}} -> descend(root, path, depth + 1, ignored, found)
        {:ok, %File.Stat{type: :regular}} -> [path | found]
        _ -> found
      end
    end
  end

  defp join("", name), do: name
  defp join(parent, name), do: parent <> "/" <> name

  defp ignore_patterns(root) do
    case Git.read_file(root, ".gitignore", max_bytes: @max_bytes) do
      {:ok, text} ->
        text
        |> String.split(~r/\r?\n/)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == "" or String.starts_with?(&1, ["#", "!"])))
        |> Enum.map(&ignore_regex/1)

      _ ->
        []
    end
  end

  # Covers plain names, trailing-slash directories and `*` globs, which is enough for
  # the fallback walk. Negation and `**` are left unsupported.
  defp ignore_regex(pattern) do
    body = pattern |> String.trim_trailing("/") |> String.trim_leading("/")
    escaped = body |> Regex.escape() |> String.replace("\\*", "[^/]*")

    if String.contains?(body, "/") do
      Regex.compile!("\\A" <> escaped <> "(?:/.*)?\\z")
    else
      Regex.compile!("(?:\\A|/)" <> escaped <> "(?:/.*)?\\z")
    end
  end

  defp ignored?(path, patterns), do: Enum.any?(patterns, &Regex.match?(&1, path))

  defp bounded(value, maximum) when is_integer(value) and value > 0, do: min(value, maximum)
  defp bounded(_, maximum), do: maximum
end
