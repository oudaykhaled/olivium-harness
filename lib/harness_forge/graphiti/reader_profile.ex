defmodule HarnessForge.Graphiti.ReaderProfile do
  @moduledoc "A separately launched trusted application-read-only reader; no database role claim."
  alias HarnessForge.{Contracts, Graphiti.LaunchProfile}
  @profile "graph-reader-isolated-v1"

  def args(spec) do
    with {:ok, base} <- LaunchProfile.worker_profile(spec) do
      argv =
        base["argv"]
        |> replace_option("--name", name(spec))
        |> replace_option("--network-alias", "reader")
        |> Enum.map(
          &String.replace(
            &1,
            "dev.harnessforge.profile=graph-worker-isolated-v1",
            "dev.harnessforge.profile=" <> @profile
          )
        )

      {prefix, [image]} = Enum.split(argv, length(argv) - 1)
      {:ok, prefix ++ ["--entrypoint", "python", image, "-I", "/app/inventory.py"]}
    end
  end

  def verify(spec, actual) do
    with {:ok, base} <- LaunchProfile.worker_profile(spec),
         true <- is_map(actual) and actual["Name"] == "/" <> name(spec),
         true <- actual["Path"] == "python" and actual["Args"] == ["-I", "/app/inventory.py"],
         %{"Entrypoint" => ["python"], "Cmd" => ["-I", "/app/inventory.py"], "Labels" => labels} <-
           actual["Config"],
         true <- labels == Map.put(base["labels"], "dev.harnessforge.profile", @profile),
         endpoint when is_map(endpoint) <-
           get_in(actual, ["NetworkSettings", "Networks", spec["network_name"]]),
         aliases when is_list(aliases) <- endpoint["Aliases"],
         allowed = [name(spec), "reader", actual["Id"], String.slice(actual["Id"], 0, 12)],
         true <- "reader" in aliases and Enum.all?(aliases, &(&1 in allowed)),
         true <- is_nil(endpoint["DNSNames"]) or Enum.all?(endpoint["DNSNames"], &(&1 in allowed)) do
      # Normalize ONLY fields whose exact reader values were checked above.
      # All isolation/image/environment checks are the shared worker checks.
      worker =
        actual
        |> Map.put("Name", "/" <> base["name"])
        |> Map.put("Args", ["-I", "/app/__main__.py"])
        |> put_in(["Config", "Entrypoint"], ["python", "-I", "/app/__main__.py"])
        |> put_in(["Config", "Cmd"], nil)
        |> put_in(["Config", "Labels"], base["labels"])
        |> put_in(["NetworkSettings", "Networks", spec["network_name"], "Aliases"], ["worker"])
        |> put_in(["NetworkSettings", "Networks", spec["network_name"], "DNSNames"], nil)

      with {:ok, receipt} <- LaunchProfile.verify_worker(spec, worker) do
        {:ok,
         Map.put(
           receipt,
           "profile_digest",
           Contracts.digest(%{"profile" => @profile, "base" => base})
         )}
      end
    else
      _ -> {:error, :graph_launch_mismatch}
    end
  rescue
    _ -> {:error, :graph_launch_mismatch}
  end

  defp name(spec), do: "hf-graph-reader-" <> String.replace(spec["session_id"], "-", "")

  defp replace_option(argv, key, value) do
    Enum.chunk_while(
      argv,
      [],
      fn item, acc ->
        case acc do
          [^key] -> {:cont, [key, value], []}
          [] when item == key -> {:cont, [item]}
          [] -> {:cont, [item], []}
        end
      end,
      fn acc -> {:cont, acc, []} end
    )
    |> List.flatten()
  end
end
