defmodule HarnessForge.Graphiti.ProtocolTest do
  use ExUnit.Case, async: true
  alias HarnessForge.Graphiti.Protocol

  defp frame do
    %{
      "v" => 1,
      "kind" => "job",
      "session_id" => "session:synthetic",
      "seq" => 1,
      "request_id" => "request:synthetic",
      "payload" => %{
        "op" => "search",
        "job_id" => "job:synthetic",
        "idempotency_key" => "idempotency:synthetic",
        "scope_ref" => "group:synthetic",
        "semantic_generation" => 1,
        "authorization_generation" => 1,
        "cancel_epoch" => 0,
        "closure_ref" => "manifest:synthetic",
        "closure_digest" => String.duplicate("1", 64),
        "stage_set_digest" => String.duplicate("2", 64),
        "partition_id" => "partition:synthetic",
        "lease_id" => "lease:synthetic",
        "worker_session_id" => "session:synthetic",
        "deadline_ms" => 60000,
        "args" => %{
          "query" => "Café synthetic",
          "limit" => 10,
          "recipe_id" => "edge_hybrid_rrf_v1"
        }
      }
    }
  end

  test "packet prefix is UTF8 bytes and partial reads retain only bounded remainder" do
    value = frame()
    assert {:ok, packet} = Protocol.encode(value)
    <<length::unsigned-big-32, json::binary>> = packet
    assert length == byte_size(json)
    <<prefix::binary-size(6), rest::binary>> = packet
    assert {:ok, [], ^prefix} = Protocol.consume(prefix)
    assert {:ok, [^value], ""} = Protocol.consume(prefix <> rest)
  end

  test "huge prefix rejects before buffering body; duplicate/unknown fields and forged groups reject" do
    assert {:error, :invalid_frame} = Protocol.consume(<<131_073::unsigned-big-32>>)
    assert {:error, :invalid_frame} = Protocol.decode("{\"v\":1,\"v\":1}")
    assert {:error, :invalid_frame} = Protocol.encode(Map.put(frame(), "permission", "allow"))
    forged = put_in(frame(), ["payload", "args", "group_ids"], ["foreign"])
    assert {:error, :invalid_frame} = Protocol.encode(forged)

    assert {:error, :invalid_frame} =
             Protocol.encode(put_in(frame(), ["payload", "scope_ref"], ""))
  end

  test "wrong scalar and payload sizes cannot pass as a valid job" do
    for changed <- [
          put_in(frame(), ["payload", "args", "limit"], true),
          put_in(frame(), ["payload", "args", "limit"], 101),
          put_in(frame(), ["payload", "args", "query"], String.duplicate("é", 4097))
        ] do
      assert {:error, :invalid_frame} = Protocol.encode(changed)
    end
  end

  test "graph control IDs are required and private authority tokens are never wire fields" do
    assert {:error, :invalid_frame} =
             Protocol.encode(put_in(frame(), ["payload", "partition_id"], nil))

    assert {:error, :invalid_frame} =
             Protocol.encode(put_in(frame(), ["payload", "lease_id"], nil))

    assert {:error, :invalid_frame} =
             Protocol.encode(put_in(frame(), ["payload", "control_token"], "forbidden"))

    assert {:error, :invalid_frame} =
             Protocol.encode(put_in(frame(), ["payload", "operation_token"], "forbidden"))
  end

  test "context pages bind actual bounded values and acknowledgements cannot contain authority tokens" do
    value = %{"query" => "Synthetic input"}
    hash = HarnessForge.Contracts.digest(value)

    entry = %{
      "entry_id" => "entry:synthetic",
      "kind" => "deterministic_output",
      "object_id" => "call:synthetic",
      "version_ref" => nil,
      "predecessor_version_ref" => nil,
      "value_hash" => hash,
      "value" => value,
      "projection_id" => "graphiti_context_v1",
      "projection_hash" => hash,
      "parent_manifest_ref" => "manifest:synthetic",
      "parent_manifest_digest" => String.duplicate("1", 64),
      "receipt_ref" => nil
    }

    page = %{
      "job_id" => "job:synthetic",
      "partition_id" => "partition:synthetic",
      "lease_id" => "lease:synthetic",
      "cancel_epoch" => 0,
      "semantic_generation" => 1,
      "authorization_generation" => 1,
      "operation_manifest_ref" => "manifest:synthetic",
      "operation_manifest_digest" => String.duplicate("1", 64),
      "context_id" => "context:synthetic",
      "logical_call_id" => "call:synthetic",
      "phase" => "inputs",
      "seam_id" => "llm.context.v1",
      "stage_id" => "stage:synthetic",
      "prompt_name" => "extract_nodes.extract_text",
      "config_digest" => String.duplicate("2", 64),
      "schema_digest" => String.duplicate("3", 64),
      "page_index" => 0,
      "previous_page_digest" => nil,
      "final" => true,
      "entries" => [entry],
      "base_context_ref" => nil,
      "base_context_digest" => nil,
      "parent_contexts" => [],
      "raw_body_sha256" => nil,
      "rendered_projection_digest" => nil,
      "transform_id" => "graphiti_builder_v1"
    }

    assert :ok = Protocol.validate_payload("context_page", page)

    parent = %{
      "manifest_ref" => "manifest:parent",
      "manifest_digest" => String.duplicate("8", 64)
    }

    assert :ok =
             Protocol.validate_payload("context_page", Map.put(page, "parent_contexts", [parent]))

    for parents <- [
          [parent, parent],
          List.duplicate(parent, 101),
          [Map.put(parent, "authority", true)]
        ] do
      assert {:error, :invalid_dto} =
               Protocol.validate_payload(
                 "context_page",
                 Map.put(page, "parent_contexts", parents)
               )
    end

    assert {:error, :invalid_dto} =
             Protocol.validate_payload(
               "context_page",
               Map.put(page, "entries", [Map.delete(entry, "predecessor_version_ref")])
             )

    for {seam, transform} <- [
          {"graphiti.extract_nodes.v1", "graphiti_extract_nodes_v1"},
          {"graphiti.resolve_nodes.v1", "graphiti_resolve_nodes_v1"},
          {"graphiti.extract_edges.v1", "graphiti_extract_edges_v1"},
          {"graphiti.attributes.v1", "graphiti_attribute_overlay_v1"},
          {"graphiti.summary_flight.v1", "graphiti_summary_flight_v1"},
          {"graphiti.summary_batch.v1", "graphiti_fact_append_v1"},
          {"graphiti.temporal.v1", "graphiti_temporal_v1"},
          {"graphiti.save.v1", "graphiti_save_v1"},
          {"llm.response.v1", "model_response_v1"}
        ] do
      assert :ok =
               Protocol.validate_payload(
                 "context_page",
                 Map.merge(page, %{
                   "phase" => "derived",
                   "seam_id" => seam,
                   "transform_id" => transform
                 })
               )
    end

    assert {:error, :invalid_dto} =
             Protocol.validate_payload(
               "context_page",
               Map.put(page, "operation_token", "forbidden")
             )

    assert {:error, :invalid_dto} =
             Protocol.validate_payload(
               "context_page",
               Map.put(page, "entries", List.duplicate(entry, 101))
             )

    assert {:error, :invalid_dto} =
             Protocol.validate_payload(
               "context_page",
               Map.put(page, "entries", [Map.put(entry, "value", "changed")])
             )

    ack = %{
      "job_id" => page["job_id"],
      "context_id" => page["context_id"],
      "page_index" => 0,
      "page_digest" => Protocol.context_page_digest(page),
      "state" => "denied",
      "version_refs" => [],
      "context_manifest_ref" => nil,
      "context_manifest_digest" => nil,
      "allowed_body_sha256" => nil,
      "error_code" => "closure_incomplete"
    }

    assert :ok = Protocol.validate_payload("context_ack", ack)

    assert {:error, :invalid_dto} =
             Protocol.validate_payload(
               "context_ack",
               Map.put(ack, "allowed_body_sha256", String.duplicate("4", 64))
             )
  end
end
