defmodule HarnessForge.Graphiti.ReplayTranscript do
  @moduledoc "Bounded, ephemeral original inputs and settled raw receipts; never persisted or recovered."
  alias HarnessForge.{Contracts, Repo}
  alias HarnessForge.Evidence.Store
  alias HarnessForge.Graphiti.SchemaPolicy
  alias HarnessForge.Models.StageAuthority
  @error {:error, :closure_incomplete}

  def new, do: %{"inputs" => %{}, "receipts" => %{}}

  def retain_page(cache, page) do
    logical = page["logical_call_id"]

    cond do
      page["seam_id"] == "llm.response.v1" and
          Enum.all?(page["entries"], &is_nil(&1["receipt_ref"])) ->
        bounded(%{
          cache
          | "inputs" => Map.delete(cache["inputs"], logical),
            "receipts" => Map.delete(cache["receipts"], logical)
        })

      page["phase"] == "inputs" and page["seam_id"] in ~w(llm.messages.v1 embedder.input.v1) ->
        values = Enum.map(page["entries"], & &1["value"])

        input = %{
          "stage_id" => page["stage_id"],
          "config_digest" => page["config_digest"],
          "prompt_name" => page["prompt_name"],
          "messages" => if(page["seam_id"] == "llm.messages.v1", do: values),
          "embed_input" => if(page["seam_id"] == "embedder.input.v1", do: List.first(values))
        }

        with true <- byte_size(Contracts.canonical_json(values)) <= 49_152 do
          case cache["inputs"][logical] do
            nil ->
              bounded(put_in(cache, ["inputs", logical], input))

            existing ->
              if Map.delete(existing, "max_tokens") == input, do: {:ok, cache}, else: @error
          end
        else
          _ -> @error
        end

      true ->
        {:ok, cache}
    end
  rescue
    _ -> @error
  end

  def retain_receipt(cache, auth, attempt, receipt) do
    logical = attempt["logical_call_id"]
    previous = Map.get(cache["receipts"], logical, [])

    with input when is_map(input) <- cache["inputs"][logical],
         true <- input["stage_id"] == attempt["stage_id"],
         {:ok, pin} <- StageAuthority.load_pin(attempt["stage_id"]),
         true <-
           input["config_digest"] == pin["config_digest"] and
             input["prompt_name"] == attempt["prompt_name"],
         true <- length(previous) < 3 and attempt["ordinal"] == length(previous) + 1,
         predecessor = if(previous == [], do: nil, else: List.last(previous)["attempt_id"]),
         true <- attempt["predecessor_attempt_id"] == predecessor,
         true <-
           receipt["attempt_id"] == attempt["attempt_id"] and
             receipt["receipt_id"] == attempt["attempt_id"] and
             receipt["state"] == "completed" and receipt["usage_status"] == "reported",
         body when is_binary(body) <- receipt["body"],
         true <-
           byte_size(body) <= 98_304 and String.valid?(body) and
             receipt["body_sha256"] == Store.hash(body),
         true <- attempt["payload_sha256"] == Store.hash(attempt["body"]),
         {:ok, %{rows: [[1]]}} <-
           Repo.query(
             """
             SELECT 1 FROM stage_attempts a JOIN model_requests r ON r.id=a.model_request_id AND r.workspace_id=a.workspace_id
             WHERE a.workspace_id=? AND a.id=? AND a.operation_id=? AND a.logical_call_id=? AND a.stage_config_id=?
               AND a.state='completed' AND a.payload_hash=? AND a.result_hash=? AND a.response_status=? AND a.response_bytes=?
               AND r.state='completed' AND r.usage_status='reported' AND r.provider=? AND r.model=?
             """,
             [
               Store.workspace(),
               attempt["attempt_id"],
               auth.operation_id,
               logical,
               pin["id"],
               attempt["payload_sha256"],
               receipt["body_sha256"],
               receipt["http_status"],
               byte_size(body),
               pin["provider"],
               pin["model"]
             ]
           ) do
      item = %{
        "attempt_id" => attempt["attempt_id"],
        "receipt_id" => receipt["receipt_id"],
        "ordinal" => attempt["ordinal"],
        "predecessor_attempt_id" => predecessor,
        "method" => "POST",
        "endpoint" => pin["endpoint"],
        "request_body_sha256" => attempt["payload_sha256"],
        "http_status" => receipt["http_status"],
        "body" => body,
        "body_sha256" => receipt["body_sha256"]
      }

      {:ok, native_body} = Jason.decode(attempt["body"])

      max_tokens =
        if pin["provider"] == "jev", do: pin["max_output_tokens"], else: native_body["max_tokens"]

      input = Map.put(input, "max_tokens", max_tokens)

      cache
      |> put_in(["inputs", logical], input)
      |> put_in(["receipts", logical], previous ++ [item])
      |> bounded()
    else
      _ -> @error
    end
  rescue
    _ -> @error
  end

  def request(cache, auth, page) do
    logical = page["logical_call_id"]

    with input when is_map(input) <- cache["inputs"][logical],
         transcript when is_list(transcript) and length(transcript) in 1..3 <-
           cache["receipts"][logical],
         {:ok, pin} <- StageAuthority.load_pin(input["stage_id"]),
         true <-
           Enum.any?(auth.stage_pins, &(&1 == pin)) and input["stage_id"] == page["stage_id"] and
             input["config_digest"] == page["config_digest"] and
             input["prompt_name"] == page["prompt_name"],
         :ok <- SchemaPolicy.validate_pin(pin),
         root = Application.app_dir(:harness_forge, "priv/graphiti_worker"),
         {:ok, source} <- File.read(Path.join(root, "source.lock.json")) do
      request = %{
        "v" => 1,
        "nonce" => Ecto.UUID.generate(),
        "source_lock_digest" => Store.hash(source),
        "catalogue_digest" => SchemaPolicy.digest(),
        "pin" => pin,
        "prompt_name" => input["prompt_name"],
        "group_id" => auth.scope_ref,
        "messages" => input["messages"],
        "embed_input" => input["embed_input"],
        "options" =>
          if(pin["stage"] != "embedder",
            do: %{
              "max_tokens" => input["max_tokens"],
              "model_size" => "medium",
              "attribute_extraction" => false
            }
          ),
        "transcript" => transcript
      }

      if byte_size(Contracts.canonical_json(request)) <= 524_288, do: {:ok, request}, else: @error
    else
      _ -> @error
    end
  rescue
    _ -> @error
  end

  defp bounded(cache) do
    if map_size(cache["inputs"]) <= 16 and map_size(cache["receipts"]) <= 16 and
         byte_size(Contracts.canonical_json(cache)) <= 524_288, do: {:ok, cache}, else: @error
  end
end
