defmodule HarnessForge.Execution.Coding do
  @moduledoc """
  Fixed synthetic coding suite in a Docker isolated bridge, with an exact-route
  Unix-socket proxy and an offline, separately confined protected Go grader.

  This is a local single-operator profile. Docker's daemon and the selected local
  model service are trusted. No Docker socket, host home, host network, arbitrary
  image/command, or external forwarding is exposed to candidate code.
  """
  import Ecto.Query
  import Bitwise
  alias HarnessForge.{Contracts, Harnesses, Models, Repo, Workspaces}
  alias HarnessForge.Evaluation.{Run, TaskSuite}
  alias HarnessForge.Evidence.Revision
  alias HarnessForge.Execution.{Codex, CodingSession, CodingTransport, Command, Docker, Relay}
  alias HarnessForge.Models.{Configuration, LocalModelIdentity}

  @proxy "docker.io/library/nginx@sha256:30f1c0d78e0ad60901648be663a710bdadf19e4c10ac6782c235200619158284"
  @grader "docker.io/library/golang@sha256:aee43c3ccbf24fdffb7295693b6e33b21e01baec1b2a55acc351fde345e9ec34"
  @workspace_label "dev.harnessforge.workspace"
  @run_label "dev.harnessforge.run"
  @profile_label "dev.harnessforge.profile"
  @profile "docker-coding-isolated-v2"
  @codex_profile "docker-codex-isolated-v1"
  @codex_context_keys ~w(version transport driver model_identity codex_tools tools_profile_digest profile)
  @driver_keys ~w(image_id descriptor_digest receipt_digest cli_version platform)
  @codex_home_tmpfs "rw,noexec,nosuid,nodev,size=64m,mode=0700,uid=65534,gid=65534"

  def proxy_image, do: @proxy
  def grader_image, do: @grader
  def profile_digest(%CodingTransport{} = observation), do: Contracts.digest(profile(observation))

  def profile_digest(%{observation: observation} = admission),
    do: Contracts.digest(profile(observation, admission))

  def profile_id(%{"spec" => %{"spec" => %{"runtime" => %{"name" => "codex"}}}}),
    do: @codex_profile

  def profile_id(_), do: @profile

  def observation(%{observation: observation}), do: observation
  def observation(%CodingTransport{} = observation), do: observation

  def profile(observation, %{driver: driver}) do
    profile(observation)
    |> Map.merge(%{
      "id" => @codex_profile,
      "runtime_image" => driver["image_id"],
      "driver_descriptor_digest" => driver["descriptor_digest"],
      "image_receipt_digest" => driver["receipt_digest"],
      "runtime_version" => driver["cli_version"],
      "platform" => driver["platform"],
      "protocol" => "ollama-native-responses-v1",
      "proxy_config_digest" =>
        Contracts.sha256(
          proxy_config(CodingTransport.route(observation), "RELAY_PORT", :codex_responses)
        ),
      "home" => "fresh_private_tmpfs",
      "home_tmpfs" => %{
        "/home/harnessforge" => @codex_home_tmpfs,
        "/home/harnessforge/.codex" => @codex_home_tmpfs
      },
      "rule_tmpfs" => Codex.rule_tmpfs()
    })
  end

  def runtime_image(%{driver: driver}), do: driver["image_id"]
  def runtime_image(%CodingTransport{}), do: Docker.image()
  def runtime_version(%{driver: driver}), do: driver["cli_version"]
  def runtime_version(%CodingTransport{}), do: Docker.version()

  @doc false
  def context(%CodingTransport{} = observation, workspace, run),
    do: CodingTransport.context(observation, workspace, run)

  def context(%{observation: observation} = admission, workspace, run) do
    with {:ok, transport} <- CodingTransport.context(observation, workspace, run) do
      {:ok,
       %{
         "version" => "codex-coding-context-v1",
         "transport" => transport,
         "driver" => admission.driver,
         "model_identity" => admission.model_identity,
         "codex_tools" => admission.codex_tools,
         "tools_profile_digest" => admission.tools_profile_digest,
         "profile" => profile(observation, admission)
       }}
    end
  end

  @doc "Decode persisted ownership without consulting current model or image availability."
  def decode_context(context, result, workspace, run) do
    if result["execution_profile_id"] == @codex_profile do
      with true <-
             is_map(context) and Enum.sort(Map.keys(context)) == Enum.sort(@codex_context_keys),
           true <- context["version"] == "codex-coding-context-v1",
           {:ok, observation} <-
             CodingTransport.decode_context(context["transport"], %{
               workspace_id: workspace,
               run_id: run
             }),
           true <- valid_driver?(context["driver"]),
           true <- valid_model_identity?(context["model_identity"]),
           true <- valid_tools?(context["codex_tools"]),
           true <- hash?(context["tools_profile_digest"]),
           admission = %{
             observation: observation,
             driver: context["driver"],
             model_identity: context["model_identity"],
             codex_tools: context["codex_tools"],
             tools_profile_digest: context["tools_profile_digest"]
           },
           true <- context["profile"] == profile(observation, admission),
           true <-
             result["runtime_name"] == "codex" and
               result["runtime_image"] == runtime_image(admission),
           true <- result["runtime_version"] == runtime_version(admission),
           true <- result["driver_descriptor_digest"] == admission.driver["descriptor_digest"],
           true <- result["image_receipt_digest"] == admission.driver["receipt_digest"],
           true <- result["model_identity_digest"] == Contracts.digest(admission.model_identity),
           true <- result["codex_tools_digest"] == Contracts.digest(admission.codex_tools),
           true <- result["codex_tools_profile_digest"] == admission.tools_profile_digest,
           true <- result["environment_profile_digest"] == profile_digest(admission) do
        {:ok, admission}
      else
        _ -> {:error, :coding_cleanup_context_invalid}
      end
    else
      with true <- result["execution_profile_id"] == @profile,
           true <- result["runtime_name"] in ["opencode", nil],
           {:ok, observation} <-
             CodingTransport.decode_context(context, %{workspace_id: workspace, run_id: run}),
           true <- result["environment_profile_digest"] == profile_digest(observation),
           do: {:ok, observation},
           else: (_ -> {:error, :coding_cleanup_context_invalid})
    end
  rescue
    _ -> {:error, :coding_cleanup_context_invalid}
  end

  def identity(%{
        driver: driver,
        model_identity: model,
        codex_tools: tools,
        tools_profile_digest: profile_digest
      }) do
    %{
      "driver_descriptor_digest" => driver["descriptor_digest"],
      "image_receipt_digest" => driver["receipt_digest"],
      "protocol" => "ollama-native-responses-v1",
      "model_identity_digest" => Contracts.digest(model),
      "codex_tools_digest" => Contracts.digest(tools),
      "codex_tools_profile_digest" => profile_digest
    }
  end

  def identity(_), do: %{}

  def profile(observation) do
    route = CodingTransport.route(observation)

    %{
      "id" => @profile,
      "transport_identity_digest" => CodingTransport.identity_digest(observation),
      "runtime_image" => Docker.image(),
      "proxy_image" => @proxy,
      "grader_image" => @grader,
      "network" => %{"internal" => true, "gateway_mode_ipv4" => "isolated", "ipv6" => false},
      "proxy_config_digest" => Contracts.sha256(proxy_config(route, "RELAY_PORT")),
      "model_route" => route,
      "proxy_external_network" => if(route == "desktop_loopback_proxy", do: "bridge", else: nil),
      "user" => "65534:65534",
      "read_only" => true,
      "pids" => 128,
      "memory_bytes" => 1_073_741_824,
      "cpu_nano" => 1_000_000_000,
      "timeout_ms" => 300_000,
      "output_limit_bytes" => 131_072,
      "tmpfs" => %{"agent" => "noexec,nosuid,nodev,512m", "grader" => "exec,nosuid,nodev,512m"},
      "candidate_files" => ["utility.go", "go.mod"],
      "protected_grader" => "separate_container_no_network",
      "expectations" => "trusted_elixir_outside_candidate_process"
    }
  end

  def model_identity do
    config = Configuration.get()
    if is_binary(config["model"]), do: "ollama/" <> config["model"], else: "unavailable"
  end

  def model_context_digest, do: Contracts.digest(Configuration.get())

  def effective_config(artifact, provider_config) do
    config = Jason.decode!(artifact["files"]["opencode.json"])

    agents =
      Map.new(artifact["spec"]["spec"]["agents"], fn agent ->
        {agent["name"],
         %{
           "name" => agent["name"],
           "description" => agent["description"],
           "mode" => "subagent",
           "options" => %{},
           "permission" => %{},
           "prompt" => agent["instructions"],
           "steps" => artifact["spec"]["spec"]["execution"]["max_turns"]
         }}
      end)

    config
    |> Map.put("agent", agents)
    |> Map.merge(provider_config)
    |> Map.merge(%{
      "autoupdate" => false,
      "plugin" => [],
      "mcp" => %{},
      "lsp" => false,
      "formatter" => false,
      "instructions" => ["/approved/AGENTS.md"],
      "permission" => %{
        "*" => "deny",
        "read" => "allow",
        "edit" => "allow",
        "write" => "allow",
        "glob" => "allow",
        "grep" => "allow",
        "skill" => "allow",
        "external_directory" => "deny",
        "bash" => "deny",
        "task" => "deny"
      }
    })
  end

  def config_digest(artifact) do
    model = Configuration.get()["model"] || "unavailable"

    if profile_id(artifact) == @codex_profile do
      case Codex.effective_config(artifact, model) do
        {:ok, bytes} -> Contracts.sha256(bytes)
        _ -> nil
      end
    else
      Contracts.digest(effective_config(artifact, provider_config(model, "REDACTED")))
    end
  end

  def availability do
    case admit(nil) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  def admit(artifact) do
    config = Configuration.get()

    cond do
      profile_id(artifact) == @codex_profile and Repo.in_transaction?() ->
        {:error, :codex_admission_requires_outermost_transaction}

      config["provider"] != "ollama" ->
        {:error, :runtime_cloud_disabled}

      not is_binary(config["model"]) ->
        {:error, :model_not_selected}

      true ->
        with :ok <- Models.Configuration.authorize(config, %{}),
             :ok <- legacy_model_availability(artifact, config),
             :ok <- admission_artifact(artifact),
             {:ok, observation} <- CodingTransport.observe(),
             transport = transport_context(observation, 30_000),
             {:ok, admission} <- admit_target(artifact, observation, config, transport),
             :ok <- image_available(@proxy, transport),
             :ok <- image_available(@grader, transport),
             true <- Configuration.get() == config do
          {:ok, admission}
        else
          false -> {:error, :model_configuration_changed}
          error -> error
        end
    end
  end

  # Codex's target admission observes the service and immutable model through
  # the absolute-deadline collector. Do not precede it with the legacy
  # inactivity-only availability request. OpenCode keeps its original path.
  defp legacy_model_availability(artifact, config) do
    if profile_id(artifact) == @codex_profile, do: :ok, else: Models.Ollama.available(config)
  end

  @doc "No outcome/qualification overrides exist. The result is derived from observed runtime, profile, usage and protected checks."
  def run(id, artifact, admission) do
    snapshot = Configuration.get()
    observation = observation(admission)
    route = CodingTransport.route(observation)

    transport =
      transport_context(
        observation,
        min(artifact["spec"]["spec"]["execution"]["timeout_seconds"] * 1000, 300_000)
      )
      |> Map.put(:runtime, admission)

    with :ok <- valid_id(id),
         :ok <- Workspaces.ensure_writable(),
         {:ok, ^admission} <- owned_observation(id, artifact),
         :ok <- CodingTransport.verify(observation),
         true <-
           get_in(artifact, ["spec", "spec", "runtime", "version"]) == runtime_version(admission),
         {:ok, sources} <- artifact_sources(artifact),
         {:ok, relay} <-
           fence(id, transport, fn ->
             with {:ok, relay} <-
                    Relay.start_run(
                      id,
                      relay_options(admission, id, artifact) ++
                        [
                          source_ids: sources,
                          unix_socket: route == "unix_socket_proxy",
                          max_turns: min(artifact["spec"]["spec"]["execution"]["max_turns"], 100),
                          lifetime_ms:
                            min(
                              artifact["spec"]["spec"]["execution"]["timeout_seconds"] * 1000,
                              300_000
                            )
                        ]
                    ),
                  :ok <- verify_relay_identity(admission, relay),
                  {:ok, _session} <- CodingSession.start(id, relay),
                  do: {:ok, relay}
           end) do
      result =
        try do
          if Configuration.get() == snapshot,
            do: execute_suite(id, artifact, relay, transport),
            else: blocked(:model_configuration_changed)
        rescue
          _ -> blocked(:coding_execution_failed)
        catch
          :exit, _ -> blocked(:coding_execution_interrupted)
        end

      cleanup = cleanup(id)
      relay_cleanup = Relay.stop(relay)
      complete = cleanup == :ok and relay_cleanup == :ok
      usage = settled_usage(id)

      result
      |> Map.merge(%{
        "model_id" => "ollama/" <> snapshot["model"],
        "model_context_digest" => Contracts.digest(snapshot)
      })
      |> Map.merge(usage)
      |> Map.put("cleanup_status", if(complete, do: "complete", else: "cleanup_failed"))
      |> Map.put(
        "runtime_qualified",
        complete and result["runtime_qualified"] == true and usage["usage_status"] == "reported" and
          Configuration.get() == snapshot and current_artifact(id, artifact) == :ok and
          current_model(admission, snapshot) == :ok
      )
      |> then(fn result ->
        if result["outcome"] == "passed" and not result["runtime_qualified"],
          do:
            Map.merge(result, %{
              "outcome" => "inconclusive",
              "reason" => "usage_or_cleanup_unverified"
            }),
          else: result
      end)
      |> then(fn result ->
        case cleanup do
          {:error, reason} -> Map.put(result, "reason", reason_string(reason))
          _ -> result
        end
      end)
    else
      false -> blocked(:runtime_version_not_qualified)
      {:error, reason} -> blocked(reason)
      _ -> blocked(:coding_cleanup_context_invalid)
    end
  end

  defp execute_suite(id, artifact, relay, transport) do
    deadline = transport.deadline

    with :ok <-
           fence(id, transport, fn ->
             with :ok <- prepare_root(id),
                  :ok <- create_network(id, transport),
                  :ok <- start_proxy(id, relay, transport),
                  :ok <- verify_network(id, transport),
                  do: :ok
           end) do
      Enum.reduce_while(TaskSuite.tasks(), {:ok, []}, fn task, {:ok, checks} ->
        case execute_task(id, task, artifact, relay, transport, deadline) do
          {:ok, check} -> {:cont, {:ok, checks ++ [check]}}
          {:error, reason, check} -> {:halt, {:error, reason, checks ++ [check]}}
        end
      end)
      |> case do
        {:ok, checks} ->
          %{
            "outcome" => "passed",
            "reason" => "finite_synthetic_task_observations",
            "checks" => checks,
            "runtime_qualified" => true
          }

        {:error, reason, checks} ->
          Map.merge(blocked(reason), %{"outcome" => "failed", "checks" => checks})
      end
    else
      {:error, reason} -> blocked(reason)
    end
  end

  defp execute_task(id, task, artifact, relay, transport, deadline) do
    started = System.monotonic_time(:millisecond)
    before_count = request_count(id)

    result =
      with {:ok, config} <- task_config(artifact, relay),
           {:ok, paths} <-
             fence(id, transport, fn ->
               with {:ok, paths} <- materialize(id, task, artifact, config),
                    :ok <- create_agent(id, task, paths, config, relay, transport),
                    :ok <-
                      verify_container(
                        transport,
                        id,
                        agent_name(id, task),
                        runtime_image(transport.runtime),
                        network(id),
                        agent_mounts(paths, transport.runtime)
                      ),
                    :ok <- start_detached(agent_name(id, task), transport),
                    do: {:ok, paths}
             end),
           {:ok, version} <-
             exec(
               transport,
               agent_name(id, task),
               version_argv(transport.runtime),
               remaining(deadline, 15_000)
             ),
           true <- String.trim(version) == version_output(transport.runtime),
           {:ok, effective_digest} <-
             verify_effective(id, task, artifact, config, transport, deadline),
           {:ok, containment} <-
             exec(
               transport,
               agent_name(id, task),
               ["/bin/sh", "-c", containment_script(relay.port, transport.runtime)],
               remaining(deadline, 30_000)
             ),
           true <- String.trim(containment) == "coding_containment_passed",
           :ok <- verify_artifact_files(paths.approved, artifact),
           {:ok, argv} <- task_argv(task, config, transport.runtime),
           {:ok, runtime_output} <-
             exec(
               transport,
               agent_name(id, task),
               argv,
               remaining(deadline, 300_000),
               true
             ),
           :ok <- metered_output(id, before_count, runtime_output),
           :ok <- verify_runtime_output(transport.runtime, runtime_output),
           {:ok, ^effective_digest} <-
             verify_effective(id, task, artifact, config, transport, deadline),
           :ok <- stop_agent(id, task, transport),
           :ok <- verify_artifact_files(paths.approved, artifact),
           :ok <- current_artifact(id, artifact),
           :ok <- validate_candidate(paths.candidate, task, transport.runtime),
           {:ok, grade_output} <- grade(id, task, paths, transport, deadline),
           :ok <- checked_grade(task, grade_output),
           {:ok, evidence} <- task_evidence(task, paths, runtime_output, grade_output, relay) do
        {:ok,
         %{
           "id" => task,
           "outcome" => "passed",
           "objective_checks" => "passed",
           "runtime_version" => runtime_version(transport.runtime),
           "runtime_output_digest" => Contracts.sha256(runtime_output),
           "grader_output_digest" => Contracts.sha256(grade_output),
           "containment_output_digest" => Contracts.sha256(containment),
           "effective_config_digest" => effective_digest,
           "evidence" => evidence,
           "duration_ms" => System.monotonic_time(:millisecond) - started
         }}
      else
        false -> {:error, :runtime_or_metering_unverified}
        {:error, reason, evidence} -> {:error, reason, evidence}
        {:error, reason} -> {:error, reason}
      end

    case result do
      {:ok, check} ->
        {:ok, check}

      {:error, reason} ->
        failed_task(id, task, reason, %{}, relay, transport, started)

      {:error, reason, evidence} ->
        failed_task(id, task, reason, evidence, relay, transport, started)
    end
  end

  defp failed_task(id, task, reason, observations, relay, transport, started) do
    # A failed solver is stopped before inspecting any task-writable output.
    stopped = stop_agent(id, task, transport) == :ok
    evidence = failure_evidence(id, task, observations, relay, stopped)

    {:error, reason,
     %{
       "id" => task,
       "outcome" => "failed",
       "reason" => reason_string(reason),
       "evidence" => evidence,
       "duration_ms" => System.monotonic_time(:millisecond) - started
     }}
  end

  defp provider_config(model, token) do
    %{
      "enabled_providers" => ["harnessforge"],
      "model" => "harnessforge/" <> model,
      "small_model" => "harnessforge/" <> model,
      "provider" => %{
        "harnessforge" => %{
          "npm" => "@ai-sdk/openai-compatible",
          "name" => "HarnessForge metered Ollama",
          "options" => %{"baseURL" => "http://model-relay:8080/v1", "apiKey" => token},
          "models" => %{
            model => %{"name" => model, "limit" => %{"context" => 16_384, "output" => 4096}}
          }
        }
      }
    }
  end

  defp verify_config(bytes, expected) do
    with {:ok, actual} <- Jason.decode(bytes),
         true <-
           Map.take(redact_config(actual), Map.keys(expected) -- ["$schema"]) ==
             Map.drop(redact_config(expected), ["$schema"]) do
      :ok
    else
      _ -> {:error, :effective_runtime_config_mismatch}
    end
  end

  defp redact_config(config),
    do: put_in(config, ["provider", "harnessforge", "options", "apiKey"], "REDACTED")

  defp containment_script(relay_port, runtime) do
    route =
      if is_map(runtime) and Map.has_key?(runtime, :driver),
        do: "/v1/responses",
        else: "/v1/chat/completions"

    """
    set -eu
    for utility in id test grep cat touch ip timeout wget nslookup printf; do
      command -v "$utility" >/dev/null 2>&1 || exit 30
    done
    test "$(id -u)" = 65534
    test ! -e /var/run/docker.sock
    test ! -e /relay.sock
    grep -q '^CapEff:[[:space:]]*0000000000000000$' /proc/self/status
    grep -q '^NoNewPrivs:[[:space:]]*1$' /proc/self/status
    test "$(cat /sys/fs/cgroup/pids.max)" = 128
    test "$(cat /sys/fs/cgroup/memory.max)" = 1073741824
    test "$(cat /sys/fs/cgroup/cpu.max)" = '100000 100000'
    if touch /host-escape 2>/dev/null; then exit 31; fi
    if touch /approved/host-escape 2>/dev/null; then exit 32; fi
    test ! -e /protected
    if ip route | grep -q '^default '; then exit 34; fi
    if ip -6 route | grep -q '^default '; then exit 35; fi
    for address in http://1.1.1.1 http://[2606:4700:4700::1111] http://10.0.0.1 http://172.17.0.1 http://192.168.1.1 http://192.168.65.254:#{relay_port} http://169.254.169.254 http://host.docker.internal:11434 http://model-relay:8080/api/tags http://model-relay:8080/api/pull; do
      if timeout 2 wget -q -T 1 -O /tmp/probe-response "$address" 2>/dev/null; then exit 33; fi
    done
    if timeout 2 nslookup example.com >/tmp/dns-response 2>&1; then exit 36; fi
    status=$(timeout 3 wget -S -T 2 --post-data '{}' --header 'Authorization: Bearer invalid' -O /tmp/probe-response http://model-relay:8080#{route} 2>&1 || true)
    printf '%s' "$status" | grep -q '401 Unauthorized'
    for path in /api/tags /api/pull /v1/models #{route}/extra; do
      status=$(timeout 3 wget -S -T 2 --post-data '{}' -O /tmp/probe-response "http://model-relay:8080$path" 2>&1 || true)
      printf '%s' "$status" | grep -q '403 Forbidden'
    done
    printf 'coding_containment_passed\\n'
    """
  end

  defp create_network(id, transport) do
    docker_ok(
      transport,
      [
        "network",
        "create",
        "--internal",
        "--driver",
        "bridge",
        "--opt",
        "com.docker.network.bridge.gateway_mode_ipv4=isolated"
      ] ++ labels(id) ++ [network(id)]
    )
  end

  defp verify_network(id, transport) do
    with {:ok, %{exit_status: 0, output: bytes}} <-
           coding_command(transport, ["network", "inspect", network(id)]),
         {:ok, [i]} <- Jason.decode(bytes),
         true <-
           owned?(i, id) and i["Driver"] == "bridge" and i["Internal"] == true and
             i["EnableIPv6"] == false and
             get_in(i, ["Options", "com.docker.network.bridge.gateway_mode_ipv4"]) == "isolated" and
             Enum.all?(get_in(i, ["IPAM", "Config"]), &is_nil(&1["Gateway"])) do
      :ok
    else
      {:error, :coding_transport_changed} = error -> error
      _ -> {:error, :isolated_network_unverified}
    end
  end

  defp proxy_config("desktop_loopback_proxy", port) do
    String.replace(
      TaskSuite.proxy_config(),
      "http://unix:/relay.sock:/v1/chat/completions",
      "http://host.docker.internal:#{port}/v1/chat/completions"
    )
  end

  defp proxy_config(_, _), do: TaskSuite.proxy_config()

  defp proxy_config(route, port, :codex_responses) do
    bytes =
      File.read!(Application.app_dir(:harness_forge, "priv/codex_runtime/proxy-responses.conf"))

    if route == "desktop_loopback_proxy",
      do:
        String.replace(
          bytes,
          "http://unix:/relay.sock:/v1/responses",
          "http://host.docker.internal:#{port}/v1/responses"
        ),
      else: bytes
  end

  defp proxy_config(route, port, _), do: proxy_config(route, port)

  defp start_proxy(id, relay, transport) do
    path = Path.join(run_root(id), "proxy.conf")
    route = CodingTransport.route(transport.observation)

    with {:ok, user, extra_mounts} <- proxy_user_mounts(route, relay),
         :ok <-
           File.write(path, proxy_config(route, relay.port, relay.protocol || :chat), [:exclusive]),
         mounted = [{path, "/etc/nginx/nginx.conf", false}] ++ extra_mounts,
         :ok <-
           docker_ok(
             transport,
             [
               "create",
               "--pull",
               "never",
               "--name",
               proxy_name(id),
               "--network-alias",
               "model-relay"
             ] ++
               common(id, network(id), user, false) ++
               mounts(mounted) ++ ["--entrypoint", "nginx", @proxy, "-g", "daemon off;"]
           ),
         :ok <- connect_proxy(route, id, transport),
         :ok <-
           verify_container(transport, id, proxy_name(id), @proxy, network(id), mounted, user),
         :ok <- start_detached(proxy_name(id), transport),
         {:ok, _} <- exec(transport, proxy_name(id), ["nginx", "-t"], 5_000) do
      :ok
    else
      {:error, :coding_transport_changed} = error -> error
      _ -> {:error, :fixed_model_proxy_unavailable}
    end
  end

  defp proxy_user_mounts("desktop_loopback_proxy", _), do: {:ok, "65534:65534", []}

  defp proxy_user_mounts(_, relay) do
    with path when is_binary(path) <- relay.socket_path,
         {:ok, %{type: :other, uid: uid, gid: gid}} <- File.lstat(path),
         true <- uid != 0 do
      {:ok, "#{uid}:#{gid}", [{path, "/relay.sock", true}]}
    else
      _ -> {:error, :unix_model_proxy_unavailable}
    end
  end

  defp connect_proxy("desktop_loopback_proxy", id, transport),
    do: docker_ok(transport, ["network", "connect", "bridge", proxy_name(id)])

  defp connect_proxy(_, _, _), do: :ok

  defp create_agent(id, task, paths, _config, relay, %{runtime: %{driver: driver}} = transport) do
    docker_ok(
      transport,
      ["create", "--pull", "never", "--name", agent_name(id, task)] ++
        common(id, network(id)) ++
        [
          "--tmpfs",
          "/home/harnessforge:" <> @codex_home_tmpfs,
          "--tmpfs",
          "/home/harnessforge/.codex:" <> @codex_home_tmpfs
        ] ++
        Enum.flat_map(Enum.sort(Codex.rule_tmpfs()), fn {destination, options} ->
          ["--tmpfs", destination <> ":" <> options]
        end) ++
        mounts(agent_mounts(paths, transport.runtime)) ++
        [
          "--workdir",
          "/candidate",
          "--env",
          "HOME=/home/harnessforge",
          "--env",
          "CODEX_HOME=/home/harnessforge/.codex",
          "--env",
          "HARNESSFORGE_RELAY_TOKEN=" <> relay.token,
          "--entrypoint",
          "/bin/sleep",
          driver["image_id"],
          "600"
        ]
    )
  end

  defp create_agent(id, task, paths, config, _relay, transport) do
    docker_ok(
      transport,
      ["create", "--pull", "never", "--name", agent_name(id, task)] ++
        common(id, network(id)) ++
        mounts(agent_mounts(paths, transport.runtime)) ++
        [
          "--workdir",
          "/candidate",
          "--env",
          "OPENCODE_CONFIG_CONTENT=" <> Contracts.canonical_json(config),
          "--env",
          "OPENCODE_CONFIG_DIR=/tmp/approved-config",
          "--env",
          "OPENCODE_DISABLE_AUTOUPDATE=true",
          "--env",
          "OPENCODE_DISABLE_LSP_DOWNLOAD=true",
          "--env",
          "OPENCODE_DISABLE_CLAUDE_CODE=true",
          "--entrypoint",
          "/bin/sh",
          Docker.image(),
          "-c",
          "cp -R /approved/.opencode /tmp/approved-config; chmod -R u+w /tmp/approved-config; exec /bin/sleep 600"
        ]
    )
  end

  defp grade(id, task, paths, transport, deadline) do
    name = grader_name(id, task)

    with :ok <-
           fence(id, transport, fn ->
             with :ok <- create_grader(id, task, paths, transport),
                  :ok <-
                    verify_container(transport, id, name, @grader, "none", [
                      {paths.candidate, "/candidate", false},
                      {paths.protected, "/protected", false}
                    ]),
                  :ok <- start_detached(name, transport),
                  do: :ok
           end),
         {:ok, %{exit_status: 0}} <-
           coding_command(transport, ["wait", name], remaining(deadline, 90_000), 4096),
         {:ok, i} <- inspect_owned(id, name, transport),
         {:ok, %{exit_status: 0, output: output}} <-
           coding_command(transport, ["logs", name], 5_000, 65_536) do
      case grader_exit(i) do
        :ok -> {:ok, output}
        {:error, reason} -> {:error, reason, %{"grader_output" => output}}
      end
    else
      {:error, :timed_out} -> {:error, :task_time_limit}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :protected_grader_failed}
    end
  end

  defp create_grader(id, task, paths, transport) do
    docker_ok(
      transport,
      ["create", "--pull", "never", "--name", grader_name(id, task)] ++
        common(id, "none") ++
        mounts([{paths.candidate, "/candidate", false}, {paths.protected, "/protected", false}]) ++
        [
          "--env",
          "HARNESSFORGE_TASK=" <> task,
          "--env",
          "GOPROXY=off",
          "--env",
          "GOSUMDB=off",
          "--env",
          "GOTOOLCHAIN=local",
          "--env",
          "GOENV=off",
          "--env",
          "CGO_ENABLED=0",
          "--env",
          "GOCACHE=/tmp/go-cache",
          "--env",
          "GOMODCACHE=/tmp/go-mod",
          "--env",
          "GOWORK=off",
          "--entrypoint",
          "/bin/sh",
          @grader,
          "-c",
          TaskSuite.grader_script()
        ]
    )
  end

  defp grader_exit(%{"State" => %{"Running" => false, "ExitCode" => 0}}), do: :ok

  defp grader_exit(%{"State" => %{"Running" => false, "ExitCode" => 45}}),
    do: {:error, :candidate_subset_rejected}

  defp grader_exit(%{"State" => %{"Running" => false, "ExitCode" => 41}}),
    do: {:error, :protected_tests_failed}

  defp grader_exit(%{"State" => %{"Running" => false, "ExitCode" => 42}}),
    do: {:error, :protected_build_failed}

  defp grader_exit(_), do: {:error, :protected_grader_failed}

  defp common(id, network, user \\ "65534:65534", deny_dns? \\ true) do
    labels(id) ++
      [
        "--network",
        network,
        "--user",
        user,
        "--read-only",
        "--cap-drop",
        "ALL",
        "--security-opt",
        "no-new-privileges",
        "--pids-limit",
        "128",
        "--memory",
        "1g",
        "--memory-swap",
        "1g",
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
        "/tmp:rw," <>
          if(network == "none", do: "exec", else: "noexec") <> ",nosuid,nodev,size=512m,mode=1777",
        "--env",
        "HOME=/tmp",
        "--env",
        "XDG_CACHE_HOME=/tmp/cache",
        "--env",
        "XDG_DATA_HOME=/tmp/data",
        "--env",
        "XDG_CONFIG_HOME=/tmp/config"
      ] ++ if(deny_dns?, do: ["--dns", "127.0.0.1"], else: [])
  end

  defp labels(id),
    do: [
      "--label",
      "#{@workspace_label}=#{Workspaces.current_id()}",
      "--label",
      "#{@run_label}=#{id}",
      "--label",
      "#{@profile_label}=#{owned_profile(id)}"
    ]

  defp mounts(items),
    do:
      Enum.flat_map(items, fn {source, dest, writable} ->
        [
          "--mount",
          "type=bind,source=#{source},target=#{dest}" <> if(writable, do: "", else: ",readonly")
        ]
      end)

  defp verify_container(transport, id, name, image, net, expected_mounts, user \\ "65534:65534") do
    with {:ok, i} <- inspect_owned(id, name, transport) do
      h = i["HostConfig"]

      actual_mounts =
        Enum.map(i["Mounts"], &{&1["Source"], &1["Destination"], &1["RW"]}) |> Enum.sort()

      expected_networks =
        if name == proxy_name(id) and
             CodingTransport.route(transport.observation) == "desktop_loopback_proxy",
           do: Enum.sort([net, "bridge"]),
           else: [net]

      actual_networks = Map.keys(get_in(i, ["NetworkSettings", "Networks"]) || %{}) |> Enum.sort()

      valid =
        actual_networks == expected_networks and get_in(i, ["Config", "Image"]) == image and
          get_in(i, ["Config", "User"]) == user and
          h["ReadonlyRootfs"] == true and h["Privileged"] == false and h["NetworkMode"] == net and
          h["CapDrop"] == ["ALL"] and "no-new-privileges" in h["SecurityOpt"] and
          h["PidsLimit"] == 128 and h["Memory"] == 1_073_741_824 and
          h["MemorySwap"] == 1_073_741_824 and h["NanoCpus"] == 1_000_000_000 and
          (h["PortBindings"] || %{}) == %{} and actual_mounts == Enum.sort(expected_mounts) and
          codex_container_config?(transport, i)

      if valid, do: :ok, else: {:error, :coding_container_profile_mismatch}
    end
  end

  defp codex_container_config?(%{runtime: %{driver: _}}, inspection) do
    # Only the solver receives fresh HOME and the relay capability; the proxy
    # and protected grader keep their existing fixed profiles.
    if get_in(inspection, ["Config", "Image"]) == @proxy or
         get_in(inspection, ["Config", "Image"]) == @grader do
      true
    else
      Enum.all?(inspection["Mounts"] || [], &(&1["Type"] == "bind")) and
        validate_codex_container_config(inspection)
    end
  end

  defp codex_container_config?(_, _), do: true

  @doc false
  def validate_codex_container_config(inspection) when is_map(inspection) do
    environment = get_in(inspection, ["Config", "Env"]) || []
    tmpfs = get_in(inspection, ["HostConfig", "Tmpfs"]) || %{}

    expected_tmpfs =
      Map.merge(Codex.rule_tmpfs(), %{
        "/tmp" => "rw,noexec,nosuid,nodev,size=512m,mode=1777",
        "/home/harnessforge" => @codex_home_tmpfs,
        "/home/harnessforge/.codex" => @codex_home_tmpfs
      })

    is_list(environment) and Enum.all?(environment, &is_binary/1) and
      "HOME=/home/harnessforge" in environment and
      "CODEX_HOME=/home/harnessforge/.codex" in environment and
      Enum.count(environment, &String.starts_with?(&1, "HARNESSFORGE_RELAY_TOKEN=")) == 1 and
      Enum.all?(
        ~w(OPENAI_API_KEY CODEX_API_KEY ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN),
        fn name -> not Enum.any?(environment, &String.starts_with?(&1, name <> "=")) end
      ) and tmpfs == expected_tmpfs
  rescue
    _ -> false
  end

  def validate_codex_container_config(_), do: false

  defp inspect_owned(id, name, transport) do
    with {:ok, %{exit_status: 0, output: bytes}} <- coding_command(transport, ["inspect", name]),
         {:ok, [i]} <- Jason.decode(bytes),
         true <- owned?(i["Config"], id) do
      {:ok, i}
    else
      {:error, :coding_transport_changed} = error -> error
      _ -> {:error, :coding_container_not_owned}
    end
  end

  defp owned?(i, id),
    do:
      get_in(i, ["Labels", @workspace_label]) == Workspaces.current_id() and
        get_in(i, ["Labels", @run_label]) == id and
        get_in(i, ["Labels", @profile_label]) == owned_profile(id)

  defp start_detached(name, transport), do: docker_ok(transport, ["start", name])
  defp stop_agent(id, task, transport), do: remove_owned(id, agent_name(id, task), transport)

  defp exec(transport, name, command, timeout, preserve_output? \\ false) do
    case coding_command(transport, ["exec", name] ++ command, timeout, 131_072) do
      {:ok, %{exit_status: 0, output: output}} ->
        {:ok, output}

      {:error, :timed_out} ->
        {:error, :task_time_limit}

      {:error, :output_limit} ->
        {:error, :task_output_limit}

      {:error, :coding_transport_changed} = error ->
        error

      {:ok, %{exit_status: _, output: output}} when preserve_output? ->
        {:error, :task_runtime_failed, %{"agent_output" => output}}

      _ ->
        {:error, :task_runtime_failed}
    end
  end

  defp prepare_root(id) do
    with :ok <- File.mkdir_p(Workspaces.paths()["runs"]),
         :ok <- File.mkdir(run_root(id)),
         :ok <- File.chmod(run_root(id), 0o700),
         do: :ok
  end

  defp materialize(id, task, artifact, config) do
    base = Path.join(run_root(id), task)

    paths = %{
      candidate: Path.join(base, "candidate"),
      approved: Path.join(base, "approved"),
      protected: Path.join(base, "protected"),
      runtime: Path.join(base, "runtime")
    }

    fixture = TaskSuite.fixture(task)

    with :ok <- write_files(paths.candidate, fixture["candidate"], 0o666, 0o777),
         :ok <- write_files(paths.approved, artifact["files"], 0o444, 0o755),
         :ok <- write_files(paths.protected, fixture["protected"], 0o444, 0o755),
         :ok <- materialize_runtime(paths, artifact, config),
         do: {:ok, paths}
  end

  defp write_files(root, files, mode, dir_mode) do
    Enum.reduce_while(files, :ok, fn {name, bytes}, :ok ->
      path = Path.join(root, name)

      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.chmod(root, dir_mode),
           :ok <- File.write(path, bytes, [:exclusive]),
           :ok <- File.chmod(path, mode) do
        {:cont, :ok}
      else
        _ -> {:halt, {:error, :task_fixture_unavailable}}
      end
    end)
  end

  defp validate_candidate(root) do
    case File.lstat(Path.join(root, "utility.go")) do
      {:ok, %{type: :regular, size: size, links: 1}} when size in 1..65_536 -> :ok
      _ -> {:error, :invalid_candidate_file}
    end
  end

  defp validate_candidate(root, task, %{driver: _}) do
    expected_mod = TaskSuite.fixture(task)["candidate"]["go.mod"]

    with :ok <- validate_candidate(root),
         {:ok, %{type: :regular, links: 1, size: size}} <- File.lstat(Path.join(root, "go.mod")),
         true <- size == byte_size(expected_mod),
         {:ok, ^expected_mod} <- File.read(Path.join(root, "go.mod")),
         {:ok, names} <- File.ls(root),
         true <- names -- ~w(utility.go go.mod AGENTS.md .codex .agents) == [],
         do: :ok,
         else: (_ -> {:error, :candidate_subset_rejected})
  end

  defp validate_candidate(root, _task, _runtime), do: validate_candidate(root)

  defp admit_target(artifact, observation, config, transport) do
    if profile_id(artifact) == @codex_profile do
      with {:ok, driver} <- Codex.load_image(observation),
           {:ok, model} <- LocalModelIdentity.observe(config),
           {:ok, tools, tools_digest} <- load_codex_tools(driver, model, artifact) do
        {:ok,
         %{
           observation: observation,
           driver: driver,
           model_identity: model,
           codex_tools: tools,
           tools_profile_digest: tools_digest
         }}
      end
    else
      with :ok <- image_available(Docker.image(), transport), do: {:ok, observation}
    end
  end

  defp relay_options(%{codex_tools: tools}, id, artifact),
    do: [
      protocol: :codex_responses,
      codex_tools: tools,
      authorize: fn -> current_artifact(id, artifact) end
    ]

  defp relay_options(_, id, artifact), do: [authorize: fn -> current_artifact(id, artifact) end]

  defp verify_relay_identity(%{model_identity: identity}, relay),
    do:
      if(relay.protocol == :codex_responses and relay.model_identity == identity,
        do: :ok,
        else: {:error, :local_model_identity_changed}
      )

  defp verify_relay_identity(_, _), do: :ok

  defp current_model(%{model_identity: identity}, config),
    do: LocalModelIdentity.revalidate(config, identity)

  defp current_model(_, _), do: :ok

  defp current_artifact(id, artifact), do: authorize_run(id, artifact)

  @doc false
  def authorize_run(id, artifact) do
    HarnessForge.Privacy.Purge.synchronize(fn ->
      with :ok <- Workspaces.ensure_writable(),
           true <-
             Repo.exists?(
               from r in Run,
                 where:
                   r.workspace_id == ^Workspaces.current_id() and r.id == ^id and
                     r.artifact_digest == ^artifact["digest"] and
                     fragment("json_extract(?, '$.outcome')", r.result) == "running"
             ),
           :ok <- Harnesses.eligible(artifact),
           do: :ok,
           else: (_ -> {:error, :evaluation_authority_withdrawn})
    end)
  rescue
    _ -> {:error, :evaluation_authority_withdrawn}
  end

  defp task_config(artifact, %{protocol: :codex_responses, model_identity: identity}),
    do: Codex.effective_config(artifact, identity["model"])

  defp task_config(artifact, relay) do
    provider =
      put_in(
        relay.provider_config,
        ["provider", "harnessforge", "options", "baseURL"],
        "http://model-relay:8080/v1"
      )

    {:ok, effective_config(artifact, provider)}
  end

  defp version_argv(%{driver: _}), do: Codex.version_argv()
  defp version_argv(_), do: ["opencode", "--version"]
  defp version_output(%{driver: driver}), do: "codex-cli " <> driver["cli_version"]
  defp version_output(_), do: Docker.version()

  defp task_argv(task, config, runtime) do
    prompt =
      TaskSuite.fixture(task)["prompt"] <>
        "\nEdit /candidate/utility.go only. Protected tests are evaluator-owned. Report your change briefly."

    if is_map(runtime) and Map.has_key?(runtime, :driver),
      do: Codex.task_argv(prompt),
      else: {:ok, ["opencode", "run", "--format", "json", "--model", config["model"], prompt]}
  end

  defp verify_effective(
         id,
         task,
         artifact,
         config,
         %{runtime: %{model_identity: model}} = transport,
         deadline
       ) do
    with {:ok, expected} <- Codex.preflight_expected(artifact, model["model"]),
         {:ok, bytes} <-
           exec(
             transport,
             agent_name(id, task),
             Codex.preflight_argv(),
             remaining(deadline, 30_000)
           ),
         {:ok, _} <- Codex.validate_preflight(bytes, expected),
         true <- expected["overlay_sha256"] == Contracts.sha256(config),
         do: {:ok, Contracts.sha256(config)},
         else: (_ -> {:error, :codex_preflight_rejected})
  end

  defp verify_effective(id, task, _artifact, config, transport, deadline) do
    with {:ok, bytes} <-
           exec(
             transport,
             agent_name(id, task),
             ["opencode", "debug", "config"],
             remaining(deadline, 15_000)
           ),
         :ok <- verify_config(bytes, config),
         do:
           {:ok,
            Contracts.digest(Map.take(redact_config(Jason.decode!(bytes)), Map.keys(config)))}
  end

  defp verify_runtime_output(%{driver: _}, bytes) do
    case Codex.validate_events(bytes) do
      {:ok, %{"changed_paths" => paths}} ->
        if paths -- ["utility.go"] == [],
          do: :ok,
          else: {:error, :candidate_subset_rejected, %{"agent_output" => bytes}}

      {:error, reason} ->
        {:error, reason, %{"agent_output" => bytes}}
    end
  end

  defp verify_runtime_output(_, _), do: :ok

  defp metered_output(id, before_count, bytes) do
    if request_count(id) > before_count,
      do: :ok,
      else: {:error, :runtime_or_metering_unverified, %{"agent_output" => bytes}}
  end

  defp materialize_runtime(paths, artifact, config) when is_binary(config) do
    with {:ok, expected} <- Codex.preflight_expected(artifact, Configuration.get()["model"]),
         :ok <-
           write_files(
             paths.runtime,
             %{
               "config.toml" => config,
               "preflight-expected.json" => Contracts.canonical_json(expected)
             },
             0o444,
             0o755
           ),
         :ok <- materialize_rules(paths),
         do: :ok
  end

  defp materialize_runtime(_, _, _), do: :ok

  defp materialize_rules(paths) do
    Enum.reduce_while(
      [Path.join(paths.approved, ".codex/rules")],
      :ok,
      fn path, :ok ->
        with :ok <- File.mkdir_p(path),
             {:ok, %{type: :directory}} <- File.lstat(path),
             {:ok, []} <- File.ls(path),
             :ok <- File.chmod(path, 0o555) do
          {:cont, :ok}
        else
          _ -> {:halt, {:error, :codex_preflight_rejected}}
        end
      end
    )
  end

  defp agent_mounts(paths, %{driver: _}) do
    [
      {paths.candidate, "/candidate", true},
      {paths.approved, "/approved", false},
      {Path.join(paths.approved, "AGENTS.md"), "/candidate/AGENTS.md", false},
      {Path.join(paths.approved, ".codex"), "/candidate/.codex", false},
      {Path.join(paths.approved, ".agents"), "/candidate/.agents", false},
      {Path.join(paths.runtime, "config.toml"), "/home/harnessforge/.codex/config.toml", false},
      {Path.join(paths.runtime, "preflight-expected.json"), "/runtime/preflight-expected.json",
       false}
    ]
  end

  defp agent_mounts(paths, _),
    do: [{paths.candidate, "/candidate", true}, {paths.approved, "/approved", false}]

  defp verify_artifact_files(root, artifact) do
    Enum.reduce_while(artifact["files"], :ok, fn {path, expected}, :ok ->
      file = Path.join(root, path)

      with {:ok, %{type: :regular, links: 1, size: size}} <- File.lstat(file),
           true <- size == byte_size(expected),
           {:ok, ^expected} <- File.read(file),
           do: {:cont, :ok},
           else: (_ -> {:halt, {:error, :approved_artifact_changed}})
    end)
  end

  defp task_evidence(task, paths, output, grade, relay) do
    with {:ok, after_bytes} <- File.read(Path.join(paths.candidate, "utility.go")),
         {:ok, agent_output} <-
           sanitize_evidence(output, [relay.token, Configuration.get()["endpoint"]]),
         {:ok, candidate_before} <-
           sanitize_evidence(TaskSuite.fixture(task)["candidate"]["utility.go"], [relay.token]),
         {:ok, candidate_after} <- sanitize_evidence(after_bytes, [relay.token]),
         {:ok, grader_output} <- sanitize_evidence(grade, [relay.token]) do
      {:ok,
       %{
         "version" => 1,
         "solver_stopped" => true,
         "agent_output" => agent_output,
         "candidate_before" => candidate_before,
         "candidate_after" => candidate_after,
         "candidate_before_digest" =>
           Contracts.sha256(TaskSuite.fixture(task)["candidate"]["utility.go"]),
         "candidate_after_digest" => Contracts.sha256(after_bytes),
         "grader_output" => grader_output,
         "objective_checks" => "passed"
       }}
    end
  end

  defp checked_grade(task, output) do
    case TaskSuite.check(task, output) do
      :ok -> :ok
      {:error, reason} -> {:error, reason, %{"grader_output" => output}}
    end
  end

  defp failure_evidence(id, task, observations, relay, stopped) do
    before_bytes = TaskSuite.fixture(task)["candidate"]["utility.go"]
    evidence = %{"version" => 1, "solver_stopped" => stopped, "objective_checks" => "unverified"}
    path = Path.join([run_root(id), task, "candidate", "utility.go"])

    after_bytes =
      if stopped do
        with {:ok, %{type: :regular, links: 1, size: size}} <- File.lstat(path),
             true <- size in 1..65_536,
             {:ok, bytes} <- bounded_read(path, size),
             do: bytes,
             else: (_ -> nil)
      end

    observations =
      Map.merge(
        Map.take(observations, ~w(agent_output grader_output)),
        %{"candidate_before" => before_bytes, "candidate_after" => after_bytes}
      )

    Enum.reduce(observations, evidence, fn {key, bytes}, acc ->
      case sanitize_evidence(bytes, [relay.token, Configuration.get()["endpoint"]]) do
        {:ok, text} -> Map.put(acc, key, text)
        _ -> acc
      end
    end)
  end

  @doc false
  def sanitize_evidence(bytes, secrets)
      when is_binary(bytes) and byte_size(bytes) <= 131_072 and is_list(secrets) do
    if String.valid?(bytes) do
      text =
        Enum.reduce(secrets, bytes, fn secret, text ->
          if is_binary(secret) and secret != "",
            do: String.replace(text, secret, "[REDACTED]"),
            else: text
        end)

      text =
        text
        |> String.replace(~r/\e\[[0-?]*[ -\/]*[@-~]/, "")
        |> String.replace(
          ~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F\x{202A}-\x{202E}\x{2066}-\x{2069}]/u,
          ""
        )

      if byte_size(text) <= 131_072, do: {:ok, text}, else: {:error, :task_output_limit}
    else
      {:error, :task_output_invalid}
    end
  end

  def sanitize_evidence(_, _), do: {:error, :task_output_invalid}

  defp owned_profile(id) do
    case Repo.one(
           from r in Run,
             where: r.workspace_id == ^Workspaces.current_id() and r.id == ^id,
             select: fragment("json_extract(?, '$.execution_profile_id')", r.result)
         ) do
      profile when profile in [@profile, @codex_profile] -> profile
      _ -> "unknown"
    end
  end

  defp valid_driver?(driver) when is_map(driver) do
    Enum.sort(Map.keys(driver)) == Enum.sort(@driver_keys) and
      hash?(driver["descriptor_digest"]) and hash?(driver["receipt_digest"]) and
      is_binary(driver["image_id"]) and
      Regex.match?(~r/\Asha256:[a-f0-9]{64}\z/, driver["image_id"]) and
      driver["cli_version"] == "0.156.0" and driver["platform"] in ["linux/amd64", "linux/arm64"]
  end

  defp valid_driver?(_), do: false

  defp valid_model_identity?(identity) when is_map(identity) do
    Enum.sort(Map.keys(identity)) == Enum.sort(~w(version model digest endpoint capabilities)) and
      identity["version"] == "0.40.14" and hash?(identity["digest"]) and
      is_binary(identity["model"]) and is_binary(identity["endpoint"]) and
      match?({:ok, _}, Configuration.endpoint("ollama", identity["endpoint"])) and
      is_list(identity["capabilities"]) and "tools" in identity["capabilities"] and
      Enum.all?(identity["capabilities"], &is_binary/1)
  end

  defp valid_model_identity?(_), do: false
  defp valid_tools?(tools), do: match?({:ok, _}, Models.CodexProtocol.tool_scope(tools))
  defp hash?(value), do: is_binary(value) and Regex.match?(~r/\A[a-f0-9]{64}\z/, value)

  defp load_codex_tools(driver, model, artifact) do
    root = Workspaces.root()
    directory = Path.join(root, "runtime")
    path = Path.join(directory, "codex-tools-receipt.json")

    keys =
      ~w(version cli_version descriptor_digest image_id model_identity_digest overlay_digest tools)

    with {:ok, root_stat} <- File.lstat(root),
         true <- root_stat.type == :directory and (root_stat.mode &&& 0o777) == 0o700,
         {:ok, directory_stat} <- File.lstat(directory),
         true <-
           directory_stat.type == :directory and directory_stat.uid == root_stat.uid and
             (directory_stat.mode &&& 0o777) == 0o700,
         {:ok, stat} <- File.lstat(path),
         true <-
           stat.type == :regular and stat.links == 1 and stat.uid == root_stat.uid and
             (stat.mode &&& 0o777) == 0o600 and stat.size in 1..131_072,
         {:ok, bytes} <- bounded_read(path, stat.size),
         {:ok, after_stat} <- File.lstat(path),
         true <- stable_stat?(stat, after_stat),
         {:ok, after_directory} <- File.lstat(directory),
         true <- stable_stat?(directory_stat, after_directory),
         {:ok, after_root} <- File.lstat(root),
         true <- stable_stat?(root_stat, after_root),
         {:ok, receipt} <- Contracts.decode_json(bytes),
         true <- is_map(receipt) and Enum.sort(Map.keys(receipt)) == Enum.sort(keys),
         true <- receipt["version"] == 1 and receipt["cli_version"] == driver["cli_version"],
         true <-
           receipt["descriptor_digest"] == driver["descriptor_digest"] and
             receipt["image_id"] == driver["image_id"],
         true <-
           receipt["model_identity_digest"] == Contracts.digest(model) and
             receipt["overlay_digest"] == config_digest(artifact),
         true <- valid_tools?(receipt["tools"]),
         do: {:ok, receipt["tools"], Contracts.digest(receipt)},
         else: (_ -> {:error, :codex_tools_unverified})
  rescue
    _ -> {:error, :codex_tools_unverified}
  end

  defp bounded_read(path, size) do
    with {:ok, io} <- File.open(path, [:read, :binary]) do
      try do
        case IO.binread(io, 131_073) do
          bytes when is_binary(bytes) and byte_size(bytes) == size -> {:ok, bytes}
          _ -> {:error, :codex_tools_unverified}
        end
      after
        File.close(io)
      end
    end
  end

  defp stable_stat?(before_stat, after_stat),
    do:
      Map.take(
        before_stat,
        ~w(type mode uid gid inode major_device minor_device links size mtime ctime)a
      ) ==
        Map.take(
          after_stat,
          ~w(type mode uid gid inode major_device minor_device links size mtime ctime)a
        )

  defp artifact_sources(artifact) do
    ids =
      get_in(artifact, ["spec", "spec", "rules"])
      |> Enum.flat_map(& &1["evidence"])
      |> Enum.map(& &1["revision_id"])
      |> Enum.uniq()

    revisions =
      Repo.all(
        from r in Revision,
          where: r.workspace_id == ^Workspaces.current_id() and r.id in ^ids,
          select: %{source_id: r.source_id, id: r.id}
      )

    with true <- length(revisions) == length(ids),
         {:ok, claims} <- HarnessForge.Evidence.approved_claims(),
         rules = get_in(artifact, ["spec", "spec", "rules"]),
         selected =
           Enum.filter(claims, fn claim ->
             Enum.any?(
               rules,
               &(&1["id"] == claim["id"] and &1["revision_hash"] == claim["revision_hash"])
             )
           end),
         true <- length(selected) == length(rules),
         {:ok, origins} <- origin_sources(selected),
         sources = Enum.uniq(Enum.map(revisions, & &1.source_id) ++ origins),
         true <- length(sources) in 1..100 do
      {:ok, sources}
    else
      _ -> {:error, :artifact_sources_unavailable}
    end
  rescue
    _ -> {:error, :artifact_sources_unavailable}
  end

  # Membership projection only. Origin and Harnesses retain all current-use
  # decisions; this supplies transitive source identities to the existing Ledger.
  defp origin_sources(claims) do
    Enum.reduce_while(claims, {:ok, []}, fn claim, {:ok, accumulated} ->
      with {:ok, refs} <- HarnessForge.Evidence.Origin.references(claim),
           {:ok, sources} <- manifest_sources(refs["manifest_refs"] || []),
           collected = Enum.uniq(accumulated ++ refs["source_ids"] ++ sources),
           true <- length(collected) <= 100 do
        {:cont, {:ok, collected}}
      else
        _ -> {:halt, {:error, :artifact_sources_unavailable}}
      end
    end)
  end

  defp manifest_sources(refs) do
    Enum.reduce_while(refs, {:ok, []}, fn ref, {:ok, accumulated} ->
      with {:ok, _} <- HarnessForge.Evidence.OriginV2.manifest(ref["id"], ref["digest"]),
           {:ok, %{rows: rows}} <-
             Repo.query(
               """
               WITH RECURSIVE manifests(id) AS (
                 SELECT ?
                 UNION
                 SELECT d.parent_manifest_id FROM origin_dependencies d JOIN manifests m ON m.id=d.manifest_id
                   WHERE d.workspace_id=? AND d.kind='manifest' AND d.parent_manifest_id IS NOT NULL
                 UNION
                 SELECT b.source_manifest_id FROM graph_manifest_builds b JOIN manifests m ON m.id=b.manifest_id
                   WHERE b.workspace_id=? AND b.source_manifest_id IS NOT NULL
               )
               SELECT DISTINCT d.source_id FROM origin_dependencies d JOIN manifests m ON m.id=d.manifest_id
                 WHERE d.workspace_id=? AND d.kind='source_revision' AND d.source_id IS NOT NULL LIMIT 101
               """,
               [
                 ref["id"],
                 Workspaces.current_id(),
                 Workspaces.current_id(),
                 Workspaces.current_id()
               ],
               log: false
             ),
           sources = Enum.uniq(accumulated ++ Enum.map(rows, &hd/1)),
           true <- length(sources) <= 100 do
        {:cont, {:ok, sources}}
      else
        _ -> {:halt, {:error, :artifact_sources_unavailable}}
      end
    end)
  end

  defp request_count(id) do
    {:ok, requests} = Models.list_requests(id)
    length(requests)
  end

  @doc false
  def settled_usage(id) do
    case Models.list_requests(id) do
      {:ok, requests} when requests != [] ->
        reported? =
          Enum.all?(requests, fn request ->
            request["state"] == "completed" and request["usage_status"] == "reported" and
              is_integer(request["input_tokens"]) and request["input_tokens"] >= 0 and
              is_integer(request["output_tokens"]) and request["output_tokens"] >= 0
          end)

        %{
          "usage_status" => if(reported?, do: "reported", else: "unknown"),
          "model_requests" => length(requests),
          "input_tokens" =>
            if(reported?, do: Enum.reduce(requests, 0, &(&1["input_tokens"] + &2)), else: nil),
          "output_tokens" =>
            if(reported?, do: Enum.reduce(requests, 0, &(&1["output_tokens"] + &2)), else: nil)
        }

      {:ok, []} ->
        %{"usage_status" => "not_dispatched", "model_requests" => 0}

      _ ->
        %{
          "usage_status" => "unknown",
          "model_requests" => nil,
          "input_tokens" => nil,
          "output_tokens" => nil
        }
    end
  rescue
    _ ->
      %{
        "usage_status" => "unknown",
        "model_requests" => nil,
        "input_tokens" => nil,
        "output_tokens" => nil
      }
  end

  @doc false
  def stop_session(id) do
    :global.trans({{__MODULE__, Workspaces.current_id(), id}, self()}, fn ->
      stop_owned_session(id)
    end)
  end

  defp stop_owned_session(id) do
    with :ok <- valid_id(id),
         true <-
           Repo.exists?(
             from r in Run, where: r.workspace_id == ^Workspaces.current_id() and r.id == ^id
           ) do
      CodingSession.stop(id)
    else
      _ -> {:error, :coding_cleanup_context_invalid}
    end
  end

  @doc "Revoke the owned local session, then clean only the persisted original Docker authority."
  def cleanup(id) do
    :global.trans({{__MODULE__, Workspaces.current_id(), id}, self()}, fn ->
      with :ok <- valid_id(id),
           :ok <- stop_owned_session(id),
           {:ok, observation} <- owned_observation(id),
           transport =
             transport_context(observation(observation), 60_000) |> Map.put(:runtime, observation),
           :ok <- CodingTransport.verify(observation(observation)),
           :ok <-
             Enum.reduce_while(resource_names(id), :ok, fn name, :ok ->
               case remove_owned(id, name, transport) do
                 :ok -> {:cont, :ok}
                 error -> {:halt, error}
               end
             end),
           :ok <- remove_network(id, transport),
           :ok <- CodingTransport.verify(observation(observation)) do
        :ok
      else
        :no_resources -> :ok
        {:error, reason} -> {:error, reason}
        _ -> {:error, :cleanup_failed}
      end
    end)
  end

  # Compatibility entry point uses persisted rows, never a default-daemon sweep.
  def reconcile do
    Repo.all(from r in Run, where: r.workspace_id == ^Workspaces.current_id())
    |> Enum.filter(fn r ->
      r.result["execution_profile_id"] in [@profile, @codex_profile] and
        (r.result["outcome"] in ~w(running pending) or
           r.result["cleanup_status"] in ~w(pending cleanup_failed))
    end)
    |> Enum.reduce_while(:ok, fn r, :ok ->
      case cleanup(r.id) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp remove_owned(id, name, transport) do
    with {:ok, present} <- present?(name, transport) do
      if present do
        with {:ok, _} <- inspect_owned(id, name, transport),
             :ok <- docker_ok(transport, ["rm", "--force", name]),
             {:ok, false} <- present?(name, transport),
             do: CodingTransport.verify(transport.observation)
      else
        CodingTransport.verify(transport.observation)
      end
    end
  end

  defp remove_network(id, transport) do
    args = ["network", "ls", "--filter", "name=^#{network(id)}$", "--format", "{{.Name}}"]

    with {:ok, %{exit_status: 0, output: output}} <- coding_command(transport, args) do
      if String.trim(output) == "" do
        CodingTransport.verify(transport.observation)
      else
        with true <- String.trim(output) == network(id),
             :ok <- verify_network(id, transport),
             :ok <- docker_ok(transport, ["network", "rm", network(id)]),
             {:ok, %{exit_status: 0, output: ""}} <- coding_command(transport, args),
             do: CodingTransport.verify(transport.observation)
      end
    end
  end

  defp present?(name, transport) do
    case coding_command(transport, [
           "ps",
           "--all",
           "--filter",
           "name=^/#{name}$",
           "--format",
           "{{.ID}}"
         ]) do
      {:ok, %{exit_status: 0, output: bytes}} -> {:ok, String.trim(bytes) != ""}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :container_presence_unavailable}
    end
  end

  defp image_available(image, transport),
    do: docker_ok(transport, ["image", "inspect", image, "--format", "{{.Id}}"])

  defp docker_ok(transport, args) do
    case coding_command(transport, args) do
      {:ok, %{exit_status: 0}} -> :ok
      {:error, reason} -> {:error, reason}
      _ -> {:error, :coding_docker_operation_failed}
    end
  end

  defp coding_command(transport, args, timeout \\ 10_000, limit \\ 65_536) do
    deadline = min(transport.deadline, System.monotonic_time(:millisecond) + timeout)

    with :ok <- CodingTransport.verify(transport.observation),
         true <- System.monotonic_time(:millisecond) < deadline do
      Command.docker_at(
        CodingTransport.endpoint(transport.observation),
        args,
        remaining(deadline, timeout),
        limit
      )
    else
      false -> {:error, :timed_out}
      error -> error
    end
  end

  defp transport_context(observation, timeout),
    do: %{observation: observation, deadline: System.monotonic_time(:millisecond) + timeout}

  defp admission_artifact(nil), do: :ok

  defp admission_artifact(artifact) do
    expected = if profile_id(artifact) == @codex_profile, do: "0.156.0", else: Docker.version()

    with true <- get_in(artifact, ["spec", "spec", "runtime", "name"]) in ["opencode", "codex"],
         true <- get_in(artifact, ["spec", "spec", "runtime", "version"]) == expected,
         {:ok, _} <- artifact_sources(artifact) do
      :ok
    else
      false -> {:error, :runtime_version_not_qualified}
      error -> error
    end
  end

  defp owned_observation(id, artifact \\ nil) do
    case Repo.one(
           from r in Run, where: r.workspace_id == ^Workspaces.current_id() and r.id == ^id
         ) do
      %Run{} = record ->
        result = record.result

        cond do
          is_nil(artifact) and is_nil(record.execution_context) and
              ((result["outcome"] == "blocked" and result["cleanup_status"] == "not_started" and
                  result["usage_status"] == "not_dispatched") or
                 (result["reason"] == "restored_requires_reevaluation" and
                    result["cleanup_status"] == "not_dispatched")) ->
            :no_resources

          result["execution_profile_id"] not in [@profile, @codex_profile] ->
            {:error, :coding_cleanup_origin_unknown}

          result["kind"] != "task" or result["runtime_name"] not in ["opencode", "codex"] or
            result["runtime_name"] == "codex" !=
              (result["execution_profile_id"] == @codex_profile) or
            result["id"] != record.id or result["artifact_digest"] != record.artifact_digest ->
            {:error, :coding_cleanup_context_invalid}

          not is_nil(artifact) and
              (record.artifact_digest != artifact["digest"] or
                 result["outcome"] != "running" or
                 result["model_context_digest"] != model_context_digest() or
                 result["effective_config_digest"] != config_digest(artifact)) ->
            {:error, :coding_cleanup_context_invalid}

          true ->
            with {:ok, admission} <-
                   decode_context(
                     record.execution_context,
                     result,
                     record.workspace_id,
                     record.id
                   ) do
              {:ok, admission}
            else
              _ -> {:error, :coding_cleanup_context_invalid}
            end
        end

      _ ->
        {:error, :coding_cleanup_context_invalid}
    end
  end

  defp valid_id(id),
    do:
      if(is_binary(id) and match?({:ok, _}, Ecto.UUID.cast(id)),
        do: :ok,
        else: {:error, :invalid_run_id}
      )

  defp blocked(reason),
    do: %{
      "outcome" => "blocked",
      "reason" => reason_string(reason),
      "runtime_qualified" => false,
      "checks" => [],
      "usage_status" => "not_dispatched",
      "cleanup_status" => "not_started"
    }

  defp reason_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_string(_), do: "coding_execution_failed"

  defp fence(id, transport, function) do
    :global.trans({{__MODULE__, Workspaces.current_id(), id}, self()}, fn ->
      case Repo.one(
             from r in Run, where: r.workspace_id == ^Workspaces.current_id() and r.id == ^id
           ) do
        %{result: %{"outcome" => "running"}} ->
          with {:ok, observation} <- owned_observation(id),
               true <- observation(observation) == transport.observation,
               :ok <- CodingTransport.verify(observation(observation)) do
            function.()
          else
            false -> {:error, :coding_cleanup_context_invalid}
            error -> error
          end

        _ ->
          {:error, :evaluation_cancelled}
      end
    end)
  end

  defp remaining(deadline, limit),
    do: min(max(deadline - System.monotonic_time(:millisecond), 1), limit)

  defp run_root(id), do: Path.join(Workspaces.paths()["runs"], "coding-" <> id)
  defp network(id), do: "hf-code-" <> id
  defp proxy_name(id), do: network(id) <> "-proxy"
  defp agent_name(id, task), do: network(id) <> "-" <> task <> "-agent"
  defp grader_name(id, task), do: network(id) <> "-" <> task <> "-grader"

  defp resource_names(id),
    do:
      Enum.flat_map(TaskSuite.tasks(), &[agent_name(id, &1), grader_name(id, &1)]) ++
        [proxy_name(id)]
end
