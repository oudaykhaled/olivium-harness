defmodule HarnessForge.Graphiti.LaunchProfile do
  @moduledoc """
  Pure intended-profile and Docker-inspection checks for root-owned launches.

  These checks neither launch a process nor establish runtime containment.
  Root independently qualifies image content, the actual backend/network,
  boot/session ownership and the trusted measurement path. Credentials and
  environment values never appear in returned receipts or error details.
  """
  alias HarnessForge.Contracts

  @id "graph-worker-isolated-v1"
  @keys ~w(workspace_id partition_id session_id worker_image network_name network_id image_env_digest)
  @entrypoint ["python", "-I", "/app/__main__.py"]
  @tmpfs "rw,noexec,nosuid,nodev,size=67108864"
  @memory 805_306_368
  @nano_cpus 1_000_000_000
  @network_option "com.docker.network.bridge.gateway_mode_ipv4"
  @ipv4_option "com.docker.network.enable_ipv4"
  @invalid {:error, :invalid_graph_launch_profile}
  @mismatch {:error, :graph_launch_mismatch}
  @type result :: {:ok, map() | [String.t()]} | {:error, atom()}

  @spec worker_args(map()) :: result()
  def worker_args(spec) do
    with {:ok, profile} <- worker_profile(spec), do: {:ok, profile["argv"]}
  end

  @spec worker_profile(map()) :: result()
  def worker_profile(spec) do
    if valid_spec?(spec), do: {:ok, profile(spec)}, else: @invalid
  rescue
    _ -> @invalid
  end

  @spec verify_worker(map(), map()) :: result()
  def verify_worker(spec, inspection) do
    with {:ok, intended} <- worker_profile(spec),
         true <- is_map(inspection) and not is_struct(inspection),
         true <- hex?(inspection["Id"]),
         true <- inspection["Name"] == "/" <> intended["name"],
         true <- inspection["Image"] == spec["worker_image"],
         true <-
           inspection["Path"] == "python" and inspection["Args"] == ["-I", "/app/__main__.py"],
         true <- config?(inspection["Config"], intended),
         true <- host?(inspection["HostConfig"], intended),
         true <- inspection["Mounts"] == [],
         true <- state?(inspection["State"]),
         true <- networks?(inspection["NetworkSettings"], intended, inspection["Id"]) do
      {:ok,
       %{
         "container_id" => inspection["Id"],
         "image_id" => spec["worker_image"],
         "profile_digest" => Contracts.digest(intended),
         "network_id" => spec["network_id"],
         "session_id" => spec["session_id"]
       }}
    else
      _ -> @mismatch
    end
  rescue
    _ -> @mismatch
  end

  @doc "Fixed offline native-response verifier; reuses the worker's process isolation checks."
  def verify_replay(spec, inspection) do
    with {:ok, intended} <- worker_profile(spec),
         true <- is_map(inspection),
         true <- hex?(inspection["Id"]) and inspection["Image"] == spec["worker_image"],
         name = "hf-graph-replay-" <> compact(spec["session_id"]),
         true <-
           inspection["Name"] == "/" <> name and inspection["Path"] == "python" and
             inspection["Args"] == ["-I", "/app/response_proof.py"],
         config = inspection["Config"],
         labels =
           Map.put(
             intended["labels"],
             "dev.harnessforge.profile",
             "graph-response-replay-isolated-v1"
           ),
         true <-
           config["Entrypoint"] == ["python"] and
             config["Cmd"] == ["-I", "/app/response_proof.py"] and config["Labels"] == labels,
         # Only these independently checked entrypoint/profile fields differ.
         normalized =
           config
           |> Map.put("Entrypoint", @entrypoint)
           |> Map.put("Cmd", nil)
           |> Map.put("Labels", intended["labels"]),
         true <- config?(normalized, intended),
         offline = put_in(intended, ["network", "name"], "none"),
         true <- host?(inspection["HostConfig"], offline),
         true <- inspection["Mounts"] == [] and state?(inspection["State"]),
         true <- offline_network?(inspection["NetworkSettings"]) do
      {:ok,
       %{
         "container_id" => inspection["Id"],
         "image_id" => spec["worker_image"],
         "session_id" => spec["session_id"],
         "profile_digest" =>
           Contracts.digest(%{
             "base" => intended,
             "profile" => "graph-response-replay-isolated-v1",
             "network" => "none",
             "name" => name,
             "entrypoint" => ["python", "-I", "/app/response_proof.py"]
           })
       }}
    else
      _ -> @mismatch
    end
  rescue
    _ -> @mismatch
  end

  defp offline_network?(%{"Networks" => %{"none" => endpoint}} = settings)
       when is_map(endpoint) do
    map_size(settings["Networks"]) == 1 and
      Enum.all?(
        ~w(IPAddress Gateway GlobalIPv6Address IPv6Gateway MacAddress),
        &(endpoint[&1] in [nil, ""])
      ) and
      endpoint["Aliases"] in [nil, []] and endpoint["DNSNames"] in [nil, []] and
      Enum.all?(
        ~w(IPAddress Gateway GlobalIPv6Address IPv6Gateway LinkLocalIPv6Address),
        &(settings[&1] in [nil, ""])
      ) and
      empty_map?(settings["Ports"])
  end

  defp offline_network?(_), do: false

  @spec network_args(String.t(), String.t()) :: result()
  def network_args(workspace_id, partition_id) do
    if uuid?(workspace_id) and uuid?(partition_id) do
      intended = network_profile(workspace_id, partition_id)

      {:ok,
       [
         "network",
         "create",
         "--driver",
         "bridge",
         "--internal",
         "--ipv6=false",
         "--opt",
         @network_option <> "=isolated"
       ] ++ label_args(intended["labels"]) ++ [intended["name"]]}
    else
      @invalid
    end
  rescue
    _ -> @invalid
  end

  @spec verify_network(String.t(), String.t(), map()) :: result()
  def verify_network(workspace_id, partition_id, inspection) do
    with true <- uuid?(workspace_id) and uuid?(partition_id),
         true <- is_map(inspection) and not is_struct(inspection),
         intended = network_profile(workspace_id, partition_id),
         true <- hex?(inspection["Id"]),
         true <- inspection["Name"] == intended["name"] and inspection["Driver"] == "bridge",
         true <- inspection["Internal"] === true and inspection["EnableIPv6"] === false,
         true <- not Map.has_key?(inspection, "EnableIPv4") or inspection["EnableIPv4"] === true,
         true <- inspection["Scope"] == "local",
         true <- network_options?(inspection["Options"], intended["options"]),
         true <- inspection["Labels"] == intended["labels"] do
      {:ok,
       %{
         "network_id" => inspection["Id"],
         "network_name" => intended["name"],
         "profile_digest" => Contracts.digest(intended)
       }}
    else
      _ -> @mismatch
    end
  rescue
    _ -> @mismatch
  end

  defp valid_spec?(spec) do
    is_map(spec) and not is_struct(spec) and map_size(spec) == length(@keys) and
      Enum.all?(@keys, &Map.has_key?(spec, &1)) and
      Enum.all?(~w(workspace_id partition_id session_id), &uuid?(spec[&1])) and
      image?(spec["worker_image"]) and hex?(spec["network_id"]) and hex?(spec["image_env_digest"]) and
      spec["network_name"] == network_name(spec["partition_id"])
  end

  defp profile(spec) do
    labels =
      labels(spec["workspace_id"], spec["partition_id"])
      |> Map.put("dev.harnessforge.session", spec["session_id"])

    name = "hf-graph-worker-" <> compact(spec["partition_id"])

    args =
      [
        "create",
        "--pull",
        "never",
        "--interactive",
        "--attach",
        "stdin",
        "--attach",
        "stdout",
        "--name",
        name
      ] ++
        label_args(labels) ++
        [
          "--network",
          spec["network_name"],
          "--network-alias",
          "worker",
          "--user",
          "65532:65532",
          "--read-only",
          "--cap-drop",
          "ALL",
          "--security-opt",
          "no-new-privileges:true",
          "--pids-limit",
          "64",
          "--memory",
          Integer.to_string(@memory),
          "--memory-swap",
          Integer.to_string(@memory),
          "--cpus",
          "1",
          "--tmpfs",
          "/tmp:" <> @tmpfs,
          "--log-driver",
          "none",
          "--stop-timeout",
          "10",
          "--ipc",
          "private",
          "--cgroupns",
          "private",
          spec["worker_image"]
        ]

    %{
      "profile_id" => @id,
      "workspace_id" => spec["workspace_id"],
      "partition_id" => spec["partition_id"],
      "session_id" => spec["session_id"],
      "name" => name,
      "image_id" => spec["worker_image"],
      "image_env_digest" => spec["image_env_digest"],
      "entrypoint" => @entrypoint,
      "cmd" => nil,
      "working_dir" => "/app",
      "user" => "65532:65532",
      "labels" => labels,
      "network" => %{
        "name" => spec["network_name"],
        "id" => spec["network_id"],
        "alias" => "worker"
      },
      "stdin" => true,
      "stdin_once" => true,
      "stdout" => true,
      "stderr" => false,
      "tty" => false,
      "read_only" => true,
      "cap_drop" => ["ALL"],
      "cap_add" => [],
      "security_opt" => ["no-new-privileges:true"],
      "pids_limit" => 64,
      "memory" => @memory,
      "memory_swap" => @memory,
      "nano_cpus" => @nano_cpus,
      "tmpfs" => %{"/tmp" => @tmpfs},
      "log_driver" => "none",
      "stop_timeout" => 10,
      "ipc_mode" => "private",
      "cgroupns_mode" => "private",
      "mounts" => [],
      "ports" => [],
      "devices" => [],
      "argv" => args
    }
  end

  defp config?(config, intended) when is_map(config) do
    config["Image"] == intended["image_id"] and config["Entrypoint"] == @entrypoint and
      Map.has_key?(config, "Cmd") and is_nil(config["Cmd"]) and
      config["WorkingDir"] == "/app" and config["User"] == "65532:65532" and
      config["Labels"] == intended["labels"] and
      Map.has_key?(config, "Volumes") and is_nil(config["Volumes"]) and
      empty_map?(config["ExposedPorts"]) and config["StopTimeout"] == 10 and
      config["OpenStdin"] === true and config["AttachStdin"] === true and
      config["AttachStdout"] === true and config["AttachStderr"] === false and
      config["Tty"] === false and config["StdinOnce"] === true and
      environment?(config["Env"], intended["image_env_digest"])
  end

  defp config?(_, _), do: false

  defp environment?(env, expected) when is_list(env) and length(env) <= 256 do
    with true <-
           Enum.all?(
             env,
             &(is_binary(&1) and String.valid?(&1) and byte_size(&1) <= 8192 and
                 not String.contains?(&1, <<0>>))
           ),
         true <- Enum.reduce(env, 0, &(byte_size(&1) + &2)) <= 65_536,
         pairs = Enum.map(env, &String.split(&1, "=", parts: 2)),
         true <-
           Enum.all?(pairs, fn pair ->
             case pair do
               [key, _value] ->
                 Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, key) and not secret_key?(key)

               _ ->
                 false
             end
           end),
         keys = Enum.map(pairs, &hd/1),
         true <- length(keys) == length(Enum.uniq(keys)),
         true <- Contracts.digest(Enum.sort(env)) == expected do
      true
    else
      _ -> false
    end
  end

  defp environment?(_, _), do: false

  defp secret_key?(key) do
    key = String.upcase(key)
    Regex.match?(~r/API_KEY|TOKEN|SECRET|PASSWORD|PROXY|\ADOCKER_|\AHARNESSFORGE_/, key)
  end

  defp host?(host, intended) when is_map(host) do
    host["NetworkMode"] == intended["network"]["name"] and
      host["ReadonlyRootfs"] === true and host["Privileged"] === false and
      host["CapDrop"] == ["ALL"] and empty_list?(host["CapAdd"]) and
      host["SecurityOpt"] == ["no-new-privileges:true"] and
      host["PidsLimit"] == 64 and host["Memory"] == @memory and host["MemorySwap"] == @memory and
      host["NanoCpus"] == @nano_cpus and host["CpuPeriod"] == 0 and host["CpuQuota"] == 0 and
      host["CpuShares"] == 0 and host["CpusetCpus"] == "" and host["CpusetMems"] == "" and
      host["Tmpfs"] == intended["tmpfs"] and host["IpcMode"] == "private" and
      host["CgroupnsMode"] == "private" and host["PidMode"] in ["", "private"] and
      host["UTSMode"] in ["", "private"] and host["UsernsMode"] in [nil, "", "private"] and
      host["PublishAllPorts"] === false and empty_map?(host["PortBindings"]) and
      Enum.all?(
        ~w(Binds Mounts VolumesFrom Devices DeviceRequests DeviceCgroupRules Links ExtraHosts Dns DnsOptions DnsSearch),
        &empty_list?(host[&1])
      ) and
      log?(host["LogConfig"]) and restart?(host["RestartPolicy"])
  end

  defp host?(_, _), do: false

  defp log?(%{"Type" => "none", "Config" => config}), do: config == %{}
  defp log?(_), do: false
  defp restart?(%{"Name" => name, "MaximumRetryCount" => 0}), do: name in ["", "no"]
  defp restart?(_), do: false

  defp state?(%{"Status" => status} = state) when status in ["created", "running"] do
    state["Running"] === (status == "running") and
      Enum.all?(~w(Paused Restarting OOMKilled Dead), &(state[&1] === false)) and
      state["Error"] == "" and state["ExitCode"] == 0
  end

  defp state?(_), do: false

  defp networks?(settings, intended, container_id) when is_map(settings) do
    networks = settings["Networks"]
    expected = intended["network"]

    with true <- is_map(networks) and map_size(networks) == 1,
         {:ok, endpoint} <- Map.fetch(networks, expected["name"]),
         true <- is_map(endpoint) and endpoint["NetworkID"] == expected["id"],
         true <-
           endpoint["GlobalIPv6Address"] in [nil, ""] and endpoint["IPv6Gateway"] in [nil, ""],
         true <-
           settings["GlobalIPv6Address"] in [nil, ""] and
             settings["LinkLocalIPv6Address"] in [nil, ""],
         true <- empty_map?(settings["Ports"]),
         aliases when is_list(aliases) <- endpoint["Aliases"],
         true <- "worker" in aliases and length(aliases) == length(Enum.uniq(aliases)),
         allowed = ["worker", intended["name"], container_id, String.slice(container_id, 0, 12)],
         true <- Enum.all?(aliases, &(&1 in allowed)),
         true <- dns_names?(endpoint["DNSNames"], allowed) do
      true
    else
      _ -> false
    end
  end

  defp networks?(_, _, _), do: false

  defp dns_names?(nil, _allowed), do: true
  defp dns_names?(names, allowed) when is_list(names), do: Enum.all?(names, &(&1 in allowed))
  defp dns_names?(_, _), do: false

  defp network_profile(workspace, partition) do
    %{
      "profile_id" => @id,
      "kind" => "network",
      "workspace_id" => workspace,
      "partition_id" => partition,
      "name" => network_name(partition),
      "driver" => "bridge",
      "internal" => true,
      "enable_ipv6" => false,
      "scope" => "local",
      "options" => %{@network_option => "isolated"},
      "labels" => labels(workspace, partition)
    }
  end

  # Docker may materialize its enabled-IPv4 default in network inspect. This
  # exact normalization changes no intended isolation policy or profile digest.
  defp network_options?(actual, intended),
    do: actual == intended or actual == Map.put(intended, @ipv4_option, "true")

  defp labels(workspace, partition),
    do: %{
      "dev.harnessforge.workspace" => workspace,
      "dev.harnessforge.partition" => partition,
      "dev.harnessforge.profile" => @id
    }

  defp label_args(labels),
    do:
      labels
      |> Enum.sort()
      |> Enum.flat_map(fn {key, value} -> ["--label", key <> "=" <> value] end)

  defp network_name(partition), do: "hf-graph-net-" <> compact(partition)
  defp compact(id), do: String.replace(id, "-", "")
  defp empty_list?(value), do: is_nil(value) or value == []
  defp empty_map?(value), do: is_nil(value) or value == %{}
  defp uuid?(value), do: is_binary(value) and match?({:ok, ^value}, Ecto.UUID.cast(value))
  defp hex?(value), do: is_binary(value) and Regex.match?(~r/\A[a-f0-9]{64}\z/, value)
  defp image?("sha256:" <> hash), do: hex?(hash)
  defp image?(_), do: false
end
