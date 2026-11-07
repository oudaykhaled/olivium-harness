defmodule HarnessForge.Graphiti.Inventory do
  @moduledoc "Independent fixed-query measurement through a separately inspected private reader."
  alias HarnessForge.Contracts
  alias HarnessForge.Execution.Command
  alias HarnessForge.Graphiti.{Pipe, ReaderProfile}

  @query ~w(action kind cursor limit object_ids)
  @response ~w(v session_id action state records next_cursor exhausted error_code)

  # Context is held by the root launch owner, never supplied by a model/browser.
  # Database credentials are shared only inside this application TCB. They do
  # not establish a backend-enforced read-only role.
  def measure(context, query) do
    with true <- is_map(query) and Enum.sort(Map.keys(query)) == Enum.sort(@query),
         true <- query["action"] in ~w(identity page objects),
         session = Ecto.UUID.generate(),
         spec = Map.put(context.spec, "session_id", session),
         {:ok, args} <- ReaderProfile.args(spec),
         {:ok, %{exit_status: 0, output: output}} <- Command.docker_at(context.endpoint, args),
         id = String.trim(output),
         true <- HarnessForge.Models.Stages.digest?(id) do
      try do
        request =
          Map.merge(query, %{
            "v" => 1,
            "session_id" => session,
            "backend" => context.credentials,
            "group_id" => context.group_id
          })

        with {:ok, port} <- Pipe.attach(context.endpoint, id) do
          try do
            with {:ok, actual} <- running(context.endpoint, id, 20),
                 {:ok, launch} <- ReaderProfile.verify(spec, actual),
                 :ok <- topology(context, id),
                 {:ok, result} <- Pipe.exchange(port, request),
                 :ok <- validate_response(result, request),
                 :ok <- topology(context, id) do
              {:ok,
               %{
                 "result" => result,
                 "receipt" =>
                   Map.merge(launch, %{
                     "reader_session_id" => session,
                     "backend_container_id" => context.backend_id,
                     "response_digest" => Contracts.digest(result),
                     "action" => query["action"],
                     "measurement" => "trusted-application-read-only-independent-path-v1"
                   })
               }}
            else
              {:error, _} = error -> error
              _ -> {:error, :reconcile_required}
            end
          after
            Pipe.close(port)
          end
        end
      after
        Command.docker_at(context.endpoint, ["rm", "-f", id])
      end
    else
      _ -> {:error, :invalid_dto}
    end
  rescue
    _ -> {:error, :reconcile_required}
  end

  def identity(context),
    do:
      measure(context, %{
        "action" => "identity",
        "kind" => nil,
        "cursor" => nil,
        "limit" => 1,
        "object_ids" => []
      })

  def validate_response(value, request) do
    valid =
      is_map(value) and Enum.sort(Map.keys(value)) == Enum.sort(@response) and
        value["v"] === 1 and value["session_id"] == request["session_id"] and
        value["action"] == request["action"] and value["state"] in ~w(ok denied) and
        is_list(value["records"]) and length(value["records"]) <= 10 and
        is_boolean(value["exhausted"]) and bounded?(value, 0)

    cond do
      not valid ->
        {:error, :invalid_frame}

      value["state"] == "denied" ->
        if value["records"] == [] and is_nil(value["next_cursor"]) and
             value["exhausted"] == false and
             value["error_code"] in HarnessForge.Graphiti.Protocol.error_codes(),
           do: {:error, :closure_incomplete},
           else: {:error, :invalid_frame}

      value["error_code"] != nil ->
        {:error, :invalid_frame}

      value["exhausted"] != is_nil(value["next_cursor"]) ->
        {:error, :invalid_frame}

      request["action"] == "identity" ->
        validate_identity(value, request)

      true ->
        validate_objects(value, request)
    end
  rescue
    _ -> {:error, :invalid_frame}
  end

  defp validate_identity(value, request) do
    case value["records"] do
      [identity] ->
        if Enum.sort(Map.keys(identity)) ==
             Enum.sort(
               ~w(edition version database foreign_nodes foreign_edges unknown_nodes unknown_edges)
             ) and
             identity["edition"] == "community" and identity["version"] == "5.26.32" and
             identity["database"] == request["backend"]["database"] and
             value["exhausted"] and
             Enum.all?(
               ~w(foreign_nodes foreign_edges unknown_nodes unknown_edges),
               &(identity[&1] === 0)
             ), do: :ok, else: {:error, :reconcile_required}

      _ ->
        {:error, :invalid_frame}
    end
  end

  defp validate_objects(value, request) do
    types = %{
      "episode" => "EpisodicNode",
      "entity" => "EntityNode",
      "edge" => "EntityEdge",
      "mention" => "EpisodicEdge"
    }

    records = value["records"]
    ids = Enum.map(records, &get_in(&1, ["fields", "uuid"]))

    valid =
      Enum.all?(records, fn record ->
        Enum.sort(Map.keys(record)) == ~w(fields object_type vector_commitments) and
          record["object_type"] == types[request["kind"]] and
          is_map(record["fields"]) and record["fields"]["group_id"] == request["group_id"] and
          HarnessForge.Evidence.Corpora.uuid?(record["fields"]["uuid"]) and
          is_map(record["vector_commitments"])
      end) and length(records) <= request["limit"] and ids == Enum.sort(Enum.uniq(ids), :desc) and
        (is_nil(request["cursor"]) or Enum.all?(ids, &(&1 < request["cursor"]))) and
        (is_nil(value["next_cursor"]) or (ids != [] and value["next_cursor"] == List.last(ids))) and
        (request["action"] != "objects" or
           (value["exhausted"] and Enum.sort(ids) == Enum.sort(request["object_ids"])))

    if valid, do: :ok, else: {:error, :closure_incomplete}
  end

  defp bounded?(_, depth) when depth > 12, do: false

  defp bounded?(value, depth) when is_map(value),
    do:
      map_size(value) <= 100 and
        Enum.all?(value, fn {k, v} -> is_binary(k) and bounded?(v, depth + 1) end)

  defp bounded?(value, depth) when is_list(value),
    do: length(value) <= 100 and Enum.all?(value, &bounded?(&1, depth + 1))

  defp bounded?(value, _) when is_binary(value),
    do: String.valid?(value) and byte_size(value) <= 98_304

  defp bounded?(value, _), do: is_integer(value) or is_boolean(value) or is_nil(value)

  defp running(_endpoint, _id, 0), do: {:error, :worker_lost}

  defp running(endpoint, id, remaining) do
    with {:ok, %{exit_status: 0, output: bytes}} <- Command.docker_at(endpoint, ["inspect", id]),
         {:ok, [actual]} <- Jason.decode(bytes) do
      if actual["State"]["Running"] == true do
        {:ok, actual}
      else
        Process.sleep(25)
        running(endpoint, id, remaining - 1)
      end
    else
      _ -> {:error, :worker_lost}
    end
  end

  defp topology(context, reader) do
    with {:ok, %{exit_status: 0, output: bytes}} <-
           Command.docker_at(context.endpoint, ["network", "inspect", context.spec["network_id"]]),
         {:ok, [network]} <- Jason.decode(bytes),
         ids = Map.keys(network["Containers"] || %{}),
         allowed = [context.backend_id | context.writer_ids] ++ if(reader, do: [reader], else: []),
         true <- Enum.all?(ids, &(&1 in allowed)) and context.backend_id in ids do
      :ok
    else
      _ -> {:error, :reconcile_required}
    end
  end
end
