defmodule HarnessForge.Execution.CodingTransport do
  @moduledoc false
  import Bitwise
  alias HarnessForge.Execution.Command

  @version "coding-transport-v2"
  @keys ~w(version route endpoint daemon_id workspace_id run_id)
  @fields ~w(ID OSType OperatingSystem KernelVersion DockerRootDir CgroupVersion SecurityOptions)
  @native_os ["Ubuntu 22.04.5 LTS", "Ubuntu 24.04.3 LTS", "Debian GNU/Linux 12 (bookworm)"]
  @info "{\"ID\":{{json .ID}},\"OSType\":{{json .OSType}},\"OperatingSystem\":{{json .OperatingSystem}},\"KernelVersion\":{{json .KernelVersion}},\"DockerRootDir\":{{json .DockerRootDir}},\"CgroupVersion\":{{json .CgroupVersion}},\"SecurityOptions\":{{json .SecurityOptions}}}"
  @enforce_keys [:endpoint, :daemon_id, :route]
  @derive {Inspect, except: [:endpoint, :daemon_id]}
  defstruct [:endpoint, :daemon_id, :route]
  @opaque t :: %__MODULE__{endpoint: String.t(), daemon_id: String.t(), route: String.t()}

  @spec route(t()) :: String.t()
  def route(%__MODULE__{route: route}), do: route

  @spec endpoint(t()) :: String.t()
  def endpoint(%__MODULE__{endpoint: endpoint}), do: endpoint

  @spec identity_digest(t()) :: String.t()
  def identity_digest(%__MODULE__{} = observation) do
    HarnessForge.Contracts.digest(%{
      "version" => @version,
      "route" => observation.route,
      "endpoint" => observation.endpoint,
      "daemon_id" => observation.daemon_id
    })
  end

  @spec observe() :: {:ok, t()} | {:error, atom()}
  def observe do
    deadline = System.monotonic_time(:millisecond) + 6_000

    with {:ok, endpoint} <- Command.local_endpoint(),
         {:ok, stat} <- File.stat(String.replace_prefix(endpoint, "unix://", "")),
         true <- socket?(stat),
         {:ok, %{exit_status: 0, output: bytes}} <-
           Command.docker_at(
             endpoint,
             ["info", "--format", @info],
             remaining(deadline, 3_000),
             8_192
           ),
         {:ok, info} <- Jason.decode(bytes),
         true <- valid_info?(info),
         {:ok, route} <- supported_route(info, host_evidence(endpoint, stat)),
         true <- System.monotonic_time(:millisecond) <= deadline do
      {:ok, %__MODULE__{endpoint: endpoint, daemon_id: info["ID"], route: route}}
    else
      {:error, :local_docker_required} -> {:error, :local_docker_required}
      {:error, :coding_transport_unsupported} -> {:error, :coding_transport_unsupported}
      _ -> {:error, :coding_transport_unavailable}
    end
  end

  @spec verify(t()) :: :ok | {:error, atom()}
  def verify(%__MODULE__{} = observation) do
    with true <- valid_observation?(observation),
         {:ok, %{exit_status: 0, output: bytes}} <-
           Command.docker_at(
             observation.endpoint,
             ["info", "--format", "{{json .ID}}"],
             3_000,
             512
           ),
         {:ok, id} <- Jason.decode(bytes),
         true <- valid_id?(id) and id == observation.daemon_id do
      :ok
    else
      _ -> {:error, :coding_transport_changed}
    end
  end

  def verify(_), do: {:error, :coding_cleanup_context_invalid}

  @spec context(t(), String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def context(%__MODULE__{} = o, workspace_id, run_id) do
    if valid_observation?(o) and uuid?(workspace_id) and uuid?(run_id) do
      {:ok,
       %{
         "version" => @version,
         "route" => o.route,
         "endpoint" => o.endpoint,
         "daemon_id" => o.daemon_id,
         "workspace_id" => workspace_id,
         "run_id" => run_id
       }}
    else
      {:error, :coding_cleanup_context_invalid}
    end
  end

  def context(_, _, _), do: {:error, :coding_cleanup_context_invalid}

  @spec decode_context(term(), %{workspace_id: String.t(), run_id: String.t()}) ::
          {:ok, t()} | {:error, atom()}
  def decode_context(context, %{workspace_id: workspace_id, run_id: run_id})
      when is_map(context) do
    with true <- Enum.sort(Map.keys(context)) == Enum.sort(@keys),
         true <- Enum.all?(Map.values(context), &is_binary/1),
         true <- context["version"] == @version and uuid?(workspace_id) and uuid?(run_id),
         true <- context["workspace_id"] == workspace_id and context["run_id"] == run_id,
         o = %__MODULE__{
           endpoint: context["endpoint"],
           daemon_id: context["daemon_id"],
           route: context["route"]
         },
         true <- valid_observation?(o) do
      {:ok, o}
    else
      _ -> {:error, :coding_cleanup_context_invalid}
    end
  end

  def decode_context(_, _), do: {:error, :coding_cleanup_context_invalid}

  defp valid_observation?(o),
    do:
      Command.valid_endpoint?(o.endpoint) and valid_id?(o.daemon_id) and
        o.route in ["desktop_loopback_proxy", "unix_socket_proxy"]

  defp valid_info?(info) when is_map(info) do
    Enum.sort(Map.keys(info)) == Enum.sort(@fields) and valid_id?(info["ID"]) and
      bounded?(info["OSType"], 16) and bounded?(info["CgroupVersion"], 8) and
      Enum.all?(~w(OperatingSystem KernelVersion DockerRootDir), &bounded?(info[&1], 256)) and
      is_list(info["SecurityOptions"]) and length(info["SecurityOptions"]) <= 16 and
      Enum.all?(info["SecurityOptions"], &bounded?(&1, 256))
  end

  defp valid_info?(_), do: false

  defp bounded?(value, limit),
    do: is_binary(value) and String.valid?(value) and byte_size(value) <= limit

  defp valid_id?(value),
    do:
      is_binary(value) and byte_size(value) in 1..128 and
        Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9:-]{0,127}\z/, value)

  defp uuid?(value), do: is_binary(value) and match?({:ok, _}, Ecto.UUID.cast(value))
  defp socket?(stat), do: (stat.mode &&& 0o170000) == 0o140000

  @doc false
  # Pure policy evaluation yields a route name, never execution authority.
  # observe/0 always supplies host evidence collected directly below.
  def supported_route(info, host) do
    cond do
      not valid_info?(info) ->
        {:error, :coding_transport_unsupported}

      host.os in [{:unix, :darwin}, {:unix, :linux}] and host.socket? and
        Command.valid_endpoint?(host.endpoint) and info["OSType"] == "linux" and
        info["OperatingSystem"] == "Docker Desktop" and info["CgroupVersion"] == "2" and
          Regex.match?(~r/\A[0-9]+\.[0-9]+\.[0-9]+-linuxkit\z/, info["KernelVersion"]) ->
        {:ok, "desktop_loopback_proxy"}

      native?(info, host) ->
        {:ok, "unix_socket_proxy"}

      true ->
        {:error, :coding_transport_unsupported}
    end
  end

  defp native?(info, host) do
    options = info["SecurityOptions"]

    host.os == {:unix, :linux} and host.socket? and host.uid == 0 and
      host.endpoint in ["unix:///var/run/docker.sock", "unix:///run/docker.sock"] and
      is_binary(host.kernel) and bounded?(host.kernel, 256) and
      info["OSType"] == "linux" and host.pretty_name in @native_os and
      info["OperatingSystem"] == host.pretty_name and
      info["KernelVersion"] == host.kernel and
      info["DockerRootDir"] == "/var/lib/docker" and info["CgroupVersion"] == "2" and
      "name=seccomp,profile=builtin" in options and
      not Enum.any?(
        options,
        &(String.starts_with?(&1, "name=rootless") or String.starts_with?(&1, "name=userns"))
      )
  end

  defp host_evidence(endpoint, stat) do
    host = %{
      os: :os.type(),
      endpoint: endpoint,
      socket?: socket?(stat),
      uid: stat.uid,
      pretty_name: nil,
      kernel: nil
    }

    if host.os == {:unix, :linux} do
      with {:ok, release} <- bounded_file("/etc/os-release"),
           [_, pretty] <- Regex.run(~r/^PRETTY_NAME="([^"\r\n]+)"$/m, release),
           {:ok, kernel} <- bounded_file("/proc/sys/kernel/osrelease") do
        %{host | pretty_name: pretty, kernel: String.trim_trailing(kernel, "\n")}
      else
        _ -> host
      end
    else
      host
    end
  end

  defp bounded_file(path) do
    with {:ok, file} <- File.open(path, [:read, :binary]) do
      try do
        case IO.binread(file, 4_097) do
          bytes when is_binary(bytes) and byte_size(bytes) <= 4_096 -> {:ok, bytes}
          _ -> {:error, :unsupported}
        end
      after
        File.close(file)
      end
    end
  end

  defp remaining(deadline, limit),
    do: min(max(deadline - System.monotonic_time(:millisecond), 1), limit)
end
