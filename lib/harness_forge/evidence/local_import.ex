defmodule HarnessForge.Evidence.LocalImport do
  @moduledoc "Bounded UTF-8 imports from an explicitly approved local directory; symbolic links are rejected."
  @max_bytes 1_048_576
  @max_files 500
  @max_total_bytes 16_777_216
  @extensions ~w(.md .markdown .txt)

  def approved_directory(path) when is_binary(path) do
    with true <- Path.type(path) == :absolute,
         false <- ".." in Path.split(path),
         :ok <- no_symlink_components(path),
         {:ok, %{type: :directory}} <- File.lstat(path) do
      {:ok, Path.expand(path)}
    else
      _ -> {:error, :unsafe_directory}
    end
  end

  def approved_directory(_), do: {:error, :unsafe_directory}

  def read_all(directory) do
    with {:ok, directory} <- approved_directory(directory),
         {:ok, paths} <- walk(directory, directory, []) do
      Enum.reduce_while(Enum.sort(paths), {:ok, [], 0}, fn path, {:ok, documents, bytes} ->
        case read_file(directory, path) do
          {:ok, document} ->
            total = bytes + byte_size(document["body"])

            if total <= @max_total_bytes,
              do: {:cont, {:ok, [document | documents], total}},
              else: {:halt, {:error, :import_too_large}}

          error ->
            {:halt, error}
        end
      end)
      |> case do
        {:ok, documents, _} -> {:ok, documents}
        error -> error
      end
    end
  end

  def validate_body(body) when is_binary(body) do
    cond do
      byte_size(body) > @max_bytes -> {:error, :file_too_large}
      not String.valid?(body) or String.contains?(body, <<0>>) -> {:error, :binary_file}
      true -> :ok
    end
  end

  def validate_body(_), do: {:error, :invalid_input}

  defp walk(directory, root, accumulator) do
    with {:ok, names} <- File.ls(directory) do
      Enum.reduce_while(Enum.sort(names), {:ok, accumulator}, fn name, {:ok, paths} ->
        path = Path.join(directory, name)

        result =
          with :ok <- contained(root, path),
               {:ok, stat} <- File.lstat(path) do
            case stat.type do
              :symlink ->
                {:error, :symlink_not_allowed}

              :directory ->
                walk(path, root, paths)

              :regular ->
                if Path.extname(path) in @extensions,
                  do: {:ok, [path | paths]},
                  else: {:ok, paths}

              _ ->
                {:error, :unsupported_file}
            end
          end

        case result do
          {:ok, found} when length(found) <= @max_files -> {:cont, {:ok, found}}
          {:ok, _} -> {:halt, {:error, :too_many_files}}
          _ -> {:halt, result}
        end
      end)
    else
      _ -> {:error, :unreadable_directory}
    end
  end

  @doc false
  def read_document(root, path), do: read_file(root, path)

  @doc false
  def inspect_document(root, path) do
    with {:ok, root} <- approved_directory(root),
         :ok <- contained(root, path),
         true <- Path.extname(path) in @extensions,
         :ok <- no_symlink_components(path),
         {:ok, %{type: :regular, size: size} = stat} when size <= @max_bytes <- File.lstat(path) do
      {:ok, %{"size" => size, "fingerprint" => file_identity(stat)}}
    else
      {:ok, %{size: size}} when size > @max_bytes -> {:error, :file_too_large}
      {:error, :symlink_not_allowed} = error -> error
      _ -> {:error, :unreadable_file}
    end
  end

  @doc false
  def read_document(
        root,
        path,
        %{"allowance_bytes" => allowance, "fingerprint" => expected} = bounds
      )
      when is_integer(allowance) and allowance >= 0 and allowance <= @max_bytes and
             map_size(bounds) == 2 do
    with {:ok, observed} <- inspect_document(root, path),
         true <- observed["size"] == allowance and observed["fingerprint"] == expected,
         {:ok, stat} <- File.lstat(path),
         true <- file_identity(stat) == expected,
         {:ok, body} <- bounded_read(path, stat, allowance),
         true <- byte_size(body) == allowance,
         :ok <- validate_body(body) do
      {:ok,
       %{
         "external_id" => Path.relative_to(path, root),
         "title" => Path.basename(path),
         "body" => body
       }}
    else
      false -> {:error, :source_unavailable}
      error -> error
    end
  end

  def read_document(_, _, _), do: {:error, :invalid_input}

  defp file_identity(stat) do
    %{
      "inode" => stat.inode,
      "device" => stat.major_device,
      "size" => stat.size,
      "mtime" => stat.mtime |> NaiveDateTime.from_erl!() |> NaiveDateTime.to_iso8601()
    }
  end

  def read_file(root, path) do
    with {:ok, root} <- approved_directory(root),
         :ok <- contained(root, path),
         true <- Path.extname(path) in @extensions,
         :ok <- no_symlink_components(path),
         {:ok, %{type: :regular, size: size} = stat} when size <= @max_bytes <- File.lstat(path),
         {:ok, body} <- bounded_read(path, stat),
         :ok <- validate_body(body) do
      relative = Path.relative_to(path, root)
      {:ok, %{"external_id" => relative, "title" => Path.basename(relative), "body" => body}}
    else
      {:ok, %{size: size}} when size > @max_bytes -> {:error, :file_too_large}
      {:error, reason} when reason in [:binary_file, :symlink_not_allowed] -> {:error, reason}
      _ -> {:error, :unreadable_file}
    end
  end

  # Match the opened descriptor to the checked inode before reading, then check
  # the path again. A concurrent symlink replacement cannot import another file.
  defp bounded_read(path, expected), do: bounded_read(path, expected, :legacy)

  defp bounded_read(path, expected, allowance) do
    with {:ok, descriptor} <- :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      try do
        with {:ok, record} <- :file.read_file_info(descriptor, time: :universal),
             actual = File.Stat.from_record(record),
             true <- same_file?(actual, expected),
             {:ok, body} <- read_chunk(descriptor, allowance),
             {:ok, after_record} <- :file.read_file_info(descriptor, time: :universal),
             true <- same_file?(File.Stat.from_record(after_record), expected),
             {:ok, current} <- File.lstat(path),
             true <- same_file?(current, expected),
             :ok <- no_symlink_components(path) do
          {:ok, body}
        else
          _ -> {:error, :unreadable_file}
        end
      after
        :file.close(descriptor)
      end
    end
  end

  defp same_file?(actual, expected),
    do:
      actual.type == :regular and actual.inode == expected.inode and
        actual.major_device == expected.major_device and actual.size == expected.size and
        actual.mtime == expected.mtime

  defp read_chunk(descriptor, :legacy) do
    case :file.read(descriptor, @max_bytes + 1) do
      :eof -> {:ok, ""}
      other -> other
    end
  end

  defp read_chunk(_, 0), do: {:ok, ""}

  defp read_chunk(descriptor, allowance) do
    case :file.read(descriptor, allowance) do
      :eof -> {:ok, ""}
      result -> result
    end
  end

  defp contained(root, path) do
    if String.starts_with?(Path.expand(path), root <> "/"), do: :ok, else: {:error, :path_escape}
  end

  defp no_symlink_components(path) do
    Path.expand(path)
    |> Path.split()
    |> Enum.reduce_while("", fn part, previous ->
      current = if previous == "", do: part, else: Path.join(previous, part)

      case File.lstat(current) do
        {:ok, %{type: :symlink}} -> {:halt, {:error, :symlink_not_allowed}}
        {:ok, _} -> {:cont, current}
        _ -> {:halt, {:error, :unreadable_file}}
      end
    end)
    |> case do
      {:error, _} = error -> error
      _ -> :ok
    end
  end
end
