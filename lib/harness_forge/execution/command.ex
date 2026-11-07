defmodule HarnessForge.Execution.Command do
  @moduledoc false

  @overrides ~w(DOCKER_CONTEXT DOCKER_HOST DOCKER_TLS DOCKER_TLS_VERIFY DOCKER_CERT_PATH DOCKER_API_VERSION)

  # Offline execution resolves its own endpoint; coding uses only docker_at.
  def docker(args, timeout \\ 10_000, output_limit \\ 65_536) do
    with {:ok, endpoint} <- local_endpoint(),
         do: docker_at(endpoint, args, timeout, output_limit)
  end

  @spec docker_at(String.t(), [String.t()], pos_integer(), pos_integer()) ::
          {:ok, map()} | {:error, atom()}
  def docker_at(endpoint, args, timeout \\ 10_000, output_limit \\ 65_536) do
    with true <- valid_endpoint?(endpoint) and safe_args?(args) do
      case System.find_executable("docker") do
        nil ->
          {:error, :docker_unavailable}

        executable ->
          invoke(executable, ["--host", endpoint] ++ args, timeout, output_limit)
      end
    else
      _ -> {:error, :local_docker_required}
    end
  end

  @spec local_endpoint() :: {:ok, String.t()} | {:error, atom()}
  def local_endpoint do
    context = System.get_env("DOCKER_CONTEXT")
    host = System.get_env("DOCKER_HOST")

    resolved =
      cond do
        context not in [nil, ""] -> resolve_context(context)
        host not in [nil, ""] -> {:ok, host}
        true -> resolve_context(nil)
      end

    case resolved do
      {:ok, endpoint} ->
        if valid_endpoint?(endpoint), do: {:ok, endpoint}, else: {:error, :local_docker_required}

      error ->
        error
    end
  end

  defp resolve_context(context) do
    valid =
      is_nil(context) or
        (is_binary(context) and byte_size(context) in 1..128 and
           Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/, context))

    with true <- valid,
         executable when is_binary(executable) <- System.find_executable("docker"),
         args = ["context", "inspect"] ++ if(context, do: [context], else: []),
         {:ok, %{exit_status: 0, output: bytes}} <-
           invoke(
             executable,
             args ++ ["--format", "{{json .Endpoints.docker.Host}}"],
             3_000,
             4_096
           ),
         {:ok, endpoint} <- Jason.decode(bytes) do
      {:ok, endpoint}
    else
      false -> {:error, :local_docker_required}
      _ -> {:error, :docker_unavailable}
    end
  end

  def valid_endpoint?(endpoint) when is_binary(endpoint) and byte_size(endpoint) <= 4_096 do
    String.valid?(endpoint) and Regex.match?(~r/\Aunix:\/\/\/[A-Za-z0-9._~\/-]+\z/, endpoint) and
      endpoint
      |> String.replace_prefix("unix:///", "")
      |> String.split("/")
      |> Enum.all?(&(&1 not in ["", ".", ".."]))
  end

  def valid_endpoint?(_), do: false

  defp safe_args?(args) when is_list(args) do
    Enum.all?(args, fn arg ->
      is_binary(arg) and not String.contains?(arg, <<0>>) and
        not Enum.any?(
          ~w(--host --context --config -H),
          &(&1 == arg or String.starts_with?(arg, &1 <> "="))
        ) and
        not String.starts_with?(arg, "-H")
    end)
  end

  defp safe_args?(_), do: false

  defp invoke(executable, args, timeout, limit) do
    port =
      Port.open({:spawn_executable, String.to_charlist(executable)}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :use_stdio,
        args: Enum.map(args, &String.to_charlist/1),
        env: Enum.map(@overrides, &{String.to_charlist(&1), false})
      ])

    collect(port, System.monotonic_time(:millisecond) + timeout, limit, "")
  rescue
    ArgumentError -> {:error, :docker_unavailable}
    ErlangError -> {:error, :docker_unavailable}
  end

  defp collect(port, deadline, limit, output) do
    if System.monotonic_time(:millisecond) >= deadline do
      close(port)
      {:error, :timed_out}
    else
      receive do
        {^port, {:data, bytes}} ->
          if byte_size(output) + byte_size(bytes) > limit do
            close(port)
            {:error, :output_limit}
          else
            collect(port, deadline, limit, output <> bytes)
          end

        {^port, {:exit_status, status}} ->
          {:ok, %{output: output, exit_status: status}}
      after
        max(deadline - System.monotonic_time(:millisecond), 0) ->
          close(port)
          {:error, :timed_out}
      end
    end
  end

  defp close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end
end
