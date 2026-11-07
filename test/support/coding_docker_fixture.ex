defmodule HarnessForge.CodingDockerFixture do
  @moduledoc """
  Synthetic Docker CLI boundary, never a candidate-code or qualification hook.

  `install!/1` installs a hand-authored Python standard-library CLI named docker
  in PATH, plus two inert real Unix sockets (`endpoint` and `decoy_endpoint`).
  `put_daemon(f, endpoint, attrs)` merges string-keyed attributes: `info` replaces
  the seven projected fields, `status` sets the CLI exit code, `raw_info` replaces
  discovery bytes, `delay_ms` delays replies, `containers` maps exact names to
  Docker inspect maps, and `networks` maps names to inspect maps. Empty maps prove
  synthetic absence. `identity_raw` overrides the ID-only JSON reply. `context`
  overrides the JSON-selected endpoint returned by context inspect.

  Logs contain argv plus only the six Docker override variables. Tests must use
  synthetic values for those variables. No inherited environment dump is kept.
  Delete context-bearing fixture rows before restoring PATH or committed purge.
  """
  alias HarnessForge.Execution.CodingTransport

  @env ~w(PATH DOCKER_HOST DOCKER_CONTEXT DOCKER_TLS DOCKER_TLS_VERIFY DOCKER_CERT_PATH DOCKER_API_VERSION HF_CODING_DOCKER_STATE HF_CODING_DOCKER_LOG)

  def info do
    %{
      "ID" => "HF07:ORIGINAL",
      "OSType" => "linux",
      "OperatingSystem" => "Docker Desktop",
      "KernelVersion" => "6.10.14-linuxkit",
      "DockerRootDir" => "/var/lib/docker",
      "CgroupVersion" => "2",
      "SecurityOptions" => ["name=seccomp,profile=builtin"]
    }
  end

  def install!(opts \\ []) do
    root =
      Path.join(
        if(:os.type() == {:unix, :darwin}, do: "/private/tmp", else: "/tmp"),
        "hf07-cli-" <> Ecto.UUID.generate()
      )

    File.mkdir_p!(root)
    paths = Enum.map(~w(original.sock decoy.sock), &Path.join(root, &1))

    listeners =
      Enum.map(paths, fn path ->
        {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, path}])
        listener
      end)

    [endpoint, decoy] = Enum.map(paths, &("unix://" <> &1))
    state = Path.join(root, "state.json")
    log = Path.join(root, "commands.jsonl")
    previous = Map.new(@env, &{&1, System.get_env(&1)})

    fixture = %{
      root: root,
      endpoint: endpoint,
      decoy_endpoint: decoy,
      listeners: listeners,
      state: state,
      log: log,
      previous: previous
    }

    daemon = %{
      "info" => Keyword.get(opts, :info, info()),
      "status" => 0,
      "containers" => %{},
      "networks" => %{}
    }

    File.write!(
      state,
      Jason.encode!(%{
        "context" => endpoint,
        "daemons" => %{
          endpoint => daemon,
          decoy => put_in(daemon, ["info", "ID"], "HF07:DECOY")
        }
      })
    )

    File.write!(log, "")
    executable = Path.join(root, "docker")
    File.write!(executable, script())
    File.chmod!(executable, 0o700)
    System.put_env("PATH", root <> ":" <> (previous["PATH"] || ""))
    System.put_env("HF_CODING_DOCKER_STATE", state)
    System.put_env("HF_CODING_DOCKER_LOG", log)
    Enum.each(@env -- ~w(PATH HF_CODING_DOCKER_STATE HF_CODING_DOCKER_LOG), &System.delete_env/1)
    select(fixture, endpoint)
    fixture
  end

  def restore(fixture) do
    Enum.each(fixture.listeners, &:gen_tcp.close/1)

    Enum.each(fixture.previous, fn {key, value} ->
      if value, do: System.put_env(key, value), else: System.delete_env(key)
    end)

    File.rm_rf!(fixture.root)
    :ok
  end

  def select(_fixture, endpoint) do
    System.delete_env("DOCKER_CONTEXT")
    System.put_env("DOCKER_HOST", endpoint)
    :ok
  end

  def put_daemon(fixture, endpoint, attrs) do
    state = fixture.state |> File.read!() |> Jason.decode!()

    state =
      if Map.has_key?(attrs, "context"),
        do: Map.put(state, "context", attrs["context"]),
        else: state

    daemon =
      Map.merge(
        state["daemons"][endpoint] ||
          %{"info" => info(), "containers" => %{}, "networks" => %{}, "status" => 0},
        Map.delete(attrs, "context")
      )

    File.write!(fixture.state, Jason.encode!(put_in(state, ["daemons", endpoint], daemon)))
    :ok
  end

  def observation(fixture, workspace_id, run_id) do
    state = fixture.state |> File.read!() |> Jason.decode!()

    context = %{
      "version" => "coding-transport-v2",
      "route" => "desktop_loopback_proxy",
      "endpoint" => fixture.endpoint,
      "daemon_id" => state["daemons"][fixture.endpoint]["info"]["ID"],
      "workspace_id" => workspace_id,
      "run_id" => run_id
    }

    CodingTransport.decode_context(context, %{workspace_id: workspace_id, run_id: run_id})
  end

  def commands(fixture),
    do:
      fixture.log |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

  def clear_commands(fixture), do: File.write!(fixture.log, "")

  defp script do
    ~S"""
    #!/usr/bin/env python3
    import json, os, sys, time
    state_path = os.environ['HF_CODING_DOCKER_STATE']
    log_path = os.environ['HF_CODING_DOCKER_LOG']
    args = sys.argv[1:]
    names = ['DOCKER_CONTEXT','DOCKER_HOST','DOCKER_TLS','DOCKER_TLS_VERIFY','DOCKER_CERT_PATH','DOCKER_API_VERSION']
    with open(log_path, 'a') as log:
        log.write(json.dumps({'argv': args, 'env': {k: os.environ.get(k) for k in names}}) + '\n')
    with open(state_path) as source:
        state = json.load(source)
    if args[:2] == ['context','inspect']:
        print(json.dumps(state['context']))
        sys.exit(0)
    if len(args) < 3 or args[0] != '--host':
        sys.exit(92)
    endpoint, args = args[1], args[2:]
    daemon = state['daemons'].get(endpoint)
    if daemon is None:
        sys.exit(93)
    time.sleep(daemon.get('delay_ms', 0)/1000)
    if daemon.get('status', 0):
        sys.exit(daemon['status'])
    if args[0] == 'info':
        if args[-1] == '{{json .ID}}':
            print(daemon.get('identity_raw', json.dumps(daemon['info'].get('ID'))))
        else:
            print(daemon.get('raw_info', json.dumps(daemon['info'])))
    elif args[:2] == ['image','inspect']:
        print('sha256:synthetic-fixture')
    elif args[0] == 'ps':
        name = next((a[7:-1] for a in args if a.startswith('name=^/') and a.endswith('$')), '')
        if name in daemon.get('containers', {}): print('synthetic-container')
    elif args[0] == 'inspect':
        item = daemon.get('containers', {}).get(args[1])
        if item is None: sys.exit(1)
        print(json.dumps([item]))
    elif args[0] == 'rm':
        daemon.get('containers', {}).pop(args[-1], None)
        with open(state_path, 'w') as target: json.dump(state, target)
    elif args[:2] == ['network','ls']:
        name = next((a[6:-1] for a in args if a.startswith('name=^') and a.endswith('$')), '')
        if name in daemon.get('networks', {}): print(name)
    elif args[:2] == ['network','inspect']:
        item = daemon.get('networks', {}).get(args[2])
        if item is None: sys.exit(1)
        print(json.dumps([item]))
    elif args[:2] == ['network','rm']:
        daemon.get('networks', {}).pop(args[-1], None)
        with open(state_path, 'w') as target: json.dump(state, target)
    else:
        sys.exit(94)
    """
  end
end
