defmodule HarnessForge.Execution.Docker do
  @moduledoc "Fixed, offline Docker confinement profile; accepts no executable, argv, mount or network input."
  alias HarnessForge.{Contracts, Workspaces}
  alias HarnessForge.Execution.Command

  @image "ghcr.io/anomalyco/opencode@sha256:f4cfe16d91efbbfca01a51c44094fba4cf82e15c7fa17de5f11f9059699b1e6e"
  @version "1.19.5"
  @label "dev.harnessforge.workspace"
  @run_label "dev.harnessforge.run"
  @probe """
  set -eu
  test "$(id -u)" = 65534
  test ! -e /var/run/docker.sock
  test ! -e /run/docker.sock
  grep -q '^CapEff:[[:space:]]*0000000000000000$' /proc/self/status
  grep -q '^NoNewPrivs:[[:space:]]*1$' /proc/self/status
  test "$(cat /sys/fs/cgroup/pids.max)" = 64
  test "$(cat /sys/fs/cgroup/memory.max)" = 536870912
  test "$(cat /sys/fs/cgroup/cpu.max)" = '100000 100000'
  if touch /harnessforge-escape 2>/dev/null; then exit 31; fi
  test -z "$(ip -o link show up | sed '/^[0-9]*: lo:/d')"
  if ip route get 203.0.113.1 >/dev/null 2>&1; then exit 32; fi
  if ip -6 route get 2001:db8::1 >/dev/null 2>&1; then exit 33; fi
  printf 'containment_checks_passed\n'
  """

  def image, do: @image
  def version, do: @version
  def profile_digest, do: Contracts.digest(profile())

  def profile do
    %{
      "id" => "docker-offline-v1",
      "image" => @image,
      "user" => "65534:65534",
      "network" => "none",
      "read_only" => true,
      "cap_drop" => ["ALL"],
      "no_new_privileges" => true,
      "pids" => 64,
      "memory_bytes" => 536_870_912,
      "cpu_nano" => 1_000_000_000,
      "host_mounts" => [],
      "timeout_ms" => 15_000,
      "output_limit_bytes" => 65_536,
      "tmpfs_limit_bytes" => 67_108_864
    }
  end

  def probe do
    with {:ok, %{exit_status: 0, output: host}} <-
           Command.docker(["context", "inspect", "--format", "{{.Endpoints.docker.Host}}"]),
         true <- String.starts_with?(String.trim(host), "unix://"),
         {:ok, %{exit_status: 0, output: "linux\n"}} <-
           Command.docker(["info", "--format", "{{.OSType}}"]),
         {:ok, %{exit_status: 0}} <-
           Command.docker(["image", "inspect", @image, "--format", "{{.Id}}"]) do
      {:ok,
       %{
         "available" => true,
         "image" => @image,
         "version" => @version,
         "environment_profile_digest" => profile_digest(),
         "task_model_route" => "unavailable"
       }}
    else
      _ -> {:error, :local_docker_or_pinned_image_unavailable}
    end
  end

  def name(run_id), do: "hf-" <> run_id

  def start(run_id, kind, config \\ %{}) do
    with :ok <- valid_id(run_id),
         {:ok, entrypoint, argv} <- command(kind),
         {:ok, _} <- probe(),
         {:ok, %{exit_status: 0}} <- Command.docker(create_args(run_id, entrypoint, argv, config)),
         {:ok, inspection} <- inspect_owned(run_id),
         :ok <- verify_profile(inspection) do
      {:ok, %{run_id: run_id, name: name(run_id)}}
    else
      error ->
        # A create may have succeeded before a transport/inspection failure.
        # Callers also retain a durable run identity for startup reconciliation.
        {:error, {:execution_start_failed, safe_reason(error)}}
    end
  end

  def await(%{run_id: id}) do
    with {:ok, inspection} <- inspect_owned(id), :ok <- verify_profile(inspection) do
      started = System.monotonic_time(:millisecond)
      result = Command.docker(["start", "--attach", name(id)], 15_000, 65_536)
      outcome = result_outcome(result, id)
      cleanup = cleanup(id)

      {:ok,
       Map.merge(outcome, %{
         "duration_ms" => System.monotonic_time(:millisecond) - started,
         "cleanup_status" => if(cleanup == :ok, do: "complete", else: "cleanup_failed")
       })}
    end
  end

  def inspect_owned(id) do
    with :ok <- valid_id(id),
         {:ok, %{exit_status: 0, output: bytes}} <- Command.docker(["inspect", name(id)]),
         {:ok, [inspection]} <- Jason.decode(bytes),
         true <- get_in(inspection, ["Config", "Labels", @label]) == Workspaces.current_id(),
         true <- get_in(inspection, ["Config", "Labels", @run_label]) == id do
      {:ok, inspection}
    else
      _ -> {:error, :container_unavailable_or_not_owned}
    end
  end

  def cleanup(id) do
    :global.trans({{__MODULE__, Workspaces.current_id(), id}, self()}, fn -> cleanup_owned(id) end)
  end

  defp cleanup_owned(id) do
    with :ok <- valid_id(id), {:ok, present} <- present?(id) do
      if present do
        with {:ok, _} <- inspect_owned(id),
             {:ok, %{exit_status: 0}} <- Command.docker(["rm", "--force", name(id)]),
             {:ok, false} <- present?(id),
             do: :ok
      else
        :ok
      end
    else
      _ -> {:error, :cleanup_failed}
    end
    |> case do
      :ok -> :ok
      _ -> {:error, :cleanup_failed}
    end
  end

  def reconcile do
    with {:ok, %{exit_status: 0, output: output}} <-
           Command.docker([
             "ps",
             "--all",
             "--filter",
             "label=#{@label}=#{Workspaces.current_id()}",
             "--format",
             "{{.Label \"#{@run_label}\"}}"
           ]) do
      output
      |> String.split("\n", trim: true)
      |> Enum.reduce_while(:ok, fn id, :ok ->
        case cleanup(id) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    else
      _ -> {:error, :docker_reconciliation_unavailable}
    end
  end

  def verify_profile(i) do
    h = i["HostConfig"] || %{}

    valid =
      get_in(i, ["Config", "User"]) == "65534:65534" and
        h["ReadonlyRootfs"] == true and h["NetworkMode"] == "none" and
        h["Privileged"] == false and h["CapDrop"] == ["ALL"] and
        "no-new-privileges" in (h["SecurityOpt"] || []) and h["PidsLimit"] == 64 and
        h["Memory"] == 536_870_912 and h["MemorySwap"] == 536_870_912 and
        h["NanoCpus"] == 1_000_000_000 and (h["Binds"] || []) == [] and
        (i["Mounts"] || []) == [] and get_in(i, ["Config", "Image"]) == @image

    if valid, do: :ok, else: {:error, :container_profile_mismatch}
  end

  defp command(:version), do: {:ok, "opencode", ["--version"]}
  defp command(:config), do: {:ok, "opencode", ["debug", "config"]}
  defp command(:containment), do: {:ok, "/bin/sh", ["-c", @probe]}
  defp command(:timeout_probe), do: {:ok, "/bin/sleep", ["60"]}

  defp command(:output_probe),
    do: {:ok, "/bin/sh", ["-c", "while :; do printf 'bounded-output-check\\n'; done"]}

  defp command(_), do: {:error, :unsupported_execution_kind}

  defp create_args(id, entrypoint, argv, config) do
    effective =
      Map.merge(config, %{
        "autoupdate" => false,
        "enabled_providers" => [],
        "plugin" => [],
        "mcp" => %{},
        "lsp" => false,
        "formatter" => false,
        "permission" => %{"*" => "deny"}
      })

    [
      "create",
      "--pull",
      "never",
      "--name",
      name(id),
      "--label",
      "#{@label}=#{Workspaces.current_id()}",
      "--label",
      "#{@run_label}=#{id}",
      "--network",
      "none",
      "--user",
      "65534:65534",
      "--read-only",
      "--cap-drop",
      "ALL",
      "--security-opt",
      "no-new-privileges",
      "--pids-limit",
      "64",
      "--memory",
      "512m",
      "--memory-swap",
      "512m",
      "--cpus",
      "1",
      "--log-driver",
      "local",
      "--log-opt",
      "max-size=1m",
      "--log-opt",
      "max-file=1",
      "--log-opt",
      "compress=false",
      "--tmpfs",
      "/tmp:rw,noexec,nosuid,nodev,size=64m,mode=1777",
      "--env",
      "HOME=/tmp",
      "--env",
      "XDG_CACHE_HOME=/tmp/cache",
      "--env",
      "XDG_DATA_HOME=/tmp/data",
      "--env",
      "XDG_CONFIG_HOME=/tmp/config",
      "--env",
      "OPENCODE_CONFIG_CONTENT=" <> Contracts.canonical_json(effective),
      "--entrypoint",
      entrypoint,
      @image
    ] ++ argv
  end

  defp result_outcome({:ok, %{output: output}}, id) do
    case inspect_owned(id) do
      {:ok, %{"State" => %{"Running" => false, "ExitCode" => exit}}} ->
        %{
          "outcome" => if(exit == 0, do: "passed", else: "failed"),
          "exit_status" => exit,
          "output" => output,
          "reason" => nil
        }

      _ ->
        %{
          "outcome" => "interrupted",
          "output" => output,
          "reason" => "container_state_unavailable"
        }
    end
  end

  defp result_outcome({:error, :timed_out}, _),
    do: %{"outcome" => "timed_out", "reason" => "time_limit", "output" => ""}

  defp result_outcome({:error, :output_limit}, _),
    do: %{"outcome" => "failed", "reason" => "output_limit", "output" => ""}

  defp result_outcome(_, _),
    do: %{"outcome" => "interrupted", "reason" => "docker_transport_failed", "output" => ""}

  defp present?(id) do
    case Command.docker(["ps", "--all", "--filter", "name=^/#{name(id)}$", "--format", "{{.ID}}"]) do
      {:ok, %{exit_status: 0, output: output}} -> {:ok, String.trim(output) != ""}
      _ -> {:error, :container_presence_unavailable}
    end
  end

  defp valid_id(id) when is_binary(id) do
    if Regex.match?(~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/, id),
      do: :ok,
      else: {:error, :invalid_run_id}
  end

  defp valid_id(_), do: {:error, :invalid_run_id}
  defp safe_reason({:error, atom}) when is_atom(atom), do: atom
  defp safe_reason(_), do: :container_operation_failed
end
