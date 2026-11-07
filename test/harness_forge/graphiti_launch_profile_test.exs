defmodule HarnessForge.Graphiti.LaunchProfileTest do
  use ExUnit.Case, async: true
  alias HarnessForge.Contracts
  alias HarnessForge.Graphiti.LaunchProfile

  @workspace "11111111-1111-4111-8111-111111111111"
  @partition "22222222-2222-4222-8222-222222222222"
  @session "33333333-3333-4333-8333-333333333333"
  @other_session "44444444-4444-4444-8444-444444444444"
  @container String.duplicate("d", 64)
  @network String.duplicate("e", 64)
  @image "sha256:" <> String.duplicate("a", 64)
  @network_name "hf-graph-net-22222222222242228222222222222222"
  @worker_name "hf-graph-worker-22222222222242228222222222222222"
  @gateway "com.docker.network.bridge.gateway_mode_ipv4"
  @ipv4 "com.docker.network.enable_ipv4"
  @environment ["PATH=/usr/local/bin:/usr/bin:/bin", "LANG=C.UTF-8", "GPG_KEY=public-fixture-key"]

  test "argv is immutable image-only create with the exact isolated resources and pipe attachments" do
    spec = spec()
    assert {:ok, argv} = LaunchProfile.worker_args(spec)
    assert Enum.take(argv, 2) == ["create", "--pull"]
    assert List.last(argv) == @image
    assert option(argv, "--pull") == "never"
    assert option(argv, "--name") == @worker_name
    assert options(argv, "--attach") == ["stdin", "stdout"]
    assert option(argv, "--network") == @network_name
    assert option(argv, "--network-alias") == "worker"
    assert option(argv, "--user") == "65532:65532"
    assert option(argv, "--cap-drop") == "ALL"
    assert option(argv, "--security-opt") == "no-new-privileges:true"
    assert option(argv, "--pids-limit") == "64"
    assert option(argv, "--memory") == "805306368"
    assert option(argv, "--memory-swap") == "805306368"
    assert option(argv, "--cpus") == "1"
    assert option(argv, "--tmpfs") == "/tmp:rw,noexec,nosuid,nodev,size=67108864"
    assert option(argv, "--log-driver") == "none"
    assert option(argv, "--stop-timeout") == "10"
    assert option(argv, "--ipc") == "private"
    assert option(argv, "--cgroupns") == "private"
    assert "--read-only" in argv and "--interactive" in argv

    for forbidden <- [
          "--env",
          "--env-file",
          "--entrypoint",
          "--privileged",
          "--cap-add",
          "--volume",
          "--mount",
          "--device",
          "--publish",
          "--tty"
        ] do
      refute forbidden in argv
    end

    assert {:ok, intended} = LaunchProfile.worker_profile(spec)
    assert intended["argv"] == argv
    assert intended["profile_id"] == "graph-worker-isolated-v1"
  end

  test "only the seven strict scope fields are accepted" do
    for bad <- [
          Map.put(spec(), "command", "bash"),
          Map.put(spec(), "environment", %{}),
          Map.delete(spec(), "session_id"),
          Map.put(spec(), "workspace_id", "workspace"),
          Map.put(spec(), "partition_id", nil),
          Map.put(spec(), "session_id", @session <> "x"),
          Map.put(spec(), "worker_image", "worker:latest"),
          Map.put(spec(), "network_id", String.duplicate("E", 64)),
          Map.put(spec(), "network_name", "external"),
          Map.put(spec(), "image_env_digest", "bad"),
          %{workspace_id: @workspace}
        ] do
      assert {:error, :invalid_graph_launch_profile} = LaunchProfile.worker_args(bad)
      assert {:error, :invalid_graph_launch_profile} = LaunchProfile.worker_profile(bad)
    end
  end

  test "offline native replay retains process isolation and refuses any network or executable substitution" do
    assert {:ok, argv} = HarnessForge.Graphiti.ResponseProof.args(spec())
    assert option(argv, "--network") == "none"
    refute "--network-alias" in argv
    assert Enum.take(argv, -4) == ["python", @image, "-I", "/app/response_proof.py"]

    actual =
      inspection()
      |> Map.put("Name", "/hf-graph-replay-" <> String.replace(@session, "-", ""))
      |> Map.put("Args", ["-I", "/app/response_proof.py"])
      |> put_in(["Config", "Entrypoint"], ["python"])
      |> put_in(["Config", "Cmd"], ["-I", "/app/response_proof.py"])
      |> put_in(
        ["Config", "Labels", "dev.harnessforge.profile"],
        "graph-response-replay-isolated-v1"
      )
      |> put_in(["HostConfig", "NetworkMode"], "none")
      |> put_in(["NetworkSettings", "Networks"], %{
        "none" => %{"IPAddress" => "", "Gateway" => "", "Aliases" => nil}
      })

    assert {:ok, _} = LaunchProfile.verify_replay(spec(), actual)

    for {path, value} <- [
          {["HostConfig", "NetworkMode"], "host"},
          {["NetworkSettings", "Networks"], %{"none" => %{}, "extra" => %{}}},
          {["NetworkSettings", "Networks", "none", "IPAddress"], "10.0.0.2"},
          {["Config", "Cmd"], ["-c", "untrusted"]},
          {["Config", "User"], "0:0"},
          {["HostConfig", "Binds"], ["/:/host"]},
          {["HostConfig", "Privileged"], true},
          {["HostConfig", "LogConfig"], %{"Type" => "json-file", "Config" => %{}}}
        ] do
      assert {:error, :graph_launch_mismatch} =
               LaunchProfile.verify_replay(spec(), put_in(actual, path, value))
    end
  end

  test "created and running inspection yield exactly a scoped receipt without environment data" do
    spec = spec()
    {:ok, intended} = LaunchProfile.worker_profile(spec)
    assert {:ok, receipt} = LaunchProfile.verify_worker(spec, inspection())

    assert receipt == %{
             "container_id" => @container,
             "image_id" => @image,
             "profile_digest" => Contracts.digest(intended),
             "network_id" => @network,
             "session_id" => @session
           }

    running =
      inspection() |> put_in(["State", "Status"], "running") |> put_in(["State", "Running"], true)

    assert {:ok, ^receipt} = LaunchProfile.verify_worker(spec, running)
    reversed = put_in(inspection(), ["Config", "Env"], Enum.reverse(@environment))
    assert {:ok, ^receipt} = LaunchProfile.verify_worker(spec, reversed)
    other = Map.put(spec, "session_id", @other_session)
    {:ok, other_profile} = LaunchProfile.worker_profile(other)
    refute Contracts.digest(other_profile) == receipt["profile_digest"]
    assert {:error, :graph_launch_mismatch} = LaunchProfile.verify_worker(other, inspection())
  end

  test "image, executable, arguments, user, working directory and scope mismatches deny" do
    changes = [
      {["Image"], "sha256:" <> String.duplicate("b", 64)},
      {["Config", "Image"], "sha256:" <> String.duplicate("b", 64)},
      {["Id"], String.duplicate("D", 64)},
      {["Name"], "/foreign-worker"},
      {["Path"], "bash"},
      {["Args"], ["-I", "/app/__main__.py", "unexpected"]},
      {["Config", "Entrypoint"], ["python", "/app/__main__.py"]},
      {["Config", "Cmd"], ["sh"]},
      {["Config", "WorkingDir"], "/tmp"},
      {["Config", "User"], "0:0"},
      {["Config", "Labels", "dev.harnessforge.session"], @other_session},
      {["Config", "Labels", "dev.harnessforge.workspace"], @other_session}
    ]

    for {path, value} <- changes, do: assert_mismatch(put_in(inspection(), path, value))
    assert_mismatch(update_in(inspection(), ["Config"], &Map.delete(&1, "Cmd")))
  end

  test "weak security, resource, temporary-storage and logging policies deny" do
    changes = [
      {["HostConfig", "ReadonlyRootfs"], false},
      {["HostConfig", "Privileged"], true},
      {["HostConfig", "CapDrop"], []},
      {["HostConfig", "CapAdd"], ["SYS_ADMIN"]},
      {["HostConfig", "SecurityOpt"], ["no-new-privileges:false"]},
      {["HostConfig", "PidsLimit"], -1},
      {["HostConfig", "Memory"], 0},
      {["HostConfig", "MemorySwap"], -1},
      {["HostConfig", "NanoCpus"], 2_000_000_000},
      {["HostConfig", "CpuQuota"], -1},
      {["HostConfig", "Tmpfs"], %{"/tmp" => "rw,exec,nosuid,nodev,size=67108864"}},
      {["HostConfig", "LogConfig"], %{"Type" => "json-file", "Config" => %{}}},
      {["HostConfig", "IpcMode"], "host"},
      {["HostConfig", "PidMode"], "host"},
      {["HostConfig", "UTSMode"], "host"},
      {["HostConfig", "CgroupnsMode"], "host"},
      {["HostConfig", "UsernsMode"], "host"},
      {["Config", "StopTimeout"], 11},
      {["HostConfig", "RestartPolicy"], %{"Name" => "always", "MaximumRetryCount" => 0}}
    ]

    for {path, value} <- changes, do: assert_mismatch(put_in(inspection(), path, value))
  end

  test "host mounts, Docker socket, volumes, devices and host port publication deny" do
    changes = [
      {["HostConfig", "Binds"], ["/var/run/docker.sock:/var/run/docker.sock"]},
      {["HostConfig", "Mounts"], [%{"Type" => "bind", "Source" => "/", "Target" => "/host"}]},
      {["Mounts"], [%{"Type" => "volume", "Destination" => "/app"}]},
      {["Config", "Volumes"], %{"/data" => %{}}},
      {["HostConfig", "VolumesFrom"], ["host-data"]},
      {["HostConfig", "Devices"], [%{"PathOnHost" => "/dev/kvm"}]},
      {["HostConfig", "DeviceRequests"], [%{"Count" => -1}]},
      {["HostConfig", "DeviceCgroupRules"], ["a *:* rwm"]},
      {["HostConfig", "PortBindings"], %{"8000/tcp" => [%{"HostPort" => "8000"}]}},
      {["HostConfig", "PublishAllPorts"], true}
    ]

    for {path, value} <- changes, do: assert_mismatch(put_in(inspection(), path, value))
  end

  test "TTY, attached stderr, closed input and unsafe runtime state deny" do
    for {path, value} <- [
          {["Config", "Tty"], true},
          {["Config", "AttachStderr"], true},
          {["Config", "OpenStdin"], false},
          {["Config", "AttachStdin"], false},
          {["Config", "AttachStdout"], false},
          {["Config", "StdinOnce"], false},
          {["State", "Status"], "exited"},
          {["State", "Paused"], true},
          {["State", "Restarting"], true},
          {["State", "OOMKilled"], true},
          {["State", "Dead"], true}
        ],
        do: assert_mismatch(put_in(inspection(), path, value))
  end

  test "credential and proxy families deny even when their new environment hash is pinned" do
    for key <- [
          "OPENAI_API_KEY",
          "HF_TOKEN",
          "SECRET",
          "PASSWORD",
          "http_proxy",
          "HTTPS_PROXY",
          "ALL_PROXY",
          "NO_PROXY",
          "DOCKER_HOST",
          "HARNESSFORGE_MODEL_KEY"
        ] do
      env = @environment ++ [key <> "=synthetic-value"]
      pinned = Map.put(spec(), "image_env_digest", Contracts.digest(Enum.sort(env)))

      assert {:error, :graph_launch_mismatch} =
               LaunchProfile.verify_worker(pinned, put_in(inspection(), ["Config", "Env"], env))
    end

    # A public base-image GPG_KEY is deliberately allowed; pin equality still
    # detects any changed value and duplicate environment names are rejected.
    assert {:ok, _} = LaunchProfile.verify_worker(spec(), inspection())
    env = @environment ++ ["LANG=other"]
    pinned = Map.put(spec(), "image_env_digest", Contracts.digest(Enum.sort(env)))

    assert {:error, :graph_launch_mismatch} =
             LaunchProfile.verify_worker(pinned, put_in(inspection(), ["Config", "Env"], env))

    assert_mismatch(put_in(inspection(), ["Config", "Env"], ["LANG=changed"]))
  end

  test "the only worker network must be the intended network ID with no IPv6 or foreign aliases" do
    for {path, value} <- [
          {["HostConfig", "NetworkMode"], "host"},
          {["NetworkSettings", "Networks", @network_name, "NetworkID"],
           String.duplicate("f", 64)},
          {["NetworkSettings", "Networks", @network_name, "GlobalIPv6Address"], "fd00::2"},
          {["NetworkSettings", "Networks", @network_name, "Aliases"], ["other"]},
          {["NetworkSettings", "Networks", @network_name, "Aliases"], ["worker", "foreign-alias"]}
        ],
        do: assert_mismatch(put_in(inspection(), path, value))

    assert_mismatch(
      update_in(
        inspection(),
        ["NetworkSettings", "Networks"],
        &Map.put(&1, "external", %{"NetworkID" => @network})
      )
    )
  end

  test "network argv and inspection bind an isolated internal bridge with a scope-only receipt" do
    assert {:ok, argv} = LaunchProfile.network_args(@workspace, @partition)
    assert Enum.take(argv, 4) == ["network", "create", "--driver", "bridge"]
    assert "--internal" in argv and "--ipv6=false" in argv
    assert option(argv, "--opt") == @gateway <> "=isolated"
    assert List.last(argv) == @network_name

    assert {:ok, receipt} =
             LaunchProfile.verify_network(@workspace, @partition, network_inspection())

    assert Enum.sort(Map.keys(receipt)) == ~w(network_id network_name profile_digest)
    assert receipt["network_id"] == @network and receipt["network_name"] == @network_name

    original = network_inspection() |> Map.put("Options", %{@gateway => "isolated"})
    assert {:ok, ^receipt} = LaunchProfile.verify_network(@workspace, @partition, original)

    assert {:ok, ^receipt} =
             LaunchProfile.verify_network(
               @workspace,
               @partition,
               Map.delete(original, "EnableIPv4")
             )

    assert {:error, :invalid_graph_launch_profile} =
             LaunchProfile.network_args("foreign", @partition)

    assert {:error, :graph_launch_mismatch} =
             LaunchProfile.verify_network(@other_session, @partition, network_inspection())
  end

  test "external networks, other drivers and changed gateway/options/labels deny" do
    for {key, value} <- [
          {"Id", "bad"},
          {"Name", "external"},
          {"Driver", "host"},
          {"Internal", false},
          {"EnableIPv4", false},
          {"EnableIPv4", "true"},
          {"EnableIPv4", nil},
          {"EnableIPv6", true},
          {"Scope", "swarm"},
          {"Options", %{@gateway => "nat"}},
          {"Options", %{@gateway => "isolated", @ipv4 => "false"}},
          {"Options", %{@gateway => "isolated", @ipv4 => true}},
          {"Options", %{@gateway => "isolated", @ipv4 => "true", "unexpected" => "true"}},
          {"Options", %{@gateway => "isolated", "unexpected" => "true"}},
          {"Labels", %{}}
        ] do
      assert {:error, :graph_launch_mismatch} =
               LaunchProfile.verify_network(
                 @workspace,
                 @partition,
                 Map.put(network_inspection(), key, value)
               )
    end
  end

  defp spec do
    %{
      "workspace_id" => @workspace,
      "partition_id" => @partition,
      "session_id" => @session,
      "worker_image" => @image,
      "network_name" => @network_name,
      "network_id" => @network,
      "image_env_digest" => Contracts.digest(Enum.sort(@environment))
    }
  end

  defp inspection do
    %{
      "Id" => @container,
      "Name" => "/" <> @worker_name,
      "Image" => @image,
      "Path" => "python",
      "Args" => ["-I", "/app/__main__.py"],
      "Mounts" => [],
      "Config" => %{
        "Image" => @image,
        "Entrypoint" => ["python", "-I", "/app/__main__.py"],
        "Cmd" => nil,
        "WorkingDir" => "/app",
        "User" => "65532:65532",
        "Labels" => Map.put(network_labels(), "dev.harnessforge.session", @session),
        "Env" => @environment,
        "Volumes" => nil,
        "ExposedPorts" => nil,
        "StopTimeout" => 10,
        "OpenStdin" => true,
        "AttachStdin" => true,
        "AttachStdout" => true,
        "AttachStderr" => false,
        "Tty" => false,
        "StdinOnce" => true
      },
      "HostConfig" => %{
        "NetworkMode" => @network_name,
        "ReadonlyRootfs" => true,
        "Privileged" => false,
        "CapDrop" => ["ALL"],
        "CapAdd" => nil,
        "SecurityOpt" => ["no-new-privileges:true"],
        "PidsLimit" => 64,
        "Memory" => 805_306_368,
        "MemorySwap" => 805_306_368,
        "NanoCpus" => 1_000_000_000,
        "CpuPeriod" => 0,
        "CpuQuota" => 0,
        "CpuShares" => 0,
        "CpusetCpus" => "",
        "CpusetMems" => "",
        "Tmpfs" => %{"/tmp" => "rw,noexec,nosuid,nodev,size=67108864"},
        "IpcMode" => "private",
        "CgroupnsMode" => "private",
        "PidMode" => "",
        "UTSMode" => "",
        "UsernsMode" => "",
        "PublishAllPorts" => false,
        "PortBindings" => %{},
        "Binds" => nil,
        "Mounts" => nil,
        "VolumesFrom" => nil,
        "Devices" => [],
        "DeviceRequests" => nil,
        "DeviceCgroupRules" => nil,
        "Links" => nil,
        "ExtraHosts" => nil,
        "Dns" => [],
        "DnsOptions" => [],
        "DnsSearch" => [],
        "LogConfig" => %{"Type" => "none", "Config" => %{}},
        "RestartPolicy" => %{"Name" => "no", "MaximumRetryCount" => 0}
      },
      "State" => %{
        "Status" => "created",
        "Running" => false,
        "Paused" => false,
        "Restarting" => false,
        "OOMKilled" => false,
        "Dead" => false,
        "Error" => "",
        "ExitCode" => 0
      },
      "NetworkSettings" => %{
        "Ports" => %{},
        "Networks" => %{
          @network_name => %{
            "NetworkID" => @network,
            "GlobalIPv6Address" => "",
            "IPv6Gateway" => "",
            "Aliases" => [@worker_name, "worker"],
            "DNSNames" => [@worker_name, "worker", String.slice(@container, 0, 12)]
          }
        }
      }
    }
  end

  defp network_inspection do
    %{
      "Id" => @network,
      "Name" => @network_name,
      "Driver" => "bridge",
      "Internal" => true,
      "EnableIPv4" => true,
      "EnableIPv6" => false,
      "Scope" => "local",
      "Options" => %{@gateway => "isolated", @ipv4 => "true"},
      "Labels" => network_labels()
    }
  end

  defp network_labels,
    do: %{
      "dev.harnessforge.workspace" => @workspace,
      "dev.harnessforge.partition" => @partition,
      "dev.harnessforge.profile" => "graph-worker-isolated-v1"
    }

  defp assert_mismatch(inspection),
    do:
      assert({:error, :graph_launch_mismatch} == LaunchProfile.verify_worker(spec(), inspection))

  defp option(argv, key),
    do:
      argv
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.find_value(fn [flag, value] -> if flag == key, do: value end)

  defp options(argv, key),
    do:
      argv
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.flat_map(fn [flag, value] -> if flag == key, do: [value], else: [] end)
end
