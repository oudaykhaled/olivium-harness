defmodule HarnessForge.Graphiti.Backend do
  @moduledoc false
  alias HarnessForge.{Contracts, Workspaces}
  alias HarnessForge.Execution.Command
  alias HarnessForge.Graphiti.{BackendProfile, Inventory, LaunchProfile}

  # Called only by the root launch owner. Every resource is fresh and belongs
  # to this partition. No existing backend, mounted host directory or public
  # listener is adopted. Progress contains no credentials.
  def create(partition, image, backend_image, progress) do
    with {:ok, endpoint} <- Command.local_endpoint(),
         {:ok, args} <-
           LaunchProfile.network_args(Workspaces.current_id(), partition["partition_id"]),
         {:ok, output} <- command(endpoint, args),
         network_id = String.trim(output),
         {:ok, network} <- inspection(endpoint, ["network", "inspect", network_id]),
         {:ok, network_receipt} <-
           LaunchProfile.verify_network(
             Workspaces.current_id(),
             partition["partition_id"],
             network
           ) do
      resources = %{
        "partition_id" => partition["partition_id"],
        "workspace_id" => Workspaces.current_id(),
        "network_id" => network_id,
        "network_name" => network_receipt["network_name"],
        "volumes" => [],
        "backend_id" => nil
      }

      :ok = progress.(resources)
      provision(endpoint, partition, image, backend_image, resources, progress)
    else
      _ -> {:error, :graph_unavailable}
    end
  rescue
    _ -> {:error, :reconcile_required}
  end

  def cleanup(endpoint, resources) do
    with :ok <- cleanup_scope(resources),
         :ok <- remove_backend(endpoint, resources),
         :ok <- remove_volumes(endpoint, resources),
         :ok <- remove_network(endpoint, resources) do
      :ok
    else
      _ -> {:error, :reconcile_required}
    end
  end

  # This only authorises deletion of the exact recorded resources. A persisted
  # record never authorises attaching or adopting a backend after owner loss.
  def cleanup_scope(resources) when is_map(resources) do
    suffix = String.replace(resources["partition_id"] || "", "-", "")
    allowed = Enum.map(~w(data logs conf), &("hf-graph-" <> &1 <> "-" <> suffix))

    if Enum.sort(Map.keys(resources)) ==
         Enum.sort(~w(partition_id workspace_id network_id network_name volumes backend_id)) and
         resources["workspace_id"] == Workspaces.current_id() and
         HarnessForge.Evidence.Corpora.uuid?(resources["partition_id"]) and
         HarnessForge.Models.Stages.digest?(resources["network_id"]) and
         resources["network_name"] == "hf-graph-net-" <> suffix and
         (is_nil(resources["backend_id"]) or
            HarnessForge.Models.Stages.digest?(resources["backend_id"])) and
         is_list(resources["volumes"]) and length(resources["volumes"]) <= 3 and
         length(Enum.uniq_by(resources["volumes"], & &1["Name"])) ==
           length(resources["volumes"]) and
         Enum.all?(resources["volumes"], fn saved ->
           is_map(saved) and
             Enum.sort(Map.keys(saved)) == Enum.sort(~w(Name CreatedAt Driver Labels Options)) and
             saved["Name"] in allowed and is_binary(saved["CreatedAt"]) and
             saved["Driver"] == "local" and saved["Options"] in [nil, %{}] and
             saved["Labels"] == volume_labels(resources)
         end),
       do: :ok,
       else: {:error, :reconcile_required}
  rescue
    _ -> {:error, :reconcile_required}
  end

  def cleanup_scope(_), do: {:error, :reconcile_required}

  def remove_worker(endpoint, id, partition, session) do
    expected = %{
      "dev.harnessforge.workspace" => Workspaces.current_id(),
      "dev.harnessforge.partition" => partition,
      "dev.harnessforge.profile" => "graph-worker-isolated-v1",
      "dev.harnessforge.session" => session
    }

    with true <- HarnessForge.Models.Stages.digest?(id),
         true <-
           HarnessForge.Evidence.Corpora.uuid?(partition) and
             HarnessForge.Evidence.Corpora.uuid?(session),
         {:ok, present} <- exists(endpoint, :container, id) do
      if present do
        result =
          with {:ok, actual} <- inspection(endpoint, ["inspect", id]),
               true <- actual["Id"] == id and actual["Config"]["Labels"] == expected,
               {:ok, _} <- command(endpoint, ["rm", "-f", id], 35_000),
               {:ok, false} <- exists(endpoint, :container, id),
               do: :ok,
               else: (_ -> {:error, :reconcile_required})

        # The owner-loss guardian may remove this same immutable ID between
        # list/inspect/remove. Only a fresh successful absence check settles
        # that race; an inspection or daemon error alone is never success.
        case result do
          :ok -> :ok
          _ -> settle_worker_removal(endpoint, id, System.monotonic_time(:millisecond) + 2_000)
        end
      else
        :ok
      end
    else
      _ -> {:error, :reconcile_required}
    end
  end

  # The guardian may still be completing the exact same removal. Observe only
  # this immutable ID, for a bounded time; never retry mutation or treat a
  # daemon/query failure as absence.
  defp settle_worker_removal(endpoint, id, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :reconcile_required}
    else
      case exists(endpoint, :container, id, min(remaining, 1_000)) do
        {:ok, false} ->
          :ok

        {:ok, true} ->
          Process.sleep(25)
          settle_worker_removal(endpoint, id, deadline)

        _ ->
          {:error, :reconcile_required}
      end
    end
  end

  def inspect_current(context) do
    with {:ok, backend} <- inspection(context.endpoint, ["inspect", context.backend_id]),
         true <- backend["State"]["Running"] === true,
         {:ok, _} <- BackendProfile.verify_backend(context.backend_spec, backend),
         {:ok, network} <-
           inspection(context.endpoint, ["network", "inspect", context.spec["network_id"]]),
         {:ok, _} <-
           LaunchProfile.verify_network(
             context.spec["workspace_id"],
             context.spec["partition_id"],
             network
           ),
         true <-
           Enum.all?(
             Map.keys(network["Containers"] || %{}),
             &(&1 in [context.backend_id | context.writer_ids])
           ) do
      :ok
    else
      _ -> {:error, :reconcile_required}
    end
  end

  def inspection(endpoint, args) do
    with {:ok, bytes} <- command(endpoint, args),
         {:ok, [value]} <- Jason.decode(bytes),
         true <- is_map(value),
         do: {:ok, value},
         else: (_ -> {:error, :graph_unavailable})
  end

  def command(endpoint, args, timeout \\ 15_000) do
    case Command.docker_at(endpoint, args, timeout, 262_144) do
      {:ok, %{exit_status: 0, output: bytes}} -> {:ok, bytes}
      _ -> {:error, :graph_unavailable}
    end
  end

  defp provision(endpoint, partition, image, backend_image, resources, progress) do
    password = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    env = %{
      "NEO4J_AUTH" => "neo4j/" <> password,
      "NEO4J_server_memory_heap_initial__size" => "256m",
      "NEO4J_server_memory_heap_max__size" => "512m",
      "NEO4J_server_memory_pagecache_size" => "256m",
      "NEO4J_server_http_enabled" => "false",
      "NEO4J_server_https_enabled" => "false",
      "NEO4J_server_bolt_advertised__address" => "neo4j:7687",
      "NEO4J_dbms_usage__report_enabled" => "false",
      "JAVA_TOOL_OPTIONS" => "-Djava.io.tmpdir=/tmp/neo4j-native"
    }

    directory = Path.join([Workspaces.root(), "tmp", "graph-launch-" <> Ecto.UUID.generate()])
    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)
    env_file = Path.join(directory, "backend.env")
    # Exclusive creation and private parent prevent accidental credential reuse.
    File.write!(
      env_file,
      Enum.map_join(Enum.sort(env), "\n", fn {k, v} -> k <> "=" <> v end) <> "\n",
      [:exclusive]
    )

    File.chmod!(env_file, 0o600)

    try do
      with {:ok, metadata} <- inspection(endpoint, ["image", "inspect", backend_image]),
           true <- metadata["Id"] == backend_image and metadata["Os"] == "linux",
           defaults =
             Map.new(metadata["Config"]["Env"], fn item ->
               item |> String.split("=", parts: 2) |> List.to_tuple()
             end),
           effective = Enum.map(Map.merge(defaults, env), fn {k, v} -> k <> "=" <> v end),
           backend_spec = %{
             "workspace_id" => Workspaces.current_id(),
             "partition_id" => partition["partition_id"],
             "backend_image" => backend_image,
             "network_name" => resources["network_name"],
             "network_id" => resources["network_id"],
             "env_file" => env_file,
             "env_digest" => Contracts.digest(Enum.sort(effective))
           },
           {:ok, intended} <- BackendProfile.backend_profile(backend_spec),
           {:ok, resources} <- volumes(endpoint, intended["volumes"], resources, progress),
           {:ok, argv} <- BackendProfile.backend_args(backend_spec),
           {:ok, output} <- command(endpoint, argv),
           backend_id = String.trim(output),
           true <- HarnessForge.Models.Stages.digest?(backend_id) do
        resources = Map.put(resources, "backend_id", backend_id)
        :ok = progress.(resources)

        with {:ok, _} <- command(endpoint, ["start", backend_id]),
             {:ok, actual} <- inspection(endpoint, ["inspect", backend_id]),
             {:ok, backend_receipt} <- BackendProfile.verify_backend(backend_spec, actual) do
          spec = %{
            "workspace_id" => Workspaces.current_id(),
            "partition_id" => partition["partition_id"],
            "session_id" => Ecto.UUID.generate(),
            "worker_image" => image["image_id"],
            "network_name" => resources["network_name"],
            "network_id" => resources["network_id"],
            "image_env_digest" => image["image_env_digest"]
          }

          context = %{
            endpoint: endpoint,
            spec: spec,
            backend_spec: backend_spec,
            backend_id: backend_id,
            writer_ids: [],
            group_id: partition["group_id"],
            resources: resources,
            image: image,
            backend_receipt: backend_receipt,
            credentials: %{
              "uri" => "bolt://neo4j:7687",
              "user" => "neo4j",
              "password" => password,
              "database" => "neo4j"
            }
          }

          with {:ok, inventory} <- ready(context, System.monotonic_time(:millisecond) + 60_000),
               :ok <- inspect_current(context) do
            {:ok, Map.put(context, :initial_inventory, inventory)}
          end
        end
      else
        _ -> {:error, :graph_unavailable}
      end
    after
      File.rm(env_file)
      File.rmdir(directory)
    end
  end

  defp volumes(endpoint, expected, resources, progress) do
    Enum.reduce_while(Enum.sort(expected), {:ok, resources}, fn {_destination, name},
                                                                {:ok, current} ->
      # A preexisting name is never implicitly adopted, even with matching labels.
      with {:ok, %{exit_status: status}} when status != 0 <-
             Command.docker_at(endpoint, ["volume", "inspect", name]),
           {:ok, _} <-
             command(
               endpoint,
               ["volume", "create", "--driver", "local"] ++
                 label_args(volume_labels(resources)) ++ [name]
             ),
           {:ok, actual} <- inspection(endpoint, ["volume", "inspect", name]),
           true <-
             actual["Name"] == name and actual["Driver"] == "local" and
               actual["Options"] in [nil, %{}] and actual["Labels"] == volume_labels(resources) do
        next =
          Map.put(
            current,
            "volumes",
            current["volumes"] ++ [Map.take(actual, ~w(Name CreatedAt Driver Labels Options))]
          )

        :ok = progress.(next)
        {:cont, {:ok, next}}
      else
        _ -> {:halt, {:error, :reconcile_required}}
      end
    end)
  end

  defp ready(context, deadline) do
    case Inventory.identity(context) do
      {:ok, _} = result ->
        result

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :graph_unavailable}
        else
          Process.sleep(250)
          ready(context, deadline)
        end
    end
  end

  defp remove_backend(_endpoint, %{"backend_id" => nil}), do: :ok

  defp remove_backend(endpoint, resources) do
    with {:ok, present} <- exists(endpoint, :container, resources["backend_id"]) do
      if present, do: remove_present_backend(endpoint, resources), else: :ok
    end
  end

  defp remove_present_backend(endpoint, resources) do
    with {:ok, actual} <- inspection(endpoint, ["inspect", resources["backend_id"]]),
         true <-
           actual["Id"] == resources["backend_id"] and
             actual["Config"]["Labels"] ==
               Map.put(
                 volume_labels(resources),
                 "dev.harnessforge.profile",
                 "graph-backend-isolated-v1"
               ),
         {:ok, _} <- command(endpoint, ["rm", "-f", resources["backend_id"]], 35_000),
         {:ok, false} <- exists(endpoint, :container, resources["backend_id"]) do
      :ok
    else
      _ -> {:error, :reconcile_required}
    end
  end

  defp remove_volumes(endpoint, resources) do
    Enum.reduce_while(resources["volumes"], :ok, fn saved, :ok ->
      with :ok <- remove_volume(endpoint, saved) do
        {:cont, :ok}
      else
        _ -> {:halt, {:error, :reconcile_required}}
      end
    end)
  end

  defp remove_volume(endpoint, saved) do
    with {:ok, present} <- exists(endpoint, :volume, saved["Name"]) do
      if present do
        with {:ok, actual} <- inspection(endpoint, ["volume", "inspect", saved["Name"]]),
             true <- Map.take(actual, Map.keys(saved)) == saved,
             {:ok, _} <- command(endpoint, ["volume", "rm", saved["Name"]]),
             {:ok, false} <- exists(endpoint, :volume, saved["Name"]),
             do: :ok,
             else: (_ -> {:error, :reconcile_required})
      else
        :ok
      end
    end
  end

  defp remove_network(endpoint, resources) do
    with {:ok, present} <- exists(endpoint, :network, resources["network_id"]) do
      if present do
        with {:ok, network} <-
               inspection(endpoint, ["network", "inspect", resources["network_id"]]),
             true <-
               network["Id"] == resources["network_id"] and
                 network["Labels"] == network_labels(resources) and
                 network["Name"] == resources["network_name"] and
                 network["Containers"] in [nil, %{}],
             {:ok, _} <- command(endpoint, ["network", "rm", resources["network_id"]]),
             {:ok, false} <- exists(endpoint, :network, resources["network_id"]),
             do: :ok,
             else: (_ -> {:error, :reconcile_required})
      else
        :ok
      end
    end
  end

  # A failed inspect cannot distinguish absence from an unavailable daemon.
  # Only a successful bounded inventory proves that an exact resource is gone.
  defp exists(endpoint, kind, identity, timeout \\ 15_000) do
    args =
      case kind do
        :container ->
          [
            "container",
            "ls",
            "--all",
            "--no-trunc",
            "--filter",
            "id=" <> identity,
            "--format",
            "{{.ID}}"
          ]

        :network ->
          ["network", "ls", "--no-trunc", "--filter", "id=" <> identity, "--format", "{{.ID}}"]

        :volume ->
          ["volume", "ls", "--filter", "name=" <> identity, "--format", "{{.Name}}"]
      end

    with {:ok, output} <- command(endpoint, args, timeout) do
      names = String.split(output, "\n", trim: true)
      {:ok, identity in names}
    end
  end

  defp volume_labels(resources),
    do: %{
      "dev.harnessforge.workspace" => resources["workspace_id"],
      "dev.harnessforge.partition" => resources["partition_id"]
    }

  defp network_labels(resources),
    do: Map.put(volume_labels(resources), "dev.harnessforge.profile", "graph-worker-isolated-v1")

  defp label_args(labels),
    do: Enum.flat_map(Enum.sort(labels), fn {k, v} -> ["--label", k <> "=" <> v] end)
end
