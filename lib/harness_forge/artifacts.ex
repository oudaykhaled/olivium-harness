defmodule HarnessForge.Artifacts do
  @moduledoc """
  Immutable content-addressed artifacts under the owned workspace directory.

  A complete private stage is verified before atomic rename publishes it.
  Exports contain runtime files only and require a fresh absolute target with
  existing nonsymlink parents. Existing files/directories are never overwritten.
  The owning workspace process excludes competing OS processes; in-VM operations
  serialize by destination. Like ordinary local files, this is not protection
  against a hostile process with the operator's filesystem permissions.

  `:root` is a trusted embedding/test option; UI input must not control it.
  """
  alias HarnessForge.{Compiler, Contracts, Workspaces}
  alias HarnessForge.Contracts.Error

  @max_stored_bytes 16_000_000

  @spec publish(map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def publish(artifact, opts \\ []) do
    with :ok <- Compiler.verify(artifact),
         :ok <- valid_files(artifact["files"]),
         {:ok, store} <- store_root(opts) do
      destination = Path.join(store, artifact["digest"])
      synchronized(destination, fn -> publish_at(artifact, store, destination) end)
    end
  end

  @spec read(String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def read(digest, opts \\ []) do
    with :ok <- valid_digest(digest),
         {:ok, store} <- store_root(opts) do
      read_at(Path.join(store, digest), digest)
    end
  end

  @doc "List all persisted artifacts after verifying their metadata and payload bytes."
  @spec list(keyword()) :: {:ok, [map()]} | {:error, Error.t()}
  def list(opts \\ []) do
    with {:ok, store} <- store_root(opts),
         {:ok, entries} <- File.ls(store) do
      entries
      |> Enum.reject(&String.starts_with?(&1, ".stage-"))
      |> Enum.sort()
      |> Enum.reduce_while({:ok, []}, fn digest, {:ok, acc} ->
        case read(digest, opts) do
          {:ok, artifact} -> {:cont, {:ok, [artifact | acc]}}
          failure -> {:halt, failure}
        end
      end)
      |> case do
        {:ok, values} -> {:ok, Enum.reverse(values)}
        failure -> failure
      end
    else
      {:error, %Error{} = reason} -> {:error, reason}
      _ -> error("artifact_io_error", "Cannot list artifacts")
    end
  end

  @spec export(map() | String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def export(artifact_or_digest, target, opts \\ []) do
    with {:ok, artifact} <- resolve(artifact_or_digest, opts),
         :ok <- Compiler.verify(artifact),
         :ok <- valid_files(artifact["files"]),
         :ok <- valid_target(target),
         :ok <- existing_directory(Path.dirname(target)) do
      synchronized(target, fn -> export_at(artifact, target) end)
    end
  end

  defp resolve(digest, opts) when is_binary(digest), do: read(digest, opts)
  defp resolve(artifact, _) when is_map(artifact), do: {:ok, artifact}
  defp resolve(_, _), do: error("invalid_artifact", "Expected an artifact or content digest")

  defp publish_at(artifact, store, destination) do
    case File.lstat(destination) do
      {:error, :enoent} ->
        stage = Path.join(store, ".stage-" <> unique_suffix())

        with_stage(stage, fn ->
          with :ok <- write_stage(stage, artifact),
               {:ok, ^artifact} <- read_at(stage, artifact["digest"]),
               :ok <- absent(destination),
               :ok <- rename(stage, destination) do
            {:ok, location(artifact, destination)}
          end
        end)

      {:ok, %File.Stat{type: :directory}} ->
        case read_at(destination, artifact["digest"]) do
          {:ok, ^artifact} ->
            {:ok, location(artifact, destination)}

          _ ->
            error("artifact_conflict", "Existing content-addressed artifact failed verification")
        end

      _ ->
        error("unsafe_artifact_path", "Artifact destination is not a safe directory")
    end
  end

  defp export_at(artifact, target) do
    stage = Path.join(Path.dirname(target), ".harnessforge-export-" <> unique_suffix())

    with :ok <- absent(target) do
      with_stage(stage, fn ->
        with :ok <- write_files(stage, artifact["files"]),
             :ok <- verify_payload(stage, artifact["files"]),
             :ok <- existing_directory(Path.dirname(target)),
             :ok <- absent(target),
             :ok <- rename(stage, target) do
          {:ok, location(artifact, target)}
        end
      end)
    end
  end

  defp write_stage(stage, artifact) do
    with :ok <- write_file(Path.join(stage, "artifact.json"), Contracts.canonical_json(artifact)),
         :ok <- create_directory(Path.join(stage, "payload")) do
      write_files(Path.join(stage, "payload"), artifact["files"])
    end
  end

  defp write_files(base, files) do
    files
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while(:ok, fn {relative, bytes}, :ok ->
      path = Path.join(base, relative)

      case with :ok <- ensure_directory(Path.dirname(path)), do: write_file(path, bytes) do
        :ok -> {:cont, :ok}
        failure -> {:halt, failure}
      end
    end)
  end

  defp read_at(path, digest) do
    metadata = Path.join(path, "artifact.json")

    with :ok <- existing_directory(path),
         :ok <- regular_file(metadata, @max_stored_bytes),
         {:ok, bytes} <- File.read(metadata),
         {:ok, artifact} <- Jason.decode(bytes),
         :ok <- Compiler.verify(artifact),
         true <- artifact["digest"] == digest,
         :ok <- valid_files(artifact["files"]),
         :ok <- verify_payload(Path.join(path, "payload"), artifact["files"]),
         {:ok, entries} <- File.ls(path),
         true <- Enum.sort(entries) == ["artifact.json", "payload"] do
      {:ok, artifact}
    else
      {:error, %Error{} = reason} ->
        {:error, reason}

      _ ->
        error("invalid_artifact", "Stored artifact is missing or failed integrity verification")
    end
  end

  defp verify_payload(base, files) do
    with :ok <- existing_directory(base),
         {:ok, paths} <- regular_tree(base, ""),
         true <- Enum.sort(paths) == Enum.sort(Map.keys(files)) do
      Enum.reduce_while(files, :ok, fn {relative, expected}, :ok ->
        path = Path.join(base, relative)

        case with :ok <- regular_file(path, byte_size(expected)),
                  {:ok, ^expected} <- File.read(path),
                  do: :ok do
          :ok -> {:cont, :ok}
          _ -> {:halt, error("invalid_artifact", "Artifact payload does not match its manifest")}
        end
      end)
    else
      _ -> error("invalid_artifact", "Artifact payload contains missing, extra or unsafe files")
    end
  end

  defp regular_tree(base, relative) do
    case File.ls(Path.join(base, relative)) do
      {:ok, entries} ->
        Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
          child = if relative == "", do: entry, else: Path.join(relative, entry)

          case File.lstat(Path.join(base, child)) do
            {:ok, %File.Stat{type: :regular}} ->
              {:cont, {:ok, [child | acc]}}

            {:ok, %File.Stat{type: :directory}} ->
              case regular_tree(base, child) do
                {:ok, children} -> {:cont, {:ok, children ++ acc}}
                failure -> {:halt, failure}
              end

            _ ->
              {:halt, error("unsafe_artifact_path", "Symlinks and special files are forbidden")}
          end
        end)

      _ ->
        error("invalid_artifact", "Artifact payload cannot be read")
    end
  end

  defp store_root(opts) do
    root = Keyword.get(opts, :root, Workspaces.root())

    if is_binary(root) and Path.type(root) == :absolute do
      store = Path.join(Path.expand(root), "artifacts")
      with :ok <- ensure_directory(store), do: {:ok, store}
    else
      error("unsafe_artifact_path", "Workspace root must be absolute")
    end
  end

  defp valid_files(files) when is_map(files) and map_size(files) > 0 do
    if Enum.all?(files, fn {path, bytes} -> safe_relative?(path) and is_binary(bytes) end),
      do: :ok,
      else: error("unsafe_artifact_path", "Artifact filenames must be contained relative paths")
  end

  defp valid_files(_), do: error("invalid_artifact", "Artifact must contain files")

  defp safe_relative?(path) when is_binary(path) do
    Path.type(path) == :relative and not String.contains?(path, ["\\", <<0>>]) and
      Enum.all?(
        String.split(path, "/"),
        &(&1 not in ["", ".", ".."] and Regex.match?(~r/^[a-zA-Z0-9_.-]+$/, &1))
      )
  end

  defp safe_relative?(_), do: false

  defp valid_digest(digest) when is_binary(digest) do
    if Regex.match?(~r/^[a-f0-9]{64}$/, digest),
      do: :ok,
      else: error("invalid_artifact_digest", "Expected a lowercase SHA-256 artifact digest")
  end

  defp valid_digest(_), do: error("invalid_artifact_digest", "Expected an artifact digest")

  defp valid_target(target) when is_binary(target) do
    if Path.type(target) == :absolute and target != "/" and
         not String.contains?(target, ["\\", <<0>>]) and
         Enum.all?(String.split(target, "/", trim: true), &(&1 not in [".", ".."])),
       do: :ok,
       else:
         error("unsafe_artifact_path", "Export target must be a fresh absolute contained path")
  end

  defp valid_target(_),
    do: error("unsafe_artifact_path", "Export target must be an absolute path")

  defp ensure_directory(path), do: walk_directories(path, true)
  defp existing_directory(path), do: walk_directories(path, false)

  defp walk_directories(path, create?) do
    Path.split(Path.expand(path))
    |> Enum.reduce_while({:ok, ""}, fn component, {:ok, parent} ->
      current = if component == "/", do: "/", else: Path.join(parent, component)

      result =
        case File.lstat(current) do
          {:ok, %File.Stat{type: :directory}} ->
            :ok

          {:error, :enoent} when create? ->
            create_directory(current)

          _ ->
            error(
              "unsafe_artifact_path",
              "Directory path contains a symlink, special file or missing parent"
            )
        end

      case result do
        :ok -> {:cont, {:ok, current}}
        failure -> {:halt, failure}
      end
    end)
    |> case do
      {:ok, _} -> :ok
      failure -> failure
    end
  end

  defp create_directory(path) do
    case File.mkdir(path) do
      :ok -> File.chmod(path, 0o700) |> io_result()
      {:error, :eexist} -> existing_directory(path)
      _ -> error("artifact_io_error", "Cannot create artifact directory")
    end
  end

  defp write_file(path, bytes) do
    case File.open(path, [:write, :binary, :exclusive]) do
      {:ok, device} ->
        try do
          with :ok <- File.chmod(path, 0o600),
               :ok <- IO.binwrite(device, bytes),
               :ok <- :file.sync(device),
               do: :ok
        after
          File.close(device)
        end
        |> io_result()

      _ ->
        error("artifact_io_error", "Cannot exclusively write artifact file")
    end
  end

  defp regular_file(path, max_bytes) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= max_bytes -> :ok
      _ -> error("invalid_artifact", "Artifact file is missing, oversized or unsafe")
    end
  end

  defp absent(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      _ -> error("export_conflict", "Destination already exists; choose a fresh directory")
    end
  end

  defp with_stage(stage, fun) do
    case File.mkdir(stage) do
      :ok ->
        try do
          with :ok <- File.chmod(stage, 0o700), do: fun.()
        after
          File.rm_rf(stage)
        end

      _ ->
        error("artifact_io_error", "Cannot create private artifact stage")
    end
  end

  defp rename(stage, target), do: File.rename(stage, target) |> io_result()
  defp io_result(:ok), do: :ok
  defp io_result(_), do: error("artifact_io_error", "Filesystem operation failed")
  defp location(artifact, path), do: %{"digest" => artifact["digest"], "path" => path}
  defp unique_suffix, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  defp synchronized(path, fun), do: :global.trans({{__MODULE__, path}, self()}, fun)
  defp error(code, message), do: {:error, %Error{code: code, message: message}}
end
