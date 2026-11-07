defmodule HarnessForge.Graphiti.SearchProtocolTest do
  use ExUnit.Case, async: true
  alias HarnessForge.{Contracts, Graphiti.Protocol, Graphiti.SchemaPolicy, Models.Stages}

  test "preparation control has no query, provider options, credentials or job authority" do
    req = %{
      "operation_id" => Ecto.UUID.generate(),
      "partition_id" => Ecto.UUID.generate(),
      "lease_id" => Ecto.UUID.generate(),
      "scope_ref" => "hf_synthetic_scope",
      "stage_set_digest" => String.duplicate("1", 64)
    }

    ack =
      Map.merge(req, %{
        "initialized" => true,
        "source_lock_digest" => String.duplicate("2", 64),
        "backend_pin_digest" => String.duplicate("3", 64),
        "error_code" => nil
      })

    for {kind, value} <- [{"prepare_runtime", req}, {"prepare_runtime_ack", ack}] do
      assert :ok == Protocol.validate_payload(kind, value)

      for key <- ["query", "deadline_ms", "backend_password", "options", "job_id"] do
        assert {:error, _} = Protocol.validate_payload(kind, Map.put(value, key, "untrusted"))
      end

      for key <- Map.keys(value) do
        assert {:error, _} = Protocol.validate_payload(kind, Map.delete(value, key))
      end
    end

    for value <- [
          Map.put(ack, "initialized", false),
          Map.put(ack, "initialized", 1),
          Map.put(ack, "error_code", "provider_error"),
          Map.put(ack, "error_code", "raw detail")
        ] do
      assert {:error, _} = Protocol.validate_payload("prepare_runtime_ack", value)
    end

    assert :ok ==
             Protocol.validate_payload(
               "prepare_runtime_ack",
               Map.merge(ack, %{"initialized" => false, "error_code" => "deadline_exceeded"})
             )
  end

  test "root search observations cannot authorize provider sends or widen the wire intent transform" do
    p = pin()

    input = %{
      "stage_id" => p["id"],
      "config_digest" => p["config_digest"],
      "prompt_name" => "graphiti.search.v1",
      "seam_id" => "graphiti.search.v1",
      "schema_digest" => SchemaPolicy.search_schema_digest(),
      "phase" => "inputs",
      "base_context_ref" => nil,
      "base_context_digest" => nil,
      "receipt_ref" => nil,
      "receipt_digest" => nil,
      "raw_body_sha256" => nil,
      "rendered_projection_digest" => Contracts.digest([]),
      "transform_id" => "root_search_intent_v1",
      "page_index" => 0,
      "final" => true,
      "previous_page_digest" => nil,
      "parent_contexts" => []
    }

    assert :ok == SchemaPolicy.validate_context(p, input)

    result =
      Map.merge(input, %{
        "phase" => "derived",
        "transform_id" => "native_search_rrf_v1",
        "base_context_ref" => Ecto.UUID.generate(),
        "base_context_digest" => String.duplicate("4", 64)
      })

    assert :ok == SchemaPolicy.validate_context(p, result)

    assert {:error, _} =
             SchemaPolicy.validate_context(
               p,
               Map.put(result, "transform_id", "root_search_intent_v1")
             )

    server_intent =
      Map.merge(result, %{
        "graph_kind" => "derived",
        "transform_id" => "root_search_intent_v1",
        "rendered_projection_digest" => nil
      })

    assert :ok == SchemaPolicy.validate_context(p, server_intent)

    # The root seals an inputs manifest for the final wire page before its
    # derived ACK. That server manifest retains the initial input ACK as base.
    server_result_inputs =
      Map.merge(result, %{
        "graph_kind" => "inputs",
        "transform_id" => nil,
        "rendered_projection_digest" => nil
      })

    assert :ok == SchemaPolicy.validate_context(p, server_result_inputs)

    for value <- [
          Map.merge(input, Map.take(result, ~w(base_context_ref base_context_digest))),
          Map.put(server_result_inputs, "base_context_ref", nil),
          Map.put(server_result_inputs, "base_context_digest", nil)
        ] do
      assert {:error, _} = SchemaPolicy.validate_context(p, value)
    end

    for value <- [
          Map.put(input, "phase", "attempt_bind"),
          Map.put(input, "raw_body_sha256", String.duplicate("5", 64)),
          Map.put(result, "receipt_ref", Ecto.UUID.generate()),
          Map.put(result, "schema_digest", SchemaPolicy.digest())
        ] do
      assert {:error, _} = SchemaPolicy.validate_context(p, value)
    end

    assert {:error, _} = SchemaPolicy.entry(p, "graphiti.search.v1")
    assert {:error, _} = SchemaPolicy.validate_body(p, "graphiti.search.v1", "{}", [])
    assert SchemaPolicy.search_prompt_policy()["provider_attempt"] == false
  end

  defp pin do
    value = %{
      "id" => Ecto.UUID.generate(),
      "stage" => "embedder",
      "provider" => "ollama",
      "model" => "synthetic-pinned",
      "endpoint" => "http://127.0.0.1:11434/v1/embeddings",
      "route_id" => "graphiti_embedder",
      "credential_ref" => nil,
      "prompt_digest" => SchemaPolicy.prompt_policy_digest("embedder"),
      "schema_digest" => SchemaPolicy.digest(),
      "consent_revision" => 1,
      "input_rate" => 0,
      "output_rate" => 0,
      "max_output_tokens" => 1024,
      "timeout_ms" => 60000
    }

    Map.put(value, "config_digest", Stages.fingerprint(value))
  end
end
