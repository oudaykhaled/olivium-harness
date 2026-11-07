defmodule HarnessForge.Graphiti.ResponseProof do
  @moduledoc "Isolated replay of settled receipts through pinned native clients; grants no send authority."
  alias HarnessForge.Contracts
  alias HarnessForge.Graphiti.{Backend, LaunchProfile, Pipe}

  # Context and the transcript come from the private live owner, never a browser.
  def verify(context, request, timeout)
      when is_map(context) and is_map(request) and timeout in 1..15_000 do
    spec = Map.put(context.spec, "session_id", Ecto.UUID.generate())

    with {:ok, args} <- args(spec),
         {:ok, output} <- Backend.command(context.endpoint, args),
         id = String.trim(output),
         true <- HarnessForge.Models.Stages.digest?(id) do
      try do
        with {:ok, port} <- Pipe.attach(context.endpoint, id) do
          try do
            with {:ok, actual} <- running(context.endpoint, id, 40),
                 {:ok, profile} <- LaunchProfile.verify_replay(spec, actual),
                 {:ok, response} <- Pipe.exchange(port, request, timeout, 524_288),
                 :ok <- validate_result(request, response) do
              {:ok,
               %{
                 "value" => response["value"],
                 "receipt" =>
                   Map.merge(profile, %{
                     "response_sha256" => Contracts.digest(response),
                     "transcript_sha256" => response["transcript_sha256"],
                     "measurement" => "pinned-native-client-offline-replay-v1"
                   })
               }}
            else
              _ -> {:error, :closure_incomplete}
            end
          after
            Pipe.close(port)
          end
        end
      after
        Backend.command(context.endpoint, ["rm", "-f", id])
      end
    else
      _ -> {:error, :closure_incomplete}
    end
  rescue
    _ -> {:error, :closure_incomplete}
  end

  def verify(_, _, _), do: {:error, :closure_incomplete}

  @doc false
  def args(spec) do
    with {:ok, base} <- LaunchProfile.worker_profile(spec) do
      labels =
        Map.put(base["labels"], "dev.harnessforge.profile", "graph-response-replay-isolated-v1")

      name = "hf-graph-replay-" <> String.replace(spec["session_id"], "-", "")
      # Retain all shared process limits. Replace only the fixed name/labels,
      # network and entrypoint. No user-supplied arguments or filesystem path.
      argv =
        replace(base["argv"], "--name", name)
        |> replace("--network", "none")
        |> drop_option("--network-alias")
        |> replace_labels(labels)

      {prefix, [image]} = Enum.split(argv, length(argv) - 1)
      {:ok, prefix ++ ["--entrypoint", "python", image, "-I", "/app/response_proof.py"]}
    end
  end

  @doc false
  def validate_result(request, response) do
    expected_keys =
      ~w(v nonce state transcript_sha256 consumed_receipts value value_sha256 error_code)

    consumed = Enum.map(request["transcript"], &Map.take(&1, ~w(attempt_id receipt_id)))

    with true <- is_map(response) and Enum.sort(Map.keys(response)) == Enum.sort(expected_keys),
         true <-
           response["v"] === 1 and response["state"] == "ok" and is_nil(response["error_code"]),
         true <-
           response["nonce"] == request["nonce"] and
             response["transcript_sha256"] == Contracts.digest(request["transcript"]) and
             response["consumed_receipts"] == consumed,
         true <- response["value_sha256"] == Contracts.digest(response["value"]),
         true <- byte_size(Contracts.canonical_json(response)) <= 98_304,
         do: :ok,
         else: (_ -> {:error, :closure_incomplete})
  rescue
    _ -> {:error, :closure_incomplete}
  end

  defp replace([key, _ | rest], key, value), do: [key, value | rest]
  defp replace([head | rest], key, value), do: [head | replace(rest, key, value)]
  defp replace([], _, _), do: []
  defp drop_option([key, _ | rest], key), do: rest
  defp drop_option([head | rest], key), do: [head | drop_option(rest, key)]
  defp drop_option([], _), do: []

  defp replace_labels(["--label", value | rest], labels) do
    [key, _] = String.split(value, "=", parts: 2)
    ["--label", key <> "=" <> Map.fetch!(labels, key) | replace_labels(rest, labels)]
  end

  defp replace_labels([head | rest], labels), do: [head | replace_labels(rest, labels)]
  defp replace_labels([], _), do: []

  defp running(_, _, 0), do: {:error, :worker_lost}

  defp running(endpoint, id, remaining) do
    with {:ok, actual} <- Backend.inspection(endpoint, ["inspect", id]) do
      if actual["State"]["Running"] === true do
        {:ok, actual}
      else
        Process.sleep(25)
        running(endpoint, id, remaining - 1)
      end
    end
  end
end
