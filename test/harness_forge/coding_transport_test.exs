defmodule HarnessForge.CodingTransportTest do
  use ExUnit.Case, async: false
  alias HarnessForge.CodingDockerFixture, as: Fixture
  alias HarnessForge.Execution.{Coding, CodingTransport, Command}

  setup do
    fixture = Fixture.install!()
    on_exit(fn -> Fixture.restore(fixture) end)
    %{fixture: fixture}
  end

  test "actual Port argv pins the endpoint and clears all Docker overrides", %{fixture: f} do
    for key <-
          ~w(DOCKER_CONTEXT DOCKER_HOST DOCKER_TLS DOCKER_TLS_VERIFY DOCKER_CERT_PATH DOCKER_API_VERSION),
        do: System.put_env(key, "synthetic-sentinel")

    assert {:ok, %{exit_status: 0}} =
             Command.docker_at(f.endpoint, ["image", "inspect", "synthetic"])

    assert [%{"argv" => ["--host", endpoint | _], "env" => env}] = Fixture.commands(f)
    assert endpoint == f.endpoint
    assert Enum.all?(env, fn {_, value} -> is_nil(value) end)

    assert {:error, :local_docker_required} =
             Command.docker_at(f.endpoint, ["--host", f.decoy_endpoint])

    assert {:error, :local_docker_required} =
             Command.docker_at(f.endpoint, ["--context=decoy", "info"])

    assert length(Fixture.commands(f)) == 1
  end

  test "context wins over host, decodes one JSON string, and rejects unsafe input", %{fixture: f} do
    Fixture.put_daemon(f, f.endpoint, %{"context" => f.decoy_endpoint})
    System.put_env("DOCKER_CONTEXT", "synthetic-context")
    assert {:ok, endpoint} = Command.local_endpoint()
    assert endpoint == f.decoy_endpoint

    assert [%{"argv" => ["context", "inspect", "synthetic-context", "--format", _]}] =
             Fixture.commands(f)

    System.put_env("DOCKER_CONTEXT", " --host=decoy")
    assert {:error, :local_docker_required} = Command.local_endpoint()
    System.delete_env("DOCKER_CONTEXT")

    for endpoint <- [
          "tcp://127.0.0.1:2375",
          " unix:///tmp/a",
          "unix:///tmp/a ",
          "unix:///tmp//a",
          "unix:///tmp/../a",
          "unix:///tmp/./a",
          "unix:///tmp/a/",
          "unix://user@host/tmp/a",
          "unix:///tmp/a?x",
          "unix:///tmp/a#x",
          "unix:///tmp/%61",
          "unix:///"
        ] do
      System.put_env("DOCKER_HOST", endpoint)
      assert {:error, :local_docker_required} = Command.local_endpoint()
    end

    refute Command.valid_endpoint?(<<255>>)
  end

  test "Desktop discovery produces a pure private-identity digest", %{fixture: f} do
    assert {:ok, observation} = CodingTransport.observe()
    commands = Fixture.commands(f)
    assert length(commands) == 1
    assert observation.route == "desktop_loopback_proxy"
    profile = Coding.profile(observation)
    assert profile["id"] == "docker-coding-isolated-v2"
    assert profile["model_route"] == "desktop_loopback_proxy"
    assert profile["proxy_external_network"] == "bridge"
    assert is_binary(profile["transport_identity_digest"])
    assert Coding.profile_digest(observation) == HarnessForge.Contracts.digest(profile)
    refute Jason.encode!(profile) =~ f.endpoint
    refute Jason.encode!(profile) =~ "HF07:ORIGINAL"
    assert Fixture.commands(f) == commands
  end

  missing_fields =
    for key <- Map.keys(Fixture.info()),
        {kind, info} <- [
          {"missing", Map.delete(Fixture.info(), key)},
          {"nil", Map.put(Fixture.info(), key, nil)}
        ] do
      {"#{kind} #{key}", info}
    end

  malformed_fields =
    missing_fields ++
      [
        {"extra field", Map.put(Fixture.info(), "extra", "bad")},
        {"empty ID", Map.put(Fixture.info(), "ID", "")},
        {"invalid ID", Map.put(Fixture.info(), "ID", "bad id")},
        {"oversized ID", Map.put(Fixture.info(), "ID", String.duplicate("a", 129))},
        {"oversized OS", Map.put(Fixture.info(), "OSType", String.duplicate("a", 17))},
        {"oversized kernel",
         Map.put(Fixture.info(), "KernelVersion", String.duplicate("a", 257))},
        {"oversized option count",
         Map.put(Fixture.info(), "SecurityOptions", List.duplicate("option", 17))},
        {"oversized option",
         Map.put(Fixture.info(), "SecurityOptions", [String.duplicate("a", 257)])}
      ]

  for {name, info} <- malformed_fields do
    @tag malformed_info: info
    test "projected metadata rejects #{name} after a healthy CLI control", %{
      fixture: f,
      malformed_info: info
    } do
      assert {:ok, observation} = CodingTransport.observe()
      assert CodingTransport.endpoint(observation) == f.endpoint
      assert CodingTransport.route(observation) == "desktop_loopback_proxy"

      Fixture.put_daemon(f, f.endpoint, %{"info" => info})
      assert {:error, :coding_transport_unavailable} = CodingTransport.observe()
      assert length(Fixture.commands(f)) == 2
    end
  end

  test "discovery refuses malformed, nonzero, oversized and timed-out CLI output", %{fixture: f} do
    for attrs <- [
          %{"raw_info" => "not-json"},
          %{"raw_info" => "[]"},
          %{"raw_info" => String.duplicate("x", 8_193)},
          %{"status" => 3},
          %{"delay_ms" => 3_100}
        ] do
      Fixture.put_daemon(
        f,
        f.endpoint,
        Map.merge(
          %{"raw_info" => Jason.encode!(Fixture.info()), "status" => 0, "delay_ms" => 0},
          attrs
        )
      )

      assert {:error, :coding_transport_unavailable} = CodingTransport.observe()
    end

    Fixture.select(f, "unix://" <> Path.join(f.root, "missing.sock"))
    assert {:error, :coding_transport_unavailable} = CodingTransport.observe()
  end

  test "unrecognized OS never falls back to a Unix route", %{fixture: f} do
    Fixture.put_daemon(f, f.endpoint, %{
      "info" => Map.put(Fixture.info(), "OperatingSystem", "Future Docker")
    })

    assert {:error, :coding_transport_unsupported} = CodingTransport.observe()

    assert Enum.all?(Fixture.commands(f), fn command ->
             ["--host", endpoint, "info" | _] = command["argv"]
             endpoint == f.endpoint
           end)
  end

  test "finite positive Desktop policy independently rejects changed required fields", %{
    fixture: f
  } do
    host = %{
      os: {:unix, :darwin},
      endpoint: f.endpoint,
      socket?: true,
      uid: 501,
      pretty_name: nil,
      kernel: nil
    }

    assert {:ok, "desktop_loopback_proxy"} = CodingTransport.supported_route(Fixture.info(), host)

    for {key, value} <- [
          {"OSType", "windows"},
          {"OperatingSystem", "future Desktop"},
          {"KernelVersion", "6.10.14-linuxkit-extra"},
          {"CgroupVersion", "1"}
        ] do
      assert {:error, :coding_transport_unsupported} =
               CodingTransport.supported_route(Map.put(Fixture.info(), key, value), host)
    end

    for changes <- [%{os: {:win32, :nt}}, %{socket?: false}, %{endpoint: "tcp://host:2375"}] do
      assert {:error, :coding_transport_unsupported} =
               CodingTransport.supported_route(Fixture.info(), Map.merge(host, changes))
    end
  end

  test "native support is a finite same-host rootful policy, never a negative Desktop fallback" do
    host = %{
      os: {:unix, :linux},
      endpoint: "unix:///var/run/docker.sock",
      socket?: true,
      uid: 0,
      pretty_name: "Ubuntu 24.04.3 LTS",
      kernel: "6.8.0-85-generic"
    }

    info =
      Fixture.info()
      |> Map.put("OperatingSystem", host.pretty_name)
      |> Map.put("KernelVersion", host.kernel)

    assert {:ok, "unix_socket_proxy"} = CodingTransport.supported_route(info, host)

    for os <- ["Ubuntu 22.04.5 LTS", "Ubuntu 24.04.3 LTS", "Debian GNU/Linux 12 (bookworm)"] do
      assert {:ok, "unix_socket_proxy"} =
               CodingTransport.supported_route(Map.put(info, "OperatingSystem", os), %{
                 host
                 | pretty_name: os
               })
    end

    for changes <- [
          %{os: {:unix, :darwin}},
          %{endpoint: "unix:///tmp/forwarded.sock"},
          %{socket?: false},
          %{uid: 1000},
          %{pretty_name: nil},
          %{pretty_name: "Ubuntu 26.04 LTS"},
          %{kernel: nil},
          %{kernel: "different"}
        ] do
      assert {:error, :coding_transport_unsupported} =
               CodingTransport.supported_route(info, Map.merge(host, changes))
    end

    for {key, value} <- [
          {"OSType", "windows"},
          {"OperatingSystem", "Ubuntu 26.04 LTS"},
          {"KernelVersion", "different"},
          {"DockerRootDir", "/tmp/docker"},
          {"CgroupVersion", "1"},
          {"SecurityOptions", []},
          {"SecurityOptions", ["name=seccomp,profile=builtin", "name=rootless"]},
          {"SecurityOptions", ["name=seccomp,profile=builtin", "name=userns"]}
        ] do
      assert {:error, :coding_transport_unsupported} =
               CodingTransport.supported_route(Map.put(info, key, value), host)
    end
  end

  test "context has exact six string keys, ownership and bounds", %{fixture: f} do
    workspace = Ecto.UUID.generate()
    run = Ecto.UUID.generate()
    assert {:ok, o} = Fixture.observation(f, workspace, run)
    assert {:ok, context} = CodingTransport.context(o, workspace, run)
    assert map_size(context) == 6

    assert {:ok, ^o} =
             CodingTransport.decode_context(context, %{workspace_id: workspace, run_id: run})

    for invalid <- [
          nil,
          %{},
          Map.put(context, "extra", "x"),
          Map.delete(context, "endpoint"),
          Map.put(context, "endpoint", nil),
          Map.put(context, "daemon_id", ""),
          Map.put(context, "route", "unix"),
          Map.put(context, "version", "coding-transport-v1"),
          Map.put(context, "workspace_id", Ecto.UUID.generate()),
          Map.put(context, "run_id", Ecto.UUID.generate())
        ] do
      assert {:error, :coding_cleanup_context_invalid} =
               CodingTransport.decode_context(invalid, %{workspace_id: workspace, run_id: run})
    end
  end
end
