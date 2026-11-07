defmodule HarnessForge.Graphiti.BackendProfile do
  @moduledoc """
  Pure intended-profile and inspection checks for a dedicated Neo4j backend.

  Root owns actual launches, credentials, environment-file containment and
  lifetime, volume provenance, storage incarnation and backend qualification.
  These validators never read environment files or return environment values.
  A fixture passing these checks is not evidence of runtime containment.

  Docker's Config.AttachStdout/AttachStderr defaults are true even without
  create --attach flags; these are configuration capabilities, not active
  channels. Root starts the backend with docker start ID without attaching.
  Actual launch/channel ownership remains a root check, not an inspect claim.
  """
  alias HarnessForge.Contracts

  @id "graph-backend-isolated-v1"
  @keys ~w(workspace_id partition_id backend_image network_name network_id env_file env_digest)
  @entrypoint ["tini", "-g", "--", "/startup/docker-entrypoint.sh"]
  @args ["-g", "--", "/startup/docker-entrypoint.sh", "neo4j"]
  @ports ~w(7473/tcp 7474/tcp 7687/tcp)
  @memory 1_610_612_736
  @tmpfs %{
    "/tmp" => "rw,noexec,nosuid,nodev,size=134217728,uid=7474,gid=7474",
    "/tmp/neo4j-native" => "rw,exec,nosuid,nodev,size=16777216,uid=7474,gid=7474",
    "/var/lib/neo4j/run" => "rw,noexec,nosuid,nodev,size=16777216,uid=7474,gid=7474"
  }
  @invalid {:error, :invalid_graph_launch_profile}
  @mismatch {:error, :graph_launch_mismatch}
  @type result :: {:ok, map() | [String.t()]} | {:error, atom()}

  @spec backend_args(map()) :: result()
  def backend_args(spec) do
    with {:ok, intended} <- backend_profile(spec), do: {:ok, intended["argv"]}
  end

  @spec backend_profile(map()) :: result()
  def backend_profile(spec) do
    if valid_spec?(spec), do: {:ok, profile(spec)}, else: @invalid
  rescue
    _ -> @invalid
  end

  @spec verify_backend(map(), map()) :: result()
  def verify_backend(spec, inspection) do
    with {:ok, intended} <- backend_profile(spec),
         true <- is_map(inspection) and not is_struct(inspection),
         true <- hex?(inspection["Id"]),
         true <- inspection["Name"] == "/" <> intended["name"],
         true <- inspection["Image"] == spec["backend_image"],
         true <- inspection["Path"] == "tini" and inspection["Args"] == @args,
         true <- config?(inspection["Config"], intended),
         true <- host?(inspection["HostConfig"], intended),
         true <- actual_mounts?(inspection["Mounts"], intended["volumes"]),
         true <- network?(inspection["NetworkSettings"], intended, inspection["Id"]),
         true <- state?(inspection["State"]) do
      {:ok,
       %{
         "container_id" => inspection["Id"],
         "image_id" => spec["backend_image"],
         "profile_digest" => Contracts.digest(intended),
         "network_id" => spec["network_id"]
       }}
    else
      _ -> @mismatch
    end
  rescue
    _ -> @mismatch
  end

  defp valid_spec?(spec) do
    is_map(spec) and not is_struct(spec) and map_size(spec) == length(@keys) and
      Enum.all?(@keys, &Map.has_key?(spec, &1)) and uuid?(spec["workspace_id"]) and
      uuid?(spec["partition_id"]) and image?(spec["backend_image"]) and hex?(spec["network_id"]) and
      hex?(spec["env_digest"]) and
      spec["network_name"] == "hf-graph-net-" <> compact(spec["partition_id"]) and
      env_path?(spec["env_file"])
  end

  defp env_path?(path) when is_binary(path) do
    String.valid?(path) and byte_size(path) in 2..4096 and String.starts_with?(path, "/") and
      not String.contains?(path, [<<0>>, "\r", "\n"]) and
      Enum.all?(tl(String.split(path, "/")), &(&1 not in ["", ".", ".."]))
  end

  defp env_path?(_), do: false

  defp profile(spec) do
    suffix = compact(spec["partition_id"])
    name = "hf-graph-backend-" <> suffix

    labels = %{
      "dev.harnessforge.workspace" => spec["workspace_id"],
      "dev.harnessforge.partition" => spec["partition_id"],
      "dev.harnessforge.profile" => @id
    }

    volumes = %{
      "/data" => "hf-graph-data-" <> suffix,
      "/logs" => "hf-graph-logs-" <> suffix,
      "/var/lib/neo4j/conf" => "hf-graph-conf-" <> suffix
    }

    args =
      ["create", "--pull", "never", "--name", name] ++
        Enum.flat_map(Enum.sort(labels), fn {key, value} -> ["--label", key <> "=" <> value] end) ++
        [
          "--network",
          spec["network_name"],
          "--network-alias",
          "neo4j",
          "--user",
          "7474:7474",
          "--read-only",
          "--cap-drop",
          "ALL",
          "--security-opt",
          "no-new-privileges:true",
          "--pids-limit",
          "256",
          "--memory",
          Integer.to_string(@memory),
          "--memory-swap",
          Integer.to_string(@memory),
          "--cpus",
          "2",
          "--log-driver",
          "none",
          "--stop-timeout",
          "30",
          "--ipc",
          "private",
          "--cgroupns",
          "private",
          "--env-file",
          spec["env_file"]
        ] ++
        Enum.flat_map(Enum.sort(volumes), fn {destination, source} ->
          ["--mount", "type=volume,source=" <> source <> ",target=" <> destination]
        end) ++
        Enum.flat_map(Enum.sort(@tmpfs), fn {path, options} ->
          ["--tmpfs", path <> ":" <> options]
        end) ++ [spec["backend_image"]]

    %{
      "profile_id" => @id,
      "workspace_id" => spec["workspace_id"],
      "partition_id" => spec["partition_id"],
      "name" => name,
      "image_id" => spec["backend_image"],
      "env_digest" => spec["env_digest"],
      "entrypoint" => @entrypoint,
      "cmd" => ["neo4j"],
      "working_dir" => "/var/lib/neo4j",
      "user" => "7474:7474",
      "labels" => labels,
      "network" => %{
        "name" => spec["network_name"],
        "id" => spec["network_id"],
        "alias" => "neo4j"
      },
      "attach_stdin" => false,
      "attach_stdout" => true,
      "attach_stderr" => true,
      "open_stdin" => false,
      "tty" => false,
      "read_only" => true,
      "privileged" => false,
      "cap_drop" => ["ALL"],
      "cap_add" => [],
      "security_opt" => ["no-new-privileges:true"],
      "pids_limit" => 256,
      "memory" => @memory,
      "memory_swap" => @memory,
      "nano_cpus" => 2_000_000_000,
      "tmpfs" => @tmpfs,
      "volumes" => volumes,
      "image_volumes" => %{"/data" => %{}, "/logs" => %{}},
      "unpublished_image_ports" => @ports,
      "log_driver" => "none",
      "stop_timeout" => 30,
      "ipc_mode" => "private",
      "cgroupns_mode" => "private",
      "argv" => args
    }
  end

  defp config?(config, intended) when is_map(config) do
    config["Image"] == intended["image_id"] and config["Entrypoint"] == @entrypoint and
      config["Cmd"] == ["neo4j"] and
      config["User"] == "7474:7474" and config["WorkingDir"] == "/var/lib/neo4j" and
      config["Labels"] == intended["labels"] and
      config["Volumes"] == intended["image_volumes"] and exposed?(config["ExposedPorts"]) and
      config["StopTimeout"] == 30 and config["AttachStdin"] === false and
      config["AttachStdout"] === true and
      config["AttachStderr"] === true and config["OpenStdin"] === false and
      config["Tty"] === false and
      config["StdinOnce"] === false and environment?(config["Env"], intended["env_digest"])
  end

  defp config?(_, _), do: false

  defp environment?(env, digest) when is_list(env) and length(env) <= 256 do
    with true <-
           Enum.all?(
             env,
             &(is_binary(&1) and String.valid?(&1) and byte_size(&1) <= 8192 and
                 not String.contains?(&1, <<0>>))
           ),
         true <- Enum.reduce(env, 0, &(byte_size(&1) + &2)) < 65_536,
         pairs = Enum.map(env, &String.split(&1, "=", parts: 2)),
         true <-
           Enum.all?(pairs, fn pair ->
             case pair do
               [key, _] ->
                 Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, key) and allowed_env_key?(key)

               _ ->
                 false
             end
           end),
         names = Enum.map(pairs, &hd/1),
         true <- length(names) == length(Enum.uniq(names)),
         true <- Contracts.digest(Enum.sort(env)) == digest do
      true
    else
      _ -> false
    end
  end

  defp environment?(_, _), do: false

  defp allowed_env_key?("NEO4J_AUTH"), do: true

  defp allowed_env_key?(key) do
    not Regex.match?(
      ~r/API_KEY|TOKEN|SECRET|PASSWORD|PROXY|CREDENTIAL|AUTH|\ADOCKER_|\AHARNESSFORGE_|\AOTEL_|\AOPENAI_|\AANTHROPIC_|\AAWS_|\AAZURE_|\AGOOGLE_|\AGEMINI_/,
      String.upcase(key)
    )
  end

  defp host?(host, intended) when is_map(host) do
    host["NetworkMode"] == intended["network"]["name"] and host["ReadonlyRootfs"] === true and
      host["Privileged"] === false and
      host["CapDrop"] == ["ALL"] and empty_list?(host["CapAdd"]) and
      host["SecurityOpt"] == ["no-new-privileges:true"] and
      host["PidsLimit"] == 256 and host["Memory"] == @memory and host["MemorySwap"] == @memory and
      host["NanoCpus"] == 2_000_000_000 and
      host["CpuPeriod"] == 0 and host["CpuQuota"] == 0 and host["CpuShares"] == 0 and
      host["CpusetCpus"] == "" and host["CpusetMems"] == "" and
      host["Tmpfs"] == @tmpfs and host["IpcMode"] == "private" and
      host["CgroupnsMode"] == "private" and
      host["PidMode"] in ["", "private"] and host["UTSMode"] in ["", "private"] and
      host["UsernsMode"] in [nil, "", "private"] and
      host["PublishAllPorts"] === false and empty_map?(host["PortBindings"]) and
      Enum.all?(
        ~w(Binds VolumesFrom Devices DeviceRequests DeviceCgroupRules Links ExtraHosts Dns DnsOptions DnsSearch),
        &empty_list?(host[&1])
      ) and
      requested_mounts?(host["Mounts"], intended["volumes"]) and
      host["LogConfig"] == %{"Type" => "none", "Config" => %{}} and
      restart?(host["RestartPolicy"])
  end

  defp host?(_, _), do: false

  defp requested_mounts?(mounts, expected) when is_list(mounts) and length(mounts) == 3 do
    Enum.all?(mounts, fn mount ->
      is_map(mount) and mount["Type"] == "volume" and Map.has_key?(expected, mount["Target"]) and
        mount["Source"] == expected[mount["Target"]] and mount["ReadOnly"] in [nil, false] and
        is_nil(mount["BindOptions"]) and is_nil(mount["TmpfsOptions"]) and
        mount["Consistency"] in [nil, ""] and
        mount["VolumeOptions"] in [nil, %{}, %{"NoCopy" => false}]
    end) and length(Enum.uniq_by(mounts, & &1["Target"])) == 3
  end

  defp requested_mounts?(_, _), do: false

  defp actual_mounts?(mounts, expected) when is_list(mounts) and length(mounts) == 3 do
    Enum.all?(mounts, fn mount ->
      is_map(mount) and mount["Type"] == "volume" and Map.has_key?(expected, mount["Destination"]) and
        mount["Name"] == expected[mount["Destination"]] and mount["Driver"] == "local" and
        mount["RW"] === true and mount["Mode"] in ["", "z"] and mount["Propagation"] == ""
    end) and length(Enum.uniq_by(mounts, & &1["Destination"])) == 3
  end

  defp actual_mounts?(_, _), do: false

  defp network?(settings, intended, id) when is_map(settings) do
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
         true <- unpublished_ports?(settings["Ports"]),
         aliases when is_list(aliases) <- endpoint["Aliases"],
         allowed = ["neo4j", intended["name"], id, String.slice(id, 0, 12)],
         true <-
           "neo4j" in aliases and length(aliases) == length(Enum.uniq(aliases)) and
             Enum.all?(aliases, &(&1 in allowed)),
         true <-
           is_nil(endpoint["DNSNames"]) or
             (is_list(endpoint["DNSNames"]) and Enum.all?(endpoint["DNSNames"], &(&1 in allowed))) do
      true
    else
      _ -> false
    end
  end

  defp network?(_, _, _), do: false

  defp state?(%{"Status" => status} = state) when status in ["created", "running"] do
    state["Running"] === (status == "running") and
      Enum.all?(~w(Paused Restarting OOMKilled Dead), &(state[&1] === false)) and
      state["Error"] == "" and state["ExitCode"] == 0
  end

  defp state?(_), do: false
  defp restart?(%{"Name" => name, "MaximumRetryCount" => 0}), do: name in ["no", ""]
  defp restart?(_), do: false
  defp exposed?(nil), do: true

  defp exposed?(ports) when is_map(ports),
    do: Enum.all?(ports, fn {key, value} -> key in @ports and value == %{} end)

  defp exposed?(_), do: false
  defp unpublished_ports?(nil), do: true

  defp unpublished_ports?(ports) when is_map(ports),
    do: Enum.all?(ports, fn {key, value} -> key in @ports and is_nil(value) end)

  defp unpublished_ports?(_), do: false
  defp empty_list?(value), do: is_nil(value) or value == []
  defp empty_map?(value), do: is_nil(value) or value == %{}
  defp compact(id), do: String.replace(id, "-", "")
  defp uuid?(value), do: is_binary(value) and match?({:ok, ^value}, Ecto.UUID.cast(value))
  defp hex?(value), do: is_binary(value) and Regex.match?(~r/\A[a-f0-9]{64}\z/, value)
  defp image?("sha256:" <> hash), do: hex?(hash)
  defp image?(_), do: false
end
