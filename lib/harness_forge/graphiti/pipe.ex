defmodule HarnessForge.Graphiti.Pipe do
  @moduledoc false
  alias HarnessForge.{Contracts, Models.Stages}
  alias HarnessForge.Execution.Command

  @overrides ~w(DOCKER_CONTEXT DOCKER_HOST DOCKER_TLS DOCKER_TLS_VERIFY DOCKER_CERT_PATH DOCKER_API_VERSION)

  # Only root-owned, already-created containers may be attached. No shell,
  # stdin file, credential argv, stderr merging, or Erlang packet framing.
  def attach(endpoint, container_id) do
    open(endpoint, container_id, ["start", "--attach", "--interactive", container_id])
  end

  def watch(endpoint, container_id), do: open(endpoint, container_id, ["wait", container_id])

  defp open(endpoint, container_id, args) do
    with true <- Command.valid_endpoint?(endpoint) and Stages.digest?(container_id),
         executable when is_binary(executable) <- System.find_executable("docker") do
      {:ok,
       Port.open({:spawn_executable, String.to_charlist(executable)}, [
         :binary,
         :exit_status,
         :use_stdio,
         :eof,
         args:
           Enum.map(
             ["--host", endpoint] ++ args,
             &String.to_charlist/1
           ),
         env: Enum.map(@overrides, &{String.to_charlist(&1), false})
       ])}
    else
      _ -> {:error, :worker_lost}
    end
  rescue
    _ -> {:error, :worker_lost}
  end

  def exchange(port, request, timeout \\ 35_000, request_limit \\ 131_072) do
    with true <- is_port(port) and is_map(request),
         bytes = Contracts.canonical_json(request),
         true <- request_limit in [131_072, 524_288] and byte_size(bytes) in 1..request_limit,
         true <- Port.command(port, <<byte_size(bytes)::unsigned-big-32, bytes::binary>>) do
      observe(:request_sent, request)
      result = collect(port, System.monotonic_time(:millisecond) + timeout, "", false, nil)
      if match?({:ok, _}, result), do: observe(:response_received, request)
      result
    else
      _ -> {:error, :invalid_frame}
    end
  rescue
    _ -> {:error, :worker_lost}
  after
    close(port)
  end

  def decode_response(<<size::unsigned-big-32, body::binary>>)
      when size in 1..98_304 and byte_size(body) == size do
    with {:ok, value} <- Jason.decode(body),
         true <- is_map(value) and Contracts.canonical_json(value) == body do
      {:ok, value}
    else
      _ -> {:error, :invalid_frame}
    end
  rescue
    _ -> {:error, :invalid_frame}
  end

  def decode_response(_), do: {:error, :invalid_frame}

  def close(port) do
    if is_port(port) and Port.info(port), do: Port.close(port)
    :ok
  rescue
    _ -> :ok
  end

  defp collect(_port, _deadline, bytes, true, 0), do: decode_response(bytes)

  defp collect(_port, _deadline, _bytes, _eof, status) when is_integer(status) and status != 0,
    do: {:error, :worker_lost}

  defp collect(port, deadline, bytes, eof, status) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :timed_out}
    else
      receive do
        {^port, {:data, next}} ->
          combined = bytes <> next

          if valid_prefix?(combined),
            do: collect(port, deadline, combined, eof, status),
            else: {:error, :invalid_frame}

        {^port, :eof} ->
          collect(port, deadline, bytes, true, status)

        {^port, {:exit_status, code}} ->
          collect(port, deadline, bytes, eof, code)

        {:EXIT, ^port, _} ->
          {:error, :worker_lost}
      after
        remaining -> {:error, :timed_out}
      end
    end
  end

  defp valid_prefix?(bytes) when byte_size(bytes) < 4, do: true

  defp valid_prefix?(<<size::unsigned-big-32, body::binary>>),
    do: size in 1..98_304 and byte_size(body) <= size

  # Body-free lifecycle signals also let qualification pause a real reader
  # after sending, then verify post-I/O cancellation without mocking the read.
  defp observe(event, %{"v" => 1, "session_id" => session, "action" => action})
       when action in ["identity", "page", "objects"] do
    :telemetry.execute([:harness_forge, :graphiti, :inventory, event], %{count: 1}, %{
      session_id: session,
      action: action
    })
  end

  defp observe(_, _), do: :ok
end
