defmodule HarnessForge.Graphiti.Image do
  @moduledoc "Outside-worker verification of immutable application bytes; never starts the image."
  alias HarnessForge.{Contracts, Evidence.Store}
  alias HarnessForge.Execution.Command
  alias HarnessForge.Models.Stages

  @limit 8_388_608
  @invalid {:error, :graph_image_mismatch}

  def verify(endpoint, "sha256:" <> digest = image) do
    with true <- Stages.digest?(digest),
         {:ok, expected} <- source_pins(),
         {:ok, metadata} <- inspect_image(endpoint, image),
         {:ok, %{exit_status: 0, output: output}} <-
           Command.docker_at(endpoint, [
             "create",
             "--pull",
             "never",
             "--network",
             "none",
             "--read-only",
             "--user",
             "65532:65532",
             "--cap-drop",
             "ALL",
             "--security-opt",
             "no-new-privileges:true",
             "--label",
             "dev.harnessforge.source-check=" <> Ecto.UUID.generate(),
             image
           ]),
         id = String.trim(output),
         true <- Stages.digest?(id) do
      try do
        with {:ok, %{exit_status: 0, output: bytes}} <-
               Command.docker_at(endpoint, ["cp", id <> ":/app/.", "-"], 15_000, @limit),
             {:ok, pins} <- verify_archive(bytes, expected),
             {:ok, %{exit_status: 0, output: state}} <-
               Command.docker_at(endpoint, ["inspect", "--format", "{{json .State}}", id]),
             {:ok, %{"Status" => "created", "Running" => false}} <- Jason.decode(state) do
          {:ok,
           Map.merge(metadata, %{
             "source_pins" => pins,
             "source_digest" => Contracts.digest(pins),
             "archive_digest" => Store.hash(bytes),
             "verification" => "outside-worker-never-started-v1"
           })}
        else
          _ -> @invalid
        end
      after
        Command.docker_at(endpoint, ["rm", "-f", id])
      end
    else
      _ -> @invalid
    end
  rescue
    _ -> @invalid
  end

  def verify(_, _), do: @invalid

  def source_pins do
    root = Application.app_dir(:harness_forge, "priv/graphiti_worker")
    entries = Path.wildcard(Path.join(root, "**/*"), match_dot: true)

    if length(entries) in 1..128 do
      Enum.reduce_while(entries, {:ok, %{}}, fn path, {:ok, acc} ->
        case File.lstat(path) do
          {:ok, %{type: :directory}} ->
            {:cont, {:ok, acc}}

          {:ok, %{type: :regular, size: size}} when size <= @limit ->
            case File.read(path) do
              {:ok, bytes} ->
                {:cont, {:ok, Map.put(acc, Path.relative_to(path, root), Store.hash(bytes))}}

              _ ->
                {:halt, @invalid}
            end

          _ ->
            {:halt, @invalid}
        end
      end)
    else
      @invalid
    end
  end

  # Memory-only extraction follows a complete bounded header/type/path check.
  # No archive path is ever written to the filesystem.
  def verify_archive(bytes, expected)
      when is_binary(bytes) and byte_size(bytes) <= @limit and is_map(expected) do
    with true <- map_size(expected) in 1..128,
         {:ok, entries} <- :erl_tar.table({:binary, bytes}, [:verbose]),
         true <- length(entries) in 1..256,
         true <- Enum.all?(entries, &safe_header?/1),
         files = Enum.filter(entries, &(elem(&1, 1) == :regular)),
         paths = Enum.map(files, &normalize(elem(&1, 0))),
         true <- length(paths) == length(Enum.uniq(paths)),
         true <- Enum.sum(Enum.map(files, &elem(&1, 2))) <= @limit,
         true <- Enum.sort(paths) == Enum.sort(Map.keys(expected)),
         {:ok, extracted} <- :erl_tar.extract({:binary, bytes}, [:memory]),
         pins = Map.new(extracted, fn {path, value} -> {normalize(path), Store.hash(value)} end),
         true <- pins == expected do
      {:ok, pins}
    else
      _ -> @invalid
    end
  rescue
    _ -> @invalid
  end

  def verify_archive(_, _), do: @invalid

  defp inspect_image(endpoint, image) do
    with {:ok, %{exit_status: 0, output: bytes}} <-
           Command.docker_at(endpoint, ["image", "inspect", image], 10_000, 131_072),
         {:ok, [%{"Id" => ^image, "Config" => config} = actual]} <- Jason.decode(bytes),
         true <- actual["Os"] == "linux" and actual["Architecture"] in ["arm64", "amd64"],
         true <- config["Entrypoint"] == ["python", "-I", "/app/__main__.py"],
         true <- is_nil(config["Cmd"]) and is_nil(config["Volumes"]),
         true <- config["User"] == "65532:65532" and config["WorkingDir"] == "/app",
         env when is_list(env) <- config["Env"],
         true <- length(env) <= 256 and Enum.all?(env, &is_binary/1) do
      {:ok,
       %{
         "image_id" => image,
         "image_env_digest" => Contracts.digest(Enum.sort(env)),
         "image_config_digest" =>
           Contracts.digest(Map.take(config, ~w(Entrypoint Cmd Volumes User WorkingDir Env))),
         "architecture" => actual["Architecture"]
       }}
    else
      _ -> @invalid
    end
  end

  defp safe_header?({path, type, size, _, mode, _, _}) when type in [:regular, :directory] do
    name = normalize(path)

    is_integer(size) and size >= 0 and size <= @limit and is_integer(mode) and
      Bitwise.band(mode, 0o6000) == 0 and
      ((type == :directory and name in ["", "."]) or safe_path?(name))
  end

  defp safe_header?(_), do: false

  defp normalize(path),
    do: path |> List.to_string() |> String.replace_prefix("./", "") |> String.trim_trailing("/")

  defp safe_path?(path) do
    String.valid?(path) and byte_size(path) in 1..512 and not String.starts_with?(path, "/") and
      not String.contains?(path, ["\\", <<0>>]) and
      Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."]))
  end
end
