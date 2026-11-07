defmodule HarnessForge.Privacy.Files do
  @moduledoc false
  @max_files 20_000
  @max_bytes 1_073_741_824

  def absolute(path) when is_binary(path) do
    if Path.type(path) == :absolute and path != "/" and byte_size(path) < 4096 and
         not String.contains?(path, ["\\", <<0>>]) and
         Enum.all?(String.split(path, "/", trim: true), &(&1 not in [".", ".."])) do
      :ok
    else
      {:error, :unsafe_path}
    end
  end

  def absolute(_), do: {:error, :unsafe_path}

  def directory(path) do
    with :ok <- absolute(path) do
      Path.split(path)
      |> Enum.reduce_while({:ok, ""}, fn part, {:ok, parent} ->
        next = if part == "/", do: "/", else: Path.join(parent, part)

        case File.lstat(next) do
          {:ok, %{type: :directory}} -> {:cont, {:ok, next}}
          _ -> {:halt, {:error, :unsafe_path}}
        end
      end)
      |> case do
        {:ok, _} -> :ok
        error -> error
      end
    end
  end

  def fresh(path) do
    with :ok <- absolute(path),
         :ok <- directory(Path.dirname(path)),
         {:error, :enoent} <- File.lstat(path) do
      :ok
    else
      {:ok, _} -> {:error, :target_exists}
      error -> error
    end
  end

  def relative(path) when is_binary(path) do
    if Path.type(path) == :relative and not String.contains?(path, ["\\", <<0>>]) and
         Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."])) do
      :ok
    else
      {:error, :unsafe_path}
    end
  end

  def relative(_), do: {:error, :unsafe_path}

  def tree(path) do
    with :ok <- directory(path),
         {:ok, entries, _bytes} <- scan(path, "", [], 0),
         do: {:ok, Enum.sort(entries)}
  end

  defp scan(base, relative, entries, bytes) do
    with true <- length(entries) <= @max_files and bytes <= @max_bytes,
         {:ok, children} <- File.ls(Path.join(base, relative)) do
      Enum.reduce_while(children, {:ok, entries, bytes}, fn child, {:ok, acc, total} ->
        child = Path.join(relative, child)
        path = Path.join(base, child)

        result =
          case File.lstat(path) do
            {:ok, %{type: :regular, size: size}} ->
              if length(acc) < @max_files and total + size <= @max_bytes,
                do: {:ok, [child | acc], total + size},
                else: {:error, :inventory_limit}

            {:ok, %{type: :directory}} ->
              scan(base, child, acc, total)

            _ ->
              {:error, :unsafe_path}
          end

        case result do
          {:ok, _, _} -> {:cont, result}
          error -> {:halt, error}
        end
      end)
    else
      false -> {:error, :inventory_limit}
      _ -> {:error, :unsafe_path}
    end
  end

  # Callers supply only fixed owned paths or paths from a validated persisted plan.
  # Never follows links, including links found during retry after a partial delete.
  def remove_owned(root, relative) do
    with :ok <- directory(root), :ok <- relative(relative) do
      path = Path.join(root, relative)

      case parent_chain(Path.dirname(path)) do
        :ok -> remove(path)
        :missing -> :ok
        error -> error
      end
    end
  end

  defp parent_chain(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        directory(path)

      {:error, :enoent} ->
        case parent_chain(Path.dirname(path)) do
          :ok -> :missing
          result -> result
        end

      _ ->
        {:error, :unsafe_path}
    end
  end

  defp remove(path) do
    case File.lstat(path) do
      {:error, :enoent} ->
        :ok

      {:ok, %{type: :regular}} ->
        File.rm(path)

      {:ok, %{type: :directory}} ->
        with {:ok, children} <- File.ls(path),
             :ok <-
               Enum.reduce_while(children, :ok, fn name, :ok ->
                 case remove(Path.join(path, name)) do
                   :ok -> {:cont, :ok}
                   error -> {:halt, error}
                 end
               end),
             do: File.rmdir(path)

      _ ->
        {:error, :unsafe_path}
    end
  end

  def write(path, bytes) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- directory(Path.dirname(path)),
         {:ok, io} <- File.open(path, [:write, :binary, :exclusive]) do
      try do
        with :ok <- File.chmod(path, 0o600), :ok <- IO.binwrite(io, bytes), do: :file.sync(io)
      after
        File.close(io)
      end
    end
  end

  def stage(target, fun) do
    stage = Path.join(Path.dirname(target), ".harnessforge-private-" <> Ecto.UUID.generate())

    with :ok <- fresh(target), :ok <- File.mkdir(stage), :ok <- File.chmod(stage, 0o700) do
      try do
        with {:ok, result} <- fun.(stage),
             :ok <- fresh(target),
             :ok <- File.rename(stage, target),
             do: {:ok, result}
      after
        remove(stage)
      end
    end
  end
end
