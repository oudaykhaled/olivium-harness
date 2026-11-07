defmodule HarnessForge.Graphiti.IngestIntent do
  @moduledoc "Server-owned one-passage native episode intent; preparing an intent sends no model request."
  alias HarnessForge.{Contracts, Repo}
  alias HarnessForge.Evidence.{GraphManifests, Passages, Store}
  alias HarnessForge.Graphiti.{Protocol, Runtime, SchemaPolicy}
  alias HarnessForge.Models.{StageAuthority, StageControl}
  @error {:error, :closure_incomplete}
  @context ~w(operation_manifest_ref operation_manifest_digest base_context_ref base_context_digest context_id logical_call_id seam_id stage_id prompt_name config_digest schema_digest raw_body_sha256 rendered_projection_digest transform_id receipt_ref receipt_digest)
  @row ~w(source_id revision_id episode_binding_id derivative_version_id projection_id projection_hash parent_manifest_id)

  def prepare(%StageAuthority{operation_type: "ingest"} = auth, passage_id) do
    with :ok <- Runtime.current(auth) do
      HarnessForge.Privacy.Purge.synchronize(fn ->
        Store.transaction(fn ->
          with {:ok, _} <- StageControl.graph_current(auth),
               true <-
                 Enum.all?(~w(extraction summary node_dedupe edge_dedupe embedder), fn stage ->
                   Enum.any?(auth.stage_pins, &(&1["stage"] == stage))
                 end),
               {:ok, window} <- Passages.envelope(passage_id),
               {:ok, true} <-
                 GraphManifests.contains_source?(
                   auth.manifest_id,
                   auth.manifest_digest,
                   window["source_id"],
                   auth
                 ),
               {:ok, %{rows: []}} <-
                 Repo.query(
                   "SELECT id FROM graph_episode_bindings WHERE workspace_id=? AND partition_id=? AND passage_id=?",
                   [Store.workspace(), auth.partition_id, passage_id]
                 ),
               {:ok, %{rows: previous}} <-
                 Repo.query(
                   "SELECT episode_uuid FROM graph_episode_bindings WHERE workspace_id=? AND partition_id=? AND state='ready' ORDER BY inserted_at DESC,id DESC LIMIT 24",
                   [Store.workspace(), auth.partition_id]
                 ),
               {reference, basis} = reference_time(window),
               binding = Ecto.UUID.generate(),
               args = %{
                 "binding_id" => binding,
                 "episode_uuid" => Ecto.UUID.generate(),
                 "revision_id" => window["revision_id"],
                 "body_hash" => window["snippet_hash"],
                 "window_start" => window["start_byte"],
                 "window_end" => window["end_byte"],
                 "body" => window["snippet"],
                 "reference_time" => reference,
                 "time_basis" => basis,
                 "prior_episode_ids" => previous |> Enum.reverse() |> Enum.map(&hd/1)
               },
               job = job(auth, args),
               :ok <- Protocol.validate_payload("job", job),
               {:ok, input} <- seal_input(auth, window),
               {:ok, _} <-
                 Repo.query(
                   "INSERT INTO graph_episode_bindings(id,workspace_id,partition_id,revision_id,passage_id,chunker_version,episode_uuid,payload_hash,state,manifest_id,inserted_at,updated_at) VALUES(?,?,?,?,?,?,?,?,'staging',?,?,?)",
                   [
                     binding,
                     Store.workspace(),
                     auth.partition_id,
                     window["revision_id"],
                     passage_id,
                     Passages.versions()["chunker"],
                     args["episode_uuid"],
                     Contracts.digest(args),
                     input["manifest_id"],
                     now(),
                     now()
                   ]
                 ),
               {:ok, _} <- StageControl.graph_current(auth) do
            {:ok, job}
          else
            _ -> @error
          end
        end)
      end)
    end
  rescue
    _ -> @error
  end

  def prepare(_, _), do: @error

  # The private live owner calls this before registering a job. Its args must
  # match both the root-minted immutable intent hash and the original UTF-8
  # passage window. A worker-provided body or UUID cannot establish an intent.
  def validate(%StageAuthority{operation_type: "ingest"} = auth, job) do
    with {:ok, _} <- StageControl.graph_current(auth),
         :ok <- Protocol.validate_payload("job", job),
         true <- same_control?(auth, job),
         args = job["args"],
         {:ok, %{rows: [[passage, revision, episode, hash, state, input, digest]]}} <-
           Repo.query(
             "SELECT b.passage_id,b.revision_id,b.episode_uuid,b.payload_hash,b.state,b.manifest_id,m.digest FROM graph_episode_bindings b JOIN dependency_manifests m ON m.workspace_id=b.workspace_id AND m.id=b.manifest_id AND m.state='sealed' WHERE b.workspace_id=? AND b.partition_id=? AND b.id=?",
             [Store.workspace(), auth.partition_id, args["binding_id"]]
           ),
         true <-
           state in ~w(staging indexing) and revision == args["revision_id"] and
             episode == args["episode_uuid"] and hash == Contracts.digest(args),
         {:ok, _} <- GraphManifests.validate_current(input, digest, auth),
         {:ok, window} <- Passages.envelope(passage),
         {reference, basis} = reference_time(window),
         true <-
           window["revision_id"] == revision and args["body"] == window["snippet"] and
             args["body_hash"] == window["snippet_hash"] and
             args["window_start"] == window["start_byte"] and
             args["window_end"] == window["end_byte"] and args["reference_time"] == reference and
             args["time_basis"] == basis,
         {:ok, true} <-
           GraphManifests.contains_source?(
             auth.manifest_id,
             auth.manifest_digest,
             window["source_id"],
             auth
           ),
         do: :ok,
         else: (_ -> @error)
  rescue
    _ -> @error
  end

  def validate(_, _), do: @error

  defp job(auth, args) do
    %{
      "op" => "ingest",
      "job_id" => auth.operation_id,
      "idempotency_key" => Ecto.UUID.generate(),
      "scope_ref" => auth.scope_ref,
      "semantic_generation" => auth.semantic_generation,
      "authorization_generation" => auth.authorization_generation,
      "cancel_epoch" => auth.cancel_epoch,
      "closure_ref" => auth.manifest_id,
      "closure_digest" => auth.manifest_digest,
      "stage_set_digest" => StageAuthority.stage_set_digest(auth),
      "partition_id" => auth.partition_id,
      "lease_id" => auth.lease_id,
      "worker_session_id" => auth.worker_session_id,
      "deadline_ms" => max(1, DateTime.diff(auth.deadline_at, Store.now(), :millisecond)),
      "args" => args
    }
  end

  defp same_control?(auth, job) do
    expected = %{
      "op" => auth.operation_type,
      "job_id" => auth.operation_id,
      "scope_ref" => auth.scope_ref,
      "semantic_generation" => auth.semantic_generation,
      "authorization_generation" => auth.authorization_generation,
      "cancel_epoch" => auth.cancel_epoch,
      "closure_ref" => auth.manifest_id,
      "closure_digest" => auth.manifest_digest,
      "stage_set_digest" => StageAuthority.stage_set_digest(auth),
      "partition_id" => auth.partition_id,
      "lease_id" => auth.lease_id,
      "worker_session_id" => auth.worker_session_id
    }

    Map.take(job, Map.keys(expected)) == expected
  end

  defp reference_time(window) do
    [{"effective_at", "effective"}, {"event_at", "event"}, {"captured_at", "capture_fallback"}]
    |> Enum.find_value(fn {field, basis} ->
      with value when is_binary(value) <- window[field],
           {:ok, date, _} <- DateTime.from_iso8601(value) do
        {DateTime.to_iso8601(date), basis}
      else
        _ -> nil
      end
    end)
  end

  defp seal_input(auth, window) do
    pin = Enum.find(auth.stage_pins, &(&1["stage"] == "extraction"))

    with {:ok, entry} <- SchemaPolicy.entry(pin, "graphiti.save.v1") do
      context =
        Map.new(@context, &{&1, nil})
        |> Map.merge(%{
          "graph_kind" => "inputs",
          "operation_manifest_ref" => auth.manifest_id,
          "operation_manifest_digest" => auth.manifest_digest,
          "context_id" => Ecto.UUID.generate(),
          "logical_call_id" => Ecto.UUID.generate(),
          "seam_id" => "graphiti.save.v1",
          "stage_id" => pin["id"],
          "prompt_name" => "graphiti.save.v1",
          "config_digest" => pin["config_digest"],
          "schema_digest" => entry["schema_digest"]
        })

      source =
        Map.new(@row, &{&1, nil})
        |> Map.merge(%{
          "kind" => "source_revision",
          "dependency_key" => "source_revision:" <> window["revision_id"],
          "source_id" => window["source_id"],
          "revision_id" => window["revision_id"],
          "content_hash" => window["body_hash"],
          "role" => "uncited"
        })

      parent =
        Map.new(@row, &{&1, nil})
        |> Map.merge(%{
          "kind" => "manifest",
          "dependency_key" => "manifest:" <> auth.manifest_id,
          "parent_manifest_id" => auth.manifest_id,
          "content_hash" => auth.manifest_digest,
          "role" => "transitive"
        })

      with {:ok, build} <- GraphManifests.begin_manifest(auth, "graph_ingest", context),
           {:ok, _} <-
             GraphManifests.append_page(
               build["manifest_id"],
               %{
                 "page_index" => 0,
                 "first_ordinal" => 0,
                 "previous_page_digest" => nil,
                 "final" => true,
                 "rows" => [parent, source]
               },
               auth
             ),
           {:ok, _} <-
             GraphManifests.finish_manifest(
               build["manifest_id"],
               %{"dependency_count" => 2, "source_count" => 1},
               auth
             ),
           {:ok, %{"state" => "sealed"} = sealed} <-
             GraphManifests.advance_validation(build["manifest_id"], auth),
           do: {:ok, sealed},
           else: (_ -> @error)
    end
  end

  defp now, do: DateTime.to_iso8601(Store.now())
end
