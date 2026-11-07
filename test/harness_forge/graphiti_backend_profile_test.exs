defmodule HarnessForge.Graphiti.BackendProfileTest do
  use ExUnit.Case, async: true
  alias HarnessForge.Contracts
  alias HarnessForge.Graphiti.BackendProfile

  @workspace "11111111-1111-4111-8111-111111111111"
  @partition "22222222-2222-4222-8222-222222222222"
  @suffix "22222222222242228222222222222222"
  @name "hf-graph-backend-" <> @suffix
  @network_name "hf-graph-net-" <> @suffix
  @image "sha256:" <> String.duplicate("a", 64)
  @container String.duplicate("d", 64)
  @network String.duplicate("e", 64)
  @env ["PATH=/usr/bin:/bin", "JAVA_HOME=/opt/java", "NEO4J_AUTH=neo4j/synthetic-test-only"]
  @tmpfs %{
    "/tmp" => "rw,noexec,nosuid,nodev,size=134217728,uid=7474,gid=7474",
    "/tmp/neo4j-native" => "rw,exec,nosuid,nodev,size=16777216,uid=7474,gid=7474",
    "/var/lib/neo4j/run" => "rw,noexec,nosuid,nodev,size=16777216,uid=7474,gid=7474"
  }

  test "exact seven-key spec accepts an inert absolute path without reading it" do
    assert {:ok, _} = BackendProfile.backend_profile(spec())

    for bad <- [
          Map.put(spec(), "image_env_digest", String.duplicate("a", 64)),
          Map.put(spec(), "password", "synthetic"),
          Map.delete(spec(), "env_digest"),
          Map.put(spec(), "backend_image", "neo4j:latest"),
          Map.put(spec(), "network_name", "external"),
          Map.put(spec(), "network_id", String.duplicate("E", 64))
        ] do
      assert {:error, :invalid_graph_launch_profile} = BackendProfile.backend_args(bad)
    end

    for path <- [
          "relative.env",
          "/tmp/../secret.env",
          "/tmp/./secret.env",
          "/tmp//secret.env",
          "/tmp/secret.env\n",
          "/tmp/secret.env\r",
          "/tmp/secret.env" <> <<0>>,
          "/",
          "/tmp/"
        ] do
      assert {:error, :invalid_graph_launch_profile} =
               BackendProfile.backend_profile(Map.put(spec(), "env_file", path))
    end
  end

  test "argv pins the image, resources, isolation, env-file and three named volumes without attaches" do
    assert {:ok, argv} = BackendProfile.backend_args(spec())
    assert List.last(argv) == @image

    for {flag, expected} <- [
          {"--pull", "never"},
          {"--name", @name},
          {"--user", "7474:7474"},
          {"--network", @network_name},
          {"--network-alias", "neo4j"},
          {"--cap-drop", "ALL"},
          {"--security-opt", "no-new-privileges:true"},
          {"--pids-limit", "256"},
          {"--memory", "1610612736"},
          {"--memory-swap", "1610612736"},
          {"--cpus", "2"},
          {"--stop-timeout", "30"},
          {"--log-driver", "none"},
          {"--ipc", "private"},
          {"--cgroupns", "private"},
          {"--env-file", spec()["env_file"]}
        ] do
      assert option(argv, flag) == expected
    end

    assert "--read-only" in argv
    assert length(options(argv, "--mount")) == 3
    assert "type=volume,source=hf-graph-data-#{@suffix},target=/data" in options(argv, "--mount")
    assert "type=volume,source=hf-graph-logs-#{@suffix},target=/logs" in options(argv, "--mount")

    assert "type=volume,source=hf-graph-conf-#{@suffix},target=/var/lib/neo4j/conf" in options(
             argv,
             "--mount"
           )

    assert Enum.sort(options(argv, "--tmpfs")) ==
             Enum.sort(Enum.map(@tmpfs, fn {path, flags} -> path <> ":" <> flags end))

    for forbidden <- [
          "--attach",
          "--interactive",
          "--tty",
          "--entrypoint",
          "--env",
          "--privileged",
          "--cap-add",
          "--publish",
          "--device",
          "--volume"
        ],
        do: refute(forbidden in argv)

    {:ok, intended} = BackendProfile.backend_profile(spec())
    refute String.contains?(Contracts.canonical_json(intended), "synthetic-test-only")
    assert intended["env_digest"] == spec()["env_digest"]
  end

  test "valid synthetic inspection returns only the four scoped receipt fields" do
    {:ok, intended} = BackendProfile.backend_profile(spec())
    assert {:ok, receipt} = BackendProfile.verify_backend(spec(), inspection())

    assert receipt == %{
             "container_id" => @container,
             "image_id" => @image,
             "network_id" => @network,
             "profile_digest" => Contracts.digest(intended)
           }

    assert {:ok, ^receipt} =
             BackendProfile.verify_backend(
               spec(),
               put_in(inspection(), ["Config", "Env"], Enum.reverse(@env))
             )

    running =
      inspection() |> put_in(["State", "Status"], "running") |> put_in(["State", "Running"], true)

    assert {:ok, ^receipt} = BackendProfile.verify_backend(spec(), running)
    # Internal Docker volume Source is a locator, not proof of storage
    # provenance. Root separately qualifies dedicated volume identity/options.
    moved =
      update_in(
        inspection(),
        ["Mounts"],
        &Enum.map(&1, fn mount -> Map.put(mount, "Source", "/another-docker-internal-locator") end)
      )

    assert {:ok, ^receipt} = BackendProfile.verify_backend(spec(), moved)
  end

  test "foreign content, scope, executable, command and user are refused" do
    for {path, value} <- [
          {["Image"], "sha256:" <> String.duplicate("b", 64)},
          {["Config", "Image"], "neo4j:tag"},
          {["Name"], "/another-backend"},
          {["Path"], "sh"},
          {["Args"], ["neo4j", "console", "extra"]},
          {["Config", "Entrypoint"], ["sh"]},
          {["Config", "Cmd"], ["neo4j", "extra"]},
          {["Config", "WorkingDir"], "/tmp"},
          {["Config", "User"], "0:0"},
          {["Config", "Labels", "dev.harnessforge.workspace"], @partition},
          {["HostConfig", "NetworkMode"], "host"},
          {["NetworkSettings", "Networks", @network_name, "NetworkID"],
           String.duplicate("f", 64)},
          {["NetworkSettings", "Networks", @network_name, "GlobalIPv6Address"], "fd00::2"}
        ],
        do: mismatch(put_in(inspection(), path, value))

    mismatch(
      update_in(
        inspection(),
        ["NetworkSettings", "Networks"],
        &Map.put(&1, "external", %{"NetworkID" => @network})
      )
    )
  end

  test "exact three volume names, destinations, driver, write mode and declaration are required" do
    for {field, value} <- [
          {"Type", "bind"},
          {"Name", "foreign-volume"},
          {"Destination", "/host"},
          {"Driver", "nfs"},
          {"RW", false},
          {"Mode", "shared"},
          {"Propagation", "rshared"}
        ] do
      mismatch(update_in(inspection(), ["Mounts", Access.at(0)], &Map.put(&1, field, value)))
    end

    mismatch(update_in(inspection(), ["Mounts"], &tl/1))
    mismatch(update_in(inspection(), ["Mounts"], fn [first | _] -> [first, first, first] end))

    mismatch(
      put_in(inspection(), ["Config", "Volumes"], %{
        "/data" => %{},
        "/logs" => %{},
        "/host" => %{}
      })
    )

    mismatch(put_in(inspection(), ["HostConfig", "Binds"], ["/var/run/docker.sock:/socket"]))

    mismatch(
      update_in(
        inspection(),
        ["HostConfig", "Mounts", Access.at(0)],
        &Map.put(&1, "Source", "/host-bind")
      )
    )

    mismatch(
      update_in(
        inspection(),
        ["HostConfig", "Mounts", Access.at(0)],
        &Map.put(&1, "ReadOnly", true)
      )
    )
  end

  test "only dedicated native tmpfs may execute, with all ownership/size restrictions intact" do
    assert {:ok, _} = BackendProfile.verify_backend(spec(), inspection())

    mismatch(
      put_in(
        inspection(),
        ["HostConfig", "Tmpfs", "/tmp"],
        "rw,exec,nosuid,nodev,size=134217728,uid=7474,gid=7474"
      )
    )

    mismatch(
      put_in(
        inspection(),
        ["HostConfig", "Tmpfs", "/tmp/neo4j-native"],
        "rw,exec,nosuid,nodev,size=16777216,uid=0,gid=0"
      )
    )

    mismatch(
      put_in(
        inspection(),
        ["HostConfig", "Tmpfs", "/tmp/neo4j-native"],
        "rw,noexec,nosuid,nodev,size=16777216,uid=7474,gid=7474"
      )
    )

    mismatch(
      update_in(inspection(), ["HostConfig", "Tmpfs"], &Map.put(&1, "/another-exec", "rw,exec"))
    )
  end

  test "published ports, weakened resources/security, devices and changed stream flags are refused" do
    for {path, value} <- [
          {["HostConfig", "ReadonlyRootfs"], false},
          {["HostConfig", "Privileged"], true},
          {["HostConfig", "CapAdd"], ["SYS_ADMIN"]},
          {["HostConfig", "CapDrop"], []},
          {["HostConfig", "SecurityOpt"], ["no-new-privileges:false"]},
          {["HostConfig", "PidsLimit"], -1},
          {["HostConfig", "Memory"], 0},
          {["HostConfig", "MemorySwap"], -1},
          {["HostConfig", "NanoCpus"], 1_000_000_000},
          {["HostConfig", "IpcMode"], "host"},
          {["HostConfig", "CgroupnsMode"], "host"},
          {["HostConfig", "PidMode"], "host"},
          {["HostConfig", "Devices"], [%{"PathOnHost" => "/dev/kvm"}]},
          {["HostConfig", "ExtraHosts"], ["external:host-gateway"]},
          {["HostConfig", "PortBindings"], %{"7687/tcp" => [%{"HostPort" => "7687"}]}},
          {["HostConfig", "PublishAllPorts"], true},
          {["NetworkSettings", "Ports"], %{"7687/tcp" => [%{"HostPort" => "7687"}]}},
          {["HostConfig", "LogConfig"], %{"Type" => "json-file", "Config" => %{}}},
          {["Config", "Tty"], true},
          {["Config", "OpenStdin"], true},
          {["Config", "AttachStdin"], true},
          {["Config", "AttachStdout"], false},
          {["Config", "AttachStderr"], false},
          {["Config", "StopTimeout"], 10},
          {["State", "Status"], "exited"},
          {["State", "OOMKilled"], true}
        ],
        do: mismatch(put_in(inspection(), path, value))
  end

  test "only exact hashed environment permits the private Neo4j auth; provider/proxy/OTEL keys deny" do
    for key <- [
          "OPENAI_API_KEY",
          "ANTHROPIC_API_KEY",
          "AWS_ACCESS_KEY_ID",
          "PASSWORD",
          "SERVICE_TOKEN",
          "SECRET",
          "http_proxy",
          "NO_PROXY",
          "OTEL_EXPORTER_OTLP_ENDPOINT",
          "DOCKER_HOST",
          "HARNESSFORGE_KEY",
          "AUTH_TOKEN"
        ] do
      env = @env ++ [key <> "=synthetic-value"]
      pinned = Map.put(spec(), "env_digest", Contracts.digest(Enum.sort(env)))

      assert {:error, :graph_launch_mismatch} =
               BackendProfile.verify_backend(pinned, put_in(inspection(), ["Config", "Env"], env))
    end

    mismatch(
      put_in(inspection(), ["Config", "Env"], ["NEO4J_AUTH=neo4j/different-synthetic-value"])
    )

    duplicate = @env ++ ["NEO4J_AUTH=neo4j/duplicate-synthetic-value"]

    assert {:error, :graph_launch_mismatch} =
             BackendProfile.verify_backend(
               Map.put(spec(), "env_digest", Contracts.digest(Enum.sort(duplicate))),
               put_in(inspection(), ["Config", "Env"], duplicate)
             )
  end

  defp spec,
    do: %{
      "workspace_id" => @workspace,
      "partition_id" => @partition,
      "backend_image" => @image,
      "network_name" => @network_name,
      "network_id" => @network,
      "env_file" => "/private/tmp/nonexistent-public-fixture/auth.env",
      "env_digest" => Contracts.digest(Enum.sort(@env))
    }

  defp labels,
    do: %{
      "dev.harnessforge.workspace" => @workspace,
      "dev.harnessforge.partition" => @partition,
      "dev.harnessforge.profile" => "graph-backend-isolated-v1"
    }

  defp volumes,
    do: %{
      "/data" => "hf-graph-data-" <> @suffix,
      "/logs" => "hf-graph-logs-" <> @suffix,
      "/var/lib/neo4j/conf" => "hf-graph-conf-" <> @suffix
    }

  defp inspection do
    %{
      "Id" => @container,
      "Name" => "/" <> @name,
      "Image" => @image,
      "Path" => "tini",
      "Args" => ["-g", "--", "/startup/docker-entrypoint.sh", "neo4j"],
      "Config" => %{
        "Image" => @image,
        "Entrypoint" => ["tini", "-g", "--", "/startup/docker-entrypoint.sh"],
        "Cmd" => ["neo4j"],
        "WorkingDir" => "/var/lib/neo4j",
        "User" => "7474:7474",
        "Labels" => labels(),
        "Env" => @env,
        "Volumes" => %{"/data" => %{}, "/logs" => %{}},
        "ExposedPorts" => %{"7473/tcp" => %{}, "7474/tcp" => %{}, "7687/tcp" => %{}},
        "StopTimeout" => 30,
        "AttachStdin" => false,
        "AttachStdout" => true,
        "AttachStderr" => true,
        "OpenStdin" => false,
        "Tty" => false,
        "StdinOnce" => false
      },
      "HostConfig" => %{
        "NetworkMode" => @network_name,
        "ReadonlyRootfs" => true,
        "Privileged" => false,
        "CapDrop" => ["ALL"],
        "CapAdd" => [],
        "SecurityOpt" => ["no-new-privileges:true"],
        "PidsLimit" => 256,
        "Memory" => 1_610_612_736,
        "MemorySwap" => 1_610_612_736,
        "NanoCpus" => 2_000_000_000,
        "CpuPeriod" => 0,
        "CpuQuota" => 0,
        "CpuShares" => 0,
        "CpusetCpus" => "",
        "CpusetMems" => "",
        "Tmpfs" => @tmpfs,
        "IpcMode" => "private",
        "CgroupnsMode" => "private",
        "PidMode" => "",
        "UTSMode" => "",
        "UsernsMode" => "",
        "PublishAllPorts" => false,
        "PortBindings" => %{},
        "Binds" => nil,
        "VolumesFrom" => nil,
        "Devices" => [],
        "DeviceRequests" => nil,
        "DeviceCgroupRules" => nil,
        "Links" => nil,
        "ExtraHosts" => nil,
        "Dns" => [],
        "DnsOptions" => [],
        "DnsSearch" => [],
        "Mounts" =>
          Enum.map(volumes(), fn {path, name} ->
            %{
              "Type" => "volume",
              "Source" => name,
              "Target" => path,
              "ReadOnly" => false,
              "VolumeOptions" => %{"NoCopy" => false}
            }
          end),
        "LogConfig" => %{"Type" => "none", "Config" => %{}},
        "RestartPolicy" => %{"Name" => "no", "MaximumRetryCount" => 0}
      },
      "Mounts" =>
        Enum.map(volumes(), fn {path, name} ->
          %{
            "Type" => "volume",
            "Name" => name,
            "Destination" => path,
            "Driver" => "local",
            "RW" => true,
            "Mode" => "z",
            "Propagation" => "",
            "Source" => "/docker-internal/volumes/" <> name <> "/_data"
          }
        end),
      "NetworkSettings" => %{
        "Ports" => %{"7473/tcp" => nil, "7474/tcp" => nil, "7687/tcp" => nil},
        "Networks" => %{
          @network_name => %{
            "NetworkID" => @network,
            "GlobalIPv6Address" => "",
            "IPv6Gateway" => "",
            "Aliases" => [@name, "neo4j"],
            "DNSNames" => [@name, "neo4j", String.slice(@container, 0, 12)]
          }
        }
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
      }
    }
  end

  defp mismatch(inspection),
    do:
      assert(
        {:error, :graph_launch_mismatch} == BackendProfile.verify_backend(spec(), inspection)
      )

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
